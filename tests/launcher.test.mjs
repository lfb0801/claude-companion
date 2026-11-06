import test, {after, before} from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import {spawn} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import {mkdtempSync, mkdirSync, writeFileSync, utimesSync, realpathSync, rmSync, existsSync} from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import WebSocket from 'ws';
import {createLauncher, encodeCwd, decodeProjectDir} from '../launcher.mjs';

// Every test uses a fake `claude` and a private tmux socket, so the user's own tmux sessions are never touched.
const here = path.dirname(fileURLToPath(import.meta.url));
const fakeClaude = path.join(here, 'fixtures/fake-claude.sh');
const socket = `cc-test-${process.pid}-${Math.random().toString(36).slice(2, 8)}`;
const tmp = realpathSync(mkdtempSync(path.join(os.tmpdir(), 'cc-launcher-')));
const projectsDir = path.join(tmp, 'projects'), sessionsDir = path.join(tmp, 'sessions'), work = path.join(tmp, 'work');
for (const d of [projectsDir, sessionsDir, work]) mkdirSync(d);
const launcher = createLauncher({claudeBin: fakeClaude, tmuxSocket: socket, projectsDir, sessionsDir});
const children = [];
let server, base;

const until = async (fn, ms = 5000) => { const end = Date.now() + ms; for (;;) { const v = await fn(); if (v) return v; if (Date.now() > end) throw Error('timed out'); await new Promise(r => setTimeout(r, 50)); } };
const pane = async name => (await launcher.tmux('capture-pane', '-p', '-J', '-t', `=${name}:`)).stdout;
const post = (p, body, headers = {'Content-Type': 'application/json'}) => fetch(base + p, {method: 'POST', headers, body: typeof body === 'string' ? body : JSON.stringify(body)});

before(async () => {
  server = http.createServer(async (req, res) => { if (await launcher.handle(req, res, new URL(req.url, 'http://localhost'))) return; res.writeHead(404); res.end(); });
  launcher.attach(server);
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${server.address().port}`;
});
after(async () => {
  launcher.close();
  await launcher.tmux('kill-server');
  for (const c of children) try { c.kill('SIGKILL'); } catch {}
  await new Promise(r => server.close(r));
  rmSync(tmp, {recursive: true, force: true});
  rmSync(path.join(process.env.TMUX_TMPDIR || '/tmp', `tmux-${process.getuid()}`, socket), {force: true});
});

test('GET /projects decodes ~/.claude/projects, preferring the transcript cwd, newest first', async () => {
  const one = path.join(work, 'my.proj-one'), two = path.join(work, 'plain_two');
  mkdirSync(one); mkdirSync(two);
  const id1 = randomUUID(), id2 = randomUUID(), now = Date.now() / 1000;
  // one: folder name is lossy ('.' and '-' both become '-'), the transcript carries the real cwd.
  const f1 = path.join(projectsDir, encodeCwd(one)); mkdirSync(f1);
  writeFileSync(path.join(f1, `${id1}.jsonl`), [{type: 'mode', mode: 'normal', sessionId: id1}, {type: 'user', cwd: one, sessionId: id1}].map(JSON.stringify).join('\n') + '\n');
  utimesSync(path.join(f1, `${id1}.jsonl`), now - 100, now - 100);
  // two: no cwd in the transcript, so the folder name is decoded against the file system.
  const f2 = path.join(projectsDir, encodeCwd(two)); mkdirSync(f2);
  writeFileSync(path.join(f2, `${id2}.jsonl`), JSON.stringify({type: 'mode', sessionId: id2}) + '\n');
  utimesSync(path.join(f2, `${id2}.jsonl`), now - 10, now - 10);
  // gone: the cwd no longer exists, so it is not offered.
  const f3 = path.join(projectsDir, encodeCwd(path.join(work, 'gone'))); mkdirSync(f3);
  writeFileSync(path.join(f3, `${randomUUID()}.jsonl`), JSON.stringify({cwd: path.join(work, 'gone')}) + '\n');

  const res = await fetch(base + '/projects');
  assert.equal(res.status, 200);
  const list = await res.json();
  assert.deepEqual(list.map(p => p.cwd), [two, one]);
  assert.equal(list[1].name, 'my.proj-one');
  assert.deepEqual(list[1].sessions.map(s => s.session_id), [id1]);
  assert.ok(list[0].lastActive > list[1].lastActive);
  assert.equal(await decodeProjectDir(encodeCwd(one)), one);
  assert.equal(await decodeProjectDir(encodeCwd(path.join(work, 'gone'))), null);
});

test('POST /launch starts claude --session-id in a cc-<id> tmux session in that cwd', async () => {
  const cwd = path.join(work, 'we ird;$(dir)'); mkdirSync(cwd);
  const marker = path.join(tmp, 'pwned');
  const prompt = `fix it $(touch ${marker}) \`touch ${marker}\`; touch ${marker} | cat & "q" 'q'`;
  const res = await post('/launch', {cwd, prompt});
  assert.equal(res.status, 200);
  const {session_id, tmux} = await res.json();
  assert.match(session_id, /^[0-9a-f-]{36}$/);
  assert.equal(tmux, `cc-${session_id}`);
  const out = await until(async () => { const p = await pane(tmux); return p.includes('FAKE-CLAUDE ready') && p; });
  assert.ok(out.includes(`FAKE-CLAUDE cwd=${cwd}`), out);
  assert.deepEqual([...out.matchAll(/ARG\[(.*)\]/g)].map(m => m[1]), ['--session-id', session_id, '--', prompt]);
  assert.equal(existsSync(marker), false, 'the prompt went through a shell');

  const listed = await (await fetch(base + '/tmux')).json();
  assert.ok(listed.some(s => s.tmux === tmux && s.session_id === session_id && s.cwd === cwd));
  // Without a prompt, claude gets no positional argument.
  const bare = await (await post('/launch', {cwd: work})).json();
  const out2 = await until(async () => { const p = await pane(bare.tmux); return p.includes('FAKE-CLAUDE ready') && p; });
  assert.deepEqual([...out2.matchAll(/ARG\[(.*)\]/g)].map(m => m[1]), ['--session-id', bare.session_id]);
});

test('input validation rejects bad cwd, ids, names, content types and origins', async () => {
  const file = path.join(work, 'a-file'); writeFileSync(file, '');
  for (const cwd of [undefined, 42, 'relative/dir', path.join(work, 'missing'), file, `${work}\0x`, `${work}; rm -rf /`])
    assert.equal((await post('/launch', {cwd})).status, 400, `cwd ${cwd}`);
  assert.equal((await post('/launch', {cwd: work, prompt: {x: 1}})).status, 400);
  assert.equal((await post('/launch', 'not json')).status, 400);
  assert.equal((await post('/launch', JSON.stringify({cwd: work}), {'Content-Type': 'text/plain'})).status, 415);
  assert.equal((await post('/launch', {cwd: work}, {'Content-Type': 'application/json', Origin: 'https://evil.example'})).status, 403);
  for (const session_id of ['abc', `${randomUUID()}; rm -rf /`, '../../etc', 7])
    assert.equal((await post('/resume', {session_id, cwd: work})).status, 400, `id ${session_id}`);
  assert.equal((await post('/resume', {session_id: randomUUID(), cwd: 'nope'})).status, 400);
  const status = path => new Promise(resolve => { const ws = new WebSocket(base.replace('http', 'ws') + path); ws.on('unexpected-response', (_, res) => resolve(res.statusCode)); ws.on('open', () => { ws.close(); resolve(101); }); ws.on('error', () => {}); });
  assert.equal(await status('/term/cc-..%2F..%2Fx'), 400);
  assert.equal(await status('/term/cc-$(id)'), 400);
  assert.equal(await status('/term/main'), 400);
  assert.equal(await status(`/term/cc-${randomUUID()}`), 404);
});

test('POST /resume warns while the session looks alive and proceeds with force', async () => {
  // A process whose argv mentions the id (e.g. `claude --resume <id>` in some terminal).
  const id = randomUUID();
  const proc = spawn(process.execPath, ['-e', 'setInterval(()=>{},1000)', id], {stdio: 'ignore'}); children.push(proc);
  await until(async () => (await launcher.stillAlive(id))?.pid === proc.pid);
  const warned = await (await post('/resume', {session_id: id, cwd: work})).json();
  assert.match(warned.warning, /still looks alive/);
  assert.equal(warned.tmux, undefined);
  assert.equal((await launcher.list()).some(s => s.session_id === id), false, 'resumed before the warning was confirmed');
  const forced = await (await post('/resume', {session_id: id, cwd: work, force: true})).json();
  assert.equal(forced.tmux, `cc-${id}`);
  const out = await until(async () => { const p = await pane(forced.tmux); return p.includes('FAKE-CLAUDE ready') && p; });
  assert.deepEqual([...out.matchAll(/ARG\[(.*)\]/g)].map(m => m[1]), ['--resume', id]);

  // A live Claude Code process registered in ~/.claude/sessions/<pid>.json.
  const id2 = randomUUID();
  writeFileSync(path.join(sessionsDir, `${process.pid}.json`), JSON.stringify({pid: process.pid, sessionId: id2}));
  assert.match((await (await post('/resume', {session_id: id2, cwd: work})).json()).warning, /Claude Code process/);

  // Still running in its companion tmux session: warn, and force opens that session instead of a second process.
  const again = await (await post('/resume', {session_id: id, cwd: work})).json();
  assert.equal(again.tmux, `cc-${id}`);
  assert.match(again.warning, /tmux session/);
  const reopened = await (await post('/resume', {session_id: id, cwd: work, force: true})).json();
  assert.deepEqual(reopened, {session_id: id, tmux: `cc-${id}`, cwd: work, existing: true});

  // Nothing alive: resumes straight away.
  const id3 = randomUUID();
  const fresh = await (await post('/resume', {session_id: id3, cwd: work})).json();
  assert.equal(fresh.tmux, `cc-${id3}`);
});

test('WebSocket /term/<name> streams the tmux pane, sends input and resizes', async () => {
  const {tmux} = await (await post('/launch', {cwd: work, prompt: 'hello'})).json();
  await until(async () => (await pane(tmux)).includes('FAKE-CLAUDE ready'));
  const ws = new WebSocket(`${base.replace('http', 'ws')}/term/${tmux}?cols=100&rows=30`);
  let got = '';
  ws.on('message', d => { got += d.toString(); });
  await new Promise((resolve, reject) => { ws.on('open', resolve); ws.on('error', reject); });
  await until(() => got.includes('FAKE-CLAUDE ready'));
  ws.send(JSON.stringify({t: 'i', d: 'typed-into-the-drawer\r'}));
  // cat echoes the line back, so it shows up twice in the pane.
  await until(async () => (await pane(tmux)).split('typed-into-the-drawer').length === 3);
  await until(() => got.includes('typed-into-the-drawer'));
  ws.send(JSON.stringify({t: 'r', cols: 90, rows: 25}));
  await until(async () => (await launcher.tmux('display-message', '-p', '-t', `=${tmux}:`, '#{window_width}x#{window_height}')).stdout.trim() .startsWith('90x'));
  ws.close();
  // Closing the drawer only detaches: the session keeps running.
  await until(async () => (await launcher.list()).find(s => s.tmux === tmux)?.attached === 0);
});
