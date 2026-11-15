#!/usr/bin/env bash
# DNEX Folha — Replay completo das migrations + testes pgTAP.
# Uso: tests/ci/replay.sh
# Variáveis de ambiente: PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE
# Falha imediatamente se qualquer migration ou teste falhar.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PSQL="psql -v ON_ERROR_STOP=1 --no-psqlrc -q"
PG_PROVE="pg_prove"

echo "==> Aplicando bootstrap..."
${PSQL} -f "${SCRIPT_DIR}/bootstrap.sql"

echo "==> Aplicando migrations em ordem..."
for migration in "${REPO_ROOT}"/migrations/supabase/[0-9]*.supabase.sql; do
  # Pula arquivos .down.sql
  case "${migration}" in
    *.down.sql) continue ;;
  esac
  echo " -> $(basename "${migration}")"
  ${PSQL} -f "${migration}"
done

echo "==> Executando testes pgTAP..."
FAILED=0
for test_file in "${REPO_ROOT}"/tests/folha/*.pgtap.sql; do
  echo " -> $(basename "${test_file}")"
  if ! ${PG_PROVE} -d "${PGDATABASE:-postgres}" "${test_file}"; then
    FAILED=$((FAILED + 1))
  fi
done

if [ "${FAILED}" -gt 0 ]; then
  echo "ERRO: ${FAILED} arquivo(s) de teste falharam."
  exit 1
fi

echo "==> Todas as migrations aplicadas e testes passaram."