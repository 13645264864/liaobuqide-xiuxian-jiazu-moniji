CREATE OR REPLACE FUNCTION public.fc_get_world_state() RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); v_me public.fc_characters; v_pos public.fc_character_positions; v_cell public.fc_world_cells; v_room public.fc_world_rooms;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid; IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 SELECT * INTO v_pos FROM public.fc_character_positions WHERE character_id=v_me.id;
 IF v_pos.cell_id IS NULL THEN
  SELECT * INTO v_cell FROM public.fc_world_cells WHERE id='11000000-0000-0000-0000-000000000005';
  INSERT INTO public.fc_character_positions(character_id,cell_id) VALUES(v_me.id,v_cell.id) ON CONFLICT (character_id) DO NOTHING;
  SELECT * INTO v_pos FROM public.fc_character_positions WHERE character_id=v_me.id;
 ELSE
  SELECT * INTO v_cell FROM public.fc_world_cells WHERE id=v_pos.cell_id;
 END IF;
 UPDATE public.fc_character_positions SET updated_at=now() WHERE character_id=v_me.id;
 SELECT * INTO v_room FROM public.fc_world_rooms WHERE id=v_cell.room_id;
 RETURN jsonb_build_object('room',to_jsonb(v_room),'cell',to_jsonb(v_cell),'cells',(SELECT jsonb_agg(to_jsonb(t) ORDER BY t.y,t.x) FROM public.fc_world_cells t WHERE t.room_id=v_room.id),'exits',coalesce((SELECT jsonb_agg(jsonb_build_object('from_cell',e.from_cell,'x',c.x,'y',c.y,'direction',e.direction,'to_room',r.name)) FROM public.fc_world_exits e JOIN public.fc_world_cells c ON c.id=e.from_cell JOIN public.fc_world_cells dest ON dest.id=e.to_cell JOIN public.fc_world_rooms r ON r.id=dest.room_id WHERE c.room_id=v_room.id),'[]'::jsonb),'navigation',jsonb_build_object('cells',(SELECT jsonb_agg(to_jsonb(c)) FROM public.fc_world_cells c),'edges',(SELECT jsonb_agg(jsonb_build_object('from',c.id,'to',n.id,'direction',d.direction)) FROM public.fc_world_cells c CROSS JOIN (VALUES ('north'),('south'),('east'),('west')) d(direction) JOIN public.fc_world_cells n ON n.id=public.fc_world_next_cell(c.id,d.direction))),'map_rooms',(SELECT jsonb_agg(to_jsonb(r)) FROM public.fc_world_rooms r),'nearby',coalesce((SELECT jsonb_agg(jsonb_build_object('id',c.id,'name',c.display_name,'title',c.title)) FROM public.fc_character_positions p JOIN public.fc_characters c ON c.id=p.character_id WHERE p.cell_id=v_cell.id AND c.id<>v_me.id AND p.updated_at>now()-interval '90 seconds'),'[]'::jsonb));
END $$;
GRANT EXECUTE ON FUNCTION public.fc_get_world_state() TO authenticated;
