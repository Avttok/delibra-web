-- =====================================================================
-- PW Express · Preço pela soma coleta→entrega, orçamento editável e
-- pagamento do motoboy por zonas de entrega
-- ---------------------------------------------------------------------
--  • Orçamento (padrão novo "soma das entregas"): cada entrega custa
--    valor/km × distância da coleta até ela; o pedido é a soma. O modo
--    antigo (km da rota inteira) continua como opção, no geral, por tipo
--    e por cliente (preco_distancia_modo).
--  • "Como chegou no valor" editável: o gestor muda quantidade, valor
--    unitário e valor final de cada linha, os percentuais e o mínimo.
--  • Pagamento do motoboy (padrão novo "por zonas"): cada entrega tem um
--    raio; se os raios das entregas se encostam (entregas juntas) paga o
--    km da entrega de referência (padrão: a mais próxima) + fixo por
--    entrega a mais; se há entrega isolada, paga a porcentagem da rota
--    (padrão 65% motoboy; gestor 30%; Dev 5%). Tudo ajustável no geral,
--    por tipo, cliente e motoboy. Os modelos antigos continuam.
-- Rode depois de 20261110000013. Seguro rodar de novo.
-- =====================================================================

alter table public.pedido_pontos add column if not exists dist_coleta_m integer;

insert into public.configuracoes (chave, valor) values
  ('preco_distancia_modo', '"soma_entregas"'), ('soma_inclui_saida', 'false'), ('soma_inclui_entrega_extra', 'false'),
  ('zona_entrega_raio_m', '1500'), ('zona_regra', '"todas"'), ('zona_fora_pct', '65'),
  ('zona_km_regra', '"mais_perto"'), ('zona_valor_km', '2'), ('zona_entrega_extra', '10'), ('zona_coleta_extra', '0'),
  ('zona_fixo_rota', '0'), ('zona_minimo', '0')
on conflict (chave) do nothing;
-- os dois padrões novos
insert into public.configuracoes (chave, valor) values ('pag_modo', '"zonas"') on conflict (chave) do update set valor = excluded.valor;
insert into public.configuracoes (chave, valor) values ('dev_origem', '"gestor"') on conflict (chave) do nothing;


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
  v_dist := coalesce(nullif(d ->> 'distancia_m', '')::numeric,
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
        v_d := coalesce(nullif(v_pt ->> 'dist_coleta_m', '')::numeric,
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
   where z.ativa and (z.cliente_id = v_cli
          or (z.cliente_id is null and not (privado.pol_bool('zona_cliente_exclusiva', false, v_cli, null, v_tp)
                                            and exists (select 1 from public.zonas zz where zz.ativa and zz.cliente_id = v_cli))))
     and exists (select 1 from jsonb_array_elements(coalesce(d -> 'pontos', '[]')) x
                  where privado.dist_m(z.lat, z.lng, (x ->> 'lat')::double precision, (x ->> 'lng')::double precision) <= z.raio_m);
  if v_za <> 0 then v_linhas := v_linhas || jsonb_build_object('rotulo', 'Zona', 'detalhe', array_to_string(v_znomes, ', '), 'fixo', true, 'valor', v_za); v_fixos := v_fixos + v_za; end if;
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
  if coalesce(v_ha, 0) <> 0 then v_linhas := v_linhas || jsonb_build_object('rotulo', v_hnome, 'fixo', true, 'valor', v_ha); v_fixos := v_fixos + v_ha; end if;
  if coalesce(v_hp, 0) <> 0 then v_pcts := v_pcts || jsonb_build_object('rotulo', v_hnome, 'pct', v_hp); v_pct := v_pct + v_hp; end if;

  v_total := v_sub * (1 + v_pct / 100.0) + v_fixos;
  v_min := privado.pol_num('valor_minimo', 0, v_cli, null, v_tp);
  v_total := privado.arredondar(greatest(v_total, v_min));
  perform set_config('pwex.regras', coalesce(v_guc, ''), true);
  return jsonb_build_object(
    'linhas', v_linhas, 'percentuais', v_pcts, 'subtotal', round(v_sub + v_fixos, 2), 'acrescimo_pct', v_pct,
    'minimo', v_min, 'total', v_total, 'modo_distancia', case when v_fixo_cliente then 'fixo' when v_soma then 'soma_entregas' else 'rota' end, 'km', v_km, 'distancia_m', round(v_dist),
    'coletas', v_ncol, 'entregas', v_nent, 'volumes', v_pac, 'peso_real_kg', round(v_real, 2), 'peso_cubado_kg', round(v_cub, 2),
    'peso_taxado_kg', v_tax, 'perigoso', v_perig, 'calculado_em', now());
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
  if p_acao = 'voltar_revisao' then
    if p.status not in ('aprovado', 'roteirizado', 'em_rota') then raise exception 'pedido_nao_pode_voltar' using errcode = '22023'; end if;
    if exists (select 1 from public.pedido_pontos x where x.pedido_id = p.id and x.status not in ('pendente', 'em_rota'))
       or exists (select 1 from public.paradas x where x.pedido_id = p.id and x.status::text in ('chegou', 'concluida'))
       or exists (select 1 from public.paradas x join public.corridas c on c.id = x.corrida_id
                   where x.pedido_id = p.id and (c.status::text = 'em_andamento'
                         or (c.status::text = 'aceita' and not privado.cfg_bool('voltar_revisao_aceitas', true)))) then
      raise exception 'pedido_em_andamento' using errcode = '22023';
    end if;
    perform privado.tirar_pedido_das_rotas(p.id, true);
    update public.pedidos set status = 'recebido', aprovado_em = null, revisado_por = null, revisado_em = null where id = p.id;
    update public.pedido_pontos set status = 'pendente' where pedido_id = p.id;
    perform privado.evento_pedido(p.id, 'voltou_revisao', jsonb_build_object('motivo', p_motivo));
    return (select to_jsonb(x) from public.pedidos x where x.id = p.id);
  end if;
  if p.status in ('concluido', 'cancelado', 'recusado') and p_acao <> 'ajustar' then raise exception 'pedido_finalizado' using errcode = '22023'; end if;
  if p.fatura_id is not null and exists (select 1 from public.faturas f where f.id = p.fatura_id and f.status <> 'rascunho') then
    raise exception 'pedido_ja_faturado' using errcode = '22023';
  end if;

  if p_acao = 'recalcular' then
    select privado.orcar(jsonb_build_object('pedido_id', p.id, 'empresa_id', p.empresa_id, 'tipo', p.tipo, 'tipo_pedido', p.tipo_pedido, 'quando', p.quando, 'urgente', p.urgente,
             'distancia_m', p.distancia_estimada_m,
             'pontos', (select jsonb_agg(jsonb_build_object('tipo', x.tipo, 'lat', x.lat, 'lng', x.lng, 'dist_coleta_m', x.dist_coleta_m) order by x.ordem) from public.pedido_pontos x where x.pedido_id = p.id),
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


-- ------------------------------------------------------------- "como chegou no valor" editável
-- p_linhas = [{ rotulo, detalhe?, qtd?, unit?, unidade?, valor?, fixo? }]: com qtd e unit, o valor é qtd × unit (a não ser que venha "valor").
-- p_percentuais = [{ rotulo, pct }]. Total = (linhas normais) × (1 + soma dos %) + linhas fixas, nunca abaixo do mínimo.
create or replace function public.editar_orcamento(p_pedido uuid, p_linhas jsonb, p_percentuais jsonb default '[]', p_minimo numeric default null, p_motivo text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  p        public.pedidos%rowtype;
  l        jsonb;
  v_linhas jsonb := '[]';
  v_pcts   jsonb := '[]';
  v_sub    numeric := 0; v_fixos numeric := 0; v_pct numeric := 0;
  v_val    numeric; v_min numeric; v_total numeric;
  v_orc    jsonb;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select * into p from public.pedidos where id = p_pedido for update;
  if not found then raise exception 'pedido_nao_encontrado' using errcode = '22023'; end if;
  if p.fatura_id is not null and exists (select 1 from public.faturas f where f.id = p.fatura_id and f.status <> 'rascunho') then
    raise exception 'pedido_ja_faturado' using errcode = '22023';
  end if;
  if p_linhas is null or jsonb_typeof(p_linhas) <> 'array' or jsonb_array_length(p_linhas) > 80 then raise exception 'orcamento_invalido' using errcode = '22023'; end if;
  for l in select * from jsonb_array_elements(p_linhas) loop
    if coalesce(trim(l ->> 'rotulo'), '') = '' then continue; end if;
    v_val := round(coalesce(nullif(l ->> 'valor', '')::numeric, nullif(l ->> 'qtd', '')::numeric * nullif(l ->> 'unit', '')::numeric, 0), 2);
    v_linhas := v_linhas || (jsonb_strip_nulls(jsonb_build_object('chave', l ->> 'chave', 'rotulo', left(l ->> 'rotulo', 80), 'qtd', nullif(l ->> 'qtd', '')::numeric,
                  'unit', nullif(l ->> 'unit', '')::numeric, 'unidade', l ->> 'unidade', 'fixo', nullif((l ->> 'fixo')::boolean, false),
                  'detalhe', case when nullif(l ->> 'qtd', '') is not null and nullif(l ->> 'unit', '') is not null
                                  then format('%s %s × R$ %s', l ->> 'qtd', coalesce(l ->> 'unidade', ''), l ->> 'unit') else nullif(left(l ->> 'detalhe', 160), '') end))
                || jsonb_build_object('valor', v_val));
    if coalesce((l ->> 'fixo')::boolean, false) then v_fixos := v_fixos + v_val; else v_sub := v_sub + v_val; end if;
  end loop;
  for l in select * from jsonb_array_elements(coalesce(p_percentuais, '[]')) loop
    if coalesce(trim(l ->> 'rotulo'), '') = '' or coalesce(nullif(l ->> 'pct', '')::numeric, 0) = 0 then continue; end if;
    v_pcts := v_pcts || jsonb_build_object('rotulo', left(l ->> 'rotulo', 80), 'pct', (l ->> 'pct')::numeric);
    v_pct := v_pct + (l ->> 'pct')::numeric;
  end loop;
  v_min := greatest(coalesce(p_minimo, (p.orcamento ->> 'minimo')::numeric, 0), 0);
  v_total := privado.arredondar(greatest(v_sub * (1 + v_pct / 100.0) + v_fixos, v_min, 0));
  v_orc := coalesce(p.orcamento, '{}') || jsonb_build_object(
    'linhas', v_linhas, 'percentuais', v_pcts, 'subtotal', round(v_sub + v_fixos, 2), 'acrescimo_pct', v_pct, 'minimo', v_min, 'total', v_total,
    'editado', true, 'editado_em', now(), 'editado_por', auth.uid(), 'motivo', nullif(trim(p_motivo), ''),
    'original', coalesce(p.orcamento -> 'original', p.orcamento - 'original'));
  update public.pedidos set orcamento = v_orc, valor_calculado = v_total, valor = v_total, valor_ajuste = 0,
         ajuste_motivo = coalesce(nullif(trim(p_motivo), ''), ajuste_motivo), valor_dev = round(v_total * dev_pct / 100, 2)
   where id = p.id;
  perform privado.valores_rota(x.corrida_id) from (select distinct corrida_id from public.paradas where pedido_id = p.id) x;
  perform privado.evento_pedido(p.id, 'orcamento_editado', jsonb_build_object('de', p.valor, 'para', v_total, 'motivo', p_motivo));
  return (select to_jsonb(x) from public.pedidos x where x.id = p.id);
end;
$$;
revoke all on function public.editar_orcamento(uuid, jsonb, jsonb, numeric, text) from public, anon;
grant execute on function public.editar_orcamento(uuid, jsonb, jsonb, numeric, text) to authenticated;


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
  v_dev   numeric;
  v_teto  numeric;
  v_orig  text;
  v_raio  numeric; v_zregra text; v_nent int; v_juntas int; v_agrup boolean; v_zona jsonb; v_pz boolean := false;
begin
  select * into c from public.corridas where id = p_corrida;
  if not found then return null; end if;
  v_m := coalesce(p_motoboy, c.motoboy_id);
  -- teto: o motoboy nunca leva mais que a rota paga (tirando a parte do Dev)
  v_dev := privado.dev_da_corrida(c);
  v_teto := greatest(round(coalesce(c.valor, 0) - coalesce(c.valor, 0) * v_dev / 100, 2), 0);
  v_orig := privado.pol_txt('dev_origem', 'gestor', c.empresa_id, null, c.tipo_pedido);
  v_modo := privado.pol_txt('pag_modo', 'zonas', c.empresa_id, v_m, c.tipo_pedido);
  if v_modo = 'zonas' then
    -- cada entrega tem um raio; dois raios se encostam quando a distância entre as entregas é até 2 raios
    v_pz := true;
    v_raio := greatest(privado.pol_num('zona_entrega_raio_m', 1500, c.empresa_id, v_m, c.tipo_pedido), 0);
    v_zregra := privado.pol_txt('zona_regra', 'todas', c.empresa_id, v_m, c.tipo_pedido);
    select count(*), count(*) filter (where exists (select 1 from public.paradas y where y.corrida_id = p_corrida and y.tipo = 'entrega' and y.id <> x.id
                                                     and privado.dist_m(x.lat, x.lng, y.lat, y.lng) <= 2 * v_raio))
      into v_nent, v_juntas from public.paradas x where x.corrida_id = p_corrida and x.tipo = 'entrega';
    v_agrup := v_nent >= 2 and (case when v_zregra = 'alguma' then v_juntas >= 2 else v_juntas = v_nent end);
    v_zona := jsonb_build_object('raio_m', v_raio, 'regra', v_zregra, 'entregas', v_nent, 'juntas', v_juntas, 'agrupada', v_agrup);
    v_modo := case when v_agrup then 'rota' else 'percentual' end;
  end if;
  if v_modo = 'percentual' then
    v_pct := case when v_pz then coalesce(c.repasse_manual, privado.pol_num('zona_fora_pct', 65, c.empresa_id, v_m, c.tipo_pedido))
                  else coalesce(c.repasse_manual, (select e.repasse_pct from public.empresas e where e.id = c.empresa_id),
                                case when v_m is not null then privado.repasse_de(v_m) end, privado.cfg_num('repasse_motoboy_pct', 67.5)) end;
    v_total := privado.parte_motoboy(c.valor, v_pct, v_dev, v_orig);
    return jsonb_build_object('zona', v_zona, 'modo', 'percentual', 'pct', v_pct, 'valor_rota', coalesce(c.valor, 0), 'dev_pct', v_dev, 'dev_origem', v_orig,
                              'teto', v_teto, 'limitado', v_total > v_teto, 'total', least(v_total, v_teto));
  end if;
  v_regra := privado.pol_txt('pag_km_regra', 'mediana', null, v_m, c.tipo_pedido);
  v_base  := privado.pol_txt('pag_distancia', 'rua', null, v_m, c.tipo_pedido);
  v_vkm   := privado.pol_num('pag_valor_km', 2, null, v_m, c.tipo_pedido);
  v_vext  := privado.pol_num('pag_entrega_extra', 10, null, v_m, c.tipo_pedido);
  v_vcol  := privado.pol_num('pag_coleta_extra', 0, null, v_m, c.tipo_pedido);
  v_fixo  := privado.pol_num('pag_fixo_rota', 0, null, v_m, c.tipo_pedido);
  v_min   := privado.pol_num('pag_minimo', 0, null, v_m, c.tipo_pedido);
  v_perc  := least(100, greatest(1, privado.pol_num('pag_km_percentil', 75, null, v_m, c.tipo_pedido)));
  if v_pz then
    -- entregas juntas: km da entrega de referência (padrão: a mais próxima) + fixo por entrega a mais
    v_regra := privado.pol_txt('zona_km_regra', 'mais_perto', c.empresa_id, v_m, c.tipo_pedido);
    v_vkm   := privado.pol_num('zona_valor_km', 2, c.empresa_id, v_m, c.tipo_pedido);
    v_vext  := privado.pol_num('zona_entrega_extra', 10, c.empresa_id, v_m, c.tipo_pedido);
    v_vcol  := privado.pol_num('zona_coleta_extra', 0, c.empresa_id, v_m, c.tipo_pedido);
    v_fixo  := privado.pol_num('zona_fixo_rota', 0, c.empresa_id, v_m, c.tipo_pedido);
    v_min   := privado.pol_num('zona_minimo', 0, c.empresa_id, v_m, c.tipo_pedido);
  end if;

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
    'zona', v_zona, 'valor_rota', coalesce(c.valor, 0), 'teto', v_teto, 'limitado', v_total > v_teto, 'calculado', v_total,
    'modo', 'rota', 'regra', v_regra, 'percentil', case when v_regra = 'percentil' then v_perc end, 'distancia', v_base,
    'distancias_km', (select coalesce(jsonb_agg(round(u / 1000.0, 2)), '[]') from unnest(v_ds) u),
    'km_referencia', round(v_ref / 1000.0, 2), 'valor_km', v_vkm, 'valor_km_total', round(round(v_ref / 1000.0, 2) * v_vkm, 2),
    'entregas', v_n, 'entregas_extras', greatest(v_n - 1, 0), 'valor_entrega_extra', v_vext,
    'coletas', v_ncol, 'coletas_extras', greatest(v_ncol - 1, 0), 'valor_coleta_extra', v_vcol,
    'fixo', v_fixo, 'minimo', v_min, 'total', least(v_total, v_teto));
end;
$$;


notify pgrst, 'reload schema';
