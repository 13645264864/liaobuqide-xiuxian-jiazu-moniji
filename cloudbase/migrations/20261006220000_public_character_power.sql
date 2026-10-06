CREATE FUNCTION public.fc_character_power(c public.fc_characters) RETURNS numeric LANGUAGE sql IMMUTABLE SET search_path=public,pg_temp AS $$
 SELECT round((s->>'health')::numeric*0.2+(s->>'mana')::numeric*0.1+(s->>'attack')::numeric*5+(s->>'defense')::numeric*3+(s->>'speed')::numeric*2+coalesce((c.expansion_stats->>'health')::numeric,0)*0.2+coalesce((c.expansion_stats->>'mana')::numeric,0)*0.1+coalesce((c.expansion_stats->>'attack')::numeric,0)*5+coalesce((c.expansion_stats->>'defense')::numeric,0)*3+coalesce((c.expansion_stats->>'speed')::numeric,0)*2) FROM public.fc_base_stats(c.realm_index,c.realm_layer,c.realm_grade) s
$$;
REVOKE ALL ON FUNCTION public.fc_character_power(public.fc_characters) FROM PUBLIC;
CREATE OR REPLACE FUNCTION public.fc_list_chat(p_channel text,p_before timestamptz DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); v_me public.fc_characters; v_rows jsonb;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid;
 IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 IF p_channel NOT IN('world','family') THEN RAISE EXCEPTION '该聊天频道尚未开放'; END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(q) ORDER BY q.created_at),'[]'::jsonb) INTO v_rows FROM (
  SELECT m.id,m.channel,m.content,m.message_type,m.audio_key,m.created_at,c.id AS sender_id,c.display_name AS sender_name,c.title AS sender_title,c.realm AS sender_realm,c.cultivation AS sender_cultivation,c.avatar_key AS sender_avatar_key,public.fc_character_power(c) AS sender_power
  FROM public.fc_chat_messages m JOIN public.fc_characters c ON c.id=m.sender_id
  WHERE m.channel=p_channel AND (p_channel='world' OR m.family_id=v_me.family_id) AND (p_before IS NULL OR m.created_at<p_before)
  ORDER BY m.created_at DESC LIMIT 50) q;
 RETURN v_rows;
END $$;
CREATE OR REPLACE FUNCTION public.fc_get_public_profile(p_target_id uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_target public.fc_characters; v_family public.fc_families; v_result jsonb;
BEGIN
 SELECT * INTO v_target FROM public.fc_characters WHERE id=p_target_id;
 IF v_target.id IS NULL THEN RAISE EXCEPTION '修士不存在'; END IF;
 SELECT * INTO v_family FROM public.fc_families WHERE id=v_target.family_id;
 SELECT jsonb_build_object('power',public.fc_character_power(v_target),'id',v_target.id,'display_name',v_target.display_name,'title',v_target.title,'profile',v_target.profile,'location',v_target.location,'realm',v_target.realm,'cultivation',v_target.cultivation,'capacity',v_target.capacity,'lifespan',v_target.lifespan,'foundation',v_target.foundation,'avatar_key',v_target.avatar_key,'family_name',v_family.name,
 'parents',coalesce((SELECT jsonb_agg(jsonb_build_object('id',p.id,'display_name',p.display_name,'relation','父母')) FROM public.fc_characters p WHERE p.id IN(v_target.parent_a,v_target.parent_b)),'[]'::jsonb),
 'children',coalesce((SELECT jsonb_agg(jsonb_build_object('id',p.id,'display_name',p.display_name,'relation','子女')) FROM public.fc_characters p WHERE p.parent_a=v_target.id OR p.parent_b=v_target.id),'[]'::jsonb),
 'partner',coalesce((SELECT jsonb_build_object('id',p.id,'display_name',p.display_name,'relation','道侣') FROM public.fc_marriages m JOIN public.fc_characters p ON p.id=CASE WHEN m.parent_a=v_target.id THEN m.parent_b ELSE m.parent_a END WHERE m.status='active' AND v_target.id IN(m.parent_a,m.parent_b) LIMIT 1),'null'::jsonb),
 'friends',coalesce((SELECT jsonb_agg(jsonb_build_object('id',p.id,'display_name',p.display_name)) FROM public.fc_relationships r JOIN public.fc_characters p ON p.id=r.target_id WHERE r.owner_id=v_target.id AND r.relation='friend'),'[]'::jsonb),
 'blocked',coalesce((SELECT jsonb_agg(jsonb_build_object('id',p.id,'display_name',p.display_name)) FROM public.fc_relationships r JOIN public.fc_characters p ON p.id=r.target_id WHERE r.owner_id=v_target.id AND r.relation='enemy'),'[]'::jsonb)) INTO v_result;
 RETURN v_result;
END $$;
GRANT EXECUTE ON FUNCTION public.fc_get_public_profile(uuid) TO authenticated;
