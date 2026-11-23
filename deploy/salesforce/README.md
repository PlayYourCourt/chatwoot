# Salesforce → Chatwoot import

Imports the Salesforce weekly export (Contacts/Accounts/Leads, Cases + emails, TextAnything SMS,
Opportunities and the Freshdesk-era tickets/notes that live in `Staging__c`/`Legacy_Notes__c`) into
Chatwoot contacts and conversations. Built on Chatwoot's `DataImports` framework (the same one used
for Freshdesk and Intercom): resumable, idempotent, progress visible under Settings → Data.

```
ZIPs ─load_staging.sh─▶ staging Postgres (raw tables) ─transform.sh─▶ sf.people / sf.threads / sf.parts
                                                          │
Chatwoot rails + sidekiq ◀── SALESFORCE_STAGING_DATABASE_URL ──┘   rails salesforce:import[...]
```

## Requirements

- Docker. The staging DB is a throwaway `postgres:16` container (`docker-compose.staging.yml`) on the
  Chatwoot compose network, reachable from rails/sidekiq as `sf-staging`.
- `unzip` on the host (`apt-get install unzip` on the Droplet); the loader reads the export ZIPs with it.
- ~40 GB free disk for the full export (2.7 GB ZIPs, ~15 GB staging DB, Chatwoot DB growth ~10 GB).
- `SALESFORCE_STAGING_DATABASE_URL=postgres://sf:sf@sf-staging:5432/sf` in the Chatwoot env file, and
  the rails/sidekiq containers restarted so they pick it up.

## Run order

```bash
# 1. staging database
docker compose -f deploy/salesforce/docker-compose.staging.yml up -d

# 2. load the CSVs straight out of the ZIPs (≈ 30–60 min for the full export; ONLY=table1,table2 to redo a few)
deploy/salesforce/load_staging.sh "sales_force_exports/nov 6"

# 3. clean, dedupe, bucket (≈ 10–20 min); prints counts and the cleaning log summary
deploy/salesforce/transform.sh          # or: deploy/salesforce/transform.sh 03 04

# 4. labels + custom attribute definitions in Chatwoot (idempotent)
docker compose -f deploy/docker-compose.local.yml -f deploy/docker-compose.local.prebuilt.yml \
  exec rails bundle exec rails "salesforce:setup[1]"

# 5. start an import: phase = salesforce | freshdesk, optional since date (threads active on/after it)
docker compose ... exec rails bundle exec rails "salesforce:import[1,salesforce,2026-08-10]"   # local 90-day slice
docker compose ... exec rails bundle exec rails "salesforce:import[1,salesforce]"              # full Salesforce era
docker compose ... exec rails bundle exec rails "salesforce:import[1,freshdesk]"               # Freshdesk era, second pass

# 6. watch: Settings → Data in the dashboard, or
docker compose ... exec rails bundle exec rails "salesforce:report[1]"
```

Only one import per account runs at a time; the task refuses to start another while one is active.
Re-running an import never duplicates: every contact, conversation and message is keyed by its
Salesforce id (`DataImportMapping`), and already-imported items are counted as skipped.

## Inboxes

Threads are bucketed in SQL (`sf.threads.bucket`) and resolved to inboxes by
`DataImports::Salesforce::InboxResolver`:

| bucket | inbox |
|---|---|
| `email:<address>` | the live email inbox with that address, else placeholder "Salesforce Import - Email <address>" |
| `sms:<number>` | the live Twilio inbox with that number, else placeholder "Salesforce Import - SMS <name> (<number>)" |
| `web-forms`, `freshdesk-sales`, `freshdesk-support`, `support-tasks` | placeholders |

Placeholders are API-channel inboxes (nothing can be sent from them). When a real Twilio inbox exists
for a number, move the history across:

```bash
rails "salesforce:relocate_inbox[<placeholder inbox id>,<twilio inbox id>]"
```

## What gets cleaned (see `sf.cleaning_log` after the transform)

- names `null`/`none`/`test`/… blanked; junk emails blanked; phones normalized to E.164
- placeholder phones (repeated digits, numbers shared by >3 people) blanked everywhere
- contacts sharing an email merged (oldest, most complete wins; the others' ids kept in `sf_merged_ids`)
- leads attached to their contact by conversion, email or phone; repeated lead submissions collapsed
- SMS: `failed`/`undelivered` dropped, duplicates within a minute dropped
- emails deduplicated on `MessageIdentifier`; Freshdesk system notes (`created_by: …`) dropped
- threads with no person or no content skipped
- enhanced notes (the Notes related list on Accounts, Opportunities and Leads; stage `05_notes.sql`) become
  Chatwoot contact notes on the person, headed by title, record and author; the server-written
  `System - Opp Close` / `System - Drip Halted` notes are dropped. They are only in a **full** export (the
  trimmed exports have no `ContentVersion.csv`), and only an export made with *Include Salesforce Files and
  Salesforce CRM Content document versions* ticked carries the note bodies; without it the loader warns and the
  transform uses Salesforce's 255-character preview, which truncates roughly one note in ten.

## No data loss

Every imported record carries the full source row(s) under `additional_attributes.source.salesforce`
(contacts: Contact + Account + Leads; conversations: Case/Opportunity/Lead/Staging row; messages:
EmailMessage/Interaction/Note minus the body). Keep the staging DB (or `pg_dump` it to Spaces) as the
archive; `salesforce_id` on every record is the key back into it.

## Production (Droplet)

Same pipeline, run on the Droplet; the staging container joins the `chatwoot` compose network there too.
Disk: ~15 GB staging plus ~10 GB Chatwoot growth; the Droplet's 160 GB covers it.

```bash
# 0. copy the export up (from your machine); keep the folder name so the loader finds every part
rsync -av --progress "sales_force_exports/nov 18/" root@<droplet>:/opt/chatwoot/sales_force_exports/nov\ 18/

# on the Droplet, from the repo checkout
cd /opt/chatwoot
grep -E 'SALESFORCE_STAGING_DATABASE_URL|SALESFORCE_OWNER_EMAILS' deploy/.env.do   # both must be set
docker compose -f deploy/salesforce/docker-compose.staging.yml up -d
deploy/salesforce/load_staging.sh "sales_force_exports/nov 18"      # 30–60 min
deploy/salesforce/transform.sh                                     # 10–20 min, prints counts

R="docker compose -f deploy/docker-compose.do.yml exec rails bundle exec rails"
$R "salesforce:setup[1]"                      # labels, attributes, teams used by the import (idempotent)
$R "salesforce:import[1,salesforce]"          # full Salesforce era; runs in Sidekiq, resumable
$R "salesforce:report[1]"                     # progress; also Settings → Data in the dashboard
$R "salesforce:import[1,freshdesk]"           # second pass once the first reports complete
```

The import runs as parallel page chains (6 by default; the fifth argument sets it, e.g.
`salesforce:import[1,salesforce,,,8]`): rows are split by `seq % chains`, each chain keeps its own cursor and the last
one to finish a stage starts the next. Against the managed database a single chain manages ~10 contacts/s, so the
chains are what make the 720k contacts fit in hours rather than days. If the report stops moving while the status
is still `processing` (a Sidekiq restart can drop a chain), or the status is `failed`, `salesforce:resume[1]` re-enqueues
the unfinished chains; `salesforce:abandon[1]` stops an import so a new one can start. A statement timeout on a page
re-runs that page a few seconds later rather than failing the import.

Afterwards, `salesforce:merge_placeholders[1]` folds any duplicate placeholder inboxes (chains that met a new bucket
at the same moment, before the account lock in `PlaceholderInboxBuilder` existed) into the oldest one, then
`salesforce:relocate_inbox[<placeholder>,<twilio inbox>]` for each number that now has a real Twilio
inbox, then stop the staging container (`docker compose -f deploy/salesforce/docker-compose.staging.yml down`;
keep the volume, or `pg_dump` it to Spaces as the archive).

## Re-importing a newer export

Load and transform the new export over the old staging data (the loader truncates each table), then run
`salesforce:import` again. What happens to each kind of record:

| Record | Already imported (mapped by Salesforce id) | New in this export |
|---|---|---|
| Contact | **left as is**: name, email, phone, custom attributes, type are not touched | created |
| Conversation | **left as is**: status, owner, team, priority, labels are not touched | created with its state |
| Message | skipped | appended to its conversation, even an existing one |

Items that failed in an earlier import (`salesforce:report` lists them) are walked again by the next import even
when `since` would leave them out; their Salesforce ids travel in the import's `source_metadata`.

So by default a lead whose Salesforce status changed since the last import keeps the status it has in Chatwoot,
which is what you want once agents work in Chatwoot (the import must not undo their changes).

While Salesforce is still the system of record, add `refresh` to make its state win:

```bash
$R "salesforce:import[1,salesforce,,refresh]"
```

A refresh import re-applies to already-imported records: conversation status (and snooze), owner, team,
priority and labels (added, never removed); contact name, type (lead → customer only) and custom /
source attributes. Email and phone are never changed by a refresh. Nothing is deleted.

## Re-running a stage

- Loader: `ONLY=interaction,legacy_note deploy/salesforce/load_staging.sh "<zip dir>"` truncates and reloads those tables.
- Transform: stages are independent files under `sql/`; `transform.sh 02 03 04` rebuilds from people onwards.
- Import: a new `salesforce:import` after a transform change re-walks everything and only adds what is
  new (existing items are skipped by mapping).
