export function circleEntry(a,b,c,r){const dx=b.x-a.x,dy=b.y-a.y,ox=a.x-c.x,oy=a.y-c.y,q=dx*dx+dy*dy,v=ox*ox+oy*oy-r*r;if(v<=0)return 0;if(!q)return Infinity;const p=ox*dx+oy*dy,d=p*p-q*v;if(d<0)return Infinity;const t=(-p-Math.sqrt(d))/q;return t>=0&&t<=1?t:Infinity;}
export function boxEntry(a,b,box,pad=0){let lo=0,hi=1;const dx=b.x-a.x,dy=b.y-a.y;for(const [p,q] of [[-dx,a.x-box.x+pad],[dx,box.x+box.w+pad-a.x],[-dy,a.y-box.y+pad],[dy,box.y+box.h+pad-a.y]]){if(!p){if(q<0)return Infinity;}else{const t=q/p;if(p<0)lo=Math.max(lo,t);else hi=Math.min(hi,t);if(lo>hi)return Infinity;}}return lo;}
export function projectileTarget(shot,entities){const from={x:shot.px,y:shot.py};let target=null,nearest=Infinity;for(const agent of entities){let entry=circleEntry(from,shot,agent,agent.r+24);for(const message of agent.messages)entry=Math.min(entry,boxEntry(from,shot,message,12));if(entry!==Infinity&&entry<=nearest){nearest=entry;target=agent;}}return target;}
export class SwingGate {
 constructor(){this.spent=false;this.quiet=0;this.last={x:850,y:450};this.direction=null;this.lastHit=-Infinity;}
 reset(){this.spent=false;this.direction=null;}
 move(mouse,tick){const dx=mouse.x-this.last.x,dy=mouse.y-this.last.y,speed=Math.hypot(dx,dy);this.last={...mouse};if(speed<=4){this.quiet++;return;}const dir={x:dx/speed,y:dy/speed};if(this.quiet>=12||speed>8&&this.direction&&dir.x*this.direction.x+dir.y*this.direction.y<-.4&&tick-this.lastHit>12)this.spent=false;this.direction=dir;this.quiet=0;}
 consume(tick){this.spent=true;this.lastHit=tick;}
}
