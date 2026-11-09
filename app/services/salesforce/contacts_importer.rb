# Imports Salesforce Leads/Contacts from a CSV export into an account's contacts.
#
# Expected CSV headers (extra columns are ignored):
#   salesforce_id, first_name, last_name, email, phone, company, sf_account_id,
#   lead_status, lead_source, owner
#
# Rows are matched on salesforce_id, then email, then phone, so the import is re-runnable.
# Phone numbers are normalised to E.164 (US default). Rows with no usable identifier are skipped.
class Salesforce::ContactsImporter
  CONTACT_ATTRIBUTES = {
    'salesforce_id' => 'Salesforce ID',
    'sf_account_id' => 'Salesforce Account ID',
    'company' => 'Company',
    'lead_status' => 'Lead Status',
    'lead_source' => 'Lead Source',
    'owner' => 'Owner'
  }.freeze

  BATCH_SIZE = 500

  pattr_initialize [:account!, :path!, { default_country: :US }]

  def perform
    ensure_attribute_definitions
    stats = { created: 0, updated: 0, skipped: 0, failed: 0 }

    CSV.foreach(path, headers: true).with_index(2).each_slice(BATCH_SIZE) do |rows|
      Contact.transaction { rows.each { |row, line| import_row(row, line, stats) } }
      Rails.logger.info("[Salesforce::ContactsImporter] #{stats}")
    end

    stats
  end

  private

  def ensure_attribute_definitions
    CONTACT_ATTRIBUTES.each do |key, display_name|
      account.custom_attribute_definitions.find_or_create_by!(attribute_key: key, attribute_model: 'contact_attribute') do |definition|
        definition.attribute_display_name = display_name
        definition.attribute_display_type = 'text'
      end
    end
  end

  def import_row(row, line, stats)
    identity = extract_identity(row)
    return stats[:skipped] += 1 if identity.values.all?(&:blank?)

    contact = find_contact(identity) || account.contacts.new
    result = contact.new_record? ? :created : :updated
    assign_attributes(contact, row, identity)
    contact.save!
    stats[result] += 1
  rescue ActiveRecord::RecordInvalid => e
    stats[:failed] += 1
    Rails.logger.warn("[Salesforce::ContactsImporter] line #{line} (#{identity[:salesforce_id]}): #{e.message}")
  end

  def extract_identity(row)
    {
      salesforce_id: row['salesforce_id'].to_s.strip.presence,
      email: row['email'].to_s.strip.downcase.presence,
      phone: normalize_phone(row['phone'])
    }
  end

  def find_contact(identity)
    contact = account.contacts.find_by("custom_attributes->>'salesforce_id' = ?", identity[:salesforce_id]) if identity[:salesforce_id]
    contact ||= account.contacts.from_email(identity[:email]) if identity[:email]
    contact ||= account.contacts.find_by(phone_number: identity[:phone]) if identity[:phone]
    contact
  end

  def assign_attributes(contact, row, identity)
    name = [row['first_name'], row['last_name']].map { |part| part.to_s.strip }.compact_blank.join(' ')
    contact.name = name if name.present?
    contact.email ||= identity[:email]
    contact.phone_number ||= identity[:phone]
    contact.custom_attributes = contact.custom_attributes.merge(custom_attributes_from(row, identity))
  end

  def custom_attributes_from(row, identity)
    CONTACT_ATTRIBUTES.keys.index_with { |key| row[key].to_s.strip.presence }.merge('salesforce_id' => identity[:salesforce_id]).compact
  end

  def normalize_phone(raw)
    return if raw.blank?

    number = TelephoneNumber.parse(raw.to_s.strip, default_country)
    number.valid? ? number.e164_number : nil
  end
end
