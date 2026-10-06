CREATE OR REPLACE FUNCTION public.fc_list_chat(p_channel text,p_before timestamptz DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); v_me public.fc_characters; v_rows jsonb;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid;
 IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 IF p_channel NOT IN('world','family') THEN RAISE EXCEPTION '该聊天频道尚未开放'; END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(q) ORDER BY q.created_at),'[]'::jsonb) INTO v_rows FROM (
  SELECT m.id,m.channel,m.content,m.message_type,m.audio_key,m.created_at,c.display_name AS sender_name
  FROM public.fc_chat_messages m JOIN public.fc_characters c ON c.id=m.sender_id
  WHERE m.channel=p_channel AND (p_channel='world' OR m.family_id=v_me.family_id) AND (p_before IS NULL OR m.created_at<p_before)
  ORDER BY m.created_at DESC LIMIT 50) q;
 RETURN v_rows;
END $$;
