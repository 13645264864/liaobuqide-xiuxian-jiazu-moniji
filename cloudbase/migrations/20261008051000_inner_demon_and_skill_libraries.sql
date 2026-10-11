CREATE TABLE public.fc_skill_definitions(id text PRIMARY KEY,name text NOT NULL,category text NOT NULL CHECK(category IN ('art','ability')),description text NOT NULL,enhanced_description text NOT NULL,effects jsonb NOT NULL,enhanced_effects jsonb NOT NULL);
CREATE TABLE public.fc_known_skills(character_id uuid REFERENCES public.fc_characters(id),skill_id text REFERENCES public.fc_skill_definitions(id),enhanced boolean NOT NULL DEFAULT false,learned_realm integer NOT NULL,slot integer CHECK(slot BETWEEN 1 AND 3),PRIMARY KEY(character_id,skill_id));
CREATE TABLE public.fc_skill_choices(id uuid PRIMARY KEY REFERENCES public.fc_breakthrough_records(id),character_id uuid NOT NULL REFERENCES public.fc_characters(id),grade integer NOT NULL,realm integer NOT NULL,candidates jsonb NOT NULL,selected_id text REFERENCES public.fc_skill_definitions(id),created_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX fc_pending_skill_choices ON public.fc_skill_choices(character_id) WHERE selected_id IS NULL;
CREATE TABLE public.fc_trial_locks(character_id uuid PRIMARY KEY REFERENCES public.fc_characters(id),expires_at timestamptz NOT NULL);
ALTER TABLE public.fc_combat_encounters ADD COLUMN skill_runtime jsonb NOT NULL DEFAULT '{}';
ALTER TABLE public.fc_characters ADD COLUMN legacy_grade_stats jsonb NOT NULL DEFAULT '{}';
ALTER TABLE public.fc_skill_definitions ENABLE ROW LEVEL SECURITY;ALTER TABLE public.fc_known_skills ENABLE ROW LEVEL SECURITY;ALTER TABLE public.fc_skill_choices ENABLE ROW LEVEL SECURITY;ALTER TABLE public.fc_trial_locks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.fc_skill_definitions,public.fc_known_skills,public.fc_skill_choices,public.fc_trial_locks FROM anon,authenticated;

CREATE FUNCTION public.fc_get_skills() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE me uuid;
BEGIN SELECT id INTO me FROM public.fc_characters WHERE owner_id=public.fc_require_uid();IF me IS NULL THEN RAISE EXCEPTION '请先入世';END IF;
 RETURN jsonb_build_object('skills',coalesce((SELECT jsonb_agg(to_jsonb(d)||jsonb_build_object('enhanced',k.enhanced,'slot',k.slot,'learned_realm',k.learned_realm,'effects',CASE WHEN k.enhanced THEN d.enhanced_effects ELSE d.effects END,'description',CASE WHEN k.enhanced THEN d.enhanced_description ELSE d.description END)) FROM public.fc_known_skills k JOIN public.fc_skill_definitions d ON d.id=k.skill_id WHERE k.character_id=me),'[]'::jsonb),'pending',coalesce((SELECT jsonb_agg(to_jsonb(c)) FROM public.fc_skill_choices c WHERE c.character_id=me AND selected_id IS NULL),'[]'::jsonb)); END $$;

CREATE FUNCTION public.fc_generate_skill_choice(p_record uuid,p_character uuid,p_grade integer,p_realm integer) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE cards jsonb:='[]';d public.fc_skill_definitions;ability boolean;prob numeric; enhanced boolean:=p_grade=9;ids text[]:=ARRAY[]::text[];i integer;cat text;existing jsonb;
BEGIN
 SELECT candidates INTO existing FROM public.fc_skill_choices WHERE id=p_record;IF existing IS NOT NULL THEN RETURN existing;END IF;
 prob:=CASE p_grade WHEN 4 THEN .2 WHEN 5 THEN .4 WHEN 6 THEN .6 ELSE 0 END;ability:=p_grade>=7 OR random()<prob;
 FOR i IN 1..3 LOOP
 cat:=CASE WHEN p_grade>=7 OR ability AND i=1 THEN 'ability' ELSE 'art' END;
 SELECT * INTO d FROM public.fc_skill_definitions WHERE category=cat AND NOT(fc_skill_definitions.id=ANY(ids)) ORDER BY EXISTS(SELECT 1 FROM public.fc_known_skills k WHERE k.character_id=p_character AND k.skill_id=fc_skill_definitions.id AND (NOT enhanced OR k.enhanced)),random() LIMIT 1;
 ids:=array_append(ids,d.id);cards:=cards||jsonb_build_array(to_jsonb(d)||jsonb_build_object('enhanced',enhanced,'effects',CASE WHEN enhanced THEN d.enhanced_effects ELSE d.effects END,'description',CASE WHEN enhanced THEN d.enhanced_description ELSE d.description END));END LOOP;
 INSERT INTO public.fc_skill_choices(id,character_id,grade,realm,candidates) VALUES(p_record,p_character,p_grade,p_realm,cards);RETURN cards;END $$;
REVOKE ALL ON FUNCTION public.fc_generate_skill_choice(uuid,uuid,integer,integer) FROM PUBLIC,authenticated,anon;

CREATE FUNCTION public.fc_choose_skill(p_choice uuid,p_skill text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters;choice public.fc_skill_choices;card jsonb;
BEGIN
 SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE;
 SELECT * INTO choice FROM public.fc_skill_choices WHERE id=p_choice AND character_id=c.id FOR UPDATE;
 IF choice.id IS NULL THEN RAISE EXCEPTION '无可领取的领悟';END IF;
 IF choice.selected_id IS NOT NULL THEN IF choice.selected_id<>p_skill THEN RAISE EXCEPTION '已经选择过奖励';END IF;RETURN public.fc_get_skills();END IF;
 SELECT v INTO card FROM jsonb_array_elements(choice.candidates) v WHERE v->>'id'=p_skill;
 IF card IS NULL THEN RAISE EXCEPTION '不在本次候选内';END IF;
 INSERT INTO public.fc_known_skills(character_id,skill_id,enhanced,learned_realm) VALUES(c.id,p_skill,(card->>'enhanced')::boolean,choice.realm)
 ON CONFLICT(character_id,skill_id) DO UPDATE SET enhanced=public.fc_known_skills.enhanced OR EXCLUDED.enhanced,learned_realm=greatest(public.fc_known_skills.learned_realm,EXCLUDED.learned_realm);
 UPDATE public.fc_skill_choices SET selected_id=p_skill WHERE id=p_choice;RETURN public.fc_get_skills();END $$;

CREATE FUNCTION public.fc_equip_skill(p_skill text,p_slot integer DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters;cat text;
BEGIN SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE;
 IF EXISTS(SELECT 1 FROM public.fc_combat_encounters WHERE character_id=c.id AND status='active') OR EXISTS(SELECT 1 FROM public.fc_trial_locks WHERE character_id=c.id AND expires_at>now()) THEN RAISE EXCEPTION '战斗或试炼中不能更换技能';END IF;
 SELECT d.category INTO cat FROM public.fc_known_skills k JOIN public.fc_skill_definitions d ON d.id=k.skill_id WHERE k.character_id=c.id AND k.skill_id=p_skill;
 IF cat IS NULL THEN RAISE EXCEPTION '尚未领悟';END IF;
 IF p_slot IS NOT NULL AND (p_slot<1 OR p_slot>(CASE WHEN cat='ability' THEN 2 ELSE 3 END)) THEN RAISE EXCEPTION '启用位置无效';END IF;
 IF p_slot IS NOT NULL THEN UPDATE public.fc_known_skills k SET slot=NULL FROM public.fc_skill_definitions d WHERE k.character_id=c.id AND d.id=k.skill_id AND d.category=cat AND k.slot=p_slot;END IF;
 UPDATE public.fc_known_skills SET slot=p_slot WHERE character_id=c.id AND skill_id=p_skill;RETURN public.fc_get_skills();END $$;
REVOKE ALL ON FUNCTION public.fc_get_skills(),public.fc_choose_skill(uuid,text),public.fc_equip_skill(text,integer) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.fc_get_skills(),public.fc_choose_skill(uuid,text),public.fc_equip_skill(text,integer) TO authenticated;
INSERT INTO public.fc_skill_definitions(id,name,category,description,enhanced_description,effects,enhanced_effects) VALUES
('art_01','五岳剑阵','art','伤害倍率300%；生命护盾15.0%；需要佩剑','伤害倍率300%；生命护盾15.0%；需要佩剑','{"damage": 3, "targets": 5, "cooldown": 10, "cost": 0.12, "sword": true, "shield": 0.15}','{"damage": 3, "targets": 5, "cooldown": 10, "cost": 0.12, "sword": true, "shield": 0.15}'),
('art_02','流星连剑','art','伤害倍率500%；需要佩剑','伤害倍率500%；需要佩剑','{"damage": 5, "targets": 1, "cooldown": 8, "cost": 0.1, "sword": true}','{"damage": 5, "targets": 1, "cooldown": 8, "cost": 0.1, "sword": true}'),
('art_03','横扫八方','art','伤害倍率280.0%；敌方伤害降低15.0%；持续4秒','伤害倍率280.0%；敌方伤害降低15.0%；持续4秒','{"damage": 2.8, "targets": 5, "cooldown": 10, "cost": 0.12, "sword": false, "weaken": 0.15, "duration": 4}','{"damage": 2.8, "targets": 5, "cooldown": 10, "cost": 0.12, "sword": false, "weaken": 0.15, "duration": 4}'),
('art_04','雷链术','art','伤害倍率260.0%；眩晕1秒','伤害倍率260.0%；眩晕1秒','{"damage": 2.6, "targets": 5, "cooldown": 12, "cost": 0.12, "sword": false, "stun": 1}','{"damage": 2.6, "targets": 5, "cooldown": 12, "cost": 0.12, "sword": false, "stun": 1}'),
('art_05','赤焰环','art','伤害倍率180.0%；每秒持续伤害40.0%；持续4秒','伤害倍率180.0%；每秒持续伤害40.0%；持续4秒','{"damage": 1.8, "targets": 5, "cooldown": 12, "cost": 0.12, "sword": false, "burn": 0.4, "duration": 4}','{"damage": 1.8, "targets": 5, "cooldown": 12, "cost": 0.12, "sword": false, "burn": 0.4, "duration": 4}'),
('art_06','冰封剑雨','art','伤害倍率250.0%；敌方伤害降低20.0%；持续4秒；需要佩剑','伤害倍率250.0%；敌方伤害降低20.0%；持续4秒；需要佩剑','{"damage": 2.5, "targets": 5, "cooldown": 12, "cost": 0.12, "sword": true, "weaken": 0.2, "duration": 4}','{"damage": 2.5, "targets": 5, "cooldown": 12, "cost": 0.12, "sword": true, "weaken": 0.2, "duration": 4}'),
('art_07','破甲斩','art','伤害倍率450.0%；忽略防御30.0%；需要佩剑','伤害倍率450.0%；忽略防御30.0%；需要佩剑','{"damage": 4.5, "targets": 1, "cooldown": 10, "cost": 0.1, "sword": true, "pierce": 0.3}','{"damage": 4.5, "targets": 1, "cooldown": 10, "cost": 0.1, "sword": true, "pierce": 0.3}'),
('art_08','断岳重击','art','伤害倍率600%','伤害倍率600%','{"damage": 6, "targets": 1, "cooldown": 12, "cost": 0.12, "sword": false}','{"damage": 6, "targets": 1, "cooldown": 12, "cost": 0.12, "sword": false}'),
('art_09','追魂剑','art','伤害倍率400%；需要佩剑','伤害倍率400%；需要佩剑','{"damage": 4, "targets": 1, "cooldown": 10, "cost": 0.1, "sword": true, "execute": 1.625}','{"damage": 4, "targets": 1, "cooldown": 10, "cost": 0.1, "sword": true, "execute": 1.625}'),
('art_10','烈火掌','art','伤害倍率350.0%；每秒持续伤害50.0%；持续4秒','伤害倍率350.0%；每秒持续伤害50.0%；持续4秒','{"damage": 3.5, "targets": 1, "cooldown": 10, "cost": 0.1, "sword": false, "burn": 0.5, "duration": 4}','{"damage": 3.5, "targets": 1, "cooldown": 10, "cost": 0.1, "sword": false, "burn": 0.5, "duration": 4}'),
('art_11','穿云刺','art','伤害倍率450.0%；忽略防御40.0%','伤害倍率450.0%；忽略防御40.0%','{"damage": 4.5, "targets": 1, "cooldown": 10, "cost": 0.1, "sword": false, "pierce": 0.4}','{"damage": 4.5, "targets": 1, "cooldown": 10, "cost": 0.1, "sword": false, "pierce": 0.4}'),
('art_12','震魂刺','art','伤害倍率300%；眩晕1秒；消耗神识上限2%','伤害倍率300%；眩晕1秒；消耗神识上限2%','{"damage": 3, "targets": 1, "cooldown": 12, "cost": 0.1, "sword": false, "stun": 1, "spirit": 0.02}','{"damage": 3, "targets": 1, "cooldown": 12, "cost": 0.1, "sword": false, "stun": 1, "spirit": 0.02}'),
('art_13','缠藤困阵','art','伤害倍率180.0%；敌方伤害降低20.0%；持续4秒','伤害倍率180.0%；敌方伤害降低20.0%；持续4秒','{"damage": 1.8, "targets": 5, "cooldown": 14, "cost": 0.12, "sword": false, "weaken": 0.2, "duration": 4}','{"damage": 1.8, "targets": 5, "cooldown": 14, "cost": 0.12, "sword": false, "weaken": 0.2, "duration": 4}'),
('art_14','碎盾诀','art','伤害倍率350.0%；忽略防御50.0%','伤害倍率350.0%；忽略防御50.0%','{"damage": 3.5, "targets": 1, "cooldown": 10, "cost": 0.1, "sword": false, "pierce": 0.5}','{"damage": 3.5, "targets": 1, "cooldown": 10, "cost": 0.1, "sword": false, "pierce": 0.5}'),
('art_15','风雷双击','art','伤害倍率500%；忽略防御30.0%','伤害倍率500%；忽略防御30.0%','{"damage": 5, "targets": 1, "cooldown": 10, "cost": 0.11, "sword": false, "pierce": 0.3}','{"damage": 5, "targets": 1, "cooldown": 10, "cost": 0.11, "sword": false, "pierce": 0.3}'),
('art_16','金钟护体','art','伤害倍率150.0%；生命护盾35.0%；持续6秒','伤害倍率150.0%；生命护盾35.0%；持续6秒','{"damage": 1.5, "targets": 5, "cooldown": 16, "cost": 0.12, "sword": false, "shield": 0.35, "duration": 6}','{"damage": 1.5, "targets": 5, "cooldown": 16, "cost": 0.12, "sword": false, "shield": 0.35, "duration": 6}'),
('art_17','守山剑式','art','伤害倍率220.0%；减伤25.0%；持续4秒；需要佩剑','伤害倍率220.0%；减伤25.0%；持续4秒；需要佩剑','{"damage": 2.2, "targets": 5, "cooldown": 12, "cost": 0.12, "sword": true, "reduction": 0.25, "duration": 4}','{"damage": 2.2, "targets": 5, "cooldown": 12, "cost": 0.12, "sword": true, "reduction": 0.25, "duration": 4}'),
('art_18','回春诀','art','生命护盾10.0%；恢复生命20.0%；生命低于60%触发','生命护盾10.0%；恢复生命20.0%；生命低于60%触发','{"damage": 0, "targets": 1, "cooldown": 20, "cost": 0.12, "sword": false, "heal": 0.2, "shield": 0.1, "threshold": 0.6}','{"damage": 0, "targets": 1, "cooldown": 20, "cost": 0.12, "sword": false, "heal": 0.2, "shield": 0.1, "threshold": 0.6}'),
('art_19','净身诀','art','伤害倍率200%；恢复生命12.0%','伤害倍率200%；恢复生命12.0%','{"damage": 2, "targets": 1, "cooldown": 18, "cost": 0.1, "sword": false, "heal": 0.12, "cleanse": true}','{"damage": 2, "targets": 1, "cooldown": 18, "cost": 0.1, "sword": false, "heal": 0.12, "cleanse": true}'),
('art_20','灵息回流','art','伤害倍率160.0%；回复灵力18.0%','伤害倍率160.0%；回复灵力18.0%','{"damage": 1.6, "targets": 1, "cooldown": 20, "cost": 0, "sword": false, "mana_restore": 0.18}','{"damage": 1.6, "targets": 1, "cooldown": 20, "cost": 0, "sword": false, "mana_restore": 0.18}'),
('art_21','摄灵掌','art','伤害倍率300%；回复灵力8.0%','伤害倍率300%；回复灵力8.0%','{"damage": 3, "targets": 1, "cooldown": 12, "cost": 0.04, "sword": false, "mana_restore": 0.08}','{"damage": 3, "targets": 1, "cooldown": 12, "cost": 0.04, "sword": false, "mana_restore": 0.08}'),
('art_22','血战连斩','art','伤害倍率600%','伤害倍率600%','{"damage": 6, "targets": 1, "cooldown": 12, "cost": 0.08, "sword": false, "self_cost": 0.05, "min_health": 0.3}','{"damage": 6, "targets": 1, "cooldown": 12, "cost": 0.08, "sword": false, "self_cost": 0.05, "min_health": 0.3}'),
('art_23','镜光反击','art','伤害倍率400%；减伤60.0%；持续1秒','伤害倍率400%；减伤60.0%；持续1秒','{"damage": 4, "targets": 1, "cooldown": 16, "cost": 0.12, "sword": false, "reduction": 0.6, "duration": 1}','{"damage": 4, "targets": 1, "cooldown": 16, "cost": 0.12, "sword": false, "reduction": 0.6, "duration": 1}'),
('art_24','星火燎原','art','伤害倍率200%；每秒持续伤害37.5%；持续4秒','伤害倍率200%；每秒持续伤害37.5%；持续4秒','{"damage": 2, "targets": 5, "cooldown": 12, "cost": 0.12, "sword": false, "burn": 0.375, "duration": 4}','{"damage": 2, "targets": 5, "cooldown": 12, "cost": 0.12, "sword": false, "burn": 0.375, "duration": 4}'),
('art_25','归元剑诀','art','伤害倍率350.0%；恢复生命12.0%；需要佩剑','伤害倍率350.0%；恢复生命12.0%；需要佩剑','{"damage": 3.5, "targets": 1, "cooldown": 15, "cost": 0.12, "sword": true, "heal": 0.12}','{"damage": 3.5, "targets": 1, "cooldown": 15, "cost": 0.12, "sword": true, "heal": 0.12}'),
('ability_01','破天剑','ability','伤害倍率1000%；生命护盾25.0%；忽略防御60.0%','伤害倍率1800%；生命护盾45.0%；忽略防御80.0%','{"damage": 10, "targets": 1, "cooldown": 40, "cost": 0.2, "shield": 0.25, "pierce": 0.6}','{"damage": 18, "targets": 1, "cooldown": 25, "cost": 0.2, "shield": 0.45, "pierce": 0.8}'),
('ability_02','不灭金身','ability','伤害倍率600%；减伤70.0%；生命低于60%触发；持续6秒','伤害倍率1200%；恢复生命30.0%；减伤85.0%；生命低于60%触发；持续8秒','{"damage": 6, "targets": 1, "cooldown": 45, "cost": 0.2, "threshold": 0.6, "reduction": 0.7, "duration": 6}','{"damage": 12, "targets": 1, "cooldown": 35, "cost": 0.2, "threshold": 0.6, "reduction": 0.85, "duration": 8, "heal": 0.3, "immunity": 8}'),
('ability_03','万剑归宗','ability','伤害倍率1200%；忽略防御30.0%；减伤30.0%；持续3秒','伤害倍率2160.0%；忽略防御60.0%；减伤60.0%；持续3秒','{"damage": 12, "targets": 1, "cooldown": 40, "cost": 0.2, "pierce": 0.3, "reduction": 0.3, "duration": 3}','{"damage": 21.6, "targets": 1, "cooldown": 30, "cost": 0.2, "pierce": 0.6, "reduction": 0.6, "duration": 3}'),
('ability_04','天雷诛邪','ability','伤害倍率1200%；生命护盾20.0%；眩晕1秒','伤害倍率2000%；生命护盾40.0%；眩晕2秒','{"damage": 12, "targets": 1, "cooldown": 40, "cost": 0.2, "stun": 1, "shield": 0.2}','{"damage": 20, "targets": 1, "cooldown": 30, "cost": 0.2, "stun": 2, "shield": 0.4}'),
('ability_05','山河镇魔','ability','伤害倍率700%；敌方伤害降低25.0%；持续5秒','伤害倍率1200%；敌方伤害降低40.0%；持续7秒','{"damage": 7, "targets": 5, "cooldown": 40, "cost": 0.2, "weaken": 0.25, "duration": 5}','{"damage": 12, "targets": 5, "cooldown": 30, "cost": 0.2, "weaken": 0.4, "duration": 7}'),
('ability_06','凤凰涅槃','ability','伤害倍率800%；恢复生命35.0%；致命受击触发，每场仅一次；同类保命不叠加','伤害倍率1600%；恢复生命70.0%；减伤100%；持续2秒；致命受击触发，每场仅一次；同类保命不叠加','{"damage": 8, "targets": 1, "cooldown": 9999, "cost": 0, "lethal": true, "heal": 0.35}','{"damage": 16, "targets": 1, "cooldown": 9999, "cost": 0, "lethal": true, "heal": 0.7, "reduction": 1, "duration": 2}'),
('ability_07','太虚护命','ability','伤害倍率1000%；生命护盾30.0%；致命受击触发，每场仅一次；同类保命不叠加','伤害倍率2000%；生命护盾60.0%；回复灵力20.0%；致命受击触发，每场仅一次；同类保命不叠加','{"damage": 10, "targets": 1, "cooldown": 9999, "cost": 0, "lethal": true, "shield": 0.3}','{"damage": 20, "targets": 1, "cooldown": 9999, "cost": 0, "lethal": true, "shield": 0.6, "mana_restore": 0.2}'),
('ability_08','噬灵归元','ability','伤害倍率900%；恢复生命25.0%；回复灵力15.0%','伤害倍率1600%；恢复生命40.0%；回复灵力25.0%','{"damage": 9, "targets": 1, "cooldown": 40, "cost": 0.2, "heal": 0.25, "mana_restore": 0.15}','{"damage": 16, "targets": 1, "cooldown": 30, "cost": 0.2, "heal": 0.4, "mana_restore": 0.25}'),
('ability_09','冰魄封天','ability','伤害倍率900%；生命护盾30.0%；眩晕1秒','伤害倍率1500%；生命护盾50.0%；敌方伤害降低30.0%；持续4秒；眩晕2秒','{"damage": 9, "targets": 1, "cooldown": 40, "cost": 0.2, "stun": 1, "shield": 0.3}','{"damage": 15, "targets": 1, "cooldown": 30, "cost": 0.2, "stun": 2, "shield": 0.5, "weaken": 0.3, "duration": 4}'),
('ability_10','幽冥断魂','ability','伤害倍率1100%；敌方伤害降低30.0%；持续6秒；消耗神识上限2%','伤害倍率1800%；敌方伤害降低50.0%；持续6秒；消耗神识上限2%','{"damage": 11, "targets": 1, "cooldown": 40, "cost": 0.2, "spirit": 0.02, "weaken": 0.3, "duration": 6}','{"damage": 18, "targets": 1, "cooldown": 30, "cost": 0.2, "spirit": 0.02, "weaken": 0.5, "duration": 6, "immunity": 4}'),
('ability_11','剑意领域','ability','生命护盾25.0%；忽略防御20.0%；增伤35.0%；持续10秒','生命护盾45.0%；忽略防御40.0%；增伤65.0%；持续15秒','{"damage": 0, "targets": 1, "cooldown": 40, "cost": 0.2, "boost": 0.35, "pierce": 0.2, "shield": 0.25, "duration": 10}','{"damage": 0, "targets": 1, "cooldown": 30, "cost": 0.2, "boost": 0.65, "pierce": 0.4, "shield": 0.45, "duration": 15}'),
('ability_12','五行轮转','ability','伤害倍率1100%；生命护盾20.0%；忽略防御20.0%；回复灵力10.0%；每秒持续伤害40.0%；持续4秒','伤害倍率2000%；生命护盾35.0%；恢复生命20.0%；忽略防御40.0%；回复灵力20.0%；每秒持续伤害80.0%；持续4秒','{"damage": 11, "targets": 1, "cooldown": 40, "cost": 0.2, "pierce": 0.2, "burn": 0.4, "duration": 4, "mana_restore": 0.1, "shield": 0.2}','{"damage": 20, "targets": 1, "cooldown": 30, "cost": 0.2, "pierce": 0.4, "burn": 0.8, "duration": 4, "mana_restore": 0.2, "shield": 0.35, "heal": 0.2}'),
('ability_13','阴阳逆转','ability','伤害倍率1000%；恢复生命30.0%；生命低于40%触发','伤害倍率1800%；恢复生命55.0%；减伤50.0%；生命低于40%触发；持续4秒','{"damage": 10, "targets": 1, "cooldown": 40, "cost": 0.2, "threshold": 0.4, "heal": 0.3}','{"damage": 18, "targets": 1, "cooldown": 30, "cost": 0.2, "threshold": 0.4, "heal": 0.55, "reduction": 0.5, "duration": 4}'),
('ability_14','星辰坠落','ability','伤害倍率800%；生命护盾30.0%','伤害倍率1400%；生命护盾50.0%；忽略防御50.0%','{"damage": 8, "targets": 5, "cooldown": 40, "cost": 0.2, "shield": 0.3}','{"damage": 14, "targets": 5, "cooldown": 30, "cost": 0.2, "shield": 0.5, "pierce": 0.5}'),
('ability_15','万象灵镜','ability','伤害倍率1200%；减伤80.0%；持续1秒','伤害倍率2800%；减伤100%；持续2秒','{"damage": 12, "targets": 1, "cooldown": 40, "cost": 0.2, "reduction": 0.8, "duration": 1}','{"damage": 28, "targets": 1, "cooldown": 30, "cost": 0.2, "reduction": 1, "duration": 2}'),
('ability_16','法相镇身','ability','伤害倍率640.0%；生命护盾40.0%；增伤30.0%；持续8秒','伤害倍率1200%；生命护盾70.0%；增伤50.0%；持续8秒','{"damage": 6.4, "targets": 1, "cooldown": 40, "cost": 0.2, "shield": 0.4, "boost": 0.3, "duration": 8}','{"damage": 12, "targets": 1, "cooldown": 30, "cost": 0.2, "shield": 0.7, "boost": 0.5, "duration": 8}'),
('ability_17','血海战魂','ability','增伤50.0%；吸血15.0%；持续8秒','生命护盾35.0%；增伤80.0%；吸血25.0%；持续8秒','{"damage": 0, "targets": 1, "cooldown": 40, "cost": 0.2, "boost": 0.5, "lifesteal": 0.15, "duration": 8, "self_cost": 0.1}','{"damage": 0, "targets": 1, "cooldown": 30, "cost": 0.2, "boost": 0.8, "lifesteal": 0.25, "duration": 8, "shield": 0.35}'),
('ability_18','青莲净世','ability','伤害倍率600%；恢复生命25.0%','伤害倍率1100%；恢复生命45.0%','{"damage": 6, "targets": 5, "cooldown": 40, "cost": 0.2, "heal": 0.25, "cleanse": true}','{"damage": 11, "targets": 5, "cooldown": 30, "cost": 0.2, "heal": 0.45, "cleanse": true, "immunity": 6}'),
('ability_19','风雷神行','ability','伤害倍率900%；减伤100%；持续1秒','伤害倍率2250.0%；减伤100%；持续2秒','{"damage": 9, "targets": 1, "cooldown": 40, "cost": 0.2, "reduction": 1, "duration": 1}','{"damage": 22.5, "targets": 1, "cooldown": 30, "cost": 0.2, "reduction": 1, "duration": 2}'),
('ability_20','混元一气','ability','伤害倍率1300%；减伤30.0%；回复灵力20.0%；持续5秒','伤害倍率2200%；减伤60.0%；回复灵力35.0%；持续5秒','{"damage": 13, "targets": 1, "cooldown": 40, "cost": 0.2, "mana_restore": 0.2, "reduction": 0.3, "duration": 5}','{"damage": 22, "targets": 1, "cooldown": 30, "cost": 0.2, "mana_restore": 0.35, "reduction": 0.6, "duration": 5}'),
('ability_21','镇魂天钟','ability','伤害倍率650.0%；生命护盾30.0%；眩晕1秒；消耗神识上限2%','伤害倍率1100%；生命护盾55.0%；眩晕2秒；消耗神识上限2%','{"damage": 6.5, "targets": 5, "cooldown": 40, "cost": 0.2, "stun": 1, "shield": 0.3, "spirit": 0.02}','{"damage": 11, "targets": 5, "cooldown": 30, "cost": 0.2, "stun": 2, "shield": 0.55, "spirit": 0.02}'),
('ability_22','乾坤挪移','ability','伤害倍率1000%；减伤70.0%；持续1秒','伤害倍率1800%；恢复生命25.0%；减伤90.0%；持续1秒','{"damage": 10, "targets": 1, "cooldown": 40, "cost": 0.2, "reduction": 0.7, "duration": 1}','{"damage": 18, "targets": 1, "cooldown": 30, "cost": 0.2, "reduction": 0.9, "duration": 1, "heal": 0.25}'),
('ability_23','太初剑心','ability','伤害倍率600%；生命护盾30.0%','伤害倍率1000%；生命护盾50.0%','{"damage": 6, "targets": 1, "cooldown": 4, "cost": 0, "shield": 0.3}','{"damage": 10, "targets": 1, "cooldown": 3, "cost": 0, "shield": 0.5}'),
('ability_24','苍龙守道','ability','伤害倍率1000%；减伤30.0%；持续10秒','伤害倍率2400%；减伤55.0%；持续12秒','{"damage": 10, "targets": 1, "cooldown": 40, "cost": 0.2, "reduction": 0.3, "duration": 10}','{"damage": 24, "targets": 1, "cooldown": 30, "cost": 0.2, "reduction": 0.55, "duration": 12}'),
('ability_25','轮回印','ability','伤害倍率1200%；生命护盾25.0%；延迟8秒爆发','伤害倍率2200%；生命护盾45.0%；恢复生命20.0%；延迟8秒爆发','{"damage": 12, "targets": 1, "cooldown": 40, "cost": 0.2, "shield": 0.25, "delay": 8}','{"damage": 22, "targets": 1, "cooldown": 30, "cost": 0.2, "shield": 0.45, "delay": 8, "heal": 0.2}');
CREATE OR REPLACE FUNCTION public.fc_base_stats_legacy(p_realm integer, p_layer integer, p_grade integer)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
SELECT jsonb_build_object('health',(ARRAY[100,500,2500,12500,62500,312500])[p_realm+1]*(1+(p_layer-1)*0.1)*(1+(p_grade-1)*0.0625),'mana',(ARRAY[100,300,900,2700,8100,24300])[p_realm+1]*(1+(p_layer-1)*0.1)*(1+(p_grade-1)*0.0625),'attack',(ARRAY[20,100,500,2500,12500,62500])[p_realm+1]*(1+(p_layer-1)*0.1)*(1+(p_grade-1)*0.0625),'defense',(ARRAY[10,50,250,1250,6250,31250])[p_realm+1]*(1+(p_layer-1)*0.1)*(1+(p_grade-1)*0.0625),'speed',(ARRAY[10,15,22,32,46,66])[p_realm+1]*(1+(p_layer-1)*0.02),'consciousness_max',(ARRAY[100,300,900,2700,8100,24300])[p_realm+1]*(1+(p_layer-1)*0.1)*(1+(p_grade-1)*0.0625),'critical_rate',5,'critical_damage',150)
$function$;

DO $$ DECLARE c public.fc_characters; oldstats jsonb; newstats jsonb; result jsonb; key text;
BEGIN FOR c IN SELECT * FROM public.fc_characters LOOP
oldstats:=public.fc_base_stats_legacy(c.realm_index,c.realm_layer,c.realm_grade);newstats:=public.fc_base_stats_legacy(c.realm_index,c.realm_layer,1);result:='{}';
FOREACH key IN ARRAY ARRAY['health','mana','attack','defense','speed','consciousness_max'] LOOP result:=jsonb_set(result,ARRAY[key],to_jsonb((oldstats->>key)::numeric-(newstats->>key)::numeric));END LOOP;
UPDATE public.fc_characters SET legacy_grade_stats=result WHERE id=c.id;END LOOP;END $$;
CREATE OR REPLACE FUNCTION public.fc_base_stats(p_realm integer,p_layer integer,p_grade integer) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$ SELECT public.fc_base_stats_legacy(p_realm,p_layer,1) $$;
REVOKE ALL ON FUNCTION public.fc_base_stats_legacy(integer,integer,integer) FROM PUBLIC,authenticated,anon;
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
 s:=jsonb_set(s,ARRAY['health'],to_jsonb(round((s->>'health')::numeric*(1+public.fc_manual_health(c)),2)));
 power:=round((s->>'health')::numeric*0.2+(s->>'mana')::numeric*0.1+(s->>'attack')::numeric*5+(s->>'defense')::numeric*3+(s->>'speed')::numeric*2);
 RETURN s||jsonb_build_object('aura_required',public.fc_aura_requirement(c.realm_index,c.realm_layer),'aura_points',round(c.cultivation/100*public.fc_aura_requirement(c.realm_index,c.realm_layer),2),'aura_limit',c.capacity/100*public.fc_aura_requirement(c.realm_index,c.realm_layer),'aura_rate',public.fc_aura_rate(c.realm_index),'power',power,'mind',c.mind,'consciousness',round(c.consciousness,2),'effects',public.fc_mind_effects(c.mind),'expansion_stats',c.expansion_stats);
END $function$;
CREATE OR REPLACE FUNCTION public.fc_character_power(c fc_characters)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
 SELECT round(((s->>'health')::numeric+coalesce((c.expansion_stats->>'health')::numeric,0)+coalesce((c.legacy_grade_stats->>'health')::numeric,0)+coalesce((e->>'health')::numeric,0))*(1+public.fc_manual_health(c))*0.2+((s->>'mana')::numeric+coalesce((c.expansion_stats->>'mana')::numeric,0)+coalesce((c.legacy_grade_stats->>'mana')::numeric,0)+coalesce((e->>'mana')::numeric,0))*0.1+((s->>'attack')::numeric+coalesce((c.expansion_stats->>'attack')::numeric,0)+coalesce((c.legacy_grade_stats->>'attack')::numeric,0)+coalesce((e->>'attack')::numeric,0))*5+((s->>'defense')::numeric+coalesce((c.expansion_stats->>'defense')::numeric,0)+coalesce((c.legacy_grade_stats->>'defense')::numeric,0)+coalesce((e->>'defense')::numeric,0))*3+((s->>'speed')::numeric+coalesce((c.expansion_stats->>'speed')::numeric,0)+coalesce((c.legacy_grade_stats->>'speed')::numeric,0)+coalesce((e->>'speed')::numeric,0))*2) FROM public.fc_base_stats(c.realm_index,c.realm_layer,c.realm_grade) s,public.fc_equipment_stats(c.id) e
$function$;
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
 effects:=public.fc_mind_effects(c.mind);
 UPDATE public.fc_characters SET consciousness=least(max_spirit,consciousness+elapsed*max_spirit*0.01*(effects->>'recovery')::numeric),recovery_at=now() WHERE id=c.id;
END $function$;-- A shared deterministic tick is used by ordinary combat and inner-demon trials.
CREATE FUNCTION public.fc_skill_tick(p_character uuid,p_stats jsonb,p_enemy jsonb,p_runtime jsonb,p_health numeric,p_mana numeric,p_turn integer,p_incoming numeric,p_enemy_health numeric,p_enemy_max numeric,p_enemies integer DEFAULT 1) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE runtime jsonb:=p_runtime;rec record;fx jsonb;cd integer;last_tick integer;cost numeric;atk numeric:=(p_stats->>'attack')::numeric;hpmax numeric:=(p_stats->>'health')::numeric;mpmax numeric:=(p_stats->>'mana')::numeric;health numeric:=p_health;mana numeric:=p_mana;shield numeric:=coalesce((runtime->>'shield')::numeric,0);shield_until integer:=coalesce((runtime->>'shield_until')::integer,-1);damage numeric:=0;incoming numeric:=p_incoming;amount numeric;mitigation numeric:=0;boost numeric:=0;lifesteal numeric:=0;weaken numeric:=0;is_lethal boolean;is_delayed boolean;protection numeric:=0;logs jsonb:='[]';spirit numeric;spirit_cost numeric;targets integer;stun integer;immune integer:=coalesce((runtime->>'enemy_immune_until')::integer,-1);enemy_stun integer:=coalesce((runtime->>'enemy_stun_until')::integer,-1);base_attack numeric;crossed boolean:=(p_enemy->>'realm_index')::integer=(p_stats->>'realm_index')::integer+1;has_ability boolean:=false;strong_ability boolean:=false;sword boolean;
BEGIN
 SELECT EXISTS(SELECT 1 FROM public.fc_equipment_instances WHERE character_id=p_character AND equipped_slot='weapon') INTO sword;
 SELECT consciousness INTO spirit FROM public.fc_characters WHERE id=p_character;
 SELECT EXISTS(SELECT 1 FROM public.fc_known_skills k JOIN public.fc_skill_definitions d ON d.id=k.skill_id WHERE k.character_id=p_character AND k.slot IS NOT NULL AND d.category='ability'),EXISTS(SELECT 1 FROM public.fc_known_skills k JOIN public.fc_skill_definitions d ON d.id=k.skill_id WHERE k.character_id=p_character AND k.slot IS NOT NULL AND d.category='ability' AND k.enhanced) INTO has_ability,strong_ability;
 IF crossed AND has_ability AND p_turn<(CASE WHEN strong_ability THEN 8 ELSE 5 END) THEN protection:=CASE WHEN strong_ability THEN .55 ELSE .35 END;END IF;
 IF shield_until<p_turn THEN shield:=0;END IF;
 FOR rec IN SELECT d.*,k.enhanced,k.slot FROM public.fc_known_skills k JOIN public.fc_skill_definitions d ON d.id=k.skill_id WHERE k.character_id=p_character AND k.slot IS NOT NULL ORDER BY d.category,k.slot LOOP
  fx:=CASE WHEN rec.enhanced THEN rec.enhanced_effects ELSE rec.effects END;
  cd:=(fx->>'cooldown')::integer;is_lethal:=coalesce((fx->>'lethal')::boolean,false);is_delayed:=coalesce((fx->>'delay')::integer,0)>0;
  last_tick:=coalesce((runtime->'used'->>rec.id)::integer,-99999);
  IF p_turn-last_tick<cd OR coalesce((fx->>'sword')::boolean,false) AND NOT sword THEN CONTINUE;END IF;
  IF fx ? 'threshold' AND health/hpmax>(fx->>'threshold')::numeric THEN CONTINUE;END IF;
  IF fx ? 'min_health' AND health/hpmax<(fx->>'min_health')::numeric THEN CONTINUE;END IF;
  IF is_lethal AND (incoming<health+shield OR coalesce((runtime->>'saved')::boolean,false)) THEN CONTINUE;END IF;
  IF is_lethal THEN runtime:=runtime||jsonb_build_object('saved',true);health:=greatest(health,1);incoming:=0;END IF;
  cost:=mpmax*coalesce((fx->>'cost')::numeric,0);spirit_cost:=(p_stats->>'consciousness_max')::numeric*coalesce((fx->>'spirit')::numeric,0);
  IF mana<cost OR spirit<spirit_cost THEN CONTINUE;END IF;
  mana:=mana-cost;spirit:=spirit-spirit_cost;
  runtime:=runtime||jsonb_build_object('used',coalesce(runtime->'used','{}'::jsonb)||jsonb_build_object(rec.id,p_turn));
  targets:=least(greatest(1,p_enemies),coalesce((fx->>'targets')::integer,1));
  base_attack:=greatest(1,atk-(p_enemy->>'base_defense')::numeric*.35*(1-least(.9,coalesce((fx->>'pierce')::numeric,0)+CASE WHEN crossed AND rec.category='ability' THEN CASE WHEN rec.enhanced THEN .35 ELSE .2 END ELSE 0 END)));
  amount:=base_attack*coalesce((fx->>'damage')::numeric,0)*targets;
  IF fx ? 'execute' AND p_enemy_health/p_enemy_max<.3 THEN amount:=amount*(fx->>'execute')::numeric;END IF;
  IF is_delayed THEN runtime:=runtime||jsonb_build_object('delayed',coalesce(runtime->'delayed','[]'::jsonb)||jsonb_build_array(jsonb_build_object('at',p_turn+(fx->>'delay')::integer,'damage',amount)));ELSE damage:=damage+amount;END IF;
  health:=least(hpmax,health+hpmax*coalesce((fx->>'heal')::numeric,0));mana:=least(mpmax,mana+mpmax*coalesce((fx->>'mana_restore')::numeric,0));
  IF fx ? 'shield' THEN shield:=greatest(shield,hpmax*(fx->>'shield')::numeric);shield_until:=greatest(shield_until,p_turn+coalesce((fx->>'duration')::integer,6));END IF;
  IF fx ? 'self_cost' THEN health:=greatest(1,health*(1-(fx->>'self_cost')::numeric));END IF;
  runtime:=runtime||jsonb_build_object('effects',coalesce(runtime->'effects','{}'::jsonb)||jsonb_build_object(rec.id,jsonb_build_object('until',p_turn+coalesce((fx->>'duration')::integer,1),'reduction',coalesce(fx->'reduction','0'),'boost',coalesce(fx->'boost','0'),'weaken',coalesce(fx->'weaken','0'),'lifesteal',coalesce(fx->'lifesteal','0'),'burn',coalesce(fx->'burn','0'))));
  IF fx ? 'cleanse' THEN runtime:=runtime||jsonb_build_object('cleansed_at',p_turn);END IF;
  stun:=coalesce((fx->>'stun')::integer,0);
  IF stun>0 AND immune<p_turn THEN enemy_stun:=p_turn+stun-1;immune:=enemy_stun+3;END IF;
  IF fx ? 'immunity' THEN runtime:=runtime||jsonb_build_object('immunity_until',p_turn+(fx->>'immunity')::integer);END IF;
  logs:=logs||jsonb_build_array(rec.name||CASE WHEN rec.enhanced THEN '·强化' ELSE '' END||' 发动，额外伤害'||round(amount)||'，消耗灵力'||round(cost));
 END LOOP;
 FOR rec IN SELECT value FROM jsonb_each(coalesce(runtime->'effects','{}')) LOOP
  IF (rec.value->>'until')::integer>p_turn THEN
   mitigation:=greatest(mitigation,(rec.value->>'reduction')::numeric);boost:=greatest(boost,(rec.value->>'boost')::numeric);weaken:=greatest(weaken,(rec.value->>'weaken')::numeric);lifesteal:=greatest(lifesteal,(rec.value->>'lifesteal')::numeric);
   damage:=damage+atk*(rec.value->>'burn')::numeric;
  END IF;
 END LOOP;
 FOR rec IN SELECT value FROM jsonb_array_elements(coalesce(runtime->'delayed','[]')) LOOP IF (rec.value->>'at')::integer=p_turn THEN damage:=damage+(rec.value->>'damage')::numeric;logs:=logs||jsonb_build_array('轮回印爆发');END IF;END LOOP;
 damage:=damage*(1+boost);health:=least(hpmax,health+damage*lifesteal);
 incoming:=incoming*(1-greatest(mitigation,protection))*(1-weaken);
 IF enemy_stun>=p_turn THEN incoming:=0;END IF;
 amount:=least(shield,incoming);shield:=shield-amount;incoming:=incoming-amount;
 runtime:=runtime||jsonb_build_object('shield',shield,'shield_until',shield_until,'enemy_stun_until',enemy_stun,'enemy_immune_until',immune);
 UPDATE public.fc_characters SET consciousness=greatest(0,spirit) WHERE id=p_character AND consciousness<>spirit;
 RETURN jsonb_build_object('damage',damage,'incoming',incoming,'health',health,'mana',mana,'runtime',runtime,'logs',logs);
END $$;
REVOKE ALL ON FUNCTION public.fc_skill_tick(uuid,jsonb,jsonb,jsonb,numeric,numeric,integer,numeric,numeric,numeric,integer) FROM PUBLIC,authenticated,anon;

CREATE FUNCTION public.fc_simulate_inner_demon(p_grade integer) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters;stats jsonb;base jsonb;enemy jsonb;runtime jsonb:='{}';ticks jsonb:='[]';effects jsonb;hp numeric;mana numeric;ehp numeric;ehpmax numeric;atk numeric;ea numeric;ed numeric;phmax numeric;damage numeric;incoming numeric;factor numeric:=1+(p_grade-1)*.0625;turn integer;art numeric:=1;modifier numeric:=1;
BEGIN
 SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE;
 stats:=public.fc_get_attributes()||jsonb_build_object('realm_index',c.realm_index);base:=public.fc_base_stats(c.realm_index,c.realm_layer,1);
 enemy:=jsonb_build_object('name','心魔','realm_index',c.realm_index,'base_health',(base->>'health')::numeric*factor,'base_attack',(base->>'attack')::numeric*factor,'base_defense',(base->>'defense')::numeric*factor,'speed',(base->>'speed')::numeric,'expansion_percent',(p_grade-1)*6.25);
 hp:=(stats->>'health')::numeric;phmax:=hp;mana:=(stats->>'mana')::numeric;ehp:=(enemy->>'base_health')::numeric;ehpmax:=ehp;ea:=(enemy->>'base_attack')::numeric;ed:=(enemy->>'base_defense')::numeric;atk:=(stats->>'attack')::numeric;
 IF EXISTS(SELECT 1 FROM public.fc_equipment_instances WHERE character_id=c.id AND equipped_slot='weapon') AND c.equipped_art IN ('nameless_sword','family_sword') THEN art:=CASE WHEN c.equipped_art='nameless_sword' THEN 2 ELSE 2.2 END;END IF;
 modifier:=1+CASE WHEN c.breakthrough_boost_until>now() THEN .10 ELSE 0 END+(public.fc_mind_effects(c.mind)->>'breakthrough_bonus')::numeric/100;
 FOR turn IN 0..119 LOOP
  damage:=greatest(1,atk-ed*.35)*art*modifier;incoming:=greatest(1,ea-(stats->>'defense')::numeric*.25);
  effects:=public.fc_skill_tick(c.id,stats,enemy,runtime,hp,mana,turn,incoming,ehp,ehpmax,1);
  runtime:=effects->'runtime';hp:=(effects->>'health')::numeric;mana:=(effects->>'mana')::numeric;damage:=damage+(effects->>'damage')::numeric;incoming:=(effects->>'incoming')::numeric;
  ehp:=greatest(0,ehp-damage);IF ehp=0 THEN incoming:=0;END IF;hp:=greatest(0,hp-incoming);
  ticks:=ticks||jsonb_build_array(jsonb_build_object('turn',turn+1,'player_health',hp,'monster_health',ehp,'damage',round(damage,2),'incoming',round(incoming,2),'logs',effects->'logs'));
  EXIT WHEN ehp=0 OR hp=0;
 END LOOP;
 RETURN jsonb_build_object('success',ehp=0,'name','心魔','avatar_key',c.avatar_key,'player_name',c.display_name,'player_health_max',phmax,'monster',enemy,'grade',p_grade,'turns',ticks);
END $$;
REVOKE ALL ON FUNCTION public.fc_simulate_inner_demon(integer) FROM PUBLIC,authenticated,anon;
CREATE OR REPLACE FUNCTION public.fc_breakthrough(p_grade integer DEFAULT 1, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$

DECLARE v_me public.fc_characters; v_uid text:=public.fc_require_uid(); v_result jsonb; v_major boolean; v_chance numeric; v_roll numeric; v_win boolean; v_extra numeric; v_realms text[]:=ARRAY['练气','筑基','金丹','元婴','出窍','化神']; v_layers text[]:=ARRAY['一','二','三','四','五','六','七','八','九']; v_log jsonb:='[]'::jsonb; v_old jsonb; v_new jsonb; v_bonus jsonb; v_changes jsonb:='{}'::jsonb; k text; v_delta numeric; v_extra_delta numeric; v_demon jsonb; v_cards jsonb;

BEGIN

 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=v_uid FOR UPDATE;

 IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;

 IF p_request_id IS NULL THEN RAISE EXCEPTION '缺少突破请求标识'; END IF;

 SELECT result INTO v_result FROM public.fc_breakthrough_records WHERE id=p_request_id AND character_id=v_me.id;

 IF v_result IS NOT NULL THEN RETURN jsonb_build_object('state',public.fc_get_state(),'trial',v_result); END IF;

 IF EXISTS(SELECT 1 FROM public.fc_breakthrough_records WHERE id=p_request_id) THEN RAISE EXCEPTION '请求标识无效'; END IF;

 IF p_grade NOT BETWEEN 1 AND 9 THEN RAISE EXCEPTION '品级必须在一至九品之间'; END IF;

 IF v_me.realm_index=5 AND v_me.realm_layer=9 THEN RAISE EXCEPTION '化神九层已达当前开放上限'; END IF;

 IF v_me.cultivation<v_me.capacity THEN RAISE EXCEPTION '修为不足本层突破上限'; END IF;

 IF EXISTS(SELECT 1 FROM public.fc_combat_encounters WHERE character_id=v_me.id AND status='active') OR EXISTS(SELECT 1 FROM public.fc_city_journeys WHERE character_id=v_me.id) OR EXISTS(SELECT 1 FROM public.fc_trial_locks WHERE character_id=v_me.id AND expires_at>now()) THEN RAISE EXCEPTION '战斗、旅行或心魔试炼中不能再次突破';END IF;
 IF v_me.lifespan<=1 THEN RAISE EXCEPTION '寿元不足，无法承受突破'; END IF;

 v_major:=v_me.realm_layer=9;

 v_extra:=v_me.expansion_ratio*100;

 IF v_major THEN
  v_demon:=public.fc_simulate_inner_demon(p_grade);v_win:=(v_demon->>'success')::boolean;v_chance:=CASE WHEN v_win THEN 100 ELSE 0 END;
  UPDATE public.fc_characters SET breakthrough_boost_until=NULL WHERE id=v_me.id;
  v_log:=jsonb_build_array('迎战'||p_grade||'级心魔，参考扩脉强度'||((p_grade-1)*6.25)||'%。');

 ELSE

  v_chance:=100;v_win:=true;

  v_log:=jsonb_build_array('灵气运转周天，冲击下一层修为。');

 END IF;

 IF v_win THEN

  v_old:=public.fc_base_stats(v_me.realm_index,v_me.realm_layer,v_me.realm_grade);

  v_new:=public.fc_base_stats(CASE WHEN v_major THEN v_me.realm_index+1 ELSE v_me.realm_index END,CASE WHEN v_major THEN 1 ELSE v_me.realm_layer+1 END,CASE WHEN v_major THEN p_grade ELSE v_me.realm_grade END);

  v_bonus:=v_me.expansion_stats;
  v_changes:=jsonb_build_object('base',jsonb_build_object(),'expansion',jsonb_build_object());
  FOREACH k IN ARRAY ARRAY['health','mana','attack','defense','speed','consciousness_max'] LOOP
   v_delta:=greatest(0,(v_new->>k)::numeric-(v_old->>k)::numeric);
   v_extra_delta:=v_delta*v_extra/100*(1+((CASE WHEN v_major THEN p_grade ELSE v_me.realm_grade END)-1)*.0625);
   v_bonus:=jsonb_set(v_bonus,ARRAY[k],to_jsonb(coalesce((v_bonus->>k)::numeric,0)+v_extra_delta));
   v_changes:=jsonb_set(v_changes,ARRAY['base',k],to_jsonb(round(v_delta,2)));
   v_changes:=jsonb_set(v_changes,ARRAY['expansion',k],to_jsonb(round(v_extra_delta,2)));
  END LOOP;
  UPDATE public.fc_characters SET expansion_stats=v_bonus WHERE id=v_me.id;

  IF v_major THEN
  UPDATE public.fc_characters SET breakthrough_boost_until=NULL WHERE id=v_me.id;

   UPDATE public.fc_characters SET mind=least(100,mind+5),realm_index=realm_index+1,realm_layer=1,realm_grade=p_grade,realm=v_realms[v_me.realm_index+2]||'一层',cultivation=0,last_claim_at=now(),attribute_bonus=attribute_bonus+v_extra,lifespan=lifespan+(ARRAY[100,300,500,1000,2000])[v_me.realm_index+1] WHERE id=v_me.id;

   v_log:=v_log||jsonb_build_array('击败判定妖魔，突破至'||v_realms[v_me.realm_index+2]||'一层，定为'||p_grade||'品。');

  ELSE

   UPDATE public.fc_characters SET realm_layer=realm_layer+1,realm=v_realms[v_me.realm_index+1]||v_layers[v_me.realm_layer+1]||'层',cultivation=greatest(0,v_me.cultivation-v_me.capacity)*public.fc_aura_requirement(v_me.realm_index,v_me.realm_layer)/public.fc_aura_requirement(v_me.realm_index,v_me.realm_layer+1),last_claim_at=now(),attribute_bonus=attribute_bonus+v_extra WHERE id=v_me.id;

   v_log:=v_log||jsonb_build_array('剩余灵气 '||round(greatest(0,v_me.cultivation-v_me.capacity)/100*public.fc_aura_requirement(v_me.realm_index,v_me.realm_layer),2)||' 点流入下一层。突破成功：'||v_realms[v_me.realm_index+1]||v_layers[v_me.realm_layer+1]||'层。');

  END IF;

 ELSE

  UPDATE public.fc_characters SET cultivation=greatest(0,cultivation-capacity*0.5),lifespan=greatest(1,lifespan-5),foundation=greatest(0,foundation-CASE WHEN p_grade>=7 THEN 5 ELSE 2 END),last_claim_at=now() WHERE id=v_me.id;

  v_log:=v_log||jsonb_build_array('妖魔压制了你的突破：损失本层所需灵气的50%、5年寿元，道基减少'||CASE WHEN p_grade>=7 THEN 5 ELSE 2 END||'点，境界保持不变。');

 END IF;

 v_result:=jsonb_build_object('success',v_win,'major',v_major,'grade',CASE WHEN v_major THEN p_grade ELSE v_me.realm_grade END,'chance',v_chance,'log',v_log,'changes',CASE WHEN v_win THEN v_changes ELSE '{}'::jsonb END,'demon',v_demon,'expansion_ratio',v_me.expansion_ratio,'grade_factor',1+((CASE WHEN v_major THEN p_grade ELSE v_me.realm_grade END)-1)*.0625);

 INSERT INTO public.fc_breakthrough_records(id,character_id,result) VALUES(p_request_id,v_me.id,v_result);

 IF v_major THEN INSERT INTO public.fc_trial_locks(character_id,expires_at) VALUES(v_me.id,now()+make_interval(secs=>least(30,jsonb_array_length(v_demon->'turns')))) ON CONFLICT(character_id) DO UPDATE SET expires_at=EXCLUDED.expires_at;END IF;
 IF v_major AND v_win THEN v_cards:=public.fc_generate_skill_choice(p_request_id,v_me.id,p_grade,v_me.realm_index+1);v_result:=v_result||jsonb_build_object('choice_id',p_request_id,'candidates',v_cards);UPDATE public.fc_breakthrough_records SET result=v_result WHERE id=p_request_id;END IF;
 INSERT INTO public.fc_notices(character_id,body) VALUES(v_me.id,v_log->>(jsonb_array_length(v_log)-1));

 RETURN jsonb_build_object('state',public.fc_get_state(),'trial',v_result);

END $function$;
CREATE OR REPLACE FUNCTION public.fc_resolve_combat(p_action text DEFAULT 'auto'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE c public.fc_characters; e public.fc_combat_encounters; m public.fc_monster_definitions; stats jsonb; damage numeric; incoming numeric; alive integer; crit boolean; sword boolean; hits numeric:=1; spirit_cost numeric; mana_cost numeric; skill_log text:=''; stun boolean:=false; skill_effects jsonb; skill_hp numeric; skill_mana numeric;
BEGIN
 SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE;
 IF c.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 SELECT * INTO e FROM public.fc_combat_encounters WHERE character_id=c.id AND status='active' LIMIT 1 FOR UPDATE;
 IF e.id IS NULL THEN RETURN public.fc_get_combat(); END IF;
 IF now()-e.tick_at<interval '1 second' THEN RETURN public.fc_get_combat(); END IF;
 SELECT * INTO m FROM public.fc_monster_definitions WHERE id=e.monster_id;
 stats:=public.fc_get_attributes()||jsonb_build_object('realm_index',c.realm_index); crit:=random()<0.05;
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
 skill_effects:=public.fc_skill_tick(c.id,stats,to_jsonb(m),e.skill_runtime,e.player_health,e.player_mana,e.turn,incoming,e.monster_health,m.base_health*e.monster_count,greatest(1,ceil(e.monster_health/m.base_health)::integer));
 damage:=damage+(skill_effects->>'damage')::numeric;incoming:=CASE WHEN damage>=e.monster_health THEN 0 ELSE (skill_effects->>'incoming')::numeric END;skill_hp:=(skill_effects->>'health')::numeric;skill_mana:=(skill_effects->>'mana')::numeric;
 UPDATE public.fc_combat_encounters SET tick_at=now(),turn=turn+1,skill_runtime=skill_effects->'runtime',player_mana=CASE WHEN hits>1 THEN greatest(0,skill_mana-mana_cost) ELSE skill_mana END,player_health=greatest(0,skill_hp-incoming),monster_health=greatest(0,monster_health-damage),battle_log=battle_log||(skill_effects->'logs')||jsonb_build_array('第'||(turn+1)||'回合：'||skill_log||' 造成'||round(damage)||'伤害，妖兽造成'||round(incoming)||'伤害。') WHERE id=e.id RETURNING * INTO e;
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
END $function$;

CREATE FUNCTION public.fc_guard_trial_movement() RETURNS trigger LANGUAGE plpgsql SET search_path=public,pg_temp AS $$
BEGIN IF NEW.cell_id IS DISTINCT FROM OLD.cell_id AND EXISTS(SELECT 1 FROM public.fc_trial_locks WHERE character_id=NEW.character_id AND expires_at>now()) THEN RAISE EXCEPTION '心魔试炼中不能移动';END IF;RETURN NEW;END $$;
CREATE TRIGGER guard_trial_movement BEFORE UPDATE OF cell_id ON public.fc_character_positions FOR EACH ROW EXECUTE FUNCTION public.fc_guard_trial_movement();
REVOKE ALL ON FUNCTION public.fc_guard_trial_movement() FROM PUBLIC,authenticated,anon;
DO $$ DECLARE d text; BEGIN d:=pg_get_functiondef('public.fc_spawn_combat()'::regprocedure);IF position('SELECT * INTO p FROM public.fc_character_positions' IN d)=0 THEN RAISE EXCEPTION 'Unexpected spawn signature';END IF;d:=replace(d,'SELECT * INTO p FROM public.fc_character_positions', 'IF EXISTS(SELECT 1 FROM public.fc_trial_locks WHERE character_id=c.id AND expires_at>now()) THEN RETURN jsonb_build_object(''active'',false);END IF; SELECT * INTO p FROM public.fc_character_positions');EXECUTE d;END $$;
