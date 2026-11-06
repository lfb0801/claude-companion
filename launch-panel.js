// Launch form: pick a recent project (from GET /projects) or type a folder, add an optional first prompt,
// POST /launch. Recent sessions of the picked project can be resumed from here too.
const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const ago=ms=>{const s=(Date.now()-ms)/1000;return s<90?'just now':s<5400?`${Math.round(s/60)} min ago`:s<129600?`${Math.round(s/3600)} h ago`:`${Math.round(s/86400)} d ago`;};
async function post(path,body){const r=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});const j=await r.json().catch(()=>({}));if(!r.ok)throw Error(j.error||`${path} failed (${r.status})`);return j;}

// "Resume here": POST /resume, and when the session still looks alive, ask before resending with force.
// Resolves to {session_id, tmux, cwd, existing?}, or null when the user cancels.
export async function resumeSession({session_id,cwd}){const r=await post('/resume',{session_id,cwd});if(!r.warning)return r;
 if(!confirm(r.tmux?`${r.warning}\n\nOpen its running terminal instead?`:`${r.warning}\n\nResume anyway?`))return null;
 return post('/resume',{session_id,cwd,force:true});}

export function createLaunchPanel(rootEl,{onLaunched}={}){
 const el=document.createElement('form');el.className='cc-launch';el.hidden=true;el.setAttribute('aria-label','Launch a Claude Code session');
 el.innerHTML=`<header><strong>Launch a session</strong><button type="button" class="cc-x" aria-label="Close">×</button></header>
<label>Project<select name="project"><option value="">Loading recent projects…</option></select></label>
<label class="cc-other" hidden>Folder (absolute path)<input name="cwd" placeholder="/Users/me/Projects/app" autocomplete="off" spellcheck="false"></label>
<label>First prompt <span class="cc-opt">(optional)</span><textarea name="prompt" rows="3" placeholder="What should Claude start on?"></textarea></label>
<div class="cc-row"><button type="submit" class="cc-go">Launch</button><span class="cc-msg" role="status"></span></div>
<div class="cc-recent" hidden><div class="cc-sub">Recent sessions here</div><ul></ul></div>`;
 rootEl.append(el);
 const $=s=>el.querySelector(s),sel=$('select'),other=$('.cc-other'),msg=$('.cc-msg');let projects=[],busy=false;
 const cwd=()=>sel.value==='other'?$('input[name=cwd]').value.trim():sel.value;
 const say=(t,err)=>{msg.textContent=t;msg.classList.toggle('cc-err',!!err);};
 const done=r=>{if(r){close();onLaunched?.(r);}};

 function renderRecent(){const p=projects.find(x=>x.cwd===sel.value),ul=$('.cc-recent ul');other.hidden=sel.value!=='other';$('.cc-recent').hidden=!p?.sessions?.length;
  ul.innerHTML=(p?.sessions||[]).map(s=>`<li><code>${esc(s.session_id.slice(0,8))}</code><span>${esc(ago(s.mtime))}</span><button type="button" data-resume="${esc(s.session_id)}">Resume here</button></li>`).join('');}
 async function load(){say('');try{projects=await (await fetch('/projects')).json();}catch{projects=[];say('Could not load recent projects',true);}
  const keep=sel.value;sel.innerHTML=projects.map(p=>`<option value="${esc(p.cwd)}" title="${esc(p.cwd)}">${esc(p.name)} · ${esc(ago(p.lastActive))}</option>`).join('')+'<option value="other">Other folder…</option>';
  if(keep&&[...sel.options].some(o=>o.value===keep))sel.value=keep;renderRecent();}

 sel.addEventListener('change',()=>{renderRecent();if(sel.value==='other')$('input[name=cwd]').focus();});
 $('.cc-x').addEventListener('click',()=>close());
 el.addEventListener('keydown',e=>{e.stopPropagation();if(e.key==='Escape')close();if(e.key==='Enter'&&(e.metaKey||e.ctrlKey))el.requestSubmit();});
 el.addEventListener('keyup',e=>e.stopPropagation());
 el.addEventListener('submit',async e=>{e.preventDefault();if(busy)return;const dir=cwd();if(!dir)return say('Pick a project folder',true);
  busy=true;say('Launching…');try{const prompt=$('textarea').value;const r=await post('/launch',{cwd:dir,...(prompt.trim()?{prompt}:{})});$('textarea').value='';say('');done({...r,cwd:dir});}catch(err){say(err.message,true);}finally{busy=false;}});
 el.addEventListener('click',async e=>{const id=e.target.closest?.('[data-resume]')?.dataset.resume;if(!id||busy)return;busy=true;say('Resuming…');
  try{const r=await resumeSession({session_id:id,cwd:sel.value});say('');done(r&&{...r,cwd:sel.value});}catch(err){say(err.message,true);}finally{busy=false;}});

 function open(){el.hidden=false;load();sel.focus();}
 function close(){el.hidden=true;}
 return {open,close,toggle:()=>el.hidden?open():close(),isOpen:()=>!el.hidden,el};}
