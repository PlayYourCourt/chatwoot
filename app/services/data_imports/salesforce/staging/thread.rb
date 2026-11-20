class DataImports::Salesforce::Staging::Thread < DataImports::Salesforce::Staging::Record
  self.table_name = 'sf.threads'
  self.primary_key = 'thread_key'

  def self.in_scope(phase, since, retry_keys: [])
    scope = where(phase: phase)
    return scope if since.blank?

    active = scope.where('last_at >= ?', since)
    retry_keys.empty? ? active : active.or(scope.where(thread_key: retry_keys))
  end
end
