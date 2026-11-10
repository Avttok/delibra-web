-- =====================================================================
-- PW Express · Seed do piloto
-- Dá ao usuário de teste os papéis de gestor (ver o mapa) e motoboy
-- (usar o app). Rode DEPOIS da migração 0001.
-- =====================================================================

-- cria perfis para usuários que já existiam antes do gatilho
insert into public.perfis (id, nome)
select id, split_part(email, '@', 1)
from auth.users
on conflict (id) do nothing;

update public.perfis
   set papeis = array['gestor', 'motoboy']::public.papel_usuario[]
 where id = '5ee3bba5-7f47-4f3e-9c49-0730dd7b71aa';

insert into public.motoboys (id)
values ('5ee3bba5-7f47-4f3e-9c49-0730dd7b71aa')
on conflict (id) do nothing;

-- conferência: deve mostrar 1 linha com {gestor,motoboy}
select p.id, p.nome, p.papeis, m.status
from public.perfis p
left join public.motoboys m on m.id = p.id
where p.id = '5ee3bba5-7f47-4f3e-9c49-0730dd7b71aa';
