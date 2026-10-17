import React from 'react';
import {Card} from '../core/Card.jsx';
import {Eyebrow} from '../core/Eyebrow.jsx';
const H={on:['On plan','var(--health-on-plan)'],setback:['Small setback, recoverable','var(--health-setback)'],off:['Off plan, real blocker','var(--health-off-plan)'],unknown:["Can't tell right now",'var(--health-unknown)']};
export function HealthCard({state,reason,large}){
  const [l,c]=H[state];const u=state==='unknown';
  return <Card tone={c}><div style={{display:'flex',alignItems:'center',gap:10}}><span style={{width:14,height:14,borderRadius:'50%',flex:'none',...(u?{border:'1.5px dashed '+c}:{background:c,boxShadow:'0 0 12px '+c})}}></span><span style={{fontSize:large?20:18,fontWeight:600,color:c,flex:1}}>{l}</span><Eyebrow>Plan health</Eyebrow></div>
  <div style={{fontSize:large?15:14,lineHeight:1.35,marginTop:6,color:'var(--st-ink-2)',textWrap:'pretty'}}>{reason}</div></Card>;
}
