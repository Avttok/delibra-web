-- =====================================================================
-- PW Express · Renascimento (parte 1 de 2): valores novos de enum
-- Rode SOZINHA, antes de 20261109000002_renascimento.sql.
--
--  • status "montada": rota criada pelo roteirizador, esperando o gestor liberar.
--  • despacho "quadro": a rota aparece para todos os motoboys e o primeiro que pegar leva.
--  • despacho "melhor_primeiro": fica alguns segundos só para o melhor motoboy e depois vai ao quadro.
-- =====================================================================
alter type public.status_corrida add value if not exists 'montada';
alter type public.modo_despacho add value if not exists 'quadro';
alter type public.modo_despacho add value if not exists 'melhor_primeiro';
