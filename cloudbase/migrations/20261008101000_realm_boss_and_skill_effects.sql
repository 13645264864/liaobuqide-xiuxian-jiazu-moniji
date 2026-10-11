CREATE OR REPLACE FUNCTION public.fc_skill_tick(p_character uuid, p_stats jsonb, p_enemy jsonb, p_runtime jsonb, p_health numeric, p_mana numeric, p_turn integer, p_incoming numeric, p_enemy_health numeric, p_enemy_max numeric, p_enemies integer DEFAULT 1)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE runtime jsonb:=p_runtime;rec record;fx jsonb;cd integer;last_tick integer;cost numeric;atk numeric:=(p_stats->>'attack')::numeric;hpmax numeric:=(p_stats->>'health')::numeric;mpmax numeric:=(p_stats->>'mana')::numeric;health numeric:=p_health;mana numeric:=p_mana;shield numeric:=coalesce((runtime->>'shield')::numeric,0);shield_until integer:=coalesce((runtime->>'shield_until')::integer,-1);damage numeric:=0;incoming numeric:=p_incoming;amount numeric;mitigation numeric:=0;boost numeric:=0;lifesteal numeric:=0;weaken numeric:=0;is_lethal boolean;is_delayed boolean;protection numeric:=0;logs jsonb:='[]';spirit numeric;spirit_cost numeric;targets integer;stun integer;immune integer:=coalesce((runtime->>'enemy_immune_until')::integer,-1);enemy_stun integer:=coalesce((runtime->>'enemy_stun_until')::integer,-1);base_attack numeric;crossed boolean:=(p_enemy->>'realm_index')::integer=(p_stats->>'realm_index')::integer+1;has_ability boolean:=false;strong_ability boolean:=false;sword boolean; player_realm integer; trait_cost numeric;
BEGIN
 SELECT EXISTS(SELECT 1 FROM public.fc_equipment_instances WHERE character_id=p_character AND equipped_slot='weapon') INTO sword;
 SELECT realm_index INTO player_realm FROM public.fc_characters WHERE id=p_character;trait_cost:=least(.5,coalesce((public.fc_family_traits(p_character)->>'cost')::numeric,0));
 SELECT consciousness INTO spirit FROM public.fc_characters WHERE id=p_character;
 SELECT EXISTS(SELECT 1 FROM public.fc_known_skills k JOIN public.fc_skill_definitions d ON d.id=k.skill_id WHERE k.character_id=p_character AND k.slot IS NOT NULL AND d.category='ability' AND d.source='breakthrough'),EXISTS(SELECT 1 FROM public.fc_known_skills k JOIN public.fc_skill_definitions d ON d.id=k.skill_id WHERE k.character_id=p_character AND k.slot IS NOT NULL AND d.category='ability' AND d.source='breakthrough' AND k.enhanced) INTO has_ability,strong_ability;
 IF crossed AND has_ability THEN protection:=CASE WHEN strong_ability THEN .92 ELSE .85 END;damage:=damage+atk*CASE WHEN strong_ability THEN 4 ELSE 2 END;END IF;
 IF shield_until<p_turn THEN shield:=0;END IF;
 FOR rec IN SELECT d.*,k.enhanced,k.slot FROM public.fc_known_skills k JOIN public.fc_skill_definitions d ON d.id=k.skill_id WHERE k.character_id=p_character AND k.slot IS NOT NULL AND (d.source='breakthrough' OR d.source='boss' AND player_realm>=d.realm_required OR d.source='family' AND player_realm=d.realm_required) ORDER BY d.category,k.slot LOOP
  fx:=CASE WHEN rec.enhanced THEN rec.enhanced_effects ELSE rec.effects END;
  cd:=(fx->>'cooldown')::integer;is_lethal:=coalesce((fx->>'lethal')::boolean,false);is_delayed:=coalesce((fx->>'delay')::integer,0)>0;
  last_tick:=coalesce((runtime->'used'->>rec.id)::integer,-99999);
  IF p_turn-last_tick<cd OR coalesce((fx->>'sword')::boolean,false) AND NOT sword THEN CONTINUE;END IF;
  IF fx ? 'threshold' AND health/hpmax>(fx->>'threshold')::numeric THEN CONTINUE;END IF;
  IF fx ? 'min_health' AND health/hpmax<(fx->>'min_health')::numeric THEN CONTINUE;END IF;
  IF is_lethal AND (incoming<health+shield OR coalesce((runtime->>'saved')::boolean,false)) THEN CONTINUE;END IF;
  cost:=mpmax*coalesce((fx->>'cost')::numeric,0)*(1-trait_cost);spirit_cost:=(p_stats->>'consciousness_max')::numeric*coalesce((fx->>'spirit')::numeric,0);
  IF mana<cost OR spirit<spirit_cost THEN CONTINUE;END IF;
  mana:=mana-cost;spirit:=least((p_stats->>'consciousness_max')::numeric,spirit-spirit_cost+(p_stats->>'consciousness_max')::numeric*coalesce((fx->>'spirit_restore')::numeric,0));
  IF is_lethal THEN runtime:=runtime||jsonb_build_object('saved',true);health:=greatest(health,1);incoming:=0;END IF;
  runtime:=runtime||jsonb_build_object('used',coalesce(runtime->'used','{}'::jsonb)||jsonb_build_object(rec.id,p_turn));
  targets:=least(greatest(1,p_enemies),coalesce((fx->>'targets')::integer,1));
  base_attack:=greatest(1,atk-(p_enemy->>'base_defense')::numeric*.35*(1-least(.9,coalesce((fx->>'pierce')::numeric,0)+CASE WHEN crossed AND rec.category='ability' THEN CASE WHEN rec.enhanced THEN .35 ELSE .2 END ELSE 0 END)));
  amount:=base_attack*coalesce((fx->>'damage')::numeric,0)*targets*CASE WHEN crossed AND rec.category='ability' THEN CASE WHEN rec.enhanced THEN 1.8 ELSE 1.4 END ELSE 1 END;
  IF fx ? 'execute' AND p_enemy_health/p_enemy_max<.3 THEN amount:=amount*(fx->>'execute')::numeric;END IF;
  IF is_delayed THEN runtime:=runtime||jsonb_build_object('delayed',coalesce(runtime->'delayed','[]'::jsonb)||jsonb_build_array(jsonb_build_object('at',p_turn+(fx->>'delay')::integer,'damage',amount)));ELSE damage:=damage+amount;END IF;
  health:=least(hpmax,health+hpmax*coalesce((fx->>'heal')::numeric,0));mana:=least(mpmax,mana+mpmax*coalesce((fx->>'mana_restore')::numeric,0));
  IF fx ? 'shield' THEN shield:=greatest(shield,hpmax*(fx->>'shield')::numeric);shield_until:=greatest(shield_until,p_turn+coalesce((fx->>'duration')::integer,6));END IF;
  IF fx ? 'self_cost' THEN health:=greatest(1,health*(1-(fx->>'self_cost')::numeric));END IF;
  runtime:=runtime||jsonb_build_object('effects',coalesce(runtime->'effects','{}'::jsonb)||jsonb_build_object(rec.id,jsonb_build_object('until',p_turn+coalesce((fx->>'duration')::integer,1),'reduction',coalesce(fx->'reduction','0'),'boost',coalesce(fx->'boost','0'),'weaken',coalesce(fx->'weaken','0'),'lifesteal',coalesce(fx->'lifesteal','0'),'burn',coalesce(fx->'burn','0'))));
  IF fx ? 'cleanse' THEN runtime:=runtime||jsonb_build_object('cleansed_at',p_turn);END IF;
  stun:=coalesce((fx->>'stun')::integer,0);
  IF stun>0 AND immune<p_turn THEN enemy_stun:=p_turn+stun-1;immune:=enemy_stun+3;END IF;
  IF fx ? 'immunity' THEN runtime:=runtime||jsonb_build_object('immunity_until',p_turn+(fx->>'immunity')::integer);END IF;
  logs:=logs||jsonb_build_array(rec.name||CASE WHEN rec.enhanced THEN '·强化' ELSE '' END||' 发动，额外伤害'||round(amount)||'，消耗灵力'||round(cost));
 END LOOP;
 FOR rec IN SELECT value FROM jsonb_each(coalesce(runtime->'effects','{}')) LOOP
  IF (rec.value->>'until')::integer>p_turn THEN
   mitigation:=greatest(mitigation,(rec.value->>'reduction')::numeric);boost:=greatest(boost,(rec.value->>'boost')::numeric);weaken:=greatest(weaken,(rec.value->>'weaken')::numeric);lifesteal:=greatest(lifesteal,(rec.value->>'lifesteal')::numeric);
   damage:=damage+atk*(rec.value->>'burn')::numeric;
  END IF;
 END LOOP;
 FOR rec IN SELECT value FROM jsonb_array_elements(coalesce(runtime->'delayed','[]')) LOOP IF (rec.value->>'at')::integer=p_turn THEN damage:=damage+(rec.value->>'damage')::numeric;logs:=logs||jsonb_build_array('轮回印爆发');END IF;END LOOP;
 damage:=damage*(1+boost);health:=least(hpmax,health+damage*lifesteal);
 incoming:=incoming*(1-greatest(mitigation,protection))*(1-weaken);
 IF enemy_stun>=p_turn THEN incoming:=0;END IF;
 amount:=least(shield,incoming);shield:=shield-amount;incoming:=incoming-amount;
 runtime:=runtime||jsonb_build_object('shield',shield,'shield_until',shield_until,'enemy_stun_until',enemy_stun,'enemy_immune_until',immune);
 UPDATE public.fc_characters SET consciousness=greatest(0,spirit) WHERE id=p_character AND consciousness<>spirit;
 RETURN jsonb_build_object('damage',damage,'incoming',incoming,'health',health,'mana',mana,'runtime',runtime,'logs',logs);
END $function$;

DO $$ DECLARE i integer;s jsonb;factor numeric;BEGIN
FOR i IN 3..5 LOOP s:=public.fc_base_stats(i,1,1);
INSERT INTO public.fc_monster_definitions(id,name,realm_index,region_depth,base_health,base_attack,base_defense,speed,weakness,combat_note,image_path)
VALUES('wild_high_'||i,(ARRAY['练气','筑基','金丹','元婴','出窍','化神'])[i+1]||'山野灵兽',i,CASE WHEN i=3 THEN 'inner' ELSE 'core' END,(s->>'health')::numeric,(s->>'attack')::numeric*1.15,(s->>'defense')::numeric,(s->>'speed')::numeric,'战技配合','高阶普通妖兽','monsters/core_fire_qilin.png');END LOOP;
FOR i IN 0..5 LOOP
s:=public.fc_base_stats(i,9,1);factor:=1+(CASE WHEN i%2=0 THEN 6 ELSE 7 END)*.0625;
INSERT INTO public.fc_monster_definitions(id,name,realm_index,region_depth,base_health,base_attack,base_defense,speed,weakness,combat_note,image_path,is_boss,boss_skill,boss_damage,boss_cooldown)
VALUES('realm_boss_'||i,(ARRAY['练气','筑基','金丹','元婴','出窍','化神'])[i+1]||'Boss·镇山兽',i,CASE WHEN i<2 THEN 'outer' WHEN i<4 THEN 'inner' ELSE 'core' END,((s->>'health')::numeric+((s->>'health')::numeric-100)*.5*factor)*1.3,((s->>'attack')::numeric+((s->>'attack')::numeric-20)*.5*factor)*1.1,(s->>'defense')::numeric+((s->>'defense')::numeric-10)*.5*factor,(s->>'speed')::numeric,'建议同境界高层修士准备装备与神通','专属战技：镇岳斩，定期爆发','monsters/core_blood_serpent.png',true,'镇岳斩',2.5,10);
END LOOP;END $$;
CREATE OR REPLACE FUNCTION public.fc_spawn_combat()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE c public.fc_characters; p public.fc_character_positions; cell public.fc_world_cells; r public.fc_world_rooms; e public.fc_combat_encounters; m public.fc_monster_definitions; allowed integer;
BEGIN
 SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE;
 IF EXISTS(SELECT 1 FROM public.fc_trial_locks WHERE character_id=c.id AND expires_at>now()) THEN RETURN jsonb_build_object('active',false);END IF; SELECT * INTO p FROM public.fc_character_positions WHERE character_id=c.id;
 SELECT * INTO cell FROM public.fc_world_cells WHERE id=p.cell_id;
 SELECT * INTO r FROM public.fc_world_rooms WHERE id=cell.room_id;
 IF r.is_safe_city OR r.kind NOT IN ('wilderness','forest','road') THEN RETURN public.fc_get_combat(); END IF;
 -- While a gathering timer is running, no ordinary encounter may be rolled.
 IF c.gathering_kind='herb' AND c.gathering_room=r.id AND c.gathering_started_at>now()-interval '30 seconds' THEN RETURN public.fc_get_combat(); END IF;
 SELECT * INTO e FROM public.fc_combat_encounters WHERE character_id=c.id AND status='active' LIMIT 1;
 IF e.id IS NOT NULL THEN RETURN public.fc_get_combat(); END IF;
 IF EXISTS(SELECT 1 FROM public.fc_city_journeys WHERE character_id=c.id) THEN RETURN jsonb_build_object('active',false); END IF;
 IF now()-c.encounter_checked_at<interval '5 seconds' THEN RETURN jsonb_build_object('active',false); END IF;
 UPDATE public.fc_characters SET encounter_checked_at=now() WHERE id=c.id;
 IF random()>(CASE WHEN c.lure_room=r.id THEN 1 ELSE r.encounter_rate END) THEN RETURN jsonb_build_object('active',false); END IF;
 allowed:=CASE WHEN r.region_depth='inner' THEN 3 WHEN r.region_depth='core' THEN 5 ELSE 1 END;
 IF r.kind='forest' AND random()<.10 THEN SELECT * INTO m FROM public.fc_monster_definitions WHERE is_boss AND region_depth=CASE WHEN r.region_depth='inner' THEN 'inner' WHEN r.region_depth='core' THEN 'core' ELSE 'outer' END AND realm_index<=least(allowed,c.realm_index+1) ORDER BY random() LIMIT 1; ELSE SELECT * INTO m FROM public.fc_monster_definitions WHERE NOT is_boss AND region_depth=CASE WHEN r.region_depth='inner' THEN 'inner' WHEN r.region_depth='core' THEN 'core' ELSE 'outer' END AND realm_index<=least(allowed,c.realm_index+1) ORDER BY random() LIMIT 1;END IF;
 IF m.id IS NULL THEN RETURN jsonb_build_object('active',false); END IF;
 INSERT INTO public.fc_combat_encounters(character_id,room_id,monster_id,monster_count,player_health,monster_health) VALUES(c.id,r.id,m.id,CASE WHEN m.is_boss THEN 1 ELSE 1+floor(random()*3)::int END,(public.fc_get_attributes()->>'health')::numeric,m.base_health) RETURNING * INTO e;
 RETURN public.fc_get_combat();
END $function$;
CREATE OR REPLACE FUNCTION public.fc_finish_gather_internal(p_kind text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE c public.fc_characters; r public.fc_world_rooms; tier integer; roll numeric; m public.fc_monster_definitions; message text; herb_name text; eid uuid;
BEGIN
 SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE;
 IF c.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 SELECT room.* INTO r FROM public.fc_character_positions p JOIN public.fc_world_cells cell ON cell.id=p.cell_id JOIN public.fc_world_rooms room ON room.id=cell.room_id WHERE p.character_id=c.id;
 IF EXISTS(SELECT 1 FROM public.fc_city_journeys WHERE character_id=c.id) OR EXISTS(SELECT 1 FROM public.fc_combat_encounters WHERE character_id=c.id AND status='active') THEN RAISE EXCEPTION '旅行或战斗中不能采集'; END IF;
 IF c.gathering_at>now()-interval '10 seconds' THEN RAISE EXCEPTION '采集冷却10秒'; END IF;
 IF p_kind='ore' THEN
  IF r.family_id IS DISTINCT FROM c.family_id OR r.mine_level IS NULL THEN RAISE EXCEPTION '请前往本族灵矿的对应矿层'; END IF;
  IF c.realm_index<(r.mine_level-1)*2 THEN RAISE EXCEPTION '境界不足'; END IF;
  roll:=random();tier:=(r.mine_level-1)*2;
  IF roll<0.4 THEN NULL; ELSIF roll<0.5 THEN tier:=tier+1; ELSE tier:=-1; END IF;
  IF tier=-1 THEN PERFORM public.fc_inventory_add(c.id,'waste_ore','废矿与碎石',1,'杂物','采矿所得，无装备制作价值。');message:='采到了废矿与碎石。';
  ELSE message:=(ARRAY['练气','筑基','金丹','元婴','出窍','化神'])[tier+1]||'灵矿石'; PERFORM public.fc_inventory_add(c.id,'ore_'||tier,message,1,'材料','宗族矿层产出，装备材料。');message:='获得1份'||message; END IF;
 ELSIF p_kind='herb' THEN
  IF r.kind NOT IN ('forest','wilderness') OR r.is_safe_city THEN RAISE EXCEPTION '灵草采集请前往野外刷怪区'; END IF;
  IF r.kind='wilderness' THEN
   IF c.realm_index<0 THEN RAISE EXCEPTION '境界不足'; END IF;
   IF random()>=0.20 THEN message:='荒原灵草稀少，本次没有找到练气灵草。'; IF p_kind='herb' AND random()<.10 THEN PERFORM public.fc_inventory_add(c.id,'bamboo_seed','竹子种子',1,'种子','可种在本族灵田，10分钟成熟。');message:=message||' 获得1颗竹子种子。';END IF; UPDATE public.fc_characters SET gathering_at=now() WHERE id=c.id; RETURN jsonb_build_object('message',message,'workshop',public.fc_get_workshop()); END IF;
   tier:=0;
  END IF;
  IF r.kind<>'wilderness' THEN tier:=CASE r.region_depth WHEN 'inner' THEN 2 WHEN 'core' THEN 4 ELSE 0 END; ELSE tier:=0; END IF;
  IF c.realm_index<tier THEN RAISE EXCEPTION '境界不足，无法进入本区域采集'; END IF;
  roll:=random();
  IF r.kind='wilderness' THEN roll:=0.0; END IF;
  IF roll>=0.5 THEN message:='未找到可采灵草，只有枯草。';
  ELSE
   IF roll>=0.4 THEN tier:=tier+1; END IF;
   SELECT * INTO m FROM public.fc_monster_definitions WHERE realm_index=tier AND NOT is_boss ORDER BY random() LIMIT 1;
   IF m.id IS NULL THEN message:='发现高阶灵草，但对应守草妖兽尚未开放，本次未获得灵草。';
   ELSE
    herb_name:=(ARRAY['练气','筑基','金丹','元婴','出窍','化神'])[tier+1]||'灵草';
    INSERT INTO public.fc_combat_encounters(character_id,room_id,monster_id,monster_count,player_health,monster_health,herb_reward_key,herb_reward_name,battle_log)
    VALUES(c.id,r.id,m.id,1,(public.fc_get_attributes()->>'health')::numeric,m.base_health,'herb_'||tier,herb_name,jsonb_build_array('采摘完成，惊动了守草妖兽；击败它后取得'||herb_name)) RETURNING id INTO eid;
    message:='采摘完成，惊动了守草妖兽'||m.name||'！击败它后取得'||herb_name||'。';
   END IF;
  END IF;
 ELSIF p_kind='fiber' THEN
  IF r.family_id IS DISTINCT FROM c.family_id OR r.template_id IS DISTINCT FROM '10000000-0000-0000-0000-000000000022'::uuid THEN RAISE EXCEPTION '纸材需前往本族灵田采集'; END IF;
  tier:=least(2,c.realm_index);PERFORM public.fc_inventory_add(c.id,'fiber_'||tier,(ARRAY['练气','筑基','金丹'])[tier+1]||'纸材纤维',3,'材料');message:='获得3份纸材纤维。';
 ELSE RAISE EXCEPTION '采集类型无效'; END IF;
 IF p_kind='herb' AND random()<.10 THEN PERFORM public.fc_inventory_add(c.id,'bamboo_seed','竹子种子',1,'种子','可种在本族灵田，10分钟成熟。');message:=message||' 获得1颗竹子种子。';END IF; UPDATE public.fc_characters SET gathering_at=now() WHERE id=c.id;
 RETURN jsonb_build_object('message',message,'workshop',public.fc_get_workshop());
END $function$;
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
 UPDATE public.fc_combat_encounters SET tick_at=now(),turn=turn+1,skill_runtime=skill_effects->'runtime',player_mana=CASE WHEN hits>1 THEN greatest(0,skill_mana-mana_cost) ELSE skill_mana END,player_health=greatest(0,skill_hp-incoming),monster_health=greatest(0,monster_health-damage),battle_log=battle_log||(skill_effects->'logs')||jsonb_build_array('第'||(turn+1)||'回合：'||skill_log||' 造成'||round(damage)||'伤害，妖兽造成'||round(incoming)||'伤害。') WHERE id=e.id RETURNING * INTO e;
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

CREATE FUNCTION public.fc_boss_rare_loot() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE m public.fc_monster_definitions;name text;
BEGIN IF OLD.status='active' AND NEW.status='won' THEN SELECT * INTO m FROM public.fc_monster_definitions WHERE id=NEW.monster_id;IF m.is_boss THEN name:=(ARRAY['练气','筑基','金丹','元婴','出窍','化神'])[m.realm_index+1];
IF random()<.15 THEN PERFORM public.fc_inventory_add(NEW.character_id,'dao_aura_'||m.realm_index,name||'道法气息',1,'材料','10份可重置对应境界家族功法的一个词条。');NEW.battle_log:=NEW.battle_log||jsonb_build_array('获得1份'||name||'道法气息');END IF;
IF random()<.02 THEN PERFORM public.fc_inventory_add(NEW.character_id,'boss_crystal_'||m.realm_index,name||'Boss战技传承水晶',1,'功法','使用领悟对应Boss战技，强于家族战技，略低于突破战技。');NEW.battle_log:=NEW.battle_log||jsonb_build_array('获得Boss战技传承水晶');END IF;END IF;END IF;RETURN NEW;END $$;
CREATE TRIGGER boss_rare_loot BEFORE UPDATE OF status ON public.fc_combat_encounters FOR EACH ROW EXECUTE FUNCTION public.fc_boss_rare_loot();
REVOKE ALL ON FUNCTION public.fc_boss_rare_loot() FROM PUBLIC,authenticated,anon;
