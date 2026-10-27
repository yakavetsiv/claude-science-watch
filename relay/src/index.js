// Claude Science Watch relay. Holds the latest status the Mac helper
// published and a short queue of Allow/Deny answers from the watch.
//
//   PUT  /status         Mac   -> store the latest status JSON
//   GET  /status         watch -> read it
//   POST /reply          watch -> queue an answer {id, nonce, decision}
//   GET  /replies?after= Mac   -> answers with seq > after
//
// Every request needs `Authorization: Bearer <RELAY_TOKEN>` (a Worker secret).
// GET /status adds `relay.requests_today`: requests counted since midnight
// UTC, when Cloudflare's free daily request limit resets.
// One Durable Object holds everything, so reads always see the last write.

import { DurableObject } from 'cloudflare:workers';

const MAX_BODY = 64 * 1024;
const REPLY_TTL_MS = 60 * 60 * 1000;
const DAILY_LIMIT = 100000; // Workers free plan

export default {
  async fetch(request, env) {
    if (!authorized(request, env.RELAY_TOKEN)) return json({ error: 'unauthorized' }, 401);
    const stub = env.RELAY.get(env.RELAY.idFromName('default'));
    return stub.fetch(request);
  },
};

export class Relay extends DurableObject {
  async fetch(request) {
    const url = new URL(request.url);
    const route = `${request.method} ${url.pathname}`;
    const requestsToday = await this.countRequest();

    if (route === 'PUT /status') {
      const body = await readBody(request);
      if (body === null) return json({ error: 'body too large' }, 413);
      try {
        JSON.parse(body);
      } catch {
        return json({ error: 'status must be JSON' }, 400);
      }
      await this.ctx.storage.put('status', body);
      return new Response(null, { status: 204 });
    }

    if (route === 'GET /status') {
      const status = await this.ctx.storage.get('status');
      if (!status) return json({ error: 'no status yet' }, 404);
      return json({ ...JSON.parse(status), relay: { requests_today: requestsToday, daily_limit: DAILY_LIMIT } });
    }

    if (route === 'POST /reply') {
      const body = await readBody(request);
      let reply;
      try {
        reply = JSON.parse(body ?? '');
      } catch {
        return json({ error: 'reply must be JSON' }, 400);
      }
      const { id, nonce, decision } = reply ?? {};
      if (![id, nonce, decision].every((v) => typeof v === 'string' && v.length <= 200)) {
        return json({ error: 'reply needs id, nonce and decision' }, 400);
      }
      const seq = ((await this.ctx.storage.get('seq')) ?? 0) + 1;
      const now = Date.now();
      const replies = ((await this.ctx.storage.get('replies')) ?? [])
        .filter((r) => now - r.at < REPLY_TTL_MS)
        .slice(-49);
      replies.push({ seq, at: now, id, nonce, decision });
      await this.ctx.storage.put({ seq, replies });
      return json({ seq });
    }

    if (route === 'GET /replies') {
      // Without `after`, return only the current seq: a restarted helper must
      // not replay old answers.
      const seq = (await this.ctx.storage.get('seq')) ?? 0;
      const after = Number(url.searchParams.get('after'));
      if (!url.searchParams.has('after') || !Number.isFinite(after)) return json({ seq, replies: [] });
      const replies = ((await this.ctx.storage.get('replies')) ?? []).filter((r) => r.seq > after);
      return json({ seq, replies });
    }

    return json({ error: 'not found' }, 404);
  }

  async countRequest() {
    const day = new Date().toISOString().slice(0, 10);
    const counter = (await this.ctx.storage.get('requests')) ?? {};
    const count = counter.day === day ? counter.count + 1 : 1;
    await this.ctx.storage.put('requests', { day, count });
    return count;
  }
}

function authorized(request, token) {
  if (!token) return false;
  const given = request.headers.get('Authorization') ?? '';
  const expected = `Bearer ${token}`;
  if (given.length !== expected.length) return false;
  let diff = 0;
  for (let i = 0; i < given.length; i++) diff |= given.charCodeAt(i) ^ expected.charCodeAt(i);
  return diff === 0;
}

async function readBody(request) {
  const text = await request.text();
  return text.length > MAX_BODY ? null : text;
}

function json(data, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: { 'Content-Type': 'application/json' } });
}
