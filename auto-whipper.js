import {Whip,ropeHits} from './physics.js';
import {whipHitsBox} from './messages.js';
export class AutoWhipper {
 constructor(){this.whip=null;this.target=null;this.frame=0;this.cooldown=0;this.hand={x:820,y:650};}
 step(entities){
  const agents=[...entities];if(this.cooldown){this.cooldown--;return null;}
  let target=agents.find(a=>a.id===this.target&&a.blocked&&!a.failed);
  if(!target){target=agents.filter(a=>a.blocked&&!a.failed).sort((a,b)=>(a.messages[0]?.born||0)-(b.messages[0]?.born||0))[0];this.target=target?.id??null;this.frame=0;this.whip=null;}
  if(!target){this.hand={x:820,y:650};return null;}
  const t=Math.min(1,this.frame/20);this.hand={x:target.x-330+t*460,y:target.y-95+Math.sin(t*Math.PI)*80};
  this.whip??=new Whip(this.hand.x,this.hand.y);if(this.frame===6)this.whip.kick();this.whip.step(this.hand,1600,900);this.frame++;
  const message=target.messages[0];if(this.frame>=12&&(ropeHits(this.whip,target)||message&&whipHitsBox(this.whip,message))){
   const event={type:'agent-resumed',owner:target.id,id:message?.id,source:'auto'};this.target=null;this.cooldown=30;return event;
  }
  if(this.frame>65){this.target=null;this.whip=null;}
  return null;
 }
}
