import React from 'react';
export function SoldToast({amount,detail,more,visible=true}){
  const c=amount<0?'var(--money-loss)':'var(--money-gain)';
  return <div style={{display:'inline-flex',alignItems:'center',gap:10,maxWidth:'100%',padding:'9px 14px',borderRadius:999,background:'var(--st-panel-2)',border:'1px solid var(--st-line)',boxShadow:'0 8px 24px oklch(0 0 0 / .4)',opacity:visible?1:0,transform:visible?'none':'translateY(10px)',transition:'opacity .35s, transform .35s'}}>
    <span style={{fontFamily:'var(--font-mono)',fontSize:10,letterSpacing:'.12em',padding:'2px 6px',borderRadius:4,background:c,color:'var(--st-page)',fontWeight:600}}>SOLD</span>
    <span style={{fontFamily:'var(--font-mono)',fontSize:16,color:c}}>{(amount<0?'−':'+')+Math.abs(amount).toLocaleString('en-US')}</span>
    <span style={{fontSize:13,color:'var(--text-muted)',whiteSpace:'nowrap',overflow:'hidden',textOverflow:'ellipsis'}}>{detail}{more?` · +${more} more`:''}</span></div>;
}
