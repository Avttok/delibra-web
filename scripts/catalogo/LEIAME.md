# Catálogo de ajustes: site → app

Os ajustes moram em `src/features/configuracoes/definicoes.ts`. O app tem uma cópia gerada (`Catalogo.kt`).

Depois de criar ou mudar um ajuste no site:

```bash
python3 scripts/catalogo/gerar-app.py ../delibra-app   # caminho do repositório do app
```

E registre o grupo do ajuste novo em `public.ajuste_grupos` numa migração (para as permissões do Dev valerem nele).
