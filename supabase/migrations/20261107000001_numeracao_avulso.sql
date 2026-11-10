-- =====================================================================
-- PW Express · Migração 0007 · Numeração por sequência, acréscimo por corrida e cliente avulso com nome
-- ---------------------------------------------------------------------
-- 1. Corridas reais e de teste têm numerações separadas (#1, #2… e T1, T2…).
--    O número é sempre o maior existente + 1 na sequência: apagar a última corrida libera o número dela.
--    As corridas que já existem são renumeradas em ordem de criação, cada uma na sua sequência.
-- 2. Cada corrida diz se cobra o acréscimo por distância (aplicar_acrescimo).
-- 3. Cliente avulso com nome (cliente_nome), para separar nos registros e no financeiro.
-- Pré-requisito: migrações até a 0006. Seguro rodar de novo.
-- =====================================================================

alter table public.corridas add column if not exists cliente_nome      text;
alter table public.corridas add column if not exists aplicar_acrescimo boolean not null default true;

-- ---------------------------------------------------------------------
-- 1. Numeração
-- ---------------------------------------------------------------------
do $$ begin
  alter table public.corridas alter column numero drop identity if exists;
exception when others then null; end $$;
alter table public.corridas drop constraint if exists corridas_numero_key;
drop index if exists public.corridas_numero_key;

-- renumera só uma vez (na primeira execução)
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'corridas_numero_por_sequencia') then
    update public.corridas set numero = -numero;
    update public.corridas c set numero = n.novo
      from (select id, row_number() over (partition by teste order by criada_em, id) as novo from public.corridas) n
     where n.id = c.id;
    alter table public.corridas add constraint corridas_numero_por_sequencia unique (teste, numero);
  end if;
end $$;

create or replace function privado.numerar_corrida()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  -- uma criação por vez em cada sequência, para dois gestores não pegarem o mesmo número
  perform pg_advisory_xact_lock(hashtext('pwex_numero_' || new.teste::text));
  select coalesce(max(numero), 0) + 1 into new.numero from public.corridas where teste = new.teste;
  return new;
end;
$$;

drop trigger if exists corridas_numero on public.corridas;
create trigger corridas_numero before insert on public.corridas
  for each row execute function privado.numerar_corrida();

-- ---------------------------------------------------------------------
-- 2. Acréscimo por distância só quando a corrida pede
-- ---------------------------------------------------------------------
create or replace function privado.aplicar_acrescimo_entrega()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.valor is null then return new; end if;
  new.valor_base := new.valor;
  new.fator_entrega := case when new.aplicar_acrescimo then privado.fator_distancia(new.distancia_planejada_m, 'entrega') else 0 end;
  new.valor := privado.arredondar(new.valor_base * (1 + new.fator_entrega));
  return new;
end;
$$;

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


create or replace function public.criar_corrida(dados jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_id    uuid;
  v_modo  public.modo_despacho := coalesce(nullif(dados ->> 'modo_despacho', ''), 'cascata')::public.modo_despacho;
  v_teste boolean := coalesce((dados ->> 'teste')::boolean, false);
  v_moto  uuid := nullif(dados ->> 'motoboy_id', '')::uuid;
  v_exige_codigo boolean := coalesce((dados ->> 'exige_codigo')::boolean, privado.cfg_bool('padrao_exige_codigo', false));
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

  insert into public.corridas (
    empresa_id, cliente_nome, aplicar_acrescimo, criada_por, modo_despacho, motoboy_designado_id, teste,
    exige_foto, exige_assinatura, exige_nome, exige_codigo, codigo_entrega,
    exigir_no_local, raio_chegada_m,
    distancia_planejada_m, duracao_planejada_s, rota_planejada, valor, observacoes
  ) values (
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

  perform privado.evento(v_id, 'criada', jsonb_build_object('modo', v_modo, 'teste', v_teste));
  perform privado.despachar(v_id);
  return v_id;
end;
$$;


create or replace function privado.corrida_json(p_corrida uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', c.id,
    'numero', c.numero,
    'status', c.status,
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


-- nomes de clientes avulsos já usados (para sugerir na criação)
create or replace function public.clientes_avulsos()
returns table (nome text, corridas bigint, ultima timestamptz)
language sql stable security definer set search_path = '' as $$
  select cliente_nome, count(*), max(criada_em)
    from public.corridas
   where public.is_gestor() and empresa_id is null and cliente_nome is not null
   group by cliente_nome
   order by max(criada_em) desc
   limit 200;
$$;

-- registro da equipe: inclui o nome do cliente
create or replace function public.registro_membro(p_usuario uuid, p_limite int default 300)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_itens  jsonb;
  v_resumo jsonb;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;

  with ev as (
    select e.criado_em as quando, e.tipo, e.dados, (e.autor = p_usuario and e.tipo not in ('oferta_enviada', 'oferta_expirada')) as fez,
           c.id as corrida_id, c.numero, c.teste, c.status::text as status_corrida,
           case when c.motoboy_id = p_usuario then c.valor_motoboy end as ganho, c.valor,
           coalesce(em.nome, c.cliente_nome) as cliente
      from public.eventos_corrida e
      join public.corridas c on c.id = e.corrida_id
      left join public.empresas em on em.id = c.empresa_id
     where (e.autor = p_usuario and e.tipo not in ('oferta_enviada', 'oferta_expirada', 'sem_motoboy'))
        or (e.dados ->> 'motoboy_id') = p_usuario::text
        or (e.tipo = 'cancelada' and c.motoboy_id = p_usuario)
    union all
    select x.excluida_em, 'excluida', jsonb_build_object('motivo', x.motivo, 'status', x.status), true,
           null, x.numero, x.teste, x.status, null, x.valor, null
      from public.registro_exclusoes x
     where x.excluida_por = p_usuario
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'quando', quando, 'tipo', tipo, 'dados', dados, 'fez', fez, 'corrida_id', corrida_id,
           'numero', numero, 'teste', teste, 'status_corrida', status_corrida, 'ganho', ganho, 'valor', valor, 'cliente', cliente
         ) order by quando desc), '[]'::jsonb)
    into v_itens
    from (select * from ev order by quando desc limit greatest(1, least(p_limite, 2000))) t;

  select jsonb_build_object(
    'criadas',            (select count(*) from public.corridas where criada_por = p_usuario and not teste),
    'criadas_teste',      (select count(*) from public.corridas where criada_por = p_usuario and teste),
    'concluidas',         (select count(*) from public.corridas where motoboy_id = p_usuario and status = 'concluida' and not teste),
    'concluidas_teste',   (select count(*) from public.corridas where motoboy_id = p_usuario and status = 'concluida' and teste),
    'canceladas_com_ele', (select count(*) from public.corridas where motoboy_id = p_usuario and status = 'cancelada'),
    'cancelou',           (select count(*) from public.eventos_corrida where autor = p_usuario and tipo = 'cancelada'),
    'aceitas',            (select count(*) from public.ofertas where motoboy_id = p_usuario and status = 'aceita'),
    'recusadas',          (select count(*) from public.ofertas where motoboy_id = p_usuario and status = 'recusada'),
    'expiradas',          (select count(*) from public.ofertas where motoboy_id = p_usuario and status = 'expirada'),
    'excluiu',            (select count(*) from public.registro_exclusoes where excluida_por = p_usuario),
    'ganhos',             (select coalesce(sum(valor_motoboy), 0) from public.corridas where motoboy_id = p_usuario and status = 'concluida' and not teste),
    'ganhos_teste',       (select coalesce(sum(valor_motoboy), 0) from public.corridas where motoboy_id = p_usuario and status = 'concluida' and teste),
    'km_rodados',         (select round(coalesce(sum(coalesce(distancia_real_m, distancia_planejada_m)), 0) / 1000.0, 1)
                             from public.corridas where motoboy_id = p_usuario and status = 'concluida' and not teste)
  ) into v_resumo;

  return jsonb_build_object('resumo', v_resumo, 'itens', v_itens);
end;
$$;

revoke all on all functions in schema privado from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array['public.criar_corrida(jsonb)', 'public.clientes_avulsos()', 'public.registro_membro(uuid, int)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
