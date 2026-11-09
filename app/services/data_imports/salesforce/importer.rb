# rubocop:disable Rails/SkipsModelValidations
# Salesforce-specific behaviour on top of the generic importer:
# - contact_inboxes on live email/Twilio inboxes use the real address/number as source_id, so future
#   inbound mail or SMS lands on the same contact_inbox (placeholders keep the synthetic id);
# - imported conversations get their labels and open/resolved status;
# - messages carry the SMS delivery status and, for emails, the subject/from/to in content_attributes.
class DataImports::Salesforce::Importer < DataImports::Importer
  SMS_STATUSES = { 'delivered' => 'delivered', 'read' => 'read', 'sent' => 'sent' }.freeze

  private

  def contact_inbox_for(contact, inbox)
    source_id = live_source_id(contact, inbox) || "salesforce:#{contact.id}"
    ContactInbox.find_or_create_by!(contact: contact, inbox: inbox) do |contact_inbox|
      contact_inbox.source_id = source_id
    end
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    # the address/number is already linked to another contact on this inbox: fall back to a synthetic id
    ContactInbox.find_or_create_by!(contact: contact, inbox: inbox) { |ci| ci.source_id = "salesforce:#{contact.id}" }
  end

  def live_source_id(contact, inbox)
    case inbox.channel_type
    when 'Channel::Email' then contact.email.presence
    when 'Channel::TwilioSms' then contact.phone_number.presence
    end
  end

  def create_conversation(conversation, contact, contact_inbox, inbox, source_type)
    super.tap do |chatwoot_conversation|
      apply_labels(chatwoot_conversation, Array(conversation['labels']))
      chatwoot_conversation.update_columns(status: Conversation.statuses['open']) if conversation['status'] == 'open'
    end
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
