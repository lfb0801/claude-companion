// Bottom drawer with an xterm.js terminal attached to a companion tmux session over /term/<tmux>.
// xterm.js and its fit addon come from the npm packages, served by launcher.mjs under /vendor/.
// Protocol: server → client raw output; client → server JSON {t:'i',d} input and {t:'r',cols,rows} resize.
let xtermLoad=null;
const loadXterm=()=>xtermLoad??=(async()=>{if(!document.querySelector('link[data-xterm]')){const l=document.createElement('link');l.rel='stylesheet';l.href='/vendor/xterm.css';l.dataset.xterm='';document.head.append(l);}
 const [{Terminal},{FitAddon}]=await Promise.all([import('/vendor/xterm.mjs'),import('/vendor/addon-fit.mjs')]);return {Terminal,FitAddon};})();
const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

export function createDrawer(rootEl,{onClose}={}){
 const el=document.createElement('section');el.className='cc-drawer';el.hidden=true;el.setAttribute('aria-label','Session terminal');
 el.innerHTML=`<header class="cc-drawer-head"><strong class="cc-drawer-title"></strong><code class="cc-drawer-cmd" title="Attach from any terminal"></code><button class="cc-drawer-close" type="button" aria-label="Close terminal">Close</button></header><div class="cc-drawer-term"></div>`;
 rootEl.append(el);
 const box=el.querySelector('.cc-drawer-term');let cur=null,token=0;
 el.querySelector('.cc-drawer-close').addEventListener('click',()=>close());
 // Keys typed into the terminal must not reach the stage's shortcuts (W, G, D, H, M, space...).
 for(const t of ['keydown','keyup'])el.addEventListener(t,e=>e.stopPropagation());

 async function open({tmux,title}={}){if(!/^cc-[0-9a-f-]{36}$/.test(tmux||''))throw Error('bad tmux session name');
  if(cur?.tmux===tmux){el.hidden=false;cur.term.focus();return;}
  teardown();const my=++token;
  el.querySelector('.cc-drawer-title').textContent=title||tmux;el.querySelector('.cc-drawer-cmd').innerHTML=`tmux attach -t ${esc(tmux)}`;el.hidden=false;
  const {Terminal,FitAddon}=await loadXterm();if(my!==token)return;
  const term=new Terminal({cursorBlink:true,fontSize:13,fontFamily:'ui-monospace,SFMono-Regular,Menlo,monospace',theme:{background:'#0b0c09',foreground:'#eeeedd',cursor:'#d7ff62',selectionBackground:'#d7ff6244'},scrollback:5000});
  const fit=new FitAddon();term.loadAddon(fit);term.open(box);try{fit.fit();}catch{}
  const ws=new WebSocket(`${location.protocol==='https:'?'wss':'ws'}://${location.host}/term/${tmux}?cols=${term.cols}&rows=${term.rows}`);
  const send=m=>{if(ws.readyState===1)ws.send(JSON.stringify(m));};
  ws.onmessage=e=>term.write(typeof e.data==='string'?e.data:new Uint8Array(e.data));
  ws.onclose=e=>{if(cur?.ws===ws)term.write(`\r\n\x1b[2m[${e.code===1000?'detached':'connection closed'}${e.reason&&e.reason!=='detached'?': '+e.reason:''}]\x1b[0m\r\n`);};
  term.onData(d=>send({t:'i',d}));
  term.onResize(({cols,rows})=>send({t:'r',cols,rows}));
  const ro=new ResizeObserver(()=>{try{fit.fit();}catch{}});ro.observe(box);
  cur={tmux,term,ws,ro};term.focus();}

 function teardown(){if(!cur)return;const {term,ws,ro}=cur;cur=null;ro.disconnect();try{ws.close();}catch{}term.dispose();box.textContent='';}
 // Closing only detaches the drawer: the tmux session (and claude) keeps running.
 function close(){token++;const was=cur?.tmux;teardown();el.hidden=true;if(was!==undefined)onClose?.(was);}
 return {open,close,isOpen:()=>!el.hidden,current:()=>cur?.tmux??null};}
