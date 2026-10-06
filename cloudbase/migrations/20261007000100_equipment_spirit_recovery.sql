CREATE OR REPLACE FUNCTION public.fc_recover_attributes() RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters; elapsed numeric; max_spirit numeric; effects jsonb; hours integer; gain integer;
BEGIN
 SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE; IF c.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 elapsed:=least(720,greatest(0,extract(epoch FROM(now()-c.recovery_at))/60));
 max_spirit:=(public.fc_base_stats(c.realm_index,c.realm_layer,c.realm_grade)->>'consciousness_max')::numeric+coalesce((c.expansion_stats->>'consciousness_max')::numeric,0)+coalesce((public.fc_equipment_stats(c.id)->>'consciousness_max')::numeric,0);
 effects:=public.fc_mind_effects(c.mind);
 UPDATE public.fc_characters SET consciousness=least(max_spirit,consciousness+elapsed*max_spirit*0.01*(effects->>'recovery')::numeric),recovery_at=now() WHERE id=c.id;
END $$;
