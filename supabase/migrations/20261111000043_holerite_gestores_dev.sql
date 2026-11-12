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
