class DataImports::Salesforce::Staging::Person < DataImports::Salesforce::Staging::Record
  self.table_name = 'sf.people'
  self.primary_key = 'person_key'

  def self.in_scope(phase, since)
    return all if since.blank?

    where('EXISTS (SELECT 1 FROM sf.threads t WHERE t.person_key = sf.people.person_key AND t.phase = ? AND t.last_at >= ?)', phase, since)
  end
end
