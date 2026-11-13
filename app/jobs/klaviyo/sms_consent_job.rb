# Mirrors a contact's STOP / START SMS reply into Klaviyo's SMS marketing consent, so SMS sent from
# Klaviyo itself respects opt-outs taken in Chatwoot (Twilio already blocks Chatwoot's own sends).
class Klaviyo::SmsConsentJob < ApplicationJob
  queue_as :low

  def perform(phone_number, opted_out, replied_at)
    client = Klaviyo::Client.new(GlobalConfigService.load('KLAVIYO_PRIVATE_API_KEY', nil))
    if opted_out
      client.unsubscribe_sms(phone_numbers: [phone_number])
    else
      client.subscribe_sms(phone_number: phone_number, consented_at: replied_at)
    end
  end
end
