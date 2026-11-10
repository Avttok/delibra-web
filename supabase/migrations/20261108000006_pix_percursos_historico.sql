-- =====================================================================
-- PW Express · Chaves PIX múltiplas, percursos separados teste/real e
-- apagar histórico em massa (gestor e Dev)
-- ---------------------------------------------------------------------
--  • chaves_pix: cada pessoa cadastra quantas chaves quiser; uma é a
--    principal (para onde vai o repasse). As chaves que já existiam em
--    dados_recebimento são copiadas como principal. A tabela antiga fica
--    (não é apagada) e a função antiga continua funcionando para APKs velhos.
--  • localizacoes.teste: cada ping é gravado como teste ou real (segue a
--    corrida, ou o modo teste do motoboy na hora). Percursos de um modo não
--    aparecem no outro.
--  • apagar_historico: apaga de uma vez corridas finalizadas e/ou percursos
--    de todos (ou de um motoboy), do modo teste ou do real, até uma data.
--    Exige a senha, como a exclusão de corridas, e guarda cópia das corridas.
-- Seguro rodar de novo.
-- =====================================================================

-- ------------------------------------------------------------- chaves PIX
create table if not exists public.chaves_pix (
  id          uuid primary key default gen_random_uuid(),
  usuario_id  uuid not null references public.perfis (id) on delete cascade,
  tipo_chave  text not null check (tipo_chave in ('cpf', 'cnpj', 'email', 'telefone', 'aleatoria')),
  chave       text not null,
  titular     text not null,
  principal   boolean not null default false,
  criado_em   timestamptz not null default now(),
  unique (usuario_id, chave)
);
create unique index if not exists chaves_pix_uma_principal on public.chaves_pix (usuario_id) where principal;
create index if not exists chaves_pix_usuario_idx on public.chaves_pix (usuario_id);

alter table public.chaves_pix enable row level security;
drop policy if exists chaves_pix_leitura on public.chaves_pix;
create policy chaves_pix_leitura on public.chaves_pix for select to authenticated
  using (usuario_id = (select auth.uid()) or (select public.is_gestor()));
revoke all on public.chaves_pix from anon;
grant select on public.chaves_pix to authenticated;

-- copia a chave antiga (uma por pessoa) como principal
insert into public.chaves_pix (usuario_id, tipo_chave, chave, titular, principal, criado_em)
select usuario_id, tipo_chave, chave, titular, true, atualizado_em from public.dados_recebimento d
 where not exists (select 1 from public.chaves_pix c where c.usuario_id = d.usuario_id)
on conflict do nothing;

-- A chave confere com o tipo? (o app e o site já mandam normalizada)
create or replace function privado.chave_pix_valida(p_tipo text, p_chave text)
returns boolean language sql immutable set search_path = '' as $$
  select case p_tipo
    when 'cpf'       then p_chave ~ '^[0-9]{11}$'
    when 'cnpj'      then p_chave ~ '^[A-Z0-9]{12}[0-9]{2}$'
    when 'telefone'  then p_chave ~ '^\+55[1-9]{2}9[0-9]{8}$'
    when 'email'     then p_chave ~ '^[^\s@]+@[^\s@]+\.[^\s@]{2,}$' and length(p_chave) <= 77
    when 'aleatoria' then p_chave ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    else false end;
$$;

create or replace function public.adicionar_chave_pix(p_tipo text, p_chave text, p_titular text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_id    uuid;
  v_chave text := trim(p_chave);
begin
  if auth.uid() is null then raise exception 'nao_autenticado' using errcode = '28000'; end if;
  if p_tipo not in ('cpf', 'cnpj', 'email', 'telefone', 'aleatoria') then raise exception 'tipo_invalido' using errcode = '22023'; end if;
  if p_tipo = 'email' then v_chave := lower(v_chave); end if;
  if not privado.chave_pix_valida(p_tipo, v_chave) then raise exception 'chave_invalida' using errcode = '22023'; end if;
  if length(trim(coalesce(p_titular, ''))) < 3 then raise exception 'titular_invalido' using errcode = '22023'; end if;
  if exists (select 1 from public.chaves_pix where usuario_id = auth.uid() and chave = v_chave) then
    raise exception 'chave_repetida' using errcode = '23505';
  end if;
  insert into public.chaves_pix (usuario_id, tipo_chave, chave, titular, principal)
  values (auth.uid(), p_tipo, v_chave, left(trim(p_titular), 120),
          not exists (select 1 from public.chaves_pix where usuario_id = auth.uid()))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.remover_chave_pix(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_era_principal boolean;
begin
  delete from public.chaves_pix where id = p_id and usuario_id = auth.uid() returning principal into v_era_principal;
  -- a mais antiga que sobrou vira a principal
  if v_era_principal then
    update public.chaves_pix set principal = true
     where id = (select id from public.chaves_pix where usuario_id = auth.uid() order by criado_em limit 1);
  end if;
end;
$$;

create or replace function public.definir_chave_pix_principal(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.chaves_pix where id = p_id and usuario_id = auth.uid()) then
    raise exception 'chave_nao_encontrada' using errcode = '22023';
  end if;
  update public.chaves_pix set principal = false where usuario_id = auth.uid() and principal and id <> p_id;
  update public.chaves_pix set principal = true where id = p_id;
end;
$$;

-- APK antigo (uma chave só): grava/atualiza a principal nas duas tabelas
create or replace function public.definir_minha_chave_pix(p_tipo text, p_chave text, p_titular text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if coalesce(trim(p_chave), '') = '' then
    delete from public.dados_recebimento where usuario_id = auth.uid();
    perform public.remover_chave_pix(id) from public.chaves_pix where usuario_id = auth.uid() and principal;
    return;
  end if;
  if p_tipo not in ('cpf', 'cnpj', 'email', 'telefone', 'aleatoria') then raise exception 'tipo_invalido' using errcode = '22023'; end if;
  if length(trim(p_titular)) < 3 then raise exception 'titular_invalido' using errcode = '22023'; end if;
  insert into public.dados_recebimento (usuario_id, tipo_chave, chave, titular, atualizado_em)
  values (auth.uid(), p_tipo, left(trim(p_chave), 120), left(trim(p_titular), 120), now())
  on conflict (usuario_id) do update set tipo_chave = excluded.tipo_chave, chave = excluded.chave, titular = excluded.titular, atualizado_em = now();
  update public.chaves_pix set principal = false where usuario_id = auth.uid() and principal;
  insert into public.chaves_pix (usuario_id, tipo_chave, chave, titular, principal)
  values (auth.uid(), p_tipo, left(trim(p_chave), 120), left(trim(p_titular), 120), true)
  on conflict (usuario_id, chave) do update set tipo_chave = excluded.tipo_chave, titular = excluded.titular, principal = true;
end;
$$;

-- ------------------------------------------------------------- percursos teste x real
alter table public.localizacoes add column if not exists teste boolean not null default false;
create index if not exists localizacoes_teste_tempo_idx on public.localizacoes (teste, registrado_em desc);

-- cada ping nasce teste ou real: o da corrida manda; sem corrida, o modo do motoboy
create or replace function privado.marcar_ping_teste()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.corrida_id is not null then
    select c.teste into new.teste from public.corridas c where c.id = new.corrida_id;
  end if;
  if new.corrida_id is null or new.teste is null then
    select coalesce(m.modo_teste, false) into new.teste from public.motoboys m where m.id = new.motoboy_id;
  end if;
  new.teste := coalesce(new.teste, false);
  return new;
end;
$$;
drop trigger if exists localizacoes_marcar_teste on public.localizacoes;
create trigger localizacoes_marcar_teste before insert on public.localizacoes
  for each row execute function privado.marcar_ping_teste();

-- pings antigos de corrida de teste passam a ser teste (os sem corrida ficam como real)
update public.localizacoes l set teste = true
  from public.corridas c where l.corrida_id = c.id and c.teste and not l.teste;

-- ------------------------------------------------------------- apagar histórico em massa
-- Confere a senha com o mesmo limite da exclusão de corridas (5 erradas / 15 min).
-- Devolve null se conferiu, ou o erro para mostrar.
create or replace function privado.senha_com_limite(p_senha text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  delete from privado.tentativas_senha where quando < now() - interval '15 minutes';
  if (select count(*) from privado.tentativas_senha where usuario = auth.uid()) >= 5 then
    return jsonb_build_object('erro', 'muitas_tentativas');
  end if;
  if not privado.senha_confere(p_senha) then
    insert into privado.tentativas_senha (usuario) values (auth.uid());
    return jsonb_build_object('erro', 'senha_incorreta',
      'restantes', 5 - (select count(*) from privado.tentativas_senha where usuario = auth.uid()));
  end if;
  delete from privado.tentativas_senha where usuario = auth.uid();
  return null;
end;
$$;

-- Corridas que entram na limpeza: finalizadas, do modo pedido, de quem o chamador pode mexer.
create or replace function privado.corridas_do_historico(p_teste boolean, p_motoboy uuid, p_ate timestamptz)
returns setof uuid language sql stable security definer set search_path = '' as $$
  select c.id from public.corridas c
   where c.teste = p_teste
     and c.status::text in ('concluida', 'cancelada', 'sem_motoboy')
     and (p_motoboy is null or c.motoboy_id = p_motoboy)
     and (p_ate is null or c.criada_em < p_ate)
     and (c.motoboy_id is null or public.pode_gerenciar(c.motoboy_id));
$$;

-- Pings que entram na limpeza: os de procurar corrida (sem corrida) e os de corridas que já não existem.
create or replace function privado.pings_do_historico(p_teste boolean, p_motoboy uuid, p_ate timestamptz)
returns setof bigint language sql stable security definer set search_path = '' as $$
  select l.id from public.localizacoes l
   where l.teste = p_teste
     and (p_motoboy is null or l.motoboy_id = p_motoboy)
     and (p_ate is null or l.registrado_em < p_ate)
     and (l.corrida_id is null or not exists (select 1 from public.corridas c where c.id = l.corrida_id))
     and public.pode_gerenciar(l.motoboy_id);
$$;

-- Quanto seria apagado (para a janela mostrar antes de pedir a senha).
create or replace function public.previa_historico(p_teste boolean, p_motoboy uuid default null, p_ate timestamptz default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  return jsonb_build_object(
    'corridas', (select count(*) from privado.corridas_do_historico(p_teste, p_motoboy, p_ate)),
    'pings', (select count(*) from privado.pings_do_historico(p_teste, p_motoboy, p_ate))
  );
end;
$$;

create or replace function public.apagar_historico(
  p_senha text, p_teste boolean, p_corridas boolean, p_percursos boolean,
  p_motoboy uuid default null, p_ate timestamptz default null, p_motivo text default null
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_erro     jsonb;
  v_ids      uuid[];
  v_arquivos text[] := '{}';
  v_corridas int := 0;
  v_pings    int := 0;
begin
  if not public.is_gestor() then raise exception 'apenas_gestor' using errcode = '42501'; end if;
  if not coalesce(p_corridas, false) and not coalesce(p_percursos, false) then raise exception 'nada_para_excluir' using errcode = '22023'; end if;
  if p_motoboy is not null and not public.pode_gerenciar(p_motoboy) then raise exception 'sem_permissao' using errcode = '42501'; end if;

  v_erro := privado.senha_com_limite(p_senha);
  if v_erro is not null then return v_erro; end if;

  if p_corridas then
    select coalesce(array_agg(id), '{}') into v_ids from privado.corridas_do_historico(p_teste, p_motoboy, p_ate) id;
    if cardinality(v_ids) > 0 then
      insert into public.registro_exclusoes (corrida_id, numero, teste, status, valor, copia, motivo, excluida_por)
      select c.id, c.numero, c.teste, c.status::text, c.valor,
             jsonb_build_object(
               'corrida', to_jsonb(c),
               'paradas', coalesce((select jsonb_agg(to_jsonb(p) order by p.ordem) from public.paradas p where p.corrida_id = c.id), '[]'),
               'eventos', coalesce((select jsonb_agg(to_jsonb(e) order by e.criado_em) from public.eventos_corrida e where e.corrida_id = c.id), '[]')
             ),
             coalesce(nullif(trim(p_motivo), ''), 'Limpeza de histórico'), auth.uid()
        from public.corridas c where c.id = any (v_ids);

      select coalesce(array_agg(a), '{}') into v_arquivos
        from (select foto_path a from public.paradas where corrida_id = any (v_ids) and foto_path is not null
              union all
              select assinatura_path from public.paradas where corrida_id = any (v_ids) and assinatura_path is not null) t;

      delete from public.localizacoes where corrida_id = any (v_ids);
      delete from public.corridas where id = any (v_ids);
      get diagnostics v_corridas = row_count;
    end if;
  end if;

  if p_percursos then
    delete from public.localizacoes where id in (select privado.pings_do_historico(p_teste, p_motoboy, p_ate));
    get diagnostics v_pings = row_count;
  end if;

  return jsonb_build_object('corridas', v_corridas, 'pings', v_pings, 'arquivos', to_jsonb(v_arquivos));
end;
$$;

-- ------------------------------------------------------------- permissões
revoke all on all functions in schema privado from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array[
    'public.adicionar_chave_pix(text, text, text)', 'public.remover_chave_pix(uuid)', 'public.definir_chave_pix_principal(uuid)',
    'public.definir_minha_chave_pix(text, text, text)',
    'public.previa_historico(boolean, uuid, timestamptz)',
    'public.apagar_historico(text, boolean, boolean, boolean, uuid, timestamptz, text)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
