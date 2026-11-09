class KlaviyoListener < BaseListener
  def message_created(event)
    message = extract_message_and_account(event)[0]
    return unless message.incoming?
    return if GlobalConfigService.load('KLAVIYO_PRIVATE_API_KEY', nil).blank?

    contact = message.conversation.contact
    return if contact.email.blank? && contact.phone_number.blank?

    mark_replied(contact)
    Klaviyo::PushEventJob.perform_later(message.id)
  end

  private

  def mark_replied(contact)
    return if contact.custom_attributes['flow_status'] == 'replied'

    contact.update!(custom_attributes: contact.custom_attributes.merge('flow_status' => 'replied'))
  end
end
