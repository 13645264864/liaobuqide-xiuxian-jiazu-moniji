ALTER TABLE public.fc_world_rooms ADD COLUMN field_level smallint CHECK(field_level BETWEEN 1 AND 3);
CREATE TABLE public.fc_field_plots(cell_id uuid PRIMARY KEY REFERENCES public.fc_world_cells(id),tilled boolean NOT NULL DEFAULT false,crop text CHECK(crop='bamboo'),planted_at timestamptz,planted_by uuid REFERENCES public.fc_characters(id));
ALTER TABLE public.fc_field_plots ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.fc_field_plots FROM PUBLIC,authenticated,anon;

CREATE FUNCTION public.fc_ensure_field_layers(p_family uuid) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE base public.fc_world_rooms; r1 uuid;r2 uuid;r3 uuid;r uuid;i integer;door uuid;other_door uuid;
BEGIN
 SELECT * INTO base FROM public.fc_world_rooms WHERE family_id=p_family AND template_id='10000000-0000-0000-0000-000000000022';
 IF base.id IS NULL THEN RETURN;END IF;
 r1:=base.id;r2:=md5(p_family::text||':field:2')::uuid;r3:=md5(p_family::text||':field:3')::uuid;
 UPDATE public.fc_world_rooms SET field_level=1,name='家族灵田·第一层' WHERE id=r1 AND field_level IS DISTINCT FROM 1;
 FOR i IN 2..3 LOOP
 r:=CASE WHEN i=2 THEN r2 ELSE r3 END;
 INSERT INTO public.fc_world_rooms(id,state_name,city_name,name,kind,description,family_id,city_id,is_safe_city,region_depth,field_level)
 VALUES(r,base.state_name,base.city_name,'家族灵田·'||CASE WHEN i=2 THEN '第二层' ELSE '第三层' END,'building','种植竹子：先松土，再种植，10分钟成熟。',p_family,base.city_id,true,'city',i) ON CONFLICT DO NOTHING;
 INSERT INTO public.fc_world_cells(id,room_id,x,y,terrain) SELECT md5(r::text||':'||x||':'||y)::uuid,r,x,y,'field' FROM generate_series(-1,1)x CROSS JOIN generate_series(-1,1)y ON CONFLICT DO NOTHING;
 END LOOP;
 -- Use the south-centre portal cell for every exit so eight other cells remain plots.
 SELECT id INTO door FROM public.fc_world_cells WHERE room_id=r1 AND x=0 AND y=1;
 SELECT id INTO other_door FROM public.fc_world_cells WHERE room_id=r2 AND x=0 AND y=1;
 INSERT INTO public.fc_world_exits VALUES(door,'north',other_door) ON CONFLICT(from_cell,direction) DO UPDATE SET to_cell=EXCLUDED.to_cell;
 INSERT INTO public.fc_world_exits VALUES(other_door,'south',door) ON CONFLICT(from_cell,direction) DO UPDATE SET to_cell=EXCLUDED.to_cell;
 door:=other_door;SELECT id INTO other_door FROM public.fc_world_cells WHERE room_id=r3 AND x=0 AND y=1;
 INSERT INTO public.fc_world_exits VALUES(door,'north',other_door) ON CONFLICT(from_cell,direction) DO UPDATE SET to_cell=EXCLUDED.to_cell;
 INSERT INTO public.fc_world_exits VALUES(other_door,'south',door) ON CONFLICT(from_cell,direction) DO UPDATE SET to_cell=EXCLUDED.to_cell;
 -- Higher realms use a direct third-layer portal, since second-layer entry is exclusive.
 INSERT INTO public.fc_world_exits(from_cell,direction,to_cell) SELECT a.id,'east',b.id FROM public.fc_world_cells a,public.fc_world_cells b WHERE a.room_id=r1 AND a.x=0 AND a.y=1 AND b.room_id=r3 AND b.x=0 AND b.y=1 ON CONFLICT(from_cell,direction) DO UPDATE SET to_cell=EXCLUDED.to_cell;
 INSERT INTO public.fc_world_exits(from_cell,direction,to_cell) SELECT a.id,'west',b.id FROM public.fc_world_cells a,public.fc_world_cells b WHERE a.room_id=r3 AND a.x=0 AND a.y=1 AND b.room_id=r1 AND b.x=0 AND b.y=1 ON CONFLICT(from_cell,direction) DO UPDATE SET to_cell=EXCLUDED.to_cell;
 INSERT INTO public.fc_field_plots(cell_id) SELECT cell.id FROM public.fc_world_cells cell WHERE cell.room_id IN(r1,r2,r3) AND NOT(cell.x=0 AND cell.y=1) ON CONFLICT DO NOTHING;
END $$;
REVOKE ALL ON FUNCTION public.fc_ensure_field_layers(uuid) FROM PUBLIC,authenticated,anon;
SELECT public.fc_ensure_field_layers(id) FROM public.fc_families;

CREATE FUNCTION public.fc_field_access_guard() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters;r public.fc_world_rooms;
BEGIN
 SELECT * INTO c FROM public.fc_characters WHERE id=NEW.character_id;
 SELECT room.* INTO r FROM public.fc_world_cells cell JOIN public.fc_world_rooms room ON room.id=cell.room_id WHERE cell.id=NEW.cell_id;
 IF r.field_level IS NOT NULL THEN
 IF r.family_id IS DISTINCT FROM c.family_id THEN RAISE EXCEPTION '你不是本家族成员';END IF;
 IF r.field_level=2 AND c.realm_index NOT IN(2,3) THEN RAISE EXCEPTION '灵田第二层只允许金丹、元婴修士进入';END IF;
 IF r.field_level=3 AND c.realm_index NOT IN(4,5) THEN RAISE EXCEPTION '灵田第三层只允许出窍、化神修士进入';END IF;
 END IF;RETURN NEW;
END $$;
CREATE TRIGGER field_access_guard BEFORE INSERT OR UPDATE OF cell_id ON public.fc_character_positions FOR EACH ROW EXECUTE FUNCTION public.fc_field_access_guard();
REVOKE ALL ON FUNCTION public.fc_field_access_guard() FROM PUBLIC,authenticated,anon;

CREATE FUNCTION public.fc_get_field() RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters;r public.fc_world_rooms;
BEGIN
 SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid();
 SELECT room.* INTO r FROM public.fc_character_positions pos JOIN public.fc_world_cells cell ON cell.id=pos.cell_id JOIN public.fc_world_rooms room ON room.id=cell.room_id WHERE pos.character_id=c.id;
 IF r.field_level IS NULL OR r.family_id IS DISTINCT FROM c.family_id THEN RAISE EXCEPTION '请前往本族灵田';END IF;
 RETURN jsonb_build_object('room_id',r.id,'level',r.field_level,'has_hoe',EXISTS(SELECT 1 FROM public.fc_inventory_slots WHERE character_id=c.id AND item_key='farm_hoe' AND quantity>0),'seeds',coalesce((SELECT sum(quantity) FROM public.fc_inventory_slots WHERE character_id=c.id AND item_key='bamboo_seed'),0),'plots',coalesce((SELECT jsonb_agg(to_jsonb(p)||jsonb_build_object('ready',p.planted_at IS NOT NULL AND p.planted_at<=now()-interval '10 minutes','remaining',CASE WHEN p.planted_at IS NULL THEN 0 ELSE greatest(0,ceil(extract(epoch FROM p.planted_at+interval '10 minutes'-now()))) END)) FROM public.fc_field_plots p JOIN public.fc_world_cells cell ON cell.id=p.cell_id WHERE cell.room_id=r.id),'[]'::jsonb));
END $$;

CREATE FUNCTION public.fc_field_action(p_cell uuid,p_action text,p_crop text DEFAULT 'bamboo') RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE c public.fc_characters;plot public.fc_field_plots;r public.fc_world_rooms;msg text;level_min integer;
BEGIN
 SELECT * INTO c FROM public.fc_characters WHERE owner_id=public.fc_require_uid() FOR UPDATE;
 IF c.id IS NULL THEN RAISE EXCEPTION '请先入世';END IF;
 SELECT room.* INTO r FROM public.fc_world_cells cell JOIN public.fc_world_rooms room ON room.id=cell.room_id WHERE cell.id=p_cell;
 IF r.field_level IS NULL OR r.family_id IS DISTINCT FROM c.family_id THEN RAISE EXCEPTION '不是本族灵田';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.fc_character_positions WHERE character_id=c.id AND cell_id=p_cell) THEN RAISE EXCEPTION '请先走到这块灵田';END IF;
 IF (r.field_level=2 AND c.realm_index NOT IN(2,3)) OR (r.field_level=3 AND c.realm_index NOT IN(4,5)) THEN RAISE EXCEPTION '境界不符合本层灵田要求';END IF;
 IF EXISTS(SELECT 1 FROM public.fc_combat_encounters WHERE character_id=c.id AND status='active') OR EXISTS(SELECT 1 FROM public.fc_city_journeys WHERE character_id=c.id) OR EXISTS(SELECT 1 FROM public.fc_trial_locks WHERE character_id=c.id AND expires_at>now()) THEN RAISE EXCEPTION '旅行或战斗中不能种植';END IF;
 SELECT * INTO plot FROM public.fc_field_plots WHERE cell_id=p_cell FOR UPDATE;
 IF plot.cell_id IS NULL THEN RAISE EXCEPTION '入口格不能种植';END IF;
 IF p_action='till' THEN
 IF plot.tilled THEN RAISE EXCEPTION '已松土';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.fc_inventory_slots WHERE character_id=c.id AND item_key='farm_hoe' AND quantity>0) THEN RAISE EXCEPTION '需要先制造一把锄头';END IF;
 UPDATE public.fc_field_plots SET tilled=true WHERE cell_id=p_cell;msg:='松土完成，可以种植作物。';
 ELSIF p_action='plant' THEN
 IF NOT plot.tilled THEN RAISE EXCEPTION '请先用锄头松土';END IF;
 IF plot.crop IS NOT NULL THEN RAISE EXCEPTION '这里已经种了作物';END IF;
 IF p_crop<>'bamboo' THEN RAISE EXCEPTION '目前只能种植竹子';END IF;
 PERFORM public.fc_inventory_take(c.id,'bamboo_seed',1);
 UPDATE public.fc_field_plots SET crop='bamboo',planted_at=now(),planted_by=c.id WHERE cell_id=p_cell;msg:='竹子种植成功，10分钟后成熟。';
 ELSIF p_action='harvest' THEN
 IF plot.crop IS NULL OR plot.planted_at>now()-interval '10 minutes' THEN RAISE EXCEPTION '竹子尚未成熟';END IF;
 PERFORM public.fc_inventory_add(c.id,'bamboo','竹子',3,'材料','灵田竹子，可加工纸材。');
 PERFORM public.fc_inventory_add(c.id,'bamboo_seed','竹子种子',2,'种子','每颗种植一次，10分钟成熟，收获3根竹子和2颗种子。');
 UPDATE public.fc_field_plots SET crop=NULL,planted_at=NULL,planted_by=NULL WHERE cell_id=p_cell;msg:='收获3根竹子和2颗竹子种子。';
 ELSE RAISE EXCEPTION '种植操作无效';END IF;
 RETURN jsonb_build_object('message',msg,'field',public.fc_get_field());
END $$;
REVOKE ALL ON FUNCTION public.fc_get_field(),public.fc_field_action(uuid,text,text) FROM PUBLIC,anon;
GRANT EXECUTE ON FUNCTION public.fc_get_field(),public.fc_field_action(uuid,text,text) TO authenticated;

INSERT INTO public.fc_recipes(id,name,profession,realm_min,spirit_cost,ingredients,output_key,output_name,output_category,description,success_rate,output_quantity) VALUES
('farm_hoe','制造锄头','smith',0,2,'{"ore_0":2}','farm_hoe','锄头','工具','2份练气灵矿石制成，灵田松土工具，可重复使用。',100,1),
('bamboo_fiber','竹子加工纸材','talisman',0,2,'{"bamboo":1}','fiber_0','练气纸材纤维','材料','1根竹子加工3份纸材，再用于制作符纸。',100,3);
DO $patch$ DECLARE d text;BEGIN
 d:=pg_get_functiondef('public.fc_get_home_entrances()'::regprocedure);
 IF position('PERFORM public.fc_ensure_mine_layers(me.family_id);' IN d)=0 THEN RAISE EXCEPTION 'Home entry signature changed';END IF;
 d:=replace(d,'PERFORM public.fc_ensure_mine_layers(me.family_id);','PERFORM public.fc_ensure_mine_layers(me.family_id);PERFORM public.fc_ensure_field_layers(me.family_id);');EXECUTE d;
 d:=pg_get_functiondef('public.fc_check_home_access(uuid)'::regprocedure);
 d:=replace(d,'RETURN jsonb_build_object(', 'IF r.field_level=2 AND me.realm_index NOT IN(2,3) THEN RAISE EXCEPTION ''灵田第二层只允许金丹、元婴'';END IF;IF r.field_level=3 AND me.realm_index NOT IN(4,5) THEN RAISE EXCEPTION ''灵田第三层只允许出窍、化神'';END IF; RETURN jsonb_build_object(');EXECUTE d;
 d:=pg_get_functiondef('public.fc_craft(text)'::regprocedure);
 d:=replace(d,'''forge_anvil'',''forge_hammer'',''forge_furnace''','''forge_anvil'',''forge_hammer'',''forge_furnace'',''farm_hoe''');
 d:=replace(d,'success:=random()*100<chance;','IF recipe.id IN (''farm_hoe'',''bamboo_fiber'') THEN chance:=100;END IF;success:=random()*100<chance;');EXECUTE d;
 d:=pg_get_functiondef('public.fc_begin_gather(text)'::regprocedure);
 d:=replace(d,'IF kind NOT IN', 'IF kind=''fiber'' THEN RAISE EXCEPTION ''纸材需要种竹子收获，再到制造加工'';END IF; IF kind NOT IN');EXECUTE d;
 d:=pg_get_functiondef('public.fc_finish_gather_internal(text)'::regprocedure);
 IF position('UPDATE public.fc_characters SET gathering_at=now()' IN d)=0 THEN RAISE EXCEPTION 'Gather signature changed';END IF;
 -- Include seed chance even on unsuccessful herb searches; random is server-only.
 d:=replace(d,'UPDATE public.fc_characters SET gathering_at=now()', 'IF p_kind=''herb'' AND random()<.10 THEN PERFORM public.fc_inventory_add(c.id,''bamboo_seed'',''竹子种子'',1,''种子'',''可种在本族灵田，10分钟成熟。'');message:=message||'' 获得1颗竹子种子。'';END IF; UPDATE public.fc_characters SET gathering_at=now()');EXECUTE d;
END $patch$;
