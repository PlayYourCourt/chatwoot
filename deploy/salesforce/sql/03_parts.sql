-- Stage 3: message parts (SMS interactions, emails, Freshdesk notes) with the thread each belongs to.
-- Thread keys: case:<CaseId> | opp:<canonical OpportunityId> | lead:<LeadId>:<pyc number>
--              account:<AccountId>:<pyc number> | fd:<freshdesk ticket id>
SET client_min_messages = warning;
SET search_path = sf, public;
DELETE FROM sf.cleaning_log WHERE stage = 'parts';  -- this stage rewrites its own log rows on re-run

------------------------------------------------------------------------------------------------
-- 3a. Canonical records for Freshdesk-era duplicates
------------------------------------------------------------------------------------------------
-- Several Opportunities can carry the same Freshdesk ticket id (lead conversions re-created them);
-- the oldest is canonical and owns the ticket's notes.
DROP TABLE IF EXISTS sf.opp_canon;
CREATE TABLE sf.opp_canon AS
SELECT o.id AS opp_id,
       sf.nz(o.pyc_legacy_id__c) AS legacy_id,
       CASE WHEN sf.nz(o.pyc_legacy_id__c) IS NULL THEN o.id
            ELSE first_value(o.id) OVER (PARTITION BY sf.nz(o.pyc_legacy_id__c) ORDER BY sf.ts(o.createddate), o.id) END AS canon_id
FROM sf.opportunity o;
CREATE UNIQUE INDEX ON sf.opp_canon (opp_id);
CREATE INDEX ON sf.opp_canon (legacy_id);
CREATE INDEX ON sf.opp_canon (canon_id);

-- Case ids by Freshdesk ticket id (oldest wins)
DROP TABLE IF EXISTS sf.case_legacy;
CREATE TABLE sf.case_legacy AS
SELECT DISTINCT ON (sf.nz(pyc_legacy_id__c)) sf.nz(pyc_legacy_id__c) AS legacy_id, id AS case_id
FROM sf."case" WHERE sf.nz(pyc_legacy_id__c) IS NOT NULL
ORDER BY sf.nz(pyc_legacy_id__c), sf.ts(createddate), id;
CREATE UNIQUE INDEX ON sf.case_legacy (legacy_id);

-- Freshdesk tickets that exist only in the staging table: one canonical row per ticket id.
DROP TABLE IF EXISTS sf.fd_ticket;
CREATE TABLE sf.fd_ticket AS
SELECT DISTINCT ON (s.legacy_id) s.legacy_id, s.id AS staging_id
FROM sf.s_clean s
WHERE s.legacy_id IS NOT NULL
  AND s.case_id IS NULL AND s.opp_id IS NULL
  AND NOT EXISTS (SELECT 1 FROM sf.opp_canon oc WHERE oc.legacy_id = s.legacy_id)
  AND NOT EXISTS (SELECT 1 FROM sf.case_legacy cl WHERE cl.legacy_id = s.legacy_id)
ORDER BY s.legacy_id, (s.account_id IS NULL), s.created_at DESC;
CREATE UNIQUE INDEX ON sf.fd_ticket (legacy_id);
CREATE INDEX ON sf.fd_ticket (staging_id);

------------------------------------------------------------------------------------------------
-- 3b. SMS interactions
--   * failed/undelivered dropped, duplicates within a minute dropped
--   * automated drip messages older than 3 months are condensed: only the last automated message
--     before each customer reply is kept, and one private note per thread records the sequence
--   * no verbatim copy on SMS rows (status/number/SID already travel as message metadata)
------------------------------------------------------------------------------------------------
DROP TABLE IF EXISTS sf.p_sms;
CREATE UNLOGGED TABLE sf.p_sms AS
WITH kept AS (
  SELECT i.id,
         sf.ts(i.createddate) AS created_at,
         CASE WHEN i.tabyot__direction__c = 'Inbound' THEN 'incoming' ELSE 'outgoing' END AS direction,
         CASE WHEN i.tabyot__direction__c = 'Inbound' THEN sf.nz(i.tabyot__to_phone__c) ELSE sf.nz(i.tabyot__from_phone__c) END AS pyc_number,
         sf.nz(i.tabyot__record_id__c) AS record_id,
         coalesce(sf.nz(i.tabyot__message__c), '') AS body,
         i.tabyot__from_phone__c AS from_phone, i.tabyot__to_phone__c AS to_phone,
         i.tabyot__status__c AS sf_status,
         (sf.nz(i.tabyot__is_automated_msg__c) = '1') AS automated,
         sf.nz(i.drip_tracking__c) AS drip_step,
         sf.nz(i.tabyot__sid__c) AS sid,
         CASE left(sf.nz(i.tabyot__record_id__c), 3)
           WHEN '500' THEN 'case:' || i.tabyot__record_id__c
           WHEN '006' THEN 'opp:' || coalesce(oc.canon_id, i.tabyot__record_id__c)
           WHEN '00Q' THEN 'lead:' || i.tabyot__record_id__c || ':' || coalesce(
                  CASE WHEN i.tabyot__direction__c = 'Inbound' THEN sf.nz(i.tabyot__to_phone__c) ELSE sf.nz(i.tabyot__from_phone__c) END, 'unknown')
           WHEN '001' THEN 'account:' || i.tabyot__record_id__c || ':' || coalesce(
                  CASE WHEN i.tabyot__direction__c = 'Inbound' THEN sf.nz(i.tabyot__to_phone__c) ELSE sf.nz(i.tabyot__from_phone__c) END, 'unknown')
         END AS thread_key
  FROM sf.interaction i
  LEFT JOIN sf.opp_canon oc ON left(i.tabyot__record_id__c, 3) = '006' AND oc.opp_id = i.tabyot__record_id__c
  WHERE coalesce(i.tabyot__status__c, '') NOT IN ('failed', 'undelivered')
    AND sf.nz(i.tabyot__record_id__c) IS NOT NULL
),
dedup AS (
  SELECT k.*, row_number() OVER (PARTITION BY k.direction, k.from_phone, k.to_phone, k.body, date_trunc('minute', k.created_at)
                                 ORDER BY k.created_at, k.id) AS rn
  FROM kept k
),
flagged AS (
  SELECT d.*, lead(d.direction) OVER (PARTITION BY d.thread_key ORDER BY d.created_at, d.id) AS next_direction
  FROM dedup d WHERE d.rn = 1 AND d.thread_key IS NOT NULL
)
SELECT f.id, f.record_id, left(f.record_id, 3) AS record_kind, f.pyc_number, f.direction, f.created_at,
       CASE WHEN media.urls IS NULL THEN f.body ELSE concat_ws(E'\n', nullif(f.body, ''), media.urls) END AS body,
       CASE f.sf_status WHEN 'delivered' THEN 'delivered' WHEN 'received' THEN 'delivered' WHEN 'read' THEN 'read' ELSE 'sent' END AS status,
       f.automated, f.drip_step, f.sid, f.thread_key,
       -- condensed: automated, outgoing, older than 3 months, and not the last message before a reply
       (f.automated AND f.direction = 'outgoing' AND f.created_at < current_date - interval '3 months'
          AND coalesce(f.next_direction, '') <> 'incoming') AS condensed
FROM flagged f
LEFT JOIN LATERAL (
  SELECT string_agg('[' || coalesce(sf.nz(m.tabyot__content_type__c), 'media') || '] ' || sf.nz(m.tabyot__media_url__c), E'\n') AS urls
  FROM sf.interaction_media m WHERE m.tabyot__text_anything_interaction__c = f.id AND sf.nz(m.tabyot__media_url__c) IS NOT NULL) media ON true;
CREATE INDEX ON sf.p_sms (thread_key);

-- one private note per thread summarising the condensed drip messages
DROP TABLE IF EXISTS sf.p_drip_summary;
CREATE UNLOGGED TABLE sf.p_drip_summary AS
SELECT thread_key,
       min(created_at) AS created_at,
       mode() WITHIN GROUP (ORDER BY pyc_number) AS pyc_number,
       format('Automated drip sequence: %s SMS sent between %s and %s (%s). Older automated messages were condensed on import; '
              'replies and the last message before each reply are kept.',
              count(*), to_char(min(created_at), 'YYYY-MM-DD'), to_char(max(created_at), 'YYYY-MM-DD'),
              coalesce(string_agg(DISTINCT regexp_replace(drip_step, ' (Sent|Failed)$', ''), ', ' ORDER BY regexp_replace(drip_step, ' (Sent|Failed)$', '')), 'steps unknown')) AS body,
       jsonb_build_object('condensed_count', count(*), 'first_at', min(created_at), 'last_at', max(created_at),
                          'steps', coalesce(jsonb_agg(DISTINCT drip_step) FILTER (WHERE drip_step IS NOT NULL), '[]'::jsonb),
                          'sids', coalesce(jsonb_agg(sid) FILTER (WHERE sid IS NOT NULL), '[]'::jsonb)) AS raw
FROM sf.p_sms WHERE condensed GROUP BY thread_key;

INSERT INTO sf.cleaning_log
SELECT 'parts', 'sms_skipped_failed_or_undelivered', NULL, count(*)::text FROM sf.interaction WHERE tabyot__status__c IN ('failed', 'undelivered');
INSERT INTO sf.cleaning_log
SELECT 'parts', 'sms_deduplicated', NULL, ((SELECT count(*) FROM sf.interaction WHERE coalesce(tabyot__status__c, '') NOT IN ('failed', 'undelivered')
                                             AND sf.nz(tabyot__record_id__c) IS NOT NULL) - (SELECT count(*) FROM sf.p_sms))::text;
INSERT INTO sf.cleaning_log SELECT 'parts', 'sms_drip_condensed', NULL, count(*)::text FROM sf.p_sms WHERE condensed;
INSERT INTO sf.cleaning_log SELECT 'parts', 'sms_drip_summary_notes', NULL, count(*)::text FROM sf.p_drip_summary;

------------------------------------------------------------------------------------------------
-- 3c. Emails (all parented to Cases)
------------------------------------------------------------------------------------------------
DROP TABLE IF EXISTS sf.p_email;
CREATE UNLOGGED TABLE sf.p_email AS
WITH dedup AS (
  SELECT e.*, row_number() OVER (PARTITION BY coalesce(sf.nz(e.messageidentifier), e.id) ORDER BY sf.ts(e.messagedate), e.id) AS rn
  FROM sf.email_message e
  WHERE left(sf.nz(e.parentid), 3) = '500'
)
SELECT d.id, 'case:' || d.parentid AS thread_key,
       coalesce(sf.ts(d.messagedate), sf.ts(d.createddate)) AS created_at,
       CASE WHEN d.incoming = '1' THEN 'incoming' ELSE 'outgoing' END AS direction,
       sf.nz(d.subject) AS subject,
       coalesce(sf.nz(d.textbody), sf.strip_html(d.htmlbody), '') AS body,
       sf.nz(d.fromname) AS author_name,
       lower(sf.nz(d.fromaddress)) AS from_addr,
       lower(sf.nz(d.toaddress)) AS to_addr,
       lower(sf.nz(d.ccaddress)) AS cc_addr,
       (SELECT (regexp_matches(lower(coalesce(d.toaddress, '') || ' ' || coalesce(d.fromaddress, '') || ' ' || coalesce(d.ccaddress, '')),
                               '([a-z0-9._-]+@playyourcourt\.com)'))[1] LIMIT 1) AS pyc_address,
       (d.hasattachment = '1') AS has_attachment,
       -- raw copy without the bodies (they are the message content; HtmlBody stays in the staging archive)
       sf.raw(d.*) - 'textbody' - 'htmlbody' - 'rn' AS raw
FROM dedup d
WHERE d.rn = 1;
CREATE INDEX ON sf.p_email (thread_key);
INSERT INTO sf.cleaning_log SELECT 'parts', 'email_deduplicated', NULL, ((SELECT count(*) FROM sf.email_message) - (SELECT count(*) FROM sf.p_email))::text;

------------------------------------------------------------------------------------------------
-- 3d. Freshdesk notes
------------------------------------------------------------------------------------------------
DROP TABLE IF EXISTS sf.p_note;
CREATE UNLOGGED TABLE sf.p_note AS
SELECT n.id,
       coalesce(
         CASE WHEN sf.nz(n.case__c) IS NOT NULL THEN 'case:' || sf.nz(n.case__c) END,
         CASE WHEN oc.canon_id IS NOT NULL THEN 'opp:' || oc.canon_id END,
         CASE WHEN oct.canon_id IS NOT NULL THEN 'opp:' || oct.canon_id END,
         CASE WHEN cl.case_id IS NOT NULL THEN 'case:' || cl.case_id END,
         CASE WHEN ft.legacy_id IS NOT NULL THEN 'fd:' || ft.legacy_id END
       ) AS thread_key,
       coalesce(sf.ts(n.ticket_created_date_time__c), sf.ts(n.createddate)) AS created_at,
       CASE
         WHEN b ~* '^(sms from|voice call from|user filled out|user purchased|user replied|customer replied|incoming)' THEN 'incoming'
         WHEN b ~* '^([A-Za-z.\- ]{1,40} sent (a|an) (sms|email|mms)|intro email|conversation starter|ld ?[0-9] sent|pyc sent|automated|outgoing)' THEN 'outgoing'
         WHEN sf.nz(n.incoming__c) = '1' THEN 'incoming'
         WHEN sf.nz(n.private__c) = '1' THEN 'note'
         ELSE 'outgoing' END AS direction,
       b AS body,
       sf.nz(n.user_id__c) AS author_id,
       sf.raw(n.*) - 'body__c' AS raw
FROM sf.legacy_note n
CROSS JOIN LATERAL (SELECT coalesce(sf.nz(n.body__c), '') AS b) x
LEFT JOIN sf.opp_canon oc  ON sf.nz(n.opportunity__c) IS NOT NULL AND oc.opp_id = sf.nz(n.opportunity__c)
LEFT JOIN sf.opp_canon oct ON oc.opp_id IS NULL AND sf.nz(n.ticket_id__c) IS NOT NULL AND oct.legacy_id = sf.nz(n.ticket_id__c) AND oct.opp_id = oct.canon_id
LEFT JOIN sf.case_legacy cl ON sf.nz(n.ticket_id__c) IS NOT NULL AND cl.legacy_id = sf.nz(n.ticket_id__c)
LEFT JOIN sf.fd_ticket ft   ON sf.nz(n.ticket_id__c) IS NOT NULL AND ft.legacy_id = sf.nz(n.ticket_id__c)
WHERE b <> ''
  AND b !~ '^created_by: '
  AND sf.nz(n.source__c) IS DISTINCT FROM '4';
CREATE INDEX ON sf.p_note (thread_key);
INSERT INTO sf.cleaning_log SELECT 'parts', 'note_skipped_system_or_blank', NULL,
  ((SELECT count(*) FROM sf.legacy_note) - (SELECT count(*) FROM sf.p_note))::text;
INSERT INTO sf.cleaning_log SELECT 'parts', 'note_without_resolvable_ticket', NULL, count(*)::text FROM sf.p_note WHERE thread_key IS NULL;

------------------------------------------------------------------------------------------------
-- 3e. All parts
------------------------------------------------------------------------------------------------
DROP TABLE IF EXISTS sf.parts;
CREATE TABLE sf.parts (
  part_id     text PRIMARY KEY,
  thread_key  text NOT NULL,
  kind        text NOT NULL,          -- sms | email | note
  created_at  timestamptz NOT NULL,
  direction   text NOT NULL,          -- incoming | outgoing | note
  body        text NOT NULL,
  subject     text,
  status      text,
  author_name text,
  from_addr   text,
  to_addr     text,
  cc_addr     text,
  pyc_number  text,
  pyc_address text,
  automated   boolean,
  raw         jsonb NOT NULL DEFAULT '{}'
);
INSERT INTO sf.parts (part_id, thread_key, kind, created_at, direction, body, status, pyc_number, automated, raw)
SELECT 'sms:' || id, thread_key, 'sms', created_at, direction, body, status, pyc_number, automated,
       jsonb_strip_nulls(jsonb_build_object('sid', sid, 'drip_step', drip_step))
FROM sf.p_sms WHERE NOT condensed;
INSERT INTO sf.parts (part_id, thread_key, kind, created_at, direction, body, pyc_number, automated, raw)
SELECT 'drip:' || thread_key, thread_key, 'sms', created_at, 'note', body, pyc_number, true, raw FROM sf.p_drip_summary;
INSERT INTO sf.parts (part_id, thread_key, kind, created_at, direction, body, subject, author_name, from_addr, to_addr, cc_addr, pyc_address, raw)
SELECT 'email:' || id, thread_key, 'email', created_at, direction, body, subject, author_name, from_addr, to_addr, cc_addr, pyc_address, raw FROM sf.p_email;
INSERT INTO sf.parts (part_id, thread_key, kind, created_at, direction, body, raw)
SELECT 'note:' || id, thread_key, 'note', created_at, direction, body, raw FROM sf.p_note WHERE thread_key IS NOT NULL;
CREATE INDEX ON sf.parts (thread_key, created_at);
ANALYZE sf.parts;

SELECT kind, direction, count(*) FROM sf.parts GROUP BY 1, 2 ORDER BY 1, 2;
