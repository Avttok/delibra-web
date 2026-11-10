-- =====================================================================
-- Delibra · 0023: "Revisar rota" antes de aprovar
-- Na prévia das rotas do pedido o gestor escolhe como o motoboy vai ser pago (modelo e
-- parâmetros), valendo para quem pegar, por cima do cadastro do motoboy. Fica guardado no
-- pedido e passa para a rota quando ela nasce (inclusive na prévia, que já mostra o valor).
-- =====================================================================
alter table public.pedidos add column if not exists regras_rota jsonb not null default '{}';

create or replace function public.definir_regras_rota_pedido(p_pedido uuid, p_regras jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p public.pedidos%rowtype; v jsonb := coalesce(privado.limpar_regras(p_regras), '{}');
begin
  if not public.is_gestor() or not public.pode('pedidos') then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select * into p from public.pedidos where id = p_pedido for update;
  if not found then raise exception 'pedido_nao_encontrado' using errcode = '22023'; end if;
  update public.pedidos set regras_rota = v where id = p_pedido;
  perform privado.evento_pedido(p_pedido, 'regras_rota', jsonb_build_object('regras', v));
  insert into public.decisoes_rota (por, acao, pedido_id, empresa_id, tipo_pedido, dados)
  values (auth.uid(), 'regras', p_pedido, p.empresa_id, p.tipo_pedido, jsonb_build_object('regras', v, 'antes_de_aprovar', true));
  -- rotas que já existem e ainda não têm regras próprias recebem estas
  update public.corridas c set pag_regras = v
   where c.id in (select x.corrida_id from public.paradas x where x.pedido_id = p_pedido)
     and c.status::text in ('montada', 'agendada', 'aguardando_motoboy', 'sem_motoboy')
     and coalesce(c.pag_regras, '{}') = coalesce(p.regras_rota, '{}');
  return v;
end;
$$;
grant execute on function public.definir_regras_rota_pedido(uuid, jsonb) to authenticated;

-- a parada do pedido entrou numa rota: a rota herda as regras de pagamento do pedido (se ainda não tem)
create or replace function privado.herdar_regras_rota()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v jsonb;
begin
  if new.pedido_id is null then return new; end if;
  select regras_rota into v from public.pedidos where id = new.pedido_id;
  if v is null or v = '{}'::jsonb then return new; end if;
  update public.corridas set pag_regras = v where id = new.corrida_id and coalesce(pag_regras, '{}') = '{}';
  return new;
end;
$$;
drop trigger if exists herdar_regras_rota on public.paradas;
create trigger herdar_regras_rota after insert or update of corrida_id on public.paradas for each row execute function privado.herdar_regras_rota();
revoke execute on function privado.herdar_regras_rota() from public, anon, authenticated;
