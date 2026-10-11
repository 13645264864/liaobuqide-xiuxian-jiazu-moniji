ALTER TABLE public.fc_combat_encounters ADD COLUMN boss_ready_at timestamptz,ADD COLUMN last_damage numeric NOT NULL DEFAULT 0,ADD COLUMN last_incoming numeric NOT NULL DEFAULT 0,ADD COLUMN last_critical boolean NOT NULL DEFAULT false;
CREATE OR REPLACE FUNCTION public.fc_character_combat_stats(p_character uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE c public.fc_characters; s jsonb; k text; power numeric;
BEGIN
 SELECT * INTO c FROM public.fc_characters WHERE id=p_character;
 s:=public.fc_base_stats(c.realm_index,c.realm_layer,c.realm_grade);
 FOREACH k IN ARRAY ARRAY['health','mana','attack','defense','speed','consciousness_max'] LOOP s:=jsonb_set(s,ARRAY[k],to_jsonb(round((s->>k)::numeric+coalesce((c.expansion_stats->>k)::numeric,0)+coalesce((c.legacy_grade_stats->>k)::numeric,0)+coalesce((public.fc_equipment_stats(c.id)->>k)::numeric,0),2))); END LOOP;
 
 s:=jsonb_set(s,ARRAY['health'],to_jsonb(round((s->>'health')::numeric*(1+public.fc_manual_health(c)),2)));
 s:=public.fc_apply_family_traits(c.id,s);power:=round((s->>'health')::numeric*0.2+(s->>'mana')::numeric*0.1+(s->>'attack')::numeric*5+(s->>'defense')::numeric*3+(s->>'speed')::numeric*2);
 RETURN s||jsonb_build_object('aura_required',public.fc_aura_requirement(c.realm_index,c.realm_layer),'aura_points',round(c.cultivation/100*public.fc_aura_requirement(c.realm_index,c.realm_layer),2),'aura_limit',c.capacity/100*public.fc_aura_requirement(c.realm_index,c.realm_layer),'aura_rate',public.fc_aura_rate(c.realm_index),'power',power,'mind',c.mind,'consciousness',round(c.consciousness,2),'effects',public.fc_mind_effects(c.mind),'expansion_stats',c.expansion_stats);
END $function$;
REVOKE ALL ON FUNCTION public.fc_character_combat_stats(uuid) FROM PUBLIC,authenticated,anon;
CREATE OR REPLACE FUNCTION public.fc_get_combat()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE c public.fc_characters; e public.fc_combat_encounters; m public.fc_monster_definitions; current_room uuid; safe boolean;stats jsonb;inventory jsonb;skills jsonb;
BEGIN SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid(); SELECT r.id,r.is_safe_city INTO current_room,safe FROM public.fc_character_positions p JOIN public.fc_world_cells cell ON cell.id=p.cell_id JOIN public.fc_world_rooms r ON r.id=cell.room_id WHERE p.character_id=c.id; IF coalesce(safe,true) THEN RETURN jsonb_build_object('active',false); END IF; SELECT * INTO e FROM public.fc_combat_encounters WHERE character_id=c.id AND room_id=current_room AND status IN ('active','won','lost') AND (status='active' OR tick_at>now()-interval '30 seconds') ORDER BY created_at DESC LIMIT 1; IF e.id IS NULL THEN RETURN jsonb_build_object('active',false); END IF; SELECT * INTO m FROM public.fc_monster_definitions WHERE id=e.monster_id; stats:=public.fc_character_combat_stats(c.id);inventory:=(SELECT coalesce(jsonb_agg(jsonb_build_object('key',item_key,'name',item_name,'quantity',quantity)),'[]'::jsonb) FROM public.fc_inventory_slots WHERE character_id=c.id AND item_key IN('fire_talisman_'||c.realm_index,'thunder_talisman_'||c.realm_index,'health_pill_'||c.realm_index,'mana_pill_'||c.realm_index));skills:=(SELECT coalesce(jsonb_agg(jsonb_build_object('id',d.id,'name',d.name,'category',d.category,'slot',k.slot,'enhanced',k.enhanced,'effects',CASE WHEN k.enhanced THEN d.enhanced_effects ELSE d.effects END)),'[]'::jsonb) FROM public.fc_known_skills k JOIN public.fc_skill_definitions d ON d.id=k.skill_id WHERE k.character_id=c.id AND k.slot IS NOT NULL AND (d.source='breakthrough' OR d.source='family' AND d.realm_required=c.realm_index OR d.source='boss' AND d.realm_required<=c.realm_index));RETURN jsonb_build_object('active',e.status='active','encounter',to_jsonb(e),'monster',to_jsonb(m),'player_realm',c.realm,'player_name',c.display_name,'player_avatar_key',c.avatar_key,'player_realm_index',c.realm_index,'player_stats',stats,'items',inventory,'skills',skills); END $function$;
CREATE OR REPLACE FUNCTION public.fc_resolve_combat(p_action text DEFAULT 'auto'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE c public.fc_characters; e public.fc_combat_encounters; m public.fc_monster_definitions; stats jsonb; damage numeric; incoming numeric; alive integer; crit boolean; sword boolean; hits numeric:=1; spirit_cost numeric; mana_cost numeric; skill_log text:=''; stun boolean:=false; skill_effects jsonb; skill_hp numeric; skill_mana numeric;
BEGIN
 SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE;
 IF c.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 SELECT * INTO e FROM public.fc_combat_encounters WHERE character_id=c.id AND status='active' LIMIT 1 FOR UPDATE;
 IF e.id IS NULL THEN RETURN public.fc_get_combat(); END IF;
 IF now()-e.tick_at<interval '1 second' THEN RETURN public.fc_get_combat(); END IF;
 SELECT * INTO m FROM public.fc_monster_definitions WHERE id=e.monster_id;
 IF m.is_boss AND e.turn%m.boss_cooldown=0 THEN
 IF e.boss_ready_at IS NULL THEN UPDATE public.fc_combat_encounters SET boss_ready_at=now()+interval '2 seconds',battle_log=battle_log||jsonb_build_array('Boss蓄力：'||m.boss_skill||'，2秒后发动！') WHERE id=e.id;RETURN public.fc_get_combat();END IF;
 IF e.boss_ready_at>now() THEN RETURN public.fc_get_combat();END IF;
 END IF;
 stats:=public.fc_get_attributes()||jsonb_build_object('realm_index',c.realm_index); crit:=random()<0.05;
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
 IF m.is_boss AND e.turn%m.boss_cooldown=0 THEN incoming:=incoming*m.boss_damage;skill_log:=skill_log||' Boss专属战技·'||m.boss_skill;END IF;
 skill_effects:=public.fc_skill_tick(c.id,stats,to_jsonb(m),e.skill_runtime,e.player_health,e.player_mana,e.turn,incoming,e.monster_health,m.base_health*e.monster_count,greatest(1,ceil(e.monster_health/m.base_health)::integer));
 damage:=damage+(skill_effects->>'damage')::numeric;incoming:=CASE WHEN damage>=e.monster_health THEN 0 ELSE (skill_effects->>'incoming')::numeric END;skill_hp:=(skill_effects->>'health')::numeric;skill_mana:=(skill_effects->>'mana')::numeric;
 UPDATE public.fc_combat_encounters SET tick_at=now(),turn=turn+1,boss_ready_at=NULL,last_damage=round(damage,2),last_incoming=round(incoming,2),last_critical=crit,skill_runtime=skill_effects->'runtime',player_mana=CASE WHEN hits>1 THEN greatest(0,skill_mana-mana_cost) ELSE skill_mana END,player_health=greatest(0,skill_hp-incoming),monster_health=greatest(0,monster_health-damage),battle_log=battle_log||(skill_effects->'logs')||jsonb_build_array('第'||(turn+1)||'回合：'||skill_log||' 造成'||round(damage)||'伤害，妖兽造成'||round(incoming)||'伤害。') WHERE id=e.id RETURNING * INTO e;
 IF e.monster_health<=0 THEN
  PERFORM public.fc_inventory_add(c.id,'hide_'||m.realm_index,(ARRAY['练气','筑基','金丹','元婴','出窍','化神'])[m.realm_index+1]||'妖兽皮',2*e.monster_count,'材料','妖兽掉落，炼器及功法材料。');
  PERFORM public.fc_inventory_add(c.id,'blood_'||m.realm_index,(ARRAY['练气','筑基','金丹','元婴','出窍','化神'])[m.realm_index+1]||'妖兽血',e.monster_count,'材料','妖兽掉落，炼丹及画符材料。');
  UPDATE public.fc_characters SET spirit_stones=spirit_stones+5*(m.realm_index+1)*e.monster_count,encounter_checked_at=now() WHERE id=c.id;
  UPDATE public.fc_combat_encounters SET status='won',result='胜利',battle_log=battle_log||jsonb_build_array('获得妖兽皮、妖兽血及'||(5*(m.realm_index+1)*e.monster_count)||'灵石。') WHERE id=e.id;
 ELSIF e.player_health<=0 THEN
  UPDATE public.fc_characters SET encounter_checked_at=now() WHERE id=c.id;
  UPDATE public.fc_combat_encounters SET status='lost',result='战败',battle_log=battle_log||jsonb_build_array('战败，本轮内测不扣寿元及物品。') WHERE id=e.id;
 END IF;
 RETURN public.fc_get_combat();
END $function$;
CREATE OR REPLACE FUNCTION public.fc_consume_item_internal(p_key text, p_inventory_key text DEFAULT NULL::text, p_item_realm integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE c public.fc_characters; s jsonb; e public.fc_combat_encounters; cap numeric; mid text;
BEGIN
 SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE; IF c.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 s:=public.fc_get_attributes(); SELECT * INTO e FROM public.fc_combat_encounters WHERE character_id=c.id AND status='active' LIMIT 1 FOR UPDATE;
 IF p_key='expansion_pill' THEN
  IF c.capacity>=150 THEN RAISE EXCEPTION '丹田容量已达完美圆满'; END IF;
  PERFORM public.fc_claim_cultivation(); PERFORM public.fc_inventory_take(c.id,coalesce(p_inventory_key,p_key),1); UPDATE public.fc_characters SET capacity=least(150,capacity+5) WHERE id=c.id;
 ELSIF p_key='spirit_pill' THEN
  PERFORM public.fc_inventory_take(c.id,coalesce(p_inventory_key,p_key),1); UPDATE public.fc_characters SET consciousness=least((s->>'consciousness_max')::numeric,consciousness+(s->>'consciousness_max')::numeric*0.3) WHERE id=c.id;
 ELSIF p_key='life_pill' THEN
  IF c.pill_day=current_date AND coalesce((c.daily_pills->>'life')::integer,0)>=1 THEN RAISE EXCEPTION '延寿丹每日最多一次'; END IF;
  cap:=(ARRAY[100,200,500,1000,2000,4000])[c.realm_index+1]; IF c.lifespan>=cap THEN RAISE EXCEPTION '已达当前境界寿元上限'; END IF;
  PERFORM public.fc_inventory_take(c.id,coalesce(p_inventory_key,p_key),1); UPDATE public.fc_characters SET lifespan=least(cap,lifespan+(ARRAY[5,10,20,40,80,160])[p_item_realm+1]),pill_day=current_date,daily_pills=jsonb_build_object('life',1) WHERE id=c.id;
 ELSIF p_key='lure_pill' THEN
  IF NOT EXISTS(SELECT 1 FROM public.fc_character_positions p JOIN public.fc_world_cells cell ON cell.id=p.cell_id JOIN public.fc_world_rooms r ON r.id=cell.room_id WHERE p.character_id=c.id AND NOT r.is_safe_city) OR EXISTS(SELECT 1 FROM public.fc_city_journeys WHERE character_id=c.id) THEN RAISE EXCEPTION '聚妖丹只能在野外或官道使用'; END IF;
  PERFORM public.fc_inventory_take(c.id,coalesce(p_inventory_key,p_key),1); UPDATE public.fc_characters SET lure_room=(SELECT cell.room_id FROM public.fc_character_positions p JOIN public.fc_world_cells cell ON cell.id=p.cell_id WHERE p.character_id=c.id) WHERE id=c.id;
 ELSIF p_key IN ('battle_pill','breakthrough_pill') THEN
  IF p_key='breakthrough_pill' AND c.breakthrough_boost_until>now() OR p_key='battle_pill' AND c.battle_boost_until>now() THEN RAISE EXCEPTION '丹药效果仍在生效'; END IF;
  PERFORM public.fc_inventory_take(c.id,coalesce(p_inventory_key,p_key),1); UPDATE public.fc_characters SET battle_boost_until=CASE WHEN p_key='battle_pill' THEN now()+interval '10 minutes' ELSE battle_boost_until END,breakthrough_boost_until=CASE WHEN p_key='breakthrough_pill' THEN now()+interval '1 hour' ELSE breakthrough_boost_until END WHERE id=c.id;
 ELSIF p_key IN ('health_pill','mana_pill','fire_talisman','thunder_talisman') THEN
  IF e.id IS NULL THEN RAISE EXCEPTION '此物品需要在战斗中使用'; END IF;
  IF p_key IN ('fire_talisman','thunder_talisman') AND e.player_mana<(s->>'mana')::numeric*0.05 THEN RAISE EXCEPTION '灵力不足'; END IF;
  IF p_key IN ('fire_talisman','thunder_talisman') AND e.item_at>now()-interval '8 seconds' THEN RAISE EXCEPTION '符箓冷却8秒'; END IF;
  PERFORM public.fc_inventory_take(c.id,coalesce(p_inventory_key,p_key),1);
  UPDATE public.fc_combat_encounters SET player_health=CASE WHEN p_key='health_pill' THEN least((s->>'health')::numeric,player_health+(s->>'health')::numeric*0.35) ELSE player_health END,player_mana=CASE WHEN p_key='mana_pill' THEN least((s->>'mana')::numeric,player_mana+(s->>'mana')::numeric*0.4) WHEN p_key IN ('fire_talisman','thunder_talisman') THEN player_mana-(s->>'mana')::numeric*0.05 ELSE player_mana END,monster_health=CASE WHEN p_key='fire_talisman' THEN monster_health-(s->>'attack')::numeric*3 WHEN p_key='thunder_talisman' THEN monster_health-(s->>'attack')::numeric*2.5 ELSE monster_health END,stunned_until=CASE WHEN p_key='thunder_talisman' THEN now()+interval '1 second' ELSE stunned_until END,item_at=now(),battle_log=battle_log||jsonb_build_array('使用了'||p_key) WHERE id=e.id;
 ELSIF p_key LIKE 'book_%' THEN
  mid:=substring(p_key FROM 6); IF NOT EXISTS(SELECT 1 FROM public.fc_manual_definitions WHERE id=mid) THEN RAISE EXCEPTION '无法学习该功法'; END IF;
  IF EXISTS(SELECT 1 FROM public.fc_known_manuals WHERE character_id=c.id AND manual_id=mid) THEN RAISE EXCEPTION '已经学会此功法'; END IF;
  PERFORM public.fc_inventory_take(c.id,coalesce(p_inventory_key,p_key),1); INSERT INTO public.fc_known_manuals(character_id,manual_id) VALUES(c.id,mid);
 ELSE RAISE EXCEPTION '该物品不可直接使用'; END IF;
 IF e.id IS NOT NULL AND EXISTS(SELECT 1 FROM public.fc_combat_encounters WHERE id=e.id AND status='active' AND monster_health<=0) THEN UPDATE public.fc_combat_encounters SET tick_at=now()-interval '2 seconds',boss_ready_at=now()-interval '1 second' WHERE id=e.id;PERFORM public.fc_resolve_combat('auto');END IF;
 RETURN jsonb_build_object('message','使用成功','inventory',public.fc_get_inventory());
END $function$;
