-- PW Express 0017: pacotes por ponto (ícone, detalhes e os que vão para todas as entregas),
-- para o app do motoboy, o gestor e o cliente.


create or replace function privado.corrida_json_completo(p_corrida uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', c.id, 'numero', c.numero, 'status', c.status, 'origem', c.origem,
    'agendada_para', c.agendada_para, 'reservada_em', c.reservada_em,
    'cancelar_reserva_ate', case when c.agendada_para is not null
      then c.agendada_para - make_interval(mins => privado.cfg_num('agendada_cancelar_ate_min', 60)::int) end,
    'iniciar_a_partir_de', case when c.agendada_para is not null
      then c.agendada_para - make_interval(mins => privado.cfg_num('agendada_iniciar_antes_min', 60)::int) end,
    'teste', c.teste, 'urgente', c.urgente, 'perigoso', c.tem_perigoso,
    'valor_motoboy', coalesce(c.valor_motoboy, (privado.calcular_pagamento(c.id, auth.uid()) ->> 'total')::numeric),
    'distancia_planejada_m', c.distancia_planejada_m, 'duracao_planejada_s', c.duracao_planejada_s,
    'observacoes', c.observacoes, 'exige_foto', c.exige_foto, 'exige_assinatura', c.exige_assinatura,
    'exige_nome', c.exige_nome, 'exige_codigo', c.exige_codigo, 'exigir_no_local', c.exigir_no_local,
    'raio_chegada_m', c.raio_chegada_m, 'rota_planejada', c.rota_planejada,
    'empresa_nome', coalesce(e.nome, c.cliente_nome),
    'entregas', (select count(*) from public.paradas p where p.corrida_id = c.id and p.tipo = 'entrega'),
    'coletas', (select count(*) from public.paradas p where p.corrida_id = c.id and p.tipo = 'coleta'),
    'paradas', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id, 'ordem', p.ordem, 'tipo', p.tipo, 'endereco', p.endereco,
        'lat', p.lat, 'lng', p.lng, 'contato_nome', p.contato_nome,
        'contato_telefone', p.contato_telefone, 'instrucoes', p.instrucoes, 'status', p.status,
        'referencias', p.referencias,
        'exige', privado.exige_parada(p, c), 'janela_de', to_char(p.janela_de, 'HH24:MI'), 'janela_ate', to_char(p.janela_ate, 'HH24:MI'),
        'cliente', (select coalesce(em.nome, pd.cliente_nome) from public.pedidos pd left join public.empresas em on em.id = pd.empresa_id where pd.id = p.pedido_id),
        'pedido_numero', (select pd.numero from public.pedidos pd where pd.id = p.pedido_id),
        'itens', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'descricao', i.descricao, 'quantidade', i.quantidade,
                    'categoria', k.nome, 'icone', k.icone, 'perigoso', coalesce(k.perigoso, false), 'fragil', coalesce(k.fragil, false),
                    'peso_kg', i.peso_kg, 'comprimento_cm', i.comprimento_cm, 'largura_cm', i.largura_cm, 'altura_cm', i.altura_cm,
                    'valor_declarado', i.valor_declarado, 'observacoes', i.observacoes,
                    -- true = não está preso a este ponto (vai para todas as entregas / sai de qualquer coleta)
                    'todas', case when p.tipo = 'entrega' then i.entrega_id is null else i.coleta_id is null end)), '[]')
                    from public.pedido_itens i left join public.categorias_produto k on k.id = i.categoria_id
                   where p.pedido_ponto_id is not null and i.pedido_id = p.pedido_id
                     and (case when p.tipo = 'entrega' then i.entrega_id = p.pedido_ponto_id or i.entrega_id is null
                               else i.coleta_id = p.pedido_ponto_id or i.coleta_id is null end))
      ) order by p.ordem)
      from public.paradas p where p.corrida_id = c.id
    ), '[]'::jsonb)
  )
  from public.corridas c
  left join public.empresas e on e.id = c.empresa_id
  where c.id = p_corrida;
$$;

create or replace function public.meus_pedidos_cliente(p_dias int default 120)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(x order by (x ->> 'criado_em') desc), '[]'::jsonb) from (
    select jsonb_build_object(
      'id', p.id, 'numero', p.numero, 'tipo', p.tipo, 'tipo_pedido', p.tipo_pedido, 'quando', p.quando, 'urgente', p.urgente,
      'status', p.status,
      'valor', case when privado.cliente_ve_preco(p.empresa_id, p.status::text) then p.valor end,
      'orcamento', case when privado.cliente_ve_preco(p.empresa_id, p.status::text) then p.orcamento end,
      'preco_oculto', not privado.cliente_ve_preco(p.empresa_id, p.status::text), 'cobranca', p.cobranca, 'pagamento_status', p.pagamento_status,
      'pagamento_metodo', p.pagamento_metodo, 'fatura_id', p.fatura_id, 'observacoes', p.observacoes, 'recusa_motivo', p.recusa_motivo,
      'criado_em', p.criado_em, 'concluido_em', p.concluido_em, 'cancelado_em', p.cancelado_em,
      'pontos', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'tipo', x.tipo, 'endereco', x.endereco, 'lat', x.lat, 'lng', x.lng,
                                 'contato_nome', x.contato_nome, 'status', x.status, 'concluido_em', x.concluido_em, 'recebedor_nome', x.recebedor_nome,
                                 'exige_foto', x.exige_foto, 'exige_assinatura', x.exige_assinatura, 'exige_nome', x.exige_nome, 'exige_codigo', x.exige_codigo,
                                 'janela_de', to_char(x.janela_de, 'HH24:MI'), 'janela_ate', to_char(x.janela_ate, 'HH24:MI'),
                                 'codigo', (select pa.codigo from public.paradas pa join public.corridas c on c.id = pa.corrida_id
                                             where pa.pedido_ponto_id = x.id and pa.codigo is not null and c.status::text not in ('cancelada', 'concluida')
                                               and privado.pol_bool('cliente_ve_codigo', true, p.empresa_id) limit 1)) order by x.ordem)
                          from public.pedido_pontos x where x.pedido_id = p.id), '[]'),
      'itens', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'coleta_id', i.coleta_id, 'entrega_id', i.entrega_id, 'descricao', i.descricao, 'quantidade', i.quantidade, 'peso_kg', i.peso_kg,
                                'categoria', k.nome, 'categoria_id', i.categoria_id, 'icone', k.icone, 'perigoso', coalesce(k.perigoso, false),
                                'comprimento_cm', i.comprimento_cm, 'largura_cm', i.largura_cm, 'altura_cm', i.altura_cm, 'valor_declarado', i.valor_declarado))
                         from public.pedido_itens i left join public.categorias_produto k on k.id = i.categoria_id where i.pedido_id = p.id), '[]'),
      'motoboys', (select coalesce(jsonb_agg(distinct split_part(pf.nome, ' ', 1)) filter (where privado.pol_bool('cliente_ve_motoboy', true, p.empresa_id)), '[]') from public.paradas pa join public.corridas c on c.id = pa.corrida_id
                     join public.perfis pf on pf.id = c.motoboy_id where pa.pedido_id = p.id and c.status::text <> 'cancelada'),
      'codigos', (select coalesce(jsonb_agg(distinct c.codigo_entrega) filter (where c.codigo_entrega is not null and privado.pol_bool('cliente_ve_codigo', true, p.empresa_id)), '[]') from public.paradas pa
                    join public.corridas c on c.id = pa.corrida_id where pa.pedido_id = p.id and c.exige_codigo and pa.exige_codigo is not false and pa.codigo is null and c.status::text not in ('cancelada', 'concluida'))
    ) x
      from public.pedidos p
     where p.empresa_id = privado.minha_empresa() and p.teste = privado.cliente_teste()
       and p.criado_em > now() - make_interval(days => greatest(1, least(p_dias, 400)))
     limit 500
  ) t;
$$;
