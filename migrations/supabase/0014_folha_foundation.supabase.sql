-- DNEX Folha — Fase 1: fundação do schema folha com isolamento multi-tenant.
-- Cria schema, role, tabelas mestras, catálogo de rubricas, tabelas de versão,
-- RLS com FORCE, função de contexto e máscara de dado sensível.
-- Rollback: DROP SCHEMA folha CASCADE; DROP ROLE dnex_gestao_folha_worker;
BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Schema e role
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS folha;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dnex_gestao_folha_worker') THEN
    CREATE ROLE dnex_gestao_folha_worker NOLOGIN;
  END IF;
END
$$;

REVOKE ALL ON SCHEMA folha FROM PUBLIC, authenticated, service_role;
GRANT USAGE ON SCHEMA folha TO dnex_gestao_folha_worker;
GRANT USAGE ON SCHEMA folha TO dnex_gestao_data_owner;

-- ---------------------------------------------------------------------------
-- 2. Extensão para criptografia de PII/saúde (fallback se Vault não disponível)
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- ---------------------------------------------------------------------------
-- 3. Função de contexto de tenant (padrão gestao_auth)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION folha.current_account_id() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, gestao_auth
AS $$
  SELECT COALESCE(
    (SELECT account_id FROM gestao_auth.access_assertion
      WHERE assertion_id = NULLIF(current_setting('dnex.context_nonce', true), '')::uuid
        AND consumed_at IS NULL
        AND revoked_at IS NULL
        AND expires_at > now()
      LIMIT 1),
    NULLIF(current_setting('folha.account_id', true), '')::uuid
  );
$$;

REVOKE ALL ON FUNCTION folha.current_account_id() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION folha.current_account_id() TO dnex_gestao_folha_worker;
GRANT EXECUTE ON FUNCTION folha.current_account_id() TO dnex_gestao_data_owner;

-- ---------------------------------------------------------------------------
-- 4. Tabelas mestras
-- ---------------------------------------------------------------------------
CREATE TABLE folha.employee (
  employee_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  cpf character(11) NOT NULL,
  nome_completo text NOT NULL,
  data_nascimento date NOT NULL,
  sexo char(1) CHECK (sexo IN ('M', 'F')),
  email text,
  telefone text,
  bank_account_encrypted bytea,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (account_id, cpf)
);

CREATE TABLE folha.employment_contract (
  contract_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  employee_id uuid NOT NULL REFERENCES folha.employee(employee_id),
  data_admissao date NOT NULL,
  data_demissao date,
  cargo text NOT NULL,
  salario_base numeric(12,2) NOT NULL,
  regime_trabalho text NOT NULL CHECK (regime_trabalho IN ('clt', 'pj', 'estagio', 'aprendiz')),
  jornada_semanal integer NOT NULL DEFAULT 44,
  cofre_certificate_ref uuid,
  status text NOT NULL DEFAULT 'ativo' CHECK (status IN ('ativo', 'inativo', 'afastado')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE folha.payroll_run (
  run_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  competencia date NOT NULL,
  status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'calculating', 'calculated', 'approved', 'closed', 'cancelled')),
  total_proventos numeric(14,2),
  total_descontos numeric(14,2),
  total_liquido numeric(14,2),
  total_encargos_patronais numeric(14,2),
  calculado_em timestamptz,
  aprovado_em timestamptz,
  fechado_em timestamptz,
  created_by text,
  approved_by text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (account_id, competencia)
);

CREATE TABLE folha.payroll_result (
  result_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id uuid NOT NULL REFERENCES folha.payroll_run(run_id),
  account_id uuid NOT NULL,
  employee_id uuid NOT NULL REFERENCES folha.employee(employee_id),
  contract_id uuid NOT NULL REFERENCES folha.employment_contract(contract_id),
  total_proventos numeric(12,2) NOT NULL,
  total_descontos numeric(12,2) NOT NULL,
  liquido numeric(12,2) NOT NULL,
  inss_empregado numeric(12,2) NOT NULL,
  irrf numeric(12,2) NOT NULL,
  fgts numeric(12,2) NOT NULL,
  inss_patronal numeric(12,2),
  rat numeric(12,2),
  terceiros numeric(12,2),
  calculation_hash text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE folha.calculation_trace (
  trace_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  result_id uuid NOT NULL REFERENCES folha.payroll_result(result_id),
  account_id uuid NOT NULL,
  step_order integer NOT NULL,
  rubrica_code text NOT NULL,
  descricao text NOT NULL,
  base_calculo numeric(12,2),
  aliquota numeric(8,4),
  valor numeric(12,2) NOT NULL,
  tipo text NOT NULL CHECK (tipo IN ('provento', 'desconto', 'informativo', 'encargo')),
  rule_version_id uuid,
  tax_table_version_id uuid,
  detail_json jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- 5. Catálogo de rubricas e regras versionadas
-- ---------------------------------------------------------------------------
CREATE TABLE folha.earning_deduction_code (
  code_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid,
  codigo text NOT NULL,
  descricao text NOT NULL,
  natureza text NOT NULL CHECK (natureza IN ('provento', 'desconto', 'informativo', 'encargo')),
  incidencia_inss boolean NOT NULL DEFAULT false,
  incidencia_irrf boolean NOT NULL DEFAULT false,
  incidencia_fgts boolean NOT NULL DEFAULT false,
  is_global boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (account_id, codigo)
);

CREATE TABLE folha.payroll_rule_version (
  rule_version_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  code_id uuid NOT NULL REFERENCES folha.earning_deduction_code(code_id),
  valid_from timestamptz NOT NULL,
  valid_until timestamptz,
  formula text,
  parameters jsonb,
  source_url text,
  source_hash text,
  captured_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE folha.tax_table_version (
  tax_table_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tipo text NOT NULL CHECK (tipo IN ('inss', 'irrf', 'fgts', 'salario_minimo', 'salario_familia')),
  vigencia_inicio date NOT NULL,
  vigencia_fim date,
  tabela_json jsonb NOT NULL,
  source_url text NOT NULL,
  source_hash text NOT NULL,
  captured_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tipo, vigencia_inicio)
);

CREATE TABLE folha.collective_agreement (
  agreement_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  sindicato text NOT NULL,
  categoria text NOT NULL,
  vigencia_inicio date NOT NULL,
  vigencia_fim date NOT NULL,
  clausulas_json jsonb NOT NULL,
  source_url text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE folha.benefit (
  benefit_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  employee_id uuid NOT NULL REFERENCES folha.employee(employee_id),
  tipo text NOT NULL CHECK (tipo IN ('vale_transporte', 'vale_refeicao', 'plano_saude', 'plano_odontologico', 'seguro_vida', 'outro')),
  valor numeric(12,2) NOT NULL,
  desconto_empregado numeric(12,2) NOT NULL DEFAULT 0,
  inicio_vigencia date NOT NULL,
  fim_vigencia date,
  provider_name text,
  health_plan_data_encrypted bytea,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- 6. Auditoria append-only
-- ---------------------------------------------------------------------------
CREATE TABLE folha.auditoria (
  auditoria_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  account_id uuid NOT NULL,
  actor text NOT NULL,
  acao text NOT NULL,
  recurso text NOT NULL,
  recurso_id uuid,
  correlation_id uuid,
  detalhe jsonb,
  criado_em timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION folha.bloquear_mutacao_auditoria() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'folha.auditoria é append-only: UPDATE e DELETE são proibidos';
END
$$;

CREATE TRIGGER auditoria_append_only
  BEFORE UPDATE OR DELETE ON folha.auditoria
  FOR EACH ROW EXECUTE FUNCTION folha.bloquear_mutacao_auditoria();

-- ---------------------------------------------------------------------------
-- 7. Função de máscara para dado sensível
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION folha.mask_cpf(p_cpf text) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha, gestao_auth
AS $$
  SELECT CASE
    WHEN gestao_auth.has_permission('folha.read', folha.current_account_id(), NULL, NULL)
      AND current_user IN ('dnex_gestao_folha_worker', 'dnex_gestao_data_owner')
    THEN p_cpf
    ELSE '***.' || substring(p_cpf from 4 for 3) || '.' || substring(p_cpf from 7 for 3) || '-**'
  END;
$$;

REVOKE ALL ON FUNCTION folha.mask_cpf(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION folha.mask_cpf(text) TO dnex_gestao_folha_worker;
GRANT EXECUTE ON FUNCTION folha.mask_cpf(text) TO dnex_gestao_data_owner;
GRANT EXECUTE ON FUNCTION folha.mask_cpf(text) TO authenticated;

-- ---------------------------------------------------------------------------
-- 8. RLS — ENABLE + FORCE em todas as tabelas tenant-scoped
-- ---------------------------------------------------------------------------

-- employee
ALTER TABLE folha.employee ENABLE ROW LEVEL SECURITY;
ALTER TABLE folha.employee FORCE ROW LEVEL SECURITY;
CREATE POLICY employee_isolamento ON folha.employee
  USING (account_id = folha.current_account_id())
  WITH CHECK (account_id = folha.current_account_id());

-- employment_contract
ALTER TABLE folha.employment_contract ENABLE ROW LEVEL SECURITY;
ALTER TABLE folha.employment_contract FORCE ROW LEVEL SECURITY;
CREATE POLICY contract_isolamento ON folha.employment_contract
  USING (account_id = folha.current_account_id())
  WITH CHECK (account_id = folha.current_account_id());

-- payroll_run
ALTER TABLE folha.payroll_run ENABLE ROW LEVEL SECURITY;
ALTER TABLE folha.payroll_run FORCE ROW LEVEL SECURITY;
CREATE POLICY run_isolamento ON folha.payroll_run
  USING (account_id = folha.current_account_id())
  WITH CHECK (account_id = folha.current_account_id());

-- payroll_result
ALTER TABLE folha.payroll_result ENABLE ROW LEVEL SECURITY;
ALTER TABLE folha.payroll_result FORCE ROW LEVEL SECURITY;
CREATE POLICY result_isolamento ON folha.payroll_result
  USING (account_id = folha.current_account_id())
  WITH CHECK (account_id = folha.current_account_id());

-- calculation_trace
ALTER TABLE folha.calculation_trace ENABLE ROW LEVEL SECURITY;
ALTER TABLE folha.calculation_trace FORCE ROW LEVEL SECURITY;
CREATE POLICY trace_isolamento ON folha.calculation_trace
  USING (account_id = folha.current_account_id())
  WITH CHECK (account_id = folha.current_account_id());

-- earning_deduction_code (global + tenant)
ALTER TABLE folha.earning_deduction_code ENABLE ROW LEVEL SECURITY;
ALTER TABLE folha.earning_deduction_code FORCE ROW LEVEL SECURITY;
CREATE POLICY rubrica_isolamento ON folha.earning_deduction_code
  USING (account_id = folha.current_account_id() OR is_global = true)
  WITH CHECK (account_id = folha.current_account_id());

-- payroll_rule_version
ALTER TABLE folha.payroll_rule_version ENABLE ROW LEVEL SECURITY;
ALTER TABLE folha.payroll_rule_version FORCE ROW LEVEL SECURITY;
CREATE POLICY rule_isolamento ON folha.payroll_rule_version
  USING (account_id = folha.current_account_id())
  WITH CHECK (account_id = folha.current_account_id());

-- tax_table_version (global — leitura universal, escrita restrita)
ALTER TABLE folha.tax_table_version ENABLE ROW LEVEL SECURITY;
ALTER TABLE folha.tax_table_version FORCE ROW LEVEL SECURITY;
CREATE POLICY tax_table_read ON folha.tax_table_version
  FOR SELECT USING (true);
CREATE POLICY tax_table_write ON folha.tax_table_version
  FOR INSERT WITH CHECK (current_user = 'dnex_gestao_data_owner');

-- collective_agreement
ALTER TABLE folha.collective_agreement ENABLE ROW LEVEL SECURITY;
ALTER TABLE folha.collective_agreement FORCE ROW LEVEL SECURITY;
CREATE POLICY agreement_isolamento ON folha.collective_agreement
  USING (account_id = folha.current_account_id())
  WITH CHECK (account_id = folha.current_account_id());

-- benefit
ALTER TABLE folha.benefit ENABLE ROW LEVEL SECURITY;
ALTER TABLE folha.benefit FORCE ROW LEVEL SECURITY;
CREATE POLICY benefit_isolamento ON folha.benefit
  USING (account_id = folha.current_account_id())
  WITH CHECK (account_id = folha.current_account_id());

-- auditoria
ALTER TABLE folha.auditoria ENABLE ROW LEVEL SECURITY;
ALTER TABLE folha.auditoria FORCE ROW LEVEL SECURITY;
CREATE POLICY auditoria_isolamento ON folha.auditoria
  USING (account_id = folha.current_account_id())
  WITH CHECK (account_id = folha.current_account_id());

-- ---------------------------------------------------------------------------
-- 9. Grants por tabela (REVOKE ALL antes do GRANT — padrão dnex-fiscal-migration-acl)
-- ---------------------------------------------------------------------------
REVOKE ALL ON ALL TABLES IN SCHEMA folha FROM PUBLIC, authenticated, service_role;

GRANT SELECT, INSERT, UPDATE ON folha.employee TO dnex_gestao_folha_worker;
GRANT SELECT ON folha.employee TO dnex_gestao_data_owner;

GRANT SELECT, INSERT, UPDATE ON folha.employment_contract TO dnex_gestao_folha_worker;
GRANT SELECT ON folha.employment_contract TO dnex_gestao_data_owner;

GRANT SELECT, INSERT, UPDATE ON folha.payroll_run TO dnex_gestao_folha_worker;
GRANT SELECT ON folha.payroll_run TO dnex_gestao_data_owner;

GRANT SELECT, INSERT ON folha.payroll_result TO dnex_gestao_folha_worker;
GRANT SELECT ON folha.payroll_result TO dnex_gestao_data_owner;

GRANT SELECT, INSERT ON folha.calculation_trace TO dnex_gestao_folha_worker;
GRANT SELECT ON folha.calculation_trace TO dnex_gestao_data_owner;

GRANT SELECT, INSERT, UPDATE ON folha.earning_deduction_code TO dnex_gestao_folha_worker;
GRANT SELECT ON folha.earning_deduction_code TO dnex_gestao_data_owner;

GRANT SELECT, INSERT ON folha.payroll_rule_version TO dnex_gestao_folha_worker;
GRANT SELECT ON folha.payroll_rule_version TO dnex_gestao_data_owner;

GRANT SELECT ON folha.tax_table_version TO dnex_gestao_folha_worker;
GRANT SELECT ON folha.tax_table_version TO dnex_gestao_data_owner;
GRANT SELECT, INSERT ON folha.tax_table_version TO dnex_gestao_data_owner;

GRANT SELECT, INSERT, UPDATE ON folha.collective_agreement TO dnex_gestao_folha_worker;
GRANT SELECT ON folha.collective_agreement TO dnex_gestao_data_owner;

GRANT SELECT, INSERT, UPDATE ON folha.benefit TO dnex_gestao_folha_worker;
GRANT SELECT ON folha.benefit TO dnex_gestao_data_owner;

GRANT SELECT, INSERT ON folha.auditoria TO dnex_gestao_folha_worker;
GRANT SELECT ON folha.auditoria TO dnex_gestao_data_owner;

GRANT USAGE ON ALL SEQUENCES IN SCHEMA folha TO dnex_gestao_folha_worker;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA folha TO dnex_gestao_data_owner;

COMMIT;