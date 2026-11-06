import {initial,reduce,TOOLS} from './state.js';
import {Theater} from './theater.js';
import {startDemo} from './demo.js';

const app=document.querySelector('#app');
const TOOL_INFO={whip:['W','Whip','approves what it hits'],cannon:['G','Cannon','Space or hold the mouse to fire, approves'],stamp:['D','Stamp','click a prompt to deny it'],intern:['H','Approval Intern','approves everything, in every session']};
const esc=s=>String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
app.innerHTML=`<main class="stage"><div class="stage-inner"><canvas aria-label="Claude Code companion stage"></canvas></div></main>
<nav class="toolbar" aria-label="Tools"><div id="tools"></div><button id="mute" class="tool"><span class="key">M</span><span>Sound</span></button></nav>
<button class="sound-unlock" id="unlock">Click anywhere to enable sound</button>`;

let state=initial();
const canvas=document.querySelector('canvas'),surface=canvas.parentElement;
const theater=new Theater(canvas,onAnswer);
// Phase 1: an answer only clears the prompt on the stage. Phase 3 sends it to the server.
const listeners=[];
function onAnswer(e){dispatch({type:'answered',id:e.owner,prompt:e.id});for(const f of listeners)f(e);}
function dispatch(action){state=reduce(state,action);render();}
function render(){theater.sync(state);document.querySelector('#tools').innerHTML=TOOLS.map(id=>{const [key,title,desc]=TOOL_INFO[id];return `<button class="tool ${state[id]?'active':''}" data-tool="${id}" aria-pressed="${state[id]}" title="${esc(desc)}"><span class="key">${key}</span><span>${esc(title)}</span></button>`;}).join('');const mute=document.querySelector('#mute');mute.classList.toggle('active',!state.muted);mute.setAttribute('aria-pressed',String(!state.muted));mute.lastElementChild.textContent=state.muted?'Muted':'Sound';}

function unlock(){theater.unlock();document.querySelector('#unlock')?.remove();}
const toPoint=e=>{const r=surface.getBoundingClientRect();return {x:(e.clientX-r.left)/r.width*1600,y:(e.clientY-r.top)/r.height*900};};
document.addEventListener('click',e=>{unlock();const b=e.target.closest?.('button');if(!b)return;if(b.dataset.tool)dispatch({type:b.dataset.tool});if(b.id==='mute')dispatch({type:'mute'});});
const keymap={w:'whip',g:'cannon',d:'stamp',h:'intern',m:'mute',enter:'crack'};
document.addEventListener('keydown',e=>{if(e.key==='Escape'){theater.firing=false;return;}if(e.target.matches?.('input,textarea')||e.metaKey||e.ctrlKey||e.altKey)return;const key=e.key.toLowerCase();if(key==='f'){e.preventDefault();if(document.fullscreenElement)document.exitFullscreen();else document.documentElement.requestFullscreen().catch(()=>{});return;}if(key===' '){e.preventDefault();unlock();theater.firing=true;return;}if(e.repeat)return;if(keymap[key]){e.preventDefault();unlock();dispatch({type:keymap[key]});}});
document.addEventListener('keyup',e=>{if(e.key===' ')theater.firing=false;});
window.addEventListener('blur',()=>{theater.firing=false;});
surface.addEventListener('pointermove',e=>{theater.mouse=toPoint(e);});
surface.addEventListener('pointerdown',e=>{unlock();theater.mouse=toPoint(e);if(state.stamp&&e.button===0)theater.stamp(theater.mouse);theater.firing=state.cannon&&!state.stamp;});
window.addEventListener('pointerup',()=>theater.firing=false);

render();
// ?demo shows fake sessions until Phase 2 brings real ones.
if(new URLSearchParams(location.search).has('demo'))startDemo(dispatch,listeners);
