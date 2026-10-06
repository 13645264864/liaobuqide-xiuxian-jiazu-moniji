CREATE OR REPLACE FUNCTION public.fc_founder_city_before_insert() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE founder boolean; free integer;
BEGIN
 SELECT is_founder INTO founder FROM public.fc_characters WHERE id=NEW.leader_id;
 IF founder THEN
  -- A surviving clan keeps its city; a replacement founder receives an unoccupied city.
  SELECT ct.id INTO free FROM public.fc_cities ct WHERE NOT EXISTS(SELECT 1 FROM public.fc_families WHERE city_id=ct.id) ORDER BY ct.id LIMIT 1;
  IF free IS NULL THEN RAISE EXCEPTION '暂无空闲立族城池'; END IF;
  NEW.city_id:=free;
 END IF;
 RETURN NEW;
END $$;
