-- =====================================================================
-- PW Express · Migração 0008 · Controle total das contas pelo gestor
-- ---------------------------------------------------------------------
-- · Bloquear / desbloquear acesso (feito pelo site, via Supabase Auth)
-- · Excluir conta com a senha do gestor. Antes de apagar:
--     - o nome fica guardado nas corridas da pessoa (o histórico não perde quem fez)
--     - uma cópia do perfil vai para registro_contas_excluidas
-- · listar_equipe() passa a dizer se a conta está bloqueada
-- Pré-requisito: migrações até a 0007. Seguro rodar de novo.
-- =====================================================================

alter table public.corridas add column if not exists motoboy_nome_arquivado text;
alter table public.corridas add column if not exists criada_por_nome_arquivado text;

create table if not exists public.registro_contas_excluidas (
  id            bigint generated always as identity primary key,
  usuario_id    uuid not null,
  email         text,
  nome          text,
  papeis        text[],
  copia         jsonb not null,
  motivo        text,
  excluida_por  uuid references public.perfis (id) on delete set null,
  excluida_em   timestamptz not null default now()
);

alter table public.registro_contas_excluidas enable row level security;
drop policy if exists registro_contas_excluidas_leitura on public.registro_contas_excluidas;
create policy registro_contas_excluidas_leitura on public.registro_contas_excluidas
  for select to authenticated using ((select public.is_gestor()));
revoke all on public.registro_contas_excluidas from anon;
grant select on public.registro_contas_excluidas to authenticated;

-- ---------------------------------------------------------------------
-- Confere tudo e arquiva. Quem apaga a conta de fato é o site (Auth Admin),
-- logo depois de receber {ok: true} daqui.
-- ---------------------------------------------------------------------
create or replace function public.preparar_exclusao_conta(p_usuario uuid, p_senha text, p_motivo text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_perfil public.perfis%rowtype;
  v_email  text;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;

  -- mesma proteção da exclusão de corridas: 5 senhas erradas → 15 min bloqueado
  delete from privado.tentativas_senha where quando < now() - interval '15 minutes';
  if (select count(*) from privado.tentativas_senha where usuario = auth.uid()) >= 5 then
    return jsonb_build_object('erro', 'muitas_tentativas');
  end if;
  if not privado.senha_confere(p_senha) then
    insert into privado.tentativas_senha (usuario) values (auth.uid());
    return jsonb_build_object('erro', 'senha_incorreta',
      'restantes', 5 - (select count(*) from privado.tentativas_senha where usuario = auth.uid()));
  end if;
  delete from privado.tentativas_senha where usuario = auth.uid();

  if p_usuario = auth.uid() then return jsonb_build_object('erro', 'nao_exclua_a_si_mesmo'); end if;
  select * into v_perfil from public.perfis where id = p_usuario;
  if not found then return jsonb_build_object('erro', 'usuario_nao_encontrado'); end if;
  if exists (select 1 from public.corridas where motoboy_id = p_usuario and status in ('aceita', 'em_andamento'))
     or exists (select 1 from public.ofertas where motoboy_id = p_usuario and status = 'pendente') then
    return jsonb_build_object('erro', 'membro_em_corrida');
  end if;

  select email::text into v_email from auth.users where id = p_usuario;

  -- o histórico guarda quem foi
  update public.corridas set motoboy_nome_arquivado = v_perfil.nome where motoboy_id = p_usuario;
  update public.corridas set criada_por_nome_arquivado = v_perfil.nome where criada_por = p_usuario;

  insert into public.registro_contas_excluidas (usuario_id, email, nome, papeis, copia, motivo, excluida_por)
  values (p_usuario, v_email, v_perfil.nome, v_perfil.papeis::text[],
          jsonb_build_object(
            'perfil', to_jsonb(v_perfil),
            'motoboy', (select to_jsonb(m) - 'posicao' from public.motoboys m where m.id = p_usuario),
            'corridas_feitas', (select count(*) from public.corridas where motoboy_id = p_usuario and status = 'concluida'),
            'corridas_criadas', (select count(*) from public.corridas where criada_por = p_usuario)
          ),
          nullif(trim(p_motivo), ''), auth.uid());

  return jsonb_build_object('ok', true, 'email', v_email, 'nome', v_perfil.nome);
end;
$$;

-- equipe com o estado do acesso
drop function if exists public.listar_equipe();
create function public.listar_equipe()
returns table (id uuid, email text, nome text, foto_url text, papeis public.papel_usuario[],
               status public.status_motoboy, modo_teste boolean, repasse_pct numeric, criado_em timestamptz,
               bloqueado boolean, ultimo_acesso timestamptz)
language sql stable security definer set search_path = '' as $$
  select p.id, u.email::text, p.nome, p.foto_url, p.papeis, m.status, coalesce(m.modo_teste, p.modo_teste), m.repasse_pct, p.criado_em,
         coalesce(u.banned_until > now(), false), u.last_sign_in_at
    from public.perfis p
    join auth.users u on u.id = p.id
    left join public.motoboys m on m.id = p.id
   where public.is_gestor()
   order by p.nome;
$$;

revoke all on all functions in schema privado from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array['public.preparar_exclusao_conta(uuid, text, text)', 'public.listar_equipe()'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
