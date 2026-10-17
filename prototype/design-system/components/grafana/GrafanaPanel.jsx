import React from 'react';
export function GrafanaPanel({title,children,noData,style}){
  return <div style={{background:'var(--gf-panel)',border:'1px solid var(--gf-border)',borderRadius:2,display:'flex',flexDirection:'column',minHeight:96,fontFamily:'Inter, system-ui, sans-serif',color:'var(--gf-text)',...style}}><div style={{padding:'6px 8px',fontSize:12,fontWeight:500}}>{title}</div>
  <div style={{flex:1,padding:'4px 10px 10px',display:'flex',flexDirection:'column',justifyContent:noData?'center':'flex-start',alignItems:noData?'center':'stretch'}}>{noData?<span style={{fontSize:13,color:'var(--gf-text-faint)'}}>No data</span>:children}</div></div>;
}
