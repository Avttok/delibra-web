-- =====================================================================
-- PW Express · Migração 0006 · Acréscimo por distância, modo teste no painel e registro por pessoa
-- ---------------------------------------------------------------------
-- 1. Acréscimo por distância (configurável em Configurações → Preço):
--    · coleta a mais de 100 km do motoboy: +0,5× do valor a cada 100 km (calculado por motoboy, na oferta)
--    · entrega a mais de 200 km da coleta: +0,25× a cada 200 km (calculado na criação)
--    Os acréscimos somam: 250 km até a coleta + 450 km de percurso = 1 + 1,0 + 0,5 = 2,5× o valor.
-- 2. Modo teste também para quem é só gestor (o painel inteiro fica violeta).
-- 3. registro_membro(): tudo o que cada pessoa fez ou recebeu, para a página Equipe.
-- 4. Até 3 pontos de referência por parada (vão para o app junto com a corrida).
-- Pré-requisito: migrações até a 0005. Seguro rodar de novo.
-- =====================================================================

insert into public.configuracoes (chave, valor) values
  ('acrescimo_distancia',        'true'),
  ('acrescimo_coleta_cada_km',   '100'),
  ('acrescimo_coleta_fator',     '0.5'),
  ('acrescimo_entrega_cada_km',  '200'),
  ('acrescimo_entrega_fator',    '0.25')
on conflict (chave) do nothing;

alter table public.corridas add column if not exists valor_base    numeric(10, 2);          -- antes dos acréscimos
alter table public.corridas add column if not exists fator_entrega numeric(6, 3) not null default 0;
alter table public.corridas add column if not exists fator_coleta  numeric(6, 3) not null default 0;
alter table public.ofertas  add column if not exists fator_coleta  numeric(6, 3) not null default 0;
alter table public.ofertas  add column if not exists valor         numeric(10, 2);          -- valor desta oferta (com o acréscimo da coleta)
alter table public.perfis   add column if not exists modo_teste    boolean not null default false;

-- quantas "faixas" de distância foram passadas × fator
create or replace function privado.fator_distancia(p_dist_m double precision, p_qual text)
returns numeric language sql stable security definer set search_path = '' as $$
  select case
    when not privado.cfg_bool('acrescimo_distancia', true) or p_dist_m is null then 0
    when privado.cfg_num('acrescimo_' || p_qual || '_cada_km', 0) <= 0 then 0
    else floor(p_dist_m / 1000 / privado.cfg_num('acrescimo_' || p_qual || '_cada_km', 0))
         * privado.cfg_num('acrescimo_' || p_qual || '_fator', 0)
  end;
$$;

-- mesmo arredondamento das Configurações (0 = centavos)
create or replace function privado.arredondar(p_valor numeric)
returns numeric language sql stable security definer set search_path = '' as $$
  select case when privado.cfg_num('arredondamento', 0) > 0
              then ceil(p_valor / privado.cfg_num('arredondamento', 0) - 0.000000001) * privado.cfg_num('arredondamento', 0)
              else round(p_valor, 2) end;
$$;

-- na criação: guarda o valor base e aplica o acréscimo do percurso (coleta → entrega)
create or replace function privado.aplicar_acrescimo_entrega()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.valor is null then return new; end if;
  new.valor_base := new.valor;
  new.fator_entrega := privado.fator_distancia(new.distancia_planejada_m, 'entrega');
  new.valor := privado.arredondar(new.valor_base * (1 + new.fator_entrega));
  return new;
end;
$$;

drop trigger if exists corridas_acrescimo_entrega on public.corridas;
create trigger corridas_acrescimo_entrega before insert on public.corridas
  for each row execute function privado.aplicar_acrescimo_entrega();

-- prévia para a tela de nova corrida (o motoboy ainda não é conhecido)
create or replace function public.prever_acrescimo(p_distancia_m int)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'fator_entrega', privado.fator_distancia(p_distancia_m, 'entrega'),
    'ligado', privado.cfg_bool('acrescimo_distancia', true)
  ) where public.is_gestor();
$$;

-- ---------------------------------------------------------------------
-- Despacho: cada oferta leva o valor com o acréscimo da coleta daquele motoboy
-- ---------------------------------------------------------------------
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
  v_fc := privado.fator_distancia(v_dist, 'coleta');
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

-- o app mostra o valor da oferta (com o acréscimo da distância do motoboy)
create or replace function public.oferta_pendente()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'oferta_id', o.id,
    'expira_em', o.expira_em,
    'segundos_restantes', greatest(0, extract(epoch from (o.expira_em - now())))::int,
    'distancia_m', o.distancia_m,
    'corrida', jsonb_set(
      privado.corrida_json(o.corrida_id), '{valor_motoboy}',
      to_jsonb(round(coalesce(o.valor, c.valor, 0) * privado.repasse_de(o.motoboy_id) / 100, 2))
    )
  )
  from public.ofertas o
  join public.corridas c on c.id = o.corrida_id
  where o.motoboy_id = auth.uid() and o.status = 'pendente' and o.expira_em > now()
  order by o.criada_em desc
  limit 1;
$$;

-- no aceite, o valor da corrida passa a ser o da oferta aceita
create or replace function public.responder_oferta(p_oferta uuid, p_aceitar boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  o       public.ofertas%rowtype;
  v_pct   numeric;
  v_valor numeric;
begin
  select * into o from public.ofertas where id = p_oferta for update;
  if not found or o.motoboy_id <> auth.uid() then
    raise exception 'oferta_nao_encontrada' using errcode = '22023';
  end if;
  if o.status <> 'pendente' or o.expira_em <= now() then
    raise exception 'oferta_expirou' using errcode = '22023';
  end if;

  if not p_aceitar then
    update public.ofertas set status = 'recusada', respondida_em = now() where id = p_oferta;
    perform privado.evento(o.corrida_id, 'oferta_recusada', jsonb_build_object('motoboy_id', o.motoboy_id));
    perform privado.despachar(o.corrida_id);
    return null;
  end if;

  if exists (select 1 from public.corridas
              where motoboy_id = auth.uid() and status in ('aceita', 'em_andamento')) then
    raise exception 'voce_ja_tem_corrida_ativa' using errcode = '22023';
  end if;

  v_pct := privado.repasse_de(o.motoboy_id);
  select coalesce(o.valor, valor, 0) into v_valor from public.corridas where id = o.corrida_id;
  update public.ofertas set status = 'aceita', respondida_em = now() where id = p_oferta;
  update public.corridas
     set status = 'aceita', motoboy_id = o.motoboy_id, aceita_em = now(),
         valor = v_valor,
         fator_coleta = o.fator_coleta,
         repasse_pct = v_pct,
         valor_motoboy = round(v_valor * v_pct / 100, 2),
         valor_gestao = v_valor - round(v_valor * v_pct / 100, 2)
   where id = o.corrida_id;
  update public.paradas set status = 'a_caminho'
   where corrida_id = o.corrida_id and ordem = (select min(ordem) from public.paradas where corrida_id = o.corrida_id);
  update public.motoboys set status = 'em_corrida', status_em = now() where id = o.motoboy_id;
  perform privado.evento(o.corrida_id, 'aceita', jsonb_build_object(
    'motoboy_id', o.motoboy_id, 'repasse_pct', v_pct, 'fator_coleta', o.fator_coleta, 'distancia_m', o.distancia_m));

  return privado.corrida_json(o.corrida_id);
end;
$$;

-- =====================================================================
-- Modo teste para todo gestor (no painel); gestor+motoboy também muda o app
-- =====================================================================
update public.perfis p set modo_teste = true
  from public.motoboys m where m.id = p.id and m.modo_teste and not p.modo_teste;

create or replace function public.definir_modo_teste(p_ligado boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_gestor() then
    raise exception 'apenas_gestor' using errcode = '42501';
  end if;
  if public.tem_papel('motoboy'::public.papel_usuario) then
    if exists (select 1 from public.ofertas where motoboy_id = auth.uid() and status = 'pendente')
       or exists (select 1 from public.corridas where motoboy_id = auth.uid() and status in ('aceita', 'em_andamento')) then
      raise exception 'conclua_a_corrida_antes' using errcode = '22023';
    end if;
    insert into public.motoboys (id, modo_teste) values (auth.uid(), p_ligado)
    on conflict (id) do update set modo_teste = excluded.modo_teste;
  end if;
  update public.perfis set modo_teste = p_ligado where id = auth.uid();
end;
$$;

create or replace function public.meu_perfil()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', p.id,
    'nome', p.nome,
    'foto_url', p.foto_url,
    'papeis', to_jsonb(p.papeis),
    'gestor', 'gestor' = any (p.papeis),
    'motoboy', 'motoboy' = any (p.papeis),
    'modo_teste', coalesce(m.modo_teste, p.modo_teste),
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

-- =====================================================================
-- Registro geral de cada pessoa (página Equipe)
-- =====================================================================
create or replace function public.registro_membro(p_usuario uuid, p_limite int default 300)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_itens  jsonb;
  v_resumo jsonb;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;

  with ev as (
    -- o que ela fez (autor) ou recebeu (motoboy citado no evento)
    select e.criado_em as quando, e.tipo, e.dados, (e.autor = p_usuario and e.tipo not in ('oferta_enviada', 'oferta_expirada')) as fez,
           c.id as corrida_id, c.numero, c.teste, c.status::text as status_corrida,
           case when c.motoboy_id = p_usuario then c.valor_motoboy end as ganho, c.valor
      from public.eventos_corrida e
      join public.corridas c on c.id = e.corrida_id
     where (e.autor = p_usuario and e.tipo not in ('oferta_enviada', 'oferta_expirada', 'sem_motoboy'))
        or (e.dados ->> 'motoboy_id') = p_usuario::text
        or (e.tipo = 'cancelada' and c.motoboy_id = p_usuario)
    union all
    select x.excluida_em, 'excluida', jsonb_build_object('motivo', x.motivo, 'status', x.status), true,
           null, x.numero, x.teste, x.status, null, x.valor
      from public.registro_exclusoes x
     where x.excluida_por = p_usuario
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'quando', quando, 'tipo', tipo, 'dados', dados, 'fez', fez, 'corrida_id', corrida_id,
           'numero', numero, 'teste', teste, 'status_corrida', status_corrida, 'ganho', ganho, 'valor', valor
         ) order by quando desc), '[]'::jsonb)
    into v_itens
    from (select * from ev order by quando desc limit greatest(1, least(p_limite, 2000))) t;

  select jsonb_build_object(
    'criadas',            (select count(*) from public.corridas where criada_por = p_usuario),
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

-- listar_equipe agora diz se a pessoa está em modo teste mesmo sem ser motoboy
create or replace function public.listar_equipe()
returns table (id uuid, email text, nome text, foto_url text, papeis public.papel_usuario[],
               status public.status_motoboy, modo_teste boolean, repasse_pct numeric, criado_em timestamptz)
language sql stable security definer set search_path = '' as $$
  select p.id, u.email::text, p.nome, p.foto_url, p.papeis, m.status, coalesce(m.modo_teste, p.modo_teste), m.repasse_pct, p.criado_em
    from public.perfis p
    join auth.users u on u.id = p.id
    left join public.motoboys m on m.id = p.id
   where public.is_gestor()
   order by p.nome;
$$;


-- =====================================================================
-- Pontos de referência: até 3 por parada (o app mostra perto da coleta e da entrega)
-- Formato: [{ "nome": "Posto Ipiranga", "lat": -26.9, "lng": -49.0, "distancia_m": 80, "tipo": "Posto" }]
-- =====================================================================
alter table public.paradas add column if not exists referencias jsonb not null default '[]';
do $$ begin
  alter table public.paradas add constraint paradas_ate_3_referencias
    check (jsonb_typeof(referencias) = 'array' and jsonb_array_length(referencias) <= 3);
exception when duplicate_object then null; end $$;

-- só o que interessa, no máximo 3, sem nomes vazios
create or replace function privado.limpar_referencias(p jsonb)
returns jsonb language sql immutable set search_path = '' as $$
  select coalesce(jsonb_agg(r order by ord), '[]'::jsonb)
    from (
      select jsonb_strip_nulls(jsonb_build_object(
               'nome', left(trim(x ->> 'nome'), 80),
               'lat', (x ->> 'lat')::double precision,
               'lng', (x ->> 'lng')::double precision,
               'distancia_m', (x ->> 'distancia_m')::int,
               'tipo', nullif(left(trim(x ->> 'tipo'), 40), ''))) as r, ord
        from jsonb_array_elements(case when jsonb_typeof(p) = 'array' then p else '[]'::jsonb end) with ordinality as t(x, ord)
       where nullif(trim(x ->> 'nome'), '') is not null
       order by ord
       limit 3
    ) s;
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
    empresa_id, criada_por, modo_despacho, motoboy_designado_id, teste,
    exige_foto, exige_assinatura, exige_nome, exige_codigo, codigo_entrega,
    exigir_no_local, raio_chegada_m,
    distancia_planejada_m, duracao_planejada_s, rota_planejada, valor, observacoes
  ) values (
    nullif(dados ->> 'empresa_id', '')::uuid,
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
    'empresa_nome', e.nome,
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


-- editar perfil pelo site: foto_url vazia ('') remove a foto
create or replace function public.atualizar_meu_perfil(p_nome text default null, p_foto_url text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if p_nome is not null and length(trim(p_nome)) not between 2 and 60 then
    raise exception 'nome_invalido' using errcode = '22023';
  end if;
  update public.perfis
     set nome = coalesce(nullif(trim(p_nome), ''), nome),
         foto_url = case when p_foto_url = '' then null else coalesce(p_foto_url, foto_url) end
   where id = auth.uid();
  return public.meu_perfil();
end;
$$;

revoke all on all functions in schema privado from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array['public.prever_acrescimo(int)', 'public.registro_membro(uuid, int)',
                           'public.definir_modo_teste(boolean)', 'public.meu_perfil()', 'public.listar_equipe()',
                           'public.oferta_pendente()', 'public.responder_oferta(uuid, boolean)',
                           'public.atualizar_meu_perfil(text, text)', 'public.criar_corrida(jsonb)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
