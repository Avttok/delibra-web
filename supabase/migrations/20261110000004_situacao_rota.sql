-- =====================================================================
-- "Por que este pedido ainda não virou rota / não foi despachado?"
-- public.situacao_rota(pedido) devolve o motivo em português, para o site e o app
-- mostrarem no detalhe do pedido. Rode depois de 20261110000003.
-- =====================================================================
create or replace function public.situacao_rota(p_pedido uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  p        public.pedidos%rowtype;
  v_antes  interval := make_interval(mins => privado.cfg_num('rota_montar_antes_min', 1440)::int);
  v_espera interval := make_interval(mins => privado.cfg_num('express_agrupar_espera_min', 0)::int);
  v_cron   text;
  v_job    text;
  v_aviso  text;
  v_rotas  jsonb;
  k        record;
  v_modo   text;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select * into p from public.pedidos where id = p_pedido;
  if not found then raise exception 'pedido_nao_encontrado' using errcode = '22023'; end if;

  -- último ciclo automático (pg_cron), se der para ler
  begin
    execute $q$select d.status || coalesce(': ' || nullif(left(d.return_message, 300), ''), '')
                from cron.job_run_details d join cron.job j on j.jobid = d.jobid
               where j.jobname = 'pwex-rotas' order by d.start_time desc limit 1$q$ into v_cron;
  exception when others then v_cron := null;
  end;
  begin
    execute $q$select case when not exists (select 1 from cron.job where jobname = 'pwex-rotas') then 'a tarefa automática “pwex-rotas” não existe no banco'
                           when not exists (select 1 from cron.job where jobname = 'pwex-rotas' and active) then 'a tarefa automática “pwex-rotas” está desativada' end$q$ into v_job;
  exception when others then v_job := 'o pg_cron não está disponível no banco';
  end;

  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'status', c.status, 'modo', c.modo_despacho, 'motoboy', c.motoboy_id) order by c.criada_em), '[]')
    into v_rotas
    from public.corridas c where c.id in (select corrida_id from public.paradas where pedido_id = p.id) and c.status::text <> 'cancelada';

  if p.status = 'recebido' then
    return jsonb_build_object('codigo', 'revisao', 'motivo', 'Esperando a sua revisão: aprove para o pedido entrar nas rotas.', 'rotas', v_rotas, 'ciclo', v_cron);
  end if;
  if p.status in ('concluido', 'cancelado', 'recusado') then
    return jsonb_build_object('codigo', 'finalizado', 'motivo', null, 'rotas', v_rotas, 'ciclo', v_cron);
  end if;

  -- já está numa rota: diz em que pé a rota está
  if jsonb_array_length(v_rotas) > 0 then
    select c.* into k from public.corridas c
     where c.id in (select corrida_id from public.paradas where pedido_id = p.id) and c.status::text <> 'cancelada'
     order by c.criada_em desc limit 1;
    v_modo := privado.pol_txt('despacho_modo', 'quadro', k.empresa_id, null, k.tipo_pedido);
    return jsonb_build_object('rotas', v_rotas, 'ciclo', v_cron, 'codigo', 'rota_' || k.status::text, 'motivo',
      case k.status::text
        when 'montada' then case when v_modo = 'direto'
                                 then 'Rota montada. Despacho no modo “direto”: escolha o motoboy na rota.'
                                 else 'Rota montada, esperando você liberar (a opção “Revisar rotas antes de soltar” está ligada).' end
        when 'agendada' then 'Rota agendada: aparece no quadro dos motoboys para reserva.'
        when 'reservada' then 'Rota reservada por um motoboy.'
        when 'aguardando_motoboy' then 'Rota liberada, esperando um motoboy aceitar.'
        when 'sem_motoboy' then 'Ninguém aceitou a rota ainda (sem motoboy disponível).'
        when 'aceita' then 'Um motoboy aceitou a rota.'
        when 'em_andamento' then 'Rota em andamento.'
        else 'Rota: ' || k.status::text end);
  end if;

  -- aprovado e fora das rotas: procura o bloqueio, na mesma ordem do roteirizador
  if not privado.cfg_bool('roteirizador_ligado', true) then
    return jsonb_build_object('codigo', 'roteirizador_desligado', 'motivo', 'O roteirizador automático está desligado nas Configurações.', 'rotas', v_rotas, 'ciclo', v_cron);
  end if;
  perform privado.usar_regras(coalesce(p.regras, '{}'));
  if p.cobranca = 'pre_pago' and p.pagamento_status is distinct from 'pago'
     and not privado.pol_bool('rotear_sem_pagamento', false, p.empresa_id, null, p.tipo_pedido) then
    perform privado.usar_regras('{}');
    return jsonb_build_object('codigo', 'pagamento', 'motivo', 'Cliente pré-pago: a rota só sai depois que você confirmar o pagamento (PIX/cartão).', 'rotas', v_rotas, 'ciclo', v_cron);
  end if;
  perform privado.usar_regras('{}');
  if not exists (select 1 from public.pedido_pontos where pedido_id = p.id and tipo = 'coleta') then
    return jsonb_build_object('codigo', 'sem_coleta', 'motivo', 'O pedido não tem ponto de coleta.', 'rotas', v_rotas, 'ciclo', v_cron);
  end if;
  if not exists (select 1 from public.pedido_pontos where pedido_id = p.id and tipo = 'entrega' and status = 'pendente') then
    return jsonb_build_object('codigo', 'sem_entrega', 'motivo', 'Nenhuma entrega pendente neste pedido.', 'rotas', v_rotas, 'ciclo', v_cron);
  end if;
  if p.tipo = 'planejado' and p.quando - v_antes > now() then
    return jsonb_build_object('codigo', 'cedo', 'motivo', 'Agendado: a rota é montada ' || privado.cfg_num('rota_montar_antes_min', 1440)::int || ' min antes do horário ('
             || to_char((p.quando - v_antes) at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') || ').', 'rotas', v_rotas, 'ciclo', v_cron);
  end if;
  v_aviso := case when v_job is not null then ' Atenção: ' || v_job || ', então nada é montado sozinho.'
                  when v_cron is not null and v_cron not like 'succeeded%' then ' Atenção, o último ciclo automático falhou: ' || v_cron
                  else '' end;
  if p.tipo = 'express' and coalesce(p.aprovado_em, p.criado_em) > now() - v_espera then
    return jsonb_build_object('codigo', 'espera', 'rotas', v_rotas, 'ciclo', v_cron, 'motivo',
      'Express: esperando ' || privado.cfg_num('express_agrupar_espera_min', 0)::int || ' min para juntar com outros pedidos (monta às '
      || to_char((coalesce(p.aprovado_em, p.criado_em) + v_espera) at time zone 'America/Sao_Paulo', 'HH24:MI')
      || '). “Montar rota agora” monta já, juntando os pedidos que estão esperando.' || v_aviso);
  end if;
  return jsonb_build_object('codigo', 'sem_bloqueio', 'rotas', v_rotas, 'ciclo', v_cron,
    'motivo', 'Nada impede a rota. Use “Montar rota agora”: se der erro, a mensagem aparece aqui.' || v_aviso);
end;
$$;
revoke all on function public.situacao_rota(uuid) from public, anon;
grant execute on function public.situacao_rota(uuid) to authenticated;

-- "Montar rota agora" no modo do próprio pedido (teste ou real)
create or replace function public.roteirizar_pedido(p_pedido uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_teste boolean;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select teste into v_teste from public.pedidos where id = p_pedido;
  if not found then raise exception 'pedido_nao_encontrado' using errcode = '22023'; end if;
  perform set_config('pwex.sem_espera', 'on', true);
  perform privado.roteirizar(v_teste);
  perform set_config('pwex.sem_espera', 'off', true);
  return public.situacao_rota(p_pedido);
end;
$$;
revoke all on function public.roteirizar_pedido(uuid) from public, anon;
grant execute on function public.roteirizar_pedido(uuid) to authenticated;


-- Roteirizador: a regra “Montar rota sem esperar o pagamento” colocada no próprio pedido também vale
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
    if not privado.pol_bool('rota_revisao_gestor', false, (select empresa_id from public.corridas where id = v_id), null,
                            (select tipo_pedido from public.corridas where id = v_id)) then
      perform privado.liberar_rota(v_id);
    end if;
  end loop;
  return v_n;
end;
$$;

-- Botão "Montar rotas": monta já, sem a espera de agrupamento do Express
create or replace function public.roteirizar_agora(p_teste boolean default null)
returns int language plpgsql security definer set search_path = '' as $$
declare v int;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  perform set_config('pwex.sem_espera', 'on', true);
  v := privado.roteirizar(coalesce(p_teste, (select modo_teste from public.perfis where id = auth.uid()), false));
  perform set_config('pwex.sem_espera', 'off', true);
  return v;
end;
$$;
