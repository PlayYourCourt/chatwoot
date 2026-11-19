class DataImports::Salesforce::ImportJob < DataImports::Salesforce::BaseJob
  # Starts (or, from `salesforce:resume`, re-enqueues) the parallel page chains of the current stage.
  def perform(data_import, run_id = nil)
    return if skip_import?(data_import, run_id)

    importer = importer_for(data_import, run_id)
    return unless importer.start!

    importer.enqueue_stage(run_id)
  rescue StandardError => e
    fail_unexpected_error(importer, e)
  end
end
