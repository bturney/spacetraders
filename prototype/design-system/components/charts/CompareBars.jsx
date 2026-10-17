import React from 'react';
export function CompareBars({options,caption}){
  const m=Math.max(...options.map(o=>Math.abs(o.value)));
  return <div style={{display:'flex',flexDirection:'column',gap:8}}>{caption&&<div style={{fontSize:12,color:'var(--text-dim)'}}>{caption}</div>}
  {options.map((o,i)=>{const c=o.value<0?'var(--money-loss)':o.chosen?'var(--money-gain)':'var(--st-dim)';return <div key={i} style={{display:'grid',gridTemplateColumns:'minmax(0,1.3fr) minmax(0,1fr) 64px',gap:10,alignItems:'center'}}>
    <span style={{fontSize:13,color:o.chosen?'var(--text-body)':'var(--text-muted)',whiteSpace:'nowrap',overflow:'hidden',textOverflow:'ellipsis'}}>{o.label}{o.chosen&&<span style={{fontFamily:'var(--font-mono)',fontSize:9,letterSpacing:'.12em',color:'var(--money-gain)',marginLeft:6}}>CHOSEN</span>}</span>
    <div style={{height:8,borderRadius:4,background:'var(--st-track)'}}><div style={{width:Math.abs(o.value)/m*100+'%',height:'100%',borderRadius:4,background:c}}></div></div>
    <span style={{fontFamily:'var(--font-mono)',fontSize:12,textAlign:'right',color:c}}>{(o.value<0?'−':'+')+Math.abs(o.value).toLocaleString('en-US')}</span></div>})}</div>;
}
