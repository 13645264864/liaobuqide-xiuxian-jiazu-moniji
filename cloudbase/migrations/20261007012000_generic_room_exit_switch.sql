CREATE OR REPLACE FUNCTION public.fc_player_next_cell(p_cell uuid,p_direction text) RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_exit uuid; v_cell public.fc_world_cells; v_room public.fc_world_rooms; v_family uuid;
BEGIN
 SELECT to_cell INTO v_exit FROM public.fc_world_exits WHERE from_cell=p_cell AND direction=p_direction LIMIT 1;
 IF v_exit IS NOT NULL THEN RETURN v_exit; END IF;
 SELECT * INTO v_cell FROM public.fc_world_cells WHERE id=p_cell;
 SELECT * INTO v_room FROM public.fc_world_rooms WHERE id=v_cell.room_id;
 SELECT family_id INTO v_family FROM public.fc_characters WHERE owner_id=public.fc_require_uid();
 IF v_cell.x=0 AND v_cell.y=-1 AND p_direction='north' AND v_room.family_id=v_family THEN
  RETURN (SELECT cell.id FROM public.fc_world_cells cell JOIN public.fc_world_rooms street ON street.id=cell.room_id WHERE street.city_id=v_room.city_id AND street.family_id IS NULL AND cell.x=0 AND cell.y=1 LIMIT 1);
 END IF;
 IF v_cell.x=0 AND v_cell.y=1 AND p_direction='south' AND v_room.family_id IS NULL THEN
  RETURN (SELECT cell.id FROM public.fc_world_cells cell JOIN public.fc_world_rooms home ON home.id=cell.room_id WHERE home.family_id=v_family AND home.city_id=v_room.city_id AND cell.x=0 AND cell.y=-1 LIMIT 1);
 END IF;
 RETURN public.fc_world_next_cell(p_cell,p_direction);
END $$;
REVOKE ALL ON FUNCTION public.fc_player_next_cell(uuid,text) FROM PUBLIC;
