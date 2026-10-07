CREATE OR REPLACE FUNCTION public.fc_prepare_world_position()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_uid text:=public.fc_require_uid(); v_me public.fc_characters; v_pos public.fc_character_positions; v_cell public.fc_world_cells; v_room public.fc_world_rooms; v_home uuid;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid; IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 v_home:=public.fc_ensure_family_home(v_me.family_id);
 SELECT * INTO v_pos FROM public.fc_character_positions WHERE character_id=v_me.id;
 IF EXISTS(SELECT 1 FROM public.fc_city_journeys WHERE character_id=v_me.id AND arrives_at<=now()) THEN
 SELECT c.* INTO v_cell FROM public.fc_city_journeys j JOIN public.fc_world_rooms r ON r.city_id=j.destination AND (r.template_id='10000000-0000-0000-0000-000000000006' OR r.id='10000000-0000-0000-0000-000000000006') JOIN public.fc_world_cells c ON c.room_id=r.id AND c.x=0 AND c.y=0 WHERE j.character_id=v_me.id;
 UPDATE public.fc_character_positions SET cell_id=v_cell.id WHERE character_id=v_me.id;
 DELETE FROM public.fc_city_journeys WHERE character_id=v_me.id;
 SELECT * INTO v_pos FROM public.fc_character_positions WHERE character_id=v_me.id;
 END IF;
 IF v_pos.cell_id IS NULL THEN
  SELECT * INTO v_cell FROM public.fc_world_cells WHERE room_id=v_home AND x=0 AND y=0;
  INSERT INTO public.fc_character_positions(character_id,cell_id) VALUES(v_me.id,v_cell.id) ON CONFLICT (character_id) DO NOTHING;
  SELECT * INTO v_pos FROM public.fc_character_positions WHERE character_id=v_me.id;
 ELSE
  SELECT * INTO v_cell FROM public.fc_world_cells WHERE id=v_pos.cell_id;
 END IF;
 IF EXISTS(SELECT 1 FROM public.fc_world_rooms r WHERE r.id=v_cell.room_id AND r.family_id IS NULL AND (r.id='10000000-0000-0000-0000-000000000001' OR r.id::text BETWEEN '10000000-0000-0000-0000-000000000010' AND '10000000-0000-0000-0000-000000000022')) THEN
 SELECT * INTO v_cell FROM public.fc_world_cells WHERE id=md5(v_me.family_id::text||':cell:'||v_cell.id::text)::uuid;
 UPDATE public.fc_character_positions SET cell_id=v_cell.id WHERE character_id=v_me.id;
 END IF;
 UPDATE public.fc_character_positions SET updated_at=now() WHERE character_id=v_me.id;
 SELECT * INTO v_room FROM public.fc_world_rooms WHERE id=v_cell.room_id;
 PERFORM public.fc_claim_cultivation();

END $function$;
REVOKE ALL ON FUNCTION public.fc_prepare_world_position() FROM PUBLIC,authenticated,anon;

CREATE OR REPLACE FUNCTION public.fc_move_world(p_direction text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE v_uid text:=public.fc_require_uid(); v_me public.fc_characters; v_pos public.fc_character_positions; v_cell public.fc_world_cells; v_next public.fc_world_cells;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid; IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 PERFORM public.fc_prepare_world_position(); SELECT * INTO v_pos FROM public.fc_character_positions WHERE character_id=v_me.id FOR UPDATE; SELECT * INTO v_cell FROM public.fc_world_cells WHERE id=v_pos.cell_id;
 SELECT n.* INTO v_next FROM public.fc_world_cells n WHERE n.id=public.fc_player_next_cell(v_cell.id,p_direction);
 IF v_next.id IS NULL THEN RAISE EXCEPTION '这里没有可通行的道路'; END IF;
 IF EXISTS(SELECT 1 FROM public.fc_combat_encounters WHERE character_id=v_me.id AND status='active') THEN RAISE EXCEPTION '战斗中不能移动'; END IF;
 IF EXISTS(SELECT 1 FROM public.fc_world_rooms target JOIN public.fc_world_rooms current ON current.id=v_cell.room_id WHERE target.id=v_next.room_id AND target.region_depth='inner' AND v_me.realm_index<2 AND target.id<>current.id AND current.region_depth<>'core') THEN RAISE EXCEPTION '内围区域需要金丹及以上境界'; END IF;
 IF EXISTS(SELECT 1 FROM public.fc_world_rooms target JOIN public.fc_world_rooms current ON current.id=v_cell.room_id WHERE target.id=v_next.room_id AND target.region_depth='core' AND v_me.realm_index<4 AND target.id<>current.id) THEN RAISE EXCEPTION '核心区域需要出窍及以上境界'; END IF;
 UPDATE public.fc_character_positions SET cell_id=v_next.id,updated_at=now() WHERE character_id=v_me.id;
 RETURN public.fc_get_world_state();
END $function$;

