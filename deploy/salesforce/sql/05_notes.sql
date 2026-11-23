-- Stage 5: enhanced notes (the "Notes" related list on Accounts, Opportunities and Leads; ContentNote in the
-- API, FileType SNOTE in ContentVersion) -> sf.person_notes, one row per note with the person it belongs to.
-- The importer turns each into a Chatwoot contact note. Bodies come from the ContentVersion files when the
-- export includes them (sf.content_note_body, see load_staging.sh), otherwise from the 255-character TextPreview.
SET client_min_messages = warning;
SET search_path = sf, public;
DELETE FROM sf.cleaning_log WHERE stage = 'notes';

DROP TABLE IF EXISTS sf.person_notes;
CREATE TABLE sf.person_notes (
  note_key   text PRIMARY KEY,   -- 'note:' || ContentDocumentId
  person_key text NOT NULL,
  title      text,               -- NULL for "Untitled Note"
  body       text NOT NULL,
  author     text,
  about      text,               -- the Salesforce record the note hangs off: Opportunity "<name>", Account, Lead
  created_at timestamptz,
  raw        jsonb NOT NULL DEFAULT '{}'
);
CREATE INDEX ON sf.person_notes (person_key);

-- The trimmed weekly exports have no ContentVersion.csv; then there are no notes to stage and the importer sees
-- an empty table.
SELECT to_regclass('sf.content_version') IS NULL AS no_notes \gset
\if :no_notes
\echo 'no ContentVersion in this export: sf.person_notes left empty'
\quit
\endif

CREATE INDEX IF NOT EXISTS content_version_doc_idx ON sf.content_version (contentdocumentid);
CREATE INDEX IF NOT EXISTS content_link_doc_idx ON sf.content_document_link (contentdocumentid);
CREATE TABLE IF NOT EXISTS sf.content_note_body (id text PRIMARY KEY, body text);

-- A note can be linked to several records (a converted lead links its lead, account and opportunity): the
-- opportunity wins, then the account, then the lead. Every path resolves through the same person aliases the
-- threads use, so a note lands on the same contact as the opportunity's conversation.
INSERT INTO sf.person_notes
SELECT 'note:' || v.contentdocumentid,
       l.person_key,
       nullif(sf.nz(v.title), 'Untitled Note'),
       coalesce(nullif(sf.strip_html(b.body), ''), sf.nz(v.textpreview)),
       own.name,
       l.about,
       sf.ts(v.createddate),
       sf.raw(v.*) - 'textpreview'
FROM sf.content_version v
LEFT JOIN sf.content_note_body b ON b.id = v.id
LEFT JOIN sf.owner_name own ON own.id = v.createdbyid
LEFT JOIN LATERAL (
  SELECT x.person_key, x.about
  FROM sf.content_document_link cdl
  LEFT JOIN sf.opportunity o ON o.id = cdl.linkedentityid
  LEFT JOIN sf.opp_canon oc ON oc.opp_id = o.id
  LEFT JOIN sf.threads t ON t.thread_key = 'opp:' || oc.canon_id
  CROSS JOIN LATERAL (SELECT
    CASE left(cdl.linkedentityid, 3)
      WHEN '006' THEN coalesce(t.person_key, sf.person_for('account', sf.nz(o.accountid)))
      WHEN '001' THEN sf.person_for('account', cdl.linkedentityid)
      WHEN '00Q' THEN sf.person_for('lead', cdl.linkedentityid)
    END AS person_key,
    CASE left(cdl.linkedentityid, 3)
      WHEN '006' THEN 'Opportunity "' || coalesce(sf.nz(o.name), o.id) || '"'
      WHEN '001' THEN 'Account'
      WHEN '00Q' THEN 'Lead'
    END AS about,
    CASE left(cdl.linkedentityid, 3) WHEN '006' THEN 1 WHEN '001' THEN 2 ELSE 3 END AS prio) x
  WHERE cdl.contentdocumentid = v.contentdocumentid AND x.person_key IS NOT NULL
  ORDER BY x.prio
  LIMIT 1) l ON true
WHERE v.filetype = 'SNOTE' AND v.islatest = '1' AND v.isdeleted = '0'
  AND l.person_key IS NOT NULL
  -- "System - Opp Close" / "System - Drip Halted" are written by the PYC server; the conversation's labels and
  -- attributes already carry that state, so only notes a person wrote become contact notes.
  AND (own.name = 'PYC Server' AND sf.nz(v.title) LIKE 'System - %') IS NOT TRUE
  AND coalesce(nullif(sf.strip_html(b.body), ''), sf.nz(v.textpreview)) IS NOT NULL;

INSERT INTO sf.cleaning_log SELECT 'notes', 'imported', NULL, count(*)::text FROM sf.person_notes;
INSERT INTO sf.cleaning_log SELECT 'notes', 'body_from_preview_only', NULL, count(*)::text
  FROM sf.person_notes n
  WHERE NOT EXISTS (SELECT 1 FROM sf.content_version v JOIN sf.content_note_body b ON b.id = v.id WHERE 'note:' || v.contentdocumentid = n.note_key);
INSERT INTO sf.cleaning_log SELECT 'notes', 'skipped_no_person_or_blank', NULL,
  ((SELECT count(*) FROM sf.content_version WHERE filetype = 'SNOTE' AND islatest = '1' AND isdeleted = '0') - (SELECT count(*) FROM sf.person_notes))::text;

SELECT action, detail FROM sf.cleaning_log WHERE stage = 'notes' ORDER BY action;
