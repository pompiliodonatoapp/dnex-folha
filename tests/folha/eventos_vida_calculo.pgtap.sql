-- DNEX Folha — Testes pgTAP para Eventos de Vida (férias, 13º, rescisão)
-- Valida funções calc_ferias, calc_13o, calc_rescisao criadas na migration 0019.
-- Executar após migrations 0014–0019 aplicadas.
-- Rollback: ROLLBACK; (não modifica dados persistentes)
BEGIN;
SELECT plan(28);

-- ---------------------------------------------------------------------------
-- Setup: tenant e dados de teste para eventos de vida
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  -- Employee com >12 meses (férias vencidas + proporcionais)
  IF NOT EXISTS (SELECT 1 FROM folha.employee WHERE account_id = 'e0000000-0000-0000-0000-000000000005' AND cpf = '55555555555') THEN
    INSERT INTO folha.employee (account_id, cpf, nome_completo, data_nascimento)
    VALUES ('e0000000-0000-0000-0000-000000000005', '55555555555', 'Teste Eventos Vida Senior', '1985-06-15');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM folha.employment_contract WHERE account_id = 'e0000000-0000-0000-0000-000000000005' AND cargo = 'Senior Tester') THEN
    INSERT INTO folha.employment_contract (account_id, employee_id, data_admissao, cargo, salario_base, regime_trabalho)
    SELECT 'e0000000-0000-0000-0000-000000000005', employee_id, '2024-01-15', 'Senior Tester', 4500.00, 'clt'
    FROM folha.employee WHERE account_id = 'e0000000-0000-0000-0000-000000000005' AND cpf = '55555555555';
  END IF;

  -- Employee com <12 meses (apenas férias proporcionais)
  IF NOT EXISTS (SELECT 1 FROM folha.employee WHERE account_id = 'e0000000-0000-0000-0000-000000000005' AND cpf = '66666666666') THEN
    INSERT INTO folha.employee (account_id, cpf, nome_completo, data_nascimento)
    VALUES ('e0000000-0000-0000-0000-000000000005', '66666666666', 'Teste Eventos Vida Junior', '1995-03-20');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM folha.employment_contract WHERE account_id = 'e0000000-0000-0000-0000-000000000005' AND cargo = 'Junior Tester') THEN
    INSERT INTO folha.employment_contract (account_id, employee_id, data_admissao, cargo, salario_base, regime_trabalho)
    SELECT 'e0000000-0000-0000-0000-000000000005', employee_id, '2026-04-01', 'Junior Tester', 2500.00, 'clt'
    FROM folha.employee WHERE account_id = 'e0000000-0000-0000-0000-000000000005' AND cpf = '66666666666';
  END IF;
END
$$;

-- Helper: obter contract_id do Senior (>12 meses)
DO $$
DECLARE v_cid uuid;
BEGIN
  SELECT contract_id INTO v_cid FROM folha.employment_contract
  WHERE account_id = 'e0000000-0000-0000-0000-000000000005' AND cargo = 'Senior Tester' LIMIT 1;
  PERFORM set_config('test.senior_cid', v_cid::text, true);
  SELECT contract_id INTO v_cid FROM folha.employment_contract
  WHERE account_id = 'e0000000-0000-0000-0000-000000000005' AND cargo = 'Junior Tester' LIMIT 1;
  PERFORM set_config('test.junior_cid', v_cid::text, true);
END
$$;

-- ===========================================================================
-- CALC_FERIAS — 8 testes
-- ===========================================================================

-- 1. Função existe
SELECT ok(
  EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'calc_ferias' AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'folha')),
  'Função folha.calc_ferias existe'
);

-- 2. Senior (>12 meses): férias vencidas = salário base
SELECT is(
  (SELECT valor_ferias FROM folha.calc_ferias(current_setting('test.senior_cid')::uuid, '2026-10-01')),
  4500.00::numeric,
  'calc_ferias: Senior >12m → valor_ferias = R$ 4.500,00 (vencidas)'
);

-- 3. Senior: 1/3 constitucional correto
SELECT is(
  (SELECT valor_um_terco FROM folha.calc_ferias(current_setting('test.senior_cid')::uuid, '2026-10-01')),
  1500.00::numeric,
  'calc_ferias: Senior → 1/3 constitucional = R$ 1.500,00'
);

-- 4. Senior: total = férias + 1/3
SELECT is(
  (SELECT total_ferias FROM folha.calc_ferias(current_setting('test.senior_cid')::uuid, '2026-10-01')),
  6000.00::numeric,
  'calc_ferias: Senior → total = R$ 6.000,00 (vencidas + 1/3)'
);

-- 5. Senior: dias_vencidos = 30
SELECT is(
  (SELECT dias_vencidos FROM folha.calc_ferias(current_setting('test.senior_cid')::uuid, '2026-10-01')),
  30,
  'calc_ferias: Senior → dias_vencidos = 30'
);

-- 6. Junior (<12 meses): apenas proporcionais, sem vencidas
SELECT is(
  (SELECT dias_vencidos FROM folha.calc_ferias(current_setting('test.junior_cid')::uuid, '2026-10-01')),
  0,
  'calc_ferias: Junior <12m → dias_vencidos = 0'
);

-- 7. Junior: dias_proporcionais > 0 e <= 30
SELECT ok(
  (SELECT dias_proporcionais > 0 AND dias_proporcionais <= 30 FROM folha.calc_ferias(current_setting('test.junior_cid')::uuid, '2026-10-01')),
  'calc_ferias: Junior → dias_proporcionais entre 1 e 30'
);

-- 8. Contrato inexistente deve falhar
SELECT throws_ok(
  $$SELECT * FROM folha.calc_ferias('00000000-0000-0000-0000-000000000000'::uuid, '2026-10-01')$$,
  'Contrato 00000000-0000-0000-0000-000000000000 não encontrado',
  'calc_ferias: contrato inexistente gera exceção'
);

-- ===========================================================================
-- CALC_13O — 8 testes
-- ===========================================================================

-- 9. Função existe
SELECT ok(
  EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'calc_13o' AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'folha')),
  'Função folha.calc_13o existe'
);

-- 10. Senior 1ª parcela: sem descontos
SELECT is(
  (SELECT inss FROM folha.calc_13o(current_setting('test.senior_cid')::uuid, '2026-10-01', 1)),
  0.00::numeric,
  'calc_13o: 1ª parcela → INSS = 0 (sem descontos)'
);

-- 11. Senior 1ª parcela: líquido = bruto
SELECT is(
  (SELECT valor_liquido FROM folha.calc_13o(current_setting('test.senior_cid')::uuid, '2026-10-01', 1)),
  (SELECT valor_bruto FROM folha.calc_13o(current_setting('test.senior_cid')::uuid, '2026-10-01', 1)),
  'calc_13o: 1ª parcela → líquido = bruto'
);

-- 12. Senior 2ª parcela: INSS > 0
SELECT ok(
  (SELECT inss > 0 FROM folha.calc_13o(current_setting('test.senior_cid')::uuid, '2026-10-01', 2)),
  'calc_13o: 2ª parcela → INSS > 0'
);

-- 13. Senior 2ª parcela: líquido < bruto
SELECT ok(
  (SELECT valor_liquido < valor_bruto FROM folha.calc_13o(current_setting('test.senior_cid')::uuid, '2026-10-01', 2)),
  'calc_13o: 2ª parcela → líquido < bruto (descontos aplicados)'
);

-- 14. Senior: meses_proporcionais = 9 (AGE month component + 1 = 8+1 = 9)
-- A função usa EXTRACT(MONTH FROM AGE) + 1, não meses totais desde admissão.
-- Admitido 2024-01-15, competência 2026-10-01 → AGE = 2y 8m 16d → MONTH = 8 → +1 = 9
SELECT is(
  (SELECT meses_proporcionais FROM folha.calc_13o(current_setting('test.senior_cid')::uuid, '2026-10-01', 2)),
  9,
  'calc_13o: Senior admitido jan/2024 → meses_proporcionais = 9 (MONTH FROM AGE + 1)'
);

-- 15. Junior: meses_proporcionais < 12 (admitido abr/2026)
SELECT ok(
  (SELECT meses_proporcionais < 12 AND meses_proporcionais >= 1 FROM folha.calc_13o(current_setting('test.junior_cid')::uuid, '2026-10-01', 2)),
  'calc_13o: Junior admitido abr/2026 → meses_proporcionais entre 1 e 11'
);

-- 16. Contrato inexistente deve falhar
SELECT throws_ok(
  $$SELECT * FROM folha.calc_13o('00000000-0000-0000-0000-000000000000'::uuid, '2026-10-01', 2)$$,
  'Contrato 00000000-0000-0000-0000-000000000000 não encontrado',
  'calc_13o: contrato inexistente gera exceção'
);

-- ===========================================================================
-- CALC_RESCISAO — 12 testes
-- ===========================================================================

-- 17. Função existe
SELECT ok(
  EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'calc_rescisao' AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'folha')),
  'Função folha.calc_rescisao existe'
);

-- 18. Rescisão sem justa causa: saldo_salário > 0
SELECT ok(
  (SELECT saldo_salario > 0 FROM folha.calc_rescisao(current_setting('test.senior_cid')::uuid, '2026-10-13', 'sem_justa_causa')),
  'calc_rescisao: sem_justa_causa → saldo_salario > 0'
);

-- 19. Rescisão sem justa causa: aviso_previo_indenizado = salário base
SELECT is(
  (SELECT aviso_previo_indenizado FROM folha.calc_rescisao(current_setting('test.senior_cid')::uuid, '2026-10-13', 'sem_justa_causa')),
  4500.00::numeric,
  'calc_rescisao: sem_justa_causa → aviso_previo = R$ 4.500,00'
);

-- 20. Rescisão sem justa causa: multa_fgts = 40% do salário (simplificado)
SELECT is(
  (SELECT multa_fgts FROM folha.calc_rescisao(current_setting('test.senior_cid')::uuid, '2026-10-13', 'sem_justa_causa')),
  1800.00::numeric,
  'calc_rescisao: sem_justa_causa → multa_fgts = R$ 1.800,00 (40%)'
);

-- 21. Rescisão sem justa causa: total_proventos > 0
SELECT ok(
  (SELECT total_proventos > 0 FROM folha.calc_rescisao(current_setting('test.senior_cid')::uuid, '2026-10-13', 'sem_justa_causa')),
  'calc_rescisao: sem_justa_causa → total_proventos > 0'
);

-- 22. Rescisão sem justa causa: liquido_rescisao = total_proventos - total_descontos
SELECT ok(
  (SELECT liquido_rescisao = total_proventos - total_descontos FROM folha.calc_rescisao(current_setting('test.senior_cid')::uuid, '2026-10-13', 'sem_justa_causa')),
  'calc_rescisao: liquido = proventos - descontos'
);

-- 23. Rescisão por pedido de demissão: aviso_previo = 0
SELECT is(
  (SELECT aviso_previo_indenizado FROM folha.calc_rescisao(current_setting('test.senior_cid')::uuid, '2026-10-13', 'pedido_demissao')),
  0.00::numeric,
  'calc_rescisao: pedido_demissao → aviso_previo = 0'
);

-- 24. Rescisão por pedido de demissão: multa_fgts = 0
SELECT is(
  (SELECT multa_fgts FROM folha.calc_rescisao(current_setting('test.senior_cid')::uuid, '2026-10-13', 'pedido_demissao')),
  0.00::numeric,
  'calc_rescisao: pedido_demissao → multa_fgts = 0'
);

-- 25. Rescisão por justa causa: aviso_previo = 0
SELECT is(
  (SELECT aviso_previo_indenizado FROM folha.calc_rescisao(current_setting('test.senior_cid')::uuid, '2026-10-13', 'justa_causa')),
  0.00::numeric,
  'calc_rescisao: justa_causa → aviso_previo = 0'
);

-- 26. Rescisão por justa causa: multa_fgts = 0
SELECT is(
  (SELECT multa_fgts FROM folha.calc_rescisao(current_setting('test.senior_cid')::uuid, '2026-10-13', 'justa_causa')),
  0.00::numeric,
  'calc_rescisao: justa_causa → multa_fgts = 0'
);

-- 27. Senior (>12m): ferias_vencidas > 0 na rescisão
SELECT ok(
  (SELECT ferias_vencidas > 0 FROM folha.calc_rescisao(current_setting('test.senior_cid')::uuid, '2026-10-13', 'sem_justa_causa')),
  'calc_rescisao: Senior >12m → ferias_vencidas > 0'
);

-- 28. Contrato inexistente deve falhar
SELECT throws_ok(
  $$SELECT * FROM folha.calc_rescisao('00000000-0000-0000-0000-000000000000'::uuid, '2026-10-13', 'sem_justa_causa')$$,
  'Contrato 00000000-0000-0000-0000-000000000000 não encontrado',
  'calc_rescisao: contrato inexistente gera exceção'
);

-- ---------------------------------------------------------------------------
-- Cleanup
-- ---------------------------------------------------------------------------
DELETE FROM folha.employment_contract WHERE account_id = 'e0000000-0000-0000-0000-000000000005' AND cargo IN ('Senior Tester', 'Junior Tester');
DELETE FROM folha.employee WHERE account_id = 'e0000000-0000-0000-0000-000000000005' AND cpf IN ('55555555555', '66666666666');

SELECT * FROM finish();
ROLLBACK;