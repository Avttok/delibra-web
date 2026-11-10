-- =====================================================================
-- PW Express · Despacho mais esperto e mais controle sobre o cliente
-- ---------------------------------------------------------------------
--  Despacho
--  • Padrão novo: a rota vai direto para a tela de oferta (um motoboy por
--    vez, do mais perto ao mais longe). Se ninguém pega, vai para o
--    quadro de rotas com aviso (despacho_sem_motoboy).
--  • Extensão de rota: motoboys em corrida, perto da coleta, também podem
--    receber a oferta (despacho_em_corrida). Aceitando, as paradas novas
--    entram no fim da rota que ele já está fazendo. O gestor também pode
--    estender na mão.
--  • Planejadas sem reserva: aviso aos motoboys online antes do horário
--    (agendada_aviso_online_min) e, mais perto, despacho pelo modo
--    escolhido (agendada_abrir_modo).
--  • Quem recebe o aviso do quadro e em que raio (quadro_avisa, quadro_aviso_raio_km).
--  Cliente
--  • Pode ou não agendar, pedir urgente, limites de entregas/coletas,
--    pedidos abertos, dias de antecedência e horário para pedir.
-- Rode depois de 20261110000014. Seguro rodar de novo.
-- =====================================================================

alter table public.ofertas add column if not exists extensao boolean not null default false;
alter table public.corridas add column if not exists aviso_online_em timestamptz;
alter table public.corridas add column if not exists unida_em uuid;
alter table public.corridas add column if not exists pag_piso numeric(10, 2);
alter table public.corridas add column if not exists despacho_auto_em timestamptz;

insert into public.configuracoes (chave, valor) values
  ('despacho_sem_motoboy', '"quadro"'), ('despacho_max_ofertas', '0'), ('despacho_em_corrida', '"depois"'),
  ('extensao_raio_km', '3'), ('extensao_max_entregas', '8'), ('extensao_nunca_reduz', 'true'), ('quadro_avisa', '"disponiveis"'), ('quadro_aviso_raio_km', '0'),
  ('agendada_aviso_online_min', '60'), ('agendada_abrir_modo', '"cascata"'),
  ('cliente_pode_agendar', 'true'), ('cliente_pode_urgente', 'true'), ('cliente_max_entregas', '0'), ('cliente_max_coletas', '0'),
  ('cliente_max_pedidos_abertos', '0'), ('cliente_agendar_max_dias', '60'), ('cliente_pode_ida_volta', 'true'), ('cliente_coleta_fixa', 'false'),
  ('cliente_pode_observacoes', 'true'), ('cliente_ve_faturas', 'true'), ('cliente_pode_chat', 'true'), ('cliente_pedido_de', '""'), ('cliente_pedido_ate', '""')
on conflict (chave) do nothing;
-- padrão novo: oferta direta, um por vez
insert into public.configuracoes (chave, valor) values ('despacho_modo', '"cascata"') on conflict (chave) do update set valor = excluded.valor;

-- ------------------------------------------------------------- aviso do quadro: quem recebe
create or replace function privado.avisar_quadro(p_corrida uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  c      public.corridas%rowtype;
  v_m    uuid;
  v_n    int;
  v_quem text;
  v_raio numeric;
  v_col  record;
begin
  select * into c from public.corridas where id = p_corrida;
  v_quem := privado.pol_txt('quadro_avisa', 'disponiveis', c.empresa_id, null, c.tipo_pedido);
  if v_quem = 'ninguem' then return; end if;
  v_raio := privado.pol_num('quadro_aviso_raio_km', 0, c.empresa_id, null, c.tipo_pedido) * 1000;
  select lat, lng into v_col from public.paradas where corrida_id = p_corrida order by ordem limit 1;
  select count(*) into v_n from public.paradas where corrida_id = p_corrida and tipo = 'entrega';
  for v_m in
    select m.id from public.motoboys m
      join public.perfis pf on pf.id = m.id and 'motoboy' = any (pf.papeis)
     where m.modo_teste = c.teste
       and (c.agendada_para > now() or m.status = 'disponivel' or (v_quem = 'online' and m.status <> 'offline'))
       and (v_raio <= 0 or m.lat is null or privado.dist_m(m.lat, m.lng, v_col.lat, v_col.lng) <= v_raio)
     limit 300
  loop
    perform privado.enviar_push(v_m, jsonb_build_object(
      'tipo', 'rota_nova', 'corrida_id', p_corrida::text, 'teste', c.teste::text,
      'planejada', (c.agendada_para is not null)::text, 'entregas', v_n::text,
      'sugerida', (v_m = c.sugerido_motoboy_id)::text,
      'agendada_para', coalesce(to_char(c.agendada_para at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), '')));
  end loop;
end;
$$;

-- ------------------------------------------------------------- extensão: as paradas da rota nova entram no fim da rota em andamento
create or replace function privado.estender_rota(p_ativa uuid, p_nova uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  a public.corridas%rowtype;
  n public.corridas%rowtype;
  v_base int;
begin
  select * into a from public.corridas where id = p_ativa for update;
  select * into n from public.corridas where id = p_nova for update;
  if a.id is null or n.id is null or a.id = n.id then raise exception 'rota_nao_encontrada' using errcode = '22023'; end if;
  if a.status::text not in ('aceita', 'em_andamento') or a.motoboy_id is null then raise exception 'rota_nao_esta_em_andamento' using errcode = '22023'; end if;
  if n.motoboy_id is not null or n.status::text not in ('montada', 'agendada', 'aguardando_motoboy', 'sem_motoboy') then
    raise exception 'rota_ja_pegada' using errcode = '22023';
  end if;
  if a.teste <> n.teste then raise exception 'rota_destino_invalida' using errcode = '22023'; end if;
  update public.ofertas set status = 'cancelada' where corrida_id = n.id and status = 'pendente';
  select coalesce(max(ordem), 0) + 1 into v_base from public.paradas where corrida_id = a.id;
  -- mantém a ordem que a rota nova já tinha; tudo pendente, depois das paradas que ele já tem
  update public.paradas p set corrida_id = a.id, ordem = v_base + x.k, status = 'pendente'
    from (select id, row_number() over (order by ordem) k from public.paradas where corrida_id = n.id) x
   where p.id = x.id;
  -- estender nunca faz o motoboy ganhar menos do que já tinha garantido nesta rota
  if privado.pol_bool('extensao_nunca_reduz', true, a.empresa_id, a.motoboy_id, a.tipo_pedido) then
    update public.corridas set pag_piso = greatest(coalesce(pag_piso, 0), coalesce(valor_motoboy, 0)) where id = a.id;
  end if;
  update public.corridas set valor = coalesce(valor, 0) + coalesce(n.valor, 0), valor_base = coalesce(valor_base, 0) + coalesce(n.valor_base, n.valor, 0),
         tem_perigoso = tem_perigoso or coalesce(n.tem_perigoso, false), urgente = urgente or coalesce(n.urgente, false),
         distancia_planejada_m = null, rota_planejada = null, otimizada_em = null
   where id = a.id;
  update public.corridas set status = 'cancelada', cancelada_em = now(), unida_em = a.id where id = n.id;
  perform privado.evento(n.id, 'cancelada', jsonb_build_object('motivo', 'unida à rota em andamento', 'rota', a.id));
  perform privado.evento(a.id, 'rota_estendida', jsonb_build_object('rota', n.id, 'numero', n.numero,
    'entregas', (select count(*) from public.paradas where corrida_id = a.id and tipo = 'entrega' and ordem >= v_base)));
  perform privado.enviar_push(a.motoboy_id, jsonb_build_object('tipo', 'rota_estendida', 'corrida_id', a.id::text, 'teste', a.teste::text));
  return a.id;
end;
$$;

-- o gestor estende na mão: com oferta (o motoboy aceita) ou direto
create or replace function public.estender_rota(p_nova uuid, p_motoboy uuid, p_perguntar boolean default true)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_ativa uuid;
begin
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
revoke all on function public.estender_rota(uuid, uuid, boolean) from public, anon;
grant execute on function public.estender_rota(uuid, uuid, boolean) to authenticated;


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
  v_emc        text;
  v_ext_raio   numeric;
  v_ext_max    int;
  v_nent       int;
  v_max        int;
  v_ext        boolean := false;
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
  -- motoboys em corrida também concorrem (extensão de rota), se a regra deixar e a rota for para agora
  v_emc := case when c.agendada_para > now() then 'nao' else privado.pol_txt('despacho_em_corrida', 'depois', c.empresa_id, null, c.tipo_pedido) end;
  v_ext_raio := privado.pol_num('extensao_raio_km', 3, c.empresa_id, null, c.tipo_pedido) * 1000;
  v_ext_max := privado.pol_num('extensao_max_entregas', 8, c.empresa_id, null, c.tipo_pedido)::int;
  select count(*) into v_nent from public.paradas where corrida_id = p_corrida and tipo = 'entrega';
  v_max := privado.pol_num('despacho_max_ofertas', 0, c.empresa_id, null, c.tipo_pedido)::int;

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
     where (m.status = 'disponivel'
            or (v_emc in ('depois', 'junto') and m.status = 'em_corrida'
                and extensions.st_distance(m.posicao, v_coleta) <= v_ext_raio
                and exists (select 1 from public.corridas k where k.motoboy_id = m.id and k.status::text in ('aceita', 'em_andamento') and k.teste = c.teste
                             and (select count(*) from public.paradas kp where kp.corrida_id = k.id and kp.tipo = 'entrega' and kp.status::text <> 'concluida') + v_nent <= v_ext_max)))
       and (v_max <= 0 or (select count(*) from public.ofertas o where o.corrida_id = p_corrida and o.rodada = c.rodada) < v_max)
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
     order by (f.ordem is null), f.ordem, (v_emc = 'depois' and m.status <> 'disponivel'), extensions.st_distance(m.posicao, v_coleta)
     limit 1;
  end if;

  if v_motoboy is null then
    -- ninguém para oferecer: vai para o quadro de rotas com aviso (ou para em "sem motoboy", se a regra pedir)
    if c.modo_despacho::text = 'melhor_primeiro' or (c.agendada_para > now() and c.modo_despacho::text <> 'direto')
       or (c.modo_despacho::text = 'cascata' and privado.pol_txt('despacho_sem_motoboy', 'quadro', c.empresa_id, null, c.tipo_pedido) = 'quadro') then
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
  v_ext := (c.agendada_para is null or c.agendada_para <= now()) and exists (select 1 from public.corridas k where k.motoboy_id = v_motoboy and k.status::text in ('aceita', 'em_andamento'));
  insert into public.ofertas (corrida_id, motoboy_id, rodada, distancia_m, expira_em, fator_coleta, valor, extensao)
  values (p_corrida, v_motoboy, c.rodada, round(v_dist), v_expira, v_fc,
          privado.arredondar(coalesce(c.valor_base, c.valor, 0) * (1 + coalesce(c.fator_entrega, 0) + v_fc)), v_ext)
  returning id into v_oferta;

  update public.corridas set status = 'aguardando_motoboy' where id = p_corrida;
  perform privado.evento(p_corrida, 'oferta_enviada', jsonb_build_object('motoboy_id', v_motoboy, 'distancia_m', round(v_dist), 'extensao', v_ext));
  perform privado.enviar_push(v_motoboy, jsonb_build_object(
    'tipo', 'oferta', 'extensao', v_ext::text, 'oferta_id', v_oferta::text, 'corrida_id', p_corrida::text, 'teste', c.teste::text,
    'expira_em', to_char(v_expira at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  ));
end;
$$;

create or replace function public.responder_oferta(p_oferta uuid, p_aceitar boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  o       public.ofertas%rowtype;
  v_pct   numeric;
  v_valor numeric;
  v_ativa uuid;
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
    -- extensão de rota: as paradas novas entram no fim da rota que ele já está fazendo
    if o.extensao then
      update public.ofertas set status = 'aceita', respondida_em = now() where id = p_oferta;
      v_ativa := privado.estender_rota(
        (select id from public.corridas where motoboy_id = auth.uid() and status in ('aceita', 'em_andamento') order by aceita_em desc limit 1), o.corrida_id);
      return privado.corrida_json(v_ativa);
    end if;
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

  -- ninguém reservou e a hora está chegando: avisa os motoboys online (uma vez)
  if privado.cfg_num('agendada_aviso_online_min', 60) > 0 then
    for r in
      update public.corridas set aviso_online_em = now()
       where status::text = 'agendada' and aviso_online_em is null and motoboy_id is null
         and agendada_para - make_interval(mins => privado.cfg_num('agendada_aviso_online_min', 60)::int) <= now()
      returning id, teste, agendada_para
    loop
      perform privado.evento(r.id, 'planejada_aberta', '{}');
      perform privado.enviar_push(m.id, jsonb_build_object('tipo', 'planejada_aberta', 'corrida_id', r.id::text, 'teste', r.teste::text,
                'agendada_para', to_char(r.agendada_para at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')))
         from public.motoboys m where m.modo_teste = r.teste and m.status <> 'offline';
    end loop;
  end if;

  -- ninguém reservou: despacho perto da hora, pelo modo escolhido (ou "sem motoboy" no horário)
  if privado.cfg_bool('agendada_despacho_auto', true) then
    for r in
      update public.corridas set status = 'aguardando_motoboy',
             modo_despacho = (case when privado.cfg_txt('agendada_abrir_modo', 'cascata') = 'quadro' then 'quadro' else 'cascata' end)::public.modo_despacho,
             quadro_desde = case when privado.cfg_txt('agendada_abrir_modo', 'cascata') = 'quadro' then now() else quadro_desde end,
             despacho_auto_em = now()
       where status::text = 'agendada' and despacho_auto_em is null
         and agendada_para - make_interval(mins => privado.cfg_num('agendada_despacho_auto_min', 30)::int) <= now()
      returning id, modo_despacho
    loop
      perform privado.evento(r.id, 'planejada_despachada', jsonb_build_object('automatico', true, 'modo', r.modo_despacho));
      if r.modo_despacho::text = 'quadro' then perform privado.avisar_quadro(r.id); else perform privado.despachar(r.id); end if;
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

create or replace function public.criar_pedido(dados jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_gestor  boolean := public.is_gestor() and not coalesce((dados ->> 'como_cliente')::boolean, false);
  v_regras  jsonb := '{}';
  v_cat     public.categorias_produto%rowtype;
  v_cli     uuid;
  e         public.empresas%rowtype;
  v_quando  timestamptz := nullif(dados ->> 'quando', '')::timestamptz;
  v_tipo    text;
  v_tp      text := coalesce(nullif(dados ->> 'tipo_pedido', ''), 'padrao');
  v_teste   boolean := false;
  v_id      uuid;
  v_ids     uuid[] := '{}';
  v_pid     uuid;
  v_orc     jsonb;
  v_status  text;
  v_cobr    text;
  v_dev     numeric;
  p         jsonb;
  i         jsonb;
  k         int := 0;
begin
  if v_gestor then
    v_cli := nullif(dados ->> 'empresa_id', '')::uuid;
    v_teste := coalesce((dados ->> 'teste')::boolean, (select modo_teste from public.perfis where id = auth.uid()), false);
  else
    v_cli := privado.minha_empresa();
    if v_cli is null then raise exception 'apenas_gestor_ou_cliente' using errcode = '42501'; end if;
    v_teste := privado.cliente_teste();
  end if;
  if v_gestor then v_regras := privado.limpar_regras(dados -> 'regras'); end if;
  if v_cli is not null and v_gestor and (select modo_teste from public.empresas where id = v_cli) then v_teste := true; end if;
  if v_cli is not null then select * into e from public.empresas where id = v_cli; end if;
  if not exists (select 1 from public.tipos_pedido where chave = v_tp and (ativo or v_gestor)) then raise exception 'tipo_pedido_invalido' using errcode = '22023'; end if;

  v_tipo := case when v_quando is null then 'express' else 'planejado' end;
  if not v_gestor then
    if v_tipo = 'express' and not (coalesce(e.pode_express, false) and privado.pol_bool('cliente_pode_express', true, v_cli, null, v_tp)) then
      raise exception 'cliente_so_agendado' using errcode = '42501';
    end if;
    if v_tipo = 'planejado' and not privado.pol_bool('cliente_pode_agendar', true, v_cli, null, v_tp) then
      raise exception 'cliente_sem_agendado' using errcode = '42501';
    end if;
    if v_tipo = 'planejado' and privado.pol_num('cliente_agendar_max_dias', 60, v_cli, null, v_tp) > 0
       and v_quando > now() + make_interval(days => privado.pol_num('cliente_agendar_max_dias', 60, v_cli, null, v_tp)::int) then
      raise exception 'agendamento_longe_demais' using errcode = '22023';
    end if;
    if coalesce((dados ->> 'urgente')::boolean, false) and not privado.pol_bool('cliente_pode_urgente', true, v_cli, null, v_tp) then
      raise exception 'cliente_sem_urgente' using errcode = '42501';
    end if;
    if privado.pol_num('cliente_max_entregas', 0, v_cli, null, v_tp) > 0
       and (select count(*) from jsonb_array_elements(coalesce(dados -> 'pontos', '[]')) x where x ->> 'tipo' = 'entrega') > privado.pol_num('cliente_max_entregas', 0, v_cli, null, v_tp) then
      raise exception 'entregas_demais' using errcode = '22023';
    end if;
    if privado.pol_num('cliente_max_coletas', 0, v_cli, null, v_tp) > 0
       and (select count(*) from jsonb_array_elements(coalesce(dados -> 'pontos', '[]')) x where x ->> 'tipo' = 'coleta') > privado.pol_num('cliente_max_coletas', 0, v_cli, null, v_tp) then
      raise exception 'coletas_demais' using errcode = '22023';
    end if;
    if privado.pol_num('cliente_max_pedidos_abertos', 0, v_cli, null, v_tp) > 0
       and (select count(*) from public.pedidos x where x.empresa_id = v_cli and x.teste = v_teste and x.status in ('recebido', 'aprovado', 'roteirizado', 'em_rota'))
           >= privado.pol_num('cliente_max_pedidos_abertos', 0, v_cli, null, v_tp) then
      raise exception 'pedidos_abertos_demais' using errcode = '22023';
    end if;
    -- horário em que o cliente pode pedir para agora (vazio = qualquer hora)
    if v_tipo = 'express' and privado.pol_txt('cliente_pedido_de', '', v_cli, null, v_tp) ~ '^[0-2][0-9]:[0-5][0-9]$'
       and privado.pol_txt('cliente_pedido_ate', '', v_cli, null, v_tp) ~ '^[0-2][0-9]:[0-5][0-9]$'
       and not ((now() at time zone 'America/Sao_Paulo')::time between privado.pol_txt('cliente_pedido_de', '', v_cli, null, v_tp)::time
                                                                 and privado.pol_txt('cliente_pedido_ate', '', v_cli, null, v_tp)::time) then
      raise exception 'fora_do_horario' using errcode = '22023';
    end if;
    if v_tipo = 'planejado' and v_quando < now() + make_interval(mins => privado.pol_num('agendada_antecedencia_cliente_min', 60, v_cli, null, v_tp)::int) then
      raise exception 'horario_muito_proximo' using errcode = '22023';
    end if;
  elsif v_tipo = 'planejado' and v_quando < now() then
    raise exception 'horario_passou' using errcode = '22023';
  end if;

  if (select count(*) from jsonb_array_elements(coalesce(dados -> 'pontos', '[]')) x where x ->> 'tipo' = 'coleta') < 1
     or (select count(*) from jsonb_array_elements(coalesce(dados -> 'pontos', '[]')) x where x ->> 'tipo' = 'entrega') < 1 then
    raise exception 'pedido_precisa_coleta_e_entrega' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(dados -> 'pontos') x where nullif(x ->> 'lat', '') is null or nullif(x ->> 'lng', '') is null) then
    raise exception 'ponto_sem_localizacao' using errcode = '22023';
  end if;
  if jsonb_array_length(dados -> 'pontos') > 60 then raise exception 'pontos_demais' using errcode = '22023'; end if;
  if exists (select 1 from jsonb_array_elements(dados -> 'pontos') x
              where nullif(x ->> 'janela_de', '') is not null and nullif(x ->> 'janela_ate', '') is not null
                and (x ->> 'janela_de')::time >= (x ->> 'janela_ate')::time) then
    raise exception 'janela_invalida' using errcode = '22023';
  end if;
  -- campos do item que a categoria exige
  for i in select * from jsonb_array_elements(coalesce(dados -> 'itens', '[]')) loop
    if nullif(i ->> 'categoria_id', '') is null then
      if not v_gestor and privado.cfg_bool('item_categoria_obrigatoria', false) then raise exception 'item_sem_categoria' using errcode = '22023'; end if;
      continue;
    end if;
    select * into v_cat from public.categorias_produto where id = (i ->> 'categoria_id')::uuid;
    if not found then raise exception 'categoria_invalida' using errcode = '22023'; end if;
    if v_gestor then continue; end if;
    if v_cat.campo_peso = 'obrigatorio' and coalesce(nullif(i ->> 'peso_kg', '')::numeric, 0) <= 0 then raise exception 'item_sem_peso' using errcode = '22023'; end if;
    if v_cat.campo_valor = 'obrigatorio' and coalesce(nullif(i ->> 'valor_declarado', '')::numeric, 0) <= 0 then raise exception 'item_sem_valor' using errcode = '22023'; end if;
    if v_cat.campo_descricao = 'obrigatorio' and coalesce(trim(i ->> 'descricao'), '') = '' then raise exception 'item_sem_descricao' using errcode = '22023'; end if;
    if v_cat.campo_medidas = 'obrigatorio' and (coalesce(nullif(i ->> 'comprimento_cm', '')::numeric, 0) <= 0
         or coalesce(nullif(i ->> 'largura_cm', '')::numeric, 0) <= 0 or coalesce(nullif(i ->> 'altura_cm', '')::numeric, 0) <= 0) then
      raise exception 'item_sem_medidas' using errcode = '22023';
    end if;
  end loop;
  perform privado.usar_regras(v_regras);

  v_orc := privado.orcar(jsonb_build_object('empresa_id', v_cli, 'tipo', v_tipo, 'tipo_pedido', v_tp, 'quando', v_quando,
                                            'urgente', coalesce((dados ->> 'urgente')::boolean, false), 'distancia_m', dados -> 'distancia_m',
                                            'pontos', dados -> 'pontos', 'itens', coalesce(dados -> 'itens', '[]'), 'regras', v_regras));
  v_cobr := privado.pol_txt('cobranca_modo', 'credito', v_cli, null, v_tp);
  if v_cli is null then v_cobr := 'pre_pago'; end if;
  v_status := case when v_gestor then 'aprovado'
                   when privado.pol_bool('pedido_revisao_gestor', true, v_cli, null, v_tp) then 'recebido'
                   else 'aprovado' end;
  v_dev := coalesce(e.dev_pct, privado.pol_num('dev_pct', 5, v_cli, null, v_tp));

  insert into public.pedidos (teste, empresa_id, cliente_nome, criado_por, origem, tipo, tipo_pedido, quando, urgente, status, observacoes,
                              distancia_estimada_m, orcamento, valor_calculado, valor, dev_pct, valor_dev, cobranca, pagamento_status,
                              pagamento_metodo, aprovado_em, revisado_por, revisado_em, regras)
  values (v_teste, v_cli, case when v_cli is null then nullif(trim(dados ->> 'cliente_nome'), '') end, auth.uid(),
          case when v_gestor then 'gestor' else 'cliente' end, v_tipo, v_tp, v_quando, coalesce((dados ->> 'urgente')::boolean, false),
          v_status, nullif(left(dados ->> 'observacoes', 1000), ''), (v_orc ->> 'distancia_m')::int, v_orc,
          (v_orc ->> 'total')::numeric, (v_orc ->> 'total')::numeric, v_dev, round((v_orc ->> 'total')::numeric * v_dev / 100, 2),
          v_cobr, case when v_cobr = 'pre_pago' then 'pendente' else 'nao_exigido' end, nullif(dados ->> 'metodo', ''),
          case when v_status = 'aprovado' then now() end,
          case when v_gestor then auth.uid() end, case when v_gestor then now() end, v_regras)
  returning id into v_id;

  for p in select * from jsonb_array_elements(dados -> 'pontos') loop
    -- confirmações e janela de cada ponto: o cliente só pede o que o gestor liberou para ele
    insert into public.pedido_pontos (pedido_id, ordem, tipo, endereco, lat, lng, contato_nome, contato_telefone, instrucoes, referencias,
                                      exige_foto, exige_assinatura, exige_nome, exige_codigo, janela_de, janela_ate, dist_coleta_m)
    values (v_id, k, (p ->> 'tipo')::public.tipo_parada, left(coalesce(p ->> 'endereco', ''), 300), (p ->> 'lat')::double precision, (p ->> 'lng')::double precision,
            nullif(left(p ->> 'contato_nome', 120), ''), nullif(left(p ->> 'contato_telefone', 40), ''), nullif(left(p ->> 'instrucoes', 500), ''),
            privado.limpar_referencias(p -> 'referencias'),
            case when v_gestor or privado.pol_bool('cliente_confirma_foto', true, v_cli, null, v_tp) then (p ->> 'exige_foto')::boolean end,
            case when v_gestor or privado.pol_bool('cliente_confirma_assinatura', true, v_cli, null, v_tp) then (p ->> 'exige_assinatura')::boolean end,
            case when v_gestor or privado.pol_bool('cliente_confirma_nome', true, v_cli, null, v_tp) then (p ->> 'exige_nome')::boolean end,
            case when v_gestor or privado.pol_bool('cliente_confirma_codigo', true, v_cli, null, v_tp) then (p ->> 'exige_codigo')::boolean end,
            case when v_gestor or privado.pol_bool('cliente_pode_janela', true, v_cli, null, v_tp) then nullif(p ->> 'janela_de', '')::time end,
            case when v_gestor or privado.pol_bool('cliente_pode_janela', true, v_cli, null, v_tp) then nullif(p ->> 'janela_ate', '')::time end,
            case when nullif(p ->> 'dist_coleta_m', '')::numeric between 1 and 2000000 then round((p ->> 'dist_coleta_m')::numeric)::int end)
    returning id into v_pid;
    v_ids := v_ids || v_pid;
    k := k + 1;
  end loop;

  for i in select * from jsonb_array_elements(coalesce(dados -> 'itens', '[]')) loop
    insert into public.pedido_itens (pedido_id, coleta_id, entrega_id, descricao, categoria_id, quantidade, peso_kg, comprimento_cm, largura_cm, altura_cm, valor_declarado, observacoes)
    values (v_id,
            case when nullif(i ->> 'coleta', '') is not null then v_ids[(i ->> 'coleta')::int + 1] end,
            case when nullif(i ->> 'entrega', '') is not null then v_ids[(i ->> 'entrega')::int + 1] end,
            left(coalesce(nullif(trim(i ->> 'descricao'), ''), (select nome from public.categorias_produto where id = nullif(i ->> 'categoria_id', '')::uuid), 'Item'), 200), nullif(i ->> 'categoria_id', '')::uuid,
            greatest(1, coalesce((i ->> 'quantidade')::int, 1)), nullif(i ->> 'peso_kg', '')::numeric,
            nullif(i ->> 'comprimento_cm', '')::numeric, nullif(i ->> 'largura_cm', '')::numeric, nullif(i ->> 'altura_cm', '')::numeric,
            nullif(i ->> 'valor_declarado', '')::numeric, nullif(left(i ->> 'observacoes', 300), ''));
  end loop;

  -- "dados" também é coluna de pedido_modelos: usa o parâmetro pelo nome da função
  for i in select * from jsonb_array_elements(coalesce(criar_pedido.dados -> 'objetos_usados', '[]')) loop
    update public.cliente_objetos o set usos = o.usos + 1 where o.id = (i #>> '{}')::uuid and (v_gestor or o.empresa_id = v_cli);
  end loop;
  if nullif(criar_pedido.dados ->> 'modelo_id', '') is not null then
    update public.pedido_modelos m set usos = m.usos + 1, usado_em = now() where m.id = (criar_pedido.dados ->> 'modelo_id')::uuid;
  end if;
  perform privado.usar_regras('{}');
  perform privado.evento_pedido(v_id, 'criado', jsonb_build_object('origem', case when v_gestor then 'gestor' else 'cliente' end, 'total', v_orc -> 'total'));
  if v_status = 'aprovado' then perform privado.roteirizar(v_teste); end if;
  return v_id;
end;
$$;

create or replace function privado.liberar_rota(p_corrida uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  c      public.corridas%rowtype;
  v_modo text;
  v_sug  uuid;
begin
  select * into c from public.corridas where id = p_corrida for update;
  if not found or c.status::text <> 'montada' then return; end if;
  v_modo := privado.pol_txt('despacho_modo', 'cascata', c.empresa_id, null, c.tipo_pedido);
  v_sug := privado.melhor_motoboy(p_corrida);
  update public.corridas set sugerido_motoboy_id = v_sug where id = p_corrida;
  if v_modo = 'direto' then return; end if;   -- gestor escolhe o motoboy
  if c.agendada_para is not null then
    update public.corridas set status = 'agendada', modo_despacho = 'quadro', quadro_desde = now() where id = p_corrida;
    perform privado.evento(p_corrida, 'liberada', jsonb_build_object('modo', 'quadro', 'planejada', true));
    perform privado.avisar_quadro(p_corrida);
  elsif v_modo = 'quadro' then
    update public.corridas set status = 'aguardando_motoboy', modo_despacho = 'quadro', quadro_desde = now() where id = p_corrida;
    perform privado.evento(p_corrida, 'liberada', jsonb_build_object('modo', 'quadro'));
    perform privado.avisar_quadro(p_corrida);
  else
    update public.corridas set status = 'aguardando_motoboy', modo_despacho = v_modo::public.modo_despacho where id = p_corrida;
    perform privado.evento(p_corrida, 'liberada', jsonb_build_object('modo', v_modo));
    perform privado.despachar(p_corrida);
  end if;
end;
$$;

create or replace function public.minha_conta_cliente()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_cli uuid := privado.minha_empresa(); e public.empresas%rowtype;
begin
  if v_cli is null then return null; end if;
  select * into e from public.empresas where id = v_cli;
  return jsonb_build_object(
    'id', e.id, 'nome', e.nome, 'tipo', e.tipo, 'documento', coalesce(e.cnpj, e.cpf), 'telefone', e.telefone, 'email', e.email,
    'endereco', e.endereco, 'lat', e.lat, 'lng', e.lng, 'instrucoes_coleta', e.instrucoes_coleta,
    'pode_express', e.pode_express and privado.pol_bool('cliente_pode_express', true, v_cli), 've_ao_vivo', e.cliente_ve_ao_vivo,
    'cobranca', privado.pol_txt('cobranca_modo', 'credito', v_cli), 'fatura_ciclo', privado.pol_txt('fatura_ciclo', 'semanal', v_cli),
    'metodos', to_jsonb(e.pagamento_metodos), 'antecedencia_min', privado.pol_num('agendada_antecedencia_cliente_min', 60, v_cli),
    'tipos_pedido', (select coalesce(jsonb_agg(jsonb_build_object('chave', t.chave, 'nome', t.nome, 'descricao', t.descricao, 'icone', t.icone) order by t.ordem), '[]')
                       from public.tipos_pedido t where t.ativo),
    'categorias', (select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'nome', k.nome, 'descricao', k.descricao, 'perigoso', k.perigoso,
                                                               'classe_risco', k.classe_risco, 'fragil', k.fragil, 'icone', k.icone,
                                                               'campo_descricao', k.campo_descricao, 'campo_peso', k.campo_peso, 'campo_medidas', k.campo_medidas,
                                                               'campo_valor', k.campo_valor, 'campo_quantidade', k.campo_quantidade) order by k.ordem), '[]')
                     from public.categorias_produto k where k.ativa),
    'icone', e.icone, 'teste', privado.cliente_teste(), 've_preco_na_hora', privado.cliente_ve_preco(v_cli),
    'pode_modelos', privado.pol_bool('cliente_pode_modelos', true, v_cli), 'pode_cancelar', privado.pol_bool('cliente_pode_cancelar', true, v_cli),
    'troca_senha', privado.pol_bool('cliente_troca_senha', true, v_cli),
    'confirmacoes', jsonb_build_object('foto', privado.pol_bool('cliente_confirma_foto', true, v_cli), 'nome', privado.pol_bool('cliente_confirma_nome', true, v_cli),
                                       'assinatura', privado.pol_bool('cliente_confirma_assinatura', true, v_cli), 'codigo', privado.pol_bool('cliente_confirma_codigo', true, v_cli)),
    'padrao_confirmacoes', jsonb_build_object('foto', privado.cfg_bool('padrao_exige_foto', false), 'nome', privado.cfg_bool('padrao_exige_nome', true),
                                              'assinatura', privado.cfg_bool('padrao_exige_assinatura', false), 'codigo', privado.cfg_bool('padrao_exige_codigo', false)),
    'pode_janela', privado.pol_bool('cliente_pode_janela', true, v_cli), 'pode_objetos', privado.pol_bool('cliente_pode_objetos', true, v_cli),
    'modelo_horario', privado.pol_bool('cliente_modelo_horario', true, v_cli),
    'pode_agendar', privado.pol_bool('cliente_pode_agendar', true, v_cli), 'pode_urgente', privado.pol_bool('cliente_pode_urgente', true, v_cli),
    'max_entregas', privado.pol_num('cliente_max_entregas', 0, v_cli), 'max_coletas', privado.pol_num('cliente_max_coletas', 0, v_cli),
    'agendar_max_dias', privado.pol_num('cliente_agendar_max_dias', 60, v_cli), 'pode_ida_volta', privado.pol_bool('cliente_pode_ida_volta', true, v_cli),
    'coleta_fixa', privado.pol_bool('cliente_coleta_fixa', false, v_cli), 'pode_observacoes', privado.pol_bool('cliente_pode_observacoes', true, v_cli),
    've_faturas', privado.pol_bool('cliente_ve_faturas', true, v_cli), 'pode_chat', privado.pol_bool('cliente_pode_chat', true, v_cli),
    'pedido_de', privado.pol_txt('cliente_pedido_de', '', v_cli), 'pedido_ate', privado.pol_txt('cliente_pedido_ate', '', v_cli),
    'modo_distancia', privado.pol_txt('preco_distancia_modo', 'soma_entregas', v_cli), 'categoria_obrigatoria', privado.cfg_bool('item_categoria_obrigatoria', false),
    'em_aberto', (select coalesce(sum(valor), 0) from public.pedidos where empresa_id = v_cli and teste = privado.cliente_teste() and cobranca = 'credito' and fatura_id is null and status = 'concluido'));
end;
$$;


revoke all on function privado.estender_rota(uuid, uuid) from public, anon, authenticated;


create or replace function privado.dividir_valor()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_calc jsonb; v_dev numeric; v_valor numeric; v_teto numeric; v_moto numeric; v_orig text;
begin
  if new.motoboy_id is not null and new.status::text in ('aceita', 'em_andamento', 'concluida') and (
       old.status is distinct from new.status or old.valor is distinct from new.valor or old.pag_ajuste is distinct from new.pag_ajuste
       or old.motoboy_id is distinct from new.motoboy_id or old.valor_motoboy is distinct from new.valor_motoboy
       or old.repasse_manual is distinct from new.repasse_manual or old.dev_manual is distinct from new.dev_manual) then
    v_valor := coalesce(new.valor, 0);
    v_dev := privado.dev_da_corrida(new);
    v_teto := greatest(round(v_valor - v_valor * v_dev / 100, 2), 0);
    v_orig := privado.pol_txt('dev_origem', 'gestor', new.empresa_id, null, new.tipo_pedido);
    v_calc := privado.calcular_pagamento(new.id, new.motoboy_id);
    if v_calc ->> 'modo' = 'percentual' then
      -- o valor pode ter mudado nesta mesma atualização: refaz com o valor novo
      v_calc := v_calc || jsonb_build_object('total', privado.parte_motoboy(v_valor, (v_calc ->> 'pct')::numeric, v_dev, v_orig), 'valor_rota', v_valor);
      new.repasse_pct := (v_calc ->> 'pct')::numeric;
    end if;
    -- por km: o cálculo antes do teto (o teto é aplicado aqui, com o valor novo da rota)
    v_moto := round(coalesce((v_calc ->> 'calculado')::numeric, (v_calc ->> 'total')::numeric) + coalesce(new.pag_ajuste, 0), 2);
    v_calc := v_calc || jsonb_build_object('total', least(greatest(v_moto - coalesce(new.pag_ajuste, 0), 0), v_teto));
    v_calc := v_calc || jsonb_build_object('teto', v_teto, 'limitado', v_moto > v_teto or coalesce((v_calc ->> 'limitado')::boolean, false));
    new.pag_calculo := v_calc;
    -- piso da extensão de rota (nunca acima do teto)
    new.valor_motoboy := greatest(least(greatest(v_moto, coalesce(new.pag_piso, 0)), v_teto), 0);
    new.dev_pct := v_dev;
    new.valor_dev := round(v_valor * v_dev / 100, 2);
    new.valor_gestao := v_valor - new.valor_motoboy - new.valor_dev;
  end if;
  return new;
end;
$$;


notify pgrst, 'reload schema';
