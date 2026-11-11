-- =====================================================================
-- Delibra · 0035: nome no topo, pedido de cancelamento do motoboy, penalidades,
--                  pagamentos (Mercado Pago) e aprendizado que generaliza
--
--  • organizacoes.nome_topo: o texto ao lado da logo no topo (ex.: logo "PW" + "Express"),
--    separado do nome do app usado onde a logo não aparece (ex.: "PW Express").
--  • Chamados: o motoboy em corrida pede para cancelar; o gestor aprova (a rota volta para
--    o sistema) ou nega (continua com ele). Abandono depois de negado = penalidade.
--  • Penalidades (motoboys e clientes): automáticas (oferta ignorada/recusada, desistência,
--    abandono, atraso em planejada) e manuais. Passou do limite na janela → suspensão
--    (motoboy sem ofertas/quadro; cliente sem pedidos novos). Tudo em Ajustes.
--  • Pagamentos: PIX e cartão pelo Mercado Pago. O dinheiro cai na conta da plataforma
--    (Dev) ou na da empresa: padrão global e escolha por empresa (Dev). As chaves ficam
--    em privado.* e só o servidor (service role) lê.
--  • Aprendizado: regras de pagamento por chave e por semelhança (cliente, tipo, número de
--    entregas, km, horário), não só cópias idênticas; e percurso editado repetido quando
--    as paradas são as mesmas (perto).
-- =====================================================================

-- ===================================================================== nome no topo
alter table public.organizacoes add column if not exists nome_topo text;
alter table public.organizacoes drop constraint if exists organizacoes_nome_topo_check;
alter table public.organizacoes add constraint organizacoes_nome_topo_check check (nome_topo is null or char_length(nome_topo) between 1 and 30);
create or replace function public.marca_publica(p_slug text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('nome', o.nome, 'nome_app', o.nome_app, 'nome_topo', o.nome_topo, 'logo', o.logo_url, 'cor', o.cor, 'logo_escala', o.logo_escala,
                            'brilho_cor', o.logo_brilho_cor, 'brilho', o.logo_brilho, 'fonte', o.fonte_nome)
    from public.organizacoes o where o.slug = p_slug and o.status in ('ativa', 'teste');
$$;
create or replace function public.dev_marca_organizacao(p_org uuid, p jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  update public.organizacoes set
    logo_url = case when p ? 'logo_url' then nullif(p ->> 'logo_url', '') else logo_url end,
    logo_original_url = case when p ? 'logo_original_url' then nullif(p ->> 'logo_original_url', '') else logo_original_url end,
    logo_brilho_cor = case when p ? 'brilho_cor' then nullif(p ->> 'brilho_cor', '') else logo_brilho_cor end,
    logo_brilho = case when p ? 'brilho' then least(greatest((p ->> 'brilho')::numeric, 0), 1) else logo_brilho end,
    logo_escala = case when p ? 'logo_escala' then least(greatest((p ->> 'logo_escala')::numeric, 0.8), 2.6) else logo_escala end,
    fonte_nome = case when p ? 'fonte' then nullif(p ->> 'fonte', '') else fonte_nome end,
    nome_app = case when p ? 'nome_app' then nullif(trim(p ->> 'nome_app'), '') else nome_app end,
    nome_topo = case when p ? 'nome_topo' then nullif(trim(p ->> 'nome_topo'), '') else nome_topo end
  where id = p_org;
end;
$$;
create or replace function public.salvar_minha_organizacao(p jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_gestor_pleno() or public.minha_org() is null then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  update public.organizacoes set
    nome      = coalesce(nullif(trim(p ->> 'nome'), ''), nome),
    documento = case when p ? 'documento' then nullif(regexp_replace(p ->> 'documento', '\D', '', 'g'), '') else documento end,
    logo_url  = case when p ? 'logo_url' then nullif(p ->> 'logo_url', '') else logo_url end,
    cor       = case when p ? 'cor' then nullif(p ->> 'cor', '') else cor end,
    nome_app  = case when p ? 'nome_app' then nullif(trim(p ->> 'nome_app'), '') else nome_app end,
    nome_topo = case when p ? 'nome_topo' then nullif(trim(p ->> 'nome_topo'), '') else nome_topo end,
    logo_original_url = case when p ? 'logo_original_url' then nullif(p ->> 'logo_original_url', '') else logo_original_url end,
    logo_brilho_cor = case when p ? 'brilho_cor' then nullif(p ->> 'brilho_cor', '') else logo_brilho_cor end,
    logo_brilho = case when p ? 'brilho' then least(greatest((p ->> 'brilho')::numeric, 0), 1) else logo_brilho end,
    fonte_nome = case when p ? 'fonte' then nullif(p ->> 'fonte', '') else fonte_nome end,
    logo_escala = case when p ? 'logo_escala' then least(greatest((p ->> 'logo_escala')::numeric, 0.8), 2.6) else logo_escala end
   where id = public.minha_org();
end;
$$;

-- ===================================================================== ajustes por empresa (para gatilhos e cron)
create or replace function privado.cfg_org_num(p_org uuid, p_chave text, p_padrao numeric)
returns numeric language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select (valor #>> '{}')::numeric from public.politicas where escopo = 'organizacao' and alvo = p_org::text and chave = p_chave),
    (select (valor #>> '{}')::numeric from public.configuracoes where chave = p_chave),
    p_padrao);
$$;
create or replace function privado.cfg_org_txt(p_org uuid, p_chave text, p_padrao text)
returns text language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select valor #>> '{}' from public.politicas where escopo = 'organizacao' and alvo = p_org::text and chave = p_chave),
    (select valor #>> '{}' from public.configuracoes where chave = p_chave),
    p_padrao);
$$;
revoke execute on function privado.cfg_org_num(uuid, text, numeric), privado.cfg_org_txt(uuid, text, text) from public, anon, authenticated;

-- ===================================================================== penalidades
alter table public.motoboys add column if not exists suspenso_ate timestamptz;
alter table public.motoboys add column if not exists suspenso_motivo text;
alter table public.empresas add column if not exists bloqueado_ate timestamptz;
alter table public.empresas add column if not exists bloqueado_motivo text;

create table if not exists public.penalidades (
  id             uuid primary key default gen_random_uuid(),
  organizacao_id uuid references public.organizacoes (id) on delete cascade,
  alvo_tipo      text not null check (alvo_tipo in ('motoboy', 'cliente')),
  motoboy_id     uuid references public.perfis (id) on delete cascade,
  empresa_id     uuid references public.empresas (id) on delete cascade,
  tipo           text not null,
  pontos         numeric not null check (pontos >= 0),
  motivo         text,
  corrida_id     uuid references public.corridas (id) on delete set null,
  criado_por     uuid references public.perfis (id) on delete set null,
  criado_em      timestamptz not null default now(),
  perdoada_em    timestamptz,
  perdoada_por   uuid references public.perfis (id) on delete set null,
  check ((alvo_tipo = 'motoboy' and motoboy_id is not null) or (alvo_tipo = 'cliente' and empresa_id is not null))
);
create index if not exists penalidades_motoboy on public.penalidades (motoboy_id, criado_em desc);
create index if not exists penalidades_empresa on public.penalidades (empresa_id, criado_em desc);
create index if not exists penalidades_org on public.penalidades (organizacao_id);
alter table public.penalidades enable row level security;
drop policy if exists penalidades_leitura on public.penalidades;
create policy penalidades_leitura on public.penalidades for select to authenticated
  using ((select public.is_gestor()) or motoboy_id = (select auth.uid()));
drop policy if exists org_isolamento on public.penalidades;
create policy org_isolamento on public.penalidades as restrictive for all to authenticated
  using (public.ve_org(organizacao_id) or motoboy_id = (select auth.uid())) with check (public.ve_org(organizacao_id));

-- pontos que valem agora (dentro da janela, não perdoados)
create or replace function privado.pontos_penalidade(p_tipo text, p_alvo uuid, p_org uuid)
returns numeric language sql stable security definer set search_path = '' as $$
  select coalesce(sum(pontos), 0) from public.penalidades
   where perdoada_em is null and criado_em > now() - make_interval(days => privado.cfg_org_num(p_org, 'pen_janela_dias', 30)::int)
     and case when p_tipo = 'motoboy' then motoboy_id = p_alvo else empresa_id = p_alvo end;
$$;
create or replace function privado.motoboy_suspenso(p_motoboy uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select suspenso_ate > now() from public.motoboys where id = p_motoboy), false);
$$;
revoke execute on function privado.pontos_penalidade(text, uuid, uuid), privado.motoboy_suspenso(uuid) from public, anon, authenticated;

-- Registra (se o sistema estiver ligado e os pontos > 0) e aplica a suspensão quando passa do limite.
create or replace function privado.penalizar(p_org uuid, p_alvo_tipo text, p_alvo uuid, p_tipo text, p_pontos numeric,
                                             p_motivo text default null, p_corrida uuid default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_total numeric; v_lim numeric; v_h numeric; v_ate timestamptz;
begin
  if p_alvo is null or coalesce(p_pontos, 0) <= 0 then return null; end if;
  if not coalesce((select (valor #>> '{}')::boolean from public.politicas where escopo = 'organizacao' and alvo = p_org::text and chave = 'pen_ligado'),
                  (select (valor #>> '{}')::boolean from public.configuracoes where chave = 'pen_ligado'), true) then return null; end if;
  insert into public.penalidades (organizacao_id, alvo_tipo, motoboy_id, empresa_id, tipo, pontos, motivo, corrida_id, criado_por)
  values (p_org, p_alvo_tipo, case when p_alvo_tipo = 'motoboy' then p_alvo end, case when p_alvo_tipo = 'cliente' then p_alvo end,
          p_tipo, p_pontos, nullif(trim(p_motivo), ''), p_corrida, auth.uid())
  returning id into v_id;
  v_total := privado.pontos_penalidade(p_alvo_tipo, p_alvo, p_org);
  if p_alvo_tipo = 'motoboy' then
    v_lim := privado.cfg_org_num(p_org, 'pen_limite', 10);
    v_h := privado.cfg_org_num(p_org, 'pen_suspensao_horas', 24);
    if v_lim > 0 and v_total >= v_lim and v_h > 0 and not privado.motoboy_suspenso(p_alvo) then
      v_ate := now() + make_interval(mins => (v_h * 60)::int);
      update public.motoboys set suspenso_ate = v_ate, suspenso_motivo = 'Passou de ' || v_lim || ' pontos de penalidade' where id = p_alvo;
      perform privado.enviar_push(p_alvo, jsonb_build_object('tipo', 'suspenso', 'ate', to_char(v_ate at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'titulo', 'Você está suspenso', 'texto', 'Passou do limite de penalidades. Sem corridas novas até ' || to_char(v_ate at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') || '.'));
      perform privado.avisar_gestores(p_org, jsonb_build_object('tipo', 'motoboy_suspenso', 'motoboy_id', p_alvo::text,
        'titulo', coalesce((select split_part(nome, ' ', 1) from public.perfis where id = p_alvo), 'Motoboy') || ' foi suspenso',
        'texto', 'Passou de ' || v_lim || ' pontos de penalidade. Volta ' || to_char(v_ate at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') || '.'), 'pessoas');
    end if;
  else
    v_lim := privado.cfg_org_num(p_org, 'pen_cliente_limite', 0);
    v_h := privado.cfg_org_num(p_org, 'pen_cliente_bloqueio_horas', 72);
    if v_lim > 0 and v_total >= v_lim and v_h > 0 then
      update public.empresas set bloqueado_ate = now() + make_interval(mins => (v_h * 60)::int),
             bloqueado_motivo = 'Passou de ' || v_lim || ' pontos de penalidade' where id = p_alvo and (bloqueado_ate is null or bloqueado_ate < now());
    end if;
  end if;
  return v_id;
end;
$$;
revoke execute on function privado.penalizar(uuid, text, uuid, text, numeric, text, uuid) from public, anon, authenticated;

-- oferta recusada ou ignorada (deixou expirar)
create or replace function privado.pen_oferta()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_org uuid;
begin
  if new.status::text = old.status::text or new.status::text not in ('recusada', 'expirada') then return new; end if;
  select organizacao_id into v_org from public.corridas where id = new.corrida_id;
  if (select teste from public.corridas where id = new.corrida_id) then return new; end if;
  perform privado.penalizar(v_org, 'motoboy', new.motoboy_id, case when new.status::text = 'recusada' then 'oferta_recusada' else 'oferta_ignorada' end,
    privado.cfg_org_num(v_org, case when new.status::text = 'recusada' then 'pen_pts_recusa' else 'pen_pts_ignorada' end, case when new.status::text = 'recusada' then 0 else 1 end),
    case when new.status::text = 'recusada' then 'Recusou uma oferta' else 'Deixou a oferta passar sem responder' end, new.corrida_id);
  return new;
exception when others then
  raise warning 'pen_oferta: %', sqlerrm; return new;
end;
$$;
drop trigger if exists pen_oferta on public.ofertas;
create trigger pen_oferta after update of status on public.ofertas for each row execute function privado.pen_oferta();

-- planejada atrasada (o sistema marca atraso_avisado_em)
create or replace function privado.pen_atraso()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.atraso_avisado_em is not null and old.atraso_avisado_em is null and new.motoboy_id is not null and not coalesce(new.teste, false) then
    perform privado.penalizar(new.organizacao_id, 'motoboy', new.motoboy_id, 'atraso', privado.cfg_org_num(new.organizacao_id, 'pen_pts_atraso', 1),
      'Atrasou o início de uma rota planejada', new.id);
  end if;
  return new;
exception when others then
  raise warning 'pen_atraso: %', sqlerrm; return new;
end;
$$;
drop trigger if exists pen_atraso on public.corridas;
create trigger pen_atraso after update of atraso_avisado_em on public.corridas for each row execute function privado.pen_atraso();
revoke execute on function privado.pen_oferta(), privado.pen_atraso() from public, anon, authenticated;

-- manual (gestor): motoboy ou cliente
create or replace function public.penalizar_manual(p_alvo_tipo text, p_alvo uuid, p_pontos numeric, p_motivo text, p_corrida uuid default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_org uuid; v_id uuid;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if coalesce(p_pontos, 0) <= 0 or p_pontos > 1000 then raise exception 'pontos_invalidos' using errcode = '22023'; end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'informe_o_motivo' using errcode = '22023'; end if;
  if p_alvo_tipo = 'motoboy' then
    if not public.ve_pessoa(p_alvo) then raise exception 'sem_permissao' using errcode = '42501'; end if;
    v_org := coalesce(public.minha_org(), (select organizacao_id from public.perfis where id = p_alvo));
  elsif p_alvo_tipo = 'cliente' then
    select organizacao_id into v_org from public.empresas where id = p_alvo and public.ve_org(organizacao_id);
    if not found then raise exception 'sem_permissao' using errcode = '42501'; end if;
  else raise exception 'alvo_invalido' using errcode = '22023'; end if;
  -- manual vale mesmo com o automático desligado
  insert into public.penalidades (organizacao_id, alvo_tipo, motoboy_id, empresa_id, tipo, pontos, motivo, corrida_id, criado_por)
  values (v_org, p_alvo_tipo, case when p_alvo_tipo = 'motoboy' then p_alvo end, case when p_alvo_tipo = 'cliente' then p_alvo end,
          'manual', p_pontos, trim(p_motivo), p_corrida, auth.uid()) returning id into v_id;
  -- confere o limite (reusa a regra, sem registrar de novo)
  perform privado.conferir_limite_penalidade(p_alvo_tipo, p_alvo, v_org);
  return v_id;
end;
$$;

create or replace function privado.conferir_limite_penalidade(p_alvo_tipo text, p_alvo uuid, p_org uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_total numeric := privado.pontos_penalidade(p_alvo_tipo, p_alvo, p_org); v_lim numeric; v_h numeric;
begin
  if p_alvo_tipo = 'motoboy' then
    v_lim := privado.cfg_org_num(p_org, 'pen_limite', 10); v_h := privado.cfg_org_num(p_org, 'pen_suspensao_horas', 24);
    if v_lim > 0 and v_total >= v_lim and v_h > 0 and not privado.motoboy_suspenso(p_alvo) then
      update public.motoboys set suspenso_ate = now() + make_interval(mins => (v_h * 60)::int), suspenso_motivo = 'Passou de ' || v_lim || ' pontos de penalidade' where id = p_alvo;
      perform privado.enviar_push(p_alvo, jsonb_build_object('tipo', 'suspenso', 'titulo', 'Você está suspenso', 'texto', 'Passou do limite de penalidades. Sem corridas novas por um tempo.'));
    end if;
  else
    v_lim := privado.cfg_org_num(p_org, 'pen_cliente_limite', 0); v_h := privado.cfg_org_num(p_org, 'pen_cliente_bloqueio_horas', 72);
    if v_lim > 0 and v_total >= v_lim and v_h > 0 then
      update public.empresas set bloqueado_ate = now() + make_interval(mins => (v_h * 60)::int), bloqueado_motivo = 'Passou de ' || v_lim || ' pontos de penalidade'
       where id = p_alvo and (bloqueado_ate is null or bloqueado_ate < now());
    end if;
  end if;
end;
$$;
revoke execute on function privado.conferir_limite_penalidade(text, uuid, uuid) from public, anon, authenticated;

create or replace function public.perdoar_penalidade(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  update public.penalidades set perdoada_em = now(), perdoada_por = auth.uid() where id = p_id and perdoada_em is null and public.ve_org(organizacao_id);
  if not found then raise exception 'penalidade_nao_encontrada' using errcode = '22023'; end if;
end;
$$;

-- tirar a suspensão / o bloqueio antes da hora
create or replace function public.levantar_suspensao(p_alvo_tipo text, p_alvo uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if p_alvo_tipo = 'motoboy' then
    if not public.ve_pessoa(p_alvo) then raise exception 'sem_permissao' using errcode = '42501'; end if;
    update public.motoboys set suspenso_ate = null, suspenso_motivo = null where id = p_alvo;
    perform privado.enviar_push(p_alvo, jsonb_build_object('tipo', 'suspensao_fim', 'titulo', 'Suspensão retirada', 'texto', 'Você já pode receber corridas de novo.'));
  else
    update public.empresas set bloqueado_ate = null, bloqueado_motivo = null where id = p_alvo and public.ve_org(organizacao_id);
  end if;
end;
$$;

-- lista + situação (gestor vê de quem enxerga; motoboy vê as dele)
create or replace function public.penalidades_de(p_alvo_tipo text, p_alvo uuid default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_alvo uuid := coalesce(p_alvo, auth.uid()); v_org uuid;
begin
  if p_alvo_tipo = 'motoboy' then
    if v_alvo <> auth.uid() and not (public.is_gestor() and public.ve_pessoa(v_alvo)) then raise exception 'sem_permissao' using errcode = '42501'; end if;
    v_org := (select organizacao_id from public.perfis where id = v_alvo);
  else
    select organizacao_id into v_org from public.empresas where id = v_alvo and (public.ve_org(organizacao_id) or id = privado.minha_empresa());
    if not found then raise exception 'sem_permissao' using errcode = '42501'; end if;
  end if;
  return jsonb_build_object(
    'pontos', privado.pontos_penalidade(p_alvo_tipo, v_alvo, v_org),
    'limite', case when p_alvo_tipo = 'motoboy' then privado.cfg_org_num(v_org, 'pen_limite', 10) else privado.cfg_org_num(v_org, 'pen_cliente_limite', 0) end,
    'janela_dias', privado.cfg_org_num(v_org, 'pen_janela_dias', 30),
    'suspenso_ate', case when p_alvo_tipo = 'motoboy' then (select suspenso_ate from public.motoboys where id = v_alvo and suspenso_ate > now())
                         else (select bloqueado_ate from public.empresas where id = v_alvo and bloqueado_ate > now()) end,
    'motivo', case when p_alvo_tipo = 'motoboy' then (select suspenso_motivo from public.motoboys where id = v_alvo) else (select bloqueado_motivo from public.empresas where id = v_alvo) end,
    'itens', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'tipo', x.tipo, 'pontos', x.pontos, 'motivo', x.motivo, 'quando', x.criado_em,
        'corrida_numero', (select c.numero from public.corridas c where c.id = x.corrida_id), 'perdoada', x.perdoada_em is not null,
        'vale', x.perdoada_em is null and x.criado_em > now() - make_interval(days => privado.cfg_org_num(v_org, 'pen_janela_dias', 30)::int))
        order by x.criado_em desc)
        from (select * from public.penalidades where case when p_alvo_tipo = 'motoboy' then motoboy_id = v_alvo else empresa_id = v_alvo end
               order by criado_em desc limit 100) x), '[]'::jsonb));
end;
$$;
revoke execute on function public.penalizar_manual(text, uuid, numeric, text, uuid), public.perdoar_penalidade(uuid),
  public.levantar_suspensao(text, uuid), public.penalidades_de(text, uuid) from public, anon;
grant execute on function public.penalizar_manual(text, uuid, numeric, text, uuid), public.perdoar_penalidade(uuid),
  public.levantar_suspensao(text, uuid), public.penalidades_de(text, uuid) to authenticated;
create or replace function privado.despachar(p_corrida uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  c            public.corridas%rowtype;
  v_coleta     extensions.geography;
  v_motoboy    uuid;
  v_dist       double precision;
  v_oferta     uuid;
  v_expira     timestamptz;
  v_idade      interval := make_interval(mins => privado.cfg_num('posicao_max_min', 15)::int);
  v_raio_max   numeric := privado.cfg_num('raio_max_despacho_km', 0) * 1000;
  v_favoritos  boolean := privado.cfg_bool('favoritos_primeiro', true);
  v_fc         numeric;
  v_emc        text;
  v_ext_raio   numeric;
  v_ext_max    int;
  v_nent       int;
  v_max        int;
  v_ext        boolean := false;
begin
  select * into c from public.corridas where id = p_corrida for update;
  if not found or c.status not in ('aguardando_motoboy', 'sem_motoboy') then return; end if;
  perform set_config('pwex.org', coalesce(c.organizacao_id::text, ''), true);
  if exists (select 1 from public.ofertas where corrida_id = p_corrida and status = 'pendente') then return; end if;
  -- quadro: ninguém recebe oferta, todos veem e o primeiro pega
  if c.modo_despacho::text = 'quadro' then return; end if;
  -- melhor primeiro: já teve a vez dele → vai para o quadro (agendada volta a ser "agendada" para reservar)
  if c.modo_despacho::text = 'melhor_primeiro' and exists (select 1 from public.ofertas where corrida_id = p_corrida) then
    update public.corridas set modo_despacho = 'quadro', quadro_desde = now(),
           status = case when c.agendada_para > now() then 'agendada' else 'aguardando_motoboy' end::public.status_corrida where id = p_corrida;
    perform privado.evento(p_corrida, 'foi_para_o_quadro');
    perform privado.avisar_quadro(p_corrida);
    return;
  end if;
  v_expira := now() + make_interval(secs => case when c.modo_despacho::text = 'melhor_primeiro'
                                                 then privado.pol_num('despacho_melhor_segundos', 45, c.empresa_id, null, c.tipo_pedido)
                                                 else privado.cfg_num('oferta_segundos', 30) end);

  select extensions.st_setsrid(extensions.st_makepoint(lng, lat), 4326)::extensions.geography
    into v_coleta from public.paradas where corrida_id = p_corrida order by ordem limit 1;
  -- motoboys em corrida também concorrem (extensão de rota), se a regra deixar e a rota for para agora
  v_emc := case when c.agendada_para > now() then 'nao' else privado.pol_txt('despacho_em_corrida', 'depois', c.empresa_id, null, c.tipo_pedido) end;
  v_ext_raio := privado.pol_num('extensao_raio_km', 3, c.empresa_id, null, c.tipo_pedido) * 1000;
  v_ext_max := privado.pol_num('extensao_max_entregas', 8, c.empresa_id, null, c.tipo_pedido)::int;
  select count(*) into v_nent from public.paradas where corrida_id = p_corrida and tipo = 'entrega';
  v_max := privado.pol_num('despacho_max_ofertas', 0, c.empresa_id, null, c.tipo_pedido)::int;

  if c.modo_despacho = 'direto' then
    if c.motoboy_designado_id is not null and not exists (
      select 1 from public.ofertas where corrida_id = p_corrida and motoboy_id = c.motoboy_designado_id and rodada = c.rodada
    ) and exists (select 1 from public.motoboys where id = c.motoboy_designado_id and modo_teste = c.teste) then
      v_motoboy := c.motoboy_designado_id;
      select extensions.st_distance(m.posicao, v_coleta) into v_dist from public.motoboys m where m.id = v_motoboy;
    end if;
  else
    select m.id, extensions.st_distance(m.posicao, v_coleta) into v_motoboy, v_dist
      from public.motoboys m
      left join public.empresa_favoritos f on v_favoritos and f.motoboy_id = m.id and f.empresa_id = c.empresa_id
     where (m.status = 'disponivel'
            or (v_emc in ('depois', 'junto') and m.status = 'em_corrida'
                and extensions.st_distance(m.posicao, v_coleta) <= v_ext_raio
                and exists (select 1 from public.corridas k where k.motoboy_id = m.id and k.status::text in ('aceita', 'em_andamento') and k.teste = c.teste
                             and (select count(*) from public.paradas kp where kp.corrida_id = k.id and kp.tipo = 'entrega' and kp.status::text <> 'concluida') + v_nent <= v_ext_max)))
       and (v_max <= 0 or (select count(*) from public.ofertas o where o.corrida_id = p_corrida and o.rodada = c.rodada) < v_max)
       and m.modo_teste = c.teste
       and not privado.motoboy_suspenso(m.id)
       and m.posicao is not null
       and m.posicao_em > now() - v_idade
       and (v_raio_max <= 0 or extensions.st_distance(m.posicao, v_coleta) <= v_raio_max)
       and (c.urgente or coalesce(m.raio_km, 0) <= 0 or extensions.st_distance(
              case when m.raio_modo = 'fixo' and m.raio_lat is not null and m.raio_lng is not null
                   then extensions.st_setsrid(extensions.st_makepoint(m.raio_lng, m.raio_lat), 4326)::extensions.geography
                   else m.posicao end,
              v_coleta) <= m.raio_km * 1000)
       and not exists (select 1 from public.ofertas o where o.corrida_id = p_corrida and o.motoboy_id = m.id
                        and (o.rodada = c.rodada or o.status = 'recusada'))
       and not exists (select 1 from public.ofertas o where o.motoboy_id = m.id and o.status = 'pendente')
       and public.org_alcanca(c.organizacao_id, (select p.organizacao_id from public.perfis p where p.id = m.id), null)
     -- primeiro os da própria empresa; os de outras só se o Dev liberou (e, em "sem motoboy livre", só se faltar)
     order by ((select p.organizacao_id from public.perfis p where p.id = m.id) is distinct from c.organizacao_id), (f.ordem is null), f.ordem, (v_emc = 'depois' and m.status <> 'disponivel'), extensions.st_distance(m.posicao, v_coleta)
     limit 1;
  end if;

  if v_motoboy is null then
    -- ninguém para oferecer: vai para o quadro de rotas com aviso (ou para em "sem motoboy", se a regra pedir)
    if c.modo_despacho::text = 'melhor_primeiro' or (c.agendada_para > now() and c.modo_despacho::text <> 'direto')
       or (c.modo_despacho::text = 'cascata' and privado.pol_txt('despacho_sem_motoboy', 'quadro', c.empresa_id, null, c.tipo_pedido) = 'quadro') then
      update public.corridas set modo_despacho = 'quadro', quadro_desde = now(),
             status = case when c.agendada_para > now() then 'agendada' else 'aguardando_motoboy' end::public.status_corrida where id = p_corrida;
      perform privado.evento(p_corrida, 'foi_para_o_quadro');
      perform privado.avisar_quadro(p_corrida);
      return;
    end if;
    update public.corridas set status = 'sem_motoboy' where id = p_corrida;
    perform privado.evento(p_corrida, 'sem_motoboy');
    return;
  end if;

  v_fc := case when c.aplicar_acrescimo then privado.fator_distancia(v_dist, 'coleta') else 0 end;
  v_ext := (c.agendada_para is null or c.agendada_para <= now()) and exists (select 1 from public.corridas k where k.motoboy_id = v_motoboy and k.status::text in ('aceita', 'em_andamento'));
  insert into public.ofertas (corrida_id, motoboy_id, rodada, distancia_m, expira_em, fator_coleta, valor, extensao)
  values (p_corrida, v_motoboy, c.rodada, round(v_dist), v_expira, v_fc,
          privado.arredondar(coalesce(c.valor_base, c.valor, 0) * (1 + coalesce(c.fator_entrega, 0) + v_fc)), v_ext)
  returning id into v_oferta;

  update public.corridas set status = 'aguardando_motoboy' where id = p_corrida;
  perform privado.evento(p_corrida, 'oferta_enviada', jsonb_build_object('motoboy_id', v_motoboy, 'distancia_m', round(v_dist), 'extensao', v_ext));
  perform privado.enviar_push(v_motoboy, jsonb_build_object(
    'tipo', 'oferta', 'extensao', v_ext::text, 'oferta_id', v_oferta::text, 'corrida_id', p_corrida::text, 'teste', c.teste::text,
    'expira_em', to_char(v_expira at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
  ));
end;
$$;
create or replace function public.rotas_disponiveis()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  m  public.motoboys%rowtype;
begin
  perform privado.checar_versao_app();
  if not public.tem_papel('motoboy'::public.papel_usuario) then raise exception 'apenas_motoboy' using errcode = '42501'; end if;
  select * into m from public.motoboys where id = auth.uid();
  if privado.motoboy_suspenso(auth.uid()) then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(privado.corrida_json(c.id) || jsonb_build_object(
             'planejada', c.agendada_para is not null,
             'sugerida', c.sugerido_motoboy_id = auth.uid(),
             'distancia_ate_coleta_m', round(privado.dist_m(m.lat, m.lng, col.lat, col.lng)),
             'no_quadro_desde', c.quadro_desde)
           order by (c.sugerido_motoboy_id = auth.uid()) desc, c.urgente desc, coalesce(c.agendada_para, c.quadro_desde, c.criada_em))
      from public.corridas c
      join lateral (select lat, lng from public.paradas where corrida_id = c.id order by ordem limit 1) col on true
     where c.motoboy_id is null and c.teste = coalesce(m.modo_teste, false)
       and public.org_alcanca(c.organizacao_id, (select organizacao_id from public.perfis where id = auth.uid()), c.quadro_desde)
       and ((c.status::text in ('aguardando_motoboy', 'sem_motoboy') and c.modo_despacho::text = 'quadro')
            or (c.status::text = 'agendada' and c.agendada_para > now()))
       and (c.agendada_para is not null or c.urgente or coalesce(m.raio_km, 0) <= 0 or m.lat is null or privado.dist_m(
              case when m.raio_modo = 'fixo' and m.raio_lat is not null then m.raio_lat else m.lat end,
              case when m.raio_modo = 'fixo' and m.raio_lng is not null then m.raio_lng else m.lng end, col.lat, col.lng) <= m.raio_km * 1000)
  ), '[]'::jsonb);
end;
$$;
create or replace function public.pegar_rota(p_corrida uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c       public.corridas%rowtype;
  v_teste boolean := coalesce((select modo_teste from public.motoboys where id = auth.uid()), false);
begin
  if privado.motoboy_suspenso(auth.uid()) then raise exception 'motoboy_suspenso' using errcode = '42501'; end if;
  perform privado.checar_versao_app();
  if not public.tem_papel('motoboy'::public.papel_usuario) then raise exception 'apenas_motoboy' using errcode = '42501'; end if;
  select * into c from public.corridas where id = p_corrida for update;
  if not found or c.motoboy_id is not null then raise exception 'rota_ja_pegada' using errcode = '22023'; end if;
  if c.teste <> v_teste then raise exception 'modo_teste_diferente' using errcode = '22023'; end if;
  if privado.cfg_bool('veiculo_obrigatorio', false) and not c.teste
     and (select veiculo_placa from public.motoboys where id = auth.uid()) is null then
    raise exception 'cadastre_o_veiculo' using errcode = '42501';
  end if;
  if c.status::text = 'agendada' then return public.reservar_corrida(p_corrida); end if;
  if not (c.status::text in ('aguardando_motoboy', 'sem_motoboy') and c.modo_despacho::text = 'quadro') then
    raise exception 'rota_ja_pegada' using errcode = '22023';
  end if;
  if exists (select 1 from public.corridas where motoboy_id = auth.uid() and status in ('aceita', 'em_andamento')) then
    raise exception 'voce_ja_tem_corrida_ativa' using errcode = '22023';
  end if;
  update public.ofertas set status = 'cancelada' where corrida_id = p_corrida and status = 'pendente';
  update public.corridas set status = 'aceita', motoboy_id = auth.uid(), aceita_em = now() where id = p_corrida;
  update public.paradas set status = 'a_caminho'
   where corrida_id = p_corrida and ordem = (select min(ordem) from public.paradas where corrida_id = p_corrida);
  update public.motoboys set status = 'em_corrida', status_em = now() where id = auth.uid();
  perform privado.evento(p_corrida, 'aceita', jsonb_build_object('motoboy_id', auth.uid(), 'quadro', true, 'sugerida', c.sugerido_motoboy_id = auth.uid()));
  return privado.corrida_json(p_corrida);
end;
$$;
create or replace function public.responder_oferta(p_oferta uuid, p_aceitar boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  o       public.ofertas%rowtype;
  v_pct   numeric;
  v_valor numeric;
  v_ativa uuid;
begin
  if p_aceitar and privado.motoboy_suspenso(auth.uid()) then raise exception 'motoboy_suspenso' using errcode = '42501'; end if;
  perform privado.checar_versao_app();
  select * into o from public.ofertas where id = p_oferta for update;
  if not found or o.motoboy_id <> auth.uid() then
    raise exception 'oferta_nao_encontrada' using errcode = '22023';
  end if;
  if o.status <> 'pendente' or o.expira_em <= now() then
    raise exception 'oferta_expirou' using errcode = '22023';
  end if;

  if not p_aceitar then
    update public.ofertas set status = 'recusada', respondida_em = now() where id = p_oferta;
    perform privado.evento(o.corrida_id, 'oferta_recusada', jsonb_build_object('motoboy_id', o.motoboy_id));
    perform privado.despachar(o.corrida_id);
    return null;
  end if;

  -- corrida agendada: aceitar a oferta é reservar (começa no horário)
  if (select agendada_para from public.corridas where id = o.corrida_id) > now() then
    perform privado.reservar_por_oferta(o);
    return privado.corrida_json(o.corrida_id);
  end if;

  if exists (select 1 from public.corridas
              where motoboy_id = auth.uid() and status in ('aceita', 'em_andamento')) then
    -- extensão de rota: as paradas novas entram no fim da rota que ele já está fazendo
    if o.extensao then
      update public.ofertas set status = 'aceita', respondida_em = now() where id = p_oferta;
      v_ativa := privado.estender_rota(
        (select id from public.corridas where motoboy_id = auth.uid() and status in ('aceita', 'em_andamento') order by aceita_em desc limit 1), o.corrida_id);
      return privado.corrida_json(v_ativa);
    end if;
    raise exception 'voce_ja_tem_corrida_ativa' using errcode = '22023';
  end if;

  v_pct := privado.repasse_de(o.motoboy_id);
  select coalesce(o.valor, valor, 0) into v_valor from public.corridas where id = o.corrida_id;
  update public.ofertas set status = 'aceita', respondida_em = now() where id = p_oferta;
  update public.corridas
     set status = 'aceita', motoboy_id = o.motoboy_id, aceita_em = now(),
         valor = v_valor,
         fator_coleta = o.fator_coleta,
         repasse_pct = v_pct,
         valor_motoboy = round(v_valor * v_pct / 100, 2),
         valor_gestao = v_valor - round(v_valor * v_pct / 100, 2)
   where id = o.corrida_id;
  update public.paradas set status = 'a_caminho'
   where corrida_id = o.corrida_id and ordem = (select min(ordem) from public.paradas where corrida_id = o.corrida_id);
  update public.motoboys set status = 'em_corrida', status_em = now() where id = o.motoboy_id;
  perform privado.evento(o.corrida_id, 'aceita', jsonb_build_object(
    'motoboy_id', o.motoboy_id, 'repasse_pct', v_pct, 'fator_coleta', o.fator_coleta, 'distancia_m', o.distancia_m));

  return privado.corrida_json(o.corrida_id);
end;
$$;
create or replace function public.criar_pedido(dados jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_gestor  boolean := public.is_gestor() and not coalesce((dados ->> 'como_cliente')::boolean, false);
  v_regras  jsonb := '{}';
  v_cat     public.categorias_produto%rowtype;
  v_cli     uuid;
  e         public.empresas%rowtype;
  v_quando  timestamptz := nullif(dados ->> 'quando', '')::timestamptz;
  v_tipo    text;
  v_tp      text := coalesce(nullif(dados ->> 'tipo_pedido', ''), 'padrao');
  v_teste   boolean := false;
  v_id      uuid;
  v_ids     uuid[] := '{}';
  v_pid     uuid;
  v_orc     jsonb;
  v_status  text;
  v_cobr    text;
  v_dev     numeric;
  p         jsonb;
  i         jsonb;
  k         int := 0;
begin
  if v_gestor then
    v_cli := nullif(dados ->> 'empresa_id', '')::uuid;
    v_teste := coalesce((dados ->> 'teste')::boolean, (select modo_teste from public.perfis where id = auth.uid()), false);
  else
    v_cli := privado.minha_empresa();
    if v_cli is null then raise exception 'apenas_gestor_ou_cliente' using errcode = '42501'; end if;
    v_teste := privado.cliente_teste();
    if exists (select 1 from public.empresas where id = v_cli and bloqueado_ate > now()) then
      raise exception 'cliente_bloqueado' using errcode = '42501', detail = (select bloqueado_motivo from public.empresas where id = v_cli);
    end if;
  end if;
  if v_gestor then v_regras := privado.limpar_regras(dados -> 'regras'); end if;
  if v_cli is not null and v_gestor and (select modo_teste from public.empresas where id = v_cli) then v_teste := true; end if;
  if v_cli is not null then select * into e from public.empresas where id = v_cli; end if;
  if v_gestor and v_cli is not null and (e.id is null or not public.ve_org(e.organizacao_id)) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if not exists (select 1 from public.tipos_pedido where chave = v_tp and (ativo or v_gestor)
                 and (organizacao_id is null or organizacao_id = privado.org_contexto(v_cli))) then raise exception 'tipo_pedido_invalido' using errcode = '22023'; end if;

  v_tipo := case when v_quando is null then 'express' else 'planejado' end;
  if not v_gestor then
    if v_tipo = 'express' and not (coalesce(e.pode_express, false) and privado.pol_bool('cliente_pode_express', true, v_cli, null, v_tp)) then
      raise exception 'cliente_so_agendado' using errcode = '42501';
    end if;
    if v_tipo = 'planejado' and not privado.pol_bool('cliente_pode_agendar', true, v_cli, null, v_tp) then
      raise exception 'cliente_sem_agendado' using errcode = '42501';
    end if;
    if v_tipo = 'planejado' and privado.pol_num('cliente_agendar_max_dias', 60, v_cli, null, v_tp) > 0
       and v_quando > now() + make_interval(days => privado.pol_num('cliente_agendar_max_dias', 60, v_cli, null, v_tp)::int) then
      raise exception 'agendamento_longe_demais' using errcode = '22023';
    end if;
    if coalesce((dados ->> 'urgente')::boolean, false) and not privado.pol_bool('cliente_pode_urgente', true, v_cli, null, v_tp) then
      raise exception 'cliente_sem_urgente' using errcode = '42501';
    end if;
    if privado.pol_num('cliente_max_entregas', 0, v_cli, null, v_tp) > 0
       and (select count(*) from jsonb_array_elements(coalesce(dados -> 'pontos', '[]')) x where x ->> 'tipo' = 'entrega') > privado.pol_num('cliente_max_entregas', 0, v_cli, null, v_tp) then
      raise exception 'entregas_demais' using errcode = '22023';
    end if;
    if privado.pol_num('cliente_max_coletas', 0, v_cli, null, v_tp) > 0
       and (select count(*) from jsonb_array_elements(coalesce(dados -> 'pontos', '[]')) x where x ->> 'tipo' = 'coleta') > privado.pol_num('cliente_max_coletas', 0, v_cli, null, v_tp) then
      raise exception 'coletas_demais' using errcode = '22023';
    end if;
    if privado.pol_num('cliente_max_pedidos_abertos', 0, v_cli, null, v_tp) > 0
       and (select count(*) from public.pedidos x where x.empresa_id = v_cli and x.teste = v_teste and x.status in ('recebido', 'aprovado', 'roteirizado', 'em_rota'))
           >= privado.pol_num('cliente_max_pedidos_abertos', 0, v_cli, null, v_tp) then
      raise exception 'pedidos_abertos_demais' using errcode = '22023';
    end if;
    -- horário em que o cliente pode pedir para agora (vazio = qualquer hora)
    if v_tipo = 'express' and privado.pol_txt('cliente_pedido_de', '', v_cli, null, v_tp) ~ '^[0-2][0-9]:[0-5][0-9]$'
       and privado.pol_txt('cliente_pedido_ate', '', v_cli, null, v_tp) ~ '^[0-2][0-9]:[0-5][0-9]$'
       and not ((now() at time zone 'America/Sao_Paulo')::time between privado.pol_txt('cliente_pedido_de', '', v_cli, null, v_tp)::time
                                                                 and privado.pol_txt('cliente_pedido_ate', '', v_cli, null, v_tp)::time) then
      raise exception 'fora_do_horario' using errcode = '22023';
    end if;
    if v_tipo = 'planejado' and v_quando < now() + make_interval(mins => privado.pol_num('agendada_antecedencia_cliente_min', 60, v_cli, null, v_tp)::int) then
      raise exception 'horario_muito_proximo' using errcode = '22023';
    end if;
  elsif v_tipo = 'planejado' and v_quando < now() then
    raise exception 'horario_passou' using errcode = '22023';
  end if;

  if (select count(*) from jsonb_array_elements(coalesce(dados -> 'pontos', '[]')) x where x ->> 'tipo' = 'coleta') < 1
     or (select count(*) from jsonb_array_elements(coalesce(dados -> 'pontos', '[]')) x where x ->> 'tipo' = 'entrega') < 1 then
    raise exception 'pedido_precisa_coleta_e_entrega' using errcode = '22023';
  end if;
  if exists (select 1 from jsonb_array_elements(dados -> 'pontos') x where nullif(x ->> 'lat', '') is null or nullif(x ->> 'lng', '') is null) then
    raise exception 'ponto_sem_localizacao' using errcode = '22023';
  end if;
  if jsonb_array_length(dados -> 'pontos') > 60 then raise exception 'pontos_demais' using errcode = '22023'; end if;
  if exists (select 1 from jsonb_array_elements(dados -> 'pontos') x
              where nullif(x ->> 'janela_de', '') is not null and nullif(x ->> 'janela_ate', '') is not null
                and (x ->> 'janela_de')::time >= (x ->> 'janela_ate')::time) then
    raise exception 'janela_invalida' using errcode = '22023';
  end if;
  -- campos do item que a categoria exige
  for i in select * from jsonb_array_elements(coalesce(dados -> 'itens', '[]')) loop
    if nullif(i ->> 'categoria_id', '') is null then
      if not v_gestor and privado.cfg_bool('item_categoria_obrigatoria', false) then raise exception 'item_sem_categoria' using errcode = '22023'; end if;
      continue;
    end if;
    select * into v_cat from public.categorias_produto where id = (i ->> 'categoria_id')::uuid
       and (organizacao_id is null or organizacao_id = privado.org_contexto(v_cli));
    if not found then raise exception 'categoria_invalida' using errcode = '22023'; end if;
    if v_gestor then continue; end if;
    if v_cat.campo_peso = 'obrigatorio' and coalesce(nullif(i ->> 'peso_kg', '')::numeric, 0) <= 0 then raise exception 'item_sem_peso' using errcode = '22023'; end if;
    if v_cat.campo_valor = 'obrigatorio' and coalesce(nullif(i ->> 'valor_declarado', '')::numeric, 0) <= 0 then raise exception 'item_sem_valor' using errcode = '22023'; end if;
    if v_cat.campo_descricao = 'obrigatorio' and coalesce(trim(i ->> 'descricao'), '') = '' then raise exception 'item_sem_descricao' using errcode = '22023'; end if;
    if v_cat.campo_medidas = 'obrigatorio' and (coalesce(nullif(i ->> 'comprimento_cm', '')::numeric, 0) <= 0
         or coalesce(nullif(i ->> 'largura_cm', '')::numeric, 0) <= 0 or coalesce(nullif(i ->> 'altura_cm', '')::numeric, 0) <= 0) then
      raise exception 'item_sem_medidas' using errcode = '22023';
    end if;
  end loop;
  perform privado.usar_regras(v_regras);

  v_orc := privado.orcar(jsonb_build_object('empresa_id', v_cli, 'tipo', v_tipo, 'tipo_pedido', v_tp, 'quando', v_quando,
                                            'urgente', coalesce((dados ->> 'urgente')::boolean, false), 'distancia_m', dados -> 'distancia_m',
                                            'pontos', dados -> 'pontos', 'itens', coalesce(dados -> 'itens', '[]'), 'regras', v_regras));
  v_cobr := privado.pol_txt('cobranca_modo', 'credito', v_cli, null, v_tp);
  if v_cli is null then v_cobr := 'pre_pago'; end if;
  v_status := case when v_gestor then 'aprovado'
                   when privado.pol_bool('pedido_revisao_gestor', true, v_cli, null, v_tp) then 'recebido'
                   else 'aprovado' end;
  v_dev := coalesce(e.dev_pct, privado.pol_num('dev_pct', 5, v_cli, null, v_tp));

  insert into public.pedidos (teste, empresa_id, cliente_nome, criado_por, origem, tipo, tipo_pedido, quando, urgente, status, observacoes,
                              distancia_estimada_m, orcamento, valor_calculado, valor, dev_pct, valor_dev, cobranca, pagamento_status,
                              pagamento_metodo, aprovado_em, revisado_por, revisado_em, regras)
  values (v_teste, v_cli, case when v_cli is null then nullif(trim(dados ->> 'cliente_nome'), '') end, auth.uid(),
          case when v_gestor then 'gestor' else 'cliente' end, v_tipo, v_tp, v_quando, coalesce((dados ->> 'urgente')::boolean, false),
          v_status, nullif(left(dados ->> 'observacoes', 1000), ''), (v_orc ->> 'distancia_m')::int, v_orc,
          (v_orc ->> 'total')::numeric, (v_orc ->> 'total')::numeric, v_dev, round((v_orc ->> 'total')::numeric * v_dev / 100, 2),
          v_cobr, case when v_cobr = 'pre_pago' then 'pendente' else 'nao_exigido' end, nullif(dados ->> 'metodo', ''),
          case when v_status = 'aprovado' then now() end,
          case when v_gestor then auth.uid() end, case when v_gestor then now() end, v_regras)
  returning id into v_id;

  for p in select * from jsonb_array_elements(dados -> 'pontos') loop
    -- confirmações e janela de cada ponto: o cliente só pede o que o gestor liberou para ele
    insert into public.pedido_pontos (pedido_id, ordem, tipo, endereco, lat, lng, contato_nome, contato_telefone, instrucoes, referencias,
                                      exige_foto, exige_assinatura, exige_nome, exige_codigo, janela_de, janela_ate, dist_coleta_m)
    values (v_id, k, (p ->> 'tipo')::public.tipo_parada, left(coalesce(p ->> 'endereco', ''), 300), (p ->> 'lat')::double precision, (p ->> 'lng')::double precision,
            nullif(left(p ->> 'contato_nome', 120), ''), nullif(left(p ->> 'contato_telefone', 40), ''), nullif(left(p ->> 'instrucoes', 500), ''),
            privado.limpar_referencias(p -> 'referencias'),
            case when v_gestor or privado.pol_bool('cliente_confirma_foto', true, v_cli, null, v_tp) then (p ->> 'exige_foto')::boolean end,
            case when v_gestor or privado.pol_bool('cliente_confirma_assinatura', true, v_cli, null, v_tp) then (p ->> 'exige_assinatura')::boolean end,
            case when v_gestor or privado.pol_bool('cliente_confirma_nome', true, v_cli, null, v_tp) then (p ->> 'exige_nome')::boolean end,
            case when v_gestor or privado.pol_bool('cliente_confirma_codigo', true, v_cli, null, v_tp) then (p ->> 'exige_codigo')::boolean end,
            case when v_gestor or privado.pol_bool('cliente_pode_janela', true, v_cli, null, v_tp) then nullif(p ->> 'janela_de', '')::time end,
            case when v_gestor or privado.pol_bool('cliente_pode_janela', true, v_cli, null, v_tp) then nullif(p ->> 'janela_ate', '')::time end,
            case when nullif(p ->> 'dist_coleta_m', '')::numeric between 1 and 2000000 then round((p ->> 'dist_coleta_m')::numeric)::int end)
    returning id into v_pid;
    v_ids := v_ids || v_pid;
    k := k + 1;
  end loop;

  for i in select * from jsonb_array_elements(coalesce(dados -> 'itens', '[]')) loop
    insert into public.pedido_itens (pedido_id, coleta_id, entrega_id, descricao, categoria_id, quantidade, peso_kg, comprimento_cm, largura_cm, altura_cm, valor_declarado, observacoes)
    values (v_id,
            case when nullif(i ->> 'coleta', '') is not null then v_ids[(i ->> 'coleta')::int + 1] end,
            case when nullif(i ->> 'entrega', '') is not null then v_ids[(i ->> 'entrega')::int + 1] end,
            left(coalesce(nullif(trim(i ->> 'descricao'), ''), (select nome from public.categorias_produto where id = nullif(i ->> 'categoria_id', '')::uuid), 'Item'), 200), nullif(i ->> 'categoria_id', '')::uuid,
            greatest(1, coalesce((i ->> 'quantidade')::int, 1)), nullif(i ->> 'peso_kg', '')::numeric,
            nullif(i ->> 'comprimento_cm', '')::numeric, nullif(i ->> 'largura_cm', '')::numeric, nullif(i ->> 'altura_cm', '')::numeric,
            nullif(i ->> 'valor_declarado', '')::numeric, nullif(left(i ->> 'observacoes', 300), ''));
  end loop;

  -- "dados" também é coluna de pedido_modelos: usa o parâmetro pelo nome da função
  for i in select * from jsonb_array_elements(coalesce(criar_pedido.dados -> 'objetos_usados', '[]')) loop
    update public.cliente_objetos o set usos = o.usos + 1 where o.id = (i #>> '{}')::uuid and (v_gestor or o.empresa_id = v_cli);
  end loop;
  if nullif(criar_pedido.dados ->> 'modelo_id', '') is not null then
    update public.pedido_modelos m set usos = m.usos + 1, usado_em = now() where m.id = (criar_pedido.dados ->> 'modelo_id')::uuid;
  end if;
  perform privado.usar_regras('{}');
  perform privado.evento_pedido(v_id, 'criado', jsonb_build_object('origem', case when v_gestor then 'gestor' else 'cliente' end, 'total', v_orc -> 'total'));
  if v_status = 'aprovado' then perform privado.roteirizar(v_teste); end if;
  return v_id;
end;
$$;

-- ===================================================================== pedido de cancelamento do motoboy
create table if not exists public.chamados_corrida (
  id             uuid primary key default gen_random_uuid(),
  organizacao_id uuid references public.organizacoes (id) on delete cascade,
  corrida_id     uuid not null references public.corridas (id) on delete cascade,
  motoboy_id     uuid not null references public.perfis (id) on delete cascade,
  tipo           text not null default 'cancelar' check (tipo in ('cancelar')),
  motivo         text not null,
  status         text not null default 'pendente' check (status in ('pendente', 'aprovado', 'negado', 'retirado', 'expirado')),
  resposta       text,
  respondido_por uuid references public.perfis (id) on delete set null,
  respondido_em  timestamptz,
  abandono       boolean not null default false,
  criado_em      timestamptz not null default now()
);
create index if not exists chamados_corrida_org on public.chamados_corrida (organizacao_id, status, criado_em desc);
create unique index if not exists chamados_corrida_um_pendente on public.chamados_corrida (corrida_id) where status = 'pendente';
alter table public.chamados_corrida enable row level security;
drop policy if exists chamados_leitura on public.chamados_corrida;
create policy chamados_leitura on public.chamados_corrida for select to authenticated
  using ((select public.is_gestor()) or motoboy_id = (select auth.uid()));
drop policy if exists org_isolamento on public.chamados_corrida;
create policy org_isolamento on public.chamados_corrida as restrictive for all to authenticated
  using (public.ve_org(organizacao_id) or motoboy_id = (select auth.uid())) with check (public.ve_org(organizacao_id));

create or replace function privado.chamado_json(p_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select to_jsonb(h) || jsonb_build_object(
    'corrida_numero', c.numero, 'corrida_teste', c.teste, 'corrida_status', c.status, 'motoboy_nome', public.nome_publico(h.motoboy_id),
    'feitas', (select count(*) from public.paradas p where p.corrida_id = c.id and p.status::text = 'concluida'),
    'paradas', (select count(*) from public.paradas p where p.corrida_id = c.id))
    from public.chamados_corrida h join public.corridas c on c.id = h.corrida_id where h.id = p_id;
$$;
revoke execute on function privado.chamado_json(uuid) from public, anon, authenticated;

-- tira o motoboy da rota e devolve ao sistema (despacho de novo, se a regra mandar)
create or replace function privado.devolver_rota(p_corrida uuid, p_evento text)
returns void language plpgsql security definer set search_path = '' as $$
declare c public.corridas%rowtype;
begin
  select * into c from public.corridas where id = p_corrida for update;
  if c.motoboy_id is null then return; end if;
  update public.motoboys set status = 'disponivel', status_em = now() where id = c.motoboy_id and status = 'em_corrida';
  update public.ofertas set status = 'cancelada' where corrida_id = p_corrida and status::text in ('pendente', 'aceita');
  update public.corridas set motoboy_id = null, motoboy_designado_id = null, aceita_em = null, iniciada_em = null, reservada_em = null,
         rodada = rodada + 1, status = 'sem_motoboy' where id = p_corrida;
  perform privado.evento(p_corrida, p_evento, jsonb_build_object('motoboy_id', c.motoboy_id));
  if privado.cfg_org_bool(c.organizacao_id, 'chamado_redespachar', true) then
    update public.corridas set status = 'aguardando_motoboy', modo_despacho = 'cascata' where id = p_corrida;
    perform privado.despachar(p_corrida);
  end if;
end;
$$;
revoke execute on function privado.devolver_rota(uuid, text) from public, anon, authenticated;

create or replace function public.pedir_cancelamento_corrida(p_corrida uuid, p_motivo text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c public.corridas%rowtype; v_id uuid;
begin
  select * into c from public.corridas where id = p_corrida;
  if not found or c.motoboy_id is distinct from auth.uid() or c.status::text not in ('aceita', 'em_andamento', 'reservada') then
    raise exception 'corrida_nao_e_sua' using errcode = '42501';
  end if;
  if not privado.cfg_org_bool(c.organizacao_id, 'chamado_motoboy_pode', true) then raise exception 'chamado_desligado' using errcode = '42501'; end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'informe_o_motivo' using errcode = '22023'; end if;
  if exists (select 1 from public.chamados_corrida where corrida_id = p_corrida and status = 'pendente') then raise exception 'chamado_ja_aberto' using errcode = '22023'; end if;
  insert into public.chamados_corrida (organizacao_id, corrida_id, motoboy_id, motivo) values (c.organizacao_id, p_corrida, auth.uid(), left(trim(p_motivo), 500))
  returning id into v_id;
  perform privado.evento(p_corrida, 'pediu_cancelamento', jsonb_build_object('motivo', trim(p_motivo)));
  perform privado.avisar_gestores(c.organizacao_id, jsonb_build_object('tipo', 'chamado_cancelar', 'chamado_id', v_id::text, 'corrida_id', p_corrida::text,
    'titulo', public.nome_publico(auth.uid()) || ' quer cancelar a rota ' || case when c.teste then 'T' else '#' end || c.numero,
    'texto', left(trim(p_motivo), 140)), 'corridas');
  -- sem resposta no prazo: o que a regra mandar (nada, aprovar)
  return privado.chamado_json(v_id);
end;
$$;

create or replace function public.retirar_chamado(p_chamado uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.chamados_corrida set status = 'retirado', respondido_em = now() where id = p_chamado and motoboy_id = auth.uid() and status = 'pendente';
  if not found then raise exception 'chamado_nao_encontrado' using errcode = '22023'; end if;
end;
$$;

-- gestor responde. p_penalizar: null = o que a regra manda; true/false = decide agora
create or replace function public.responder_chamado(p_chamado uuid, p_aprovar boolean, p_resposta text default null, p_penalizar boolean default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare h public.chamados_corrida%rowtype; c public.corridas%rowtype;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select * into h from public.chamados_corrida where id = p_chamado for update;
  if not found or not public.ve_org(h.organizacao_id) then raise exception 'chamado_nao_encontrado' using errcode = '22023'; end if;
  if h.status <> 'pendente' then raise exception 'chamado_ja_respondido' using errcode = '22023'; end if;
  select * into c from public.corridas where id = h.corrida_id;
  update public.chamados_corrida set status = case when p_aprovar then 'aprovado' else 'negado' end, resposta = nullif(trim(p_resposta), ''),
         respondido_por = auth.uid(), respondido_em = now() where id = p_chamado;
  if p_aprovar then
    if c.motoboy_id = h.motoboy_id and c.status::text in ('aceita', 'em_andamento', 'reservada') then
      perform privado.devolver_rota(c.id, 'cancelamento_aprovado');
    end if;
    if coalesce(p_penalizar, privado.cfg_org_num(h.organizacao_id, 'pen_pts_desistencia', 2) > 0) and not c.teste then
      perform privado.penalizar(h.organizacao_id, 'motoboy', h.motoboy_id, 'desistencia',
        greatest(privado.cfg_org_num(h.organizacao_id, 'pen_pts_desistencia', 2), case when p_penalizar then 1 else 0 end), 'Desistiu da rota (cancelamento aprovado)', c.id);
    end if;
  end if;
  perform privado.enviar_push(h.motoboy_id, jsonb_build_object('tipo', 'chamado_respondido', 'chamado_id', p_chamado::text, 'corrida_id', c.id::text,
    'aprovado', p_aprovar::text,
    'titulo', case when p_aprovar then 'Cancelamento aprovado' else 'Cancelamento negado' end,
    'texto', coalesce(nullif(trim(p_resposta), ''), case when p_aprovar then 'A rota saiu de você. Pode parar.' else 'Siga com a rota como combinado.' end)));
  return privado.chamado_json(p_chamado);
end;
$$;

-- o motoboy abandonou (depois de negado, ou sem chamado): tira a rota dele e penaliza
create or replace function public.marcar_abandono(p_corrida uuid, p_motivo text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare c public.corridas%rowtype;
begin
  if not public.is_gestor() or not public.ve_corrida(p_corrida) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  select * into c from public.corridas where id = p_corrida;
  if c.motoboy_id is null or c.status::text not in ('aceita', 'em_andamento', 'reservada') then raise exception 'rota_sem_motoboy' using errcode = '22023'; end if;
  update public.chamados_corrida set abandono = true where corrida_id = p_corrida and motoboy_id = c.motoboy_id and status = 'negado';
  if not c.teste then
    perform privado.penalizar(c.organizacao_id, 'motoboy', c.motoboy_id, 'abandono', privado.cfg_org_num(c.organizacao_id, 'pen_pts_abandono', 5),
      coalesce(nullif(trim(p_motivo), ''), 'Abandonou a rota'), p_corrida);
  end if;
  perform privado.enviar_push(c.motoboy_id, jsonb_build_object('tipo', 'cancelada', 'corrida_id', p_corrida::text));
  perform privado.devolver_rota(p_corrida, 'abandono');
end;
$$;

create or replace function public.chamados_abertos()
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when not public.is_gestor() then '[]'::jsonb else coalesce((
    select jsonb_agg(privado.chamado_json(h.id) order by h.criado_em desc) from public.chamados_corrida h
     where public.ve_org(h.organizacao_id) and (h.status = 'pendente' or h.criado_em > now() - interval '2 days')), '[]'::jsonb) end;
$$;
create or replace function public.meu_chamado(p_corrida uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select privado.chamado_json(h.id) from public.chamados_corrida h
   where h.corrida_id = p_corrida and h.motoboy_id = auth.uid() order by h.criado_em desc limit 1;
$$;

-- sem resposta no prazo: aprova sozinho (se a regra mandar)
create or replace function privado.processar_chamados()
returns void language plpgsql security definer set search_path = '' as $$
declare h record;
begin
  for h in select * from public.chamados_corrida where status = 'pendente' loop
    if privado.cfg_org_txt(h.organizacao_id, 'chamado_sem_resposta', 'nada') = 'aprovar'
       and h.criado_em < now() - make_interval(mins => privado.cfg_org_num(h.organizacao_id, 'chamado_prazo_min', 10)::int) then
      update public.chamados_corrida set status = 'expirado', resposta = 'Aprovado sozinho: sem resposta no prazo', respondido_em = now() where id = h.id;
      perform privado.devolver_rota(h.corrida_id, 'cancelamento_automatico');
      perform privado.enviar_push(h.motoboy_id, jsonb_build_object('tipo', 'chamado_respondido', 'chamado_id', h.id::text, 'corrida_id', h.corrida_id::text,
        'aprovado', 'true', 'titulo', 'Cancelamento aprovado', 'texto', 'Ninguém respondeu no prazo: a rota saiu de você.'));
    end if;
  end loop;
end;
$$;
revoke execute on function privado.processar_chamados() from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'cron') and exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'cron' and p.proname = 'schedule') then
    perform cron.schedule('pwex-chamados', '* * * * *', 'select privado.processar_chamados()');
  end if;
exception when others then null;
end $$;

revoke execute on function public.pedir_cancelamento_corrida(uuid, text), public.retirar_chamado(uuid), public.responder_chamado(uuid, boolean, text, boolean),
  public.marcar_abandono(uuid, text), public.chamados_abertos(), public.meu_chamado(uuid) from public, anon;
grant execute on function public.pedir_cancelamento_corrida(uuid, text), public.retirar_chamado(uuid), public.responder_chamado(uuid, boolean, text, boolean),
  public.marcar_abandono(uuid, text), public.chamados_abertos(), public.meu_chamado(uuid) to authenticated;

-- ===================================================================== pagamentos (Mercado Pago)
create table if not exists privado.pagamento_contas (
  id             uuid primary key default gen_random_uuid(),
  organizacao_id uuid unique references public.organizacoes (id) on delete cascade, -- null = conta da plataforma (Dev)
  access_token   text not null,
  public_key     text,
  conta_nome     text,
  atualizado_em  timestamptz not null default now(),
  atualizado_por uuid
);
create unique index if not exists pagamento_contas_plataforma on privado.pagamento_contas ((organizacao_id is null)) where organizacao_id is null;
revoke all on privado.pagamento_contas from public, anon, authenticated;

alter table public.organizacoes add column if not exists pagamento_destino text not null default 'padrao';
alter table public.organizacoes drop constraint if exists organizacoes_pagamento_destino_check;
alter table public.organizacoes add constraint organizacoes_pagamento_destino_check check (pagamento_destino in ('padrao', 'plataforma', 'empresa'));
insert into public.configuracoes (chave, valor) values ('pagamento_destino_padrao', '"empresa"') on conflict (chave) do nothing;

create table if not exists public.pagamentos (
  id             uuid primary key default gen_random_uuid(),
  organizacao_id uuid references public.organizacoes (id) on delete cascade,
  empresa_id     uuid references public.empresas (id) on delete set null,
  alvo           text not null check (alvo in ('pedido', 'fatura')),
  pedido_id      uuid references public.pedidos (id) on delete cascade,
  fatura_id      uuid references public.faturas (id) on delete cascade,
  provedor       text not null default 'mercadopago',
  provedor_id    text,
  metodo         text not null check (metodo in ('pix', 'cartao')),
  destino        text not null check (destino in ('plataforma', 'empresa')),
  status         text not null default 'pendente' check (status in ('pendente', 'aprovado', 'recusado', 'cancelado', 'expirado', 'reembolsado')),
  valor          numeric(12, 2) not null,
  qr_code        text,
  qr_base64      text,
  link           text,
  expira_em      timestamptz,
  detalhe        jsonb not null default '{}',
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now()
);
create index if not exists pagamentos_pedido on public.pagamentos (pedido_id);
create index if not exists pagamentos_fatura on public.pagamentos (fatura_id);
create index if not exists pagamentos_org on public.pagamentos (organizacao_id, criado_em desc);
alter table public.pagamentos enable row level security;
drop policy if exists pagamentos_leitura on public.pagamentos;
create policy pagamentos_leitura on public.pagamentos for select to authenticated
  using ((select public.is_gestor()) or empresa_id = (select public.minha_empresa_id()));
drop policy if exists org_isolamento on public.pagamentos;
create policy org_isolamento on public.pagamentos as restrictive for all to authenticated
  using (public.ve_org(organizacao_id) or empresa_id = (select public.minha_empresa_id())) with check (false);

-- para onde vai o dinheiro desta empresa (o Dev escolhe o padrão e a exceção por empresa)
create or replace function privado.pagamento_destino(p_org uuid)
returns text language sql stable security definer set search_path = '' as $$
  select case coalesce((select pagamento_destino from public.organizacoes where id = p_org), 'padrao')
    when 'padrao' then coalesce((select valor #>> '{}' from public.configuracoes where chave = 'pagamento_destino_padrao'), 'empresa')
    else (select pagamento_destino from public.organizacoes where id = p_org) end;
$$;
revoke execute on function privado.pagamento_destino(uuid) from public, anon, authenticated;

-- gestor: liga a conta Mercado Pago da empresa (o token nunca volta para a tela)
create or replace function public.pag_salvar_conta(p_token text, p_public_key text default null, p_nome text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_org uuid := public.minha_org();
begin
  if not public.is_gestor_pleno() or v_org is null then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if coalesce(trim(p_token), '') = '' then
    delete from privado.pagamento_contas where organizacao_id = v_org;
  else
    if trim(p_token) !~ '^(APP_USR|TEST)-' then raise exception 'token_invalido' using errcode = '22023'; end if;
    insert into privado.pagamento_contas (organizacao_id, access_token, public_key, conta_nome, atualizado_por)
    values (v_org, trim(p_token), nullif(trim(p_public_key), ''), nullif(trim(p_nome), ''), auth.uid())
    on conflict (organizacao_id) do update set access_token = excluded.access_token, public_key = excluded.public_key,
      conta_nome = coalesce(excluded.conta_nome, pagamento_contas.conta_nome), atualizado_em = now(), atualizado_por = auth.uid();
  end if;
  return public.pag_minha_conta();
end;
$$;
create or replace function public.pag_minha_conta()
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when not public.is_gestor() then null else jsonb_build_object(
    'conectada', k.id is not null, 'final', right(k.access_token, 4), 'teste', k.access_token like 'TEST-%', 'nome', k.conta_nome,
    'atualizado_em', k.atualizado_em,
    'destino', privado.pagamento_destino(public.minha_org()),
    'plataforma_conectada', exists (select 1 from privado.pagamento_contas where organizacao_id is null)) end
  from (select 1) x left join privado.pagamento_contas k on k.organizacao_id = public.minha_org();
$$;

-- Dev: conta da plataforma, padrão global e destino por empresa
create or replace function public.dev_pag_salvar_plataforma(p_token text, p_public_key text default null, p_nome text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  delete from privado.pagamento_contas where organizacao_id is null;
  if coalesce(trim(p_token), '') <> '' then
    if trim(p_token) !~ '^(APP_USR|TEST)-' then raise exception 'token_invalido' using errcode = '22023'; end if;
    insert into privado.pagamento_contas (organizacao_id, access_token, public_key, conta_nome, atualizado_por)
    values (null, trim(p_token), nullif(trim(p_public_key), ''), nullif(trim(p_nome), ''), auth.uid());
  end if;
  return public.dev_pag_contas();
end;
$$;
create or replace function public.dev_pag_destino(p_org uuid, p_destino text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  if p_org is null then
    if p_destino not in ('plataforma', 'empresa') then raise exception 'destino_invalido' using errcode = '22023'; end if;
    insert into public.configuracoes (chave, valor) values ('pagamento_destino_padrao', to_jsonb(p_destino))
    on conflict (chave) do update set valor = excluded.valor;
  else
    update public.organizacoes set pagamento_destino = p_destino where id = p_org;
  end if;
  return public.dev_pag_contas();
end;
$$;
create or replace function public.dev_pag_contas()
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when not public.is_dev() then null else jsonb_build_object(
    'padrao', coalesce((select valor #>> '{}' from public.configuracoes where chave = 'pagamento_destino_padrao'), 'empresa'),
    'plataforma', (select jsonb_build_object('conectada', true, 'final', right(access_token, 4), 'teste', access_token like 'TEST-%', 'nome', conta_nome, 'atualizado_em', atualizado_em)
                     from privado.pagamento_contas where organizacao_id is null),
    'empresas', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'nome', o.nome, 'escolha', o.pagamento_destino, 'destino', privado.pagamento_destino(o.id),
        'conectada', exists (select 1 from privado.pagamento_contas k where k.organizacao_id = o.id),
        'recebido_30d', (select coalesce(sum(valor), 0) from public.pagamentos g where g.organizacao_id = o.id and g.status = 'aprovado' and g.criado_em > now() - interval '30 days'))
        order by o.nome) from public.organizacoes o), '[]'::jsonb)) end;
$$;

-- --- só o servidor (service role) -----------------------------------------
-- prepara a cobrança: confere quem pede, o valor e qual conta usa
create or replace function public.pag_preparar(p_alvo text, p_id uuid, p_usuario uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_org uuid; v_emp uuid; v_valor numeric; v_desc text; v_dest text; v_tok text; v_email text; v_ok boolean;
begin
  if not privado.eh_servico() then raise exception 'apenas_servidor' using errcode = '42501'; end if;
  if p_alvo = 'pedido' then
    select organizacao_id, empresa_id, valor, 'Pedido #' || numero into v_org, v_emp, v_valor, v_desc
      from public.pedidos where id = p_id and cobranca = 'pre_pago' and pagamento_status = 'pendente' and status not in ('cancelado', 'recusado');
  elsif p_alvo = 'fatura' then
    select organizacao_id, empresa_id, total, 'Fatura #' || numero into v_org, v_emp, v_valor, v_desc
      from public.faturas where id = p_id and status = 'emitida';
  end if;
  if v_emp is null and v_org is null then return jsonb_build_object('erro', 'nada_a_pagar'); end if;
  if coalesce(v_valor, 0) <= 0 then return jsonb_build_object('erro', 'sem_valor'); end if;
  -- quem pede: o cliente dono, ou um gestor da empresa
  select exists (select 1 from public.perfis p where p.id = p_usuario and (p.empresa_id = v_emp
            or (p.organizacao_id = v_org and p.papeis && array['gestor', 'supervisor']::public.papel_usuario[]) or 'dev' = any (p.papeis)))
    into v_ok;
  if not v_ok then return jsonb_build_object('erro', 'sem_permissao'); end if;
  v_dest := privado.pagamento_destino(v_org);
  select access_token into v_tok from privado.pagamento_contas where organizacao_id is not distinct from case when v_dest = 'plataforma' then null else v_org end;
  if v_tok is null then return jsonb_build_object('erro', 'conta_nao_ligada', 'destino', v_dest); end if;
  select email into v_email from auth.users where id = p_usuario;
  return jsonb_build_object('token', v_tok, 'destino', v_dest, 'organizacao_id', v_org, 'empresa_id', v_emp, 'valor', round(v_valor, 2),
    'descricao', v_desc || ' · ' || coalesce((select coalesce(nome_app, nome) from public.organizacoes where id = v_org), 'Delibra'),
    'email', v_email, 'empresa_nome', (select nome from public.empresas where id = v_emp),
    'pix_aberto', (select to_jsonb(g) - 'detalhe' from public.pagamentos g where g.metodo = 'pix' and g.status = 'pendente' and g.expira_em > now() + interval '2 minutes'
                    and case when p_alvo = 'pedido' then g.pedido_id = p_id else g.fatura_id = p_id end and round(g.valor, 2) = round(v_valor, 2) order by g.criado_em desc limit 1));
end;
$$;
create or replace function public.pag_registrar(p jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
  if not privado.eh_servico() then raise exception 'apenas_servidor' using errcode = '42501'; end if;
  insert into public.pagamentos (id, organizacao_id, empresa_id, alvo, pedido_id, fatura_id, provedor_id, metodo, destino, valor, qr_code, qr_base64, link, expira_em, detalhe)
  values (coalesce((p ->> 'id')::uuid, gen_random_uuid()), (p ->> 'organizacao_id')::uuid, (p ->> 'empresa_id')::uuid, p ->> 'alvo', (p ->> 'pedido_id')::uuid, (p ->> 'fatura_id')::uuid, p ->> 'provedor_id',
          p ->> 'metodo', p ->> 'destino', (p ->> 'valor')::numeric, p ->> 'qr_code', p ->> 'qr_base64', p ->> 'link', (p ->> 'expira_em')::timestamptz, coalesce(p -> 'detalhe', '{}'))
  returning id into v_id;
  if p ->> 'alvo' = 'pedido' then update public.pedidos set pagamento_metodo = p ->> 'metodo' where id = (p ->> 'pedido_id')::uuid and pagamento_status = 'pendente'; end if;
  return v_id;
end;
$$;
-- token da conta que criou este pagamento (para conferir no Mercado Pago)
create or replace function public.pag_token_de(p_pagamento uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when not privado.eh_servico() then null else jsonb_build_object('token', k.access_token, 'provedor_id', g.provedor_id, 'status', g.status,
    'valor', g.valor, 'metodo', g.metodo, 'alvo', g.alvo, 'pedido_id', g.pedido_id, 'fatura_id', g.fatura_id, 'empresa_id', g.empresa_id, 'organizacao_id', g.organizacao_id) end
    from public.pagamentos g
    left join privado.pagamento_contas k on k.organizacao_id is not distinct from case when g.destino = 'plataforma' then null else g.organizacao_id end
   where g.id = p_pagamento;
$$;
-- resultado conferido no Mercado Pago: aprovado → pedido/fatura pagos (e o pedido segue para virar rota)
create or replace function public.pag_atualizar(p_pagamento uuid, p_status text, p_provedor_id text default null, p_detalhe jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare g public.pagamentos%rowtype; v_teste boolean;
begin
  if not privado.eh_servico() then raise exception 'apenas_servidor' using errcode = '42501'; end if;
  select * into g from public.pagamentos where id = p_pagamento for update;
  if not found then raise exception 'pagamento_nao_encontrado' using errcode = '22023'; end if;
  if p_status not in ('pendente', 'aprovado', 'recusado', 'cancelado', 'expirado', 'reembolsado') then raise exception 'status_invalido' using errcode = '22023'; end if;
  update public.pagamentos set status = p_status, provedor_id = coalesce(p_provedor_id, provedor_id), detalhe = detalhe || coalesce(p_detalhe, '{}'), atualizado_em = now()
   where id = p_pagamento;
  if p_status = 'aprovado' and g.status <> 'aprovado' then
    if g.alvo = 'pedido' then
      update public.pedidos set pagamento_status = 'pago', pago_em = now(), pagamento_metodo = g.metodo, pagamento_ref = 'mp:' || coalesce(p_provedor_id, g.provedor_id)
       where id = g.pedido_id and pagamento_status = 'pendente' returning teste into v_teste;
      if found then
        perform privado.evento_pedido(g.pedido_id, 'pago', jsonb_build_object('metodo', g.metodo, 'mercadopago', coalesce(p_provedor_id, g.provedor_id)));
        perform privado.roteirizar(coalesce(v_teste, false));
        perform privado.avisar_gestores(g.organizacao_id, jsonb_build_object('tipo', 'pedido_novo', 'pedido_id', g.pedido_id::text,
          'titulo', 'Pagamento confirmado', 'texto', (select coalesce(e.nome, 'Cliente') from public.empresas e where e.id = g.empresa_id) || ' pagou ' ||
          replace(to_char(g.valor, 'FM999G999D00'), '.', ',') || ' por ' || case when g.metodo = 'pix' then 'PIX' else 'cartão' end), 'pedidos');
      end if;
    else
      update public.faturas set status = 'paga', paga_em = now(), pagamento_metodo = g.metodo, pagamento_ref = 'mp:' || coalesce(p_provedor_id, g.provedor_id)
       where id = g.fatura_id and status = 'emitida';
      update public.pedidos set pagamento_status = 'pago', pago_em = now(), pagamento_metodo = coalesce(pagamento_metodo, g.metodo) where fatura_id = g.fatura_id;
    end if;
  end if;
  return (select to_jsonb(x) - 'detalhe' from public.pagamentos x where x.id = p_pagamento);
end;
$$;
-- testar a conta ligada (servidor): token e o nome da conta no Mercado Pago
create or replace function public.pag_token_conta(p_org uuid)
returns text language sql stable security definer set search_path = '' as $$
  select case when privado.eh_servico() then (select access_token from privado.pagamento_contas where organizacao_id is not distinct from p_org) end;
$$;
create or replace function public.pag_nome_conta(p_org uuid, p_nome text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not privado.eh_servico() then raise exception 'apenas_servidor' using errcode = '42501'; end if;
  update privado.pagamento_contas set conta_nome = left(p_nome, 80) where organizacao_id is not distinct from p_org;
end;
$$;
revoke execute on function public.pag_token_conta(uuid), public.pag_nome_conta(uuid, text) from public, anon, authenticated;
grant execute on function public.pag_token_conta(uuid), public.pag_nome_conta(uuid, text) to service_role;
revoke execute on function public.pag_preparar(text, uuid, uuid), public.pag_registrar(jsonb), public.pag_token_de(uuid),
  public.pag_atualizar(uuid, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.pag_preparar(text, uuid, uuid), public.pag_registrar(jsonb), public.pag_token_de(uuid),
  public.pag_atualizar(uuid, text, text, jsonb) to service_role;
revoke execute on function public.pag_salvar_conta(text, text, text), public.pag_minha_conta(), public.dev_pag_salvar_plataforma(text, text, text),
  public.dev_pag_destino(uuid, text), public.dev_pag_contas() from public, anon;
grant execute on function public.pag_salvar_conta(text, text, text), public.pag_minha_conta(), public.dev_pag_salvar_plataforma(text, text, text),
  public.dev_pag_destino(uuid, text), public.dev_pag_contas() to authenticated;

-- ===================================================================== aprendizado que generaliza
-- Regras de pagamento: cada chave vota sozinha, nas decisões parecidas (mesmo cliente pesa mais;
-- depois tipo de pedido, número de entregas, km e horário). Número: a mediana, se os valores
-- forem parecidos. Texto/sim-não: o que ganhou com folga.
create or replace function privado.aprender_regras(p_corrida uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  c public.corridas%rowtype; v_ctx jsonb; v_min int; v_res jsonb := '{}'; k record; v_vals jsonb; v_n int; v_med numeric; v_top text; v_topn int;
begin
  select * into c from public.corridas where id = p_corrida;
  v_ctx := privado.contexto_rota(p_corrida);
  v_min := greatest(privado.pol_num('aprender_minimo', 3, c.empresa_id, null, c.tipo_pedido)::int, 1);
  for k in
    with parecidas as (
      select d.dados -> 'depois' r,
             (case when d.empresa_id is not distinct from c.empresa_id then 3 else 0 end)
           + (case when d.tipo_pedido is not distinct from c.tipo_pedido then 1 else 0 end)
           + (case when abs(coalesce((d.dados #>> '{contexto,entregas}')::numeric, 0) - coalesce((v_ctx ->> 'entregas')::numeric, 0)) <= 1 then 1 else 0 end)
           + (case when coalesce((v_ctx ->> 'km')::numeric, 0) > 0 and abs(coalesce((d.dados #>> '{contexto,km}')::numeric, 0) - (v_ctx ->> 'km')::numeric) <= greatest((v_ctx ->> 'km')::numeric * 0.35, 1) then 1 else 0 end)
           + (case when abs(coalesce((d.dados #>> '{contexto,hora}')::numeric, 12) - coalesce((v_ctx ->> 'hora')::numeric, 12)) <= 2 then 0.5 else 0 end) pontos
        from public.decisoes_rota d
       where d.acao = 'regras' and d.organizacao_id is not distinct from c.organizacao_id and d.criada_em > now() - interval '90 days'
         and jsonb_typeof(d.dados -> 'depois') = 'object' and d.dados -> 'depois' <> '{}'
       order by d.criada_em desc limit 60)
    select e.key chave, jsonb_agg(e.value) vals, count(*) n
      from parecidas p, jsonb_each(p.r) e
     where p.pontos >= case when privado.pol_bool('aprender_entre_clientes', false, c.empresa_id, null, c.tipo_pedido) then 2.5 else 3 end
     group by e.key
  loop
    if k.n < v_min then continue; end if;
    if (select bool_and(jsonb_typeof(x) = 'number') from jsonb_array_elements(k.vals) x) then
      select percentile_cont(0.5) within group (order by x::text::numeric) into v_med from jsonb_array_elements(k.vals) x;
      -- parecidos: ≥ 60% dentro de ±15% da mediana
      if (select count(*) filter (where abs(x::text::numeric - v_med) <= greatest(abs(v_med) * 0.15, 0.01)) from jsonb_array_elements(k.vals) x) >= ceil(k.n * 0.6) then
        v_res := v_res || jsonb_build_object(k.chave, round(v_med, 2));
      end if;
    else
      select x::text, count(*) into v_top, v_topn from jsonb_array_elements(k.vals) x group by x::text order by count(*) desc limit 1;
      if v_topn >= ceil(k.n * 0.6) and v_topn >= v_min then v_res := v_res || jsonb_build_object(k.chave, v_top::jsonb); end if;
    end if;
  end loop;
  return v_res;
end;
$$;
revoke execute on function privado.aprender_regras(uuid) from public, anon, authenticated;

create or replace function privado.aplicar_aprendido(p_corrida uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare c public.corridas%rowtype; v_r jsonb; v_p uuid; d record; v_raio numeric; v_novas jsonb; v_ok boolean; v_ordem uuid[];
begin
  select * into c from public.corridas where id = p_corrida;
  if not found then return; end if;
  -- regras de pagamento
  if c.pag_regras is null and privado.pol_bool('aprender_regras_rota', false, c.empresa_id, null, c.tipo_pedido) then
    v_r := privado.aprender_regras(p_corrida);
    if v_r is not null and v_r <> '{}' then
      update public.corridas set pag_regras = v_r where id = p_corrida;
      insert into public.decisoes_rota (acao, corrida_id, empresa_id, tipo_pedido, dados, organizacao_id)
      values ('aprendido', p_corrida, c.empresa_id, c.tipo_pedido, jsonb_build_object('regras', v_r), c.organizacao_id);
    end if;
  end if;
  -- percurso: as mesmas paradas (perto) de um percurso que você já editou → mesma ordem e mesmo caminho
  if c.percurso_via is null and privado.pol_bool('aprender_percurso', true, c.empresa_id, null, c.tipo_pedido) then
    v_raio := privado.pol_num('aprender_percurso_raio_m', 250, c.empresa_id, null, c.tipo_pedido);
    select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'lat', p.lat, 'lng', p.lng, 'tipo', p.tipo) order by p.ordem), '[]') into v_novas
      from public.paradas p where p.corrida_id = p_corrida;
    for d in select x.dados from public.decisoes_rota x
              where x.acao = 'percurso' and x.organizacao_id is not distinct from c.organizacao_id and x.criada_em > now() - interval '120 days'
                and jsonb_array_length(coalesce(x.dados -> 'paradas', '[]')) = jsonb_array_length(v_novas)
              order by x.criada_em desc limit 30 loop
      -- cada parada antiga (na ordem dela) acha uma nova do mesmo tipo dentro do raio
      v_ordem := '{}'; v_ok := true;
      for k in 0 .. jsonb_array_length(v_novas) - 1 loop
        v_p := null;
        select (n ->> 'id')::uuid into v_p from jsonb_array_elements(v_novas) n
         where n ->> 'tipo' = d.dados -> 'paradas' -> k ->> 'tipo' and not ((n ->> 'id')::uuid = any (v_ordem))
           and privado.dist_m((n ->> 'lat')::float8, (n ->> 'lng')::float8, (d.dados -> 'paradas' -> k ->> 'lat')::float8, (d.dados -> 'paradas' -> k ->> 'lng')::float8) <= v_raio
         order by privado.dist_m((n ->> 'lat')::float8, (n ->> 'lng')::float8, (d.dados -> 'paradas' -> k ->> 'lat')::float8, (d.dados -> 'paradas' -> k ->> 'lng')::float8) limit 1;
        if v_p is null then v_ok := false; exit; end if;
        v_ordem := v_ordem || v_p;
      end loop;
      if v_ok then
        -- duas etapas: a ordem é única por rota
        update public.paradas set ordem = ordem + 10000 where corrida_id = p_corrida;
        update public.paradas p set ordem = x.i - 1 from unnest(v_ordem) with ordinality x(pid, i) where p.id = x.pid;
        update public.corridas set percurso_via = d.dados -> 'via', percurso_aprendido = true where id = p_corrida;
        insert into public.decisoes_rota (acao, corrida_id, empresa_id, tipo_pedido, dados, organizacao_id)
        values ('aprendido', p_corrida, c.empresa_id, c.tipo_pedido, jsonb_build_object('percurso', true), c.organizacao_id);
        exit;
      end if;
    end loop;
  end if;
end;
$$;
revoke execute on function privado.aplicar_aprendido(uuid) from public, anon, authenticated;
alter table public.corridas add column if not exists percurso_aprendido boolean not null default false;
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
    otimizada_em = now(), percurso_aprendido = false
  where id = p_corrida;
  if jsonb_typeof(p_via) = 'array' and jsonb_array_length(p_via) > 0 then
    perform privado.decisao('percurso', p_corrida, jsonb_build_object('via', p_via, 'paradas',
      (select jsonb_agg(jsonb_build_object('lat', p.lat, 'lng', p.lng, 'tipo', p.tipo) order by p.ordem) from public.paradas p where p.corrida_id = p_corrida)));
  end if;
end;
$$;
create or replace function public.meu_perfil()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', p.id,
    'nome', p.nome,
    'foto_url', p.foto_url,
    'papeis', to_jsonb(p.papeis),
    'gestor', 'gestor' = any (p.papeis) or 'dev' = any (p.papeis) or 'supervisor' = any (p.papeis),
    'motoboy', 'motoboy' = any (p.papeis),
    'dev', 'dev' = any (p.papeis),
    'cor_tema', p.cor_tema,
    'modo_teste', coalesce(m.modo_teste, p.modo_teste),
    'suspenso_ate', case when m.suspenso_ate > now() then m.suspenso_ate end, 'suspenso_motivo', case when m.suspenso_ate > now() then m.suspenso_motivo end,
    'raio', jsonb_build_object('km', m.raio_km, 'modo', coalesce(m.raio_modo, 'posicao'), 'lat', m.raio_lat, 'lng', m.raio_lng),
    'modulos', coalesce((
      select jsonb_object_agg(md.chave,
        'dev' = any (p.papeis) or (md.ligado and (md.papeis is null or p.papeis && md.papeis)))
        from public.modulos md
    ), '{}'::jsonb),
    'holerite_visivel', privado.pol_bool('motoboy_ve_holerite', true, null, p.id, null),
    'supervisor', 'supervisor' = any (p.papeis),
    'permissoes', p.permissoes,
    'dev_oculto', p.dev_oculto,
    'organizacao', (select jsonb_build_object('id', o.id, 'nome', o.nome, 'nome_app', o.nome_app, 'nome_topo', o.nome_topo, 'logo', o.logo_url, 'logo_escala', o.logo_escala, 'logo_original', o.logo_original_url, 'brilho_cor', o.logo_brilho_cor, 'brilho', o.logo_brilho, 'fonte', o.fonte_nome, 'cor', o.cor, 'status', o.status, 'suspensa_motivo', case when o.status in ('suspensa', 'cancelada') then o.suspensa_motivo end)
                      from public.organizacoes o where o.id = case when 'dev' = any (p.papeis) and p.dev_vazio then null else coalesce(case when 'dev' = any (p.papeis) then p.org_em_foco end, p.organizacao_id) end),
    'configuracoes', coalesce((
      select jsonb_object_agg(k, v) from jsonb_each(public.ajustes()) e(k, v)
       where k in ('intervalo_corrida_s', 'intervalo_economia_s', 'disponivel_envio_min',
                       'disponivel_distancia_m', 'raio_chegada_m', 'teste_admin_ignora_local', 'oferta_segundos',
                       'quadro_mostra_enderecos', 'quadro_mostra_itens', 'simulador_ligado', 'simulador_velocidade_kmh',
                       'motoboy_edita_veiculo', 'mapa_offline_some_h', 'mapa_offline_esmaecer', 'veiculo_obrigatorio',
                       'rota_provedor', 'rota_perfil', 'chat_ligado', 'chat_geral', 'chat_fotos', 'ping_envio_s',
                       'chat_compartilhar', 'chat_compartilhar_tipos', 'chat_grupos_equipe', 'pagamento_na_plataforma', 'compartilhar_motoboy_resumo')
    ), '{}'::jsonb)
    -- o que pode mudar por motoboy (regra dele > geral)
    || jsonb_build_object(
      'intervalo_corrida_s', privado.pol_num('intervalo_corrida_s', 6, null, p.id, null),
      'intervalo_economia_s', privado.pol_num('intervalo_economia_s', 20, null, p.id, null),
      'disponivel_envio_min', privado.pol_num('disponivel_envio_min', 3, null, p.id, null),
      'disponivel_distancia_m', privado.pol_num('disponivel_distancia_m', 300, null, p.id, null),
      'ping_distancia_m', privado.pol_num('ping_distancia_m', 20, null, p.id, null),
      'ping_precisao_max_m', privado.pol_num('ping_precisao_max_m', 60, null, p.id, null),
      'navegacao_ligada', privado.pol_bool('navegacao_ligada', true, null, p.id, null),
      'navegacao_voz', privado.pol_bool('navegacao_voz', true, null, p.id, null),
      'navegacao_recalcular_m', privado.pol_num('navegacao_recalcular_m', 60, null, p.id, null),
      'navegacao_na_notificacao', privado.pol_bool('navegacao_na_notificacao', true, null, p.id, null))
  )
  from public.perfis p
  left join public.motoboys m on m.id = p.id
  where p.id = auth.uid();
$$;

-- leitura pela API só com as políticas acima; escrita só pelas funções
revoke all on public.penalidades, public.chamados_corrida, public.pagamentos from anon;
revoke insert, update, delete on public.penalidades, public.chamados_corrida, public.pagamentos from authenticated;
grant select on public.penalidades, public.chamados_corrida, public.pagamentos to authenticated;
grant all on public.penalidades, public.chamados_corrida, public.pagamentos to service_role;

notify pgrst, 'reload schema';
