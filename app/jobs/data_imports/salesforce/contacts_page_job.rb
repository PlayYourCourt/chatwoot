class DataImports::Salesforce::ContactsPageJob < DataImports::Salesforce::BaseJob
  # One chain per shard: imports a page, re-enqueues itself with the next cursor, and reports to the importer
  # when its shard is exhausted (the last shard to do so starts the conversation stage).
  def perform(data_import, starting_after = nil, run_id = nil, shard = 0)
    return if skip_import?(data_import, run_id)

    importer = importer_for(data_import, run_id)
    unless importer.shard_completed?('contacts', shard)
      result = importer.import_contacts_page(starting_after: starting_after, shard: shard)
      return if skip_import?(data_import, run_id)
      return self.class.perform_later(data_import, result.next_cursor, run_id, shard) unless result.done?
    end

    importer.shard_finished('contacts', run_id)
  rescue ActiveRecord::QueryCanceled
    retry_page(data_import, starting_after, run_id, shard)
  rescue StandardError => e
    fail_unexpected_error(importer, e)
  end
end
