-- API das lojas, termos e travamentos: cada linha diz OK ou FALHA (o CI para em FALHA)
\i t81.sql
\set QUIET on
\pset tuples_only on
reset role;
set role authenticated;
select set_config('request.uid','00000000-0000-0000-0000-0000000000a1',false) \g /dev/null
select public.api_criar_chave('00000000-0000-0000-0000-0000000000e1','Loja teste') ->> 'chave' as chave \gset
select case when :'chave' like 'dlb_%' and length(:'chave') = 68 then 'OK chave criada' else 'FALHA chave' end;
select case when public.api_definir_webhook('00000000-0000-0000-0000-0000000000e1','https://loja.exemplo.com/hook') -> 'webhook' ->> 'url' = 'https://loja.exemplo.com/hook' then 'OK webhook salvo' else 'FALHA webhook' end;
reset role;
select set_config('request.uid','',false) \g /dev/null
select set_config('request.jwt.claims','{"role":"service_role"}',false) \g /dev/null
select public.api_criar_pedido(encode(sha256(convert_to(:'chave','UTF8')),'hex'),
  jsonb_build_object('referencia_externa','PED-1','quando', now() + interval '1 day',
    'pontos', '[{"tipo":"coleta","endereco":"a","lat":-27.59,"lng":-48.55},{"tipo":"entrega","endereco":"b","lat":-27.6,"lng":-48.56}]'::jsonb,
    'itens', '[{"descricao":"Caixa","quantidade":1,"entrega":1}]'::jsonb)) ->> 'id' as pid \gset
select case when status = 'recebido' and origem = 'api' and referencia_externa = 'PED-1' then 'OK pedido pela API' else 'FALHA pedido pela API' end from public.pedidos where id = :'pid';
select set_config('request.jwt.claims','{"role":"service_role"}',false) \g /dev/null
select case when public.api_criar_pedido(encode(sha256(convert_to(:'chave','UTF8')),'hex'), jsonb_build_object('referencia_externa','PED-1','quando', now() + interval '1 day','pontos','[]'::jsonb)) ->> 'id' = :'pid'
  then 'OK referência repetida não duplica' else 'FALHA referência repetida' end;
select case when count(*) = 1 then 'OK webhook na fila' else 'FALHA webhook na fila' end from privado.avisos_externos where canal = 'webhook' and assunto = 'pedido.recebido';
select set_config('request.jwt.claims','{"role":"service_role"}',false) \g /dev/null
select case when public.api_cancelar_pedido(encode(sha256(convert_to(:'chave','UTF8')),'hex'), :'pid'::uuid) ->> 'status' = 'cancelado' then 'OK cancelar pela API' else 'FALHA cancelar' end;
-- chave errada e empresa de outra transportadora
select set_config('request.jwt.claims','{"role":"service_role"}',false) \g /dev/null
do $$ begin perform public.api_pedido('errado', null, 'PED-1'); raise notice 'FALHA chave errada passou'; exception when others then if sqlerrm like '%chave_invalida%' then raise notice 'OK chave errada barrada'; else raise notice 'FALHA chave errada: %', sqlerrm; end if; end $$;
reset role;
select set_config('request.jwt.claims','',false) \g /dev/null
set role authenticated;
select set_config('request.uid','00000000-0000-0000-0000-0000000000b1',false) \g /dev/null
do $$ begin perform public.api_da_empresa('00000000-0000-0000-0000-0000000000e1'); raise notice 'FALHA outra empresa viu a API'; exception when others then raise notice 'OK outra empresa barrada'; end $$;
-- termos
select set_config('request.uid','00000000-0000-0000-0000-0000000000a3',false) \g /dev/null
select case when (public.termos_situacao() ->> 'aceito')::boolean = false then 'OK termos pendentes' else 'FALHA termos pendentes' end;
select case when (public.aceitar_termos(public.termos_situacao() ->> 'versao', 'teste') ->> 'aceito')::boolean then 'OK termos aceitos' else 'FALHA termos aceitos' end;
-- travamentos (mesmo erro em linhas diferentes conta como um)
select case when public.registrar_erros_app('[{"tipo":"travou","versao":"t","pilha":"java.lang.NullPointerException\n at a.B.c(B.kt:12)"},{"tipo":"travou","versao":"t","pilha":"java.lang.NullPointerException\n at a.B.c(B.kt:13)"}]') = 2
  then 'OK travamentos recebidos' else 'FALHA travamentos' end;
select set_config('request.uid','00000000-0000-0000-0000-0000000000d1',false) \g /dev/null
select case when jsonb_array_length(public.dev_erros_app(7) -> 'lista') = 1 and (public.dev_erros_app(7) ->> 'total')::int = 2 then 'OK travamentos agrupados' else 'FALHA travamentos agrupados' end;
reset role;
