# Pushes a "Chatwoot Reply" event to the Klaviyo profile for the contact who sent an incoming
# message. Nurture flows use a flow filter on this metric to stop once a lead replies.
class Klaviyo::PushEventJob < ApplicationJob
  queue_as :low

  METRIC = 'Chatwoot Reply'.freeze

  def perform(message_id)
    message = Message.find_by(id: message_id)
    return if message.blank?

    api_key = GlobalConfigService.load('KLAVIYO_PRIVATE_API_KEY', nil)
    return if api_key.blank?

    contact = message.conversation.contact
    profile = { email: contact.email, phone_number: contact.phone_number }.compact_blank
    return if profile.empty?

    Klaviyo::Client.new(api_key).create_event(
      metric: METRIC,
      profile: profile,
      properties: {
        inbox: message.inbox.name,
        channel: message.inbox.channel_type,
        conversation_id: message.conversation.display_id,
        contact_id: contact.id
      },
      unique_id: "chatwoot-message-#{message.id}"
    )
  end
end
