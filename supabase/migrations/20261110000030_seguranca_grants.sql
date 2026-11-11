-- =====================================================================
-- Delibra · 0030: segurança antes de abrir ao público
--
-- Funções novas nascem executáveis por "anon" (visitante sem login). Todas já checam quem
-- chama, mas por garantia o visitante só pode chamar o que é público de verdade:
-- versao_app, marca_publica, cadastro_aberto (e as que as regras de acesso usam por dentro).
-- =====================================================================
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('ajustes', 'ajustes_mudados', 'chat_cartao', 'chat_participo', 'corrida_percurso_via', 'definir_marca_organizacao',
                         'definir_percurso_rota', 'definir_permissoes', 'definir_regras_rota_pedido', 'dev_apagar_conversa', 'dev_conversas',
                         'dev_definir_modo', 'dev_empresas_foco', 'dev_faturamento', 'dev_focar_org', 'dev_licencas', 'dev_mover_pessoa',
                         'dev_ocultar', 'dev_organizacoes', 'dev_salvar_organizacao', 'meu_plano', 'minha_organizacao', 'salvar_ajuste',
                         'salvar_minha_organizacao', 'voltar_ajuste', 'org_alcanca', 'nome_publico', 'foto_publica', 'pode_salvar_objetos', 'minha_org')
  loop
    execute format('revoke execute on function %s from public, anon', f.sig);
    execute format('grant execute on function %s to authenticated', f.sig);
  end loop;
end $$;

notify pgrst, 'reload schema';
