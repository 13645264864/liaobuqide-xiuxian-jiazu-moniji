CREATE FUNCTION public.fc_profession_research(p_skill text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters;
BEGIN
 PERFORM public.fc_recover_attributes(); SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE;
 IF p_skill NOT IN ('astrology','medicine') THEN RAISE EXCEPTION '研究类型无效'; END IF;
 IF c.consciousness<10 THEN RAISE EXCEPTION '研究需要10点神识'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.fc_character_positions p JOIN public.fc_world_cells cell ON cell.id=p.cell_id JOIN public.fc_world_rooms r ON r.id=cell.room_id WHERE p.character_id=c.id AND r.family_id=c.family_id AND r.template_id='10000000-0000-0000-0000-000000000015') THEN RAISE EXCEPTION '请先前往本族练功房'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.fc_inventory_slots WHERE character_id=c.id AND item_key=CASE p_skill WHEN 'astrology' THEN 'star_platform' ELSE 'acupoint_chart' END) THEN RAISE EXCEPTION '占星需要观星台，医术需要人体穴位图'; END IF;
 IF c.research_at>now()-interval '60 seconds' THEN RAISE EXCEPTION '研究冷却60秒'; END IF;
 UPDATE public.fc_characters SET consciousness=consciousness-10,research_at=now(),profession_levels=jsonb_set(profession_levels,ARRAY[p_skill],to_jsonb(coalesce((profession_levels->>p_skill)::integer,1)+1)) WHERE id=c.id;
 RETURN public.fc_get_workshop();
END $$;
ALTER TABLE public.fc_characters ADD COLUMN research_at timestamptz;
REVOKE ALL ON FUNCTION public.fc_profession_research(text) FROM PUBLIC; GRANT EXECUTE ON FUNCTION public.fc_profession_research(text) TO authenticated;
