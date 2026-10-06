CREATE OR REPLACE FUNCTION public.fc_require_uid() RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=auth.uid();
BEGIN
 IF v_uid IS NULL OR auth.role()='anon' THEN RAISE EXCEPTION '请先登录'; END IF;
 IF EXISTS(SELECT 1 FROM public.fc_closed_accounts WHERE fc_closed_accounts.uid=v_uid) THEN RAISE EXCEPTION '该游戏账号已坐化注销，无法再次入世'; END IF;
 RETURN v_uid;
END $$;

CREATE OR REPLACE FUNCTION public.fc_retire(p_confirmation text) RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); c public.fc_characters; successor uuid; world public.fc_world;
BEGIN
 SELECT * INTO world FROM public.fc_world WHERE id=1 FOR UPDATE;
 SELECT * INTO c FROM public.fc_characters WHERE owner_id=v_uid FOR UPDATE;
 IF c.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 IF p_confirmation IS DISTINCT FROM '确认坐化' THEN RAISE EXCEPTION '请输入确认坐化'; END IF;
 INSERT INTO public.fc_closed_accounts(uid,character_id) VALUES(v_uid,c.id);
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
   UPDATE public.fc_families SET city_id=NULL,accept_random=false,description=left(description,270)||'（宗族已无人，宅邸封存。）' WHERE id=c.family_id;
  END IF;
 END IF;
 UPDATE public.fc_characters SET mind=greatest(0,mind-CASE WHEN c.id IN(parent_a,parent_b) OR EXISTS(SELECT 1 FROM public.fc_relationships r WHERE r.owner_id=fc_characters.id AND r.target_id=c.id AND r.relation='friend') THEN 15 ELSE 5 END) WHERE family_id=c.family_id AND retired_at IS NULL;
 INSERT INTO public.fc_notices(character_id,body) SELECT id,c.display_name||'已经坐化，族谱保留其身世。' FROM public.fc_characters WHERE family_id=c.family_id AND retired_at IS NULL;
 RETURN jsonb_build_object('closed',true,'founder_slot_released',c.is_founder,'message','已坐化注销。身世保留在族谱，物品和修为不可恢复。');
END $$;

