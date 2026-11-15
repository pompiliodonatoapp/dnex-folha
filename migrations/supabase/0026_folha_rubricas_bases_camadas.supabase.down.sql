-- DNEX Folha — Reversão da migration 0026 (aplicar depois da reversão da 0027).
--
-- AVISO: devolve o cadastro ao estado da 0025: uma folha por conta e competência, rubrica com
-- três indicadores de incidência, sem bases, camadas, lançamentos nem pendências como dado, e
-- com as tabelas de INSS e de salário mínimo de 2026 de novo com vigência aberta (o defeito
-- que a 0026 corrige). Use só para desfazer uma aplicação que deu errado e reaplique em
-- seguida. Não é um estado para operar.
--
-- Recusa (SQLSTATE 55000) se as funções da 0027 ainda existirem, se alguma tabela criada pela
-- 0026 tiver dado de conta, ou se houver mais de uma folha na mesma conta e competência. A
-- conferência roda com row_security = off; se o papel não ignorar RLS, falha em vez de apagar
-- sem ver.
BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL row_security = off;

DO $$
DECLARE
  v_tabela text;
  v_tem boolean;
BEGIN
  IF to_regprocedure('folha.folha_gravar_resultado(uuid, uuid, uuid, date, jsonb)') IS NOT NULL THEN
    RAISE EXCEPTION '0026 (reversão): reverta antes a migration 0027'
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  FOREACH v_tabela IN ARRAY ARRAY[
    'payroll_pendency', 'payroll_result_item', 'payroll_result_base', 'payroll_process_input',
    'payroll_entry', 'contract_leave', 'external_remuneration', 'rubric_rule', 'rubric_esocial_nature'
  ]
  LOOP
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM folha.%I)', v_tabela) INTO v_tem;
    IF v_tem THEN
      RAISE EXCEPTION '0026 (reversão): folha.% tem linhas; exporte e apague os dados antes de reverter', v_tabela
        USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
  END LOOP;
  -- As incidências que a própria 0026 derivou para rubricas de conta já existentes (fonte
  -- terminada em [0026]) e as ligações de base criadas junto com elas não impedem a reversão.
  IF EXISTS (SELECT 1 FROM folha.calculation_base WHERE account_id IS NOT NULL)
     OR EXISTS (SELECT 1 FROM folha.rubric_incidence
                 WHERE account_id IS NOT NULL AND COALESCE(fonte, '') NOT LIKE '%[0026]')
     OR EXISTS (SELECT 1 FROM folha.rubric_base rb
                 WHERE rb.account_id IS NOT NULL
                   AND NOT EXISTS (SELECT 1 FROM folha.rubric_incidence ri
                                    WHERE ri.code_id = rb.code_id AND ri.fonte LIKE '%[0026]'
                                      AND ri.vigencia_inicio = rb.vigencia_inicio)) THEN
    RAISE EXCEPTION '0026 (reversão): há base, incidência ou ligação de rubrica cadastrada por conta'
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  IF EXISTS (SELECT 1 FROM folha.employment_contract WHERE agreement_id IS NOT NULL) THEN
    RAISE EXCEPTION '0026 (reversão): há contrato ligado a convenção coletiva'
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  IF EXISTS (SELECT 1 FROM folha.payroll_run WHERE tipo_processo <> 'mensal' OR sequencia <> 1)
     OR EXISTS (SELECT 1 FROM folha.payroll_run GROUP BY account_id, competencia HAVING count(*) > 1) THEN
    RAISE EXCEPTION '0026 (reversão): há folha de outro tipo de processo ou mais de uma folha por conta e competência'
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  IF EXISTS (SELECT 1 FROM folha.calculation_trace WHERE camada_regra IS NOT NULL OR rule_id IS NOT NULL) THEN
    RAISE EXCEPTION '0026 (reversão): há memória de cálculo com a camada da regra; exporte antes de reverter'
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
END
$$;

-- Vigências: reabre só o que a 0026 fechou.
UPDATE folha.tax_table_version
   SET vigencia_fim = NULL
 WHERE tipo IN ('inss', 'salario_minimo') AND vigencia_inicio = '2026-01-01' AND vigencia_fim = '2026-12-31';

-- Resultado e folha
DROP TABLE folha.payroll_pendency;
DROP TABLE folha.payroll_result_base;
DROP TABLE folha.payroll_result_item;
DROP TABLE folha.payroll_process_input;
ALTER TABLE folha.calculation_trace
  DROP COLUMN rule_id,
  DROP COLUMN camada_regra;
DROP INDEX folha.payroll_run_processo_key;
ALTER TABLE folha.payroll_run
  DROP CONSTRAINT payroll_run_competencia_dia_1,
  DROP COLUMN sequencia,
  DROP COLUMN tipo_processo;
ALTER TABLE folha.payroll_run
  ADD CONSTRAINT payroll_run_account_id_competencia_key UNIQUE (account_id, competencia);

-- Lançamentos, afastamentos, outros vínculos e camadas
DROP TABLE folha.external_remuneration;
DROP TABLE folha.contract_leave;
DROP TABLE folha.payroll_entry;
DROP TABLE folha.rubric_rule;
DROP FUNCTION folha.formula_valida(jsonb, integer);
ALTER TABLE folha.employment_contract
  DROP COLUMN agreement_id;
DROP INDEX folha.payroll_result_account_result_key;
DROP INDEX folha.payroll_run_account_run_key;
DROP INDEX folha.collective_agreement_account_agreement_key;
DROP INDEX folha.employment_contract_account_contract_key;
DROP INDEX folha.employee_account_employee_key;

-- Rubrica
DROP TABLE folha.rubric_base;
DROP TABLE folha.rubric_esocial_nature;
DROP TABLE folha.rubric_incidence;
DROP FUNCTION folha.exigir_rubrica_da_conta();
DROP INDEX folha.earning_deduction_code_global_codigo_key;
DROP TRIGGER trg_rubrica_derivar_tipo ON folha.earning_deduction_code;
DROP FUNCTION folha.rubrica_derivar_tipo();
DELETE FROM folha.earning_deduction_code
 WHERE account_id IS NULL
   AND codigo IN ('ADIANTAMENTO_SALARIAL_PAGO', 'FERIAS_GOZO', 'FERIAS_TERCO', 'ABONO_PECUNIARIO_TERCO', 'FERIAS_DOBRA',
                  'RESC_INDENIZACAO_ART479', 'INSS_13_SALARIO', 'IRRF_13_SALARIO', 'IRRF_FERIAS',
                  'DECIMO_TERCEIRO_ADIANT_COMP', 'RESC_DESCONTO_AVISO_PREVIO', 'RESC_DESCONTO_ART480');
ALTER TABLE folha.earning_deduction_code
  DROP COLUMN ordem_calculo,
  DROP COLUMN forma_calculo,
  DROP COLUMN tipo_rubrica;
COMMENT ON COLUMN folha.earning_deduction_code.incidencia_inss IS NULL;
COMMENT ON COLUMN folha.earning_deduction_code.incidencia_irrf IS NULL;
COMMENT ON COLUMN folha.earning_deduction_code.incidencia_fgts IS NULL;

-- Catálogos
DROP TABLE folha.rule_layer;
DROP TABLE folha.esocial_rubric_nature;
DROP TABLE folha.incidence_code;
DROP TABLE folha.calculation_base;
DROP FUNCTION folha.conta_imutavel();

COMMIT;
