class KlaviyoListener < BaseListener
  # Twilio's default opt-out / opt-in keywords, matched on the reply's letters only ("Stop." counts).
  SMS_OPT_OUT_KEYWORDS = %w[STOP STOPALL UNSUBSCRIBE CANCEL END QUIT REVOKE OPTOUT].freeze
  SMS_OPT_IN_KEYWORDS = %w[START UNSTOP YES].freeze

  def message_created(event)
    message = extract_message_and_account(event)[0]
    return unless message.incoming?

    contact = message.conversation.contact
    record_sms_consent(message, contact) if message.inbox.twilio? && message.inbox.channel.sms?
    return if klaviyo_api_key.blank?
    return if contact.email.blank? && contact.phone_number.blank?

    # opt-outs count as replies too: either way the nurture flow stops
    mark_replied(contact)
    Klaviyo::PushEventJob.perform_later(message.id)
  end

  private

  # sms_opted_out_at holds when the contact texted STOP; a later START clears it. Opt-in keywords only
  # count after an opt-out, so an ordinary "yes" to a question is not taken as marketing consent.
  def record_sms_consent(message, contact)
    keyword = message.content.to_s.upcase.gsub(/[^A-Z]/, '')
    opted_out = SMS_OPT_OUT_KEYWORDS.include?(keyword)
    return unless opted_out || (SMS_OPT_IN_KEYWORDS.include?(keyword) && contact.custom_attributes['sms_opted_out_at'].present?)

    attributes = contact.custom_attributes.except('sms_opted_out_at')
    attributes['sms_opted_out_at'] = message.created_at.iso8601 if opted_out
    contact.update!(custom_attributes: attributes)
    return if klaviyo_api_key.blank? || contact.phone_number.blank?

    Klaviyo::SmsConsentJob.perform_later(contact.phone_number, opted_out, message.created_at)
  end

  def mark_replied(contact)
    return if contact.custom_attributes['flow_status'] == 'replied'

    contact.update!(custom_attributes: contact.custom_attributes.merge('flow_status' => 'replied'))
  end

  def klaviyo_api_key
    GlobalConfigService.load('KLAVIYO_PRIVATE_API_KEY', nil)
  end
end
