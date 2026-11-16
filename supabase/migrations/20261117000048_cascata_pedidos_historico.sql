-- 0048 · Cascata e pedidos
--  • ajustes dev_/saas_/especial_ (globais, por empresa ou por pessoa) só o Dev grava
--  • permissões especiais (avançar fora do local em teste, diagnóstico) só pelo Dev; sai a regra "gestor + motoboy"
--  • criar rota à mão só se o Dev ligar (dev_criar_rota_manual); o padrão é só pedido
--  • editar pedido com as mesmas opções da criação (criar_pedido com editar_id)
--  • tipos de pedido desligados até o Dev ligar (dev_tipos_pedido_ligado)
--  • painel_do_dia(p_dia): o Hoje de qualquer data
--  • historico_rotas / ficha_rota: tudo da rota num lugar; rotas_resumo: número da rota e dos pedidos de cada percurso
--  • abas do app do motoboy: Seu dia, Rotas, Holerite (Dev e gestor ligam/desligam, também por motoboy)

do $$ begin
  perform set_config('lock_timeout', '60s', true);
  lock table public.politicas, public.tipos_pedido in access exclusive mode;
end $$;

-- ===================================================================== só o Dev grava ajustes do Dev e permissões especiais
create or replace function privado.proteger_ajustes_dev()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or public.is_dev() then return coalesce(new, old); end if;   -- sistema / Dev
  if coalesce(new.chave, old.chave) ~ '^(dev_|saas_|especial_)' then
    raise exception 'so_o_dev' using errcode = '42501';
  end if;
  return coalesce(new, old);
end;
$$;
drop trigger if exists proteger_ajustes_dev on public.politicas;
create trigger proteger_ajustes_dev before insert or update or delete on public.politicas for each row execute function privado.proteger_ajustes_dev();

-- especial_: vale o da pessoa (motoboy) > o da empresa > o global. Sempre definido pelo Dev.
create or replace function privado.especial(p_chave text, p_pessoa uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.is_dev() or coalesce(
    (select (valor #>> '{}')::boolean from public.politicas where escopo = 'motoboy' and alvo = p_pessoa::text and chave = p_chave),
    (select (valor #>> '{}')::boolean from public.politicas where escopo = 'organizacao' and chave = p_chave
        and alvo = (select organizacao_id::text from public.perfis where id = p_pessoa)),
    (select (valor #>> '{}')::boolean from public.configuracoes where chave = p_chave),
    false);
$$;
revoke execute on function privado.especial(text, uuid) from public, anon, authenticated;

insert into public.ajuste_grupos (chave, grupo, area) values
  ('especial_ignora_local', 'teste', 'sistema'), ('especial_diagnostico', 'teste', 'sistema'),
  ('dev_criar_rota_manual', 'pedidos', 'operacao'), ('dev_tipos_pedido_ligado', 'pedidos', 'operacao'),
  ('cliente_edita_pedido', 'cli_pode', 'clientes'),
  ('motoboy_aba_dia', 'app_motoboy', 'motoboys'), ('motoboy_aba_rotas', 'app_motoboy', 'motoboys'), ('motoboy_aba_holerite', 'app_motoboy', 'motoboys'),
  ('mapa_rota_planejada', 'mapa', 'mapa')
on conflict (chave) do update set grupo = excluded.grupo, area = excluded.area;

-- ===================================================================== tipos de pedido: desligados até o Dev ligar
create or replace function public.tipos_pedido_ligados()
returns boolean language sql stable security definer set search_path = '' as $$ select privado.cfg_bool('dev_tipos_pedido_ligado', false) $$;
grant execute on function public.tipos_pedido_ligados() to authenticated;
drop policy if exists tipos_pedido_leitura on public.tipos_pedido;
create policy tipos_pedido_leitura on public.tipos_pedido for select to authenticated
  using ((ativo and (select public.tipos_pedido_ligados())) or (select public.is_dev()));
drop policy if exists tipos_pedido_gestor on public.tipos_pedido;
create policy tipos_pedido_gestor on public.tipos_pedido for all to authenticated
  using ((select public.is_dev()) or ((select public.is_gestor()) and (select public.tipos_pedido_ligados())))
  with check ((select public.is_dev()) or ((select public.is_gestor()) and (select public.tipos_pedido_ligados())));

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
  -- respostas dos campos próprios ("resp_<campo>" e/ou "respostas": {...}); fotos chegam como caminho do arquivo
  if v_dados ? 'respostas' or exists (select 1 from jsonb_object_keys(v_dados) k where k like 'resp\_%') then
    update public.paradas set respostas = coalesce(respostas, '{}') || privado.limpar_extras(c.organizacao_id, 'ponto', c.tipo_pedido,
      coalesce(v_dados -> 'respostas', '{}') || coalesce((select jsonb_object_agg(substr(k, 6), v) from jsonb_each(v_dados) e(k, v) where k like 'resp\_%'), '{}'),
      'motoboy', false)
     where id = p_parada;
  end if;
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
                  and c.teste and privado.especial('especial_ignora_local', auth.uid()))
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
       set status = 'chegou', chegou_em = coalesce(privado.quando_offline(v_dados), now()), feita_offline = feita_offline or coalesce(v_dados ->> 'offline' = 'true', false),
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
         feita_offline = feita_offline or coalesce(v_dados ->> 'offline' = 'true', false),
         distancia_chegada_m = coalesce(distancia_chegada_m, round(v_dist)),
         local_ignorado = local_ignorado or v_ignorar,
         recebedor_nome = nullif(trim(v_dados ->> 'recebedor_nome'), ''),
         foto_path = nullif(v_dados ->> 'foto_path', ''),
         assinatura_path = nullif(v_dados ->> 'assinatura_path', '')
   where id = p.id;
  -- pedido de pular esta parada que ficou aberto: não precisa mais
  update public.chamados_corrida set status = 'retirado', respondido_em = now() where corrida_id = c.id and tipo = 'pular' and parada_id = p.id and status = 'pendente';
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
    'modulos', coalesce((select jsonb_object_agg(md.chave, privado.modulo_ligado(md.chave, p.id)) from public.modulos md), '{}'::jsonb),
    'rotulos', privado.rotulos_de(coalesce(p.organizacao_id, privado.org_contexto(p.empresa_id, null))),
    'campos', (select coalesce(jsonb_agg(jsonb_build_object('chave', k.chave, 'rotulo', k.rotulo, 'dica', k.dica, 'tipo', k.tipo, 'opcoes', k.opcoes,
                 'obrigatorio', k.obrigatorio, 'quem_preenche', k.quem_preenche, 'entidade', k.entidade, 'ponto_tipo', k.ponto_tipo,
                 'tipos_pedido', k.tipos_pedido, 'etapa', k.etapa, 'visivel_motoboy', k.visivel_motoboy, 'visivel_cliente', k.visivel_cliente) order by k.entidade, k.ordem), '[]')
                 from public.campos_personalizados k where k.ativo and (k.organizacao_id is null or k.organizacao_id = coalesce(p.organizacao_id, privado.org_contexto(p.empresa_id, null)))),
    'cargo', (select jsonb_build_object('id', k.id, 'nome', k.nome, 'icone', k.icone) from public.cargos k where k.id = p.cargo_id),
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
                       'dev_site_url', 'offline_finalizar_ligado', 'emergencia_ligada', 'motoboy_pede_pular', 'dev_jogo_vel_max_kmh', 'dev_jogo_ranking',
                       'chat_editar_min', 'chat_audio_ligado', 'dev_chat_audio_ligado', 'dev_chat_audio_max_s', 'chat_reacoes')
    ), '{}'::jsonb)
    -- o que pode mudar por motoboy (regra dele > geral)
    || jsonb_build_object(
      'intervalo_corrida_s', privado.pol_num('intervalo_corrida_s', 6, null, p.id, null),
      'intervalo_economia_s', privado.pol_num('intervalo_economia_s', 20, null, p.id, null),
      'disponivel_envio_min', privado.pol_num('disponivel_envio_min', 3, null, p.id, null),
      'disponivel_distancia_m', privado.pol_num('disponivel_distancia_m', 300, null, p.id, null),
      'disponivel_fator', privado.pol_num('disponivel_fator', 3, null, p.id, null),
      'motoboy_rotas_simultaneas', privado.pol_num('motoboy_rotas_simultaneas', 1, null, p.id, null),
      'motoboy_rotas_distancia_aviso_km', privado.pol_num('motoboy_rotas_distancia_aviso_km', 5, null, p.id, null),
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
      'motoboy_pode_finalizar', privado.pol_bool('motoboy_pode_finalizar', false, null, p.id, null),
      'especial_ignora_local', privado.especial('especial_ignora_local', p.id),
      'especial_diagnostico', privado.especial('especial_diagnostico', p.id),
      'motoboy_aba_dia', privado.pol_bool('motoboy_aba_dia', true, null, p.id, null),
      'motoboy_aba_rotas', privado.pol_bool('motoboy_aba_rotas', true, null, p.id, null),
      'motoboy_aba_holerite', privado.pol_bool('motoboy_aba_holerite', true, null, p.id, null),
      'dev_tipos_pedido_ligado', privado.cfg_bool('dev_tipos_pedido_ligado', false),
      'dev_criar_rota_manual', public.is_dev() or privado.cfg_org_bool(coalesce(p.organizacao_id, p.org_em_foco), 'dev_criar_rota_manual', false),
      'mapa_rota_planejada', privado.cfg_org_bool(coalesce(p.organizacao_id, p.org_em_foco), 'mapa_rota_planejada', true))
  )
  from public.perfis p
  left join public.motoboys m on m.id = p.id
  where p.id = auth.uid();
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
                       from public.tipos_pedido t where t.ativo and privado.cfg_bool('dev_tipos_pedido_ligado', false) and (t.organizacao_id is null or t.organizacao_id = privado.org_contexto(v_cli))),
    'edita_pedido', privado.pol_bool('cliente_edita_pedido', true, v_cli),
    'categorias', (select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'nome', k.nome, 'descricao', k.descricao, 'perigoso', k.perigoso,
                                                               'classe_risco', k.classe_risco, 'fragil', k.fragil, 'icone', k.icone,
                                                               'campo_descricao', k.campo_descricao, 'campo_peso', k.campo_peso, 'campo_medidas', k.campo_medidas,
                                                               'campo_valor', k.campo_valor, 'campo_quantidade', k.campo_quantidade) order by k.ordem), '[]')
                     from public.categorias_produto k where k.ativa and (k.organizacao_id is null or k.organizacao_id = privado.org_contexto(v_cli))),
    'icone', e.icone, 'teste', privado.cliente_teste(), 've_preco_na_hora', privado.cliente_ve_preco(v_cli),
    'pode_modelos', privado.pol_bool('cliente_pode_modelos', true, v_cli), 'pode_cancelar', privado.pol_bool('cliente_pode_cancelar', true, v_cli),
    'troca_senha', privado.pol_bool('cliente_troca_senha', true, v_cli),
    'pode_avaliar', privado.cfg_bool('saas_avaliacoes', true) and privado.pol_bool('avaliacao_ligada', true, v_cli) and privado.pol_txt('avaliacao_quem', 'cliente', v_cli) in ('cliente', 'ambos'),
    'pode_rastreio', privado.cfg_bool('saas_rastreio', true) and privado.pol_bool('rastreio_ligado', true, v_cli),
    've_nota_motoboy', privado.cfg_bool('saas_cliente_ve_nota_motoboy', true) and privado.pol_bool('cliente_ve_nota_motoboy', false, v_cli),
    'confirmacoes', jsonb_build_object('foto', privado.pol_bool('cliente_confirma_foto', true, v_cli), 'nome', privado.pol_bool('cliente_confirma_nome', true, v_cli),
                                       'assinatura', privado.pol_bool('cliente_confirma_assinatura', true, v_cli), 'codigo', privado.pol_bool('cliente_confirma_codigo', true, v_cli)),
    'padrao_confirmacoes', jsonb_build_object('foto', privado.cfg_bool('padrao_exige_foto', false), 'nome', privado.cfg_bool('padrao_exige_nome', true),
                                              'assinatura', privado.cfg_bool('padrao_exige_assinatura', false), 'codigo', privado.cfg_bool('padrao_exige_codigo', false)),
    'pode_janela', privado.pol_bool('cliente_pode_janela', true, v_cli), 'pode_objetos', privado.pol_bool('cliente_pode_objetos', true, v_cli),
    'modelo_horario', privado.pol_bool('cliente_modelo_horario', true, v_cli),
    'pode_agendar', privado.pol_bool('cliente_pode_agendar', true, v_cli), 'pode_urgente', privado.pol_bool('cliente_pode_urgente', true, v_cli),
    'escolhe_veiculo', privado.pol_bool('cliente_escolhe_veiculo', false, v_cli), 'veiculos_aceitos', privado.pol('veiculos_aceitos', v_cli, null, null),
    'max_entregas', privado.pol_num('cliente_max_entregas', 0, v_cli), 'max_coletas', privado.pol_num('cliente_max_coletas', 0, v_cli),
    'agendar_max_dias', privado.pol_num('cliente_agendar_max_dias', 60, v_cli), 'pode_ida_volta', privado.pol_bool('cliente_pode_ida_volta', true, v_cli),
    'coleta_fixa', privado.pol_bool('cliente_coleta_fixa', false, v_cli), 'pode_observacoes', privado.pol_bool('cliente_pode_observacoes', true, v_cli),
    've_faturas', privado.pol_bool('cliente_ve_faturas', true, v_cli), 'pode_chat', privado.pol_bool('cliente_pode_chat', true, v_cli),
    've_rota', coalesce(privado.pol('cliente_ve_rota', v_cli), '["feito", "motoboy"]'::jsonb),
    'pedido_de', privado.pol_txt('cliente_pedido_de', '', v_cli), 'pedido_ate', privado.pol_txt('cliente_pedido_ate', '', v_cli),
    'modo_distancia', privado.pol_txt('preco_distancia_modo', 'soma_entregas', v_cli), 'categoria_obrigatoria', privado.cfg_bool('item_categoria_obrigatoria', false),
    'em_aberto', (select coalesce(sum(valor), 0) from public.pedidos where empresa_id = v_cli and teste = privado.cliente_teste() and cobranca = 'credito' and fatura_id is null and status = 'concluido'));
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
  -- planejada: tem horário para começar
  v_quando  timestamptz := nullif(dados ->> 'agendada_para', '')::timestamptz;
  v_serie   uuid := nullif(dados ->> 'serie_id', '')::uuid;
  v_status  text := 'aguardando_motoboy';
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  -- o padrão é só pedido (vira rota pelo sistema); rota à mão só se o Dev ligar, para todas ou para a empresa
  if not public.is_dev() and not privado.cfg_org_bool(public.minha_org(), 'dev_criar_rota_manual', false)
     and coalesce(current_setting('pwex.serie', true), '') = '' then
    raise exception 'criar_rota_desligado' using errcode = '42501';
  end if;
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
    urgente, repasse_manual, dev_manual, empresa_id, cliente_nome, aplicar_acrescimo, criada_por, modo_despacho, motoboy_designado_id, teste,
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
    nullif(dados ->> 'repasse_pct', '')::numeric,
    nullif(dados ->> 'dev_pct', '')::numeric,
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
create or replace function public.criar_serie(dados jsonb, p_datas timestamptz[])
returns uuid[] language plpgsql security definer set search_path = '' as $$
declare
  v_serie uuid := gen_random_uuid();
  v_ids   uuid[] := '{}';
  d       timestamptz;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  -- o padrão é só pedido (vira rota pelo sistema); rota à mão só se o Dev ligar, para todas ou para a empresa
  if not public.is_dev() and not privado.cfg_org_bool(public.minha_org(), 'dev_criar_rota_manual', false)
     and coalesce(current_setting('pwex.serie', true), '') = '' then
    raise exception 'criar_rota_desligado' using errcode = '42501';
  end if;
  if p_datas is null or cardinality(p_datas) = 0 then raise exception 'sem_datas' using errcode = '22023'; end if;
  if cardinality(p_datas) > 60 then raise exception 'datas_demais' using errcode = '22023'; end if;
  foreach d in array (select array_agg(x order by x) from unnest(p_datas) x) loop
    perform set_config('pwex.serie', '1', true);
    v_ids := v_ids || public.criar_corrida(dados || jsonb_build_object('agendada_para', d, 'serie_id', v_serie));
  end loop;
  return v_ids;
end;
$$;

-- Pode editar? Antes de qualquer etapa feita e sem rota em andamento (igual a "voltar para revisão").
create or replace function privado.pedido_editavel(p_pedido uuid, p_gestor boolean)
returns void language plpgsql stable security definer set search_path = '' as $$
declare p public.pedidos%rowtype;
begin
  select * into p from public.pedidos where id = p_pedido;
  if p.id is null then raise exception 'pedido_nao_encontrado' using errcode = '22023'; end if;
  if p_gestor then
    if not public.ve_pedido(p.id) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  else
    if p.empresa_id is distinct from privado.minha_empresa() then raise exception 'sem_permissao' using errcode = '42501'; end if;
    if not privado.pol_bool('cliente_edita_pedido', true, p.empresa_id) then raise exception 'acao_bloqueada' using errcode = '42501'; end if;
    if p.status <> 'recebido' then raise exception 'pedido_ja_aprovado' using errcode = '22023'; end if;
  end if;
  if p.status in ('concluido', 'cancelado', 'recusado') then raise exception 'pedido_finalizado' using errcode = '22023'; end if;
  if p.fatura_id is not null and exists (select 1 from public.faturas f where f.id = p.fatura_id and f.status <> 'rascunho') then
    raise exception 'pedido_ja_faturado' using errcode = '22023';
  end if;
  if exists (select 1 from public.pedido_pontos x where x.pedido_id = p.id and x.status not in ('pendente', 'em_rota'))
     or exists (select 1 from public.paradas x where x.pedido_id = p.id and x.status::text in ('chegou', 'concluida'))
     or exists (select 1 from public.paradas x join public.corridas c on c.id = x.corrida_id where x.pedido_id = p.id and c.status::text = 'em_andamento') then
    raise exception 'pedido_em_andamento' using errcode = '22023';
  end if;
end;
$$;
revoke execute on function privado.pedido_editavel(uuid, boolean) from public, anon, authenticated;

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
  v_editar  uuid := nullif(dados ->> 'editar_id', '')::uuid;
  v_antes   public.pedidos%rowtype;
begin
  if v_gestor then
    v_cli := nullif(dados ->> 'empresa_id', '')::uuid;
    v_teste := coalesce((dados ->> 'teste')::boolean, (select modo_teste from public.perfis where id = auth.uid()), false);
  else
    v_cli := privado.minha_empresa();
    if v_cli is null then raise exception 'apenas_gestor_ou_cliente' using errcode = '42501'; end if;
    v_teste := privado.cliente_teste();
    if exists (select 1 from public.empresas where id = v_cli and bloqueado_ate > now()) then
      raise exception 'cliente_bloqueado' using errcode = '42501', detail = (select bloqueado_motivo from public.empresas where id = v_cli);
    end if;
  end if;
  if v_gestor then v_regras := privado.limpar_regras(dados -> 'regras'); end if;
  if v_cli is not null and v_gestor and (select modo_teste from public.empresas where id = v_cli) then v_teste := true; end if;
  if v_cli is not null then select * into e from public.empresas where id = v_cli; end if;
  if v_gestor and v_cli is not null and (e.id is null or not public.ve_org(e.organizacao_id)) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if not exists (select 1 from public.tipos_pedido where chave = v_tp and (ativo or v_gestor)
                 and (organizacao_id is null or organizacao_id = privado.org_contexto(v_cli))) then raise exception 'tipo_pedido_invalido' using errcode = '22023'; end if;

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
       and not ((now() at time zone (select privado.fuso()))::time between privado.pol_txt('cliente_pedido_de', '', v_cli, null, v_tp)::time
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
    select * into v_cat from public.categorias_produto where id = (i ->> 'categoria_id')::uuid
       and (organizacao_id is null or organizacao_id = privado.org_contexto(v_cli));
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

  if v_editar is not null then
    -- editar: valida, tira das rotas que ainda não saíram, troca pontos e itens e recalcula (mesmas regras da criação)
    if v_gestor then perform privado.exigir_acao('editar_pedido'); end if;
    perform privado.pedido_editavel(v_editar, v_gestor);
    select * into v_antes from public.pedidos where id = v_editar;
    v_teste := v_antes.teste;
    perform privado.tirar_pedido_das_rotas(v_editar, true);
    delete from public.pedido_itens where pedido_id = v_editar;
    delete from public.pedido_pontos where pedido_id = v_editar;
    update public.pedidos set empresa_id = case when v_gestor then v_cli else empresa_id end,
           cliente_nome = case when v_gestor and v_cli is null then nullif(trim(dados ->> 'cliente_nome'), '') else cliente_nome end,
           tipo = v_tipo, tipo_pedido = v_tp, quando = v_quando, urgente = coalesce((dados ->> 'urgente')::boolean, false),
           observacoes = nullif(left(dados ->> 'observacoes', 1000), ''), distancia_estimada_m = (v_orc ->> 'distancia_m')::int,
           orcamento = v_orc, valor_calculado = (v_orc ->> 'total')::numeric,
           valor = case when v_antes.pagamento_status = 'pago' then v_antes.valor else (v_orc ->> 'total')::numeric end,
           valor_dev = round(case when v_antes.pagamento_status = 'pago' then v_antes.valor else (v_orc ->> 'total')::numeric end * dev_pct / 100, 2),
           regras = case when v_gestor then v_regras else regras end,
           status = case when v_gestor then 'aprovado' else 'recebido' end,
           aprovado_em = case when v_gestor then now() else null end,
           revisado_por = case when v_gestor then auth.uid() end, revisado_em = case when v_gestor then now() end
     where id = v_editar returning id into v_id;
    v_status := case when v_gestor then 'aprovado' else 'recebido' end;
  else
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
  end if;
  -- campos próprios do pedido e veículo pedido
  update public.pedidos set
    extras = privado.limpar_extras(privado.org_contexto(v_cli, null), 'pedido', v_tp, dados -> 'extras', case when v_gestor then 'gestor' else 'cliente' end),
    veiculo = case when nullif(dados ->> 'veiculo', '') in ('moto', 'carro', 'bicicleta', 'van', 'outro')
                    and (v_gestor or privado.pol_bool('cliente_escolhe_veiculo', false, v_cli, null, v_tp)) then dados ->> 'veiculo' end
   where id = v_id;

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
    if p ? 'extras' then
      update public.pedido_pontos set extras = privado.limpar_extras(privado.org_contexto(v_cli, null), 'ponto', v_tp, p -> 'extras',
        case when v_gestor then 'gestor' else 'cliente' end, false) where id = v_pid;
    end if;
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
  perform privado.evento_pedido(v_id, case when v_editar is not null then 'editado' else 'criado' end, jsonb_build_object('origem', case when v_gestor then 'gestor' else 'cliente' end, 'total', v_orc -> 'total'));
  if v_status = 'aprovado' then perform privado.roteirizar(v_teste); end if;
  return v_id;
end;
$$;

-- Tudo do pedido para abrir no editor (o mesmo formato que criar_pedido recebe)
create or replace function public.pedido_para_editar(p_pedido uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare p public.pedidos%rowtype;
begin
  perform privado.pedido_editavel(p_pedido, public.is_gestor());
  select * into p from public.pedidos where id = p_pedido;
  return jsonb_build_object(
    'editar_id', p.id, 'numero', p.numero, 'empresa_id', p.empresa_id, 'cliente_nome', p.cliente_nome, 'quando', p.quando, 'urgente', p.urgente,
    'tipo_pedido', p.tipo_pedido, 'observacoes', p.observacoes, 'extras', p.extras, 'veiculo', p.veiculo, 'regras', p.regras, 'teste', p.teste,
    'pontos', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'tipo', x.tipo, 'endereco', x.endereco, 'lat', x.lat, 'lng', x.lng,
                 'contato_nome', x.contato_nome, 'contato_telefone', x.contato_telefone, 'instrucoes', x.instrucoes, 'referencias', x.referencias,
                 'exige_foto', x.exige_foto, 'exige_assinatura', x.exige_assinatura, 'exige_nome', x.exige_nome, 'exige_codigo', x.exige_codigo,
                 'janela_de', to_char(x.janela_de, 'HH24:MI'), 'janela_ate', to_char(x.janela_ate, 'HH24:MI'), 'extras', x.extras) order by x.ordem), '[]')
               from public.pedido_pontos x where x.pedido_id = p.id),
    'itens', (select coalesce(jsonb_agg(jsonb_build_object('descricao', i.descricao, 'categoria_id', i.categoria_id, 'quantidade', i.quantidade,
                 'peso_kg', i.peso_kg, 'comprimento_cm', i.comprimento_cm, 'largura_cm', i.largura_cm, 'altura_cm', i.altura_cm,
                 'valor_declarado', i.valor_declarado, 'observacoes', i.observacoes,
                 'coleta', (select x.ordem from public.pedido_pontos x where x.id = i.coleta_id),
                 'entrega', (select x.ordem from public.pedido_pontos x where x.id = i.entrega_id))), '[]')
               from public.pedido_itens i where i.pedido_id = p.id));
end;
$$;
grant execute on function public.pedido_para_editar(uuid) to authenticated;


create or replace function public.painel_do_dia(p_dia date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_hoje timestamptz := (coalesce(p_dia, (now() at time zone (select privado.fuso()))::date)::timestamp) at time zone (select privado.fuso());
  v_fim timestamptz := v_hoje + interval '1 day';
  v_teste boolean := coalesce((select p.modo_teste from public.perfis p where p.id = auth.uid()), false);
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  return jsonb_build_object(
    'pedidos_hoje', (select count(*) from public.pedidos p where public.ve_org(p.organizacao_id) and p.criado_em >= v_hoje and p.criado_em < v_fim),
    'para_revisar', (select count(*) from public.pedidos p where public.ve_org(p.organizacao_id) and p.status::text = 'recebido'),
    'rotas_ativas', (select count(*) from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text in ('aceita', 'em_andamento')),
    'rotas_esperando', (select count(*) from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text in ('aguardando_motoboy', 'sem_motoboy', 'montada')),
    'sem_motoboy', (select count(*) from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'sem_motoboy'),
    'concluidas_hoje', (select count(*) from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'concluida' and c.concluida_em >= v_hoje and c.concluida_em < v_fim),
    'faturamento_hoje', (select coalesce(sum(c.valor), 0) from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'concluida' and c.concluida_em >= v_hoje and c.concluida_em < v_fim),
    'gestao_hoje', (select coalesce(sum(c.valor_gestao), 0) from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'concluida' and c.concluida_em >= v_hoje and c.concluida_em < v_fim),
    'km_hoje', (select round(coalesce(sum(coalesce(c.distancia_real_m, c.distancia_planejada_m)), 0) / 1000.0, 1) from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'concluida' and c.concluida_em >= v_hoje and c.concluida_em < v_fim),
    'motoboys_online', (select count(*) from public.motoboys m join public.perfis p on p.id = m.id where public.ve_org(p.organizacao_id) and m.status::text <> 'offline' and p.modo_teste = v_teste),
    'motoboys_em_rota', (select count(*) from public.motoboys m join public.perfis p on p.id = m.id where public.ve_org(p.organizacao_id) and m.status::text = 'em_corrida' and p.modo_teste = v_teste),
    'emergencias', (select count(*) from public.emergencias e where public.ve_org(e.organizacao_id) and e.resolvida_em is null),
    'chamados', (select count(*) from public.chamados_corrida h where public.ve_org(h.organizacao_id) and h.status = 'pendente'),
    'aguardando_confirmacao', (select count(*) from public.corridas c where public.ve_org(c.organizacao_id) and c.aguardando_confirmacao),
    'nota_media_30d', (select round(avg(a.nota)::numeric, 1) from public.avaliacoes a where public.ve_org(a.organizacao_id) and a.criado_em > now() - interval '30 days'),
    'notas_ruins_hoje', (select count(*) from public.avaliacoes a where public.ve_org(a.organizacao_id) and a.criado_em >= v_hoje and a.criado_em < v_fim and a.nota <= 2),
    'por_hora', (select coalesce(jsonb_agg(jsonb_build_object('hora', h, 'rotas', n) order by h), '[]') from (
                   select extract(hour from c.concluida_em at time zone (select privado.fuso()))::int h, count(*) n from public.corridas c
                    where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'concluida' and c.concluida_em >= v_hoje and c.concluida_em < v_fim group by 1) x),
    'canceladas_hoje', (select count(*) from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'cancelada' and c.cancelada_em >= v_hoje and c.cancelada_em < v_fim),
    'entregas_hoje', (select count(*) from public.paradas x join public.corridas c on c.id = x.corrida_id where public.ve_org(c.organizacao_id) and c.teste = v_teste
                       and x.tipo::text = 'entrega' and x.status::text = 'concluida' and x.concluida_em >= v_hoje and x.concluida_em < v_fim),
    'tempo_medio_min', (select round(avg(extract(epoch from (c.concluida_em - coalesce(c.aceita_em, c.iniciada_em))) / 60.0))::int from public.corridas c
                         where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'concluida' and c.concluida_em >= v_hoje and c.concluida_em < v_fim and coalesce(c.aceita_em, c.iniciada_em) is not null),
    'pagar_motoboys_hoje', (select coalesce(sum(c.valor_motoboy), 0) from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'concluida' and c.concluida_em >= v_hoje and c.concluida_em < v_fim),
    'ontem_concluidas', (select count(*) from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'concluida'
                          and c.concluida_em >= v_hoje - interval '1 day' and c.concluida_em < least(now(), v_fim) - interval '1 day'),
    'hora_agora', case when now() < v_fim then extract(hour from now() at time zone (select privado.fuso()))::int else 23 end,
    'dia', to_char(v_hoje at time zone (select privado.fuso()), 'YYYY-MM-DD'), 'hoje', now() >= v_hoje and now() < v_fim,
    'em_andamento', (select coalesce(jsonb_agg(x order by x->>'desde'), '[]') from (
                   select jsonb_build_object('id', c.id, 'numero', c.numero, 'motoboy', split_part(public.nome_publico(c.motoboy_id), ' ', 1), 'status', c.status::text,
                     'feitas', (select count(*) from public.paradas p where p.corrida_id = c.id and p.status::text = 'concluida'),
                     'total', (select count(*) from public.paradas p where p.corrida_id = c.id), 'desde', coalesce(c.aceita_em, c.criada_em)) x
                     from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text in ('aceita', 'em_andamento')
                     order by coalesce(c.aceita_em, c.criada_em) limit 8) y),
    'top_motoboys', (select coalesce(jsonb_agg(jsonb_build_object('nome', split_part(public.nome_publico(x.motoboy_id), ' ', 1), 'rotas', x.n) order by x.n desc), '[]') from (
                   select c.motoboy_id, count(*) n from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'concluida' and c.concluida_em >= v_hoje and c.concluida_em < v_fim and c.motoboy_id is not null
                    group by 1 order by 2 desc limit 5) x));
end;
$$;
grant execute on function public.painel_do_dia(date) to authenticated;


-- Lista do histórico: filtros por período, motoboy, cliente, status e busca (número da rota/pedido, endereço, recebedor)
create or replace function public.historico_rotas(p jsonb default '{}')
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_de timestamptz; v_ate timestamptz; v_teste boolean; v_busca text := nullif(trim(p ->> 'busca'), '');
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  v_de := ((coalesce(nullif(p ->> 'de', '')::date, (now() at time zone (select privado.fuso()))::date - 30))::timestamp) at time zone (select privado.fuso());
  v_ate := ((coalesce(nullif(p ->> 'ate', '')::date, (now() at time zone (select privado.fuso()))::date) + 1)::timestamp) at time zone (select privado.fuso());
  v_teste := coalesce((p ->> 'teste')::boolean, (select modo_teste from public.perfis where id = auth.uid()), false);
  return (select coalesce(jsonb_agg(x order by x ->> 'quando' desc), '[]') from (
    select jsonb_build_object(
      'id', c.id, 'numero', c.numero, 'status', c.status, 'teste', c.teste, 'tipo_pedido', c.tipo_pedido,
      'quando', coalesce(c.concluida_em, c.cancelada_em, c.agendada_para, c.criada_em),
      'criada_em', c.criada_em, 'concluida_em', c.concluida_em, 'cancelada_em', c.cancelada_em,
      'motoboy_id', c.motoboy_id, 'motoboy', public.nome_publico(c.motoboy_id),
      'cliente', coalesce((select string_agg(distinct coalesce(em.nome, pd.cliente_nome), ', ') from public.paradas x join public.pedidos pd on pd.id = x.pedido_id
                            left join public.empresas em on em.id = pd.empresa_id where x.corrida_id = c.id), (select e.nome from public.empresas e where e.id = c.empresa_id), c.cliente_nome),
      'pedidos', (select coalesce(jsonb_agg(distinct pd.numero), '[]') from public.paradas x join public.pedidos pd on pd.id = x.pedido_id where x.corrida_id = c.id),
      'entregas', (select count(*) from public.paradas x where x.corrida_id = c.id and x.tipo = 'entrega'),
      'feitas', (select count(*) from public.paradas x where x.corrida_id = c.id and x.status::text = 'concluida'),
      'km', round(coalesce(c.distancia_real_m, c.distancia_planejada_m, 0) / 1000.0, 1),
      'valor', c.valor, 'valor_motoboy', c.valor_motoboy,
      'minutos', case when c.concluida_em is not null and coalesce(c.aceita_em, c.iniciada_em) is not null
                      then round(extract(epoch from c.concluida_em - coalesce(c.aceita_em, c.iniciada_em)) / 60) end,
      'problemas', (select count(*) from public.chamados_corrida h where h.corrida_id = c.id)
                 + (select count(*) from public.paradas x where x.corrida_id = c.id and (x.local_ignorado or x.feita_offline)),
      'nota', (select round(avg(a.nota)::numeric, 1) from public.avaliacoes a where a.corrida_id = c.id)) x
    from public.corridas c
   where public.ve_org(c.organizacao_id) and c.teste = v_teste
     and coalesce(c.concluida_em, c.cancelada_em, c.agendada_para, c.criada_em) >= v_de
     and coalesce(c.concluida_em, c.cancelada_em, c.agendada_para, c.criada_em) < v_ate
     and (nullif(p ->> 'motoboy', '') is null or c.motoboy_id = (p ->> 'motoboy')::uuid)
     and (nullif(p ->> 'status', '') is null or c.status::text = any (string_to_array(p ->> 'status', ',')))
     and (nullif(p ->> 'cliente', '') is null or c.empresa_id = (p ->> 'cliente')::uuid
          or exists (select 1 from public.paradas x join public.pedidos pd on pd.id = x.pedido_id where x.corrida_id = c.id and pd.empresa_id = (p ->> 'cliente')::uuid))
     and (v_busca is null or c.numero::text = ltrim(v_busca, '#T')
          or exists (select 1 from public.paradas x left join public.pedidos pd on pd.id = x.pedido_id where x.corrida_id = c.id
                      and (pd.numero::text = ltrim(v_busca, '#P') or x.endereco ilike '%' || v_busca || '%' or x.recebedor_nome ilike '%' || v_busca || '%')))
   order by coalesce(c.concluida_em, c.cancelada_em, c.agendada_para, c.criada_em) desc
   limit least(coalesce((p ->> 'limite')::int, 200), 500)) y);
end;
$$;
grant execute on function public.historico_rotas(jsonb) to authenticated;

-- Ficha completa da rota: paradas com comprovantes e respostas, pedidos com itens, linha do tempo, pedidos do motoboy, notas e pagamento
create or replace function public.ficha_rota(p_corrida uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare c public.corridas%rowtype;
begin
  if not public.is_gestor() or not public.ve_corrida(p_corrida) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  select * into c from public.corridas where id = p_corrida;
  return jsonb_build_object(
    'rota', to_jsonb(c) - 'rota_planejada' - 'trajeto' || jsonb_build_object('motoboy', public.nome_publico(c.motoboy_id),
             'cliente', coalesce((select e.nome from public.empresas e where e.id = c.empresa_id), c.cliente_nome)),
    'paradas', (select coalesce(jsonb_agg(to_jsonb(x) || jsonb_build_object('pedido_numero', pd.numero, 'cliente', coalesce(em.nome, pd.cliente_nome),
                   'itens', (select coalesce(jsonb_agg(jsonb_build_object('descricao', i.descricao, 'quantidade', i.quantidade, 'categoria', k.nome, 'icone', k.icone)), '[]')
                              from public.pedido_itens i left join public.categorias_produto k on k.id = i.categoria_id
                             where i.pedido_id = x.pedido_id and (i.entrega_id = x.pedido_ponto_id or i.coleta_id = x.pedido_ponto_id)))
                 order by x.ordem), '[]')
                 from public.paradas x left join public.pedidos pd on pd.id = x.pedido_id left join public.empresas em on em.id = pd.empresa_id
                where x.corrida_id = c.id),
    'pedidos', (select coalesce(jsonb_agg(jsonb_build_object('id', pd.id, 'numero', pd.numero, 'status', pd.status, 'cliente', coalesce(em.nome, pd.cliente_nome),
                   'valor', pd.valor, 'pagamento', pd.pagamento_status, 'criado_em', pd.criado_em, 'observacoes', pd.observacoes, 'extras', pd.extras,
                   'tipo_pedido', pd.tipo_pedido, 'urgente', pd.urgente, 'quando', pd.quando,
                   'outras_rotas', (select coalesce(jsonb_agg(distinct jsonb_build_object('id', k.id, 'numero', k.numero, 'status', k.status)), '[]')
                                      from public.paradas y join public.corridas k on k.id = y.corrida_id where y.pedido_id = pd.id and k.id <> c.id))), '[]')
                 from public.pedidos pd left join public.empresas em on em.id = pd.empresa_id
                where pd.id in (select x.pedido_id from public.paradas x where x.corrida_id = c.id)),
    'eventos', (select coalesce(jsonb_agg(jsonb_build_object('tipo', e.tipo, 'dados', e.dados, 'quando', e.criado_em, 'autor', public.nome_publico(e.autor)) order by e.criado_em), '[]')
                  from public.eventos_corrida e where e.corrida_id = c.id),
    'chamados', (select coalesce(jsonb_agg(jsonb_build_object('tipo', h.tipo, 'status', h.status, 'motivo', h.motivo, 'resposta', h.resposta,
                   'criado_em', h.criado_em, 'respondido_em', h.respondido_em, 'parada_id', h.parada_id) order by h.criado_em), '[]')
                  from public.chamados_corrida h where h.corrida_id = c.id),
    'avaliacoes', (select coalesce(jsonb_agg(jsonb_build_object('nota', a.nota, 'comentario', a.comentario, 'autor', a.autor, 'quando', a.criado_em)), '[]')
                     from public.avaliacoes a where a.corrida_id = c.id),
    'ofertas', (select coalesce(jsonb_agg(jsonb_build_object('motoboy', public.nome_publico(o.motoboy_id), 'status', o.status, 'rodada', o.rodada,
                   'distancia_m', o.distancia_m, 'quando', o.criada_em) order by o.criada_em), '[]') from public.ofertas o where o.corrida_id = c.id),
    'pagamento', jsonb_build_object('valor', c.valor, 'motoboy', c.valor_motoboy, 'gestao', c.valor_gestao, 'calculo', c.pag_calculo,
                   'ajuste', c.pag_ajuste, 'ajuste_motivo', c.pag_ajuste_motivo));
end;
$$;
grant execute on function public.ficha_rota(uuid) to authenticated;

-- Para os percursos do mapa e do histórico do motoboy: número da rota e dos pedidos de cada registro
create or replace function public.rotas_resumo(p_ids uuid[])
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_object_agg(c.id, jsonb_build_object('numero', c.numero, 'teste', c.teste, 'status', c.status,
           'pedidos', (select coalesce(jsonb_agg(distinct jsonb_build_object('id', pd.id, 'numero', pd.numero)), '[]')
                         from public.paradas x join public.pedidos pd on pd.id = x.pedido_id where x.corrida_id = c.id))), '{}')
    from public.corridas c where c.id = any (p_ids[1:300]) and public.ve_corrida(c.id);
$$;
grant execute on function public.rotas_resumo(uuid[]) to authenticated;

