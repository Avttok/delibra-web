-- =====================================================================
-- Pedido cancelado/recusado que tira uma rota reservada: o motoboy recebe o aviso de cancelamento.
-- Rode depois de 20261110000009.
-- =====================================================================
create or replace function privado.tirar_das_rotas(p_pedido uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare r uuid; v_moto uuid;
begin
  for r in select distinct x.corrida_id from public.paradas x join public.corridas c on c.id = x.corrida_id
            where x.pedido_id = p_pedido and c.status::text in ('montada', 'agendada', 'reservada', 'aguardando_motoboy', 'sem_motoboy') loop
    update public.ofertas set status = 'cancelada' where corrida_id = r and status = 'pendente';
    delete from public.paradas where corrida_id = r and pedido_id = p_pedido;
    if not exists (select 1 from public.paradas where corrida_id = r and tipo = 'entrega') then
      update public.corridas set status = 'cancelada', cancelada_em = now() where id = r returning motoboy_id into v_moto;
      perform privado.evento(r, 'cancelada', jsonb_build_object('motivo', 'pedidos retirados'));
      -- reservada: avisa o motoboy que a reserva caiu
      if v_moto is not null then perform privado.enviar_push(v_moto, jsonb_build_object('tipo', 'cancelada', 'corrida_id', r::text)); end if;
    else
      perform privado.ordenar_rota(r);
      perform privado.valores_rota(r);
    end if;
  end loop;
end;
$$;
