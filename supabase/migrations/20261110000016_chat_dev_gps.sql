-- =====================================================================
-- PW Express · Chat, apagar tudo (Dev) e ajustes de GPS/percurso/navegação
-- ---------------------------------------------------------------------
--  • Chat: conversa geral da equipe, mensagens diretas e grupos, com
--    fotos e cartões compartilhados (pedido, rota, cliente, pessoa, local).
--  • Dev: contar, listar e apagar qualquer registro: um a um, por
--    categoria ou tudo (com senha).
--  • GPS: pings mais próximos (tempo e distância), por motoboy; provedor
--    e perfil do mapa para o percurso; navegação curva a curva.
-- Rode depois de 20261110000015. Seguro rodar de novo.
-- =====================================================================

-- ------------------------------------------------------------- padrões
insert into public.configuracoes (chave, valor) values
  ('chat_ligado', 'true'), ('chat_geral', 'true'), ('chat_motoboy_direta', 'true'), ('chat_fotos', 'true'), ('chat_apagar_min', '30'),
  ('ping_distancia_m', '20'), ('ping_precisao_max_m', '60'), ('ping_envio_s', '12'),
  ('percurso_provedor', '"valhalla"'), ('percurso_perfil', '"motorcycle"'), ('percurso_raio_m', '30'), ('percurso_filtro_m', '12'),
  ('percurso_tira_voltas', 'true'), ('percurso_volta_max_m', '450'), ('percurso_vel_max_kmh', '160'),
  ('rota_provedor', '"valhalla"'), ('rota_perfil', '"motorcycle"'),
  ('navegacao_ligada', 'true'), ('navegacao_voz', 'true'), ('navegacao_recalcular_m', '60'), ('navegacao_na_notificacao', 'true')
on conflict (chave) do nothing;
-- pings mais próximos: quem ainda estava no padrão antigo (45 s / 90 s) passa para 6 s / 20 s
update public.configuracoes set valor = '6' where chave = 'intervalo_corrida_s' and (valor #>> '{}')::numeric >= 30;
update public.configuracoes set valor = '20' where chave = 'intervalo_economia_s' and (valor #>> '{}')::numeric >= 60;
insert into public.configuracoes (chave, valor) values ('intervalo_corrida_s', '6'), ('intervalo_economia_s', '20') on conflict (chave) do nothing;

-- =====================================================================
-- CHAT
-- =====================================================================
create table if not exists public.chat_conversas (
  id            uuid primary key default gen_random_uuid(),
  tipo          text not null check (tipo in ('geral', 'direta', 'grupo')),
  nome          text,
  criada_por    uuid references public.perfis (id) on delete set null,
  criada_em     timestamptz not null default now(),
  ultima_em     timestamptz not null default now(),
  ultima_previa text,
  ultima_autor  uuid
);
create unique index if not exists chat_uma_geral on public.chat_conversas (tipo) where tipo = 'geral';
create table if not exists public.chat_membros (
  conversa_id uuid not null references public.chat_conversas (id) on delete cascade,
  usuario_id  uuid not null references public.perfis (id) on delete cascade,
  lida_em     timestamptz not null default now(),
  silenciada  boolean not null default false,
  entrou_em   timestamptz not null default now(),
  primary key (conversa_id, usuario_id)
);
create index if not exists chat_membros_usuario_idx on public.chat_membros (usuario_id);
create table if not exists public.chat_mensagens (
  id          uuid primary key default gen_random_uuid(),
  conversa_id uuid not null references public.chat_conversas (id) on delete cascade,
  autor_id    uuid references public.perfis (id) on delete set null,
  texto       text,
  -- { tipo: foto|pedido|rota|cliente|pessoa|local, id?, titulo?, sub?, caminho?, lat?, lng? }
  anexo       jsonb,
  criada_em   timestamptz not null default now(),
  apagada_em  timestamptz
);
create index if not exists chat_mensagens_conversa_idx on public.chat_mensagens (conversa_id, criada_em desc);
insert into public.chat_conversas (tipo, nome) select 'geral', 'Equipe' where not exists (select 1 from public.chat_conversas where tipo = 'geral');

-- É da equipe (motoboy, gestor ou Dev)?
create or replace function public.chat_equipe()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.perfis p where p.id = auth.uid() and p.papeis && array['motoboy', 'gestor', 'dev']::public.papel_usuario[]);
$$;
-- Posso ver esta conversa?
create or replace function public.chat_sou_membro(p_conversa uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.chat_membros m where m.conversa_id = p_conversa and m.usuario_id = auth.uid())
      or (public.chat_equipe() and privado.cfg_bool('chat_geral', true) and exists (select 1 from public.chat_conversas c where c.id = p_conversa and c.tipo = 'geral'));
$$;

alter table public.chat_conversas enable row level security;
alter table public.chat_membros enable row level security;
alter table public.chat_mensagens enable row level security;
drop policy if exists chat_conversas_leitura on public.chat_conversas;
create policy chat_conversas_leitura on public.chat_conversas for select to authenticated using ((select public.chat_sou_membro(id)));
drop policy if exists chat_membros_leitura on public.chat_membros;
create policy chat_membros_leitura on public.chat_membros for select to authenticated using ((select public.chat_sou_membro(conversa_id)));
drop policy if exists chat_mensagens_leitura on public.chat_mensagens;
create policy chat_mensagens_leitura on public.chat_mensagens for select to authenticated using ((select public.chat_sou_membro(conversa_id)));
revoke all on public.chat_conversas, public.chat_membros, public.chat_mensagens from anon;
grant select on public.chat_conversas, public.chat_membros, public.chat_mensagens to authenticated;
do $$ begin
  alter publication supabase_realtime add table public.chat_mensagens;
exception when others then null; end $$;

-- Com quem posso falar: equipe fala com a equipe (motoboy↔motoboy se a regra deixar) e com clientes (só gestor); cliente fala com os gestores.
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
    select jsonb_agg(jsonb_build_object('id', p.id, 'nome', p.nome, 'foto', p.foto_url, 'papeis', to_jsonb(p.papeis),
             'status', (select m.status from public.motoboys m where m.id = p.id),
             'empresa', (select e.nome from public.empresas e where e.id = p.empresa_id)) order by p.nome)
      from public.perfis p
     where p.id <> v_eu.id
       and not exists (select 1 from auth.users u where u.id = p.id and u.banned_until > now())
       and (case
              when v_gestor then true
              when public.chat_equipe() then (p.papeis && array['gestor', 'dev']::public.papel_usuario[])
                                             or ('motoboy' = any (p.papeis) and privado.cfg_bool('chat_motoboy_direta', true))
              else p.papeis && array['gestor']::public.papel_usuario[] end)), '[]'::jsonb);
end;
$$;

-- Abre (ou cria) a conversa direta com alguém
create or replace function public.chat_abrir_direta(p_usuario uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if auth.uid() is null or p_usuario = auth.uid() then raise exception 'conversa_invalida' using errcode = '22023'; end if;
  if not exists (select 1 from jsonb_array_elements(public.chat_contatos()) x where (x ->> 'id')::uuid = p_usuario) then
    raise exception 'sem_permissao' using errcode = '42501';
  end if;
  select c.id into v_id from public.chat_conversas c
   where c.tipo = 'direta'
     and exists (select 1 from public.chat_membros m where m.conversa_id = c.id and m.usuario_id = auth.uid())
     and exists (select 1 from public.chat_membros m where m.conversa_id = c.id and m.usuario_id = p_usuario)
   limit 1;
  if v_id is null then
    insert into public.chat_conversas (tipo, criada_por) values ('direta', auth.uid()) returning id into v_id;
    insert into public.chat_membros (conversa_id, usuario_id) values (v_id, auth.uid()), (v_id, p_usuario);
  end if;
  return v_id;
end;
$$;

-- Grupo (só gestor cria)
create or replace function public.chat_criar_grupo(p_nome text, p_membros uuid[])
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if coalesce(trim(p_nome), '') = '' then raise exception 'nome_obrigatorio' using errcode = '22023'; end if;
  insert into public.chat_conversas (tipo, nome, criada_por) values ('grupo', left(trim(p_nome), 60), auth.uid()) returning id into v_id;
  insert into public.chat_membros (conversa_id, usuario_id)
  select v_id, u from (select distinct unnest(p_membros || auth.uid()) u) x where exists (select 1 from public.perfis p where p.id = x.u);
  return v_id;
end;
$$;

-- Envia mensagem (texto e/ou anexo) e avisa os outros
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
  if v_txt is null and p_anexo is null then raise exception 'mensagem_vazia' using errcode = '22023'; end if;
  insert into public.chat_mensagens (conversa_id, autor_id, texto, anexo) values (p_conversa, auth.uid(), v_txt, p_anexo) returning id into v_id;
  v_previa := left(coalesce(v_txt, case p_anexo ->> 'tipo' when 'foto' then '📷 Foto' when 'local' then '📍 Local' else coalesce(p_anexo ->> 'titulo', 'Anexo') end), 120);
  update public.chat_conversas set ultima_em = now(), ultima_previa = v_previa, ultima_autor = auth.uid() where id = p_conversa;
  insert into public.chat_membros (conversa_id, usuario_id) values (p_conversa, auth.uid())
    on conflict (conversa_id, usuario_id) do update set lida_em = now();
  select split_part(nome, ' ', 1) into v_nome from public.perfis where id = auth.uid();
  for v_m in
    select x.id from (
      select m.usuario_id id, m.silenciada from public.chat_membros m where m.conversa_id = p_conversa
      union
      select p.id, false from public.perfis p where c.tipo = 'geral' and p.papeis && array['motoboy', 'gestor', 'dev']::public.papel_usuario[]
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

create or replace function public.chat_marcar_lida(p_conversa uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.chat_sou_membro(p_conversa) then return; end if;
  insert into public.chat_membros (conversa_id, usuario_id) values (p_conversa, auth.uid())
    on conflict (conversa_id, usuario_id) do update set lida_em = now();
end;
$$;

create or replace function public.chat_silenciar(p_conversa uuid, p_silenciar boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.chat_sou_membro(p_conversa) then return; end if;
  insert into public.chat_membros (conversa_id, usuario_id, silenciada) values (p_conversa, auth.uid(), p_silenciar)
    on conflict (conversa_id, usuario_id) do update set silenciada = excluded.silenciada;
end;
$$;

-- O autor apaga (dentro do prazo); gestor apaga qualquer uma
create or replace function public.chat_apagar_mensagem(p_mensagem uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare m public.chat_mensagens%rowtype;
begin
  select * into m from public.chat_mensagens where id = p_mensagem;
  if not found or not public.chat_sou_membro(m.conversa_id) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if not public.is_gestor() and (m.autor_id is distinct from auth.uid()
       or m.criada_em < now() - make_interval(mins => privado.cfg_num('chat_apagar_min', 30)::int)) then
    raise exception 'sem_permissao' using errcode = '42501';
  end if;
  update public.chat_mensagens set apagada_em = now(), texto = null, anexo = null where id = p_mensagem;
end;
$$;

-- Minhas conversas, com o outro lado (nas diretas), a última mensagem e as não lidas
create or replace function public.chat_conversas()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(x order by (x ->> 'ultima_em') desc), '[]'::jsonb) from (
    select jsonb_build_object(
      'id', c.id, 'tipo', c.tipo, 'ultima_em', c.ultima_em, 'ultima_previa', c.ultima_previa, 'ultima_minha', c.ultima_autor = auth.uid(),
      'silenciada', coalesce(eu.silenciada, false),
      'nome', case when c.tipo = 'direta' then (select p.nome from public.chat_membros m join public.perfis p on p.id = m.usuario_id
                                                 where m.conversa_id = c.id and m.usuario_id <> auth.uid() limit 1) else c.nome end,
      'foto', case when c.tipo = 'direta' then (select p.foto_url from public.chat_membros m join public.perfis p on p.id = m.usuario_id
                                                 where m.conversa_id = c.id and m.usuario_id <> auth.uid() limit 1) end,
      'outro', case when c.tipo = 'direta' then (select m.usuario_id from public.chat_membros m where m.conversa_id = c.id and m.usuario_id <> auth.uid() limit 1) end,
      'membros', (select count(*) from public.chat_membros m where m.conversa_id = c.id),
      'nao_lidas', (select count(*) from public.chat_mensagens g where g.conversa_id = c.id and g.autor_id is distinct from auth.uid() and g.apagada_em is null
                     and g.criada_em > coalesce(eu.lida_em, case when c.tipo = 'geral' then now() - interval '1 day' else '-infinity' end))
    ) x
      from public.chat_conversas c
      left join public.chat_membros eu on eu.conversa_id = c.id and eu.usuario_id = auth.uid()
     where privado.cfg_bool('chat_ligado', true) and public.chat_sou_membro(c.id)
  ) t;
$$;

-- fotos do chat (Storage): pasta = id da conversa
insert into storage.buckets (id, name, public) values ('chat', 'chat', false) on conflict (id) do nothing;
drop policy if exists chat_envio on storage.objects;
create policy chat_envio on storage.objects for insert to authenticated
  with check (bucket_id = 'chat' and (select public.chat_sou_membro(((storage.foldername(name))[1])::uuid)));
drop policy if exists chat_leitura on storage.objects;
create policy chat_leitura on storage.objects for select to authenticated
  using (bucket_id = 'chat' and (select public.chat_sou_membro(((storage.foldername(name))[1])::uuid)));

do $$
declare f text;
begin
  foreach f in array array['chat_equipe()', 'chat_sou_membro(uuid)', 'chat_contatos()', 'chat_abrir_direta(uuid)', 'chat_criar_grupo(text, uuid[])',
                           'chat_enviar(uuid, text, jsonb)', 'chat_marcar_lida(uuid)', 'chat_silenciar(uuid, boolean)', 'chat_apagar_mensagem(uuid)', 'chat_conversas()'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- push para qualquer pessoa da equipe (gestor sem cadastro de motoboy também recebe o chat)
alter table privado.fcm_tokens drop constraint if exists fcm_tokens_motoboy_id_fkey;

-- =====================================================================
-- DEV: apagar qualquer coisa
-- =====================================================================
-- Categorias: o que cada uma apaga e de que tabela vem a lista
create or replace function privado.dev_categorias()
returns jsonb language sql immutable set search_path = '' as $$
  select jsonb_build_array(
    jsonb_build_object('chave', 'pedidos', 'nome', 'Pedidos', 'descricao', 'Pedidos com pontos, itens e histórico. As rotas ficam sem as paradas deles.'),
    jsonb_build_object('chave', 'corridas', 'nome', 'Rotas e corridas', 'descricao', 'Rotas, paradas, ofertas, eventos e os pings ligados a elas.'),
    jsonb_build_object('chave', 'percursos', 'nome', 'Percursos (pings)', 'descricao', 'Todas as posições guardadas e o traçado pelas ruas.'),
    jsonb_build_object('chave', 'ofertas', 'nome', 'Ofertas', 'descricao', 'Ofertas enviadas aos motoboys (aceitas, recusadas, expiradas).'),
    jsonb_build_object('chave', 'faturas', 'nome', 'Faturas', 'descricao', 'Faturas dos clientes (os pedidos voltam a ficar sem fatura).'),
    jsonb_build_object('chave', 'holerites', 'nome', 'Folha', 'descricao', 'Holerites e ajustes da folha.'),
    jsonb_build_object('chave', 'chat', 'nome', 'Chat', 'descricao', 'Mensagens e conversas (a conversa geral é recriada vazia).'),
    jsonb_build_object('chave', 'modelos', 'nome', 'Modelos e objetos', 'descricao', 'Modelos de pedido e objetos salvos pelos clientes.'),
    jsonb_build_object('chave', 'clientes', 'nome', 'Clientes', 'descricao', 'Empresas e pessoas cadastradas, com pedidos, faturas e contas de acesso desvinculadas.'),
    jsonb_build_object('chave', 'cadastros', 'nome', 'Cadastros pendentes', 'descricao', 'Pedidos de cadastro feitos pelo site.'),
    jsonb_build_object('chave', 'excecoes', 'nome', 'Exceções (regras por alvo)', 'descricao', 'Regras por tipo, cliente e motoboy. As gerais ficam.'),
    jsonb_build_object('chave', 'zonas', 'nome', 'Zonas de preço', 'descricao', 'Raios com dinâmica de preço.'),
    jsonb_build_object('chave', 'horarios', 'nome', 'Horários de pico', 'descricao', 'Faixas de horário com acréscimo.'),
    jsonb_build_object('chave', 'registros', 'nome', 'Registros de exclusão', 'descricao', 'Cópias guardadas de corridas e contas apagadas.'),
    jsonb_build_object('chave', 'conquistas', 'nome', 'Conquistas manuais', 'descricao', 'Medalhas liberadas ou bloqueadas à mão.'),
    jsonb_build_object('chave', 'pix', 'nome', 'Chaves PIX', 'descricao', 'Chaves PIX cadastradas pela equipe.'),
    jsonb_build_object('chave', 'configuracoes', 'nome', 'Configurações', 'descricao', 'Volta todos os ajustes gerais para o padrão.'));
$$;

create or replace function public.dev_contagem()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  return (select jsonb_agg(k || jsonb_build_object('total', case k ->> 'chave'
      when 'pedidos' then (select count(*) from public.pedidos)
      when 'corridas' then (select count(*) from public.corridas)
      when 'percursos' then (select count(*) from public.localizacoes)
      when 'ofertas' then (select count(*) from public.ofertas)
      when 'faturas' then (select count(*) from public.faturas)
      when 'holerites' then (select count(*) from public.holerites) + (select count(*) from public.holerite_ajustes)
      when 'chat' then (select count(*) from public.chat_mensagens)
      when 'modelos' then (select count(*) from public.pedido_modelos) + (select count(*) from public.cliente_objetos)
      when 'clientes' then (select count(*) from public.empresas)
      when 'cadastros' then (select count(*) from public.cadastros_cliente)
      when 'excecoes' then (select count(*) from public.politicas)
      when 'zonas' then (select count(*) from public.zonas)
      when 'horarios' then (select count(*) from public.faixas_horario)
      when 'registros' then (select count(*) from public.registro_exclusoes) + (select count(*) from public.registro_contas_excluidas)
      when 'conquistas' then (select count(*) from public.conquistas_manuais)
      when 'pix' then (select count(*) from public.chaves_pix)
      when 'configuracoes' then (select count(*) from public.configuracoes)
      else 0 end)) from jsonb_array_elements(privado.dev_categorias()) k);
end;
$$;

-- Lista os registros de uma categoria (para apagar um a um)
create or replace function public.dev_listar(p_categoria text, p_busca text default null, p_limite int default 100)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_b text := '%' || lower(coalesce(trim(p_busca), '')) || '%'; v_l int := least(greatest(coalesce(p_limite, 100), 1), 500);
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  return coalesce(case p_categoria
    when 'pedidos' then (select jsonb_agg(x) from (select jsonb_build_object('id', p.id, 'titulo', (case when p.teste then 'T' else '#' end) || p.numero || ' · ' || coalesce(e.nome, p.cliente_nome, 'avulso'),
        'sub', p.status || ' · R$ ' || coalesce(p.valor, 0), 'quando', p.criado_em) x from public.pedidos p left join public.empresas e on e.id = p.empresa_id
        where lower(p.numero::text || ' ' || coalesce(e.nome, p.cliente_nome, '') || ' ' || p.status) like v_b order by p.criado_em desc limit v_l) t)
    when 'corridas' then (select jsonb_agg(x) from (select jsonb_build_object('id', c.id, 'titulo', (case when c.teste then 'T' else '#' end) || c.numero || ' · ' || coalesce(pf.nome, 'sem motoboy'),
        'sub', c.status::text || ' · R$ ' || coalesce(c.valor, 0), 'quando', c.criada_em) x from public.corridas c left join public.perfis pf on pf.id = c.motoboy_id
        where lower(c.numero::text || ' ' || coalesce(pf.nome, '') || ' ' || c.status::text) like v_b order by c.criada_em desc limit v_l) t)
    when 'percursos' then (select jsonb_agg(x) from (select jsonb_build_object('id', pf.id, 'titulo', pf.nome, 'sub', count(*) || ' pings', 'quando', max(l.registrado_em)) x
        from public.localizacoes l join public.perfis pf on pf.id = l.motoboy_id where lower(pf.nome) like v_b group by pf.id order by max(l.registrado_em) desc limit v_l) t)
    when 'ofertas' then (select jsonb_agg(x) from (select jsonb_build_object('id', o.id, 'titulo', coalesce(pf.nome, 'motoboy') || ' · rota ' || c.numero, 'sub', o.status::text, 'quando', o.criada_em) x
        from public.ofertas o join public.corridas c on c.id = o.corrida_id left join public.perfis pf on pf.id = o.motoboy_id
        where lower(coalesce(pf.nome, '') || ' ' || c.numero || ' ' || o.status::text) like v_b order by o.criada_em desc limit v_l) t)
    when 'faturas' then (select jsonb_agg(x) from (select jsonb_build_object('id', f.id, 'titulo', 'Fatura ' || f.numero || ' · ' || coalesce(e.nome, ''), 'sub', f.status || ' · R$ ' || coalesce(f.total, 0), 'quando', f.fim) x
        from public.faturas f left join public.empresas e on e.id = f.empresa_id where lower(f.numero::text || ' ' || coalesce(e.nome, '') || ' ' || f.status) like v_b order by f.fim desc limit v_l) t)
    when 'holerites' then (select jsonb_agg(x) from (select jsonb_build_object('id', h.id, 'titulo', coalesce(pf.nome, 'motoboy'), 'sub', h.status || ' · ' || h.inicio || ' a ' || h.fim, 'quando', h.fim) x
        from public.holerites h left join public.perfis pf on pf.id = h.motoboy_id where lower(coalesce(pf.nome, '') || ' ' || h.status) like v_b order by h.fim desc limit v_l) t)
    when 'chat' then (select jsonb_agg(x) from (select jsonb_build_object('id', c.id, 'titulo', coalesce(c.nome, (select string_agg(split_part(p.nome, ' ', 1), ' e ') from public.chat_membros m join public.perfis p on p.id = m.usuario_id where m.conversa_id = c.id), 'Conversa'),
        'sub', c.tipo || ' · ' || (select count(*) from public.chat_mensagens g where g.conversa_id = c.id) || ' mensagens', 'quando', c.ultima_em) x
        from public.chat_conversas c order by c.ultima_em desc limit v_l) t)
    when 'modelos' then (select jsonb_agg(x) from (
        select jsonb_build_object('id', m.id, 'titulo', 'Modelo: ' || m.nome, 'sub', e.nome, 'quando', m.criado_em) x from public.pedido_modelos m join public.empresas e on e.id = m.empresa_id where lower(m.nome || ' ' || e.nome) like v_b
        union all select jsonb_build_object('id', o.id, 'titulo', 'Objeto: ' || o.nome, 'sub', e.nome, 'quando', o.criado_em) from public.cliente_objetos o join public.empresas e on e.id = o.empresa_id where lower(o.nome || ' ' || e.nome) like v_b
        limit v_l) t)
    when 'clientes' then (select jsonb_agg(x) from (select jsonb_build_object('id', e.id, 'titulo', e.nome, 'sub', coalesce(e.cnpj, e.cpf, '') || ' · ' || (select count(*) from public.pedidos p where p.empresa_id = e.id) || ' pedidos', 'quando', e.criado_em) x
        from public.empresas e where lower(e.nome || ' ' || coalesce(e.cnpj, e.cpf, '')) like v_b order by e.nome limit v_l) t)
    when 'cadastros' then (select jsonb_agg(x) from (select jsonb_build_object('id', k.id, 'titulo', k.nome, 'sub', k.status, 'quando', k.criado_em) x from public.cadastros_cliente k where lower(k.nome) like v_b order by k.criado_em desc limit v_l) t)
    when 'excecoes' then (select jsonb_agg(x) from (select jsonb_build_object('id', md5(o.escopo || o.alvo || o.chave), 'titulo', o.chave, 'sub', o.escopo || ' · ' || coalesce(
          (select e.nome from public.empresas e where o.escopo = 'cliente' and e.id::text = o.alvo), (select p.nome from public.perfis p where o.escopo = 'motoboy' and p.id::text = o.alvo), o.alvo) || ' = ' || (o.valor #>> '{}'), 'quando', o.atualizado_em) x
        from public.politicas o where lower(o.chave || ' ' || o.escopo) like v_b order by o.atualizado_em desc limit v_l) t)
    when 'zonas' then (select jsonb_agg(x) from (select jsonb_build_object('id', z.id, 'titulo', z.nome, 'sub', z.raio_m || ' m') x from public.zonas z where lower(z.nome) like v_b limit v_l) t)
    when 'horarios' then (select jsonb_agg(x) from (select jsonb_build_object('id', f.id, 'titulo', f.nome, 'sub', f.inicio || '–' || f.fim) x from public.faixas_horario f where lower(f.nome) like v_b limit v_l) t)
    when 'registros' then (select jsonb_agg(x) from (select jsonb_build_object('id', r.id, 'titulo', 'Corrida ' || coalesce(r.numero::text, ''), 'sub', coalesce(r.motivo, ''), 'quando', r.excluida_em) x from public.registro_exclusoes r order by r.excluida_em desc limit v_l) t)
    when 'conquistas' then (select jsonb_agg(x) from (select jsonb_build_object('id', md5(k.perfil_id::text || k.chave), 'titulo', k.chave, 'sub', coalesce(pf.nome, '')) x from public.conquistas_manuais k left join public.perfis pf on pf.id = k.perfil_id limit v_l) t)
    when 'pix' then (select jsonb_agg(x) from (select jsonb_build_object('id', k.id, 'titulo', coalesce(pf.nome, ''), 'sub', k.tipo_chave || ' · ' || k.chave, 'quando', k.criado_em) x from public.chaves_pix k left join public.perfis pf on pf.id = k.usuario_id where lower(coalesce(pf.nome, '') || k.chave) like v_b limit v_l) t)
    when 'configuracoes' then (select jsonb_agg(x) from (select jsonb_build_object('id', md5(c.chave), 'titulo', c.chave, 'sub', c.valor #>> '{}') x from public.configuracoes c where lower(c.chave) like v_b order by c.chave limit v_l) t)
  end, '[]'::jsonb);
end;
$$;

-- Apaga: p_ids nulo = a categoria inteira; p_categoria = 'tudo' = todas as categorias de operação
-- ('tudo' não mexe em clientes, configurações, exceções, zonas e horários; 'tudo_mesmo' apaga também).
create or replace function public.dev_apagar(p_senha text, p_categoria text, p_ids text[] default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_erro jsonb;
  v_n    bigint := 0;
  v_k    bigint;
  v_cat  text;
  v_tudo boolean := p_ids is null;
  v_u    uuid[];
  v_arq  text[] := '{}';
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  v_erro := privado.senha_com_limite(p_senha);
  if v_erro is not null then return v_erro; end if;
  if p_categoria in ('tudo', 'tudo_mesmo') then
    foreach v_cat in array (case when p_categoria = 'tudo'
        then array['chat', 'ofertas', 'faturas', 'holerites', 'corridas', 'pedidos', 'percursos', 'registros']
        else array['chat', 'ofertas', 'faturas', 'holerites', 'corridas', 'pedidos', 'percursos', 'registros', 'modelos', 'cadastros', 'clientes', 'excecoes', 'zonas', 'horarios', 'conquistas', 'pix', 'configuracoes'] end) loop
      v_n := v_n + coalesce((public.dev_apagar_interno(v_cat, null) ->> 'apagados')::bigint, 0);
    end loop;
    return jsonb_build_object('apagados', v_n);
  end if;
  return public.dev_apagar_interno(p_categoria, p_ids);
end;
$$;

create or replace function public.dev_apagar_interno(p_categoria text, p_ids text[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_n    bigint := 0;
  v_k    bigint;
  v_tudo boolean := p_ids is null;
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  if p_categoria = 'pedidos' then
    delete from public.paradas where pedido_id in (select id from public.pedidos where v_tudo or id::text = any (p_ids));
    delete from public.pedidos where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count;
    -- rotas que ficaram vazias
    delete from public.corridas c where c.origem = 'roteirizador' and not exists (select 1 from public.paradas x where x.corrida_id = c.id);
  elsif p_categoria = 'corridas' then
    delete from public.localizacoes where corrida_id in (select id from public.corridas where v_tudo or id::text = any (p_ids));
    update public.motoboys set status = 'disponivel', status_em = now()
     where status = 'em_corrida' and id in (select motoboy_id from public.corridas where (v_tudo or id::text = any (p_ids)) and status::text in ('aceita', 'em_andamento'));
    delete from public.corridas where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count;
    update public.pedidos p set status = 'aprovado' where p.status in ('roteirizado', 'em_rota') and not exists (select 1 from public.paradas x where x.pedido_id = p.id);
    update public.pedido_pontos pp set status = 'pendente' where pp.status = 'em_rota' and not exists (select 1 from public.paradas x where x.pedido_ponto_id = pp.id);
  elsif p_categoria = 'percursos' then
    delete from public.localizacoes where v_tudo or motoboy_id::text = any (p_ids); get diagnostics v_n = row_count;
    delete from public.trechos_ajustados where v_tudo or motoboy_id::text = any (p_ids);
  elsif p_categoria = 'ofertas' then
    delete from public.ofertas where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count;
  elsif p_categoria = 'faturas' then
    update public.pedidos set fatura_id = null where fatura_id in (select id from public.faturas where v_tudo or id::text = any (p_ids));
    delete from public.faturas where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count;
  elsif p_categoria = 'holerites' then
    delete from public.holerite_ajustes where v_tudo or holerite_id::text = any (p_ids); get diagnostics v_k = row_count;
    delete from public.holerites where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count; v_n := v_n + v_k;
  elsif p_categoria = 'chat' then
    select count(*) into v_n from public.chat_mensagens where v_tudo or conversa_id::text = any (p_ids);
    delete from public.chat_conversas where v_tudo or id::text = any (p_ids);
    insert into public.chat_conversas (tipo, nome) select 'geral', 'Equipe' where not exists (select 1 from public.chat_conversas where tipo = 'geral');
  elsif p_categoria = 'modelos' then
    delete from public.pedido_modelos where v_tudo or id::text = any (p_ids); get diagnostics v_k = row_count;
    delete from public.cliente_objetos where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count; v_n := v_n + v_k;
  elsif p_categoria = 'clientes' then
    delete from public.paradas where pedido_id in (select id from public.pedidos where empresa_id in (select id from public.empresas where v_tudo or id::text = any (p_ids)));
    delete from public.pedidos where empresa_id in (select id from public.empresas where v_tudo or id::text = any (p_ids));
    delete from public.faturas where empresa_id in (select id from public.empresas where v_tudo or id::text = any (p_ids));
    update public.corridas set empresa_id = null where empresa_id in (select id from public.empresas where v_tudo or id::text = any (p_ids));
    update public.perfis set empresa_id = null where empresa_id in (select id from public.empresas where v_tudo or id::text = any (p_ids));
    delete from public.politicas where escopo = 'cliente' and (v_tudo or alvo = any (p_ids));
    delete from public.empresas where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count;
  elsif p_categoria = 'cadastros' then
    delete from public.cadastros_cliente where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count;
  elsif p_categoria = 'excecoes' then
    delete from public.politicas where v_tudo or md5(escopo || alvo || chave) = any (p_ids); get diagnostics v_n = row_count;
  elsif p_categoria = 'zonas' then
    delete from public.zonas where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count;
  elsif p_categoria = 'horarios' then
    delete from public.faixas_horario where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count;
  elsif p_categoria = 'registros' then
    delete from public.registro_exclusoes where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count;
    if v_tudo then delete from public.registro_contas_excluidas; end if;
  elsif p_categoria = 'conquistas' then
    delete from public.conquistas_manuais where v_tudo or md5(perfil_id::text || chave) = any (p_ids); get diagnostics v_n = row_count;
  elsif p_categoria = 'pix' then
    delete from public.chaves_pix where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count;
  elsif p_categoria = 'configuracoes' then
    -- apagar = voltar ao padrão (cada regra tem o padrão dela no sistema)
    delete from public.configuracoes where (v_tudo or md5(chave) = any (p_ids)) and chave not in ('versao_minima_app', 'versao_obrigatoria');
    get diagnostics v_n = row_count;
  else
    raise exception 'categoria_invalida' using errcode = '22023';
  end if;
  return jsonb_build_object('apagados', v_n);
end;
$$;
revoke all on function public.dev_contagem() from public, anon;
revoke all on function public.dev_listar(text, text, int) from public, anon;
revoke all on function public.dev_apagar(text, text, text[]) from public, anon;
revoke all on function public.dev_apagar_interno(text, text[]) from public, anon, authenticated;
grant execute on function public.dev_contagem() to authenticated;
grant execute on function public.dev_listar(text, text, int) to authenticated;
grant execute on function public.dev_apagar(text, text, text[]) to authenticated;
revoke all on function privado.dev_categorias() from public, anon, authenticated;

-- ------------------------------------------------------------- módulos novos (o Dev liga/desliga e escolhe quem usa)
insert into public.modulos (chave, nome, descricao, grupo, ordem) values
  ('chat', 'Chat', 'Conversa geral, mensagens diretas e grupos, com fotos e cartões compartilhados.', 'Comunicação', 100),
  ('navegacao', 'Navegação curva a curva', 'Instruções "vire à direita na…" na tela da corrida, na notificação e por voz.', 'Mapa', 110),
  ('extensao_rota', 'Extensão de rota', 'Oferecer rota nova a quem já está em corrida perto da coleta (e o gestor estender na mão).', 'Corridas', 120),
  ('orcamento_editavel', 'Orçamento editável', 'Gestor muda cada linha do "como chegou no valor".', 'Corridas', 130),
  ('objetos_cliente', 'Objetos salvos', 'Clientes guardam os produtos que mandam sempre.', 'Clientes', 140)
on conflict (chave) do nothing;

-- painel do Dev com mais números
create or replace function public.painel_dev()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_tarefas jsonb := '[]';
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  begin
    execute 'select coalesce(jsonb_agg(jsonb_build_object(''nome'', jobname, ''quando'', schedule, ''ativa'', active)), ''[]'') from cron.job' into v_tarefas;
  exception when others then v_tarefas := '[]';
  end;
  return jsonb_build_object(
    'contagens', jsonb_build_object(
      'contas', (select count(*) from public.perfis),
      'motoboys', (select count(*) from public.perfis where 'motoboy' = any (papeis)),
      'gestores', (select count(*) from public.perfis where 'gestor' = any (papeis)),
      'clientes', (select count(*) from public.empresas),
      'motoboys_online', (select count(*) from public.motoboys where status <> 'offline'),
      'em_corrida', (select count(*) from public.motoboys where status = 'em_corrida'),
      'pedidos', (select count(*) from public.pedidos),
      'pedidos_abertos', (select count(*) from public.pedidos where status in ('recebido', 'aprovado', 'roteirizado', 'em_rota')),
      'corridas_reais', (select count(*) from public.corridas where not teste),
      'corridas_teste', (select count(*) from public.corridas where teste),
      'corridas_ativas', (select count(*) from public.corridas where status::text in ('aguardando_motoboy', 'aceita', 'em_andamento')),
      'no_quadro', (select count(*) from public.corridas where modo_despacho::text = 'quadro' and motoboy_id is null and status::text in ('aguardando_motoboy', 'agendada')),
      'ofertas_pendentes', (select count(*) from public.ofertas where status = 'pendente'),
      'pings_24h', (select count(*) from public.localizacoes where registrado_em > now() - interval '24 hours'),
      'pings_total', (select count(*) from public.localizacoes),
      'trechos_ruas', (select count(*) from public.trechos_ajustados),
      'faturas', (select count(*) from public.faturas),
      'holerites', (select count(*) from public.holerites),
      'mensagens_chat', (select count(*) from public.chat_mensagens),
      'excecoes', (select count(*) from public.politicas),
      'configuracoes_mudadas', (select count(*) from public.configuracoes),
      'faturado_30d', (select coalesce(sum(valor), 0) from public.corridas where not teste and status::text = 'concluida' and concluida_em > now() - interval '30 days'),
      'motoboys_30d', (select coalesce(sum(valor_motoboy), 0) from public.corridas where not teste and status::text = 'concluida' and concluida_em > now() - interval '30 days'),
      'dev_30d', (select coalesce(sum(valor_dev), 0) from public.corridas where not teste and status::text = 'concluida' and concluida_em > now() - interval '30 days'),
      'corridas_apagadas', (select count(*) from public.registro_exclusoes),
      'contas_excluidas', (select count(*) from public.registro_contas_excluidas),
      'tamanho_banco_mb', (select round(pg_database_size(current_database()) / 1048576.0))
    ),
    'aparelhos', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', m.id, 'nome', p.nome, 'versao_app', m.versao_app, 'status', m.status, 'posicao_em', m.posicao_em,
        'bateria', m.bateria, 'precisao_m', m.precisao_m, 'modo_economia', m.modo_economia, 'modo_teste', m.modo_teste,
        'status_em', m.status_em, 'pings_24h', (select count(*) from public.localizacoes l where l.motoboy_id = m.id and l.registrado_em > now() - interval '24 hours'),
        'push', exists (select 1 from privado.fcm_tokens t where t.motoboy_id = m.id)
      ) order by m.posicao_em desc nulls last)
      from public.motoboys m join public.perfis p on p.id = m.id
    ), '[]'::jsonb),
    'exclusoes', coalesce((
      select jsonb_agg(x order by x->>'quando' desc) from (
        select jsonb_build_object('tipo', 'corrida', 'rotulo', coalesce(case when teste then 'T' else '#' end || numero, '—'),
                 'motivo', motivo, 'por', (select nome from public.perfis where id = excluida_por), 'quando', excluida_em) x
          from public.registro_exclusoes
        union all
        select jsonb_build_object('tipo', 'conta', 'rotulo', coalesce(nome, email), 'motivo', motivo,
                 'por', (select nome from public.perfis where id = excluida_por), 'quando', excluida_em)
          from public.registro_contas_excluidas
        limit 300
      ) t
    ), '[]'::jsonb),
    'tarefas', v_tarefas
  );
end;
$$;


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
                       'motoboy_edita_veiculo', 'mapa_offline_some_h', 'mapa_offline_esmaecer', 'veiculo_obrigatorio',
                       'rota_provedor', 'rota_perfil', 'chat_ligado', 'chat_geral', 'chat_fotos', 'ping_envio_s')
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


notify pgrst, 'reload schema';
