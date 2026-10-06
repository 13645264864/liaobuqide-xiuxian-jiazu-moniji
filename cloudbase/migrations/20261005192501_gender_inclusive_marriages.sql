CREATE OR REPLACE FUNCTION public.fc_propose_marriage(p_target_id uuid) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); v_me public.fc_characters; v_target public.fc_characters;
BEGIN
 PERFORM 1 FROM public.fc_world WHERE id=1 FOR UPDATE;
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid;
 SELECT * INTO v_target FROM public.fc_characters WHERE id=p_target_id;
 IF v_me.id IS NULL OR v_target.id IS NULL OR v_me.id=v_target.id THEN RAISE EXCEPTION '请先入世，并选择其他修士'; END IF;
 IF v_target.id IN(v_me.parent_a,v_me.parent_b) OR v_me.id IN(v_target.parent_a,v_target.parent_b)
 OR v_me.parent_a IN(v_target.parent_a,v_target.parent_b) OR v_me.parent_b IN(v_target.parent_a,v_target.parent_b) THEN RAISE EXCEPTION '直系亲属与兄弟姐妹不能结为道侣'; END IF;
 IF EXISTS(SELECT 1 FROM public.fc_marriages WHERE status='active' AND (v_me.id IN(parent_a,parent_b) OR v_target.id IN(parent_a,parent_b))) THEN RAISE EXCEPTION '已有道侣的修士不能重复成婚'; END IF;
 IF EXISTS(SELECT 1 FROM public.fc_invitations WHERE status='pending' AND ((proposer_id=v_me.id AND target_id=v_target.id) OR (proposer_id=v_target.id AND target_id=v_me.id))) THEN RETURN public.fc_get_state(); END IF;
 INSERT INTO public.fc_invitations(proposer_id,target_id) VALUES(v_me.id,v_target.id);
 INSERT INTO public.fc_notices(character_id,body) VALUES(v_target.id,v_me.display_name||'向你发出了道侣邀请。');
 RETURN public.fc_get_state();
END $$;

CREATE OR REPLACE FUNCTION public.fc_respond_marriage(p_invitation_id uuid,p_accept boolean) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
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
 v_father:=v_other.id;
 v_mother:=v_me.id;
 INSERT INTO public.fc_marriages(parent_a,parent_b) VALUES(v_father,v_mother) RETURNING id INTO v_m;
 INSERT INTO public.fc_birth_slots(marriage_id,slot_type) VALUES(v_m,'initial'),(v_m,'initial');
 UPDATE public.fc_invitations SET status='accepted' WHERE id=v_inv.id;
 UPDATE public.fc_invitations SET status='closed' WHERE status='pending' AND (proposer_id IN(v_me.id,v_other.id) OR target_id IN(v_me.id,v_other.id));
 INSERT INTO public.fc_notices(character_id,body) VALUES(v_me.id,'你与'||v_other.display_name||'结为道侣，已开放两个子女名额。'),(v_other.id,'你与'||v_me.display_name||'结为道侣，已开放两个子女名额。');
 RETURN public.fc_get_state();
END $$;

CREATE OR REPLACE FUNCTION public.fc_get_state() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
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
 SELECT c.id::text,c.display_name,CASE WHEN c.id=v_me.parent_a THEN '双亲' WHEN c.id=v_me.parent_b THEN '双亲'
 WHEN c.parent_a=v_me.id OR c.parent_b=v_me.id THEN '子女' ELSE '道侣' END AS role,f.name AS family_name,false AS deceased
 FROM public.fc_characters c JOIN public.fc_families f ON f.id=c.family_id
 WHERE c.id IN(v_me.parent_a,v_me.parent_b) OR c.parent_a=v_me.id OR c.parent_b=v_me.id
 OR EXISTS(SELECT 1 FROM public.fc_marriages m WHERE m.status='active' AND v_me.id IN(m.parent_a,m.parent_b) AND c.id IN(m.parent_a,m.parent_b) AND c.id<>v_me.id)
 UNION ALL SELECT 'ancestor-a',v_me.ancestor_a,'先父','已故先祖',true WHERE v_me.is_founder
 UNION ALL SELECT 'ancestor-b',v_me.ancestor_b,'先母','已故先祖',true WHERE v_me.is_founder) q),'[]'::jsonb));
 RETURN v_result;
END $$;
