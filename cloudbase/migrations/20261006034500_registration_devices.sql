CREATE TABLE public.fc_registration_devices (
  device_id text PRIMARY KEY CHECK (char_length(device_id) BETWEEN 8 AND 200),
  user_uid text NOT NULL UNIQUE,
  platform text NOT NULL CHECK (platform IN ('android','web')),
  ip_hash text NOT NULL,
  registered_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX fc_registration_ip ON public.fc_registration_devices(ip_hash, registered_at DESC);
ALTER TABLE public.fc_registration_devices ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.fc_registration_devices FROM anon, authenticated;
