-- =====================================================================
-- PW Express · Pedido sob medida do cliente
-- ---------------------------------------------------------------------
--  • Cada coleta/entrega pode pedir confirmações próprias (foto, nome de
--    quem entregou/recebeu, assinatura, código) e uma janela de horário.
--    Vazio = segue o padrão da rota. O código passa a ser de cada parada.
--  • Objetos salvos: o cliente guarda os produtos que manda sempre.
--  • Tudo é peça do lego: o gestor liga/desliga no geral e por cliente.
-- Rode depois de 20261110000011. Seguro rodar de novo.
-- =====================================================================

-- ------------------------------------------------------------- colunas
alter table public.pedido_pontos add column if not exists exige_foto boolean;
alter table public.pedido_pontos add column if not exists exige_assinatura boolean;
alter table public.pedido_pontos add column if not exists exige_nome boolean;
alter table public.pedido_pontos add column if not exists exige_codigo boolean;
alter table public.pedido_pontos add column if not exists janela_de time;
alter table public.pedido_pontos add column if not exists janela_ate time;
alter table public.paradas add column if not exists exige_foto boolean;
alter table public.paradas add column if not exists exige_assinatura boolean;
alter table public.paradas add column if not exists exige_nome boolean;
alter table public.paradas add column if not exists exige_codigo boolean;
alter table public.paradas add column if not exists codigo text;
alter table public.paradas add column if not exists janela_de time;
alter table public.paradas add column if not exists janela_ate time;

-- padrões das peças novas (o gestor muda no geral e em cada cliente)
insert into public.configuracoes (chave, valor) values
  ('cliente_confirma_foto', 'true'), ('cliente_confirma_nome', 'true'), ('cliente_confirma_assinatura', 'true'),
  ('cliente_confirma_codigo', 'true'), ('cliente_pode_janela', 'true'), ('cliente_pode_objetos', 'true'),
  ('cliente_modelo_horario', 'true')
on conflict (chave) do nothing;

-- ------------------------------------------------------------- a parada herda o que o cliente pediu no ponto
create or replace function privado.parada_herda_ponto()
returns trigger language plpgsql security definer set search_path = '' as $$
declare pp public.pedido_pontos%rowtype;
begin
  if new.pedido_ponto_id is null then return new; end if;
  select * into pp from public.pedido_pontos where id = new.pedido_ponto_id;
  if not found then return new; end if;
  new.exige_foto := coalesce(new.exige_foto, pp.exige_foto);
  new.exige_assinatura := coalesce(new.exige_assinatura, pp.exige_assinatura);
  new.exige_nome := coalesce(new.exige_nome, pp.exige_nome);
  new.exige_codigo := coalesce(new.exige_codigo, pp.exige_codigo);
  new.janela_de := coalesce(new.janela_de, pp.janela_de);
  new.janela_ate := coalesce(new.janela_ate, pp.janela_ate);
  if new.exige_codigo and new.codigo is null then new.codigo := lpad((floor(random() * 10000))::int::text, 4, '0'); end if;
  return new;
end;
$$;
drop trigger if exists paradas_herda_ponto on public.paradas;
create trigger paradas_herda_ponto before insert on public.paradas for each row execute function privado.parada_herda_ponto();

-- o que vale de fato em cada parada: o do ponto ou, vazio, o padrão da rota (que vale só nas entregas)
create or replace function privado.exige_parada(p public.paradas, c public.corridas)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'foto', coalesce(p.exige_foto, p.tipo = 'entrega' and c.exige_foto),
    'assinatura', coalesce(p.exige_assinatura, p.tipo = 'entrega' and c.exige_assinatura),
    'nome', coalesce(p.exige_nome, p.tipo = 'entrega' and c.exige_nome),
    'codigo', coalesce(p.exige_codigo, p.tipo = 'entrega' and c.exige_codigo));
$$;

-- ------------------------------------------------------------- objetos salvos do cliente
create table if not exists public.cliente_objetos (
  id         uuid primary key default gen_random_uuid(),
  empresa_id uuid not null references public.empresas (id) on delete cascade,
  nome       text not null check (length(trim(nome)) between 1 and 80),
  dados      jsonb not null default '{}',
  usos       int not null default 0,
  criado_em  timestamptz not null default now(),
  unique (empresa_id, nome)
);
alter table public.cliente_objetos enable row level security;
create or replace function public.pode_salvar_objetos()
returns boolean language sql stable security definer set search_path = '' as $$
  select privado.pol_bool('cliente_pode_objetos', true, privado.minha_empresa());
$$;
drop policy if exists cliente_objetos_acesso on public.cliente_objetos;
create policy cliente_objetos_acesso on public.cliente_objetos for all to authenticated
  using (empresa_id = (select public.minha_empresa_id()) or (select public.is_gestor()))
  with check ((empresa_id = (select public.minha_empresa_id()) and (select public.pode_salvar_objetos())) or (select public.is_gestor()));
revoke all on public.cliente_objetos from anon;
grant select, insert, update, delete on public.cliente_objetos to authenticated;


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
  end if;
  if v_gestor then v_regras := privado.limpar_regras(dados -> 'regras'); end if;
  if v_cli is not null and v_gestor and (select modo_teste from public.empresas where id = v_cli) then v_teste := true; end if;
  if v_cli is not null then select * into e from public.empresas where id = v_cli; end if;
  if not exists (select 1 from public.tipos_pedido where chave = v_tp and (ativo or v_gestor)) then raise exception 'tipo_pedido_invalido' using errcode = '22023'; end if;

  v_tipo := case when v_quando is null then 'express' else 'planejado' end;
  if not v_gestor then
    if v_tipo = 'express' and not (coalesce(e.pode_express, false) and privado.pol_bool('cliente_pode_express', true, v_cli, null, v_tp)) then
      raise exception 'cliente_so_agendado' using errcode = '42501';
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
    select * into v_cat from public.categorias_produto where id = (i ->> 'categoria_id')::uuid;
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

  for p in select * from jsonb_array_elements(dados -> 'pontos') loop
    -- confirmações e janela de cada ponto: o cliente só pede o que o gestor liberou para ele
    insert into public.pedido_pontos (pedido_id, ordem, tipo, endereco, lat, lng, contato_nome, contato_telefone, instrucoes, referencias,
                                      exige_foto, exige_assinatura, exige_nome, exige_codigo, janela_de, janela_ate)
    values (v_id, k, (p ->> 'tipo')::public.tipo_parada, left(coalesce(p ->> 'endereco', ''), 300), (p ->> 'lat')::double precision, (p ->> 'lng')::double precision,
            nullif(left(p ->> 'contato_nome', 120), ''), nullif(left(p ->> 'contato_telefone', 40), ''), nullif(left(p ->> 'instrucoes', 500), ''),
            privado.limpar_referencias(p -> 'referencias'),
            case when v_gestor or privado.pol_bool('cliente_confirma_foto', true, v_cli, null, v_tp) then (p ->> 'exige_foto')::boolean end,
            case when v_gestor or privado.pol_bool('cliente_confirma_assinatura', true, v_cli, null, v_tp) then (p ->> 'exige_assinatura')::boolean end,
            case when v_gestor or privado.pol_bool('cliente_confirma_nome', true, v_cli, null, v_tp) then (p ->> 'exige_nome')::boolean end,
            case when v_gestor or privado.pol_bool('cliente_confirma_codigo', true, v_cli, null, v_tp) then (p ->> 'exige_codigo')::boolean end,
            case when v_gestor or privado.pol_bool('cliente_pode_janela', true, v_cli, null, v_tp) then nullif(p ->> 'janela_de', '')::time end,
            case when v_gestor or privado.pol_bool('cliente_pode_janela', true, v_cli, null, v_tp) then nullif(p ->> 'janela_ate', '')::time end)
    returning id into v_pid;
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
  perform privado.checar_versao_app();
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

create or replace function privado.corrida_json_completo(p_corrida uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', c.id, 'numero', c.numero, 'status', c.status, 'origem', c.origem,
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
    'raio_chegada_m', c.raio_chegada_m, 'rota_planejada', c.rota_planejada,
    'empresa_nome', coalesce(e.nome, c.cliente_nome),
    'entregas', (select count(*) from public.paradas p where p.corrida_id = c.id and p.tipo = 'entrega'),
    'coletas', (select count(*) from public.paradas p where p.corrida_id = c.id and p.tipo = 'coleta'),
    'paradas', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id, 'ordem', p.ordem, 'tipo', p.tipo, 'endereco', p.endereco,
        'lat', p.lat, 'lng', p.lng, 'contato_nome', p.contato_nome,
        'contato_telefone', p.contato_telefone, 'instrucoes', p.instrucoes, 'status', p.status,
        'referencias', p.referencias,
        'exige', privado.exige_parada(p, c), 'janela_de', to_char(p.janela_de, 'HH24:MI'), 'janela_ate', to_char(p.janela_ate, 'HH24:MI'),
        'cliente', (select coalesce(em.nome, pd.cliente_nome) from public.pedidos pd left join public.empresas em on em.id = pd.empresa_id where pd.id = p.pedido_id),
        'pedido_numero', (select pd.numero from public.pedidos pd where pd.id = p.pedido_id),
        'itens', (select coalesce(jsonb_agg(jsonb_build_object('descricao', i.descricao, 'quantidade', i.quantidade,
                    'categoria', k.nome, 'perigoso', coalesce(k.perigoso, false), 'fragil', coalesce(k.fragil, false))), '[]')
                    from public.pedido_itens i left join public.categorias_produto k on k.id = i.categoria_id
                   where p.pedido_ponto_id is not null and (i.entrega_id = p.pedido_ponto_id or i.coleta_id = p.pedido_ponto_id))
      ) order by p.ordem)
      from public.paradas p where p.corrida_id = c.id
    ), '[]'::jsonb)
  )
  from public.corridas c
  left join public.empresas e on e.id = c.empresa_id
  where c.id = p_corrida;
$$;

create or replace function public.meus_pedidos_cliente(p_dias int default 120)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(x order by (x ->> 'criado_em') desc), '[]'::jsonb) from (
    select jsonb_build_object(
      'id', p.id, 'numero', p.numero, 'tipo', p.tipo, 'tipo_pedido', p.tipo_pedido, 'quando', p.quando, 'urgente', p.urgente,
      'status', p.status,
      'valor', case when privado.cliente_ve_preco(p.empresa_id, p.status::text) then p.valor end,
      'orcamento', case when privado.cliente_ve_preco(p.empresa_id, p.status::text) then p.orcamento end,
      'preco_oculto', not privado.cliente_ve_preco(p.empresa_id, p.status::text), 'cobranca', p.cobranca, 'pagamento_status', p.pagamento_status,
      'pagamento_metodo', p.pagamento_metodo, 'fatura_id', p.fatura_id, 'observacoes', p.observacoes, 'recusa_motivo', p.recusa_motivo,
      'criado_em', p.criado_em, 'concluido_em', p.concluido_em, 'cancelado_em', p.cancelado_em,
      'pontos', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'tipo', x.tipo, 'endereco', x.endereco, 'lat', x.lat, 'lng', x.lng,
                                 'contato_nome', x.contato_nome, 'status', x.status, 'concluido_em', x.concluido_em, 'recebedor_nome', x.recebedor_nome,
                                 'exige_foto', x.exige_foto, 'exige_assinatura', x.exige_assinatura, 'exige_nome', x.exige_nome, 'exige_codigo', x.exige_codigo,
                                 'janela_de', to_char(x.janela_de, 'HH24:MI'), 'janela_ate', to_char(x.janela_ate, 'HH24:MI'),
                                 'codigo', (select pa.codigo from public.paradas pa join public.corridas c on c.id = pa.corrida_id
                                             where pa.pedido_ponto_id = x.id and pa.codigo is not null and c.status::text not in ('cancelada', 'concluida')
                                               and privado.pol_bool('cliente_ve_codigo', true, p.empresa_id) limit 1)) order by x.ordem)
                          from public.pedido_pontos x where x.pedido_id = p.id), '[]'),
      'itens', coalesce((select jsonb_agg(jsonb_build_object('descricao', i.descricao, 'quantidade', i.quantidade, 'peso_kg', i.peso_kg,
                                'categoria', k.nome, 'categoria_id', i.categoria_id, 'icone', k.icone, 'perigoso', coalesce(k.perigoso, false),
                                'comprimento_cm', i.comprimento_cm, 'largura_cm', i.largura_cm, 'altura_cm', i.altura_cm, 'valor_declarado', i.valor_declarado))
                         from public.pedido_itens i left join public.categorias_produto k on k.id = i.categoria_id where i.pedido_id = p.id), '[]'),
      'motoboys', (select coalesce(jsonb_agg(distinct split_part(pf.nome, ' ', 1)) filter (where privado.pol_bool('cliente_ve_motoboy', true, p.empresa_id)), '[]') from public.paradas pa join public.corridas c on c.id = pa.corrida_id
                     join public.perfis pf on pf.id = c.motoboy_id where pa.pedido_id = p.id and c.status::text <> 'cancelada'),
      'codigos', (select coalesce(jsonb_agg(distinct c.codigo_entrega) filter (where c.codigo_entrega is not null and privado.pol_bool('cliente_ve_codigo', true, p.empresa_id)), '[]') from public.paradas pa
                    join public.corridas c on c.id = pa.corrida_id where pa.pedido_id = p.id and c.exige_codigo and pa.exige_codigo is not false and pa.codigo is null and c.status::text not in ('cancelada', 'concluida'))
    ) x
      from public.pedidos p
     where p.empresa_id = privado.minha_empresa() and p.teste = privado.cliente_teste()
       and p.criado_em > now() - make_interval(days => greatest(1, least(p_dias, 400)))
     limit 500
  ) t;
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
                       from public.tipos_pedido t where t.ativo),
    'categorias', (select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'nome', k.nome, 'descricao', k.descricao, 'perigoso', k.perigoso,
                                                               'classe_risco', k.classe_risco, 'fragil', k.fragil, 'icone', k.icone,
                                                               'campo_descricao', k.campo_descricao, 'campo_peso', k.campo_peso, 'campo_medidas', k.campo_medidas,
                                                               'campo_valor', k.campo_valor, 'campo_quantidade', k.campo_quantidade) order by k.ordem), '[]')
                     from public.categorias_produto k where k.ativa),
    'icone', e.icone, 'teste', privado.cliente_teste(), 've_preco_na_hora', privado.cliente_ve_preco(v_cli),
    'pode_modelos', privado.pol_bool('cliente_pode_modelos', true, v_cli), 'pode_cancelar', privado.pol_bool('cliente_pode_cancelar', true, v_cli),
    'troca_senha', privado.pol_bool('cliente_troca_senha', true, v_cli),
    'confirmacoes', jsonb_build_object('foto', privado.pol_bool('cliente_confirma_foto', true, v_cli), 'nome', privado.pol_bool('cliente_confirma_nome', true, v_cli),
                                       'assinatura', privado.pol_bool('cliente_confirma_assinatura', true, v_cli), 'codigo', privado.pol_bool('cliente_confirma_codigo', true, v_cli)),
    'padrao_confirmacoes', jsonb_build_object('foto', privado.cfg_bool('padrao_exige_foto', false), 'nome', privado.cfg_bool('padrao_exige_nome', true),
                                              'assinatura', privado.cfg_bool('padrao_exige_assinatura', false), 'codigo', privado.cfg_bool('padrao_exige_codigo', false)),
    'pode_janela', privado.pol_bool('cliente_pode_janela', true, v_cli), 'pode_objetos', privado.pol_bool('cliente_pode_objetos', true, v_cli),
    'modelo_horario', privado.pol_bool('cliente_modelo_horario', true, v_cli), 'categoria_obrigatoria', privado.cfg_bool('item_categoria_obrigatoria', false),
    'em_aberto', (select coalesce(sum(valor), 0) from public.pedidos where empresa_id = v_cli and teste = privado.cliente_teste() and cobranca = 'credito' and fatura_id is null and status = 'concluido'));
end;
$$;


revoke all on function privado.parada_herda_ponto() from public, anon, authenticated;
revoke all on function privado.exige_parada(public.paradas, public.corridas) from public, anon, authenticated;

notify pgrst, 'reload schema';
