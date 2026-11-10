-- PW Express 0018: a oferta diz se é extensão da rota atual (o app mostra diferente).

create or replace function public.oferta_pendente()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare o public.ofertas%rowtype; v jsonb;
begin
  perform privado.checar_versao_app();
  select * into o from public.ofertas where motoboy_id = auth.uid() and status = 'pendente' and expira_em > now() order by criada_em desc limit 1;
  if not found then return null; end if;
  v := privado.corrida_json(o.corrida_id);
  return jsonb_build_object('oferta_id', o.id, 'expira_em', o.expira_em,
    'segundos_restantes', greatest(0, extract(epoch from (o.expira_em - now())))::int, 'distancia_m', o.distancia_m, 'corrida', v,
    -- extensão: as paradas entram no fim da rota que o motoboy já está fazendo
    'extensao', o.extensao,
    'rota_atual', case when o.extensao then (select jsonb_build_object('id', a.id, 'numero', a.numero,
                         'paradas_restantes', (select count(*) from public.paradas p where p.corrida_id = a.id and p.status::text <> 'concluida'))
                         from public.corridas a where a.motoboy_id = auth.uid() and a.status::text in ('aceita', 'em_andamento') order by a.aceita_em desc nulls last limit 1) end);
end;
$$;
