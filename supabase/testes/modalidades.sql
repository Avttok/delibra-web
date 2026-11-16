-- Motor de modalidades (0046): cada linha diz OK ou FALHA
\i t81.sql
\set QUIET on
\pset tuples_only on
\set ON_ERROR_STOP off
reset role;
select set_config('request.jwt.claims','',false) \g /dev/null
set role authenticated;
select set_config('request.uid','00000000-0000-0000-0000-0000000000a1',false) \g /dev/null
-- 1. campo próprio obrigatório no pedido
select public.salvar_campo('{"entidade":"pedido","rotulo":"Número da nota","tipo":"texto","obrigatorio":true,"quem_preenche":"cliente"}') is not null as x \gset
select set_config('request.uid','00000000-0000-0000-0000-0000000000c1',false) \g /dev/null
do $$ begin
  perform public.criar_pedido(jsonb_build_object('quando', now() + interval '1 day', 'pontos', '[{"tipo":"coleta","endereco":"a","lat":-26.9,"lng":-49.1},{"tipo":"entrega","endereco":"b","lat":-26.92,"lng":-49.08}]'::jsonb));
  raise notice 'FALHA campo obrigatório não barrou';
exception when others then if sqlerrm like 'campo_obrigatorio:Número da nota%' then raise notice 'OK campo obrigatório barra o pedido'; else raise notice 'FALHA campo obrigatório: %', sqlerrm; end if; end $$;
select public.criar_pedido(jsonb_build_object('quando', now() + interval '1 day', 'extras', '{"numero_da_nota":"NF 123","lixo":"x"}'::jsonb,
  'pontos', '[{"tipo":"coleta","endereco":"a","lat":-26.9,"lng":-49.1},{"tipo":"entrega","endereco":"b","lat":-26.92,"lng":-49.08}]'::jsonb)) as ped \gset
reset role;
select case when extras = '{"numero_da_nota":"NF 123"}'::jsonb then 'OK campo salvo no pedido (e só ele)' else 'FALHA campo salvo: ' || extras::text end from public.pedidos where id = :'ped';
-- 2. regra extra de preço: 2% do valor declarado
set role authenticated;
select set_config('request.uid','00000000-0000-0000-0000-0000000000a1',false) \g /dev/null
select public.salvar_regra_extra('{"alvo":"preco","nome":"Seguro","unidade":"pct_declarado","valor":2}') is not null as x \gset
reset role;
select case when exists (select 1 from jsonb_array_elements(privado.orcar(jsonb_build_object('empresa_id','00000000-0000-0000-0000-0000000000e1',
    'pontos','[{"tipo":"coleta","lat":-26.9,"lng":-49.1},{"tipo":"entrega","lat":-26.92,"lng":-49.08}]'::jsonb,
    'itens','[{"quantidade":1,"valor_declarado":1000}]'::jsonb)) -> 'linhas') l where l ->> 'rotulo' = 'Seguro' and (l ->> 'valor')::numeric = 20)
  then 'OK regra extra de preço entra no orçamento' else 'FALHA regra extra de preço' end;
-- 3. regra extra de pagamento: bônus fixo R$ 7
select (privado.calcular_pagamento('00000000-0000-0000-0000-0000000000f8') ->> 'total')::numeric as antes \gset
set role authenticated;
select set_config('request.uid','00000000-0000-0000-0000-0000000000a1',false) \g /dev/null
select public.salvar_regra_extra('{"alvo":"pagamento","nome":"Bônus","unidade":"fixo","valor":7}') is not null as x \gset
reset role;
select case when (privado.calcular_pagamento('00000000-0000-0000-0000-0000000000f8') ->> 'total')::numeric = :'antes'::numeric + 7
  then 'OK regra extra de pagamento soma no total' else 'FALHA regra extra de pagamento' end;
-- 4. cargo personalizado bloqueia uma ação
set role authenticated;
select set_config('request.uid','00000000-0000-0000-0000-0000000000a1',false) \g /dev/null
select public.salvar_cargo('{"nome":"Atendente","permissoes":{"pedidos":true,"financeiro":false},"acoes":{"editar_valor_pedido":false}}') as cargo \gset
select public.definir_cargo_pessoa('00000000-0000-0000-0000-0000000000a2', :'cargo') \g /dev/null
reset role;
select case when permissoes = '{"pedidos":true,"financeiro":false}'::jsonb then 'OK cargo aplica as permissões' else 'FALHA cargo permissões: ' || permissoes::text end from public.perfis where id = '00000000-0000-0000-0000-0000000000a2';
set role authenticated;
select set_config('request.uid','00000000-0000-0000-0000-0000000000a2',false) \g /dev/null
select set_config('teste.ped', :'ped', false) \g /dev/null
do $$ begin perform public.definir_regras_pedido(current_setting('teste.ped')::uuid, '{}'::jsonb); raise notice 'FALHA cargo não bloqueou';
exception when others then if sqlerrm like '%acao_bloqueada%' then raise notice 'OK cargo bloqueia a ação'; else raise notice 'FALHA cargo: %', sqlerrm; end if; end $$;
-- 5. módulo desligado só para uma empresa
select set_config('request.uid','00000000-0000-0000-0000-0000000000d1',false) \g /dev/null
select public.definir_modulo_empresa((select organizacao_id from public.perfis where id = '00000000-0000-0000-0000-0000000000a1'), 'chat', false) \g /dev/null
select set_config('request.uid','00000000-0000-0000-0000-0000000000a1',false) \g /dev/null
select case when not public.modulo_ativo('chat') and (public.meu_perfil() -> 'modulos' ->> 'chat') = 'false' then 'OK módulo desligado na empresa A' else 'FALHA módulo empresa A' end;
select set_config('request.uid','00000000-0000-0000-0000-0000000000b1',false) \g /dev/null
select case when public.modulo_ativo('chat') then 'OK módulo segue ligado na empresa B' else 'FALHA módulo empresa B' end;
-- 6. veículo: cliente só aceita carro
reset role;
insert into public.politicas (escopo, alvo, chave, valor) values ('cliente', '00000000-0000-0000-0000-0000000000e1', 'veiculos_aceitos', '["carro"]');
select case when not privado.veiculo_serve('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000f8') then 'OK moto não recebe rota que pede carro' else 'FALHA veículo moto' end;
update public.motoboys set veiculo_tipo = 'carro' where id = '00000000-0000-0000-0000-0000000000a3';
select case when privado.veiculo_serve('00000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000f8') then 'OK carro recebe' else 'FALHA veículo carro' end;
delete from public.politicas where chave = 'veiculos_aceitos';
-- 7. nome próprio de status
set role authenticated;
select set_config('request.uid','00000000-0000-0000-0000-0000000000a1',false) \g /dev/null
select public.salvar_rotulo('pedido:recebido', 'Aguardando conferência') \g /dev/null
select case when public.meu_perfil() -> 'rotulos' ->> '|pedido:recebido' = 'Aguardando conferência' then 'OK nome próprio de status' else 'FALHA nome próprio' end;
-- 8. respostas do motoboy na parada (limpeza e tipos)
select public.salvar_campo('{"entidade":"ponto","ponto_tipo":"entrega","rotulo":"Dinheiro recebido","chave":"dinheiro","tipo":"dinheiro","quem_preenche":"motoboy"}') is not null as x \gset
reset role;
select case when privado.limpar_extras((select organizacao_id from public.perfis where id = '00000000-0000-0000-0000-0000000000a1'), 'ponto', null,
  '{"dinheiro":"35,50","outro":"x"}', 'motoboy', false) = '{"dinheiro":35.50}'::jsonb then 'OK resposta da parada limpa e no tipo certo' else 'FALHA resposta da parada' end;
-- 9. API: limite por minuto
insert into public.politicas (escopo, alvo, chave, valor) values ('organizacao', (select organizacao_id from public.perfis where id = '00000000-0000-0000-0000-0000000000a1')::text, 'api_limite_minuto', '2');
set role authenticated;
select set_config('request.uid','00000000-0000-0000-0000-0000000000a1',false) \g /dev/null
select public.api_criar_chave('00000000-0000-0000-0000-0000000000e1','Loja') ->> 'chave' as chave \gset
reset role;
select set_config('request.uid','',false) \g /dev/null
select set_config('request.jwt.claims','{"role":"service_role"}',false) \g /dev/null
select set_config('teste.chave', :'chave', false) \g /dev/null
do $$ declare h text := encode(sha256(convert_to(current_setting('teste.chave'), 'UTF8')), 'hex'); n int := 0; begin
  for i in 1..3 loop
    begin perform public.api_pedidos(h); perform set_config('request.jwt.claims','{"role":"service_role"}', true); n := n + 1;
    exception when others then if sqlerrm like '%limite_excedido%' then raise notice 'OK limite da API barra a 3ª chamada (passaram %)', n; return; end if; raise notice 'FALHA limite: %', sqlerrm; return; end;
  end loop;
  raise notice 'FALHA limite não barrou';
end $$;
