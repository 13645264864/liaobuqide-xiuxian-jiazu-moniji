import {rpc} from './backend';
export async function gatherForTenSeconds<T>(kind:string,onCountdown?:(seconds:number)=>void):Promise<T>{
 const started=await rpc<{kind:string;duration:number}>('fc_begin_gather',{p_kind:kind});
 const end=Date.now()+10000;onCountdown?.(10);
 await new Promise<void>(resolve=>{const timer=setInterval(()=>{const seconds=Math.max(0,Math.ceil((end-Date.now())/1000));onCountdown?.(seconds);if(seconds===0){clearInterval(timer);resolve()}},200)});
 return rpc<T>('fc_gather',{p_kind:started.kind});
}
