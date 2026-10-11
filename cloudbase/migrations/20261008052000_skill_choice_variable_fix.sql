CREATE OR REPLACE FUNCTION public.fc_generate_skill_choice(p_record uuid,p_character uuid,p_grade integer,p_realm integer) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE cards jsonb:='[]';d public.fc_skill_definitions;ability boolean;prob numeric; is_enhanced boolean:=p_grade=9;ids text[]:=ARRAY[]::text[];i integer;cat text;existing jsonb;
BEGIN
 SELECT candidates INTO existing FROM public.fc_skill_choices WHERE id=p_record;IF existing IS NOT NULL THEN RETURN existing;END IF;
 prob:=CASE p_grade WHEN 4 THEN .2 WHEN 5 THEN .4 WHEN 6 THEN .6 ELSE 0 END;ability:=p_grade>=7 OR random()<prob;
 FOR i IN 1..3 LOOP
 cat:=CASE WHEN p_grade>=7 OR ability AND i=1 THEN 'ability' ELSE 'art' END;
 SELECT * INTO d FROM public.fc_skill_definitions WHERE category=cat AND NOT(id=ANY(ids)) ORDER BY EXISTS(SELECT 1 FROM public.fc_known_skills k WHERE k.character_id=p_character AND k.skill_id=fc_skill_definitions.id AND (NOT is_enhanced OR k.enhanced)),random() LIMIT 1;
 ids:=array_append(ids,d.id);cards:=cards||jsonb_build_array(to_jsonb(d)||jsonb_build_object('enhanced',is_enhanced,'effects',CASE WHEN is_enhanced THEN d.enhanced_effects ELSE d.effects END,'description',CASE WHEN is_enhanced THEN d.enhanced_description ELSE d.description END));END LOOP;
 INSERT INTO public.fc_skill_choices(id,character_id,grade,realm,candidates) VALUES(p_record,p_character,p_grade,p_realm,cards);RETURN cards;END $$;
