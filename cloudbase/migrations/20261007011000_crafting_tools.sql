INSERT INTO public.fc_recipes(id,name,profession,spirit_cost,ingredients,output_key,output_name,output_category,description) VALUES
('forge_furnace','炼丹炉鼎','smith',10,'{"ore_0":8,"hide_0":1}','alchemy_furnace','炼丹炉鼎','工具','炼丹使用的炉鼎，可重复使用。'),
('forge_anvil','铁砧','smith',5,'{"ore_0":6}','smith_anvil','铁砧','工具','加工装备的基础工具。'),
('forge_hammer','铁锤','smith',5,'{"ore_0":3,"hide_0":1}','smith_hammer','铁锤','工具','配合铁砧炼器。');

CREATE OR REPLACE FUNCTION public.fc_craft(p_recipe text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters; recipe public.fc_recipes; part record; chance numeric; success boolean; free integer; eid uuid; eq public.fc_equipment_definitions; output text; authored text;
BEGIN
 PERFORM public.fc_recover_attributes(); SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE;
 SELECT * INTO recipe FROM public.fc_recipes WHERE id=p_recipe; IF recipe.id IS NULL THEN RAISE EXCEPTION '配方不存在'; END IF;
 IF recipe.profession='alchemy' AND NOT EXISTS(SELECT 1 FROM public.fc_inventory_slots WHERE character_id=c.id AND item_key='alchemy_furnace') THEN RAISE EXCEPTION '炼丹需要先制作炉鼎'; END IF;
 IF recipe.profession='smith' AND recipe.id NOT IN ('forge_anvil','forge_hammer','forge_furnace') AND (NOT EXISTS(SELECT 1 FROM public.fc_inventory_slots WHERE character_id=c.id AND item_key='smith_anvil') OR NOT EXISTS(SELECT 1 FROM public.fc_inventory_slots WHERE character_id=c.id AND item_key='smith_hammer')) THEN RAISE EXCEPTION '炼器需要铁砧与铁锤'; END IF;
 IF c.realm_index<recipe.realm_min THEN RAISE EXCEPTION '境界不足'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.fc_character_positions p JOIN public.fc_world_cells cell ON cell.id=p.cell_id JOIN public.fc_world_rooms r ON r.id=cell.room_id WHERE p.character_id=c.id AND r.family_id=c.family_id AND r.template_id=CASE recipe.profession WHEN 'smith' THEN '10000000-0000-0000-0000-000000000017'::uuid WHEN 'alchemy' THEN '10000000-0000-0000-0000-000000000016'::uuid WHEN 'talisman' THEN '10000000-0000-0000-0000-000000000018'::uuid ELSE '10000000-0000-0000-0000-000000000015'::uuid END) THEN RAISE EXCEPTION '请先前往对应本族炼器房、炼丹房、符纸房或练功房'; END IF;
 IF EXISTS(SELECT 1 FROM public.fc_combat_encounters WHERE character_id=c.id AND status='active') THEN RAISE EXCEPTION '战斗中无法制作'; END IF;
 IF c.consciousness<recipe.spirit_cost THEN RAISE EXCEPTION '神识不足'; END IF;
 IF recipe.profession='author' THEN
  IF NOT EXISTS(SELECT 1 FROM public.fc_inventory_slots WHERE character_id=c.id AND item_key='star_platform') OR NOT EXISTS(SELECT 1 FROM public.fc_inventory_slots WHERE character_id=c.id AND item_key='acupoint_chart') THEN RAISE EXCEPTION '创作功法需要观星台和人体穴位图'; END IF;
  IF c.authored_day=current_date AND c.authored_count>=10 THEN RAISE EXCEPTION '每天最多创作十本功法'; END IF;
 END IF;
 FOR part IN SELECT key,value::integer AS quantity FROM jsonb_each_text(recipe.ingredients) LOOP
  IF (SELECT coalesce(sum(quantity),0) FROM public.fc_inventory_slots WHERE character_id=c.id AND item_key=part.key AND equipment_id IS NULL)<part.quantity THEN RAISE EXCEPTION '缺少材料：%',part.key; END IF;
 END LOOP;
 IF (SELECT count(*) FROM public.fc_inventory_slots WHERE character_id=c.id)>=200 THEN RAISE EXCEPTION '请预留一格成品空间'; END IF;
 FOR part IN SELECT key,value::integer AS quantity FROM jsonb_each_text(recipe.ingredients) LOOP PERFORM public.fc_inventory_take(c.id,part.key,part.quantity); END LOOP;
 chance:=least(95,recipe.success_rate+(public.fc_mind_effects(c.mind)->>'craft_bonus')::numeric+least(5,coalesce((c.profession_levels->>recipe.profession)::integer,1)-1));
 IF recipe.profession='author' THEN chance:=least(95,chance+least(5,coalesce((c.profession_levels->>'astrology')::integer,1)+coalesce((c.profession_levels->>'medicine')::integer,1)-2)); END IF;
 success:=random()*100<chance;
 UPDATE public.fc_characters SET consciousness=consciousness-recipe.spirit_cost,profession_levels=jsonb_set(profession_levels,ARRAY[recipe.profession],to_jsonb(coalesce((profession_levels->>recipe.profession)::integer,1)+1)),authored_count=CASE WHEN recipe.profession='author' THEN CASE WHEN authored_day=current_date THEN authored_count+1 ELSE 1 END ELSE authored_count END,authored_day=CASE WHEN recipe.profession='author' THEN current_date ELSE authored_day END WHERE id=c.id;
 IF success THEN
  SELECT * INTO eq FROM public.fc_equipment_definitions WHERE item_key=recipe.output_key;
  IF eq.item_key IS NOT NULL THEN
   SELECT n INTO free FROM generate_series(1,200) n WHERE NOT EXISTS(SELECT 1 FROM public.fc_inventory_slots WHERE character_id=c.id AND slot=n) ORDER BY n LIMIT 1;
   INSERT INTO public.fc_equipment_instances(character_id,item_key) VALUES(c.id,eq.item_key) RETURNING id INTO eid;
   INSERT INTO public.fc_inventory_slots(character_id,slot,item_key,item_name,quantity,category,description,equipment_id) VALUES(c.id,free,eq.item_key,eq.name,1,'装备',eq.description,eid);
  ELSE
   output:=recipe.output_key;
   IF recipe.profession='author' AND output='authored_manual' THEN
    authored:=CASE WHEN c.mind>=80 AND coalesce((c.profession_levels->>'astrology')::integer,1)>=3 AND coalesce((c.profession_levels->>'medicine')::integer,1)>=3 THEN 'family_mind' ELSE 'nameless_mind' END;
    output:='book_'||authored;
   END IF;
   PERFORM public.fc_inventory_add(c.id,output,CASE WHEN authored IS NOT NULL THEN (SELECT name FROM public.fc_manual_definitions WHERE id=authored)||'手稿' ELSE recipe.output_name END,recipe.output_quantity,recipe.output_category,recipe.description);
  END IF;
 END IF;
 RETURN jsonb_build_object('message',CASE WHEN success THEN '制作成功：'||recipe.output_name ELSE '制作失败，材料及神识已消耗。' END,'success',success,'chance',chance,'workshop',public.fc_get_workshop());
END $$;

