# Read-only base for the Salesforce staging database (see deploy/salesforce/): a separate Postgres
# reached through SALESFORCE_STAGING_DATABASE_URL, holding the transformed sf.people / sf.threads /
# sf.parts tables that are the only thing the importer reads.
class DataImports::Salesforce::Staging::Record < ActiveRecord::Base # rubocop:disable Rails/ApplicationRecord
  self.abstract_class = true

  establish_connection(ENV['SALESFORCE_STAGING_DATABASE_URL']) if ENV['SALESFORCE_STAGING_DATABASE_URL'].present?

  def readonly?
    true
  end
end
