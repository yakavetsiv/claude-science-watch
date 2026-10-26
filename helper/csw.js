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
  pollSeconds: 120,
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

async function daemonRunning(config) {
  try {
    await fetch(`${config.daemonUrl}/`, { method: 'HEAD', signal: AbortSignal.timeout(3000) });
    return true;
  } catch {
    return false;
  }
}

// ---------- ntfy ----------

async function push(config, { title, message, priority = 3, tags = [] }) {
  const res = await fetch(config.ntfyServer, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ topic: config.ntfyTopic, title, message, priority, tags }),
  });
  if (!res.ok) throw new Error(`ntfy returned HTTP ${res.status}`);
  log(`Pushed: ${title} — ${message}`);
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

  for (const project of dash.projects ?? []) {
    for (const bench of project.needs_input_benches ?? []) {
      if (!bench?.id) continue;
      nowNeedsInput.add(bench.id);
      if (!prevNeedsInput.has(bench.id) && notify && config.notifyNeedsInput) {
        await push(config, {
          title: 'Claude Science needs your input',
          message: sessionLine(config, project, bench),
          priority: 4,
          tags: ['raised_hand'],
        });
      }
    }
    for (const bench of project.recently_completed ?? []) {
      if (!bench?.id) continue;
      const key = `${bench.id}@${bench.completed_at ?? ''}`;
      if (seenCompleted.has(key)) continue;
      seenCompleted.add(key);
      if (notify && config.notifyCompleted) {
        await push(config, {
          title: 'Claude Science session finished',
          message: sessionLine(config, project, bench),
          priority: 3,
          tags: ['white_check_mark'],
        });
      }
    }
  }

  state.needsInput = [...nowNeedsInput];
  state.seenCompleted = [...seenCompleted].slice(-500);
  return {
    processing: dash.total_processing ?? 0,
    needsInput: dash.total_needs_input ?? 0,
  };
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
  // A read-only poll (--status) must not mark anything as already notified.
  if (notify) {
    state.initialized = true;
    writeJson(STATE_PATH, state);
  }

  const status = {
    updated_at: new Date().toISOString(),
    limits: (usage.limits ?? []).map((l) => ({
      kind: l.kind,
      label: limitLabel(l),
      percent: l.percent,
      severity: l.severity,
      resets_at: l.resets_at,
      is_active: l.is_active,
    })),
    sessions,
  };
  writeJson(STATUS_PATH, status);
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
