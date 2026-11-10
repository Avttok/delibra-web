-- =====================================================================
-- PW Express · 0012 (parte 2 de 2): Clientes, Carteira e pagamento
-- Rode DEPOIS de 20261108000004_status_pagamento.sql.
--
--  • "Empresas" viram "Clientes": pessoa jurídica (CNPJ) ou física (CPF).
--    Cliente novo só faz pedido agendado até o gestor liberar "Express".
--  • Divisão em três partes: motoboy 67,5% · gestão 27,5% · Dev 5%.
--    Ajustável por cliente e por corrida. O motoboy nunca vê percentuais.
--  • Chave PIX de cada pessoa (tabela própria, só a pessoa e a gestão leem).
--  • Pagamento: pedido do cliente nasce "aguardando pagamento" e só é
--    despachado quando o pagamento é confirmado (gestor, ou a intermediadora).
--  • Orçamento: switches explícitos para cada acréscimo por distância.
-- =====================================================================

-- ------------------------------------------------------------- configurações
insert into public.configuracoes (chave, valor) values
  ('dev_pct', '5'),
  ('acrescimo_coleta_ligado', 'true'),
  ('acrescimo_entrega_ligado', 'true')
on conflict (chave) do nothing;
-- 70/30 vira 67,5/27,5/5 (só se ainda estava no padrão antigo)
update public.configuracoes set valor = '67.5' where chave = 'repasse_motoboy_pct' and valor::text in ('70', '70.0');

-- cada acréscimo tem o próprio liga/desliga
create or replace function privado.fator_distancia(p_dist_m double precision, p_qual text)
returns numeric language sql stable security definer set search_path = '' as $$
  select case
    when not privado.cfg_bool('acrescimo_distancia', true) or p_dist_m is null then 0
    when not privado.cfg_bool('acrescimo_' || p_qual || '_ligado', true) then 0
    when privado.cfg_num('acrescimo_' || p_qual || '_cada_km', 0) <= 0 then 0
    else floor(p_dist_m / 1000 / privado.cfg_num('acrescimo_' || p_qual || '_cada_km', 0))
         * privado.cfg_num('acrescimo_' || p_qual || '_fator', 0)
  end;
$$;

-- ------------------------------------------------------------- clientes (PF ou PJ)
alter table public.empresas add column if not exists tipo text not null default 'pj';
alter table public.empresas add column if not exists cpf text;
alter table public.empresas add column if not exists pode_express boolean not null default false;
alter table public.empresas add column if not exists repasse_pct numeric(5, 2);
alter table public.empresas add column if not exists dev_pct numeric(5, 2);
alter table public.empresas add column if not exists pagamento_metodos text[] not null default '{pix,cartao}';
do $$ begin
  alter table public.empresas add constraint empresas_tipo_valido check (tipo in ('pj', 'pf'));
exception when duplicate_object then null; end $$;
create unique index if not exists empresas_cpf_unico on public.empresas (cpf) where cpf is not null;
-- quem já era cliente continua podendo pedir Express
do $$ begin
  if not exists (select 1 from public.configuracoes where chave = 'clientes_express_migrados') then
    update public.empresas set pode_express = true;
    insert into public.configuracoes (chave, valor) values ('clientes_express_migrados', 'true');
  end if;
end $$;

-- conta de cliente ligada a um cliente cadastrado
alter table public.perfis add column if not exists empresa_id uuid references public.empresas (id) on delete set null;

-- ------------------------------------------------------------- divisão em três partes
alter table public.corridas add column if not exists repasse_manual numeric(5, 2);
alter table public.corridas add column if not exists dev_manual numeric(5, 2);
alter table public.corridas add column if not exists dev_pct numeric(5, 2);
alter table public.corridas add column if not exists valor_dev numeric(10, 2);

-- Sempre que o valor do motoboy é congelado (no aceite), refaz a divisão:
-- corrida > cliente > (motoboy ou padrão) para o motoboy; corrida > cliente > padrão para o Dev.
create or replace function privado.dividir_valor()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_rep numeric; v_dev numeric; v_valor numeric;
begin
  if new.valor_motoboy is not null and (
       old.valor_motoboy is distinct from new.valor_motoboy or old.valor is distinct from new.valor
       or old.repasse_pct is distinct from new.repasse_pct) then
    v_rep := coalesce(new.repasse_manual, (select e.repasse_pct from public.empresas e where e.id = new.empresa_id), new.repasse_pct,
                      privado.cfg_num('repasse_motoboy_pct', 67.5));
    v_dev := coalesce(new.dev_manual, (select e.dev_pct from public.empresas e where e.id = new.empresa_id), privado.cfg_num('dev_pct', 5));
    v_valor := coalesce(new.valor, 0);
    new.repasse_pct := v_rep;
    new.dev_pct := v_dev;
    new.valor_motoboy := round(v_valor * v_rep / 100, 2);
    new.valor_dev := round(v_valor * v_dev / 100, 2);
    new.valor_gestao := v_valor - new.valor_motoboy - new.valor_dev;
  end if;
  return new;
end;
$$;
drop trigger if exists corridas_dividir_valor on public.corridas;
create trigger corridas_dividir_valor before update on public.corridas
  for each row execute function privado.dividir_valor();
update public.corridas set valor_dev = 0 where valor_dev is null and valor_motoboy is not null;

-- ------------------------------------------------------------- dados para receber (PIX)
create table if not exists public.dados_recebimento (
  usuario_id    uuid primary key references public.perfis (id) on delete cascade,
  tipo_chave    text not null check (tipo_chave in ('cpf', 'cnpj', 'email', 'telefone', 'aleatoria')),
  chave         text not null,
  titular       text not null,
  atualizado_em timestamptz not null default now()
);
alter table public.dados_recebimento enable row level security;
drop policy if exists dados_recebimento_leitura on public.dados_recebimento;
create policy dados_recebimento_leitura on public.dados_recebimento for select to authenticated
  using (usuario_id = (select auth.uid()) or (select public.is_gestor()));
revoke all on public.dados_recebimento from anon;
grant select on public.dados_recebimento to authenticated;

create or replace function public.definir_minha_chave_pix(p_tipo text, p_chave text, p_titular text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if coalesce(trim(p_chave), '') = '' then
    delete from public.dados_recebimento where usuario_id = auth.uid();
    return;
  end if;
  if p_tipo not in ('cpf', 'cnpj', 'email', 'telefone', 'aleatoria') then raise exception 'tipo_invalido' using errcode = '22023'; end if;
  if length(trim(p_titular)) < 3 then raise exception 'titular_invalido' using errcode = '22023'; end if;
  insert into public.dados_recebimento (usuario_id, tipo_chave, chave, titular, atualizado_em)
  values (auth.uid(), p_tipo, left(trim(p_chave), 120), left(trim(p_titular), 120), now())
  on conflict (usuario_id) do update set tipo_chave = excluded.tipo_chave, chave = excluded.chave, titular = excluded.titular, atualizado_em = now();
end;
$$;

-- ------------------------------------------------------------- pagamento
alter table public.corridas add column if not exists pagamento_status text not null default 'nao_exigido';
alter table public.corridas add column if not exists pagamento_metodo text;
alter table public.corridas add column if not exists pagamento_ref text;
alter table public.corridas add column if not exists pago_em timestamptz;
alter table public.corridas add column if not exists por_cliente boolean not null default false;
do $$ begin
  alter table public.corridas add constraint corridas_pagamento_valido check (pagamento_status in ('nao_exigido', 'pendente', 'pago', 'reembolsado', 'falhou'));
exception when duplicate_object then null; end $$;

-- Confirma o pagamento (gestor agora; a intermediadora depois, pelo servidor) e solta a corrida.
create or replace function public.confirmar_pagamento(p_corrida uuid, p_metodo text default null, p_ref text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare c public.corridas%rowtype;
begin
  if not public.is_gestor() and current_user not in ('service_role', 'postgres') then
    raise exception 'apenas_gestor' using errcode = '42501';
  end if;
  select * into c from public.corridas where id = p_corrida for update;
  if not found then raise exception 'corrida_inexistente' using errcode = '22023'; end if;
  if c.status::text <> 'aguardando_pagamento' then raise exception 'nao_aguarda_pagamento' using errcode = '22023'; end if;
  update public.corridas
     set pagamento_status = 'pago', pago_em = now(), pagamento_metodo = coalesce(p_metodo, pagamento_metodo), pagamento_ref = p_ref,
         status = (case when c.agendada_para is not null then 'agendada' else 'aguardando_motoboy' end)::public.status_corrida
   where id = p_corrida;
  perform privado.evento(p_corrida, 'pagamento_confirmado', jsonb_build_object('metodo', p_metodo, 'por', auth.uid()));
  if c.agendada_para is not null then
    perform privado.avisar_planejada(p_corrida, 'planejada_nova', null);
  else
    perform privado.despachar(p_corrida);
  end if;
end;
$$;

-- ------------------------------------------------------------- lado do cliente
create or replace function privado.minha_empresa()
returns uuid language sql stable security definer set search_path = '' as $$
  select empresa_id from public.perfis where id = auth.uid() and 'cliente' = any (papeis);
$$;

create or replace function public.minha_empresa_info()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', e.id, 'nome', e.nome, 'tipo', e.tipo, 'modalidade', e.modalidade_preco, 'valor_km', e.valor_km, 'valor_fixo', e.valor_fixo,
    'pode_express', e.pode_express, 've_ao_vivo', e.cliente_ve_ao_vivo, 'metodos', to_jsonb(e.pagamento_metodos),
    'endereco', e.endereco, 'lat', e.lat, 'lng', e.lng, 'instrucoes_coleta', e.instrucoes_coleta, 'telefone', e.telefone,
    'antecedencia_min', privado.cfg_num('agendada_antecedencia_min', 30),
    'valor_minimo', privado.cfg_num('valor_minimo', 0)
  )
  from public.empresas e where e.id = privado.minha_empresa();
$$;

-- Pedido feito pelo cliente: o preço é do cadastro dele; nasce aguardando o pagamento.
create or replace function public.cliente_criar_pedido(dados jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_emp   public.empresas%rowtype;
  v_id    uuid;
  v_quando timestamptz := nullif(dados ->> 'agendada_para', '')::timestamptz;
  v_dist  int := nullif(dados ->> 'distancia_planejada_m', '')::int;
  v_valor numeric;
begin
  select * into v_emp from public.empresas where id = privado.minha_empresa();
  if not found then raise exception 'apenas_cliente' using errcode = '42501'; end if;
  if jsonb_array_length(coalesce(dados -> 'paradas', '[]')) < 2 then raise exception 'corrida_precisa_de_2_paradas' using errcode = '22023'; end if;
  if (dados -> 'paradas' -> 0 ->> 'tipo') <> 'coleta' then raise exception 'primeira_parada_deve_ser_coleta' using errcode = '22023'; end if;
  if v_quando is null and not v_emp.pode_express then raise exception 'cliente_so_agendado' using errcode = '42501'; end if;
  if v_quando is not null and v_quando < now() + make_interval(mins => privado.cfg_num('agendada_antecedencia_min', 30)::int) then
    raise exception 'horario_muito_proximo' using errcode = '22023';
  end if;
  v_valor := case v_emp.modalidade_preco::text
    when 'fixo' then v_emp.valor_fixo
    when 'por_km' then case when v_dist is null then null else v_emp.valor_km * v_dist / 1000.0 end
    else null end;
  if v_valor is null then raise exception 'sem_preco_automatico' using errcode = '22023'; end if;
  v_valor := privado.arredondar(greatest(v_valor, privado.cfg_num('valor_minimo', 0)));

  insert into public.corridas (
    status, agendada_para, empresa_id, criada_por, modo_despacho, teste, por_cliente, pagamento_status, pagamento_metodo,
    exige_foto, exige_assinatura, exige_nome, exige_codigo, codigo_entrega, exigir_no_local, raio_chegada_m,
    distancia_planejada_m, duracao_planejada_s, rota_planejada, valor, observacoes
  ) values (
    'aguardando_pagamento', v_quando, v_emp.id, auth.uid(), 'cascata', false, true, 'pendente', nullif(dados ->> 'metodo', ''),
    privado.cfg_bool('padrao_exige_foto', false), privado.cfg_bool('padrao_exige_assinatura', false), privado.cfg_bool('padrao_exige_nome', true),
    true, lpad((floor(random() * 10000))::int::text, 4, '0'),
    privado.cfg_bool('exigir_no_local', true), privado.cfg_num('raio_chegada_m', 150)::int,
    v_dist, nullif(dados ->> 'duracao_planejada_s', '')::int, nullif(dados ->> 'rota_planejada', ''), v_valor,
    nullif(left(dados ->> 'observacoes', 500), '')
  ) returning id into v_id;

  insert into public.paradas (corrida_id, ordem, tipo, endereco, lat, lng, contato_nome, contato_telefone, instrucoes, referencias)
  select v_id, (ord - 1)::int, (p ->> 'tipo')::public.tipo_parada, left(p ->> 'endereco', 300),
         (p ->> 'lat')::double precision, (p ->> 'lng')::double precision,
         nullif(p ->> 'contato_nome', ''), nullif(p ->> 'contato_telefone', ''), nullif(p ->> 'instrucoes', ''),
         privado.limpar_referencias(p -> 'referencias')
    from jsonb_array_elements(dados -> 'paradas') with ordinality as t(p, ord);

  perform privado.evento(v_id, 'criada', jsonb_build_object('por_cliente', true, 'agendada_para', v_quando));
  return v_id;
end;
$$;

create or replace function public.cliente_cancelar_pedido(p_corrida uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.corridas set status = 'cancelada', cancelada_em = now()
   where id = p_corrida and empresa_id = privado.minha_empresa()
     and (status::text = 'aguardando_pagamento' or (status::text = 'agendada' and motoboy_id is null));
  if not found then raise exception 'nao_pode_cancelar' using errcode = '22023'; end if;
  perform privado.evento(p_corrida, 'cancelada', jsonb_build_object('por_cliente', true));
end;
$$;

-- Pedidos do cliente (sem dados internos: nada de repasse ou divisão)
create or replace function public.meus_pedidos(p_dias int default 120)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(x order by (x->>'criada_em') desc), '[]'::jsonb) from (
    select jsonb_build_object(
      'id', c.id, 'numero', c.numero, 'status', c.status, 'valor', c.valor, 'pagamento_status', c.pagamento_status,
      'pagamento_metodo', c.pagamento_metodo, 'agendada_para', c.agendada_para, 'criada_em', c.criada_em,
      'aceita_em', c.aceita_em, 'concluida_em', c.concluida_em, 'cancelada_em', c.cancelada_em, 'pago_em', c.pago_em,
      'distancia_m', coalesce(c.distancia_real_m, c.distancia_planejada_m), 'codigo_entrega', c.codigo_entrega,
      'rota', c.rota_planejada, 'motoboy', (select p.nome from public.perfis p where p.id = c.motoboy_id),
      'paradas', coalesce((select jsonb_agg(jsonb_build_object('tipo', pa.tipo, 'endereco', pa.endereco, 'status', pa.status, 'lat', pa.lat, 'lng', pa.lng,
                                 'concluida_em', pa.concluida_em, 'recebedor', pa.recebedor_nome) order by pa.ordem)
                            from public.paradas pa where pa.corrida_id = c.id), '[]'::jsonb)
    ) x
      from public.corridas c
     where c.empresa_id = privado.minha_empresa() and not c.teste
       and c.criada_em > now() - make_interval(days => greatest(1, least(p_dias, 400)))
     limit 500
  ) t;
$$;

-- Onde está o motoboy do meu pedido (só se o cliente vê ao vivo)
create or replace function public.acompanhar_pedido(p_corrida uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('lat', m.lat, 'lng', m.lng, 'posicao_em', m.posicao_em, 'status', c.status)
    from public.corridas c
    join public.empresas e on e.id = c.empresa_id
    left join public.motoboys m on m.id = c.motoboy_id
   where c.id = p_corrida and c.empresa_id = privado.minha_empresa() and e.cliente_ve_ao_vivo
     and c.status::text in ('aceita', 'em_andamento');
$$;

-- perfil: diz se é cliente e de qual cadastro
create or replace function privado.eh_cliente()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.perfis where id = auth.uid() and 'cliente' = any (papeis));
$$;

-- ------------------------------------------------------------- criar corrida (gestor) com divisão própria
create or replace function public.criar_corrida(dados jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_id    uuid;
  v_modo  public.modo_despacho := coalesce(nullif(dados ->> 'modo_despacho', ''), 'cascata')::public.modo_despacho;
  v_teste boolean := coalesce((dados ->> 'teste')::boolean, false);
  v_moto  uuid := nullif(dados ->> 'motoboy_id', '')::uuid;
  v_exige_codigo boolean := coalesce((dados ->> 'exige_codigo')::boolean, privado.cfg_bool('padrao_exige_codigo', false));
  -- planejada: tem horário para começar
  v_quando  timestamptz := nullif(dados ->> 'agendada_para', '')::timestamptz;
  v_serie   uuid := nullif(dados ->> 'serie_id', '')::uuid;
  v_status  text := 'aguardando_motoboy';
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if jsonb_array_length(coalesce(dados -> 'paradas', '[]')) < 2 then
    raise exception 'corrida_precisa_de_2_paradas' using errcode = '22023';
  end if;
  if (dados -> 'paradas' -> 0 ->> 'tipo') <> 'coleta' then
    raise exception 'primeira_parada_deve_ser_coleta' using errcode = '22023';
  end if;
  if v_modo = 'direto' and v_moto is null then
    raise exception 'escolha_o_motoboy' using errcode = '22023';
  end if;
  if v_modo = 'direto' and not exists (select 1 from public.motoboys where id = v_moto and modo_teste = v_teste) then
    raise exception '%', case when v_teste then 'motoboy_fora_do_modo_teste' else 'motoboy_em_modo_teste' end
      using errcode = '22023';
  end if;

  if v_quando is not null then
    if v_quando < now() + make_interval(mins => privado.cfg_num('agendada_antecedencia_min', 30)::int) then
      raise exception 'horario_muito_proximo' using errcode = '22023';
    end if;
    -- direto = já reservada para esse motoboy; cascata = aberta para todos reservarem
    v_status := case when v_modo = 'direto' then 'reservada' else 'agendada' end;
  end if;

  insert into public.corridas (
    status, motoboy_id, agendada_para, serie_id, reservada_em,
    urgente, repasse_manual, dev_manual, empresa_id, cliente_nome, aplicar_acrescimo, criada_por, modo_despacho, motoboy_designado_id, teste,
    exige_foto, exige_assinatura, exige_nome, exige_codigo, codigo_entrega,
    exigir_no_local, raio_chegada_m,
    distancia_planejada_m, duracao_planejada_s, rota_planejada, valor, observacoes
  ) values (
    v_status::public.status_corrida,
    case when v_status = 'reservada' then v_moto end,
    v_quando,
    v_serie,
    case when v_status = 'reservada' then now() end,
    coalesce((dados ->> 'urgente')::boolean, false),
    nullif(dados ->> 'repasse_pct', '')::numeric,
    nullif(dados ->> 'dev_pct', '')::numeric,
    nullif(dados ->> 'empresa_id', '')::uuid,
    case when nullif(dados ->> 'empresa_id', '') is null then nullif(left(trim(dados ->> 'cliente_nome'), 80), '') end,
    coalesce((dados ->> 'aplicar_acrescimo')::boolean, true),
    auth.uid(),
    v_modo,
    v_moto,
    v_teste,
    coalesce((dados ->> 'exige_foto')::boolean, privado.cfg_bool('padrao_exige_foto', false)),
    coalesce((dados ->> 'exige_assinatura')::boolean, privado.cfg_bool('padrao_exige_assinatura', false)),
    coalesce((dados ->> 'exige_nome')::boolean, privado.cfg_bool('padrao_exige_nome', true)),
    v_exige_codigo,
    case when v_exige_codigo then lpad((floor(random() * 10000))::int::text, 4, '0') end,
    coalesce((dados ->> 'exigir_no_local')::boolean, privado.cfg_bool('exigir_no_local', true)),
    coalesce((dados ->> 'raio_chegada_m')::int, privado.cfg_num('raio_chegada_m', 150)::int),
    (dados ->> 'distancia_planejada_m')::int,
    (dados ->> 'duracao_planejada_s')::int,
    nullif(dados ->> 'rota_planejada', ''),
    (dados ->> 'valor')::numeric,
    nullif(dados ->> 'observacoes', '')
  ) returning id into v_id;

  insert into public.paradas (corrida_id, ordem, tipo, endereco, lat, lng, contato_nome, contato_telefone, instrucoes, referencias)
  select v_id, (ord - 1)::int, (p ->> 'tipo')::public.tipo_parada, p ->> 'endereco',
         (p ->> 'lat')::double precision, (p ->> 'lng')::double precision,
         nullif(p ->> 'contato_nome', ''), nullif(p ->> 'contato_telefone', ''), nullif(p ->> 'instrucoes', ''),
         privado.limpar_referencias(p -> 'referencias')
    from jsonb_array_elements(dados -> 'paradas') with ordinality as t(p, ord);

  perform privado.evento(v_id, 'criada', jsonb_build_object('modo', v_modo, 'teste', v_teste, 'agendada_para', v_quando));
  if v_quando is null then
    perform privado.despachar(v_id);
  elsif v_status = 'reservada' then
    perform privado.evento(v_id, 'reservada', jsonb_build_object('motoboy_id', v_moto, 'pelo_gestor', true));
    perform privado.enviar_push(v_moto, jsonb_build_object('tipo', 'planejada_reservada', 'corrida_id', v_id::text,
      'agendada_para', to_char(v_quando at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')));
  else
    perform privado.avisar_planejada(v_id, 'planejada_nova', null);
  end if;
  return v_id;
end;
$$;

-- ------------------------------------------------------------- permissões
revoke all on all functions in schema privado from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array[
    'public.definir_minha_chave_pix(text, text, text)', 'public.confirmar_pagamento(uuid, text, text)',
    'public.minha_empresa_info()', 'public.cliente_criar_pedido(jsonb)', 'public.cliente_cancelar_pedido(uuid)',
    'public.meus_pedidos(int)', 'public.acompanhar_pedido(uuid)', 'public.criar_corrida(jsonb)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
