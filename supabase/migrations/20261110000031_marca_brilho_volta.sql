-- =====================================================================
-- Delibra · 0031: modo em branco sem empresa, brilho e fonte da marca, volta do motoboy
--
--  • Modo "Em branco" do Dev: o perfil não traz empresa nenhuma (nem a dele).
--  • organizacoes: logo_original_url (reajustar sem reenviar), logo_brilho_cor e logo_brilho
--    (cor e força do brilho atrás da logo) e fonte_nome (fonte do nome no topo).
--  • pag_volta: paga a volta do motoboy, da última parada até o ponto de partida (km × valor).
--  • definir_distancias_pedido: grava a distância pelas ruas de cada entrega e recalcula
--    (para trocar o pedido de "linha reta" para "pelas ruas" na hora).
-- =====================================================================
set check_function_bodies = off;

alter table public.organizacoes add column if not exists logo_original_url text;
alter table public.organizacoes add column if not exists logo_brilho_cor text;
alter table public.organizacoes add column if not exists logo_brilho numeric not null default 0.55 check (logo_brilho between 0 and 1);
alter table public.organizacoes add column if not exists fonte_nome text;

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
    'organizacao', (select jsonb_build_object('id', o.id, 'nome', o.nome, 'nome_app', o.nome_app, 'logo', o.logo_url, 'logo_escala', o.logo_escala, 'logo_original', o.logo_original_url, 'brilho_cor', o.logo_brilho_cor, 'brilho', o.logo_brilho, 'fonte', o.fonte_nome, 'cor', o.cor, 'status', o.status)
                      from public.organizacoes o where o.id = case when 'dev' = any (p.papeis) and p.dev_vazio then null else coalesce(case when 'dev' = any (p.papeis) then p.org_em_foco end, p.organizacao_id) end),
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
    logo_original_url = case when p ? 'logo_original_url' then nullif(p ->> 'logo_original_url', '') else logo_original_url end,
    logo_brilho_cor = case when p ? 'brilho_cor' then nullif(p ->> 'brilho_cor', '') else logo_brilho_cor end,
    logo_brilho = case when p ? 'brilho' then least(greatest((p ->> 'brilho')::numeric, 0), 1) else logo_brilho end,
    fonte_nome = case when p ? 'fonte' then nullif(p ->> 'fonte', '') else fonte_nome end,
    logo_escala = case when p ? 'logo_escala' then least(greatest((p ->> 'logo_escala')::numeric, 0.8), 2.6) else logo_escala end
   where id = public.minha_org();
end;
$$;

-- Dev: as mesmas chaves para qualquer empresa (vazio/ausente = não mexe).
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
    nome_app = case when p ? 'nome_app' then nullif(trim(p ->> 'nome_app'), '') else nome_app end
  where id = p_org;
end;
$$;
revoke execute on function public.dev_marca_organizacao(uuid, jsonb) from public, anon;
grant execute on function public.dev_marca_organizacao(uuid, jsonb) to authenticated;

create or replace function public.marca_publica(p_slug text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('nome', o.nome, 'nome_app', o.nome_app, 'logo', o.logo_url, 'cor', o.cor, 'logo_escala', o.logo_escala,
                            'brilho_cor', o.logo_brilho_cor, 'brilho', o.logo_brilho, 'fonte', o.fonte_nome)
    from public.organizacoes o where o.slug = p_slug and o.status in ('ativa', 'teste');
$$;
grant execute on function public.marca_publica(text) to anon, authenticated;

create or replace function privado.calcular_pagamento(p_corrida uuid, p_motoboy uuid default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  c        public.corridas%rowtype;
  v_m      uuid;
  v_ant    text := current_setting('pwex.regras', true);
  v_rr     jsonb;
  v_modos  text[];
  v_comb   text;
  v_parte  jsonb;
  v_partes jsonb := '[]';
  v_vals   numeric[] := '{}';
  v_t      numeric;
  v_acr    numeric; v_acrp numeric;
  v_teto   numeric;
  v_modo   text;
  v_res    jsonb;
  v_vkm    numeric; v_vm numeric; v_vv numeric; v_ult public.paradas%rowtype; v_ini public.paradas%rowtype;
begin
  select * into c from public.corridas where id = p_corrida;
  if not found then return null; end if;
  c.valor := coalesce(nullif(current_setting('pwex.valor_rota', true), '')::numeric, c.valor);
  v_m := coalesce(p_motoboy, c.motoboy_id);
  v_rr := coalesce(nullif(current_setting('pwex.pag_regras_rota', true), '')::jsonb, c.pag_regras, '{}');
  if v_rr <> '{}' then
    perform set_config('pwex.regras', (coalesce(nullif(v_ant, '')::jsonb, '{}') || v_rr)::text, true);
  end if;
  begin
    select array_agg(x) into v_modos from jsonb_array_elements_text(
      case when jsonb_typeof(privado.pol('pag_modos', c.empresa_id, v_m, c.tipo_pedido)) = 'array' then privado.pol('pag_modos', c.empresa_id, v_m, c.tipo_pedido) else '[]' end) x
     where x in ('zonas', 'rota', 'percentual', 'por_entrega', 'fixo');
    if coalesce(array_length(v_modos, 1), 0) = 0 then v_modos := array[privado.pol_txt('pag_modo', 'zonas', c.empresa_id, v_m, c.tipo_pedido)]; end if;
    v_comb := privado.pol_txt('pag_combinar', 'soma', c.empresa_id, v_m, c.tipo_pedido);
    v_acr := privado.pol_num('pag_acrescimo_rota', 0, c.empresa_id, v_m, c.tipo_pedido);
    v_acrp := privado.pol_num('pag_acrescimo_pct', 0, c.empresa_id, v_m, c.tipo_pedido);
    foreach v_modo in array v_modos loop
      v_parte := case v_modo when 'por_entrega' then privado.pag_por_entrega(p_corrida, v_m)
                             when 'fixo' then privado.pag_fixo(p_corrida, v_m)
                             else privado.calcular_pagamento_um(p_corrida, v_m, v_modo) end;
      v_partes := v_partes || jsonb_build_array(v_parte || jsonb_build_object('parte', v_modo));
      v_vals := v_vals || coalesce((v_parte ->> 'calculado')::numeric, (v_parte ->> 'total')::numeric, 0);
    end loop;
    v_teto := greatest(coalesce(c.valor, 0), 0);
    if array_length(v_modos, 1) = 1 and v_acr = 0 and v_acrp = 0 then
      v_res := v_partes -> 0;
    else
      v_t := case v_comb when 'maior' then (select max(u) from unnest(v_vals) u)
                         when 'menor' then (select min(u) from unnest(v_vals) u)
                         when 'media' then (select round(avg(u), 2) from unnest(v_vals) u)
                         else (select sum(u) from unnest(v_vals) u) end;
      v_t := round(v_t * (1 + v_acrp / 100) + v_acr, 2);
      v_res := jsonb_build_object('modo', 'combinado', 'combinar', v_comb, 'partes', v_partes, 'acrescimo', v_acr, 'acrescimo_pct', v_acrp,
                                  'valor_rota', coalesce(c.valor, 0), 'teto', v_teto, 'calculado', v_t, 'limitado', v_t > v_teto, 'total', least(v_t, v_teto));
    end if;
    -- volta: da última parada até o ponto de partida (a primeira coleta), em km × valor
    if privado.pol_bool('pag_volta', false, c.empresa_id, v_m, c.tipo_pedido) then
      select * into v_ult from public.paradas where corrida_id = p_corrida order by ordem desc limit 1;
      select * into v_ini from public.paradas where corrida_id = p_corrida and tipo = 'coleta' order by ordem limit 1;
      if v_ult.id is not null and v_ini.id is not null and v_ult.id <> v_ini.id then
        v_vm := privado.dist_m(v_ult.lat, v_ult.lng, v_ini.lat, v_ini.lng) * privado.pol_num('fator_rua', 1.3, c.empresa_id, v_m, c.tipo_pedido);
        v_vkm := privado.pol_num('pag_volta_valor_km', privado.pol_num('pag_valor_km', 2, c.empresa_id, v_m, c.tipo_pedido), c.empresa_id, v_m, c.tipo_pedido);
        v_vv := round(round(v_vm / 1000.0, 2) * v_vkm * privado.pol_num('pag_volta_pct', 100, c.empresa_id, v_m, c.tipo_pedido) / 100, 2);
        v_t := coalesce((v_res ->> 'calculado')::numeric, (v_res ->> 'total')::numeric, 0) + v_vv;
        v_res := v_res || jsonb_build_object('volta', jsonb_build_object('km', round(v_vm / 1000.0, 2), 'valor_km', v_vkm,
                     'pct', privado.pol_num('pag_volta_pct', 100, c.empresa_id, v_m, c.tipo_pedido), 'valor', v_vv),
                   'calculado', v_t,
                   'limitado', privado.pol_bool('pag_volta_teto', true, c.empresa_id, v_m, c.tipo_pedido) and v_t > v_teto,
                   'total', case when privado.pol_bool('pag_volta_teto', true, c.empresa_id, v_m, c.tipo_pedido) then least(v_t, v_teto) else v_t end);
      end if;
    end if;
    if v_rr <> '{}' then v_res := v_res || jsonb_build_object('regras_rota', v_rr); end if;
  exception when others then
    perform set_config('pwex.regras', coalesce(v_ant, ''), true);
    raise;
  end;
  perform set_config('pwex.regras', coalesce(v_ant, ''), true);
  return v_res;
end;
$$;


-- Distância pelas ruas de cada entrega (o app/site calcula) e recalcula o pedido.
create or replace function public.definir_distancias_pedido(p_pedido uuid, p_dist jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare x jsonb; p public.pedidos%rowtype;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if not public.ve_pedido(p_pedido) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  select * into p from public.pedidos where id = p_pedido;
  for x in select * from jsonb_array_elements(privado.lista(p_dist)) loop
    update public.pedido_pontos set dist_coleta_m = case when (x ->> 'dist_m')::numeric between 1 and 2000000 then round((x ->> 'dist_m')::numeric)::int end
     where id = (x ->> 'id')::uuid and pedido_id = p_pedido;
  end loop;
  if p.status in ('recebido', 'aprovado') then perform public.revisar_pedido(p_pedido, 'recalcular'); end if;
end;
$$;
revoke execute on function public.definir_distancias_pedido(uuid, jsonb) from public, anon;
grant execute on function public.definir_distancias_pedido(uuid, jsonb) to authenticated;

notify pgrst, 'reload schema';
