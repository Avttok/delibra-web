\set QUIET on
insert into auth.users(id,email) values
 ('00000000-0000-0000-0000-0000000000d1','dev@x'),
 ('00000000-0000-0000-0000-0000000000a1','ga@x'),('00000000-0000-0000-0000-0000000000a2','sa@x'),('00000000-0000-0000-0000-0000000000a3','ma@x'),
 ('00000000-0000-0000-0000-0000000000b1','gb@x'),('00000000-0000-0000-0000-0000000000b3','mb@x');
update public.perfis set papeis='{dev,gestor}', nome='Ruan' where id='00000000-0000-0000-0000-0000000000d1';
select set_config('request.uid','00000000-0000-0000-0000-0000000000d1',false) \g /dev/null
select public.dev_salvar_organizacao('{"nome":"PW Express","dono_id":"00000000-0000-0000-0000-0000000000a1"}') as oa \gset
select public.dev_salvar_organizacao('{"nome":"Outra Log","dono_id":"00000000-0000-0000-0000-0000000000b1"}') as ob \gset
update perfis set organizacao_id=:'oa', papeis='{supervisor}', nome='Sup A' where id='00000000-0000-0000-0000-0000000000a2';
update perfis set organizacao_id=:'oa', papeis='{motoboy}', nome='Moto A' where id='00000000-0000-0000-0000-0000000000a3';
update perfis set organizacao_id=:'ob', papeis='{motoboy}', nome='Moto B' where id='00000000-0000-0000-0000-0000000000b3';
insert into motoboys(id) values ('00000000-0000-0000-0000-0000000000a3'),('00000000-0000-0000-0000-0000000000b3') on conflict do nothing;
insert into empresas(id,nome,organizacao_id) values ('00000000-0000-0000-0000-0000000000e1','Cliente A',:'oa'),('00000000-0000-0000-0000-0000000000e2','Cliente B',:'ob');
\echo == licencas criadas
select count(*) from licencas;
\echo == gestor A ve so a empresa dele
set role authenticated;
select set_config('request.uid','00000000-0000-0000-0000-0000000000a1',false) \g /dev/null
select string_agg(nome, ',' order by nome) from empresas;
select string_agg(nome, ',' order by nome) from perfis;
select count(*) from organizacoes;
\echo == gestor A tenta ver cliente B (0)
select count(*) from empresas where id='00000000-0000-0000-0000-0000000000e2';
\echo == ajuste da empresa A nao muda B
select public.salvar_ajuste('oferta_segundos','99');
select public.ajustes()->>'oferta_segundos';
select set_config('request.uid','00000000-0000-0000-0000-0000000000b1',false) \g /dev/null
select public.ajustes()->>'oferta_segundos';
\echo == gestor B nao edita o Dev (erro esperado)
select public.pode_gerenciar('00000000-0000-0000-0000-0000000000d1');
reset role;
\echo == supervisor: pode pedidos sim, ajustes nao
set role authenticated;
select set_config('request.uid','00000000-0000-0000-0000-0000000000a2',false) \g /dev/null
select public.pode('pedidos'), public.pode('ajustes'), public.is_gestor(), public.is_gestor_pleno();
\echo == dev oculto
select set_config('request.uid','00000000-0000-0000-0000-0000000000d1',false) \g /dev/null
select public.dev_ocultar(true);
select set_config('request.uid','00000000-0000-0000-0000-0000000000a1',false) \g /dev/null
select public.nome_publico('00000000-0000-0000-0000-0000000000d1');
\echo == dev ve todos
select set_config('request.uid','00000000-0000-0000-0000-0000000000d1',false) \g /dev/null
select count(*) from empresas;
select public.dev_focar_org(:'oa');
select count(*) from empresas;
select public.dev_focar_org(null);
reset role;
\echo == alcance
select public.org_alcanca(:'oa', :'ob');
update organizacoes set compartilhar='sempre' where id=:'oa'; update organizacoes set receber_de_outras=true where id=:'ob';
select public.org_alcanca(:'oa', :'ob'), public.org_alcanca(:'ob', :'oa');
\echo == dev_pct por modelo
select privado.pol_num('dev_pct', 5, '00000000-0000-0000-0000-0000000000e1');
update organizacoes set cobranca_modelo='licenca', mensalidade=300 where id=:'oa';
select privado.pol_num('dev_pct', 5, '00000000-0000-0000-0000-0000000000e1'), privado.pol_num('dev_pct', 5, '00000000-0000-0000-0000-0000000000e2');
\echo == faturamento
select set_config('request.uid','00000000-0000-0000-0000-0000000000d1',false) \g /dev/null
select r->'totais', jsonb_array_length(r->'empresas') from public.dev_faturamento() r;
\echo == chat geral por empresa
select count(*) from chat_conversas where tipo='geral';
