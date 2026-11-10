-- =====================================================================
-- Delibra · 0025: a cobrança da plataforma é com a empresa, nunca com o motoboy
--
--  • O que o motoboy recebe não depende mais da parte da plataforma: o teto é o valor da rota
--    e o percentual do motoboy é sobre o valor inteiro.
--  • A parte da plataforma vem só do plano da empresa (percentual, licença ou isento); o
--    cadastro de clientes não muda isso. Fica registrada em cada rota só para a cobrança.
--  • valor_gestao = valor da rota − motoboy (a mensalidade/percentual é cobrada à parte).
--  • meu_plano(): o gestor vê o próprio plano, o histórico e quanto deve no período.
--  • Ícone da empresa: o dono (ou o Dev) envia um ícone que substitui o Delibra no app,
--    no site e no atalho do celular. marca_publica(slug) mostra nome/ícone/cor na tela de entrar.
-- =====================================================================
set check_function_bodies = off;

create or replace function privado.parte_motoboy(p_valor numeric, p_pct numeric, p_dev numeric, p_origem text)
returns numeric language sql immutable set search_path = '' as $$
  select round(coalesce(p_valor, 0) * coalesce(p_pct, 0) / 100, 2);
$$;

create or replace function privado.dev_da_corrida(c public.corridas)
returns numeric language sql stable security definer set search_path = '' as $$
  select coalesce(c.dev_manual,
    (select case when o.cobranca_modelo = 'percentual' and o.status <> 'cancelada' then o.cobranca_pct else 0 end
       from public.organizacoes o where o.id = c.organizacao_id),
    privado.pol_num('dev_pct', 5, null, null, c.tipo_pedido));
$$;

create or replace function privado.calcular_pagamento_um(p_corrida uuid, p_motoboy uuid, p_modo text)
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
  -- valor novo vindo do gatilho (antes de gravar)
  c.valor := coalesce(nullif(current_setting('pwex.valor_rota', true), '')::numeric, c.valor);
  v_m := coalesce(p_motoboy, c.motoboy_id);
  -- teto: o motoboy nunca leva mais que a rota paga
  v_dev := privado.dev_da_corrida(c);
  v_teto := greatest(coalesce(c.valor, 0), 0);
  v_orig := privado.pol_txt('dev_origem', 'gestor', c.empresa_id, null, c.tipo_pedido);
  v_modo := coalesce(p_modo, privado.pol_txt('pag_modo', 'zonas', c.empresa_id, v_m, c.tipo_pedido));
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
                                case when v_m is not null then privado.repasse_de(v_m) end, privado.pol_num('repasse_motoboy_pct', 65, c.empresa_id, v_m, c.tipo_pedido)) end;
    v_total := privado.parte_motoboy(c.valor, v_pct, v_dev, v_orig);
    return jsonb_build_object('zona', v_zona, 'modo', 'percentual', 'pct', v_pct, 'valor_rota', coalesce(c.valor, 0), 
                              'teto', v_teto, 'limitado', v_total > v_teto, 'calculado', v_total, 'total', least(v_total, v_teto));
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
     where x in ('zonas', 'rota', 'percentual', 'por_entrega', 'fixo');
    if coalesce(array_length(v_modos, 1), 0) = 0 then v_modos := array[privado.pol_txt('pag_modo', 'zonas', c.empresa_id, v_m, c.tipo_pedido)]; end if;
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
    if array_length(v_modos, 1) = 1 and v_acr = 0 and v_acrp = 0 then
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
    if v_rr <> '{}' then v_res := v_res || jsonb_build_object('regras_rota', v_rr); end if;
  exception when others then
    perform set_config('pwex.regras', coalesce(v_ant, ''), true);
    raise;
  end;
  perform set_config('pwex.regras', coalesce(v_ant, ''), true);
  return v_res;
end;
$$;

create or replace function privado.dividir_valor()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_calc jsonb; v_dev numeric; v_valor numeric; v_teto numeric; v_moto numeric; v_orig text;
begin
  if new.motoboy_id is not null and new.status::text in ('aceita', 'em_andamento', 'concluida') and (
       old.status is distinct from new.status or old.valor is distinct from new.valor or old.pag_ajuste is distinct from new.pag_ajuste
       or old.motoboy_id is distinct from new.motoboy_id or old.valor_motoboy is distinct from new.valor_motoboy
       or old.repasse_manual is distinct from new.repasse_manual or old.dev_manual is distinct from new.dev_manual
       or old.pag_regras is distinct from new.pag_regras) then
    v_valor := coalesce(new.valor, 0);
    v_dev := privado.dev_da_corrida(new);
    v_teto := greatest(v_valor, 0);
    v_orig := privado.pol_txt('dev_origem', 'gestor', new.empresa_id, null, new.tipo_pedido);
    perform set_config('pwex.valor_rota', v_valor::text, true);
    perform set_config('pwex.pag_regras_rota', coalesce(new.pag_regras, '{}')::text, true);
    v_calc := privado.calcular_pagamento(new.id, new.motoboy_id);
    perform set_config('pwex.valor_rota', '', true);
    perform set_config('pwex.pag_regras_rota', '', true);
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
    -- piso da extensão de rota (nunca acima do teto)
    new.valor_motoboy := greatest(least(greatest(v_moto, coalesce(new.pag_piso, 0)), v_teto), 0);
    new.dev_pct := v_dev;
    new.valor_dev := round(v_valor * v_dev / 100, 2);
    new.valor_gestao := v_valor - new.valor_motoboy;
  end if;
  return new;
end;
$$;


-- O gestor vê o próprio plano: modelo, valores, histórico e o que deve no período.
create or replace function public.meu_plano(p_de date default null, p_ate date default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_org  uuid := public.minha_org();
  v_de   date := coalesce(p_de, date_trunc('month', now() at time zone 'America/Sao_Paulo')::date);
  v_ate  date := coalesce(p_ate, (now() at time zone 'America/Sao_Paulo')::date);
  o      public.organizacoes%rowtype;
  v_fat  numeric; v_rotas int; v_pct_val numeric; v_devido numeric; v_venc date;
begin
  if not public.is_gestor_pleno() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if v_org is null then return null; end if;
  select * into o from public.organizacoes where id = v_org;
  select coalesce(sum(c.valor), 0), count(*), coalesce(sum(c.valor_dev), 0) into v_fat, v_rotas, v_pct_val
    from public.corridas c
   where c.organizacao_id = v_org and c.status = 'concluida' and not coalesce(c.teste, false)
     and (c.concluida_em at time zone 'America/Sao_Paulo')::date between v_de and v_ate;
  v_devido := round(case o.cobranca_modelo when 'percentual' then v_pct_val
    when 'licenca' then o.mensalidade else 0 end, 2);
  v_venc := make_date(extract(year from v_ate)::int, extract(month from v_ate)::int, o.vencimento_dia);
  if v_venc < v_ate then v_venc := (v_venc + interval '1 month')::date; end if;
  return jsonb_build_object(
    'empresa', o.nome, 'status', o.status, 'modelo', o.cobranca_modelo,
    'pct', o.cobranca_pct, 'mensalidade', o.mensalidade, 'vencimento_dia', o.vencimento_dia, 'proximo_vencimento', v_venc,
    'de', v_de, 'ate', v_ate, 'faturamento', v_fat, 'rotas', v_rotas, 'devido', v_devido,
    'limites', o.limites,
    'historico', coalesce((select jsonb_agg(jsonb_build_object('modelo', l.modelo, 'valor', l.valor, 'pct', l.pct,
        'inicio', l.inicio, 'fim', l.fim, 'status', l.status) order by l.inicio desc, l.criado_em desc)
        from public.licencas l where l.organizacao_id = v_org), '[]'::jsonb),
    'meses', coalesce((select jsonb_agg(jsonb_build_object('mes', m.mes, 'faturamento', m.fat, 'rotas', m.n, 'devido',
          round(case o.cobranca_modelo when 'percentual' then m.dev when 'licenca' then o.mensalidade else 0 end, 2)) order by m.mes desc)
        from (select date_trunc('month', c.concluida_em at time zone 'America/Sao_Paulo')::date mes, sum(c.valor) fat, count(*) n, sum(c.valor_dev) dev
                from public.corridas c where c.organizacao_id = v_org and c.status = 'concluida' and not coalesce(c.teste, false)
                 and c.concluida_em > now() - interval '6 months' group by 1) m), '[]'::jsonb));
end;
$$;
grant execute on function public.meu_plano(date, date) to authenticated;

update public.corridas set valor_gestao = coalesce(valor, 0) - coalesce(valor_motoboy, 0)
 where status not in ('concluida', 'cancelada') and valor is not null;

-- ===================================================================== ícone da empresa
insert into storage.buckets (id, name, public) values ('marcas', 'marcas', true) on conflict (id) do nothing;
drop policy if exists marcas_envio on storage.objects;
create policy marcas_envio on storage.objects for insert to authenticated
  with check (bucket_id = 'marcas' and (public.is_dev() or (public.is_gestor_pleno() and (storage.foldername(name))[1] = public.minha_org()::text)));
drop policy if exists marcas_troca on storage.objects;
create policy marcas_troca on storage.objects for update to authenticated
  using (bucket_id = 'marcas' and (public.is_dev() or (public.is_gestor_pleno() and (storage.foldername(name))[1] = public.minha_org()::text)));
drop policy if exists marcas_apagar on storage.objects;
create policy marcas_apagar on storage.objects for delete to authenticated
  using (bucket_id = 'marcas' and (public.is_dev() or (public.is_gestor_pleno() and (storage.foldername(name))[1] = public.minha_org()::text)));

-- Dev troca o ícone de qualquer empresa; o gestor usa salvar_minha_organizacao.
create or replace function public.definir_marca_organizacao(p_org uuid, p_logo text, p_cor text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not (public.is_dev() or (public.is_gestor_pleno() and p_org = public.minha_org())) then
    raise exception 'sem_permissao' using errcode = '42501';
  end if;
  update public.organizacoes set logo_url = nullif(trim(p_logo), ''), cor = coalesce(nullif(trim(p_cor), ''), cor) where id = p_org;
end;
$$;
grant execute on function public.definir_marca_organizacao(uuid, text, text) to authenticated;

-- Para a tela de entrar / criar conta (link com ?empresa=slug): nome, ícone e cor, sem mais nada.
create or replace function public.marca_publica(p_slug text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('nome', o.nome, 'logo', o.logo_url, 'cor', o.cor)
    from public.organizacoes o where o.slug = p_slug and o.status in ('ativa', 'teste');
$$;
grant execute on function public.marca_publica(text) to anon, authenticated;

notify pgrst, 'reload schema';
