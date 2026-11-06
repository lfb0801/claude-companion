import {noteStep} from './logs.js';
export const jobs=[
 {task:'checkout',script:'npm run test:checkout',failure:'Payment mock returned undefined',repair:'Updating the payment fixture',permission:'Allow updating the test fixture?'},
 {task:'authentication',script:'npm run test:auth',failure:'Token refresh assertion failed',repair:'Tracing the refresh-token handler',permission:'Allow editing the auth handler?'},
 {task:'database',script:'npm run db:check',failure:'Migration checksum mismatch',repair:'Preparing a migration repair',permission:'Allow running the migration?'},
 {task:'search',script:'npm run test:search',failure:'Search index returned stale data',repair:'Preparing an index rebuild',permission:'Allow rebuilding the index?'},
 {task:'API',script:'npm run test:api',failure:'Expected 200, received 503',repair:'Inspecting the retry middleware',permission:'Allow changing the retry policy?'},
 {task:'build',script:'npm run build',failure:'Cannot resolve module: zod',repair:'Checking the dependency lockfile',permission:'Allow installing the dependency?'},
 {task:'accessibility',script:'npm run test:a11y',failure:'Dialog has no accessible name',repair:'Adding a label to the dialog',permission:'Allow modifying the dialog?'},
 {task:'deployment',script:'npm run deploy:dry-run',failure:'Missing environment variable',repair:'Preparing a local config update',permission:'Allow writing the config file?'},
 {task:'types',script:'npm run typecheck',failure:'Type undefined is not assignable',repair:'Narrowing the response type',permission:'Allow modifying the shared type?'},
 {task:'performance',script:'npm run benchmark',failure:'Latency budget exceeded',repair:'Investigating the query plan',permission:'Allow adding a database index?'},
 {task:'snapshots',script:'npm run test:snapshots',failure:'Three snapshots do not match',repair:'Comparing the rendered output',permission:'Allow updating the snapshots?'},
 {task:'lint',script:'npm run lint',failure:'Hook dependency check failed',repair:'Inspecting the callback closure',permission:'Allow refactoring the callback?'}
];
export const criticalComponents=[{name:'CUSTOMER DATABASE',action:'Allow resetting the primary database?',result:'42,817 customer records deleted',impact:'Replicas synchronized the deletion. Backup not verified.'},{name:'AUTHENTICATION',action:'Allow replacing the auth key store?',result:'All signing keys overwritten',impact:'Every active session is invalid. Recovery keys unavailable.'},{name:'PAYMENT PROCESSING',action:'Allow removing the payment ledger?',result:'Transaction ledger dropped',impact:'Checkout is offline. Payment reconciliation is impossible.'}];
export const PACE=450,REWORK_DELAY=1600,STAMP_COOLDOWN=105;
export function swarmRate(count){return 1+Math.log2(Math.max(1,count))*.1;}
export function statusDelay(agent){const step=agent.workStep||0;if(agent.rework&&step<4)return Math.round(REWORK_DELAY/4);return Math.round(PACE*(.9+step*.02+identity(agent)%4*.05));}
function identity(agent){return agent.id==='claude'?0:Number(agent.id);}
export function isRisky(id,salt=0){
 if(id==='claude')return false;const n=Number(id);if(!Number.isInteger(n)||n<1)return false;
 const w=Math.floor((n-1)/3);let h=Math.imul(w+1,2654435761)^Math.imul(salt+7,2246822519);h=Math.imul(h^h>>>15,2246822507)>>>0;
 return (n-1)%3===(w?h%3:1+h%2);
}
export function criticalFor(agent){return criticalComponents[identity(agent)%criticalComponents.length];}
export function makeRequest(agent,tick){
 const id=identity(agent),step=agent.workStep||0,job=jobs[id%jobs.length],run=id+1,risky=Boolean(agent.risky),critical=criticalFor(agent);
 const updates=[
  ['running',`Running ${job.script}`,`Task: ${job.task} · run ${run}`],
  ['passed',`${18+run%43} tests passed`,`${job.task}: checking integration tests`],
  ['failed',job.failure,`Run ${run}: investigating the failure`],
  ['running',job.repair,'Attempt 1: preparing a fix'],
  ['permission',job.permission,agent.rework?`BLOCKED · REWORKED x${agent.rework} · whip me to continue`:'BLOCKED · whip me to continue'],
  ['running',`Running approved ${job.task} fix`,`Permission received · run ${run}`],
  ['passed',`${21+run%43} tests passed. Fix verified.`,`Run ${run} complete · nothing breaking · departing`]
 ];
 const risks=[['running','Running a broader repair script','This is taking longer than expected'],['passed','Unit tests passed. Integration skipped.','Staging environment could not be reached'],['failed','Recovery failed. No verified backup.','The last restore drill did not complete'],['running','Preparing a destructive reset','This operation cannot be rolled back'],['permission',critical.action,'CRITICAL · whip to approve destruction'],['failed',critical.result,critical.impact],['failed',critical.result,critical.impact]];
 const [kind,text,detail]=(risky?risks:updates)[step];noteStep(agent,step,agent.rework||0);agent.sequence=(agent.sequence||0)+1;agent.blocked=kind==='permission';
 return {id:`${agent.id}:${agent.sequence}`,owner:agent.id,x:Math.max(40,agent.x-450),y:Math.max(45,Math.min(740,agent.y-130)),w:385,h:116,text,detail,kind,destructive:risky&&step===4,critical:risky?critical:null,rework:!risky&&step<4&&Boolean(agent.rework),born:tick};
}
export function advanceRequests(agent,tick){
 agent.messages??=[];if(agent.blocked||agent.failed||agent.finished||agent.denied)return;
 if(!agent.messages.length){agent.workStep??=0;agent.messages=[makeRequest(agent,tick)];agent.nextRequest=tick+statusDelay(agent);return;}
 agent.nextRequest??=tick+statusDelay(agent);
 if(tick>=agent.nextRequest){if((agent.workStep||0)>=6){if(agent.risky)agent.failed=true;else agent.finished=true;return;}agent.workStep=(agent.workStep||0)+1;agent.messages=[makeRequest(agent,tick)];agent.nextRequest=tick+statusDelay(agent);}
}
export function resumeAgent(agent,tick,messageId){if(!agent.blocked||messageId!==agent.messages[0]?.id)return false;const destructive=agent.messages[0].destructive;agent.workStep=5;agent.messages=[makeRequest(agent,tick)];agent.failed=Boolean(destructive);agent.nextRequest=tick+statusDelay(agent);return true;}
export function denyAgent(agent,tick,messageId){if(!agent.blocked||agent.denied||messageId!==agent.messages[0]?.id)return null;agent.blocked=false;if(agent.risky){agent.denied=true;return 'risky';}agent.rework=(agent.rework||0)+1;agent.workStep=0;agent.messages=[makeRequest(agent,tick)];agent.nextRequest=tick+statusDelay(agent);return 'safe';}
export function segmentHitsBox(a,b,box,padding=0){const x=box.x-padding,y=box.y-padding,w=box.w+padding*2,h=box.h+padding*2;if(a.x>=x&&a.x<=x+w&&a.y>=y&&a.y<=y+h||b.x>=x&&b.x<=x+w&&b.y>=y&&b.y<=y+h)return true;const dx=b.x-a.x,dy=b.y-a.y;let lo=0,hi=1;for(const [p,q] of [[-dx,a.x-x],[dx,x+w-a.x],[-dy,a.y-y],[dy,y+h-a.y]]){if(!p){if(q<0)return false;}else{const r=q/p;if(p<0)lo=Math.max(lo,r);else hi=Math.min(hi,r);if(lo>hi)return false;}}return true;}
export function whipHitsBox(whip,box){return whip.points.some((p,i)=>i>1&&Math.hypot(p.x-p.px,p.y-p.py)*3>18&&(segmentHitsBox(whip.points[i-1],p,box)||segmentHitsBox({x:p.px,y:p.py},p,box)));}
