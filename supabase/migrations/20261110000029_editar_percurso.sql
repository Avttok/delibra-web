-- =====================================================================
-- Delibra · 0029: editar percurso
--
-- O gestor arrasta o caminho da rota para as ruas que quer (pontos "passar por") e salva o
-- traçado. Fica em corridas.rota_planejada (o que o motoboy e o mapa mostram), com a
-- distância nova, e os pontos em percurso_via para reabrir a edição depois.
-- =====================================================================
alter table public.corridas add column if not exists percurso_via jsonb;

create or replace function public.definir_percurso_rota(p_corrida uuid, p_polyline text, p_distancia_m numeric default null,
                                                       p_duracao_s numeric default null, p_via jsonb default null)
returns void language plpgsql security definer set search_path = '' as $$
declare c public.corridas%rowtype;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if not public.ve_corrida(p_corrida) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  select * into c from public.corridas where id = p_corrida;
  if c.id is null then raise exception 'rota_nao_encontrada' using errcode = '22023'; end if;
  if c.status in ('concluida', 'cancelada') then raise exception 'rota_encerrada' using errcode = '22023'; end if;
  if p_polyline is null or length(p_polyline) < 4 then raise exception 'percurso_invalido' using errcode = '22023'; end if;
  update public.corridas set
    rota_planejada = p_polyline,
    distancia_planejada_m = coalesce(round(p_distancia_m)::int, distancia_planejada_m),
    duracao_planejada_s = coalesce(round(p_duracao_s)::int, duracao_planejada_s),
    percurso_via = case when jsonb_typeof(p_via) = 'array' and jsonb_array_length(p_via) > 0 then p_via end,
    otimizada_em = now()
  where id = p_corrida;
end;
$$;
grant execute on function public.definir_percurso_rota(uuid, text, numeric, numeric, jsonb) to authenticated;

notify pgrst, 'reload schema';

-- pontos de passagem salvos (para reabrir a edição)
create or replace function public.corrida_percurso_via(p_corrida uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce((select percurso_via from public.corridas where id = p_corrida and public.is_gestor() and public.ve_corrida(p_corrida)), '[]'::jsonb);
$$;
grant execute on function public.corrida_percurso_via(uuid) to authenticated;
notify pgrst, 'reload schema';
