-- Lote 50 · novidades pelo app do Dev (o site grava direto na tabela; o app usa estas funções)
create or replace function public.dev_novidades()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(to_jsonb(n) order by n.criado_em desc) from public.novidades n), '[]');
end;
$$;
create or replace function public.dev_salvar_novidade(p jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid := nullif(p ->> 'id', '')::uuid;
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  if coalesce(trim(p ->> 'titulo'), '') = '' or coalesce(trim(p ->> 'versao'), '') = '' then raise exception 'titulo_obrigatorio' using errcode = '22023'; end if;
  if v is null then
    insert into public.novidades (versao, area, plataforma, titulo, texto, publicado, criado_por)
    values (trim(p ->> 'versao'), coalesce(nullif(p ->> 'area', ''), 'todos'), coalesce(nullif(p ->> 'plataforma', ''), 'todas'), trim(p ->> 'titulo'),
            nullif(p ->> 'texto', ''), coalesce((p ->> 'publicado')::boolean, true), auth.uid())
    returning id into v;
  else
    update public.novidades set versao = trim(p ->> 'versao'), area = coalesce(nullif(p ->> 'area', ''), 'todos'), plataforma = coalesce(nullif(p ->> 'plataforma', ''), 'todas'),
      titulo = trim(p ->> 'titulo'), texto = nullif(p ->> 'texto', ''), publicado = coalesce((p ->> 'publicado')::boolean, true)
     where id = v;
  end if;
  perform privado.anotar_dev('novidades', 'salvar', v::text, p);
  return v;
end;
$$;
create or replace function public.dev_apagar_novidade(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  delete from public.novidades where id = p_id;
  perform privado.anotar_dev('novidades', 'apagar', p_id::text);
end;
$$;
revoke execute on function public.dev_novidades(), public.dev_salvar_novidade(jsonb), public.dev_apagar_novidade(uuid) from anon;
