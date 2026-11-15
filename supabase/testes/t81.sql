\i t80.sql
\set QUIET on
\echo ===== 43
set role authenticated;
\echo == vagas e gestor nao cria gestor
select set_config('request.uid','00000000-0000-0000-0000-0000000000a1',false) \g /dev/null
select public.vagas_da_equipe();
reset role;
insert into auth.users(id,email) values ('00000000-0000-0000-0000-0000000000a7','g2@x');
select set_config('request.uid','00000000-0000-0000-0000-0000000000a1',false) \g /dev/null
update perfis set organizacao_id=:'oa', papeis='{gestor}' where id='00000000-0000-0000-0000-0000000000a7';
select set_config('request.uid','00000000-0000-0000-0000-0000000000d1',false) \g /dev/null
update perfis set organizacao_id=:'oa', papeis='{gestor}' where id='00000000-0000-0000-0000-0000000000a7';
update configuracoes set valor='2' where chave='dev_gestores_por_empresa';
update perfis set organizacao_id=:'oa', papeis='{gestor}' where id='00000000-0000-0000-0000-0000000000a7';
select papeis from perfis where id='00000000-0000-0000-0000-0000000000a7';
\echo == holerite visibilidade
set role authenticated;
select set_config('request.uid','00000000-0000-0000-0000-0000000000a1',false) \g /dev/null
select public.ajuste_holerite('00000000-0000-0000-0000-0000000000a3', current_date - 3, current_date + 3, 'Vale', -50, false, 'oculto') is not null;
select public.ajuste_holerite('00000000-0000-0000-0000-0000000000a3', current_date - 3, current_date + 3, 'Bônus chuva', 20, false, 'valor') is not null;
select jsonb_array_length(privado.holerite_json('00000000-0000-0000-0000-0000000000a3', current_date - 3, current_date + 3, false, true) -> 'ajustes') gestor_ve;
reset role;
select set_config('request.uid','00000000-0000-0000-0000-0000000000a3',false) \g /dev/null
select x -> 'ajustes', x ->> 'total' from privado.holerite_json('00000000-0000-0000-0000-0000000000a3', current_date - 3, current_date + 3, false, true) x;
\echo == regras de rota concluida recalcula
set role authenticated;
select set_config('request.uid','00000000-0000-0000-0000-0000000000a1',false) \g /dev/null
select valor_motoboy antes from corridas where id='00000000-0000-0000-0000-0000000000f8';
select public.definir_regras_rota('00000000-0000-0000-0000-0000000000f8', '{"pag_modos":["fixo"],"fx_valor_rota":33}') ->> 'total' total;
select valor_motoboy depois from corridas where id='00000000-0000-0000-0000-0000000000f8';
select public.ajustar_pagamento_rota('00000000-0000-0000-0000-0000000000f8', -3, 'atraso', false) ->> 'valor_motoboy';
\echo == dev oculto some
select count(*) dev_visivel from perfis where id='00000000-0000-0000-0000-0000000000d1';
select public.nome_publico('00000000-0000-0000-0000-0000000000d1');
select set_config('request.uid','00000000-0000-0000-0000-0000000000d1',false) \g /dev/null
select jsonb_array_length(public.dev_usuarios()) contas, public.dev_saude() ->> 'banco_mb' is not null saude;
select public.dev_definir_papeis('00000000-0000-0000-0000-0000000000a3', array['motoboy','supervisor']) ->> 'ok';
reset role;
\echo == reabrir
set role authenticated;
select set_config('request.uid','00000000-0000-0000-0000-0000000000a1',false) \g /dev/null
update pedidos set status='cancelado', cancelado_em=now() where id='00000000-0000-0000-0000-0000000000c8';
reset role;
update pedidos set status='cancelado', cancelado_em=now() where id='00000000-0000-0000-0000-0000000000c8';
update corridas set status='cancelada', cancelada_em=now() where id='00000000-0000-0000-0000-0000000000fa';
set role authenticated;
select public.revisar_pedido('00000000-0000-0000-0000-0000000000c8', 'voltar_revisao') ->> 'status';
select public.reabrir_corrida('00000000-0000-0000-0000-0000000000fa');
select status from corridas where id='00000000-0000-0000-0000-0000000000fa';
reset role;
