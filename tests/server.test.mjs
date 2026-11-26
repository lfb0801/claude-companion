import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync, writeFileSync, appendFileSync, mkdtempSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import http from 'node:http';
import {createCompanion, plain} from '../companion.mjs';
import {createServer} from '../server.mjs';
import {createInbox} from '../inbox.mjs';
import {parseLine, Tail} from '../transcript.mjs';

const FIX = new URL('./fixtures/spike/', import.meta.url);
const hooks = name => readFileSync(new URL(`${name}.hooks.jsonl`, FIX), 'utf8').trim().split('\n').map(l => JSON.parse(l).payload);
const transcript = name => readFileSync(new URL(`${name}.transcript.jsonl`, FIX), 'utf8').trim().split('\n');
const tick = () => new Promise(r => setImmediate(r));

// A companion with one watching page; collects what the page would receive.
function watched() {
  const c = createCompanion({tail: false});
  const events = [];
  const off = c.subscribe(e => events.push(e));
  const promptOf = id => c.sessions.get(id)?.prompt;
  return {c, events, off, promptOf, of: type => events.filter(e => e.type === type)};
}

test('replaying session a: every PermissionRequest is held, and each reply matches how it was really answered', async () => {
  const {c, of, promptOf} = watched();
  const L = hooks('session-a');
  const sid = L[0].session_id;
  // How each PermissionRequest (by index in the recording) was answered during the spike.
  const script = {
    2: 'terminal-allow', 8: 'companion-allow', 13: 'terminal-deny', 16: 'companion-deny',
    25: 'companion-answer', 34: 'companion-deny', 38: 'companion-allow',
  };
  const replies = {};
  for (const [i, payload] of L.entries()) {
    const ac = new AbortController();
    const reply = c.ingest(payload, {signal: ac.signal}).then(r => { replies[i] = r; });
    await tick();
    const action = script[i];
    if (!action) { await reply; continue; }
    const p = promptOf(sid);
    assert.ok(p, `prompt held for event ${i}`);
    assert.equal(replies[i], undefined, `event ${i} is still waiting`);
    if (action === 'companion-allow') assert.equal(c.answer({session: sid, prompt: p.id, decision: 'allow'}), true);
    if (action === 'companion-deny') c.answer({session: sid, prompt: p.id, decision: 'deny'});
    if (action === 'companion-answer') c.answer({session: sid, prompt: p.id, decision: 'allow', answers: {'Which fruit do you prefer?': 'Blue'}});
    if (action === 'terminal-deny') ac.abort(); // Claude closes the hook connection
    // terminal-allow: the PostToolUse two events later settles it
    if (action !== 'terminal-allow') await reply;
  }
  await tick();
  assert.deepEqual(replies[2], {}, 'answered in the terminal: the held hook just gets an empty reply');
  assert.equal(replies[8].hookSpecificOutput.decision.behavior, 'allow');
  assert.deepEqual(replies[13], {}, 'interrupted: nothing to send');
  assert.equal(replies[16].hookSpecificOutput.decision.behavior, 'deny');
  assert.deepEqual(replies[25].hookSpecificOutput.decision.updatedInput.answers, {'Which fruit do you prefer?': 'Blue'});
  assert.equal(replies[25].hookSpecificOutput.decision.updatedInput.questions.length, 1, 'the original input is kept');
  assert.match(replies[34].hookSpecificOutput.decision.message, /plan/);
  assert.equal(replies[38].hookSpecificOutput.decision.behavior, 'allow');
  const kinds = of('prompt').filter(e => e.prompt.kind !== 'input').map(e => e.prompt.kind);
  assert.deepEqual(kinds, ['permission', 'permission', 'permission', 'permission', 'question', 'plan', 'permission']);
  const answered = of('answered').filter(e => e.decision !== 'none').map(e => `${e.source}:${e.decision}`);
  assert.deepEqual(answered, ['terminal:allow', 'companion:allow', 'terminal:deny', 'companion:deny', 'companion:allow', 'companion:deny', 'companion:allow']);
  assert.equal(of('prompt')[0].prompt.text, 'Bash: touch spike1.txt');
  assert.equal(of('prompt')[0].prompt.detail, 'Create empty file spike1.txt');
});

test('a PermissionRequest is paired with its PreToolUse, so a transcript rejection clears the right prompt', async () => {
  const {c, promptOf, of} = watched();
  const L = hooks('session-a');
  const sid = L[0].session_id;
  for (const p of L.slice(11, 14)) c.ingest(p);
  await tick();
  assert.equal(promptOf(sid).tool_use_id, L[12].tool_use_id);
  const rejected = transcript('session-a').find(l => l.includes('User rejected tool use'));
  c.readLine(sid, rejected);
  assert.equal(promptOf(sid), null);
  assert.equal(of('answered').at(-1).source, 'terminal');
  assert.equal(of('answered').at(-1).decision, 'deny');
});

test('with no page open a PermissionRequest is not held; closing the last page releases held prompts to the terminal', async () => {
  const c = createCompanion({tail: false});
  const L = hooks('session-a');
  assert.deepEqual(await c.ingest(L[2]), {}, 'no page: answered at once with no decision');
  const off = c.subscribe(() => {});
  let reply;
  c.ingest(L[8]).then(r => { reply = r; });
  await tick();
  assert.equal(reply, undefined);
  off();
  await tick();
  assert.deepEqual(reply, {});
});

test('only the first answer counts, and an answer for an old prompt is ignored', async () => {
  const {c, promptOf} = watched();
  const L = hooks('session-a');
  const sid = L[0].session_id;
  let reply;
  c.ingest(L[8]).then(r => { reply = r; });
  await tick();
  const p = promptOf(sid);
  assert.equal(c.answer({session: sid, prompt: 'not-it', decision: 'deny'}), false);
  assert.equal(c.answer({session: sid, prompt: p.id, decision: 'allow'}), true);
  assert.equal(c.answer({session: sid, prompt: p.id, decision: 'deny'}), false);
  await tick();
  assert.equal(reply.hookSpecificOutput.decision.behavior, 'allow');
});

test('a tool that approves a question without picking answers chooses the first option of each question', async () => {
  const {c, promptOf} = watched();
  const pr = hooks('session-a')[25];
  let reply;
  c.ingest(pr).then(r => { reply = r; });
  await tick();
  c.answer({session: pr.session_id, prompt: promptOf(pr.session_id).id, decision: 'allow', source: 'whip'});
  await tick();
  assert.deepEqual(reply.hookSpecificOutput.decision.updatedInput.answers, {'Which fruit do you prefer?': 'Apple'});
});

test('a deny with a note tells Claude why; a plan sent back says what to change', async () => {
  const {c, promptOf} = watched();
  const L = hooks('session-a');
  const sid = L[0].session_id;
  let reply;
  c.ingest(L[8]).then(r => { reply = r; });
  await tick();
  c.answer({session: sid, prompt: promptOf(sid).id, decision: 'deny', message: '  use the existing fixture instead  '});
  await tick();
  assert.equal(reply.hookSpecificOutput.decision.message, 'Denied from the companion. The user says: use the existing fixture instead');
  c.ingest(L[34]).then(r => { reply = r; });
  await tick();
  c.answer({session: sid, prompt: promptOf(sid).id, decision: 'deny', message: 'split step 2 in two'});
  await tick();
  assert.equal(reply.hookSpecificOutput.decision.message, 'The user wants changes to the plan: split step 2 in two');
});

test('a finished turn or idle notification raises nothing: prompts come from the Remarc session', async () => {
  const {c, promptOf} = watched();
  const L = hooks('session-a');
  const sid = L[0].session_id;
  await c.ingest(L[5]); // Stop
  assert.equal(promptOf(sid), null, 'no waiting-for-you card after a Stop');
  await c.ingest(L[42]); // idle_prompt
  assert.equal(promptOf(sid), null, 'and none from an idle notification');
});

test('the waiting-for-you text drops Markdown markup', () => {
  assert.equal(plain('You answered **SQLite** for the `db`. See [docs](https://x).\n## Next\n- item'), 'You answered SQLite for the db. See docs.\nNext\nitem');
});

test('sessions: created on first event, greeted on start, titled from the transcript, removed on end with held prompts released', async () => {
  const {c, of} = watched();
  const L = hooks('session-a');
  const sid = L[0].session_id;
  await c.ingest({...L[0], hook_event_name: 'SessionStart', source: 'startup'});
  assert.equal(of('session')[0].session.folder, 'spike-proj');
  assert.equal(of('greet')[0].id, sid);
  await c.ingest({...L[0], hook_event_name: 'SessionStart', source: 'compact'});
  assert.equal(of('greet').length, 1, 'no entrance after a compact');
  for (const line of transcript('session-a')) c.readLine(sid, line);
  assert.equal(c.sessions.get(sid).title, 'Spike1.txt file creation');
  const log = c.log(sid, 300);
  assert.ok(log.some(l => l.kind === 'user' && l.text.includes('touch spike1.txt')));
  assert.ok(log.some(l => l.kind === 'tool' && l.text.startsWith('● Bash(touch')));
  assert.ok(log.some(l => l.text.includes('Rejected in the terminal')));
  assert.ok(!log.some(l => l.text.includes('<system-reminder>')));
  let reply;
  c.ingest(L[8]).then(r => { reply = r; });
  await tick();
  await c.ingest({...L[0], hook_event_name: 'SessionEnd', reason: 'other'});
  await tick();
  assert.deepEqual(reply, {});
  assert.equal(c.sessions.size, 0);
  assert.equal(of('end')[0].id, sid);
});

test('companion-ask questions: answered, declined, interrupted in the session, or handed back when the page closes', async () => {
  const {c, promptOf, off} = watched();
  const [q] = readFileSync(new URL('companion-ask.asks.jsonl', FIX), 'utf8').trim().split('\n').map(l => JSON.parse(l));
  const sid = q.session_id;
  const a = c.ask(q);
  assert.equal(promptOf(sid).kind, 'question');
  assert.equal(promptOf(sid).questions[0].question, 'Which color do you prefer?');
  const waiting = c.askStatus(a.id, 5000);
  c.answer({session: sid, prompt: promptOf(sid).id, decision: 'allow', answers: {'Which color do you prefer?': 'Blue'}});
  assert.deepEqual(await waiting, {status: 'answered', answers: {'Which color do you prefer?': 'Blue'}});
  const n = c.ask(q);
  c.answer({session: sid, prompt: promptOf(sid).id, decision: 'allow', answers: {'Which color do you prefer?': 'Blue — note: darker'}, notes: {'Which color do you prefer?': 'darker'}});
  assert.deepEqual(await c.askStatus(n.id), {status: 'answered', answers: {'Which color do you prefer?': 'Blue — note: darker'}, annotations: {'Which color do you prefer?': {notes: 'darker'}}}, 'a note on a card goes out as an annotation');
  const b = c.ask(q);
  c.answer({session: sid, prompt: promptOf(sid).id, decision: 'deny'});
  assert.deepEqual(await c.askStatus(b.id), {status: 'declined'});
  const d = c.ask(q);
  c.cancelAsk(d.id);
  assert.equal(promptOf(sid), null);
  assert.deepEqual(await c.askStatus(d.id), {status: 'interrupted'});
  const e = c.ask(q);
  off();
  assert.deepEqual(await c.askStatus(e.id), {status: 'cancelled'});
  assert.equal(c.ask(q), null, 'no page open: the mod falls back to the terminal dialog');
});

test('transcript: parses every recorded transcript without throwing and finds titles and rejections', () => {
  const rejected = {}, titles = {};
  for (const name of ['session-a', 'session-b', 'session-c', 'session-d']) for (const line of transcript(name)) {
    const r = parseLine(line);
    if (r.title) titles[name] = r.title;
    rejected[name] = (rejected[name] || 0) + r.results.filter(x => x.rejected).length;
  }
  assert.equal(titles['session-a'], 'Spike1.txt file creation');
  assert.equal(rejected['session-a'], 1, 'the one terminal "No" in session a');
  assert.equal(rejected['session-b'], 0);
  assert.deepEqual(parseLine('not json'), {lines: [], results: []});
});

test('transcript tail reads appended lines once, across partial writes', async () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'tail-'));
  const file = path.join(dir, 't.jsonl');
  writeFileSync(file, '{"a":1}\n{"b"');
  const seen = [];
  const t = new Tail(file, l => seen.push(l), {interval: 1e6});
  await t.read();
  assert.deepEqual(seen, ['{"a":1}']);
  appendFileSync(file, ':2}\n');
  await t.read(); await t.read();
  assert.deepEqual(seen, ['{"a":1}', '{"b":2}']);
  t.stop();
});

test('HTTP: SSE snapshot and events, a held hook answered through /answer, and other websites are refused', async () => {
  const c = createCompanion({tail: false});
  const server = createServer({companion: c, port: 0});
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    assert.equal((await fetch(`${base}/ask`, {method: 'POST', body: '{}'})).status, 503, 'no page: questions go to the terminal');
    const ac = new AbortController();
    const sse = await fetch(`${base}/events`, {signal: ac.signal});
    const reader = sse.body.getReader();
    const events = [];
    const pump = (async () => { let buf = ''; for (;;) { const {value, done} = await reader.read(); if (done) return; buf += new TextDecoder().decode(value); let i; while ((i = buf.indexOf('\n\n')) >= 0) { const chunk = buf.slice(0, i); buf = buf.slice(i + 2); if (chunk.startsWith('data: ')) events.push(JSON.parse(chunk.slice(6))); } } })().catch(() => {});
    const until = async f => { for (let i = 0; i < 200 && !f(); i++) await new Promise(r => setTimeout(r, 5)); assert.ok(f()); };
    await until(() => events.some(e => e.type === 'snapshot'));
    const pr = hooks('session-a')[8];
    const held = fetch(`${base}/ingest`, {method: 'POST', headers: {'content-type': 'application/json'}, body: JSON.stringify(pr)}).then(r => r.json());
    await until(() => events.some(e => e.type === 'prompt'));
    const prompt = events.find(e => e.type === 'prompt');
    const evil = await fetch(`${base}/answer`, {method: 'POST', headers: {origin: 'https://evil.example'}, body: JSON.stringify({session: prompt.id, prompt: prompt.prompt.id, decision: 'allow'})});
    assert.equal(evil.status, 403);
    const ok = await fetch(`${base}/answer`, {method: 'POST', headers: {origin: base}, body: JSON.stringify({session: prompt.id, prompt: prompt.prompt.id, decision: 'allow'})});
    assert.deepEqual(await ok.json(), {ok: true});
    assert.equal((await held).hookSpecificOutput.decision.behavior, 'allow');
    await until(() => events.some(e => e.type === 'answered'));
    const page = await fetch(`${base}/`);
    assert.match(await page.text(), /Claude Code Companion/);
    assert.equal((await fetch(`${base}/%2e%2e/%2e%2e/etc/hosts`)).status, 404, 'no files outside the app folder');
    const rebound = await new Promise((resolve, reject) => http.request(`${base}/ingest`, {method: 'POST', headers: {host: 'evil.example'}}, r => { r.resume(); resolve(r.statusCode); }).on('error', reject).end('{}'));
    assert.equal(rebound, 403, 'DNS rebinding: a request for another host name is refused');
    ac.abort(); await pump;
  } finally { server.close(); server.closeAllConnections?.(); c.close(); }
});

test('Phone Whip queues reviewed text only for the explicitly selected Claude Code session', async () => {
  const companion = createCompanion({tail: false});
  const server = createServer({companion, port: 0});
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  try {
    const base = `http://127.0.0.1:${server.address().port}`;
    const endpoint = '/inbox/phone-dictation';
    const phone = {'x-companion-inbox': 'phone-whip'};
    const get = async (path, headers = {}) => (await fetch(base + path, {headers})).json();
    const post = (path, payload, headers = {}) => fetch(base + path, {
      method: 'POST', headers: {'content-type': 'application/json', ...headers}, body: JSON.stringify(payload),
    });
    const a = hooks('session-a')[0];
    const b = hooks('session-b')[0];
    await companion.ingest(b);
    const aInbox = '/inbox/' + a.session_id;
    const bInbox = '/inbox/' + b.session_id;
    const draft = {session: b.session_id, request: '00000000-0000-0000-0000-000000000001', text: 'Reviewed fixture 🎙️\nSecond line.'};

    assert.deepEqual(await get(endpoint), {sessions: []}, 'the phone lists sessions with the updated poll');
    assert.equal((await post(endpoint, draft)).status, 400, 'a session must check in first');
    const checkIn = (inbox, cwd, idle) => post(inbox + '/check-in', {cwd, idle}, phone);
    assert.equal((await checkIn(aInbox, 'relative/path', false)).status, 400);
    assert.deepEqual(await (await checkIn(aInbox, a.cwd, false)).json(), {armed: false},
      'a busy session can appear even if Companion missed SessionStart');
    await get(bInbox, phone);
    assert.deepEqual(new Set((await get(endpoint)).sessions.map(s => s.id)), new Set([a.session_id, b.session_id]));
    assert.equal((await post(endpoint, {...draft, session: undefined})).status, 400);
    assert.equal((await post(endpoint, {...draft, text: '   '})).status, 400);
    assert.equal((await post(endpoint, {...draft, text: 'é'.repeat(32769)})).status, 400);
    assert.equal((await post(endpoint, draft, {'content-type': 'text/plain'})).status, 415);
    assert.equal((await post(endpoint, draft)).status, 202);
    assert.equal((await post(endpoint, draft)).status, 202, 'retry confirms the same send');
    assert.equal((await post(endpoint, {...draft, session: a.session_id})).status, 400);
    assert.equal((await get(aInbox, phone)).prompt, undefined);
    assert.equal((await get(bInbox)).prompt, undefined, 'the old poll cannot take dictation');
    assert.deepEqual(await (await checkIn(bInbox, b.cwd, false)).json(), {armed: false},
      'a busy check-in must leave the message in the queue');

    const offered = {armed: true, prompt: draft.text, dictation: draft.request};
    assert.deepEqual(await (await checkIn(bInbox, b.cwd, true)).json(), offered);
    assert.equal((await get(bInbox, phone)).prompt, undefined, 'a second poll does not submit again');
    await post(aInbox + '/release', {dictation: draft.request, retry: true}, phone);
    assert.equal((await get(bInbox, phone)).prompt, undefined, 'only the selected session may release it');
    await post(bInbox + '/release', {dictation: draft.request, retry: true}, phone);
    assert.deepEqual(await get(bInbox, phone), offered, 'a known dropped submission is offered again');
    await post(bInbox + '/release', {dictation: draft.request, retry: false}, phone);
    assert.equal((await post(endpoint, draft)).status, 202);
    assert.equal((await get(bInbox, phone)).prompt, undefined, 'an accepted send stays idempotent');

    await post(endpoint, {...draft, request: '00000000-0000-0000-0000-000000000002'});
    await companion.ingest({...b, hook_event_name: 'SessionEnd'});
    assert.equal((await post(endpoint, draft)).status, 400);
    await companion.ingest(b);
    assert.equal((await get(bInbox, phone)).prompt, undefined, 'an ended session leaves no queued prompt behind');
    assert.equal((await post(endpoint, draft)).status, 400, 'a retry cannot enter a resumed session');
  } finally {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
    companion.close();
  }
});

test('phone sessions report whether they are working, waiting or idle', async () => {
  const companion = createCompanion();
  const inbox = createInbox({source: {name: 'test'}, companion});
  const hook = hooks('session-b')[0];
  await companion.ingest(hook);
  const state = () => inbox.phoneTargets().find(s => s.id === hook.session_id)?.state;
  inbox.checkInPhoneSession(hook.session_id);
  assert.equal(state(), 'idle', 'a session that never said it is mid-turn is idle');
  inbox.checkInPhoneSession(hook.session_id, false);
  assert.equal(state(), 'working');
  inbox.checkInPhoneSession(hook.session_id, true);
  assert.equal(state(), 'idle');
  companion.close();
});

test('urgent phone messages are handed to a working session flagged to interrupt, and others wait', async () => {
  const companion = createCompanion();
  const inbox = createInbox({source: {name: 'test'}, companion});
  const hook = hooks('session-b')[0];
  await companion.ingest(hook);
  const id = hook.session_id;
  inbox.checkInPhoneSession(id, false);
  const calm = '00000000-0000-0000-0000-0000000000a1', loud = '00000000-0000-0000-0000-0000000000a2';
  assert.deepEqual(inbox.enqueueDictation({session: id, request: calm, text: 'later'}), {queued: true});
  assert.deepEqual(inbox.nextUrgent(id), {armed: false}, 'an ordinary message waits for the end of the turn');
  assert.deepEqual(inbox.enqueueDictation({session: id, request: loud, text: 'now', urgent: true}), {queued: true});
  assert.deepEqual(inbox.nextUrgent(id), {armed: true, prompt: 'now', dictation: loud, interrupt: true});
  assert.deepEqual(inbox.nextUrgent(id), {armed: false}, 'offered once');
  companion.close();
});

test('a name you gave the session beats the generated title, and a later generated one does not replace it', async () => {
  const companion = createCompanion();
  const hook = hooks('session-b')[0];
  const dir = mkdtempSync(path.join(tmpdir(), 'titles-'));
  const file = path.join(dir, 'transcript.jsonl');
  writeFileSync(file, [
    {type: 'ai-title', aiTitle: 'Generated'},
    {type: 'custom-title', customTitle: 'Site chat'},
    {type: 'ai-title', aiTitle: 'Generated again'},
  ].map(l => JSON.stringify(l)).join('\n') + '\n');
  await companion.ingest({...hook, transcript_path: file});
  await new Promise(r => setTimeout(r, 700));
  assert.equal(companion.sessions.get(hook.session_id).title, 'Site chat');
  companion.close();
});

test('a fork nests under the session it came from, and a worktree session under its project\'s main session', async () => {
  const companion = createCompanion();
  const inbox = createInbox({source: {name: 'test'}, companion});
  const main = hooks('session-a')[0];
  const side = hooks('session-b')[0];
  const dir = mkdtempSync(path.join(tmpdir(), 'fork-'));
  const file = path.join(dir, 'transcript.jsonl');
  // A fork's transcript opens with the records of the session it was forked from.
  writeFileSync(file, [{type: 'queue-operation', sessionId: main.session_id}, {type: 'queue-operation', sessionId: side.session_id}]
    .map(l => JSON.stringify(l)).join('\n') + '\n');
  await companion.ingest(main);
  await companion.ingest({...side, transcript_path: file});
  await new Promise(r => setTimeout(r, 700));
  for (const s of [main, side]) inbox.checkInPhoneSession(s.session_id);
  const parents = () => Object.fromEntries(inbox.phoneTargets().map(s => [s.id, s.parent]));
  assert.equal(parents()[side.session_id], main.session_id);
  assert.equal(parents()[main.session_id], undefined);

  const tree = {session_id: 'worktree-session-1', cwd: path.join(main.cwd, '.claude/worktrees/feature'), hook_event_name: 'SessionStart'};
  await companion.ingest(tree);
  inbox.checkInPhoneSession(tree.session_id);
  assert.equal(parents()[tree.session_id], main.session_id);
  companion.close();
});

test('a side chat from the phone nests under its session, and a session that stops checking in drops off', async () => {
  const companion = createCompanion();
  const inbox = createInbox({source: {name: 'test'}, companion});
  const main = hooks('session-a')[0];
  const side = {...hooks('session-b')[0], session_id: '6f1c2c55-2b7a-4c8e-9d1e-0a6b2f3c4d5e'};
  const parent = '0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d';
  await companion.ingest({...main, session_id: parent});
  await companion.ingest(side);
  assert.deepEqual(inbox.adoptSideChat('not an id', parent), {error: 'Expected two session ids'});
  assert.deepEqual(inbox.adoptSideChat(side.session_id, parent), {ok: true});
  for (const id of [parent, side.session_id]) inbox.checkInPhoneSession(id);
  const parents = () => Object.fromEntries(inbox.phoneTargets().map(s => [s.id, s.parent]));
  assert.equal(parents()[side.session_id], parent);

  const realNow = Date.now;
  try {
    Date.now = () => realNow() + 61_000;
    inbox.checkInPhoneSession(parent);
    assert.deepEqual(Object.keys(parents()), [parent]);
  } finally { Date.now = realNow; }
  companion.close();
});
