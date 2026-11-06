// Turns a spike recording into sanitized test fixtures.
// Usage: node spike/make-fixtures.mjs <spike-out/hooks.jsonl> <outDir>
// Writes <outDir>/<name>.hooks.jsonl and <outDir>/<name>.transcript.jsonl per session.
// Drops system prompts, attachments, API request blobs and account ids; rewrites home/tmp paths.
import {readFileSync, writeFileSync, mkdirSync, existsSync} from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const [hooksFile, outDir] = process.argv.slice(2);
if (!hooksFile || !outDir) { console.error('usage: make-fixtures.mjs <hooks.jsonl> <outDir>'); process.exit(1); }
mkdirSync(outDir, {recursive: true});

const KEEP_TRANSCRIPT = new Set(['user', 'assistant', 'system', 'ai-title', 'last-prompt', 'permission-mode', 'mode']);
const DROP_KEYS = ['requestId', 'slug', 'gitBranch', 'version', 'entrypoint', 'userType'];
const home = os.homedir();

// Longest first, so the scratchpad dir is replaced before /private/tmp and $HOME.
const rewrites = [];
const scrub = s => rewrites.reduce((acc, [from, to]) => acc.split(from).join(to), s);
const clean = obj => JSON.parse(scrub(JSON.stringify(obj)));

const records = readFileSync(hooksFile, 'utf8').trim().split('\n').map(l => JSON.parse(l));
const bySession = new Map();
for (const r of records) {
  const p = r.payload;
  if (!bySession.has(p.session_id)) bySession.set(p.session_id, {cwd: p.cwd, transcript: p.transcript_path, hooks: []});
  bySession.get(p.session_id).hooks.push(r);
}

let n = 0;
for (const [sid, s] of bySession) {
  const name = `session-${String.fromCharCode(97 + n++)}`;
  const project = path.basename(s.cwd);
  rewrites.length = 0;
  const encoded = path.basename(path.dirname(s.transcript)); // e.g. -private-tmp-...-spike-proj
  const scratch = s.hooks.find(r => r.payload.scratchpad_dir)?.payload.scratchpad_dir;
  if (scratch) rewrites.push([scratch, `/tmp/claude/${project}/${sid}/scratchpad`]);
  rewrites.push([encoded, `-work-${project}`], [path.dirname(s.cwd), '/work'],[path.dirname(path.dirname(s.transcript)), '/home/me/.claude/projects'], [home, '/home/me']);

  const hooks = s.hooks.map(r => clean({received_at: r.received_at, user_agent: r.headers['user-agent'], payload: r.payload}));
  writeFileSync(path.join(outDir, `${name}.hooks.jsonl`), hooks.map(h => JSON.stringify(h)).join('\n') + '\n');

  let kept = 0;
  if (existsSync(s.transcript)) {
    const lines = readFileSync(s.transcript, 'utf8').trim().split('\n').map(l => JSON.parse(l))
      .filter(d => KEEP_TRANSCRIPT.has(d.type))
      .filter(d => !(d.type === 'user' && d.isMeta))
      .map(d => { for (const k of DROP_KEYS) delete d[k]; return clean(d); });
    kept = lines.length;
    writeFileSync(path.join(outDir, `${name}.transcript.jsonl`), lines.map(l => JSON.stringify(l)).join('\n') + '\n');
  }
  console.log(`${name}: ${sid} (${project}) hooks=${hooks.length} transcript=${kept}`);
}
