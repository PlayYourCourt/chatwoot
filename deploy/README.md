# PlayYourCourt Chatwoot deployment

Everything PlayYourCourt-specific for running Chatwoot lives in this folder. Upstream compose files
in the repo root are untouched so merges from `chatwoot/chatwoot` stay clean.

| File | Purpose |
|---|---|
| `docker-compose.local.yml` | Full stack on your laptop: app, Sidekiq, Postgres (pgvector), Redis, Mailhog |
| `docker-compose.do.yml` | DigitalOcean Droplet stack: app, Sidekiq, Redis, Caddy (TLS). Postgres is DO Managed, files are on Spaces |
| `Caddyfile` | Reverse proxy with automatic Let's Encrypt certificates |
| `.env.local.example` / `.env.do.example` | Environment templates. Copy to `.env.local` / `.env.do` (git-ignored) |
| `bin/local-setup.sh` | One-time local bootstrap |
| `bin/droplet-setup.sh` | One-time Droplet bootstrap |
| `bin/deploy.sh` | Pull the newest image, migrate, restart |

The image is built from this fork by `.github/workflows/publish_image.yml` and pushed to
`ghcr.io/playyourcourt/chatwoot` on every push to `main` (tag `latest`) or a `v*` tag.

## Run locally

```bash
deploy/bin/local-setup.sh          # first time: creates .env.local, builds, prepares the DB
docker compose -f deploy/docker-compose.local.yml up -d
```

Open http://localhost:3000 and complete the onboarding to create the first admin. Outbound email
lands in Mailhog at http://localhost:8025. To test Twilio or Postmark webhooks against your laptop,
expose port 3000 with `cloudflared tunnel --url http://localhost:3000` and use that URL as the
webhook host.

Rebuild after code changes with `docker compose -f deploy/docker-compose.local.yml up -d --build`.

## Deploy to DigitalOcean

Provision once:

1. **Managed PostgreSQL 16**, 2 vCPU / 4 GB with storage raised to at least 60 GB (the Salesforce
   history adds ~10 GB of rows plus indexes; leave headroom for WAL and bloat). Create database
   `chatwoot`. Note the connection string; it must include `sslmode=require`. The Salesforce staging
   DB is *not* managed: it runs as a container on the Droplet only while importing (see `salesforce/`).
2. **Spaces bucket** (e.g. `pyc-chatwoot`, region `nyc3`) and a Spaces access key.
3. **Droplet** (Ubuntu 24.04, 4 vCPU / 8 GB, 160 GB disk; the disk matters during the import).
   Add the Droplet to the database's trusted sources. Enable weekly Droplet backups.
4. **DNS**: A record for `crm.playyourcourt.com` → Droplet IP.
5. **GHCR**: a GitHub personal access token with `read:packages` for the Droplet to pull the image.

Then on the Droplet:

```bash
git clone git@github.com:PlayYourCourt/chatwoot.git && cd chatwoot
cp deploy/.env.do.example deploy/.env.do   # fill in every value; SECRET_KEY_BASE: openssl rand -hex 64
GHCR_USER=<github-user> GHCR_TOKEN=<token> deploy/bin/droplet-setup.sh
```

Open `https://crm.playyourcourt.com` and complete onboarding.

### Releases (GitHub Actions)

`.github/workflows/publish_image.yml` is the whole pipeline:

- **Branches**: `develop` mirrors upstream `chatwoot/chatwoot` and is never deployed. `main` is
  production. To release, merge into `main` (`git checkout main && git merge develop` or a PR) and push.
- **On push to `main`**: build the image (enterprise stripped), push `ghcr.io/playyourcourt/chatwoot:<sha>`
  and `:latest`, then SSH into the Droplet, check out that commit and run `deploy/bin/deploy.sh <image:sha>`
  (pull, `db:migrate`, `up -d`). The exact build is pinned in `deploy/.env` on the Droplet.
- **Rollback**: Actions → the workflow → "Run workflow" from the previous good commit with *deploy* ticked,
  or on the Droplet `deploy/bin/deploy.sh ghcr.io/playyourcourt/chatwoot:<old sha>`.
- **Secrets** (repository → Settings → Secrets): `DROPLET_HOST`, `DROPLET_USER`, `DROPLET_SSH_KEY`
  (a deploy-only key whose public half is in the Droplet user's `authorized_keys`), `DROPLET_APP_DIR`
  (the checkout path, e.g. `/opt/chatwoot`). Create a `production` environment in the repo so deploys
  show up in the Deployments tab and can require a reviewer later.
- **Upstream updates**: `git fetch upstream && git checkout develop && git merge upstream/develop`,
  resolve, run the local stack, then merge `develop` into `main`.

Backups: DO Managed PostgreSQL keeps daily backups with point-in-time recovery; attachments are in
Spaces. Nothing on the Droplet needs backing up.

AWS instead of DO: same compose file. Point `DATABASE_URL` at RDS and `STORAGE_*` at S3
(or `ACTIVE_STORAGE_SERVICE=amazon` with `S3_BUCKET_NAME` / `AWS_*`).

## Email (Postmark, Google stays in front)

Root-domain MX stays on Google Workspace. Postmark handles inbound on a subdomain and all outbound.

1. In Postmark, add sender domain `playyourcourt.com` (DKIM + Return-Path DNS records). These
   coexist with Google's MX.
2. Create an inbound server. Point MX for `inbound.playyourcourt.com` at `inbound.postmarkapp.com`.
   Set the inbound webhook to
   `https://actionmailbox:<RAILS_INBOUND_EMAIL_PASSWORD>@crm.playyourcourt.com/rails/action_mailbox/postmark/inbound_emails`
   and tick **Include raw email content in JSON payload**.
3. Fill the `SMTP_*`, `RAILS_INBOUND_EMAIL_*` and `MAILER_INBOUND_EMAIL_DOMAIN` values in `.env.do`.
4. For each address (`sales@`, `support@` …): create an **Email** inbox in Chatwoot with that
   address. Chatwoot shows a *forward to* address on the inbound subdomain. In Google Workspace make
   the address a group (free) that forwards to it. Agent replies go out from the real address via
   Postmark; customer replies come straight to Postmark, no Google hop.
5. Optional: an automation rule per inbox (`conversation_created` → add label) if you want labels
   in addition to the inbox itself.

## SMS (Twilio, one inbox per number)

1. In Twilio, create one **Messaging Service** per purpose (e.g. `Nurture`, `Support`,
   `Reminders`) and attach its number(s). Complete A2P 10DLC registration on each.
2. For each service create a **Twilio SMS** inbox in Chatwoot using the Messaging Service SID.
3. Set each service's inbound webhook to `https://crm.playyourcourt.com/twilio/callback` and the
   status callback to `https://crm.playyourcourt.com/twilio/delivery_status`.

Chatwoot routes inbound SMS to the right inbox by Messaging Service SID (falling back to the
destination number), so all services share the same two URLs.

## Klaviyo nurture flows

Klaviyo owns the sequence (steps, delays, splits). Chatwoot sends and records the messages.

**Sending a step.** Add a *Webhook* action to the flow:

```
POST https://crm.playyourcourt.com/api/v1/accounts/<ACCOUNT_ID>/integrations/klaviyo/outreach
Headers: api_access_token: <Chatwoot access token of an agent or bot user>
         Content-Type: application/json
Body:
{
  "email": "{{ person.email }}",
  "phone_number": "{{ person.phone_number }}",
  "name": "{{ person.first_name }} {{ person.last_name }}",
  "inbox_id": <ID of the Twilio or Email inbox to send from>,
  "content": "Hi {{ person.first_name }}, ...",
  "custom_attributes": { "lead_source": "klaviyo" }
}
```

The endpoint finds or creates the contact (by email, then phone), reuses the contact's open
conversation on that inbox or opens one, and sends `content` as an outgoing message. Omit
`content` to only create the contact. Response: `{ contact_id, conversation_id, message_id }`.

**Stopping on a reply.** When a contact sends an incoming SMS or email, Chatwoot pushes a
`Chatwoot Reply` event to the Klaviyo profile (needs `KLAVIYO_PRIVATE_API_KEY` with `events:write`
in `.env.do`) and sets the contact attribute `flow_status=replied`. Add a **flow filter** (flow
level, not per message): *Chatwoot Reply zero times since starting this flow*.

**Stopping on a sale.** Have the platform or Stripe post a `Sale` event for the profile
(`POST https://a.klaviyo.com/api/events`, same shape as above with metric `Sale`) and add the
flow filter *Sale zero times since starting this flow*.

## Salesforce import

Export Leads/Contacts from Salesforce (Bulk API or Data Loader) to a CSV with headers
`salesforce_id, first_name, last_name, email, phone, company, sf_account_id, lead_status,
lead_source, owner`. Then:

```bash
docker compose -f deploy/docker-compose.do.yml cp contacts.csv rails:/tmp/contacts.csv
docker compose -f deploy/docker-compose.do.yml exec rails \
  bundle exec rails "salesforce:import_contacts[<ACCOUNT_ID>,/tmp/contacts.csv]"
```

The import is idempotent: rows match on Salesforce ID, then email, then phone. Custom attribute
definitions are created automatically. Cases import (as conversations in an API inbox) is a
follow-up once the case export format is known.
