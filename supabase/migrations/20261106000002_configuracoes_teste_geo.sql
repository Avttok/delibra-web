-- =====================================================================
-- PW Express · Migração 0003 · Configurações, modo teste e geolocalização
-- ---------------------------------------------------------------------
-- Pré-requisito: migrações 0001 e 0002.
-- Seguro rodar de novo.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Parâmetros do sistema (editáveis pelo gestor em /gestor/configuracoes)
-- ---------------------------------------------------------------------
create table if not exists public.configuracoes (
  chave          text primary key,
  valor          jsonb not null,
  atualizado_em  timestamptz not null default now(),
  atualizado_por uuid references public.perfis (id) on delete set null
);

insert into public.configuracoes (chave, valor) values
  -- despacho
  ('oferta_segundos',          '30'),
  ('posicao_max_min',          '15'),
  ('raio_max_despacho_km',     '0'),      -- 0 = sem limite
  ('favoritos_primeiro',       'true'),
  -- etapas e geolocalização
  ('exigir_no_local',          'true'),
  ('raio_chegada_m',           '150'),
  ('precisao_max_m',           '80'),     -- quanto do erro do GPS é tolerado
  ('posicao_valida_s',         '180'),    -- idade máxima da posição usada na validação
  -- preço
  ('valor_km_padrao',          '2'),
  ('valor_minimo',             '0'),
  ('arredondamento',           '0'),      -- 0 = centavos; 0.5 = de 50 em 50 centavos; 1 = reais inteiros
  -- comprovantes padrão de uma nova corrida
  ('padrao_exige_nome',        'true'),
  ('padrao_exige_foto',        'false'),
  ('padrao_exige_assinatura',  'false'),
  ('padrao_exige_codigo',      'false'),
  -- rastreamento no app
  ('intervalo_corrida_s',      '45'),
  ('intervalo_economia_s',     '90'),
  ('disponivel_envio_min',     '3'),
  ('disponivel_distancia_m',   '300'),
  -- modo teste
  ('teste_admin_ignora_local', 'true')    -- gestor+motoboy pode avançar etapa de corrida teste sem estar no local
on conflict (chave) do nothing;

create or replace function privado.cfg(p_chave text, p_padrao jsonb)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce((select valor from public.configuracoes where chave = p_chave), p_padrao);
$$;

create or replace function privado.cfg_num(p_chave text, p_padrao numeric)
returns numeric language sql stable security definer set search_path = '' as $$
  select coalesce((select (valor #>> '{}')::numeric from public.configuracoes where chave = p_chave), p_padrao);
$$;

create or replace function privado.cfg_bool(p_chave text, p_padrao boolean)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select (valor #>> '{}')::boolean from public.configuracoes where chave = p_chave), p_padrao);
$$;

-- ---------------------------------------------------------------------
-- Novas colunas
-- ---------------------------------------------------------------------
alter table public.motoboys add column if not exists modo_teste boolean not null default false;
alter table public.corridas add column if not exists teste boolean not null default false;
alter table public.corridas add column if not exists exigir_no_local boolean not null default true;
alter table public.corridas add column if not exists raio_chegada_m int not null default 150;
alter table public.paradas  add column if not exists distancia_chegada_m int;   -- quão perto o motoboy estava ao marcar
alter table public.paradas  add column if not exists local_ignorado boolean not null default false;

-- =====================================================================
-- Despacho (agora com parâmetros e modo teste)
-- =====================================================================
create or replace function privado.despachar(p_corrida uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  c            public.corridas%rowtype;
  v_coleta     extensions.geography;
  v_motoboy    uuid;
  v_dist       double precision;
  v_oferta     uuid;
  v_expira     timestamptz := now() + make_interval(secs => privado.cfg_num('oferta_segundos', 30));
  v_idade      interval := make_interval(mins => privado.cfg_num('posicao_max_min', 15)::int);
  v_raio_max   numeric := privado.cfg_num('raio_max_despacho_km', 0) * 1000;
  v_favoritos  boolean := privado.cfg_bool('favoritos_primeiro', true);
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
    ) and exists (
      select 1 from public.motoboys where id = c.motoboy_designado_id and modo_teste = c.teste
    ) then
      v_motoboy := c.motoboy_designado_id;
      select extensions.st_distance(m.posicao, v_coleta) into v_dist from public.motoboys m where m.id = v_motoboy;
    end if;
  else
    select m.id, extensions.st_distance(m.posicao, v_coleta)
      into v_motoboy, v_dist
      from public.motoboys m
      left join public.empresa_favoritos f
        on v_favoritos and f.motoboy_id = m.id and f.empresa_id = c.empresa_id
     where m.status = 'disponivel'
       and m.modo_teste = c.teste
       and m.posicao is not null
       and m.posicao_em > now() - v_idade
       and (v_raio_max <= 0 or extensions.st_distance(m.posicao, v_coleta) <= v_raio_max)
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
    'teste', c.teste::text,
    'expira_em', to_char(v_expira at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  ));
end;
$$;

-- =====================================================================
-- Criar corrida (teste, geolocalização e padrões vindos das configurações)
-- =====================================================================
create or replace function public.criar_corrida(dados jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_id    uuid;
  v_modo  public.modo_despacho := coalesce(nullif(dados ->> 'modo_despacho', ''), 'cascata')::public.modo_despacho;
  v_teste boolean := coalesce((dados ->> 'teste')::boolean, false);
  v_moto  uuid := nullif(dados ->> 'motoboy_id', '')::uuid;
  v_exige_codigo boolean := coalesce((dados ->> 'exige_codigo')::boolean, privado.cfg_bool('padrao_exige_codigo', false));
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if jsonb_array_length(coalesce(dados -> 'paradas', '[]')) < 2 then
    raise exception 'corrida_precisa_de_2_paradas' using errcode = '22023';
  end if;
  if (dados -> 'paradas' -> 0 ->> 'tipo') <> 'coleta' then
    raise exception 'primeira_parada_deve_ser_coleta' using errcode = '22023';
  end if;
  if v_modo = 'direto' and v_moto is null then
    raise exception 'escolha_o_motoboy' using errcode = '22023';
  end if;
  if v_modo = 'direto' and not exists (select 1 from public.motoboys where id = v_moto and modo_teste = v_teste) then
    raise exception '%', case when v_teste then 'motoboy_fora_do_modo_teste' else 'motoboy_em_modo_teste' end
      using errcode = '22023';
  end if;

  insert into public.corridas (
    empresa_id, criada_por, modo_despacho, motoboy_designado_id, teste,
    exige_foto, exige_assinatura, exige_nome, exige_codigo, codigo_entrega,
    exigir_no_local, raio_chegada_m,
    distancia_planejada_m, duracao_planejada_s, rota_planejada, valor, observacoes
  ) values (
    nullif(dados ->> 'empresa_id', '')::uuid,
    auth.uid(),
    v_modo,
    v_moto,
    v_teste,
    coalesce((dados ->> 'exige_foto')::boolean, privado.cfg_bool('padrao_exige_foto', false)),
    coalesce((dados ->> 'exige_assinatura')::boolean, privado.cfg_bool('padrao_exige_assinatura', false)),
    coalesce((dados ->> 'exige_nome')::boolean, privado.cfg_bool('padrao_exige_nome', true)),
    v_exige_codigo,
    case when v_exige_codigo then lpad((floor(random() * 10000))::int::text, 4, '0') end,
    coalesce((dados ->> 'exigir_no_local')::boolean, privado.cfg_bool('exigir_no_local', true)),
    coalesce((dados ->> 'raio_chegada_m')::int, privado.cfg_num('raio_chegada_m', 150)::int),
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

  perform privado.evento(v_id, 'criada', jsonb_build_object('modo', v_modo, 'teste', v_teste));
  perform privado.despachar(v_id);
  return v_id;
end;
$$;

create or replace function public.redespachar(p_corrida uuid, p_motoboy uuid default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_teste boolean;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select teste into v_teste from public.corridas where id = p_corrida;
  if p_motoboy is not null and not exists (select 1 from public.motoboys where id = p_motoboy and modo_teste = v_teste) then
    raise exception '%', case when v_teste then 'motoboy_fora_do_modo_teste' else 'motoboy_em_modo_teste' end
      using errcode = '22023';
  end if;
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
-- Dados da corrida para o app (agora com teste e regra de local)
-- =====================================================================
create or replace function privado.corrida_json(p_corrida uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', c.id,
    'numero', c.numero,
    'status', c.status,
    'teste', c.teste,
    'valor', c.valor,
    'distancia_planejada_m', c.distancia_planejada_m,
    'duracao_planejada_s', c.duracao_planejada_s,
    'observacoes', c.observacoes,
    'exige_foto', c.exige_foto,
    'exige_assinatura', c.exige_assinatura,
    'exige_nome', c.exige_nome,
    'exige_codigo', c.exige_codigo,
    'exigir_no_local', c.exigir_no_local,
    'raio_chegada_m', c.raio_chegada_m,
    'rota_planejada', c.rota_planejada,
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

-- =====================================================================
-- Validação de presença no local
-- Usa a posição enviada junto com a ação (lat, lng, precisao_m) e, se não
-- houver, a última posição conhecida do motoboy. Devolve a distância (m).
-- =====================================================================
create or replace function privado.distancia_ate_parada(p public.paradas, p_dados jsonb, p_motoboy uuid)
returns table (distancia_m double precision, tolerancia_m double precision)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_alvo   extensions.geography := extensions.st_setsrid(extensions.st_makepoint(p.lng, p.lat), 4326)::extensions.geography;
  v_max_prec numeric := privado.cfg_num('precisao_max_m', 80);
  v_validade interval := make_interval(secs => privado.cfg_num('posicao_valida_s', 180));
  m public.motoboys%rowtype;
begin
  if (p_dados ->> 'lat') is not null and (p_dados ->> 'lng') is not null then
    distancia_m := extensions.st_distance(v_alvo,
      extensions.st_setsrid(extensions.st_makepoint((p_dados ->> 'lng')::float8, (p_dados ->> 'lat')::float8), 4326)::extensions.geography);
    tolerancia_m := least(coalesce((p_dados ->> 'precisao_m')::numeric, 0), v_max_prec);
    return next;
    return;
  end if;
  select * into m from public.motoboys where id = p_motoboy;
  if m.posicao is not null and m.posicao_em > now() - v_validade then
    distancia_m := extensions.st_distance(v_alvo, m.posicao);
    tolerancia_m := least(coalesce(m.precisao_m, 0), v_max_prec);
    return next;
  end if;
end;
$$;

-- acao: 'chegou' | 'concluir'
-- dados: { lat, lng, precisao_m, ignorar_local, recebedor_nome, codigo, foto_path, assinatura_path }
create or replace function public.avancar_parada(p_parada uuid, p_acao text, p_dados jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  p          public.paradas%rowtype;
  c          public.corridas%rowtype;
  v_atual    int;
  v_dados    jsonb := coalesce(p_dados, '{}');
  v_dist     double precision;
  v_tol      double precision;
  v_ignorar  boolean := false;
begin
  select * into p from public.paradas where id = p_parada for update;
  if not found then raise exception 'parada_nao_encontrada' using errcode = '22023'; end if;
  select * into c from public.corridas where id = p.corrida_id for update;
  if c.motoboy_id is distinct from auth.uid() or c.status not in ('aceita', 'em_andamento') then
    raise exception 'corrida_nao_esta_ativa' using errcode = '22023';
  end if;
  if p_acao not in ('chegou', 'concluir') then raise exception 'acao_invalida' using errcode = '22023'; end if;

  select min(ordem) into v_atual from public.paradas where corrida_id = c.id and status <> 'concluida';
  if p.ordem <> v_atual then raise exception 'conclua_a_parada_anterior' using errcode = '22023'; end if;

  -- presença no local
  select d.distancia_m, d.tolerancia_m into v_dist, v_tol from privado.distancia_ate_parada(p, v_dados, auth.uid()) d;
  if c.exigir_no_local then
    v_ignorar := coalesce((v_dados ->> 'ignorar_local')::boolean, false)
                 and c.teste and public.is_gestor()
                 and privado.cfg_bool('teste_admin_ignora_local', true);
    if not v_ignorar then
      if v_dist is null then
        raise exception 'sem_localizacao' using errcode = '22023';
      end if;
      if v_dist - v_tol > c.raio_chegada_m then
        raise exception 'longe_do_local:%:%', round(v_dist), c.raio_chegada_m using errcode = '22023';
      end if;
    end if;
  end if;

  if c.status = 'aceita' then
    update public.corridas set status = 'em_andamento', iniciada_em = now() where id = c.id;
  end if;

  if p_acao = 'chegou' then
    update public.paradas
       set status = 'chegou', chegou_em = now(),
           distancia_chegada_m = round(v_dist), local_ignorado = v_ignorar
     where id = p.id;
    perform privado.evento(c.id, 'chegou', jsonb_build_object(
      'parada', p.ordem, 'tipo', p.tipo, 'distancia_m', round(v_dist), 'local_ignorado', v_ignorar));
    return privado.corrida_json(c.id);
  end if;

  -- concluir
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
         distancia_chegada_m = coalesce(distancia_chegada_m, round(v_dist)),
         local_ignorado = local_ignorado or v_ignorar,
         recebedor_nome = nullif(trim(v_dados ->> 'recebedor_nome'), ''),
         foto_path = nullif(v_dados ->> 'foto_path', ''),
         assinatura_path = nullif(v_dados ->> 'assinatura_path', '')
   where id = p.id;
  perform privado.evento(c.id, 'parada_concluida', jsonb_build_object(
    'parada', p.ordem, 'tipo', p.tipo, 'distancia_m', round(v_dist), 'local_ignorado', v_ignorar));

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

  return privado.corrida_json(c.id);
end;
$$;

-- =====================================================================
-- App: perfil, configurações e modo teste
-- =====================================================================
create or replace function public.meu_perfil()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', p.id,
    'nome', p.nome,
    'papeis', to_jsonb(p.papeis),
    'gestor', 'gestor' = any (p.papeis),
    'motoboy', 'motoboy' = any (p.papeis),
    'modo_teste', coalesce(m.modo_teste, false),
    'configuracoes', coalesce((select jsonb_object_agg(chave, valor) from public.configuracoes), '{}'::jsonb)
  )
  from public.perfis p
  left join public.motoboys m on m.id = p.id
  where p.id = auth.uid();
$$;

create or replace function public.definir_modo_teste(p_ligado boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not (public.is_gestor() and public.tem_papel('motoboy'::public.papel_usuario)) then
    raise exception 'apenas_gestor_motoboy' using errcode = '42501';
  end if;
  if exists (select 1 from public.ofertas where motoboy_id = auth.uid() and status = 'pendente')
     or exists (select 1 from public.corridas where motoboy_id = auth.uid() and status in ('aceita', 'em_andamento')) then
    raise exception 'conclua_a_corrida_antes' using errcode = '22023';
  end if;
  insert into public.motoboys (id, modo_teste) values (auth.uid(), p_ligado)
  on conflict (id) do update set modo_teste = excluded.modo_teste;
end;
$$;

-- =====================================================================
-- Segurança
-- =====================================================================
alter table public.configuracoes enable row level security;

drop policy if exists configuracoes_leitura on public.configuracoes;
create policy configuracoes_leitura on public.configuracoes
  for select to authenticated using (true);

drop policy if exists configuracoes_gestor on public.configuracoes;
create policy configuracoes_gestor on public.configuracoes
  for update to authenticated
  using ((select public.is_gestor())) with check ((select public.is_gestor()));

revoke all on public.configuracoes from anon;
grant select, update on public.configuracoes to authenticated;

revoke all on all functions in schema privado from public, anon, authenticated;

do $$
declare f text;
begin
  foreach f in array array['public.meu_perfil()', 'public.definir_modo_teste(boolean)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

do $$ begin alter publication supabase_realtime add table public.configuracoes;
exception when duplicate_object then null; end $$;

-- quem mudou e quando
create or replace function privado.carimbar_configuracao()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.atualizado_em := now();
  new.atualizado_por := auth.uid();
  return new;
end;
$$;

drop trigger if exists carimbar on public.configuracoes;
create trigger carimbar before update on public.configuracoes
  for each row execute function privado.carimbar_configuracao();

-- =====================================================================
-- Empresas: dados da Receita e ponto de coleta padrão
-- =====================================================================
alter table public.empresas add column if not exists razao_social     text;
alter table public.empresas add column if not exists nome_fantasia    text;
alter table public.empresas add column if not exists situacao         text;   -- ATIVA, BAIXADA, INAPTA...
alter table public.empresas add column if not exists telefone         text;
alter table public.empresas add column if not exists email            text;
alter table public.empresas add column if not exists endereco         text;   -- endereço de coleta padrão
alter table public.empresas add column if not exists lat              double precision;
alter table public.empresas add column if not exists lng              double precision;
alter table public.empresas add column if not exists instrucoes_coleta text;
alter table public.empresas add column if not exists dados_receita    jsonb;
alter table public.empresas add column if not exists consultado_em    timestamptz;

-- =====================================================================
-- Repasse: motoboy fica com X% do valor (padrão 70%), gestão com o resto
-- =====================================================================
insert into public.configuracoes (chave, valor) values ('repasse_motoboy_pct', '70')
on conflict (chave) do nothing;

alter table public.motoboys add column if not exists repasse_pct numeric(5, 2);      -- null = usa o padrão
alter table public.corridas add column if not exists repasse_pct numeric(5, 2);      -- congelado no aceite
alter table public.corridas add column if not exists valor_motoboy numeric(10, 2);
alter table public.corridas add column if not exists valor_gestao numeric(10, 2);

create or replace function privado.repasse_de(p_motoboy uuid)
returns numeric language sql stable security definer set search_path = '' as $$
  select coalesce((select repasse_pct from public.motoboys where id = p_motoboy),
                  privado.cfg_num('repasse_motoboy_pct', 70));
$$;

-- oferta já mostra quanto o motoboy recebe
create or replace function public.oferta_pendente()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'oferta_id', o.id,
    'expira_em', o.expira_em,
    'segundos_restantes', greatest(0, extract(epoch from (o.expira_em - now())))::int,
    'distancia_m', o.distancia_m,
    'valor_motoboy', round(c.valor * privado.repasse_de(o.motoboy_id) / 100, 2),
    'corrida', privado.corrida_json(o.corrida_id)
  )
  from public.ofertas o
  join public.corridas c on c.id = o.corrida_id
  where o.motoboy_id = auth.uid() and o.status = 'pendente' and o.expira_em > now()
  order by o.criada_em desc
  limit 1;
$$;

create or replace function public.responder_oferta(p_oferta uuid, p_aceitar boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  o     public.ofertas%rowtype;
  v_pct numeric;
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

  v_pct := privado.repasse_de(o.motoboy_id);
  update public.ofertas set status = 'aceita', respondida_em = now() where id = p_oferta;
  update public.corridas
     set status = 'aceita', motoboy_id = o.motoboy_id, aceita_em = now(),
         repasse_pct = v_pct,
         valor_motoboy = round(coalesce(valor, 0) * v_pct / 100, 2),
         valor_gestao = coalesce(valor, 0) - round(coalesce(valor, 0) * v_pct / 100, 2)
   where id = o.corrida_id;
  update public.paradas set status = 'a_caminho'
   where corrida_id = o.corrida_id and ordem = (select min(ordem) from public.paradas where corrida_id = o.corrida_id);
  update public.motoboys set status = 'em_corrida', status_em = now() where id = o.motoboy_id;
  perform privado.evento(o.corrida_id, 'aceita', jsonb_build_object('motoboy_id', o.motoboy_id, 'repasse_pct', v_pct));

  return privado.corrida_json(o.corrida_id);
end;
$$;

-- ganhos do motoboy (corridas concluídas, sem as de teste), no fuso de São Paulo
create or replace function public.meus_ganhos()
returns jsonb language sql stable security definer set search_path = '' as $$
  with base as (
    select valor_motoboy, (concluida_em at time zone 'America/Sao_Paulo') as quando
      from public.corridas
     where motoboy_id = auth.uid() and status = 'concluida' and not teste
  ), agora as (select (now() at time zone 'America/Sao_Paulo') as t)
  select jsonb_build_object(
    'hoje',   coalesce(sum(valor_motoboy) filter (where quando >= date_trunc('day', t)), 0),
    'semana', coalesce(sum(valor_motoboy) filter (where quando >= date_trunc('week', t)), 0),
    'mes',    coalesce(sum(valor_motoboy) filter (where quando >= date_trunc('month', t)), 0),
    'corridas_hoje', count(*) filter (where quando >= date_trunc('day', t)),
    'repasse_pct', privado.repasse_de(auth.uid())
  )
  from base, agora;
$$;

-- corrida para o app inclui o valor do motoboy (depois do aceite)
create or replace function privado.corrida_json(p_corrida uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', c.id,
    'numero', c.numero,
    'status', c.status,
    'teste', c.teste,
    'valor', c.valor,
    'valor_motoboy', c.valor_motoboy,
    'distancia_planejada_m', c.distancia_planejada_m,
    'duracao_planejada_s', c.duracao_planejada_s,
    'observacoes', c.observacoes,
    'exige_foto', c.exige_foto,
    'exige_assinatura', c.exige_assinatura,
    'exige_nome', c.exige_nome,
    'exige_codigo', c.exige_codigo,
    'exigir_no_local', c.exigir_no_local,
    'raio_chegada_m', c.raio_chegada_m,
    'rota_planejada', c.rota_planejada,
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

revoke all on all functions in schema privado from public, anon, authenticated;
revoke all on function public.meus_ganhos() from public, anon;
grant execute on function public.meus_ganhos() to authenticated;

-- gestor pode ajustar o repasse individual pela tela de equipe (futura) via RPC
create or replace function public.definir_repasse(p_motoboy uuid, p_pct numeric)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if p_pct is not null and (p_pct < 0 or p_pct > 100) then raise exception 'percentual_invalido' using errcode = '22023'; end if;
  update public.motoboys set repasse_pct = p_pct where id = p_motoboy;
end;
$$;
revoke all on function public.definir_repasse(uuid, numeric) from public, anon;
grant execute on function public.definir_repasse(uuid, numeric) to authenticated;

-- =====================================================================
-- Sigilo do repasse: o motoboy só vê o valor dele.
-- Leitura direta das tabelas de corrida passa a ser só do gestor;
-- o app do motoboy usa apenas as funções (que não expõem total nem %).
-- =====================================================================
create or replace function public.e_motoboy_da_corrida(p_corrida uuid, p_ativa boolean default false)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.corridas c
     where c.id = p_corrida and c.motoboy_id = auth.uid()
       and (not p_ativa or c.status in ('aceita', 'em_andamento'))
  );
$$;
revoke all on function public.e_motoboy_da_corrida(uuid, boolean) from public, anon;
grant execute on function public.e_motoboy_da_corrida(uuid, boolean) to authenticated;

drop policy if exists corridas_leitura on public.corridas;
create policy corridas_leitura on public.corridas
  for select to authenticated using ((select public.is_gestor()));

drop policy if exists paradas_leitura on public.paradas;
create policy paradas_leitura on public.paradas
  for select to authenticated using ((select public.is_gestor()));

drop policy if exists ofertas_leitura on public.ofertas;
create policy ofertas_leitura on public.ofertas
  for select to authenticated using ((select public.is_gestor()));

drop policy if exists comprovantes_envio on storage.objects;
create policy comprovantes_envio on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'comprovantes'
    and public.e_motoboy_da_corrida(((storage.foldername(name))[1])::uuid, true)
  );

drop policy if exists comprovantes_leitura on storage.objects;
create policy comprovantes_leitura on storage.objects
  for select to authenticated
  using (
    bucket_id = 'comprovantes'
    and ((select public.is_gestor()) or public.e_motoboy_da_corrida(((storage.foldername(name))[1])::uuid))
  );

-- corrida para o app: sem valor total e sem percentual, só o valor do motoboy
create or replace function privado.corrida_json(p_corrida uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', c.id,
    'numero', c.numero,
    'status', c.status,
    'teste', c.teste,
    'valor_motoboy', coalesce(c.valor_motoboy, round(coalesce(c.valor, 0) * privado.repasse_de(auth.uid()) / 100, 2)),
    'distancia_planejada_m', c.distancia_planejada_m,
    'duracao_planejada_s', c.duracao_planejada_s,
    'observacoes', c.observacoes,
    'exige_foto', c.exige_foto,
    'exige_assinatura', c.exige_assinatura,
    'exige_nome', c.exige_nome,
    'exige_codigo', c.exige_codigo,
    'exigir_no_local', c.exigir_no_local,
    'raio_chegada_m', c.raio_chegada_m,
    'rota_planejada', c.rota_planejada,
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

create or replace function public.meus_ganhos()
returns jsonb language sql stable security definer set search_path = '' as $$
  with base as (
    select valor_motoboy, (concluida_em at time zone 'America/Sao_Paulo') as quando
      from public.corridas
     where motoboy_id = auth.uid() and status = 'concluida' and not teste
  ), agora as (select (now() at time zone 'America/Sao_Paulo') as t)
  select jsonb_build_object(
    'hoje',   coalesce(sum(valor_motoboy) filter (where quando >= date_trunc('day', t)), 0),
    'semana', coalesce(sum(valor_motoboy) filter (where quando >= date_trunc('week', t)), 0),
    'mes',    coalesce(sum(valor_motoboy) filter (where quando >= date_trunc('month', t)), 0),
    'corridas_hoje', count(*) filter (where quando >= date_trunc('day', t))
  )
  from base, agora;
$$;

-- o motoboy não precisa ler as configurações de preço/repasse: perfil filtra o que vai ao app
create or replace function public.meu_perfil()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', p.id,
    'nome', p.nome,
    'papeis', to_jsonb(p.papeis),
    'gestor', 'gestor' = any (p.papeis),
    'motoboy', 'motoboy' = any (p.papeis),
    'modo_teste', coalesce(m.modo_teste, false),
    'configuracoes', coalesce((
      select jsonb_object_agg(chave, valor) from public.configuracoes
       where chave in ('intervalo_corrida_s', 'intervalo_economia_s', 'disponivel_envio_min',
                       'disponivel_distancia_m', 'raio_chegada_m', 'teste_admin_ignora_local', 'oferta_segundos')
    ), '{}'::jsonb)
  )
  from public.perfis p
  left join public.motoboys m on m.id = p.id
  where p.id = auth.uid();
$$;

-- configurações: leitura direta só para gestor (motoboy recebe o recorte acima)
drop policy if exists configuracoes_leitura on public.configuracoes;
create policy configuracoes_leitura on public.configuracoes
  for select to authenticated using ((select public.is_gestor()));

revoke all on all functions in schema privado from public, anon, authenticated;

-- =====================================================================
-- Perfil: nome e foto editáveis pelo próprio usuário (tela "Meu perfil" no app)
-- =====================================================================
alter table public.perfis add column if not exists foto_url text;

insert into storage.buckets (id, name, public)
values ('avatares', 'avatares', true)
on conflict (id) do nothing;

drop policy if exists avatares_envio on storage.objects;
create policy avatares_envio on storage.objects
  for insert to authenticated
  with check (bucket_id = 'avatares' and (storage.foldername(name))[1] = (select auth.uid())::text);

drop policy if exists avatares_troca on storage.objects;
create policy avatares_troca on storage.objects
  for update to authenticated
  using (bucket_id = 'avatares' and (storage.foldername(name))[1] = (select auth.uid())::text);

create or replace function public.atualizar_meu_perfil(p_nome text default null, p_foto_url text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if p_nome is not null and length(trim(p_nome)) not between 2 and 60 then
    raise exception 'nome_invalido' using errcode = '22023';
  end if;
  update public.perfis
     set nome = coalesce(nullif(trim(p_nome), ''), nome),
         foto_url = coalesce(p_foto_url, foto_url)
   where id = auth.uid();
  return public.meu_perfil();
end;
$$;
revoke all on function public.atualizar_meu_perfil(text, text) from public, anon;
grant execute on function public.atualizar_meu_perfil(text, text) to authenticated;

create or replace function public.meu_perfil()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', p.id,
    'nome', p.nome,
    'foto_url', p.foto_url,
    'papeis', to_jsonb(p.papeis),
    'gestor', 'gestor' = any (p.papeis),
    'motoboy', 'motoboy' = any (p.papeis),
    'modo_teste', coalesce(m.modo_teste, false),
    'configuracoes', coalesce((
      select jsonb_object_agg(chave, valor) from public.configuracoes
       where chave in ('intervalo_corrida_s', 'intervalo_economia_s', 'disponivel_envio_min',
                       'disponivel_distancia_m', 'raio_chegada_m', 'teste_admin_ignora_local', 'oferta_segundos')
    ), '{}'::jsonb)
  )
  from public.perfis p
  left join public.motoboys m on m.id = p.id
  where p.id = auth.uid();
$$;

-- o mapa do gestor precisa das fotos
do $$ begin alter publication supabase_realtime add table public.perfis;
exception when duplicate_object then null; end $$;
