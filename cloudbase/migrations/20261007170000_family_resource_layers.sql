ALTER TABLE public.fc_world_rooms ADD COLUMN mine_level smallint CHECK(mine_level BETWEEN 1 AND 3);
ALTER TABLE public.fc_combat_encounters ADD COLUMN herb_reward_key text,ADD COLUMN herb_reward_name text;
CREATE FUNCTION public.fc_ensure_mine_layers(p_family uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE base public.fc_world_rooms; previous_room uuid; new_room uuid; layer integer;
BEGIN
 SELECT * INTO base FROM public.fc_world_rooms WHERE family_id=p_family AND template_id='10000000-0000-0000-0000-000000000021';
 IF base.id IS NULL THEN RETURN; END IF;
 UPDATE public.fc_world_rooms SET mine_level=1,name='家族灵矿·第一层' WHERE id=base.id;
 previous_room:=base.id;
 FOR layer IN 2..3 LOOP
  new_room:=md5(p_family::text||':mine:'||layer)::uuid;
  INSERT INTO public.fc_world_rooms(id,state_name,city_name,name,kind,description,family_id,city_id,is_safe_city,region_depth,mine_level)
  VALUES(new_room,base.state_name,base.city_name,CASE layer WHEN 2 THEN '家族灵矿·第二层' ELSE '家族灵矿·第三层' END,'building',CASE layer WHEN 2 THEN '金丹及以上可进入；40%金丹矿、10%元婴矿、50%废矿。' ELSE '出窍及以上可进入；40%出窍矿、10%化神矿、50%废矿。' END,p_family,base.city_id,true,'city',layer) ON CONFLICT DO NOTHING;
  INSERT INTO public.fc_world_cells(id,room_id,x,y,terrain) SELECT md5(new_room::text||':'||x||':'||y)::uuid,new_room,x,y,'mine' FROM generate_series(-1,1) x CROSS JOIN generate_series(-1,1) y ON CONFLICT DO NOTHING;
  INSERT INTO public.fc_world_exits(from_cell,direction,to_cell) SELECT a.id,'south',b.id FROM public.fc_world_cells a,public.fc_world_cells b WHERE a.room_id=previous_room AND a.x=0 AND a.y=1 AND b.room_id=new_room AND b.x=0 AND b.y=-1 ON CONFLICT DO NOTHING;
  INSERT INTO public.fc_world_exits(from_cell,direction,to_cell) SELECT b.id,'north',a.id FROM public.fc_world_cells a,public.fc_world_cells b WHERE a.room_id=previous_room AND a.x=0 AND a.y=1 AND b.room_id=new_room AND b.x=0 AND b.y=-1 ON CONFLICT DO NOTHING;
  previous_room:=new_room;
 END LOOP;
END $$;
REVOKE ALL ON FUNCTION public.fc_ensure_mine_layers(uuid) FROM PUBLIC;
SELECT public.fc_ensure_mine_layers(id) FROM public.fc_families WHERE city_id IS NOT NULL;
CREATE FUNCTION public.fc_get_home_entrances() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE me public.fc_characters; city integer;
BEGIN
 SELECT * INTO me FROM public.fc_characters WHERE owner_id=public.fc_require_uid(); IF me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 PERFORM public.fc_ensure_mine_layers(me.family_id);
 SELECT r.city_id INTO city FROM public.fc_character_positions p JOIN public.fc_world_cells c ON c.id=p.cell_id JOIN public.fc_world_rooms r ON r.id=c.room_id WHERE p.character_id=me.id;
 RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('id',r.id,'name',r.name,'mine_level',r.mine_level,'own_family',r.family_id=me.family_id)) FROM public.fc_world_rooms r JOIN public.fc_families f ON f.id=r.family_id WHERE f.city_id IS NOT NULL AND (r.template_id='10000000-0000-0000-0000-000000000001' AND r.city_id=city OR r.family_id=me.family_id AND r.mine_level IS NOT NULL)),'[]'::jsonb);
END $$;
CREATE FUNCTION public.fc_check_home_access(p_room uuid) RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE me public.fc_characters; r public.fc_world_rooms;
BEGIN
 SELECT * INTO me FROM public.fc_characters WHERE owner_id=public.fc_require_uid(); SELECT * INTO r FROM public.fc_world_rooms WHERE id=p_room;
 IF r.id IS NULL THEN RAISE EXCEPTION '地点不存在'; END IF;
 IF r.family_id IS NOT NULL AND r.family_id IS DISTINCT FROM me.family_id THEN RAISE EXCEPTION '你不是本家族成员'; END IF;
 IF r.mine_level IS NOT NULL AND me.realm_index<(r.mine_level-1)*2 THEN RAISE EXCEPTION '该矿层需要%及以上境界',CASE r.mine_level WHEN 2 THEN '金丹' ELSE '出窍' END; END IF;
 RETURN jsonb_build_object('allowed',true);
END $$;
-- Enforce membership/minimum realm for all moves, not just the UI entry.
CREATE FUNCTION public.fc_resource_position_guard() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE me public.fc_characters; r public.fc_world_rooms;
BEGIN
 SELECT * INTO me FROM public.fc_characters WHERE id=NEW.character_id;
 SELECT room.* INTO r FROM public.fc_world_cells cell JOIN public.fc_world_rooms room ON room.id=cell.room_id WHERE cell.id=NEW.cell_id;
 IF r.family_id IS NOT NULL AND r.family_id IS DISTINCT FROM me.family_id THEN RAISE EXCEPTION '你不是本家族成员'; END IF;
 IF r.mine_level IS NOT NULL AND me.realm_index<(r.mine_level-1)*2 THEN RAISE EXCEPTION '境界不足，第二层需金丹，第三层需出窍'; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER resource_position_guard BEFORE INSERT OR UPDATE OF cell_id ON public.fc_character_positions FOR EACH ROW EXECUTE FUNCTION public.fc_resource_position_guard();
CREATE OR REPLACE FUNCTION public.fc_gather(p_kind text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters; r public.fc_world_rooms; tier integer; roll numeric; m public.fc_monster_definitions; message text; herb_name text; eid uuid;
BEGIN
 SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE;
 IF c.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 SELECT room.* INTO r FROM public.fc_character_positions p JOIN public.fc_world_cells cell ON cell.id=p.cell_id JOIN public.fc_world_rooms room ON room.id=cell.room_id WHERE p.character_id=c.id;
 IF EXISTS(SELECT 1 FROM public.fc_city_journeys WHERE character_id=c.id) OR EXISTS(SELECT 1 FROM public.fc_combat_encounters WHERE character_id=c.id AND status='active') THEN RAISE EXCEPTION '旅行或战斗中不能采集'; END IF;
 IF c.gathering_at>now()-interval '30 seconds' THEN RAISE EXCEPTION '采集冷却30秒'; END IF;
 IF p_kind='ore' THEN
  IF r.family_id IS DISTINCT FROM c.family_id OR r.mine_level IS NULL THEN RAISE EXCEPTION '请前往本族灵矿的对应矿层'; END IF;
  IF c.realm_index<(r.mine_level-1)*2 THEN RAISE EXCEPTION '境界不足'; END IF;
  roll:=random();tier:=(r.mine_level-1)*2;
  IF roll<0.4 THEN NULL; ELSIF roll<0.5 THEN tier:=tier+1; ELSE tier:=-1; END IF;
  IF tier=-1 THEN PERFORM public.fc_inventory_add(c.id,'waste_ore','废矿与碎石',1,'杂物','采矿所得，无装备制作价值。');message:='采到了废矿与碎石。';
  ELSE message:=(ARRAY['练气','筑基','金丹','元婴','出窍','化神'])[tier+1]||'灵矿石'; PERFORM public.fc_inventory_add(c.id,'ore_'||tier,message,1,'材料','宗族矿层产出，装备材料。');message:='获得1份'||message; END IF;
 ELSIF p_kind='herb' THEN
  IF r.kind<>'forest' OR r.is_safe_city THEN RAISE EXCEPTION '灵草采集请前往森林等野外刷怪区'; END IF;
  tier:=CASE r.region_depth WHEN 'inner' THEN 2 WHEN 'core' THEN 4 ELSE 0 END;
  IF c.realm_index<tier THEN RAISE EXCEPTION '境界不足，无法进入本区域采集'; END IF;
  roll:=random();
  IF roll>=0.5 THEN message:='未找到可采灵草，只有枯草。';
  ELSE
   IF roll>=0.4 THEN tier:=tier+1; END IF;
   SELECT * INTO m FROM public.fc_monster_definitions WHERE realm_index=tier ORDER BY random() LIMIT 1;
   IF m.id IS NULL THEN message:='发现高阶灵草，但对应守草妖兽尚未开放，本次未获得灵草。';
   ELSE
    herb_name:=(ARRAY['练气','筑基','金丹','元婴','出窍','化神'])[tier+1]||'灵草';
    INSERT INTO public.fc_combat_encounters(character_id,room_id,monster_id,monster_count,player_health,monster_health,herb_reward_key,herb_reward_name)
    VALUES(c.id,r.id,m.id,1,(public.fc_get_attributes()->>'health')::numeric,m.base_health,'herb_'||tier,herb_name) RETURNING id INTO eid;
    message:='发现'||herb_name||'，被'||m.name||'守护；战斗胜利后才能获得。';
   END IF;
  END IF;
 ELSIF p_kind='fiber' THEN
  IF r.family_id IS DISTINCT FROM c.family_id OR r.template_id IS DISTINCT FROM '10000000-0000-0000-0000-000000000022'::uuid THEN RAISE EXCEPTION '纸材需前往本族灵田采集'; END IF;
  tier:=least(2,c.realm_index);PERFORM public.fc_inventory_add(c.id,'fiber_'||tier,(ARRAY['练气','筑基','金丹'])[tier+1]||'纸材纤维',3,'材料');message:='获得3份纸材纤维。';
 ELSE RAISE EXCEPTION '采集类型无效'; END IF;
 UPDATE public.fc_characters SET gathering_at=now() WHERE id=c.id;
 RETURN jsonb_build_object('message',message,'workshop',public.fc_get_workshop());
END $$;
CREATE FUNCTION public.fc_guarded_herb_reward() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 IF OLD.status='active' AND NEW.status='won' AND NEW.herb_reward_key IS NOT NULL THEN
  PERFORM public.fc_inventory_add(NEW.character_id,NEW.herb_reward_key,NEW.herb_reward_name,1,'材料','击败守草妖兽后获得。');
  NEW.battle_log:=NEW.battle_log||jsonb_build_array('守草妖兽已击败，获得1份'||NEW.herb_reward_name);
 END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER guarded_herb_reward BEFORE UPDATE OF status ON public.fc_combat_encounters FOR EACH ROW EXECUTE FUNCTION public.fc_guarded_herb_reward();
REVOKE ALL ON FUNCTION public.fc_get_home_entrances(),public.fc_check_home_access(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fc_get_home_entrances(),public.fc_check_home_access(uuid) TO authenticated;
