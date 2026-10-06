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

INSERT INTO public.fc_recipes(id,name,profession,realm_min,spirit_cost,ingredients,output_key,output_name,output_category,description)
SELECT 'forge_'||item_key,'制作·'||name,'smith',realm_required,5*(realm_required+1),jsonb_build_object('ore_'||realm_required,CASE WHEN slot_type='weapon' THEN 6 ELSE 3 END,'hide_'||realm_required,CASE WHEN slot_type='weapon' THEN 1 ELSE 4 END)||CASE WHEN realm_required>=3 THEN jsonb_build_object('blood_'||realm_required,3,'fiber_'||realm_required,3) ELSE '{}' END,item_key,name,'装备','前期装备仅需宗族矿石与对应妖兽皮；高阶装备增加兽血与灵纤维。' FROM public.fc_equipment_definitions;
INSERT INTO public.fc_recipes(id,name,profession,spirit_cost,ingredients,output_key,output_name,output_category,description) VALUES
('star_platform','观星台','smith',10,'{"ore_0":10,"hide_0":2}','star_platform','观星台','工具','创作功法必备工具，制作后可重复使用。'),
('acupoint_chart','人体穴位图','talisman',10,'{"hide_0":4,"blood_0":2}','acupoint_chart','人体穴位图','工具','医术与创作功法参考，可重复使用。'),
('pill_expansion','扩灵丹','alchemy',10,'{"herb_0":6,"ore_0":1}','expansion_pill','扩灵丹','丹药','每颗增加本层基础丹田容量5%，不改变突破需求。'),
('pill_spirit','养神丹','alchemy',8,'{"herb_0":4,"blood_0":1}','spirit_pill','养神丹','丹药','恢复神识上限30%。'),
('pill_life','延寿丹','alchemy',20,'{"herb_0":12,"blood_0":3}','life_pill','延寿丹','丹药','恢复5年寿元，不超过境界寿元上限，每日最多一次。'),
('pill_lure','聚妖丹','alchemy',8,'{"herb_0":3,"blood_0":2}','lure_pill','聚妖丹','丹药','全境界可用，当前野外区域遇怪率100%，离开失效。'),
('pill_breakthrough','破境丹','alchemy',15,'{"herb_0":8,"blood_0":2}','breakthrough_pill','破境丹','丹药','下一小时大境界试炼胜率+10个百分点，使用一次突破后消失。'),
('pill_battle','战意丹','alchemy',10,'{"herb_0":4,"blood_0":2}','battle_pill','战意丹','丹药','十分钟内战斗攻击伤害+25%，不可叠加。'),
('pill_mana','回灵丹','alchemy',5,'{"herb_0":3}','mana_pill','回灵丹','丹药','战斗中恢复灵力上限40%。'),
('pill_health','疗伤丹','alchemy',5,'{"herb_0":3,"blood_0":1}','health_pill','疗伤丹','丹药','战斗中恢复生命上限35%。'),
('paper','符纸','talisman',3,'{"fiber_0":3}','talisman_paper','符纸','材料','灵田纸材加工，用于战斗符箓。'),
('fire_talisman','烈火符','talisman',8,'{"talisman_paper":2,"blood_0":2}','fire_talisman','烈火符','符箓','战斗消耗5%灵力，造成300%攻击伤害。'),
('thunder_talisman','雷击符','talisman',10,'{"talisman_paper":2,"blood_1":2}','thunder_talisman','雷击符','符箓','战斗消耗5%灵力，造成250%攻击伤害，眩晕1秒。'),
('create_manual','创作心法','author',15,'{"hide_0":3,"blood_0":1}','authored_manual','心法手稿','功法','炼气即可创作，需观星台及人体穴位图。占星和医术均达到3级且心境至少80可创作家族心法，否则为无名心法。'),
('create_sword','创作家族剑诀','author',20,'{"hide_0":4,"blood_0":2}','book_family_sword','家族战技·守城剑诀','功法','需要观星台、人体穴位图，每日创作上限十本。'),
('create_stun','创作震魂术','author',15,'{"hide_0":3,"blood_0":3}','book_spirit_stun','神识术·震魂','功法','需要观星台、人体穴位图。'),
('create_weapons','创作百兵战技','author',15,'{"hide_0":3,"blood_0":2}','book_weapon_basics','百兵基础战技','功法','基础武器使用战技。');
INSERT INTO public.fc_recipes(id,name,profession,realm_min,spirit_cost,ingredients,output_key,output_name,output_category,description) VALUES
('vajra_array','金刚阵','smith',1,20,'{"ore_1":8,"hide_1":3,"blood_1":2}','vajra_array','金刚阵','阵法','筑基以上可用，消耗一份保护当前地点两小时。');
CREATE FUNCTION public.fc_consume_item(p_key text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters; s jsonb; e public.fc_combat_encounters; cap numeric; mid text;
BEGIN
 SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE; IF c.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 s:=public.fc_get_attributes(); SELECT * INTO e FROM public.fc_combat_encounters WHERE character_id=c.id AND status='active' LIMIT 1 FOR UPDATE;
 IF p_key='expansion_pill' THEN
  IF c.capacity>=150 THEN RAISE EXCEPTION '丹田容量已达完美圆满'; END IF;
  PERFORM public.fc_claim_cultivation(); PERFORM public.fc_inventory_take(c.id,p_key,1); UPDATE public.fc_characters SET capacity=least(150,capacity+5) WHERE id=c.id;
 ELSIF p_key='spirit_pill' THEN
  PERFORM public.fc_inventory_take(c.id,p_key,1); UPDATE public.fc_characters SET consciousness=least((s->>'consciousness_max')::numeric,consciousness+(s->>'consciousness_max')::numeric*0.3) WHERE id=c.id;
 ELSIF p_key='life_pill' THEN
  IF c.pill_day=current_date AND coalesce((c.daily_pills->>'life')::integer,0)>=1 THEN RAISE EXCEPTION '延寿丹每日最多一次'; END IF;
  cap:=(ARRAY[100,200,500,1000,2000,4000])[c.realm_index+1]; IF c.lifespan>=cap THEN RAISE EXCEPTION '已达当前境界寿元上限'; END IF;
  PERFORM public.fc_inventory_take(c.id,p_key,1); UPDATE public.fc_characters SET lifespan=least(cap,lifespan+5),pill_day=current_date,daily_pills=jsonb_build_object('life',1) WHERE id=c.id;
 ELSIF p_key='lure_pill' THEN
  IF NOT EXISTS(SELECT 1 FROM public.fc_character_positions p JOIN public.fc_world_cells cell ON cell.id=p.cell_id JOIN public.fc_world_rooms r ON r.id=cell.room_id WHERE p.character_id=c.id AND NOT r.is_safe_city) OR EXISTS(SELECT 1 FROM public.fc_city_journeys WHERE character_id=c.id) THEN RAISE EXCEPTION '聚妖丹只能在野外或官道使用'; END IF;
  PERFORM public.fc_inventory_take(c.id,p_key,1); UPDATE public.fc_characters SET lure_room=(SELECT cell.room_id FROM public.fc_character_positions p JOIN public.fc_world_cells cell ON cell.id=p.cell_id WHERE p.character_id=c.id) WHERE id=c.id;
 ELSIF p_key IN ('battle_pill','breakthrough_pill') THEN
  IF p_key='breakthrough_pill' AND c.breakthrough_boost_until>now() OR p_key='battle_pill' AND c.battle_boost_until>now() THEN RAISE EXCEPTION '丹药效果仍在生效'; END IF;
  PERFORM public.fc_inventory_take(c.id,p_key,1); UPDATE public.fc_characters SET battle_boost_until=CASE WHEN p_key='battle_pill' THEN now()+interval '10 minutes' ELSE battle_boost_until END,breakthrough_boost_until=CASE WHEN p_key='breakthrough_pill' THEN now()+interval '1 hour' ELSE breakthrough_boost_until END WHERE id=c.id;
 ELSIF p_key IN ('health_pill','mana_pill','fire_talisman','thunder_talisman') THEN
  IF e.id IS NULL THEN RAISE EXCEPTION '此物品需要在战斗中使用'; END IF;
  IF p_key IN ('fire_talisman','thunder_talisman') AND e.player_mana<(s->>'mana')::numeric*0.05 THEN RAISE EXCEPTION '灵力不足'; END IF;
  IF p_key IN ('fire_talisman','thunder_talisman') AND e.item_at>now()-interval '3 seconds' THEN RAISE EXCEPTION '战斗物品冷却3秒'; END IF;
  PERFORM public.fc_inventory_take(c.id,p_key,1);
  UPDATE public.fc_combat_encounters SET player_health=CASE WHEN p_key='health_pill' THEN least((s->>'health')::numeric,player_health+(s->>'health')::numeric*0.35) ELSE player_health END,player_mana=CASE WHEN p_key='mana_pill' THEN least((s->>'mana')::numeric,player_mana+(s->>'mana')::numeric*0.4) WHEN p_key IN ('fire_talisman','thunder_talisman') THEN player_mana-(s->>'mana')::numeric*0.05 ELSE player_mana END,monster_health=CASE WHEN p_key='fire_talisman' THEN monster_health-(s->>'attack')::numeric*3 WHEN p_key='thunder_talisman' THEN monster_health-(s->>'attack')::numeric*2.5 ELSE monster_health END,stunned_until=CASE WHEN p_key='thunder_talisman' THEN now()+interval '1 second' ELSE stunned_until END,item_at=now(),battle_log=battle_log||jsonb_build_array('使用了'||p_key) WHERE id=e.id;
 ELSIF p_key LIKE 'book_%' THEN
  mid:=substring(p_key FROM 6); IF NOT EXISTS(SELECT 1 FROM public.fc_manual_definitions WHERE id=mid) THEN RAISE EXCEPTION '无法学习该功法'; END IF;
  IF EXISTS(SELECT 1 FROM public.fc_known_manuals WHERE character_id=c.id AND manual_id=mid) THEN RAISE EXCEPTION '已经学会此功法'; END IF;
  PERFORM public.fc_inventory_take(c.id,p_key,1); INSERT INTO public.fc_known_manuals(character_id,manual_id) VALUES(c.id,mid);
 ELSE RAISE EXCEPTION '该物品不可直接使用'; END IF;
 RETURN jsonb_build_object('message','使用成功','inventory',public.fc_get_inventory());
END $$;
REVOKE ALL ON FUNCTION public.fc_consume_item(text) FROM PUBLIC; GRANT EXECUTE ON FUNCTION public.fc_consume_item(text) TO authenticated;
ALTER TABLE public.fc_combat_encounters ADD COLUMN player_mana numeric NOT NULL DEFAULT 100, ADD COLUMN stunned_until timestamptz, ADD COLUMN item_at timestamptz;

CREATE OR REPLACE FUNCTION public.fc_claim_cultivation() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_uid text:=public.fc_require_uid(); v_me public.fc_characters; v_minutes integer; v_rate numeric; v_room public.fc_world_rooms; v_defense boolean; v_end timestamptz;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid FOR UPDATE;
 IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 SELECT r.* INTO v_room FROM public.fc_character_positions p JOIN public.fc_world_cells cell ON cell.id=p.cell_id JOIN public.fc_world_rooms r ON r.id=cell.room_id WHERE p.character_id=v_me.id;
 v_end:=now();
 IF NOT coalesce(v_room.is_safe_city,false) THEN
  SELECT expires_at INTO v_end FROM public.fc_defense_setups WHERE character_id=v_me.id AND room_id=v_room.id;
  v_end:=least(now(),coalesce(v_end,v_me.last_claim_at));
 END IF;
 IF EXISTS(SELECT 1 FROM public.fc_city_journeys WHERE character_id=v_me.id) THEN v_end:=v_me.last_claim_at; END IF;
 v_minutes:=least(720,greatest(0,floor(extract(epoch FROM(v_end-v_me.last_claim_at))/60)::integer));
 v_rate:=CASE WHEN v_me.worship_until IS NOT NULL AND v_me.worship_until>now() THEN 1.10 ELSE 1.0 END;
 IF EXISTS(SELECT 1 FROM public.fc_character_positions p JOIN public.fc_world_cells c ON c.id=p.cell_id JOIN public.fc_world_rooms r ON r.id=c.room_id WHERE p.character_id=v_me.id AND r.template_id='10000000-0000-0000-0000-000000000020' AND r.family_id=v_me.family_id) THEN v_rate:=v_rate+0.50; END IF;
 v_rate:=v_rate*(public.fc_mind_effects(v_me.mind)->>'cultivation')::numeric*public.fc_manual_rate(v_me);
 IF v_minutes>0 THEN
  UPDATE public.fc_known_manuals SET progress=least(100,progress+v_minutes/5) WHERE character_id=v_me.id AND manual_id=v_me.equipped_mind;
  UPDATE public.fc_characters SET cultivation=least(capacity,cultivation+v_minutes*v_rate*public.fc_aura_rate(v_me.realm_index)/public.fc_aura_requirement(v_me.realm_index,v_me.realm_layer)*100),last_claim_at=CASE WHEN now()-last_claim_at>interval '12 hours' THEN now() ELSE last_claim_at+make_interval(mins=>v_minutes) END WHERE id=v_me.id;
  INSERT INTO public.fc_notices(character_id,body) VALUES(v_me.id,CASE WHEN coalesce(v_room.is_safe_city,false) THEN '城内闭关结算：修炼了 ' ELSE '阵法守护下闭关结算：修炼了 ' END||v_minutes||' 分钟，灵气收益倍率为 '||v_rate||'。');
 END IF;
 IF v_end<now() THEN UPDATE public.fc_characters SET last_claim_at=now() WHERE id=v_me.id; END IF;
 PERFORM public.fc_recover_attributes();
 RETURN public.fc_get_state();
END $$;

CREATE OR REPLACE FUNCTION public.fc_get_attributes() RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters; s jsonb; k text; power numeric;
BEGIN
 PERFORM public.fc_recover_attributes(); SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid();
 s:=public.fc_base_stats(c.realm_index,c.realm_layer,c.realm_grade);
 FOREACH k IN ARRAY ARRAY['health','mana','attack','defense','speed','consciousness_max'] LOOP s:=jsonb_set(s,ARRAY[k],to_jsonb(round((s->>k)::numeric+coalesce((c.expansion_stats->>k)::numeric,0)+coalesce((public.fc_equipment_stats(c.id)->>k)::numeric,0),2))); END LOOP;
 s:=jsonb_set(s,ARRAY['health'],to_jsonb(round((s->>'health')::numeric*(1+public.fc_manual_health(c)),2)));
 power:=round((s->>'health')::numeric*0.2+(s->>'mana')::numeric*0.1+(s->>'attack')::numeric*5+(s->>'defense')::numeric*3+(s->>'speed')::numeric*2);
 RETURN s||jsonb_build_object('aura_required',public.fc_aura_requirement(c.realm_index,c.realm_layer),'aura_points',round(c.cultivation/100*public.fc_aura_requirement(c.realm_index,c.realm_layer),2),'aura_limit',c.capacity/100*public.fc_aura_requirement(c.realm_index,c.realm_layer),'aura_rate',public.fc_aura_rate(c.realm_index),'power',power,'mind',c.mind,'consciousness',round(c.consciousness,2),'effects',public.fc_mind_effects(c.mind),'expansion_stats',c.expansion_stats);
END $$;

CREATE OR REPLACE FUNCTION public.fc_character_power(c public.fc_characters) RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT round(((s->>'health')::numeric+coalesce((c.expansion_stats->>'health')::numeric,0)+coalesce((e->>'health')::numeric,0))*(1+public.fc_manual_health(c))*0.2+((s->>'mana')::numeric+coalesce((c.expansion_stats->>'mana')::numeric,0)+coalesce((e->>'mana')::numeric,0))*0.1+((s->>'attack')::numeric+coalesce((c.expansion_stats->>'attack')::numeric,0)+coalesce((e->>'attack')::numeric,0))*5+((s->>'defense')::numeric+coalesce((c.expansion_stats->>'defense')::numeric,0)+coalesce((e->>'defense')::numeric,0))*3+((s->>'speed')::numeric+coalesce((c.expansion_stats->>'speed')::numeric,0)+coalesce((e->>'speed')::numeric,0))*2) FROM public.fc_base_stats(c.realm_index,c.realm_layer,c.realm_grade) s,public.fc_equipment_stats(c.id) e
$$;
CREATE OR REPLACE FUNCTION public.fc_breakthrough(p_grade integer DEFAULT 1,p_request_id uuid DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_me public.fc_characters; v_uid text:=public.fc_require_uid(); v_result jsonb; v_major boolean; v_chance numeric; v_roll numeric; v_win boolean; v_extra numeric; v_realms text[]:=ARRAY['练气','筑基','金丹','元婴','出窍','化神']; v_layers text[]:=ARRAY['一','二','三','四','五','六','七','八','九']; v_log jsonb:='[]'::jsonb; v_old jsonb; v_new jsonb; v_bonus jsonb; k text;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid FOR UPDATE;
 IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 IF p_request_id IS NULL THEN RAISE EXCEPTION '缺少突破请求标识'; END IF;
 SELECT result INTO v_result FROM public.fc_breakthrough_records WHERE id=p_request_id AND character_id=v_me.id;
 IF v_result IS NOT NULL THEN RETURN jsonb_build_object('state',public.fc_get_state(),'trial',v_result); END IF;
 IF EXISTS(SELECT 1 FROM public.fc_breakthrough_records WHERE id=p_request_id) THEN RAISE EXCEPTION '请求标识无效'; END IF;
 IF p_grade NOT BETWEEN 1 AND 9 THEN RAISE EXCEPTION '品级必须在一至九品之间'; END IF;
 IF v_me.realm_index=5 AND v_me.realm_layer=9 THEN RAISE EXCEPTION '化神九层已达当前开放上限'; END IF;
 IF v_me.cultivation<100 THEN RAISE EXCEPTION '丹田灵气不足本层突破需求'; END IF;
 IF v_me.lifespan<=1 THEN RAISE EXCEPTION '寿元不足，无法承受突破'; END IF;
 v_major:=v_me.realm_layer=9;
 v_extra:=greatest(0,v_me.cultivation-100);
 IF v_major THEN
  UPDATE public.fc_characters SET breakthrough_boost_until=NULL WHERE id=v_me.id;
  v_chance:=greatest(5,least(95,70+CASE WHEN v_me.breakthrough_boost_until>now() THEN 10 ELSE 0 END+(public.fc_mind_effects(v_me.mind)->>'breakthrough_bonus')::numeric-(p_grade-1)*7+v_extra*0.8-(100-v_me.foundation)*0.5));
  v_roll:=random()*100;v_win:=v_roll<v_chance;
  v_log:=jsonb_build_array('你以'||v_me.realm||'的修为迎战'||p_grade||'品判定妖魔。','丹田灵气 '||v_me.cultivation||'%，道基 '||v_me.foundation||'%，本次胜率 '||v_chance||'%。');
 ELSE
  v_chance:=100;v_win:=true;
  v_log:=jsonb_build_array('灵气运转周天，冲击下一层修为。');
 END IF;
 IF v_win THEN
  v_old:=public.fc_base_stats(v_me.realm_index,v_me.realm_layer,v_me.realm_grade);
  v_new:=public.fc_base_stats(CASE WHEN v_major THEN v_me.realm_index+1 ELSE v_me.realm_index END,CASE WHEN v_major THEN 1 ELSE v_me.realm_layer+1 END,CASE WHEN v_major THEN p_grade ELSE v_me.realm_grade END);
  v_bonus:=v_me.expansion_stats;
  FOREACH k IN ARRAY ARRAY['health','mana','attack','defense','speed','consciousness_max'] LOOP
   v_bonus:=jsonb_set(v_bonus,ARRAY[k],to_jsonb(coalesce((v_bonus->>k)::numeric,0)+greatest(0,(v_new->>k)::numeric-(v_old->>k)::numeric)*v_extra/100));
  END LOOP;
  UPDATE public.fc_characters SET expansion_stats=v_bonus WHERE id=v_me.id;
  IF v_major THEN
  UPDATE public.fc_characters SET breakthrough_boost_until=NULL WHERE id=v_me.id;
   UPDATE public.fc_characters SET mind=least(100,mind+5),realm_index=realm_index+1,realm_layer=1,realm_grade=p_grade,realm=v_realms[v_me.realm_index+2]||'一层',cultivation=0,last_claim_at=now(),attribute_bonus=attribute_bonus+v_extra,lifespan=lifespan+(ARRAY[100,300,500,1000,2000])[v_me.realm_index+1] WHERE id=v_me.id;
   v_log:=v_log||jsonb_build_array('击败判定妖魔，突破至'||v_realms[v_me.realm_index+2]||'一层，定为'||p_grade||'品。');
  ELSE
   UPDATE public.fc_characters SET realm_layer=realm_layer+1,realm=v_realms[v_me.realm_index+1]||v_layers[v_me.realm_layer+1]||'层',cultivation=v_extra*public.fc_aura_requirement(v_me.realm_index,v_me.realm_layer)/public.fc_aura_requirement(v_me.realm_index,v_me.realm_layer+1),last_claim_at=now(),attribute_bonus=attribute_bonus+v_extra WHERE id=v_me.id;
   v_log:=v_log||jsonb_build_array('剩余灵气 '||round(v_extra/100*public.fc_aura_requirement(v_me.realm_index,v_me.realm_layer),2)||' 点流入下一层。突破成功：'||v_realms[v_me.realm_index+1]||v_layers[v_me.realm_layer+1]||'层。');
  END IF;
 ELSE
  UPDATE public.fc_characters SET cultivation=greatest(0,cultivation-50),lifespan=greatest(1,lifespan-5),foundation=greatest(0,foundation-CASE WHEN p_grade>=7 THEN 5 ELSE 2 END),last_claim_at=now() WHERE id=v_me.id;
  v_log:=v_log||jsonb_build_array('妖魔压制了你的突破：损失本层所需灵气的50%、5年寿元，道基减少'||CASE WHEN p_grade>=7 THEN 5 ELSE 2 END||'点，境界保持不变。');
 END IF;
 v_result:=jsonb_build_object('success',v_win,'major',v_major,'grade',CASE WHEN v_major THEN p_grade ELSE v_me.realm_grade END,'chance',v_chance,'log',v_log);
 INSERT INTO public.fc_breakthrough_records(id,character_id,result) VALUES(p_request_id,v_me.id,v_result);
 INSERT INTO public.fc_notices(character_id,body) VALUES(v_me.id,v_log->>(jsonb_array_length(v_log)-1));
 RETURN jsonb_build_object('state',public.fc_get_state(),'trial',v_result);
END $$;
REVOKE ALL ON FUNCTION public.fc_breakthrough(integer,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fc_breakthrough(integer,uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.fc_start_city_journey(p_destination integer,p_mode text DEFAULT 'walk') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_me public.fc_characters; v_city integer; v_distance numeric; v_seconds integer;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE;
 IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 PERFORM public.fc_get_world_state();
 IF EXISTS(SELECT 1 FROM public.fc_city_journeys WHERE character_id=v_me.id) THEN RAISE EXCEPTION '正在城际旅行'; END IF;
 SELECT r.city_id INTO v_city FROM public.fc_character_positions p JOIN public.fc_world_cells c ON c.id=p.cell_id JOIN public.fc_world_rooms r ON r.id=c.room_id WHERE p.character_id=v_me.id;
 SELECT distance INTO v_distance FROM public.fc_city_roads WHERE a=least(v_city,p_destination) AND b=greatest(v_city,p_destination);
 IF v_distance IS NULL THEN RAISE EXCEPTION '只能沿道路前往相邻城池'; END IF;
 IF p_mode<>'walk' THEN RAISE EXCEPTION '马车、飞剑、云舟需接入对应服务或器物后使用'; END IF;
 v_seconds:=30;
 PERFORM public.fc_claim_cultivation();
 INSERT INTO public.fc_city_journeys VALUES(v_me.id,p_destination,now(),now()+make_interval(secs=>v_seconds),p_mode);
 RETURN public.fc_get_world_state();
END $$;
REVOKE ALL ON FUNCTION public.fc_start_city_journey(integer,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fc_start_city_journey(integer,text) TO authenticated;

CREATE OR REPLACE FUNCTION public.fc_resolve_combat(p_action text DEFAULT 'auto') RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters; e public.fc_combat_encounters; m public.fc_monster_definitions; stats jsonb; damage numeric; incoming numeric; alive integer; crit boolean; sword boolean; hits numeric:=1; spirit_cost numeric; mana_cost numeric; skill_log text:=''; stun boolean:=false;
BEGIN
 SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE;
 IF c.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 SELECT * INTO e FROM public.fc_combat_encounters WHERE character_id=c.id AND status='active' LIMIT 1 FOR UPDATE;
 IF e.id IS NULL THEN RETURN public.fc_get_combat(); END IF;
 IF now()-e.tick_at<interval '1 second' THEN RETURN public.fc_get_combat(); END IF;
 SELECT * INTO m FROM public.fc_monster_definitions WHERE id=e.monster_id;
 stats:=public.fc_get_attributes(); crit:=random()<0.05;
 sword:=EXISTS(SELECT 1 FROM public.fc_equipment_instances WHERE character_id=c.id AND equipped_slot='weapon');
 damage:=greatest(1,(stats->>'attack')::numeric-m.base_defense*0.35)*(CASE WHEN crit THEN 1.5 ELSE 1 END);
 IF sword AND c.equipped_art IN ('nameless_sword','family_sword') THEN
  damage:=damage*CASE c.equipped_art WHEN 'nameless_sword' THEN 2 ELSE 2.2 END;
  mana_cost:=(stats->>'mana')::numeric*0.05;
  IF (e.turn+1)%3=0 AND e.player_mana>=mana_cost THEN hits:=CASE c.equipped_art WHEN 'nameless_sword' THEN 1.8 ELSE 1.95 END; skill_log:=' 三连斩'; END IF;
 ELSIF c.equipped_art='weapon_basics' THEN damage:=damage*1.3;
 END IF;
 damage:=damage*hits*CASE WHEN c.battle_boost_until>now() THEN 1.25 ELSE 1 END;
 spirit_cost:=(stats->>'consciousness_max')::numeric*0.1;
 IF c.equipped_spell='spirit_stun' AND e.turn%4=0 AND c.consciousness>=spirit_cost THEN
  damage:=damage+(stats->>'attack')::numeric*0.4; stun:=true; skill_log:=skill_log||' 震魂：眩晕1秒';
  UPDATE public.fc_characters SET consciousness=consciousness-spirit_cost WHERE id=c.id;
 END IF;
 alive:=greatest(0,ceil(greatest(0,e.monster_health-damage)/m.base_health)::integer);
 incoming:=CASE WHEN alive=0 OR stun OR e.stunned_until>e.tick_at THEN 0 ELSE greatest(1,m.base_attack-(stats->>'defense')::numeric*0.25)*(1+0.35*(alive-1)) END;
 UPDATE public.fc_combat_encounters SET tick_at=now(),turn=turn+1,player_mana=CASE WHEN hits>1 THEN greatest(0,player_mana-mana_cost) ELSE player_mana END,player_health=greatest(0,player_health-incoming),monster_health=greatest(0,monster_health-damage),battle_log=battle_log||jsonb_build_array('第'||(turn+1)||'回合：'||skill_log||' 造成'||round(damage)||'伤害，妖兽造成'||round(incoming)||'伤害。') WHERE id=e.id RETURNING * INTO e;
 IF e.monster_health<=0 THEN
  PERFORM public.fc_inventory_add(c.id,'hide_'||m.realm_index,(ARRAY['练气','筑基','金丹'])[m.realm_index+1]||'妖兽皮',2*e.monster_count,'材料','妖兽掉落，炼器及功法材料。');
  PERFORM public.fc_inventory_add(c.id,'blood_'||m.realm_index,(ARRAY['练气','筑基','金丹'])[m.realm_index+1]||'妖兽血',e.monster_count,'材料','妖兽掉落，炼丹及画符材料。');
  UPDATE public.fc_characters SET spirit_stones=spirit_stones+5*(m.realm_index+1)*e.monster_count,encounter_checked_at=now() WHERE id=c.id;
  UPDATE public.fc_combat_encounters SET status='won',result='胜利',battle_log=battle_log||jsonb_build_array('获得妖兽皮、妖兽血及'||(5*(m.realm_index+1)*e.monster_count)||'灵石。') WHERE id=e.id;
 ELSIF e.player_health<=0 THEN
  UPDATE public.fc_characters SET encounter_checked_at=now() WHERE id=c.id;
  UPDATE public.fc_combat_encounters SET status='lost',result='战败',battle_log=battle_log||jsonb_build_array('战败，本轮内测不扣寿元及物品。') WHERE id=e.id;
 END IF;
 RETURN public.fc_get_combat();
END $$;
CREATE FUNCTION public.fc_combat_mana_init() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN NEW.player_mana:=(public.fc_get_attributes()->>'mana')::numeric; RETURN NEW; END $$;
CREATE TRIGGER combat_mana_init BEFORE INSERT ON public.fc_combat_encounters FOR EACH ROW EXECUTE FUNCTION public.fc_combat_mana_init();
