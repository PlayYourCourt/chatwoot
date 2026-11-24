#!/usr/bin/env python3
"""Generates the n8n workflows of the SMS sequence engine into workflows/*.json (design: DESIGN.md).

Engine workflows (Gate, Send, APIs, watcher, error handler) are owned here: edit this file, run it, then
`push.py`. The flow workflows (`Flow: <key>`) are generated once as a skeleton and then owned by the n8n
editor (marketers edit their Step config nodes), so this script skips a flow file that already exists.

Node parameter shapes match n8n 2.45.x (n8n-nodes-base versions as listed per helper).
"""
import json
import os
import uuid

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'workflows')
BOT_USER_EMAIL = 'tech@playyourcourt.com'           # the Chatwoot user whose token sends; excluded from "agent messaged"
ALERT_EMAIL = 'keith@playyourcourt.com'
ALERT_FROM = 'support@playyourcourt.com'
CHATWOOT_URL = 'http://rails:3000'                   # as seen from the n8n container (same compose network)
CHATWOOT_ACCOUNT_ID = 1

CRED_SEQ = {'name': 'seq', 'type': 'postgres'}
CRED_RO = {'name': 'chatwoot readonly', 'type': 'postgres'}
CRED_CW = {'name': 'Chatwoot API token', 'type': 'httpHeaderAuth'}
CRED_SMTP = {'name': 'Alerts SMTP', 'type': 'smtp'}

X = 220  # grid step


def nid(name):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, 'seq:' + name))


def node(name, type_, version, params, pos, **extra):
    n = {'id': nid(name), 'name': name, 'type': type_, 'typeVersion': version, 'position': list(pos), 'parameters': params}
    n.update(extra)
    return n


def pg(name, cred, sql, pos, always=False, on_error_continue=False):
    """Postgres executeQuery, one query per input item (v2.8). on_error_continue: a failed query does not fail the
    run (for log writes that must never block the real work)."""
    n = node(name, 'n8n-nodes-base.postgres', 2.8,
             {'operation': 'executeQuery', 'query': sql, 'options': {'queryBatching': 'independently'}},
             pos, credentials={'postgres': dict(cred)})
    if always:
        n['alwaysOutputData'] = True
    if on_error_continue:
        n['onError'] = 'continueRegularOutput'
    return n


def code(name, js, pos):
    return node(name, 'n8n-nodes-base.code', 2, {'jsCode': js}, pos)


def set_node(name, fields, pos):
    """Set v3.5, keeps other fields. fields: {name: (type, value)}; marketers edit these."""
    assignments = [{'id': nid(name + ':' + k), 'name': k, 'type': t, 'value': v} for k, (t, v) in fields.items()]
    return node(name, 'n8n-nodes-base.set', 3.5, {'assignments': {'assignments': assignments}, 'includeOtherFields': True, 'options': {}}, pos)


def condition(left, operation, right=None, type_='string'):
    cond = {'id': nid(left + operation + str(right)), 'leftValue': left, 'operator': {'type': type_, 'operation': operation}}
    if right is None:
        cond['operator']['singleValue'] = True
        cond['rightValue'] = ''
    else:
        cond['rightValue'] = right
    return cond


def filter_(conds):
    return {'options': {'caseSensitive': True, 'leftValue': '', 'typeValidation': 'strict', 'version': 2}, 'conditions': conds, 'combinator': 'and'}


def if_node(name, conds, pos):
    return node(name, 'n8n-nodes-base.if', 2.4, {'conditions': filter_(conds), 'options': {}}, pos)


def switch(name, left, values, pos):
    """Switch v3.5 in rules mode: one renamed output per value, no fallback."""
    rules = [{'conditions': filter_([condition(left, 'equals', v)]), 'renameOutput': True, 'outputKey': v} for v in values]
    return node(name, 'n8n-nodes-base.switch', 3.5, {'rules': {'values': rules}, 'options': {}}, pos)


def exec_wf(name, target, pos):
    """Execute Workflow v1.4 calling a sub-workflow by name (push.py resolves the id)."""
    return node(name, 'n8n-nodes-base.executeWorkflow', 1.4,
                {'workflowId': {'__rl': True, 'mode': 'list', 'value': '', 'cachedResultName': target},
                 'workflowInputs': {'mappingMode': 'passThrough', 'value': None}, 'mode': 'once', 'options': {}}, pos)


def wf_trigger(name, pos):
    return node(name, 'n8n-nodes-base.executeWorkflowTrigger', 1.3, {'inputSource': 'passthrough'}, pos)


def webhook(name, path, pos, respond_node=True):
    params = {'httpMethod': 'POST', 'path': path, 'options': {}}
    params['responseMode'] = 'responseNode' if respond_node else 'onReceived'
    return node(name, 'n8n-nodes-base.webhook', 2.1, params, pos, webhookId=nid('webhook:' + path))


def respond(name, status, body_expr, pos):
    return node(name, 'n8n-nodes-base.respondToWebhook', 1.4,
                {'respondWith': 'json', 'responseBody': body_expr, 'options': {'responseCode': status}}, pos)


API = f'{CHATWOOT_URL}/api/v1/accounts/{CHATWOOT_ACCOUNT_ID}'


def http(name, method, url, pos, body_expr=None):
    """Chatwoot API call with the tech@ token; errors come out as items with an `error` field, never retried.
    X-Forwarded-Proto: the call goes over the compose network as plain HTTP, and production Rails (FORCE_SSL)
    would otherwise redirect it to https://rails:3000, a TLS handshake against a plaintext port."""
    params = {'method': method, 'url': url, 'authentication': 'genericCredentialType', 'genericAuthType': 'httpHeaderAuth',
              'sendHeaders': True, 'headerParameters': {'parameters': [{'name': 'X-Forwarded-Proto', 'value': 'https'}]},
              'options': {'timeout': 30000}}
    if body_expr:
        params.update({'sendBody': True, 'specifyBody': 'json', 'jsonBody': body_expr})
    return node(name, 'n8n-nodes-base.httpRequest', 4.2, params, pos, credentials={'httpHeaderAuth': dict(CRED_CW)},
                onError='continueRegularOutput', retryOnFail=False)


def http_outreach(name, body_expr, pos):
    return http(name, 'POST', f'{API}/integrations/klaviyo/outreach', pos, body_expr)


def merge(name, pos):
    return node(name, 'n8n-nodes-base.merge', 3.2, {'mode': 'append', 'numberInputs': 2}, pos)


def schedule(name, minutes, pos):
    return node(name, 'n8n-nodes-base.scheduleTrigger', 1.4, {'rule': {'interval': [{'field': 'minutes', 'minutesInterval': minutes}]}}, pos)


def sticky(text, pos, width=400, height=120, color=1):
    n = node('Note ' + nid(text)[:8], 'n8n-nodes-base.stickyNote', 1, {'content': text, 'width': width, 'height': height, 'color': color}, pos)
    return n


def workflow(name, nodes, edges, settings=None):
    """edges: (from, to) or (from, to, from_output) or (from, to, from_output, to_input)."""
    connections = {}
    for e in edges:
        src, dst = e[0], e[1]
        out_i = e[2] if len(e) > 2 else 0
        in_i = e[3] if len(e) > 3 else 0
        outs = connections.setdefault(src, {'main': []})['main']
        while len(outs) <= out_i:
            outs.append([])
        outs[out_i].append({'node': dst, 'type': 'main', 'index': in_i})
    s = {'executionOrder': 'v1', 'timezone': 'UTC', 'saveManualExecutions': True, 'executionTimeout': 600}
    s.update(settings or {})
    return {'name': name, 'nodes': nodes, 'connections': connections, 'settings': s}


# ----------------------------------------------------------------------------------------------- shared JS

JS_HELPERS = r"""
const q = v => v === null || v === undefined ? 'NULL' : "'" + String(v).replace(/'/g, "''") + "'";
const qj = v => q(JSON.stringify(v === undefined ? null : v)) + '::jsonb';
const e164 = v => {
  const d = String(v || '').replace(/\D/g, '');
  if (d.length === 10) return '+1' + d;
  if (d.length === 11 && d[0] === '1') return '+' + d;
  return null;
};
// The n8n run that writes a log row: Chatwoot's Reports → Sequences page links to it (workflow/<id>/executions/<id>).
const RUN_COLS = 'workflow_id, execution_id';
const RUN_VALS = `${q($workflow.id)}, ${q($execution.id)}`;
"""

# ----------------------------------------------------------------------------------------------- Gate

GATE_FACTS_SQL = f"""SELECT {{{{ $json.id }}}}::bigint AS enrollment_id,
  c.id AS contact_id, c.name, c.email, c.phone_number, c.custom_attributes,
  bot.id AS bot_user_id,
  EXISTS (SELECT 1 FROM messages m JOIN conversations cv ON cv.id = m.conversation_id
          WHERE cv.contact_id = c.id AND m.message_type = 0 AND m.created_at > '{{{{ $json.enrolled_at }}}}') AS replied,
  EXISTS (SELECT 1 FROM messages m JOIN conversations cv ON cv.id = m.conversation_id
          WHERE cv.contact_id = c.id AND m.message_type = 1 AND m.private = false AND m.sender_type = 'User'
            AND m.sender_id IS DISTINCT FROM bot.id AND m.created_at > '{{{{ $json.enrolled_at }}}}') AS agent_messaged,
  (SELECT coalesce(array_agg(DISTINCT t.name), '{{}}') FROM taggings tg JOIN tags t ON t.id = tg.tag_id
   WHERE tg.context = 'labels' AND ((tg.taggable_type = 'Contact' AND tg.taggable_id = c.id)
      OR (tg.taggable_type = 'Conversation' AND tg.taggable_id IN (SELECT id FROM conversations WHERE contact_id = c.id)))) AS labels,
  (SELECT coalesce(array_agg(DISTINCT cv.inbox_id), '{{}}') FROM conversations cv
   WHERE cv.contact_id = c.id AND cv.created_at < '{{{{ $json.enrolled_at }}}}'
     -- only conversations with a real message: a conversation holding just private notes or activity does not count
     AND EXISTS (SELECT 1 FROM messages m WHERE m.conversation_id = cv.id AND m.private = false AND m.message_type IN (0, 1, 3))) AS prior_conversation_inboxes,
  (SELECT jsonb_build_object('enabled', i.working_hours_enabled, 'timezone', i.timezone,
     'hours', (SELECT coalesce(jsonb_agg(jsonb_build_object('day', w.day_of_week, 'open_all_day', w.open_all_day,
                 'closed_all_day', w.closed_all_day, 'open', w.open_hour * 60 + w.open_minutes, 'close', w.close_hour * 60 + w.close_minutes)), '[]')
               FROM working_hours w WHERE w.inbox_id = i.id))
   FROM inboxes i WHERE i.id = {{{{ $json.flow.inbox_id }}}}) AS inbox,
  (SELECT cv.id FROM conversations cv WHERE cv.contact_id = c.id AND cv.inbox_id = {{{{ $json.flow.inbox_id }}}}
   ORDER BY cv.created_at DESC LIMIT 1) AS conversation_id
FROM (SELECT 1) x
-- The enrolled contact, or (after a merge removed it) the contact that now holds the enrolled number. No row = deleted.
LEFT JOIN contacts c ON c.id = coalesce(
  (SELECT id FROM contacts WHERE id = {{{{ $json.contact_id }}}}),
  (SELECT id FROM contacts WHERE account_id = {CHATWOOT_ACCOUNT_ID} AND phone_number = '{{{{ $json.phone }}}}' ORDER BY id LIMIT 1))
LEFT JOIN users bot ON bot.email = '{BOT_USER_EMAIL}'"""

GATE_EVENTS_SQL = """WITH moved AS (
  -- follow a merge: point the enrollment at the surviving contact (unless that contact has its own active enrollment in the flow)
  UPDATE seq_enrollments e SET contact_id = {{ $json.contact_id || 'NULL' }}
  WHERE e.id = {{ $json.enrollment_id }} AND e.contact_id <> {{ $json.contact_id || 'NULL' }}
    AND NOT EXISTS (SELECT 1 FROM seq_enrollments o WHERE o.contact_id = {{ $json.contact_id || 'NULL' }} AND o.flow_key = e.flow_key AND o.status = 'active')
  RETURNING 1)
SELECT {{ $json.enrollment_id }}::bigint AS enrollment_id,
  coalesce((SELECT jsonb_agg(jsonb_build_object('kind', kind, 'payload', payload, 'occurred_at', occurred_at) ORDER BY occurred_at)
            FROM seq_events WHERE (contact_id = {{ $json.contact_id || 'NULL' }} OR phone = '{{ $('Rows').item.json.phone }}')
              AND occurred_at > '{{ $('Rows').item.json.enrolled_at }}'), '[]') AS events,
  (SELECT coalesce(array_agg(DISTINCT flow_key), '{}') FROM seq_enrollments
   WHERE contact_id = {{ $json.contact_id || 'NULL' }} AND id <> {{ $json.enrollment_id }}) AS enrolled_flows,
  EXISTS (SELECT 1 FROM seq_enrollments WHERE contact_id = {{ $json.contact_id || 'NULL' }} AND status = 'active'
          AND id <> {{ $json.enrollment_id }}) AS other_active"""

GATE_DECIDE_JS = JS_HELPERS + r"""
// DateTime (Luxon) is a global in n8n Code nodes

// ---- settings
const LEGAL = { weekday: [9 * 60, 21 * 60], sunday: [12 * 60, 21 * 60] };   // minutes of day; tighten here, never widen per flow
const LEGAL_ALSO_IN = 'America/Chicago';
const DEFAULT_TZ = 'America/Chicago';
const MAX_DEFERRALS = 14;
const SEARCH_DAYS = 14;
const STEP_MIN = 15;
// Fallback lookups when the contact has no timezone attribute: US ZIP prefix, then area code (tz_data.json, see build_tz_data.py).
// A prefix can span several zones; the legal window must then be open in every one of them.
const TZ_DATA = __TZ_DATA__;
const expand = groups => { const m = {}; for (const [zones, prefixes] of Object.entries(groups)) for (const p of prefixes.split(' ')) m[p] = zones.split('|'); return m; };
const zipZones = expand(TZ_DATA.zip3);
const areaZones = expand(TZ_DATA.area);
const UNKNOWN_ZONES = ['America/New_York', 'America/Los_Angeles'];   // nothing known: legal on both coasts

// ---- inputs: facts (this node's input), events, and the claimed rows
const rows = Object.fromEntries($('Rows').all().map(i => [String(i.json.id), i.json]));
const events = Object.fromEntries($input.all().map(i => [String(i.json.enrollment_id), i.json.events || []]));
const enrolledFlows = Object.fromEntries($input.all().map(i => [String(i.json.enrollment_id), i.json.enrolled_flows || []]));
const otherActive = Object.fromEntries($input.all().map(i => [String(i.json.enrollment_id), !!i.json.other_active]));
const now = DateTime.utc();

// Order: the contact's timezone attribute, its postal code, the phone's area code, then the both-coasts default.
function resolveTimezone(attrs, phone) {
  const tz = attrs && attrs.timezone;
  if (tz && DateTime.now().setZone(tz).isValid) return { zone: tz, zones: [tz], source: attrs.timezone_source || 'contact' };
  const zip = String((attrs && attrs.postal_code) || '').trim().match(/^(\d{3})\d{2}/);
  if (zip && zipZones[zip[1]]) return { zone: zipZones[zip[1]][0], zones: zipZones[zip[1]], source: 'postal_code' };
  const code = String(phone || '').replace(/^\+1/, '').slice(0, 3);
  if (areaZones[code]) return { zone: areaZones[code][0], zones: areaZones[code], source: 'phone' };
  return { zone: DEFAULT_TZ, zones: UNKNOWN_ZONES, source: 'default' };
}

function minutesOf(dt) { return dt.hour * 60 + dt.minute; }
function withinRange(dt, open, close) { const m = minutesOf(dt); return m >= open && m < close; }
function legalOpen(dt) {
  const range = dt.weekday === 7 ? LEGAL.sunday : LEGAL.weekday;
  return withinRange(dt, range[0], range[1]);
}
function inboxOpen(inbox, utc) {
  if (!inbox || !inbox.enabled) return true;
  const local = utc.setZone(inbox.timezone || 'UTC');
  const day = (inbox.hours || []).find(h => h.day === local.weekday % 7);   // Chatwoot: 0 = Sunday
  if (!day) return false;
  if (day.closed_all_day) return false;
  if (day.open_all_day) return true;
  return withinRange(local, day.open, day.close);
}
function flowWindowOpen(win, local) {
  if (!win || !win.open || !win.close) return true;
  const [oh, om] = win.open.split(':').map(Number);
  const [ch, cm] = win.close.split(':').map(Number);
  return withinRange(local, oh * 60 + om, ch * 60 + cm);
}
function allowed(utc, tz, sw, inbox) {
  const local = utc.setZone(tz.zone);
  if ((sw.holidays || []).includes(local.toISODate())) return false;
  if (!tz.zones.every(z => legalOpen(utc.setZone(z))) || !legalOpen(utc.setZone(LEGAL_ALSO_IN))) return false;
  if (sw.business_hours && !inboxOpen(inbox, utc)) return false;
  return flowWindowOpen(sw.flow_window, local);
}
function nextOpenTime(utc, tz, sw, inbox) {
  let t = utc.plus({ minutes: STEP_MIN - (utc.minute % STEP_MIN) }).set({ second: 0, millisecond: 0 });
  const end = utc.plus({ days: SEARCH_DAYS });
  while (t < end) { if (allowed(t, tz, sw, inbox)) return t; t = t.plus({ minutes: STEP_MIN }); }
  return null;
}
function spreadMinutes(contactId, spreadHours) {
  let h = 2166136261;
  for (const ch of String(contactId)) { h ^= ch.charCodeAt(0); h = Math.imul(h, 16777619); }
  return (h >>> 0) % (Math.max(0, spreadHours || 0) * 60 || 1);
}
const isTrue = v => v === true || v === 'true';

function evaluateEndRules(rules, f) {
  const purchases = f.events.filter(e => e.kind === 'purchase');
  for (const r of rules || []) {
    switch (r.rule) {
      case 'replied': if (f.replied) return 'replied'; break;
      case 'agent_messaged': if (f.agent_messaged) return 'agent_messaged'; break;
      case 'purchased': if (purchases.length) return 'purchased'; break;
      case 'purchased_item': {
        const wanted = (r.skus || []).map(String);
        const skus = purchases.flatMap(e => [e.payload && e.payload.sku, ...((e.payload && e.payload.items) || []).map(i => i.sku)]).filter(Boolean).map(String);
        if (skus.some(s => wanted.includes(s))) return 'purchased_item';
        break;
      }
      case 'label': if (f.labels.includes(r.label)) return 'label:' + r.label; break;
      case 'no_label': if (!f.labels.includes(r.label)) return 'no_label:' + r.label; break;
      case 'no_enrollment_in': {
        const hit = (r.flows || []).find(k => f.enrolled_flows.includes(k));
        if (hit) return 'prior_flow:' + hit;
        break;
      }
      case 'no_prior_conversation':
        if ((r.inbox_ids || []).some(id => f.prior_conversation_inboxes.includes(Number(id)))) return 'prior_conversation';
        break;
      case 'field': {
        const v = r.field in f.contact ? f.contact[r.field] : (f.attrs || {})[r.field];
        const set = v !== null && v !== undefined && v !== '';
        const hit = r.op === 'set' ? set : r.op === 'empty' ? !set : r.op === 'is_not' ? String(v) !== String(r.value) : String(v) === String(r.value);
        if (hit) return 'field:' + r.field;
        break;
      }
    }
  }
  return null;
}

const out = [];
for (const item of $('Chatwoot facts').all()) {
  const facts = item.json;
  const row = rows[String(facts.enrollment_id)];
  const flow = row.flow || {};
  const sw = flow.send_window || {};
  const attrs = facts.custom_attributes || {};
  const f = {
    contact: { id: facts.contact_id, name: facts.name, email: facts.email, phone_number: facts.phone_number },
    attrs, replied: !!facts.replied, agent_messaged: !!facts.agent_messaged, labels: facts.labels || [],
    prior_conversation_inboxes: (facts.prior_conversation_inboxes || []).map(Number),
    events: events[String(row.id)] || [], enrolled_flows: enrolledFlows[String(row.id)] || [],
  };
  const tz = resolveTimezone(attrs, row.phone);
  const { zone, source } = tz;
  let decision = 'send', reason = null, nextRun = null;
  if (!facts.contact_id) { decision = 'exit'; reason = 'contact_deleted'; }
  // merged into a contact that is already in a sequence: that enrollment carries on, this one ends
  else if (String(facts.contact_id) !== String(row.contact_id) && otherActive[String(row.id)]) { decision = 'exit'; reason = 'merged_duplicate'; }
  else if (attrs.sms_opted_out_at || f.events.some(e => e.kind === 'opt_out')) { decision = 'exit'; reason = 'opted_out'; }
  else if (isTrue(attrs.exclude_from_drip)) { decision = 'exit'; reason = 'excluded_from_drip'; }
  else if (f.labels.includes('stop-sequence')) { decision = 'exit'; reason = 'stop_label'; }
  // texts only ever go to the number that was enrolled
  else if (facts.phone_number !== row.phone) { decision = 'exit'; reason = 'phone_changed'; }
  else {
    const rule = evaluateEndRules(flow.end_rules, f);
    if (rule) { decision = 'exit'; reason = rule; }
    else if (!allowed(now, tz, sw, facts.inbox)) {
      const open = nextOpenTime(now, tz, sw, facts.inbox);
      if (!open || (row.defer_count || 0) >= MAX_DEFERRALS) { decision = 'exit'; reason = 'no_send_window'; }
      else {
        const spread = open.plus({ minutes: spreadMinutes(facts.contact_id, flow.spread_hours) });
        nextRun = allowed(spread, tz, sw, facts.inbox) ? spread : open;
        decision = 'defer'; reason = 'window_closed';
      }
    }
  }
  const inputs = { zone, source, local_time: now.setZone(zone).toISO(), replied: f.replied, agent_messaged: f.agent_messaged,
                   labels: f.labels, events: f.events.length, opted_out_at: attrs.sms_opted_out_at || null, next_run_at: nextRun && nextRun.toISO() };
  let writeback_sql = null;
  if (decision === 'defer') {
    writeback_sql = `WITH e AS (UPDATE seq_enrollments SET next_run_at = ${q(nextRun.toISO())}, claimed_at = NULL, defer_count = defer_count + 1 WHERE id = ${row.id} RETURNING id, current_step)
      INSERT INTO seq_step_logs (enrollment_id, step, outcome, reason, inputs, ${RUN_COLS}) SELECT id, current_step, 'deferred', ${q(reason)}, ${qj(inputs)}, ${RUN_VALS} FROM e`;
  } else if (decision === 'exit') {
    writeback_sql = `WITH e AS (UPDATE seq_enrollments SET status = 'exited', ended_at = now(), exit_reason = ${q(reason)}, claimed_at = NULL WHERE id = ${row.id} AND status = 'active' RETURNING id, current_step)
      INSERT INTO seq_step_logs (enrollment_id, step, outcome, reason, inputs, ${RUN_COLS}) SELECT id, current_step, 'exited', ${q(reason)}, ${qj(inputs)}, ${RUN_VALS} FROM e`;
  }
  const name = facts.name || '';
  let exit_note = null;
  if (decision === 'exit') {
    const skus = f.events.filter(e => e.kind === 'purchase').flatMap(e => [e.payload && e.payload.sku, ...((e.payload && e.payload.items) || []).map(i => i.sku)]).filter(Boolean);
    const detail = reason.startsWith('purchased') && skus.length ? ` (${[...new Set(skus)].join(', ')})` : '';
    exit_note = `Left the "${flow.name || row.flow_key}" SMS sequence at step ${row.current_step}: ${reason}${detail}.`;
  }
  out.push({ json: { ...row, enrollment_id: row.id, decision, reason, next_run_at: nextRun && nextRun.toISO(), writeback_sql,
    conversation_id: facts.conversation_id || null, exit_note,
    timezone: zone, timezone_source: source, local_time: inputs.local_time,
    contact: { ...f.contact, first_name: name.split(' ')[0] || '', last_name: name.split(' ').slice(1).join(' '), attrs },
    bot_user_id: facts.bot_user_id, gate_inputs: inputs } });
}
return out;
"""


GATE_DECIDE_JS = GATE_DECIDE_JS.replace('__TZ_DATA__', json.dumps(json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'tz_data.json'))), separators=(',', ':')))


def gate_workflow():
    nodes = [
        wf_trigger('Rows', (0, 0)),
        pg('Chatwoot facts', CRED_RO, GATE_FACTS_SQL, (X, 0), always=True),
        pg('Seq events', CRED_SEQ, GATE_EVENTS_SQL, (2 * X, 0), always=True),
        code('Decide', GATE_DECIDE_JS, (3 * X, 0)),
        sticky('## Seq: Gate\nCalled with claimed enrollment rows (each with its `flow`). Reads Chatwoot read-only and seq_events, '
               'then decides per row: `send`, `defer` (next_run_at) or `exit` (reason). Non-send rows carry `writeback_sql`.\n'
               'Order: suppression → stop label → end rules → legal window → business hours → flow window / holidays.', (0, -220), 900, 150),
    ]
    edges = [('Rows', 'Chatwoot facts'), ('Chatwoot facts', 'Seq events'), ('Seq events', 'Decide')]
    return workflow('Seq: Gate', nodes, edges)


# ----------------------------------------------------------------------------------------------- Send

SEND_RENDER_JS = JS_HELPERS + r"""
const UNITS = ['minutes', 'hours', 'days', 'weeks'];
const out = [];
for (const item of $input.all()) {
  const r = item.json;
  const c = r.contact || {};
  // Precedence: enrollment params (from the webhook) > Flow config vars > contact attributes > contact basics.
  const fields = { name: c.name, first_name: c.first_name, last_name: c.last_name, email: c.email, phone: c.phone_number, ...(c.attrs || {}),
                   ...((r.flow && r.flow.vars) || {}), ...(r.params || {}) };
  let error = null;
  const body = String(r.message || '').replace(/\{\{\s*([\w.]+)\s*\}\}/g, (_, key) => {
    const v = fields[key];
    if (v === undefined || v === null || v === '') { error = error || 'missing_placeholder:' + key; return ''; }
    return String(v);
  });
  if (!r.message) error = 'empty_message';
  if (!UNITS.includes(r.delay_unit) && r.next_step !== 'done') error = error || 'bad_delay_unit:' + r.delay_unit;
  const variant = r.variant || 'A';
  const key = `${r.enrollment_id}:${r.current_step}:${variant}`;
  const status = error ? 'skipped' : 'pending';
  const log_sql = `INSERT INTO seq_message_logs (enrollment_id, contact_id, inbox_id, step, variant, body, idempotency_key, status, error, timezone, timezone_source, local_time, consent_snapshot, sent_by, ${RUN_COLS})
    VALUES (${r.enrollment_id}, ${c.id}, ${r.flow.inbox_id}, ${q(r.current_step)}, ${q(variant)}, ${q(body)}, ${q(key)}, ${q(status)}, ${q(error)}, ${q(r.timezone)}, ${q(r.timezone_source)}, ${q(r.local_time)}, ${qj({ opted_out_at: (c.attrs || {}).sms_opted_out_at || null })}, 'engine', ${RUN_VALS})
    ON CONFLICT (idempotency_key) DO NOTHING RETURNING id`;
  out.push({ json: { ...r, body, variant, idempotency_key: key, render_error: error, log_sql } });
}
return out;
"""

SEND_PREPARE_JS = r"""
// Pair the insert results with the rendered rows (one result item per row, {} when the key already existed).
const rendered = $('Render').all();
const out = [];
$input.all().forEach((item, i) => {
  const r = rendered[i].json;
  const log_id = item.json.id || null;
  let action = 'send';
  if (!log_id) action = 'already_sent';
  else if (r.render_error) action = 'fail';
  out.push({ json: { ...r, log_id, action } });
});
return out;
"""

SEND_OUTCOME_JS = JS_HELPERS + r"""
// Items arrive from both branches of "Send it?": HTTP results (true) and untouched rows (false).
let httpItems = [];
try { httpItems = $('Chatwoot outreach').all(); } catch (e) { httpItems = []; }
let sentRows = [];
try { sentRows = $('Send it?').all(0); } catch (e) { sentRows = []; }
let otherRows = [];
try { otherRows = $('Send it?').all(1); } catch (e) { otherRows = []; }

function classify(res) {
  if (!res.error) return { status: 'sent', message_id: res.message_id || null, error: null };
  const err = res.error;
  const text = typeof err === 'string' ? err : JSON.stringify(err);
  const code = typeof err === 'object' && (err.httpCode || err.status || err.statusCode);
  const m = text.match(/\b(4\d\d|5\d\d)\b/);
  if (code || m) return { status: 'failed', message_id: null, error: text.slice(0, 500) };
  return { status: 'unknown', message_id: null, error: text.slice(0, 500) };   // timeout, connection reset: outcome not known
}

const out = [];
const finish = (r, status, message_id, error) => {
  const failurePolicy = (r.flow && r.flow.on_send_failure) || 'continue';
  let send_result, enrollment_sql;
  const advance = r.next_step === 'done'
    ? `UPDATE seq_enrollments SET status = 'completed', ended_at = now(), current_step = 'done', claimed_at = NULL, defer_count = 0 WHERE id = ${r.enrollment_id} AND status = 'active'`
    : `UPDATE seq_enrollments SET current_step = ${q(r.next_step)}, next_run_at = now() + interval '${Number(r.delay_to_next) || 0} ${r.delay_unit}', claimed_at = NULL, defer_count = 0 WHERE id = ${r.enrollment_id} AND status = 'active'`;
  const hold = `UPDATE seq_enrollments SET status = 'held', held_at = now(), claimed_at = NULL WHERE id = ${r.enrollment_id} AND status = 'active'`;
  const exit = `UPDATE seq_enrollments SET status = 'exited', ended_at = now(), exit_reason = 'send_failed', claimed_at = NULL WHERE id = ${r.enrollment_id} AND status = 'active'`;
  if (status === 'unknown') { send_result = 'held'; enrollment_sql = hold; }
  else if (status === 'failed' || status === 'skipped') {
    send_result = failurePolicy === 'hold' ? 'held' : failurePolicy === 'exit' ? 'exited' : 'advanced';
    enrollment_sql = failurePolicy === 'hold' ? hold : failurePolicy === 'exit' ? exit : advance;
  } else { send_result = 'advanced'; enrollment_sql = advance; }
  const stepOutcome = status === 'sent' ? 'sent' : status === 'already_sent' ? 'skipped' : 'failed';
  const logUpdate = r.log_id
    ? `UPDATE seq_message_logs SET status = ${q(status === 'already_sent' ? 'skipped' : status)}, chatwoot_message_id = ${message_id || 'NULL'}, error = ${q(error)} WHERE id = ${r.log_id}`
    : `SELECT 1`;
  const update_sql = `WITH l AS (${logUpdate}), e AS (${enrollment_sql})
    INSERT INTO seq_step_logs (enrollment_id, step, outcome, reason, inputs, ${RUN_COLS}) VALUES (${r.enrollment_id}, ${q(r.current_step)}, ${q(stepOutcome)}, ${q(error || (status === 'already_sent' ? 'already_sent' : null))}, ${qj({ status, send_result, message_id, next_step: r.next_step })}, ${RUN_VALS})`;
  out.push({ json: { enrollment_id: r.enrollment_id, step: r.current_step, status, send_result, message_id, error, update_sql } });
};
sentRows.forEach((row, i) => { const res = (httpItems[i] || {}).json || { error: 'no response item' }; const c = classify(res); finish(row.json, c.status, c.message_id, c.error); });
otherRows.forEach(row => { const r = row.json; finish(r, r.action === 'already_sent' ? 'already_sent' : 'skipped', null, r.render_error); });
return out;
"""

SEND_BODY = """={{ JSON.stringify({ phone_number: $json.phone, email: $json.contact.email || undefined, name: $json.contact.name || undefined,
  inbox_id: $json.flow.inbox_id, content: $json.body }) }}"""


def send_workflow():
    nodes = [
        wf_trigger('Steps', (0, 0)),
        code('Render', SEND_RENDER_JS, (X, 0)),
        pg('Log message', CRED_SEQ, '={{ $json.log_sql }}', (2 * X, 0), always=True),
        code('Prepare send', SEND_PREPARE_JS, (3 * X, 0)),
        if_node('Send it?', [condition('={{ $json.action }}', 'equals', 'send')], (4 * X, 0)),
        http_outreach('Chatwoot outreach', SEND_BODY, (5 * X, -100)),
        merge('Both branches', (6 * X, 0)),
        code('Outcome', SEND_OUTCOME_JS, (7 * X, 0)),
        pg('Update log', CRED_SEQ, '={{ $json.update_sql }}', (8 * X, 0), always=True),
        code('Return', "return $('Outcome').all().map(i => { const { update_sql, ...rest } = i.json; return { json: rest }; });", (9 * X, 0)),
        sticky('## Seq: Send\nOne item per step to send (row + step config). Writes the message log row first (unique key = '
               'enrollment:step:variant, so a rerun never sends twice), posts through Chatwoot\'s outreach endpoint once (no retry), '
               'then records the outcome and applies the next step / hold / exit to the enrollment itself. Returns `send_result` per row.',
               (0, -220), 1100, 150),
    ]
    edges = [('Steps', 'Render'), ('Render', 'Log message'), ('Log message', 'Prepare send'), ('Prepare send', 'Send it?'),
             ('Send it?', 'Chatwoot outreach', 0), ('Chatwoot outreach', 'Both branches', 0, 0), ('Send it?', 'Both branches', 1, 1),
             ('Both branches', 'Outcome'), ('Outcome', 'Update log'), ('Update log', 'Return')]
    return workflow('Seq: Send', nodes, edges)


# ----------------------------------------------------------------------------------------------- Flow

REGISTER_SQL = """INSERT INTO seq_flows (key, name, status, inbox_id, reentry_policy, reentry_cooldown_days, end_rules, send_window, spread_hours, on_send_failure, vars, updated_at)
SELECT c.key, c.name, c.status, c.inbox_id, c.reentry_policy, c.reentry_cooldown_days, c.end_rules,
       jsonb_strip_nulls(jsonb_build_object('business_hours', c.business_hours, 'holidays', c.holidays,
         'flow_window', CASE WHEN c.flow_window_open <> '' AND c.flow_window_close <> ''
                             THEN jsonb_build_object('open', c.flow_window_open, 'close', c.flow_window_close) END)),
       c.spread_hours, c.on_send_failure,
       jsonb_strip_nulls(jsonb_build_object('rep_first_name', nullif(c.rep_first_name, ''), 'rep_phone', nullif(c.rep_phone, ''),
                                            'checkout_url', nullif(c.checkout_url, ''))),
       now()
FROM jsonb_to_record('{{ JSON.stringify($json).replace(/'/g, "''") }}'::jsonb)
     AS c(key text, name text, status text, inbox_id integer, reentry_policy text, reentry_cooldown_days integer, end_rules jsonb,
          business_hours boolean, holidays jsonb, flow_window_open text, flow_window_close text, spread_hours integer, on_send_failure text,
          rep_first_name text, rep_phone text, checkout_url text)
ON CONFLICT (key) DO UPDATE SET name = EXCLUDED.name, status = EXCLUDED.status, inbox_id = EXCLUDED.inbox_id,
  reentry_policy = EXCLUDED.reentry_policy, reentry_cooldown_days = EXCLUDED.reentry_cooldown_days, end_rules = EXCLUDED.end_rules,
  send_window = EXCLUDED.send_window, spread_hours = EXCLUDED.spread_hours, on_send_failure = EXCLUDED.on_send_failure,
  vars = EXCLUDED.vars, updated_at = now()
RETURNING key, status, inbox_id"""

CLAIM_SQL = """WITH claimed AS (
  UPDATE seq_enrollments e SET claimed_at = now()
  WHERE e.id IN (SELECT id FROM seq_enrollments
                 WHERE flow_key = '{{ $json.key }}' AND '{{ $json.status }}' = 'active' AND status = 'active' AND next_run_at <= now() AND claimed_at IS NULL
                 ORDER BY next_run_at LIMIT 200 FOR UPDATE SKIP LOCKED)
  RETURNING e.*)
SELECT claimed.*, row_to_json(f)::jsonb AS flow FROM claimed JOIN seq_flows f ON f.key = claimed.flow_key WHERE f.status = 'active'"""


def flow_workflow(flow_key, config, steps):
    """config: flow settings for the Flow config node (see FLOWS). steps: list of (step, message, delay_to_next,
    delay_unit, note). The last step's next_step is 'done'."""
    y = 0
    nodes = [
        schedule('Every minute', 1, (0, 0)),
        set_node('Flow config', {
            'key': ('string', flow_key),
            'name': ('string', config['name']),
            'status': ('string', 'paused'),   # ships paused: set inbox_id (and the end rules' inbox ids), then 'active' and publish
            'inbox_id': ('number', config['inbox_id']),
            'reentry_policy': ('string', config.get('reentry_policy', 'never')),
            'reentry_cooldown_days': ('number', config.get('reentry_cooldown_days', 0)),
            'end_rules': ('array', json.dumps(config.get('end_rules', []))),
            'business_hours': ('boolean', config.get('business_hours', True)),
            'holidays': ('array', json.dumps(config.get('holidays', []))),
            'flow_window_open': ('string', ''),
            'flow_window_close': ('string', ''),
            'spread_hours': ('number', 3),
            'on_send_failure': ('string', 'continue'),
            # Message placeholders ({{rep_first_name}}, {{rep_phone}}, {{checkout_url}}); the enroll webhook can override them per contact.
            'rep_first_name': ('string', config.get('rep_first_name', 'Adam')),
            'rep_phone': ('string', config.get('rep_phone', '+13013752751')),
            'checkout_url': ('string', config.get('checkout_url', '')),
        }, (X, 0)),
        pg('Register flow', CRED_SEQ, REGISTER_SQL, (2 * X, 0)),
        pg('Claim due rows', CRED_SEQ, CLAIM_SQL, (3 * X, 0)),
        exec_wf('Gate', 'Seq: Gate', (4 * X, 0)),
        if_node('Send?', [condition('={{ $json.decision }}', 'equals', 'send')], (5 * X, 0)),
        pg('Defer or exit', CRED_SEQ, '={{ $json.writeback_sql }}', (6 * X, 160), always=True),
        if_node('Exited?', [condition("={{ $('Gate').item.json.decision }}", 'equals', 'exit'),
                            condition("={{ $('Gate').item.json.conversation_id }}", 'exists', type_='number')], (7 * X, 160)),
        http('Exit note', 'POST', f"={API}/conversations/{{{{ $('Gate').item.json.conversation_id }}}}/messages", (8 * X, 160),
             "={{ JSON.stringify({ content: $('Gate').item.json.exit_note, private: true, message_type: 'outgoing' }) }}"),
        switch('Step', '={{ $json.current_step }}', [s[0] for s in steps], (6 * X, -40)),
        sticky(f'## Flow: {flow_key}\nEvery minute: save **Flow config** to the database → claim up to 200 due rows → Gate → one lane per step '
               '(top to bottom, in order); Send advances the row; an exit leaves a private note on the conversation. Marketers edit only the yellow nodes and publish. '
               '**Flow config**: `inbox_id` is the Chatwoot inbox (channel) the texts go out on; `status` is `paused` until you set it to `active` (paused: no enrollments, no sends); '
               '`reentry_policy` never / after_completion / after_exit / always; `holidays` are dates like "2026-12-25"; '
               '`flow_window_open`/`close` ("10:00"/"18:00", contact-local) are optional; `rep_first_name`, `rep_phone` and `checkout_url` '
               'fill the matching placeholders (the enroll webhook can send a per-contact `checkout_url`). **Step config**: message, delay_to_next, '
               'delay_unit. `{{first_name}}`, `{{name}}`, `{{rep_first_name}}`, `{{rep_phone}}`, `{{checkout_url}}` and any contact attribute key '
               'are placeholders. Never connect one lane to another.',
               (0, -300), 1400, 210),
    ]
    nodes[1]['color'] = 3
    edges = [('Every minute', 'Flow config'), ('Flow config', 'Register flow'), ('Register flow', 'Claim due rows'),
             ('Claim due rows', 'Gate'), ('Gate', 'Send?'), ('Send?', 'Step', 0), ('Send?', 'Defer or exit', 1),
             ('Defer or exit', 'Exited?'), ('Exited?', 'Exit note', 0)]
    for i, (step, message, delay, unit, note) in enumerate(steps):
        y = 200 * i
        last = i == len(steps) - 1
        cfg = f'Step {step} config'
        nodes.append(set_node(cfg, {
            'message': ('string', message),
            'delay_to_next': ('number', 0 if last else delay),
            'delay_unit': ('string', 'days' if last else unit),
            'next_step': ('string', 'done' if last else steps[i + 1][0]),
        }, (7 * X, y)))
        nodes[-1]['color'] = 3
        send = f'Send step {step}'
        nodes.append(exec_wf(send, 'Seq: Send', (8 * X, y)))
        nodes.append(sticky(f'**Step {step}** · {note}' + ('' if last else f'\nthen wait {delay} {unit}'), (7 * X - 40, y + 90), 420, 70, 5))
        edges += [('Step', cfg, i), (cfg, send)]
    return workflow(f'Flow: {flow_key}', nodes, edges)


# ----------------------------------------------------------------------------------------------- Enroll (sub-workflow) and APIs

ENROLL_NORMALIZE_JS = JS_HELPERS + r"""
const out = [];
for (const item of $input.all()) {
  const b = item.json;
  const phone = e164(b.phone_number || b.phone);
  const flow = String(b.flow || b.flow_key || '').trim();
  const name = [b.first_name, b.last_name].filter(Boolean).join(' ') || b.name || undefined;
  let outcome = null;
  if (!phone) outcome = 'invalid_phone';
  else if (!/^[a-z0-9_-]+$/.test(flow)) outcome = 'invalid_flow';
  // params become message placeholders for this enrollment; checkout_url may also be sent at the top level.
  const params = { ...(b.params || {}), ...(b.checkout_url ? { checkout_url: String(b.checkout_url) } : {}) };
  out.push({ json: { flow, phone, email: b.email || undefined, name, source: b.source || 'api', params, outcome } });
}
return out;
"""

ENROLL_SQL_JS = JS_HELPERS + r"""
const req = $('Normalize').all();
const out = [];
$input.all().forEach((item, i) => {
  const r = req[i].json;
  const contact_id = item.json.contact_id;
  const optedOut = item.json.opted_out_at;
  const excluded = item.json.exclude_from_drip === 'true';
  let sql;
  if (!contact_id) sql = `SELECT 'contact_failed' AS outcome, NULL::bigint AS id`;
  else if (optedOut) sql = `SELECT 'skipped_no_consent' AS outcome, NULL::bigint AS id`;
  else if (excluded) sql = `SELECT 'skipped_excluded' AS outcome, NULL::bigint AS id`;
  else sql = `WITH f AS (SELECT * FROM seq_flows WHERE key = ${q(r.flow)} AND status = 'active'),
    last AS (SELECT * FROM seq_enrollments WHERE flow_key = ${q(r.flow)} AND contact_id = ${contact_id} ORDER BY enrolled_at DESC LIMIT 1),
    other AS (SELECT flow_key FROM seq_enrollments WHERE contact_id = ${contact_id} AND status = 'active' AND flow_key <> ${q(r.flow)} LIMIT 1),
    blocked AS (SELECT e.flow_key FROM seq_enrollments e
                WHERE e.contact_id = ${contact_id} AND e.flow_key IN (
                  SELECT jsonb_array_elements_text(rule->'flows') FROM f, jsonb_array_elements(f.end_rules) rule WHERE rule->>'rule' = 'no_enrollment_in')
                LIMIT 1),
    verdict AS (SELECT CASE
        WHEN f.key IS NULL THEN 'unknown_flow'
        WHEN last.status = 'active' THEN 'skipped_active'
        WHEN other.flow_key IS NOT NULL THEN 'skipped_in_other_flow'
        WHEN blocked.flow_key IS NOT NULL THEN 'skipped_prior_flow'
        WHEN last.id IS NULL THEN 'enrolled'
        WHEN f.reentry_policy = 'never' THEN 'skipped_reentry'
        WHEN last.ended_at > now() - (f.reentry_cooldown_days || ' days')::interval THEN 'skipped_reentry'
        WHEN f.reentry_policy = 'after_completion' AND last.status <> 'completed' THEN 'skipped_reentry'
        WHEN f.reentry_policy = 'after_exit' AND last.status NOT IN ('completed', 'exited') THEN 'skipped_reentry'
        ELSE 'enrolled' END AS outcome
      FROM (SELECT 1) x LEFT JOIN f ON true LEFT JOIN last ON true LEFT JOIN other ON true LEFT JOIN blocked ON true),
    ins AS (INSERT INTO seq_enrollments (flow_key, contact_id, phone, source, params)
            SELECT ${q(r.flow)}, ${contact_id}, ${q(r.phone)}, ${q(r.source)}, ${qj(r.params)} FROM verdict WHERE outcome = 'enrolled' RETURNING id)
    SELECT verdict.outcome, ins.id FROM verdict LEFT JOIN ins ON true`;
  out.push({ json: { ...r, contact_id, enroll_sql: sql } });
});
return out;
"""

ENROLL_RESULT_JS = r"""
const req = $('Enroll SQL').all();
return $input.all().map((item, i) => ({ json: { outcome: item.json.outcome || req[i].json.outcome, enrollment_id: item.json.id || null,
  contact_id: req[i].json.contact_id || null, flow: req[i].json.flow, phone: req[i].json.phone,
  email: req[i].json.email || null, source: req[i].json.source || null } }));
"""

# Every attempt is recorded, refused ones included (they leave no enrollment row), with the n8n run that handled it.
ENROLL_ATTEMPT_JS = JS_HELPERS + r"""
return $input.all().map(item => {
  const r = item.json;
  return { json: { ...r, attempt_sql: `INSERT INTO seq_enroll_attempts (flow_key, phone, email, contact_id, source, outcome, enrollment_id, ${RUN_COLS})
    VALUES (${q(r.flow)}, ${q(r.phone)}, ${q(r.email)}, ${r.contact_id || 'NULL'}, ${q(r.source)}, ${q(r.outcome)}, ${r.enrollment_id || 'NULL'}, ${RUN_VALS})` } };
});
"""

ENROLL_RETURN_JS = r"""
return $('Attempt SQL').all().map(i => { const { attempt_sql, email, source, ...rest } = i.json; return { json: rest }; });
"""


def enroll_contact_workflow():
    upsert_body = "={{ JSON.stringify({ phone_number: $json.phone, email: $json.email, name: $json.name }) }}"
    nodes = [
        wf_trigger('Request', (0, 0)),
        code('Normalize', ENROLL_NORMALIZE_JS, (X, 0)),
        if_node('Valid?', [condition('={{ $json.outcome }}', 'empty')], (2 * X, 0)),
        http_outreach('Upsert contact', upsert_body, (3 * X, -100)),
        pg('Consent', CRED_RO, "SELECT {{ $json.contact_id || 'NULL' }}::bigint AS contact_id, c.custom_attributes->>'sms_opted_out_at' AS opted_out_at, c.custom_attributes->>'exclude_from_drip' AS exclude_from_drip FROM (SELECT 1) x LEFT JOIN contacts c ON c.id = {{ $json.contact_id || 'NULL' }}", (4 * X, -100), always=True),
        code('Enroll SQL', ENROLL_SQL_JS, (5 * X, -100)),
        pg('Insert enrollment', CRED_SEQ, '={{ $json.enroll_sql }}', (6 * X, -100), always=True),
        code('Result', ENROLL_RESULT_JS, (7 * X, -100)),
        code('Invalid', "return $input.all().map(i => ({ json: { outcome: i.json.outcome, enrollment_id: null, contact_id: null, flow: i.json.flow, phone: i.json.phone, email: i.json.email || null, source: i.json.source || null } }));", (3 * X, 120)),
        code('Attempt SQL', ENROLL_ATTEMPT_JS, (8 * X, 0)),
        pg('Log attempt', CRED_SEQ, '={{ $json.attempt_sql }}', (9 * X, 0), always=True, on_error_continue=True),
        code('Return', ENROLL_RETURN_JS, (10 * X, 0)),
        sticky('## Seq: enroll contact\nInput: `{flow, phone_number, email?, first_name?, last_name?, source?, checkout_url?, params?}`. Upserts the Chatwoot contact '
               '(outreach endpoint without content), checks consent, applies the flow\'s re-entry policy and inserts the enrollment. '
               'Returns `outcome`: enrolled, skipped_active, skipped_reentry, skipped_no_consent, unknown_flow, invalid_phone, invalid_flow. '
               'Every call is recorded in `seq_enroll_attempts` with its outcome.',
               (0, -240), 1000, 150),
    ]
    edges = [('Request', 'Normalize'), ('Normalize', 'Valid?'), ('Valid?', 'Upsert contact', 0), ('Valid?', 'Invalid', 1),
             ('Upsert contact', 'Consent'), ('Consent', 'Enroll SQL'), ('Enroll SQL', 'Insert enrollment'), ('Insert enrollment', 'Result'),
             ('Result', 'Attempt SQL'), ('Invalid', 'Attempt SQL'), ('Attempt SQL', 'Log attempt'), ('Log attempt', 'Return')]
    return workflow('Seq: enroll contact', nodes, edges)


def check_key_workflow():
    nodes = [
        wf_trigger('Token', (0, 0)),
        node('Digest', 'n8n-nodes-base.crypto', 1, {'action': 'hash', 'type': 'SHA256', 'value': '={{ $json.token || "" }}', 'dataPropertyName': 'token_digest', 'encoding': 'hex'}, (X, 0)),
        pg('Lookup', CRED_SEQ, "UPDATE seq_api_keys SET last_used_at = now() WHERE token_digest = '{{ $json.token_digest }}' AND revoked_at IS NULL RETURNING name, scopes", (2 * X, 0), always=True),
        code('Verdict', "return $input.all().map(i => ({ json: { authorized: !!i.json.name, key_name: i.json.name || null, scopes: i.json.scopes || [] } }));", (3 * X, 0)),
        sticky('## Seq: check api key\nInput `{token}` (the bearer token or the `key` query parameter). SHA-256 is compared with `seq_api_keys.token_digest`. '
               'Returns `{authorized, key_name, scopes}`.', (0, -200), 800, 110),
    ]
    return workflow('Seq: check api key', nodes, [('Token', 'Digest'), ('Digest', 'Lookup'), ('Lookup', 'Verdict')])


def api_workflow(name, path, after_auth_nodes, after_auth_edges, first_after_auth, respond_body):
    """Webhook → check key → IF → (nodes) → Respond 200; unauthorized → Respond 401."""
    nodes = [
        webhook('Webhook', path, (0, 0)),
        code('Token', "return $input.all().map(i => ({ json: { token: String(i.json.headers.authorization || '').replace(/^Bearer\\s+/i, '') || i.json.query.key || '' } }));", (X, 0)),
        exec_wf('Check key', 'Seq: check api key', (2 * X, 0)),
        if_node('Authorized?', [condition('={{ $json.authorized }}', 'true', type_='boolean')], (3 * X, 0)),
        respond('Respond 401', 401, '={{ JSON.stringify({ error: "unauthorized" }) }}', (4 * X, 160)),
        respond('Respond', 200, respond_body, (4 * X + X * (len(after_auth_nodes) + 1), 0)),
    ] + after_auth_nodes
    edges = [('Webhook', 'Token'), ('Token', 'Check key'), ('Check key', 'Authorized?'), ('Authorized?', first_after_auth, 0),
             ('Authorized?', 'Respond 401', 1)] + after_auth_edges
    return workflow(name, nodes, edges)


def enroll_api():
    nodes = [
        code('Request', "return [{ json: { ...$('Webhook').first().json.body } }];", (4 * X, 0)),
        exec_wf('Enroll', 'Seq: enroll contact', (5 * X, 0)),
    ]
    return api_workflow('Seq API: enroll', 'enroll', nodes, [('Request', 'Enroll'), ('Enroll', 'Respond')], 'Request',
                        '={{ JSON.stringify($json) }}')


EXIT_SQL_JS = JS_HELPERS + r"""
const b = $('Webhook').first().json.body || {};
const phone = e164(b.phone_number || b.phone);
if (!phone) return [{ json: { exit_sql: `SELECT 'invalid_phone' AS outcome, 0 AS exited` } }];
const flow = b.flow ? ` AND flow_key = ${q(String(b.flow))}` : '';
const reason = q(String(b.reason || 'api_exit').slice(0, 100));
return [{ json: { exit_sql: `WITH e AS (UPDATE seq_enrollments SET status = 'exited', ended_at = now(), exit_reason = ${reason}, claimed_at = NULL
    WHERE phone = ${q(phone)} AND status = 'active'${flow} RETURNING id, current_step),
  l AS (INSERT INTO seq_step_logs (enrollment_id, step, outcome, reason, ${RUN_COLS}) SELECT id, current_step, 'exited', ${reason}, ${RUN_VALS} FROM e RETURNING enrollment_id)
  SELECT 'ok' AS outcome, count(*)::int AS exited FROM l` } }];
"""


def exit_api():
    nodes = [
        code('Exit SQL', EXIT_SQL_JS, (4 * X, 0)),
        pg('Exit enrollments', CRED_SEQ, '={{ $json.exit_sql }}', (5 * X, 0), always=True),
    ]
    return api_workflow('Seq API: exit', 'exit', nodes, [('Exit SQL', 'Exit enrollments'), ('Exit enrollments', 'Respond')], 'Exit SQL',
                        '={{ JSON.stringify({ outcome: $json.outcome || "ok", exited: $json.exited || 0 }) }}')


EVENT_SQL_JS = JS_HELPERS + r"""
const b = $('Webhook').first().json.body || {};
const phone = e164(b.phone_number || b.phone);
const kind = ['purchase', 'opt_out', 'custom'].includes(b.kind) ? b.kind : null;
if (!kind || !phone) return [{ json: { event_sql: `SELECT 'invalid' AS outcome, NULL::bigint AS id` } }];
const contact_id = $input.first().json.contact_id || null;
const occurred = b.occurred_at ? q(b.occurred_at) : 'now()';
return [{ json: { event_sql: `INSERT INTO seq_events (contact_id, phone, kind, payload, occurred_at, source)
  VALUES (${contact_id || 'NULL'}, ${q(phone)}, ${q(kind)}, ${qj(b.payload || {})}, ${occurred}, ${q(String(b.source || 'api'))}) RETURNING 'ok' AS outcome, id` } }];
"""


def events_api():
    nodes = [
        pg('Find contact', CRED_RO, "SELECT id AS contact_id FROM contacts WHERE phone_number = '{{ String($('Webhook').first().json.body.phone_number || $('Webhook').first().json.body.phone || '').replace(/[^\\d+]/g, '').replace(/^(\\d{10})$/, '+1$1').replace(/^1(\\d{10})$/, '+1$1') }}' ORDER BY id LIMIT 1", (4 * X, 0), always=True),
        code('Event SQL', EVENT_SQL_JS, (5 * X, 0)),
        pg('Insert event', CRED_SEQ, '={{ $json.event_sql }}', (6 * X, 0), always=True),
    ]
    return api_workflow('Seq API: events', 'events', nodes,
                        [('Find contact', 'Event SQL'), ('Event SQL', 'Insert event'), ('Insert event', 'Respond')], 'Find contact',
                        '={{ JSON.stringify({ outcome: $json.outcome || "invalid", event_id: $json.id || null }) }}')


LABEL_ACTIONS_JS = JS_HELPERS + r"""
// Chatwoot conversation_updated webhook: changed_attributes[].label_list = {previous_value, current_value}
const p = $('Webhook').first().json.body || {};
if (p.event !== 'conversation_updated') return [];
const change = (p.changed_attributes || []).find(c => c.label_list);
if (!change) return [];
const added = (change.label_list.current_value || []).filter(l => !(change.label_list.previous_value || []).includes(l));
const sender = (p.meta && p.meta.sender) || {};
const out = [];
for (const label of added) {
  if (label === 'stop-sequence' && sender.id) {
    out.push({ json: { action: 'exit', contact_id: sender.id, exit_sql: `WITH e AS (UPDATE seq_enrollments SET status = 'exited', ended_at = now(), exit_reason = 'stop_label', claimed_at = NULL
      WHERE contact_id = ${sender.id} AND status = 'active' RETURNING id, current_step)
      INSERT INTO seq_step_logs (enrollment_id, step, outcome, reason, ${RUN_COLS}) SELECT id, current_step, 'exited', 'stop_label', ${RUN_VALS} FROM e` } });
  } else if (label.startsWith('enroll-')) {
    out.push({ json: { action: 'enroll', flow: label.slice(7), phone_number: sender.phone_number, email: sender.email, name: sender.name, source: 'label' } });
  }
}
return out;
"""


def label_watcher():
    nodes = [
        webhook('Webhook', 'chatwoot-events', (0, 0), respond_node=False),
        code('Token', "return [{ json: { token: $json.query.key || '' } }];", (X, 0)),
        exec_wf('Check key', 'Seq: check api key', (2 * X, 0)),
        if_node('Authorized?', [condition('={{ $json.authorized }}', 'true', type_='boolean')], (3 * X, 0)),
        code('Label actions', LABEL_ACTIONS_JS, (4 * X, 0)),
        switch('Action', '={{ $json.action }}', ['enroll', 'exit'], (5 * X, 0)),
        exec_wf('Enroll', 'Seq: enroll contact', (6 * X, -80)),
        pg('Exit enrollments', CRED_SEQ, '={{ $json.exit_sql }}', (6 * X, 80), always=True),
        sticky('## Seq: label watcher\nChatwoot webhook (`conversation_updated`, URL `…/webhook/chatwoot-events?key=<api key>`). '
               'Adding `enroll-<flow>` to a conversation enrolls its contact; adding `stop-sequence` exits every active enrollment.',
               (0, -200), 900, 110),
    ]
    edges = [('Webhook', 'Token'), ('Token', 'Check key'), ('Check key', 'Authorized?'), ('Authorized?', 'Label actions', 0),
             ('Label actions', 'Action'), ('Action', 'Enroll', 0), ('Action', 'Exit enrollments', 1)]
    return workflow('Seq: label watcher', nodes, edges)


def error_workflow():
    text = ("={{ 'Workflow: ' + $json.workflow.name + '\\nExecution: ' + ($json.execution.url || $json.execution.id) + '\\nNode: ' + "
            "(($json.execution.lastNodeExecuted) || '?') + '\\n\\n' + JSON.stringify($json.execution.error, null, 2).slice(0, 4000) }}")
    error_sql_js = JS_HELPERS + r"""
// An execution error carries `execution`; a trigger that failed to start carries `trigger` instead.
return $input.all().map(i => {
  const e = i.json;
  const error = (e.execution && e.execution.error) || (e.trigger && e.trigger.error) || {};
  return { json: { error_sql: `INSERT INTO seq_errors (workflow_id, workflow_name, execution_id, node, message)
    VALUES (${q(e.workflow && e.workflow.id)}, ${q(e.workflow && e.workflow.name)}, ${q(e.execution && e.execution.id)},
            ${q(e.execution && e.execution.lastNodeExecuted)}, ${q(String(error.message || JSON.stringify(error)).slice(0, 2000))})` } };
});
"""
    nodes = [
        node('Error', 'n8n-nodes-base.errorTrigger', 1, {}, (0, 0)),
        # above the email on the canvas so it runs first (v1 order is top to bottom): a failing SMTP server must not lose the record
        code('Error SQL', error_sql_js, (X, 0)),
        pg('Record error', CRED_SEQ, '={{ $json.error_sql }}', (2 * X, 0), always=True, on_error_continue=True),
        node('Email alert', 'n8n-nodes-base.emailSend', 2.1,
             {'fromEmail': ALERT_FROM, 'toEmail': ALERT_EMAIL, 'subject': '={{ "n8n error: " + $json.workflow.name }}',
              'emailFormat': 'text', 'text': text, 'options': {'appendAttribution': False}},
             (X, 160), credentials={'smtp': dict(CRED_SMTP)}),
        sticky('## Seq: error handler\nSet as the Error Workflow of every engine workflow (Settings → Error workflow). '
               'Emails the alert and records the failed run in `seq_errors` (shown on Chatwoot\'s Reports → Sequences page). '
               'Housekeeping releases the claims of a failed run.', (0, -180), 700, 120),
    ]
    return workflow('Seq: error handler', nodes, [('Error', 'Error SQL'), ('Error', 'Email alert'), ('Error SQL', 'Record error')])



# ----------------------------------------------------------------------------------------------- Housekeeping

HK_RELEASE_SQL = """WITH r AS (UPDATE seq_enrollments SET claimed_at = NULL WHERE status = 'active' AND claimed_at < now() - interval '15 minutes' RETURNING id)
SELECT count(*)::int AS released FROM r"""

HK_LOST_SQL = """WITH l AS (UPDATE seq_message_logs SET status = 'unknown', error = 'no outcome recorded within 10 minutes'
                 WHERE status = 'pending' AND sent_at < now() - interval '10 minutes' RETURNING enrollment_id),
     e AS (UPDATE seq_enrollments SET status = 'held', held_at = now(), claimed_at = NULL
           WHERE id IN (SELECT enrollment_id FROM l) AND status = 'active' RETURNING id)
SELECT count(*)::int AS lost FROM l"""

HK_PROBLEMS_SQL = """SELECT
  (SELECT count(*)::int FROM seq_enrollments WHERE status = 'held' AND held_at > now() - interval '16 minutes') AS newly_held,
  (SELECT count(*)::int FROM seq_enrollments WHERE status = 'active' AND claimed_at IS NULL AND next_run_at < now() - interval '30 minutes') AS overdue,
  (SELECT count(*)::int FROM seq_enrollments WHERE status = 'active' AND defer_count = 6) AS deferring,
  (SELECT count(*)::int FROM seq_step_logs WHERE outcome = 'failed' AND ran_at > now() - interval '16 minutes') AS failed_sends,
  {{ $('Release stale claims').first().json.released }} AS released,
  {{ $('Flag lost sends').first().json.lost }} AS lost"""

HK_SENT_SQL = """SELECT coalesce(string_agg(chatwoot_message_id::text, ','), '0') AS ids FROM seq_message_logs
WHERE status = 'sent' AND chatwoot_message_id IS NOT NULL AND sent_at > now() - interval '3 days'"""

# messages.status 3 = failed (Twilio rejected the send, or its delivery callback reported failed / undelivered)
HK_FAILED_SQL = """SELECT m.id AS message_id, m.conversation_id, coalesce(((m.content_attributes #>> '{}')::jsonb)->>'external_error', 'no error text') AS external_error   -- Rails stores this column as a JSON string
FROM messages m WHERE m.id IN ({{ $json.ids }}) AND m.status = 3"""

HK_FAILURE_SQL_JS = JS_HELPERS + r"""
return $input.all().map(i => {
  const m = i.json;
  const reason = 'delivery_failed: ' + String(m.external_error).slice(0, 300);
  return { json: { ...m, mark_sql: `WITH l AS (UPDATE seq_message_logs SET status = 'failed', error = ${q(reason)}
      WHERE chatwoot_message_id = ${Number(m.message_id)} AND status = 'sent' RETURNING enrollment_id, step),
    s AS (INSERT INTO seq_step_logs (enrollment_id, step, outcome, reason, ${RUN_COLS}) SELECT enrollment_id, step, 'failed', ${q(reason)}, ${RUN_VALS} FROM l)
    SELECT ${Number(m.conversation_id)} AS conversation_id, ${q(m.external_error)} AS external_error, l.step, e.phone, e.status, e.current_step,
           e.next_run_at, coalesce(f.name, e.flow_key) AS flow_name
    FROM l JOIN seq_enrollments e ON e.id = l.enrollment_id LEFT JOIN seq_flows f ON f.key = e.flow_key` } };
});
"""

HK_FAILURE_NOTE_JS = r"""
return $input.all().filter(i => i.json.conversation_id).map(i => {
  const r = i.json;
  const next = r.status === 'active'
    ? `The sequence is still running: step ${r.current_step} is due ${DateTime.fromISO(new Date(r.next_run_at).toISOString()).toUTC().toFormat('LLL d, HH:mm')} UTC. Fix the number, or add the stop-sequence label to end it.`
    : `The sequence is no longer running (${r.status}).`;
  return { json: { conversation_id: r.conversation_id,
    content: `SMS not delivered: step ${r.step} of the "${r.flow_name}" sequence to ${r.phone} failed. Carrier / Twilio said: ${String(r.external_error).replace(/\s+/g, ' ').trim()}. ${next}` } };
});
"""

HK_ALERT_JS = r"""
const p = $input.first().json;
const lines = [];
if (p.newly_held) lines.push(`${p.newly_held} enrollment(s) moved to held: check the conversation in Chatwoot, then skip or resend (seq_enrollments.status = 'held').`);
if (p.lost) lines.push(`${p.lost} send(s) had no recorded outcome after 10 minutes (message log status 'unknown').`);
if (p.released) lines.push(`${p.released} stale claim(s) released (a flow run died mid-way).`);
if (p.overdue) lines.push(`${p.overdue} due row(s) older than 30 minutes: is the flow workflow active?`);
if (p.deferring) lines.push(`${p.deferring} enrollment(s) deferred 6 times in a row: check the flow's send window and the inbox hours.`);
if (p.failed_sends) lines.push(`${p.failed_sends} send(s) failed (rejected by Chatwoot, Twilio or the carrier; delivery failures get a private note on the conversation) in the last 15 minutes.`);
if (!lines.length) return [];
return [{ json: { subject: 'SMS sequences: ' + lines.length + ' problem(s)', text: lines.join('\n') + '\n\n' + JSON.stringify(p) } }];
"""

HK_CHANGED_SQL = """SELECT c.contact_id,
  (SELECT coalesce(array_agg(a.flow_key), '{}') FROM seq_enrollments a WHERE a.contact_id = c.contact_id AND a.status = 'active') AS active_flows,
  (SELECT string_agg(l.flow_key || ': ' || CASE l.status
      WHEN 'active' THEN 'step ' || l.current_step || ', next ' || to_char(l.next_run_at AT TIME ZONE 'UTC', 'Mon DD HH24:MI') || ' UTC'
      WHEN 'held' THEN 'held, needs a person'
      WHEN 'completed' THEN 'completed'
      ELSE 'exited (' || coalesce(l.exit_reason, '') || ')' END, ' | ' ORDER BY l.enrolled_at DESC)
   FROM (SELECT DISTINCT ON (flow_key) * FROM seq_enrollments b WHERE b.contact_id = c.contact_id ORDER BY flow_key, enrolled_at DESC) l) AS sequence_status
FROM (SELECT DISTINCT e.contact_id FROM seq_enrollments e
      WHERE e.enrolled_at > now() - interval '16 minutes' OR e.ended_at > now() - interval '16 minutes' OR e.held_at > now() - interval '16 minutes'
         OR EXISTS (SELECT 1 FROM seq_step_logs s WHERE s.enrollment_id = e.id AND s.ran_at > now() - interval '16 minutes')) c"""

HK_MIRROR_JS = r"""
const changed = $('Changed contacts').all();
const out = [];
$input.all().forEach((item, i) => {
  const row = changed[i].json;
  if (item.json.error) return;                               // contact gone or API down: try again next run
  const current = (item.json.payload || []).filter(l => !l.startsWith('in-sequence-'));
  const labels = current.concat((row.active_flows || []).map(f => 'in-sequence-' + f));
  out.push({ json: { contact_id: row.contact_id, labels, sequence_status: row.sequence_status || '' } });
});
return out;
"""


def housekeeping_workflow():
    nodes = [
        schedule('Every 15 minutes', 15, (0, 0)),
        pg('Release stale claims', CRED_SEQ, HK_RELEASE_SQL, (X, -120), always=True),
        pg('Flag lost sends', CRED_SEQ, HK_LOST_SQL, (2 * X, -120), always=True),
        pg('Problems', CRED_SEQ, HK_PROBLEMS_SQL, (3 * X, -120), always=True),
        code('Alert text', HK_ALERT_JS, (4 * X, -120)),
        node('Email alert', 'n8n-nodes-base.emailSend', 2.1,
             {'fromEmail': ALERT_FROM, 'toEmail': ALERT_EMAIL, 'subject': '={{ $json.subject }}', 'emailFormat': 'text',
              'text': '={{ $json.text }}', 'options': {'appendAttribution': False}}, (5 * X, -120), credentials={'smtp': dict(CRED_SMTP)}),
        pg('Changed contacts', CRED_SEQ, HK_CHANGED_SQL, (X, 120)),
        http('Current labels', 'GET', f'={API}/contacts/{{{{ $json.contact_id }}}}/labels', (2 * X, 120)),
        code('Mirror', HK_MIRROR_JS, (3 * X, 120)),
        http('Set labels', 'POST', f'={API}/contacts/{{{{ $json.contact_id }}}}/labels', (4 * X, 120), '={{ JSON.stringify({ labels: $json.labels }) }}'),
        http('Set status', 'PATCH', f"={API}/contacts/{{{{ $('Mirror').item.json.contact_id }}}}", (5 * X, 120),
             "={{ JSON.stringify({ custom_attributes: { sequence_status: $('Mirror').item.json.sequence_status } }) }}"),
        pg('Recent sends', CRED_SEQ, HK_SENT_SQL, (X, 340)),
        pg('Failed in Chatwoot', CRED_RO, HK_FAILED_SQL, (2 * X, 340)),
        code('Failure SQL', HK_FAILURE_SQL_JS, (3 * X, 340)),
        pg('Mark failed', CRED_SEQ, '={{ $json.mark_sql }}', (4 * X, 340)),
        code('Failure note', HK_FAILURE_NOTE_JS, (5 * X, 340)),
        http('Post failure note', 'POST', f'={API}/conversations/{{{{ $json.conversation_id }}}}/messages', (6 * X, 340),
             "={{ JSON.stringify({ content: $json.content, private: true, message_type: 'outgoing' }) }}"),
        sticky('## Seq: housekeeping\nEvery 15 minutes. Top: release claims older than 15 min, mark sends with no outcome after 10 min as '
               '`unknown` and hold their enrollment, then email a summary of anything wrong. Bottom: mirror enrollments that changed '
               'since the last run to Chatwoot (`in-sequence-<flow>` labels and the `sequence_status` attribute). Third row: texts from the last 3 days '
               'that Twilio or the carrier failed get a private note on their conversation and are marked failed in the log.', (0, -320), 1100, 170),
    ]
    edges = [('Every 15 minutes', 'Release stale claims'), ('Release stale claims', 'Flag lost sends'), ('Flag lost sends', 'Problems'),
             ('Problems', 'Alert text'), ('Alert text', 'Email alert'),
             ('Every 15 minutes', 'Changed contacts'), ('Changed contacts', 'Current labels'), ('Current labels', 'Mirror'),
             ('Mirror', 'Set labels'), ('Set labels', 'Set status'),
             ('Every 15 minutes', 'Recent sends'), ('Recent sends', 'Failed in Chatwoot'), ('Failed in Chatwoot', 'Failure SQL'),
             ('Failure SQL', 'Mark failed'), ('Mark failed', 'Failure note'), ('Failure note', 'Post failure note')]
    return workflow('Seq: housekeeping', nodes, edges)


# The Salesforce lessons drip (Quick SMS day 0, 24h, 48h, 7d, 14d, 6 weeks). Delays are the gaps between steps.
LESSONS_STEPS = [
    ('1', "Hey {{first_name}}, I understand you're looking for tennis lessons - I'm {{rep_first_name}}, your dedicated account manager at "
          "PlayYourCourt. Let me know when you can chat or text to review coaches and hear how this works. You can text me or call me at "
          "{{rep_phone}}. Would you like to see coach options now? ... Also, I'm a real person, but if you don't want me to text you, just reply stop.",
     1, 'days', 'quick SMS, day 0'),
    ('2', "Hey {{first_name}}, This is {{rep_first_name}}. I wanted to check back to see if you're still interested in tennis lessons? "
          "When did you want to get started?", 1, 'days', '24 hours'),
    ('3', "Hey, {{first_name}} I really don't want to bother you. Let me know if you're still interested in tennis lessons. You can call or "
          "text me at {{rep_phone}}. Take care until then, {{rep_first_name}}.", 5, 'days', '48 hours'),
    ('4', "Hey {{first_name}}, It's {{rep_first_name}} at PlayYourCourt. How've you been? Wanted to see if it's a better time to try and set "
          "up tennis lessons? You can call or text me at {{rep_phone}}.", 7, 'days', '7 days'),
    ('5', "Hey {{first_name}}, {{rep_first_name}} here from PlayYourCourt. I have a few great coaches with openings right now. Want me to "
          "send you some options? You can call or text me at {{rep_phone}}.", 28, 'days', '14 days'),
    ('6', "Hey {{first_name}}, We know it's tough to find tennis coaches these days. Were you ever able to find a coach?",
     0, 'days', '6 weeks, final'),
]

# Abandoned membership signup: one text with the checkout link (Flow config default, or `checkout_url` from the enroll webhook).
MEMBERSHIP_STEPS = [
    ('1', "Hey {{first_name}}, this is {{rep_first_name}} from PlayYourCourt. I saw you started to sign up for our tennis membership, but "
          "didn't finish. Here's a link {{checkout_url}} to pick up where you left off. {{first_name}}, did you have any questions or "
          "problems getting signed up? Reply STOP to opt out.", 0, 'days', 'abandoned signup, single text'),
]


# Starting settings for the Flow config node of each generated flow. The file is editor-owned afterwards:
# the real inbox id, rep, policy and holidays are set in the n8n editor and published, not here.
# Inbox ids below are the local database's Twilio inboxes (Lesson Sales 5, Membership Sales 68) and their Salesforce import
# inboxes; check them on production.
COMMON_END_RULES = [{'rule': 'replied'}, {'rule': 'agent_messaged'}, {'rule': 'purchased'}]
FLOWS = {
    'lessons': ({'name': 'Lessons lead drip', 'inbox_id': 5,
                 'reentry_policy': 'never', 'business_hours': True, 'holidays': [],
                 'end_rules': COMMON_END_RULES + [
                     # already texted by the old Salesforce drip, or has history on the lessons number
                     {'rule': 'field', 'field': 'drip_step', 'op': 'set'},
                     {'rule': 'no_prior_conversation', 'inbox_ids': [5, 86]}]}, LESSONS_STEPS),
    'membership': ({'name': 'Membership abandoned signup', 'inbox_id': 68,
                    'reentry_policy': 'never', 'business_hours': True, 'holidays': [],
                    'checkout_url': 'https://www.playyourcourt.com/tennis-community/',
                    'end_rules': COMMON_END_RULES + [{'rule': 'no_prior_conversation', 'inbox_ids': [68]}]}, MEMBERSHIP_STEPS),
}


def main():
    os.makedirs(OUT, exist_ok=True)
    engine = [gate_workflow(), send_workflow(), enroll_contact_workflow(), check_key_workflow(), enroll_api(), exit_api(), events_api(),
              label_watcher(), housekeeping_workflow(), error_workflow()]
    for wf in engine:
        write(wf)
    for key, (config, steps) in FLOWS.items():
        path = os.path.join(OUT, f'flow_{key}.json')
        if os.path.exists(path):
            print(f'kept    {path} (owned by the editor)')
            continue
        write(flow_workflow(key, config, steps))


def write(wf):
    fname = wf['name'].lower().replace('seq api: ', 'api_').replace('seq: ', '').replace('flow: ', 'flow_').replace(' ', '_') + '.json'
    path = os.path.join(OUT, fname)
    with open(path, 'w') as f:
        json.dump(wf, f, indent=2)
        f.write('\n')
    print(f'wrote   {path} ({len(wf["nodes"])} nodes)')


if __name__ == '__main__':
    main()
