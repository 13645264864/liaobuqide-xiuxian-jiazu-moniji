-- Existing family halls use this template; retain their rooms and connections.
UPDATE public.fc_world_cells cell SET terrain='family_statue'
FROM public.fc_world_rooms r WHERE r.id=cell.room_id
AND (r.template_id='10000000-0000-0000-0000-000000000011' OR r.id='10000000-0000-0000-0000-000000000011')
AND cell.x=0 AND cell.y=-1;

CREATE FUNCTION public.fc_mark_family_statue() RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN
 IF NEW.x=0 AND NEW.y=-1 AND EXISTS(SELECT 1 FROM public.fc_world_rooms r WHERE r.id=NEW.room_id AND (r.template_id='10000000-0000-0000-0000-000000000011' OR r.id='10000000-0000-0000-0000-000000000011')) THEN NEW.terrain:='family_statue'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER mark_family_statue BEFORE INSERT ON public.fc_world_cells FOR EACH ROW EXECUTE FUNCTION public.fc_mark_family_statue();
REVOKE ALL ON FUNCTION public.fc_mark_family_statue() FROM PUBLIC,authenticated,anon;

CREATE OR REPLACE FUNCTION public.fc_worship_ancestral_hall() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters;
BEGIN
 SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE;
 IF c.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.fc_character_positions p JOIN public.fc_world_cells cell ON cell.id=p.cell_id JOIN public.fc_world_rooms r ON r.id=cell.room_id WHERE p.character_id=c.id AND r.family_id=c.family_id AND r.template_id='10000000-0000-0000-0000-000000000011' AND cell.terrain='family_statue') THEN RAISE EXCEPTION '请到本族宗祠的家族神像前祭拜';END IF;
 IF EXISTS(SELECT 1 FROM public.fc_city_journeys WHERE character_id=c.id) OR EXISTS(SELECT 1 FROM public.fc_combat_encounters WHERE character_id=c.id AND status='active') THEN RAISE EXCEPTION '旅行或战斗中不能祭拜';END IF;
 IF c.worship_until>now() THEN RAISE EXCEPTION '宗祠修炼加成仍在生效';END IF;
 PERFORM public.fc_claim_cultivation();
 UPDATE public.fc_characters SET worship_until=now()+interval '2 hours',worship_bonus=0.10 WHERE id=c.id;
 RETURN jsonb_build_object('message','祭拜成功：宗祠修炼速度临时增加10%，持续2小时。','state',public.fc_get_state());
END $$;
REVOKE ALL ON FUNCTION public.fc_worship_ancestral_hall() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.fc_worship_ancestral_hall() TO authenticated;
