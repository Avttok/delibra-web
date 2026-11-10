# Delibra · site

Um site só para tudo que não é o app do motoboy:

| Endereço | Para quem |
|---|---|
| `/` | Apresentação da Delibra; quem já entrou como cliente vê o painel de pedidos |
| `/entrar` | Área do cliente (pedidos, acompanhamento, faturas, chat) |
| `/gestor/...` | Painel do gestor e do supervisor (mapa, pedidos, rotas, clientes, equipe, chat, ajustes) |
| `/gestor/dev` | Console do Dev: empresas, faturamento da plataforma, conversas, módulos, versão do app |
| `/app` | Baixar o app do motoboy |
| `/ajuda`, `/suporte` | Central de ajuda (equipe / clientes) |

## Plataforma multiempresa

Cada **empresa** (transportadora) tem a própria equipe, clientes, pedidos, rotas, chat e ajustes.
O banco isola uma empresa da outra (regras restritivas no Supabase). Hierarquia:
**Dev** (plataforma) → **Gestor** (dono da empresa) → **Supervisor** (líder de equipe, com permissões) → **Motoboy** / **Cliente**.

## Configurar do zero

1. **Supabase**: crie o projeto. Em *Database → Extensions*, ligue `postgis`, `pg_cron` e `pg_net`.
2. **GitHub → Settings → Secrets and variables → Actions**: crie o segredo `SUPABASE_DB_URL` com a
   *Connection string* (Project Settings → Database → Session pooler → URI), já com a senha do banco.
   Esse segredo fica só no GitHub.
3. **Actions → "Migrar banco (Supabase)" → Run workflow**: aplica todas as migrações, em ordem.
   Depois disso, toda migração nova enviada para a `main` roda sozinha.
4. **Vercel**: importe este repositório e configure as variáveis:
   - `NEXT_PUBLIC_SUPABASE_URL` e `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` (públicas)
   - `SUPABASE_SECRET_KEY` (Project Settings → API Keys → Secret key) — **só na Vercel**
   - `PUSH_SECRET`: rode `select valor from privado.config where chave = 'push_secret';` no SQL Editor e copie
   - `FIREBASE_SERVICE_ACCOUNT` (JSON da conta de serviço do Firebase) — **só na Vercel**
5. Crie a conta master **dev@delibra.com** (Supabase → Authentication → Add user, ou pelo site):
   ela já nasce Dev. Rode o workflow de novo com `site_url` = endereço da Vercel (para os avisos push).
6. No **Dev → Empresas**, crie a primeira empresa e escolha o gestor dela.

Nunca coloque a secret key, a senha do banco ou a conta de serviço do Firebase no código ou no chat.
