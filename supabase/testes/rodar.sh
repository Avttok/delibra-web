#!/bin/bash
# Teste antes de publicar: monta um banco vazio, aplica TODAS as migrações e roda o fluxo principal.
# Uso: PGHOST=… PGUSER=… PGPASSWORD=… bash supabase/testes/rodar.sh   (banco de teste descartável, nunca o de produção)
set -uo pipefail
cd "$(dirname "$0")"
DB=delibra_teste
psql -q -d postgres -c "drop database if exists $DB" -c "create database $DB" >/dev/null || exit 1
psql -q -d $DB -f stub.sql >/dev/null 2>&1
falhou=0
for f in ../migrations/*.sql; do
  # sem pg_cron, pg_net e PostGIS no banco de teste: o stub imita o que as migrações usam deles
  out=$(sed -e '/create extension if not exists \(pg_cron\|pg_net\|postgis\)/d' -e 's/extensions.geography(Point, 4326)/extensions.geography/' -e '/using gist/d' "$f" \
        | psql -q -d $DB -v ON_ERROR_STOP=1 2>&1 | grep -i "error" | head -3)
  if [ -n "$out" ]; then echo "::error::Migração $(basename "$f") falhou: $out"; falhou=1; fi
done
[ $falhou = 1 ] && exit 1
echo "Migrações aplicadas."

# fluxo principal (pedido, rota, pagamento, holerite, permissões…): os 12 erros são as recusas esperadas
erros=$(psql -q -d $DB -f t81.sql 2>&1 | grep -c ERROR)
if [ "$erros" != "12" ]; then echo "::error::Fluxo principal: $erros erros (esperado 12). Rode t81.sql e compare."; psql -q -d $DB -f t81.sql 2>&1 | grep -B2 ERROR | tail -40; exit 1; fi
echo "Fluxo principal ok (12 recusas esperadas)."

# API, termos e travamentos: cada linha é OK ou FALHA
psql -q -d postgres -c "drop database if exists $DB" -c "create database $DB" >/dev/null
psql -q -d $DB -f stub.sql >/dev/null 2>&1
for f in ../migrations/*.sql; do
  sed -e '/create extension if not exists \(pg_cron\|pg_net\|postgis\)/d' -e 's/extensions.geography(Point, 4326)/extensions.geography/' -e '/using gist/d' "$f" | psql -q -d $DB >/dev/null 2>&1
done
saida=$(psql -q -d $DB -f api.sql 2>&1 | grep -E "OK |FALHA")
echo "$saida" | sed 's/^.*\(OK\|FALHA\)/\1/'
ok=$(echo "$saida" | grep -c "OK ")
if echo "$saida" | grep -q FALHA || [ "$ok" -lt 12 ]; then echo "::error::Teste da API/termos/travamentos falhou ($ok de 12 ok)."; exit 1; fi

# motor de modalidades (campos, nomes, regras extras, cargos, módulos por empresa, veículo, limite da API)
psql -q -d postgres -c "drop database if exists $DB" -c "create database $DB" >/dev/null
psql -q -d $DB -f stub.sql >/dev/null 2>&1
for f in ../migrations/*.sql; do
  sed -e '/create extension if not exists \(pg_cron\|pg_net\|postgis\)/d' -e 's/extensions.geography(Point, 4326)/extensions.geography/' -e '/using gist/d' "$f" | psql -q -d $DB >/dev/null 2>&1
done
saida=$(psql -q -d $DB -f modalidades.sql 2>&1 | grep -E "OK |FALHA")
echo "$saida" | sed 's/^.*\(OK\|FALHA\)/\1/'
ok=$(echo "$saida" | grep -c "OK ")
if echo "$saida" | grep -q FALHA || [ "$ok" -lt 13 ]; then echo "::error::Teste do motor de modalidades falhou ($ok de 13 ok)."; exit 1; fi
echo "Tudo certo: pode publicar."
