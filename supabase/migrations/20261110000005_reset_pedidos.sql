-- =====================================================================
-- Dev: zerar os pedidos (teste, reais ou ambos) e recomeçar a numeração do #1.
-- Apaga os pedidos do alvo, as rotas ligadas a eles e as faturas que ficarem vazias.
-- As rotas apagadas ficam copiadas em registro_exclusoes. Rode depois de 20261110000004.
-- =====================================================================
create or replace function public.resetar_pedidos(p_alvo text, p_confirmar text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_testes boolean[];
  v_corr   uuid[];
  v_fat    uuid[];
  v_ped    int;
  v_rot    int;
  v_fts    int;
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  if p_confirmar is distinct from 'ZERAR' then raise exception 'confirmacao_invalida' using errcode = '22023'; end if;
  v_testes := case p_alvo when 'teste' then array[true] when 'reais' then array[false] when 'ambos' then array[true, false] end;
  if v_testes is null then raise exception 'alvo_invalido' using errcode = '22023'; end if;
  perform pg_advisory_xact_lock(hashtext('pwex_roteirizar_true'));
  perform pg_advisory_xact_lock(hashtext('pwex_roteirizar_false'));

  -- rotas que levam pedidos do alvo (ou montadas pelo roteirizador no mesmo modo)
  select coalesce(array_agg(distinct c.id), '{}') into v_corr
    from public.corridas c
   where c.teste = any (v_testes)
     and (c.origem = 'roteirizador'
          or exists (select 1 from public.paradas x join public.pedidos p on p.id = x.pedido_id where x.corrida_id = c.id));
  select coalesce(array_agg(distinct p.fatura_id) filter (where p.fatura_id is not null), '{}') into v_fat
    from public.pedidos p where p.teste = any (v_testes);

  -- motoboys que estavam nessas rotas voltam a ficar disponíveis
  update public.motoboys m set status = 'disponivel', status_em = now()
   where m.status = 'em_corrida' and exists (select 1 from public.corridas c where c.id = any (v_corr) and c.motoboy_id = m.id);

  insert into public.registro_exclusoes (corrida_id, numero, teste, status, valor, copia, motivo, excluida_por)
  select c.id, c.numero, c.teste, c.status::text, c.valor, to_jsonb(c), 'reset dos pedidos (' || p_alvo || ')', auth.uid()
    from public.corridas c where c.id = any (v_corr);
  delete from public.corridas where id = any (v_corr);
  get diagnostics v_rot = row_count;

  delete from public.pedidos where teste = any (v_testes);
  get diagnostics v_ped = row_count;

  delete from public.faturas f where f.id = any (v_fat) and not exists (select 1 from public.pedidos p where p.fatura_id = f.id);
  get diagnostics v_fts = row_count;

  return jsonb_build_object('pedidos', v_ped, 'rotas', v_rot, 'faturas', v_fts);
end;
$$;
revoke all on function public.resetar_pedidos(text, text) from public, anon;
grant execute on function public.resetar_pedidos(text, text) to authenticated;
