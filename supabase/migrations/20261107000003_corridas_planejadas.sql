-- =====================================================================
-- PW Express · Migração 0009 · Corridas planejadas (com hora para começar)
-- ---------------------------------------------------------------------
-- Fluxo:
--   gestor cria com horário ─┬─ "aberta"  → status agendada: aparece no app de TODOS os motoboys
--                            │              (mesmo offline; teste ↔ modo teste) e o primeiro que reservar fica com ela
--                            └─ "direto"  → status reservada: já fica com o motoboy escolhido
--   reservada: o motoboy pode desistir até 1 h antes (volta a agendada e todos são avisados);
--              a partir de 1 h antes ele toca "Iniciar" e vira uma corrida normal (aceita).
--   ninguém reservou até 30 min antes → entra no despacho normal (cascata), se ligado;
--              senão, no horário vira "sem motoboy".
--   lembrete ao motoboy 30 min antes; 10 min depois do horário sem iniciar → evento de atraso para o gestor.
-- Repetição: criar_serie() cria várias corridas iguais em datas diferentes (mesmo serie_id).
-- Todos os prazos ficam em Configurações → Corridas planejadas.
-- Pré-requisito: migrações até a 0008. Seguro rodar de novo.
-- =====================================================================

alter type public.status_corrida add value if not exists 'agendada';
alter type public.status_corrida add value if not exists 'reservada';

alter table public.corridas add column if not exists agendada_para       timestamptz;
alter table public.corridas add column if not exists reservada_em        timestamptz;
alter table public.corridas add column if not exists serie_id            uuid;
alter table public.corridas add column if not exists lembrete_enviado_em timestamptz;
alter table public.corridas add column if not exists atraso_avisado_em   timestamptz;
create index if not exists corridas_agendada_idx on public.corridas (agendada_para) where agendada_para is not null;
create index if not exists corridas_serie_idx on public.corridas (serie_id) where serie_id is not null;

insert into public.configuracoes (chave, valor) values
  ('agendada_antecedencia_min',   '30'),    -- mínimo de antecedência para planejar
  ('agendada_cancelar_ate_min',   '60'),    -- motoboy desiste até X min antes
  ('agendada_iniciar_antes_min',  '60'),    -- pode iniciar a partir de X min antes
  ('agendada_lembrete_min',       '30'),    -- lembrete X min antes
  ('agendada_despacho_auto',      'true'),  -- sem reserva perto da hora → despacho normal
  ('agendada_despacho_auto_min',  '30'),    -- …X min antes
  ('agendada_atraso_min',         '10'),    -- aviso de atraso X min depois do horário
  ('agendada_max_por_motoboy',    '3'),     -- reservas ao mesmo tempo por motoboy
  ('agendada_intervalo_min',      '30')     -- folga mínima entre duas reservas do mesmo motoboy
on conflict (chave) do nothing;

-- avisa todos os motoboys do modo certo (teste ↔ real), menos um
create or replace function privado.avisar_planejada(p_corrida uuid, p_tipo text, p_exceto uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  c public.corridas%rowtype;
  r record;
begin
  select * into c from public.corridas where id = p_corrida;
  if not found then return; end if;
  for r in
    select m.id from public.motoboys m
      join public.perfis p on p.id = m.id and 'motoboy' = any (p.papeis)
      join auth.users u on u.id = m.id
     where m.modo_teste = c.teste and (u.banned_until is null or u.banned_until < now())
       and (p_exceto is null or m.id <> p_exceto)
  loop
    perform privado.enviar_push(r.id, jsonb_build_object('tipo', p_tipo, 'corrida_id', p_corrida::text,
      'agendada_para', to_char(c.agendada_para at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')));
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- Criação (agora aceita agendada_para e serie_id)
-- ---------------------------------------------------------------------
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
    empresa_id, cliente_nome, aplicar_acrescimo, criada_por, modo_despacho, motoboy_designado_id, teste,
    exige_foto, exige_assinatura, exige_nome, exige_codigo, codigo_entrega,
    exigir_no_local, raio_chegada_m,
    distancia_planejada_m, duracao_planejada_s, rota_planejada, valor, observacoes
  ) values (
    v_status::public.status_corrida,
    case when v_status = 'reservada' then v_moto end,
    v_quando,
    v_serie,
    case when v_status = 'reservada' then now() end,
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

-- Repetição: mesma corrida em várias datas (até 60)
create or replace function public.criar_serie(dados jsonb, p_datas timestamptz[])
returns uuid[] language plpgsql security definer set search_path = '' as $$
declare
  v_serie uuid := gen_random_uuid();
  v_ids   uuid[] := '{}';
  d       timestamptz;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if p_datas is null or cardinality(p_datas) = 0 then raise exception 'sem_datas' using errcode = '22023'; end if;
  if cardinality(p_datas) > 60 then raise exception 'datas_demais' using errcode = '22023'; end if;
  foreach d in array (select array_agg(x order by x) from unnest(p_datas) x) loop
    v_ids := v_ids || public.criar_corrida(dados || jsonb_build_object('agendada_para', d, 'serie_id', v_serie));
  end loop;
  return v_ids;
end;
$$;

create or replace function privado.corrida_json(p_corrida uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', c.id,
    'numero', c.numero,
    'status', c.status,
    'agendada_para', c.agendada_para,
    'reservada_em', c.reservada_em,
    'cancelar_reserva_ate', case when c.agendada_para is not null
      then c.agendada_para - make_interval(mins => privado.cfg_num('agendada_cancelar_ate_min', 60)::int) end,
    'iniciar_a_partir_de', case when c.agendada_para is not null
      then c.agendada_para - make_interval(mins => privado.cfg_num('agendada_iniciar_antes_min', 60)::int) end,
    'teste', c.teste,
    'valor_motoboy', coalesce(c.valor_motoboy, round(coalesce(c.valor, 0) * privado.repasse_de(auth.uid()) / 100, 2)),
    'distancia_planejada_m', c.distancia_planejada_m,
    'duracao_planejada_s', c.duracao_planejada_s,
    'observacoes', c.observacoes,
    'exige_foto', c.exige_foto,
    'exige_assinatura', c.exige_assinatura,
    'exige_nome', c.exige_nome,
    'exige_codigo', c.exige_codigo,
    'exigir_no_local', c.exigir_no_local,
    'raio_chegada_m', c.raio_chegada_m,
    'rota_planejada', c.rota_planejada,
    'empresa_nome', coalesce(e.nome, c.cliente_nome),
    'paradas', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id, 'ordem', p.ordem, 'tipo', p.tipo, 'endereco', p.endereco,
        'lat', p.lat, 'lng', p.lng, 'contato_nome', p.contato_nome,
        'contato_telefone', p.contato_telefone, 'instrucoes', p.instrucoes, 'status', p.status,
        'referencias', p.referencias
      ) order by p.ordem)
      from public.paradas p where p.corrida_id = c.id
    ), '[]'::jsonb)
  )
  from public.corridas c
  left join public.empresas e on e.id = c.empresa_id
  where c.id = p_corrida;
$$;

-- ---------------------------------------------------------------------
-- RPCs do APP (motoboy)
-- ---------------------------------------------------------------------

-- abertas para reservar (do meu modo) + as que eu reservei
create or replace function public.corridas_planejadas()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_teste boolean := coalesce((select modo_teste from public.motoboys where id = auth.uid()), false);
begin
  if not public.tem_papel('motoboy'::public.papel_usuario) then raise exception 'apenas_motoboy' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(privado.corrida_json(c.id) || jsonb_build_object('minha', coalesce(c.motoboy_id = auth.uid(), false)) order by c.agendada_para)
      from public.corridas c
     where c.agendada_para is not null and c.teste = v_teste
       and ((c.status::text = 'agendada' and c.agendada_para > now())
            or (c.status::text = 'reservada' and c.motoboy_id = auth.uid()))
  ), '[]'::jsonb);
end;
$$;

create or replace function public.reservar_corrida(p_corrida uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c       public.corridas%rowtype;
  v_teste boolean := coalesce((select modo_teste from public.motoboys where id = auth.uid()), false);
  v_folga interval := make_interval(mins => privado.cfg_num('agendada_intervalo_min', 30)::int);
begin
  if not public.tem_papel('motoboy'::public.papel_usuario) then raise exception 'apenas_motoboy' using errcode = '42501'; end if;
  select * into c from public.corridas where id = p_corrida for update;
  if not found or c.status::text <> 'agendada' or c.motoboy_id is not null then
    raise exception 'corrida_ja_reservada' using errcode = '22023';
  end if;
  if c.teste <> v_teste then raise exception 'modo_teste_diferente' using errcode = '22023'; end if;
  if c.agendada_para <= now() then raise exception 'horario_passou' using errcode = '22023'; end if;
  if (select count(*) from public.corridas where motoboy_id = auth.uid() and status::text = 'reservada')
     >= privado.cfg_num('agendada_max_por_motoboy', 3) then
    raise exception 'limite_de_reservas' using errcode = '22023';
  end if;
  -- não deixa reservar duas no mesmo intervalo (duração prevista + folga)
  if exists (
    select 1 from public.corridas o
     where o.motoboy_id = auth.uid() and o.status::text = 'reservada'
       and tstzrange(o.agendada_para - v_folga, o.agendada_para + make_interval(secs => coalesce(o.duracao_planejada_s, 3600)) + v_folga)
           && tstzrange(c.agendada_para, c.agendada_para + make_interval(secs => coalesce(c.duracao_planejada_s, 3600)))
  ) then
    raise exception 'conflito_de_horario' using errcode = '22023';
  end if;

  update public.corridas set status = 'reservada'::text::public.status_corrida, motoboy_id = auth.uid(), reservada_em = now(),
         lembrete_enviado_em = null, atraso_avisado_em = null
   where id = p_corrida;
  perform privado.evento(p_corrida, 'reservada', jsonb_build_object('motoboy_id', auth.uid()));
  return privado.corrida_json(p_corrida);
end;
$$;

create or replace function public.cancelar_reserva(p_corrida uuid, p_motivo text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  c public.corridas%rowtype;
begin
  select * into c from public.corridas where id = p_corrida for update;
  if not found or c.status::text <> 'reservada' or c.motoboy_id is distinct from auth.uid() then
    raise exception 'reserva_nao_encontrada' using errcode = '22023';
  end if;
  if now() > c.agendada_para - make_interval(mins => privado.cfg_num('agendada_cancelar_ate_min', 60)::int) then
    raise exception 'prazo_de_cancelamento_passou' using errcode = '22023';
  end if;
  update public.corridas set status = 'agendada'::text::public.status_corrida, motoboy_id = null, reservada_em = null where id = p_corrida;
  perform privado.evento(p_corrida, 'reserva_cancelada', jsonb_build_object('motoboy_id', auth.uid(), 'motivo', nullif(trim(p_motivo), '')));
  perform privado.avisar_planejada(p_corrida, 'planejada_voltou', auth.uid());
end;
$$;

-- vira corrida normal (aceita) para quem reservou
create or replace function privado.iniciar_reservada(p_corrida uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  c       public.corridas%rowtype;
  v_pct   numeric;
begin
  select * into c from public.corridas where id = p_corrida for update;
  if not found or c.status::text <> 'reservada' then raise exception 'reserva_nao_encontrada' using errcode = '22023'; end if;
  if exists (select 1 from public.corridas where motoboy_id = c.motoboy_id and status in ('aceita', 'em_andamento')) then
    raise exception 'voce_ja_tem_corrida_ativa' using errcode = '22023';
  end if;
  v_pct := privado.repasse_de(c.motoboy_id);
  update public.corridas
     set status = 'aceita', aceita_em = now(), repasse_pct = v_pct,
         valor_motoboy = round(coalesce(valor, 0) * v_pct / 100, 2),
         valor_gestao = coalesce(valor, 0) - round(coalesce(valor, 0) * v_pct / 100, 2)
   where id = p_corrida;
  update public.paradas set status = 'a_caminho'
   where corrida_id = p_corrida and ordem = (select min(ordem) from public.paradas where corrida_id = p_corrida);
  update public.motoboys set status = 'em_corrida', status_em = now() where id = c.motoboy_id;
  perform privado.evento(p_corrida, 'aceita', jsonb_build_object('motoboy_id', c.motoboy_id, 'repasse_pct', v_pct, 'planejada', true));
end;
$$;

create or replace function public.iniciar_planejada(p_corrida uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c public.corridas%rowtype;
begin
  select * into c from public.corridas where id = p_corrida;
  if not found or c.status::text <> 'reservada' or c.motoboy_id is distinct from auth.uid() then
    raise exception 'reserva_nao_encontrada' using errcode = '22023';
  end if;
  if now() < c.agendada_para - make_interval(mins => privado.cfg_num('agendada_iniciar_antes_min', 60)::int) then
    raise exception 'ainda_nao_pode_iniciar' using errcode = '22023';
  end if;
  perform privado.iniciar_reservada(p_corrida);
  return privado.corrida_json(p_corrida);
end;
$$;

-- ---------------------------------------------------------------------
-- RPC do GESTOR: liberar reserva, reservar para alguém, mudar horário, despachar agora
-- ---------------------------------------------------------------------
create or replace function public.gerenciar_planejada(p_corrida uuid, p_acao text, p_motoboy uuid default null, p_quando timestamptz default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  c public.corridas%rowtype;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select * into c from public.corridas where id = p_corrida for update;
  if not found or c.status::text not in ('agendada', 'reservada') then raise exception 'corrida_nao_esta_planejada' using errcode = '22023'; end if;

  if p_acao = 'liberar' then
    if c.status::text <> 'reservada' then return; end if;
    update public.corridas set status = 'agendada'::text::public.status_corrida, motoboy_id = null, reservada_em = null where id = p_corrida;
    perform privado.evento(p_corrida, 'reserva_cancelada', jsonb_build_object('motoboy_id', c.motoboy_id, 'pelo_gestor', true));
    perform privado.enviar_push(c.motoboy_id, jsonb_build_object('tipo', 'planejada_liberada', 'corrida_id', p_corrida::text));
    perform privado.avisar_planejada(p_corrida, 'planejada_voltou', c.motoboy_id);

  elsif p_acao = 'reservar' then
    if p_motoboy is null or not exists (select 1 from public.motoboys where id = p_motoboy and modo_teste = c.teste) then
      raise exception '%', case when c.teste then 'motoboy_fora_do_modo_teste' else 'motoboy_em_modo_teste' end using errcode = '22023';
    end if;
    if c.motoboy_id is not null and c.motoboy_id <> p_motoboy then
      perform privado.enviar_push(c.motoboy_id, jsonb_build_object('tipo', 'planejada_liberada', 'corrida_id', p_corrida::text));
    end if;
    update public.corridas set status = 'reservada'::text::public.status_corrida, motoboy_id = p_motoboy, reservada_em = now(),
           lembrete_enviado_em = null, atraso_avisado_em = null where id = p_corrida;
    perform privado.evento(p_corrida, 'reservada', jsonb_build_object('motoboy_id', p_motoboy, 'pelo_gestor', true));
    perform privado.enviar_push(p_motoboy, jsonb_build_object('tipo', 'planejada_reservada', 'corrida_id', p_corrida::text,
      'agendada_para', to_char(c.agendada_para at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')));

  elsif p_acao = 'reagendar' then
    if p_quando is null or p_quando < now() + interval '5 minutes' then raise exception 'horario_muito_proximo' using errcode = '22023'; end if;
    update public.corridas set agendada_para = p_quando, lembrete_enviado_em = null, atraso_avisado_em = null where id = p_corrida;
    perform privado.evento(p_corrida, 'reagendada', jsonb_build_object('de', c.agendada_para, 'para', p_quando));
    if c.motoboy_id is not null then
      perform privado.enviar_push(c.motoboy_id, jsonb_build_object('tipo', 'planejada_reagendada', 'corrida_id', p_corrida::text,
        'agendada_para', to_char(p_quando at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')));
    end if;

  elsif p_acao = 'despachar_agora' then
    if c.motoboy_id is not null then
      perform privado.enviar_push(c.motoboy_id, jsonb_build_object('tipo', 'planejada_liberada', 'corrida_id', p_corrida::text));
    end if;
    update public.corridas set status = 'aguardando_motoboy', motoboy_id = null, reservada_em = null, modo_despacho = 'cascata'
     where id = p_corrida;
    perform privado.evento(p_corrida, 'planejada_despachada', jsonb_build_object('pelo_gestor', true));
    perform privado.despachar(p_corrida);

  else
    raise exception 'acao_invalida' using errcode = '22023';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- A cada minuto: lembretes, despacho automático, sem motoboy e atrasos
-- ---------------------------------------------------------------------
create or replace function privado.processar_planejadas()
returns void language plpgsql security definer set search_path = '' as $$
declare
  r record;
begin
  -- lembrete para quem reservou
  for r in
    update public.corridas set lembrete_enviado_em = now()
     where status::text = 'reservada' and lembrete_enviado_em is null
       and agendada_para - make_interval(mins => privado.cfg_num('agendada_lembrete_min', 30)::int) <= now()
    returning id, motoboy_id, agendada_para
  loop
    perform privado.enviar_push(r.motoboy_id, jsonb_build_object('tipo', 'planejada_lembrete', 'corrida_id', r.id::text,
      'agendada_para', to_char(r.agendada_para at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')));
  end loop;

  -- ninguém reservou: despacho normal perto da hora (ou "sem motoboy" no horário)
  if privado.cfg_bool('agendada_despacho_auto', true) then
    for r in
      update public.corridas set status = 'aguardando_motoboy', modo_despacho = 'cascata'
       where status::text = 'agendada'
         and agendada_para - make_interval(mins => privado.cfg_num('agendada_despacho_auto_min', 30)::int) <= now()
      returning id
    loop
      perform privado.evento(r.id, 'planejada_despachada', jsonb_build_object('automatico', true));
      perform privado.despachar(r.id);
    end loop;
  else
    for r in
      update public.corridas set status = 'sem_motoboy' where status::text = 'agendada' and agendada_para <= now() returning id
    loop
      perform privado.evento(r.id, 'sem_motoboy', jsonb_build_object('planejada', true));
    end loop;
  end if;

  -- reservada e não iniciada depois do horário: avisa uma vez
  for r in
    update public.corridas set atraso_avisado_em = now()
     where status::text = 'reservada' and atraso_avisado_em is null
       and agendada_para + make_interval(mins => privado.cfg_num('agendada_atraso_min', 10)::int) <= now()
    returning id, motoboy_id
  loop
    perform privado.evento(r.id, 'planejada_atrasada', jsonb_build_object('motoboy_id', r.motoboy_id));
    perform privado.enviar_push(r.motoboy_id, jsonb_build_object('tipo', 'planejada_atrasada', 'corrida_id', r.id::text));
  end loop;
end;
$$;

do $$ begin
  perform cron.unschedule('pwex-planejadas');
exception when others then null; end $$;
select cron.schedule('pwex-planejadas', '* * * * *', 'select privado.processar_planejadas()');

-- exclusão de corridas: reservada também precisa ser cancelada antes
create or replace function public.excluir_corridas(p_corridas uuid[], p_senha text, p_motivo text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_ativas   int;
  v_arquivos text[];
  v_qtd      int;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if p_corridas is null or cardinality(p_corridas) = 0 then raise exception 'nada_para_excluir' using errcode = '22023'; end if;

  -- no máximo 5 senhas erradas a cada 15 minutos
  delete from privado.tentativas_senha where quando < now() - interval '15 minutes';
  -- (devolve o erro em vez de lançar exceção, para a tentativa ficar gravada)
  if (select count(*) from privado.tentativas_senha where usuario = auth.uid()) >= 5 then
    return jsonb_build_object('erro', 'muitas_tentativas');
  end if;
  if not privado.senha_confere(p_senha) then
    insert into privado.tentativas_senha (usuario) values (auth.uid());
    return jsonb_build_object('erro', 'senha_incorreta',
      'restantes', 5 - (select count(*) from privado.tentativas_senha where usuario = auth.uid()));
  end if;
  delete from privado.tentativas_senha where usuario = auth.uid();

  select count(*) into v_ativas from public.corridas
   where id = any (p_corridas) and status::text in ('aceita', 'em_andamento', 'reservada');
  if v_ativas > 0 then raise exception 'cancele_as_corridas_em_andamento' using errcode = '22023'; end if;

  -- cópia de segurança no registro
  insert into public.registro_exclusoes (corrida_id, numero, teste, status, valor, copia, motivo, excluida_por)
  select c.id, c.numero, c.teste, c.status::text, c.valor,
         jsonb_build_object(
           'corrida', to_jsonb(c),
           'paradas', coalesce((select jsonb_agg(to_jsonb(p) order by p.ordem) from public.paradas p where p.corrida_id = c.id), '[]'),
           'eventos', coalesce((select jsonb_agg(to_jsonb(e) order by e.criado_em) from public.eventos_corrida e where e.corrida_id = c.id), '[]')
         ),
         nullif(trim(p_motivo), ''), auth.uid()
    from public.corridas c where c.id = any (p_corridas);

  select coalesce(array_agg(a), '{}') into v_arquivos
    from (select foto_path a from public.paradas where corrida_id = any (p_corridas) and foto_path is not null
          union all
          select assinatura_path from public.paradas where corrida_id = any (p_corridas) and assinatura_path is not null) t;

  delete from public.localizacoes where corrida_id = any (p_corridas);
  delete from public.corridas where id = any (p_corridas);   -- paradas, ofertas e eventos vão junto (cascade)
  get diagnostics v_qtd = row_count;

  return jsonb_build_object('excluidas', v_qtd, 'arquivos', to_jsonb(v_arquivos));
end;
$$;

revoke all on all functions in schema privado from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array['public.criar_corrida(jsonb)', 'public.criar_serie(jsonb, timestamptz[])', 'public.corridas_planejadas()',
                           'public.reservar_corrida(uuid)', 'public.cancelar_reserva(uuid, text)', 'public.iniciar_planejada(uuid)',
                           'public.gerenciar_planejada(uuid, text, uuid, timestamptz)', 'public.excluir_corridas(uuid[], text, text)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
