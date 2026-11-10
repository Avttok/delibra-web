-- =====================================================================
-- PW Express · Refinamento (10/11/2026)
--   ícones de catálogo, cliente e motoboy · veículo e CNH do motoboy
--   cliente em modo teste · gestor usando o site do cliente · voltar pedido à revisão
--   cadastro de empresas pelo site (instantâneo ou com aprovação) · modelos de pedido
--   campos do item por categoria (peso, medidas, valor declarado) · regras por pedido
--   zona exclusiva do cliente · simulador de posição (modo teste) · parâmetros novos
-- Rode depois de 20261109000003.
-- =====================================================================

-- ------------------------------------------------------------- parâmetros novos
insert into public.configuracoes (chave, valor) values
  ('mapa_offline_some_h',          '24'),        -- motoboy offline some do mapa depois de tantas horas
  ('mapa_offline_esmaecer',        'true'),      -- offline vai ficando transparente com o tempo
  ('cadastro_cliente_modo',        '"aprovacao"'),-- desligado | aprovacao | instantaneo
  ('cadastro_express_liberado',    'false'),     -- cliente que se cadastrou já pode pedir Express
  ('cadastro_cobranca',            '"pre_pago"'),-- cobrança de quem se cadastra sozinho: pre_pago | credito
  ('zona_cliente_exclusiva',       'false'),     -- cliente com zonas próprias ignora as zonas gerais
  ('motoboy_edita_veiculo',        'false'),     -- motoboy pode editar placa, cor e CNH no app
  ('veiculo_obrigatorio',          'false'),     -- só pega rota quem tem placa cadastrada
  ('quadro_mostra_enderecos',      'true'),      -- quadro mostra os endereços antes de pegar
  ('quadro_mostra_itens',          'true'),      -- quadro mostra os itens antes de pegar
  ('cliente_pode_modelos',         'true'),      -- cliente pode salvar modelos de pedido
  ('cliente_ve_motoboy',           'true'),      -- cliente vê o primeiro nome do motoboy
  ('cliente_ve_codigo',            'true'),      -- cliente vê o código de entrega
  ('cliente_pode_cancelar',        'true'),      -- cliente cancela enquanto ninguém pegou
  ('cliente_troca_senha',          'true'),      -- cliente pode trocar a própria senha
  ('item_categoria_obrigatoria',   'false'),     -- todo item precisa de categoria
  ('voltar_revisao_aceitas',       'true'),      -- pode voltar à revisão mesmo com a rota aceita (sem parada feita)
  ('simulador_ligado',             'true'),      -- simulador de posição para motoboys em modo teste
  ('simulador_velocidade_kmh',     '35')         -- velocidade padrão do simulador
on conflict (chave) do nothing;

create or replace function privado.cfg_txt(p_chave text, p_padrao text)
returns text language sql stable security definer set search_path = '' as $$
  select coalesce((select valor #>> '{}' from public.configuracoes where chave = p_chave), p_padrao);
$$;

-- ------------------------------------------------------------- ícones
alter table public.categorias_produto add column if not exists icone text;
alter table public.zonas add column if not exists icone text;
alter table public.faixas_horario add column if not exists icone text;
alter table public.empresas add column if not exists icone text;
alter table public.perfis add column if not exists icone text;
update public.categorias_produto set icone = case nome
  when 'Documentos' then 'file-text' when 'Pacote comum' then 'package' when 'Eletrônicos' then 'smartphone'
  when 'Alimentos' then 'utensils' when 'Medicamentos' then 'pill' when 'Químicos / inflamáveis' then 'flask-conical' else 'package' end
 where icone is null;
update public.faixas_horario set icone = 'clock' where icone is null;
update public.zonas set icone = 'map-pin' where icone is null;

-- ------------------------------------------------------------- campos do item por categoria
alter table public.categorias_produto add column if not exists campo_descricao text not null default 'opcional';
alter table public.categorias_produto add column if not exists campo_peso text not null default 'opcional';
alter table public.categorias_produto add column if not exists campo_medidas text not null default 'opcional';
alter table public.categorias_produto add column if not exists campo_valor text not null default 'oculto';
alter table public.categorias_produto add column if not exists campo_quantidade text not null default 'opcional';
do $$ begin
  alter table public.categorias_produto add constraint categorias_campos_ck check (
    campo_descricao in ('oculto', 'opcional', 'obrigatorio') and campo_peso in ('oculto', 'opcional', 'obrigatorio')
    and campo_medidas in ('oculto', 'opcional', 'obrigatorio') and campo_valor in ('oculto', 'opcional', 'obrigatorio')
    and campo_quantidade in ('oculto', 'opcional', 'obrigatorio'));
exception when duplicate_object then null; end $$;
-- padrões sensatos para as categorias de fábrica (o gestor muda depois)
update public.categorias_produto set campo_peso = 'oculto', campo_medidas = 'oculto', campo_valor = 'oculto' where nome = 'Documentos' and campo_valor = 'oculto' and campo_peso = 'opcional';
update public.categorias_produto set campo_valor = 'opcional' where nome in ('Eletrônicos', 'Medicamentos') and campo_valor = 'oculto';
update public.categorias_produto set campo_medidas = 'oculto' where nome in ('Alimentos', 'Medicamentos') and campo_medidas = 'opcional';

-- ------------------------------------------------------------- veículo e CNH
alter table public.motoboys add column if not exists veiculo_tipo text not null default 'moto';
alter table public.motoboys add column if not exists veiculo_modelo text;
alter table public.motoboys add column if not exists veiculo_placa text;
alter table public.motoboys add column if not exists veiculo_cor text;
alter table public.motoboys add column if not exists veiculo_ano int;
alter table public.motoboys add column if not exists cnh_numero text;
alter table public.motoboys add column if not exists cnh_categoria text;
alter table public.motoboys add column if not exists cnh_validade date;
do $$ begin
  alter table public.motoboys add constraint motoboys_veiculo_ck check (
    veiculo_tipo in ('moto', 'carro', 'bicicleta', 'van', 'outro')
    and (veiculo_placa is null or veiculo_placa ~ '^[A-Z]{3}[0-9][A-Z0-9][0-9]{2}$')
    and (cnh_numero is null or cnh_numero ~ '^[0-9]{9,11}$')
    and (cnh_categoria is null or cnh_categoria ~ '^(ACC|A|B|C|D|E|AB|AC|AD|AE)$')
    and (veiculo_ano is null or veiculo_ano between 1950 and 2100));
exception when duplicate_object then null; end $$;

create or replace function privado.veiculo_json(m public.motoboys)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object('tipo', m.veiculo_tipo, 'modelo', m.veiculo_modelo, 'placa', m.veiculo_placa, 'cor', m.veiculo_cor,
    'ano', m.veiculo_ano, 'cnh_numero', m.cnh_numero, 'cnh_categoria', m.cnh_categoria, 'cnh_validade', m.cnh_validade,
    'cnh_vencida', m.cnh_validade is not null and m.cnh_validade < current_date,
    'cnh_vence_em_dias', case when m.cnh_validade is not null then m.cnh_validade - current_date end);
$$;

-- Motoboy (se permitido) ou gestor grava o veículo. d: {tipo, modelo, placa, cor, ano, cnh_numero, cnh_categoria, cnh_validade}
create or replace function public.salvar_veiculo(p_motoboy uuid, d jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_id    uuid := coalesce(p_motoboy, auth.uid());
  v_placa text := nullif(upper(regexp_replace(coalesce(d ->> 'placa', ''), '[^A-Za-z0-9]', '', 'g')), '');
  v_cnh   text := nullif(regexp_replace(coalesce(d ->> 'cnh_numero', ''), '[^0-9]', '', 'g'), '');
  v_cat   text := nullif(upper(trim(coalesce(d ->> 'cnh_categoria', ''))), '');
  m       public.motoboys%rowtype;
begin
  if v_id = auth.uid() and not public.is_gestor() then
    if not privado.cfg_bool('motoboy_edita_veiculo', false) then raise exception 'so_o_gestor_edita' using errcode = '42501'; end if;
  elsif not public.is_gestor() or not public.pode_gerenciar(v_id) then
    raise exception 'apenas_gestor' using errcode = '42501';
  end if;
  if not exists (select 1 from public.perfis where id = v_id and 'motoboy' = any (papeis)) then raise exception 'nao_e_motoboy' using errcode = '22023'; end if;
  if v_placa is not null and v_placa !~ '^[A-Z]{3}[0-9][A-Z0-9][0-9]{2}$' then raise exception 'placa_invalida' using errcode = '22023'; end if;
  if v_cnh is not null and v_cnh !~ '^[0-9]{9,11}$' then raise exception 'cnh_invalida' using errcode = '22023'; end if;
  if v_cat is not null and v_cat !~ '^(ACC|A|B|C|D|E|AB|AC|AD|AE)$' then raise exception 'cnh_categoria_invalida' using errcode = '22023'; end if;
  insert into public.motoboys (id) values (v_id) on conflict (id) do nothing;
  update public.motoboys set
    veiculo_tipo = coalesce(nullif(d ->> 'tipo', ''), veiculo_tipo),
    veiculo_modelo = nullif(left(trim(coalesce(d ->> 'modelo', '')), 60), ''),
    veiculo_placa = v_placa,
    veiculo_cor = nullif(left(trim(coalesce(d ->> 'cor', '')), 30), ''),
    veiculo_ano = nullif(d ->> 'ano', '')::int,
    cnh_numero = v_cnh, cnh_categoria = v_cat,
    cnh_validade = nullif(d ->> 'cnh_validade', '')::date
   where id = v_id returning * into m;
  return privado.veiculo_json(m);
end;
$$;

create or replace function public.meu_veiculo()
returns jsonb language sql stable security definer set search_path = '' as $$
  select privado.veiculo_json(m) || jsonb_build_object('pode_editar', privado.cfg_bool('motoboy_edita_veiculo', false))
    from public.motoboys m where m.id = auth.uid();
$$;

-- Gestor ou o próprio troca o ícone (motoboy) / gestor troca o do cliente
create or replace function public.definir_icone(p_tipo text, p_id uuid, p_icone text)
returns void language plpgsql security definer set search_path = '' as $$
declare v text := nullif(left(trim(coalesce(p_icone, '')), 40), '');
begin
  if v is not null and v !~ '^[a-z0-9-]{2,40}$' then raise exception 'icone_invalido' using errcode = '22023'; end if;
  if p_tipo = 'perfil' then
    if not (p_id = auth.uid() or (public.is_gestor() and public.pode_gerenciar(p_id))) then raise exception 'sem_permissao' using errcode = '42501'; end if;
    update public.perfis set icone = v where id = p_id;
  elsif p_tipo = 'empresa' then
    if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
    update public.empresas set icone = v where id = p_id;
  else
    raise exception 'tipo_invalido' using errcode = '22023';
  end if;
end;
$$;

-- ------------------------------------------------------------- cliente em modo teste / gestor como cliente
alter table public.empresas add column if not exists modo_teste boolean not null default false;

create table if not exists public.acesso_como_cliente (
  perfil_id  uuid primary key references public.perfis (id) on delete cascade,
  empresa_id uuid not null references public.empresas (id) on delete cascade,
  desde      timestamptz not null default now()
);
alter table public.acesso_como_cliente enable row level security;
drop policy if exists acesso_como_cliente_proprio on public.acesso_como_cliente;
create policy acesso_como_cliente_proprio on public.acesso_como_cliente for select to authenticated using (perfil_id = (select auth.uid()));


create or replace function privado.minha_empresa()
returns uuid language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select empresa_id from public.perfis where id = auth.uid() and 'cliente' = any (papeis) and empresa_id is not null),
    (select a.empresa_id from public.acesso_como_cliente a join public.perfis p on p.id = a.perfil_id
      where a.perfil_id = auth.uid() and ('gestor' = any (p.papeis) or 'dev' = any (p.papeis))));
$$;
create or replace function public.minha_empresa_id()
returns uuid language sql stable security definer set search_path = '' as $$
  select privado.minha_empresa();
$$;

-- Pedidos e faturas de teste: cliente em modo teste, ou gestor em modo teste usando o site do cliente
create or replace function privado.cliente_teste()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select e.modo_teste from public.empresas e where e.id = privado.minha_empresa()), false)
      or coalesce((select p.modo_teste from public.perfis p join public.acesso_como_cliente a on a.perfil_id = p.id
                    where p.id = auth.uid() and not ('cliente' = any (p.papeis) and p.empresa_id is not null)), false);
$$;

-- Gestor/Dev escolhe um cliente para usar o site do cliente como ele (null sai)
create or replace function public.entrar_como_cliente(p_empresa uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if p_empresa is null then
    delete from public.acesso_como_cliente where perfil_id = auth.uid();
    return null;
  end if;
  if not exists (select 1 from public.empresas where id = p_empresa) then raise exception 'cliente_nao_encontrado' using errcode = '22023'; end if;
  insert into public.acesso_como_cliente (perfil_id, empresa_id) values (auth.uid(), p_empresa)
  on conflict (perfil_id) do update set empresa_id = excluded.empresa_id, desde = now();
  return (select jsonb_build_object('id', id, 'nome', nome) from public.empresas where id = p_empresa);
end;
$$;

-- Gestor/Dev também pode ser cliente: liga a conta a um cadastro (null desliga)
create or replace function public.vincular_cliente(p_usuario uuid, p_empresa uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if p_usuario <> auth.uid() and not public.pode_gerenciar(p_usuario) then raise exception 'conta_protegida' using errcode = '42501'; end if;
  if p_empresa is not null and not exists (select 1 from public.empresas where id = p_empresa) then raise exception 'cliente_nao_encontrado' using errcode = '22023'; end if;
  update public.perfis set empresa_id = p_empresa,
         papeis = case when p_empresa is null then array_remove(papeis, 'cliente'::public.papel_usuario)
                       else (select array_agg(distinct x) from unnest(papeis || '{cliente}'::public.papel_usuario[]) x) end
   where id = p_usuario;
end;
$$;

-- Para o site do cliente: quem sou eu (cliente de verdade, gestor como cliente ou cadastro em análise)
create or replace function public.meu_acesso_cliente()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare p public.perfis%rowtype; v_emp uuid; c record;
begin
  select * into p from public.perfis where id = auth.uid();
  if not found then return jsonb_build_object('tipo', 'nenhum'); end if;
  if 'cliente' = any (p.papeis) and p.empresa_id is not null then
    return jsonb_build_object('tipo', 'cliente', 'empresa_id', p.empresa_id, 'nome', p.nome,
      'gestor', 'gestor' = any (p.papeis) or 'dev' = any (p.papeis), 'teste', privado.cliente_teste());
  end if;
  if 'gestor' = any (p.papeis) or 'dev' = any (p.papeis) then
    select empresa_id into v_emp from public.acesso_como_cliente where perfil_id = p.id;
    return jsonb_build_object('tipo', 'gestor', 'nome', p.nome, 'empresa_id', v_emp,
      'empresa_nome', (select nome from public.empresas where id = v_emp), 'teste', privado.cliente_teste(),
      'clientes', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'nome', e.nome, 'teste', e.modo_teste) order by e.modo_teste desc, e.nome), '[]')
                     from public.empresas e));
  end if;
  select * into c from public.cadastros_cliente where perfil_id = p.id order by criado_em desc limit 1;
  if found then
    return jsonb_build_object('tipo', 'cadastro', 'status', c.status, 'motivo', c.motivo, 'nome', c.nome);
  end if;
  return jsonb_build_object('tipo', 'nenhum', 'nome', p.nome);
end;
$$;


-- ------------------------------------------------------------- cadastro de empresas pelo site do cliente
create table if not exists public.cadastros_cliente (
  id           uuid primary key default gen_random_uuid(),
  perfil_id    uuid references public.perfis (id) on delete set null,
  email        text not null,
  nome         text not null,          -- razão social / nome
  responsavel  text,
  tipo         text not null default 'pj' check (tipo in ('pj', 'pf')),
  documento    text,                   -- CNPJ ou CPF, só números
  telefone     text,
  endereco     text,
  lat          double precision,
  lng          double precision,
  observacoes  text,
  status       text not null default 'pendente' check (status in ('pendente', 'aprovado', 'recusado')),
  motivo       text,
  empresa_id   uuid references public.empresas (id) on delete set null,
  revisado_por uuid references public.perfis (id) on delete set null,
  revisado_em  timestamptz,
  criado_em    timestamptz not null default now()
);
create index if not exists cadastros_cliente_status_idx on public.cadastros_cliente (status, criado_em desc);
alter table public.cadastros_cliente enable row level security;
drop policy if exists cadastros_cliente_gestor on public.cadastros_cliente;
create policy cadastros_cliente_gestor on public.cadastros_cliente for select to authenticated using ((select public.is_gestor()));

-- Cria o cliente a partir do cadastro e liga a conta (aprovação ou cadastro instantâneo)
create or replace function privado.aprovar_cadastro(p_id uuid, p_opcoes jsonb default '{}')
returns uuid language plpgsql security definer set search_path = '' as $$
declare c public.cadastros_cliente%rowtype; v_emp uuid; v_cobr text;
begin
  select * into c from public.cadastros_cliente where id = p_id for update;
  if not found then raise exception 'cadastro_nao_encontrado' using errcode = '22023'; end if;
  if c.status = 'aprovado' then return c.empresa_id; end if;
  if c.documento is not null then
    select id into v_emp from public.empresas
     where (c.tipo = 'pj' and cnpj = c.documento) or (c.tipo = 'pf' and cpf = c.documento) limit 1;
  end if;
  if v_emp is null then
    insert into public.empresas (nome, tipo, cnpj, cpf, telefone, email, endereco, lat, lng, modalidade_preco, pode_express)
    values (c.nome, c.tipo, case when c.tipo = 'pj' then c.documento end, case when c.tipo = 'pf' then c.documento end,
            c.telefone, c.email, c.endereco, c.lat, c.lng, 'por_km',
            coalesce((p_opcoes ->> 'pode_express')::boolean, privado.cfg_bool('cadastro_express_liberado', false)))
    returning id into v_emp;
  end if;
  v_cobr := coalesce(nullif(p_opcoes ->> 'cobranca', ''), privado.cfg_txt('cadastro_cobranca', 'pre_pago'));
  if v_cobr in ('pre_pago', 'credito') and v_cobr <> privado.cfg_txt('cobranca_modo', 'credito') then
    insert into public.politicas (escopo, alvo, chave, valor) values ('cliente', v_emp::text, 'cobranca_modo', to_jsonb(v_cobr))
    on conflict (escopo, alvo, chave) do update set valor = excluded.valor, atualizado_em = now();
  end if;
  if c.perfil_id is not null then
    update public.perfis set empresa_id = v_emp,
           papeis = (select array_agg(distinct x) from unnest(papeis || '{cliente}'::public.papel_usuario[]) x),
           nome = case when coalesce(nome, '') = '' then coalesce(c.responsavel, c.nome) else nome end
     where id = c.perfil_id;
  end if;
  update public.cadastros_cliente set status = 'aprovado', empresa_id = v_emp, revisado_por = auth.uid(), revisado_em = now(), motivo = null where id = c.id;
  return v_emp;
end;
$$;

-- Gestor aprova (com opções) ou recusa
create or replace function public.revisar_cadastro(p_id uuid, p_aprovar boolean, p_motivo text default null, p_opcoes jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_emp uuid;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if p_aprovar then
    v_emp := privado.aprovar_cadastro(p_id, coalesce(p_opcoes, '{}'));
  else
    update public.cadastros_cliente set status = 'recusado', motivo = nullif(trim(coalesce(p_motivo, '')), ''), revisado_por = auth.uid(), revisado_em = now()
     where id = p_id and status = 'pendente';
    if not found then raise exception 'cadastro_nao_encontrado' using errcode = '22023'; end if;
  end if;
  return (select to_jsonb(c) from public.cadastros_cliente c where c.id = p_id);
end;
$$;

-- Chamado pelo servidor do site (service_role) depois de criar a conta: registra e, se for instantâneo, aprova
create or replace function public.registrar_cadastro(d jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_modo text := privado.cfg_txt('cadastro_cliente_modo', 'aprovacao'); v_id uuid; v_doc text;
begin
  if not privado.eh_servico() then raise exception 'apenas_servidor' using errcode = '42501'; end if;
  if v_modo = 'desligado' then raise exception 'cadastro_desligado' using errcode = '42501'; end if;
  v_doc := nullif(regexp_replace(coalesce(d ->> 'documento', ''), '[^0-9]', '', 'g'), '');
  if v_doc is not null and length(v_doc) not in (11, 14) then raise exception 'documento_invalido' using errcode = '22023'; end if;
  insert into public.cadastros_cliente (perfil_id, email, nome, responsavel, tipo, documento, telefone, endereco, lat, lng, observacoes)
  values (nullif(d ->> 'perfil_id', '')::uuid, lower(trim(d ->> 'email')), left(trim(d ->> 'nome'), 120), nullif(left(trim(coalesce(d ->> 'responsavel', '')), 80), ''),
          case when length(coalesce(v_doc, '')) = 11 then 'pf' else 'pj' end, v_doc, nullif(left(trim(coalesce(d ->> 'telefone', '')), 30), ''),
          nullif(left(trim(coalesce(d ->> 'endereco', '')), 300), ''), nullif(d ->> 'lat', '')::double precision, nullif(d ->> 'lng', '')::double precision,
          nullif(left(trim(coalesce(d ->> 'observacoes', '')), 500), ''))
  returning id into v_id;
  if v_modo = 'instantaneo' then perform privado.aprovar_cadastro(v_id); end if;
  return (select jsonb_build_object('id', c.id, 'status', c.status) from public.cadastros_cliente c where c.id = v_id);
end;
$$;

-- O que o site público precisa saber antes do cadastro
create or replace function public.cadastro_aberto()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('modo', privado.cfg_txt('cadastro_cliente_modo', 'aprovacao'));
$$;


-- ------------------------------------------------------------- modelos (templates) de pedido
create table if not exists public.pedido_modelos (
  id         uuid primary key default gen_random_uuid(),
  empresa_id uuid references public.empresas (id) on delete cascade,
  criado_por uuid references public.perfis (id) on delete set null,
  nome       text not null check (length(trim(nome)) between 1 and 60),
  icone      text,
  dados      jsonb not null default '{}',   -- mesmo formato do criar_pedido (sem horário)
  usos       int not null default 0,
  usado_em   timestamptz,
  criado_em  timestamptz not null default now()
);
create index if not exists pedido_modelos_empresa_idx on public.pedido_modelos (empresa_id, nome);
alter table public.pedido_modelos enable row level security;
create or replace function public.pode_salvar_modelos()
returns boolean language sql stable security definer set search_path = '' as $$
  select privado.pol_bool('cliente_pode_modelos', true, privado.minha_empresa());
$$;
drop policy if exists pedido_modelos_cliente on public.pedido_modelos;
create policy pedido_modelos_cliente on public.pedido_modelos for all to authenticated
  using (empresa_id = (select public.minha_empresa_id()) or (select public.is_gestor()))
  with check ((empresa_id = (select public.minha_empresa_id()) and pode_salvar_modelos()) or (select public.is_gestor()));


-- ------------------------------------------------------------- regras por pedido (a peça mais alta do lego)
alter table public.pedidos add column if not exists regras jsonb not null default '{}';
create or replace function privado.pol(p_chave text, p_cliente uuid default null, p_motoboy uuid default null, p_tipo text default null)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(
    (nullif(current_setting('pwex.regras', true), '')::jsonb -> p_chave),
    (select valor from public.politicas where p_motoboy is not null and escopo = 'motoboy' and alvo = p_motoboy::text and chave = p_chave),
    (select valor from public.politicas where p_cliente is not null and escopo = 'cliente' and alvo = p_cliente::text and chave = p_chave),
    (select valor from public.politicas where p_tipo is not null and escopo = 'tipo' and alvo = p_tipo and chave = p_chave),
    (select valor from public.configuracoes where chave = p_chave));
$$;
create or replace function privado.limpar_regras(r jsonb)
returns jsonb language sql immutable set search_path = '' as $$
  select coalesce(jsonb_object_agg(k, v), '{}') from jsonb_each(case when jsonb_typeof(r) = 'object' then r else '{}' end) e(k, v)
   where k ~ '^[a-z0-9_]{2,60}$' and k not in ('dev_pct') and jsonb_typeof(v) in ('number', 'boolean', 'string');
$$;
create or replace function privado.usar_regras(r jsonb)
returns void language sql volatile set search_path = '' as $$
  select set_config('pwex.regras', coalesce(privado.limpar_regras(r), '{}')::text, true);
$$;

-- Gestor troca as regras de um pedido (recalcula se ainda não saiu)
create or replace function public.definir_regras_pedido(p_pedido uuid, p_regras jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p public.pedidos%rowtype;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select * into p from public.pedidos where id = p_pedido for update;
  if not found then raise exception 'pedido_nao_encontrado' using errcode = '22023'; end if;
  update public.pedidos set regras = privado.limpar_regras(p_regras) where id = p.id;
  perform privado.evento_pedido(p.id, 'regras', jsonb_build_object('regras', privado.limpar_regras(p_regras)));
  if p.status in ('recebido', 'aprovado') then perform public.revisar_pedido(p.id, 'recalcular'); end if;
  return (select to_jsonb(x) from public.pedidos x where x.id = p.id);
end;
$$;


-- orçamento: regras do pedido e zonas exclusivas do cliente
create or replace function privado.orcar(d jsonb)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_cli    uuid := nullif(d ->> 'empresa_id', '')::uuid;
  v_tp     text := coalesce(nullif(d ->> 'tipo_pedido', ''), 'padrao');
  v_quando timestamptz := coalesce(nullif(d ->> 'quando', '')::timestamptz, now());
  e        public.empresas%rowtype;
  v_linhas jsonb := '[]';
  v_pcts   jsonb := '[]';
  v_fixos  numeric := 0;
  v_sub    numeric := 0;
  v_pct    numeric := 0;
  v_dist   numeric;
  v_km     numeric;
  v_ncol   int; v_nent int; v_pac int;
  v_real   numeric; v_cub numeric; v_tax numeric;
  v_val    numeric; v_x numeric;
  v_perig  boolean;
  v_cat    record;
  v_zp     numeric := 0; v_za numeric := 0; v_znomes text[] := '{}';
  v_hp     numeric := 0; v_ha numeric := 0; v_hnome text;
  v_somar  boolean;
  v_total  numeric;
  v_min    numeric;
  v_fixo_cliente boolean := false;
  v_vkm    numeric;
  v_guc    text := current_setting('pwex.regras', true);
begin
  -- regras do pedido (salvo ou ainda no formulário)
  if nullif(d ->> 'pedido_id', '') is not null then
    perform privado.usar_regras((select regras from public.pedidos where id = (d ->> 'pedido_id')::uuid));
  elsif d ? 'regras' then
    perform privado.usar_regras(d -> 'regras');
  end if;
  if v_cli is not null then select * into e from public.empresas where id = v_cli; end if;
  select count(*) filter (where x ->> 'tipo' = 'coleta'), count(*) filter (where x ->> 'tipo' = 'entrega')
    into v_ncol, v_nent from jsonb_array_elements(coalesce(d -> 'pontos', '[]')) x;
  v_dist := coalesce(nullif(d ->> 'distancia_m', '')::numeric,
                     privado.distancia_estimada(d -> 'pontos') * privado.pol_num('fator_rua', 1.3, v_cli, null, v_tp));
  v_km := round(v_dist / 1000.0, 2);

  -- base e distância (o preço fixo do cadastro antigo do cliente ainda vale)
  if e.id is not null and e.modalidade_preco::text = 'fixo' and e.valor_fixo is not null
     and not exists (select 1 from public.politicas where escopo = 'cliente' and alvo = v_cli::text and chave in ('preco_base', 'preco_km'))
     and not (coalesce(nullif(current_setting('pwex.regras', true), '')::jsonb, '{}') ?| array['preco_base', 'preco_km']) then
    v_fixo_cliente := true;
    v_linhas := v_linhas || jsonb_build_object('rotulo', 'Preço fixo do cliente', 'valor', e.valor_fixo);
    v_sub := v_sub + e.valor_fixo;
  else
    v_val := privado.pol_num('preco_base', 8, v_cli, null, v_tp);
    if v_val <> 0 then v_linhas := v_linhas || jsonb_build_object('rotulo', 'Saída', 'valor', v_val); v_sub := v_sub + v_val; end if;
    v_vkm := privado.pol_num('preco_km', 2.5, v_cli, null, v_tp);
    if e.id is not null and e.modalidade_preco::text = 'por_km' and e.valor_km is not null
       and not exists (select 1 from public.politicas where escopo = 'cliente' and alvo = v_cli::text and chave = 'preco_km')
       and not (coalesce(nullif(current_setting('pwex.regras', true), '')::jsonb, '{}') ? 'preco_km') then
      v_vkm := e.valor_km;
    end if;
    v_val := round(v_km * v_vkm, 2);
    v_linhas := v_linhas || jsonb_build_object('rotulo', 'Distância', 'detalhe', format('%s km × R$ %s', v_km, v_vkm), 'valor', v_val);
    v_sub := v_sub + v_val;
  end if;

  -- pontos extras
  if v_ncol > 1 then
    v_val := (v_ncol - 1) * privado.pol_num('preco_coleta_extra', 5, v_cli, null, v_tp);
    if v_val <> 0 then v_linhas := v_linhas || jsonb_build_object('rotulo', 'Coletas extras', 'detalhe', format('%s × R$ %s', v_ncol - 1, privado.pol_num('preco_coleta_extra', 5, v_cli, null, v_tp)), 'valor', v_val); v_sub := v_sub + v_val; end if;
  end if;
  if v_nent > 1 then
    v_val := (v_nent - 1) * privado.pol_num('preco_entrega_extra', 5, v_cli, null, v_tp);
    if v_val <> 0 then v_linhas := v_linhas || jsonb_build_object('rotulo', 'Entregas extras', 'detalhe', format('%s × R$ %s', v_nent - 1, privado.pol_num('preco_entrega_extra', 5, v_cli, null, v_tp)), 'valor', v_val); v_sub := v_sub + v_val; end if;
  end if;

  -- pacotes, peso real × peso cubado
  select coalesce(sum(coalesce((i ->> 'quantidade')::int, 1)), 0),
         coalesce(sum(coalesce((i ->> 'quantidade')::int, 1) * coalesce((i ->> 'peso_kg')::numeric, 0)), 0),
         coalesce(sum(coalesce((i ->> 'quantidade')::int, 1) * coalesce((i ->> 'comprimento_cm')::numeric, 0) * coalesce((i ->> 'largura_cm')::numeric, 0)
                      * coalesce((i ->> 'altura_cm')::numeric, 0)), 0) / greatest(privado.pol_num('cubagem_fator', 6000, v_cli, null, v_tp), 1)
    into v_pac, v_real, v_cub from jsonb_array_elements(coalesce(d -> 'itens', '[]')) i;
  v_x := greatest(0, v_pac - privado.pol_num('preco_pacotes_inclusos', 1, v_cli, null, v_tp));
  if v_x > 0 then
    v_val := v_x * privado.pol_num('preco_pacote_extra', 1, v_cli, null, v_tp);
    if v_val <> 0 then v_linhas := v_linhas || jsonb_build_object('rotulo', 'Volumes extras', 'detalhe', format('%s volume(s) além do incluso', v_x), 'valor', v_val); v_sub := v_sub + v_val; end if;
  end if;
  v_tax := round(greatest(v_real, v_cub), 2);
  v_x := greatest(0, v_tax - privado.pol_num('preco_kg_incluso', 5, v_cli, null, v_tp));
  if v_x > 0 then
    v_val := round(v_x * privado.pol_num('preco_kg', 1, v_cli, null, v_tp), 2);
    if v_val <> 0 then
      v_linhas := v_linhas || jsonb_build_object('rotulo', 'Peso excedente',
        'detalhe', format('%s kg taxados (%s)', v_tax, case when v_cub > v_real then 'peso cubado' else 'peso real' end), 'valor', v_val);
      v_sub := v_sub + v_val;
    end if;
  end if;

  -- categorias
  v_perig := false;
  for v_cat in
    select k.id, k.nome, k.perigoso, k.adicional_item, k.adicional_fixo, k.fator_pct, sum(coalesce((i ->> 'quantidade')::int, 1)) q
      from jsonb_array_elements(coalesce(d -> 'itens', '[]')) i
      join public.categorias_produto k on k.id = nullif(i ->> 'categoria_id', '')::uuid
     group by k.id
  loop
    v_perig := v_perig or v_cat.perigoso;
    v_val := v_cat.adicional_fixo + v_cat.adicional_item * v_cat.q;
    if v_val <> 0 then v_linhas := v_linhas || jsonb_build_object('rotulo', v_cat.nome, 'detalhe', format('%s item(ns)', v_cat.q), 'valor', v_val); v_sub := v_sub + v_val; end if;
    if v_cat.fator_pct <> 0 then v_pcts := v_pcts || jsonb_build_object('rotulo', v_cat.nome, 'pct', v_cat.fator_pct); v_pct := v_pct + v_cat.fator_pct; end if;
  end loop;
  if v_perig then
    v_val := privado.pol_num('preco_perigoso_fixo', 10, v_cli, null, v_tp);
    if v_val <> 0 then v_linhas := v_linhas || jsonb_build_object('rotulo', 'Produto perigoso', 'valor', v_val); v_fixos := v_fixos + v_val; end if;
    v_x := privado.pol_num('preco_perigoso_pct', 30, v_cli, null, v_tp);
    if v_x <> 0 then v_pcts := v_pcts || jsonb_build_object('rotulo', 'Produto perigoso', 'pct', v_x); v_pct := v_pct + v_x; end if;
  end if;

  -- express e urgente
  if coalesce(d ->> 'tipo', 'express') = 'express' then
    v_x := privado.pol_num('preco_express_pct', 0, v_cli, null, v_tp);
    if v_x <> 0 then v_pcts := v_pcts || jsonb_build_object('rotulo', 'Express', 'pct', v_x); v_pct := v_pct + v_x; end if;
  end if;
  if coalesce((d ->> 'urgente')::boolean, false) then
    v_x := privado.pol_num('preco_urgente_pct', 20, v_cli, null, v_tp);
    if v_x <> 0 then v_pcts := v_pcts || jsonb_build_object('rotulo', 'Urgente', 'pct', v_x); v_pct := v_pct + v_x; end if;
  end if;

  -- zonas (raios com dinâmica de preço): algum ponto dentro do raio
  v_somar := privado.pol_txt('zona_combinar', 'maior', v_cli, null, v_tp) = 'somar';
  select coalesce(case when v_somar then sum(z.fator_pct) else max(z.fator_pct) end, 0),
         coalesce(case when v_somar then sum(z.adicional) else max(z.adicional) end, 0),
         coalesce(array_agg(z.nome), '{}')
    into v_zp, v_za, v_znomes
    from public.zonas z
   where z.ativa and (z.cliente_id = v_cli
          or (z.cliente_id is null and not (privado.pol_bool('zona_cliente_exclusiva', false, v_cli, null, v_tp)
                                            and exists (select 1 from public.zonas zz where zz.ativa and zz.cliente_id = v_cli))))
     and exists (select 1 from jsonb_array_elements(coalesce(d -> 'pontos', '[]')) x
                  where privado.dist_m(z.lat, z.lng, (x ->> 'lat')::double precision, (x ->> 'lng')::double precision) <= z.raio_m);
  if v_za <> 0 then v_linhas := v_linhas || jsonb_build_object('rotulo', 'Zona', 'detalhe', array_to_string(v_znomes, ', '), 'valor', v_za); v_fixos := v_fixos + v_za; end if;
  if v_zp <> 0 then v_pcts := v_pcts || jsonb_build_object('rotulo', 'Zona: ' || array_to_string(v_znomes, ', '), 'pct', v_zp); v_pct := v_pct + v_zp; end if;

  -- horário de pico (pelo horário da coleta)
  select f.fator_pct, f.adicional, f.nome into v_hp, v_ha, v_hnome
    from public.faixas_horario f
   where f.ativa and (f.cliente_id is null or f.cliente_id = v_cli)
     and extract(dow from v_quando at time zone 'America/Sao_Paulo')::int = any (f.dias)
     and (case when f.fim > f.inicio
               then (v_quando at time zone 'America/Sao_Paulo')::time >= f.inicio and (v_quando at time zone 'America/Sao_Paulo')::time < f.fim
               else (v_quando at time zone 'America/Sao_Paulo')::time >= f.inicio or (v_quando at time zone 'America/Sao_Paulo')::time < f.fim end)
   order by (f.cliente_id is null), f.fator_pct desc, f.adicional desc limit 1;
  if coalesce(v_ha, 0) <> 0 then v_linhas := v_linhas || jsonb_build_object('rotulo', v_hnome, 'valor', v_ha); v_fixos := v_fixos + v_ha; end if;
  if coalesce(v_hp, 0) <> 0 then v_pcts := v_pcts || jsonb_build_object('rotulo', v_hnome, 'pct', v_hp); v_pct := v_pct + v_hp; end if;

  v_total := v_sub * (1 + v_pct / 100.0) + v_fixos;
  v_min := privado.pol_num('valor_minimo', 0, v_cli, null, v_tp);
  v_total := privado.arredondar(greatest(v_total, v_min));
  perform set_config('pwex.regras', coalesce(v_guc, ''), true);
  return jsonb_build_object(
    'linhas', v_linhas, 'percentuais', v_pcts, 'subtotal', round(v_sub + v_fixos, 2), 'acrescimo_pct', v_pct,
    'minimo', v_min, 'total', v_total, 'km', v_km, 'distancia_m', round(v_dist),
    'coletas', v_ncol, 'entregas', v_nent, 'volumes', v_pac, 'peso_real_kg', round(v_real, 2), 'peso_cubado_kg', round(v_cub, 2),
    'peso_taxado_kg', v_tax, 'perigoso', v_perig, 'calculado_em', now());
end;
$$;


-- criar pedido: gestor como cliente, cliente em teste, regras do pedido, campos exigidos pela categoria
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
  end if;
  if v_gestor then v_regras := privado.limpar_regras(dados -> 'regras'); end if;
  if v_cli is not null and v_gestor and (select modo_teste from public.empresas where id = v_cli) then v_teste := true; end if;
  if v_cli is not null then select * into e from public.empresas where id = v_cli; end if;
  if not exists (select 1 from public.tipos_pedido where chave = v_tp and (ativo or v_gestor)) then raise exception 'tipo_pedido_invalido' using errcode = '22023'; end if;

  v_tipo := case when v_quando is null then 'express' else 'planejado' end;
  if not v_gestor then
    if v_tipo = 'express' and not (coalesce(e.pode_express, false) and privado.pol_bool('cliente_pode_express', true, v_cli, null, v_tp)) then
      raise exception 'cliente_so_agendado' using errcode = '42501';
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
  -- campos do item que a categoria exige
  for i in select * from jsonb_array_elements(coalesce(dados -> 'itens', '[]')) loop
    if nullif(i ->> 'categoria_id', '') is null then
      if not v_gestor and privado.cfg_bool('item_categoria_obrigatoria', false) then raise exception 'item_sem_categoria' using errcode = '22023'; end if;
      continue;
    end if;
    select * into v_cat from public.categorias_produto where id = (i ->> 'categoria_id')::uuid;
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
    insert into public.pedido_pontos (pedido_id, ordem, tipo, endereco, lat, lng, contato_nome, contato_telefone, instrucoes, referencias)
    values (v_id, k, (p ->> 'tipo')::public.tipo_parada, left(coalesce(p ->> 'endereco', ''), 300), (p ->> 'lat')::double precision, (p ->> 'lng')::double precision,
            nullif(left(p ->> 'contato_nome', 120), ''), nullif(left(p ->> 'contato_telefone', 40), ''), nullif(left(p ->> 'instrucoes', 500), ''),
            privado.limpar_referencias(p -> 'referencias'))
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

  if nullif(dados ->> 'modelo_id', '') is not null then
    update public.pedido_modelos set usos = usos + 1, usado_em = now() where id = (dados ->> 'modelo_id')::uuid;
  end if;
  perform privado.usar_regras('{}');
  perform privado.evento_pedido(v_id, 'criado', jsonb_build_object('origem', case when v_gestor then 'gestor' else 'cliente' end, 'total', v_orc -> 'total'));
  if v_status = 'aprovado' then perform privado.roteirizar(v_teste); end if;
  return v_id;
end;
$$;


-- revisar: nova ação "voltar_revisao" (desfaz a rota enquanto nenhuma parada foi feita)
create or replace function public.revisar_pedido(p_pedido uuid, p_acao text, p_valor numeric default null, p_motivo text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  p     public.pedidos%rowtype;
  v_orc jsonb;
  v_val numeric;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  select * into p from public.pedidos where id = p_pedido for update;
  if not found then raise exception 'pedido_nao_encontrado' using errcode = '22023'; end if;
  if p_acao = 'voltar_revisao' then
    if p.status not in ('aprovado', 'roteirizado', 'em_rota') then raise exception 'pedido_nao_pode_voltar' using errcode = '22023'; end if;
    if exists (select 1 from public.pedido_pontos x where x.pedido_id = p.id and x.status not in ('pendente', 'em_rota'))
       or exists (select 1 from public.paradas x where x.pedido_id = p.id and x.status::text in ('chegou', 'concluida'))
       or exists (select 1 from public.paradas x join public.corridas c on c.id = x.corrida_id
                   where x.pedido_id = p.id and (c.status::text = 'em_andamento'
                         or (c.status::text = 'aceita' and not privado.cfg_bool('voltar_revisao_aceitas', true)))) then
      raise exception 'pedido_em_andamento' using errcode = '22023';
    end if;
    perform privado.tirar_pedido_das_rotas(p.id, true);
    update public.pedidos set status = 'recebido', aprovado_em = null, revisado_por = null, revisado_em = null where id = p.id;
    update public.pedido_pontos set status = 'pendente' where pedido_id = p.id;
    perform privado.evento_pedido(p.id, 'voltou_revisao', jsonb_build_object('motivo', p_motivo));
    return (select to_jsonb(x) from public.pedidos x where x.id = p.id);
  end if;
  if p.status in ('concluido', 'cancelado', 'recusado') and p_acao <> 'ajustar' then raise exception 'pedido_finalizado' using errcode = '22023'; end if;
  if p.fatura_id is not null and exists (select 1 from public.faturas f where f.id = p.fatura_id and f.status <> 'rascunho') then
    raise exception 'pedido_ja_faturado' using errcode = '22023';
  end if;

  if p_acao = 'recalcular' then
    select privado.orcar(jsonb_build_object('pedido_id', p.id, 'empresa_id', p.empresa_id, 'tipo', p.tipo, 'tipo_pedido', p.tipo_pedido, 'quando', p.quando, 'urgente', p.urgente,
             'distancia_m', p.distancia_estimada_m,
             'pontos', (select jsonb_agg(jsonb_build_object('tipo', x.tipo, 'lat', x.lat, 'lng', x.lng) order by x.ordem) from public.pedido_pontos x where x.pedido_id = p.id),
             'itens', coalesce((select jsonb_agg(to_jsonb(i)) from public.pedido_itens i where i.pedido_id = p.id), '[]')))
      into v_orc;
    update public.pedidos set orcamento = v_orc, valor_calculado = (v_orc ->> 'total')::numeric,
           valor = (v_orc ->> 'total')::numeric + valor_ajuste, valor_dev = round(((v_orc ->> 'total')::numeric + valor_ajuste) * dev_pct / 100, 2)
     where id = p.id;
    perform privado.evento_pedido(p.id, 'recalculado', jsonb_build_object('total', v_orc -> 'total'));
  elsif p_acao in ('aprovar', 'ajustar') then
    if p_valor is not null then
      if p_valor < 0 then raise exception 'valor_invalido' using errcode = '22023'; end if;
      if p_valor <> coalesce(p.valor_calculado, 0) and coalesce(trim(p_motivo), '') = '' and p_valor <> p.valor then
        raise exception 'informe_o_motivo' using errcode = '22023';
      end if;
      v_val := round(p_valor, 2);
      update public.pedidos set valor = v_val, valor_ajuste = v_val - coalesce(valor_calculado, 0),
             ajuste_motivo = coalesce(nullif(trim(p_motivo), ''), ajuste_motivo), valor_dev = round(v_val * dev_pct / 100, 2)
       where id = p.id;
      -- a rota recebe a parte nova do valor
      perform privado.valores_rota(x.corrida_id) from (select distinct corrida_id from public.paradas where pedido_id = p.id) x;
      perform privado.evento_pedido(p.id, 'valor_ajustado', jsonb_build_object('de', p.valor, 'para', v_val, 'motivo', p_motivo));
    end if;
    if p_acao = 'aprovar' and p.status = 'recebido' then
      update public.pedidos set status = 'aprovado', aprovado_em = now(), revisado_por = auth.uid(), revisado_em = now() where id = p.id;
      perform privado.evento_pedido(p.id, 'aprovado');
      perform privado.roteirizar(p.teste);
    end if;
  elsif p_acao = 'recusar' then
    if p.status not in ('recebido', 'aprovado') then raise exception 'pedido_ja_em_rota' using errcode = '22023'; end if;
    update public.pedidos set status = 'recusado', recusa_motivo = nullif(trim(p_motivo), ''), revisado_por = auth.uid(), revisado_em = now() where id = p.id;
    perform privado.tirar_das_rotas(p.id);
    perform privado.evento_pedido(p.id, 'recusado', jsonb_build_object('motivo', p_motivo));
  else
    raise exception 'acao_invalida' using errcode = '22023';
  end if;
  return (select to_jsonb(x) from public.pedidos x where x.id = p.id);
end;
$$;


-- Tira as paradas do pedido das rotas que não começaram (e, se permitido, das aceitas sem parada feita)
create or replace function privado.tirar_pedido_das_rotas(p_pedido uuid, p_aceitas boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  for r in select distinct x.corrida_id id, c.status::text status, c.motoboy_id from public.paradas x join public.corridas c on c.id = x.corrida_id
            where x.pedido_id = p_pedido
              and (c.status::text in ('montada', 'agendada', 'reservada', 'aguardando_motoboy', 'sem_motoboy')
                   or (p_aceitas and c.status::text = 'aceita')) loop
    update public.ofertas set status = 'cancelada' where corrida_id = r.id and status = 'pendente';
    delete from public.paradas where corrida_id = r.id and pedido_id = p_pedido;
    if not exists (select 1 from public.paradas where corrida_id = r.id and tipo = 'entrega') then
      update public.corridas set status = 'cancelada', cancelada_em = now() where id = r.id;
      perform privado.evento(r.id, 'cancelada', jsonb_build_object('motivo', 'pedido voltou para revisão'));
      if r.motoboy_id is not null then
        update public.motoboys set status = 'disponivel', status_em = now() where id = r.motoboy_id and status = 'em_corrida';
        perform privado.enviar_push(r.motoboy_id, jsonb_build_object('tipo', 'cancelada', 'corrida_id', r.id::text));
      end if;
    else
      -- sobrou coleta sem entrega? sai também
      delete from public.paradas pa where pa.corrida_id = r.id and pa.tipo = 'coleta'
         and pa.pedido_id is not null and not exists (select 1 from public.paradas e where e.corrida_id = r.id and e.tipo = 'entrega' and e.pedido_id = pa.pedido_id);
      perform privado.ordenar_rota(r.id);
      perform privado.valores_rota(r.id);
      perform privado.evento(r.id, 'rota_atualizada', jsonb_build_object('motivo', 'pedido voltou para revisão'));
    end if;
  end loop;
end;
$$;


-- roteirizador: as regras de cada pedido valem enquanto ele é encaixado
create or replace function privado.roteirizar(p_teste boolean default false)
returns int language plpgsql security definer set search_path = '' as $$
declare
  t          record;
  r          record;
  v_rota     uuid;
  v_col      uuid;
  v_n        int := 0;
  v_tocadas  uuid[] := '{}';
  v_novas    uuid[] := '{}';
  v_id       uuid;
  v_janela   interval := make_interval(mins => privado.cfg_num('rota_janela_min', 30)::int);
  v_antes    interval := make_interval(mins => privado.cfg_num('rota_montar_antes_min', 1440)::int);
  v_espera   interval := make_interval(mins => privado.cfg_num('express_agrupar_espera_min', 0)::int);
  v_rc       double precision;
  v_re       double precision;
  v_maxe     int;
  v_maxc     int;
  v_maxkm    double precision;
  v_agrupar  boolean;
  v_perig_ex boolean := privado.cfg_bool('perigoso_rota_exclusiva', true);
  v_codigo   boolean := privado.cfg_bool('padrao_exige_codigo', false);
begin
  if not privado.cfg_bool('roteirizador_ligado', true) then return 0; end if;
  perform pg_advisory_xact_lock(hashtext('pwex_roteirizar_' || p_teste::text));

  for t in
    select e.id entrega_id, e.lat, e.lng, e.endereco, e.contato_nome, e.contato_telefone, e.instrucoes, e.referencias,
           p.id pedido_id, p.empresa_id, p.tipo, p.tipo_pedido, p.quando, p.urgente, p.observacoes,
           col.id coleta_id, col.lat clat, col.lng clng,
           exists (select 1 from public.pedido_itens i join public.categorias_produto k on k.id = i.categoria_id
                    where i.pedido_id = p.id and k.perigoso and (i.entrega_id = e.id or i.entrega_id is null)) perigoso
      from public.pedido_pontos e
      join public.pedidos p on p.id = e.pedido_id
      cross join lateral (
        select c.* from public.pedido_pontos c
         where c.pedido_id = p.id and c.tipo = 'coleta'
         order by (exists (select 1 from public.pedido_itens i where i.pedido_id = p.id and i.entrega_id = e.id and i.coleta_id = c.id)) desc, c.ordem
         limit 1) col
     where e.tipo = 'entrega' and e.status = 'pendente' and p.teste = p_teste
       and p.status in ('aprovado', 'roteirizado')
       and (p.cobranca <> 'pre_pago' or p.pagamento_status = 'pago')
       and not exists (select 1 from public.paradas x join public.corridas k on k.id = x.corrida_id
                        where x.pedido_ponto_id = e.id and k.status::text <> 'cancelada')
       and ((p.tipo = 'express' and coalesce(p.aprovado_em, p.criado_em) <= now() - v_espera)
            or (p.tipo = 'planejado' and p.quando - v_antes <= now()))
     order by coalesce(p.quando, p.aprovado_em, p.criado_em), p.numero, e.ordem
  loop
    perform privado.usar_regras((select regras from public.pedidos where id = t.pedido_id));
    v_rc := privado.pol_num('rota_raio_coleta_km', 2, t.empresa_id, null, t.tipo_pedido) * 1000;
    v_re := privado.pol_num('rota_raio_entrega_km', 3, t.empresa_id, null, t.tipo_pedido) * 1000;
    v_maxe := privado.pol_num('rota_max_entregas', 5, t.empresa_id, null, t.tipo_pedido)::int;
    v_maxc := privado.pol_num('rota_max_coletas', 3, t.empresa_id, null, t.tipo_pedido)::int;
    v_maxkm := privado.pol_num('rota_max_km', 0, t.empresa_id, null, t.tipo_pedido) * 1000;
    v_agrupar := privado.pol_bool('roteirizar_agrupar', true, t.empresa_id, null, t.tipo_pedido);
    v_rota := null; v_col := null;

    if v_agrupar then
      select k.id rota, cp.id coleta_parada, cp.mesmo into r
        from public.corridas k
        cross join lateral (select x.lat, x.lng from public.paradas x where x.corrida_id = k.id and x.tipo = 'coleta' order by x.ordem limit 1) c0
        cross join lateral (
          select x.id, (x.pedido_ponto_id = t.coleta_id) mesmo from public.paradas x
           where x.corrida_id = k.id and x.tipo = 'coleta'
             and (x.pedido_ponto_id = t.coleta_id or privado.dist_m(x.lat, x.lng, t.clat, t.clng) <= v_rc)
           order by (x.pedido_ponto_id = t.coleta_id) desc, privado.dist_m(x.lat, x.lng, t.clat, t.clng) limit 1) cp
        cross join lateral (
          select min(privado.dist_m(x.lat, x.lng, t.lat, t.lng)) d, count(*) n from public.paradas x where x.corrida_id = k.id and x.tipo = 'entrega') ent
        cross join lateral (select count(*) n from public.paradas x where x.corrida_id = k.id and x.tipo = 'coleta') ncol
       where k.origem = 'roteirizador' and k.teste = p_teste and k.motoboy_id is null
         and k.status::text in ('montada', 'agendada', 'aguardando_motoboy', 'sem_motoboy')
         and not exists (select 1 from public.ofertas o where o.corrida_id = k.id and o.status = 'pendente')
         and (k.agendada_para is null) = (t.tipo = 'express')
         and (case when t.tipo = 'express' then k.criada_em >= now() - v_janela
                   else abs(extract(epoch from (k.agendada_para - t.quando))) <= extract(epoch from v_janela) end)
         and ent.n < v_maxe
         and ent.d <= v_re
         and (cp.mesmo or ncol.n < v_maxc)
         and (v_maxkm <= 0 or privado.dist_m(c0.lat, c0.lng, t.lat, t.lng) <= v_maxkm)
         and (not v_perig_ex or k.tem_perigoso = t.perigoso)
         and (k.exclusiva_empresa is null or k.exclusiva_empresa = t.empresa_id)
         and (not privado.pol_bool('rota_exclusiva_cliente', false, t.empresa_id, null, t.tipo_pedido)
              or not exists (select 1 from public.paradas x join public.pedidos pp on pp.id = x.pedido_id
                              where x.corrida_id = k.id and pp.empresa_id is distinct from t.empresa_id))
         and coalesce(k.urgente, false) = coalesce(t.urgente, false)
       order by ent.d
       limit 1;
      if r.rota is not null then
        v_rota := r.rota;
        if r.mesmo then v_col := r.coleta_parada; end if;
      end if;
    end if;

    if v_rota is null then
      insert into public.corridas (
        status, origem, teste, empresa_id, tipo_pedido, agendada_para, urgente, modo_despacho, montada_em,
        exige_foto, exige_assinatura, exige_nome, exige_codigo, codigo_entrega, exigir_no_local, raio_chegada_m,
        aplicar_acrescimo, tem_perigoso, exclusiva_empresa, observacoes)
      values (
        'montada', 'roteirizador', p_teste, t.empresa_id, t.tipo_pedido, case when t.tipo = 'planejado' then t.quando end, coalesce(t.urgente, false),
        'quadro', now(),
        privado.cfg_bool('padrao_exige_foto', false), privado.cfg_bool('padrao_exige_assinatura', false), privado.cfg_bool('padrao_exige_nome', true),
        v_codigo, case when v_codigo then lpad((floor(random() * 10000))::int::text, 4, '0') end,
        privado.cfg_bool('exigir_no_local', true), privado.cfg_num('raio_chegada_m', 150)::int,
        false, t.perigoso,
        case when privado.pol_bool('rota_exclusiva_cliente', false, t.empresa_id, null, t.tipo_pedido) then t.empresa_id end,
        t.observacoes)
      returning id into v_rota;
      v_novas := v_novas || v_rota;
    end if;

    if v_col is null then
      insert into public.paradas (corrida_id, ordem, tipo, endereco, lat, lng, contato_nome, contato_telefone, instrucoes, referencias, pedido_id, pedido_ponto_id)
      select v_rota, 100000 + coalesce((select max(ordem) from public.paradas where corrida_id = v_rota), 0) + 1, 'coleta', c.endereco, c.lat, c.lng,
             c.contato_nome, c.contato_telefone, c.instrucoes, c.referencias, t.pedido_id, c.id
        from public.pedido_pontos c where c.id = t.coleta_id;
    end if;
    insert into public.paradas (corrida_id, ordem, tipo, endereco, lat, lng, contato_nome, contato_telefone, instrucoes, referencias, pedido_id, pedido_ponto_id)
    values (v_rota, 100000 + coalesce((select max(ordem) from public.paradas where corrida_id = v_rota), 0) + 1, 'entrega', t.endereco, t.lat, t.lng,
            t.contato_nome, t.contato_telefone, t.instrucoes, t.referencias, t.pedido_id, t.entrega_id);

    update public.pedidos set status = 'roteirizado' where id = t.pedido_id and status = 'aprovado';
    if not (v_rota = any (v_tocadas)) then v_tocadas := v_tocadas || v_rota; end if;
    v_n := v_n + 1;
  end loop;
  perform privado.usar_regras('{}');

  foreach v_id in array v_tocadas loop
    perform privado.ordenar_rota(v_id);
    perform privado.valores_rota(v_id);
    if not (v_id = any (v_novas)) then perform privado.evento(v_id, 'rota_atualizada', jsonb_build_object('entregas', (select count(*) from public.paradas where corrida_id = v_id and tipo = 'entrega'))); end if;
  end loop;
  foreach v_id in array v_novas loop
    perform privado.evento(v_id, 'rota_montada', jsonb_build_object('entregas', (select count(*) from public.paradas where corrida_id = v_id and tipo = 'entrega')));
    if not privado.pol_bool('rota_revisao_gestor', false, (select empresa_id from public.corridas where id = v_id), null,
                            (select tipo_pedido from public.corridas where id = v_id)) then
      perform privado.liberar_rota(v_id);
    end if;
  end loop;
  return v_n;
end;
$$;


-- lado do cliente: campos por categoria, opções e modo teste
create or replace function public.minha_conta_cliente()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_cli uuid := privado.minha_empresa(); e public.empresas%rowtype;
begin
  if v_cli is null then return null; end if;
  select * into e from public.empresas where id = v_cli;
  return jsonb_build_object(
    'id', e.id, 'nome', e.nome, 'tipo', e.tipo, 'documento', coalesce(e.cnpj, e.cpf), 'telefone', e.telefone, 'email', e.email,
    'endereco', e.endereco, 'lat', e.lat, 'lng', e.lng, 'instrucoes_coleta', e.instrucoes_coleta,
    'pode_express', e.pode_express and privado.pol_bool('cliente_pode_express', true, v_cli), 've_ao_vivo', e.cliente_ve_ao_vivo,
    'cobranca', privado.pol_txt('cobranca_modo', 'credito', v_cli), 'fatura_ciclo', privado.pol_txt('fatura_ciclo', 'semanal', v_cli),
    'metodos', to_jsonb(e.pagamento_metodos), 'antecedencia_min', privado.pol_num('agendada_antecedencia_cliente_min', 60, v_cli),
    'tipos_pedido', (select coalesce(jsonb_agg(jsonb_build_object('chave', t.chave, 'nome', t.nome, 'descricao', t.descricao, 'icone', t.icone) order by t.ordem), '[]')
                       from public.tipos_pedido t where t.ativo),
    'categorias', (select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'nome', k.nome, 'descricao', k.descricao, 'perigoso', k.perigoso,
                                                               'classe_risco', k.classe_risco, 'fragil', k.fragil, 'icone', k.icone,
                                                               'campo_descricao', k.campo_descricao, 'campo_peso', k.campo_peso, 'campo_medidas', k.campo_medidas,
                                                               'campo_valor', k.campo_valor, 'campo_quantidade', k.campo_quantidade) order by k.ordem), '[]')
                     from public.categorias_produto k where k.ativa),
    'icone', e.icone, 'teste', privado.cliente_teste(),
    'pode_modelos', privado.pol_bool('cliente_pode_modelos', true, v_cli), 'pode_cancelar', privado.pol_bool('cliente_pode_cancelar', true, v_cli),
    'troca_senha', privado.pol_bool('cliente_troca_senha', true, v_cli), 'categoria_obrigatoria', privado.cfg_bool('item_categoria_obrigatoria', false),
    'em_aberto', (select coalesce(sum(valor), 0) from public.pedidos where empresa_id = v_cli and teste = privado.cliente_teste() and cobranca = 'credito' and fatura_id is null and status = 'concluido'));
end;
$$;

create or replace function public.meus_pedidos_cliente(p_dias int default 120)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(x order by (x ->> 'criado_em') desc), '[]'::jsonb) from (
    select jsonb_build_object(
      'id', p.id, 'numero', p.numero, 'tipo', p.tipo, 'tipo_pedido', p.tipo_pedido, 'quando', p.quando, 'urgente', p.urgente,
      'status', p.status, 'valor', p.valor, 'orcamento', p.orcamento, 'cobranca', p.cobranca, 'pagamento_status', p.pagamento_status,
      'pagamento_metodo', p.pagamento_metodo, 'fatura_id', p.fatura_id, 'observacoes', p.observacoes, 'recusa_motivo', p.recusa_motivo,
      'criado_em', p.criado_em, 'concluido_em', p.concluido_em, 'cancelado_em', p.cancelado_em,
      'pontos', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'tipo', x.tipo, 'endereco', x.endereco, 'lat', x.lat, 'lng', x.lng,
                                 'contato_nome', x.contato_nome, 'status', x.status, 'concluido_em', x.concluido_em, 'recebedor_nome', x.recebedor_nome) order by x.ordem)
                          from public.pedido_pontos x where x.pedido_id = p.id), '[]'),
      'itens', coalesce((select jsonb_agg(jsonb_build_object('descricao', i.descricao, 'quantidade', i.quantidade, 'peso_kg', i.peso_kg,
                                'categoria', k.nome, 'categoria_id', i.categoria_id, 'icone', k.icone, 'perigoso', coalesce(k.perigoso, false),
                                'comprimento_cm', i.comprimento_cm, 'largura_cm', i.largura_cm, 'altura_cm', i.altura_cm, 'valor_declarado', i.valor_declarado))
                         from public.pedido_itens i left join public.categorias_produto k on k.id = i.categoria_id where i.pedido_id = p.id), '[]'),
      'motoboys', (select coalesce(jsonb_agg(distinct split_part(pf.nome, ' ', 1)) filter (where privado.pol_bool('cliente_ve_motoboy', true, p.empresa_id)), '[]') from public.paradas pa join public.corridas c on c.id = pa.corrida_id
                     join public.perfis pf on pf.id = c.motoboy_id where pa.pedido_id = p.id and c.status::text <> 'cancelada'),
      'codigos', (select coalesce(jsonb_agg(distinct c.codigo_entrega) filter (where c.codigo_entrega is not null and privado.pol_bool('cliente_ve_codigo', true, p.empresa_id)), '[]') from public.paradas pa
                    join public.corridas c on c.id = pa.corrida_id where pa.pedido_id = p.id and c.exige_codigo and c.status::text not in ('cancelada', 'concluida'))
    ) x
      from public.pedidos p
     where p.empresa_id = privado.minha_empresa() and p.teste = privado.cliente_teste()
       and p.criado_em > now() - make_interval(days => greatest(1, least(p_dias, 400)))
     limit 500
  ) t;
$$;

create or replace function public.minhas_faturas()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', f.id, 'numero', f.numero, 'inicio', f.inicio, 'fim', f.fim, 'status', f.status, 'subtotal', f.subtotal, 'ajuste', f.ajuste,
      'ajuste_motivo', f.ajuste_motivo, 'total', f.total, 'vencimento', f.vencimento, 'emitida_em', f.emitida_em, 'paga_em', f.paga_em,
      'pedidos', (select coalesce(jsonb_agg(jsonb_build_object('numero', p.numero, 'concluido_em', p.concluido_em, 'valor', p.valor,
                     'entregas', (select count(*) from public.pedido_pontos x where x.pedido_id = p.id and x.tipo = 'entrega')) order by p.concluido_em), '[]')
                    from public.pedidos p where p.fatura_id = f.id)) order by f.fim desc), '[]')
    from public.faturas f
   where f.empresa_id = privado.minha_empresa() and f.teste = privado.cliente_teste() and f.status in ('emitida', 'paga');
$$;

create or replace function public.cancelar_pedido(p_pedido uuid, p_motivo text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare p public.pedidos%rowtype;
begin
  select * into p from public.pedidos where id = p_pedido for update;
  if not found or not (public.is_gestor() or (p.empresa_id is not null and p.empresa_id = privado.minha_empresa())) then
    raise exception 'pedido_nao_encontrado' using errcode = '22023';
  end if;
  if p.status in ('concluido', 'cancelado', 'recusado') then raise exception 'pedido_finalizado' using errcode = '22023'; end if;
  if not public.is_gestor() and not privado.pol_bool('cliente_pode_cancelar', true, p.empresa_id) then raise exception 'cliente_nao_cancela' using errcode = '42501'; end if;
  if exists (select 1 from public.paradas x join public.corridas c on c.id = x.corrida_id
              where x.pedido_id = p.id and c.status::text in ('aceita', 'em_andamento', 'concluida')) then
    raise exception 'pedido_em_andamento' using errcode = '22023';
  end if;
  if not public.is_gestor() and exists (select 1 from public.paradas x join public.corridas c on c.id = x.corrida_id
                                         where x.pedido_id = p.id and c.status::text = 'reservada') then
    raise exception 'pedido_em_andamento' using errcode = '22023';
  end if;
  perform privado.tirar_das_rotas(p.id);
  update public.pedidos set status = 'cancelado', cancelado_em = now() where id = p.id;
  update public.pedido_pontos set status = 'cancelado' where pedido_id = p.id and status <> 'concluido';
  perform privado.evento_pedido(p.id, 'cancelado', jsonb_build_object('motivo', p_motivo, 'por_cliente', not public.is_gestor()));
end;
$$;


-- perfil do app: parâmetros novos
create or replace function public.meu_perfil()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', p.id,
    'nome', p.nome,
    'foto_url', p.foto_url,
    'papeis', to_jsonb(p.papeis),
    'gestor', 'gestor' = any (p.papeis) or 'dev' = any (p.papeis),
    'motoboy', 'motoboy' = any (p.papeis),
    'dev', 'dev' = any (p.papeis),
    'cor_tema', p.cor_tema,
    'modo_teste', coalesce(m.modo_teste, p.modo_teste),
    'raio', jsonb_build_object('km', m.raio_km, 'modo', coalesce(m.raio_modo, 'posicao'), 'lat', m.raio_lat, 'lng', m.raio_lng),
    'modulos', coalesce((
      select jsonb_object_agg(md.chave,
        'dev' = any (p.papeis) or (md.ligado and (md.papeis is null or p.papeis && md.papeis)))
        from public.modulos md
    ), '{}'::jsonb),
    'configuracoes', coalesce((
      select jsonb_object_agg(chave, valor) from public.configuracoes
       where chave in ('intervalo_corrida_s', 'intervalo_economia_s', 'disponivel_envio_min',
                       'disponivel_distancia_m', 'raio_chegada_m', 'teste_admin_ignora_local', 'oferta_segundos',
                       'quadro_mostra_enderecos', 'quadro_mostra_itens', 'simulador_ligado', 'simulador_velocidade_kmh',
                       'motoboy_edita_veiculo', 'mapa_offline_some_h', 'mapa_offline_esmaecer', 'veiculo_obrigatorio')
    ), '{}'::jsonb)
  )
  from public.perfis p
  left join public.motoboys m on m.id = p.id
  where p.id = auth.uid();
$$;


-- ------------------------------------------------------------- simulador de posição (modo teste)
alter table public.localizacoes add column if not exists simulada boolean not null default false;

-- Gestor move um motoboy de TESTE (o servidor grava o ping como se viesse do celular)
create or replace function public.simular_posicao(p_motoboy uuid, p_lat double precision, p_lng double precision,
                                                  p_velocidade_ms real default null, p_direcao real default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare m public.motoboys%rowtype; v_sessao uuid; v_corrida uuid; v_status text;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if not privado.cfg_bool('simulador_ligado', true) then raise exception 'simulador_desligado' using errcode = '42501'; end if;
  if p_lat is null or p_lng is null or abs(p_lat) > 90 or abs(p_lng) > 180 then raise exception 'posicao_invalida' using errcode = '22023'; end if;
  select * into m from public.motoboys where id = p_motoboy for update;
  if not found then raise exception 'nao_e_motoboy' using errcode = '22023'; end if;
  if not coalesce(m.modo_teste, false) then raise exception 'so_em_modo_teste' using errcode = '42501'; end if;
  v_status := case when m.status::text = 'offline' then 'disponivel' else m.status::text end;
  select id into v_corrida from public.corridas where motoboy_id = p_motoboy and status::text in ('aceita', 'em_andamento') order by aceita_em desc limit 1;
  select l.sessao_id into v_sessao from public.localizacoes l
   where l.motoboy_id = p_motoboy and l.registrado_em > now() - interval '20 minutes' and l.status::text = v_status
   order by l.registrado_em desc limit 1;
  insert into public.localizacoes (motoboy_id, id_local, sessao_id, corrida_id, status, lat, lng, precisao_m, velocidade_ms, direcao_graus, bateria, registrado_em, simulada)
  values (p_motoboy, gen_random_uuid(), coalesce(v_sessao, gen_random_uuid()), case when v_status = 'em_corrida' then v_corrida end,
          v_status::public.status_motoboy, p_lat, p_lng, 5, p_velocidade_ms, p_direcao, coalesce(m.bateria, 100), now(), true);
  update public.motoboys set lat = p_lat, lng = p_lng, precisao_m = 5, posicao_em = now(),
         status = v_status::public.status_motoboy, status_em = case when m.status::text = 'offline' then now() else status_em end
   where id = p_motoboy;
  return jsonb_build_object('lat', p_lat, 'lng', p_lng, 'status', v_status);
end;
$$;


-- ------------------------------------------------------------- versão do app (o Dev escolhe; as outras não rodam)
insert into public.configuracoes (chave, valor) values
  ('app_versao_exigida', '0'),        -- build que deve rodar (0 = sempre a mais nova publicada)
  ('app_forcar_versao',  'true'),     -- outra versão fica bloqueada até atualizar
  ('app_dev_livre',      'true'),     -- contas Dev podem testar qualquer versão
  ('app_repo',           '"Avttok/PWEx_App"')
on conflict (chave) do nothing;

alter table public.motoboys add column if not exists app_versao int;
alter table public.motoboys add column if not exists app_versao_em timestamptz;

-- Só o Dev mexe nas chaves da versão
create or replace function privado.proteger_config_dev()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is not null and not public.is_dev() and new.chave in ('app_versao_exigida', 'app_forcar_versao', 'app_dev_livre', 'app_repo') then
    raise exception 'apenas_dev' using errcode = '42501';
  end if;
  return new;
end;
$$;
drop trigger if exists configuracoes_proteger_app on public.configuracoes;
create trigger configuracoes_proteger_app before insert or update on public.configuracoes for each row execute function privado.proteger_config_dev();

-- Versão que o app informa em todo pedido ao servidor (cabeçalho x-pwex-versao)
create or replace function privado.versao_do_app()
returns int language sql stable set search_path = '' as $$
  select nullif(regexp_replace(coalesce(nullif(current_setting('request.headers', true), '')::json ->> 'x-pwex-versao', ''), '[^0-9]', '', 'g'), '')::int;
$$;

-- Bloqueia o app numa versão que o Dev não escolheu (só nas funções do motoboy)
create or replace function privado.checar_versao_app()
returns void language plpgsql stable security definer set search_path = '' as $$
declare v_exig int := privado.cfg_num('app_versao_exigida', 0)::int; v_app int := privado.versao_do_app();
begin
  if v_exig <= 0 or not privado.cfg_bool('app_forcar_versao', true) then return; end if;
  if privado.eh_servico() then return; end if;
  if privado.cfg_bool('app_dev_livre', true) and public.is_dev() then return; end if;
  if v_app is distinct from v_exig then
    raise exception 'versao_nao_autorizada' using errcode = '42501', detail = format('instalada %s, exigida %s', coalesce(v_app::text, 'antiga'), v_exig);
  end if;
end;
$$;

-- Anota a versão que cada motoboy está usando (o Dev vê no console)
create or replace function privado.anotar_versao_app()
returns void language plpgsql volatile security definer set search_path = '' as $$
declare v int := privado.versao_do_app();
begin
  if v is null or auth.uid() is null then return; end if;
  update public.motoboys set app_versao = v, app_versao_em = now()
   where id = auth.uid() and (app_versao is distinct from v or app_versao_em < now() - interval '10 minutes');
end;
$$;

-- O app pergunta qual versão deve rodar (antes e depois do login)
create or replace function public.versao_app()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'exigida', privado.cfg_num('app_versao_exigida', 0)::int,
    'forcar', privado.cfg_bool('app_forcar_versao', true),
    'dev_livre', privado.cfg_bool('app_dev_livre', true) and coalesce(public.is_dev(), false),
    'url', case when privado.cfg_num('app_versao_exigida', 0)::int > 0 then
             format('https://github.com/%s/releases/download/build-%s/PWExpress-motoboy-build%s.apk',
                    privado.cfg_txt('app_repo', 'Avttok/PWEx_App'), privado.cfg_num('app_versao_exigida', 0)::int, privado.cfg_num('app_versao_exigida', 0)::int) end);
$$;

-- Dev: quem está em qual versão
create or replace function public.versoes_em_uso()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'nome', p.nome, 'versao', m.app_versao, 'em', m.app_versao_em, 'teste', m.modo_teste)
                                    order by m.app_versao desc nulls last, p.nome), '[]')
            from public.motoboys m join public.perfis p on p.id = m.id where 'motoboy' = any (p.papeis));
end;
$$;


create or replace function public.registrar_localizacoes(pontos jsonb)
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid       uuid := auth.uid();
  v_inseridos integer := 0;
  v_ultimo    jsonb;
  v_corrida   uuid;
begin
  perform privado.checar_versao_app();
  perform privado.anotar_versao_app();
  if v_uid is null then
    raise exception 'nao_autenticado' using errcode = '28000';
  end if;
  if not public.tem_papel('motoboy'::public.papel_usuario) then
    raise exception 'usuario_nao_e_motoboy' using errcode = '42501';
  end if;
  if pontos is null or jsonb_typeof(pontos) <> 'array' or jsonb_array_length(pontos) = 0 then
    return 0;
  end if;
  if jsonb_array_length(pontos) > 500 then
    raise exception 'lote_grande_demais' using errcode = '22023';
  end if;

  insert into public.motoboys (id) values (v_uid) on conflict (id) do nothing;

  select id into v_corrida from public.corridas
   where motoboy_id = v_uid and status in ('aceita', 'em_andamento')
   order by aceita_em desc limit 1;

  insert into public.localizacoes (
    motoboy_id, id_local, sessao_id, corrida_id, status, lat, lng,
    precisao_m, velocidade_ms, direcao_graus, altitude_m, bateria, registrado_em
  )
  select
    v_uid,
    (p ->> 'id_local')::uuid,
    nullif(p ->> 'sessao_id', '')::uuid,
    coalesce(nullif(p ->> 'corrida_id', '')::uuid,
             case when (p ->> 'status') = 'em_corrida' then v_corrida end),
    (p ->> 'status')::public.status_motoboy,
    (p ->> 'lat')::double precision,
    (p ->> 'lng')::double precision,
    (p ->> 'precisao_m')::real,
    (p ->> 'velocidade_ms')::real,
    (p ->> 'direcao_graus')::real,
    (p ->> 'altitude_m')::real,
    (p ->> 'bateria')::smallint,
    (p ->> 'registrado_em')::timestamptz
  from jsonb_array_elements(pontos) as p
  on conflict (motoboy_id, id_local) do nothing;

  get diagnostics v_inseridos = row_count;

  select p into v_ultimo
  from jsonb_array_elements(pontos) as p
  order by (p ->> 'registrado_em')::timestamptz desc
  limit 1;

  update public.motoboys
     set lat        = (v_ultimo ->> 'lat')::double precision,
         lng        = (v_ultimo ->> 'lng')::double precision,
         precisao_m = (v_ultimo ->> 'precisao_m')::real,
         bateria    = (v_ultimo ->> 'bateria')::smallint,
         posicao_em = (v_ultimo ->> 'registrado_em')::timestamptz
   where id = v_uid
     and (posicao_em is null or posicao_em < (v_ultimo ->> 'registrado_em')::timestamptz);

  return v_inseridos;
end;
$$;


create or replace function public.atualizar_status(
  p_status        public.status_motoboy,
  p_modo_economia boolean default false,
  p_versao_app    text default null
)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_status public.status_motoboy := p_status;
begin
  perform privado.checar_versao_app();
  perform privado.anotar_versao_app();
  if v_uid is null then
    raise exception 'nao_autenticado' using errcode = '28000';
  end if;
  if not public.tem_papel('motoboy'::public.papel_usuario) then
    raise exception 'usuario_nao_e_motoboy' using errcode = '42501';
  end if;

  if exists (select 1 from public.corridas where motoboy_id = v_uid and status in ('aceita', 'em_andamento')) then
    v_status := 'em_corrida';
  elsif p_status = 'em_corrida' then
    v_status := 'disponivel';
  end if;

  insert into public.motoboys (id, status, modo_economia, versao_app, status_em)
  values (v_uid, v_status, p_modo_economia, p_versao_app, now())
  on conflict (id) do update
    set status        = excluded.status,
        modo_economia = excluded.modo_economia,
        versao_app    = coalesce(excluded.versao_app, public.motoboys.versao_app),
        status_em     = now();
end;
$$;


create or replace function public.reservar_corrida(p_corrida uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c       public.corridas%rowtype;
  v_teste boolean := coalesce((select modo_teste from public.motoboys where id = auth.uid()), false);
  v_folga interval := make_interval(mins => privado.cfg_num('agendada_intervalo_min', 30)::int);
begin
  perform privado.checar_versao_app();
  if not public.tem_papel('motoboy'::public.papel_usuario) then raise exception 'apenas_motoboy' using errcode = '42501'; end if;
  select * into c from public.corridas where id = p_corrida for update;
  if not found or c.status::text <> 'agendada' or c.motoboy_id is not null then
    raise exception 'corrida_ja_reservada' using errcode = '22023';
  end if;
  if c.teste <> v_teste then raise exception 'modo_teste_diferente' using errcode = '22023'; end if;
  if c.agendada_para <= now() then raise exception 'horario_passou' using errcode = '22023'; end if;
  if (select count(*) from public.corridas where motoboy_id = auth.uid() and status::text = 'reservada')
     >= privado.cfg_num('agendada_max_por_motoboy', 3) then
    raise exception 'limite_de_reservas' using errcode = '22023';
  end if;
  -- não deixa reservar duas no mesmo intervalo (duração prevista + folga)
  if exists (
    select 1 from public.corridas o
     where o.motoboy_id = auth.uid() and o.status::text = 'reservada'
       and tstzrange(o.agendada_para - v_folga, o.agendada_para + make_interval(secs => coalesce(o.duracao_planejada_s, 3600)) + v_folga)
           && tstzrange(c.agendada_para, c.agendada_para + make_interval(secs => coalesce(c.duracao_planejada_s, 3600)))
  ) then
    raise exception 'conflito_de_horario' using errcode = '22023';
  end if;

  update public.corridas set status = 'reservada'::text::public.status_corrida, motoboy_id = auth.uid(), reservada_em = now(),
         lembrete_enviado_em = null, atraso_avisado_em = null
   where id = p_corrida;
  perform privado.evento(p_corrida, 'reservada', jsonb_build_object('motoboy_id', auth.uid()));
  return privado.corrida_json(p_corrida);
end;
$$;


create or replace function public.responder_oferta(p_oferta uuid, p_aceitar boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  o       public.ofertas%rowtype;
  v_pct   numeric;
  v_valor numeric;
begin
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

  if exists (select 1 from public.corridas
              where motoboy_id = auth.uid() and status in ('aceita', 'em_andamento')) then
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


create or replace function public.avancar_parada(p_parada uuid, p_acao text, p_dados jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  p          public.paradas%rowtype;
  c          public.corridas%rowtype;
  v_atual    int;
  v_dados    jsonb := coalesce(p_dados, '{}');
  v_dist     double precision;
  v_tol      double precision;
  v_ignorar  boolean := false;
begin
  perform privado.checar_versao_app();
  select * into p from public.paradas where id = p_parada for update;
  if not found then raise exception 'parada_nao_encontrada' using errcode = '22023'; end if;
  select * into c from public.corridas where id = p.corrida_id for update;
  if c.motoboy_id is distinct from auth.uid() or c.status not in ('aceita', 'em_andamento') then
    raise exception 'corrida_nao_esta_ativa' using errcode = '22023';
  end if;
  if p_acao not in ('chegou', 'concluir') then raise exception 'acao_invalida' using errcode = '22023'; end if;

  select min(ordem) into v_atual from public.paradas where corrida_id = c.id and status <> 'concluida';
  if p.ordem <> v_atual then raise exception 'conclua_a_parada_anterior' using errcode = '22023'; end if;

  -- presença no local
  select d.distancia_m, d.tolerancia_m into v_dist, v_tol from privado.distancia_ate_parada(p, v_dados, auth.uid()) d;
  if c.exigir_no_local then
    v_ignorar := coalesce((v_dados ->> 'ignorar_local')::boolean, false)
                 and c.teste and public.is_gestor()
                 and privado.cfg_bool('teste_admin_ignora_local', true);
    if not v_ignorar then
      if v_dist is null then
        raise exception 'sem_localizacao' using errcode = '22023';
      end if;
      if v_dist - v_tol > c.raio_chegada_m then
        raise exception 'longe_do_local:%:%', round(v_dist), c.raio_chegada_m using errcode = '22023';
      end if;
    end if;
  end if;

  if c.status = 'aceita' then
    update public.corridas set status = 'em_andamento', iniciada_em = now() where id = c.id;
  end if;

  if p_acao = 'chegou' then
    update public.paradas
       set status = 'chegou', chegou_em = now(),
           distancia_chegada_m = round(v_dist), local_ignorado = v_ignorar
     where id = p.id;
    perform privado.evento(c.id, 'chegou', jsonb_build_object(
      'parada', p.ordem, 'tipo', p.tipo, 'distancia_m', round(v_dist), 'local_ignorado', v_ignorar));
    return privado.corrida_json(c.id);
  end if;

  -- concluir
  if p.tipo = 'entrega' then
    if c.exige_nome and coalesce(trim(v_dados ->> 'recebedor_nome'), '') = '' then
      raise exception 'informe_o_nome_de_quem_recebeu' using errcode = '22023';
    end if;
    if c.exige_codigo and coalesce(v_dados ->> 'codigo', '') <> coalesce(c.codigo_entrega, '') then
      raise exception 'codigo_incorreto' using errcode = '22023';
    end if;
    if c.exige_foto and coalesce(v_dados ->> 'foto_path', '') = '' then
      raise exception 'falta_a_foto' using errcode = '22023';
    end if;
    if c.exige_assinatura and coalesce(v_dados ->> 'assinatura_path', '') = '' then
      raise exception 'falta_a_assinatura' using errcode = '22023';
    end if;
  end if;

  update public.paradas
     set status = 'concluida',
         chegou_em = coalesce(chegou_em, now()),
         concluida_em = now(),
         distancia_chegada_m = coalesce(distancia_chegada_m, round(v_dist)),
         local_ignorado = local_ignorado or v_ignorar,
         recebedor_nome = nullif(trim(v_dados ->> 'recebedor_nome'), ''),
         foto_path = nullif(v_dados ->> 'foto_path', ''),
         assinatura_path = nullif(v_dados ->> 'assinatura_path', '')
   where id = p.id;
  perform privado.evento(c.id, 'parada_concluida', jsonb_build_object(
    'parada', p.ordem, 'tipo', p.tipo, 'distancia_m', round(v_dist), 'local_ignorado', v_ignorar));

  update public.paradas set status = 'a_caminho'
   where corrida_id = c.id
     and ordem = (select min(ordem) from public.paradas where corrida_id = c.id and status = 'pendente');

  if not exists (select 1 from public.paradas where corrida_id = c.id and status <> 'concluida') then
    update public.corridas set status = 'concluida', concluida_em = now() where id = c.id;
    update public.motoboys set status = 'disponivel', status_em = now() where id = c.motoboy_id;
    perform privado.finalizar_trajeto(c.id, false);
    perform privado.evento(c.id, 'concluida');
    return null;
  end if;

  return privado.corrida_json(c.id);
end;
$$;


create or replace function public.iniciar_planejada(p_corrida uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c public.corridas%rowtype;
begin
  perform privado.checar_versao_app();
  select * into c from public.corridas where id = p_corrida;
  if not found or c.status::text <> 'reservada' or c.motoboy_id is distinct from auth.uid() then
    raise exception 'reserva_nao_encontrada' using errcode = '22023';
  end if;
  if now() < c.agendada_para - make_interval(mins => privado.cfg_num('agendada_iniciar_antes_min', 60)::int) then
    raise exception 'ainda_nao_pode_iniciar' using errcode = '22023';
  end if;
  perform privado.iniciar_reservada(p_corrida);
  return privado.corrida_json(p_corrida);
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
       and ((c.status::text in ('aguardando_motoboy', 'sem_motoboy') and c.modo_despacho::text = 'quadro')
            or (c.status::text = 'agendada' and c.agendada_para > now()))
       and (c.agendada_para is not null or c.urgente or coalesce(m.raio_km, 0) <= 0 or m.lat is null or privado.dist_m(
              case when m.raio_modo = 'fixo' and m.raio_lat is not null then m.raio_lat else m.lat end,
              case when m.raio_modo = 'fixo' and m.raio_lng is not null then m.raio_lng else m.lng end, col.lat, col.lng) <= m.raio_km * 1000)
  ), '[]'::jsonb);
end;
$$;


create or replace function public.corridas_planejadas()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_teste boolean := coalesce((select modo_teste from public.motoboys where id = auth.uid()), false);
begin
  perform privado.checar_versao_app();
  if not public.tem_papel('motoboy'::public.papel_usuario) then raise exception 'apenas_motoboy' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(privado.corrida_json(c.id) || jsonb_build_object('minha', coalesce(c.motoboy_id = auth.uid(), false)) order by c.agendada_para)
      from public.corridas c
     where c.agendada_para is not null and c.teste = v_teste
       and ((c.status::text = 'agendada' and c.agendada_para > now())
            or (c.status::text = 'reservada' and c.motoboy_id = auth.uid()))
  ), '[]'::jsonb);
end;
$$;


create or replace function public.oferta_pendente()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare o public.ofertas%rowtype; v jsonb;
begin
  perform privado.checar_versao_app();
  select * into o from public.ofertas where motoboy_id = auth.uid() and status = 'pendente' and expira_em > now() order by criada_em desc limit 1;
  if not found then return null; end if;
  v := privado.corrida_json(o.corrida_id);
  return jsonb_build_object('oferta_id', o.id, 'expira_em', o.expira_em,
    'segundos_restantes', greatest(0, extract(epoch from (o.expira_em - now())))::int, 'distancia_m', o.distancia_m, 'corrida', v);
end;
$$;


create or replace function public.pegar_rota(p_corrida uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c       public.corridas%rowtype;
  v_teste boolean := coalesce((select modo_teste from public.motoboys where id = auth.uid()), false);
begin
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


-- ------------------------------------------------------------- permissões
revoke all on all functions in schema privado from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array[
    'public.salvar_veiculo(uuid, jsonb)', 'public.meu_veiculo()', 'public.definir_icone(text, uuid, text)',
    'public.minha_empresa_id()', 'public.entrar_como_cliente(uuid)', 'public.meu_acesso_cliente()', 'public.vincular_cliente(uuid, uuid)',
    'public.revisar_cadastro(uuid, boolean, text, jsonb)', 'public.cadastro_aberto()', 'public.pode_salvar_modelos()',
    'public.definir_regras_pedido(uuid, jsonb)', 'public.criar_pedido(jsonb)', 'public.revisar_pedido(uuid, text, numeric, text)',
    'public.minha_conta_cliente()', 'public.meus_pedidos_cliente(int)', 'public.minhas_faturas()', 'public.cancelar_pedido(uuid, text)',
    'public.simular_posicao(uuid, double precision, double precision, real, real)', 'public.versao_app()', 'public.versoes_em_uso()'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
revoke all on function public.registrar_cadastro(jsonb) from public, anon, authenticated;
grant select on public.cadastros_cliente to authenticated;
grant select on public.acesso_como_cliente to authenticated;
grant select, insert, update, delete on public.pedido_modelos to authenticated;
do $$ begin execute 'grant execute on function public.registrar_cadastro(jsonb) to service_role'; exception when undefined_object then null; end $$;
do $$ begin execute 'grant execute on function public.cadastro_aberto() to anon'; exception when undefined_object then null; end $$;
do $$ begin execute 'grant execute on function public.versao_app() to anon'; exception when undefined_object then null; end $$;

do $$
declare t text;
begin
  foreach t in array array['cadastros_cliente', 'pedido_modelos'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object or undefined_object then null;
    end;
  end loop;
end $$;
