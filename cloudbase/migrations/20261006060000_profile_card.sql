ALTER TABLE public.fc_characters ADD COLUMN IF NOT EXISTS title text NOT NULL DEFAULT '初入仙途';
ALTER TABLE public.fc_characters ADD COLUMN IF NOT EXISTS profile text NOT NULL DEFAULT '';
ALTER TABLE public.fc_characters ADD COLUMN IF NOT EXISTS location text NOT NULL DEFAULT '家族领地';
ALTER TABLE public.fc_characters ADD COLUMN IF NOT EXISTS avatar_key text;
CREATE TABLE IF NOT EXISTS public.fc_relationships (
 owner_id uuid NOT NULL REFERENCES public.fc_characters(id), target_id uuid NOT NULL REFERENCES public.fc_characters(id), relation text NOT NULL CHECK(relation IN ('friend','enemy')), created_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(owner_id,target_id)
);
ALTER TABLE public.fc_relationships ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.fc_relationships FROM anon,authenticated;
CREATE OR REPLACE FUNCTION public.fc_update_profile(p_title text,p_profile text,p_location text,p_avatar_key text DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); v_me public.fc_characters;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid FOR UPDATE;
 IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 IF char_length(p_title)>32 OR char_length(p_profile)>240 OR char_length(p_location)>80 THEN RAISE EXCEPTION '资料卡内容超出长度限制'; END IF;
 UPDATE public.fc_characters SET title=trim(p_title),profile=trim(p_profile),location=trim(p_location),avatar_key=coalesce(p_avatar_key,avatar_key) WHERE id=v_me.id;
 RETURN public.fc_get_state();
END $$;
CREATE OR REPLACE FUNCTION public.fc_set_relationship(p_target_id uuid,p_relation text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); v_me public.fc_characters;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid;
 IF v_me.id IS NULL OR p_target_id=v_me.id OR p_relation NOT IN('friend','enemy') THEN RAISE EXCEPTION '关系设置无效'; END IF;
 INSERT INTO public.fc_relationships(owner_id,target_id,relation) VALUES(v_me.id,p_target_id,p_relation) ON CONFLICT(owner_id,target_id) DO UPDATE SET relation=excluded.relation;
 RETURN public.fc_get_state();
END $$;
GRANT EXECUTE ON FUNCTION public.fc_update_profile(text,text,text,text),public.fc_set_relationship(uuid,text) TO authenticated;
