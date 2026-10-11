-- Align existing rooms to the Xuzhou template without replacing identities,
-- player positions, names, ownership, or inter-city roads.
CREATE TEMP TABLE layout_room_map ON COMMIT DROP AS
SELECT target.id AS target_room, source.id AS source_room, target.city_id,
       target.family_id
FROM public.fc_world_rooms target JOIN public.fc_world_rooms source
 ON source.family_id IS NULL AND source.city_id=1
 AND source.id=target.template_id
WHERE target.template_id IS NOT NULL AND target.template_id<>'10000000-0000-0000-0000-000000000004'
UNION ALL
SELECT target.id,source.id,target.city_id,target.family_id
FROM public.fc_world_rooms target JOIN public.fc_world_rooms source
 ON source.city_id=1 AND source.family_id IS NULL AND source.kind='forest'
 AND source.region_depth=target.region_depth
WHERE target.city_id<>1 AND target.family_id IS NULL AND target.kind='forest';

-- Preserve cell IDs and any interactive terrain (such as family_statue).
INSERT INTO public.fc_world_cells(id,room_id,x,y,terrain)
SELECT md5(m.target_room::text||':repair:'||s.x||':'||s.y)::uuid,m.target_room,s.x,s.y,s.terrain
FROM layout_room_map m JOIN public.fc_world_cells s ON s.room_id=m.source_room
WHERE NOT EXISTS(SELECT 1 FROM public.fc_world_cells c WHERE c.room_id=m.target_room AND c.x=s.x AND c.y=s.y);

CREATE TEMP TABLE layout_expected_exits ON COMMIT DROP AS
SELECT a.id AS from_cell,e.direction,b.id AS to_cell
FROM layout_room_map sm
JOIN public.fc_world_cells original_a ON original_a.room_id=sm.source_room
JOIN public.fc_world_exits e ON e.from_cell=original_a.id
JOIN public.fc_world_cells original_b ON original_b.id=e.to_cell
JOIN layout_room_map dm ON dm.source_room=original_b.room_id
 AND dm.city_id=sm.city_id AND dm.family_id IS NOT DISTINCT FROM sm.family_id
JOIN public.fc_world_cells a ON a.room_id=sm.target_room AND a.x=original_a.x AND a.y=original_a.y
JOIN public.fc_world_cells b ON b.room_id=dm.target_room AND b.x=original_b.x AND b.y=original_b.y;

INSERT INTO public.fc_world_exits(from_cell,direction,to_cell)
SELECT DISTINCT from_cell,direction,to_cell FROM layout_expected_exits
ON CONFLICT(from_cell,direction) DO UPDATE SET to_cell=EXCLUDED.to_cell;

-- Family-home doors are city-local. Public streets choose the caller's home
-- dynamically; they must never be hard-wired to a different family's home.
INSERT INTO public.fc_world_exits(from_cell,direction,to_cell)
SELECT a.id,'south',b.id FROM public.fc_world_rooms home
JOIN public.fc_families f ON f.id=home.family_id
JOIN public.fc_world_cells a ON a.room_id=home.id AND a.x=0 AND a.y=1
JOIN public.fc_world_rooms street ON street.city_id=f.city_id AND street.family_id IS NULL
 AND (street.template_id='10000000-0000-0000-0000-000000000005' OR street.id='10000000-0000-0000-0000-000000000005')
JOIN public.fc_world_cells b ON b.room_id=street.id AND b.x=0 AND b.y=-1
WHERE home.template_id='10000000-0000-0000-0000-000000000001'
ON CONFLICT(from_cell,direction) DO UPDATE SET to_cell=EXCLUDED.to_cell;

CREATE OR REPLACE FUNCTION public.fc_player_next_cell(p_cell uuid,p_direction text)
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE cell public.fc_world_cells;room public.fc_world_rooms;family uuid;target uuid;
BEGIN
 SELECT * INTO cell FROM public.fc_world_cells WHERE id=p_cell;
 SELECT * INTO room FROM public.fc_world_rooms WHERE id=cell.room_id;
 SELECT family_id INTO family FROM public.fc_characters WHERE owner_id=public.fc_require_uid();
 IF cell.x=0 AND cell.y=-1 AND p_direction='north' AND room.family_id IS NULL
 AND (room.template_id='10000000-0000-0000-0000-000000000005' OR room.id='10000000-0000-0000-0000-000000000005')
 AND room.city_id=(SELECT city_id FROM public.fc_families WHERE id=family) THEN
 SELECT c.id INTO target FROM public.fc_world_rooms h JOIN public.fc_world_cells c ON c.room_id=h.id
 WHERE h.family_id=family AND h.template_id='10000000-0000-0000-0000-000000000001' AND c.x=0 AND c.y=1;
 IF target IS NOT NULL THEN RETURN target;END IF;
 END IF;
 IF cell.x=0 AND cell.y=1 AND p_direction='south' AND room.family_id=family
 AND room.template_id='10000000-0000-0000-0000-000000000001' THEN
 SELECT c.id INTO target FROM public.fc_world_rooms s JOIN public.fc_world_cells c ON c.room_id=s.id
 WHERE s.family_id IS NULL AND s.city_id=room.city_id
 AND (s.template_id='10000000-0000-0000-0000-000000000005' OR s.id='10000000-0000-0000-0000-000000000005') AND c.x=0 AND c.y=-1;
 IF target IS NOT NULL THEN RETURN target;END IF;
 END IF;
 RETURN public.fc_world_next_cell(p_cell,p_direction);
END $$;
REVOKE ALL ON FUNCTION public.fc_player_next_cell(uuid,text) FROM PUBLIC,anon;

-- Patch only the navigation edge expression and append the dynamic home door
-- to displayed exits. Do not replace the world-state function body.
DO $patch$
DECLARE definition text;old_expression text;new_expression text;anchor text;
BEGIN
 definition:=pg_get_functiondef('public.fc_get_world_state()'::regprocedure);
 old_expression:='CASE WHEN c.room_id=''10000000-0000-0000-0000-000000000005'' AND c.x=0 AND c.y=-1 AND d.direction=''north'' THEN (SELECT id FROM public.fc_world_cells WHERE room_id=v_home AND x=0 AND y=1) ELSE public.fc_world_next_cell(c.id,d.direction) END';
 IF position(old_expression IN definition)=0 THEN RAISE EXCEPTION 'Unexpected navigation expression, abort';END IF;
 definition:=replace(definition,old_expression,'public.fc_player_next_cell(c.id,d.direction)');
 anchor:='''exits'',coalesce(';
 IF position(anchor IN definition)=0 THEN RAISE EXCEPTION 'Unexpected exits expression, abort';END IF;
 new_expression:='''exits'',CASE WHEN v_room.family_id IS NULL AND (v_room.template_id=''10000000-0000-0000-0000-000000000005'' OR v_room.id=''10000000-0000-0000-0000-000000000005'') AND v_room.city_id=(SELECT city_id FROM public.fc_families WHERE id=v_me.family_id) THEN jsonb_build_array(jsonb_build_object(''from_cell'',(SELECT id FROM public.fc_world_cells WHERE room_id=v_room.id AND x=0 AND y=-1),''x'',0,''y'',-1,''direction'',''north'',''to_room'',(SELECT name FROM public.fc_world_rooms WHERE id=v_home))) ELSE ''[]''::jsonb END || coalesce(';
 definition:=replace(definition,anchor,new_expression);EXECUTE definition;
END $patch$;

-- All existing families get the same three-layer mine chain.
SELECT public.fc_ensure_mine_layers(id) FROM public.fc_families;
