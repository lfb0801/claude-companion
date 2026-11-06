import {ideas} from './content.js';
import {isRisky} from './messages.js';
export const WAVES=4,WAVE_GAP=2100,WAVE_LEAD=90;
export const waveSize=i=>{let a=2,b=3;for(;i>0;i--)[a,b]=[b,a+b];return a;};
export const grade=n=>n<1?'A':n<3?'B':n<5?'C':'D';
const freshWave=()=>({on:false,started:false,n:0,total:WAVES});
export const initial=()=>({idea:'overview',focus:null,trail:[],claude:false,whip:false,cannon:false,stamp:false,reveal:false,punch:false,agents:[],gated:[],approved:0,seed:1,autoWhip:false,workApprovals:0,autoApproved:0,completed:0,spared:0,falseRejects:0,linesProduced:0,linesRead:0,won:false,summary:null,disaster:null,crack:0,fire:0,cleared:0,muted:false,lab:{ambiguity:30,volume:60},wave:freshWave(),exit:null});
function judge(s){if(s.won||s.disaster||s.completed<1||s.claude||s.agents.some(id=>!isRisky(id,s.cleared)||!s.gated.includes(id))||s.wave.started&&s.wave.n<s.wave.total)return;s.won=true;s.summary={completed:s.completed,spared:s.spared,holding:s.agents.length,falseRejects:s.falseRejects};}
export function reduce(state,action){const s=JSON.parse(JSON.stringify(state)),n=ideas[s.idea];switch(action.type){
 case 'focus':s.focus=action.id;s.punch=false;break;
 case 'jump':if(ideas[action.id]&&action.id!==s.idea){s.trail.push(s.idea);s.idea=action.id;s.reveal=false;s.punch=false;}break;
 case 'nav':{const dir=action.dir;if(dir==='home'){s.idea='overview';s.trail=[];}else if(dir==='up'){s.idea=n.parent||'overview';s.trail=[];}else if(dir==='down'){if(n.children?.length){s.trail.push(s.idea);s.idea=n.children[0];}}else{const list=n.siblings||ideas[n.parent]?.children||n.children||[];if(list.length){const i=list.indexOf(s.idea);s.idea=list[(i+(dir==='left'?-1:1)+list.length)%list.length];}}s.reveal=false;s.punch=false;break;}
 case 'claude':if(s.claude)s.exit={id:'claude',how:'rejected'};s.claude=!s.claude;s.punch=false;break;
 case 'autoWhip':case 'whip':case 'cannon':case 'stamp':case 'reveal':s[action.type]=!s[action.type];s.punch=false;break;
 case 'waves':{const w=s.wave;if(w.on)w.on=false;else if(w.n<w.total&&!s.disaster&&!s.won){w.on=true;w.started=true;}break;}
 case 'wave':{const w=s.wave;if(!w.on||w.n>=w.total||s.disaster||s.won)break;for(let i=0,c=waveSize(w.n);i<c;i++)s.agents.push(s.seed++);if(++w.n>=w.total)w.on=false;s.punch=false;break;}
 case 'add':case 'swarm':for(let i=0;i<(action.count??(action.type==='add'?1:6));i++)s.agents.push(s.seed++);s.punch=false;break;
 case 'remove':if(action.id==='claude'){if(s.claude)s.exit={id:'claude',how:'rejected'};s.claude=false;}else{if(s.agents.includes(action.id)){if(isRisky(action.id,s.cleared)&&!s.won)s.spared++;s.exit={id:action.id,how:'rejected'};}s.agents=s.agents.filter(id=>id!==action.id);}break;
 case 'hit':if(action.id==='claude'){if(!s.claude)break;s.claude=false;s.completed++;}else{if(!s.agents.includes(action.id))break;s.agents=s.agents.filter(id=>id!==action.id);if(!isRisky(action.id,s.cleared))s.completed++;}s.exit={id:action.id,how:'approved'};s.approved++;break;
 case 'complete':{const id=action.id;if(!(id==='claude'?s.claude:s.agents.includes(id))||isRisky(id,s.cleared))break;if(id==='claude')s.claude=false;else s.agents=s.agents.filter(x=>x!==id);s.completed++;s.exit={id,how:'finished'};break;}
 case 'reject':{const id=action.id;if(!(id==='claude'?s.claude:s.agents.includes(id)))break;if(isRisky(id,s.cleared)){s.agents=s.agents.filter(x=>x!==id);if(!s.won)s.spared++;s.exit={id,how:'denied'};}else if(!s.won)s.falseRejects++;s.punch=false;break;}
 case 'gate':if(s.agents.includes(action.id)&&isRisky(action.id,s.cleared)&&!s.gated.includes(action.id))s.gated.push(action.id);break;
 case 'crack':if(s.whip)s.crack++;break;
 case 'fire':if(s.cannon)s.fire++;break;
 case 'permissionApproved':s.workApprovals++;if(action.source==='auto')s.autoApproved++;break;
 case 'disaster':if(!s.disaster&&!s.won&&(action.owner==='claude'?s.claude:s.agents.includes(action.owner))){s.disaster={owner:action.owner,component:action.component,result:action.result,impact:action.impact,evidence:action.evidence||null};s.wave.on=false;}break;
 case 'logstats':if(!s.won&&!s.disaster){s.linesProduced=Math.max(0,action.produced|0);s.linesRead=Math.max(0,Math.min(action.read|0,s.linesProduced));}break;
 case 'mute':s.muted=!s.muted;break;
 case 'lab':s.lab[action.key]=action.value;break;
 case 'punch':case 'clear':case 'reset':s.claude=false;s.whip=false;s.cannon=false;s.stamp=false;s.agents=[];s.gated=[];s.reveal=false;s.punch=action.type==='punch';s.approved=0;s.disaster=null;s.autoWhip=false;s.workApprovals=0;s.autoApproved=0;s.completed=0;s.spared=0;s.falseRejects=0;s.linesProduced=0;s.linesRead=0;s.won=false;s.summary=null;s.seed=1;s.wave=freshWave();s.exit=null;s.cleared++;break;
 }judge(s);return s;}
