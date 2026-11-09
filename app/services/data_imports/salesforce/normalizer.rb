# Shapes staging rows into the payloads DataImports::Importer expects (the same shapes the Freshdesk
# and Intercom normalizers produce). Timestamps are Unix integers because the importer validates them.
class DataImports::Salesforce::Normalizer
  def contact(person)
    {
      'id' => person.person_key,
      'name' => person.name,
      'email' => person.email,
      'phone' => person.phone,
      'external_id' => person.identifier,
      'contact_type' => person.contact_type,
      'city' => person.city,
      'country' => person.country,
      'created_at' => epoch(person.created_at),
      'updated_at' => epoch(person.updated_at),
      'last_seen_at' => epoch(person.updated_at),
      'custom' => person.custom || {},
      'raw' => person.raw || {}
    }
  end

  def conversation_summary(thread)
    { 'id' => thread.thread_key, 'source' => { 'type' => thread.bucket } }
  end

  def conversation(thread, person, parts)
    {
      'id' => thread.thread_key,
      'created_at' => epoch(thread.created_at),
      'updated_at' => epoch(thread.last_at),
      'status' => thread.status,
      'bucket' => thread.bucket,
      'subject' => thread.subject,
      'labels' => Array(thread.labels),
      'sf_object' => thread.sf_object,
      'custom' => thread.custom || {},
      'raw' => thread.raw || {},
      'source' => source(thread, person),
      'contacts' => { 'contacts' => [contact(person)] },
      'conversation_parts' => {
        'conversation_parts' => parts.map { |part| message(part) },
        'total_count' => parts.size
      }
    }
  end

  private

  # The first message is the record's description, when it has one. Subject is only included
  # alongside a body so SMS-only threads do not get a synthetic "SMS with Adam" message.
  def source(thread, person)
    author_type = thread.first_author == 'admin' ? 'admin' : 'contact'
    payload = { 'id' => thread.thread_key, 'type' => thread.bucket, 'author' => { 'type' => author_type, 'id' => person.person_key } }
    return payload if thread.first_body.blank?

    payload.merge('subject' => thread.subject, 'body' => thread.first_body)
  end

  def message(part)
    {
      'id' => part.part_id,
      'kind' => part.kind,
      'part_type' => part.direction == 'note' ? 'note' : 'comment',
      'body' => part.body,
      'subject' => (part.subject if part.kind == 'email'),
      'created_at' => epoch(part.created_at),
      'status' => part.status,
      'automated' => part.automated,
      'from' => part.from_addr,
      'to' => part.to_addr,
      'cc' => part.cc_addr,
      'pyc_number' => part.pyc_number,
      'raw' => part.raw || {},
      'author' => author(part)
    }.compact
  end

  def author(part)
    return { 'type' => 'admin', 'name' => part.author_name, 'email' => part.from_addr }.compact unless part.direction == 'incoming'

    { 'type' => 'contact', 'name' => part.author_name, 'email' => part.from_addr }.compact
  end

  def epoch(time)
    time&.to_i
  end
end
