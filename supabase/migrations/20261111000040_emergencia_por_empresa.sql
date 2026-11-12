-- =====================================================================
-- Delibra · 0040: o Dev escolhe de quais empresas recebe as emergências
-- =====================================================================
create or replace function public.dev_emergencia_orgs()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  return coalesce(privado.cfg('dev_emergencia_orgs', '[]'::jsonb), '[]'::jsonb);
end;
$$;

create or replace function public.dev_emergencia_receber_org(p_org uuid, p_ligar boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v jsonb;
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  v := coalesce((select valor from public.configuracoes where chave = 'dev_emergencia_orgs'), '[]'::jsonb) - p_org::text;
  if p_ligar then v := v || to_jsonb(p_org::text); end if;
  insert into public.configuracoes (chave, valor) values ('dev_emergencia_orgs', v) on conflict (chave) do update set valor = excluded.valor;
  return v;
end;
$$;
revoke execute on function public.dev_emergencia_orgs(), public.dev_emergencia_receber_org(uuid, boolean) from public, anon;
grant execute on function public.dev_emergencia_orgs(), public.dev_emergencia_receber_org(uuid, boolean) to authenticated;
