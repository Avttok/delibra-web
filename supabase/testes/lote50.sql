-- Lote 50 (0051): Delibra Dev / o Fantasma. Cada linha diz OK ou FALHA
\i t81.sql
\set QUIET on
\pset tuples_only on
\set ON_ERROR_STOP off
reset role;
select set_config('request.jwt.claims','',false) \g /dev/null
set role authenticated;
-- 1. só o Dev mexe nas regras
select set_config('request.uid','00000000-0000-0000-0000-0000000000a1',false) \g /dev/null
do $$ begin perform public.dev_regras(); raise notice 'FALHA gestor leu regras';
exception when others then raise notice 'OK regras só para o Dev'; end $$;
-- 2. precedência pessoa > empresa > global
select set_config('request.uid','00000000-0000-0000-0000-0000000000d1',false) \g /dev/null
select public.dev_salvar_regra('{"chave":"oferta_segundos","escopo":"global","valor":10,"porque":"teste"}') \g /dev/null
select public.dev_salvar_regra(jsonb_build_object('chave','oferta_segundos','escopo','empresa','alvo',:'oa','valor',20)) \g /dev/null
select public.dev_salvar_regra('{"chave":"oferta_segundos","escopo":"pessoa","alvo":"00000000-0000-0000-0000-0000000000a1","valor":30}') as rp \gset
reset role;
select set_config('request.uid','',false) \g /dev/null
insert into auth.users(id,email) values ('00000000-0000-0000-0000-0000000000f1','solto@x') on conflict do nothing;
select case when privado.pol('oferta_segundos', null, '00000000-0000-0000-0000-0000000000a1') = '30'
             and privado.pol('oferta_segundos', null, '00000000-0000-0000-0000-0000000000a3') = '20'
             and privado.pol('oferta_segundos', null, '00000000-0000-0000-0000-0000000000f1') = '10'
       then 'OK regra pessoa > empresa > global' else 'FALHA precedência' end;
-- 3. o Dev não sofre regra que não fez para si
select case when privado.decide('00000000-0000-0000-0000-0000000000d1', 'oferta_segundos') is null then 'OK Dev imune às regras dos outros' else 'FALHA Dev afetado' end;
insert into public.regras_dev (chave, escopo, alvo, valor) values ('oferta_segundos', 'pessoa', '00000000-0000-0000-0000-0000000000d1', '99');
select case when privado.decide('00000000-0000-0000-0000-0000000000d1', 'oferta_segundos') ->> 'valor' = '99' then 'OK regra do Dev para si mesmo vale' else 'FALHA regra própria' end;
-- 4. condição de dia: regra fora do dia não vale
insert into public.regras_dev (chave, escopo, valor, condicoes) values ('raio_chegada_m', 'global', '777',
  jsonb_build_object('dias', jsonb_build_array(((extract(isodow from now() at time zone 'America/Sao_Paulo')::int) % 7) + 1)));
select case when privado.decide('00000000-0000-0000-0000-0000000000a1', 'raio_chegada_m') is null then 'OK condição de dia respeitada' else 'FALHA condição' end;
-- 5. módulo desligado só para um cliente: o servidor recusa
insert into public.regras_dev (chave, escopo, alvo, valor, porque) values ('modulo:pedidos', 'cliente', '00000000-0000-0000-0000-0000000000e1', 'false', 'cliente inadimplente');
set role authenticated;
select set_config('request.uid','00000000-0000-0000-0000-0000000000c1',false) \g /dev/null
do $$ begin
  perform public.criar_pedido(jsonb_build_object('quando', now() + interval '1 day', 'pontos', '[{"tipo":"coleta","endereco":"a","lat":-26.9,"lng":-49.1},{"tipo":"entrega","endereco":"b","lat":-26.92,"lng":-49.08}]'::jsonb));
  raise notice 'FALHA cliente criou pedido com módulo desligado';
exception when others then if sqlerrm = 'modulo_desligado' then raise notice 'OK módulo desligado para o cliente trava no servidor'; else raise notice 'FALHA módulo: %', sqlerrm; end if; end $$;
select case when (public.meu_perfil() -> 'modulos' ->> 'pedidos') = 'false' then 'OK perfil do cliente mostra módulo desligado' else 'FALHA perfil cliente' end;
select set_config('request.uid','00000000-0000-0000-0000-0000000000a1',false) \g /dev/null
select case when public.modulo_ativo('pedidos') then 'OK gestor segue com pedidos' else 'FALHA gestor perdeu pedidos' end;
-- 6. ação bloqueada para uma pessoa
reset role;
insert into public.regras_dev (chave, escopo, alvo, valor) values ('acao:excluir_corrida', 'pessoa', '00000000-0000-0000-0000-0000000000a1', 'false');
set role authenticated;
select case when not public.posso('excluir_corrida') then 'OK ação bloqueada por regra' else 'FALHA ação' end;
-- 7. permissão especial para cliente
reset role;
select set_config('request.uid','',false) \g /dev/null
insert into public.politicas (escopo, alvo, chave, valor) values ('cliente', '00000000-0000-0000-0000-0000000000e1', 'especial_cliente_edita_aprovado', 'true') on conflict (escopo, alvo, chave) do update set valor = 'true';
select case when privado.especial('especial_cliente_edita_aprovado', '00000000-0000-0000-0000-0000000000c1')
             and not privado.especial('especial_cliente_edita_aprovado', '00000000-0000-0000-0000-0000000000a3') then 'OK permissão especial do cliente' else 'FALHA especial cliente' end;
-- 8. por quê, matriz, comando, explorador
set role authenticated;
select set_config('request.uid','00000000-0000-0000-0000-0000000000d1',false) \g /dev/null
select case when public.dev_explicar('00000000-0000-0000-0000-0000000000c1', 'modulo:pedidos') ->> 'motivo' like 'Regra do Dev: cliente inadimplente%'
             and public.dev_explicar('00000000-0000-0000-0000-0000000000a1', 'oferta_segundos') ->> 'fonte' = 'regra'
             and public.dev_explicar('00000000-0000-0000-0000-0000000000a3', 'especial_ignora_local') ->> 'fonte' is not null
       then 'OK por quê explica a origem' else 'FALHA explicar' end;
select case when jsonb_array_length(public.dev_matriz(:'oa', array['modulo:pedidos', 'acao:excluir_corrida', 'oferta_segundos'])) >= 3 then 'OK matriz pessoa × permissão' else 'FALHA matriz' end;
select case when jsonb_array_length(public.dev_comando() -> 'empresas') >= 2 and (public.dev_comando() ->> 'regras_ativas')::int >= 5 then 'OK comando ao vivo' else 'FALHA comando' end;
select case when jsonb_array_length(public.dev_tabelas()) > 20 and (public.dev_explorar('perfis', 'Moto', 10, 0, '-nome') ->> 'total')::int >= 2 then 'OK explorador de dados' else 'FALHA explorador' end;
do $$ begin perform public.dev_explorar('perfis; drop table x', null); raise notice 'FALHA explorador aceitou nome ruim';
exception when others then raise notice 'OK explorador só aceita tabela real'; end $$;
-- 9. versões: muda e volta
select public.dev_salvar_regra(jsonb_build_object('id', :'rp', 'chave','oferta_segundos','escopo','pessoa','alvo','00000000-0000-0000-0000-0000000000a1','valor',45)) \g /dev/null
select public.dev_restaurar_regra(:'rp', 1);
select case when (select valor from public.regras_dev where id = :'rp') = '30' and jsonb_array_length(public.dev_regras_historico(:'rp')) >= 3 then 'OK versões da regra' else 'FALHA versões' end;
-- 10. novidades por área
select set_config('request.uid','00000000-0000-0000-0000-0000000000a3',false) \g /dev/null
select case when not exists (select 1 from jsonb_array_elements(public.minhas_novidades()) n where n ->> 'area' in ('gestor', 'dev', 'cliente'))
             and exists (select 1 from jsonb_array_elements(public.minhas_novidades()) n where n ->> 'area' = 'todos') then 'OK motoboy só vê novidades dele' else 'FALHA novidades motoboy' end;
select set_config('request.uid','00000000-0000-0000-0000-0000000000d1',false) \g /dev/null
select case when exists (select 1 from jsonb_array_elements(public.minhas_novidades()) n where n ->> 'area' = 'dev') then 'OK Dev vê todas as áreas' else 'FALHA novidades dev' end;
-- 11. aviso só para motoboys
select public.dev_avisar('{"texto":"Chuva forte","nivel":"aviso","papeis":["motoboy"]}') \g /dev/null
select set_config('request.uid','00000000-0000-0000-0000-0000000000a3',false) \g /dev/null
select jsonb_array_length(public.avisos_para_mim()) as am \gset
select set_config('request.uid','00000000-0000-0000-0000-0000000000a1',false) \g /dev/null
select case when :am = 1 and jsonb_array_length(public.avisos_para_mim()) = 0 then 'OK aviso só para quem deve' else 'FALHA avisos' end;
-- 12. emergência e registro do Dev
select set_config('request.uid','00000000-0000-0000-0000-0000000000d1',false) \g /dev/null
select public.dev_congelar_empresa(:'ob', true, 'teste') \g /dev/null
select public.dev_derrubar_sessoes(null, :'ob') \g /dev/null
select public.dev_congelar_empresa(:'ob', false) \g /dev/null
select case when (select status from public.organizacoes where id = :'ob') = 'ativa'
             and jsonb_array_length(public.dev_registro(50)) >= 5
             and exists (select 1 from jsonb_array_elements(public.dev_registro(200)) r where r ->> 'area' = 'organizacoes') then 'OK emergência anotada no registro do Dev' else 'FALHA registro' end;
select set_config('request.uid','00000000-0000-0000-0000-0000000000a1',false) \g /dev/null
select case when (select count(*) from public.registro_dev) = 0 then 'OK registro do Dev invisível ao gestor' else 'FALHA registro vazou' end;
