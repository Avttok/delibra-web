-- =====================================================================
-- PW Express · Divisão da rota: motoboy %, gestor o resto, Dev à parte
-- ---------------------------------------------------------------------
--  • O motoboy NUNCA ganha mais que a rota paga: teto = valor da rota − parte
--    do Dev, nos dois modelos (percentual e por km) e também com o ajuste
--    do gestor. Quando o teto corta, o cálculo mostra ("limitado").
--  • Percentual: ex. 40 = motoboy leva 40% da rota, o gestor o resto.
--  • De onde sai a parte do Dev (escolha do gestor, no geral ou por cliente):
--      gestor       → sai só da parte do gestor (R$100: 40 / 55 / 5)
--      total        → sai antes de dividir      (R$100: 5; 38 / 57)
--      proporcional → os dois cedem igual        (R$100: 38 / 57 / 5)
--  • valor_gestao passa a ser o que fica com o gestor: valor − motoboy − Dev.
-- Rode depois de 20261110000012. Seguro rodar de novo.
-- =====================================================================

insert into public.configuracoes (chave, valor) values ('dev_origem', '"gestor"') on conflict (chave) do nothing;

-- Parte do Dev (%) que vale para a corrida
create or replace function privado.dev_da_corrida(c public.corridas)
returns numeric language sql stable security definer set search_path = '' as $$
  select coalesce(c.dev_manual, (select e.dev_pct from public.empresas e where e.id = c.empresa_id),
                  privado.pol_num('dev_pct', 5, c.empresa_id, null, c.tipo_pedido));
$$;

-- Quanto o motoboy leva no percentual, conforme de onde sai a parte do Dev
create or replace function privado.parte_motoboy(p_valor numeric, p_pct numeric, p_dev numeric, p_origem text)
returns numeric language sql immutable set search_path = '' as $$
  select round(case p_origem
    when 'total' then (coalesce(p_valor, 0) - coalesce(p_valor, 0) * coalesce(p_dev, 0) / 100) * coalesce(p_pct, 0) / 100
    when 'proporcional' then coalesce(p_valor, 0) * coalesce(p_pct, 0) / 100 * (1 - coalesce(p_dev, 0) / 100)
    else coalesce(p_valor, 0) * coalesce(p_pct, 0) / 100 end, 2);
$$;


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
begin
  select * into c from public.corridas where id = p_corrida;
  if not found then return null; end if;
  v_m := coalesce(p_motoboy, c.motoboy_id);
  -- teto: o motoboy nunca leva mais que a rota paga (tirando a parte do Dev)
  v_dev := privado.dev_da_corrida(c);
  v_teto := greatest(round(coalesce(c.valor, 0) - coalesce(c.valor, 0) * v_dev / 100, 2), 0);
  v_orig := privado.pol_txt('dev_origem', 'gestor', c.empresa_id, null, c.tipo_pedido);
  v_modo := privado.pol_txt('pag_modo', 'rota', null, v_m, c.tipo_pedido);
  if v_modo = 'percentual' then
    v_pct := coalesce(c.repasse_manual, (select e.repasse_pct from public.empresas e where e.id = c.empresa_id),
                      case when v_m is not null then privado.repasse_de(v_m) end, privado.cfg_num('repasse_motoboy_pct', 67.5));
    v_total := privado.parte_motoboy(c.valor, v_pct, v_dev, v_orig);
    return jsonb_build_object('modo', 'percentual', 'pct', v_pct, 'valor_rota', coalesce(c.valor, 0), 'dev_pct', v_dev, 'dev_origem', v_orig,
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
    'valor_rota', coalesce(c.valor, 0), 'teto', v_teto, 'limitado', v_total > v_teto, 'calculado', v_total,
    'modo', 'rota', 'regra', v_regra, 'percentil', case when v_regra = 'percentil' then v_perc end, 'distancia', v_base,
    'distancias_km', (select coalesce(jsonb_agg(round(u / 1000.0, 2)), '[]') from unnest(v_ds) u),
    'km_referencia', round(v_ref / 1000.0, 2), 'valor_km', v_vkm, 'valor_km_total', round(round(v_ref / 1000.0, 2) * v_vkm, 2),
    'entregas', v_n, 'entregas_extras', greatest(v_n - 1, 0), 'valor_entrega_extra', v_vext,
    'coletas', v_ncol, 'coletas_extras', greatest(v_ncol - 1, 0), 'valor_coleta_extra', v_vcol,
    'fixo', v_fixo, 'minimo', v_min, 'total', least(v_total, v_teto));
end;
$$;


-- Divisão ao aceitar/concluir: motoboy (cálculo + ajuste, nunca acima do teto), Dev e o resto para o gestor
create or replace function privado.dividir_valor()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_calc jsonb; v_dev numeric; v_valor numeric; v_teto numeric; v_moto numeric; v_orig text;
begin
  if new.motoboy_id is not null and new.status::text in ('aceita', 'em_andamento', 'concluida') and (
       old.status is distinct from new.status or old.valor is distinct from new.valor or old.pag_ajuste is distinct from new.pag_ajuste
       or old.motoboy_id is distinct from new.motoboy_id or old.valor_motoboy is distinct from new.valor_motoboy
       or old.repasse_manual is distinct from new.repasse_manual or old.dev_manual is distinct from new.dev_manual) then
    v_valor := coalesce(new.valor, 0);
    v_dev := privado.dev_da_corrida(new);
    v_teto := greatest(round(v_valor - v_valor * v_dev / 100, 2), 0);
    v_orig := privado.pol_txt('dev_origem', 'gestor', new.empresa_id, null, new.tipo_pedido);
    v_calc := privado.calcular_pagamento(new.id, new.motoboy_id);
    if v_calc ->> 'modo' = 'percentual' then
      -- o valor pode ter mudado nesta mesma atualização: refaz com o valor novo
      v_calc := v_calc || jsonb_build_object('total', privado.parte_motoboy(v_valor, (v_calc ->> 'pct')::numeric, v_dev, v_orig), 'valor_rota', v_valor);
      new.repasse_pct := (v_calc ->> 'pct')::numeric;
    end if;
    -- por km: o cálculo antes do teto (o teto é aplicado aqui, com o valor novo da rota)
    v_moto := round(coalesce((v_calc ->> 'calculado')::numeric, (v_calc ->> 'total')::numeric) + coalesce(new.pag_ajuste, 0), 2);
    v_calc := v_calc || jsonb_build_object('total', least(greatest(v_moto - coalesce(new.pag_ajuste, 0), 0), v_teto));
    v_calc := v_calc || jsonb_build_object('teto', v_teto, 'limitado', v_moto > v_teto or coalesce((v_calc ->> 'limitado')::boolean, false));
    new.pag_calculo := v_calc;
    new.valor_motoboy := greatest(least(v_moto, v_teto), 0);
    new.dev_pct := v_dev;
    new.valor_dev := round(v_valor * v_dev / 100, 2);
    new.valor_gestao := v_valor - new.valor_motoboy - new.valor_dev;
  end if;
  return new;
end;
$$;

-- corridas já fechadas: a parte do gestor passa a ser o que sobra de fato (não muda o que o motoboy recebeu)
update public.corridas set valor_gestao = coalesce(valor, 0) - coalesce(valor_motoboy, 0) - coalesce(valor_dev, 0)
 where valor_motoboy is not null;

revoke all on function privado.dev_da_corrida(public.corridas) from public, anon, authenticated;
revoke all on function privado.parte_motoboy(numeric, numeric, numeric, text) from public, anon, authenticated;

notify pgrst, 'reload schema';
