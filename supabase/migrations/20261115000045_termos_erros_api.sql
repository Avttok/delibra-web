-- 0045 · Termos e aceite · travamentos do app · API e webhooks para lojas virtuais
--  • aceites: quem aceitou os termos de uso e a política de privacidade, em qual versão (Dev muda a versão → todos aceitam de novo)
--  • erros_app: travamentos e erros do app, enviados pelo próprio app; resumo na Saúde do sistema
--  • api_chaves / api_webhooks: a loja (cliente da transportadora) cria e acompanha pedidos sozinha
--    e recebe o andamento no endereço dela (fila privado.avisos_externos, canal 'webhook')

-- pega as travas logo no começo (evita impasse com o app gravando pedidos ao mesmo tempo)
do $$ begin
  perform set_config('lock_timeout', '60s', true);
  lock table public.pedidos in access exclusive mode;
  lock table privado.avisos_externos in access exclusive mode;
end $$;

-- ===================================================================== termos e aceite
create table if not exists public.aceites (
  usuario_id uuid not null references auth.users (id) on delete cascade,
  documento  text not null check (documento in ('termos', 'privacidade')),
  versao     text not null,
  origem     text,
  aceito_em  timestamptz not null default now(),
  primary key (usuario_id, documento, versao)
);
alter table public.aceites enable row level security;
drop policy if exists aceites_ler on public.aceites;
create policy aceites_ler on public.aceites for select to authenticated using (usuario_id = (select auth.uid()) or (select public.is_dev()));

-- versão em vigor (Console Dev → Sistema → Versão dos termos)
create or replace function privado.termos_versao()
returns text language sql stable security definer set search_path = '' as $$
  select coalesce(nullif(privado.cfg_txt('termos_versao', '2026-11-15'), ''), '2026-11-15');
$$;

create or replace function public.termos_situacao()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('versao', privado.termos_versao(),
    'aceito', auth.uid() is null or (
      exists (select 1 from public.aceites a where a.usuario_id = auth.uid() and a.documento = 'termos' and a.versao = privado.termos_versao())
      and exists (select 1 from public.aceites a where a.usuario_id = auth.uid() and a.documento = 'privacidade' and a.versao = privado.termos_versao())));
$$;

create or replace function public.aceitar_termos(p_versao text, p_origem text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'nao_autenticado' using errcode = '42501'; end if;
  if p_versao is distinct from privado.termos_versao() then raise exception 'versao_mudou' using errcode = '22023'; end if;
  insert into public.aceites (usuario_id, documento, versao, origem)
  select auth.uid(), d, p_versao, left(coalesce(p_origem, ''), 40) from unnest(array['termos', 'privacidade']) d
  on conflict do nothing;
  return public.termos_situacao();
end;
$$;

revoke execute on function public.termos_situacao(), public.aceitar_termos(text, text) from public, anon;
grant execute on function public.termos_situacao(), public.aceitar_termos(text, text) to authenticated;

-- ===================================================================== travamentos do app
create table if not exists public.erros_app (
  id             bigint generated always as identity primary key,
  usuario_id     uuid,
  organizacao_id uuid,
  assinatura     text not null,
  tipo           text not null default 'travou' check (tipo in ('travou', 'erro')),
  versao         text,
  aparelho       text,
  android        text,
  tela           text,
  mensagem       text,
  pilha          text,
  quantas        int not null default 1,
  primeiro_em    timestamptz not null default now(),
  ultimo_em      timestamptz not null default now()
);
create index if not exists erros_app_ultimo_idx on public.erros_app (ultimo_em desc);
create index if not exists erros_app_assinatura_idx on public.erros_app (assinatura, versao, usuario_id);
alter table public.erros_app enable row level security;
drop policy if exists erros_app_dev on public.erros_app;
create policy erros_app_dev on public.erros_app for select to authenticated using ((select public.is_dev()));

-- o app manda um ou mais relatos (os guardados de quando travou); o mesmo erro no mesmo dia só soma
create or replace function public.registrar_erros_app(p_itens jsonb)
returns int language plpgsql security definer set search_path = '' as $$
declare
  i jsonb; n int := 0; v_ass text; v_id bigint;
  v_org uuid := case when auth.uid() is not null then public.minha_org() end;
begin
  if jsonb_typeof(p_itens) <> 'array' then return 0; end if;
  for i in select * from jsonb_array_elements(p_itens) limit 20 loop
    -- assinatura: tipo do erro + as primeiras linhas da pilha (sem números de linha que mudam por build)
    v_ass := md5(coalesce(i ->> 'tipo', 'travou') || '|' || left(regexp_replace(coalesce(i ->> 'pilha', i ->> 'mensagem', ''), ':[0-9]+\)', ')', 'g'), 1200));
    select id into v_id from public.erros_app
     where assinatura = v_ass and versao is not distinct from left(i ->> 'versao', 40) and usuario_id is not distinct from auth.uid()
       and ultimo_em > now() - interval '1 day' order by ultimo_em desc limit 1;
    if v_id is not null then
      update public.erros_app set quantas = quantas + greatest(1, least(coalesce((i ->> 'quantas')::int, 1), 1000)), ultimo_em = now() where id = v_id;
    else
      insert into public.erros_app (usuario_id, organizacao_id, assinatura, tipo, versao, aparelho, android, tela, mensagem, pilha, quantas, primeiro_em)
      values (auth.uid(), v_org, v_ass, case when i ->> 'tipo' = 'erro' then 'erro' else 'travou' end,
              left(i ->> 'versao', 40), left(i ->> 'aparelho', 80), left(i ->> 'android', 20), left(i ->> 'tela', 80),
              left(i ->> 'mensagem', 500), left(i ->> 'pilha', 8000), greatest(1, least(coalesce((i ->> 'quantas')::int, 1), 1000)),
              coalesce(least(nullif(i ->> 'quando', '')::timestamptz, now()), now()));
    end if;
    n := n + 1;
  end loop;
  -- guarda 30 dias
  if random() < 0.05 then delete from public.erros_app where ultimo_em < now() - interval '30 days'; end if;
  return n;
exception when others then return n;
end;
$$;
revoke execute on function public.registrar_erros_app(jsonb) from public;
grant execute on function public.registrar_erros_app(jsonb) to anon, authenticated;

-- resumo para a Saúde do sistema: os erros mais frequentes do período
create or replace function public.dev_erros_app(p_dias int default 7)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_desde timestamptz := now() - make_interval(days => greatest(1, least(coalesce(p_dias, 7), 30)));
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  return jsonb_build_object(
    'total', (select coalesce(sum(quantas), 0) from public.erros_app where ultimo_em >= v_desde and public.ve_org(organizacao_id)),
    'aparelhos', (select count(distinct usuario_id) from public.erros_app where ultimo_em >= v_desde and public.ve_org(organizacao_id)),
    'lista', (select coalesce(jsonb_agg(x order by x.quantas desc), '[]') from (
      select e.assinatura, e.tipo, max(e.mensagem) mensagem, max(e.tela) tela, sum(e.quantas)::int quantas, count(distinct e.usuario_id)::int pessoas,
             array_agg(distinct e.versao) filter (where e.versao is not null) versoes, max(e.ultimo_em) ultimo_em,
             (array_agg(e.pilha order by e.ultimo_em desc))[1] pilha,
             (array_agg(e.aparelho || coalesce(' · Android ' || e.android, '') order by e.ultimo_em desc))[1] aparelho
        from public.erros_app e where e.ultimo_em >= v_desde and public.ve_org(e.organizacao_id)
       group by e.assinatura, e.tipo order by sum(e.quantas) desc limit 30) x));
end;
$$;
revoke execute on function public.dev_erros_app(int) from public, anon;
grant execute on function public.dev_erros_app(int) to authenticated;

-- ===================================================================== API para lojas virtuais
alter table public.pedidos add column if not exists referencia_externa text;
alter table public.pedidos drop constraint if exists pedidos_origem_check;
alter table public.pedidos add constraint pedidos_origem_check check (origem in ('cliente', 'gestor', 'api'));
create index if not exists pedidos_ref_externa_idx on public.pedidos (empresa_id, referencia_externa) where referencia_externa is not null;

create table if not exists public.api_chaves (
  id             uuid primary key default gen_random_uuid(),
  organizacao_id uuid not null,
  empresa_id     uuid not null references public.empresas (id) on delete cascade,
  nome           text not null default 'Loja',
  prefixo        text not null,
  hash           text not null unique,
  criada_por     uuid,
  criada_em      timestamptz not null default now(),
  ultimo_uso     timestamptz,
  usos           bigint not null default 0,
  revogada_em    timestamptz
);
create index if not exists api_chaves_empresa_idx on public.api_chaves (empresa_id);
alter table public.api_chaves enable row level security;   -- só pelas funções abaixo

create table if not exists public.api_webhooks (
  id             uuid primary key default gen_random_uuid(),
  organizacao_id uuid not null,
  empresa_id     uuid not null unique references public.empresas (id) on delete cascade,
  url            text not null check (url ~ '^https://'),
  segredo        text not null,
  eventos        text[] not null default array['recebido', 'aprovado', 'em_rota', 'concluido', 'cancelado', 'recusado'],
  ativo          boolean not null default true,
  criado_em      timestamptz not null default now(),
  ultimo_envio   timestamptz,
  ultimo_status  text
);
alter table public.api_webhooks enable row level security;

alter table privado.avisos_externos drop constraint if exists avisos_externos_canal_check;
alter table privado.avisos_externos add constraint avisos_externos_canal_check check (canal in ('email', 'whatsapp', 'nota', 'cobranca', 'webhook'));

-- nova ação que o Dev pode tirar dos gestores
create or replace function privado.acoes_gestor()
returns text[] language sql immutable as $$
  select array['criar_contas', 'excluir_contas', 'editar_cargos', 'apagar_historico', 'exportar_dados', 'editar_valor_pedido',
               'editar_pagamento_motoboy', 'ajuste_holerite', 'fechar_holerite', 'emitir_fatura', 'cancelar_rota', 'voltar_revisao',
               'chat_apagar', 'mudar_marca', 'modo_teste', 'ver_carteira', 'regras_por_cliente', 'regras_por_motoboy', 'penalidades', 'forcar_inicio',
               'integracao_api'];
$$;

-- o gestor da transportadora mexe só nas lojas (clientes) dela, se o Dev liberou
create or replace function privado.api_exigir_gestor(p_empresa uuid)
returns uuid language plpgsql stable security definer set search_path = '' as $$
declare v_org uuid;
begin
  select organizacao_id into v_org from public.empresas where id = p_empresa;
  if v_org is null then raise exception 'empresa_inexistente' using errcode = '22023'; end if;
  if not (public.is_dev() or (public.is_gestor_pleno() and v_org = public.minha_org())) then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if not public.is_dev() and not privado.cfg_org_bool(v_org, 'api_lojas_liberada', true) then raise exception 'api_desligada' using errcode = '42501'; end if;
  perform privado.exigir_acao('integracao_api');
  return v_org;
end;
$$;

create or replace function public.api_da_empresa(p_empresa uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  perform privado.api_exigir_gestor(p_empresa);
  return jsonb_build_object(
    'chaves', (select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'nome', k.nome, 'prefixo', k.prefixo, 'criada_em', k.criada_em,
                 'ultimo_uso', k.ultimo_uso, 'usos', k.usos, 'revogada_em', k.revogada_em) order by k.criada_em desc), '[]')
               from public.api_chaves k where k.empresa_id = p_empresa),
    'webhook', (select jsonb_build_object('url', w.url, 'segredo', w.segredo, 'eventos', w.eventos, 'ativo', w.ativo,
                 'ultimo_envio', w.ultimo_envio, 'ultimo_status', w.ultimo_status) from public.api_webhooks w where w.empresa_id = p_empresa),
    'tem_acesso', exists (select 1 from public.perfis p where p.empresa_id = p_empresa and 'cliente' = any (p.papeis)));
end;
$$;

-- a chave inteira só aparece uma vez (guardamos só o resumo dela)
create or replace function public.api_criar_chave(p_empresa uuid, p_nome text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_org uuid := privado.api_exigir_gestor(p_empresa); v_chave text; v_id uuid;
begin
  if not exists (select 1 from public.perfis p where p.empresa_id = p_empresa and 'cliente' = any (p.papeis)) then
    raise exception 'empresa_sem_acesso' using errcode = '22023';
  end if;
  v_chave := 'dlb_' || replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  insert into public.api_chaves (organizacao_id, empresa_id, nome, prefixo, hash, criada_por)
  values (v_org, p_empresa, coalesce(nullif(left(trim(p_nome), 60), ''), 'Loja'), left(v_chave, 12), encode(sha256(convert_to(v_chave, 'UTF8')), 'hex'), auth.uid())
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'chave', v_chave);
end;
$$;

create or replace function public.api_revogar_chave(p_chave uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_emp uuid;
begin
  select empresa_id into v_emp from public.api_chaves where id = p_chave;
  if v_emp is null then raise exception 'chave_inexistente' using errcode = '22023'; end if;
  perform privado.api_exigir_gestor(v_emp);
  update public.api_chaves set revogada_em = coalesce(revogada_em, now()) where id = p_chave;
end;
$$;

create or replace function public.api_definir_webhook(p_empresa uuid, p_url text, p_eventos text[] default null, p_ativo boolean default true, p_novo_segredo boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_org uuid := privado.api_exigir_gestor(p_empresa);
  v_ev text[] := (select coalesce(array_agg(e), '{}') from unnest(coalesce(p_eventos, array['recebido', 'aprovado', 'em_rota', 'concluido', 'cancelado', 'recusado'])) e
                   where e in ('recebido', 'aprovado', 'roteirizado', 'em_rota', 'concluido', 'cancelado', 'recusado'));
  v_seg text := 'whsec_' || replace(gen_random_uuid()::text, '-', '');
begin
  if nullif(trim(coalesce(p_url, '')), '') is null then
    delete from public.api_webhooks where empresa_id = p_empresa;
    return public.api_da_empresa(p_empresa);
  end if;
  if trim(p_url) !~ '^https://[^/\s]+\.[^/\s]+' then raise exception 'url_invalida' using errcode = '22023'; end if;
  insert into public.api_webhooks (organizacao_id, empresa_id, url, segredo, eventos, ativo)
  values (v_org, p_empresa, trim(p_url), v_seg, v_ev, coalesce(p_ativo, true))
  on conflict (empresa_id) do update set url = excluded.url, eventos = excluded.eventos, ativo = excluded.ativo,
    segredo = case when p_novo_segredo then excluded.segredo else public.api_webhooks.segredo end;
  return public.api_da_empresa(p_empresa);
end;
$$;

revoke execute on function public.api_da_empresa(uuid), public.api_criar_chave(uuid, text), public.api_revogar_chave(uuid),
  public.api_definir_webhook(uuid, text, text[], boolean, boolean) from public, anon;
grant execute on function public.api_da_empresa(uuid), public.api_criar_chave(uuid, text), public.api_revogar_chave(uuid),
  public.api_definir_webhook(uuid, text, text[], boolean, boolean) to authenticated;

-- ---------------------------------------------------------------- lado da loja (só o servidor chama, com a chave conferida)
-- O pedido entra como se a própria loja tivesse pedido pelo site: valem todas as regras do cliente.
create or replace function privado.api_agir_como(p_hash text)
returns public.api_chaves language plpgsql security definer set search_path = '' as $$
declare k public.api_chaves%rowtype; v_usuario uuid;
begin
  select * into k from public.api_chaves where hash = p_hash and revogada_em is null;
  if k.id is null then raise exception 'chave_invalida' using errcode = '28000'; end if;
  if not privado.cfg_org_bool(k.organizacao_id, 'api_lojas_liberada', true) then raise exception 'api_desligada' using errcode = '42501'; end if;
  select p.id into v_usuario from public.perfis p
   where p.empresa_id = k.empresa_id and 'cliente' = any (p.papeis)
   order by p.criado_em limit 1;
  if v_usuario is null then raise exception 'empresa_sem_acesso' using errcode = '42501'; end if;
  perform set_config('request.jwt.claim.sub', v_usuario::text, true);
  perform set_config('request.jwt.claims', jsonb_build_object('sub', v_usuario, 'role', 'authenticated')::text, true);
  perform set_config('request.uid', v_usuario::text, true);   -- banco de teste local
  update public.api_chaves set ultimo_uso = now(), usos = usos + 1 where id = k.id;
  return k;
end;
$$;

create or replace function privado.api_pedido_json(p_pedido uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', p.id, 'numero', p.numero, 'status', p.status, 'referencia_externa', p.referencia_externa,
    'criado_em', p.criado_em, 'quando', p.quando, 'urgente', p.urgente, 'valor', p.valor, 'pagamento', p.pagamento_status, 'teste', p.teste,
    'pontos', (select coalesce(jsonb_agg(jsonb_build_object('ordem', pp.ordem, 'tipo', pp.tipo, 'endereco', pp.endereco, 'lat', pp.lat, 'lng', pp.lng,
                 'contato_nome', pp.contato_nome) order by pp.ordem), '[]') from public.pedido_pontos pp where pp.pedido_id = p.id))
  from public.pedidos p where p.id = p_pedido;
$$;

create or replace function public.api_criar_pedido(p_hash text, p_dados jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare k public.api_chaves%rowtype; v_id uuid; v_ref text := nullif(left(trim(p_dados ->> 'referencia_externa'), 120), ''); v_rastreio jsonb;
begin
  if not privado.eh_servico() then raise exception 'apenas_servidor' using errcode = '42501'; end if;
  k := privado.api_agir_como(p_hash);
  -- a mesma referência não cria dois pedidos (a loja pode repetir o envio sem medo)
  if v_ref is not null then
    select id into v_id from public.pedidos where empresa_id = k.empresa_id and referencia_externa = v_ref and status not in ('cancelado', 'recusado') limit 1;
    if v_id is not null then return privado.api_pedido_json(v_id) || jsonb_build_object('repetido', true); end if;
  end if;
  v_id := public.criar_pedido((p_dados - 'referencia_externa' - 'regras' - 'empresa_id') || jsonb_build_object('como_cliente', true));
  update public.pedidos set referencia_externa = v_ref, origem = 'api' where id = v_id;
  begin v_rastreio := to_jsonb(public.gerar_rastreio(v_id)); exception when others then v_rastreio := null; end;
  return privado.api_pedido_json(v_id) || jsonb_build_object('rastreio', v_rastreio);
end;
$$;

create or replace function public.api_pedido(p_hash text, p_pedido uuid default null, p_referencia text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare k public.api_chaves%rowtype; v_id uuid;
begin
  if not privado.eh_servico() then raise exception 'apenas_servidor' using errcode = '42501'; end if;
  k := privado.api_agir_como(p_hash);
  select id into v_id from public.pedidos
   where empresa_id = k.empresa_id and ((p_pedido is not null and id = p_pedido) or (p_pedido is null and referencia_externa = p_referencia))
   order by criado_em desc limit 1;
  if v_id is null then raise exception 'pedido_inexistente' using errcode = '22023'; end if;
  return privado.api_pedido_json(v_id);
end;
$$;

create or replace function public.api_pedidos(p_hash text, p_desde timestamptz default null, p_status text default null, p_limite int default 50)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare k public.api_chaves%rowtype;
begin
  if not privado.eh_servico() then raise exception 'apenas_servidor' using errcode = '42501'; end if;
  k := privado.api_agir_como(p_hash);
  return (select coalesce(jsonb_agg(privado.api_pedido_json(x.id) order by x.criado_em desc), '[]') from (
    select id, criado_em from public.pedidos where empresa_id = k.empresa_id
       and criado_em >= coalesce(p_desde, now() - interval '30 days') and (p_status is null or status = p_status)
     order by criado_em desc limit greatest(1, least(coalesce(p_limite, 50), 200))) x);
end;
$$;

create or replace function public.api_cancelar_pedido(p_hash text, p_pedido uuid, p_motivo text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare k public.api_chaves%rowtype;
begin
  if not privado.eh_servico() then raise exception 'apenas_servidor' using errcode = '42501'; end if;
  k := privado.api_agir_como(p_hash);
  if not exists (select 1 from public.pedidos where id = p_pedido and empresa_id = k.empresa_id) then raise exception 'pedido_inexistente' using errcode = '22023'; end if;
  perform public.cancelar_pedido(p_pedido, coalesce(nullif(left(p_motivo, 300), ''), 'Cancelado pela loja (API)'));
  return privado.api_pedido_json(p_pedido);
end;
$$;

revoke execute on function public.api_criar_pedido(text, jsonb), public.api_pedido(text, uuid, text), public.api_pedidos(text, timestamptz, text, int),
  public.api_cancelar_pedido(text, uuid, text) from public, anon, authenticated;
do $$ begin
  execute 'grant execute on function public.api_criar_pedido(text, jsonb), public.api_pedido(text, uuid, text), public.api_pedidos(text, timestamptz, text, int), public.api_cancelar_pedido(text, uuid, text) to service_role';
exception when undefined_object then null; end $$;

-- ---------------------------------------------------------------- webhooks: cada mudança de status vai para a fila
create or replace function privado.aviso_webhook_pedido()
returns trigger language plpgsql security definer set search_path = '' as $$
declare w public.api_webhooks%rowtype;
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then return new; end if;
  if new.empresa_id is null then return new; end if;
  select * into w from public.api_webhooks where empresa_id = new.empresa_id and ativo;
  if w.id is null or not (new.status = any (w.eventos)) then return new; end if;
  insert into privado.avisos_externos (organizacao_id, canal, para, assunto, corpo)
  values (w.organizacao_id, 'webhook', w.url, 'pedido.' || new.status,
          jsonb_build_object('webhook_id', w.id, 'evento', 'pedido.' || new.status, 'pedido', privado.api_pedido_json(new.id)));
  return new;
exception when others then return new;   -- aviso nunca atrapalha o pedido
end;
$$;
drop trigger if exists aviso_webhook_pedido on public.pedidos;
create trigger aviso_webhook_pedido after insert or update of status on public.pedidos
  for each row execute function privado.aviso_webhook_pedido();

-- resultado de cada envio aparece para o gestor
create or replace function public.webhook_resultado(p_webhook uuid, p_status text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not privado.eh_servico() then raise exception 'apenas_servidor' using errcode = '42501'; end if;
  update public.api_webhooks set ultimo_envio = now(), ultimo_status = left(p_status, 80) where id = p_webhook;
end;
$$;
revoke execute on function public.webhook_resultado(uuid, text) from public, anon, authenticated;
do $$ begin
  execute 'grant execute on function public.webhook_resultado(uuid, text) to service_role';
exception when undefined_object then null; end $$;

-- o processador precisa do segredo para assinar
create or replace function public.webhook_segredo(p_webhook uuid)
returns text language plpgsql stable security definer set search_path = '' as $$
begin
  if not privado.eh_servico() then raise exception 'apenas_servidor' using errcode = '42501'; end if;
  return (select segredo from public.api_webhooks where id = p_webhook);
end;
$$;
revoke execute on function public.webhook_segredo(uuid) from public, anon, authenticated;
do $$ begin
  execute 'grant execute on function public.webhook_segredo(uuid) to service_role';
exception when undefined_object then null; end $$;

-- ajustes novos entram nos grupos de permissão (área Sistema: o gestor só vê se o Dev liberar)
insert into public.ajuste_grupos (chave, grupo, area) values
  ('api_lojas_liberada', 'plataforma', 'sistema'),
  ('termos_versao', 'plataforma', 'sistema')
on conflict (chave) do update set grupo = excluded.grupo, area = excluded.area;
