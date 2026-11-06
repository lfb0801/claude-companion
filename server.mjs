// Companion server: static files for the page, hook ingest, SSE to the page, answers back to Claude.
//   POST /ingest              hook events from the plugin (PermissionRequest is held until answered)
//   GET  /events              SSE: snapshot, session, end, greet, prompt, answered, log
//   POST /answer              {session, prompt, decision: 'allow'|'deny', answers?, source?}
//   GET  /log/:session?n=80   recent transcript lines for the hover panel
//   POST /ask, GET /ask/:id?wait=4, POST /ask/:id/cancel   the companion-ask mod (plugin/hooks/ask.ts)
import http from 'node:http';
import {readFile} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createCompanion} from './companion.mjs';
import {createRemarcSession} from './remarc.mjs';

const types = {'.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png', '.mp3': 'audio/mpeg'};
const MAX_BODY = 4 << 20;

export function createServer({companion = createCompanion(), launcher = null, root = path.dirname(fileURLToPath(import.meta.url)), port = 5173} = {}) {
  // Allowed Host / Origin values follow the port actually bound (tests listen on port 0).
  const bound = () => server.address()?.port ?? port;
  const hostOk = h => h === `localhost:${bound()}` || h === `127.0.0.1:${bound()}`;
  const originOk = o => o === `http://localhost:${bound()}` || o === `http://127.0.0.1:${bound()}`;
  const body = req => new Promise((resolve, reject) => {
    let s = '', n = 0;
    req.on('data', c => { n += c.length; if (n > MAX_BODY) { reject(Object.assign(Error('too large'), {status: 413})); req.destroy(); } else s += c; });
    req.on('end', () => { try { resolve(s ? JSON.parse(s) : {}); } catch { reject(Object.assign(Error('bad json'), {status: 400})); } });
    req.on('error', reject);
  });
  const json = (res, obj, status = 200) => { res.writeHead(status, {'Content-Type': 'application/json'}); res.end(JSON.stringify(obj ?? {})); };

  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    const p = url.pathname;
    try {
      // Only this machine's pages and Claude Code (which sends no Origin) may talk to the API.
      // This stops other websites in your browser from answering prompts or reading sessions.
      if (!hostOk(req.headers.host)) return json(res, {error: 'bad host'}, 403);
      if (req.headers.origin && !originOk(req.headers.origin)) return json(res, {error: 'bad origin'}, 403);
      // Launching sessions, recent projects, resume, xterm assets (launcher.mjs).
      if (launcher && await launcher.handle(req, res, url)) return;

      if (p === '/ingest' && req.method === 'POST') {
        const payload = await body(req);
        const ac = new AbortController();
        res.on('close', () => { if (!res.writableEnded) ac.abort(); });
        const reply = await companion.ingest(payload, {signal: ac.signal});
        if (!res.destroyed) json(res, reply);
        return;
      }
      if (p === '/events') {
        res.writeHead(200, {'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', Connection: 'keep-alive'});
        const send = e => res.write(`data: ${JSON.stringify(e)}\n\n`);
        const off = companion.subscribe(send);
        const ping = setInterval(() => res.write(': ping\n\n'), 15000);
        req.on('close', () => { clearInterval(ping); off(); });
        return;
      }
      if (p === '/answer' && req.method === 'POST') return json(res, {ok: companion.answer(await body(req))});
      if (p === '/remarc' && req.method === 'POST') {
        const {session, name} = await body(req);
        if (typeof session !== 'string' || !session) return json(res, {error: 'session required'}, 400);
        return json(res, await createRemarcSession({name: String(name || 'session'), claudeSessionId: session}));
      }
      if (p.startsWith('/log/')) return json(res, {lines: companion.log(decodeURIComponent(p.slice(5)), Math.min(300, Number(url.searchParams.get('n')) || 80)) ?? []});
      if (p === '/ask' && req.method === 'POST') {
        const r = companion.ask(await body(req));
        return r ? json(res, r) : json(res, {error: 'no companion open'}, 503);
      }
      const ask = p.match(/^\/ask\/([0-9a-f-]{36})(\/cancel)?$/);
      if (ask && ask[2] && req.method === 'POST') return json(res, {ok: companion.cancelAsk(ask[1])});
      if (ask) {
        const r = await companion.askStatus(ask[1], Math.min(10, Number(url.searchParams.get('wait')) || 0) * 1000);
        return r ? json(res, r) : json(res, {error: 'unknown'}, 404);
      }

      if (req.method !== 'GET') return json(res, {error: 'not found'}, 404);
      const file = path.resolve(root, '.' + (p === '/' ? '/index.html' : decodeURIComponent(p)));
      if (!file.startsWith(root + path.sep)) throw Object.assign(Error(), {status: 404});
      const data = await readFile(file);
      res.writeHead(200, {'Content-Type': types[path.extname(file)] || 'text/plain', 'Cache-Control': 'no-cache'});
      res.end(data);
    } catch (err) {
      if (!res.headersSent) json(res, {error: err.status ? err.message : 'not found'}, err.status || 404);
    }
  });
  return server;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const PORT = 5173;
  const {createLauncher} = await import('./launcher.mjs');
  // Only this page may launch sessions or open terminals: not other sites, not other local ports.
  const launcher = createLauncher({allowOrigin: o => !o || o === `http://localhost:${PORT}` || o === `http://127.0.0.1:${PORT}`});
  const server = createServer({launcher, port: PORT});
  launcher.attach(server);
  server.listen(PORT, '127.0.0.1', () => console.log(`Claude Code companion · http://localhost:${PORT}`));
}
