import React from 'react';
const mix=(c,p)=>`color-mix(in oklch, ${c} ${p}%, transparent)`;
export function Card({tone,inner,children,style,onClick}){
  const bg=inner?'var(--surface-inner)':tone?mix(tone,9):'var(--surface-card)';
  const bd=tone?mix(tone,35):'var(--border-card)';
  return <div onClick={onClick} style={{background:bg,border:'1px solid '+bd,borderRadius:inner?10:14,padding:'11px 14px',transition:'background .6s, border-color .6s',cursor:onClick?'pointer':undefined,...style}}>{children}</div>;
}
