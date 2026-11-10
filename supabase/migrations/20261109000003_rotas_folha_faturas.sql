-- =====================================================================
-- PW Express · Renascimento (parte 3 de 3): rotas automáticas, despacho, folha e faturas
-- Rode DEPOIS de 20261109000002_renascimento.sql.
--
--  • Pedido → (revisão do gestor, se ligada) → roteirizador → rota (corrida).
--    O roteirizador junta entregas de pedidos diferentes (mesma janela de horário e
--    perto umas das outras) e separa as de um mesmo pedido quando ficam longe.
--  • Despacho por regra: quadro (todos veem, o 1º que pegar leva), melhor primeiro,
--    cascata ou direto. Express e planejadas aparecem com o mesmo peso no app.
--  • Pagamento do motoboy por rota: km da entrega de referência × valor do km
--    + valor por entrega/coleta extra (regras escolhidas pelo gestor).
--  • Folha (holerite) por período, com ajustes do gestor. Motoboy não vê valores
--    a menos que o gestor permita.
--  • Faturas do cliente no crédito, por ciclo (diário, semanal, quinzenal, mensal).
-- =====================================================================

-- Chamada feita com a chave secreta (site/servidor), não por um usuário
create or replace function privado.eh_servico()
returns boolean language sql stable set search_path = '' as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role',
                  nullif(current_setting('request.jwt.claim.role', true), '')) = 'service_role';
$$;

-- ------------------------------------------------------------- colunas novas
alter table public.corridas add column if not exists origem text not null default 'manual';
alter table public.corridas add column if not exists tipo_pedido text;
alter table public.corridas add column if not exists pag_calculo jsonb;
alter table public.corridas add column if not exists pag_ajuste numeric(10, 2) not null default 0;
alter table public.corridas add column if not exists pag_ajuste_motivo text;
alter table public.corridas add column if not exists sugerido_motoboy_id uuid references public.motoboys (id) on delete set null;
alter table public.corridas add column if not exists quadro_desde timestamptz;
alter table public.corridas add column if not exists otimizada_em timestamptz;
alter table public.corridas add column if not exists montada_em timestamptz;
alter table public.corridas add column if not exists exclusiva_empresa uuid;
alter table public.corridas add column if not exists tem_perigoso boolean not null default false;

alter table public.paradas add column if not exists pedido_id uuid references public.pedidos (id) on delete set null;
alter table public.paradas add column if not exists pedido_ponto_id uuid references public.pedido_pontos (id) on delete set null;
alter table public.paradas add column if not exists dist_rua_m int;
alter table public.paradas add column if not exists dist_acum_m int;
create index if not exists paradas_pedido_ponto_idx on public.paradas (pedido_ponto_id);
create index if not exists paradas_pedido_idx on public.paradas (pedido_id);

-- ------------------------------------------------------------- criar pedido (cliente ou gestor)
-- dados: {empresa_id?, cliente_nome?, quando?, urgente?, tipo_pedido?, observacoes?, distancia_m?, teste?, metodo?,
--         pontos:[{tipo, endereco, lat, lng, contato_nome, contato_telefone, instrucoes, referencias}],
--         itens:[{descricao, categoria_id, quantidade, peso_kg, comprimento_cm, largura_cm, altura_cm, valor_declarado, coleta, entrega}]}
--   (coleta/entrega dos itens = índice do ponto na lista, começando em 0)
create or replace function public.criar_pedido(dados jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_gestor  boolean := public.is_gestor();
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
  end if;
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

  v_orc := privado.orcar(jsonb_build_object('empresa_id', v_cli, 'tipo', v_tipo, 'tipo_pedido', v_tp, 'quando', v_quando,
                                            'urgente', coalesce((dados ->> 'urgente')::boolean, false), 'distancia_m', dados -> 'distancia_m',
                                            'pontos', dados -> 'pontos', 'itens', coalesce(dados -> 'itens', '[]')));
  v_cobr := privado.pol_txt('cobranca_modo', 'credito', v_cli, null, v_tp);
  if v_cli is null then v_cobr := 'pre_pago'; end if;
  v_status := case when v_gestor then 'aprovado'
                   when privado.pol_bool('pedido_revisao_gestor', true, v_cli, null, v_tp) then 'recebido'
                   else 'aprovado' end;
  v_dev := coalesce(e.dev_pct, privado.pol_num('dev_pct', 5, v_cli, null, v_tp));

  insert into public.pedidos (teste, empresa_id, cliente_nome, criado_por, origem, tipo, tipo_pedido, quando, urgente, status, observacoes,
                              distancia_estimada_m, orcamento, valor_calculado, valor, dev_pct, valor_dev, cobranca, pagamento_status,
                              pagamento_metodo, aprovado_em, revisado_por, revisado_em)
  values (v_teste, v_cli, case when v_cli is null then nullif(trim(dados ->> 'cliente_nome'), '') end, auth.uid(),
          case when v_gestor then 'gestor' else 'cliente' end, v_tipo, v_tp, v_quando, coalesce((dados ->> 'urgente')::boolean, false),
          v_status, nullif(left(dados ->> 'observacoes', 1000), ''), (v_orc ->> 'distancia_m')::int, v_orc,
          (v_orc ->> 'total')::numeric, (v_orc ->> 'total')::numeric, v_dev, round((v_orc ->> 'total')::numeric * v_dev / 100, 2),
          v_cobr, case when v_cobr = 'pre_pago' then 'pendente' else 'nao_exigido' end, nullif(dados ->> 'metodo', ''),
          case when v_status = 'aprovado' then now() end,
          case when v_gestor then auth.uid() end, case when v_gestor then now() end)
  returning id into v_id;

  for p in select * from jsonb_array_elements(dados -> 'pontos') loop
    insert into public.pedido_pontos (pedido_id, ordem, tipo, endereco, lat, lng, contato_nome, contato_telefone, instrucoes, referencias)
    values (v_id, k, (p ->> 'tipo')::public.tipo_parada, left(coalesce(p ->> 'endereco', ''), 300), (p ->> 'lat')::double precision, (p ->> 'lng')::double precision,
            nullif(left(p ->> 'contato_nome', 120), ''), nullif(left(p ->> 'contato_telefone', 40), ''), nullif(left(p ->> 'instrucoes', 500), ''),
            privado.limpar_referencias(p -> 'referencias'))
    returning id into v_pid;
    v_ids := v_ids || v_pid;
    k := k + 1;
  end loop;

  for i in select * from jsonb_array_elements(coalesce(dados -> 'itens', '[]')) loop
    insert into public.pedido_itens (pedido_id, coleta_id, entrega_id, descricao, categoria_id, quantidade, peso_kg, comprimento_cm, largura_cm, altura_cm, valor_declarado, observacoes)
    values (v_id,
            case when nullif(i ->> 'coleta', '') is not null then v_ids[(i ->> 'coleta')::int + 1] end,
            case when nullif(i ->> 'entrega', '') is not null then v_ids[(i ->> 'entrega')::int + 1] end,
            left(coalesce(nullif(trim(i ->> 'descricao'), ''), 'Item'), 200), nullif(i ->> 'categoria_id', '')::uuid,
            greatest(1, coalesce((i ->> 'quantidade')::int, 1)), nullif(i ->> 'peso_kg', '')::numeric,
            nullif(i ->> 'comprimento_cm', '')::numeric, nullif(i ->> 'largura_cm', '')::numeric, nullif(i ->> 'altura_cm', '')::numeric,
            nullif(i ->> 'valor_declarado', '')::numeric, nullif(left(i ->> 'observacoes', 300), ''));
  end loop;

  perform privado.evento_pedido(v_id, 'criado', jsonb_build_object('origem', case when v_gestor then 'gestor' else 'cliente' end, 'total', v_orc -> 'total'));
  if v_status = 'aprovado' then perform privado.roteirizar(v_teste); end if;
  return v_id;
end;
$$;

-- Gestor revisa: aprovar (com valor final opcional), ajustar o valor, recusar ou recalcular o orçamento
create or replace function public.revisar_pedido(p_pedido uuid, p_acao text, p_valor numeric default null, p_motivo text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  p     public.pedidos%rowtype;
  v_orc jsonb;
  v_val numeric;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select * into p from public.pedidos where id = p_pedido for update;
  if not found then raise exception 'pedido_nao_encontrado' using errcode = '22023'; end if;
  if p.status in ('concluido', 'cancelado', 'recusado') and p_acao <> 'ajustar' then raise exception 'pedido_finalizado' using errcode = '22023'; end if;
  if p.fatura_id is not null and exists (select 1 from public.faturas f where f.id = p.fatura_id and f.status <> 'rascunho') then
    raise exception 'pedido_ja_faturado' using errcode = '22023';
  end if;

  if p_acao = 'recalcular' then
    select privado.orcar(jsonb_build_object('empresa_id', p.empresa_id, 'tipo', p.tipo, 'tipo_pedido', p.tipo_pedido, 'quando', p.quando, 'urgente', p.urgente,
             'distancia_m', p.distancia_estimada_m,
             'pontos', (select jsonb_agg(jsonb_build_object('tipo', x.tipo, 'lat', x.lat, 'lng', x.lng) order by x.ordem) from public.pedido_pontos x where x.pedido_id = p.id),
             'itens', coalesce((select jsonb_agg(to_jsonb(i)) from public.pedido_itens i where i.pedido_id = p.id), '[]')))
      into v_orc;
    update public.pedidos set orcamento = v_orc, valor_calculado = (v_orc ->> 'total')::numeric,
           valor = (v_orc ->> 'total')::numeric + valor_ajuste, valor_dev = round(((v_orc ->> 'total')::numeric + valor_ajuste) * dev_pct / 100, 2)
     where id = p.id;
    perform privado.evento_pedido(p.id, 'recalculado', jsonb_build_object('total', v_orc -> 'total'));
  elsif p_acao in ('aprovar', 'ajustar') then
    if p_valor is not null then
      if p_valor < 0 then raise exception 'valor_invalido' using errcode = '22023'; end if;
      if p_valor <> coalesce(p.valor_calculado, 0) and coalesce(trim(p_motivo), '') = '' and p_valor <> p.valor then
        raise exception 'informe_o_motivo' using errcode = '22023';
      end if;
      v_val := round(p_valor, 2);
      update public.pedidos set valor = v_val, valor_ajuste = v_val - coalesce(valor_calculado, 0),
             ajuste_motivo = coalesce(nullif(trim(p_motivo), ''), ajuste_motivo), valor_dev = round(v_val * dev_pct / 100, 2)
       where id = p.id;
      -- a rota recebe a parte nova do valor
      perform privado.valores_rota(x.corrida_id) from (select distinct corrida_id from public.paradas where pedido_id = p.id) x;
      perform privado.evento_pedido(p.id, 'valor_ajustado', jsonb_build_object('de', p.valor, 'para', v_val, 'motivo', p_motivo));
    end if;
    if p_acao = 'aprovar' and p.status = 'recebido' then
      update public.pedidos set status = 'aprovado', aprovado_em = now(), revisado_por = auth.uid(), revisado_em = now() where id = p.id;
      perform privado.evento_pedido(p.id, 'aprovado');
      perform privado.roteirizar(p.teste);
    end if;
  elsif p_acao = 'recusar' then
    if p.status not in ('recebido', 'aprovado') then raise exception 'pedido_ja_em_rota' using errcode = '22023'; end if;
    update public.pedidos set status = 'recusado', recusa_motivo = nullif(trim(p_motivo), ''), revisado_por = auth.uid(), revisado_em = now() where id = p.id;
    perform privado.tirar_das_rotas(p.id);
    perform privado.evento_pedido(p.id, 'recusado', jsonb_build_object('motivo', p_motivo));
  else
    raise exception 'acao_invalida' using errcode = '22023';
  end if;
  return (select to_jsonb(x) from public.pedidos x where x.id = p.id);
end;
$$;

-- Tira as paradas de um pedido das rotas que ainda não começaram (as vazias são canceladas)
create or replace function privado.tirar_das_rotas(p_pedido uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare r uuid;
begin
  for r in select distinct x.corrida_id from public.paradas x join public.corridas c on c.id = x.corrida_id
            where x.pedido_id = p_pedido and c.status::text in ('montada', 'agendada', 'reservada', 'aguardando_motoboy', 'sem_motoboy') loop
    update public.ofertas set status = 'cancelada' where corrida_id = r and status = 'pendente';
    delete from public.paradas where corrida_id = r and pedido_id = p_pedido;
    if not exists (select 1 from public.paradas where corrida_id = r and tipo = 'entrega') then
      update public.corridas set status = 'cancelada', cancelada_em = now() where id = r;
      perform privado.evento(r, 'cancelada', jsonb_build_object('motivo', 'pedidos retirados'));
    else
      perform privado.ordenar_rota(r);
      perform privado.valores_rota(r);
    end if;
  end loop;
end;
$$;

-- Cancelar pedido (gestor; cliente enquanto nenhum motoboy pegou)
create or replace function public.cancelar_pedido(p_pedido uuid, p_motivo text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare p public.pedidos%rowtype;
begin
  select * into p from public.pedidos where id = p_pedido for update;
  if not found or not (public.is_gestor() or (p.empresa_id is not null and p.empresa_id = privado.minha_empresa())) then
    raise exception 'pedido_nao_encontrado' using errcode = '22023';
  end if;
  if p.status in ('concluido', 'cancelado', 'recusado') then raise exception 'pedido_finalizado' using errcode = '22023'; end if;
  if exists (select 1 from public.paradas x join public.corridas c on c.id = x.corrida_id
              where x.pedido_id = p.id and c.status::text in ('aceita', 'em_andamento', 'concluida')) then
    raise exception 'pedido_em_andamento' using errcode = '22023';
  end if;
  if not public.is_gestor() and exists (select 1 from public.paradas x join public.corridas c on c.id = x.corrida_id
                                         where x.pedido_id = p.id and c.status::text = 'reservada') then
    raise exception 'pedido_em_andamento' using errcode = '22023';
  end if;
  perform privado.tirar_das_rotas(p.id);
  update public.pedidos set status = 'cancelado', cancelado_em = now() where id = p.id;
  update public.pedido_pontos set status = 'cancelado' where pedido_id = p.id and status <> 'concluido';
  perform privado.evento_pedido(p.id, 'cancelado', jsonb_build_object('motivo', p_motivo, 'por_cliente', not public.is_gestor()));
end;
$$;

-- Pagamento antecipado recebido (gestor ou intermediadora via service_role)
create or replace function public.confirmar_pagamento_pedido(p_pedido uuid, p_metodo text default null, p_ref text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare v_teste boolean;
begin
  if not (public.is_gestor() or privado.eh_servico()) then
    raise exception 'apenas_gestor' using errcode = '42501';
  end if;
  update public.pedidos set pagamento_status = 'pago', pago_em = now(), pagamento_metodo = coalesce(p_metodo, pagamento_metodo), pagamento_ref = p_ref
   where id = p_pedido and pagamento_status = 'pendente' returning teste into v_teste;
  if not found then raise exception 'pagamento_nao_pendente' using errcode = '22023'; end if;
  perform privado.evento_pedido(p_pedido, 'pago', jsonb_build_object('metodo', p_metodo));
  perform privado.roteirizar(v_teste);
end;
$$;

-- ------------------------------------------------------------- roteirizador
-- Ordena a rota: coletas primeiro (sempre a mais próxima), depois entregas (idem).
-- Distâncias por linha reta × fator de rua; o site troca pelas do mapa (OSRM) logo em seguida.
create or replace function privado.ordenar_rota(p_corrida uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_fator  numeric := privado.cfg_num('fator_rua', 1.3);
  v_lat    double precision; v_lng double precision;
  v_c0lat  double precision; v_c0lng double precision;
  v_ordem  int := 0;
  v_acum   double precision := 0;
  v_pid    uuid; v_plat double precision; v_plng double precision;
  v_fase   text;
begin
  if exists (select 1 from public.paradas where corrida_id = p_corrida and status <> 'pendente') then return; end if;
  update public.paradas set ordem = ordem + 100000 where corrida_id = p_corrida and ordem < 100000;
  foreach v_fase in array array['coleta', 'entrega'] loop
    loop
      v_pid := null;
      select x.id, x.lat, x.lng into v_pid, v_plat, v_plng
        from public.paradas x
       where x.corrida_id = p_corrida and x.ordem >= 100000 and x.tipo::text = v_fase
       order by case when v_lat is null then x.ordem::double precision else privado.dist_m(v_lat, v_lng, x.lat, x.lng) end, x.ordem
       limit 1;
      exit when v_pid is null;
      if v_lat is not null then v_acum := v_acum + privado.dist_m(v_lat, v_lng, v_plat, v_plng) * v_fator; end if;
      if v_c0lat is null then v_c0lat := v_plat; v_c0lng := v_plng; end if;
      update public.paradas set ordem = v_ordem,
             dist_rua_m = case when v_fase = 'entrega' then round(privado.dist_m(v_c0lat, v_c0lng, v_plat, v_plng) * v_fator) end,
             dist_acum_m = round(v_acum)
       where id = v_pid;
      v_lat := v_plat; v_lng := v_plng; v_ordem := v_ordem + 1;
    end loop;
  end loop;
  update public.corridas set distancia_planejada_m = round(v_acum), duracao_planejada_s = round(v_acum / 1000.0 / 25 * 3600) + v_ordem * 180,
         rota_planejada = null, otimizada_em = null
   where id = p_corrida;
end;
$$;

-- Valor da rota (parte de cada pedido proporcional às entregas que estão nela) e prévia do pagamento
create or replace function privado.valores_rota(p_corrida uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_valor numeric;
begin
  select coalesce(sum(round(coalesce(p.valor, 0) * x.n::numeric / greatest(t.total, 1), 2)), 0) into v_valor
    from (select pedido_id, count(*) n from public.paradas where corrida_id = p_corrida and tipo = 'entrega' and pedido_id is not null group by pedido_id) x
    join public.pedidos p on p.id = x.pedido_id
    join lateral (select count(*) total from public.pedido_pontos pp where pp.pedido_id = p.id and pp.tipo = 'entrega') t on true;
  update public.corridas set valor = v_valor, valor_base = v_valor,
         empresa_id = coalesce((select p.empresa_id from public.paradas x join public.pedidos p on p.id = x.pedido_id
                                 where x.corrida_id = p_corrida order by x.ordem limit 1), empresa_id),
         pag_calculo = case when motoboy_id is null then privado.calcular_pagamento(p_corrida, null) else pag_calculo end
   where id = p_corrida;
end;
$$;

-- Melhor motoboy para a rota: disponível, no modo certo, dentro do raio dele; favoritos do cliente e o mais perto da 1ª coleta
create or replace function privado.melhor_motoboy(p_corrida uuid)
returns uuid language sql stable security definer set search_path = '' as $$
  select m.id
    from public.corridas c
    join lateral (select lat, lng from public.paradas where corrida_id = c.id order by ordem limit 1) col on true
    join public.motoboys m on m.status = 'disponivel' and m.modo_teste = c.teste and m.lat is not null
    left join public.empresa_favoritos f on f.motoboy_id = m.id and f.empresa_id = c.empresa_id
   where c.id = p_corrida
     and m.posicao_em > now() - make_interval(mins => privado.cfg_num('posicao_max_min', 15)::int)
     and not exists (select 1 from auth.users u where u.id = m.id and u.banned_until > now())
     and (c.urgente or coalesce(m.raio_km, 0) <= 0 or privado.dist_m(
            case when m.raio_modo = 'fixo' and m.raio_lat is not null then m.raio_lat else m.lat end,
            case when m.raio_modo = 'fixo' and m.raio_lng is not null then m.raio_lng else m.lng end, col.lat, col.lng) <= m.raio_km * 1000)
   order by (f.ordem is null), f.ordem, privado.dist_m(m.lat, m.lng, col.lat, col.lng)
   limit 1;
$$;

-- Avisa (push) quem pode pegar a rota do quadro
create or replace function privado.avisar_quadro(p_corrida uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  c   public.corridas%rowtype;
  v_m uuid;
  v_n int;
begin
  select * into c from public.corridas where id = p_corrida;
  select count(*) into v_n from public.paradas where corrida_id = p_corrida and tipo = 'entrega';
  for v_m in
    select m.id from public.motoboys m
      join public.perfis pf on pf.id = m.id and 'motoboy' = any (pf.papeis)
     where m.modo_teste = c.teste
       and (c.agendada_para is not null or m.status = 'disponivel')
     limit 200
  loop
    perform privado.enviar_push(v_m, jsonb_build_object(
      'tipo', 'rota_nova', 'corrida_id', p_corrida::text, 'teste', c.teste::text,
      'planejada', (c.agendada_para is not null)::text, 'entregas', v_n::text,
      'sugerida', (v_m = c.sugerido_motoboy_id)::text,
      'agendada_para', coalesce(to_char(c.agendada_para at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), '')));
  end loop;
end;
$$;

-- Solta a rota montada para os motoboys, conforme a regra de despacho (cliente > tipo > global)
create or replace function privado.liberar_rota(p_corrida uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  c      public.corridas%rowtype;
  v_modo text;
  v_sug  uuid;
begin
  select * into c from public.corridas where id = p_corrida for update;
  if not found or c.status::text <> 'montada' then return; end if;
  v_modo := privado.pol_txt('despacho_modo', 'quadro', c.empresa_id, null, c.tipo_pedido);
  v_sug := privado.melhor_motoboy(p_corrida);
  update public.corridas set sugerido_motoboy_id = v_sug where id = p_corrida;
  if v_modo = 'direto' then return; end if;   -- gestor escolhe o motoboy
  if c.agendada_para is not null then
    update public.corridas set status = 'agendada', modo_despacho = 'quadro', quadro_desde = now() where id = p_corrida;
    perform privado.evento(p_corrida, 'liberada', jsonb_build_object('modo', 'quadro', 'planejada', true));
    perform privado.avisar_quadro(p_corrida);
  elsif v_modo = 'quadro' then
    update public.corridas set status = 'aguardando_motoboy', modo_despacho = 'quadro', quadro_desde = now() where id = p_corrida;
    perform privado.evento(p_corrida, 'liberada', jsonb_build_object('modo', 'quadro'));
    perform privado.avisar_quadro(p_corrida);
  else
    update public.corridas set status = 'aguardando_motoboy', modo_despacho = v_modo::public.modo_despacho where id = p_corrida;
    perform privado.evento(p_corrida, 'liberada', jsonb_build_object('modo', v_modo));
    perform privado.despachar(p_corrida);
  end if;
end;
$$;

-- Gestor solta a rota (opcional: muda o modo ou já entrega a um motoboy)
create or replace function public.liberar_rota(p_corrida uuid, p_modo text default null, p_motoboy uuid default null)
returns void language plpgsql security definer set search_path = '' as $$
declare c public.corridas%rowtype;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select * into c from public.corridas where id = p_corrida for update;
  if not found or c.status::text not in ('montada', 'sem_motoboy', 'aguardando_motoboy', 'agendada') or c.motoboy_id is not null then
    raise exception 'rota_nao_pode_ser_liberada' using errcode = '22023';
  end if;
  update public.ofertas set status = 'cancelada' where corrida_id = p_corrida and status = 'pendente';
  if p_motoboy is not null then
    if c.agendada_para is not null then
      update public.corridas set status = 'reservada', motoboy_id = p_motoboy, reservada_em = now(), modo_despacho = 'direto' where id = p_corrida;
      perform privado.evento(p_corrida, 'reservada', jsonb_build_object('motoboy_id', p_motoboy, 'pelo_gestor', true));
      perform privado.enviar_push(p_motoboy, jsonb_build_object('tipo', 'planejada_reservada', 'corrida_id', p_corrida::text));
    else
      update public.corridas set status = 'aguardando_motoboy', modo_despacho = 'direto', motoboy_designado_id = p_motoboy, rodada = rodada + 1 where id = p_corrida;
      perform privado.despachar(p_corrida);
    end if;
    return;
  end if;
  if p_modo is not null then
    if p_modo not in ('quadro', 'melhor_primeiro', 'cascata') then raise exception 'modo_invalido' using errcode = '22023'; end if;
    update public.corridas set status = 'montada' where id = p_corrida;
    -- regra só desta rota: aplica o modo pedido
    if c.agendada_para is not null or p_modo = 'quadro' then
      update public.corridas set status = case when c.agendada_para is not null then 'agendada' else 'aguardando_motoboy' end::public.status_corrida,
             modo_despacho = 'quadro', quadro_desde = now(), sugerido_motoboy_id = privado.melhor_motoboy(p_corrida) where id = p_corrida;
      perform privado.avisar_quadro(p_corrida);
    else
      update public.corridas set status = 'aguardando_motoboy', modo_despacho = p_modo::public.modo_despacho, rodada = rodada + 1 where id = p_corrida;
      perform privado.despachar(p_corrida);
    end if;
    perform privado.evento(p_corrida, 'liberada', jsonb_build_object('modo', p_modo, 'pelo_gestor', true));
    return;
  end if;
  update public.corridas set status = 'montada' where id = p_corrida;
  perform privado.liberar_rota(p_corrida);
end;
$$;

-- O roteirizador: encaixa as entregas prontas em rotas abertas ou cria rotas novas.
create or replace function privado.roteirizar(p_teste boolean default false)
returns int language plpgsql security definer set search_path = '' as $$
declare
  t          record;
  r          record;
  v_rota     uuid;
  v_col      uuid;
  v_n        int := 0;
  v_tocadas  uuid[] := '{}';
  v_novas    uuid[] := '{}';
  v_id       uuid;
  v_janela   interval := make_interval(mins => privado.cfg_num('rota_janela_min', 30)::int);
  v_antes    interval := make_interval(mins => privado.cfg_num('rota_montar_antes_min', 1440)::int);
  v_espera   interval := make_interval(mins => privado.cfg_num('express_agrupar_espera_min', 0)::int);
  v_rc       double precision;
  v_re       double precision;
  v_maxe     int;
  v_maxc     int;
  v_maxkm    double precision;
  v_agrupar  boolean;
  v_perig_ex boolean := privado.cfg_bool('perigoso_rota_exclusiva', true);
  v_codigo   boolean := privado.cfg_bool('padrao_exige_codigo', false);
begin
  if not privado.cfg_bool('roteirizador_ligado', true) then return 0; end if;
  perform pg_advisory_xact_lock(hashtext('pwex_roteirizar_' || p_teste::text));

  for t in
    select e.id entrega_id, e.lat, e.lng, e.endereco, e.contato_nome, e.contato_telefone, e.instrucoes, e.referencias,
           p.id pedido_id, p.empresa_id, p.tipo, p.tipo_pedido, p.quando, p.urgente, p.observacoes,
           col.id coleta_id, col.lat clat, col.lng clng,
           exists (select 1 from public.pedido_itens i join public.categorias_produto k on k.id = i.categoria_id
                    where i.pedido_id = p.id and k.perigoso and (i.entrega_id = e.id or i.entrega_id is null)) perigoso
      from public.pedido_pontos e
      join public.pedidos p on p.id = e.pedido_id
      cross join lateral (
        select c.* from public.pedido_pontos c
         where c.pedido_id = p.id and c.tipo = 'coleta'
         order by (exists (select 1 from public.pedido_itens i where i.pedido_id = p.id and i.entrega_id = e.id and i.coleta_id = c.id)) desc, c.ordem
         limit 1) col
     where e.tipo = 'entrega' and e.status = 'pendente' and p.teste = p_teste
       and p.status in ('aprovado', 'roteirizado')
       and (p.cobranca <> 'pre_pago' or p.pagamento_status = 'pago')
       and not exists (select 1 from public.paradas x join public.corridas k on k.id = x.corrida_id
                        where x.pedido_ponto_id = e.id and k.status::text <> 'cancelada')
       and ((p.tipo = 'express' and coalesce(p.aprovado_em, p.criado_em) <= now() - v_espera)
            or (p.tipo = 'planejado' and p.quando - v_antes <= now()))
     order by coalesce(p.quando, p.aprovado_em, p.criado_em), p.numero, e.ordem
  loop
    v_rc := privado.pol_num('rota_raio_coleta_km', 2, t.empresa_id, null, t.tipo_pedido) * 1000;
    v_re := privado.pol_num('rota_raio_entrega_km', 3, t.empresa_id, null, t.tipo_pedido) * 1000;
    v_maxe := privado.pol_num('rota_max_entregas', 5, t.empresa_id, null, t.tipo_pedido)::int;
    v_maxc := privado.pol_num('rota_max_coletas', 3, t.empresa_id, null, t.tipo_pedido)::int;
    v_maxkm := privado.pol_num('rota_max_km', 0, t.empresa_id, null, t.tipo_pedido) * 1000;
    v_agrupar := privado.pol_bool('roteirizar_agrupar', true, t.empresa_id, null, t.tipo_pedido);
    v_rota := null; v_col := null;

    if v_agrupar then
      select k.id rota, cp.id coleta_parada, cp.mesmo into r
        from public.corridas k
        cross join lateral (select x.lat, x.lng from public.paradas x where x.corrida_id = k.id and x.tipo = 'coleta' order by x.ordem limit 1) c0
        cross join lateral (
          select x.id, (x.pedido_ponto_id = t.coleta_id) mesmo from public.paradas x
           where x.corrida_id = k.id and x.tipo = 'coleta'
             and (x.pedido_ponto_id = t.coleta_id or privado.dist_m(x.lat, x.lng, t.clat, t.clng) <= v_rc)
           order by (x.pedido_ponto_id = t.coleta_id) desc, privado.dist_m(x.lat, x.lng, t.clat, t.clng) limit 1) cp
        cross join lateral (
          select min(privado.dist_m(x.lat, x.lng, t.lat, t.lng)) d, count(*) n from public.paradas x where x.corrida_id = k.id and x.tipo = 'entrega') ent
        cross join lateral (select count(*) n from public.paradas x where x.corrida_id = k.id and x.tipo = 'coleta') ncol
       where k.origem = 'roteirizador' and k.teste = p_teste and k.motoboy_id is null
         and k.status::text in ('montada', 'agendada', 'aguardando_motoboy', 'sem_motoboy')
         and not exists (select 1 from public.ofertas o where o.corrida_id = k.id and o.status = 'pendente')
         and (k.agendada_para is null) = (t.tipo = 'express')
         and (case when t.tipo = 'express' then k.criada_em >= now() - v_janela
                   else abs(extract(epoch from (k.agendada_para - t.quando))) <= extract(epoch from v_janela) end)
         and ent.n < v_maxe
         and ent.d <= v_re
         and (cp.mesmo or ncol.n < v_maxc)
         and (v_maxkm <= 0 or privado.dist_m(c0.lat, c0.lng, t.lat, t.lng) <= v_maxkm)
         and (not v_perig_ex or k.tem_perigoso = t.perigoso)
         and (k.exclusiva_empresa is null or k.exclusiva_empresa = t.empresa_id)
         and (not privado.pol_bool('rota_exclusiva_cliente', false, t.empresa_id, null, t.tipo_pedido)
              or not exists (select 1 from public.paradas x join public.pedidos pp on pp.id = x.pedido_id
                              where x.corrida_id = k.id and pp.empresa_id is distinct from t.empresa_id))
         and coalesce(k.urgente, false) = coalesce(t.urgente, false)
       order by ent.d
       limit 1;
      if r.rota is not null then
        v_rota := r.rota;
        if r.mesmo then v_col := r.coleta_parada; end if;
      end if;
    end if;

    if v_rota is null then
      insert into public.corridas (
        status, origem, teste, empresa_id, tipo_pedido, agendada_para, urgente, modo_despacho, montada_em,
        exige_foto, exige_assinatura, exige_nome, exige_codigo, codigo_entrega, exigir_no_local, raio_chegada_m,
        aplicar_acrescimo, tem_perigoso, exclusiva_empresa, observacoes)
      values (
        'montada', 'roteirizador', p_teste, t.empresa_id, t.tipo_pedido, case when t.tipo = 'planejado' then t.quando end, coalesce(t.urgente, false),
        'quadro', now(),
        privado.cfg_bool('padrao_exige_foto', false), privado.cfg_bool('padrao_exige_assinatura', false), privado.cfg_bool('padrao_exige_nome', true),
        v_codigo, case when v_codigo then lpad((floor(random() * 10000))::int::text, 4, '0') end,
        privado.cfg_bool('exigir_no_local', true), privado.cfg_num('raio_chegada_m', 150)::int,
        false, t.perigoso,
        case when privado.pol_bool('rota_exclusiva_cliente', false, t.empresa_id, null, t.tipo_pedido) then t.empresa_id end,
        t.observacoes)
      returning id into v_rota;
      v_novas := v_novas || v_rota;
    end if;

    if v_col is null then
      insert into public.paradas (corrida_id, ordem, tipo, endereco, lat, lng, contato_nome, contato_telefone, instrucoes, referencias, pedido_id, pedido_ponto_id)
      select v_rota, 100000 + coalesce((select max(ordem) from public.paradas where corrida_id = v_rota), 0) + 1, 'coleta', c.endereco, c.lat, c.lng,
             c.contato_nome, c.contato_telefone, c.instrucoes, c.referencias, t.pedido_id, c.id
        from public.pedido_pontos c where c.id = t.coleta_id;
    end if;
    insert into public.paradas (corrida_id, ordem, tipo, endereco, lat, lng, contato_nome, contato_telefone, instrucoes, referencias, pedido_id, pedido_ponto_id)
    values (v_rota, 100000 + coalesce((select max(ordem) from public.paradas where corrida_id = v_rota), 0) + 1, 'entrega', t.endereco, t.lat, t.lng,
            t.contato_nome, t.contato_telefone, t.instrucoes, t.referencias, t.pedido_id, t.entrega_id);

    update public.pedidos set status = 'roteirizado' where id = t.pedido_id and status = 'aprovado';
    if not (v_rota = any (v_tocadas)) then v_tocadas := v_tocadas || v_rota; end if;
    v_n := v_n + 1;
  end loop;

  foreach v_id in array v_tocadas loop
    perform privado.ordenar_rota(v_id);
    perform privado.valores_rota(v_id);
    if not (v_id = any (v_novas)) then perform privado.evento(v_id, 'rota_atualizada', jsonb_build_object('entregas', (select count(*) from public.paradas where corrida_id = v_id and tipo = 'entrega'))); end if;
  end loop;
  foreach v_id in array v_novas loop
    perform privado.evento(v_id, 'rota_montada', jsonb_build_object('entregas', (select count(*) from public.paradas where corrida_id = v_id and tipo = 'entrega')));
    if not privado.pol_bool('rota_revisao_gestor', false, (select empresa_id from public.corridas where id = v_id), null,
                            (select tipo_pedido from public.corridas where id = v_id)) then
      perform privado.liberar_rota(v_id);
    end if;
  end loop;
  return v_n;
end;
$$;

-- Gestor roda o roteirizador na hora
create or replace function public.roteirizar_agora(p_teste boolean default null)
returns int language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  return privado.roteirizar(coalesce(p_teste, (select modo_teste from public.perfis where id = auth.uid()), false));
end;
$$;

-- Gestor move uma entrega (e o que ela precisa) para outra rota aberta, ou para uma rota nova
create or replace function public.mover_entrega(p_parada uuid, p_destino uuid default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  x       public.paradas%rowtype;
  o       public.corridas%rowtype;
  d       public.corridas%rowtype;
  v_col   public.paradas%rowtype;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select * into x from public.paradas where id = p_parada and tipo = 'entrega';
  if not found then raise exception 'parada_nao_encontrada' using errcode = '22023'; end if;
  select * into o from public.corridas where id = x.corrida_id for update;
  if o.status::text not in ('montada', 'agendada', 'aguardando_motoboy', 'sem_motoboy') or o.motoboy_id is not null then
    raise exception 'rota_ja_pegada' using errcode = '22023';
  end if;
  if p_destino is null then
    insert into public.corridas (status, origem, teste, empresa_id, tipo_pedido, agendada_para, urgente, modo_despacho, montada_em,
                                 exige_foto, exige_assinatura, exige_nome, exige_codigo, codigo_entrega, exigir_no_local, raio_chegada_m, aplicar_acrescimo, tem_perigoso)
    values ('montada', 'roteirizador', o.teste, o.empresa_id, o.tipo_pedido, o.agendada_para, o.urgente, 'quadro', now(),
            o.exige_foto, o.exige_assinatura, o.exige_nome, o.exige_codigo, o.codigo_entrega, o.exigir_no_local, o.raio_chegada_m, false, o.tem_perigoso)
    returning * into d;
  else
    select * into d from public.corridas where id = p_destino for update;
    if not found or d.status::text not in ('montada', 'agendada', 'aguardando_motoboy', 'sem_motoboy') or d.motoboy_id is not null or d.teste <> o.teste then
      raise exception 'rota_destino_invalida' using errcode = '22023';
    end if;
  end if;
  -- leva a coleta junto se o destino ainda não tem a coleta deste pedido
  select c.* into v_col from public.paradas c join public.pedido_itens i on i.coleta_id = c.pedido_ponto_id and i.entrega_id = x.pedido_ponto_id
   where c.corrida_id = o.id and c.tipo = 'coleta' limit 1;
  if v_col.id is null then select * into v_col from public.paradas where corrida_id = o.id and tipo = 'coleta' and pedido_id = x.pedido_id order by ordem limit 1; end if;
  if v_col.id is not null and not exists (select 1 from public.paradas where corrida_id = d.id and pedido_ponto_id = v_col.pedido_ponto_id) then
    insert into public.paradas (corrida_id, ordem, tipo, endereco, lat, lng, contato_nome, contato_telefone, instrucoes, referencias, pedido_id, pedido_ponto_id)
    values (d.id, 100000 + coalesce((select max(ordem) from public.paradas where corrida_id = d.id), 0) + 1, 'coleta', v_col.endereco, v_col.lat, v_col.lng,
            v_col.contato_nome, v_col.contato_telefone, v_col.instrucoes, v_col.referencias, v_col.pedido_id, v_col.pedido_ponto_id);
  end if;
  update public.paradas set corrida_id = d.id, ordem = 100000 + coalesce((select max(ordem) from public.paradas where corrida_id = d.id), 0) + 1 where id = x.id;
  -- coleta que ficou sem entrega do mesmo pedido sai da rota de origem
  delete from public.paradas c where c.corrida_id = o.id and c.tipo = 'coleta' and c.pedido_id is not null
     and not exists (select 1 from public.paradas e where e.corrida_id = o.id and e.tipo = 'entrega' and e.pedido_id = c.pedido_id);
  if not exists (select 1 from public.paradas where corrida_id = o.id and tipo = 'entrega') then
    update public.corridas set status = 'cancelada', cancelada_em = now() where id = o.id;
    perform privado.evento(o.id, 'cancelada', jsonb_build_object('motivo', 'entregas movidas'));
  else
    perform privado.ordenar_rota(o.id); perform privado.valores_rota(o.id);
  end if;
  perform privado.ordenar_rota(d.id); perform privado.valores_rota(d.id);
  perform privado.evento(d.id, 'entrega_movida', jsonb_build_object('parada', x.id, 'de', o.id));
  return d.id;
end;
$$;

-- Site aplica a ordem e as distâncias calculadas pelo mapa (OSRM)
create or replace function public.aplicar_otimizacao(p_corrida uuid, p_ordem uuid[], p_rua int[], p_acum int[], p_total int, p_duracao int, p_polyline text)
returns void language plpgsql security definer set search_path = '' as $$
declare i int;
begin
  if not (public.is_gestor() or privado.eh_servico()) then
    raise exception 'apenas_gestor' using errcode = '42501';
  end if;
  if exists (select 1 from public.paradas where corrida_id = p_corrida and status <> 'pendente') then return; end if;
  if (select count(*) from public.paradas where corrida_id = p_corrida) <> coalesce(array_length(p_ordem, 1), 0) then return; end if;
  if exists (select 1 from unnest(p_ordem) u where not exists (select 1 from public.paradas x where x.id = u and x.corrida_id = p_corrida)) then return; end if;
  update public.paradas set ordem = ordem + 100000 where corrida_id = p_corrida;
  for i in 1 .. array_length(p_ordem, 1) loop
    update public.paradas set ordem = i - 1,
           dist_rua_m = case when tipo = 'entrega' then p_rua[i] end, dist_acum_m = p_acum[i]
     where id = p_ordem[i];
  end loop;
  update public.corridas set distancia_planejada_m = p_total, duracao_planejada_s = p_duracao, rota_planejada = p_polyline, otimizada_em = now()
   where id = p_corrida;
  perform privado.valores_rota(p_corrida);
end;
$$;

-- ------------------------------------------------------------- despacho (quadro e melhor primeiro)
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
begin
  select * into c from public.corridas where id = p_corrida for update;
  if not found or c.status not in ('aguardando_motoboy', 'sem_motoboy') then return; end if;
  if exists (select 1 from public.ofertas where corrida_id = p_corrida and status = 'pendente') then return; end if;
  -- quadro: ninguém recebe oferta, todos veem e o primeiro pega
  if c.modo_despacho::text = 'quadro' then return; end if;
  -- melhor primeiro: já teve a vez dele → vai para o quadro
  if c.modo_despacho::text = 'melhor_primeiro' and exists (select 1 from public.ofertas where corrida_id = p_corrida) then
    update public.corridas set modo_despacho = 'quadro', status = 'aguardando_motoboy', quadro_desde = now() where id = p_corrida;
    perform privado.evento(p_corrida, 'foi_para_o_quadro');
    perform privado.avisar_quadro(p_corrida);
    return;
  end if;
  v_expira := now() + make_interval(secs => case when c.modo_despacho::text = 'melhor_primeiro'
                                                 then privado.pol_num('despacho_melhor_segundos', 45, c.empresa_id, null, c.tipo_pedido)
                                                 else privado.cfg_num('oferta_segundos', 30) end);

  select extensions.st_setsrid(extensions.st_makepoint(lng, lat), 4326)::extensions.geography
    into v_coleta from public.paradas where corrida_id = p_corrida order by ordem limit 1;

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
     where m.status = 'disponivel'
       and m.modo_teste = c.teste
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
     order by (f.ordem is null), f.ordem, extensions.st_distance(m.posicao, v_coleta)
     limit 1;
  end if;

  if v_motoboy is null then
    if c.modo_despacho::text = 'melhor_primeiro' then
      update public.corridas set modo_despacho = 'quadro', status = 'aguardando_motoboy', quadro_desde = now() where id = p_corrida;
      perform privado.evento(p_corrida, 'foi_para_o_quadro');
      perform privado.avisar_quadro(p_corrida);
      return;
    end if;
    update public.corridas set status = 'sem_motoboy' where id = p_corrida;
    perform privado.evento(p_corrida, 'sem_motoboy');
    return;
  end if;

  v_fc := case when c.aplicar_acrescimo then privado.fator_distancia(v_dist, 'coleta') else 0 end;
  insert into public.ofertas (corrida_id, motoboy_id, rodada, distancia_m, expira_em, fator_coleta, valor)
  values (p_corrida, v_motoboy, c.rodada, round(v_dist), v_expira, v_fc,
          privado.arredondar(coalesce(c.valor_base, c.valor, 0) * (1 + coalesce(c.fator_entrega, 0) + v_fc)))
  returning id into v_oferta;

  update public.corridas set status = 'aguardando_motoboy' where id = p_corrida;
  perform privado.evento(p_corrida, 'oferta_enviada', jsonb_build_object('motoboy_id', v_motoboy, 'distancia_m', round(v_dist)));
  perform privado.enviar_push(v_motoboy, jsonb_build_object(
    'tipo', 'oferta', 'oferta_id', v_oferta::text, 'corrida_id', p_corrida::text, 'teste', c.teste::text,
    'expira_em', to_char(v_expira at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  ));
end;
$$;

-- ------------------------------------------------------------- pagamento do motoboy
-- Regras (motoboy > tipo > global): pag_modo, pag_valor_km, pag_entrega_extra, pag_coleta_extra, pag_fixo_rota,
-- pag_minimo, pag_km_regra (mediana | percentil | media | mais_longe | mais_perto | total_rota), pag_km_percentil,
-- pag_distancia (rua = coleta→entrega direto | acumulada = km rodados na ordem da rota).
create or replace function privado.calcular_pagamento(p_corrida uuid, p_motoboy uuid default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  c       public.corridas%rowtype;
  v_m     uuid;
  v_modo  text; v_regra text; v_base text;
  v_vkm   numeric; v_vext numeric; v_vcol numeric; v_fixo numeric; v_min numeric; v_perc numeric;
  v_fator numeric := privado.cfg_num('fator_rua', 1.3);
  v_ds    numeric[];
  v_n     int; v_ncol int;
  v_ref   numeric;
  v_total numeric;
  v_pct   numeric;
  v_c0    record;
begin
  select * into c from public.corridas where id = p_corrida;
  if not found then return null; end if;
  v_m := coalesce(p_motoboy, c.motoboy_id);
  v_modo := privado.pol_txt('pag_modo', 'rota', null, v_m, c.tipo_pedido);
  if v_modo = 'percentual' then
    v_pct := coalesce(c.repasse_manual, (select e.repasse_pct from public.empresas e where e.id = c.empresa_id),
                      case when v_m is not null then privado.repasse_de(v_m) end, privado.cfg_num('repasse_motoboy_pct', 67.5));
    return jsonb_build_object('modo', 'percentual', 'pct', v_pct, 'valor_rota', coalesce(c.valor, 0),
                              'total', round(coalesce(c.valor, 0) * v_pct / 100, 2));
  end if;
  v_regra := privado.pol_txt('pag_km_regra', 'mediana', null, v_m, c.tipo_pedido);
  v_base  := privado.pol_txt('pag_distancia', 'rua', null, v_m, c.tipo_pedido);
  v_vkm   := privado.pol_num('pag_valor_km', 2, null, v_m, c.tipo_pedido);
  v_vext  := privado.pol_num('pag_entrega_extra', 10, null, v_m, c.tipo_pedido);
  v_vcol  := privado.pol_num('pag_coleta_extra', 0, null, v_m, c.tipo_pedido);
  v_fixo  := privado.pol_num('pag_fixo_rota', 0, null, v_m, c.tipo_pedido);
  v_min   := privado.pol_num('pag_minimo', 0, null, v_m, c.tipo_pedido);
  v_perc  := least(100, greatest(1, privado.pol_num('pag_km_percentil', 75, null, v_m, c.tipo_pedido)));

  select lat, lng into v_c0 from public.paradas where corrida_id = p_corrida and tipo = 'coleta' order by ordem limit 1;
  if v_c0.lat is null then select lat, lng into v_c0 from public.paradas where corrida_id = p_corrida order by ordem limit 1; end if;
  -- distância de cada entrega (do mapa; sem mapa ainda, linha reta × fator de rua)
  with ent as (
    select x.ordem, x.lat, x.lng, x.dist_rua_m, x.dist_acum_m,
           lag(x.lat) over (order by x.ordem) plat, lag(x.lng) over (order by x.ordem) plng
      from public.paradas x where x.corrida_id = p_corrida
  ), acum as (
    select e.*, sum(coalesce(privado.dist_m(e.plat, e.plng, e.lat, e.lng), 0)) over (order by e.ordem) * v_fator as acum_est
      from ent e
  )
  select array_agg(round(case when v_base = 'acumulada' then coalesce(a.dist_acum_m, a.acum_est)
                              else coalesce(a.dist_rua_m, privado.dist_m(v_c0.lat, v_c0.lng, a.lat, a.lng) * v_fator) end)::numeric
                   order by case when v_base = 'acumulada' then coalesce(a.dist_acum_m, a.acum_est)
                                 else coalesce(a.dist_rua_m, privado.dist_m(v_c0.lat, v_c0.lng, a.lat, a.lng) * v_fator) end)
    into v_ds
    from acum a join public.paradas x on x.corrida_id = p_corrida and x.ordem = a.ordem
   where x.tipo = 'entrega';
  v_n := coalesce(array_length(v_ds, 1), 0);
  select count(*) into v_ncol from public.paradas where corrida_id = p_corrida and tipo = 'coleta';

  v_ref := case
    when v_n = 0 then 0
    when v_regra = 'media' then (select avg(u) from unnest(v_ds) u)
    when v_regra = 'mais_longe' then v_ds[v_n]
    when v_regra = 'mais_perto' then v_ds[1]
    when v_regra = 'percentil' then v_ds[greatest(1, ceil(v_perc / 100.0 * v_n)::int)]
    when v_regra = 'total_rota' then coalesce(c.distancia_planejada_m, (select max(u) from unnest(v_ds) u))
    else v_ds[v_n / 2 + 1]   -- mediana: com número par de entregas, a de cima das duas do meio
  end;
  v_total := v_fixo + round(v_ref / 1000.0, 2) * v_vkm + greatest(v_n - 1, 0) * v_vext + greatest(v_ncol - 1, 0) * v_vcol;
  v_total := round(greatest(v_total, v_min), 2);
  return jsonb_build_object(
    'modo', 'rota', 'regra', v_regra, 'percentil', case when v_regra = 'percentil' then v_perc end, 'distancia', v_base,
    'distancias_km', (select coalesce(jsonb_agg(round(u / 1000.0, 2)), '[]') from unnest(v_ds) u),
    'km_referencia', round(v_ref / 1000.0, 2), 'valor_km', v_vkm, 'valor_km_total', round(round(v_ref / 1000.0, 2) * v_vkm, 2),
    'entregas', v_n, 'entregas_extras', greatest(v_n - 1, 0), 'valor_entrega_extra', v_vext,
    'coletas', v_ncol, 'coletas_extras', greatest(v_ncol - 1, 0), 'valor_coleta_extra', v_vcol,
    'fixo', v_fixo, 'minimo', v_min, 'total', v_total);
end;
$$;

-- Divisão: motoboy pelo cálculo da rota (+ ajuste do gestor); Dev % do faturamento; gestão = valor − Dev.
create or replace function privado.dividir_valor()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_calc jsonb; v_dev numeric; v_valor numeric;
begin
  if new.motoboy_id is not null and new.status::text in ('aceita', 'em_andamento', 'concluida') and (
       old.status is distinct from new.status or old.valor is distinct from new.valor or old.pag_ajuste is distinct from new.pag_ajuste
       or old.motoboy_id is distinct from new.motoboy_id or old.valor_motoboy is distinct from new.valor_motoboy
       or old.repasse_manual is distinct from new.repasse_manual or old.dev_manual is distinct from new.dev_manual) then
    v_calc := privado.calcular_pagamento(new.id, new.motoboy_id);
    if v_calc ->> 'modo' = 'percentual' then
      v_calc := jsonb_set(v_calc, '{total}', to_jsonb(round(coalesce(new.valor, 0) * (v_calc ->> 'pct')::numeric / 100, 2)));
      new.repasse_pct := (v_calc ->> 'pct')::numeric;
    end if;
    new.pag_calculo := v_calc;
    new.valor_motoboy := (v_calc ->> 'total')::numeric + coalesce(new.pag_ajuste, 0);
    v_dev := coalesce(new.dev_manual, (select e.dev_pct from public.empresas e where e.id = new.empresa_id),
                      privado.pol_num('dev_pct', 5, new.empresa_id, null, new.tipo_pedido));
    v_valor := coalesce(new.valor, 0);
    new.dev_pct := v_dev;
    new.valor_dev := round(v_valor * v_dev / 100, 2);
    new.valor_gestao := v_valor - new.valor_dev;
  end if;
  return new;
end;
$$;

-- ------------------------------------------------------------- quadro de rotas (app do motoboy)
create or replace function privado.ve_valores(p_motoboy uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.is_gestor() or privado.pol_bool('motoboy_ve_valores', false, null, p_motoboy, null);
$$;

-- Os dados da corrida para o app, sem valores quando o gestor não permite
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

create or replace function privado.corrida_json(p_corrida uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb := privado.corrida_json_completo(p_corrida);
begin
  if v is null then return null; end if;
  if privado.ve_valores(auth.uid()) then return v || jsonb_build_object('valores_visiveis', true); end if;
  return (v - 'valor_motoboy') || jsonb_build_object('valores_visiveis', false);
end;
$$;

create or replace function public.oferta_pendente()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare o public.ofertas%rowtype; v jsonb;
begin
  select * into o from public.ofertas where motoboy_id = auth.uid() and status = 'pendente' and expira_em > now() order by criada_em desc limit 1;
  if not found then return null; end if;
  v := privado.corrida_json(o.corrida_id);
  return jsonb_build_object('oferta_id', o.id, 'expira_em', o.expira_em,
    'segundos_restantes', greatest(0, extract(epoch from (o.expira_em - now())))::int, 'distancia_m', o.distancia_m, 'corrida', v);
end;
$$;

-- Rotas que o motoboy pode pegar agora: express no quadro e planejadas livres (mesmo peso)
create or replace function public.rotas_disponiveis()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  m  public.motoboys%rowtype;
begin
  if not public.tem_papel('motoboy'::public.papel_usuario) then raise exception 'apenas_motoboy' using errcode = '42501'; end if;
  select * into m from public.motoboys where id = auth.uid();
  return coalesce((
    select jsonb_agg(privado.corrida_json(c.id) || jsonb_build_object(
             'planejada', c.agendada_para is not null,
             'sugerida', c.sugerido_motoboy_id = auth.uid(),
             'distancia_ate_coleta_m', round(privado.dist_m(m.lat, m.lng, col.lat, col.lng)),
             'no_quadro_desde', c.quadro_desde)
           order by (c.sugerido_motoboy_id = auth.uid()) desc, c.urgente desc, coalesce(c.agendada_para, c.quadro_desde, c.criada_em))
      from public.corridas c
      join lateral (select lat, lng from public.paradas where corrida_id = c.id order by ordem limit 1) col on true
     where c.motoboy_id is null and c.teste = coalesce(m.modo_teste, false)
       and ((c.status::text in ('aguardando_motoboy', 'sem_motoboy') and c.modo_despacho::text = 'quadro')
            or (c.status::text = 'agendada' and c.agendada_para > now()))
       and (c.agendada_para is not null or c.urgente or coalesce(m.raio_km, 0) <= 0 or m.lat is null or privado.dist_m(
              case when m.raio_modo = 'fixo' and m.raio_lat is not null then m.raio_lat else m.lat end,
              case when m.raio_modo = 'fixo' and m.raio_lng is not null then m.raio_lng else m.lng end, col.lat, col.lng) <= m.raio_km * 1000)
  ), '[]'::jsonb);
end;
$$;

-- Pegar a rota do quadro (express: já sai aceita; planejada: fica reservada)
create or replace function public.pegar_rota(p_corrida uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c       public.corridas%rowtype;
  v_teste boolean := coalesce((select modo_teste from public.motoboys where id = auth.uid()), false);
begin
  if not public.tem_papel('motoboy'::public.papel_usuario) then raise exception 'apenas_motoboy' using errcode = '42501'; end if;
  select * into c from public.corridas where id = p_corrida for update;
  if not found or c.motoboy_id is not null then raise exception 'rota_ja_pegada' using errcode = '22023'; end if;
  if c.teste <> v_teste then raise exception 'modo_teste_diferente' using errcode = '22023'; end if;
  if c.status::text = 'agendada' then return public.reservar_corrida(p_corrida); end if;
  if not (c.status::text in ('aguardando_motoboy', 'sem_motoboy') and c.modo_despacho::text = 'quadro') then
    raise exception 'rota_ja_pegada' using errcode = '22023';
  end if;
  if exists (select 1 from public.corridas where motoboy_id = auth.uid() and status in ('aceita', 'em_andamento')) then
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

-- ------------------------------------------------------------- pedido acompanha a rota
create or replace function privado.sincronizar_pedido()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_table_name = 'corridas' then
    if new.status::text in ('aceita', 'em_andamento', 'reservada') and old.status is distinct from new.status then
      update public.pedidos set status = 'em_rota'
       where id in (select pedido_id from public.paradas where corrida_id = new.id and pedido_id is not null) and status in ('aprovado', 'roteirizado');
      update public.pedido_pontos set status = 'em_rota'
       where id in (select pedido_ponto_id from public.paradas where corrida_id = new.id and pedido_ponto_id is not null) and status = 'pendente';
    end if;
    return new;
  end if;
  -- paradas
  if new.pedido_ponto_id is not null and new.status = 'concluida' and old.status is distinct from new.status then
    update public.pedido_pontos set status = 'concluido', concluido_em = coalesce(concluido_em, new.concluida_em, now()),
           recebedor_nome = coalesce(new.recebedor_nome, recebedor_nome)
     where id = new.pedido_ponto_id and status <> 'concluido';
    update public.pedidos p set status = 'concluido', concluido_em = now()
     where p.id = new.pedido_id and p.status not in ('concluido', 'cancelado', 'recusado')
       and not exists (select 1 from public.pedido_pontos x where x.pedido_id = p.id and x.tipo = 'entrega' and x.status not in ('concluido', 'cancelado'));
  end if;
  return new;
end;
$$;
drop trigger if exists corridas_sincronizar_pedido on public.corridas;
create trigger corridas_sincronizar_pedido after update of status on public.corridas for each row execute function privado.sincronizar_pedido();
drop trigger if exists paradas_sincronizar_pedido on public.paradas;
create trigger paradas_sincronizar_pedido after update of status on public.paradas for each row execute function privado.sincronizar_pedido();

-- ------------------------------------------------------------- folha (holerite)
create table if not exists public.holerites (
  id          uuid primary key default gen_random_uuid(),
  motoboy_id  uuid not null references public.perfis (id) on delete cascade,
  teste       boolean not null default false,
  inicio      date not null,
  fim         date not null,
  status      text not null default 'aberto' check (status in ('aberto', 'fechado', 'pago')),
  rotas       int, entregas int, km numeric(10, 1),
  calculado   numeric(10, 2), ajustes numeric(10, 2), total numeric(10, 2),
  observacoes text,
  fechado_em  timestamptz, fechado_por uuid, pago_em timestamptz, pagamento_ref text,
  criado_em   timestamptz not null default now(),
  unique (motoboy_id, teste, inicio, fim)
);
create table if not exists public.holerite_ajustes (
  id          uuid primary key default gen_random_uuid(),
  holerite_id uuid not null references public.holerites (id) on delete cascade,
  descricao   text not null,
  valor       numeric(10, 2) not null,
  criado_por  uuid,
  criado_em   timestamptz not null default now()
);
alter table public.holerites enable row level security;
alter table public.holerite_ajustes enable row level security;
drop policy if exists holerites_leitura on public.holerites;
create policy holerites_leitura on public.holerites for select to authenticated using ((select public.is_gestor()));
drop policy if exists holerite_ajustes_leitura on public.holerite_ajustes;
create policy holerite_ajustes_leitura on public.holerite_ajustes for select to authenticated using ((select public.is_gestor()));
grant select on public.holerites, public.holerite_ajustes to authenticated;

-- Período de pagamento que contém a data (regra do motoboy > global)
create or replace function privado.periodo_holerite(p_motoboy uuid, p_data date)
returns table (inicio date, fim date) language plpgsql stable security definer set search_path = '' as $$
declare
  v_per text := privado.pol_txt('holerite_periodo', 'semanal', null, p_motoboy, null);
  v_ini int := least(7, greatest(1, privado.pol_num('holerite_inicio_semana', 1, null, p_motoboy, null)::int));
  v_i date;
begin
  if v_per = 'diario' then inicio := p_data; fim := p_data;
  elsif v_per = 'quinzenal' then
    if extract(day from p_data) <= 15 then inicio := date_trunc('month', p_data)::date; fim := inicio + 14;
    else inicio := date_trunc('month', p_data)::date + 15; fim := (date_trunc('month', p_data) + interval '1 month - 1 day')::date; end if;
  elsif v_per = 'mensal' then inicio := date_trunc('month', p_data)::date; fim := (date_trunc('month', p_data) + interval '1 month - 1 day')::date;
  else
    v_i := p_data - ((extract(isodow from p_data)::int - v_ini + 7) % 7);
    inicio := v_i; fim := v_i + 6;
  end if;
  return next;
end;
$$;

create or replace function privado.dia_local(p timestamptz)
returns date language sql immutable set search_path = '' as $$ select (p at time zone 'America/Sao_Paulo')::date $$;

-- Resumo da folha de todos os motoboys num intervalo
create or replace function public.folha(p_inicio date, p_fim date, p_teste boolean default false)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(x order by x ->> 'nome') from (
      select jsonb_build_object(
        'motoboy_id', pf.id, 'nome', pf.nome, 'foto_url', pf.foto_url,
        'rotas', count(c.id), 'entregas', coalesce(sum((c.pag_calculo ->> 'entregas')::int), 0),
        'km', round(coalesce(sum(coalesce(c.distancia_real_m, c.distancia_planejada_m, 0)), 0) / 1000.0, 1),
        'calculado', coalesce(sum((c.pag_calculo ->> 'total')::numeric), 0),
        'ajustes_rotas', coalesce(sum(c.pag_ajuste), 0),
        'ajustes', coalesce((select sum(a.valor) from public.holerites h join public.holerite_ajustes a on a.holerite_id = h.id
                              where h.motoboy_id = pf.id and h.teste = p_teste and h.inicio = p_inicio and h.fim = p_fim), 0),
        'faturado', coalesce(sum(c.valor), 0),
        'holerite', (select to_jsonb(h) from public.holerites h where h.motoboy_id = pf.id and h.teste = p_teste and h.inicio = p_inicio and h.fim = p_fim),
        'chave_pix', (select jsonb_build_object('tipo', k.tipo_chave, 'chave', k.chave, 'titular', k.titular) from public.chaves_pix k where k.usuario_id = pf.id and k.principal limit 1)
      ) x
      from public.perfis pf
      left join public.corridas c on c.motoboy_id = pf.id and c.status = 'concluida' and c.teste = p_teste
                                 and privado.dia_local(c.concluida_em) between p_inicio and p_fim
     where 'motoboy' = any (pf.papeis)
     group by pf.id
    ) t
  ), '[]'::jsonb);
end;
$$;

-- Holerite detalhado de um motoboy (gestor; o próprio motoboy usa meu_holerite)
create or replace function privado.holerite_json(p_motoboy uuid, p_inicio date, p_fim date, p_teste boolean, p_valores boolean)
returns jsonb language sql stable security definer set search_path = '' as $$
  with rotas as (
    select c.id, c.numero, c.concluida_em, c.valor, c.valor_motoboy, c.pag_calculo, c.pag_ajuste, c.pag_ajuste_motivo,
           coalesce(c.distancia_real_m, c.distancia_planejada_m, 0) metros,
           (select count(*) from public.paradas x where x.corrida_id = c.id and x.tipo = 'entrega') entregas,
           (select coalesce(string_agg(distinct coalesce(e.nome, pd.cliente_nome), ', '), coalesce(e2.nome, c.cliente_nome))
              from public.paradas x left join public.pedidos pd on pd.id = x.pedido_id left join public.empresas e on e.id = pd.empresa_id
             where x.corrida_id = c.id) clientes
      from public.corridas c left join public.empresas e2 on e2.id = c.empresa_id
     where c.motoboy_id = p_motoboy and c.status = 'concluida' and c.teste = p_teste
       and privado.dia_local(c.concluida_em) between p_inicio and p_fim
  ), h as (
    select * from public.holerites where motoboy_id = p_motoboy and teste = p_teste and inicio = p_inicio and fim = p_fim
  )
  select jsonb_build_object(
    'motoboy_id', p_motoboy, 'inicio', p_inicio, 'fim', p_fim, 'teste', p_teste,
    'status', coalesce((select status from h), 'aberto'),
    'fechado_em', (select fechado_em from h), 'pago_em', (select pago_em from h), 'observacoes', (select observacoes from h),
    'rotas', (select count(*) from rotas), 'entregas', (select coalesce(sum(entregas), 0) from rotas),
    'km', (select round(coalesce(sum(metros), 0) / 1000.0, 1) from rotas),
    'valores_visiveis', p_valores,
    'calculado', case when p_valores then (select coalesce(sum((pag_calculo ->> 'total')::numeric), 0) from rotas) end,
    'ajustes_rotas', case when p_valores then (select coalesce(sum(pag_ajuste), 0) from rotas) end,
    'ajustes', case when p_valores then coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'descricao', a.descricao, 'valor', a.valor, 'criado_em', a.criado_em) order by a.criado_em)
                                                   from public.holerite_ajustes a where a.holerite_id = (select id from h)), '[]') end,
    'total', case when p_valores then
      (select coalesce(sum(valor_motoboy), 0) from rotas)
      + coalesce((select sum(a.valor) from public.holerite_ajustes a where a.holerite_id = (select id from h)), 0) end,
    'itens', coalesce((select jsonb_agg(jsonb_build_object(
        'id', r.id, 'numero', r.numero, 'concluida_em', r.concluida_em, 'entregas', r.entregas, 'km', round(r.metros / 1000.0, 1),
        'clientes', r.clientes,
        'calculo', case when p_valores then r.pag_calculo end, 'ajuste', case when p_valores then r.pag_ajuste end,
        'ajuste_motivo', case when p_valores then r.pag_ajuste_motivo end, 'valor', case when p_valores then r.valor_motoboy end,
        'faturado', case when public.is_gestor() then r.valor end) order by r.concluida_em) from rotas r), '[]'));
$$;

create or replace function public.holerite(p_motoboy uuid, p_inicio date, p_fim date, p_teste boolean default false)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  return privado.holerite_json(p_motoboy, p_inicio, p_fim, p_teste, true);
end;
$$;

-- Motoboy: períodos (o atual e os anteriores) e o detalhe
create or replace function public.meus_holerites(p_quantos int default 12)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_teste boolean := coalesce((select modo_teste from public.motoboys where id = auth.uid()), false);
  v_ve    boolean := privado.ve_valores(auth.uid());
  v_veh   boolean := privado.pol_bool('motoboy_ve_holerite_valor', true, null, auth.uid(), null);
  v_d     date := privado.dia_local(now());
  v_out   jsonb := '[]';
  v_per   record;
  v_h     jsonb;
  k       int := 0;
begin
  if not public.tem_papel('motoboy'::public.papel_usuario) then raise exception 'apenas_motoboy' using errcode = '42501'; end if;
  while k < least(greatest(p_quantos, 1), 36) loop
    select * into v_per from privado.periodo_holerite(auth.uid(), v_d);
    v_h := privado.holerite_json(auth.uid(), v_per.inicio, v_per.fim, v_teste, true);
    v_out := v_out || jsonb_build_object('inicio', v_per.inicio, 'fim', v_per.fim, 'status', v_h ->> 'status',
      'rotas', v_h -> 'rotas', 'entregas', v_h -> 'entregas', 'km', v_h -> 'km', 'pago_em', v_h -> 'pago_em',
      'total', case when v_ve or (v_veh and v_h ->> 'status' in ('fechado', 'pago')) then v_h -> 'total' end);
    v_d := v_per.inicio - 1;
    k := k + 1;
  end loop;
  return jsonb_build_object('periodos', v_out, 'valores_visiveis', v_ve, 'teste', v_teste,
                            'periodo', privado.pol_txt('holerite_periodo', 'semanal', null, auth.uid(), null));
end;
$$;

create or replace function public.meu_holerite(p_inicio date, p_fim date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_teste boolean := coalesce((select modo_teste from public.motoboys where id = auth.uid()), false);
  v_ve    boolean := privado.ve_valores(auth.uid());
  v       jsonb;
begin
  if not public.tem_papel('motoboy'::public.papel_usuario) then raise exception 'apenas_motoboy' using errcode = '42501'; end if;
  v := privado.holerite_json(auth.uid(), p_inicio, p_fim, v_teste, v_ve);
  -- holerite fechado: mostra o total (se o gestor deixar), mesmo sem os valores de cada rota
  if not v_ve and v ->> 'status' in ('fechado', 'pago') and privado.pol_bool('motoboy_ve_holerite_valor', true, null, auth.uid(), null) then
    v := v || jsonb_build_object('total', (select total from public.holerites where motoboy_id = auth.uid() and teste = v_teste and inicio = p_inicio and fim = p_fim));
  end if;
  return v;
end;
$$;

create or replace function privado.holerite_aberto(p_motoboy uuid, p_inicio date, p_fim date, p_teste boolean)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_st text;
begin
  select id, status into v_id, v_st from public.holerites where motoboy_id = p_motoboy and teste = p_teste and inicio = p_inicio and fim = p_fim;
  if v_id is null then
    insert into public.holerites (motoboy_id, teste, inicio, fim) values (p_motoboy, p_teste, p_inicio, p_fim) returning id into v_id;
  elsif v_st <> 'aberto' then
    raise exception 'holerite_fechado' using errcode = '22023';
  end if;
  return v_id;
end;
$$;

-- Gestor infla ou reduz o pagamento de uma rota (com motivo)
create or replace function public.ajustar_pagamento_rota(p_corrida uuid, p_ajuste numeric, p_motivo text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c public.corridas%rowtype; v_per record;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select * into c from public.corridas where id = p_corrida for update;
  if not found or c.motoboy_id is null then raise exception 'rota_sem_motoboy' using errcode = '22023'; end if;
  if coalesce(p_ajuste, 0) <> 0 and coalesce(trim(p_motivo), '') = '' then raise exception 'informe_o_motivo' using errcode = '22023'; end if;
  if c.concluida_em is not null then
    select * into v_per from privado.periodo_holerite(c.motoboy_id, privado.dia_local(c.concluida_em));
    if exists (select 1 from public.holerites where motoboy_id = c.motoboy_id and teste = c.teste and inicio = v_per.inicio and fim = v_per.fim and status <> 'aberto') then
      raise exception 'holerite_fechado' using errcode = '22023';
    end if;
  end if;
  update public.corridas set pag_ajuste = round(coalesce(p_ajuste, 0), 2), pag_ajuste_motivo = nullif(trim(p_motivo), '') where id = p_corrida;
  perform privado.evento(p_corrida, 'pagamento_ajustado', jsonb_build_object('ajuste', p_ajuste, 'motivo', p_motivo));
  return (select jsonb_build_object('valor_motoboy', valor_motoboy, 'pag_calculo', pag_calculo, 'pag_ajuste', pag_ajuste) from public.corridas where id = p_corrida);
end;
$$;

-- Recalcula o pagamento de uma rota já concluída pelas regras de agora
create or replace function public.recalcular_pagamento_rota(p_corrida uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c public.corridas%rowtype; v jsonb;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select * into c from public.corridas where id = p_corrida for update;
  if not found or c.motoboy_id is null then raise exception 'rota_sem_motoboy' using errcode = '22023'; end if;
  v := privado.calcular_pagamento(p_corrida, c.motoboy_id);
  update public.corridas set pag_calculo = v, valor_motoboy = (v ->> 'total')::numeric + pag_ajuste where id = p_corrida;
  return v;
end;
$$;

create or replace function public.ajuste_holerite(p_motoboy uuid, p_inicio date, p_fim date, p_descricao text, p_valor numeric, p_teste boolean default false)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_h uuid; v_id uuid;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if coalesce(trim(p_descricao), '') = '' or coalesce(p_valor, 0) = 0 then raise exception 'ajuste_invalido' using errcode = '22023'; end if;
  v_h := privado.holerite_aberto(p_motoboy, p_inicio, p_fim, p_teste);
  insert into public.holerite_ajustes (holerite_id, descricao, valor, criado_por) values (v_h, left(trim(p_descricao), 200), round(p_valor, 2), auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.remover_ajuste_holerite(p_ajuste uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if exists (select 1 from public.holerite_ajustes a join public.holerites h on h.id = a.holerite_id where a.id = p_ajuste and h.status <> 'aberto') then
    raise exception 'holerite_fechado' using errcode = '22023';
  end if;
  delete from public.holerite_ajustes where id = p_ajuste;
end;
$$;

-- Fechar / reabrir / marcar pago
create or replace function public.situacao_holerite(p_motoboy uuid, p_inicio date, p_fim date, p_acao text, p_teste boolean default false, p_obs text default null, p_ref text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_h uuid; v jsonb;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select id into v_h from public.holerites where motoboy_id = p_motoboy and teste = p_teste and inicio = p_inicio and fim = p_fim;
  if v_h is null then insert into public.holerites (motoboy_id, teste, inicio, fim) values (p_motoboy, p_teste, p_inicio, p_fim) returning id into v_h; end if;
  if p_acao = 'fechar' then
    v := privado.holerite_json(p_motoboy, p_inicio, p_fim, p_teste, true);
    update public.holerites set status = 'fechado', fechado_em = now(), fechado_por = auth.uid(), observacoes = coalesce(nullif(trim(p_obs), ''), observacoes),
           rotas = (v ->> 'rotas')::int, entregas = (v ->> 'entregas')::int, km = (v ->> 'km')::numeric,
           calculado = (v ->> 'calculado')::numeric + (v ->> 'ajustes_rotas')::numeric,
           ajustes = (v ->> 'total')::numeric - (v ->> 'calculado')::numeric - (v ->> 'ajustes_rotas')::numeric,
           total = (v ->> 'total')::numeric
     where id = v_h and status = 'aberto';
    if not found then raise exception 'holerite_ja_fechado' using errcode = '22023'; end if;
  elsif p_acao = 'reabrir' then
    update public.holerites set status = 'aberto', fechado_em = null, pago_em = null where id = v_h;
  elsif p_acao = 'pago' then
    update public.holerites set status = 'pago', pago_em = now(), pagamento_ref = p_ref where id = v_h and status = 'fechado';
    if not found then raise exception 'feche_o_holerite_antes' using errcode = '22023'; end if;
  else
    raise exception 'acao_invalida' using errcode = '22023';
  end if;
  return (select to_jsonb(h) from public.holerites h where h.id = v_h);
end;
$$;

-- Resumo do motoboy no Início (valores só se o gestor permitir)
create or replace function public.meus_ganhos()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_teste boolean := coalesce((select modo_teste from public.motoboys where id = auth.uid()), false);
  v_ve    boolean := privado.ve_valores(auth.uid());
  v_per   record;
  v       jsonb;
begin
  select * into v_per from privado.periodo_holerite(auth.uid(), privado.dia_local(now()));
  with base as (
    select valor_motoboy, coalesce(distancia_real_m, distancia_planejada_m, 0) as metros,
           (select count(*) from public.paradas x where x.corrida_id = c.id and x.tipo = 'entrega') entregas,
           (concluida_em at time zone 'America/Sao_Paulo') as quando
      from public.corridas c
     where motoboy_id = auth.uid() and status = 'concluida' and c.teste = v_teste
  ), agora as (select (now() at time zone 'America/Sao_Paulo') as t)
  select jsonb_build_object(
    'valores_visiveis', v_ve,
    'hoje',   case when v_ve then coalesce(sum(valor_motoboy) filter (where quando >= date_trunc('day', t)), 0) end,
    'semana', case when v_ve then coalesce(sum(valor_motoboy) filter (where quando >= date_trunc('week', t)), 0) end,
    'mes',    case when v_ve then coalesce(sum(valor_motoboy) filter (where quando >= date_trunc('month', t)), 0) end,
    'total',  case when v_ve then coalesce(sum(valor_motoboy), 0) end,
    'periodo_total', case when v_ve then coalesce(sum(valor_motoboy) filter (where quando::date between v_per.inicio and v_per.fim), 0) end,
    'periodo_inicio', v_per.inicio, 'periodo_fim', v_per.fim,
    'corridas_hoje',   count(*) filter (where quando >= date_trunc('day', t)),
    'corridas_semana', count(*) filter (where quando >= date_trunc('week', t)),
    'corridas_mes',    count(*) filter (where quando >= date_trunc('month', t)),
    'corridas_periodo', count(*) filter (where quando::date between v_per.inicio and v_per.fim),
    'entregas_hoje',   coalesce(sum(entregas) filter (where quando >= date_trunc('day', t)), 0),
    'entregas_periodo', coalesce(sum(entregas) filter (where quando::date between v_per.inicio and v_per.fim), 0),
    'km_hoje', round(coalesce(sum(metros) filter (where quando >= date_trunc('day', t)), 0) / 1000.0, 1),
    'km_periodo', round(coalesce(sum(metros) filter (where quando::date between v_per.inicio and v_per.fim), 0) / 1000.0, 1),
    'km_mes',  round(coalesce(sum(metros) filter (where quando >= date_trunc('month', t)), 0) / 1000.0, 1),
    'teste', v_teste
  ) into v
  from base, agora;
  return v;
end;
$$;

create or replace function public.minhas_corridas(p_dias int default 120)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(x order by (x->>'quando') desc), '[]'::jsonb) from (
    select jsonb_build_object(
      'id', c.id, 'numero', c.numero, 'teste', c.teste, 'status', c.status,
      'valor_motoboy', case when c.status = 'concluida' and privado.ve_valores(auth.uid()) then c.valor_motoboy end,
      'distancia_m', coalesce(c.distancia_real_m, c.distancia_planejada_m),
      'aceita_em', c.aceita_em, 'concluida_em', c.concluida_em, 'cancelada_em', c.cancelada_em,
      'quando', coalesce(c.concluida_em, c.cancelada_em, c.aceita_em, c.criada_em),
      'planejada', c.agendada_para is not null,
      'entregas', (select count(*) from public.paradas p where p.corrida_id = c.id and p.tipo = 'entrega'),
      'empresa_nome', coalesce(e.nome, c.cliente_nome),
      'paradas', coalesce((select jsonb_agg(jsonb_build_object('tipo', p.tipo, 'endereco', p.endereco, 'status', p.status, 'concluida_em', p.concluida_em) order by p.ordem)
                            from public.paradas p where p.corrida_id = c.id), '[]'::jsonb)
    ) x
      from public.corridas c
      left join public.empresas e on e.id = c.empresa_id
     where c.motoboy_id = auth.uid()
       and c.status::text in ('concluida', 'cancelada')
       and c.teste = coalesce((select modo_teste from public.motoboys where id = auth.uid()), false)
       and coalesce(c.concluida_em, c.cancelada_em, c.criada_em) > now() - make_interval(days => greatest(1, least(p_dias, 400)))
     order by coalesce(c.concluida_em, c.cancelada_em, c.criada_em) desc
     limit 400
  ) t;
$$;

-- ------------------------------------------------------------- faturas (clientes no crédito)
create table if not exists public.faturas (
  id           uuid primary key default gen_random_uuid(),
  numero       bigint generated always as identity unique,
  empresa_id   uuid not null references public.empresas (id) on delete cascade,
  teste        boolean not null default false,
  inicio       date not null,
  fim          date not null,
  status       text not null default 'rascunho' check (status in ('rascunho', 'emitida', 'paga', 'cancelada')),
  subtotal     numeric(12, 2) not null default 0,
  ajuste       numeric(12, 2) not null default 0,
  ajuste_motivo text,
  total        numeric(12, 2) not null default 0,
  dev_pct      numeric(5, 2),
  valor_dev    numeric(12, 2),
  vencimento   date,
  emitida_em   timestamptz,
  paga_em      timestamptz,
  pagamento_metodo text,
  pagamento_ref text,
  observacoes  text,
  criado_por   uuid,
  criado_em    timestamptz not null default now()
);
do $$ begin
  alter table public.pedidos add constraint pedidos_fatura_fk foreign key (fatura_id) references public.faturas (id) on delete set null;
exception when duplicate_object then null; end $$;
alter table public.faturas enable row level security;
drop policy if exists faturas_leitura on public.faturas;
create policy faturas_leitura on public.faturas for select to authenticated
  using ((select public.is_gestor()) or (empresa_id = (select public.minha_empresa_id()) and status in ('emitida', 'paga')));
grant select on public.faturas to authenticated;

create or replace function privado.totalizar_fatura(p_fatura uuid)
returns void language sql security definer set search_path = '' as $$
  update public.faturas f set
    subtotal = coalesce((select sum(p.valor) from public.pedidos p where p.fatura_id = f.id), 0),
    total = coalesce((select sum(p.valor) from public.pedidos p where p.fatura_id = f.id), 0) + f.ajuste,
    valor_dev = round((coalesce((select sum(p.valor) from public.pedidos p where p.fatura_id = f.id), 0) + f.ajuste) * coalesce(f.dev_pct, 5) / 100, 2)
  where f.id = p_fatura;
$$;

-- Junta os pedidos concluídos e não faturados de um cliente no período
create or replace function privado.criar_fatura(p_cliente uuid, p_inicio date, p_fim date, p_teste boolean, p_rascunho boolean)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if not exists (select 1 from public.pedidos where empresa_id = p_cliente and teste = p_teste and cobranca = 'credito' and fatura_id is null
                  and status = 'concluido' and privado.dia_local(concluido_em) between p_inicio and p_fim) then
    return null;
  end if;
  insert into public.faturas (empresa_id, teste, inicio, fim, status, dev_pct, vencimento, emitida_em, criado_por)
  values (p_cliente, p_teste, p_inicio, p_fim, case when p_rascunho then 'rascunho' else 'emitida' end,
          coalesce((select dev_pct from public.empresas where id = p_cliente), privado.pol_num('dev_pct', 5, p_cliente)),
          p_fim + privado.pol_num('fatura_vencimento_dias', 3, p_cliente)::int, case when not p_rascunho then now() end, auth.uid())
  returning id into v_id;
  update public.pedidos set fatura_id = v_id
   where empresa_id = p_cliente and teste = p_teste and cobranca = 'credito' and fatura_id is null
     and status = 'concluido' and privado.dia_local(concluido_em) between p_inicio and p_fim;
  perform privado.totalizar_fatura(v_id);
  return v_id;
end;
$$;

create or replace function public.gerar_fatura(p_cliente uuid, p_inicio date, p_fim date, p_teste boolean default false)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  v_id := privado.criar_fatura(p_cliente, p_inicio, p_fim, p_teste, true);
  if v_id is null then raise exception 'nada_para_faturar' using errcode = '22023'; end if;
  return v_id;
end;
$$;

-- Gera sozinho as faturas dos ciclos que já fecharam (roda de hora em hora)
create or replace function privado.gerar_faturas_automaticas()
returns int language plpgsql security definer set search_path = '' as $$
declare
  e       record;
  v_ciclo text;
  v_hoje  date := privado.dia_local(now());
  v_ini   date; v_fim date;
  v_dia   int;
  v_n     int := 0;
  v_teste boolean;
begin
  for e in select id from public.empresas loop
    if privado.pol_txt('cobranca_modo', 'credito', e.id) <> 'credito' then continue; end if;
    v_ciclo := privado.pol_txt('fatura_ciclo', 'semanal', e.id);
    if v_ciclo = 'manual' then continue; end if;
    if v_ciclo = 'diario' then v_fim := v_hoje - 1; v_ini := v_fim;
    elsif v_ciclo = 'semanal' then
      v_dia := least(6, greatest(0, privado.pol_num('fatura_dia_semana', 6, e.id)::int));
      v_fim := v_hoje - ((extract(dow from v_hoje)::int - v_dia + 7) % 7);
      if v_fim >= v_hoje then v_fim := v_fim - 7; end if;
      v_ini := v_fim - 6;
    elsif v_ciclo = 'quinzenal' then
      if extract(day from v_hoje) > 15 then v_ini := date_trunc('month', v_hoje)::date; v_fim := v_ini + 14;
      else v_ini := (date_trunc('month', v_hoje) - interval '1 month')::date + 15; v_fim := (date_trunc('month', v_hoje) - interval '1 day')::date; end if;
    else
      v_ini := (date_trunc('month', v_hoje) - interval '1 month')::date; v_fim := (date_trunc('month', v_hoje) - interval '1 day')::date;
    end if;
    foreach v_teste in array array[false, true] loop
      -- pega também pedidos de períodos anteriores que ficaram para trás
      if privado.criar_fatura(e.id, date '2000-01-01', v_fim, v_teste, privado.pol_bool('fatura_revisao', true, e.id)) is not null then
        update public.faturas set inicio = greatest(inicio, least(v_ini, (select min(privado.dia_local(concluido_em)) from public.pedidos p where p.fatura_id = faturas.id)))
         where empresa_id = e.id and teste = v_teste and fim = v_fim and inicio = date '2000-01-01';
        v_n := v_n + 1;
      end if;
    end loop;
  end loop;
  return v_n;
end;
$$;

create or replace function public.editar_fatura(p_fatura uuid, p_acao text, p_ajuste numeric default null, p_motivo text default null,
                                                p_vencimento date default null, p_metodo text default null, p_pedido uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare f public.faturas%rowtype;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select * into f from public.faturas where id = p_fatura for update;
  if not found then raise exception 'fatura_nao_encontrada' using errcode = '22023'; end if;
  if p_acao = 'ajustar' then
    if f.status not in ('rascunho', 'emitida') then raise exception 'fatura_fechada' using errcode = '22023'; end if;
    if coalesce(p_ajuste, 0) <> 0 and coalesce(trim(p_motivo), '') = '' then raise exception 'informe_o_motivo' using errcode = '22023'; end if;
    update public.faturas set ajuste = round(coalesce(p_ajuste, 0), 2), ajuste_motivo = nullif(trim(p_motivo), ''),
           vencimento = coalesce(p_vencimento, vencimento) where id = f.id;
    perform privado.totalizar_fatura(f.id);
  elsif p_acao = 'tirar_pedido' then
    if f.status <> 'rascunho' then raise exception 'so_no_rascunho' using errcode = '22023'; end if;
    update public.pedidos set fatura_id = null where id = p_pedido and fatura_id = f.id;
    perform privado.totalizar_fatura(f.id);
  elsif p_acao = 'emitir' then
    if f.status <> 'rascunho' then raise exception 'so_no_rascunho' using errcode = '22023'; end if;
    update public.faturas set status = 'emitida', emitida_em = now(), vencimento = coalesce(p_vencimento, vencimento) where id = f.id;
  elsif p_acao = 'paga' then
    if f.status <> 'emitida' then raise exception 'emita_antes' using errcode = '22023'; end if;
    update public.faturas set status = 'paga', paga_em = now(), pagamento_metodo = p_metodo where id = f.id;
    update public.pedidos set pagamento_status = 'pago', pago_em = now(), pagamento_metodo = coalesce(p_metodo, pagamento_metodo) where fatura_id = f.id;
  elsif p_acao = 'cancelar' then
    if f.status = 'paga' then raise exception 'fatura_paga' using errcode = '22023'; end if;
    update public.pedidos set fatura_id = null where fatura_id = f.id;
    update public.faturas set status = 'cancelada' where id = f.id;
  else
    raise exception 'acao_invalida' using errcode = '22023';
  end if;
  return (select to_jsonb(x) from public.faturas x where x.id = f.id);
end;
$$;

-- ------------------------------------------------------------- lado do cliente
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
                                                               'classe_risco', k.classe_risco, 'fragil', k.fragil) order by k.ordem), '[]')
                     from public.categorias_produto k where k.ativa),
    'em_aberto', (select coalesce(sum(valor), 0) from public.pedidos where empresa_id = v_cli and not teste and cobranca = 'credito' and fatura_id is null and status = 'concluido'));
end;
$$;

create or replace function public.meus_pedidos_cliente(p_dias int default 120)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(x order by (x ->> 'criado_em') desc), '[]'::jsonb) from (
    select jsonb_build_object(
      'id', p.id, 'numero', p.numero, 'tipo', p.tipo, 'tipo_pedido', p.tipo_pedido, 'quando', p.quando, 'urgente', p.urgente,
      'status', p.status, 'valor', p.valor, 'orcamento', p.orcamento, 'cobranca', p.cobranca, 'pagamento_status', p.pagamento_status,
      'pagamento_metodo', p.pagamento_metodo, 'fatura_id', p.fatura_id, 'observacoes', p.observacoes, 'recusa_motivo', p.recusa_motivo,
      'criado_em', p.criado_em, 'concluido_em', p.concluido_em, 'cancelado_em', p.cancelado_em,
      'pontos', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'tipo', x.tipo, 'endereco', x.endereco, 'lat', x.lat, 'lng', x.lng,
                                 'contato_nome', x.contato_nome, 'status', x.status, 'concluido_em', x.concluido_em, 'recebedor_nome', x.recebedor_nome) order by x.ordem)
                          from public.pedido_pontos x where x.pedido_id = p.id), '[]'),
      'itens', coalesce((select jsonb_agg(jsonb_build_object('descricao', i.descricao, 'quantidade', i.quantidade, 'peso_kg', i.peso_kg,
                                'categoria', k.nome, 'perigoso', coalesce(k.perigoso, false)))
                         from public.pedido_itens i left join public.categorias_produto k on k.id = i.categoria_id where i.pedido_id = p.id), '[]'),
      'motoboys', (select coalesce(jsonb_agg(distinct pf.nome), '[]') from public.paradas pa join public.corridas c on c.id = pa.corrida_id
                     join public.perfis pf on pf.id = c.motoboy_id where pa.pedido_id = p.id and c.status::text <> 'cancelada'),
      'codigos', (select coalesce(jsonb_agg(distinct c.codigo_entrega) filter (where c.codigo_entrega is not null), '[]') from public.paradas pa
                    join public.corridas c on c.id = pa.corrida_id where pa.pedido_id = p.id and c.exige_codigo and c.status::text not in ('cancelada', 'concluida'))
    ) x
      from public.pedidos p
     where p.empresa_id = privado.minha_empresa() and not p.teste
       and p.criado_em > now() - make_interval(days => greatest(1, least(p_dias, 400)))
     limit 500
  ) t;
$$;

-- Onde estão os motoboys do pedido (só se o cliente vê ao vivo)
create or replace function public.acompanhar_pedido_cliente(p_pedido uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('lat', m.lat, 'lng', m.lng, 'posicao_em', m.posicao_em, 'nome', split_part(pf.nome, ' ', 1),
                                               'status', c.status, 'rota_planejada', c.rota_planejada)), '[]')
    from (select distinct pa.corrida_id from public.paradas pa where pa.pedido_id = p_pedido) r
    join public.corridas c on c.id = r.corrida_id and c.status::text in ('aceita', 'em_andamento')
    join public.pedidos p on p.id = p_pedido and p.empresa_id = privado.minha_empresa()
    join public.empresas e on e.id = p.empresa_id and e.cliente_ve_ao_vivo
    join public.motoboys m on m.id = c.motoboy_id
    join public.perfis pf on pf.id = m.id;
$$;

create or replace function public.minhas_faturas()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', f.id, 'numero', f.numero, 'inicio', f.inicio, 'fim', f.fim, 'status', f.status, 'subtotal', f.subtotal, 'ajuste', f.ajuste,
      'ajuste_motivo', f.ajuste_motivo, 'total', f.total, 'vencimento', f.vencimento, 'emitida_em', f.emitida_em, 'paga_em', f.paga_em,
      'pedidos', (select coalesce(jsonb_agg(jsonb_build_object('numero', p.numero, 'concluido_em', p.concluido_em, 'valor', p.valor,
                     'entregas', (select count(*) from public.pedido_pontos x where x.pedido_id = p.id and x.tipo = 'entrega')) order by p.concluido_em), '[]')
                    from public.pedidos p where p.fatura_id = f.id)) order by f.fim desc), '[]')
    from public.faturas f
   where f.empresa_id = privado.minha_empresa() and not f.teste and f.status in ('emitida', 'paga');
$$;

-- ------------------------------------------------------------- otimização pelo mapa (site)
create or replace function privado.pedir_otimizacao()
returns void language plpgsql security definer set search_path = '' as $$
declare v_url text; v_secret text;
begin
  if not exists (select 1 from public.corridas where origem = 'roteirizador' and otimizada_em is null
                  and status::text in ('montada', 'agendada', 'aguardando_motoboy', 'sem_motoboy', 'reservada')) then return; end if;
  select replace(valor, '/api/push', '/api/rotas/otimizar') into v_url from privado.config where chave = 'push_url';
  select valor into v_secret from privado.config where chave = 'push_secret';
  if v_url is null or v_secret is null then return; end if;
  perform net.http_post(url := v_url, body := '{}'::jsonb,
                        headers := jsonb_build_object('Content-Type', 'application/json', 'x-pwex-secret', v_secret), timeout_milliseconds := 20000);
exception when others then
  raise warning 'pedir_otimizacao falhou: %', sqlerrm;
end;
$$;

create or replace function privado.ciclo_rotas()
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform privado.roteirizar(false);
  perform privado.roteirizar(true);
  perform privado.pedir_otimizacao();
end;
$$;

do $$ begin
  perform cron.unschedule('pwex-rotas');
exception when others then null; end $$;
select cron.schedule('pwex-rotas', '* * * * *', 'select privado.ciclo_rotas()');
do $$ begin
  perform cron.unschedule('pwex-faturas');
exception when others then null; end $$;
select cron.schedule('pwex-faturas', '7 * * * *', 'select privado.gerar_faturas_automaticas()');

-- ------------------------------------------------------------- permissões
revoke all on all functions in schema privado from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array[
    'public.definir_politica(text, text, text, jsonb)', 'public.orcar_previa(jsonb)', 'public.minha_empresa_id()',
    'public.criar_pedido(jsonb)', 'public.revisar_pedido(uuid, text, numeric, text)', 'public.cancelar_pedido(uuid, text)',
    'public.confirmar_pagamento_pedido(uuid, text, text)', 'public.liberar_rota(uuid, text, uuid)', 'public.roteirizar_agora(boolean)',
    'public.mover_entrega(uuid, uuid)', 'public.aplicar_otimizacao(uuid, uuid[], int[], int[], int, int, text)',
    'public.oferta_pendente()', 'public.rotas_disponiveis()', 'public.pegar_rota(uuid)',
    'public.folha(date, date, boolean)', 'public.holerite(uuid, date, date, boolean)', 'public.meus_holerites(int)', 'public.meu_holerite(date, date)',
    'public.ajustar_pagamento_rota(uuid, numeric, text)', 'public.recalcular_pagamento_rota(uuid)',
    'public.ajuste_holerite(uuid, date, date, text, numeric, boolean)', 'public.remover_ajuste_holerite(uuid)',
    'public.situacao_holerite(uuid, date, date, text, boolean, text, text)', 'public.meus_ganhos()', 'public.minhas_corridas(int)',
    'public.gerar_fatura(uuid, date, date, boolean)', 'public.editar_fatura(uuid, text, numeric, text, date, text, uuid)',
    'public.minha_conta_cliente()', 'public.meus_pedidos_cliente(int)', 'public.acompanhar_pedido_cliente(uuid)', 'public.minhas_faturas()'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
do $$ begin
  execute 'grant execute on function public.aplicar_otimizacao(uuid, uuid[], int[], int[], int, int, text) to service_role';
  execute 'grant execute on function public.confirmar_pagamento_pedido(uuid, text, text) to service_role';
exception when undefined_object then null; end $$;

-- ------------------------------------------------------------- tempo real (painéis atualizam sozinhos)
do $$
declare t text;
begin
  foreach t in array array['pedidos', 'pedido_pontos', 'faturas', 'holerites', 'politicas', 'zonas', 'faixas_horario', 'categorias_produto'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object or undefined_object then null;
    end;
  end loop;
end $$;
