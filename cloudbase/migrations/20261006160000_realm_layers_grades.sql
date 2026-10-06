ALTER TABLE public.fc_characters ADD COLUMN realm_index smallint NOT NULL DEFAULT 0 CHECK(realm_index BETWEEN 0 AND 5), ADD COLUMN realm_layer smallint NOT NULL DEFAULT 1 CHECK(realm_layer BETWEEN 1 AND 9), ADD COLUMN realm_grade smallint NOT NULL DEFAULT 1 CHECK(realm_grade BETWEEN 1 AND 9), ADD COLUMN attribute_bonus numeric NOT NULL DEFAULT 0;
UPDATE public.fc_characters SET realm='练气一层';
ALTER TABLE public.fc_characters ALTER COLUMN realm SET DEFAULT '练气一层';
CREATE TABLE public.fc_breakthrough_records(id uuid PRIMARY KEY,character_id uuid NOT NULL REFERENCES public.fc_characters(id),created_at timestamptz NOT NULL DEFAULT now(),result jsonb NOT NULL);
ALTER TABLE public.fc_breakthrough_records ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.fc_breakthrough_records FROM anon,authenticated;
CREATE FUNCTION public.fc_breakthrough(p_grade integer DEFAULT 1,p_request_id uuid DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_me public.fc_characters; v_uid text:=public.fc_require_uid(); v_result jsonb; v_major boolean; v_chance numeric; v_roll numeric; v_win boolean; v_extra numeric; v_realms text[]:=ARRAY['练气','筑基','金丹','元婴','出窍','化神']; v_layers text[]:=ARRAY['一','二','三','四','五','六','七','八','九']; v_log jsonb:='[]'::jsonb;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid FOR UPDATE;
 IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 IF p_request_id IS NULL THEN RAISE EXCEPTION '缺少突破请求标识'; END IF;
 SELECT result INTO v_result FROM public.fc_breakthrough_records WHERE id=p_request_id AND character_id=v_me.id;
 IF v_result IS NOT NULL THEN RETURN jsonb_build_object('state',public.fc_get_state(),'trial',v_result); END IF;
 IF EXISTS(SELECT 1 FROM public.fc_breakthrough_records WHERE id=p_request_id) THEN RAISE EXCEPTION '请求标识无效'; END IF;
 IF p_grade NOT BETWEEN 1 AND 9 THEN RAISE EXCEPTION '品级必须在一至九品之间'; END IF;
 IF v_me.realm_index=5 AND v_me.realm_layer=9 THEN RAISE EXCEPTION '化神九层已达当前开放上限'; END IF;
 IF v_me.cultivation<100 THEN RAISE EXCEPTION '丹田灵气达到100%%才能突破'; END IF;
 IF v_me.lifespan<=1 THEN RAISE EXCEPTION '寿元不足，无法承受突破'; END IF;
 v_major:=v_me.realm_layer=9;
 v_extra:=greatest(0,v_me.cultivation-100);
 IF v_major THEN
  v_chance:=greatest(5,least(95,70-(p_grade-1)*7+v_extra*0.8-(100-v_me.foundation)*0.5));
  v_roll:=random()*100;v_win:=v_roll<v_chance;
  v_log:=jsonb_build_array('你以'||v_me.realm||'的修为迎战'||p_grade||'品判定妖魔。','丹田灵气 '||v_me.cultivation||'%，道基 '||v_me.foundation||'%，本次胜率 '||v_chance||'%。');
 ELSE
  v_chance:=100;v_win:=true;
  v_log:=jsonb_build_array('灵气运转周天，冲击下一层修为。');
 END IF;
 IF v_win THEN
  IF v_major THEN
   UPDATE public.fc_characters SET realm_index=realm_index+1,realm_layer=1,realm_grade=p_grade,realm=v_realms[v_me.realm_index+2]||'一层',cultivation=0,last_claim_at=now(),attribute_bonus=attribute_bonus+v_extra,lifespan=lifespan+(ARRAY[100,300,500,1000,2000])[v_me.realm_index+1] WHERE id=v_me.id;
   v_log:=v_log||jsonb_build_array('击败判定妖魔，突破至'||v_realms[v_me.realm_index+2]||'一层，定为'||p_grade||'品。');
  ELSE
   UPDATE public.fc_characters SET realm_layer=realm_layer+1,realm=v_realms[v_me.realm_index+1]||v_layers[v_me.realm_layer+1]||'层',cultivation=0,last_claim_at=now(),attribute_bonus=attribute_bonus+v_extra WHERE id=v_me.id;
   v_log:=v_log||jsonb_build_array('突破成功：'||v_realms[v_me.realm_index+1]||v_layers[v_me.realm_layer+1]||'层。');
  END IF;
 ELSE
  UPDATE public.fc_characters SET cultivation=greatest(0,cultivation-50),lifespan=greatest(1,lifespan-5),foundation=greatest(0,foundation-CASE WHEN p_grade>=7 THEN 5 ELSE 2 END),last_claim_at=now() WHERE id=v_me.id;
  v_log:=v_log||jsonb_build_array('妖魔压制了你的突破：损失50点灵气、5年寿元，道基减少'||CASE WHEN p_grade>=7 THEN 5 ELSE 2 END||'点，境界保持不变。');
 END IF;
 v_result:=jsonb_build_object('success',v_win,'major',v_major,'grade',CASE WHEN v_major THEN p_grade ELSE v_me.realm_grade END,'chance',v_chance,'log',v_log);
 INSERT INTO public.fc_breakthrough_records(id,character_id,result) VALUES(p_request_id,v_me.id,v_result);
 INSERT INTO public.fc_notices(character_id,body) VALUES(v_me.id,v_log->>(jsonb_array_length(v_log)-1));
 RETURN jsonb_build_object('state',public.fc_get_state(),'trial',v_result);
END $$;
REVOKE ALL ON FUNCTION public.fc_breakthrough(integer,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fc_breakthrough(integer,uuid) TO authenticated;
