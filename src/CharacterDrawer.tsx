import {DemonTrial,SkillChoice,type Choice} from './Skills';
import {useEffect,useState} from 'react';
import {X,ChevronDown,ChevronUp} from 'lucide-react';
import {AttributePanel} from './AttributePanel';
import {BreakthroughResult,type Trial} from './BreakthroughResult';
import {BreakthroughPanel} from './BreakthroughPanel';
import {rpc,errorText} from './lib/backend';
import {auraRequirement,type GameState} from './lib/types';
import type {InventoryState} from './StoragePage';

interface Details{base:number;extra:number;limit:number;points:number;ratio:number;remaining:number;speed:number;cultivating:boolean;factors:Array<{name:string;value:number;active:boolean}>}
export function CharacterDrawer({state,setState,setError,onClose,avatar,power}:{state:GameState;setState:(s:GameState)=>void;setError:(s:string)=>void;onClose:()=>void;avatar:string;power:number|null}){
 const [details,setDetails]=useState<Details|null>(null),[info,setInfo]=useState<'limit'|'speed'|null>(null),[result,setResult]=useState<Trial|null>(null),[demonPlaying,setDemonPlaying]=useState(false),[choice,setChoice]=useState<Choice|null>(null);
 const c=state.character!;const family=state.families.find(f=>f.id===c.family_id);
 const [pillCount,setPillCount]=useState<number|null>(null),[expansionCount,setExpansionCount]=useState<number|null>(null),[expanded,setExpanded]=useState(false);
 useEffect(()=>{let live=true;rpc<InventoryState>('fc_get_inventory').then(v=>{if(live){setPillCount(v.items.filter(i=>i.item_key==='breakthrough_pill_'+c.realm_index).reduce((sum,i)=>sum+Number(i.quantity),0));setExpansionCount(v.items.filter(i=>i.item_key==='expansion_pill_'+c.realm_index).reduce((sum,i)=>sum+Number(i.quantity),0))}}).catch(e=>{if(live)setError(errorText(e))});return()=>{live=false}},[c.id,c.last_claim_at,setError]);
 useEffect(()=>{let live=true;rpc<Details>('fc_get_cultivation_details').then(v=>{if(live)setDetails(v)}).catch(e=>{if(live)setError(errorText(e))});return()=>{live=false}},[c.id,c.realm,c.capacity,c.last_claim_at,setError]);
 const requirement=auraRequirement(c),aura=Number(c.cultivation)/100*requirement,limit=Number(c.capacity)/100*requirement;
 const ready=Number(c.cultivation)>=Number(c.capacity),capped=c.realm_index===5&&c.realm_layer===9;
 return <div className="character-backdrop" onClick={onClose}><section className="character-drawer" role="dialog" aria-modal="true" aria-label="角色信息" onClick={e=>e.stopPropagation()}>
  <header className="character-drawer-heading"><h2>角色信息</h2><button className="character-qq" title="点击复制QQ群号" onClick={()=>{void navigator.clipboard?.writeText('1126378718')}}>QQ群<br/>1126378718</button><button aria-label="关闭角色" onClick={onClose}><X size={24}/></button></header>
  <div className="character-drawer-body">
   <div className="character-identity"><div className="portrait">{avatar?<img src={avatar} alt="角色头像"/>:c.display_name.slice(0,1)}</div><div><h3>{c.display_name}<small>{c.gender==='male'?'男修':'女修'}</small></h3><p>{c.realm} · {c.realm_grade}品</p><span>{family?.name||'宗族'} · {c.title}</span></div></div>
   <div className="character-wealth"><strong>战力 {power===null?'—':power.toLocaleString('zh-CN')}</strong><span>灵石 {Number(c.spirit_stones||0).toLocaleString('zh-CN')}</span></div>
   <section className="character-cultivation"><div className="character-aura-heading"><h3>修为 <button className="info-dot" aria-label="修为上限说明" onClick={()=>setInfo('limit')}>?</button></h3><span>{aura.toFixed(2)} / {limit.toFixed(2)}</span>{ready&&!capped&&<button className="primary" aria-expanded={expanded} onClick={()=>setExpanded(v=>!v)}>突破{expanded?<ChevronUp size={14}/>:<ChevronDown size={14}/>}</button>}</div>
    <progress aria-label="修为进度" value={Math.min(Number(c.capacity),Math.max(0,Number(c.cultivation)))} max={Math.max(1,Number(c.capacity))}/>
    <div className="character-rate">吸纳灵气 {details?details.speed.toFixed(2):'读取中…'} 点/分钟 <button className="info-dot" aria-label="吸纳速度说明" onClick={()=>setInfo('speed')}>?</button></div><p className="character-aura-state">{capped?'已达化神九层':ready?'修为已满，可以突破':'修为未满，先在城内闭关修炼'}</p>
    <div className="character-pill"><strong>突破丹</strong><span>持有 {pillCount===null?'—':pillCount} 粒</span></div><p className="muted">大境界试炼成功率增加10个百分点，效果持续1小时，突破后消失；在储物中点击丹药使用。</p><div className="character-pill"><strong>扩脉丹</strong><span>持有 {expansionCount===null?'—':expansionCount} 粒 · 本小境界还能吃 {details?details.remaining:Math.max(0,Math.floor((150-Number(c.capacity))/5))} 粒</span></div><p className="muted">扩脉丹可以扩大丹田，让你存下更多灵气。“基础容量”就是当前境界、当前小层在没吃扩脉丹时，丹田最多能容纳的灵气。每颗增加这份基础容量的5%，最多增加50%，不是每颗都对吃丹后的容量再乘5%。例如原来最多存100点，吃1颗能存105点，吃满能存150点。突破前要把扩大后的丹田也修满，所以需要多吸收一些灵气；好处是突破时生命、灵力、攻击、防御、速度和神识上限会获得额外增长。扩脉越多，额外增长越多，品级系数只作用于这部分额外增长。扩脉比例会保留到下一层：下一层原本能存125点，保留5%扩脉后就能存131.25点。吃丹不会直接增加属性或提高吸纳速度，额外属性在成功突破时获得。</p>
   </section>
   {ready&&!capped&&expanded&&<BreakthroughPanel state={state} setState={setState} setError={setError} onResult={v=>{setResult(v);setDemonPlaying(Boolean(v.demon))}}/>}
   <AttributePanel refreshKey={`${c.realm}:${c.realm_grade}:${c.last_claim_at}`} setError={setError}/>
  </div>
  {info&&<div className="character-info-overlay"><section role="dialog" aria-label={info==='limit'?'修为上限构成':'吸纳速度因素'}><button aria-label="关闭说明" onClick={()=>setInfo(null)}><X/></button><h3>{info==='limit'?'修为上限构成':'吸纳速度因素'}</h3>{info==='limit'?<p>未扩脉的丹田最大灵气容量 {requirement.toFixed(2)} ＋ 扩脉额外 {(limit-requirement).toFixed(2)} ＝ 最终上限 {limit.toFixed(2)} 点。下一层按原基础阶梯计算，保留扩脉比例。</p>:details?<><p>基础速度 × 心法 × 心境 ×（1＋灵脉加成＋宗祠临时加成）</p>{details.factors.map(f=><p key={f.name}>{f.name}：{f.value} · {f.active?'已激活':'未激活'}</p>)}<p>合计 {details.speed.toFixed(2)} 点/分钟。{details.cultivating?'正在闭关吸纳':'未开始闭关，此处显示可达到的速度'}。扩脉丹不提高吸纳速度。</p></>:<p>正在读取…</p>}</section></div>}
  {result?.demon&&demonPlaying&&<DemonTrial demon={result.demon} setError={setError} onComplete={()=>setDemonPlaying(false)}/>}
  {result&&!demonPlaying&&<BreakthroughResult trial={result} onClose={()=>{if(result.choice_id&&result.candidates)setChoice({id:result.choice_id,candidates:result.candidates,grade:result.grade,realm:c.realm_index});setResult(null)}}/>}
  {choice&&<SkillChoice choice={choice} setError={setError} onClose={()=>setChoice(null)} onComplete={()=>setChoice(null)}/>}
 </section></div>;
}
