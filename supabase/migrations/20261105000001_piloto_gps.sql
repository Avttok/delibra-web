-- =====================================================================
-- PW Express · Migração 0001 · Piloto do rastreamento GPS
-- ---------------------------------------------------------------------
-- Como aplicar: Supabase > SQL Editor > New query > colar tudo > Run.
-- É seguro rodar de novo: tudo usa "if not exists" / "or replace".
-- =====================================================================

create extension if not exists postgis with schema extensions;

-- ---------------------------------------------------------------------
-- Tipos
-- ---------------------------------------------------------------------
do $$ begin
  create type public.papel_usuario as enum ('gestor', 'motoboy', 'cliente');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.status_motoboy as enum ('offline', 'disponivel', 'em_corrida');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------
-- Perfis: 1 linha por usuário do Supabase Auth.
-- Um usuário pode ter vários papéis (ex.: gestor que também testa como motoboy).
-- ---------------------------------------------------------------------
create table if not exists public.perfis (
  id         uuid primary key references auth.users (id) on delete cascade,
  nome       text not null default '',
  papeis     public.papel_usuario[] not null default '{}',
  criado_em  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Motoboys: estado atual (1 linha por motoboy). É o que o mapa do gestor
-- escuta em tempo real e o que o despacho vai consultar por proximidade.
-- ---------------------------------------------------------------------
create table if not exists public.motoboys (
  id             uuid primary key references public.perfis (id) on delete cascade,
  status         public.status_motoboy not null default 'offline',
  modo_economia  boolean not null default false,
  lat            double precision,
  lng            double precision,
  precisao_m     real,
  bateria        smallint,
  posicao        extensions.geography(Point, 4326) generated always as (
                   case when lat is null or lng is null then null
                   else extensions.st_setsrid(extensions.st_makepoint(lng, lat), 4326)::extensions.geography
                   end
                 ) stored,
  posicao_em     timestamptz,
  status_em      timestamptz not null default now(),
  versao_app     text
);

create index if not exists motoboys_posicao_gix on public.motoboys using gist (posicao);
create index if not exists motoboys_status_idx  on public.motoboys (status);

-- ---------------------------------------------------------------------
-- Localizações: tabela "quente" de pontos GPS.
-- Na fase de corridas, os pontos de cada corrida concluída serão
-- compactados numa polyline e apagados daqui.
-- ---------------------------------------------------------------------
create table if not exists public.localizacoes (
  id             bigint generated always as identity primary key,
  motoboy_id     uuid not null references public.motoboys (id) on delete cascade,
  id_local       uuid not null,               -- gerado no celular; evita duplicar em reenvios
  sessao_id      uuid,                         -- agrupa um período "em corrida"
  corrida_id     uuid,                         -- preenchido na fase de corridas
  status         public.status_motoboy not null,
  lat            double precision not null,
  lng            double precision not null,
  precisao_m     real,
  velocidade_ms  real,
  direcao_graus  real,
  altitude_m     real,
  bateria        smallint,
  registrado_em  timestamptz not null,         -- hora do GPS no celular
  recebido_em    timestamptz not null default now(),
  unique (motoboy_id, id_local)
);

create index if not exists localizacoes_motoboy_tempo_idx on public.localizacoes (motoboy_id, registrado_em desc);
create index if not exists localizacoes_sessao_idx        on public.localizacoes (sessao_id, registrado_em);

-- ---------------------------------------------------------------------
-- Helpers de papel
-- ---------------------------------------------------------------------
create or replace function public.tem_papel(p public.papel_usuario)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.perfis
    where id = auth.uid() and p = any (papeis)
  );
$$;

create or replace function public.is_gestor()
returns boolean
language sql stable security definer set search_path = ''
as $$ select public.tem_papel('gestor'::public.papel_usuario); $$;

-- ---------------------------------------------------------------------
-- Perfil criado automaticamente para todo novo usuário
-- ---------------------------------------------------------------------
create or replace function public.criar_perfil_novo_usuario()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.perfis (id, nome)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'nome', split_part(new.email, '@', 1), ''))
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists ao_criar_usuario on auth.users;
create trigger ao_criar_usuario
  after insert on auth.users
  for each row execute function public.criar_perfil_novo_usuario();

-- ---------------------------------------------------------------------
-- RPC: motoboy muda de estado (offline / disponivel / em_corrida)
-- ---------------------------------------------------------------------
create or replace function public.atualizar_status(
  p_status        public.status_motoboy,
  p_modo_economia boolean default false,
  p_versao_app    text default null
)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'nao_autenticado' using errcode = '28000';
  end if;
  if not public.tem_papel('motoboy'::public.papel_usuario) then
    raise exception 'usuario_nao_e_motoboy' using errcode = '42501';
  end if;

  insert into public.motoboys (id, status, modo_economia, versao_app, status_em)
  values (v_uid, p_status, p_modo_economia, p_versao_app, now())
  on conflict (id) do update
    set status        = excluded.status,
        modo_economia = excluded.modo_economia,
        versao_app    = coalesce(excluded.versao_app, public.motoboys.versao_app),
        status_em     = now();
end;
$$;

-- ---------------------------------------------------------------------
-- RPC: lote de pontos GPS enviado pelo app (fila offline → servidor)
-- pontos = [{ id_local, sessao_id, corrida_id, status, lat, lng,
--             precisao_m, velocidade_ms, direcao_graus, altitude_m,
--             bateria, registrado_em }, ...]
-- Retorna quantos pontos novos foram gravados.
-- ---------------------------------------------------------------------
create or replace function public.registrar_localizacoes(pontos jsonb)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid      uuid := auth.uid();
  v_inseridos integer := 0;
  v_ultimo   jsonb;
begin
  if v_uid is null then
    raise exception 'nao_autenticado' using errcode = '28000';
  end if;
  if not public.tem_papel('motoboy'::public.papel_usuario) then
    raise exception 'usuario_nao_e_motoboy' using errcode = '42501';
  end if;
  if pontos is null or jsonb_typeof(pontos) <> 'array' or jsonb_array_length(pontos) = 0 then
    return 0;
  end if;
  if jsonb_array_length(pontos) > 500 then
    raise exception 'lote_grande_demais' using errcode = '22023';
  end if;

  -- garante a linha do motoboy
  insert into public.motoboys (id) values (v_uid) on conflict (id) do nothing;

  insert into public.localizacoes (
    motoboy_id, id_local, sessao_id, corrida_id, status, lat, lng,
    precisao_m, velocidade_ms, direcao_graus, altitude_m, bateria, registrado_em
  )
  select
    v_uid,
    (p ->> 'id_local')::uuid,
    nullif(p ->> 'sessao_id', '')::uuid,
    nullif(p ->> 'corrida_id', '')::uuid,
    (p ->> 'status')::public.status_motoboy,
    (p ->> 'lat')::double precision,
    (p ->> 'lng')::double precision,
    (p ->> 'precisao_m')::real,
    (p ->> 'velocidade_ms')::real,
    (p ->> 'direcao_graus')::real,
    (p ->> 'altitude_m')::real,
    (p ->> 'bateria')::smallint,
    (p ->> 'registrado_em')::timestamptz
  from jsonb_array_elements(pontos) as p
  on conflict (motoboy_id, id_local) do nothing;

  get diagnostics v_inseridos = row_count;

  -- atualiza a "posição atual" com o ponto mais recente do lote
  select p into v_ultimo
  from jsonb_array_elements(pontos) as p
  order by (p ->> 'registrado_em')::timestamptz desc
  limit 1;

  update public.motoboys
     set lat        = (v_ultimo ->> 'lat')::double precision,
         lng        = (v_ultimo ->> 'lng')::double precision,
         precisao_m = (v_ultimo ->> 'precisao_m')::real,
         bateria    = (v_ultimo ->> 'bateria')::smallint,
         posicao_em = (v_ultimo ->> 'registrado_em')::timestamptz
   where id = v_uid
     and (posicao_em is null or posicao_em < (v_ultimo ->> 'registrado_em')::timestamptz);

  return v_inseridos;
end;
$$;

-- ---------------------------------------------------------------------
-- Segurança (RLS): ninguém escreve direto nas tabelas; escrita só pelas RPCs.
-- Leitura: cada um vê o próprio; gestor vê tudo.
-- ---------------------------------------------------------------------
alter table public.perfis       enable row level security;
alter table public.motoboys     enable row level security;
alter table public.localizacoes enable row level security;

drop policy if exists perfis_leitura on public.perfis;
create policy perfis_leitura on public.perfis
  for select to authenticated
  using (id = (select auth.uid()) or (select public.is_gestor()));

drop policy if exists motoboys_leitura on public.motoboys;
create policy motoboys_leitura on public.motoboys
  for select to authenticated
  using (id = (select auth.uid()) or (select public.is_gestor()));

drop policy if exists localizacoes_leitura on public.localizacoes;
create policy localizacoes_leitura on public.localizacoes
  for select to authenticated
  using (motoboy_id = (select auth.uid()) or (select public.is_gestor()));

revoke all on public.perfis, public.motoboys, public.localizacoes from anon;
grant select on public.perfis, public.motoboys, public.localizacoes to authenticated;

revoke all on function public.atualizar_status(public.status_motoboy, boolean, text) from public, anon;
revoke all on function public.registrar_localizacoes(jsonb) from public, anon;
grant execute on function public.atualizar_status(public.status_motoboy, boolean, text) to authenticated;
grant execute on function public.registrar_localizacoes(jsonb) to authenticated;
grant execute on function public.tem_papel(public.papel_usuario) to authenticated;
grant execute on function public.is_gestor() to authenticated;

-- ---------------------------------------------------------------------
-- Tempo real: o mapa do gestor escuta essas duas tabelas
-- ---------------------------------------------------------------------
do $$ begin
  alter publication supabase_realtime add table public.motoboys;
exception when duplicate_object then null; end $$;

do $$ begin
  alter publication supabase_realtime add table public.localizacoes;
exception when duplicate_object then null; end $$;
