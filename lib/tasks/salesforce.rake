# rubocop:disable Metrics/BlockLength
namespace :salesforce do
  desc 'Import Salesforce leads/contacts from a CSV. Usage: rails "salesforce:import_contacts[ACCOUNT_ID,/path/to/contacts.csv]"'
  task :import_contacts, [:account_id, :path] => :environment do |_task, args|
    account = Account.find(args[:account_id])
    stats = Salesforce::ContactsImporter.new(account: account, path: args[:path]).perform
    puts "Salesforce contacts import for account #{account.id}: #{stats}"
  end

  desc 'Create the labels and custom attribute definitions the Salesforce import fills. Usage: rails "salesforce:setup[ACCOUNT_ID]"'
  task :setup, [:account_id] => :environment do |_task, args|
    account = Account.find(args[:account_id])
    puts "Account #{account.id}: #{DataImports::Salesforce::Setup.new(account: account).perform}"
  end

  desc 'Start a Salesforce import from the staging DB. Usage: rails "salesforce:import[ACCOUNT_ID,salesforce|freshdesk,2026-08-10,refresh,6]" ' \
       '(refresh: re-apply Salesforce state to records an earlier import created; give an ISO 8601 time instead, e.g. ' \
       '2026-11-23T09:30:00-05:00, to leave records changed in Chatwoot after it alone; last argument: parallel chains, default 6)'
  task :import, [:account_id, :phase, :since, :refresh, :shards] => :environment do |_task, args|
    account = Account.find(args[:account_id])
    initiated_by = account.administrators.first
    phase = args[:phase].presence || 'salesforce'
    failed_items = DataImportItem.where(data_import: account.data_imports.where(source_provider: 'salesforce'), status: :failed)
    data_import = DataImports::CreationService.new(
      account: account,
      initiated_by: initiated_by,
      source_params: {
        source_provider: 'salesforce',
        access_token: 'staging',
        name: ['Salesforce', phase, args[:since].presence, args[:refresh].presence].compact.join(' '),
        phase: phase,
        since: args[:since].presence,
        refresh: args[:refresh].presence,
        shards: args[:shards].presence,
        retry_person_keys: failed_items.where(source_object_type: 'contact').distinct.pluck(:source_object_id),
        retry_thread_keys: failed_items.where(source_object_type: 'conversation').distinct.pluck(:source_object_id),
        import_types: DataImport::IMPORT_TYPES
      }
    ).perform
    abort 'Another data import is already in progress for this account.' unless data_import

    DataImports::Salesforce::ImportJob.perform_later(data_import, data_import.active_import_run_id)
    metadata = data_import.source_metadata
    puts "Started DataImport ##{data_import.id} (#{data_import.name}, #{metadata['shards'] || DataImports::Salesforce::Source::DEFAULT_SHARDS} chains, " \
         "retrying #{Array(metadata['retry_person_keys']).size} contacts / #{Array(metadata['retry_thread_keys']).size} conversations " \
         'that failed earlier); ' \
         "totals: #{data_import.stats}"
  end

  desc 'Re-enqueue the page chains of the latest unfinished (or failed) Salesforce import. Usage: rails "salesforce:resume[ACCOUNT_ID]"'
  task :resume, [:account_id] => :environment do |_task, args|
    account = Account.find(args[:account_id])
    data_import = account.data_imports.where(source_provider: 'salesforce', status: [:pending, :processing, :failed]).order(:id).last
    abort 'No Salesforce import to resume for this account.' unless data_import

    data_import.update!(status: :processing) if data_import.failed?
    DataImports::Salesforce::ImportJob.perform_later(data_import, data_import.active_import_run_id)
    puts "Resumed DataImport ##{data_import.id} (#{data_import.name}); cursor: #{data_import.cursor}"
  end

  desc 'Abandon the running Salesforce import so a new one can start. Usage: rails "salesforce:abandon[ACCOUNT_ID]"'
  task :abandon, [:account_id] => :environment do |_task, args|
    account = Account.find(args[:account_id])
    data_import = account.data_imports.where(source_provider: 'salesforce', status: [:pending, :processing]).order(:id).last
    abort 'No Salesforce import is in progress for this account.' unless data_import

    data_import.abandon!
    puts "DataImport ##{data_import.id} (#{data_import.name}) status=#{data_import.status}"
  end

  desc 'Move imported history from a placeholder inbox into a real inbox. Usage: rails "salesforce:relocate_inbox[FROM_INBOX_ID,TO_INBOX_ID]"'
  task :relocate_inbox, [:from_inbox_id, :to_inbox_id] => :environment do |_task, args|
    from = Inbox.find(args[:from_inbox_id])
    to = Inbox.find(args[:to_inbox_id])
    result = DataImports::Salesforce::InboxRelocator.new(from: from, to: to).perform
    puts "Moved #{result.conversations} conversations, #{result.messages} messages, #{result.contact_inboxes} contact inboxes " \
         "from ##{from.id} to ##{to.id}"
    puts "Deleted placeholder inbox ##{from.id} (#{from.name})" if result.deleted_placeholder
  end

  desc 'Fold duplicate Salesforce placeholder inboxes (same bucket) into the oldest one. Usage: rails "salesforce:merge_placeholders[ACCOUNT_ID]"'
  task :merge_placeholders, [:account_id] => :environment do |_task, args|
    account = Account.find(args[:account_id])
    placeholders = account.inboxes.includes(:channel).where(channel_type: 'Channel::Api').order(:id).select do |inbox|
      attrs = inbox.channel.additional_attributes || {}
      attrs['source_provider'] == 'salesforce' && attrs['import_placeholder'] == true
    end
    placeholders.group_by { |inbox| inbox.channel.additional_attributes['source_bucket'] }.each_value do |inboxes|
      keeper, *duplicates = inboxes
      duplicates.each do |duplicate|
        result = DataImports::Salesforce::InboxRelocator.new(from: duplicate, to: keeper).perform
        puts "##{duplicate.id} -> ##{keeper.id} (#{keeper.name}): #{result.conversations} conversations, #{result.messages} messages"
      end
    end
  end

  desc 'Summarise Salesforce imports for an account. Usage: rails "salesforce:report[ACCOUNT_ID]"'
  task :report, [:account_id] => :environment do |_task, args|
    account = Account.find(args[:account_id])
    account.data_imports.where(source_provider: 'salesforce').order(:id).each do |data_import|
      puts "DataImport ##{data_import.id} #{data_import.name} status=#{data_import.status} stats=#{data_import.stats}"
      items = DataImportItem.where(data_import_id: data_import.id)
      puts "  items: #{items.group(:source_object_type, :status).count}"
      items.where(status: :failed).group(:last_error_message).order('count_all DESC').limit(10).count.each do |message, count|
        puts "  #{count}x #{message.to_s.truncate(160)}"
      end
    end
    puts 'Conversations per inbox:'
    imported_by_inbox = account.conversations.where("identifier LIKE 'salesforce:%'").group(:inbox_id).count
    total_by_inbox = account.conversations.group(:inbox_id).count
    account.inboxes.order(:id).each do |inbox|
      puts "  ##{inbox.id} #{inbox.name}: #{imported_by_inbox[inbox.id].to_i} imported / #{total_by_inbox[inbox.id].to_i} total"
    end
    contacts = DataImportMapping.where(account_id: account.id, source_provider: 'salesforce', source_object_type: 'contact').count
    puts "Imported contacts: #{contacts}"
  end
end
# rubocop:enable Metrics/BlockLength
