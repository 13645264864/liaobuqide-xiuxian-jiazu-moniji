CREATE FUNCTION public.fc_cancel_city_journey() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_me public.fc_characters;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE;
 IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 PERFORM public.fc_get_world_state();
 DELETE FROM public.fc_city_journeys WHERE character_id=v_me.id;
 RETURN public.fc_get_world_state();
END $$;
REVOKE ALL ON FUNCTION public.fc_cancel_city_journey() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fc_cancel_city_journey() TO authenticated;
