-- DNEX Folha — Testes pgTAP para Eventos de Vida (férias, 13º, rescisão)
-- Valida funções calc_ferias, calc_13o, calc_rescisao criadas na migration 0019
-- e corrigidas na migration 0023.
-- Executar após migrations 0014–0023 aplicadas.
-- Rollback: ROLLBACK; (não modifica dados persistentes)
--
-- NOTA (15/11/2026): Após a migration 0023, as assinaturas de calc_ferias e
-- calc_rescisao mudaram. Testes que dependiam da assinatura antiga foram
-- comentados com "-- OBSOLETO-0023" e substituídos por verificações estruturais.
-- Os testes dourados com valores exatos estão em 0023_eventos_vida_dourados.pgtap.sql.
BEGIN;
SELECT plan(22);

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
-- CALC_FERIAS — 4 testes (assinatura nova pós-0023)
-- ===========================================================================

-- 1. Função existe
SELECT ok(
  EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'calc_ferias' AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'folha')),
  'Função folha.calc_ferias existe'
);

-- 2. calc_ferias retorna tipo composto com campo valor_ferias
SELECT ok(
  EXISTS(SELECT 1 FROM pg_attribute a JOIN pg_type t ON a.attrelid = t.typrelid
         JOIN pg_namespace n ON t.typnamespace = n.oid
         WHERE n.nspname = 'folha' AND t.typname = 'calc_ferias_result'
         AND a.attname = 'valor_ferias'),
  'calc_ferias: tipo de retorno tem campo valor_ferias'
);

-- 3. Contrato inexistente deve falhar (nova assinatura: 8 parâmetros)
SELECT throws_ok(
  $$SELECT * FROM folha.calc_ferias('00000000-0000-0000-0000-000000000000'::uuid, '2026-10-01', 30, 0, 0, '2024-01-01', '2025-01-01', 4500.00)$$,
  NULL,
  NULL,
  'calc_ferias: contrato inexistente gera exceção'
);

-- 4. Tabela payroll_parameter existe (criada na migration 0023)
SELECT ok(
  EXISTS(SELECT 1 FROM information_schema.tables WHERE table_schema = 'folha' AND table_name = 'payroll_parameter'),
  'Tabela folha.payroll_parameter existe (migration 0023)'
);

-- OBSOLETO-0023: testes 2-7 da versão anterior usavam assinatura antiga
-- calc_ferias(uuid, date) que não existe mais após migration 0023.
-- Os casos dourados com valores exatos estão em 0023_eventos_vida_dourados.pgtap.sql.

-- ===========================================================================
-- CALC_13O — 7 testes
-- ===========================================================================

-- 5. Função existe
SELECT ok(
  EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'calc_13o' AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'folha')),
  'Função folha.calc_13o existe'
);

-- 6. Senior 1ª parcela: sem descontos
SELECT is(
  (SELECT inss FROM folha.calc_13o(current_setting('test.senior_cid')::uuid, '2026-10-01', 1)),
  0.00::numeric,
  'calc_13o: 1ª parcela → INSS = 0 (sem descontos)'
);

-- 7. Senior 1ª parcela: líquido = bruto
SELECT is(
  (SELECT valor_liquido FROM folha.calc_13o(current_setting('test.senior_cid')::uuid, '2026-10-01', 1)),
  (SELECT valor_bruto FROM folha.calc_13o(current_setting('test.senior_cid')::uuid, '2026-10-01', 1)),
  'calc_13o: 1ª parcela → líquido = bruto'
);

-- 8. Senior 2ª parcela: INSS > 0
SELECT ok(
  (SELECT inss > 0 FROM folha.calc_13o(current_setting('test.senior_cid')::uuid, '2026-10-01', 2)),
  'calc_13o: 2ª parcela → INSS > 0'
);

-- 9. Senior 2ª parcela: líquido < bruto
SELECT ok(
  (SELECT valor_liquido < valor_bruto FROM folha.calc_13o(current_setting('test.senior_cid')::uuid, '2026-10-01', 2)),
  'calc_13o: 2ª parcela → líquido < bruto (descontos aplicados)'
);

-- OBSOLETO-0023: teste 14 antigo esperava meses_proporcionais=9 usando
-- EXTRACT(MONTH FROM AGE)+1, que é o BUG T1 corrigido na migration 0023.
-- A função agora calcula avos por ano civil com fração ≥15 dias.
-- Senior admitido 15/01/2024 em competência 2026-10-01 → 12 avos (ano inteiro).
SELECT is(
  (SELECT meses_proporcionais FROM folha.calc_13o(current_setting('test.senior_cid')::uuid, '2026-10-01', 2)),
  12,
  'calc_13o: Senior admitido jan/2024 → 12 avos em out/2026 (CORRIGIDO T1)'
);

-- 11. Contrato inexistente deve falhar
SELECT throws_ok(
  $$SELECT * FROM folha.calc_13o('00000000-0000-0000-0000-000000000000'::uuid, '2026-10-01', 2)$$,
  NULL,
  NULL,
  'calc_13o: contrato inexistente gera exceção'
);

-- ===========================================================================
-- CALC_RESCISAO — 8 testes (assinatura nova pós-0023)
-- ===========================================================================

-- 12. Função existe
SELECT ok(
  EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'calc_rescisao' AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'folha')),
  'Função folha.calc_rescisao existe'
);

-- OBSOLETO-0023: testes 18-27 da versão anterior usavam assinatura antiga
-- calc_rescisao(uuid, date, text) com 3 parâmetros. A nova assinatura tem
-- 10 parâmetros. Além disso, os testes 19 e 20 codificavam erros:
--   - aviso_previo fixo em 4500 (deveria ser proporcional: 30+3/ano)
--   - multa_fgts = 1800 dentro dos proventos (E3: deve ser FORA do líquido)
-- Os casos dourados com valores exatos estão em 0023_eventos_vida_dourados.pgtap.sql.

-- 13. Rescisão sem justa causa: saldo_salário > 0 (nova assinatura)
SELECT ok(
  (SELECT saldo_salario > 0 FROM folha.calc_rescisao(
    current_setting('test.senior_cid')::uuid, '2026-10-13', 'sem_justa_causa',
    'indenizado', 0, 4500.00, 0, 0, 0, 0)),
  'calc_rescisao: sem_justa_causa → saldo_salario > 0'
);

-- 14. Rescisão sem justa causa: aviso_previo_valor > 0 (proporcional, não fixo)
SELECT ok(
  (SELECT aviso_previo_valor > 0 FROM folha.calc_rescisao(
    current_setting('test.senior_cid')::uuid, '2026-10-13', 'sem_justa_causa',
    'indenizado', 0, 4500.00, 0, 0, 0, 0)),
  'calc_rescisao: sem_justa_causa → aviso_previo_valor > 0 (proporcional CORRIGIDO E2)'
);

-- 15. Rescisão sem justa causa: total_proventos > 0
SELECT ok(
  (SELECT total_proventos > 0 FROM folha.calc_rescisao(
    current_setting('test.senior_cid')::uuid, '2026-10-13', 'sem_justa_causa',
    'indenizado', 0, 4500.00, 0, 0, 0, 0)),
  'calc_rescisao: sem_justa_causa → total_proventos > 0'
);

-- 16. Rescisão por pedido de demissão: aviso_previo_valor = 0
SELECT is(
  (SELECT aviso_previo_valor FROM folha.calc_rescisao(
    current_setting('test.senior_cid')::uuid, '2026-10-13', 'pedido_demissao',
    NULL, 0, 4500.00, 0, 0, 0, 0)),
  0.00::numeric,
  'calc_rescisao: pedido_demissao → aviso_previo_valor = 0'
);

-- 17. Rescisão por justa causa: multa_fgts = 0
SELECT is(
  (SELECT multa_fgts FROM folha.calc_rescisao(
    current_setting('test.senior_cid')::uuid, '2026-10-13', 'justa_causa',
    NULL, 0, 4500.00, 0, 0, 0, 0)),
  0.00::numeric,
  'calc_rescisao: justa_causa → multa_fgts = 0'
);

-- 18. Rescisão por justa causa: aviso_previo_valor = 0
SELECT is(
  (SELECT aviso_previo_valor FROM folha.calc_rescisao(
    current_setting('test.senior_cid')::uuid, '2026-10-13', 'justa_causa',
    NULL, 0, 4500.00, 0, 0, 0, 0)),
  0.00::numeric,
  'calc_rescisao: justa_causa → aviso_previo_valor = 0'
);

-- 19. Contrato inexistente deve falhar (nova assinatura)
SELECT throws_ok(
  $$SELECT * FROM folha.calc_rescisao('00000000-0000-0000-0000-000000000000'::uuid, '2026-10-13', 'sem_justa_causa', NULL, 0, 4500.00, 0, 0, 0, 0)$$,
  NULL,
  NULL,
  'calc_rescisao: contrato inexistente gera exceção'
);

-- ---------------------------------------------------------------------------
-- Cleanup
-- ---------------------------------------------------------------------------
DELETE FROM folha.employment_contract WHERE account_id = 'e0000000-0000-0000-0000-000000000005' AND cargo IN ('Senior Tester', 'Junior Tester');
DELETE FROM folha.employee WHERE account_id = 'e0000000-0000-0000-0000-000000000005' AND cpf IN ('55555555555', '66666666666');

SELECT * FROM finish();
ROLLBACK;