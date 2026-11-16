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

echo "==> Conferindo a cópia da migration do dnex-gestao (schema gestao_folha)..."
(cd "${SCRIPT_DIR}" && sha256sum -c gestao_folha_0015_candidate.sha256)

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

roda_testes() {
  local falhas=0
  for test_file in "$@"; do
    echo " -> $(basename "${test_file}")"
    if ! ${PG_PROVE} -d "${PGDATABASE:-postgres}" "${test_file}"; then
      falhas=$((falhas + 1))
    fi
  done
  return "${falhas}"
}

echo "==> Executando testes pgTAP..."
FAILED=0
roda_testes "${REPO_ROOT}"/tests/folha/*.pgtap.sql || FAILED=$((FAILED + $?))

echo "==> Executando testes de concorrência (duas conexões)..."
if ! bash "${SCRIPT_DIR}/concorrencia_rateio.sh"; then
  FAILED=$((FAILED + 1))
fi

# Reversão e reaplicação das migrations que têm par .down.sql a partir da 0028: desfaz da
# última para a primeira, reaplica na ordem e roda de novo os testes delas. Os testes pgTAP
# não deixam dado (ROLLBACK), então as reversões não encontram linha que as impeça.
echo "==> Ciclo up -> down -> up (0028 em diante)..."
mapfile -t CICLO < <(ls "${REPO_ROOT}"/migrations/supabase/00[2-9][0-9]_*.supabase.down.sql | awk -F/ '{print $NF}' | awk '$0 >= "0028"' | sort)
for ((i = ${#CICLO[@]} - 1; i >= 0; i--)); do
  echo " <- ${CICLO[$i]}"
  ${PSQL} -f "${REPO_ROOT}/migrations/supabase/${CICLO[$i]}"
done
for down in "${CICLO[@]}"; do
  up="${down%.down.sql}.sql"
  echo " -> ${up}"
  ${PSQL} -f "${REPO_ROOT}/migrations/supabase/${up}"
done
TESTES_CICLO=()
for down in "${CICLO[@]}"; do
  for test_file in "${REPO_ROOT}/tests/folha/${down:0:4}"_*.pgtap.sql; do
    [ -e "${test_file}" ] && TESTES_CICLO+=("${test_file}")
  done
done
if [ "${#TESTES_CICLO[@]}" -gt 0 ]; then
  roda_testes "${TESTES_CICLO[@]}" || FAILED=$((FAILED + $?))
fi

if [ "${FAILED}" -gt 0 ]; then
  echo "ERRO: ${FAILED} arquivo(s) de teste falharam."
  exit 1
fi

echo "==> Todas as migrations aplicadas e testes passaram."
