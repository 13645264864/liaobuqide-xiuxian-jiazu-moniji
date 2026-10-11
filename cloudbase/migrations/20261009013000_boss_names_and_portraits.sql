-- Cosmetic Boss update; keep identifiers, combat values and loot unchanged.
UPDATE public.fc_monster_definitions SET name='黑纹妖猪王',image_path='monsters/boss_qi_boar.png' WHERE id='realm_boss_0' AND realm_index=0 AND is_boss;
UPDATE public.fc_monster_definitions SET name='幽影毒蛛',image_path='monsters/boss_foundation_spider.png' WHERE id='realm_boss_1' AND realm_index=1 AND is_boss;
UPDATE public.fc_monster_definitions SET name='赤炎金猊',image_path='monsters/boss_core_lion.png' WHERE id='realm_boss_2' AND realm_index=2 AND is_boss;
UPDATE public.fc_monster_definitions SET name='九霄雷鹏',image_path='monsters/boss_nascent_thunderbird.png' WHERE id='realm_boss_3' AND realm_index=3 AND is_boss;
UPDATE public.fc_monster_definitions SET name='虚空吞天蟒',image_path='monsters/boss_outbody_serpent.png' WHERE id='realm_boss_4' AND realm_index=4 AND is_boss;
UPDATE public.fc_monster_definitions SET name='太古混沌兽',image_path='monsters/boss_deity_chaos.png' WHERE id='realm_boss_5' AND realm_index=5 AND is_boss;
