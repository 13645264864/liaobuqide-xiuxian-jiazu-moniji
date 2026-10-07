-- Only public outdoor encounter rates; no functions or navigation are changed.
UPDATE public.fc_world_rooms SET encounter_rate=0.50 WHERE kind='wilderness' AND family_id IS NULL AND NOT is_safe_city AND encounter_rate>0;
UPDATE public.fc_world_rooms SET encounter_rate=0.80 WHERE kind='forest' AND family_id IS NULL AND NOT is_safe_city;
