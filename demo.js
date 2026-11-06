// Fake sessions for ?demo, so the stage and tools can be tried before the server feeds real sessions.
// Delete once Phase 2 lands.
const SESSIONS=[
 {id:'demo-1',folder:'claude-companion',title:'Rebuild the stage'},
 {id:'demo-2',folder:'billing-api',title:'Fix flaky webhook test'},
 {id:'demo-3',folder:'docs-site',title:'Update install guide'},
];
const PROMPTS=[
 {kind:'permission',text:'Bash: npm test',detail:'Run the test suite'},
 {kind:'permission',text:'Edit src/server.mjs',detail:'Add the /events endpoint'},
 {kind:'question',text:'Which port should the server use?',detail:'5173 · 8080 · Other'},
 {kind:'plan',text:'Plan: split theater.js into stage and tools',detail:'4 steps · ready to execute'},
 {kind:'input',text:'Done. Anything else?',detail:'Waiting for your next prompt'},
];
export function startDemo(dispatch,listeners){
 let n=0;const ask=id=>dispatch({type:'prompt',id,prompt:{id:`p${++n}`,...PROMPTS[n%PROMPTS.length]}});
 dispatch({type:'sessions',sessions:SESSIONS});
 SESSIONS.forEach((s,i)=>setTimeout(()=>ask(s.id),800+i*900));
 listeners.push(e=>setTimeout(()=>ask(e.owner),2500+Math.random()*3000));
}
