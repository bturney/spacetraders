import React from 'react';
const mix=(c,p)=>`color-mix(in oklch, ${c} ${p}%, transparent)`;
export function RouteBar({from,to,progress=0,color='var(--status-trading)',size='md',at}){
  const z={sm:[5,8,11],md:[8,12,12],lg:[10,16,13]}[size];
  const code={fontFamily:'var(--font-mono)',fontSize:z[2],color:'var(--text-muted)',minWidth:30};
  if(at) return <div style={{display:'flex',alignItems:'center',gap:8}}><span style={code}>{at}</span><div style={{flex:1,height:z[0],borderRadius:z[0],background:'var(--st-track)',overflow:'hidden'}}><div style={{width:(1-progress)*100+'%',height:'100%',background:mix(color,40),transition:'width .25s linear'}}></div></div></div>;
  return <div style={{display:'flex',alignItems:'center',gap:8}}><span style={code}>{from}</span>
    <div style={{flex:1,position:'relative',height:z[1]}}><div style={{position:'absolute',left:0,right:0,top:(z[1]-z[0])/2,height:z[0],borderRadius:z[0],background:'var(--st-track)',overflow:'hidden'}}><div style={{width:progress*100+'%',height:'100%',background:mix(color,55),transition:'width .25s linear'}}></div></div>
    <div style={{position:'absolute',top:0,left:`calc(${progress*100}% - ${z[1]/2}px)`,width:z[1],height:z[1],background:color,transform:'rotate(45deg) scale(.8)',boxShadow:'0 0 8px '+color,transition:'left .25s linear'}}></div></div>
    <span style={{...code,textAlign:'right'}}>{to}</span></div>;
}
