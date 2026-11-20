class DataImports::Salesforce::BaseJob < DataImports::BaseJob
  RETRY_PAGE_DELAY = 10.seconds

  private

  # A statement timeout (the managed database under load) retries the page a little later instead of failing the
  # whole import: items are idempotent and the shard's cursor only advances once a page is done.
  def retry_page(data_import, starting_after, run_id, shard)
    Rails.logger.warn("#{self.class.name}: statement timeout on shard #{shard} after #{starting_after.inspect}; retrying the page")
    self.class.set(wait: RETRY_PAGE_DELAY).perform_later(data_import, starting_after, run_id, shard)
  end
end
