CREATE OR REPLACE FUNCTION public.fc_list_chat(p_channel text,p_before timestamptz DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); v_me public.fc_characters; v_rows jsonb;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid;
 IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 IF p_channel NOT IN('world','family') THEN RAISE EXCEPTION '该聊天频道尚未开放'; END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(q) ORDER BY q.created_at),'[]'::jsonb) INTO v_rows FROM (
  SELECT m.id,m.channel,m.content,m.message_type,m.audio_key,m.created_at,c.id AS sender_id,c.display_name AS sender_name,c.title AS sender_title,c.realm AS sender_realm,c.cultivation AS sender_cultivation,c.avatar_key AS sender_avatar_key
  FROM public.fc_chat_messages m JOIN public.fc_characters c ON c.id=m.sender_id
  WHERE m.channel=p_channel AND (p_channel='world' OR m.family_id=v_me.family_id) AND (p_before IS NULL OR m.created_at<p_before)
  ORDER BY m.created_at DESC LIMIT 50) q;
 RETURN v_rows;
END $$;
CREATE OR REPLACE FUNCTION public.fc_social_action(p_target_id uuid,p_action text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); v_me public.fc_characters; v_target public.fc_characters; v_body text;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid; SELECT * INTO v_target FROM public.fc_characters WHERE id=p_target_id;
 IF v_me.id IS NULL OR v_target.id IS NULL OR v_me.id=v_target.id THEN RAISE EXCEPTION '目标修士无效'; END IF;
 IF p_action IN('friend','enemy') THEN INSERT INTO public.fc_relationships(owner_id,target_id,relation) VALUES(v_me.id,v_target.id,p_action) ON CONFLICT(owner_id,target_id) DO UPDATE SET relation=excluded.relation;
 ELSIF p_action='greet' THEN v_body:=v_me.display_name||'向你打了招呼。';
 ELSIF p_action='team' THEN v_body:=v_me.display_name||'邀请你组队。';
 ELSE RAISE EXCEPTION '操作不支持'; END IF;
 IF v_body IS NOT NULL THEN INSERT INTO public.fc_notices(character_id,body) VALUES(v_target.id,v_body); END IF;
 RETURN public.fc_get_state();
END $$;
GRANT EXECUTE ON FUNCTION public.fc_social_action(uuid,text) TO authenticated;
