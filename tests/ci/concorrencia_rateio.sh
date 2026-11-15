#!/usr/bin/env bash
# DNEX Folha — corrida real no rateio do contrato (migration 0024), com duas conexões.
#
# Cenário: o contrato não tem rateio. Duas transações gravam, ao mesmo tempo, 100% cada
# uma em uma LOTAÇÃO DIFERENTE do mesmo contrato. Cada uma, sozinha, soma 100. Sem
# serialização por contrato as duas passam e o contrato fica com 200%.
# Esperado: exatamente uma confirma; a outra falha com 23514 (READ COMMITTED) ou 40001
# (REPEATABLE READ); o contrato termina com 100.
#
# Roda depois das migrations, no banco de CI. Usa a conta fictícia c0ffee00-... e apaga
# o que gravou. Variáveis: PGHOST, PGPORT, PGUSER, PGPASSWORD, PGDATABASE.
set -euo pipefail

PSQL="psql -v ON_ERROR_STOP=1 --no-psqlrc -q -X -At"
CONTA='c0ffee00-0000-0000-0000-000000000001'
EMP='c0ffee00-0000-0000-0000-0000000000e1'
EST='c0ffee00-0000-0000-0000-0000000000f1'
L1='c0ffee00-0000-0000-0000-0000000000a1'
L2='c0ffee00-0000-0000-0000-0000000000a2'
TRAB='c0ffee00-0000-0000-0000-0000000000c1'
CONTRATO='c0ffee00-0000-0000-0000-0000000000d1'
TMP="$(mktemp -d)"

limpa() {
  ${PSQL} >/dev/null <<SQL
BEGIN;
DELETE FROM folha.contract_tax_allocation WHERE account_id = '${CONTA}';
DELETE FROM folha.tax_allocation WHERE account_id = '${CONTA}';
DELETE FROM folha.employment_contract WHERE account_id = '${CONTA}';
DELETE FROM folha.employee WHERE account_id = '${CONTA}';
DELETE FROM folha.establishment WHERE account_id = '${CONTA}';
DELETE FROM folha.employer WHERE account_id = '${CONTA}';
COMMIT;
SQL
}
trap 'limpa || true; rm -rf "${TMP}"' EXIT

prepara() {
  limpa
  ${PSQL} >/dev/null <<SQL
BEGIN;
INSERT INTO folha.employer (employer_id, account_id, tipo_inscricao, inscricao, razao_social)
VALUES ('${EMP}', '${CONTA}', 'cnpj', '99999999', 'Empresa Concorrencia');
INSERT INTO folha.establishment (establishment_id, account_id, employer_id, tipo_inscricao, inscricao, cnae_preponderante)
VALUES ('${EST}', '${CONTA}', '${EMP}', 'cnpj', '99999999000199', '0000000');
INSERT INTO folha.tax_allocation (allocation_id, account_id, employer_id, establishment_id, codigo_lotacao, tipo_lotacao) VALUES
  ('${L1}', '${CONTA}', '${EMP}', '${EST}', 'C1', 'teste'),
  ('${L2}', '${CONTA}', '${EMP}', '${EST}', 'C2', 'teste');
INSERT INTO folha.employee (employee_id, account_id, cpf, nome_completo, data_nascimento)
VALUES ('${TRAB}', '${CONTA}', '99999999999', 'Ficticio Concorrencia', '1990-01-01');
INSERT INTO folha.employment_contract (contract_id, account_id, employee_id, data_admissao, cargo, salario_base, regime_trabalho, employer_id, establishment_id)
VALUES ('${CONTRATO}', '${CONTA}', '${TRAB}', '2026-01-01', 'Teste', 1000.00, 'clt', '${EMP}', '${EST}');
COMMIT;
SQL
}

# Uma transação: grava 100% na lotação $1, segura $2 segundos aberta e confirma.
# Imprime o SQLSTATE ('00000' = confirmou).
transacao() {
  local lotacao="$1" espera="$2" isolamento="$3" saida="$4"
  psql --no-psqlrc -q -X -At -v VERBOSITY=sqlstate >/dev/null 2>"${saida}.err" <<SQL || true
BEGIN ISOLATION LEVEL ${isolamento};
INSERT INTO folha.contract_tax_allocation (account_id, employer_id, contract_id, allocation_id, percentual, vigencia_inicio)
VALUES ('${CONTA}', '${EMP}', '${CONTRATO}', '${lotacao}', 100, '2026-01-01');
SELECT pg_sleep(${espera});
COMMIT;
SQL
  if [ -s "${saida}.err" ]; then
    grep -oE '(ERROR|ERRO):[[:space:]]+[0-9A-Z]{5}' "${saida}.err" | head -1 | grep -oE '[0-9A-Z]{5}$' > "${saida}" || echo 'XXXXX' > "${saida}"
  else
    echo '00000' > "${saida}"
  fi
}

rodada() {
  local isolamento="$1" esperado_falha="$2"
  prepara
  transacao "${L1}" 2 "${isolamento}" "${TMP}/a" &
  sleep 0.5
  transacao "${L2}" 0 "${isolamento}" "${TMP}/b" &
  wait
  local a b soma
  a="$(cat "${TMP}/a")"; b="$(cat "${TMP}/b")"
  soma="$(${PSQL} -c "SELECT COALESCE(sum(percentual), 0)::int FROM folha.contract_tax_allocation WHERE contract_id = '${CONTRATO}'")"
  echo "    ${isolamento}: transacao A=${a} transacao B=${b} soma final=${soma}"
  if [ "${soma}" != "100" ]; then
    echo "ERRO: o contrato terminou com soma ${soma} (esperado 100)"; return 1
  fi
  if ! { [ "${a}" = "00000" ] && [ "${b}" = "${esperado_falha}" ]; } \
     && ! { [ "${b}" = "00000" ] && [ "${a}" = "${esperado_falha}" ]; }; then
    echo "ERRO: esperado uma transacao confirmada (00000) e a outra recusada com ${esperado_falha}"; return 1
  fi
}

echo " -> concorrencia_rateio.sh"
rodada "READ COMMITTED" "23514"
rodada "REPEATABLE READ" "40001"
echo "    ok: duas transacoes concorrentes nao deixam o contrato com 200%"
