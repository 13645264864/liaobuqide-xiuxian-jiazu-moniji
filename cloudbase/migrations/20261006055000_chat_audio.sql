ALTER TABLE public.fc_chat_messages ADD COLUMN IF NOT EXISTS message_type text NOT NULL DEFAULT 'text';
ALTER TABLE public.fc_chat_messages ADD COLUMN IF NOT EXISTS audio_key text;
ALTER TABLE public.fc_chat_messages DROP CONSTRAINT IF EXISTS fc_chat_messages_content_check;
ALTER TABLE public.fc_chat_messages ADD CONSTRAINT fc_chat_messages_content_check CHECK(char_length(content) BETWEEN 0 AND 240);
ALTER TABLE public.fc_chat_messages ADD CONSTRAINT fc_chat_messages_type_check CHECK(message_type IN ('text','audio'));
CREATE OR REPLACE FUNCTION public.fc_send_chat(p_channel text,p_content text,p_message_type text DEFAULT 'text',p_audio_key text DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); v_me public.fc_characters; v_count integer; v_id uuid;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid;
 IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 IF p_channel NOT IN('world','family') THEN RAISE EXCEPTION '该聊天频道尚未开放'; END IF;
 IF p_message_type='text' AND (char_length(trim(p_content))<1 OR char_length(trim(p_content))>240) THEN RAISE EXCEPTION '消息需为 1 至 240 个字符'; END IF;
 IF p_message_type='audio' AND coalesce(p_audio_key,'')='' THEN RAISE EXCEPTION '语音文件不能为空'; END IF;
 SELECT count(*) INTO v_count FROM public.fc_chat_messages WHERE sender_id=v_me.id AND created_at>now()-interval '1 minute';
 IF v_count>=3 THEN RAISE EXCEPTION '发送太快了，每分钟最多发送 3 条消息'; END IF;
 INSERT INTO public.fc_chat_messages(channel,family_id,sender_id,content,message_type,audio_key) VALUES(p_channel,CASE WHEN p_channel='family' THEN v_me.family_id ELSE NULL END,v_me.id,trim(p_content),p_message_type,p_audio_key) RETURNING id INTO v_id;
 RETURN jsonb_build_object('id',v_id);
END $$;
GRANT EXECUTE ON FUNCTION public.fc_send_chat(text,text,text,text) TO authenticated;
