import React from 'react';
const mix=(c,p)=>`color-mix(in oklch, ${c} ${p}%, transparent)`;
export const STATUS={trading:['Trading','var(--status-trading)'],busy:['Busy, not earning','var(--status-busy)'],waiting:['Waiting on purpose','var(--status-waiting)'],stuck:['Stuck','var(--status-stuck)'],scouting:['Scouting prices','var(--status-scouting)']};
export function StatusChip({status,label,small}){
  const [l,c]=STATUS[status]||STATUS.trading;
  return <span style={{display:'inline-flex',alignItems:'center',gap:6,padding:small?'2px 7px':'3px 9px',borderRadius:999,background:mix(c,16),color:c,fontSize:small?11:12,fontWeight:500,whiteSpace:'nowrap'}}><span style={{width:6,height:6,borderRadius:'50%',background:c}}></span>{label||l}</span>;
}
