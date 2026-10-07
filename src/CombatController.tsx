import {useEffect,useRef,useState} from 'react';
import {Swords} from 'lucide-react';
import {rpc,errorText,signedAvatar} from './lib/backend';
export interface Combat {active:boolean;encounter?:{id:string;player_health:number;monster_health:number;monster_count:number;turn:number;player_mana:number;battle_log:string[];result:string|null};monster?:{name:string;image_path:string;realm_index:number;base_health:number;base_attack:number;base_defense:number;speed:number};player_name:string;player_avatar_key:string|null;player_realm:string}
export function MonsterGroup({monster,health,count}:{monster:NonNullable<Combat['monster']>;health:number;count:number}){return <div className="monster-group">{Array.from({length:Math.max(1,Math.min(3,count))},(_,i)=>{const remaining=Math.max(0,Math.min(Number(monster.base_health),health-i*Number(monster.base_health)));return <div className={remaining>0?'combatant monster':'combatant monster defeated'} key={i}><div className="combat-avatar"><img src={monster.image_path} alt={monster.name}/></div><strong>{monster.name}</strong><small>{['练气','筑基','金丹','元婴','出窍','化神'][Number(monster.realm_index)]}期</small><div className="monster-numbers"><span>生命 {Math.ceil(remaining)} / {monster.base_health}</span><span>攻击 {monster.base_attack} · 防御 {monster.base_defense}</span><span>速度 {monster.speed}</span></div></div>})}</div>}
export function CombatController({setError,inline=false,onCombatChange}:{setError:(s:string)=>void;inline?:boolean;onCombatChange?:(c:Combat|null)=>void}){
 const [combat,setCombat]=useState<Combat|null>(null),[avatar,setAvatar]=useState('');
 const current=useRef<Combat|null>(null),dismissed=useRef(sessionStorage.getItem('dismissed-combat')||'');current.current=combat;
 useEffect(()=>{let live=true;let busy=false;let checks=0;
  const tick=async()=>{if(busy)return;busy=true;try{
   let next:Combat;
   if(current.current?.active)next=await rpc<Combat>('fc_resolve_combat',{p_action:'auto'});
   else if(current.current?.encounter?.result)return;
   else {checks++;next=await rpc<Combat>(checks%5===0?'fc_spawn_combat':'fc_get_combat');}
   if(live&&next.encounter&&next.encounter.id!==dismissed.current){setCombat(next);if(next.active)window.dispatchEvent(new Event('combat-start'));}
  }catch(e){if(live)setError(errorText(e))}finally{busy=false}};
  void rpc('fc_get_manuals').catch(e=>setError(errorText(e)));void rpc('fc_claim_lure_supply').catch(e=>setError(errorText(e)));void tick();const timer=setInterval(()=>{if(document.visibilityState==='visible')void tick()},1000);
  return()=>{live=false;clearInterval(timer)};
 },[setError]);
 useEffect(()=>{let live=true;setAvatar('');if(combat?.player_avatar_key)void signedAvatar(combat.player_avatar_key).then(v=>{if(live)setAvatar(v)}).catch(e=>setError(errorText(e)));return()=>{live=false}},[combat?.player_avatar_key,setError]);
 useEffect(()=>{onCombatChange?.(combat)},[combat,onCombatChange]);
 useEffect(()=>{if(!combat?.encounter||combat.active)return;const id=combat.encounter.id;const timer=setTimeout(()=>{dismissed.current=id;sessionStorage.setItem('dismissed-combat',id);setCombat(null)},1500);return()=>clearTimeout(timer)},[combat?.active,combat?.encounter?.id]);
 const e=combat?.encounter,m=combat?.monster;
 return <>{inline&&!e&&<div className="battle-idle"><Swords size={32}/><h3>暂无战斗</h3><p>荒原与野外每5秒判定一次遭遇，城内安全。</p></div>}{e&&m&&<div className={inline?'combat-inline':'combat-backdrop'}><section className="combat-window" role="dialog" aria-label="自动战斗"><div className="combat-head"><strong>{combat?.active?'自动战斗':e.result}</strong>{!combat?.active&&<small>即将自动关闭</small>}</div><div className={combat?.active?'combat-arena battling':'combat-arena'} key={e.turn}><div className="combatant"><div className="combat-avatar">{avatar?<img src={avatar} alt="玩家头像"/>:combat?.player_name.slice(0,1)}</div><strong>{combat?.player_name}</strong><small>{combat?.player_realm} · 生命 {Math.max(0,Math.round(e.player_health))} · 灵力 {Math.max(0,Math.round(e.player_mana))}</small></div><Swords className="combat-collision"/><MonsterGroup monster={m} health={Number(e.monster_health)} count={Number(e.monster_count)}/></div><div className="combat-log">{e.battle_log?.slice(-6).map((line,i)=><p key={i}>{line}</p>)}</div></section></div>}</>;
}
