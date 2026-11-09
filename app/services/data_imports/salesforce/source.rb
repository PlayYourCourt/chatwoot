# Salesforce provider for the DataImports framework. Its "API" is the staging Postgres built by
# deploy/salesforce/ (sf.people, sf.threads, sf.parts). `source_metadata` carries the run scope:
#   phase: 'salesforce' (cases, leads, opportunities, SMS, email) or 'freshdesk' (legacy tickets)
#   since: optional ISO date; only threads active on/after it, and the people they touch
class DataImports::Salesforce::Source
  PROVIDER = 'salesforce'.freeze
  DISPLAY_NAME = 'Salesforce'.freeze
  CONTACTS_PER_PAGE = 200
  CONVERSATIONS_PER_PAGE = 50
  PHASES = %w[salesforce freshdesk].freeze
  ALREADY_IMPORTED_ERROR_CODE = 'salesforce_already_imported'.freeze
  SKIPPED_MESSAGE_ERROR_CODE = 'salesforce_blank_message'.freeze
  TRUNCATED_PARTS_ERROR_CODE = 'salesforce_truncated_parts'.freeze

  attr_reader :provider, :display_name, :contacts_per_page, :conversations_per_page, :phase, :since

  def self.credentials_validator(source_params:, import_types:)
    DataImports::Salesforce::CredentialsValidator.new(source_params: source_params, import_types: import_types)
  end

  def self.source_metadata(source_params)
    params = source_params.to_h.with_indifferent_access
    { 'phase' => params[:phase].presence || 'salesforce', 'since' => params[:since].presence }.compact
  end

  def self.default_import_name
    'Salesforce'
  end

  def self.credential_name
    'staging database'
  end

  def self.import_job_class
    DataImports::Salesforce::ImportJob
  end

  def self.importer_class
    DataImports::Salesforce::Importer
  end

  def self.contacts_page_job_class
    DataImports::Salesforce::ContactsPageJob
  end

  def self.conversations_page_job_class
    DataImports::Salesforce::ConversationsPageJob
  end

  def self.client_error?(_error)
    false
  end

  def self.authentication_error?(_error)
    false
  end

  def initialize(access_token: nil, source_metadata: {}) # rubocop:disable Lint/UnusedMethodArgument
    @provider = PROVIDER
    @display_name = DISPLAY_NAME
    @contacts_per_page = CONTACTS_PER_PAGE
    @conversations_per_page = CONVERSATIONS_PER_PAGE
    metadata = source_metadata.to_h.with_indifferent_access
    @phase = PHASES.include?(metadata[:phase]) ? metadata[:phase] : 'salesforce'
    @since = metadata[:since].present? ? Time.zone.parse(metadata[:since].to_s) : nil
    @normalizer = DataImports::Salesforce::Normalizer.new
  end

  def list_contacts(starting_after:, per_page:)
    scope = people_scope
    page = scope.where('seq > ?', starting_after.to_i).order(:seq).limit(per_page).to_a
    response = paginated(page.map { |person| @normalizer.contact(person) }, page.last&.seq, per_page)
    response['total_count'] = scope.count if starting_after.blank?
    response
  end

  def list_conversations(starting_after:, per_page:)
    scope = threads_scope
    page = scope.where('seq > ?', starting_after.to_i).order(:seq).limit(per_page).to_a
    response = paginated(page.map { |thread| @normalizer.conversation_summary(thread) }, page.last&.seq, per_page)
    response['total_count'] = scope.count if starting_after.blank?
    response
  end

  def retrieve_conversation(id)
    thread = DataImports::Salesforce::Staging::Thread.find(id)
    person = DataImports::Salesforce::Staging::Person.find(thread.person_key)
    parts = DataImports::Salesforce::Staging::Part.where(thread_key: id).order(:created_at, :part_id).to_a
    @normalizer.conversation(thread, person, parts)
  end

  def retrieve_contact(id)
    @normalizer.contact(DataImports::Salesforce::Staging::Person.find(id))
  end

  def client_error?(_error)
    false
  end

  def placeholder_inbox_builder(account:)
    DataImports::Salesforce::InboxResolver.new(account: account)
  end

  def message_batch_builder(data_import:, conversation:, source_conversation:)
    DataImports::Salesforce::MessageBatchBuilder.new(data_import: data_import, conversation: conversation, source_conversation: source_conversation)
  end

  def activity_part?(_part)
    false
  end

  def source_message_importable?(source)
    DataImports::Salesforce::MessageBatchBuilder.source_message_importable?(source)
  end

  def activity_content(_part)
    nil
  end

  def already_imported_error_code
    ALREADY_IMPORTED_ERROR_CODE
  end

  def skipped_message_error_code
    SKIPPED_MESSAGE_ERROR_CODE
  end

  def truncated_parts_error_code
    TRUNCATED_PARTS_ERROR_CODE
  end

  def skipped_message_reason
    'blank_salesforce_message'
  end

  def contact_custom_attributes(contact_payload)
    contact_payload['custom'].to_h
  end

  # Lands in Contact#additional_attributes['source'] together with provider: 'salesforce'.
  def contact_source_metadata(contact_payload)
    { person_key: contact_payload['id'], salesforce: contact_payload['raw'].to_h }
  end

  def conversation_custom_attributes(conversation)
    conversation['custom'].to_h
  end

  def conversation_source_metadata(conversation)
    {
      thread_key: conversation['id'],
      sf_object: conversation['sf_object'],
      bucket: conversation['bucket'],
      subject: conversation['subject'],
      salesforce: conversation['raw'].to_h
    }.compact
  end

  def message_source_metadata(part)
    {
      part_id: part['id'],
      kind: part['kind'],
      status: part['status'],
      automated: part['automated'],
      from: part['from'],
      to: part['to'],
      cc: part['cc'],
      pyc_number: part['pyc_number'],
      salesforce: part['raw'].to_h
    }.compact
  end

  def timestamp_for(value)
    return Time.current if value.blank?

    value.is_a?(Numeric) || value.to_s.match?(/\A-?\d+(?:\.\d+)?\z/) ? Time.zone.at(value.to_f) : Time.zone.parse(value.to_s)
  end

  private

  def people_scope
    DataImports::Salesforce::Staging::Person.in_scope(@phase, @since)
  end

  def threads_scope
    DataImports::Salesforce::Staging::Thread.in_scope(@phase, @since)
  end

  # A short page means we are done; a full page may have more.
  def paginated(records, last_seq, per_page)
    {
      'data' => records,
      'pages' => { 'next' => records.size == per_page ? { 'starting_after' => last_seq } : nil }
    }
  end
end
