import React from 'react';
export function CreditsTicker({value,flash,size=44}){
  return <div style={{position:'relative',display:'inline-block'}}><span style={{fontFamily:'var(--font-mono)',fontSize:size,fontWeight:600,fontVariantNumeric:'tabular-nums',color:flash?'var(--money-gain)':'var(--text-body)',transition:'color .6s'}}>{Math.round(value).toLocaleString('en-US')}</span>
  {flash&&<span style={{position:'absolute',left:'100%',top:4,marginLeft:10,fontFamily:'var(--font-mono)',fontSize:size*.36,color:'var(--money-gain)',whiteSpace:'nowrap'}}>+{flash.toLocaleString('en-US')}</span>}</div>;
}
