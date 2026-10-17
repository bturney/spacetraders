import React from 'react';
export function GrafanaBackBar({to='Mission Control',url,onBack}){
  return <div style={{display:'flex',alignItems:'center',gap:12,padding:'8px 12px',background:'var(--gf-chrome)',borderBottom:'1px solid var(--gf-border)',fontSize:13}}><button onClick={onBack} style={{all:'unset',cursor:'pointer',color:'var(--st-link)',minHeight:32,display:'flex',alignItems:'center'}}>← Back to {to}</button><span style={{fontFamily:'var(--font-mono)',fontSize:11,color:'var(--gf-text-faint)',overflow:'hidden',textOverflow:'ellipsis',whiteSpace:'nowrap'}}>{url}</span></div>;
}
