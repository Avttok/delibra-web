-- =====================================================================
-- Delibra · 0039: chat novo — responder, reagir, editar, buscar, áudio, grupo da corrida (cliente ↔ motoboy),
--                  caixa da empresa com horário e resposta automática, membros e admins, retenção e exportar
-- =====================================================================
set check_function_bodies = off;

insert into public.configuracoes (chave, valor) values
  ('chat_reacoes', 'true'), ('chat_responder', 'true'), ('chat_editar_min', '15'), ('chat_visto', 'true'),
  ('chat_corrida_ligado', 'true'), ('chat_cliente_motoboy', 'true'), ('chat_caixa_empresa', 'true'),
  ('chat_atendimento_ligado', 'false'), ('chat_atendimento_de', '"08:00"'), ('chat_atendimento_ate', '"18:00"'), ('chat_atendimento_dias', '[1,2,3,4,5]'),
  ('chat_resposta_auto', '"Recebemos sua mensagem. Nosso atendimento é das 8h às 18h, em dias úteis; respondemos assim que voltarmos."'),
  ('chat_gestor_gerencia_grupos', 'true'), ('chat_audio_ligado', 'true'),
  ('dev_chat_audio_ligado', 'true'), ('dev_chat_audio_max_s', '60'), ('dev_chat_audio_dias', '30'), ('dev_chat_retencao_dias', '0')
on conflict (chave) do nothing;

alter table public.chat_conversas drop constraint if exists chat_conversas_tipo_check;
alter table public.chat_conversas add constraint chat_conversas_tipo_check check (tipo in ('geral', 'direta', 'grupo', 'corrida', 'empresa'));
alter table public.chat_conversas add column if not exists corrida_id uuid references public.corridas (id) on delete set null;
alter table public.chat_conversas add column if not exists empresa_id uuid references public.empresas (id) on delete cascade;
alter table public.chat_conversas add column if not exists arquivada_em timestamptz;
create unique index if not exists chat_uma_por_corrida on public.chat_conversas (corrida_id) where tipo = 'corrida';
create unique index if not exists chat_uma_por_empresa on public.chat_conversas (empresa_id) where tipo = 'empresa';
alter table public.chat_membros add column if not exists admin boolean not null default false;
alter table public.chat_mensagens add column if not exists resposta_a uuid references public.chat_mensagens (id) on delete set null;
alter table public.chat_mensagens add column if not exists editada_em timestamptz;
alter table public.chat_mensagens add column if not exists reacoes jsonb not null default '{}'::jsonb;
alter table public.chat_mensagens add column if not exists automatica boolean not null default false;
create index if not exists chat_mensagens_busca on public.chat_mensagens using gin (to_tsvector('portuguese', coalesce(texto, '')));

-- (participação definida no fim)

-- ===================================================================== caixa da empresa (cliente ↔ empresa)
create or replace function public.chat_caixa_empresa(p_empresa uuid default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_emp uuid := coalesce(p_empresa, privado.minha_empresa()); v_org uuid; v_id uuid; v_nome text;
begin
  if v_emp is null then raise exception 'sem_empresa' using errcode = '22023'; end if;
  select organizacao_id, nome into v_org, v_nome from public.empresas where id = v_emp;
  if not (v_emp = privado.minha_empresa() or (public.is_gestor() and public.ve_org(v_org))) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if not privado.cfg_org_bool(v_org, 'chat_caixa_empresa', true) then raise exception 'chat_desligado' using errcode = '42501'; end if;
  select id into v_id from public.chat_conversas where tipo = 'empresa' and empresa_id = v_emp;
  if v_id is null then
    insert into public.chat_conversas (tipo, nome, organizacao_id, empresa_id, criada_por)
    values ('empresa', v_nome, v_org, v_emp, auth.uid()) on conflict do nothing returning id into v_id;
    if v_id is null then select id into v_id from public.chat_conversas where tipo = 'empresa' and empresa_id = v_emp; end if;
  end if;
  return v_id;
end;
$$;

-- fora do horário: resposta automática (uma por hora por conversa)
create or replace function privado.chat_fora_do_horario(p_org uuid)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare v_agora timestamp := (now() at time zone 'America/Sao_Paulo'); v_de time; v_ate time; v_dias jsonb;
begin
  if not privado.cfg_org_bool(p_org, 'chat_atendimento_ligado', false) then return false; end if;
  v_de := coalesce(nullif(privado.cfg_org_txt(p_org, 'chat_atendimento_de', '08:00'), '')::time, '08:00');
  v_ate := coalesce(nullif(privado.cfg_org_txt(p_org, 'chat_atendimento_ate', '18:00'), '')::time, '18:00');
  select coalesce(p.valor, c.valor) into v_dias from public.configuracoes c
    left join public.politicas p on p.escopo = 'organizacao' and p.alvo = p_org::text and p.chave = 'chat_atendimento_dias'
   where c.chave = 'chat_atendimento_dias';
  if jsonb_typeof(v_dias) = 'array' and not (v_dias @> to_jsonb(extract(isodow from v_agora)::int)) then return true; end if;
  return v_agora::time < v_de or v_agora::time >= v_ate;
exception when others then return false;
end;
$$;

drop function if exists public.chat_enviar(uuid, text, jsonb);
create or replace function public.chat_enviar(p_conversa uuid, p_texto text default null, p_anexo jsonb default null, p_resposta_a uuid default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  c        public.chat_conversas%rowtype;
  v_id     uuid;
  v_txt    text := nullif(left(trim(coalesce(p_texto, '')), 4000), '');
  v_previa text;
  v_nome   text;
  v_m      uuid;
begin
  if auth.uid() is null then raise exception 'nao_autenticado' using errcode = '28000'; end if;
  if not privado.cfg_bool('chat_ligado', true) then raise exception 'chat_desligado' using errcode = '42501'; end if;
  select * into c from public.chat_conversas where id = p_conversa;
  if not found or not public.chat_sou_membro(p_conversa) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  -- grupo de corrida que terminou: fica só para ler
  if c.arquivada_em is not null then raise exception 'conversa_arquivada' using errcode = '42501'; end if;
  if p_anexo ->> 'tipo' = 'audio' then
    if not privado.cfg_bool('dev_chat_audio_ligado', true) or not privado.cfg_org_bool(c.organizacao_id, 'chat_audio_ligado', true) then raise exception 'audio_desligado' using errcode = '42501'; end if;
    if coalesce((p_anexo ->> 'duracao')::numeric, 0) > privado.cfg_num('dev_chat_audio_max_s', 60) + 1 then raise exception 'audio_longo' using errcode = '22023'; end if;
  end if;
  if p_anexo is not null and (jsonb_typeof(p_anexo) <> 'object' or coalesce(p_anexo ->> 'tipo', '') not in ('foto', 'pedido', 'rota', 'cliente', 'pessoa', 'local', 'audio')) then
    raise exception 'anexo_invalido' using errcode = '22023';
  end if;
  if p_anexo ->> 'tipo' = 'foto' and not privado.cfg_bool('chat_fotos', true) then raise exception 'fotos_desligadas' using errcode = '42501'; end if;
  if p_anexo is not null and p_anexo ->> 'tipo' not in ('foto', 'audio') and not public.is_dev() and (
       not privado.cfg_bool('chat_compartilhar', true)
    or not coalesce(privado.cfg('chat_compartilhar_tipos', '["pedido","rota","cliente","pessoa","local"]'::jsonb) ? (p_anexo ->> 'tipo'), true)) then
    raise exception 'compartilhamento_desligado' using errcode = '42501';
  end if;
  if not public.chat_participo(p_conversa) and not exists (select 1 from public.chat_membros where conversa_id = p_conversa and usuario_id = auth.uid()) and public.is_dev() and not privado.cfg_bool('dev_escreve_em_conversas', false) then
    raise exception 'dev_so_le' using errcode = '42501';
  end if;
  if v_txt is null and p_anexo is null then raise exception 'mensagem_vazia' using errcode = '22023'; end if;
  if p_resposta_a is not null and not exists (select 1 from public.chat_mensagens r where r.id = p_resposta_a and r.conversa_id = p_conversa) then p_resposta_a := null; end if;
  insert into public.chat_mensagens (conversa_id, autor_id, texto, anexo, resposta_a) values (p_conversa, auth.uid(), v_txt, p_anexo, p_resposta_a) returning id into v_id;
  v_previa := left(coalesce(v_txt, case p_anexo ->> 'tipo' when 'foto' then '📷 Foto' when 'audio' then '🎤 Áudio' when 'local' then '📍 Local' else coalesce(p_anexo ->> 'titulo', 'Anexo') end), 120);
  update public.chat_conversas set ultima_em = now(), ultima_previa = v_previa, ultima_autor = auth.uid() where id = p_conversa;
  insert into public.chat_membros (conversa_id, usuario_id) values (p_conversa, auth.uid())
    on conflict (conversa_id, usuario_id) do update set lida_em = now();
  v_nome := split_part(public.nome_publico(auth.uid()), ' ', 1);
  for v_m in
    select x.id from (
      select m.usuario_id id, m.silenciada from public.chat_membros m where m.conversa_id = p_conversa
      union
      select p.id, false from public.perfis p where c.tipo = 'geral' and p.papeis && array['motoboy', 'gestor', 'supervisor']::public.papel_usuario[]
         and p.organizacao_id is not distinct from c.organizacao_id
      union
      -- caixa da empresa: quem atende e os usuários do cliente
      select p.id, false from public.perfis p where c.tipo = 'empresa' and (
             (p.organizacao_id = c.organizacao_id and ('gestor' = any (p.papeis) or ('supervisor' = any (p.papeis) and coalesce((p.permissoes ->> 'chat')::boolean, true))))
          or (p.empresa_id = c.empresa_id and 'cliente' = any (p.papeis)))
    ) x where x.id <> auth.uid() and not x.silenciada
       and not exists (select 1 from public.chat_membros s where s.conversa_id = p_conversa and s.usuario_id = x.id and s.silenciada)
    limit 300
  loop
    perform privado.enviar_push(v_m, jsonb_build_object('tipo', 'chat', 'conversa_id', p_conversa::text, 'mensagem_id', v_id::text,
      'titulo', case when c.tipo = 'direta' then v_nome else coalesce(c.nome, 'Chat') end,
      'texto', case when c.tipo = 'direta' then v_previa else v_nome || ': ' || v_previa end));
  end loop;
  -- cliente escrevendo fora do horário: resposta automática (no máximo uma por hora)
  if c.tipo = 'empresa' and privado.minha_empresa() = c.empresa_id and privado.chat_fora_do_horario(c.organizacao_id)
     and not exists (select 1 from public.chat_mensagens a where a.conversa_id = p_conversa and a.automatica and a.criada_em > now() - interval '1 hour') then
    insert into public.chat_mensagens (conversa_id, autor_id, texto, automatica)
    values (p_conversa, null, privado.cfg_org_txt(c.organizacao_id, 'chat_resposta_auto', 'Recebemos sua mensagem e respondemos assim que voltarmos.'), true);
  end if;
  return v_id;
end;
$$;

-- ===================================================================== reagir, editar, buscar, exportar
create or replace function public.chat_reagir(p_mensagem uuid, p_emoji text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare m public.chat_mensagens%rowtype; v jsonb; v_lista jsonb; v_eu text := auth.uid()::text;
begin
  select * into m from public.chat_mensagens where id = p_mensagem for update;
  if not found or not public.chat_participo(m.conversa_id) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if not privado.cfg_bool('chat_reacoes', true) then raise exception 'reacoes_desligadas' using errcode = '42501'; end if;
  if p_emoji is null or char_length(p_emoji) > 16 or p_emoji = '' then raise exception 'emoji_invalido' using errcode = '22023'; end if;
  v := coalesce(m.reacoes, '{}'::jsonb);
  v_lista := coalesce(v -> p_emoji, '[]'::jsonb);
  -- de novo no mesmo emoji: tira
  if v_lista ? v_eu then v_lista := v_lista - v_eu; else v_lista := v_lista || to_jsonb(v_eu); end if;
  v := case when jsonb_array_length(v_lista) = 0 then v - p_emoji else jsonb_set(v, array[p_emoji], v_lista) end;
  if (select count(*) from jsonb_object_keys(v)) > 12 then raise exception 'reacoes_demais' using errcode = '22023'; end if;
  update public.chat_mensagens set reacoes = v where id = p_mensagem;
  return v;
end;
$$;

create or replace function public.chat_editar(p_mensagem uuid, p_texto text)
returns void language plpgsql security definer set search_path = '' as $$
declare m public.chat_mensagens%rowtype; v_txt text := nullif(left(trim(coalesce(p_texto, '')), 4000), '');
begin
  select * into m from public.chat_mensagens where id = p_mensagem for update;
  if not found or m.autor_id is distinct from auth.uid() or m.apagada_em is not null then raise exception 'sem_permissao' using errcode = '42501'; end if;
  if m.criada_em < now() - make_interval(mins => greatest(privado.cfg_num('chat_editar_min', 15), 0)::int) then raise exception 'tempo_de_editar_passou' using errcode = '42501'; end if;
  if v_txt is null then raise exception 'mensagem_vazia' using errcode = '22023'; end if;
  if exists (select 1 from public.chat_conversas c where c.id = m.conversa_id and c.arquivada_em is not null) then raise exception 'conversa_arquivada' using errcode = '42501'; end if;
  update public.chat_mensagens set texto = v_txt, editada_em = now() where id = p_mensagem;
end;
$$;

create or replace function public.chat_buscar(p_conversa uuid, p_busca text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'texto', g.texto, 'criada_em', g.criada_em, 'autor', public.nome_publico(g.autor_id)) order by g.criada_em desc), '[]')
    from (select * from public.chat_mensagens g
           where g.conversa_id = p_conversa and public.chat_sou_membro(p_conversa) and g.apagada_em is null
             and char_length(trim(coalesce(p_busca, ''))) >= 2 and g.texto ilike '%' || trim(p_busca) || '%'
           order by g.criada_em desc limit 60) g;
$$;

create or replace function public.chat_exportar(p_conversa uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare c public.chat_conversas%rowtype;
begin
  select * into c from public.chat_conversas where id = p_conversa;
  if not found or not public.chat_sou_membro(p_conversa) or not (public.is_gestor() or public.is_dev()) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  return jsonb_build_object('conversa', coalesce(c.nome, c.tipo), 'tipo', c.tipo, 'exportada_em', now(),
    'mensagens', (select coalesce(jsonb_agg(jsonb_build_object('quando', g.criada_em, 'autor', coalesce(public.nome_publico(g.autor_id), 'Resposta automática'),
                    'texto', g.texto, 'anexo', g.anexo ->> 'tipo', 'apagada', g.apagada_em is not null, 'editada', g.editada_em is not null) order by g.criada_em), '[]')
                   from public.chat_mensagens g where g.conversa_id = p_conversa));
end;
$$;

-- ===================================================================== membros e opções do grupo
create or replace function public.chat_membros_de(p_conversa uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'nome', public.nome_publico(p.id), 'foto', public.foto_publica(p.id), 'admin', m.admin,
           'papeis', case when public.dev_oculto_para_mim(p.id) then '["dev"]'::jsonb else to_jsonb(p.papeis) end, 'lida_em', m.lida_em) order by m.admin desc, public.nome_publico(p.id)), '[]')
    from public.chat_membros m join public.perfis p on p.id = m.usuario_id
   where m.conversa_id = p_conversa and public.chat_sou_membro(p_conversa);
$$;

create or replace function privado.chat_pode_gerenciar(p_conversa uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.is_dev()
      or exists (select 1 from public.chat_conversas c where c.id = p_conversa and c.tipo in ('grupo', 'corrida') and (
           c.criada_por = auth.uid()
        or exists (select 1 from public.chat_membros m where m.conversa_id = c.id and m.usuario_id = auth.uid() and m.admin)
        or (public.is_gestor() and public.ve_org(c.organizacao_id) and privado.cfg_org_bool(c.organizacao_id, 'chat_gestor_gerencia_grupos', true))));
$$;

create or replace function public.chat_grupo(p_conversa uuid, p_acao text, p_usuario uuid default null, p_nome text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare c public.chat_conversas%rowtype;
begin
  select * into c from public.chat_conversas where id = p_conversa;
  if not found then raise exception 'conversa_nao_encontrada' using errcode = '22023'; end if;
  if p_acao = 'sair' then
    delete from public.chat_membros where conversa_id = p_conversa and usuario_id = auth.uid();
    return '{}'::jsonb;
  end if;
  if not privado.chat_pode_gerenciar(p_conversa) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  case p_acao
    when 'adicionar' then
      if not exists (select 1 from public.perfis p where p.id = p_usuario and (public.ve_org(p.organizacao_id) or public.is_dev())) then raise exception 'sem_permissao' using errcode = '42501'; end if;
      insert into public.chat_membros (conversa_id, usuario_id, lida_em) values (p_conversa, p_usuario, now() - interval '1 day') on conflict do nothing;
    when 'remover' then delete from public.chat_membros where conversa_id = p_conversa and usuario_id = p_usuario;
    when 'admin' then update public.chat_membros set admin = not admin where conversa_id = p_conversa and usuario_id = p_usuario;
    when 'renomear' then update public.chat_conversas set nome = nullif(left(trim(coalesce(p_nome, '')), 60), '') where id = p_conversa and tipo in ('grupo', 'corrida');
    when 'apagar' then
      if not (public.is_dev() or c.criada_por = auth.uid() or public.is_gestor_pleno()) then raise exception 'sem_permissao' using errcode = '42501'; end if;
      delete from public.chat_conversas where id = p_conversa and tipo in ('grupo', 'corrida', 'direta', 'empresa');
    else raise exception 'acao_invalida' using errcode = '22023';
  end case;
  return public.chat_membros_de(p_conversa);
end;
$$;

-- ===================================================================== grupo da corrida (motoboy + clientes da rota + gestores)
create or replace function privado.chat_da_corrida()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_id uuid; v_cli boolean;
begin
  -- terminou: vai para o histórico (só leitura)
  if new.status::text in ('concluida', 'cancelada') and old.status::text not in ('concluida', 'cancelada') then
    update public.chat_conversas set arquivada_em = now() where tipo = 'corrida' and corrida_id = new.id and arquivada_em is null;
    return new;
  end if;
  if new.motoboy_id is null or new.status::text not in ('aceita', 'em_andamento') then return new; end if;
  if old.motoboy_id is not distinct from new.motoboy_id and old.status::text in ('aceita', 'em_andamento') then return new; end if;
  if not privado.cfg_org_bool(new.organizacao_id, 'chat_corrida_ligado', true) or not privado.cfg_bool('chat_ligado', true) then return new; end if;
  insert into public.chat_conversas (tipo, nome, organizacao_id, corrida_id, criada_por)
  values ('corrida', 'Rota ' || case when new.teste then 'T' else '#' end || new.numero, new.organizacao_id, new.id, new.motoboy_id)
  on conflict do nothing;
  select id into v_id from public.chat_conversas where tipo = 'corrida' and corrida_id = new.id;
  update public.chat_conversas set arquivada_em = null where id = v_id;
  -- motoboy trocou: sai o antigo, entra o novo
  if old.motoboy_id is not null and old.motoboy_id is distinct from new.motoboy_id then
    delete from public.chat_membros where conversa_id = v_id and usuario_id = old.motoboy_id;
  end if;
  insert into public.chat_membros (conversa_id, usuario_id, lida_em) values (v_id, new.motoboy_id, now()) on conflict do nothing;
  -- quem pediu (clientes das paradas), se o gestor deixar cliente falar com o motoboy
  v_cli := privado.cfg_org_bool(new.organizacao_id, 'chat_cliente_motoboy', true);
  if v_cli then
    insert into public.chat_membros (conversa_id, usuario_id, lida_em)
    select distinct v_id, p.id, now() - interval '1 minute' from public.perfis p
     where 'cliente' = any (p.papeis) and p.empresa_id in (
       select pd.empresa_id from public.paradas pa join public.pedidos pd on pd.id = pa.pedido_id where pa.corrida_id = new.id
       union select new.empresa_id)
    on conflict do nothing;
  end if;
  return new;
exception when others then
  raise warning 'chat_da_corrida: %', sqlerrm;
  return new;
end;
$$;
drop trigger if exists corridas_chat on public.corridas;
create trigger corridas_chat after update of status, motoboy_id on public.corridas for each row execute function privado.chat_da_corrida();

-- o grupo da corrida aparece para os gestores da empresa (sem precisar ser membro)

-- ===================================================================== lista de conversas: tipo novo, arquivada, cliente da caixa

create or replace function public.chat_conversas()
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(x order by (x ->> 'ultima_em') desc), '[]'::jsonb) from (
    select jsonb_build_object(
      'id', c.id, 'tipo', c.tipo, 'corrida_id', c.corrida_id, 'empresa_id', c.empresa_id, 'arquivada', c.arquivada_em is not null, 'ultima_em', c.ultima_em, 'ultima_previa', c.ultima_previa, 'ultima_minha', c.ultima_autor = auth.uid(),
      'silenciada', coalesce(eu.silenciada, false),
      'nome', case when c.tipo = 'direta' then (select public.nome_publico(p.id) from public.chat_membros m join public.perfis p on p.id = m.usuario_id
                                                 where m.conversa_id = c.id and m.usuario_id <> auth.uid() limit 1) else c.nome end,
      'foto', case when c.tipo = 'direta' then (select public.foto_publica(p.id) from public.chat_membros m join public.perfis p on p.id = m.usuario_id
                                                 where m.conversa_id = c.id and m.usuario_id <> auth.uid() limit 1) end,
      'outro', case when c.tipo = 'direta' then (select m.usuario_id from public.chat_membros m where m.conversa_id = c.id and m.usuario_id <> auth.uid() limit 1) end,
      'oculto', case when c.tipo = 'direta' then (select public.dev_oculto_para_mim(m.usuario_id) from public.chat_membros m where m.conversa_id = c.id and m.usuario_id <> auth.uid() limit 1) end,
      'papeis', case when c.tipo = 'direta' then (select to_jsonb(p.papeis) from public.chat_membros m join public.perfis p on p.id = m.usuario_id where m.conversa_id = c.id and m.usuario_id <> auth.uid() limit 1) end,
      'membros', (select count(*) from public.chat_membros m where m.conversa_id = c.id),
      'nao_lidas', (select count(*) from public.chat_mensagens g where g.conversa_id = c.id and g.autor_id is distinct from auth.uid() and g.apagada_em is null
                     and g.criada_em > coalesce(eu.lida_em, case when c.tipo = 'geral' then now() - interval '1 day' else '-infinity' end))
    ) x
      from public.chat_conversas c
      left join public.chat_membros eu on eu.conversa_id = c.id and eu.usuario_id = auth.uid()
     where privado.cfg_bool('chat_ligado', true) and public.chat_participo(c.id)
  ) t;
$$;

-- ===================================================================== guardar por quanto tempo (Dev)
create or replace function privado.chat_limpar()
returns void language plpgsql security definer set search_path = '' as $$
declare v_dias int := privado.cfg_num('dev_chat_retencao_dias', 0)::int; v_audio int := privado.cfg_num('dev_chat_audio_dias', 30)::int;
begin
  if v_dias > 0 then delete from public.chat_mensagens where criada_em < now() - make_interval(days => v_dias); end if;
  if v_audio > 0 then
    update public.chat_mensagens set anexo = jsonb_build_object('tipo', 'audio', 'expirado', true, 'duracao', anexo -> 'duracao')
     where anexo ->> 'tipo' = 'audio' and not coalesce((anexo ->> 'expirado')::boolean, false) and criada_em < now() - make_interval(days => v_audio);
  end if;
end;
$$;
revoke execute on function privado.chat_limpar(), privado.chat_da_corrida(), privado.chat_pode_gerenciar(uuid), privado.chat_fora_do_horario(uuid) from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'cron') and exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'cron' and p.proname = 'schedule') then
    perform cron.schedule('pwex-chat-limpar', '17 4 * * *', 'select privado.chat_limpar()');
  end if;
exception when others then null;
end $$;

revoke execute on function public.chat_enviar(uuid, text, jsonb, uuid), public.chat_reagir(uuid, text), public.chat_editar(uuid, text), public.chat_buscar(uuid, text),
  public.chat_exportar(uuid), public.chat_membros_de(uuid), public.chat_grupo(uuid, text, uuid, text), public.chat_caixa_empresa(uuid) from public, anon;
grant execute on function public.chat_enviar(uuid, text, jsonb, uuid), public.chat_reagir(uuid, text), public.chat_editar(uuid, text), public.chat_buscar(uuid, text),
  public.chat_exportar(uuid), public.chat_membros_de(uuid), public.chat_grupo(uuid, text, uuid, text), public.chat_caixa_empresa(uuid) to authenticated;

create or replace function public.chat_participo(p_conversa uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.chat_membros m where m.conversa_id = p_conversa and m.usuario_id = auth.uid())
      or exists (select 1 from public.chat_conversas c where c.id = p_conversa and (
            (c.tipo = 'empresa' and (c.empresa_id = privado.minha_empresa() or (public.is_gestor() and public.ve_org(c.organizacao_id) and public.pode('chat'))))
         or (c.tipo = 'corrida' and public.is_gestor() and public.ve_org(c.organizacao_id))))
      or (public.chat_equipe() and privado.cfg_bool('chat_geral', true) and exists (
            select 1 from public.chat_conversas c where c.id = p_conversa and c.tipo = 'geral'
               and c.organizacao_id is not distinct from (select case when 'dev' = any (p.papeis) then p.org_em_foco else p.organizacao_id end
                                                           from public.perfis p where p.id = auth.uid())));
$$;
