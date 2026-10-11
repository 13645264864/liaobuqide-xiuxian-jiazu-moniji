CREATE OR REPLACE FUNCTION public.fc_simulate_inner_demon(p_grade integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE c public.fc_characters;stats jsonb;base jsonb;enemy jsonb;runtime jsonb:='{}';ticks jsonb:='[]';effects jsonb;hp numeric;mana numeric;ehp numeric;ehpmax numeric;atk numeric;ea numeric;ed numeric;phmax numeric;damage numeric;incoming numeric;factor numeric:=(p_grade-1)*.0625; cumulative jsonb:='{}'; previous_stats jsonb; next_stats jsonb; key text; step_realm integer; step_layer integer; delta numeric;turn integer;art numeric:=1;modifier numeric:=1;
BEGIN
 SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE;
 stats:=public.fc_get_attributes()||jsonb_build_object('realm_index',c.realm_index);base:=public.fc_base_stats(c.realm_index,c.realm_layer,1);
 IF p_grade NOT BETWEEN 1 AND 9 THEN RAISE EXCEPTION '心魔等级必须为1至9';END IF;
 -- Reconstruct an ungraded cultivator, including every successful transition
 -- from qi layer one. Only expansion growth receives the grade coefficient.
 previous_stats:=public.fc_base_stats(0,1,1);
 FOR step_realm IN 0..c.realm_index LOOP
  FOR step_layer IN 1..(CASE WHEN step_realm=c.realm_index THEN c.realm_layer ELSE 9 END) LOOP
   next_stats:=public.fc_base_stats(step_realm,step_layer,1);
   FOREACH key IN ARRAY ARRAY['health','mana','attack','defense','speed','consciousness_max'] LOOP
    delta:=greatest(0,(next_stats->>key)::numeric-(previous_stats->>key)::numeric);
    cumulative:=jsonb_set(cumulative,ARRAY[key],to_jsonb(coalesce((cumulative->>key)::numeric,0)+delta*factor*(1+(p_grade-1)*.0625)));
   END LOOP;
   previous_stats:=next_stats;
  END LOOP;
 END LOOP;
 enemy:=jsonb_build_object('name','心魔','realm_index',c.realm_index,'base_health',(base->>'health')::numeric+coalesce((cumulative->>'health')::numeric,0),'base_attack',(base->>'attack')::numeric+coalesce((cumulative->>'attack')::numeric,0),'base_defense',(base->>'defense')::numeric+coalesce((cumulative->>'defense')::numeric,0),'speed',(base->>'speed')::numeric+coalesce((cumulative->>'speed')::numeric,0),'mana',(base->>'mana')::numeric+coalesce((cumulative->>'mana')::numeric,0),'consciousness_max',(base->>'consciousness_max')::numeric+coalesce((cumulative->>'consciousness_max')::numeric,0),'expansion_percent',factor*100,'base_stats',base,'cumulative_expansion',cumulative,'grade_factor',1+(p_grade-1)*.0625);

 hp:=(stats->>'health')::numeric;phmax:=hp;mana:=(stats->>'mana')::numeric;ehp:=(enemy->>'base_health')::numeric;ehpmax:=ehp;ea:=(enemy->>'base_attack')::numeric;ed:=(enemy->>'base_defense')::numeric;atk:=(stats->>'attack')::numeric;
 IF EXISTS(SELECT 1 FROM public.fc_equipment_instances WHERE character_id=c.id AND equipped_slot='weapon') AND c.equipped_art IN ('nameless_sword','family_sword') THEN art:=CASE WHEN c.equipped_art='nameless_sword' THEN 2 ELSE 2.2 END;END IF;
 modifier:=1+CASE WHEN c.breakthrough_boost_until>now() THEN .10 ELSE 0 END+(public.fc_mind_effects(c.mind)->>'breakthrough_bonus')::numeric/100;
 FOR turn IN 0..119 LOOP
  damage:=greatest(1,atk-ed*.35)*art*modifier;incoming:=greatest(1,ea-(stats->>'defense')::numeric*.25);
  effects:=public.fc_skill_tick(c.id,stats,enemy,runtime,hp,mana,turn,incoming,ehp,ehpmax,1);
  runtime:=effects->'runtime';hp:=(effects->>'health')::numeric;mana:=(effects->>'mana')::numeric;damage:=damage+(effects->>'damage')::numeric;incoming:=(effects->>'incoming')::numeric;
  ehp:=greatest(0,ehp-damage);IF ehp=0 THEN incoming:=0;END IF;hp:=greatest(0,hp-incoming);
  ticks:=ticks||jsonb_build_array(jsonb_build_object('turn',turn+1,'player_health',hp,'monster_health',ehp,'damage',round(damage,2),'incoming',round(incoming,2),'logs',effects->'logs'));
  EXIT WHEN ehp=0 OR hp=0;
 END LOOP;
 RETURN jsonb_build_object('success',ehp=0,'name','心魔','avatar_key',c.avatar_key,'player_name',c.display_name,'player_health_max',phmax,'monster',enemy,'grade',p_grade,'turns',ticks);
END $function$;
