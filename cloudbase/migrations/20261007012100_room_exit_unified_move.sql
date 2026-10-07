CREATE OR REPLACE FUNCTION public.fc_player_next_cell(p_cell uuid,p_direction text) RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_exit uuid; v_cell public.fc_world_cells; v_room public.fc_world_rooms; v_family uuid; v_target public.fc_world_cells;
BEGIN
 SELECT to_cell INTO v_exit FROM public.fc_world_exits WHERE from_cell=p_cell AND direction=p_direction LIMIT 1;
 IF v_exit IS NOT NULL THEN RETURN v_exit; END IF;
 SELECT * INTO v_cell FROM public.fc_world_cells WHERE id=p_cell;
 SELECT * INTO v_room FROM public.fc_world_rooms WHERE id=v_cell.room_id;
 SELECT family_id INTO v_family FROM public.fc_characters WHERE owner_id=public.fc_require_uid();
 IF v_family IS NOT NULL AND v_cell.x=0 AND v_cell.y=-1 AND p_direction='north' AND v_room.family_id IS NULL AND v_room.city_id=(SELECT city_id FROM public.fc_families WHERE id=v_family) THEN
  SELECT cell.* INTO v_target FROM public.fc_world_cells cell JOIN public.fc_world_rooms home ON home.id=cell.room_id WHERE home.family_id=v_family AND home.template_id='10000000-0000-0000-0000-000000000001' AND cell.x=0 AND cell.y=1 LIMIT 1;
  IF v_target.id IS NOT NULL THEN RETURN v_target.id; END IF;
 END IF;
 IF v_family IS NOT NULL AND v_cell.x=0 AND v_cell.y=1 AND p_direction='south' AND v_room.family_id=v_family THEN
  SELECT cell.* INTO v_target FROM public.fc_world_cells cell JOIN public.fc_world_rooms street ON street.id=cell.room_id WHERE street.family_id IS NULL AND street.city_id=v_room.city_id AND cell.x=0 AND cell.y=-1 LIMIT 1;
  IF v_target.id IS NOT NULL THEN RETURN v_target.id; END IF;
 END IF;
 RETURN public.fc_world_next_cell(p_cell,p_direction);
END $$;
CREATE OR REPLACE FUNCTION public.fc_move_world(p_direction text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); v_me public.fc_characters; v_pos public.fc_character_positions; v_cell public.fc_world_cells; v_next public.fc_world_cells;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid; IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 PERFORM public.fc_get_world_state(); SELECT * INTO v_pos FROM public.fc_character_positions WHERE character_id=v_me.id FOR UPDATE; SELECT * INTO v_cell FROM public.fc_world_cells WHERE id=v_pos.cell_id;
 SELECT n.* INTO v_next FROM public.fc_world_cells n WHERE n.id=public.fc_player_next_cell(v_cell.id,p_direction);
 IF v_next.id IS NULL THEN RAISE EXCEPTION '这里没有可通行的道路'; END IF;
 IF EXISTS(SELECT 1 FROM public.fc_combat_encounters WHERE character_id=v_me.id AND status='active') THEN RAISE EXCEPTION '战斗中不能移动'; END IF;
 UPDATE public.fc_character_positions SET cell_id=v_next.id,updated_at=now() WHERE character_id=v_me.id;
 RETURN public.fc_get_world_state();
END $$;
REVOKE ALL ON FUNCTION public.fc_player_next_cell(uuid,text),public.fc_move_world(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fc_move_world(text) TO authenticated;
