import {Whip,ropeHits,whipHitsBox} from './physics.js';
// The Approval Intern: walks to the oldest waiting prompt, in any session, and whips it. Approves everything.
export class AutoWhipper {
 constructor(){this.whip=null;this.target=null;this.frame=0;this.cooldown=0;this.hand={x:820,y:650};}
 step(entities){
  const waiting=[...entities].filter(a=>a.prompt&&!a.answered&&!(a.enter>0));if(this.cooldown){this.cooldown--;return null;}
  let target=waiting.find(a=>a.id===this.target);
  if(!target){target=waiting.sort((a,b)=>(a.box?.born||0)-(b.box?.born||0))[0];this.target=target?.id??null;this.frame=0;this.whip=null;}
  if(!target){this.hand={x:820,y:650};return null;}
  const t=Math.min(1,this.frame/20);this.hand={x:target.x-330+t*460,y:target.y-95+Math.sin(t*Math.PI)*80};
  this.whip??=new Whip(this.hand.x,this.hand.y);if(this.frame===6)this.whip.kick();this.whip.step(this.hand,1600,900);this.frame++;
  if(this.frame>=12&&(ropeHits(this.whip,target)||target.box&&whipHitsBox(this.whip,target.box))){
   const event={type:'answer',owner:target.id,id:target.prompt.id,decision:'allow',source:'intern'};this.target=null;this.cooldown=30;return event;
  }
  if(this.frame>65){this.target=null;this.whip=null;}
  return null;
 }
}
