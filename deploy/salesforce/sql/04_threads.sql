-- Stage 4: threads (one per future Chatwoot conversation) with person, inbox bucket, labels and attributes.
SET client_min_messages = warning;
SET search_path = sf, public;
DELETE FROM sf.cleaning_log WHERE stage = 'threads';  -- this stage rewrites its own log rows on re-run

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

-- Freshdesk agent names by responder id: legacy cases/opportunities only carry the id, and their Salesforce owner is the migration user.
DROP TABLE IF EXISTS sf.fd_responder;
CREATE UNLOGGED TABLE sf.fd_responder AS
SELECT DISTINCT ON (responder_id__c) responder_id__c AS id, responder_name__c AS name
FROM sf.staging
WHERE sf.nz(responder_id__c) IS NOT NULL AND sf.nz(responder_name__c) IS NOT NULL
ORDER BY responder_id__c, createddate DESC;
CREATE UNIQUE INDEX ON sf.fd_responder (id);

-- Chatwoot conversation priority from Salesforce (Low/Medium/High/Urgent) or Freshdesk (1-4) values.
CREATE OR REPLACE FUNCTION sf.priority(v text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE lower(sf.nz(v)) WHEN 'low' THEN 'low' WHEN '1' THEN 'low' WHEN 'medium' THEN 'medium' WHEN '2' THEN 'medium'
                              WHEN 'high' THEN 'high' WHEN '3' THEN 'high' WHEN 'urgent' THEN 'urgent' WHEN '4' THEN 'urgent' END
$$;

-- Furthest automated SMS step a lead reached (lessons drip first, then the membership drip).
CREATE OR REPLACE FUNCTION sf.drip_step(l sf.lead) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN l.x6_week_sms_sent__c = '1' THEN '6 week' WHEN l.x14_day_sms_sent__c = '1' THEN '14 day'
              WHEN l.x7_day_sms_sent__c = '1' THEN '7 day' WHEN l.x48_hrs_sms_sent__c = '1' THEN '48 hrs'
              WHEN l.x24_hrs_sms_sent__c = '1' THEN '24 hrs' WHEN l.quick_sms_sent__c = '1' THEN 'Quick'
              WHEN l.x2nd_membership_sms_sent__c = '1' THEN '2nd membership'
              WHEN l.x1st_membership_sms_sent__c = '1' THEN '1st membership' END
$$;

-- Site-relative PYC paths (/tennis-pros/...) as full links.
CREATE OR REPLACE FUNCTION sf.pyc_url(v text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN sf.nz(v) LIKE '/%' THEN 'https://www.playyourcourt.com' || sf.nz(v) ELSE sf.nz(v) END
$$;

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
  status       text NOT NULL,            -- open | pending | resolved
  created_at   timestamptz NOT NULL,
  last_at      timestamptz NOT NULL,
  subject      text,
  first_body   text,
  first_author text,                     -- contact | admin
  labels       text[] NOT NULL DEFAULT '{}',
  parts_count  int NOT NULL DEFAULT 0,
  custom       jsonb NOT NULL DEFAULT '{}',
  raw          jsonb NOT NULL DEFAULT '{}',
  priority     text,                     -- low | medium | high | urgent
  due_at       timestamptz               -- the importer snoozes unresolved threads until this when it is still ahead
);

------------------------------------------------------------------------------------------------
-- 4a. Cases
------------------------------------------------------------------------------------------------
INSERT INTO sf.threads (thread_key, phase, sf_object, person_key, bucket, status, created_at, last_at, subject, first_body, first_author,
                        labels, parts_count, custom, raw, priority, due_at)
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
         WHEN sf.nz(c.origin) = 'SMS' THEN 'sms:' || coalesce(dn.number, 'unknown')  -- number from the "New SMS Message" description
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
         -- subject only: the auto-reply queue also holds real customer mail (refunds, cancellations)
         CASE WHEN c.subject ~* '(mail system error|delivery status notification|failure notice|automatic reply|undeliverable|systems bounce)' THEN 'bounce' END], NULL),
       coalesce(tp.parts_count, 0),
       jsonb_strip_nulls(jsonb_build_object(
         'sf_object', 'case', 'salesforce_id', c.id, 'case_number', sf.nz(c.casenumber), 'case_origin', sf.nz(c.origin),
         'case_type', sf.nz(c.type), 'sf_priority', sf.nz(c.priority), 'sf_owner', own.name, 'fd_responder', fr.name,
         'freshdesk_ticket_id', sf.nz(c.pyc_legacy_id__c), 'freshdesk_ticket_type', sf.nz(c.pyc_legacy_ticket_type__c),
         'freshdesk_group', sf.nz(c.pyc_legacy_support_groups__c), 'freshdesk_status', sf.nz(c.pyc_legacy_ticket_status__c),
         'pyc_number', coalesce(tp.pyc_number, dn.number), 'source_address', tp.pyc_address)),
       sf.raw(c.*),
       sf.priority(c.priority), NULL
FROM sf."case" c
LEFT JOIN sf.thread_parts tp ON tp.thread_key = 'case:' || c.id
LEFT JOIN sf.number_meta dn ON dn.number = substring(c.description FROM 'From:\s*(?:<[^>]+>\s*)*(\+[0-9]{11,15})')
LEFT JOIN sf.owner_name own ON own.id = c.ownerid
LEFT JOIN sf.fd_responder fr ON fr.id = sf.nz(c.pyc_legacy_responder_id__c);

------------------------------------------------------------------------------------------------
-- 4b. Opportunities (canonical only)
------------------------------------------------------------------------------------------------
INSERT INTO sf.threads (thread_key, phase, sf_object, person_key, bucket, status, created_at, last_at, subject, first_body, first_author,
                        labels, parts_count, custom, raw, priority, due_at)
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
       -- Salesforce-era pipeline stays live; Freshdesk-era opportunities are history
       CASE WHEN oc.legacy_id IS NOT NULL AND coalesce(tp.sms_count, 0) = 0 THEN 'resolved'
            WHEN o.stagename IN ('Expressed Interest', 'Matching Product(s)') THEN 'open'
            ELSE 'resolved' END,
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
         'sf_object', 'opportunity', 'salesforce_id', o.id, 'opp_stage', sf.nz(o.stagename), 'sf_priority', sf.nz(o.priority__c),
         'sf_owner', own.name, 'lead_source', sf.nz(o.leadsource), 'fd_responder', fr.name,
         'sf_due_by', to_char(sf.ts(o.due_by__c) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
         'freshdesk_ticket_id', oc.legacy_id, 'freshdesk_ticket_type', sf.nz(o.pyc_legacy_ticket_type__c),
         'freshdesk_group', sf.nz(o.pyc_legacy_support_groups__c), 'freshdesk_status', sf.nz(o.pyc_legacy_ticket_status__c),
         'pyc_number', tp.pyc_number)),
       sf.raw(o.*),
       sf.priority(o.priority__c), sf.ts(o.due_by__c)
FROM sf.opportunity o
JOIN sf.opp_canon oc ON oc.opp_id = o.id AND oc.canon_id = o.id
LEFT JOIN sf.thread_parts tp ON tp.thread_key = 'opp:' || o.id
LEFT JOIN sf.owner_name own ON own.id = o.ownerid
LEFT JOIN sf.fd_responder fr ON fr.id = sf.nz(o.pyc_legacy_responder_id__c);

------------------------------------------------------------------------------------------------
-- 4c. Lead and Account SMS threads (one per record × PYC number)
------------------------------------------------------------------------------------------------
INSERT INTO sf.threads (thread_key, phase, sf_object, person_key, bucket, status, created_at, last_at, subject, labels, parts_count, custom, raw)
SELECT tp.thread_key, 'salesforce', 'lead',
       sf.person_for('lead', split_part(tp.thread_key, ':', 2)),
       'sms:' || split_part(tp.thread_key, ':', 3),
       -- nurturing leads are still in the automated SMS flow; converted ones live on as opportunities
       CASE WHEN l.isconverted = '1' THEN 'resolved'
            WHEN l.status = 'Nurturing' THEN 'pending'
            WHEN l.status IN ('New', 'Assigned') THEN 'open'
            ELSE 'resolved' END,
       tp.first_at, tp.last_at,
       'SMS with ' || coalesce(nm.name, split_part(tp.thread_key, ':', 3)),
       array_remove(ARRAY['lead',
         CASE sf.nz(l.lead_type__c) WHEN 'Membership Leads' THEN 'membership' WHEN 'Lessons' THEN 'lessons' WHEN 'League Lead' THEN 'league' END,
         sf.slug(l.status),
         CASE WHEN l.isconverted = '1' THEN 'converted' END], NULL),
       tp.parts_count,
       jsonb_strip_nulls(jsonb_build_object('sf_object', 'lead', 'salesforce_id', l.id, 'lead_status', sf.nz(l.status),
         'lead_source', sf.nz(l.leadsource), 'sf_owner', own.name, 'pyc_number', split_part(tp.thread_key, ':', 3),
         'drip_step', sf.drip_step(l))),
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
                        labels, parts_count, custom, raw, priority, due_at)
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
         'freshdesk_ticket_type', sf.nz(s.ticket_type__c), 'freshdesk_status', sf.nz(s.status__c), 'sf_priority', sf.nz(s.priority__c),
         'fd_responder', sf.nz(s.responder_name__c))),
       sf.raw(s.*),
       sf.priority(s.priority__c), NULL
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
-- stale pipeline: no activity for 120 days and nothing due ahead
UPDATE sf.threads SET status = 'resolved'
WHERE sf_object IN ('opportunity', 'lead') AND status <> 'resolved' AND last_at < now() - interval '120 days' AND (due_at IS NULL OR due_at <= now());
-- the departed owner's open cases are long abandoned
UPDATE sf.threads SET status = 'resolved' WHERE sf_object = 'case' AND status = 'open' AND custom->>'sf_owner' = 'jjustin mc';
-- parts whose thread was dropped
DELETE FROM sf.parts p WHERE NOT EXISTS (SELECT 1 FROM sf.threads t WHERE t.thread_key = p.thread_key);

-- 4f looks threads up by person, so index before it
CREATE INDEX ON sf.threads (phase, last_at);
CREATE INDEX ON sf.threads (person_key);
CREATE INDEX ON sf.threads (bucket);
CREATE UNIQUE INDEX ON sf.threads (seq);
ANALYZE sf.threads; ANALYZE sf.parts;

------------------------------------------------------------------------------------------------
-- 4f. Person-level preferences, one value each: the contact first, then their latest opportunity, then their
--     latest lead. Checkboxes default to unticked on every object, so ticked anywhere counts.
------------------------------------------------------------------------------------------------
UPDATE sf.people p SET custom = p.custom || x.prefs
FROM (
  SELECT pe.person_key, jsonb_strip_nulls(jsonb_build_object(
           'skill_level', coalesce(sf.nz(c.skill_level__c), sf.nz(o.skill_level__c), sf.nz(l.skill_level__c)),
           'ntrp', coalesce(sf.nz(c.playing_level_ntrp__c), sf.nz(o.playing_level_ntrp__c), sf.nz(l.playing_level_ntrp__c)),
           'singles', coalesce(c.singles__c = '1' OR ll.singles, false),
           'doubles', coalesce(c.doubles__c = '1' OR o.doubles__c = '1' OR ll.doubles, false),
           'match_play', coalesce(c.match_play__c = '1' OR o.match_play__c = '1' OR ll.match_play, false),
           'practice_play', coalesce(c.practice_play__c = '1' OR o.practice_play__c = '1' OR ll.practice_play, false),
           -- the lead's Pro List short link points at the same page; used when no Suggested Pro URL exists
           'suggested_pro_url', sf.pyc_url(coalesce(sf.nz(a.suggested_pro_url__c), sf.nz(o.suggested_pro_url__c), sf.nz(l.suggested_pro_url__c),
                                                    sf.nz(l.pro_list_url__c))),
           'membership_checkout_url', sf.nz(l.membership_checkout_url__c),
           'drip_step', sf.drip_step(l))) AS prefs
  FROM sf.people pe
  LEFT JOIN sf.contact c ON pe.person_key = 'contact:' || c.id
  LEFT JOIN sf.account a ON a.id = c.accountid
  LEFT JOIN LATERAL (SELECT o.* FROM sf.threads t JOIN sf.opportunity o ON o.id = t.custom->>'salesforce_id'
                     WHERE t.person_key = pe.person_key AND t.sf_object = 'opportunity' ORDER BY t.created_at DESC LIMIT 1) o ON true
  LEFT JOIN LATERAL (SELECT l.* FROM sf.l_person lp JOIN sf.lead l ON l.id = lp.lead_id
                     WHERE lp.person_key = pe.person_key ORDER BY l.createddate DESC LIMIT 1) l ON true
  LEFT JOIN LATERAL (SELECT bool_or(l2.singles__c = '1') AS singles, bool_or(l2.doubles__c = '1') AS doubles,
                            bool_or(l2.match_play__c = '1') AS match_play, bool_or(l2.practice_play__c = '1') AS practice_play
                     FROM sf.l_person lp JOIN sf.lead l2 ON l2.id = lp.lead_id WHERE lp.person_key = pe.person_key) ll ON true
) x
WHERE x.person_key = p.person_key;


------------------------------------------------------------------------------------------------
-- 4g. SMS opt-outs: a person whose latest keyword reply (letters only, as KlaviyoListener matches live
--     replies) is an opt-out gets sms_opted_out_at. Opt-in words only count after an opt-out.
------------------------------------------------------------------------------------------------
UPDATE sf.people p SET custom = p.custom || jsonb_build_object('sms_opted_out_at', to_char(k.opted_out_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
FROM (
  SELECT t.person_key,
         max(pa.created_at) FILTER (WHERE kw IN ('STOP', 'STOPALL', 'UNSUBSCRIBE', 'CANCEL', 'END', 'QUIT', 'REVOKE', 'OPTOUT')) AS opted_out_at,
         max(pa.created_at) FILTER (WHERE kw IN ('START', 'UNSTOP', 'YES')) AS opted_in_at
  FROM sf.parts pa
  JOIN sf.threads t ON t.thread_key = pa.thread_key
  CROSS JOIN LATERAL (SELECT regexp_replace(upper(pa.body), '[^A-Z]', '', 'g') AS kw) k
  WHERE pa.kind = 'sms' AND pa.direction = 'incoming' AND length(pa.body) < 40
  GROUP BY t.person_key
) k
WHERE k.person_key = p.person_key AND k.opted_out_at IS NOT NULL AND (k.opted_in_at IS NULL OR k.opted_in_at < k.opted_out_at);

SELECT phase, sf_object, count(*) AS threads, sum(parts_count) AS parts FROM sf.threads GROUP BY 1, 2 ORDER BY 1, 2;
SELECT bucket, count(*) FROM sf.threads GROUP BY 1 ORDER BY 2 DESC;
SELECT action, count(*), max(detail) FROM sf.cleaning_log WHERE stage IN ('parts', 'threads') GROUP BY 1 ORDER BY 1;
