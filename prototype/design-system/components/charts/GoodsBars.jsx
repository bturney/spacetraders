import React from 'react';
export function GoodsBars({items}){
  const m=Math.max(...items.map(i=>i.value));
  return <div style={{display:'flex',flexDirection:'column',gap:6}}>{items.map((it,i)=><div key={i} style={{display:'grid',gridTemplateColumns:'96px minmax(0,1fr) 48px',gap:8,alignItems:'center',fontSize:13}}><span>{it.label}</span><div style={{height:8,borderRadius:4,background:'var(--st-track)'}}><div style={{width:it.value/m*100+'%',height:'100%',borderRadius:4,background:i?'color-mix(in oklch, var(--st-yellow) 60%, transparent)':'var(--st-yellow)'}}></div></div><span style={{fontFamily:'var(--font-mono)',fontSize:12,textAlign:'right',color:'var(--text-muted)'}}>{it.display}</span></div>)}</div>;
}
