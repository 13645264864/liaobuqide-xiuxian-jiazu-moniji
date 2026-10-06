CREATE OR REPLACE FUNCTION public.fc_update_profile(p_title text,p_profile text,p_location text,p_avatar_key text DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); v_me public.fc_characters;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid FOR UPDATE;
 IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 IF char_length(p_profile)>240 OR char_length(p_location)>80 THEN RAISE EXCEPTION '资料卡内容超出长度限制'; END IF;
 UPDATE public.fc_characters SET profile=trim(p_profile),location=trim(p_location),avatar_key=coalesce(p_avatar_key,avatar_key) WHERE id=v_me.id;
 RETURN public.fc_get_state();
END $$;
CREATE OR REPLACE FUNCTION public.fc_get_public_profile(p_target_id uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_target public.fc_characters; v_family public.fc_families; v_result jsonb;
BEGIN
 SELECT * INTO v_target FROM public.fc_characters WHERE id=p_target_id;
 IF v_target.id IS NULL THEN RAISE EXCEPTION '修士不存在'; END IF;
 SELECT * INTO v_family FROM public.fc_families WHERE id=v_target.family_id;
 SELECT jsonb_build_object('id',v_target.id,'display_name',v_target.display_name,'title',v_target.title,'profile',v_target.profile,'location',v_target.location,'realm',v_target.realm,'cultivation',v_target.cultivation,'capacity',v_target.capacity,'lifespan',v_target.lifespan,'foundation',v_target.foundation,'avatar_key',v_target.avatar_key,'family_name',v_family.name,
 'parents',coalesce((SELECT jsonb_agg(jsonb_build_object('id',p.id,'display_name',p.display_name,'relation','父母')) FROM public.fc_characters p WHERE p.id IN(v_target.parent_a,v_target.parent_b)),'[]'::jsonb),
 'children',coalesce((SELECT jsonb_agg(jsonb_build_object('id',p.id,'display_name',p.display_name,'relation','子女')) FROM public.fc_characters p WHERE p.parent_a=v_target.id OR p.parent_b=v_target.id),'[]'::jsonb),
 'partner',coalesce((SELECT jsonb_build_object('id',p.id,'display_name',p.display_name,'relation','道侣') FROM public.fc_marriages m JOIN public.fc_characters p ON p.id=CASE WHEN m.parent_a=v_target.id THEN m.parent_b ELSE m.parent_a END WHERE m.status='active' AND v_target.id IN(m.parent_a,m.parent_b) LIMIT 1),'null'::jsonb),
 'friends',coalesce((SELECT jsonb_agg(jsonb_build_object('id',p.id,'display_name',p.display_name)) FROM public.fc_relationships r JOIN public.fc_characters p ON p.id=r.target_id WHERE r.owner_id=v_target.id AND r.relation='friend'),'[]'::jsonb),
 'blocked',coalesce((SELECT jsonb_agg(jsonb_build_object('id',p.id,'display_name',p.display_name)) FROM public.fc_relationships r JOIN public.fc_characters p ON p.id=r.target_id WHERE r.owner_id=v_target.id AND r.relation='enemy'),'[]'::jsonb)) INTO v_result;
 RETURN v_result;
END $$;
GRANT EXECUTE ON FUNCTION public.fc_get_public_profile(uuid) TO authenticated;
