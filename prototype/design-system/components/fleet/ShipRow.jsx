import React from 'react';
const mix=(c,p)=>`color-mix(in oklch, ${c} ${p}%, transparent)`;
import {StatusChip,STATUS} from '../core/StatusChip.jsx';
import {RouteBar} from '../live/RouteBar.jsx';
import {Money} from '../core/Money.jsx';
export function ShipRow({ship,compact,sold,onClick}){
  const c=STATUS[ship.status][1];
  const t=sold!=null?<span style={{color:sold<0?'var(--money-loss)':'var(--money-gain)'}}>{(sold<0?'−':'+')+Math.abs(sold).toLocaleString('en-US')} sold</span>:<>{ship.time}<div style={{fontSize:10,color:'var(--text-dim)'}}>{ship.timeCaption}</div></>;
  const cells=[<span key="n" style={{gridArea:'name',fontFamily:'var(--font-mono)',fontSize:13}}>{ship.name}</span>,<span key="s" style={{gridArea:'status',justifySelf:compact?'end':'start'}}><StatusChip status={ship.status} small/></span>,
   <span key="c" style={{gridArea:'cargo',fontSize:14,color:'var(--st-ink-2)',minWidth:0,overflow:'hidden',textOverflow:'ellipsis',whiteSpace:'nowrap'}}>{ship.phrase}</span>,
   <span key="r" style={{gridArea:'route',minWidth:0}}><RouteBar size="sm" from={ship.from} to={ship.to} at={ship.at} progress={ship.progress} color={c}/></span>,
   <span key="t" style={{gridArea:'time',fontFamily:'var(--font-mono)',fontSize:13,textAlign:'right',fontVariantNumeric:'tabular-nums'}}>{t}</span>,
   <span key="e" style={{gridArea:'est',textAlign:'right'}}><Money value={ship.expected} est stale={ship.stale}/></span>];
  return <div onClick={onClick} style={{display:'grid',gap:compact?'6px 10px':'0 14px',alignItems:'center',padding:compact?'10px 12px':'10px 14px',borderTop:'1px solid var(--st-divider)',cursor:'pointer',background:sold!=null?mix(sold<0?'var(--money-loss)':'var(--money-gain)',9):'transparent',transition:'background .6s',
   gridTemplateAreas:compact?"'name status' 'cargo est' 'route time'":"'name status cargo route time est'",gridTemplateColumns:compact?'minmax(0,1fr) auto':'128px 140px minmax(0,1.1fr) minmax(0,1.2fr) 70px 92px'}}>{cells}</div>;
}
