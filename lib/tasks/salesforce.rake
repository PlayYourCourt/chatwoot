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

  desc 'Start a Salesforce import from the staging DB. Usage: rails "salesforce:import[ACCOUNT_ID,salesforce|freshdesk,2026-08-10]"'
  task :import, [:account_id, :phase, :since] => :environment do |_task, args|
    account = Account.find(args[:account_id])
    initiated_by = account.administrators.first
    phase = args[:phase].presence || 'salesforce'
    data_import = DataImports::CreationService.new(
      account: account,
      initiated_by: initiated_by,
      source_params: {
        source_provider: 'salesforce',
        access_token: 'staging',
        name: ['Salesforce', phase, args[:since].presence].compact.join(' '),
        phase: phase,
        since: args[:since].presence,
        import_types: DataImport::IMPORT_TYPES
      }
    ).perform
    abort 'Another data import is already in progress for this account.' unless data_import

    DataImports::Salesforce::ImportJob.perform_later(data_import, data_import.active_import_run_id)
    puts "Started DataImport ##{data_import.id} (#{data_import.name}); totals: #{data_import.stats}"
  end

  desc 'Move imported history from a placeholder inbox into a real inbox. Usage: rails "salesforce:relocate_inbox[FROM_INBOX_ID,TO_INBOX_ID]"'
  task :relocate_inbox, [:from_inbox_id, :to_inbox_id] => :environment do |_task, args|
    from = Inbox.find(args[:from_inbox_id])
    to = Inbox.find(args[:to_inbox_id])
    abort 'Both inboxes must belong to the same account.' unless from.account_id == to.account_id

    moved_contact_inboxes = 0
    ContactInbox.where(inbox_id: from.id).find_each do |contact_inbox|
      source_id = case to.channel_type
                  when 'Channel::Email' then contact_inbox.contact.email.presence
                  when 'Channel::TwilioSms' then contact_inbox.contact.phone_number.presence
                  end || contact_inbox.source_id
      existing = ContactInbox.find_by(inbox_id: to.id, source_id: source_id)
      if existing && existing.contact_id == contact_inbox.contact_id
        Conversation.where(contact_inbox_id: contact_inbox.id).update_all(contact_inbox_id: existing.id) # rubocop:disable Rails/SkipsModelValidations
        contact_inbox.delete
      elsif existing
        contact_inbox.update_columns(inbox_id: to.id) # rubocop:disable Rails/SkipsModelValidations
      else
        contact_inbox.update_columns(inbox_id: to.id, source_id: source_id) # rubocop:disable Rails/SkipsModelValidations
      end
      moved_contact_inboxes += 1
    end
    conversations = Conversation.where(inbox_id: from.id).update_all(inbox_id: to.id) # rubocop:disable Rails/SkipsModelValidations
    messages = Message.where(inbox_id: from.id).update_all(inbox_id: to.id) # rubocop:disable Rails/SkipsModelValidations
    puts "Moved #{conversations} conversations, #{messages} messages, #{moved_contact_inboxes} contact inboxes from ##{from.id} to ##{to.id}"
    if from.channel_type == 'Channel::Api' && from.channel.additional_attributes&.dig('import_placeholder')
      from.destroy!
      puts "Deleted placeholder inbox ##{from.id} (#{from.name})"
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
    account.inboxes.order(:id).each do |inbox|
      imported = inbox.conversations.where("identifier LIKE 'salesforce:%'").count
      puts "  ##{inbox.id} #{inbox.name}: #{imported} imported / #{inbox.conversations.count} total"
    end
    puts "Imported contacts: #{account.contacts.where("additional_attributes->'source'->>'provider' = 'salesforce'").count}"
  end
end
# rubocop:enable Metrics/BlockLength
