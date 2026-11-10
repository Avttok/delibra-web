-- =====================================================================
-- Delibra · 0024: cartões do chat, roteirizador por empresa e travas de empresa
--
--  • chat_cartao: o cartão compartilhado no chat mostra o que está acontecendo (status do
--    pedido/rota, motoboy, entregas, cliente…). Gestor vê tudo; motoboy vê o essencial
--    (sem valores nem dados do painel), conforme o ajuste compartilhar_motoboy_resumo.
--  • O roteirizador nunca junta pedidos de empresas diferentes na mesma rota e usa os
--    ajustes da empresa de cada pedido.
--  • Funções que recebem o id de uma rota, pedido, pessoa, cliente ou fatura recusam ids de
--    outra empresa; as listas (equipe, folha, quadro, planejadas, pings) só trazem a sua.
-- =====================================================================
set check_function_bodies = off;

create or replace function public.chat_cartao(p_tipo text, p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_gestor boolean := public.is_gestor();
  v_resumo boolean := not public.is_gestor() and privado.cfg_bool('compartilhar_motoboy_resumo', true);
  v_valores boolean := public.is_gestor() and public.pode('financeiro');
  c public.corridas%rowtype; p public.pedidos%rowtype; e public.empresas%rowtype; pf public.perfis%rowtype;
  v_linhas jsonb := '[]';
  v_titulo text; v_sub text; v_status text; v_cor text; v_lat double precision; v_lng double precision;
  v_prox text; v_feitas int; v_total int;
begin
  if auth.uid() is null then raise exception 'nao_autenticado' using errcode = '28000'; end if;
  if not v_gestor and not v_resumo then return jsonb_build_object('tipo', p_tipo, 'bloqueado', true); end if;
  if p_tipo = 'rota' then
    select * into c from public.corridas where id = p_id;
    if not found or not (public.ve_corrida(p_id) or (not v_gestor and public.ve_org(c.organizacao_id))) then return jsonb_build_object('tipo', p_tipo, 'sem_acesso', true); end if;
    select count(*) filter (where status = 'concluida'), count(*) into v_feitas, v_total from public.paradas where corrida_id = c.id;
    select endereco into v_prox from public.paradas where corrida_id = c.id and status <> 'concluida' order by ordem limit 1;
    select lat, lng into v_lat, v_lng from public.paradas where corrida_id = c.id order by ordem limit 1;
    v_titulo := 'Rota ' || case when c.teste then 'T' else '#' end || c.numero;
    v_status := c.status::text;
    v_linhas := jsonb_build_array(
      jsonb_build_object('icone', 'bike', 'rotulo', 'Motoboy', 'valor', coalesce(public.nome_publico(c.motoboy_id), 'Sem motoboy ainda')),
      jsonb_build_object('icone', 'list-checks', 'rotulo', 'Paradas', 'valor', v_feitas || ' de ' || v_total || ' feitas'),
      jsonb_build_object('icone', 'ruler', 'rotulo', 'Distância', 'valor', round(coalesce(c.distancia_planejada_m, 0) / 1000.0, 1) || ' km'));
    if v_prox is not null then v_linhas := v_linhas || jsonb_build_array(jsonb_build_object('icone', 'map-pin', 'rotulo', 'Próxima', 'valor', split_part(v_prox, ',', 1))); end if;
    if c.agendada_para is not null then v_linhas := v_linhas || jsonb_build_array(jsonb_build_object('icone', 'calendar-clock', 'rotulo', 'Agendada', 'valor', to_char(c.agendada_para at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'))); end if;
    if v_gestor then
      v_linhas := v_linhas || jsonb_build_array(jsonb_build_object('icone', 'building-2', 'rotulo', 'Cliente', 'valor', coalesce((select nome from public.empresas where id = c.empresa_id), c.cliente_nome, 'Avulso')));
      if v_valores then v_linhas := v_linhas || jsonb_build_array(jsonb_build_object('icone', 'wallet', 'rotulo', 'Valor', 'valor', 'R$ ' || replace(to_char(coalesce(c.valor, 0), 'FM999G990D00'), '.', ','))); end if;
    end if;
    v_sub := coalesce(public.nome_publico(c.motoboy_id), '') ;
  elsif p_tipo = 'pedido' then
    select * into p from public.pedidos where id = p_id;
    if not found or not (public.ve_pedido(p_id) or public.ve_org(p.organizacao_id)) then return jsonb_build_object('tipo', p_tipo, 'sem_acesso', true); end if;
    v_titulo := 'Pedido ' || case when p.teste then 'T-' else 'P-' end || p.numero;
    v_status := p.status::text;
    select lat, lng into v_lat, v_lng from public.pedido_pontos where pedido_id = p.id order by ordem limit 1;
    v_linhas := jsonb_build_array(
      jsonb_build_object('icone', 'building-2', 'rotulo', 'Cliente', 'valor', coalesce((select nome from public.empresas where id = p.empresa_id), p.cliente_nome, 'Avulso')),
      jsonb_build_object('icone', 'package', 'rotulo', 'Entregas', 'valor', (select count(*) from public.pedido_pontos where pedido_id = p.id and tipo = 'entrega')::text),
      jsonb_build_object('icone', 'clock', 'rotulo', case when p.tipo = 'planejado' then 'Para' else 'Feito' end,
                         'valor', to_char(coalesce(p.quando, p.criado_em) at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI')));
    if v_valores then v_linhas := v_linhas || jsonb_build_array(jsonb_build_object('icone', 'wallet', 'rotulo', 'Valor', 'valor', 'R$ ' || replace(to_char(coalesce(p.valor, 0), 'FM999G990D00'), '.', ','))); end if;
    v_sub := coalesce((select nome from public.empresas where id = p.empresa_id), p.cliente_nome);
  elsif p_tipo = 'cliente' then
    select * into e from public.empresas where id = p_id;
    if not found or not public.ve_org(e.organizacao_id) then return jsonb_build_object('tipo', p_tipo, 'sem_acesso', true); end if;
    v_titulo := e.nome; v_lat := e.lat; v_lng := e.lng;
    v_linhas := jsonb_build_array(jsonb_build_object('icone', 'map-pin', 'rotulo', 'Endereço', 'valor', coalesce(e.endereco, '—')));
    if e.instrucoes_coleta is not null then v_linhas := v_linhas || jsonb_build_array(jsonb_build_object('icone', 'info', 'rotulo', 'Na coleta', 'valor', e.instrucoes_coleta)); end if;
    if v_gestor then
      v_linhas := v_linhas || jsonb_build_array(
        jsonb_build_object('icone', 'phone', 'rotulo', 'Telefone', 'valor', coalesce(e.telefone, '—')),
        jsonb_build_object('icone', 'clipboard-list', 'rotulo', 'Pedidos abertos', 'valor',
          (select count(*) from public.pedidos x where x.empresa_id = e.id and x.status in ('recebido', 'aprovado', 'roteirizado', 'em_rota'))::text));
    end if;
    v_sub := case when v_gestor then coalesce(e.nome_fantasia, e.razao_social) else null end;
  elsif p_tipo = 'pessoa' then
    select * into pf from public.perfis where id = p_id;
    if not found or not public.ve_pessoa(p_id) then return jsonb_build_object('tipo', p_tipo, 'sem_acesso', true); end if;
    v_titulo := public.nome_publico(pf.id);
    v_status := (select m.status::text from public.motoboys m where m.id = pf.id);
    v_linhas := jsonb_build_array(jsonb_build_object('icone', 'shield-check', 'rotulo', 'Cargo', 'valor',
      case when 'dev' = any (pf.papeis) then 'Dev' when 'gestor' = any (pf.papeis) then 'Gestor' when 'supervisor' = any (pf.papeis) then 'Supervisor'
           when 'motoboy' = any (pf.papeis) then 'Motoboy' else 'Cliente' end));
    if v_gestor and v_status is not null then
      v_linhas := v_linhas || jsonb_build_array(jsonb_build_object('icone', 'route', 'rotulo', 'Rotas hoje', 'valor',
        (select count(*) from public.corridas k where k.motoboy_id = pf.id and k.status = 'concluida' and privado.dia_local(k.concluida_em) = privado.dia_local(now()))::text));
    end if;
    return jsonb_build_object('tipo', p_tipo, 'titulo', v_titulo, 'foto', public.foto_publica(pf.id), 'oculto', public.dev_oculto_para_mim(pf.id),
                              'status', v_status, 'linhas', v_linhas, 'resumo', not v_gestor);
  else
    return jsonb_build_object('tipo', p_tipo);
  end if;
  return jsonb_build_object('tipo', p_tipo, 'titulo', v_titulo, 'sub', v_sub, 'status', v_status, 'linhas', v_linhas,
                            'lat', v_lat, 'lng', v_lng, 'resumo', not v_gestor);
end;
$$;
grant execute on function public.chat_cartao(text, uuid) to authenticated;

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
           p.id pedido_id, p.organizacao_id org, p.empresa_id, p.tipo, p.tipo_pedido, p.quando, p.urgente, p.observacoes,
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
    -- ajustes e a rota nova ficam na empresa deste pedido
    perform set_config('pwex.org', coalesce(t.org::text, ''), true);
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
         and k.organizacao_id is not distinct from t.org
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

create or replace function public.listar_equipe()
returns table (id uuid, email text, nome text, foto_url text, papeis public.papel_usuario[],
               status public.status_motoboy, modo_teste boolean, repasse_pct numeric, criado_em timestamptz,
               bloqueado boolean, ultimo_acesso timestamptz)
language sql stable security definer set search_path = '' as $$
  select p.id, u.email::text, p.nome, p.foto_url, p.papeis, m.status, coalesce(m.modo_teste, p.modo_teste), m.repasse_pct, p.criado_em,
         coalesce(u.banned_until > now(), false), u.last_sign_in_at
    from public.perfis p
    join auth.users u on u.id = p.id
    left join public.motoboys m on m.id = p.id
   where public.is_gestor() and public.ve_pessoa(p.id)
     and not (cardinality(p.papeis) = 0
              and exists (select 1 from public.cadastros_cliente c where c.perfil_id = p.id and c.status in ('pendente', 'recusado')))
   order by p.nome;
$$;

create or replace function public.clientes_avulsos()
returns table (nome text, corridas bigint, ultima timestamptz)
language sql stable security definer set search_path = '' as $$
  select cliente_nome, count(*), max(criada_em)
    from public.corridas
   where public.is_gestor() and public.ve_org(organizacao_id) and empresa_id is null and cliente_nome is not null
   group by cliente_nome
   order by max(criada_em) desc
   limit 200;
$$;

create or replace function public.folha(p_inicio date, p_fim date, p_teste boolean default false)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(x order by x ->> 'nome') from (
      select jsonb_build_object(
        'motoboy_id', pf.id, 'nome', pf.nome, 'foto_url', pf.foto_url,
        'rotas', count(c.id), 'entregas', coalesce(sum((c.pag_calculo ->> 'entregas')::int), 0),
        'km', round(coalesce(sum(coalesce(c.distancia_real_m, c.distancia_planejada_m, 0)), 0) / 1000.0, 1),
        'calculado', coalesce(sum((c.pag_calculo ->> 'total')::numeric), 0),
        'ajustes_rotas', coalesce(sum(c.pag_ajuste), 0),
        'ajustes', coalesce((select sum(a.valor) from public.holerites h join public.holerite_ajustes a on a.holerite_id = h.id
                              where h.motoboy_id = pf.id and h.teste = p_teste and h.inicio = p_inicio and h.fim = p_fim), 0),
        'faturado', coalesce(sum(c.valor), 0),
        'holerite', (select to_jsonb(h) from public.holerites h where h.motoboy_id = pf.id and h.teste = p_teste and h.inicio = p_inicio and h.fim = p_fim),
        'chave_pix', (select jsonb_build_object('tipo', k.tipo_chave, 'chave', k.chave, 'titular', k.titular) from public.chaves_pix k where k.usuario_id = pf.id and k.principal limit 1)
      ) x
      from public.perfis pf
      left join public.corridas c on c.motoboy_id = pf.id and c.status = 'concluida' and c.teste = p_teste and public.ve_org(c.organizacao_id)
                                 and privado.dia_local(c.concluida_em) between p_inicio and p_fim
     where 'motoboy' = any (pf.papeis) and public.ve_pessoa(pf.id)
     group by pf.id
    ) t
  ), '[]'::jsonb);
end;
$$;

create or replace function public.rotas_disponiveis()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  m  public.motoboys%rowtype;
begin
  perform privado.checar_versao_app();
  if not public.tem_papel('motoboy'::public.papel_usuario) then raise exception 'apenas_motoboy' using errcode = '42501'; end if;
  select * into m from public.motoboys where id = auth.uid();
  return coalesce((
    select jsonb_agg(privado.corrida_json(c.id) || jsonb_build_object(
             'planejada', c.agendada_para is not null,
             'sugerida', c.sugerido_motoboy_id = auth.uid(),
             'distancia_ate_coleta_m', round(privado.dist_m(m.lat, m.lng, col.lat, col.lng)),
             'no_quadro_desde', c.quadro_desde)
           order by (c.sugerido_motoboy_id = auth.uid()) desc, c.urgente desc, coalesce(c.agendada_para, c.quadro_desde, c.criada_em))
      from public.corridas c
      join lateral (select lat, lng from public.paradas where corrida_id = c.id order by ordem limit 1) col on true
     where c.motoboy_id is null and c.teste = coalesce(m.modo_teste, false)
       and public.org_alcanca(c.organizacao_id, (select organizacao_id from public.perfis where id = auth.uid()), c.quadro_desde)
       and ((c.status::text in ('aguardando_motoboy', 'sem_motoboy') and c.modo_despacho::text = 'quadro')
            or (c.status::text = 'agendada' and c.agendada_para > now()))
       and (c.agendada_para is not null or c.urgente or coalesce(m.raio_km, 0) <= 0 or m.lat is null or privado.dist_m(
              case when m.raio_modo = 'fixo' and m.raio_lat is not null then m.raio_lat else m.lat end,
              case when m.raio_modo = 'fixo' and m.raio_lng is not null then m.raio_lng else m.lng end, col.lat, col.lng) <= m.raio_km * 1000)
  ), '[]'::jsonb);
end;
$$;

create or replace function public.corridas_planejadas()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_teste boolean := coalesce((select modo_teste from public.motoboys where id = auth.uid()), false);
begin
  perform privado.checar_versao_app();
  if not public.tem_papel('motoboy'::public.papel_usuario) then raise exception 'apenas_motoboy' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(privado.corrida_json(c.id) || jsonb_build_object('minha', coalesce(c.motoboy_id = auth.uid(), false)) order by c.agendada_para)
      from public.corridas c
     where c.agendada_para is not null and c.teste = v_teste
       and (c.motoboy_id = auth.uid() or public.org_alcanca(c.organizacao_id, (select organizacao_id from public.perfis where id = auth.uid()), c.quadro_desde))
       and ((c.status::text = 'agendada' and c.agendada_para > now())
            or (c.status::text = 'reservada' and c.motoboy_id = auth.uid()))
  ), '[]'::jsonb);
end;
$$;

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
     and (not v_gestor or public.ve_pessoa(l.motoboy_id))
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
     and (not v_gestor or public.ve_corrida(c.id))
     and not exists (select 1 from public.localizacoes l where l.corrida_id = c.id);

  return jsonb_build_object('pings', v_pings, 'legado', v_legado);
end;
$$;

create or replace function public.ve_org(p_org uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select auth.uid() is null
      or (public.is_dev() and (public.minha_org() is null or p_org is not distinct from public.minha_org()))
      or (p_org is not distinct from public.minha_org());
$$;

create or replace function public.registrar_cadastro(d jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_modo text; v_id uuid; v_doc text; v_org uuid;
begin
  if not privado.eh_servico() then raise exception 'apenas_servidor' using errcode = '42501'; end if;
  -- empresa (transportadora) do cadastro: a do link (?empresa=slug) ou, se só existir uma ativa, ela
  v_org := coalesce((select o.id from public.organizacoes o where o.slug = nullif(lower(d ->> 'empresa'), '') and o.status in ('ativa', 'teste')),
                    (select o.id from public.organizacoes o where o.status in ('ativa', 'teste') having count(*) = 1 group by o.id limit 1));
  if v_org is null and exists (select 1 from public.organizacoes) then raise exception 'empresa_obrigatoria' using errcode = '22023'; end if;
  perform set_config('pwex.org', coalesce(v_org::text, ''), true);
  if v_org is not null and nullif(d ->> 'perfil_id', '') is not null then update public.perfis set organizacao_id = v_org where id = (d ->> 'perfil_id')::uuid and organizacao_id is null; end if;
  v_modo := privado.cfg_txt('cadastro_cliente_modo', 'aprovacao');
  if v_modo = 'desligado' then raise exception 'cadastro_desligado' using errcode = '42501'; end if;
  v_doc := nullif(regexp_replace(coalesce(d ->> 'documento', ''), '[^0-9]', '', 'g'), '');
  if v_doc is not null and length(v_doc) not in (11, 14) then raise exception 'documento_invalido' using errcode = '22023'; end if;
  insert into public.cadastros_cliente (perfil_id, email, nome, responsavel, tipo, documento, telefone, endereco, lat, lng, observacoes)
  values (nullif(d ->> 'perfil_id', '')::uuid, lower(trim(d ->> 'email')), left(trim(d ->> 'nome'), 120), nullif(left(trim(coalesce(d ->> 'responsavel', '')), 80), ''),
          case when length(coalesce(v_doc, '')) = 11 then 'pf' else 'pj' end, v_doc, nullif(left(trim(coalesce(d ->> 'telefone', '')), 30), ''),
          nullif(left(trim(coalesce(d ->> 'endereco', '')), 300), ''), nullif(d ->> 'lat', '')::double precision, nullif(d ->> 'lng', '')::double precision,
          nullif(left(trim(coalesce(d ->> 'observacoes', '')), 500), ''))
  returning id into v_id;
  if v_modo = 'instantaneo' then perform privado.aprovar_cadastro(v_id); end if;
  return (select jsonb_build_object('id', c.id, 'status', c.status) from public.cadastros_cliente c where c.id = v_id);
end;
$$;

create or replace function public.ajustar_pagamento_rota(p_corrida uuid, p_ajuste numeric, p_motivo text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c public.corridas%rowtype; v_per record;
begin
  -- outra empresa: recusa
  if p_corrida is not null and not public.ve_corrida(p_corrida) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select * into c from public.corridas where id = p_corrida for update;
  if not found or c.motoboy_id is null then raise exception 'rota_sem_motoboy' using errcode = '22023'; end if;
  if coalesce(p_ajuste, 0) <> 0 and coalesce(trim(p_motivo), '') = '' then raise exception 'informe_o_motivo' using errcode = '22023'; end if;
  if c.concluida_em is not null then
    select * into v_per from privado.periodo_holerite(c.motoboy_id, privado.dia_local(c.concluida_em));
    if exists (select 1 from public.holerites where motoboy_id = c.motoboy_id and teste = c.teste and inicio = v_per.inicio and fim = v_per.fim and status <> 'aberto') then
      raise exception 'holerite_fechado' using errcode = '22023';
    end if;
  end if;
  update public.corridas set pag_ajuste = round(coalesce(p_ajuste, 0), 2), pag_ajuste_motivo = nullif(trim(p_motivo), '') where id = p_corrida;
  perform privado.evento(p_corrida, 'pagamento_ajustado', jsonb_build_object('ajuste', p_ajuste, 'motivo', p_motivo));
  return (select jsonb_build_object('valor_motoboy', valor_motoboy, 'pag_calculo', pag_calculo, 'pag_ajuste', pag_ajuste) from public.corridas where id = p_corrida);
end;
$$;

create or replace function public.ajuste_holerite(p_motoboy uuid, p_inicio date, p_fim date, p_descricao text, p_valor numeric, p_teste boolean default false)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_h uuid; v_id uuid;
begin
  -- outra empresa: recusa
  if p_motoboy is not null and not public.ve_pessoa(p_motoboy) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if coalesce(trim(p_descricao), '') = '' or coalesce(p_valor, 0) = 0 then raise exception 'ajuste_invalido' using errcode = '22023'; end if;
  v_h := privado.holerite_aberto(p_motoboy, p_inicio, p_fim, p_teste);
  insert into public.holerite_ajustes (holerite_id, descricao, valor, criado_por) values (v_h, left(trim(p_descricao), 200), round(p_valor, 2), auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.apagar_historico(
  p_senha text, p_teste boolean, p_corridas boolean, p_percursos boolean,
  p_motoboy uuid default null, p_ate timestamptz default null, p_motivo text default null
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_erro     jsonb;
  v_ids      uuid[];
  v_arquivos text[] := '{}';
  v_corridas int := 0;
  v_pings    int := 0;
begin
  -- outra empresa: recusa
  if p_motoboy is not null and not public.ve_pessoa(p_motoboy) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if not coalesce(p_corridas, false) and not coalesce(p_percursos, false) then raise exception 'nada_para_excluir' using errcode = '22023'; end if;
  if p_motoboy is not null and not public.pode_gerenciar(p_motoboy) then raise exception 'sem_permissao' using errcode = '42501'; end if;

  v_erro := privado.senha_com_limite(p_senha);
  if v_erro is not null then return v_erro; end if;

  if p_corridas then
    select coalesce(array_agg(id), '{}') into v_ids from privado.corridas_do_historico(p_teste, p_motoboy, p_ate) id;
    if cardinality(v_ids) > 0 then
      insert into public.registro_exclusoes (corrida_id, numero, teste, status, valor, copia, motivo, excluida_por)
      select c.id, c.numero, c.teste, c.status::text, c.valor,
             jsonb_build_object(
               'corrida', to_jsonb(c),
               'paradas', coalesce((select jsonb_agg(to_jsonb(p) order by p.ordem) from public.paradas p where p.corrida_id = c.id), '[]'),
               'eventos', coalesce((select jsonb_agg(to_jsonb(e) order by e.criado_em) from public.eventos_corrida e where e.corrida_id = c.id), '[]')
             ),
             coalesce(nullif(trim(p_motivo), ''), 'Limpeza de histórico'), auth.uid()
        from public.corridas c where c.id = any (v_ids);

      select coalesce(array_agg(a), '{}') into v_arquivos
        from (select foto_path a from public.paradas where corrida_id = any (v_ids) and foto_path is not null
              union all
              select assinatura_path from public.paradas where corrida_id = any (v_ids) and assinatura_path is not null) t;

      delete from public.localizacoes where corrida_id = any (v_ids);
      delete from public.corridas where id = any (v_ids);
      get diagnostics v_corridas = row_count;
    end if;
  end if;

  if p_percursos then
    delete from public.localizacoes where id in (select privado.pings_do_historico(p_teste, p_motoboy, p_ate));
    get diagnostics v_pings = row_count;
  end if;

  return jsonb_build_object('corridas', v_corridas, 'pings', v_pings, 'arquivos', to_jsonb(v_arquivos));
end;
$$;

create or replace function public.aplicar_otimizacao(p_corrida uuid, p_ordem uuid[], p_rua int[], p_acum int[], p_total int, p_duracao int, p_polyline text)
returns void language plpgsql security definer set search_path = '' as $$
declare i int;
begin
  -- outra empresa: recusa
  if p_corrida is not null and not public.ve_corrida(p_corrida) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if not (public.is_gestor() or privado.eh_servico()) then
    raise exception 'apenas_gestor' using errcode = '42501';
  end if;
  if exists (select 1 from public.paradas where corrida_id = p_corrida and status <> 'pendente') then return; end if;
  if (select count(*) from public.paradas where corrida_id = p_corrida) <> coalesce(array_length(p_ordem, 1), 0) then return; end if;
  if exists (select 1 from unnest(p_ordem) u where not exists (select 1 from public.paradas x where x.id = u and x.corrida_id = p_corrida)) then return; end if;
  update public.paradas set ordem = ordem + 100000 where corrida_id = p_corrida;
  for i in 1 .. array_length(p_ordem, 1) loop
    update public.paradas set ordem = i - 1,
           dist_rua_m = case when tipo = 'entrega' then p_rua[i] end, dist_acum_m = p_acum[i]
     where id = p_ordem[i];
  end loop;
  update public.corridas set distancia_planejada_m = p_total, duracao_planejada_s = p_duracao, rota_planejada = p_polyline, otimizada_em = now()
   where id = p_corrida;
  perform privado.valores_rota(p_corrida);
end;
$$;

create or replace function public.aprovar_e_montar(p_pedido uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p public.pedidos%rowtype; v_r jsonb;
begin
  -- outra empresa: recusa
  if p_pedido is not null and not public.ve_pedido(p_pedido) then raise exception 'sem_permissao' using errcode = '42501'; end if;
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

create or replace function public.avancar_parada(p_parada uuid, p_acao text, p_dados jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  p          public.paradas%rowtype;
  c          public.corridas%rowtype;
  v_atual    int;
  v_dados    jsonb := coalesce(p_dados, '{}');
  v_dist     double precision;
  v_tol      double precision;
  v_ignorar  boolean := false;
  v_ex       jsonb;
begin
  -- outra empresa: recusa
  if p_parada is not null and not public.ve_corrida((select tv_par.corrida_id from public.paradas tv_par where tv_par.id = p_parada)) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  perform privado.checar_versao_app();
  select * into p from public.paradas where id = p_parada for update;
  if not found then raise exception 'parada_nao_encontrada' using errcode = '22023'; end if;
  select * into c from public.corridas where id = p.corrida_id for update;
  if c.motoboy_id is distinct from auth.uid() or c.status not in ('aceita', 'em_andamento') then
    raise exception 'corrida_nao_esta_ativa' using errcode = '22023';
  end if;
  if p_acao not in ('chegou', 'concluir') then raise exception 'acao_invalida' using errcode = '22023'; end if;

  select min(ordem) into v_atual from public.paradas where corrida_id = c.id and status <> 'concluida';
  if p.ordem <> v_atual then raise exception 'conclua_a_parada_anterior' using errcode = '22023'; end if;

  -- presença no local
  select d.distancia_m, d.tolerancia_m into v_dist, v_tol from privado.distancia_ate_parada(p, v_dados, auth.uid()) d;
  if c.exigir_no_local then
    v_ignorar := coalesce((v_dados ->> 'ignorar_local')::boolean, false)
                 and c.teste and public.is_gestor()
                 and privado.cfg_bool('teste_admin_ignora_local', true);
    if not v_ignorar then
      if v_dist is null then
        raise exception 'sem_localizacao' using errcode = '22023';
      end if;
      if v_dist - v_tol > c.raio_chegada_m then
        raise exception 'longe_do_local:%:%', round(v_dist), c.raio_chegada_m using errcode = '22023';
      end if;
    end if;
  end if;

  if c.status = 'aceita' then
    update public.corridas set status = 'em_andamento', iniciada_em = now() where id = c.id;
  end if;

  if p_acao = 'chegou' then
    update public.paradas
       set status = 'chegou', chegou_em = now(),
           distancia_chegada_m = round(v_dist), local_ignorado = v_ignorar
     where id = p.id;
    perform privado.evento(c.id, 'chegou', jsonb_build_object(
      'parada', p.ordem, 'tipo', p.tipo, 'distancia_m', round(v_dist), 'local_ignorado', v_ignorar));
    return privado.corrida_json(c.id);
  end if;

  -- concluir: o que esta parada exige (o que o cliente pediu no ponto, ou o padrão da rota nas entregas)
  v_ex := privado.exige_parada(p, c);
  if (v_ex ->> 'nome')::boolean and coalesce(trim(v_dados ->> 'recebedor_nome'), '') = '' then
    raise exception 'informe_o_nome_de_quem_recebeu' using errcode = '22023';
  end if;
  if (v_ex ->> 'codigo')::boolean and coalesce(v_dados ->> 'codigo', '') <> coalesce(p.codigo, c.codigo_entrega, '') then
    raise exception 'codigo_incorreto' using errcode = '22023';
  end if;
  if (v_ex ->> 'foto')::boolean and coalesce(v_dados ->> 'foto_path', '') = '' then
    raise exception 'falta_a_foto' using errcode = '22023';
  end if;
  if (v_ex ->> 'assinatura')::boolean and coalesce(v_dados ->> 'assinatura_path', '') = '' then
    raise exception 'falta_a_assinatura' using errcode = '22023';
  end if;

  update public.paradas
     set status = 'concluida',
         chegou_em = coalesce(chegou_em, now()),
         concluida_em = now(),
         distancia_chegada_m = coalesce(distancia_chegada_m, round(v_dist)),
         local_ignorado = local_ignorado or v_ignorar,
         recebedor_nome = nullif(trim(v_dados ->> 'recebedor_nome'), ''),
         foto_path = nullif(v_dados ->> 'foto_path', ''),
         assinatura_path = nullif(v_dados ->> 'assinatura_path', '')
   where id = p.id;
  perform privado.evento(c.id, 'parada_concluida', jsonb_build_object(
    'parada', p.ordem, 'tipo', p.tipo, 'distancia_m', round(v_dist), 'local_ignorado', v_ignorar));

  update public.paradas set status = 'a_caminho'
   where corrida_id = c.id
     and ordem = (select min(ordem) from public.paradas where corrida_id = c.id and status = 'pendente');

  if not exists (select 1 from public.paradas where corrida_id = c.id and status <> 'concluida') then
    update public.corridas set status = 'concluida', concluida_em = now() where id = c.id;
    update public.motoboys set status = 'disponivel', status_em = now() where id = c.motoboy_id;
    perform privado.finalizar_trajeto(c.id, false);
    perform privado.evento(c.id, 'concluida');
    return null;
  end if;

  return privado.corrida_json(c.id);
end;
$$;

create or replace function public.cancelar_corrida(p_corrida uuid, p_motivo text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  c public.corridas%rowtype;
begin
  -- outra empresa: recusa
  if p_corrida is not null and not public.ve_corrida(p_corrida) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select * into c from public.corridas where id = p_corrida for update;
  if not found or c.status in ('concluida', 'cancelada') then return; end if;

  update public.ofertas set status = 'cancelada', respondida_em = now()
   where corrida_id = p_corrida and status = 'pendente';
  update public.corridas set status = 'cancelada', cancelada_em = now() where id = p_corrida;

  if c.motoboy_id is not null then
    update public.motoboys set status = 'disponivel', status_em = now()
     where id = c.motoboy_id and status = 'em_corrida';
    perform privado.enviar_push(c.motoboy_id,
      jsonb_build_object('tipo', 'cancelada', 'corrida_id', p_corrida::text));
  end if;
  perform privado.evento(p_corrida, 'cancelada', jsonb_build_object('motivo', p_motivo));
end;
$$;

create or replace function public.cancelar_pedido(p_pedido uuid, p_motivo text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare p public.pedidos%rowtype;
begin
  -- outra empresa: recusa
  if p_pedido is not null and not public.ve_pedido(p_pedido) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  select * into p from public.pedidos where id = p_pedido for update;
  if not found or not (public.is_gestor() or (p.empresa_id is not null and p.empresa_id = privado.minha_empresa())) then
    raise exception 'pedido_nao_encontrado' using errcode = '22023';
  end if;
  if p.status in ('concluido', 'cancelado', 'recusado') then raise exception 'pedido_finalizado' using errcode = '22023'; end if;
  if not public.is_gestor() and not privado.pol_bool('cliente_pode_cancelar', true, p.empresa_id) then raise exception 'cliente_nao_cancela' using errcode = '42501'; end if;
  if exists (select 1 from public.paradas x join public.corridas c on c.id = x.corrida_id
              where x.pedido_id = p.id and c.status::text in ('aceita', 'em_andamento', 'concluida')) then
    raise exception 'pedido_em_andamento' using errcode = '22023';
  end if;
  if not public.is_gestor() and exists (select 1 from public.paradas x join public.corridas c on c.id = x.corrida_id
                                         where x.pedido_id = p.id and c.status::text = 'reservada') then
    raise exception 'pedido_em_andamento' using errcode = '22023';
  end if;
  perform privado.tirar_das_rotas(p.id);
  update public.pedidos set status = 'cancelado', cancelado_em = now() where id = p.id;
  update public.pedido_pontos set status = 'cancelado' where pedido_id = p.id and status <> 'concluido';
  perform privado.evento_pedido(p.id, 'cancelado', jsonb_build_object('motivo', p_motivo, 'por_cliente', not public.is_gestor()));
end;
$$;

create or replace function public.confirmar_pagamento(p_corrida uuid, p_metodo text default null, p_ref text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare c public.corridas%rowtype;
begin
  -- outra empresa: recusa
  if p_corrida is not null and not public.ve_corrida(p_corrida) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if not public.is_gestor() and current_user not in ('service_role', 'postgres') then
    raise exception 'apenas_gestor' using errcode = '42501';
  end if;
  select * into c from public.corridas where id = p_corrida for update;
  if not found then raise exception 'corrida_inexistente' using errcode = '22023'; end if;
  if c.status::text <> 'aguardando_pagamento' then raise exception 'nao_aguarda_pagamento' using errcode = '22023'; end if;
  update public.corridas
     set pagamento_status = 'pago', pago_em = now(), pagamento_metodo = coalesce(p_metodo, pagamento_metodo), pagamento_ref = p_ref,
         status = (case when c.agendada_para is not null then 'agendada' else 'aguardando_motoboy' end)::public.status_corrida
   where id = p_corrida;
  perform privado.evento(p_corrida, 'pagamento_confirmado', jsonb_build_object('metodo', p_metodo, 'por', auth.uid()));
  if c.agendada_para is not null then
    perform privado.avisar_planejada(p_corrida, 'planejada_nova', null);
  else
    perform privado.despachar(p_corrida);
  end if;
end;
$$;

create or replace function public.confirmar_pagamento_pedido(p_pedido uuid, p_metodo text default null, p_ref text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare v_teste boolean;
begin
  -- outra empresa: recusa
  if p_pedido is not null and not public.ve_pedido(p_pedido) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if not (public.is_gestor() or privado.eh_servico()) then
    raise exception 'apenas_gestor' using errcode = '42501';
  end if;
  update public.pedidos set pagamento_status = 'pago', pago_em = now(), pagamento_metodo = coalesce(p_metodo, pagamento_metodo), pagamento_ref = p_ref
   where id = p_pedido and pagamento_status = 'pendente' returning teste into v_teste;
  if not found then raise exception 'pagamento_nao_pendente' using errcode = '22023'; end if;
  perform privado.evento_pedido(p_pedido, 'pago', jsonb_build_object('metodo', p_metodo));
  perform privado.roteirizar(v_teste);
end;
$$;

create or replace function public.definir_regras_pedido(p_pedido uuid, p_regras jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p public.pedidos%rowtype;
begin
  -- outra empresa: recusa
  if p_pedido is not null and not public.ve_pedido(p_pedido) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select * into p from public.pedidos where id = p_pedido for update;
  if not found then raise exception 'pedido_nao_encontrado' using errcode = '22023'; end if;
  update public.pedidos set regras = privado.limpar_regras(p_regras) where id = p.id;
  perform privado.evento_pedido(p.id, 'regras', jsonb_build_object('regras', privado.limpar_regras(p_regras)));
  if p.status in ('recebido', 'aprovado') then perform public.revisar_pedido(p.id, 'recalcular'); end if;
  return (select to_jsonb(x) from public.pedidos x where x.id = p.id);
end;
$$;

create or replace function public.definir_regras_rota(p_corrida uuid, p_regras jsonb, p_motivo text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c public.corridas%rowtype; v_r jsonb;
begin
  -- outra empresa: recusa
  if p_corrida is not null and not public.ve_corrida(p_corrida) then raise exception 'sem_permissao' using errcode = '42501'; end if;
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

create or replace function public.definir_regras_rota_pedido(p_pedido uuid, p_regras jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p public.pedidos%rowtype; v jsonb := coalesce(privado.limpar_regras(p_regras), '{}');
begin
  -- outra empresa: recusa
  if p_pedido is not null and not public.ve_pedido(p_pedido) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if not public.is_gestor() or not public.pode('pedidos') then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select * into p from public.pedidos where id = p_pedido for update;
  if not found then raise exception 'pedido_nao_encontrado' using errcode = '22023'; end if;
  update public.pedidos set regras_rota = v where id = p_pedido;
  perform privado.evento_pedido(p_pedido, 'regras_rota', jsonb_build_object('regras', v));
  insert into public.decisoes_rota (por, acao, pedido_id, empresa_id, tipo_pedido, dados)
  values (auth.uid(), 'regras', p_pedido, p.empresa_id, p.tipo_pedido, jsonb_build_object('regras', v, 'antes_de_aprovar', true));
  -- rotas que já existem e ainda não têm regras próprias recebem estas
  update public.corridas c set pag_regras = v
   where c.id in (select x.corrida_id from public.paradas x where x.pedido_id = p_pedido)
     and c.status::text in ('montada', 'agendada', 'aguardando_motoboy', 'sem_motoboy')
     and coalesce(c.pag_regras, '{}') = coalesce(p.regras_rota, '{}');
  return v;
end;
$$;

create or replace function public.definir_repasse(p_motoboy uuid, p_pct numeric)
returns void language plpgsql security definer set search_path = '' as $$
begin
  -- outra empresa: recusa
  if p_motoboy is not null and not public.ve_pessoa(p_motoboy) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if p_pct is not null and (p_pct < 0 or p_pct > 100) then raise exception 'percentual_invalido' using errcode = '22023'; end if;
  update public.motoboys set repasse_pct = p_pct where id = p_motoboy;
end;
$$;

create or replace function public.definir_valor_rota(p_corrida uuid, p_valor numeric, p_motivo text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare c public.corridas%rowtype;
begin
  -- outra empresa: recusa
  if p_corrida is not null and not public.ve_corrida(p_corrida) then raise exception 'sem_permissao' using errcode = '42501'; end if;
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

create or replace function public.editar_fatura(p_fatura uuid, p_acao text, p_ajuste numeric default null, p_motivo text default null,
                                                p_vencimento date default null, p_metodo text default null, p_pedido uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare f public.faturas%rowtype;
begin
  -- outra empresa: recusa
  if p_fatura is not null and not public.ve_org((select tv_fat.organizacao_id from public.faturas tv_fat where tv_fat.id = p_fatura)) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if p_pedido is not null and not public.ve_pedido(p_pedido) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select * into f from public.faturas where id = p_fatura for update;
  if not found then raise exception 'fatura_nao_encontrada' using errcode = '22023'; end if;
  if p_acao = 'ajustar' then
    if f.status not in ('rascunho', 'emitida') then raise exception 'fatura_fechada' using errcode = '22023'; end if;
    if coalesce(p_ajuste, 0) <> 0 and coalesce(trim(p_motivo), '') = '' then raise exception 'informe_o_motivo' using errcode = '22023'; end if;
    update public.faturas set ajuste = round(coalesce(p_ajuste, 0), 2), ajuste_motivo = nullif(trim(p_motivo), ''),
           vencimento = coalesce(p_vencimento, vencimento) where id = f.id;
    perform privado.totalizar_fatura(f.id);
  elsif p_acao = 'tirar_pedido' then
    if f.status <> 'rascunho' then raise exception 'so_no_rascunho' using errcode = '22023'; end if;
    update public.pedidos set fatura_id = null where id = p_pedido and fatura_id = f.id;
    perform privado.totalizar_fatura(f.id);
  elsif p_acao = 'emitir' then
    if f.status <> 'rascunho' then raise exception 'so_no_rascunho' using errcode = '22023'; end if;
    update public.faturas set status = 'emitida', emitida_em = now(), vencimento = coalesce(p_vencimento, vencimento) where id = f.id;
  elsif p_acao = 'paga' then
    if f.status <> 'emitida' then raise exception 'emita_antes' using errcode = '22023'; end if;
    update public.faturas set status = 'paga', paga_em = now(), pagamento_metodo = p_metodo where id = f.id;
    update public.pedidos set pagamento_status = 'pago', pago_em = now(), pagamento_metodo = coalesce(p_metodo, pagamento_metodo) where fatura_id = f.id;
  elsif p_acao = 'cancelar' then
    if f.status = 'paga' then raise exception 'fatura_paga' using errcode = '22023'; end if;
    update public.pedidos set fatura_id = null where fatura_id = f.id;
    update public.faturas set status = 'cancelada' where id = f.id;
  else
    raise exception 'acao_invalida' using errcode = '22023';
  end if;
  return (select to_jsonb(x) from public.faturas x where x.id = f.id);
end;
$$;

create or replace function public.editar_membro(p_usuario uuid, p_nome text, p_papeis public.papel_usuario[], p_repasse numeric default null)
returns void language plpgsql security definer set search_path = '' as $$
declare v_atual public.papel_usuario[];
begin
  -- outra empresa: recusa
  if p_usuario is not null and not public.ve_pessoa(p_usuario) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if not public.pode_gerenciar(p_usuario) then raise exception 'conta_protegida' using errcode = '42501'; end if;
  select papeis into v_atual from public.perfis where id = p_usuario;
  -- dar ou tirar o cargo Dev: só um Dev
  if ('dev' = any (p_papeis)) <> ('dev' = any (coalesce(v_atual, '{}'))) and not public.is_dev() then
    raise exception 'apenas_dev' using errcode = '42501';
  end if;
  -- dar ou tirar Gestor/Supervisor: só o gestor da empresa (ou o Dev)
  if (('gestor' = any (p_papeis)) <> ('gestor' = any (coalesce(v_atual, '{}')) )
      or ('supervisor' = any (p_papeis)) <> ('supervisor' = any (coalesce(v_atual, '{}')))) and not public.is_gestor_pleno() then
    raise exception 'apenas_gestor' using errcode = '42501';
  end if;
  if p_usuario = auth.uid() and not ('gestor' = any (p_papeis) or 'dev' = any (p_papeis) or 'supervisor' = any (p_papeis)) then
    raise exception 'nao_remova_seu_proprio_acesso' using errcode = '22023';
  end if;
  if p_usuario = auth.uid() and 'dev' = any (coalesce(v_atual, '{}')) and not ('dev' = any (p_papeis)) then
    raise exception 'nao_remova_seu_proprio_acesso' using errcode = '22023';
  end if;
  if p_repasse is not null and (p_repasse < 0 or p_repasse > 100) then
    raise exception 'percentual_invalido' using errcode = '22023';
  end if;
  update public.perfis set nome = coalesce(nullif(trim(p_nome), ''), nome), papeis = p_papeis,
         organizacao_id = coalesce(organizacao_id, public.minha_org()),
         responsavel_id = coalesce(responsavel_id, case when p_usuario <> auth.uid() then auth.uid() end)
   where id = p_usuario;
  if 'motoboy' = any (p_papeis) then
    insert into public.motoboys (id) values (p_usuario) on conflict (id) do nothing;
    -- percentual agora é uma exceção de pagamento do motoboy (Regras); só grava se vier
    if p_repasse is not null then
      insert into public.politicas (escopo, alvo, chave, valor) values ('motoboy', p_usuario::text, 'repasse_motoboy_pct', to_jsonb(p_repasse))
      on conflict (escopo, alvo, chave) do update set valor = excluded.valor;
    end if;
  end if;
end;
$$;

create or replace function public.editar_orcamento(p_pedido uuid, p_linhas jsonb, p_percentuais jsonb default '[]', p_minimo numeric default null, p_motivo text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  p        public.pedidos%rowtype;
  l        jsonb;
  v_linhas jsonb := '[]';
  v_pcts   jsonb := '[]';
  v_sub    numeric := 0; v_fixos numeric := 0; v_pct numeric := 0;
  v_val    numeric; v_min numeric; v_total numeric;
  v_orc    jsonb;
begin
  -- outra empresa: recusa
  if p_pedido is not null and not public.ve_pedido(p_pedido) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select * into p from public.pedidos where id = p_pedido for update;
  if not found then raise exception 'pedido_nao_encontrado' using errcode = '22023'; end if;
  if p.fatura_id is not null and exists (select 1 from public.faturas f where f.id = p.fatura_id and f.status <> 'rascunho') then
    raise exception 'pedido_ja_faturado' using errcode = '22023';
  end if;
  if p_linhas is null or jsonb_typeof(p_linhas) <> 'array' or jsonb_array_length(p_linhas) > 80 then raise exception 'orcamento_invalido' using errcode = '22023'; end if;
  for l in select * from jsonb_array_elements(p_linhas) loop
    if coalesce(trim(l ->> 'rotulo'), '') = '' then continue; end if;
    v_val := round(coalesce(nullif(l ->> 'valor', '')::numeric, nullif(l ->> 'qtd', '')::numeric * nullif(l ->> 'unit', '')::numeric, 0), 2);
    v_linhas := v_linhas || (jsonb_strip_nulls(jsonb_build_object('chave', l ->> 'chave', 'rotulo', left(l ->> 'rotulo', 80), 'qtd', nullif(l ->> 'qtd', '')::numeric,
                  'unit', nullif(l ->> 'unit', '')::numeric, 'unidade', l ->> 'unidade', 'fixo', nullif((l ->> 'fixo')::boolean, false),
                  'detalhe', case when nullif(l ->> 'qtd', '') is not null and nullif(l ->> 'unit', '') is not null
                                  then format('%s %s × R$ %s', l ->> 'qtd', coalesce(l ->> 'unidade', ''), l ->> 'unit') else nullif(left(l ->> 'detalhe', 160), '') end))
                || jsonb_build_object('valor', v_val));
    if coalesce((l ->> 'fixo')::boolean, false) then v_fixos := v_fixos + v_val; else v_sub := v_sub + v_val; end if;
  end loop;
  for l in select * from jsonb_array_elements(coalesce(p_percentuais, '[]')) loop
    if coalesce(trim(l ->> 'rotulo'), '') = '' or coalesce(nullif(l ->> 'pct', '')::numeric, 0) = 0 then continue; end if;
    v_pcts := v_pcts || jsonb_build_object('rotulo', left(l ->> 'rotulo', 80), 'pct', (l ->> 'pct')::numeric);
    v_pct := v_pct + (l ->> 'pct')::numeric;
  end loop;
  v_min := greatest(coalesce(p_minimo, (p.orcamento ->> 'minimo')::numeric, 0), 0);
  v_total := privado.arredondar(greatest(v_sub * (1 + v_pct / 100.0) + v_fixos, v_min, 0));
  v_orc := coalesce(p.orcamento, '{}') || jsonb_build_object(
    'linhas', v_linhas, 'percentuais', v_pcts, 'subtotal', round(v_sub + v_fixos, 2), 'acrescimo_pct', v_pct, 'minimo', v_min, 'total', v_total,
    'editado', true, 'editado_em', now(), 'editado_por', auth.uid(), 'motivo', nullif(trim(p_motivo), ''),
    'original', coalesce(p.orcamento -> 'original', p.orcamento - 'original'));
  update public.pedidos set orcamento = v_orc, valor_calculado = v_total, valor = v_total, valor_ajuste = 0,
         ajuste_motivo = coalesce(nullif(trim(p_motivo), ''), ajuste_motivo), valor_dev = round(v_total * dev_pct / 100, 2)
   where id = p.id;
  perform privado.valores_rota(x.corrida_id) from (select distinct corrida_id from public.paradas where pedido_id = p.id) x;
  perform privado.evento_pedido(p.id, 'orcamento_editado', jsonb_build_object('de', p.valor, 'para', v_total, 'motivo', p_motivo));
  return (select to_jsonb(x) from public.pedidos x where x.id = p.id);
end;
$$;

create or replace function public.estender_rota(p_nova uuid, p_motoboy uuid, p_perguntar boolean default true)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_ativa uuid;
begin
  -- outra empresa: recusa
  if p_nova is not null and not public.ve_corrida(p_nova) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if p_motoboy is not null and not public.ve_pessoa(p_motoboy) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select id into v_ativa from public.corridas where motoboy_id = p_motoboy and status::text in ('aceita', 'em_andamento') order by aceita_em desc limit 1;
  if v_ativa is null then raise exception 'motoboy_sem_rota_em_andamento' using errcode = '22023'; end if;
  if coalesce(p_perguntar, true) then
    perform public.liberar_rota(p_nova, null, p_motoboy);
    return p_nova;
  end if;
  return privado.estender_rota(v_ativa, p_nova);
end;
$$;

create or replace function public.gerenciar_planejada(p_corrida uuid, p_acao text, p_motoboy uuid default null, p_quando timestamptz default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  c public.corridas%rowtype;
begin
  -- outra empresa: recusa
  if p_corrida is not null and not public.ve_corrida(p_corrida) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if p_motoboy is not null and not public.ve_pessoa(p_motoboy) then raise exception 'sem_permissao' using errcode = '42501'; end if;
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

create or replace function public.holerite(p_motoboy uuid, p_inicio date, p_fim date, p_teste boolean default false)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  -- outra empresa: recusa
  if p_motoboy is not null and not public.ve_pessoa(p_motoboy) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  return privado.holerite_json(p_motoboy, p_inicio, p_fim, p_teste, true);
end;
$$;

create or replace function public.juntar_rotas(p_origem uuid, p_destino uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare x record; o public.corridas; d public.corridas;
begin
  -- outra empresa: recusa
  if p_origem is not null and not public.ve_corrida(p_origem) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if p_destino is not null and not public.ve_corrida(p_destino) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  o := privado.rota_editavel(p_origem); d := privado.rota_editavel(p_destino);
  if o.teste <> d.teste or p_origem = p_destino then raise exception 'rota_destino_invalida' using errcode = '22023'; end if;
  for x in select id from public.paradas where corrida_id = p_origem and tipo = 'entrega' order by ordem loop
    perform public.mover_entrega(x.id, p_destino);
  end loop;
  perform privado.decisao('juntar', p_destino, jsonb_build_object('de', p_origem));
  return p_destino;
end;
$$;

create or replace function public.liberar_rota(p_corrida uuid, p_modo text default null, p_motoboy uuid default null)
returns void language plpgsql security definer set search_path = '' as $$
declare c public.corridas%rowtype;
begin
  -- outra empresa: recusa
  if p_corrida is not null and not public.ve_corrida(p_corrida) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if p_motoboy is not null and not public.ve_pessoa(p_motoboy) then raise exception 'sem_permissao' using errcode = '42501'; end if;
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

create or replace function public.mover_entrega(p_parada uuid, p_destino uuid default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  x       public.paradas%rowtype;
  o       public.corridas%rowtype;
  d       public.corridas%rowtype;
  v_col   public.paradas%rowtype;
begin
  -- outra empresa: recusa
  if p_parada is not null and not public.ve_corrida((select tv_par.corrida_id from public.paradas tv_par where tv_par.id = p_parada)) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if p_destino is not null and not public.ve_corrida(p_destino) then raise exception 'sem_permissao' using errcode = '42501'; end if;
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

create or replace function public.ordenar_paradas(p_corrida uuid, p_ordem uuid[])
returns void language plpgsql security definer set search_path = '' as $$
declare i int; c public.corridas;
begin
  -- outra empresa: recusa
  if p_corrida is not null and not public.ve_corrida(p_corrida) then raise exception 'sem_permissao' using errcode = '42501'; end if;
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

create or replace function public.preparar_exclusao_conta(p_usuario uuid, p_senha text, p_motivo text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_perfil public.perfis%rowtype;
  v_email  text;
begin
  -- outra empresa: recusa
  if p_usuario is not null and not public.ve_pessoa(p_usuario) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;

  -- mesma proteção da exclusão de corridas: 5 senhas erradas → 15 min bloqueado
  delete from privado.tentativas_senha where quando < now() - interval '15 minutes';
  if (select count(*) from privado.tentativas_senha where usuario = auth.uid()) >= 5 then
    return jsonb_build_object('erro', 'muitas_tentativas');
  end if;
  if not privado.senha_confere(p_senha) then
    insert into privado.tentativas_senha (usuario) values (auth.uid());
    return jsonb_build_object('erro', 'senha_incorreta',
      'restantes', 5 - (select count(*) from privado.tentativas_senha where usuario = auth.uid()));
  end if;
  delete from privado.tentativas_senha where usuario = auth.uid();

  if p_usuario = auth.uid() then return jsonb_build_object('erro', 'nao_exclua_a_si_mesmo'); end if;
  select * into v_perfil from public.perfis where id = p_usuario;
  if not found then return jsonb_build_object('erro', 'usuario_nao_encontrado'); end if;
  if exists (select 1 from public.corridas where motoboy_id = p_usuario and status in ('aceita', 'em_andamento'))
     or exists (select 1 from public.ofertas where motoboy_id = p_usuario and status = 'pendente') then
    return jsonb_build_object('erro', 'membro_em_corrida');
  end if;

  select email::text into v_email from auth.users where id = p_usuario;

  -- o histórico guarda quem foi
  update public.corridas set motoboy_nome_arquivado = v_perfil.nome where motoboy_id = p_usuario;
  update public.corridas set criada_por_nome_arquivado = v_perfil.nome where criada_por = p_usuario;

  insert into public.registro_contas_excluidas (usuario_id, email, nome, papeis, copia, motivo, excluida_por)
  values (p_usuario, v_email, v_perfil.nome, v_perfil.papeis::text[],
          jsonb_build_object(
            'perfil', to_jsonb(v_perfil),
            'motoboy', (select to_jsonb(m) - 'posicao' from public.motoboys m where m.id = p_usuario),
            'corridas_feitas', (select count(*) from public.corridas where motoboy_id = p_usuario and status = 'concluida'),
            'corridas_criadas', (select count(*) from public.corridas where criada_por = p_usuario)
          ),
          nullif(trim(p_motivo), ''), auth.uid());

  return jsonb_build_object('ok', true, 'email', v_email, 'nome', v_perfil.nome);
end;
$$;

create or replace function public.previa_historico(p_teste boolean, p_motoboy uuid default null, p_ate timestamptz default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  -- outra empresa: recusa
  if p_motoboy is not null and not public.ve_pessoa(p_motoboy) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  return jsonb_build_object(
    'corridas', (select count(*) from privado.corridas_do_historico(p_teste, p_motoboy, p_ate)),
    'pings', (select count(*) from privado.pings_do_historico(p_teste, p_motoboy, p_ate))
  );
end;
$$;

create or replace function public.previa_rotas_pedido(p_pedido uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare p public.pedidos%rowtype; v_res jsonb;
begin
  -- outra empresa: recusa
  if p_pedido is not null and not public.ve_pedido(p_pedido) then raise exception 'sem_permissao' using errcode = '42501'; end if;
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

create or replace function public.recalcular_pagamento_rota(p_corrida uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c public.corridas%rowtype; v jsonb;
begin
  -- outra empresa: recusa
  if p_corrida is not null and not public.ve_corrida(p_corrida) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select * into c from public.corridas where id = p_corrida for update;
  if not found or c.motoboy_id is null then raise exception 'rota_sem_motoboy' using errcode = '22023'; end if;
  v := privado.calcular_pagamento(p_corrida, c.motoboy_id);
  update public.corridas set pag_calculo = v, valor_motoboy = (v ->> 'total')::numeric + pag_ajuste where id = p_corrida;
  return v;
end;
$$;

create or replace function public.redespachar(p_corrida uuid, p_motoboy uuid default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_teste boolean;
  r record;
begin
  -- outra empresa: recusa
  if p_corrida is not null and not public.ve_corrida(p_corrida) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if p_motoboy is not null and not public.ve_pessoa(p_motoboy) then raise exception 'sem_permissao' using errcode = '42501'; end if;
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

create or replace function public.registro_membro(p_usuario uuid, p_limite int default 300)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_itens  jsonb;
  v_resumo jsonb;
begin
  -- outra empresa: recusa
  if p_usuario is not null and not public.ve_pessoa(p_usuario) then raise exception 'sem_permissao' using errcode = '42501'; end if;
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

create or replace function public.revisar_pedido(p_pedido uuid, p_acao text, p_valor numeric default null, p_motivo text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  p     public.pedidos%rowtype;
  v_orc jsonb;
  v_val numeric;
begin
  -- outra empresa: recusa
  if p_pedido is not null and not public.ve_pedido(p_pedido) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select * into p from public.pedidos where id = p_pedido for update;
  if not found then raise exception 'pedido_nao_encontrado' using errcode = '22023'; end if;
  if p_acao = 'voltar_revisao' then
    if p.status not in ('aprovado', 'roteirizado', 'em_rota') then raise exception 'pedido_nao_pode_voltar' using errcode = '22023'; end if;
    if exists (select 1 from public.pedido_pontos x where x.pedido_id = p.id and x.status not in ('pendente', 'em_rota'))
       or exists (select 1 from public.paradas x where x.pedido_id = p.id and x.status::text in ('chegou', 'concluida'))
       or exists (select 1 from public.paradas x join public.corridas c on c.id = x.corrida_id
                   where x.pedido_id = p.id and (c.status::text = 'em_andamento'
                         or (c.status::text = 'aceita' and not privado.cfg_bool('voltar_revisao_aceitas', true)))) then
      raise exception 'pedido_em_andamento' using errcode = '22023';
    end if;
    perform privado.tirar_pedido_das_rotas(p.id, true);
    update public.pedidos set status = 'recebido', aprovado_em = null, revisado_por = null, revisado_em = null where id = p.id;
    update public.pedido_pontos set status = 'pendente' where pedido_id = p.id;
    perform privado.evento_pedido(p.id, 'voltou_revisao', jsonb_build_object('motivo', p_motivo));
    return (select to_jsonb(x) from public.pedidos x where x.id = p.id);
  end if;
  if p.status in ('concluido', 'cancelado', 'recusado') and p_acao <> 'ajustar' then raise exception 'pedido_finalizado' using errcode = '22023'; end if;
  if p.fatura_id is not null and exists (select 1 from public.faturas f where f.id = p.fatura_id and f.status <> 'rascunho') then
    raise exception 'pedido_ja_faturado' using errcode = '22023';
  end if;

  if p_acao = 'recalcular' then
    select privado.orcar(jsonb_build_object('pedido_id', p.id, 'empresa_id', p.empresa_id, 'tipo', p.tipo, 'tipo_pedido', p.tipo_pedido, 'quando', p.quando, 'urgente', p.urgente,
             'distancia_m', p.distancia_estimada_m,
             'pontos', (select jsonb_agg(jsonb_build_object('tipo', x.tipo, 'lat', x.lat, 'lng', x.lng, 'dist_coleta_m', x.dist_coleta_m) order by x.ordem) from public.pedido_pontos x where x.pedido_id = p.id),
             'itens', coalesce((select jsonb_agg(to_jsonb(i)) from public.pedido_itens i where i.pedido_id = p.id), '[]')))
      into v_orc;
    update public.pedidos set orcamento = v_orc, valor_calculado = (v_orc ->> 'total')::numeric,
           valor = (v_orc ->> 'total')::numeric + valor_ajuste, valor_dev = round(((v_orc ->> 'total')::numeric + valor_ajuste) * dev_pct / 100, 2)
     where id = p.id;
    perform privado.evento_pedido(p.id, 'recalculado', jsonb_build_object('total', v_orc -> 'total'));
  elsif p_acao in ('aprovar', 'ajustar') then
    if p_valor is not null then
      if p_valor < 0 then raise exception 'valor_invalido' using errcode = '22023'; end if;
      if p_valor <> coalesce(p.valor_calculado, 0) and coalesce(trim(p_motivo), '') = '' and p_valor <> p.valor then
        raise exception 'informe_o_motivo' using errcode = '22023';
      end if;
      v_val := round(p_valor, 2);
      update public.pedidos set valor = v_val, valor_ajuste = v_val - coalesce(valor_calculado, 0),
             ajuste_motivo = coalesce(nullif(trim(p_motivo), ''), ajuste_motivo), valor_dev = round(v_val * dev_pct / 100, 2)
       where id = p.id;
      -- a rota recebe a parte nova do valor
      perform privado.valores_rota(x.corrida_id) from (select distinct corrida_id from public.paradas where pedido_id = p.id) x;
      perform privado.evento_pedido(p.id, 'valor_ajustado', jsonb_build_object('de', p.valor, 'para', v_val, 'motivo', p_motivo));
    end if;
    if p_acao = 'aprovar' and p.status = 'recebido' then
      update public.pedidos set status = 'aprovado', aprovado_em = now(), revisado_por = auth.uid(), revisado_em = now() where id = p.id;
      perform privado.evento_pedido(p.id, 'aprovado');
      perform privado.roteirizar(p.teste);
    end if;
  elsif p_acao = 'recusar' then
    if p.status not in ('recebido', 'aprovado') then raise exception 'pedido_ja_em_rota' using errcode = '22023'; end if;
    update public.pedidos set status = 'recusado', recusa_motivo = nullif(trim(p_motivo), ''), revisado_por = auth.uid(), revisado_em = now() where id = p.id;
    perform privado.tirar_das_rotas(p.id);
    perform privado.evento_pedido(p.id, 'recusado', jsonb_build_object('motivo', p_motivo));
  else
    raise exception 'acao_invalida' using errcode = '22023';
  end if;
  return (select to_jsonb(x) from public.pedidos x where x.id = p.id);
end;
$$;

create or replace function public.roteirizar_pedido(p_pedido uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_teste boolean;
begin
  -- outra empresa: recusa
  if p_pedido is not null and not public.ve_pedido(p_pedido) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select teste into v_teste from public.pedidos where id = p_pedido;
  if not found then raise exception 'pedido_nao_encontrado' using errcode = '22023'; end if;
  perform set_config('pwex.sem_espera', 'on', true);
  perform privado.roteirizar(v_teste);
  perform set_config('pwex.sem_espera', 'off', true);
  return public.situacao_rota(p_pedido);
end;
$$;

create or replace function public.salvar_veiculo(p_motoboy uuid, d jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_id    uuid := coalesce(p_motoboy, auth.uid());
  v_placa text := nullif(upper(regexp_replace(coalesce(d ->> 'placa', ''), '[^A-Za-z0-9]', '', 'g')), '');
  v_cnh   text := nullif(regexp_replace(coalesce(d ->> 'cnh_numero', ''), '[^0-9]', '', 'g'), '');
  v_cat   text := nullif(upper(trim(coalesce(d ->> 'cnh_categoria', ''))), '');
  m       public.motoboys%rowtype;
begin
  -- outra empresa: recusa
  if p_motoboy is not null and not public.ve_pessoa(p_motoboy) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if v_id = auth.uid() and not public.is_gestor() then
    if not privado.cfg_bool('motoboy_edita_veiculo', false) then raise exception 'so_o_gestor_edita' using errcode = '42501'; end if;
  elsif not public.is_gestor() or not public.pode_gerenciar(v_id) then
    raise exception 'apenas_gestor' using errcode = '42501';
  end if;
  if not exists (select 1 from public.perfis where id = v_id and 'motoboy' = any (papeis)) then raise exception 'nao_e_motoboy' using errcode = '22023'; end if;
  if v_placa is not null and v_placa !~ '^[A-Z]{3}[0-9][A-Z0-9][0-9]{2}$' then raise exception 'placa_invalida' using errcode = '22023'; end if;
  if v_cnh is not null and v_cnh !~ '^[0-9]{9,11}$' then raise exception 'cnh_invalida' using errcode = '22023'; end if;
  if v_cat is not null and v_cat !~ '^(ACC|A|B|C|D|E|AB|AC|AD|AE)$' then raise exception 'cnh_categoria_invalida' using errcode = '22023'; end if;
  insert into public.motoboys (id) values (v_id) on conflict (id) do nothing;
  update public.motoboys set
    veiculo_tipo = coalesce(nullif(d ->> 'tipo', ''), veiculo_tipo),
    veiculo_modelo = nullif(left(trim(coalesce(d ->> 'modelo', '')), 60), ''),
    veiculo_placa = v_placa,
    veiculo_cor = nullif(left(trim(coalesce(d ->> 'cor', '')), 30), ''),
    veiculo_ano = nullif(d ->> 'ano', '')::int,
    cnh_numero = v_cnh, cnh_categoria = v_cat,
    cnh_validade = nullif(d ->> 'cnh_validade', '')::date
   where id = v_id returning * into m;
  return privado.veiculo_json(m);
end;
$$;

create or replace function public.simular_posicao(p_motoboy uuid, p_lat double precision, p_lng double precision,
                                                  p_velocidade_ms real default null, p_direcao real default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare m public.motoboys%rowtype; v_sessao uuid; v_corrida uuid; v_status text;
begin
  -- outra empresa: recusa
  if p_motoboy is not null and not public.ve_pessoa(p_motoboy) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if not privado.cfg_bool('simulador_ligado', true) then raise exception 'simulador_desligado' using errcode = '42501'; end if;
  if p_lat is null or p_lng is null or abs(p_lat) > 90 or abs(p_lng) > 180 then raise exception 'posicao_invalida' using errcode = '22023'; end if;
  select * into m from public.motoboys where id = p_motoboy for update;
  if not found then raise exception 'nao_e_motoboy' using errcode = '22023'; end if;
  if not coalesce(m.modo_teste, false) then raise exception 'so_em_modo_teste' using errcode = '42501'; end if;
  v_status := case when m.status::text = 'offline' then 'disponivel' else m.status::text end;
  select id into v_corrida from public.corridas where motoboy_id = p_motoboy and status::text in ('aceita', 'em_andamento') order by aceita_em desc limit 1;
  select l.sessao_id into v_sessao from public.localizacoes l
   where l.motoboy_id = p_motoboy and l.registrado_em > now() - interval '20 minutes' and l.status::text = v_status
   order by l.registrado_em desc limit 1;
  insert into public.localizacoes (motoboy_id, id_local, sessao_id, corrida_id, status, lat, lng, precisao_m, velocidade_ms, direcao_graus, bateria, registrado_em, simulada)
  values (p_motoboy, gen_random_uuid(), coalesce(v_sessao, gen_random_uuid()), case when v_status = 'em_corrida' then v_corrida end,
          v_status::public.status_motoboy, p_lat, p_lng, 5, p_velocidade_ms, p_direcao, coalesce(m.bateria, 100), now(), true);
  update public.motoboys set lat = p_lat, lng = p_lng, precisao_m = 5, posicao_em = now(),
         status = v_status::public.status_motoboy, status_em = case when m.status::text = 'offline' then now() else status_em end
   where id = p_motoboy;
  return jsonb_build_object('lat', p_lat, 'lng', p_lng, 'status', v_status);
end;
$$;

create or replace function public.situacao_holerite(p_motoboy uuid, p_inicio date, p_fim date, p_acao text, p_teste boolean default false, p_obs text default null, p_ref text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_h uuid; v jsonb;
begin
  -- outra empresa: recusa
  if p_motoboy is not null and not public.ve_pessoa(p_motoboy) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select id into v_h from public.holerites where motoboy_id = p_motoboy and teste = p_teste and inicio = p_inicio and fim = p_fim;
  if v_h is null then insert into public.holerites (motoboy_id, teste, inicio, fim) values (p_motoboy, p_teste, p_inicio, p_fim) returning id into v_h; end if;
  if p_acao = 'fechar' then
    v := privado.holerite_json(p_motoboy, p_inicio, p_fim, p_teste, true);
    update public.holerites set status = 'fechado', fechado_em = now(), fechado_por = auth.uid(), observacoes = coalesce(nullif(trim(p_obs), ''), observacoes),
           rotas = (v ->> 'rotas')::int, entregas = (v ->> 'entregas')::int, km = (v ->> 'km')::numeric,
           calculado = (v ->> 'calculado')::numeric + (v ->> 'ajustes_rotas')::numeric,
           ajustes = (v ->> 'total')::numeric - (v ->> 'calculado')::numeric - (v ->> 'ajustes_rotas')::numeric,
           total = (v ->> 'total')::numeric
     where id = v_h and status = 'aberto';
    if not found then raise exception 'holerite_ja_fechado' using errcode = '22023'; end if;
  elsif p_acao = 'reabrir' then
    update public.holerites set status = 'aberto', fechado_em = null, pago_em = null where id = v_h;
  elsif p_acao = 'pago' then
    update public.holerites set status = 'pago', pago_em = now(), pagamento_ref = p_ref where id = v_h and status = 'fechado';
    if not found then raise exception 'feche_o_holerite_antes' using errcode = '22023'; end if;
  else
    raise exception 'acao_invalida' using errcode = '22023';
  end if;
  return (select to_jsonb(h) from public.holerites h where h.id = v_h);
end;
$$;

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
  -- outra empresa: recusa
  if p_pedido is not null and not public.ve_pedido(p_pedido) then raise exception 'sem_permissao' using errcode = '42501'; end if;
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

create or replace function public.sugestoes_rota(p_pedido uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare p public.pedidos%rowtype;
begin
  -- outra empresa: recusa
  if p_pedido is not null and not public.ve_pedido(p_pedido) then raise exception 'sem_permissao' using errcode = '42501'; end if;
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

create or replace function public.vincular_cliente(p_usuario uuid, p_empresa uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  -- outra empresa: recusa
  if p_usuario is not null and not public.ve_pessoa(p_usuario) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if p_empresa is not null and not public.ve_org((select tv_emp.organizacao_id from public.empresas tv_emp where tv_emp.id = p_empresa)) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if p_usuario <> auth.uid() and not public.pode_gerenciar(p_usuario) then raise exception 'conta_protegida' using errcode = '42501'; end if;
  if p_empresa is not null and not exists (select 1 from public.empresas where id = p_empresa) then raise exception 'cliente_nao_encontrado' using errcode = '22023'; end if;
  update public.perfis set empresa_id = p_empresa,
         papeis = case when p_empresa is null then array_remove(papeis, 'cliente'::public.papel_usuario)
                       else (select array_agg(distinct x) from unnest(papeis || '{cliente}'::public.papel_usuario[]) x) end
   where id = p_usuario;
end;
$$;

-- funções com trava de empresa: ajustar_pagamento_rota, ajuste_holerite, apagar_historico, aplicar_otimizacao, aprovar_e_montar, avancar_parada, cancelar_corrida, cancelar_pedido, confirmar_pagamento, confirmar_pagamento_pedido, definir_regras_pedido, definir_regras_rota, definir_regras_rota_pedido, definir_repasse, definir_valor_rota, editar_fatura, editar_membro, editar_orcamento, estender_rota, gerenciar_planejada, holerite, juntar_rotas, liberar_rota, mover_entrega, ordenar_paradas, preparar_exclusao_conta, previa_historico, previa_rotas_pedido, recalcular_pagamento_rota, redespachar, registro_membro, revisar_pedido, roteirizar_pedido, salvar_veiculo, simular_posicao, situacao_holerite, situacao_rota, sugestoes_rota, vincular_cliente
