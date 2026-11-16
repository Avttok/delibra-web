-- 0047 · Fuso por empresa, ofertas resistentes e campos na chegada
--  • fuso_horario: cada empresa escolhe o fuso (horários, relatórios, "hoje", janelas de preço)
--  • expirar_ofertas: uma rota com problema não derruba as outras; o erro vai para a Saúde do sistema
--  • campos_personalizados.etapa: campo do ponto perguntado na chegada ou ao concluir

do $$ begin
  perform set_config('lock_timeout', '60s', true);
  lock table public.campos_personalizados in access exclusive mode;
end $$;

-- ===================================================================== fuso horário
create or replace function privado.fuso_valido(p text)
returns text language sql immutable set search_path = '' as $$
  select case when p = any (array['America/Sao_Paulo', 'America/Noronha', 'America/Manaus', 'America/Cuiaba', 'America/Campo_Grande',
                                  'America/Porto_Velho', 'America/Boa_Vista', 'America/Rio_Branco', 'America/Belem', 'America/Fortaleza',
                                  'America/Recife', 'America/Bahia', 'America/Araguaina', 'America/Maceio'])
              then p else 'America/Sao_Paulo' end;
$$;

create or replace function privado.fuso_org(p_org uuid)
returns text language sql stable security definer set search_path = '' as $$
  select privado.fuso_valido(privado.cfg_org_txt(p_org, 'fuso_horario', 'America/Sao_Paulo'));
$$;

-- Fuso de quem está chamando (ou da empresa em contexto: pwex.org). Use "(select privado.fuso())" nas consultas: calcula uma vez só.
create or replace function privado.fuso()
returns text language sql stable security definer set search_path = '' as $$
  select privado.fuso_valido(coalesce(nullif(current_setting('pwex.fuso', true), ''), privado.cfg_org_txt(privado.org_contexto(), 'fuso_horario', 'America/Sao_Paulo')));
$$;
revoke execute on function privado.fuso_valido(text), privado.fuso_org(uuid), privado.fuso() from public, anon, authenticated;

insert into public.ajuste_grupos (chave, grupo, area) values ('fuso_horario', 'plataforma', 'sistema')
on conflict (chave) do update set grupo = excluded.grupo, area = excluded.area;

-- ===================================================================== erros do servidor na Saúde do sistema
create or replace function privado.erro_servidor(p_onde text, p_msg text, p_org uuid default null)
returns void language plpgsql security definer set search_path = '' as $$
declare v_ass text := 'servidor:' || p_onde || ':' || left(regexp_replace(coalesce(p_msg, ''), '[0-9a-f]{8}-[0-9a-f-]{27}', '…', 'g'), 80); v_id bigint;
begin
  select id into v_id from public.erros_app where assinatura = v_ass and versao = 'servidor' and ultimo_em > now() - interval '1 day' order by id desc limit 1;
  if v_id is not null then
    update public.erros_app set quantas = quantas + 1, ultimo_em = now(), mensagem = left(p_msg, 2000) where id = v_id;
  else
    insert into public.erros_app (organizacao_id, assinatura, tipo, versao, aparelho, tela, mensagem)
    values (p_org, v_ass, 'erro', 'servidor', 'servidor', p_onde, left(p_msg, 2000));
  end if;
exception when others then null;   -- registrar o erro nunca pode derrubar quem chamou
end;
$$;
revoke execute on function privado.erro_servidor(text, text, uuid) from public, anon, authenticated;

-- ===================================================================== ofertas vencidas: uma por vez, sem derrubar as outras
create or replace function privado.expirar_ofertas()
returns void language plpgsql security definer set search_path = '' as $$
declare
  r record;
begin
  -- não fica esperando trava: se algo estiver preso, tenta de novo em 5 s
  perform set_config('lock_timeout', '3s', true);
  for r in
    update public.ofertas o set status = 'expirada', respondida_em = now()
     where o.id in (select x.id from public.ofertas x where x.status = 'pendente' and x.expira_em <= now()
                     order by x.expira_em limit 200 for update skip locked)
    returning o.corrida_id, o.motoboy_id
  loop
    begin
      perform privado.evento(r.corrida_id, 'oferta_expirada', jsonb_build_object('motoboy_id', r.motoboy_id));
      perform privado.despachar(r.corrida_id);
    exception when others then
      perform privado.erro_servidor('expirar_ofertas', sqlerrm, (select organizacao_id from public.corridas where id = r.corrida_id));
    end;
  end loop;
end;
$$;

-- ===================================================================== campos do ponto: na chegada ou ao concluir
alter table public.campos_personalizados add column if not exists etapa text not null default 'concluir';
do $$ begin
  alter table public.campos_personalizados add constraint campos_personalizados_etapa_check check (etapa in ('chegou', 'concluir'));
exception when duplicate_object then null; end $$;

create or replace function public.salvar_campo(p jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid := nullif(p ->> 'id', '')::uuid; v_org uuid; v_atual public.campos_personalizados%rowtype;
begin
  if not (public.is_dev() or public.is_gestor_pleno()) then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  perform privado.exigir_acao('campos_personalizados');
  if not public.is_dev() and not privado.cfg_org_bool(public.minha_org(), 'gestor_cria_campos', true) then raise exception 'acao_bloqueada' using errcode = '42501'; end if;
  -- Dev: "plataforma" = vale para todas; senão a empresa em foco. Gestor: sempre a empresa dele.
  v_org := case when public.is_dev() then case when coalesce((p ->> 'da_plataforma')::boolean, false) then null else public.minha_org() end else public.minha_org() end;
  if v_id is not null then
    select * into v_atual from public.campos_personalizados where id = v_id;
    if v_atual.id is null then raise exception 'campo_inexistente' using errcode = '22023'; end if;
    if not public.is_dev() and v_atual.organizacao_id is distinct from public.minha_org() then raise exception 'sem_permissao' using errcode = '42501'; end if;
    v_org := case when public.is_dev() then v_atual.organizacao_id else v_org end;
  end if;
  insert into public.campos_personalizados as c (id, organizacao_id, entidade, ponto_tipo, tipos_pedido, chave, rotulo, dica, tipo, opcoes, obrigatorio,
                                                 quem_preenche, visivel_cliente, visivel_motoboy, ordem, ativo, etapa)
  values (coalesce(v_id, gen_random_uuid()), v_org, p ->> 'entidade', nullif(p ->> 'ponto_tipo', ''),
          coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p -> 'tipos_pedido', '[]')) x), '{}'),
          left(trim(both '_' from lower(regexp_replace(translate(lower(coalesce(nullif(p ->> 'chave', ''), p ->> 'rotulo')),
               'áàâãäéèêëíìîïóòôõöúùûüçñ', 'aaaaaeeeeiiiiooooouuuucn'), '[^a-z0-9]+', '_', 'g'))), 40),
          left(trim(p ->> 'rotulo'), 80), nullif(left(trim(coalesce(p ->> 'dica', '')), 200), ''), coalesce(nullif(p ->> 'tipo', ''), 'texto'),
          coalesce((select array_agg(left(trim(x), 60)) from jsonb_array_elements_text(coalesce(p -> 'opcoes', '[]')) x where trim(x) <> ''), '{}'),
          coalesce((p ->> 'obrigatorio')::boolean, false), coalesce(nullif(p ->> 'quem_preenche', ''), 'qualquer'),
          coalesce((p ->> 'visivel_cliente')::boolean, true), coalesce((p ->> 'visivel_motoboy')::boolean, true),
          coalesce((p ->> 'ordem')::int, 0), coalesce((p ->> 'ativo')::boolean, true),
          case when p ->> 'etapa' = 'chegou' then 'chegou' else 'concluir' end)
  on conflict (id) do update set entidade = excluded.entidade, ponto_tipo = excluded.ponto_tipo, tipos_pedido = excluded.tipos_pedido,
    rotulo = excluded.rotulo, dica = excluded.dica, tipo = excluded.tipo, opcoes = excluded.opcoes, obrigatorio = excluded.obrigatorio,
    quem_preenche = excluded.quem_preenche, visivel_cliente = excluded.visivel_cliente, visivel_motoboy = excluded.visivel_motoboy,
    ordem = excluded.ordem, ativo = excluded.ativo, etapa = excluded.etapa
  returning c.id into v_id;
  return v_id;
exception when unique_violation then raise exception 'campo_repetido' using errcode = '23505';
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
      'motoboy_pode_finalizar', privado.pol_bool('motoboy_pode_finalizar', false, null, p.id, null))
  )
  from public.perfis p
  left join public.motoboys m on m.id = p.id
  where p.id = auth.uid();
$$;
create or replace function public.meus_ganhos()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_teste boolean := coalesce((select modo_teste from public.motoboys where id = auth.uid()), false);
  v_ve    boolean := privado.ve_valores(auth.uid());
  v_per   record;
  v       jsonb;
begin
  select * into v_per from privado.periodo_holerite(auth.uid(), privado.dia_local(now()));
  with base as (
    select valor_motoboy, coalesce(distancia_real_m, distancia_planejada_m, 0) as metros,
           (select count(*) from public.paradas x where x.corrida_id = c.id and x.tipo = 'entrega') entregas,
           (concluida_em at time zone (select privado.fuso())) as quando
      from public.corridas c
     where motoboy_id = auth.uid() and status = 'concluida' and c.teste = v_teste
  ), agora as (select (now() at time zone (select privado.fuso())) as t)
  select jsonb_build_object(
    'valores_visiveis', v_ve,
    'hoje',   case when v_ve then coalesce(sum(valor_motoboy) filter (where quando >= date_trunc('day', t)), 0) end,
    'semana', case when v_ve then coalesce(sum(valor_motoboy) filter (where quando >= date_trunc('week', t)), 0) end,
    'mes',    case when v_ve then coalesce(sum(valor_motoboy) filter (where quando >= date_trunc('month', t)), 0) end,
    'total',  case when v_ve then coalesce(sum(valor_motoboy), 0) end,
    'periodo_total', case when v_ve then coalesce(sum(valor_motoboy) filter (where quando::date between v_per.inicio and v_per.fim), 0) end,
    'periodo_inicio', v_per.inicio, 'periodo_fim', v_per.fim,
    'corridas_hoje',   count(*) filter (where quando >= date_trunc('day', t)),
    'corridas_semana', count(*) filter (where quando >= date_trunc('week', t)),
    'corridas_mes',    count(*) filter (where quando >= date_trunc('month', t)),
    'corridas_periodo', count(*) filter (where quando::date between v_per.inicio and v_per.fim),
    'entregas_hoje',   coalesce(sum(entregas) filter (where quando >= date_trunc('day', t)), 0),
    'entregas_periodo', coalesce(sum(entregas) filter (where quando::date between v_per.inicio and v_per.fim), 0),
    'km_hoje', round(coalesce(sum(metros) filter (where quando >= date_trunc('day', t)), 0) / 1000.0, 1),
    'km_periodo', round(coalesce(sum(metros) filter (where quando::date between v_per.inicio and v_per.fim), 0) / 1000.0, 1),
    'km_mes',  round(coalesce(sum(metros) filter (where quando >= date_trunc('month', t)), 0) / 1000.0, 1),
    'teste', v_teste
  ) into v
  from base, agora;
  return v;
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
  perform privado.evento_pedido(v_id, 'criado', jsonb_build_object('origem', case when v_gestor then 'gestor' else 'cliente' end, 'total', v_orc -> 'total'));
  if v_status = 'aprovado' then perform privado.roteirizar(v_teste); end if;
  return v_id;
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
             || to_char((p.quando - v_antes) at time zone (select privado.fuso()), 'DD/MM HH24:MI') || ').', 'rotas', v_rotas, 'ciclo', v_cron);
  end if;
  v_aviso := case when v_job is not null then ' Atenção: ' || v_job || ', então nada é montado sozinho.'
                  when v_cron is not null and v_cron not like 'succeeded%' then ' Atenção, o último ciclo automático falhou: ' || v_cron
                  else '' end;
  if p.tipo = 'express' and coalesce(p.aprovado_em, p.criado_em) > now() - v_espera then
    return jsonb_build_object('codigo', 'espera', 'rotas', v_rotas, 'ciclo', v_cron, 'motivo',
      'Express: esperando ' || privado.cfg_num('express_agrupar_espera_min', 0)::int || ' min para juntar com outros pedidos (monta às '
      || to_char((coalesce(p.aprovado_em, p.criado_em) + v_espera) at time zone (select privado.fuso()), 'HH24:MI')
      || '). “Montar rota agora” monta já, juntando os pedidos que estão esperando.' || v_aviso);
  end if;
  return jsonb_build_object('codigo', 'sem_bloqueio', 'rotas', v_rotas, 'ciclo', v_cron,
    'motivo', 'Nada impede a rota. Use “Montar rota agora”: se der erro, a mensagem aparece aqui.' || v_aviso);
end;
$$;
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
    if c.agendada_para is not null then v_linhas := v_linhas || jsonb_build_array(jsonb_build_object('icone', 'calendar-clock', 'rotulo', 'Agendada', 'valor', to_char(c.agendada_para at time zone (select privado.fuso()), 'DD/MM HH24:MI'))); end if;
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
                         'valor', to_char(coalesce(p.quando, p.criado_em) at time zone (select privado.fuso()), 'DD/MM HH24:MI')));
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
create or replace function public.meu_plano(p_de date default null, p_ate date default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_org  uuid := public.minha_org();
  v_de   date := coalesce(p_de, date_trunc('month', now() at time zone (select privado.fuso()))::date);
  v_ate  date := coalesce(p_ate, (now() at time zone (select privado.fuso()))::date);
  o      public.organizacoes%rowtype;
  v_fat  numeric; v_rotas int; v_pct_val numeric; v_devido numeric; v_venc date;
begin
  if not public.is_gestor_pleno() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if v_org is null then return null; end if;
  select * into o from public.organizacoes where id = v_org;
  select coalesce(sum(c.valor), 0), count(*), coalesce(sum(c.valor_dev), 0) into v_fat, v_rotas, v_pct_val
    from public.corridas c
   where c.organizacao_id = v_org and c.status = 'concluida' and not coalesce(c.teste, false)
     and (c.concluida_em at time zone (select privado.fuso()))::date between v_de and v_ate;
  v_devido := round(case o.cobranca_modelo when 'percentual' then v_pct_val
    when 'licenca' then case o.cobranca_periodo when 'anual' then o.mensalidade / 12.0 when 'vitalicia' then 0 else o.mensalidade end else 0 end, 2);
  v_venc := make_date(extract(year from v_ate)::int, extract(month from v_ate)::int, o.vencimento_dia);
  if v_venc < v_ate then v_venc := (v_venc + interval '1 month')::date; end if;
  return jsonb_build_object(
    'empresa', o.nome, 'status', o.status, 'modelo', o.cobranca_modelo,
    'pct', o.cobranca_pct, 'mensalidade', o.mensalidade, 'periodo', o.cobranca_periodo, 'vencimento_dia', o.vencimento_dia, 'proximo_vencimento', v_venc,
    'de', v_de, 'ate', v_ate, 'faturamento', v_fat, 'rotas', v_rotas, 'devido', v_devido,
    'limites', o.limites,
    'historico', coalesce((select jsonb_agg(jsonb_build_object('modelo', l.modelo, 'valor', l.valor, 'pct', l.pct,
        'inicio', l.inicio, 'fim', l.fim, 'status', l.status) order by l.inicio desc, l.criado_em desc)
        from public.licencas l where l.organizacao_id = v_org), '[]'::jsonb),
    'meses', coalesce((select jsonb_agg(jsonb_build_object('mes', m.mes, 'faturamento', m.fat, 'rotas', m.n, 'devido',
          round(case o.cobranca_modelo when 'percentual' then m.dev when 'licenca' then case o.cobranca_periodo when 'anual' then o.mensalidade / 12.0 when 'vitalicia' then 0 else o.mensalidade end else 0 end, 2)) order by m.mes desc)
        from (select date_trunc('month', c.concluida_em at time zone (select privado.fuso()))::date mes, sum(c.valor) fat, count(*) n, sum(c.valor_dev) dev
                from public.corridas c where c.organizacao_id = v_org and c.status = 'concluida' and not coalesce(c.teste, false)
                 and c.concluida_em > now() - interval '6 months' group by 1) m), '[]'::jsonb));
end;
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
    select k.*, (k.concluida_em at time zone (select privado.fuso())) local
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
create or replace function public.painel_do_dia()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_hoje timestamptz := date_trunc('day', now() at time zone (select privado.fuso())) at time zone (select privado.fuso());
  v_teste boolean := coalesce((select p.modo_teste from public.perfis p where p.id = auth.uid()), false);
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  return jsonb_build_object(
    'pedidos_hoje', (select count(*) from public.pedidos p where public.ve_org(p.organizacao_id) and p.criado_em >= v_hoje),
    'para_revisar', (select count(*) from public.pedidos p where public.ve_org(p.organizacao_id) and p.status::text = 'recebido'),
    'rotas_ativas', (select count(*) from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text in ('aceita', 'em_andamento')),
    'rotas_esperando', (select count(*) from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text in ('aguardando_motoboy', 'sem_motoboy', 'montada')),
    'sem_motoboy', (select count(*) from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'sem_motoboy'),
    'concluidas_hoje', (select count(*) from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'concluida' and c.concluida_em >= v_hoje),
    'faturamento_hoje', (select coalesce(sum(c.valor), 0) from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'concluida' and c.concluida_em >= v_hoje),
    'gestao_hoje', (select coalesce(sum(c.valor_gestao), 0) from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'concluida' and c.concluida_em >= v_hoje),
    'km_hoje', (select round(coalesce(sum(coalesce(c.distancia_real_m, c.distancia_planejada_m)), 0) / 1000.0, 1) from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'concluida' and c.concluida_em >= v_hoje),
    'motoboys_online', (select count(*) from public.motoboys m join public.perfis p on p.id = m.id where public.ve_org(p.organizacao_id) and m.status::text <> 'offline' and p.modo_teste = v_teste),
    'motoboys_em_rota', (select count(*) from public.motoboys m join public.perfis p on p.id = m.id where public.ve_org(p.organizacao_id) and m.status::text = 'em_corrida' and p.modo_teste = v_teste),
    'emergencias', (select count(*) from public.emergencias e where public.ve_org(e.organizacao_id) and e.resolvida_em is null),
    'chamados', (select count(*) from public.chamados_corrida h where public.ve_org(h.organizacao_id) and h.status = 'pendente'),
    'aguardando_confirmacao', (select count(*) from public.corridas c where public.ve_org(c.organizacao_id) and c.aguardando_confirmacao),
    'nota_media_30d', (select round(avg(a.nota)::numeric, 1) from public.avaliacoes a where public.ve_org(a.organizacao_id) and a.criado_em > now() - interval '30 days'),
    'notas_ruins_hoje', (select count(*) from public.avaliacoes a where public.ve_org(a.organizacao_id) and a.criado_em >= v_hoje and a.nota <= 2),
    'por_hora', (select coalesce(jsonb_agg(jsonb_build_object('hora', h, 'rotas', n) order by h), '[]') from (
                   select extract(hour from c.concluida_em at time zone (select privado.fuso()))::int h, count(*) n from public.corridas c
                    where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'concluida' and c.concluida_em >= v_hoje group by 1) x),
    'canceladas_hoje', (select count(*) from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'cancelada' and c.cancelada_em >= v_hoje),
    'entregas_hoje', (select count(*) from public.paradas x join public.corridas c on c.id = x.corrida_id where public.ve_org(c.organizacao_id) and c.teste = v_teste
                       and x.tipo::text = 'entrega' and x.status::text = 'concluida' and x.concluida_em >= v_hoje),
    'tempo_medio_min', (select round(avg(extract(epoch from (c.concluida_em - coalesce(c.aceita_em, c.iniciada_em))) / 60.0))::int from public.corridas c
                         where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'concluida' and c.concluida_em >= v_hoje and coalesce(c.aceita_em, c.iniciada_em) is not null),
    'pagar_motoboys_hoje', (select coalesce(sum(c.valor_motoboy), 0) from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'concluida' and c.concluida_em >= v_hoje),
    'ontem_concluidas', (select count(*) from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'concluida'
                          and c.concluida_em >= v_hoje - interval '1 day' and c.concluida_em < now() - interval '1 day'),
    'hora_agora', extract(hour from now() at time zone (select privado.fuso()))::int,
    'em_andamento', (select coalesce(jsonb_agg(x order by x->>'desde'), '[]') from (
                   select jsonb_build_object('id', c.id, 'numero', c.numero, 'motoboy', split_part(public.nome_publico(c.motoboy_id), ' ', 1), 'status', c.status::text,
                     'feitas', (select count(*) from public.paradas p where p.corrida_id = c.id and p.status::text = 'concluida'),
                     'total', (select count(*) from public.paradas p where p.corrida_id = c.id), 'desde', coalesce(c.aceita_em, c.criada_em)) x
                     from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text in ('aceita', 'em_andamento')
                     order by coalesce(c.aceita_em, c.criada_em) limit 8) y),
    'top_motoboys', (select coalesce(jsonb_agg(jsonb_build_object('nome', split_part(public.nome_publico(x.motoboy_id), ' ', 1), 'rotas', x.n) order by x.n desc), '[]') from (
                   select c.motoboy_id, count(*) n from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'concluida' and c.concluida_em >= v_hoje and c.motoboy_id is not null
                    group by 1 order by 2 desc limit 5) x));
end;
$$;
create or replace function public.relatorio(p_tipo text, p_de date, p_ate date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_de timestamptz := (p_de::timestamp) at time zone (select privado.fuso());
  v_ate timestamptz := ((p_ate + 1)::timestamp) at time zone (select privado.fuso());
  v_teste boolean := coalesce((select p.modo_teste from public.perfis p where p.id = auth.uid()), false);
  r jsonb;
begin
  perform privado.exigir_acao('exportar_dados');
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if p_de is null or p_ate is null or p_ate < p_de or p_ate - p_de > 400 then raise exception 'periodo_invalido' using errcode = '22023'; end if;
  if p_tipo = 'rotas' then
    select coalesce(jsonb_agg(jsonb_build_object(
        'Rota', c.numero, 'Data', to_char(coalesce(c.concluida_em, c.cancelada_em, c.criada_em) at time zone (select privado.fuso()), 'DD/MM/YYYY HH24:MI'),
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
        'Pedido', p.numero, 'Data', to_char(p.criado_em at time zone (select privado.fuso()), 'DD/MM/YYYY HH24:MI'),
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
create or replace function privado.penalizar(p_org uuid, p_alvo_tipo text, p_alvo uuid, p_tipo text, p_pontos numeric,
                                             p_motivo text default null, p_corrida uuid default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_total numeric; v_lim numeric; v_h numeric; v_ate timestamptz;
begin
  if p_alvo is null or coalesce(p_pontos, 0) <= 0 then return null; end if;
  if not coalesce((select (valor #>> '{}')::boolean from public.politicas where escopo = 'organizacao' and alvo = p_org::text and chave = 'pen_ligado'),
                  (select (valor #>> '{}')::boolean from public.configuracoes where chave = 'pen_ligado'), true) then return null; end if;
  insert into public.penalidades (organizacao_id, alvo_tipo, motoboy_id, empresa_id, tipo, pontos, motivo, corrida_id, criado_por)
  values (p_org, p_alvo_tipo, case when p_alvo_tipo = 'motoboy' then p_alvo end, case when p_alvo_tipo = 'cliente' then p_alvo end,
          p_tipo, p_pontos, nullif(trim(p_motivo), ''), p_corrida, auth.uid())
  returning id into v_id;
  v_total := privado.pontos_penalidade(p_alvo_tipo, p_alvo, p_org);
  if p_alvo_tipo = 'motoboy' then
    v_lim := privado.cfg_org_num(p_org, 'pen_limite', 10);
    v_h := privado.cfg_org_num(p_org, 'pen_suspensao_horas', 24);
    if v_lim > 0 and v_total >= v_lim and v_h > 0 and not privado.motoboy_suspenso(p_alvo) then
      v_ate := now() + make_interval(mins => (v_h * 60)::int);
      update public.motoboys set suspenso_ate = v_ate, suspenso_motivo = 'Passou de ' || v_lim || ' pontos de penalidade' where id = p_alvo;
      perform privado.enviar_push(p_alvo, jsonb_build_object('tipo', 'suspenso', 'ate', to_char(v_ate at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'titulo', 'Você está suspenso', 'texto', 'Passou do limite de penalidades. Sem corridas novas até ' || to_char(v_ate at time zone privado.fuso_org(p_org), 'DD/MM HH24:MI') || '.'));
      perform privado.avisar_gestores(p_org, jsonb_build_object('tipo', 'motoboy_suspenso', 'motoboy_id', p_alvo::text,
        'titulo', coalesce((select split_part(nome, ' ', 1) from public.perfis where id = p_alvo), 'Motoboy') || ' foi suspenso',
        'texto', 'Passou de ' || v_lim || ' pontos de penalidade. Volta ' || to_char(v_ate at time zone privado.fuso_org(p_org), 'DD/MM HH24:MI') || '.'), 'pessoas');
    end if;
  else
    v_lim := privado.cfg_org_num(p_org, 'pen_cliente_limite', 0);
    v_h := privado.cfg_org_num(p_org, 'pen_cliente_bloqueio_horas', 72);
    if v_lim > 0 and v_total >= v_lim and v_h > 0 then
      update public.empresas set bloqueado_ate = now() + make_interval(mins => (v_h * 60)::int),
             bloqueado_motivo = 'Passou de ' || v_lim || ' pontos de penalidade' where id = p_alvo and (bloqueado_ate is null or bloqueado_ate < now());
    end if;
  end if;
  return v_id;
end;
$$;
create or replace function privado.chat_fora_do_horario(p_org uuid)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare v_agora timestamp := (now() at time zone privado.fuso_org(p_org)); v_de time; v_ate time; v_dias jsonb;
begin
  if not privado.cfg_org_bool(p_org, 'chat_atendimento_ligado', false) then return false; end if;
  v_de := coalesce(nullif(privado.cfg_org_txt(p_org, 'chat_atendimento_de', '08:00'), '')::time, '08:00');
  v_ate := coalesce(nullif(privado.cfg_org_txt(p_org, 'chat_atendimento_ate', '18:00'), '')::time, '18:00');
  select coalesce(p.valor, c.valor) into v_dias from public.configuracoes c
    left join public.politicas p on p.escopo = 'organizacao' and p.alvo = p_org::text and p.chave = 'chat_atendimento_dias'
   where c.chave = 'chat_atendimento_dias';
  if jsonb_typeof(v_dias) = 'array' and not (v_dias @> to_jsonb(extract(isodow from v_agora)::int) or v_dias @> to_jsonb(extract(isodow from v_agora)::int::text)) then return true; end if;
  return v_agora::time < v_de or v_agora::time >= v_ate;
exception when others then return false;
end;
$$;
create or replace function privado.orcar(d jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_cli    uuid := nullif(d ->> 'empresa_id', '')::uuid;
  v_tp     text := coalesce(nullif(d ->> 'tipo_pedido', ''), 'padrao');
  v_quando timestamptz := coalesce(nullif(d ->> 'quando', '')::timestamptz, now());
  e        public.empresas%rowtype;
  v_linhas jsonb := '[]';
  v_pcts   jsonb := '[]';
  v_fixos  numeric := 0;
  v_sub    numeric := 0;
  v_pct    numeric := 0;
  v_dist   numeric;
  v_km     numeric;
  v_ncol   int; v_nent int; v_pac int;
  v_real   numeric; v_cub numeric; v_tax numeric;
  v_val    numeric; v_x numeric;
  v_perig  boolean;
  v_cat    record;
  v_zp     numeric := 0; v_za numeric := 0; v_znomes text[] := '{}';
  v_hp     numeric := 0; v_ha numeric := 0; v_hnome text;
  v_somar  boolean;
  v_total  numeric;
  v_min    numeric;
  v_fixo_cliente boolean := false;
  v_vkm    numeric;
  v_guc    text := current_setting('pwex.regras', true);
  v_soma   boolean;
  v_pt     jsonb;
  v_col    jsonb;
  v_n      int := 0;
  v_d      numeric;
  v_fr     numeric;
  v_reta   boolean;
  v_org    uuid := privado.org_contexto(nullif(d ->> 'empresa_id', '')::uuid);
begin
  -- regras do pedido (salvo ou ainda no formulário)
  if nullif(d ->> 'pedido_id', '') is not null then
    perform privado.usar_regras((select regras from public.pedidos where id = (d ->> 'pedido_id')::uuid));
  elsif d ? 'regras' then
    perform privado.usar_regras(d -> 'regras');
  end if;
  if v_cli is not null then select * into e from public.empresas where id = v_cli; end if;
  select count(*) filter (where x ->> 'tipo' = 'coleta'), count(*) filter (where x ->> 'tipo' = 'entrega')
    into v_ncol, v_nent from jsonb_array_elements(coalesce(d -> 'pontos', '[]')) x;
  v_reta := privado.pol_txt('orcamento_trajeto', 'ruas', v_cli, null, v_tp) = 'reta';
  v_dist := coalesce(case when v_reta then null else nullif(d ->> 'distancia_m', '')::numeric end,
                     privado.distancia_estimada(d -> 'pontos') * privado.pol_num('fator_rua', 1.3, v_cli, null, v_tp));
  v_km := round(v_dist / 1000.0, 2);
  v_soma := privado.pol_txt('preco_distancia_modo', 'soma_entregas', v_cli, null, v_tp) = 'soma_entregas';
  v_fr := privado.pol_num('fator_rua', 1.3, v_cli, null, v_tp);

  -- base e distância (o preço fixo do cadastro antigo do cliente ainda vale)
  if e.id is not null and e.modalidade_preco::text = 'fixo' and e.valor_fixo is not null
     and not exists (select 1 from public.politicas where escopo = 'cliente' and alvo = v_cli::text and chave in ('preco_base', 'preco_km'))
     and not (coalesce(nullif(current_setting('pwex.regras', true), '')::jsonb, '{}') ?| array['preco_base', 'preco_km']) then
    v_fixo_cliente := true;
    v_linhas := v_linhas || jsonb_build_object('rotulo', 'Preço fixo do cliente', 'valor', e.valor_fixo);
    v_sub := v_sub + e.valor_fixo;
  else
    v_val := privado.pol_num('preco_base', 8, v_cli, null, v_tp);
    if v_soma and not privado.pol_bool('soma_inclui_saida', false, v_cli, null, v_tp) then v_val := 0; end if;
    if v_val <> 0 then v_linhas := v_linhas || jsonb_build_object('chave', 'saida', 'rotulo', 'Saída', 'valor', v_val); v_sub := v_sub + v_val; end if;
    v_vkm := privado.pol_num('preco_km', 2.5, v_cli, null, v_tp);
    if e.id is not null and e.modalidade_preco::text = 'por_km' and e.valor_km is not null
       and not exists (select 1 from public.politicas where escopo = 'cliente' and alvo = v_cli::text and chave = 'preco_km')
       and not (coalesce(nullif(current_setting('pwex.regras', true), '')::jsonb, '{}') ? 'preco_km') then
      v_vkm := e.valor_km;
    end if;
    if v_soma then
      -- soma das entregas: cada entrega = valor/km × distância da coleta dela (a coleta anterior na lista; sem ela, a primeira)
      v_dist := 0;
      v_col := (select x from jsonb_array_elements(coalesce(d -> 'pontos', '[]')) x where x ->> 'tipo' = 'coleta' limit 1);
      for v_pt in select * from jsonb_array_elements(coalesce(d -> 'pontos', '[]')) loop
        if v_pt ->> 'tipo' = 'coleta' then v_col := v_pt; continue; end if;
        v_n := v_n + 1;
        v_d := coalesce(case when v_reta then null else nullif(v_pt ->> 'dist_coleta_m', '')::numeric end,
                        privado.dist_m((v_col ->> 'lat')::double precision, (v_col ->> 'lng')::double precision,
                                       (v_pt ->> 'lat')::double precision, (v_pt ->> 'lng')::double precision) * v_fr, 0);
        v_dist := v_dist + v_d;
        v_val := round(round(v_d / 1000.0, 2) * v_vkm, 2);
        v_linhas := v_linhas || jsonb_build_object('chave', 'entrega_' || v_n, 'rotulo', case when v_nent > 1 then 'Entrega ' || v_n else 'Entrega' end,
          'detalhe', format('coleta → entrega: %s km × R$ %s', round(v_d / 1000.0, 2), v_vkm), 'qtd', round(v_d / 1000.0, 2), 'unit', v_vkm, 'unidade', 'km', 'valor', v_val);
        v_sub := v_sub + v_val;
      end loop;
      v_km := round(v_dist / 1000.0, 2);
    else
      v_val := round(v_km * v_vkm, 2);
      v_linhas := v_linhas || jsonb_build_object('chave', 'distancia', 'rotulo', 'Distância', 'detalhe', format('%s km × R$ %s', v_km, v_vkm), 'qtd', v_km, 'unit', v_vkm, 'unidade', 'km', 'valor', v_val);
      v_sub := v_sub + v_val;
    end if;
  end if;

  -- pontos extras
  if v_ncol > 1 then
    v_val := (v_ncol - 1) * privado.pol_num('preco_coleta_extra', 5, v_cli, null, v_tp);
    if v_val <> 0 then v_linhas := v_linhas || jsonb_build_object('rotulo', 'Coletas extras', 'detalhe', format('%s × R$ %s', v_ncol - 1, privado.pol_num('preco_coleta_extra', 5, v_cli, null, v_tp)), 'qtd', v_ncol - 1, 'unit', privado.pol_num('preco_coleta_extra', 5, v_cli, null, v_tp), 'unidade', 'coleta', 'valor', v_val); v_sub := v_sub + v_val; end if;
  end if;
  if v_nent > 1 and (not v_soma or v_fixo_cliente or privado.pol_bool('soma_inclui_entrega_extra', false, v_cli, null, v_tp)) then
    v_val := (v_nent - 1) * privado.pol_num('preco_entrega_extra', 5, v_cli, null, v_tp);
    if v_val <> 0 then v_linhas := v_linhas || jsonb_build_object('rotulo', 'Entregas extras', 'detalhe', format('%s × R$ %s', v_nent - 1, privado.pol_num('preco_entrega_extra', 5, v_cli, null, v_tp)), 'qtd', v_nent - 1, 'unit', privado.pol_num('preco_entrega_extra', 5, v_cli, null, v_tp), 'unidade', 'entrega', 'valor', v_val); v_sub := v_sub + v_val; end if;
  end if;

  -- pacotes, peso real × peso cubado
  select coalesce(sum(coalesce((i ->> 'quantidade')::int, 1)), 0),
         coalesce(sum(coalesce((i ->> 'quantidade')::int, 1) * coalesce((i ->> 'peso_kg')::numeric, 0)), 0),
         coalesce(sum(coalesce((i ->> 'quantidade')::int, 1) * coalesce((i ->> 'comprimento_cm')::numeric, 0) * coalesce((i ->> 'largura_cm')::numeric, 0)
                      * coalesce((i ->> 'altura_cm')::numeric, 0)), 0) / greatest(privado.pol_num('cubagem_fator', 6000, v_cli, null, v_tp), 1)
    into v_pac, v_real, v_cub from jsonb_array_elements(coalesce(d -> 'itens', '[]')) i;
  v_x := greatest(0, v_pac - privado.pol_num('preco_pacotes_inclusos', 1, v_cli, null, v_tp));
  if v_x > 0 then
    v_val := v_x * privado.pol_num('preco_pacote_extra', 1, v_cli, null, v_tp);
    if v_val <> 0 then v_linhas := v_linhas || jsonb_build_object('rotulo', 'Volumes extras', 'detalhe', format('%s volume(s) além do incluso', v_x), 'qtd', v_x, 'unit', privado.pol_num('preco_pacote_extra', 1, v_cli, null, v_tp), 'unidade', 'volume', 'valor', v_val); v_sub := v_sub + v_val; end if;
  end if;
  v_tax := round(greatest(v_real, v_cub), 2);
  v_x := greatest(0, v_tax - privado.pol_num('preco_kg_incluso', 5, v_cli, null, v_tp));
  if v_x > 0 then
    v_val := round(v_x * privado.pol_num('preco_kg', 1, v_cli, null, v_tp), 2);
    if v_val <> 0 then
      v_linhas := v_linhas || jsonb_build_object('rotulo', 'Peso excedente',
        'detalhe', format('%s kg taxados (%s)', v_tax, case when v_cub > v_real then 'peso cubado' else 'peso real' end), 'qtd', v_x, 'unit', privado.pol_num('preco_kg', 1, v_cli, null, v_tp), 'unidade', 'kg', 'valor', v_val);
      v_sub := v_sub + v_val;
    end if;
  end if;

  -- categorias
  v_perig := false;
  for v_cat in
    select k.id, k.nome, k.perigoso, k.adicional_item, k.adicional_fixo, k.fator_pct, sum(coalesce((i ->> 'quantidade')::int, 1)) q
      from jsonb_array_elements(coalesce(d -> 'itens', '[]')) i
      join public.categorias_produto k on k.id = nullif(i ->> 'categoria_id', '')::uuid
     group by k.id
  loop
    v_perig := v_perig or v_cat.perigoso;
    v_val := v_cat.adicional_fixo + v_cat.adicional_item * v_cat.q;
    if v_val <> 0 then v_linhas := v_linhas || jsonb_build_object('rotulo', v_cat.nome, 'detalhe', format('%s item(ns)', v_cat.q), 'valor', v_val); v_sub := v_sub + v_val; end if;
    if v_cat.fator_pct <> 0 then v_pcts := v_pcts || jsonb_build_object('rotulo', v_cat.nome, 'pct', v_cat.fator_pct); v_pct := v_pct + v_cat.fator_pct; end if;
  end loop;
  if v_perig then
    v_val := privado.pol_num('preco_perigoso_fixo', 10, v_cli, null, v_tp);
    if v_val <> 0 then v_linhas := v_linhas || jsonb_build_object('rotulo', 'Produto perigoso', 'fixo', true, 'valor', v_val); v_fixos := v_fixos + v_val; end if;
    v_x := privado.pol_num('preco_perigoso_pct', 30, v_cli, null, v_tp);
    if v_x <> 0 then v_pcts := v_pcts || jsonb_build_object('rotulo', 'Produto perigoso', 'pct', v_x); v_pct := v_pct + v_x; end if;
  end if;

  -- express e urgente
  if coalesce(d ->> 'tipo', 'express') = 'express' then
    v_x := privado.pol_num('preco_express_pct', 0, v_cli, null, v_tp);
    if v_x <> 0 then v_pcts := v_pcts || jsonb_build_object('rotulo', 'Express', 'pct', v_x); v_pct := v_pct + v_x; end if;
  end if;
  if coalesce((d ->> 'urgente')::boolean, false) then
    v_x := privado.pol_num('preco_urgente_pct', 20, v_cli, null, v_tp);
    if v_x <> 0 then v_pcts := v_pcts || jsonb_build_object('rotulo', 'Urgente', 'pct', v_x); v_pct := v_pct + v_x; end if;
  end if;

  -- zonas (raios com dinâmica de preço): algum ponto dentro do raio
  v_somar := privado.pol_txt('zona_combinar', 'maior', v_cli, null, v_tp) = 'somar';
  select coalesce(case when v_somar then sum(z.fator_pct) else max(z.fator_pct) end, 0),
         coalesce(case when v_somar then sum(z.adicional) else max(z.adicional) end, 0),
         coalesce(array_agg(z.nome), '{}')
    into v_zp, v_za, v_znomes
    from public.zonas z
   where z.ativa and (z.organizacao_id is null or z.organizacao_id = v_org) and (z.cliente_id = v_cli
          or (z.cliente_id is null and not (privado.pol_bool('zona_cliente_exclusiva', false, v_cli, null, v_tp)
                                            and exists (select 1 from public.zonas zz where zz.ativa and zz.cliente_id = v_cli and (zz.organizacao_id is null or zz.organizacao_id = v_org)))))
     and exists (select 1 from jsonb_array_elements(coalesce(d -> 'pontos', '[]')) x
                  where privado.dist_m(z.lat, z.lng, (x ->> 'lat')::double precision, (x ->> 'lng')::double precision) <= z.raio_m);
  if v_za <> 0 then v_linhas := v_linhas || jsonb_build_object('rotulo', 'Zona', 'detalhe', array_to_string(v_znomes, ', '), 'fixo', true, 'valor', v_za); v_fixos := v_fixos + v_za; end if;
  if v_zp <> 0 then v_pcts := v_pcts || jsonb_build_object('rotulo', 'Zona: ' || array_to_string(v_znomes, ', '), 'pct', v_zp); v_pct := v_pct + v_zp; end if;

  -- horário de pico (pelo horário da coleta)
  select f.fator_pct, f.adicional, f.nome into v_hp, v_ha, v_hnome
    from public.faixas_horario f
   where f.ativa and (f.organizacao_id is null or f.organizacao_id = v_org) and (f.cliente_id is null or f.cliente_id = v_cli)
     and extract(dow from v_quando at time zone privado.fuso_org(v_org))::int = any (f.dias)
     and (case when f.fim > f.inicio
               then (v_quando at time zone privado.fuso_org(v_org))::time >= f.inicio and (v_quando at time zone privado.fuso_org(v_org))::time < f.fim
               else (v_quando at time zone privado.fuso_org(v_org))::time >= f.inicio or (v_quando at time zone privado.fuso_org(v_org))::time < f.fim end)
   order by (f.cliente_id is null), f.fator_pct desc, f.adicional desc limit 1;
  if coalesce(v_ha, 0) <> 0 then v_linhas := v_linhas || jsonb_build_object('rotulo', v_hnome, 'fixo', true, 'valor', v_ha); v_fixos := v_fixos + v_ha; end if;
  if coalesce(v_hp, 0) <> 0 then v_pcts := v_pcts || jsonb_build_object('rotulo', v_hnome, 'pct', v_hp); v_pct := v_pct + v_hp; end if;

  -- regras extras da empresa e da plataforma (blocos montados no editor)
  for v_pt in select * from jsonb_array_elements(privado.regras_extras_linhas('preco', v_org, jsonb_build_object(
      'quando', v_quando, 'tipo', v_tp, 'cliente', v_cli, 'veiculo', d ->> 'veiculo', 'urgente', coalesce((d ->> 'urgente')::boolean, false),
      'km', v_km, 'coletas', v_ncol, 'entregas', v_nent, 'volumes', v_pac, 'kg', v_tax, 'subtotal', v_sub,
      'declarado', (select coalesce(sum(coalesce((i ->> 'quantidade')::int, 1) * coalesce((i ->> 'valor_declarado')::numeric, 0)), 0) from jsonb_array_elements(coalesce(d -> 'itens', '[]')) i)))) loop
    v_linhas := v_linhas || v_pt; v_fixos := v_fixos + (v_pt ->> 'valor')::numeric;
  end loop;
  v_total := v_sub * (1 + v_pct / 100.0) + v_fixos;
  v_min := privado.pol_num('valor_minimo', 0, v_cli, null, v_tp);
  v_total := privado.arredondar(greatest(v_total, v_min));
  perform set_config('pwex.regras', coalesce(v_guc, ''), true);
  return jsonb_build_object(
    'linhas', v_linhas, 'percentuais', v_pcts, 'subtotal', round(v_sub + v_fixos, 2), 'acrescimo_pct', v_pct,
    'minimo', v_min, 'total', v_total, 'trajeto', case when v_reta then 'reta' else 'ruas' end, 'modo_distancia', case when v_fixo_cliente then 'fixo' when v_soma then 'soma_entregas' else 'rota' end, 'km', v_km, 'distancia_m', round(v_dist),
    'coletas', v_ncol, 'entregas', v_nent, 'volumes', v_pac, 'peso_real_kg', round(v_real, 2), 'peso_cubado_kg', round(v_cub, 2),
    'peso_taxado_kg', v_tax, 'perigoso', v_perig, 'calculado_em', now());
end;
$$;
create or replace function privado.contexto_rota(p_corrida uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('entregas', (select count(*) from public.paradas where corrida_id = c.id and tipo = 'entrega'),
           'coletas', (select count(*) from public.paradas where corrida_id = c.id and tipo = 'coleta'),
           'km', round(coalesce(c.distancia_planejada_m, 0) / 1000.0, 1), 'valor', c.valor, 'urgente', c.urgente,
           'planejada', c.agendada_para is not null, 'hora', extract(hour from coalesce(c.agendada_para, now()) at time zone privado.fuso_org(c.organizacao_id)),
           'dia_semana', extract(isodow from coalesce(c.agendada_para, now()) at time zone privado.fuso_org(c.organizacao_id)),
           'pedidos', (select count(distinct pedido_id) from public.paradas where corrida_id = c.id and pedido_id is not null))
    from public.corridas c where c.id = p_corrida;
$$;
create or replace function privado.dia_local(p timestamptz)
returns date language sql stable security definer set search_path = '' as $$ select (p at time zone privado.fuso())::date $$;

-- Resumo da folha de todos os motoboys num intervalo
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
      left join public.corridas c on c.motoboy_id = pf.id and c.status = 'concluida' and c.teste = p_teste
                                 and privado.dia_local(c.concluida_em) between p_inicio and p_fim
     where 'motoboy' = any (pf.papeis)
     group by pf.id
    ) t
  ), '[]'::jsonb);
end;
$$;
create or replace function privado.regra_vale(r public.regras_extras, x jsonb)
returns boolean language plpgsql stable set search_path = '' as $$
declare c jsonb := coalesce(r.condicoes, '{}'); v_q timestamptz := coalesce(nullif(x ->> 'quando', '')::timestamptz, now());
  v_h time := (v_q at time zone privado.fuso_valido(coalesce(x ->> 'fuso', privado.fuso())))::time; v_dow int := extract(dow from v_q at time zone privado.fuso_valido(coalesce(x ->> 'fuso', privado.fuso())))::int;
begin
  if jsonb_typeof(c -> 'dias') = 'array' and jsonb_array_length(c -> 'dias') > 0 and not (c -> 'dias') @> to_jsonb(v_dow) then return false; end if;
  if nullif(c ->> 'de', '') is not null and nullif(c ->> 'ate', '') is not null then
    if (c ->> 'ate')::time > (c ->> 'de')::time then
      if not (v_h >= (c ->> 'de')::time and v_h < (c ->> 'ate')::time) then return false; end if;
    elsif not (v_h >= (c ->> 'de')::time or v_h < (c ->> 'ate')::time) then return false; end if;
  end if;
  if jsonb_typeof(c -> 'tipos') = 'array' and jsonb_array_length(c -> 'tipos') > 0 and not (c -> 'tipos') ? coalesce(x ->> 'tipo', 'padrao') then return false; end if;
  if jsonb_typeof(c -> 'clientes') = 'array' and jsonb_array_length(c -> 'clientes') > 0 and not (c -> 'clientes') ? coalesce(x ->> 'cliente', '') then return false; end if;
  if jsonb_typeof(c -> 'motoboys') = 'array' and jsonb_array_length(c -> 'motoboys') > 0 and not (c -> 'motoboys') ? coalesce(x ->> 'motoboy', '') then return false; end if;
  if jsonb_typeof(c -> 'veiculos') = 'array' and jsonb_array_length(c -> 'veiculos') > 0 and not (c -> 'veiculos') ? coalesce(x ->> 'veiculo', '') then return false; end if;
  if c ? 'urgente' and (c ->> 'urgente')::boolean is distinct from coalesce((x ->> 'urgente')::boolean, false) then return false; end if;
  if nullif(c ->> 'km_min', '') is not null and coalesce((x ->> 'km')::numeric, 0) < (c ->> 'km_min')::numeric then return false; end if;
  if nullif(c ->> 'km_max', '') is not null and coalesce((x ->> 'km')::numeric, 0) > (c ->> 'km_max')::numeric then return false; end if;
  return true;
end;
$$;
create or replace function privado.regras_extras_linhas(p_alvo text, p_org uuid, x jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r public.regras_extras%rowtype; v_out jsonb := '[]'; v_q numeric; v_val numeric; v_base numeric;
begin
  x := coalesce(x, '{}') || jsonb_build_object('fuso', privado.fuso_org(p_org));
  for r in select * from public.regras_extras where ativo and alvo = p_alvo and (organizacao_id is null or organizacao_id = p_org) order by ordem, criado_em loop
    if not privado.regra_vale(r, x) then continue; end if;
    v_q := case r.unidade when 'fixo' then 1 when 'km' then coalesce((x ->> 'km')::numeric, 0)
             when 'ponto' then coalesce((x ->> 'coletas')::numeric, 0) + coalesce((x ->> 'entregas')::numeric, 0)
             when 'coleta' then coalesce((x ->> 'coletas')::numeric, 0) when 'entrega' then coalesce((x ->> 'entregas')::numeric, 0)
             when 'volume' then coalesce((x ->> 'volumes')::numeric, 0) when 'kg' then coalesce((x ->> 'kg')::numeric, 0)
             when 'minuto_parado' then coalesce((x ->> 'minutos_parado')::numeric, 0)
             else null end;
    if v_q is not null then
      v_q := greatest(0, v_q - r.franquia);
      v_val := round(v_q * r.valor, 2);
    else
      v_base := case r.unidade when 'pct_subtotal' then coalesce((x ->> 'subtotal')::numeric, 0)
                               when 'pct_declarado' then coalesce((x ->> 'declarado')::numeric, 0)
                               when 'pct_rota' then coalesce((x ->> 'valor_rota')::numeric, 0) else 0 end;
      v_val := round(greatest(0, v_base - r.franquia) * r.valor / 100, 2);
    end if;
    if r.minimo is not null and v_val <> 0 then v_val := greatest(v_val, r.minimo); end if;
    if r.maximo is not null then v_val := least(v_val, r.maximo); end if;
    if v_val = 0 then continue; end if;
    v_out := v_out || jsonb_build_object('chave', 'extra_' || r.id, 'rotulo', r.nome, 'valor', v_val, 'extra', true, 'fixo', true,
      'limitar', r.limitar_ao_valor, 'unidade', r.unidade, 'unit', r.valor, 'qtd', v_q,
      'detalhe', case when v_q is not null and r.unidade <> 'fixo' then format('%s %s × R$ %s', round(v_q, 2), replace(r.unidade, '_', ' '), r.valor)
                      when v_q is null then format('%s%% de R$ %s', r.valor, round(v_base, 2)) end);
  end loop;
  return v_out;
end;
$$;
create or replace function public.dev_saude()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_cron jsonb := '[]'; v_mig jsonb := '[]';
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  begin
    execute $q$select coalesce(jsonb_agg(jsonb_build_object('nome', j.jobname, 'quando', j.schedule, 'ativa', j.active,
               'ultima', (select max(d.start_time) from cron.job_run_details d where d.jobid = j.jobid),
               'falhas_24h', (select count(*) from cron.job_run_details d where d.jobid = j.jobid and d.status = 'failed' and d.start_time > now() - interval '1 day'),
               'erro', (select d.return_message from cron.job_run_details d where d.jobid = j.jobid and d.status = 'failed' order by d.start_time desc limit 1),
               'erro_em', (select max(d.start_time) from cron.job_run_details d where d.jobid = j.jobid and d.status = 'failed'))
               order by j.jobname), '[]') from cron.job j$q$ into v_cron;
  exception when others then v_cron := '[]';
  end;
  begin
    execute $q$select coalesce(jsonb_agg(jsonb_build_object('nome', nome, 'em', aplicada_em) order by aplicada_em desc), '[]') from (select * from controle.migracoes order by aplicada_em desc limit 8) m$q$ into v_mig;
  exception when others then v_mig := '[]';
  end;
  return jsonb_build_object(
    'banco_mb', round(pg_database_size(current_database()) / 1048576.0, 1),
    'tabelas', (select coalesce(jsonb_agg(jsonb_build_object('nome', t.relname, 'mb', round(pg_total_relation_size(t.oid) / 1048576.0, 1), 'linhas', t.reltuples::bigint)
                  order by pg_total_relation_size(t.oid) desc), '[]')
                  from (select c.oid, c.relname, c.reltuples from pg_class c join pg_namespace n on n.oid = c.relnamespace
                         where n.nspname = 'public' and c.relkind = 'r' order by pg_total_relation_size(c.oid) desc limit 10) t),
    'pings_1h', (select count(*) from public.localizacoes where registrado_em > now() - interval '1 hour'),
    'pings_24h', (select count(*) from public.localizacoes where registrado_em > now() - interval '1 day'),
    'motoboys_online', (select count(*) from public.motoboys where status::text <> 'offline'),
    'contas', (select count(*) from public.perfis),
    'empresas', (select count(*) from public.organizacoes),
    'rotas_ativas', (select count(*) from public.corridas where status::text in ('aceita', 'em_andamento')),
    'emergencias_abertas', (select count(*) from public.emergencias where resolvida_em is null),
    'mensagens_24h', (select count(*) from public.chat_mensagens where criada_em > now() - interval '1 day'),
    'tarefas', v_cron, 'migracoes', v_mig, 'agora', now());
end;
$$;
