-- 0050 · ajuste "Motoboy vê as avaliações" no grupo do que o motoboy vê
insert into public.ajuste_grupos (chave, grupo, area) values ('motoboy_ve_notas', 'mb_ve', 'motoboys')
on conflict (chave) do update set grupo = excluded.grupo, area = excluded.area;
