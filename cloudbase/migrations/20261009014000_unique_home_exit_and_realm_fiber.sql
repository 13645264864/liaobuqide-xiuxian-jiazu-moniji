-- Collapse only identical UI exit records. Distinct directions remain selectable.
CREATE FUNCTION public.fc_unique_world_exits(p_exits jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
 SELECT coalesce(jsonb_agg(value ORDER BY ord),'[]'::jsonb) FROM
 (SELECT DISTINCT ON (value->>'from_cell',value->>'direction',value->>'to_room') value,ord
 FROM jsonb_array_elements(p_exits) WITH ORDINALITY AS e(value,ord)
 ORDER BY value->>'from_cell',value->>'direction',value->>'to_room',ord) deduplicated
$$;
REVOKE ALL ON FUNCTION public.fc_unique_world_exits(jsonb) FROM PUBLIC,anon,authenticated;
DO $patch$ DECLARE d text;start_at integer;end_at integer;old_part text;
BEGIN
 d:=pg_get_functiondef('public.fc_get_world_state()'::regprocedure);
 start_at:=position('''exits'',CASE WHEN' IN d);end_at:=position(',''navigation'',jsonb_build_object' IN d);
 IF start_at=0 OR end_at<=start_at THEN RAISE EXCEPTION 'Unexpected world-state exit expression';END IF;
 old_part:=substring(d FROM start_at FOR end_at-start_at);
 d:=replace(d,old_part,'''exits'',public.fc_unique_world_exits('||substring(old_part FROM 9)||')');
 EXECUTE d;
END $patch$;

UPDATE public.fc_inventory_slots SET item_name='竹子' WHERE item_key='bamboo';
UPDATE public.fc_inventory_slots SET item_name=(ARRAY['练气','筑基','金丹','元婴','出窍','化神'])[right(item_key,1)::integer+1]||'纸材纤维' WHERE item_key~'^fiber_[0-5]$';

-- Keep old generic paper usable for realm-zero crafting; stop producing it.
UPDATE public.fc_recipes SET active=false WHERE id='paper';
DO $$ DECLARE tier integer;names text[]:=ARRAY['练气','筑基','金丹','元婴','出窍','化神'];
BEGIN
 FOR tier IN 0..5 LOOP
 INSERT INTO public.fc_recipes(id,name,profession,realm_min,spirit_cost,ingredients,output_key,output_name,output_category,description,success_rate,output_quantity)
 VALUES('paper_r'||tier,names[tier+1]||'符纸','talisman',tier,0,jsonb_build_object('fiber_'||tier,3),'talisman_paper_'||tier,names[tier+1]||'符纸','材料','3份对应境界纸材纤维制作1张符纸，不消耗神识。',100,1);
 IF tier>0 THEN
 INSERT INTO public.fc_recipes(id,name,profession,realm_min,spirit_cost,ingredients,output_key,output_name,output_category,description,success_rate,output_quantity)
 VALUES('upgrade_fiber_r'||tier,'合成'||names[tier+1]||'纸材纤维','smith',tier,0,jsonb_build_object('fiber_'||(tier-1),3),'fiber_'||tier,names[tier+1]||'纸材纤维','材料','3份低一境界纸材纤维合成1份本境界纤维，成功率100%。',100,1);
 END IF;
 UPDATE public.fc_recipes SET ingredients=(ingredients-'talisman_paper')||jsonb_build_object('talisman_paper_'||tier,coalesce((ingredients->>'talisman_paper')::integer,2))
 WHERE active AND profession='talisman' AND realm_min=tier AND output_key IN('fire_talisman_'||tier,'thunder_talisman_'||tier);
 IF tier>=3 THEN
 UPDATE public.fc_recipes SET ingredients=ingredients||jsonb_build_object('fiber_'||tier,CASE WHEN profession='author' THEN 6 ELSE 3 END)
 WHERE active AND realm_min=tier AND (profession='author' OR profession='smith' AND output_category='装备');
 END IF;
 END LOOP;
END $$;

DO $patch$ DECLARE d text;needle text;
BEGIN
 d:=pg_get_functiondef('public.fc_craft(text)'::regprocedure);
 needle:='''forge_furnace'',''farm_hoe'',''bamboo_fiber'') AND';
 IF position(needle IN d)=0 THEN RAISE EXCEPTION 'Unexpected craft tooling guard';END IF;
 d:=replace(d,needle,'''forge_furnace'',''farm_hoe'',''bamboo_fiber'') AND recipe.id NOT LIKE ''upgrade_fiber_r%'' AND');
 d:=replace(d,'success:=random()*100<chance;', 'IF recipe.output_key LIKE ''talisman_paper_%'' OR recipe.id LIKE ''upgrade_fiber_r%'' THEN chance:=100;END IF;success:=random()*100<chance;');EXECUTE d;
 d:=pg_get_functiondef('public.fc_finish_gather_internal(text)'::regprocedure);
 needle:='IF p_kind=''herb'' AND random()<.10 THEN';
 IF position(needle IN d)=0 THEN RAISE EXCEPTION 'Unexpected herb seed drop hook';END IF;
 d:=replace(d,needle,'IF p_kind=''herb'' AND random()<.10 THEN PERFORM public.fc_inventory_add(c.id,''bamboo'',''竹子'',1,''材料'',''可在炼器中加工纸材纤维，1根竹子得10份练气纤维。'');message:=message||'' 获得1根竹子。'';END IF; '||needle);
 EXECUTE d;
END $patch$;
