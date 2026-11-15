do $$ begin create role anon nologin; exception when duplicate_object then null; end $$; do $$ begin create role authenticated nologin; exception when duplicate_object then null; end $$;
create schema extensions; create schema auth; create schema cron; create schema net; create schema storage;
create extension pgcrypto with schema extensions;
create table auth.users(id uuid primary key, email text, raw_user_meta_data jsonb, encrypted_password text, banned_until timestamptz, last_sign_in_at timestamptz);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.uid', true),'')::uuid $$;
grant usage on schema auth, extensions, public to authenticated, anon;
grant execute on function auth.uid() to authenticated, anon;
create publication supabase_realtime;
-- postgis falso: ponto como texto "lng lat", distância haversine em metros
create domain extensions.geography as text;
create function extensions.st_makepoint(x double precision, y double precision) returns text language sql immutable as $$ select x||' '||y $$;
create function extensions.st_setsrid(g text, s int) returns text language sql immutable as $$ select g $$;
create function extensions.st_distance(a text, b text) returns double precision language sql immutable as $$
  select 6371000*2*asin(sqrt(power(sin(radians(split_part(b,' ',2)::float-split_part(a,' ',2)::float)/2),2)
    + cos(radians(split_part(a,' ',2)::float))*cos(radians(split_part(b,' ',2)::float))*power(sin(radians(split_part(b,' ',1)::float-split_part(a,' ',1)::float)/2),2))) $$;
create function cron.schedule(a text, b text, c text) returns bigint language sql as $$ select 1::bigint $$;
create function net.http_post(url text, body jsonb default null, params jsonb default null, headers jsonb default null, timeout_milliseconds int default null) returns bigint language sql as $$ select 1::bigint $$;
create table storage.buckets(id text primary key, name text, public boolean, file_size_limit bigint, allowed_mime_types text[]);
create table storage.objects(id uuid default gen_random_uuid(), bucket_id text, name text, owner uuid);
alter table storage.objects enable row level security;
create function storage.foldername(n text) returns text[] language sql immutable as $$ select string_to_array(n,'/') $$;
create function cron.unschedule(a text) returns boolean language sql as $$ select true $$;
do $$ begin create role service_role; exception when others then null; end $$;
