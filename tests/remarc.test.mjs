import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, writeFileSync, mkdirSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {createRemarcSession, findRemarcMcp} from '../remarc.mjs';

// A stand-in for the Remarc MCP server: answers initialize, then remarc_create_session.
const fake = (toolReply) => {
  const dir = mkdtempSync(path.join(tmpdir(), 'remarc-'));
  const file = path.join(dir, 'index.js');
  writeFileSync(file, `
    let buf = '';
    process.stdin.on('data', c => { buf += c; for (let i; (i = buf.indexOf('\\n')) >= 0;) {
      const m = JSON.parse(buf.slice(0, i)); buf = buf.slice(i + 1);
      if (m.method === 'initialize') console.log(JSON.stringify({jsonrpc: '2.0', id: m.id, result: {}}));
      if (m.method === 'tools/call') console.log(JSON.stringify({jsonrpc: '2.0', id: m.id, result: ${JSON.stringify(toolReply)}, echo: m.params.arguments}));
    } });`);
  return file;
};

test('creates a Remarc session for a Claude session through the MCP server', async () => {
  const r = await createRemarcSession({name: 'mac', claudeSessionId: 'abc'}, {entry: fake({content: [{type: 'text', text: 'Created Remarc session "mac"'}]})});
  assert.deepEqual(r, {ok: true, text: 'Created Remarc session "mac"'});
});

test('a refused tool call is reported as an error', async () => {
  const r = await createRemarcSession({name: 'mac', claudeSessionId: 'abc'}, {entry: fake({isError: true, content: [{type: 'text', text: 'No Remarc app'}]})});
  assert.deepEqual(r, {ok: false, error: 'No Remarc app'});
});

test('no Remarc plugin installed: says so instead of failing', async () => {
  assert.equal(findRemarcMcp(mkdtempSync(path.join(tmpdir(), 'home-'))), null);
  const r = await createRemarcSession({name: 'mac', claudeSessionId: 'abc'}, {entry: null});
  assert.equal(r.ok, false);
  assert.match(r.error, /not installed/);
});

test('finds the newest installed version', () => {
  const home = mkdtempSync(path.join(tmpdir(), 'home-'));
  for (const v of ['0.9.0', '0.13.3', '0.10.1']) {
    const d = path.join(home, '.claude/plugins/cache/remarc/remarc', v, 'mcp/dist');
    mkdirSync(d, {recursive: true}); writeFileSync(path.join(d, 'index.js'), '');
  }
  assert.match(findRemarcMcp(home), /0\.13\.3/);
});
