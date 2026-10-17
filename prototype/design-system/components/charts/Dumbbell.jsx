import React from 'react';
export function Dumbbell({label,expected,actual,note,range=2000}){
  const pos=v=>50+Math.max(-50,Math.min(50,v/range*50));
  const c=actual<0?'var(--money-loss)':actual>=expected?'var(--money-gain)':'var(--money-short)';
  const a=pos(expected),b=pos(actual),d=actual-expected,f=v=>(v<0?'−':'+')+Math.abs(v).toLocaleString('en-US');
  return <div style={{display:'flex',flexDirection:'column',gap:5}}><div style={{display:'flex',justifyContent:'space-between',gap:8,fontSize:13}}><span>{label}</span><span style={{fontFamily:'var(--font-mono)',fontSize:12,color:'var(--text-muted)'}}>exp {f(expected)} → <span style={{color:c}}>{f(actual)}</span></span></div>
  <div style={{position:'relative',height:12}}><div style={{position:'absolute',left:'50%',top:0,bottom:0,width:1,background:'var(--st-zero)'}}></div><div style={{position:'absolute',top:5,height:2,left:Math.min(a,b)+'%',width:Math.abs(a-b)+'%',background:c}}></div>
  <div style={{position:'absolute',top:1,left:`calc(${a}% - 5px)`,width:8,height:8,borderRadius:'50%',border:'1.5px solid var(--text-muted)',background:'var(--surface-card)'}}></div><div style={{position:'absolute',top:1,left:`calc(${b}% - 5px)`,width:10,height:10,borderRadius:'50%',background:c}}></div></div>
  <div style={{fontSize:11,color:'var(--text-dim)'}}><span style={{color:c,fontFamily:'var(--font-mono)'}}>{f(d)} vs est.</span>{note?' · '+note:''}</div></div>;
}
