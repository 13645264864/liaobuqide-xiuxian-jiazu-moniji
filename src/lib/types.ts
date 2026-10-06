export interface Character {
  cultivating:boolean;cultivating_since:string|null;
  equipped_mind?:string;
  spirit_stones:number;id: string; display_name: string; gender: 'male'|'female'; root: string;
  registration_order: number; family_id: string; is_founder: boolean;
  parent_a: string|null; parent_b: string|null; cultivation: number; capacity: number;
  realm_index:number;realm_layer:number;realm_grade:number;attribute_bonus:number;realm: string; lifespan: number; foundation: number; last_claim_at: string; worship_until: string|null; worship_bonus: number; title:string; profile:string; location:string; avatar_key:string|null;
}
export interface Family {
  id: string; name: string; description: string; leader_id: string;
  prestige: number; level: number; members: number; open_slots: number;
  accept_random: boolean; gender_filter: string; root_filter: string;
}
export interface Relative { id: string; display_name: string; role: string; family_name: string; deceased: boolean }
export interface Person {id: string; display_name: string; gender: string; family_name: string; married: boolean}
export interface Invitation {id:string; proposer_name:string; proposer_id:string; target_id:string; status:string}
export interface BirthSlot {id:string; marriage_id:string; parent_a_name:string; parent_b_name:string; family_ids:string[]; slot_type:string; family_names:string[]}
export interface BirthApproval {id:string; parent_a:string; parent_b:string; approved_a:boolean; approved_b:boolean; status:string}
export interface Notice {id:string; body:string; created_at:string}
export interface ChatMessage {id:string; channel:string; content:string; message_type:'text'|'audio'; audio_key:string|null; created_at:string; sender_id:string; sender_name:string; sender_title:string; sender_realm:string; sender_cultivation:number;sender_power?:number;sender_spirit_stones?:number; sender_avatar_key:string|null}
export interface WorldState {encounter?:{id:string;monster_name:string;monster_realm_index:number;monster_layer:number;monster_count:number;monster?:{name:string}}|null;cultivation_safety?:{city_safe:boolean;can_cultivate:boolean;defense_until:string|null};atlas?:{states:Array<{id:number;name:string;ring:number;x:number;y:number}>;cities:Array<{id:number;state_id:number;name:string;x:number;y:number;founder_city:boolean}>;roads:Array<{a:number;b:number;distance:number}>};journey?:{destination:number;started_at:string;arrives_at:string;mode:string}|null;navigation?:{cells:Array<{id:string;room_id:string;x:number;y:number}>;edges:Array<{from:string;to:string;direction:"north"|"south"|"east"|"west"}>};cells?:Array<{id:string;x:number;y:number;terrain:string}>;exits?:Array<{from_cell:string;x:number;y:number;direction:string;to_room:string}>;map_rooms?:Array<{id:string;template_id?:string;family_id?:string;name:string;kind:string;description:string}>;room:{city_id?:number;id:string;state_name:string;city_name:string;name:string;kind:string;danger:number;encounter_rate:number;description:string};cell:{id:string;room_id:string;x:number;y:number;terrain:string};nearby:Array<{id:string;name:string;title:string}>}
export interface GameState {
  character: Character|null; families: Family[]; relatives: Relative[]; people: Person[];
  invitations: Invitation[]; slots: BirthSlot[]; approvals: BirthApproval[]; notices: Notice[];
  world: {registration_count:number; founder_limit:number; origin_family_id:string|null; title:string};
}
function record(value: unknown): value is Record<string, unknown> {return typeof value==='object' && value!==null && !Array.isArray(value)}
export function validateState(value: unknown): GameState {
  if (!record(value) || !record(value.world) || typeof value.world.registration_count!=='number') throw new Error('服务器返回的世界数据格式不正确。');
  for (const key of ['families','relatives','people','invitations','slots','approvals','notices']) if(!Array.isArray(value[key])) throw new Error(`服务器返回的 ${key} 格式不正确。`);
  if (value.character!==null && (!record(value.character) || typeof value.character.id!=='string')) throw new Error('服务器返回的角色格式不正确。');
  return value as unknown as GameState;
}

export function auraRequirement(c:Character):number{return [100,500,2500,12500,62500,312500][c.realm_index]*(1+(c.realm_layer-1)*0.25)}
export function auraRate(c:Character):number{return [1,4,15,50,150,400][c.realm_index]*(c.equipped_mind==='nameless_mind'&&c.realm_index<2?10:c.equipped_mind==='family_mind'?(c.realm_index<2?12:1.5):1)}

