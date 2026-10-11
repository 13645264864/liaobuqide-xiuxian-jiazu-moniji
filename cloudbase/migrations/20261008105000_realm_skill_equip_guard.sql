DO $$ DECLARE d text;BEGIN
 d:=pg_get_functiondef('public.fc_equip_skill(text,integer)'::regprocedure);
 d:=replace(d,'IF cat IS NULL THEN', 'IF p_slot IS NOT NULL AND EXISTS(SELECT 1 FROM public.fc_skill_definitions WHERE id=p_skill AND ((source=''family'' AND realm_required<>c.realm_index) OR (source=''boss'' AND realm_required>c.realm_index))) THEN RAISE EXCEPTION ''技能不符合当前境界'';END IF; IF cat IS NULL THEN');EXECUTE d;
END $$;
