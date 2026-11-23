class DataImports::Salesforce::Staging::Person < DataImports::Salesforce::Staging::Record
  self.table_name = 'sf.people'
  self.primary_key = 'person_key'

  # People with notes are always walked (a few thousand): contact notes only travel with the contacts stage,
  # and the importer adds just the ones not mapped yet.
  def self.in_scope(phase, since, retry_keys: [])
    return all if since.blank?

    active = where('EXISTS (SELECT 1 FROM sf.threads t WHERE t.person_key = sf.people.person_key AND t.phase = ? AND t.last_at >= ?)',
                   phase, since)
    scope = active.or(where(person_key: DataImports::Salesforce::Staging::PersonNote.select(:person_key)))
    retry_keys.empty? ? scope : scope.or(where(person_key: retry_keys))
  end
end
