CREATE TABLE public.fc_inventory_slots(character_id uuid NOT NULL REFERENCES public.fc_characters(id),slot integer NOT NULL CHECK(slot BETWEEN 1 AND 200),item_key text NOT NULL,item_name text NOT NULL,quantity integer NOT NULL CHECK(quantity>0),category text NOT NULL DEFAULT '其他',description text NOT NULL DEFAULT '',PRIMARY KEY(character_id,slot));
ALTER TABLE public.fc_inventory_slots ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.fc_inventory_slots FROM anon,authenticated;
CREATE FUNCTION public.fc_get_inventory() RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE v_id uuid;
BEGIN
 SELECT id INTO v_id FROM public.fc_characters WHERE owner_id=public.fc_require_uid();
 IF v_id IS NULL THEN RAISE EXCEPTION '请先入世'; END IF;
 RETURN jsonb_build_object('capacity',200,'used',(SELECT count(*) FROM public.fc_inventory_slots WHERE character_id=v_id),'items',coalesce((SELECT jsonb_agg(to_jsonb(i) ORDER BY slot) FROM public.fc_inventory_slots i WHERE character_id=v_id),'[]'::jsonb));
END $$;
REVOKE ALL ON FUNCTION public.fc_get_inventory() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fc_get_inventory() TO authenticated;
