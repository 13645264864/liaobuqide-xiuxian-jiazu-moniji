ALTER TABLE public.fc_characters ADD COLUMN manuals_granted boolean NOT NULL DEFAULT false, ADD COLUMN equipped_mind text, ADD COLUMN equipped_art text, ADD COLUMN equipped_spell text, ADD COLUMN profession_levels jsonb NOT NULL DEFAULT '{"smith":1,"alchemy":1,"talisman":1,"author":1,"astrology":1,"medicine":1}', ADD COLUMN gathering_at timestamptz, ADD COLUMN authored_day date NOT NULL DEFAULT current_date, ADD COLUMN authored_count integer NOT NULL DEFAULT 0, ADD COLUMN daily_pills jsonb NOT NULL DEFAULT '{}', ADD COLUMN pill_day date NOT NULL DEFAULT current_date, ADD COLUMN breakthrough_boost_until timestamptz, ADD COLUMN battle_boost_until timestamptz, ADD COLUMN health_bonus numeric NOT NULL DEFAULT 0;
CREATE TABLE public.fc_manual_definitions(id text PRIMARY KEY,name text NOT NULL,category text NOT NULL,realm_min integer NOT NULL DEFAULT 0,realm_max integer NOT NULL DEFAULT 5,description text NOT NULL);
CREATE TABLE public.fc_known_manuals(character_id uuid REFERENCES public.fc_characters(id),manual_id text REFERENCES public.fc_manual_definitions(id),progress integer NOT NULL DEFAULT 0 CHECK(progress BETWEEN 0 AND 100),PRIMARY KEY(character_id,manual_id));
CREATE TABLE public.fc_recipes(id text PRIMARY KEY,name text NOT NULL,profession text NOT NULL,realm_min integer NOT NULL DEFAULT 0,spirit_cost integer NOT NULL,ingredients jsonb NOT NULL,output_key text NOT NULL,output_name text NOT NULL,output_category text NOT NULL,output_quantity integer NOT NULL DEFAULT 1,description text NOT NULL,success_rate integer NOT NULL DEFAULT 85);
ALTER TABLE public.fc_manual_definitions ENABLE ROW LEVEL SECURITY; ALTER TABLE public.fc_known_manuals ENABLE ROW LEVEL SECURITY; ALTER TABLE public.fc_recipes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.fc_manual_definitions,public.fc_known_manuals,public.fc_recipes FROM anon,authenticated;
INSERT INTO public.fc_manual_definitions(id,name,category,realm_max,description) VALUES
('nameless_mind','无名心法','mind',1,'练气、筑基修炼速度×10；熟练度满100后，装备时生命上限+30%。'),
('family_mind','家族心法','mind',5,'练气、筑基修炼速度×12；金丹及以上×1.5。修满后装备时生命上限+40%。'),
('nameless_sword','无名战技','art',5,'佩剑时普通攻击伤害+100%，每三回合发动三连斩，每斩为强化后普通攻击的60%。'),
('family_sword','家族战技·守城剑诀','art',5,'佩剑时攻击伤害+120%，每三回合发动三连斩，每斩为强化后普通攻击的65%。'),
('spirit_stun','神识术·震魂','spell',5,'每四回合消耗10%神识上限，先造成40%攻击伤害，眩晕妖兽1秒，使其跳过本回合反击。'),
('weapon_basics','百兵基础战技','art',5,'普通伤害+30%；适用于已实现的剑及将来开放的其他武器。');
CREATE FUNCTION public.fc_inventory_add(p_character uuid,p_key text,p_name text,p_quantity integer,p_category text,p_description text DEFAULT '') RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_slot integer;
BEGIN
 IF p_quantity<=0 THEN RAISE EXCEPTION '物品数量必须为正数'; END IF;
 SELECT slot INTO v_slot FROM public.fc_inventory_slots WHERE character_id=p_character AND item_key=p_key AND equipment_id IS NULL ORDER BY slot LIMIT 1 FOR UPDATE;
 IF v_slot IS NOT NULL THEN UPDATE public.fc_inventory_slots SET quantity=quantity+p_quantity WHERE character_id=p_character AND slot=v_slot; RETURN; END IF;
 SELECT n INTO v_slot FROM generate_series(1,200) n WHERE NOT EXISTS(SELECT 1 FROM public.fc_inventory_slots WHERE character_id=p_character AND slot=n) ORDER BY n LIMIT 1;
 IF v_slot IS NULL THEN RAISE EXCEPTION '储物空间不足，请先整理'; END IF;
 INSERT INTO public.fc_inventory_slots(character_id,slot,item_key,item_name,quantity,category,description) VALUES(p_character,v_slot,p_key,p_name,p_quantity,p_category,p_description);
END $$;
CREATE FUNCTION public.fc_inventory_take(p_character uuid,p_key text,p_quantity integer) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE item public.fc_inventory_slots; remaining integer:=p_quantity; take integer;
BEGIN
 IF p_quantity<=0 THEN RAISE EXCEPTION '物品数量必须为正数'; END IF;
 IF (SELECT coalesce(sum(quantity),0) FROM public.fc_inventory_slots WHERE character_id=p_character AND item_key=p_key AND equipment_id IS NULL)<p_quantity THEN RAISE EXCEPTION '材料不足：%',p_key; END IF;
 FOR item IN SELECT * FROM public.fc_inventory_slots WHERE character_id=p_character AND item_key=p_key AND equipment_id IS NULL ORDER BY slot FOR UPDATE LOOP
  take:=least(remaining,item.quantity);
  IF take=item.quantity THEN DELETE FROM public.fc_inventory_slots WHERE character_id=p_character AND slot=item.slot; ELSE UPDATE public.fc_inventory_slots SET quantity=quantity-take WHERE character_id=p_character AND slot=item.slot; END IF;
  remaining:=remaining-take; EXIT WHEN remaining=0;
 END LOOP;
END $$;
REVOKE ALL ON FUNCTION public.fc_inventory_add(uuid,text,text,integer,text,text),public.fc_inventory_take(uuid,text,integer) FROM PUBLIC;
CREATE FUNCTION public.fc_manual_rate(c public.fc_characters) RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
 SELECT CASE WHEN c.equipped_mind='nameless_mind' AND c.realm_index<2 THEN 10 WHEN c.equipped_mind='family_mind' AND c.realm_index<2 THEN 12 WHEN c.equipped_mind='family_mind' THEN 1.5 ELSE 1 END
$$;
CREATE FUNCTION public.fc_manual_health(c public.fc_characters) RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT CASE WHEN EXISTS(SELECT 1 FROM public.fc_known_manuals WHERE character_id=c.id AND manual_id=c.equipped_mind AND progress=100) THEN CASE c.equipped_mind WHEN 'family_mind' THEN 0.4 WHEN 'nameless_mind' THEN 0.3 ELSE 0 END ELSE 0 END
$$;
REVOKE ALL ON FUNCTION public.fc_manual_health(public.fc_characters) FROM PUBLIC;
CREATE FUNCTION public.fc_get_manuals() RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters;
BEGIN
 SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE; IF c.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 IF NOT c.manuals_granted THEN
  INSERT INTO public.fc_known_manuals(character_id,manual_id) VALUES(c.id,'nameless_mind'),(c.id,'nameless_sword') ON CONFLICT DO NOTHING;
  UPDATE public.fc_characters SET manuals_granted=true,equipped_mind=coalesce(equipped_mind,'nameless_mind'),equipped_art=coalesce(equipped_art,'nameless_sword'),last_claim_at=now() WHERE id=c.id RETURNING * INTO c;
 END IF;
 RETURN jsonb_build_object('equipped_mind',c.equipped_mind,'equipped_art',c.equipped_art,'equipped_spell',c.equipped_spell,'realm_index',c.realm_index,'manuals',coalesce((SELECT jsonb_agg(to_jsonb(d)||jsonb_build_object('progress',k.progress)) FROM public.fc_known_manuals k JOIN public.fc_manual_definitions d ON d.id=k.manual_id WHERE k.character_id=c.id),'[]'::jsonb));
END $$;
CREATE FUNCTION public.fc_equip_manual(p_id text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters; d public.fc_manual_definitions;
BEGIN
 SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE;
 SELECT * INTO d FROM public.fc_manual_definitions WHERE id=p_id;
 IF NOT EXISTS(SELECT 1 FROM public.fc_known_manuals WHERE character_id=c.id AND manual_id=p_id) THEN RAISE EXCEPTION '尚未学会此功法'; END IF;
 IF c.realm_index NOT BETWEEN d.realm_min AND d.realm_max THEN RAISE EXCEPTION '此功法不适用于当前境界'; END IF;
 IF EXISTS(SELECT 1 FROM public.fc_combat_encounters WHERE character_id=c.id AND status='active') THEN RAISE EXCEPTION '战斗中不能更换功法'; END IF;
 PERFORM public.fc_claim_cultivation();
 UPDATE public.fc_characters SET equipped_mind=CASE WHEN d.category='mind' THEN p_id ELSE equipped_mind END,equipped_art=CASE WHEN d.category='art' THEN p_id ELSE equipped_art END,equipped_spell=CASE WHEN d.category='spell' THEN p_id ELSE equipped_spell END,last_claim_at=now() WHERE id=c.id;
 RETURN public.fc_get_manuals();
END $$;
CREATE FUNCTION public.fc_study_manual(p_id text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters;
BEGIN
 PERFORM public.fc_recover_attributes(); SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE;
 IF NOT EXISTS(SELECT 1 FROM public.fc_known_manuals WHERE character_id=c.id AND manual_id=p_id AND progress<100) THEN RAISE EXCEPTION '功法尚未学会或已经修满'; END IF;
 IF c.consciousness<10 THEN RAISE EXCEPTION '神识不足，研习需要10点'; END IF;
 IF EXISTS(SELECT 1 FROM public.fc_combat_encounters WHERE character_id=c.id AND status='active') THEN RAISE EXCEPTION '战斗中不能研习'; END IF;
 UPDATE public.fc_known_manuals SET progress=least(100,progress+10) WHERE character_id=c.id AND manual_id=p_id;
 UPDATE public.fc_characters SET consciousness=consciousness-10 WHERE id=c.id;
 RETURN public.fc_get_manuals();
END $$;
CREATE FUNCTION public.fc_get_workshop() RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters;
BEGIN
 PERFORM public.fc_recover_attributes(); SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid();
 IF c.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 RETURN jsonb_build_object('realm_index',c.realm_index,'consciousness',c.consciousness,'skills',c.profession_levels,'craft_bonus',(public.fc_mind_effects(c.mind)->>'craft_bonus')::numeric,'recipes',(SELECT jsonb_agg(to_jsonb(r) ORDER BY realm_min,name) FROM public.fc_recipes r),'inventory',public.fc_get_inventory());
END $$;
CREATE FUNCTION public.fc_gather(p_kind text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters; r public.fc_world_rooms; tier integer;
BEGIN
 SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE;
 SELECT room.* INTO r FROM public.fc_character_positions p JOIN public.fc_world_cells cell ON cell.id=p.cell_id JOIN public.fc_world_rooms room ON room.id=cell.room_id WHERE p.character_id=c.id;
 IF r.family_id IS DISTINCT FROM c.family_id OR r.template_id IS DISTINCT FROM (CASE WHEN p_kind='ore' THEN '10000000-0000-0000-0000-000000000021'::uuid ELSE '10000000-0000-0000-0000-000000000022'::uuid END) THEN RAISE EXCEPTION '挖矿需前往本族灵矿，采集药草及纸材需前往本族灵田'; END IF;
 IF p_kind NOT IN ('ore','herb','fiber') THEN RAISE EXCEPTION '采集类型无效'; END IF;
 IF c.gathering_at>now()-interval '30 seconds' THEN RAISE EXCEPTION '采集冷却30秒'; END IF;
 tier:=least(2,c.realm_index);
 PERFORM public.fc_inventory_add(c.id,p_kind||'_'||tier,(ARRAY['练气','筑基','金丹'])[tier+1]||CASE p_kind WHEN 'ore' THEN '灵矿石' WHEN 'herb' THEN '药草' ELSE '纸材纤维' END,3,'材料','家族后山采集，用于制作。');
 UPDATE public.fc_characters SET gathering_at=now() WHERE id=c.id;
 RETURN public.fc_get_workshop();
END $$;
CREATE FUNCTION public.fc_craft(p_recipe text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters; recipe public.fc_recipes; part record; chance numeric; success boolean; free integer; eid uuid; eq public.fc_equipment_definitions; output text; authored text;
BEGIN
 PERFORM public.fc_recover_attributes(); SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE;
 SELECT * INTO recipe FROM public.fc_recipes WHERE id=p_recipe; IF recipe.id IS NULL THEN RAISE EXCEPTION '配方不存在'; END IF;
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
REVOKE ALL ON FUNCTION public.fc_get_manuals(),public.fc_equip_manual(text),public.fc_study_manual(text),public.fc_get_workshop(),public.fc_gather(text),public.fc_craft(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fc_get_manuals(),public.fc_equip_manual(text),public.fc_study_manual(text),public.fc_get_workshop(),public.fc_gather(text),public.fc_craft(text) TO authenticated;
