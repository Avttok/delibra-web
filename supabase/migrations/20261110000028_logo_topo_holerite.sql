-- =====================================================================
-- Delibra · 0028: tamanho da logo no topo, repositório do app e holerite
--
--  • organizacoes.logo_escala: o tamanho da logo da empresa no topo do app e do site
--    (0,8 a 2,6; o dono ajusta no editor do ícone, vendo a prévia).
--  • app_repo apontava para o repositório antigo da PW Express: agora Avttok/delibra-app.
--  • Holerite do motoboy: "cannot extract elements from a scalar" quando ele não vê valores
--    (ajustes vinham como null). Listas vazias agora são sempre listas.
-- =====================================================================
set check_function_bodies = off;

alter table public.organizacoes add column if not exists logo_escala numeric not null default 1.9 check (logo_escala between 0.8 and 2.6);

update public.configuracoes set valor = '"Avttok/delibra-app"' where chave = 'app_repo';
insert into public.configuracoes (chave, valor) values ('app_repo', '"Avttok/delibra-app"') on conflict (chave) do nothing;

create or replace function privado.lista(j jsonb)
returns jsonb language sql immutable set search_path = '' as $$
  select case when jsonb_typeof(j) = 'array' then j else '[]'::jsonb end;
$$;

create or replace function public.versao_app()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'exigida', privado.cfg_num('app_versao_exigida', 0)::int,
    'forcar', privado.cfg_bool('app_forcar_versao', true),
    'dev_livre', privado.cfg_bool('app_dev_livre', true) and coalesce(public.is_dev(), false),
    'url', case when privado.cfg_num('app_versao_exigida', 0)::int > 0 then
             format('https://github.com/%s/releases/download/build-%s/Delibra-motoboy-build%s.apk',
                    privado.cfg_txt('app_repo', 'Avttok/delibra-app'), privado.cfg_num('app_versao_exigida', 0)::int, privado.cfg_num('app_versao_exigida', 0)::int) end);
$$;

create or replace function privado.holerite_para_motoboy(v jsonb)
returns jsonb language plpgsql immutable set search_path = '' as $$
declare
  v_aj    numeric := coalesce((select sum((a ->> 'valor')::numeric) from jsonb_array_elements(privado.lista(v -> 'ajustes')) a), 0);
  v_base  numeric := coalesce((select sum(coalesce((i ->> 'valor')::numeric, 0)) from jsonb_array_elements(privado.lista(v -> 'itens')) i), 0);
  v_n     int := jsonb_array_length(privado.lista(v -> 'itens'));
  v_itens jsonb := '[]';
  v_resto numeric := v_aj;
  i       jsonb;
  k       int := 0;
  v_parte numeric;
begin
  for i in select * from jsonb_array_elements(privado.lista(v -> 'itens')) loop
    k := k + 1;
    if i ->> 'valor' is not null and v_aj <> 0 and v_n > 0 then
      v_parte := case when k = v_n then v_resto
                      when v_base > 0 then round(v_aj * coalesce((i ->> 'valor')::numeric, 0) / v_base, 2)
                      else round(v_aj / v_n, 2) end;
      v_resto := v_resto - v_parte;
      i := jsonb_set(i, '{valor}', to_jsonb(round((i ->> 'valor')::numeric + v_parte, 2)));
    end if;
    v_itens := v_itens || (i - 'ajuste' - 'ajuste_motivo' - 'calculo');
  end loop;
  return (v - 'ajustes' - 'ajustes_rotas' - 'calculado') || jsonb_build_object('itens', v_itens);
end;
$$;

create or replace function public.meu_holerite(p_inicio date, p_fim date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_teste boolean := coalesce((select modo_teste from public.motoboys where id = auth.uid()), false);
  v_ve    boolean := privado.ve_valores(auth.uid());
  v       jsonb;
begin
  if not public.tem_papel('motoboy'::public.papel_usuario) then raise exception 'apenas_motoboy' using errcode = '42501'; end if;
  if not privado.pol_bool('motoboy_ve_holerite', true, null, auth.uid(), null) then raise exception 'holerite_oculto' using errcode = '42501'; end if;
  v := privado.holerite_json(auth.uid(), p_inicio, p_fim, v_teste, v_ve);
  -- holerite fechado: mostra o total (se o gestor deixar), mesmo sem os valores de cada rota
  if not v_ve and v ->> 'status' in ('fechado', 'pago') and privado.pol_bool('motoboy_ve_holerite_valor', true, null, auth.uid(), null) then
    v := v || jsonb_build_object('total', (select total from public.holerites where motoboy_id = auth.uid() and teste = v_teste and inicio = p_inicio and fim = p_fim));
  end if;
  -- "só depois de fechar": nada de valor enquanto o período está aberto
  if privado.pol_txt('motoboy_holerite_quando', 'aberto', null, auth.uid(), null) = 'fechado' and coalesce(v ->> 'status', 'aberto') = 'aberto' then
    v := (v - 'total') || jsonb_build_object('valores_visiveis', false, 'itens',
      coalesce((select jsonb_agg(i - 'valor' - 'ajuste' - 'ajuste_motivo' - 'calculo') from jsonb_array_elements(privado.lista(v -> 'itens')) i), '[]'));
  end if;
  return privado.holerite_para_motoboy(v);
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
    'organizacao', (select jsonb_build_object('id', o.id, 'nome', o.nome, 'nome_app', o.nome_app, 'logo', o.logo_url, 'logo_escala', o.logo_escala, 'cor', o.cor, 'status', o.status)
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
    nome_app  = case when p ? 'nome_app' then nullif(trim(p ->> 'nome_app'), '') else nome_app end,
    logo_escala = case when p ? 'logo_escala' then least(greatest((p ->> 'logo_escala')::numeric, 0.8), 2.6) else logo_escala end
   where id = public.minha_org();
end;
$$;

drop function if exists public.definir_marca_organizacao(uuid, text, text, text, boolean);
create or replace function public.definir_marca_organizacao(p_org uuid, p_logo text default null, p_cor text default null, p_nome_app text default null,
                                                           p_so_nome boolean default false, p_escala numeric default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not (public.is_dev() or (public.is_gestor_pleno() and p_org = public.minha_org())) then
    raise exception 'sem_permissao' using errcode = '42501';
  end if;
  if p_so_nome then
    update public.organizacoes set nome_app = nullif(trim(p_nome_app), '') where id = p_org;
  else
    update public.organizacoes set logo_url = nullif(trim(p_logo), ''), cor = coalesce(nullif(trim(p_cor), ''), cor),
      logo_escala = coalesce(least(greatest(p_escala, 0.8), 2.6), logo_escala) where id = p_org;
  end if;
end;
$$;
grant execute on function public.definir_marca_organizacao(uuid, text, text, text, boolean, numeric) to authenticated;

create or replace function public.marca_publica(p_slug text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('nome', o.nome, 'nome_app', o.nome_app, 'logo', o.logo_url, 'cor', o.cor, 'logo_escala', o.logo_escala)
    from public.organizacoes o where o.slug = p_slug and o.status in ('ativa', 'teste');
$$;
grant execute on function public.marca_publica(text) to anon, authenticated;

-- ===================================================================== Dev oculto some das listas
-- Com "Ficar oculto" ligado, o Dev não aparece para ninguém: equipe, mapa, contatos do chat,
-- escolha de motoboy. Só ele (e outro Dev) o vê. Nas conversas em que já está, segue como "Dev".
drop policy if exists dev_oculto_some on public.perfis;
create policy dev_oculto_some on public.perfis as restrictive for select to authenticated
  using (not public.dev_oculto_para_mim(id));
drop policy if exists dev_oculto_some on public.motoboys;
create policy dev_oculto_some on public.motoboys as restrictive for select to authenticated
  using (not public.dev_oculto_para_mim(id));

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
   where public.is_gestor() and public.ve_pessoa(p.id) and not public.dev_oculto_para_mim(p.id)
     and not (cardinality(p.papeis) = 0
              and exists (select 1 from public.cadastros_cliente c where c.perfil_id = p.id and c.status in ('pendente', 'recusado')))
   order by p.nome;
$$;

create or replace function public.chat_contatos()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_eu     public.perfis%rowtype;
  v_gestor boolean := public.is_gestor();
begin
  select * into v_eu from public.perfis where id = auth.uid();
  if v_eu.id is null or not privado.cfg_bool('chat_ligado', true) then return '[]'::jsonb; end if;
  if 'cliente' = any (v_eu.papeis) and not public.chat_equipe() and not privado.pol_bool('cliente_pode_chat', true, v_eu.empresa_id) then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', p.id, 'nome', public.nome_publico(p.id), 'foto', public.foto_publica(p.id), 'oculto', public.dev_oculto_para_mim(p.id),
             'papeis', case when public.dev_oculto_para_mim(p.id) then '["dev"]'::jsonb else to_jsonb(p.papeis) end,
             'status', (select m.status from public.motoboys m where m.id = p.id),
             'empresa', (select e.nome from public.empresas e where e.id = p.empresa_id)) order by public.nome_publico(p.id))
      from public.perfis p
     where p.id <> v_eu.id and not public.dev_oculto_para_mim(p.id)
       and (public.ve_pessoa(p.id) or ('dev' = any (p.papeis) and v_gestor))
       and not exists (select 1 from auth.users u where u.id = p.id and u.banned_until > now())
       and (case
              when v_gestor then true
              when public.chat_equipe() then (p.papeis && array['gestor', 'dev', 'supervisor']::public.papel_usuario[])
                                             or ('motoboy' = any (p.papeis) and privado.cfg_bool('chat_motoboy_direta', true))
              else p.papeis && array['gestor']::public.papel_usuario[] end)), '[]'::jsonb);
end;
$$;


notify pgrst, 'reload schema';
