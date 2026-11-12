-- =====================================================================
-- Delibra · 0043: holerite (o gestor escolhe o que o motoboy vê), pagamento da rota editável até fechar o holerite,
--                  limite de gestores por empresa (só o Dev cria gestor), Dev oculto some de tudo, ferramentas do Dev
-- =====================================================================
set check_function_bodies = off;

insert into public.configuracoes (chave, valor) values
  ('dev_gestores_por_empresa', '1'), ('dev_supervisores_por_empresa', '0')
on conflict (chave) do nothing;

-- ===================================================================== holerite: o que o motoboy vê
alter table public.holerite_ajustes add column if not exists visibilidade text not null default 'tudo';
alter table public.holerite_ajustes drop constraint if exists holerite_ajustes_visibilidade_check;
alter table public.holerite_ajustes add constraint holerite_ajustes_visibilidade_check check (visibilidade in ('tudo', 'valor', 'oculto'));
alter table public.corridas add column if not exists pag_ajuste_mostrar boolean not null default true;

create or replace function privado.holerite_json(p_motoboy uuid, p_inicio date, p_fim date, p_teste boolean, p_valores boolean)
returns jsonb language sql stable security definer set search_path = '' as $$
  with rotas as (
    select c.id, c.numero, c.concluida_em, c.valor, c.valor_motoboy, c.pag_calculo, c.pag_ajuste, c.pag_ajuste_motivo, c.pag_ajuste_mostrar,
           coalesce(c.distancia_real_m, c.distancia_planejada_m, 0) metros,
           (select count(*) from public.paradas x where x.corrida_id = c.id and x.tipo = 'entrega') entregas,
           (select coalesce(string_agg(distinct coalesce(e.nome, pd.cliente_nome), ', '), coalesce(e2.nome, c.cliente_nome))
              from public.paradas x left join public.pedidos pd on pd.id = x.pedido_id left join public.empresas e on e.id = pd.empresa_id
             where x.corrida_id = c.id) clientes
      from public.corridas c left join public.empresas e2 on e2.id = c.empresa_id
     where c.motoboy_id = p_motoboy and c.status = 'concluida' and c.teste = p_teste
       and privado.dia_local(c.concluida_em) between p_inicio and p_fim
  ), h as (
    select * from public.holerites where motoboy_id = p_motoboy and teste = p_teste and inicio = p_inicio and fim = p_fim
  ), fx as (
    -- salário, diárias, horas e mínimo do período
    select privado.pag_periodo(p_motoboy, p_inicio, p_fim, p_teste, (select coalesce(sum(valor_motoboy), 0) from rotas)) j
  )
  select jsonb_build_object(
    'motoboy_id', p_motoboy, 'inicio', p_inicio, 'fim', p_fim, 'teste', p_teste,
    'status', coalesce((select status from h), 'aberto'),
    'fechado_em', (select fechado_em from h), 'pago_em', (select pago_em from h), 'observacoes', (select observacoes from h),
    'rotas', (select count(*) from rotas), 'entregas', (select coalesce(sum(entregas), 0) from rotas),
    'km', (select round(coalesce(sum(metros), 0) / 1000.0, 1) from rotas),
    'valores_visiveis', p_valores,
    'calculado', case when p_valores then (select coalesce(sum((pag_calculo ->> 'total')::numeric), 0) from rotas) + (select (j ->> 'total')::numeric from fx) end,
    'fixos', case when p_valores then (select j -> 'itens' from fx) else (select coalesce(jsonb_agg(i - 'valor' - 'base'), '[]') from fx, jsonb_array_elements(fx.j -> 'itens') i) end,
    'fixos_total', case when p_valores then (select (j ->> 'total')::numeric from fx) end,
    'ajustes_rotas', case when p_valores then (select coalesce(sum(pag_ajuste), 0) from rotas) end,
    -- o gestor vê tudo; o motoboy vê o que o gestor escolheu (tudo, só o valor, ou nada)
    'ajustes', case when p_valores then coalesce((select jsonb_agg(jsonb_build_object('id', a.id,
                    'descricao', case when public.is_gestor() or a.visibilidade = 'tudo' then a.descricao else 'Ajuste' end,
                    'valor', a.valor, 'criado_em', a.criado_em, 'visibilidade', case when public.is_gestor() then a.visibilidade end) order by a.criado_em)
                                                   from public.holerite_ajustes a where a.holerite_id = (select id from h)
                                                    and (public.is_gestor() or a.visibilidade <> 'oculto')), '[]') end,
    'total', case when p_valores then
      (select coalesce(sum(valor_motoboy), 0) from rotas) + (select (j ->> 'total')::numeric from fx)
      + coalesce((select sum(a.valor) from public.holerite_ajustes a where a.holerite_id = (select id from h) and (public.is_gestor() or a.visibilidade <> 'oculto')), 0) end,
    'itens', coalesce((select jsonb_agg(jsonb_build_object(
        'id', r.id, 'numero', r.numero, 'concluida_em', r.concluida_em, 'entregas', r.entregas, 'km', round(r.metros / 1000.0, 1),
        'clientes', r.clientes,
        'calculo', case when p_valores then r.pag_calculo end, 'ajuste', case when p_valores then r.pag_ajuste end,
        'ajuste_motivo', case when p_valores and (public.is_gestor() or r.pag_ajuste_mostrar) then r.pag_ajuste_motivo end, 'valor', case when p_valores then r.valor_motoboy end,
        'faturado', case when public.is_gestor() then r.valor end) order by r.concluida_em) from rotas r), '[]'));
$$;

drop function if exists public.ajuste_holerite(uuid, date, date, text, numeric, boolean);
create or replace function public.ajuste_holerite(p_motoboy uuid, p_inicio date, p_fim date, p_descricao text, p_valor numeric, p_teste boolean default false,
                                                  p_visibilidade text default 'tudo')
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_h uuid; v_id uuid;
begin
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

create or replace function public.ajuste_holerite_visibilidade(p_id uuid, p_visibilidade text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_mb uuid;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if p_visibilidade not in ('tudo', 'valor', 'oculto') then raise exception 'visibilidade_invalida' using errcode = '22023'; end if;
  select h.motoboy_id into v_mb from public.holerite_ajustes a join public.holerites h on h.id = a.holerite_id where a.id = p_id;
  if v_mb is null or not public.ve_pessoa(v_mb) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  update public.holerite_ajustes set visibilidade = p_visibilidade where id = p_id;
end;
$$;
revoke execute on function public.ajuste_holerite(uuid, date, date, text, numeric, boolean, text), public.ajuste_holerite_visibilidade(uuid, text) from public, anon;
grant execute on function public.ajuste_holerite(uuid, date, date, text, numeric, boolean, text), public.ajuste_holerite_visibilidade(uuid, text) to authenticated;

drop function if exists public.ajustar_pagamento_rota(uuid, numeric, text);
create or replace function public.ajustar_pagamento_rota(p_corrida uuid, p_ajuste numeric, p_motivo text, p_mostrar boolean default true)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c public.corridas%rowtype; v_per record;
begin
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

grant execute on function public.ajustar_pagamento_rota(uuid, numeric, text, boolean) to authenticated;

create or replace function public.definir_regras_rota(p_corrida uuid, p_regras jsonb, p_motivo text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c public.corridas%rowtype; v_r jsonb;
begin
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

create or replace function privado.limite_cargo(p_org uuid, p_cargo text)
returns int language sql stable security definer set search_path = '' as $$
  select nullif(coalesce(nullif((select o.limites ->> case p_cargo when 'gestor' then 'gestores' when 'supervisor' then 'supervisores' else 'motoboys' end
                                 from public.organizacoes o where o.id = p_org), '')::int,
                         case p_cargo when 'gestor' then privado.cfg_num('dev_gestores_por_empresa', 1)::int
                                      when 'supervisor' then privado.cfg_num('dev_supervisores_por_empresa', 0)::int else 0 end), 0);
$$;

create or replace function privado.conferir_limites()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_org uuid; v_lim int; v_n int; v_cargo text;
begin
  v_org := new.organizacao_id;
  if v_org is null or 'dev' = any (new.papeis) then return new; end if;
  if tg_op = 'UPDATE' and old.organizacao_id is not distinct from new.organizacao_id and old.papeis = new.papeis then return new; end if;
  foreach v_cargo in array array['motoboy', 'gestor', 'supervisor'] loop
    continue when not (v_cargo::public.papel_usuario = any (new.papeis));
    continue when tg_op = 'UPDATE' and v_cargo::public.papel_usuario = any (old.papeis) and old.organizacao_id is not distinct from v_org;
    -- gestor novo: só o Dev (ou o próprio sistema, no cadastro de empresa) cria
    if v_cargo = 'gestor' and auth.uid() is not null and not public.is_dev() then
      raise exception 'apenas_dev_cria_gestor' using errcode = '42501';
    end if;
    v_lim := privado.limite_cargo(v_org, v_cargo);
    if v_lim is not null and v_lim > 0 then
      select count(*) into v_n from public.perfis where organizacao_id = v_org and v_cargo::public.papel_usuario = any (papeis) and id <> new.id;
      if v_n >= v_lim then raise exception 'limite_%_do_plano', case v_cargo when 'motoboy' then 'motoboys' when 'gestor' then 'gestores' else 'supervisores' end
        using errcode = '22023', detail = v_lim::text; end if;
    end if;
  end loop;
  return new;
end;
$$;
revoke execute on function privado.conferir_limites(), privado.limite_cargo(uuid, text) from public, anon, authenticated;

-- quantas contas de cada cargo ainda cabem (a tela de criar/editar desliga o que não cabe)
create or replace function public.vagas_da_equipe(p_org uuid default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_org uuid := coalesce(p_org, public.minha_org()); r jsonb := '{}'; v_c text; v_n int; v_l int;
begin
  if not (public.is_gestor() or public.is_dev()) then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if p_org is not null and not public.is_dev() and p_org is distinct from public.minha_org() then raise exception 'sem_permissao' using errcode = '42501'; end if;
  foreach v_c in array array['gestor', 'supervisor', 'motoboy'] loop
    select count(*) into v_n from public.perfis where organizacao_id = v_org and v_c::public.papel_usuario = any (papeis) and not ('dev' = any (papeis));
    v_l := privado.limite_cargo(v_org, v_c);
    r := r || jsonb_build_object(v_c, jsonb_build_object('usados', v_n, 'limite', v_l,
           'pode', (v_c <> 'gestor' or public.is_dev()) and (v_l is null or v_n < v_l)));
  end loop;
  return r;
end;
$$;
revoke execute on function public.vagas_da_equipe(uuid) from public, anon;
grant execute on function public.vagas_da_equipe(uuid) to authenticated;

-- ===================================================================== Dev oculto: some de tudo para quem não é Dev
create or replace function public.nome_publico(p_id uuid)
returns text language sql stable security definer set search_path = '' as $$
  select case when public.dev_oculto_para_mim(p_id) then 'Sistema' else (select nome from public.perfis where id = p_id) end;
$$;
drop policy if exists dev_oculto_some on public.perfis;
create policy dev_oculto_some on public.perfis as restrictive for select to authenticated
  using (id = (select auth.uid()) or not (dev_oculto and 'dev' = any (papeis)) or (select public.is_dev()));
drop policy if exists dev_oculto_some on public.motoboys;
create policy dev_oculto_some on public.motoboys as restrictive for select to authenticated using (not public.dev_oculto_para_mim(id));
drop policy if exists dev_oculto_some on public.chat_membros;
create policy dev_oculto_some on public.chat_membros as restrictive for select to authenticated using (not public.dev_oculto_para_mim(usuario_id));
drop policy if exists dev_oculto_some on public.chat_mensagens;
create policy dev_oculto_some on public.chat_mensagens as restrictive for select to authenticated using (autor_id is null or not public.dev_oculto_para_mim(autor_id));

create or replace function public.chat_membros_de(p_conversa uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'nome', public.nome_publico(p.id), 'foto', public.foto_publica(p.id), 'admin', m.admin,
           'papeis', case when public.dev_oculto_para_mim(p.id) then '["dev"]'::jsonb else to_jsonb(p.papeis) end, 'lida_em', m.lida_em) order by m.admin desc, public.nome_publico(p.id)), '[]')
    from public.chat_membros m join public.perfis p on p.id = m.usuario_id
   where m.conversa_id = p_conversa and public.chat_sou_membro(p_conversa) and not public.dev_oculto_para_mim(p.id);
$$;

create or replace function public.chat_autores(p_conversa uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'nome', public.nome_publico(p.id), 'foto', public.foto_publica(p.id),
                   'oculto', public.dev_oculto_para_mim(p.id),
                   'papeis', case when public.dev_oculto_para_mim(p.id) then '["dev"]'::jsonb else to_jsonb(p.papeis) end,
                   'empresa', (select e.nome from public.empresas e where e.id = p.empresa_id))), '[]')
    from public.perfis p
   where public.chat_sou_membro(p_conversa) and not public.dev_oculto_para_mim(p.id)
     and (p.id in (select distinct g.autor_id from public.chat_mensagens g where g.conversa_id = p_conversa)
          or p.id in (select m.usuario_id from public.chat_membros m where m.conversa_id = p_conversa));
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
       -- conversa direta com o Dev oculto não aparece
       and not (c.tipo = 'direta' and exists (select 1 from public.chat_membros m where m.conversa_id = c.id and public.dev_oculto_para_mim(m.usuario_id)))
  ) t;
$$;

create or replace function public.auditoria_lista(p_de timestamptz default null, p_ate timestamptz default null, p_busca text default null, p_limite int default 200)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not (public.is_gestor_pleno() or public.is_dev()) then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'quando', a.criado_em, 'autor', public.nome_publico(a.autor_id), 'autor_id', a.autor_id,
           'tabela', a.tabela, 'acao', a.acao, 'alvo', a.alvo, 'antes', a.antes, 'depois', a.depois) order by a.criado_em desc)
    from (select * from public.auditoria x
           where public.ve_org(x.organizacao_id) and not public.dev_oculto_para_mim(x.autor_id)
             and (p_de is null or x.criado_em >= p_de) and (p_ate is null or x.criado_em < p_ate)
             and (p_busca is null or x.tabela ilike '%' || p_busca || '%' or x.depois::text ilike '%' || p_busca || '%' or public.nome_publico(x.autor_id) ilike '%' || p_busca || '%')
           order by x.criado_em desc limit least(greatest(coalesce(p_limite, 200), 1), 1000)) a), '[]'::jsonb);
end;
$$;

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
     where (p_escopo = 'global' or g.organizacao_id is not distinct from v_org) and not public.dev_oculto_para_mim(g.motoboy_id)
       and (p_periodo = 'sempre' or g.criado_em >= date_trunc('month', now()))
     group by g.motoboy_id, jp.xp, jp.equipado
     order by max(g.pontos) desc limit 50) t), '[]'::jsonb);
end;
$$;

create or replace function public.perfil_publico(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  pf public.perfis%rowtype; m public.motoboys%rowtype;
  v_eu boolean := p_id = auth.uid();
  v_ges boolean := public.is_gestor();
  v_tudo boolean;
  v jsonb;
begin
  if public.dev_oculto_para_mim(p_id) then raise exception 'sem_permissao' using errcode = '42501'; end if;
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

-- todas as contas do sistema (busca por nome, e-mail ou empresa)
create or replace function public.dev_usuarios(p_busca text default null, p_org uuid default null, p_limite int default 200)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(x order by x ->> 'nome') from (
    select jsonb_build_object('id', p.id, 'nome', p.nome, 'email', u.email, 'papeis', to_jsonb(p.papeis), 'foto', p.foto_url,
             'organizacao_id', p.organizacao_id, 'organizacao', o.nome, 'empresa', e.nome, 'criado_em', p.criado_em,
             'ultimo_acesso', u.last_sign_in_at, 'bloqueado', u.banned_until > now(), 'modo_teste', p.modo_teste,
             'motoboy', case when m.id is not null then jsonb_build_object('status', m.status, 'versao', coalesce(m.app_versao::text, m.versao_app::text), 'posicao_em', m.posicao_em,
                                                                         'bateria', m.bateria, 'aparelho', m.aparelho, 'suspenso_ate', m.suspenso_ate) end) x
      from public.perfis p left join auth.users u on u.id = p.id left join public.organizacoes o on o.id = p.organizacao_id
      left join public.empresas e on e.id = p.empresa_id left join public.motoboys m on m.id = p.id
     where (p_org is null or p.organizacao_id = p_org)
       and (p_busca is null or p.nome ilike '%' || p_busca || '%' or u.email ilike '%' || p_busca || '%' or o.nome ilike '%' || p_busca || '%')
     order by p.nome limit least(greatest(coalesce(p_limite, 200), 1), 1000)) t), '[]'::jsonb);
end;
$$;

-- Dev muda os cargos de qualquer conta (o limite da empresa continua valendo)
create or replace function public.dev_definir_papeis(p_id uuid, p_papeis text[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v public.papel_usuario[];
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  select coalesce(array_agg(distinct x::public.papel_usuario), '{}') into v from unnest(p_papeis) x
   where x in ('gestor', 'supervisor', 'motoboy', 'cliente', 'dev');
  if array_length(v, 1) is null then raise exception 'sem_papel' using errcode = '22023'; end if;
  if not exists (select 1 from public.perfis where id = p_id) then raise exception 'conta_nao_encontrada' using errcode = '22023'; end if;
  update public.perfis set papeis = v where id = p_id;
  if 'motoboy' = any (v) then insert into public.motoboys (id) values (p_id) on conflict do nothing; end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- saúde do sistema: banco, tabelas, pings, tarefas automáticas e migrações
create or replace function public.dev_saude()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_cron jsonb := '[]'; v_mig jsonb := '[]';
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  begin
    execute $q$select coalesce(jsonb_agg(jsonb_build_object('nome', j.jobname, 'quando', j.schedule, 'ativa', j.active,
               'ultima', (select max(d.start_time) from cron.job_run_details d where d.jobid = j.jobid),
               'falhas_24h', (select count(*) from cron.job_run_details d where d.jobid = j.jobid and d.status = 'failed' and d.start_time > now() - interval '1 day'),
               'erro', (select d.return_message from cron.job_run_details d where d.jobid = j.jobid and d.status = 'failed' order by d.start_time desc limit 1))
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
revoke execute on function public.dev_usuarios(text, uuid, int), public.dev_definir_papeis(uuid, text[]), public.dev_saude() from public, anon;
grant execute on function public.dev_usuarios(text, uuid, int), public.dev_definir_papeis(uuid, text[]), public.dev_saude() to authenticated;

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

-- rota cancelada volta: com pedidos, os pedidos voltam para a revisão; avulsa, a rota volta a "montada" para soltar de novo
create or replace function public.reabrir_corrida(p_corrida uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c public.corridas%rowtype; v_n int := 0; r record;
begin
  if not public.is_gestor() or not public.ve_corrida(p_corrida) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  select * into c from public.corridas where id = p_corrida for update;
  if c.status::text <> 'cancelada' then raise exception 'rota_nao_cancelada' using errcode = '22023'; end if;
  for r in select distinct pd.id from public.paradas pa join public.pedidos pd on pd.id = pa.pedido_id where pa.corrida_id = c.id and pd.status::text in ('cancelado', 'recusado') loop
    update public.pedidos set status = 'recebido', cancelado_em = null, recusa_motivo = null, aprovado_em = null, revisado_por = null, revisado_em = null where id = r.id;
    update public.pedido_pontos set status = 'pendente' where pedido_id = r.id and status::text <> 'concluido';
    v_n := v_n + 1;
  end loop;
  if v_n = 0 then
    update public.paradas set status = 'pendente', chegou_em = null where corrida_id = c.id and status::text <> 'concluida';
    update public.corridas set status = 'montada', motoboy_id = null, aceita_em = null, iniciada_em = null, cancelada_em = null where id = c.id;
  end if;
  perform privado.evento(c.id, 'reaberta', jsonb_build_object('pedidos', v_n));
  return jsonb_build_object('pedidos', v_n, 'rota', case when v_n = 0 then 'montada' end);
end;
$$;
revoke execute on function public.reabrir_corrida(uuid) from public, anon;
grant execute on function public.reabrir_corrida(uuid) to authenticated;


-- ===================================================================== painel do dia mais completo (Lote 42)
create or replace function public.painel_do_dia()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_hoje timestamptz := date_trunc('day', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo';
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
                   select extract(hour from c.concluida_em at time zone 'America/Sao_Paulo')::int h, count(*) n from public.corridas c
                    where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'concluida' and c.concluida_em >= v_hoje group by 1) x),
    'canceladas_hoje', (select count(*) from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'cancelada' and c.cancelada_em >= v_hoje),
    'entregas_hoje', (select count(*) from public.paradas x join public.corridas c on c.id = x.corrida_id where public.ve_org(c.organizacao_id) and c.teste = v_teste
                       and x.tipo::text = 'entrega' and x.status::text = 'concluida' and x.concluida_em >= v_hoje),
    'tempo_medio_min', (select round(avg(extract(epoch from (c.concluida_em - coalesce(c.aceita_em, c.iniciada_em))) / 60.0))::int from public.corridas c
                         where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'concluida' and c.concluida_em >= v_hoje and coalesce(c.aceita_em, c.iniciada_em) is not null),
    'pagar_motoboys_hoje', (select coalesce(sum(c.valor_motoboy), 0) from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'concluida' and c.concluida_em >= v_hoje),
    'ontem_concluidas', (select count(*) from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'concluida'
                          and c.concluida_em >= v_hoje - interval '1 day' and c.concluida_em < now() - interval '1 day'),
    'hora_agora', extract(hour from now() at time zone 'America/Sao_Paulo')::int,
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
revoke execute on function public.painel_do_dia() from public, anon;
grant execute on function public.painel_do_dia() to authenticated;

-- ===================================================================== GPS mais leve no servidor
-- Pontos de quando o motoboy não estava em rota, depois de N horas, ficam só um a cada X minutos.
create or replace function privado.afinar_ociosos(p_max int default 50000)
returns int language plpgsql security definer set search_path = '' as $$
declare v_h numeric := privado.cfg_num('ping_ocioso_horas', 48); v_min numeric := greatest(privado.cfg_num('ping_ocioso_min', 10), 1); v_n int;
begin
  if v_h <= 0 then return 0; end if;
  with c as (
    select id, row_number() over (partition by motoboy_id, date_bin(make_interval(mins => v_min::int), registrado_em, timestamptz '2000-01-01') order by registrado_em) rn
      from public.localizacoes
     where corrida_id is null and registrado_em < now() - make_interval(hours => v_h::int)
       and registrado_em > now() - make_interval(hours => v_h::int) - interval '45 days'
  )
  delete from public.localizacoes l using (select id from c where rn > 1 limit greatest(p_max, 1)) x where l.id = x.id;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke execute on function privado.afinar_ociosos(int) from public, anon, authenticated;

create or replace function public.dev_afinar_gps()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_a int; v_b int;
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  v_a := privado.afinar_pings(200);
  v_b := privado.afinar_ociosos(200000);
  return jsonb_build_object('rotas', v_a, 'fora_de_rota', v_b, 'pings_total', (select count(*) from public.localizacoes));
end;
$$;
revoke execute on function public.dev_afinar_gps() from public, anon;
grant execute on function public.dev_afinar_gps() to authenticated;

-- Dev: deixa um motoboy offline na hora (aparelho perdido, app travado)
create or replace function public.dev_forcar_offline(p_motoboy uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  if exists (select 1 from public.corridas where motoboy_id = p_motoboy and status::text in ('aceita', 'em_andamento')) then
    raise exception 'membro_em_corrida' using errcode = '22023';
  end if;
  update public.motoboys set status = 'offline' where id = p_motoboy;
  return jsonb_build_object('ok', found);
end;
$$;
revoke execute on function public.dev_forcar_offline(uuid) from public, anon;
grant execute on function public.dev_forcar_offline(uuid) to authenticated;

do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'cron') and exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'cron' and p.proname = 'schedule') then
    perform cron.schedule('pwex-afinar-ociosos', '23 * * * *', 'select privado.afinar_ociosos(50000)');
  end if;
end $$;

-- ===================================================================== relatórios (Excel, PDF e e-mail)
-- Linhas prontas para planilha: rotas, pedidos, motoboys ou clientes no período (só da empresa de quem pede, sem teste).
create or replace function public.relatorio(p_tipo text, p_de date, p_ate date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_de timestamptz := (p_de::timestamp) at time zone 'America/Sao_Paulo';
  v_ate timestamptz := ((p_ate + 1)::timestamp) at time zone 'America/Sao_Paulo';
  v_teste boolean := coalesce((select p.modo_teste from public.perfis p where p.id = auth.uid()), false);
  r jsonb;
begin
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
revoke execute on function public.relatorio(text, date, date) from public, anon;
grant execute on function public.relatorio(text, date, date) to authenticated;

-- ===================================================================== cliente em mais de uma empresa
-- Cada conta de cliente pode ser cliente de várias transportadoras; escolhe com qual está pedindo agora.
create table if not exists public.cliente_vinculos (
  usuario_id     uuid not null references public.perfis (id) on delete cascade,
  empresa_id     uuid not null references public.empresas (id) on delete cascade,
  organizacao_id uuid references public.organizacoes (id) on delete cascade,
  criado_em      timestamptz not null default now(),
  primary key (usuario_id, empresa_id)
);
alter table public.cliente_vinculos enable row level security;
drop policy if exists cliente_vinculos_meus on public.cliente_vinculos;
create policy cliente_vinculos_meus on public.cliente_vinculos for select to authenticated using (usuario_id = (select auth.uid()) or (select public.is_dev()));
grant select on public.cliente_vinculos to authenticated;

insert into public.cliente_vinculos (usuario_id, empresa_id, organizacao_id)
  select p.id, p.empresa_id, e.organizacao_id from public.perfis p join public.empresas e on e.id = p.empresa_id
   where p.empresa_id is not null and 'cliente' = any (p.papeis)
  on conflict do nothing;

create or replace function privado.lembrar_vinculo_cliente()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.empresa_id is not null and 'cliente' = any (new.papeis) then
    insert into public.cliente_vinculos (usuario_id, empresa_id, organizacao_id)
    values (new.id, new.empresa_id, (select organizacao_id from public.empresas where id = new.empresa_id))
    on conflict do nothing;
  end if;
  return new;
end;
$$;
drop trigger if exists lembrar_vinculo_cliente on public.perfis;
create trigger lembrar_vinculo_cliente after insert or update of empresa_id, papeis on public.perfis for each row execute function privado.lembrar_vinculo_cliente();

-- aprovar cadastro: procura o cliente só dentro da transportadora do cadastro, e a conta passa a pedir para ela
create or replace function privado.aprovar_cadastro(p_id uuid, p_opcoes jsonb default '{}')
returns uuid language plpgsql security definer set search_path = '' as $$
declare c public.cadastros_cliente%rowtype; v_emp uuid; v_cobr text;
begin
  select * into c from public.cadastros_cliente where id = p_id for update;
  if not found then raise exception 'cadastro_nao_encontrado' using errcode = '22023'; end if;
  if c.status = 'aprovado' then return c.empresa_id; end if;
  if c.organizacao_id is not null then perform set_config('pwex.org', c.organizacao_id::text, true); end if;
  if c.documento is not null then
    select id into v_emp from public.empresas
     where ((c.tipo = 'pj' and cnpj = c.documento) or (c.tipo = 'pf' and cpf = c.documento))
       and organizacao_id is not distinct from c.organizacao_id limit 1;
  end if;
  if v_emp is null then
    insert into public.empresas (nome, tipo, cnpj, cpf, telefone, email, endereco, lat, lng, modalidade_preco, pode_express, organizacao_id)
    values (c.nome, c.tipo, case when c.tipo = 'pj' then c.documento end, case when c.tipo = 'pf' then c.documento end,
            c.telefone, c.email, c.endereco, c.lat, c.lng, 'por_km',
            coalesce((p_opcoes ->> 'pode_express')::boolean, privado.cfg_bool('cadastro_express_liberado', false)), c.organizacao_id)
    returning id into v_emp;
  end if;
  v_cobr := coalesce(nullif(p_opcoes ->> 'cobranca', ''), privado.cfg_txt('cadastro_cobranca', 'pre_pago'));
  if v_cobr in ('pre_pago', 'credito') and v_cobr <> privado.cfg_txt('cobranca_modo', 'credito') then
    insert into public.politicas (escopo, alvo, chave, valor) values ('cliente', v_emp::text, 'cobranca_modo', to_jsonb(v_cobr))
    on conflict (escopo, alvo, chave) do update set valor = excluded.valor, atualizado_em = now();
  end if;
  if c.perfil_id is not null then
    update public.perfis set empresa_id = v_emp, organizacao_id = coalesce(c.organizacao_id, organizacao_id),
           papeis = (select array_agg(distinct x) from unnest(papeis || '{cliente}'::public.papel_usuario[]) x),
           nome = case when coalesce(nome, '') = '' then coalesce(c.responsavel, c.nome) else nome end
     where id = c.perfil_id and not ('gestor' = any (papeis) or 'motoboy' = any (papeis) or 'supervisor' = any (papeis) or 'dev' = any (papeis));
    -- conta da equipe que também é cliente: só ganha o vínculo, sem sair da empresa dela
    insert into public.cliente_vinculos (usuario_id, empresa_id, organizacao_id) values (c.perfil_id, v_emp, c.organizacao_id) on conflict do nothing;
  end if;
  update public.cadastros_cliente set status = 'aprovado', empresa_id = v_emp, revisado_por = auth.uid(), revisado_em = now(), motivo = null where id = c.id;
  return v_emp;
end;
$$;
revoke execute on function privado.aprovar_cadastro(uuid, jsonb) from public, anon, authenticated;

-- as transportadoras de que sou cliente (e qual está valendo agora)
create or replace function public.minhas_empresas_cliente()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('empresa_id', v.empresa_id, 'cliente', e.nome, 'organizacao_id', v.organizacao_id,
           'nome', coalesce(o.nome_app, o.nome), 'logo', o.logo_url, 'cor', o.cor, 'slug', o.slug,
           'atual', v.empresa_id = (select p.empresa_id from public.perfis p where p.id = auth.uid())) order by coalesce(o.nome_app, o.nome)), '[]'::jsonb)
    from public.cliente_vinculos v join public.empresas e on e.id = v.empresa_id left join public.organizacoes o on o.id = v.organizacao_id
   where v.usuario_id = auth.uid() and (o.id is null or o.status in ('ativa', 'teste'));
$$;
revoke execute on function public.minhas_empresas_cliente() from public, anon;
grant execute on function public.minhas_empresas_cliente() to authenticated;

create or replace function public.trocar_empresa_cliente(p_empresa uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v public.cliente_vinculos%rowtype;
begin
  select * into v from public.cliente_vinculos where usuario_id = auth.uid() and empresa_id = p_empresa;
  if not found then raise exception 'sem_vinculo' using errcode = '42501'; end if;
  if exists (select 1 from public.perfis where id = auth.uid() and ('gestor' = any (papeis) or 'motoboy' = any (papeis) or 'supervisor' = any (papeis) or 'dev' = any (papeis))) then
    raise exception 'conta_da_equipe' using errcode = '22023';
  end if;
  update public.perfis set empresa_id = v.empresa_id, organizacao_id = coalesce(v.organizacao_id, organizacao_id) where id = auth.uid();
  return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function public.trocar_empresa_cliente(uuid) from public, anon;
grant execute on function public.trocar_empresa_cliente(uuid) to authenticated;

-- já sou cliente de uma: peço para ser de outra (usa os dados do meu cadastro atual)
create or replace function public.pedir_outra_empresa(p_slug text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_org uuid; e public.empresas%rowtype; v_id uuid; v_modo text;
begin
  select o.id into v_org from public.organizacoes o where o.slug = lower(trim(p_slug)) and o.status in ('ativa', 'teste');
  if v_org is null then raise exception 'empresa_nao_encontrada' using errcode = '22023'; end if;
  if exists (select 1 from public.cliente_vinculos where usuario_id = auth.uid() and organizacao_id = v_org) then raise exception 'ja_cliente' using errcode = '22023'; end if;
  if exists (select 1 from public.cadastros_cliente where perfil_id = auth.uid() and organizacao_id = v_org and status = 'pendente') then raise exception 'ja_pedido' using errcode = '22023'; end if;
  select x.* into e from public.empresas x join public.perfis p on p.empresa_id = x.id where p.id = auth.uid();
  if not found then raise exception 'sem_cadastro' using errcode = '22023'; end if;
  perform set_config('pwex.org', v_org::text, true);
  v_modo := privado.cfg_org_txt(v_org, 'cadastro_cliente_modo', 'aprovacao');
  if v_modo = 'desligado' then raise exception 'cadastro_desligado' using errcode = '42501'; end if;
  insert into public.cadastros_cliente (perfil_id, email, nome, responsavel, tipo, documento, telefone, endereco, lat, lng, observacoes, organizacao_id)
  values (auth.uid(), coalesce(e.email, (select u.email from auth.users u where u.id = auth.uid())), e.nome, null, coalesce(e.tipo, 'pj'),
          coalesce(e.cnpj, e.cpf), e.telefone, e.endereco, e.lat, e.lng, 'Já é cliente de outra transportadora na Delibra.', v_org)
  returning id into v_id;
  if v_modo = 'instantaneo' then perform privado.aprovar_cadastro(v_id); end if;
  return (select jsonb_build_object('id', c.id, 'status', c.status) from public.cadastros_cliente c where c.id = v_id);
end;
$$;
revoke execute on function public.pedir_outra_empresa(text) from public, anon;
grant execute on function public.pedir_outra_empresa(text) to authenticated;

-- cards do cadastro: área aproximada de cada transportadora (centro das entregas, ~1 km) para mostrar a distância
create or replace function public.empresas_cadastro()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'slug', o.slug, 'nome', coalesce(o.nome_app, o.nome), 'logo', o.logo_url, 'cor', o.cor,
           'modo', privado.cfg_org_txt(o.id, 'cadastro_cliente_modo', 'aprovacao'),
           'nota', (select round(avg(a.nota)::numeric, 1) from public.avaliacoes a where a.organizacao_id = o.id),
           'avaliacoes', (select count(*) from public.avaliacoes a where a.organizacao_id = o.id),
           'entregas', (select count(*) from public.corridas c where c.organizacao_id = o.id and c.status::text = 'concluida' and not c.teste),
           'lat', (select round(avg(x.lat)::numeric, 2) from (select p.lat from public.paradas p join public.corridas c on c.id = p.corrida_id
                     where c.organizacao_id = o.id and not c.teste and c.status::text = 'concluida' order by c.concluida_em desc limit 300) x),
           'lng', (select round(avg(x.lng)::numeric, 2) from (select p.lng from public.paradas p join public.corridas c on c.id = p.corrida_id
                     where c.organizacao_id = o.id and not c.teste and c.status::text = 'concluida' order by c.concluida_em desc limit 300) x)
         ) order by coalesce(o.nome_app, o.nome)), '[]'::jsonb)
    from public.organizacoes o
   where o.slug is not null and o.status in ('ativa', 'teste')
     and privado.cfg_org_txt(o.id, 'cadastro_cliente_modo', 'aprovacao') <> 'desligado';
$$;
grant execute on function public.empresas_cadastro() to anon, authenticated;

-- ===================================================================== módulos ligados aos fluxos (e-mail, WhatsApp, nota, devolução)
-- Tudo passa por uma fila: o banco anota o que precisa sair e o site manda pelo provedor conectado.
-- Sem provedor conectado (Ajustes → Integrações, só o Dev), nada entra na fila.
create table if not exists privado.avisos_externos (
  id             bigint generated always as identity primary key,
  organizacao_id uuid,
  canal          text not null check (canal in ('email', 'whatsapp', 'nota')),
  para           text,
  assunto        text,
  corpo          jsonb not null default '{}',
  status         text not null default 'pendente' check (status in ('pendente', 'enviando', 'enviado', 'erro', 'sem_conexao')),
  tentativas     int not null default 0,
  erro           text,
  ref            text,
  criado_em      timestamptz not null default now(),
  enviado_em     timestamptz
);
create index if not exists avisos_externos_pendentes_idx on privado.avisos_externos (status, criado_em) where status in ('pendente', 'erro');

create or replace function privado.enfileirar(p_org uuid, p_canal text, p_para text, p_assunto text, p_corpo jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if nullif(trim(coalesce(p_para, '')), '') is null and p_canal <> 'nota' then return; end if;
  if p_canal = 'email' and privado.cfg_txt('dev_email_provedor', 'nenhum') = 'nenhum' then return; end if;
  if p_canal = 'whatsapp' and privado.cfg_txt('dev_whatsapp_provedor', 'nenhum') = 'nenhum' then return; end if;
  if p_canal = 'nota' and privado.cfg_txt('dev_nf_provedor', 'nenhum') = 'nenhum' then return; end if;
  -- a mesma nota nunca sai duas vezes
  if p_corpo ? 'referencia' and exists (select 1 from privado.avisos_externos where canal = p_canal and corpo ->> 'referencia' = p_corpo ->> 'referencia' and status <> 'erro') then return; end if;
  insert into privado.avisos_externos (organizacao_id, canal, para, assunto, corpo) values (p_org, p_canal, p_para, p_assunto, coalesce(p_corpo, '{}'));
end;
$$;

-- cadastro aprovado → e-mail para o cliente
create or replace function privado.aviso_cadastro()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'aprovado' and old.status is distinct from 'aprovado' and privado.cfg_org_bool(new.organizacao_id, 'email_aviso_cadastro', true) then
    perform privado.enfileirar(new.organizacao_id, 'email', new.email, 'Seu cadastro foi aprovado',
      jsonb_build_object('modelo', 'cadastro', 'nome', new.nome, 'empresa', (select coalesce(o.nome_app, o.nome) from public.organizacoes o where o.id = new.organizacao_id)));
  end if;
  return new;
end;
$$;
drop trigger if exists aviso_cadastro on public.cadastros_cliente;
create trigger aviso_cadastro after update of status on public.cadastros_cliente for each row execute function privado.aviso_cadastro();

-- fatura emitida → e-mail para o cliente; paga → nota (se "quando for paga")
create or replace function privado.aviso_fatura()
returns trigger language plpgsql security definer set search_path = '' as $$
declare e public.empresas%rowtype;
begin
  if new.teste then return new; end if;
  select * into e from public.empresas where id = new.empresa_id;
  if new.status = 'emitida' and old.status is distinct from 'emitida' and privado.cfg_org_bool(new.organizacao_id, 'email_aviso_fatura', true) then
    perform privado.enfileirar(new.organizacao_id, 'email', e.email, 'Fatura #' || new.numero || ' emitida',
      jsonb_build_object('modelo', 'fatura', 'nome', e.nome, 'numero', new.numero, 'total', new.total, 'vencimento', new.vencimento, 'inicio', new.inicio, 'fim', new.fim));
  end if;
  if new.status = 'paga' and old.status is distinct from 'paga' and privado.pol_txt('nf_emissao', 'manual', new.empresa_id) = 'pago' then
    perform privado.enfileirar(new.organizacao_id, 'nota', e.email, 'Nota da fatura #' || new.numero,
      jsonb_build_object('referencia', 'fatura-' || new.id, 'documento', coalesce(e.cnpj, e.cpf), 'nome', e.nome, 'email', e.email, 'valor', new.total,
                         'descricao', 'Serviços de entrega de ' || to_char(new.inicio, 'DD/MM/YYYY') || ' a ' || to_char(new.fim, 'DD/MM/YYYY')));
  end if;
  return new;
end;
$$;
drop trigger if exists aviso_fatura on public.faturas;
create trigger aviso_fatura after update of status on public.faturas for each row execute function privado.aviso_fatura();

-- pedido entregue → e-mail (se ligado) e nota (se "quando for entregue"); pago e cancelado → aviso da devolução
create or replace function privado.aviso_pedido()
returns trigger language plpgsql security definer set search_path = '' as $$
declare e public.empresas%rowtype; v_regra text; v_dev numeric;
begin
  if new.teste then return new; end if;
  select * into e from public.empresas where id = new.empresa_id;
  if new.status::text = 'concluido' and old.status::text is distinct from 'concluido' then
    if privado.cfg_org_bool(new.organizacao_id, 'email_aviso_entregue', false) then
      perform privado.enfileirar(new.organizacao_id, 'email', e.email, 'Pedido #' || new.numero || ' entregue', jsonb_build_object('modelo', 'entregue', 'nome', e.nome, 'numero', new.numero));
    end if;
    if new.empresa_id is not null and privado.pol_txt('nf_emissao', 'manual', new.empresa_id) = 'entregue' then
      perform privado.enfileirar(new.organizacao_id, 'nota', e.email, 'Nota do pedido #' || new.numero,
        jsonb_build_object('referencia', 'pedido-' || new.id, 'documento', coalesce(e.cnpj, e.cpf), 'nome', e.nome, 'email', e.email, 'valor', new.valor, 'descricao', 'Entrega do pedido #' || new.numero));
    end if;
  end if;
  if new.pagamento_status::text = 'pago' and old.pagamento_status::text is distinct from 'pago' and new.empresa_id is not null and privado.pol_txt('nf_emissao', 'manual', new.empresa_id) = 'pago' then
    perform privado.enfileirar(new.organizacao_id, 'nota', e.email, 'Nota do pedido #' || new.numero,
      jsonb_build_object('referencia', 'pedido-' || new.id, 'documento', coalesce(e.cnpj, e.cpf), 'nome', e.nome, 'email', e.email, 'valor', new.valor, 'descricao', 'Entrega do pedido #' || new.numero));
  end if;
  if new.status::text = 'cancelado' and old.status::text is distinct from 'cancelado' and new.pagamento_status::text = 'pago' then
    v_regra := privado.pol_txt('devolucao_padrao', 'total', new.empresa_id);
    v_dev := case v_regra when 'total' then new.valor when 'taxa' then greatest(coalesce(new.valor, 0) - privado.pol_num('devolucao_taxa', 0, new.empresa_id), 0)
                          when 'nada_coletado' then case when exists (select 1 from public.pedido_pontos x where x.pedido_id = new.id and x.tipo::text = 'coleta' and x.status::text = 'concluido') then 0 else new.valor end
                          else null end;
    perform privado.enfileirar(new.organizacao_id, 'email', e.email, 'Pedido #' || new.numero || ' cancelado',
      jsonb_build_object('modelo', 'devolucao', 'nome', e.nome, 'numero', new.numero, 'valor', new.valor, 'devolver', v_dev, 'regra', v_regra));
  end if;
  return new;
end;
$$;
drop trigger if exists aviso_pedido on public.pedidos;
create trigger aviso_pedido after update of status, pagamento_status on public.pedidos for each row execute function privado.aviso_pedido();

-- rota saiu → WhatsApp para quem recebe, com o link de acompanhar (se ligado)
create or replace function privado.aviso_rota_saiu()
returns trigger language plpgsql security definer set search_path = '' as $$
declare k record; v_tok text; v_site text := coalesce(nullif(privado.cfg('dev_site_url', '""'::jsonb) #>> '{}', ''), '');
begin
  if new.teste or new.status::text <> 'em_andamento' or old.status::text = 'em_andamento' then return new; end if;
  if not privado.cfg_org_bool(new.organizacao_id, 'whatsapp_aviso_rastreio', false) then return new; end if;
  for k in select distinct on (pp.id) pp.id ponto, pp.pedido_id, pp.contato_telefone, pp.contato_nome
             from public.paradas x join public.pedido_pontos pp on pp.pedido_id = x.pedido_id and pp.tipo::text = 'entrega'
            where x.corrida_id = new.id and x.tipo::text = 'entrega' and nullif(pp.contato_telefone, '') is not null loop
    select token into v_tok from public.rastreios where pedido_id = k.pedido_id and ponto_id = k.ponto and (expira_em is null or expira_em > now()) limit 1;
    if v_tok is null then insert into public.rastreios (pedido_id, ponto_id) values (k.pedido_id, k.ponto) returning token into v_tok; end if;
    perform privado.enfileirar(new.organizacao_id, 'whatsapp', regexp_replace(k.contato_telefone, '[^0-9]', '', 'g'), null,
      jsonb_build_object('modelo', privado.cfg_org_txt(new.organizacao_id, 'whatsapp_modelo_rastreio', 'rastreio_entrega'),
                         'variaveis', jsonb_build_array(coalesce(k.contato_nome, ''), v_site || '/r/' || v_tok)));
  end loop;
  return new;
exception when others then
  raise warning 'aviso_rota_saiu: %', sqlerrm;
  return new;
end;
$$;
drop trigger if exists aviso_rota_saiu on public.corridas;
create trigger aviso_rota_saiu after update of status on public.corridas for each row execute function privado.aviso_rota_saiu();

-- o site pega a fila (com o segredo do servidor) e devolve o resultado
create or replace function public.avisos_externos_pegar(p_limite int default 20)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r jsonb;
begin
  if not privado.eh_servico() then raise exception 'apenas_servidor' using errcode = '42501'; end if;
  with x as (
    select id from privado.avisos_externos
     where (status = 'pendente' or (status = 'erro' and tentativas < 5 and criado_em > now() - interval '2 days')
            or (status = 'enviando' and criado_em < now() - interval '10 minutes'))
     order by criado_em limit greatest(least(p_limite, 100), 1) for update skip locked)
  update privado.avisos_externos a set status = 'enviando', tentativas = a.tentativas + 1 from x where a.id = x.id;
  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'canal', a.canal, 'para', a.para, 'assunto', a.assunto, 'corpo', a.corpo,
           'empresa', (select coalesce(o.nome_app, o.nome) from public.organizacoes o where o.id = a.organizacao_id),
           'nf_provedor', privado.cfg_txt('dev_nf_provedor', 'nenhum'), 'nf_cnpj', privado.cfg_org_txt(a.organizacao_id, 'nf_cnpj_prestador', ''),
           'nf_servico', privado.cfg_org_txt(a.organizacao_id, 'nf_codigo_servico', '')) order by a.id), '[]') into r
    from privado.avisos_externos a where a.status = 'enviando' and a.enviado_em is null and a.tentativas > 0
     and a.id in (select id from privado.avisos_externos where status = 'enviando' order by id limit 100);
  return r;
end;
$$;
create or replace function public.avisos_externos_resultado(p_id bigint, p_status text, p_erro text default null, p_ref text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not privado.eh_servico() then raise exception 'apenas_servidor' using errcode = '42501'; end if;
  update privado.avisos_externos set status = case when p_status in ('enviado', 'erro', 'sem_conexao') then p_status else 'erro' end,
         erro = left(p_erro, 500), ref = left(p_ref, 200), enviado_em = case when p_status = 'enviado' then now() end where id = p_id;
end;
$$;
revoke execute on function public.avisos_externos_pegar(int), public.avisos_externos_resultado(bigint, text, text, text) from public, anon, authenticated;
do $$ begin
  execute 'grant execute on function public.avisos_externos_pegar(int), public.avisos_externos_resultado(bigint, text, text, text) to service_role';
exception when undefined_object then null; end $$;

-- a cada minuto, se tem algo na fila, chama o site
create or replace function privado.chamar_avisos_externos()
returns void language plpgsql security definer set search_path = '' as $$
declare v_url text; v_secret text;
begin
  if not exists (select 1 from privado.avisos_externos where status = 'pendente' or (status = 'erro' and tentativas < 5 and criado_em > now() - interval '2 days')) then return; end if;
  select replace(valor, '/api/push', '/api/avisos/processar') into v_url from privado.config where chave = 'push_url';
  select valor into v_secret from privado.config where chave = 'push_secret';
  if v_url is null or v_secret is null then return; end if;
  perform net.http_post(url := v_url, body := '{}'::jsonb,
                        headers := jsonb_build_object('Content-Type', 'application/json', 'x-pwex-secret', v_secret), timeout_milliseconds := 20000);
exception when others then
  raise warning 'chamar_avisos_externos: %', sqlerrm;
end;
$$;
do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'cron') and exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'cron' and p.proname = 'schedule') then
    perform cron.schedule('pwex-avisos-externos', '* * * * *', 'select privado.chamar_avisos_externos()');
  end if;
end $$;

-- Dev: o que saiu (ou não) pela fila
create or replace function public.dev_avisos_externos(p_limite int default 100)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'canal', a.canal, 'para', a.para, 'assunto', a.assunto, 'status', a.status, 'erro', a.erro,
            'tentativas', a.tentativas, 'criado_em', a.criado_em, 'enviado_em', a.enviado_em,
            'empresa', (select o.nome from public.organizacoes o where o.id = a.organizacao_id)) order by a.id desc), '[]')
    from (select * from privado.avisos_externos order by id desc limit least(greatest(p_limite, 1), 500)) a);
end;
$$;
revoke execute on function public.dev_avisos_externos(int) from public, anon;
grant execute on function public.dev_avisos_externos(int) to authenticated;
