-- Lote 46 (0047): fuso por empresa, ofertas resistentes, campos na chegada. Cada linha diz OK ou FALHA
\i t81.sql
\set QUIET on
\pset tuples_only on
\set ON_ERROR_STOP off
reset role;
select set_config('request.jwt.claims','',false) \g /dev/null
select set_config('request.uid','00000000-0000-0000-0000-0000000000a1',false) \g /dev/null
select case when privado.fuso() = 'America/Sao_Paulo' then 'OK fuso padrão é São Paulo' else 'FALHA fuso padrão: ' || privado.fuso() end;
reset role;
insert into public.politicas (escopo, alvo, chave, valor) values ('organizacao', public.minha_org()::text, 'fuso_horario', '"America/Manaus"');
select set_config('request.uid','00000000-0000-0000-0000-0000000000a1',false) \g /dev/null
select case when privado.fuso() = 'America/Manaus' then 'OK empresa escolhe o fuso' else 'FALHA fuso da empresa: ' || privado.fuso() end;
select set_config('request.uid','00000000-0000-0000-0000-0000000000b1',false) \g /dev/null
select case when privado.fuso() = 'America/Sao_Paulo' then 'OK fuso de uma empresa não vaza para outra' else 'FALHA fuso vazou: ' || privado.fuso() end;
set role authenticated;
select set_config('request.uid','00000000-0000-0000-0000-0000000000a1',false) \g /dev/null
do $$ begin perform public.painel_do_dia(); perform public.meus_ganhos(); raise notice 'OK painel e ganhos com o fuso da empresa';
exception when others then raise notice 'FALHA painel com fuso: %', sqlerrm; end $$;
reset role;
select case when privado.fuso_valido('Europe/Paris') = 'America/Sao_Paulo' then 'OK fuso fora da lista volta para São Paulo' else 'FALHA fuso inválido aceito' end;
-- ofertas vencidas: uma rota com erro não derruba as outras
begin;
create or replace function privado.despachar(p_corrida uuid) returns void language plpgsql as $f$
begin if p_corrida = '00000000-0000-0000-0000-0000000000f8' then raise exception 'falha_de_teste'; end if; end $f$;
update public.ofertas set status = 'expirada' where status = 'pendente';
insert into public.ofertas (corrida_id, motoboy_id, rodada, distancia_m, expira_em)
select c.id, '00000000-0000-0000-0000-0000000000a3', 99, 100, now() - interval '1 minute' from (select id from public.corridas order by (id = '00000000-0000-0000-0000-0000000000f8') desc, criada_em limit 2) c;
select privado.expirar_ofertas();
select case when (select count(*) from public.ofertas where rodada = 99 and status = 'expirada') = 2 then 'OK as duas ofertas venceram mesmo com erro numa' else 'FALHA ofertas: ' || (select string_agg(status::text, ',') from public.ofertas where rodada = 99) end;
select case when exists (select 1 from public.erros_app where versao = 'servidor' and tela = 'expirar_ofertas' and mensagem like '%falha_de_teste%') then 'OK erro foi para a Saúde do sistema' else 'FALHA erro não registrado' end;
rollback;
-- campo pedido na chegada
set role authenticated;
select set_config('request.uid','00000000-0000-0000-0000-0000000000a1',false) \g /dev/null
select public.salvar_campo('{"entidade":"ponto","ponto_tipo":"coleta","rotulo":"Lacre","tipo":"texto","quem_preenche":"motoboy","etapa":"chegou"}') is not null as x \gset
select case when exists (select 1 from jsonb_array_elements(public.meu_perfil() -> 'campos') c where c ->> 'chave' = 'lacre' and c ->> 'etapa' = 'chegou') then 'OK campo perguntado na chegada' else 'FALHA etapa do campo' end;
