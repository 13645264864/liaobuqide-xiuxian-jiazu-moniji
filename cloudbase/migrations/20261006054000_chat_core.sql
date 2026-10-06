CREATE TABLE public.fc_chat_messages (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), channel text NOT NULL CHECK(channel IN ('world','family','household','mentor','direct')),
 family_id uuid REFERENCES public.fc_families(id), sender_id uuid NOT NULL REFERENCES public.fc_characters(id), content text NOT NULL CHECK(char_length(content) BETWEEN 1 AND 240),
 created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX fc_chat_channel_time ON public.fc_chat_messages(channel,created_at DESC);
CREATE INDEX fc_chat_family_time ON public.fc_chat_messages(family_id,created_at DESC);
ALTER TABLE public.fc_chat_messages ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.fc_chat_messages FROM anon,authenticated;
CREATE OR REPLACE FUNCTION public.fc_send_chat(p_channel text,p_content text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); v_me public.fc_characters; v_count integer; v_id uuid;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid;
 IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 IF p_channel NOT IN('world','family') THEN RAISE EXCEPTION '该聊天频道尚未开放'; END IF;
 IF char_length(trim(p_content))<1 OR char_length(trim(p_content))>240 THEN RAISE EXCEPTION '消息需为 1 至 240 个字符'; END IF;
 IF p_channel='family' AND v_me.family_id IS NULL THEN RAISE EXCEPTION '你还没有家族'; END IF;
 SELECT count(*) INTO v_count FROM public.fc_chat_messages WHERE sender_id=v_me.id AND created_at>now()-interval '1 minute';
 IF v_count>=3 THEN RAISE EXCEPTION '发送太快了，每分钟最多发送 3 条消息'; END IF;
 INSERT INTO public.fc_chat_messages(channel,family_id,sender_id,content) VALUES(p_channel,CASE WHEN p_channel='family' THEN v_me.family_id ELSE NULL END,v_me.id,trim(p_content)) RETURNING id INTO v_id;
 RETURN jsonb_build_object('id',v_id);
END $$;
CREATE OR REPLACE FUNCTION public.fc_list_chat(p_channel text,p_before timestamptz DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); v_me public.fc_characters; v_rows jsonb;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid;
 IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 IF p_channel NOT IN('world','family') THEN RAISE EXCEPTION '该聊天频道尚未开放'; END IF;
 SELECT coalesce(jsonb_agg(to_jsonb(q) ORDER BY q.created_at),'[]'::jsonb) INTO v_rows FROM (
  SELECT m.id,m.channel,m.content,m.created_at,c.display_name AS sender_name
  FROM public.fc_chat_messages m JOIN public.fc_characters c ON c.id=m.sender_id
  WHERE m.channel=p_channel AND (p_channel='world' OR m.family_id=v_me.family_id) AND (p_before IS NULL OR m.created_at<p_before)
  ORDER BY m.created_at DESC LIMIT 50) q;
 RETURN v_rows;
END $$;
GRANT EXECUTE ON FUNCTION public.fc_send_chat(text,text),public.fc_list_chat(text,timestamptz) TO authenticated;
