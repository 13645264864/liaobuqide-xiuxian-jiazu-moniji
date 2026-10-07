import {useEffect,useRef,useState} from 'react';import {rpc,errorText,getWorldState} from './lib/backend';import type {WorldState} from './lib/types';import type {Combat} from './CombatController';
export function AutoGather({familyId,combat,setError}:{familyId:string;combat:Combat|null;setError:(s:string)=>void}){
 const [requested,setRequested]=useState(false);
 const [world,setWorld]=useState<WorldState|null>(null),[paused,setPaused]=useState<string|null>(null),[remaining,setRemaining]=useState(0);const token=useRef(0);const combatRef=useRef(combat);combatRef.current=combat;const roomId=useRef<string|null>(null);
 const cancelServerGather=()=>{void rpc('fc_cancel_gather').catch(()=>undefined)};
 useEffect(()=>{let live=true;const update=(next:WorldState)=>{if(!live)return;if(roomId.current!==null&&roomId.current!==next.room.id||next.journey){token.current++;setRequested(false);setPaused(null);setRemaining(0)}roomId.current=next.room.id;setWorld(next)};void getWorldState().then(update).catch(e=>setError(errorText(e)));const changed=(e:Event)=>update((e as CustomEvent<WorldState>).detail);window.addEventListener('world-position',changed);return()=>{live=false;cancelServerGather();window.removeEventListener('world-position',changed)}},[setError]);
 const room=world?.room;const eligible=Boolean(room&&!world?.journey&&((['forest','wilderness'].includes(room.kind)&&room.family_id==null)||room.family_id===familyId&&room.mine_level));
 useEffect(()=>{const start=()=>{if(!eligible){setError('此处不能采集，请前往本族灵矿或野外。');return}setPaused(null);setRequested(true)};window.addEventListener('auto-gather-start',start);return()=>window.removeEventListener('auto-gather-start',start)},[eligible,setError]);
 useEffect(()=>{
  if(!requested||!eligible||!room||paused===room.id||combat?.active)return;
  const run=++token.current;let timer:ReturnType<typeof setInterval>|undefined,finishWait:(()=>void)|undefined;
  const current=()=>run===token.current;
  const wait=(duration:number)=>new Promise<void>(resolve=>{finishWait=resolve;const end=Date.now()+duration;setRemaining(Math.ceil(duration/1000));timer=setInterval(()=>{const seconds=Math.max(0,Math.ceil((end-Date.now())/1000));if(current())setRemaining(seconds);if(!current()||seconds===0){clearInterval(timer);timer=undefined;finishWait=undefined;resolve()}},200)});
  const loop=async()=>{while(current()&&!combatRef.current?.active){try{
   const start=await rpc<{kind:string}>('fc_begin_gather',{p_kind:'auto'});if(!current())return;
   await wait(10200);if(!current()||combatRef.current?.active)return;
   const result=await rpc<{message:string}>('fc_gather',{p_kind:start.kind});if(!current())return;setError(result.message);
   // Allow the combat poll to pick up a newly created herb guardian.
   if(start.kind==='herb')await wait(1500);
  }catch(e){if(!current())return;const message=errorText(e);
   // Access failures stop this room; timers and interruptions are retryable.
   if(/境界不足|本族|不能采集|请前往|采集类型无效|请先入世/.test(message)){setError(message);setPaused(room.id);return}
   if(!/战斗|正在采集|等待完成|冷却/.test(message))setError(message);
   await wait(/正在采集|等待完成|冷却/.test(message)?10200:3000);
  }}};void loop();return()=>{token.current++;clearInterval(timer);finishWait?.();setRemaining(0)};
 },[requested,room?.id,eligible,paused,combat?.active,setError]);
 if(!requested||!eligible||paused===room?.id)return null;
 return <div className="auto-gather-status" role="status"><span>{combat?.active?'正在采集中… 战斗后继续':`正在采集中…${remaining>0?` ${remaining}秒`:''}`}</span><button onClick={()=>{cancelServerGather();token.current++;setRequested(false);setPaused(room!.id);setRemaining(0)}}>取消采集</button></div>;
}
