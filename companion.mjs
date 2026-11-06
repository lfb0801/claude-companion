// The companion's brain: session state built from hook events and transcripts, and the prompts
// waiting for an answer. No HTTP here; server.mjs wires it up, tests drive it with fixtures.
//
// A prompt is answered once, by whoever is first: the companion (answer), the terminal (seen as
// PostToolUse, a rejected tool_result, or the hook connection closing), or nobody (session end).
import path from 'node:path';
import {randomUUID} from 'node:crypto';
import {parseLine, toolSummary, Tail} from './transcript.mjs';

const LOG_KEEP = 300;
const one = s => String(s ?? '').replace(/\s+/g, ' ').trim();
const cut = (s, n) => s.length > n ? s.slice(0, n - 1) + '…' : s;
// Claude's last message without Markdown markup, for a one-line box: **bold**, `code`, # headings, [links](url).
export const plain = s => String(s ?? '').replace(/```[\s\S]*?```/g, ' ').replace(/\[([^\]]*)\]\([^)]*\)/g, '$1').replace(/(\*\*|__|`)/g, '').replace(/^\s{0,3}#{1,6}\s+/gm, '').replace(/^\s*[-*]\s+/gm, '');
const firstOptions =questions => Object.fromEntries((questions || []).map(q => [q.question, q.options?.[0]?.label ?? '']));

function describe(tool, input = {}, cwd = '') {
  const rel = p => p && cwd && p.startsWith(cwd + '/') ? p.slice(cwd.length + 1) : p;
  if (tool === 'Bash') return {kind: 'permission', text: `Bash: ${cut(one(input.command), 140)}`, detail: one(input.description)};
  if (tool === 'AskUserQuestion') { const q = input.questions || []; return {kind: 'question', text: one(q[0]?.question), detail: q[0]?.options?.map(o => o.label).join(' · ') || '', questions: q}; }
  if (tool === 'ExitPlanMode') { const plan = String(input.plan || ''); return {kind: 'plan', text: one(plan.match(/^#+\s*(.+)$/m)?.[1] || 'Plan ready'), detail: 'Plan ready to execute', plan}; }
  if (input.file_path) return {kind: 'permission', text: `${tool} ${rel(input.file_path)}`, detail: ''};
  return {kind: 'permission', text: `${tool}: ${cut(one(toolSummary(tool, input)), 120)}`, detail: ''};
}

export function createCompanion({tail = true, tailInterval = 500} = {}) {
  const sessions = new Map(); // id -> {id, cwd, folder, title, transcript, prompt, pre: [], log: [], tail}
  const asks = new Map();     // ask id -> {session, status, answers, waiters}
  const listeners = new Set();
  const emit = e => { for (const f of listeners) f(e); };
  const view = s => ({id: s.id, cwd: s.cwd, folder: s.folder, title: s.title, prompt: s.prompt && publicPrompt(s.prompt)});
  const publicPrompt = p => ({id: p.id, kind: p.kind, text: p.text, detail: p.detail, tool: p.tool, ...(p.questions ? {questions: p.questions} : {}), ...(p.plan ? {plan: p.plan} : {})});

  function session(payload, {create = true} = {}) {
    let s = sessions.get(payload.session_id);
    if (!s && create) {
      s = {id: payload.session_id, cwd: payload.cwd || '', folder: path.basename(payload.cwd || '') || 'session', title: '', transcript: '', prompt: null, pre: [], log: []};
      sessions.set(s.id, s);
      emit({type: 'session', session: view(s)});
    }
    if (s && payload.transcript_path && !s.transcript) { s.transcript = payload.transcript_path; if (tail) startTail(s); }
    return s;
  }

  function startTail(s) {
    s.tail = new Tail(s.transcript, line => readLine(s, line), {interval: tailInterval});
    s.tail.start();
  }
  function readLine(s, line) {
    const r = parseLine(line);
    if (r.title && r.title !== s.title) { s.title = r.title; emit({type: 'session', session: view(s)}); }
    if (r.lines.length) { s.log.push(...r.lines); if (s.log.length > LOG_KEEP) s.log.splice(0, s.log.length - LOG_KEEP); emit({type: 'log', id: s.id, lines: r.lines}); }
    for (const res of r.results) if (s.prompt?.tool_use_id === res.tool_use_id) settle(s, 'terminal', res.rejected || res.error ? 'deny' : 'allow');
  }

  // Ends the current prompt: replies to a held hook / ask, tells the page. Returns false if already gone.
  function settle(s, source, decision, reply = {}) {
    const p = s.prompt;
    if (!p) return false;
    s.prompt = null;
    p.done?.(reply);
    emit({type: 'answered', id: s.id, prompt: p.id, source, decision});
    return true;
  }
  function setPrompt(s, p) {
    if (s.prompt) settle(s, 'replaced', 'none');
    s.prompt = {id: randomUUID(), ...p};
    emit({type: 'prompt', id: s.id, prompt: publicPrompt(s.prompt)});
    return s.prompt;
  }
  const idle = (s, text) => { if (!s.prompt) setPrompt(s, {kind: 'input', text: cut(one(plain(text)) || 'Waiting for your input', 160), detail: 'Waiting for your next prompt', tool: null}); };
  const clearIdle = (s, source = 'terminal') => { if (s.prompt?.kind === 'input') settle(s, source, 'none'); };

  // One hook event in, the hook's reply out. Most replies are immediate and empty; a
  // PermissionRequest is held until answered, unless no companion tab is open.
  function ingest(payload, {signal} = {}) {
    const ev = payload.hook_event_name;
    const s = session(payload);
    if (!s) return Promise.resolve({});
    switch (ev) {
      case 'SessionStart':
        if (payload.source === 'startup' || payload.source === 'resume') emit({type: 'greet', id: s.id});
        break;
      case 'UserPromptSubmit': clearIdle(s); break;
      case 'PreToolUse':
        clearIdle(s);
        s.pre.push({tool: payload.tool_name, key: JSON.stringify(payload.tool_input), id: payload.tool_use_id});
        if (s.pre.length > 20) s.pre.shift();
        break;
      case 'PostToolUse':
        if (s.prompt?.tool_use_id && s.prompt.tool_use_id === payload.tool_use_id) settle(s, 'terminal', 'allow');
        break;
      case 'Notification':
        if (payload.notification_type === 'idle_prompt') idle(s, payload.message);
        break;
      case 'Stop': idle(s, payload.last_assistant_message); break;
      case 'SessionEnd':
        settle(s, 'ended', 'none');
        s.tail?.stop(); sessions.delete(s.id);
        emit({type: 'end', id: s.id});
        break;
      case 'PermissionRequest': {
        if (!listeners.size) return Promise.resolve({}); // nobody watching: the terminal dialog handles it
        const key = JSON.stringify(payload.tool_input);
        const pre = [...s.pre].reverse().find(x => x.tool === payload.tool_name && x.key === key);
        return new Promise(resolve => {
          const p = setPrompt(s, {...describe(payload.tool_name, payload.tool_input, s.cwd), tool: payload.tool_name, input: payload.tool_input, tool_use_id: pre?.id, done: resolve});
          // Closed by Claude: denied in the terminal, interrupted, or the hook timed out.
          signal?.addEventListener('abort', () => { if (s.prompt === p) settle(s, 'terminal', 'deny'); }, {once: true});
        });
      }
    }
    return Promise.resolve({});
  }

  // The companion answers. decision: 'allow' | 'deny'; answers: {question: label} for questions;
  // notes: {question: text} added to a picked answer, passed on as AskUserQuestion annotations.
  // message: why you denied, or what should change in a plan; Claude reads it as the denial reason.
  function answer({session: id, prompt, decision, answers, notes, message: why, source = 'companion'}) {
    const s = sessions.get(id);
    const p = s?.prompt;
    if (!p || p.id !== prompt) return false;
    const annotations = notes && Object.keys(notes).length ? Object.fromEntries(Object.entries(notes).map(([q, n]) => [q, {notes: String(n)}])) : undefined;
    if (p.ask) {
      const a = asks.get(p.ask);
      if (decision === 'allow') { a.status = 'answered'; a.answers = answers || firstOptions(p.questions); a.annotations = annotations; } else a.status = 'declined';
      wake(a);
      return settle(s, source, decision);
    }
    if (p.kind === 'input') return settle(s, source, decision);
    let reply;
    if (decision === 'allow') {
      const updatedInput = p.kind === 'question' ? {...p.input, answers: answers || firstOptions(p.questions), ...(annotations ? {annotations} : {})} : undefined;
      reply = {hookSpecificOutput: {hookEventName: 'PermissionRequest', decision: {behavior: 'allow', ...(updatedInput ? {updatedInput} : {})}}};
    } else {
      const note = typeof why === 'string' && why.trim() ? why.trim().slice(0, 2000) : '';
      const message = p.kind === 'question' ? 'The user declined to answer from the companion.'
        : p.kind === 'plan' ? (note ? `The user wants changes to the plan: ${note}` : 'The user rejected the plan from the companion. Ask what to change.')
        : note ? `Denied from the companion. The user says: ${note}` : 'Denied from the companion.';
      reply = {hookSpecificOutput: {hookEventName: 'PermissionRequest', decision: {behavior: 'deny', message}}};
    }
    return settle(s, source, decision, reply);
  }

  // Questions from the companion-ask mod.
  function ask({session_id, cwd, transcript_path, tool_use_id, questions}) {
    if (!listeners.size || !session_id || !Array.isArray(questions)) return null;
    const s = session({session_id, cwd, transcript_path});
    const id = randomUUID();
    const a = {session: s.id, status: 'pending', answers: null, waiters: new Set()};
    asks.set(id, a);
    const d = describe('AskUserQuestion', {questions}, s.cwd);
    setPrompt(s, {...d, tool: 'AskUserQuestion', tool_use_id, ask: id, done: () => { if (a.status === 'pending') { a.status = 'cancelled'; wake(a); } }});
    return {id};
  }
  function wake(a) { for (const w of a.waiters) w(); a.waiters.clear(); }
  async function askStatus(id, waitMs = 0) {
    const a = asks.get(id);
    if (!a) return null;
    if (a.status === 'pending' && waitMs > 0) await new Promise(r => { const t = setTimeout(r, waitMs); a.waiters.add(() => { clearTimeout(t); r(); }); });
    const out = a.status === 'answered' ? {status: a.status, answers: a.answers, ...(a.annotations ? {annotations: a.annotations} : {})} : {status: a.status};
    if (a.status !== 'pending') setTimeout(() => asks.delete(id), 60_000).unref?.();
    return out;
  }
  function cancelAsk(id) {
    const a = asks.get(id);
    if (!a) return false;
    const s = sessions.get(a.session);
    if (a.status === 'pending') a.status = 'interrupted';
    if (s?.prompt?.ask === id) settle(s, 'terminal', 'none');
    return true;
  }

  // Page connections. When the last one goes, held prompts go back to the terminal.
  function subscribe(fn) {
    listeners.add(fn);
    fn({type: 'snapshot', sessions: [...sessions.values()].map(view)});
    return () => {
      listeners.delete(fn);
      if (!listeners.size) for (const s of sessions.values()) if (s.prompt && s.prompt.kind !== 'input') settle(s, 'released', 'none');
    };
  }

  const log = (id, n = 80) => sessions.get(id)?.log.slice(-n) ?? null;
  const close = () => { for (const s of sessions.values()) { settle(s, 'released', 'none'); s.tail?.stop(); } };
  return {ingest, answer, ask, askStatus, cancelAsk, subscribe, log, close, sessions, readLine: (id, line) => { const s = sessions.get(id); if (s) readLine(s, line); }};
}
