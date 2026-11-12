-- =====================================================================
-- Delibra · 0041: cadastro do cliente escolhendo a empresa por cards (com a nota de cada uma)
-- =====================================================================
create or replace function public.empresas_cadastro()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'slug', o.slug, 'nome', coalesce(o.nome_app, o.nome), 'logo', o.logo_url, 'cor', o.cor,
           'modo', privado.cfg_org_txt(o.id, 'cadastro_cliente_modo', 'aprovacao'),
           'nota', (select round(avg(a.nota)::numeric, 1) from public.avaliacoes a where a.organizacao_id = o.id),
           'avaliacoes', (select count(*) from public.avaliacoes a where a.organizacao_id = o.id),
           'entregas', (select count(*) from public.corridas c where c.organizacao_id = o.id and c.status::text = 'concluida' and not c.teste)
         ) order by coalesce(o.nome_app, o.nome)), '[]'::jsonb)
    from public.organizacoes o
   where o.slug is not null and o.status in ('ativa', 'teste')
     and privado.cfg_org_txt(o.id, 'cadastro_cliente_modo', 'aprovacao') <> 'desligado';
$$;
grant execute on function public.empresas_cadastro() to anon, authenticated;
