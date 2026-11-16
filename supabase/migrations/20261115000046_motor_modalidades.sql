-- 0046 · Motor de modalidades
--  • campos_personalizados: campos próprios em pedido, ponto (o que o motoboy responde na parada), cliente e motoboy
--  • rotulos: nomes próprios para status e tipos de parada, por empresa e por tipo de pedido
--  • regras_extras: blocos de preço e de pagamento (R$ X por unidade, quando <condição>, com mínimo e máximo)
--  • cargos: cargos personalizados (conjunto de permissões e ações) para a equipe
--  • modulos_empresa: módulo ligado/desligado por empresa
--  • veículo: o pedido pode exigir um tipo de veículo; o despacho só oferece a quem tem
--  • textos dos avisos por empresa, limite de chamadas da API, percurso da rota pela janela de tempo (várias rotas juntas)

do $$ begin
  perform set_config('lock_timeout', '60s', true);
  lock table public.pedidos, public.pedido_pontos, public.paradas, public.corridas, public.perfis, public.motoboys, public.empresas,
             public.api_chaves, public.modulos in access exclusive mode;
end $$;

-- ===================================================================== campos próprios
create table if not exists public.campos_personalizados (
  id             uuid primary key default gen_random_uuid(),
  organizacao_id uuid,                                  -- vazio = da plataforma (o Dev), vale para todas
  entidade       text not null check (entidade in ('pedido', 'ponto', 'cliente', 'motoboy')),
  ponto_tipo     text check (ponto_tipo in ('coleta', 'entrega')),   -- ponto: só coleta, só entrega ou os dois (vazio)
  tipos_pedido   text[] not null default '{}',          -- vazio = todos os tipos
  chave          text not null check (chave ~ '^[a-z][a-z0-9_]{0,39}$'),
  rotulo         text not null,
  dica           text,
  tipo           text not null default 'texto' check (tipo in ('texto', 'numero', 'dinheiro', 'sim_nao', 'escolha', 'data', 'telefone', 'documento', 'foto')),
  opcoes         text[] not null default '{}',
  obrigatorio    boolean not null default false,
  quem_preenche  text not null default 'qualquer' check (quem_preenche in ('cliente', 'gestor', 'motoboy', 'qualquer')),
  visivel_cliente boolean not null default true,
  visivel_motoboy boolean not null default true,
  ordem          int not null default 0,
  ativo          boolean not null default true,
  criado_em      timestamptz not null default now()
);
create unique index if not exists campos_personalizados_chave_idx on public.campos_personalizados (coalesce(organizacao_id, '00000000-0000-0000-0000-000000000000'::uuid), entidade, chave);
alter table public.campos_personalizados enable row level security;

alter table public.pedidos       add column if not exists extras jsonb not null default '{}';
alter table public.pedido_pontos add column if not exists extras jsonb not null default '{}';
alter table public.paradas       add column if not exists respostas jsonb not null default '{}';
alter table public.empresas      add column if not exists extras jsonb not null default '{}';
alter table public.motoboys      add column if not exists extras jsonb not null default '{}';

-- campos que valem para uma empresa (os dela + os da plataforma)
create or replace function privado.campos_de(p_org uuid, p_entidade text, p_tipo text default null)
returns setof public.campos_personalizados language sql stable security definer set search_path = '' as $$
  select * from public.campos_personalizados c
   where c.ativo and c.entidade = p_entidade and (c.organizacao_id is null or c.organizacao_id = p_org)
     and (p_tipo is null or cardinality(c.tipos_pedido) = 0 or p_tipo = any (c.tipos_pedido))
   order by c.ordem, c.rotulo;
$$;

-- guarda só o que é campo de verdade (limpa o resto), no tamanho certo; obrigatório faltando → erro com o nome do campo
create or replace function privado.limpar_extras(p_org uuid, p_entidade text, p_tipo text, p_valor jsonb, p_quem text, p_exigir boolean default true)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare k public.campos_personalizados%rowtype; v jsonb := '{}'; x jsonb;
begin
  for k in select * from privado.campos_de(p_org, p_entidade, p_tipo) loop
    x := coalesce(p_valor, '{}') -> k.chave;
    if x is null or x = 'null'::jsonb or (jsonb_typeof(x) = 'string' and trim(x #>> '{}') = '') then
      if p_exigir and k.obrigatorio and k.quem_preenche in (p_quem, 'qualquer') then
        raise exception 'campo_obrigatorio:%', k.rotulo using errcode = '22023';
      end if;
      continue;
    end if;
    if k.tipo in ('numero', 'dinheiro') then
      if jsonb_typeof(x) <> 'number' and (x #>> '{}') !~ '^-?[0-9]+([.,][0-9]+)?$' then raise exception 'campo_invalido:%', k.rotulo using errcode = '22023'; end if;
      x := to_jsonb(replace(x #>> '{}', ',', '.')::numeric);
    elsif k.tipo = 'sim_nao' then
      x := to_jsonb(coalesce((x #>> '{}')::boolean, false));
    elsif k.tipo = 'escolha' and cardinality(k.opcoes) > 0 and not ((x #>> '{}') = any (k.opcoes)) then
      raise exception 'campo_invalido:%', k.rotulo using errcode = '22023';
    else
      x := to_jsonb(left(x #>> '{}', 500));
    end if;
    v := v || jsonb_build_object(k.chave, x);
  end loop;
  return v;
end;
$$;

-- quem lê: a equipe da empresa, o cliente e o motoboy (o app filtra o que mostra)
create or replace function public.campos_da_empresa(p_entidade text default null)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(to_jsonb(c) order by c.entidade, c.ordem, c.rotulo), '[]')
    from public.campos_personalizados c
   where c.ativo and (p_entidade is null or c.entidade = p_entidade)
     and (c.organizacao_id is null or c.organizacao_id = coalesce(public.minha_org(), privado.org_contexto(privado.minha_empresa(), null)));
$$;

-- editor (gestor da empresa ou Dev). Inativos também aparecem no editor.
create or replace function public.campos_editor()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not (public.is_dev() or public.is_gestor_pleno()) then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(to_jsonb(c) || jsonb_build_object('da_plataforma', c.organizacao_id is null) order by c.entidade, c.ordem, c.rotulo), '[]')
            from public.campos_personalizados c
           where (public.is_dev() and public.ve_org_ou_global(c.organizacao_id)) or c.organizacao_id = public.minha_org() or c.organizacao_id is null);
end;
$$;

create or replace function public.salvar_campo(p jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid := nullif(p ->> 'id', '')::uuid; v_org uuid; v_atual public.campos_personalizados%rowtype;
begin
  if not (public.is_dev() or public.is_gestor_pleno()) then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  perform privado.exigir_acao('campos_personalizados');
  if not public.is_dev() and not privado.cfg_org_bool(public.minha_org(), 'gestor_cria_campos', true) then raise exception 'acao_bloqueada' using errcode = '42501'; end if;
  -- Dev: "plataforma" = vale para todas; senão a empresa em foco. Gestor: sempre a empresa dele.
  v_org := case when public.is_dev() then case when coalesce((p ->> 'da_plataforma')::boolean, false) then null else public.minha_org() end else public.minha_org() end;
  if v_id is not null then
    select * into v_atual from public.campos_personalizados where id = v_id;
    if v_atual.id is null then raise exception 'campo_inexistente' using errcode = '22023'; end if;
    if not public.is_dev() and v_atual.organizacao_id is distinct from public.minha_org() then raise exception 'sem_permissao' using errcode = '42501'; end if;
    v_org := case when public.is_dev() then v_atual.organizacao_id else v_org end;
  end if;
  insert into public.campos_personalizados as c (id, organizacao_id, entidade, ponto_tipo, tipos_pedido, chave, rotulo, dica, tipo, opcoes, obrigatorio,
                                                 quem_preenche, visivel_cliente, visivel_motoboy, ordem, ativo)
  values (coalesce(v_id, gen_random_uuid()), v_org, p ->> 'entidade', nullif(p ->> 'ponto_tipo', ''),
          coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p -> 'tipos_pedido', '[]')) x), '{}'),
          left(trim(both '_' from lower(regexp_replace(translate(lower(coalesce(nullif(p ->> 'chave', ''), p ->> 'rotulo')),
               'áàâãäéèêëíìîïóòôõöúùûüçñ', 'aaaaaeeeeiiiiooooouuuucn'), '[^a-z0-9]+', '_', 'g'))), 40),
          left(trim(p ->> 'rotulo'), 80), nullif(left(trim(coalesce(p ->> 'dica', '')), 200), ''), coalesce(nullif(p ->> 'tipo', ''), 'texto'),
          coalesce((select array_agg(left(trim(x), 60)) from jsonb_array_elements_text(coalesce(p -> 'opcoes', '[]')) x where trim(x) <> ''), '{}'),
          coalesce((p ->> 'obrigatorio')::boolean, false), coalesce(nullif(p ->> 'quem_preenche', ''), 'qualquer'),
          coalesce((p ->> 'visivel_cliente')::boolean, true), coalesce((p ->> 'visivel_motoboy')::boolean, true),
          coalesce((p ->> 'ordem')::int, 0), coalesce((p ->> 'ativo')::boolean, true))
  on conflict (id) do update set entidade = excluded.entidade, ponto_tipo = excluded.ponto_tipo, tipos_pedido = excluded.tipos_pedido,
    rotulo = excluded.rotulo, dica = excluded.dica, tipo = excluded.tipo, opcoes = excluded.opcoes, obrigatorio = excluded.obrigatorio,
    quem_preenche = excluded.quem_preenche, visivel_cliente = excluded.visivel_cliente, visivel_motoboy = excluded.visivel_motoboy,
    ordem = excluded.ordem, ativo = excluded.ativo
  returning c.id into v_id;
  return v_id;
exception when unique_violation then raise exception 'campo_repetido' using errcode = '23505';
end;
$$;

create or replace function public.apagar_campo(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_org uuid;
begin
  if not (public.is_dev() or public.is_gestor_pleno()) then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  perform privado.exigir_acao('campos_personalizados');
  select organizacao_id into v_org from public.campos_personalizados where id = p_id;
  if not public.is_dev() and v_org is distinct from public.minha_org() then raise exception 'sem_permissao' using errcode = '42501'; end if;
  delete from public.campos_personalizados where id = p_id;
end;
$$;

-- valores dos campos de um cliente (empresa) ou motoboy, pelo gestor
create or replace function public.salvar_extras(p_entidade text, p_alvo uuid, p_valores jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_org uuid; v jsonb;
begin
  if p_entidade = 'cliente' then
    select organizacao_id into v_org from public.empresas where id = p_alvo;
    if v_org is null or not (public.is_gestor() and public.ve_org(v_org)) then raise exception 'sem_permissao' using errcode = '42501'; end if;
    v := privado.limpar_extras(v_org, 'cliente', null, p_valores, 'gestor');
    update public.empresas set extras = v where id = p_alvo;
  elsif p_entidade = 'motoboy' then
    if not (public.pode_gerenciar(p_alvo) or (p_alvo = auth.uid())) then raise exception 'sem_permissao' using errcode = '42501'; end if;
    v_org := (select organizacao_id from public.perfis where id = p_alvo);
    v := privado.limpar_extras(v_org, 'motoboy', null, p_valores, case when p_alvo = auth.uid() then 'motoboy' else 'gestor' end);
    update public.motoboys set extras = v where id = p_alvo;
  else raise exception 'entidade_invalida' using errcode = '22023';
  end if;
  return v;
end;
$$;

revoke execute on function public.campos_da_empresa(text), public.campos_editor(), public.salvar_campo(jsonb), public.apagar_campo(uuid),
  public.salvar_extras(text, uuid, jsonb) from public, anon;
grant execute on function public.campos_da_empresa(text), public.campos_editor(), public.salvar_campo(jsonb), public.apagar_campo(uuid),
  public.salvar_extras(text, uuid, jsonb) to authenticated;

-- ===================================================================== nomes próprios
-- alvo: 'pedido:<status>', 'rota:<status>', 'parada:coleta', 'parada:entrega'. tipo_pedido vazio = todos os tipos.
create table if not exists public.rotulos (
  organizacao_id uuid,
  tipo_pedido    text not null default '',
  alvo           text not null check (alvo ~ '^(pedido|rota|parada):[a-z_]+$'),
  texto          text not null
);
create unique index if not exists rotulos_unico_idx on public.rotulos (coalesce(organizacao_id, '00000000-0000-0000-0000-000000000000'::uuid), tipo_pedido, alvo);
alter table public.rotulos enable row level security;

-- mapa "tipo|alvo" → texto: o da empresa vence o da plataforma
create or replace function privado.rotulos_de(p_org uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_object_agg(k, t), '{}') from (
    select distinct on (r.tipo_pedido, r.alvo) r.tipo_pedido || '|' || r.alvo k, r.texto t
      from public.rotulos r where r.organizacao_id is null or r.organizacao_id = p_org
     order by r.tipo_pedido, r.alvo, (r.organizacao_id is null)) x;
$$;

create or replace function public.meus_rotulos()
returns jsonb language sql stable security definer set search_path = '' as $$
  select privado.rotulos_de(coalesce(public.minha_org(), privado.org_contexto(privado.minha_empresa(), null)));
$$;

create or replace function public.salvar_rotulo(p_alvo text, p_texto text, p_tipo_pedido text default '', p_plataforma boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_org uuid := case when public.is_dev() and p_plataforma then null else public.minha_org() end;
begin
  if not (public.is_dev() or public.is_gestor_pleno()) then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  perform privado.exigir_acao('rotulos');
  if v_org is null and not public.is_dev() then raise exception 'sem_empresa' using errcode = '22023'; end if;
  delete from public.rotulos where organizacao_id is not distinct from v_org and tipo_pedido = coalesce(p_tipo_pedido, '') and alvo = p_alvo;
  if nullif(trim(coalesce(p_texto, '')), '') is not null then
    insert into public.rotulos (organizacao_id, tipo_pedido, alvo, texto) values (v_org, coalesce(p_tipo_pedido, ''), p_alvo, left(trim(p_texto), 60));
  end if;
  return public.meus_rotulos();
end;
$$;

create or replace function public.rotulos_editor()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not (public.is_dev() or public.is_gestor_pleno()) then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('alvo', r.alvo, 'tipo_pedido', r.tipo_pedido, 'texto', r.texto, 'da_plataforma', r.organizacao_id is null)), '[]')
            from public.rotulos r where r.organizacao_id is null or r.organizacao_id = public.minha_org());
end;
$$;
revoke execute on function public.meus_rotulos(), public.salvar_rotulo(text, text, text, boolean), public.rotulos_editor() from public, anon;
grant execute on function public.meus_rotulos(), public.salvar_rotulo(text, text, text, boolean), public.rotulos_editor() to authenticated;

-- ===================================================================== regras extras de preço e pagamento
create table if not exists public.regras_extras (
  id             uuid primary key default gen_random_uuid(),
  organizacao_id uuid,
  alvo           text not null check (alvo in ('preco', 'pagamento')),
  nome           text not null,
  unidade        text not null check (unidade in ('fixo', 'km', 'ponto', 'coleta', 'entrega', 'volume', 'kg', 'minuto_parado', 'pct_subtotal', 'pct_declarado', 'pct_rota')),
  valor          numeric not null default 0,
  franquia       numeric not null default 0,      -- quantos da unidade não cobram (ex.: 10 min de espera grátis, 5 km inclusos)
  minimo         numeric,
  maximo         numeric,
  condicoes      jsonb not null default '{}',     -- dias [0..6], de, ate (HH:MM), tipos, clientes, motoboys, veiculos, urgente, km_min, km_max
  limitar_ao_valor boolean not null default false, -- pagamento: soma dentro do teto (valor da rota)
  ativo          boolean not null default true,
  ordem          int not null default 0,
  criado_em      timestamptz not null default now()
);
alter table public.regras_extras enable row level security;

-- uma regra vale neste contexto?
create or replace function privado.regra_vale(r public.regras_extras, x jsonb)
returns boolean language plpgsql stable set search_path = '' as $$
declare c jsonb := coalesce(r.condicoes, '{}'); v_q timestamptz := coalesce(nullif(x ->> 'quando', '')::timestamptz, now());
  v_h time := (v_q at time zone 'America/Sao_Paulo')::time; v_dow int := extract(dow from v_q at time zone 'America/Sao_Paulo')::int;
begin
  if jsonb_typeof(c -> 'dias') = 'array' and jsonb_array_length(c -> 'dias') > 0 and not (c -> 'dias') @> to_jsonb(v_dow) then return false; end if;
  if nullif(c ->> 'de', '') is not null and nullif(c ->> 'ate', '') is not null then
    if (c ->> 'ate')::time > (c ->> 'de')::time then
      if not (v_h >= (c ->> 'de')::time and v_h < (c ->> 'ate')::time) then return false; end if;
    elsif not (v_h >= (c ->> 'de')::time or v_h < (c ->> 'ate')::time) then return false; end if;
  end if;
  if jsonb_typeof(c -> 'tipos') = 'array' and jsonb_array_length(c -> 'tipos') > 0 and not (c -> 'tipos') ? coalesce(x ->> 'tipo', 'padrao') then return false; end if;
  if jsonb_typeof(c -> 'clientes') = 'array' and jsonb_array_length(c -> 'clientes') > 0 and not (c -> 'clientes') ? coalesce(x ->> 'cliente', '') then return false; end if;
  if jsonb_typeof(c -> 'motoboys') = 'array' and jsonb_array_length(c -> 'motoboys') > 0 and not (c -> 'motoboys') ? coalesce(x ->> 'motoboy', '') then return false; end if;
  if jsonb_typeof(c -> 'veiculos') = 'array' and jsonb_array_length(c -> 'veiculos') > 0 and not (c -> 'veiculos') ? coalesce(x ->> 'veiculo', '') then return false; end if;
  if c ? 'urgente' and (c ->> 'urgente')::boolean is distinct from coalesce((x ->> 'urgente')::boolean, false) then return false; end if;
  if nullif(c ->> 'km_min', '') is not null and coalesce((x ->> 'km')::numeric, 0) < (c ->> 'km_min')::numeric then return false; end if;
  if nullif(c ->> 'km_max', '') is not null and coalesce((x ->> 'km')::numeric, 0) > (c ->> 'km_max')::numeric then return false; end if;
  return true;
end;
$$;

-- linhas das regras que valem: [{rotulo, detalhe, qtd, unit, unidade, valor, extra:true, limitar}]
create or replace function privado.regras_extras_linhas(p_alvo text, p_org uuid, x jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r public.regras_extras%rowtype; v_out jsonb := '[]'; v_q numeric; v_val numeric; v_base numeric;
begin
  for r in select * from public.regras_extras where ativo and alvo = p_alvo and (organizacao_id is null or organizacao_id = p_org) order by ordem, criado_em loop
    if not privado.regra_vale(r, x) then continue; end if;
    v_q := case r.unidade when 'fixo' then 1 when 'km' then coalesce((x ->> 'km')::numeric, 0)
             when 'ponto' then coalesce((x ->> 'coletas')::numeric, 0) + coalesce((x ->> 'entregas')::numeric, 0)
             when 'coleta' then coalesce((x ->> 'coletas')::numeric, 0) when 'entrega' then coalesce((x ->> 'entregas')::numeric, 0)
             when 'volume' then coalesce((x ->> 'volumes')::numeric, 0) when 'kg' then coalesce((x ->> 'kg')::numeric, 0)
             when 'minuto_parado' then coalesce((x ->> 'minutos_parado')::numeric, 0)
             else null end;
    if v_q is not null then
      v_q := greatest(0, v_q - r.franquia);
      v_val := round(v_q * r.valor, 2);
    else
      v_base := case r.unidade when 'pct_subtotal' then coalesce((x ->> 'subtotal')::numeric, 0)
                               when 'pct_declarado' then coalesce((x ->> 'declarado')::numeric, 0)
                               when 'pct_rota' then coalesce((x ->> 'valor_rota')::numeric, 0) else 0 end;
      v_val := round(greatest(0, v_base - r.franquia) * r.valor / 100, 2);
    end if;
    if r.minimo is not null and v_val <> 0 then v_val := greatest(v_val, r.minimo); end if;
    if r.maximo is not null then v_val := least(v_val, r.maximo); end if;
    if v_val = 0 then continue; end if;
    v_out := v_out || jsonb_build_object('chave', 'extra_' || r.id, 'rotulo', r.nome, 'valor', v_val, 'extra', true, 'fixo', true,
      'limitar', r.limitar_ao_valor, 'unidade', r.unidade, 'unit', r.valor, 'qtd', v_q,
      'detalhe', case when v_q is not null and r.unidade <> 'fixo' then format('%s %s × R$ %s', round(v_q, 2), replace(r.unidade, '_', ' '), r.valor)
                      when v_q is null then format('%s%% de R$ %s', r.valor, round(v_base, 2)) end);
  end loop;
  return v_out;
end;
$$;

create or replace function public.regras_extras_editor()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not (public.is_dev() or public.is_gestor_pleno()) then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(to_jsonb(r) || jsonb_build_object('da_plataforma', r.organizacao_id is null) order by r.alvo, r.ordem, r.criado_em), '[]')
            from public.regras_extras r where r.organizacao_id is null or r.organizacao_id = public.minha_org() or (public.is_dev() and public.ve_org_ou_global(r.organizacao_id)));
end;
$$;

create or replace function public.salvar_regra_extra(p jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid := nullif(p ->> 'id', '')::uuid; v_org uuid; v_atual public.regras_extras%rowtype;
begin
  if not (public.is_dev() or public.is_gestor_pleno()) then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  perform privado.exigir_acao('regras_extras');
  if p ->> 'alvo' = 'pagamento' then perform privado.exigir_acao('editar_pagamento_motoboy'); else perform privado.exigir_acao('editar_valor_pedido'); end if;
  v_org := case when public.is_dev() and coalesce((p ->> 'da_plataforma')::boolean, false) then null else public.minha_org() end;
  if v_org is null and not public.is_dev() then raise exception 'sem_empresa' using errcode = '22023'; end if;
  if v_id is not null then
    select * into v_atual from public.regras_extras where id = v_id;
    if v_atual.id is null then raise exception 'regra_inexistente' using errcode = '22023'; end if;
    if not public.is_dev() and v_atual.organizacao_id is distinct from public.minha_org() then raise exception 'sem_permissao' using errcode = '42501'; end if;
    if public.is_dev() then v_org := v_atual.organizacao_id; end if;
  end if;
  insert into public.regras_extras as r (id, organizacao_id, alvo, nome, unidade, valor, franquia, minimo, maximo, condicoes, limitar_ao_valor, ativo, ordem)
  values (coalesce(v_id, gen_random_uuid()), v_org, p ->> 'alvo', left(trim(p ->> 'nome'), 80), p ->> 'unidade',
          coalesce((p ->> 'valor')::numeric, 0), coalesce((p ->> 'franquia')::numeric, 0), nullif(p ->> 'minimo', '')::numeric, nullif(p ->> 'maximo', '')::numeric,
          coalesce(p -> 'condicoes', '{}'), coalesce((p ->> 'limitar_ao_valor')::boolean, false), coalesce((p ->> 'ativo')::boolean, true), coalesce((p ->> 'ordem')::int, 0))
  on conflict (id) do update set alvo = excluded.alvo, nome = excluded.nome, unidade = excluded.unidade, valor = excluded.valor, franquia = excluded.franquia,
    minimo = excluded.minimo, maximo = excluded.maximo, condicoes = excluded.condicoes, limitar_ao_valor = excluded.limitar_ao_valor,
    ativo = excluded.ativo, ordem = excluded.ordem
  returning r.id into v_id;
  return v_id;
end;
$$;

create or replace function public.apagar_regra_extra(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_org uuid;
begin
  if not (public.is_dev() or public.is_gestor_pleno()) then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  perform privado.exigir_acao('regras_extras');
  select organizacao_id into v_org from public.regras_extras where id = p_id;
  if not public.is_dev() and v_org is distinct from public.minha_org() then raise exception 'sem_permissao' using errcode = '42501'; end if;
  delete from public.regras_extras where id = p_id;
end;
$$;
revoke execute on function public.regras_extras_editor(), public.salvar_regra_extra(jsonb), public.apagar_regra_extra(uuid) from public, anon;
grant execute on function public.regras_extras_editor(), public.salvar_regra_extra(jsonb), public.apagar_regra_extra(uuid) to authenticated;

-- ===================================================================== cargos personalizados
create table if not exists public.cargos (
  id             uuid primary key default gen_random_uuid(),
  organizacao_id uuid not null,
  nome           text not null,
  icone          text,
  permissoes     jsonb not null default '{}',   -- as permissões de supervisor (pedidos, rotas, mapa, financeiro…)
  acoes          jsonb not null default '{}',   -- ações liga/desliga só para quem tem este cargo (acao → false bloqueia)
  criado_em      timestamptz not null default now(),
  unique (organizacao_id, nome)
);
alter table public.cargos enable row level security;
alter table public.perfis add column if not exists cargo_id uuid references public.cargos (id) on delete set null;

create or replace function public.cargos_da_empresa()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(to_jsonb(c) || jsonb_build_object('pessoas', (select count(*) from public.perfis p where p.cargo_id = c.id)) order by c.nome), '[]')
    from public.cargos c where c.organizacao_id = public.minha_org() and public.is_gestor();
$$;

create or replace function public.salvar_cargo(p jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid := nullif(p ->> 'id', '')::uuid;
begin
  if not (public.is_dev() or public.is_gestor_pleno()) then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  perform privado.exigir_acao('cargos_personalizados');
  if public.minha_org() is null then raise exception 'sem_empresa' using errcode = '22023'; end if;
  if v_id is not null and not exists (select 1 from public.cargos where id = v_id and organizacao_id = public.minha_org()) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  insert into public.cargos as c (id, organizacao_id, nome, icone, permissoes, acoes)
  values (coalesce(v_id, gen_random_uuid()), public.minha_org(), left(trim(p ->> 'nome'), 40), nullif(p ->> 'icone', ''),
          coalesce(p -> 'permissoes', '{}'), coalesce(p -> 'acoes', '{}'))
  on conflict (id) do update set nome = excluded.nome, icone = excluded.icone, permissoes = excluded.permissoes, acoes = excluded.acoes
  returning c.id into v_id;
  -- quem já tem o cargo recebe as permissões novas
  update public.perfis set permissoes = (select permissoes from public.cargos where id = v_id) where cargo_id = v_id;
  return v_id;
exception when unique_violation then raise exception 'cargo_repetido' using errcode = '23505';
end;
$$;

create or replace function public.apagar_cargo(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not (public.is_dev() or public.is_gestor_pleno()) then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  perform privado.exigir_acao('cargos_personalizados');
  delete from public.cargos where id = p_id and organizacao_id = public.minha_org();
end;
$$;

-- dar um cargo a alguém da equipe: vira supervisor com as permissões do cargo (null tira o cargo e mantém as permissões)
create or replace function public.definir_cargo_pessoa(p_pessoa uuid, p_cargo uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare k public.cargos%rowtype;
begin
  if not (public.is_dev() or public.is_gestor_pleno()) then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  perform privado.exigir_acao('cargos_personalizados');
  if not public.pode_gerenciar(p_pessoa) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if p_cargo is null then update public.perfis set cargo_id = null where id = p_pessoa; return; end if;
  select * into k from public.cargos where id = p_cargo and organizacao_id = (select organizacao_id from public.perfis where id = p_pessoa);
  if k.id is null then raise exception 'cargo_inexistente' using errcode = '22023'; end if;
  if not exists (select 1 from public.perfis where id = p_pessoa and 'supervisor' = any (papeis)) then
    raise exception 'so_supervisor' using errcode = '22023';
  end if;
  update public.perfis set cargo_id = k.id, permissoes = k.permissoes where id = p_pessoa;
end;
$$;
revoke execute on function public.cargos_da_empresa(), public.salvar_cargo(jsonb), public.apagar_cargo(uuid), public.definir_cargo_pessoa(uuid, uuid) from public, anon;
grant execute on function public.cargos_da_empresa(), public.salvar_cargo(jsonb), public.apagar_cargo(uuid), public.definir_cargo_pessoa(uuid, uuid) to authenticated;

-- ===================================================================== módulos por empresa
create table if not exists public.modulos_empresa (
  organizacao_id uuid not null,
  chave          text not null references public.modulos (chave) on delete cascade,
  ligado         boolean not null,
  primary key (organizacao_id, chave)
);
alter table public.modulos_empresa enable row level security;

create or replace function public.definir_modulo_empresa(p_org uuid, p_chave text, p_ligado boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  if p_ligado is null then delete from public.modulos_empresa where organizacao_id = p_org and chave = p_chave;
  else insert into public.modulos_empresa values (p_org, p_chave, p_ligado) on conflict (organizacao_id, chave) do update set ligado = excluded.ligado; end if;
end;
$$;
create or replace function public.modulos_da_empresa(p_org uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when public.is_dev() then coalesce((select jsonb_object_agg(chave, ligado) from public.modulos_empresa where organizacao_id = p_org), '{}') end;
$$;
revoke execute on function public.definir_modulo_empresa(uuid, text, boolean), public.modulos_da_empresa(uuid) from public, anon;
grant execute on function public.definir_modulo_empresa(uuid, text, boolean), public.modulos_da_empresa(uuid) to authenticated;

-- ligado de verdade para esta pessoa: empresa (se o Dev definiu) > geral; papéis do módulo valem sempre
create or replace function privado.modulo_ligado(p_chave text, p_pessoa uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((
    select 'dev' = any (p.papeis) or (coalesce(me.ligado, m.ligado) and (m.papeis is null or p.papeis && m.papeis))
      from public.modulos m join public.perfis p on p.id = p_pessoa
      left join public.modulos_empresa me on me.chave = m.chave and me.organizacao_id = p.organizacao_id
     where m.chave = p_chave), true);
$$;

create or replace function public.modulo_ativo(p_chave text)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.is_dev() or privado.modulo_ligado(p_chave, auth.uid());
$$;

-- ===================================================================== veículo
alter table public.pedidos add column if not exists veiculo text check (veiculo in ('moto', 'carro', 'bicicleta', 'van', 'outro'));

-- veículos que podem levar esta rota: o que o pedido pediu, senão o que o cliente/tipo aceita (vazio = qualquer)
create or replace function privado.veiculos_da_corrida(p_corrida uuid)
returns text[] language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select array_agg(distinct pe.veiculo) from public.paradas pa join public.pedidos pe on pe.id = pa.pedido_id where pa.corrida_id = p_corrida and pe.veiculo is not null),
    (select array(select jsonb_array_elements_text(case when jsonb_typeof(v) = 'array' then v else '[]' end))
       from (select privado.pol('veiculos_aceitos', c.empresa_id, null, c.tipo_pedido) v from public.corridas c where c.id = p_corrida) x),
    '{}');
$$;
create or replace function privado.veiculo_serve(p_motoboy uuid, p_corrida uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select cardinality(privado.veiculos_da_corrida(p_corrida)) = 0
      or coalesce((select veiculo_tipo from public.motoboys where id = p_motoboy), 'moto') = any (privado.veiculos_da_corrida(p_corrida));
$$;

-- ===================================================================== API: limite de chamadas
alter table public.api_chaves add column if not exists janela_minuto timestamptz;
alter table public.api_chaves add column if not exists janela_usos int not null default 0;


create or replace function privado.acoes_gestor()
returns text[] language sql immutable as $$
  select array['criar_contas', 'excluir_contas', 'editar_cargos', 'apagar_historico', 'exportar_dados', 'editar_valor_pedido',
               'editar_pagamento_motoboy', 'ajuste_holerite', 'fechar_holerite', 'emitir_fatura', 'cancelar_rota', 'voltar_revisao',
               'chat_apagar', 'mudar_marca', 'modo_teste', 'ver_carteira', 'regras_por_cliente', 'regras_por_motoboy', 'penalidades', 'forcar_inicio',
               'integracao_api', 'campos_personalizados', 'regras_extras', 'cargos_personalizados', 'rotulos'];
$$;

create or replace function privado.exigir_acao(p_acao text)
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null or public.is_dev() then return; end if;
  if not privado.gestor_pode_acao(public.minha_org(), p_acao)
     or coalesce((select (k.acoes ->> p_acao)::boolean from public.perfis pf join public.cargos k on k.id = pf.cargo_id where pf.id = auth.uid()), true) = false then
    raise exception 'acao_bloqueada' using errcode = '42501', detail = p_acao;
  end if;
end;
$$;
create or replace function privado.orcar(d jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
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
  v_guc    text := current_setting('pwex.regras', true);
  v_soma   boolean;
  v_pt     jsonb;
  v_col    jsonb;
  v_n      int := 0;
  v_d      numeric;
  v_fr     numeric;
  v_reta   boolean;
  v_org    uuid := privado.org_contexto(nullif(d ->> 'empresa_id', '')::uuid);
begin
  -- regras do pedido (salvo ou ainda no formulário)
  if nullif(d ->> 'pedido_id', '') is not null then
    perform privado.usar_regras((select regras from public.pedidos where id = (d ->> 'pedido_id')::uuid));
  elsif d ? 'regras' then
    perform privado.usar_regras(d -> 'regras');
  end if;
  if v_cli is not null then select * into e from public.empresas where id = v_cli; end if;
  select count(*) filter (where x ->> 'tipo' = 'coleta'), count(*) filter (where x ->> 'tipo' = 'entrega')
    into v_ncol, v_nent from jsonb_array_elements(coalesce(d -> 'pontos', '[]')) x;
  v_reta := privado.pol_txt('orcamento_trajeto', 'ruas', v_cli, null, v_tp) = 'reta';
  v_dist := coalesce(case when v_reta then null else nullif(d ->> 'distancia_m', '')::numeric end,
                     privado.distancia_estimada(d -> 'pontos') * privado.pol_num('fator_rua', 1.3, v_cli, null, v_tp));
  v_km := round(v_dist / 1000.0, 2);
  v_soma := privado.pol_txt('preco_distancia_modo', 'soma_entregas', v_cli, null, v_tp) = 'soma_entregas';
  v_fr := privado.pol_num('fator_rua', 1.3, v_cli, null, v_tp);

  -- base e distância (o preço fixo do cadastro antigo do cliente ainda vale)
  if e.id is not null and e.modalidade_preco::text = 'fixo' and e.valor_fixo is not null
     and not exists (select 1 from public.politicas where escopo = 'cliente' and alvo = v_cli::text and chave in ('preco_base', 'preco_km'))
     and not (coalesce(nullif(current_setting('pwex.regras', true), '')::jsonb, '{}') ?| array['preco_base', 'preco_km']) then
    v_fixo_cliente := true;
    v_linhas := v_linhas || jsonb_build_object('rotulo', 'Preço fixo do cliente', 'valor', e.valor_fixo);
    v_sub := v_sub + e.valor_fixo;
  else
    v_val := privado.pol_num('preco_base', 8, v_cli, null, v_tp);
    if v_soma and not privado.pol_bool('soma_inclui_saida', false, v_cli, null, v_tp) then v_val := 0; end if;
    if v_val <> 0 then v_linhas := v_linhas || jsonb_build_object('chave', 'saida', 'rotulo', 'Saída', 'valor', v_val); v_sub := v_sub + v_val; end if;
    v_vkm := privado.pol_num('preco_km', 2.5, v_cli, null, v_tp);
    if e.id is not null and e.modalidade_preco::text = 'por_km' and e.valor_km is not null
       and not exists (select 1 from public.politicas where escopo = 'cliente' and alvo = v_cli::text and chave = 'preco_km')
       and not (coalesce(nullif(current_setting('pwex.regras', true), '')::jsonb, '{}') ? 'preco_km') then
      v_vkm := e.valor_km;
    end if;
    if v_soma then
      -- soma das entregas: cada entrega = valor/km × distância da coleta dela (a coleta anterior na lista; sem ela, a primeira)
      v_dist := 0;
      v_col := (select x from jsonb_array_elements(coalesce(d -> 'pontos', '[]')) x where x ->> 'tipo' = 'coleta' limit 1);
      for v_pt in select * from jsonb_array_elements(coalesce(d -> 'pontos', '[]')) loop
        if v_pt ->> 'tipo' = 'coleta' then v_col := v_pt; continue; end if;
        v_n := v_n + 1;
        v_d := coalesce(case when v_reta then null else nullif(v_pt ->> 'dist_coleta_m', '')::numeric end,
                        privado.dist_m((v_col ->> 'lat')::double precision, (v_col ->> 'lng')::double precision,
                                       (v_pt ->> 'lat')::double precision, (v_pt ->> 'lng')::double precision) * v_fr, 0);
        v_dist := v_dist + v_d;
        v_val := round(round(v_d / 1000.0, 2) * v_vkm, 2);
        v_linhas := v_linhas || jsonb_build_object('chave', 'entrega_' || v_n, 'rotulo', case when v_nent > 1 then 'Entrega ' || v_n else 'Entrega' end,
          'detalhe', format('coleta → entrega: %s km × R$ %s', round(v_d / 1000.0, 2), v_vkm), 'qtd', round(v_d / 1000.0, 2), 'unit', v_vkm, 'unidade', 'km', 'valor', v_val);
        v_sub := v_sub + v_val;
      end loop;
      v_km := round(v_dist / 1000.0, 2);
    else
      v_val := round(v_km * v_vkm, 2);
      v_linhas := v_linhas || jsonb_build_object('chave', 'distancia', 'rotulo', 'Distância', 'detalhe', format('%s km × R$ %s', v_km, v_vkm), 'qtd', v_km, 'unit', v_vkm, 'unidade', 'km', 'valor', v_val);
      v_sub := v_sub + v_val;
    end if;
  end if;

  -- pontos extras
  if v_ncol > 1 then
    v_val := (v_ncol - 1) * privado.pol_num('preco_coleta_extra', 5, v_cli, null, v_tp);
    if v_val <> 0 then v_linhas := v_linhas || jsonb_build_object('rotulo', 'Coletas extras', 'detalhe', format('%s × R$ %s', v_ncol - 1, privado.pol_num('preco_coleta_extra', 5, v_cli, null, v_tp)), 'qtd', v_ncol - 1, 'unit', privado.pol_num('preco_coleta_extra', 5, v_cli, null, v_tp), 'unidade', 'coleta', 'valor', v_val); v_sub := v_sub + v_val; end if;
  end if;
  if v_nent > 1 and (not v_soma or v_fixo_cliente or privado.pol_bool('soma_inclui_entrega_extra', false, v_cli, null, v_tp)) then
    v_val := (v_nent - 1) * privado.pol_num('preco_entrega_extra', 5, v_cli, null, v_tp);
    if v_val <> 0 then v_linhas := v_linhas || jsonb_build_object('rotulo', 'Entregas extras', 'detalhe', format('%s × R$ %s', v_nent - 1, privado.pol_num('preco_entrega_extra', 5, v_cli, null, v_tp)), 'qtd', v_nent - 1, 'unit', privado.pol_num('preco_entrega_extra', 5, v_cli, null, v_tp), 'unidade', 'entrega', 'valor', v_val); v_sub := v_sub + v_val; end if;
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
    if v_val <> 0 then v_linhas := v_linhas || jsonb_build_object('rotulo', 'Volumes extras', 'detalhe', format('%s volume(s) além do incluso', v_x), 'qtd', v_x, 'unit', privado.pol_num('preco_pacote_extra', 1, v_cli, null, v_tp), 'unidade', 'volume', 'valor', v_val); v_sub := v_sub + v_val; end if;
  end if;
  v_tax := round(greatest(v_real, v_cub), 2);
  v_x := greatest(0, v_tax - privado.pol_num('preco_kg_incluso', 5, v_cli, null, v_tp));
  if v_x > 0 then
    v_val := round(v_x * privado.pol_num('preco_kg', 1, v_cli, null, v_tp), 2);
    if v_val <> 0 then
      v_linhas := v_linhas || jsonb_build_object('rotulo', 'Peso excedente',
        'detalhe', format('%s kg taxados (%s)', v_tax, case when v_cub > v_real then 'peso cubado' else 'peso real' end), 'qtd', v_x, 'unit', privado.pol_num('preco_kg', 1, v_cli, null, v_tp), 'unidade', 'kg', 'valor', v_val);
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
    if v_val <> 0 then v_linhas := v_linhas || jsonb_build_object('rotulo', 'Produto perigoso', 'fixo', true, 'valor', v_val); v_fixos := v_fixos + v_val; end if;
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
   where z.ativa and (z.organizacao_id is null or z.organizacao_id = v_org) and (z.cliente_id = v_cli
          or (z.cliente_id is null and not (privado.pol_bool('zona_cliente_exclusiva', false, v_cli, null, v_tp)
                                            and exists (select 1 from public.zonas zz where zz.ativa and zz.cliente_id = v_cli and (zz.organizacao_id is null or zz.organizacao_id = v_org)))))
     and exists (select 1 from jsonb_array_elements(coalesce(d -> 'pontos', '[]')) x
                  where privado.dist_m(z.lat, z.lng, (x ->> 'lat')::double precision, (x ->> 'lng')::double precision) <= z.raio_m);
  if v_za <> 0 then v_linhas := v_linhas || jsonb_build_object('rotulo', 'Zona', 'detalhe', array_to_string(v_znomes, ', '), 'fixo', true, 'valor', v_za); v_fixos := v_fixos + v_za; end if;
  if v_zp <> 0 then v_pcts := v_pcts || jsonb_build_object('rotulo', 'Zona: ' || array_to_string(v_znomes, ', '), 'pct', v_zp); v_pct := v_pct + v_zp; end if;

  -- horário de pico (pelo horário da coleta)
  select f.fator_pct, f.adicional, f.nome into v_hp, v_ha, v_hnome
    from public.faixas_horario f
   where f.ativa and (f.organizacao_id is null or f.organizacao_id = v_org) and (f.cliente_id is null or f.cliente_id = v_cli)
     and extract(dow from v_quando at time zone 'America/Sao_Paulo')::int = any (f.dias)
     and (case when f.fim > f.inicio
               then (v_quando at time zone 'America/Sao_Paulo')::time >= f.inicio and (v_quando at time zone 'America/Sao_Paulo')::time < f.fim
               else (v_quando at time zone 'America/Sao_Paulo')::time >= f.inicio or (v_quando at time zone 'America/Sao_Paulo')::time < f.fim end)
   order by (f.cliente_id is null), f.fator_pct desc, f.adicional desc limit 1;
  if coalesce(v_ha, 0) <> 0 then v_linhas := v_linhas || jsonb_build_object('rotulo', v_hnome, 'fixo', true, 'valor', v_ha); v_fixos := v_fixos + v_ha; end if;
  if coalesce(v_hp, 0) <> 0 then v_pcts := v_pcts || jsonb_build_object('rotulo', v_hnome, 'pct', v_hp); v_pct := v_pct + v_hp; end if;

  -- regras extras da empresa e da plataforma (blocos montados no editor)
  for v_pt in select * from jsonb_array_elements(privado.regras_extras_linhas('preco', v_org, jsonb_build_object(
      'quando', v_quando, 'tipo', v_tp, 'cliente', v_cli, 'veiculo', d ->> 'veiculo', 'urgente', coalesce((d ->> 'urgente')::boolean, false),
      'km', v_km, 'coletas', v_ncol, 'entregas', v_nent, 'volumes', v_pac, 'kg', v_tax, 'subtotal', v_sub,
      'declarado', (select coalesce(sum(coalesce((i ->> 'quantidade')::int, 1) * coalesce((i ->> 'valor_declarado')::numeric, 0)), 0) from jsonb_array_elements(coalesce(d -> 'itens', '[]')) i)))) loop
    v_linhas := v_linhas || v_pt; v_fixos := v_fixos + (v_pt ->> 'valor')::numeric;
  end loop;
  v_total := v_sub * (1 + v_pct / 100.0) + v_fixos;
  v_min := privado.pol_num('valor_minimo', 0, v_cli, null, v_tp);
  v_total := privado.arredondar(greatest(v_total, v_min));
  perform set_config('pwex.regras', coalesce(v_guc, ''), true);
  return jsonb_build_object(
    'linhas', v_linhas, 'percentuais', v_pcts, 'subtotal', round(v_sub + v_fixos, 2), 'acrescimo_pct', v_pct,
    'minimo', v_min, 'total', v_total, 'trajeto', case when v_reta then 'reta' else 'ruas' end, 'modo_distancia', case when v_fixo_cliente then 'fixo' when v_soma then 'soma_entregas' else 'rota' end, 'km', v_km, 'distancia_m', round(v_dist),
    'coletas', v_ncol, 'entregas', v_nent, 'volumes', v_pac, 'peso_real_kg', round(v_real, 2), 'peso_cubado_kg', round(v_cub, 2),
    'peso_taxado_kg', v_tax, 'perigoso', v_perig, 'calculado_em', now());
end;
$$;
create or replace function privado.calcular_pagamento(p_corrida uuid, p_motoboy uuid default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  c        public.corridas%rowtype;
  v_m      uuid;
  v_ant    text := current_setting('pwex.regras', true);
  v_rr     jsonb;
  v_modos  text[];
  v_comb   text;
  v_parte  jsonb;
  v_partes jsonb := '[]';
  v_vals   numeric[] := '{}';
  v_t      numeric;
  v_acr    numeric; v_acrp numeric;
  v_teto   numeric;
  v_modo   text;
  v_res    jsonb;
  v_vkm    numeric; v_vm numeric; v_vv numeric; v_ult public.paradas%rowtype; v_ini public.paradas%rowtype;
begin
  select * into c from public.corridas where id = p_corrida;
  if not found then return null; end if;
  c.valor := coalesce(nullif(current_setting('pwex.valor_rota', true), '')::numeric, c.valor);
  v_m := coalesce(p_motoboy, c.motoboy_id);
  v_rr := coalesce(nullif(current_setting('pwex.pag_regras_rota', true), '')::jsonb, c.pag_regras, '{}');
  if v_rr <> '{}' then
    perform set_config('pwex.regras', (coalesce(nullif(v_ant, '')::jsonb, '{}') || v_rr)::text, true);
  end if;
  begin
    select array_agg(x) into v_modos from jsonb_array_elements_text(
      case when jsonb_typeof(privado.pol('pag_modos', c.empresa_id, v_m, c.tipo_pedido)) = 'array' then privado.pol('pag_modos', c.empresa_id, v_m, c.tipo_pedido) else '[]' end) x
     where x in ('zonas', 'rota', 'percentual', 'por_entrega', 'fixo', 'salario', 'diaria', 'por_hora');
    if coalesce(array_length(v_modos, 1), 0) = 0 then v_modos := array[privado.pol_txt('pag_modo', 'zonas', c.empresa_id, v_m, c.tipo_pedido)]; end if;
    -- salário, diária e hora entram no holerite do período, não na rota
    v_modos := array(select x from unnest(v_modos) x where x not in ('salario', 'diaria', 'por_hora'));
    v_comb := privado.pol_txt('pag_combinar', 'soma', c.empresa_id, v_m, c.tipo_pedido);
    v_acr := privado.pol_num('pag_acrescimo_rota', 0, c.empresa_id, v_m, c.tipo_pedido);
    v_acrp := privado.pol_num('pag_acrescimo_pct', 0, c.empresa_id, v_m, c.tipo_pedido);
    foreach v_modo in array v_modos loop
      v_parte := case v_modo when 'por_entrega' then privado.pag_por_entrega(p_corrida, v_m)
                             when 'fixo' then privado.pag_fixo(p_corrida, v_m)
                             else privado.calcular_pagamento_um(p_corrida, v_m, v_modo) end;
      v_partes := v_partes || jsonb_build_array(v_parte || jsonb_build_object('parte', v_modo));
      v_vals := v_vals || coalesce((v_parte ->> 'calculado')::numeric, (v_parte ->> 'total')::numeric, 0);
    end loop;
    v_teto := greatest(coalesce(c.valor, 0), 0);
    if coalesce(array_length(v_modos, 1), 0) = 0 then
      v_res := jsonb_build_object('modo', 'periodo', 'partes', '[]'::jsonb, 'valor_rota', coalesce(c.valor, 0), 'teto', v_teto,
                                  'calculado', greatest(v_acr, 0), 'limitado', false, 'total', least(greatest(v_acr, 0), v_teto),
                                  'obs', 'Pago no holerite (salário, diária ou hora).');
    elsif array_length(v_modos, 1) = 1 and v_acr = 0 and v_acrp = 0 then
      v_res := v_partes -> 0;
    else
      v_t := case v_comb when 'maior' then (select max(u) from unnest(v_vals) u)
                         when 'menor' then (select min(u) from unnest(v_vals) u)
                         when 'media' then (select round(avg(u), 2) from unnest(v_vals) u)
                         else (select sum(u) from unnest(v_vals) u) end;
      v_t := round(v_t * (1 + v_acrp / 100) + v_acr, 2);
      v_res := jsonb_build_object('modo', 'combinado', 'combinar', v_comb, 'partes', v_partes, 'acrescimo', v_acr, 'acrescimo_pct', v_acrp,
                                  'valor_rota', coalesce(c.valor, 0), 'teto', v_teto, 'calculado', v_t, 'limitado', v_t > v_teto, 'total', least(v_t, v_teto));
    end if;
    -- volta: da última parada até o ponto de partida (a primeira coleta), em km × valor
    if privado.pol_bool('pag_volta', false, c.empresa_id, v_m, c.tipo_pedido) then
      select * into v_ult from public.paradas where corrida_id = p_corrida order by ordem desc limit 1;
      select * into v_ini from public.paradas where corrida_id = p_corrida and tipo = 'coleta' order by ordem limit 1;
      if v_ult.id is not null and v_ini.id is not null and v_ult.id <> v_ini.id then
        v_vm := privado.dist_m(v_ult.lat, v_ult.lng, v_ini.lat, v_ini.lng) * privado.pol_num('fator_rua', 1.3, c.empresa_id, v_m, c.tipo_pedido);
        v_vkm := privado.pol_num('pag_volta_valor_km', privado.pol_num('pag_valor_km', 2, c.empresa_id, v_m, c.tipo_pedido), c.empresa_id, v_m, c.tipo_pedido);
        v_vv := round(round(v_vm / 1000.0, 2) * v_vkm * privado.pol_num('pag_volta_pct', 100, c.empresa_id, v_m, c.tipo_pedido) / 100, 2);
        v_t := coalesce((v_res ->> 'calculado')::numeric, (v_res ->> 'total')::numeric, 0) + v_vv;
        v_res := v_res || jsonb_build_object('volta', jsonb_build_object('km', round(v_vm / 1000.0, 2), 'valor_km', v_vkm,
                     'pct', privado.pol_num('pag_volta_pct', 100, c.empresa_id, v_m, c.tipo_pedido), 'valor', v_vv),
                   'calculado', v_t,
                   'limitado', privado.pol_bool('pag_volta_teto', true, c.empresa_id, v_m, c.tipo_pedido) and v_t > v_teto,
                   'total', case when privado.pol_bool('pag_volta_teto', true, c.empresa_id, v_m, c.tipo_pedido) then least(v_t, v_teto) else v_t end);
      end if;
    end if;
    -- regras extras de pagamento (espera, bônus por horário, por veículo…)
    v_parte := privado.regras_extras_linhas('pagamento', c.organizacao_id, jsonb_build_object(
      'quando', coalesce(c.concluida_em, c.agendada_para, now()), 'tipo', c.tipo_pedido, 'cliente', c.empresa_id, 'motoboy', v_m,
      'veiculo', (select veiculo_tipo from public.motoboys where id = v_m), 'urgente', c.urgente,
      'km', round(coalesce(c.distancia_planejada_m, 0) / 1000.0, 2),
      'coletas', (select count(*) from public.paradas where corrida_id = p_corrida and tipo = 'coleta'),
      'entregas', (select count(*) from public.paradas where corrida_id = p_corrida and tipo = 'entrega'),
      'minutos_parado', (select coalesce(round(sum(extract(epoch from (concluida_em - chegou_em)) / 60)), 0) from public.paradas
                          where corrida_id = p_corrida and chegou_em is not null and concluida_em > chegou_em),
      'valor_rota', coalesce(c.valor, 0)));
    if jsonb_array_length(v_parte) > 0 then
      v_t := coalesce((v_res ->> 'total')::numeric, 0);
      v_t := v_t + (select coalesce(sum((e ->> 'valor')::numeric), 0) from jsonb_array_elements(v_parte) e where not (e ->> 'limitar')::boolean);
      v_vv := coalesce((v_res ->> 'total')::numeric, 0) + (select coalesce(sum((e ->> 'valor')::numeric), 0) from jsonb_array_elements(v_parte) e where (e ->> 'limitar')::boolean);
      v_t := v_t + least(v_vv, greatest(coalesce(c.valor, 0), 0)) - coalesce((v_res ->> 'total')::numeric, 0);
      v_res := v_res || jsonb_build_object('extras', v_parte, 'total', round(greatest(v_t, 0), 2));
    end if;
    if v_rr <> '{}' then v_res := v_res || jsonb_build_object('regras_rota', v_rr); end if;
  exception when others then
    perform set_config('pwex.regras', coalesce(v_ant, ''), true);
    raise;
  end;
  perform set_config('pwex.regras', coalesce(v_ant, ''), true);
  return v_res;
end;
$$;
create or replace function privado.despachar(p_corrida uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  c            public.corridas%rowtype;
  v_coleta     extensions.geography;
  v_motoboy    uuid;
  v_dist       double precision;
  v_oferta     uuid;
  v_expira     timestamptz;
  v_idade      interval := make_interval(mins => privado.cfg_num('posicao_max_min', 15)::int);
  v_raio_max   numeric := privado.cfg_num('raio_max_despacho_km', 0) * 1000;
  v_favoritos  boolean := privado.cfg_bool('favoritos_primeiro', true);
  v_fc         numeric;
  v_emc        text;
  v_ext_raio   numeric;
  v_ext_max    int;
  v_nent       int;
  v_max        int;
  v_ext        boolean := false;
begin
  select * into c from public.corridas where id = p_corrida for update;
  if not found or c.status not in ('aguardando_motoboy', 'sem_motoboy') then return; end if;
  perform set_config('pwex.org', coalesce(c.organizacao_id::text, ''), true);
  if exists (select 1 from public.ofertas where corrida_id = p_corrida and status = 'pendente') then return; end if;
  -- quadro: ninguém recebe oferta, todos veem e o primeiro pega
  if c.modo_despacho::text = 'quadro' then return; end if;
  -- melhor primeiro: já teve a vez dele → vai para o quadro (agendada volta a ser "agendada" para reservar)
  if c.modo_despacho::text = 'melhor_primeiro' and exists (select 1 from public.ofertas where corrida_id = p_corrida) then
    update public.corridas set modo_despacho = 'quadro', quadro_desde = now(),
           status = case when c.agendada_para > now() then 'agendada' else 'aguardando_motoboy' end::public.status_corrida where id = p_corrida;
    perform privado.evento(p_corrida, 'foi_para_o_quadro');
    perform privado.avisar_quadro(p_corrida);
    return;
  end if;
  v_expira := now() + make_interval(secs => case when c.modo_despacho::text = 'melhor_primeiro'
                                                 then privado.pol_num('despacho_melhor_segundos', 45, c.empresa_id, null, c.tipo_pedido)
                                                 else privado.cfg_num('oferta_segundos', 30) end);

  select extensions.st_setsrid(extensions.st_makepoint(lng, lat), 4326)::extensions.geography
    into v_coleta from public.paradas where corrida_id = p_corrida order by ordem limit 1;
  -- motoboys em corrida também concorrem (extensão de rota), se a regra deixar e a rota for para agora
  v_emc := case when c.agendada_para > now() then 'nao' else privado.pol_txt('despacho_em_corrida', 'depois', c.empresa_id, null, c.tipo_pedido) end;
  v_ext_raio := privado.pol_num('extensao_raio_km', 3, c.empresa_id, null, c.tipo_pedido) * 1000;
  v_ext_max := privado.pol_num('extensao_max_entregas', 8, c.empresa_id, null, c.tipo_pedido)::int;
  select count(*) into v_nent from public.paradas where corrida_id = p_corrida and tipo = 'entrega';
  v_max := privado.pol_num('despacho_max_ofertas', 0, c.empresa_id, null, c.tipo_pedido)::int;

  if c.modo_despacho = 'direto' then
    if c.motoboy_designado_id is not null and not exists (
      select 1 from public.ofertas where corrida_id = p_corrida and motoboy_id = c.motoboy_designado_id and rodada = c.rodada
    ) and exists (select 1 from public.motoboys where id = c.motoboy_designado_id and modo_teste = c.teste) then
      v_motoboy := c.motoboy_designado_id;
      select extensions.st_distance(m.posicao, v_coleta) into v_dist from public.motoboys m where m.id = v_motoboy;
    end if;
  else
    select m.id, extensions.st_distance(m.posicao, v_coleta) into v_motoboy, v_dist
      from public.motoboys m
      left join public.empresa_favoritos f on v_favoritos and f.motoboy_id = m.id and f.empresa_id = c.empresa_id
     where privado.veiculo_serve(m.id, p_corrida) and (m.status = 'disponivel'
            or (v_emc in ('depois', 'junto') and m.status = 'em_corrida'
                and extensions.st_distance(m.posicao, v_coleta) <= v_ext_raio
                and exists (select 1 from public.corridas k where k.motoboy_id = m.id and k.status::text in ('aceita', 'em_andamento') and k.teste = c.teste
                             and (select count(*) from public.paradas kp where kp.corrida_id = k.id and kp.tipo = 'entrega' and kp.status::text <> 'concluida') + v_nent <= v_ext_max)))
       and (v_max <= 0 or (select count(*) from public.ofertas o where o.corrida_id = p_corrida and o.rodada = c.rodada) < v_max)
       and m.modo_teste = c.teste
       and not privado.motoboy_suspenso(m.id)
       and m.posicao is not null
       and m.posicao_em > now() - v_idade
       and (v_raio_max <= 0 or extensions.st_distance(m.posicao, v_coleta) <= v_raio_max)
       and (c.urgente or coalesce(m.raio_km, 0) <= 0 or extensions.st_distance(
              case when m.raio_modo = 'fixo' and m.raio_lat is not null and m.raio_lng is not null
                   then extensions.st_setsrid(extensions.st_makepoint(m.raio_lng, m.raio_lat), 4326)::extensions.geography
                   else m.posicao end,
              v_coleta) <= m.raio_km * 1000)
       and not exists (select 1 from public.ofertas o where o.corrida_id = p_corrida and o.motoboy_id = m.id
                        and (o.rodada = c.rodada or o.status = 'recusada'))
       and not exists (select 1 from public.ofertas o where o.motoboy_id = m.id and o.status = 'pendente')
       and public.motoboy_alcanca(c.organizacao_id, m.id, null)
     -- primeiro os da própria empresa; os de outras só se o Dev liberou (e, em "sem motoboy livre", só se faltar)
     order by ((select p.organizacao_id from public.perfis p where p.id = m.id) is distinct from c.organizacao_id), (f.ordem is null), f.ordem, (v_emc = 'depois' and m.status <> 'disponivel'), extensions.st_distance(m.posicao, v_coleta) - privado.bonus_regiao(m.id, p_corrida)
     limit 1;
  end if;

  if v_motoboy is null then
    -- ninguém para oferecer: vai para o quadro de rotas com aviso (ou para em "sem motoboy", se a regra pedir)
    if c.modo_despacho::text = 'melhor_primeiro' or (c.agendada_para > now() and c.modo_despacho::text <> 'direto')
       or (c.modo_despacho::text = 'cascata' and privado.pol_txt('despacho_sem_motoboy', 'quadro', c.empresa_id, null, c.tipo_pedido) = 'quadro') then
      update public.corridas set modo_despacho = 'quadro', quadro_desde = now(),
             status = case when c.agendada_para > now() then 'agendada' else 'aguardando_motoboy' end::public.status_corrida where id = p_corrida;
      perform privado.evento(p_corrida, 'foi_para_o_quadro');
      perform privado.avisar_quadro(p_corrida);
      return;
    end if;
    update public.corridas set status = 'sem_motoboy' where id = p_corrida;
    perform privado.evento(p_corrida, 'sem_motoboy');
    return;
  end if;

  v_fc := case when c.aplicar_acrescimo then privado.fator_distancia(v_dist, 'coleta') else 0 end;
  v_ext := (c.agendada_para is null or c.agendada_para <= now()) and exists (select 1 from public.corridas k where k.motoboy_id = v_motoboy and k.status::text in ('aceita', 'em_andamento'));
  insert into public.ofertas (corrida_id, motoboy_id, rodada, distancia_m, expira_em, fator_coleta, valor, extensao)
  values (p_corrida, v_motoboy, c.rodada, round(v_dist), v_expira, v_fc,
          privado.arredondar(coalesce(c.valor_base, c.valor, 0) * (1 + coalesce(c.fator_entrega, 0) + v_fc)), v_ext)
  returning id into v_oferta;

  update public.corridas set status = 'aguardando_motoboy' where id = p_corrida;
  perform privado.evento(p_corrida, 'oferta_enviada', jsonb_build_object('motoboy_id', v_motoboy, 'distancia_m', round(v_dist), 'extensao', v_ext));
  perform privado.enviar_push(v_motoboy, jsonb_build_object(
    'tipo', 'oferta', 'extensao', v_ext::text, 'oferta_id', v_oferta::text, 'corrida_id', p_corrida::text, 'teste', c.teste::text,
    'expira_em', to_char(v_expira at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  ));
end;
$$;
create or replace function public.pegar_rota(p_corrida uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c       public.corridas%rowtype;
  v_teste boolean := coalesce((select modo_teste from public.motoboys where id = auth.uid()), false);
begin
  if privado.motoboy_suspenso(auth.uid()) then raise exception 'motoboy_suspenso' using errcode = '42501'; end if;
  perform privado.checar_versao_app();
  if not public.tem_papel('motoboy'::public.papel_usuario) then raise exception 'apenas_motoboy' using errcode = '42501'; end if;
  select * into c from public.corridas where id = p_corrida for update;
  if not found or c.motoboy_id is not null then raise exception 'rota_ja_pegada' using errcode = '22023'; end if;
  if c.teste <> v_teste then raise exception 'modo_teste_diferente' using errcode = '22023'; end if;
  if privado.cfg_bool('veiculo_obrigatorio', false) and not c.teste
     and (select veiculo_placa from public.motoboys where id = auth.uid()) is null then
    raise exception 'cadastre_o_veiculo' using errcode = '42501';
  end if;
  if not privado.veiculo_serve(auth.uid(), p_corrida) then raise exception 'veiculo_nao_serve' using errcode = '22023'; end if;
  if c.status::text = 'agendada' then return public.reservar_corrida(p_corrida); end if;
  if not (c.status::text in ('aguardando_motoboy', 'sem_motoboy') and c.modo_despacho::text = 'quadro') then
    raise exception 'rota_ja_pegada' using errcode = '22023';
  end if;
  if not privado.pode_mais_rota(auth.uid()) then
    raise exception 'voce_ja_tem_corrida_ativa' using errcode = '22023';
  end if;
  update public.ofertas set status = 'cancelada' where corrida_id = p_corrida and status = 'pendente';
  update public.corridas set status = 'aceita', motoboy_id = auth.uid(), aceita_em = now() where id = p_corrida;
  update public.paradas set status = 'a_caminho'
   where corrida_id = p_corrida and ordem = (select min(ordem) from public.paradas where corrida_id = p_corrida);
  update public.motoboys set status = 'em_corrida', status_em = now() where id = auth.uid();
  perform privado.evento(p_corrida, 'aceita', jsonb_build_object('motoboy_id', auth.uid(), 'quadro', true, 'sugerida', c.sugerido_motoboy_id = auth.uid()));
  return privado.corrida_json(p_corrida);
end;
$$;
create or replace function public.criar_pedido(dados jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_gestor  boolean := public.is_gestor() and not coalesce((dados ->> 'como_cliente')::boolean, false);
  v_regras  jsonb := '{}';
  v_cat     public.categorias_produto%rowtype;
  v_cli     uuid;
  e         public.empresas%rowtype;
  v_quando  timestamptz := nullif(dados ->> 'quando', '')::timestamptz;
  v_tipo    text;
  v_tp      text := coalesce(nullif(dados ->> 'tipo_pedido', ''), 'padrao');
  v_teste   boolean := false;
  v_id      uuid;
  v_ids     uuid[] := '{}';
  v_pid     uuid;
  v_orc     jsonb;
  v_status  text;
  v_cobr    text;
  v_dev     numeric;
  p         jsonb;
  i         jsonb;
  k         int := 0;
begin
  if v_gestor then
    v_cli := nullif(dados ->> 'empresa_id', '')::uuid;
    v_teste := coalesce((dados ->> 'teste')::boolean, (select modo_teste from public.perfis where id = auth.uid()), false);
  else
    v_cli := privado.minha_empresa();
    if v_cli is null then raise exception 'apenas_gestor_ou_cliente' using errcode = '42501'; end if;
    v_teste := privado.cliente_teste();
    if exists (select 1 from public.empresas where id = v_cli and bloqueado_ate > now()) then
      raise exception 'cliente_bloqueado' using errcode = '42501', detail = (select bloqueado_motivo from public.empresas where id = v_cli);
    end if;
  end if;
  if v_gestor then v_regras := privado.limpar_regras(dados -> 'regras'); end if;
  if v_cli is not null and v_gestor and (select modo_teste from public.empresas where id = v_cli) then v_teste := true; end if;
  if v_cli is not null then select * into e from public.empresas where id = v_cli; end if;
  if v_gestor and v_cli is not null and (e.id is null or not public.ve_org(e.organizacao_id)) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if not exists (select 1 from public.tipos_pedido where chave = v_tp and (ativo or v_gestor)
                 and (organizacao_id is null or organizacao_id = privado.org_contexto(v_cli))) then raise exception 'tipo_pedido_invalido' using errcode = '22023'; end if;

  v_tipo := case when v_quando is null then 'express' else 'planejado' end;
  if not v_gestor then
    if v_tipo = 'express' and not (coalesce(e.pode_express, false) and privado.pol_bool('cliente_pode_express', true, v_cli, null, v_tp)) then
      raise exception 'cliente_so_agendado' using errcode = '42501';
    end if;
    if v_tipo = 'planejado' and not privado.pol_bool('cliente_pode_agendar', true, v_cli, null, v_tp) then
      raise exception 'cliente_sem_agendado' using errcode = '42501';
    end if;
    if v_tipo = 'planejado' and privado.pol_num('cliente_agendar_max_dias', 60, v_cli, null, v_tp) > 0
       and v_quando > now() + make_interval(days => privado.pol_num('cliente_agendar_max_dias', 60, v_cli, null, v_tp)::int) then
      raise exception 'agendamento_longe_demais' using errcode = '22023';
    end if;
    if coalesce((dados ->> 'urgente')::boolean, false) and not privado.pol_bool('cliente_pode_urgente', true, v_cli, null, v_tp) then
      raise exception 'cliente_sem_urgente' using errcode = '42501';
    end if;
    if privado.pol_num('cliente_max_entregas', 0, v_cli, null, v_tp) > 0
       and (select count(*) from jsonb_array_elements(coalesce(dados -> 'pontos', '[]')) x where x ->> 'tipo' = 'entrega') > privado.pol_num('cliente_max_entregas', 0, v_cli, null, v_tp) then
      raise exception 'entregas_demais' using errcode = '22023';
    end if;
    if privado.pol_num('cliente_max_coletas', 0, v_cli, null, v_tp) > 0
       and (select count(*) from jsonb_array_elements(coalesce(dados -> 'pontos', '[]')) x where x ->> 'tipo' = 'coleta') > privado.pol_num('cliente_max_coletas', 0, v_cli, null, v_tp) then
      raise exception 'coletas_demais' using errcode = '22023';
    end if;
    if privado.pol_num('cliente_max_pedidos_abertos', 0, v_cli, null, v_tp) > 0
       and (select count(*) from public.pedidos x where x.empresa_id = v_cli and x.teste = v_teste and x.status in ('recebido', 'aprovado', 'roteirizado', 'em_rota'))
           >= privado.pol_num('cliente_max_pedidos_abertos', 0, v_cli, null, v_tp) then
      raise exception 'pedidos_abertos_demais' using errcode = '22023';
    end if;
    -- horário em que o cliente pode pedir para agora (vazio = qualquer hora)
    if v_tipo = 'express' and privado.pol_txt('cliente_pedido_de', '', v_cli, null, v_tp) ~ '^[0-2][0-9]:[0-5][0-9]$'
       and privado.pol_txt('cliente_pedido_ate', '', v_cli, null, v_tp) ~ '^[0-2][0-9]:[0-5][0-9]$'
       and not ((now() at time zone 'America/Sao_Paulo')::time between privado.pol_txt('cliente_pedido_de', '', v_cli, null, v_tp)::time
                                                                 and privado.pol_txt('cliente_pedido_ate', '', v_cli, null, v_tp)::time) then
      raise exception 'fora_do_horario' using errcode = '22023';
    end if;
    if v_tipo = 'planejado' and v_quando < now() + make_interval(mins => privado.pol_num('agendada_antecedencia_cliente_min', 60, v_cli, null, v_tp)::int) then
      raise exception 'horario_muito_proximo' using errcode = '22023';
    end if;
  elsif v_tipo = 'planejado' and v_quando < now() then
    raise exception 'horario_passou' using errcode = '22023';
  end if;

  if (select count(*) from jsonb_array_elements(coalesce(dados -> 'pontos', '[]')) x where x ->> 'tipo' = 'coleta') < 1
     or (select count(*) from jsonb_array_elements(coalesce(dados -> 'pontos', '[]')) x where x ->> 'tipo' = 'entrega') < 1 then
    raise exception 'pedido_precisa_coleta_e_entrega' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(dados -> 'pontos') x where nullif(x ->> 'lat', '') is null or nullif(x ->> 'lng', '') is null) then
    raise exception 'ponto_sem_localizacao' using errcode = '22023';
  end if;
  if jsonb_array_length(dados -> 'pontos') > 60 then raise exception 'pontos_demais' using errcode = '22023'; end if;
  if exists (select 1 from jsonb_array_elements(dados -> 'pontos') x
              where nullif(x ->> 'janela_de', '') is not null and nullif(x ->> 'janela_ate', '') is not null
                and (x ->> 'janela_de')::time >= (x ->> 'janela_ate')::time) then
    raise exception 'janela_invalida' using errcode = '22023';
  end if;
  -- campos do item que a categoria exige
  for i in select * from jsonb_array_elements(coalesce(dados -> 'itens', '[]')) loop
    if nullif(i ->> 'categoria_id', '') is null then
      if not v_gestor and privado.cfg_bool('item_categoria_obrigatoria', false) then raise exception 'item_sem_categoria' using errcode = '22023'; end if;
      continue;
    end if;
    select * into v_cat from public.categorias_produto where id = (i ->> 'categoria_id')::uuid
       and (organizacao_id is null or organizacao_id = privado.org_contexto(v_cli));
    if not found then raise exception 'categoria_invalida' using errcode = '22023'; end if;
    if v_gestor then continue; end if;
    if v_cat.campo_peso = 'obrigatorio' and coalesce(nullif(i ->> 'peso_kg', '')::numeric, 0) <= 0 then raise exception 'item_sem_peso' using errcode = '22023'; end if;
    if v_cat.campo_valor = 'obrigatorio' and coalesce(nullif(i ->> 'valor_declarado', '')::numeric, 0) <= 0 then raise exception 'item_sem_valor' using errcode = '22023'; end if;
    if v_cat.campo_descricao = 'obrigatorio' and coalesce(trim(i ->> 'descricao'), '') = '' then raise exception 'item_sem_descricao' using errcode = '22023'; end if;
    if v_cat.campo_medidas = 'obrigatorio' and (coalesce(nullif(i ->> 'comprimento_cm', '')::numeric, 0) <= 0
         or coalesce(nullif(i ->> 'largura_cm', '')::numeric, 0) <= 0 or coalesce(nullif(i ->> 'altura_cm', '')::numeric, 0) <= 0) then
      raise exception 'item_sem_medidas' using errcode = '22023';
    end if;
  end loop;
  perform privado.usar_regras(v_regras);

  v_orc := privado.orcar(jsonb_build_object('empresa_id', v_cli, 'tipo', v_tipo, 'tipo_pedido', v_tp, 'quando', v_quando,
                                            'urgente', coalesce((dados ->> 'urgente')::boolean, false), 'distancia_m', dados -> 'distancia_m',
                                            'pontos', dados -> 'pontos', 'itens', coalesce(dados -> 'itens', '[]'), 'regras', v_regras));
  v_cobr := privado.pol_txt('cobranca_modo', 'credito', v_cli, null, v_tp);
  if v_cli is null then v_cobr := 'pre_pago'; end if;
  v_status := case when v_gestor then 'aprovado'
                   when privado.pol_bool('pedido_revisao_gestor', true, v_cli, null, v_tp) then 'recebido'
                   else 'aprovado' end;
  v_dev := coalesce(e.dev_pct, privado.pol_num('dev_pct', 5, v_cli, null, v_tp));

  insert into public.pedidos (teste, empresa_id, cliente_nome, criado_por, origem, tipo, tipo_pedido, quando, urgente, status, observacoes,
                              distancia_estimada_m, orcamento, valor_calculado, valor, dev_pct, valor_dev, cobranca, pagamento_status,
                              pagamento_metodo, aprovado_em, revisado_por, revisado_em, regras)
  values (v_teste, v_cli, case when v_cli is null then nullif(trim(dados ->> 'cliente_nome'), '') end, auth.uid(),
          case when v_gestor then 'gestor' else 'cliente' end, v_tipo, v_tp, v_quando, coalesce((dados ->> 'urgente')::boolean, false),
          v_status, nullif(left(dados ->> 'observacoes', 1000), ''), (v_orc ->> 'distancia_m')::int, v_orc,
          (v_orc ->> 'total')::numeric, (v_orc ->> 'total')::numeric, v_dev, round((v_orc ->> 'total')::numeric * v_dev / 100, 2),
          v_cobr, case when v_cobr = 'pre_pago' then 'pendente' else 'nao_exigido' end, nullif(dados ->> 'metodo', ''),
          case when v_status = 'aprovado' then now() end,
          case when v_gestor then auth.uid() end, case when v_gestor then now() end, v_regras)
  returning id into v_id;
  -- campos próprios do pedido e veículo pedido
  update public.pedidos set
    extras = privado.limpar_extras(privado.org_contexto(v_cli, null), 'pedido', v_tp, dados -> 'extras', case when v_gestor then 'gestor' else 'cliente' end),
    veiculo = case when nullif(dados ->> 'veiculo', '') in ('moto', 'carro', 'bicicleta', 'van', 'outro')
                    and (v_gestor or privado.pol_bool('cliente_escolhe_veiculo', false, v_cli, null, v_tp)) then dados ->> 'veiculo' end
   where id = v_id;

  for p in select * from jsonb_array_elements(dados -> 'pontos') loop
    -- confirmações e janela de cada ponto: o cliente só pede o que o gestor liberou para ele
    insert into public.pedido_pontos (pedido_id, ordem, tipo, endereco, lat, lng, contato_nome, contato_telefone, instrucoes, referencias,
                                      exige_foto, exige_assinatura, exige_nome, exige_codigo, janela_de, janela_ate, dist_coleta_m)
    values (v_id, k, (p ->> 'tipo')::public.tipo_parada, left(coalesce(p ->> 'endereco', ''), 300), (p ->> 'lat')::double precision, (p ->> 'lng')::double precision,
            nullif(left(p ->> 'contato_nome', 120), ''), nullif(left(p ->> 'contato_telefone', 40), ''), nullif(left(p ->> 'instrucoes', 500), ''),
            privado.limpar_referencias(p -> 'referencias'),
            case when v_gestor or privado.pol_bool('cliente_confirma_foto', true, v_cli, null, v_tp) then (p ->> 'exige_foto')::boolean end,
            case when v_gestor or privado.pol_bool('cliente_confirma_assinatura', true, v_cli, null, v_tp) then (p ->> 'exige_assinatura')::boolean end,
            case when v_gestor or privado.pol_bool('cliente_confirma_nome', true, v_cli, null, v_tp) then (p ->> 'exige_nome')::boolean end,
            case when v_gestor or privado.pol_bool('cliente_confirma_codigo', true, v_cli, null, v_tp) then (p ->> 'exige_codigo')::boolean end,
            case when v_gestor or privado.pol_bool('cliente_pode_janela', true, v_cli, null, v_tp) then nullif(p ->> 'janela_de', '')::time end,
            case when v_gestor or privado.pol_bool('cliente_pode_janela', true, v_cli, null, v_tp) then nullif(p ->> 'janela_ate', '')::time end,
            case when nullif(p ->> 'dist_coleta_m', '')::numeric between 1 and 2000000 then round((p ->> 'dist_coleta_m')::numeric)::int end)
    returning id into v_pid;
    if p ? 'extras' then
      update public.pedido_pontos set extras = privado.limpar_extras(privado.org_contexto(v_cli, null), 'ponto', v_tp, p -> 'extras',
        case when v_gestor then 'gestor' else 'cliente' end, false) where id = v_pid;
    end if;
    v_ids := v_ids || v_pid;
    k := k + 1;
  end loop;

  for i in select * from jsonb_array_elements(coalesce(dados -> 'itens', '[]')) loop
    insert into public.pedido_itens (pedido_id, coleta_id, entrega_id, descricao, categoria_id, quantidade, peso_kg, comprimento_cm, largura_cm, altura_cm, valor_declarado, observacoes)
    values (v_id,
            case when nullif(i ->> 'coleta', '') is not null then v_ids[(i ->> 'coleta')::int + 1] end,
            case when nullif(i ->> 'entrega', '') is not null then v_ids[(i ->> 'entrega')::int + 1] end,
            left(coalesce(nullif(trim(i ->> 'descricao'), ''), (select nome from public.categorias_produto where id = nullif(i ->> 'categoria_id', '')::uuid), 'Item'), 200), nullif(i ->> 'categoria_id', '')::uuid,
            greatest(1, coalesce((i ->> 'quantidade')::int, 1)), nullif(i ->> 'peso_kg', '')::numeric,
            nullif(i ->> 'comprimento_cm', '')::numeric, nullif(i ->> 'largura_cm', '')::numeric, nullif(i ->> 'altura_cm', '')::numeric,
            nullif(i ->> 'valor_declarado', '')::numeric, nullif(left(i ->> 'observacoes', 300), ''));
  end loop;

  -- "dados" também é coluna de pedido_modelos: usa o parâmetro pelo nome da função
  for i in select * from jsonb_array_elements(coalesce(criar_pedido.dados -> 'objetos_usados', '[]')) loop
    update public.cliente_objetos o set usos = o.usos + 1 where o.id = (i #>> '{}')::uuid and (v_gestor or o.empresa_id = v_cli);
  end loop;
  if nullif(criar_pedido.dados ->> 'modelo_id', '') is not null then
    update public.pedido_modelos m set usos = m.usos + 1, usado_em = now() where m.id = (criar_pedido.dados ->> 'modelo_id')::uuid;
  end if;
  perform privado.usar_regras('{}');
  perform privado.evento_pedido(v_id, 'criado', jsonb_build_object('origem', case when v_gestor then 'gestor' else 'cliente' end, 'total', v_orc -> 'total'));
  if v_status = 'aprovado' then perform privado.roteirizar(v_teste); end if;
  return v_id;
end;
$$;
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
  v_ex       jsonb;
begin
  -- outra empresa: recusa
  if p_parada is not null and not public.ve_corrida((select tv_par.corrida_id from public.paradas tv_par where tv_par.id = p_parada)) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  perform privado.checar_versao_app();
  select * into p from public.paradas where id = p_parada for update;
  if not found then raise exception 'parada_nao_encontrada' using errcode = '22023'; end if;
  select * into c from public.corridas where id = p.corrida_id for update;
  -- respostas dos campos próprios ("resp_<campo>" e/ou "respostas": {...}); fotos chegam como caminho do arquivo
  if v_dados ? 'respostas' or exists (select 1 from jsonb_object_keys(v_dados) k where k like 'resp\_%') then
    update public.paradas set respostas = coalesce(respostas, '{}') || privado.limpar_extras(c.organizacao_id, 'ponto', c.tipo_pedido,
      coalesce(v_dados -> 'respostas', '{}') || coalesce((select jsonb_object_agg(substr(k, 6), v) from jsonb_each(v_dados) e(k, v) where k like 'resp\_%'), '{}'),
      'motoboy', false)
     where id = p_parada;
  end if;
  -- etapa feita sem internet chegando depois que a corrida fechou sozinha: só completa os dados
  if p.confirmacao_pendente and c.motoboy_id = auth.uid() and p_acao = 'concluir' then
    update public.paradas set confirmacao_pendente = false, feita_offline = true,
           concluida_em = coalesce(privado.quando_offline(v_dados), concluida_em),
           recebedor_nome = coalesce(nullif(trim(v_dados ->> 'recebedor_nome'), ''), recebedor_nome),
           foto_path = coalesce(nullif(v_dados ->> 'foto_path', ''), foto_path),
           assinatura_path = coalesce(nullif(v_dados ->> 'assinatura_path', ''), assinatura_path)
     where id = p.id;
    if not exists (select 1 from public.paradas where corrida_id = c.id and confirmacao_pendente) then
      update public.corridas set aguardando_confirmacao = false where id = c.id;
      perform privado.evento(c.id, 'confirmada_offline');
    end if;
    return privado.corrida_json(c.id);
  end if;
  if p.confirmacao_pendente and c.motoboy_id = auth.uid() then return privado.corrida_json(c.id); end if;
  if c.motoboy_id is distinct from auth.uid() or c.status not in ('aceita', 'em_andamento') then
    raise exception 'corrida_nao_esta_ativa' using errcode = '22023';
  end if;
  if p_acao not in ('chegou', 'concluir') then raise exception 'acao_invalida' using errcode = '22023'; end if;

  select min(ordem) into v_atual from public.paradas where corrida_id = c.id and status <> 'concluida';
  if p.ordem <> v_atual then raise exception 'conclua_a_parada_anterior' using errcode = '22023'; end if;

  -- presença no local
  select d.distancia_m, d.tolerancia_m into v_dist, v_tol from privado.distancia_ate_parada(p, v_dados, auth.uid()) d;
  if c.exigir_no_local then
    v_ignorar := (coalesce((v_dados ->> 'ignorar_local')::boolean, false)
                  and c.teste and public.is_gestor()
                  and privado.cfg_bool('teste_admin_ignora_local', true))
                 -- o gestor liberou esta parada (pular o raio)
                 or p.liberada_local
                 -- o gestor deu ao motoboy a liberdade de pular
                 or (coalesce((v_dados ->> 'ignorar_local')::boolean, false) and privado.cfg_bool('saas_pular_parada', true)
                     and privado.pol_bool('motoboy_pode_pular', false, c.empresa_id, auth.uid(), c.tipo_pedido));
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
       set status = 'chegou', chegou_em = coalesce(privado.quando_offline(v_dados), now()), feita_offline = feita_offline or coalesce(v_dados ->> 'offline' = 'true', false),
           distancia_chegada_m = round(v_dist), local_ignorado = v_ignorar
     where id = p.id;
    perform privado.evento(c.id, 'chegou', jsonb_build_object(
      'parada', p.ordem, 'tipo', p.tipo, 'distancia_m', round(v_dist), 'local_ignorado', v_ignorar));
    return privado.corrida_json(c.id);
  end if;

  -- concluir: o que esta parada exige (o que o cliente pediu no ponto, ou o padrão da rota nas entregas)
  v_ex := privado.exige_parada(p, c);
  if (v_ex ->> 'nome')::boolean and coalesce(trim(v_dados ->> 'recebedor_nome'), '') = '' then
    raise exception 'informe_o_nome_de_quem_recebeu' using errcode = '22023';
  end if;
  if (v_ex ->> 'codigo')::boolean and coalesce(v_dados ->> 'codigo', '') <> coalesce(p.codigo, c.codigo_entrega, '') then
    raise exception 'codigo_incorreto' using errcode = '22023';
  end if;
  if (v_ex ->> 'foto')::boolean and coalesce(v_dados ->> 'foto_path', '') = '' then
    raise exception 'falta_a_foto' using errcode = '22023';
  end if;
  if (v_ex ->> 'assinatura')::boolean and coalesce(v_dados ->> 'assinatura_path', '') = '' then
    raise exception 'falta_a_assinatura' using errcode = '22023';
  end if;

  update public.paradas
     set status = 'concluida',
         chegou_em = coalesce(chegou_em, privado.quando_offline(v_dados), now()),
         concluida_em = coalesce(privado.quando_offline(v_dados), now()),
         feita_offline = feita_offline or coalesce(v_dados ->> 'offline' = 'true', false),
         distancia_chegada_m = coalesce(distancia_chegada_m, round(v_dist)),
         local_ignorado = local_ignorado or v_ignorar,
         recebedor_nome = nullif(trim(v_dados ->> 'recebedor_nome'), ''),
         foto_path = nullif(v_dados ->> 'foto_path', ''),
         assinatura_path = nullif(v_dados ->> 'assinatura_path', '')
   where id = p.id;
  -- pedido de pular esta parada que ficou aberto: não precisa mais
  update public.chamados_corrida set status = 'retirado', respondido_em = now() where corrida_id = c.id and tipo = 'pular' and parada_id = p.id and status = 'pendente';
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
create or replace function public.meu_perfil()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', p.id,
    'nome', p.nome,
    'foto_url', p.foto_url,
    'papeis', to_jsonb(p.papeis),
    'gestor', 'gestor' = any (p.papeis) or 'dev' = any (p.papeis) or 'supervisor' = any (p.papeis),
    'motoboy', 'motoboy' = any (p.papeis),
    'dev', 'dev' = any (p.papeis),
    'cor_tema', p.cor_tema, 'tema', p.tema,
    'modo_teste', coalesce(m.modo_teste, p.modo_teste),
    'suspenso_ate', case when m.suspenso_ate > now() then m.suspenso_ate end, 'suspenso_motivo', case when m.suspenso_ate > now() then m.suspenso_motivo end,
    'raio', jsonb_build_object('km', m.raio_km, 'modo', coalesce(m.raio_modo, 'posicao'), 'lat', m.raio_lat, 'lng', m.raio_lng),
    'modulos', coalesce((select jsonb_object_agg(md.chave, privado.modulo_ligado(md.chave, p.id)) from public.modulos md), '{}'::jsonb),
    'rotulos', privado.rotulos_de(coalesce(p.organizacao_id, privado.org_contexto(p.empresa_id, null))),
    'campos', (select coalesce(jsonb_agg(jsonb_build_object('chave', k.chave, 'rotulo', k.rotulo, 'dica', k.dica, 'tipo', k.tipo, 'opcoes', k.opcoes,
                 'obrigatorio', k.obrigatorio, 'quem_preenche', k.quem_preenche, 'entidade', k.entidade, 'ponto_tipo', k.ponto_tipo,
                 'tipos_pedido', k.tipos_pedido, 'visivel_motoboy', k.visivel_motoboy, 'visivel_cliente', k.visivel_cliente) order by k.entidade, k.ordem), '[]')
                 from public.campos_personalizados k where k.ativo and (k.organizacao_id is null or k.organizacao_id = coalesce(p.organizacao_id, privado.org_contexto(p.empresa_id, null)))),
    'cargo', (select jsonb_build_object('id', k.id, 'nome', k.nome, 'icone', k.icone) from public.cargos k where k.id = p.cargo_id),
    'holerite_visivel', privado.pol_bool('motoboy_ve_holerite', true, null, p.id, null),
    'supervisor', 'supervisor' = any (p.papeis),
    'permissoes', p.permissoes,
    'dev_oculto', p.dev_oculto,
    'organizacao', (select jsonb_build_object('id', o.id, 'nome', o.nome, 'nome_app', o.nome_app, 'nome_topo', o.nome_topo, 'nomes', o.nomes, 'logo', o.logo_url, 'logo_escala', o.logo_escala, 'logo_original', o.logo_original_url, 'brilho_cor', o.logo_brilho_cor, 'brilho', o.logo_brilho, 'fonte', o.fonte_nome, 'cor', o.cor, 'status', o.status, 'suspensa_motivo', case when o.status in ('suspensa', 'cancelada') then o.suspensa_motivo end)
                      from public.organizacoes o where o.id = case when 'dev' = any (p.papeis) and p.dev_vazio then null else coalesce(case when 'dev' = any (p.papeis) then p.org_em_foco end, p.organizacao_id) end),
    'configuracoes', coalesce((
      select jsonb_object_agg(k, v) from jsonb_each(public.ajustes()) e(k, v)
       where k in ('intervalo_corrida_s', 'intervalo_economia_s', 'disponivel_envio_min',
                       'disponivel_distancia_m', 'raio_chegada_m', 'teste_admin_ignora_local', 'oferta_segundos',
                       'quadro_mostra_enderecos', 'quadro_mostra_itens', 'simulador_ligado', 'simulador_velocidade_kmh',
                       'motoboy_edita_veiculo', 'mapa_offline_some_h', 'mapa_offline_esmaecer', 'veiculo_obrigatorio',
                       'rota_provedor', 'rota_perfil', 'chat_ligado', 'chat_geral', 'chat_fotos', 'ping_envio_s',
                       'chat_compartilhar', 'chat_compartilhar_tipos', 'chat_grupos_equipe', 'pagamento_na_plataforma', 'compartilhar_motoboy_resumo',
                       'usuario_troca_senha', 'perfil_publico_ligado', 'chat_motoboy_abre_rota', 'chat_rota_respostas',
                       'lembrar_pagina', 'passar_corrida_ligado', 'pedido_confirmar_revisao', 'chamado_motoboy_pode',
                       'dev_site_url', 'offline_finalizar_ligado', 'emergencia_ligada', 'motoboy_pede_pular', 'dev_jogo_vel_max_kmh', 'dev_jogo_ranking',
                       'chat_editar_min', 'chat_audio_ligado', 'dev_chat_audio_ligado', 'dev_chat_audio_max_s', 'chat_reacoes')
    ), '{}'::jsonb)
    -- o que pode mudar por motoboy (regra dele > geral)
    || jsonb_build_object(
      'intervalo_corrida_s', privado.pol_num('intervalo_corrida_s', 6, null, p.id, null),
      'intervalo_economia_s', privado.pol_num('intervalo_economia_s', 20, null, p.id, null),
      'disponivel_envio_min', privado.pol_num('disponivel_envio_min', 3, null, p.id, null),
      'disponivel_distancia_m', privado.pol_num('disponivel_distancia_m', 300, null, p.id, null),
      'disponivel_fator', privado.pol_num('disponivel_fator', 3, null, p.id, null),
      'motoboy_rotas_simultaneas', privado.pol_num('motoboy_rotas_simultaneas', 1, null, p.id, null),
      'motoboy_rotas_distancia_aviso_km', privado.pol_num('motoboy_rotas_distancia_aviso_km', 5, null, p.id, null),
      'ping_distancia_m', privado.pol_num('ping_distancia_m', 20, null, p.id, null),
      'ping_precisao_max_m', privado.pol_num('ping_precisao_max_m', 60, null, p.id, null),
      'navegacao_ligada', privado.pol_bool('navegacao_ligada', true, null, p.id, null),
      'navegacao_voz', privado.pol_bool('navegacao_voz', true, null, p.id, null),
      'navegacao_recalcular_m', privado.pol_num('navegacao_recalcular_m', 60, null, p.id, null),
      'navegacao_na_notificacao', privado.pol_bool('navegacao_na_notificacao', true, null, p.id, null),
      'motoboy_edita_veiculo', privado.pol_bool('motoboy_edita_veiculo', false, null, p.id, null),
      'ping_inteligente', privado.pol_bool('ping_inteligente', true, null, p.id, null),
      'ping_curva_graus', privado.pol_num('ping_curva_graus', 25, null, p.id, null),
      'ping_reta_max_m', privado.pol_num('ping_reta_max_m', 200, null, p.id, null),
      'jogo_ligado', privado.pol_bool('jogo_ligado', true, null, p.id, null),
      'jogo_toques', privado.pol_num('jogo_toques', 5, null, p.id, null),
      'motoboy_pode_pular', privado.cfg_bool('saas_pular_parada', true) and privado.pol_bool('motoboy_pode_pular', false, null, p.id, null),
      'motoboy_pode_cancelar', privado.pol_bool('motoboy_pode_cancelar', false, null, p.id, null),
      'motoboy_pode_finalizar', privado.pol_bool('motoboy_pode_finalizar', false, null, p.id, null))
  )
  from public.perfis p
  left join public.motoboys m on m.id = p.id
  where p.id = auth.uid();
$$;
create or replace function public.avisos_externos_pegar(p_limite int default 20)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r jsonb;
begin
  if not privado.eh_servico() then raise exception 'apenas_servidor' using errcode = '42501'; end if;
  with x as (
    select id from privado.avisos_externos
     where (status = 'pendente' or (status = 'erro' and tentativas < 5 and criado_em > now() - interval '2 days')
            or (status = 'enviando' and criado_em < now() - interval '10 minutes'))
     order by criado_em limit greatest(least(p_limite, 100), 1) for update skip locked)
  update privado.avisos_externos a set status = 'enviando', tentativas = a.tentativas + 1 from x where a.id = x.id;
  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'canal', a.canal, 'para', a.para, 'assunto', a.assunto, 'corpo', a.corpo,
           'empresa', (select coalesce(o.nome_app, o.nome) from public.organizacoes o where o.id = a.organizacao_id),
           'nf_provedor', privado.cfg_txt('dev_nf_provedor', 'nenhum'), 'nf_cnpj', privado.cfg_org_txt(a.organizacao_id, 'nf_cnpj_prestador', ''),
           'nf_servico', privado.cfg_org_txt(a.organizacao_id, 'nf_codigo_servico', ''),
           'textos', jsonb_build_object('cadastro', privado.cfg_org_txt(a.organizacao_id, 'aviso_texto_cadastro', ''),
                                        'fatura', privado.cfg_org_txt(a.organizacao_id, 'aviso_texto_fatura', ''),
                                        'entregue', privado.cfg_org_txt(a.organizacao_id, 'aviso_texto_entregue', ''),
                                        'devolucao', privado.cfg_org_txt(a.organizacao_id, 'aviso_texto_devolucao', ''))) order by a.id), '[]') into r
    from privado.avisos_externos a where a.status = 'enviando' and a.enviado_em is null and a.tentativas > 0
     and a.id in (select id from privado.avisos_externos where status = 'enviando' order by id limit 100);
  return r;
end;
$$;
create or replace function privado.api_agir_como(p_hash text)
returns public.api_chaves language plpgsql security definer set search_path = '' as $$
declare k public.api_chaves%rowtype; v_usuario uuid;
begin
  select * into k from public.api_chaves where hash = p_hash and revogada_em is null;
  if k.id is null then raise exception 'chave_invalida' using errcode = '28000'; end if;
  if not privado.cfg_org_bool(k.organizacao_id, 'api_lojas_liberada', true) then raise exception 'api_desligada' using errcode = '42501'; end if;
  select p.id into v_usuario from public.perfis p
   where p.empresa_id = k.empresa_id and 'cliente' = any (p.papeis)
   order by p.criado_em limit 1;
  if v_usuario is null then raise exception 'empresa_sem_acesso' using errcode = '42501'; end if;
  perform set_config('request.jwt.claim.sub', v_usuario::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_usuario, 'role', 'authenticated')::text, true);
  perform set_config('request.uid', v_usuario::text, true);   -- banco de teste local
  -- limite de chamadas por minuto (Ajustes → Plataforma; 0 = sem limite)
  if privado.cfg_org_txt(k.organizacao_id, 'api_limite_minuto', '120') ~ '^[0-9]+$' and privado.cfg_org_txt(k.organizacao_id, 'api_limite_minuto', '120')::int > 0
     and k.janela_minuto = date_trunc('minute', now()) and k.janela_usos >= privado.cfg_org_txt(k.organizacao_id, 'api_limite_minuto', '120')::int then
    raise exception 'limite_excedido' using errcode = '53400';
  end if;
  update public.api_chaves set ultimo_uso = now(), usos = usos + 1,
         janela_usos = case when janela_minuto = date_trunc('minute', now()) then janela_usos + 1 else 1 end,
         janela_minuto = date_trunc('minute', now())
   where id = k.id;
  return k;
end;
$$;
create or replace function privado.api_pedido_json(p_pedido uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', p.id, 'numero', p.numero, 'status', p.status, 'referencia_externa', p.referencia_externa,
    'criado_em', p.criado_em, 'quando', p.quando, 'urgente', p.urgente, 'valor', p.valor, 'pagamento', p.pagamento_status, 'teste', p.teste, 'veiculo', p.veiculo, 'extras', p.extras,
    'pontos', (select coalesce(jsonb_agg(jsonb_build_object('ordem', pp.ordem, 'tipo', pp.tipo, 'endereco', pp.endereco, 'lat', pp.lat, 'lng', pp.lng,
                 'contato_nome', pp.contato_nome, 'extras', pp.extras,
                 'respostas', (select coalesce(jsonb_object_agg(pa.id, pa.respostas) filter (where pa.respostas <> '{}'), '{}') from public.paradas pa where pa.pedido_ponto_id = pp.id)) order by pp.ordem), '[]') from public.pedido_pontos pp where pp.pedido_id = p.id))
  from public.pedidos p where p.id = p_pedido;
$$;
create or replace function public.pings_percurso(
  p_de timestamptz default null, p_ate timestamptz default null,
  p_motoboy uuid default null, p_teste boolean default null, p_corrida uuid default null
)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid    uuid := auth.uid();
  v_gestor boolean := public.is_gestor();
  v_pings  jsonb;
  v_legado jsonb;
begin
  if v_uid is null then raise exception 'nao_autenticado' using errcode = '28000'; end if;
  if not v_gestor then
    if p_corrida is not null then
      if not exists (select 1 from public.corridas where id = p_corrida and motoboy_id = v_uid) then
        raise exception 'sem_permissao' using errcode = '42501';
      end if;
      p_motoboy := v_uid;
    elsif p_motoboy is distinct from v_uid then
      raise exception 'sem_permissao' using errcode = '42501';
    end if;
  end if;
  if p_corrida is null then
    if p_de is null or p_ate is null then raise exception 'periodo_obrigatorio' using errcode = '22023'; end if;
    if p_ate - p_de > interval '3 days' then raise exception 'periodo_grande' using errcode = '22023'; end if;
  end if;

  select coalesce(jsonb_agg(jsonb_build_array(l.motoboy_id, round(l.lat::numeric, 6), round(l.lng::numeric, 6), l.status, coalesce(p_corrida, l.corrida_id),
                  (extract(epoch from l.registrado_em) * 1000)::bigint, round(coalesce(l.precisao_m, 0)::numeric))
                  order by l.motoboy_id, l.registrado_em), '[]'::jsonb)
    into v_pings
    from public.localizacoes l
   where (case when p_corrida is not null then (l.corrida_id = p_corrida
                 -- com várias rotas abertas, o ping fica numa só: vale o que o motoboy da rota fez enquanto ela estava aberta
                 or (l.status = 'em_corrida' and exists (select 1 from public.corridas k where k.id = p_corrida and k.motoboy_id = l.motoboy_id
                       and l.registrado_em >= coalesce(k.aceita_em, k.iniciada_em) and l.registrado_em <= coalesce(k.concluida_em, k.cancelada_em, now()))))
               else l.registrado_em >= p_de and l.registrado_em < p_ate end)
     and (p_motoboy is null or l.motoboy_id = p_motoboy)
     and (p_teste is null or l.teste = p_teste)
     and (not v_gestor or public.ve_pessoa(l.motoboy_id))
     and l.lat between -90 and 90 and l.lng between -180 and 180 and not (l.lat = 0 and l.lng = 0);

  -- corridas que foram compactadas antes desta versão (os pings já tinham sido apagados)
  select coalesce(jsonb_agg(jsonb_build_object(
           'motoboy', c.motoboy_id, 'corrida', c.id, 'trajeto', c.trajeto,
           'ini', (extract(epoch from coalesce(c.iniciada_em, c.aceita_em, c.criada_em)) * 1000)::bigint,
           'fim', (extract(epoch from coalesce(c.concluida_em, c.cancelada_em, c.compactada_em)) * 1000)::bigint)), '[]'::jsonb)
    into v_legado
    from public.corridas c
   where c.trajeto is not null and c.compactada_em is not null and c.motoboy_id is not null
     and (case when p_corrida is not null then c.id = p_corrida
               else coalesce(c.concluida_em, c.cancelada_em) >= p_de and coalesce(c.iniciada_em, c.aceita_em, c.criada_em) < p_ate end)
     and (p_motoboy is null or c.motoboy_id = p_motoboy)
     and (p_teste is null or c.teste = p_teste)
     and (not v_gestor or public.ve_corrida(c.id))
     and not exists (select 1 from public.localizacoes l where l.corrida_id = c.id);

  return jsonb_build_object('pings', v_pings, 'legado', v_legado);
end;
$$;
create or replace function public.minha_conta_cliente()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_cli uuid := privado.minha_empresa(); e public.empresas%rowtype;
begin
  if v_cli is null then return null; end if;
  select * into e from public.empresas where id = v_cli;
  return jsonb_build_object(
    'id', e.id, 'nome', e.nome, 'tipo', e.tipo, 'documento', coalesce(e.cnpj, e.cpf), 'telefone', e.telefone, 'email', e.email,
    'endereco', e.endereco, 'lat', e.lat, 'lng', e.lng, 'instrucoes_coleta', e.instrucoes_coleta,
    'pode_express', e.pode_express and privado.pol_bool('cliente_pode_express', true, v_cli), 've_ao_vivo', e.cliente_ve_ao_vivo,
    'cobranca', privado.pol_txt('cobranca_modo', 'credito', v_cli), 'fatura_ciclo', privado.pol_txt('fatura_ciclo', 'semanal', v_cli),
    'metodos', to_jsonb(e.pagamento_metodos), 'antecedencia_min', privado.pol_num('agendada_antecedencia_cliente_min', 60, v_cli),
    'tipos_pedido', (select coalesce(jsonb_agg(jsonb_build_object('chave', t.chave, 'nome', t.nome, 'descricao', t.descricao, 'icone', t.icone) order by t.ordem), '[]')
                       from public.tipos_pedido t where t.ativo and (t.organizacao_id is null or t.organizacao_id = privado.org_contexto(v_cli))),
    'categorias', (select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'nome', k.nome, 'descricao', k.descricao, 'perigoso', k.perigoso,
                                                               'classe_risco', k.classe_risco, 'fragil', k.fragil, 'icone', k.icone,
                                                               'campo_descricao', k.campo_descricao, 'campo_peso', k.campo_peso, 'campo_medidas', k.campo_medidas,
                                                               'campo_valor', k.campo_valor, 'campo_quantidade', k.campo_quantidade) order by k.ordem), '[]')
                     from public.categorias_produto k where k.ativa and (k.organizacao_id is null or k.organizacao_id = privado.org_contexto(v_cli))),
    'icone', e.icone, 'teste', privado.cliente_teste(), 've_preco_na_hora', privado.cliente_ve_preco(v_cli),
    'pode_modelos', privado.pol_bool('cliente_pode_modelos', true, v_cli), 'pode_cancelar', privado.pol_bool('cliente_pode_cancelar', true, v_cli),
    'troca_senha', privado.pol_bool('cliente_troca_senha', true, v_cli),
    'pode_avaliar', privado.cfg_bool('saas_avaliacoes', true) and privado.pol_bool('avaliacao_ligada', true, v_cli) and privado.pol_txt('avaliacao_quem', 'cliente', v_cli) in ('cliente', 'ambos'),
    'pode_rastreio', privado.cfg_bool('saas_rastreio', true) and privado.pol_bool('rastreio_ligado', true, v_cli),
    've_nota_motoboy', privado.cfg_bool('saas_cliente_ve_nota_motoboy', true) and privado.pol_bool('cliente_ve_nota_motoboy', false, v_cli),
    'confirmacoes', jsonb_build_object('foto', privado.pol_bool('cliente_confirma_foto', true, v_cli), 'nome', privado.pol_bool('cliente_confirma_nome', true, v_cli),
                                       'assinatura', privado.pol_bool('cliente_confirma_assinatura', true, v_cli), 'codigo', privado.pol_bool('cliente_confirma_codigo', true, v_cli)),
    'padrao_confirmacoes', jsonb_build_object('foto', privado.cfg_bool('padrao_exige_foto', false), 'nome', privado.cfg_bool('padrao_exige_nome', true),
                                              'assinatura', privado.cfg_bool('padrao_exige_assinatura', false), 'codigo', privado.cfg_bool('padrao_exige_codigo', false)),
    'pode_janela', privado.pol_bool('cliente_pode_janela', true, v_cli), 'pode_objetos', privado.pol_bool('cliente_pode_objetos', true, v_cli),
    'modelo_horario', privado.pol_bool('cliente_modelo_horario', true, v_cli),
    'pode_agendar', privado.pol_bool('cliente_pode_agendar', true, v_cli), 'pode_urgente', privado.pol_bool('cliente_pode_urgente', true, v_cli),
    'escolhe_veiculo', privado.pol_bool('cliente_escolhe_veiculo', false, v_cli), 'veiculos_aceitos', privado.pol('veiculos_aceitos', v_cli, null, null),
    'max_entregas', privado.pol_num('cliente_max_entregas', 0, v_cli), 'max_coletas', privado.pol_num('cliente_max_coletas', 0, v_cli),
    'agendar_max_dias', privado.pol_num('cliente_agendar_max_dias', 60, v_cli), 'pode_ida_volta', privado.pol_bool('cliente_pode_ida_volta', true, v_cli),
    'coleta_fixa', privado.pol_bool('cliente_coleta_fixa', false, v_cli), 'pode_observacoes', privado.pol_bool('cliente_pode_observacoes', true, v_cli),
    've_faturas', privado.pol_bool('cliente_ve_faturas', true, v_cli), 'pode_chat', privado.pol_bool('cliente_pode_chat', true, v_cli),
    've_rota', coalesce(privado.pol('cliente_ve_rota', v_cli), '["feito", "motoboy"]'::jsonb),
    'pedido_de', privado.pol_txt('cliente_pedido_de', '', v_cli), 'pedido_ate', privado.pol_txt('cliente_pedido_ate', '', v_cli),
    'modo_distancia', privado.pol_txt('preco_distancia_modo', 'soma_entregas', v_cli), 'categoria_obrigatoria', privado.cfg_bool('item_categoria_obrigatoria', false),
    'em_aberto', (select coalesce(sum(valor), 0) from public.pedidos where empresa_id = v_cli and teste = privado.cliente_teste() and cobranca = 'credito' and fatura_id is null and status = 'concluido'));
end;
$$;

-- ===================================================================== servidores de mapa (Dev → Ajustes → Plataforma)
-- Os públicos gratuitos são o padrão; com volume, o Dev aponta para servidores próprios ou pagos (mesmo formato de API).
create or replace function public.servidores_mapa()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'osrm', coalesce(nullif(trim(privado.cfg_txt('dev_mapa_osrm', '')), ''), 'https://router.project-osrm.org'),
    'valhalla', coalesce(nullif(trim(privado.cfg_txt('dev_mapa_valhalla', '')), ''), 'https://valhalla1.openstreetmap.de'),
    'nominatim', coalesce(nullif(trim(privado.cfg_txt('dev_mapa_nominatim', '')), ''), 'https://nominatim.openstreetmap.org'));
$$;
grant execute on function public.servidores_mapa() to anon, authenticated;
insert into public.ajuste_grupos (chave, grupo, area) values
  ('dev_mapa_osrm', 'plataforma', 'sistema'), ('dev_mapa_valhalla', 'plataforma', 'sistema'), ('dev_mapa_nominatim', 'plataforma', 'sistema')
on conflict (chave) do update set grupo = excluded.grupo, area = excluded.area;

create or replace function privado.corrida_json_completo(p_corrida uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', c.id, 'numero', c.numero, 'status', c.status, 'origem', c.origem, 'tipo_pedido', c.tipo_pedido,
    'agendada_para', c.agendada_para, 'reservada_em', c.reservada_em,
    'cancelar_reserva_ate', case when c.agendada_para is not null
      then c.agendada_para - make_interval(mins => privado.cfg_num('agendada_cancelar_ate_min', 60)::int) end,
    'iniciar_a_partir_de', case when c.agendada_para is not null
      then c.agendada_para - make_interval(mins => privado.cfg_num('agendada_iniciar_antes_min', 60)::int) end,
    'teste', c.teste, 'urgente', c.urgente, 'perigoso', c.tem_perigoso,
    'valor_motoboy', coalesce(c.valor_motoboy, (privado.calcular_pagamento(c.id, auth.uid()) ->> 'total')::numeric),
    'distancia_planejada_m', c.distancia_planejada_m, 'duracao_planejada_s', c.duracao_planejada_s,
    'observacoes', c.observacoes, 'exige_foto', c.exige_foto, 'exige_assinatura', c.exige_assinatura,
    'exige_nome', c.exige_nome, 'exige_codigo', c.exige_codigo, 'exigir_no_local', c.exigir_no_local,
    'raio_chegada_m', c.raio_chegada_m, 'rota_planejada', c.rota_planejada, 'aguardando_confirmacao', c.aguardando_confirmacao,
    'empresa_nome', coalesce(e.nome, c.cliente_nome),
    'entregas', (select count(*) from public.paradas p where p.corrida_id = c.id and p.tipo = 'entrega'),
    'coletas', (select count(*) from public.paradas p where p.corrida_id = c.id and p.tipo = 'coleta'),
    'paradas', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id, 'ordem', p.ordem, 'tipo', p.tipo, 'endereco', p.endereco,
        'lat', p.lat, 'lng', p.lng, 'contato_nome', p.contato_nome,
        'contato_telefone', p.contato_telefone, 'instrucoes', p.instrucoes, 'status', p.status,
        'referencias', p.referencias, 'liberada_local', p.liberada_local, 'confirmacao_pendente', p.confirmacao_pendente,
        'exige', privado.exige_parada(p, c), 'janela_de', to_char(p.janela_de, 'HH24:MI'), 'janela_ate', to_char(p.janela_ate, 'HH24:MI'),
        'cliente', (select coalesce(em.nome, pd.cliente_nome) from public.pedidos pd left join public.empresas em on em.id = pd.empresa_id where pd.id = p.pedido_id),
        'pedido_numero', (select pd.numero from public.pedidos pd where pd.id = p.pedido_id),
        'itens', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'descricao', i.descricao, 'quantidade', i.quantidade,
                    'categoria', k.nome, 'icone', k.icone, 'perigoso', coalesce(k.perigoso, false), 'fragil', coalesce(k.fragil, false),
                    'peso_kg', i.peso_kg, 'comprimento_cm', i.comprimento_cm, 'largura_cm', i.largura_cm, 'altura_cm', i.altura_cm,
                    'valor_declarado', i.valor_declarado, 'observacoes', i.observacoes,
                    -- true = não está preso a este ponto (vai para todas as entregas / sai de qualquer coleta)
                    'todas', case when p.tipo = 'entrega' then i.entrega_id is null else i.coleta_id is null end)), '[]')
                    from public.pedido_itens i left join public.categorias_produto k on k.id = i.categoria_id
                   where p.pedido_ponto_id is not null and i.pedido_id = p.pedido_id
                     and (case when p.tipo = 'entrega' then i.entrega_id = p.pedido_ponto_id or i.entrega_id is null
                               else (i.coleta_id = p.pedido_ponto_id or i.coleta_id is null)
                                    -- só o que vai para uma entrega desta rota
                                    and (i.entrega_id is null or exists (select 1 from public.paradas p2 where p2.corrida_id = c.id
                                         and p2.tipo = 'entrega' and p2.pedido_ponto_id = i.entrega_id)) end))
      ) order by p.ordem)
      from public.paradas p where p.corrida_id = c.id
    ), '[]'::jsonb)
  )
  from public.corridas c
  left join public.empresas e on e.id = c.empresa_id
  where c.id = p_corrida;
$$;

-- ajustes novos nos grupos de permissão
insert into public.ajuste_grupos (chave, grupo, area) values
  ('veiculos_aceitos', 'veiculo', 'motoboys'),
  ('cliente_escolhe_veiculo', 'cli_pode', 'clientes'),
  ('aviso_texto_cadastro', 'integracoes', 'sistema'),
  ('aviso_texto_fatura', 'integracoes', 'sistema'),
  ('aviso_texto_entregue', 'integracoes', 'sistema'),
  ('aviso_texto_devolucao', 'integracoes', 'sistema'),
  ('api_limite_minuto', 'plataforma', 'sistema'),
  ('gestor_cria_campos', 'plataforma', 'sistema')
on conflict (chave) do update set grupo = excluded.grupo, area = excluded.area;
