-- DNEX Folha — Testes dourados para motor de eventos de vida corrigido (migration 0023)
-- Casos extraídos dos pareceres técnicos de 15/11/2026.
-- Método INSS adotado: soma exata das faixas contínuas, ROUND ao final (método A).
-- Executar após migrations 0014–0023 aplicadas.
BEGIN;
SELECT plan(78);

-- ---------------------------------------------------------------------------
-- Setup: tenant e contratos de teste
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_emp uuid;
  v_cid uuid;
BEGIN
  PERFORM set_config('folha.account_id', 'e0000000-0000-0000-0000-000000000099', true);

  -- CT-01/02: Senior admitido 15/01/2024, salário 4.500
  INSERT INTO folha.employee (account_id, cpf, nome_completo, data_nascimento)
  VALUES ('e0000000-0000-0000-0000-000000000099', '10000000001', 'CT01 Senior', '1980-01-01')
  ON CONFLICT (account_id, cpf) DO NOTHING;
  SELECT employee_id INTO v_emp FROM folha.employee
  WHERE account_id = 'e0000000-0000-0000-0000-000000000099' AND cpf = '10000000001';
  INSERT INTO folha.employment_contract (account_id, employee_id, data_admissao, cargo, salario_base, regime_trabalho)
  VALUES ('e0000000-0000-0000-0000-000000000099', v_emp, '2024-01-15', 'CT01', 4500.00, 'clt')
  ON CONFLICT DO NOTHING;
  SELECT contract_id INTO v_cid FROM folha.employment_contract
  WHERE account_id = 'e0000000-0000-0000-0000-000000000099' AND cargo = 'CT01';
  PERFORM set_config('test.ct01_cid', v_cid::text, true);

  -- CT-03a: admissão 17/03/2026, salário 3.600
  INSERT INTO folha.employee (account_id, cpf, nome_completo, data_nascimento)
  VALUES ('e0000000-0000-0000-0000-000000000099', '10000000003', 'CT03a', '1990-01-01')
  ON CONFLICT (account_id, cpf) DO NOTHING;
  SELECT employee_id INTO v_emp FROM folha.employee
  WHERE account_id = 'e0000000-0000-0000-0000-000000000099' AND cpf = '10000000003';
  INSERT INTO folha.employment_contract (account_id, employee_id, data_admissao, cargo, salario_base, regime_trabalho)
  VALUES ('e0000000-0000-0000-0000-000000000099', v_emp, '2026-03-17', 'CT03a', 3600.00, 'clt')
  ON CONFLICT DO NOTHING;
  SELECT contract_id INTO v_cid FROM folha.employment_contract
  WHERE account_id = 'e0000000-0000-0000-0000-000000000099' AND cargo = 'CT03a';
  PERFORM set_config('test.ct03a_cid', v_cid::text, true);

  -- CT-03b: admissão 18/03/2026, salário 3.600
  INSERT INTO folha.employee (account_id, cpf, nome_completo, data_nascimento)
  VALUES ('e0000000-0000-0000-0000-000000000099', '10000000034', 'CT03b', '1990-01-01')
  ON CONFLICT (account_id, cpf) DO NOTHING;
  SELECT employee_id INTO v_emp FROM folha.employee
  WHERE account_id = 'e0000000-0000-0000-0000-000000000099' AND cpf = '10000000034';
  INSERT INTO folha.employment_contract (account_id, employee_id, data_admissao, cargo, salario_base, regime_trabalho)
  VALUES ('e0000000-0000-0000-0000-000000000099', v_emp, '2026-03-18', 'CT03b', 3600.00, 'clt')
  ON CONFLICT DO NOTHING;
  SELECT contract_id INTO v_cid FROM folha.employment_contract
  WHERE account_id = 'e0000000-0000-0000-0000-000000000099' AND cargo = 'CT03b';
  PERFORM set_config('test.ct03b_cid', v_cid::text, true);

  -- CT-04a: admissão 14/02/2026, salário 2.400
  INSERT INTO folha.employee (account_id, cpf, nome_completo, data_nascimento)
  VALUES ('e0000000-0000-0000-0000-000000000099', '10000000004', 'CT04a', '1990-01-01')
  ON CONFLICT (account_id, cpf) DO NOTHING;
  SELECT employee_id INTO v_emp FROM folha.employee
  WHERE account_id = 'e0000000-0000-0000-0000-000000000099' AND cpf = '10000000004';
  INSERT INTO folha.employment_contract (account_id, employee_id, data_admissao, cargo, salario_base, regime_trabalho)
  VALUES ('e0000000-0000-0000-0000-000000000099', v_emp, '2026-02-14', 'CT04a', 2400.00, 'clt')
  ON CONFLICT DO NOTHING;
  SELECT contract_id INTO v_cid FROM folha.employment_contract
  WHERE account_id = 'e0000000-0000-0000-0000-000000000099' AND cargo = 'CT04a';
  PERFORM set_config('test.ct04a_cid', v_cid::text, true);

  -- CT-04b: admissão 15/02/2026, salário 2.400
  INSERT INTO folha.employee (account_id, cpf, nome_completo, data_nascimento)
  VALUES ('e0000000-0000-0000-0000-000000000099', '10000000045', 'CT04b', '1990-01-01')
  ON CONFLICT (account_id, cpf) DO NOTHING;
  SELECT employee_id INTO v_emp FROM folha.employee
  WHERE account_id = 'e0000000-0000-0000-0000-000000000099' AND cpf = '10000000045';
  INSERT INTO folha.employment_contract (account_id, employee_id, data_admissao, cargo, salario_base, regime_trabalho)
  VALUES ('e0000000-0000-0000-0000-000000000099', v_emp, '2026-02-15', 'CT04b', 2400.00, 'clt')
  ON CONFLICT DO NOTHING;
  SELECT contract_id INTO v_cid FROM folha.employment_contract
  WHERE account_id = 'e0000000-0000-0000-0000-000000000099' AND cargo = 'CT04b';
  PERFORM set_config('test.ct04b_cid', v_cid::text, true);

  -- CT-05: admissão 20/11/2025, salário 9.000
  INSERT INTO folha.employee (account_id, cpf, nome_completo, data_nascimento)
  VALUES ('e0000000-0000-0000-0000-000000000099', '10000000005', 'CT05', '1985-01-01')
  ON CONFLICT (account_id, cpf) DO NOTHING;
  SELECT employee_id INTO v_emp FROM folha.employee
  WHERE account_id = 'e0000000-0000-0000-0000-000000000099' AND cpf = '10000000005';
  INSERT INTO folha.employment_contract (account_id, employee_id, data_admissao, cargo, salario_base, regime_trabalho)
  VALUES ('e0000000-0000-0000-0000-000000000099', v_emp, '2025-11-20', 'CT05', 9000.00, 'clt')
  ON CONFLICT DO NOTHING;
  SELECT contract_id INTO v_cid FROM folha.employment_contract
  WHERE account_id = 'e0000000-0000-0000-0000-000000000099' AND cargo = 'CT05';
  PERFORM set_config('test.ct05_cid', v_cid::text, true);

  -- CT-06: admissão 20/12/2026, salário 3.000 (fração <15 dias = 0 avos)
  INSERT INTO folha.employee (account_id, cpf, nome_completo, data_nascimento)
  VALUES ('e0000000-0000-0000-0000-000000000099', '10000000006', 'CT06', '1990-01-01')
  ON CONFLICT (account_id, cpf) DO NOTHING;
  SELECT employee_id INTO v_emp FROM folha.employee
  WHERE account_id = 'e0000000-0000-0000-0000-000000000099' AND cpf = '10000000006';
  INSERT INTO folha.employment_contract (account_id, employee_id, data_admissao, cargo, salario_base, regime_trabalho)
  VALUES ('e0000000-0000-0000-0000-000000000099', v_emp, '2026-12-20', 'CT06', 3000.00, 'clt')
  ON CONFLICT DO NOTHING;
  SELECT contract_id INTO v_cid FROM folha.employment_contract
  WHERE account_id = 'e0000000-0000-0000-0000-000000000099' AND cargo = 'CT06';
  PERFORM set_config('test.ct06_cid', v_cid::text, true);

  -- CT-07: férias simples, período aquisitivo completo, 30 dias gozo, salário 3.000
  INSERT INTO folha.employee (account_id, cpf, nome_completo, data_nascimento)
  VALUES ('e0000000-0000-0000-0000-000000000099', '10000000007', 'CT07', '1990-01-01')
  ON CONFLICT (account_id, cpf) DO NOTHING;
  SELECT employee_id INTO v_emp FROM folha.employee
  WHERE account_id = 'e0000000-0000-0000-0000-000000000099' AND cpf = '10000000007';
  INSERT INTO folha.employment_contract (account_id, employee_id, data_admissao, cargo, salario_base, regime_trabalho)
  VALUES ('e0000000-0000-0000-0000-000000000099', v_emp, '2024-06-01', 'CT07', 3000.00, 'clt')
  ON CONFLICT DO NOTHING;
  SELECT contract_id INTO v_cid FROM folha.employment_contract
  WHERE account_id = 'e0000000-0000-0000-0000-000000000099' AND cargo = 'CT07';
  PERFORM set_config('test.ct07_cid', v_cid::text, true);

  -- CT-08: férias com abono pecuniário (10 dias vendidos), salário 4.000
  INSERT INTO folha.employee (account_id, cpf, nome_completo, data_nascimento)
  VALUES ('e0000000-0000-0000-0000-000000000099', '10000000008', 'CT08', '1990-01-01')
  ON CONFLICT (account_id, cpf) DO NOTHING;
  SELECT employee_id INTO v_emp FROM folha.employee
  WHERE account_id = 'e0000000-0000-0000-0000-000000000099' AND cpf = '10000000008';
  INSERT INTO folha.employment_contract (account_id, employee_id, data_admissao, cargo, salario_base, regime_trabalho)
  VALUES ('e0000000-0000-0000-0000-000000000099', v_emp, '2024-03-01', 'CT08', 4000.00, 'clt')
  ON CONFLICT DO NOTHING;
  SELECT contract_id INTO v_cid FROM folha.employment_contract
  WHERE account_id = 'e0000000-0000-0000-0000-000000000099' AND cargo = 'CT08';
  PERFORM set_config('test.ct08_cid', v_cid::text, true);

  -- CT-09: férias proporcionais rescisão, 5/12 avos, salário 2.400
  INSERT INTO folha.employee (account_id, cpf, nome_completo, data_nascimento)
  VALUES ('e0000000-0000-0000-0000-000000000099', '10000000009', 'CT09', '1990-01-01')
  ON CONFLICT (account_id, cpf) DO NOTHING;
  SELECT employee_id INTO v_emp FROM folha.employee
  WHERE account_id = 'e0000000-0000-0000-0000-000000000099' AND cpf = '10000000009';
  INSERT INTO folha.employment_contract (account_id, employee_id, data_admissao, cargo, salario_base, regime_trabalho)
  VALUES ('e0000000-0000-0000-0000-000000000099', v_emp, '2026-01-15', 'CT09', 2400.00, 'clt')
  ON CONFLICT DO NOTHING;
  SELECT contract_id INTO v_cid FROM folha.employment_contract
  WHERE account_id = 'e0000000-0000-0000-0000-000000000099' AND cargo = 'CT09';
  PERFORM set_config('test.ct09_cid', v_cid::text, true);

  -- CT-10: férias dobra art.137, salário 3.600
  INSERT INTO folha.employee (account_id, cpf, nome_completo, data_nascimento)
  VALUES ('e0000000-0000-0000-0000-000000000099', '10000000010', 'CT10', '1990-01-01')
  ON CONFLICT (account_id, cpf) DO NOTHING;
  SELECT employee_id INTO v_emp FROM folha.employee
  WHERE account_id = 'e0000000-0000-0000-0000-000000000099' AND cpf = '10000000010';
  INSERT INTO folha.employment_contract (account_id, employee_id, data_admissao, cargo, salario_base, regime_trabalho)
  VALUES ('e0000000-0000-0000-0000-000000000099', v_emp, '2023-01-01', 'CT10', 3600.00, 'clt')
  ON CONFLICT DO NOTHING;
  SELECT contract_id INTO v_cid FROM folha.employment_contract
  WHERE account_id = 'e0000000-0000-0000-0000-000000000099' AND cargo = 'CT10';
  PERFORM set_config('test.ct10_cid', v_cid::text, true);

  -- CT-12: férias proporcionais na rescisão, admissão 10/04/2026, salário 3.200
  INSERT INTO folha.employee (account_id, cpf, nome_completo, data_nascimento)
  VALUES ('e0000000-0000-0000-0000-000000000099', '10000000088', 'CT12', '1990-01-01')
  ON CONFLICT (account_id, cpf) DO NOTHING;
  SELECT employee_id INTO v_emp FROM folha.employee
  WHERE account_id = 'e0000000-0000-0000-0000-000000000099' AND cpf = '10000000088';
  INSERT INTO folha.employment_contract (account_id, employee_id, data_admissao, cargo, salario_base, regime_trabalho)
  VALUES ('e0000000-0000-0000-0000-000000000099', v_emp, '2026-04-10', 'CT12', 3200.00, 'clt')
  ON CONFLICT DO NOTHING;
  SELECT contract_id INTO v_cid FROM folha.employment_contract
  WHERE account_id = 'e0000000-0000-0000-0000-000000000099' AND cargo = 'CT12';
  PERFORM set_config('test.ct12_cid', v_cid::text, true);

  -- G01: rescisão sem justa causa, 2 anos completos, salário 3.000
  INSERT INTO folha.employee (account_id, cpf, nome_completo, data_nascimento)
  VALUES ('e0000000-0000-0000-0000-000000000099', '10000000051', 'G01', '1990-01-01')
  ON CONFLICT (account_id, cpf) DO NOTHING;
  SELECT employee_id INTO v_emp FROM folha.employee
  WHERE account_id = 'e0000000-0000-0000-0000-000000000099' AND cpf = '10000000051';
  INSERT INTO folha.employment_contract (account_id, employee_id, data_admissao, cargo, salario_base, regime_trabalho)
  VALUES ('e0000000-0000-0000-0000-000000000099', v_emp, '2024-06-01', 'G01', 3000.00, 'clt')
  ON CONFLICT DO NOTHING;
  SELECT contract_id INTO v_cid FROM folha.employment_contract
  WHERE account_id = 'e0000000-0000-0000-0000-000000000099' AND cargo = 'G01';
  PERFORM set_config('test.g01_cid', v_cid::text, true);

  -- G02: pedido de demissão, 1 ano completo, salário 2.500
  INSERT INTO folha.employee (account_id, cpf, nome_completo, data_nascimento)
  VALUES ('e0000000-0000-0000-0000-000000000099', '10000000052', 'G02', '1990-01-01')
  ON CONFLICT (account_id, cpf) DO NOTHING;
  SELECT employee_id INTO v_emp FROM folha.employee
  WHERE account_id = 'e0000000-0000-0000-0000-000000000099' AND cpf = '10000000052';
  INSERT INTO folha.employment_contract (account_id, employee_id, data_admissao, cargo, salario_base, regime_trabalho)
  VALUES ('e0000000-0000-0000-0000-000000000099', v_emp, '2025-06-01', 'G02', 2500.00, 'clt')
  ON CONFLICT DO NOTHING;
  SELECT contract_id INTO v_cid FROM folha.employment_contract
  WHERE account_id = 'e0000000-0000-0000-0000-000000000099' AND cargo = 'G02';
  PERFORM set_config('test.g02_cid', v_cid::text, true);

  -- G03: justa causa, salário 2.800
  INSERT INTO folha.employee (account_id, cpf, nome_completo, data_nascimento)
  VALUES ('e0000000-0000-0000-0000-000000000099', '10000000053', 'G03', '1990-01-01')
  ON CONFLICT (account_id, cpf) DO NOTHING;
  SELECT employee_id INTO v_emp FROM folha.employee
  WHERE account_id = 'e0000000-0000-0000-0000-000000000099' AND cpf = '10000000053';
  INSERT INTO folha.employment_contract (account_id, employee_id, data_admissao, cargo, salario_base, regime_trabalho)
  VALUES ('e0000000-0000-0000-0000-000000000099', v_emp, '2025-01-15', 'G03', 2800.00, 'clt')
  ON CONFLICT DO NOTHING;
  SELECT contract_id INTO v_cid FROM folha.employment_contract
  WHERE account_id = 'e0000000-0000-0000-0000-000000000099' AND cargo = 'G03';
  PERFORM set_config('test.g03_cid', v_cid::text, true);

  -- G04: acordo 484-A, 1.5 anos, salário 4.000
  INSERT INTO folha.employee (account_id, cpf, nome_completo, data_nascimento)
  VALUES ('e0000000-0000-0000-0000-000000000099', '10000000054', 'G04', '1990-01-01')
  ON CONFLICT (account_id, cpf) DO NOTHING;
  SELECT employee_id INTO v_emp FROM folha.employee
  WHERE account_id = 'e0000000-0000-0000-0000-000000000099' AND cpf = '10000000054';
  INSERT INTO folha.employment_contract (account_id, employee_id, data_admissao, cargo, salario_base, regime_trabalho)
  VALUES ('e0000000-0000-0000-0000-000000000099', v_emp, '2025-01-01', 'G04', 4000.00, 'clt')
  ON CONFLICT DO NOTHING;
  SELECT contract_id INTO v_cid FROM folha.employment_contract
  WHERE account_id = 'e0000000-0000-0000-0000-000000000099' AND cargo = 'G04';
  PERFORM set_config('test.g04_cid', v_cid::text, true);

  -- G12: rescisão proporcional, admissão 17/08/2026, salário 2.100
  INSERT INTO folha.employee (account_id, cpf, nome_completo, data_nascimento)
  VALUES ('e0000000-0000-0000-0000-000000000099', '10000000012', 'G12', '1990-01-01')
  ON CONFLICT (account_id, cpf) DO NOTHING;
  SELECT employee_id INTO v_emp FROM folha.employee
  WHERE account_id = 'e0000000-0000-0000-0000-000000000099' AND cpf = '10000000012';
  INSERT INTO folha.employment_contract (account_id, employee_id, data_admissao, cargo, salario_base, regime_trabalho)
  VALUES ('e0000000-0000-0000-0000-000000000099', v_emp, '2026-08-17', 'G12', 2100.00, 'clt')
  ON CONFLICT DO NOTHING;
  SELECT contract_id INTO v_cid FROM folha.employment_contract
  WHERE account_id = 'e0000000-0000-0000-0000-000000000099' AND cargo = 'G12';
  PERFORM set_config('test.g12_cid', v_cid::text, true);

  -- PJ: regime inválido para teste negativo
  INSERT INTO folha.employee (account_id, cpf, nome_completo, data_nascimento)
  VALUES ('e0000000-0000-0000-0000-000000000099', '10000000099', 'PJ Test', '1990-01-01')
  ON CONFLICT (account_id, cpf) DO NOTHING;
  SELECT employee_id INTO v_emp FROM folha.employee
  WHERE account_id = 'e0000000-0000-0000-0000-000000000099' AND cpf = '10000000099';
  INSERT INTO folha.employment_contract (account_id, employee_id, data_admissao, cargo, salario_base, regime_trabalho)
  VALUES ('e0000000-0000-0000-0000-000000000099', v_emp, '2024-01-01', 'PJ', 5000.00, 'pj')
  ON CONFLICT DO NOTHING;
  SELECT contract_id INTO v_cid FROM folha.employment_contract
  WHERE account_id = 'e0000000-0000-0000-0000-000000000099' AND cargo = 'PJ';
  PERFORM set_config('test.pj_cid', v_cid::text, true);
END
$$;

-- ===========================================================================
-- CT-01: 13º adiantamento, ano inteiro, salário 4.500
-- Admissão 15/01/2024 → 12 avos em 2026. 1ª parcela = metade sem descontos.
-- Bruto = 4500/2 = 2250. FGTS = 2250*8% = 180. Líquido = 2250.
-- ===========================================================================
SELECT is((SELECT meses_proporcionais FROM folha.calc_13o(current_setting('test.ct01_cid')::uuid, '2026-11-30', 1)), 12, 'CT-01: avos=12');
SELECT is((SELECT valor_bruto FROM folha.calc_13o(current_setting('test.ct01_cid')::uuid, '2026-11-30', 1)), 2250.00::numeric, 'CT-01: bruto=2250');
SELECT is((SELECT inss FROM folha.calc_13o(current_setting('test.ct01_cid')::uuid, '2026-11-30', 1)), 0.00::numeric, 'CT-01: INSS=0 na 1a parcela');
SELECT is((SELECT irrf FROM folha.calc_13o(current_setting('test.ct01_cid')::uuid, '2026-11-30', 1)), 0.00::numeric, 'CT-01: IRRF=0 na 1a parcela');
SELECT is((SELECT valor_liquido FROM folha.calc_13o(current_setting('test.ct01_cid')::uuid, '2026-11-30', 1)), 2250.00::numeric, 'CT-01: liquido=2250');
SELECT is((SELECT fgts FROM folha.calc_13o(current_setting('test.ct01_cid')::uuid, '2026-11-30', 1)), 180.00::numeric, 'CT-01: FGTS=180');

-- ===========================================================================
-- CT-02: 13º quitação com adiantamento compensado, salário 4.500
-- Bruto total = 4500. INSS(A) sobre 4500 = 431.51.
-- Parecer: IRRF=0, liquido=1818.49.
-- ===========================================================================
SELECT is((SELECT valor_bruto FROM folha.calc_13o(current_setting('test.ct01_cid')::uuid, '2026-12-18', 2, 2250.00)), 4500.00::numeric, 'CT-02: bruto=4500');
SELECT is((SELECT inss FROM folha.calc_13o(current_setting('test.ct01_cid')::uuid, '2026-12-18', 2, 2250.00)), 431.51::numeric, 'CT-02: INSS(A)=431.51');
SELECT is((SELECT irrf FROM folha.calc_13o(current_setting('test.ct01_cid')::uuid, '2026-12-18', 2, 2250.00)), 0.00::numeric, 'CT-02: IRRF=0 per parecer');
SELECT is((SELECT adiantamento_compensado FROM folha.calc_13o(current_setting('test.ct01_cid')::uuid, '2026-12-18', 2, 2250.00)), 2250.00::numeric, 'CT-02: adiant=2250');
SELECT is((SELECT valor_liquido FROM folha.calc_13o(current_setting('test.ct01_cid')::uuid, '2026-12-18', 2, 2250.00)), 1818.49::numeric, 'CT-02: liquido(A)=1818.49');
SELECT is((SELECT fgts FROM folha.calc_13o(current_setting('test.ct01_cid')::uuid, '2026-12-18', 2, 2250.00)), 180.00::numeric, 'CT-02: FGTS=180 (sobre diferença)');

-- ===========================================================================
-- CT-03: corte 15 dias em mês de 31 dias
-- CT-03a: adm 17/03 → 17..31 = 15 dias → avo. CT-03b: adm 18/03 → 14 dias → sem avo.
-- ===========================================================================
SELECT is((SELECT meses_proporcionais FROM folha.calc_13o(current_setting('test.ct03a_cid')::uuid, '2026-12-01', 2)), 10, 'CT-03a: 10 avos');
SELECT is((SELECT valor_bruto FROM folha.calc_13o(current_setting('test.ct03a_cid')::uuid, '2026-12-01', 2)), 3000.00::numeric, 'CT-03a: bruto=3000');
SELECT is((SELECT meses_proporcionais FROM folha.calc_13o(current_setting('test.ct03b_cid')::uuid, '2026-12-01', 2)), 9, 'CT-03b: 9 avos');
SELECT is((SELECT valor_bruto FROM folha.calc_13o(current_setting('test.ct03b_cid')::uuid, '2026-12-01', 2)), 2700.00::numeric, 'CT-03b: bruto=2700');

-- ===========================================================================
-- CT-04: corte 15 dias em fevereiro (28 dias)
-- CT-04a: adm 14/02 → 14..28 = 15 dias → avo. CT-04b: adm 15/02 → 14 dias → sem avo.
-- ===========================================================================
SELECT is((SELECT meses_proporcionais FROM folha.calc_13o(current_setting('test.ct04a_cid')::uuid, '2026-12-01', 2)), 11, 'CT-04a: 11 avos');
SELECT is((SELECT valor_bruto FROM folha.calc_13o(current_setting('test.ct04a_cid')::uuid, '2026-12-01', 2)), 2200.00::numeric, 'CT-04a: bruto=2200');
SELECT is((SELECT meses_proporcionais FROM folha.calc_13o(current_setting('test.ct04b_cid')::uuid, '2026-12-01', 2)), 10, 'CT-04b: 10 avos');
SELECT is((SELECT valor_bruto FROM folha.calc_13o(current_setting('test.ct04b_cid')::uuid, '2026-12-01', 2)), 2000.00::numeric, 'CT-04b: bruto=2000');

-- ===========================================================================
-- CT-05: faixa alta, admissão ano anterior, 12 avos
-- INSS sobre 9000 limitado ao teto 8475.55: método A = 988.09
-- IRRF: base 9000-988.09=8011.91; 8011.91*27.5%-908.73=1294.55
-- Liquido: 9000-4500-988.09-1294.55=2217.36
-- ===========================================================================
SELECT is((SELECT meses_proporcionais FROM folha.calc_13o(current_setting('test.ct05_cid')::uuid, '2026-12-18', 2, 4500.00)), 12, 'CT-05: 12 avos');
SELECT is((SELECT valor_bruto FROM folha.calc_13o(current_setting('test.ct05_cid')::uuid, '2026-12-18', 2, 4500.00)), 9000.00::numeric, 'CT-05: bruto=9000');
SELECT is((SELECT inss FROM folha.calc_13o(current_setting('test.ct05_cid')::uuid, '2026-12-18', 2, 4500.00)), 988.09::numeric, 'CT-05: INSS(A)=988.09');
SELECT is((SELECT irrf FROM folha.calc_13o(current_setting('test.ct05_cid')::uuid, '2026-12-18', 2, 4500.00)), 1294.55::numeric, 'CT-05: IRRF=1294.55');
SELECT is((SELECT valor_liquido FROM folha.calc_13o(current_setting('test.ct05_cid')::uuid, '2026-12-18', 2, 4500.00)), 2217.36::numeric, 'CT-05: liquido(A)=2217.36');

-- ===========================================================================
-- CT-06: fração <15 dias = 0 avos (admissão 20/12 → 12 dias em dez)
-- ===========================================================================
SELECT is((SELECT meses_proporcionais FROM folha.calc_13o(current_setting('test.ct06_cid')::uuid, '2026-12-31', 2)), 0, 'CT-06: 0 avos');
SELECT is((SELECT valor_bruto FROM folha.calc_13o(current_setting('test.ct06_cid')::uuid, '2026-12-31', 2)), 0.00::numeric, 'CT-06: bruto=0');

-- ===========================================================================
-- CT-07: férias simples, 30 dias gozo, salário 3.000, 0 faltas
-- Valor = 3000 + 1000 (terço) = 4000. INSS sobre 3000 = 270.37 (A). FGTS sobre 3000 = 240.
-- IRRF base = 3000-270.37 = 2729.63 → 7.5% - 189.59 = 15.13. Liquido = 4000-270.37-15.13 = 3714.50.
-- ===========================================================================
SELECT is((SELECT valor_ferias FROM folha.calc_ferias(current_setting('test.ct07_cid')::uuid, '2026-01-15', 30, 0, 0, '2024-06-01', '2025-05-31', 3000.00)), 3000.00::numeric, 'CT-07: ferias=3000');
SELECT is((SELECT terco_constitucional FROM folha.calc_ferias(current_setting('test.ct07_cid')::uuid, '2026-01-15', 30, 0, 0, '2024-06-01', '2025-05-31', 3000.00)), 1000.00::numeric, 'CT-07: terco=1000');
SELECT is((SELECT inss FROM folha.calc_ferias(current_setting('test.ct07_cid')::uuid, '2026-01-15', 30, 0, 0, '2024-06-01', '2025-05-31', 3000.00)), 270.37::numeric, 'CT-07: INSS=270.37');
SELECT is((SELECT valor_liquido FROM folha.calc_ferias(current_setting('test.ct07_cid')::uuid, '2026-01-15', 30, 0, 0, '2024-06-01', '2025-05-31', 3000.00)), 3714.50::numeric, 'CT-07: liquido=3714.50');

-- ===========================================================================
-- CT-08: férias com abono pecuniário (10 dias vendidos), salário 4.000
-- Gozo = 20 dias. Abono = 10/30 * 4000 = 1333.33. Terço abono = 444.44.
-- Ferias gozadas = 20/30 * 4000 = 2666.67. Terço gozo = 888.89.
-- INSS sobre 2666.67 = 238.24 (A). FGTS sobre 2666.67 = 213.33.
-- IRRF base = 2666.67-238.24 = 2428.43 → isento (<=2428.80).
-- Liquido = (2666.67+888.89) + (1333.33+444.44) - 238.24 = 5095.09.
-- ===========================================================================
SELECT is((SELECT valor_abono FROM folha.calc_ferias(current_setting('test.ct08_cid')::uuid, '2026-01-15', 20, 10, 0, '2024-03-01', '2025-02-28', 4000.00)), 1333.33::numeric, 'CT-08: abono=1333.33');
SELECT is((SELECT terco_abono FROM folha.calc_ferias(current_setting('test.ct08_cid')::uuid, '2026-01-15', 20, 10, 0, '2024-03-01', '2025-02-28', 4000.00)), 444.44::numeric, 'CT-08: terco_abono=444.44');
SELECT is((SELECT inss FROM folha.calc_ferias(current_setting('test.ct08_cid')::uuid, '2026-01-15', 20, 10, 0, '2024-03-01', '2025-02-28', 4000.00)), 238.24::numeric, 'CT-08: INSS=238.24');
SELECT is((SELECT valor_liquido FROM folha.calc_ferias(current_setting('test.ct08_cid')::uuid, '2026-01-15', 20, 10, 0, '2024-03-01', '2025-02-28', 4000.00)), 5095.09::numeric, 'CT-08: liquido=5095.09');

-- ===========================================================================
-- CT-10: férias dobra art.137, salário 3.600
-- Período concessivo expirado → dobra = valor integral das férias.
-- Ferias = 3600 + 1200 (terço) + 3600 (dobra) = 8400.
-- INSS sobre 3600 = 354.09 (A). IRRF base = 3600-354.09 = 3245.91 → 15%-381.17 = 105.72.
-- Liquido = 8400 - 354.09 - 105.72 = 7940.19.
-- ===========================================================================
SELECT is((SELECT valor_dobra FROM folha.calc_ferias(current_setting('test.ct10_cid')::uuid, '2026-01-15', 30, 0, 0, '2023-01-01', '2023-12-31', 3600.00)), 3600.00::numeric, 'CT-10: dobra=3600');
SELECT is((SELECT inss FROM folha.calc_ferias(current_setting('test.ct10_cid')::uuid, '2026-01-15', 30, 0, 0, '2023-01-01', '2023-12-31', 3600.00)), 354.09::numeric, 'CT-10: INSS=354.09');
SELECT is((SELECT valor_liquido FROM folha.calc_ferias(current_setting('test.ct10_cid')::uuid, '2026-01-15', 30, 0, 0, '2023-01-01', '2023-12-31', 3600.00)), 7940.19::numeric, 'CT-10: liquido=7940.19');

-- ===========================================================================
-- G01: rescisão sem justa causa, 2 anos completos, salário 3.000
-- Saldo salário 15 dias = 1500. Aviso indenizado 36 dias = 3600.
-- 13º prop 6/12 = 1500. Férias prop 8/12 = 2000 + terço 666.67.
-- Multa FGTS = 40% sobre base extrato (parametrizada).
-- INSS saldo = 135.19. INSS 13º = 120.00. IRRF saldo = 0. IRRF 13º = 0.
-- Liquido = 1500+3600+1500+2666.67 - 135.19 - 120.00 = 9011.48.
-- ===========================================================================
SELECT is((SELECT saldo_salario FROM folha.calc_rescisao(current_setting('test.g01_cid')::uuid, '2026-06-15', 'sem_justa_causa', 'indenizado', 0, 3000.00, 0, 0, 0, 0)), 1500.00::numeric, 'G01: saldo=1500');
SELECT is((SELECT aviso_previo_valor FROM folha.calc_rescisao(current_setting('test.g01_cid')::uuid, '2026-06-15', 'sem_justa_causa', 'indenizado', 0, 3000.00, 0, 0, 0, 0)), 3600.00::numeric, 'G01: aviso=3600');
SELECT is((SELECT decimo_terceiro_proporcional FROM folha.calc_rescisao(current_setting('test.g01_cid')::uuid, '2026-06-15', 'sem_justa_causa', 'indenizado', 0, 3000.00, 0, 0, 0, 0)), 1500.00::numeric, 'G01: 13o=1500');
SELECT is((SELECT ferias_proporcionais FROM folha.calc_rescisao(current_setting('test.g01_cid')::uuid, '2026-06-15', 'sem_justa_causa', 'indenizado', 0, 3000.00, 0, 0, 0, 0)), 2666.67::numeric, 'G01: ferias+terco=2666.67');
SELECT is((SELECT valor_liquido FROM folha.calc_rescisao(current_setting('test.g01_cid')::uuid, '2026-06-15', 'sem_justa_causa', 'indenizado', 0, 3000.00, 0, 0, 0, 0)), 9011.48::numeric, 'G01: liquido=9011.48');

-- ===========================================================================
-- G03: justa causa, salário 2.800
-- Apenas saldo salário e férias vencidas (se houver). Sem aviso, sem 13º, sem multa.
-- Saldo 15 dias = 1400. INSS = 119.14. IRRF = 0. Liquido = 1280.86.
-- ===========================================================================
SELECT is((SELECT saldo_salario FROM folha.calc_rescisao(current_setting('test.g03_cid')::uuid, '2026-06-15', 'justa_causa', NULL, 0, 2800.00, 0, 0, 0, 0)), 1400.00::numeric, 'G03: saldo=1400');
SELECT is((SELECT aviso_previo_valor FROM folha.calc_rescisao(current_setting('test.g03_cid')::uuid, '2026-06-15', 'justa_causa', NULL, 0, 2800.00, 0, 0, 0, 0)), 0.00::numeric, 'G03: aviso=0');
SELECT is((SELECT multa_fgts FROM folha.calc_rescisao(current_setting('test.g03_cid')::uuid, '2026-06-15', 'justa_causa', NULL, 0, 2800.00, 0, 0, 0, 0)), 0.00::numeric, 'G03: multa_fgts=0');
SELECT is((SELECT valor_liquido FROM folha.calc_rescisao(current_setting('test.g03_cid')::uuid, '2026-06-15', 'justa_causa', NULL, 0, 2800.00, 0, 0, 0, 0)), 1280.86::numeric, 'G03: liquido=1280.86');

-- ===========================================================================
-- Negativos: regime não-CLT deve levantar exceção
-- ===========================================================================
SELECT throws_ok(
  $$SELECT folha.calc_13o(current_setting('test.pj_cid')::uuid, '2026-12-01', 2)$$,
  'P0001',
  NULL,
  'NEG: calc_13o recusa regime não-CLT'
);
SELECT throws_ok(
  $$SELECT folha.calc_rescisao(current_setting('test.pj_cid')::uuid, '2026-06-15', 'sem_justa_causa', NULL, 0, 5000.00, 0, 0, 0, 0)$$,
  'P0001',
  NULL,
  'NEG: calc_rescisao recusa regime não-CLT'
);

ROLLBACK;