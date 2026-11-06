const clamp=(n,a,b)=>Math.max(a,Math.min(b,n));
export class Whip {
 constructor(x=800,y=400){this.points=Array.from({length:28},(_,i)=>({x:x+i*3,y:y+i*17,px:x+i*3,py:y+i*17}));this.anchor={x,y};this.angle=-.85;this.old={x,y};this.age=0;this.lastCrack=-100;this.lastGesture=-100;this.flick=0;for(let i=0;i<180;i++)this.step({x,y},1600,900);this.age=0;this.lastGesture=-100;}
 length(i){return 22*(1-i/27*.4);}
 kick(){this.flick=18;}
 step(mouse,width,height){
  this.age++;let mx=clamp(mouse.x,0,width),my=clamp(mouse.y,0,height);
  const inputSpeed=Math.hypot(mx-this.old.x,my-this.old.y);
  if(inputSpeed>15||this.flick)this.lastGesture=this.age;
  const target=-.85+clamp((mx-this.old.x)*.002+(my-this.old.y)*.001,-.25,.25);
  this.angle+=(target-this.angle)*.12;this.old={x:mx,y:my};
  if(this.flick){const phase=(18-this.flick)/17;mx+=Math.sin(phase*Math.PI*2)*155;my-=Math.sin(phase*Math.PI)*45;this.flick--;}
  const start={...this.anchor};this.anchor.x+=(clamp(mx,0,width)-this.anchor.x)*.55;this.anchor.y+=(clamp(my,0,height)-this.anchor.y)*.55;
  for(let sub=1;sub<=3;sub++){
   const hx=start.x+(this.anchor.x-start.x)*sub/3,hy=start.y+(this.anchor.y-start.y)*sub/3;
   for(let i=2;i<28;i++){const p=this.points[i],vx=(p.x-p.px)*.97,vy=(p.y-p.py)*.97;p.px=p.x;p.py=p.y;p.x+=vx;p.y+=vy+1.2/9;}
   const pin=this.points[0],handle=this.points[1];pin.x=hx;pin.y=hy;pin.px=hx;pin.py=hy;handle.x=hx+Math.cos(this.angle)*this.length(0);handle.y=hy+Math.sin(this.angle)*this.length(0);handle.px=handle.x;handle.py=handle.y;
   for(let k=0;k<16;k++){
    for(let i=1;i<27;i++){const a=this.points[i],b=this.points[i+1],dx=b.x-a.x,dy=b.y-a.y,d=Math.hypot(dx,dy)||.0001,f=(d-this.length(i))/d;if(i>1){a.x+=dx*f*.5;a.y+=dy*f*.5;b.x-=dx*f*.5;b.y-=dy*f*.5;}else{b.x-=dx*f;b.y-=dy*f;}}
    for(let i=1;i<28;i++){const p=this.points[i],x=clamp(p.x,0,width),y=clamp(p.y,0,height);if(x!==p.x){p.x=x;p.px=x;}if(y!==p.y){p.y=y;p.py=y;}}
   }
  }
  const tip=this.points.at(-1),speed=Math.hypot(tip.x-tip.px,tip.y-tip.py)*3;
  if((speed>125&&this.age>21||this.flick>0&&speed>20)&&this.age-this.lastGesture<24&&this.age-this.lastCrack>18){this.lastCrack=this.age;return true;}return false;
 }
}
export function segmentDistance(p,a,b){const dx=b.x-a.x,dy=b.y-a.y,t=clamp(((p.x-a.x)*dx+(p.y-a.y)*dy)/(dx*dx+dy*dy||1),0,1);return Math.hypot(p.x-a.x-t*dx,p.y-a.y-t*dy);}
export function ropeHits(whip,agent){return whip.points.some((p,i)=>i>1&&Math.hypot(p.x-p.px,p.y-p.py)*3>18&&(segmentDistance(agent,whip.points[i-1],p)<agent.r||segmentDistance(agent,{x:p.px,y:p.py},p)<agent.r));}
