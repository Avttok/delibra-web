-- =====================================================================
-- Delibra · 0034: avisos (push) também para o gestor
--
--  • Qualquer conta da equipe registra o celular para receber avisos (antes só motoboy:
--    quem era só gestor não recebia nem as mensagens do chat).
--  • Gestores e supervisores (com permissão de pedidos) da empresa recebem:
--      pedido_novo       → um cliente fez um pedido (para revisar ou já aprovado)
--      rota_sem_motoboy  → ninguém pegou a rota
--      cadastro_novo     → um cliente pediu cadastro
--    Cada um pode ser desligado em Ajustes (aviso_gestor_*).
-- =====================================================================

create or replace function public.registrar_fcm_token(p_token text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'sem_login' using errcode = '42501'; end if;
  if coalesce(trim(p_token), '') = '' then raise exception 'token_vazio' using errcode = '22023'; end if;
  if not exists (select 1 from public.perfis where id = auth.uid()
                  and papeis && array['motoboy', 'gestor', 'supervisor', 'dev']::public.papel_usuario[]) then
    raise exception 'sem_permissao' using errcode = '42501';
  end if;
  if public.tem_papel('motoboy'::public.papel_usuario) then
    insert into public.motoboys (id) values (auth.uid()) on conflict (id) do nothing;
  end if;
  -- o mesmo aparelho não pode ficar em duas contas
  delete from privado.fcm_tokens where token = p_token and motoboy_id <> auth.uid();
  insert into privado.fcm_tokens (motoboy_id, token) values (auth.uid(), p_token)
  on conflict (motoboy_id) do update set token = excluded.token, atualizado_em = now();
end;
$$;
revoke execute on function public.registrar_fcm_token(text) from public, anon;
grant execute on function public.registrar_fcm_token(text) to authenticated;

-- Ajuste da empresa (ou o global), sem depender de quem disparou.
create or replace function privado.cfg_org_bool(p_org uuid, p_chave text, p_padrao boolean)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select (valor #>> '{}')::boolean from public.politicas where escopo = 'organizacao' and alvo = p_org::text and chave = p_chave),
    (select (valor #>> '{}')::boolean from public.configuracoes where chave = p_chave),
    p_padrao);
$$;

-- Avisa os gestores (e supervisores com a permissão) de uma empresa. Nunca derruba quem chamou.
create or replace function privado.avisar_gestores(p_org uuid, p_dados jsonb, p_permissao text default 'pedidos')
returns void language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  if p_org is null then return; end if;
  for r in
    select p.id from public.perfis p
     where p.organizacao_id = p_org and p.id is distinct from auth.uid()
       and ('gestor' = any (p.papeis) or ('supervisor' = any (p.papeis) and coalesce((p.permissoes ->> p_permissao)::boolean, true)))
       and exists (select 1 from privado.fcm_tokens t where t.motoboy_id = p.id)
  loop
    begin
      perform privado.enviar_push(r.id, p_dados);
    exception when others then null;
    end;
  end loop;
exception when others then
  raise warning 'avisar_gestores falhou: %', sqlerrm;
end;
$$;
revoke execute on function privado.cfg_org_bool(uuid, text, boolean), privado.avisar_gestores(uuid, jsonb, text) from public, anon, authenticated;

-- pedido novo de cliente
create or replace function privado.aviso_pedido_novo()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_cli text; v_n int;
begin
  if new.origem <> 'cliente' or not privado.cfg_org_bool(new.organizacao_id, 'aviso_gestor_pedido', true) then return new; end if;
  select coalesce(e.nome, new.cliente_nome, 'Cliente') into v_cli from public.empresas e where e.id = new.empresa_id;
  v_cli := coalesce(v_cli, new.cliente_nome, 'Cliente');
  perform privado.avisar_gestores(new.organizacao_id, jsonb_build_object(
    'tipo', 'pedido_novo', 'pedido_id', new.id::text, 'teste', coalesce(new.teste, false)::text,
    'titulo', case when new.status = 'recebido' then 'Pedido para revisar' else 'Pedido novo' end,
    'texto', v_cli || ' · ' || case when new.tipo = 'planejado' then 'com hora marcada' else 'express' end));
  return new;
end;
$$;
drop trigger if exists aviso_pedido_novo on public.pedidos;
create trigger aviso_pedido_novo after insert on public.pedidos for each row execute function privado.aviso_pedido_novo();

-- rota sem motoboy (ninguém aceitou)
create or replace function privado.aviso_sem_motoboy()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status::text = 'sem_motoboy' and old.status::text is distinct from 'sem_motoboy'
     and privado.cfg_org_bool(new.organizacao_id, 'aviso_gestor_sem_motoboy', true) then
    perform privado.avisar_gestores(new.organizacao_id, jsonb_build_object(
      'tipo', 'rota_sem_motoboy', 'corrida_id', new.id::text, 'teste', coalesce(new.teste, false)::text,
      'titulo', 'Rota ' || case when new.teste then 'T' else '#' end || new.numero || ' sem motoboy',
      'texto', 'Ninguém pegou a rota. Ofereça de novo ou escolha um motoboy.'), 'corridas');
  end if;
  return new;
end;
$$;
drop trigger if exists aviso_sem_motoboy on public.corridas;
create trigger aviso_sem_motoboy after update of status on public.corridas for each row execute function privado.aviso_sem_motoboy();

-- cliente pediu cadastro
create or replace function privado.aviso_cadastro_novo()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if privado.cfg_org_bool(new.organizacao_id, 'aviso_gestor_cadastro', true) then
    perform privado.avisar_gestores(new.organizacao_id, jsonb_build_object(
      'tipo', 'cadastro_novo', 'cadastro_id', new.id::text,
      'titulo', 'Cadastro de cliente', 'texto', coalesce(new.nome, 'Um cliente') || ' quer pedir pela plataforma. Aprove ou recuse.'), 'clientes');
  end if;
  return new;
end;
$$;
drop trigger if exists aviso_cadastro_novo on public.cadastros_cliente;
create trigger aviso_cadastro_novo after insert on public.cadastros_cliente for each row execute function privado.aviso_cadastro_novo();

revoke execute on function privado.aviso_pedido_novo(), privado.aviso_sem_motoboy(), privado.aviso_cadastro_novo() from public, anon, authenticated;

notify pgrst, 'reload schema';
