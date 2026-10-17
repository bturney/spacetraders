import React from 'react';
export function Money({value,est,stale,size=13,color}){
  if(value==null) return <span style={{fontFamily:'var(--font-mono)',fontSize:size,color:'var(--text-dim)'}}>—</span>;
  const c=color||(value<0?'var(--money-loss)':'var(--text-body)');
  const s=(value<0?'−':'+')+Math.abs(Math.round(value)).toLocaleString('en-US');
  return <span style={{fontFamily:'var(--font-mono)',fontSize:size,fontVariantNumeric:'tabular-nums',color:c,whiteSpace:'nowrap'}}>{stale?'~':''}{s}{est&&<span style={{fontSize:Math.max(10,size*.75),color:'var(--text-dim)'}}> est.</span>}</span>;
}
