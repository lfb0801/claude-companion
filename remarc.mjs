// Starts a Remarc session for a Claude session by calling the Remarc plugin's own MCP server
// (remarc_create_session) over stdio, the supported way in. Remarc's data file is never touched here.
import {spawn} from 'node:child_process';
import {existsSync, readdirSync} from 'node:fs';
import {homedir} from 'node:os';
import path from 'node:path';

/** The newest installed Remarc plugin's MCP entry point, or null. */
export function findRemarcMcp(home = homedir()) {
  const base = path.join(home, '.claude', 'plugins', 'cache', 'remarc', 'remarc');
  if (!existsSync(base)) return null;
  const versions = readdirSync(base).filter(v => existsSync(path.join(base, v, 'mcp', 'dist', 'index.js')))
    .sort((a, b) => a.localeCompare(b, undefined, {numeric: true}));
  return versions.length ? path.join(base, versions.at(-1), 'mcp', 'dist', 'index.js') : null;
}

/** {ok, text} from remarc_create_session; {ok: false, error} if Remarc is missing or fails. */
export function createRemarcSession({name, claudeSessionId}, {entry = findRemarcMcp(), env = process.env, timeout = 15000} = {}) {
  return new Promise(resolve => {
    if (!entry) return resolve({ok: false, error: 'The Remarc plugin is not installed'});
    const child = spawn('node', [entry], {env, stdio: ['pipe', 'pipe', 'ignore']});
    let buf = '', done = false;
    const finish = r => { if (done) return; done = true; clearTimeout(timer); child.kill(); resolve(r); };
    const timer = setTimeout(() => finish({ok: false, error: 'Remarc did not answer in time'}), timeout);
    const send = m => child.stdin.write(JSON.stringify({jsonrpc: '2.0', ...m}) + '\n');
    child.on('error', e => finish({ok: false, error: String(e.message || e)}));
    child.on('exit', () => finish({ok: false, error: 'Remarc stopped before answering'}));
    child.stdout.on('data', chunk => {
      buf += chunk;
      for (let i; (i = buf.indexOf('\n')) >= 0;) {
        const line = buf.slice(0, i); buf = buf.slice(i + 1);
        let m; try { m = JSON.parse(line); } catch { continue; }
        if (m.id === 1) {
          send({method: 'notifications/initialized'});
          send({id: 2, method: 'tools/call', params: {name: 'remarc_create_session',
            arguments: {name, claude_session_id: claudeSessionId, harness: 'claudeCode'}}});
        } else if (m.id === 2) {
          const text = (m.result?.content ?? []).map(c => c.text).filter(Boolean).join('\n');
          finish(m.error || m.result?.isError ? {ok: false, error: m.error?.message || text || 'Remarc refused'} : {ok: true, text});
        }
      }
    });
    send({id: 1, method: 'initialize', params: {protocolVersion: '2025-06-18', capabilities: {}, clientInfo: {name: 'claude-companion', version: '0.1.0'}}});
  });
}
