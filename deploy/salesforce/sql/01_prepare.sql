-- Stage 1: helper functions, lookup tables and indexes on the raw export tables.
-- Idempotent. Runs in a few minutes on the full export (the index builds dominate).
SET client_min_messages = warning;
SET search_path = sf, public;

CREATE OR REPLACE FUNCTION sf.nz(v text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN v IS NULL OR btrim(v) = '' OR v IN ('null', '000000000000000AAA') THEN NULL ELSE btrim(v) END
$$;

CREATE OR REPLACE FUNCTION sf.ts(v text) RETURNS timestamptz LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN sf.nz(v) IS NULL THEN NULL ELSE sf.nz(v)::timestamp AT TIME ZONE 'UTC' END
$$;

-- E.164 for US-centric data: 10 digits -> +1, 11 digits starting with 1 -> +, otherwise 11-15 digits -> +digits.
CREATE OR REPLACE FUNCTION sf.phone_e164(v text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN d IS NULL OR d = '' THEN NULL
    WHEN length(d) = 10 THEN '+1' || d
    WHEN length(d) = 11 AND left(d, 1) = '1' THEN '+' || d
    WHEN length(d) BETWEEN 11 AND 15 AND left(d, 1) <> '0' THEN '+' || d
    ELSE NULL END
  FROM (SELECT regexp_replace(coalesce(sf.nz(v), ''), '\D', '', 'g') AS d) x
$$;

CREATE OR REPLACE FUNCTION sf.email_norm(v text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN e ~ '^[^@\s]+@[^@\s]+\.[^@\s]{2,}$' THEN e ELSE NULL END
  FROM (SELECT lower(sf.nz(v)) AS e) x
$$;

CREATE OR REPLACE FUNCTION sf.name_part(v text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN lower(btrim(coalesce(v, ''))) IN ('', 'null', 'none', 'na', 'n/a', 'test', 'unknown', '-', '.', '?', 'noname')
              THEN NULL ELSE btrim(v) END
$$;

-- label slug: lowercase, letters/digits/_/- only, >= 2 chars (Chatwoot Label title rule)
CREATE OR REPLACE FUNCTION sf.slug(v text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN length(s) >= 2 THEN s ELSE NULL END
  FROM (SELECT btrim(regexp_replace(regexp_replace(lower(coalesce(v, '')), '[^a-z0-9]+', '-', 'g'), '-+', '-', 'g'), '-') AS s) x
$$;

CREATE OR REPLACE FUNCTION sf.strip_html(v text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT btrim(regexp_replace(regexp_replace(regexp_replace(coalesce(v, ''),
           '<(br|/p|/div|/tr|/li)[^>]*>', E'\n', 'gi'), '<[^>]+>', '', 'g'), '&nbsp;', ' ', 'g'))
$$;

-- jsonb of all non-empty columns of a row (the "raw copy" that travels with every imported record)
CREATE OR REPLACE FUNCTION sf.raw(r anyelement) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(jsonb_object_agg(key, value), '{}'::jsonb)
  FROM jsonb_each_text(to_jsonb(r))
  WHERE value IS NOT NULL AND value NOT IN ('', 'null', '000000000000000AAA')
$$;

-- Purchased PYC numbers (names from Keith, 2026-11-08) + anything else seen in the purchased_number table.
DROP TABLE IF EXISTS sf.number_meta;
CREATE TABLE sf.number_meta (number text PRIMARY KEY, name text, owner_name text, default_object text);
INSERT INTO sf.number_meta VALUES
  ('+13019004377', 'Adam', 'Adam Soule', 'Opportunity'),
  ('+13019004237', 'Missi', 'Adam Soule', 'Opportunity'),
  ('+13019457136', 'Zach', 'Zach Howard', 'Opportunity'),
  ('+13018571552', 'Memby CA', 'SMS queue', 'Case'),
  ('+13013752751', 'Lesson Sales', 'SMS queue', 'Case'),
  ('+13013752315', 'Generic Sales', 'SMS queue', 'Case'),
  ('+13013811305', 'Membership Support', 'SMS queue', 'Case'),
  ('+13018572245', 'Bracket Challenge Support', 'SMS queue', 'Case'),
  ('+13013811580', 'Bracket Challenge CA', 'SMS queue', 'Case'),
  ('+13015179538', 'Broadcast Promo', 'SMS queue', 'Case'),
  ('+13017158953', 'App Notification', 'SMS queue', 'Case'),
  ('+18045811778', 'TestNumber', 'PYC Server', 'Case'),
  ('+18043526275', 'TestNumber2', 'PYC Server', 'Case');
INSERT INTO sf.number_meta (number, name, owner_name, default_object)
SELECT sf.nz(tabyot__number__c), coalesce(sf.nz(tabyot__friendly_name__c), sf.nz(tabyot__number__c)), NULL, NULL
FROM sf.purchased_number
WHERE sf.nz(tabyot__number__c) IS NOT NULL
ON CONFLICT (number) DO NOTHING;

-- Owner names: users + the four case queues (names inferred from their contents).
DROP TABLE IF EXISTS sf.owner_name;
CREATE TABLE sf.owner_name AS
SELECT id, btrim(concat_ws(' ', sf.nz(firstname), sf.nz(lastname))) AS name, 'user' AS kind FROM sf.sf_user
UNION ALL SELECT * FROM (VALUES
  ('00GHp0000063jlLMAQ', 'Support queue (email/web)', 'queue'),
  ('00GHp0000063FkIMAU', 'SMS queue', 'queue'),
  ('00GHp0000063r2mMAA', 'Support queue 2 (email)', 'queue'),
  ('00GHp0000063r2rMAA', 'Auto-replies / bounces queue', 'queue')) q(id, name, kind);
CREATE UNIQUE INDEX ON sf.owner_name (id);

-- Phone numbers that are obviously placeholders.
DROP TABLE IF EXISTS sf.phone_blocklist;
CREATE TABLE sf.phone_blocklist (phone text PRIMARY KEY, reason text);
INSERT INTO sf.phone_blocklist
SELECT p, 'pattern' FROM (
  SELECT sf.phone_e164(d) AS p FROM unnest(ARRAY['1234567890','0123456789','2223334444','1112223333','5551234567','5555555555',
    '1111111111','2222222222','3333333333','4444444444','6666666666','7777777777','8888888888','9999999999','0000000000']) d
) x WHERE p IS NOT NULL
ON CONFLICT DO NOTHING;

DROP TABLE IF EXISTS sf.junk_email;
CREATE TABLE sf.junk_email (pattern text PRIMARY KEY);
INSERT INTO sf.junk_email VALUES ('^none@'), ('^noemail'), ('^no-email'), ('^test@'), ('^test[0-9]*@'), ('@example\.com$'),
  ('@test\.com$'), ('@testt?\.'), ('^fake@'), ('^na@'), ('^unknown@'), ('^null@'), ('@playyourcourt\.test$');

-- Indexes on the raw tables (join keys only).
CREATE INDEX IF NOT EXISTS contact_id_idx ON sf.contact (id);
CREATE INDEX IF NOT EXISTS contact_accountid_idx ON sf.contact (accountid);
CREATE INDEX IF NOT EXISTS contact_email_idx ON sf.contact (lower(email));
CREATE INDEX IF NOT EXISTS contact_legacy_idx ON sf.contact (pyc_legacy_id__c);
CREATE INDEX IF NOT EXISTS contact_pycuser_idx ON sf.contact (pyc_user_id__c);
CREATE INDEX IF NOT EXISTS account_id_idx ON sf.account (id);
CREATE INDEX IF NOT EXISTS account_personcontact_idx ON sf.account (personcontactid);
CREATE INDEX IF NOT EXISTS lead_id_idx ON sf.lead (id);
CREATE INDEX IF NOT EXISTS lead_email_idx ON sf.lead (lower(email));
CREATE INDEX IF NOT EXISTS lead_converted_idx ON sf.lead (convertedcontactid);
CREATE INDEX IF NOT EXISTS lead_pycuser_idx ON sf.lead (pyc_user_id__c);
CREATE INDEX IF NOT EXISTS case_id_idx ON sf."case" (id);
CREATE INDEX IF NOT EXISTS case_legacy_idx ON sf."case" (pyc_legacy_id__c);
CREATE INDEX IF NOT EXISTS opportunity_id_idx ON sf.opportunity (id);
CREATE INDEX IF NOT EXISTS opportunity_legacy_idx ON sf.opportunity (pyc_legacy_id__c);
CREATE INDEX IF NOT EXISTS opportunity_account_idx ON sf.opportunity (accountid);
CREATE INDEX IF NOT EXISTS email_parent_idx ON sf.email_message (parentid);
CREATE INDEX IF NOT EXISTS email_msgid_idx ON sf.email_message (messageidentifier);
CREATE INDEX IF NOT EXISTS interaction_record_idx ON sf.interaction (tabyot__record_id__c);
CREATE INDEX IF NOT EXISTS interaction_status_idx ON sf.interaction (tabyot__status__c);
CREATE INDEX IF NOT EXISTS interaction_media_parent_idx ON sf.interaction_media (tabyot__text_anything_interaction__c);
CREATE INDEX IF NOT EXISTS note_opp_idx ON sf.legacy_note (opportunity__c);
CREATE INDEX IF NOT EXISTS note_case_idx ON sf.legacy_note (case__c);
CREATE INDEX IF NOT EXISTS note_ticket_idx ON sf.legacy_note (ticket_id__c);
CREATE INDEX IF NOT EXISTS staging_legacy_idx ON sf.staging (pyc_legacy_id__c);
CREATE INDEX IF NOT EXISTS staging_case_idx ON sf.staging (caseid__c);
CREATE INDEX IF NOT EXISTS staging_opp_idx ON sf.staging (oppid__c);
CREATE INDEX IF NOT EXISTS staging_account_idx ON sf.staging (account_id__c);
ANALYZE;
