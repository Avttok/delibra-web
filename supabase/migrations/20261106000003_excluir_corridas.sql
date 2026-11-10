-- =====================================================================
-- PW Express · Migração 0004 · Exclusão de corridas com senha
-- ---------------------------------------------------------------------
-- A senha do gestor é conferida aqui no banco (bcrypt do Supabase Auth),
-- então a exclusão não pode ser feita sem ela, nem chamando a API direto.
-- Toda exclusão fica registrada em registro_exclusoes (com uma cópia dos dados).
-- Seguro rodar de novo.
-- =====================================================================

create table if not exists public.registro_exclusoes (
  id          bigint generated always as identity primary key,
  corrida_id  uuid not null,
  numero      bigint,
  teste       boolean,
  status      text,
  valor       numeric(10, 2),
  copia       jsonb not null,          -- corrida + paradas + eventos no momento da exclusão
  motivo      text,
  excluida_por uuid references public.perfis (id) on delete set null,
  excluida_em timestamptz not null default now()
);

alter table public.registro_exclusoes enable row level security;
drop policy if exists registro_exclusoes_leitura on public.registro_exclusoes;
create policy registro_exclusoes_leitura on public.registro_exclusoes
  for select to authenticated using ((select public.is_gestor()));
revoke all on public.registro_exclusoes from anon;
grant select on public.registro_exclusoes to authenticated;

-- tentativas erradas (proteção contra adivinhação de senha)
create table if not exists privado.tentativas_senha (
  usuario   uuid not null,
  quando    timestamptz not null default now()
);

create or replace function privado.senha_confere(p_senha text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  v_hash text;
begin
  if p_senha is null or p_senha = '' then return false; end if;
  select encrypted_password into v_hash from auth.users where id = auth.uid();
  return v_hash is not null and extensions.crypt(p_senha, v_hash) = v_hash;
end;
$$;

-- Apaga corridas (uma ou várias). Devolve os arquivos de comprovante para o site remover do Storage.
create or replace function public.excluir_corridas(p_corridas uuid[], p_senha text, p_motivo text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_ativas   int;
  v_arquivos text[];
  v_qtd      int;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if p_corridas is null or cardinality(p_corridas) = 0 then raise exception 'nada_para_excluir' using errcode = '22023'; end if;

  -- no máximo 5 senhas erradas a cada 15 minutos
  delete from privado.tentativas_senha where quando < now() - interval '15 minutes';
  -- (devolve o erro em vez de lançar exceção, para a tentativa ficar gravada)
  if (select count(*) from privado.tentativas_senha where usuario = auth.uid()) >= 5 then
    return jsonb_build_object('erro', 'muitas_tentativas');
  end if;
  if not privado.senha_confere(p_senha) then
    insert into privado.tentativas_senha (usuario) values (auth.uid());
    return jsonb_build_object('erro', 'senha_incorreta',
      'restantes', 5 - (select count(*) from privado.tentativas_senha where usuario = auth.uid()));
  end if;
  delete from privado.tentativas_senha where usuario = auth.uid();

  select count(*) into v_ativas from public.corridas
   where id = any (p_corridas) and status in ('aceita', 'em_andamento');
  if v_ativas > 0 then raise exception 'cancele_as_corridas_em_andamento' using errcode = '22023'; end if;

  -- cópia de segurança no registro
  insert into public.registro_exclusoes (corrida_id, numero, teste, status, valor, copia, motivo, excluida_por)
  select c.id, c.numero, c.teste, c.status::text, c.valor,
         jsonb_build_object(
           'corrida', to_jsonb(c),
           'paradas', coalesce((select jsonb_agg(to_jsonb(p) order by p.ordem) from public.paradas p where p.corrida_id = c.id), '[]'),
           'eventos', coalesce((select jsonb_agg(to_jsonb(e) order by e.criado_em) from public.eventos_corrida e where e.corrida_id = c.id), '[]')
         ),
         nullif(trim(p_motivo), ''), auth.uid()
    from public.corridas c where c.id = any (p_corridas);

  select coalesce(array_agg(a), '{}') into v_arquivos
    from (select foto_path a from public.paradas where corrida_id = any (p_corridas) and foto_path is not null
          union all
          select assinatura_path from public.paradas where corrida_id = any (p_corridas) and assinatura_path is not null) t;

  delete from public.localizacoes where corrida_id = any (p_corridas);
  delete from public.corridas where id = any (p_corridas);   -- paradas, ofertas e eventos vão junto (cascade)
  get diagnostics v_qtd = row_count;

  return jsonb_build_object('excluidas', v_qtd, 'arquivos', to_jsonb(v_arquivos));
end;
$$;

revoke all on function public.excluir_corridas(uuid[], text, text) from public, anon;
grant execute on function public.excluir_corridas(uuid[], text, text) to authenticated;
revoke all on all functions in schema privado from public, anon, authenticated;

-- gestor pode remover os arquivos de comprovante (o site apaga depois da exclusão)
drop policy if exists comprovantes_exclusao on storage.objects;
create policy comprovantes_exclusao on storage.objects
  for delete to authenticated
  using (bucket_id = 'comprovantes' and (select public.is_gestor()));

-- =====================================================================
-- Correção: enviar foto de perfil (o "substituir se existir" do Storage exige leitura)
-- =====================================================================
drop policy if exists avatares_leitura on storage.objects;
create policy avatares_leitura on storage.objects
  for select to authenticated
  using (bucket_id = 'avatares');

-- =====================================================================
-- Equipe: gestor vê e edita papéis, nome e repasse individual
-- (contas novas continuam sendo criadas em Authentication → Users)
-- =====================================================================
create or replace function public.listar_equipe()
returns table (id uuid, email text, nome text, foto_url text, papeis public.papel_usuario[],
               status public.status_motoboy, modo_teste boolean, repasse_pct numeric, criado_em timestamptz)
language sql stable security definer set search_path = '' as $$
  select p.id, u.email::text, p.nome, p.foto_url, p.papeis, m.status, coalesce(m.modo_teste, false), m.repasse_pct, p.criado_em
    from public.perfis p
    join auth.users u on u.id = p.id
    left join public.motoboys m on m.id = p.id
   where public.is_gestor()
   order by p.nome;
$$;

create or replace function public.editar_membro(p_usuario uuid, p_nome text, p_papeis public.papel_usuario[], p_repasse numeric default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if p_usuario = auth.uid() and not ('gestor' = any (p_papeis)) then
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

revoke all on function public.listar_equipe() from public, anon;
revoke all on function public.editar_membro(uuid, text, public.papel_usuario[], numeric) from public, anon;
grant execute on function public.listar_equipe() to authenticated;
grant execute on function public.editar_membro(uuid, text, public.papel_usuario[], numeric) to authenticated;
