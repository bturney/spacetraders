import React from 'react';
export function DataBadge({sample,short}){
  const c=sample?'var(--st-yellow)':'var(--st-green)';
  return <span style={{fontFamily:'var(--font-mono)',fontSize:10,letterSpacing:'.12em',padding:'4px 7px',borderRadius:5,border:'1px solid '+c,color:c,whiteSpace:'nowrap'}}>{sample?'SAMPLE':'REAL'}{short?'':' DATA'}</span>;
}
