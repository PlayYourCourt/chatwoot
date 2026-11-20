# rubocop:disable Rails/SkipsModelValidations
# Salesforce-specific behaviour on top of the generic importer:
# - contact_inboxes on live email/Twilio inboxes use the real address/number as source_id, so future
#   inbound mail or SMS lands on the same contact_inbox (placeholders keep the synthetic id);
# - imported conversations get their labels, status (snoozed until a future due date), priority, owner and team;
# - messages carry the SMS delivery status and, for emails, the subject/from/to in content_attributes.
# - the contact and conversation stages run as `shards` parallel page chains (rows split by `seq % shards`),
#   each with its own cursor key (`contacts/0` ...). The stage key (`contacts`) is marked completed by whichever
#   chain finishes last. Stats are flushed once per page as deltas merged under the import's row lock, and the
#   per-item stop check is throttled, because every round trip to the database is what bounds the throughput.
class DataImports::Salesforce::Importer < DataImports::Importer
  SMS_STATUSES = { 'delivered' => 'delivered', 'read' => 'read', 'sent' => 'sent' }.freeze
  # Salesforce object => Chatwoot team name; the teams must exist before the import.
  OBJECT_TEAMS = { 'opportunity' => 'lesson sales', 'case' => 'support' }.freeze
  STOP_CHECK_INTERVAL = 10.seconds
  COUNTER_STATS = { 'contacts' => %w[imported skipped], 'conversations' => %w[imported skipped],
                    'messages' => %w[imported skipped total], 'errors' => %w[count] }.freeze

  def shards
    @source.shards
  end

  def shard_keys(stage)
    Array.new(shards) { |shard| "#{stage}/#{shard}" }
  end

  def shard_completed?(stage, shard)
    stage_completed?("#{stage}/#{shard}")
  end

  def import_contacts_page(starting_after: nil, shard: 0)
    response = @source.list_contacts(starting_after: starting_after, per_page: @source.contacts_per_page, shard: shard)
    import_shard_page("contacts/#{shard}", response) { |contact| import_contact(contact) }
  end

  def import_conversations_page(starting_after: nil, shard: 0)
    response = @source.list_conversations(starting_after: starting_after, per_page: @source.conversations_per_page, shard: shard)
    import_shard_page("conversations/#{shard}", response) { |summary| import_conversation_from_summary(summary) }
  end

  # Enqueues one page chain per shard for the stage that is not done yet (on start and when resuming).
  def enqueue_stage(run_id)
    if import_contacts? && !contacts_completed?
      enqueue_shards(DataImports::Salesforce::ContactsPageJob, 'contacts', run_id)
    elsif import_conversations? && !conversations_completed?
      enqueue_shards(DataImports::Salesforce::ConversationsPageJob, 'conversations', run_id)
    else
      finish!
    end
  end

  # Called by a chain that reached the end of its shard: the last one marks the stage completed and moves on.
  def shard_finished(stage, run_id)
    advanced = @data_import.with_lock do
      next false if inactive_import_run?

      cursor = @data_import.cursor.to_h.deep_stringify_keys
      next false if cursor.dig(stage, 'completed') == true
      next false unless shard_keys(stage).all? { |key| cursor.dig(key, 'completed') == true }

      @data_import.update!(cursor: cursor.merge(stage => { 'completed' => true, 'updated_at' => Time.current.iso8601 }))
      true
    end
    enqueue_stage(run_id) if advanced
  end

  # The generic finish! writes the in-memory stats; with several chains they are only deltas, so count first.
  def finish!
    @data_import.with_lock do
      next if inactive_import_run?

      @stats = default_stats.deep_merge(@data_import.stats || {})
      items = @data_import.items.where(source_provider: @source.provider)
      %w[contact conversation].each do |type|
        @stats["#{type}s"]['imported'] = items.where(source_object_type: type).imported.count
        @stats["#{type}s"]['skipped'] = items.where(source_object_type: type).skipped.count
      end
      mappings = @data_import.mappings.where(source_provider: @source.provider, source_object_type: 'message')
      @stats['messages']['imported'] = mappings.count - mappings.where("metadata ->> 'skipped' = ?", 'true').count
      @stats['messages']['skipped'] = @data_import.import_errors.where(source_object_type: 'message').where("details ->> 'kind' = ?", 'skipped').count
    end
    super
  end

  private

  def enqueue_shards(job_class, stage, run_id)
    shards.times do |shard|
      next if stage_completed?("#{stage}/#{shard}")

      job_class.perform_later(@data_import, cursor_for("#{stage}/#{shard}"), run_id, shard)
    end
  end

  def import_shard_page(key, response)
    @defer_stats = true
    Array(response['data']).each do |record|
      break if import_stopped?

      yield record
    end
    @defer_stats = false
    return PageResult.new(next_cursor: nil) if import_stopped?

    persist_stats
    PageResult.new(next_cursor: update_cursor(key, response.dig('pages', 'next', 'starting_after')))
  end

  def import_stopped?
    return true if @import_stopped
    return false if @stop_checked_at && @stop_checked_at > STOP_CHECK_INTERVAL.ago

    @stop_checked_at = Time.current
    super
  end

  # Each chain only ever writes its own key, so there is no concurrent-writer check per key.
  def update_cursor(key, cursor)
    @data_import.with_lock do
      current_cursor = @data_import.cursor.to_h.deep_stringify_keys
      if inactive_import_run?
        @import_stopped = true
        next current_cursor.dig(key, 'starting_after')
      end

      updated_cursor = current_cursor.merge(
        key => { 'starting_after' => cursor, 'completed' => cursor.blank?, 'updated_at' => Time.current.iso8601 }
      )
      @data_import.update!(cursor: updated_cursor)
      @persisted_cursor = updated_cursor.deep_dup
      cursor
    end
  end

  # Counters are increments since the last flush, added to whatever the other chains have stored meanwhile.
  def persist_stats
    return if @defer_stats

    @data_import.with_lock do
      stored = default_stats.deep_merge(@data_import.stats || {})
      base = @persisted_stats || stored
      COUNTER_STATS.each do |group, keys|
        keys.each do |stat|
          delta = @stats.dig(group, stat).to_i - base.dig(group, stat).to_i
          stored[group][stat] = stored[group][stat].to_i + delta unless delta.zero? && stored[group][stat].nil?
        end
      end
      @stats = stored
      @data_import.update_columns(stats: @stats, updated_at: Time.current)
      @persisted_stats = @stats.deep_dup
    end
  end

  # Absolute counts are reconciled once at the end (finish!) instead of per page.
  def reconcile_dirty_stats; end
  def reconcile_item_stats(_source_object_type); end
  def reconcile_message_stats; end

  # The generic importer holds the import's row lock while it writes each message batch so that an abandoned run
  # never writes. With many chains that lock serialises every message write and the waits exceed the statement
  # timeout; the throttled stop check is the guard here instead.
  def bulk_write_message_entries(conversation, contact, batch_builder, entries)
    return if import_stopped?

    persist_message_entries(conversation, contact, batch_builder.refresh(entries).entries)
  end

  def import_unprepared_message(conversation, contact, batch_builder, source_entry)
    return if import_stopped?

    with_query_timeout_retry do
      import_message(conversation, contact, batch_builder.perform([source_entry]).entries.first)
    end
  rescue StandardError => e
    fail_message(conversation, source_entry[:source_id], source_entry[:part], e)
  end

  def fallback_message_entry(conversation, contact, batch_builder, entry)
    return if import_stopped?

    with_query_timeout_retry do
      import_message(conversation, contact, batch_builder.refresh([entry]).entries.first, reindex: false)
    end
  rescue ActiveRecord::ActiveRecordError => e
    fail_message(conversation, entry.source_id, entry.part, e)
  end

  def contact_inbox_for(contact, inbox)
    source_id = live_source_id(contact, inbox) || "salesforce:#{contact.id}"
    ContactInbox.find_or_create_by!(contact: contact, inbox: inbox) do |contact_inbox|
      contact_inbox.source_id = source_id
    end
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    # the address/number is already linked to another contact on this inbox: fall back to a synthetic id
    ContactInbox.find_or_create_by!(contact: contact, inbox: inbox) { |ci| ci.source_id = "salesforce:#{contact.id}" }
  end

  # The generic importer marks every imported contact as a lead; people with a Stripe id or a won
  # opportunity are customers (decided in sf.people).
  def contact_attributes(contact_payload)
    super.tap do |attrs|
      attrs[:contact_type] = Contact.contact_types[:customer] if contact_payload['contact_type'] == 'customer'
    end
  end

  def live_source_id(contact, inbox)
    case inbox.channel_type
    when 'Channel::Email' then contact.email.presence
    when 'Channel::TwilioSms' then contact.phone_number.presence
    end
  end

  def create_conversation(conversation, contact, contact_inbox, inbox, source_type)
    super.tap { |chatwoot_conversation| apply_salesforce_state(chatwoot_conversation, conversation) }
  end

  def refresh_mapped_conversation(chatwoot_conversation, conversation)
    apply_salesforce_state(chatwoot_conversation, conversation) if @source.refresh?
  end

  # A refresh never changes email/phone (uniqueness against other contacts) and never demotes a customer to a lead.
  def refresh_mapped_contact(contact, contact_payload)
    return unless @source.refresh?

    attrs = contact_attributes(contact_payload)
    updates = {
      additional_attributes: contact.additional_attributes.to_h.deep_merge(attrs[:additional_attributes].to_h),
      custom_attributes: contact.custom_attributes.to_h.deep_merge(attrs[:custom_attributes].to_h),
      updated_at: Time.current
    }
    updates[:name] = attrs[:name] if attrs[:name].present?
    updates[:contact_type] = attrs[:contact_type] if attrs[:contact_type] == Contact.contact_types[:customer]
    contact.update_columns(updates)
  end

  def apply_salesforce_state(chatwoot_conversation, conversation)
    apply_labels(chatwoot_conversation, Array(conversation['labels']))
    chatwoot_conversation.update_columns(
      conversation_state(conversation).merge(
        priority: Conversation.priorities[conversation['priority']],
        assignee_id: owner_agent_id(conversation['custom']),
        team_id: object_team_id(conversation['sf_object'])
      )
    )
  end

  # Unresolved threads with a due date still ahead are snoozed until it, so they come back on their own.
  def conversation_state(conversation)
    due_at = conversation['due_at'] && Time.zone.at(conversation['due_at'])
    return { status: Conversation.statuses['snoozed'], snoozed_until: due_at } if conversation['status'] != 'resolved' && due_at&.future?

    { status: Conversation.statuses[conversation['status']] }
  end

  # SALESFORCE_OWNER_EMAILS maps Salesforce owner / Freshdesk agent names to Chatwoot logins, per server:
  # "Zach Howard=zach@example.com;Adam Soule=adam@example.com". The Salesforce owner wins; the Freshdesk agent is
  # used when the owner is not listed (legacy records are owned by the migration user). Unlisted names stay unassigned.
  def owner_agent_id(custom)
    @owner_agent_ids ||= ENV.fetch('SALESFORCE_OWNER_EMAILS').split(';').to_h { |pair| pair.split('=', 2).map(&:strip) }
                            .transform_values { |email| @account.users.find_by!(email: email).id }
    @owner_agent_ids[custom['sf_owner']] || @owner_agent_ids[custom['fd_responder']]
  end

  def object_team_id(sf_object)
    @object_team_ids ||= OBJECT_TEAMS.transform_values { |name| @account.teams.find_by!(name: name).id }
    @object_team_ids[sf_object]
  end

  def apply_labels(conversation, labels)
    labels = labels.map(&:to_s).map(&:downcase).uniq.grep(RegexHelper::UNICODE_CHARACTER_NUMBER_HYPHEN_UNDERSCORE)
    return if labels.empty?

    labels.each { |label| account_label(label) }
    tags = ActsAsTaggableOn::Tag.find_or_create_all_with_like_by_name(labels)
    now = Time.current
    rows = tags.map { |tag| [tag.id, 'Conversation', conversation.id, 'labels', now] }
    ActsAsTaggableOn::Tagging.import(%i[tag_id taggable_type taggable_id context created_at], rows,
                                     on_duplicate_key_ignore: true, validate: false)
    conversation.update_columns(cached_label_list: (conversation.cached_label_list_array | labels).join(','))
  end

  def account_label(title)
    @account_labels ||= @account.labels.pluck(:title).to_set
    return if @account_labels.include?(title)

    @account.labels.create!(title: title)
    @account_labels << title
  rescue ActiveRecord::RecordInvalid
    @account_labels << title
  end

  def message_attributes(conversation, contact, part, message_source_id, content)
    super.tap do |attrs|
      attrs[:status] = Message.statuses[SMS_STATUSES.fetch(part['status'].to_s, 'sent')]
      attrs[:content_attributes] = email_content_attributes(part) if part['kind'] == 'email'
    end
  end

  def email_content_attributes(part)
    {
      email: {
        subject: part['subject'],
        from: Array(part['from'].presence),
        to: split_addresses(part['to']),
        cc: split_addresses(part['cc']),
        date: timestamp_for(part['created_at']).iso8601
      }.compact
    }
  end

  def split_addresses(value)
    value.to_s.split(/[;,\s]+/).compact_blank
  end
end
# rubocop:enable Rails/SkipsModelValidations
