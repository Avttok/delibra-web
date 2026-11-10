-- =====================================================================
-- 1) Repasse do motoboy sai do perfil e vira parâmetro de pagamento (exceção por motoboy).
-- 2) Gestor escolhe se o motoboy vê a aba Holerite (geral ou por motoboy).
-- 3) Dev ganha/bloqueia conquistas de qualquer pessoa.
-- Rode depois de 20261110000006.
-- =====================================================================

-- ------------------------------------------------------------- repasse: perfil → peça do lego (escopo motoboy)
insert into public.politicas (escopo, alvo, chave, valor)
select 'motoboy', m.id::text, 'repasse_motoboy_pct', to_jsonb(m.repasse_pct)
  from public.motoboys m where m.repasse_pct is not null
on conflict (escopo, alvo, chave) do nothing;
update public.motoboys set repasse_pct = null where repasse_pct is not null;

create or replace function privado.repasse_de(p_motoboy uuid)
returns numeric language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select nullif(valor #>> '{}', '')::numeric from public.politicas where escopo = 'motoboy' and alvo = p_motoboy::text and chave = 'repasse_motoboy_pct'),
    (select repasse_pct from public.motoboys where id = p_motoboy),
    privado.cfg_num('repasse_motoboy_pct', 67.5));
$$;

-- editar membro: não mexe mais no percentual (nem apaga o que existe)
create or replace function public.editar_membro(p_usuario uuid, p_nome text, p_papeis public.papel_usuario[], p_repasse numeric default null)
returns void language plpgsql security definer set search_path = '' as $$
declare v_atual public.papel_usuario[];
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if not public.pode_gerenciar(p_usuario) then raise exception 'conta_protegida' using errcode = '42501'; end if;
  select papeis into v_atual from public.perfis where id = p_usuario;
  -- dar ou tirar o cargo Dev: só um Dev
  if ('dev' = any (p_papeis)) <> ('dev' = any (coalesce(v_atual, '{}'))) and not public.is_dev() then
    raise exception 'apenas_dev' using errcode = '42501';
  end if;
  if p_usuario = auth.uid() and not ('gestor' = any (p_papeis) or 'dev' = any (p_papeis)) then
    raise exception 'nao_remova_seu_proprio_acesso' using errcode = '22023';
  end if;
  if p_usuario = auth.uid() and 'dev' = any (coalesce(v_atual, '{}')) and not ('dev' = any (p_papeis)) then
    raise exception 'nao_remova_seu_proprio_acesso' using errcode = '22023';
  end if;
  if p_repasse is not null and (p_repasse < 0 or p_repasse > 100) then
    raise exception 'percentual_invalido' using errcode = '22023';
  end if;
  update public.perfis set nome = coalesce(nullif(trim(p_nome), ''), nome), papeis = p_papeis where id = p_usuario;
  if 'motoboy' = any (p_papeis) then
    insert into public.motoboys (id) values (p_usuario) on conflict (id) do nothing;
    -- percentual agora é uma exceção de pagamento do motoboy (Regras); só grava se vier
    if p_repasse is not null then
      insert into public.politicas (escopo, alvo, chave, valor) values ('motoboy', p_usuario::text, 'repasse_motoboy_pct', to_jsonb(p_repasse))
      on conflict (escopo, alvo, chave) do update set valor = excluded.valor;
    end if;
  end if;
end;
$$;


-- ------------------------------------------------------------- aba Holerite do motoboy
insert into public.configuracoes (chave, valor) values ('motoboy_ve_holerite', 'true') on conflict (chave) do nothing;

create or replace function public.meu_perfil()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', p.id,
    'nome', p.nome,
    'foto_url', p.foto_url,
    'papeis', to_jsonb(p.papeis),
    'gestor', 'gestor' = any (p.papeis) or 'dev' = any (p.papeis),
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
    'configuracoes', coalesce((
      select jsonb_object_agg(chave, valor) from public.configuracoes
       where chave in ('intervalo_corrida_s', 'intervalo_economia_s', 'disponivel_envio_min',
                       'disponivel_distancia_m', 'raio_chegada_m', 'teste_admin_ignora_local', 'oferta_segundos',
                       'quadro_mostra_enderecos', 'quadro_mostra_itens', 'simulador_ligado', 'simulador_velocidade_kmh',
                       'motoboy_edita_veiculo', 'mapa_offline_some_h', 'mapa_offline_esmaecer', 'veiculo_obrigatorio')
    ), '{}'::jsonb)
  )
  from public.perfis p
  left join public.motoboys m on m.id = p.id
  where p.id = auth.uid();
$$;

create or replace function public.meus_holerites(p_quantos int default 12)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_teste boolean := coalesce((select modo_teste from public.motoboys where id = auth.uid()), false);
  v_ve    boolean := privado.ve_valores(auth.uid());
  v_veh   boolean := privado.pol_bool('motoboy_ve_holerite_valor', true, null, auth.uid(), null);
  v_d     date := privado.dia_local(now());
  v_out   jsonb := '[]';
  v_per   record;
  v_h     jsonb;
  k       int := 0;
begin
  if not public.tem_papel('motoboy'::public.papel_usuario) then raise exception 'apenas_motoboy' using errcode = '42501'; end if;
  if not privado.pol_bool('motoboy_ve_holerite', true, null, auth.uid(), null) then raise exception 'holerite_oculto' using errcode = '42501'; end if;
  while k < least(greatest(p_quantos, 1), 36) loop
    select * into v_per from privado.periodo_holerite(auth.uid(), v_d);
    v_h := privado.holerite_json(auth.uid(), v_per.inicio, v_per.fim, v_teste, true);
    v_out := v_out || jsonb_build_object('inicio', v_per.inicio, 'fim', v_per.fim, 'status', v_h ->> 'status',
      'rotas', v_h -> 'rotas', 'entregas', v_h -> 'entregas', 'km', v_h -> 'km', 'pago_em', v_h -> 'pago_em',
      'total', case when v_ve or (v_veh and v_h ->> 'status' in ('fechado', 'pago')) then v_h -> 'total' end);
    v_d := v_per.inicio - 1;
    k := k + 1;
  end loop;
  return jsonb_build_object('periodos', v_out, 'valores_visiveis', v_ve, 'teste', v_teste,
                            'periodo', privado.pol_txt('holerite_periodo', 'semanal', null, auth.uid(), null));
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
  return v;
end;
$$;


-- ------------------------------------------------------------- conquistas: o Dev ganha ou bloqueia na mão
create table if not exists public.conquistas_manuais (
  perfil_id uuid not null references public.perfis (id) on delete cascade,
  chave     text not null,
  ganha     boolean not null,
  por       uuid references public.perfis (id) on delete set null,
  em        timestamptz not null default now(),
  primary key (perfil_id, chave)
);
alter table public.conquistas_manuais enable row level security;
revoke all on public.conquistas_manuais from anon, authenticated;

create or replace function public.definir_conquista(p_perfil uuid, p_chave text, p_estado text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  if p_estado = 'auto' then
    delete from public.conquistas_manuais where perfil_id = p_perfil and chave = p_chave;
  elsif p_estado in ('ganha', 'bloqueada') then
    insert into public.conquistas_manuais (perfil_id, chave, ganha, por) values (p_perfil, p_chave, p_estado = 'ganha', auth.uid())
    on conflict (perfil_id, chave) do update set ganha = excluded.ganha, por = excluded.por, em = now();
  else
    raise exception 'estado_invalido' using errcode = '22023';
  end if;
end;
$$;
revoke all on function public.definir_conquista(uuid, text, text) from public, anon;
grant execute on function public.definir_conquista(uuid, text, text) to authenticated;

create or replace function public.conquistas(p_motoboy uuid default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_id    uuid := coalesce(p_motoboy, auth.uid());
  v_teste boolean;
  v_cri   timestamptz;
  m       public.motoboys%rowtype;
  r       jsonb;
begin
  if v_id is null then raise exception 'sem_login' using errcode = '42501'; end if;
  if v_id <> auth.uid() and not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
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


-- ------------------------------------------------------------- cliente vê o preço na hora ou só depois da revisão
insert into public.configuracoes (chave, valor) values ('cliente_ve_preco', '"na_hora"') on conflict (chave) do nothing;
create or replace function privado.cliente_ve_preco(p_cli uuid, p_status text default null)
returns boolean language sql stable security definer set search_path = '' as $$
  select privado.pol_txt('cliente_ve_preco', 'na_hora', p_cli) <> 'apos_revisao' or (p_status is not null and p_status not in ('recebido'));
$$;

create or replace function public.orcar_previa(dados jsonb)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_cli uuid;
begin
  if public.is_gestor() then return privado.orcar(dados); end if;
  v_cli := privado.minha_empresa();
  if v_cli is null then raise exception 'apenas_cliente' using errcode = '42501'; end if;
  if not privado.cliente_ve_preco(v_cli) then
    return jsonb_build_object('oculto', true, 'distancia_m', (privado.orcar(jsonb_set(dados, '{empresa_id}', to_jsonb(v_cli::text))) -> 'distancia_m'));
  end if;
  return privado.orcar(jsonb_set(dados, '{empresa_id}', to_jsonb(v_cli::text)));
end;
$$;

create or replace function public.meus_pedidos_cliente(p_dias int default 120)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(x order by (x ->> 'criado_em') desc), '[]'::jsonb) from (
    select jsonb_build_object(
      'id', p.id, 'numero', p.numero, 'tipo', p.tipo, 'tipo_pedido', p.tipo_pedido, 'quando', p.quando, 'urgente', p.urgente,
      'status', p.status,
      'valor', case when privado.cliente_ve_preco(p.empresa_id, p.status::text) then p.valor end,
      'orcamento', case when privado.cliente_ve_preco(p.empresa_id, p.status::text) then p.orcamento end,
      'preco_oculto', not privado.cliente_ve_preco(p.empresa_id, p.status::text), 'cobranca', p.cobranca, 'pagamento_status', p.pagamento_status,
      'pagamento_metodo', p.pagamento_metodo, 'fatura_id', p.fatura_id, 'observacoes', p.observacoes, 'recusa_motivo', p.recusa_motivo,
      'criado_em', p.criado_em, 'concluido_em', p.concluido_em, 'cancelado_em', p.cancelado_em,
      'pontos', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'tipo', x.tipo, 'endereco', x.endereco, 'lat', x.lat, 'lng', x.lng,
                                 'contato_nome', x.contato_nome, 'status', x.status, 'concluido_em', x.concluido_em, 'recebedor_nome', x.recebedor_nome) order by x.ordem)
                          from public.pedido_pontos x where x.pedido_id = p.id), '[]'),
      'itens', coalesce((select jsonb_agg(jsonb_build_object('descricao', i.descricao, 'quantidade', i.quantidade, 'peso_kg', i.peso_kg,
                                'categoria', k.nome, 'categoria_id', i.categoria_id, 'icone', k.icone, 'perigoso', coalesce(k.perigoso, false),
                                'comprimento_cm', i.comprimento_cm, 'largura_cm', i.largura_cm, 'altura_cm', i.altura_cm, 'valor_declarado', i.valor_declarado))
                         from public.pedido_itens i left join public.categorias_produto k on k.id = i.categoria_id where i.pedido_id = p.id), '[]'),
      'motoboys', (select coalesce(jsonb_agg(distinct split_part(pf.nome, ' ', 1)) filter (where privado.pol_bool('cliente_ve_motoboy', true, p.empresa_id)), '[]') from public.paradas pa join public.corridas c on c.id = pa.corrida_id
                     join public.perfis pf on pf.id = c.motoboy_id where pa.pedido_id = p.id and c.status::text <> 'cancelada'),
      'codigos', (select coalesce(jsonb_agg(distinct c.codigo_entrega) filter (where c.codigo_entrega is not null and privado.pol_bool('cliente_ve_codigo', true, p.empresa_id)), '[]') from public.paradas pa
                    join public.corridas c on c.id = pa.corrida_id where pa.pedido_id = p.id and c.exige_codigo and c.status::text not in ('cancelada', 'concluida'))
    ) x
      from public.pedidos p
     where p.empresa_id = privado.minha_empresa() and p.teste = privado.cliente_teste()
       and p.criado_em > now() - make_interval(days => greatest(1, least(p_dias, 400)))
     limit 500
  ) t;
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
    'troca_senha', privado.pol_bool('cliente_troca_senha', true, v_cli), 'categoria_obrigatoria', privado.cfg_bool('item_categoria_obrigatoria', false),
    'em_aberto', (select coalesce(sum(valor), 0) from public.pedidos where empresa_id = v_cli and teste = privado.cliente_teste() and cobranca = 'credito' and fatura_id is null and status = 'concluido'));
end;
$$;


-- ------------------------------------------------------------- holerite do motoboy: valor durante o período ou só depois de fechar;
-- os ajustes (bônus/descontos) entram diluídos nas rotas, sem mostrar o motivo
insert into public.configuracoes (chave, valor) values ('motoboy_holerite_quando', '"aberto"') on conflict (chave) do nothing;

create or replace function privado.holerite_para_motoboy(v jsonb)
returns jsonb language plpgsql immutable set search_path = '' as $$
declare
  v_aj    numeric := coalesce((select sum((a ->> 'valor')::numeric) from jsonb_array_elements(coalesce(v -> 'ajustes', '[]')) a), 0);
  v_base  numeric := coalesce((select sum(coalesce((i ->> 'valor')::numeric, 0)) from jsonb_array_elements(coalesce(v -> 'itens', '[]')) i), 0);
  v_n     int := jsonb_array_length(coalesce(v -> 'itens', '[]'));
  v_itens jsonb := '[]';
  v_resto numeric := v_aj;
  i       jsonb;
  k       int := 0;
  v_parte numeric;
begin
  for i in select * from jsonb_array_elements(coalesce(v -> 'itens', '[]')) loop
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
      coalesce((select jsonb_agg(i - 'valor' - 'ajuste' - 'ajuste_motivo' - 'calculo') from jsonb_array_elements(coalesce(v -> 'itens', '[]')) i), '[]'));
  end if;
  return privado.holerite_para_motoboy(v);
end;
$$;

create or replace function public.meus_holerites(p_quantos int default 12)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_teste boolean := coalesce((select modo_teste from public.motoboys where id = auth.uid()), false);
  v_ve    boolean := privado.ve_valores(auth.uid());
  v_veh   boolean := privado.pol_bool('motoboy_ve_holerite_valor', true, null, auth.uid(), null);
  v_d     date := privado.dia_local(now());
  v_out   jsonb := '[]';
  v_per   record;
  v_h     jsonb;
  k       int := 0;
begin
  if not public.tem_papel('motoboy'::public.papel_usuario) then raise exception 'apenas_motoboy' using errcode = '42501'; end if;
  if not privado.pol_bool('motoboy_ve_holerite', true, null, auth.uid(), null) then raise exception 'holerite_oculto' using errcode = '42501'; end if;
  while k < least(greatest(p_quantos, 1), 36) loop
    select * into v_per from privado.periodo_holerite(auth.uid(), v_d);
    v_h := privado.holerite_json(auth.uid(), v_per.inicio, v_per.fim, v_teste, true);
    v_out := v_out || jsonb_build_object('inicio', v_per.inicio, 'fim', v_per.fim, 'status', v_h ->> 'status',
      'rotas', v_h -> 'rotas', 'entregas', v_h -> 'entregas', 'km', v_h -> 'km', 'pago_em', v_h -> 'pago_em',
      'total', case when (v_ve and (v_h ->> 'status' in ('fechado', 'pago') or privado.pol_txt('motoboy_holerite_quando', 'aberto', null, auth.uid(), null) <> 'fechado'))
                         or (v_veh and v_h ->> 'status' in ('fechado', 'pago')) then v_h -> 'total' end);
    v_d := v_per.inicio - 1;
    k := k + 1;
  end loop;
  return jsonb_build_object('periodos', v_out, 'valores_visiveis', v_ve, 'teste', v_teste,
                            'periodo', privado.pol_txt('holerite_periodo', 'semanal', null, auth.uid(), null));
end;
$$;
