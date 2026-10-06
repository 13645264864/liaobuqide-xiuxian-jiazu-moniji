CREATE TABLE public.fc_world_exits (
 from_cell uuid NOT NULL REFERENCES public.fc_world_cells(id), direction text NOT NULL CHECK(direction IN ('north','south','east','west')), to_cell uuid NOT NULL REFERENCES public.fc_world_cells(id), PRIMARY KEY(from_cell,direction)
);
ALTER TABLE public.fc_world_exits ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.fc_world_exits FROM anon,authenticated;
INSERT INTO public.fc_world_rooms(id,state_name,city_name,name,kind,description) VALUES
 ('10000000-0000-0000-0000-000000000005','中州','许州城','府前街','road','城主府前的街道，宅门向北，南面通往城门。百姓在街旁摆摊。'),
 ('10000000-0000-0000-0000-000000000006','中州','许州城','许州城南门','building','城墙下的南门通道，向北回城，向南出城进入荒原。');
INSERT INTO public.fc_world_cells(id,room_id,x,y,terrain)
SELECT md5(r.id::text || ':' || x || ':' || y)::uuid,r.id,x,y,CASE WHEN r.kind='building' THEN 'city_gate' ELSE 'floor' END
FROM public.fc_world_rooms r CROSS JOIN generate_series(-1,1) x CROSS JOIN generate_series(-1,1) y
WHERE r.id IN ('10000000-0000-0000-0000-000000000005','10000000-0000-0000-0000-000000000006');
UPDATE public.fc_world_cells SET terrain='room' WHERE room_id='10000000-0000-0000-0000-000000000001';
UPDATE public.fc_world_cells SET terrain='door' WHERE room_id='10000000-0000-0000-0000-000000000001' AND x=0 AND y=1;
INSERT INTO public.fc_world_exits SELECT a.id,'south',b.id FROM public.fc_world_cells a,public.fc_world_cells b WHERE a.room_id='10000000-0000-0000-0000-000000000001' AND a.x=0 AND a.y=1 AND b.room_id='10000000-0000-0000-0000-000000000005' AND b.x=0 AND b.y=-1;
INSERT INTO public.fc_world_exits SELECT b.id,'north',a.id FROM public.fc_world_cells a,public.fc_world_cells b WHERE a.room_id='10000000-0000-0000-0000-000000000001' AND a.x=0 AND a.y=1 AND b.room_id='10000000-0000-0000-0000-000000000005' AND b.x=0 AND b.y=-1;
INSERT INTO public.fc_world_exits SELECT a.id,'south',b.id FROM public.fc_world_cells a,public.fc_world_cells b WHERE a.room_id='10000000-0000-0000-0000-000000000005' AND a.x=0 AND a.y=1 AND b.room_id='10000000-0000-0000-0000-000000000006' AND b.x=0 AND b.y=-1;
INSERT INTO public.fc_world_exits SELECT b.id,'north',a.id FROM public.fc_world_cells a,public.fc_world_cells b WHERE a.room_id='10000000-0000-0000-0000-000000000005' AND a.x=0 AND a.y=1 AND b.room_id='10000000-0000-0000-0000-000000000006' AND b.x=0 AND b.y=-1;
INSERT INTO public.fc_world_exits SELECT a.id,'south',b.id FROM public.fc_world_cells a,public.fc_world_cells b WHERE a.room_id='10000000-0000-0000-0000-000000000006' AND a.x=0 AND a.y=1 AND b.room_id='10000000-0000-0000-0000-000000000002' AND b.x=0 AND b.y=-1;
INSERT INTO public.fc_world_exits SELECT b.id,'north',a.id FROM public.fc_world_cells a,public.fc_world_cells b WHERE a.room_id='10000000-0000-0000-0000-000000000006' AND a.x=0 AND a.y=1 AND b.room_id='10000000-0000-0000-0000-000000000002' AND b.x=0 AND b.y=-1;
INSERT INTO public.fc_world_exits SELECT a.id,'east',b.id FROM public.fc_world_cells a,public.fc_world_cells b WHERE a.room_id='10000000-0000-0000-0000-000000000002' AND a.x=1 AND a.y=0 AND b.room_id='10000000-0000-0000-0000-000000000003' AND b.x=-1 AND b.y=0;
INSERT INTO public.fc_world_exits SELECT b.id,'west',a.id FROM public.fc_world_cells a,public.fc_world_cells b WHERE a.room_id='10000000-0000-0000-0000-000000000002' AND a.x=1 AND a.y=0 AND b.room_id='10000000-0000-0000-0000-000000000003' AND b.x=-1 AND b.y=0;
INSERT INTO public.fc_world_exits SELECT a.id,'south',b.id FROM public.fc_world_cells a,public.fc_world_cells b WHERE a.room_id='10000000-0000-0000-0000-000000000002' AND a.x=0 AND a.y=1 AND b.room_id='10000000-0000-0000-0000-000000000004' AND b.x=0 AND b.y=-1;
INSERT INTO public.fc_world_exits SELECT b.id,'north',a.id FROM public.fc_world_cells a,public.fc_world_cells b WHERE a.room_id='10000000-0000-0000-0000-000000000002' AND a.x=0 AND a.y=1 AND b.room_id='10000000-0000-0000-0000-000000000004' AND b.x=0 AND b.y=-1;
CREATE FUNCTION public.fc_world_next_cell(p_cell uuid,p_direction text) RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT coalesce((SELECT to_cell FROM public.fc_world_exits WHERE from_cell=p_cell AND direction=p_direction),
 (SELECT n.id FROM public.fc_world_cells c JOIN public.fc_world_cells n ON n.room_id=c.room_id
 AND n.x=c.x+CASE p_direction WHEN 'east' THEN 1 WHEN 'west' THEN -1 ELSE 0 END
 AND n.y=c.y+CASE p_direction WHEN 'south' THEN 1 WHEN 'north' THEN -1 ELSE 0 END
 WHERE c.id=p_cell AND p_direction IN ('north','south','east','west')))
$$;
REVOKE ALL ON FUNCTION public.fc_world_next_cell(uuid,text) FROM PUBLIC;
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
 SELECT * INTO v_room FROM public.fc_world_rooms WHERE id=v_cell.room_id;
 RETURN jsonb_build_object('room',to_jsonb(v_room),'cell',to_jsonb(v_cell),'cells',(SELECT jsonb_agg(to_jsonb(t) ORDER BY t.y,t.x) FROM public.fc_world_cells t WHERE t.room_id=v_room.id),'exits',coalesce((SELECT jsonb_agg(jsonb_build_object('from_cell',e.from_cell,'x',c.x,'y',c.y,'direction',e.direction,'to_room',r.name)) FROM public.fc_world_exits e JOIN public.fc_world_cells c ON c.id=e.from_cell JOIN public.fc_world_cells dest ON dest.id=e.to_cell JOIN public.fc_world_rooms r ON r.id=dest.room_id WHERE c.room_id=v_room.id),'[]'::jsonb),'map_rooms',(SELECT jsonb_agg(to_jsonb(r)) FROM public.fc_world_rooms r),'nearby',coalesce((SELECT jsonb_agg(jsonb_build_object('id',c.id,'name',c.display_name,'title',c.title)) FROM public.fc_character_positions p JOIN public.fc_characters c ON c.id=p.character_id WHERE p.cell_id=v_cell.id AND c.id<>v_me.id),'[]'::jsonb));
END $$;
GRANT EXECUTE ON FUNCTION public.fc_get_world_state() TO authenticated;
CREATE OR REPLACE FUNCTION public.fc_move_world(p_direction text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); v_me public.fc_characters; v_pos public.fc_character_positions; v_cell public.fc_world_cells; v_next public.fc_world_cells; dx integer:=0; dy integer:=0;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid; IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 PERFORM public.fc_get_world_state(); SELECT * INTO v_pos FROM public.fc_character_positions WHERE character_id=v_me.id FOR UPDATE; IF v_pos.cell_id IS NULL THEN PERFORM public.fc_get_world_state(); SELECT * INTO v_pos FROM public.fc_character_positions WHERE character_id=v_me.id; END IF;
 SELECT * INTO v_cell FROM public.fc_world_cells WHERE id=v_pos.cell_id;
 IF p_direction='north' THEN dy:=-1; ELSIF p_direction='south' THEN dy:=1; ELSIF p_direction='west' THEN dx:=-1; ELSIF p_direction='east' THEN dx:=1; ELSE RAISE EXCEPTION '方向无效'; END IF;
 SELECT n.* INTO v_next FROM public.fc_world_cells n WHERE n.id=public.fc_world_next_cell(v_cell.id,p_direction);
 IF v_next.id IS NULL THEN RAISE EXCEPTION '这里没有可通行的道路'; END IF;
 UPDATE public.fc_character_positions SET cell_id=v_next.id,updated_at=now() WHERE character_id=v_me.id;
 RETURN public.fc_get_world_state();
END $$;
GRANT EXECUTE ON FUNCTION public.fc_get_world_state(),public.fc_move_world(text) TO authenticated;
