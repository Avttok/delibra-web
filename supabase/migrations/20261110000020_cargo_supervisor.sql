-- =====================================================================
-- PW Express · 0020 (parte 1 de 2): cargo Supervisor (líder de equipe)
-- Rode ANTES de 20261110000021_organizacoes_saas.sql.
-- (O Postgres não deixa usar um valor novo de enum na mesma transação em
--  que ele foi criado, por isso este arquivo fica separado.)
-- =====================================================================
alter type public.papel_usuario add value if not exists 'supervisor';
