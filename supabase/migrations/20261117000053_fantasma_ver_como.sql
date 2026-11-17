-- Lote 50 · Fantasma completo: aparelho, ajustes nas telas, nível do ajuste, ver como, novidades por plataforma

create or replace function privado.aparelho()
returns text language sql stable security definer set search_path = '' as $$
  select case when coalesce(nullif(current_setting('request.headers', true), '')::json ->> 'x-pwex-versao', '') <> '' then 'app' else 'site' end;
$$;
revoke execute on function privado.aparelho() from public, anon, authenticated;

create or replace function privado.decide(p_pessoa uuid, p_chave text, p_ctx jsonb default '{}')
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_papeis  public.papel_usuario[];
  v_org     uuid;
  v_cliente uuid;
  v_teste   boolean;
  v_dev     boolean := false;
  v_tz      text;
  v_agora   timestamp;
  r         public.regras_dev%rowtype;
begin
  if p_pessoa is not null then
    select p.papeis, p.organizacao_id, p.empresa_id, coalesce(p.modo_teste, false) into v_papeis, v_org, v_cliente, v_teste
      from public.perfis p where p.id = p_pessoa;
    v_dev := coalesce('dev' = any (v_papeis), false);
  end if;
  v_org := coalesce(nullif(p_ctx ->> 'org', '')::uuid, v_org);
  v_cliente := coalesce(nullif(p_ctx ->> 'cliente', '')::uuid, v_cliente);
  if v_cliente is not null and v_org is null then select organizacao_id into v_org from public.empresas where id = v_cliente; end if;
  for r in
    select * from public.regras_dev x
     where x.chave = p_chave and x.ativo
       and (x.valida_de is null or x.valida_de <= now()) and (x.valida_ate is null or x.valida_ate > now())
       and case
             when v_dev then x.escopo = 'pessoa' and x.alvo = p_pessoa::text
             else (x.escopo = 'global')
               or (x.escopo = 'empresa' and x.alvo = v_org::text)
               or (x.escopo = 'cliente' and x.alvo = v_cliente::text)
               or (x.escopo = 'pessoa'  and x.alvo = p_pessoa::text)
               or (x.escopo = 'papel'   and x.alvo = any (v_papeis::text[]))
           end
     order by case x.escopo when 'pessoa' then 1 when 'cliente' then 2 when 'empresa' then 3 when 'papel' then 4 else 5 end, x.atualizado_em desc
  loop
    -- condições: papéis, modo teste, aparelho, dias e horário (no fuso da empresa)
    if jsonb_typeof(r.condicoes -> 'papeis') = 'array' and jsonb_array_length(r.condicoes -> 'papeis') > 0
       and not exists (select 1 from jsonb_array_elements_text(r.condicoes -> 'papeis') e where e = any (coalesce(v_papeis::text[], '{}'))) then continue; end if;
    if r.condicoes ? 'teste' and (r.condicoes ->> 'teste')::boolean is distinct from coalesce(v_teste, false) then continue; end if;
    if coalesce(r.condicoes ->> 'aparelho', '') <> '' and r.condicoes ->> 'aparelho' <> coalesce(nullif(p_ctx ->> 'aparelho', ''), privado.aparelho()) then continue; end if;
    if r.condicoes ?| array['dias', 'de', 'ate'] then
      if v_tz is null then
        v_tz := case when p_chave = 'fuso_horario' or v_org is null then 'America/Sao_Paulo' else coalesce(privado.fuso_org(v_org), 'America/Sao_Paulo') end;
        v_agora := now() at time zone v_tz;
      end if;
      if jsonb_typeof(r.condicoes -> 'dias') = 'array' and jsonb_array_length(r.condicoes -> 'dias') > 0
         and not exists (select 1 from jsonb_array_elements_text(r.condicoes -> 'dias') e where e::int = extract(isodow from v_agora)::int) then continue; end if;
      if coalesce(r.condicoes ->> 'de', '') <> '' and coalesce(r.condicoes ->> 'ate', '') <> '' then
        if (r.condicoes ->> 'de')::time <= (r.condicoes ->> 'ate')::time then
          if not (v_agora::time >= (r.condicoes ->> 'de')::time and v_agora::time < (r.condicoes ->> 'ate')::time) then continue; end if;
        else -- atravessa a meia-noite
          if not (v_agora::time >= (r.condicoes ->> 'de')::time or v_agora::time < (r.condicoes ->> 'ate')::time) then continue; end if;
        end if;
      end if;
    end if;
    return jsonb_build_object('valor', r.valor, 'regra', r.id, 'escopo', r.escopo, 'versao', r.versao,
      'motivo', 'Regra do Dev' || coalesce(': ' || nullif(r.porque, ''), '') ||
                case r.escopo when 'pessoa' then ' (só esta pessoa)' when 'cliente' then ' (este cliente)' when 'empresa' then ' (esta empresa)'
                              when 'papel' then ' (todos os ' || r.alvo || 's)' else ' (todo o sistema)' end);
  end loop;
  return null;
end;
$$;

create or replace function privado.ajustes_valendo(p_pessoa uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select public.ajustes() || coalesce((
    select jsonb_object_agg(k.chave, v -> 'valor')
      from (select distinct chave from public.regras_dev where ativo and chave !~ '^(modulo|acao|nivel):') k,
           lateral (select privado.decide(p_pessoa, k.chave, jsonb_build_object('org', public.minha_org())) v) x
     where v is not null), '{}'::jsonb);
$$;
revoke execute on function privado.ajustes_valendo(uuid) from public, anon, authenticated;

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
      select jsonb_object_agg(k, v) from jsonb_each(privado.ajustes_valendo(p.id)) e(k, v)
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
      'especial_cliente_edita_aprovado', privado.especial('especial_cliente_edita_aprovado', p.id),
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
create or replace function privado.nivel_ajuste(p_org uuid, p_chave text)
returns text language sql stable security definer set search_path = '' as $$
  with g as (select grupo, area from public.ajuste_grupos where chave = p_chave),
  c as (select pg.nivel, pg.organizacao_id, case split_part(pg.alvo, ':', 1) when 'chave' then 1 when 'grupo' then 2 else 3 end ordem
          from public.permissoes_gestor pg
         where (pg.organizacao_id = p_org or pg.organizacao_id is null)
           and (pg.alvo = 'chave:' || p_chave or pg.alvo = 'grupo:' || (select grupo from g) or pg.alvo = 'area:' || (select area from g)))
  select coalesce(privado.regra(auth.uid(), 'nivel:' || p_chave, jsonb_build_object('org', p_org)) ->> 'valor',
                  (select nivel from c order by ordem, (organizacao_id is null) limit 1),
                  case when (select area from g) = 'sistema' then 'oculto' else 'editar' end);
$$;

create or replace function public.dev_ver_como(p_pessoa uuid)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_claims text := current_setting('request.jwt.claims', true);
  v_sub    text := current_setting('request.jwt.claim.sub', true);
  v_uid    text := current_setting('request.uid', true);
  v_perfil jsonb; v_perm jsonb; v_nov jsonb; v_av jsonb;
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  if not exists (select 1 from public.perfis where id = p_pessoa) then raise exception 'pessoa_inexistente' using errcode = '22023'; end if;
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_pessoa, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_pessoa::text, true);
  perform set_config('request.uid', p_pessoa::text, true);
  begin
    v_perfil := public.meu_perfil();
    v_perm := public.minhas_permissoes();
    v_nov := public.minhas_novidades(20);
    v_av := public.avisos_para_mim();
  exception when others then
    perform set_config('request.jwt.claims', coalesce(v_claims, ''), true);
    perform set_config('request.jwt.claim.sub', coalesce(v_sub, ''), true);
    perform set_config('request.uid', coalesce(v_uid, ''), true);
    raise;
  end;
  perform set_config('request.jwt.claims', coalesce(v_claims, ''), true);
  perform set_config('request.jwt.claim.sub', coalesce(v_sub, ''), true);
  perform set_config('request.uid', coalesce(v_uid, ''), true);
  perform privado.anotar_dev('ver_como', 'abrir', p_pessoa::text);
  return jsonb_build_object('perfil', v_perfil - 'campos', 'permissoes', v_perm, 'novidades', v_nov, 'avisos', v_av);
end;
$$;
revoke execute on function public.dev_ver_como(uuid) from anon;

-- 5. novidades por plataforma (o site não mostra o que é só do app, e vice-versa)
drop function if exists public.minhas_novidades(int);
create or replace function public.minhas_novidades(p_limite int default 40, p_plataforma text default null)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'versao', n.versao, 'area', n.area, 'plataforma', n.plataforma, 'titulo', n.titulo, 'texto', n.texto, 'em', n.criado_em)
           order by n.criado_em desc, n.area), '[]')
    from (select * from public.novidades x
           where x.publicado and x.area = any (coalesce(privado.minhas_areas(auth.uid()), array['todos']))
             and (p_plataforma is null or x.plataforma in ('todas', p_plataforma))
           order by x.criado_em desc limit least(coalesce(p_limite, 40), 200)) n
   where privado.modulo_ligado('novidades', auth.uid());
$$;
grant execute on function public.minhas_novidades(int, text) to authenticated;
revoke execute on function public.minhas_novidades(int, text) from anon;


create table if not exists public.sinais (
  id             bigserial primary key,
  tipo           text not null,
  organizacao_id uuid,
  pessoa_id      uuid,
  em             timestamptz not null default now()
);
create index if not exists sinais_em on public.sinais (em);
alter table public.sinais enable row level security;
drop policy if exists sinais_leitura on public.sinais;
create policy sinais_leitura on public.sinais for select to authenticated using (
  public.is_dev() or pessoa_id = auth.uid()
  or (pessoa_id is null and (organizacao_id is null or organizacao_id = (select coalesce(p.organizacao_id, (select e.organizacao_id from public.empresas e where e.id = p.empresa_id)) from public.perfis p where p.id = auth.uid()))));
revoke all on public.sinais from anon;
grant select on public.sinais to authenticated;
do $$ begin alter publication supabase_realtime add table public.sinais; exception when others then null; end $$;

create or replace function privado.sinalizar(p_tipo text, p_org uuid default null, p_pessoa uuid default null, p_push boolean default true)
returns void language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  delete from public.sinais where em < now() - interval '1 day';
  insert into public.sinais (tipo, organizacao_id, pessoa_id) values (p_tipo, p_org, p_pessoa);
  if not p_push then return; end if;
  -- push silencioso para quem tem o app (o app recarrega o perfil e os avisos)
  for r in select t.motoboy_id from privado.fcm_tokens t join public.perfis p on p.id = t.motoboy_id
            where (p_pessoa is not null and p.id = p_pessoa)
               or (p_pessoa is null and (p_org is null or p.organizacao_id = p_org or p.empresa_id in (select id from public.empresas where organizacao_id = p_org)))
            limit 2000 loop
    perform privado.enviar_push(r.motoboy_id, jsonb_build_object('tipo', 'sinal', 'qual', p_tipo));
  end loop;
exception when others then
  raise warning 'sinalizar falhou: %', sqlerrm;
end;
$$;
revoke execute on function privado.sinalizar(text, uuid, uuid, boolean) from public, anon, authenticated;

create or replace function privado.trg_sinal()
returns trigger language plpgsql security definer set search_path = '' as $$
declare x jsonb := to_jsonb(coalesce(new, old)); a jsonb := case when tg_op = 'UPDATE' then to_jsonb(old) end;
begin
  case tg_table_name
    when 'avisos_dev' then perform privado.sinalizar('avisos', nullif(x ->> 'organizacao_id', '')::uuid);
    when 'organizacoes' then
      if tg_op = 'UPDATE' and (a ->> 'status') is distinct from (x ->> 'status') then perform privado.sinalizar('empresa', (x ->> 'id')::uuid); end if;
    when 'regras_dev' then
      perform privado.sinalizar('perfil',
        case when x ->> 'escopo' = 'empresa' then (x ->> 'alvo')::uuid when x ->> 'escopo' = 'cliente' then (select organizacao_id from public.empresas where id::text = x ->> 'alvo') end,
        case when x ->> 'escopo' = 'pessoa' then (x ->> 'alvo')::uuid end);
    when 'modulos' then perform privado.sinalizar('perfil');
    when 'modulos_empresa' then perform privado.sinalizar('perfil', (x ->> 'organizacao_id')::uuid);
    when 'perfis' then
      if tg_op = 'UPDATE' and ((a -> 'papeis') is distinct from (x -> 'papeis') or (a -> 'permissoes') is distinct from (x -> 'permissoes')
          or (a ->> 'cargo_id') is distinct from (x ->> 'cargo_id') or (a ->> 'organizacao_id') is distinct from (x ->> 'organizacao_id')) then
        perform privado.sinalizar('perfil', null, (x ->> 'id')::uuid);
      end if;
    else null;
  end case;
  return coalesce(new, old);
end;
$$;
do $$ declare t text; begin
  foreach t in array array['avisos_dev', 'organizacoes', 'regras_dev', 'modulos', 'modulos_empresa', 'perfis'] loop
    execute format('drop trigger if exists sinal_instantaneo on public.%I', t);
    execute format('create trigger sinal_instantaneo after insert or update or delete on public.%I for each row execute function privado.trg_sinal()', t);
  end loop;
end $$;

create or replace function public.dev_derrubar_sessoes(p_pessoa uuid default null, p_org uuid default null)
returns int language plpgsql security definer set search_path = '' as $$
declare v_ids uuid[]; n int := 0; m int := 0;
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  select array_agg(id) into v_ids from public.perfis
   where id <> auth.uid() and ((p_pessoa is not null and id = p_pessoa)
      or (p_org is not null and (organizacao_id = p_org or empresa_id in (select id from public.empresas where organizacao_id = p_org))));
  if v_ids is null then return 0; end if;
  if to_regclass('auth.refresh_tokens') is not null then
    execute 'delete from auth.refresh_tokens where user_id::uuid = any ($1)' using v_ids; get diagnostics m = row_count;
  end if;
  if to_regclass('auth.sessions') is not null then
    execute 'delete from auth.sessions where user_id = any ($1)' using v_ids; get diagnostics n = row_count;
  end if;
  -- quem foi desconectado sai na hora (site pelo tempo real, app pelo push)
  if p_pessoa is not null then perform privado.sinalizar('sessao', null, p_pessoa);
  else perform privado.sinalizar('sessao', p_org); end if;
  perform privado.anotar_dev('emergencia', 'derrubar_sessoes', coalesce(p_pessoa::text, p_org::text), jsonb_build_object('pessoas', cardinality(v_ids), 'sessoes', n));
  return cardinality(v_ids);
end;
$$;