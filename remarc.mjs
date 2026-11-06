// Talks to the Remarc plugin's own MCP server over stdio, the supported way in. Remarc's data file
// is never touched here. Remarc is one comment source for the inbox (inbox.mjs); the rest of the
// companion knows nothing about it, so other sources can replace it where Remarc does not run.
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

/** {ok, text} from one Remarc tool; {ok: false, error} if Remarc is missing or fails. */
export function callRemarc(tool, args, {entry = findRemarcMcp(), env = process.env, timeout = 15000} = {}) {
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
          send({id: 2, method: 'tools/call', params: {name: tool, arguments: args}});
        } else if (m.id === 2) {
          const text = (m.result?.content ?? []).map(c => c.text).filter(Boolean).join('\n');
          finish(m.error || m.result?.isError ? {ok: false, error: m.error?.message || text || 'Remarc refused'} : {ok: true, text});
        }
      }
    });
    send({id: 1, method: 'initialize', params: {protocolVersion: '2025-06-18', capabilities: {}, clientInfo: {name: 'claude-companion', version: '0.1.0'}}});
  });
}

export const createRemarcSession = ({name, claudeSessionId}, opts) =>
  callRemarc('remarc_create_session', {name, claude_session_id: claudeSessionId, harness: 'claudeCode'}, opts);

/** remarc_list_comments' text: one block per comment, each opening `[type] [status] reference`. */
export function parseComments(text) {
  return text.split(/\n(?=\[\w+\] \[\w+\] )/).flatMap(block => {
    const head = block.match(/^\[(\w+)\] \[(\w+)\] (.*)$/m);
    const id = block.match(/^\s+ID: \S+ \((\w+)\)/m)?.[1];
    if (!head || !id) return [];
    return [{id, status: head[2], ref: head[3], request: block.match(/^\s+Comment: (.*)$/m)?.[1]?.trim() ?? ''}];
  });
}

/** The inbox source for Remarc: {name, link, list}. */
export function remarcSource(opts) {
  return {
    name: 'Remarc',
    async link({name, claudeSessionId}) {
      const r = await createRemarcSession({name, claudeSessionId}, opts);
      if (!r.ok) return r;
      const made = r.text.match(/Created Remarc session "(.+)" \(id: ([0-9A-Fa-f-]+)\)/);
      return made ? {ok: true, text: r.text, link: {id: made[2], name: made[1]}} : {ok: false, error: r.text};
    },
    /** Comments of the linked Remarc session: [{id, status, ref, request}], or {ok: false, error}. */
    async list(link) {
      const r = await callRemarc('remarc_list_comments', {session_id: link.id}, opts);
      return r.ok ? {ok: true, comments: parseComments(r.text)} : r;
    },
  };
}
