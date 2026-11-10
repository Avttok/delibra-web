-- =====================================================================
-- PW Express · 0010 (parte 2 de 2): Dev, módulos e cor do tema
-- Rode DEPOIS de 20261108000001_papel_dev.sql.
--
--  • Dev: administrador do sistema, acima do gestor. Tudo que o gestor faz,
--    o Dev faz; e só o Dev mexe em contas Dev ou dá o cargo Dev.
--  • Módulos: o Dev liga/desliga partes do sistema e escolhe quem vê cada uma.
--  • Cor do tema por conta: "ouro" (padrão) ou "vermelho" (só Dev).
-- =====================================================================

-- ------------------------------------------------------------- papéis
create or replace function public.is_dev()
returns boolean language sql stable security definer set search_path = ''
as $$ select public.tem_papel('dev'::public.papel_usuario); $$;

-- Dev conta como gestor em todas as regras que já existem
create or replace function public.is_gestor()
returns boolean language sql stable security definer set search_path = ''
as $$ select public.tem_papel('gestor'::public.papel_usuario) or public.tem_papel('dev'::public.papel_usuario); $$;

-- Quem chamou pode mexer na conta p_alvo? Dev: todas. Gestor: todas menos as Dev.
create or replace function public.pode_gerenciar(p_alvo uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select public.is_dev()
      or (public.is_gestor() and not exists (select 1 from public.perfis where id = p_alvo and 'dev' = any (papeis)));
$$;

-- A conta do Ruan é a conta Dev (continua gestor e motoboy também)
update public.perfis p
   set papeis = (select array_agg(distinct x) from unnest(p.papeis || array['dev', 'gestor']::public.papel_usuario[]) x)
 where p.id in (select id from auth.users where lower(email) = 'ruan.carlos@pwexpress.com');

-- ------------------------------------------------------------- editar membro com as proteções
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
    insert into public.motoboys (id, repasse_pct) values (p_usuario, p_repasse)
    on conflict (id) do update set repasse_pct = excluded.repasse_pct;
  end if;
end;
$$;

-- ------------------------------------------------------------- cor do tema
alter table public.perfis add column if not exists cor_tema text not null default 'ouro';
do $$ begin
  alter table public.perfis add constraint perfis_cor_tema_valida check (cor_tema in ('ouro', 'vermelho'));
exception when duplicate_object then null; end $$;
update public.perfis set cor_tema = 'vermelho' where 'dev' = any (papeis) and cor_tema = 'ouro';

create or replace function public.definir_cor_tema(p_cor text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_cor not in ('ouro', 'vermelho') then raise exception 'cor_invalida' using errcode = '22023'; end if;
  if p_cor = 'vermelho' and not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  update public.perfis set cor_tema = p_cor where id = auth.uid();
end;
$$;

-- ------------------------------------------------------------- módulos
create table if not exists public.modulos (
  chave          text primary key,
  nome           text not null,
  descricao      text,
  grupo          text not null default 'geral',
  ligado         boolean not null default true,
  -- quem usa o módulo (null = todos). O Dev sempre vê tudo.
  papeis         public.papel_usuario[],
  ordem          int not null default 0,
  atualizado_em  timestamptz not null default now(),
  atualizado_por uuid references public.perfis (id) on delete set null
);
alter table public.modulos enable row level security;
drop policy if exists modulos_leitura on public.modulos;
create policy modulos_leitura on public.modulos for select to authenticated using (true);
revoke all on public.modulos from anon;
grant select on public.modulos to authenticated;

insert into public.modulos (chave, nome, descricao, grupo, ordem) values
  ('corridas_planejadas', 'Corridas planejadas', 'Criar corridas com data e hora; motoboys reservam no app.', 'Corridas', 10),
  ('pontos_referencia',   'Pontos de referência', 'Até 3 referências perto da coleta e da entrega.', 'Corridas', 20),
  ('excluir_corridas',    'Apagar corridas', 'Gestores podem apagar corridas (com senha e registro).', 'Corridas', 30),
  ('modo_teste',          'Modo teste', 'Gestores podem ligar o modo teste (tudo violeta, corridas de teste).', 'Sistema', 40),
  ('criar_contas',        'Criar contas pelo painel', 'Gestores criam contas de motoboy e gestor no site e no app.', 'Equipe', 50),
  ('carteira',            'Carteira', 'Ganhos, repasses e extratos.', 'Carteira', 60),
  ('trilhas_mapa',        'Trilhas no mapa', 'Pings e percursos dos motoboys no mapa do gestor.', 'Mapa', 70),
  ('estabelecimentos',    'Estabelecimentos no mapa', 'Nomes de lojas, mercados, postos… nos mapas.', 'Mapa', 80),
  ('atualizacao_app',     'Atualização pelo app', 'O app procura e instala versões novas sozinho.', 'Sistema', 90)
on conflict (chave) do nothing;

-- O módulo está valendo para quem chamou?
create or replace function public.modulo_ativo(p_chave text)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((
    select public.is_dev() or (m.ligado and (m.papeis is null or exists (
      select 1 from public.perfis p where p.id = auth.uid() and p.papeis && m.papeis)))
      from public.modulos m where m.chave = p_chave
  ), true);
$$;

create or replace function public.definir_modulo(p_chave text, p_ligado boolean, p_papeis public.papel_usuario[] default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  update public.modulos set ligado = p_ligado, papeis = nullif(p_papeis, '{}'), atualizado_em = now(), atualizado_por = auth.uid()
   where chave = p_chave;
  if not found then raise exception 'modulo_inexistente' using errcode = '22023'; end if;
end;
$$;

-- ------------------------------------------------------------- perfil (com dev, cor e módulos)
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
    'modulos', coalesce((
      select jsonb_object_agg(md.chave,
        'dev' = any (p.papeis) or (md.ligado and (md.papeis is null or p.papeis && md.papeis)))
        from public.modulos md
    ), '{}'::jsonb),
    'configuracoes', coalesce((
      select jsonb_object_agg(chave, valor) from public.configuracoes
       where chave in ('intervalo_corrida_s', 'intervalo_economia_s', 'disponivel_envio_min',
                       'disponivel_distancia_m', 'raio_chegada_m', 'teste_admin_ignora_local', 'oferta_segundos')
    ), '{}'::jsonb)
  )
  from public.perfis p
  left join public.motoboys m on m.id = p.id
  where p.id = auth.uid();
$$;

-- modo teste respeita o módulo (desligar o modo é sempre permitido; o Dev sempre pode)
create or replace function public.definir_modo_teste(p_ligado boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_gestor() then
    raise exception 'apenas_gestor' using errcode = '42501';
  end if;
  if p_ligado and not public.modulo_ativo('modo_teste') then
    raise exception 'modulo_desligado' using errcode = '42501';
  end if;
  if public.tem_papel('motoboy'::public.papel_usuario) then
    if exists (select 1 from public.ofertas where motoboy_id = auth.uid() and status = 'pendente')
       or exists (select 1 from public.corridas where motoboy_id = auth.uid() and status in ('aceita', 'em_andamento')) then
      raise exception 'conclua_a_corrida_antes' using errcode = '22023';
    end if;
    insert into public.motoboys (id, modo_teste) values (auth.uid(), p_ligado)
    on conflict (id) do update set modo_teste = excluded.modo_teste;
  end if;
  update public.perfis set modo_teste = p_ligado where id = auth.uid();
end;
$$;

-- ------------------------------------------------------------- painel do Dev: o sistema "nu"
create or replace function public.painel_dev()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  return jsonb_build_object(
    'contagens', jsonb_build_object(
      'contas', (select count(*) from public.perfis),
      'motoboys_online', (select count(*) from public.motoboys where status <> 'offline'),
      'corridas_reais', (select count(*) from public.corridas where not teste),
      'corridas_teste', (select count(*) from public.corridas where teste),
      'corridas_ativas', (select count(*) from public.corridas where status::text in ('aguardando', 'aceita', 'em_andamento')),
      'pings_24h', (select count(*) from public.localizacoes where registrado_em > now() - interval '24 hours'),
      'pings_total', (select count(*) from public.localizacoes),
      'corridas_apagadas', (select count(*) from public.registro_exclusoes),
      'contas_excluidas', (select count(*) from public.registro_contas_excluidas)
    ),
    'aparelhos', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', m.id, 'nome', p.nome, 'versao_app', m.versao_app, 'status', m.status, 'posicao_em', m.posicao_em,
        'bateria', m.bateria, 'precisao_m', m.precisao_m, 'modo_economia', m.modo_economia, 'modo_teste', m.modo_teste,
        'status_em', m.status_em
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
        order by 1 desc limit 100
      ) t
    ), '[]'::jsonb)
  );
end;
$$;

-- ------------------------------------------------------------- permissões
do $$
declare f text;
begin
  foreach f in array array[
    'public.is_dev()', 'public.pode_gerenciar(uuid)', 'public.definir_cor_tema(text)', 'public.modulo_ativo(text)',
    'public.definir_modulo(text, boolean, public.papel_usuario[])', 'public.painel_dev()', 'public.meu_perfil()',
    'public.editar_membro(uuid, text, public.papel_usuario[], numeric)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
