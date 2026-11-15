-- DNEX Folha — Testes pgTAP de isolamento multi-tenant (migration 0014).
-- Valida RLS, FORCE, grants e máscara de CPF conforme auditoria preliminar.
-- Executar com: psql -f tests/folha/0014_folha_rls_isolation.pgtap.sql
BEGIN;

SELECT plan(19);

-- ---------------------------------------------------------------------------
-- Setup: tenants e dados de teste
-- ---------------------------------------------------------------------------
DO $$
BEGIN
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
SELECT ok((SELECT relrowsecurity FROM pg_class WHERE oid = 'folha.employee'::regclass), 'employee tem RLS enabled');
SELECT ok((SELECT relrowsecurity FROM pg_class WHERE oid = 'folha.payroll_run'::regclass), 'payroll_run tem RLS enabled');
SELECT ok((SELECT relrowsecurity FROM pg_class WHERE oid = 'folha.payroll_result'::regclass), 'payroll_result tem RLS enabled');
SELECT ok((SELECT relrowsecurity FROM pg_class WHERE oid = 'folha.calculation_trace'::regclass), 'calculation_trace tem RLS enabled');

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
-- A conta da sessão vem da reserva por parâmetro (folha.account_id), que desde a
-- migration 0024 só vale para o papel de teste dnex_folha_ci (membro do worker, sem
-- BYPASSRLS). O caminho de produção, pela asserção de gestao_auth, é exercido em
-- tests/folha/0024_empregador_parametros.pgtap.sql.
-- O teste roda como superusuario, que ignora RLS mesmo com FORCE: a leitura e feita
-- com o papel de teste e o resultado e conferido depois de voltar ao papel original
-- (as funcoes do pgTAP nao sao executaveis pelo papel de teste).
-- ---------------------------------------------------------------------------
SET LOCAL folha.account_id = 'a0000000-0000-0000-0000-000000000001';
SET LOCAL ROLE dnex_folha_ci;
SELECT count(*) AS proprios_a FROM folha.employee WHERE account_id = 'a0000000-0000-0000-0000-000000000001' \gset
SELECT count(*) AS alheios_a FROM folha.employee WHERE account_id = 'b0000000-0000-0000-0000-000000000002' \gset
RESET ROLE;
SELECT is(:proprios_a::bigint, 1::bigint, 'Tenant A ve o proprio employee (o teste nao passa por tabela vazia)');
SELECT is(
  :alheios_a::bigint,
  0::bigint,
  'Tenant A não vê employees do Tenant B'
);

-- ---------------------------------------------------------------------------
-- 6. Tenant B não lê dados de Tenant A (e vê o próprio)
-- ---------------------------------------------------------------------------
SET LOCAL folha.account_id = 'b0000000-0000-0000-0000-000000000002';
SET LOCAL ROLE dnex_folha_ci;
SELECT count(*) AS proprios_b FROM folha.employee WHERE account_id = 'b0000000-0000-0000-0000-000000000002' \gset
SELECT count(*) AS alheios_b FROM folha.employee WHERE account_id = 'a0000000-0000-0000-0000-000000000001' \gset
RESET ROLE;
SELECT is(:proprios_b::bigint, 1::bigint, 'Tenant B ve o proprio employee');
SELECT is(
  :alheios_b::bigint,
  0::bigint,
  'Tenant B não vê employees do Tenant A'
);

-- ---------------------------------------------------------------------------
-- 7. tax_table_version é legível sem conta na sessão (leitura universal)
--    Lida com o worker, sem asserção e sem reserva: precisa enxergar as linhas
--    semeadas pela 0015 (o superusuário as conta sem RLS, como referência).
-- ---------------------------------------------------------------------------
RESET folha.account_id;
SELECT count(*) AS tabelas_total FROM folha.tax_table_version \gset
SET LOCAL ROLE dnex_gestao_folha_worker;
SELECT count(*) AS tabelas_worker FROM folha.tax_table_version \gset
RESET ROLE;
SELECT ok(
  :tabelas_total > 0 AND :tabelas_worker = :tabelas_total,
  'tax_table_version: worker sem conta na sessão lê todas as linhas semeadas'
);

-- ---------------------------------------------------------------------------
-- 8. Rubricas globais são legíveis por qualquer tenant
--    Tenant A, sem rubrica própria, enxerga exatamente as globais da 0017.
-- ---------------------------------------------------------------------------
SELECT count(*) AS globais_total FROM folha.earning_deduction_code WHERE is_global \gset
SET LOCAL folha.account_id = 'a0000000-0000-0000-0000-000000000001';
SET LOCAL ROLE dnex_folha_ci;
SELECT count(*) AS globais_a FROM folha.earning_deduction_code \gset
RESET ROLE;
RESET folha.account_id;
SELECT ok(
  :globais_total > 0 AND :globais_a = :globais_total,
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
-- 10. Auditoria é append-only (UPDATE deve falhar com a exceção do trigger)
-- ---------------------------------------------------------------------------
INSERT INTO folha.auditoria (account_id, actor, acao, recurso)
VALUES ('a0000000-0000-0000-0000-000000000001', 'test', 'test_action', 'test_resource');

SELECT throws_ok(
  $$UPDATE folha.auditoria SET actor = 'modified' WHERE actor = 'test'$$,
  'P0001',
  'folha.auditoria é append-only: UPDATE e DELETE são proibidos',
  'Auditoria rejeita UPDATE (append-only)'
);

-- ---------------------------------------------------------------------------
-- 11. Worker NÃO tem BYPASSRLS nem SUPERUSER (as policies valem para ele)
-- ---------------------------------------------------------------------------
SELECT ok(
  (SELECT NOT rolbypassrls AND NOT rolsuper FROM pg_roles WHERE rolname = 'dnex_gestao_folha_worker'),
  'dnex_gestao_folha_worker NÃO tem BYPASSRLS'
);

-- ---------------------------------------------------------------------------
-- 12. Grants corretos: folha_worker tem SELECT/INSERT/UPDATE em employee
-- ---------------------------------------------------------------------------
SELECT table_privs_are(
  'folha', 'employee', 'dnex_gestao_folha_worker',
  ARRAY['SELECT', 'INSERT', 'UPDATE'],
  'folha_worker tem SELECT/INSERT/UPDATE em employee'
);

-- ---------------------------------------------------------------------------
-- 13. Grants corretos: data_owner tem apenas SELECT em employee
-- ---------------------------------------------------------------------------
SELECT table_privs_are(
  'folha', 'employee', 'dnex_gestao_data_owner',
  ARRAY['SELECT'],
  'data_owner tem apenas SELECT em employee'
);

-- ---------------------------------------------------------------------------
-- Cleanup
-- ---------------------------------------------------------------------------
-- Sem DELETE: a auditoria e append-only; a transacao inteira e desfeita.

SELECT * FROM finish();
ROLLBACK;
