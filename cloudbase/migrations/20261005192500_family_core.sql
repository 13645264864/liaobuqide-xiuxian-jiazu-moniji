CREATE TABLE public.fc_world (
  id integer PRIMARY KEY CHECK (id=1), registration_count integer NOT NULL DEFAULT 0,
  founder_limit integer NOT NULL DEFAULT 50, origin_family_id uuid,
  title text NOT NULL DEFAULT '了不起的修仙家族模拟器'
);
INSERT INTO public.fc_world(id) VALUES(1);
CREATE TABLE public.fc_characters (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), owner_id text NOT NULL UNIQUE,
  display_name text NOT NULL CHECK(char_length(display_name) BETWEEN 2 AND 16),
  gender text NOT NULL CHECK(gender IN ('male','female')), root text NOT NULL,
  registration_order integer NOT NULL UNIQUE, family_id uuid NOT NULL,
  is_founder boolean NOT NULL DEFAULT false, parent_a uuid, parent_b uuid,
  ancestor_a text, ancestor_b text,
  cultivation numeric NOT NULL DEFAULT 0, capacity numeric NOT NULL DEFAULT 100,
  realm text NOT NULL DEFAULT '炼气一层', lifespan integer NOT NULL DEFAULT 100,
  foundation integer NOT NULL DEFAULT 100, last_claim_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.fc_families (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), name text NOT NULL UNIQUE CHECK(char_length(name) BETWEEN 2 AND 16),
  description text NOT NULL DEFAULT '愿同族携手，守一方安宁。' CHECK(char_length(description)<=300),
  leader_id uuid NOT NULL REFERENCES public.fc_characters(id), prestige integer NOT NULL DEFAULT 100,
  level integer NOT NULL DEFAULT 1, accept_random boolean NOT NULL DEFAULT true,
  gender_filter text NOT NULL DEFAULT 'any' CHECK(gender_filter IN ('any','male','female')),
  root_filter text NOT NULL DEFAULT 'any' CHECK(root_filter IN ('any','金','木','水','火','土')),
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.fc_characters ADD CONSTRAINT fc_family_fk FOREIGN KEY(family_id) REFERENCES public.fc_families(id) DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE public.fc_characters ADD CONSTRAINT fc_parent_a_fk FOREIGN KEY(parent_a) REFERENCES public.fc_characters(id);
ALTER TABLE public.fc_characters ADD CONSTRAINT fc_parent_b_fk FOREIGN KEY(parent_b) REFERENCES public.fc_characters(id);
ALTER TABLE public.fc_world ADD CONSTRAINT fc_origin_fk FOREIGN KEY(origin_family_id) REFERENCES public.fc_families(id);
CREATE TABLE public.fc_marriages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), parent_a uuid NOT NULL REFERENCES public.fc_characters(id),
  parent_b uuid NOT NULL REFERENCES public.fc_characters(id), status text NOT NULL DEFAULT 'active',
  created_at timestamptz NOT NULL DEFAULT now(), CHECK(parent_a<>parent_b)
);
CREATE TABLE public.fc_invitations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), proposer_id uuid NOT NULL REFERENCES public.fc_characters(id),
  target_id uuid NOT NULL REFERENCES public.fc_characters(id), status text NOT NULL DEFAULT 'pending',
  created_at timestamptz NOT NULL DEFAULT now(), CHECK(proposer_id<>target_id)
);
CREATE UNIQUE INDEX fc_pending_invitation ON public.fc_invitations(LEAST(proposer_id,target_id),GREATEST(proposer_id,target_id)) WHERE status='pending';
CREATE TABLE public.fc_birth_slots (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), marriage_id uuid NOT NULL REFERENCES public.fc_marriages(id),
  slot_type text NOT NULL CHECK(slot_type IN ('initial','extra')), approved_by uuid REFERENCES public.fc_characters(id),
  claimed_by uuid UNIQUE REFERENCES public.fc_characters(id), created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.fc_notices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), character_id uuid NOT NULL REFERENCES public.fc_characters(id),
  body text NOT NULL, created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.fc_receipts (
  owner_id text NOT NULL, action text NOT NULL, request_id uuid NOT NULL, result jsonb NOT NULL,
  PRIMARY KEY(owner_id,action,request_id), created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX fc_character_family ON public.fc_characters(family_id);
CREATE INDEX fc_parent_a_index ON public.fc_characters(parent_a);
CREATE INDEX fc_parent_b_index ON public.fc_characters(parent_b);
CREATE INDEX fc_available_slot ON public.fc_birth_slots(marriage_id,slot_type) WHERE claimed_by IS NULL;
CREATE INDEX fc_notice_character ON public.fc_notices(character_id,created_at DESC);

ALTER TABLE public.fc_world ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fc_characters ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fc_families ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fc_marriages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fc_invitations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fc_birth_slots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fc_notices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fc_receipts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.fc_world,public.fc_characters,public.fc_families,public.fc_marriages,public.fc_invitations,public.fc_birth_slots,public.fc_notices,public.fc_receipts FROM anon,authenticated;

CREATE FUNCTION public.fc_require_uid() RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=auth.uid();
BEGIN IF v_uid IS NULL OR auth.role()='anon' THEN RAISE EXCEPTION '请先登录'; END IF; RETURN v_uid; END $$;

CREATE FUNCTION public.fc_get_state() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); v_me public.fc_characters; v_result jsonb;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid;
 v_result:=jsonb_build_object('character',CASE WHEN v_me.id IS NULL THEN NULL ELSE to_jsonb(v_me)-'owner_id' END,
 'world',(SELECT to_jsonb(w) FROM public.fc_world w WHERE id=1),
 'families',COALESCE((SELECT jsonb_agg(q ORDER BY q.created_at) FROM (
 SELECT f.*, (SELECT count(*) FROM public.fc_characters c WHERE c.family_id=f.id) AS members,
 (SELECT count(*) FROM public.fc_birth_slots s JOIN public.fc_marriages m ON m.id=s.marriage_id
 JOIN public.fc_characters a ON a.id=m.parent_a JOIN public.fc_characters b ON b.id=m.parent_b
 WHERE s.claimed_by IS NULL AND m.status='active' AND f.id IN (a.family_id,b.family_id)) AS open_slots
 FROM public.fc_families f LIMIT 100) q),'[]'::jsonb),
 'people',COALESCE((SELECT jsonb_agg(q) FROM (SELECT c.id,c.display_name,c.gender,f.name AS family_name,
 EXISTS(SELECT 1 FROM public.fc_marriages m WHERE m.status='active' AND c.id IN(m.parent_a,m.parent_b)) AS married
 FROM public.fc_characters c JOIN public.fc_families f ON f.id=c.family_id ORDER BY c.registration_order LIMIT 100) q),'[]'::jsonb),
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
 SELECT c.id::text,c.display_name,CASE WHEN c.id=v_me.parent_a THEN '父亲' WHEN c.id=v_me.parent_b THEN '母亲'
 WHEN c.parent_a=v_me.id OR c.parent_b=v_me.id THEN '子女' ELSE '道侣' END AS role,f.name AS family_name,false AS deceased
 FROM public.fc_characters c JOIN public.fc_families f ON f.id=c.family_id
 WHERE c.id IN(v_me.parent_a,v_me.parent_b) OR c.parent_a=v_me.id OR c.parent_b=v_me.id
 OR EXISTS(SELECT 1 FROM public.fc_marriages m WHERE m.status='active' AND v_me.id IN(m.parent_a,m.parent_b) AND c.id IN(m.parent_a,m.parent_b) AND c.id<>v_me.id)
 UNION ALL SELECT 'ancestor-a',v_me.ancestor_a,'先父','已故先祖',true WHERE v_me.is_founder
 UNION ALL SELECT 'ancestor-b',v_me.ancestor_b,'先母','已故先祖',true WHERE v_me.is_founder) q),'[]'::jsonb));
 RETURN v_result;
END $$;

CREATE FUNCTION public.fc_enter_world(p_name text,p_gender text,p_mode text,p_family_name text DEFAULT '',p_slot_id uuid DEFAULT NULL,p_family_id uuid DEFAULT NULL,p_random boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); v_world public.fc_world; v_char uuid:=gen_random_uuid(); v_family uuid;
v_order integer; v_root text; v_slot public.fc_birth_slots; v_marriage public.fc_marriages; v_a public.fc_characters; v_b public.fc_characters; v_f public.fc_families;
BEGIN
 SELECT * INTO v_world FROM public.fc_world WHERE id=1 FOR UPDATE;
 IF EXISTS(SELECT 1 FROM public.fc_characters WHERE owner_id=v_uid) THEN RETURN public.fc_get_state(); END IF;
 IF char_length(trim(p_name)) NOT BETWEEN 2 AND 16 OR p_gender NOT IN('male','female') THEN RAISE EXCEPTION '道号需为 2 至 16 个字，且需选择性别'; END IF;
 v_order:=v_world.registration_count+1;
 v_root:=(ARRAY['金','木','水','火','土'])[1+floor(random()*5)::integer];
 IF v_order<=v_world.founder_limit AND p_mode IN('create','join') THEN
  IF v_order=1 OR p_mode='create' THEN
   IF char_length(trim(p_family_name)) NOT BETWEEN 2 AND 16 THEN RAISE EXCEPTION '家族名称需为 2 至 16 个字'; END IF;
   v_family:=gen_random_uuid();
  ELSE
   v_family:=v_world.origin_family_id;
   IF v_family IS NULL THEN RAISE EXCEPTION '原始家族尚未建立'; END IF;
  END IF;
  INSERT INTO public.fc_characters(id,owner_id,display_name,gender,root,registration_order,family_id,is_founder,ancestor_a,ancestor_b)
  VALUES(v_char,v_uid,trim(p_name),p_gender,v_root,v_order,v_family,true,trim(p_name)||'之先父',trim(p_name)||'之先母');
  IF v_order=1 OR p_mode='create' THEN
   INSERT INTO public.fc_families(id,name,leader_id) VALUES(v_family,trim(p_family_name),v_char);
  END IF;
  IF v_order=1 THEN UPDATE public.fc_world SET origin_family_id=v_family WHERE id=1; END IF;
 ELSE
  IF p_mode<>'birth' THEN RAISE EXCEPTION '创世名额已满，请选择真人家庭出生'; END IF;
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

CREATE FUNCTION public.fc_propose_marriage(p_target_id uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); v_me public.fc_characters; v_target public.fc_characters;
BEGIN
 PERFORM 1 FROM public.fc_world WHERE id=1 FOR UPDATE;
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid;
 SELECT * INTO v_target FROM public.fc_characters WHERE id=p_target_id;
 IF v_me.id IS NULL OR v_target.id IS NULL OR v_me.id=v_target.id THEN RAISE EXCEPTION '请先入世，并选择其他修士'; END IF;
 IF v_me.gender=v_target.gender THEN RAISE EXCEPTION '首版道侣需为一名男修与一名女修'; END IF;
 IF v_target.id IN(v_me.parent_a,v_me.parent_b) OR v_me.id IN(v_target.parent_a,v_target.parent_b)
 OR v_me.parent_a IN(v_target.parent_a,v_target.parent_b) OR v_me.parent_b IN(v_target.parent_a,v_target.parent_b) THEN RAISE EXCEPTION '直系亲属与兄弟姐妹不能结为道侣'; END IF;
 IF EXISTS(SELECT 1 FROM public.fc_marriages WHERE status='active' AND (v_me.id IN(parent_a,parent_b) OR v_target.id IN(parent_a,parent_b))) THEN RAISE EXCEPTION '已有道侣的修士不能重复成婚'; END IF;
 IF EXISTS(SELECT 1 FROM public.fc_invitations WHERE status='pending' AND ((proposer_id=v_me.id AND target_id=v_target.id) OR (proposer_id=v_target.id AND target_id=v_me.id))) THEN RETURN public.fc_get_state(); END IF;
 INSERT INTO public.fc_invitations(proposer_id,target_id) VALUES(v_me.id,v_target.id);
 INSERT INTO public.fc_notices(character_id,body) VALUES(v_target.id,v_me.display_name||'向你发出了道侣邀请。');
 RETURN public.fc_get_state();
END $$;

CREATE FUNCTION public.fc_respond_marriage(p_invitation_id uuid,p_accept boolean) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); v_me public.fc_characters; v_other public.fc_characters; v_inv public.fc_invitations; v_m uuid; v_father uuid; v_mother uuid;
BEGIN
 PERFORM 1 FROM public.fc_world WHERE id=1 FOR UPDATE;
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid;
 SELECT * INTO v_inv FROM public.fc_invitations WHERE id=p_invitation_id FOR UPDATE;
 IF v_inv.target_id IS DISTINCT FROM v_me.id OR v_me.id IS NULL THEN RAISE EXCEPTION '只有收到邀请的修士可以回复'; END IF;
 IF v_inv.status<>'pending' THEN RETURN public.fc_get_state(); END IF;
 IF NOT p_accept THEN UPDATE public.fc_invitations SET status='declined' WHERE id=v_inv.id; RETURN public.fc_get_state(); END IF;
 SELECT * INTO v_other FROM public.fc_characters WHERE id=v_inv.proposer_id;
 IF EXISTS(SELECT 1 FROM public.fc_marriages WHERE status='active' AND (v_me.id IN(parent_a,parent_b) OR v_other.id IN(parent_a,parent_b))) THEN RAISE EXCEPTION '已有道侣，不能接受此邀请'; END IF;
 v_father:=CASE WHEN v_me.gender='male' THEN v_me.id ELSE v_other.id END;
 v_mother:=CASE WHEN v_me.gender='female' THEN v_me.id ELSE v_other.id END;
 INSERT INTO public.fc_marriages(parent_a,parent_b) VALUES(v_father,v_mother) RETURNING id INTO v_m;
 INSERT INTO public.fc_birth_slots(marriage_id,slot_type) VALUES(v_m,'initial'),(v_m,'initial');
 UPDATE public.fc_invitations SET status='accepted' WHERE id=v_inv.id;
 UPDATE public.fc_invitations SET status='closed' WHERE status='pending' AND (proposer_id IN(v_me.id,v_other.id) OR target_id IN(v_me.id,v_other.id));
 INSERT INTO public.fc_notices(character_id,body) VALUES(v_me.id,'你与'||v_other.display_name||'结为道侣，已开放两个子女名额。'),(v_other.id,'你与'||v_me.display_name||'结为道侣，已开放两个子女名额。');
 RETURN public.fc_get_state();
END $$;

CREATE FUNCTION public.fc_open_extra_slot(p_request_id uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); v_me public.fc_characters; v_m public.fc_marriages; v_result jsonb;
BEGIN
 PERFORM 1 FROM public.fc_world WHERE id=1 FOR UPDATE;
 SELECT result INTO v_result FROM public.fc_receipts WHERE owner_id=v_uid AND action='extra_slot' AND request_id=p_request_id;
 IF FOUND THEN RETURN public.fc_get_state(); END IF;
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid;
 SELECT * INTO v_m FROM public.fc_marriages WHERE status='active' AND v_me.id IN(parent_a,parent_b);
 IF v_m.id IS NULL THEN RAISE EXCEPTION '请先结为道侣'; END IF;
 IF EXISTS(SELECT 1 FROM public.fc_birth_slots WHERE marriage_id=v_m.id AND slot_type='initial' AND claimed_by IS NULL) THEN RAISE EXCEPTION '默认两个名额尚未领满，请先接纳初始子女'; END IF;
 IF EXISTS(SELECT 1 FROM public.fc_birth_slots WHERE marriage_id=v_m.id AND slot_type='extra' AND claimed_by IS NULL) THEN RAISE EXCEPTION '已有可领取的额外名额'; END IF;
 INSERT INTO public.fc_birth_slots(marriage_id,slot_type,approved_by) VALUES(v_m.id,'extra',v_me.id);
 INSERT INTO public.fc_receipts(owner_id,action,request_id,result) VALUES(v_uid,'extra_slot',p_request_id,'{}'::jsonb);
 INSERT INTO public.fc_notices(character_id,body) VALUES(v_m.parent_a,v_me.display_name||'同意再接纳一名子女，额外名额已开放。'),(v_m.parent_b,v_me.display_name||'同意再接纳一名子女，额外名额已开放。');
 RETURN public.fc_get_state();
END $$;

CREATE FUNCTION public.fc_update_family(p_description text,p_accept_random boolean,p_gender_filter text,p_root_filter text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); v_me public.fc_characters;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid;
 IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 UPDATE public.fc_families SET description=p_description,accept_random=p_accept_random,gender_filter=p_gender_filter,root_filter=p_root_filter WHERE id=v_me.family_id AND leader_id=v_me.id;
 IF NOT FOUND THEN RAISE EXCEPTION '只有族长可以修改家族设置'; END IF;
 RETURN public.fc_get_state();
END $$;

CREATE FUNCTION public.fc_claim_cultivation() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); v_me public.fc_characters; v_minutes integer;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid FOR UPDATE;
 IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 v_minutes:=least(720,greatest(0,floor(extract(epoch FROM(now()-v_me.last_claim_at))/60)::integer));
 IF v_minutes>0 THEN
  UPDATE public.fc_characters SET cultivation=least(capacity,cultivation+v_minutes),last_claim_at=CASE WHEN now()-last_claim_at>interval '12 hours' THEN now() ELSE last_claim_at+make_interval(mins=>v_minutes) END WHERE id=v_me.id;
  INSERT INTO public.fc_notices(character_id,body) VALUES(v_me.id,'闭关结算：修炼了 '||v_minutes||' 分钟，灵气提升至丹田容量上限以内。');
 END IF;
 RETURN public.fc_get_state();
END $$;

REVOKE ALL ON FUNCTION public.fc_require_uid() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.fc_get_state(),public.fc_enter_world(text,text,text,text,uuid,uuid,boolean),public.fc_propose_marriage(uuid),public.fc_respond_marriage(uuid,boolean),public.fc_open_extra_slot(uuid),public.fc_update_family(text,boolean,text,text),public.fc_claim_cultivation() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fc_get_state(),public.fc_enter_world(text,text,text,text,uuid,uuid,boolean),public.fc_propose_marriage(uuid),public.fc_respond_marriage(uuid,boolean),public.fc_open_extra_slot(uuid),public.fc_update_family(text,boolean,text,text),public.fc_claim_cultivation() TO authenticated;
