import {gatherForTenSeconds} from './lib/gather';
import {rpc,errorText} from './lib/backend';
import {useState} from 'react';import {Swords,ScrollText,Sprout} from 'lucide-react';
import {CombatController,type Combat} from './CombatController';import {auraRequirement,auraRate,type GameState} from './lib/types';
export function BattleCultivation({state,stopped,busy,setError,perform,onCombatChange,defense}:{state:GameState;stopped:boolean;busy:boolean;setError:(s:string)=>void;perform:(name:string)=>Promise<void>;onCombatChange:(c:Combat|null)=>void;defense:React.ReactNode}){
 const c=state.character!;const points=Number(c.cultivation);const capacity=Number(c.capacity);
 return <div className="home-meditation"><section className="meditation-dock"><div className="section-title"><h3><Sprout size={16}/>闭关修炼</h3><div id="meditation-chat-anchor"/><span>{c.cultivating?'闭关中':'未闭关'}</span></div>{defense}<div className="meditation-buttons"><button className="primary" disabled={busy||Boolean(c.cultivating)} onClick={()=>stopped?setError('野外闭关需要金刚阵，请返回城池或布置金刚阵。'):void perform('fc_start_meditation')}>开始闭关</button><button className="secondary" disabled={busy||!c.cultivating} onClick={()=>void perform('fc_end_meditation')}>结束闭关</button></div><div className="home-gather-buttons"><button className="secondary" disabled={busy} onClick={()=>window.dispatchEvent(new Event('auto-gather-start'))}>开始采集</button><button className="secondary" disabled={busy} onClick={()=>window.dispatchEvent(new CustomEvent('auto-farm',{detail:{realm:c.realm_index}}))}>自动刷怪</button></div></section></div>;
}
