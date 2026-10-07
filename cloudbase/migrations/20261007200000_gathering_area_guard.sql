-- Stop normal encounters while gathering, and require a completed herb collection
-- to create exactly one active guard encounter.
CREATE OR REPLACE FUNCTION public.fc_spawn_combat() RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters; p public.fc_character_positions; cell public.fc_world_cells; r public.fc_world_rooms; e public.fc_combat_encounters; m public.fc_monster_definitions; allowed integer;
BEGIN
 SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE;
 SELECT * INTO p FROM public.fc_character_positions WHERE character_id=c.id;
 SELECT * INTO cell FROM public.fc_world_cells WHERE id=p.cell_id;
 SELECT * INTO r FROM public.fc_world_rooms WHERE id=cell.room_id;
 IF r.is_safe_city OR r.kind NOT IN ('wilderness','forest','road') THEN RETURN public.fc_get_combat(); END IF;
 -- While a gathering timer is running, no ordinary encounter may be rolled.
 IF c.gathering_started_at IS NOT NULL THEN RETURN public.fc_get_combat(); END IF;
 SELECT * INTO e FROM public.fc_combat_encounters WHERE character_id=c.id AND status='active' LIMIT 1;
 IF e.id IS NOT NULL THEN RETURN public.fc_get_combat(); END IF;
 IF EXISTS(SELECT 1 FROM public.fc_city_journeys WHERE character_id=c.id) THEN RETURN jsonb_build_object('active',false); END IF;
 IF now()-c.encounter_checked_at<interval '5 seconds' THEN RETURN jsonb_build_object('active',false); END IF;
 UPDATE public.fc_characters SET encounter_checked_at=now() WHERE id=c.id;
 IF random()>(CASE WHEN c.lure_room=r.id THEN 1 ELSE r.encounter_rate END) THEN RETURN jsonb_build_object('active',false); END IF;
 allowed:=CASE WHEN r.region_depth='outer' THEN least(1,c.realm_index+1) WHEN r.region_depth='inner' THEN least(2,c.realm_index+1) ELSE 2 END;
 SELECT * INTO m FROM public.fc_monster_definitions WHERE region_depth=CASE WHEN r.region_depth='inner' THEN 'inner' ELSE 'outer' END AND r.region_depth<>'core' AND realm_index<=least(2,c.realm_index+1) ORDER BY random() LIMIT 1;
 IF m.id IS NULL THEN RETURN jsonb_build_object('active',false); END IF;
 INSERT INTO public.fc_combat_encounters(character_id,room_id,monster_id,monster_count,player_health,monster_health) VALUES(c.id,r.id,m.id,1+floor(random()*3)::int,(public.fc_get_attributes()->>'health')::numeric,m.base_health) RETURNING * INTO e;
 RETURN public.fc_get_combat();
END $$;

CREATE OR REPLACE FUNCTION public.fc_gather(p_kind text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters; current_room uuid; result jsonb;
BEGIN
 SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE;
 IF c.gathering_started_at IS NULL OR c.gathering_kind IS DISTINCT FROM p_kind THEN RAISE EXCEPTION '请先开始采集'; END IF;
 IF now()<c.gathering_started_at+interval '10 seconds' THEN RAISE EXCEPTION '采集需要10秒，请等待完成'; END IF;
 SELECT cell.room_id INTO current_room FROM public.fc_character_positions p JOIN public.fc_world_cells cell ON cell.id=p.cell_id WHERE p.character_id=c.id;
 IF current_room IS DISTINCT FROM c.gathering_room THEN
  UPDATE public.fc_characters SET gathering_started_at=NULL,gathering_room=NULL,gathering_kind=NULL WHERE id=c.id;
  RAISE EXCEPTION '已离开采集区域，采集自动停止';
 END IF;
 IF p_kind='ore' AND NOT EXISTS(SELECT 1 FROM public.fc_world_rooms r WHERE r.id=current_room AND r.family_id=c.family_id AND r.mine_level IS NOT NULL) THEN
  UPDATE public.fc_characters SET gathering_started_at=NULL,gathering_room=NULL,gathering_kind=NULL WHERE id=c.id;
  RAISE EXCEPTION '已离开本族灵矿，采矿自动停止';
 END IF;
 IF p_kind='herb' AND NOT EXISTS(SELECT 1 FROM public.fc_world_rooms r WHERE r.id=current_room AND r.kind='forest' AND NOT r.is_safe_city) THEN
  UPDATE public.fc_characters SET gathering_started_at=NULL,gathering_room=NULL,gathering_kind=NULL WHERE id=c.id;
  RAISE EXCEPTION '已离开森林，采草自动停止';
 END IF;
 result:=public.fc_finish_gather_internal(p_kind);
 UPDATE public.fc_characters SET gathering_started_at=NULL,gathering_room=NULL,gathering_kind=NULL WHERE id=c.id;
 RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.fc_spawn_combat(),public.fc_gather(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fc_spawn_combat(),public.fc_gather(text) TO authenticated;
