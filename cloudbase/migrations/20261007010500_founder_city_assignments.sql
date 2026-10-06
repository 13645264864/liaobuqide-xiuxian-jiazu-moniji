UPDATE public.fc_families f SET city_id=c.registration_order FROM public.fc_characters c WHERE c.id=f.leader_id AND c.is_founder AND c.registration_order BETWEEN 1 AND 50;
CREATE UNIQUE INDEX fc_founder_city_unique ON public.fc_families(city_id) WHERE city_id BETWEEN 1 AND 50;
CREATE FUNCTION public.fc_founder_city_before_insert() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE n integer;
BEGIN
 SELECT registration_order INTO n FROM public.fc_characters WHERE id=NEW.leader_id AND is_founder;
 IF n BETWEEN 1 AND 50 THEN NEW.city_id:=n; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER founder_city_before_insert BEFORE INSERT ON public.fc_families FOR EACH ROW EXECUTE FUNCTION public.fc_founder_city_before_insert();
CREATE OR REPLACE FUNCTION public.fc_ensure_family_home(p_family uuid) RETURNS uuid LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=public,pg_temp AS $$
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
 UPDATE public.fc_world_rooms SET city_id=coalesce((SELECT city_id FROM public.fc_families WHERE id=p_family),1) WHERE family_id=p_family;
 UPDATE public.fc_world_rooms r SET city_name=ct.name,state_name=st.name,is_safe_city=true FROM public.fc_families f JOIN public.fc_cities ct ON ct.id=f.city_id JOIN public.fc_states st ON st.id=ct.state_id WHERE r.family_id=f.id AND f.id=p_family;
 UPDATE public.fc_world_exits e SET to_cell=dest.id FROM public.fc_world_cells src JOIN public.fc_world_rooms home ON home.id=src.room_id JOIN public.fc_families f ON f.id=home.family_id JOIN public.fc_world_rooms street ON street.city_id=f.city_id AND street.family_id IS NULL AND (street.id='10000000-0000-0000-0000-000000000005' OR street.template_id='10000000-0000-0000-0000-000000000005') JOIN public.fc_world_cells dest ON dest.room_id=street.id AND dest.x=0 AND dest.y=-1 WHERE home.family_id=p_family AND home.template_id='10000000-0000-0000-0000-000000000001' AND src.x=0 AND src.y=1 AND e.from_cell=src.id AND e.direction='south';
 RETURN v_home;
END $$;
REVOKE ALL ON FUNCTION public.fc_ensure_family_home(uuid) FROM PUBLIC;

CREATE FUNCTION public.fc_player_next_cell(p_cell uuid,p_direction text) RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_world_cells; r public.fc_world_rooms; family public.fc_families;
BEGIN
 SELECT * INTO c FROM public.fc_world_cells WHERE id=p_cell;
 SELECT * INTO r FROM public.fc_world_rooms WHERE id=c.room_id;
 IF (r.id='10000000-0000-0000-0000-000000000005' OR r.template_id='10000000-0000-0000-0000-000000000005') AND c.x=0 AND c.y=-1 AND p_direction='north' THEN
  SELECT f.* INTO family FROM public.fc_families f JOIN public.fc_characters me ON me.family_id=f.id WHERE me.owner_id=public.fc_require_uid();
  IF family.city_id=r.city_id THEN
   RETURN (SELECT cell.id FROM public.fc_world_cells cell JOIN public.fc_world_rooms home ON home.id=cell.room_id WHERE home.family_id=family.id AND home.template_id='10000000-0000-0000-0000-000000000001' AND cell.x=0 AND cell.y=1);
  END IF;
  RETURN NULL;
 END IF;
 RETURN public.fc_world_next_cell(p_cell,p_direction);
END $$;
REVOKE ALL ON FUNCTION public.fc_player_next_cell(uuid,text) FROM PUBLIC;
CREATE OR REPLACE FUNCTION public.fc_get_world_state() RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=public,pg_temp AS $$
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
 RETURN jsonb_build_object('cultivation_safety',jsonb_build_object('city_safe',v_room.is_safe_city,'can_cultivate',v_room.is_safe_city OR EXISTS(SELECT 1 FROM public.fc_defense_setups d WHERE d.character_id=v_me.id AND d.room_id=v_room.id AND d.expires_at>now()) AND NOT EXISTS(SELECT 1 FROM public.fc_city_journeys j WHERE j.character_id=v_me.id),'defense_until',(SELECT expires_at FROM public.fc_defense_setups WHERE character_id=v_me.id AND room_id=v_room.id)),'encounter',(SELECT to_jsonb(e) FROM public.fc_wild_encounters e WHERE e.character_id=v_me.id AND e.room_id=v_room.id AND e.status='待处理' ORDER BY e.created_at DESC LIMIT 1),'atlas',jsonb_build_object('states',(SELECT jsonb_agg(to_jsonb(s)) FROM public.fc_states s),'cities',(SELECT jsonb_agg(to_jsonb(c)) FROM public.fc_cities c),'roads',(SELECT jsonb_agg(to_jsonb(e)) FROM public.fc_city_roads e)),'journey',(SELECT to_jsonb(j) FROM public.fc_city_journeys j WHERE j.character_id=v_me.id),'room',to_jsonb(v_room),'cell',to_jsonb(v_cell),'cells',(SELECT jsonb_agg(to_jsonb(t) ORDER BY t.y,t.x) FROM public.fc_world_cells t WHERE t.room_id=v_room.id),'exits',CASE WHEN (v_room.id='10000000-0000-0000-0000-000000000005' OR v_room.template_id='10000000-0000-0000-0000-000000000005') AND v_room.city_id=(SELECT city_id FROM public.fc_families WHERE id=v_me.family_id) THEN jsonb_build_array(jsonb_build_object('from_cell',(SELECT id FROM public.fc_world_cells WHERE room_id=v_room.id AND x=0 AND y=-1),'x',0,'y',-1,'direction','north','to_room',(SELECT name FROM public.fc_world_rooms WHERE id=v_home))) ELSE '[]'::jsonb END || coalesce((SELECT jsonb_agg(jsonb_build_object('from_cell',e.from_cell,'x',c.x,'y',c.y,'direction',e.direction,'to_room',CASE WHEN r.id='10000000-0000-0000-0000-000000000001' THEN (SELECT name FROM public.fc_world_rooms WHERE id=v_home) ELSE r.name END)) FROM public.fc_world_exits e JOIN public.fc_world_cells c ON c.id=e.from_cell JOIN public.fc_world_cells dest ON dest.id=e.to_cell JOIN public.fc_world_rooms r ON r.id=dest.room_id WHERE c.room_id=v_room.id AND NOT (v_room.id='10000000-0000-0000-0000-000000000005' AND e.direction='north' AND c.x=0 AND c.y=-1)),'[]'::jsonb),'navigation',jsonb_build_object('cells',(SELECT jsonb_agg(to_jsonb(c)) FROM public.fc_world_cells c JOIN public.fc_world_rooms r ON r.id=c.room_id WHERE (r.family_id=v_me.family_id AND r.city_id=v_room.city_id OR (r.city_id=v_room.city_id AND r.family_id IS NULL AND r.id<>'10000000-0000-0000-0000-000000000001' AND r.id::text NOT BETWEEN '10000000-0000-0000-0000-000000000010' AND '10000000-0000-0000-0000-000000000022'))),'edges',(SELECT jsonb_agg(jsonb_build_object('from',c.id,'to',n.id,'direction',d.direction)) FROM public.fc_world_cells c JOIN public.fc_world_rooms r ON r.id=c.room_id CROSS JOIN (VALUES ('north'),('south'),('east'),('west')) d(direction) JOIN public.fc_world_cells n ON n.id=public.fc_player_next_cell(c.id,d.direction) WHERE (r.family_id=v_me.family_id AND r.city_id=v_room.city_id OR (r.city_id=v_room.city_id AND r.family_id IS NULL AND r.id<>'10000000-0000-0000-0000-000000000001' AND r.id::text NOT BETWEEN '10000000-0000-0000-0000-000000000010' AND '10000000-0000-0000-0000-000000000022')) AND EXISTS(SELECT 1 FROM public.fc_world_rooms nr WHERE nr.id=n.room_id AND (nr.family_id IS NULL OR nr.family_id=v_me.family_id)))),'map_rooms',(SELECT jsonb_agg(to_jsonb(r)) FROM public.fc_world_rooms r WHERE (r.family_id=v_me.family_id AND r.city_id=v_room.city_id OR (r.city_id=v_room.city_id AND r.family_id IS NULL AND r.id<>'10000000-0000-0000-0000-000000000001' AND r.id::text NOT BETWEEN '10000000-0000-0000-0000-000000000010' AND '10000000-0000-0000-0000-000000000022'))),'nearby',coalesce((SELECT jsonb_agg(jsonb_build_object('id',c.id,'name',c.display_name,'title',c.title)) FROM public.fc_character_positions p JOIN public.fc_characters c ON c.id=p.character_id WHERE p.cell_id=v_cell.id AND c.id<>v_me.id AND p.updated_at>now()-interval '90 seconds'),'[]'::jsonb));
END $$;
GRANT EXECUTE ON FUNCTION public.fc_get_world_state() TO authenticated;

CREATE OR REPLACE FUNCTION public.fc_move_world(p_direction text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); v_me public.fc_characters; v_pos public.fc_character_positions; v_cell public.fc_world_cells; v_next public.fc_world_cells; dx integer:=0; dy integer:=0;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid; IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 PERFORM public.fc_get_world_state(); SELECT * INTO v_pos FROM public.fc_character_positions WHERE character_id=v_me.id FOR UPDATE; IF v_pos.cell_id IS NULL THEN PERFORM public.fc_get_world_state(); SELECT * INTO v_pos FROM public.fc_character_positions WHERE character_id=v_me.id; END IF;
 IF EXISTS(SELECT 1 FROM public.fc_city_journeys WHERE character_id=v_me.id) THEN RAISE EXCEPTION '正在城际旅行，抵达前不能移动'; END IF;
 SELECT * INTO v_cell FROM public.fc_world_cells WHERE id=v_pos.cell_id;
 IF p_direction='north' THEN dy:=-1; ELSIF p_direction='south' THEN dy:=1; ELSIF p_direction='west' THEN dx:=-1; ELSIF p_direction='east' THEN dx:=1; ELSE RAISE EXCEPTION '方向无效'; END IF;
 SELECT n.* INTO v_next FROM public.fc_world_cells n WHERE n.id=public.fc_player_next_cell(v_cell.id,p_direction);
 IF v_next.id IS NULL THEN RAISE EXCEPTION '这里没有可通行的道路'; END IF;
 IF EXISTS(SELECT 1 FROM public.fc_combat_encounters WHERE character_id=v_me.id AND status='active') THEN RAISE EXCEPTION '战斗中不能移动'; END IF; IF EXISTS(SELECT 1 FROM public.fc_world_rooms WHERE id=v_next.room_id AND (region_depth='inner' AND v_me.realm_index<2 OR region_depth='core' AND v_me.realm_index<4)) THEN RAISE EXCEPTION '内围需金丹及以上，核心需出窍及以上'; END IF; PERFORM public.fc_claim_cultivation();
 UPDATE public.fc_character_positions SET cell_id=v_next.id,updated_at=now() WHERE character_id=v_me.id;
 UPDATE public.fc_characters SET lure_room=NULL WHERE id=v_me.id AND lure_room IS DISTINCT FROM v_next.room_id;
 RETURN public.fc_get_world_state();
END $$;
GRANT EXECUTE ON FUNCTION public.fc_get_world_state(),public.fc_move_world(text) TO authenticated;

SELECT public.fc_ensure_family_home(id) FROM public.fc_families;
-- Existing members are relocated to their own home, keeping old possessions and cultivation.
DELETE FROM public.fc_city_journeys j USING public.fc_characters c WHERE c.id=j.character_id AND c.family_id IN (SELECT f.id FROM public.fc_families f JOIN public.fc_characters leader ON leader.id=f.leader_id WHERE leader.is_founder);
UPDATE public.fc_combat_encounters e SET status='cancelled',result='宗族迁驻，遭遇已结束' FROM public.fc_characters c WHERE c.id=e.character_id AND e.status='active' AND c.family_id IN (SELECT f.id FROM public.fc_families f JOIN public.fc_characters leader ON leader.id=f.leader_id WHERE leader.is_founder);
INSERT INTO public.fc_character_positions(character_id,cell_id)
 SELECT c.id,cell.id FROM public.fc_characters c JOIN public.fc_families f ON f.id=c.family_id JOIN public.fc_characters leader ON leader.id=f.leader_id JOIN public.fc_world_rooms home ON home.family_id=f.id AND home.template_id='10000000-0000-0000-0000-000000000001' JOIN public.fc_world_cells cell ON cell.room_id=home.id AND cell.x=0 AND cell.y=0 WHERE leader.is_founder
 ON CONFLICT(character_id) DO UPDATE SET cell_id=excluded.cell_id,updated_at=now();
UPDATE public.fc_characters c SET last_claim_at=now(),lure_room=NULL,location=ct.name||' · '||f.name||'宅邸' FROM public.fc_families f JOIN public.fc_cities ct ON ct.id=f.city_id WHERE c.family_id=f.id AND EXISTS(SELECT 1 FROM public.fc_characters leader WHERE leader.id=f.leader_id AND leader.is_founder);
