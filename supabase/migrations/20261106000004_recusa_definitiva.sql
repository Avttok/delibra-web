-- =====================================================================
-- PW Express · Migração 0005 · Quem recusou não recebe a mesma corrida de novo
-- ---------------------------------------------------------------------
-- No redespacho (cascata), motoboys que já recusaram essa corrida ficam de fora.
-- Eles só recebem um aviso silencioso: "Uma corrida que você recusou voltou ao lançamento".
-- (O gestor ainda pode mandar direto para um deles, se quiser.)
-- Seguro rodar de novo.
-- =====================================================================

create or replace function privado.despachar(p_corrida uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  c            public.corridas%rowtype;
  v_coleta     extensions.geography;
  v_motoboy    uuid;
  v_dist       double precision;
  v_oferta     uuid;
  v_expira     timestamptz := now() + make_interval(secs => privado.cfg_num('oferta_segundos', 30));
  v_idade      interval := make_interval(mins => privado.cfg_num('posicao_max_min', 15)::int);
  v_raio_max   numeric := privado.cfg_num('raio_max_despacho_km', 0) * 1000;
  v_favoritos  boolean := privado.cfg_bool('favoritos_primeiro', true);
begin
  select * into c from public.corridas where id = p_corrida for update;
  if not found or c.status not in ('aguardando_motoboy', 'sem_motoboy') then return; end if;
  if exists (select 1 from public.ofertas where corrida_id = p_corrida and status = 'pendente') then return; end if;

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
       -- já recebeu nesta rodada, ou RECUSOU em qualquer rodada
       and not exists (select 1 from public.ofertas o where o.corrida_id = p_corrida and o.motoboy_id = m.id
                        and (o.rodada = c.rodada or o.status = 'recusada'))
       and not exists (select 1 from public.ofertas o where o.motoboy_id = m.id and o.status = 'pendente')
     order by (f.ordem is null), f.ordem, extensions.st_distance(m.posicao, v_coleta)
     limit 1;
  end if;

  if v_motoboy is null then
    update public.corridas set status = 'sem_motoboy' where id = p_corrida;
    perform privado.evento(p_corrida, 'sem_motoboy');
    return;
  end if;

  insert into public.ofertas (corrida_id, motoboy_id, rodada, distancia_m, expira_em)
  values (p_corrida, v_motoboy, c.rodada, round(v_dist), v_expira) returning id into v_oferta;

  update public.corridas set status = 'aguardando_motoboy' where id = p_corrida;
  perform privado.evento(p_corrida, 'oferta_enviada', jsonb_build_object('motoboy_id', v_motoboy, 'distancia_m', round(v_dist)));
  perform privado.enviar_push(v_motoboy, jsonb_build_object(
    'tipo', 'oferta', 'oferta_id', v_oferta::text, 'corrida_id', p_corrida::text, 'teste', c.teste::text,
    'expira_em', to_char(v_expira at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  ));
end;
$$;

create or replace function public.redespachar(p_corrida uuid, p_motoboy uuid default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_teste boolean;
  r record;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select teste into v_teste from public.corridas where id = p_corrida;
  if p_motoboy is not null and not exists (select 1 from public.motoboys where id = p_motoboy and modo_teste = v_teste) then
    raise exception '%', case when v_teste then 'motoboy_fora_do_modo_teste' else 'motoboy_em_modo_teste' end using errcode = '22023';
  end if;
  update public.corridas
     set rodada = rodada + 1,
         modo_despacho = case when p_motoboy is null then 'cascata' else 'direto' end::public.modo_despacho,
         motoboy_designado_id = p_motoboy,
         status = 'aguardando_motoboy'
   where id = p_corrida and status = 'sem_motoboy';
  if not found then raise exception 'corrida_nao_esta_sem_motoboy' using errcode = '22023'; end if;
  perform privado.evento(p_corrida, 'redespachada', jsonb_build_object('motoboy_id', p_motoboy));
  perform privado.despachar(p_corrida);

  -- aviso silencioso para quem recusou (sem som alto, sem tela cheia)
  for r in select distinct motoboy_id from public.ofertas
            where corrida_id = p_corrida and status = 'recusada' and motoboy_id is distinct from p_motoboy loop
    perform privado.enviar_push(r.motoboy_id, jsonb_build_object('tipo', 'corrida_voltou', 'corrida_id', p_corrida::text));
  end loop;
end;
$$;

revoke all on all functions in schema privado from public, anon, authenticated;

-- =====================================================================
-- Modo teste no app: com o modo ligado, os ganhos mostrados são os das corridas de teste
-- =====================================================================
create or replace function public.meus_ganhos()
returns jsonb language sql stable security definer set search_path = '' as $$
  with modo as (
    select coalesce((select modo_teste from public.motoboys where id = auth.uid()), false) as teste
  ), base as (
    select valor_motoboy, (concluida_em at time zone 'America/Sao_Paulo') as quando
      from public.corridas, modo
     where motoboy_id = auth.uid() and status = 'concluida' and corridas.teste = modo.teste
  ), agora as (select (now() at time zone 'America/Sao_Paulo') as t)
  select jsonb_build_object(
    'hoje',   coalesce(sum(valor_motoboy) filter (where quando >= date_trunc('day', t)), 0),
    'semana', coalesce(sum(valor_motoboy) filter (where quando >= date_trunc('week', t)), 0),
    'mes',    coalesce(sum(valor_motoboy) filter (where quando >= date_trunc('month', t)), 0),
    'corridas_hoje', count(*) filter (where quando >= date_trunc('day', t)),
    'teste', (select teste from modo)
  )
  from base, agora;
$$;
