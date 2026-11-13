# Minimal client for the Klaviyo APIs Chatwoot calls: Create Event and the SMS consent jobs.
# https://developers.klaviyo.com/en/reference/create_event
# https://developers.klaviyo.com/en/reference/bulk_subscribe_profiles
class Klaviyo::Client
  include HTTParty
  base_uri 'https://a.klaviyo.com/api'

  REVISION = '2026-10-15'.freeze

  class ApiError < StandardError; end

  def initialize(api_key)
    @api_key = api_key
  end

  def create_event(metric:, profile:, properties: {}, unique_id: nil)
    post('/events', {
           type: 'event',
           attributes: {
             metric: { data: { type: 'metric', attributes: { name: metric } } },
             profile: { data: { type: 'profile', attributes: profile } },
             properties: properties,
             unique_id: unique_id
           }.compact
         })
  end

  # Account-level SMS marketing consent (no list). A START reply is the consent, so it is recorded as a
  # historical import with its own timestamp: no double opt-in message, no "added to list" flows.
  def subscribe_sms(phone_number:, consented_at:)
    post('/profile-subscription-bulk-create-jobs', {
           type: 'profile-subscription-bulk-create-job',
           attributes: {
             historical_import: true,
             custom_source: 'Chatwoot SMS reply',
             profiles: { data: [sms_profile(phone_number, consent: 'SUBSCRIBED', consented_at: consented_at.iso8601)] }
           }
         })
  end

  # Up to 100 numbers per call.
  def unsubscribe_sms(phone_numbers:)
    post('/profile-subscription-bulk-delete-jobs', {
           type: 'profile-subscription-bulk-delete-job',
           attributes: { profiles: { data: phone_numbers.map { |number| sms_profile(number, consent: 'UNSUBSCRIBED') } } }
         })
  end

  private

  def sms_profile(phone_number, **consent)
    { type: 'profile', attributes: { phone_number: phone_number, subscriptions: { sms: { marketing: consent } } } }
  end

  def post(path, data)
    response = self.class.post(path, headers: headers, body: { data: data }.to_json)
    raise ApiError, "Klaviyo #{response.code}: #{response.body}" unless response.success?

    response
  end

  def headers
    {
      'Authorization' => "Klaviyo-API-Key #{@api_key}",
      'revision' => REVISION,
      'Content-Type' => 'application/vnd.api+json',
      'Accept' => 'application/vnd.api+json'
    }
  end
end
