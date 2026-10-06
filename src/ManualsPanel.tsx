import {useEffect,useState} from 'react';import {rpc,errorText} from './lib/backend';
interface Manuals{equipped_mind:string;equipped_art:string;equipped_spell:string;manuals:Array<{id:string;name:string;category:string;progress:number;description:string}>}
export function ManualsPanel({setError,onChange}:{setError:(s:string)=>void;onChange:()=>void}){
 const [data,setData]=useState<Manuals|null>(null),[busy,setBusy]=useState(false);
 useEffect(()=>{void rpc<Manuals>('fc_get_manuals').then(setData).catch(e=>setError(errorText(e)))},[setError]);
 const act=async(name:string,id:string)=>{setBusy(true);try{setData(await rpc<Manuals>(name,{p_id:id}));onChange()}catch(e){setError(errorText(e))}finally{setBusy(false)}};
 return <section className="paper-section"><h2>卷二 · 神仙妙法</h2><p className="muted">心法、战技、神识术各装备一种。研习消耗10点神识，熟练度增加10。</p>{data?.manuals.map(m=>{const equipped=[data.equipped_mind,data.equipped_art,data.equipped_spell].includes(m.id);return <article className="recipe-row" key={m.id}><h3>{m.name} {equipped?'· 已装备':''}</h3><p>{m.description}</p><p>熟练度 {m.progress}/100</p><div className="action-row"><button className="secondary" disabled={busy||equipped} onClick={()=>void act('fc_equip_manual',m.id)}>装备</button><button className="primary" disabled={busy||m.progress===100} onClick={()=>void act('fc_study_manual',m.id)}>研习</button></div></article>})}</section>;
}
