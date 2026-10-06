ALTER TABLE public.fc_characters ADD COLUMN IF NOT EXISTS worship_until timestamptz, ADD COLUMN IF NOT EXISTS worship_bonus numeric NOT NULL DEFAULT 0;

CREATE OR REPLACE FUNCTION public.fc_worship_ancestral_hall() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); v_me public.fc_characters;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid FOR UPDATE;
 IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 IF v_me.worship_until IS NOT NULL AND v_me.worship_until>now() THEN RAISE EXCEPTION '宗祠加成仍在生效'; END IF;
 UPDATE public.fc_characters SET worship_until=now()+interval '1 hour', worship_bonus=0.10 WHERE id=v_me.id;
 INSERT INTO public.fc_notices(character_id,body) VALUES(v_me.id,'祭拜宗祠成功：闭关收益提升 10%，持续 1 小时。');
 RETURN public.fc_get_state();
END $$;
REVOKE ALL ON FUNCTION public.fc_worship_ancestral_hall() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fc_worship_ancestral_hall() TO authenticated;

CREATE OR REPLACE FUNCTION public.fc_claim_cultivation() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); v_me public.fc_characters; v_minutes integer; v_rate numeric;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid FOR UPDATE;
 IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 v_minutes:=least(720,greatest(0,floor(extract(epoch FROM(now()-v_me.last_claim_at))/60)::integer));
 v_rate:=CASE WHEN v_me.worship_until IS NOT NULL AND v_me.worship_until>now() THEN 1.10 ELSE 1.0 END;
 IF v_minutes>0 THEN
  UPDATE public.fc_characters SET cultivation=least(capacity,cultivation+v_minutes*v_rate),last_claim_at=CASE WHEN now()-last_claim_at>interval '12 hours' THEN now() ELSE last_claim_at+make_interval(mins=>v_minutes) END WHERE id=v_me.id;
  INSERT INTO public.fc_notices(character_id,body) VALUES(v_me.id,'闭关结算：修炼了 '||v_minutes||' 分钟，灵气收益倍率为 '||v_rate||'。');
 END IF;
 RETURN public.fc_get_state();
END $$;
