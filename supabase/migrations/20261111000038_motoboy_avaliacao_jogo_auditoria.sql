-- =====================================================================
-- Delibra · 0038: motoboy sem internet, fechamento automático, emergência, pular parada,
--                  avaliações, rastreio público, jogo (moedas, loja, ranking), auditoria,
--                  tema por pessoa, domínio do site e tag PAGO
-- =====================================================================
set check_function_bodies = off;

insert into public.configuracoes (chave, valor) values
  ('dev_site_url', '""'),
  ('offline_finalizar_ligado', 'true'), ('auto_fechar_ligado', 'true'), ('auto_fechar_folga_min', '5'), ('auto_fechar_vel_kmh', '25'),
  ('emergencia_ligada', 'true'), ('emergencia_avisa_gestor', 'true'), ('emergencia_avisa_supervisor', 'true'), ('dev_emergencia_receber', 'false'),
  ('dev_emergencia_orgs', '[]'),
  ('saas_pular_parada', 'true'), ('pular_parada_ligado', 'true'), ('motoboy_pode_pular', 'false'), ('motoboy_pede_pular', 'true'), ('pen_pts_pulo', '0'),
  ('motoboy_pode_cancelar', 'false'), ('motoboy_pode_finalizar', 'false'),
  ('saas_avaliacoes', 'true'), ('avaliacao_ligada', 'true'), ('avaliacao_quem', '"cliente"'), ('avaliacao_ruim_ate', '2'), ('pen_pts_avaliacao_ruim', '1'),
  ('avaliacao_avisa_gestor', 'true'), ('saas_cliente_ve_nota_motoboy', 'true'), ('cliente_ve_nota_motoboy', 'false'),
  ('saas_rastreio', 'true'), ('rastreio_ligado', 'true'), ('rastreio_validade_h', '24'), ('rastreio_envio', '"copiar"'), ('rastreio_mostra_motoboy', 'true'),
  ('dev_jogo_moedas_corrida', '10'), ('dev_jogo_moedas_entrega', '3'), ('dev_jogo_moedas_km', '1'), ('dev_jogo_moedas_avaliacao5', '5'),
  ('dev_jogo_moedas_pacote', '1'), ('dev_jogo_vel_max_kmh', '8'), ('dev_jogo_ranking', 'true'),
  ('auditoria_ligada', 'true'), ('saas_dois_passos', 'false'), ('saas_cadastro_empresas', 'false'), ('saas_teste_dias', '14')
on conflict (chave) do nothing;

-- ===================================================================== tema por pessoa (app e site)
alter table public.perfis add column if not exists tema jsonb not null default '{}'::jsonb;
create or replace function public.salvar_meu_tema(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb;
begin
  if auth.uid() is null then raise exception 'nao_autenticado' using errcode = '28000'; end if;
  if jsonb_typeof(p) <> 'object' then raise exception 'tema_invalido' using errcode = '22023'; end if;
  update public.perfis set tema = (tema || (select coalesce(jsonb_object_agg(k, x), '{}'::jsonb) from jsonb_each(p) e(k, x)
           where k in ('preferencia', 'estilo', 'fonte', 'numero_barra', 'idioma') and jsonb_typeof(x) in ('string', 'boolean')))
   where id = auth.uid() returning tema into v;
  return v;
end;
$$;

create or replace function public.meu_perfil()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', p.id,
    'nome', p.nome,
    'foto_url', p.foto_url,
    'papeis', to_jsonb(p.papeis),
    'gestor', 'gestor' = any (p.papeis) or 'dev' = any (p.papeis) or 'supervisor' = any (p.papeis),
    'motoboy', 'motoboy' = any (p.papeis),
    'dev', 'dev' = any (p.papeis),
    'cor_tema', p.cor_tema, 'tema', p.tema,
    'modo_teste', coalesce(m.modo_teste, p.modo_teste),
    'suspenso_ate', case when m.suspenso_ate > now() then m.suspenso_ate end, 'suspenso_motivo', case when m.suspenso_ate > now() then m.suspenso_motivo end,
    'raio', jsonb_build_object('km', m.raio_km, 'modo', coalesce(m.raio_modo, 'posicao'), 'lat', m.raio_lat, 'lng', m.raio_lng),
    'modulos', coalesce((
      select jsonb_object_agg(md.chave,
        'dev' = any (p.papeis) or (md.ligado and (md.papeis is null or p.papeis && md.papeis)))
        from public.modulos md
    ), '{}'::jsonb),
    'holerite_visivel', privado.pol_bool('motoboy_ve_holerite', true, null, p.id, null),
    'supervisor', 'supervisor' = any (p.papeis),
    'permissoes', p.permissoes,
    'dev_oculto', p.dev_oculto,
    'organizacao', (select jsonb_build_object('id', o.id, 'nome', o.nome, 'nome_app', o.nome_app, 'nome_topo', o.nome_topo, 'nomes', o.nomes, 'logo', o.logo_url, 'logo_escala', o.logo_escala, 'logo_original', o.logo_original_url, 'brilho_cor', o.logo_brilho_cor, 'brilho', o.logo_brilho, 'fonte', o.fonte_nome, 'cor', o.cor, 'status', o.status, 'suspensa_motivo', case when o.status in ('suspensa', 'cancelada') then o.suspensa_motivo end)
                      from public.organizacoes o where o.id = case when 'dev' = any (p.papeis) and p.dev_vazio then null else coalesce(case when 'dev' = any (p.papeis) then p.org_em_foco end, p.organizacao_id) end),
    'configuracoes', coalesce((
      select jsonb_object_agg(k, v) from jsonb_each(public.ajustes()) e(k, v)
       where k in ('intervalo_corrida_s', 'intervalo_economia_s', 'disponivel_envio_min',
                       'disponivel_distancia_m', 'raio_chegada_m', 'teste_admin_ignora_local', 'oferta_segundos',
                       'quadro_mostra_enderecos', 'quadro_mostra_itens', 'simulador_ligado', 'simulador_velocidade_kmh',
                       'motoboy_edita_veiculo', 'mapa_offline_some_h', 'mapa_offline_esmaecer', 'veiculo_obrigatorio',
                       'rota_provedor', 'rota_perfil', 'chat_ligado', 'chat_geral', 'chat_fotos', 'ping_envio_s',
                       'chat_compartilhar', 'chat_compartilhar_tipos', 'chat_grupos_equipe', 'pagamento_na_plataforma', 'compartilhar_motoboy_resumo',
                       'usuario_troca_senha', 'perfil_publico_ligado', 'chat_motoboy_abre_rota', 'chat_rota_respostas',
                       'lembrar_pagina', 'passar_corrida_ligado', 'pedido_confirmar_revisao', 'chamado_motoboy_pode',
                       'dev_site_url', 'offline_finalizar_ligado', 'emergencia_ligada', 'motoboy_pede_pular', 'dev_jogo_vel_max_kmh', 'dev_jogo_ranking')
    ), '{}'::jsonb)
    -- o que pode mudar por motoboy (regra dele > geral)
    || jsonb_build_object(
      'intervalo_corrida_s', privado.pol_num('intervalo_corrida_s', 6, null, p.id, null),
      'intervalo_economia_s', privado.pol_num('intervalo_economia_s', 20, null, p.id, null),
      'disponivel_envio_min', privado.pol_num('disponivel_envio_min', 3, null, p.id, null),
      'disponivel_distancia_m', privado.pol_num('disponivel_distancia_m', 300, null, p.id, null),
      'ping_distancia_m', privado.pol_num('ping_distancia_m', 20, null, p.id, null),
      'ping_precisao_max_m', privado.pol_num('ping_precisao_max_m', 60, null, p.id, null),
      'navegacao_ligada', privado.pol_bool('navegacao_ligada', true, null, p.id, null),
      'navegacao_voz', privado.pol_bool('navegacao_voz', true, null, p.id, null),
      'navegacao_recalcular_m', privado.pol_num('navegacao_recalcular_m', 60, null, p.id, null),
      'navegacao_na_notificacao', privado.pol_bool('navegacao_na_notificacao', true, null, p.id, null),
      'motoboy_edita_veiculo', privado.pol_bool('motoboy_edita_veiculo', false, null, p.id, null),
      'ping_inteligente', privado.pol_bool('ping_inteligente', true, null, p.id, null),
      'ping_curva_graus', privado.pol_num('ping_curva_graus', 25, null, p.id, null),
      'ping_reta_max_m', privado.pol_num('ping_reta_max_m', 200, null, p.id, null),
      'jogo_ligado', privado.pol_bool('jogo_ligado', true, null, p.id, null),
      'jogo_toques', privado.pol_num('jogo_toques', 5, null, p.id, null),
      'motoboy_pode_pular', privado.cfg_bool('saas_pular_parada', true) and privado.pol_bool('motoboy_pode_pular', false, null, p.id, null),
      'motoboy_pode_cancelar', privado.pol_bool('motoboy_pode_cancelar', false, null, p.id, null),
      'motoboy_pode_finalizar', privado.pol_bool('motoboy_pode_finalizar', false, null, p.id, null))
  )
  from public.perfis p
  left join public.motoboys m on m.id = p.id
  where p.id = auth.uid();
$$;

alter table public.paradas add column if not exists liberada_local boolean not null default false;
alter table public.paradas add column if not exists feita_offline boolean not null default false;
alter table public.paradas add column if not exists confirmacao_pendente boolean not null default false;
alter table public.corridas add column if not exists aguardando_confirmacao boolean not null default false;

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
  -- etapa feita sem internet chegando depois que a corrida fechou sozinha: só completa os dados
  if p.confirmacao_pendente and c.motoboy_id = auth.uid() and p_acao = 'concluir' then
    update public.paradas set confirmacao_pendente = false, feita_offline = true,
           concluida_em = coalesce(privado.quando_offline(v_dados), concluida_em),
           recebedor_nome = coalesce(nullif(trim(v_dados ->> 'recebedor_nome'), ''), recebedor_nome),
           foto_path = coalesce(nullif(v_dados ->> 'foto_path', ''), foto_path),
           assinatura_path = coalesce(nullif(v_dados ->> 'assinatura_path', ''), assinatura_path)
     where id = p.id;
    if not exists (select 1 from public.paradas where corrida_id = c.id and confirmacao_pendente) then
      update public.corridas set aguardando_confirmacao = false where id = c.id;
      perform privado.evento(c.id, 'confirmada_offline');
    end if;
    return privado.corrida_json(c.id);
  end if;
  if p.confirmacao_pendente and c.motoboy_id = auth.uid() then return privado.corrida_json(c.id); end if;
  if c.motoboy_id is distinct from auth.uid() or c.status not in ('aceita', 'em_andamento') then
    raise exception 'corrida_nao_esta_ativa' using errcode = '22023';
  end if;
  if p_acao not in ('chegou', 'concluir') then raise exception 'acao_invalida' using errcode = '22023'; end if;

  select min(ordem) into v_atual from public.paradas where corrida_id = c.id and status <> 'concluida';
  if p.ordem <> v_atual then raise exception 'conclua_a_parada_anterior' using errcode = '22023'; end if;

  -- presença no local
  select d.distancia_m, d.tolerancia_m into v_dist, v_tol from privado.distancia_ate_parada(p, v_dados, auth.uid()) d;
  if c.exigir_no_local then
    v_ignorar := (coalesce((v_dados ->> 'ignorar_local')::boolean, false)
                  and c.teste and public.is_gestor()
                  and privado.cfg_bool('teste_admin_ignora_local', true))
                 -- o gestor liberou esta parada (pular o raio)
                 or p.liberada_local
                 -- o gestor deu ao motoboy a liberdade de pular
                 or (coalesce((v_dados ->> 'ignorar_local')::boolean, false) and privado.cfg_bool('saas_pular_parada', true)
                     and privado.pol_bool('motoboy_pode_pular', false, c.empresa_id, auth.uid(), c.tipo_pedido));
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
       set status = 'chegou', chegou_em = coalesce(privado.quando_offline(v_dados), now()), feita_offline = feita_offline or (v_dados ->> 'offline') = 'true',
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
         chegou_em = coalesce(chegou_em, privado.quando_offline(v_dados), now()),
         concluida_em = coalesce(privado.quando_offline(v_dados), now()),
         feita_offline = feita_offline or (v_dados ->> 'offline') = 'true',
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

-- nunca aceita hora no futuro nem com mais de 24 h (vale para o que veio do celular)
create or replace function privado.quando_offline(d jsonb)
returns timestamptz language plpgsql stable set search_path = '' as $$
declare v timestamptz;
begin
  if d ->> 'feito_em' is null then return null; end if;
  v := (d ->> 'feito_em')::timestamptz;
  if v > now() + interval '2 minutes' or v < now() - interval '24 hours' then return null; end if;
  return least(v, now());
exception when others then return null;
end;
$$;

-- Fechamento automático: motoboy sem dar notícia, e já passou da hora que ele chegaria (pela velocidade
-- média na corrida e a distância do último ping até as paradas que faltam) mais a folga do gestor.
create or replace function privado.fechar_sem_noticia()
returns int language plpgsql security definer set search_path = '' as $$
declare
  c record; v_ult record; v_vel double precision; v_dist double precision; v_previsto timestamptz; v_n int := 0;
  v_folga numeric; v_lat double precision; v_lng double precision; pa record;
begin
  for c in select k.* from public.corridas k where k.status::text = 'em_andamento' and k.motoboy_id is not null loop
    continue when not privado.cfg_org_bool(c.organizacao_id, 'auto_fechar_ligado', true);
    v_folga := privado.cfg_org_num(c.organizacao_id, 'auto_fechar_folga_min', 5);
    select lat, lng, registrado_em into v_ult from public.localizacoes where corrida_id = c.id order by registrado_em desc limit 1;
    if v_ult.registrado_em is null then
      select lat, lng, posicao_em as registrado_em into v_ult from public.motoboys where id = c.motoboy_id;
    end if;
    continue when v_ult.registrado_em is null or v_ult.registrado_em > now() - make_interval(mins => greatest(v_folga, 1)::int);
    -- velocidade média nesta corrida (m/s); sem dado, a do ajuste
    select case when extract(epoch from (max(registrado_em) - min(registrado_em))) > 60
                then coalesce(c.distancia_real_m, 0) / extract(epoch from (max(registrado_em) - min(registrado_em))) end
      into v_vel from public.localizacoes where corrida_id = c.id;
    v_vel := greatest(coalesce(nullif(v_vel, 0), privado.cfg_org_num(c.organizacao_id, 'auto_fechar_vel_kmh', 25) / 3.6), 2);
    v_dist := 0; v_lat := v_ult.lat; v_lng := v_ult.lng;
    for pa in select lat, lng from public.paradas where corrida_id = c.id and status::text <> 'concluida' order by ordem loop
      v_dist := v_dist + privado.dist_m(v_lat, v_lng, pa.lat, pa.lng) * 1.3; v_lat := pa.lat; v_lng := pa.lng;
    end loop;
    v_previsto := v_ult.registrado_em + make_interval(secs => (v_dist / v_vel)::int) + make_interval(mins => v_folga::int);
    continue when now() < v_previsto;
    update public.paradas set status = 'concluida', concluida_em = coalesce(concluida_em, now()), chegou_em = coalesce(chegou_em, now()),
           confirmacao_pendente = true
     where corrida_id = c.id and status::text <> 'concluida';
    update public.corridas set status = 'concluida', concluida_em = now(), aguardando_confirmacao = true where id = c.id;
    update public.motoboys set status = 'disponivel', status_em = now() where id = c.motoboy_id and status = 'em_corrida';
    begin perform privado.finalizar_trajeto(c.id, false); exception when others then null; end;
    perform privado.evento(c.id, 'fechada_sem_noticia', jsonb_build_object('previsto', v_previsto));
    begin
      perform privado.avisar_gestores(c.organizacao_id, jsonb_build_object('tipo', 'corrida_fechada_auto', 'corrida_id', c.id::text,
        'titulo', 'Rota ' || case when c.teste then 'T' else '#' end || c.numero || ' fechada sozinha',
        'texto', 'O motoboy ficou sem sinal. Ficou como "Aguardando confirmação" até o app mandar as etapas.'), 'pedidos');
    exception when others then null;
    end;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
revoke execute on function privado.fechar_sem_noticia(), privado.quando_offline(jsonb) from public, anon, authenticated;

-- gestor libera a parada (pula o raio). p_penalizar: decide na hora.
create or replace function public.liberar_parada(p_parada uuid, p_penalizar boolean default false, p_motivo text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p public.paradas%rowtype; c public.corridas%rowtype;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select * into p from public.paradas where id = p_parada;
  if not found or not public.ve_corrida(p.corrida_id) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  select * into c from public.corridas where id = p.corrida_id;
  if not privado.cfg_bool('saas_pular_parada', true) or not privado.cfg_org_bool(c.organizacao_id, 'pular_parada_ligado', true) then
    raise exception 'pular_desligado' using errcode = '42501';
  end if;
  update public.paradas set liberada_local = true where id = p_parada;
  update public.chamados_corrida set status = 'aprovado', respondido_por = auth.uid(), respondido_em = now(), resposta = nullif(trim(p_motivo), '')
   where corrida_id = c.id and tipo = 'pular' and parada_id = p_parada and status = 'pendente';
  perform privado.evento(c.id, 'parada_liberada', jsonb_build_object('parada', p.ordem, 'motivo', nullif(trim(p_motivo), '')));
  if p_penalizar and c.motoboy_id is not null and not c.teste then
    perform privado.penalizar(c.organizacao_id, 'motoboy', c.motoboy_id, 'pulo', greatest(privado.cfg_org_num(c.organizacao_id, 'pen_pts_pulo', 0), 1),
      coalesce(nullif(trim(p_motivo), ''), 'Parada liberada fora do raio'), c.id);
  end if;
  if c.motoboy_id is not null then
    begin
      perform privado.enviar_push(c.motoboy_id, jsonb_build_object('tipo', 'parada_liberada', 'corrida_id', c.id::text,
        'titulo', 'Parada liberada', 'texto', 'O gestor liberou a parada ' || (p.ordem + 1) || ': pode confirmar de onde está.'));
    exception when others then null;
    end;
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- motoboy pede para pular (como o pedido de cancelamento)
alter table public.chamados_corrida drop constraint if exists chamados_corrida_tipo_check;
alter table public.chamados_corrida add constraint chamados_corrida_tipo_check check (tipo in ('cancelar', 'pular'));
alter table public.chamados_corrida add column if not exists parada_id uuid references public.paradas (id) on delete cascade;
drop index if exists public.chamados_corrida_um_pendente;
create unique index if not exists chamados_corrida_um_pendente on public.chamados_corrida (corrida_id, tipo) where status = 'pendente';

create or replace function public.pedir_pular_parada(p_parada uuid, p_motivo text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p public.paradas%rowtype; c public.corridas%rowtype; v_id uuid;
begin
  select * into p from public.paradas where id = p_parada;
  select * into c from public.corridas where id = p.corrida_id;
  if c.id is null or c.motoboy_id is distinct from auth.uid() or c.status::text not in ('aceita', 'em_andamento') then raise exception 'corrida_nao_e_sua' using errcode = '42501'; end if;
  if not privado.cfg_bool('saas_pular_parada', true) or not privado.pol_bool('motoboy_pede_pular', true, c.empresa_id, auth.uid(), c.tipo_pedido) then
    raise exception 'pular_desligado' using errcode = '42501';
  end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'informe_o_motivo' using errcode = '22023'; end if;
  if exists (select 1 from public.chamados_corrida where corrida_id = c.id and tipo = 'pular' and status = 'pendente') then raise exception 'chamado_ja_aberto' using errcode = '22023'; end if;
  insert into public.chamados_corrida (organizacao_id, corrida_id, motoboy_id, motivo, tipo, parada_id)
  values (c.organizacao_id, c.id, auth.uid(), left(trim(p_motivo), 500), 'pular', p_parada) returning id into v_id;
  perform privado.evento(c.id, 'pediu_pular', jsonb_build_object('parada', p.ordem, 'motivo', trim(p_motivo)));
  perform privado.avisar_gestores(c.organizacao_id, jsonb_build_object('tipo', 'chamado_pular', 'chamado_id', v_id::text, 'corrida_id', c.id::text,
    'titulo', public.nome_publico(auth.uid()) || ' pede para liberar a parada ' || (p.ordem + 1), 'texto', left(trim(p_motivo), 140)), 'pedidos');
  return privado.chamado_json(v_id);
end;
$$;

create or replace function public.responder_chamado(p_chamado uuid, p_aprovar boolean, p_resposta text default null, p_penalizar boolean default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare h public.chamados_corrida%rowtype; c public.corridas%rowtype;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select * into h from public.chamados_corrida where id = p_chamado for update;
  if not found or not public.ve_org(h.organizacao_id) then raise exception 'chamado_nao_encontrado' using errcode = '22023'; end if;
  if h.status <> 'pendente' then raise exception 'chamado_ja_respondido' using errcode = '22023'; end if;
  select * into c from public.corridas where id = h.corrida_id;
  -- pedido para pular uma parada: aprovar libera o raio dela
  if h.tipo = 'pular' then
    update public.chamados_corrida set status = case when p_aprovar then 'aprovado' else 'negado' end, resposta = nullif(trim(p_resposta), ''),
           respondido_por = auth.uid(), respondido_em = now() where id = p_chamado;
    if p_aprovar then
      update public.paradas set liberada_local = true where id = h.parada_id;
      if coalesce(p_penalizar, false) and not c.teste then
        perform privado.penalizar(h.organizacao_id, 'motoboy', h.motoboy_id, 'pulo', greatest(privado.cfg_org_num(h.organizacao_id, 'pen_pts_pulo', 0), 1), 'Parada liberada fora do raio', c.id);
      end if;
    end if;
    perform privado.enviar_push(h.motoboy_id, jsonb_build_object('tipo', 'chamado_respondido', 'chamado_id', p_chamado::text, 'corrida_id', c.id::text, 'pular', 'true',
      'aprovado', 'false', 'titulo', case when p_aprovar then 'Parada liberada' else 'Liberação negada' end,
      'texto', coalesce(nullif(trim(p_resposta), ''), case when p_aprovar then 'Pode confirmar a parada de onde está.' else 'Chegue ao endereço para confirmar.' end)));
    return privado.chamado_json(p_chamado);
  end if;
  update public.chamados_corrida set status = case when p_aprovar then 'aprovado' else 'negado' end, resposta = nullif(trim(p_resposta), ''),
         respondido_por = auth.uid(), respondido_em = now() where id = p_chamado;
  if p_aprovar then
    if c.motoboy_id = h.motoboy_id and c.status::text in ('aceita', 'em_andamento', 'reservada') then
      perform privado.devolver_rota(c.id, 'cancelamento_aprovado');
    end if;
    if coalesce(p_penalizar, privado.cfg_org_num(h.organizacao_id, 'pen_pts_desistencia', 2) > 0) and not c.teste then
      perform privado.penalizar(h.organizacao_id, 'motoboy', h.motoboy_id, 'desistencia',
        greatest(privado.cfg_org_num(h.organizacao_id, 'pen_pts_desistencia', 2), case when p_penalizar then 1 else 0 end), 'Desistiu da rota (cancelamento aprovado)', c.id);
    end if;
  end if;
  perform privado.enviar_push(h.motoboy_id, jsonb_build_object('tipo', 'chamado_respondido', 'chamado_id', p_chamado::text, 'corrida_id', c.id::text,
    'aprovado', p_aprovar::text,
    'titulo', case when p_aprovar then 'Cancelamento aprovado' else 'Cancelamento negado' end,
    'texto', coalesce(nullif(trim(p_resposta), ''), case when p_aprovar then 'A rota saiu de você. Pode parar.' else 'Siga com a rota como combinado.' end)));
  return privado.chamado_json(p_chamado);
end;
$$;

create or replace function privado.chamado_json(p_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select to_jsonb(h) || jsonb_build_object(
    'corrida_numero', c.numero, 'corrida_teste', c.teste, 'corrida_status', c.status, 'motoboy_nome', public.nome_publico(h.motoboy_id),
    'feitas', (select count(*) from public.paradas p where p.corrida_id = c.id and p.status::text = 'concluida'),
    'paradas', (select count(*) from public.paradas p where p.corrida_id = c.id),
    'parada_ordem', (select p.ordem from public.paradas p where p.id = h.parada_id), 'parada_endereco', (select p.endereco from public.paradas p where p.id = h.parada_id))
    from public.chamados_corrida h join public.corridas c on c.id = h.corrida_id where h.id = p_id;
$$;

create or replace function public.meu_chamado(p_corrida uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select privado.chamado_json(h.id) from public.chamados_corrida h
   where h.corrida_id = p_corrida and h.motoboy_id = auth.uid() and h.tipo = 'cancelar' order by h.criado_em desc limit 1;
$$;

create or replace function public.meu_pedido_pular(p_corrida uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select privado.chamado_json(h.id) from public.chamados_corrida h
   where h.corrida_id = p_corrida and h.motoboy_id = auth.uid() and h.tipo = 'pular' order by h.criado_em desc limit 1;
$$;

-- ===================================================================== emergência
create table if not exists public.emergencias (
  id             uuid primary key default gen_random_uuid(),
  organizacao_id uuid references public.organizacoes (id) on delete cascade,
  motoboy_id     uuid not null references public.perfis (id) on delete cascade,
  corrida_id     uuid references public.corridas (id) on delete set null,
  lat double precision, lng double precision, precisao_m real,
  criado_em      timestamptz not null default now(),
  resolvida_em   timestamptz, resolvida_por uuid references public.perfis (id) on delete set null, nota text
);
create index if not exists emergencias_org on public.emergencias (organizacao_id, criado_em desc);
alter table public.emergencias enable row level security;
drop policy if exists emergencias_leitura on public.emergencias;
create policy emergencias_leitura on public.emergencias for select to authenticated using ((select public.is_gestor()) or motoboy_id = (select auth.uid()));
drop policy if exists org_isolamento on public.emergencias;
create policy org_isolamento on public.emergencias as restrictive for all to authenticated
  using (public.ve_org(organizacao_id) or motoboy_id = (select auth.uid()) or public.is_dev()) with check (public.ve_org(organizacao_id));
grant select on public.emergencias to authenticated;

create or replace function public.acionar_emergencia(p_lat double precision default null, p_lng double precision default null, p_precisao real default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_org uuid; v_id uuid; v_cor uuid; v_nome text; r record; v_dados jsonb; v_mb record;
begin
  if auth.uid() is null then raise exception 'nao_autenticado' using errcode = '28000'; end if;
  select organizacao_id into v_org from public.perfis where id = auth.uid();
  if not privado.cfg_org_bool(v_org, 'emergencia_ligada', true) then raise exception 'emergencia_desligada' using errcode = '42501'; end if;
  select id into v_cor from public.corridas where motoboy_id = auth.uid() and status::text in ('aceita', 'em_andamento') order by aceita_em desc limit 1;
  if p_lat is null then select lat, lng into v_mb from public.motoboys where id = auth.uid(); p_lat := v_mb.lat; p_lng := v_mb.lng; end if;
  insert into public.emergencias (organizacao_id, motoboy_id, corrida_id, lat, lng, precisao_m) values (v_org, auth.uid(), v_cor, p_lat, p_lng, p_precisao) returning id into v_id;
  v_nome := public.nome_publico(auth.uid());
  v_dados := jsonb_build_object('tipo', 'emergencia', 'emergencia_id', v_id::text, 'corrida_id', coalesce(v_cor::text, ''), 'lat', coalesce(p_lat::text, ''), 'lng', coalesce(p_lng::text, ''),
    'titulo', 'EMERGÊNCIA: ' || v_nome, 'texto', v_nome || ' apertou o botão de emergência. Toque para ver onde ele está.');
  for r in
    select p.id from public.perfis p
     where p.organizacao_id = v_org and p.id <> auth.uid()
       and (('gestor' = any (p.papeis) and privado.cfg_org_bool(v_org, 'emergencia_avisa_gestor', true))
         or ('supervisor' = any (p.papeis) and privado.cfg_org_bool(v_org, 'emergencia_avisa_supervisor', true)))
    union
    -- o Dev recebe se ligou para todos, para esta empresa ou para este motoboy
    select p.id from public.perfis p
     where 'dev' = any (p.papeis) and (privado.cfg_bool('dev_emergencia_receber', false)
           or coalesce(privado.cfg('dev_emergencia_orgs', '[]'::jsonb) ? v_org::text, false)
           or exists (select 1 from public.politicas x where x.escopo = 'motoboy' and x.alvo = auth.uid()::text and x.chave = 'dev_emergencia_receber' and x.valor = 'true'::jsonb))
  loop
    begin perform privado.enviar_push(r.id, v_dados); exception when others then null; end;
  end loop;
  if v_cor is not null then perform privado.evento(v_cor, 'emergencia', jsonb_build_object('lat', p_lat, 'lng', p_lng)); end if;
  return jsonb_build_object('id', v_id);
end;
$$;

create or replace function public.resolver_emergencia(p_id uuid, p_nota text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.emergencias set resolvida_em = now(), resolvida_por = auth.uid(), nota = nullif(trim(p_nota), '')
   where id = p_id and resolvida_em is null and (public.is_gestor() and public.ve_org(organizacao_id) or public.is_dev() or motoboy_id = auth.uid());
  if not found then raise exception 'emergencia_nao_encontrada' using errcode = '22023'; end if;
end;
$$;

create or replace function public.emergencias_abertas()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'motoboy_id', e.motoboy_id, 'motoboy_nome', public.nome_publico(e.motoboy_id), 'corrida_id', e.corrida_id,
           'lat', e.lat, 'lng', e.lng, 'criado_em', e.criado_em, 'resolvida_em', e.resolvida_em) order by e.criado_em desc), '[]'::jsonb)
    from public.emergencias e
   where (public.is_gestor() and public.ve_org(e.organizacao_id) or public.is_dev()) and (e.resolvida_em is null or e.criado_em > now() - interval '1 day');
$$;

-- ===================================================================== avaliações
create table if not exists public.avaliacoes (
  id             uuid primary key default gen_random_uuid(),
  organizacao_id uuid references public.organizacoes (id) on delete cascade,
  corrida_id     uuid references public.corridas (id) on delete set null,
  pedido_id      uuid references public.pedidos (id) on delete set null,
  motoboy_id     uuid references public.perfis (id) on delete set null,
  empresa_id     uuid references public.empresas (id) on delete set null,
  autor          text not null check (autor in ('cliente', 'recebedor')),
  autor_id       uuid references public.perfis (id) on delete set null,
  nota           smallint not null check (nota between 1 and 5),
  comentario     text check (comentario is null or char_length(comentario) <= 500),
  criado_em      timestamptz not null default now()
);
create unique index if not exists avaliacoes_uma_por_autor on public.avaliacoes (pedido_id, autor, coalesce(corrida_id, '00000000-0000-0000-0000-000000000000'::uuid));
create index if not exists avaliacoes_motoboy on public.avaliacoes (motoboy_id, criado_em desc);
alter table public.avaliacoes enable row level security;
drop policy if exists avaliacoes_leitura on public.avaliacoes;
create policy avaliacoes_leitura on public.avaliacoes for select to authenticated
  using ((select public.is_gestor()) or motoboy_id = (select auth.uid()) or empresa_id = privado.minha_empresa());
drop policy if exists org_isolamento on public.avaliacoes;
create policy org_isolamento on public.avaliacoes as restrictive for all to authenticated
  using (public.ve_org(organizacao_id) or motoboy_id = (select auth.uid()) or empresa_id = privado.minha_empresa()) with check (false);
grant select on public.avaliacoes to authenticated;

create or replace function privado.registrar_avaliacao(p_pedido uuid, p_autor text, p_autor_id uuid, p_nota int, p_comentario text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare pd public.pedidos%rowtype; c public.corridas%rowtype; v_id uuid;
begin
  select * into pd from public.pedidos where id = p_pedido;
  if not found then raise exception 'pedido_nao_encontrado' using errcode = '22023'; end if;
  if not privado.cfg_bool('saas_avaliacoes', true) or not privado.pol_bool('avaliacao_ligada', true, pd.empresa_id) then raise exception 'avaliacao_desligada' using errcode = '42501'; end if;
  if privado.pol_txt('avaliacao_quem', 'cliente', pd.empresa_id) not in (p_autor, 'ambos') then raise exception 'avaliacao_desligada' using errcode = '42501'; end if;
  if p_nota not between 1 and 5 then raise exception 'nota_invalida' using errcode = '22023'; end if;
  select k.* into c from public.corridas k join public.paradas pa on pa.corrida_id = k.id
   where pa.pedido_id = p_pedido and k.status::text = 'concluida' order by k.concluida_em desc limit 1;
  if c.id is null then raise exception 'avalie_depois_da_entrega' using errcode = '22023'; end if;
  insert into public.avaliacoes (organizacao_id, corrida_id, pedido_id, motoboy_id, empresa_id, autor, autor_id, nota, comentario)
  values (pd.organizacao_id, c.id, p_pedido, c.motoboy_id, pd.empresa_id, p_autor, p_autor_id, p_nota, nullif(left(trim(coalesce(p_comentario, '')), 500), ''))
  on conflict do nothing returning id into v_id;
  if v_id is null then raise exception 'ja_avaliado' using errcode = '22023'; end if;
  -- nota ruim: penalidade e aviso (os dois desligáveis)
  if p_nota <= privado.cfg_org_num(pd.organizacao_id, 'avaliacao_ruim_ate', 2) and c.motoboy_id is not null and not c.teste then
    if privado.cfg_org_num(pd.organizacao_id, 'pen_pts_avaliacao_ruim', 1) > 0 then
      perform privado.penalizar(pd.organizacao_id, 'motoboy', c.motoboy_id, 'avaliacao', privado.cfg_org_num(pd.organizacao_id, 'pen_pts_avaliacao_ruim', 1),
        'Avaliação ' || p_nota || ' estrela(s)' || coalesce(': ' || nullif(left(trim(p_comentario), 80), ''), ''), c.id);
    end if;
    if privado.cfg_org_bool(pd.organizacao_id, 'avaliacao_avisa_gestor', true) then
      perform privado.avisar_gestores(pd.organizacao_id, jsonb_build_object('tipo', 'avaliacao_ruim', 'corrida_id', c.id::text,
        'titulo', 'Avaliação ' || p_nota || '★ na rota #' || c.numero, 'texto', coalesce(nullif(left(trim(p_comentario), 120), ''), 'Sem comentário.')), 'pedidos');
    end if;
  end if;
  if p_nota = 5 and c.motoboy_id is not null then perform privado.jogo_ganhar(c.motoboy_id, privado.cfg_num('dev_jogo_moedas_avaliacao5', 5)::int, 'avaliacao'); end if;
  return jsonb_build_object('id', v_id);
end;
$$;
revoke execute on function privado.registrar_avaliacao(uuid, text, uuid, int, text) from public, anon, authenticated;

create or replace function public.avaliar_pedido(p_pedido uuid, p_nota int, p_comentario text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.pedidos where id = p_pedido and empresa_id = privado.minha_empresa()) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  return privado.registrar_avaliacao(p_pedido, 'cliente', auth.uid(), p_nota, p_comentario);
end;
$$;

-- nota da empresa (para os cards do cadastro) e do motoboy
create or replace function privado.nota_org(p_org uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('media', round(avg(nota)::numeric, 1), 'total', count(*)) from public.avaliacoes where organizacao_id = p_org;
$$;
create or replace function public.nota_motoboy(p_motoboy uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_org uuid := (select organizacao_id from public.perfis where id = p_motoboy);
begin
  if privado.minha_empresa() is not null and not (privado.cfg_bool('saas_cliente_ve_nota_motoboy', true) and privado.cfg_org_bool(v_org, 'cliente_ve_nota_motoboy', false)) then
    return null;
  end if;
  return (select jsonb_build_object('media', round(avg(nota)::numeric, 1), 'total', count(*)) from public.avaliacoes where motoboy_id = p_motoboy);
end;
$$;

-- ===================================================================== rastreio público
create table if not exists public.rastreios (
  token      text primary key default encode(extensions.gen_random_bytes(12), 'hex'),
  pedido_id  uuid not null references public.pedidos (id) on delete cascade,
  ponto_id   uuid references public.pedido_pontos (id) on delete cascade,
  criado_por uuid references public.perfis (id) on delete set null,
  criado_em  timestamptz not null default now(),
  expira_em  timestamptz
);
alter table public.rastreios enable row level security;
revoke all on public.rastreios from anon, authenticated;

create or replace function public.gerar_rastreio(p_pedido uuid, p_ponto uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare pd public.pedidos%rowtype; v_tok text; v_h numeric;
begin
  select * into pd from public.pedidos where id = p_pedido;
  if not found or not coalesce(pd.empresa_id = privado.minha_empresa() or (public.is_gestor() and public.ve_org(pd.organizacao_id)), false) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if not privado.cfg_bool('saas_rastreio', true) or not privado.pol_bool('rastreio_ligado', true, pd.empresa_id) then raise exception 'rastreio_desligado' using errcode = '42501'; end if;
  v_h := privado.cfg_num('rastreio_validade_h', 24);
  select token into v_tok from public.rastreios where pedido_id = p_pedido and ponto_id is not distinct from p_ponto and (expira_em is null or expira_em > now()) limit 1;
  if v_tok is null then
    insert into public.rastreios (pedido_id, ponto_id, criado_por, expira_em) values (p_pedido, p_ponto, auth.uid(), null) returning token into v_tok;
  end if;
  return jsonb_build_object('token', v_tok, 'url', coalesce(nullif(privado.cfg('dev_site_url', '""'::jsonb) #>> '{}', ''), '') || '/r/' || v_tok,
                            'envio', privado.cfg('rastreio_envio', '"copiar"'::jsonb) #>> '{}');
end;
$$;

-- Para quem recebe a entrega (sem login): situação, previsão, onde o motoboy está e a marca da empresa.
create or replace function public.rastreio_publico(p_token text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r public.rastreios%rowtype; pd public.pedidos%rowtype; o public.organizacoes%rowtype; c record; v_fim timestamptz; v_pontos jsonb; m record;
begin
  select * into r from public.rastreios where token = p_token;
  if not found then return jsonb_build_object('erro', 'link_invalido'); end if;
  select * into pd from public.pedidos where id = r.pedido_id;
  select * into o from public.organizacoes where id = pd.organizacao_id;
  select k.id, k.status, k.motoboy_id, k.concluida_em, k.rota_planejada, k.numero into c
    from public.corridas k join public.paradas pa on pa.corrida_id = k.id
   where pa.pedido_id = pd.id and (r.ponto_id is null or pa.pedido_ponto_id = r.ponto_id) and k.status::text <> 'cancelada'
   order by k.criada_em desc limit 1;
  -- vale até X horas depois da entrega
  v_fim := coalesce(c.concluida_em, pd.concluido_em) + make_interval(hours => privado.cfg_num('rastreio_validade_h', 24)::int);
  if v_fim is not null and v_fim < now() then return jsonb_build_object('erro', 'link_expirado', 'marca', jsonb_build_object('nome', coalesce(o.nome_app, o.nome), 'logo', o.logo_url, 'cor', o.cor)); end if;
  select coalesce(jsonb_agg(jsonb_build_object('tipo', pa.tipo, 'status', pa.status, 'endereco', split_part(pa.endereco, ',', 1), 'lat', pa.lat, 'lng', pa.lng,
           'concluida_em', pa.concluida_em, 'recebedor', case when pa.status::text = 'concluida' then left(pa.recebedor_nome, 1) || '…' end) order by pa.ordem), '[]')
    into v_pontos from public.paradas pa where pa.corrida_id = c.id and (r.ponto_id is null or pa.pedido_ponto_id = r.ponto_id or pa.tipo = 'coleta');
  select lat, lng, posicao_em into m from public.motoboys where id = c.motoboy_id and c.status::text in ('aceita', 'em_andamento');
  return jsonb_build_object(
    'pedido', pd.numero, 'status', coalesce(c.status::text, pd.status::text), 'rota', c.numero,
    'marca', jsonb_build_object('nome', coalesce(o.nome_app, o.nome), 'topo', o.nome_topo, 'logo', o.logo_url, 'cor', o.cor),
    'motoboy', case when privado.pol_bool('rastreio_mostra_motoboy', true, pd.empresa_id) then split_part(public.nome_publico(c.motoboy_id), ' ', 1) end,
    'posicao', case when m.lat is not null then jsonb_build_object('lat', round(m.lat::numeric, 4), 'lng', round(m.lng::numeric, 4), 'em', m.posicao_em) end,
    'pontos', v_pontos, 'rota_planejada', c.rota_planejada,
    'pode_avaliar', privado.cfg_bool('saas_avaliacoes', true) and privado.pol_txt('avaliacao_quem', 'cliente', pd.empresa_id) in ('recebedor', 'ambos')
                    and c.status::text = 'concluida' and not exists (select 1 from public.avaliacoes a where a.pedido_id = pd.id and a.autor = 'recebedor'));
end;
$$;

create or replace function public.avaliar_por_rastreio(p_token text, p_nota int, p_comentario text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.rastreios%rowtype;
begin
  select * into r from public.rastreios where token = p_token;
  if not found then raise exception 'link_invalido' using errcode = '22023'; end if;
  return privado.registrar_avaliacao(r.pedido_id, 'recebedor', null, p_nota, p_comentario);
end;
$$;
grant execute on function public.rastreio_publico(text), public.avaliar_por_rastreio(text, int, text) to anon, authenticated;

-- ===================================================================== jogo: moedas, loja, ranking
create table if not exists public.jogo_perfis (
  motoboy_id uuid primary key references public.perfis (id) on delete cascade,
  moedas     int not null default 0 check (moedas >= 0),
  xp         int not null default 0,
  recorde    int not null default 0,
  partidas   int not null default 0,
  itens      text[] not null default '{}',
  equipado   jsonb not null default '{}'::jsonb,
  atualizado_em timestamptz not null default now()
);
create table if not exists public.jogo_partidas (
  id bigint generated always as identity primary key,
  motoboy_id uuid not null references public.perfis (id) on delete cascade,
  organizacao_id uuid references public.organizacoes (id) on delete cascade,
  pontos int not null, distancia int not null default 0, criado_em timestamptz not null default now()
);
create index if not exists jogo_partidas_rank on public.jogo_partidas (criado_em desc, pontos desc);
-- catálogo da loja (o preço vale do servidor; o Dev muda aqui)
create table if not exists public.jogo_itens (
  chave text primary key, tipo text not null, nome text not null, preco int not null check (preco >= 0), nivel int not null default 1, dados jsonb not null default '{}'::jsonb
);
alter table public.jogo_perfis enable row level security;
alter table public.jogo_partidas enable row level security;
alter table public.jogo_itens enable row level security;
revoke all on public.jogo_perfis, public.jogo_partidas from anon, authenticated;
drop policy if exists jogo_itens_leitura on public.jogo_itens;
create policy jogo_itens_leitura on public.jogo_itens for select to authenticated using (true);
grant select on public.jogo_itens to authenticated;

insert into public.jogo_itens (chave, tipo, nome, preco, nivel, dados) values
  ('moto_classica', 'moto', 'Clássica', 0, 1, '{"cor":"#D4AF37"}'), ('moto_noite', 'moto', 'Noite', 120, 1, '{"cor":"#1F2937"}'),
  ('moto_rubi', 'moto', 'Rubi', 250, 3, '{"cor":"#DC2626"}'), ('moto_oceano', 'moto', 'Oceano', 250, 3, '{"cor":"#0EA5E9"}'),
  ('moto_neon', 'moto', 'Neon', 600, 6, '{"cor":"#22D3EE","brilho":true}'), ('moto_ouro', 'moto', 'Ouro puro', 1500, 10, '{"cor":"#FDE68A","brilho":true}'),
  ('capacete_branco', 'capacete', 'Branco', 0, 1, '{"cor":"#F5F5F5"}'), ('capacete_preto', 'capacete', 'Preto fosco', 80, 1, '{"cor":"#111827"}'),
  ('capacete_raio', 'capacete', 'Raio', 200, 2, '{"cor":"#FACC15","desenho":"raio"}'), ('capacete_chamas', 'capacete', 'Chamas', 350, 4, '{"cor":"#F97316","desenho":"chamas"}'),
  ('capacete_galaxia', 'capacete', 'Galáxia', 900, 8, '{"cor":"#7C3AED","desenho":"estrelas"}'),
  ('rastro_nenhum', 'rastro', 'Sem rastro', 0, 1, '{}'), ('rastro_ouro', 'rastro', 'Faísca dourada', 150, 2, '{"cor":"#D4AF37"}'),
  ('rastro_arco', 'rastro', 'Arco-íris', 700, 7, '{"arco":true}'),
  ('buzina_padrao', 'buzina', 'Bi-bi', 0, 1, '{}'), ('buzina_trem', 'buzina', 'Trem', 120, 2, '{}'),
  ('poder_escudo', 'poder', 'Escudo (1 batida)', 40, 1, '{"consumivel":true}'), ('poder_ima', 'poder', 'Ímã de pacotes', 30, 1, '{"consumivel":true}'),
  ('poder_turbo', 'poder', 'Turbo de moedas', 50, 3, '{"consumivel":true}')
on conflict (chave) do nothing;

create or replace function privado.jogo_level(p_xp int) returns int language sql immutable as $$ select 1 + floor(sqrt(greatest(p_xp, 0) / 100.0))::int; $$;

create or replace function privado.jogo_ganhar(p_motoboy uuid, p_moedas int, p_motivo text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_motoboy is null or coalesce(p_moedas, 0) <= 0 then return; end if;
  insert into public.jogo_perfis (motoboy_id, moedas, xp) values (p_motoboy, p_moedas, p_moedas)
  on conflict (motoboy_id) do update set moedas = public.jogo_perfis.moedas + excluded.moedas, xp = public.jogo_perfis.xp + excluded.xp, atualizado_em = now();
exception when others then null;
end;
$$;

-- moedas pelo trabalho: corrida concluída, cada entrega e cada km (nunca aparece de onde veio)
create or replace function privado.jogo_por_corrida()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status::text = 'concluida' and old.status::text <> 'concluida' and new.motoboy_id is not null and not new.teste then
    perform privado.jogo_ganhar(new.motoboy_id,
      (privado.cfg_num('dev_jogo_moedas_corrida', 10)
       + privado.cfg_num('dev_jogo_moedas_entrega', 3) * (select count(*) from public.paradas p where p.corrida_id = new.id and p.tipo = 'entrega')
       + privado.cfg_num('dev_jogo_moedas_km', 1) * floor(coalesce(new.distancia_real_m, new.distancia_planejada_m, 0) / 1000.0))::int, 'corrida');
  end if;
  return new;
end;
$$;
drop trigger if exists corridas_jogo on public.corridas;
create trigger corridas_jogo after update of status on public.corridas for each row execute function privado.jogo_por_corrida();

create or replace function public.jogo_meu()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare j public.jogo_perfis%rowtype;
begin
  if auth.uid() is null then raise exception 'nao_autenticado' using errcode = '28000'; end if;
  insert into public.jogo_perfis (motoboy_id, itens, equipado) values (auth.uid(), '{moto_classica,capacete_branco,rastro_nenhum,buzina_padrao}',
    '{"moto":"moto_classica","capacete":"capacete_branco","rastro":"rastro_nenhum","buzina":"buzina_padrao"}') on conflict do nothing;
  -- quem ganhou moedas antes de abrir o jogo recebe o kit inicial
  update public.jogo_perfis set itens = '{moto_classica,capacete_branco,rastro_nenhum,buzina_padrao}'::text[] || itens,
         equipado = '{"moto":"moto_classica","capacete":"capacete_branco","rastro":"rastro_nenhum","buzina":"buzina_padrao"}'::jsonb || equipado
   where motoboy_id = auth.uid() and not ('moto_classica' = any (itens));
  select * into j from public.jogo_perfis where motoboy_id = auth.uid();
  return jsonb_build_object('moedas', j.moedas, 'xp', j.xp, 'level', privado.jogo_level(j.xp), 'proximo_xp', power(privado.jogo_level(j.xp), 2) * 100,
    'recorde', j.recorde, 'partidas', j.partidas, 'itens', to_jsonb(j.itens), 'equipado', j.equipado,
    'loja', (select coalesce(jsonb_agg(to_jsonb(i) order by i.tipo, i.preco), '[]') from public.jogo_itens i),
    'vel_max_kmh', privado.cfg_num('dev_jogo_vel_max_kmh', 8), 'ranking', privado.cfg_bool('dev_jogo_ranking', true));
end;
$$;

-- fim de partida: pontos e moedas pegas (limitadas para não dar para trapacear)
create or replace function public.jogo_registrar_partida(p_pontos int, p_moedas int default 0, p_distancia int default 0, p_poderes text[] default '{}')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_m int := least(greatest(coalesce(p_moedas, 0), 0), 200) * privado.cfg_num('dev_jogo_moedas_pacote', 1)::int; v_p text;
begin
  if auth.uid() is null then raise exception 'nao_autenticado' using errcode = '28000'; end if;
  perform public.jogo_meu();
  -- poderes usados saem do inventário
  foreach v_p in array coalesce(p_poderes, '{}') loop
    update public.jogo_perfis set itens = array_remove(itens, v_p) where motoboy_id = auth.uid() and v_p like 'poder_%' and v_p = any (itens);
  end loop;
  update public.jogo_perfis set moedas = moedas + v_m, xp = xp + least(greatest(p_pontos, 0), 5000) / 10 + v_m,
         recorde = greatest(recorde, least(greatest(p_pontos, 0), 100000)), partidas = partidas + 1, atualizado_em = now()
   where motoboy_id = auth.uid();
  insert into public.jogo_partidas (motoboy_id, organizacao_id, pontos, distancia)
  values (auth.uid(), (select organizacao_id from public.perfis where id = auth.uid()), least(greatest(p_pontos, 0), 100000), greatest(coalesce(p_distancia, 0), 0));
  return public.jogo_meu();
end;
$$;

create or replace function public.jogo_comprar(p_item text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare i public.jogo_itens%rowtype; j public.jogo_perfis%rowtype;
begin
  perform public.jogo_meu();
  select * into i from public.jogo_itens where chave = p_item;
  if not found then raise exception 'item_nao_existe' using errcode = '22023'; end if;
  select * into j from public.jogo_perfis where motoboy_id = auth.uid() for update;
  if privado.jogo_level(j.xp) < i.nivel then raise exception 'level_baixo' using errcode = '22023'; end if;
  if i.tipo <> 'poder' and p_item = any (j.itens) then raise exception 'ja_tem' using errcode = '22023'; end if;
  if j.moedas < i.preco then raise exception 'moedas_insuficientes' using errcode = '22023'; end if;
  update public.jogo_perfis set moedas = moedas - i.preco, itens = itens || p_item, atualizado_em = now() where motoboy_id = auth.uid();
  if i.tipo <> 'poder' then perform public.jogo_equipar(p_item); end if;
  return public.jogo_meu();
end;
$$;

create or replace function public.jogo_equipar(p_item text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_tipo text;
begin
  select tipo into v_tipo from public.jogo_itens where chave = p_item;
  if v_tipo is null or v_tipo = 'poder' then raise exception 'item_nao_existe' using errcode = '22023'; end if;
  update public.jogo_perfis set equipado = equipado || jsonb_build_object(v_tipo, p_item) where motoboy_id = auth.uid() and p_item = any (itens);
  if not found then raise exception 'nao_tem' using errcode = '22023'; end if;
  return public.jogo_meu();
end;
$$;

-- ranking: da empresa ou global; do mês ou de sempre (perfil com level e visual; sem empresa no global)
create or replace function public.jogo_ranking(p_escopo text default 'empresa', p_periodo text default 'mes')
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_org uuid := (select organizacao_id from public.perfis where id = auth.uid());
begin
  if not privado.cfg_bool('dev_jogo_ranking', true) then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(x order by (x ->> 'pontos')::int desc) from (
    select jsonb_build_object('id', g.motoboy_id, 'nome', split_part(public.nome_publico(g.motoboy_id), ' ', 1), 'foto', public.foto_publica(g.motoboy_id),
             'pontos', max(g.pontos), 'eu', g.motoboy_id = auth.uid(),
             'level', privado.jogo_level(coalesce(jp.xp, 0)), 'equipado', coalesce(jp.equipado, '{}')) x
      from public.jogo_partidas g left join public.jogo_perfis jp on jp.motoboy_id = g.motoboy_id
     where (p_escopo = 'global' or g.organizacao_id is not distinct from v_org)
       and (p_periodo = 'sempre' or g.criado_em >= date_trunc('month', now()))
     group by g.motoboy_id, jp.xp, jp.equipado
     order by max(g.pontos) desc limit 50) t), '[]'::jsonb);
end;
$$;

-- ===================================================================== auditoria (quem fez o quê)
create table if not exists public.auditoria (
  id bigint generated always as identity primary key,
  organizacao_id uuid references public.organizacoes (id) on delete cascade,
  autor_id uuid references public.perfis (id) on delete set null,
  tabela text not null, acao text not null, alvo text, antes jsonb, depois jsonb,
  criado_em timestamptz not null default now()
);
create index if not exists auditoria_org on public.auditoria (organizacao_id, criado_em desc);
alter table public.auditoria enable row level security;
revoke all on public.auditoria from anon, authenticated;

create or replace function privado.auditar()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_org uuid; v_antes jsonb; v_depois jsonb; v_dif jsonb;
begin
  if auth.uid() is null then return coalesce(new, old); end if;
  if not exists (select 1 from public.perfis p where p.id = auth.uid() and p.papeis && array['gestor', 'supervisor', 'dev']::public.papel_usuario[]) then return coalesce(new, old); end if;
  v_antes := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  v_depois := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  -- em mudança: só o que mudou (sem colunas que mexem sozinhas)
  if tg_op = 'UPDATE' then
    select jsonb_object_agg(k, v_depois -> k) into v_dif from jsonb_object_keys(v_depois) k
     where v_depois -> k is distinct from v_antes -> k and k not in ('atualizado_em', 'ultima_em', 'posicao', 'posicao_em', 'lat', 'lng', 'status_em', 'precisao_m', 'bateria');
    if v_dif is null then return new; end if;
    v_antes := (select jsonb_object_agg(k, v_antes -> k) from jsonb_object_keys(v_dif) k);
    v_depois := v_dif;
  end if;
  begin
    v_org := coalesce(nullif(to_jsonb(coalesce(new, old)) ->> 'organizacao_id', '')::uuid, public.minha_org());
  exception when others then v_org := public.minha_org();
  end;
  if not privado.cfg_org_bool(v_org, 'auditoria_ligada', true) then return coalesce(new, old); end if;
  insert into public.auditoria (organizacao_id, autor_id, tabela, acao, alvo, antes, depois)
  values (v_org, auth.uid(), tg_table_name, lower(tg_op), coalesce(to_jsonb(coalesce(new, old)) ->> 'id', to_jsonb(coalesce(new, old)) ->> 'chave'), v_antes, v_depois);
  return coalesce(new, old);
exception when others then return coalesce(new, old);
end;
$$;
do $$ declare t text; begin
  foreach t in array array['pedidos', 'corridas', 'politicas', 'empresas', 'zonas', 'categorias_produto', 'tipos_pedido', 'penalidades', 'chamados_corrida', 'faixas_horario'] loop
    if to_regclass('public.' || t) is not null then
      execute format('drop trigger if exists zz_auditoria on public.%I', t);
      execute format('create trigger zz_auditoria after insert or update or delete on public.%I for each row execute function privado.auditar()', t);
    end if;
  end loop;
end $$;

create or replace function public.auditoria_lista(p_de timestamptz default null, p_ate timestamptz default null, p_busca text default null, p_limite int default 200)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not (public.is_gestor_pleno() or public.is_dev()) then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'quando', a.criado_em, 'autor', public.nome_publico(a.autor_id), 'autor_id', a.autor_id,
           'tabela', a.tabela, 'acao', a.acao, 'alvo', a.alvo, 'antes', a.antes, 'depois', a.depois) order by a.criado_em desc)
    from (select * from public.auditoria x
           where public.ve_org(x.organizacao_id)
             and (p_de is null or x.criado_em >= p_de) and (p_ate is null or x.criado_em < p_ate)
             and (p_busca is null or x.tabela ilike '%' || p_busca || '%' or x.depois::text ilike '%' || p_busca || '%' or public.nome_publico(x.autor_id) ilike '%' || p_busca || '%')
           order by x.criado_em desc limit least(greatest(coalesce(p_limite, 200), 1), 1000)) a), '[]'::jsonb);
end;
$$;

-- ===================================================================== agendas
do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'cron') and exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'cron' and p.proname = 'schedule') then
    perform cron.schedule('pwex-fechar-sem-noticia', '*/2 * * * *', 'select privado.fechar_sem_noticia()');
  end if;
exception when others then null;
end $$;

-- ===================================================================== permissões
revoke execute on function public.salvar_meu_tema(jsonb), public.liberar_parada(uuid, boolean, text), public.pedir_pular_parada(uuid, text), public.meu_pedido_pular(uuid),
  public.acionar_emergencia(double precision, double precision, real), public.resolver_emergencia(uuid, text), public.emergencias_abertas(),
  public.avaliar_pedido(uuid, int, text), public.nota_motoboy(uuid), public.gerar_rastreio(uuid, uuid),
  public.jogo_meu(), public.jogo_registrar_partida(int, int, int, text[]), public.jogo_comprar(text), public.jogo_equipar(text), public.jogo_ranking(text, text),
  public.auditoria_lista(timestamptz, timestamptz, text, int) from public, anon;
grant execute on function public.salvar_meu_tema(jsonb), public.liberar_parada(uuid, boolean, text), public.pedir_pular_parada(uuid, text), public.meu_pedido_pular(uuid),
  public.acionar_emergencia(double precision, double precision, real), public.resolver_emergencia(uuid, text), public.emergencias_abertas(),
  public.avaliar_pedido(uuid, int, text), public.nota_motoboy(uuid), public.gerar_rastreio(uuid, uuid),
  public.jogo_meu(), public.jogo_registrar_partida(int, int, int, text[]), public.jogo_comprar(text), public.jogo_equipar(text), public.jogo_ranking(text, text),
  public.auditoria_lista(timestamptz, timestamptz, text, int) to authenticated;
revoke execute on function privado.jogo_ganhar(uuid, int, text), privado.nota_org(uuid), privado.auditar(), privado.jogo_por_corrida() from public, anon, authenticated;
