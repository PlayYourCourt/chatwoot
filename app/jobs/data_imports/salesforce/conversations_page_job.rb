class DataImports::Salesforce::ConversationsPageJob < DataImports::Salesforce::BaseJob
  # One chain per shard, as ContactsPageJob; the last shard to finish completes the import.
  def perform(data_import, starting_after = nil, run_id = nil, shard = 0)
    return if skip_import?(data_import, run_id)

    importer = importer_for(data_import, run_id)
    unless importer.shard_completed?('conversations', shard)
      result = importer.import_conversations_page(starting_after: starting_after, shard: shard)
      return if skip_import?(data_import, run_id)
      return self.class.perform_later(data_import, result.next_cursor, run_id, shard) unless result.done?
    end

    importer.shard_finished('conversations', run_id)
  rescue ActiveRecord::QueryCanceled
    retry_page(data_import, starting_after, run_id, shard)
  rescue StandardError => e
    fail_unexpected_error(importer, e)
  end
end
