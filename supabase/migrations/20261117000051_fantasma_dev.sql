-- Lote 50 · Delibra Dev: o Fantasma. Ver claude/plano-lote-50-controle-dev.md

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. Regras do Dev (o Fantasma): quem vê o quê, quando e por quê
-- ═══════════════════════════════════════════════════════════════════════════
create table if not exists public.regras_dev (
  id          uuid primary key default gen_random_uuid(),
  chave       text not null,                       -- ajuste, 'modulo:<chave>', 'acao:<acao>' ou 'especial_*'
  escopo      text not null default 'global' check (escopo in ('global', 'empresa', 'cliente', 'pessoa', 'papel')),
  alvo        text,                                 -- id da empresa/cliente/pessoa ou nome do papel
  valor       jsonb not null default 'true',
  condicoes   jsonb not null default '{}',          -- dias [1-7], de/ate 'HH:MM', papeis [], teste bool, aparelho 'app'|'site'
  porque      text,
  valida_de   timestamptz,
  valida_ate  timestamptz,
  ativo       boolean not null default true,
  versao      int not null default 1,
  criado_por  uuid references public.perfis (id) on delete set null,
  criado_em   timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  check (escopo = 'global' or alvo is not null)
);
create index if not exists regras_dev_chave on public.regras_dev (chave) where ativo;
create table if not exists public.regras_dev_historico (
  id        bigserial primary key,
  regra_id  uuid not null,
  versao    int not null,
  operacao  text not null,
  dados     jsonb not null,
  por       uuid,
  em        timestamptz not null default now()
);
alter table public.regras_dev enable row level security;
alter table public.regras_dev_historico enable row level security;
drop policy if exists regras_dev_dev on public.regras_dev;
create policy regras_dev_dev on public.regras_dev for all to authenticated using (public.is_dev()) with check (public.is_dev());
drop policy if exists regras_dev_hist_dev on public.regras_dev_historico;
create policy regras_dev_hist_dev on public.regras_dev_historico for select to authenticated using (public.is_dev());
revoke all on public.regras_dev, public.regras_dev_historico from anon;
grant select, insert, update, delete on public.regras_dev to authenticated;
grant select on public.regras_dev_historico to authenticated;

create or replace function privado.trg_regras_dev()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then
    new.versao := old.versao + 1;
    new.atualizado_em := now();
  end if;
  if tg_op = 'DELETE' then
    insert into public.regras_dev_historico (regra_id, versao, operacao, dados, por) values (old.id, old.versao, 'apagada', to_jsonb(old), auth.uid());
    return old;
  end if;
  insert into public.regras_dev_historico (regra_id, versao, operacao, dados, por)
  values (new.id, new.versao, case tg_op when 'INSERT' then 'criada' else 'mudada' end, to_jsonb(new), auth.uid());
  return new;
end;
$$;
drop trigger if exists regras_dev_versao on public.regras_dev;
create trigger regras_dev_versao before insert or update or delete on public.regras_dev for each row execute function privado.trg_regras_dev();

-- O motor único: dada uma pessoa e uma chave, qual regra do Dev vale agora (ou null = segue o sistema)?
-- O Dev só é afetado pelas regras que ele mesmo fez para si (escopo pessoa, alvo = ele).
create or replace function privado.decide(p_pessoa uuid, p_chave text, p_ctx jsonb default '{}')
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_papeis  public.papel_usuario[];
  v_org     uuid;
  v_cliente uuid;
  v_teste   boolean;
  v_dev     boolean := false;
  v_tz      text;
  v_agora   timestamp;
  r         public.regras_dev%rowtype;
begin
  if p_pessoa is not null then
    select p.papeis, p.organizacao_id, p.empresa_id, coalesce(p.modo_teste, false) into v_papeis, v_org, v_cliente, v_teste
      from public.perfis p where p.id = p_pessoa;
    v_dev := coalesce('dev' = any (v_papeis), false);
  end if;
  v_org := coalesce(nullif(p_ctx ->> 'org', '')::uuid, v_org);
  v_cliente := coalesce(nullif(p_ctx ->> 'cliente', '')::uuid, v_cliente);
  if v_cliente is not null and v_org is null then select organizacao_id into v_org from public.empresas where id = v_cliente; end if;
  for r in
    select * from public.regras_dev x
     where x.chave = p_chave and x.ativo
       and (x.valida_de is null or x.valida_de <= now()) and (x.valida_ate is null or x.valida_ate > now())
       and case
             when v_dev then x.escopo = 'pessoa' and x.alvo = p_pessoa::text
             else (x.escopo = 'global')
               or (x.escopo = 'empresa' and x.alvo = v_org::text)
               or (x.escopo = 'cliente' and x.alvo = v_cliente::text)
               or (x.escopo = 'pessoa'  and x.alvo = p_pessoa::text)
               or (x.escopo = 'papel'   and x.alvo = any (v_papeis::text[]))
           end
     order by case x.escopo when 'pessoa' then 1 when 'cliente' then 2 when 'empresa' then 3 when 'papel' then 4 else 5 end, x.atualizado_em desc
  loop
    -- condições: papéis, modo teste, aparelho, dias e horário (no fuso da empresa)
    if jsonb_typeof(r.condicoes -> 'papeis') = 'array' and jsonb_array_length(r.condicoes -> 'papeis') > 0
       and not exists (select 1 from jsonb_array_elements_text(r.condicoes -> 'papeis') e where e = any (coalesce(v_papeis::text[], '{}'))) then continue; end if;
    if r.condicoes ? 'teste' and (r.condicoes ->> 'teste')::boolean is distinct from coalesce(v_teste, false) then continue; end if;
    if r.condicoes ? 'aparelho' and coalesce(p_ctx ->> 'aparelho', '') <> '' and r.condicoes ->> 'aparelho' <> p_ctx ->> 'aparelho' then continue; end if;
    if r.condicoes ?| array['dias', 'de', 'ate'] then
      if v_tz is null then
        v_tz := case when p_chave = 'fuso_horario' or v_org is null then 'America/Sao_Paulo' else coalesce(privado.fuso_org(v_org), 'America/Sao_Paulo') end;
        v_agora := now() at time zone v_tz;
      end if;
      if jsonb_typeof(r.condicoes -> 'dias') = 'array' and jsonb_array_length(r.condicoes -> 'dias') > 0
         and not exists (select 1 from jsonb_array_elements_text(r.condicoes -> 'dias') e where e::int = extract(isodow from v_agora)::int) then continue; end if;
      if coalesce(r.condicoes ->> 'de', '') <> '' and coalesce(r.condicoes ->> 'ate', '') <> '' then
        if (r.condicoes ->> 'de')::time <= (r.condicoes ->> 'ate')::time then
          if not (v_agora::time >= (r.condicoes ->> 'de')::time and v_agora::time < (r.condicoes ->> 'ate')::time) then continue; end if;
        else -- atravessa a meia-noite
          if not (v_agora::time >= (r.condicoes ->> 'de')::time or v_agora::time < (r.condicoes ->> 'ate')::time) then continue; end if;
        end if;
      end if;
    end if;
    return jsonb_build_object('valor', r.valor, 'regra', r.id, 'escopo', r.escopo, 'versao', r.versao,
      'motivo', 'Regra do Dev' || coalesce(': ' || nullif(r.porque, ''), '') ||
                case r.escopo when 'pessoa' then ' (só esta pessoa)' when 'cliente' then ' (este cliente)' when 'empresa' then ' (esta empresa)'
                              when 'papel' then ' (todos os ' || r.alvo || 's)' else ' (todo o sistema)' end);
  end loop;
  return null;
end;
$$;
-- atalho barato: só roda o motor quando existe regra ativa para a chave
create or replace function privado.regra(p_pessoa uuid, p_chave text, p_ctx jsonb default '{}')
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when exists (select 1 from public.regras_dev where chave = p_chave and ativo) then privado.decide(p_pessoa, p_chave, p_ctx) end;
$$;
revoke execute on function privado.decide(uuid, text, jsonb), privado.regra(uuid, text, jsonb) from public, anon, authenticated;

create or replace function privado.pol(p_chave text, p_cliente uuid default null, p_motoboy uuid default null, p_tipo text default null)
returns jsonb language sql stable security definer set search_path = '' as $$
  with o as (select x.* from public.organizacoes x where x.id = privado.org_contexto(p_cliente, p_motoboy))
  select coalesce(
    -- a cobrança da plataforma vem do contrato da empresa (licença/isenta = 0%)
    case when p_chave = 'dev_pct' then (select case when o.cobranca_modelo <> 'percentual' then '0'::jsonb end from o) end,
    (nullif(current_setting('pwex.regras', true), '')::jsonb -> p_chave),
    (privado.regra(coalesce(p_motoboy, auth.uid()), p_chave, jsonb_build_object('cliente', p_cliente, 'org', (select o.id from o), 'tipo', p_tipo)) -> 'valor'),
    (select valor from public.politicas where p_motoboy is not null and escopo = 'motoboy' and alvo = p_motoboy::text and chave = p_chave),
    (select valor from public.politicas where p_cliente is not null and escopo = 'cliente' and alvo = p_cliente::text and chave = p_chave),
    (select valor from public.politicas where p_tipo is not null and escopo = 'tipo' and chave = p_chave
        and alvo in ((select o.id::text from o) || ':' || p_tipo, p_tipo) order by (alvo = p_tipo) limit 1),
    case when p_chave = 'dev_pct' then (select to_jsonb(o.cobranca_pct) from o) end,
    (select valor from public.politicas where escopo = 'organizacao' and alvo = (select o.id::text from o) and chave = p_chave
        and p_chave !~ '^(app_|dev_|saas_)'),
    (select valor from public.configuracoes where chave = p_chave));
$$;

create or replace function privado.modulo_ligado(p_chave text, p_pessoa uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(
    (privado.regra(p_pessoa, 'modulo:' || p_chave) ->> 'valor')::boolean,
    (select 'dev' = any (p.papeis) or (coalesce(me.ligado, m.ligado) and (m.papeis is null or p.papeis && m.papeis))
       from public.modulos m join public.perfis p on p.id = p_pessoa
       left join public.modulos_empresa me on me.chave = m.chave and me.organizacao_id = coalesce(p.organizacao_id, (select e.organizacao_id from public.empresas e where e.id = p.empresa_id))
      where m.chave = p_chave),
    true);
$$;
-- o Dev também passa pelo motor: só o que ele mesmo definiu para si muda alguma coisa
create or replace function public.modulo_ativo(p_chave text)
returns boolean language sql stable security definer set search_path = '' as $$
  select privado.modulo_ligado(p_chave, auth.uid());
$$;
-- trava no servidor: módulo desligado não roda, nem pelo app antigo nem pela API
create or replace function privado.exigir_modulo(p_chave text)
returns void language plpgsql stable security definer set search_path = '' as $$
declare v_ok boolean;
begin
  if auth.uid() is not null then v_ok := privado.modulo_ligado(p_chave, auth.uid());
  else
    v_ok := coalesce((select coalesce(me.ligado, m.ligado) from public.modulos m
                        left join public.modulos_empresa me on me.chave = m.chave and me.organizacao_id = nullif(current_setting('pwex.org', true), '')::uuid
                       where m.chave = p_chave), true);
  end if;
  if not v_ok then raise exception 'modulo_desligado' using errcode = '42501', detail = p_chave; end if;
end;
$$;
revoke execute on function privado.exigir_modulo(text) from public, anon, authenticated;

-- permissões especiais: pessoa > cliente (empresa do cliente) > empresa > sistema; regra do Dev antes de tudo
create or replace function privado.especial(p_chave text, p_pessoa uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(
    (privado.regra(p_pessoa, p_chave) ->> 'valor')::boolean,
    public.is_dev() or exists (select 1 from public.perfis where id = p_pessoa and 'dev' = any (papeis)) or coalesce(
      (select (valor #>> '{}')::boolean from public.politicas where escopo = 'motoboy' and alvo = p_pessoa::text and chave = p_chave),
      (select (valor #>> '{}')::boolean from public.politicas where escopo = 'cliente' and chave = p_chave
          and alvo = (select empresa_id::text from public.perfis where id = p_pessoa)),
      (select (valor #>> '{}')::boolean from public.politicas where escopo = 'organizacao' and chave = p_chave
          and alvo = (select coalesce(p.organizacao_id, e.organizacao_id)::text from public.perfis p left join public.empresas e on e.id = p.empresa_id where p.id = p_pessoa)),
      (select (valor #>> '{}')::boolean from public.configuracoes where chave = p_chave),
      false));
$$;

create or replace function privado.exigir_acao(p_acao text)
returns void language plpgsql stable security definer set search_path = '' as $$
declare v jsonb;
begin
  if auth.uid() is null then return; end if;
  v := privado.regra(auth.uid(), 'acao:' || p_acao);
  if v is not null then
    if (v ->> 'valor')::boolean then return; end if;
    raise exception 'acao_bloqueada' using errcode = '42501', detail = p_acao;
  end if;
  if public.is_dev() then return; end if;
  if not privado.gestor_pode_acao(public.minha_org(), p_acao)
     or coalesce((select (k.acoes ->> p_acao)::boolean from public.perfis pf join public.cargos k on k.id = pf.cargo_id where pf.id = auth.uid()), true) = false then
    raise exception 'acao_bloqueada' using errcode = '42501', detail = p_acao;
  end if;
end;
$$;
create or replace function public.posso(p_acao text)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((privado.regra(auth.uid(), 'acao:' || p_acao) ->> 'valor')::boolean,
                  public.is_dev() or privado.gestor_pode_acao(public.minha_org(), p_acao));
$$;
create or replace function public.pode(p_acao text)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((privado.regra(auth.uid(), 'acao:' || p_acao) ->> 'valor')::boolean, case
    when auth.uid() is null or public.is_gestor_pleno() then true
    when public.is_supervisor() then coalesce(
      (select (p.permissoes ->> p_acao)::boolean from public.perfis p where p.id = auth.uid() and jsonb_typeof(p.permissoes -> p_acao) = 'boolean'),
      p_acao in ('pedidos', 'rotas', 'motoboys', 'cadastrar', 'chat', 'mapa', 'clientes'))
    else false end);
$$;

-- ajustes gerais e da empresa: regra do Dev (global/empresa) antes do valor salvo
create or replace function privado.cfg_txt(p_chave text, p_padrao text)
returns text language sql stable security definer set search_path = '' as $$
  select coalesce(privado.regra(auth.uid(), p_chave) -> 'valor' #>> '{}', (select valor #>> '{}' from public.configuracoes where chave = p_chave), p_padrao);
$$;
create or replace function privado.cfg_bool(p_chave text, p_padrao boolean)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((privado.regra(auth.uid(), p_chave) -> 'valor' #>> '{}')::boolean, (select (valor #>> '{}')::boolean from public.configuracoes where chave = p_chave), p_padrao);
$$;
create or replace function privado.cfg_num(p_chave text, p_padrao numeric)
returns numeric language sql stable security definer set search_path = '' as $$
  select coalesce((privado.regra(auth.uid(), p_chave) -> 'valor' #>> '{}')::numeric, (select (valor #>> '{}')::numeric from public.configuracoes where chave = p_chave), p_padrao);
$$;
create or replace function privado.cfg_org_txt(p_org uuid, p_chave text, p_padrao text)
returns text language sql stable security definer set search_path = '' as $$
  select coalesce(
    privado.regra(auth.uid(), p_chave, jsonb_build_object('org', p_org)) -> 'valor' #>> '{}',
    (select valor #>> '{}' from public.politicas where escopo = 'organizacao' and alvo = p_org::text and chave = p_chave),
    (select valor #>> '{}' from public.configuracoes where chave = p_chave),
    p_padrao);
$$;
create or replace function privado.cfg_org_bool(p_org uuid, p_chave text, p_padrao boolean)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(
    (privado.regra(auth.uid(), p_chave, jsonb_build_object('org', p_org)) -> 'valor' #>> '{}')::boolean,
    (select (valor #>> '{}')::boolean from public.politicas where escopo = 'organizacao' and alvo = p_org::text and chave = p_chave),
    (select (valor #>> '{}')::boolean from public.configuracoes where chave = p_chave),
    p_padrao);
$$;
create or replace function privado.cfg_org_num(p_org uuid, p_chave text, p_padrao numeric)
returns numeric language sql stable security definer set search_path = '' as $$
  select coalesce(
    (privado.regra(auth.uid(), p_chave, jsonb_build_object('org', p_org)) -> 'valor' #>> '{}')::numeric,
    (select (valor #>> '{}')::numeric from public.politicas where escopo = 'organizacao' and alvo = p_org::text and chave = p_chave),
    (select (valor #>> '{}')::numeric from public.configuracoes where chave = p_chave),
    p_padrao);
$$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. Um módulo por funcionalidade (todos ligados: nada muda até o Dev mexer)
-- ═══════════════════════════════════════════════════════════════════════════
insert into public.modulos (chave, nome, descricao, grupo, ordem) values
  ('pedidos',               'Pedidos', 'Clientes e gestores criam pedidos de coleta e entrega.', 'Pedidos', 100),
  ('editar_pedido',         'Editar pedido', 'Mudar um pedido depois de criado, com as mesmas opções.', 'Pedidos', 101),
  ('tipos_pedido',          'Tipos de pedido', 'Escolher o tipo (documento, comida, carga…) ao pedir.', 'Pedidos', 102),
  ('itens_pedido',          'Itens do pedido', 'Lista do que vai em cada coleta e cada entrega.', 'Pedidos', 103),
  ('pedido_urgente',        'Pedido urgente', 'Marcar o pedido como urgente.', 'Pedidos', 104),
  ('series',                'Pedidos que se repetem', 'Pedidos fixos por dia da semana.', 'Pedidos', 105),
  ('orcamento_editavel',    'Orçamento editável', 'O gestor ajusta o valor do pedido antes de aprovar.', 'Pedidos', 106),
  ('objetos_cliente',       'Objetos do cliente', 'Objetos que o cliente cadastra e escolhe ao pedir.', 'Pedidos', 107),
  ('historico_rotas',       'Histórico de rotas', 'Lista de rotas passadas com filtros, no site e no app.', 'Rotas', 110),
  ('ficha_rota',            'Ficha da rota do motoboy', 'O motoboy abre a ficha das rotas que fez.', 'Rotas', 111),
  ('rota_planejada',        'Rota planejada no mapa', 'Linha branca com o caminho previsto.', 'Rotas', 112),
  ('extensao_rota',         'Extensão de rota', 'Encaixar pedidos novos numa rota em andamento.', 'Rotas', 113),
  ('navegacao',             'Navegação', 'Botão para abrir o caminho no Maps/Waze e a faixa de navegação.', 'Rotas', 114),
  ('pular_parada',          'Pular parada', 'O motoboy pede para pular uma parada.', 'Rotas', 115),
  ('comprovantes',          'Fotos e comprovantes', 'Foto e assinatura na coleta e na entrega.', 'Rotas', 116),
  ('rastreio',              'Link de rastreio', 'Link para o destinatário acompanhar a entrega.', 'Rotas', 117),
  ('avaliacoes',            'Avaliações', 'Clientes e destinatários avaliam a entrega.', 'Rotas', 118),
  ('painel_dia',            'Hoje', 'O painel do dia do gestor.', 'Gestão', 120),
  ('mapa_ao_vivo',          'Mapa ao vivo', 'Os motoboys no mapa em tempo real.', 'Gestão', 121),
  ('cargos',                'Cargos e supervisores', 'Criar cargos com permissões próprias.', 'Equipe', 130),
  ('penalidades',           'Penalidades e chamados', 'Advertências, chamados e respostas.', 'Equipe', 131),
  ('emergencia',            'Botão de emergência', 'O motoboy pede socorro pelo app.', 'Equipe', 132),
  ('holerite',              'Holerite', 'Recibo de pagamento do motoboy e do gestor.', 'Carteira', 140),
  ('faturas',               'Faturas', 'Faturas dos clientes.', 'Carteira', 141),
  ('pagamento_online',      'Pagamento online', 'Cobrança por PIX/cartão pelo Mercado Pago.', 'Carteira', 142),
  ('precos',                'Tabela de preços', 'Preço por distância, tipo e cliente.', 'Carteira', 143),
  ('api_externa',           'API para integrações', 'Outros sistemas criam e consultam pedidos.', 'Sistema', 150),
  ('campos_personalizados', 'Campos personalizados', 'Campos extras nos pedidos, paradas e cadastros.', 'Sistema', 151),
  ('auditoria',             'Auditoria', 'Registro de quem mudou o quê.', 'Sistema', 152),
  ('ajuda',                 'Central de ajuda', 'Artigos de ajuda no site e no app.', 'Sistema', 153),
  ('tour',                  'Tour guiado', 'O passeio pelas telas na primeira vez.', 'Sistema', 154),
  ('novidades',             'Novidades da versão', 'O que mudou em cada atualização.', 'Sistema', 155),
  ('dois_passos',           'Verificação em duas etapas', 'Código extra no login.', 'Sistema', 156),
  ('avisos',                'Avisos do sistema', 'Faixa com avisos do Dev no topo das telas.', 'Sistema', 157)
on conflict (chave) do nothing;

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
  v_editar  uuid := nullif(dados ->> 'editar_id', '')::uuid;
  v_antes   public.pedidos%rowtype;
begin
  perform privado.exigir_modulo('pedidos');
  if v_editar is not null then perform privado.exigir_modulo('editar_pedido'); end if;
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
       and not ((now() at time zone (select privado.fuso()))::time between privado.pol_txt('cliente_pedido_de', '', v_cli, null, v_tp)::time
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

  if v_editar is not null then
    -- editar: valida, tira das rotas que ainda não saíram, troca pontos e itens e recalcula (mesmas regras da criação)
    if v_gestor then perform privado.exigir_acao('editar_pedido'); end if;
    perform privado.pedido_editavel(v_editar, v_gestor);
    select * into v_antes from public.pedidos where id = v_editar;
    v_teste := v_antes.teste;
    perform privado.tirar_pedido_das_rotas(v_editar, true);
    delete from public.pedido_itens where pedido_id = v_editar;
    delete from public.pedido_pontos where pedido_id = v_editar;
    update public.pedidos set empresa_id = case when v_gestor then v_cli else empresa_id end,
           cliente_nome = case when v_gestor and v_cli is null then nullif(trim(dados ->> 'cliente_nome'), '') else cliente_nome end,
           tipo = v_tipo, tipo_pedido = v_tp, quando = v_quando, urgente = coalesce((dados ->> 'urgente')::boolean, false),
           observacoes = nullif(left(dados ->> 'observacoes', 1000), ''), distancia_estimada_m = (v_orc ->> 'distancia_m')::int,
           orcamento = v_orc, valor_calculado = (v_orc ->> 'total')::numeric,
           valor = case when v_antes.pagamento_status = 'pago' then v_antes.valor else (v_orc ->> 'total')::numeric end,
           valor_dev = round(case when v_antes.pagamento_status = 'pago' then v_antes.valor else (v_orc ->> 'total')::numeric end * dev_pct / 100, 2),
           regras = case when v_gestor then v_regras else regras end,
           status = case when v_gestor then 'aprovado' else 'recebido' end,
           aprovado_em = case when v_gestor then now() else null end,
           revisado_por = case when v_gestor then auth.uid() end, revisado_em = case when v_gestor then now() end
     where id = v_editar returning id into v_id;
    v_status := case when v_gestor then 'aprovado' else 'recebido' end;
  else
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
  end if;
  -- campos próprios do pedido e veículo pedido
  update public.pedidos set
    extras = privado.limpar_extras(privado.org_contexto(v_cli, null), 'pedido', v_tp, dados -> 'extras', case when v_gestor then 'gestor' else 'cliente' end),
    veiculo = case when nullif(dados ->> 'veiculo', '') in ('moto', 'carro', 'bicicleta', 'van', 'outro')
                    and (v_gestor or privado.pol_bool('cliente_escolhe_veiculo', false, v_cli, null, v_tp)) then dados ->> 'veiculo' end
   where id = v_id;

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
    if p ? 'extras' then
      update public.pedido_pontos set extras = privado.limpar_extras(privado.org_contexto(v_cli, null), 'ponto', v_tp, p -> 'extras',
        case when v_gestor then 'gestor' else 'cliente' end, false) where id = v_pid;
    end if;
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
  perform privado.evento_pedido(v_id, case when v_editar is not null then 'editado' else 'criado' end, jsonb_build_object('origem', case when v_gestor then 'gestor' else 'cliente' end, 'total', v_orc -> 'total'));
  if v_status = 'aprovado' then perform privado.roteirizar(v_teste); end if;
  return v_id;
end;
$$;
create or replace function public.criar_serie(dados jsonb, p_datas timestamptz[])
returns uuid[] language plpgsql security definer set search_path = '' as $$
declare
  v_serie uuid := gen_random_uuid();
  v_ids   uuid[] := '{}';
  d       timestamptz;
begin
  perform privado.exigir_modulo('series');
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  -- o padrão é só pedido (vira rota pelo sistema); rota à mão só se o Dev ligar, para todas ou para a empresa
  if not public.is_dev() and not privado.cfg_org_bool(public.minha_org(), 'dev_criar_rota_manual', false)
     and coalesce(current_setting('pwex.serie', true), '') = '' then
    raise exception 'criar_rota_desligado' using errcode = '42501';
  end if;
  if p_datas is null or cardinality(p_datas) = 0 then raise exception 'sem_datas' using errcode = '22023'; end if;
  if cardinality(p_datas) > 60 then raise exception 'datas_demais' using errcode = '22023'; end if;
  foreach d in array (select array_agg(x order by x) from unnest(p_datas) x) loop
    perform set_config('pwex.serie', '1', true);
    v_ids := v_ids || public.criar_corrida(dados || jsonb_build_object('agendada_para', d, 'serie_id', v_serie));
  end loop;
  return v_ids;
end;
$$;
create or replace function public.historico_rotas(p jsonb default '{}')
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_de timestamptz; v_ate timestamptz; v_teste boolean; v_busca text := nullif(trim(p ->> 'busca'), '');
begin
  perform privado.exigir_modulo('historico_rotas');
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  v_de := ((coalesce(nullif(p ->> 'de', '')::date, (now() at time zone (select privado.fuso()))::date - 30))::timestamp) at time zone (select privado.fuso());
  v_ate := ((coalesce(nullif(p ->> 'ate', '')::date, (now() at time zone (select privado.fuso()))::date) + 1)::timestamp) at time zone (select privado.fuso());
  v_teste := coalesce((p ->> 'teste')::boolean, (select modo_teste from public.perfis where id = auth.uid()), false);
  return (select coalesce(jsonb_agg(x order by x ->> 'quando' desc), '[]') from (
    select jsonb_build_object(
      'id', c.id, 'numero', c.numero, 'status', c.status, 'teste', c.teste, 'tipo_pedido', c.tipo_pedido,
      'quando', coalesce(c.concluida_em, c.cancelada_em, c.agendada_para, c.criada_em),
      'criada_em', c.criada_em, 'concluida_em', c.concluida_em, 'cancelada_em', c.cancelada_em,
      'motoboy_id', c.motoboy_id, 'motoboy', public.nome_publico(c.motoboy_id),
      'cliente', coalesce((select string_agg(distinct coalesce(em.nome, pd.cliente_nome), ', ') from public.paradas x join public.pedidos pd on pd.id = x.pedido_id
                            left join public.empresas em on em.id = pd.empresa_id where x.corrida_id = c.id), (select e.nome from public.empresas e where e.id = c.empresa_id), c.cliente_nome),
      'pedidos', (select coalesce(jsonb_agg(distinct pd.numero), '[]') from public.paradas x join public.pedidos pd on pd.id = x.pedido_id where x.corrida_id = c.id),
      'entregas', (select count(*) from public.paradas x where x.corrida_id = c.id and x.tipo = 'entrega'),
      'feitas', (select count(*) from public.paradas x where x.corrida_id = c.id and x.status::text = 'concluida'),
      'km', round(coalesce(c.distancia_real_m, c.distancia_planejada_m, 0) / 1000.0, 1),
      'valor', c.valor, 'valor_motoboy', c.valor_motoboy,
      'minutos', case when c.concluida_em is not null and coalesce(c.aceita_em, c.iniciada_em) is not null
                      then round(extract(epoch from c.concluida_em - coalesce(c.aceita_em, c.iniciada_em)) / 60) end,
      'problemas', (select count(*) from public.chamados_corrida h where h.corrida_id = c.id)
                 + (select count(*) from public.paradas x where x.corrida_id = c.id and (x.local_ignorado or x.feita_offline)),
      'nota', (select round(avg(a.nota)::numeric, 1) from public.avaliacoes a where a.corrida_id = c.id)) x
    from public.corridas c
   where public.ve_org(c.organizacao_id) and c.teste = v_teste
     and coalesce(c.concluida_em, c.cancelada_em, c.agendada_para, c.criada_em) >= v_de
     and coalesce(c.concluida_em, c.cancelada_em, c.agendada_para, c.criada_em) < v_ate
     and (nullif(p ->> 'motoboy', '') is null or c.motoboy_id = (p ->> 'motoboy')::uuid)
     and (nullif(p ->> 'status', '') is null or c.status::text = any (string_to_array(p ->> 'status', ',')))
     and (nullif(p ->> 'cliente', '') is null or c.empresa_id = (p ->> 'cliente')::uuid
          or exists (select 1 from public.paradas x join public.pedidos pd on pd.id = x.pedido_id where x.corrida_id = c.id and pd.empresa_id = (p ->> 'cliente')::uuid))
     and (v_busca is null or c.numero::text = ltrim(v_busca, '#T')
          or exists (select 1 from public.paradas x left join public.pedidos pd on pd.id = x.pedido_id where x.corrida_id = c.id
                      and (pd.numero::text = ltrim(v_busca, '#P') or x.endereco ilike '%' || v_busca || '%' or x.recebedor_nome ilike '%' || v_busca || '%')))
   order by coalesce(c.concluida_em, c.cancelada_em, c.agendada_para, c.criada_em) desc
   limit least(coalesce((p ->> 'limite')::int, 200), 500)) y);
end;
$$;
create or replace function public.ficha_rota(p_corrida uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare c public.corridas%rowtype;
begin
  perform privado.exigir_modulo('historico_rotas');
  if not public.is_gestor() or not public.ve_corrida(p_corrida) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  select * into c from public.corridas where id = p_corrida;
  return jsonb_build_object(
    'rota', to_jsonb(c) - 'rota_planejada' - 'trajeto' || jsonb_build_object('motoboy', public.nome_publico(c.motoboy_id),
             'cliente', coalesce((select e.nome from public.empresas e where e.id = c.empresa_id), c.cliente_nome)),
    'paradas', (select coalesce(jsonb_agg(to_jsonb(x) || jsonb_build_object('pedido_numero', pd.numero, 'cliente', coalesce(em.nome, pd.cliente_nome),
                   'itens', (select coalesce(jsonb_agg(jsonb_build_object('descricao', i.descricao, 'quantidade', i.quantidade, 'categoria', k.nome, 'icone', k.icone)), '[]')
                              from public.pedido_itens i left join public.categorias_produto k on k.id = i.categoria_id
                             where i.pedido_id = x.pedido_id and (i.entrega_id = x.pedido_ponto_id or i.coleta_id = x.pedido_ponto_id)))
                 order by x.ordem), '[]')
                 from public.paradas x left join public.pedidos pd on pd.id = x.pedido_id left join public.empresas em on em.id = pd.empresa_id
                where x.corrida_id = c.id),
    'pedidos', (select coalesce(jsonb_agg(jsonb_build_object('id', pd.id, 'numero', pd.numero, 'status', pd.status, 'cliente', coalesce(em.nome, pd.cliente_nome),
                   'valor', pd.valor, 'pagamento', pd.pagamento_status, 'criado_em', pd.criado_em, 'observacoes', pd.observacoes, 'extras', pd.extras,
                   'tipo_pedido', pd.tipo_pedido, 'urgente', pd.urgente, 'quando', pd.quando,
                   'outras_rotas', (select coalesce(jsonb_agg(distinct jsonb_build_object('id', k.id, 'numero', k.numero, 'status', k.status)), '[]')
                                      from public.paradas y join public.corridas k on k.id = y.corrida_id where y.pedido_id = pd.id and k.id <> c.id))), '[]')
                 from public.pedidos pd left join public.empresas em on em.id = pd.empresa_id
                where pd.id in (select x.pedido_id from public.paradas x where x.corrida_id = c.id)),
    'eventos', (select coalesce(jsonb_agg(jsonb_build_object('tipo', e.tipo, 'dados', e.dados, 'quando', e.criado_em, 'autor', public.nome_publico(e.autor)) order by e.criado_em), '[]')
                  from public.eventos_corrida e where e.corrida_id = c.id),
    'chamados', (select coalesce(jsonb_agg(jsonb_build_object('tipo', h.tipo, 'status', h.status, 'motivo', h.motivo, 'resposta', h.resposta,
                   'criado_em', h.criado_em, 'respondido_em', h.respondido_em, 'parada_id', h.parada_id) order by h.criado_em), '[]')
                  from public.chamados_corrida h where h.corrida_id = c.id),
    'avaliacoes', (select coalesce(jsonb_agg(jsonb_build_object('nota', a.nota, 'comentario', a.comentario, 'autor', a.autor, 'quando', a.criado_em)), '[]')
                     from public.avaliacoes a where a.corrida_id = c.id),
    'ofertas', (select coalesce(jsonb_agg(jsonb_build_object('motoboy', public.nome_publico(o.motoboy_id), 'status', o.status, 'rodada', o.rodada,
                   'distancia_m', o.distancia_m, 'quando', o.criada_em) order by o.criada_em), '[]') from public.ofertas o where o.corrida_id = c.id),
    'pagamento', jsonb_build_object('valor', c.valor, 'motoboy', c.valor_motoboy, 'gestao', c.valor_gestao, 'calculo', c.pag_calculo,
                   'ajuste', c.pag_ajuste, 'ajuste_motivo', c.pag_ajuste_motivo));
end;
$$;
create or replace function public.minha_ficha_rota(p_corrida uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare c public.corridas%rowtype; v_valores boolean := privado.ve_valores(auth.uid());
begin
  perform privado.exigir_modulo('ficha_rota');
  select * into c from public.corridas where id = p_corrida;
  if c.id is null or c.motoboy_id is distinct from auth.uid() then raise exception 'corrida_nao_e_sua' using errcode = '42501'; end if;
  return jsonb_build_object(
    'id', c.id, 'numero', c.numero, 'teste', c.teste, 'status', c.status, 'tipo_pedido', c.tipo_pedido,
    'criada_em', c.criada_em, 'aceita_em', c.aceita_em, 'concluida_em', c.concluida_em, 'cancelada_em', c.cancelada_em,
    'distancia_m', coalesce(c.distancia_real_m, c.distancia_planejada_m), 'rota_planejada', c.rota_planejada,
    'cliente', coalesce((select e.nome from public.empresas e where e.id = c.empresa_id), c.cliente_nome),
    'valor', case when v_valores then c.valor_motoboy end,
    'calculo', case when v_valores then c.pag_calculo end,
    'ajuste', case when v_valores and c.pag_ajuste_mostrar then c.pag_ajuste end,
    'ajuste_motivo', case when v_valores and c.pag_ajuste_mostrar then c.pag_ajuste_motivo end,
    'paradas', (select coalesce(jsonb_agg(jsonb_build_object('ordem', x.ordem, 'tipo', x.tipo, 'endereco', x.endereco, 'lat', x.lat, 'lng', x.lng, 'status', x.status,
                   'chegou_em', x.chegou_em, 'concluida_em', x.concluida_em, 'recebedor_nome', x.recebedor_nome, 'local_ignorado', x.local_ignorado,
                   'feita_offline', x.feita_offline, 'liberada_local', x.liberada_local, 'tem_foto', x.foto_path is not null, 'tem_assinatura', x.assinatura_path is not null,
                   'pedido_numero', (select pd.numero from public.pedidos pd where pd.id = x.pedido_id)) order by x.ordem), '[]')
                 from public.paradas x where x.corrida_id = c.id),
    'chamados', (select coalesce(jsonb_agg(jsonb_build_object('tipo', h.tipo, 'status', h.status, 'motivo', h.motivo, 'resposta', h.resposta, 'criado_em', h.criado_em) order by h.criado_em), '[]')
                  from public.chamados_corrida h where h.corrida_id = c.id and h.motoboy_id = auth.uid()),
    'avaliacoes', (select coalesce(jsonb_agg(jsonb_build_object('nota', a.nota, 'comentario', a.comentario)), '[]')
                     from public.avaliacoes a where a.corrida_id = c.id and privado.cfg_bool('motoboy_ve_notas', true)));
end;
$$;
create or replace function public.painel_do_dia(p_dia date)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_hoje timestamptz := (coalesce(p_dia, (now() at time zone (select privado.fuso()))::date)::timestamp) at time zone (select privado.fuso());
  v_fim timestamptz := v_hoje + interval '1 day';
  v_teste boolean := coalesce((select p.modo_teste from public.perfis p where p.id = auth.uid()), false);
begin
  perform privado.exigir_modulo('painel_dia');
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  return jsonb_build_object(
    'pedidos_hoje', (select count(*) from public.pedidos p where public.ve_org(p.organizacao_id) and p.criado_em >= v_hoje and p.criado_em < v_fim),
    'para_revisar', (select count(*) from public.pedidos p where public.ve_org(p.organizacao_id) and p.status::text = 'recebido'),
    'rotas_ativas', (select count(*) from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text in ('aceita', 'em_andamento')),
    'rotas_esperando', (select count(*) from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text in ('aguardando_motoboy', 'sem_motoboy', 'montada')),
    'sem_motoboy', (select count(*) from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'sem_motoboy'),
    'concluidas_hoje', (select count(*) from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'concluida' and c.concluida_em >= v_hoje and c.concluida_em < v_fim),
    'faturamento_hoje', (select coalesce(sum(c.valor), 0) from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'concluida' and c.concluida_em >= v_hoje and c.concluida_em < v_fim),
    'gestao_hoje', (select coalesce(sum(c.valor_gestao), 0) from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'concluida' and c.concluida_em >= v_hoje and c.concluida_em < v_fim),
    'km_hoje', (select round(coalesce(sum(coalesce(c.distancia_real_m, c.distancia_planejada_m)), 0) / 1000.0, 1) from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'concluida' and c.concluida_em >= v_hoje and c.concluida_em < v_fim),
    'motoboys_online', (select count(*) from public.motoboys m join public.perfis p on p.id = m.id where public.ve_org(p.organizacao_id) and m.status::text <> 'offline' and p.modo_teste = v_teste),
    'motoboys_em_rota', (select count(*) from public.motoboys m join public.perfis p on p.id = m.id where public.ve_org(p.organizacao_id) and m.status::text = 'em_corrida' and p.modo_teste = v_teste),
    'emergencias', (select count(*) from public.emergencias e where public.ve_org(e.organizacao_id) and e.resolvida_em is null),
    'chamados', (select count(*) from public.chamados_corrida h where public.ve_org(h.organizacao_id) and h.status = 'pendente'),
    'aguardando_confirmacao', (select count(*) from public.corridas c where public.ve_org(c.organizacao_id) and c.aguardando_confirmacao),
    'nota_media_30d', (select round(avg(a.nota)::numeric, 1) from public.avaliacoes a where public.ve_org(a.organizacao_id) and a.criado_em > now() - interval '30 days'),
    'notas_ruins_hoje', (select count(*) from public.avaliacoes a where public.ve_org(a.organizacao_id) and a.criado_em >= v_hoje and a.criado_em < v_fim and a.nota <= 2),
    'por_hora', (select coalesce(jsonb_agg(jsonb_build_object('hora', h, 'rotas', n) order by h), '[]') from (
                   select extract(hour from c.concluida_em at time zone (select privado.fuso()))::int h, count(*) n from public.corridas c
                    where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'concluida' and c.concluida_em >= v_hoje and c.concluida_em < v_fim group by 1) x),
    'canceladas_hoje', (select count(*) from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'cancelada' and c.cancelada_em >= v_hoje and c.cancelada_em < v_fim),
    'entregas_hoje', (select count(*) from public.paradas x join public.corridas c on c.id = x.corrida_id where public.ve_org(c.organizacao_id) and c.teste = v_teste
                       and x.tipo::text = 'entrega' and x.status::text = 'concluida' and x.concluida_em >= v_hoje and x.concluida_em < v_fim),
    'tempo_medio_min', (select round(avg(extract(epoch from (c.concluida_em - coalesce(c.aceita_em, c.iniciada_em))) / 60.0))::int from public.corridas c
                         where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'concluida' and c.concluida_em >= v_hoje and c.concluida_em < v_fim and coalesce(c.aceita_em, c.iniciada_em) is not null),
    'pagar_motoboys_hoje', (select coalesce(sum(c.valor_motoboy), 0) from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'concluida' and c.concluida_em >= v_hoje and c.concluida_em < v_fim),
    'ontem_concluidas', (select count(*) from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'concluida'
                          and c.concluida_em >= v_hoje - interval '1 day' and c.concluida_em < least(now(), v_fim) - interval '1 day'),
    'hora_agora', case when now() < v_fim then extract(hour from now() at time zone (select privado.fuso()))::int else 23 end,
    'dia', to_char(v_hoje at time zone (select privado.fuso()), 'YYYY-MM-DD'), 'hoje', now() >= v_hoje and now() < v_fim,
    'em_andamento', (select coalesce(jsonb_agg(x order by x->>'desde'), '[]') from (
                   select jsonb_build_object('id', c.id, 'numero', c.numero, 'motoboy', split_part(public.nome_publico(c.motoboy_id), ' ', 1), 'status', c.status::text,
                     'feitas', (select count(*) from public.paradas p where p.corrida_id = c.id and p.status::text = 'concluida'),
                     'total', (select count(*) from public.paradas p where p.corrida_id = c.id), 'desde', coalesce(c.aceita_em, c.criada_em)) x
                     from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text in ('aceita', 'em_andamento')
                     order by coalesce(c.aceita_em, c.criada_em) limit 8) y),
    'top_motoboys', (select coalesce(jsonb_agg(jsonb_build_object('nome', split_part(public.nome_publico(x.motoboy_id), ' ', 1), 'rotas', x.n) order by x.n desc), '[]') from (
                   select c.motoboy_id, count(*) n from public.corridas c where public.ve_org(c.organizacao_id) and c.teste = v_teste and c.status::text = 'concluida' and c.concluida_em >= v_hoje and c.concluida_em < v_fim and c.motoboy_id is not null
                    group by 1 order by 2 desc limit 5) x));
end;
$$;
create or replace function public.avaliar_pedido(p_pedido uuid, p_nota int, p_comentario text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform privado.exigir_modulo('avaliacoes');
  if not exists (select 1 from public.pedidos where id = p_pedido and empresa_id = privado.minha_empresa()) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  return privado.registrar_avaliacao(p_pedido, 'cliente', auth.uid(), p_nota, p_comentario);
end;
$$;
create or replace function public.acionar_emergencia(p_lat double precision default null, p_lng double precision default null, p_precisao real default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_org uuid; v_id uuid; v_cor uuid; v_nome text; r record; v_dados jsonb; v_mb record;
begin
  perform privado.exigir_modulo('emergencia');
  if auth.uid() is null then raise exception 'nao_autenticado' using errcode = '28000'; end if;
  select organizacao_id into v_org from public.perfis where id = auth.uid();
  if not privado.cfg_org_bool(v_org, 'emergencia_ligada', true) then raise exception 'emergencia_desligada' using errcode = '42501'; end if;
  select id into v_cor from public.corridas where motoboy_id = auth.uid() and status::text in ('aceita', 'em_andamento') order by aceita_em desc limit 1;
  if p_lat is null then select lat, lng into v_mb from public.motoboys where id = auth.uid(); p_lat := v_mb.lat; p_lng := v_mb.lng; end if;
  insert into public.emergencias (organizacao_id, motoboy_id, corrida_id, lat, lng, precisao_m) values (v_org, auth.uid(), v_cor, p_lat, p_lng, p_precisao) returning id into v_id;
  v_nome := public.nome_publico(auth.uid());
  v_dados := jsonb_build_object('tipo', 'emergencia', 'emergencia_id', v_id::text, 'corrida_id', coalesce(v_cor::text, ''), 'lat', coalesce(p_lat::text, ''), 'lng', coalesce(p_lng::text, ''),
    'titulo', 'EMERGÊNCIA: ' || v_nome, 'texto', v_nome || ' apertou o botão de emergência. Toque para ver onde ele está.');
  for r in
    select p.id from public.perfis p
     where p.organizacao_id = v_org and p.id <> auth.uid()
       and (('gestor' = any (p.papeis) and privado.cfg_org_bool(v_org, 'emergencia_avisa_gestor', true))
         or ('supervisor' = any (p.papeis) and privado.cfg_org_bool(v_org, 'emergencia_avisa_supervisor', true)))
    union
    -- o Dev recebe se ligou para todos, para esta empresa ou para este motoboy
    select p.id from public.perfis p
     where 'dev' = any (p.papeis) and (privado.cfg_bool('dev_emergencia_receber', false)
           or coalesce(privado.cfg('dev_emergencia_orgs', '[]'::jsonb) ? v_org::text, false)
           or exists (select 1 from public.politicas x where x.escopo = 'motoboy' and x.alvo = auth.uid()::text and x.chave = 'dev_emergencia_receber' and x.valor = 'true'::jsonb))
  loop
    begin perform privado.enviar_push(r.id, v_dados); exception when others then null; end;
  end loop;
  if v_cor is not null then perform privado.evento(v_cor, 'emergencia', jsonb_build_object('lat', p_lat, 'lng', p_lng)); end if;
  return jsonb_build_object('id', v_id);
end;
$$;
create or replace function public.pedir_pular_parada(p_parada uuid, p_motivo text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p public.paradas%rowtype; c public.corridas%rowtype; v_id uuid;
begin
  perform privado.exigir_modulo('pular_parada');
  select * into p from public.paradas where id = p_parada;
  select * into c from public.corridas where id = p.corrida_id;
  if c.id is null or c.motoboy_id is distinct from auth.uid() or c.status::text not in ('aceita', 'em_andamento') then raise exception 'corrida_nao_e_sua' using errcode = '42501'; end if;
  if not privado.cfg_bool('saas_pular_parada', true) or not privado.pol_bool('motoboy_pede_pular', true, c.empresa_id, auth.uid(), c.tipo_pedido) then
    raise exception 'pular_desligado' using errcode = '42501';
  end if;
  if coalesce(trim(p_motivo), '') = '' then raise exception 'informe_o_motivo' using errcode = '22023'; end if;
  if exists (select 1 from public.chamados_corrida where corrida_id = c.id and tipo = 'pular' and status = 'pendente') then raise exception 'chamado_ja_aberto' using errcode = '22023'; end if;
  insert into public.chamados_corrida (organizacao_id, corrida_id, motoboy_id, motivo, tipo, parada_id)
  values (c.organizacao_id, c.id, auth.uid(), left(trim(p_motivo), 500), 'pular', p_parada) returning id into v_id;
  perform privado.evento(c.id, 'pediu_pular', jsonb_build_object('parada', p.ordem, 'motivo', trim(p_motivo)));
  perform privado.avisar_gestores(c.organizacao_id, jsonb_build_object('tipo', 'chamado_pular', 'chamado_id', v_id::text, 'corrida_id', c.id::text,
    'titulo', public.nome_publico(auth.uid()) || ' pede para liberar a parada ' || (p.ordem + 1), 'texto', left(trim(p_motivo), 140)), 'pedidos');
  return privado.chamado_json(v_id);
end;
$$;
create or replace function public.gerar_rastreio(p_pedido uuid, p_ponto uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare pd public.pedidos%rowtype; v_tok text; v_h numeric;
begin
  perform privado.exigir_modulo('rastreio');
  select * into pd from public.pedidos where id = p_pedido;
  if not found or not coalesce(pd.empresa_id = privado.minha_empresa() or (public.is_gestor() and public.ve_org(pd.organizacao_id)), false) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if not privado.cfg_bool('saas_rastreio', true) or not privado.pol_bool('rastreio_ligado', true, pd.empresa_id) then raise exception 'rastreio_desligado' using errcode = '42501'; end if;
  v_h := privado.cfg_num('rastreio_validade_h', 24);
  select token into v_tok from public.rastreios where pedido_id = p_pedido and ponto_id is not distinct from p_ponto and (expira_em is null or expira_em > now()) limit 1;
  if v_tok is null then
    insert into public.rastreios (pedido_id, ponto_id, criado_por, expira_em) values (p_pedido, p_ponto, auth.uid(), null) returning token into v_tok;
  end if;
  return jsonb_build_object('token', v_tok, 'url', coalesce(nullif(privado.cfg('dev_site_url', '""'::jsonb) #>> '{}', ''), '') || '/r/' || v_tok,
                            'envio', privado.cfg('rastreio_envio', '"copiar"'::jsonb) #>> '{}');
end;
$$;
create or replace function public.gerar_fatura(p_cliente uuid, p_inicio date, p_fim date, p_teste boolean default false)
returns uuid language plpgsql security definer set search_path = '' as $$
begin
  perform privado.exigir_modulo('faturas');
  if p_cliente is not null and not exists (select 1 from public.empresas e where e.id = p_cliente and public.ve_org(e.organizacao_id)) then
    raise exception 'sem_permissao' using errcode = '42501';
  end if;
  return privado.gerar_fatura_sem_guarda(p_cliente, p_inicio, p_fim, p_teste);
end;
$$;
create or replace function public.api_criar_chave(p_empresa uuid, p_nome text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_org uuid := privado.api_exigir_gestor(p_empresa); v_chave text; v_id uuid;
begin
  perform privado.exigir_modulo('api_externa');
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
create or replace function public.estender_rota(p_nova uuid, p_motoboy uuid, p_perguntar boolean default true)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_ativa uuid;
begin
  perform privado.exigir_modulo('extensao_rota');
  -- outra empresa: recusa
  if p_nova is not null and not public.ve_corrida(p_nova) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if p_motoboy is not null and not public.ve_pessoa(p_motoboy) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select id into v_ativa from public.corridas where motoboy_id = p_motoboy and status::text in ('aceita', 'em_andamento') order by aceita_em desc limit 1;
  if v_ativa is null then raise exception 'motoboy_sem_rota_em_andamento' using errcode = '22023'; end if;
  if coalesce(p_perguntar, true) then
    perform public.liberar_rota(p_nova, null, p_motoboy);
    return p_nova;
  end if;
  return privado.estender_rota(v_ativa, p_nova);
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
    'cor_tema', p.cor_tema, 'tema', p.tema,
    'modo_teste', coalesce(m.modo_teste, p.modo_teste),
    'suspenso_ate', case when m.suspenso_ate > now() then m.suspenso_ate end, 'suspenso_motivo', case when m.suspenso_ate > now() then m.suspenso_motivo end,
    'raio', jsonb_build_object('km', m.raio_km, 'modo', coalesce(m.raio_modo, 'posicao'), 'lat', m.raio_lat, 'lng', m.raio_lng),
    'modulos', coalesce((select jsonb_object_agg(md.chave, privado.modulo_ligado(md.chave, p.id)) from public.modulos md), '{}'::jsonb),
    'rotulos', privado.rotulos_de(coalesce(p.organizacao_id, privado.org_contexto(p.empresa_id, null))),
    'campos', (select coalesce(jsonb_agg(jsonb_build_object('chave', k.chave, 'rotulo', k.rotulo, 'dica', k.dica, 'tipo', k.tipo, 'opcoes', k.opcoes,
                 'obrigatorio', k.obrigatorio, 'quem_preenche', k.quem_preenche, 'entidade', k.entidade, 'ponto_tipo', k.ponto_tipo,
                 'tipos_pedido', k.tipos_pedido, 'etapa', k.etapa, 'visivel_motoboy', k.visivel_motoboy, 'visivel_cliente', k.visivel_cliente) order by k.entidade, k.ordem), '[]')
                 from public.campos_personalizados k where k.ativo and (k.organizacao_id is null or k.organizacao_id = coalesce(p.organizacao_id, privado.org_contexto(p.empresa_id, null)))),
    'cargo', (select jsonb_build_object('id', k.id, 'nome', k.nome, 'icone', k.icone) from public.cargos k where k.id = p.cargo_id),
    'holerite_visivel', privado.pol_bool('motoboy_ve_holerite', true, null, p.id, null),
    'supervisor', 'supervisor' = any (p.papeis),
    'permissoes', p.permissoes,
    'dev_oculto', p.dev_oculto,
    'organizacao', (select jsonb_build_object('id', o.id, 'nome', o.nome, 'nome_app', o.nome_app, 'nome_topo', o.nome_topo, 'nomes', o.nomes, 'logo', o.logo_url, 'logo_escala', o.logo_escala, 'logo_original', o.logo_original_url, 'brilho_cor', o.logo_brilho_cor, 'brilho', o.logo_brilho, 'fonte', o.fonte_nome, 'cor', o.cor, 'status', o.status, 'suspensa_motivo', case when o.status in ('suspensa', 'cancelada') then o.suspensa_motivo end)
                      from public.organizacoes o where o.id = case when 'dev' = any (p.papeis) and p.dev_vazio then null else coalesce(case when 'dev' = any (p.papeis) then p.org_em_foco end, p.organizacao_id) end),
    'configuracoes', coalesce((
      select jsonb_object_agg(k, v) from jsonb_each(public.ajustes()) e(k, v)
       where k in ('intervalo_corrida_s', 'intervalo_economia_s', 'disponivel_envio_min',
                       'disponivel_distancia_m', 'raio_chegada_m', 'teste_admin_ignora_local', 'oferta_segundos',
                       'quadro_mostra_enderecos', 'quadro_mostra_itens', 'simulador_ligado', 'simulador_velocidade_kmh',
                       'motoboy_edita_veiculo', 'mapa_offline_some_h', 'mapa_offline_esmaecer', 'veiculo_obrigatorio',
                       'rota_provedor', 'rota_perfil', 'chat_ligado', 'chat_geral', 'chat_fotos', 'ping_envio_s',
                       'chat_compartilhar', 'chat_compartilhar_tipos', 'chat_grupos_equipe', 'pagamento_na_plataforma', 'compartilhar_motoboy_resumo',
                       'usuario_troca_senha', 'perfil_publico_ligado', 'chat_motoboy_abre_rota', 'chat_rota_respostas',
                       'lembrar_pagina', 'passar_corrida_ligado', 'pedido_confirmar_revisao', 'chamado_motoboy_pode',
                       'dev_site_url', 'offline_finalizar_ligado', 'emergencia_ligada', 'motoboy_pede_pular', 'dev_jogo_vel_max_kmh', 'dev_jogo_ranking',
                       'chat_editar_min', 'chat_audio_ligado', 'dev_chat_audio_ligado', 'dev_chat_audio_max_s', 'chat_reacoes')
    ), '{}'::jsonb)
    -- o que pode mudar por motoboy (regra dele > geral)
    || jsonb_build_object(
      'intervalo_corrida_s', privado.pol_num('intervalo_corrida_s', 6, null, p.id, null),
      'intervalo_economia_s', privado.pol_num('intervalo_economia_s', 20, null, p.id, null),
      'disponivel_envio_min', privado.pol_num('disponivel_envio_min', 3, null, p.id, null),
      'disponivel_distancia_m', privado.pol_num('disponivel_distancia_m', 300, null, p.id, null),
      'disponivel_fator', privado.pol_num('disponivel_fator', 3, null, p.id, null),
      'motoboy_rotas_simultaneas', privado.pol_num('motoboy_rotas_simultaneas', 1, null, p.id, null),
      'motoboy_rotas_distancia_aviso_km', privado.pol_num('motoboy_rotas_distancia_aviso_km', 5, null, p.id, null),
      'ping_distancia_m', privado.pol_num('ping_distancia_m', 20, null, p.id, null),
      'ping_precisao_max_m', privado.pol_num('ping_precisao_max_m', 60, null, p.id, null),
      'navegacao_ligada', privado.pol_bool('navegacao_ligada', true, null, p.id, null),
      'navegacao_voz', privado.pol_bool('navegacao_voz', true, null, p.id, null),
      'navegacao_recalcular_m', privado.pol_num('navegacao_recalcular_m', 60, null, p.id, null),
      'navegacao_na_notificacao', privado.pol_bool('navegacao_na_notificacao', true, null, p.id, null),
      'motoboy_edita_veiculo', privado.pol_bool('motoboy_edita_veiculo', false, null, p.id, null),
      'ping_inteligente', privado.pol_bool('ping_inteligente', true, null, p.id, null),
      'ping_curva_graus', privado.pol_num('ping_curva_graus', 25, null, p.id, null),
      'ping_reta_max_m', privado.pol_num('ping_reta_max_m', 200, null, p.id, null),
      'jogo_ligado', privado.pol_bool('jogo_ligado', true, null, p.id, null),
      'jogo_toques', privado.pol_num('jogo_toques', 5, null, p.id, null),
      'motoboy_pode_pular', privado.cfg_bool('saas_pular_parada', true) and privado.pol_bool('motoboy_pode_pular', false, null, p.id, null),
      'motoboy_pode_cancelar', privado.pol_bool('motoboy_pode_cancelar', false, null, p.id, null),
      'motoboy_pode_finalizar', privado.pol_bool('motoboy_pode_finalizar', false, null, p.id, null),
      'especial_ignora_local', privado.especial('especial_ignora_local', p.id),
      'especial_diagnostico', privado.especial('especial_diagnostico', p.id),
      'especial_cliente_edita_aprovado', privado.especial('especial_cliente_edita_aprovado', p.id),
      'motoboy_aba_dia', privado.pol_bool('motoboy_aba_dia', true, null, p.id, null),
      'motoboy_aba_rotas', privado.pol_bool('motoboy_aba_rotas', true, null, p.id, null),
      'motoboy_aba_holerite', privado.pol_bool('motoboy_aba_holerite', true, null, p.id, null),
      'dev_tipos_pedido_ligado', privado.cfg_bool('dev_tipos_pedido_ligado', false),
      'dev_criar_rota_manual', public.is_dev() or privado.cfg_org_bool(coalesce(p.organizacao_id, p.org_em_foco), 'dev_criar_rota_manual', false),
      'mapa_rota_planejada', privado.cfg_org_bool(coalesce(p.organizacao_id, p.org_em_foco), 'mapa_rota_planejada', true))
  )
  from public.perfis p
  left join public.motoboys m on m.id = p.id
  where p.id = auth.uid();
$$;
create or replace function privado.pedido_editavel(p_pedido uuid, p_gestor boolean)
returns void language plpgsql stable security definer set search_path = '' as $$
declare p public.pedidos%rowtype;
begin
  select * into p from public.pedidos where id = p_pedido;
  if p.id is null then raise exception 'pedido_nao_encontrado' using errcode = '22023'; end if;
  if p_gestor then
    if not public.ve_pedido(p.id) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  else
    if p.empresa_id is distinct from privado.minha_empresa() then raise exception 'sem_permissao' using errcode = '42501'; end if;
    if not privado.pol_bool('cliente_edita_pedido', true, p.empresa_id) then raise exception 'acao_bloqueada' using errcode = '42501'; end if;
    if p.status <> 'recebido' and not privado.especial('especial_cliente_edita_aprovado', auth.uid()) then raise exception 'pedido_ja_aprovado' using errcode = '22023'; end if;
  end if;
  if p.status in ('concluido', 'cancelado', 'recusado') then raise exception 'pedido_finalizado' using errcode = '22023'; end if;
  if p.fatura_id is not null and exists (select 1 from public.faturas f where f.id = p.fatura_id and f.status <> 'rascunho') then
    raise exception 'pedido_ja_faturado' using errcode = '22023';
  end if;
  if exists (select 1 from public.pedido_pontos x where x.pedido_id = p.id and x.status not in ('pendente', 'em_rota'))
     or exists (select 1 from public.paradas x where x.pedido_id = p.id and x.status::text in ('chegou', 'concluida'))
     or exists (select 1 from public.paradas x join public.corridas c on c.id = x.corrida_id where x.pedido_id = p.id and c.status::text = 'em_andamento') then
    raise exception 'pedido_em_andamento' using errcode = '22023';
  end if;
end;
$$;

insert into public.configuracoes (chave, valor) values
  ('especial_cliente_edita_aprovado', 'false')
on conflict (chave) do nothing;

-- ═══════════════════════════════════════════════════════════════════════════
-- 5. Registro do Dev: tudo que o Dev muda fica anotado (só o Dev lê)
-- ═══════════════════════════════════════════════════════════════════════════
create table if not exists public.registro_dev (
  id      bigserial primary key,
  dev_id  uuid,
  area    text not null,
  acao    text not null,
  alvo    text,
  detalhe jsonb,
  em      timestamptz not null default now()
);
create index if not exists registro_dev_em on public.registro_dev (em desc);
alter table public.registro_dev enable row level security;
drop policy if exists registro_dev_leitura on public.registro_dev;
create policy registro_dev_leitura on public.registro_dev for select to authenticated using (public.is_dev());
revoke all on public.registro_dev from anon;
grant select on public.registro_dev to authenticated;

create or replace function privado.anotar_dev(p_area text, p_acao text, p_alvo text, p_detalhe jsonb default null)
returns void language sql security definer set search_path = '' as $$
  insert into public.registro_dev (dev_id, area, acao, alvo, detalhe) values (auth.uid(), p_area, p_acao, p_alvo, p_detalhe);
$$;
revoke execute on function privado.anotar_dev(text, text, text, jsonb) from public, anon, authenticated;

create or replace function privado.trg_registro_dev()
returns trigger language plpgsql security definer set search_path = '' as $$
declare a jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end; d jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end; x jsonb := coalesce(d, a);
begin
  if auth.uid() is null or not public.is_dev() then return coalesce(new, old); end if;
  if tg_table_name = 'perfis' and x ->> 'id' = auth.uid()::text then return coalesce(new, old); end if;
  insert into public.registro_dev (dev_id, area, acao, alvo, detalhe)
  values (auth.uid(), tg_table_name, lower(tg_op),
          coalesce(x ->> 'chave', x ->> 'nome', x ->> 'id') || coalesce(' · ' || (x ->> 'escopo') || ':' || (x ->> 'alvo'), ''),
          jsonb_strip_nulls(jsonb_build_object('antes', a - 'logo_original_url', 'depois', d - 'logo_original_url')));
  return coalesce(new, old);
end;
$$;
do $$ declare t text; begin
  foreach t in array array['regras_dev', 'modulos', 'modulos_empresa', 'politicas', 'configuracoes', 'organizacoes', 'cargos', 'perfis'] loop
    execute format('drop trigger if exists registro_dev on public.%I', t);
    execute format('create trigger registro_dev after insert or update or delete on public.%I for each row execute function privado.trg_registro_dev()', t);
  end loop;
end $$;

create or replace function public.dev_registro(p_limite int default 200, p_antes bigint default null, p_area text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'dev', p.nome, 'area', r.area, 'acao', r.acao, 'alvo', r.alvo, 'detalhe', r.detalhe, 'em', r.em) order by r.id desc)
    from (select * from public.registro_dev x where (p_antes is null or x.id < p_antes) and (p_area is null or x.area = p_area) order by x.id desc limit least(coalesce(p_limite, 200), 1000)) r
    left join public.perfis p on p.id = r.dev_id), '[]');
end;
$$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 6. RPCs das Regras do Fantasma
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public.dev_regras()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(to_jsonb(r) || jsonb_build_object('alvo_nome', case r.escopo
        when 'empresa' then (select nome from public.organizacoes where id::text = r.alvo)
        when 'cliente' then (select nome from public.empresas where id::text = r.alvo)
        when 'pessoa'  then (select nome from public.perfis where id::text = r.alvo)
        else r.alvo end,
      'vencida', r.valida_ate is not null and r.valida_ate <= now(), 'autor', (select nome from public.perfis where id = r.criado_por))
      order by r.ativo desc, r.atualizado_em desc) from public.regras_dev r), '[]');
end;
$$;
create or replace function public.dev_salvar_regra(p jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid := nullif(p ->> 'id', '')::uuid; v_escopo text := coalesce(nullif(p ->> 'escopo', ''), 'global');
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  if coalesce(trim(p ->> 'chave'), '') = '' then raise exception 'chave_obrigatoria' using errcode = '22023'; end if;
  if v_escopo <> 'global' and coalesce(p ->> 'alvo', '') = '' then raise exception 'alvo_obrigatorio' using errcode = '22023'; end if;
  if v_id is null then
    insert into public.regras_dev (chave, escopo, alvo, valor, condicoes, porque, valida_de, valida_ate, ativo, criado_por)
    values (trim(p ->> 'chave'), v_escopo, case when v_escopo = 'global' then null else p ->> 'alvo' end, coalesce(p -> 'valor', 'true'),
            coalesce(p -> 'condicoes', '{}'), nullif(p ->> 'porque', ''), nullif(p ->> 'valida_de', '')::timestamptz,
            nullif(p ->> 'valida_ate', '')::timestamptz, coalesce((p ->> 'ativo')::boolean, true), auth.uid())
    returning id into v_id;
  else
    update public.regras_dev set chave = trim(p ->> 'chave'), escopo = v_escopo, alvo = case when v_escopo = 'global' then null else p ->> 'alvo' end,
      valor = coalesce(p -> 'valor', 'true'), condicoes = coalesce(p -> 'condicoes', '{}'), porque = nullif(p ->> 'porque', ''),
      valida_de = nullif(p ->> 'valida_de', '')::timestamptz, valida_ate = nullif(p ->> 'valida_ate', '')::timestamptz,
      ativo = coalesce((p ->> 'ativo')::boolean, true)
     where id = v_id;
    if not found then raise exception 'regra_inexistente' using errcode = '22023'; end if;
  end if;
  return v_id;
end;
$$;
create or replace function public.dev_apagar_regra(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  delete from public.regras_dev where id = p_id;
end;
$$;
create or replace function public.dev_regras_historico(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('versao', h.versao, 'operacao', h.operacao, 'dados', h.dados, 'por', p.nome, 'em', h.em) order by h.id desc)
    from public.regras_dev_historico h left join public.perfis p on p.id = h.por where h.regra_id = p_id), '[]');
end;
$$;
-- volta a regra para uma versão anterior
create or replace function public.dev_restaurar_regra(p_id uuid, p_versao int)
returns void language plpgsql security definer set search_path = '' as $$
declare d jsonb;
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  select dados into d from public.regras_dev_historico where regra_id = p_id and versao = p_versao order by id desc limit 1;
  if d is null then raise exception 'versao_inexistente' using errcode = '22023'; end if;
  if exists (select 1 from public.regras_dev where id = p_id) then
    perform public.dev_salvar_regra(d);
  else
    insert into public.regras_dev (id, chave, escopo, alvo, valor, condicoes, porque, valida_de, valida_ate, ativo, criado_por)
    values (p_id, d ->> 'chave', d ->> 'escopo', d ->> 'alvo', d -> 'valor', coalesce(d -> 'condicoes', '{}'), d ->> 'porque',
            (d ->> 'valida_de')::timestamptz, (d ->> 'valida_ate')::timestamptz, coalesce((d ->> 'ativo')::boolean, true), auth.uid());
  end if;
end;
$$;

-- "Por quê?": o valor que vale para a pessoa e de onde ele vem
create or replace function public.dev_explicar(p_pessoa uuid, p_chave text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  pf public.perfis%rowtype; v_org uuid; r jsonb; v jsonb; v_motivo text; v_fonte text; m public.modulos%rowtype; me boolean; k text;
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  select * into pf from public.perfis where id = p_pessoa;
  if pf.id is null then raise exception 'pessoa_inexistente' using errcode = '22023'; end if;
  v_org := coalesce(pf.organizacao_id, (select organizacao_id from public.empresas where id = pf.empresa_id));
  perform set_config('pwex.org', coalesce(v_org::text, ''), true);
  r := privado.decide(p_pessoa, p_chave, jsonb_build_object('org', v_org, 'cliente', pf.empresa_id));
  if p_chave like 'modulo:%' then
    k := substr(p_chave, 8);
    v := to_jsonb(privado.modulo_ligado(k, p_pessoa));
    select * into m from public.modulos where chave = k;
    select ligado into me from public.modulos_empresa where chave = k and organizacao_id = v_org;
    v_fonte := case when r is not null then 'regra' when 'dev' = any (pf.papeis) then 'dev' when me is not null then 'empresa' when m.chave is null then 'padrao' else 'modulo' end;
    v_motivo := case v_fonte when 'regra' then r ->> 'motivo' when 'dev' then 'O Dev vê tudo'
      when 'empresa' then 'Módulo ' || case when me then 'ligado' else 'desligado' end || ' para a empresa'
      when 'padrao' then 'Módulo sem cadastro: vale ligado'
      else case when not m.ligado then 'Módulo desligado para todos'
                when m.papeis is not null and not (pf.papeis && m.papeis) then 'Módulo só para ' || array_to_string(m.papeis::text[], ', ')
                else 'Módulo ligado para todos' end end;
  elsif p_chave like 'acao:%' then
    k := substr(p_chave, 6);
    if r is not null then v := r -> 'valor'; v_fonte := 'regra'; v_motivo := r ->> 'motivo';
    elsif 'dev' = any (pf.papeis) then v := 'true'; v_fonte := 'dev'; v_motivo := 'O Dev pode tudo';
    elsif not privado.gestor_pode_acao(v_org, k) then v := 'false'; v_fonte := 'empresa'; v_motivo := 'Bloqueado para os gestores da empresa';
    elsif coalesce((select (c.acoes ->> k)::boolean from public.cargos c where c.id = pf.cargo_id), true) = false then
      v := 'false'; v_fonte := 'cargo'; v_motivo := 'Bloqueado no cargo ' || coalesce((select nome from public.cargos where id = pf.cargo_id), '');
    else v := 'true'; v_fonte := 'padrao'; v_motivo := 'Liberado (padrão)'; end if;
  elsif p_chave like 'especial_%' then
    v := to_jsonb(privado.especial(p_chave, p_pessoa));
    v_fonte := case when r is not null then 'regra' when 'dev' = any (pf.papeis) then 'dev'
      when exists (select 1 from public.politicas where escopo = 'motoboy' and alvo = p_pessoa::text and chave = p_chave) then 'pessoa'
      when exists (select 1 from public.politicas where escopo = 'cliente' and alvo = pf.empresa_id::text and chave = p_chave) then 'cliente'
      when exists (select 1 from public.politicas where escopo = 'organizacao' and alvo = v_org::text and chave = p_chave) then 'empresa'
      when exists (select 1 from public.configuracoes where chave = p_chave) then 'sistema' else 'padrao' end;
    v_motivo := case v_fonte when 'regra' then r ->> 'motivo' when 'dev' then 'O Dev tem todas' when 'pessoa' then 'Concedida para esta pessoa'
      when 'cliente' then 'Concedida para o cliente' when 'empresa' then 'Concedida para a empresa' when 'sistema' then 'Valor do sistema' else 'Ninguém tem por padrão' end;
  else
    v := privado.pol(p_chave, pf.empresa_id, p_pessoa, null);
    v_fonte := case when r is not null then 'regra'
      when exists (select 1 from public.politicas where escopo = 'motoboy' and alvo = p_pessoa::text and chave = p_chave) then 'pessoa'
      when exists (select 1 from public.politicas where escopo = 'cliente' and alvo = pf.empresa_id::text and chave = p_chave) then 'cliente'
      when exists (select 1 from public.politicas where escopo = 'organizacao' and alvo = v_org::text and chave = p_chave) then 'empresa'
      when exists (select 1 from public.configuracoes where chave = p_chave) then 'sistema' else 'padrao' end;
    v_motivo := case v_fonte when 'regra' then r ->> 'motivo' when 'pessoa' then 'Ajuste só desta pessoa' when 'cliente' then 'Ajuste do cliente'
      when 'empresa' then 'Ajuste da empresa' when 'sistema' then 'Ajuste geral do sistema' else 'Padrão do app (nada salvo)' end;
  end if;
  return jsonb_build_object('pessoa', p_pessoa, 'chave', p_chave, 'valor', v, 'fonte', v_fonte, 'motivo', v_motivo, 'regra', r -> 'regra');
end;
$$;
-- Matriz pessoa × permissão de uma empresa (equipe e clientes)
create or replace function public.dev_matriz(p_org uuid, p_chaves text[])
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare saida jsonb := '[]'; pf record; vals jsonb; k text;
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  for pf in select p.id, p.nome, p.papeis, p.empresa_id, (select nome from public.cargos where id = p.cargo_id) cargo, (select nome from public.empresas where id = p.empresa_id) cliente
              from public.perfis p
             where p.organizacao_id = p_org or p.empresa_id in (select id from public.empresas where organizacao_id = p_org)
             order by ('cliente' = any (p.papeis)), p.nome limit 300 loop
    vals := '{}';
    foreach k in array coalesce(p_chaves, '{}') loop
      vals := vals || jsonb_build_object(k, public.dev_explicar(pf.id, k) - 'pessoa' - 'chave');
    end loop;
    saida := saida || jsonb_build_array(jsonb_build_object('id', pf.id, 'nome', pf.nome, 'papeis', to_jsonb(pf.papeis), 'cargo', pf.cargo, 'cliente', pf.cliente, 'valores', vals));
  end loop;
  return saida;
end;
$$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 7. Novidades por área: cada pessoa vê só o que mudou para os cargos dela
-- ═══════════════════════════════════════════════════════════════════════════
create table if not exists public.novidades (
  id         uuid primary key default gen_random_uuid(),
  versao     text not null,
  area       text not null default 'todos' check (area in ('todos', 'motoboy', 'gestor', 'supervisor', 'cliente', 'dev')),
  plataforma text not null default 'todas' check (plataforma in ('todas', 'app', 'site')),
  titulo     text not null,
  texto      text,
  publicado  boolean not null default true,
  criado_por uuid references public.perfis (id) on delete set null,
  criado_em  timestamptz not null default now()
);
alter table public.novidades enable row level security;
drop policy if exists novidades_dev on public.novidades;
create policy novidades_dev on public.novidades for all to authenticated using (public.is_dev()) with check (public.is_dev());
revoke all on public.novidades from anon;
grant select, insert, update, delete on public.novidades to authenticated;

create or replace function privado.minhas_areas(p_pessoa uuid)
returns text[] language sql stable security definer set search_path = '' as $$
  select case when 'dev' = any (p.papeis) then array['todos', 'motoboy', 'gestor', 'supervisor', 'cliente', 'dev']
              else array['todos'] || p.papeis::text[] end
    from public.perfis p where p.id = p_pessoa;
$$;
create or replace function public.minhas_novidades(p_limite int default 40)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'versao', n.versao, 'area', n.area, 'plataforma', n.plataforma, 'titulo', n.titulo, 'texto', n.texto, 'em', n.criado_em)
           order by n.criado_em desc, n.area), '[]')
    from (select * from public.novidades x
           where x.publicado and x.area = any (coalesce(privado.minhas_areas(auth.uid()), array['todos']))
           order by x.criado_em desc limit least(coalesce(p_limite, 40), 200)) n
   where privado.modulo_ligado('novidades', auth.uid());
$$;
grant execute on function public.minhas_novidades(int) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════════
-- 8. Avisos do Dev (faixa no topo do site e do app)
-- ═══════════════════════════════════════════════════════════════════════════
create table if not exists public.avisos_dev (
  id             uuid primary key default gen_random_uuid(),
  texto          text not null,
  nivel          text not null default 'info' check (nivel in ('info', 'aviso', 'urgente')),
  papeis         public.papel_usuario[],
  organizacao_id uuid references public.organizacoes (id) on delete cascade,
  ate            timestamptz,
  ativo          boolean not null default true,
  criado_por     uuid references public.perfis (id) on delete set null,
  criado_em      timestamptz not null default now()
);
alter table public.avisos_dev enable row level security;
drop policy if exists avisos_dev_dev on public.avisos_dev;
create policy avisos_dev_dev on public.avisos_dev for all to authenticated using (public.is_dev()) with check (public.is_dev());
grant select, insert, update, delete on public.avisos_dev to authenticated;
create or replace function public.avisos_para_mim()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'texto', a.texto, 'nivel', a.nivel, 'ate', a.ate) order by a.criado_em desc), '[]')
    from public.avisos_dev a, public.perfis p
   where p.id = auth.uid() and a.ativo and (a.ate is null or a.ate > now())
     and (a.organizacao_id is null or a.organizacao_id = coalesce(p.organizacao_id, (select e.organizacao_id from public.empresas e where e.id = p.empresa_id)) or 'dev' = any (p.papeis))
     and (a.papeis is null or a.papeis && p.papeis or 'dev' = any (p.papeis))
     and privado.modulo_ligado('avisos', p.id);
$$;
grant execute on function public.avisos_para_mim() to authenticated;
create or replace function public.dev_avisar(p jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  if coalesce(trim(p ->> 'texto'), '') = '' then raise exception 'texto_obrigatorio' using errcode = '22023'; end if;
  insert into public.avisos_dev (texto, nivel, papeis, organizacao_id, ate, criado_por)
  values (trim(p ->> 'texto'), coalesce(nullif(p ->> 'nivel', ''), 'info'),
          (select nullif(array_agg(x::public.papel_usuario), '{}') from jsonb_array_elements_text(coalesce(p -> 'papeis', '[]')) x),
          nullif(p ->> 'organizacao_id', '')::uuid, nullif(p ->> 'ate', '')::timestamptz, auth.uid())
  returning id into v;
  perform privado.anotar_dev('avisos', 'enviar', v::text, p);
  return v;
end;
$$;
create or replace function public.dev_encerrar_aviso(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  update public.avisos_dev set ativo = false where id = p_id;
  perform privado.anotar_dev('avisos', 'encerrar', p_id::text);
end;
$$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 9. Emergência: congelar empresa, derrubar sessões
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public.dev_congelar_empresa(p_org uuid, p_congelar boolean, p_motivo text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  update public.organizacoes set status = case when p_congelar then 'suspensa' else 'ativa' end,
         suspensa_motivo = case when p_congelar then coalesce(nullif(p_motivo, ''), 'Acesso congelado pelo suporte') end
   where id = p_org;
  if not found then raise exception 'empresa_inexistente' using errcode = '22023'; end if;
end;
$$;
-- tira do ar as sessões abertas (de uma pessoa ou de uma empresa inteira); o Dev nunca se derruba
create or replace function public.dev_derrubar_sessoes(p_pessoa uuid default null, p_org uuid default null)
returns int language plpgsql security definer set search_path = '' as $$
declare v_ids uuid[]; n int := 0; m int := 0;
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  select array_agg(id) into v_ids from public.perfis
   where id <> auth.uid() and ((p_pessoa is not null and id = p_pessoa)
      or (p_org is not null and (organizacao_id = p_org or empresa_id in (select id from public.empresas where organizacao_id = p_org))));
  if v_ids is null then return 0; end if;
  if to_regclass('auth.refresh_tokens') is not null then
    execute 'delete from auth.refresh_tokens where user_id::uuid = any ($1)' using v_ids; get diagnostics m = row_count;
  end if;
  if to_regclass('auth.sessions') is not null then
    execute 'delete from auth.sessions where user_id = any ($1)' using v_ids; get diagnostics n = row_count;
  end if;
  perform privado.anotar_dev('emergencia', 'derrubar_sessoes', coalesce(p_pessoa::text, p_org::text), jsonb_build_object('pessoas', cardinality(v_ids), 'sessoes', n));
  return cardinality(v_ids);
end;
$$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 10. Comando ao vivo e explorador de dados (só leitura)
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public.dev_comando()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  return jsonb_build_object(
    'agora', now(),
    'empresas', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'nome', o.nome, 'status', o.status,
        'online', (select count(*) from public.motoboys m join public.perfis p on p.id = m.id where p.organizacao_id = o.id and m.status <> 'offline'),
        'em_corrida', (select count(*) from public.motoboys m join public.perfis p on p.id = m.id where p.organizacao_id = o.id and m.status = 'em_corrida'),
        'rotas_ativas', (select count(*) from public.corridas c where c.organizacao_id = o.id and c.status::text in ('aguardando_motoboy', 'aceita', 'em_andamento') and not c.teste),
        'pedidos_hoje', (select count(*) from public.pedidos x where x.organizacao_id = o.id and x.criado_em > now() - interval '24 hours' and not x.teste),
        'para_revisar', (select count(*) from public.pedidos x where x.organizacao_id = o.id and x.status = 'recebido' and not x.teste),
        'emergencias', (select count(*) from public.emergencias e where e.organizacao_id = o.id and e.resolvida_em is null)
      ) order by o.nome) from public.organizacoes o), '[]'),
    'motoboys', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'nome', p.nome, 'empresa', (select nome from public.organizacoes where id = p.organizacao_id),
        'status', m.status, 'posicao_em', m.posicao_em, 'bateria', m.bateria, 'lat', m.lat, 'lng', m.lng, 'versao', m.versao_app) order by m.posicao_em desc nulls last)
      from public.motoboys m join public.perfis p on p.id = m.id where m.status <> 'offline'), '[]'),
    'regras_ativas', (select count(*) from public.regras_dev where ativo and (valida_ate is null or valida_ate > now())),
    'avisos', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'texto', a.texto, 'nivel', a.nivel, 'ate', a.ate, 'empresa', (select nome from public.organizacoes where id = a.organizacao_id)) order by a.criado_em desc)
      from public.avisos_dev a where a.ativo and (a.ate is null or a.ate > now())), '[]'),
    'modulos_desligados', coalesce((select jsonb_agg(chave) from public.modulos where not ligado), '[]'),
    'ultimas', coalesce((select jsonb_agg(x order by (x ->> 'em') desc) from (
        (select jsonb_build_object('tipo', 'pedido', 'texto', 'Pedido #' || numero || ' · ' || coalesce(cliente_nome, ''), 'em', criado_em) x from public.pedidos order by criado_em desc limit 8)
        union all
        (select jsonb_build_object('tipo', 'dev', 'texto', area || ' · ' || acao || coalesce(' · ' || alvo, ''), 'em', em) from public.registro_dev order by id desc limit 8)) t), '[]'));
end;
$$;
create or replace function public.dev_tabelas()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('tabela', c.relname, 'linhas', greatest(c.reltuples, 0)::bigint,
      'colunas', (select jsonb_agg(a.attname order by a.attnum) from pg_catalog.pg_attribute a where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped)) order by c.relname)
    from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind in ('r', 'p')), '[]');
end;
$$;
create or replace function public.dev_explorar(p_tabela text, p_busca text default null, p_limite int default 50, p_pagina int default 0, p_ordem text default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb; total bigint; ord text := '';
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  if not exists (select 1 from pg_catalog.pg_tables where schemaname = 'public' and tablename = p_tabela) then raise exception 'tabela_inexistente' using errcode = '22023'; end if;
  if p_ordem is not null then
    if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = p_tabela and column_name = regexp_replace(p_ordem, '^-', '')) then
      raise exception 'coluna_inexistente' using errcode = '22023'; end if;
    ord := format(' order by %I %s nulls last', regexp_replace(p_ordem, '^-', ''), case when p_ordem like '-%' then 'desc' else 'asc' end);
  end if;
  execute format('select count(*) from public.%I t where ($1 is null or t::text ilike ''%%'' || $1 || ''%%'')', p_tabela) into total using nullif(p_busca, '');
  execute format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]'') from (select * from public.%I t where ($1 is null or t::text ilike ''%%'' || $1 || ''%%'')%s limit $2 offset $3) x', p_tabela, ord)
    into v using nullif(p_busca, ''), least(greatest(coalesce(p_limite, 50), 1), 500), greatest(coalesce(p_pagina, 0), 0) * least(greatest(coalesce(p_limite, 50), 1), 500);
  return jsonb_build_object('total', total, 'linhas', v);
end;
$$;

revoke execute on function public.dev_regras(), public.dev_salvar_regra(jsonb), public.dev_apagar_regra(uuid), public.dev_regras_historico(uuid),
  public.dev_restaurar_regra(uuid, int), public.dev_explicar(uuid, text), public.dev_matriz(uuid, text[]), public.dev_registro(int, bigint, text),
  public.dev_avisar(jsonb), public.dev_encerrar_aviso(uuid), public.dev_congelar_empresa(uuid, boolean, text), public.dev_derrubar_sessoes(uuid, uuid),
  public.dev_comando(), public.dev_tabelas(), public.dev_explorar(text, text, int, int, text), public.avisos_para_mim(), public.minhas_novidades(int) from anon;

-- ═══════════════════════════════════════════════════════════════════════════
-- 11. Novidades desta versão, por área
-- ═══════════════════════════════════════════════════════════════════════════
insert into public.novidades (versao, area, plataforma, titulo, texto) values
  ('Lote 50', 'todos', 'todas', 'Avisos no topo da tela', 'Quando houver um aviso importante da plataforma, ele aparece numa faixa no alto da tela.'),
  ('Lote 50', 'todos', 'todas', 'Novidades só do que é seu', 'Esta lista agora mostra só o que mudou para o seu tipo de conta.'),
  ('Lote 50', 'gestor', 'site', 'Valores da plataforma escondidos', 'A fatura e o pedido não mostram mais a parte da plataforma para a equipe da empresa.'),
  ('Lote 50', 'cliente', 'todas', 'Editar pedido aprovado', 'Se a sua empresa liberar, você pode mudar um pedido mesmo depois de aprovado, até ele sair para a rota.'),
  ('Lote 50', 'dev', 'todas', 'Delibra Dev', 'Área própria do Dev: comando ao vivo, regras do Fantasma, módulos de tudo, matriz de permissões com o porquê, explorador de dados, registro do Dev, novidades por área, avisos e emergência.');
