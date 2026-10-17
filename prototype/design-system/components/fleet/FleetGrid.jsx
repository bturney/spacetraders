import React from 'react';
const mix=(c,p)=>`color-mix(in oklch, ${c} ${p}%, transparent)`;
import {STATUS} from '../core/StatusChip.jsx';
export function FleetGrid({ships,columns=20,onSelect}){
  const counts={};ships.forEach(s=>counts[s.status]=(counts[s.status]||0)+1);
  return <div><div style={{display:'grid',gridTemplateColumns:`repeat(${columns},minmax(0,1fr))`,gap:3}}>{ships.map((s,i)=>{const c=STATUS[s.status][1];const p=s.status==='stuck'?1:s.progress;return <div key={i} title={s.name} onClick={()=>onSelect&&onSelect(s)} style={{aspectRatio:'1',borderRadius:2,background:mix(c,18),position:'relative',overflow:'hidden',cursor:'pointer',outline:s.sold?'1.5px solid var(--money-gain)':'none'}}><div style={{position:'absolute',left:0,right:0,bottom:0,height:p*100+'%',background:mix(c,70),transition:'height .25s linear'}}></div></div>})}</div>
  <div style={{display:'flex',flexWrap:'wrap',gap:'4px 14px',marginTop:10,fontSize:12,color:'var(--text-muted)'}}>{Object.keys(STATUS).filter(k=>counts[k]).map(k=><span key={k} style={{display:'flex',alignItems:'center',gap:6}}><span style={{width:8,height:8,borderRadius:2,background:STATUS[k][1]}}></span>{STATUS[k][0]} <span style={{fontFamily:'var(--font-mono)'}}>{counts[k]}</span></span>)}</div></div>;
}
