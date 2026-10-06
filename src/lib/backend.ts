import cloudbase from '@cloudbase/js-sdk';
import { validateState, type GameState } from './types';

const env = import.meta.env.VITE_CLOUDBASE_ENV_ID;
const key = import.meta.env.VITE_PUBLISHABLE_KEY;
export const configured = Boolean(env && key);
const app = configured ? cloudbase.init({env, region: 'ap-shanghai', accessKey: key, auth: {detectSessionInUrl: true}}) : null;
export const auth = app?.auth ?? null;
const registrationEndpoint = 'https://chumowujin-beta-d0faxqcq5b2c32fa-1332832013.ap-shanghai.app.tcloudbase.com/api/register';
export function credentialPassword(password:string):string {
  let hash=0x811c9dc5;
  for(const char of password.toLowerCase()){hash^=char.charCodeAt(0);hash=Math.imul(hash,16777619)}
  return `${Math.abs(hash).toString(36).padStart(8,'0')}${password.toLowerCase().slice(0,16)}Aa1!`.slice(0,32);
}
interface RpcClient {
  rpc(name: string, args?: Record<string, unknown>): Promise<{data: unknown; error: {message: string} | null}>;
}

export async function registerAccount(username:string,password:string,device:{identifier:string;platform:string}):Promise<void> {
  const response=await fetch(registrationEndpoint,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({username,password,device})});
  const value:unknown=await response.json();
  if(typeof value!=='object' || value===null || !('ok' in value) || value.ok!==true) {
    const message=typeof value==='object' && value!==null && 'message' in value && typeof value.message==='string' ? value.message : '注册未完成，请稍后重试。';
    throw new Error(message);
  }
}

export async function rpc<T>(name: string, args: Record<string, unknown> = {}): Promise<T> {
  if (!app || !auth) throw new Error('尚未配置联网环境。');
  const {data: sessionData, error: sessionError} = await auth.getSession();
  if (sessionError) throw sessionError;
  if (!sessionData?.session) throw new Error('请先登录。');
  const db = app.rdb() as unknown as RpcClient;
  const { data, error } = await db.rpc(name, args);
  if (error) throw new Error(error.message);
  return data as T;
}

export async function getState(): Promise<GameState> {
  const result: unknown = await rpc('fc_get_state');
  return validateState(result);
}
export async function getWorldState():Promise<import('./types').WorldState>{const result=await rpc<import('./types').WorldState>('fc_get_world_state');window.dispatchEvent(new CustomEvent('cultivation-safety',{detail:result.cultivation_safety}));return result}
export async function moveWorld(direction:'north'|'south'|'east'|'west'):Promise<import('./types').WorldState>{const result=await rpc<import('./types').WorldState>('fc_move_world',{p_direction:direction});window.dispatchEvent(new CustomEvent('cultivation-safety',{detail:result.cultivation_safety}));return result}

export async function listChat(channel:'world'|'family'):Promise<import('./types').ChatMessage[]> { return rpc('fc_list_chat',{p_channel:channel}); }
export async function sendChat(channel:'world'|'family',content:string):Promise<void> { await rpc('fc_send_chat',{p_channel:channel,p_content:content}); }
export async function sendAudioChat(channel:'world'|'family',audioKey:string):Promise<void> { await rpc('fc_send_chat',{p_channel:channel,p_content:'',p_message_type:'audio',p_audio_key:audioKey}); }
export async function uploadChatAudio(blob:Blob):Promise<string> {
  if(!app||!auth) throw new Error('请先登录。');
  const {data:sessionData}=await auth.getSession(); const uid=sessionData?.session?.user?.id;
  if(!uid) throw new Error('请先登录。');
  const key=`${uid}/${crypto.randomUUID()}.webm`;
  const storage=app.storage.from('chat-audio');
  const {error}=await storage.upload(key,blob,{contentType:blob.type||'audio/webm'} as never);
  if(error) throw new Error(error.message);
  return key;
}
export async function chatAudioUrl(key:string):Promise<string> {
  if(!app) throw new Error('未配置联网环境。');
  const {data,error}=await app.storage.from('chat-audio').createSignedUrl(key,3600);
  if(error) throw new Error(error.message);
  return (data as {fullSignedURL?:string;signedUrl?:string}).fullSignedURL || (data as {signedUrl?:string}).signedUrl || '';
}
export async function updateProfile(title:string,profile:string,location:string,avatarKey?:string|null):Promise<GameState>{return rpc('fc_update_profile',{p_title:title,p_profile:profile,p_location:location,p_avatar_key:avatarKey||null})}
export async function socialAction(targetId:string,action:'greet'|'friend'|'enemy'|'team'):Promise<GameState>{return rpc('fc_social_action',{p_target_id:targetId,p_action:action})}
export async function publicProfile(targetId:string):Promise<unknown>{return rpc('fc_get_public_profile',{p_target_id:targetId})}
export async function setRelationship(targetId:string,relation:'friend'|'enemy'):Promise<GameState>{return rpc('fc_set_relationship',{p_target_id:targetId,p_relation:relation})}
export async function uploadAvatar(file:File):Promise<string>{if(!app||!auth)throw new Error('请先登录。');const {data:s}=await auth.getSession();const uid=s?.session?.user?.id;if(!uid)throw new Error('请先登录。');if(file.size>2*1024*1024)throw new Error('头像不能超过 2MB。');if(!['image/png','image/jpeg','image/webp'].includes(file.type))throw new Error('头像仅支持 PNG、JPG 或 WebP。');const key=`${uid}/avatar-${crypto.randomUUID()}.${file.type.split('/')[1].replace('jpeg','jpg')}`;const {error}=await app.storage.from('avatars').upload(key,file);if(error)throw new Error(error.message);return key}
export async function signedAvatar(key:string):Promise<string>{if(!app)throw new Error('未配置联网环境。');const {data,error}=await app.storage.from('avatars').createSignedUrl(key,3600);if(error)throw new Error(error.message);return (data as {fullSignedURL?:string;signedUrl?:string}).fullSignedURL || (data as {signedUrl?:string}).signedUrl || ''}

export function errorText(error: unknown): string {
  if (error instanceof Error) return error.message;
  if (typeof error === 'object' && error !== null && 'message' in error && typeof error.message === 'string') return error.message;
  return '请求未完成，请重试。';
}
