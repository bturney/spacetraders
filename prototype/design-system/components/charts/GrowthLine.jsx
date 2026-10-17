import React from 'react';
export function GrowthLine({points,height=72,startLabel,endLabel}){
  const max=Math.max(...points),min=Math.min(...points),w=300;
  const xy=points.map((v,i)=>[i/(points.length-1)*w,height-((v-min)/(max-min||1))*(height-4)-2]);
  const d=xy.map((p,i)=>(i?'L':'M')+p[0].toFixed(1)+' '+p[1].toFixed(1)).join(' ');
  return <div><svg viewBox={`0 0 ${w} ${height}`} preserveAspectRatio="none" style={{width:'100%',height,display:'block'}}><path d={d+` L${w} ${height} L0 ${height} Z`} fill="color-mix(in oklch, var(--st-green) 12%, transparent)"/><path d={d} fill="none" stroke="var(--st-green)" strokeWidth="1.6" vectorEffect="non-scaling-stroke"/></svg>
  <div style={{display:'flex',justifyContent:'space-between',fontFamily:'var(--font-mono)',fontSize:10,color:'var(--text-dim)',marginTop:4}}><span>{startLabel}</span><span>{endLabel}</span></div></div>;
}
