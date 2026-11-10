-- =====================================================================
-- PW Express · Migração 0002 · Corridas, despacho e comprovantes
-- ---------------------------------------------------------------------
-- Pré-requisito: migração 0001 aplicada.
-- Como aplicar: SQL Editor > New query > colar tudo > Run.
-- Seguro rodar de novo.
-- =====================================================================

create extension if not exists pg_net;
create extension if not exists pg_cron;

-- ---------------------------------------------------------------------
-- Configuração privada (segredos do servidor). Ninguém do app/site lê.
-- ---------------------------------------------------------------------
create schema if not exists privado;
revoke all on schema privado from public, anon, authenticated;

create table if not exists privado.config (
  chave text primary key,
  valor text not null
);

-- segredo que o banco usa para chamar o site (rota /api/push)
insert into privado.config (chave, valor)
values ('push_secret', encode(extensions.gen_random_bytes(24), 'hex'))
on conflict (chave) do nothing;

-- ---------------------------------------------------------------------
-- Tipos
-- ---------------------------------------------------------------------
do $$ begin create type public.status_corrida as enum
  ('aguardando_motoboy', 'sem_motoboy', 'aceita', 'em_andamento', 'concluida', 'cancelada');
exception when duplicate_object then null; end $$;

do $$ begin create type public.tipo_parada as enum ('coleta', 'entrega');
exception when duplicate_object then null; end $$;

do $$ begin create type public.status_parada as enum ('pendente', 'a_caminho', 'chegou', 'concluida');
exception when duplicate_object then null; end $$;

do $$ begin create type public.modo_despacho as enum ('direto', 'cascata');
exception when duplicate_object then null; end $$;

do $$ begin create type public.status_oferta as enum ('pendente', 'aceita', 'recusada', 'expirada', 'cancelada');
exception when duplicate_object then null; end $$;

do $$ begin create type public.modalidade_preco as enum ('por_km', 'fixo', 'por_zona');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------
-- Empresas (clientes) e motoboys favoritos
-- ---------------------------------------------------------------------
create table if not exists public.empresas (
  id                 uuid primary key default gen_random_uuid(),
  nome               text not null,
  cnpj               text unique,
  modalidade_preco   public.modalidade_preco not null default 'por_km',
  valor_km           numeric(10, 2) not null default 2.00,
  valor_fixo         numeric(10, 2),
  cliente_ve_ao_vivo boolean not null default false,
  observacoes        text,
  criado_em          timestamptz not null default now()
);

create table if not exists public.empresa_favoritos (
  empresa_id  uuid not null references public.empresas (id) on delete cascade,
  motoboy_id  uuid not null references public.motoboys (id) on delete cascade,
  ordem       int not null default 0,
  primary key (empresa_id, motoboy_id)
);

-- ---------------------------------------------------------------------
-- Corridas
-- ---------------------------------------------------------------------
create table if not exists public.corridas (
  id                     uuid primary key default gen_random_uuid(),
  numero                 bigint generated always as identity unique,
  empresa_id             uuid references public.empresas (id) on delete set null,
  criada_por             uuid references public.perfis (id) on delete set null,
  status                 public.status_corrida not null default 'aguardando_motoboy',
  modo_despacho          public.modo_despacho not null default 'cascata',
  motoboy_designado_id   uuid references public.motoboys (id) on delete set null,
  motoboy_id             uuid references public.motoboys (id) on delete set null,
  rodada                 int not null default 1,
  exige_foto             boolean not null default false,
  exige_assinatura       boolean not null default false,
  exige_nome             boolean not null default false,
  exige_codigo           boolean not null default false,
  codigo_entrega         text,
  distancia_planejada_m  int,
  duracao_planejada_s    int,
  rota_planejada         text,              -- polyline (precisão 5)
  valor                  numeric(10, 2),
  distancia_real_m       int,
  trajeto                text,              -- polyline do caminho real
  observacoes            text,
  criada_em              timestamptz not null default now(),
  aceita_em              timestamptz,
  iniciada_em            timestamptz,
  concluida_em           timestamptz,
  cancelada_em           timestamptz,
  compactada_em          timestamptz
);

create index if not exists corridas_status_idx  on public.corridas (status);
create index if not exists corridas_motoboy_idx on public.corridas (motoboy_id, status);

create table if not exists public.paradas (
  id               uuid primary key default gen_random_uuid(),
  corrida_id       uuid not null references public.corridas (id) on delete cascade,
  ordem            int not null,
  tipo             public.tipo_parada not null,
  endereco         text not null,
  lat              double precision not null,
  lng              double precision not null,
  contato_nome     text,
  contato_telefone text,
  instrucoes       text,
  status           public.status_parada not null default 'pendente',
  chegou_em        timestamptz,
  concluida_em     timestamptz,
  recebedor_nome   text,
  foto_path        text,
  assinatura_path  text,
  unique (corrida_id, ordem)
);

create table if not exists public.ofertas (
  id             uuid primary key default gen_random_uuid(),
  corrida_id     uuid not null references public.corridas (id) on delete cascade,
  motoboy_id     uuid not null references public.motoboys (id) on delete cascade,
  rodada         int not null default 1,
  distancia_m    int,
  status         public.status_oferta not null default 'pendente',
  criada_em      timestamptz not null default now(),
  expira_em      timestamptz not null,
  respondida_em  timestamptz
);

create unique index if not exists ofertas_uma_pendente_por_corrida
  on public.ofertas (corrida_id) where status = 'pendente';
create index if not exists ofertas_motoboy_idx on public.ofertas (motoboy_id, status);

create table if not exists public.eventos_corrida (
  id          bigint generated always as identity primary key,
  corrida_id  uuid not null references public.corridas (id) on delete cascade,
  tipo        text not null,
  dados       jsonb not null default '{}',
  autor       uuid,
  criado_em   timestamptz not null default now()
);
create index if not exists eventos_corrida_idx on public.eventos_corrida (corrida_id, criado_em);

-- token do celular para notificações (privado: só as funções do servidor leem)
create table if not exists privado.fcm_tokens (
  motoboy_id    uuid primary key references public.motoboys (id) on delete cascade,
  token         text not null unique,
  atualizado_em timestamptz not null default now()
);

-- =====================================================================
-- Funções internas
-- =====================================================================

create or replace function privado.evento(p_corrida uuid, p_tipo text, p_dados jsonb default '{}')
returns void language sql security definer set search_path = '' as $$
  insert into public.eventos_corrida (corrida_id, tipo, dados, autor)
  values (p_corrida, p_tipo, coalesce(p_dados, '{}'), auth.uid());
$$;

-- Envia push (FCM) pelo site. Falha silenciosa: o app também consulta ao abrir.
create or replace function privado.enviar_push(p_motoboy uuid, p_dados jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_token  text;
  v_url    text;
  v_secret text;
begin
  select token into v_token from privado.fcm_tokens where motoboy_id = p_motoboy;
  select valor into v_url    from privado.config where chave = 'push_url';
  select valor into v_secret from privado.config where chave = 'push_secret';
  if v_token is null or v_url is null or v_secret is null then return; end if;

  perform net.http_post(
    url     := v_url,
    body    := jsonb_build_object('token', v_token, 'data', p_dados),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-pwex-secret', v_secret),
    timeout_milliseconds := 5000
  );
exception when others then
  raise warning 'enviar_push falhou: %', sqlerrm;
end;
$$;

-- Dados da corrida para o app (sem o código de entrega)
create or replace function privado.corrida_json(p_corrida uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', c.id,
    'numero', c.numero,
    'status', c.status,
    'valor', c.valor,
    'distancia_planejada_m', c.distancia_planejada_m,
    'duracao_planejada_s', c.duracao_planejada_s,
    'observacoes', c.observacoes,
    'exige_foto', c.exige_foto,
    'exige_assinatura', c.exige_assinatura,
    'exige_nome', c.exige_nome,
    'exige_codigo', c.exige_codigo,
    'empresa_nome', e.nome,
    'paradas', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id, 'ordem', p.ordem, 'tipo', p.tipo, 'endereco', p.endereco,
        'lat', p.lat, 'lng', p.lng, 'contato_nome', p.contato_nome,
        'contato_telefone', p.contato_telefone, 'instrucoes', p.instrucoes, 'status', p.status
      ) order by p.ordem)
      from public.paradas p where p.corrida_id = c.id
    ), '[]'::jsonb)
  )
  from public.corridas c
  left join public.empresas e on e.id = c.empresa_id
  where c.id = p_corrida;
$$;

-- Escolhe o próximo motoboy e cria a oferta (30 s para responder)
create or replace function privado.despachar(p_corrida uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  c            public.corridas%rowtype;
  v_coleta     extensions.geography;
  v_motoboy    uuid;
  v_dist       double precision;
  v_oferta     uuid;
  v_expira     timestamptz := now() + interval '30 seconds';
begin
  select * into c from public.corridas where id = p_corrida for update;
  if not found or c.status not in ('aguardando_motoboy', 'sem_motoboy') then return; end if;
  if exists (select 1 from public.ofertas where corrida_id = p_corrida and status = 'pendente') then return; end if;

  select extensions.st_setsrid(extensions.st_makepoint(lng, lat), 4326)::extensions.geography
    into v_coleta
    from public.paradas where corrida_id = p_corrida order by ordem limit 1;

  if c.modo_despacho = 'direto' then
    if c.motoboy_designado_id is not null and not exists (
      select 1 from public.ofertas
      where corrida_id = p_corrida and motoboy_id = c.motoboy_designado_id and rodada = c.rodada
    ) then
      v_motoboy := c.motoboy_designado_id;
      select extensions.st_distance(m.posicao, v_coleta) into v_dist from public.motoboys m where m.id = v_motoboy;
    end if;
  else
    select m.id, extensions.st_distance(m.posicao, v_coleta)
      into v_motoboy, v_dist
      from public.motoboys m
      left join public.empresa_favoritos f on f.motoboy_id = m.id and f.empresa_id = c.empresa_id
     where m.status = 'disponivel'
       and m.posicao is not null
       and m.posicao_em > now() - interval '15 minutes'
       and not exists (select 1 from public.ofertas o
                        where o.corrida_id = p_corrida and o.motoboy_id = m.id and o.rodada = c.rodada)
       and not exists (select 1 from public.ofertas o
                        where o.motoboy_id = m.id and o.status = 'pendente')
     order by (f.ordem is null), f.ordem, extensions.st_distance(m.posicao, v_coleta)
     limit 1;
  end if;

  if v_motoboy is null then
    update public.corridas set status = 'sem_motoboy' where id = p_corrida;
    perform privado.evento(p_corrida, 'sem_motoboy');
    return;
  end if;

  insert into public.ofertas (corrida_id, motoboy_id, rodada, distancia_m, expira_em)
  values (p_corrida, v_motoboy, c.rodada, round(v_dist), v_expira)
  returning id into v_oferta;

  update public.corridas set status = 'aguardando_motoboy' where id = p_corrida;
  perform privado.evento(p_corrida, 'oferta_enviada',
    jsonb_build_object('motoboy_id', v_motoboy, 'distancia_m', round(v_dist)));

  perform privado.enviar_push(v_motoboy, jsonb_build_object(
    'tipo', 'oferta',
    'oferta_id', v_oferta::text,
    'corrida_id', p_corrida::text,
    'expira_em', to_char(v_expira at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  ));
end;
$$;

-- Codificação "polyline" do Google (precisão 5)
create or replace function privado.polyline_valor(v bigint)
returns text language plpgsql immutable as $$
declare
  s text := '';
  x bigint := case when v < 0 then ~(v << 1) else (v << 1) end;
begin
  while x >= 32 loop
    s := s || chr((((x & 31) | 32) + 63)::int);
    x := x >> 5;
  end loop;
  return s || chr((x + 63)::int);
end;
$$;

-- Converte os pontos GPS da corrida em polyline + km real.
-- p_apagar = true remove os pontos brutos da tabela quente.
create or replace function privado.finalizar_trajeto(p_corrida uuid, p_apagar boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare
  r     record;
  plat  bigint := 0;
  plng  bigint := 0;
  ilat  bigint;
  ilng  bigint;
  enc   text := '';
  dist  double precision := 0;
  ant   extensions.geography;
  atual extensions.geography;
begin
  for r in
    select lat, lng from public.localizacoes
     where corrida_id = p_corrida order by registrado_em
  loop
    ilat := round(r.lat * 1e5);
    ilng := round(r.lng * 1e5);
    enc  := enc || privado.polyline_valor(ilat - plat) || privado.polyline_valor(ilng - plng);
    plat := ilat;
    plng := ilng;
    atual := extensions.st_setsrid(extensions.st_makepoint(r.lng, r.lat), 4326)::extensions.geography;
    if ant is not null then dist := dist + extensions.st_distance(ant, atual); end if;
    ant := atual;
  end loop;

  if enc <> '' then
    update public.corridas
       set trajeto = enc, distancia_real_m = round(dist),
           compactada_em = case when p_apagar then now() else compactada_em end
     where id = p_corrida;
  elsif p_apagar then
    update public.corridas set compactada_em = now() where id = p_corrida;
  end if;

  if p_apagar then
    delete from public.localizacoes where corrida_id = p_corrida;
  end if;
end;
$$;

-- =====================================================================
-- RPCs do GESTOR
-- =====================================================================

-- dados = { empresa_id, modo_despacho, motoboy_id, exige_foto, exige_assinatura,
--           exige_nome, exige_codigo, distancia_planejada_m, duracao_planejada_s,
--           rota_planejada, valor, observacoes,
--           paradas: [{ tipo, endereco, lat, lng, contato_nome, contato_telefone, instrucoes }] }
create or replace function public.criar_corrida(dados jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_id   uuid;
  v_modo public.modo_despacho := coalesce(nullif(dados ->> 'modo_despacho', ''), 'cascata')::public.modo_despacho;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if jsonb_array_length(coalesce(dados -> 'paradas', '[]')) < 2 then
    raise exception 'corrida_precisa_de_2_paradas' using errcode = '22023';
  end if;
  if (dados -> 'paradas' -> 0 ->> 'tipo') <> 'coleta' then
    raise exception 'primeira_parada_deve_ser_coleta' using errcode = '22023';
  end if;
  if v_modo = 'direto' and nullif(dados ->> 'motoboy_id', '') is null then
    raise exception 'escolha_o_motoboy' using errcode = '22023';
  end if;

  insert into public.corridas (
    empresa_id, criada_por, modo_despacho, motoboy_designado_id,
    exige_foto, exige_assinatura, exige_nome, exige_codigo, codigo_entrega,
    distancia_planejada_m, duracao_planejada_s, rota_planejada, valor, observacoes
  ) values (
    nullif(dados ->> 'empresa_id', '')::uuid,
    auth.uid(),
    v_modo,
    nullif(dados ->> 'motoboy_id', '')::uuid,
    coalesce((dados ->> 'exige_foto')::boolean, false),
    coalesce((dados ->> 'exige_assinatura')::boolean, false),
    coalesce((dados ->> 'exige_nome')::boolean, false),
    coalesce((dados ->> 'exige_codigo')::boolean, false),
    case when coalesce((dados ->> 'exige_codigo')::boolean, false)
         then lpad((floor(random() * 10000))::int::text, 4, '0') end,
    (dados ->> 'distancia_planejada_m')::int,
    (dados ->> 'duracao_planejada_s')::int,
    nullif(dados ->> 'rota_planejada', ''),
    (dados ->> 'valor')::numeric,
    nullif(dados ->> 'observacoes', '')
  ) returning id into v_id;

  insert into public.paradas (corrida_id, ordem, tipo, endereco, lat, lng, contato_nome, contato_telefone, instrucoes)
  select v_id, (ord - 1)::int, (p ->> 'tipo')::public.tipo_parada, p ->> 'endereco',
         (p ->> 'lat')::double precision, (p ->> 'lng')::double precision,
         nullif(p ->> 'contato_nome', ''), nullif(p ->> 'contato_telefone', ''), nullif(p ->> 'instrucoes', '')
    from jsonb_array_elements(dados -> 'paradas') with ordinality as t(p, ord);

  perform privado.evento(v_id, 'criada', jsonb_build_object('modo', v_modo));
  perform privado.despachar(v_id);
  return v_id;
end;
$$;

create or replace function public.cancelar_corrida(p_corrida uuid, p_motivo text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  c public.corridas%rowtype;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select * into c from public.corridas where id = p_corrida for update;
  if not found or c.status in ('concluida', 'cancelada') then return; end if;

  update public.ofertas set status = 'cancelada', respondida_em = now()
   where corrida_id = p_corrida and status = 'pendente';
  update public.corridas set status = 'cancelada', cancelada_em = now() where id = p_corrida;

  if c.motoboy_id is not null then
    update public.motoboys set status = 'disponivel', status_em = now()
     where id = c.motoboy_id and status = 'em_corrida';
    perform privado.enviar_push(c.motoboy_id,
      jsonb_build_object('tipo', 'cancelada', 'corrida_id', p_corrida::text));
  end if;
  perform privado.evento(p_corrida, 'cancelada', jsonb_build_object('motivo', p_motivo));
end;
$$;

-- Nova tentativa para corrida "sem motoboy". p_motoboy = null → cascata.
create or replace function public.redespachar(p_corrida uuid, p_motoboy uuid default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  update public.corridas
     set rodada = rodada + 1,
         modo_despacho = case when p_motoboy is null then 'cascata' else 'direto' end::public.modo_despacho,
         motoboy_designado_id = p_motoboy,
         status = 'aguardando_motoboy'
   where id = p_corrida and status = 'sem_motoboy';
  if not found then raise exception 'corrida_nao_esta_sem_motoboy' using errcode = '22023'; end if;
  perform privado.evento(p_corrida, 'redespachada', jsonb_build_object('motoboy_id', p_motoboy));
  perform privado.despachar(p_corrida);
end;
$$;

-- =====================================================================
-- RPCs do MOTOBOY
-- =====================================================================

create or replace function public.registrar_fcm_token(p_token text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.tem_papel('motoboy'::public.papel_usuario) then
    raise exception 'usuario_nao_e_motoboy' using errcode = '42501';
  end if;
  insert into public.motoboys (id) values (auth.uid()) on conflict (id) do nothing;
  -- o mesmo aparelho não pode ficar em dois motoboys
  delete from privado.fcm_tokens where token = p_token and motoboy_id <> auth.uid();
  insert into privado.fcm_tokens (motoboy_id, token) values (auth.uid(), p_token)
  on conflict (motoboy_id) do update set token = excluded.token, atualizado_em = now();
end;
$$;

create or replace function public.oferta_pendente()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'oferta_id', o.id,
    'expira_em', o.expira_em,
    'segundos_restantes', greatest(0, extract(epoch from (o.expira_em - now())))::int,
    'distancia_m', o.distancia_m,
    'corrida', privado.corrida_json(o.corrida_id)
  )
  from public.ofertas o
  where o.motoboy_id = auth.uid() and o.status = 'pendente' and o.expira_em > now()
  order by o.criada_em desc
  limit 1;
$$;

create or replace function public.minha_corrida_ativa()
returns jsonb language sql stable security definer set search_path = '' as $$
  select privado.corrida_json(c.id)
  from public.corridas c
  where c.motoboy_id = auth.uid() and c.status in ('aceita', 'em_andamento')
  order by c.aceita_em desc
  limit 1;
$$;

create or replace function public.responder_oferta(p_oferta uuid, p_aceitar boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  o public.ofertas%rowtype;
begin
  select * into o from public.ofertas where id = p_oferta for update;
  if not found or o.motoboy_id <> auth.uid() then
    raise exception 'oferta_nao_encontrada' using errcode = '22023';
  end if;
  if o.status <> 'pendente' or o.expira_em <= now() then
    raise exception 'oferta_expirou' using errcode = '22023';
  end if;

  if not p_aceitar then
    update public.ofertas set status = 'recusada', respondida_em = now() where id = p_oferta;
    perform privado.evento(o.corrida_id, 'oferta_recusada', jsonb_build_object('motoboy_id', o.motoboy_id));
    perform privado.despachar(o.corrida_id);
    return null;
  end if;

  if exists (select 1 from public.corridas
              where motoboy_id = auth.uid() and status in ('aceita', 'em_andamento')) then
    raise exception 'voce_ja_tem_corrida_ativa' using errcode = '22023';
  end if;

  update public.ofertas set status = 'aceita', respondida_em = now() where id = p_oferta;
  update public.corridas
     set status = 'aceita', motoboy_id = o.motoboy_id, aceita_em = now()
   where id = o.corrida_id;
  update public.paradas set status = 'a_caminho'
   where corrida_id = o.corrida_id and ordem = (select min(ordem) from public.paradas where corrida_id = o.corrida_id);
  update public.motoboys set status = 'em_corrida', status_em = now() where id = o.motoboy_id;
  perform privado.evento(o.corrida_id, 'aceita', jsonb_build_object('motoboy_id', o.motoboy_id));

  return privado.corrida_json(o.corrida_id);
end;
$$;

-- acao: 'chegou' | 'concluir'
-- dados (ao concluir entrega): { recebedor_nome, codigo, foto_path, assinatura_path }
create or replace function public.avancar_parada(p_parada uuid, p_acao text, p_dados jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  p        public.paradas%rowtype;
  c        public.corridas%rowtype;
  v_atual  int;
  v_dados  jsonb := coalesce(p_dados, '{}');
begin
  select * into p from public.paradas where id = p_parada for update;
  if not found then raise exception 'parada_nao_encontrada' using errcode = '22023'; end if;
  select * into c from public.corridas where id = p.corrida_id for update;
  if c.motoboy_id is distinct from auth.uid() or c.status not in ('aceita', 'em_andamento') then
    raise exception 'corrida_nao_esta_ativa' using errcode = '22023';
  end if;

  select min(ordem) into v_atual from public.paradas where corrida_id = c.id and status <> 'concluida';
  if p.ordem <> v_atual then raise exception 'conclua_a_parada_anterior' using errcode = '22023'; end if;

  if c.status = 'aceita' then
    update public.corridas set status = 'em_andamento', iniciada_em = now() where id = c.id;
  end if;

  if p_acao = 'chegou' then
    update public.paradas set status = 'chegou', chegou_em = now() where id = p.id;
    perform privado.evento(c.id, 'chegou', jsonb_build_object('parada', p.ordem, 'tipo', p.tipo));

  elsif p_acao = 'concluir' then
    if p.tipo = 'entrega' then
      if c.exige_nome and coalesce(trim(v_dados ->> 'recebedor_nome'), '') = '' then
        raise exception 'informe_o_nome_de_quem_recebeu' using errcode = '22023';
      end if;
      if c.exige_codigo and coalesce(v_dados ->> 'codigo', '') <> coalesce(c.codigo_entrega, '') then
        raise exception 'codigo_incorreto' using errcode = '22023';
      end if;
      if c.exige_foto and coalesce(v_dados ->> 'foto_path', '') = '' then
        raise exception 'falta_a_foto' using errcode = '22023';
      end if;
      if c.exige_assinatura and coalesce(v_dados ->> 'assinatura_path', '') = '' then
        raise exception 'falta_a_assinatura' using errcode = '22023';
      end if;
    end if;

    update public.paradas
       set status = 'concluida',
           chegou_em = coalesce(chegou_em, now()),
           concluida_em = now(),
           recebedor_nome = nullif(trim(v_dados ->> 'recebedor_nome'), ''),
           foto_path = nullif(v_dados ->> 'foto_path', ''),
           assinatura_path = nullif(v_dados ->> 'assinatura_path', '')
     where id = p.id;
    perform privado.evento(c.id, 'parada_concluida', jsonb_build_object('parada', p.ordem, 'tipo', p.tipo));

    update public.paradas set status = 'a_caminho'
     where corrida_id = c.id
       and ordem = (select min(ordem) from public.paradas where corrida_id = c.id and status = 'pendente');

    if not exists (select 1 from public.paradas where corrida_id = c.id and status <> 'concluida') then
      update public.corridas set status = 'concluida', concluida_em = now() where id = c.id;
      update public.motoboys set status = 'disponivel', status_em = now() where id = c.motoboy_id;
      perform privado.finalizar_trajeto(c.id, false);
      perform privado.evento(c.id, 'concluida');
      return null;
    end if;
  else
    raise exception 'acao_invalida' using errcode = '22023';
  end if;

  return privado.corrida_json(c.id);
end;
$$;

-- Pontos GPS: agora vinculados automaticamente à corrida ativa
create or replace function public.registrar_localizacoes(pontos jsonb)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid       uuid := auth.uid();
  v_inseridos integer := 0;
  v_ultimo    jsonb;
  v_corrida   uuid;
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

  insert into public.motoboys (id) values (v_uid) on conflict (id) do nothing;

  select id into v_corrida from public.corridas
   where motoboy_id = v_uid and status in ('aceita', 'em_andamento')
   order by aceita_em desc limit 1;

  insert into public.localizacoes (
    motoboy_id, id_local, sessao_id, corrida_id, status, lat, lng,
    precisao_m, velocidade_ms, direcao_graus, altitude_m, bateria, registrado_em
  )
  select
    v_uid,
    (p ->> 'id_local')::uuid,
    nullif(p ->> 'sessao_id', '')::uuid,
    coalesce(nullif(p ->> 'corrida_id', '')::uuid,
             case when (p ->> 'status') = 'em_corrida' then v_corrida end),
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

-- O app não pode sair do "em corrida" por conta própria enquanto houver corrida ativa
create or replace function public.atualizar_status(
  p_status        public.status_motoboy,
  p_modo_economia boolean default false,
  p_versao_app    text default null
)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_status public.status_motoboy := p_status;
begin
  if v_uid is null then
    raise exception 'nao_autenticado' using errcode = '28000';
  end if;
  if not public.tem_papel('motoboy'::public.papel_usuario) then
    raise exception 'usuario_nao_e_motoboy' using errcode = '42501';
  end if;

  if exists (select 1 from public.corridas where motoboy_id = v_uid and status in ('aceita', 'em_andamento')) then
    v_status := 'em_corrida';
  elsif p_status = 'em_corrida' then
    v_status := 'disponivel';
  end if;

  insert into public.motoboys (id, status, modo_economia, versao_app, status_em)
  values (v_uid, v_status, p_modo_economia, p_versao_app, now())
  on conflict (id) do update
    set status        = excluded.status,
        modo_economia = excluded.modo_economia,
        versao_app    = coalesce(excluded.versao_app, public.motoboys.versao_app),
        status_em     = now();
end;
$$;

-- =====================================================================
-- Tarefas automáticas (pg_cron)
-- =====================================================================

create or replace function privado.expirar_ofertas()
returns void language plpgsql security definer set search_path = '' as $$
declare
  r record;
begin
  for r in
    update public.ofertas set status = 'expirada', respondida_em = now()
     where status = 'pendente' and expira_em <= now()
    returning corrida_id, motoboy_id
  loop
    perform privado.evento(r.corrida_id, 'oferta_expirada', jsonb_build_object('motoboy_id', r.motoboy_id));
    perform privado.despachar(r.corrida_id);
  end loop;
end;
$$;

create or replace function privado.compactar_trajetos()
returns void language plpgsql security definer set search_path = '' as $$
declare
  r record;
begin
  for r in
    select id from public.corridas
     where status in ('concluida', 'cancelada')
       and compactada_em is null
       and coalesce(concluida_em, cancelada_em) < now() - interval '30 minutes'
     limit 50
  loop
    perform privado.finalizar_trajeto(r.id, true);
  end loop;
end;
$$;

select cron.schedule('pwex-expirar-ofertas', '5 seconds', 'select privado.expirar_ofertas()');
select cron.schedule('pwex-compactar-trajetos', '*/10 * * * *', 'select privado.compactar_trajetos()');

-- =====================================================================
-- Segurança
-- =====================================================================
alter table public.empresas          enable row level security;
alter table public.empresa_favoritos enable row level security;
alter table public.corridas          enable row level security;
alter table public.paradas           enable row level security;
alter table public.ofertas           enable row level security;
alter table public.eventos_corrida   enable row level security;

-- empresas e favoritos: gestor faz tudo direto (CRUD simples)
drop policy if exists empresas_gestor on public.empresas;
create policy empresas_gestor on public.empresas
  for all to authenticated
  using ((select public.is_gestor())) with check ((select public.is_gestor()));

drop policy if exists favoritos_gestor on public.empresa_favoritos;
create policy favoritos_gestor on public.empresa_favoritos
  for all to authenticated
  using ((select public.is_gestor())) with check ((select public.is_gestor()));

-- corridas, paradas, ofertas: leitura (escrita só pelas RPCs)
drop policy if exists corridas_leitura on public.corridas;
create policy corridas_leitura on public.corridas
  for select to authenticated
  using ((select public.is_gestor()) or motoboy_id = (select auth.uid()));

drop policy if exists paradas_leitura on public.paradas;
create policy paradas_leitura on public.paradas
  for select to authenticated
  using ((select public.is_gestor()) or exists (
    select 1 from public.corridas c where c.id = corrida_id and c.motoboy_id = (select auth.uid())));

drop policy if exists ofertas_leitura on public.ofertas;
create policy ofertas_leitura on public.ofertas
  for select to authenticated
  using ((select public.is_gestor()) or motoboy_id = (select auth.uid()));

drop policy if exists eventos_leitura on public.eventos_corrida;
create policy eventos_leitura on public.eventos_corrida
  for select to authenticated
  using ((select public.is_gestor()));

revoke all on public.empresas, public.empresa_favoritos, public.corridas, public.paradas,
              public.ofertas, public.eventos_corrida from anon;
grant select, insert, update, delete on public.empresas, public.empresa_favoritos to authenticated;
grant select on public.corridas, public.paradas, public.ofertas, public.eventos_corrida to authenticated;

revoke all on all functions in schema privado from public, anon, authenticated;

do $$
declare f text;
begin
  foreach f in array array[
    'public.criar_corrida(jsonb)',
    'public.cancelar_corrida(uuid, text)',
    'public.redespachar(uuid, uuid)',
    'public.registrar_fcm_token(text)',
    'public.oferta_pendente()',
    'public.minha_corrida_ativa()',
    'public.responder_oferta(uuid, boolean)',
    'public.avancar_parada(uuid, text, jsonb)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

-- =====================================================================
-- Comprovantes (Storage): pasta = id da corrida
-- =====================================================================
insert into storage.buckets (id, name, public)
values ('comprovantes', 'comprovantes', false)
on conflict (id) do nothing;

drop policy if exists comprovantes_envio on storage.objects;
create policy comprovantes_envio on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'comprovantes'
    and exists (select 1 from public.corridas c
                 where c.id::text = (storage.foldername(name))[1]
                   and c.motoboy_id = (select auth.uid())
                   and c.status in ('aceita', 'em_andamento'))
  );

drop policy if exists comprovantes_leitura on storage.objects;
create policy comprovantes_leitura on storage.objects
  for select to authenticated
  using (
    bucket_id = 'comprovantes'
    and ((select public.is_gestor()) or exists (
      select 1 from public.corridas c
       where c.id::text = (storage.foldername(name))[1] and c.motoboy_id = (select auth.uid())))
  );

-- =====================================================================
-- Tempo real
-- =====================================================================
do $$ begin alter publication supabase_realtime add table public.corridas;
exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.paradas;
exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.ofertas;
exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.eventos_corrida;
exception when duplicate_object then null; end $$;

-- =====================================================================
-- Endereço do site que envia os pushes
-- =====================================================================
insert into privado.config (chave, valor)
values ('push_url', 'https://delibra-web.vercel.app/api/push')
on conflict (chave) do update set valor = excluded.valor;
