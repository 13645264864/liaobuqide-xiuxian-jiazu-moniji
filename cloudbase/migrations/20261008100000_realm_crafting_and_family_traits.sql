ALTER TABLE public.fc_recipes ADD COLUMN active boolean NOT NULL DEFAULT true;
ALTER TABLE public.fc_skill_definitions ADD COLUMN source text NOT NULL DEFAULT 'breakthrough',ADD COLUMN realm_required integer;
ALTER TABLE public.fc_monster_definitions ADD COLUMN is_boss boolean NOT NULL DEFAULT false,ADD COLUMN boss_skill text,ADD COLUMN boss_damage numeric NOT NULL DEFAULT 0,ADD COLUMN boss_cooldown integer NOT NULL DEFAULT 10;
CREATE TABLE public.fc_family_manuals(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),character_id uuid NOT NULL REFERENCES public.fc_characters(id),realm integer NOT NULL CHECK(realm BETWEEN 0 AND 5),name text NOT NULL,progress integer NOT NULL DEFAULT 0 CHECK(progress BETWEEN 0 AND 100),traits jsonb NOT NULL DEFAULT '[]',created_at timestamptz NOT NULL DEFAULT now());
ALTER TABLE public.fc_family_manuals ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.fc_family_manuals FROM PUBLIC,authenticated,anon;
ALTER TABLE public.fc_characters ADD COLUMN equipped_family_manual uuid REFERENCES public.fc_family_manuals(id);

CREATE FUNCTION public.fc_random_family_trait(p_realm integer) RETURNS jsonb LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
DECLARE keys text[]:=ARRAY['health','mana','attack','defense','consciousness_max','recovery','speed','cost','alchemy','smith','talisman'];n integer:=1+floor(random()*11)::integer;value numeric;
BEGIN value:=CASE keys[n] WHEN 'health' THEN .35+p_realm*.05 WHEN 'mana' THEN .35+p_realm*.05 WHEN 'consciousness_max' THEN .35+p_realm*.05 WHEN 'attack' THEN .15+p_realm*.03 WHEN 'defense' THEN .20+p_realm*.04 WHEN 'recovery' THEN .20+p_realm*.05 WHEN 'speed' THEN .05+p_realm*.01 WHEN 'cost' THEN .03+p_realm*.01 ELSE .02+p_realm*.01 END;RETURN jsonb_build_object('key',keys[n],'value',value);END $$;
REVOKE ALL ON FUNCTION public.fc_random_family_trait(integer) FROM PUBLIC,authenticated,anon;

CREATE FUNCTION public.fc_family_traits(p_character uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE m public.fc_family_manuals;c public.fc_characters;t jsonb;result jsonb:='{}';k text;
BEGIN SELECT * INTO c FROM public.fc_characters WHERE id=p_character;SELECT * INTO m FROM public.fc_family_manuals WHERE id=c.equipped_family_manual AND character_id=c.id AND realm=c.realm_index AND progress=100;IF m.id IS NULL THEN RETURN result;END IF;
FOR t IN SELECT value FROM jsonb_array_elements(m.traits) LOOP k:=t->>'key';result:=jsonb_set(result,ARRAY[k],to_jsonb(coalesce((result->>k)::numeric,0)+(t->>'value')::numeric));END LOOP;RETURN result;END $$;
REVOKE ALL ON FUNCTION public.fc_family_traits(uuid) FROM PUBLIC,authenticated,anon;

CREATE FUNCTION public.fc_get_family_manuals() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters;
BEGIN SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid();IF c.id IS NULL THEN RAISE EXCEPTION '请先入世';END IF;
RETURN jsonb_build_object('equipped',c.equipped_family_manual,'realm',c.realm_index,'manuals',coalesce((SELECT jsonb_agg(to_jsonb(m)||jsonb_build_object('rate',(ARRAY[12,12,16,16,20,20])[m.realm+1],'study_cost',(ARRAY[15,45,135,405,1215,3645])[m.realm+1])) FROM public.fc_family_manuals m WHERE character_id=c.id),'[]'::jsonb));END $$;

CREATE FUNCTION public.fc_family_manual_action(p_id uuid,p_action text,p_trait integer DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters;m public.fc_family_manuals;cost integer;i integer;traits jsonb;key text;
BEGIN SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE;SELECT * INTO m FROM public.fc_family_manuals WHERE id=p_id AND character_id=c.id FOR UPDATE;
IF m.id IS NULL THEN RAISE EXCEPTION '没有这本家族功法';END IF;IF m.realm<>c.realm_index THEN RAISE EXCEPTION '只能使用当前境界的家族功法';END IF;
IF EXISTS(SELECT 1 FROM public.fc_combat_encounters WHERE character_id=c.id AND status='active') OR EXISTS(SELECT 1 FROM public.fc_trial_locks WHERE character_id=c.id AND expires_at>now()) THEN RAISE EXCEPTION '战斗或试炼中不能调整功法';END IF;
IF p_action='equip' THEN PERFORM public.fc_claim_cultivation();UPDATE public.fc_characters SET equipped_family_manual=m.id WHERE id=c.id;
ELSIF p_action='study' THEN IF m.progress=100 THEN RAISE EXCEPTION '已经修满';END IF;cost:=(ARRAY[15,45,135,405,1215,3645])[m.realm+1];PERFORM public.fc_recover_attributes();SELECT consciousness INTO c.consciousness FROM public.fc_characters WHERE id=c.id;IF c.consciousness<cost THEN RAISE EXCEPTION '研习需要%点神识',cost;END IF;traits:=m.traits;
IF m.progress+10>=100 THEN traits:='[]';FOR i IN 1..m.realm+1 LOOP traits:=traits||jsonb_build_array(public.fc_random_family_trait(m.realm));END LOOP;END IF;
UPDATE public.fc_family_manuals SET progress=least(100,progress+10),traits=traits WHERE id=m.id;UPDATE public.fc_characters SET consciousness=consciousness-cost WHERE id=c.id;
ELSIF p_action='reroll' THEN IF m.progress<100 OR p_trait IS NULL OR p_trait<0 OR p_trait>=jsonb_array_length(m.traits) THEN RAISE EXCEPTION '词条位置无效';END IF;key:='dao_aura_'||m.realm;
IF (SELECT coalesce(sum(quantity),0) FROM public.fc_inventory_slots WHERE character_id=c.id AND item_key=key)<10 THEN RAISE EXCEPTION '需要10份%道法气息',(ARRAY['练气','筑基','金丹','元婴','出窍','化神'])[m.realm+1];END IF;
PERFORM public.fc_inventory_take(c.id,key,10);UPDATE public.fc_family_manuals SET traits=jsonb_set(traits,ARRAY[p_trait::text],public.fc_random_family_trait(m.realm)) WHERE id=m.id;
ELSE RAISE EXCEPTION '操作无效';END IF;RETURN public.fc_get_family_manuals();END $$;
REVOKE ALL ON FUNCTION public.fc_get_family_manuals(),public.fc_family_manual_action(uuid,text,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.fc_get_family_manuals(),public.fc_family_manual_action(uuid,text,integer) TO authenticated;

-- Do not destroy old items: legacy consumables become realm-zero versions.
UPDATE public.fc_inventory_slots SET item_key=item_key||'_0',item_name='练气'||CASE item_key WHEN 'expansion_pill' THEN '扩脉丹' WHEN 'breakthrough_pill' THEN '突破丹' ELSE item_name END WHERE item_key IN ('expansion_pill','spirit_pill','life_pill','lure_pill','breakthrough_pill','battle_pill','mana_pill','health_pill','fire_talisman','thunder_talisman');
UPDATE public.fc_recipes SET active=false WHERE profession='author' OR output_key IN ('expansion_pill','spirit_pill','life_pill','lure_pill','breakthrough_pill','battle_pill','mana_pill','health_pill','fire_talisman','thunder_talisman','star_platform','acupoint_chart');
UPDATE public.fc_recipes SET profession='smith',output_quantity=10,description='1根竹子加工10份练气纸材纤维，成功率100%。' WHERE id='bamboo_fiber';
UPDATE public.fc_recipes SET spirit_cost=0 WHERE output_key='talisman_paper';

DO $$ DECLARE r public.fc_recipes;i integer;names text[]:=ARRAY['练气','筑基','金丹','元婴','出窍','化神'];parts jsonb;part record;item text; BEGIN
FOR r IN SELECT * FROM public.fc_recipes WHERE output_key IN ('expansion_pill','spirit_pill','life_pill','lure_pill','breakthrough_pill','battle_pill','mana_pill','health_pill','fire_talisman','thunder_talisman') LOOP
FOR i IN 0..5 LOOP parts:='{}';FOR part IN SELECT key,value FROM jsonb_each(r.ingredients) LOOP item:=CASE WHEN part.key ~ '^(herb|blood|ore)_[0-5]$' THEN regexp_replace(part.key,'[0-5]$',i::text) ELSE part.key END;parts:=parts||jsonb_build_object(item,part.value);END LOOP;
INSERT INTO public.fc_recipes(id,name,profession,realm_min,spirit_cost,ingredients,output_key,output_name,output_category,description,success_rate,output_quantity)
VALUES(r.id||'_r'||i,names[i+1]||CASE r.output_key WHEN 'expansion_pill' THEN '扩脉丹' WHEN 'breakthrough_pill' THEN '突破丹' ELSE r.output_name END,r.profession,i,r.spirit_cost*(2^i)::integer,parts,r.output_key||'_'||i,names[i+1]||CASE r.output_key WHEN 'expansion_pill' THEN '扩脉丹' WHEN 'breakthrough_pill' THEN '突破丹' ELSE r.output_name END,r.output_category,'仅对应境界可用。'||r.description,r.success_rate,r.output_quantity);
END LOOP;END LOOP;
FOR i IN 0..5 LOOP
INSERT INTO public.fc_recipes(id,name,profession,realm_min,spirit_cost,ingredients,output_key,output_name,output_category,description,success_rate) VALUES
('star_platform_r'||i,names[i+1]||'观星台','smith',i,10*(3^i)::integer,jsonb_build_object('ore_'||i,10,'hide_'||i,4,'blood_'||i,2),'star_platform_'||i,names[i+1]||'观星台','工具','对应境界家族功法、战技和神通创作条件，可重复使用。',80),
('family_mind_r'||i,'创作'||names[i+1]||'家族功法','author',i,(ARRAY[30,90,270,810,2430,7290])[i+1],jsonb_build_object('hide_'||i,6,'blood_'||i,4,'herb_'||i,6),'family_mind_'||i,names[i+1]||'家族功法','功法','修炼倍率'||(ARRAY[12,12,16,16,20,20])[i+1]||'；修满随机获得'||(i+1)||'个可重复词条。',65),
('family_art_r'||i,'创作'||names[i+1]||'家族战技','author',i,(ARRAY[40,120,360,1080,3240,9720])[i+1],jsonb_build_object('hide_'||i,8,'blood_'||i,6,'ore_'||i,4),'family_art_'||i,names[i+1]||'家族战技','功法','伤害低于Boss传承，强于无名战技，具有回神或节流等特殊效果。',65);
IF i>=2 THEN INSERT INTO public.fc_recipes(id,name,profession,realm_min,spirit_cost,ingredients,output_key,output_name,output_category,description,success_rate) VALUES('family_ability_r'||i,'创作'||names[i+1]||'家族神通','author',i,(ARRAY[0,0,540,1620,4860,14580])[i+1],jsonb_build_object('hide_'||i,12,'blood_'||i,10,'herb_'||i,10,'ore_'||i,6),'family_ability_'||i,names[i+1]||'家族神通','功法','伤害较低，不享受突破神通跨阶保护，具有灵力循环或护盾等特殊效果。',65);END IF;
END LOOP;END $$;
INSERT INTO public.fc_skill_definitions(id,name,category,description,enhanced_description,effects,enhanced_effects,source,realm_required) VALUES
('family_art_0','练气家族守山战技','art','伤害350%，最多3目标，护盾10%；命中恢复神识上限2%。','伤害350%，最多3目标，护盾10%；命中恢复神识上限2%。','{"damage": 3.5, "targets": 3, "cooldown": 12, "cost": 0.12, "shield": 0.1, "spirit_restore": 0.02, "mana_restore": 0}','{"damage": 3.5, "targets": 3, "cooldown": 12, "cost": 0.12, "shield": 0.1, "spirit_restore": 0.02, "mana_restore": 0}','family',0),
('boss_art_0','练气Boss传承·镇岳斩','art','伤害450%，最多3目标，护盾10%；Boss专属传承。','伤害450%，最多3目标，护盾10%；Boss专属传承。','{"damage": 4.5, "targets": 3, "cooldown": 12, "cost": 0.12, "shield": 0.1, "spirit_restore": 0, "mana_restore": 0}','{"damage": 4.5, "targets": 3, "cooldown": 12, "cost": 0.12, "shield": 0.1, "spirit_restore": 0, "mana_restore": 0}','boss',0),
('family_art_1','筑基家族守山战技','art','伤害350%，最多3目标，护盾10%；命中恢复神识上限2%。','伤害350%，最多3目标，护盾10%；命中恢复神识上限2%。','{"damage": 3.5, "targets": 3, "cooldown": 12, "cost": 0.12, "shield": 0.1, "spirit_restore": 0.02, "mana_restore": 0}','{"damage": 3.5, "targets": 3, "cooldown": 12, "cost": 0.12, "shield": 0.1, "spirit_restore": 0.02, "mana_restore": 0}','family',1),
('boss_art_1','筑基Boss传承·镇岳斩','art','伤害450%，最多3目标，护盾10%；Boss专属传承。','伤害450%，最多3目标，护盾10%；Boss专属传承。','{"damage": 4.5, "targets": 3, "cooldown": 12, "cost": 0.12, "shield": 0.1, "spirit_restore": 0, "mana_restore": 0}','{"damage": 4.5, "targets": 3, "cooldown": 12, "cost": 0.12, "shield": 0.1, "spirit_restore": 0, "mana_restore": 0}','boss',1),
('family_art_2','金丹家族守山战技','art','伤害350%，最多3目标，护盾10%；命中恢复神识上限2%。','伤害350%，最多3目标，护盾10%；命中恢复神识上限2%。','{"damage": 3.5, "targets": 3, "cooldown": 12, "cost": 0.12, "shield": 0.1, "spirit_restore": 0.02, "mana_restore": 0}','{"damage": 3.5, "targets": 3, "cooldown": 12, "cost": 0.12, "shield": 0.1, "spirit_restore": 0.02, "mana_restore": 0}','family',2),
('boss_art_2','金丹Boss传承·镇岳斩','art','伤害450%，最多3目标，护盾10%；Boss专属传承。','伤害450%，最多3目标，护盾10%；Boss专属传承。','{"damage": 4.5, "targets": 3, "cooldown": 12, "cost": 0.12, "shield": 0.1, "spirit_restore": 0, "mana_restore": 0}','{"damage": 4.5, "targets": 3, "cooldown": 12, "cost": 0.12, "shield": 0.1, "spirit_restore": 0, "mana_restore": 0}','boss',2),
('family_ability_2','金丹家族神通·归元护族','ability','伤害550%，最多3目标，护盾20%；命中恢复神识上限2%。','伤害550%，最多3目标，护盾20%；命中恢复神识上限2%。','{"damage": 5.5, "targets": 3, "cooldown": 30, "cost": 0.2, "shield": 0.2, "spirit_restore": 0.02, "mana_restore": 0.03}','{"damage": 5.5, "targets": 3, "cooldown": 30, "cost": 0.2, "shield": 0.2, "spirit_restore": 0.02, "mana_restore": 0.03}','family',2),
('family_art_3','元婴家族守山战技','art','伤害350%，最多3目标，护盾10%；命中恢复神识上限2%。','伤害350%，最多3目标，护盾10%；命中恢复神识上限2%。','{"damage": 3.5, "targets": 3, "cooldown": 12, "cost": 0.12, "shield": 0.1, "spirit_restore": 0.02, "mana_restore": 0}','{"damage": 3.5, "targets": 3, "cooldown": 12, "cost": 0.12, "shield": 0.1, "spirit_restore": 0.02, "mana_restore": 0}','family',3),
('boss_art_3','元婴Boss传承·镇岳斩','art','伤害450%，最多3目标，护盾10%；Boss专属传承。','伤害450%，最多3目标，护盾10%；Boss专属传承。','{"damage": 4.5, "targets": 3, "cooldown": 12, "cost": 0.12, "shield": 0.1, "spirit_restore": 0, "mana_restore": 0}','{"damage": 4.5, "targets": 3, "cooldown": 12, "cost": 0.12, "shield": 0.1, "spirit_restore": 0, "mana_restore": 0}','boss',3),
('family_ability_3','元婴家族神通·归元护族','ability','伤害550%，最多3目标，护盾20%；命中恢复神识上限2%。','伤害550%，最多3目标，护盾20%；命中恢复神识上限2%。','{"damage": 5.5, "targets": 3, "cooldown": 30, "cost": 0.2, "shield": 0.2, "spirit_restore": 0.02, "mana_restore": 0.03}','{"damage": 5.5, "targets": 3, "cooldown": 30, "cost": 0.2, "shield": 0.2, "spirit_restore": 0.02, "mana_restore": 0.03}','family',3),
('family_art_4','出窍家族守山战技','art','伤害350%，最多3目标，护盾10%；命中恢复神识上限2%。','伤害350%，最多3目标，护盾10%；命中恢复神识上限2%。','{"damage": 3.5, "targets": 3, "cooldown": 12, "cost": 0.12, "shield": 0.1, "spirit_restore": 0.02, "mana_restore": 0}','{"damage": 3.5, "targets": 3, "cooldown": 12, "cost": 0.12, "shield": 0.1, "spirit_restore": 0.02, "mana_restore": 0}','family',4),
('boss_art_4','出窍Boss传承·镇岳斩','art','伤害450%，最多3目标，护盾10%；Boss专属传承。','伤害450%，最多3目标，护盾10%；Boss专属传承。','{"damage": 4.5, "targets": 3, "cooldown": 12, "cost": 0.12, "shield": 0.1, "spirit_restore": 0, "mana_restore": 0}','{"damage": 4.5, "targets": 3, "cooldown": 12, "cost": 0.12, "shield": 0.1, "spirit_restore": 0, "mana_restore": 0}','boss',4),
('family_ability_4','出窍家族神通·归元护族','ability','伤害550%，最多3目标，护盾20%；命中恢复神识上限2%。','伤害550%，最多3目标，护盾20%；命中恢复神识上限2%。','{"damage": 5.5, "targets": 3, "cooldown": 30, "cost": 0.2, "shield": 0.2, "spirit_restore": 0.02, "mana_restore": 0.03}','{"damage": 5.5, "targets": 3, "cooldown": 30, "cost": 0.2, "shield": 0.2, "spirit_restore": 0.02, "mana_restore": 0.03}','family',4),
('family_art_5','化神家族守山战技','art','伤害350%，最多3目标，护盾10%；命中恢复神识上限2%。','伤害350%，最多3目标，护盾10%；命中恢复神识上限2%。','{"damage": 3.5, "targets": 3, "cooldown": 12, "cost": 0.12, "shield": 0.1, "spirit_restore": 0.02, "mana_restore": 0}','{"damage": 3.5, "targets": 3, "cooldown": 12, "cost": 0.12, "shield": 0.1, "spirit_restore": 0.02, "mana_restore": 0}','family',5),
('boss_art_5','化神Boss传承·镇岳斩','art','伤害450%，最多3目标，护盾10%；Boss专属传承。','伤害450%，最多3目标，护盾10%；Boss专属传承。','{"damage": 4.5, "targets": 3, "cooldown": 12, "cost": 0.12, "shield": 0.1, "spirit_restore": 0, "mana_restore": 0}','{"damage": 4.5, "targets": 3, "cooldown": 12, "cost": 0.12, "shield": 0.1, "spirit_restore": 0, "mana_restore": 0}','boss',5),
('family_ability_5','化神家族神通·归元护族','ability','伤害550%，最多3目标，护盾20%；命中恢复神识上限2%。','伤害550%，最多3目标，护盾20%；命中恢复神识上限2%。','{"damage": 5.5, "targets": 3, "cooldown": 30, "cost": 0.2, "shield": 0.2, "spirit_restore": 0.02, "mana_restore": 0.03}','{"damage": 5.5, "targets": 3, "cooldown": 30, "cost": 0.2, "shield": 0.2, "spirit_restore": 0.02, "mana_restore": 0.03}','family',5);
CREATE OR REPLACE FUNCTION public.fc_craft(p_recipe text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE c public.fc_characters; recipe public.fc_recipes; part record; chance numeric; success boolean; free integer; eid uuid; eq public.fc_equipment_definitions; output text; authored text;
BEGIN
 PERFORM public.fc_recover_attributes(); SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE;
 SELECT * INTO recipe FROM public.fc_recipes WHERE id=p_recipe; IF recipe.id IS NULL OR NOT recipe.active THEN RAISE EXCEPTION '配方不存在'; END IF;
 IF recipe.profession='alchemy' AND NOT EXISTS(SELECT 1 FROM public.fc_inventory_slots WHERE character_id=c.id AND item_key='alchemy_furnace') THEN RAISE EXCEPTION '炼丹需要先制作炉鼎'; END IF;
 IF recipe.profession='smith' AND recipe.id NOT IN ('forge_anvil','forge_hammer','forge_furnace','farm_hoe','bamboo_fiber') AND (NOT EXISTS(SELECT 1 FROM public.fc_inventory_slots WHERE character_id=c.id AND item_key='smith_anvil') OR NOT EXISTS(SELECT 1 FROM public.fc_inventory_slots WHERE character_id=c.id AND item_key='smith_hammer')) THEN RAISE EXCEPTION '炼器需要铁砧与铁锤'; END IF;
 IF c.realm_index<recipe.realm_min THEN RAISE EXCEPTION '境界不足'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.fc_character_positions p JOIN public.fc_world_cells cell ON cell.id=p.cell_id JOIN public.fc_world_rooms r ON r.id=cell.room_id WHERE p.character_id=c.id AND r.family_id=c.family_id AND r.template_id=CASE recipe.profession WHEN 'smith' THEN '10000000-0000-0000-0000-000000000017'::uuid WHEN 'alchemy' THEN '10000000-0000-0000-0000-000000000016'::uuid WHEN 'talisman' THEN '10000000-0000-0000-0000-000000000018'::uuid ELSE '10000000-0000-0000-0000-000000000015'::uuid END) THEN RAISE EXCEPTION '请先前往对应本族炼器房、炼丹房、符纸房或练功房'; END IF;
 IF EXISTS(SELECT 1 FROM public.fc_combat_encounters WHERE character_id=c.id AND status='active') THEN RAISE EXCEPTION '战斗中无法制作'; END IF;
 IF c.consciousness<recipe.spirit_cost THEN RAISE EXCEPTION '神识不足'; END IF;
 IF recipe.profession='author' THEN
  IF c.realm_index<>recipe.realm_min THEN RAISE EXCEPTION '只能创作当前境界的家族项目';END IF;IF NOT EXISTS(SELECT 1 FROM public.fc_inventory_slots WHERE character_id=c.id AND item_key='star_platform_'||recipe.realm_min) THEN RAISE EXCEPTION '需要对应境界观星台';END IF;
  IF c.authored_day=current_date AND c.authored_count>=10 THEN RAISE EXCEPTION '每天最多创作十本功法'; END IF;
 END IF;
 FOR part IN SELECT key,value::integer AS quantity FROM jsonb_each_text(recipe.ingredients) LOOP
  IF (SELECT coalesce(sum(quantity),0) FROM public.fc_inventory_slots WHERE character_id=c.id AND item_key=part.key AND equipment_id IS NULL)<part.quantity THEN RAISE EXCEPTION '缺少材料：%',part.key; END IF;
 END LOOP;
 IF (SELECT count(*) FROM public.fc_inventory_slots WHERE character_id=c.id)>=200 THEN RAISE EXCEPTION '请预留一格成品空间'; END IF;
 FOR part IN SELECT key,value::integer AS quantity FROM jsonb_each_text(recipe.ingredients) LOOP PERFORM public.fc_inventory_take(c.id,part.key,part.quantity); END LOOP;
 chance:=least(95,recipe.success_rate+coalesce((public.fc_family_traits(c.id)->>recipe.profession)::numeric,0)*100+(public.fc_mind_effects(c.mind)->>'craft_bonus')::numeric+least(5,coalesce((c.profession_levels->>recipe.profession)::integer,1)-1));
 IF recipe.profession='author' THEN chance:=least(95,chance+least(5,coalesce((c.profession_levels->>'astrology')::integer,1)+coalesce((c.profession_levels->>'medicine')::integer,1)-2)); END IF;
 IF recipe.id IN ('farm_hoe','bamboo_fiber') THEN chance:=100;END IF;success:=random()*100<chance;
 UPDATE public.fc_characters SET consciousness=consciousness-recipe.spirit_cost,profession_levels=jsonb_set(profession_levels,ARRAY[recipe.profession],to_jsonb(coalesce((profession_levels->>recipe.profession)::integer,1)+1)),authored_count=CASE WHEN recipe.profession='author' THEN CASE WHEN authored_day=current_date THEN authored_count+1 ELSE 1 END ELSE authored_count END,authored_day=CASE WHEN recipe.profession='author' THEN current_date ELSE authored_day END WHERE id=c.id;
 IF success THEN
  SELECT * INTO eq FROM public.fc_equipment_definitions WHERE item_key=recipe.output_key;
  IF eq.item_key IS NOT NULL THEN
   SELECT n INTO free FROM generate_series(1,200) n WHERE NOT EXISTS(SELECT 1 FROM public.fc_inventory_slots WHERE character_id=c.id AND slot=n) ORDER BY n LIMIT 1;
   INSERT INTO public.fc_equipment_instances(character_id,item_key) VALUES(c.id,eq.item_key) RETURNING id INTO eid;
   INSERT INTO public.fc_inventory_slots(character_id,slot,item_key,item_name,quantity,category,description,equipment_id) VALUES(c.id,free,eq.item_key,eq.name,1,'装备',eq.description,eid);
  ELSE
   output:=recipe.output_key;
   IF recipe.profession='author' AND output LIKE 'family_mind_%' THEN INSERT INTO public.fc_family_manuals(character_id,realm,name) VALUES(c.id,recipe.realm_min,recipe.output_name);RETURN jsonb_build_object('message','创作成功，已存入神仙妙法·功法','success',true,'chance',chance,'workshop',public.fc_get_workshop());END IF;
   IF recipe.profession='author' AND output='authored_manual' THEN
    authored:=CASE WHEN c.mind>=80 AND coalesce((c.profession_levels->>'astrology')::integer,1)>=3 AND coalesce((c.profession_levels->>'medicine')::integer,1)>=3 THEN 'family_mind' ELSE 'nameless_mind' END;
    output:='book_'||authored;
   END IF;
   PERFORM public.fc_inventory_add(c.id,output,CASE WHEN authored IS NOT NULL THEN (SELECT name FROM public.fc_manual_definitions WHERE id=authored)||'手稿' ELSE recipe.output_name END,recipe.output_quantity,recipe.output_category,recipe.description);
  END IF;
 END IF;
 RETURN jsonb_build_object('message',CASE WHEN success THEN '制作成功：'||recipe.output_name ELSE '制作失败，材料及神识已消耗。' END,'success',success,'chance',chance,'workshop',public.fc_get_workshop());
END $function$;
CREATE OR REPLACE FUNCTION public.fc_get_workshop()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE c public.fc_characters;
BEGIN
 PERFORM public.fc_recover_attributes(); SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid();
 IF c.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 RETURN jsonb_build_object('realm_index',c.realm_index,'consciousness',c.consciousness,'skills',c.profession_levels,'craft_bonus',(public.fc_mind_effects(c.mind)->>'craft_bonus')::numeric,'recipes',(SELECT jsonb_agg(to_jsonb(r) ORDER BY realm_min,name) FROM public.fc_recipes r WHERE r.active),'inventory',public.fc_get_inventory());
END $function$;
CREATE OR REPLACE FUNCTION public.fc_consume_item_internal(p_key text,p_inventory_key text DEFAULT NULL,p_item_realm integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE c public.fc_characters; s jsonb; e public.fc_combat_encounters; cap numeric; mid text;
BEGIN
 SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE; IF c.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 s:=public.fc_get_attributes(); SELECT * INTO e FROM public.fc_combat_encounters WHERE character_id=c.id AND status='active' LIMIT 1 FOR UPDATE;
 IF p_key='expansion_pill' THEN
  IF c.capacity>=150 THEN RAISE EXCEPTION '丹田容量已达完美圆满'; END IF;
  PERFORM public.fc_claim_cultivation(); PERFORM public.fc_inventory_take(c.id,coalesce(p_inventory_key,p_key),1); UPDATE public.fc_characters SET capacity=least(150,capacity+5) WHERE id=c.id;
 ELSIF p_key='spirit_pill' THEN
  PERFORM public.fc_inventory_take(c.id,coalesce(p_inventory_key,p_key),1); UPDATE public.fc_characters SET consciousness=least((s->>'consciousness_max')::numeric,consciousness+(s->>'consciousness_max')::numeric*0.3) WHERE id=c.id;
 ELSIF p_key='life_pill' THEN
  IF c.pill_day=current_date AND coalesce((c.daily_pills->>'life')::integer,0)>=1 THEN RAISE EXCEPTION '延寿丹每日最多一次'; END IF;
  cap:=(ARRAY[100,200,500,1000,2000,4000])[c.realm_index+1]; IF c.lifespan>=cap THEN RAISE EXCEPTION '已达当前境界寿元上限'; END IF;
  PERFORM public.fc_inventory_take(c.id,coalesce(p_inventory_key,p_key),1); UPDATE public.fc_characters SET lifespan=least(cap,lifespan+(ARRAY[5,10,20,40,80,160])[p_item_realm+1]),pill_day=current_date,daily_pills=jsonb_build_object('life',1) WHERE id=c.id;
 ELSIF p_key='lure_pill' THEN
  IF NOT EXISTS(SELECT 1 FROM public.fc_character_positions p JOIN public.fc_world_cells cell ON cell.id=p.cell_id JOIN public.fc_world_rooms r ON r.id=cell.room_id WHERE p.character_id=c.id AND NOT r.is_safe_city) OR EXISTS(SELECT 1 FROM public.fc_city_journeys WHERE character_id=c.id) THEN RAISE EXCEPTION '聚妖丹只能在野外或官道使用'; END IF;
  PERFORM public.fc_inventory_take(c.id,coalesce(p_inventory_key,p_key),1); UPDATE public.fc_characters SET lure_room=(SELECT cell.room_id FROM public.fc_character_positions p JOIN public.fc_world_cells cell ON cell.id=p.cell_id WHERE p.character_id=c.id) WHERE id=c.id;
 ELSIF p_key IN ('battle_pill','breakthrough_pill') THEN
  IF p_key='breakthrough_pill' AND c.breakthrough_boost_until>now() OR p_key='battle_pill' AND c.battle_boost_until>now() THEN RAISE EXCEPTION '丹药效果仍在生效'; END IF;
  PERFORM public.fc_inventory_take(c.id,coalesce(p_inventory_key,p_key),1); UPDATE public.fc_characters SET battle_boost_until=CASE WHEN p_key='battle_pill' THEN now()+interval '10 minutes' ELSE battle_boost_until END,breakthrough_boost_until=CASE WHEN p_key='breakthrough_pill' THEN now()+interval '1 hour' ELSE breakthrough_boost_until END WHERE id=c.id;
 ELSIF p_key IN ('health_pill','mana_pill','fire_talisman','thunder_talisman') THEN
  IF e.id IS NULL THEN RAISE EXCEPTION '此物品需要在战斗中使用'; END IF;
  IF p_key IN ('fire_talisman','thunder_talisman') AND e.player_mana<(s->>'mana')::numeric*0.05 THEN RAISE EXCEPTION '灵力不足'; END IF;
  IF p_key IN ('fire_talisman','thunder_talisman') AND e.item_at>now()-interval '8 seconds' THEN RAISE EXCEPTION '符箓冷却8秒'; END IF;
  PERFORM public.fc_inventory_take(c.id,coalesce(p_inventory_key,p_key),1);
  UPDATE public.fc_combat_encounters SET player_health=CASE WHEN p_key='health_pill' THEN least((s->>'health')::numeric,player_health+(s->>'health')::numeric*0.35) ELSE player_health END,player_mana=CASE WHEN p_key='mana_pill' THEN least((s->>'mana')::numeric,player_mana+(s->>'mana')::numeric*0.4) WHEN p_key IN ('fire_talisman','thunder_talisman') THEN player_mana-(s->>'mana')::numeric*0.05 ELSE player_mana END,monster_health=CASE WHEN p_key='fire_talisman' THEN monster_health-(s->>'attack')::numeric*3 WHEN p_key='thunder_talisman' THEN monster_health-(s->>'attack')::numeric*2.5 ELSE monster_health END,stunned_until=CASE WHEN p_key='thunder_talisman' THEN now()+interval '1 second' ELSE stunned_until END,item_at=now(),battle_log=battle_log||jsonb_build_array('使用了'||p_key) WHERE id=e.id;
 ELSIF p_key LIKE 'book_%' THEN
  mid:=substring(p_key FROM 6); IF NOT EXISTS(SELECT 1 FROM public.fc_manual_definitions WHERE id=mid) THEN RAISE EXCEPTION '无法学习该功法'; END IF;
  IF EXISTS(SELECT 1 FROM public.fc_known_manuals WHERE character_id=c.id AND manual_id=mid) THEN RAISE EXCEPTION '已经学会此功法'; END IF;
  PERFORM public.fc_inventory_take(c.id,coalesce(p_inventory_key,p_key),1); INSERT INTO public.fc_known_manuals(character_id,manual_id) VALUES(c.id,mid);
 ELSE RAISE EXCEPTION '该物品不可直接使用'; END IF;
 RETURN jsonb_build_object('message','使用成功','inventory',public.fc_get_inventory());
END $function$;
REVOKE ALL ON FUNCTION public.fc_consume_item_internal(text,text,integer) FROM PUBLIC,authenticated,anon;

CREATE OR REPLACE FUNCTION public.fc_consume_item(p_key text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters;base_key text;realm integer;d public.fc_skill_definitions;
BEGIN SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE;
IF p_key ~ '^(expansion_pill|spirit_pill|life_pill|lure_pill|breakthrough_pill|battle_pill|mana_pill|health_pill|fire_talisman|thunder_talisman)_[0-5]$' THEN
realm:=right(p_key,1)::integer;base_key:=left(p_key,length(p_key)-2);IF c.realm_index<>realm THEN RAISE EXCEPTION '丹药或符箓必须与当前境界相同';END IF;
RETURN public.fc_consume_item_internal(base_key,p_key,realm);
ELSIF p_key ~ '^(family_art|family_ability|boss_crystal)_[0-5]$' THEN
realm:=right(p_key,1)::integer;IF c.realm_index<realm THEN RAISE EXCEPTION '境界不足';END IF;
base_key:=CASE WHEN p_key LIKE 'boss_crystal_%' THEN 'boss_art_'||realm ELSE p_key END;
SELECT * INTO d FROM public.fc_skill_definitions WHERE id=base_key;
IF d.id IS NULL THEN RAISE EXCEPTION '传承未开放';END IF;
IF EXISTS(SELECT 1 FROM public.fc_known_skills WHERE character_id=c.id AND skill_id=d.id) THEN RAISE EXCEPTION '已经领悟该战技或神通';END IF;
PERFORM public.fc_inventory_take(c.id,p_key,1);INSERT INTO public.fc_known_skills(character_id,skill_id,enhanced,learned_realm) VALUES(c.id,d.id,false,realm);
RETURN jsonb_build_object('message','领悟成功，已存入神仙妙法','inventory',public.fc_get_inventory());
ELSIF p_key IN ('expansion_pill','spirit_pill','life_pill','lure_pill','breakthrough_pill','battle_pill','mana_pill','health_pill','fire_talisman','thunder_talisman') THEN RAISE EXCEPTION '请使用对应境界版本';
END IF;RETURN public.fc_consume_item_internal(p_key,p_key,0);END $$;

CREATE OR REPLACE FUNCTION public.fc_manual_rate(c public.fc_characters) RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
SELECT coalesce((SELECT (ARRAY[12,12,16,16,20,20])[m.realm+1]*(1+coalesce((public.fc_family_traits(c.id)->>'cultivation')::numeric,0)) FROM public.fc_family_manuals m WHERE m.id=c.equipped_family_manual AND m.character_id=c.id AND m.realm=c.realm_index),CASE WHEN c.equipped_mind='nameless_mind' AND c.realm_index<2 THEN 10 WHEN c.equipped_mind='family_mind' THEN (ARRAY[12,12,16,16,20,20])[c.realm_index+1] ELSE 1 END) $$;
CREATE FUNCTION public.fc_apply_family_traits(p_character uuid,p_stats jsonb) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE t jsonb:=public.fc_family_traits(p_character);c public.fc_characters;base jsonb;s jsonb:=p_stats;k text;
BEGIN SELECT * INTO c FROM public.fc_characters WHERE id=p_character;base:=public.fc_base_stats(c.realm_index,c.realm_layer,1);
FOREACH k IN ARRAY ARRAY['health','mana','attack','defense','speed','consciousness_max'] LOOP s:=jsonb_set(s,ARRAY[k],to_jsonb(round((s->>k)::numeric+(base->>k)::numeric*coalesce((t->>k)::numeric,0),2)));END LOOP;RETURN s;END $$;
REVOKE ALL ON FUNCTION public.fc_apply_family_traits(uuid,jsonb) FROM PUBLIC,authenticated,anon;
CREATE OR REPLACE FUNCTION public.fc_manual_health(c fc_characters)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
 SELECT CASE WHEN EXISTS(SELECT 1 FROM public.fc_family_manuals WHERE id=c.equipped_family_manual AND realm=c.realm_index) THEN 0 WHEN EXISTS(SELECT 1 FROM public.fc_known_manuals WHERE character_id=c.id AND manual_id=c.equipped_mind AND progress=100) THEN CASE c.equipped_mind WHEN 'family_mind' THEN 0.4 WHEN 'nameless_mind' THEN 0.3 ELSE 0 END ELSE 0 END
$function$;
CREATE OR REPLACE FUNCTION public.fc_get_attributes()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE c public.fc_characters; s jsonb; k text; power numeric;
BEGIN
 PERFORM public.fc_recover_attributes(); SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid();
 s:=public.fc_base_stats(c.realm_index,c.realm_layer,c.realm_grade);
 FOREACH k IN ARRAY ARRAY['health','mana','attack','defense','speed','consciousness_max'] LOOP s:=jsonb_set(s,ARRAY[k],to_jsonb(round((s->>k)::numeric+coalesce((c.expansion_stats->>k)::numeric,0)+coalesce((c.legacy_grade_stats->>k)::numeric,0)+coalesce((public.fc_equipment_stats(c.id)->>k)::numeric,0),2))); END LOOP;
 s:=public.fc_apply_family_traits(c.id,s);
 s:=jsonb_set(s,ARRAY['health'],to_jsonb(round((s->>'health')::numeric*(1+public.fc_manual_health(c)),2)));
 power:=round((s->>'health')::numeric*0.2+(s->>'mana')::numeric*0.1+(s->>'attack')::numeric*5+(s->>'defense')::numeric*3+(s->>'speed')::numeric*2);
 RETURN s||jsonb_build_object('aura_required',public.fc_aura_requirement(c.realm_index,c.realm_layer),'aura_points',round(c.cultivation/100*public.fc_aura_requirement(c.realm_index,c.realm_layer),2),'aura_limit',c.capacity/100*public.fc_aura_requirement(c.realm_index,c.realm_layer),'aura_rate',public.fc_aura_rate(c.realm_index),'power',power,'mind',c.mind,'consciousness',round(c.consciousness,2),'effects',public.fc_mind_effects(c.mind),'expansion_stats',c.expansion_stats);
END $function$;
CREATE OR REPLACE FUNCTION public.fc_recover_attributes()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE c public.fc_characters; elapsed numeric; max_spirit numeric; effects jsonb; hours integer; gain integer;
BEGIN
 SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE; IF c.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 elapsed:=least(720,greatest(0,extract(epoch FROM(now()-c.recovery_at))/60));
 max_spirit:=(public.fc_base_stats(c.realm_index,c.realm_layer,c.realm_grade)->>'consciousness_max')::numeric+coalesce((c.expansion_stats->>'consciousness_max')::numeric,0)+coalesce((c.legacy_grade_stats->>'consciousness_max')::numeric,0)+coalesce((public.fc_equipment_stats(c.id)->>'consciousness_max')::numeric,0);
 max_spirit:=max_spirit+(public.fc_base_stats(c.realm_index,c.realm_layer,1)->>'consciousness_max')::numeric*coalesce((public.fc_family_traits(c.id)->>'consciousness_max')::numeric,0);
 effects:=public.fc_mind_effects(c.mind);
 UPDATE public.fc_characters SET consciousness=least(max_spirit,consciousness+elapsed*max_spirit*0.01*(effects->>'recovery')::numeric*(1+coalesce((public.fc_family_traits(c.id)->>'recovery')::numeric,0))),recovery_at=now() WHERE id=c.id;
END $function$;

CREATE OR REPLACE FUNCTION public.fc_character_power(c public.fc_characters) RETURNS numeric LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
SELECT round((s->>'health')::numeric*.2+(s->>'mana')::numeric*.1+(s->>'attack')::numeric*5+(s->>'defense')::numeric*3+(s->>'speed')::numeric*2) FROM (SELECT public.fc_apply_family_traits(c.id,jsonb_build_object('health',((b->>'health')::numeric+coalesce((c.expansion_stats->>'health')::numeric,0)+coalesce((c.legacy_grade_stats->>'health')::numeric,0)+coalesce((e->>'health')::numeric,0))*(1+public.fc_manual_health(c)),'mana',(b->>'mana')::numeric+coalesce((c.expansion_stats->>'mana')::numeric,0)+coalesce((c.legacy_grade_stats->>'mana')::numeric,0)+coalesce((e->>'mana')::numeric,0),'attack',(b->>'attack')::numeric+coalesce((c.expansion_stats->>'attack')::numeric,0)+coalesce((c.legacy_grade_stats->>'attack')::numeric,0)+coalesce((e->>'attack')::numeric,0),'defense',(b->>'defense')::numeric+coalesce((c.expansion_stats->>'defense')::numeric,0)+coalesce((c.legacy_grade_stats->>'defense')::numeric,0)+coalesce((e->>'defense')::numeric,0),'speed',(b->>'speed')::numeric+coalesce((c.expansion_stats->>'speed')::numeric,0)+coalesce((c.legacy_grade_stats->>'speed')::numeric,0)+coalesce((e->>'speed')::numeric,0))) AS s FROM public.fc_base_stats(c.realm_index,c.realm_layer,1)b,public.fc_equipment_stats(c.id)e) q $$;

CREATE FUNCTION public.fc_progress_family_manual() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE m public.fc_family_manuals;minutes integer;i integer;t jsonb;
BEGIN
IF NEW.equipped_family_manual IS NOT NULL AND OLD.cultivating AND NEW.last_claim_at>OLD.last_claim_at THEN
SELECT * INTO m FROM public.fc_family_manuals WHERE id=NEW.equipped_family_manual AND character_id=NEW.id AND realm=NEW.realm_index FOR UPDATE;
IF m.id IS NOT NULL AND m.progress<100 THEN minutes:=floor(extract(epoch FROM NEW.last_claim_at-OLD.last_claim_at)/60);IF minutes>=5 THEN t:=m.traits;IF m.progress+minutes/5>=100 THEN t:='[]';FOR i IN 1..m.realm+1 LOOP t:=t||jsonb_build_array(public.fc_random_family_trait(m.realm));END LOOP;END IF;UPDATE public.fc_family_manuals SET progress=least(100,progress+minutes/5),traits=t WHERE id=m.id;END IF;END IF;
END IF;RETURN NEW;END $$;
CREATE TRIGGER progress_family_manual AFTER UPDATE OF last_claim_at ON public.fc_characters FOR EACH ROW EXECUTE FUNCTION public.fc_progress_family_manual();
REVOKE ALL ON FUNCTION public.fc_progress_family_manual() FROM PUBLIC,authenticated,anon;
CREATE OR REPLACE FUNCTION public.fc_generate_skill_choice(p_record uuid,p_character uuid,p_grade integer,p_realm integer) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE cards jsonb:='[]';d public.fc_skill_definitions;ability boolean;prob numeric; is_enhanced boolean:=p_grade=9;ids text[]:=ARRAY[]::text[];i integer;cat text;existing jsonb;
BEGIN
 SELECT candidates INTO existing FROM public.fc_skill_choices WHERE id=p_record;IF existing IS NOT NULL THEN RETURN existing;END IF;
 prob:=CASE p_grade WHEN 4 THEN .2 WHEN 5 THEN .4 WHEN 6 THEN .6 ELSE 0 END;ability:=p_grade>=7 OR random()<prob;
 FOR i IN 1..3 LOOP
 cat:=CASE WHEN p_grade>=7 OR ability AND i=1 THEN 'ability' ELSE 'art' END;
 SELECT * INTO d FROM public.fc_skill_definitions WHERE category=cat AND source='breakthrough' AND NOT(id=ANY(ids)) ORDER BY EXISTS(SELECT 1 FROM public.fc_known_skills k WHERE k.character_id=p_character AND k.skill_id=fc_skill_definitions.id AND (NOT is_enhanced OR k.enhanced)),random() LIMIT 1;
 ids:=array_append(ids,d.id);cards:=cards||jsonb_build_array(to_jsonb(d)||jsonb_build_object('enhanced',is_enhanced,'effects',CASE WHEN is_enhanced THEN d.enhanced_effects ELSE d.effects END,'description',CASE WHEN is_enhanced THEN d.enhanced_description ELSE d.description END));END LOOP;
 INSERT INTO public.fc_skill_choices(id,character_id,grade,realm,candidates) VALUES(p_record,p_character,p_grade,p_realm,cards);RETURN cards;END $$;
CREATE OR REPLACE FUNCTION public.fc_equip_manual(p_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE c public.fc_characters; d public.fc_manual_definitions;
BEGIN
 SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE;
 SELECT * INTO d FROM public.fc_manual_definitions WHERE id=p_id;
 IF NOT EXISTS(SELECT 1 FROM public.fc_known_manuals WHERE character_id=c.id AND manual_id=p_id) THEN RAISE EXCEPTION '尚未学会此功法'; END IF;
 IF c.realm_index NOT BETWEEN d.realm_min AND d.realm_max THEN RAISE EXCEPTION '此功法不适用于当前境界'; END IF;
 IF EXISTS(SELECT 1 FROM public.fc_combat_encounters WHERE character_id=c.id AND status='active') THEN RAISE EXCEPTION '战斗中不能更换功法'; END IF;
 PERFORM public.fc_claim_cultivation();
 UPDATE public.fc_characters SET equipped_family_manual=CASE WHEN d.category='mind' THEN NULL ELSE equipped_family_manual END,equipped_mind=CASE WHEN d.category='mind' THEN p_id ELSE equipped_mind END,equipped_art=CASE WHEN d.category='art' THEN p_id ELSE equipped_art END,equipped_spell=CASE WHEN d.category='spell' THEN p_id ELSE equipped_spell END,last_claim_at=now() WHERE id=c.id;
 RETURN public.fc_get_manuals();
END $function$;

CREATE OR REPLACE FUNCTION public.fc_use_expansion_pill(p_slot integer) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$ DECLARE c public.fc_characters;k text;BEGIN SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid();SELECT item_key INTO k FROM public.fc_inventory_slots WHERE character_id=c.id AND slot=p_slot;IF k IS DISTINCT FROM 'expansion_pill_'||c.realm_index THEN RAISE EXCEPTION '请使用对应境界扩脉丹';END IF;PERFORM public.fc_consume_item(k);RETURN public.fc_get_state();END $$;
