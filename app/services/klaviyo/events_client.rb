# Minimal client for Klaviyo's Create Event API.
# https://developers.klaviyo.com/en/reference/create_event
class Klaviyo::EventsClient
  include HTTParty
  base_uri 'https://a.klaviyo.com/api'

  REVISION = '2024-10-15'.freeze

  class ApiError < StandardError; end

  def initialize(api_key)
    @api_key = api_key
  end

  def create_event(metric:, profile:, properties: {}, unique_id: nil)
    body = {
      data: {
        type: 'event',
        attributes: {
          metric: { data: { type: 'metric', attributes: { name: metric } } },
          profile: { data: { type: 'profile', attributes: profile } },
          properties: properties,
          unique_id: unique_id
        }.compact
      }
    }

    response = self.class.post('/events', headers: headers, body: body.to_json)
    raise ApiError, "Klaviyo #{response.code}: #{response.body}" unless response.success?

    response
  end

  private

  def headers
    {
      'Authorization' => "Klaviyo-API-Key #{@api_key}",
      'revision' => REVISION,
      'Content-Type' => 'application/vnd.api+json',
      'Accept' => 'application/vnd.api+json'
    }
  end
end
