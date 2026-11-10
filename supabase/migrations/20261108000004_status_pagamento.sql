-- =====================================================================
-- PW Express · 0012 (parte 1 de 2): status "aguardando_pagamento"
-- Rode SOZINHO primeiro; depois 20261108000005_clientes_carteira.sql.
-- =====================================================================
alter type public.status_corrida add value if not exists 'aguardando_pagamento';
