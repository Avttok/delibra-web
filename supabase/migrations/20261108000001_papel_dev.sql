-- =====================================================================
-- PW Express · 0010 (parte 1 de 2): cargo "dev"
-- Rode este arquivo SOZINHO primeiro. Depois rode 20261108000002_dev_modulos.sql.
-- (o Postgres só deixa usar um valor novo de enum depois que ele foi salvo)
-- =====================================================================
alter type public.papel_usuario add value if not exists 'dev';
