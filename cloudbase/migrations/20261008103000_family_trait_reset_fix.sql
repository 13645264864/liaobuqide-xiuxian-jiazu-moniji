CREATE OR REPLACE FUNCTION public.fc_family_manual_action(p_id uuid,p_action text,p_trait integer DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters;m public.fc_family_manuals;cost integer;i integer;traits jsonb;key text;
BEGIN SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE;SELECT * INTO m FROM public.fc_family_manuals WHERE id=p_id AND character_id=c.id FOR UPDATE;
IF m.id IS NULL THEN RAISE EXCEPTION '没有这本家族功法';END IF;IF m.realm<>c.realm_index THEN RAISE EXCEPTION '只能使用当前境界的家族功法';END IF;
IF EXISTS(SELECT 1 FROM public.fc_combat_encounters WHERE character_id=c.id AND status='active') OR EXISTS(SELECT 1 FROM public.fc_trial_locks WHERE character_id=c.id AND expires_at>now()) THEN RAISE EXCEPTION '战斗或试炼中不能调整功法';END IF;
IF p_action='equip' THEN PERFORM public.fc_claim_cultivation();UPDATE public.fc_characters SET equipped_family_manual=m.id WHERE id=c.id;
ELSIF p_action='study' THEN IF m.progress=100 THEN RAISE EXCEPTION '已经修满';END IF;cost:=(ARRAY[15,45,135,405,1215,3645])[m.realm+1];PERFORM public.fc_recover_attributes();SELECT consciousness INTO c.consciousness FROM public.fc_characters WHERE id=c.id;IF c.consciousness<cost THEN RAISE EXCEPTION '研习需要%点神识',cost;END IF;traits:=m.traits;
IF m.progress+10>=100 THEN traits:='[]';FOR i IN 1..m.realm+1 LOOP traits:=traits||jsonb_build_array(public.fc_random_family_trait(m.realm));END LOOP;END IF;
UPDATE public.fc_family_manuals SET progress=least(100,progress+10),traits=traits WHERE id=m.id;UPDATE public.fc_characters SET consciousness=consciousness-cost WHERE id=c.id;
ELSIF p_action='reroll' THEN IF m.progress<100 OR p_trait IS NULL OR p_trait<0 OR p_trait>=jsonb_array_length(m.traits) THEN RAISE EXCEPTION '词条位置无效';END IF;key:='dao_aura_'||m.realm;
IF (SELECT coalesce(sum(quantity),0) FROM public.fc_inventory_slots WHERE character_id=c.id AND item_key=key)<10 THEN RAISE EXCEPTION '需要10份%道法气息',(ARRAY['练气','筑基','金丹','元婴','出窍','化神'])[m.realm+1];END IF;
PERFORM public.fc_inventory_take(c.id,key,10);UPDATE public.fc_family_manuals SET traits=jsonb_set(public.fc_family_manuals.traits,ARRAY[p_trait::text],public.fc_random_family_trait(m.realm)) WHERE id=m.id;
ELSE RAISE EXCEPTION '操作无效';END IF;RETURN public.fc_get_family_manuals();END $$;
