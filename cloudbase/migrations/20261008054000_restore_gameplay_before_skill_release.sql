CREATE OR REPLACE FUNCTION public.fc_base_stats(p_realm integer, p_layer integer, p_grade integer)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
SELECT jsonb_build_object('health',(ARRAY[100,500,2500,12500,62500,312500])[p_realm+1]*(1+(p_layer-1)*0.1)*(1+(p_grade-1)*0.0625),'mana',(ARRAY[100,300,900,2700,8100,24300])[p_realm+1]*(1+(p_layer-1)*0.1)*(1+(p_grade-1)*0.0625),'attack',(ARRAY[20,100,500,2500,12500,62500])[p_realm+1]*(1+(p_layer-1)*0.1)*(1+(p_grade-1)*0.0625),'defense',(ARRAY[10,50,250,1250,6250,31250])[p_realm+1]*(1+(p_layer-1)*0.1)*(1+(p_grade-1)*0.0625),'speed',(ARRAY[10,15,22,32,46,66])[p_realm+1]*(1+(p_layer-1)*0.02),'consciousness_max',(ARRAY[100,300,900,2700,8100,24300])[p_realm+1]*(1+(p_layer-1)*0.1)*(1+(p_grade-1)*0.0625),'critical_rate',5,'critical_damage',150)
$function$;
CREATE OR REPLACE FUNCTION public.fc_get_attributes()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE c public.fc_characters; s jsonb; k text; power numeric;
BEGIN
 PERFORM public.fc_recover_attributes(); SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid();
 s:=public.fc_base_stats(c.realm_index,c.realm_layer,c.realm_grade);
 FOREACH k IN ARRAY ARRAY['health','mana','attack','defense','speed','consciousness_max'] LOOP s:=jsonb_set(s,ARRAY[k],to_jsonb(round((s->>k)::numeric+coalesce((c.expansion_stats->>k)::numeric,0)+coalesce((public.fc_equipment_stats(c.id)->>k)::numeric,0),2))); END LOOP;
 s:=jsonb_set(s,ARRAY['health'],to_jsonb(round((s->>'health')::numeric*(1+public.fc_manual_health(c)),2)));
 power:=round((s->>'health')::numeric*0.2+(s->>'mana')::numeric*0.1+(s->>'attack')::numeric*5+(s->>'defense')::numeric*3+(s->>'speed')::numeric*2);
 RETURN s||jsonb_build_object('aura_required',public.fc_aura_requirement(c.realm_index,c.realm_layer),'aura_points',round(c.cultivation/100*public.fc_aura_requirement(c.realm_index,c.realm_layer),2),'aura_limit',c.capacity/100*public.fc_aura_requirement(c.realm_index,c.realm_layer),'aura_rate',public.fc_aura_rate(c.realm_index),'power',power,'mind',c.mind,'consciousness',round(c.consciousness,2),'effects',public.fc_mind_effects(c.mind),'expansion_stats',c.expansion_stats);
END $function$;
CREATE OR REPLACE FUNCTION public.fc_character_power(c fc_characters)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
 SELECT round(((s->>'health')::numeric+coalesce((c.expansion_stats->>'health')::numeric,0)+coalesce((e->>'health')::numeric,0))*(1+public.fc_manual_health(c))*0.2+((s->>'mana')::numeric+coalesce((c.expansion_stats->>'mana')::numeric,0)+coalesce((e->>'mana')::numeric,0))*0.1+((s->>'attack')::numeric+coalesce((c.expansion_stats->>'attack')::numeric,0)+coalesce((e->>'attack')::numeric,0))*5+((s->>'defense')::numeric+coalesce((c.expansion_stats->>'defense')::numeric,0)+coalesce((e->>'defense')::numeric,0))*3+((s->>'speed')::numeric+coalesce((c.expansion_stats->>'speed')::numeric,0)+coalesce((e->>'speed')::numeric,0))*2) FROM public.fc_base_stats(c.realm_index,c.realm_layer,c.realm_grade) s,public.fc_equipment_stats(c.id) e
$function$;
CREATE OR REPLACE FUNCTION public.fc_recover_attributes()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE c public.fc_characters; elapsed numeric; max_spirit numeric; effects jsonb; hours integer; gain integer;
BEGIN
 SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE; IF c.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 elapsed:=least(720,greatest(0,extract(epoch FROM(now()-c.recovery_at))/60));
 max_spirit:=(public.fc_base_stats(c.realm_index,c.realm_layer,c.realm_grade)->>'consciousness_max')::numeric+coalesce((c.expansion_stats->>'consciousness_max')::numeric,0)+coalesce((public.fc_equipment_stats(c.id)->>'consciousness_max')::numeric,0);
 effects:=public.fc_mind_effects(c.mind);
 UPDATE public.fc_characters SET consciousness=least(max_spirit,consciousness+elapsed*max_spirit*0.01*(effects->>'recovery')::numeric),recovery_at=now() WHERE id=c.id;
END $function$;
CREATE OR REPLACE FUNCTION public.fc_resolve_combat(p_action text DEFAULT 'auto'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE c public.fc_characters; e public.fc_combat_encounters; m public.fc_monster_definitions; stats jsonb; damage numeric; incoming numeric; alive integer; crit boolean; sword boolean; hits numeric:=1; spirit_cost numeric; mana_cost numeric; skill_log text:=''; stun boolean:=false;
BEGIN
 SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE;
 IF c.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 SELECT * INTO e FROM public.fc_combat_encounters WHERE character_id=c.id AND status='active' LIMIT 1 FOR UPDATE;
 IF e.id IS NULL THEN RETURN public.fc_get_combat(); END IF;
 IF now()-e.tick_at<interval '1 second' THEN RETURN public.fc_get_combat(); END IF;
 SELECT * INTO m FROM public.fc_monster_definitions WHERE id=e.monster_id;
 stats:=public.fc_get_attributes(); crit:=random()<0.05;
 sword:=EXISTS(SELECT 1 FROM public.fc_equipment_instances WHERE character_id=c.id AND equipped_slot='weapon');
 damage:=greatest(1,(stats->>'attack')::numeric-m.base_defense*0.35)*(CASE WHEN crit THEN 1.5 ELSE 1 END);
 IF sword AND c.equipped_art IN ('nameless_sword','family_sword') THEN
  damage:=damage*CASE c.equipped_art WHEN 'nameless_sword' THEN 2 ELSE 2.2 END;
  mana_cost:=(stats->>'mana')::numeric*0.05;
  IF (e.turn+1)%3=0 AND e.player_mana>=mana_cost THEN hits:=CASE c.equipped_art WHEN 'nameless_sword' THEN 1.8 ELSE 1.95 END; skill_log:=' 三连斩'; END IF;
 ELSIF c.equipped_art='weapon_basics' THEN damage:=damage*1.3;
 END IF;
 damage:=damage*hits*CASE WHEN c.battle_boost_until>now() THEN 1.25 ELSE 1 END;
 spirit_cost:=(stats->>'consciousness_max')::numeric*0.1;
 IF c.equipped_spell='spirit_stun' AND e.turn%4=0 AND c.consciousness>=spirit_cost THEN
  damage:=damage+(stats->>'attack')::numeric*0.4; stun:=true; skill_log:=skill_log||' 震魂：眩晕1秒';
  UPDATE public.fc_characters SET consciousness=consciousness-spirit_cost WHERE id=c.id;
 END IF;
 alive:=greatest(0,ceil(greatest(0,e.monster_health-damage)/m.base_health)::integer);
 incoming:=CASE WHEN alive=0 OR stun OR e.stunned_until>e.tick_at THEN 0 ELSE greatest(1,m.base_attack-(stats->>'defense')::numeric*0.25)*(1+0.35*(alive-1)) END;
 UPDATE public.fc_combat_encounters SET tick_at=now(),turn=turn+1,player_mana=CASE WHEN hits>1 THEN greatest(0,player_mana-mana_cost) ELSE player_mana END,player_health=greatest(0,player_health-incoming),monster_health=greatest(0,monster_health-damage),battle_log=battle_log||jsonb_build_array('第'||(turn+1)||'回合：'||skill_log||' 造成'||round(damage)||'伤害，妖兽造成'||round(incoming)||'伤害。') WHERE id=e.id RETURNING * INTO e;
 IF e.monster_health<=0 THEN
  PERFORM public.fc_inventory_add(c.id,'hide_'||m.realm_index,(ARRAY['练气','筑基','金丹'])[m.realm_index+1]||'妖兽皮',2*e.monster_count,'材料','妖兽掉落，炼器及功法材料。');
  PERFORM public.fc_inventory_add(c.id,'blood_'||m.realm_index,(ARRAY['练气','筑基','金丹'])[m.realm_index+1]||'妖兽血',e.monster_count,'材料','妖兽掉落，炼丹及画符材料。');
  UPDATE public.fc_characters SET spirit_stones=spirit_stones+5*(m.realm_index+1)*e.monster_count,encounter_checked_at=now() WHERE id=c.id;
  UPDATE public.fc_combat_encounters SET status='won',result='胜利',battle_log=battle_log||jsonb_build_array('获得妖兽皮、妖兽血及'||(5*(m.realm_index+1)*e.monster_count)||'灵石。') WHERE id=e.id;
 ELSIF e.player_health<=0 THEN
  UPDATE public.fc_characters SET encounter_checked_at=now() WHERE id=c.id;
  UPDATE public.fc_combat_encounters SET status='lost',result='战败',battle_log=battle_log||jsonb_build_array('战败，本轮内测不扣寿元及物品。') WHERE id=e.id;
 END IF;
 RETURN public.fc_get_combat();
END $function$;
CREATE OR REPLACE FUNCTION public.fc_breakthrough(p_grade integer DEFAULT 1, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$

DECLARE v_me public.fc_characters; v_uid text:=public.fc_require_uid(); v_result jsonb; v_major boolean; v_chance numeric; v_roll numeric; v_win boolean; v_extra numeric; v_realms text[]:=ARRAY['练气','筑基','金丹','元婴','出窍','化神']; v_layers text[]:=ARRAY['一','二','三','四','五','六','七','八','九']; v_log jsonb:='[]'::jsonb; v_old jsonb; v_new jsonb; v_bonus jsonb; v_changes jsonb:='{}'::jsonb; k text; v_delta numeric; v_extra_delta numeric;

BEGIN

 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid FOR UPDATE;

 IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;

 IF p_request_id IS NULL THEN RAISE EXCEPTION '缺少突破请求标识'; END IF;

 SELECT result INTO v_result FROM public.fc_breakthrough_records WHERE id=p_request_id AND character_id=v_me.id;

 IF v_result IS NOT NULL THEN RETURN jsonb_build_object('state',public.fc_get_state(),'trial',v_result); END IF;

 IF EXISTS(SELECT 1 FROM public.fc_breakthrough_records WHERE id=p_request_id) THEN RAISE EXCEPTION '请求标识无效'; END IF;

 IF p_grade NOT BETWEEN 1 AND 9 THEN RAISE EXCEPTION '品级必须在一至九品之间'; END IF;

 IF v_me.realm_index=5 AND v_me.realm_layer=9 THEN RAISE EXCEPTION '化神九层已达当前开放上限'; END IF;

 IF v_me.cultivation<v_me.capacity THEN RAISE EXCEPTION '修为不足本层突破上限'; END IF;

 IF v_me.lifespan<=1 THEN RAISE EXCEPTION '寿元不足，无法承受突破'; END IF;

 v_major:=v_me.realm_layer=9;

 v_extra:=v_me.expansion_ratio*100;

 IF v_major THEN
  UPDATE public.fc_characters SET breakthrough_boost_until=NULL WHERE id=v_me.id;

  v_chance:=greatest(5,least(95,70+CASE WHEN v_me.breakthrough_boost_until>now() THEN 10 ELSE 0 END+(public.fc_mind_effects(v_me.mind)->>'breakthrough_bonus')::numeric-(p_grade-1)*7+v_extra*0.8-(100-v_me.foundation)*0.5));

  v_roll:=random()*100;v_win:=v_roll<v_chance;

  v_log:=jsonb_build_array('你以'||v_me.realm||'的修为迎战'||p_grade||'品判定妖魔。','修为上限 '||v_me.cultivation||'/'||v_me.capacity||'，道基 '||v_me.foundation||'%，本次胜率 '||v_chance||'%。');

 ELSE

  v_chance:=100;v_win:=true;

  v_log:=jsonb_build_array('灵气运转周天，冲击下一层修为。');

 END IF;

 IF v_win THEN

  v_old:=public.fc_base_stats(v_me.realm_index,v_me.realm_layer,v_me.realm_grade);

  v_new:=public.fc_base_stats(CASE WHEN v_major THEN v_me.realm_index+1 ELSE v_me.realm_index END,CASE WHEN v_major THEN 1 ELSE v_me.realm_layer+1 END,CASE WHEN v_major THEN p_grade ELSE v_me.realm_grade END);

  v_bonus:=v_me.expansion_stats;
  v_changes:=jsonb_build_object('base',jsonb_build_object(),'expansion',jsonb_build_object());
  FOREACH k IN ARRAY ARRAY['health','mana','attack','defense','speed','consciousness_max'] LOOP
   v_delta:=greatest(0,(v_new->>k)::numeric-(v_old->>k)::numeric);
   v_extra_delta:=v_delta*v_extra/100;
   v_bonus:=jsonb_set(v_bonus,ARRAY[k],to_jsonb(coalesce((v_bonus->>k)::numeric,0)+v_extra_delta));
   v_changes:=jsonb_set(v_changes,ARRAY['base',k],to_jsonb(round(v_delta,2)));
   v_changes:=jsonb_set(v_changes,ARRAY['expansion',k],to_jsonb(round(v_extra_delta,2)));
  END LOOP;
  UPDATE public.fc_characters SET expansion_stats=v_bonus WHERE id=v_me.id;

  IF v_major THEN
  UPDATE public.fc_characters SET breakthrough_boost_until=NULL WHERE id=v_me.id;

   UPDATE public.fc_characters SET mind=least(100,mind+5),realm_index=realm_index+1,realm_layer=1,realm_grade=p_grade,realm=v_realms[v_me.realm_index+2]||'一层',cultivation=0,last_claim_at=now(),attribute_bonus=attribute_bonus+v_extra,lifespan=lifespan+(ARRAY[100,300,500,1000,2000])[v_me.realm_index+1] WHERE id=v_me.id;

   v_log:=v_log||jsonb_build_array('击败判定妖魔，突破至'||v_realms[v_me.realm_index+2]||'一层，定为'||p_grade||'品。');

  ELSE

   UPDATE public.fc_characters SET realm_layer=realm_layer+1,realm=v_realms[v_me.realm_index+1]||v_layers[v_me.realm_layer+1]||'层',cultivation=greatest(0,v_me.cultivation-v_me.capacity)*public.fc_aura_requirement(v_me.realm_index,v_me.realm_layer)/public.fc_aura_requirement(v_me.realm_index,v_me.realm_layer+1),last_claim_at=now(),attribute_bonus=attribute_bonus+v_extra WHERE id=v_me.id;

   v_log:=v_log||jsonb_build_array('剩余灵气 '||round(greatest(0,v_me.cultivation-v_me.capacity)/100*public.fc_aura_requirement(v_me.realm_index,v_me.realm_layer),2)||' 点流入下一层。突破成功：'||v_realms[v_me.realm_index+1]||v_layers[v_me.realm_layer+1]||'层。');

  END IF;

 ELSE

  UPDATE public.fc_characters SET cultivation=greatest(0,cultivation-capacity*0.5),lifespan=greatest(1,lifespan-5),foundation=greatest(0,foundation-CASE WHEN p_grade>=7 THEN 5 ELSE 2 END),last_claim_at=now() WHERE id=v_me.id;

  v_log:=v_log||jsonb_build_array('妖魔压制了你的突破：损失本层所需灵气的50%、5年寿元，道基减少'||CASE WHEN p_grade>=7 THEN 5 ELSE 2 END||'点，境界保持不变。');

 END IF;

 v_result:=jsonb_build_object('success',v_win,'major',v_major,'grade',CASE WHEN v_major THEN p_grade ELSE v_me.realm_grade END,'chance',v_chance,'log',v_log,'changes',CASE WHEN v_win THEN v_changes ELSE '{}'::jsonb END);

 INSERT INTO public.fc_breakthrough_records(id,character_id,result) VALUES(p_request_id,v_me.id,v_result);

 INSERT INTO public.fc_notices(character_id,body) VALUES(v_me.id,v_log->>(jsonb_array_length(v_log)-1));

 RETURN jsonb_build_object('state',public.fc_get_state(),'trial',v_result);

END $function$;
DROP TRIGGER IF EXISTS guard_trial_movement ON public.fc_character_positions;
DELETE FROM public.fc_trial_locks;
DO $$ DECLARE d text;BEGIN d:=pg_get_functiondef('public.fc_spawn_combat()'::regprocedure);d:=replace(d,'IF EXISTS(SELECT 1 FROM public.fc_trial_locks WHERE character_id=c.id AND expires_at>now()) THEN RETURN jsonb_build_object(''active'',false);END IF; ','');EXECUTE d;END $$;