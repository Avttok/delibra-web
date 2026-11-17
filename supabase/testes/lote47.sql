-- Lote 47 (0048): cascata Dev → gestor, só pedidos, editar pedido, Hoje por data, histórico. Cada linha diz OK ou FALHA
\i t81.sql
\set QUIET on
\pset tuples_only on
\set ON_ERROR_STOP off
reset role;
select set_config('request.jwt.claims','',false) \g /dev/null
set role authenticated;
select set_config('request.uid','00000000-0000-0000-0000-0000000000a1',false) \g /dev/null
-- 1. gestor não cria rota à mão (padrão)
do $$ begin
  perform public.criar_corrida('{"paradas":[{"tipo":"coleta","endereco":"a","lat":-26.9,"lng":-49.1},{"tipo":"entrega","endereco":"b","lat":-26.92,"lng":-49.08}]}'::jsonb);
  raise notice 'FALHA gestor criou rota à mão';
exception when others then if sqlerrm = 'criar_rota_desligado' then raise notice 'OK criar rota fica desligado por padrão'; else raise notice 'FALHA criar rota: %', sqlerrm; end if; end $$;
-- 2. gestor não grava permissão especial nem ajuste do Dev
reset role;
do $$ begin
  insert into public.politicas (escopo, alvo, chave, valor) values ('motoboy', '00000000-0000-0000-0000-0000000000a3', 'especial_ignora_local', 'true');
  raise notice 'FALHA gestor gravou permissão especial';
exception when others then if sqlerrm like '%so_o_dev%' or sqlerrm like '%row-level%' then raise notice 'OK permissão especial só pelo Dev'; else raise notice 'FALHA especial: %', sqlerrm; end if; end $$;
-- 3. sem permissão especial, gestor+motoboy não ganha nada
reset role;
select case when not privado.especial('especial_ignora_local', '00000000-0000-0000-0000-0000000000a1') then 'OK gestor sem permissão especial' else 'FALHA gestor tem especial sozinho' end;
select set_config('request.uid','',false) \g /dev/null
insert into public.politicas (escopo, alvo, chave, valor) values ('motoboy', '00000000-0000-0000-0000-0000000000a3', 'especial_ignora_local', 'true') on conflict do nothing;
select case when privado.especial('especial_ignora_local', '00000000-0000-0000-0000-0000000000a3') then 'OK Dev concede por pessoa' else 'FALHA especial por pessoa' end;
-- 4. criar e editar pedido (mesmas opções)
set role authenticated;
select set_config('request.uid','00000000-0000-0000-0000-0000000000a1',false) \g /dev/null
select public.criar_pedido(jsonb_build_object('quando', now() + interval '1 day', 'pontos', '[{"tipo":"coleta","endereco":"a","lat":-26.9,"lng":-49.1},{"tipo":"entrega","endereco":"b","lat":-26.92,"lng":-49.08}]'::jsonb,
  'itens', '[{"descricao":"Caixa","quantidade":3,"coleta":0,"entrega":1}]'::jsonb)) as ped \gset
select (public.pedido_para_editar(:'ped') -> 'pontos' -> 0 ->> 'endereco') = 'a' as x \gset
select case when :'x' then 'OK pedido abre no editor' else 'FALHA editor' end;
select public.criar_pedido(jsonb_build_object('editar_id', :'ped', 'quando', now() + interval '2 day', 'urgente', true,
  'pontos', '[{"tipo":"coleta","endereco":"a2","lat":-26.9,"lng":-49.1},{"tipo":"entrega","endereco":"b2","lat":-26.92,"lng":-49.08},{"tipo":"entrega","endereco":"c2","lat":-26.93,"lng":-49.07}]'::jsonb,
  'itens', '[{"descricao":"Caixa","quantidade":2,"coleta":0,"entrega":1},{"descricao":"Caixa","quantidade":1,"coleta":0,"entrega":2}]'::jsonb)) as ped2 \gset
reset role;
select case when :'ped' = :'ped2' and (select count(*) from public.pedido_pontos where pedido_id = :'ped') = 3
            and (select urgente from public.pedidos where id = :'ped') and (select count(*) from public.pedido_itens where pedido_id = :'ped' and entrega_id is not null) = 2
       then 'OK pedido editado (pontos, itens e opções)' else 'FALHA edição' end;
-- 5. Hoje de outra data e histórico
set role authenticated;
select set_config('request.uid','00000000-0000-0000-0000-0000000000a1',false) \g /dev/null
select case when (public.painel_do_dia((now() - interval '3 day')::date) ->> 'hoje')::boolean = false then 'OK Hoje de outra data' else 'FALHA Hoje por data' end;
select case when jsonb_typeof(public.historico_rotas('{"de":"2020-01-01"}')) = 'array' then 'OK histórico de rotas' else 'FALHA histórico' end;
select (public.historico_rotas('{"de":"2020-01-01","teste":false}') -> 0 ->> 'id') as rid \gset
do $$ begin
  if nullif(current_setting('teste.rid', true), '') is null then raise notice 'OK ficha da rota (sem rotas)'; return; end if;
  if public.ficha_rota(current_setting('teste.rid')::uuid) ? 'eventos' then raise notice 'OK ficha da rota'; else raise notice 'FALHA ficha'; end if;
exception when others then raise notice 'FALHA ficha: %', sqlerrm; end $$;
-- 6. tipos de pedido desligados: o gestor só não vê
select case when (select count(*) from public.tipos_pedido) = 0 then 'OK tipos de pedido desligados' else 'FALHA tipos visíveis' end;
-- 0049: ficha do motoboy só para ele
set role authenticated;
select set_config('request.uid','00000000-0000-0000-0000-0000000000a1',false) \g /dev/null
do $$ begin perform public.minha_ficha_rota('00000000-0000-0000-0000-0000000000f8'); raise notice 'FALHA ficha de outro motoboy abriu';
exception when others then if sqlerrm = 'corrida_nao_e_sua' then raise notice 'OK ficha do motoboy só para ele'; else raise notice 'FALHA ficha motoboy: %', sqlerrm; end if; end $$;
