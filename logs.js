import {jobs,criticalFor} from './messages.js';
// Session logs. Nothing is stored or sent as text: an agent only carries counters and a short trail of [cycle,step,size] chunks (all serializable, mirrored by the 10Hz simulation message). Every window rebuilds the identical lines from (agent id, cycle, step, risky) with a seeded generator (nothing here may be nondeterministic).
export const LOG_CAP=400,TRAIL=20,EMIT=.15,READ_RATE=.08,DWELL=40,TICKER_ROWS=48,EVIDENCE=/destructive reset target/;
const CACHE=500,cache=new Map(),num=id=>id==='claude'?0:Number(id);
const hash=(...v)=>{let h=2166136261;for(const x of v){h=Math.imul(h^(x|0),16777619);h^=h>>>13;h=Math.imul(h,1274126177);}return (h^h>>>16)>>>0;};
const rng=s=>()=>{s=s+1831565813|0;let t=Math.imul(s^s>>>15,1|s);t=t+Math.imul(t^t>>>7,61|t)^t;return((t^t>>>14)>>>0)/4294967296;};
export const chunkSize=(id,cycle,step)=>20+hash(num(id),cycle,step,77)%41;
export const humLevel=n=>n>0?Math.min(.05,.008+.007*Math.log2(1+n)):0;
const titles=['running the checks','reading the results','investigating the failure','preparing a fix','waiting for review','applying the approved fix','verifying'],upbeat=['Tests started','Looks good so far','Found the cause','Fix drafted','Ready for review','Fix applied','Fix verified'],names=['handles empty input','retries on timeout','validates the schema','returns 200 for known ids','rejects malformed tokens','renders without crashing','keeps ordering stable','logs the request id','falls back to defaults','paginates large results'];
function build(id,cycle,step,risky){
 const n=chunkSize(id,cycle,step),j=jobs[num(id)%jobs.length],cr=criticalFor({id}),T=j.task,r=rng(hash(num(id),cycle,step,risky?1:0,5)),pick=a=>a[Math.floor(r()*a.length)],int=(a,b)=>a+Math.floor(r()*(b-a+1));
 const f=()=>pick([`src/${T}/index.ts`,`src/${T}/handler.ts`,`src/${T}/service.ts`,`src/${T}/utils.ts`,`lib/shared/config.ts`,`tests/${T}/${T}.spec.ts`,`src/${T}/types.d.ts`,`package.json`]),tn=()=>pick(names),hunk=()=>{const a=int(4,200),v=pick(['value','result','options','payload','client']);return [`@@ -${a},${int(3,9)} +${a},${int(3,12)} @@ ${pick(['export function','async function','class','const'])} ${T}${pick(['Handler','Service','Config','Client'])}`,`-  const ${v} = ${pick(['load()','read(input)','fetchItem(id)','parse(raw)'])};`,`+  const ${v} = ${pick(['await load()','await read(input)','await fetchItem(id)','validate(parse(raw))'])};`];};
 const general=[()=>`● Read ${f()} (${int(12,340)} lines)`,()=>`● Grep "${pick(['handler','config','retry','fixture','timeout','schema','token','cache'])}" → ${int(1,19)} matches in ${int(1,7)} files`,()=>`● Edit ${f()} (+${int(1,24)} −${int(0,11)})`,()=>`  … ${pick(['checking call sites','comparing against the previous run','narrowing the change','re-reading the assertion','looking for a smaller fix','confirming the types line up'])}`,()=>`[info] ${pick(['tsc','jest','eslint','vite'])} cache ${pick(['hit','miss'])} · ${int(3,880)} ms`,()=>`  ⏱ ${int(0,4)}.${int(10,99)}s`,()=>`● Bash ${pick(['git diff --stat','git status --short','ls src/'+T,'cat package.json | head -20','node --version'])}`,()=>`  → ${pick(['ok','done','no changes','exit 0'])} (${int(40,900)} ms)`];
 const theme=[
  [()=>`$ ${j.script}`,()=>`> factories@0.1.0 ${j.script.split(' ').pop()}`,()=>`RUNS  tests/${T}/${pick(['unit','api','ui'])}.spec.ts`,()=>`  ✓ ${T} › ${tn()} (${int(2,90)} ms)`],
  [()=>`  ✓ ${T} › ${tn()} (${int(2,90)} ms)`,()=>`  ✓ ${T} › ${tn()} (${int(2,90)} ms)`,()=>`PASS  tests/${T}/${pick(['unit','api','ui'])}.spec.ts`,()=>`Tests: ${int(12,60)} passed, ${int(12,60)} total`],
  [()=>`  ✕ ${T} › ${tn()} (${int(2,90)} ms)`,()=>`    ● ${j.failure}`,()=>`      at Object.<anonymous> (${f()}:${int(10,200)}:${int(3,40)})`,()=>`      expect(received).toEqual(expected)`],
  [()=>`● Edit ${f()} (+${int(1,24)} −${int(0,11)})`,hunk,()=>`  … ${j.repair.toLowerCase()}: ${pick(['reading','editing','re-running'])} ${f()}`],
  [()=>`  … waiting ${int(1,9)}m ${int(10,59)}s: ${j.permission.toLowerCase()}`,()=>`plan: ${pick(['apply the patch','run the script again','touch only the files listed'])}`,()=>`● Read ${f()} (${int(12,340)} lines)`],
  [()=>`✓ applied patch to ${f()}`,()=>`$ ${j.script}`,()=>`  ✓ ${T} › ${tn()} (${int(2,90)} ms)`,hunk],
  [()=>`  ✓ ${T} › ${tn()} (${int(2,90)} ms)`,()=>`PASS  tests/${T}/${pick(['unit','api','ui'])}.spec.ts`,()=>`Tests: ${int(21,63)} passed, ${int(21,63)} total`,()=>`  ⏱ ${int(0,4)}.${int(10,99)}s`]][step];
 const decoys=[()=>`warning: flaky test "${tn()}" failed once, retried (attempt 2/3) and passed`,()=>`npm WARN deprecated ${pick(['request@2.88.2','left-pad@1.3.0','querystring@0.2.0','glob@7.2.3'])}: package is no longer maintained`,()=>`warning: slow query ${int(240,900)} ms (threshold 200 ms): SELECT * FROM ${T}_events WHERE ...`,()=>`lint warning: ${f()}:${int(3,180)}:${int(1,30)} unused variable '${pick(['tmp','res','cb','opts'])}' (no-unused-vars)`,()=>`warning: ${pick(['Node','TypeScript'])} experimental feature in use: ${pick(['--experimental-vm-modules','import assertions'])}`,()=>`warning: test took ${int(3,9)}.${int(1,9)}s, over the 2s soft limit`];
 const out=[];while(out.length<n){const g=r()<.55?pick(theme)():pick(general)();Array.isArray(g)?out.push(...g):out.push(g);}out.length=n;
 const free=new Set(),slot=(lo,hi)=>{let p=int(lo,hi);while(free.has(p)||p<1||p>n-2)p=p>=hi?lo:p+1;free.add(p);return p;};
 out[0]=`── ${titles[step]} · ${T} ──`;out[n-1]=`summary: "${upbeat[step]}"`;
 if(cycle&&!step)out[1]=`↺ review feedback: changes requested (rework ${cycle}), restarting ${T}`,free.add(1);
 for(let k=int(1,3);k--;)out[slot(2,n-3)]=pick(decoys)();
 const say=(t,lo=2,hi=n-3)=>{out[slot(lo,hi)]=t;};
 if(risky){
  if(step===0)say(`note: repair scope widened beyond ${T}, now touching shared infrastructure`);
  if(step===1){say(`SKIP  integration/${T}.integration.spec.ts · staging environment unreachable · 0 of ${int(9,24)} integration tests ran`);say(`Tests: ${int(18,60)} passed, ${int(9,24)} skipped (integration)`);}
  if(step===2){say(`warning: no verified backup for ${cr.name} · last restore drill did not complete`);say(`warning: --skip-validation set, bypassing validation of the ${cr.name} schema`);}
  if(step===3){say(`warning: rollback plan untested · no snapshot taken, no down-migration available`);say(`warning: bypassing validation checks (--force)`);say(`warning: destructive reset target: ${cr.name} (primary, live traffic) · no verified backup · rollback untested`,Math.floor(n*.5),n-3);}
  if(step===4){say(`⏸ permission requested: ${cr.action}`);say(`agent note: "repair ready for review"`);}
  if(step>=5){say(`ERROR ${cr.result}`);say(`ERROR ${cr.impact}`);}
 }else{
  if(step===1)say(`integration suite: ${int(9,24)}/${int(9,24)} checks green (staging reachable)`);
  if(step===3)say(`✓ backup verified · restore drill passed ${int(1,6)} days ago`);
  if(step===4){say(`⏸ permission requested: ${j.permission}`);say(`✓ rollback tested: git revert applies cleanly`);}
 }
 return out;
}
export function chunk(id,cycle,step,risky){const key=`${num(id)}:${cycle}:${step}:${risky?1:0}`;let c=cache.get(key);if(c)return c;c=build(id,cycle,step,Boolean(risky));cache.set(key,c);if(cache.size>CACHE)for(const k of cache.keys()){cache.delete(k);if(cache.size<CACHE*.75)break;}return c;}
// Called by makeRequest at every status step: queues one chunk of lines on the agent and keeps only the last TRAIL chunks.
export function noteStep(agent,step,cycle){const n=chunkSize(agent.id,cycle,step);agent.trail=[...(agent.trail||[]),[cycle,step,n]];agent.queued=(agent.queued||0)+n;while(agent.trail.length>TRAIL)agent.dropped=(agent.dropped||0)+agent.trail.shift()[2];}
// Called every tick for an agent on stage: lines are emitted gradually (about EMIT per tick, faster with the swarm and when the backlog is large) so the log types itself out but is always written before the next step.
export function emitTick(agent,rate=1){const q=agent.queued||0,e=agent.emitF||0;if(e<q)agent.emitF=Math.min(q,e+EMIT*rate*(1+(q-e)/80));}
export const produced=agent=>Math.floor(agent.emitF||0);
export const readOf=agent=>Math.min(produced(agent),Math.floor(agent.readF||0));
// The visible log: the last `max` emitted lines (never more than LOG_CAP), their absolute index (first) and the line being typed right now.
export function logView(agent,max=LOG_CAP){const T=agent.trail||[],lim=produced(agent);max=Math.min(max,LOG_CAP);let s=agent.dropped||0;const parts=T.map(([c,st,n])=>{const p={c,st,n,s};s+=n;return p;}),out=[];let first=lim,typing=null;for(let k=parts.length-1;k>=0&&out.length<max;k--){const p=parts[k];if(p.s>lim)continue;const ls=chunk(agent.id,p.c,p.st,agent.risky);if(lim<p.s+p.n&&!typing)typing={text:ls[lim-p.s],frac:(agent.emitF||0)-lim};for(let i=Math.min(p.n,lim-p.s)-1;i>=0&&out.length<max;i--){out.push(ls[i]);first=p.s+i;}}return {lines:out.reverse(),first,total:lim,typing};}
// The one line that warns about a risky agent: its position in its own log, and how much of that log the player had actually read.
export function evidenceFor(agent){if(!agent.risky)return null;const id=agent.id,text=chunk(id,0,3,true).find(l=>EVIDENCE.test(l));if(!text)return null;let pos=chunk(id,0,3,true).indexOf(text);for(let s=0;s<3;s++)pos+=chunkSize(id,0,s);return {text,owner:id,pos,produced:produced(agent),read:readOf(agent)};}
