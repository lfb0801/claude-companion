import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, mkdirSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {createInbox, isMainSession} from '../inbox.mjs';
import {parseComments} from '../remarc.mjs';

const sessions = new Map([
  ['main', {id: 'main', cwd: '/work/app', folder: 'app'}],
  ['nested', {id: 'nested', cwd: '/work/app/.claude/worktrees/x', folder: 'x'}],
]);
const companion = {sessions};
const mainCheck = cwd => !cwd.includes('/.claude/worktrees/');
let comments = [];
const links = [];
const source = {
  name: 'Remarc',
  link: async ({name, claudeSessionId}) => { links.push(claudeSessionId); return {ok: true, text: `Linked ${name}`, link: {id: 'r1', name}}; },
  list: async () => ({ok: true, comments}),
};

test('only a main session gets a source session; worktree sessions are refused', async () => {
  const inbox = createInbox({source, companion, mainCheck});
  const r = await inbox.arm('nested');
  assert.equal(r.ok, false);
  assert.match(r.error, /worktree/);
  assert.deepEqual(links, []);
});

test('arming with no session links each main session once, never the nested ones', async () => {
  links.length = 0;
  const inbox = createInbox({source, companion, mainCheck});
  assert.equal((await inbox.arm()).ok, true);
  assert.equal((await inbox.arm()).ok, true);
  assert.deepEqual(links, ['main']);
  assert.equal(inbox.isArmed('nested'), false);
});

test('a comment is handed over once; released ones come back', async () => {
  const inbox = createInbox({source, companion, mainCheck});
  await inbox.arm('main');
  comments = [{id: 'abc12', status: 'open', ref: 'Button', request: 'Make it blue'}, {id: 'zzz99', status: 'resolved', ref: 'x', request: 'done'}];
  const a = await inbox.next('main');
  assert.deepEqual(a.ids, ['abc12']);
  assert.match(a.prompt, /Make it blue/);
  assert.match(a.prompt, /main session/);
  assert.equal((await inbox.next('main')).prompt, undefined);
  inbox.release('main', ['abc12']);
  assert.deepEqual((await inbox.next('main')).ids, ['abc12']);
  assert.deepEqual(await inbox.next('nested'), {armed: false});
});

test('a session in a git worktree is not main; a normal checkout is', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'main-'));
  mkdirSync(path.join(root, '.git'));
  const wt = mkdtempSync(path.join(tmpdir(), 'wt-'));
  writeFileSync(path.join(wt, '.git'), 'gitdir: elsewhere');
  assert.equal(isMainSession(root), true);
  assert.equal(isMainSession(wt), false);
  assert.equal(isMainSession(''), false);
});

test('parses remarc_list_comments text', () => {
  const text = '[text] [open] Hero title\n  ID: 6A1B2C3D-0000 (abc12)\n  Comment: Make it blue\n\n[screenshot] [resolved] Footer\n  ID: X (def34)\n  Comment: ok';
  assert.deepEqual(parseComments(text).map(c => [c.id, c.status, c.request]), [['abc12', 'open', 'Make it blue'], ['def34', 'resolved', 'ok']]);
});

test('batch mode holds comments until send, live delivers at once', async () => {
  comments = [{id: 'b1', status: 'open', ref: 'r', request: 'one'}];
  const inbox = createInbox({source, companion, mainCheck});
  assert.deepEqual(inbox.state(), {linked: false, mode: 'live', pending: 0});
  await inbox.arm('main');
  assert.equal(inbox.setMode('nope').ok, false);
  inbox.setMode('batch');
  let r = await inbox.next('main');
  assert.equal(r.prompt, undefined);
  assert.equal(r.pending, 1);
  assert.deepEqual(inbox.state(), {linked: true, mode: 'batch', pending: 1});
  inbox.send();
  r = await inbox.next('main');
  assert.deepEqual(r.ids, ['b1']);
  assert.equal((await inbox.next('main')).prompt, undefined, 'delivered once');
  comments = [{id: 'b2', status: 'open', ref: 'r', request: 'two'}];
  assert.equal((await inbox.next('main')).prompt, undefined, 'held again after the send');
  inbox.setMode('live');
  assert.deepEqual((await inbox.next('main')).ids, ['b2']);
});
