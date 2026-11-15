\i t77.sql
\echo ===== CHEGOU
insert into corridas(id,status,teste,valor,valor_base,origem,organizacao_id,motoboy_id,aceita_em) values ('00000000-0000-0000-0000-0000000000fa','aceita',false,10,10,'manual',:'oa','00000000-0000-0000-0000-0000000000b3',now());
update perfis set organizacao_id=:'oa' where id='00000000-0000-0000-0000-0000000000b3';
insert into paradas(id,corrida_id,ordem,tipo,lat,lng,endereco) values ('00000000-0000-0000-0000-0000000000a9','00000000-0000-0000-0000-0000000000fa',0,'coleta',-26.9,-49.1,'X'),('00000000-0000-0000-0000-0000000000aa','00000000-0000-0000-0000-0000000000fa',1,'entrega',-26.91,-49.1,'Y');
set role authenticated;
select set_config('request.uid','00000000-0000-0000-0000-0000000000b3',false) \g /dev/null
select public.avancar_parada('00000000-0000-0000-0000-0000000000a9','chegou','{"lat":-26.9,"lng":-49.1,"precisao_m":5}') is not null chegou;
select public.avancar_parada('00000000-0000-0000-0000-0000000000a9','concluir','{"lat":-26.9,"lng":-49.1,"precisao_m":5}') is not null concluiu;
