-- DNEX Folha — Testes pgTAP de ACL pós-migration 0022 (revogação de execução pública).
-- Valida que anon/authenticated NÃO executam funções sensíveis e que
-- dnex_gestao_folha_worker executa todas. Também verifica que nenhuma função
-- SECURITY DEFINER do schema folha é executável por anon (salvo exceções justificadas).
-- Executar após migrations 0014–0022 aplicadas.
-- Rollback: ROLLBACK;
BEGIN;

-- Plano: 8 funções × 3 roles (anon, authenticated, worker) = 24
--       + 1 teste geral de varredura SECURITY DEFINER
--       Total: 25
SELECT plan(25);

-- ---------------------------------------------------------------------------
-- Helper: verificar se role tem privilégio EXECUTE em função
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION test.has_execute(p_schema text, p_func text, p_role text)
RETURNS boolean
LANGUAGE sql STABLE
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM information_schema.routine_privileges rp
    WHERE rp.routine_schema = p_schema
      AND rp.routine_name = p_func
      AND rp.grantee = p_role
      AND rp.privilege_type = 'EXECUTE'
  );
$$;

-- ---------------------------------------------------------------------------
-- 1-3. dispatch_folha_completa(uuid)
-- ---------------------------------------------------------------------------
SELECT ok(NOT test.has_execute('folha', 'dispatch_folha_completa', 'anon'),
  'anon NÃO executa dispatch_folha_completa(uuid)');
SELECT ok(NOT test.has_execute('folha', 'dispatch_folha_completa', 'authenticated'),
  'authenticated NÃO executa dispatch_folha_completa(uuid)');
SELECT ok(test.has_execute('folha', 'dispatch_folha_completa', 'dnex_gestao_folha_worker'),
  'dnex_gestao_folha_worker executa dispatch_folha_completa(uuid)');

-- ---------------------------------------------------------------------------
-- 4-6. dashboard_completo(uuid)
-- ---------------------------------------------------------------------------
SELECT ok(NOT test.has_execute('folha', 'dashboard_completo', 'anon'),
  'anon NÃO executa dashboard_completo(uuid)');
SELECT ok(NOT test.has_execute('folha', 'dashboard_completo', 'authenticated'),
  'authenticated NÃO executa dashboard_completo(uuid)');
SELECT ok(test.has_execute('folha', 'dashboard_completo', 'dnex_gestao_folha_worker'),
  'dnex_gestao_folha_worker executa dashboard_completo(uuid)');

-- ---------------------------------------------------------------------------
-- 7-9. build_esocial_s1200(uuid) — definida em 0020, deve seguir mesmo padrão
-- ---------------------------------------------------------------------------
SELECT ok(NOT test.has_execute('folha', 'build_esocial_s1200', 'anon'),
  'anon NÃO executa build_esocial_s1200(uuid)');
SELECT ok(NOT test.has_execute('folha', 'build_esocial_s1200', 'authenticated'),
  'authenticated NÃO executa build_esocial_s1200(uuid)');
SELECT ok(test.has_execute('folha', 'build_esocial_s1200', 'dnex_gestao_folha_worker'),
  'dnex_gestao_folha_worker executa build_esocial_s1200(uuid)');

-- ---------------------------------------------------------------------------
-- 10-12. build_esocial_s2200(uuid)
-- ---------------------------------------------------------------------------
SELECT ok(NOT test.has_execute('folha', 'build_esocial_s2200', 'anon'),
  'anon NÃO executa build_esocial_s2200(uuid)');
SELECT ok(NOT test.has_execute('folha', 'build_esocial_s2200', 'authenticated'),
  'authenticated NÃO executa build_esocial_s2200(uuid)');
SELECT ok(test.has_execute('folha', 'build_esocial_s2200', 'dnex_gestao_folha_worker'),
  'dnex_gestao_folha_worker executa build_esocial_s2200(uuid)');

-- ---------------------------------------------------------------------------
-- 13-15. build_contabil_folha(uuid)
-- ---------------------------------------------------------------------------
SELECT ok(NOT test.has_execute('folha', 'build_contabil_folha', 'anon'),
  'anon NÃO executa build_contabil_folha(uuid)');
SELECT ok(NOT test.has_execute('folha', 'build_contabil_folha', 'authenticated'),
  'authenticated NÃO executa build_contabil_folha(uuid)');
SELECT ok(test.has_execute('folha', 'build_contabil_folha', 'dnex_gestao_folha_worker'),
  'dnex_gestao_folha_worker executa build_contabil_folha(uuid)');

-- ---------------------------------------------------------------------------
-- 16-18. calc_inss(numeric, date) — função de cálculo core
-- ---------------------------------------------------------------------------
SELECT ok(NOT test.has_execute('folha', 'calc_inss', 'anon'),
  'anon NÃO executa calc_inss');
SELECT ok(NOT test.has_execute('folha', 'calc_inss', 'authenticated'),
  'authenticated NÃO executa calc_inss');
SELECT ok(test.has_execute('folha', 'calc_inss', 'dnex_gestao_folha_worker'),
  'dnex_gestao_folha_worker executa calc_inss');

-- ---------------------------------------------------------------------------
-- 19-21. calc_irrf(numeric, integer, boolean, date)
-- ---------------------------------------------------------------------------
SELECT ok(NOT test.has_execute('folha', 'calc_irrf', 'anon'),
  'anon NÃO executa calc_irrf');
SELECT ok(NOT test.has_execute('folha', 'calc_irrf', 'authenticated'),
  'authenticated NÃO executa calc_irrf');
SELECT ok(test.has_execute('folha', 'calc_irrf', 'dnex_gestao_folha_worker'),
  'dnex_gestao_folha_worker executa calc_irrf');

-- ---------------------------------------------------------------------------
-- 22-24. run_payroll_employee(uuid, uuid)
-- ---------------------------------------------------------------------------
SELECT ok(NOT test.has_execute('folha', 'run_payroll_employee', 'anon'),
  'anon NÃO executa run_payroll_employee');
SELECT ok(NOT test.has_execute('folha', 'run_payroll_employee', 'authenticated'),
  'authenticated NÃO executa run_payroll_employee');
SELECT ok(test.has_execute('folha', 'run_payroll_employee', 'dnex_gestao_folha_worker'),
  'dnex_gestao_folha_worker executa run_payroll_employee');

-- ---------------------------------------------------------------------------
-- 25. Varredura geral: nenhuma função SECURITY DEFINER do schema folha
--     deve ter EXECUTE concedido a anon.
--     Exceção justificada: NENHUMA. Todas as funções folha são internas
--     e devem ser acessadas apenas via dnex_gestao_folha_worker ou
--     dnex_gestao_data_owner. mask_cpf concede EXECUTE a authenticated
--     (migration 0014:257) mas NÃO a anon, portanto passa neste teste.
-- ---------------------------------------------------------------------------
SELECT is(
  (SELECT count(*)::int
   FROM information_schema.routine_privileges rp
   JOIN pg_proc p ON p.proname = rp.routine_name
   JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE rp.routine_schema = 'folha'
     AND rp.grantee = 'anon'
     AND rp.privilege_type = 'EXECUTE'
     AND p.prosecdef = true),
  0,
  'Nenhuma função SECURITY DEFINER do schema folha é executável por anon'
);

-- Cleanup helper
DROP FUNCTION IF EXISTS test.has_execute(text, text, text);

SELECT * FROM finish();
ROLLBACK;