-- Complement the encounter guard with server-side movement cancellation and
-- bounded gathering tickets, so cancelling or disconnecting cannot grant immunity.
CREATE OR REPLACE FUNCTION public.fc_cancel_gather() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 UPDATE public.fc_characters SET gathering_started_at=NULL,gathering_room=NULL,gathering_kind=NULL WHERE owner_id=public.fc_require_uid();
 RETURN jsonb_build_object('message','已停止采集');
END $$;
REVOKE ALL ON FUNCTION public.fc_cancel_gather() FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.fc_cancel_gather() TO authenticated;

CREATE OR REPLACE FUNCTION public.fc_cancel_gather_on_move() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE previous_room uuid; next_room uuid;
BEGIN
 SELECT room_id INTO previous_room FROM public.fc_world_cells WHERE id=OLD.cell_id;
 SELECT room_id INTO next_room FROM public.fc_world_cells WHERE id=NEW.cell_id;
 IF previous_room IS DISTINCT FROM next_room THEN
  UPDATE public.fc_characters SET gathering_started_at=NULL,gathering_room=NULL,gathering_kind=NULL WHERE id=NEW.character_id;
 END IF;
 RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION public.fc_cancel_gather_on_move() FROM PUBLIC,authenticated,anon;
CREATE TRIGGER cancel_gather_on_move AFTER UPDATE OF cell_id ON public.fc_character_positions
FOR EACH ROW EXECUTE FUNCTION public.fc_cancel_gather_on_move();

-- Limit normal-encounter protection to a live ticket in the current room.
DO $patch$
DECLARE definition text;
BEGIN
 definition:=pg_get_functiondef('public.fc_spawn_combat()'::regprocedure);
 IF position('IF c.gathering_started_at IS NOT NULL THEN' IN definition)=0 THEN RAISE EXCEPTION 'Unexpected spawn function; aborting'; END IF;
 definition:=replace(definition,'IF c.gathering_started_at IS NOT NULL THEN',
 'IF c.gathering_kind=''herb'' AND c.gathering_room=r.id AND c.gathering_started_at>now()-interval ''30 seconds'' THEN');
 EXECUTE definition;
END $patch$;

CREATE OR REPLACE FUNCTION public.fc_finish_gather_internal(p_kind text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters; r public.fc_world_rooms; tier integer; roll numeric; m public.fc_monster_definitions; message text; herb_name text; eid uuid;
BEGIN
 SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE;
 IF c.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 SELECT room.* INTO r FROM public.fc_character_positions p JOIN public.fc_world_cells cell ON cell.id=p.cell_id JOIN public.fc_world_rooms room ON room.id=cell.room_id WHERE p.character_id=c.id;
 IF EXISTS(SELECT 1 FROM public.fc_city_journeys WHERE character_id=c.id) OR EXISTS(SELECT 1 FROM public.fc_combat_encounters WHERE character_id=c.id AND status='active') THEN RAISE EXCEPTION '旅行或战斗中不能采集'; END IF;
 IF c.gathering_at>now()-interval '10 seconds' THEN RAISE EXCEPTION '采集冷却10秒'; END IF;
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
    INSERT INTO public.fc_combat_encounters(character_id,room_id,monster_id,monster_count,player_health,monster_health,herb_reward_key,herb_reward_name,battle_log)
    VALUES(c.id,r.id,m.id,1,(public.fc_get_attributes()->>'health')::numeric,m.base_health,'herb_'||tier,herb_name,jsonb_build_array('采摘完成，惊动了守草妖兽；击败它后取得'||herb_name)) RETURNING id INTO eid;
    message:='采摘完成，惊动了守草妖兽'||m.name||'！击败它后取得'||herb_name||'。';
   END IF;
  END IF;
 ELSIF p_kind='fiber' THEN
  IF r.family_id IS DISTINCT FROM c.family_id OR r.template_id IS DISTINCT FROM '10000000-0000-0000-0000-000000000022'::uuid THEN RAISE EXCEPTION '纸材需前往本族灵田采集'; END IF;
  tier:=least(2,c.realm_index);PERFORM public.fc_inventory_add(c.id,'fiber_'||tier,(ARRAY['练气','筑基','金丹'])[tier+1]||'纸材纤维',3,'材料');message:='获得3份纸材纤维。';
 ELSE RAISE EXCEPTION '采集类型无效'; END IF;
 UPDATE public.fc_characters SET gathering_at=now() WHERE id=c.id;
 RETURN jsonb_build_object('message',message,'workshop',public.fc_get_workshop());
END $$;

REVOKE ALL ON FUNCTION public.fc_finish_gather_internal(text) FROM PUBLIC,authenticated,anon;
