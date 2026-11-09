# Creates the labels and custom attribute definitions the Salesforce import fills in. Idempotent.
class DataImports::Salesforce::Setup
  LABEL_COLORS = {
    'case' => '#1f93ff', 'opportunity' => '#8b5cf6', 'lead' => '#f59e0b', 'customer' => '#10b981', 'freshdesk' => '#6b7280',
    'membership' => '#ec4899', 'lessons' => '#14b8a6', 'league' => '#0ea5e9', 'closed-won' => '#16a34a', 'closed-lost' => '#dc2626',
    'converted' => '#22c55e', 'bounce' => '#9ca3af', 'support' => '#3b82f6', 'membership-support' => '#db2777', 'lessons-support' => '#0d9488',
    'pro-communication' => '#7c3aed', 'bracket-challenge-support' => '#f97316', 'new-membership-lead' => '#e11d48', 'new-lead' => '#eab308',
    'support-ticket' => '#2563eb', 'sales-followup' => '#a855f7', 'switch-coach' => '#0891b2', 'low-credits-lead' => '#ca8a04',
    'nurturing' => '#fb923c', 'new' => '#fde047', 'assigned' => '#60a5fa', 'expressed-interest' => '#c084fc'
  }.freeze

  # key => [display name, type, list values]
  CONTACT_ATTRIBUTES = {
    'salesforce_id' => ['Salesforce ID', 'text'],
    'sf_account_id' => ['Salesforce Account ID', 'text'],
    'sf_lead_ids' => ['Salesforce Lead IDs', 'text'],
    'sf_merged_ids' => ['Merged Salesforce IDs', 'text'],
    'freshdesk_id' => ['Freshdesk ID', 'text'],
    'pyc_user_id' => ['PYC User ID', 'text'],
    'stripe_customer_id' => ['Stripe Customer ID', 'text'],
    'shopify_id' => ['Shopify ID', 'text'],
    'lead_type' => ['Lead Type', 'list', %w[Membership Lessons League]],
    'lead_status' => ['Lead Status', 'list', ['New', 'Assigned', 'Nurturing', 'Converted', 'Lost - Non Responsive']],
    'lead_source' => ['Lead Source', 'text'],
    'owner' => %w[Owner text],
    'company' => %w[Company text],
    'is_pro' => ['Is Pro', 'checkbox'],
    'skill_level' => ['Skill Level', 'list', %w[Beginner Intermediate Advanced Competitor]],
    'ntrp' => %w[NTRP text],
    'age_range' => ['Age Range', 'text'],
    'fitness' => %w[Fitness text],
    'lesson_goal' => ['Lesson Goal', 'text'],
    'lesson_taker' => ['Lesson Taker', 'text'],
    'preferred_time_of_day' => ['Preferred Time of Day', 'text'],
    'preferred_day' => ['Preferred Day', 'text'],
    'preferred_location' => ['Preferred Location', 'text'],
    'gender' => %w[Gender text],
    'postal_code' => ['Postal Code', 'text'],
    'timezone' => %w[Timezone text],
    'first_contact_at' => ['First Contact', 'date'],
    'last_inbound_contact_at' => ['Last Inbound Contact', 'date'],
    'support_profile_url' => ['Support Profile', 'link'],
    'decision_criteria' => ['Decision Criteria', 'text'],
    'legacy_agent_name' => ['Legacy Agent', 'text'],
    'drip_messages_sent' => ['Drip Messages Sent', 'number'],
    'last_drip_sms_at' => ['Last Drip SMS', 'date'],
    'exclude_from_drip' => ['Exclude From Drip', 'checkbox'],
    'email_opted_out' => ['Email Opted Out', 'checkbox'],
    'do_not_call' => ['Do Not Call', 'checkbox']
  }.freeze

  CONVERSATION_ATTRIBUTES = {
    'sf_object' => ['Salesforce Object', 'list', %w[case opportunity lead account freshdesk]],
    'salesforce_id' => ['Salesforce ID', 'text'],
    'case_number' => ['Case Number', 'text'],
    'case_origin' => ['Case Origin', 'text'],
    'case_type' => ['Case Type', 'text'],
    'priority' => ['Salesforce Priority', 'text'],
    'opp_stage' => ['Opportunity Stage', 'text'],
    'lead_status' => ['Lead Status', 'text'],
    'lead_source' => ['Lead Source', 'text'],
    'sf_owner' => ['Salesforce Owner', 'text'],
    'freshdesk_ticket_id' => ['Freshdesk Ticket ID', 'text'],
    'freshdesk_ticket_type' => ['Freshdesk Ticket Type', 'text'],
    'freshdesk_group' => ['Freshdesk Group', 'text'],
    'freshdesk_status' => ['Freshdesk Status', 'text'],
    'pyc_number' => ['PYC Number', 'text'],
    'source_address' => ['Source Address', 'text']
  }.freeze

  pattr_initialize [:account!]

  def perform
    LABEL_COLORS.each { |title, color| account.labels.find_or_create_by!(title: title) { |label| label.color = color } }
    define(:contact_attribute, CONTACT_ATTRIBUTES)
    define(:conversation_attribute, CONVERSATION_ATTRIBUTES)
    { labels: account.labels.count, custom_attribute_definitions: account.custom_attribute_definitions.count }
  end

  private

  def define(model, definitions)
    definitions.each do |key, (name, type, values)|
      account.custom_attribute_definitions.find_or_create_by!(attribute_key: key, attribute_model: model) do |definition|
        definition.attribute_display_name = name
        definition.attribute_display_type = type
        definition.attribute_values = values if values
      end
    end
  end
end
