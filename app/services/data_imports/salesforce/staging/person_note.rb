class DataImports::Salesforce::Staging::PersonNote < DataImports::Salesforce::Staging::Record
  self.table_name = 'sf.person_notes'
  self.primary_key = 'note_key'
end
