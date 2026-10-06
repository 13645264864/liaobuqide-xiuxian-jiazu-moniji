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
