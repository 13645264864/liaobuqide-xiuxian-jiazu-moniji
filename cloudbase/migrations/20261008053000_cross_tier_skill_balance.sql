CREATE OR REPLACE FUNCTION public.fc_skill_tick(p_character uuid,p_stats jsonb,p_enemy jsonb,p_runtime jsonb,p_health numeric,p_mana numeric,p_turn integer,p_incoming numeric,p_enemy_health numeric,p_enemy_max numeric,p_enemies integer DEFAULT 1) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE runtime jsonb:=p_runtime;rec record;fx jsonb;cd integer;last_tick integer;cost numeric;atk numeric:=(p_stats->>'attack')::numeric;hpmax numeric:=(p_stats->>'health')::numeric;mpmax numeric:=(p_stats->>'mana')::numeric;health numeric:=p_health;mana numeric:=p_mana;shield numeric:=coalesce((runtime->>'shield')::numeric,0);shield_until integer:=coalesce((runtime->>'shield_until')::integer,-1);damage numeric:=0;incoming numeric:=p_incoming;amount numeric;mitigation numeric:=0;boost numeric:=0;lifesteal numeric:=0;weaken numeric:=0;is_lethal boolean;is_delayed boolean;protection numeric:=0;logs jsonb:='[]';spirit numeric;spirit_cost numeric;targets integer;stun integer;immune integer:=coalesce((runtime->>'enemy_immune_until')::integer,-1);enemy_stun integer:=coalesce((runtime->>'enemy_stun_until')::integer,-1);base_attack numeric;crossed boolean:=(p_enemy->>'realm_index')::integer=(p_stats->>'realm_index')::integer+1;has_ability boolean:=false;strong_ability boolean:=false;sword boolean;
BEGIN
 SELECT EXISTS(SELECT 1 FROM public.fc_equipment_instances WHERE character_id=p_character AND equipped_slot='weapon') INTO sword;
 SELECT consciousness INTO spirit FROM public.fc_characters WHERE id=p_character;
 SELECT EXISTS(SELECT 1 FROM public.fc_known_skills k JOIN public.fc_skill_definitions d ON d.id=k.skill_id WHERE k.character_id=p_character AND k.slot IS NOT NULL AND d.category='ability'),EXISTS(SELECT 1 FROM public.fc_known_skills k JOIN public.fc_skill_definitions d ON d.id=k.skill_id WHERE k.character_id=p_character AND k.slot IS NOT NULL AND d.category='ability' AND k.enhanced) INTO has_ability,strong_ability;
 IF crossed AND has_ability AND p_turn<(CASE WHEN strong_ability THEN 8 ELSE 6 END) THEN protection:=CASE WHEN strong_ability THEN .90 ELSE .75 END;END IF;
 IF shield_until<p_turn THEN shield:=0;END IF;
 FOR rec IN SELECT d.*,k.enhanced,k.slot FROM public.fc_known_skills k JOIN public.fc_skill_definitions d ON d.id=k.skill_id WHERE k.character_id=p_character AND k.slot IS NOT NULL ORDER BY d.category,k.slot LOOP
  fx:=CASE WHEN rec.enhanced THEN rec.enhanced_effects ELSE rec.effects END;
  cd:=(fx->>'cooldown')::integer;is_lethal:=coalesce((fx->>'lethal')::boolean,false);is_delayed:=coalesce((fx->>'delay')::integer,0)>0;
  last_tick:=coalesce((runtime->'used'->>rec.id)::integer,-99999);
  IF p_turn-last_tick<cd OR coalesce((fx->>'sword')::boolean,false) AND NOT sword THEN CONTINUE;END IF;
  IF fx ? 'threshold' AND health/hpmax>(fx->>'threshold')::numeric THEN CONTINUE;END IF;
  IF fx ? 'min_health' AND health/hpmax<(fx->>'min_health')::numeric THEN CONTINUE;END IF;
  IF is_lethal AND (incoming<health+shield OR coalesce((runtime->>'saved')::boolean,false)) THEN CONTINUE;END IF;
  cost:=mpmax*coalesce((fx->>'cost')::numeric,0);spirit_cost:=(p_stats->>'consciousness_max')::numeric*coalesce((fx->>'spirit')::numeric,0);
  IF mana<cost OR spirit<spirit_cost THEN CONTINUE;END IF;
  mana:=mana-cost;spirit:=spirit-spirit_cost;
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
END $$;
