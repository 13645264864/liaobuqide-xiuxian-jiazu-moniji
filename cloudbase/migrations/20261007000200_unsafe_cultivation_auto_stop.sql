UPDATE public.fc_world_rooms SET is_safe_city=true WHERE family_id IS NOT NULL AND kind IN ('building','road');
CREATE OR REPLACE FUNCTION public.fc_claim_cultivation() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); v_me public.fc_characters; v_minutes integer; v_rate numeric; v_room public.fc_world_rooms; v_defense boolean; v_end timestamptz;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid FOR UPDATE;
 IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 SELECT r.* INTO v_room FROM public.fc_character_positions p JOIN public.fc_world_cells cell ON cell.id=p.cell_id JOIN public.fc_world_rooms r ON r.id=cell.room_id WHERE p.character_id=v_me.id;
 v_end:=now();
 IF NOT coalesce(v_room.is_safe_city,false) THEN
  SELECT expires_at INTO v_end FROM public.fc_defense_setups WHERE character_id=v_me.id AND room_id=v_room.id;
  v_end:=least(now(),coalesce(v_end,v_me.last_claim_at));
 END IF;
 IF EXISTS(SELECT 1 FROM public.fc_city_journeys WHERE character_id=v_me.id) THEN v_end:=v_me.last_claim_at; END IF;
 v_minutes:=least(720,greatest(0,floor(extract(epoch FROM(v_end-v_me.last_claim_at))/60)::integer));
 v_rate:=CASE WHEN v_me.worship_until IS NOT NULL AND v_me.worship_until>now() THEN 1.10 ELSE 1.0 END;
 IF EXISTS(SELECT 1 FROM public.fc_character_positions p JOIN public.fc_world_cells c ON c.id=p.cell_id JOIN public.fc_world_rooms r ON r.id=c.room_id WHERE p.character_id=v_me.id AND r.template_id='10000000-0000-0000-0000-000000000020' AND r.family_id=v_me.family_id) THEN v_rate:=v_rate+0.50; END IF;
 v_rate:=v_rate*(public.fc_mind_effects(v_me.mind)->>'cultivation')::numeric;
 IF v_minutes>0 THEN
  UPDATE public.fc_characters SET cultivation=least(capacity,cultivation+v_minutes*v_rate*public.fc_aura_rate(v_me.realm_index)/public.fc_aura_requirement(v_me.realm_index,v_me.realm_layer)*100),last_claim_at=CASE WHEN now()-last_claim_at>interval '12 hours' THEN now() ELSE last_claim_at+make_interval(mins=>v_minutes) END WHERE id=v_me.id;
  INSERT INTO public.fc_notices(character_id,body) VALUES(v_me.id,CASE WHEN coalesce(v_room.is_safe_city,false) THEN '城内闭关结算：修炼了 ' ELSE '阵法守护下闭关结算：修炼了 ' END||v_minutes||' 分钟，灵气收益倍率为 '||v_rate||'。');
 END IF;
 IF v_end<now() THEN UPDATE public.fc_characters SET last_claim_at=now() WHERE id=v_me.id; END IF;
 PERFORM public.fc_recover_attributes();
 RETURN public.fc_get_state();
END $$;
CREATE OR REPLACE FUNCTION public.fc_prepare_defense(p_hours integer DEFAULT 2) RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters; cell public.fc_character_positions; r public.fc_world_rooms;
BEGIN SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE; IF c.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF; SELECT * INTO cell FROM public.fc_character_positions WHERE character_id=c.id; SELECT * INTO r FROM public.fc_world_rooms WHERE id=(SELECT room_id FROM public.fc_world_cells WHERE id=cell.cell_id); IF r.is_safe_city THEN RETURN jsonb_build_object('safe',true,'room',r.name,'message','城池范围内可无条件闭关。'); END IF; IF p_hours NOT BETWEEN 1 AND 12 THEN RAISE EXCEPTION '阵法守护时间为1至12小时'; END IF; PERFORM public.fc_claim_cultivation(); UPDATE public.fc_characters SET last_claim_at=now() WHERE id=c.id; INSERT INTO public.fc_defense_setups VALUES(c.id,r.id,now()+make_interval(hours=>p_hours),'金刚护身阵') ON CONFLICT(character_id,room_id) DO UPDATE SET expires_at=excluded.expires_at; RETURN jsonb_build_object('safe',false,'room',r.name,'expires_at',now()+make_interval(hours=>p_hours),'message','已布置金刚护身阵，可在阵法有效期内闭关。'); END $$;
REVOKE ALL ON FUNCTION public.fc_prepare_defense(integer) FROM PUBLIC; GRANT EXECUTE ON FUNCTION public.fc_prepare_defense(integer) TO authenticated;
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
 RETURN jsonb_build_object('cultivation_safety',jsonb_build_object('city_safe',v_room.is_safe_city,'can_cultivate',v_room.is_safe_city OR EXISTS(SELECT 1 FROM public.fc_defense_setups d WHERE d.character_id=v_me.id AND d.room_id=v_room.id AND d.expires_at>now()) AND NOT EXISTS(SELECT 1 FROM public.fc_city_journeys j WHERE j.character_id=v_me.id),'defense_until',(SELECT expires_at FROM public.fc_defense_setups WHERE character_id=v_me.id AND room_id=v_room.id)),'atlas',jsonb_build_object('states',(SELECT jsonb_agg(to_jsonb(s)) FROM public.fc_states s),'cities',(SELECT jsonb_agg(to_jsonb(c)) FROM public.fc_cities c),'roads',(SELECT jsonb_agg(to_jsonb(e)) FROM public.fc_city_roads e)),'journey',(SELECT to_jsonb(j) FROM public.fc_city_journeys j WHERE j.character_id=v_me.id),'room',to_jsonb(v_room),'cell',to_jsonb(v_cell),'cells',(SELECT jsonb_agg(to_jsonb(t) ORDER BY t.y,t.x) FROM public.fc_world_cells t WHERE t.room_id=v_room.id),'exits',coalesce((SELECT jsonb_agg(jsonb_build_object('from_cell',e.from_cell,'x',c.x,'y',c.y,'direction',e.direction,'to_room',CASE WHEN r.id='10000000-0000-0000-0000-000000000001' THEN (SELECT name FROM public.fc_world_rooms WHERE id=v_home) ELSE r.name END)) FROM public.fc_world_exits e JOIN public.fc_world_cells c ON c.id=e.from_cell JOIN public.fc_world_cells dest ON dest.id=e.to_cell JOIN public.fc_world_rooms r ON r.id=dest.room_id WHERE c.room_id=v_room.id),'[]'::jsonb),'navigation',jsonb_build_object('cells',(SELECT jsonb_agg(to_jsonb(c)) FROM public.fc_world_cells c JOIN public.fc_world_rooms r ON r.id=c.room_id WHERE (r.family_id=v_me.family_id AND r.city_id=v_room.city_id OR (r.city_id=v_room.city_id AND r.family_id IS NULL AND r.id<>'10000000-0000-0000-0000-000000000001' AND r.id::text NOT BETWEEN '10000000-0000-0000-0000-000000000010' AND '10000000-0000-0000-0000-000000000022'))),'edges',(SELECT jsonb_agg(jsonb_build_object('from',c.id,'to',n.id,'direction',d.direction)) FROM public.fc_world_cells c JOIN public.fc_world_rooms r ON r.id=c.room_id CROSS JOIN (VALUES ('north'),('south'),('east'),('west')) d(direction) JOIN public.fc_world_cells n ON n.id=CASE WHEN c.room_id='10000000-0000-0000-0000-000000000005' AND c.x=0 AND c.y=-1 AND d.direction='north' THEN (SELECT id FROM public.fc_world_cells WHERE room_id=v_home AND x=0 AND y=1) ELSE public.fc_world_next_cell(c.id,d.direction) END WHERE (r.family_id=v_me.family_id AND r.city_id=v_room.city_id OR (r.city_id=v_room.city_id AND r.family_id IS NULL AND r.id<>'10000000-0000-0000-0000-000000000001' AND r.id::text NOT BETWEEN '10000000-0000-0000-0000-000000000010' AND '10000000-0000-0000-0000-000000000022')) AND EXISTS(SELECT 1 FROM public.fc_world_rooms nr WHERE nr.id=n.room_id AND (nr.family_id IS NULL OR nr.family_id=v_me.family_id)))),'map_rooms',(SELECT jsonb_agg(to_jsonb(r)) FROM public.fc_world_rooms r WHERE (r.family_id=v_me.family_id AND r.city_id=v_room.city_id OR (r.city_id=v_room.city_id AND r.family_id IS NULL AND r.id<>'10000000-0000-0000-0000-000000000001' AND r.id::text NOT BETWEEN '10000000-0000-0000-0000-000000000010' AND '10000000-0000-0000-0000-000000000022'))),'nearby',coalesce((SELECT jsonb_agg(jsonb_build_object('id',c.id,'name',c.display_name,'title',c.title)) FROM public.fc_character_positions p JOIN public.fc_characters c ON c.id=p.character_id WHERE p.cell_id=v_cell.id AND c.id<>v_me.id AND p.updated_at>now()-interval '90 seconds'),'[]'::jsonb));
END $$;
GRANT EXECUTE ON FUNCTION public.fc_get_world_state() TO authenticated;
