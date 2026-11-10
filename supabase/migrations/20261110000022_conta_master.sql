-- =====================================================================
-- Delibra · 0022: conta master
-- A conta dev@delibra.com é o Dev da plataforma (também gestor e motoboy, para testar).
-- Vale na hora em que a conta é criada (pelo site ou pelo painel do Supabase) e
-- também para uma conta que já exista.
-- =====================================================================
create or replace function privado.conta_master()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from auth.users u where u.id = new.id and lower(u.email) = 'dev@delibra.com') then
    new.papeis := (select array_agg(distinct x) from unnest(coalesce(new.papeis, '{}') || array['dev', 'gestor', 'motoboy']::public.papel_usuario[]) x);
    new.organizacao_id := null;   -- o Dev é da plataforma, não de uma empresa
  end if;
  return new;
end;
$$;
drop trigger if exists conta_master on public.perfis;
create trigger conta_master before insert on public.perfis for each row execute function privado.conta_master();
revoke execute on function privado.conta_master() from public, anon, authenticated;

-- motoboy do Dev (para ele testar o app)
create or replace function privado.conta_master_motoboy()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if 'dev' = any (new.papeis) and 'motoboy' = any (new.papeis) then
    insert into public.motoboys (id) values (new.id) on conflict (id) do nothing;
  end if;
  return new;
end;
$$;
drop trigger if exists conta_master_motoboy on public.perfis;
create trigger conta_master_motoboy after insert on public.perfis for each row execute function privado.conta_master_motoboy();
revoke execute on function privado.conta_master_motoboy() from public, anon, authenticated;

-- contas criadas antes do banco existir ficaram sem perfil: cria agora (o gatilho acima já faz o Dev)
insert into public.perfis (id, nome)
select u.id, coalesce(nullif(u.raw_user_meta_data ->> 'nome', ''), split_part(u.email, '@', 1))
  from auth.users u
 where not exists (select 1 from public.perfis p where p.id = u.id);

-- se a conta já existe
update public.perfis p
   set papeis = (select array_agg(distinct x) from unnest(p.papeis || array['dev', 'gestor', 'motoboy']::public.papel_usuario[]) x),
       organizacao_id = null
 where p.id in (select id from auth.users where lower(email) = 'dev@delibra.com');
insert into public.motoboys (id) select id from auth.users where lower(email) = 'dev@delibra.com' on conflict (id) do nothing;
