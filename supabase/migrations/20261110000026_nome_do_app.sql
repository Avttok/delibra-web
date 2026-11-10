-- =====================================================================
-- Delibra · 0026: nome do app por empresa
--
--  • organizacoes.nome_app: o nome que aparece no lugar de "Delibra" (topo do app e do site,
--    atalho do celular, telas de entrar). Vazio = Delibra. O dono ou o Dev muda.
-- =====================================================================
set check_function_bodies = off;
alter table public.organizacoes add column if not exists nome_app text check (nome_app is null or char_length(nome_app) between 2 and 30);

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
    'organizacao', (select jsonb_build_object('id', o.id, 'nome', o.nome, 'nome_app', o.nome_app, 'logo', o.logo_url, 'cor', o.cor, 'status', o.status)
                      from public.organizacoes o where o.id = coalesce(case when 'dev' = any (p.papeis) then p.org_em_foco end, p.organizacao_id)),
    'configuracoes', coalesce((
      select jsonb_object_agg(k, v) from jsonb_each(public.ajustes()) e(k, v)
       where k in ('intervalo_corrida_s', 'intervalo_economia_s', 'disponivel_envio_min',
                       'disponivel_distancia_m', 'raio_chegada_m', 'teste_admin_ignora_local', 'oferta_segundos',
                       'quadro_mostra_enderecos', 'quadro_mostra_itens', 'simulador_ligado', 'simulador_velocidade_kmh',
                       'motoboy_edita_veiculo', 'mapa_offline_some_h', 'mapa_offline_esmaecer', 'veiculo_obrigatorio',
                       'rota_provedor', 'rota_perfil', 'chat_ligado', 'chat_geral', 'chat_fotos', 'ping_envio_s',
                       'chat_compartilhar', 'chat_compartilhar_tipos', 'chat_grupos_equipe', 'pagamento_na_plataforma', 'compartilhar_motoboy_resumo')
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
      'navegacao_na_notificacao', privado.pol_bool('navegacao_na_notificacao', true, null, p.id, null))
  )
  from public.perfis p
  left join public.motoboys m on m.id = p.id
  where p.id = auth.uid();
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
    nome_app  = case when p ? 'nome_app' then nullif(trim(p ->> 'nome_app'), '') else nome_app end
   where id = public.minha_org();
end;
$$;

drop function if exists public.definir_marca_organizacao(uuid, text, text);
create or replace function public.definir_marca_organizacao(p_org uuid, p_logo text default null, p_cor text default null, p_nome_app text default null, p_so_nome boolean default false)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not (public.is_dev() or (public.is_gestor_pleno() and p_org = public.minha_org())) then
    raise exception 'sem_permissao' using errcode = '42501';
  end if;
  if p_so_nome then
    update public.organizacoes set nome_app = nullif(trim(p_nome_app), '') where id = p_org;
  else
    update public.organizacoes set logo_url = nullif(trim(p_logo), ''), cor = coalesce(nullif(trim(p_cor), ''), cor) where id = p_org;
  end if;
end;
$$;
grant execute on function public.definir_marca_organizacao(uuid, text, text, text, boolean) to authenticated;

create or replace function public.marca_publica(p_slug text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('nome', o.nome, 'nome_app', o.nome_app, 'logo', o.logo_url, 'cor', o.cor)
    from public.organizacoes o where o.slug = p_slug and o.status in ('ativa', 'teste');
$$;
grant execute on function public.marca_publica(text) to anon, authenticated;

notify pgrst, 'reload schema';
