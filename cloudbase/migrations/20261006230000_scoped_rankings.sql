ALTER TABLE public.fc_characters ADD COLUMN spirit_stones bigint NOT NULL DEFAULT 0 CHECK(spirit_stones>=0);
CREATE FUNCTION public.fc_get_rankings(p_board text DEFAULT 'power',p_scope text DEFAULT 'continent') RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_me public.fc_characters; v_state integer; v_rows jsonb; v_my_rank bigint;
BEGIN
 SELECT * INTO v_me FROM public.fc_characters WHERE owner_id=public.fc_require_uid();
 IF v_me.id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 IF p_board NOT IN ('power','realm','wealth','family') OR p_scope NOT IN ('family','state','continent') THEN RAISE EXCEPTION '榜单或范围无效'; END IF;
 SELECT ct.state_id INTO v_state FROM public.fc_families f JOIN public.fc_cities ct ON ct.id=f.city_id WHERE f.id=v_me.family_id;
 IF p_board='family' THEN
 WITH families AS (
 SELECT f.id,f.name,f.level,f.prestige,count(c.id) AS members,coalesce(sum(public.fc_character_power(c)),0) AS score,st.name AS state_name
 FROM public.fc_families f JOIN public.fc_cities ct ON ct.id=f.city_id JOIN public.fc_states st ON st.id=ct.state_id LEFT JOIN public.fc_characters c ON c.family_id=f.id
 WHERE (p_scope='continent' OR p_scope='family' AND f.id=v_me.family_id OR p_scope='state' AND ct.state_id=v_state)
 GROUP BY f.id,st.name
 ), ranked AS (SELECT *,dense_rank() OVER(ORDER BY score DESC) AS rank FROM families), limited AS (SELECT * FROM ranked ORDER BY score DESC,name,id LIMIT 100)
 SELECT coalesce(jsonb_agg(to_jsonb(limited) ORDER BY score DESC,name,id),'[]'::jsonb) INTO v_rows FROM limited;
 ELSE
 WITH players AS (
 SELECT c.id,c.display_name AS name,c.realm,c.realm_index,c.realm_layer,c.realm_grade,c.spirit_stones,public.fc_character_power(c) AS power,f.name AS family_name,st.name AS state_name,
 CASE p_board WHEN 'power' THEN public.fc_character_power(c) WHEN 'wealth' THEN c.spirit_stones ELSE c.realm_index*10000+c.realm_layer*100+c.realm_grade END AS score
 FROM public.fc_characters c JOIN public.fc_families f ON f.id=c.family_id JOIN public.fc_cities ct ON ct.id=f.city_id JOIN public.fc_states st ON st.id=ct.state_id
 WHERE (p_scope='continent' OR p_scope='family' AND c.family_id=v_me.family_id OR p_scope='state' AND ct.state_id=v_state)
 ), ranked AS (SELECT *,dense_rank() OVER(ORDER BY score DESC) AS rank FROM players), limited AS (SELECT * FROM ranked ORDER BY score DESC,name,id LIMIT 100)
 SELECT coalesce(jsonb_agg(to_jsonb(limited) ORDER BY score DESC,name,id),'[]'::jsonb) INTO v_rows FROM limited;
 END IF;
 RETURN jsonb_build_object('board',p_board,'scope',p_scope,'scope_name',CASE p_scope WHEN 'family' THEN (SELECT name FROM public.fc_families WHERE id=v_me.family_id) WHEN 'state' THEN (SELECT name FROM public.fc_states WHERE id=v_state) ELSE '全大陆' END,'self_id',CASE WHEN p_board='family' THEN v_me.family_id ELSE v_me.id END,'rows',v_rows);
END $$;
REVOKE ALL ON FUNCTION public.fc_get_rankings(text,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fc_get_rankings(text,text) TO authenticated;
