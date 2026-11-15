\i t60.sql
\set QUIET on
\set ON_ERROR_STOP off
insert into auth.users(id,email) values ('00000000-0000-0000-0000-0000000000c1','cli@x') on conflict do nothing;
update perfis set organizacao_id=:'oa', papeis='{cliente}', nome='Cli A', empresa_id='00000000-0000-0000-0000-0000000000e1' where id='00000000-0000-0000-0000-0000000000c1';
insert into pedidos(id, origem, tipo, status, organizacao_id, valor, empresa_id) values ('00000000-0000-0000-0000-0000000000c8','gestor','express','roteirizado',:'oa',10,'00000000-0000-0000-0000-0000000000e1');
insert into pedido_pontos(id, pedido_id, ordem, tipo, endereco, lat, lng) values
 ('00000000-0000-0000-0000-000000000081','00000000-0000-0000-0000-0000000000c8',0,'coleta','Col, Centro',-26.9,-49.1),
 ('00000000-0000-0000-0000-000000000082','00000000-0000-0000-0000-0000000000c8',1,'entrega','Rua 1, Velha',-26.92,-49.08);
insert into corridas(id,status,teste,valor,valor_base,origem,organizacao_id,motoboy_id,aceita_em,empresa_id) values ('00000000-0000-0000-0000-0000000000f8','aceita',false,100,100,'manual',:'oa','00000000-0000-0000-0000-0000000000a3',now(),'00000000-0000-0000-0000-0000000000e1');
insert into paradas(id,corrida_id, ordem, tipo, lat, lng, endereco, pedido_id, pedido_ponto_id) values
 ('00000000-0000-0000-0000-000000000091','00000000-0000-0000-0000-0000000000f8',0,'coleta',-26.9,-49.1,'Col, Centro','00000000-0000-0000-0000-0000000000c8','00000000-0000-0000-0000-000000000081');
insert into paradas(id,corrida_id, ordem, tipo, lat, lng, endereco, pedido_id, pedido_ponto_id) values
 ('00000000-0000-0000-0000-000000000092','00000000-0000-0000-0000-0000000000f8',1,'entrega',-26.92,-49.08,'Rua 1, Velha','00000000-0000-0000-0000-0000000000c8','00000000-0000-0000-0000-000000000082');
update motoboys set status='em_corrida', lat=-27.5, lng=-48.5, posicao_em=now() where id='00000000-0000-0000-0000-0000000000a3';
set role authenticated;
\echo == 1. meu_perfil tem chaves novas
select set_config('request.uid','00000000-0000-0000-0000-0000000000a3',false) \g /dev/null
select x ? 'tema' tema, x->'config' ? 'dev_site_url' site, (x->'config'->>'motoboy_pode_pular') pular from public.meu_perfil() x;
\echo == 2. longe: erro; pedir pular; pedir de novo: erro
select public.avancar_parada('00000000-0000-0000-0000-000000000091','chegou','{"lat":-27.5,"lng":-48.5}') is not null;
select public.pedir_pular_parada('00000000-0000-0000-0000-000000000091','portao fechado') ->> 'tipo' tipo;
select public.pedir_pular_parada('00000000-0000-0000-0000-000000000091','de novo');
select public.meu_pedido_pular('00000000-0000-0000-0000-0000000000f8') ->> 'status' st;
\echo == 3. gestor aprova com penalidade -> libera; motoboy conclui longe
select set_config('request.uid','00000000-0000-0000-0000-0000000000a1',false) \g /dev/null
select public.responder_chamado((select id from chamados_corrida where tipo='pular' limit 1), true, 'ok', true) ->> 'status';
select set_config('request.uid','00000000-0000-0000-0000-0000000000a3',false) \g /dev/null
select public.avancar_parada('00000000-0000-0000-0000-000000000091','concluir','{"lat":-27.5,"lng":-48.5,"offline":"true","feito_em":"2020-01-01"}') ->> 'status' st;
reset role;
select ordem, status, liberada_local, feita_offline, local_ignorado from paradas where corrida_id='00000000-0000-0000-0000-0000000000f8' order by ordem;
select tipo, pontos from penalidades;
\echo == 4. emergencia
set role authenticated;
select set_config('request.uid','00000000-0000-0000-0000-0000000000a3',false) \g /dev/null
select public.acionar_emergencia(-27.5,-48.5,10) ? 'id' ok;
select set_config('request.uid','00000000-0000-0000-0000-0000000000a1',false) \g /dev/null
select jsonb_array_length(public.emergencias_abertas()) n;
select public.resolver_emergencia((select id from emergencias limit 1), 'tudo bem');
select set_config('request.uid','00000000-0000-0000-0000-0000000000b1',false) \g /dev/null
select jsonb_array_length(public.emergencias_abertas()) outra_org;
reset role;
\echo == 5. fechar sem noticia (ultimo ping 2h atras)
update motoboys set lat=-26.93, lng=-49.08, posicao_em=now()-interval '2 hours' where id='00000000-0000-0000-0000-0000000000a3';
select privado.fechar_sem_noticia() fechadas;
select status, aguardando_confirmacao from corridas where id='00000000-0000-0000-0000-0000000000f8';
select ordem, status, confirmacao_pendente from paradas where corrida_id='00000000-0000-0000-0000-0000000000f8' order by ordem;
\echo == 6. etapa offline chega depois
set role authenticated;
select set_config('request.uid','00000000-0000-0000-0000-0000000000a3',false) \g /dev/null
select public.avancar_parada('00000000-0000-0000-0000-000000000092','concluir',jsonb_build_object('recebedor_nome','Joao','feito_em',(now()-interval '10 minutes')::text)) is not null;
reset role;
select aguardando_confirmacao from corridas where id='00000000-0000-0000-0000-0000000000f8';
select recebedor_nome, feita_offline, confirmacao_pendente from paradas where id='00000000-0000-0000-0000-000000000092';
\echo == 7. moedas da corrida; jogo
select moedas from jogo_perfis where motoboy_id='00000000-0000-0000-0000-0000000000a3';
set role authenticated;
select set_config('request.uid','00000000-0000-0000-0000-0000000000a3',false) \g /dev/null
select x->>'moedas' moedas, x->>'level' lvl, jsonb_array_length(x->'loja') loja from public.jogo_meu() x;
select public.jogo_registrar_partida(1200, 30, 500) ->> 'moedas';
select public.jogo_comprar('moto_noite');
select public.jogo_comprar('poder_ima') ->> 'moedas';
select public.jogo_comprar('moto_ouro');
select public.jogo_registrar_partida(300, 0, 10, '{poder_ima}') -> 'itens';
select public.jogo_equipar('moto_rubi');
select x->0->>'pontos' p, x->0->>'eu' eu from public.jogo_ranking('empresa','mes') x;
select jsonb_array_length(public.jogo_ranking('global','sempre'));
\echo == 8. avaliacao 1 estrela do cliente -> penalidade
select set_config('request.uid','00000000-0000-0000-0000-0000000000c1',false) \g /dev/null
select public.avaliar_pedido('00000000-0000-0000-0000-0000000000c8', 1, 'atrasou') ? 'id';
select public.avaliar_pedido('00000000-0000-0000-0000-0000000000c8', 5);
select public.nota_motoboy('00000000-0000-0000-0000-0000000000a3') nota_cliente;
select set_config('request.uid','00000000-0000-0000-0000-0000000000a1',false) \g /dev/null
select public.nota_motoboy('00000000-0000-0000-0000-0000000000a3') nota_gestor;
reset role;
select tipo, pontos from penalidades order by criado_em;
\echo == 9. rastreio
set role authenticated;
select set_config('request.uid','00000000-0000-0000-0000-0000000000c1',false) \g /dev/null
select public.gerar_rastreio('00000000-0000-0000-0000-0000000000c8') ->> 'token' as tok \gset
select set_config('request.uid','00000000-0000-0000-0000-0000000000b1',false) \g /dev/null
select public.gerar_rastreio('00000000-0000-0000-0000-0000000000c8');
reset role;
set role anon;
select set_config('request.uid','',false) \g /dev/null
select x->>'status' st, x->'marca'->>'nome' marca, jsonb_array_length(x->'pontos') pts, x->>'pode_avaliar' av from public.rastreio_publico(:'tok') x;
select public.rastreio_publico('xx');
reset role;
\echo == 10. tema e auditoria
set role authenticated;
select set_config('request.uid','00000000-0000-0000-0000-0000000000a1',false) \g /dev/null
select public.salvar_meu_tema('{"preferencia":"escuro","hack":"x","numero_barra":false}');
reset role;
update pedidos set valor=11 where id='00000000-0000-0000-0000-0000000000c8';
set role authenticated;
select jsonb_array_length(public.auditoria_lista()) > 0 tem, public.auditoria_lista() -> 0 ->> 'tabela' tab;
select set_config('request.uid','00000000-0000-0000-0000-0000000000a3',false) \g /dev/null
select public.auditoria_lista();
reset role;
