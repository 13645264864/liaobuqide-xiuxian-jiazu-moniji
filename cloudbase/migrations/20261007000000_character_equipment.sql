ALTER TABLE public.fc_characters ADD COLUMN equipment_starter_claimed boolean NOT NULL DEFAULT false;
ALTER TABLE public.fc_inventory_slots ADD COLUMN equipment_id uuid;
CREATE TABLE public.fc_equipment_definitions(item_key text PRIMARY KEY,name text NOT NULL,slot_type text NOT NULL,realm_required smallint NOT NULL,quality text NOT NULL,stats jsonb NOT NULL,description text NOT NULL);
CREATE TABLE public.fc_equipment_instances(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),character_id uuid NOT NULL REFERENCES public.fc_characters(id),item_key text NOT NULL REFERENCES public.fc_equipment_definitions(item_key),equipped_slot text,UNIQUE(character_id,equipped_slot),CHECK(equipped_slot IS NULL OR equipped_slot IN ('crown','clothes','pants','shoes','cloak','weapon','earring','necklace','belt','ring_left','ring_right','bracelet','anklet','pendant')));
ALTER TABLE public.fc_inventory_slots ADD CONSTRAINT inventory_equipment_fk FOREIGN KEY(equipment_id) REFERENCES public.fc_equipment_instances(id);
ALTER TABLE public.fc_equipment_definitions ENABLE ROW LEVEL SECURITY; ALTER TABLE public.fc_equipment_instances ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.fc_equipment_definitions,public.fc_equipment_instances FROM anon,authenticated;
INSERT INTO public.fc_equipment_definitions VALUES('sword_0','练气铁剑','weapon',0,'凡品','{"attack": 12}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('crown_0','练气头冠','crown',0,'凡品','{"health": 3.0, "defense": 0.4, "consciousness_max": 3.0}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('clothes_0','练气衣服','clothes',0,'凡品','{"health": 12.0, "defense": 1.2}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('pants_0','练气裤子','pants',0,'凡品','{"health": 6.0, "defense": 0.7}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('shoes_0','练气鞋子','shoes',0,'凡品','{"health": 3.0, "defense": 0.3, "speed": 0.8}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('ring_0','练气戒指','ring',0,'凡品','{"attack": 0.6, "mana": 5.0}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('sword_1','筑基灵剑','weapon',1,'凡品','{"attack": 60}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('crown_1','筑基头冠','crown',1,'凡品','{"health": 15.0, "defense": 2.0, "consciousness_max": 9.0}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('clothes_1','筑基衣服','clothes',1,'凡品','{"health": 60.0, "defense": 6.0}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('pants_1','筑基裤子','pants',1,'凡品','{"health": 30.0, "defense": 3.5}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('shoes_1','筑基鞋子','shoes',1,'凡品','{"health": 15.0, "defense": 1.5, "speed": 1.2}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('ring_1','筑基戒指','ring',1,'凡品','{"attack": 3.0, "mana": 15.0}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('sword_2','金丹灵剑','weapon',2,'凡品','{"attack": 300}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('crown_2','金丹头冠','crown',2,'凡品','{"health": 75.0, "defense": 10.0, "consciousness_max": 27.0}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('clothes_2','金丹衣服','clothes',2,'凡品','{"health": 300.0, "defense": 30.0}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('pants_2','金丹裤子','pants',2,'凡品','{"health": 150.0, "defense": 17.5}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('shoes_2','金丹鞋子','shoes',2,'凡品','{"health": 75.0, "defense": 7.5, "speed": 1.76}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('ring_2','金丹戒指','ring',2,'凡品','{"attack": 15.0, "mana": 45.0}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('sword_3','元婴灵剑','weapon',3,'凡品','{"attack": 1400}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('crown_3','元婴头冠','crown',3,'凡品','{"health": 375.0, "defense": 50.0, "consciousness_max": 81.0}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('clothes_3','元婴衣服','clothes',3,'凡品','{"health": 1500.0, "defense": 150.0}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('pants_3','元婴裤子','pants',3,'凡品','{"health": 750.0, "defense": 87.5}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('shoes_3','元婴鞋子','shoes',3,'凡品','{"health": 375.0, "defense": 37.5, "speed": 2.56}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('cloak_3','元婴披风','cloak',3,'凡品','{"health": 1000.0, "defense": 75.0}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('ring_3','元婴戒指','ring',3,'凡品','{"attack": 75.0, "mana": 135.0}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('belt_3','元婴腰带','belt',3,'凡品','{"health": 625.0, "defense": 62.5, "mana": 162.0}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('earring_3','元婴耳环','earring',3,'凡品','{"consciousness_max": 135.0}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('necklace_3','元婴项链','necklace',3,'凡品','{"health": 750.0}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('bracelet_3','元婴手链','bracelet',3,'凡品','{"defense": 62.5}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('anklet_3','元婴脚环','anklet',3,'凡品','{"speed": 1.6}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('pendant_3','元婴吊坠','pendant',3,'凡品','{"mana": 162.0, "consciousness_max": 135.0}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('sword_4','出窍灵剑','weapon',4,'凡品','{"attack": 6500}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('crown_4','出窍头冠','crown',4,'凡品','{"health": 1875.0, "defense": 250.0, "consciousness_max": 243.0}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('clothes_4','出窍衣服','clothes',4,'凡品','{"health": 7500.0, "defense": 750.0}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('pants_4','出窍裤子','pants',4,'凡品','{"health": 3750.0, "defense": 437.5}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('shoes_4','出窍鞋子','shoes',4,'凡品','{"health": 1875.0, "defense": 187.5, "speed": 3.68}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('cloak_4','出窍披风','cloak',4,'凡品','{"health": 5000.0, "defense": 375.0}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('ring_4','出窍戒指','ring',4,'凡品','{"attack": 375.0, "mana": 405.0}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('belt_4','出窍腰带','belt',4,'凡品','{"health": 3125.0, "defense": 312.5, "mana": 486.0}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('earring_4','出窍耳环','earring',4,'凡品','{"consciousness_max": 405.0}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('necklace_4','出窍项链','necklace',4,'凡品','{"health": 3750.0}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('bracelet_4','出窍手链','bracelet',4,'凡品','{"defense": 312.5}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('anklet_4','出窍脚环','anklet',4,'凡品','{"speed": 2.3}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('pendant_4','出窍吊坠','pendant',4,'凡品','{"mana": 486.0, "consciousness_max": 405.0}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('sword_5','化神灵剑','weapon',5,'凡品','{"attack": 30000}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('crown_5','化神头冠','crown',5,'凡品','{"health": 9375.0, "defense": 1250.0, "consciousness_max": 729.0}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('clothes_5','化神衣服','clothes',5,'凡品','{"health": 37500.0, "defense": 3750.0}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('pants_5','化神裤子','pants',5,'凡品','{"health": 18750.0, "defense": 2187.5}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('shoes_5','化神鞋子','shoes',5,'凡品','{"health": 9375.0, "defense": 937.5, "speed": 5.28}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('cloak_5','化神披风','cloak',5,'凡品','{"health": 25000.0, "defense": 1875.0}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('ring_5','化神戒指','ring',5,'凡品','{"attack": 1875.0, "mana": 1215.0}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('belt_5','化神腰带','belt',5,'凡品','{"health": 15625.0, "defense": 1562.5, "mana": 1458.0}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('earring_5','化神耳环','earring',5,'凡品','{"consciousness_max": 1215.0}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('necklace_5','化神项链','necklace',5,'凡品','{"health": 18750.0}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('bracelet_5','化神手链','bracelet',5,'凡品','{"defense": 1562.5}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('anklet_5','化神脚环','anklet',5,'凡品','{"speed": 3.3}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
INSERT INTO public.fc_equipment_definitions VALUES('pendant_5','化神吊坠','pendant',5,'凡品','{"mana": 1458.0, "consciousness_max": 1215.0}','对应境界一层的固定装备加成，穿戴后计入修士属性与战力。');
CREATE FUNCTION public.fc_equipment_stats(p_character uuid) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT coalesce(jsonb_object_agg(key,total),'{}'::jsonb) FROM (SELECT j.key,sum(j.value::numeric) AS total FROM public.fc_equipment_instances i JOIN public.fc_equipment_definitions d ON d.item_key=i.item_key CROSS JOIN LATERAL jsonb_each_text(d.stats) j WHERE i.character_id=p_character AND i.equipped_slot IS NOT NULL GROUP BY j.key) q
$$;
REVOKE ALL ON FUNCTION public.fc_equipment_stats(uuid) FROM PUBLIC;
CREATE FUNCTION public.fc_get_equipment() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters;
BEGIN SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid(); IF c.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 RETURN jsonb_build_object('realm_index',c.realm_index,'items',coalesce((SELECT jsonb_agg(jsonb_build_object('id',i.id,'equipped_slot',i.equipped_slot,'definition',to_jsonb(d))) FROM public.fc_equipment_instances i JOIN public.fc_equipment_definitions d ON d.item_key=i.item_key WHERE i.character_id=c.id),'[]'::jsonb),'stats',public.fc_equipment_stats(c.id)); END $$;
CREATE FUNCTION public.fc_change_equipment(p_id uuid,p_slot text DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters; item public.fc_equipment_instances; d public.fc_equipment_definitions; old public.fc_equipment_instances; bag integer; empty_slot integer;
BEGIN
 SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE; IF c.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 SELECT * INTO item FROM public.fc_equipment_instances WHERE id=p_id AND character_id=c.id FOR UPDATE; IF item.id IS NULL THEN RAISE EXCEPTION '装备不属于你'; END IF;
 SELECT * INTO d FROM public.fc_equipment_definitions WHERE item_key=item.item_key;
 IF p_slot IS NULL THEN
  IF item.equipped_slot IS NULL THEN RETURN public.fc_get_equipment(); END IF;
  SELECT n INTO empty_slot FROM generate_series(1,200) n WHERE NOT EXISTS(SELECT 1 FROM public.fc_inventory_slots WHERE character_id=c.id AND slot=n) ORDER BY n LIMIT 1;
  IF empty_slot IS NULL THEN RAISE EXCEPTION '储物空间已满，无法卸下'; END IF;
  INSERT INTO public.fc_inventory_slots(character_id,slot,item_key,item_name,quantity,category,description,equipment_id) VALUES(c.id,empty_slot,item.item_key,d.name,1,'装备',d.description,item.id);
  UPDATE public.fc_equipment_instances SET equipped_slot=NULL WHERE id=item.id;
 ELSE
  IF c.realm_index<d.realm_required THEN RAISE EXCEPTION '境界不足，无法穿戴'; END IF;
  IF NOT (p_slot=d.slot_type OR d.slot_type='ring' AND p_slot IN ('ring_left','ring_right')) THEN RAISE EXCEPTION '装备部位不匹配'; END IF;
  IF item.equipped_slot=p_slot THEN RETURN public.fc_get_equipment(); END IF;
  IF item.equipped_slot IS NOT NULL THEN RAISE EXCEPTION '请先卸下再更换部位'; END IF;
  SELECT slot INTO bag FROM public.fc_inventory_slots WHERE equipment_id=item.id AND character_id=c.id FOR UPDATE;
  IF bag IS NULL THEN RAISE EXCEPTION '储物中找不到该装备'; END IF;
  SELECT * INTO old FROM public.fc_equipment_instances WHERE character_id=c.id AND equipped_slot=p_slot FOR UPDATE;
  DELETE FROM public.fc_inventory_slots WHERE character_id=c.id AND slot=bag;
  IF old.id IS NOT NULL THEN
   INSERT INTO public.fc_inventory_slots(character_id,slot,item_key,item_name,quantity,category,description,equipment_id) SELECT c.id,bag,old.item_key,name,1,'装备',description,old.id FROM public.fc_equipment_definitions WHERE item_key=old.item_key;
   UPDATE public.fc_equipment_instances SET equipped_slot=NULL WHERE id=old.id;
  END IF;
  UPDATE public.fc_equipment_instances SET equipped_slot=p_slot WHERE id=item.id;
 END IF;
 RETURN public.fc_get_equipment(); END $$;
CREATE FUNCTION public.fc_claim_starter_equipment() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters; d public.fc_equipment_definitions; empty_slot integer; eid uuid;
BEGIN SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE; IF c.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 IF c.equipment_starter_claimed THEN RETURN public.fc_get_equipment(); END IF;
 IF (SELECT count(*) FROM public.fc_inventory_slots WHERE character_id=c.id)>194 THEN RAISE EXCEPTION '领取需要6格空位'; END IF;
 FOR d IN SELECT * FROM public.fc_equipment_definitions WHERE item_key IN ('sword_0','crown_0','clothes_0','pants_0','shoes_0','ring_0') ORDER BY item_key LOOP
  SELECT n INTO empty_slot FROM generate_series(1,200) n WHERE NOT EXISTS(SELECT 1 FROM public.fc_inventory_slots WHERE character_id=c.id AND slot=n) ORDER BY n LIMIT 1;
  INSERT INTO public.fc_equipment_instances(character_id,item_key) VALUES(c.id,d.item_key) RETURNING id INTO eid;
  INSERT INTO public.fc_inventory_slots(character_id,slot,item_key,item_name,quantity,category,description,equipment_id) VALUES(c.id,empty_slot,d.item_key,d.name,1,'装备',d.description,eid);
 END LOOP;
 UPDATE public.fc_characters SET equipment_starter_claimed=true WHERE id=c.id;
 RETURN public.fc_get_equipment(); END $$;
REVOKE ALL ON FUNCTION public.fc_get_equipment(),public.fc_change_equipment(uuid,text),public.fc_claim_starter_equipment() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fc_get_equipment(),public.fc_change_equipment(uuid,text),public.fc_claim_starter_equipment() TO authenticated;
CREATE OR REPLACE FUNCTION public.fc_get_attributes() RETURNS jsonb LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters; s jsonb; k text; power numeric;
BEGIN
 PERFORM public.fc_recover_attributes(); SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid();
 s:=public.fc_base_stats(c.realm_index,c.realm_layer,c.realm_grade);
 FOREACH k IN ARRAY ARRAY['health','mana','attack','defense','speed','consciousness_max'] LOOP s:=jsonb_set(s,ARRAY[k],to_jsonb(round((s->>k)::numeric+coalesce((c.expansion_stats->>k)::numeric,0)+coalesce((public.fc_equipment_stats(c.id)->>k)::numeric,0),2))); END LOOP;
 power:=round((s->>'health')::numeric*0.2+(s->>'mana')::numeric*0.1+(s->>'attack')::numeric*5+(s->>'defense')::numeric*3+(s->>'speed')::numeric*2);
 RETURN s||jsonb_build_object('aura_required',public.fc_aura_requirement(c.realm_index,c.realm_layer),'aura_points',round(c.cultivation/100*public.fc_aura_requirement(c.realm_index,c.realm_layer),2),'aura_limit',c.capacity/100*public.fc_aura_requirement(c.realm_index,c.realm_layer),'aura_rate',public.fc_aura_rate(c.realm_index),'power',power,'mind',c.mind,'consciousness',round(c.consciousness,2),'effects',public.fc_mind_effects(c.mind),'expansion_stats',c.expansion_stats);
END $$;
CREATE OR REPLACE FUNCTION public.fc_character_power(c public.fc_characters) RETURNS numeric LANGUAGE sql STABLE SET search_path=public,pg_temp AS $$
 SELECT round((s->>'health')::numeric*0.2+(s->>'mana')::numeric*0.1+(s->>'attack')::numeric*5+(s->>'defense')::numeric*3+(s->>'speed')::numeric*2+coalesce((c.expansion_stats->>'health')::numeric,0)*0.2+coalesce((c.expansion_stats->>'mana')::numeric,0)*0.1+coalesce((c.expansion_stats->>'attack')::numeric,0)*5+coalesce((c.expansion_stats->>'defense')::numeric,0)*3+coalesce((c.expansion_stats->>'speed')::numeric,0)*2+(coalesce((public.fc_equipment_stats(c.id)->>'health')::numeric,0)*0.2+coalesce((public.fc_equipment_stats(c.id)->>'mana')::numeric,0)*0.1+coalesce((public.fc_equipment_stats(c.id)->>'attack')::numeric,0)*5+coalesce((public.fc_equipment_stats(c.id)->>'defense')::numeric,0)*3+coalesce((public.fc_equipment_stats(c.id)->>'speed')::numeric,0)*2)) FROM public.fc_base_stats(c.realm_index,c.realm_layer,c.realm_grade) s
$$;
REVOKE ALL ON FUNCTION public.fc_character_power(public.fc_characters) FROM PUBLIC;
