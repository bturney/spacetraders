import React from 'react';
import {Card} from '../core/Card.jsx';
import {StatusChip,STATUS} from '../core/StatusChip.jsx';
import {RouteBar} from '../live/RouteBar.jsx';
import {Countdown} from '../live/Countdown.jsx';
export function ShipCard({ship,sold,onClick}){
  const c=STATUS[ship.status][1];
  return <Card inner tone={sold!=null?(sold<0?'var(--money-loss)':'var(--money-gain)'):undefined} onClick={onClick} style={{display:'flex',flexDirection:'column',gap:8}}>
   <div style={{display:'flex',alignItems:'flex-start',gap:8}}><div style={{flex:1,display:'flex',flexDirection:'column',gap:4,minWidth:0}}><div style={{display:'flex',gap:8,alignItems:'center'}}><span style={{fontFamily:'var(--font-mono)',fontSize:12}}>{ship.name}</span><StatusChip status={ship.status} small/></div><span style={{fontSize:14,color:'var(--st-ink-2)'}}>{ship.phrase}</span></div>
   {sold!=null?<div style={{textAlign:'right'}}><div style={{fontFamily:'var(--font-mono)',fontSize:24,color:sold<0?'var(--money-loss)':'var(--money-gain)'}}>{(sold<0?'−':'+')+Math.abs(sold).toLocaleString('en-US')}</div><div style={{fontSize:10,color:'var(--text-dim)'}}>sold just now</div></div>:<Countdown seconds={ship.seconds} caption={ship.timeCaption}/>}</div>
   <RouteBar from={ship.from} to={ship.to} at={ship.at} progress={ship.progress} color={c}/></Card>;
}
