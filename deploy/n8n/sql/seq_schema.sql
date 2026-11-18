-- SMS sequence engine state (deploy/n8n/DESIGN.md "Database schema"). Loaded into the `seq` database by
-- deploy/n8n/setup_db.sh as the admin user; the engine role gets no DELETE on the log tables. Idempotent.
-- All timestamps are timestamptz in UTC.
SET client_min_messages = warning;

CREATE TABLE IF NOT EXISTS seq_flows (
  key                   text PRIMARY KEY,
  name                  text NOT NULL,
  status                text NOT NULL DEFAULT 'paused' CHECK (status IN ('active', 'paused')),
  inbox_id              integer NOT NULL,
  reentry_policy        text NOT NULL DEFAULT 'after_completion'
                        CHECK (reentry_policy IN ('never', 'after_completion', 'after_exit', 'always')),
  reentry_cooldown_days integer NOT NULL DEFAULT 0,
  end_rules             jsonb NOT NULL DEFAULT '[]',
  send_window           jsonb NOT NULL DEFAULT '{}',
  spread_hours          integer NOT NULL DEFAULT 3,
  on_send_failure       text NOT NULL DEFAULT 'continue' CHECK (on_send_failure IN ('continue', 'exit', 'hold')),
  vars                  jsonb NOT NULL DEFAULT '{}',   -- message placeholders from the Flow config node (rep_first_name, rep_phone, checkout_url)
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE seq_flows ADD COLUMN IF NOT EXISTS vars jsonb NOT NULL DEFAULT '{}';

CREATE TABLE IF NOT EXISTS seq_enrollments (
  id            bigserial PRIMARY KEY,
  flow_key      text NOT NULL REFERENCES seq_flows (key),
  contact_id    bigint NOT NULL,
  phone         text NOT NULL,
  status        text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'completed', 'exited', 'held')),
  current_step  text NOT NULL DEFAULT '1',
  next_run_at   timestamptz NOT NULL DEFAULT now(),
  claimed_at    timestamptz,
  enrolled_at   timestamptz NOT NULL DEFAULT now(),
  ended_at      timestamptz,
  exit_reason   text,
  source        text,
  params        jsonb NOT NULL DEFAULT '{}',
  defer_count   integer NOT NULL DEFAULT 0,
  variant       text,
  held_at       timestamptz
);
ALTER TABLE seq_enrollments ADD COLUMN IF NOT EXISTS held_at timestamptz;
CREATE INDEX IF NOT EXISTS seq_enrollments_due ON seq_enrollments (status, next_run_at);
CREATE INDEX IF NOT EXISTS seq_enrollments_contact ON seq_enrollments (contact_id);
CREATE UNIQUE INDEX IF NOT EXISTS seq_enrollments_one_active
  ON seq_enrollments (flow_key, contact_id) WHERE status = 'active';

CREATE TABLE IF NOT EXISTS seq_step_logs (
  id            bigserial PRIMARY KEY,
  enrollment_id bigint NOT NULL REFERENCES seq_enrollments (id),
  step          text NOT NULL,
  outcome       text NOT NULL CHECK (outcome IN ('sent', 'deferred', 'exited', 'skipped', 'failed')),
  reason        text,
  inputs        jsonb NOT NULL DEFAULT '{}',
  ran_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS seq_step_logs_enrollment ON seq_step_logs (enrollment_id, ran_at);

CREATE TABLE IF NOT EXISTS seq_message_logs (
  id                  bigserial PRIMARY KEY,
  enrollment_id       bigint NOT NULL REFERENCES seq_enrollments (id),
  contact_id          bigint NOT NULL,
  inbox_id            integer NOT NULL,
  step                text NOT NULL,
  variant             text,
  body                text NOT NULL,
  idempotency_key     text NOT NULL UNIQUE,            -- enrollment_id:step:variant
  chatwoot_message_id bigint,
  twilio_sid          text,
  status              text NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending', 'sent', 'skipped', 'failed', 'unknown', 'resent')),
  error               text,
  timezone            text,
  timezone_source     text,
  local_time          text,
  consent_snapshot    jsonb NOT NULL DEFAULT '{}',
  sent_by             text,                            -- 'engine' or the name of the person who resent
  sent_at             timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS seq_message_logs_enrollment ON seq_message_logs (enrollment_id);
CREATE INDEX IF NOT EXISTS seq_message_logs_pending ON seq_message_logs (sent_at) WHERE chatwoot_message_id IS NULL;

CREATE TABLE IF NOT EXISTS seq_events (
  id          bigserial PRIMARY KEY,
  contact_id  bigint,
  phone       text,
  kind        text NOT NULL CHECK (kind IN ('purchase', 'opt_out', 'custom')),
  payload     jsonb NOT NULL DEFAULT '{}',
  occurred_at timestamptz NOT NULL DEFAULT now(),
  source      text
);
CREATE INDEX IF NOT EXISTS seq_events_contact ON seq_events (contact_id, kind, occurred_at);
CREATE INDEX IF NOT EXISTS seq_events_phone ON seq_events (phone, kind, occurred_at);

CREATE TABLE IF NOT EXISTS seq_api_keys (
  id           bigserial PRIMARY KEY,
  name         text NOT NULL UNIQUE,
  token_digest text NOT NULL UNIQUE,                   -- sha256 hex of the bearer token
  scopes       text[] NOT NULL DEFAULT '{enroll,exit,events}',
  last_used_at timestamptz,
  revoked_at   timestamptz,
  created_at   timestamptz NOT NULL DEFAULT now()
);

-- What the n8n engine credential may do. No DELETE anywhere: logs are the record.
GRANT USAGE ON SCHEMA public TO seq_engine;
GRANT SELECT, INSERT, UPDATE ON seq_flows, seq_enrollments, seq_step_logs, seq_message_logs, seq_events TO seq_engine;
GRANT SELECT, UPDATE ON seq_api_keys TO seq_engine;    -- UPDATE for last_used_at; keys are created by hand
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO seq_engine;
