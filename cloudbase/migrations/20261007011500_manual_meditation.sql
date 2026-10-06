ALTER TABLE public.fc_characters ADD COLUMN cultivating boolean NOT NULL DEFAULT false, ADD COLUMN cultivating_since timestamptz;
CREATE OR REPLACE FUNCTION public.fc_claim_cultivation() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); v_me public.fc_characters; v_minutes integer; v_rate numeric; v_room public.fc_world_rooms; v_defense boolean; v_end timestamptz;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid FOR UPDATE;
 IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 IF NOT v_me.cultivating THEN UPDATE public.fc_characters SET last_claim_at=now() WHERE id=v_me.id; RETURN public.fc_get_state(); END IF;
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
 v_rate:=v_rate*(public.fc_mind_effects(v_me.mind)->>'cultivation')::numeric*public.fc_manual_rate(v_me);
 IF v_minutes>0 THEN
  UPDATE public.fc_known_manuals SET progress=least(100,progress+v_minutes/5) WHERE character_id=v_me.id AND manual_id=v_me.equipped_mind;
  UPDATE public.fc_characters SET cultivation=least(capacity,cultivation+v_minutes*v_rate*public.fc_aura_rate(v_me.realm_index)/public.fc_aura_requirement(v_me.realm_index,v_me.realm_layer)*100),last_claim_at=CASE WHEN now()-last_claim_at>interval '12 hours' THEN now() ELSE last_claim_at+make_interval(mins=>v_minutes) END WHERE id=v_me.id;
  INSERT INTO public.fc_notices(character_id,body) VALUES(v_me.id,CASE WHEN coalesce(v_room.is_safe_city,false) THEN '城内闭关结算：修炼了 ' ELSE '阵法守护下闭关结算：修炼了 ' END||v_minutes||' 分钟，灵气收益倍率为 '||v_rate||'。');
 END IF;
 IF v_end<now() THEN UPDATE public.fc_characters SET last_claim_at=now(),cultivating=false,cultivating_since=NULL WHERE id=v_me.id; END IF;
 PERFORM public.fc_recover_attributes();
 RETURN public.fc_get_state();
END $$;


CREATE FUNCTION public.fc_start_meditation() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters; r public.fc_world_rooms;
BEGIN
 SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE;
 IF c.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 SELECT room.* INTO r FROM public.fc_character_positions p JOIN public.fc_world_cells cell ON cell.id=p.cell_id JOIN public.fc_world_rooms room ON room.id=cell.room_id WHERE p.character_id=c.id;
 IF r.id IS NULL THEN PERFORM public.fc_get_world_state(); SELECT room.* INTO r FROM public.fc_character_positions p JOIN public.fc_world_cells cell ON cell.id=p.cell_id JOIN public.fc_world_rooms room ON room.id=cell.room_id WHERE p.character_id=c.id; END IF;
 IF EXISTS(SELECT 1 FROM public.fc_city_journeys WHERE character_id=c.id) THEN RAISE EXCEPTION '官道旅行中不能闭关'; END IF;
 IF EXISTS(SELECT 1 FROM public.fc_combat_encounters WHERE character_id=c.id AND status='active') THEN RAISE EXCEPTION '战斗中不能闭关'; END IF;
 IF NOT r.is_safe_city AND NOT EXISTS(SELECT 1 FROM public.fc_defense_setups WHERE character_id=c.id AND room_id=r.id AND expires_at>now()) THEN RAISE EXCEPTION '当前没有安全闭关环境，请返回城池或布置防御阵法'; END IF;
 IF NOT c.cultivating THEN UPDATE public.fc_characters SET cultivating=true,cultivating_since=now(),last_claim_at=now() WHERE id=c.id; END IF;
 RETURN public.fc_get_state();
END $$;
CREATE FUNCTION public.fc_end_meditation() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters;
BEGIN
 SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE;
 IF c.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 PERFORM public.fc_claim_cultivation();
 UPDATE public.fc_characters SET cultivating=false,cultivating_since=NULL,last_claim_at=now() WHERE id=c.id;
 RETURN public.fc_get_state();
END $$;
REVOKE ALL ON FUNCTION public.fc_start_meditation(),public.fc_end_meditation() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fc_start_meditation(),public.fc_end_meditation() TO authenticated;
CREATE FUNCTION public.fc_combat_stops_meditation() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 PERFORM public.fc_claim_cultivation();
 UPDATE public.fc_characters SET cultivating=false,cultivating_since=NULL,last_claim_at=now() WHERE id=NEW.character_id;
 RETURN NEW;
END $$;
CREATE TRIGGER combat_stops_meditation BEFORE INSERT ON public.fc_combat_encounters FOR EACH ROW EXECUTE FUNCTION public.fc_combat_stops_meditation();
