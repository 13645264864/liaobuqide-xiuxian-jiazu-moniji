CREATE OR REPLACE FUNCTION public.fc_enter_world(p_name text,p_gender text,p_mode text,p_family_name text DEFAULT '',p_slot_id uuid DEFAULT NULL,p_family_id uuid DEFAULT NULL,p_random boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); v_world public.fc_world; v_char uuid:=gen_random_uuid(); v_family uuid;
v_order integer; v_root text; v_slot public.fc_birth_slots; v_marriage public.fc_marriages; v_a public.fc_characters; v_b public.fc_characters; v_f public.fc_families;
BEGIN
 SELECT * INTO v_world FROM public.fc_world WHERE id=1 FOR UPDATE;
 IF EXISTS(SELECT 1 FROM public.fc_characters WHERE owner_id=v_uid) THEN RETURN public.fc_get_state(); END IF;
 IF char_length(trim(p_name)) NOT BETWEEN 2 AND 16 OR p_gender NOT IN('male','female') THEN RAISE EXCEPTION '道号需为 2 至 16 个字，且需选择性别'; END IF;
 v_order:=v_world.registration_count+1;
 v_root:=(ARRAY['金','木','水','火','土'])[1+floor(random()*5)::integer];
 IF v_order<=v_world.founder_limit THEN
  IF p_mode<>'create' THEN RAISE EXCEPTION '前 50 名为立族资格，默认开辟新家族；第 51 名起才能作为真人道侣的子女出生'; END IF;
  IF char_length(trim(p_family_name)) NOT BETWEEN 2 AND 16 THEN RAISE EXCEPTION '家族名称需为 2 至 16 个字'; END IF;
  v_family:=gen_random_uuid();
  INSERT INTO public.fc_characters(id,owner_id,display_name,gender,root,registration_order,family_id,is_founder,ancestor_a,ancestor_b)
  VALUES(v_char,v_uid,trim(p_name),p_gender,v_root,v_order,v_family,true,trim(p_name)||'之先父',trim(p_name)||'之先母');
  INSERT INTO public.fc_families(id,name,leader_id) VALUES(v_family,trim(p_family_name),v_char);
  IF v_order=1 THEN UPDATE public.fc_world SET origin_family_id=v_family WHERE id=1; END IF;
 ELSE
  IF p_mode<>'birth' THEN RAISE EXCEPTION '前 50 名为立族资格，第 51 名起只能作为真人道侣的子女出生'; END IF;
  IF p_slot_id IS NULL THEN
   SELECT s.* INTO v_slot FROM public.fc_birth_slots s JOIN public.fc_marriages m ON m.id=s.marriage_id
   JOIN public.fc_characters a ON a.id=m.parent_a JOIN public.fc_characters b ON b.id=m.parent_b
   WHERE s.claimed_by IS NULL AND m.status='active' AND EXISTS(
    SELECT 1 FROM public.fc_families f WHERE f.id IN(a.family_id,b.family_id) AND (p_family_id IS NULL OR f.id=p_family_id)
    AND (NOT p_random OR f.accept_random) AND f.gender_filter IN('any',p_gender) AND f.root_filter IN('any',v_root))
   ORDER BY CASE WHEN s.slot_type='initial' THEN 0 ELSE 1 END,random() LIMIT 1 FOR UPDATE OF s;
  ELSE
   SELECT * INTO v_slot FROM public.fc_birth_slots WHERE id=p_slot_id AND claimed_by IS NULL FOR UPDATE;
  END IF;
  IF v_slot.id IS NULL THEN RAISE EXCEPTION '当前没有符合条件的出生名额，请选择其他家庭或稍后再来'; END IF;
  SELECT * INTO v_marriage FROM public.fc_marriages WHERE id=v_slot.marriage_id AND status='active';
  IF v_marriage.id IS NULL THEN RAISE EXCEPTION '该名额已失效'; END IF;
  IF v_slot.slot_type='extra' AND v_slot.approved_by NOT IN(v_marriage.parent_a,v_marriage.parent_b) THEN RAISE EXCEPTION '额外名额尚未获得父母同意'; END IF;
  SELECT * INTO v_a FROM public.fc_characters WHERE id=v_marriage.parent_a;
  SELECT * INTO v_b FROM public.fc_characters WHERE id=v_marriage.parent_b;
  v_family:=p_family_id;
  IF v_family IS NULL THEN
   SELECT f.id INTO v_family FROM public.fc_families f WHERE f.id IN(v_a.family_id,v_b.family_id)
   AND (NOT p_random OR f.accept_random) AND f.gender_filter IN('any',p_gender) AND f.root_filter IN('any',v_root) ORDER BY random() LIMIT 1;
  END IF;
  IF v_family IS NULL OR v_family NOT IN(v_a.family_id,v_b.family_id) THEN RAISE EXCEPTION '只能选择父母所属家族'; END IF;
  SELECT * INTO v_f FROM public.fc_families WHERE id=v_family;
  IF (p_random AND NOT v_f.accept_random) OR v_f.gender_filter NOT IN('any',p_gender) OR v_f.root_filter NOT IN('any',v_root) THEN RAISE EXCEPTION '不符合该家族的接纳条件，请重新选择'; END IF;
  INSERT INTO public.fc_characters(id,owner_id,display_name,gender,root,registration_order,family_id,parent_a,parent_b)
  VALUES(v_char,v_uid,trim(p_name),p_gender,v_root,v_order,v_family,v_a.id,v_b.id);
  UPDATE public.fc_birth_slots SET claimed_by=v_char WHERE id=v_slot.id;
  INSERT INTO public.fc_notices(character_id,body) VALUES(v_a.id,trim(p_name)||'已作为你们的子女入世'),(v_b.id,trim(p_name)||'已作为你们的子女入世');
 END IF;
 UPDATE public.fc_world SET registration_count=v_order WHERE id=1;
 INSERT INTO public.fc_notices(character_id,body) VALUES(v_char,'你已入世，血脉与家族已录入族谱。');
 RETURN public.fc_get_state();
END $$;
