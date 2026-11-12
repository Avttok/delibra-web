-- =====================================================================
-- Delibra · 0044: o Dev decide o que os gestores podem (ajustes e ações), foco do Dev de verdade
--                  (Tudo / Em branco / empresa), várias rotas por motoboy, forçar início, apagar contas por completo
-- =====================================================================
set check_function_bodies = off;

-- pega de uma vez as tabelas que muda (as tarefas automáticas esperam em vez de travar)
do $$ begin
  perform set_config('lock_timeout', '60s', true);
  lock table public.perfis, public.motoboys, public.corridas, public.pedidos, public.chat_conversas, public.chat_membros,
             public.chat_mensagens, public.politicas, public.configuracoes, public.ofertas in access exclusive mode;
end $$;


-- ===================================================================== foco do Dev
-- Tudo: vê tudo de todas as empresas. Em branco: não vê nada (como um sistema novo). Empresa: só ela.
create or replace function public.ve_org(p_org uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select auth.uid() is null
      or (public.is_dev() and case when coalesce((select dev_vazio from public.perfis where id = auth.uid()), false) then false
                                   else (public.minha_org() is null or p_org is not distinct from public.minha_org()) end)
      or (not public.is_dev() and p_org is not distinct from public.minha_org());
$$;
create or replace function public.ve_org_ou_global(p_org uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select case when public.is_dev() and coalesce((select dev_vazio from public.perfis where id = auth.uid()), false) then false
              else p_org is null or public.ve_org(p_org) end;
$$;


create or replace function public.dev_conversas(p_org uuid default null)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when not public.is_dev() then '[]'::jsonb else coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', c.id, 'tipo', c.tipo, 'nome', c.nome, 'ultima_em', c.ultima_em, 'ultima_previa', c.ultima_previa,
      'organizacao_id', c.organizacao_id, 'organizacao', (select o.nome from public.organizacoes o where o.id = c.organizacao_id),
      'mensagens', (select count(*) from public.chat_mensagens g where g.conversa_id = c.id),
      'membros', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'nome', p.nome, 'foto', p.foto_url, 'papeis', to_jsonb(p.papeis)))
                             from public.chat_membros m join public.perfis p on p.id = m.usuario_id where m.conversa_id = c.id), '[]'::jsonb),
      'sou_membro', exists (select 1 from public.chat_membros m where m.conversa_id = c.id and m.usuario_id = auth.uid())
    ) order by c.ultima_em desc)
      from public.chat_conversas c where (p_org is null or c.organizacao_id = p_org) and public.ve_org(c.organizacao_id)), '[]'::jsonb) end;
$$;


create or replace function public.chat_conversas()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(x order by (x ->> 'ultima_em') desc), '[]'::jsonb) from (
    select jsonb_build_object(
      'id', c.id, 'tipo', c.tipo, 'corrida_id', c.corrida_id, 'empresa_id', c.empresa_id, 'arquivada', c.arquivada_em is not null, 'ultima_em', c.ultima_em, 'ultima_previa', c.ultima_previa, 'ultima_minha', c.ultima_autor = auth.uid(),
      'silenciada', coalesce(eu.silenciada, false),
      'nome', case when c.tipo = 'direta' then (select public.nome_publico(p.id) from public.chat_membros m join public.perfis p on p.id = m.usuario_id
                                                 where m.conversa_id = c.id and m.usuario_id <> auth.uid() limit 1) else c.nome end,
      'foto', case when c.tipo = 'direta' then (select public.foto_publica(p.id) from public.chat_membros m join public.perfis p on p.id = m.usuario_id
                                                 where m.conversa_id = c.id and m.usuario_id <> auth.uid() limit 1) end,
      'outro', case when c.tipo = 'direta' then (select m.usuario_id from public.chat_membros m where m.conversa_id = c.id and m.usuario_id <> auth.uid() limit 1) end,
      'oculto', case when c.tipo = 'direta' then (select public.dev_oculto_para_mim(m.usuario_id) from public.chat_membros m where m.conversa_id = c.id and m.usuario_id <> auth.uid() limit 1) end,
      'papeis', case when c.tipo = 'direta' then (select to_jsonb(p.papeis) from public.chat_membros m join public.perfis p on p.id = m.usuario_id where m.conversa_id = c.id and m.usuario_id <> auth.uid() limit 1) end,
      'membros', (select count(*) from public.chat_membros m where m.conversa_id = c.id and not public.dev_oculto_para_mim(m.usuario_id)),
      'nao_lidas', (select count(*) from public.chat_mensagens g where g.conversa_id = c.id and g.autor_id is distinct from auth.uid() and g.apagada_em is null
                     and g.criada_em > coalesce(eu.lida_em, case when c.tipo = 'geral' then now() - interval '1 day' else '-infinity' end))
    ) x
      from public.chat_conversas c
      left join public.chat_membros eu on eu.conversa_id = c.id and eu.usuario_id = auth.uid()
     where privado.cfg_bool('chat_ligado', true) and public.chat_participo(c.id)
       -- Dev: só as conversas do foco (Tudo = todas; Em branco = nenhuma; empresa = só dela)
       and (not public.is_dev() or public.ve_org(c.organizacao_id))
       -- conversa direta com o Dev oculto não aparece
       and not (c.tipo = 'direta' and exists (select 1 from public.chat_membros m where m.conversa_id = c.id and public.dev_oculto_para_mim(m.usuario_id)))
  ) t;
$$;


-- ===================================================================== o que os gestores podem (o Dev decide)
-- alvo: 'area:x' | 'grupo:x' | 'chave:x' (nível editar/ver/oculto) ou 'acao:x' (sim/nao).
-- organizacao_id nulo = padrão para todas as empresas; com empresa = só ela (vence o padrão).
create table if not exists public.ajuste_grupos (chave text primary key, grupo text not null, area text not null);
alter table public.ajuste_grupos enable row level security;
drop policy if exists ajuste_grupos_ler on public.ajuste_grupos;
create policy ajuste_grupos_ler on public.ajuste_grupos for select to authenticated using (true);
grant select on public.ajuste_grupos to authenticated;

insert into public.ajuste_grupos (chave, grupo, area) values
  ('cadastro_cliente_modo', 'cli_cadastro', 'clientes'),
  ('cadastro_express_liberado', 'cli_cadastro', 'clientes'),
  ('cadastro_cobranca', 'cli_cadastro', 'clientes'),
  ('cliente_pode_modelos', 'cli_pode', 'clientes'),
  ('cliente_confirma_foto', 'cli_pode', 'clientes'),
  ('cliente_confirma_nome', 'cli_pode', 'clientes'),
  ('cliente_confirma_assinatura', 'cli_pode', 'clientes'),
  ('cliente_confirma_codigo', 'cli_pode', 'clientes'),
  ('cliente_pode_janela', 'cli_pode', 'clientes'),
  ('cliente_pode_objetos', 'cli_pode', 'clientes'),
  ('cliente_modelo_horario', 'cli_pode', 'clientes'),
  ('cliente_pode_cancelar', 'cli_pode', 'clientes'),
  ('cliente_ve_preco', 'cli_ve', 'clientes'),
  ('cliente_ve_motoboy', 'cli_ve', 'clientes'),
  ('cliente_ve_codigo', 'cli_ve', 'clientes'),
  ('cliente_troca_senha', 'cli_pode', 'clientes'),
  ('item_categoria_obrigatoria', 'cli_pode', 'clientes'),
  ('zona_cliente_exclusiva', 'precocliente', 'preco'),
  ('mapa_offline_some_h', 'mapa', 'mapa'),
  ('mapa_offline_esmaecer', 'mapa', 'mapa'),
  ('motoboy_edita_veiculo', 'veiculo', 'motoboys'),
  ('veiculo_obrigatorio', 'veiculo', 'motoboys'),
  ('quadro_mostra_enderecos', 'quadro', 'operacao'),
  ('quadro_mostra_itens', 'quadro', 'operacao'),
  ('simulador_ligado', 'teste', 'sistema'),
  ('simulador_velocidade_kmh', 'teste', 'sistema'),
  ('voltar_revisao_aceitas', 'pedidos', 'operacao'),
  ('aviso_gestor_pedido', 'pedidos', 'operacao'),
  ('aviso_gestor_sem_motoboy', 'pedidos', 'operacao'),
  ('aviso_gestor_cadastro', 'pedidos', 'operacao'),
  ('pedido_revisao_gestor', 'pedidos', 'operacao'),
  ('cliente_pode_express', 'cli_pode', 'clientes'),
  ('agendada_antecedencia_cliente_min', 'cli_pode', 'clientes'),
  ('roteirizador_ligado', 'rotas', 'operacao'),
  ('roteirizar_agrupar', 'rotas', 'operacao'),
  ('rota_janela_min', 'rotas', 'operacao'),
  ('rota_raio_coleta_km', 'rotas', 'operacao'),
  ('rota_raio_entrega_km', 'rotas', 'operacao'),
  ('rota_max_entregas', 'rotas', 'operacao'),
  ('rota_max_coletas', 'rotas', 'operacao'),
  ('rota_max_km', 'rotas', 'operacao'),
  ('rota_montar_antes_min', 'rotas', 'operacao'),
  ('express_agrupar_espera_min', 'rotas', 'operacao'),
  ('rota_exclusiva_cliente', 'rotas', 'operacao'),
  ('perigoso_rota_exclusiva', 'rotas', 'operacao'),
  ('rota_revisao_gestor', 'rotas', 'operacao'),
  ('despacho_modo', 'despacho', 'operacao'),
  ('despacho_melhor_segundos', 'despacho', 'operacao'),
  ('fator_rua', 'navegacao', 'mapa'),
  ('pag_modo', 'pagamento', 'motoboys'),
  ('pag_modos', 'pag_combinar', 'motoboys'),
  ('pag_combinar', 'pag_combinar', 'motoboys'),
  ('pag_acrescimo_pct', 'pag_combinar', 'motoboys'),
  ('pag_acrescimo_rota', 'pag_combinar', 'motoboys'),
  ('pe_valor_km', 'pag_entrega', 'motoboys'),
  ('pe_fixo_entrega', 'pag_entrega', 'motoboys'),
  ('pe_minimo', 'pag_entrega', 'motoboys'),
  ('fx_valor_rota', 'pag_fixo', 'motoboys'),
  ('fx_valor_entrega', 'pag_fixo', 'motoboys'),
  ('fx_valor_coleta', 'pag_fixo', 'motoboys'),
  ('revisao_previa_rotas', 'aprender', 'operacao'),
  ('aprender_regras_rota', 'aprender', 'operacao'),
  ('aprender_entre_clientes', 'aprender', 'operacao'),
  ('aprender_percurso', 'aprender', 'operacao'),
  ('aprender_percurso_raio_m', 'aprender', 'operacao'),
  ('aprender_minimo', 'aprender', 'operacao'),
  ('pag_valor_km', 'pag_km', 'motoboys'),
  ('pag_entrega_extra', 'pag_km', 'motoboys'),
  ('pag_coleta_extra', 'pag_km', 'motoboys'),
  ('pag_fixo_rota', 'pag_km', 'motoboys'),
  ('pag_minimo', 'pag_km', 'motoboys'),
  ('pag_km_regra', 'pag_km', 'motoboys'),
  ('pag_km_percentil', 'pag_km', 'motoboys'),
  ('pag_distancia', 'pag_km', 'motoboys'),
  ('motoboy_ve_valores', 'mb_ve', 'motoboys'),
  ('motoboy_ve_holerite', 'mb_ve', 'motoboys'),
  ('motoboy_holerite_quando', 'mb_ve', 'motoboys'),
  ('motoboy_ve_holerite_valor', 'mb_ve', 'motoboys'),
  ('holerite_periodo', 'mb_ve', 'motoboys'),
  ('holerite_inicio_semana', 'mb_ve', 'motoboys'),
  ('preco_base', 'precocliente', 'preco'),
  ('preco_km', 'precocliente', 'preco'),
  ('preco_coleta_extra', 'precocliente', 'preco'),
  ('preco_entrega_extra', 'precocliente', 'preco'),
  ('preco_pacotes_inclusos', 'precocliente', 'preco'),
  ('preco_pacote_extra', 'precocliente', 'preco'),
  ('preco_kg_incluso', 'precocliente', 'preco'),
  ('preco_kg', 'precocliente', 'preco'),
  ('cubagem_fator', 'precocliente', 'preco'),
  ('preco_perigoso_pct', 'precocliente', 'preco'),
  ('preco_perigoso_fixo', 'precocliente', 'preco'),
  ('preco_express_pct', 'precocliente', 'preco'),
  ('preco_urgente_pct', 'precocliente', 'preco'),
  ('zona_combinar', 'precocliente', 'preco'),
  ('rotear_sem_pagamento', 'faturas', 'clientes'),
  ('cobranca_modo', 'faturas', 'clientes'),
  ('fatura_ciclo', 'faturas', 'clientes'),
  ('fatura_dia_semana', 'faturas', 'clientes'),
  ('fatura_vencimento_dias', 'faturas', 'clientes'),
  ('fatura_revisao', 'faturas', 'clientes'),
  ('oferta_segundos', 'despacho', 'operacao'),
  ('posicao_max_min', 'despacho', 'operacao'),
  ('raio_max_despacho_km', 'despacho', 'operacao'),
  ('raio_motoboy_max_km', 'despacho', 'operacao'),
  ('offline_auto_min', 'despacho', 'operacao'),
  ('favoritos_primeiro', 'despacho', 'operacao'),
  ('agendada_antecedencia_min', 'planejadas', 'operacao'),
  ('agendada_cancelar_ate_min', 'planejadas', 'operacao'),
  ('agendada_iniciar_antes_min', 'planejadas', 'operacao'),
  ('agendada_lembrete_min', 'planejadas', 'operacao'),
  ('agendada_despacho_auto', 'planejadas', 'operacao'),
  ('agendada_despacho_auto_min', 'planejadas', 'operacao'),
  ('agendada_atraso_min', 'planejadas', 'operacao'),
  ('agendada_max_por_motoboy', 'planejadas', 'operacao'),
  ('agendada_intervalo_min', 'planejadas', 'operacao'),
  ('exigir_no_local', 'local', 'motoboys'),
  ('raio_chegada_m', 'local', 'motoboys'),
  ('precisao_max_m', 'local', 'motoboys'),
  ('posicao_valida_s', 'local', 'motoboys'),
  ('pen_ligado', 'penalidades', 'motoboys'),
  ('pen_pts_ignorada', 'penalidades', 'motoboys'),
  ('pen_pts_recusa', 'penalidades', 'motoboys'),
  ('pen_pts_desistencia', 'penalidades', 'motoboys'),
  ('pen_pts_abandono', 'penalidades', 'motoboys'),
  ('pen_pts_atraso', 'penalidades', 'motoboys'),
  ('pen_janela_dias', 'penalidades', 'motoboys'),
  ('pen_limite', 'penalidades', 'motoboys'),
  ('pen_suspensao_horas', 'penalidades', 'motoboys'),
  ('pen_cliente_limite', 'penalidades', 'motoboys'),
  ('pen_cliente_bloqueio_horas', 'penalidades', 'motoboys'),
  ('chamado_motoboy_pode', 'chamados', 'motoboys'),
  ('chamado_redespachar', 'chamados', 'motoboys'),
  ('chamado_sem_resposta', 'chamados', 'motoboys'),
  ('chamado_prazo_min', 'chamados', 'motoboys'),
  ('pag_salario_mensal', 'pag_periodo', 'motoboys'),
  ('pag_salario_proporcional', 'pag_periodo', 'motoboys'),
  ('pag_diaria_valor', 'pag_periodo', 'motoboys'),
  ('pag_hora_valor', 'pag_periodo', 'motoboys'),
  ('pag_minimo_periodo', 'pag_periodo', 'motoboys'),
  ('pag_volta', 'pagamento', 'motoboys'),
  ('pag_volta_valor_km', 'pagamento', 'motoboys'),
  ('pag_volta_pct', 'pagamento', 'motoboys'),
  ('pag_volta_teto', 'pagamento', 'motoboys'),
  ('repasse_motoboy_pct', 'pagamento', 'motoboys'),
  ('pagamento_na_plataforma', 'mb_ve', 'motoboys'),
  ('passar_corrida_ligado', 'despacho', 'operacao'),
  ('passar_avisa_motoboy', 'despacho', 'operacao'),
  ('saas_gestor_compartilha_motoboys', 'despacho', 'operacao'),
  ('regiao_ligado', 'regiao', 'operacao'),
  ('regiao_bonus_m', 'regiao', 'operacao'),
  ('regiao_referencia', 'regiao', 'operacao'),
  ('regiao_min_por_entrega', 'regiao', 'operacao'),
  ('regiao_meia_vida_dias', 'regiao', 'operacao'),
  ('saas_compartilhar_corridas', 'despacho', 'operacao'),
  ('dev_pct', 'pagamento', 'motoboys'),
  ('valor_km_padrao', 'preco', 'preco'),
  ('valor_minimo', 'preco', 'preco'),
  ('arredondamento', 'preco', 'preco'),
  ('acrescimo_distancia', 'distancia', 'preco'),
  ('acrescimo_coleta_ligado', 'distancia', 'preco'),
  ('acrescimo_entrega_ligado', 'distancia', 'preco'),
  ('acrescimo_coleta_cada_km', 'distancia', 'preco'),
  ('acrescimo_coleta_fator', 'distancia', 'preco'),
  ('acrescimo_entrega_cada_km', 'distancia', 'preco'),
  ('acrescimo_entrega_fator', 'distancia', 'preco'),
  ('padrao_exige_nome', 'comprovantes', 'motoboys'),
  ('padrao_exige_foto', 'comprovantes', 'motoboys'),
  ('padrao_exige_assinatura', 'comprovantes', 'motoboys'),
  ('padrao_exige_codigo', 'comprovantes', 'motoboys'),
  ('intervalo_corrida_s', 'rastreamento', 'mapa'),
  ('intervalo_economia_s', 'rastreamento', 'mapa'),
  ('disponivel_envio_min', 'rastreamento', 'mapa'),
  ('disponivel_distancia_m', 'rastreamento', 'mapa'),
  ('teste_admin_ignora_local', 'teste', 'sistema'),
  ('cliente_pode_agendar', 'cli_pode', 'clientes'),
  ('cliente_pode_urgente', 'cli_pode', 'clientes'),
  ('cliente_max_entregas', 'cli_pode', 'clientes'),
  ('cliente_max_coletas', 'cli_pode', 'clientes'),
  ('cliente_max_pedidos_abertos', 'cli_pode', 'clientes'),
  ('cliente_agendar_max_dias', 'cli_pode', 'clientes'),
  ('cliente_pedido_de', 'cli_pode', 'clientes'),
  ('cliente_pedido_ate', 'cli_pode', 'clientes'),
  ('cliente_pode_ida_volta', 'cli_pode', 'clientes'),
  ('cliente_coleta_fixa', 'cli_pode', 'clientes'),
  ('cliente_pode_observacoes', 'cli_pode', 'clientes'),
  ('cliente_pode_chat', 'cli_pode', 'clientes'),
  ('cliente_ve_rota', 'cli_ve', 'clientes'),
  ('cliente_ve_faturas', 'cli_ve', 'clientes'),
  ('orcamento_trajeto', 'precocliente', 'preco'),
  ('preco_distancia_modo', 'precocliente', 'preco'),
  ('soma_inclui_saida', 'precocliente', 'preco'),
  ('soma_inclui_entrega_extra', 'precocliente', 'preco'),
  ('zona_entrega_raio_m', 'pag_zonas', 'motoboys'),
  ('zona_regra', 'pag_zonas', 'motoboys'),
  ('zona_fora_pct', 'pag_zonas', 'motoboys'),
  ('zona_km_regra', 'pag_zonas', 'motoboys'),
  ('zona_valor_km', 'pag_zonas', 'motoboys'),
  ('zona_entrega_extra', 'pag_zonas', 'motoboys'),
  ('zona_coleta_extra', 'pag_zonas', 'motoboys'),
  ('zona_fixo_rota', 'pag_zonas', 'motoboys'),
  ('zona_minimo', 'pag_zonas', 'motoboys'),
  ('despacho_sem_motoboy', 'despacho', 'operacao'),
  ('despacho_max_ofertas', 'despacho', 'operacao'),
  ('despacho_em_corrida', 'extensao', 'operacao'),
  ('extensao_raio_km', 'extensao', 'operacao'),
  ('extensao_max_entregas', 'extensao', 'operacao'),
  ('extensao_nunca_reduz', 'extensao', 'operacao'),
  ('quadro_avisa', 'quadro', 'operacao'),
  ('quadro_aviso_raio_km', 'quadro', 'operacao'),
  ('agendada_aviso_online_min', 'planejadas', 'operacao'),
  ('agendada_abrir_modo', 'planejadas', 'operacao'),
  ('ping_distancia_m', 'rastreamento', 'mapa'),
  ('ping_precisao_max_m', 'rastreamento', 'mapa'),
  ('ping_inteligente', 'rastreamento', 'mapa'),
  ('ping_curva_graus', 'rastreamento', 'mapa'),
  ('ping_reta_max_m', 'rastreamento', 'mapa'),
  ('ping_afinar_dias', 'rastreamento', 'mapa'),
  ('ping_afinar_m', 'rastreamento', 'mapa'),
  ('ping_ocioso_horas', 'rastreamento', 'mapa'),
  ('ping_ocioso_min', 'rastreamento', 'mapa'),
  ('ping_envio_s', 'rastreamento', 'mapa'),
  ('percurso_provedor', 'percurso', 'mapa'),
  ('percurso_perfil', 'percurso', 'mapa'),
  ('percurso_raio_m', 'percurso', 'mapa'),
  ('percurso_filtro_m', 'percurso', 'mapa'),
  ('percurso_vel_max_kmh', 'percurso', 'mapa'),
  ('percurso_tira_voltas', 'percurso', 'mapa'),
  ('percurso_volta_max_m', 'percurso', 'mapa'),
  ('rota_provedor', 'navegacao', 'mapa'),
  ('rota_perfil', 'navegacao', 'mapa'),
  ('navegacao_ligada', 'navegacao', 'mapa'),
  ('navegacao_voz', 'navegacao', 'mapa'),
  ('navegacao_na_notificacao', 'navegacao', 'mapa'),
  ('navegacao_recalcular_m', 'navegacao', 'mapa'),
  ('chat_ligado', 'chat', 'comunicacao'),
  ('chat_geral', 'chat', 'comunicacao'),
  ('chat_motoboy_direta', 'chat', 'comunicacao'),
  ('chat_fotos', 'chat', 'comunicacao'),
  ('chat_compartilhar', 'chat', 'comunicacao'),
  ('chat_compartilhar_tipos', 'chat', 'comunicacao'),
  ('compartilhar_motoboy_resumo', 'chat', 'comunicacao'),
  ('chat_grupos_equipe', 'chat', 'comunicacao'),
  ('dev_gestores_por_empresa', 'plataforma', 'sistema'),
  ('dev_supervisores_por_empresa', 'plataforma', 'sistema'),
  ('dev_escreve_em_conversas', 'chat', 'comunicacao'),
  ('chat_apagar_min', 'chat', 'comunicacao'),
  ('usuario_troca_senha', 'perfil', 'motoboys'),
  ('perfil_publico_ligado', 'perfil', 'motoboys'),
  ('perfil_mostra_numeros', 'perfil', 'motoboys'),
  ('perfil_mostra_conquistas', 'perfil', 'motoboys'),
  ('perfil_mostra_veiculo', 'perfil', 'motoboys'),
  ('perfil_mostra_regioes', 'perfil', 'motoboys'),
  ('jogo_ligado', 'app_motoboy', 'motoboys'),
  ('jogo_toques', 'app_motoboy', 'motoboys'),
  ('lembrar_pagina', 'app_motoboy', 'motoboys'),
  ('chat_motoboy_abre_rota', 'chat', 'comunicacao'),
  ('chat_rota_respostas', 'chat', 'comunicacao'),
  ('pedido_confirmar_revisao', 'pedidos', 'operacao'),
  ('saas_pular_parada', 'pular', 'motoboys'),
  ('pular_parada_ligado', 'pular', 'motoboys'),
  ('motoboy_pede_pular', 'pular', 'motoboys'),
  ('motoboy_pode_pular', 'pular', 'motoboys'),
  ('pen_pts_pulo', 'pular', 'motoboys'),
  ('offline_finalizar_ligado', 'offline', 'motoboys'),
  ('auto_fechar_ligado', 'offline', 'motoboys'),
  ('auto_fechar_folga_min', 'offline', 'motoboys'),
  ('auto_fechar_vel_kmh', 'offline', 'motoboys'),
  ('emergencia_ligada', 'emergencia', 'motoboys'),
  ('emergencia_avisa_gestor', 'emergencia', 'motoboys'),
  ('emergencia_avisa_supervisor', 'emergencia', 'motoboys'),
  ('dev_emergencia_receber', 'emergencia', 'motoboys'),
  ('saas_avaliacoes', 'avaliacoes', 'clientes'),
  ('avaliacao_ligada', 'avaliacoes', 'clientes'),
  ('avaliacao_quem', 'avaliacoes', 'clientes'),
  ('avaliacao_ruim_ate', 'avaliacoes', 'clientes'),
  ('pen_pts_avaliacao_ruim', 'avaliacoes', 'clientes'),
  ('avaliacao_avisa_gestor', 'avaliacoes', 'clientes'),
  ('saas_cliente_ve_nota_motoboy', 'avaliacoes', 'clientes'),
  ('cliente_ve_nota_motoboy', 'avaliacoes', 'clientes'),
  ('saas_rastreio', 'rastreio', 'clientes'),
  ('rastreio_ligado', 'rastreio', 'clientes'),
  ('rastreio_validade_h', 'rastreio', 'clientes'),
  ('rastreio_mostra_motoboy', 'rastreio', 'clientes'),
  ('rastreio_envio', 'rastreio', 'clientes'),
  ('dev_jogo_moedas_corrida', 'jogo', 'motoboys'),
  ('dev_jogo_moedas_entrega', 'jogo', 'motoboys'),
  ('dev_jogo_moedas_km', 'jogo', 'motoboys'),
  ('dev_jogo_moedas_avaliacao5', 'jogo', 'motoboys'),
  ('dev_jogo_moedas_pacote', 'jogo', 'motoboys'),
  ('dev_jogo_vel_max_kmh', 'jogo', 'motoboys'),
  ('dev_jogo_ranking', 'jogo', 'motoboys'),
  ('auditoria_ligada', 'auditoria', 'sistema'),
  ('dev_site_url', 'plataforma', 'sistema'),
  ('saas_dois_passos', 'plataforma', 'sistema'),
  ('saas_cadastro_empresas', 'plataforma', 'sistema'),
  ('saas_teste_dias', 'plataforma', 'sistema'),
  ('chat_reacoes', 'chat', 'comunicacao'),
  ('chat_editar_min', 'chat', 'comunicacao'),
  ('chat_corrida_ligado', 'chat', 'comunicacao'),
  ('chat_cliente_motoboy', 'chat', 'comunicacao'),
  ('chat_caixa_empresa', 'chat', 'comunicacao'),
  ('chat_atendimento_ligado', 'chat', 'comunicacao'),
  ('chat_atendimento_de', 'chat', 'comunicacao'),
  ('chat_atendimento_ate', 'chat', 'comunicacao'),
  ('chat_atendimento_dias', 'chat', 'comunicacao'),
  ('chat_resposta_auto', 'chat', 'comunicacao'),
  ('chat_gestor_gerencia_grupos', 'chat', 'comunicacao'),
  ('chat_audio_ligado', 'chat', 'comunicacao'),
  ('dev_chat_audio_ligado', 'chat', 'comunicacao'),
  ('dev_chat_audio_max_s', 'chat', 'comunicacao'),
  ('dev_chat_audio_dias', 'chat', 'comunicacao'),
  ('dev_chat_retencao_dias', 'chat', 'comunicacao'),
  ('dev_pag_provedor', 'integracoes', 'sistema'),
  ('dev_pag_liberacao_dias', 'integracoes', 'sistema'),
  ('dev_pag_taxa_quem', 'integracoes', 'sistema'),
  ('dev_licenca_modo', 'integracoes', 'sistema'),
  ('dev_devolucao_gestor_decide', 'integracoes', 'sistema'),
  ('devolucao_padrao', 'integracoes', 'sistema'),
  ('devolucao_taxa', 'integracoes', 'sistema'),
  ('dev_email_provedor', 'integracoes', 'sistema'),
  ('dev_whatsapp_provedor', 'integracoes', 'sistema'),
  ('email_aviso_cadastro', 'integracoes', 'sistema'),
  ('email_aviso_fatura', 'integracoes', 'sistema'),
  ('email_aviso_entregue', 'integracoes', 'sistema'),
  ('whatsapp_aviso_rastreio', 'integracoes', 'sistema'),
  ('whatsapp_modelo_rastreio', 'integracoes', 'sistema'),
  ('nf_cnpj_prestador', 'notafiscal', 'clientes'),
  ('nf_codigo_servico', 'notafiscal', 'clientes'),
  ('dev_nf_provedor', 'notafiscal', 'clientes'),
  ('nf_emissao', 'notafiscal', 'clientes')
on conflict (chave) do update set grupo = excluded.grupo, area = excluded.area;


create table if not exists public.permissoes_gestor (
  organizacao_id uuid references public.organizacoes (id) on delete cascade,
  alvo           text not null check (alvo ~ '^(area|grupo|chave|acao):[a-z0-9_]{1,60}$'),
  nivel          text not null check (nivel in ('editar', 'ver', 'oculto', 'sim', 'nao')),
  atualizado_em  timestamptz not null default now()
);
create unique index if not exists permissoes_gestor_un on public.permissoes_gestor (coalesce(organizacao_id, '00000000-0000-0000-0000-000000000000'::uuid), alvo);
alter table public.permissoes_gestor enable row level security;
drop policy if exists permissoes_gestor_dev on public.permissoes_gestor;
create policy permissoes_gestor_dev on public.permissoes_gestor for select to authenticated using ((select public.is_dev()));
grant select on public.permissoes_gestor to authenticated;

-- ações que o Dev liga e desliga para os gestores (padrão: podem)
create or replace function privado.acoes_gestor()
returns text[] language sql immutable as $$
  select array['criar_contas', 'excluir_contas', 'editar_cargos', 'apagar_historico', 'exportar_dados', 'editar_valor_pedido',
               'editar_pagamento_motoboy', 'ajuste_holerite', 'fechar_holerite', 'emitir_fatura', 'cancelar_rota', 'voltar_revisao',
               'chat_apagar', 'mudar_marca', 'modo_teste', 'ver_carteira', 'regras_por_cliente', 'regras_por_motoboy', 'penalidades', 'forcar_inicio'];
$$;

create or replace function privado.nivel_ajuste(p_org uuid, p_chave text)
returns text language sql stable security definer set search_path = '' as $$
  with g as (select grupo, area from public.ajuste_grupos where chave = p_chave),
  c as (select pg.nivel, pg.organizacao_id, case split_part(pg.alvo, ':', 1) when 'chave' then 1 when 'grupo' then 2 else 3 end ordem
          from public.permissoes_gestor pg
         where (pg.organizacao_id = p_org or pg.organizacao_id is null)
           and (pg.alvo = 'chave:' || p_chave or pg.alvo = 'grupo:' || (select grupo from g) or pg.alvo = 'area:' || (select area from g)))
  select coalesce((select nivel from c order by ordem, (organizacao_id is null) limit 1),
                  case when (select area from g) = 'sistema' then 'oculto' else 'editar' end);
$$;

create or replace function privado.gestor_pode_acao(p_org uuid, p_acao text)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select pg.nivel = 'sim' from public.permissoes_gestor pg
                    where pg.alvo = 'acao:' || p_acao and (pg.organizacao_id = p_org or pg.organizacao_id is null)
                    order by (pg.organizacao_id is null) limit 1), true);
$$;

-- barra a ação para gestor/supervisor quando o Dev desligou (o Dev e o servidor sempre podem)
create or replace function privado.exigir_acao(p_acao text)
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null or public.is_dev() then return; end if;
  if not privado.gestor_pode_acao(public.minha_org(), p_acao) then
    raise exception 'acao_bloqueada' using errcode = '42501', detail = p_acao;
  end if;
end;
$$;
revoke execute on function privado.nivel_ajuste(uuid, text), privado.gestor_pode_acao(uuid, text), privado.exigir_acao(text) from public, anon, authenticated;

-- o que eu (gestor) posso: ajustes fora do "editar" e as ações desligadas
create or replace function public.minhas_permissoes()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_org uuid := public.minha_org();
begin
  if public.is_dev() then return jsonb_build_object('dev', true, 'ajustes', '{}'::jsonb, 'acoes', '{}'::jsonb); end if;
  return jsonb_build_object('dev', false,
    'ajustes', coalesce((select jsonb_object_agg(g.chave, n) from (select chave, privado.nivel_ajuste(v_org, chave) n from public.ajuste_grupos) g where n <> 'editar'), '{}'::jsonb),
    'acoes', coalesce((select jsonb_object_agg(a, false) from unnest(privado.acoes_gestor()) a where not privado.gestor_pode_acao(v_org, a)), '{}'::jsonb));
end;
$$;
revoke execute on function public.minhas_permissoes() from public, anon;
grant execute on function public.minhas_permissoes() to authenticated;

-- Dev: lê e muda (p_org nulo = padrão de todas)
create or replace function public.dev_permissoes(p_org uuid default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  return jsonb_build_object(
    'proprias', coalesce((select jsonb_object_agg(alvo, nivel) from public.permissoes_gestor where organizacao_id is not distinct from p_org), '{}'::jsonb),
    'padrao', case when p_org is null then '{}'::jsonb else coalesce((select jsonb_object_agg(alvo, nivel) from public.permissoes_gestor where organizacao_id is null), '{}'::jsonb) end,
    'acoes', to_jsonb(privado.acoes_gestor()));
end;
$$;
create or replace function public.dev_definir_permissao(p_org uuid, p_alvo text, p_nivel text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  if p_nivel is null or p_nivel = '' then
    delete from public.permissoes_gestor where organizacao_id is not distinct from p_org and alvo = p_alvo;
    return;
  end if;
  insert into public.permissoes_gestor (organizacao_id, alvo, nivel) values (p_org, p_alvo, p_nivel)
  on conflict (coalesce(organizacao_id, '00000000-0000-0000-0000-000000000000'::uuid), alvo) do update set nivel = excluded.nivel, atualizado_em = now();
end;
$$;
revoke execute on function public.dev_permissoes(uuid), public.dev_definir_permissao(uuid, text, text) from public, anon;
grant execute on function public.dev_permissoes(uuid), public.dev_definir_permissao(uuid, text, text) to authenticated;


create or replace function public.posso(p_acao text)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.is_dev() or privado.gestor_pode_acao(public.minha_org(), p_acao);
$$;
grant execute on function public.posso(text) to authenticated;


create or replace function public.salvar_ajuste(p_chave text, p_valor jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare v_org uuid := public.minha_org();
begin
  if not public.is_gestor() or not public.pode('ajustes') then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if p_chave is null or p_chave !~ '^[a-z0-9_]{2,60}$' then raise exception 'chave_invalida' using errcode = '22023'; end if;
  if not public.is_dev() and privado.nivel_ajuste(v_org, p_chave) <> 'editar' then raise exception 'ajuste_bloqueado' using errcode = '42501'; end if;
  if p_chave ~ '^(app_|dev_|saas_)' or v_org is null then
    if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
    insert into public.configuracoes (chave, valor, atualizado_em, atualizado_por) values (p_chave, p_valor, now(), auth.uid())
    on conflict (chave) do update set valor = excluded.valor, atualizado_em = now(), atualizado_por = auth.uid();
    return;
  end if;
  insert into public.politicas (escopo, alvo, chave, valor, atualizado_em, atualizado_por)
  values ('organizacao', v_org::text, p_chave, p_valor, now(), auth.uid())
  on conflict (escopo, alvo, chave) do update set valor = excluded.valor, atualizado_em = now(), atualizado_por = auth.uid();
end;
$$;


create or replace function public.voltar_ajuste(p_chave text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_gestor() or not public.pode('ajustes') then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if not public.is_dev() and privado.nivel_ajuste(public.minha_org(), p_chave) <> 'editar' then raise exception 'ajuste_bloqueado' using errcode = '42501'; end if;
  delete from public.politicas where escopo = 'organizacao' and alvo = public.minha_org()::text and chave = p_chave;
end;
$$;


create or replace function public.definir_politica(p_escopo text, p_alvo text, p_chave text, p_valor jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if p_chave = 'dev_pct' and not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  if not public.is_dev() and privado.nivel_ajuste(public.minha_org(), p_chave) <> 'editar' then raise exception 'ajuste_bloqueado' using errcode = '42501'; end if;
  if p_escopo = 'cliente' then perform privado.exigir_acao('regras_por_cliente'); end if;
  if p_escopo = 'motoboy' then perform privado.exigir_acao('regras_por_motoboy'); end if;
  if p_escopo not in ('tipo', 'cliente', 'motoboy') or coalesce(p_alvo, '') = '' or coalesce(p_chave, '') = '' then
    raise exception 'politica_invalida' using errcode = '22023';
  end if;
  if p_escopo = 'motoboy' and not public.pode_gerenciar(p_alvo::uuid) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if p_escopo = 'cliente' and not exists (select 1 from public.empresas e where e.id::text = p_alvo and public.ve_org(e.organizacao_id)) then
    raise exception 'sem_permissao' using errcode = '42501';
  end if;
  -- tipo de pedido: a exceção é da empresa (o Dev em "Tudo" grava a regra geral)
  if p_escopo = 'tipo' and public.minha_org() is not null then p_alvo := public.minha_org()::text || ':' || regexp_replace(p_alvo, '^[^:]*:', ''); end if;
  if p_valor is null or p_valor = 'null'::jsonb then
    delete from public.politicas where escopo = p_escopo and alvo = p_alvo and chave = p_chave;
  else
    insert into public.politicas (escopo, alvo, chave, valor, atualizado_em, atualizado_por)
    values (p_escopo, p_alvo, p_chave, p_valor, now(), auth.uid())
    on conflict (escopo, alvo, chave) do update set valor = excluded.valor, atualizado_em = now(), atualizado_por = auth.uid();
  end if;
end;
$$;


create or replace function public.ajustar_pagamento_rota(p_corrida uuid, p_ajuste numeric, p_motivo text, p_mostrar boolean default true)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c public.corridas%rowtype; v_per record;
begin
  perform privado.exigir_acao('editar_pagamento_motoboy');
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
  update public.corridas set pag_ajuste = round(coalesce(p_ajuste, 0), 2), pag_ajuste_motivo = nullif(trim(p_motivo), ''), pag_ajuste_mostrar = coalesce(p_mostrar, true) where id = p_corrida;
  update public.corridas set valor_motoboy = coalesce((pag_calculo ->> 'total')::numeric, valor_motoboy - 0) + pag_ajuste where id = p_corrida and pag_calculo is not null;
  perform privado.evento(p_corrida, 'pagamento_ajustado', jsonb_build_object('ajuste', p_ajuste, 'motivo', p_motivo));
  return (select jsonb_build_object('valor_motoboy', valor_motoboy, 'pag_calculo', pag_calculo, 'pag_ajuste', pag_ajuste) from public.corridas where id = p_corrida);
end;
$$;


create or replace function public.definir_regras_rota(p_corrida uuid, p_regras jsonb, p_motivo text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c public.corridas%rowtype; v_r jsonb;
begin
  perform privado.exigir_acao('editar_pagamento_motoboy');
  -- outra empresa: recusa
  if p_corrida is not null and not public.ve_corrida(p_corrida) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select * into c from public.corridas where id = p_corrida for update;
  if not found then raise exception 'rota_nao_encontrada' using errcode = '22023'; end if;
  if c.status::text = 'cancelada' then raise exception 'rota_nao_editavel' using errcode = '22023'; end if;
  if c.concluida_em is not null and c.motoboy_id is not null then
    if exists (select 1 from public.holerites hh, privado.periodo_holerite(c.motoboy_id, privado.dia_local(c.concluida_em)) per
                where hh.motoboy_id = c.motoboy_id and hh.teste = c.teste and hh.inicio = per.inicio and hh.fim = per.fim and hh.status <> 'aberto') then
      raise exception 'holerite_fechado' using errcode = '22023';
    end if;
  end if;
  v_r := nullif(privado.limpar_regras(coalesce(p_regras, '{}')), '{}');
  -- pag_modos vem como lista
  if p_regras ? 'pag_modos' and jsonb_typeof(p_regras -> 'pag_modos') = 'array' then v_r := coalesce(v_r, '{}') || jsonb_build_object('pag_modos', p_regras -> 'pag_modos'); end if;
  update public.corridas set pag_regras = v_r where id = p_corrida;
  if c.motoboy_id is null then update public.corridas set pag_calculo = privado.calcular_pagamento(p_corrida, null) where id = p_corrida;
  else
    -- com motoboy: o valor dele muda na hora
    update public.corridas set pag_calculo = privado.calcular_pagamento(p_corrida, c.motoboy_id) where id = p_corrida;
    update public.corridas set valor_motoboy = (pag_calculo ->> 'total')::numeric + pag_ajuste where id = p_corrida;
  end if;
  perform privado.decisao('regras', p_corrida, jsonb_build_object('antes', coalesce(c.pag_regras, '{}'), 'depois', coalesce(v_r, '{}'), 'motivo', p_motivo));
  return (select pag_calculo from public.corridas where id = p_corrida);
end;
$$;


create or replace function public.ajuste_holerite(p_motoboy uuid, p_inicio date, p_fim date, p_descricao text, p_valor numeric, p_teste boolean default false,
                                                  p_visibilidade text default 'tudo')
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_h uuid; v_id uuid;
begin
  perform privado.exigir_acao('ajuste_holerite');
  if p_motoboy is not null and not public.ve_pessoa(p_motoboy) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if coalesce(trim(p_descricao), '') = '' or coalesce(p_valor, 0) = 0 then raise exception 'ajuste_invalido' using errcode = '22023'; end if;
  v_h := privado.holerite_aberto(p_motoboy, p_inicio, p_fim, p_teste);
  insert into public.holerite_ajustes (holerite_id, descricao, valor, criado_por, visibilidade)
  values (v_h, left(trim(p_descricao), 200), round(p_valor, 2), auth.uid(), case when p_visibilidade in ('tudo', 'valor', 'oculto') then p_visibilidade else 'tudo' end)
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
  perform privado.exigir_acao('apagar_historico');
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


create or replace function public.relatorio(p_tipo text, p_de date, p_ate date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_de timestamptz := (p_de::timestamp) at time zone 'America/Sao_Paulo';
  v_ate timestamptz := ((p_ate + 1)::timestamp) at time zone 'America/Sao_Paulo';
  v_teste boolean := coalesce((select p.modo_teste from public.perfis p where p.id = auth.uid()), false);
  r jsonb;
begin
  perform privado.exigir_acao('exportar_dados');
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if p_de is null or p_ate is null or p_ate < p_de or p_ate - p_de > 400 then raise exception 'periodo_invalido' using errcode = '22023'; end if;
  if p_tipo = 'rotas' then
    select coalesce(jsonb_agg(jsonb_build_object(
        'Rota', c.numero, 'Data', to_char(coalesce(c.concluida_em, c.cancelada_em, c.criada_em) at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI'),
        'Situação', case c.status::text when 'concluida' then 'Concluída' when 'cancelada' then 'Cancelada' else c.status::text end,
        'Cliente', coalesce(c.cliente_nome, ''), 'Motoboy', coalesce(public.nome_publico(c.motoboy_id), ''),
        'Paradas', (select count(*) from public.paradas x where x.corrida_id = c.id),
        'Km', round(coalesce(c.distancia_real_m, c.distancia_planejada_m, 0) / 1000.0, 1),
        'Valor', coalesce(c.valor, 0), 'Motoboy recebe', coalesce(c.valor_motoboy, 0), 'Empresa fica', coalesce(c.valor_gestao, 0))
        order by coalesce(c.concluida_em, c.cancelada_em, c.criada_em)), '[]') into r
      from public.corridas c
     where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text in ('concluida', 'cancelada')
       and coalesce(c.concluida_em, c.cancelada_em) >= v_de and coalesce(c.concluida_em, c.cancelada_em) < v_ate;
  elsif p_tipo = 'pedidos' then
    select coalesce(jsonb_agg(jsonb_build_object(
        'Pedido', p.numero, 'Data', to_char(p.criado_em at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI'),
        'Cliente', coalesce(e.nome, p.cliente_nome, 'Avulso'), 'Situação', p.status::text, 'Origem', coalesce(p.origem::text, ''),
        'Km estimado', round(coalesce(p.distancia_estimada_m, 0) / 1000.0, 1), 'Valor', coalesce(p.valor, 0),
        'Pagamento', coalesce(p.pagamento_status::text, '')) order by p.criado_em), '[]') into r
      from public.pedidos p left join public.empresas e on e.id = p.empresa_id
     where public.ve_org(p.organizacao_id) and p.teste = v_teste and p.criado_em >= v_de and p.criado_em < v_ate;
  elsif p_tipo = 'motoboys' then
    select coalesce(jsonb_agg(x order by x ->> 'Motoboy'), '[]') into r from (
      select jsonb_build_object('Motoboy', coalesce(public.nome_publico(c.motoboy_id), ''), 'Rotas', count(*),
        'Entregas', sum((select count(*) from public.paradas x where x.corrida_id = c.id and x.tipo::text = 'entrega')),
        'Km', round(sum(coalesce(c.distancia_real_m, c.distancia_planejada_m, 0)) / 1000.0, 1),
        'Valor das rotas', sum(coalesce(c.valor, 0)), 'A receber', sum(coalesce(c.valor_motoboy, 0))) x
        from public.corridas c
       where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'concluida' and c.motoboy_id is not null
         and c.concluida_em >= v_de and c.concluida_em < v_ate and not public.dev_oculto_para_mim(c.motoboy_id)
       group by c.motoboy_id) t;
  elsif p_tipo = 'clientes' then
    select coalesce(jsonb_agg(x order by (x ->> 'Faturado')::numeric desc), '[]') into r from (
      select jsonb_build_object('Cliente', coalesce(e.nome, p.cliente_nome, 'Avulso'), 'Pedidos', count(*),
        'Entregues', count(*) filter (where p.status::text in ('concluido', 'entregue')), 'Cancelados', count(*) filter (where p.status::text in ('cancelado', 'recusado')),
        'Faturado', sum(coalesce(p.valor, 0)) filter (where p.status::text not in ('cancelado', 'recusado'))) x
        from public.pedidos p left join public.empresas e on e.id = p.empresa_id
       where public.ve_org(p.organizacao_id) and p.teste = v_teste and p.criado_em >= v_de and p.criado_em < v_ate
       group by coalesce(e.nome, p.cliente_nome, 'Avulso')) t;
  else
    raise exception 'tipo_invalido' using errcode = '22023';
  end if;
  return r;
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
  if p_acao = 'ajustar' or (p_acao = 'aprovar' and p_valor is not null) then perform privado.exigir_acao('editar_valor_pedido'); end if;
  if p_acao = 'voltar_revisao' then perform privado.exigir_acao('voltar_revisao'); end if;
  select * into p from public.pedidos where id = p_pedido for update;
  if not found then raise exception 'pedido_nao_encontrado' using errcode = '22023'; end if;
  -- cancelado ou recusado: volta para a revisão (o gestor aprova de novo e vira rota outra vez)
  if p_acao = 'voltar_revisao' and p.status in ('cancelado', 'recusado') then
    update public.pedidos set status = 'recebido', cancelado_em = null, recusa_motivo = null, aprovado_em = null, revisado_por = null, revisado_em = null where id = p.id;
    update public.pedido_pontos set status = 'pendente' where pedido_id = p.id and status::text <> 'concluido';
    return (select to_jsonb(x) from public.pedidos x where x.id = p.id);
  end if;
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


-- ===================================================================== apagar: mais categorias
create or replace function privado.dev_categorias()
returns jsonb language sql immutable set search_path = '' as $$
  select jsonb_build_array(
    jsonb_build_object('chave', 'pedidos', 'nome', 'Pedidos', 'descricao', 'Pedidos com pontos, itens e histórico. As rotas ficam sem as paradas deles.'),
    jsonb_build_object('chave', 'corridas', 'nome', 'Rotas e corridas', 'descricao', 'Rotas, paradas, ofertas, eventos e os pings ligados a elas.'),
    jsonb_build_object('chave', 'percursos', 'nome', 'Percursos (pings)', 'descricao', 'Todas as posições guardadas e o traçado pelas ruas.'),
    jsonb_build_object('chave', 'ofertas', 'nome', 'Ofertas', 'descricao', 'Ofertas enviadas aos motoboys (aceitas, recusadas, expiradas).'),
    jsonb_build_object('chave', 'faturas', 'nome', 'Faturas', 'descricao', 'Faturas dos clientes (os pedidos voltam a ficar sem fatura).'),
    jsonb_build_object('chave', 'holerites', 'nome', 'Folha', 'descricao', 'Holerites e ajustes da folha.'),
    jsonb_build_object('chave', 'chat', 'nome', 'Chat', 'descricao', 'Mensagens e conversas (a conversa geral é recriada vazia).'),
    jsonb_build_object('chave', 'modelos', 'nome', 'Modelos e objetos', 'descricao', 'Modelos de pedido e objetos salvos pelos clientes.'),
    jsonb_build_object('chave', 'clientes', 'nome', 'Clientes', 'descricao', 'Empresas e pessoas cadastradas, com pedidos, faturas e contas de acesso desvinculadas.'),
    jsonb_build_object('chave', 'cadastros', 'nome', 'Cadastros pendentes', 'descricao', 'Pedidos de cadastro feitos pelo site.'),
    jsonb_build_object('chave', 'excecoes', 'nome', 'Exceções (regras por alvo)', 'descricao', 'Regras por tipo, cliente e motoboy. As gerais ficam.'),
    jsonb_build_object('chave', 'zonas', 'nome', 'Zonas de preço', 'descricao', 'Raios com dinâmica de preço.'),
    jsonb_build_object('chave', 'horarios', 'nome', 'Horários de pico', 'descricao', 'Faixas de horário com acréscimo.'),
    jsonb_build_object('chave', 'registros', 'nome', 'Registros de exclusão', 'descricao', 'Cópias guardadas de corridas e contas apagadas.'),
    jsonb_build_object('chave', 'conquistas', 'nome', 'Conquistas manuais', 'descricao', 'Medalhas liberadas ou bloqueadas à mão.'),
    jsonb_build_object('chave', 'pix', 'nome', 'Chaves PIX', 'descricao', 'Chaves PIX cadastradas pela equipe.'),
    jsonb_build_object('chave', 'configuracoes', 'nome', 'Configurações', 'descricao', 'Volta todos os ajustes gerais para o padrão.'),
    jsonb_build_object('chave', 'avaliacoes', 'nome', 'Avaliações', 'descricao', 'Notas e comentários dos clientes.'),
    jsonb_build_object('chave', 'emergencias', 'nome', 'Emergências', 'descricao', 'Alertas de emergência dos motoboys (abertos e resolvidos).'),
    jsonb_build_object('chave', 'chamados', 'nome', 'Pedidos dos motoboys', 'descricao', 'Pedidos de cancelar, pular e passar rota.'),
    jsonb_build_object('chave', 'penalidades', 'nome', 'Penalidades', 'descricao', 'Penalidades e pontos dos motoboys.'),
    jsonb_build_object('chave', 'jogo', 'nome', 'Jogo', 'descricao', 'Partidas, moedas, itens comprados e ranking.'),
    jsonb_build_object('chave', 'rastreios', 'nome', 'Links de acompanhar', 'descricao', 'Links públicos de acompanhar a entrega.'),
    jsonb_build_object('chave', 'auditoria', 'nome', 'Histórico de mudanças', 'descricao', 'Quem mudou o quê, eventos das rotas e dos pedidos.'),
    jsonb_build_object('chave', 'pagamentos', 'nome', 'Pagamentos', 'descricao', 'Cobranças e pagamentos dos pedidos (registro do sistema).'),
    jsonb_build_object('chave', 'aprendizado', 'nome', 'Aprendizado', 'descricao', 'O que o sistema aprendeu das suas decisões (rotas e regiões).'),
    jsonb_build_object('chave', 'envios', 'nome', 'Envios externos', 'descricao', 'Fila de e-mails, WhatsApp e notas.'));
$$;


create or replace function public.dev_contagem()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  return (select jsonb_agg(k || jsonb_build_object('total', case k ->> 'chave'
      when 'pedidos' then (select count(*) from public.pedidos)
      when 'corridas' then (select count(*) from public.corridas)
      when 'percursos' then (select count(*) from public.localizacoes)
      when 'ofertas' then (select count(*) from public.ofertas)
      when 'faturas' then (select count(*) from public.faturas)
      when 'holerites' then (select count(*) from public.holerites) + (select count(*) from public.holerite_ajustes)
      when 'chat' then (select count(*) from public.chat_mensagens)
      when 'modelos' then (select count(*) from public.pedido_modelos) + (select count(*) from public.cliente_objetos)
      when 'clientes' then (select count(*) from public.empresas)
      when 'cadastros' then (select count(*) from public.cadastros_cliente)
      when 'excecoes' then (select count(*) from public.politicas)
      when 'zonas' then (select count(*) from public.zonas)
      when 'horarios' then (select count(*) from public.faixas_horario)
      when 'registros' then (select count(*) from public.registro_exclusoes) + (select count(*) from public.registro_contas_excluidas)
      when 'conquistas' then (select count(*) from public.conquistas_manuais)
      when 'pix' then (select count(*) from public.chaves_pix)
      when 'configuracoes' then (select count(*) from public.configuracoes)
      when 'avaliacoes' then (select count(*) from public.avaliacoes)
      when 'emergencias' then (select count(*) from public.emergencias)
      when 'chamados' then (select count(*) from public.chamados_corrida)
      when 'penalidades' then (select count(*) from public.penalidades)
      when 'jogo' then (select count(*) from public.jogo_partidas)
      when 'rastreios' then (select count(*) from public.rastreios)
      when 'auditoria' then (select count(*) from public.auditoria)
      when 'pagamentos' then (select count(*) from public.pagamentos)
      when 'aprendizado' then (select count(*) from public.decisoes_rota)
      when 'envios' then (select count(*) from privado.avisos_externos)
      else 0 end)) from jsonb_array_elements(privado.dev_categorias()) k);
end;
$$;


create or replace function public.dev_apagar_interno(p_categoria text, p_ids text[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_n    bigint := 0;
  v_k    bigint;
  v_tudo boolean := p_ids is null;
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  if p_categoria = 'pedidos' then
    delete from public.paradas where pedido_id in (select id from public.pedidos where v_tudo or id::text = any (p_ids));
    delete from public.pedidos where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count;
    -- rotas que ficaram vazias
    delete from public.corridas c where c.origem = 'roteirizador' and not exists (select 1 from public.paradas x where x.corrida_id = c.id);
  elsif p_categoria = 'corridas' then
    delete from public.localizacoes where corrida_id in (select id from public.corridas where v_tudo or id::text = any (p_ids));
    update public.motoboys set status = 'disponivel', status_em = now()
     where status = 'em_corrida' and id in (select motoboy_id from public.corridas where (v_tudo or id::text = any (p_ids)) and status::text in ('aceita', 'em_andamento'));
    delete from public.corridas where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count;
    update public.pedidos p set status = 'aprovado' where p.status in ('roteirizado', 'em_rota') and not exists (select 1 from public.paradas x where x.pedido_id = p.id);
    update public.pedido_pontos pp set status = 'pendente' where pp.status = 'em_rota' and not exists (select 1 from public.paradas x where x.pedido_ponto_id = pp.id);
  elsif p_categoria = 'percursos' then
    delete from public.localizacoes where v_tudo or motoboy_id::text = any (p_ids); get diagnostics v_n = row_count;
    delete from public.trechos_ajustados where v_tudo or motoboy_id::text = any (p_ids);
  elsif p_categoria = 'ofertas' then
    delete from public.ofertas where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count;
  elsif p_categoria = 'faturas' then
    update public.pedidos set fatura_id = null where fatura_id in (select id from public.faturas where v_tudo or id::text = any (p_ids));
    delete from public.faturas where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count;
  elsif p_categoria = 'holerites' then
    delete from public.holerite_ajustes where v_tudo or holerite_id::text = any (p_ids); get diagnostics v_k = row_count;
    delete from public.holerites where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count; v_n := v_n + v_k;
  elsif p_categoria = 'chat' then
    select count(*) into v_n from public.chat_mensagens where v_tudo or conversa_id::text = any (p_ids);
    delete from public.chat_conversas where v_tudo or id::text = any (p_ids);
    insert into public.chat_conversas (tipo, nome) select 'geral', 'Equipe' where not exists (select 1 from public.chat_conversas where tipo = 'geral');
  elsif p_categoria = 'modelos' then
    delete from public.pedido_modelos where v_tudo or id::text = any (p_ids); get diagnostics v_k = row_count;
    delete from public.cliente_objetos where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count; v_n := v_n + v_k;
  elsif p_categoria = 'clientes' then
    delete from public.paradas where pedido_id in (select id from public.pedidos where empresa_id in (select id from public.empresas where v_tudo or id::text = any (p_ids)));
    delete from public.pedidos where empresa_id in (select id from public.empresas where v_tudo or id::text = any (p_ids));
    delete from public.faturas where empresa_id in (select id from public.empresas where v_tudo or id::text = any (p_ids));
    update public.corridas set empresa_id = null where empresa_id in (select id from public.empresas where v_tudo or id::text = any (p_ids));
    update public.perfis set empresa_id = null where empresa_id in (select id from public.empresas where v_tudo or id::text = any (p_ids));
    delete from public.politicas where escopo = 'cliente' and (v_tudo or alvo = any (p_ids));
    delete from public.empresas where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count;
  elsif p_categoria = 'cadastros' then
    delete from public.cadastros_cliente where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count;
  elsif p_categoria = 'excecoes' then
    delete from public.politicas where v_tudo or md5(escopo || alvo || chave) = any (p_ids); get diagnostics v_n = row_count;
  elsif p_categoria = 'zonas' then
    delete from public.zonas where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count;
  elsif p_categoria = 'horarios' then
    delete from public.faixas_horario where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count;
  elsif p_categoria = 'registros' then
    -- ids "c:N" (corrida apagada) e "u:N" (conta excluída); sem filtro = tudo (com WHERE: o Supabase recusa DELETE sem WHERE)
    delete from public.registro_exclusoes where v_tudo or 'c:' || id = any (p_ids) or id::text = any (p_ids); get diagnostics v_n = row_count;
    delete from public.registro_contas_excluidas where v_tudo or 'u:' || id = any (p_ids); get diagnostics v_k = row_count; v_n := v_n + v_k;
  elsif p_categoria = 'conquistas' then
    delete from public.conquistas_manuais where v_tudo or md5(perfil_id::text || chave) = any (p_ids); get diagnostics v_n = row_count;
  elsif p_categoria = 'pix' then
    delete from public.chaves_pix where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count;
  elsif p_categoria = 'configuracoes' then
    -- apagar = voltar ao padrão (cada regra tem o padrão dela no sistema)
    delete from public.configuracoes where (v_tudo or md5(chave) = any (p_ids)) and chave not in ('versao_minima_app', 'versao_obrigatoria');
    get diagnostics v_n = row_count;
  elsif p_categoria = 'avaliacoes' then
    delete from public.avaliacoes where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count;
  elsif p_categoria = 'emergencias' then
    delete from public.emergencias where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count;
  elsif p_categoria = 'chamados' then
    delete from public.chamados_corrida where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count;
  elsif p_categoria = 'penalidades' then
    delete from public.penalidades where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count;
  elsif p_categoria = 'jogo' then
    delete from public.jogo_partidas where v_tudo; get diagnostics v_n = row_count; delete from public.jogo_perfis where v_tudo; get diagnostics v_k = row_count; v_n := v_n + v_k;
  elsif p_categoria = 'rastreios' then
    delete from public.rastreios where v_tudo or token = any (p_ids); get diagnostics v_n = row_count;
  elsif p_categoria = 'auditoria' then
    delete from public.auditoria where v_tudo; get diagnostics v_n = row_count; delete from public.eventos_corrida where v_tudo; get diagnostics v_k = row_count; v_n := v_n + v_k; delete from public.pedido_eventos where v_tudo; get diagnostics v_k = row_count; v_n := v_n + v_k;
  elsif p_categoria = 'pagamentos' then
    delete from public.pagamentos where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count;
  elsif p_categoria = 'aprendizado' then
    delete from public.decisoes_rota where v_tudo; get diagnostics v_n = row_count;
  elsif p_categoria = 'envios' then
    delete from privado.avisos_externos where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count;
  else
    raise exception 'categoria_invalida' using errcode = '22023';
  end if;
  return jsonb_build_object('apagados', v_n);
end;
$$;


create or replace function public.dev_apagar(p_senha text, p_categoria text, p_ids text[] default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_erro jsonb;
  v_n    bigint := 0;
  v_k    bigint;
  v_cat  text;
  v_tudo boolean := p_ids is null;
  v_u    uuid[];
  v_arq  text[] := '{}';
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  v_erro := privado.senha_com_limite(p_senha);
  if v_erro is not null then return v_erro; end if;
  if p_categoria in ('tudo', 'tudo_mesmo') then
    foreach v_cat in array (case when p_categoria = 'tudo'
        then array['chat', 'ofertas', 'faturas', 'holerites', 'corridas', 'pedidos', 'percursos', 'registros']
        else array['chat', 'ofertas', 'faturas', 'holerites', 'corridas', 'pedidos', 'percursos', 'registros', 'modelos', 'cadastros', 'clientes', 'excecoes', 'zonas', 'horarios', 'conquistas', 'pix', 'configuracoes', 'avaliacoes', 'emergencias', 'chamados', 'penalidades', 'jogo', 'rastreios', 'auditoria', 'pagamentos', 'aprendizado', 'envios'] end) loop
      v_n := v_n + coalesce((public.dev_apagar_interno(v_cat, null) ->> 'apagados')::bigint, 0);
    end loop;
    return jsonb_build_object('apagados', v_n);
  end if;
  return public.dev_apagar_interno(p_categoria, p_ids);
end;
$$;


-- Dev confere a senha antes de ações do servidor (apagar contas)
create or replace function public.dev_conferir_senha(p_senha text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  return coalesce(privado.senha_com_limite(p_senha), jsonb_build_object('ok', true));
end;
$$;
revoke execute on function public.dev_conferir_senha(text) from public, anon;
grant execute on function public.dev_conferir_senha(text) to authenticated;

-- apagar a conta por completo: além da conta, some o que identifica a pessoa (cópia guardada, mensagens, nome nas rotas)
create or replace function public.apagar_rastros_conta(p_usuario uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not privado.eh_servico() then raise exception 'apenas_servidor' using errcode = '42501'; end if;
  delete from public.registro_contas_excluidas where usuario_id = p_usuario;
  delete from public.chat_mensagens where autor_id = p_usuario;
  delete from public.chat_membros where usuario_id = p_usuario;
  delete from public.cadastros_cliente where perfil_id = p_usuario;
  delete from public.chaves_pix where usuario_id = p_usuario;
  delete from public.jogo_partidas where motoboy_id = p_usuario;
  delete from public.jogo_perfis where motoboy_id = p_usuario;
  update public.corridas set motoboy_nome_arquivado = 'Conta apagada' where motoboy_id = p_usuario;
  update public.corridas set criada_por_nome_arquivado = 'Conta apagada' where criada_por = p_usuario;
end;
$$;
revoke execute on function public.apagar_rastros_conta(uuid) from public, anon, authenticated;
do $$ begin execute 'grant execute on function public.apagar_rastros_conta(uuid) to service_role'; exception when undefined_object then null; end $$;


-- ===================================================================== várias rotas ao mesmo tempo (o gestor decide quantas)
create or replace function privado.pode_mais_rota(p_motoboy uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select (select count(*) from public.corridas where motoboy_id = p_motoboy and status in ('aceita', 'em_andamento'))
         < greatest(privado.pol_num('motoboy_rotas_simultaneas', 1, null, p_motoboy, null), 1);
$$;
revoke execute on function privado.pode_mais_rota(uuid) from public, anon, authenticated;

-- terminou uma rota mas ainda tem outra: continua "em corrida"
create or replace function privado.manter_em_corrida()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status::text = 'disponivel' and exists (select 1 from public.corridas where motoboy_id = new.id and status in ('aceita', 'em_andamento')) then
    new.status := 'em_corrida';
  end if;
  return new;
end;
$$;
drop trigger if exists manter_em_corrida on public.motoboys;
create trigger manter_em_corrida before update of status on public.motoboys for each row execute function privado.manter_em_corrida();

create or replace function public.minha_corrida_ativa()
returns jsonb language sql stable security definer set search_path = '' as $$
  select privado.corrida_json(c.id)
  from public.corridas c
  where c.motoboy_id = auth.uid() and c.status in ('aceita', 'em_andamento')
  order by (c.status::text = 'em_andamento') desc, c.aceita_em
  limit 1;
$$;
create or replace function public.minhas_corridas_ativas()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(privado.corrida_json(c.id) order by (c.status::text = 'em_andamento') desc, c.aceita_em), '[]'::jsonb)
  from public.corridas c
  where c.motoboy_id = auth.uid() and c.status in ('aceita', 'em_andamento');
$$;
grant execute on function public.minhas_corridas_ativas() to authenticated;

-- antes de pegar mais uma: quão longe ela fica das que eu já tenho (para o aviso)
create or replace function public.distancia_das_minhas_rotas(p_corrida uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  with nova as (select lat, lng from public.paradas where corrida_id = p_corrida order by ordem limit 1),
  minhas as (select x.lat, x.lng from public.paradas x join public.corridas c on c.id = x.corrida_id
              where c.motoboy_id = auth.uid() and c.status in ('aceita', 'em_andamento') and x.status::text <> 'concluida')
  select jsonb_build_object(
    'tenho', (select count(*) from public.corridas where motoboy_id = auth.uid() and status in ('aceita', 'em_andamento')),
    'pode', privado.pode_mais_rota(auth.uid()),
    'km', (select round((min(privado.dist_m(n.lat, n.lng, m.lat, m.lng)) / 1000.0)::numeric, 1) from nova n, minhas m),
    'aviso_km', privado.pol_num('motoboy_rotas_distancia_aviso_km', 5, null, auth.uid(), null));
$$;
grant execute on function public.distancia_das_minhas_rotas(uuid) to authenticated;


create or replace function privado.iniciar_reservada(p_corrida uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  c       public.corridas%rowtype;
  v_pct   numeric;
begin
  select * into c from public.corridas where id = p_corrida for update;
  if not found or c.status::text <> 'reservada' then raise exception 'reserva_nao_encontrada' using errcode = '22023'; end if;
  if not privado.pode_mais_rota(c.motoboy_id) then
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


create or replace function public.pegar_rota(p_corrida uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c       public.corridas%rowtype;
  v_teste boolean := coalesce((select modo_teste from public.motoboys where id = auth.uid()), false);
begin
  if privado.motoboy_suspenso(auth.uid()) then raise exception 'motoboy_suspenso' using errcode = '42501'; end if;
  perform privado.checar_versao_app();
  if not public.tem_papel('motoboy'::public.papel_usuario) then raise exception 'apenas_motoboy' using errcode = '42501'; end if;
  select * into c from public.corridas where id = p_corrida for update;
  if not found or c.motoboy_id is not null then raise exception 'rota_ja_pegada' using errcode = '22023'; end if;
  if c.teste <> v_teste then raise exception 'modo_teste_diferente' using errcode = '22023'; end if;
  if privado.cfg_bool('veiculo_obrigatorio', false) and not c.teste
     and (select veiculo_placa from public.motoboys where id = auth.uid()) is null then
    raise exception 'cadastre_o_veiculo' using errcode = '42501';
  end if;
  if c.status::text = 'agendada' then return public.reservar_corrida(p_corrida); end if;
  if not (c.status::text in ('aguardando_motoboy', 'sem_motoboy') and c.modo_despacho::text = 'quadro') then
    raise exception 'rota_ja_pegada' using errcode = '22023';
  end if;
  if not privado.pode_mais_rota(auth.uid()) then
    raise exception 'voce_ja_tem_corrida_ativa' using errcode = '22023';
  end if;
  update public.ofertas set status = 'cancelada' where corrida_id = p_corrida and status = 'pendente';
  update public.corridas set status = 'aceita', motoboy_id = auth.uid(), aceita_em = now() where id = p_corrida;
  update public.paradas set status = 'a_caminho'
   where corrida_id = p_corrida and ordem = (select min(ordem) from public.paradas where corrida_id = p_corrida);
  update public.motoboys set status = 'em_corrida', status_em = now() where id = auth.uid();
  perform privado.evento(p_corrida, 'aceita', jsonb_build_object('motoboy_id', auth.uid(), 'quadro', true, 'sugerida', c.sugerido_motoboy_id = auth.uid()));
  return privado.corrida_json(p_corrida);
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
  if p_aceitar and privado.motoboy_suspenso(auth.uid()) then raise exception 'motoboy_suspenso' using errcode = '42501'; end if;
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
              where motoboy_id = auth.uid() and status in ('aceita', 'em_andamento')) and (o.extensao or not privado.pode_mais_rota(auth.uid())) then
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

  elsif p_acao = 'iniciar_agora' then
    -- o gestor manda começar já: com motoboy reservado, vira corrida dele agora; sem ninguém, vai para o despacho
    perform privado.exigir_acao('forcar_inicio');
    if c.status::text = 'reservada' and c.motoboy_id is not null then
      update public.corridas set agendada_para = now() where id = p_corrida;
      perform privado.iniciar_reservada(p_corrida);
      perform privado.evento(p_corrida, 'planejada_iniciada', jsonb_build_object('pelo_gestor', true));
      perform privado.enviar_push(c.motoboy_id, jsonb_build_object('tipo', 'corrida_atribuida', 'corrida_id', p_corrida::text));
    else
      update public.corridas set status = 'aguardando_motoboy', agendada_para = now(), modo_despacho = 'cascata' where id = p_corrida;
      perform privado.evento(p_corrida, 'planejada_despachada', jsonb_build_object('pelo_gestor', true, 'agora', true));
      perform privado.despachar(p_corrida);
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
      'motoboy_pode_finalizar', privado.pol_bool('motoboy_pode_finalizar', false, null, p.id, null))
  )
  from public.perfis p
  left join public.motoboys m on m.id = p.id
  where p.id = auth.uid();
$$;
