-- =====================================================================
-- Equipe: contas criadas pelo "Criar conta" do site do cliente ficam fora da
-- lista da equipe enquanto o cadastro espera aprovação ou foi recusado
-- (ao aprovar, a conta vira cliente e já sai da equipe pelo papel).
-- Rode depois de 20261110000001_refinamento.
-- =====================================================================
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
   where public.is_gestor()
     and not (cardinality(p.papeis) = 0
              and exists (select 1 from public.cadastros_cliente c where c.perfil_id = p.id and c.status in ('pendente', 'recusado')))
   order by p.nome;
$$;
revoke all on function public.listar_equipe() from public, anon;
grant execute on function public.listar_equipe() to authenticated;
