// Phase 0 spike: records every hook payload and can hold PermissionRequest / answer AskUserQuestion.
// Usage: node spike/hook-spike.mjs <outDir>   (listens on 127.0.0.1:5199)
// Control:  POST /mode {"hold":seconds,"reply":"none"|"allow"|"deny","answer":"<label>"}
//           POST /release {"reply":"allow"|"deny"|"none"}  -> answers every held PermissionRequest now
import http from 'node:http';
import {appendFileSync, mkdirSync} from 'node:fs';
import path from 'node:path';

const out = path.resolve(process.argv[2] || 'spike-out');
mkdirSync(out, {recursive: true});
let mode = {hold: 0, reply: 'none', answer: null};
const held = new Set();
const asks = new Map(); let askSeq = 0;
const log = (...a) => console.log(new Date().toISOString().slice(11, 23), ...a);

const body = req => new Promise(r => { let s = ''; req.on('data', c => s += c); req.on('end', () => r(s)); });
const send = (res, obj) => { res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify(obj ?? {})); };

function permissionReply(reply, payload) {
  if (reply === 'allow' && payload?.tool_name === 'AskUserQuestion' && mode.answer) {
    const answers = Object.fromEntries((payload.tool_input.questions || []).map(q => [q.question, mode.answer]));
    return {hookSpecificOutput: {hookEventName: 'PermissionRequest', decision: {behavior: 'allow', updatedInput: {...payload.tool_input, answers}}}};
  }
  if (reply === 'allow' || reply === 'deny')
    return {hookSpecificOutput: {hookEventName: 'PermissionRequest', decision: {behavior: reply, ...(reply === 'deny' ? {message: 'Denied by spike'} : {})}}};
  return {};
}

http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  const raw = await body(req);
  if (url.pathname === '/mode') { mode = {...mode, ...JSON.parse(raw || '{}')}; log('mode', mode); return send(res, mode); }
  if (url.pathname === '/release') {
    const {reply = 'allow'} = JSON.parse(raw || '{}');
    for (const h of held) h(reply);
    log('released', held.size, reply); held.clear(); return send(res, {ok: true});
  }
  // companion-ask mod protocol
  if (url.pathname === '/ask' && req.method === 'POST') {
    const q = JSON.parse(raw); const id = String(++askSeq);
    asks.set(id, {...q, status: 'pending', waiters: []});
    appendFileSync(path.join(out, 'asks.jsonl'), JSON.stringify({received_at: new Date().toISOString(), id, ...q}) + '\n');
    log('<- ask', id, q.session_id?.slice(0, 8), q.questions.map(x => x.question).join(' | '));
    return send(res, {id});
  }
  const m = url.pathname.match(/^\/ask\/(\d+)(?:\/(answer|cancel))?$/);
  if (m) {
    const a = asks.get(m[1]);
    if (!a) { res.writeHead(404); return send(res, {error: 'unknown'}); }
    const settle = () => { const w = a.waiters; a.waiters = []; w.forEach(f => f()); };
    if (m[2] === 'answer') { // body: {answer:"label"} for every question, or {answers:{...}}
      const b = JSON.parse(raw || '{}');
      a.answers = b.answers || Object.fromEntries(a.questions.map(x => [x.question, b.answer]));
      a.status = 'answered'; log('-> ask', m[1], 'answered', JSON.stringify(a.answers)); settle(); return send(res, {ok: true});
    }
    if (m[2] === 'cancel') { a.status = 'cancelled'; log('!! ask', m[1], 'cancelled by session'); settle(); return send(res, {ok: true}); }
    if (a.status === 'pending') {
      const wait = Math.min(Number(url.searchParams.get('wait') || 0), 60) * 1000;
      await new Promise(r => { const t = setTimeout(r, wait); a.waiters.push(() => { clearTimeout(t); r(); }); });
    }
    const {status, answers} = a;
    return send(res, status === 'answered' ? {status, answers} : {status});
  }
  if (url.pathname !== '/hook') { res.writeHead(404); return res.end(); }

  const payload = JSON.parse(raw);
  const ev = payload.hook_event_name;
  const t0 = Date.now();
  appendFileSync(path.join(out, 'hooks.jsonl'), JSON.stringify({received_at: new Date().toISOString(), headers: req.headers, payload}) + '\n');
  log('<-', ev, payload.tool_name || payload.notification_type || '', payload.session_id?.slice(0, 8));

  let closed = false;
  res.on('close', () => { if (!res.writableEnded) { closed = true; log('!! connection closed by client', ev, `after ${Date.now() - t0}ms`); } });

  if (ev === 'PermissionRequest' && mode.hold > 0) {
    const reply = await new Promise(resolve => {
      const done = r => { held.delete(done); resolve(r); };
      held.add(done);
      setTimeout(() => done(mode.reply), mode.hold * 1000);
    });
    if (closed) return;
    const o = permissionReply(reply, payload);
    log('->', ev, JSON.stringify(o), `after ${Date.now() - t0}ms`);
    return send(res, o);
  }
  if (ev === 'PermissionRequest') return send(res, permissionReply(mode.reply, payload));

  if (ev === 'PreToolUse' && payload.tool_name === 'AskUserQuestion' && mode.askHold > 0) {
    await new Promise(r => setTimeout(r, mode.askHold * 1000));
    if (closed) return;
    log('->', ev, 'AskUserQuestion hold over', `after ${Date.now() - t0}ms`);
  }
  if (ev === 'PreToolUse' && payload.tool_name === 'AskUserQuestion' && mode.answer && mode.pre) {
    const answers = Object.fromEntries((payload.tool_input.questions || []).map(q => [q.question, mode.answer]));
    const o = {hookSpecificOutput: {hookEventName: 'PreToolUse', permissionDecision: 'allow', updatedInput: {...payload.tool_input, answers}}};
    log('->', ev, JSON.stringify(o));
    return send(res, o);
  }
  send(res, {});
}).listen(5199, '127.0.0.1', () => log('spike listening on :5199, writing', out));
