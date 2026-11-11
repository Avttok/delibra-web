-- =====================================================================
-- Delibra · 0033: isolamento entre empresas, registros de exclusão, salário e mais
--                  modalidades de pagamento, empresas no Dev, suspensão e limites
--
--  • Registros de exclusão: "apagar tudo" falhava ("DELETE requires a WHERE clause").
--    Lista e apaga também as contas excluídas; cada registro pertence a uma empresa.
--  • Isolamento: cada empresa só lê o que é dela em registros de exclusão, ajustes de
--    holerite, chaves PIX, dados de recebimento, objetos e favoritos de clientes,
--    exceções (políticas) e horários de pico. Preço usa só as zonas e horários da empresa.
--    Exceções por tipo de pedido passam a ser de cada empresa.
--    Configurações globais: só o Dev altera. Funções que recebiam um id de outra empresa
--    agora recusam (fatura, ajuste de holerite, conquistas, prévia de pagamento, pedido).
--  • Pagamento do motoboy no período: salário fixo mensal, diária, por hora em corrida e
--    mínimo garantido. Combinam com os cálculos por rota (ou substituem).
--  • Empresas no Dev: detalhe completo, periodicidade do plano (mensal, anual, vitalícia),
--    suspender bloqueia a empresa, limites de motoboys e gestores, excluir com senha.
-- =====================================================================

-- ===================================================================== registros de exclusão
alter table public.registro_exclusoes add column if not exists organizacao_id uuid references public.organizacoes (id) on delete cascade;
alter table public.registro_contas_excluidas add column if not exists organizacao_id uuid references public.organizacoes (id) on delete cascade;

update public.registro_exclusoes r set organizacao_id = coalesce(nullif(r.copia #>> '{corrida,organizacao_id}', '')::uuid,
                                                                (select organizacao_id from public.perfis where id = r.excluida_por))
 where r.organizacao_id is null;
update public.registro_contas_excluidas r set organizacao_id = coalesce(nullif(r.copia #>> '{perfil,organizacao_id}', '')::uuid,
                                                                       (select organizacao_id from public.perfis where id = r.excluida_por))
 where r.organizacao_id is null;

create or replace function privado.registro_org()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.organizacao_id is null then
    new.organizacao_id := coalesce(
      case when tg_table_name = 'registro_exclusoes' then nullif(new.copia #>> '{corrida,organizacao_id}', '')::uuid
           else nullif(new.copia #>> '{perfil,organizacao_id}', '')::uuid end,
      public.minha_org());
  end if;
  return new;
end;
$$;
revoke execute on function privado.registro_org() from public, anon, authenticated;
drop trigger if exists registro_org on public.registro_exclusoes;
create trigger registro_org before insert on public.registro_exclusoes for each row execute function privado.registro_org();
drop trigger if exists registro_org on public.registro_contas_excluidas;
create trigger registro_org before insert on public.registro_contas_excluidas for each row execute function privado.registro_org();
create index if not exists registro_exclusoes_org on public.registro_exclusoes (organizacao_id);
create index if not exists registro_contas_excluidas_org on public.registro_contas_excluidas (organizacao_id);

-- ===================================================================== isolamento: políticas restritivas
drop policy if exists org_isolamento on public.registro_exclusoes;
create policy org_isolamento on public.registro_exclusoes as restrictive for all to authenticated
  using (public.ve_org(organizacao_id)) with check (public.ve_org(organizacao_id));
drop policy if exists org_isolamento on public.registro_contas_excluidas;
create policy org_isolamento on public.registro_contas_excluidas as restrictive for all to authenticated
  using (public.ve_org(organizacao_id)) with check (public.ve_org(organizacao_id));

-- ajuste de holerite: só o do holerite que eu vejo (holerites já é isolado)
drop policy if exists org_isolamento on public.holerite_ajustes;
create policy org_isolamento on public.holerite_ajustes as restrictive for all to authenticated
  using (exists (select 1 from public.holerites h where h.id = holerite_id))
  with check (exists (select 1 from public.holerites h where h.id = holerite_id));

-- PIX e dados de recebimento: os meus, ou de quem eu enxergo
drop policy if exists org_isolamento on public.chaves_pix;
create policy org_isolamento on public.chaves_pix as restrictive for all to authenticated
  using (usuario_id = (select auth.uid()) or public.ve_pessoa(usuario_id))
  with check (usuario_id = (select auth.uid()) or public.ve_pessoa(usuario_id));
drop policy if exists org_isolamento on public.dados_recebimento;
create policy org_isolamento on public.dados_recebimento as restrictive for all to authenticated
  using (usuario_id = (select auth.uid()) or public.ve_pessoa(usuario_id))
  with check (usuario_id = (select auth.uid()) or public.ve_pessoa(usuario_id));

-- objetos salvos e favoritos: do cliente que eu sou, ou de um cliente da minha empresa
create or replace function public.ve_cliente(p_empresa uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select auth.uid() is null or p_empresa = privado.minha_empresa()
      or exists (select 1 from public.empresas e where e.id = p_empresa and public.ve_org(e.organizacao_id));
$$;
revoke execute on function public.ve_cliente(uuid) from public, anon;
grant execute on function public.ve_cliente(uuid) to authenticated;
drop policy if exists org_isolamento on public.cliente_objetos;
create policy org_isolamento on public.cliente_objetos as restrictive for all to authenticated
  using (public.ve_cliente(empresa_id)) with check (public.ve_cliente(empresa_id));
drop policy if exists org_isolamento on public.empresa_favoritos;
create policy org_isolamento on public.empresa_favoritos as restrictive for all to authenticated
  using (public.ve_cliente(empresa_id)) with check (public.ve_cliente(empresa_id));

-- configurações globais: todo gestor lê, só o Dev muda (o gestor muda as da empresa dele, em políticas)
drop policy if exists configuracoes_gestor on public.configuracoes;
create policy configuracoes_gestor on public.configuracoes for update to authenticated
  using ((select public.is_dev())) with check ((select public.is_dev()));

-- horários de pico passam a ser de cada empresa (os de hoje ficam com a empresa mais antiga)
alter table public.faixas_horario add column if not exists organizacao_id uuid references public.organizacoes (id) on delete cascade;
update public.faixas_horario set organizacao_id = (select id from public.organizacoes order by criado_em limit 1) where organizacao_id is null;
create index if not exists faixas_horario_org on public.faixas_horario (organizacao_id);
drop trigger if exists org_padrao on public.faixas_horario;
create trigger org_padrao before insert on public.faixas_horario for each row execute function privado.org_padrao();
drop policy if exists org_isolamento on public.faixas_horario;
create policy org_isolamento on public.faixas_horario as restrictive for all to authenticated
  using (public.ve_org_ou_global(organizacao_id)) with check (public.ve_org(organizacao_id));

-- ===================================================================== exceções (políticas) por empresa
-- Tipo de pedido: o alvo vira "<empresa>:<tipo>" (as de antes ficam com a empresa de quem criou).
update public.politicas p set alvo = pf.organizacao_id::text || ':' || p.alvo
  from public.perfis pf
 where p.escopo = 'tipo' and p.alvo !~ ':' and pf.id = p.atualizado_por and pf.organizacao_id is not null
   and not exists (select 1 from public.politicas q where q.escopo = 'tipo' and q.alvo = pf.organizacao_id::text || ':' || p.alvo and q.chave = p.chave);

create or replace function public.ve_politica(p_escopo text, p_alvo text)
returns boolean language sql stable security definer set search_path = '' as $$
  select auth.uid() is null or public.is_dev() and public.minha_org() is null or case p_escopo
    when 'organizacao' then p_alvo = public.minha_org()::text
    when 'motoboy' then p_alvo = auth.uid()::text
                     or (p_alvo ~ '^[0-9a-f-]{36}$' and public.ve_pessoa(p_alvo::uuid) and public.is_gestor())
    when 'cliente' then p_alvo ~ '^[0-9a-f-]{36}$' and public.is_gestor()
                     and exists (select 1 from public.empresas e where e.id = p_alvo::uuid and public.ve_org(e.organizacao_id))
    when 'tipo' then public.is_gestor() and (p_alvo !~ ':' or split_part(p_alvo, ':', 1) = public.minha_org()::text)
    else false end;
$$;
revoke execute on function public.ve_politica(text, text) from public, anon;
grant execute on function public.ve_politica(text, text) to authenticated;
drop policy if exists org_isolamento on public.politicas;
create policy org_isolamento on public.politicas as restrictive for all to authenticated
  using (public.ve_politica(escopo, alvo)) with check (public.ve_politica(escopo, alvo));

-- O que a tela de exceções lê: um alvo (tipo sem o prefixo da empresa) e a contagem por alvo.
create or replace function public.politicas_do_alvo(p_escopo text, p_alvo text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when not public.is_gestor() then '{}'::jsonb else coalesce((
    select jsonb_object_agg(chave, valor) from (
      select distinct on (chave) chave, valor from public.politicas
       where escopo = p_escopo and public.ve_politica(escopo, alvo)
         and (alvo = p_alvo or (p_escopo = 'tipo' and alvo = public.minha_org()::text || ':' || p_alvo))
       order by chave, (alvo = p_alvo)) x), '{}'::jsonb) end;
$$;
create or replace function public.contagem_politicas()
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when not public.is_gestor() then '[]'::jsonb else coalesce((
    select jsonb_agg(jsonb_build_object('escopo', escopo, 'alvo', a, 'n', n)) from (
      select escopo, case when escopo = 'tipo' then regexp_replace(alvo, '^[^:]*:', '') else alvo end a, count(distinct chave) n
        from public.politicas where escopo in ('tipo', 'cliente', 'motoboy') and public.ve_politica(escopo, alvo)
       group by 1, 2) x), '[]'::jsonb) end;
$$;
revoke execute on function public.politicas_do_alvo(text, text), public.contagem_politicas() from public, anon;
grant execute on function public.politicas_do_alvo(text, text), public.contagem_politicas() to authenticated;
create or replace function privado.pol(p_chave text, p_cliente uuid default null, p_motoboy uuid default null, p_tipo text default null)
returns jsonb language sql stable security definer set search_path = '' as $$
  with o as (select x.* from public.organizacoes x where x.id = privado.org_contexto(p_cliente, p_motoboy))
  select coalesce(
    -- a cobrança da plataforma vem do contrato da empresa (licença/isenta = 0%)
    case when p_chave = 'dev_pct' then (select case when o.cobranca_modelo <> 'percentual' then '0'::jsonb end from o) end,
    (nullif(current_setting('pwex.regras', true), '')::jsonb -> p_chave),
    (select valor from public.politicas where p_motoboy is not null and escopo = 'motoboy' and alvo = p_motoboy::text and chave = p_chave),
    (select valor from public.politicas where p_cliente is not null and escopo = 'cliente' and alvo = p_cliente::text and chave = p_chave),
    (select valor from public.politicas where p_tipo is not null and escopo = 'tipo' and chave = p_chave
        and alvo in ((select o.id::text from o) || ':' || p_tipo, p_tipo) order by (alvo = p_tipo) limit 1),
    case when p_chave = 'dev_pct' then (select to_jsonb(o.cobranca_pct) from o) end,
    (select valor from public.politicas where escopo = 'organizacao' and alvo = (select o.id::text from o) and chave = p_chave
        and p_chave !~ '^(app_|dev_|saas_)'),
    (select valor from public.configuracoes where chave = p_chave));
$$;
create or replace function public.definir_politica(p_escopo text, p_alvo text, p_chave text, p_valor jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if p_chave = 'dev_pct' and not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  if p_escopo not in ('tipo', 'cliente', 'motoboy') or coalesce(p_alvo, '') = '' or coalesce(p_chave, '') = '' then
    raise exception 'politica_invalida' using errcode = '22023';
  end if;
  if p_escopo = 'motoboy' and not public.pode_gerenciar(p_alvo::uuid) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if p_escopo = 'cliente' and not exists (select 1 from public.empresas e where e.id::text = p_alvo and public.ve_org(e.organizacao_id)) then
    raise exception 'sem_permissao' using errcode = '42501';
  end if;
  -- tipo de pedido: a exceção é da empresa (o Dev em "Tudo" grava a regra geral)
  if p_escopo = 'tipo' and public.minha_org() is not null then p_alvo := public.minha_org()::text || ':' || regexp_replace(p_alvo, '^[^:]*:', ''); end if;
  if p_valor is null or p_valor = 'null'::jsonb then
    delete from public.politicas where escopo = p_escopo and alvo = p_alvo and chave = p_chave;
  else
    insert into public.politicas (escopo, alvo, chave, valor, atualizado_em, atualizado_por)
    values (p_escopo, p_alvo, p_chave, p_valor, now(), auth.uid())
    on conflict (escopo, alvo, chave) do update set valor = excluded.valor, atualizado_em = now(), atualizado_por = auth.uid();
  end if;
end;
$$;
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
  v_soma   boolean;
  v_pt     jsonb;
  v_col    jsonb;
  v_n      int := 0;
  v_d      numeric;
  v_fr     numeric;
  v_reta   boolean;
  v_org    uuid := privado.org_contexto(nullif(d ->> 'empresa_id', '')::uuid);
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
  v_reta := privado.pol_txt('orcamento_trajeto', 'ruas', v_cli, null, v_tp) = 'reta';
  v_dist := coalesce(case when v_reta then null else nullif(d ->> 'distancia_m', '')::numeric end,
                     privado.distancia_estimada(d -> 'pontos') * privado.pol_num('fator_rua', 1.3, v_cli, null, v_tp));
  v_km := round(v_dist / 1000.0, 2);
  v_soma := privado.pol_txt('preco_distancia_modo', 'soma_entregas', v_cli, null, v_tp) = 'soma_entregas';
  v_fr := privado.pol_num('fator_rua', 1.3, v_cli, null, v_tp);

  -- base e distância (o preço fixo do cadastro antigo do cliente ainda vale)
  if e.id is not null and e.modalidade_preco::text = 'fixo' and e.valor_fixo is not null
     and not exists (select 1 from public.politicas where escopo = 'cliente' and alvo = v_cli::text and chave in ('preco_base', 'preco_km'))
     and not (coalesce(nullif(current_setting('pwex.regras', true), '')::jsonb, '{}') ?| array['preco_base', 'preco_km']) then
    v_fixo_cliente := true;
    v_linhas := v_linhas || jsonb_build_object('rotulo', 'Preço fixo do cliente', 'valor', e.valor_fixo);
    v_sub := v_sub + e.valor_fixo;
  else
    v_val := privado.pol_num('preco_base', 8, v_cli, null, v_tp);
    if v_soma and not privado.pol_bool('soma_inclui_saida', false, v_cli, null, v_tp) then v_val := 0; end if;
    if v_val <> 0 then v_linhas := v_linhas || jsonb_build_object('chave', 'saida', 'rotulo', 'Saída', 'valor', v_val); v_sub := v_sub + v_val; end if;
    v_vkm := privado.pol_num('preco_km', 2.5, v_cli, null, v_tp);
    if e.id is not null and e.modalidade_preco::text = 'por_km' and e.valor_km is not null
       and not exists (select 1 from public.politicas where escopo = 'cliente' and alvo = v_cli::text and chave = 'preco_km')
       and not (coalesce(nullif(current_setting('pwex.regras', true), '')::jsonb, '{}') ? 'preco_km') then
      v_vkm := e.valor_km;
    end if;
    if v_soma then
      -- soma das entregas: cada entrega = valor/km × distância da coleta dela (a coleta anterior na lista; sem ela, a primeira)
      v_dist := 0;
      v_col := (select x from jsonb_array_elements(coalesce(d -> 'pontos', '[]')) x where x ->> 'tipo' = 'coleta' limit 1);
      for v_pt in select * from jsonb_array_elements(coalesce(d -> 'pontos', '[]')) loop
        if v_pt ->> 'tipo' = 'coleta' then v_col := v_pt; continue; end if;
        v_n := v_n + 1;
        v_d := coalesce(case when v_reta then null else nullif(v_pt ->> 'dist_coleta_m', '')::numeric end,
                        privado.dist_m((v_col ->> 'lat')::double precision, (v_col ->> 'lng')::double precision,
                                       (v_pt ->> 'lat')::double precision, (v_pt ->> 'lng')::double precision) * v_fr, 0);
        v_dist := v_dist + v_d;
        v_val := round(round(v_d / 1000.0, 2) * v_vkm, 2);
        v_linhas := v_linhas || jsonb_build_object('chave', 'entrega_' || v_n, 'rotulo', case when v_nent > 1 then 'Entrega ' || v_n else 'Entrega' end,
          'detalhe', format('coleta → entrega: %s km × R$ %s', round(v_d / 1000.0, 2), v_vkm), 'qtd', round(v_d / 1000.0, 2), 'unit', v_vkm, 'unidade', 'km', 'valor', v_val);
        v_sub := v_sub + v_val;
      end loop;
      v_km := round(v_dist / 1000.0, 2);
    else
      v_val := round(v_km * v_vkm, 2);
      v_linhas := v_linhas || jsonb_build_object('chave', 'distancia', 'rotulo', 'Distância', 'detalhe', format('%s km × R$ %s', v_km, v_vkm), 'qtd', v_km, 'unit', v_vkm, 'unidade', 'km', 'valor', v_val);
      v_sub := v_sub + v_val;
    end if;
  end if;

  -- pontos extras
  if v_ncol > 1 then
    v_val := (v_ncol - 1) * privado.pol_num('preco_coleta_extra', 5, v_cli, null, v_tp);
    if v_val <> 0 then v_linhas := v_linhas || jsonb_build_object('rotulo', 'Coletas extras', 'detalhe', format('%s × R$ %s', v_ncol - 1, privado.pol_num('preco_coleta_extra', 5, v_cli, null, v_tp)), 'qtd', v_ncol - 1, 'unit', privado.pol_num('preco_coleta_extra', 5, v_cli, null, v_tp), 'unidade', 'coleta', 'valor', v_val); v_sub := v_sub + v_val; end if;
  end if;
  if v_nent > 1 and (not v_soma or v_fixo_cliente or privado.pol_bool('soma_inclui_entrega_extra', false, v_cli, null, v_tp)) then
    v_val := (v_nent - 1) * privado.pol_num('preco_entrega_extra', 5, v_cli, null, v_tp);
    if v_val <> 0 then v_linhas := v_linhas || jsonb_build_object('rotulo', 'Entregas extras', 'detalhe', format('%s × R$ %s', v_nent - 1, privado.pol_num('preco_entrega_extra', 5, v_cli, null, v_tp)), 'qtd', v_nent - 1, 'unit', privado.pol_num('preco_entrega_extra', 5, v_cli, null, v_tp), 'unidade', 'entrega', 'valor', v_val); v_sub := v_sub + v_val; end if;
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
    if v_val <> 0 then v_linhas := v_linhas || jsonb_build_object('rotulo', 'Volumes extras', 'detalhe', format('%s volume(s) além do incluso', v_x), 'qtd', v_x, 'unit', privado.pol_num('preco_pacote_extra', 1, v_cli, null, v_tp), 'unidade', 'volume', 'valor', v_val); v_sub := v_sub + v_val; end if;
  end if;
  v_tax := round(greatest(v_real, v_cub), 2);
  v_x := greatest(0, v_tax - privado.pol_num('preco_kg_incluso', 5, v_cli, null, v_tp));
  if v_x > 0 then
    v_val := round(v_x * privado.pol_num('preco_kg', 1, v_cli, null, v_tp), 2);
    if v_val <> 0 then
      v_linhas := v_linhas || jsonb_build_object('rotulo', 'Peso excedente',
        'detalhe', format('%s kg taxados (%s)', v_tax, case when v_cub > v_real then 'peso cubado' else 'peso real' end), 'qtd', v_x, 'unit', privado.pol_num('preco_kg', 1, v_cli, null, v_tp), 'unidade', 'kg', 'valor', v_val);
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
    if v_val <> 0 then v_linhas := v_linhas || jsonb_build_object('rotulo', 'Produto perigoso', 'fixo', true, 'valor', v_val); v_fixos := v_fixos + v_val; end if;
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
   where z.ativa and (z.organizacao_id is null or z.organizacao_id = v_org) and (z.cliente_id = v_cli
          or (z.cliente_id is null and not (privado.pol_bool('zona_cliente_exclusiva', false, v_cli, null, v_tp)
                                            and exists (select 1 from public.zonas zz where zz.ativa and zz.cliente_id = v_cli and (zz.organizacao_id is null or zz.organizacao_id = v_org)))))
     and exists (select 1 from jsonb_array_elements(coalesce(d -> 'pontos', '[]')) x
                  where privado.dist_m(z.lat, z.lng, (x ->> 'lat')::double precision, (x ->> 'lng')::double precision) <= z.raio_m);
  if v_za <> 0 then v_linhas := v_linhas || jsonb_build_object('rotulo', 'Zona', 'detalhe', array_to_string(v_znomes, ', '), 'fixo', true, 'valor', v_za); v_fixos := v_fixos + v_za; end if;
  if v_zp <> 0 then v_pcts := v_pcts || jsonb_build_object('rotulo', 'Zona: ' || array_to_string(v_znomes, ', '), 'pct', v_zp); v_pct := v_pct + v_zp; end if;

  -- horário de pico (pelo horário da coleta)
  select f.fator_pct, f.adicional, f.nome into v_hp, v_ha, v_hnome
    from public.faixas_horario f
   where f.ativa and (f.organizacao_id is null or f.organizacao_id = v_org) and (f.cliente_id is null or f.cliente_id = v_cli)
     and extract(dow from v_quando at time zone 'America/Sao_Paulo')::int = any (f.dias)
     and (case when f.fim > f.inicio
               then (v_quando at time zone 'America/Sao_Paulo')::time >= f.inicio and (v_quando at time zone 'America/Sao_Paulo')::time < f.fim
               else (v_quando at time zone 'America/Sao_Paulo')::time >= f.inicio or (v_quando at time zone 'America/Sao_Paulo')::time < f.fim end)
   order by (f.cliente_id is null), f.fator_pct desc, f.adicional desc limit 1;
  if coalesce(v_ha, 0) <> 0 then v_linhas := v_linhas || jsonb_build_object('rotulo', v_hnome, 'fixo', true, 'valor', v_ha); v_fixos := v_fixos + v_ha; end if;
  if coalesce(v_hp, 0) <> 0 then v_pcts := v_pcts || jsonb_build_object('rotulo', v_hnome, 'pct', v_hp); v_pct := v_pct + v_hp; end if;

  v_total := v_sub * (1 + v_pct / 100.0) + v_fixos;
  v_min := privado.pol_num('valor_minimo', 0, v_cli, null, v_tp);
  v_total := privado.arredondar(greatest(v_total, v_min));
  perform set_config('pwex.regras', coalesce(v_guc, ''), true);
  return jsonb_build_object(
    'linhas', v_linhas, 'percentuais', v_pcts, 'subtotal', round(v_sub + v_fixos, 2), 'acrescimo_pct', v_pct,
    'minimo', v_min, 'total', v_total, 'trajeto', case when v_reta then 'reta' else 'ruas' end, 'modo_distancia', case when v_fixo_cliente then 'fixo' when v_soma then 'soma_entregas' else 'rota' end, 'km', v_km, 'distancia_m', round(v_dist),
    'coletas', v_ncol, 'entregas', v_nent, 'volumes', v_pac, 'peso_real_kg', round(v_real, 2), 'peso_cubado_kg', round(v_cub, 2),
    'peso_taxado_kg', v_tax, 'perigoso', v_perig, 'calculado_em', now());
end;
$$;
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
                       from public.tipos_pedido t where t.ativo and (t.organizacao_id is null or t.organizacao_id = privado.org_contexto(v_cli))),
    'categorias', (select coalesce(jsonb_agg(jsonb_build_object('id', k.id, 'nome', k.nome, 'descricao', k.descricao, 'perigoso', k.perigoso,
                                                               'classe_risco', k.classe_risco, 'fragil', k.fragil, 'icone', k.icone,
                                                               'campo_descricao', k.campo_descricao, 'campo_peso', k.campo_peso, 'campo_medidas', k.campo_medidas,
                                                               'campo_valor', k.campo_valor, 'campo_quantidade', k.campo_quantidade) order by k.ordem), '[]')
                     from public.categorias_produto k where k.ativa and (k.organizacao_id is null or k.organizacao_id = privado.org_contexto(v_cli))),
    'icone', e.icone, 'teste', privado.cliente_teste(), 've_preco_na_hora', privado.cliente_ve_preco(v_cli),
    'pode_modelos', privado.pol_bool('cliente_pode_modelos', true, v_cli), 'pode_cancelar', privado.pol_bool('cliente_pode_cancelar', true, v_cli),
    'troca_senha', privado.pol_bool('cliente_troca_senha', true, v_cli),
    'confirmacoes', jsonb_build_object('foto', privado.pol_bool('cliente_confirma_foto', true, v_cli), 'nome', privado.pol_bool('cliente_confirma_nome', true, v_cli),
                                       'assinatura', privado.pol_bool('cliente_confirma_assinatura', true, v_cli), 'codigo', privado.pol_bool('cliente_confirma_codigo', true, v_cli)),
    'padrao_confirmacoes', jsonb_build_object('foto', privado.cfg_bool('padrao_exige_foto', false), 'nome', privado.cfg_bool('padrao_exige_nome', true),
                                              'assinatura', privado.cfg_bool('padrao_exige_assinatura', false), 'codigo', privado.cfg_bool('padrao_exige_codigo', false)),
    'pode_janela', privado.pol_bool('cliente_pode_janela', true, v_cli), 'pode_objetos', privado.pol_bool('cliente_pode_objetos', true, v_cli),
    'modelo_horario', privado.pol_bool('cliente_modelo_horario', true, v_cli),
    'pode_agendar', privado.pol_bool('cliente_pode_agendar', true, v_cli), 'pode_urgente', privado.pol_bool('cliente_pode_urgente', true, v_cli),
    'max_entregas', privado.pol_num('cliente_max_entregas', 0, v_cli), 'max_coletas', privado.pol_num('cliente_max_coletas', 0, v_cli),
    'agendar_max_dias', privado.pol_num('cliente_agendar_max_dias', 60, v_cli), 'pode_ida_volta', privado.pol_bool('cliente_pode_ida_volta', true, v_cli),
    'coleta_fixa', privado.pol_bool('cliente_coleta_fixa', false, v_cli), 'pode_observacoes', privado.pol_bool('cliente_pode_observacoes', true, v_cli),
    've_faturas', privado.pol_bool('cliente_ve_faturas', true, v_cli), 'pode_chat', privado.pol_bool('cliente_pode_chat', true, v_cli),
    've_rota', coalesce(privado.pol('cliente_ve_rota', v_cli), '["feito", "motoboy"]'::jsonb),
    'pedido_de', privado.pol_txt('cliente_pedido_de', '', v_cli), 'pedido_ate', privado.pol_txt('cliente_pedido_ate', '', v_cli),
    'modo_distancia', privado.pol_txt('preco_distancia_modo', 'soma_entregas', v_cli), 'categoria_obrigatoria', privado.cfg_bool('item_categoria_obrigatoria', false),
    'em_aberto', (select coalesce(sum(valor), 0) from public.pedidos where empresa_id = v_cli and teste = privado.cliente_teste() and cobranca = 'credito' and fatura_id is null and status = 'concluido'));
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

-- Guardas: a função de antes vira privada e a pública confere a empresa antes de chamar.
do $$
begin
  if to_regprocedure('privado.gerar_fatura_sem_guarda(uuid, date, date, boolean)') is null then
    alter function public.gerar_fatura(uuid, date, date, boolean) set schema privado;
    alter function privado.gerar_fatura(uuid, date, date, boolean) rename to gerar_fatura_sem_guarda;
  end if;
  if to_regprocedure('privado.remover_ajuste_holerite_sem_guarda(uuid)') is null then
    alter function public.remover_ajuste_holerite(uuid) set schema privado;
    alter function privado.remover_ajuste_holerite(uuid) rename to remover_ajuste_holerite_sem_guarda;
  end if;
  if to_regprocedure('privado.conquistas_sem_guarda(uuid)') is null then
    alter function public.conquistas(uuid) set schema privado;
    alter function privado.conquistas(uuid) rename to conquistas_sem_guarda;
  end if;
  if to_regprocedure('privado.previa_pagamento_rota_sem_guarda(uuid, jsonb, uuid)') is null then
    alter function public.previa_pagamento_rota(uuid, jsonb, uuid) set schema privado;
    alter function privado.previa_pagamento_rota(uuid, jsonb, uuid) rename to previa_pagamento_rota_sem_guarda;
  end if;
end $$;
revoke execute on function privado.gerar_fatura_sem_guarda(uuid, date, date, boolean), privado.remover_ajuste_holerite_sem_guarda(uuid),
  privado.conquistas_sem_guarda(uuid), privado.previa_pagamento_rota_sem_guarda(uuid, jsonb, uuid) from public, anon, authenticated;

create or replace function public.gerar_fatura(p_cliente uuid, p_inicio date, p_fim date, p_teste boolean default false)
returns uuid language plpgsql security definer set search_path = '' as $$
begin
  if p_cliente is not null and not exists (select 1 from public.empresas e where e.id = p_cliente and public.ve_org(e.organizacao_id)) then
    raise exception 'sem_permissao' using errcode = '42501';
  end if;
  return privado.gerar_fatura_sem_guarda(p_cliente, p_inicio, p_fim, p_teste);
end;
$$;
create or replace function public.remover_ajuste_holerite(p_ajuste uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.holerite_ajustes a join public.holerites h on h.id = a.holerite_id
                  where a.id = p_ajuste and public.ve_org(h.organizacao_id)) then
    raise exception 'sem_permissao' using errcode = '42501';
  end if;
  perform privado.remover_ajuste_holerite_sem_guarda(p_ajuste);
end;
$$;
create or replace function public.conquistas(p_motoboy uuid default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if p_motoboy is not null and p_motoboy <> auth.uid() and not public.ve_pessoa(p_motoboy) then
    raise exception 'sem_permissao' using errcode = '42501';
  end if;
  return privado.conquistas_sem_guarda(p_motoboy);
end;
$$;
create or replace function public.previa_pagamento_rota(p_corrida uuid, p_regras jsonb default null, p_motoboy uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.corridas c where c.id = p_corrida and public.ve_org(c.organizacao_id))
     or (p_motoboy is not null and not public.ve_pessoa(p_motoboy)) then
    raise exception 'sem_permissao' using errcode = '42501';
  end if;
  return privado.previa_pagamento_rota_sem_guarda(p_corrida, p_regras, p_motoboy);
end;
$$;
revoke execute on function public.gerar_fatura(uuid, date, date, boolean), public.remover_ajuste_holerite(uuid),
  public.conquistas(uuid), public.previa_pagamento_rota(uuid, jsonb, uuid) from public, anon;
grant execute on function public.gerar_fatura(uuid, date, date, boolean), public.remover_ajuste_holerite(uuid),
  public.conquistas(uuid), public.previa_pagamento_rota(uuid, jsonb, uuid) to authenticated;

-- ===================================================================== empresa suspensa / limites do plano
-- Empresa suspensa ou cancelada: gestores e motoboys dela ficam sem acesso (o Dev continua).
create or replace function privado.org_bloqueada()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.perfis p join public.organizacoes o on o.id = p.organizacao_id
                  where p.id = auth.uid() and not ('dev' = any (p.papeis)) and o.status in ('suspensa', 'cancelada'));
$$;
revoke execute on function privado.org_bloqueada() from public, anon;
grant execute on function privado.org_bloqueada() to authenticated;

create or replace function public.is_gestor()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.perfis where id = auth.uid() and papeis && array['gestor', 'dev', 'supervisor']::public.papel_usuario[])
     and not privado.org_bloqueada();
$$;
create or replace function public.is_gestor_pleno()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.perfis where id = auth.uid() and papeis && array['gestor', 'dev']::public.papel_usuario[])
     and not privado.org_bloqueada();
$$;
create or replace function public.tem_papel(p public.papel_usuario)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.perfis where id = auth.uid() and p = any (papeis))
     and (p = 'dev' or not privado.org_bloqueada());
$$;

-- Limites do plano (Dev → Empresas): {"motoboys": N, "gestores": N, "clientes": N}. Vazio = sem limite.
create or replace function privado.conferir_limites()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_org uuid; v_lim int; v_n int;
begin
  v_org := new.organizacao_id;
  if v_org is null or 'dev' = any (new.papeis) then return new; end if;
  if tg_op = 'UPDATE' and old.organizacao_id is not distinct from new.organizacao_id and old.papeis = new.papeis then return new; end if;
  if 'motoboy' = any (new.papeis) and (tg_op = 'INSERT' or not ('motoboy' = any (old.papeis)) or old.organizacao_id is distinct from v_org) then
    v_lim := nullif((select limites ->> 'motoboys' from public.organizacoes where id = v_org), '')::int;
    if v_lim is not null and v_lim > 0 then
      select count(*) into v_n from public.perfis where organizacao_id = v_org and 'motoboy' = any (papeis) and id <> new.id;
      if v_n >= v_lim then raise exception 'limite_motoboys_do_plano' using errcode = '22023', detail = v_lim::text; end if;
    end if;
  end if;
  if new.papeis && array['gestor', 'supervisor']::public.papel_usuario[]
     and (tg_op = 'INSERT' or not (old.papeis && array['gestor', 'supervisor']::public.papel_usuario[]) or old.organizacao_id is distinct from v_org) then
    v_lim := nullif((select limites ->> 'gestores' from public.organizacoes where id = v_org), '')::int;
    if v_lim is not null and v_lim > 0 then
      select count(*) into v_n from public.perfis where organizacao_id = v_org and papeis && array['gestor', 'supervisor']::public.papel_usuario[] and id <> new.id;
      if v_n >= v_lim then raise exception 'limite_gestores_do_plano' using errcode = '22023', detail = v_lim::text; end if;
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function privado.conferir_limites() from public, anon, authenticated;
drop trigger if exists conferir_limites on public.perfis;
drop trigger if exists zz_conferir_limites on public.perfis;
-- "zz_": roda depois do perfil_org_padrao (que preenche a empresa)
create trigger zz_conferir_limites before insert or update of papeis, organizacao_id on public.perfis for each row execute function privado.conferir_limites();

create or replace function privado.conferir_limite_clientes()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_lim int;
begin
  if new.organizacao_id is null then return new; end if;
  v_lim := nullif((select limites ->> 'clientes' from public.organizacoes where id = new.organizacao_id), '')::int;
  if v_lim is not null and v_lim > 0 and (select count(*) from public.empresas where organizacao_id = new.organizacao_id) > v_lim then
    raise exception 'limite_clientes_do_plano' using errcode = '22023', detail = v_lim::text;
  end if;
  return new;
end;
$$;
revoke execute on function privado.conferir_limite_clientes() from public, anon, authenticated;
drop trigger if exists conferir_limite_clientes on public.empresas;
-- confere depois de gravar (o org_padrao já preencheu a empresa); conta a nova junto
create constraint trigger conferir_limite_clientes after insert on public.empresas deferrable initially immediate
  for each row execute function privado.conferir_limite_clientes();
create or replace function public.dev_listar(p_categoria text, p_busca text default null, p_limite int default 100)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_b text := '%' || lower(coalesce(trim(p_busca), '')) || '%'; v_l int := least(greatest(coalesce(p_limite, 100), 1), 500);
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  return coalesce(case p_categoria
    when 'pedidos' then (select jsonb_agg(x) from (select jsonb_build_object('id', p.id, 'titulo', (case when p.teste then 'T' else '#' end) || p.numero || ' · ' || coalesce(e.nome, p.cliente_nome, 'avulso'),
        'sub', p.status || ' · R$ ' || coalesce(p.valor, 0), 'quando', p.criado_em) x from public.pedidos p left join public.empresas e on e.id = p.empresa_id
        where lower(p.numero::text || ' ' || coalesce(e.nome, p.cliente_nome, '') || ' ' || p.status) like v_b order by p.criado_em desc limit v_l) t)
    when 'corridas' then (select jsonb_agg(x) from (select jsonb_build_object('id', c.id, 'titulo', (case when c.teste then 'T' else '#' end) || c.numero || ' · ' || coalesce(pf.nome, 'sem motoboy'),
        'sub', c.status::text || ' · R$ ' || coalesce(c.valor, 0), 'quando', c.criada_em) x from public.corridas c left join public.perfis pf on pf.id = c.motoboy_id
        where lower(c.numero::text || ' ' || coalesce(pf.nome, '') || ' ' || c.status::text) like v_b order by c.criada_em desc limit v_l) t)
    when 'percursos' then (select jsonb_agg(x) from (select jsonb_build_object('id', pf.id, 'titulo', pf.nome, 'sub', count(*) || ' pings', 'quando', max(l.registrado_em)) x
        from public.localizacoes l join public.perfis pf on pf.id = l.motoboy_id where lower(pf.nome) like v_b group by pf.id order by max(l.registrado_em) desc limit v_l) t)
    when 'ofertas' then (select jsonb_agg(x) from (select jsonb_build_object('id', o.id, 'titulo', coalesce(pf.nome, 'motoboy') || ' · rota ' || c.numero, 'sub', o.status::text, 'quando', o.criada_em) x
        from public.ofertas o join public.corridas c on c.id = o.corrida_id left join public.perfis pf on pf.id = o.motoboy_id
        where lower(coalesce(pf.nome, '') || ' ' || c.numero || ' ' || o.status::text) like v_b order by o.criada_em desc limit v_l) t)
    when 'faturas' then (select jsonb_agg(x) from (select jsonb_build_object('id', f.id, 'titulo', 'Fatura ' || f.numero || ' · ' || coalesce(e.nome, ''), 'sub', f.status || ' · R$ ' || coalesce(f.total, 0), 'quando', f.fim) x
        from public.faturas f left join public.empresas e on e.id = f.empresa_id where lower(f.numero::text || ' ' || coalesce(e.nome, '') || ' ' || f.status) like v_b order by f.fim desc limit v_l) t)
    when 'holerites' then (select jsonb_agg(x) from (select jsonb_build_object('id', h.id, 'titulo', coalesce(pf.nome, 'motoboy'), 'sub', h.status || ' · ' || h.inicio || ' a ' || h.fim, 'quando', h.fim) x
        from public.holerites h left join public.perfis pf on pf.id = h.motoboy_id where lower(coalesce(pf.nome, '') || ' ' || h.status) like v_b order by h.fim desc limit v_l) t)
    when 'chat' then (select jsonb_agg(x) from (select jsonb_build_object('id', c.id, 'titulo', coalesce(c.nome, (select string_agg(split_part(p.nome, ' ', 1), ' e ') from public.chat_membros m join public.perfis p on p.id = m.usuario_id where m.conversa_id = c.id), 'Conversa'),
        'sub', c.tipo || ' · ' || (select count(*) from public.chat_mensagens g where g.conversa_id = c.id) || ' mensagens', 'quando', c.ultima_em) x
        from public.chat_conversas c order by c.ultima_em desc limit v_l) t)
    when 'modelos' then (select jsonb_agg(x) from (
        select jsonb_build_object('id', m.id, 'titulo', 'Modelo: ' || m.nome, 'sub', e.nome, 'quando', m.criado_em) x from public.pedido_modelos m join public.empresas e on e.id = m.empresa_id where lower(m.nome || ' ' || e.nome) like v_b
        union all select jsonb_build_object('id', o.id, 'titulo', 'Objeto: ' || o.nome, 'sub', e.nome, 'quando', o.criado_em) from public.cliente_objetos o join public.empresas e on e.id = o.empresa_id where lower(o.nome || ' ' || e.nome) like v_b
        limit v_l) t)
    when 'clientes' then (select jsonb_agg(x) from (select jsonb_build_object('id', e.id, 'titulo', e.nome, 'sub', coalesce(e.cnpj, e.cpf, '') || ' · ' || (select count(*) from public.pedidos p where p.empresa_id = e.id) || ' pedidos', 'quando', e.criado_em) x
        from public.empresas e where lower(e.nome || ' ' || coalesce(e.cnpj, e.cpf, '')) like v_b order by e.nome limit v_l) t)
    when 'cadastros' then (select jsonb_agg(x) from (select jsonb_build_object('id', k.id, 'titulo', k.nome, 'sub', k.status, 'quando', k.criado_em) x from public.cadastros_cliente k where lower(k.nome) like v_b order by k.criado_em desc limit v_l) t)
    when 'excecoes' then (select jsonb_agg(x) from (select jsonb_build_object('id', md5(o.escopo || o.alvo || o.chave), 'titulo', o.chave, 'sub', o.escopo || ' · ' || coalesce(
          (select e.nome from public.empresas e where o.escopo = 'cliente' and e.id::text = o.alvo), (select p.nome from public.perfis p where o.escopo = 'motoboy' and p.id::text = o.alvo), o.alvo) || ' = ' || (o.valor #>> '{}'), 'quando', o.atualizado_em) x
        from public.politicas o where lower(o.chave || ' ' || o.escopo) like v_b order by o.atualizado_em desc limit v_l) t)
    when 'zonas' then (select jsonb_agg(x) from (select jsonb_build_object('id', z.id, 'titulo', z.nome, 'sub', z.raio_m || ' m') x from public.zonas z where lower(z.nome) like v_b limit v_l) t)
    when 'horarios' then (select jsonb_agg(x) from (select jsonb_build_object('id', f.id, 'titulo', f.nome, 'sub', f.inicio || '–' || f.fim) x from public.faixas_horario f where lower(f.nome) like v_b limit v_l) t)
    when 'registros' then (select jsonb_agg(x order by x ->> 'quando' desc) from (
        (select jsonb_build_object('id', 'c:' || r.id, 'titulo', 'Corrida ' || case when r.teste then 'T' else '#' end || coalesce(r.numero::text, ''), 'sub', coalesce(r.motivo, 'sem motivo') || coalesce(' · R$ ' || r.valor, ''), 'quando', r.excluida_em) x
           from public.registro_exclusoes r where lower('corrida ' || coalesce(r.numero::text, '') || ' ' || coalesce(r.motivo, '')) like v_b order by r.excluida_em desc limit v_l)
        union all
        (select jsonb_build_object('id', 'u:' || r.id, 'titulo', 'Conta ' || coalesce(r.nome, r.email, ''), 'sub', coalesce(array_to_string(r.papeis, ', '), '') || coalesce(' · ' || r.motivo, ''), 'quando', r.excluida_em)
           from public.registro_contas_excluidas r where lower('conta ' || coalesce(r.nome, '') || ' ' || coalesce(r.email, '') || ' ' || coalesce(r.motivo, '')) like v_b order by r.excluida_em desc limit v_l)) t)
    when 'conquistas' then (select jsonb_agg(x) from (select jsonb_build_object('id', md5(k.perfil_id::text || k.chave), 'titulo', k.chave, 'sub', coalesce(pf.nome, '')) x from public.conquistas_manuais k left join public.perfis pf on pf.id = k.perfil_id limit v_l) t)
    when 'pix' then (select jsonb_agg(x) from (select jsonb_build_object('id', k.id, 'titulo', coalesce(pf.nome, ''), 'sub', k.tipo_chave || ' · ' || k.chave, 'quando', k.criado_em) x from public.chaves_pix k left join public.perfis pf on pf.id = k.usuario_id where lower(coalesce(pf.nome, '') || k.chave) like v_b limit v_l) t)
    when 'configuracoes' then (select jsonb_agg(x) from (select jsonb_build_object('id', md5(c.chave), 'titulo', c.chave, 'sub', c.valor #>> '{}') x from public.configuracoes c where lower(c.chave) like v_b order by c.chave limit v_l) t)
  end, '[]'::jsonb);
end;
$$;
create or replace function public.dev_apagar_interno(p_categoria text, p_ids text[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_n    bigint := 0;
  v_k    bigint;
  v_tudo boolean := p_ids is null;
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  if p_categoria = 'pedidos' then
    delete from public.paradas where pedido_id in (select id from public.pedidos where v_tudo or id::text = any (p_ids));
    delete from public.pedidos where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count;
    -- rotas que ficaram vazias
    delete from public.corridas c where c.origem = 'roteirizador' and not exists (select 1 from public.paradas x where x.corrida_id = c.id);
  elsif p_categoria = 'corridas' then
    delete from public.localizacoes where corrida_id in (select id from public.corridas where v_tudo or id::text = any (p_ids));
    update public.motoboys set status = 'disponivel', status_em = now()
     where status = 'em_corrida' and id in (select motoboy_id from public.corridas where (v_tudo or id::text = any (p_ids)) and status::text in ('aceita', 'em_andamento'));
    delete from public.corridas where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count;
    update public.pedidos p set status = 'aprovado' where p.status in ('roteirizado', 'em_rota') and not exists (select 1 from public.paradas x where x.pedido_id = p.id);
    update public.pedido_pontos pp set status = 'pendente' where pp.status = 'em_rota' and not exists (select 1 from public.paradas x where x.pedido_ponto_id = pp.id);
  elsif p_categoria = 'percursos' then
    delete from public.localizacoes where v_tudo or motoboy_id::text = any (p_ids); get diagnostics v_n = row_count;
    delete from public.trechos_ajustados where v_tudo or motoboy_id::text = any (p_ids);
  elsif p_categoria = 'ofertas' then
    delete from public.ofertas where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count;
  elsif p_categoria = 'faturas' then
    update public.pedidos set fatura_id = null where fatura_id in (select id from public.faturas where v_tudo or id::text = any (p_ids));
    delete from public.faturas where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count;
  elsif p_categoria = 'holerites' then
    delete from public.holerite_ajustes where v_tudo or holerite_id::text = any (p_ids); get diagnostics v_k = row_count;
    delete from public.holerites where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count; v_n := v_n + v_k;
  elsif p_categoria = 'chat' then
    select count(*) into v_n from public.chat_mensagens where v_tudo or conversa_id::text = any (p_ids);
    delete from public.chat_conversas where v_tudo or id::text = any (p_ids);
    insert into public.chat_conversas (tipo, nome) select 'geral', 'Equipe' where not exists (select 1 from public.chat_conversas where tipo = 'geral');
  elsif p_categoria = 'modelos' then
    delete from public.pedido_modelos where v_tudo or id::text = any (p_ids); get diagnostics v_k = row_count;
    delete from public.cliente_objetos where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count; v_n := v_n + v_k;
  elsif p_categoria = 'clientes' then
    delete from public.paradas where pedido_id in (select id from public.pedidos where empresa_id in (select id from public.empresas where v_tudo or id::text = any (p_ids)));
    delete from public.pedidos where empresa_id in (select id from public.empresas where v_tudo or id::text = any (p_ids));
    delete from public.faturas where empresa_id in (select id from public.empresas where v_tudo or id::text = any (p_ids));
    update public.corridas set empresa_id = null where empresa_id in (select id from public.empresas where v_tudo or id::text = any (p_ids));
    update public.perfis set empresa_id = null where empresa_id in (select id from public.empresas where v_tudo or id::text = any (p_ids));
    delete from public.politicas where escopo = 'cliente' and (v_tudo or alvo = any (p_ids));
    delete from public.empresas where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count;
  elsif p_categoria = 'cadastros' then
    delete from public.cadastros_cliente where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count;
  elsif p_categoria = 'excecoes' then
    delete from public.politicas where v_tudo or md5(escopo || alvo || chave) = any (p_ids); get diagnostics v_n = row_count;
  elsif p_categoria = 'zonas' then
    delete from public.zonas where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count;
  elsif p_categoria = 'horarios' then
    delete from public.faixas_horario where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count;
  elsif p_categoria = 'registros' then
    -- ids "c:N" (corrida apagada) e "u:N" (conta excluída); sem filtro = tudo (com WHERE: o Supabase recusa DELETE sem WHERE)
    delete from public.registro_exclusoes where v_tudo or 'c:' || id = any (p_ids) or id::text = any (p_ids); get diagnostics v_n = row_count;
    delete from public.registro_contas_excluidas where v_tudo or 'u:' || id = any (p_ids); get diagnostics v_k = row_count; v_n := v_n + v_k;
  elsif p_categoria = 'conquistas' then
    delete from public.conquistas_manuais where v_tudo or md5(perfil_id::text || chave) = any (p_ids); get diagnostics v_n = row_count;
  elsif p_categoria = 'pix' then
    delete from public.chaves_pix where v_tudo or id::text = any (p_ids); get diagnostics v_n = row_count;
  elsif p_categoria = 'configuracoes' then
    -- apagar = voltar ao padrão (cada regra tem o padrão dela no sistema)
    delete from public.configuracoes where (v_tudo or md5(chave) = any (p_ids)) and chave not in ('versao_minima_app', 'versao_obrigatoria');
    get diagnostics v_n = row_count;
  else
    raise exception 'categoria_invalida' using errcode = '22023';
  end if;
  return jsonb_build_object('apagados', v_n);
end;
$$;

-- ===================================================================== pagamento do período (holerite)
-- Modalidades que valem para o período inteiro, além (ou no lugar) do cálculo por rota:
--   salario  → salário fixo mensal (proporcional aos dias do período, ou cheio)
--   diaria   → valor por dia em que fez pelo menos uma rota
--   por_hora → valor por hora em corrida (do aceite à conclusão)
--   pag_minimo_periodo → mínimo garantido no período (completa a diferença)
create or replace function privado.pag_periodo(p_motoboy uuid, p_inicio date, p_fim date, p_teste boolean, p_rotas numeric default 0)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_lista jsonb := privado.pol('pag_modos', null, p_motoboy, null);
  v_modos text[];
  v_itens jsonb := '[]';
  v_total numeric := 0;
  v_val   numeric; v_q numeric; v_x numeric; v_min numeric;
begin
  if p_motoboy is null or p_inicio is null or p_fim is null then return jsonb_build_object('itens', '[]'::jsonb, 'total', 0); end if;
  select coalesce(array_agg(x), '{}') into v_modos from jsonb_array_elements_text(case when jsonb_typeof(v_lista) = 'array' then v_lista else '[]' end) x;
  if cardinality(v_modos) = 0 then v_modos := array[privado.pol_txt('pag_modo', 'zonas', null, p_motoboy, null)]; end if;

  if 'salario' = any (v_modos) then
    v_val := privado.pol_num('pag_salario_mensal', 0, null, p_motoboy, null);
    if v_val > 0 then
      if privado.pol_bool('pag_salario_proporcional', true, null, p_motoboy, null) then
        -- soma, mês a mês, a fração do mês que cai no período
        select coalesce(sum((least(p_fim, (m + interval '1 month - 1 day')::date) - greatest(p_inicio, m::date) + 1)::numeric
                            / extract(day from (m + interval '1 month - 1 day'))::numeric), 0)
          into v_q from generate_series(date_trunc('month', p_inicio), date_trunc('month', p_fim), interval '1 month') m;
      else
        v_q := 1;
      end if;
      v_x := round(v_val * v_q, 2);
      v_itens := v_itens || jsonb_build_object('tipo', 'salario', 'descricao', 'Salário fixo',
        'detalhe', case when v_q = 1 then 'mês cheio' else round(v_q * 100) || '% do mês' end, 'base', v_val, 'quantidade', round(v_q, 4), 'valor', v_x);
      v_total := v_total + v_x;
    end if;
  end if;

  if 'diaria' = any (v_modos) then
    v_val := privado.pol_num('pag_diaria_valor', 0, null, p_motoboy, null);
    if v_val > 0 then
      select count(distinct privado.dia_local(c.concluida_em)) into v_q from public.corridas c
       where c.motoboy_id = p_motoboy and c.status = 'concluida' and c.teste = p_teste and privado.dia_local(c.concluida_em) between p_inicio and p_fim;
      v_x := round(v_val * v_q, 2);
      v_itens := v_itens || jsonb_build_object('tipo', 'diaria', 'descricao', 'Diárias', 'detalhe', v_q || ' dia' || case when v_q = 1 then '' else 's' end || ' com rota',
        'base', v_val, 'quantidade', v_q, 'valor', v_x);
      v_total := v_total + v_x;
    end if;
  end if;

  if 'por_hora' = any (v_modos) then
    v_val := privado.pol_num('pag_hora_valor', 0, null, p_motoboy, null);
    if v_val > 0 then
      select coalesce(round(sum(extract(epoch from (c.concluida_em - coalesce(c.aceita_em, c.iniciada_em, c.concluida_em)))) / 3600.0, 2), 0) into v_q
        from public.corridas c
       where c.motoboy_id = p_motoboy and c.status = 'concluida' and c.teste = p_teste and privado.dia_local(c.concluida_em) between p_inicio and p_fim;
      v_x := round(v_val * v_q, 2);
      v_itens := v_itens || jsonb_build_object('tipo', 'por_hora', 'descricao', 'Horas em corrida', 'detalhe', replace(v_q::text, '.', ',') || ' h',
        'base', v_val, 'quantidade', v_q, 'valor', v_x);
      v_total := v_total + v_x;
    end if;
  end if;

  v_min := privado.pol_num('pag_minimo_periodo', 0, null, p_motoboy, null);
  if v_min > 0 and coalesce(p_rotas, 0) + v_total < v_min then
    v_x := round(v_min - coalesce(p_rotas, 0) - v_total, 2);
    v_itens := v_itens || jsonb_build_object('tipo', 'minimo', 'descricao', 'Complemento do mínimo', 'detalhe', 'mínimo de R$ ' || v_min || ' no período',
      'base', v_min, 'valor', v_x);
    v_total := v_total + v_x;
  end if;
  return jsonb_build_object('itens', v_itens, 'total', v_total);
end;
$$;
revoke execute on function privado.pag_periodo(uuid, date, date, boolean, numeric) from public, anon, authenticated;
create or replace function privado.holerite_json(p_motoboy uuid, p_inicio date, p_fim date, p_teste boolean, p_valores boolean)
returns jsonb language sql stable security definer set search_path = '' as $$
  with rotas as (
    select c.id, c.numero, c.concluida_em, c.valor, c.valor_motoboy, c.pag_calculo, c.pag_ajuste, c.pag_ajuste_motivo,
           coalesce(c.distancia_real_m, c.distancia_planejada_m, 0) metros,
           (select count(*) from public.paradas x where x.corrida_id = c.id and x.tipo = 'entrega') entregas,
           (select coalesce(string_agg(distinct coalesce(e.nome, pd.cliente_nome), ', '), coalesce(e2.nome, c.cliente_nome))
              from public.paradas x left join public.pedidos pd on pd.id = x.pedido_id left join public.empresas e on e.id = pd.empresa_id
             where x.corrida_id = c.id) clientes
      from public.corridas c left join public.empresas e2 on e2.id = c.empresa_id
     where c.motoboy_id = p_motoboy and c.status = 'concluida' and c.teste = p_teste
       and privado.dia_local(c.concluida_em) between p_inicio and p_fim
  ), h as (
    select * from public.holerites where motoboy_id = p_motoboy and teste = p_teste and inicio = p_inicio and fim = p_fim
  ), fx as (
    -- salário, diárias, horas e mínimo do período
    select privado.pag_periodo(p_motoboy, p_inicio, p_fim, p_teste, (select coalesce(sum(valor_motoboy), 0) from rotas)) j
  )
  select jsonb_build_object(
    'motoboy_id', p_motoboy, 'inicio', p_inicio, 'fim', p_fim, 'teste', p_teste,
    'status', coalesce((select status from h), 'aberto'),
    'fechado_em', (select fechado_em from h), 'pago_em', (select pago_em from h), 'observacoes', (select observacoes from h),
    'rotas', (select count(*) from rotas), 'entregas', (select coalesce(sum(entregas), 0) from rotas),
    'km', (select round(coalesce(sum(metros), 0) / 1000.0, 1) from rotas),
    'valores_visiveis', p_valores,
    'calculado', case when p_valores then (select coalesce(sum((pag_calculo ->> 'total')::numeric), 0) from rotas) + (select (j ->> 'total')::numeric from fx) end,
    'fixos', case when p_valores then (select j -> 'itens' from fx) else (select coalesce(jsonb_agg(i - 'valor' - 'base'), '[]') from fx, jsonb_array_elements(fx.j -> 'itens') i) end,
    'fixos_total', case when p_valores then (select (j ->> 'total')::numeric from fx) end,
    'ajustes_rotas', case when p_valores then (select coalesce(sum(pag_ajuste), 0) from rotas) end,
    'ajustes', case when p_valores then coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'descricao', a.descricao, 'valor', a.valor, 'criado_em', a.criado_em) order by a.criado_em)
                                                   from public.holerite_ajustes a where a.holerite_id = (select id from h)), '[]') end,
    'total', case when p_valores then
      (select coalesce(sum(valor_motoboy), 0) from rotas) + (select (j ->> 'total')::numeric from fx)
      + coalesce((select sum(a.valor) from public.holerite_ajustes a where a.holerite_id = (select id from h)), 0) end,
    'itens', coalesce((select jsonb_agg(jsonb_build_object(
        'id', r.id, 'numero', r.numero, 'concluida_em', r.concluida_em, 'entregas', r.entregas, 'km', round(r.metros / 1000.0, 1),
        'clientes', r.clientes,
        'calculo', case when p_valores then r.pag_calculo end, 'ajuste', case when p_valores then r.pag_ajuste end,
        'ajuste_motivo', case when p_valores then r.pag_ajuste_motivo end, 'valor', case when p_valores then r.valor_motoboy end,
        'faturado', case when public.is_gestor() then r.valor end) order by r.concluida_em) from rotas r), '[]'));
$$;
create or replace function public.folha(p_inicio date, p_fim date, p_teste boolean default false)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(x order by x ->> 'nome') from (
      select jsonb_build_object(
        'motoboy_id', pf.id, 'nome', pf.nome, 'foto_url', pf.foto_url,
        'rotas', count(c.id), 'entregas', coalesce(sum((c.pag_calculo ->> 'entregas')::int), 0),
        'km', round(coalesce(sum(coalesce(c.distancia_real_m, c.distancia_planejada_m, 0)), 0) / 1000.0, 1),
        'calculado', coalesce(sum((c.pag_calculo ->> 'total')::numeric), 0)
                     + (privado.pag_periodo(pf.id, p_inicio, p_fim, p_teste, coalesce(sum(c.valor_motoboy), 0)) ->> 'total')::numeric,
        'fixos', privado.pag_periodo(pf.id, p_inicio, p_fim, p_teste, coalesce(sum(c.valor_motoboy), 0)),
        'ajustes_rotas', coalesce(sum(c.pag_ajuste), 0),
        'ajustes', coalesce((select sum(a.valor) from public.holerites h join public.holerite_ajustes a on a.holerite_id = h.id
                              where h.motoboy_id = pf.id and h.teste = p_teste and h.inicio = p_inicio and h.fim = p_fim), 0),
        'faturado', coalesce(sum(c.valor), 0),
        'holerite', (select to_jsonb(h) from public.holerites h where h.motoboy_id = pf.id and h.teste = p_teste and h.inicio = p_inicio and h.fim = p_fim),
        'chave_pix', (select jsonb_build_object('tipo', k.tipo_chave, 'chave', k.chave, 'titular', k.titular) from public.chaves_pix k where k.usuario_id = pf.id and k.principal limit 1)
      ) x
      from public.perfis pf
      left join public.corridas c on c.motoboy_id = pf.id and c.status = 'concluida' and c.teste = p_teste and public.ve_org(c.organizacao_id)
                                 and privado.dia_local(c.concluida_em) between p_inicio and p_fim
     where 'motoboy' = any (pf.papeis) and public.ve_pessoa(pf.id)
     group by pf.id
    ) t
  ), '[]'::jsonb);
end;
$$;
create or replace function privado.calcular_pagamento(p_corrida uuid, p_motoboy uuid default null)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  c        public.corridas%rowtype;
  v_m      uuid;
  v_ant    text := current_setting('pwex.regras', true);
  v_rr     jsonb;
  v_modos  text[];
  v_comb   text;
  v_parte  jsonb;
  v_partes jsonb := '[]';
  v_vals   numeric[] := '{}';
  v_t      numeric;
  v_acr    numeric; v_acrp numeric;
  v_teto   numeric;
  v_modo   text;
  v_res    jsonb;
  v_vkm    numeric; v_vm numeric; v_vv numeric; v_ult public.paradas%rowtype; v_ini public.paradas%rowtype;
begin
  select * into c from public.corridas where id = p_corrida;
  if not found then return null; end if;
  c.valor := coalesce(nullif(current_setting('pwex.valor_rota', true), '')::numeric, c.valor);
  v_m := coalesce(p_motoboy, c.motoboy_id);
  v_rr := coalesce(nullif(current_setting('pwex.pag_regras_rota', true), '')::jsonb, c.pag_regras, '{}');
  if v_rr <> '{}' then
    perform set_config('pwex.regras', (coalesce(nullif(v_ant, '')::jsonb, '{}') || v_rr)::text, true);
  end if;
  begin
    select array_agg(x) into v_modos from jsonb_array_elements_text(
      case when jsonb_typeof(privado.pol('pag_modos', c.empresa_id, v_m, c.tipo_pedido)) = 'array' then privado.pol('pag_modos', c.empresa_id, v_m, c.tipo_pedido) else '[]' end) x
     where x in ('zonas', 'rota', 'percentual', 'por_entrega', 'fixo', 'salario', 'diaria', 'por_hora');
    if coalesce(array_length(v_modos, 1), 0) = 0 then v_modos := array[privado.pol_txt('pag_modo', 'zonas', c.empresa_id, v_m, c.tipo_pedido)]; end if;
    -- salário, diária e hora entram no holerite do período, não na rota
    v_modos := array(select x from unnest(v_modos) x where x not in ('salario', 'diaria', 'por_hora'));
    v_comb := privado.pol_txt('pag_combinar', 'soma', c.empresa_id, v_m, c.tipo_pedido);
    v_acr := privado.pol_num('pag_acrescimo_rota', 0, c.empresa_id, v_m, c.tipo_pedido);
    v_acrp := privado.pol_num('pag_acrescimo_pct', 0, c.empresa_id, v_m, c.tipo_pedido);
    foreach v_modo in array v_modos loop
      v_parte := case v_modo when 'por_entrega' then privado.pag_por_entrega(p_corrida, v_m)
                             when 'fixo' then privado.pag_fixo(p_corrida, v_m)
                             else privado.calcular_pagamento_um(p_corrida, v_m, v_modo) end;
      v_partes := v_partes || jsonb_build_array(v_parte || jsonb_build_object('parte', v_modo));
      v_vals := v_vals || coalesce((v_parte ->> 'calculado')::numeric, (v_parte ->> 'total')::numeric, 0);
    end loop;
    v_teto := greatest(coalesce(c.valor, 0), 0);
    if coalesce(array_length(v_modos, 1), 0) = 0 then
      v_res := jsonb_build_object('modo', 'periodo', 'partes', '[]'::jsonb, 'valor_rota', coalesce(c.valor, 0), 'teto', v_teto,
                                  'calculado', greatest(v_acr, 0), 'limitado', false, 'total', least(greatest(v_acr, 0), v_teto),
                                  'obs', 'Pago no holerite (salário, diária ou hora).');
    elsif array_length(v_modos, 1) = 1 and v_acr = 0 and v_acrp = 0 then
      v_res := v_partes -> 0;
    else
      v_t := case v_comb when 'maior' then (select max(u) from unnest(v_vals) u)
                         when 'menor' then (select min(u) from unnest(v_vals) u)
                         when 'media' then (select round(avg(u), 2) from unnest(v_vals) u)
                         else (select sum(u) from unnest(v_vals) u) end;
      v_t := round(v_t * (1 + v_acrp / 100) + v_acr, 2);
      v_res := jsonb_build_object('modo', 'combinado', 'combinar', v_comb, 'partes', v_partes, 'acrescimo', v_acr, 'acrescimo_pct', v_acrp,
                                  'valor_rota', coalesce(c.valor, 0), 'teto', v_teto, 'calculado', v_t, 'limitado', v_t > v_teto, 'total', least(v_t, v_teto));
    end if;
    -- volta: da última parada até o ponto de partida (a primeira coleta), em km × valor
    if privado.pol_bool('pag_volta', false, c.empresa_id, v_m, c.tipo_pedido) then
      select * into v_ult from public.paradas where corrida_id = p_corrida order by ordem desc limit 1;
      select * into v_ini from public.paradas where corrida_id = p_corrida and tipo = 'coleta' order by ordem limit 1;
      if v_ult.id is not null and v_ini.id is not null and v_ult.id <> v_ini.id then
        v_vm := privado.dist_m(v_ult.lat, v_ult.lng, v_ini.lat, v_ini.lng) * privado.pol_num('fator_rua', 1.3, c.empresa_id, v_m, c.tipo_pedido);
        v_vkm := privado.pol_num('pag_volta_valor_km', privado.pol_num('pag_valor_km', 2, c.empresa_id, v_m, c.tipo_pedido), c.empresa_id, v_m, c.tipo_pedido);
        v_vv := round(round(v_vm / 1000.0, 2) * v_vkm * privado.pol_num('pag_volta_pct', 100, c.empresa_id, v_m, c.tipo_pedido) / 100, 2);
        v_t := coalesce((v_res ->> 'calculado')::numeric, (v_res ->> 'total')::numeric, 0) + v_vv;
        v_res := v_res || jsonb_build_object('volta', jsonb_build_object('km', round(v_vm / 1000.0, 2), 'valor_km', v_vkm,
                     'pct', privado.pol_num('pag_volta_pct', 100, c.empresa_id, v_m, c.tipo_pedido), 'valor', v_vv),
                   'calculado', v_t,
                   'limitado', privado.pol_bool('pag_volta_teto', true, c.empresa_id, v_m, c.tipo_pedido) and v_t > v_teto,
                   'total', case when privado.pol_bool('pag_volta_teto', true, c.empresa_id, v_m, c.tipo_pedido) then least(v_t, v_teto) else v_t end);
      end if;
    end if;
    if v_rr <> '{}' then v_res := v_res || jsonb_build_object('regras_rota', v_rr); end if;
  exception when others then
    perform set_config('pwex.regras', coalesce(v_ant, ''), true);
    raise;
  end;
  perform set_config('pwex.regras', coalesce(v_ant, ''), true);
  return v_res;
end;
$$;

-- ===================================================================== empresas (Dev)
alter table public.organizacoes add column if not exists cobranca_periodo text not null default 'mensal';
alter table public.organizacoes drop constraint if exists organizacoes_cobranca_periodo_check;
alter table public.organizacoes add constraint organizacoes_cobranca_periodo_check check (cobranca_periodo in ('mensal', 'anual', 'vitalicia'));
alter table public.organizacoes add column if not exists suspensa_motivo text;
alter table public.organizacoes add column if not exists suspensa_em timestamptz;
alter table public.licencas add column if not exists periodo text not null default 'mensal';
create or replace function public.dev_salvar_organizacao(p jsonb)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_id uuid := nullif(p ->> 'id', '')::uuid; v_antes public.organizacoes%rowtype;
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  if v_id is null then
    if coalesce(trim(p ->> 'nome'), '') = '' then raise exception 'nome_obrigatorio' using errcode = '22023'; end if;
    insert into public.organizacoes (nome) values (trim(p ->> 'nome')) returning id into v_id;
  end if;
  select * into v_antes from public.organizacoes where id = v_id;
  if not found then raise exception 'empresa_nao_encontrada' using errcode = '22023'; end if;
  update public.organizacoes set
    nome                  = coalesce(nullif(trim(p ->> 'nome'), ''), nome),
    slug                  = case when p ? 'slug' then nullif(lower(regexp_replace(p ->> 'slug', '[^a-zA-Z0-9-]+', '-', 'g')), '') else slug end,
    documento             = case when p ? 'documento' then nullif(regexp_replace(p ->> 'documento', '\D', '', 'g'), '') else documento end,
    logo_url              = case when p ? 'logo_url' then nullif(p ->> 'logo_url', '') else logo_url end,
    cor                   = case when p ? 'cor' then nullif(p ->> 'cor', '') else cor end,
    dono_id               = case when p ? 'dono_id' then nullif(p ->> 'dono_id', '')::uuid else dono_id end,
    status                = coalesce(p ->> 'status', status),
    cobranca_modelo       = coalesce(p ->> 'cobranca_modelo', cobranca_modelo),
    cobranca_pct          = coalesce((p ->> 'cobranca_pct')::numeric, cobranca_pct),
    mensalidade           = coalesce((p ->> 'mensalidade')::numeric, mensalidade),
    vencimento_dia        = coalesce((p ->> 'vencimento_dia')::int, vencimento_dia),
    limites               = coalesce(p -> 'limites', limites),
    compartilhar          = coalesce(p ->> 'compartilhar', compartilhar),
    compartilhar_apos_min = coalesce((p ->> 'compartilhar_apos_min')::int, compartilhar_apos_min),
    receber_de_outras     = coalesce((p ->> 'receber_de_outras')::boolean, receber_de_outras),
    parceiros             = case when p ? 'parceiros' then coalesce((select array_agg(x::uuid) from jsonb_array_elements_text(p -> 'parceiros') x where x <> v_id::text), '{}') else parceiros end,
    cobranca_periodo      = coalesce(p ->> 'cobranca_periodo', cobranca_periodo),
    suspensa_motivo       = case when p ? 'suspensa_motivo' then nullif(trim(p ->> 'suspensa_motivo'), '') else suspensa_motivo end,
    suspensa_em           = case when coalesce(p ->> 'status', status) in ('suspensa', 'cancelada') then coalesce(suspensa_em, now()) else null end,
    observacoes           = case when p ? 'observacoes' then nullif(p ->> 'observacoes', '') else observacoes end
   where id = v_id;
  -- o dono passa a ser gestor desta empresa
  if p ? 'dono_id' and nullif(p ->> 'dono_id', '') is not null then
    update public.perfis set organizacao_id = v_id,
           papeis = (select array_agg(distinct x) from unnest(papeis || array['gestor']::public.papel_usuario[]) x)
     where id = (p ->> 'dono_id')::uuid and not ('dev' = any (papeis));
  end if;
  -- mudou o modelo de cobrança: fecha a licença anterior e abre uma nova no histórico
  if v_antes.cobranca_modelo is distinct from (select cobranca_modelo from public.organizacoes where id = v_id)
     or v_antes.mensalidade is distinct from (select mensalidade from public.organizacoes where id = v_id)
     or v_antes.cobranca_pct is distinct from (select cobranca_pct from public.organizacoes where id = v_id)
     or v_antes.cobranca_periodo is distinct from (select cobranca_periodo from public.organizacoes where id = v_id)
     or not exists (select 1 from public.licencas where organizacao_id = v_id) then
    update public.licencas set status = 'encerrada', fim = current_date where organizacao_id = v_id and status = 'ativa';
    insert into public.licencas (organizacao_id, modelo, valor, pct, criado_por, periodo)
    select id, cobranca_modelo, mensalidade, cobranca_pct, auth.uid(), cobranca_periodo from public.organizacoes where id = v_id;
  end if;
  perform privado.chat_geral_da_org(v_id);
  return v_id;
end;
$$;
create or replace function public.dev_faturamento(p_de date default null, p_ate date default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_de   date := coalesce(p_de, date_trunc('month', now() at time zone 'America/Sao_Paulo')::date);
  v_ate  date := coalesce(p_ate, (now() at time zone 'America/Sao_Paulo')::date);
  v_dias numeric;
  r      jsonb;
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  if v_ate < v_de then raise exception 'periodo_invalido' using errcode = '22023'; end if;
  v_dias := (v_ate - v_de) + 1;
  with base as (
    select c.*, (c.concluida_em at time zone 'America/Sao_Paulo')::date dia
      from public.corridas c
     where c.status = 'concluida' and not coalesce(c.teste, false)
       and (c.concluida_em at time zone 'America/Sao_Paulo')::date between v_de and v_ate
  ), por_org as (
    select o.id, o.nome, o.status, o.cobranca_modelo, o.cobranca_periodo, o.cobranca_pct, o.mensalidade, o.logo_url, o.cor,
      count(b.id) rotas,
      coalesce(sum(b.valor), 0) faturamento,
      coalesce(sum(b.valor_motoboy), 0) repasse,
      coalesce(sum(b.valor_gestao), 0) gestao,
      coalesce(sum(b.valor_dev), 0) dev_percentual,
      coalesce(sum(coalesce(b.distancia_real_m, b.distancia_planejada_m, 0)), 0) / 1000.0 km,
      count(distinct b.empresa_id) clientes_ativos,
      count(distinct b.motoboy_id) motoboys_ativos,
      (select count(*) from public.paradas pa join base b2 on b2.id = pa.corrida_id where b2.organizacao_id = o.id and pa.tipo = 'entrega') entregas,
      (select count(*) from public.pedidos x where x.organizacao_id = o.id and not coalesce(x.teste, false)
          and (x.criado_em at time zone 'America/Sao_Paulo')::date between v_de and v_ate) pedidos,
      (select count(*) from public.empresas e where e.organizacao_id = o.id) clientes,
      (select count(*) from public.perfis p where p.organizacao_id = o.id and 'motoboy' = any (p.papeis)) motoboys,
      (select count(*) from public.perfis p where p.organizacao_id = o.id and p.papeis && array['gestor', 'supervisor']::public.papel_usuario[]) gestores
    from public.organizacoes o
    left join base b on b.organizacao_id = o.id
    group by o.id
  ), calc as (
    select x.*,
      round(case x.cobranca_modelo
        when 'percentual' then x.dev_percentual
        when 'licenca' then case x.cobranca_periodo
          when 'anual' then x.mensalidade * v_dias / 365.0
          -- vitalícia: entra uma vez, no período em que a licença começou
          when 'vitalicia' then case when exists (select 1 from public.licencas l where l.organizacao_id = x.id and l.status = 'ativa'
                                                   and l.periodo = 'vitalicia' and l.inicio between v_de and v_ate) then x.mensalidade else 0 end
          else x.mensalidade * v_dias / 30.0 end
        else 0 end, 2) receita_dev,
      case when x.rotas > 0 then round(x.faturamento / x.rotas, 2) else 0 end ticket_medio
    from por_org x
  )
  select jsonb_build_object(
    'de', v_de, 'ate', v_ate, 'dias', v_dias,
    'totais', (select jsonb_build_object(
        'empresas', count(*), 'ativas', count(*) filter (where status = 'ativa'),
        'faturamento', coalesce(sum(faturamento), 0), 'receita_dev', coalesce(sum(receita_dev), 0),
        'rotas', coalesce(sum(rotas), 0), 'entregas', coalesce(sum(entregas), 0), 'km', round(coalesce(sum(km), 0), 1),
        'motoboys', coalesce(sum(motoboys), 0), 'clientes', coalesce(sum(clientes), 0)) from calc),
    'empresas', coalesce((select jsonb_agg(jsonb_build_object(
        'id', id, 'nome', nome, 'status', status, 'logo', logo_url, 'cor', cor,
        'modelo', cobranca_modelo, 'periodo', cobranca_periodo, 'pct', cobranca_pct, 'mensalidade', mensalidade,
        'rotas', rotas, 'entregas', entregas, 'pedidos', pedidos, 'km', round(km, 1),
        'faturamento', faturamento, 'repasse', repasse, 'gestao', gestao, 'receita_dev', receita_dev, 'ticket_medio', ticket_medio,
        'clientes', clientes, 'clientes_ativos', clientes_ativos, 'motoboys', motoboys, 'motoboys_ativos', motoboys_ativos, 'gestores', gestores,
        'serie', (select coalesce(jsonb_agg(jsonb_build_object('dia', d.dia, 'faturamento', d.fat, 'rotas', d.n, 'dev', d.dev) order by d.dia), '[]'::jsonb)
                    from (select b.dia, sum(b.valor) fat, count(*) n, sum(b.valor_dev) dev from base b where b.organizacao_id = calc.id group by b.dia) d),
        'top_clientes', (select coalesce(jsonb_agg(t), '[]'::jsonb) from (
                    select e.nome, count(*) rotas, sum(b.valor) faturamento from base b join public.empresas e on e.id = b.empresa_id
                     where b.organizacao_id = calc.id group by e.nome order by sum(b.valor) desc nulls last limit 5) t)
      ) order by receita_dev desc, faturamento desc) from calc), '[]'::jsonb),
    'serie', (select coalesce(jsonb_agg(jsonb_build_object('dia', d.dia, 'faturamento', d.fat, 'rotas', d.n, 'dev', d.dev) order by d.dia), '[]'::jsonb)
                from (select b.dia, sum(b.valor) fat, count(*) n, sum(b.valor_dev) dev from base b group by b.dia) d)
  ) into r;
  return r;
end;
$$;
create or replace function public.meu_plano(p_de date default null, p_ate date default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_org  uuid := public.minha_org();
  v_de   date := coalesce(p_de, date_trunc('month', now() at time zone 'America/Sao_Paulo')::date);
  v_ate  date := coalesce(p_ate, (now() at time zone 'America/Sao_Paulo')::date);
  o      public.organizacoes%rowtype;
  v_fat  numeric; v_rotas int; v_pct_val numeric; v_devido numeric; v_venc date;
begin
  if not public.is_gestor_pleno() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if v_org is null then return null; end if;
  select * into o from public.organizacoes where id = v_org;
  select coalesce(sum(c.valor), 0), count(*), coalesce(sum(c.valor_dev), 0) into v_fat, v_rotas, v_pct_val
    from public.corridas c
   where c.organizacao_id = v_org and c.status = 'concluida' and not coalesce(c.teste, false)
     and (c.concluida_em at time zone 'America/Sao_Paulo')::date between v_de and v_ate;
  v_devido := round(case o.cobranca_modelo when 'percentual' then v_pct_val
    when 'licenca' then case o.cobranca_periodo when 'anual' then o.mensalidade / 12.0 when 'vitalicia' then 0 else o.mensalidade end else 0 end, 2);
  v_venc := make_date(extract(year from v_ate)::int, extract(month from v_ate)::int, o.vencimento_dia);
  if v_venc < v_ate then v_venc := (v_venc + interval '1 month')::date; end if;
  return jsonb_build_object(
    'empresa', o.nome, 'status', o.status, 'modelo', o.cobranca_modelo,
    'pct', o.cobranca_pct, 'mensalidade', o.mensalidade, 'periodo', o.cobranca_periodo, 'vencimento_dia', o.vencimento_dia, 'proximo_vencimento', v_venc,
    'de', v_de, 'ate', v_ate, 'faturamento', v_fat, 'rotas', v_rotas, 'devido', v_devido,
    'limites', o.limites,
    'historico', coalesce((select jsonb_agg(jsonb_build_object('modelo', l.modelo, 'valor', l.valor, 'pct', l.pct,
        'inicio', l.inicio, 'fim', l.fim, 'status', l.status) order by l.inicio desc, l.criado_em desc)
        from public.licencas l where l.organizacao_id = v_org), '[]'::jsonb),
    'meses', coalesce((select jsonb_agg(jsonb_build_object('mes', m.mes, 'faturamento', m.fat, 'rotas', m.n, 'devido',
          round(case o.cobranca_modelo when 'percentual' then m.dev when 'licenca' then case o.cobranca_periodo when 'anual' then o.mensalidade / 12.0 when 'vitalicia' then 0 else o.mensalidade end else 0 end, 2)) order by m.mes desc)
        from (select date_trunc('month', c.concluida_em at time zone 'America/Sao_Paulo')::date mes, sum(c.valor) fat, count(*) n, sum(c.valor_dev) dev
                from public.corridas c where c.organizacao_id = v_org and c.status = 'concluida' and not coalesce(c.teste, false)
                 and c.concluida_em > now() - interval '6 months' group by 1) m), '[]'::jsonb));
end;
$$;

-- Tudo de uma empresa, para a tela do Dev: equipe com último acesso, números, licenças, versões do app.
create or replace function public.dev_empresa_detalhe(p_org uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare o public.organizacoes%rowtype; v_30 timestamptz := now() - interval '30 days';
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  select * into o from public.organizacoes where id = p_org;
  if not found then raise exception 'empresa_nao_encontrada' using errcode = '22023'; end if;
  return privado.org_json(o) || jsonb_build_object(
    'equipe', coalesce((select jsonb_agg(jsonb_build_object(
        'id', p.id, 'nome', p.nome, 'foto', p.foto_url, 'papeis', to_jsonb(p.papeis), 'email', u.email,
        'ultimo_acesso', u.last_sign_in_at, 'bloqueado', u.banned_until is not null and u.banned_until > now(),
        'dono', p.id = o.dono_id, 'status', m.status, 'posicao_em', m.posicao_em, 'versao_app', m.versao_app,
        'criado_em', p.criado_em) order by (p.id = o.dono_id) desc, p.nome)
        from public.perfis p left join auth.users u on u.id = p.id left join public.motoboys m on m.id = p.id
       where p.organizacao_id = p_org and not ('dev' = any (p.papeis))), '[]'::jsonb),
    'numeros', jsonb_build_object(
      'clientes', (select count(*) from public.empresas where organizacao_id = p_org),
      'pedidos', (select count(*) from public.pedidos where organizacao_id = p_org and not coalesce(teste, false)),
      'pedidos_30d', (select count(*) from public.pedidos where organizacao_id = p_org and not coalesce(teste, false) and criado_em > v_30),
      'rotas', (select count(*) from public.corridas where organizacao_id = p_org and status = 'concluida' and not coalesce(teste, false)),
      'rotas_30d', (select count(*) from public.corridas where organizacao_id = p_org and status = 'concluida' and not coalesce(teste, false) and concluida_em > v_30),
      'faturado_30d', (select coalesce(sum(valor), 0) from public.corridas where organizacao_id = p_org and status = 'concluida' and not coalesce(teste, false) and concluida_em > v_30),
      'faturado_total', (select coalesce(sum(valor), 0) from public.corridas where organizacao_id = p_org and status = 'concluida' and not coalesce(teste, false)),
      'em_andamento', (select count(*) from public.corridas where organizacao_id = p_org and status::text in ('aceita', 'em_andamento')),
      'ultimo_pedido', (select max(criado_em) from public.pedidos where organizacao_id = p_org),
      'ultima_rota', (select max(concluida_em) from public.corridas where organizacao_id = p_org and status = 'concluida'),
      'zonas', (select count(*) from public.zonas where organizacao_id = p_org),
      'excecoes', (select count(*) from public.politicas where escopo = 'organizacao' and alvo = p_org::text)),
    'licencas', coalesce((select jsonb_agg(to_jsonb(l) order by l.inicio desc, l.criado_em desc) from public.licencas l where l.organizacao_id = p_org), '[]'::jsonb),
    'clientes_lista', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'nome', e.nome, 'pedidos',
        (select count(*) from public.pedidos x where x.empresa_id = e.id)) order by e.nome) from public.empresas e where e.organizacao_id = p_org), '[]'::jsonb));
end;
$$;
revoke execute on function public.dev_empresa_detalhe(uuid) from public, anon;
grant execute on function public.dev_empresa_detalhe(uuid) to authenticated;

-- Excluir uma empresa inteira (com a senha do Dev). As contas ficam, sem empresa (o Dev pode mover).
create or replace function public.dev_excluir_organizacao(p_org uuid, p_senha text, p_confirmar text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_erro jsonb; o public.organizacoes%rowtype; v_pessoas int;
begin
  if not public.is_dev() then raise exception 'apenas_dev' using errcode = '42501'; end if;
  v_erro := privado.senha_com_limite(p_senha);
  if v_erro is not null then return v_erro; end if;
  select * into o from public.organizacoes where id = p_org;
  if not found then raise exception 'empresa_nao_encontrada' using errcode = '22023'; end if;
  if coalesce(trim(p_confirmar), '') <> o.nome then raise exception 'confirmacao_errada' using errcode = '22023'; end if;
  select count(*) into v_pessoas from public.perfis where organizacao_id = p_org;
  update public.perfis set org_em_foco = null where org_em_foco = p_org;
  update public.motoboys set status = 'offline', status_em = now() where id in (select id from public.perfis where organizacao_id = p_org) and status <> 'offline';
  delete from public.politicas where escopo = 'organizacao' and alvo = p_org::text;
  delete from public.politicas where escopo = 'tipo' and alvo like p_org::text || ':%';
  delete from public.organizacoes where id = p_org;
  return jsonb_build_object('ok', true, 'nome', o.nome, 'contas_sem_empresa', v_pessoas);
end;
$$;
revoke execute on function public.dev_excluir_organizacao(uuid, text, text) from public, anon;
grant execute on function public.dev_excluir_organizacao(uuid, text, text) to authenticated;
create or replace function privado.org_json(o public.organizacoes)
returns jsonb language sql stable security definer set search_path = '' as $$
  select to_jsonb(o) || jsonb_build_object(
    'dono', (select jsonb_build_object('id', p.id, 'nome', p.nome, 'foto', p.foto_url) from public.perfis p where p.id = o.dono_id),
    'gestores', (select count(*) from public.perfis p where p.organizacao_id = o.id and p.papeis && array['gestor', 'supervisor']::public.papel_usuario[]),
    'motoboys', (select count(*) from public.perfis p where p.organizacao_id = o.id and 'motoboy' = any (p.papeis)),
    'online', (select count(*) from public.perfis p join public.motoboys m on m.id = p.id where p.organizacao_id = o.id and m.status <> 'offline'),
    'clientes', (select count(*) from public.empresas e where e.organizacao_id = o.id),
    'rotas_30d', (select count(*) from public.corridas c where c.organizacao_id = o.id and c.status = 'concluida' and not coalesce(c.teste, false) and c.concluida_em > now() - interval '30 days'),
    'faturado_30d', (select coalesce(sum(c.valor), 0) from public.corridas c where c.organizacao_id = o.id and c.status = 'concluida' and not coalesce(c.teste, false) and c.concluida_em > now() - interval '30 days'),
    'ultimo_pedido', (select max(x.criado_em) from public.pedidos x where x.organizacao_id = o.id),
    'licenca', (select to_jsonb(l) from public.licencas l where l.organizacao_id = o.id and l.status = 'ativa' order by l.inicio desc limit 1));
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
    'organizacao', (select jsonb_build_object('id', o.id, 'nome', o.nome, 'nome_app', o.nome_app, 'logo', o.logo_url, 'logo_escala', o.logo_escala, 'logo_original', o.logo_original_url, 'brilho_cor', o.logo_brilho_cor, 'brilho', o.logo_brilho, 'fonte', o.fonte_nome, 'cor', o.cor, 'status', o.status, 'suspensa_motivo', case when o.status in ('suspensa', 'cancelada') then o.suspensa_motivo end)
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

notify pgrst, 'reload schema';
