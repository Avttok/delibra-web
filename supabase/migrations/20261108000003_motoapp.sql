-- =====================================================================
-- PW Express · 0011: MotoApp
--  • Raio de disponibilidade do motoboy (da posição dele ou de um ponto fixo).
--    Corrida "urgente" (gestor/Dev) ignora o raio.
--  • Offline automático: disponível sem ping há 30 min vira offline sozinho;
--    o próximo ping "disponível" que chegar traz de volta.
--  • Histórico do motoboy (minhas_corridas) e ganhos mais completos.
-- =====================================================================

insert into public.configuracoes (chave, valor) values
  ('offline_auto_min', '30'),
  ('raio_motoboy_max_km', '100')
on conflict (chave) do nothing;

-- ------------------------------------------------------------- colunas
alter table public.motoboys add column if not exists raio_km      numeric(6, 1);
alter table public.motoboys add column if not exists raio_modo    text not null default 'posicao';
alter table public.motoboys add column if not exists raio_lat     double precision;
alter table public.motoboys add column if not exists raio_lng     double precision;
alter table public.motoboys add column if not exists offline_auto boolean not null default false;
do $$ begin
  alter table public.motoboys add constraint motoboys_raio_modo_valido check (raio_modo in ('posicao', 'fixo'));
exception when duplicate_object then null; end $$;

alter table public.corridas add column if not exists urgente boolean not null default false;

-- ------------------------------------------------------------- raio
create or replace function public.definir_meu_raio(p_km numeric, p_modo text default 'posicao', p_lat double precision default null, p_lng double precision default null)
returns void language plpgsql security definer set search_path = '' as $$
declare v_max numeric := privado.cfg_num('raio_motoboy_max_km', 100);
begin
  if not public.tem_papel('motoboy'::public.papel_usuario) then raise exception 'usuario_nao_e_motoboy' using errcode = '42501'; end if;
  if p_modo not in ('posicao', 'fixo') then raise exception 'modo_invalido' using errcode = '22023'; end if;
  if p_km is not null and (p_km < 0 or (v_max > 0 and p_km > v_max)) then raise exception 'raio_invalido' using errcode = '22023'; end if;
  if p_modo = 'fixo' and (p_lat is null or p_lng is null) then raise exception 'escolha_o_ponto' using errcode = '22023'; end if;
  insert into public.motoboys (id) values (auth.uid()) on conflict (id) do nothing;
  update public.motoboys
     set raio_km = nullif(p_km, 0), raio_modo = p_modo,
         raio_lat = case when p_modo = 'fixo' then p_lat end, raio_lng = case when p_modo = 'fixo' then p_lng end
   where id = auth.uid();
end;
$$;

-- ------------------------------------------------------------- offline automático
-- mudar o status por conta própria (app ou gestor) limpa a marca de "automático"
create or replace function privado.marca_offline_auto()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.status is distinct from old.status and new.offline_auto = old.offline_auto then
    new.offline_auto := false;
  end if;
  return new;
end;
$$;
drop trigger if exists motoboys_offline_auto on public.motoboys;
create trigger motoboys_offline_auto before update on public.motoboys
  for each row execute function privado.marca_offline_auto();

create or replace function privado.offline_automatico()
returns void language plpgsql security definer set search_path = '' as $$
declare v_min int := privado.cfg_num('offline_auto_min', 30)::int;
begin
  if v_min <= 0 then return; end if;
  update public.motoboys
     set status = 'offline', offline_auto = true, status_em = now()
   where status = 'disponivel'
     and coalesce(posicao_em, status_em) < now() - make_interval(mins => v_min)
     and status_em < now() - make_interval(mins => v_min);
end;
$$;

-- ping "disponível" recente de quem caiu sozinho: volta a ficar disponível
create or replace function privado.voltar_do_offline_auto()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status::text = 'disponivel' and new.registrado_em > now() - interval '5 minutes' then
    update public.motoboys set status = 'disponivel', offline_auto = false, status_em = now()
     where id = new.motoboy_id and status = 'offline' and offline_auto;
  end if;
  return null;
end;
$$;
drop trigger if exists localizacoes_volta_offline on public.localizacoes;
create trigger localizacoes_volta_offline after insert on public.localizacoes
  for each row execute function privado.voltar_do_offline_auto();

do $$ begin perform cron.unschedule('pwex-offline-auto'); exception when others then null; end $$;
select cron.schedule('pwex-offline-auto', '* * * * *', 'select privado.offline_automatico()');

-- ------------------------------------------------------------- despacho respeita o raio
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
  v_fc         numeric;
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
       -- raio do próprio motoboy (da posição dele ou de um ponto fixo); corrida urgente ignora
       and (c.urgente or coalesce(m.raio_km, 0) <= 0 or extensions.st_distance(
              case when m.raio_modo = 'fixo' and m.raio_lat is not null and m.raio_lng is not null
                   then extensions.st_setsrid(extensions.st_makepoint(m.raio_lng, m.raio_lat), 4326)::extensions.geography
                   else m.posicao end,
              v_coleta) <= m.raio_km * 1000)
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

  -- acréscimo pela distância deste motoboy até a coleta (cada motoboy vê o valor dele)
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

-- ------------------------------------------------------------- criar corrida (com "urgente")
create or replace function public.criar_corrida(dados jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_id    uuid;
  v_modo  public.modo_despacho := coalesce(nullif(dados ->> 'modo_despacho', ''), 'cascata')::public.modo_despacho;
  v_teste boolean := coalesce((dados ->> 'teste')::boolean, false);
  v_moto  uuid := nullif(dados ->> 'motoboy_id', '')::uuid;
  v_exige_codigo boolean := coalesce((dados ->> 'exige_codigo')::boolean, privado.cfg_bool('padrao_exige_codigo', false));
  -- planejada: tem horário para começar
  v_quando  timestamptz := nullif(dados ->> 'agendada_para', '')::timestamptz;
  v_serie   uuid := nullif(dados ->> 'serie_id', '')::uuid;
  v_status  text := 'aguardando_motoboy';
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if jsonb_array_length(coalesce(dados -> 'paradas', '[]')) < 2 then
    raise exception 'corrida_precisa_de_2_paradas' using errcode = '22023';
  end if;
  if (dados -> 'paradas' -> 0 ->> 'tipo') <> 'coleta' then
    raise exception 'primeira_parada_deve_ser_coleta' using errcode = '22023';
  end if;
  if v_modo = 'direto' and v_moto is null then
    raise exception 'escolha_o_motoboy' using errcode = '22023';
  end if;
  if v_modo = 'direto' and not exists (select 1 from public.motoboys where id = v_moto and modo_teste = v_teste) then
    raise exception '%', case when v_teste then 'motoboy_fora_do_modo_teste' else 'motoboy_em_modo_teste' end
      using errcode = '22023';
  end if;

  if v_quando is not null then
    if v_quando < now() + make_interval(mins => privado.cfg_num('agendada_antecedencia_min', 30)::int) then
      raise exception 'horario_muito_proximo' using errcode = '22023';
    end if;
    -- direto = já reservada para esse motoboy; cascata = aberta para todos reservarem
    v_status := case when v_modo = 'direto' then 'reservada' else 'agendada' end;
  end if;

  insert into public.corridas (
    status, motoboy_id, agendada_para, serie_id, reservada_em,
    urgente, empresa_id, cliente_nome, aplicar_acrescimo, criada_por, modo_despacho, motoboy_designado_id, teste,
    exige_foto, exige_assinatura, exige_nome, exige_codigo, codigo_entrega,
    exigir_no_local, raio_chegada_m,
    distancia_planejada_m, duracao_planejada_s, rota_planejada, valor, observacoes
  ) values (
    v_status::public.status_corrida,
    case when v_status = 'reservada' then v_moto end,
    v_quando,
    v_serie,
    case when v_status = 'reservada' then now() end,
    coalesce((dados ->> 'urgente')::boolean, false),
    nullif(dados ->> 'empresa_id', '')::uuid,
    case when nullif(dados ->> 'empresa_id', '') is null then nullif(left(trim(dados ->> 'cliente_nome'), 80), '') end,
    coalesce((dados ->> 'aplicar_acrescimo')::boolean, true),
    auth.uid(),
    v_modo,
    v_moto,
    v_teste,
    coalesce((dados ->> 'exige_foto')::boolean, privado.cfg_bool('padrao_exige_foto', false)),
    coalesce((dados ->> 'exige_assinatura')::boolean, privado.cfg_bool('padrao_exige_assinatura', false)),
    coalesce((dados ->> 'exige_nome')::boolean, privado.cfg_bool('padrao_exige_nome', true)),
    v_exige_codigo,
    case when v_exige_codigo then lpad((floor(random() * 10000))::int::text, 4, '0') end,
    coalesce((dados ->> 'exigir_no_local')::boolean, privado.cfg_bool('exigir_no_local', true)),
    coalesce((dados ->> 'raio_chegada_m')::int, privado.cfg_num('raio_chegada_m', 150)::int),
    (dados ->> 'distancia_planejada_m')::int,
    (dados ->> 'duracao_planejada_s')::int,
    nullif(dados ->> 'rota_planejada', ''),
    (dados ->> 'valor')::numeric,
    nullif(dados ->> 'observacoes', '')
  ) returning id into v_id;

  insert into public.paradas (corrida_id, ordem, tipo, endereco, lat, lng, contato_nome, contato_telefone, instrucoes, referencias)
  select v_id, (ord - 1)::int, (p ->> 'tipo')::public.tipo_parada, p ->> 'endereco',
         (p ->> 'lat')::double precision, (p ->> 'lng')::double precision,
         nullif(p ->> 'contato_nome', ''), nullif(p ->> 'contato_telefone', ''), nullif(p ->> 'instrucoes', ''),
         privado.limpar_referencias(p -> 'referencias')
    from jsonb_array_elements(dados -> 'paradas') with ordinality as t(p, ord);

  perform privado.evento(v_id, 'criada', jsonb_build_object('modo', v_modo, 'teste', v_teste, 'agendada_para', v_quando));
  if v_quando is null then
    perform privado.despachar(v_id);
  elsif v_status = 'reservada' then
    perform privado.evento(v_id, 'reservada', jsonb_build_object('motoboy_id', v_moto, 'pelo_gestor', true));
    perform privado.enviar_push(v_moto, jsonb_build_object('tipo', 'planejada_reservada', 'corrida_id', v_id::text,
      'agendada_para', to_char(v_quando at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')));
  else
    perform privado.avisar_planejada(v_id, 'planejada_nova', null);
  end if;
  return v_id;
end;
$$;

-- ------------------------------------------------------------- perfil (com o raio)
create or replace function public.meu_perfil()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', p.id,
    'nome', p.nome,
    'foto_url', p.foto_url,
    'papeis', to_jsonb(p.papeis),
    'gestor', 'gestor' = any (p.papeis) or 'dev' = any (p.papeis),
    'motoboy', 'motoboy' = any (p.papeis),
    'dev', 'dev' = any (p.papeis),
    'cor_tema', p.cor_tema,
    'modo_teste', coalesce(m.modo_teste, p.modo_teste),
    'raio', jsonb_build_object('km', m.raio_km, 'modo', coalesce(m.raio_modo, 'posicao'), 'lat', m.raio_lat, 'lng', m.raio_lng),
    'modulos', coalesce((
      select jsonb_object_agg(md.chave,
        'dev' = any (p.papeis) or (md.ligado and (md.papeis is null or p.papeis && md.papeis)))
        from public.modulos md
    ), '{}'::jsonb),
    'configuracoes', coalesce((
      select jsonb_object_agg(chave, valor) from public.configuracoes
       where chave in ('intervalo_corrida_s', 'intervalo_economia_s', 'disponivel_envio_min',
                       'disponivel_distancia_m', 'raio_chegada_m', 'teste_admin_ignora_local', 'oferta_segundos')
    ), '{}'::jsonb)
  )
  from public.perfis p
  left join public.motoboys m on m.id = p.id
  where p.id = auth.uid();
$$;

-- ------------------------------------------------------------- ganhos e histórico do motoboy
create or replace function public.meus_ganhos()
returns jsonb language sql stable security definer set search_path = '' as $$
  with modo as (
    select coalesce((select modo_teste from public.motoboys where id = auth.uid()), false) as teste
  ), base as (
    select valor_motoboy, coalesce(distancia_real_m, distancia_planejada_m, 0) as metros,
           (concluida_em at time zone 'America/Sao_Paulo') as quando
      from public.corridas, modo
     where motoboy_id = auth.uid() and status = 'concluida' and corridas.teste = modo.teste
  ), agora as (select (now() at time zone 'America/Sao_Paulo') as t)
  select jsonb_build_object(
    'hoje',   coalesce(sum(valor_motoboy) filter (where quando >= date_trunc('day', t)), 0),
    'semana', coalesce(sum(valor_motoboy) filter (where quando >= date_trunc('week', t)), 0),
    'mes',    coalesce(sum(valor_motoboy) filter (where quando >= date_trunc('month', t)), 0),
    'total',  coalesce(sum(valor_motoboy), 0),
    'corridas_hoje',   count(*) filter (where quando >= date_trunc('day', t)),
    'corridas_semana', count(*) filter (where quando >= date_trunc('week', t)),
    'corridas_mes',    count(*) filter (where quando >= date_trunc('month', t)),
    'km_hoje', round(coalesce(sum(metros) filter (where quando >= date_trunc('day', t)), 0) / 1000.0, 1),
    'km_mes',  round(coalesce(sum(metros) filter (where quando >= date_trunc('month', t)), 0) / 1000.0, 1),
    'teste', (select teste from modo)
  )
  from base, agora;
$$;

-- Corridas que o motoboy fez (concluídas e canceladas), do modo atual. Sem percentuais.
create or replace function public.minhas_corridas(p_dias int default 120)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(x order by (x->>'quando') desc), '[]'::jsonb) from (
    select jsonb_build_object(
      'id', c.id, 'numero', c.numero, 'teste', c.teste, 'status', c.status,
      'valor_motoboy', case when c.status = 'concluida' then c.valor_motoboy end,
      'distancia_m', coalesce(c.distancia_real_m, c.distancia_planejada_m),
      'aceita_em', c.aceita_em, 'concluida_em', c.concluida_em, 'cancelada_em', c.cancelada_em,
      'quando', coalesce(c.concluida_em, c.cancelada_em, c.aceita_em, c.criada_em),
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

-- ------------------------------------------------------------- permissões
revoke all on all functions in schema privado from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array[
    'public.definir_meu_raio(numeric, text, double precision, double precision)', 'public.meus_ganhos()',
    'public.minhas_corridas(int)', 'public.meu_perfil()', 'public.criar_corrida(jsonb)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
