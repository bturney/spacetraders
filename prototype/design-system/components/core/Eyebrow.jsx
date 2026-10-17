import React from 'react';
export function Eyebrow({children,right,color}){
  return <div style={{display:'flex',justifyContent:'space-between',gap:8,fontFamily:'var(--font-mono)',fontSize:10,letterSpacing:'.14em',textTransform:'uppercase',color:color||'var(--text-dim)'}}><span>{children}</span>{right&&<span style={{letterSpacing:'.04em',textTransform:'none'}}>{right}</span>}</div>;
}
