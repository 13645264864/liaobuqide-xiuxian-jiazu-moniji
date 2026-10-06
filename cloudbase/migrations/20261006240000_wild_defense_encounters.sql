ALTER TABLE public.fc_world_rooms ADD COLUMN is_safe_city boolean NOT NULL DEFAULT false;
UPDATE public.fc_world_rooms SET is_safe_city=true WHERE kind IN ('city','building') OR (kind='road' AND name NOT LIKE '%官道%' AND name NOT LIKE '%荒原%');
CREATE TABLE public.fc_defense_setups(character_id uuid NOT NULL REFERENCES public.fc_characters(id),room_id uuid NOT NULL REFERENCES public.fc_world_rooms(id),expires_at timestamptz NOT NULL,阵法_name text NOT NULL DEFAULT '金刚护身阵',PRIMARY KEY(character_id,room_id));
CREATE TABLE public.fc_wild_encounters(id uuid PRIMARY KEY,character_id uuid NOT NULL REFERENCES public.fc_characters(id),room_id uuid NOT NULL REFERENCES public.fc_world_rooms(id),created_at timestamptz NOT NULL DEFAULT now(),encounter_rate numeric NOT NULL,monster_realm_index smallint NOT NULL,monster_layer smallint NOT NULL,monster_count smallint NOT NULL,monster_name text NOT NULL,status text NOT NULL DEFAULT '待处理');
ALTER TABLE public.fc_defense_setups ENABLE ROW LEVEL SECURITY; ALTER TABLE public.fc_wild_encounters ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.fc_defense_setups,public.fc_wild_encounters FROM anon,authenticated;
CREATE FUNCTION public.fc_prepare_defense(p_hours integer DEFAULT 2) RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters; cell public.fc_world_cells; r public.fc_world_rooms;
BEGIN SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE; IF c.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF; SELECT * INTO cell FROM public.fc_character_positions WHERE character_id=c.id; SELECT * INTO r FROM public.fc_world_rooms WHERE id=(SELECT room_id FROM public.fc_world_cells WHERE id=cell.cell_id); IF r.is_safe_city THEN RETURN jsonb_build_object('safe',true,'room',r.name,'message','城池范围内可无条件闭关。'); END IF; IF p_hours NOT BETWEEN 1 AND 12 THEN RAISE EXCEPTION '阵法守护时间为1至12小时'; END IF; INSERT INTO public.fc_defense_setups VALUES(c.id,r.id,now()+make_interval(hours=>p_hours),'金刚护身阵') ON CONFLICT(character_id,room_id) DO UPDATE SET expires_at=excluded.expires_at; RETURN jsonb_build_object('safe',false,'room',r.name,'expires_at',now()+make_interval(hours=>p_hours),'message','已布置金刚护身阵，可在阵法有效期内闭关。'); END $$;
REVOKE ALL ON FUNCTION public.fc_prepare_defense(integer) FROM PUBLIC; GRANT EXECUTE ON FUNCTION public.fc_prepare_defense(integer) TO authenticated;
CREATE FUNCTION public.fc_get_wild_encounter() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters; p public.fc_character_positions; cell public.fc_world_cells; r public.fc_world_rooms; e public.fc_wild_encounters; chance numeric; maxr integer; mr integer; ml integer;
BEGIN SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid(); SELECT * INTO p FROM public.fc_character_positions WHERE character_id=c.id; SELECT * INTO cell FROM public.fc_world_cells WHERE id=p.cell_id; SELECT * INTO r FROM public.fc_world_rooms WHERE id=cell.room_id; SELECT * INTO e FROM public.fc_wild_encounters WHERE character_id=c.id AND status='待处理' ORDER BY created_at DESC LIMIT 1; IF e.id IS NOT NULL THEN RETURN jsonb_build_object('encounter',to_jsonb(e)); END IF; RETURN jsonb_build_object('encounter',null,'room',r.name,'encounter_rate',r.encounter_rate); END $$;
REVOKE ALL ON FUNCTION public.fc_get_wild_encounter() FROM PUBLIC; GRANT EXECUTE ON FUNCTION public.fc_get_wild_encounter() TO authenticated;
CREATE OR REPLACE FUNCTION public.fc_claim_cultivation() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); v_me public.fc_characters; v_minutes integer; v_rate numeric; v_room public.fc_world_rooms; v_defense boolean;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid FOR UPDATE;
 IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 SELECT r.* INTO v_room FROM public.fc_character_positions p JOIN public.fc_world_cells cell ON cell.id=p.cell_id JOIN public.fc_world_rooms r ON r.id=cell.room_id WHERE p.character_id=v_me.id;
 v_defense:=EXISTS(SELECT 1 FROM public.fc_defense_setups d WHERE d.character_id=v_me.id AND d.room_id=v_room.id AND d.expires_at>now());
 IF coalesce(v_room.is_safe_city,false)=false AND NOT v_defense THEN RAISE EXCEPTION '野外闭关需要先布置防御阵法'; END IF;
 v_minutes:=least(720,greatest(0,floor(extract(epoch FROM(now()-v_me.last_claim_at))/60)::integer));
 v_rate:=CASE WHEN v_me.worship_until IS NOT NULL AND v_me.worship_until>now() THEN 1.10 ELSE 1.0 END;
 IF EXISTS(SELECT 1 FROM public.fc_character_positions p JOIN public.fc_world_cells c ON c.id=p.cell_id JOIN public.fc_world_rooms r ON r.id=c.room_id WHERE p.character_id=v_me.id AND r.template_id='10000000-0000-0000-0000-000000000020' AND r.family_id=v_me.family_id) THEN v_rate:=v_rate+0.50; END IF;
 v_rate:=v_rate*(public.fc_mind_effects(v_me.mind)->>'cultivation')::numeric;
 IF v_minutes>0 THEN
  UPDATE public.fc_characters SET cultivation=least(capacity,cultivation+v_minutes*v_rate*public.fc_aura_rate(v_me.realm_index)/public.fc_aura_requirement(v_me.realm_index,v_me.realm_layer)*100),last_claim_at=CASE WHEN now()-last_claim_at>interval '12 hours' THEN now() ELSE last_claim_at+make_interval(mins=>v_minutes) END WHERE id=v_me.id;
  INSERT INTO public.fc_notices(character_id,body) VALUES(v_me.id,CASE WHEN coalesce(v_room.is_safe_city,false) THEN '城内闭关结算：修炼了 ' ELSE '阵法守护下闭关结算：修炼了 ' END||v_minutes||' 分钟，灵气收益倍率为 '||v_minutes||' 分钟，灵气收益倍率为 '||v_rate||'。');
 END IF;
 PERFORM public.fc_recover_attributes();
 RETURN public.fc_get_state();
END $$;
CREATE OR REPLACE FUNCTION public.fc_move_world(p_direction text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); v_me public.fc_characters; v_pos public.fc_character_positions; v_cell public.fc_world_cells; v_next public.fc_world_cells; dx integer:=0; dy integer:=0;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid; IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 PERFORM public.fc_get_world_state(); SELECT * INTO v_pos FROM public.fc_character_positions WHERE character_id=v_me.id FOR UPDATE; IF v_pos.cell_id IS NULL THEN PERFORM public.fc_get_world_state(); SELECT * INTO v_pos FROM public.fc_character_positions WHERE character_id=v_me.id; END IF;
 IF EXISTS(SELECT 1 FROM public.fc_city_journeys WHERE character_id=v_me.id) THEN RAISE EXCEPTION '正在城际旅行，抵达前不能移动'; END IF;
 SELECT * INTO v_cell FROM public.fc_world_cells WHERE id=v_pos.cell_id;
 IF p_direction='north' THEN dy:=-1; ELSIF p_direction='south' THEN dy:=1; ELSIF p_direction='west' THEN dx:=-1; ELSIF p_direction='east' THEN dx:=1; ELSE RAISE EXCEPTION '方向无效'; END IF;
 SELECT n.* INTO v_next FROM public.fc_world_cells n WHERE n.id=CASE WHEN v_cell.room_id='10000000-0000-0000-0000-000000000005' AND v_cell.x=0 AND v_cell.y=-1 AND p_direction='north' THEN (SELECT c.id FROM public.fc_world_cells c JOIN public.fc_world_rooms r ON r.id=c.room_id WHERE r.family_id=v_me.family_id AND r.template_id='10000000-0000-0000-0000-000000000001' AND c.x=0 AND c.y=1) ELSE public.fc_world_next_cell(v_cell.id,p_direction) END;
 IF v_next.id IS NULL THEN RAISE EXCEPTION '这里没有可通行的道路'; END IF;
 PERFORM public.fc_claim_cultivation();
 UPDATE public.fc_character_positions SET cell_id=v_next.id,updated_at=now() WHERE character_id=v_me.id;
 PERFORM public.fc_roll_wild_encounter(v_me.id);
 RETURN public.fc_get_world_state();
END $$;
GRANT EXECUTE ON FUNCTION public.fc_get_world_state(),public.fc_move_world(text) TO authenticated;
CREATE FUNCTION public.fc_roll_wild_encounter(p_character uuid) RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE cell public.fc_world_cells; r public.fc_world_rooms; c public.fc_characters; chance numeric; maxr integer; mr integer; ml integer;
BEGIN SELECT * INTO c FROM public.fc_characters WHERE id=p_character; SELECT * INTO cell FROM public.fc_world_cells WHERE id=(SELECT cell_id FROM public.fc_character_positions WHERE character_id=p_character); SELECT * INTO r FROM public.fc_world_rooms WHERE id=cell.room_id; IF r.kind NOT IN ('wilderness','forest') THEN RETURN; END IF; IF EXISTS(SELECT 1 FROM public.fc_wild_encounters WHERE character_id=p_character AND status='待处理') THEN RETURN; END IF; chance:=r.encounter_rate*100; IF random()*100>chance THEN RETURN; END IF; maxr:=least(5,c.realm_index+1); mr:=greatest(0,least(maxr,c.realm_index+CASE WHEN random()<0.35 THEN 1 ELSE 0 END)); ml:=1+floor(random()*9)::integer; INSERT INTO public.fc_wild_encounters VALUES(gen_random_uuid(),p_character,r.id,now(),r.encounter_rate,mr,ml,1+floor(random()*3)::integer,CASE mr WHEN 0 THEN '炼气妖兽' WHEN 1 THEN '筑基妖兽' WHEN 2 THEN '金丹妖兽' WHEN 3 THEN '元婴妖兽' WHEN 4 THEN '出窍妖兽' ELSE '化神妖兽' END,'待处理'); END $$;
REVOKE ALL ON FUNCTION public.fc_roll_wild_encounter(uuid) FROM PUBLIC;
