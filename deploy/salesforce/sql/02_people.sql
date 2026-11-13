-- Stage 2: people. One row per real person, built from Contact⋈Account, then Leads, then Freshdesk
-- requesters that never became a Salesforce record. Produces:
--   sf.people        the contact payloads the importer reads
--   sf.person_alias  (kind, sf_id) -> person_key, used by stage 3 to attach threads
--   sf.cleaning_log  what was blanked/merged and why
SET client_min_messages = warning;
SET search_path = sf, public;

DROP TABLE IF EXISTS sf.cleaning_log;
CREATE TABLE sf.cleaning_log (stage text, action text, sf_id text, detail text);

------------------------------------------------------------------------------------------------
-- 2a. Contacts cleaned (one row per Salesforce Contact)
------------------------------------------------------------------------------------------------
DROP TABLE IF EXISTS sf.c_clean;
CREATE UNLOGGED TABLE sf.c_clean AS
SELECT c.id,
       sf.nz(c.accountid)                                   AS account_id,
       sf.name_part(c.firstname)                            AS first_name,
       sf.name_part(c.lastname)                             AS last_name,
       sf.email_norm(c.email)                               AS email,
       coalesce(sf.phone_e164(c.mobilephone), sf.phone_e164(c.phone), sf.phone_e164(c.homephone)) AS phone,
       sf.nz(c.pyc_legacy_id__c)                            AS freshdesk_id,
       coalesce(sf.nz(c.pyc_user_id__c), sf.nz(c.pyc_legacy_cf_pyc_id__c)) AS pyc_user_id,
       sf.ts(c.createddate)                                 AS created_at,
       sf.ts(c.lastmodifieddate)                            AS updated_at,
       (sf.nz(c.email) IS NOT NULL)::int + (sf.nz(c.mobilephone) IS NOT NULL)::int + (sf.nz(c.pyc_user_id__c) IS NOT NULL)::int
         + (sf.nz(c.pyc_legacy_id__c) IS NOT NULL)::int + (sf.name_part(c.lastname) IS NOT NULL)::int
         + (sf.nz(c.skill_level__c) IS NOT NULL)::int + (sf.nz(a.stripe_customer_id__c) IS NOT NULL)::int AS filled,
       a.id                                                 AS acct_id
FROM sf.contact c
LEFT JOIN sf.account a ON a.id = c.accountid;
CREATE INDEX ON sf.c_clean (id);
CREATE INDEX ON sf.c_clean (email);
CREATE INDEX ON sf.c_clean (phone);
CREATE INDEX ON sf.c_clean (account_id);
CREATE INDEX ON sf.c_clean (freshdesk_id);
CREATE INDEX ON sf.c_clean (pyc_user_id);

-- junk emails -> blank
WITH junk AS (
  SELECT c.id, c.email FROM sf.c_clean c JOIN sf.junk_email j ON c.email ~ j.pattern
)
, logged AS (INSERT INTO sf.cleaning_log SELECT 'people', 'blank_junk_email', id, email FROM junk RETURNING 1)
UPDATE sf.c_clean c SET email = NULL FROM junk WHERE c.id = junk.id;

-- phones shared by more than 3 contacts are placeholders -> blocklist + blank
INSERT INTO sf.phone_blocklist (phone, reason)
SELECT phone, 'shared_by_' || count(*) FROM sf.c_clean WHERE phone IS NOT NULL GROUP BY phone HAVING count(*) > 3
ON CONFLICT DO NOTHING;
WITH bl AS (SELECT c.id, c.phone FROM sf.c_clean c JOIN sf.phone_blocklist b ON b.phone = c.phone)
, logged AS (INSERT INTO sf.cleaning_log SELECT 'people', 'blank_blocklisted_phone', id, phone FROM bl RETURNING 1)
UPDATE sf.c_clean c SET phone = NULL FROM bl WHERE c.id = bl.id;

------------------------------------------------------------------------------------------------
-- 2b. Merge contacts that share an email: the oldest, most-filled record wins.
------------------------------------------------------------------------------------------------
DROP TABLE IF EXISTS sf.c_winner;
CREATE UNLOGGED TABLE sf.c_winner AS
SELECT id,
       first_value(id) OVER (PARTITION BY coalesce(email, 'id:' || id) ORDER BY filled DESC, created_at ASC, id) AS winner_id
FROM sf.c_clean;
CREATE INDEX ON sf.c_winner (id);
CREATE INDEX ON sf.c_winner (winner_id);
INSERT INTO sf.cleaning_log SELECT 'people', 'merged_duplicate_email_contact', id, 'into ' || winner_id FROM sf.c_winner WHERE id <> winner_id;

-- Among winners, a phone must be unique: the oldest keeps it.
WITH ranked AS (
  SELECT c.id, c.phone, row_number() OVER (PARTITION BY c.phone ORDER BY c.created_at, c.id) AS rn
  FROM sf.c_clean c JOIN sf.c_winner w ON w.id = c.id AND w.winner_id = c.id
  WHERE c.phone IS NOT NULL
)
, logged AS (INSERT INTO sf.cleaning_log SELECT 'people', 'blank_duplicate_phone', id, phone FROM ranked WHERE rn > 1 RETURNING 1)
UPDATE sf.c_clean c SET phone = NULL FROM ranked WHERE ranked.rn > 1 AND c.id = ranked.id;

------------------------------------------------------------------------------------------------
-- 2c. Leads: attach to an existing contact or form new people (grouped by email, then phone, then id).
------------------------------------------------------------------------------------------------
DROP TABLE IF EXISTS sf.l_clean;
CREATE UNLOGGED TABLE sf.l_clean AS
SELECT l.id,
       sf.name_part(l.firstname) AS first_name,
       sf.name_part(l.lastname)  AS last_name,
       sf.email_norm(l.email)    AS email,
       coalesce(sf.phone_e164(l.mobilephone), sf.phone_e164(l.phone)) AS phone,
       sf.nz(l.pyc_user_id__c)   AS pyc_user_id,
       sf.nz(l.convertedcontactid) AS converted_contact_id,
       sf.ts(l.createddate)      AS created_at,
       sf.ts(l.lastmodifieddate) AS updated_at
FROM sf.lead l;
UPDATE sf.l_clean l SET email = NULL FROM sf.junk_email j WHERE l.email ~ j.pattern;
UPDATE sf.l_clean l SET phone = NULL FROM sf.phone_blocklist b WHERE b.phone = l.phone;
CREATE INDEX ON sf.l_clean (id);
CREATE INDEX ON sf.l_clean (email);
CREATE INDEX ON sf.l_clean (phone);
CREATE INDEX ON sf.l_clean (converted_contact_id);
CREATE INDEX ON sf.l_clean (pyc_user_id);

-- lead -> person_key resolution
DROP TABLE IF EXISTS sf.l_person;
CREATE TABLE sf.l_person AS  -- logged: stage 04 reads it
WITH cw AS (SELECT c.id, c.email, c.phone, c.created_at, w.winner_id FROM sf.c_clean c JOIN sf.c_winner w ON w.id = c.id)
, by_email AS (SELECT DISTINCT ON (email) email AS k, winner_id FROM cw WHERE email IS NOT NULL ORDER BY email, created_at, id)
, by_phone AS (SELECT DISTINCT ON (phone) phone AS k, winner_id FROM cw WHERE phone IS NOT NULL ORDER BY phone, created_at, id)
SELECT l.id AS lead_id,
       coalesce(
         'contact:' || wc.winner_id,                                   -- converted
         'contact:' || we.winner_id,                                   -- same email as a contact
         'contact:' || wp.winner_id,                                   -- same phone as a contact
         'lead:' || first_value(l.id) OVER (PARTITION BY coalesce(l.email, l.phone, 'id:' || l.id) ORDER BY l.created_at, l.id)
       ) AS person_key
FROM sf.l_clean l
LEFT JOIN sf.c_winner wc ON wc.id = l.converted_contact_id
LEFT JOIN by_email we ON we.k = l.email
LEFT JOIN by_phone wp ON wp.k = l.phone;
CREATE INDEX ON sf.l_person (lead_id);
CREATE INDEX ON sf.l_person (person_key);
INSERT INTO sf.cleaning_log
SELECT 'people', 'lead_attached_to_contact', lead_id, person_key FROM sf.l_person WHERE person_key LIKE 'contact:%';

------------------------------------------------------------------------------------------------
-- 2d. Freshdesk requesters from staging tickets that are not already a contact/lead.
------------------------------------------------------------------------------------------------
DROP TABLE IF EXISTS sf.s_clean;
CREATE TABLE sf.s_clean AS  -- logged: stage 03 reads it, and unlogged tables are emptied by a crash restart
SELECT s.id,
       sf.nz(s.pyc_legacy_id__c)        AS legacy_id,
       sf.nz(s.requester_id__c)         AS requester_id,
       sf.name_part(s.requester_name__c) AS requester_name,
       sf.nz(s.student_id_142378__c)    AS pyc_user_id,
       sf.email_norm(s.personemail__c)  AS email,
       sf.phone_e164(s.personphone__c)  AS phone,
       sf.nz(s.account_id__c)           AS account_id,
       sf.nz(s.caseid__c)               AS case_id,
       sf.nz(s.oppid__c)                AS opp_id,
       sf.nz(s.lead_id__c)              AS lead_id,
       sf.ts(s.created_at__c)           AS created_at
FROM sf.staging s;
UPDATE sf.s_clean s SET email = NULL FROM sf.junk_email j WHERE s.email ~ j.pattern;
UPDATE sf.s_clean s SET phone = NULL FROM sf.phone_blocklist b WHERE b.phone = s.phone;
CREATE INDEX ON sf.s_clean (id);
CREATE INDEX ON sf.s_clean (legacy_id);
CREATE INDEX ON sf.s_clean (requester_id);

DROP TABLE IF EXISTS sf.s_person;
-- One first match per key, hash-joined (a per-row lookup over 690k tickets is far too slow).
CREATE TABLE sf.s_person AS  -- logged: stage 04 reads it
WITH cw AS (SELECT c.*, w.winner_id FROM sf.c_clean c JOIN sf.c_winner w ON w.id = c.id)
, by_account AS (SELECT DISTINCT ON (account_id) account_id AS k, winner_id FROM cw WHERE account_id IS NOT NULL ORDER BY account_id, created_at, id)
, by_freshdesk AS (SELECT DISTINCT ON (freshdesk_id) freshdesk_id AS k, winner_id FROM cw WHERE freshdesk_id IS NOT NULL ORDER BY freshdesk_id, created_at, id)
, by_pyc AS (SELECT DISTINCT ON (pyc_user_id) pyc_user_id AS k, winner_id FROM cw WHERE pyc_user_id IS NOT NULL ORDER BY pyc_user_id, created_at, id)
, by_email AS (SELECT DISTINCT ON (email) email AS k, winner_id FROM cw WHERE email IS NOT NULL ORDER BY email, created_at, id)
, by_phone AS (SELECT DISTINCT ON (phone) phone AS k, winner_id FROM cw WHERE phone IS NOT NULL ORDER BY phone, created_at, id)
, lw AS (SELECT l.*, p.person_key FROM sf.l_clean l JOIN sf.l_person p ON p.lead_id = l.id)
, lead_pyc AS (SELECT DISTINCT ON (pyc_user_id) pyc_user_id AS k, person_key FROM lw WHERE pyc_user_id IS NOT NULL ORDER BY pyc_user_id, created_at, id)
, lead_email AS (SELECT DISTINCT ON (email) email AS k, person_key FROM lw WHERE email IS NOT NULL ORDER BY email, created_at, id)
SELECT s.id AS staging_id,
       coalesce(
         'contact:' || wa.winner_id,                                                   -- linked account
         'contact:' || wr.winner_id,                                                   -- requester id = contact freshdesk id
         'contact:' || wu.winner_id,                                                   -- student id = contact pyc user id
         lp.person_key,                                                                -- student id = lead pyc user id
         'contact:' || we.winner_id,                                                   -- email
         'contact:' || wp.winner_id,                                                   -- phone
         le.person_key,                                                                -- lead with same email
         CASE WHEN s.requester_id IS NOT NULL THEN 'freshdesk:' || s.requester_id END,
         CASE WHEN s.pyc_user_id IS NOT NULL THEN 'pyc:' || s.pyc_user_id END,
         CASE WHEN s.email IS NOT NULL THEN 'email:' || s.email END,
         CASE WHEN s.phone IS NOT NULL THEN 'phone:' || s.phone END
       ) AS person_key
FROM sf.s_clean s
LEFT JOIN by_account wa ON wa.k = s.account_id
LEFT JOIN by_freshdesk wr ON wr.k = s.requester_id
LEFT JOIN by_pyc wu ON wu.k = s.pyc_user_id
LEFT JOIN lead_pyc lp ON lp.k = s.pyc_user_id
LEFT JOIN by_email we ON we.k = s.email
LEFT JOIN by_phone wp ON wp.k = s.phone
LEFT JOIN lead_email le ON le.k = s.email;
CREATE INDEX ON sf.s_person (staging_id);
CREATE INDEX ON sf.s_person (person_key);
INSERT INTO sf.cleaning_log SELECT 'people', 'staging_ticket_without_identity_skipped', staging_id, NULL FROM sf.s_person WHERE person_key IS NULL;

------------------------------------------------------------------------------------------------
-- 2e. Aliases: every Salesforce id that can point at a person.
------------------------------------------------------------------------------------------------
DROP TABLE IF EXISTS sf.person_alias;
CREATE TABLE sf.person_alias AS
SELECT 'contact' AS kind, c.id AS sf_id, 'contact:' || w.winner_id AS person_key FROM sf.c_clean c JOIN sf.c_winner w ON w.id = c.id
UNION ALL
SELECT 'account', c.account_id, 'contact:' || w.winner_id FROM sf.c_clean c JOIN sf.c_winner w ON w.id = c.id WHERE c.account_id IS NOT NULL
UNION ALL
SELECT 'lead', lead_id, person_key FROM sf.l_person
UNION ALL
SELECT 'staging', staging_id, person_key FROM sf.s_person WHERE person_key IS NOT NULL
UNION ALL
(SELECT DISTINCT ON (c.freshdesk_id) 'freshdesk_requester', c.freshdesk_id, 'contact:' || w.winner_id
 FROM sf.c_clean c JOIN sf.c_winner w ON w.id = c.id WHERE c.freshdesk_id IS NOT NULL ORDER BY c.freshdesk_id, c.created_at)
UNION ALL
(SELECT DISTINCT ON (s.requester_id) 'freshdesk_requester', s.requester_id, p.person_key
 FROM sf.s_clean s JOIN sf.s_person p ON p.staging_id = s.id
 WHERE s.requester_id IS NOT NULL AND p.person_key IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sf.c_clean c WHERE c.freshdesk_id = s.requester_id)
 ORDER BY s.requester_id, s.created_at)
UNION ALL
(SELECT DISTINCT ON (c.pyc_user_id) 'pyc_user', c.pyc_user_id, 'contact:' || w.winner_id
 FROM sf.c_clean c JOIN sf.c_winner w ON w.id = c.id WHERE c.pyc_user_id IS NOT NULL ORDER BY c.pyc_user_id, c.created_at)
UNION ALL
(SELECT DISTINCT ON (l.pyc_user_id) 'pyc_user', l.pyc_user_id, p.person_key
 FROM sf.l_clean l JOIN sf.l_person p ON p.lead_id = l.id
 WHERE l.pyc_user_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM sf.c_clean c WHERE c.pyc_user_id = l.pyc_user_id)
 ORDER BY l.pyc_user_id, l.created_at);
CREATE INDEX ON sf.person_alias (kind, sf_id);
CREATE INDEX ON sf.person_alias (person_key);

------------------------------------------------------------------------------------------------
-- 2f. People
------------------------------------------------------------------------------------------------
DROP TABLE IF EXISTS sf.people;
CREATE TABLE sf.people (
  person_key   text PRIMARY KEY,
  seq          bigserial,
  name         text,
  email        text,
  phone        text,
  identifier   text,
  contact_type text,
  city         text,
  country      text,
  created_at   timestamptz,
  updated_at   timestamptz,
  custom       jsonb NOT NULL DEFAULT '{}',
  raw          jsonb NOT NULL DEFAULT '{}'
);

-- contacts (winners only; merged ids and all leads folded in)
INSERT INTO sf.people (person_key, name, email, phone, identifier, contact_type, city, country, created_at, updated_at, custom, raw)
SELECT 'contact:' || cc.id,
       coalesce(nullif(concat_ws(' ', cc.first_name, cc.last_name), ''), split_part(cc.email, '@', 1), 'Unknown'),
       cc.email, cc.phone,
       cc.pyc_user_id,
       CASE WHEN sf.nz(a.stripe_customer_id__c) IS NOT NULL OR won.n > 0 THEN 'customer' ELSE 'lead' END,
       sf.nz(c.mailingcity), coalesce(sf.nz(c.mailingcountry), 'US'),
       cc.created_at, cc.updated_at,
       jsonb_strip_nulls(jsonb_build_object(
         'salesforce_id', cc.id,
         'sf_account_id', cc.account_id,
         'sf_lead_ids', nullif(leads.ids, ''),
         'sf_merged_ids', nullif(merged.ids, ''),
         'freshdesk_id', cc.freshdesk_id,
         'pyc_user_id', cc.pyc_user_id,
         'stripe_customer_id', sf.nz(a.stripe_customer_id__c),
         'shopify_id', coalesce(sf.nz(c.hic_shopifysync__shopify_id__c), sf.nz(a.hic_shopifysync__shopify_id__c)),
         'lead_type', coalesce(leads.lead_type, CASE sf.nz(c.leadsource) WHEN 'web-Membership Leads' THEN 'Membership' WHEN 'web-lessons' THEN 'Lessons' WHEN 'Lessons' THEN 'Lessons' END),
         'lead_status', leads.status,
         'lead_source', coalesce(leads.source, sf.nz(c.leadsource), sf.nz(a.accountsource)),
         'owner', own.name,
         'is_pro', (sf.nz(c.is_pro__c) = '1'),
         'age_range', coalesce(sf.nz(c.age_range__c), leads.age_range),
         'fitness', coalesce(sf.nz(c.fitness__c), leads.fitness),
         'lesson_goal', coalesce(sf.nz(c.lesson_goal__c), leads.lesson_goal),
         'lesson_taker', leads.lesson_taker,
         'preferred_time_of_day', sf.nz(c.preferred_time_of_day__c),
         'preferred_day', sf.nz(c.preferred_day__c),
         'preferred_location', sf.nz(c.preferred_location__c),
         'gender', coalesce(sf.nz(c.genderidentity), leads.gender),
         'postal_code', coalesce(sf.nz(a.postalcode__c), sf.nz(c.mailingpostalcode), leads.postal_code),
         'timezone', coalesce(sf.nz(a.timezone__c), sf.nz(c.pyc_legacy_time_zone__c)),
         'first_contact_at', left(sf.nz(a.first_contact__c), 10),
         'last_inbound_contact_at', left(sf.nz(a.lastinboundcontact__c), 10),
         'support_profile_url', coalesce(sf.nz(c.pyc_support_profile_url__c), leads.support_profile_url),
         'decision_criteria', coalesce(sf.nz(a.decision_criteria__c), leads.decision_criteria),
         'legacy_agent_name', sf.nz(c.pyc_legacy_assigned_agent_name__c),
         'drip_messages_sent', leads.drip_messages_sent,
         'last_drip_sms_at', leads.last_drip_sms_at,
         'exclude_from_drip', leads.exclude_from_drip,
         'email_opted_out', (sf.nz(c.hasoptedoutofemail) = '1' OR leads.email_opted_out),
         'do_not_call', (sf.nz(c.donotcall) = '1' OR leads.do_not_call)
       )),
       jsonb_build_object('contact', sf.raw(c.*), 'account', coalesce(sf.raw(a.*), '{}'::jsonb), 'leads', coalesce(leads.raw, '[]'::jsonb),
                          'merged_contacts', coalesce(merged.raw, '[]'::jsonb))
FROM sf.c_clean cc
JOIN sf.contact c ON c.id = cc.id
LEFT JOIN sf.account a ON a.id = cc.account_id
LEFT JOIN sf.owner_name own ON own.id = c.ownerid
LEFT JOIN LATERAL (SELECT count(*) AS n FROM sf.opportunity o WHERE o.accountid = cc.account_id AND o.iswon = '1') won ON true
LEFT JOIN LATERAL (
  SELECT string_agg(m.id, ',' ORDER BY m.id) AS ids, jsonb_agg(sf.raw(mc.*) ORDER BY m.id) AS raw
  FROM sf.c_winner m JOIN sf.contact mc ON mc.id = m.id WHERE m.winner_id = cc.id AND m.id <> cc.id) merged ON true
LEFT JOIN LATERAL (
  SELECT string_agg(l.id, ',' ORDER BY l.createddate) AS ids,
         jsonb_agg(sf.raw(l.*) ORDER BY l.createddate) AS raw,
         (array_agg(CASE sf.nz(l.lead_type__c) WHEN 'Membership Leads' THEN 'Membership' WHEN 'Lessons' THEN 'Lessons' WHEN 'League Lead' THEN 'League' END
                    ORDER BY l.createddate DESC))[1] AS lead_type,
         (array_agg(sf.nz(l.status) ORDER BY l.createddate DESC))[1] AS status,
         (array_agg(sf.nz(l.leadsource) ORDER BY l.createddate DESC))[1] AS source,
         (array_agg(sf.nz(l.age_range__c) ORDER BY l.createddate DESC))[1] AS age_range,
         (array_agg(sf.nz(l.fitness__c) ORDER BY l.createddate DESC))[1] AS fitness,
         (array_agg(sf.nz(l.lesson_goal__c) ORDER BY l.createddate DESC))[1] AS lesson_goal,
         (array_agg(sf.nz(l.lesson_taker__c) ORDER BY l.createddate DESC))[1] AS lesson_taker,
         (array_agg(sf.nz(l.genderidentity) ORDER BY l.createddate DESC))[1] AS gender,
         (array_agg(coalesce(sf.nz(l.postalcode__c), sf.nz(l.postalcode)) ORDER BY l.createddate DESC))[1] AS postal_code,
         (array_agg(sf.nz(l.pyc_support_profile_url__c) ORDER BY l.createddate DESC))[1] AS support_profile_url,
         (array_agg(sf.nz(l.decision_criteria__c) ORDER BY l.createddate DESC))[1] AS decision_criteria,
         sum(nullif(sf.nz(l.total_messages_sent__c), '')::numeric)::int AS drip_messages_sent,
         left(max(sf.nz(l.last_drip_sms_sent_time__c)), 10) AS last_drip_sms_at,
         bool_or(sf.nz(l.exclude_from_drip__c) = '1') AS exclude_from_drip,
         bool_or(sf.nz(l.hasoptedoutofemail) = '1') AS email_opted_out,
         bool_or(sf.nz(l.donotcall) = '1') AS do_not_call
  FROM sf.l_person lp JOIN sf.lead l ON l.id = lp.lead_id WHERE lp.person_key = 'contact:' || cc.id) leads ON true
JOIN sf.c_winner w ON w.id = cc.id AND w.winner_id = cc.id;

-- lead-only people
INSERT INTO sf.people (person_key, name, email, phone, identifier, contact_type, city, country, created_at, updated_at, custom, raw)
SELECT g.person_key,
       coalesce(nullif(concat_ws(' ', sf.name_part(l.firstname), sf.name_part(l.lastname)), ''), split_part(g.email, '@', 1), 'Unknown'),
       g.email, g.phone, g.pyc_user_id, 'lead',
       sf.nz(l.city), coalesce(sf.nz(l.country), 'US'),
       g.created_at, g.updated_at,
       jsonb_strip_nulls(jsonb_build_object(
         'sf_lead_ids', g.ids,
         'pyc_user_id', g.pyc_user_id,
         'lead_type', CASE sf.nz(l.lead_type__c) WHEN 'Membership Leads' THEN 'Membership' WHEN 'Lessons' THEN 'Lessons' WHEN 'League Lead' THEN 'League' END,
         'lead_status', sf.nz(l.status),
         'lead_source', sf.nz(l.leadsource),
         'owner', own.name,
         'age_range', sf.nz(l.age_range__c),
         'fitness', sf.nz(l.fitness__c),
         'lesson_goal', sf.nz(l.lesson_goal__c),
         'lesson_taker', sf.nz(l.lesson_taker__c),
         'gender', sf.nz(l.genderidentity),
         'postal_code', coalesce(sf.nz(l.postalcode__c), sf.nz(l.postalcode)),
         'timezone', sf.nz(l.timezone__c),
         'support_profile_url', sf.nz(l.pyc_support_profile_url__c),
         'decision_criteria', sf.nz(l.decision_criteria__c),
         'drip_messages_sent', g.drip_messages_sent,
         'last_drip_sms_at', g.last_drip_sms_at,
         'exclude_from_drip', g.exclude_from_drip,
         'email_opted_out', g.email_opted_out,
         'do_not_call', g.do_not_call
       )),
       jsonb_build_object('leads', g.raw)
FROM (
  SELECT lp.person_key,
         (array_agg(l.id ORDER BY l.updated_at DESC NULLS LAST, l.id))[1] AS latest_lead_id,
         (array_agg(l.email ORDER BY l.email IS NULL, l.created_at))[1] AS email,
         (array_agg(l.phone ORDER BY l.phone IS NULL, l.created_at))[1] AS phone,
         (array_agg(l.pyc_user_id ORDER BY l.pyc_user_id IS NULL, l.created_at))[1] AS pyc_user_id,
         min(l.created_at) AS created_at, max(l.updated_at) AS updated_at,
         string_agg(l.id, ',' ORDER BY l.created_at) AS ids,
         jsonb_agg(sf.raw(r.*) ORDER BY l.created_at) AS raw,
         sum(nullif(sf.nz(r.total_messages_sent__c), '')::numeric)::int AS drip_messages_sent,
         left(max(sf.nz(r.last_drip_sms_sent_time__c)), 10) AS last_drip_sms_at,
         bool_or(sf.nz(r.exclude_from_drip__c) = '1') AS exclude_from_drip,
         bool_or(sf.nz(r.hasoptedoutofemail) = '1') AS email_opted_out,
         bool_or(sf.nz(r.donotcall) = '1') AS do_not_call
  FROM sf.l_person lp JOIN sf.l_clean l ON l.id = lp.lead_id JOIN sf.lead r ON r.id = l.id
  WHERE lp.person_key LIKE 'lead:%'
  GROUP BY lp.person_key) g
JOIN sf.lead l ON l.id = g.latest_lead_id
LEFT JOIN sf.owner_name own ON own.id = l.ownerid;

-- Freshdesk-only requesters (dummy contacts to enrich later)
INSERT INTO sf.people (person_key, name, email, phone, identifier, contact_type, country, created_at, updated_at, custom, raw)
SELECT g.person_key,
       coalesce(g.name, split_part(g.email, '@', 1), 'Freshdesk requester ' || coalesce(g.requester_id, g.pyc_user_id, '')),
       g.email, g.phone,
       coalesce(g.pyc_user_id, CASE WHEN g.requester_id IS NOT NULL THEN 'freshdesk:' || g.requester_id END),
       'lead', 'US', g.created_at, g.created_at,
       jsonb_strip_nulls(jsonb_build_object('freshdesk_id', g.requester_id, 'pyc_user_id', g.pyc_user_id, 'lead_source', 'freshdesk')),
       jsonb_build_object('freshdesk_requester', jsonb_strip_nulls(jsonb_build_object(
         'requester_id', g.requester_id, 'requester_name', g.name, 'student_id', g.pyc_user_id, 'email', g.email, 'phone', g.phone)))
FROM (
  SELECT p.person_key,
         (array_agg(s.requester_name ORDER BY s.requester_name IS NULL, s.created_at DESC))[1] AS name,
         (array_agg(s.email ORDER BY s.email IS NULL, s.created_at DESC))[1] AS email,
         (array_agg(s.phone ORDER BY s.phone IS NULL, s.created_at DESC))[1] AS phone,
         (array_agg(s.requester_id ORDER BY s.requester_id IS NULL, s.created_at DESC))[1] AS requester_id,
         (array_agg(s.pyc_user_id ORDER BY s.pyc_user_id IS NULL, s.created_at DESC))[1] AS pyc_user_id,
         min(s.created_at) AS created_at
  FROM sf.s_person p JOIN sf.s_clean s ON s.id = p.staging_id
  WHERE p.person_key IS NOT NULL AND p.person_key NOT LIKE 'contact:%' AND p.person_key NOT LIKE 'lead:%'
  GROUP BY p.person_key) g;

-- Uniqueness guards for Chatwoot: email, phone and identifier must each be unique per account.
WITH d AS (SELECT person_key, email, row_number() OVER (PARTITION BY email ORDER BY created_at, person_key) rn FROM sf.people WHERE email IS NOT NULL)
, logged AS (INSERT INTO sf.cleaning_log SELECT 'people', 'blank_duplicate_email_cross_source', person_key, email FROM d WHERE rn > 1 RETURNING 1)
UPDATE sf.people p SET email = NULL FROM d WHERE d.rn > 1 AND p.person_key = d.person_key;
WITH d AS (SELECT person_key, phone, row_number() OVER (PARTITION BY phone ORDER BY created_at, person_key) rn FROM sf.people WHERE phone IS NOT NULL)
, logged AS (INSERT INTO sf.cleaning_log SELECT 'people', 'blank_duplicate_phone_cross_source', person_key, phone FROM d WHERE rn > 1 RETURNING 1)
UPDATE sf.people p SET phone = NULL FROM d WHERE d.rn > 1 AND p.person_key = d.person_key;
WITH d AS (SELECT person_key, identifier, row_number() OVER (PARTITION BY identifier ORDER BY created_at, person_key) rn FROM sf.people WHERE identifier IS NOT NULL)
, logged AS (INSERT INTO sf.cleaning_log SELECT 'people', 'blank_duplicate_identifier', person_key, identifier FROM d WHERE rn > 1 RETURNING 1)
UPDATE sf.people p SET identifier = NULL FROM d WHERE d.rn > 1 AND p.person_key = d.person_key;

CREATE INDEX ON sf.people (email);
CREATE INDEX ON sf.people (phone);
CREATE INDEX ON sf.people (identifier);
CREATE UNIQUE INDEX ON sf.people (seq);
ANALYZE sf.people; ANALYZE sf.person_alias;

SELECT 'people' AS t, count(*) FROM sf.people
UNION ALL SELECT 'people_from_contacts', count(*) FROM sf.people WHERE person_key LIKE 'contact:%'
UNION ALL SELECT 'people_from_leads', count(*) FROM sf.people WHERE person_key LIKE 'lead:%'
UNION ALL SELECT 'people_freshdesk_only', count(*) FROM sf.people WHERE person_key NOT LIKE 'contact:%' AND person_key NOT LIKE 'lead:%'
UNION ALL SELECT 'cleaning:' || action, count(*) FROM sf.cleaning_log GROUP BY action;
