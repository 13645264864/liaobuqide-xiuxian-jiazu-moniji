ALTER TABLE public.fc_world_rooms ADD COLUMN family_id uuid REFERENCES public.fc_families(id), ADD COLUMN template_id uuid;
CREATE FUNCTION public.fc_ensure_family_home(p_family uuid) RETURNS uuid LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_name text; v_home uuid:=md5(p_family::text||':room:10000000-0000-0000-0000-000000000001')::uuid;
BEGIN
 SELECT name INTO v_name FROM public.fc_families WHERE id=p_family; IF v_name IS NULL THEN RAISE EXCEPTION '宗族不存在'; END IF;
 PERFORM pg_advisory_xact_lock(hashtext(p_family::text));
 INSERT INTO public.fc_world_rooms(id,state_name,city_name,name,kind,danger,encounter_rate,description,family_id,template_id)
 SELECT md5(p_family::text||':room:'||id::text)::uuid,state_name,city_name,CASE WHEN id='10000000-0000-0000-0000-000000000001' THEN v_name||'宅邸' ELSE name END,kind,danger,encounter_rate,description,p_family,id FROM public.fc_world_rooms WHERE family_id IS NULL AND (id='10000000-0000-0000-0000-000000000001' OR id::text BETWEEN '10000000-0000-0000-0000-000000000010' AND '10000000-0000-0000-0000-000000000022') ON CONFLICT DO NOTHING;
 UPDATE public.fc_world_rooms SET name=v_name||'宅邸',description='属于'||v_name||'的宗族宅邸。族长与族人都在这里入世，南侧通向城中府前街，北侧通向本族内院。' WHERE id=v_home;
 INSERT INTO public.fc_world_cells(id,room_id,x,y,terrain) SELECT md5(p_family::text||':cell:'||c.id::text)::uuid,r.id,c.x,c.y,c.terrain FROM public.fc_world_rooms r JOIN public.fc_world_cells c ON c.room_id=r.template_id WHERE r.family_id=p_family ON CONFLICT DO NOTHING;
 INSERT INTO public.fc_world_exits(from_cell,direction,to_cell)
 SELECT md5(p_family::text||':cell:'||e.from_cell::text)::uuid,e.direction,CASE WHEN dest.room_id='10000000-0000-0000-0000-000000000005' THEN e.to_cell ELSE md5(p_family::text||':cell:'||e.to_cell::text)::uuid END
 FROM public.fc_world_exits e JOIN public.fc_world_cells src ON src.id=e.from_cell JOIN public.fc_world_rooms r ON r.template_id=src.room_id AND r.family_id=p_family JOIN public.fc_world_cells dest ON dest.id=e.to_cell ON CONFLICT DO NOTHING;
 RETURN v_home;
END $$;
REVOKE ALL ON FUNCTION public.fc_ensure_family_home(uuid) FROM PUBLIC;
CREATE OR REPLACE FUNCTION public.fc_get_world_state() RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); v_me public.fc_characters; v_pos public.fc_character_positions; v_cell public.fc_world_cells; v_room public.fc_world_rooms; v_home uuid;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid; IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 v_home:=public.fc_ensure_family_home(v_me.family_id);
 SELECT * INTO v_pos FROM public.fc_character_positions WHERE character_id=v_me.id;
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
 RETURN jsonb_build_object('room',to_jsonb(v_room),'cell',to_jsonb(v_cell),'cells',(SELECT jsonb_agg(to_jsonb(t) ORDER BY t.y,t.x) FROM public.fc_world_cells t WHERE t.room_id=v_room.id),'exits',coalesce((SELECT jsonb_agg(jsonb_build_object('from_cell',e.from_cell,'x',c.x,'y',c.y,'direction',e.direction,'to_room',CASE WHEN r.id='10000000-0000-0000-0000-000000000001' THEN (SELECT name FROM public.fc_world_rooms WHERE id=v_home) ELSE r.name END)) FROM public.fc_world_exits e JOIN public.fc_world_cells c ON c.id=e.from_cell JOIN public.fc_world_cells dest ON dest.id=e.to_cell JOIN public.fc_world_rooms r ON r.id=dest.room_id WHERE c.room_id=v_room.id),'[]'::jsonb),'navigation',jsonb_build_object('cells',(SELECT jsonb_agg(to_jsonb(c)) FROM public.fc_world_cells c JOIN public.fc_world_rooms r ON r.id=c.room_id WHERE (r.family_id=v_me.family_id OR (r.family_id IS NULL AND r.id<>'10000000-0000-0000-0000-000000000001' AND r.id::text NOT BETWEEN '10000000-0000-0000-0000-000000000010' AND '10000000-0000-0000-0000-000000000022'))),'edges',(SELECT jsonb_agg(jsonb_build_object('from',c.id,'to',n.id,'direction',d.direction)) FROM public.fc_world_cells c JOIN public.fc_world_rooms r ON r.id=c.room_id CROSS JOIN (VALUES ('north'),('south'),('east'),('west')) d(direction) JOIN public.fc_world_cells n ON n.id=CASE WHEN c.room_id='10000000-0000-0000-0000-000000000005' AND c.x=0 AND c.y=-1 AND d.direction='north' THEN (SELECT id FROM public.fc_world_cells WHERE room_id=v_home AND x=0 AND y=1) ELSE public.fc_world_next_cell(c.id,d.direction) END WHERE (r.family_id=v_me.family_id OR (r.family_id IS NULL AND r.id<>'10000000-0000-0000-0000-000000000001' AND r.id::text NOT BETWEEN '10000000-0000-0000-0000-000000000010' AND '10000000-0000-0000-0000-000000000022')) AND EXISTS(SELECT 1 FROM public.fc_world_rooms nr WHERE nr.id=n.room_id AND (nr.family_id IS NULL OR nr.family_id=v_me.family_id)))),'map_rooms',(SELECT jsonb_agg(to_jsonb(r)) FROM public.fc_world_rooms r WHERE (r.family_id=v_me.family_id OR (r.family_id IS NULL AND r.id<>'10000000-0000-0000-0000-000000000001' AND r.id::text NOT BETWEEN '10000000-0000-0000-0000-000000000010' AND '10000000-0000-0000-0000-000000000022'))),'nearby',coalesce((SELECT jsonb_agg(jsonb_build_object('id',c.id,'name',c.display_name,'title',c.title)) FROM public.fc_character_positions p JOIN public.fc_characters c ON c.id=p.character_id WHERE p.cell_id=v_cell.id AND c.id<>v_me.id AND p.updated_at>now()-interval '90 seconds'),'[]'::jsonb));
END $$;
GRANT EXECUTE ON FUNCTION public.fc_get_world_state() TO authenticated;
CREATE OR REPLACE FUNCTION public.fc_move_world(p_direction text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); v_me public.fc_characters; v_pos public.fc_character_positions; v_cell public.fc_world_cells; v_next public.fc_world_cells; dx integer:=0; dy integer:=0;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid; IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 PERFORM public.fc_get_world_state(); SELECT * INTO v_pos FROM public.fc_character_positions WHERE character_id=v_me.id FOR UPDATE; IF v_pos.cell_id IS NULL THEN PERFORM public.fc_get_world_state(); SELECT * INTO v_pos FROM public.fc_character_positions WHERE character_id=v_me.id; END IF;
 SELECT * INTO v_cell FROM public.fc_world_cells WHERE id=v_pos.cell_id;
 IF p_direction='north' THEN dy:=-1; ELSIF p_direction='south' THEN dy:=1; ELSIF p_direction='west' THEN dx:=-1; ELSIF p_direction='east' THEN dx:=1; ELSE RAISE EXCEPTION '方向无效'; END IF;
 SELECT n.* INTO v_next FROM public.fc_world_cells n WHERE n.id=CASE WHEN v_cell.room_id='10000000-0000-0000-0000-000000000005' AND v_cell.x=0 AND v_cell.y=-1 AND p_direction='north' THEN (SELECT c.id FROM public.fc_world_cells c JOIN public.fc_world_rooms r ON r.id=c.room_id WHERE r.family_id=v_me.family_id AND r.template_id='10000000-0000-0000-0000-000000000001' AND c.x=0 AND c.y=1) ELSE public.fc_world_next_cell(v_cell.id,p_direction) END;
 IF v_next.id IS NULL THEN RAISE EXCEPTION '这里没有可通行的道路'; END IF;
 PERFORM public.fc_claim_cultivation();
 UPDATE public.fc_character_positions SET cell_id=v_next.id,updated_at=now() WHERE character_id=v_me.id;
 RETURN public.fc_get_world_state();
END $$;
GRANT EXECUTE ON FUNCTION public.fc_get_world_state(),public.fc_move_world(text) TO authenticated;
CREATE OR REPLACE FUNCTION public.fc_claim_cultivation() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); v_me public.fc_characters; v_minutes integer; v_rate numeric;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid FOR UPDATE;
 IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 v_minutes:=least(720,greatest(0,floor(extract(epoch FROM(now()-v_me.last_claim_at))/60)::integer));
 v_rate:=CASE WHEN v_me.worship_until IS NOT NULL AND v_me.worship_until>now() THEN 1.10 ELSE 1.0 END;
 IF EXISTS(SELECT 1 FROM public.fc_character_positions p JOIN public.fc_world_cells c ON c.id=p.cell_id JOIN public.fc_world_rooms r ON r.id=c.room_id WHERE p.character_id=v_me.id AND r.template_id='10000000-0000-0000-0000-000000000020' AND r.family_id=v_me.family_id) THEN v_rate:=v_rate+0.50; END IF;
 IF v_minutes>0 THEN
  UPDATE public.fc_characters SET cultivation=least(capacity,cultivation+v_minutes*v_rate),last_claim_at=CASE WHEN now()-last_claim_at>interval '12 hours' THEN now() ELSE last_claim_at+make_interval(mins=>v_minutes) END WHERE id=v_me.id;
  INSERT INTO public.fc_notices(character_id,body) VALUES(v_me.id,'闭关结算：修炼了 '||v_minutes||' 分钟，灵气收益倍率为 '||v_rate||'。');
 END IF;
 RETURN public.fc_get_state();
END $$;
