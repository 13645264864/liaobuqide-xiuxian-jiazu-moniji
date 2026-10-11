CREATE OR REPLACE FUNCTION public.fc_breakthrough(p_grade integer DEFAULT 1, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$

DECLARE v_me public.fc_characters; v_uid text:=public.fc_require_uid(); v_result jsonb; v_major boolean; v_chance numeric; v_roll numeric; v_win boolean; v_extra numeric; v_realms text[]:=ARRAY['练气','筑基','金丹','元婴','出窍','化神']; v_layers text[]:=ARRAY['一','二','三','四','五','六','七','八','九']; v_log jsonb:='[]'::jsonb; v_old jsonb; v_new jsonb; v_bonus jsonb; v_changes jsonb:='{}'::jsonb; k text; v_delta numeric; v_extra_delta numeric;

BEGIN

 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid FOR UPDATE;

 IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;

 IF p_request_id IS NULL THEN RAISE EXCEPTION '缺少突破请求标识'; END IF;

 SELECT result INTO v_result FROM public.fc_breakthrough_records WHERE id=p_request_id AND character_id=v_me.id;

 IF v_result IS NOT NULL THEN RETURN jsonb_build_object('state',public.fc_get_state(),'trial',v_result); END IF;

 IF EXISTS(SELECT 1 FROM public.fc_breakthrough_records WHERE id=p_request_id) THEN RAISE EXCEPTION '请求标识无效'; END IF;

 IF p_grade NOT BETWEEN 1 AND 9 THEN RAISE EXCEPTION '品级必须在一至九品之间'; END IF;

 IF v_me.realm_index=5 AND v_me.realm_layer=9 THEN RAISE EXCEPTION '化神九层已达当前开放上限'; END IF;

 IF v_me.cultivation<v_me.capacity THEN RAISE EXCEPTION '修为不足本层突破上限'; END IF;

 IF v_me.lifespan<=1 THEN RAISE EXCEPTION '寿元不足，无法承受突破'; END IF;

 v_major:=v_me.realm_layer=9;

 v_extra:=greatest(0,v_me.capacity-100);

 IF v_major THEN
  UPDATE public.fc_characters SET breakthrough_boost_until=NULL WHERE id=v_me.id;

  v_chance:=greatest(5,least(95,70+CASE WHEN v_me.breakthrough_boost_until>now() THEN 10 ELSE 0 END+(public.fc_mind_effects(v_me.mind)->>'breakthrough_bonus')::numeric-(p_grade-1)*7+v_extra*0.8-(100-v_me.foundation)*0.5));

  v_roll:=random()*100;v_win:=v_roll<v_chance;

  v_log:=jsonb_build_array('你以'||v_me.realm||'的修为迎战'||p_grade||'品判定妖魔。','修为上限 '||v_me.cultivation||'/'||v_me.capacity||'，道基 '||v_me.foundation||'%，本次胜率 '||v_chance||'%。');

 ELSE

  v_chance:=100;v_win:=true;

  v_log:=jsonb_build_array('灵气运转周天，冲击下一层修为。');

 END IF;

 IF v_win THEN

  v_old:=public.fc_base_stats(v_me.realm_index,v_me.realm_layer,v_me.realm_grade);

  v_new:=public.fc_base_stats(CASE WHEN v_major THEN v_me.realm_index+1 ELSE v_me.realm_index END,CASE WHEN v_major THEN 1 ELSE v_me.realm_layer+1 END,CASE WHEN v_major THEN p_grade ELSE v_me.realm_grade END);

  v_bonus:=v_me.expansion_stats;
  v_changes:=jsonb_build_object('base',jsonb_build_object(),'expansion',jsonb_build_object());
  FOREACH k IN ARRAY ARRAY['health','mana','attack','defense','speed','consciousness_max'] LOOP
   v_delta:=greatest(0,(v_new->>k)::numeric-(v_old->>k)::numeric);
   v_extra_delta:=v_delta*v_extra/100;
   v_bonus:=jsonb_set(v_bonus,ARRAY[k],to_jsonb(coalesce((v_bonus->>k)::numeric,0)+v_extra_delta));
   v_changes:=jsonb_set(v_changes,ARRAY['base',k],to_jsonb(round(v_delta,2)));
   v_changes:=jsonb_set(v_changes,ARRAY['expansion',k],to_jsonb(round(v_extra_delta,2)));
  END LOOP;
  UPDATE public.fc_characters SET expansion_stats=v_bonus WHERE id=v_me.id;

  IF v_major THEN
  UPDATE public.fc_characters SET breakthrough_boost_until=NULL WHERE id=v_me.id;

   UPDATE public.fc_characters SET mind=least(100,mind+5),realm_index=realm_index+1,realm_layer=1,realm_grade=p_grade,realm=v_realms[v_me.realm_index+2]||'一层',cultivation=0,last_claim_at=now(),attribute_bonus=attribute_bonus+v_extra,lifespan=lifespan+(ARRAY[100,300,500,1000,2000])[v_me.realm_index+1] WHERE id=v_me.id;

   v_log:=v_log||jsonb_build_array('击败判定妖魔，突破至'||v_realms[v_me.realm_index+2]||'一层，定为'||p_grade||'品。');

  ELSE

   UPDATE public.fc_characters SET realm_layer=realm_layer+1,realm=v_realms[v_me.realm_index+1]||v_layers[v_me.realm_layer+1]||'层',cultivation=v_extra*public.fc_aura_requirement(v_me.realm_index,v_me.realm_layer)/public.fc_aura_requirement(v_me.realm_index,v_me.realm_layer+1),last_claim_at=now(),attribute_bonus=attribute_bonus+v_extra WHERE id=v_me.id;

   v_log:=v_log||jsonb_build_array('剩余灵气 '||round(v_extra/100*public.fc_aura_requirement(v_me.realm_index,v_me.realm_layer),2)||' 点流入下一层。突破成功：'||v_realms[v_me.realm_index+1]||v_layers[v_me.realm_layer+1]||'层。');

  END IF;

 ELSE

  UPDATE public.fc_characters SET cultivation=greatest(0,cultivation-50),lifespan=greatest(1,lifespan-5),foundation=greatest(0,foundation-CASE WHEN p_grade>=7 THEN 5 ELSE 2 END),last_claim_at=now() WHERE id=v_me.id;

  v_log:=v_log||jsonb_build_array('妖魔压制了你的突破：损失本层所需灵气的50%、5年寿元，道基减少'||CASE WHEN p_grade>=7 THEN 5 ELSE 2 END||'点，境界保持不变。');

 END IF;

 v_result:=jsonb_build_object('success',v_win,'major',v_major,'grade',CASE WHEN v_major THEN p_grade ELSE v_me.realm_grade END,'chance',v_chance,'log',v_log,'changes',CASE WHEN v_win THEN v_changes ELSE '{}'::jsonb END);

 INSERT INTO public.fc_breakthrough_records(id,character_id,result) VALUES(p_request_id,v_me.id,v_result);

 INSERT INTO public.fc_notices(character_id,body) VALUES(v_me.id,v_log->>(jsonb_array_length(v_log)-1));

 RETURN jsonb_build_object('state',public.fc_get_state(),'trial',v_result);

END $function$;

UPDATE public.fc_inventory_slots SET item_name='扩脉丹',description='每颗提高当前修为上限5个百分点；上限会延续到下一层，突破需求按固定比例计算；额外属性在突破时结算。' WHERE item_key='expansion_pill';
UPDATE public.fc_recipes SET name='扩脉丹',output_name='扩脉丹',description='每颗提高当前修为上限5个百分点；上限会延续到下一层，突破需求按固定比例计算；额外属性在突破时结算。' WHERE output_key='expansion_pill';
