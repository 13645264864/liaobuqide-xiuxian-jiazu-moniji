ALTER TABLE public.fc_characters ADD COLUMN retired_at timestamptz;
CREATE TABLE public.fc_closed_accounts(uid text PRIMARY KEY,character_id uuid NOT NULL REFERENCES public.fc_characters(id),closed_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.fc_closed_accounts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.fc_closed_accounts FROM anon,authenticated;
CREATE OR REPLACE FUNCTION public.fc_require_uid() RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE uid text:=auth.uid();
BEGIN
 IF uid IS NULL OR auth.role()='anon' THEN RAISE EXCEPTION '请先登录'; END IF;
 IF EXISTS(SELECT 1 FROM public.fc_closed_accounts WHERE fc_closed_accounts.uid=uid) THEN RAISE EXCEPTION '该游戏账号已坐化注销，无法再次入世'; END IF;
 RETURN uid;
END $$;
CREATE OR REPLACE FUNCTION public.fc_founder_city_before_insert() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE founder boolean; free integer;
BEGIN
 SELECT is_founder INTO founder FROM public.fc_characters WHERE id=NEW.leader_id;
 IF founder THEN
  SELECT ct.id INTO free FROM public.fc_cities ct WHERE ct.id<=50 AND NOT EXISTS(SELECT 1 FROM public.fc_families WHERE city_id=ct.id) ORDER BY ct.id LIMIT 1;
  IF free IS NULL THEN RAISE EXCEPTION '暂无空闲立族城池'; END IF;
  NEW.city_id:=free;
 END IF;
 RETURN NEW;
END $$;
CREATE FUNCTION public.fc_retire(p_confirmation text) RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE uid text:=public.fc_require_uid(); c public.fc_characters; successor uuid; world public.fc_world;
BEGIN
 SELECT * INTO world FROM public.fc_world WHERE id=1 FOR UPDATE;
 SELECT * INTO c FROM public.fc_characters WHERE owner_id=uid FOR UPDATE;
 IF c.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 IF p_confirmation IS DISTINCT FROM '确认坐化' THEN RAISE EXCEPTION '请输入确认坐化'; END IF;
 INSERT INTO public.fc_closed_accounts(uid,character_id) VALUES(uid,c.id);
 UPDATE public.fc_characters SET retired_at=now(),owner_id='retired:'||id,title='已坐化',cultivation=0,spirit_stones=0,equipped_mind=NULL,equipped_art=NULL,equipped_spell=NULL WHERE id=c.id;
 DELETE FROM public.fc_character_positions WHERE character_id=c.id;
 DELETE FROM public.fc_city_journeys WHERE character_id=c.id;
 DELETE FROM public.fc_defense_setups WHERE character_id=c.id;
 UPDATE public.fc_combat_encounters SET status='cancelled',result='修士坐化' WHERE character_id=c.id AND status='active';
 DELETE FROM public.fc_inventory_slots WHERE character_id=c.id;
 DELETE FROM public.fc_equipment_instances WHERE character_id=c.id;
 DELETE FROM public.fc_known_manuals WHERE character_id=c.id;
 UPDATE public.fc_invitations SET status='declined' WHERE status='pending' AND c.id IN(proposer_id,target_id);
 UPDATE public.fc_marriages SET status='ended' WHERE c.id IN(parent_a,parent_b) AND status='active';
 UPDATE public.fc_birth_slots SET claimed_by=NULL WHERE claimed_by=c.id;
 IF EXISTS(SELECT 1 FROM public.fc_families WHERE leader_id=c.id) THEN
  SELECT id INTO successor FROM public.fc_characters WHERE family_id=c.family_id AND retired_at IS NULL ORDER BY registration_order LIMIT 1;
  IF successor IS NOT NULL THEN
   UPDATE public.fc_families SET leader_id=successor WHERE id=c.family_id;
  ELSE
   UPDATE public.fc_families SET city_id=NULL,accept_random=false,description=description||'（宗族已无人，宅邸封存。）' WHERE id=c.family_id;
  END IF;
 END IF;
 UPDATE public.fc_characters SET mind=greatest(0,mind-CASE WHEN c.id IN(parent_a,parent_b) OR EXISTS(SELECT 1 FROM public.fc_relationships r WHERE r.owner_id=fc_characters.id AND r.target_id=c.id AND r.relation='friend') THEN 15 ELSE 5 END) WHERE family_id=c.family_id AND retired_at IS NULL;
 INSERT INTO public.fc_notices(character_id,body) SELECT id,c.display_name||'已经坐化，族谱保留其身世。' FROM public.fc_characters WHERE family_id=c.family_id AND retired_at IS NULL;
 RETURN jsonb_build_object('closed',true,'founder_slot_released',c.is_founder,'message','已坐化注销。身世保留在族谱，物品和修为不可恢复。');
END $$;
REVOKE ALL ON FUNCTION public.fc_retire(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fc_retire(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.fc_get_state() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); v_me public.fc_characters; v_result jsonb;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid;
 v_result:=jsonb_build_object('character',CASE WHEN v_me.id IS NULL THEN NULL ELSE to_jsonb(v_me)-'owner_id' END,
 'world',(SELECT to_jsonb(w)||jsonb_build_object('registration_count',(SELECT count(*) FROM public.fc_characters WHERE is_founder AND retired_at IS NULL),'founder_available',greatest(0,w.founder_limit-(SELECT count(*) FROM public.fc_characters WHERE is_founder AND retired_at IS NULL)),'total_entered',w.registration_count) FROM public.fc_world w WHERE id=1),
 'families',COALESCE((SELECT jsonb_agg(q ORDER BY q.created_at) FROM (
 SELECT f.*, (SELECT count(*) FROM public.fc_characters c WHERE c.family_id=f.id AND c.retired_at IS NULL) AS members,
 (SELECT count(*) FROM public.fc_birth_slots s JOIN public.fc_marriages m ON m.id=s.marriage_id
 JOIN public.fc_characters a ON a.id=m.parent_a JOIN public.fc_characters b ON b.id=m.parent_b
 WHERE s.claimed_by IS NULL AND m.status='active' AND f.id IN (a.family_id,b.family_id)) AS open_slots
 FROM public.fc_families f WHERE f.city_id IS NOT NULL LIMIT 100) q),'[]'::jsonb),
 'people',COALESCE((SELECT jsonb_agg(q) FROM (SELECT c.id,c.display_name,c.gender,f.name AS family_name,
 EXISTS(SELECT 1 FROM public.fc_marriages m WHERE m.status='active' AND c.id IN(m.parent_a,m.parent_b)) AS married
 FROM public.fc_characters c JOIN public.fc_families f ON f.id=c.family_id WHERE c.retired_at IS NULL ORDER BY c.registration_order LIMIT 100) q),'[]'::jsonb),
 'invitations',COALESCE((SELECT jsonb_agg(q) FROM (SELECT i.*,c.display_name AS proposer_name
 FROM public.fc_invitations i JOIN public.fc_characters c ON c.id=i.proposer_id
 WHERE v_me.id IN(i.target_id,i.proposer_id) AND i.status='pending') q),'[]'::jsonb),
 'slots',COALESCE((SELECT jsonb_agg(q ORDER BY q.priority,q.created_at) FROM (
 SELECT s.id,s.marriage_id,s.slot_type,s.created_at,CASE WHEN s.slot_type='initial' THEN 0 ELSE 1 END AS priority,
 a.display_name AS parent_a_name,b.display_name AS parent_b_name,
 CASE WHEN a.family_id=b.family_id THEN jsonb_build_array(a.family_id) ELSE jsonb_build_array(a.family_id,b.family_id) END AS family_ids,
 CASE WHEN a.family_id=b.family_id THEN jsonb_build_array(fa.name) ELSE jsonb_build_array(fa.name,fb.name) END AS family_names
 FROM public.fc_birth_slots s JOIN public.fc_marriages m ON m.id=s.marriage_id
 JOIN public.fc_characters a ON a.id=m.parent_a JOIN public.fc_characters b ON b.id=m.parent_b
 JOIN public.fc_families fa ON fa.id=a.family_id JOIN public.fc_families fb ON fb.id=b.family_id
 WHERE s.claimed_by IS NULL AND m.status='active' ORDER BY CASE WHEN s.slot_type='initial' THEN 0 ELSE 1 END,s.created_at LIMIT 100) q),'[]'::jsonb),
 'approvals','[]'::jsonb,
 'notices',COALESCE((SELECT jsonb_agg(q ORDER BY q.created_at DESC) FROM (SELECT id,body,created_at FROM public.fc_notices WHERE character_id=v_me.id ORDER BY created_at DESC LIMIT 30) q),'[]'::jsonb));
 v_result:=v_result||jsonb_build_object('relatives',COALESCE((SELECT jsonb_agg(q) FROM (
 SELECT c.id::text,c.display_name,CASE WHEN c.id=v_me.parent_a THEN '双亲' WHEN c.id=v_me.parent_b THEN '双亲'
 WHEN c.parent_a=v_me.id OR c.parent_b=v_me.id THEN '子女' ELSE '道侣' END AS role,f.name AS family_name,c.retired_at IS NOT NULL AS deceased
 FROM public.fc_characters c JOIN public.fc_families f ON f.id=c.family_id
 WHERE c.id IN(v_me.parent_a,v_me.parent_b) OR c.parent_a=v_me.id OR c.parent_b=v_me.id
 OR EXISTS(SELECT 1 FROM public.fc_marriages m WHERE m.status='active' AND v_me.id IN(m.parent_a,m.parent_b) AND c.id IN(m.parent_a,m.parent_b) AND c.id<>v_me.id)
 UNION ALL SELECT 'ancestor-a',v_me.ancestor_a,'先父','已故先祖',true WHERE v_me.is_founder
 UNION ALL SELECT 'ancestor-b',v_me.ancestor_b,'先母','已故先祖',true WHERE v_me.is_founder) q),'[]'::jsonb));
 RETURN v_result;
END $$;

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
 IF (SELECT count(*) FROM public.fc_characters WHERE is_founder AND retired_at IS NULL)<v_world.founder_limit THEN
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
 PERFORM public.fc_ensure_family_home(v_family);
 INSERT INTO public.fc_notices(character_id,body) VALUES(v_char,'你已入世，血脉与家族已录入族谱。');
 RETURN public.fc_get_state();
END $$;

CREATE OR REPLACE FUNCTION public.fc_get_rankings(p_board text DEFAULT 'power',p_scope text DEFAULT 'continent') RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_me public.fc_characters; v_state integer; v_rows jsonb; v_my_rank bigint;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=public.fc_require_uid();
 IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 IF p_board NOT IN ('power','realm','wealth','family') OR p_scope NOT IN ('family','state','continent') THEN RAISE EXCEPTION '榜单或范围无效'; END IF;
 SELECT ct.state_id INTO v_state FROM public.fc_families f JOIN public.fc_cities ct ON ct.id=f.city_id WHERE f.id=v_me.family_id;
 IF p_board='family' THEN
 WITH families AS (
 SELECT f.id,f.name,f.level,f.prestige,count(c.id) AS members,coalesce(sum(public.fc_character_power(c)),0) AS score,st.name AS state_name
 FROM public.fc_families f JOIN public.fc_cities ct ON ct.id=f.city_id JOIN public.fc_states st ON st.id=ct.state_id LEFT JOIN public.fc_characters c ON c.family_id=f.id AND c.retired_at IS NULL
 WHERE f.city_id IS NOT NULL AND (p_scope='continent' OR p_scope='family' AND f.id=v_me.family_id OR p_scope='state' AND ct.state_id=v_state)
 GROUP BY f.id,st.name
 ), ranked AS (SELECT *,dense_rank() OVER(ORDER BY score DESC) AS rank FROM families), limited AS (SELECT * FROM ranked ORDER BY score DESC,name,id LIMIT 100)
 SELECT coalesce(jsonb_agg(to_jsonb(limited) ORDER BY score DESC,name,id),'[]'::jsonb) INTO v_rows FROM limited;
 ELSE
 WITH players AS (
 SELECT c.id,c.display_name AS name,c.realm,c.realm_index,c.realm_layer,c.realm_grade,c.spirit_stones,public.fc_character_power(c) AS power,f.name AS family_name,st.name AS state_name,
 CASE p_board WHEN 'power' THEN public.fc_character_power(c) WHEN 'wealth' THEN c.spirit_stones ELSE c.realm_index*10000+c.realm_layer*100+c.realm_grade END AS score
 FROM public.fc_characters c JOIN public.fc_families f ON f.id=c.family_id JOIN public.fc_cities ct ON ct.id=f.city_id JOIN public.fc_states st ON st.id=ct.state_id
 WHERE c.retired_at IS NULL AND (p_scope='continent' OR p_scope='family' AND c.family_id=v_me.family_id OR p_scope='state' AND ct.state_id=v_state)
 ), ranked AS (SELECT *,dense_rank() OVER(ORDER BY score DESC) AS rank FROM players), limited AS (SELECT * FROM ranked ORDER BY score DESC,name,id LIMIT 100)
 SELECT coalesce(jsonb_agg(to_jsonb(limited) ORDER BY score DESC,name,id),'[]'::jsonb) INTO v_rows FROM limited;
 END IF;
 RETURN jsonb_build_object('board',p_board,'scope',p_scope,'scope_name',CASE p_scope WHEN 'family' THEN (SELECT name FROM public.fc_families WHERE id=v_me.family_id) WHEN 'state' THEN (SELECT name FROM public.fc_states WHERE id=v_state) ELSE '全大陆' END,'self_id',CASE WHEN p_board='family' THEN v_me.family_id ELSE v_me.id END,'rows',v_rows);
END $$;
REVOKE ALL ON FUNCTION public.fc_get_rankings(text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fc_get_rankings(text,text) TO authenticated;

