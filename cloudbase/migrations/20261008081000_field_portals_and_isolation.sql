CREATE OR REPLACE FUNCTION public.fc_ensure_field_layers(p_family uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE base public.fc_world_rooms; r1 uuid;r2 uuid;r3 uuid;r uuid;i integer;door uuid;other_door uuid;
BEGIN
 SELECT * INTO base FROM public.fc_world_rooms WHERE family_id=p_family AND template_id='10000000-0000-0000-0000-000000000022';
 IF base.id IS NULL THEN RETURN;END IF;
 r1:=base.id;r2:=md5(p_family::text||':field:2')::uuid;r3:=md5(p_family::text||':field:3')::uuid;
 UPDATE public.fc_world_rooms SET field_level=1,name='家族灵田·第一层' WHERE id=r1 AND field_level IS DISTINCT FROM 1;
 FOR i IN 2..3 LOOP
 r:=CASE WHEN i=2 THEN r2 ELSE r3 END;
 INSERT INTO public.fc_world_rooms(id,state_name,city_name,name,kind,description,family_id,city_id,is_safe_city,region_depth,field_level)
 VALUES(r,base.state_name,base.city_name,'家族灵田·'||CASE WHEN i=2 THEN '第二层' ELSE '第三层' END,'building','种植竹子：先松土，再种植，10分钟成熟。',p_family,base.city_id,true,'city',i) ON CONFLICT DO NOTHING;
 INSERT INTO public.fc_world_cells(id,room_id,x,y,terrain) SELECT md5(r::text||':'||x||':'||y)::uuid,r,x,y,'field' FROM generate_series(-1,1)x CROSS JOIN generate_series(-1,1)y ON CONFLICT DO NOTHING;
 END LOOP;
 -- Remove only links between these three field rooms, then reconnect adjacent layers.
 DELETE FROM public.fc_world_exits ex USING public.fc_world_cells a,public.fc_world_cells b WHERE a.id=ex.from_cell AND b.id=ex.to_cell AND a.room_id IN(r1,r2,r3) AND b.room_id IN(r1,r2,r3);
 FOR i IN 1..2 LOOP
 SELECT id INTO door FROM public.fc_world_cells WHERE room_id=CASE WHEN i=1 THEN r1 ELSE r2 END AND x=0 AND y=-1;
 SELECT id INTO other_door FROM public.fc_world_cells WHERE room_id=CASE WHEN i=1 THEN r2 ELSE r3 END AND x=0 AND y=1;
 INSERT INTO public.fc_world_exits VALUES(door,'north',other_door) ON CONFLICT(from_cell,direction) DO UPDATE SET to_cell=EXCLUDED.to_cell;
 INSERT INTO public.fc_world_exits VALUES(other_door,'south',door) ON CONFLICT(from_cell,direction) DO UPDATE SET to_cell=EXCLUDED.to_cell;
 END LOOP;
 -- Preserve an occupied plot on a new portal by moving its state to a free plot.
 FOR i IN 1..2 LOOP
 r:=CASE WHEN i=1 THEN r1 ELSE r2 END;
 SELECT id INTO door FROM public.fc_world_cells WHERE room_id=r AND x=0 AND y=-1;
 IF EXISTS(SELECT 1 FROM public.fc_field_plots WHERE cell_id=door AND (tilled OR crop IS NOT NULL)) THEN
 SELECT p.cell_id INTO other_door FROM public.fc_field_plots p JOIN public.fc_world_cells cell ON cell.id=p.cell_id WHERE cell.room_id=r AND cell.id<>door AND NOT(cell.x=0 AND cell.y=1) AND p.crop IS NULL AND NOT p.tilled LIMIT 1;
 IF other_door IS NOT NULL THEN
 UPDATE public.fc_field_plots target SET tilled=source.tilled,crop=source.crop,planted_at=source.planted_at,planted_by=source.planted_by FROM public.fc_field_plots source WHERE target.cell_id=other_door AND source.cell_id=door;
 DELETE FROM public.fc_field_plots WHERE cell_id=door;
 END IF;
 ELSE DELETE FROM public.fc_field_plots WHERE cell_id=door;
 END IF;
 END LOOP;
 INSERT INTO public.fc_field_plots(cell_id) SELECT cell.id FROM public.fc_world_cells cell WHERE cell.room_id IN(r1,r2,r3) AND NOT(cell.x=0 AND cell.y=1) AND NOT(cell.room_id IN(r1,r2) AND cell.x=0 AND cell.y=-1) ON CONFLICT DO NOTHING;
END $$;

SELECT public.fc_ensure_field_layers(id) FROM public.fc_families;

DO $$ DECLARE d text;BEGIN
 d:=pg_get_functiondef('public.fc_field_access_guard()'::regprocedure);d:=replace(d,'c.realm_index NOT IN(2,3)','c.realm_index NOT IN(2,3,4,5)');EXECUTE d;
 d:=pg_get_functiondef('public.fc_check_home_access(uuid)'::regprocedure);d:=replace(d,'me.realm_index NOT IN(2,3)','me.realm_index NOT IN(2,3,4,5)');EXECUTE d;
END $$;

DO $$ DECLARE d text;BEGIN d:=pg_get_functiondef('public.fc_field_action(uuid,text,text)'::regprocedure);
 d:=replace(d,'SELECT * INTO plot FROM public.fc_field_plots', 'IF EXISTS(SELECT 1 FROM public.fc_world_exits WHERE from_cell=p_cell) AND p_action<>''harvest'' THEN RAISE EXCEPTION ''出口格不能种植'';END IF; SELECT * INTO plot FROM public.fc_field_plots');EXECUTE d;END $$;
