-- =====================================================================
-- Gestor despacha corridas agendadas com oferta (direto, melhor primeiro ou cascata).
-- Aceitar a oferta de uma agendada = reservar (não começa agora). Rode depois de 20261110000008.
-- =====================================================================

create or replace function public.liberar_rota(p_corrida uuid, p_modo text default null, p_motoboy uuid default null)
returns void language plpgsql security definer set search_path = '' as $$
declare c public.corridas%rowtype;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select * into c from public.corridas where id = p_corrida for update;
  if not found or c.status::text not in ('montada', 'sem_motoboy', 'aguardando_motoboy', 'agendada') or c.motoboy_id is not null then
    raise exception 'rota_nao_pode_ser_liberada' using errcode = '22023';
  end if;
  update public.ofertas set status = 'cancelada' where corrida_id = p_corrida and status = 'pendente';
  if p_motoboy is not null then
    -- agendada ou não: o motoboy escolhido recebe a oferta (na agendada, aceitar = reservar)
    update public.corridas set status = 'aguardando_motoboy', modo_despacho = 'direto', motoboy_designado_id = p_motoboy, rodada = rodada + 1 where id = p_corrida;
    perform privado.evento(p_corrida, 'liberada', jsonb_build_object('modo', 'direto', 'motoboy_id', p_motoboy, 'pelo_gestor', true));
    perform privado.despachar(p_corrida);
    return;
  end if;
  if p_modo is not null then
    if p_modo not in ('quadro', 'melhor_primeiro', 'cascata') then raise exception 'modo_invalido' using errcode = '22023'; end if;
    update public.corridas set status = 'montada' where id = p_corrida;
    -- regra só desta rota: aplica o modo pedido
    if p_modo = 'quadro' then
      update public.corridas set status = case when c.agendada_para is not null then 'agendada' else 'aguardando_motoboy' end::public.status_corrida,
             modo_despacho = 'quadro', quadro_desde = now(), sugerido_motoboy_id = privado.melhor_motoboy(p_corrida) where id = p_corrida;
      perform privado.avisar_quadro(p_corrida);
    else
      update public.corridas set status = 'aguardando_motoboy', modo_despacho = p_modo::public.modo_despacho, rodada = rodada + 1 where id = p_corrida;
      perform privado.despachar(p_corrida);
    end if;
    perform privado.evento(p_corrida, 'liberada', jsonb_build_object('modo', p_modo, 'pelo_gestor', true));
    return;
  end if;
  update public.corridas set status = 'montada' where id = p_corrida;
  perform privado.liberar_rota(p_corrida);
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
  v_expira     timestamptz;
  v_idade      interval := make_interval(mins => privado.cfg_num('posicao_max_min', 15)::int);
  v_raio_max   numeric := privado.cfg_num('raio_max_despacho_km', 0) * 1000;
  v_favoritos  boolean := privado.cfg_bool('favoritos_primeiro', true);
  v_fc         numeric;
begin
  select * into c from public.corridas where id = p_corrida for update;
  if not found or c.status not in ('aguardando_motoboy', 'sem_motoboy') then return; end if;
  if exists (select 1 from public.ofertas where corrida_id = p_corrida and status = 'pendente') then return; end if;
  -- quadro: ninguém recebe oferta, todos veem e o primeiro pega
  if c.modo_despacho::text = 'quadro' then return; end if;
  -- melhor primeiro: já teve a vez dele → vai para o quadro (agendada volta a ser "agendada" para reservar)
  if c.modo_despacho::text = 'melhor_primeiro' and exists (select 1 from public.ofertas where corrida_id = p_corrida) then
    update public.corridas set modo_despacho = 'quadro', quadro_desde = now(),
           status = case when c.agendada_para > now() then 'agendada' else 'aguardando_motoboy' end::public.status_corrida where id = p_corrida;
    perform privado.evento(p_corrida, 'foi_para_o_quadro');
    perform privado.avisar_quadro(p_corrida);
    return;
  end if;
  v_expira := now() + make_interval(secs => case when c.modo_despacho::text = 'melhor_primeiro'
                                                 then privado.pol_num('despacho_melhor_segundos', 45, c.empresa_id, null, c.tipo_pedido)
                                                 else privado.cfg_num('oferta_segundos', 30) end);

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
       and (c.urgente or coalesce(m.raio_km, 0) <= 0 or extensions.st_distance(
              case when m.raio_modo = 'fixo' and m.raio_lat is not null and m.raio_lng is not null
                   then extensions.st_setsrid(extensions.st_makepoint(m.raio_lng, m.raio_lat), 4326)::extensions.geography
                   else m.posicao end,
              v_coleta) <= m.raio_km * 1000)
       and not exists (select 1 from public.ofertas o where o.corrida_id = p_corrida and o.motoboy_id = m.id
                        and (o.rodada = c.rodada or o.status = 'recusada'))
       and not exists (select 1 from public.ofertas o where o.motoboy_id = m.id and o.status = 'pendente')
     order by (f.ordem is null), f.ordem, extensions.st_distance(m.posicao, v_coleta)
     limit 1;
  end if;

  if v_motoboy is null then
    if c.modo_despacho::text = 'melhor_primeiro' or (c.agendada_para > now() and c.modo_despacho::text <> 'direto') then
      update public.corridas set modo_despacho = 'quadro', quadro_desde = now(),
             status = case when c.agendada_para > now() then 'agendada' else 'aguardando_motoboy' end::public.status_corrida where id = p_corrida;
      perform privado.evento(p_corrida, 'foi_para_o_quadro');
      perform privado.avisar_quadro(p_corrida);
      return;
    end if;
    update public.corridas set status = 'sem_motoboy' where id = p_corrida;
    perform privado.evento(p_corrida, 'sem_motoboy');
    return;
  end if;

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

create or replace function privado.reservar_por_oferta(o public.ofertas)
returns void language plpgsql security definer set search_path = '' as $$
declare
  c       public.corridas%rowtype;
  v_folga interval := make_interval(mins => privado.cfg_num('agendada_intervalo_min', 30)::int);
  v_pct   numeric := privado.repasse_de(o.motoboy_id);
  v_valor numeric;
begin
  select * into c from public.corridas where id = o.corrida_id for update;
  if (select count(*) from public.corridas where motoboy_id = o.motoboy_id and status::text = 'reservada')
     >= privado.cfg_num('agendada_max_por_motoboy', 3) then
    raise exception 'limite_de_reservas' using errcode = '22023';
  end if;
  if exists (
    select 1 from public.corridas x
     where x.motoboy_id = o.motoboy_id and x.status::text = 'reservada' and x.id <> c.id
       and tstzrange(x.agendada_para - v_folga, x.agendada_para + make_interval(secs => coalesce(x.duracao_planejada_s, 3600)) + v_folga)
           && tstzrange(c.agendada_para, c.agendada_para + make_interval(secs => coalesce(c.duracao_planejada_s, 3600)))
  ) then
    raise exception 'conflito_de_horario' using errcode = '22023';
  end if;
  v_valor := coalesce(o.valor, c.valor, 0);
  update public.ofertas set status = 'aceita', respondida_em = now() where id = o.id;
  update public.corridas
     set status = 'reservada'::text::public.status_corrida, motoboy_id = o.motoboy_id, reservada_em = now(),
         lembrete_enviado_em = null, atraso_avisado_em = null,
         valor = v_valor, fator_coleta = o.fator_coleta, repasse_pct = v_pct,
         valor_motoboy = round(v_valor * v_pct / 100, 2), valor_gestao = v_valor - round(v_valor * v_pct / 100, 2)
   where id = c.id;
  perform privado.evento(c.id, 'reservada', jsonb_build_object('motoboy_id', o.motoboy_id, 'pela_oferta', true));
end;
$$;

create or replace function public.responder_oferta(p_oferta uuid, p_aceitar boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  o       public.ofertas%rowtype;
  v_pct   numeric;
  v_valor numeric;
begin
  perform privado.checar_versao_app();
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

  -- corrida agendada: aceitar a oferta é reservar (começa no horário)
  if (select agendada_para from public.corridas where id = o.corrida_id) > now() then
    perform privado.reservar_por_oferta(o);
    return privado.corrida_json(o.corrida_id);
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
