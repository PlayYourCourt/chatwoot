# n8n: SMS sequence engine

Multi-step SMS sequences (lead drips, win-backs) run in n8n with their state in a `seq` Postgres
database, sent through Chatwoot. Design: `DESIGN.md` (read its "Adjustments" section first). This file
is the runbook: what to create, how to run it locally and on the Droplet, and how to update it.

```
Klaviyo / agents ──POST /webhook/enroll|exit|events, labels──▶ n8n API workflows ──▶ seq database
every 5 min: Flow workflow claims due rows ──▶ Gate (Chatwoot DB, read-only) ──▶ Send ──▶ Chatwoot outreach endpoint ──▶ Twilio
```

## Parts

| Where | What |
|---|---|
| `sql/seq_schema.sql` | The six `seq_*` tables and the `seq_engine` grants |
| `sql/chatwoot_readonly.sql` | SELECT grants on the Chatwoot tables the Gate reads |
| `setup_db.sh` | Creates the `n8n` and `seq` databases and the three roles on a cluster, loads both SQL files. Idempotent |
| `build_workflows.py` | Generates `workflows/*.json`: the engine workflows every time, a `Flow: <key>` only when its file is missing |
| `workflows/*.json` | The n8n workflows, pushed with `push.py` |
| `push.py` | Logs in to n8n's REST API, creates or updates each workflow by name, maps credentials and sub-workflows by name, publishes |
| `../.env.n8n.example` | n8n container settings (copy to `.env.n8n`, git-ignored) |
| Chatwoot `salesforce:setup` | Creates the contact attributes (`timezone`, `timezone_source`, `sms_opted_out_at`, `sequence_status`) and labels (`stop-sequence`, `enroll-<flow>`, `in-sequence-<flow>`) |

## One-time setup (local and production)

1. **Databases and roles.** Pick passwords, then:

   ```bash
   # local: Postgres is the compose service, so run psql inside it
   N8N_DB_PASSWORD=n8n SEQ_ENGINE_PASSWORD=seq CHATWOOT_READONLY_PASSWORD=ro \
     PSQL="docker compose -f deploy/docker-compose.local.yml exec -T postgres psql -U postgres" deploy/n8n/setup_db.sh

   # production: the managed cluster's admin URL (DO console → Connection details → doadmin)
   N8N_DB_PASSWORD='…' SEQ_ENGINE_PASSWORD='…' CHATWOOT_READONLY_PASSWORD='…' \
     deploy/n8n/setup_db.sh "postgres://doadmin:…@…ondigitalocean.com:25060/defaultdb?sslmode=require"
   ```

   Single-quote the passwords (bash expands `$word` and `!` otherwise). Re-running only adds what is missing
   and sets the three passwords to the given values, so it also serves to rotate them.
2. **`deploy/.env.n8n`** from `deploy/.env.n8n.example`: the `n8n` database values from step 1 and a fresh
   `N8N_ENCRYPTION_KEY` (`openssl rand -hex 32`). Back that key up: it encrypts the stored credentials.
   Production also needs `N8N_HOST=automations.playyourcourt.com` in `deploy/.env.do` (Caddy reads it)
   and a DNS A record for that host.
3. **Chatwoot**: `rails "salesforce:setup[1]"` (attributes and labels; idempotent). The bot user is tech@:
   copy its access token (Profile Settings → Access Token) and add it as an agent member of every inbox a
   flow sends on (Settings → Inboxes → Collaborators): exits post a private note on the conversation, and an
   agent can only do that on inboxes it belongs to. Note its user id (Settings → Agents, or the URL of its
   profile): the "agent messaged them" rule excludes it.
4. **Start n8n**: `docker compose -f deploy/docker-compose.local.yml up -d n8n` (production:
   `docker compose -f deploy/docker-compose.do.yml up -d`, which also recreates Caddy for the new host).
   Open http://localhost:5678 or https://automations.playyourcourt.com and create the owner account.
5. **Credentials** (Credentials → New):
   - *Postgres* `seq`: host `postgres` (local) or the managed cluster host, database `seq`, user `seq_engine`.
     Production: SSL on, "ignore SSL issues" on (DO uses a private CA).
   - *Postgres* `chatwoot readonly`: same host, database `chatwoot_production`, user `chatwoot_readonly`.
   - *Header Auth* `Chatwoot API token`: name `api_access_token`, value = the tech@ token.
   - *SMTP* `Alerts SMTP`: Postmark SMTP (host `smtp.postmarkapp.com`, port 2525, the server token as user and
     password) in production; `mailhog`:1025 with no auth locally.
6. **Push the workflows**: `N8N_EMAIL=<owner> N8N_PASSWORD=<password> deploy/n8n/push.py` (add
   `N8N_URL=https://automations.playyourcourt.com` in production). It creates or updates every workflow by
   name, wires the credentials and sub-workflows, sets `Seq: error handler` as the error workflow and publishes.
   Re-run it after any change; a `Flow: …` workflow that already has content is left alone unless named.
7. **Flows** ship **paused** with the local database's inbox ids: open each `Flow: <key>` workflow, set `inbox_id` (and the inbox ids
   in the `no_prior_conversation` end rule) in the yellow **Flow config** node, set `status` to `active` and publish. `inbox_id` is the
   Chatwoot inbox (the Twilio number) the texts go out on (tech@ must be a member, see step 3); `status` (`active` / `paused`), `reentry_policy`,
   `reentry_cooldown_days`, `end_rules`, `business_hours`, `holidays`, `flow_window_open`/`close` (contact-local,
   e.g. `10:00`/`18:00`), `spread_hours` and `on_send_failure` are the other settings; `rep_first_name` (default Adam),
   `rep_phone` and `checkout_url` fill the `{{rep_first_name}}`, `{{rep_phone}}` and `{{checkout_url}}` placeholders in
   the step messages (`{{first_name}}`, `{{name}}` and any contact attribute key also work). The flow writes the node into
   `seq_flows` every minute, so the database row is never edited by hand. Flows shipped: `lessons` (six steps) and
   `membership` (one text with the checkout link). End rules: `replied`, `agent_messaged`,
   `purchased`, `purchased_item` (`"skus": [...]`), `label` / `no_label` (`"label"`), `field` (`"field"`, `"op"`: is /
   is_not / set / empty, `"value"`), `no_prior_conversation` (`"inbox_ids": [...]`: exit if the contact had a conversation with at
   least one real message on any of those inboxes before enrolling, e.g. the live Twilio inbox plus its Salesforce import
   inbox; a conversation holding only private notes doesn't count). `no_enrollment_in`
   (`"flows": [...]`: refuse or exit anyone who was ever enrolled in those flows). Independent of any rule, a contact
   can be in **one flow at a time**: enrolling while another flow is active returns `skipped_in_other_flow`. Contacts with
   `exclude_from_drip` checked or `sms_opted_out_at` set are refused at enrollment and exited by the Gate if flagged
   later, for every flow. The legal window (Mon–Sat 9–21, Sun 12–21, in the contact's zone and Central) is
   a constant in the Gate's `Decide` node. The contact's zone comes from its `timezone` attribute, else its
   `postal_code`, else the phone's area code (`tz_data.json`, regenerated by `build_tz_data.py`); a prefix that spans
   zones must be legal in all of them, and a number with nothing known must be legal on both coasts.
   Texts only go to the enrolled number: a contact matched by email takes the new number (the old one is kept as
   `previous_phone_number`), and the row exits `phone_changed` if the contact's number changes later, `contact_deleted`
   if the contact is deleted. After a merge the row follows the contact that holds the number.
   A text Twilio or the carrier fails gets a private note on its conversation (housekeeping, within 15 minutes).
8. **API key** for Klaviyo: `deploy/n8n/api_key.sh klaviyo "<seq database url>"` generates a token, stores only its
   SHA-256 in `seq_api_keys` and prints the token once; put it in Klaviyo's webhook header `Authorization: Bearer <token>`
   and a password manager. Rerun with the same name to rotate it (the old token stops working immediately).
9. **Automation rule** (Settings → Automations): event *Message created*, conditions *Message type = Incoming* and
   *Status = Pending*, action *Open conversation*. Outreach texts start their conversation as pending; this rule hands
   it to agents when the contact replies.
10. **Chatwoot webhook** for the label watcher: Settings → Integrations → Webhooks, URL
   `<n8n>/webhook/chatwoot-events`, event `conversation_updated`.

## Klaviyo side

Locally, Klaviyo reaches n8n at `https://n8n-dev.playyourcourt.com` through the named `chatwoot-dev`
tunnel (`cloudflared tunnel --config deploy/cloudflared.local.yml run`); `deploy/.env.n8n` sets
`N8N_HOST`/`WEBHOOK_URL` to that hostname so the editor shows the public webhook URLs.

Each lead flow gets **one** Webhook action at the start, `POST <n8n>/webhook/enroll` with header
`Authorization: Bearer <token>` and body
`{ "flow": "lessons", "phone_number": "{{ person.phone_number }}", "email": "{{ person.email }}",
"first_name": "{{ person.first_name }}", "last_name": "{{ person.last_name }}", "source": "klaviyo" }`.
The membership flow adds `"checkout_url": "{{ event.checkout_url }}"` (the person's own link; without it the text uses
the Flow config default). Texts go out on a conversation in `pending` status; the contact's reply opens it.
A flow triggered by the `Sale` metric posts to `/webhook/events` with
`{ "kind": "purchase", "phone_number": "{{ person.phone_number }}", "payload": { … } }`. Email steps stay in
Klaviyo.

## Production notes

- Regular (single process) mode. Waiting is rows in `seq_enrollments`, not n8n executions, so restarts and
  deploys lose nothing. Queue mode (`EXECUTIONS_MODE=queue`, Redis, a worker service) is a later config change.
- Backups: `n8n` and `seq` are in the managed cluster's daily backups. The `n8n_data` volume only holds a cache.
- Alerts go where the Housekeeping workflow's notification node points (email via Chatwoot's SMTP or Slack).

## Updating

- **Inbox, policy, holidays, copy, delays**: marketers edit the yellow Flow config / Step config nodes of the flow workflow
  in the editor and **publish** (n8n 2.x runs the published version, not the draft). Rows mid-flow pick the
  change up at their next step. Afterwards export (⋯ → Download) over `workflows/flow_<key>.json` and commit.
- **Engine logic** (Gate, Send, APIs, watcher): edit `build_workflows.py`, run it, `push.py`, commit the JSON.
- **A new flow**: add it to `FLOWS` in `build_workflows.py` (settings + steps), run it (it writes `flow_<key>.json`
  because the file is missing), add the flow key to `SEQUENCE_FLOWS` in Chatwoot's setup, push, then set the real
  `inbox_id` in the Flow config node and publish.
- **Regenerating an existing flow from the script** (the file is editor-owned): delete the file, rebuild,
  `push.py 'Flow: <key>'`.
- **Schema**: add to `sql/seq_schema.sql` with `IF NOT EXISTS` / `ADD COLUMN IF NOT EXISTS` and re-run
  `setup_db.sh`.
- **n8n version**: bump the image tag in both compose files, `up -d`. n8n migrates its own database.
