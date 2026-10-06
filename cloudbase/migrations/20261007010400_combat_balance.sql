CREATE OR REPLACE FUNCTION public.fc_resolve_combat(p_action text DEFAULT 'auto') RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters; e public.fc_combat_encounters; m public.fc_monster_definitions; stats jsonb; damage numeric; incoming numeric; alive integer; crit boolean;
BEGIN
 SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE;
 IF c.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 SELECT * INTO e FROM public.fc_combat_encounters WHERE character_id=c.id AND status='active' LIMIT 1 FOR UPDATE;
 IF e.id IS NULL THEN RETURN public.fc_get_combat(); END IF;
 IF now()-e.tick_at<interval '1 second' THEN RETURN public.fc_get_combat(); END IF;
 SELECT * INTO m FROM public.fc_monster_definitions WHERE id=e.monster_id;
 stats:=public.fc_get_attributes(); crit:=random()<0.05;
 damage:=greatest(1,(stats->>'attack')::numeric-m.base_defense*0.35)*(CASE WHEN crit THEN 1.5 ELSE 1 END);
 alive:=greatest(0,ceil(greatest(0,e.monster_health-damage)/m.base_health)::integer);
 incoming:=CASE WHEN alive=0 THEN 0 ELSE greatest(1,m.base_attack-(stats->>'defense')::numeric*0.25)*(1+0.35*(alive-1)) END;
 UPDATE public.fc_combat_encounters SET tick_at=now(),turn=turn+1,player_health=greatest(0,player_health-incoming),monster_health=greatest(0,monster_health-damage),battle_log=battle_log||jsonb_build_array('第'||(turn+1)||'回合：你造成'||round(damage)||CASE WHEN crit THEN '暴击伤害' ELSE '伤害' END||'，妖兽造成'||round(incoming)||'伤害。') WHERE id=e.id RETURNING * INTO e;
 IF e.monster_health<=0 THEN
  UPDATE public.fc_characters SET spirit_stones=spirit_stones+5*(m.realm_index+1)*e.monster_count,encounter_checked_at=now() WHERE id=c.id;
  UPDATE public.fc_combat_encounters SET status='won',result='胜利',battle_log=battle_log||jsonb_build_array('胜利，获得'||(5*(m.realm_index+1)*e.monster_count)||'灵石。') WHERE id=e.id;
 ELSIF e.player_health<=0 THEN
  UPDATE public.fc_characters SET encounter_checked_at=now() WHERE id=c.id;
  UPDATE public.fc_combat_encounters SET status='lost',result='战败',battle_log=battle_log||jsonb_build_array('战败，本轮内测不扣寿元及物品。') WHERE id=e.id;
 END IF;
 RETURN public.fc_get_combat();
END $$;
-- Initialize a group's health pool before its first attack.
CREATE FUNCTION public.fc_combat_health_pool() RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN NEW.monster_health:=NEW.monster_health*NEW.monster_count; RETURN NEW; END $$;
CREATE TRIGGER combat_health_pool BEFORE INSERT ON public.fc_combat_encounters FOR EACH ROW EXECUTE FUNCTION public.fc_combat_health_pool();
UPDATE public.fc_combat_encounters e SET monster_health=m.base_health*e.monster_count FROM public.fc_monster_definitions m WHERE e.monster_id=m.id AND e.turn=0 AND e.status='active';
UPDATE public.fc_wild_encounters SET status='retired' WHERE status='待处理';
UPDATE public.fc_world_rooms SET region_depth='outer' WHERE NOT is_safe_city AND kind='road';
UPDATE public.fc_world_rooms SET template_id='10000000-0000-0000-0000-000000000004' WHERE region_depth IN ('inner','core') AND kind='forest';
