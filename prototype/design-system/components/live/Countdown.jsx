import React from 'react';
export function Countdown({seconds,caption,size=24,color}){
  const t=seconds==null?'—':Math.floor(seconds/60)+':'+String(Math.max(0,Math.floor(seconds%60))).padStart(2,'0');
  return <div style={{textAlign:'right',minWidth:size*2.6}}><div style={{fontFamily:'var(--font-mono)',fontSize:size,fontWeight:500,fontVariantNumeric:'tabular-nums',color:color||'var(--text-body)',lineHeight:1.1}}>{t}</div>{caption&&<div style={{fontSize:Math.max(10,size*.42),color:'var(--text-dim)'}}>{caption}</div>}</div>;
}
