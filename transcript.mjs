// Reads Claude Code transcript JSONL (undocumented; shapes recorded in tests/fixtures/spike).
// parseLine turns one JSONL line into what the companion needs: a title, readable log lines,
// and tool results (to see prompts answered in the terminal).
import {open, stat} from 'node:fs/promises';

const one = s => String(s ?? '').replace(/\s+/g, ' ').trim();
const cut = (s, n) => s.length > n ? s.slice(0, n - 1) + '…' : s;

export function toolSummary(name, input = {}) {
  if (name === 'Bash') return input.command || '';
  if (input.file_path) return input.file_path;
  if (input.url) return input.url;
  if (input.pattern) return input.pattern;
  if (name === 'AskUserQuestion') return (input.questions || []).map(q => q.question).join(' · ');
  if (name === 'ExitPlanMode') return one(input.plan).slice(0, 120);
  return one(JSON.stringify(input)).slice(0, 120);
}

const resultText = c => typeof c === 'string' ? c : Array.isArray(c) ? c.map(b => b.text ?? '').join(' ') : '';

// Returns {title?, lines: [{kind, text}], results: [{tool_use_id, error, rejected}]}.
export function parseLine(raw) {
  const out = {lines: [], results: []};
  let d;
  try { d = JSON.parse(raw); } catch { return out; }
  if (d.type === 'ai-title' && d.aiTitle) out.title = d.aiTitle;
  if (d.isMeta || d.isSidechain) return out;
  const content = d.message?.content;
  if (d.type === 'user') {
    if (typeof content === 'string') {
      if (!content.startsWith('<')) out.lines.push({kind: 'user', text: '> ' + cut(one(content), 400)});
    } else for (const b of content || []) {
      if (b.type === 'tool_result') {
        const text = one(resultText(b.content));
        const rejected = d.toolUseResult === 'User rejected tool use';
        out.results.push({tool_use_id: b.tool_use_id, error: Boolean(b.is_error), rejected});
        out.lines.push({kind: b.is_error ? 'error' : 'result', text: '  ⎿ ' + cut(rejected ? 'Rejected in the terminal' : text || '(no output)', 200)});
      } else if (b.type === 'text' && !b.text.startsWith('<') && !b.text.startsWith('[Request interrupted')) {
        out.lines.push({kind: 'user', text: '> ' + cut(one(b.text), 400)});
      } else if (b.type === 'text' && b.text.startsWith('[Request interrupted')) {
        out.lines.push({kind: 'error', text: '  ⎿ Interrupted'});
      }
    }
  } else if (d.type === 'assistant') {
    for (const b of content || []) {
      if (b.type === 'text' && one(b.text)) out.lines.push({kind: 'assistant', text: cut(one(b.text), 600)});
      else if (b.type === 'tool_use') out.lines.push({kind: 'tool', text: `● ${b.name}(${cut(one(toolSummary(b.name, b.input)), 160)})`});
    }
  }
  return out;
}

// Follows one transcript file from the start, handing each complete line to onLine.
export class Tail {
  constructor(path, onLine, {interval = 500} = {}) { this.path = path; this.onLine = onLine; this.pos = 0; this.rest = ''; this.interval = interval; this.timer = null; this.busy = false; }
  start() { this.timer = setInterval(() => this.read(), this.interval); this.timer.unref?.(); return this.read(); }
  stop() { clearInterval(this.timer); this.timer = null; }
  async read() {
    if (this.busy) return; this.busy = true;
    try {
      const {size} = await stat(this.path);
      if (size < this.pos) { this.pos = 0; this.rest = ''; }
      if (size === this.pos) return;
      const fh = await open(this.path, 'r');
      try {
        const buf = Buffer.alloc(size - this.pos);
        await fh.read(buf, 0, buf.length, this.pos);
        this.pos = size;
        const parts = (this.rest + buf.toString('utf8')).split('\n');
        this.rest = parts.pop();
        for (const line of parts) if (line.trim()) this.onLine(line);
      } finally { await fh.close(); }
    } catch { /* file not there yet */ } finally { this.busy = false; }
  }
}
