-- SELECT-only access to the Chatwoot tables the Gate reads (deploy/n8n/DESIGN.md "SQL on Chatwoot's database").
-- Run inside the Chatwoot database by deploy/n8n/setup_db.sh. Idempotent.
SET client_min_messages = warning;
GRANT USAGE ON SCHEMA public TO chatwoot_readonly;
GRANT SELECT ON contacts, contact_inboxes, conversations, messages, inboxes, working_hours, users,
                labels, tags, taggings, custom_attribute_definitions TO chatwoot_readonly;
