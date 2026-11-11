-- =====================================================================
-- Delibra · 0032: push que chega de verdade
--
-- O banco assina cada push com privado.config.push_secret (gerado na criação do banco) e o
-- site só aceitava se fosse igual ao PUSH_SECRET da Vercel, que foi criado à mão: os dois não
-- batiam e nenhum aviso chegava ao celular (nem acordava a tela). Agora o site também aceita
-- o segredo do banco, conferido aqui (só o servidor, com a chave secreta, pode perguntar).
-- Mais: o Dev testa o push no próprio celular e vê as últimas respostas.
-- =====================================================================
create or replace function public.push_secret_confere(p text)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(p, '') <> '' and p = (select valor from privado.config where chave = 'push_secret');
$$;
revoke execute on function public.push_secret_confere(text) from public, anon, authenticated;
do $$ begin execute 'grant execute on function public.push_secret_confere(text) to service_role'; exception when undefined_object then null; end $$;

-- Dev: manda um aviso de teste para o próprio celular
create or replace function public.dev_testar_push()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_tem boolean;
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  select exists (select 1 from privado.fcm_tokens where motoboy_id = auth.uid()) into v_tem;
  if not v_tem then return jsonb_build_object('ok', false, 'motivo', 'sem_token'); end if;
  perform privado.enviar_push(auth.uid(), jsonb_build_object('tipo', 'teste', 'titulo', 'Teste de aviso', 'texto', 'Se você está lendo isto, o push está funcionando.'));
  return jsonb_build_object('ok', true);
end;
$$;
revoke execute on function public.dev_testar_push() from public, anon;
grant execute on function public.dev_testar_push() to authenticated;

-- Dev: últimas respostas do envio de push (status e erro), para saber onde travou
create or replace function public.dev_push_diagnostico()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r jsonb;
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  begin
    execute $q$select coalesce(jsonb_agg(jsonb_build_object('quando', created, 'status', status_code, 'erro', error_msg, 'corpo', left(content::text, 300)) order by id desc), '[]')
               from (select * from net._http_response order by id desc limit 10) x$q$ into r;
  exception when others then r := jsonb_build_array(jsonb_build_object('erro', sqlerrm));
  end;
  return jsonb_build_object(
    'tem_token', exists (select 1 from privado.fcm_tokens where motoboy_id = auth.uid()),
    'tem_url', exists (select 1 from privado.config where chave = 'push_url'),
    'url', (select valor from privado.config where chave = 'push_url'),
    'respostas', r);
end;
$$;
revoke execute on function public.dev_push_diagnostico() from public, anon;
grant execute on function public.dev_push_diagnostico() to authenticated;

notify pgrst, 'reload schema';
