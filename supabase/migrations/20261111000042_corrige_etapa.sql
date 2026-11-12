-- Delibra · 0042: corrige "cheguei"/"concluir" (a marca de etapa sem internet ficava vazia e travava a etapa)
set check_function_bodies = off;

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
  v_ex       jsonb;
begin
  -- outra empresa: recusa
  if p_parada is not null and not public.ve_corrida((select tv_par.corrida_id from public.paradas tv_par where tv_par.id = p_parada)) then raise exception 'sem_permissao' using errcode = '42501'; end if;
  perform privado.checar_versao_app();
  select * into p from public.paradas where id = p_parada for update;
  if not found then raise exception 'parada_nao_encontrada' using errcode = '22023'; end if;
  select * into c from public.corridas where id = p.corrida_id for update;
  -- etapa feita sem internet chegando depois que a corrida fechou sozinha: só completa os dados
  if p.confirmacao_pendente and c.motoboy_id = auth.uid() and p_acao = 'concluir' then
    update public.paradas set confirmacao_pendente = false, feita_offline = true,
           concluida_em = coalesce(privado.quando_offline(v_dados), concluida_em),
           recebedor_nome = coalesce(nullif(trim(v_dados ->> 'recebedor_nome'), ''), recebedor_nome),
           foto_path = coalesce(nullif(v_dados ->> 'foto_path', ''), foto_path),
           assinatura_path = coalesce(nullif(v_dados ->> 'assinatura_path', ''), assinatura_path)
     where id = p.id;
    if not exists (select 1 from public.paradas where corrida_id = c.id and confirmacao_pendente) then
      update public.corridas set aguardando_confirmacao = false where id = c.id;
      perform privado.evento(c.id, 'confirmada_offline');
    end if;
    return privado.corrida_json(c.id);
  end if;
  if p.confirmacao_pendente and c.motoboy_id = auth.uid() then return privado.corrida_json(c.id); end if;
  if c.motoboy_id is distinct from auth.uid() or c.status not in ('aceita', 'em_andamento') then
    raise exception 'corrida_nao_esta_ativa' using errcode = '22023';
  end if;
  if p_acao not in ('chegou', 'concluir') then raise exception 'acao_invalida' using errcode = '22023'; end if;

  select min(ordem) into v_atual from public.paradas where corrida_id = c.id and status <> 'concluida';
  if p.ordem <> v_atual then raise exception 'conclua_a_parada_anterior' using errcode = '22023'; end if;

  -- presença no local
  select d.distancia_m, d.tolerancia_m into v_dist, v_tol from privado.distancia_ate_parada(p, v_dados, auth.uid()) d;
  if c.exigir_no_local then
    v_ignorar := (coalesce((v_dados ->> 'ignorar_local')::boolean, false)
                  and c.teste and public.is_gestor()
                  and privado.cfg_bool('teste_admin_ignora_local', true))
                 -- o gestor liberou esta parada (pular o raio)
                 or p.liberada_local
                 -- o gestor deu ao motoboy a liberdade de pular
                 or (coalesce((v_dados ->> 'ignorar_local')::boolean, false) and privado.cfg_bool('saas_pular_parada', true)
                     and privado.pol_bool('motoboy_pode_pular', false, c.empresa_id, auth.uid(), c.tipo_pedido));
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
       set status = 'chegou', chegou_em = coalesce(privado.quando_offline(v_dados), now()), feita_offline = feita_offline or coalesce(v_dados ->> 'offline' = 'true', false),
           distancia_chegada_m = round(v_dist), local_ignorado = v_ignorar
     where id = p.id;
    perform privado.evento(c.id, 'chegou', jsonb_build_object(
      'parada', p.ordem, 'tipo', p.tipo, 'distancia_m', round(v_dist), 'local_ignorado', v_ignorar));
    return privado.corrida_json(c.id);
  end if;

  -- concluir: o que esta parada exige (o que o cliente pediu no ponto, ou o padrão da rota nas entregas)
  v_ex := privado.exige_parada(p, c);
  if (v_ex ->> 'nome')::boolean and coalesce(trim(v_dados ->> 'recebedor_nome'), '') = '' then
    raise exception 'informe_o_nome_de_quem_recebeu' using errcode = '22023';
  end if;
  if (v_ex ->> 'codigo')::boolean and coalesce(v_dados ->> 'codigo', '') <> coalesce(p.codigo, c.codigo_entrega, '') then
    raise exception 'codigo_incorreto' using errcode = '22023';
  end if;
  if (v_ex ->> 'foto')::boolean and coalesce(v_dados ->> 'foto_path', '') = '' then
    raise exception 'falta_a_foto' using errcode = '22023';
  end if;
  if (v_ex ->> 'assinatura')::boolean and coalesce(v_dados ->> 'assinatura_path', '') = '' then
    raise exception 'falta_a_assinatura' using errcode = '22023';
  end if;

  update public.paradas
     set status = 'concluida',
         chegou_em = coalesce(chegou_em, privado.quando_offline(v_dados), now()),
         concluida_em = coalesce(privado.quando_offline(v_dados), now()),
         feita_offline = feita_offline or coalesce(v_dados ->> 'offline' = 'true', false),
         distancia_chegada_m = coalesce(distancia_chegada_m, round(v_dist)),
         local_ignorado = local_ignorado or v_ignorar,
         recebedor_nome = nullif(trim(v_dados ->> 'recebedor_nome'), ''),
         foto_path = nullif(v_dados ->> 'foto_path', ''),
         assinatura_path = nullif(v_dados ->> 'assinatura_path', '')
   where id = p.id;
  -- pedido de pular esta parada que ficou aberto: não precisa mais
  update public.chamados_corrida set status = 'retirado', respondido_em = now() where corrida_id = c.id and tipo = 'pular' and parada_id = p.id and status = 'pendente';
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
