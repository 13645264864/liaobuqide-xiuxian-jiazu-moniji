CREATE OR REPLACE FUNCTION public.fc_claim_cultivation() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); v_me public.fc_characters; v_minutes integer; v_rate numeric;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid FOR UPDATE;
 IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 v_minutes:=least(720,greatest(0,floor(extract(epoch FROM(now()-v_me.last_claim_at))/60)::integer));
 v_rate:=CASE WHEN v_me.worship_until IS NOT NULL AND v_me.worship_until>now() THEN 1.10 ELSE 1.0 END;
 IF EXISTS(SELECT 1 FROM public.fc_character_positions p JOIN public.fc_world_cells c ON c.id=p.cell_id JOIN public.fc_world_rooms r ON r.id=c.room_id WHERE p.character_id=v_me.id AND r.template_id='10000000-0000-0000-0000-000000000020' AND r.family_id=v_me.family_id) THEN v_rate:=v_rate+0.50; END IF;
 v_rate:=v_rate*(public.fc_mind_effects(v_me.mind)->>'cultivation')::numeric;
 IF v_minutes>0 THEN
  UPDATE public.fc_characters SET cultivation=least(capacity,cultivation+v_minutes*v_rate*public.fc_aura_rate(v_me.realm_index)/public.fc_aura_requirement(v_me.realm_index,v_me.realm_layer)*100),last_claim_at=CASE WHEN now()-last_claim_at>interval '12 hours' THEN now() ELSE last_claim_at+make_interval(mins=>v_minutes) END WHERE id=v_me.id;
  INSERT INTO public.fc_notices(character_id,body) VALUES(v_me.id,'闭关结算：修炼了 '||v_minutes||' 分钟，灵气收益倍率为 '||v_rate||'。');
 END IF;
 PERFORM public.fc_recover_attributes();
 RETURN public.fc_get_state();
END $$;
CREATE OR REPLACE FUNCTION public.fc_get_attributes() RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters; s jsonb; k text; power numeric;
BEGIN
 PERFORM public.fc_recover_attributes(); SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid();
 s:=public.fc_base_stats(c.realm_index,c.realm_layer,c.realm_grade);
 FOREACH k IN ARRAY ARRAY['health','mana','attack','defense'] LOOP s:=jsonb_set(s,ARRAY[k],to_jsonb(round((s->>k)::numeric+coalesce((c.expansion_stats->>k)::numeric,0),2))); END LOOP;
 power:=round((s->>'health')::numeric*0.2+(s->>'mana')::numeric*0.1+(s->>'attack')::numeric*5+(s->>'defense')::numeric*3+(s->>'speed')::numeric*2);
 RETURN s||jsonb_build_object('aura_required',public.fc_aura_requirement(c.realm_index,c.realm_layer),'aura_points',round(c.cultivation/100*public.fc_aura_requirement(c.realm_index,c.realm_layer),2),'aura_limit',c.capacity/100*public.fc_aura_requirement(c.realm_index,c.realm_layer),'aura_rate',public.fc_aura_rate(c.realm_index),'power',power,'mind',c.mind,'consciousness',round(c.consciousness,2),'effects',public.fc_mind_effects(c.mind),'expansion_stats',c.expansion_stats);
END $$;
CREATE OR REPLACE FUNCTION public.fc_breakthrough(p_grade integer DEFAULT 1,p_request_id uuid DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_me public.fc_characters; v_uid text:=public.fc_require_uid(); v_result jsonb; v_major boolean; v_chance numeric; v_roll numeric; v_win boolean; v_extra numeric; v_realms text[]:=ARRAY['练气','筑基','金丹','元婴','出窍','化神']; v_layers text[]:=ARRAY['一','二','三','四','五','六','七','八','九']; v_log jsonb:='[]'::jsonb; v_old jsonb; v_new jsonb; v_bonus jsonb; k text;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid FOR UPDATE;
 IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 IF p_request_id IS NULL THEN RAISE EXCEPTION '缺少突破请求标识'; END IF;
 SELECT result INTO v_result FROM public.fc_breakthrough_records WHERE id=p_request_id AND character_id=v_me.id;
 IF v_result IS NOT NULL THEN RETURN jsonb_build_object('state',public.fc_get_state(),'trial',v_result); END IF;
 IF EXISTS(SELECT 1 FROM public.fc_breakthrough_records WHERE id=p_request_id) THEN RAISE EXCEPTION '请求标识无效'; END IF;
 IF p_grade NOT BETWEEN 1 AND 9 THEN RAISE EXCEPTION '品级必须在一至九品之间'; END IF;
 IF v_me.realm_index=5 AND v_me.realm_layer=9 THEN RAISE EXCEPTION '化神九层已达当前开放上限'; END IF;
 IF v_me.cultivation<100 THEN RAISE EXCEPTION '丹田灵气不足本层突破需求'; END IF;
 IF v_me.lifespan<=1 THEN RAISE EXCEPTION '寿元不足，无法承受突破'; END IF;
 v_major:=v_me.realm_layer=9;
 v_extra:=greatest(0,v_me.cultivation-100);
 IF v_major THEN
  v_chance:=greatest(5,least(95,70+(public.fc_mind_effects(v_me.mind)->>'breakthrough_bonus')::numeric-(p_grade-1)*7+v_extra*0.8-(100-v_me.foundation)*0.5));
  v_roll:=random()*100;v_win:=v_roll<v_chance;
  v_log:=jsonb_build_array('你以'||v_me.realm||'的修为迎战'||p_grade||'品判定妖魔。','丹田灵气 '||v_me.cultivation||'%，道基 '||v_me.foundation||'%，本次胜率 '||v_chance||'%。');
 ELSE
  v_chance:=100;v_win:=true;
  v_log:=jsonb_build_array('灵气运转周天，冲击下一层修为。');
 END IF;
 IF v_win THEN
  v_old:=public.fc_base_stats(v_me.realm_index,v_me.realm_layer,v_me.realm_grade);
  v_new:=public.fc_base_stats(CASE WHEN v_major THEN v_me.realm_index+1 ELSE v_me.realm_index END,CASE WHEN v_major THEN 1 ELSE v_me.realm_layer+1 END,CASE WHEN v_major THEN p_grade ELSE v_me.realm_grade END);
  v_bonus:=v_me.expansion_stats;
  FOREACH k IN ARRAY ARRAY['health','mana','attack','defense','speed','consciousness_max'] LOOP
   v_bonus:=jsonb_set(v_bonus,ARRAY[k],to_jsonb(coalesce((v_bonus->>k)::numeric,0)+greatest(0,(v_new->>k)::numeric-(v_old->>k)::numeric)*v_extra/100));
  END LOOP;
  UPDATE public.fc_characters SET expansion_stats=v_bonus WHERE id=v_me.id;
  IF v_major THEN
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
 v_result:=jsonb_build_object('success',v_win,'major',v_major,'grade',CASE WHEN v_major THEN p_grade ELSE v_me.realm_grade END,'chance',v_chance,'log',v_log);
 INSERT INTO public.fc_breakthrough_records(id,character_id,result) VALUES(p_request_id,v_me.id,v_result);
 INSERT INTO public.fc_notices(character_id,body) VALUES(v_me.id,v_log->>(jsonb_array_length(v_log)-1));
 RETURN jsonb_build_object('state',public.fc_get_state(),'trial',v_result);
END $$;
REVOKE ALL ON FUNCTION public.fc_breakthrough(integer,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fc_breakthrough(integer,uuid) TO authenticated;
CREATE OR REPLACE FUNCTION public.fc_get_attributes() RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters; s jsonb; k text; power numeric;
BEGIN
 PERFORM public.fc_recover_attributes(); SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid();
 s:=public.fc_base_stats(c.realm_index,c.realm_layer,c.realm_grade);
 FOREACH k IN ARRAY ARRAY['health','mana','attack','defense','speed','consciousness_max'] LOOP s:=jsonb_set(s,ARRAY[k],to_jsonb(round((s->>k)::numeric+coalesce((c.expansion_stats->>k)::numeric,0),2))); END LOOP;
 power:=round((s->>'health')::numeric*0.2+(s->>'mana')::numeric*0.1+(s->>'attack')::numeric*5+(s->>'defense')::numeric*3+(s->>'speed')::numeric*2);
 RETURN s||jsonb_build_object('aura_required',public.fc_aura_requirement(c.realm_index,c.realm_layer),'aura_points',round(c.cultivation/100*public.fc_aura_requirement(c.realm_index,c.realm_layer),2),'aura_limit',c.capacity/100*public.fc_aura_requirement(c.realm_index,c.realm_layer),'aura_rate',public.fc_aura_rate(c.realm_index),'power',power,'mind',c.mind,'consciousness',round(c.consciousness,2),'effects',public.fc_mind_effects(c.mind),'expansion_stats',c.expansion_stats);
END $$;
CREATE OR REPLACE FUNCTION public.fc_recover_attributes() RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters; elapsed numeric; max_spirit numeric; effects jsonb; hours integer; gain integer;
BEGIN
 SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE; IF c.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 elapsed:=least(720,greatest(0,extract(epoch FROM(now()-c.recovery_at))/60));
 max_spirit:=(public.fc_base_stats(c.realm_index,c.realm_layer,c.realm_grade)->>'consciousness_max')::numeric+coalesce((c.expansion_stats->>'consciousness_max')::numeric,0);
 effects:=public.fc_mind_effects(c.mind);
 UPDATE public.fc_characters SET consciousness=least(max_spirit,consciousness+elapsed*max_spirit*0.01*(effects->>'recovery')::numeric),recovery_at=now() WHERE id=c.id;
END $$;
CREATE FUNCTION public.fc_use_expansion_pill(p_slot integer) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters; item public.fc_inventory_slots;
BEGIN
 SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE;
 IF c.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 SELECT * INTO item FROM public.fc_inventory_slots WHERE character_id=c.id AND slot=p_slot FOR UPDATE;
 IF item.item_key IS DISTINCT FROM 'expansion_pill' THEN RAISE EXCEPTION '这里没有扩容丹'; END IF;
 IF c.capacity>=150 THEN RAISE EXCEPTION '当前丹田已达到完美圆满容量'; END IF;
 PERFORM public.fc_claim_cultivation();
 UPDATE public.fc_characters SET capacity=least(150,capacity+5) WHERE id=c.id;
 IF item.quantity=1 THEN DELETE FROM public.fc_inventory_slots WHERE character_id=c.id AND slot=p_slot; ELSE UPDATE public.fc_inventory_slots SET quantity=quantity-1 WHERE character_id=c.id AND slot=p_slot; END IF;
 RETURN public.fc_get_state();
END $$;
REVOKE ALL ON FUNCTION public.fc_use_expansion_pill(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fc_use_expansion_pill(integer) TO authenticated;
