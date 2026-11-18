class Klaviyo::OutreachService
  pattr_initialize [:account!, :user!, :params!]

  def perform
    contact = upsert_contact
    return { contact_id: contact.id } if params[:content].blank? # contact-only upsert, no conversation

    contact_inbox = ContactInboxBuilder.new(contact: contact, inbox: inbox).perform
    conversation = active_conversation(contact_inbox) || create_conversation(contact_inbox)
    tag_conversation(conversation)
    message = send_message(conversation)

    { contact_id: contact.id, conversation_id: conversation.id, message_id: message.id }
  end

  private

  def inbox
    @inbox ||= account.inboxes.find(params[:inbox_id])
  end

  def upsert_contact
    contact = find_contact || account.contacts.new
    fill_blank_attributes(contact)
    adopt_phone_number(contact)
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

  # A contact matched by email with another number on file: the number just given is the one to text.
  # The old one is kept for reference.
  def adopt_phone_number(contact)
    return if params[:phone_number].blank? || contact.phone_number == params[:phone_number]

    contact.additional_attributes = contact.additional_attributes.to_h.merge('previous_phone_number' => contact.phone_number)
    contact.phone_number = params[:phone_number]
  end

  # Phone first: SMS outreach must reach the number given, even when the email belongs to another contact.
  def find_contact
    contact = account.contacts.find_by(phone_number: params[:phone_number]) if params[:phone_number].present?
    contact ||= account.contacts.from_email(params[:email]) if params[:email].present?
    contact
  end

  def active_conversation(contact_inbox)
    contact_inbox.conversations.where.not(status: :resolved).order(created_at: :desc).first
  end

  # Pending keeps automated outreach out of the open queue; an automation rule (message created, incoming,
  # status pending) opens it when the contact replies. Snoozing stays a manual agent action.
  def create_conversation(contact_inbox)
    ConversationBuilder.new(params: ActionController::Parameters.new({ status: 'pending' }), contact_inbox: contact_inbox).perform
  end

  def tag_conversation(conversation)
    conversation.add_labels(params[:labels]) if params[:labels].present?
    return if params[:flow_step].blank?

    conversation.update!(custom_attributes: conversation.custom_attributes.merge('flow_step' => params[:flow_step]))
  end

  def send_message(conversation)
    Messages::MessageBuilder.new(user, conversation, { content: params[:content], message_type: 'outgoing' }).perform
  end
end
