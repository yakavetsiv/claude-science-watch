#!/usr/bin/env node
// Claude Science Watch helper.
// Polls the local Claude Science daemon for plan usage and session activity,
// and sends push notifications through ntfy. Also writes status.json for the
// watchOS app.
//
// Usage:
//   node csw.js            run forever (used by the launchd agent)
//   node csw.js --once     poll once and exit
//   node csw.js --test     send a test notification and exit
//   node csw.js --status   print current usage and exit (no notifications)

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');
const { execFile } = require('child_process');

const CONFIG_DIR = path.join(os.homedir(), '.config', 'claude-science-watch');
const CONFIG_PATH = path.join(CONFIG_DIR, 'config.json');
const STATE_PATH = path.join(CONFIG_DIR, 'state.json');
const STATUS_PATH = path.join(CONFIG_DIR, 'status.json');

const CLI = '/Applications/Claude Science.app/Contents/Resources/bin/claude-science';

const DEFAULT_CONFIG = {
  daemonUrl: 'http://localhost:8765',
  ntfyServer: 'https://ntfy.sh',
  ntfyTopic: null, // generated on first run
  // The watch app reads usage from this topic. Do not subscribe to it on the
  // phone: it gets a silent status message whenever usage changes.
  statusTopic: null, // defaults to `${ntfyTopic}-status`
  statusHeartbeatMinutes: 30,
  // Allow/Deny answers from the watch arrive on this topic. Anyone who knows
  // it (or the status topic, which carries the one-time codes) can answer
  // permission requests, so keep both private.
  replyTopic: null, // defaults to `${ntfyTopic}-reply`
  approvalsEnabled: true,
  pollSeconds: 30,
  thresholds: [50, 75, 90, 100],
  notifyCompleted: true,
  notifyNeedsInput: true,
  // When false, notifications say "a session" instead of the project and
  // session names, so no research titles leave this Mac.
  includeNames: true,
};

const LIMIT_LABELS = {
  session: '5-hour limit',
  weekly_all: 'Weekly limit (all models)',
  weekly_scoped: 'Weekly limit',
};

// Logs go to stderr so --status prints clean JSON on stdout.
function log(...args) {
  console.error(new Date().toISOString(), ...args);
}

function readJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return fallback;
  }
}

function writeJson(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const tmp = `${file}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(data, null, 2), { mode: 0o600 });
  fs.renameSync(tmp, file);
}

function loadConfig() {
  const config = { ...DEFAULT_CONFIG, ...readJson(CONFIG_PATH, {}) };
  if (!config.ntfyTopic) {
    // Anyone who knows the topic can read it on public ntfy.sh, so make it unguessable.
    config.ntfyTopic = `csw-${crypto.randomBytes(12).toString('hex')}`;
    writeJson(CONFIG_PATH, config);
    log(`Created ${CONFIG_PATH} with new ntfy topic ${config.ntfyTopic}`);
  }
  config.statusTopic ??= `${config.ntfyTopic}-status`;
  config.replyTopic ??= `${config.ntfyTopic}-reply`;
  return config;
}

// ---------- Daemon auth ----------

// Cookie jar for the daemon session (operon_csrf + operon_auth).
let cookies = {};

function cookieHeader() {
  return Object.entries(cookies).map(([k, v]) => `${k}=${v}`).join('; ');
}

function storeCookies(res) {
  for (const line of res.headers.getSetCookie?.() ?? []) {
    const [pair] = line.split(';');
    const i = pair.indexOf('=');
    if (i > 0) cookies[pair.slice(0, i).trim()] = pair.slice(i + 1).trim();
  }
}

function getLoginUrl() {
  return new Promise((resolve, reject) => {
    execFile(CLI, ['url'], { timeout: 30000 }, (err, stdout) => {
      if (err) return reject(new Error(`claude-science url failed: ${err.message}`));
      const url = stdout.split('\n').map((s) => s.trim()).find((s) => /^https?:\/\//.test(s));
      if (!url) return reject(new Error('claude-science url printed no link'));
      resolve(url);
    });
  });
}

// Mirrors what the browser does with the single-use login link:
// GET the link (sets operon_csrf and renders a form with a fresh nonce),
// then POST that nonce to /api/auth/nonce (sets operon_auth).
async function signIn(config) {
  cookies = {};
  const loginUrl = await getLoginUrl();
  const page = await fetch(loginUrl, { headers: { Accept: 'text/html' }, redirect: 'manual' });
  storeCookies(page);
  const html = await page.text();
  const nonce = html.match(/name="nonce" value="([^"]+)"/)?.[1];
  if (!nonce) throw new Error(`login page had no nonce (HTTP ${page.status})`);

  const res = await fetch(`${config.daemonUrl}/api/auth/nonce`, {
    method: 'POST',
    redirect: 'manual',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      Origin: config.daemonUrl,
      Cookie: cookieHeader(),
    },
    body: new URLSearchParams({ nonce, dest: '/' }),
  });
  storeCookies(res);
  await res.arrayBuffer();
  if (!cookies.operon_auth) throw new Error(`sign-in returned no auth cookie (HTTP ${res.status})`);
  log('Signed in to Claude Science daemon');
}

async function daemonGet(config, apiPath) {
  for (let attempt = 0; attempt < 2; attempt++) {
    if (!cookies.operon_auth) await signIn(config);
    const res = await fetch(`${config.daemonUrl}${apiPath}`, {
      headers: { Accept: 'application/json', Cookie: cookieHeader() },
    });
    storeCookies(res);
    if (res.status === 401) {
      cookies = {};
      continue;
    }
    if (!res.ok) throw new Error(`${apiPath} returned HTTP ${res.status}`);
    return res.json();
  }
  throw new Error(`${apiPath} still unauthorized after signing in again`);
}

// POSTs need the CSRF cookie echoed in the x-operon-csrf header, as the
// web UI does.
async function daemonPost(config, apiPath, body) {
  for (let attempt = 0; attempt < 2; attempt++) {
    if (!cookies.operon_auth) await signIn(config);
    const res = await fetch(`${config.daemonUrl}${apiPath}`, {
      method: 'POST',
      headers: {
        Accept: 'application/json',
        'Content-Type': 'application/json',
        Origin: config.daemonUrl,
        Cookie: cookieHeader(),
        'x-operon-csrf': cookies.operon_csrf ?? '',
      },
      body: JSON.stringify(body),
    });
    storeCookies(res);
    if (res.status === 401) {
      cookies = {};
      continue;
    }
    const text = await res.text();
    if (!res.ok) throw new Error(`${apiPath} returned HTTP ${res.status}: ${text.slice(0, 200)}`);
    return text ? JSON.parse(text) : null;
  }
  throw new Error(`${apiPath} still unauthorized after signing in again`);
}

async function daemonRunning(config) {
  try {
    await fetch(`${config.daemonUrl}/`, { method: 'HEAD', signal: AbortSignal.timeout(3000) });
    return true;
  } catch {
    return false;
  }
}

// ---------- ntfy ----------

async function push(config, { title, message, priority = 3, tags = [], actions }) {
  const res = await fetch(config.ntfyServer, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ topic: config.ntfyTopic, title, message, priority, tags, actions }),
  });
  if (!res.ok) throw new Error(`ntfy returned HTTP ${res.status}`);
  log(`Pushed: ${title} — ${message}`);
}

// Publishes status.json to the status topic for the watch app. ntfy.sh limits
// anonymous publishing per day, so only publish when the numbers change or
// when the heartbeat is due (the watch shows how old the data is).
async function publishStatus(config, state, status) {
  const { updated_at, ...rest } = status;
  const signature = JSON.stringify(rest);
  const heartbeatMs = config.statusHeartbeatMinutes * 60 * 1000;
  const due = Date.now() - (state.statusPublishedAt ?? 0) >= heartbeatMs;
  if (signature === state.statusSignature && !due) return;

  const res = await fetch(config.ntfyServer, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ topic: config.statusTopic, message: JSON.stringify(status), priority: 1 }),
  });
  if (!res.ok) throw new Error(`ntfy status publish returned HTTP ${res.status}`);
  state.statusSignature = signature;
  state.statusPublishedAt = Date.now();
}

// ---------- Polling ----------

function scopeName(scope) {
  if (!scope) return '';
  if (typeof scope === 'string') return scope;
  return scope.model?.display_name ?? scope.model?.id ?? scope.surface ?? '';
}

function limitLabel(limit) {
  const base = LIMIT_LABELS[limit.kind] ?? limit.kind;
  const scope = scopeName(limit.scope);
  return limit.kind === 'weekly_scoped' && scope ? `${base} (${scope})` : base;
}

// resets_at drifts by fractions of a second between polls, so compare windows
// rounded to the nearest 10 minutes.
function windowKey(iso) {
  if (!iso) return '';
  const step = 10 * 60 * 1000;
  return new Date(Math.round(new Date(iso).getTime() / step) * step).toISOString();
}

function formatReset(iso) {
  if (!iso) return '';
  const ms = new Date(iso) - Date.now();
  if (ms <= 0) return 'resetting now';
  const h = Math.floor(ms / 3600000);
  const m = Math.round((ms % 3600000) / 60000);
  const rel = h >= 24 ? `${Math.floor(h / 24)}d ${h % 24}h` : h > 0 ? `${h}h ${m}m` : `${m}m`;
  return `resets in ${rel}`;
}

async function checkUsage(config, state, notify) {
  const usage = await daemonGet(config, '/api/usage?fresh=1');
  if (!usage.ok) throw new Error(`usage unavailable: ${usage.message ?? usage.reason}`);
  const limits = usage.data.limits ?? [];

  state.thresholds ??= {};
  for (const limit of limits) {
    // One threshold record per limit window, so a reset starts the count again.
    const key = `${limit.kind}:${scopeName(limit.scope)}`;
    const prev = state.thresholds[key];
    const window = windowKey(limit.resets_at);
    const record = prev && prev.window === window ? prev : { window, notified: [] };
    if (prev && prev.window !== window && prev.notified.length && notify) {
      await push(config, {
        title: `${limitLabel(limit)} reset`,
        message: `Now at ${limit.percent}%.`,
        priority: 2,
        tags: ['white_check_mark'],
      });
    }
    const crossed = config.thresholds.filter((t) => limit.percent >= t && !record.notified.includes(t));
    if (crossed.length && notify) {
      const top = Math.max(...crossed);
      await push(config, {
        title: `${limitLabel(limit)}: ${limit.percent}% used`,
        message: formatReset(limit.resets_at) || 'Claude Science usage',
        priority: top >= 100 ? 5 : top >= 90 ? 4 : 3,
        tags: [top >= 90 ? 'warning' : 'hourglass'],
      });
    }
    record.notified.push(...crossed);
    state.thresholds[key] = record;
  }
  return usage.data;
}

function sessionLine(config, project, bench) {
  if (!config.includeNames) return 'A Claude Science session';
  const name = bench.name || bench.task_summary || 'Session';
  return `${project.name}: ${name}`;
}

async function checkSessions(config, state, notify) {
  const dash = await daemonGet(config, '/api/projects/dashboard');
  const seenCompleted = new Set(state.seenCompleted ?? []);
  const prevNeedsInput = new Set(state.needsInput ?? []);
  const nowNeedsInput = new Set();
  const prevProcessing = state.processing ?? {};
  const nowProcessing = {};
  // Bench id -> time we last sent "finished", so a session that stops
  // processing and is also marked completed only notifies once.
  const finishedAt = state.finishedAt ?? {};
  const finished = async (project, bench) => {
    const last = finishedAt[bench.id] ?? 0;
    finishedAt[bench.id] = Date.now();
    if (Date.now() - last < 10 * 60 * 1000 || !notify || !config.notifyCompleted) return;
    await push(config, {
      title: 'Claude Science session finished',
      message: sessionLine(config, project, bench),
      priority: 3,
      tags: ['white_check_mark'],
    });
  };

  for (const project of dash.projects ?? []) {
    for (const bench of project.processing_benches ?? []) {
      if (bench?.id) nowProcessing[bench.id] = { project: project.name, name: bench.name ?? null };
    }
  }

  // Sessions waiting on the user. The "needs your input" push is sent by
  // poll() after checkApprovals, and only when the wait is not a permission
  // request (those get their own Allow/Deny push).
  const needsInput = [];
  for (const project of dash.projects ?? []) {
    for (const bench of project.needs_input_benches ?? []) {
      if (!bench?.id) continue;
      nowNeedsInput.add(bench.id);
      needsInput.push({
        id: bench.id,
        project: project.name,
        name: bench.name || bench.task_summary || 'Session',
        isNew: !prevNeedsInput.has(bench.id),
        line: sessionLine(config, project, bench),
      });
    }
    for (const bench of project.recently_completed ?? []) {
      if (!bench?.id) continue;
      const key = `${bench.id}@${bench.completed_at ?? ''}`;
      if (seenCompleted.has(key)) continue;
      seenCompleted.add(key);
      await finished(project, bench);
    }
  }

  // A session that was running and has stopped without asking for input
  // has finished its turn. Most sessions go idle rather than "completed",
  // so this is the main source of finished alerts.
  for (const [id, info] of Object.entries(prevProcessing)) {
    if (nowProcessing[id] || nowNeedsInput.has(id)) continue;
    await finished({ name: info.project }, { id, name: info.name });
  }

  const cutoff = Date.now() - 24 * 3600 * 1000;
  state.finishedAt = Object.fromEntries(Object.entries(finishedAt).filter(([, t]) => t > cutoff));
  state.processing = nowProcessing;
  state.needsInput = [...nowNeedsInput];
  state.seenCompleted = [...seenCompleted].slice(-500);
  return {
    counts: {
      processing: dash.total_processing ?? 0,
      needsInput: dash.total_needs_input ?? 0,
    },
    needsInput,
  };
}

// ---------- Approvals ----------

// Pending permission requests by requestId, rebuilt on every poll. The reply
// listener reads it, so it lives in memory; nonces persist in state.json so a
// helper restart does not invalidate buttons already on the watch.
let approvals = new Map();
const usedNonces = new Set();
const APPROVAL_TTL_MS = 60 * 60 * 1000;

function describeRequest(req) {
  if (req.kind === 'local_exec') {
    const firstLine = String(req.code ?? '').split('\n').find((l) => l.trim()) ?? '';
    return { title: `Run ${req.tool ?? 'code'}`, detail: firstLine.slice(0, 120) };
  }
  const target = req.host ?? req.domain ?? req.url ?? req.path ?? req.command ?? req.tool ?? '';
  const kind = String(req.kind ?? 'request').replace(/_/g, ' ');
  return { title: `Allow ${kind}`, detail: String(target).slice(0, 120) };
}

// Pending requests that are questions for the user, not permissions. They
// need typed answers, which Allow/Deny cannot give, so they only get the
// plain "needs your input" alert.
const QUESTION_KINDS = new Set(['ask', 'question', 'plan_approval']);

/// Pending permission requests in a frame and any children it includes.
function collectPending(frame, out = []) {
  for (const req of frame?.output_data?.pending_input_requests ?? []) {
    if (!req || typeof req !== 'object' || !req.requestId) continue;
    if (QUESTION_KINDS.has(req.kind) || req.questions) continue;
    out.push(req);
  }
  for (const child of frame?.children ?? []) collectPending(child, out);
  return out;
}

async function checkApprovals(config, state, notify, needsInput) {
  const known = state.approvals ?? {};
  const next = new Map();

  for (const { id, project, name } of needsInput) {
    let frame;
    try {
      frame = await daemonGet(config, `/api/frames/${encodeURIComponent(id)}`);
    } catch (err) {
      log(`Could not read session ${id}: ${err.message}`);
      continue;
    }
    for (const req of collectPending(frame)) {
      const prev = known[req.requestId];
      const { title, detail } = describeRequest(req);
      const approval = {
        id: req.requestId,
        nonce: prev?.nonce ?? crypto.randomBytes(16).toString('hex'),
        frame_id: req.frameId ?? id,
        tool_id: req.tool_id ?? null,
        kind: req.kind ?? null,
        title,
        detail: config.includeNames ? detail : '',
        project: config.includeNames ? project : null,
        session: config.includeNames ? name : null,
        created_at: req.createdAt ?? new Date().toISOString(),
      };
      next.set(approval.id, approval);

      if (!prev && notify) {
        const answer = (decision) => ({
          action: 'http',
          label: decision === 'allow' ? 'Allow once' : 'Deny',
          url: `${config.ntfyServer}/${config.replyTopic}`,
          method: 'POST',
          body: JSON.stringify({ id: approval.id, nonce: approval.nonce, decision }),
          clear: true,
        });
        await push(config, {
          title: `Claude Science: ${title}?`,
          message: [config.includeNames ? `${project}: ${name}` : 'A session', approval.detail]
            .filter(Boolean).join('\n'),
          priority: 4,
          tags: ['lock'],
          actions: [answer('allow'), answer('deny')],
        });
      }
    }
  }

  approvals = next;
  state.approvals = Object.fromEntries(next);
  return [...next.values()];
}

async function resolveApproval(config, reply) {
  const approval = approvals.get(reply?.id);
  if (!approval) return log(`Ignored answer for unknown or finished request ${reply?.id}`);
  if (reply.nonce !== approval.nonce || usedNonces.has(reply.nonce)) {
    return log(`Rejected answer for ${approval.id}: bad or reused code`);
  }
  if (Date.now() - new Date(approval.created_at).getTime() > APPROVAL_TTL_MS) {
    return log(`Rejected answer for ${approval.id}: older than 1 hour`);
  }
  if (reply.decision !== 'allow' && reply.decision !== 'deny') {
    return log(`Rejected answer for ${approval.id}: unknown decision ${reply.decision}`);
  }
  usedNonces.add(reply.nonce);

  const response = {
    requestId: approval.id,
    action: reply.decision === 'allow' ? 'allow_once' : 'deny',
  };
  if (approval.tool_id) response.tool_id = approval.tool_id;
  const result = await daemonPost(config, `/api/frames/${encodeURIComponent(approval.frame_id)}/resolve-input`, {
    responses: [response],
  });
  approvals.delete(approval.id);
  log(`${reply.decision === 'allow' ? 'Allowed' : 'Denied'} ${approval.title} (${approval.id}): ${result?.status ?? 'ok'}`);
}

// Streams the reply topic and applies each answer. The first connection
// reads only new answers (an old one must not replay after a restart);
// reconnects pass `since` so answers sent while disconnected are not lost.
async function listenForReplies(config) {
  let since = null;
  for (;;) {
    try {
      const query = since ? `?since=${since}` : '';
      const res = await fetch(`${config.ntfyServer}/${config.replyTopic}/json${query}`);
      if (!res.ok || !res.body) throw new Error(`HTTP ${res.status}`);
      const decoder = new TextDecoder();
      let buffer = '';
      for await (const chunk of res.body) {
        buffer += decoder.decode(chunk, { stream: true });
        let nl;
        while ((nl = buffer.indexOf('\n')) >= 0) {
          const line = buffer.slice(0, nl).trim();
          buffer = buffer.slice(nl + 1);
          if (!line) continue;
          const event = JSON.parse(line);
          if (event.id) since = event.id;
          if (event.event !== 'message') continue;
          try {
            await resolveApproval(config, JSON.parse(event.message));
          } catch (err) {
            log(`Answer failed: ${err.message}`);
          }
        }
      }
    } catch (err) {
      log(`Reply stream dropped: ${err.message}`);
    }
    await new Promise((r) => setTimeout(r, 5000));
  }
}

async function poll(config, { notify = true } = {}) {
  if (!(await daemonRunning(config))) {
    log('Claude Science daemon is not running; skipping');
    return null;
  }
  const state = readJson(STATE_PATH, {});
  // On the very first poll, record what already exists without notifying.
  const firstRun = !state.initialized;
  const doNotify = notify && !firstRun;

  const usage = await checkUsage(config, state, doNotify);
  const sessions = await checkSessions(config, state, doNotify);
  const pending = config.approvalsEnabled
    ? await checkApprovals(config, state, doNotify, sessions.needsInput)
    : [];

  if (doNotify && config.notifyNeedsInput) {
    for (const wait of sessions.needsInput) {
      if (!wait.isNew || pending.some((a) => a.frame_id === wait.id || a.session === wait.name)) continue;
      await push(config, {
        title: 'Claude Science needs your input',
        message: wait.line,
        priority: 4,
        tags: ['raised_hand'],
      });
    }
  }

  const status = {
    updated_at: new Date().toISOString(),
    limits: (usage.limits ?? []).map((l) => ({
      kind: l.kind,
      label: limitLabel(l),
      percent: l.percent,
      severity: l.severity,
      // Normalized to millisecond ISO 8601, which Swift's date parser accepts.
      resets_at: l.resets_at ? new Date(l.resets_at).toISOString() : null,
      is_active: l.is_active,
    })),
    sessions: sessions.counts,
    // What the watch app lists under Approvals. `nonce` is the one-time code
    // the watch sends back with its answer.
    approvals: pending.map(({ id, nonce, title, detail, project, session, created_at }) => ({
      id, nonce, title, detail, project, session, created_at,
    })),
    reply_topic: config.replyTopic,
  };
  writeJson(STATUS_PATH, status);

  // A read-only poll (--status) must not mark anything as already notified.
  if (notify) {
    try {
      await publishStatus(config, state, status);
    } catch (err) {
      log(`Status publish failed: ${err.message}`);
    }
    state.initialized = true;
    writeJson(STATE_PATH, state);
  }
  return status;
}

async function main() {
  const config = loadConfig();
  const arg = process.argv[2];

  if (arg === '--test') {
    await push(config, { title: 'Claude Science Watch', message: 'Test notification from your Mac.', tags: ['tada'] });
    return;
  }
  if (arg === '--status') {
    const status = await poll(config, { notify: false });
    console.log(JSON.stringify(status, null, 2));
    return;
  }
  if (arg === '--once') {
    await poll(config);
    return;
  }

  log(`Polling every ${config.pollSeconds}s; ntfy topic ${config.ntfyTopic}`);
  if (config.approvalsEnabled) listenForReplies(config);
  for (;;) {
    try {
      await poll(config);
    } catch (err) {
      log(`Poll failed: ${err.message}`);
      cookies = {};
    }
    await new Promise((r) => setTimeout(r, config.pollSeconds * 1000));
  }
}

main().catch((err) => {
  log(`Fatal: ${err.message}`);
  process.exit(1);
});
