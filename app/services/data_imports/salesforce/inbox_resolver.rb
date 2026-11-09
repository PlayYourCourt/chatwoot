# Resolves a thread bucket to an inbox: a live email/Twilio inbox when one matches the address or
# number, otherwise a placeholder API inbox created once per bucket (same mechanism as the Freshdesk
# and Intercom imports). Placeholders remember their address/number so `salesforce:relocate_inbox`
# can move the history into a real inbox later.
class DataImports::Salesforce::InboxResolver < DataImports::PlaceholderInboxBuilder
  def initialize(account:)
    super(account: account, provider: 'salesforce', source_bucket: DataImports::Salesforce::SourceBucket)
    @live = {}
  end

  def inbox_for(source_type)
    live_inbox_for(source_type) || super
  end

  private

  def live_inbox_for(bucket)
    return @live[bucket] if @live.key?(bucket)

    @live[bucket] = find_live_inbox(bucket)
  end

  def find_live_inbox(bucket)
    if (address = DataImports::Salesforce::SourceBucket.email_address(bucket))
      @account.email_channels.where('LOWER(email) = ?', address.downcase).first&.inbox
    elsif (number = DataImports::Salesforce::SourceBucket.phone_number(bucket))
      @account.twilio_sms.find_by(phone_number: number)&.inbox
    end
  end

  def create_placeholder_channel(bucket)
    @account.api_channels.create!(
      additional_attributes: {
        source_provider: @provider,
        source_bucket: bucket[:key],
        import_placeholder: true,
        agent_reply_time_window: AGENT_REPLY_TIME_WINDOW_HOURS,
        email: DataImports::Salesforce::SourceBucket.email_address(bucket[:key]),
        phone_number: DataImports::Salesforce::SourceBucket.phone_number(bucket[:key])
      }.compact
    )
  end
end
