-- DNEX Folha — Motor de cálculo determinístico (INSS, IRRF, FGTS).
-- Funções SECURITY DEFINER com search_path fixo; leitura de tax_table_version por vigência.
-- Memória de cálculo via folha.calculation_trace (inserida pelo caller).
-- Rollback: DROP FUNCTION folha.calc_inss, folha.calc_irrf, folha.calc_fgts, folha.run_payroll_employee;
BEGIN;

-- ---------------------------------------------------------------------------
-- 1. calc_inss — progressivo por faixa (tabela vigente na competência)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION folha.calc_inss(
  p_salario_contribuicao numeric,
  p_competencia date
) RETURNS TABLE (
  valor_inss numeric,
  aliquota_efetiva numeric,
  tabela_vigencia date,
  tabela_hash text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_tabela jsonb;
  v_faixa jsonb;
  v_base numeric;
  v_valor numeric := 0;
  v_teto numeric;
  v_vigencia date;
  v_hash text;
BEGIN
  SELECT tabela_json, vigencia_inicio, source_hash
    INTO v_tabela, v_vigencia, v_hash
    FROM folha.tax_table_version
   WHERE tipo = 'inss'
     AND vigencia_inicio <= p_competencia
     AND (vigencia_fim IS NULL OR vigencia_fim >= p_competencia)
   ORDER BY vigencia_inicio DESC
   LIMIT 1;

  IF v_tabela IS NULL THEN
    RAISE EXCEPTION 'Tabela INSS não encontrada para competência %', p_competencia;
  END IF;

  v_teto := (v_tabela->>'teto')::numeric;
  v_base := LEAST(p_salario_contribuicao, v_teto);

  FOR v_faixa IN SELECT * FROM jsonb_array_elements(v_tabela->'faixas')
  LOOP
    DECLARE
      v_li numeric := (v_faixa->>'limite_inferior')::numeric;
      v_ls numeric := COALESCE((v_faixa->>'limite_superior')::numeric, v_teto);
      v_al numeric := (v_faixa->>'aliquota')::numeric;
      v_parcela numeric;
    BEGIN
      IF v_base > v_li THEN
        v_parcela := LEAST(v_base, v_ls) - v_li;
        v_valor := v_valor + (v_parcela * v_al);
      END IF;
    END;
  END LOOP;

  valor_inss := ROUND(v_valor, 2);
  aliquota_efetiva := CASE WHEN p_salario_contribuicao > 0
                            THEN ROUND(v_valor / p_salario_contribuicao, 4)
                            ELSE 0 END;
  tabela_vigencia := v_vigencia;
  tabela_hash := v_hash;
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION folha.calc_inss(numeric, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION folha.calc_inss(numeric, date) TO dnex_gestao_folha_worker;
GRANT EXECUTE ON FUNCTION folha.calc_inss(numeric, date) TO dnex_gestao_data_owner;

-- ---------------------------------------------------------------------------
-- 2. calc_irrf — tabela progressiva + redutor Lei 15.270/2025
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION folha.calc_irrf(
  p_base_calculo numeric,
  p_num_dependentes integer DEFAULT 0,
  p_usar_desconto_simplificado boolean DEFAULT false,
  p_competencia date DEFAULT CURRENT_DATE
) RETURNS TABLE (
  valor_irrf numeric,
  aliquota_efetiva numeric,
  desconto_aplicado text,
  redutor_lei_15270 numeric,
  tabela_vigencia date,
  tabela_hash text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_tabela jsonb;
  v_faixa jsonb;
  v_deducao_dep numeric;
  v_desc_simpl numeric;
  v_redutor_cfg jsonb;
  v_base numeric;
  v_bruto numeric := 0;
  v_redutor numeric := 0;
  v_final numeric;
  v_vigencia date;
  v_hash text;
  v_desc_tipo text := 'nenhum';
BEGIN
  SELECT tabela_json, vigencia_inicio, source_hash
    INTO v_tabela, v_vigencia, v_hash
    FROM folha.tax_table_version
   WHERE tipo = 'irrf'
     AND vigencia_inicio <= p_competencia
     AND (vigencia_fim IS NULL OR vigencia_fim >= p_competencia)
   ORDER BY vigencia_inicio DESC
   LIMIT 1;

  IF v_tabela IS NULL THEN
    RAISE EXCEPTION 'Tabela IRRF não encontrada para competência %', p_competencia;
  END IF;

  v_deducao_dep := COALESCE((v_tabela->>'deducao_dependente_mensal')::numeric, 189.59);
  v_desc_simpl := COALESCE((v_tabela->>'desconto_simplificado_mensal')::numeric, 607.20);
  v_redutor_cfg := v_tabela->'redutor_lei_15270_2025';

  -- Base após dedução de dependentes
  v_base := GREATEST(p_base_calculo - (p_num_dependentes * v_deducao_dep), 0);

  -- Desconto simplificado substitui todas as deduções legais
  IF p_usar_desconto_simplificado THEN
    v_base := GREATEST(p_base_calculo - v_desc_simpl, 0);
    v_desc_tipo := 'simplificado_' || v_desc_simpl::text;
  ELSIF p_num_dependentes > 0 THEN
    v_desc_tipo := 'dependentes_' || p_num_dependentes::text;
  END IF;

  -- Cálculo pela tabela progressiva
  FOR v_faixa IN SELECT * FROM jsonb_array_elements(v_tabela->'faixas')
  LOOP
    DECLARE
      v_li numeric := (v_faixa->>'limite_inferior')::numeric;
      v_ls numeric := (v_faixa->>'limite_superior')::numeric;
      v_al numeric := (v_faixa->>'aliquota')::numeric;
      v_pd numeric := (v_faixa->>'parcela_deduzir')::numeric;
    BEGIN
      IF v_base >= v_li AND (v_ls IS NULL OR v_base <= v_ls) THEN
        v_bruto := (v_base * v_al) - v_pd;
        EXIT;
      END IF;
    END;
  END LOOP;

  v_bruto := GREATEST(v_bruto, 0);

  -- Redutor Lei 15.270/2025 (após cálculo da tabela)
  IF v_redutor_cfg IS NOT NULL AND v_redutor_cfg != 'null'::jsonb THEN
    DECLARE
      v_isencao numeric := (v_redutor_cfg->>'isencao_efetiva_ate')::numeric;
      v_limite numeric := (v_redutor_cfg->>'reducao_decrescente_ate')::numeric;
      v_formula_a numeric := 978.62;
      v_formula_b numeric := 0.133145;
    BEGIN
      IF p_base_calculo <= v_isencao THEN
        v_redutor := v_bruto; -- isenção total
      ELSIF p_base_calculo <= v_limite THEN
        v_redutor := GREATEST(v_formula_a - (v_formula_b * p_base_calculo), 0);
        v_redutor := LEAST(v_redutor, v_bruto);
      END IF;
    END;
  END IF;

  v_final := GREATEST(ROUND(v_bruto - v_redutor, 2), 0);

  valor_irrf := v_final;
  aliquota_efetiva := CASE WHEN p_base_calculo > 0
                            THEN ROUND(v_final / p_base_calculo, 4)
                            ELSE 0 END;
  desconto_aplicado := v_desc_tipo;
  redutor_lei_15270 := ROUND(v_redutor, 2);
  tabela_vigencia := v_vigencia;
  tabela_hash := v_hash;
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION folha.calc_irrf(numeric, integer, boolean, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION folha.calc_irrf(numeric, integer, boolean, date) TO dnex_gestao_folha_worker;
GRANT EXECUTE ON FUNCTION folha.calc_irrf(numeric, integer, boolean, date) TO dnex_gestao_data_owner;

-- ---------------------------------------------------------------------------
-- 3. calc_fgts — depósito mensal (não descontado do empregado)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION folha.calc_fgts(
  p_remuneracao numeric,
  p_regime_trabalho text DEFAULT 'clt',
  p_competencia date DEFAULT CURRENT_DATE
) RETURNS TABLE (
  fgts_deposito numeric,
  fgts_multa_rescisoria numeric,
  aliquota numeric,
  tabela_vigencia date,
  tabela_hash text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_tabela jsonb;
  v_al_deposito numeric;
  v_al_multa numeric;
  v_vigencia date;
  v_hash text;
BEGIN
  SELECT tabela_json, vigencia_inicio, source_hash
    INTO v_tabela, v_vigencia, v_hash
    FROM folha.tax_table_version
   WHERE tipo = 'fgts'
     AND vigencia_inicio <= p_competencia
     AND (vigencia_fim IS NULL OR vigencia_fim >= p_competencia)
   ORDER BY vigencia_inicio DESC
   LIMIT 1;

  IF v_tabela IS NULL THEN
    RAISE EXCEPTION 'Tabela FGTS não encontrada para competência %', p_competencia;
  END IF;

  v_al_deposito := CASE
    WHEN p_regime_trabalho = 'aprendiz' THEN (v_tabela->>'aprendiz')::numeric
    ELSE (v_tabela->>'deposito_mensal_empregado')::numeric
  END;

  v_al_multa := (v_tabela->>'multa_rescisorias_dispensa_sem_justa_causa')::numeric;

  fgts_deposito := ROUND(p_remuneracao * v_al_deposito, 2);
  fgts_multa_rescisoria := ROUND(fgts_deposito * v_al_multa, 2);
  aliquota := v_al_deposito;
  tabela_vigencia := v_vigencia;
  tabela_hash := v_hash;
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION folha.calc_fgts(numeric, text, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION folha.calc_fgts(numeric, text, date) TO dnex_gestao_folha_worker;
GRANT EXECUTE ON FUNCTION folha.calc_fgts(numeric, text, date) TO dnex_gestao_data_owner;

-- ---------------------------------------------------------------------------
-- 4. run_payroll_employee — orquestra cálculo completo de um empregado
--    Insere payroll_result + calculation_trace atômico.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION folha.run_payroll_employee(
  p_run_id uuid,
  p_contract_id uuid
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_account_id uuid;
  v_employee_id uuid;
  v_salario numeric;
  v_regime text;
  v_competencia date;
  v_inss record;
  v_irrf record;
  v_fgts record;
  v_base_irrf numeric;
  v_result_id uuid;
  v_hash_input text;
BEGIN
  -- Carregar dados do contrato e competência do run
  SELECT c.account_id, c.employee_id, c.salario_base, c.regime_trabalho, r.competencia
    INTO v_account_id, v_employee_id, v_salario, v_regime, v_competencia
    FROM folha.employment_contract c
    JOIN folha.payroll_run r ON r.run_id = p_run_id
   WHERE c.contract_id = p_contract_id;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Contrato % ou run % não encontrado', p_contract_id, p_run_id;
  END IF;

  -- Hash de inputs para idempotência/replay detection
  v_hash_input := md5(v_account_id::text || p_contract_id::text || v_competencia::text
                      || v_salario::text || v_regime);

  -- Calcular INSS
  SELECT * INTO v_inss FROM folha.calc_inss(v_salario, v_competencia);

  -- Base IRRF = salário - INSS empregado
  v_base_irrf := v_salario - v_inss.valor_inss;

  -- Calcular IRRF
  SELECT * INTO v_irrf FROM folha.calc_irrf(v_base_irrf, 0, false, v_competencia);

  -- Calcular FGTS
  SELECT * INTO v_fgts FROM folha.calc_fgts(v_salario, v_regime, v_competencia);

  -- Inserir resultado
  INSERT INTO folha.payroll_result (
    run_id, account_id, employee_id, contract_id,
    total_proventos, total_descontos, liquido,
    inss_empregado, irrf, fgts,
    inss_patronal, rat, terceiros,
    calculation_hash
  ) VALUES (
    p_run_id, v_account_id, v_employee_id, p_contract_id,
    v_salario,
    v_inss.valor_inss + v_irrf.valor_irrf,
    v_salario - v_inss.valor_inss - v_irrf.valor_irrf,
    v_inss.valor_inss, v_irrf.valor_irrf, v_fgts.fgts_deposito,
    NULL, NULL, NULL, -- encargos patronais calculados separadamente
    v_hash_input
  ) RETURNING result_id INTO v_result_id;

  -- Inserir traces (memória de cálculo)
  INSERT INTO folha.calculation_trace (result_id, account_id, step_order, rubrica_code, descricao, base_calculo, aliquota, valor, tipo, detail_json)
  VALUES
    (v_result_id, v_account_id, 1, 'SALARIO_BASE', 'Salário base contratual', v_salario, 1.0000, v_salario, 'provento',
     jsonb_build_object('regime', v_regime)),
    (v_result_id, v_account_id, 2, 'INSS_EMPREGADO', 'INSS progressivo empregado', v_salario, v_inss.aliquota_efetiva, v_inss.valor_inss, 'desconto',
     jsonb_build_object('tabela_vigencia', v_inss.tabela_vigencia, 'tabela_hash', v_inss.tabela_hash)),
    (v_result_id, v_account_id, 3, 'IRRF', 'IRRF sobre rendimento do trabalho', v_base_irrf, v_irrf.aliquota_efetiva, v_irrf.valor_irrf, 'desconto',
     jsonb_build_object('base_apos_inss', v_base_irrf, 'desconto_aplicado', v_irrf.desconto_aplicado,
                        'redutor_lei_15270', v_irrf.redutor_lei_15270, 'tabela_vigencia', v_irrf.tabela_vigencia)),
    (v_result_id, v_account_id, 4, 'FGTS_DEPOSITO', 'FGTS depósito mensal (encargo)', v_salario, v_fgts.aliquota, v_fgts.fgts_deposito, 'informativo',
     jsonb_build_object('tabela_vigencia', v_fgts.tabela_vigencia));

  RETURN v_result_id;
END;
$$;

REVOKE ALL ON FUNCTION folha.run_payroll_employee(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION folha.run_payroll_employee(uuid, uuid) TO dnex_gestao_folha_worker;

COMMIT;