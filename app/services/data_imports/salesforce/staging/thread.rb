class DataImports::Salesforce::Staging::Thread < DataImports::Salesforce::Staging::Record
  self.table_name = 'sf.threads'
  self.primary_key = 'thread_key'

  def self.in_scope(phase, since)
    scope = where(phase: phase)
    since.present? ? scope.where('last_at >= ?', since) : scope
  end
end
