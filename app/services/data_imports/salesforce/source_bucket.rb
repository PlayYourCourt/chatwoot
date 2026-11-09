# Maps a thread bucket (computed by deploy/salesforce/sql/04_threads.sql) to a placeholder inbox name.
#   email:<address> | sms:<E.164 number> | web-forms | freshdesk-sales | freshdesk-support | support-tasks
class DataImports::Salesforce::SourceBucket
  # Purchased PYC numbers (names from the TextAnything meta table, 2026-11-08).
  NUMBER_NAMES = {
    '+13019004377' => 'Adam',
    '+13019004237' => 'Missi',
    '+13019457136' => 'Zach',
    '+13018571552' => 'Memby CA',
    '+13013752751' => 'Lesson Sales',
    '+13013752315' => 'Generic Sales',
    '+13013811305' => 'Membership Support',
    '+13018572245' => 'Bracket Challenge Support',
    '+13013811580' => 'Bracket Challenge CA',
    '+13015179538' => 'Broadcast Promo',
    '+13017158953' => 'App Notification',
    '+18045811778' => 'TestNumber',
    '+18043526275' => 'TestNumber2'
  }.freeze

  FIXED = {
    'web-forms' => 'Web forms',
    'freshdesk-sales' => 'Freshdesk Sales',
    'freshdesk-support' => 'Freshdesk Support',
    'support-tasks' => 'Support tasks'
  }.freeze

  def self.for(bucket)
    bucket = bucket.to_s
    kind, value = bucket.split(':', 2)
    name = case kind
           when 'email' then "Email #{value}"
           when 'sms' then value == 'unknown' ? 'SMS (unknown number)' : "SMS #{NUMBER_NAMES.fetch(value, value)} (#{value})"
           else FIXED.fetch(bucket, bucket.titleize)
           end
    { key: bucket.presence || 'support-tasks', name: name }
  end

  def self.email_address(bucket)
    bucket.to_s.delete_prefix('email:') if bucket.to_s.start_with?('email:')
  end

  def self.phone_number(bucket)
    return unless bucket.to_s.start_with?('sms:')

    number = bucket.to_s.delete_prefix('sms:')
    number unless number == 'unknown'
  end
end
