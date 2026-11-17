-- 0049 · Ficha da rota do motoboy: o que ele fez em cada rota, sem dado do cliente que ele não vê
create or replace function public.minha_ficha_rota(p_corrida uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare c public.corridas%rowtype; v_valores boolean := privado.ve_valores(auth.uid());
begin
  select * into c from public.corridas where id = p_corrida;
  if c.id is null or c.motoboy_id is distinct from auth.uid() then raise exception 'corrida_nao_e_sua' using errcode = '42501'; end if;
  return jsonb_build_object(
    'id', c.id, 'numero', c.numero, 'teste', c.teste, 'status', c.status, 'tipo_pedido', c.tipo_pedido,
    'criada_em', c.criada_em, 'aceita_em', c.aceita_em, 'concluida_em', c.concluida_em, 'cancelada_em', c.cancelada_em,
    'distancia_m', coalesce(c.distancia_real_m, c.distancia_planejada_m), 'rota_planejada', c.rota_planejada,
    'cliente', coalesce((select e.nome from public.empresas e where e.id = c.empresa_id), c.cliente_nome),
    'valor', case when v_valores then c.valor_motoboy end,
    'calculo', case when v_valores then c.pag_calculo end,
    'ajuste', case when v_valores and c.pag_ajuste_mostrar then c.pag_ajuste end,
    'ajuste_motivo', case when v_valores and c.pag_ajuste_mostrar then c.pag_ajuste_motivo end,
    'paradas', (select coalesce(jsonb_agg(jsonb_build_object('ordem', x.ordem, 'tipo', x.tipo, 'endereco', x.endereco, 'lat', x.lat, 'lng', x.lng, 'status', x.status,
                   'chegou_em', x.chegou_em, 'concluida_em', x.concluida_em, 'recebedor_nome', x.recebedor_nome, 'local_ignorado', x.local_ignorado,
                   'feita_offline', x.feita_offline, 'liberada_local', x.liberada_local, 'tem_foto', x.foto_path is not null, 'tem_assinatura', x.assinatura_path is not null,
                   'pedido_numero', (select pd.numero from public.pedidos pd where pd.id = x.pedido_id)) order by x.ordem), '[]')
                 from public.paradas x where x.corrida_id = c.id),
    'chamados', (select coalesce(jsonb_agg(jsonb_build_object('tipo', h.tipo, 'status', h.status, 'motivo', h.motivo, 'resposta', h.resposta, 'criado_em', h.criado_em) order by h.criado_em), '[]')
                  from public.chamados_corrida h where h.corrida_id = c.id and h.motoboy_id = auth.uid()),
    'avaliacoes', (select coalesce(jsonb_agg(jsonb_build_object('nota', a.nota, 'comentario', a.comentario)), '[]')
                     from public.avaliacoes a where a.corrida_id = c.id and privado.cfg_bool('motoboy_ve_notas', true)));
end;
$$;
grant execute on function public.minha_ficha_rota(uuid) to authenticated;
