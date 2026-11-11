-- =====================================================================
-- Delibra · 0027: ícone da empresa (leitura), trajeto do orçamento e modo Dev
--
--  • marcas: leitura liberada (o envio do site usa upsert, que precisa ler o objeto).
--  • orcamento_trajeto: "ruas" (padrão) usa a distância pelas ruas que o app/site calcula;
--    "reta" ignora e usa a linha reta × fator_rua. O gestor escolhe por empresa/cliente/tipo.
--  • dev_empresas_foco: lista curta para o seletor do modo Dev (app e site).
-- =====================================================================
set check_function_bodies = off;

drop policy if exists marcas_leitura on storage.objects;
create policy marcas_leitura on storage.objects for select to anon, authenticated using (bucket_id = 'marcas');

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
    'minimo', v_min, 'total', v_total, 'trajeto', case when v_reta then 'reta' else 'ruas' end, 'modo_distancia', case when v_fixo_cliente then 'fixo' when v_soma then 'soma_entregas' else 'rota' end, 'km', v_km, 'distancia_m', round(v_dist),
    'coletas', v_ncol, 'entregas', v_nent, 'volumes', v_pac, 'peso_real_kg', round(v_real, 2), 'peso_cubado_kg', round(v_cub, 2),
    'peso_taxado_kg', v_tax, 'perigoso', v_perig, 'calculado_em', now());
end;
$$;


-- Seletor do modo Dev: empresas (id, nome, nome do app, ícone, situação) e qual está em foco.
create or replace function public.dev_empresas_foco()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  return jsonb_build_object(
    'foco', (select org_em_foco from public.perfis where id = auth.uid()),
    'modo', (select case when org_em_foco is not null then 'empresa' when dev_vazio then 'vazio' else 'tudo' end from public.perfis where id = auth.uid()),
    'empresas', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'nome', o.nome, 'nome_app', o.nome_app, 'logo', o.logo_url, 'cor', o.cor, 'status', o.status,
        'motoboys', (select count(*) from public.perfis p where p.organizacao_id = o.id and 'motoboy' = any (p.papeis))) order by o.nome)
      from public.organizacoes o where o.status <> 'cancelada'), '[]'::jsonb));
end;
$$;
grant execute on function public.dev_empresas_foco() to authenticated;

-- Modo Dev: ver tudo, só uma empresa, ou "em branco" (como uma conta sem empresa).
alter table public.perfis add column if not exists dev_vazio boolean not null default false;

create or replace function public.ve_org(p_org uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select auth.uid() is null
      or (public.is_dev() and case when coalesce((select dev_vazio from public.perfis where id = auth.uid()), false) then p_org is null
                                   else (public.minha_org() is null or p_org is not distinct from public.minha_org()) end)
      or (p_org is not distinct from public.minha_org());
$$;

create or replace function public.dev_definir_modo(p_modo text, p_org uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  if p_modo = 'empresa' then
    if p_org is null or not exists (select 1 from public.organizacoes where id = p_org) then raise exception 'empresa_nao_encontrada' using errcode = '22023'; end if;
    update public.perfis set org_em_foco = p_org, dev_vazio = false where id = auth.uid();
  elsif p_modo = 'vazio' then
    update public.perfis set org_em_foco = null, dev_vazio = true where id = auth.uid();
  else
    update public.perfis set org_em_foco = null, dev_vazio = false where id = auth.uid();
  end if;
  return public.dev_empresas_foco();
end;
$$;
grant execute on function public.dev_definir_modo(text, uuid) to authenticated;

-- dev_focar_org (o "olhar só esta empresa" do site) também sai do modo em branco.
create or replace function public.dev_focar_org(p_org uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  if p_org is not null and not exists (select 1 from public.organizacoes where id = p_org) then raise exception 'empresa_nao_encontrada' using errcode = '22023'; end if;
  update public.perfis set org_em_foco = p_org, dev_vazio = false where id = auth.uid();
end;
$$;

notify pgrst, 'reload schema';
