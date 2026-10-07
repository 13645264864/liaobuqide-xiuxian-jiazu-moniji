-- Preserve escape routes for characters who entered a deep area before the gate.
DO $patch$
DECLARE definition text;
BEGIN
 definition:=pg_get_functiondef('public.fc_move_world(text)'::regprocedure);
 definition:=replace(definition,'target.region_depth=''inner'' AND v_me.realm_index<2',
 'target.region_depth=''inner'' AND v_me.realm_index<2 AND target.id<>current.id AND current.region_depth<>''core''');
 definition:=replace(definition,'target.region_depth=''core'' AND v_me.realm_index<4',
 'target.region_depth=''core'' AND v_me.realm_index<4 AND target.id<>current.id');
 EXECUTE definition;
END $patch$;

UPDATE public.fc_world_rooms
SET name=replace(name,'森林','野外'),description=replace(description,'森林','野外')
WHERE name LIKE '%森林%' OR description LIKE '%森林%';
