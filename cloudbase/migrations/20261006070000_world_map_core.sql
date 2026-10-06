CREATE TABLE public.fc_world_rooms (
 id uuid PRIMARY KEY, parent_id uuid REFERENCES public.fc_world_rooms(id), state_name text NOT NULL, city_name text, name text NOT NULL, kind text NOT NULL CHECK(kind IN('city','building','road','wilderness','forest','room')), danger numeric NOT NULL DEFAULT 0, encounter_rate numeric NOT NULL DEFAULT 0, description text NOT NULL DEFAULT ''
);
CREATE TABLE public.fc_world_cells (
 id uuid PRIMARY KEY, room_id uuid NOT NULL REFERENCES public.fc_world_rooms(id), x smallint NOT NULL, y smallint NOT NULL, terrain text NOT NULL DEFAULT 'floor', UNIQUE(room_id,x,y)
);
CREATE TABLE public.fc_character_positions (
 character_id uuid PRIMARY KEY REFERENCES public.fc_characters(id), cell_id uuid NOT NULL REFERENCES public.fc_world_cells(id), updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO public.fc_world_rooms(id,state_name,city_name,name,kind,danger,encounter_rate,description) VALUES
('10000000-0000-0000-0000-000000000001','中州','许州城','青山李氏宅邸','building',0,0,'家族宅邸，宗祠与成员部屋所在。'),
('10000000-0000-0000-0000-000000000002','中州','许州城','许州城南门外荒原','wilderness',0.2,0.10,'城门之外的荒原，官道与林间岔路在此分开。'),
('10000000-0000-0000-0000-000000000003','中州','许州城','许州官道','road',0.15,0.05,'通往相邻城池的官道，偶有低阶妖兽拦路。'),
('10000000-0000-0000-0000-000000000004','中州','许州城','黑森林外围','forest',0.65,0.35,'离开官道后的黑森林外围，资源更多，风险也更高。');
INSERT INTO public.fc_world_cells(id,room_id,x,y,terrain) VALUES
('11000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001',-1,-1,'courtyard'),('11000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001',0,-1,'ancestral_hall'),('11000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000001',1,-1,'room'),('11000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-000000000001',-1,0,'room'),('11000000-0000-0000-0000-000000000005','10000000-0000-0000-0000-000000000001',0,0,'family_hall'),('11000000-0000-0000-0000-000000000006','10000000-0000-0000-0000-000000000001',1,0,'room'),('11000000-0000-0000-0000-000000000007','10000000-0000-0000-0000-000000000001',-1,1,'room'),('11000000-0000-0000-0000-000000000008','10000000-0000-0000-0000-000000000001',0,1,'room'),('11000000-0000-0000-0000-000000000009','10000000-0000-0000-0000-000000000001',1,1,'room'),
('12000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002',-1,-1,'wilderness'),('12000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000002',0,-1,'city_gate'),('12000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000002',1,-1,'wilderness'),('12000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-000000000002',-1,0,'wilderness'),('12000000-0000-0000-0000-000000000005','10000000-0000-0000-0000-000000000002',0,0,'wilderness'),('12000000-0000-0000-0000-000000000006','10000000-0000-0000-0000-000000000002',1,0,'road_junction'),('12000000-0000-0000-0000-000000000007','10000000-0000-0000-0000-000000000002',-1,1,'forest_edge'),('12000000-0000-0000-0000-000000000008','10000000-0000-0000-0000-000000000002',0,1,'wilderness'),('12000000-0000-0000-0000-000000000009','10000000-0000-0000-0000-000000000002',1,1,'forest_edge'),
('13000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000003',-1,0,'road'),('13000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000003',0,0,'road'),('13000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000003',1,0,'road'),
('14000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000004',-1,-1,'forest'),('14000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000004',0,-1,'forest'),('14000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000004',1,-1,'forest'),('14000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-000000000004',-1,0,'forest'),('14000000-0000-0000-0000-000000000005','10000000-0000-0000-0000-000000000004',0,0,'forest'),('14000000-0000-0000-0000-000000000006','10000000-0000-0000-0000-000000000004',1,0,'forest'),('14000000-0000-0000-0000-000000000007','10000000-0000-0000-0000-000000000004',-1,1,'forest'),('14000000-0000-0000-0000-000000000008','10000000-0000-0000-0000-000000000004',0,1,'forest'),('14000000-0000-0000-0000-000000000009','10000000-0000-0000-0000-000000000004',1,1,'forest');
CREATE OR REPLACE FUNCTION public.fc_get_world_state() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); v_me public.fc_characters; v_pos public.fc_character_positions; v_cell public.fc_world_cells; v_room public.fc_world_rooms;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid; IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 SELECT * INTO v_pos FROM public.fc_character_positions WHERE character_id=v_me.id; IF v_pos.cell_id IS NULL THEN SELECT * INTO v_cell FROM public.fc_world_cells WHERE id='11000000-0000-0000-0000-000000000005'; INSERT INTO public.fc_character_positions(character_id,cell_id) VALUES(v_me.id,v_cell.id) ON CONFLICT DO NOTHING; ELSE SELECT * INTO v_cell FROM public.fc_world_cells WHERE id=v_pos.cell_id; END IF;
 SELECT * INTO v_room FROM public.fc_world_rooms WHERE id=v_cell.room_id;
 RETURN jsonb_build_object('room',to_jsonb(v_room),'cell',to_jsonb(v_cell),'nearby',coalesce((SELECT jsonb_agg(jsonb_build_object('id',c.id,'name',c.display_name,'title',c.title)) FROM public.fc_character_positions p JOIN public.fc_characters c ON c.id=p.character_id WHERE p.cell_id=v_cell.id AND c.id<>v_me.id),'[]'::jsonb));
END $$;
CREATE OR REPLACE FUNCTION public.fc_move_world(p_direction text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); v_me public.fc_characters; v_pos public.fc_character_positions; v_cell public.fc_world_cells; v_next public.fc_world_cells; dx integer:=0; dy integer:=0;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid; IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 SELECT * INTO v_pos FROM public.fc_character_positions WHERE character_id=v_me.id FOR UPDATE; IF v_pos.cell_id IS NULL THEN PERFORM public.fc_get_world_state(); SELECT * INTO v_pos FROM public.fc_character_positions WHERE character_id=v_me.id; END IF;
 SELECT * INTO v_cell FROM public.fc_world_cells WHERE id=v_pos.cell_id;
 IF p_direction='north' THEN dy:=-1; ELSIF p_direction='south' THEN dy:=1; ELSIF p_direction='west' THEN dx:=-1; ELSIF p_direction='east' THEN dx:=1; ELSE RAISE EXCEPTION '方向无效'; END IF;
 SELECT n.* INTO v_next FROM public.fc_world_cells n WHERE n.room_id=v_cell.room_id AND n.x=v_cell.x+dx AND n.y=v_cell.y+dy;
 IF v_next.id IS NULL THEN RAISE EXCEPTION '这里没有可通行的道路'; END IF;
 UPDATE public.fc_character_positions SET cell_id=v_next.id,updated_at=now() WHERE character_id=v_me.id;
 RETURN public.fc_get_world_state();
END $$;
GRANT EXECUTE ON FUNCTION public.fc_get_world_state(),public.fc_move_world(text) TO authenticated;
