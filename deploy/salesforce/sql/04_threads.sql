-- Stage 4: threads (one per future Chatwoot conversation) with person, inbox bucket, labels and attributes.
SET client_min_messages = warning;
SET search_path = sf, public;

-- Per-thread aggregates over parts: counts, time span, dominant PYC number / address.
DROP TABLE IF EXISTS sf.thread_parts;
CREATE UNLOGGED TABLE sf.thread_parts AS
SELECT thread_key,
       count(*) AS parts_count,
       count(*) FILTER (WHERE kind = 'sms') AS sms_count,
       count(*) FILTER (WHERE kind = 'email') AS email_count,
       count(*) FILTER (WHERE kind = 'note') AS note_count,
       min(created_at) AS first_at,
       max(created_at) AS last_at,
       mode() WITHIN GROUP (ORDER BY pyc_number)  AS pyc_number,
       mode() WITHIN GROUP (ORDER BY pyc_address) AS pyc_address
FROM sf.parts
GROUP BY thread_key;
CREATE UNIQUE INDEX ON sf.thread_parts (thread_key);

CREATE OR REPLACE FUNCTION sf.email_bucket(addr text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN addr ~ '^(support|info|membership|lessons|sales)@playyourcourt\.com$' THEN 'email:' || addr
              ELSE 'email:support@playyourcourt.com' END
$$;

CREATE OR REPLACE FUNCTION sf.person_for(p_kind text, p_id text) RETURNS text LANGUAGE sql STABLE AS $$
  SELECT person_key FROM sf.person_alias WHERE kind = p_kind AND sf_id = p_id LIMIT 1
$$;

CREATE OR REPLACE FUNCTION sf.person_by_email(e text) RETURNS text LANGUAGE sql STABLE AS $$
  SELECT person_key FROM sf.people WHERE e IS NOT NULL AND email = e LIMIT 1
$$;

CREATE OR REPLACE FUNCTION sf.person_by_phone(p text) RETURNS text LANGUAGE sql STABLE AS $$
  SELECT person_key FROM sf.people WHERE p IS NOT NULL AND phone = p LIMIT 1
$$;

DROP TABLE IF EXISTS sf.threads;
CREATE TABLE sf.threads (
  thread_key   text PRIMARY KEY,
  seq          bigserial,
  phase        text NOT NULL,            -- salesforce | freshdesk
  sf_object    text NOT NULL,            -- case | opportunity | lead | account | freshdesk
  person_key   text,
  bucket       text NOT NULL,            -- email:<addr> | sms:<number> | web-forms | freshdesk-sales | freshdesk-support | support-tasks
  status       text NOT NULL,            -- open | resolved
  created_at   timestamptz NOT NULL,
  last_at      timestamptz NOT NULL,
  subject      text,
  first_body   text,
  first_author text,                     -- contact | admin
  labels       text[] NOT NULL DEFAULT '{}',
  parts_count  int NOT NULL DEFAULT 0,
  custom       jsonb NOT NULL DEFAULT '{}',
  raw          jsonb NOT NULL DEFAULT '{}'
);

------------------------------------------------------------------------------------------------
-- 4a. Cases
------------------------------------------------------------------------------------------------
INSERT INTO sf.threads (thread_key, phase, sf_object, person_key, bucket, status, created_at, last_at, subject, first_body, first_author,
                        labels, parts_count, custom, raw)
SELECT 'case:' || c.id,
       CASE WHEN coalesce(tp.sms_count, 0) + coalesce(tp.email_count, 0) > 0 OR sf.nz(c.pyc_legacy_id__c) IS NULL THEN 'salesforce' ELSE 'freshdesk' END,
       'case',
       coalesce(sf.person_for('contact', sf.nz(c.contactid)),
                sf.person_for('account', sf.nz(c.accountid)),
                sf.person_by_email(sf.email_norm(c.suppliedemail)),
                sf.person_by_phone(coalesce(sf.phone_e164(c.mobilephone__c), sf.phone_e164(c.suppliedphone))),
                sf.person_for('pyc_user', sf.nz(c.pyc_user_id__c)),
                sf.person_for('freshdesk_requester', sf.nz(c.pyc_legacy_requester_id__c))),
       CASE
         WHEN tp.email_count > 0 THEN sf.email_bucket(tp.pyc_address)
         WHEN tp.sms_count > 0 THEN 'sms:' || coalesce(tp.pyc_number, 'unknown')
         WHEN sf.nz(c.origin) IN ('Email') THEN 'email:support@playyourcourt.com'
         WHEN sf.nz(c.origin) = 'Web' THEN 'web-forms'
         WHEN sf.nz(c.origin) = 'SMS' THEN 'sms:unknown'
         WHEN sf.nz(c.pyc_legacy_id__c) IS NOT NULL THEN
           CASE WHEN sf.nz(c.pyc_legacy_support_groups__c) IN ('Sales', 'Membership') THEN 'freshdesk-sales' ELSE 'freshdesk-support' END
         ELSE 'support-tasks' END,
       CASE WHEN c.isclosed = '0' THEN 'open' ELSE 'resolved' END,
       coalesce(sf.ts(c.pyc_legacy_created_at__c), sf.ts(c.createddate)),
       greatest(coalesce(tp.last_at, sf.ts(c.createddate)), coalesce(sf.ts(c.closeddate), sf.ts(c.createddate))),
       coalesce(sf.nz(c.subject), sf.nz(c.pyc_legacy_subject__c)),
       coalesce(sf.nz(c.description), sf.nz(c.pyc_legacy_description__c)),
       CASE WHEN sf.nz(c.origin) IN ('Email', 'Web', 'SMS') OR sf.nz(c.suppliedemail) IS NOT NULL THEN 'contact' ELSE 'admin' END,
       array_remove(ARRAY['case',
         sf.slug(c.type),
         CASE WHEN sf.nz(c.pyc_legacy_id__c) IS NOT NULL THEN 'freshdesk' END,
         sf.slug(c.pyc_legacy_ticket_type__c),
         CASE WHEN c.subject ~* '(mail system error|delivery status notification|failure notice|automatic reply|undeliverable|systems bounce)' THEN 'bounce' END,
         CASE WHEN c.ownerid = '00GHp0000063r2rMAA' THEN 'bounce' END], NULL),
       coalesce(tp.parts_count, 0),
       jsonb_strip_nulls(jsonb_build_object(
         'sf_object', 'case', 'salesforce_id', c.id, 'case_number', sf.nz(c.casenumber), 'case_origin', sf.nz(c.origin),
         'case_type', sf.nz(c.type), 'priority', sf.nz(c.priority), 'sf_owner', own.name,
         'freshdesk_ticket_id', sf.nz(c.pyc_legacy_id__c), 'freshdesk_ticket_type', sf.nz(c.pyc_legacy_ticket_type__c),
         'freshdesk_group', sf.nz(c.pyc_legacy_support_groups__c), 'freshdesk_status', sf.nz(c.pyc_legacy_ticket_status__c),
         'pyc_number', tp.pyc_number, 'source_address', tp.pyc_address)),
       sf.raw(c.*)
FROM sf."case" c
LEFT JOIN sf.thread_parts tp ON tp.thread_key = 'case:' || c.id
LEFT JOIN sf.owner_name own ON own.id = c.ownerid;

------------------------------------------------------------------------------------------------
-- 4b. Opportunities (canonical only)
------------------------------------------------------------------------------------------------
INSERT INTO sf.threads (thread_key, phase, sf_object, person_key, bucket, status, created_at, last_at, subject, first_body, first_author,
                        labels, parts_count, custom, raw)
SELECT 'opp:' || o.id,
       CASE WHEN coalesce(tp.sms_count, 0) > 0 OR oc.legacy_id IS NULL THEN 'salesforce' ELSE 'freshdesk' END,
       'opportunity',
       coalesce(sf.person_for('contact', sf.nz(o.contactid)),
                sf.person_for('account', sf.nz(o.accountid)),
                sf.person_by_phone(sf.phone_e164(o.mobilephone__c)),
                sf.person_for('pyc_user', sf.nz(o.pyc_user_id__c)),
                sf.person_for('freshdesk_requester', sf.nz(o.pyc_legacy_requester_id__c))),
       CASE
         WHEN tp.sms_count > 0 THEN 'sms:' || coalesce(tp.pyc_number, 'unknown')
         WHEN oc.legacy_id IS NOT NULL THEN
           CASE WHEN sf.nz(o.pyc_legacy_support_groups__c) IN ('Support', 'Tech', 'Retail', 'Bracket Challenge') THEN 'freshdesk-support' ELSE 'freshdesk-sales' END
         ELSE 'support-tasks' END,
       'resolved',
       coalesce(sf.ts(o.pyc_legacy_created_at__c), sf.ts(o.createddate)),
       greatest(coalesce(tp.last_at, sf.ts(o.createddate)), coalesce(sf.ts(o.pyc_legacy_updated_at__c), sf.ts(o.createddate))),
       coalesce(sf.nz(o.pyc_legacy_subject__c), sf.nz(o.name)),
       coalesce(sf.nz(o.pyc_legacy_description__c), sf.nz(o.description)),
       CASE WHEN oc.legacy_id IS NOT NULL THEN 'contact' ELSE 'admin' END,
       array_remove(ARRAY['opportunity',
         CASE WHEN sf.nz(o.leadsource) ILIKE '%membership%' THEN 'membership' WHEN sf.nz(o.leadsource) ILIKE '%lesson%' THEN 'lessons' END,
         CASE WHEN o.iswon = '1' THEN 'closed-won' WHEN sf.nz(o.stagename) = 'Closed Lost' THEN 'closed-lost' END,
         sf.slug(o.stagename),
         CASE WHEN oc.legacy_id IS NOT NULL THEN 'freshdesk' END,
         sf.slug(o.pyc_legacy_ticket_type__c)], NULL),
       coalesce(tp.parts_count, 0),
       jsonb_strip_nulls(jsonb_build_object(
         'sf_object', 'opportunity', 'salesforce_id', o.id, 'opp_stage', sf.nz(o.stagename), 'priority', sf.nz(o.priority__c),
         'sf_owner', own.name, 'lead_source', sf.nz(o.leadsource),
         'freshdesk_ticket_id', oc.legacy_id, 'freshdesk_ticket_type', sf.nz(o.pyc_legacy_ticket_type__c),
         'freshdesk_group', sf.nz(o.pyc_legacy_support_groups__c), 'freshdesk_status', sf.nz(o.pyc_legacy_ticket_status__c),
         'pyc_number', tp.pyc_number)),
       sf.raw(o.*)
FROM sf.opportunity o
JOIN sf.opp_canon oc ON oc.opp_id = o.id AND oc.canon_id = o.id
LEFT JOIN sf.thread_parts tp ON tp.thread_key = 'opp:' || o.id
LEFT JOIN sf.owner_name own ON own.id = o.ownerid;

------------------------------------------------------------------------------------------------
-- 4c. Lead and Account SMS threads (one per record × PYC number)
------------------------------------------------------------------------------------------------
INSERT INTO sf.threads (thread_key, phase, sf_object, person_key, bucket, status, created_at, last_at, subject, labels, parts_count, custom, raw)
SELECT tp.thread_key, 'salesforce', 'lead',
       sf.person_for('lead', split_part(tp.thread_key, ':', 2)),
       'sms:' || split_part(tp.thread_key, ':', 3),
       'resolved', tp.first_at, tp.last_at,
       'SMS with ' || coalesce(nm.name, split_part(tp.thread_key, ':', 3)),
       array_remove(ARRAY['lead',
         CASE sf.nz(l.lead_type__c) WHEN 'Membership Leads' THEN 'membership' WHEN 'Lessons' THEN 'lessons' WHEN 'League Lead' THEN 'league' END,
         sf.slug(l.status),
         CASE WHEN l.isconverted = '1' THEN 'converted' END], NULL),
       tp.parts_count,
       jsonb_strip_nulls(jsonb_build_object('sf_object', 'lead', 'salesforce_id', l.id, 'lead_status', sf.nz(l.status),
         'lead_source', sf.nz(l.leadsource), 'sf_owner', own.name, 'pyc_number', split_part(tp.thread_key, ':', 3))),
       sf.raw(l.*)
FROM sf.thread_parts tp
JOIN sf.lead l ON l.id = split_part(tp.thread_key, ':', 2)
LEFT JOIN sf.number_meta nm ON nm.number = split_part(tp.thread_key, ':', 3)
LEFT JOIN sf.owner_name own ON own.id = l.ownerid
WHERE tp.thread_key LIKE 'lead:%';

INSERT INTO sf.threads (thread_key, phase, sf_object, person_key, bucket, status, created_at, last_at, subject, labels, parts_count, custom, raw)
SELECT tp.thread_key, 'salesforce', 'account',
       sf.person_for('account', split_part(tp.thread_key, ':', 2)),
       'sms:' || split_part(tp.thread_key, ':', 3),
       'resolved', tp.first_at, tp.last_at,
       'SMS with ' || coalesce(nm.name, split_part(tp.thread_key, ':', 3)),
       ARRAY['customer'],
       tp.parts_count,
       jsonb_strip_nulls(jsonb_build_object('sf_object', 'account', 'salesforce_id', split_part(tp.thread_key, ':', 2),
         'pyc_number', split_part(tp.thread_key, ':', 3))),
       '{}'::jsonb
FROM sf.thread_parts tp
LEFT JOIN sf.number_meta nm ON nm.number = split_part(tp.thread_key, ':', 3)
WHERE tp.thread_key LIKE 'account:%';

------------------------------------------------------------------------------------------------
-- 4d. Freshdesk tickets that only exist in the staging table
------------------------------------------------------------------------------------------------
INSERT INTO sf.threads (thread_key, phase, sf_object, person_key, bucket, status, created_at, last_at, subject, first_body, first_author,
                        labels, parts_count, custom, raw)
SELECT 'fd:' || ft.legacy_id, 'freshdesk', 'freshdesk',
       sp.person_key,
       CASE WHEN sf.nz(s.ticket_type__c) IN ('New Lead', 'Sales Followup', 'Low Credits Lead', 'Mid Package FollowUp', 'New League Lead', 'Lead',
                                             'New Area Covered Lead')
                 OR sf.nz(s.group_id__c) = '5000022160' THEN 'freshdesk-sales' ELSE 'freshdesk-support' END,
       'resolved',
       coalesce(sf.ts(s.created_at__c), sf.ts(s.createddate)),
       greatest(coalesce(tp.last_at, sf.ts(s.created_at__c), sf.ts(s.createddate)), coalesce(sf.ts(s.updated_at__c), sf.ts(s.created_at__c), sf.ts(s.createddate))),
       sf.nz(s.subject__c),
       sf.nz(s.description__c),
       'contact',
       array_remove(ARRAY['freshdesk',
         CASE WHEN sf.nz(s.ticket_type__c) ILIKE '%lead%' THEN 'lead' ELSE 'case' END,
         sf.slug(s.ticket_type__c)], NULL),
       coalesce(tp.parts_count, 0),
       jsonb_strip_nulls(jsonb_build_object('sf_object', 'freshdesk', 'salesforce_id', s.id, 'freshdesk_ticket_id', ft.legacy_id,
         'freshdesk_ticket_type', sf.nz(s.ticket_type__c), 'freshdesk_status', sf.nz(s.status__c), 'priority', sf.nz(s.priority__c),
         'sf_owner', sf.nz(s.responder_name__c))),
       sf.raw(s.*)
FROM sf.fd_ticket ft
JOIN sf.staging s ON s.id = ft.staging_id
JOIN sf.s_person sp ON sp.staging_id = ft.staging_id
LEFT JOIN sf.thread_parts tp ON tp.thread_key = 'fd:' || ft.legacy_id;

------------------------------------------------------------------------------------------------
-- 4e. Drop what cannot be imported, log it, index.
------------------------------------------------------------------------------------------------
-- bounces and auto-replies are noise
INSERT INTO sf.cleaning_log SELECT 'threads', 'bounce_case_skipped', thread_key, subject FROM sf.threads WHERE sf_object = 'case' AND 'bounce' = ANY(labels);
DELETE FROM sf.threads WHERE sf_object = 'case' AND 'bounce' = ANY(labels);
INSERT INTO sf.cleaning_log SELECT 'threads', 'thread_without_person_skipped', thread_key, sf_object FROM sf.threads WHERE person_key IS NULL;
DELETE FROM sf.threads WHERE person_key IS NULL;
INSERT INTO sf.cleaning_log SELECT 'threads', 'thread_without_content_skipped', thread_key, sf_object FROM sf.threads WHERE parts_count = 0 AND first_body IS NULL;
DELETE FROM sf.threads WHERE parts_count = 0 AND first_body IS NULL;
-- parts whose thread was dropped
DELETE FROM sf.parts p WHERE NOT EXISTS (SELECT 1 FROM sf.threads t WHERE t.thread_key = p.thread_key);

CREATE INDEX ON sf.threads (phase, last_at);
CREATE INDEX ON sf.threads (person_key);
CREATE INDEX ON sf.threads (bucket);
CREATE UNIQUE INDEX ON sf.threads (seq);
ANALYZE sf.threads; ANALYZE sf.parts;

SELECT phase, sf_object, count(*) AS threads, sum(parts_count) AS parts FROM sf.threads GROUP BY 1, 2 ORDER BY 1, 2;
SELECT bucket, count(*) FROM sf.threads GROUP BY 1 ORDER BY 2 DESC;
SELECT action, count(*), max(detail) FROM sf.cleaning_log WHERE stage IN ('parts', 'threads') GROUP BY 1 ORDER BY 1;
