CREATE FUNCTION public.fc_rename_character(p_name text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE me uuid;name text:=trim(p_name);
BEGIN
 SELECT id INTO me FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE;
 IF me IS NULL THEN RAISE EXCEPTION '请先入世';END IF;
 IF name IS NULL OR char_length(name) NOT BETWEEN 2 AND 16 OR name~'[[:cntrl:]]' THEN RAISE EXCEPTION '昵称需要2至16个字符';END IF;
 PERFORM pg_advisory_xact_lock(hashtext('nickname:'||name));
 IF EXISTS(SELECT 1 FROM public.fc_characters WHERE id<>me AND display_name=name AND retired_at IS NULL) THEN RAISE EXCEPTION '昵称已被使用';END IF;
 UPDATE public.fc_characters SET display_name=name WHERE id=me;RETURN public.fc_get_state();
END $$;
REVOKE ALL ON FUNCTION public.fc_rename_character(text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.fc_rename_character(text) TO authenticated;
