-- =====================================================================
-- PW Express · Renascimento (parte 2 de 3): regras em camadas, pedidos e orçamento
-- Rode DEPOIS de 20261109000001_rotas_enums.sql e ANTES de 20261109000003_rotas_folha_faturas.sql.
--
--  • Regras em camadas (o "lego"): padrão global (tabela configuracoes) e exceções
--    por tipo de pedido, por cliente e por motoboy (tabela politicas).
--    Ordem de quem vence: motoboy > cliente > tipo de pedido > global.
--  • Pedidos do cliente (ou lançados pelo gestor) com pontos de coleta/entrega e itens
--    (quantidade, peso, medidas, categoria, perigoso, valor declarado).
--  • Catálogos: tipos de pedido, categorias de produto, zonas (raios) e horários de pico.
--  • Orçamento completo e explicado linha a linha.
--  • A parte do Dev (padrão 5%) incide sobre o faturamento; só o Dev altera.
-- =====================================================================

-- ------------------------------------------------------------- utilidades
create or replace function privado.dist_m(a_lat double precision, a_lng double precision, b_lat double precision, b_lng double precision)
returns double precision language sql immutable set search_path = '' as $$
  select case when a_lat is null or b_lat is null then null else
    2 * 6371000 * asin(sqrt(power(sin(radians(b_lat - a_lat) / 2), 2)
      + cos(radians(a_lat)) * cos(radians(b_lat)) * power(sin(radians(b_lng - a_lng) / 2), 2))) end;
$$;

-- ------------------------------------------------------------- padrões globais novos
insert into public.configuracoes (chave, valor) values
  -- fluxo do pedido
  ('pedido_revisao_gestor',        'true'),     -- pedido novo espera o gestor aprovar
  ('cliente_pode_express',         'true'),     -- além do "Express liberado" do cadastro
  ('cobranca_modo',                '"credito"'),-- credito (fatura) | pre_pago
  ('agendada_antecedencia_cliente_min', '60'),
  -- roteirizador
  ('roteirizador_ligado',          'true'),
  ('roteirizar_agrupar',           'true'),
  ('rota_janela_min',              '30'),       -- pedidos até 30 min um do outro podem dividir a rota
  ('rota_raio_coleta_km',          '2'),
  ('rota_raio_entrega_km',         '3'),
  ('rota_max_entregas',            '5'),
  ('rota_max_coletas',             '3'),
  ('rota_max_km',                  '0'),        -- 0 = sem limite (da 1ª coleta até a entrega)
  ('rota_montar_antes_min',        '1440'),     -- planejados viram rota até 24 h antes
  ('express_agrupar_espera_min',   '0'),        -- segura o express N min para juntar com outros
  ('rota_revisao_gestor',          'false'),    -- rota montada espera o gestor liberar
  ('rota_exclusiva_cliente',       'false'),    -- não mistura pedidos de outros clientes
  ('perigoso_rota_exclusiva',      'true'),     -- produto perigoso vai em rota separada
  ('fator_rua',                    '1.3'),      -- linha reta → ruas (até o mapa calcular)
  -- despacho
  ('despacho_modo',                '"quadro"'), -- quadro | melhor_primeiro | cascata | direto
  ('despacho_melhor_segundos',     '45'),
  -- pagamento do motoboy (por rota)
  ('pag_modo',                     '"rota"'),   -- rota | percentual (o antigo)
  ('pag_valor_km',                 '2'),
  ('pag_entrega_extra',            '10'),
  ('pag_coleta_extra',             '0'),
  ('pag_fixo_rota',                '0'),
  ('pag_minimo',                   '0'),
  ('pag_km_regra',                 '"mediana"'),-- mediana | percentil | media | mais_longe | mais_perto | total_rota
  ('pag_km_percentil',             '75'),
  ('pag_distancia',                '"rua"'),    -- rua (coleta → entrega direto) | acumulada (km rodados na ordem da rota)
  ('motoboy_ve_valores',           'false'),
  ('motoboy_ve_holerite_valor',    'true'),
  ('holerite_periodo',             '"semanal"'),-- diario | semanal | quinzenal | mensal
  ('holerite_inicio_semana',       '1'),        -- 1 = segunda … 7 = domingo
  -- preço para o cliente
  ('preco_base',                   '8'),
  ('preco_km',                     '2.5'),
  ('preco_coleta_extra',           '5'),
  ('preco_entrega_extra',          '5'),
  ('preco_pacotes_inclusos',       '1'),
  ('preco_pacote_extra',           '1'),
  ('preco_kg_incluso',             '5'),
  ('preco_kg',                     '1'),
  ('cubagem_fator',                '6000'),     -- peso cubado = C × L × A (cm) ÷ fator
  ('preco_perigoso_pct',           '30'),
  ('preco_perigoso_fixo',          '10'),
  ('preco_express_pct',            '0'),
  ('preco_urgente_pct',            '20'),
  ('zona_combinar',                '"maior"'),  -- maior | somar
  -- faturas
  ('fatura_ciclo',                 '"semanal"'),-- diario | semanal | quinzenal | mensal | manual
  ('fatura_dia_semana',            '6'),        -- semanal: fecha no sábado (0 = domingo)
  ('fatura_vencimento_dias',       '3'),
  ('fatura_revisao',               'true')      -- fatura nasce rascunho para o gestor revisar
on conflict (chave) do nothing;

-- ------------------------------------------------------------- regras em camadas
create table if not exists public.politicas (
  escopo         text not null check (escopo in ('tipo', 'cliente', 'motoboy')),
  alvo           text not null,
  chave          text not null,
  valor          jsonb not null,
  atualizado_em  timestamptz not null default now(),
  atualizado_por uuid references public.perfis (id) on delete set null,
  primary key (escopo, alvo, chave)
);
alter table public.politicas enable row level security;
drop policy if exists politicas_leitura on public.politicas;
create policy politicas_leitura on public.politicas for select to authenticated
  using ((select public.is_gestor()) or (escopo = 'motoboy' and alvo = (select auth.uid())::text));
grant select on public.politicas to authenticated;

-- valor efetivo: motoboy > cliente > tipo de pedido > global
create or replace function privado.pol(p_chave text, p_cliente uuid default null, p_motoboy uuid default null, p_tipo text default null)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select valor from public.politicas where p_motoboy is not null and escopo = 'motoboy' and alvo = p_motoboy::text and chave = p_chave),
    (select valor from public.politicas where p_cliente is not null and escopo = 'cliente' and alvo = p_cliente::text and chave = p_chave),
    (select valor from public.politicas where p_tipo is not null and escopo = 'tipo' and alvo = p_tipo and chave = p_chave),
    (select valor from public.configuracoes where chave = p_chave));
$$;
create or replace function privado.pol_num(p_chave text, p_padrao numeric, p_cliente uuid default null, p_motoboy uuid default null, p_tipo text default null)
returns numeric language sql stable security definer set search_path = '' as $$
  select coalesce(nullif(privado.pol(p_chave, p_cliente, p_motoboy, p_tipo) #>> '{}', '')::numeric, p_padrao);
$$;
create or replace function privado.pol_bool(p_chave text, p_padrao boolean, p_cliente uuid default null, p_motoboy uuid default null, p_tipo text default null)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(nullif(privado.pol(p_chave, p_cliente, p_motoboy, p_tipo) #>> '{}', '')::boolean, p_padrao);
$$;
create or replace function privado.pol_txt(p_chave text, p_padrao text, p_cliente uuid default null, p_motoboy uuid default null, p_tipo text default null)
returns text language sql stable security definer set search_path = '' as $$
  select coalesce(nullif(privado.pol(p_chave, p_cliente, p_motoboy, p_tipo) #>> '{}', ''), p_padrao);
$$;

-- Gestor cria/troca/remove uma exceção (valor null remove). dev_pct só o Dev.
create or replace function public.definir_politica(p_escopo text, p_alvo text, p_chave text, p_valor jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if p_chave = 'dev_pct' and not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  if p_escopo not in ('tipo', 'cliente', 'motoboy') or coalesce(p_alvo, '') = '' or coalesce(p_chave, '') = '' then
    raise exception 'politica_invalida' using errcode = '22023';
  end if;
  if p_escopo = 'motoboy' and not public.pode_gerenciar(p_alvo::uuid) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if p_valor is null or p_valor = 'null'::jsonb then
    delete from public.politicas where escopo = p_escopo and alvo = p_alvo and chave = p_chave;
  else
    insert into public.politicas (escopo, alvo, chave, valor, atualizado_em, atualizado_por)
    values (p_escopo, p_alvo, p_chave, p_valor, now(), auth.uid())
    on conflict (escopo, alvo, chave) do update set valor = excluded.valor, atualizado_em = now(), atualizado_por = auth.uid();
  end if;
end;
$$;

-- A parte do Dev só o Dev mexe (global e por cliente)
create or replace function privado.proteger_dev_pct_config()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is not null and not public.is_dev() and new.chave = 'dev_pct' then raise exception 'apenas_dev' using errcode = '42501'; end if;
  return new;
end;
$$;
create or replace function privado.proteger_dev_pct_cliente()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or public.is_dev() then return new; end if;
  if tg_op = 'UPDATE' then
    if new.dev_pct is distinct from old.dev_pct then raise exception 'apenas_dev' using errcode = '42501'; end if;
  elsif new.dev_pct is not null then
    raise exception 'apenas_dev' using errcode = '42501';
  end if;
  return new;
end;
$$;
drop function if exists privado.proteger_dev_pct() cascade;
drop trigger if exists configuracoes_proteger_dev on public.configuracoes;
create trigger configuracoes_proteger_dev before insert or update on public.configuracoes for each row execute function privado.proteger_dev_pct_config();
drop trigger if exists empresas_proteger_dev on public.empresas;
create trigger empresas_proteger_dev before insert or update on public.empresas for each row execute function privado.proteger_dev_pct_cliente();

-- ------------------------------------------------------------- catálogos
create table if not exists public.tipos_pedido (
  chave     text primary key check (chave ~ '^[a-z0-9_]{2,40}$'),
  nome      text not null,
  descricao text,
  icone     text,
  ativo     boolean not null default true,
  ordem     int not null default 0
);
insert into public.tipos_pedido (chave, nome, descricao, icone, ordem) values
  ('padrao', 'Entrega padrão', 'Pacotes e encomendas do dia a dia.', 'package', 0),
  ('documentos', 'Documentos', 'Envelopes, contratos e papéis.', 'file-text', 1),
  ('loja', 'Venda de loja', 'Uma coleta na loja e várias entregas para os compradores.', 'store', 2)
on conflict (chave) do nothing;

create table if not exists public.categorias_produto (
  id               uuid primary key default gen_random_uuid(),
  nome             text not null,
  descricao        text,
  perigoso         boolean not null default false,
  classe_risco     text,               -- ex.: "Inflamável", "Corrosivo" (ONU)
  fragil           boolean not null default false,
  adicional_item   numeric(10, 2) not null default 0,   -- por unidade
  adicional_fixo   numeric(10, 2) not null default 0,   -- uma vez por pedido
  fator_pct        numeric(6, 2) not null default 0,    -- sobre o subtotal
  ativa            boolean not null default true,
  ordem            int not null default 0,
  criado_em        timestamptz not null default now()
);
insert into public.categorias_produto (nome, descricao, perigoso, classe_risco, fragil, adicional_item, fator_pct, ordem)
select * from (values
  ('Documentos', 'Envelopes e papéis', false, null::text, false, 0::numeric, 0::numeric, 0),
  ('Pacote comum', 'Caixas e sacolas sem cuidado especial', false, null, false, 0, 0, 1),
  ('Eletrônicos', 'Celulares, fones, caixas de som', false, null, true, 1, 5, 2),
  ('Alimentos', 'Comida e bebida', false, null, false, 0, 0, 3),
  ('Medicamentos', 'Remédios e materiais de saúde', false, null, true, 0, 5, 4),
  ('Químicos / inflamáveis', 'Produtos perigosos: exigem cuidado e rota própria', true, 'Inflamável/Químico', false, 3, 0, 5)
) v where not exists (select 1 from public.categorias_produto);

create table if not exists public.zonas (
  id           uuid primary key default gen_random_uuid(),
  nome         text not null,
  cliente_id   uuid references public.empresas (id) on delete cascade,   -- null = vale para todos
  lat          double precision not null,
  lng          double precision not null,
  raio_m       int not null check (raio_m between 50 and 200000),
  fator_pct    numeric(6, 2) not null default 0,
  adicional    numeric(10, 2) not null default 0,
  cor          text not null default '#d4af37',
  ativa        boolean not null default true,
  criado_em    timestamptz not null default now()
);

create table if not exists public.faixas_horario (
  id          uuid primary key default gen_random_uuid(),
  nome        text not null,
  cliente_id  uuid references public.empresas (id) on delete cascade,
  dias        int[] not null default '{1,2,3,4,5}',   -- 0 = domingo … 6 = sábado
  inicio      time not null,
  fim         time not null,
  fator_pct   numeric(6, 2) not null default 0,
  adicional   numeric(10, 2) not null default 0,
  ativa       boolean not null default true,
  criado_em   timestamptz not null default now()
);
insert into public.faixas_horario (nome, dias, inicio, fim, fator_pct)
select * from (values ('Pico da manhã', '{1,2,3,4,5}'::int[], '07:00'::time, '09:00'::time, 15::numeric),
                      ('Pico da tarde', '{1,2,3,4,5}'::int[], '17:00'::time, '19:30'::time, 20::numeric)) v
 where not exists (select 1 from public.faixas_horario);

do $$
declare t text;
begin
  foreach t in array array['tipos_pedido', 'categorias_produto', 'zonas', 'faixas_horario'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t || '_gestor', t);
    execute format('create policy %I on public.%I for all to authenticated using ((select public.is_gestor())) with check ((select public.is_gestor()))', t || '_gestor', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
  end loop;
end $$;
-- clientes enxergam tipos e categorias ativos (para montar o pedido)
drop policy if exists tipos_pedido_leitura on public.tipos_pedido;
create policy tipos_pedido_leitura on public.tipos_pedido for select to authenticated using (ativo);
drop policy if exists categorias_leitura on public.categorias_produto;
create policy categorias_leitura on public.categorias_produto for select to authenticated using (ativa);

-- ------------------------------------------------------------- pedidos
create table if not exists public.pedidos (
  id                  uuid primary key default gen_random_uuid(),
  numero              bigint,
  teste               boolean not null default false,
  empresa_id          uuid references public.empresas (id) on delete set null,
  cliente_nome        text,
  criado_por          uuid references public.perfis (id) on delete set null,
  origem              text not null default 'gestor' check (origem in ('cliente', 'gestor')),
  tipo                text not null default 'express' check (tipo in ('express', 'planejado')),
  tipo_pedido         text not null default 'padrao' references public.tipos_pedido (chave) on update cascade,
  quando              timestamptz,               -- planejado: horário pedido; express: null (agora)
  urgente             boolean not null default false,
  status              text not null default 'recebido'
                        check (status in ('recebido', 'aprovado', 'roteirizado', 'em_rota', 'concluido', 'cancelado', 'recusado')),
  observacoes         text,
  distancia_estimada_m int,
  orcamento           jsonb,
  valor_calculado     numeric(10, 2),
  valor_ajuste        numeric(10, 2) not null default 0,
  ajuste_motivo       text,
  valor               numeric(10, 2),
  dev_pct             numeric(5, 2),
  valor_dev           numeric(10, 2),
  cobranca            text not null default 'credito' check (cobranca in ('credito', 'pre_pago')),
  pagamento_status    text not null default 'nao_exigido' check (pagamento_status in ('nao_exigido', 'pendente', 'pago', 'reembolsado')),
  pagamento_metodo    text,
  pagamento_ref       text,
  pago_em             timestamptz,
  fatura_id           uuid,
  revisado_por        uuid references public.perfis (id) on delete set null,
  revisado_em         timestamptz,
  aprovado_em         timestamptz,
  recusa_motivo       text,
  criado_em           timestamptz not null default now(),
  concluido_em        timestamptz,
  cancelado_em        timestamptz,
  unique (teste, numero)
);
create index if not exists pedidos_status_idx on public.pedidos (status, teste);
create index if not exists pedidos_empresa_idx on public.pedidos (empresa_id, criado_em desc);

create table if not exists public.pedido_pontos (
  id               uuid primary key default gen_random_uuid(),
  pedido_id        uuid not null references public.pedidos (id) on delete cascade,
  ordem            int not null,
  tipo             public.tipo_parada not null,
  endereco         text not null,
  lat              double precision not null,
  lng              double precision not null,
  contato_nome     text,
  contato_telefone text,
  instrucoes       text,
  referencias      jsonb not null default '[]',
  status           text not null default 'pendente' check (status in ('pendente', 'em_rota', 'concluido', 'cancelado')),
  concluido_em     timestamptz,
  recebedor_nome   text,
  unique (pedido_id, ordem)
);

create table if not exists public.pedido_itens (
  id               uuid primary key default gen_random_uuid(),
  pedido_id        uuid not null references public.pedidos (id) on delete cascade,
  coleta_id        uuid references public.pedido_pontos (id) on delete set null,
  entrega_id       uuid references public.pedido_pontos (id) on delete set null,
  descricao        text not null,
  categoria_id     uuid references public.categorias_produto (id) on delete set null,
  quantidade       int not null default 1 check (quantidade between 1 and 10000),
  peso_kg          numeric(10, 3),          -- por unidade
  comprimento_cm   numeric(8, 1),
  largura_cm       numeric(8, 1),
  altura_cm        numeric(8, 1),
  valor_declarado  numeric(12, 2),
  observacoes      text
);

create table if not exists public.pedido_eventos (
  id         bigint generated always as identity primary key,
  pedido_id  uuid not null references public.pedidos (id) on delete cascade,
  tipo       text not null,
  dados      jsonb not null default '{}',
  autor      uuid,
  criado_em  timestamptz not null default now()
);

-- id do cadastro do cliente logado (pública: as políticas de leitura rodam como o usuário)
create or replace function public.minha_empresa_id()
returns uuid language sql stable security definer set search_path = '' as $$
  select empresa_id from public.perfis where id = auth.uid() and 'cliente' = any (papeis);
$$;

alter table public.pedidos enable row level security;
alter table public.pedido_pontos enable row level security;
alter table public.pedido_itens enable row level security;
alter table public.pedido_eventos enable row level security;
drop policy if exists pedidos_leitura on public.pedidos;
create policy pedidos_leitura on public.pedidos for select to authenticated
  using ((select public.is_gestor()) or (empresa_id is not null and empresa_id = (select public.minha_empresa_id())));
drop policy if exists pedido_pontos_leitura on public.pedido_pontos;
create policy pedido_pontos_leitura on public.pedido_pontos for select to authenticated
  using (exists (select 1 from public.pedidos p where p.id = pedido_id));
drop policy if exists pedido_itens_leitura on public.pedido_itens;
create policy pedido_itens_leitura on public.pedido_itens for select to authenticated
  using (exists (select 1 from public.pedidos p where p.id = pedido_id));
drop policy if exists pedido_eventos_leitura on public.pedido_eventos;
create policy pedido_eventos_leitura on public.pedido_eventos for select to authenticated
  using ((select public.is_gestor()));
grant select on public.pedidos, public.pedido_pontos, public.pedido_itens, public.pedido_eventos to authenticated;

create or replace function privado.numerar_pedido()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform pg_advisory_xact_lock(hashtext('pwex_pedido_' || new.teste::text));
  select coalesce(max(numero), 0) + 1 into new.numero from public.pedidos where teste = new.teste;
  return new;
end;
$$;
drop trigger if exists pedidos_numerar on public.pedidos;
create trigger pedidos_numerar before insert on public.pedidos for each row execute function privado.numerar_pedido();

create or replace function privado.evento_pedido(p_pedido uuid, p_tipo text, p_dados jsonb default '{}')
returns void language sql security definer set search_path = '' as $$
  insert into public.pedido_eventos (pedido_id, tipo, dados, autor) values (p_pedido, p_tipo, coalesce(p_dados, '{}'), auth.uid());
$$;

-- ------------------------------------------------------------- orçamento
-- Distância estimada de um conjunto de pontos (coletas primeiro, depois entregas, sempre o mais próximo).
create or replace function privado.distancia_estimada(p_pontos jsonb)
returns int language plpgsql immutable set search_path = '' as $$
declare
  v_rest  jsonb := '[]';
  v_lat   double precision; v_lng double precision;
  v_total double precision := 0;
  v_best  int; v_bd double precision; v_d double precision; i int;
  v_fase  text;
begin
  if p_pontos is null or jsonb_array_length(p_pontos) < 2 then return 0; end if;
  foreach v_fase in array array['coleta', 'entrega'] loop
    select coalesce(jsonb_agg(x), '[]') into v_rest from jsonb_array_elements(p_pontos) x where x ->> 'tipo' = v_fase;
    while jsonb_array_length(v_rest) > 0 loop
      if v_lat is null then
        v_lat := (v_rest -> 0 ->> 'lat')::double precision; v_lng := (v_rest -> 0 ->> 'lng')::double precision;
        v_rest := v_rest - 0;
        continue;
      end if;
      v_best := 0; v_bd := null;
      for i in 0 .. jsonb_array_length(v_rest) - 1 loop
        v_d := privado.dist_m(v_lat, v_lng, (v_rest -> i ->> 'lat')::double precision, (v_rest -> i ->> 'lng')::double precision);
        if v_bd is null or v_d < v_bd then v_bd := v_d; v_best := i; end if;
      end loop;
      v_total := v_total + v_bd;
      v_lat := (v_rest -> v_best ->> 'lat')::double precision; v_lng := (v_rest -> v_best ->> 'lng')::double precision;
      v_rest := v_rest - v_best;
    end loop;
  end loop;
  return round(v_total)::int;
end;
$$;

-- Orçamento explicado. Entrada: {empresa_id, tipo, tipo_pedido, quando, urgente, distancia_m, pontos:[{tipo,lat,lng}], itens:[...]}
create or replace function privado.orcar(d jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_cli    uuid := nullif(d ->> 'empresa_id', '')::uuid;
  v_tp     text := coalesce(nullif(d ->> 'tipo_pedido', ''), 'padrao');
  v_quando timestamptz := coalesce(nullif(d ->> 'quando', '')::timestamptz, now());
  e        public.empresas%rowtype;
  v_linhas jsonb := '[]';
  v_pcts   jsonb := '[]';
  v_fixos  numeric := 0;
  v_sub    numeric := 0;
  v_pct    numeric := 0;
  v_dist   numeric;
  v_km     numeric;
  v_ncol   int; v_nent int; v_pac int;
  v_real   numeric; v_cub numeric; v_tax numeric;
  v_val    numeric; v_x numeric;
  v_perig  boolean;
  v_cat    record;
  v_zp     numeric := 0; v_za numeric := 0; v_znomes text[] := '{}';
  v_hp     numeric := 0; v_ha numeric := 0; v_hnome text;
  v_somar  boolean;
  v_total  numeric;
  v_min    numeric;
  v_fixo_cliente boolean := false;
  v_vkm    numeric;
begin
  if v_cli is not null then select * into e from public.empresas where id = v_cli; end if;
  select count(*) filter (where x ->> 'tipo' = 'coleta'), count(*) filter (where x ->> 'tipo' = 'entrega')
    into v_ncol, v_nent from jsonb_array_elements(coalesce(d -> 'pontos', '[]')) x;
  v_dist := coalesce(nullif(d ->> 'distancia_m', '')::numeric,
                     privado.distancia_estimada(d -> 'pontos') * privado.pol_num('fator_rua', 1.3, v_cli, null, v_tp));
  v_km := round(v_dist / 1000.0, 2);

  -- base e distância (o preço fixo do cadastro antigo do cliente ainda vale)
  if e.id is not null and e.modalidade_preco::text = 'fixo' and e.valor_fixo is not null
     and not exists (select 1 from public.politicas where escopo = 'cliente' and alvo = v_cli::text and chave in ('preco_base', 'preco_km')) then
    v_fixo_cliente := true;
    v_linhas := v_linhas || jsonb_build_object('rotulo', 'Preço fixo do cliente', 'valor', e.valor_fixo);
    v_sub := v_sub + e.valor_fixo;
  else
    v_val := privado.pol_num('preco_base', 8, v_cli, null, v_tp);
    if v_val <> 0 then v_linhas := v_linhas || jsonb_build_object('rotulo', 'Saída', 'valor', v_val); v_sub := v_sub + v_val; end if;
    v_vkm := privado.pol_num('preco_km', 2.5, v_cli, null, v_tp);
    if e.id is not null and e.modalidade_preco::text = 'por_km' and e.valor_km is not null
       and not exists (select 1 from public.politicas where escopo = 'cliente' and alvo = v_cli::text and chave = 'preco_km') then
      v_vkm := e.valor_km;
    end if;
    v_val := round(v_km * v_vkm, 2);
    v_linhas := v_linhas || jsonb_build_object('rotulo', 'Distância', 'detalhe', format('%s km × R$ %s', v_km, v_vkm), 'valor', v_val);
    v_sub := v_sub + v_val;
  end if;

  -- pontos extras
  if v_ncol > 1 then
    v_val := (v_ncol - 1) * privado.pol_num('preco_coleta_extra', 5, v_cli, null, v_tp);
    if v_val <> 0 then v_linhas := v_linhas || jsonb_build_object('rotulo', 'Coletas extras', 'detalhe', format('%s × R$ %s', v_ncol - 1, privado.pol_num('preco_coleta_extra', 5, v_cli, null, v_tp)), 'valor', v_val); v_sub := v_sub + v_val; end if;
  end if;
  if v_nent > 1 then
    v_val := (v_nent - 1) * privado.pol_num('preco_entrega_extra', 5, v_cli, null, v_tp);
    if v_val <> 0 then v_linhas := v_linhas || jsonb_build_object('rotulo', 'Entregas extras', 'detalhe', format('%s × R$ %s', v_nent - 1, privado.pol_num('preco_entrega_extra', 5, v_cli, null, v_tp)), 'valor', v_val); v_sub := v_sub + v_val; end if;
  end if;

  -- pacotes, peso real × peso cubado
  select coalesce(sum(coalesce((i ->> 'quantidade')::int, 1)), 0),
         coalesce(sum(coalesce((i ->> 'quantidade')::int, 1) * coalesce((i ->> 'peso_kg')::numeric, 0)), 0),
         coalesce(sum(coalesce((i ->> 'quantidade')::int, 1) * coalesce((i ->> 'comprimento_cm')::numeric, 0) * coalesce((i ->> 'largura_cm')::numeric, 0)
                      * coalesce((i ->> 'altura_cm')::numeric, 0)), 0) / greatest(privado.pol_num('cubagem_fator', 6000, v_cli, null, v_tp), 1)
    into v_pac, v_real, v_cub from jsonb_array_elements(coalesce(d -> 'itens', '[]')) i;
  v_x := greatest(0, v_pac - privado.pol_num('preco_pacotes_inclusos', 1, v_cli, null, v_tp));
  if v_x > 0 then
    v_val := v_x * privado.pol_num('preco_pacote_extra', 1, v_cli, null, v_tp);
    if v_val <> 0 then v_linhas := v_linhas || jsonb_build_object('rotulo', 'Volumes extras', 'detalhe', format('%s volume(s) além do incluso', v_x), 'valor', v_val); v_sub := v_sub + v_val; end if;
  end if;
  v_tax := round(greatest(v_real, v_cub), 2);
  v_x := greatest(0, v_tax - privado.pol_num('preco_kg_incluso', 5, v_cli, null, v_tp));
  if v_x > 0 then
    v_val := round(v_x * privado.pol_num('preco_kg', 1, v_cli, null, v_tp), 2);
    if v_val <> 0 then
      v_linhas := v_linhas || jsonb_build_object('rotulo', 'Peso excedente',
        'detalhe', format('%s kg taxados (%s)', v_tax, case when v_cub > v_real then 'peso cubado' else 'peso real' end), 'valor', v_val);
      v_sub := v_sub + v_val;
    end if;
  end if;

  -- categorias
  v_perig := false;
  for v_cat in
    select k.id, k.nome, k.perigoso, k.adicional_item, k.adicional_fixo, k.fator_pct, sum(coalesce((i ->> 'quantidade')::int, 1)) q
      from jsonb_array_elements(coalesce(d -> 'itens', '[]')) i
      join public.categorias_produto k on k.id = nullif(i ->> 'categoria_id', '')::uuid
     group by k.id
  loop
    v_perig := v_perig or v_cat.perigoso;
    v_val := v_cat.adicional_fixo + v_cat.adicional_item * v_cat.q;
    if v_val <> 0 then v_linhas := v_linhas || jsonb_build_object('rotulo', v_cat.nome, 'detalhe', format('%s item(ns)', v_cat.q), 'valor', v_val); v_sub := v_sub + v_val; end if;
    if v_cat.fator_pct <> 0 then v_pcts := v_pcts || jsonb_build_object('rotulo', v_cat.nome, 'pct', v_cat.fator_pct); v_pct := v_pct + v_cat.fator_pct; end if;
  end loop;
  if v_perig then
    v_val := privado.pol_num('preco_perigoso_fixo', 10, v_cli, null, v_tp);
    if v_val <> 0 then v_linhas := v_linhas || jsonb_build_object('rotulo', 'Produto perigoso', 'valor', v_val); v_fixos := v_fixos + v_val; end if;
    v_x := privado.pol_num('preco_perigoso_pct', 30, v_cli, null, v_tp);
    if v_x <> 0 then v_pcts := v_pcts || jsonb_build_object('rotulo', 'Produto perigoso', 'pct', v_x); v_pct := v_pct + v_x; end if;
  end if;

  -- express e urgente
  if coalesce(d ->> 'tipo', 'express') = 'express' then
    v_x := privado.pol_num('preco_express_pct', 0, v_cli, null, v_tp);
    if v_x <> 0 then v_pcts := v_pcts || jsonb_build_object('rotulo', 'Express', 'pct', v_x); v_pct := v_pct + v_x; end if;
  end if;
  if coalesce((d ->> 'urgente')::boolean, false) then
    v_x := privado.pol_num('preco_urgente_pct', 20, v_cli, null, v_tp);
    if v_x <> 0 then v_pcts := v_pcts || jsonb_build_object('rotulo', 'Urgente', 'pct', v_x); v_pct := v_pct + v_x; end if;
  end if;

  -- zonas (raios com dinâmica de preço): algum ponto dentro do raio
  v_somar := privado.pol_txt('zona_combinar', 'maior', v_cli, null, v_tp) = 'somar';
  select coalesce(case when v_somar then sum(z.fator_pct) else max(z.fator_pct) end, 0),
         coalesce(case when v_somar then sum(z.adicional) else max(z.adicional) end, 0),
         coalesce(array_agg(z.nome), '{}')
    into v_zp, v_za, v_znomes
    from public.zonas z
   where z.ativa and (z.cliente_id is null or z.cliente_id = v_cli)
     and exists (select 1 from jsonb_array_elements(coalesce(d -> 'pontos', '[]')) x
                  where privado.dist_m(z.lat, z.lng, (x ->> 'lat')::double precision, (x ->> 'lng')::double precision) <= z.raio_m);
  if v_za <> 0 then v_linhas := v_linhas || jsonb_build_object('rotulo', 'Zona', 'detalhe', array_to_string(v_znomes, ', '), 'valor', v_za); v_fixos := v_fixos + v_za; end if;
  if v_zp <> 0 then v_pcts := v_pcts || jsonb_build_object('rotulo', 'Zona: ' || array_to_string(v_znomes, ', '), 'pct', v_zp); v_pct := v_pct + v_zp; end if;

  -- horário de pico (pelo horário da coleta)
  select f.fator_pct, f.adicional, f.nome into v_hp, v_ha, v_hnome
    from public.faixas_horario f
   where f.ativa and (f.cliente_id is null or f.cliente_id = v_cli)
     and extract(dow from v_quando at time zone 'America/Sao_Paulo')::int = any (f.dias)
     and (case when f.fim > f.inicio
               then (v_quando at time zone 'America/Sao_Paulo')::time >= f.inicio and (v_quando at time zone 'America/Sao_Paulo')::time < f.fim
               else (v_quando at time zone 'America/Sao_Paulo')::time >= f.inicio or (v_quando at time zone 'America/Sao_Paulo')::time < f.fim end)
   order by (f.cliente_id is null), f.fator_pct desc, f.adicional desc limit 1;
  if coalesce(v_ha, 0) <> 0 then v_linhas := v_linhas || jsonb_build_object('rotulo', v_hnome, 'valor', v_ha); v_fixos := v_fixos + v_ha; end if;
  if coalesce(v_hp, 0) <> 0 then v_pcts := v_pcts || jsonb_build_object('rotulo', v_hnome, 'pct', v_hp); v_pct := v_pct + v_hp; end if;

  v_total := v_sub * (1 + v_pct / 100.0) + v_fixos;
  v_min := privado.pol_num('valor_minimo', 0, v_cli, null, v_tp);
  v_total := privado.arredondar(greatest(v_total, v_min));
  return jsonb_build_object(
    'linhas', v_linhas, 'percentuais', v_pcts, 'subtotal', round(v_sub + v_fixos, 2), 'acrescimo_pct', v_pct,
    'minimo', v_min, 'total', v_total, 'km', v_km, 'distancia_m', round(v_dist),
    'coletas', v_ncol, 'entregas', v_nent, 'volumes', v_pac, 'peso_real_kg', round(v_real, 2), 'peso_cubado_kg', round(v_cub, 2),
    'peso_taxado_kg', v_tax, 'perigoso', v_perig, 'calculado_em', now());
end;
$$;

-- Prévia do orçamento (cliente: sempre do próprio cadastro)
create or replace function public.orcar_previa(dados jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_cli uuid;
begin
  if public.is_gestor() then return privado.orcar(dados); end if;
  v_cli := privado.minha_empresa();
  if v_cli is null then raise exception 'apenas_cliente' using errcode = '42501'; end if;
  return privado.orcar(jsonb_set(dados, '{empresa_id}', to_jsonb(v_cli::text)));
end;
$$;
