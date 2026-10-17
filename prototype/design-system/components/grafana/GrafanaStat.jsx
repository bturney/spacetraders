import React from 'react';
export function GrafanaStat({value,unit,color='var(--gf-green)',sub}){
  return <div style={{display:'flex',flexDirection:'column',alignItems:'center',justifyContent:'center',flex:1}}><div style={{fontSize:34,fontWeight:500,color}}>{value}<span style={{fontSize:18}}>{unit}</span></div>{sub&&<div style={{fontSize:11,color:'var(--gf-text-dim)'}}>{sub}</div>}</div>;
}
