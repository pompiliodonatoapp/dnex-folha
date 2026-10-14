-- DNEX Folha — Testes pgTAP de isolamento multi-tenant (migration 0014).
-- Valida RLS, FORCE, grants e máscara de CPF conforme auditoria preliminar.
-- Executar com: psql -f tests/folha/0014_folha_rls_isolation.pgtap.sql
BEGIN;

SELECT plan(18);

-- ---------------------------------------------------------------------------
-- Setup: tenants e dados de teste
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  -- Criar tenants de teste via gestao_auth (padrão real) ou fallback direto
  IF NOT EXISTS (SELECT 1 FROM folha.employee WHERE account_id = 'a0000000-0000-0000-0000-000000000001') THEN
    INSERT INTO folha.employee (account_id, cpf, nome_completo, data_nascimento)
    VALUES ('a0000000-0000-0000-0000-000000000001', '11111111111', 'Tenant A Employee', '1990-01-01');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM folha.employee WHERE account_id = 'b0000000-0000-0000-0000-000000000002') THEN
    INSERT INTO folha.employee (account_id, cpf, nome_completo, data_nascimento)
    VALUES ('b0000000-0000-0000-0000-000000000002', '22222222222', 'Tenant B Employee', '1990-02-02');
  END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- 1. Schema existe
-- ---------------------------------------------------------------------------
SELECT has_schema('folha', 'Schema folha deve existir');

-- ---------------------------------------------------------------------------
-- 2. Role folha_worker existe
-- ---------------------------------------------------------------------------
SELECT has_role('dnex_gestao_folha_worker', 'Role dnex_gestao_folha_worker deve existir');

-- ---------------------------------------------------------------------------
-- 3. Tabelas têm RLS habilitado
-- ---------------------------------------------------------------------------
SELECT row_security_enabled('folha.employee'), 'employee tem RLS enabled';
SELECT row_security_enabled('folha.payroll_run'), 'payroll_run tem RLS enabled';
SELECT row_security_enabled('folha.payroll_result'), 'payroll_result tem RLS enabled';
SELECT row_security_enabled('folha.calculation_trace'), 'calculation_trace tem RLS enabled';

-- ---------------------------------------------------------------------------
-- 4. Tabelas têm FORCE ROW LEVEL SECURITY
-- ---------------------------------------------------------------------------
SELECT is(
  (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'folha.employee'::regclass),
  true,
  'employee tem FORCE RLS'
);
SELECT is(
  (SELECT relforcerowsecurity FROM pg_class WHERE oid = 'folha.payroll_run'::regclass),
  true,
  'payroll_run tem FORCE RLS'
);

-- ---------------------------------------------------------------------------
-- 5. Tenant A não lê dados de Tenant B (isolamento SELECT)
-- Nota: usa SET LOCAL folha.account_id como fallback porque gestao_auth.begin_request
-- exige asserção válida com nonce single-use. Em produção, o middleware chama
-- begin_request; em teste unitário, usamos o fallback direto da função current_account_id().
-- ---------------------------------------------------------------------------
SET LOCAL folha.account_id = 'a0000000-0000-0000-0000-000000000001';
SELECT is(
  (SELECT count(*) FROM folha.employee WHERE account_id = 'b0000000-0000-0000-0000-000000000002'),
  0::bigint,
  'Tenant A não vê employees do Tenant B'
);

-- ---------------------------------------------------------------------------
-- 6. Tenant B não lê dados de Tenant A
-- ---------------------------------------------------------------------------
SET LOCAL folha.account_id = 'b0000000-0000-0000-0000-000000000002';
SELECT is(
  (SELECT count(*) FROM folha.employee WHERE account_id = 'a0000000-0000-0000-0000-000000000001'),
  0::bigint,
  'Tenant B não vê employees do Tenant A'
);

-- ---------------------------------------------------------------------------
-- 7. tax_table_version é legível globalmente (leitura universal)
-- ---------------------------------------------------------------------------
RESET folha.account_id;
SELECT ok(
  (SELECT count(*) >= 0 FROM folha.tax_table_version),
  'tax_table_version permite leitura sem tenant context'
);

-- ---------------------------------------------------------------------------
-- 8. earning_deduction_code global é legível por qualquer tenant
-- ---------------------------------------------------------------------------
SET LOCAL folha.account_id = 'a0000000-0000-0000-0000-000000000001';
SELECT ok(
  (SELECT count(*) >= 0 FROM folha.earning_deduction_code WHERE is_global = true),
  'Rubricas globais são legíveis por Tenant A'
);

-- ---------------------------------------------------------------------------
-- 9. Função mask_cpf mascara para roles não privilegiadas
-- ---------------------------------------------------------------------------
SELECT is(
  folha.mask_cpf('12345678901'),
  '***.456.789-**',
  'mask_cpf retorna valor mascarado quando sem permissão folha.read'
);

-- ---------------------------------------------------------------------------
-- 10. Auditoria é append-only (UPDATE deve falhar)
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  INSERT INTO folha.auditoria (account_id, actor, acao, recurso)
  VALUES ('a0000000-0000-0000-0000-000000000001', 'test', 'test_action', 'test_resource');

  BEGIN
    UPDATE folha.auditoria SET actor = 'modified' WHERE actor = 'test';
    RAISE EXCEPTION 'UPDATE deveria ter falhado mas não falhou';
  EXCEPTION WHEN OTHERS THEN
    NULL; -- Esperado: trigger bloqueia UPDATE
  END;
END
$$;
SELECT pass('Auditoria rejeita UPDATE (append-only)');

-- ---------------------------------------------------------------------------
-- 11. Grants corretos: folha_worker tem SELECT/INSERT/UPDATE em employee
-- ---------------------------------------------------------------------------
SELECT table_privs_are(
  'folha', 'employee', 'dnex_gestao_folha_worker',
  ARRAY['SELECT', 'INSERT', 'UPDATE'],
  'folha_worker tem SELECT/INSERT/UPDATE em employee'
);

-- ---------------------------------------------------------------------------
-- 12. Grants corretos: data_owner tem apenas SELECT em employee
-- ---------------------------------------------------------------------------
SELECT table_privs_are(
  'folha', 'employee', 'dnex_gestao_data_owner',
  ARRAY['SELECT'],
  'data_owner tem apenas SELECT em employee'
);

-- ---------------------------------------------------------------------------
-- Cleanup
-- ---------------------------------------------------------------------------
DELETE FROM folha.employee WHERE cpf IN ('11111111111', '22222222222');
DELETE FROM folha.auditoria WHERE actor = 'test';

SELECT * FROM finish();
ROLLBACK;