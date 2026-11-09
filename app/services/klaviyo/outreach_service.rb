class Klaviyo::OutreachService
  pattr_initialize [:account!, :user!, :params!]

  def perform
    contact = upsert_contact
    contact_inbox = ContactInboxBuilder.new(contact: contact, inbox: inbox).perform
    conversation = active_conversation(contact_inbox) || create_conversation(contact_inbox)
    tag_conversation(conversation)
    message = send_message(conversation)

    { contact_id: contact.id, conversation_id: conversation.id, message_id: message&.id }
  end

  private

  def inbox
    @inbox ||= account.inboxes.find(params[:inbox_id])
  end

  def upsert_contact
    contact = find_contact || account.contacts.new
    fill_blank_attributes(contact)
    contact.custom_attributes = contact.custom_attributes.merge(params[:custom_attributes].to_h) if params[:custom_attributes].present?
    contact.save!
    contact
  end

  # Only fills in what the contact is missing; never overwrites agent-edited values.
  def fill_blank_attributes(contact)
    %i[name email phone_number].each do |attribute|
      contact[attribute] = params[attribute] if contact[attribute].blank? && params[attribute].present?
    end
  end

  def find_contact
    contact = account.contacts.from_email(params[:email]) if params[:email].present?
    contact ||= account.contacts.find_by(phone_number: params[:phone_number]) if params[:phone_number].present?
    contact
  end

  def active_conversation(contact_inbox)
    contact_inbox.conversations.where.not(status: :resolved).order(created_at: :desc).first
  end

  # Snoozed with no snoozed_until means "until the contact replies": automated outreach stays out of
  # the open queue, and the first incoming message reopens it (Message#reopen_conversation).
  def create_conversation(contact_inbox)
    ConversationBuilder.new(params: ActionController::Parameters.new({ status: 'snoozed' }), contact_inbox: contact_inbox).perform
  end

  def tag_conversation(conversation)
    conversation.add_labels(params[:labels]) if params[:labels].present?
    return if params[:flow_step].blank?

    conversation.update!(custom_attributes: conversation.custom_attributes.merge('flow_step' => params[:flow_step]))
  end

  def send_message(conversation)
    return if params[:content].blank?

    Messages::MessageBuilder.new(user, conversation, { content: params[:content], message_type: 'outgoing' }).perform
  end
end
