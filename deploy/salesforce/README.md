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

## No data loss

Every imported record carries the full source row(s) under `additional_attributes.source.salesforce`
(contacts: Contact + Account + Leads; conversations: Case/Opportunity/Lead/Staging row; messages:
EmailMessage/Interaction/Note minus the body). Keep the staging DB (or `pg_dump` it to Spaces) as the
archive; `salesforce_id` on every record is the key back into it.

## Re-running a stage

- Loader: `ONLY=interaction,legacy_note deploy/salesforce/load_staging.sh "<zip dir>"` truncates and reloads those tables.
- Transform: stages are independent files under `sql/`; `transform.sh 02 03 04` rebuilds from people onwards.
- Import: a new `salesforce:import` after a transform change re-walks everything and only adds what is
  new (existing items are skipped by mapping).
