-- DNEX Folha — Testes de integração da RPC folha.dashboard_completo
-- Valida retorno da função agregadora usada pela PaginaFolha no dnex-hub.
-- Executar após migrations 0014–0021 aplicadas.
-- Rollback: ROLLBACK; (não modifica dados persistentes)
BEGIN;
SELECT plan(12);

-- ---------------------------------------------------------------------------
-- Setup: tenant de teste com dados mínimos
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM folha.employee WHERE account_id = 'd0000000-0000-0000-0000-000000000004') THEN
    INSERT INTO folha.employee (account_id, cpf, nome_completo, data_nascimento)
    VALUES ('d0000000-0000-0000-0000-000000000004', '44444444444', 'Dashboard Test Employee', '1990-04-04');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM folha.employment_contract WHERE account_id = 'd0000000-0000-0000-0000-000000000004' AND cargo = 'Dashboard Tester') THEN
    INSERT INTO folha.employment_contract (account_id, employee_id, data_admissao, cargo, salario_base, regime_trabalho)
    SELECT 'd0000000-0000-0000-0000-000000000004', employee_id, '2024-01-01', 'Dashboard Tester', 5000.00, 'clt'
    FROM folha.employee WHERE account_id = 'd0000000-0000-0000-0000-000000000004' AND cpf = '44444444444';
  END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- 1. RPC existe e é executável
-- ---------------------------------------------------------------------------
SELECT ok(
  EXISTS(SELECT 1 FROM pg_proc WHERE proname = 'dashboard_completo' AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'folha')),
  'Função folha.dashboard_completo existe'
);

-- ---------------------------------------------------------------------------
-- 2. RPC retorna todos os campos esperados
-- ---------------------------------------------------------------------------
SELECT ok(
  (SELECT total_empregados_ativos IS NOT NULL FROM folha.dashboard_completo('d0000000-0000-0000-0000-000000000004')),
  'dashboard_completo retorna total_empregados_ativos'
);

SELECT ok(
  (SELECT custo_folha_mes_centavos IS NOT NULL FROM folha.dashboard_completo('d0000000-0000-0000-0000-000000000004')),
  'dashboard_completo retorna custo_folha_mes_centavos'
);

SELECT ok(
  (SELECT encargos_patronais_mes_centavos IS NOT NULL FROM folha.dashboard_completo('d0000000-0000-0000-0000-000000000004')),
  'dashboard_completo retorna encargos_patronais_mes_centavos'
);

SELECT ok(
  (SELECT competencias_abertas IS NOT NULL FROM folha.dashboard_completo('d0000000-0000-0000-0000-000000000004')),
  'dashboard_completo retorna competencias_abertas'
);

SELECT ok(
  (SELECT distribuicao_regime IS NOT NULL FROM folha.dashboard_completo('d0000000-0000-0000-0000-000000000004')),
  'dashboard_completo retorna distribuicao_regime'
);

SELECT ok(
  (SELECT evolucao_custo_6m IS NOT NULL FROM folha.dashboard_completo('d0000000-0000-0000-0000-000000000004')),
  'dashboard_completo retorna evolucao_custo_6m'
);

-- ---------------------------------------------------------------------------
-- 3. Total de empregados ativos >= 1 (dados de teste inseridos)
-- ---------------------------------------------------------------------------
SELECT ok(
  (SELECT total_empregados_ativos >= 1 FROM folha.dashboard_completo('d0000000-0000-0000-0000-000000000004')),
  'total_empregados_ativos >= 1 para tenant com contrato ativo'
);

-- ---------------------------------------------------------------------------
-- 4. distribuicao_regime é array JSON válido
-- ---------------------------------------------------------------------------
SELECT ok(
  (SELECT jsonb_typeof(distribuicao_regime) = 'array' FROM folha.dashboard_completo('d0000000-0000-0000-0000-000000000004')),
  'distribuicao_regime é array JSONB'
);

-- ---------------------------------------------------------------------------
-- 5. evolucao_custo_6m é array JSON válido
-- ---------------------------------------------------------------------------
SELECT ok(
  (SELECT jsonb_typeof(evolucao_custo_6m) = 'array' FROM folha.dashboard_completo('d0000000-0000-0000-0000-000000000004')),
  'evolucao_custo_6m é array JSONB'
);

-- ---------------------------------------------------------------------------
-- 6. Tenant sem dados retorna zeros/arrays vazios (não erro)
-- ---------------------------------------------------------------------------
SELECT ok(
  (SELECT total_empregados_ativos = 0 FROM folha.dashboard_completo('ffffffff-ffff-ffff-ffff-ffffffffffff')),
  'Tenant inexistente retorna total_empregados_ativos = 0'
);

SELECT is(
  (SELECT distribuicao_regime FROM folha.dashboard_completo('ffffffff-ffff-ffff-ffff-ffffffffffff')),
  '[]'::jsonb,
  'Tenant inexistente retorna distribuicao_regime vazio'
);

-- ---------------------------------------------------------------------------
-- Cleanup
-- ---------------------------------------------------------------------------
DELETE FROM folha.employment_contract WHERE account_id = 'd0000000-0000-0000-0000-000000000004' AND cargo = 'Dashboard Tester';
DELETE FROM folha.employee WHERE account_id = 'd0000000-0000-0000-0000-000000000004' AND cpf = '44444444444';

SELECT * FROM finish();
ROLLBACK;