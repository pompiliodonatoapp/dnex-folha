import os
#!/usr/bin/env python3
"""DNEX Folha — Executa testes de eventos de vida via Supabase Management API.
Converte asserções pgTAP em SQL puro e valida resultados localmente.
Uso: python3 tests/folha/run_eventos_vida_tests.py
"""
import json, urllib.request, ssl, sys, os

TOKEN = os.environ.get("SUPABASE_SERVICE_KEY", "")
PROJECT = "fxhphmuymkltukkkieky"
URL = f"https://api.supabase.com/v1/projects/{PROJECT}/database/query"

def run_sql(query: str) -> list:
    payload = json.dumps({"query": query}).encode("utf-8")
    req = urllib.request.Request(URL, data=payload, headers={
        "Authorization": f"Bearer {TOKEN}",
        "Content-Type": "application/json",
    }, method="POST")
    ctx = ssl.create_default_context()
    try:
        resp = urllib.request.urlopen(req, context=ctx)
        return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8")
        print(f"SQL ERROR: {body}", file=sys.stderr)
        raise

# Setup: inserir dados de teste
print("=== SETUP: Inserindo dados de teste ===")
setup_sql = """
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM folha.employee WHERE account_id = 'e0000000-0000-0000-0000-000000000005' AND cpf = '55555555555') THEN
    INSERT INTO folha.employee (account_id, cpf, nome_completo, data_nascimento)
    VALUES ('e0000000-0000-0000-0000-000000000005', '55555555555', 'Teste Eventos Vida Senior', '1985-06-15');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM folha.employee WHERE account_id = 'e0000000-0000-0000-0000-000000000005' AND cpf = '66666666666') THEN
    INSERT INTO folha.employee (account_id, cpf, nome_completo, data_nascimento)
    VALUES ('e0000000-0000-0000-0000-000000000005', '66666666666', 'Teste Eventos Vida Junior', '1995-03-20');
  END IF;
END
$$;

INSERT INTO folha.employment_contract (account_id, employee_id, data_admissao, cargo, salario_base, regime_trabalho)
SELECT 'e0000000-0000-0000-0000-000000000005', employee_id, '2024-01-15', 'Senior Tester', 4500.00, 'clt'
FROM folha.employee WHERE account_id = 'e0000000-0000-0000-0000-000000000005' AND cpf = '55555555555'
ON CONFLICT DO NOTHING;

INSERT INTO folha.employment_contract (account_id, employee_id, data_admissao, cargo, salario_base, regime_trabalho)
SELECT 'e0000000-0000-0000-0000-000000000005', employee_id, '2026-04-01', 'Junior Tester', 2500.00, 'clt'
FROM folha.employee WHERE account_id = 'e0000000-0000-0000-0000-000000000005' AND cpf = '66666666666'
ON CONFLICT DO NOTHING;
"""
run_sql(setup_sql)
print("OK: Dados de teste inseridos")

# Obter contract_ids
senior_cid = run_sql("SELECT contract_id::text AS cid FROM folha.employment_contract WHERE account_id = 'e0000000-0000-0000-0000-000000000005' AND cargo = 'Senior Tester' LIMIT 1")[0]["cid"]
junior_cid = run_sql("SELECT contract_id::text AS cid FROM folha.employment_contract WHERE account_id = 'e0000000-0000-0000-0000-000000000005' AND cargo = 'Junior Tester' LIMIT 1")[0]["cid"]
print(f"OK: senior_cid={senior_cid}, junior_cid={junior_cid}")

passed = 0
failed = 0
errors = []

def check(name: str, condition: bool):
    global passed, failed
    if condition:
        passed += 1
        print(f"  PASS: {name}")
    else:
        failed += 1
        errors.append(name)
        print(f"  FAIL: {name}")

# === CALC_FERIAS ===
print("\n=== CALC_FERIAS ===")

# 1. Função existe
r = run_sql("SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'calc_ferias' AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'folha')) AS ex")
check("calc_ferias existe", r[0]["ex"])

# 2-5. Senior férias
r = run_sql(f"SELECT * FROM folha.calc_ferias('{senior_cid}'::uuid, '2026-10-01')")
ferias_senior = r[0]
check("Senior valor_ferias = 4500", float(ferias_senior["valor_ferias"]) == 4500.00)
check("Senior valor_um_terco = 1500", float(ferias_senior["valor_um_terco"]) == 1500.00)
check("Senior total_ferias = 6000", float(ferias_senior["total_ferias"]) == 6000.00)
check("Senior dias_vencidos = 30", int(ferias_senior["dias_vencidos"]) == 30)

# 6-7. Junior férias
r = run_sql(f"SELECT * FROM folha.calc_ferias('{junior_cid}'::uuid, '2026-10-01')")
ferias_junior = r[0]
check("Junior dias_vencidos = 0", int(ferias_junior["dias_vencidos"]) == 0)
check("Junior dias_proporcionais > 0 e <= 30", 0 < int(ferias_junior["dias_proporcionais"]) <= 30)

# 8. Contrato inexistente deve falhar
try:
    run_sql("SELECT * FROM folha.calc_ferias('00000000-0000-0000-0000-000000000000'::uuid, '2026-10-01')")
    check("Contrato inexistente gera exceção", False)
except Exception:
    check("Contrato inexistente gera exceção", True)

# === CALC_13O ===
print("\n=== CALC_13O ===")

# 9. Função existe
r = run_sql("SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'calc_13o' AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'folha')) AS ex")
check("calc_13o existe", r[0]["ex"])

# 10-11. Senior 1ª parcela
r = run_sql(f"SELECT * FROM folha.calc_13o('{senior_cid}'::uuid, '2026-10-01', 1)")
p1 = r[0]
check("1ª parcela INSS = 0", float(p1["inss"]) == 0.00)
check("1ª parcela líquido = bruto", float(p1["valor_liquido"]) == float(p1["valor_bruto"]))

# 12-14. Senior 2ª parcela
r = run_sql(f"SELECT * FROM folha.calc_13o('{senior_cid}'::uuid, '2026-10-01', 2)")
p2 = r[0]
check("2ª parcela INSS > 0", float(p2["inss"]) > 0)
check("2ª parcela líquido < bruto", float(p2["valor_liquido"]) < float(p2["valor_bruto"]))
check("Senior meses_proporcionais = 12", int(p2["meses_proporcionais"]) == 12)

# 15. Junior meses proporcionais
r = run_sql(f"SELECT * FROM folha.calc_13o('{junior_cid}'::uuid, '2026-10-01', 2)")
p2j = r[0]
check("Junior meses_proporcionais entre 1 e 11", 1 <= int(p2j["meses_proporcionais"]) <= 11)

# 16. Contrato inexistente
try:
    run_sql("SELECT * FROM folha.calc_13o('00000000-0000-0000-0000-000000000000'::uuid, '2026-10-01', 2)")
    check("calc_13o contrato inexistente gera exceção", False)
except Exception:
    check("calc_13o contrato inexistente gera exceção", True)

# === CALC_RESCISAO ===
print("\n=== CALC_RESCISAO ===")

# 17. Função existe
r = run_sql("SELECT EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'calc_rescisao' AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'folha')) AS ex")
check("calc_rescisao existe", r[0]["ex"])

# 18-22. Rescisão sem justa causa
r = run_sql(f"SELECT * FROM folha.calc_rescisao('{senior_cid}'::uuid, '2026-10-13', 'sem_justa_causa')")
rsc = r[0]
check("sem_justa_causa saldo_salario > 0", float(rsc["saldo_salario"]) > 0)
check("sem_justa_causa aviso_previo = 4500", float(rsc["aviso_previo_indenizado"]) == 4500.00)
check("sem_justa_causa multa_fgts = 1800", float(rsc["multa_fgts"]) == 1800.00)
check("sem_justa_causa total_proventos > 0", float(rsc["total_proventos"]) > 0)
check("sem_justa_causa liquido = proventos - descontos",
      float(rsc["liquido_rescisao"]) == float(rsc["total_proventos"]) - float(rsc["total_descontos"]))

# 23-24. Pedido demissão
r = run_sql(f"SELECT * FROM folha.calc_rescisao('{senior_cid}'::uuid, '2026-10-13', 'pedido_demissao')")
rd = r[0]
check("pedido_demissao aviso_previo = 0", float(rd["aviso_previo_indenizado"]) == 0.00)
check("pedido_demissao multa_fgts = 0", float(rd["multa_fgts"]) == 0.00)

# 25-26. Justa causa
r = run_sql(f"SELECT * FROM folha.calc_rescisao('{senior_cid}'::uuid, '2026-10-13', 'justa_causa')")
rjc = r[0]
check("justa_causa aviso_previo = 0", float(rjc["aviso_previo_indenizado"]) == 0.00)
check("justa_causa multa_fgts = 0", float(rjc["multa_fgts"]) == 0.00)

# 27. Férias vencidas na rescisão
check("Senior ferias_vencidas > 0 na rescisão", float(rsc["ferias_vencidas"]) > 0)

# 28. Contrato inexistente
try:
    run_sql("SELECT * FROM folha.calc_rescisao('00000000-0000-0000-0000-000000000000'::uuid, '2026-10-13', 'sem_justa_causa')")
    check("calc_rescisao contrato inexistente gera exceção", False)
except Exception:
    check("calc_rescisao contrato inexistente gera exceção", True)

# Cleanup
print("\n=== CLEANUP ===")
cleanup_sql = """
DELETE FROM folha.employment_contract WHERE account_id = 'e0000000-0000-0000-0000-000000000005' AND cargo IN ('Senior Tester', 'Junior Tester');
DELETE FROM folha.employee WHERE account_id = 'e0000000-0000-0000-0000-000000000005' AND cpf IN ('55555555555', '66666666666');
"""
run_sql(cleanup_sql)
print("OK: Dados de teste removidos")

# Resumo
print(f"\n{'='*50}")
print(f"RESULTADO: {passed} PASS / {failed} FAIL (total {passed+failed})")
if errors:
    print("FALHAS:")
    for e in errors:
        print(f"  - {e}")
    sys.exit(1)
else:
    print("TODOS OS TESTES PASSARAM!")
    sys.exit(0)