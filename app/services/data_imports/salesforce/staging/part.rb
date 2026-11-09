class DataImports::Salesforce::Staging::Part < DataImports::Salesforce::Staging::Record
  self.table_name = 'sf.parts'
  self.primary_key = 'part_id'
end
