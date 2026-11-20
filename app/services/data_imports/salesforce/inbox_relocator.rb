# rubocop:disable Rails/SkipsModelValidations
# Moves imported history from one inbox into another: contact inboxes (re-keyed to the real address/number
# when the target is an email or Twilio inbox), conversations and messages. A placeholder source inbox is
# deleted once it is empty.
class DataImports::Salesforce::InboxRelocator
  Result = Struct.new(:conversations, :messages, :contact_inboxes, :deleted_placeholder, keyword_init: true)

  def initialize(from:, to:)
    raise ArgumentError, 'Both inboxes must belong to the same account.' unless from.account_id == to.account_id

    @from = from
    @to = to
  end

  def perform
    moved_contact_inboxes = 0
    ContactInbox.where(inbox_id: @from.id).find_each do |contact_inbox|
      relocate_contact_inbox(contact_inbox)
      moved_contact_inboxes += 1
    end
    conversations = Conversation.where(inbox_id: @from.id).update_all(inbox_id: @to.id)
    messages = Message.where(inbox_id: @from.id).update_all(inbox_id: @to.id)
    deleted = delete_placeholder
    Result.new(conversations: conversations, messages: messages, contact_inboxes: moved_contact_inboxes, deleted_placeholder: deleted)
  end

  private

  def relocate_contact_inbox(contact_inbox)
    source_id = case @to.channel_type
                when 'Channel::Email' then contact_inbox.contact.email.presence
                when 'Channel::TwilioSms' then contact_inbox.contact.phone_number.presence
                end || contact_inbox.source_id
    existing = ContactInbox.find_by(inbox_id: @to.id, source_id: source_id)
    if existing && existing.contact_id == contact_inbox.contact_id
      Conversation.where(contact_inbox_id: contact_inbox.id).update_all(contact_inbox_id: existing.id)
      contact_inbox.delete
    elsif existing
      contact_inbox.update_columns(inbox_id: @to.id)
    else
      contact_inbox.update_columns(inbox_id: @to.id, source_id: source_id)
    end
  end

  def delete_placeholder
    return false unless @from.channel_type == 'Channel::Api' && @from.channel.additional_attributes&.dig('import_placeholder')

    @from.destroy!
    true
  end
end
# rubocop:enable Rails/SkipsModelValidations
