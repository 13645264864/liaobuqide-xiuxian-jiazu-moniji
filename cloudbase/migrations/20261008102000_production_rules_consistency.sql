CREATE OR REPLACE FUNCTION public.fc_get_skills()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE me uuid;c_realm integer;
BEGIN SELECT id INTO me FROM public.fc_characters WHERE owner_id=public.fc_require_uid();IF me IS NULL THEN RAISE EXCEPTION '请先入世';END IF;
 SELECT realm_index INTO c_realm FROM public.fc_characters WHERE id=me;RETURN jsonb_build_object('skills',coalesce((SELECT jsonb_agg(to_jsonb(d)||jsonb_build_object('enhanced',k.enhanced,'slot',k.slot,'learned_realm',k.learned_realm,'effects',CASE WHEN k.enhanced THEN d.enhanced_effects ELSE d.effects END,'description',CASE WHEN k.enhanced THEN d.enhanced_description ELSE d.description END,'usable',d.realm_required IS NULL OR d.source='boss' AND c_realm>=d.realm_required OR d.source='family' AND c_realm=d.realm_required)) FROM public.fc_known_skills k JOIN public.fc_skill_definitions d ON d.id=k.skill_id WHERE k.character_id=me),'[]'::jsonb),'pending',coalesce((SELECT jsonb_agg(to_jsonb(c)) FROM public.fc_skill_choices c WHERE c.character_id=me AND selected_id IS NULL),'[]'::jsonb)); END $function$;

DO $$ DECLARE d text;BEGIN d:=pg_get_functiondef('public.fc_get_attributes()'::regprocedure);d:=replace(d,'s:=public.fc_apply_family_traits(c.id,s);','');d:=replace(d,'power:=round(', 's:=public.fc_apply_family_traits(c.id,s);power:=round(');EXECUTE d;END $$;

DO $$ DECLARE d text;BEGIN d:=pg_get_functiondef('public.fc_skill_tick(uuid,jsonb,jsonb,jsonb,numeric,numeric,integer,numeric,numeric,numeric,integer)'::regprocedure);d:=replace(d,'crossed AND has_ability THEN','crossed AND has_ability AND NOT coalesce((p_enemy->>''is_boss'')::boolean,false) THEN');EXECUTE d;END $$;
