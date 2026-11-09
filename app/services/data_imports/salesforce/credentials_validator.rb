# There are no credentials: the "source" is the staging database. Validation checks that it is
# reachable and transformed, and returns the counts for the requested phase/since scope.
class DataImports::Salesforce::CredentialsValidator
  def initialize(source_params:, import_types:)
    @source_params = source_params.to_h.with_indifferent_access
    @import_types = Array(import_types).compact_blank
  end

  def perform
    raise ArgumentError, 'SALESFORCE_STAGING_DATABASE_URL is not set.' if ENV['SALESFORCE_STAGING_DATABASE_URL'].blank?
    raise ArgumentError, 'Select at least one data type to import.' if @import_types.blank?

    invalid_types = @import_types - DataImport::IMPORT_TYPES
    raise ArgumentError, "Unsupported import types: #{invalid_types.join(', ')}" if invalid_types.present?

    phase = @source_params[:phase].presence || 'salesforce'
    raise ArgumentError, "Unknown phase #{phase}." unless DataImports::Salesforce::Source::PHASES.include?(phase)

    since = @source_params[:since].present? ? Time.zone.parse(@source_params[:since].to_s) : nil
    {
      'contacts' => DataImports::Salesforce::Staging::Person.in_scope(phase, since).count,
      'conversations' => DataImports::Salesforce::Staging::Thread.in_scope(phase, since).count
    }
  end
end
