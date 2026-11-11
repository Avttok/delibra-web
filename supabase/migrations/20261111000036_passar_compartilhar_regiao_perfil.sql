-- =====================================================================
-- Delibra · 0036: pacotes certos na coleta, passar corrida, motoboys compartilhados,
--                  quem conhece a região, perfil completo, rota compartilhada no chat,
--                  pings mais leves e nomes da empresa por lugar
--
--  • Coleta: mostra só os pacotes que vão para as entregas DESTA rota.
--  • Passar corrida: o gestor tira a rota de um motoboy e passa para outro (ou para o
--    sistema) enquanto nada foi coletado.
--  • Motoboys compartilhados: se o Dev deixar, o gestor escolhe com quem compartilha os
--    motoboys (todas as empresas, algumas ou nenhuma), no geral e por motoboy.
--  • Região: o sistema aprende onde cada motoboy entrega e passa tempo; no despacho, quem
--    conhece a região ganha vantagem (vale X metros a menos de distância).
--  • Perfil: página da pessoa com números, conquistas, veículo e bairros (cada parte com ajuste).
--  • Chat: o motoboy abre a rota/pedido compartilhado (mesmo em revisão) para dizer se pode.
--  • Pings: corridas antigas têm os pontos repetidos/colados afinados (sem perder o traçado).
--  • Veículo: o motoboy cadastra o próprio quando o ajuste (geral, da empresa ou dele) deixa.
--  • Nomes por lugar: entrada, notificações, site do cliente, documentos e atalho.
-- =====================================================================
set check_function_bodies = off;

create or replace function privado.corrida_json_completo(p_corrida uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', c.id, 'numero', c.numero, 'status', c.status, 'origem', c.origem,
    'agendada_para', c.agendada_para, 'reservada_em', c.reservada_em,
    'cancelar_reserva_ate', case when c.agendada_para is not null
      then c.agendada_para - make_interval(mins => privado.cfg_num('agendada_cancelar_ate_min', 60)::int) end,
    'iniciar_a_partir_de', case when c.agendada_para is not null
      then c.agendada_para - make_interval(mins => privado.cfg_num('agendada_iniciar_antes_min', 60)::int) end,
    'teste', c.teste, 'urgente', c.urgente, 'perigoso', c.tem_perigoso,
    'valor_motoboy', coalesce(c.valor_motoboy, (privado.calcular_pagamento(c.id, auth.uid()) ->> 'total')::numeric),
    'distancia_planejada_m', c.distancia_planejada_m, 'duracao_planejada_s', c.duracao_planejada_s,
    'observacoes', c.observacoes, 'exige_foto', c.exige_foto, 'exige_assinatura', c.exige_assinatura,
    'exige_nome', c.exige_nome, 'exige_codigo', c.exige_codigo, 'exigir_no_local', c.exigir_no_local,
    'raio_chegada_m', c.raio_chegada_m, 'rota_planejada', c.rota_planejada,
    'empresa_nome', coalesce(e.nome, c.cliente_nome),
    'entregas', (select count(*) from public.paradas p where p.corrida_id = c.id and p.tipo = 'entrega'),
    'coletas', (select count(*) from public.paradas p where p.corrida_id = c.id and p.tipo = 'coleta'),
    'paradas', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id, 'ordem', p.ordem, 'tipo', p.tipo, 'endereco', p.endereco,
        'lat', p.lat, 'lng', p.lng, 'contato_nome', p.contato_nome,
        'contato_telefone', p.contato_telefone, 'instrucoes', p.instrucoes, 'status', p.status,
        'referencias', p.referencias,
        'exige', privado.exige_parada(p, c), 'janela_de', to_char(p.janela_de, 'HH24:MI'), 'janela_ate', to_char(p.janela_ate, 'HH24:MI'),
        'cliente', (select coalesce(em.nome, pd.cliente_nome) from public.pedidos pd left join public.empresas em on em.id = pd.empresa_id where pd.id = p.pedido_id),
        'pedido_numero', (select pd.numero from public.pedidos pd where pd.id = p.pedido_id),
        'itens', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'descricao', i.descricao, 'quantidade', i.quantidade,
                    'categoria', k.nome, 'icone', k.icone, 'perigoso', coalesce(k.perigoso, false), 'fragil', coalesce(k.fragil, false),
                    'peso_kg', i.peso_kg, 'comprimento_cm', i.comprimento_cm, 'largura_cm', i.largura_cm, 'altura_cm', i.altura_cm,
                    'valor_declarado', i.valor_declarado, 'observacoes', i.observacoes,
                    -- true = não está preso a este ponto (vai para todas as entregas / sai de qualquer coleta)
                    'todas', case when p.tipo = 'entrega' then i.entrega_id is null else i.coleta_id is null end)), '[]')
                    from public.pedido_itens i left join public.categorias_produto k on k.id = i.categoria_id
                   where p.pedido_ponto_id is not null and i.pedido_id = p.pedido_id
                     and (case when p.tipo = 'entrega' then i.entrega_id = p.pedido_ponto_id or i.entrega_id is null
                               else (i.coleta_id = p.pedido_ponto_id or i.coleta_id is null)
                                    -- só o que vai para uma entrega desta rota
                                    and (i.entrega_id is null or exists (select 1 from public.paradas p2 where p2.corrida_id = c.id
                                         and p2.tipo = 'entrega' and p2.pedido_ponto_id = i.entrega_id)) end))
      ) order by p.ordem)
      from public.paradas p where p.corrida_id = c.id
    ), '[]'::jsonb)
  )
  from public.corridas c
  left join public.empresas e on e.id = c.empresa_id
  where c.id = p_corrida;
$$;

insert into public.configuracoes (chave, valor) values
  ('regiao_ligado', 'true'), ('regiao_bonus_m', '1500'), ('regiao_referencia', '10'), ('regiao_min_por_entrega', '20'), ('regiao_meia_vida_dias', '90'),
  ('ping_inteligente', 'true'), ('ping_curva_graus', '25'), ('ping_reta_max_m', '200'), ('ping_afinar_dias', '30'), ('ping_afinar_m', '15'),
  ('usuario_troca_senha', 'true'),
  ('perfil_publico_ligado', 'true'), ('perfil_mostra_numeros', 'true'), ('perfil_mostra_conquistas', 'true'), ('perfil_mostra_veiculo', 'true'), ('perfil_mostra_regioes', 'true'),
  ('chat_motoboy_abre_rota', 'true'), ('chat_rota_respostas', 'true'),
  ('jogo_ligado', 'true'), ('jogo_toques', '5'), ('app_lembrar_pagina', 'true'),
  ('passar_corrida_ligado', 'true'), ('passar_avisa_motoboy', 'true'),
  ('pedido_confirmar_revisao', 'true'),
  ('saas_gestor_compartilha_motoboys', 'false')
on conflict (chave) do nothing;

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
    if not privado.pol_bool('motoboy_edita_veiculo', false, null, v_id, null) then raise exception 'so_o_gestor_edita' using errcode = '42501'; end if;
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

create or replace function public.meu_veiculo()
returns jsonb language sql stable security definer set search_path = '' as $$
  select privado.veiculo_json(m) || jsonb_build_object('pode_editar', privado.pol_bool('motoboy_edita_veiculo', false, null, m.id, null))
    from public.motoboys m where m.id = auth.uid();
$$;

-- sem linha em motoboys ainda: devolve só se pode editar
create or replace function public.meu_veiculo()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select privado.veiculo_json(m) || jsonb_build_object('pode_editar', privado.pol_bool('motoboy_edita_veiculo', false, null, m.id, null))
       from public.motoboys m where m.id = auth.uid()),
    jsonb_build_object('pode_editar', privado.pol_bool('motoboy_edita_veiculo', false, null, auth.uid(), null)));
$$;

alter table public.organizacoes add column if not exists nomes jsonb not null default '{}'::jsonb;

-- só as chaves conhecidas, texto de 1 a 40
create or replace function privado.limpar_nomes(p jsonb)
returns jsonb language sql immutable set search_path = '' as $$
  select coalesce(jsonb_object_agg(k, left(trim(v #>> '{}'), 40)), '{}'::jsonb)
    from jsonb_each(case when jsonb_typeof(p) = 'object' then p else '{}'::jsonb end) e(k, v)
   where k in ('entrada', 'notificacoes', 'cliente', 'documentos', 'atalho', 'chat')
     and jsonb_typeof(v) = 'string' and length(trim(v #>> '{}')) > 0;
$$;

create or replace function public.marca_publica(p_slug text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('nome', o.nome, 'nome_app', o.nome_app, 'nome_topo', o.nome_topo, 'nomes', o.nomes, 'logo', o.logo_url, 'cor', o.cor, 'logo_escala', o.logo_escala,
                            'brilho_cor', o.logo_brilho_cor, 'brilho', o.logo_brilho, 'fonte', o.fonte_nome)
    from public.organizacoes o where o.slug = p_slug and o.status in ('ativa', 'teste');
$$;

create or replace function public.dev_marca_organizacao(p_org uuid, p jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  update public.organizacoes set
    logo_url = case when p ? 'logo_url' then nullif(p ->> 'logo_url', '') else logo_url end,
    logo_original_url = case when p ? 'logo_original_url' then nullif(p ->> 'logo_original_url', '') else logo_original_url end,
    logo_brilho_cor = case when p ? 'brilho_cor' then nullif(p ->> 'brilho_cor', '') else logo_brilho_cor end,
    logo_brilho = case when p ? 'brilho' then least(greatest((p ->> 'brilho')::numeric, 0), 1) else logo_brilho end,
    logo_escala = case when p ? 'logo_escala' then least(greatest((p ->> 'logo_escala')::numeric, 0.8), 2.6) else logo_escala end,
    fonte_nome = case when p ? 'fonte' then nullif(p ->> 'fonte', '') else fonte_nome end,
    nome_app = case when p ? 'nome_app' then nullif(trim(p ->> 'nome_app'), '') else nome_app end,
    nome_topo = case when p ? 'nome_topo' then nullif(trim(p ->> 'nome_topo'), '') else nome_topo end,
    nomes = case when p ? 'nomes' then privado.limpar_nomes(p -> 'nomes') else nomes end
  where id = p_org;
end;
$$;

create or replace function public.salvar_minha_organizacao(p jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_gestor_pleno() or public.minha_org() is null then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  update public.organizacoes set
    nome      = coalesce(nullif(trim(p ->> 'nome'), ''), nome),
    documento = case when p ? 'documento' then nullif(regexp_replace(p ->> 'documento', '\D', '', 'g'), '') else documento end,
    logo_url  = case when p ? 'logo_url' then nullif(p ->> 'logo_url', '') else logo_url end,
    cor       = case when p ? 'cor' then nullif(p ->> 'cor', '') else cor end,
    nome_app  = case when p ? 'nome_app' then nullif(trim(p ->> 'nome_app'), '') else nome_app end,
    nome_topo = case when p ? 'nome_topo' then nullif(trim(p ->> 'nome_topo'), '') else nome_topo end,
    nomes = case when p ? 'nomes' then privado.limpar_nomes(p -> 'nomes') else nomes end,
    logo_original_url = case when p ? 'logo_original_url' then nullif(p ->> 'logo_original_url', '') else logo_original_url end,
    logo_brilho_cor = case when p ? 'brilho_cor' then nullif(p ->> 'brilho_cor', '') else logo_brilho_cor end,
    logo_brilho = case when p ? 'brilho' then least(greatest((p ->> 'brilho')::numeric, 0), 1) else logo_brilho end,
    fonte_nome = case when p ? 'fonte' then nullif(p ->> 'fonte', '') else fonte_nome end,
    logo_escala = case when p ? 'logo_escala' then least(greatest((p ->> 'logo_escala')::numeric, 0.8), 2.6) else logo_escala end
   where id = public.minha_org();
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
    'cor_tema', p.cor_tema,
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
                       'app_lembrar_pagina', 'passar_corrida_ligado', 'pedido_confirmar_revisao')
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
      'jogo_toques', privado.pol_num('jogo_toques', 5, null, p.id, null))
  )
  from public.perfis p
  left join public.motoboys m on m.id = p.id
  where p.id = auth.uid();
$$;

create or replace function public.passar_corrida(p_corrida uuid, p_motoboy uuid default null, p_motivo text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c public.corridas%rowtype; v_antigo uuid;
begin
  if not public.is_gestor() or not public.pode('pedidos') then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if not public.ve_corrida(p_corrida) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if p_motoboy is not null and not public.ve_pessoa(p_motoboy) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  select * into c from public.corridas where id = p_corrida for update;
  if not privado.cfg_org_bool(c.organizacao_id, 'passar_corrida_ligado', true) then raise exception 'passar_desligado' using errcode = '42501'; end if;
  if c.motoboy_id is null or c.status::text not in ('aceita', 'em_andamento', 'reservada') then raise exception 'corrida_sem_motoboy' using errcode = '22023'; end if;
  if p_motoboy = c.motoboy_id then raise exception 'mesmo_motoboy' using errcode = '22023'; end if;
  if exists (select 1 from public.paradas where corrida_id = p_corrida and tipo = 'coleta' and status::text = 'concluida') then
    raise exception 'ja_coletou' using errcode = '22023';
  end if;
  if p_motoboy is not null and not exists (select 1 from public.motoboys where id = p_motoboy and modo_teste = c.teste) then
    raise exception '%', case when c.teste then 'motoboy_fora_do_modo_teste' else 'motoboy_em_modo_teste' end using errcode = '22023';
  end if;
  if p_motoboy is not null and privado.motoboy_suspenso(p_motoboy) then raise exception 'motoboy_suspenso' using errcode = '42501'; end if;
  v_antigo := c.motoboy_id;
  update public.motoboys set status = 'disponivel', status_em = now() where id = v_antigo and status = 'em_corrida'
     and not exists (select 1 from public.corridas k where k.motoboy_id = v_antigo and k.id <> p_corrida and k.status::text in ('aceita', 'em_andamento'));
  update public.ofertas set status = 'cancelada' where corrida_id = p_corrida and status::text in ('pendente', 'aceita');
  update public.chamados_corrida set status = 'retirado', respondido_em = now() where corrida_id = p_corrida and status = 'pendente';
  update public.corridas set motoboy_id = null, aceita_em = null, iniciada_em = null, reservada_em = null,
         rodada = rodada + 1, motoboy_designado_id = p_motoboy,
         modo_despacho = case when p_motoboy is null then 'cascata' else 'direto' end::public.modo_despacho,
         status = 'aguardando_motoboy'
   where id = p_corrida;
  perform privado.evento(p_corrida, 'passada', jsonb_build_object('de', v_antigo, 'para', p_motoboy, 'motivo', nullif(trim(coalesce(p_motivo, '')), '')));
  if privado.cfg_org_bool(c.organizacao_id, 'passar_avisa_motoboy', true) then
    begin
      perform privado.enviar_push(v_antigo, jsonb_build_object('tipo', 'corrida_passada', 'corrida_id', p_corrida::text,
        'titulo', 'Rota passada para outro motoboy',
        'texto', coalesce('O gestor tirou a rota ' || case when c.teste then 'T' else '#' end || c.numero || ' de você' ||
                          coalesce(': ' || nullif(trim(p_motivo), ''), '.'), 'O gestor tirou esta rota de você.')));
    exception when others then null;
    end;
  end if;
  perform privado.despachar(p_corrida);
  return jsonb_build_object('ok', true, 'status', (select status from public.corridas where id = p_corrida));
end;
$$;

alter table public.organizacoes add column if not exists motoboys_para text not null default 'padrao';
alter table public.organizacoes drop constraint if exists organizacoes_motoboys_para_check;
alter table public.organizacoes add constraint organizacoes_motoboys_para_check check (motoboys_para in ('padrao', 'nenhuma', 'todas', 'escolhidas'));
alter table public.organizacoes add column if not exists motoboys_para_orgs uuid[] not null default '{}';
alter table public.motoboys add column if not exists compartilhar text not null default 'empresa';
alter table public.motoboys drop constraint if exists motoboys_compartilhar_check;
alter table public.motoboys add constraint motoboys_compartilhar_check check (compartilhar in ('empresa', 'nunca', 'todas', 'escolhidas'));
alter table public.motoboys add column if not exists compartilhar_orgs uuid[] not null default '{}';

-- O motoboy aceita rotas da empresa p_origem? (escolha dele > da empresa dele > o que o Dev definiu)
create or replace function privado.motoboy_aceita(p_motoboy uuid, p_origem uuid, out aceita boolean, out explicito boolean)
language plpgsql stable security definer set search_path = '' as $$
declare m public.motoboys%rowtype; d public.organizacoes%rowtype;
begin
  select * into m from public.motoboys where id = p_motoboy;
  select o.* into d from public.organizacoes o join public.perfis p on p.organizacao_id = o.id where p.id = p_motoboy;
  aceita := coalesce(d.receber_de_outras, false); explicito := false;
  if d.id is null or not privado.cfg_bool('saas_gestor_compartilha_motoboys', false) then return; end if;
  if m.compartilhar = 'nunca' then aceita := false; explicito := true;
  elsif m.compartilhar = 'todas' then aceita := true; explicito := true;
  elsif m.compartilhar = 'escolhidas' then aceita := p_origem = any (m.compartilhar_orgs); explicito := true;
  elsif d.motoboys_para = 'nenhuma' then aceita := false; explicito := true;
  elsif d.motoboys_para = 'todas' then aceita := true; explicito := true;
  elsif d.motoboys_para = 'escolhidas' then aceita := p_origem = any (d.motoboys_para_orgs); explicito := true;
  end if;
end;
$$;

-- Uma rota da empresa p_origem pode chegar a este motoboy?
create or replace function public.motoboy_alcanca(p_origem uuid, p_motoboy uuid, p_desde timestamptz default null)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare o public.organizacoes%rowtype; v_dest uuid; v_ac boolean; v_exp boolean;
begin
  select organizacao_id into v_dest from public.perfis where id = p_motoboy;
  if p_origem is null or v_dest is null or p_origem = v_dest then return true; end if;
  if not privado.cfg_bool('saas_compartilhar_corridas', true) then return false; end if;
  select * into o from public.organizacoes where id = p_origem;
  if o.id is null or exists (select 1 from public.organizacoes where id = v_dest and status in ('suspensa', 'cancelada')) then return false; end if;
  select aceita, explicito into v_ac, v_exp from privado.motoboy_aceita(p_motoboy, p_origem);
  if not coalesce(v_ac, false) then return false; end if;
  -- compartilhado de propósito pela empresa do motoboy: chega (respeitando a espera do "sem motoboy livre")
  if v_exp then
    return o.compartilhar <> 'sem_livre' or p_desde is null or p_desde < now() - make_interval(mins => o.compartilhar_apos_min);
  end if;
  return case o.compartilhar
    when 'sempre' then true
    when 'parceiros' then v_dest = any (o.parceiros)
    when 'sem_livre' then p_desde is null or p_desde < now() - make_interval(mins => o.compartilhar_apos_min)
    else false end;
end;
$$;
grant execute on function public.motoboy_alcanca(uuid, uuid, timestamptz) to authenticated;
revoke execute on function privado.motoboy_aceita(uuid, uuid) from public, anon, authenticated;

-- Tela do gestor: com quem compartilho meus motoboys
create or replace function public.compartilhamento_motoboys()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare o public.organizacoes%rowtype;
begin
  if not public.is_gestor_pleno() or public.minha_org() is null then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select * into o from public.organizacoes where id = public.minha_org();
  return jsonb_build_object(
    'permitido', privado.cfg_bool('saas_gestor_compartilha_motoboys', false) and privado.cfg_bool('saas_compartilhar_corridas', true),
    'modo', o.motoboys_para, 'orgs', to_jsonb(o.motoboys_para_orgs), 'padrao_dev', o.receber_de_outras,
    'empresas', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'nome', coalesce(x.nome_app, x.nome)) order by x.nome)
                            from public.organizacoes x where x.id <> o.id and x.status not in ('suspensa', 'cancelada')), '[]'),
    'motoboys', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'nome', p.nome, 'foto', p.foto_url, 'modo', coalesce(m.compartilhar, 'empresa'),
                                                              'orgs', to_jsonb(coalesce(m.compartilhar_orgs, '{}'))) order by p.nome)
                            from public.perfis p left join public.motoboys m on m.id = p.id
                           where p.organizacao_id = o.id and 'motoboy' = any (p.papeis)), '[]'));
end;
$$;

create or replace function public.salvar_compartilhamento_motoboys(p_modo text, p_orgs uuid[] default '{}', p_motoboy uuid default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_gestor_pleno() or public.minha_org() is null then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if not privado.cfg_bool('saas_gestor_compartilha_motoboys', false) then raise exception 'compartilhar_desligado' using errcode = '42501'; end if;
  -- só empresas que existem (e nunca a própria)
  p_orgs := coalesce((select array_agg(x.id) from public.organizacoes x where x.id = any (coalesce(p_orgs, '{}')) and x.id <> public.minha_org()), '{}');
  if p_motoboy is null then
    if p_modo not in ('padrao', 'nenhuma', 'todas', 'escolhidas') then raise exception 'modo_invalido' using errcode = '22023'; end if;
    update public.organizacoes set motoboys_para = p_modo, motoboys_para_orgs = p_orgs where id = public.minha_org();
  else
    if p_modo not in ('empresa', 'nunca', 'todas', 'escolhidas') then raise exception 'modo_invalido' using errcode = '22023'; end if;
    if not exists (select 1 from public.perfis where id = p_motoboy and organizacao_id = public.minha_org() and 'motoboy' = any (papeis)) then
      raise exception 'sem_permissao' using errcode = '42501';
    end if;
    insert into public.motoboys (id) values (p_motoboy) on conflict (id) do nothing;
    update public.motoboys set compartilhar = p_modo, compartilhar_orgs = p_orgs where id = p_motoboy;
  end if;
end;
$$;

create or replace function privado.celula(p_lat double precision, p_lng double precision)
returns text language sql immutable set search_path = '' as $$
  select floor(p_lat * 100)::int || ':' || floor(p_lng * 100)::int;
$$;

create table if not exists privado.motoboy_regioes (
  motoboy_id    uuid not null references public.motoboys (id) on delete cascade,
  celula        text not null,
  entregas      numeric not null default 0,
  minutos       numeric not null default 0,
  atualizado_em timestamptz not null default now(),
  primary key (motoboy_id, celula)
);
create table if not exists privado.regioes_estado (id int primary key default 1 check (id = 1), ate timestamptz not null);

-- Parada concluída conta como experiência naquela área
create or replace function privado.aprender_regiao_parada()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_mb uuid; v_teste boolean;
begin
  if new.status::text <> 'concluida' or old.status::text = 'concluida' or new.lat is null then return new; end if;
  select motoboy_id, teste into v_mb, v_teste from public.corridas where id = new.corrida_id;
  if v_mb is null or v_teste then return new; end if;
  insert into privado.motoboy_regioes (motoboy_id, celula, entregas) values (v_mb, privado.celula(new.lat, new.lng), case when new.tipo = 'entrega' then 1 else 0.5 end)
  on conflict (motoboy_id, celula) do update set entregas = privado.motoboy_regioes.entregas + excluded.entregas, atualizado_em = now();
  return new;
exception when others then return new;
end;
$$;
drop trigger if exists paradas_aprender_regiao on public.paradas;
create trigger paradas_aprender_regiao after update of status on public.paradas
  for each row execute function privado.aprender_regiao_parada();

-- Tempo que cada um passa em cada área (minutos com GPS fora do offline) + esquecer devagar
create or replace function privado.aprender_regioes()
returns int language plpgsql security definer set search_path = '' as $$
declare v_de timestamptz; v_ate timestamptz := now() - interval '2 minutes'; v_n int; v_fator numeric;
begin
  select ate into v_de from privado.regioes_estado where id = 1;
  v_de := coalesce(v_de, now() - interval '90 days');
  if v_ate <= v_de then return 0; end if;
  insert into privado.motoboy_regioes (motoboy_id, celula, minutos)
  select l.motoboy_id, privado.celula(l.lat, l.lng), count(distinct date_trunc('minute', l.registrado_em))
    from public.localizacoes l
   where l.registrado_em >= v_de and l.registrado_em < v_ate and l.status::text <> 'offline'
     and not coalesce(l.simulada, false) and not coalesce(l.teste, false)
     and exists (select 1 from public.motoboys m where m.id = l.motoboy_id)
   group by 1, 2
  on conflict (motoboy_id, celula) do update set minutos = privado.motoboy_regioes.minutos + excluded.minutos, atualizado_em = now();
  get diagnostics v_n = row_count;
  -- meia-vida: o que ele fazia há muito tempo pesa menos
  v_fator := power(0.5, extract(epoch from (v_ate - v_de)) / 86400.0 / greatest(privado.cfg_num('regiao_meia_vida_dias', 90), 1));
  update privado.motoboy_regioes set entregas = entregas * v_fator, minutos = minutos * v_fator where v_fator < 0.9999;
  delete from privado.motoboy_regioes where entregas < 0.05 and minutos < 1;
  insert into privado.regioes_estado (id, ate) values (1, v_ate) on conflict (id) do update set ate = excluded.ate;
  return v_n;
end;
$$;

-- Vantagem (em metros) de quem conhece as paradas desta rota. 0 = desligado ou não conhece.
create or replace function privado.bonus_regiao(p_motoboy uuid, p_corrida uuid)
returns double precision language sql stable security definer set search_path = '' as $$
  with c as (select organizacao_id org from public.corridas where id = p_corrida),
  k as (select privado.cfg_org_bool(c.org, 'regiao_ligado', true) lig, privado.cfg_org_num(c.org, 'regiao_bonus_m', 1500) bonus,
               greatest(privado.cfg_org_num(c.org, 'regiao_referencia', 10), 1) ref, greatest(privado.cfg_org_num(c.org, 'regiao_min_por_entrega', 20), 1) mpe from c)
  select case when not (select lig from k) or (select bonus from k) <= 0 then 0::double precision else
    (select bonus from k) * coalesce((
      select avg(least(1, (coalesce(r.entregas, 0) + coalesce(r.minutos, 0) / (select mpe from k)) / (select ref from k)))
        from public.paradas pa
        left join privado.motoboy_regioes r on r.motoboy_id = p_motoboy and r.celula = privado.celula(pa.lat, pa.lng)
       where pa.corrida_id = p_corrida and pa.lat is not null), 0)::double precision end;
$$;
revoke execute on function privado.aprender_regioes(), privado.bonus_regiao(uuid, uuid), privado.aprender_regiao_parada() from public, anon, authenticated;

-- começa com o que já aconteceu
insert into privado.motoboy_regioes (motoboy_id, celula, entregas)
select c.motoboy_id, privado.celula(pa.lat, pa.lng), sum(case when pa.tipo = 'entrega' then 1 else 0.5 end)
  from public.paradas pa join public.corridas c on c.id = pa.corrida_id
 where pa.status::text = 'concluida' and c.motoboy_id is not null and not c.teste and pa.lat is not null
   and exists (select 1 from public.motoboys m where m.id = c.motoboy_id)
 group by 1, 2
on conflict (motoboy_id, celula) do nothing;
select privado.aprender_regioes();

-- O que o gestor vê: onde o motoboy mais trabalha (bairros) e o peso no despacho
create or replace function public.regioes_do_motoboy(p_motoboy uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.ve_pessoa(p_motoboy) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if p_motoboy <> auth.uid() and not public.is_gestor() and not privado.pol_bool('perfil_mostra_regioes', true, null, p_motoboy, null) then
    return '[]'::jsonb;
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('bairro', b, 'paradas', n) order by n desc) from (
      select nullif(trim(split_part(pa.endereco, ',', case when array_length(string_to_array(pa.endereco, ','), 1) >= 4 then 3 else 2 end)), '') b, count(*) n
        from public.paradas pa join public.corridas c on c.id = pa.corrida_id
       where c.motoboy_id = p_motoboy and pa.status::text = 'concluida' and not c.teste and pa.tipo = 'entrega'
         and coalesce(pa.concluida_em, c.concluida_em) > now() - interval '180 days'
       group by 1 having nullif(trim(split_part(pa.endereco, ',', case when array_length(string_to_array(pa.endereco, ','), 1) >= 4 then 3 else 2 end)), '') is not null
       order by 2 desc limit 5) z), '[]'::jsonb);
end;
$$;

create or replace function public.ve_corrida(p_corrida uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.corridas c where c.id = p_corrida and (
       public.ve_org(c.organizacao_id)
    or c.motoboy_id = auth.uid() or c.motoboy_designado_id = auth.uid()
    or exists (select 1 from public.ofertas o where o.corrida_id = c.id and o.motoboy_id = auth.uid())
    or (c.status in ('aguardando_motoboy', 'sem_motoboy') and c.modo_despacho::text = 'quadro'
        and exists (select 1 from public.perfis p where p.id = auth.uid() and 'motoboy' = any (p.papeis))
        and public.motoboy_alcanca(c.organizacao_id, auth.uid(), c.quadro_desde))));
$$;

create or replace function public.rotas_disponiveis()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  m  public.motoboys%rowtype;
begin
  perform privado.checar_versao_app();
  if not public.tem_papel('motoboy'::public.papel_usuario) then raise exception 'apenas_motoboy' using errcode = '42501'; end if;
  select * into m from public.motoboys where id = auth.uid();
  if privado.motoboy_suspenso(auth.uid()) then return '[]'::jsonb; end if;
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
       and public.motoboy_alcanca(c.organizacao_id, auth.uid(), c.quadro_desde)
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
       and (c.motoboy_id = auth.uid() or public.motoboy_alcanca(c.organizacao_id, auth.uid(), c.quadro_desde))
       and ((c.status::text = 'agendada' and c.agendada_para > now())
            or (c.status::text = 'reservada' and c.motoboy_id = auth.uid()))
  ), '[]'::jsonb);
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
  v_emc        text;
  v_ext_raio   numeric;
  v_ext_max    int;
  v_nent       int;
  v_max        int;
  v_ext        boolean := false;
begin
  select * into c from public.corridas where id = p_corrida for update;
  if not found or c.status not in ('aguardando_motoboy', 'sem_motoboy') then return; end if;
  perform set_config('pwex.org', coalesce(c.organizacao_id::text, ''), true);
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
       and not privado.motoboy_suspenso(m.id)
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
       and public.motoboy_alcanca(c.organizacao_id, m.id, null)
     -- primeiro os da própria empresa; os de outras só se o Dev liberou (e, em "sem motoboy livre", só se faltar)
     order by ((select p.organizacao_id from public.perfis p where p.id = m.id) is distinct from c.organizacao_id), (f.ordem is null), f.ordem, (v_emc = 'depois' and m.status <> 'disponivel'), extensions.st_distance(m.posicao, v_coleta) - privado.bonus_regiao(m.id, p_corrida)
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

create or replace function privado.melhor_motoboy(p_corrida uuid)
returns uuid language sql stable security definer set search_path = '' as $$
  select m.id
    from public.corridas c
    join lateral (select lat, lng from public.paradas where corrida_id = c.id order by ordem limit 1) col on true
    join public.motoboys m on m.status = 'disponivel' and m.modo_teste = c.teste and m.lat is not null
    left join public.empresa_favoritos f on f.motoboy_id = m.id and f.empresa_id = c.empresa_id
   where c.id = p_corrida
     and m.posicao_em > now() - make_interval(mins => privado.cfg_num('posicao_max_min', 15)::int)
     and not exists (select 1 from auth.users u where u.id = m.id and u.banned_until > now())
     and (c.urgente or coalesce(m.raio_km, 0) <= 0 or privado.dist_m(
            case when m.raio_modo = 'fixo' and m.raio_lat is not null then m.raio_lat else m.lat end,
            case when m.raio_modo = 'fixo' and m.raio_lng is not null then m.raio_lng else m.lng end, col.lat, col.lng) <= m.raio_km * 1000)
     and public.motoboy_alcanca(c.organizacao_id, m.id, null)
   order by ((select p.organizacao_id from public.perfis p where p.id = m.id) is distinct from c.organizacao_id), (f.ordem is null), f.ordem, privado.dist_m(m.lat, m.lng, col.lat, col.lng) - privado.bonus_regiao(m.id, c.id)
   limit 1;
$$;

create or replace function privado.conquistas_sem_guarda(p_motoboy uuid default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_id    uuid := coalesce(p_motoboy, auth.uid());
  v_teste boolean;
  v_cri   timestamptz;
  m       public.motoboys%rowtype;
  r       jsonb;
begin
  if v_id is null then raise exception 'sem_login' using errcode = '42501'; end if;
  select modo_teste, criado_em into v_teste, v_cri from public.perfis where id = v_id;
  select * into m from public.motoboys where id = v_id;
  v_teste := coalesce(v_teste, false);

  with c as (
    select k.*, (k.concluida_em at time zone 'America/Sao_Paulo') local
      from public.corridas k
     where k.motoboy_id = v_id and k.status::text = 'concluida' and k.teste = v_teste
  ), dias as (
    select distinct local::date d from c
  ), seq as (
    select count(*) n from (select d, d - (row_number() over (order by d))::int grp from dias) z group by grp
  ), ent as (
    select x.* from public.paradas x join c on c.id = x.corrida_id where x.status::text = 'concluida'
  )
  select jsonb_build_object(
    'corridas',      (select count(*) from c),
    'entregas',      (select count(*) from ent where tipo = 'entrega'),
    'coletas',       (select count(*) from ent where tipo = 'coleta'),
    'km',            round(coalesce((select sum(coalesce(distancia_real_m, distancia_planejada_m, 0)) from c), 0) / 1000.0, 1),
    'horas_online',  round((coalesce(m.online_segundos, 0)
                            + case when m.status::text <> 'offline' and m.online_desde is not null then extract(epoch from now() - m.online_desde) else 0 end) / 3600.0, 1),
    'dias_conta',    greatest(0, (now()::date - coalesce(v_cri, now())::date)),
    'noturnas',      (select count(*) from c where extract(hour from local) >= 22 or extract(hour from local) < 5),
    'madrugada',     (select count(*) from c where extract(hour from local) < 5),
    'cedinho',       (select count(*) from c where extract(hour from local) >= 5 and extract(hour from local) < 8),
    'fim_de_semana', (select count(*) from c where extract(isodow from local) in (6, 7)),
    'urgentes',      (select count(*) from c where urgente),
    'planejadas',    (select count(*) from c where agendada_para is not null),
    'perigosas',     (select count(*) from c where tem_perigoso),
    'clientes',      (select count(distinct coalesce(empresa_id::text, cliente_nome)) from c),
    'dias_ativos',   (select count(*) from dias),
    'sequencia',     coalesce((select max(n) from seq), 0),
    'melhor_dia',    coalesce((select max(n) from (select count(*) n from c group by local::date) z), 0),
    'maior_rota',    coalesce((select max(n) from (select count(*) n from ent where tipo = 'entrega' group by corrida_id) z), 0),
    'maior_km',      round(coalesce((select max(coalesce(distancia_real_m, distancia_planejada_m, 0)) from c), 0) / 1000.0, 1),
    'comprovantes',  (select count(*) from ent where foto_path is not null or assinatura_path is not null),
    'ganhos',        round(coalesce((select sum(valor_motoboy) from c), 0), 2),
    'teste',         v_teste,
    'manuais',       coalesce((select jsonb_object_agg(chave, ganha) from public.conquistas_manuais where perfil_id = v_id), '{}'::jsonb)
  ) into r;
  return r;
end;
$$;

create or replace function public.conquistas(p_motoboy uuid default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if p_motoboy is not null and p_motoboy <> auth.uid() then
    if not public.ve_pessoa(p_motoboy) then raise exception 'sem_permissao' using errcode = '42501'; end if;
    if not public.is_gestor() and not (privado.pol_bool('perfil_publico_ligado', true, null, p_motoboy, null)
                                       and privado.pol_bool('perfil_mostra_conquistas', true, null, p_motoboy, null)) then
      raise exception 'apenas_gestor' using errcode = '42501';
    end if;
  end if;
  return privado.conquistas_sem_guarda(coalesce(p_motoboy, auth.uid()));
end;
$$;
revoke execute on function privado.conquistas_sem_guarda(uuid) from public, anon, authenticated;

create or replace function public.perfil_publico(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  pf public.perfis%rowtype; m public.motoboys%rowtype;
  v_eu boolean := p_id = auth.uid();
  v_ges boolean := public.is_gestor();
  v_tudo boolean;
  v jsonb;
begin
  if auth.uid() is null then raise exception 'nao_autenticado' using errcode = '28000'; end if;
  if not public.ve_pessoa(p_id) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  select * into pf from public.perfis where id = p_id;
  if not found then raise exception 'nao_encontrado' using errcode = '22023'; end if;
  select * into m from public.motoboys where id = p_id;
  v_tudo := v_eu or v_ges;
  if not v_tudo and not privado.pol_bool('perfil_publico_ligado', true, null, p_id, null) then
    return jsonb_build_object('id', p_id, 'nome', public.nome_publico(p_id), 'foto', public.foto_publica(p_id), 'fechado', true);
  end if;
  v := jsonb_build_object(
    'id', p_id, 'nome', public.nome_publico(p_id), 'foto', public.foto_publica(p_id), 'oculto', public.dev_oculto_para_mim(p_id),
    'cargo', case when 'dev' = any (pf.papeis) then 'dev' when 'gestor' = any (pf.papeis) then 'gestor' when 'supervisor' = any (pf.papeis) then 'supervisor'
                  when 'motoboy' = any (pf.papeis) then 'motoboy' else 'cliente' end,
    'motoboy', 'motoboy' = any (pf.papeis), 'eu', v_eu,
    'cor_tema', pf.cor_tema, 'icone', pf.icone, 'desde', pf.criado_em,
    'status', m.status, 'status_em', m.status_em,
    'empresa', (select coalesce(o.nome_app, o.nome) from public.organizacoes o where o.id = pf.organizacao_id));
  if 'motoboy' = any (pf.papeis) then
    if v_tudo or privado.pol_bool('perfil_mostra_numeros', true, null, p_id, null) or privado.pol_bool('perfil_mostra_conquistas', true, null, p_id, null) then
      v := v || jsonb_build_object('numeros', privado.conquistas_sem_guarda(p_id),
                                   'mostra_numeros', v_tudo or privado.pol_bool('perfil_mostra_numeros', true, null, p_id, null),
                                   'mostra_conquistas', v_tudo or privado.pol_bool('perfil_mostra_conquistas', true, null, p_id, null));
    end if;
    if m.id is not null and (v_tudo or privado.pol_bool('perfil_mostra_veiculo', true, null, p_id, null)) then
      v := v || jsonb_build_object('veiculo', jsonb_build_object('tipo', m.veiculo_tipo, 'modelo', m.veiculo_modelo, 'cor', m.veiculo_cor, 'ano', m.veiculo_ano,
                                                                'placa', case when v_tudo then m.veiculo_placa end));
    end if;
    if v_tudo or privado.pol_bool('perfil_mostra_regioes', true, null, p_id, null) then
      v := v || jsonb_build_object('regioes', public.regioes_do_motoboy(p_id));
    end if;
    if v_ges and not v_eu then
      v := v || jsonb_build_object('penalidade_pontos', privado.pontos_penalidade('motoboy', p_id, pf.organizacao_id),
                                   'suspenso_ate', case when m.suspenso_ate > now() then m.suspenso_ate end);
    end if;
  end if;
  return v;
end;
$$;

create or replace function privado.compartilhado_comigo(p_tipo text, p_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.chat_mensagens cm join public.chat_membros mb on mb.conversa_id = cm.conversa_id and mb.usuario_id = auth.uid()
                  where cm.apagada_em is null and cm.anexo ->> 'tipo' = p_tipo and cm.anexo ->> 'id' = p_id::text)
      or exists (select 1 from public.chat_mensagens cm join public.chat_conversas cv on cv.id = cm.conversa_id and cv.tipo = 'geral'
                  where cm.apagada_em is null and cm.anexo ->> 'tipo' = p_tipo and cm.anexo ->> 'id' = p_id::text);
$$;
revoke execute on function privado.compartilhado_comigo(text, uuid) from public, anon, authenticated;

-- O motoboy abre a rota que mandaram no chat (mesmo em revisão) para ver se pode fazer.
create or replace function public.rota_compartilhada(p_corrida uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare c public.corridas%rowtype; v jsonb;
begin
  if auth.uid() is null then raise exception 'nao_autenticado' using errcode = '28000'; end if;
  select * into c from public.corridas where id = p_corrida;
  if not found then raise exception 'nao_encontrado' using errcode = '22023'; end if;
  if not public.ve_corrida(p_corrida) and not (public.ve_org(c.organizacao_id) or privado.compartilhado_comigo('rota', p_corrida)) then
    raise exception 'sem_permissao' using errcode = '42501';
  end if;
  if not public.is_gestor() then
    if not privado.cfg_org_bool(c.organizacao_id, 'chat_motoboy_abre_rota', true) then raise exception 'rota_compartilhada_desligada' using errcode = '42501'; end if;
    if not privado.compartilhado_comigo('rota', p_corrida) and c.motoboy_id is distinct from auth.uid() then raise exception 'sem_permissao' using errcode = '42501'; end if;
  end if;
  v := privado.corrida_json(p_corrida);
  return v || jsonb_build_object('compartilhada', true, 'pode_pegar', c.status::text in ('aguardando_motoboy', 'sem_motoboy', 'agendada') and c.motoboy_id is null,
                                 'em_revisao', c.status::text = 'montada', 'minha', c.motoboy_id = auth.uid(),
                                 'respostas', privado.cfg_org_bool(c.organizacao_id, 'chat_rota_respostas', true));
end;
$$;

create or replace function public.pedido_compartilhado(p_pedido uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare p public.pedidos%rowtype;
begin
  if auth.uid() is null then raise exception 'nao_autenticado' using errcode = '28000'; end if;
  select * into p from public.pedidos where id = p_pedido;
  if not found then raise exception 'nao_encontrado' using errcode = '22023'; end if;
  if not public.is_gestor() then
    if not public.ve_org(p.organizacao_id) or not privado.compartilhado_comigo('pedido', p_pedido) then raise exception 'sem_permissao' using errcode = '42501'; end if;
    if not privado.cfg_org_bool(p.organizacao_id, 'chat_motoboy_abre_rota', true) then raise exception 'rota_compartilhada_desligada' using errcode = '42501'; end if;
  elsif not public.ve_org(p.organizacao_id) then raise exception 'sem_permissao' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'id', p.id, 'numero', p.numero, 'status', p.status, 'quando', p.quando, 'urgente', p.urgente,
    'cliente', coalesce((select nome from public.empresas where id = p.empresa_id), p.cliente_nome),
    'respostas', privado.cfg_org_bool(p.organizacao_id, 'chat_rota_respostas', true),
    'rotas', coalesce((select jsonb_agg(privado.corrida_json(c.id) || jsonb_build_object('em_revisao', c.status::text = 'montada') order by c.numero)
                         from public.corridas c where c.id in (select distinct corrida_id from public.paradas where pedido_id = p.id)
                          and c.status::text <> 'cancelada'), '[]'),
    'pontos', coalesce((select jsonb_agg(jsonb_build_object('tipo', x.tipo, 'endereco', x.endereco, 'lat', x.lat, 'lng', x.lng) order by x.ordem)
                          from public.pedido_pontos x where x.pedido_id = p.id), '[]'));
end;
$$;

alter table public.corridas add column if not exists pings_afinados_em timestamptz;

-- Tira pontos colados (menos de X m do último mantido) de corridas encerradas há mais de N dias.
-- Mantém o primeiro, o último, paradas longas (>= 3 min) e curvas (mudança de direção).
create or replace function privado.afinar_pings(p_limite int default 40)
returns int language plpgsql security definer set search_path = '' as $$
declare
  v_dias numeric := privado.cfg_num('ping_afinar_dias', 30);
  v_m    double precision := privado.cfg_num('ping_afinar_m', 15);
  k record; l record; v_tirar bigint[]; v_n int := 0;
  u_lat double precision; u_lng double precision; u_t timestamptz; u_dir double precision; v_ult bigint; v_ult_ok boolean;
  v_dir double precision; v_d double precision;
begin
  if v_dias <= 0 or v_m <= 0 then return 0; end if;
  for k in select c.id from public.corridas c
            where c.pings_afinados_em is null and c.status::text in ('concluida', 'cancelada')
              and coalesce(c.concluida_em, c.cancelada_em) < now() - make_interval(days => v_dias::int)
            order by coalesce(c.concluida_em, c.cancelada_em) limit p_limite loop
    v_tirar := '{}'; u_lat := null; v_ult := null;
    for l in select id, lat, lng, registrado_em from public.localizacoes where corrida_id = k.id order by registrado_em loop
      if u_lat is null then
        u_lat := l.lat; u_lng := l.lng; u_t := l.registrado_em; u_dir := null; v_ult := null; continue;
      end if;
      v_d := privado.dist_m(u_lat, u_lng, l.lat, l.lng);
      v_dir := degrees(atan2(l.lng - u_lng, l.lat - u_lat));
      if v_d >= v_m or l.registrado_em - u_t >= interval '3 minutes'
         or (u_dir is not null and v_d >= 5 and abs(((v_dir - u_dir + 540)::numeric % 360) - 180) >= 35) then
        u_dir := case when v_d >= 5 then v_dir else u_dir end;
        u_lat := l.lat; u_lng := l.lng; u_t := l.registrado_em;
        v_ult := null;
      else
        -- candidato a sair; o último da corrida fica (tratado depois)
        v_tirar := v_tirar || l.id; v_ult := l.id;
      end if;
    end loop;
    if v_ult is not null then v_tirar := array_remove(v_tirar, v_ult); end if;
    if array_length(v_tirar, 1) > 0 then
      delete from public.localizacoes where id = any (v_tirar);
      v_n := v_n + array_length(v_tirar, 1);
    end if;
    update public.corridas set pings_afinados_em = now() where id = k.id;
  end loop;
  return v_n;
end;
$$;
revoke execute on function privado.afinar_pings(int) from public, anon, authenticated;

do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'cron') and exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'cron' and p.proname = 'schedule') then
    perform cron.schedule('pwex-regioes', '17 * * * *', 'select privado.aprender_regioes()');
    perform cron.schedule('pwex-afinar-pings', '41 4 * * *', 'select privado.afinar_pings(200)');
  end if;
exception when others then null;
end $$;

revoke execute on function public.passar_corrida(uuid, uuid, text), public.compartilhamento_motoboys(), public.salvar_compartilhamento_motoboys(text, uuid[], uuid),
  public.regioes_do_motoboy(uuid), public.perfil_publico(uuid), public.rota_compartilhada(uuid), public.pedido_compartilhado(uuid), public.conquistas(uuid) from public, anon;
grant execute on function public.passar_corrida(uuid, uuid, text), public.compartilhamento_motoboys(), public.salvar_compartilhamento_motoboys(text, uuid[], uuid),
  public.regioes_do_motoboy(uuid), public.perfil_publico(uuid), public.rota_compartilhada(uuid), public.pedido_compartilhado(uuid), public.conquistas(uuid) to authenticated;
revoke all on privado.motoboy_regioes, privado.regioes_estado from public, anon, authenticated;
