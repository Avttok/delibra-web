-- =====================================================================
-- PW Express 0019 · Revisão com rotas, cálculos combinados, regras por rota,
--   65/30/5, o que o cliente vê da rota, aparelhos, tarefas e decisões do gestor
-- Rode depois de 20261110000018.
-- =====================================================================

-- ------------------------------------------------------------- ajustes novos
insert into public.configuracoes (chave, valor) values
  ('pag_modos',            '[]'),            -- vazio = só o pag_modo; senão, todos estes juntos
  ('pag_combinar',         '"soma"'),        -- soma | maior | menor | media
  ('pag_acrescimo_rota',   '0'),             -- R$ somado depois de combinar
  ('pag_acrescimo_pct',    '0'),             -- % somado depois de combinar
  ('pe_valor_km',          '2'),             -- "por entrega": km de cada entrega × isto
  ('pe_fixo_entrega',      '0'),             -- "por entrega": + isto por entrega
  ('pe_minimo',            '0'),
  ('fx_valor_rota',        '0'),             -- "fixo": valor por rota
  ('fx_valor_entrega',     '0'),             -- "fixo": + por entrega
  ('fx_valor_coleta',      '0'),             -- "fixo": + por coleta
  ('cliente_ve_rota',      '["feito", "motoboy"]'), -- feito | restante | motoboy | planejada | outras_paradas
  ('aprender_regras_rota', 'false'),         -- aplica sozinho as regras de pagamento que o gestor sempre usa
  ('aprender_minimo',      '3'),             -- quantas vezes iguais para aplicar sozinho
  ('revisao_previa_rotas', 'true')           -- revisão do pedido mostra a prévia das rotas
on conflict (chave) do nothing;
-- padrão de divisão 65 / 30 / 5 (o Dev sai da parte do gestor)
update public.configuracoes set valor = '65' where chave = 'repasse_motoboy_pct';
update public.configuracoes set valor = '"gestor"' where chave = 'dev_origem';
update public.configuracoes set valor = '5' where chave = 'dev_pct';

alter table public.corridas add column if not exists pag_regras jsonb;
alter table public.corridas add column if not exists valor_manual numeric(12, 2);
alter table public.corridas add column if not exists valor_manual_motivo text;
alter table public.motoboys add column if not exists aparelho jsonb;
alter table public.motoboys add column if not exists aparelho_em timestamptz;

-- ------------------------------------------------------------- decisões do gestor (o sistema aprende com elas)
create table if not exists public.decisoes_rota (
  id          bigserial primary key,
  criada_em   timestamptz not null default now(),
  por         uuid references public.perfis (id) on delete set null,
  acao        text not null,              -- separar | mover | juntar | ordenar | regras | valor | aprovar | soltar | aprendido
  corrida_id  uuid,
  pedido_id   uuid,
  empresa_id  uuid,
  tipo_pedido text,
  dados       jsonb not null default '{}'  -- antes, depois e o contexto (entregas, km, horário, urgente…)
);
create index if not exists decisoes_rota_empresa_idx on public.decisoes_rota (empresa_id, acao, criada_em desc);
alter table public.decisoes_rota enable row level security;
drop policy if exists decisoes_rota_gestor on public.decisoes_rota;
create policy decisoes_rota_gestor on public.decisoes_rota for select to authenticated using (public.is_gestor());

create or replace function privado.contexto_rota(p_corrida uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('entregas', (select count(*) from public.paradas where corrida_id = c.id and tipo = 'entrega'),
           'coletas', (select count(*) from public.paradas where corrida_id = c.id and tipo = 'coleta'),
           'km', round(coalesce(c.distancia_planejada_m, 0) / 1000.0, 1), 'valor', c.valor, 'urgente', c.urgente,
           'planejada', c.agendada_para is not null, 'hora', extract(hour from coalesce(c.agendada_para, now()) at time zone 'America/Sao_Paulo'),
           'dia_semana', extract(isodow from coalesce(c.agendada_para, now()) at time zone 'America/Sao_Paulo'),
           'pedidos', (select count(distinct pedido_id) from public.paradas where corrida_id = c.id and pedido_id is not null))
    from public.corridas c where c.id = p_corrida;
$$;

create or replace function privado.decisao(p_acao text, p_corrida uuid, p_dados jsonb default '{}')
returns void language plpgsql security definer set search_path = '' as $$
declare c public.corridas%rowtype;
begin
  select * into c from public.corridas where id = p_corrida;
  insert into public.decisoes_rota (por, acao, corrida_id, pedido_id, empresa_id, tipo_pedido, dados)
  values (auth.uid(), p_acao, p_corrida, (select pedido_id from public.paradas where corrida_id = p_corrida and pedido_id is not null order by ordem limit 1),
          c.empresa_id, c.tipo_pedido, coalesce(p_dados, '{}') || jsonb_build_object('contexto', privado.contexto_rota(p_corrida)));
end;
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
  -- teto: o motoboy nunca leva mais que a rota paga (tirando a parte do Dev)
  v_dev := privado.dev_da_corrida(c);
  v_teto := greatest(round(coalesce(c.valor, 0) - coalesce(c.valor, 0) * v_dev / 100, 2), 0);
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
    return jsonb_build_object('zona', v_zona, 'modo', 'percentual', 'pct', v_pct, 'valor_rota', coalesce(c.valor, 0), 'dev_pct', v_dev, 'dev_origem', v_orig,
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

-- "Por entrega": cada entrega paga o km dela (da coleta até ela) + um fixo
create or replace function privado.pag_por_entrega(p_corrida uuid, p_motoboy uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare c public.corridas%rowtype; v_m uuid; v_vkm numeric; v_fx numeric; v_min numeric; v_l jsonb; v_t numeric; v_teto numeric; v_c0 record;
begin
  select * into c from public.corridas where id = p_corrida;
  c.valor := coalesce(nullif(current_setting('pwex.valor_rota', true), '')::numeric, c.valor);
  v_m := coalesce(p_motoboy, c.motoboy_id);
  v_vkm := privado.pol_num('pe_valor_km', 2, c.empresa_id, v_m, c.tipo_pedido);
  v_fx := privado.pol_num('pe_fixo_entrega', 0, c.empresa_id, v_m, c.tipo_pedido);
  v_min := privado.pol_num('pe_minimo', 0, c.empresa_id, v_m, c.tipo_pedido);
  v_teto := greatest(round(coalesce(c.valor, 0) * (1 - privado.dev_da_corrida(c) / 100), 2), 0);
  select lat, lng into v_c0 from public.paradas where corrida_id = p_corrida and tipo = 'coleta' order by ordem limit 1;
  select coalesce(jsonb_agg(jsonb_build_object('parada', x.id, 'ordem', x.ordem, 'km', k, 'valor', round(k * v_vkm + v_fx, 2)) order by x.ordem), '[]'),
         coalesce(sum(round(k * v_vkm + v_fx, 2)), 0)
    into v_l, v_t
    from public.paradas x
    cross join lateral (select round((coalesce(x.dist_rua_m, privado.dist_m(v_c0.lat, v_c0.lng, x.lat, x.lng) * privado.cfg_num('fator_rua', 1.3)) / 1000.0)::numeric, 2) k) kk
   where x.corrida_id = p_corrida and x.tipo = 'entrega';
  v_t := greatest(v_t, v_min);
  return jsonb_build_object('modo', 'por_entrega', 'valor_km', v_vkm, 'fixo_entrega', v_fx, 'minimo', v_min, 'linhas', v_l,
                            'valor_rota', coalesce(c.valor, 0), 'teto', v_teto, 'calculado', v_t, 'limitado', v_t > v_teto, 'total', least(v_t, v_teto));
end;
$$;

-- "Fixo": valor por rota + por entrega + por coleta
create or replace function privado.pag_fixo(p_corrida uuid, p_motoboy uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare c public.corridas%rowtype; v_m uuid; v_r numeric; v_e numeric; v_c numeric; v_ne int; v_nc int; v_t numeric; v_teto numeric;
begin
  select * into c from public.corridas where id = p_corrida;
  c.valor := coalesce(nullif(current_setting('pwex.valor_rota', true), '')::numeric, c.valor);
  v_m := coalesce(p_motoboy, c.motoboy_id);
  v_r := privado.pol_num('fx_valor_rota', 0, c.empresa_id, v_m, c.tipo_pedido);
  v_e := privado.pol_num('fx_valor_entrega', 0, c.empresa_id, v_m, c.tipo_pedido);
  v_c := privado.pol_num('fx_valor_coleta', 0, c.empresa_id, v_m, c.tipo_pedido);
  select count(*) filter (where tipo = 'entrega'), count(*) filter (where tipo = 'coleta') into v_ne, v_nc from public.paradas where corrida_id = p_corrida;
  v_t := round(v_r + v_e * v_ne + v_c * v_nc, 2);
  v_teto := greatest(round(coalesce(c.valor, 0) * (1 - privado.dev_da_corrida(c) / 100), 2), 0);
  return jsonb_build_object('modo', 'fixo', 'valor_rota_fixo', v_r, 'por_entrega', v_e, 'por_coleta', v_c, 'entregas', v_ne, 'coletas', v_nc,
                            'valor_rota', coalesce(c.valor, 0), 'teto', v_teto, 'calculado', v_t, 'limitado', v_t > v_teto, 'total', least(v_t, v_teto));
end;
$$;

-- ------------------------------------------------------------- pagamento: um ou vários modos combinados
-- As regras da própria rota (corridas.pag_regras) valem acima de todas as outras.
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
    v_teto := greatest(round(coalesce(c.valor, 0) * (1 - privado.dev_da_corrida(c) / 100), 2), 0);
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
    v_teto := greatest(round(v_valor - v_valor * v_dev / 100, 2), 0);
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
    new.valor_gestao := v_valor - new.valor_motoboy - new.valor_dev;
  end if;
  return new;
end;
$$;
create or replace function privado.valores_rota(p_corrida uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_valor numeric;
begin
  select coalesce(sum(round(coalesce(p.valor, 0) * x.n::numeric / greatest(t.total, 1), 2)), 0) into v_valor
    from (select pedido_id, count(*) n from public.paradas where corrida_id = p_corrida and tipo = 'entrega' and pedido_id is not null group by pedido_id) x
    join public.pedidos p on p.id = x.pedido_id
    join lateral (select count(*) total from public.pedido_pontos pp where pp.pedido_id = p.id and pp.tipo = 'entrega') t on true;
  -- o cálculo do motoboy já usa o valor novo
  perform set_config('pwex.valor_rota', (select coalesce(valor_manual, v_valor) from public.corridas where id = p_corrida)::text, true);
  update public.corridas set valor = coalesce(valor_manual, v_valor), valor_base = v_valor,
         empresa_id = coalesce((select p.empresa_id from public.paradas x join public.pedidos p on p.id = x.pedido_id
                                 where x.corrida_id = p_corrida order by x.ordem limit 1), empresa_id),
         pag_calculo = case when motoboy_id is null then privado.calcular_pagamento(p_corrida, null) else pag_calculo end
   where id = p_corrida;
  perform set_config('pwex.valor_rota', '', true);
end;
$$;

-- Regras de pagamento que o gestor sempre põe nas rotas deste cliente/tipo: aplica sozinho (se ligado)
create or replace function privado.aplicar_aprendido(p_corrida uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare c public.corridas%rowtype; v_min int; v_r jsonb; v_n int;
begin
  select * into c from public.corridas where id = p_corrida;
  if not found or c.pag_regras is not null then return; end if;
  if not privado.pol_bool('aprender_regras_rota', false, c.empresa_id, null, c.tipo_pedido) then return; end if;
  v_min := greatest(privado.pol_num('aprender_minimo', 3, c.empresa_id, null, c.tipo_pedido)::int, 1);
  select d.dados -> 'depois', count(*) into v_r, v_n from (
    select dados from public.decisoes_rota where acao = 'regras' and empresa_id is not distinct from c.empresa_id
       and tipo_pedido is not distinct from c.tipo_pedido and criada_em > now() - interval '60 days'
     order by criada_em desc limit greatest(v_min + 2, 5)) d
   group by d.dados -> 'depois' order by count(*) desc limit 1;
  if v_n >= v_min and v_r is not null and v_r <> '{}' then
    update public.corridas set pag_regras = v_r where id = p_corrida;
    insert into public.decisoes_rota (acao, corrida_id, empresa_id, tipo_pedido, dados)
    values ('aprendido', p_corrida, c.empresa_id, c.tipo_pedido, jsonb_build_object('regras', v_r, 'vezes', v_n));
  end if;
end;
$$;

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
  v_espera   interval := case when current_setting('pwex.sem_espera', true) = 'on' then interval '0'
                              else make_interval(mins => privado.cfg_num('express_agrupar_espera_min', 0)::int) end;
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
       and (p.cobranca <> 'pre_pago' or p.pagamento_status = 'pago'
            or coalesce((p.regras ->> 'rotear_sem_pagamento')::boolean,
                        privado.pol_bool('rotear_sem_pagamento', false, p.empresa_id, null, p.tipo_pedido)))
       and not exists (select 1 from public.paradas x join public.corridas k on k.id = x.corrida_id
                        where x.pedido_ponto_id = e.id and k.status::text <> 'cancelada')
       and ((p.tipo = 'express' and coalesce(p.aprovado_em, p.criado_em) <= now() - v_espera)
            or (p.tipo = 'planejado' and p.quando - v_antes <= now()))
     order by coalesce(p.quando, p.aprovado_em, p.criado_em), p.numero, e.ordem
  loop
    perform privado.usar_regras((select regras from public.pedidos where id = t.pedido_id));
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
  perform privado.usar_regras('{}');

  foreach v_id in array v_tocadas loop
    perform privado.ordenar_rota(v_id);
    perform privado.valores_rota(v_id);
    if not (v_id = any (v_novas)) then perform privado.evento(v_id, 'rota_atualizada', jsonb_build_object('entregas', (select count(*) from public.paradas where corrida_id = v_id and tipo = 'entrega'))); end if;
  end loop;
  foreach v_id in array v_novas loop
    perform privado.evento(v_id, 'rota_montada', jsonb_build_object('entregas', (select count(*) from public.paradas where corrida_id = v_id and tipo = 'entrega')));
    perform privado.aplicar_aprendido(v_id);
    if current_setting('pwex.segurar_rotas', true) = 'on' then continue; end if;
    if not privado.pol_bool('rota_revisao_gestor', false, (select empresa_id from public.corridas where id = v_id), null,
                            (select tipo_pedido from public.corridas where id = v_id)) then
      perform privado.liberar_rota(v_id);
    end if;
  end loop;
  return v_n;
end;
$$;
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
  perform privado.decisao(case when p_destino is null then 'separar' else 'mover' end, d.id, jsonb_build_object('parada', x.id, 'de', o.id, 'para', d.id));
  return d.id;
end;
$$;

-- ------------------------------------------------------------- editar rotas (montadas ou abertas, sem motoboy)
create or replace function privado.rota_editavel(p_corrida uuid)
returns public.corridas language plpgsql security definer set search_path = '' as $$
declare c public.corridas%rowtype;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select * into c from public.corridas where id = p_corrida for update;
  if not found then raise exception 'rota_nao_encontrada' using errcode = '22023'; end if;
  if c.status::text not in ('montada', 'agendada', 'aguardando_motoboy', 'sem_motoboy') or c.motoboy_id is not null then
    raise exception 'rota_ja_pegada' using errcode = '22023';
  end if;
  return c;
end;
$$;

-- Junta tudo da rota [p_origem] na [p_destino]
create or replace function public.juntar_rotas(p_origem uuid, p_destino uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare x record; o public.corridas; d public.corridas;
begin
  o := privado.rota_editavel(p_origem); d := privado.rota_editavel(p_destino);
  if o.teste <> d.teste or p_origem = p_destino then raise exception 'rota_destino_invalida' using errcode = '22023'; end if;
  for x in select id from public.paradas where corrida_id = p_origem and tipo = 'entrega' order by ordem loop
    perform public.mover_entrega(x.id, p_destino);
  end loop;
  perform privado.decisao('juntar', p_destino, jsonb_build_object('de', p_origem));
  return p_destino;
end;
$$;

-- Ordem escolhida pelo gestor (o site refaz as distâncias pelo mapa depois)
create or replace function public.ordenar_paradas(p_corrida uuid, p_ordem uuid[])
returns void language plpgsql security definer set search_path = '' as $$
declare i int; c public.corridas;
begin
  c := privado.rota_editavel(p_corrida);
  if (select count(*) from public.paradas where corrida_id = p_corrida) <> coalesce(array_length(p_ordem, 1), 0)
     or exists (select 1 from unnest(p_ordem) u where not exists (select 1 from public.paradas x where x.id = u and x.corrida_id = p_corrida)) then
    raise exception 'ordem_invalida' using errcode = '22023';
  end if;
  update public.paradas set ordem = ordem + 100000 where corrida_id = p_corrida;
  for i in 1 .. array_length(p_ordem, 1) loop update public.paradas set ordem = i - 1, dist_acum_m = null where id = p_ordem[i]; end loop;
  perform privado.valores_rota(p_corrida);
  perform privado.decisao('ordenar', p_corrida, jsonb_build_object('ordem', to_jsonb(p_ordem)));
end;
$$;

-- Regras de pagamento só desta rota (valem para quem pegar). p_regras vazio = volta para as regras de sempre.
create or replace function public.definir_regras_rota(p_corrida uuid, p_regras jsonb, p_motivo text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c public.corridas%rowtype; v_r jsonb;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select * into c from public.corridas where id = p_corrida for update;
  if not found then raise exception 'rota_nao_encontrada' using errcode = '22023'; end if;
  if c.status::text in ('concluida', 'cancelada') then raise exception 'rota_nao_editavel' using errcode = '22023'; end if;
  v_r := nullif(privado.limpar_regras(coalesce(p_regras, '{}')), '{}');
  -- pag_modos vem como lista
  if p_regras ? 'pag_modos' and jsonb_typeof(p_regras -> 'pag_modos') = 'array' then v_r := coalesce(v_r, '{}') || jsonb_build_object('pag_modos', p_regras -> 'pag_modos'); end if;
  update public.corridas set pag_regras = v_r where id = p_corrida;
  if c.motoboy_id is null then update public.corridas set pag_calculo = privado.calcular_pagamento(p_corrida, null) where id = p_corrida; end if;
  perform privado.decisao('regras', p_corrida, jsonb_build_object('antes', coalesce(c.pag_regras, '{}'), 'depois', coalesce(v_r, '{}'), 'motivo', p_motivo));
  return (select pag_calculo from public.corridas where id = p_corrida);
end;
$$;

-- Prévia do pagamento com regras que ainda não foram salvas (para o gestor testar antes); null = as salvas
create or replace function public.previa_pagamento_rota(p_corrida uuid, p_regras jsonb default null, p_motoboy uuid default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v jsonb; c public.corridas%rowtype;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select * into c from public.corridas where id = p_corrida;
  if not found then raise exception 'rota_nao_encontrada' using errcode = '22023'; end if;
  -- p_regras é a lista completa da rota (o que ficou de fora volta para as regras de sempre)
  perform set_config('pwex.pag_regras_rota', coalesce(privado.limpar_regras(p_regras), c.pag_regras, '{}')::text, true);
  v := privado.calcular_pagamento(p_corrida, p_motoboy);
  perform set_config('pwex.pag_regras_rota', '', true);
  return v;
end;
$$;

-- Valor da rota escolhido à mão (null = volta à soma dos pedidos)
create or replace function public.definir_valor_rota(p_corrida uuid, p_valor numeric, p_motivo text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare c public.corridas%rowtype;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select * into c from public.corridas where id = p_corrida for update;
  if not found then raise exception 'rota_nao_encontrada' using errcode = '22023'; end if;
  if c.status::text in ('concluida', 'cancelada') then raise exception 'rota_nao_editavel' using errcode = '22023'; end if;
  if p_valor is not null and p_valor < 0 then raise exception 'valor_invalido' using errcode = '22023'; end if;
  update public.corridas set valor_manual = round(p_valor, 2), valor_manual_motivo = nullif(trim(p_motivo), '') where id = p_corrida;
  perform privado.valores_rota(p_corrida);
  perform privado.decisao('valor', p_corrida, jsonb_build_object('antes', c.valor, 'depois', p_valor, 'motivo', p_motivo));
end;
$$;

-- ------------------------------------------------------------- revisão: prévia das rotas (nada é gravado)
create or replace function privado.json_rota_previa(p_corrida uuid, p_pedido uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', c.id, 'numero', c.numero, 'status', c.status, 'valor', c.valor, 'valor_manual', c.valor_manual,
    'agendada_para', c.agendada_para, 'urgente', c.urgente, 'distancia_m', c.distancia_planejada_m, 'pag_regras', c.pag_regras,
    'pagamento', coalesce(c.pag_calculo, privado.calcular_pagamento(c.id, null)), 'rota_planejada', c.rota_planejada,
    'outros_pedidos', (select count(distinct x.pedido_id) from public.paradas x where x.corrida_id = c.id and x.pedido_id is distinct from p_pedido),
    'paradas', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'ordem', x.ordem, 'tipo', x.tipo, 'endereco', x.endereco, 'lat', x.lat, 'lng', x.lng,
                  'pedido_id', x.pedido_id, 'deste_pedido', x.pedido_id = p_pedido, 'pedido_ponto_id', x.pedido_ponto_id, 'dist_rua_m', x.dist_rua_m) order by x.ordem), '[]')
                  from public.paradas x where x.corrida_id = c.id))
    from public.corridas c where c.id = p_corrida;
$$;

create or replace function public.previa_rotas_pedido(p_pedido uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare p public.pedidos%rowtype; v_res jsonb;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select * into p from public.pedidos where id = p_pedido;
  if not found then raise exception 'pedido_nao_encontrado' using errcode = '22023'; end if;
  -- já tem rota: mostra as de verdade
  if exists (select 1 from public.paradas x join public.corridas c on c.id = x.corrida_id where x.pedido_id = p_pedido and c.status::text <> 'cancelada') then
    return jsonb_build_object('previa', false, 'rotas', (select coalesce(jsonb_agg(privado.json_rota_previa(r.id, p_pedido)), '[]')
             from (select distinct c.id from public.paradas x join public.corridas c on c.id = x.corrida_id where x.pedido_id = p_pedido and c.status::text <> 'cancelada') r));
  end if;
  begin
    if p.status = 'recebido' then update public.pedidos set status = 'aprovado', aprovado_em = now() where id = p_pedido; end if;
    perform set_config('pwex.sem_espera', 'on', true);
    perform set_config('pwex.segurar_rotas', 'on', true);
    perform privado.roteirizar(p.teste);
    v_res := jsonb_build_object('previa', true, 'rotas', (select coalesce(jsonb_agg(privado.json_rota_previa(r.id, p_pedido)), '[]')
             from (select distinct c.id from public.paradas x join public.corridas c on c.id = x.corrida_id where x.pedido_id = p_pedido and c.status::text <> 'cancelada') r));
    raise exception 'pwex_previa_desfaz' using errcode = 'P0099';
  exception when sqlstate 'P0099' then null;
  end;
  perform set_config('pwex.sem_espera', 'off', true);
  perform set_config('pwex.segurar_rotas', 'off', true);
  return coalesce(v_res, jsonb_build_object('previa', true, 'rotas', '[]'::jsonb));
end;
$$;

-- Aprova e monta as rotas, mas segura (não solta para os motoboys) para o gestor ajustar
create or replace function public.aprovar_e_montar(p_pedido uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p public.pedidos%rowtype; v_r jsonb;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select * into p from public.pedidos where id = p_pedido for update;
  if not found then raise exception 'pedido_nao_encontrado' using errcode = '22023'; end if;
  if p.status = 'recebido' then
    update public.pedidos set status = 'aprovado', aprovado_em = now(), revisado_por = auth.uid(), revisado_em = now() where id = p_pedido;
  elsif p.status <> 'aprovado' then raise exception 'pedido_ja_em_rota' using errcode = '22023';
  end if;
  perform set_config('pwex.sem_espera', 'on', true);
  perform set_config('pwex.segurar_rotas', 'on', true);
  perform privado.roteirizar(p.teste);
  perform set_config('pwex.segurar_rotas', 'off', true);
  perform set_config('pwex.sem_espera', 'off', true);
  v_r := public.previa_rotas_pedido(p_pedido);
  insert into public.decisoes_rota (por, acao, pedido_id, empresa_id, tipo_pedido, dados)
  values (auth.uid(), 'aprovar', p_pedido, p.empresa_id, p.tipo_pedido, jsonb_build_object('rotas', jsonb_array_length(v_r -> 'rotas')));
  return v_r;
end;
$$;

-- O que o gestor costuma fazer com pedidos deste cliente/tipo (aparece como sugestão na revisão)
create or replace function public.sugestoes_rota(p_pedido uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare p public.pedidos%rowtype;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select * into p from public.pedidos where id = p_pedido;
  return jsonb_build_object(
    'acoes', (select coalesce(jsonb_object_agg(acao, n), '{}') from (select acao, count(*) n from public.decisoes_rota
               where empresa_id is not distinct from p.empresa_id and criada_em > now() - interval '60 days' group by acao) a),
    'pedidos_revisados', (select count(distinct pedido_id) from public.decisoes_rota where empresa_id is not distinct from p.empresa_id and acao = 'aprovar' and criada_em > now() - interval '60 days'),
    'regras_comuns', (select coalesce(jsonb_agg(jsonb_build_object('regras', r, 'vezes', n) order by n desc), '[]') from (
        select dados -> 'depois' r, count(*) n from public.decisoes_rota
         where acao = 'regras' and empresa_id is not distinct from p.empresa_id and tipo_pedido is not distinct from p.tipo_pedido
           and criada_em > now() - interval '60 days' and dados -> 'depois' <> '{}'
         group by dados -> 'depois' order by count(*) desc limit 3) t),
    'valor_medio_manual', (select round(avg((dados ->> 'depois')::numeric / nullif((dados ->> 'antes')::numeric, 0)), 3) from public.decisoes_rota
                            where acao = 'valor' and empresa_id is not distinct from p.empresa_id and dados ->> 'depois' is not null and criada_em > now() - interval '60 days'));
end;
$$;

-- ------------------------------------------------------------- aparelhos (o app conta como está)
create or replace function public.registrar_aparelho(p_info jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'nao_autenticado' using errcode = '28000'; end if;
  update public.motoboys set aparelho = p_info, aparelho_em = now() where id = auth.uid();
end;
$$;

-- ------------------------------------------------------------- tarefas automáticas (pg_cron) pelo Dev
create or replace function public.dev_tarefa(p_nome text, p_acao text, p_valor text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_id bigint; v_cmd text;
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  execute 'select jobid, command from cron.job where jobname = $1' into v_id, v_cmd using p_nome;
  if v_id is null then raise exception 'tarefa_nao_encontrada' using errcode = '22023'; end if;
  if p_acao = 'ligar' then execute 'select cron.alter_job($1, active := true)' using v_id;
  elsif p_acao = 'desligar' then execute 'select cron.alter_job($1, active := false)' using v_id;
  elsif p_acao = 'horario' then
    if p_valor is null or p_valor !~ '^(\S+\s+){4}\S+$|^\d+\s+seconds$' then raise exception 'horario_invalido' using errcode = '22023'; end if;
    execute 'select cron.alter_job($1, schedule := $2)' using v_id, p_valor;
  elsif p_acao = 'rodar' then execute v_cmd;
  else raise exception 'acao_invalida' using errcode = '22023';
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.painel_dev()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_tarefas jsonb := '[]';
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  begin
    execute 'select coalesce(jsonb_agg(jsonb_build_object(''nome'', j.jobname, ''quando'', j.schedule, ''ativa'', j.active, ''comando'', j.command,
               ''ultima'', (select jsonb_build_object(''inicio'', d.start_time, ''fim'', d.end_time, ''status'', d.status, ''mensagem'', left(d.return_message, 300))
                             from cron.job_run_details d where d.jobid = j.jobid order by d.start_time desc limit 1),
               ''falhas_24h'', (select count(*) from cron.job_run_details d where d.jobid = j.jobid and d.status = ''failed'' and d.start_time > now() - interval ''24 hours'')
             ) order by j.jobname), ''[]'') from cron.job j' into v_tarefas;
  exception when others then v_tarefas := '[]';
  end;
  return jsonb_build_object(
    'contagens', jsonb_build_object(
      'contas', (select count(*) from public.perfis),
      'motoboys', (select count(*) from public.perfis where 'motoboy' = any (papeis)),
      'gestores', (select count(*) from public.perfis where 'gestor' = any (papeis)),
      'clientes', (select count(*) from public.empresas),
      'motoboys_online', (select count(*) from public.motoboys where status <> 'offline'),
      'em_corrida', (select count(*) from public.motoboys where status = 'em_corrida'),
      'pedidos', (select count(*) from public.pedidos),
      'pedidos_abertos', (select count(*) from public.pedidos where status in ('recebido', 'aprovado', 'roteirizado', 'em_rota')),
      'corridas_reais', (select count(*) from public.corridas where not teste),
      'corridas_teste', (select count(*) from public.corridas where teste),
      'corridas_ativas', (select count(*) from public.corridas where status::text in ('aguardando_motoboy', 'aceita', 'em_andamento')),
      'no_quadro', (select count(*) from public.corridas where modo_despacho::text = 'quadro' and motoboy_id is null and status::text in ('aguardando_motoboy', 'agendada')),
      'ofertas_pendentes', (select count(*) from public.ofertas where status = 'pendente'),
      'pings_24h', (select count(*) from public.localizacoes where registrado_em > now() - interval '24 hours'),
      'pings_total', (select count(*) from public.localizacoes),
      'trechos_ruas', (select count(*) from public.trechos_ajustados),
      'faturas', (select count(*) from public.faturas),
      'holerites', (select count(*) from public.holerites),
      'mensagens_chat', (select count(*) from public.chat_mensagens),
      'excecoes', (select count(*) from public.politicas),
      'configuracoes_mudadas', (select count(*) from public.configuracoes),
      'faturado_30d', (select coalesce(sum(valor), 0) from public.corridas where not teste and status::text = 'concluida' and concluida_em > now() - interval '30 days'),
      'motoboys_30d', (select coalesce(sum(valor_motoboy), 0) from public.corridas where not teste and status::text = 'concluida' and concluida_em > now() - interval '30 days'),
      'dev_30d', (select coalesce(sum(valor_dev), 0) from public.corridas where not teste and status::text = 'concluida' and concluida_em > now() - interval '30 days'),
      'corridas_apagadas', (select count(*) from public.registro_exclusoes),
      'contas_excluidas', (select count(*) from public.registro_contas_excluidas),
      'tamanho_banco_mb', (select round(pg_database_size(current_database()) / 1048576.0))
    ),
    'aparelhos', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', m.id, 'nome', p.nome, 'versao_app', m.versao_app, 'status', m.status, 'posicao_em', m.posicao_em,
        'bateria', m.bateria, 'precisao_m', m.precisao_m, 'modo_economia', m.modo_economia, 'modo_teste', m.modo_teste,
        'status_em', m.status_em, 'pings_24h', (select count(*) from public.localizacoes l where l.motoboy_id = m.id and l.registrado_em > now() - interval '24 hours'),
        'push', exists (select 1 from privado.fcm_tokens t where t.motoboy_id = m.id),
        'push_tokens', (select count(*) from privado.fcm_tokens t where t.motoboy_id = m.id),
        'aparelho', m.aparelho, 'aparelho_em', m.aparelho_em, 'email', (select u.email from auth.users u where u.id = m.id),
        'papeis', to_jsonb(p.papeis), 'raio_km', m.raio_km,
        'pings_1h', (select count(*) from public.localizacoes l where l.motoboy_id = m.id and l.registrado_em > now() - interval '1 hour'),
        'ultima_posicao', (select jsonb_build_object('lat', l.lat, 'lng', l.lng, 'quando', l.registrado_em, 'velocidade', l.velocidade_ms, 'precisao', l.precisao_m)
                             from public.localizacoes l where l.motoboy_id = m.id order by l.registrado_em desc limit 1),
        'corrida', (select jsonb_build_object('id', c.id, 'numero', c.numero, 'status', c.status) from public.corridas c
                     where c.motoboy_id = m.id and c.status::text in ('aceita', 'em_andamento') limit 1)
      ) order by m.posicao_em desc nulls last)
      from public.motoboys m join public.perfis p on p.id = m.id
    ), '[]'::jsonb),
    'exclusoes', coalesce((
      select jsonb_agg(x order by x->>'quando' desc) from (
        select jsonb_build_object('tipo', 'corrida', 'rotulo', coalesce(case when teste then 'T' else '#' end || numero, '—'),
                 'motivo', motivo, 'por', (select nome from public.perfis where id = excluida_por), 'quando', excluida_em) x
          from public.registro_exclusoes
        union all
        select jsonb_build_object('tipo', 'conta', 'rotulo', coalesce(nome, email), 'motivo', motivo,
                 'por', (select nome from public.perfis where id = excluida_por), 'quando', excluida_em)
          from public.registro_contas_excluidas
        limit 300
      ) t
    ), '[]'::jsonb),
    'tarefas', v_tarefas
  );
end;
$$;
create or replace function privado.limpar_regras(r jsonb)
returns jsonb language sql immutable set search_path = '' as $$
  select coalesce(jsonb_object_agg(k, v), '{}') from jsonb_each(case when jsonb_typeof(r) = 'object' then r else '{}' end) e(k, v)
   where k ~ '^[a-z0-9_]{2,60}$' and k not in ('dev_pct') and (jsonb_typeof(v) in ('number', 'boolean', 'string')
          or (jsonb_typeof(v) = 'array' and not exists (select 1 from jsonb_array_elements(v) x where jsonb_typeof(x) <> 'string')));
$$;

create or replace function privado.cliente_ve(p_empresa uuid, p_item text)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select privado.pol('cliente_ve_rota', p_empresa, null, null) ? p_item), p_item in ('feito', 'motoboy'));
$$;

create or replace function public.acompanhar_pedido_cliente(p_pedido uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'lat', case when privado.cliente_ve(p.empresa_id, 'motoboy') then m.lat end,
           'lng', case when privado.cliente_ve(p.empresa_id, 'motoboy') then m.lng end,
           'posicao_em', m.posicao_em, 'nome', split_part(pf.nome, ' ', 1),
           'foto', pf.foto_url, 'status', c.status,
           'rota_planejada', case when privado.cliente_ve(p.empresa_id, 'planejada') then c.rota_planejada end,
           'outras_paradas', case when privado.cliente_ve(p.empresa_id, 'outras_paradas') then (
              select coalesce(jsonb_agg(jsonb_build_object('lat', round(x.lat::numeric, 3), 'lng', round(x.lng::numeric, 3), 'tipo', x.tipo, 'feita', x.status::text = 'concluida') order by x.ordem), '[]')
                from public.paradas x where x.corrida_id = c.id and x.pedido_id is distinct from p.id) end)), '[]')
    from (select distinct pa.corrida_id from public.paradas pa where pa.pedido_id = p_pedido) r
    join public.corridas c on c.id = r.corrida_id and c.status::text in ('aceita', 'em_andamento')
    join public.pedidos p on p.id = p_pedido and p.empresa_id = privado.minha_empresa()
    join public.empresas e on e.id = p.empresa_id and e.cliente_ve_ao_vivo
    join public.motoboys m on m.id = c.motoboy_id
    join public.perfis pf on pf.id = m.id;
$$;
create or replace function public.pings_pedido_cliente(p_pedido uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_pings  jsonb := '[]'::jsonb;
  v_legado jsonb := '[]'::jsonb;
  r        record;
begin
  if auth.uid() is null then raise exception 'nao_autenticado' using errcode = '28000'; end if;
  if not exists (select 1 from public.pedidos p join public.empresas e on e.id = p.empresa_id
                  where p.id = p_pedido and p.empresa_id = privado.minha_empresa() and e.cliente_ve_ao_vivo and privado.cliente_ve(p.empresa_id, 'feito')) then
    return jsonb_build_object('pings', v_pings, 'legado', v_legado);
  end if;
  for r in
    select pa.corrida_id, c.motoboy_id, c.trajeto, c.compactada_em,
           min(pa.concluida_em) as ini,
           case when bool_and(pa.status::text in ('concluida', 'falhou', 'pulada')) then max(pa.concluida_em) else now() end as fim
      from public.paradas pa join public.corridas c on c.id = pa.corrida_id
     where pa.pedido_id = p_pedido and c.motoboy_id is not null
     group by pa.corrida_id, c.motoboy_id, c.trajeto, c.compactada_em
  loop
    continue when r.ini is null;
    v_pings := v_pings || coalesce((
      select jsonb_agg(jsonb_build_array(l.motoboy_id, round(l.lat::numeric, 6), round(l.lng::numeric, 6), l.status, l.corrida_id,
                       (extract(epoch from l.registrado_em) * 1000)::bigint, round(coalesce(l.precisao_m, 0)::numeric)) order by l.registrado_em)
        from public.localizacoes l
       where l.corrida_id = r.corrida_id and l.registrado_em >= r.ini - interval '1 minute' and l.registrado_em <= r.fim + interval '1 minute'
         and l.lat between -90 and 90 and l.lng between -180 and 180 and not (l.lat = 0 and l.lng = 0)), '[]'::jsonb);
  end loop;
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
    'modelo_horario', privado.pol_bool('cliente_modelo_horario', true, v_cli),
    'pode_agendar', privado.pol_bool('cliente_pode_agendar', true, v_cli), 'pode_urgente', privado.pol_bool('cliente_pode_urgente', true, v_cli),
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

-- Quem escreveu na conversa (nome, foto e cargos: os selos do chat)
create or replace function public.chat_autores(p_conversa uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'nome', p.nome, 'foto', p.foto_url, 'papeis', to_jsonb(p.papeis),
                   'empresa', (select e.nome from public.empresas e where e.id = p.empresa_id))), '[]')
    from public.perfis p
   where public.chat_sou_membro(p_conversa)
     and (p.id in (select distinct g.autor_id from public.chat_mensagens g where g.conversa_id = p_conversa)
          or p.id in (select m.usuario_id from public.chat_membros m where m.conversa_id = p_conversa));
$$;

do $$
declare f text;
begin
  foreach f in array array['chat_autores(uuid)', 'juntar_rotas(uuid, uuid)', 'ordenar_paradas(uuid, uuid[])', 'definir_regras_rota(uuid, jsonb, text)',
                           'previa_pagamento_rota(uuid, jsonb, uuid)', 'definir_valor_rota(uuid, numeric, text)', 'previa_rotas_pedido(uuid)',
                           'aprovar_e_montar(uuid)', 'sugestoes_rota(uuid)', 'registrar_aparelho(jsonb)', 'dev_tarefa(text, text, text)'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
revoke all on function privado.calcular_pagamento_um(uuid, uuid, text) from public, anon, authenticated;
revoke all on function privado.pag_por_entrega(uuid, uuid) from public, anon, authenticated;
revoke all on function privado.pag_fixo(uuid, uuid) from public, anon, authenticated;
revoke all on function privado.decisao(text, uuid, jsonb) from public, anon, authenticated;
revoke all on function privado.aplicar_aprendido(uuid) from public, anon, authenticated;

