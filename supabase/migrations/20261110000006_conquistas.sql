-- =====================================================================
-- Conquistas dos motoboys: o banco conta o tempo online e devolve as estatísticas
-- (corridas, entregas, km, horas online, tempo de conta, noturnas, sequência de dias…).
-- O catálogo das conquistas (nomes, metas, ícones) fica no app. Rode depois de 20261110000005.
-- =====================================================================

-- tempo online acumulado
alter table public.motoboys add column if not exists online_segundos bigint not null default 0;
alter table public.motoboys add column if not exists online_desde timestamptz;

create or replace function privado.contar_online()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_fim timestamptz;
begin
  if new.status is not distinct from old.status then return new; end if;
  if old.status::text = 'offline' and new.status::text <> 'offline' then
    new.online_desde := now();
  elsif old.status::text <> 'offline' and new.status::text = 'offline' then
    -- offline automático (sem sinal): conta só até o último ping
    v_fim := case when coalesce(new.offline_auto, false) then least(now(), coalesce(old.posicao_em, now())) else now() end;
    new.online_segundos := coalesce(old.online_segundos, 0)
      + greatest(0, extract(epoch from (v_fim - coalesce(old.online_desde, old.status_em, v_fim))))::bigint;
    new.online_desde := null;
  end if;
  return new;
end;
$$;
drop trigger if exists motoboys_contar_online on public.motoboys;
create trigger motoboys_contar_online before update of status on public.motoboys
  for each row execute function privado.contar_online();

-- estimativa do passado: blocos de 5 min com localização enviada fora do offline
update public.motoboys m set online_segundos = coalesce(x.seg, 0)
  from (select motoboy_id, count(distinct date_trunc('hour', registrado_em) + floor(extract(minute from registrado_em) / 5) * interval '5 min') * 300 seg
          from public.localizacoes where status::text <> 'offline' and not coalesce(simulada, false)
         group by motoboy_id) x
 where x.motoboy_id = m.id and m.online_segundos = 0;
update public.motoboys set online_desde = coalesce(status_em, now()) where status::text <> 'offline' and online_desde is null;

-- Estatísticas de um motoboy (ele mesmo ou o gestor). No modo teste, contam as corridas de teste.
create or replace function public.conquistas(p_motoboy uuid default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_id    uuid := coalesce(p_motoboy, auth.uid());
  v_teste boolean;
  v_cri   timestamptz;
  m       public.motoboys%rowtype;
  r       jsonb;
begin
  if v_id is null then raise exception 'sem_login' using errcode = '42501'; end if;
  if v_id <> auth.uid() and not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select modo_teste, criado_em into v_teste, v_cri from public.perfis where id = v_id;
  select * into m from public.motoboys where id = v_id;
  v_teste := coalesce(v_teste, false);

  with c as (
    select k.*, (k.concluida_em at time zone 'America/Sao_Paulo') local
      from public.corridas k
     where k.motoboy_id = v_id and k.status::text = 'concluida' and k.teste = v_teste
  ), dias as (
    select distinct local::date d from c
  ), seq as (
    select count(*) n from (select d, d - (row_number() over (order by d))::int grp from dias) z group by grp
  ), ent as (
    select x.* from public.paradas x join c on c.id = x.corrida_id where x.status::text = 'concluida'
  )
  select jsonb_build_object(
    'corridas',      (select count(*) from c),
    'entregas',      (select count(*) from ent where tipo = 'entrega'),
    'coletas',       (select count(*) from ent where tipo = 'coleta'),
    'km',            round(coalesce((select sum(coalesce(distancia_real_m, distancia_planejada_m, 0)) from c), 0) / 1000.0, 1),
    'horas_online',  round((coalesce(m.online_segundos, 0)
                            + case when m.status::text <> 'offline' and m.online_desde is not null then extract(epoch from now() - m.online_desde) else 0 end) / 3600.0, 1),
    'dias_conta',    greatest(0, (now()::date - coalesce(v_cri, now())::date)),
    'noturnas',      (select count(*) from c where extract(hour from local) >= 22 or extract(hour from local) < 5),
    'madrugada',     (select count(*) from c where extract(hour from local) < 5),
    'cedinho',       (select count(*) from c where extract(hour from local) >= 5 and extract(hour from local) < 8),
    'fim_de_semana', (select count(*) from c where extract(isodow from local) in (6, 7)),
    'urgentes',      (select count(*) from c where urgente),
    'planejadas',    (select count(*) from c where agendada_para is not null),
    'perigosas',     (select count(*) from c where tem_perigoso),
    'clientes',      (select count(distinct coalesce(empresa_id::text, cliente_nome)) from c),
    'dias_ativos',   (select count(*) from dias),
    'sequencia',     coalesce((select max(n) from seq), 0),
    'melhor_dia',    coalesce((select max(n) from (select count(*) n from c group by local::date) z), 0),
    'maior_rota',    coalesce((select max(n) from (select count(*) n from ent where tipo = 'entrega' group by corrida_id) z), 0),
    'maior_km',      round(coalesce((select max(coalesce(distancia_real_m, distancia_planejada_m, 0)) from c), 0) / 1000.0, 1),
    'comprovantes',  (select count(*) from ent where foto_path is not null or assinatura_path is not null),
    'ganhos',        round(coalesce((select sum(valor_motoboy) from c), 0), 2),
    'teste',         v_teste
  ) into r;
  return r;
end;
$$;
revoke all on function public.conquistas(uuid) from public, anon;
grant execute on function public.conquistas(uuid) to authenticated;
