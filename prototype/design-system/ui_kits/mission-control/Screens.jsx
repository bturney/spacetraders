const NS=Object.values(window).find(v=>v&&typeof v==='object'&&v.RouteBar&&v.Card)||{};
const {Card,Eyebrow,DataBadge,Money,Countdown,SoldToast,CreditsTicker,GrowthLine,CompareBars,Dumbbell,GoodsBars,HealthCard,ShipRow,ShipCard}=NS;
const {useState,useEffect}=React;
const mmss=s=>Math.floor(s/60)+':'+String(Math.floor(s%60)).padStart(2,'0');
const LEG=[{from:'F47',to:'E45',good:'Ammunition',exp:820,act:1180,dur:220},{from:'F48',to:'C41',good:'Electronics',exp:980,act:1340,dur:200},{from:'G49',to:'E46',good:'Fertilizers',exp:560,act:610,dur:180}];
const PROBE=['C41','G49','E45','F47','A4'];

function useSim(){
  const [t,setT]=useState(150);const [credits,setCredits]=useState(2873412);const [shown,setShown]=useState(2873412);const [sold,setSold]=useState(null);
  useEffect(()=>{const id=setInterval(()=>setT(x=>x+1),1000);return()=>clearInterval(id)},[]);
  useEffect(()=>{const id=setInterval(()=>setShown(v=>Math.abs(credits-v)<1?credits:v+(credits-v)*.18),200);return()=>clearInterval(id)},[credits]);
  let acc=0,i=0;while(acc+LEG[i%3].dur<=t){acc+=LEG[i%3].dur;i++}
  const leg=LEG[i%3],left=leg.dur-(t-acc);
  useEffect(()=>{if(t>150&&t-acc===0){const p=LEG[(i+2)%3];setCredits(c=>c+p.act);setSold({amt:p.act,detail:p.good+' at '+p.to,at:t})}},[t]);
  const flash=sold&&t-sold.at<4.5?sold:null;
  const pl=(t%90),pi=Math.floor(t/90);
  const ships=[{name:'HARDBARGAIN-1',status:'trading',phrase:'Hauling 20 '+leg.good,from:leg.from,to:leg.to,progress:1-left/leg.dur,seconds:left,time:mmss(left),timeCaption:'to arrival',expected:leg.exp},
    {name:'HARDBARGAIN-2',status:'scouting',phrase:'Checking prices',from:PROBE[pi%5],to:PROBE[(pi+1)%5],progress:pl/90,seconds:90-pl,time:mmss(90-pl),timeCaption:'to arrival',expected:null}];
  return {ships,left,leg,shown,flash,sold:sold&&t-sold.at<5?sold:null};
}

function Header({left,leg}){return <div style={{display:'flex',alignItems:'center',gap:10,padding:'12px 14px',borderBottom:'1px solid var(--st-divider)'}}>
  <span style={{width:22,height:22,borderRadius:'50%',border:'2px solid var(--st-cyan)',display:'grid',placeItems:'center',flex:'none'}}><span style={{width:6,height:6,borderRadius:'50%',background:'var(--st-cyan)'}}></span></span>
  <div style={{flex:1,minWidth:0}}><div style={{fontSize:17,fontWeight:600}}>Mission Control</div><div style={{fontSize:12,color:'var(--text-dim)'}}>Healthy trading</div></div>
  <DataBadge short/><div style={{textAlign:'right'}}><div style={{fontFamily:'var(--font-mono)',fontSize:15,fontWeight:500}}>{mmss(left)}</div><div style={{fontSize:10,color:'var(--text-dim)'}}>next sale · +{leg.exp} est.</div></div></div>}

function Glance({sim,open}){return <div style={{display:'flex',flexDirection:'column',gap:10}}>
  <HealthCard state="on" reason="A trade lands every 3–4 min and earnings are at the usual pace."/>
  <Card><Eyebrow right="whole game · 5 days">Credits</Eyebrow><div style={{marginTop:4}}><CreditsTicker value={sim.shown} flash={sim.flash&&sim.flash.amt} size={34}/></div>
   <div style={{fontSize:13,color:'var(--text-muted)',margin:'2px 0 8px'}}><span style={{fontFamily:'var(--font-mono)',fontSize:15,color:'var(--text-body)'}}>~14k cr/h</span> usual pace (13–15k) · game avg 22.5k/h</div>
   <GrowthLine height={46} points={[172,190,260,420,610,900,1200,1500,1900,2300,2600,sim.shown/1000]} startLabel="11 Oct · 172k" endLabel="now · 2.87M"/></Card>
  <Card><Eyebrow>Ships in motion</Eyebrow><div style={{display:'flex',flexDirection:'column',gap:8,marginTop:8}}>{sim.ships.map(s=><ShipCard key={s.name} ship={s} onClick={()=>open(s)} sold={sim.flash&&s.status==='trading'?sim.flash.amt:null}/>)}</div></Card></div>}

function Ships({sim,open}){return <Card style={{padding:0,overflow:'hidden'}}><div style={{padding:'11px 14px'}}><Eyebrow right="by name">Ships · 2</Eyebrow></div>{sim.ships.map(s=><ShipRow key={s.name} compact ship={s} onClick={()=>open(s)} sold={sim.flash&&s.status==='trading'?sim.flash.amt:null}/>)}</Card>}

function Ship({ship,back}){const probe=ship.status==='scouting';return <div style={{display:'flex',flexDirection:'column',gap:10}}>
  <a onClick={back} style={{cursor:'pointer',fontSize:14,minHeight:32,display:'flex',alignItems:'center'}}>← All Ships</a>
  <ShipCard ship={ship}/>
  <Card><Eyebrow>Why</Eyebrow><div style={{fontSize:17,lineHeight:1.5,margin:'6px 0 12px',textWrap:'pretty'}}>{probe?'Flies market to market so the trader has fresh prices to choose from. It carries no cargo.':'Bought 20 Ammunition at F47 for 1,846 each to sell at E45 for about 1,887 each, expecting about +820. It chose this over Fertilizers G49 → E46 (+560) and Hydrocarbon C41 → G49 (+520) because it pays the most.'}</div>
   {!probe&&<CompareBars caption="What it compared" options={[{label:'Ammunition F47 → E45',value:820,chosen:true},{label:'Fertilizers G49 → E46',value:560},{label:'Hydrocarbon C41 → G49',value:520}]}/>}
   {!probe&&<div style={{fontSize:12,color:'var(--st-yellow)',marginTop:10}}>◆ The E45 price is 28 min old · <span style={{color:'var(--text-dim)'}}>◆ Estimates leave out fuel</span></div>}</Card>
  {!probe&&<Card><Eyebrow>Recent trades</Eyebrow><div style={{display:'flex',flexDirection:'column',gap:12,marginTop:8}}><Dumbbell label="Electronics F48 → C41" expected={980} actual={1340} note="Paid 59,700 · sold 61,040"/><Dumbbell label="Fertilizers G49 → E46" expected={560} actual={410} note="sample"/></div></Card>}</div>}

function Records(){return <div style={{display:'flex',flexDirection:'column',gap:10}}>
  <Card><Eyebrow>Best single trade</Eyebrow><div style={{fontFamily:'var(--font-mono)',fontSize:32,color:'var(--money-gain)'}}>+43,620</div><div style={{fontSize:13,color:'var(--text-muted)'}}>Lab Instruments C41 → A4 · 11 Oct</div></Card>
  <Card><Eyebrow>Most valuable goods</Eyebrow><div style={{marginTop:8}}><GoodsBars items={[{label:'Ship Parts',value:469,display:'469k'},{label:'Medicine',value:390,display:'390k'},{label:'Fabrics',value:380,display:'380k'},{label:'Electronics',value:303,display:'303k'}]}/></div></Card>
  <Card><Eyebrow>Trades completed</Eyebrow><div style={{fontFamily:'var(--font-mono)',fontSize:32}}>1,277</div><div style={{fontSize:13,color:'var(--text-muted)',lineHeight:1.4}}>3.13M trading profit before fuel · 397k spent on fuel · 626 buys skipped because prices rose</div></Card></div>}

function App(){const sim=useSim();const [tab,setTab]=useState('glance');const [ship,setShip]=useState(null);
  const open=s=>{setShip(s.name);};const cur=ship&&sim.ships.find(s=>s.name===ship);
  return <div style={{maxWidth:390,height:'100%',margin:'0 auto',background:'var(--surface-app)',display:'flex',flexDirection:'column',position:'relative'}}>
   <Header left={sim.left} leg={sim.leg}/>
   <div style={{flex:1,overflow:'auto',padding:'10px 12px 12px'}}>{cur?<Ship ship={cur} back={()=>setShip(null)}/>:tab==='glance'?<Glance sim={sim} open={open}/>:tab==='ships'?<Ships sim={sim} open={open}/>:<Records/>}</div>
   {sim.sold&&<div style={{position:'absolute',left:12,right:12,bottom:86,display:'flex',justifyContent:'center'}}><SoldToast amount={sim.sold.amt} detail={sim.sold.detail}/></div>}
   <div style={{display:'flex',borderTop:'1px solid var(--st-divider)',background:'var(--st-tabbar)'}}>{[['glance','Glance'],['ships','Ships'],['records','Records']].map(([k,l])=><button key={k} onClick={()=>{setTab(k);setShip(null)}} style={{all:'unset',flex:1,minHeight:48,padding:'8px 0 14px',display:'flex',flexDirection:'column',alignItems:'center',gap:6,cursor:'pointer',color:tab===k?'var(--text-body)':'var(--text-dim)',fontSize:13,fontWeight:500}}><span style={{width:18,height:3,borderRadius:2,background:tab===k?'var(--st-cyan)':'transparent'}}></span>{l}</button>)}</div></div>}
ReactDOM.createRoot(document.getElementById('root')).render(<App/>);
