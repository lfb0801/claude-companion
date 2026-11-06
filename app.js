import {initial,reduce,TOOLS} from './state.js';
import {Theater} from './theater.js';
import {startDemo} from './demo.js';

const app=document.querySelector('#app');
const TOOL_INFO={whip:['W','Whip','approves what it hits'],cannon:['G','Cannon','Space or hold the mouse to fire, approves'],stamp:['D','Stamp','click a prompt to deny it'],intern:['H','Approval Intern','approves everything, in every session']};
const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const demo=new URLSearchParams(location.search).has('demo');
app.innerHTML=`<main class="stage"><div class="stage-inner"><canvas aria-label="Claude Code companion stage"></canvas></div></main>
<nav class="toolbar" aria-label="Tools"><div id="tools"></div><button id="mute" class="tool"><span class="key">M</span><span>Sound</span></button><span class="link" id="link">connecting…</span></nav>
<aside class="log-panel" id="log" hidden><header><b id="log-title"></b><small id="log-sub"></small></header><ol id="log-lines"></ol></aside>
<div class="card-backdrop" id="card" hidden><section class="card" role="dialog" aria-modal="true" aria-labelledby="card-title"></section></div>
<button class="sound-unlock" id="unlock">Click anywhere to enable sound</button>`;

let state=initial();
const canvas=document.querySelector('canvas'),surface=canvas.parentElement;
const theater=new Theater(canvas,onAnswer);
const listeners=[];
const anyTool=()=>TOOLS.some(t=>state[t]);
const sessionOf=id=>state.sessions.find(s=>s.id===id);

// An answer clears the prompt at once, then goes to the server, which replies to Claude.
function onAnswer(e,answers){dispatch({type:'answered',id:e.owner,prompt:e.id});for(const f of listeners)f(e);if(!demo)fetch('/answer',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({session:e.owner,prompt:e.id,decision:e.decision,source:e.source,answers})}).catch(()=>{});}
function dispatch(action){state=reduce(state,action);render();}
function render(){theater.sync(state);document.querySelector('#tools').innerHTML=TOOLS.map(id=>{const [key,title,desc]=TOOL_INFO[id];return `<button class="tool ${state[id]?'active':''}" data-tool="${id}" aria-pressed="${state[id]}" title="${esc(desc)}"><span class="key">${key}</span><span>${esc(title)}</span></button>`;}).join('');const mute=document.querySelector('#mute');mute.classList.toggle('active',!state.muted);mute.setAttribute('aria-pressed',String(!state.muted));mute.lastElementChild.textContent=state.muted?'Muted':'Sound';if(card.id&&!sessionOf(card.id)?.prompt)closeCard();}

// Live sessions from the server.
function connect(){const link=document.querySelector('#link'),es=new EventSource('/events');
 es.onopen=()=>{link.textContent='live';link.className='link live';};
 es.onerror=()=>{link.textContent='server offline · retrying';link.className='link';};
 es.onmessage=({data})=>{const e=JSON.parse(data);
  if(e.type==='snapshot')dispatch({type:'sessions',sessions:e.sessions});
  else if(e.type==='session')dispatch({type:'session',session:e.session});
  else if(e.type==='end')dispatch({type:'end',id:e.id});
  else if(e.type==='prompt')dispatch({type:'prompt',id:e.id,prompt:e.prompt});
  else if(e.type==='answered')dispatch({type:'answered',id:e.id,prompt:e.prompt});
  else if(e.type==='greet'){const s=sessionOf(e.id);if(s)theater.greet(s);}
  else if(e.type==='log'&&hover.id===e.id)appendLog(e.lines);};}

// Prompt card: a click on a prompt with no tool armed. Allow / deny, pick answers, or approve a plan.
const card={id:null,prompt:null};
function openCard(a){const s=sessionOf(a.id),p=s?.prompt;if(!p)return;card.id=s.id;card.prompt=p.id;const el=document.querySelector('#card section');
 const head=`<header><small>${esc(s.folder)}${s.title?' · '+esc(s.title):''}</small><h2 id="card-title">${esc(p.text)}</h2>${p.detail?`<p>${esc(p.detail)}</p>`:''}</header>`;
 let main='',actions='';
 if(p.kind==='question'){main=(p.questions||[]).map((q,i)=>`<fieldset><legend>${esc(q.header||'')} ${esc(q.question)}</legend>${q.options.map((o,j)=>`<label><input type="${q.multiSelect?'checkbox':'radio'}" name="q${i}" value="${esc(o.label)}" ${j===0&&!q.multiSelect?'checked':''}><span><b>${esc(o.label)}</b>${o.description?`<small>${esc(o.description)}</small>`:''}</span></label>`).join('')}<label class="other"><input type="${q.multiSelect?'checkbox':'radio'}" name="q${i}" value="__other"><span><input type="text" data-other="${i}" placeholder="Other answer"></span></label></fieldset>`).join('');actions='<button data-act="deny">Decline</button><button class="primary" data-act="answer">Answer</button>';}
 else if(p.kind==='plan'){main=`<pre class="plan">${esc(p.plan||'')}</pre>`;actions='<button data-act="deny">Keep planning</button><button class="primary" data-act="allow">Approve plan</button>';}
 else if(p.kind==='input'){actions='<button class="primary" data-act="allow">Dismiss</button>';}
 else actions='<button data-act="deny">Deny</button><button class="primary" data-act="allow">Allow</button>';
 el.innerHTML=head+main+`<footer>${actions}</footer>`;document.querySelector('#card').hidden=false;el.querySelector('footer .primary')?.focus();}
function closeCard(){card.id=card.prompt=null;document.querySelector('#card').hidden=true;}
function cardAnswer(act){const s=sessionOf(card.id),a=theater.entities.get(card.id);if(!s?.prompt||s.prompt.id!==card.prompt)return closeCard();
 let answers;if(act==='answer'){answers={};s.prompt.questions.forEach((q,i)=>{const picked=[...document.querySelectorAll(`#card input[name="q${i}"]:checked`)].map(x=>x.value==='__other'?document.querySelector(`#card [data-other="${i}"]`).value.trim():x.value).filter(Boolean);answers[q.question]=picked.join(', ');});}
 const decision=act==='deny'?'deny':'allow';closeCard();
 if(a&&!a.answered){a.answered=true;a.decision=decision;}
 onAnswer({type:'answer',owner:s.id,id:s.prompt.id,decision,source:'card'},answers);}
document.querySelector('#card').addEventListener('click',e=>{if(e.target.id==='card')return closeCard();const b=e.target.closest('[data-act]');if(b)cardAnswer(b.dataset.act);if(e.target.matches('[data-other]'))e.target.closest('label').querySelector('input').checked=true;});

// Hover log: recent transcript lines beside the character, after a short dwell, only with no tool armed.
const hover={id:null,timer:0,leave:0};const logEl=document.querySelector('#log');
function showLog(a){hover.id=a.id;const s=sessionOf(a.id);document.querySelector('#log-title').textContent=s?.folder||'session';document.querySelector('#log-sub').textContent=s?.title||'';document.querySelector('#log-lines').innerHTML='';placeLog(a);logEl.hidden=false;
 if(demo)return appendLog([{kind:'assistant',text:'Demo session: no transcript.'}]);
 fetch(`/log/${encodeURIComponent(a.id)}?n=80`).then(r=>r.json()).then(r=>{if(hover.id===a.id)appendLog(r.lines);}).catch(()=>{});}
// Opens on the side with room: left of the prompt box (or the character), else right of the character.
function placeLog(a){const r=surface.getBoundingClientRect(),k=r.width/1600,W=Math.min(460,r.width*.45),left=(a.box?a.box.x:a.x-a.r)*k-12-W,right=(a.x+a.r)*k+12,x=left>=8?left:Math.min(right,r.width-W-8),H=Math.min(420,r.height-16),y=Math.max(8,Math.min(r.height-H-8,a.y*(r.height/900)-H/2));Object.assign(logEl.style,{left:`${r.left+x}px`,top:`${r.top+y}px`,width:`${W}px`,maxHeight:`${H}px`});}
function appendLog(lines){const ol=document.querySelector('#log-lines'),follow=ol.scrollTop+ol.clientHeight>=ol.scrollHeight-24;ol.insertAdjacentHTML('beforeend',lines.map(l=>`<li class="${esc(l.kind)}">${esc(l.text)}</li>`).join(''));while(ol.children.length>200)ol.firstElementChild.remove();if(follow)ol.scrollTop=ol.scrollHeight;}
function hideLog(){hover.id=null;logEl.hidden=true;clearTimeout(hover.timer);}
function hoverAt(p){clearTimeout(hover.leave);const a=anyTool()?null:theater.pick(p);if(a&&a.id===hover.id)return;clearTimeout(hover.timer);if(!a){if(hover.id)hover.leave=setTimeout(hideLog,250);return;}if(hover.id)hideLog();hover.timer=setTimeout(()=>{if(theater.entities.has(a.id))showLog(a);},350);}
logEl.addEventListener('pointerenter',()=>clearTimeout(hover.leave));logEl.addEventListener('pointerleave',()=>{hover.leave=setTimeout(hideLog,250);});

function unlock(){theater.unlock();document.querySelector('#unlock')?.remove();}
const toPoint=e=>{const r=surface.getBoundingClientRect();return {x:(e.clientX-r.left)/r.width*1600,y:(e.clientY-r.top)/r.height*900};};
document.addEventListener('click',e=>{unlock();const b=e.target.closest?.('button');if(!b)return;if(b.dataset.tool){dispatch({type:b.dataset.tool});if(anyTool())hideLog();}if(b.id==='mute')dispatch({type:'mute'});});
const keymap={w:'whip',g:'cannon',d:'stamp',h:'intern',m:'mute',enter:'crack'};
document.addEventListener('keydown',e=>{if(e.key==='Escape'){theater.firing=false;closeCard();hideLog();return;}if(!document.querySelector('#card').hidden)return;if(e.target.matches?.('input,textarea')||e.metaKey||e.ctrlKey||e.altKey)return;const key=e.key.toLowerCase();if(key==='f'){e.preventDefault();if(document.fullscreenElement)document.exitFullscreen();else document.documentElement.requestFullscreen().catch(()=>{});return;}if(key===' '){e.preventDefault();unlock();theater.firing=true;return;}if(e.repeat)return;if(keymap[key]){e.preventDefault();unlock();dispatch({type:keymap[key]});if(anyTool())hideLog();}});
document.addEventListener('keyup',e=>{if(e.key===' ')theater.firing=false;});
window.addEventListener('blur',()=>{theater.firing=false;});
surface.addEventListener('pointermove',e=>{theater.mouse=toPoint(e);hoverAt(theater.mouse);});
surface.addEventListener('pointerleave',()=>{hover.leave=setTimeout(hideLog,250);});
surface.addEventListener('pointerdown',e=>{unlock();theater.mouse=toPoint(e);if(!anyTool()&&e.button===0){const a=theater.pick(theater.mouse);if(a?.prompt&&!a.answered){hideLog();openCard(a);}return;}if(state.stamp&&e.button===0)theater.stamp(theater.mouse);theater.firing=state.cannon&&!state.stamp;});
window.addEventListener('pointerup',()=>theater.firing=false);

render();
// ?demo shows fake sessions instead of the server's (until real sessions are running).
if(demo){document.querySelector('#link').textContent='demo';startDemo(dispatch,listeners);}else connect();
