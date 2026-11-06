// Phase 4: launch and resume Claude Code sessions inside tmux (`cc-<session-id>`), list recent projects,
// and attach an xterm.js drawer to a tmux session over a WebSocket (/term/cc-<id>) through a pty.
// User strings never pass through a shell: every child process gets an argv array.
import {execFile} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import {statSync,accessSync,constants} from 'node:fs';
import {readdir,stat,open,readFile} from 'node:fs/promises';
import os from 'node:os';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
import pty from 'node-pty';
import {WebSocketServer} from 'ws';

export const NAME_RE=/^cc-[0-9a-f-]{36}$/,ID_RE=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
// Claude Code's project folder name: the cwd with every character outside [a-zA-Z0-9] replaced by '-'.
export const encodeCwd=p=>p.replace(/[^a-zA-Z0-9]/g,'-');
const HOME=os.homedir();
// xterm.js comes from the npm packages, served by the launcher so the static server needs no .mjs mime type.
const nm=path.join(path.dirname(fileURLToPath(import.meta.url)),'node_modules');
const VENDOR={'/vendor/xterm.mjs':['text/javascript',path.join(nm,'@xterm/xterm/lib/xterm.mjs')],'/vendor/xterm.css':['text/css',path.join(nm,'@xterm/xterm/css/xterm.css')],'/vendor/addon-fit.mjs':['text/javascript',path.join(nm,'@xterm/addon-fit/lib/addon-fit.mjs')]};
// The tmux server may have been started with a PATH that lacks claude, so resolve it to an absolute path once.
function which(bin){if(path.isAbsolute(bin))return bin;for(const d of [...(process.env.PATH||'').split(':'),path.join(HOME,'.local/bin'),'/opt/homebrew/bin','/usr/local/bin']){const f=path.join(d,bin);try{accessSync(f,constants.X_OK);return f;}catch{}}return bin;}
// A pty or tmux child must not think it is nested inside tmux or Claude Code.
const childEnv=()=>{const e={...process.env,TERM:'xterm-256color'};for(const k of ['TMUX','TMUX_PANE','CLAUDECODE','CLAUDE_CODE_ENTRYPOINT'])delete e[k];return e;};
const run=(bin,args,opts={})=>new Promise(resolve=>execFile(bin,args,{env:childEnv(),timeout:10000,...opts},(err,stdout,stderr)=>resolve({ok:!err,stdout:String(stdout),stderr:String(stderr),err})));
const isDir=p=>{try{return statSync(p).isDirectory();}catch{return false;}};
const alive=pid=>{try{process.kill(pid,0);return true;}catch(e){return e.code==='EPERM';}};
export function validCwd(cwd){return typeof cwd==='string'&&cwd.length<4096&&!cwd.includes('\0')&&path.isAbsolute(cwd)&&isDir(cwd);}

// First `cwd` field in the first 256 KB of a transcript.
async function transcriptCwd(file){let fh;try{fh=await open(file,'r');const buf=Buffer.alloc(262144);const {bytesRead}=await fh.read(buf,0,buf.length,0);for(const line of buf.subarray(0,bytesRead).toString('utf8').split('\n')){if(!line.includes('"cwd"'))continue;try{const c=JSON.parse(line).cwd;if(typeof c==='string'&&path.isAbsolute(c))return c;}catch{}}}catch{}finally{await fh?.close();}return null;}
// Lossy fallback: walk the file system, matching directory entries whose encoded name is a prefix of what is left.
export async function decodeProjectDir(name,root='/',depth=0){if(!name.startsWith('-')||depth>24)return null;const rest=name.slice(1);if(!rest)return root;let entries;try{entries=await readdir(root,{withFileTypes:true});}catch{return null;}
 const hits=entries.filter(e=>(e.isDirectory()||e.isSymbolicLink())&&(rest===encodeCwd(e.name)||rest.startsWith(encodeCwd(e.name)+'-'))).sort((a,b)=>b.name.length-a.name.length);
 for(const e of hits){const full=path.join(root,e.name),enc=encodeCwd(e.name);if(rest===enc)return isDir(full)?full:null;const r=await decodeProjectDir(rest.slice(enc.length),full,depth+1);if(r)return r;}return null;}

export function createLauncher({claudeBin=process.env.CLAUDE_BIN||'claude',tmuxBin='tmux',tmuxSocket=null,projectsDir=path.join(HOME,'.claude/projects'),sessionsDir=path.join(HOME,'.claude/sessions'),allowOrigin=o=>!o||/^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(o)}={}){
 const claude=which(claudeBin),tmuxPath=which(tmuxBin),sock=tmuxSocket?['-L',tmuxSocket]:[];
 const tmux=(...args)=>run(tmuxPath,[...sock,...args]);
 const hasSession=async name=>(await tmux('has-session','-t','='+name)).ok;

 async function projects(limit=40){let dirs;try{dirs=await readdir(projectsDir,{withFileTypes:true});}catch{return [];}
  const out=await Promise.all(dirs.filter(d=>d.isDirectory()).map(async d=>{const dir=path.join(projectsDir,d.name);let files;try{files=(await readdir(dir)).filter(f=>f.endsWith('.jsonl'));}catch{return null;}
   const ts=(await Promise.all(files.map(async f=>{try{return {file:path.join(dir,f),id:f.slice(0,-6),mtime:(await stat(path.join(dir,f))).mtimeMs};}catch{return null;}}))).filter(Boolean).sort((a,b)=>b.mtime-a.mtime);
   let cwd=null;for(const t of ts.slice(0,3))if((cwd=await transcriptCwd(t.file)))break;
   cwd??=await decodeProjectDir(d.name);if(!cwd||!isDir(cwd))return null;
   const lastActive=ts[0]?.mtime??(await stat(dir)).mtimeMs;
   return {cwd,name:path.basename(cwd)||cwd,folder:d.name,lastActive,sessions:ts.slice(0,5).filter(t=>ID_RE.test(t.id)).map(t=>({session_id:t.id,mtime:t.mtime}))};}));
  // Several folders can decode to one cwd; keep the most recent.
  const seen=new Set();return out.filter(Boolean).sort((a,b)=>b.lastActive-a.lastActive).filter(p=>!seen.has(p.cwd)&&seen.add(p.cwd)).slice(0,limit);}

 async function list(){const r=await tmux('list-sessions','-F','#{session_name}\t#{session_created}\t#{session_attached}\t#{pane_current_path}');if(!r.ok)return [];
  return r.stdout.split('\n').map(l=>l.split('\t')).filter(([n])=>NAME_RE.test(n)).map(([tmux,created,attached,cwd])=>({tmux,session_id:tmux.slice(3),created:+created*1000,attached:+attached,cwd}));}

 async function start(id,cwd,claudeArgs){const name='cc-'+id;
  const r=await tmux('new-session','-d','-s',name,'-c',path.resolve(cwd),'-x','200','-y','50','--',claude,...claudeArgs);
  if(!r.ok)throw Object.assign(Error(r.stderr.trim()||'tmux new-session failed'),{status:500});return {session_id:id,tmux:name,cwd};}

 // Why a session id still looks alive: its companion tmux session, a live Claude Code process registered in
 // ~/.claude/sessions/<pid>.json, or any process (outside tmux) whose argv mentions the id.
 async function stillAlive(id){if(await hasSession('cc-'+id))return {reason:`tmux session cc-${id} is still running`,tmux:'cc-'+id};
  try{for(const f of await readdir(sessionsDir)){if(!f.endsWith('.json'))continue;try{const j=JSON.parse(await readFile(path.join(sessionsDir,f),'utf8'));if(j.sessionId===id&&alive(j.pid))return {reason:`Claude Code process ${j.pid} is still running this session`,pid:j.pid};}catch{}}}catch{}
  const ps=await run('/bin/ps',['-Ao','pid=,args=']);for(const l of ps.stdout.split('\n')){const m=l.trim().match(/^(\d+)\s+(.*)$/);if(m&&m[2].includes(id)&&+m[1]!==process.pid&&!/\btmux\b/.test(m[2]))return {reason:`process ${m[1]} mentions this session: ${m[2].slice(0,120)}`,pid:+m[1]};}
  return null;}

 async function launch({cwd,prompt}={}){if(!validCwd(cwd))throw bad('cwd must be an existing absolute directory');
  if(prompt!=null&&(typeof prompt!=='string'||prompt.length>100000||prompt.includes('\0')))throw bad('prompt must be a string');
  const id=randomUUID();return start(id,cwd,['--session-id',id,...(prompt?.trim()?['--',prompt]:[])]);}

 async function resume({session_id,cwd,force}={}){if(typeof session_id!=='string'||!ID_RE.test(session_id))throw bad('session_id must be a uuid');if(!validCwd(cwd))throw bad('cwd must be an existing absolute directory');
  const live=await stillAlive(session_id);
  // Already running in our own tmux session: there is nothing to resume, open that one (never a second process).
  if(live?.tmux&&force)return {session_id,tmux:live.tmux,cwd,existing:true};
  if(live&&!force)return {warning:`This session still looks alive (${live.reason}). Resuming it here can leave two processes on one session.`,...(live.tmux?{tmux:live.tmux}:{})};
  return start(session_id,cwd,['--resume',session_id]);}

 const bad=msg=>Object.assign(Error(msg),{status:400});
 const send=(res,status,body)=>{res.writeHead(status,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify(body));};
 const body=req=>new Promise((resolve,reject)=>{let s='';req.setEncoding('utf8');req.on('data',c=>{s+=c;if(s.length>200000){reject(bad('body too large'));req.destroy();}});req.on('end',()=>{try{resolve(s?JSON.parse(s):{});}catch{reject(bad('invalid JSON'));}});req.on('error',reject);});

 async function handle(req,res,url){const p=url.pathname,m=req.method;
  if(m==='GET'&&VENDOR[p]){try{const [type,file]=VENDOR[p];res.writeHead(200,{'Content-Type':type,'Cache-Control':'max-age=3600'});res.end(await readFile(file));}catch{res.writeHead(404);res.end('Not found');}return true;}
  const route=m==='GET'&&(p==='/projects'||p==='/tmux')||m==='POST'&&(p==='/launch'||p==='/resume');if(!route)return false;
  try{if(!allowOrigin(req.headers.origin))return send(res,403,{error:'origin not allowed'}),true;
   if(p==='/projects')send(res,200,await projects());
   else if(p==='/tmux')send(res,200,await list());
   else{// JSON only: a cross-site form post cannot set this content type without a CORS preflight.
    if(!/^application\/json\b/.test(req.headers['content-type']||''))throw Object.assign(Error('Content-Type must be application/json'),{status:415});
    const b=await body(req);send(res,200,p==='/launch'?await launch(b):await resume(b));}}
  catch(e){send(res,e.status||500,{error:e.message});}return true;}

 // WebSocket /term/cc-<id>?cols=&rows=. Server → client: raw terminal output (text).
 // Client → server: JSON {t:'i',d:'keys'} input or {t:'r',cols,rows} resize.
 const wss=new WebSocketServer({noServer:true}),ptys=new Set();
 function attach(server){server.on('upgrade',async(req,socket,head)=>{const url=new URL(req.url,'http://localhost'),m=url.pathname.match(/^\/term\/([^/]+)$/);if(!m)return;
  const deny=code=>{socket.write(`HTTP/1.1 ${code}\r\nConnection: close\r\n\r\n`);socket.destroy();};
  if(!allowOrigin(req.headers.origin))return deny('403 Forbidden');const name=m[1];if(!NAME_RE.test(name))return deny('400 Bad Request');if(!(await hasSession(name)))return deny('404 Not Found');
  wss.handleUpgrade(req,socket,head,ws=>{const dim=(k,d,max)=>Math.min(Math.max(parseInt(url.searchParams.get(k))||d,2),max);
   const term=pty.spawn(tmuxPath,[...sock,'attach-session','-t','='+name],{name:'xterm-256color',cols:dim('cols',120,500),rows:dim('rows',30,200),cwd:HOME,env:childEnv()});ptys.add(term);
   term.onData(d=>{if(ws.readyState===1)ws.send(d);});
   term.onExit(()=>{ptys.delete(term);if(ws.readyState<2)ws.close(1000,'detached');});
   ws.on('message',raw=>{let msg;try{msg=JSON.parse(raw);}catch{return;}if(msg.t==='i'&&typeof msg.d==='string')term.write(msg.d);else if(msg.t==='r'){const c=+msg.cols,r=+msg.rows;if(c>1&&r>1&&c<=500&&r<=200)term.resize(c|0,r|0);}});
   ws.on('close',()=>{if(ptys.has(term)){ptys.delete(term);try{term.kill();}catch{}}});});});}
 function close(){for(const t of ptys)try{t.kill();}catch{}ptys.clear();for(const c of wss.clients)c.terminate();}

 return {handle,attach,close,projects,list,launch,resume,stillAlive,tmux};}
