-- =====================================================================
-- PW Express · Histórico de percursos guardado e traçado pelas ruas
-- ---------------------------------------------------------------------
--  • Os pings das corridas NÃO são mais apagados 30 min depois da corrida
--    (a compactação só calcula o trajeto e o km real). Só some o que o
--    gestor apagar de propósito (apagar corrida / limpar histórico).
--  • pings_percurso: devolve TODOS os pings do período (sem o corte de
--    1000 linhas da API) e, das corridas antigas que já tinham sido
--    compactadas, o trajeto guardado — para o histórico voltar a aparecer.
--  • pings_pedido_cliente: o cliente vê o trajeto feito do pedido dele
--    (da coleta até a última entrega), se a empresa vê ao vivo.
--  • trechos_ajustados: cache do traçado por cima das ruas (map matching),
--    feito pelo site e reaproveitado pelo app e pelo site.
-- Seguro rodar de novo.
-- =====================================================================

-- ------------------------------------------------- compactar sem apagar
create or replace function privado.compactar_trajetos()
returns void language plpgsql security definer set search_path = '' as $$
declare
  r record;
begin
  for r in
    select id from public.corridas
     where status in ('concluida', 'cancelada')
       and compactada_em is null
       and coalesce(concluida_em, cancelada_em) < now() - interval '30 minutes'
     limit 50
  loop
    perform privado.finalizar_trajeto(r.id, false);   -- guarda trajeto e km; os pings ficam
    update public.corridas set compactada_em = now() where id = r.id;
  end loop;
end;
$$;

-- ------------------------------------------------- pings de um período
-- Formato compacto: [motoboy, lat, lng, status, corrida, ms, precisão].
-- Gestor: qualquer motoboy (ou todos, p_motoboy nulo). Motoboy: só os dele.
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

  select coalesce(jsonb_agg(jsonb_build_array(l.motoboy_id, round(l.lat::numeric, 6), round(l.lng::numeric, 6), l.status, l.corrida_id,
                  (extract(epoch from l.registrado_em) * 1000)::bigint, round(coalesce(l.precisao_m, 0)::numeric))
                  order by l.motoboy_id, l.registrado_em), '[]'::jsonb)
    into v_pings
    from public.localizacoes l
   where (case when p_corrida is not null then l.corrida_id = p_corrida
               else l.registrado_em >= p_de and l.registrado_em < p_ate end)
     and (p_motoboy is null or l.motoboy_id = p_motoboy)
     and (p_teste is null or l.teste = p_teste)
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
     and not exists (select 1 from public.localizacoes l where l.corrida_id = c.id);

  return jsonb_build_object('pings', v_pings, 'legado', v_legado);
end;
$$;

-- ------------------------------------------------- trajeto do pedido (cliente)
-- Só o trecho do pedido: da 1ª parada dele concluída até a última (ou agora).
create or replace function public.pings_pedido_cliente(p_pedido uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_pings  jsonb := '[]'::jsonb;
  v_legado jsonb := '[]'::jsonb;
  r        record;
begin
  if auth.uid() is null then raise exception 'nao_autenticado' using errcode = '28000'; end if;
  if not exists (select 1 from public.pedidos p join public.empresas e on e.id = p.empresa_id
                  where p.id = p_pedido and p.empresa_id = privado.minha_empresa() and e.cliente_ve_ao_vivo) then
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

-- ------------------------------------------------- cache do traçado pelas ruas
create table if not exists public.trechos_ajustados (
  chave      text primary key,
  motoboy_id uuid not null references public.perfis (id) on delete cascade,
  caminho    jsonb not null,           -- [[lat, lng], ...]; [] = não deu para ajustar (usa os pings)
  criado_em  timestamptz not null default now()
);
create index if not exists trechos_ajustados_motoboy_idx on public.trechos_ajustados (motoboy_id);
alter table public.trechos_ajustados enable row level security;
revoke all on public.trechos_ajustados from anon, authenticated;

create or replace function public.ler_trechos(p_chaves text[])
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when auth.uid() is null then '{}'::jsonb
         else coalesce((select jsonb_object_agg(t.chave, t.caminho) from public.trechos_ajustados t where t.chave = any (p_chaves)), '{}'::jsonb) end;
$$;

-- itens = [{ chave, motoboy, caminho }]. Gestor guarda de qualquer um; motoboy, só os dele; os outros são ignorados.
create or replace function public.guardar_trechos(p_itens jsonb)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_uid    uuid := auth.uid();
  v_gestor boolean := public.is_gestor();
  v_n      integer;
begin
  if v_uid is null or p_itens is null or jsonb_typeof(p_itens) <> 'array' then return 0; end if;
  insert into public.trechos_ajustados (chave, motoboy_id, caminho)
  select i ->> 'chave', (i ->> 'motoboy')::uuid, i -> 'caminho'
    from jsonb_array_elements(p_itens) i
   where jsonb_typeof(i -> 'caminho') = 'array' and length(i ->> 'chave') between 10 and 200
     and (v_gestor or (i ->> 'motoboy')::uuid = v_uid)
     and exists (select 1 from public.perfis where id = (i ->> 'motoboy')::uuid)
  on conflict (chave) do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- ------------------------------------------------- permissões
revoke all on function public.pings_percurso(timestamptz, timestamptz, uuid, boolean, uuid) from public, anon;
revoke all on function public.pings_pedido_cliente(uuid) from public, anon;
revoke all on function public.ler_trechos(text[]) from public, anon;
revoke all on function public.guardar_trechos(jsonb) from public, anon;
grant execute on function public.pings_percurso(timestamptz, timestamptz, uuid, boolean, uuid) to authenticated;
grant execute on function public.pings_pedido_cliente(uuid) to authenticated;
grant execute on function public.ler_trechos(text[]) to authenticated;
grant execute on function public.guardar_trechos(jsonb) to authenticated;

notify pgrst, 'reload schema';

-- ------------------------------------------------- cliente acompanhando: com a foto do motoboy no mapa
create or replace function public.acompanhar_pedido_cliente(p_pedido uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('lat', m.lat, 'lng', m.lng, 'posicao_em', m.posicao_em, 'nome', split_part(pf.nome, ' ', 1),
                                               'foto', pf.foto_url, 'status', c.status, 'rota_planejada', c.rota_planejada)), '[]')
    from (select distinct pa.corrida_id from public.paradas pa where pa.pedido_id = p_pedido) r
    join public.corridas c on c.id = r.corrida_id and c.status::text in ('aceita', 'em_andamento')
    join public.pedidos p on p.id = p_pedido and p.empresa_id = privado.minha_empresa()
    join public.empresas e on e.id = p.empresa_id and e.cliente_ve_ao_vivo
    join public.motoboys m on m.id = c.motoboy_id
    join public.perfis pf on pf.id = m.id;
$$;
notify pgrst, 'reload schema';
