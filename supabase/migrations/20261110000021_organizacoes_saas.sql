-- =====================================================================
-- Delibra · 0021 (parte 2 de 2): plataforma multiempresa (SaaS)
-- Rode DEPOIS de 20261110000020_cargo_supervisor.sql.
--
--  • Organizações: cada gestor é uma empresa (transportadora) na Delibra, com a
--    própria equipe, clientes, pedidos, rotas, chat e ajustes.
--  • Hierarquia: Dev (plataforma, acima de todas) → Gestor (dono da empresa) →
--    Supervisor (líder de equipe, com permissões que o gestor escolhe) → Motoboy / Cliente.
--  • Isolamento: regras RESTRITIVAS por empresa por cima das que já existem
--    (o banco recusa ler/gravar dados de outra empresa, mesmo que o app peça).
--  • Alcance: o Dev decide se as corridas de uma empresa chegam a motoboys de outra
--    (nunca · só sem motoboy livre · sempre · só entre parceiras).
--  • Cobrança da plataforma: percentual do faturamento (padrão 5%), licença mensal ou isenta,
--    com histórico de licenças e o painel de faturamento do Dev.
--  • Conta do Dev: só o próprio Dev mexe nela. O Dev pode se ocultar (aparece como "Dev").
--  • Chat: o Dev lê e apaga qualquer conversa; ajustes do que pode ser enviado.
--  • Ajustes por empresa: o gestor muda os ajustes da empresa dele, sem mexer nos das outras.
-- =====================================================================

set check_function_bodies = off;

-- ===================================================================== organizações
create table if not exists public.organizacoes (
  id                     uuid primary key default gen_random_uuid(),
  nome                   text not null,
  slug                   text unique,
  documento              text,
  logo_url               text,
  cor                    text,
  dono_id                uuid references public.perfis (id) on delete set null,
  status                 text not null default 'ativa' check (status in ('teste', 'ativa', 'suspensa', 'cancelada')),
  cobranca_modelo        text not null default 'percentual' check (cobranca_modelo in ('percentual', 'licenca', 'isento')),
  cobranca_pct           numeric not null default 5 check (cobranca_pct between 0 and 100),
  mensalidade            numeric not null default 0 check (mensalidade >= 0),
  vencimento_dia         int not null default 10 check (vencimento_dia between 1 and 28),
  limites                jsonb not null default '{}',
  compartilhar           text not null default 'nunca' check (compartilhar in ('nunca', 'sem_livre', 'sempre', 'parceiros')),
  compartilhar_apos_min  int not null default 3 check (compartilhar_apos_min between 0 and 240),
  receber_de_outras      boolean not null default false,
  parceiros              uuid[] not null default '{}',
  observacoes            text,
  criado_em              timestamptz not null default now()
);
alter table public.organizacoes enable row level security;

create table if not exists public.licencas (
  id              uuid primary key default gen_random_uuid(),
  organizacao_id  uuid not null references public.organizacoes (id) on delete cascade,
  modelo          text not null check (modelo in ('percentual', 'licenca', 'isento')),
  valor           numeric not null default 0 check (valor >= 0),
  pct             numeric not null default 0 check (pct between 0 and 100),
  inicio          date not null default current_date,
  fim             date,
  status          text not null default 'ativa' check (status in ('ativa', 'encerrada', 'cancelada')),
  observacoes     text,
  criado_por      uuid references public.perfis (id) on delete set null,
  criado_em       timestamptz not null default now()
);
create index if not exists licencas_org on public.licencas (organizacao_id, inicio desc);
alter table public.licencas enable row level security;

-- ===================================================================== perfis
alter table public.perfis add column if not exists organizacao_id uuid references public.organizacoes (id) on delete set null;
alter table public.perfis add column if not exists responsavel_id uuid references public.perfis (id) on delete set null;
alter table public.perfis add column if not exists permissoes jsonb not null default '{}';
alter table public.perfis add column if not exists dev_oculto boolean not null default false;
alter table public.perfis add column if not exists org_em_foco uuid references public.organizacoes (id) on delete set null;
create index if not exists perfis_org on public.perfis (organizacao_id);

-- ===================================================================== papéis
-- Supervisor conta como gestor nas regras que já existem (vê pedidos, rotas, motoboys)…
create or replace function public.is_gestor()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.perfis where id = auth.uid() and papeis && array['gestor', 'dev', 'supervisor']::public.papel_usuario[]);
$$;
-- …mas o que é só do dono da empresa (ou do Dev) usa este:
create or replace function public.is_gestor_pleno()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.perfis where id = auth.uid() and papeis && array['gestor', 'dev']::public.papel_usuario[]);
$$;
create or replace function public.is_supervisor()
returns boolean language sql stable security definer set search_path = '' as $$
  select public.tem_papel('supervisor'::public.papel_usuario) and not public.is_gestor_pleno();
$$;

-- O que um supervisor pode fazer (o gestor escolhe). Gestor e Dev podem tudo.
create or replace function public.pode(p_acao text)
returns boolean language sql stable security definer set search_path = '' as $$
  select case
    when auth.uid() is null or public.is_gestor_pleno() then true
    when public.is_supervisor() then coalesce(
      (select (p.permissoes ->> p_acao)::boolean from public.perfis p where p.id = auth.uid() and jsonb_typeof(p.permissoes -> p_acao) = 'boolean'),
      p_acao in ('pedidos', 'rotas', 'motoboys', 'cadastrar', 'chat', 'mapa', 'clientes'))
    else false end;
$$;

-- Empresa de quem chamou. O Dev não pertence a nenhuma: vê todas, ou só a que escolheu "olhar".
create or replace function public.minha_org()
returns uuid language sql stable security definer set search_path = '' as $$
  select case when 'dev' = any (p.papeis) then p.org_em_foco else p.organizacao_id end
    from public.perfis p where p.id = auth.uid();
$$;

-- Dados de uma empresa: só ela vê. Sem empresa (null) = da plataforma: só o Dev.
create or replace function public.ve_org(p_org uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select auth.uid() is null
      or (public.is_dev() and (public.minha_org() is null or p_org is not distinct from public.minha_org()))
      or (p_org is not null and p_org = public.minha_org());
$$;
-- Catálogos (tipos, categorias, zonas): os sem empresa valem para todas.
create or replace function public.ve_org_ou_global(p_org uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_org is null or public.ve_org(p_org);
$$;

-- As corridas de uma empresa chegam a motoboys de outra? (o Dev decide por empresa)
create or replace function public.org_alcanca(p_origem uuid, p_destino uuid, p_desde timestamptz default null)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare o public.organizacoes%rowtype; d public.organizacoes%rowtype;
begin
  if p_origem is null or p_destino is null or p_origem = p_destino then return true; end if;
  if not privado.cfg_bool('saas_compartilhar_corridas', true) then return false; end if;
  select * into o from public.organizacoes where id = p_origem;
  select * into d from public.organizacoes where id = p_destino;
  if o.id is null or d.id is null or d.status in ('suspensa', 'cancelada') then return false; end if;
  return case o.compartilhar
    when 'sempre' then d.receber_de_outras
    when 'parceiros' then p_destino = any (o.parceiros)
    when 'sem_livre' then d.receber_de_outras and (p_desde is null or p_desde < now() - make_interval(mins => o.compartilhar_apos_min))
    else false end;
end;
$$;

-- Nome e foto que os outros veem (o Dev oculto aparece só como "Dev", com o ícone </>)
create or replace function public.dev_oculto_para_mim(p_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.perfis p where p.id = p_id and p.dev_oculto and 'dev' = any (p.papeis))
     and p_id is distinct from auth.uid() and not public.is_dev();
$$;
create or replace function public.nome_publico(p_id uuid)
returns text language sql stable security definer set search_path = '' as $$
  select case when public.dev_oculto_para_mim(p_id) then 'Dev' else (select nome from public.perfis where id = p_id) end;
$$;
create or replace function public.foto_publica(p_id uuid)
returns text language sql stable security definer set search_path = '' as $$
  select case when public.dev_oculto_para_mim(p_id) then null else (select foto_url from public.perfis where id = p_id) end;
$$;

-- Quem eu enxergo: eu, a minha empresa, o motoboy de outra empresa fazendo uma rota nossa,
-- e o Dev (se ele não estiver oculto e for da equipe). O Dev vê todo mundo.
create or replace function public.ve_pessoa(p_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select auth.uid() is null or p_id = auth.uid() or exists (
    select 1 from public.perfis p where p.id = p_id and (
         (public.is_dev() and (public.minha_org() is null or p.organizacao_id is not distinct from public.minha_org() or 'dev' = any (p.papeis)))
      or (not public.dev_oculto_para_mim(p.id) and p.organizacao_id is not null and p.organizacao_id = public.minha_org())
      or exists (select 1 from public.corridas c where c.motoboy_id = p.id and c.organizacao_id = public.minha_org()
                  and c.status in ('aceita', 'em_andamento', 'reservada'))));
$$;

-- ===================================================================== organização em cada dado
do $$
declare t text;
begin
  foreach t in array array['empresas', 'pedidos', 'corridas', 'chat_conversas', 'zonas', 'tipos_pedido', 'categorias_produto',
                           'faturas', 'holerites', 'pedido_modelos', 'cadastros_cliente', 'conquistas_manuais', 'decisoes_rota'] loop
    execute format('alter table public.%I add column if not exists organizacao_id uuid references public.organizacoes (id) on delete cascade', t);
    execute format('create index if not exists %I on public.%I (organizacao_id)', t || '_org', t);
  end loop;
end $$;

-- Ao criar: herda a empresa do cliente (pedidos/corridas) ou de quem criou.
create or replace function privado.org_padrao()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_emp uuid;
begin
  if new.organizacao_id is not null then return new; end if;
  if tg_table_name in ('pedidos', 'corridas', 'faturas', 'decisoes_rota') then
    begin v_emp := (to_jsonb(new) ->> 'empresa_id')::uuid; exception when others then v_emp := null; end;
    if v_emp is not null then select organizacao_id into new.organizacao_id from public.empresas where id = v_emp; end if;
  end if;
  if new.organizacao_id is null and tg_table_name = 'corridas' and (to_jsonb(new) ->> 'pedido_id') is not null then
    select organizacao_id into new.organizacao_id from public.pedidos where id = (to_jsonb(new) ->> 'pedido_id')::uuid;
  end if;
  if new.organizacao_id is null and tg_table_name = 'holerites' then
    select organizacao_id into new.organizacao_id from public.perfis where id = (to_jsonb(new) ->> 'motoboy_id')::uuid;
  end if;
  if new.organizacao_id is null then
    new.organizacao_id := coalesce(nullif(current_setting('pwex.org', true), '')::uuid, public.minha_org());
  end if;
  return new;
end;
$$;
do $$
declare t text;
begin
  foreach t in array array['empresas', 'pedidos', 'corridas', 'chat_conversas', 'zonas', 'tipos_pedido', 'categorias_produto',
                           'faturas', 'holerites', 'pedido_modelos', 'cadastros_cliente', 'conquistas_manuais', 'decisoes_rota'] loop
    execute format('drop trigger if exists org_padrao on public.%I', t);
    execute format('create trigger org_padrao before insert on public.%I for each row execute function privado.org_padrao()', t);
  end loop;
end $$;

-- Perfil novo criado por um gestor/supervisor: entra na empresa dele, com ele como responsável.
create or replace function privado.perfil_org_padrao()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.organizacao_id is null and auth.uid() is not null and auth.uid() <> new.id then
    new.organizacao_id := (select organizacao_id from public.perfis where id = auth.uid());
  end if;
  if new.responsavel_id is null and auth.uid() is not null and auth.uid() <> new.id then new.responsavel_id := auth.uid(); end if;
  return new;
end;
$$;
drop trigger if exists perfil_org_padrao on public.perfis;
create trigger perfil_org_padrao before insert or update of papeis on public.perfis for each row execute function privado.perfil_org_padrao();

-- Banco que já tinha dados (sem empresa): tudo vai para uma empresa principal.
do $$
declare v_org uuid; v_dono uuid;
begin
  if exists (select 1 from public.perfis where organizacao_id is null and not ('dev' = any (papeis)))
     and not exists (select 1 from public.organizacoes) then
    select id into v_dono from public.perfis where 'gestor' = any (papeis) and not ('dev' = any (papeis)) order by criado_em limit 1;
    insert into public.organizacoes (nome, slug, dono_id) values ('Empresa principal', 'principal', v_dono) returning id into v_org;
    update public.perfis set organizacao_id = v_org where organizacao_id is null;
    update public.empresas set organizacao_id = v_org where organizacao_id is null;
    update public.pedidos set organizacao_id = v_org where organizacao_id is null;
    update public.corridas set organizacao_id = v_org where organizacao_id is null;
    update public.chat_conversas set organizacao_id = v_org where organizacao_id is null;
    update public.faturas set organizacao_id = v_org where organizacao_id is null;
    update public.holerites set organizacao_id = v_org where organizacao_id is null;
    update public.pedido_modelos set organizacao_id = v_org where organizacao_id is null;
    update public.cadastros_cliente set organizacao_id = v_org where organizacao_id is null;
    update public.conquistas_manuais set organizacao_id = v_org where organizacao_id is null;
    update public.decisoes_rota set organizacao_id = v_org where organizacao_id is null;
  end if;
end $$;

-- ===================================================================== isolamento (regras restritivas)
-- Elas se somam (E) às regras que já existem: nada que era permitido fica mais aberto.
create or replace function public.ve_corrida(p_corrida uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.corridas c where c.id = p_corrida and (
       public.ve_org(c.organizacao_id)
    or c.motoboy_id = auth.uid() or c.motoboy_designado_id = auth.uid()
    or exists (select 1 from public.ofertas o where o.corrida_id = c.id and o.motoboy_id = auth.uid())
    or (c.status in ('aguardando_motoboy', 'sem_motoboy') and c.modo_despacho::text = 'quadro'
        and exists (select 1 from public.perfis p where p.id = auth.uid() and 'motoboy' = any (p.papeis))
        and public.org_alcanca(c.organizacao_id, (select organizacao_id from public.perfis where id = auth.uid()), c.quadro_desde))));
$$;
create or replace function public.ve_pedido(p_pedido uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.pedidos x where x.id = p_pedido and public.ve_org(x.organizacao_id))
      or exists (select 1 from public.corridas c join public.paradas pa on pa.corrida_id = c.id
                  where pa.pedido_id = p_pedido and (c.motoboy_id = auth.uid() or c.motoboy_designado_id = auth.uid()));
$$;

do $$
declare t text;
begin
  foreach t in array array['empresas', 'pedidos', 'chat_conversas', 'faturas', 'holerites', 'pedido_modelos',
                           'cadastros_cliente', 'conquistas_manuais', 'decisoes_rota'] loop
    execute format('drop policy if exists org_isolamento on public.%I', t);
    execute format('create policy org_isolamento on public.%I as restrictive for all to authenticated using (public.ve_org(organizacao_id)) with check (public.ve_org(organizacao_id))', t);
  end loop;
  foreach t in array array['zonas', 'tipos_pedido', 'categorias_produto'] loop
    execute format('drop policy if exists org_isolamento on public.%I', t);
    execute format('create policy org_isolamento on public.%I as restrictive for all to authenticated using (public.ve_org_ou_global(organizacao_id)) with check (public.ve_org_ou_global(organizacao_id))', t);
  end loop;
end $$;
drop policy if exists org_isolamento on public.corridas;
create policy org_isolamento on public.corridas as restrictive for all to authenticated
  using (public.ve_corrida(id)) with check (public.ve_org(organizacao_id) or motoboy_id = auth.uid());
drop policy if exists org_isolamento on public.paradas;
create policy org_isolamento on public.paradas as restrictive for all to authenticated using (public.ve_corrida(corrida_id));
drop policy if exists org_isolamento on public.eventos_corrida;
create policy org_isolamento on public.eventos_corrida as restrictive for all to authenticated using (public.ve_corrida(corrida_id));
drop policy if exists org_isolamento on public.ofertas;
create policy org_isolamento on public.ofertas as restrictive for all to authenticated using (motoboy_id = auth.uid() or public.ve_corrida(corrida_id));
do $$
declare t text;
begin
  foreach t in array array['pedido_itens', 'pedido_pontos', 'pedido_eventos'] loop
    if to_regclass('public.' || t) is not null then
      execute format('drop policy if exists org_isolamento on public.%I', t);
      execute format('create policy org_isolamento on public.%I as restrictive for all to authenticated using (public.ve_pedido(pedido_id))', t);
    end if;
  end loop;
end $$;
drop policy if exists org_isolamento on public.perfis;
create policy org_isolamento on public.perfis as restrictive for select to authenticated using (public.ve_pessoa(id));
drop policy if exists org_isolamento_mudar on public.perfis;
create policy org_isolamento_mudar on public.perfis as restrictive for update to authenticated using (public.ve_pessoa(id));
drop policy if exists org_isolamento on public.motoboys;
create policy org_isolamento on public.motoboys as restrictive for all to authenticated using (public.ve_pessoa(id));
drop policy if exists org_isolamento on public.localizacoes;
create policy org_isolamento on public.localizacoes as restrictive for all to authenticated using (public.ve_pessoa(motoboy_id));

-- organizações e licenças: o Dev vê todas; cada empresa vê a sua (licenças: só o gestor)
drop policy if exists organizacoes_leitura on public.organizacoes;
create policy organizacoes_leitura on public.organizacoes for select to authenticated
  using ((select public.is_dev()) or id = (select organizacao_id from public.perfis where id = (select auth.uid())));
drop policy if exists licencas_leitura on public.licencas;
create policy licencas_leitura on public.licencas for select to authenticated
  using ((select public.is_dev()) or ((select public.is_gestor_pleno()) and organizacao_id = (select public.minha_org())));

-- ===================================================================== chat por empresa
drop index if exists public.chat_uma_geral;
create unique index if not exists chat_uma_geral_org on public.chat_conversas (coalesce(organizacao_id, '00000000-0000-0000-0000-000000000000'::uuid)) where tipo = 'geral';
create or replace function privado.chat_geral_da_org(p_org uuid, p_nome text default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  select id into v from public.chat_conversas where tipo = 'geral' and organizacao_id is not distinct from p_org;
  if v is null then
    insert into public.chat_conversas (tipo, nome, organizacao_id)
    values ('geral', coalesce(p_nome, 'Equipe ' || coalesce((select nome from public.organizacoes where id = p_org), 'Delibra')), p_org)
    returning id into v;
  end if;
  return v;
end;
$$;

create or replace function public.chat_equipe()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.perfis p where p.id = auth.uid() and p.papeis && array['motoboy', 'gestor', 'dev', 'supervisor']::public.papel_usuario[]);
$$;

-- participo de verdade (membro, ou a geral da MINHA empresa); o Dev, além disso, lê qualquer conversa
create or replace function public.chat_participo(p_conversa uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.chat_membros m where m.conversa_id = p_conversa and m.usuario_id = auth.uid())
      or (public.chat_equipe() and privado.cfg_bool('chat_geral', true) and exists (
            select 1 from public.chat_conversas c where c.id = p_conversa and c.tipo = 'geral'
               and c.organizacao_id is not distinct from (select case when 'dev' = any (p.papeis) then p.org_em_foco else p.organizacao_id end
                                                           from public.perfis p where p.id = auth.uid())));
$$;
create or replace function public.chat_sou_membro(p_conversa uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.chat_participo(p_conversa) or public.is_dev();
$$;

create or replace function public.chat_conversas()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(x order by (x ->> 'ultima_em') desc), '[]'::jsonb) from (
    select jsonb_build_object(
      'id', c.id, 'tipo', c.tipo, 'ultima_em', c.ultima_em, 'ultima_previa', c.ultima_previa, 'ultima_minha', c.ultima_autor = auth.uid(),
      'silenciada', coalesce(eu.silenciada, false),
      'nome', case when c.tipo = 'direta' then (select public.nome_publico(p.id) from public.chat_membros m join public.perfis p on p.id = m.usuario_id
                                                 where m.conversa_id = c.id and m.usuario_id <> auth.uid() limit 1) else c.nome end,
      'foto', case when c.tipo = 'direta' then (select public.foto_publica(p.id) from public.chat_membros m join public.perfis p on p.id = m.usuario_id
                                                 where m.conversa_id = c.id and m.usuario_id <> auth.uid() limit 1) end,
      'outro', case when c.tipo = 'direta' then (select m.usuario_id from public.chat_membros m where m.conversa_id = c.id and m.usuario_id <> auth.uid() limit 1) end,
      'oculto', case when c.tipo = 'direta' then (select public.dev_oculto_para_mim(m.usuario_id) from public.chat_membros m where m.conversa_id = c.id and m.usuario_id <> auth.uid() limit 1) end,
      'papeis', case when c.tipo = 'direta' then (select to_jsonb(p.papeis) from public.chat_membros m join public.perfis p on p.id = m.usuario_id where m.conversa_id = c.id and m.usuario_id <> auth.uid() limit 1) end,
      'membros', (select count(*) from public.chat_membros m where m.conversa_id = c.id),
      'nao_lidas', (select count(*) from public.chat_mensagens g where g.conversa_id = c.id and g.autor_id is distinct from auth.uid() and g.apagada_em is null
                     and g.criada_em > coalesce(eu.lida_em, case when c.tipo = 'geral' then now() - interval '1 day' else '-infinity' end))
    ) x
      from public.chat_conversas c
      left join public.chat_membros eu on eu.conversa_id = c.id and eu.usuario_id = auth.uid()
     where privado.cfg_bool('chat_ligado', true) and public.chat_participo(c.id)
  ) t;
$$;

create or replace function public.chat_autores(p_conversa uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'nome', public.nome_publico(p.id), 'foto', public.foto_publica(p.id),
                   'oculto', public.dev_oculto_para_mim(p.id),
                   'papeis', case when public.dev_oculto_para_mim(p.id) then '["dev"]'::jsonb else to_jsonb(p.papeis) end,
                   'empresa', (select e.nome from public.empresas e where e.id = p.empresa_id))), '[]')
    from public.perfis p
   where public.chat_sou_membro(p_conversa)
     and (p.id in (select distinct g.autor_id from public.chat_mensagens g where g.conversa_id = p_conversa)
          or p.id in (select m.usuario_id from public.chat_membros m where m.conversa_id = p_conversa));
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
     where p.id <> v_eu.id
       and (public.ve_pessoa(p.id) or ('dev' = any (p.papeis) and v_gestor))
       and not exists (select 1 from auth.users u where u.id = p.id and u.banned_until > now())
       and (case
              when v_gestor then true
              when public.chat_equipe() then (p.papeis && array['gestor', 'dev', 'supervisor']::public.papel_usuario[])
                                             or ('motoboy' = any (p.papeis) and privado.cfg_bool('chat_motoboy_direta', true))
              else p.papeis && array['gestor']::public.papel_usuario[] end)), '[]'::jsonb);
end;
$$;

create or replace function public.chat_criar_grupo(p_nome text, p_membros uuid[])
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if not public.is_gestor() and not (privado.cfg_bool('chat_grupos_equipe', false) and public.chat_equipe()) then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if not public.pode('chat') then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if coalesce(trim(p_nome), '') = '' then raise exception 'nome_obrigatorio' using errcode = '22023'; end if;
  insert into public.chat_conversas (tipo, nome, criada_por) values ('grupo', left(trim(p_nome), 60), auth.uid()) returning id into v_id;
  insert into public.chat_membros (conversa_id, usuario_id)
  select v_id, u from (select distinct unnest(p_membros || auth.uid()) u) x where exists (select 1 from public.perfis p where p.id = x.u) and (public.ve_pessoa(x.u) or public.is_dev());
  return v_id;
end;
$$;

create or replace function public.chat_enviar(p_conversa uuid, p_texto text default null, p_anexo jsonb default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  c        public.chat_conversas%rowtype;
  v_id     uuid;
  v_txt    text := nullif(left(trim(coalesce(p_texto, '')), 4000), '');
  v_previa text;
  v_nome   text;
  v_m      uuid;
begin
  if auth.uid() is null then raise exception 'nao_autenticado' using errcode = '28000'; end if;
  if not privado.cfg_bool('chat_ligado', true) then raise exception 'chat_desligado' using errcode = '42501'; end if;
  select * into c from public.chat_conversas where id = p_conversa;
  if not found or not public.chat_sou_membro(p_conversa) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if p_anexo is not null and (jsonb_typeof(p_anexo) <> 'object' or coalesce(p_anexo ->> 'tipo', '') not in ('foto', 'pedido', 'rota', 'cliente', 'pessoa', 'local')) then
    raise exception 'anexo_invalido' using errcode = '22023';
  end if;
  if p_anexo ->> 'tipo' = 'foto' and not privado.cfg_bool('chat_fotos', true) then raise exception 'fotos_desligadas' using errcode = '42501'; end if;
  if p_anexo is not null and p_anexo ->> 'tipo' <> 'foto' and not public.is_dev() and (
       not privado.cfg_bool('chat_compartilhar', true)
    or not coalesce(privado.cfg('chat_compartilhar_tipos', '["pedido","rota","cliente","pessoa","local"]'::jsonb) ? (p_anexo ->> 'tipo'), true)) then
    raise exception 'compartilhamento_desligado' using errcode = '42501';
  end if;
  if not public.chat_participo(p_conversa) and not exists (select 1 from public.chat_membros where conversa_id = p_conversa and usuario_id = auth.uid()) and public.is_dev() and not privado.cfg_bool('dev_escreve_em_conversas', false) then
    raise exception 'dev_so_le' using errcode = '42501';
  end if;
  if v_txt is null and p_anexo is null then raise exception 'mensagem_vazia' using errcode = '22023'; end if;
  insert into public.chat_mensagens (conversa_id, autor_id, texto, anexo) values (p_conversa, auth.uid(), v_txt, p_anexo) returning id into v_id;
  v_previa := left(coalesce(v_txt, case p_anexo ->> 'tipo' when 'foto' then '📷 Foto' when 'local' then '📍 Local' else coalesce(p_anexo ->> 'titulo', 'Anexo') end), 120);
  update public.chat_conversas set ultima_em = now(), ultima_previa = v_previa, ultima_autor = auth.uid() where id = p_conversa;
  insert into public.chat_membros (conversa_id, usuario_id) values (p_conversa, auth.uid())
    on conflict (conversa_id, usuario_id) do update set lida_em = now();
  v_nome := split_part(public.nome_publico(auth.uid()), ' ', 1);
  for v_m in
    select x.id from (
      select m.usuario_id id, m.silenciada from public.chat_membros m where m.conversa_id = p_conversa
      union
      select p.id, false from public.perfis p where c.tipo = 'geral' and p.papeis && array['motoboy', 'gestor', 'supervisor']::public.papel_usuario[]
         and p.organizacao_id is not distinct from c.organizacao_id
    ) x where x.id <> auth.uid() and not x.silenciada
       and not exists (select 1 from public.chat_membros s where s.conversa_id = p_conversa and s.usuario_id = x.id and s.silenciada)
    limit 300
  loop
    perform privado.enviar_push(v_m, jsonb_build_object('tipo', 'chat', 'conversa_id', p_conversa::text, 'mensagem_id', v_id::text,
      'titulo', case when c.tipo = 'direta' then v_nome else coalesce(c.nome, 'Chat') end,
      'texto', case when c.tipo = 'direta' then v_previa else v_nome || ': ' || v_previa end));
  end loop;
  return v_id;
end;
$$;

-- Dev: todas as conversas da plataforma (com empresa e membros) e apagar conversa/grupo
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
      from public.chat_conversas c where p_org is null or c.organizacao_id = p_org), '[]'::jsonb) end;
$$;
create or replace function public.dev_apagar_conversa(p_conversa uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  delete from public.chat_conversas where id = p_conversa;
end;
$$;

-- ===================================================================== conta do Dev: só ele mexe
create or replace function public.pode_gerenciar(p_alvo uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select case
    when exists (select 1 from public.perfis where id = p_alvo and 'dev' = any (papeis)) then p_alvo = auth.uid()
    when public.is_dev() then true
    when not public.is_gestor() or not public.ve_pessoa(p_alvo) then false
    when public.is_supervisor() then public.pode('cadastrar')
         and not exists (select 1 from public.perfis where id = p_alvo and papeis && array['gestor', 'supervisor']::public.papel_usuario[])
    else true end;
$$;
create or replace function privado.proteger_dev()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_alvo uuid;
begin
  if auth.uid() is null then return coalesce(new, old); end if;            -- sistema / editor SQL
  if tg_table_name = 'perfis' then v_alvo := old.id;
  elsif tg_table_name = 'politicas' then
    if coalesce(new.escopo, old.escopo) <> 'motoboy' then return coalesce(new, old); end if;
    v_alvo := nullif(coalesce(new.alvo, old.alvo), '')::uuid;
  end if;
  if v_alvo is not null and v_alvo <> auth.uid() and exists (select 1 from public.perfis where id = v_alvo and 'dev' = any (papeis)) then
    raise exception 'conta_do_dev_protegida' using errcode = '42501';
  end if;
  return coalesce(new, old);
end;
$$;
drop trigger if exists proteger_dev on public.perfis;
create trigger proteger_dev before update or delete on public.perfis for each row execute function privado.proteger_dev();
drop trigger if exists proteger_dev on public.politicas;
create trigger proteger_dev before insert or update or delete on public.politicas for each row execute function privado.proteger_dev();

create or replace function public.dev_ocultar(p_ocultar boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  update public.perfis set dev_oculto = coalesce(p_ocultar, false) where id = auth.uid();
end;
$$;
-- Dev escolhe qual empresa "olhar" nos painéis (null = todas)
create or replace function public.dev_focar_org(p_org uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  if p_org is not null and not exists (select 1 from public.organizacoes where id = p_org) then raise exception 'empresa_nao_encontrada' using errcode = '22023'; end if;
  update public.perfis set org_em_foco = p_org where id = auth.uid();
end;
$$;

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
  -- dar ou tirar Gestor/Supervisor: só o gestor da empresa (ou o Dev)
  if (('gestor' = any (p_papeis)) <> ('gestor' = any (coalesce(v_atual, '{}')) )
      or ('supervisor' = any (p_papeis)) <> ('supervisor' = any (coalesce(v_atual, '{}')))) and not public.is_gestor_pleno() then
    raise exception 'apenas_gestor' using errcode = '42501';
  end if;
  if p_usuario = auth.uid() and not ('gestor' = any (p_papeis) or 'dev' = any (p_papeis) or 'supervisor' = any (p_papeis)) then
    raise exception 'nao_remova_seu_proprio_acesso' using errcode = '22023';
  end if;
  if p_usuario = auth.uid() and 'dev' = any (coalesce(v_atual, '{}')) and not ('dev' = any (p_papeis)) then
    raise exception 'nao_remova_seu_proprio_acesso' using errcode = '22023';
  end if;
  if p_repasse is not null and (p_repasse < 0 or p_repasse > 100) then
    raise exception 'percentual_invalido' using errcode = '22023';
  end if;
  update public.perfis set nome = coalesce(nullif(trim(p_nome), ''), nome), papeis = p_papeis,
         organizacao_id = coalesce(organizacao_id, public.minha_org()),
         responsavel_id = coalesce(responsavel_id, case when p_usuario <> auth.uid() then auth.uid() end)
   where id = p_usuario;
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

-- Gestor escolhe o que cada supervisor pode fazer (e quem responde por quem)
create or replace function public.definir_permissoes(p_usuario uuid, p_permissoes jsonb, p_responsavel uuid default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_gestor_pleno() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if not public.pode_gerenciar(p_usuario) then raise exception 'conta_protegida' using errcode = '42501'; end if;
  update public.perfis set
    permissoes = coalesce((select jsonb_object_agg(k, v) from jsonb_each(coalesce(p_permissoes, '{}')) e(k, v)
                            where k ~ '^[a-z_]{2,40}$' and jsonb_typeof(v) = 'boolean'), '{}'),
    responsavel_id = coalesce(p_responsavel, responsavel_id)
   where id = p_usuario;
end;
$$;

-- ===================================================================== ajustes por empresa
alter table public.politicas drop constraint if exists politicas_escopo_check;
alter table public.politicas add constraint politicas_escopo_check check (escopo in ('tipo', 'cliente', 'motoboy', 'organizacao'));

-- Empresa do contexto: a da rotina (pwex.org), a do cliente, a do motoboy ou a de quem chamou.
create or replace function privado.org_contexto(p_cliente uuid default null, p_motoboy uuid default null)
returns uuid language sql stable security definer set search_path = '' as $$
  select coalesce(nullif(current_setting('pwex.org', true), '')::uuid,
                  (select organizacao_id from public.empresas where id = p_cliente),
                  public.minha_org(),
                  (select organizacao_id from public.perfis where id = p_motoboy));
$$;

create or replace function privado.cfg(p_chave text, p_padrao jsonb)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select valor from public.politicas where escopo = 'organizacao' and alvo = privado.org_contexto()::text and chave = p_chave
        and p_chave !~ '^(app_|dev_|saas_)'),
    (select valor from public.configuracoes where chave = p_chave), p_padrao);
$$;

create or replace function privado.pol(p_chave text, p_cliente uuid default null, p_motoboy uuid default null, p_tipo text default null)
returns jsonb language sql stable security definer set search_path = '' as $$
  with o as (select x.* from public.organizacoes x where x.id = privado.org_contexto(p_cliente, p_motoboy))
  select coalesce(
    -- a cobrança da plataforma vem do contrato da empresa (licença/isenta = 0%)
    case when p_chave = 'dev_pct' then (select case when o.cobranca_modelo <> 'percentual' then '0'::jsonb end from o) end,
    (nullif(current_setting('pwex.regras', true), '')::jsonb -> p_chave),
    (select valor from public.politicas where p_motoboy is not null and escopo = 'motoboy' and alvo = p_motoboy::text and chave = p_chave),
    (select valor from public.politicas where p_cliente is not null and escopo = 'cliente' and alvo = p_cliente::text and chave = p_chave),
    (select valor from public.politicas where p_tipo is not null and escopo = 'tipo' and alvo = p_tipo and chave = p_chave),
    case when p_chave = 'dev_pct' then (select to_jsonb(o.cobranca_pct) from o) end,
    (select valor from public.politicas where escopo = 'organizacao' and alvo = (select o.id::text from o) and chave = p_chave
        and p_chave !~ '^(app_|dev_|saas_)'),
    (select valor from public.configuracoes where chave = p_chave));
$$;

-- Ajustes valendo para a minha empresa (padrão da plataforma + o que a empresa mudou)
create or replace function public.ajustes()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce((select jsonb_object_agg(chave, valor) from public.configuracoes), '{}'::jsonb)
      || coalesce((select jsonb_object_agg(chave, valor) from public.politicas
                    where escopo = 'organizacao' and alvo = public.minha_org()::text and chave !~ '^(app_|dev_|saas_)'), '{}'::jsonb);
$$;
-- quais ajustes a empresa mudou (para o "voltar ao padrão")
create or replace function public.ajustes_mudados()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce((select jsonb_object_agg(chave, valor) from public.politicas
                    where escopo = 'organizacao' and alvo = public.minha_org()::text), '{}'::jsonb);
$$;
-- Gravar um ajuste: o Dev (sem empresa escolhida) muda o padrão da plataforma;
-- o gestor (ou supervisor com permissão) muda só o da empresa dele.
create or replace function public.salvar_ajuste(p_chave text, p_valor jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare v_org uuid := public.minha_org();
begin
  if not public.is_gestor() or not public.pode('ajustes') then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if p_chave is null or p_chave !~ '^[a-z0-9_]{2,60}$' then raise exception 'chave_invalida' using errcode = '22023'; end if;
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
  delete from public.politicas where escopo = 'organizacao' and alvo = public.minha_org()::text and chave = p_chave;
end;
$$;

insert into public.configuracoes (chave, valor) values
  ('saas_compartilhar_corridas', 'true'),
  ('pagamento_na_plataforma', 'false'),
  ('chat_compartilhar', 'true'),
  ('chat_compartilhar_tipos', '["pedido","rota","cliente","pessoa","local"]'),
  ('chat_grupos_equipe', 'false'),
  ('dev_escreve_em_conversas', 'false'),
  ('compartilhar_motoboy_resumo', 'true')
on conflict (chave) do nothing;

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
       and public.org_alcanca(c.organizacao_id, (select p.organizacao_id from public.perfis p where p.id = m.id), null)
     -- primeiro os da própria empresa; os de outras só se o Dev liberou (e, em "sem motoboy livre", só se faltar)
     order by ((select p.organizacao_id from public.perfis p where p.id = m.id) is distinct from c.organizacao_id), (f.ordem is null), f.ordem, (v_emc = 'depois' and m.status <> 'disponivel'), extensions.st_distance(m.posicao, v_coleta)
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
     and public.org_alcanca(c.organizacao_id, (select p.organizacao_id from public.perfis p where p.id = m.id), null)
   order by ((select p.organizacao_id from public.perfis p where p.id = m.id) is distinct from c.organizacao_id), (f.ordem is null), f.ordem, privado.dist_m(m.lat, m.lng, col.lat, col.lng)
   limit 1;
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
    'organizacao', (select jsonb_build_object('id', o.id, 'nome', o.nome, 'logo', o.logo_url, 'cor', o.cor, 'status', o.status)
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

-- ===================================================================== empresas (Dev)
create or replace function privado.org_json(o public.organizacoes)
returns jsonb language sql stable security definer set search_path = '' as $$
  select to_jsonb(o) || jsonb_build_object(
    'dono', (select jsonb_build_object('id', p.id, 'nome', p.nome, 'foto', p.foto_url) from public.perfis p where p.id = o.dono_id),
    'gestores', (select count(*) from public.perfis p where p.organizacao_id = o.id and p.papeis && array['gestor', 'supervisor']::public.papel_usuario[]),
    'motoboys', (select count(*) from public.perfis p where p.organizacao_id = o.id and 'motoboy' = any (p.papeis)),
    'online', (select count(*) from public.perfis p join public.motoboys m on m.id = p.id where p.organizacao_id = o.id and m.status <> 'offline'),
    'clientes', (select count(*) from public.empresas e where e.organizacao_id = o.id),
    'licenca', (select to_jsonb(l) from public.licencas l where l.organizacao_id = o.id and l.status = 'ativa' order by l.inicio desc limit 1));
$$;
create or replace function public.dev_organizacoes()
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when not public.is_dev() then '[]'::jsonb else
    coalesce((select jsonb_agg(privado.org_json(o) order by o.nome) from public.organizacoes o), '[]'::jsonb) end;
$$;
create or replace function public.dev_salvar_organizacao(p jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid := nullif(p ->> 'id', '')::uuid; v_antes public.organizacoes%rowtype;
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  if v_id is null then
    if coalesce(trim(p ->> 'nome'), '') = '' then raise exception 'nome_obrigatorio' using errcode = '22023'; end if;
    insert into public.organizacoes (nome) values (trim(p ->> 'nome')) returning id into v_id;
  end if;
  select * into v_antes from public.organizacoes where id = v_id;
  if not found then raise exception 'empresa_nao_encontrada' using errcode = '22023'; end if;
  update public.organizacoes set
    nome                  = coalesce(nullif(trim(p ->> 'nome'), ''), nome),
    slug                  = case when p ? 'slug' then nullif(lower(regexp_replace(p ->> 'slug', '[^a-zA-Z0-9-]+', '-', 'g')), '') else slug end,
    documento             = case when p ? 'documento' then nullif(regexp_replace(p ->> 'documento', '\D', '', 'g'), '') else documento end,
    logo_url              = case when p ? 'logo_url' then nullif(p ->> 'logo_url', '') else logo_url end,
    cor                   = case when p ? 'cor' then nullif(p ->> 'cor', '') else cor end,
    dono_id               = case when p ? 'dono_id' then nullif(p ->> 'dono_id', '')::uuid else dono_id end,
    status                = coalesce(p ->> 'status', status),
    cobranca_modelo       = coalesce(p ->> 'cobranca_modelo', cobranca_modelo),
    cobranca_pct          = coalesce((p ->> 'cobranca_pct')::numeric, cobranca_pct),
    mensalidade           = coalesce((p ->> 'mensalidade')::numeric, mensalidade),
    vencimento_dia        = coalesce((p ->> 'vencimento_dia')::int, vencimento_dia),
    limites               = coalesce(p -> 'limites', limites),
    compartilhar          = coalesce(p ->> 'compartilhar', compartilhar),
    compartilhar_apos_min = coalesce((p ->> 'compartilhar_apos_min')::int, compartilhar_apos_min),
    receber_de_outras     = coalesce((p ->> 'receber_de_outras')::boolean, receber_de_outras),
    parceiros             = case when p ? 'parceiros' then coalesce((select array_agg(x::uuid) from jsonb_array_elements_text(p -> 'parceiros') x where x <> v_id::text), '{}') else parceiros end,
    observacoes           = case when p ? 'observacoes' then nullif(p ->> 'observacoes', '') else observacoes end
   where id = v_id;
  -- o dono passa a ser gestor desta empresa
  if p ? 'dono_id' and nullif(p ->> 'dono_id', '') is not null then
    update public.perfis set organizacao_id = v_id,
           papeis = (select array_agg(distinct x) from unnest(papeis || array['gestor']::public.papel_usuario[]) x)
     where id = (p ->> 'dono_id')::uuid and not ('dev' = any (papeis));
  end if;
  -- mudou o modelo de cobrança: fecha a licença anterior e abre uma nova no histórico
  if v_antes.cobranca_modelo is distinct from (select cobranca_modelo from public.organizacoes where id = v_id)
     or v_antes.mensalidade is distinct from (select mensalidade from public.organizacoes where id = v_id)
     or v_antes.cobranca_pct is distinct from (select cobranca_pct from public.organizacoes where id = v_id)
     or not exists (select 1 from public.licencas where organizacao_id = v_id) then
    update public.licencas set status = 'encerrada', fim = current_date where organizacao_id = v_id and status = 'ativa';
    insert into public.licencas (organizacao_id, modelo, valor, pct, criado_por)
    select id, cobranca_modelo, mensalidade, cobranca_pct, auth.uid() from public.organizacoes where id = v_id;
  end if;
  perform privado.chat_geral_da_org(v_id);
  return v_id;
end;
$$;
create or replace function public.dev_licencas(p_org uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when not public.is_dev() then '[]'::jsonb else
    coalesce((select jsonb_agg(to_jsonb(l) order by l.inicio desc, l.criado_em desc) from public.licencas l where l.organizacao_id = p_org), '[]'::jsonb) end;
$$;
-- Mover uma pessoa para outra empresa (Dev)
create or replace function public.dev_mover_pessoa(p_usuario uuid, p_org uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  if exists (select 1 from public.perfis where id = p_usuario and 'dev' = any (papeis)) and p_usuario <> auth.uid() then
    raise exception 'conta_do_dev_protegida' using errcode = '42501';
  end if;
  update public.perfis set organizacao_id = p_org where id = p_usuario;
end;
$$;

-- A empresa do gestor: dados e licença (sem os números de outras)
create or replace function public.minha_organizacao()
returns jsonb language sql stable security definer set search_path = '' as $$
  select (select privado.org_json(o) - 'observacoes' - 'parceiros' from public.organizacoes o where o.id = public.minha_org());
$$;
create or replace function public.salvar_minha_organizacao(p jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_gestor_pleno() or public.minha_org() is null then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  update public.organizacoes set
    nome      = coalesce(nullif(trim(p ->> 'nome'), ''), nome),
    documento = case when p ? 'documento' then nullif(regexp_replace(p ->> 'documento', '\D', '', 'g'), '') else documento end,
    logo_url  = case when p ? 'logo_url' then nullif(p ->> 'logo_url', '') else logo_url end,
    cor       = case when p ? 'cor' then nullif(p ->> 'cor', '') else cor end
   where id = public.minha_org();
end;
$$;

-- ===================================================================== faturamento do Dev
-- Por empresa, no período: quanto faturou, quanto rodou, quantos clientes/motoboys ativos
-- e quanto rende para a plataforma (percentual das rotas concluídas, ou a licença do período).
create or replace function public.dev_faturamento(p_de date default null, p_ate date default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_de   date := coalesce(p_de, date_trunc('month', now() at time zone 'America/Sao_Paulo')::date);
  v_ate  date := coalesce(p_ate, (now() at time zone 'America/Sao_Paulo')::date);
  v_dias numeric;
  r      jsonb;
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  if v_ate < v_de then raise exception 'periodo_invalido' using errcode = '22023'; end if;
  v_dias := (v_ate - v_de) + 1;
  with base as (
    select c.*, (c.concluida_em at time zone 'America/Sao_Paulo')::date dia
      from public.corridas c
     where c.status = 'concluida' and not coalesce(c.teste, false)
       and (c.concluida_em at time zone 'America/Sao_Paulo')::date between v_de and v_ate
  ), por_org as (
    select o.id, o.nome, o.status, o.cobranca_modelo, o.cobranca_pct, o.mensalidade, o.logo_url, o.cor,
      count(b.id) rotas,
      coalesce(sum(b.valor), 0) faturamento,
      coalesce(sum(b.valor_motoboy), 0) repasse,
      coalesce(sum(b.valor_gestao), 0) gestao,
      coalesce(sum(b.valor_dev), 0) dev_percentual,
      coalesce(sum(coalesce(b.distancia_real_m, b.distancia_planejada_m, 0)), 0) / 1000.0 km,
      count(distinct b.empresa_id) clientes_ativos,
      count(distinct b.motoboy_id) motoboys_ativos,
      (select count(*) from public.paradas pa join base b2 on b2.id = pa.corrida_id where b2.organizacao_id = o.id and pa.tipo = 'entrega') entregas,
      (select count(*) from public.pedidos x where x.organizacao_id = o.id and not coalesce(x.teste, false)
          and (x.criado_em at time zone 'America/Sao_Paulo')::date between v_de and v_ate) pedidos,
      (select count(*) from public.empresas e where e.organizacao_id = o.id) clientes,
      (select count(*) from public.perfis p where p.organizacao_id = o.id and 'motoboy' = any (p.papeis)) motoboys,
      (select count(*) from public.perfis p where p.organizacao_id = o.id and p.papeis && array['gestor', 'supervisor']::public.papel_usuario[]) gestores
    from public.organizacoes o
    left join base b on b.organizacao_id = o.id
    group by o.id
  ), calc as (
    select x.*,
      round(case x.cobranca_modelo
        when 'percentual' then x.dev_percentual
        when 'licenca' then x.mensalidade * v_dias / 30.0
        else 0 end, 2) receita_dev,
      case when x.rotas > 0 then round(x.faturamento / x.rotas, 2) else 0 end ticket_medio
    from por_org x
  )
  select jsonb_build_object(
    'de', v_de, 'ate', v_ate, 'dias', v_dias,
    'totais', (select jsonb_build_object(
        'empresas', count(*), 'ativas', count(*) filter (where status = 'ativa'),
        'faturamento', coalesce(sum(faturamento), 0), 'receita_dev', coalesce(sum(receita_dev), 0),
        'rotas', coalesce(sum(rotas), 0), 'entregas', coalesce(sum(entregas), 0), 'km', round(coalesce(sum(km), 0), 1),
        'motoboys', coalesce(sum(motoboys), 0), 'clientes', coalesce(sum(clientes), 0)) from calc),
    'empresas', coalesce((select jsonb_agg(jsonb_build_object(
        'id', id, 'nome', nome, 'status', status, 'logo', logo_url, 'cor', cor,
        'modelo', cobranca_modelo, 'pct', cobranca_pct, 'mensalidade', mensalidade,
        'rotas', rotas, 'entregas', entregas, 'pedidos', pedidos, 'km', round(km, 1),
        'faturamento', faturamento, 'repasse', repasse, 'gestao', gestao, 'receita_dev', receita_dev, 'ticket_medio', ticket_medio,
        'clientes', clientes, 'clientes_ativos', clientes_ativos, 'motoboys', motoboys, 'motoboys_ativos', motoboys_ativos, 'gestores', gestores,
        'serie', (select coalesce(jsonb_agg(jsonb_build_object('dia', d.dia, 'faturamento', d.fat, 'rotas', d.n, 'dev', d.dev) order by d.dia), '[]'::jsonb)
                    from (select b.dia, sum(b.valor) fat, count(*) n, sum(b.valor_dev) dev from base b where b.organizacao_id = calc.id group by b.dia) d),
        'top_clientes', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
                    select e.nome, count(*) rotas, sum(b.valor) faturamento from base b join public.empresas e on e.id = b.empresa_id
                     where b.organizacao_id = calc.id group by e.nome order by sum(b.valor) desc nulls last limit 5) t)
      ) order by receita_dev desc, faturamento desc) from calc), '[]'::jsonb),
    'serie', (select coalesce(jsonb_agg(jsonb_build_object('dia', d.dia, 'faturamento', d.fat, 'rotas', d.n, 'dev', d.dev) order by d.dia), '[]'::jsonb)
                from (select b.dia, sum(b.valor) fat, count(*) n, sum(b.valor_dev) dev from base b group by b.dia) d)
  ) into r;
  return r;
end;
$$;

-- ===================================================================== permissões
grant select on public.organizacoes, public.licencas to authenticated;
revoke execute on function privado.org_padrao(), privado.perfil_org_padrao(), privado.proteger_dev(),
  privado.chat_geral_da_org(uuid, text), privado.org_contexto(uuid, uuid), privado.org_json(public.organizacoes) from public, anon, authenticated;
grant execute on function public.is_gestor_pleno(), public.is_supervisor(), public.pode(text), public.minha_org(), public.ve_org(uuid),
  public.ve_org_ou_global(uuid), public.org_alcanca(uuid, uuid, timestamptz), public.dev_oculto_para_mim(uuid), public.nome_publico(uuid),
  public.foto_publica(uuid), public.ve_pessoa(uuid), public.ve_corrida(uuid), public.ve_pedido(uuid), public.chat_participo(uuid),
  public.dev_conversas(uuid), public.dev_apagar_conversa(uuid), public.dev_ocultar(boolean), public.dev_focar_org(uuid),
  public.definir_permissoes(uuid, jsonb, uuid), public.ajustes(), public.ajustes_mudados(), public.salvar_ajuste(text, jsonb),
  public.voltar_ajuste(text), public.dev_organizacoes(), public.dev_salvar_organizacao(jsonb), public.dev_licencas(uuid),
  public.dev_mover_pessoa(uuid, uuid), public.minha_organizacao(), public.salvar_minha_organizacao(jsonb),
  public.dev_faturamento(date, date) to authenticated;

-- realtime: o painel acompanha mudanças nas empresas
do $$ begin
  alter publication supabase_realtime add table public.organizacoes;
exception when others then null; end $$;
