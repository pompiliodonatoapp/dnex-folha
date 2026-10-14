-- DNEX Folha — Fase 3: Integração eSocial/Reinf e Contabilização
-- Funções para gerar payloads de eventos eSocial e lançamentos contábeis
-- a partir do payroll_result aprovado, alimentando os outboxes da migration 0018.
-- Rollback: DROP FUNCTION folha.build_esocial_s1200, folha.build_esocial_s2200, folha.build_contabil_folha;
BEGIN;

-- ---------------------------------------------------------------------------
-- 1. build_esocial_s1200 — Remuneração de trabalhador vinculado
-- Gera payload JSONB conforme leiaute eSocial S-1.3 vigente
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION folha.build_esocial_s1200(
  p_result_id uuid
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_result record;
  v_employee record;
  v_contract record;
  v_payload jsonb;
BEGIN
  SELECT pr.*, pr.run_id INTO v_result
  FROM folha.payroll_result pr
  WHERE pr.result_id = p_result_id;

  IF v_result.result_id IS NULL THEN
    RAISE EXCEPTION 'payroll_result % não encontrado', p_result_id;
  END IF;

  SELECT e.* INTO v_employee
  FROM folha.employee e
  WHERE e.employee_id = v_result.employee_id;

  SELECT c.* INTO v_contract
  FROM folha.employment_contract c
  WHERE c.contract_id = v_result.contract_id;

  v_payload := jsonb_build_object(
    'evento', 'S-1200',
    'versao_leiaute', 'S-1.3',
    'competencia', (SELECT competencia FROM folha.payroll_run WHERE run_id = v_result.run_id),
    'cpf_trabalhador', v_employee.cpf,
    'nome_trabalhador', v_employee.nome_completo,
    'matricula', v_contract.contract_id::text,
    'cod_categoria', CASE v_contract.regime_trabalho
      WHEN 'clt' THEN '101'
      WHEN 'aprendiz' THEN '103'
      WHEN 'estagio' THEN '401'
      ELSE '101'
    END,
    'remuneracao', jsonb_build_object(
      'vr_salario', v_result.total_proventos,
      'vr_inss_empregado', v_result.inss_empregado,
      'vr_irrf', v_result.irrf,
      'vr_fgts', v_result.fgts,
      'vr_liquido', v_result.liquido
    ),
    'encargos_patronais', jsonb_build_object(
      'vr_inss_patronal', COALESCE(v_result.inss_patronal, 0),
      'vr_rat', COALESCE(v_result.rat, 0),
      'vr_terceiros', COALESCE(v_result.terceiros, 0)
    ),
    'gerado_em', now(),
    'calculation_hash', v_result.calculation_hash
  );

  RETURN v_payload;
END;
$$;

REVOKE ALL ON FUNCTION folha.build_esocial_s1200(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION folha.build_esocial_s1200(uuid) TO dnex_gestao_folha_worker;
GRANT EXECUTE ON FUNCTION folha.build_esocial_s1200(uuid) TO dnex_gestao_data_owner;

-- ---------------------------------------------------------------------------
-- 2. build_esocial_s2200 — Cadastro inicial / admissão
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION folha.build_esocial_s2200(
  p_contract_id uuid
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_employee record;
  v_contract record;
  v_payload jsonb;
BEGIN
  SELECT c.* INTO v_contract
  FROM folha.employment_contract c
  WHERE c.contract_id = p_contract_id;

  IF v_contract.contract_id IS NULL THEN
    RAISE EXCEPTION 'employment_contract % não encontrado', p_contract_id;
  END IF;

  SELECT e.* INTO v_employee
  FROM folha.employee e
  WHERE e.employee_id = v_contract.employee_id;

  v_payload := jsonb_build_object(
    'evento', 'S-2200',
    'versao_leiaute', 'S-1.3',
    'cpf_trabalhador', v_employee.cpf,
    'nome_trabalhador', v_employee.nome_completo,
    'data_nascimento', v_employee.data_nascimento,
    'sexo', v_employee.sexo,
    'data_admissao', v_contract.data_admissao,
    'cargo', v_contract.cargo,
    'salario_base', v_contract.salario_base,
    'regime_trabalho', v_contract.regime_trabalho,
    'jornada_semanal', v_contract.jornada_semanal,
    'cod_categoria', CASE v_contract.regime_trabalho
      WHEN 'clt' THEN '101'
      WHEN 'aprendiz' THEN '103'
      WHEN 'estagio' THEN '401'
      ELSE '101'
    END,
    'gerado_em', now()
  );

  RETURN v_payload;
END;
$$;

REVOKE ALL ON FUNCTION folha.build_esocial_s2200(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION folha.build_esocial_s2200(uuid) TO dnex_gestao_folha_worker;
GRANT EXECUTE ON FUNCTION folha.build_esocial_s2200(uuid) TO dnex_gestao_data_owner;

-- ---------------------------------------------------------------------------
-- 3. build_contabil_folha — Partidas dobradas para accounting-kernel
-- Gera array de lançamentos D/C conforme plano de contas contábil
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION folha.build_contabil_folha(
  p_result_id uuid
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_result record;
  v_lancamentos jsonb := '[]'::jsonb;
BEGIN
  SELECT pr.*, r.competencia INTO v_result
  FROM folha.payroll_result pr
  JOIN folha.payroll_run r ON r.run_id = pr.run_id
  WHERE pr.result_id = p_result_id;

  IF v_result.result_id IS NULL THEN
    RAISE EXCEPTION 'payroll_result % não encontrado', p_result_id;
  END IF;

  -- Débito: Despesa com salários (proventos)
  v_lancamentos := v_lancamentos || jsonb_build_array(jsonb_build_object(
    'conta_debito', '3.2.1.01.001',
    'conta_credito', NULL,
    'valor', v_result.total_proventos,
    'historico', 'Folha pagamento competência ' || v_result.competencia::text,
    'tipo', 'despesa_salario'
  ));

  -- Crédito: Salários a pagar (líquido)
  v_lancamentos := v_lancamentos || jsonb_build_array(jsonb_build_object(
    'conta_debito', NULL,
    'conta_credito', '2.1.5.01.001',
    'valor', v_result.liquido,
    'historico', 'Salários a pagar competência ' || v_result.competencia::text,
    'tipo', 'passivo_salario'
  ));

  -- Crédito: INSS empregado a recolher
  IF v_result.inss_empregado > 0 THEN
    v_lancamentos := v_lancamentos || jsonb_build_array(jsonb_build_object(
      'conta_debito', NULL,
      'conta_credito', '2.1.5.02.001',
      'valor', v_result.inss_empregado,
      'historico', 'INSS empregado a recolher ' || v_result.competencia::text,
      'tipo', 'passivo_inss_empregado'
    ));
  END IF;

  -- Crédito: IRRF a recolher
  IF v_result.irrf > 0 THEN
    v_lancamentos := v_lancamentos || jsonb_build_array(jsonb_build_object(
      'conta_debito', NULL,
      'conta_credito', '2.1.5.03.001',
      'valor', v_result.irrf,
      'historico', 'IRRF a recolher ' || v_result.competencia::text,
      'tipo', 'passivo_irrf'
    ));
  END IF;

  -- Débito: FGTS encargo patronal (informativo, não desconta empregado)
  IF v_result.fgts > 0 THEN
    v_lancamentos := v_lancamentos || jsonb_build_array(jsonb_build_object(
      'conta_debito', '3.2.1.02.001',
      'conta_credito', '2.1.5.04.001',
      'valor', v_result.fgts,
      'historico', 'FGTS a depositar ' || v_result.competencia::text,
      'tipo', 'encargo_fgts'
    ));
  END IF;

  RETURN jsonb_build_object(
    'result_id', p_result_id,
    'competencia', v_result.competencia,
    'lancamentos', v_lancamentos,
    'total_debitos', v_result.total_proventos + COALESCE(v_result.fgts, 0),
    'total_creditos', v_result.liquido + v_result.inss_empregado + v_result.irrf + COALESCE(v_result.fgts, 0),
    'balanceado', (v_result.total_proventos + COALESCE(v_result.fgts, 0)) =
                   (v_result.liquido + v_result.inss_empregado + v_result.irrf + COALESCE(v_result.fgts, 0)),
    'gerado_em', now()
  );
END;
$$;

REVOKE ALL ON FUNCTION folha.build_contabil_folha(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION folha.build_contabil_folha(uuid) TO dnex_gestao_folha_worker;
GRANT EXECUTE ON FUNCTION folha.build_contabil_folha(uuid) TO dnex_gestao_data_owner;

-- ---------------------------------------------------------------------------
-- 4. dispatch_folha_completa — Orquestra envio para outboxes eSocial + contábil
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION folha.dispatch_folha_completa(
  p_run_id uuid
) RETURNS TABLE (
  esocial_events_dispatched integer,
  contabil_events_dispatched integer
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_result record;
  v_esocial_count integer := 0;
  v_contabil_count integer := 0;
  v_competencia date;
BEGIN
  SELECT competencia INTO v_competencia
  FROM folha.payroll_run
  WHERE run_id = p_run_id;

  IF v_competencia IS NULL THEN
    RAISE EXCEPTION 'payroll_run % não encontrado', p_run_id;
  END IF;

  FOR v_result IN
    SELECT result_id FROM folha.payroll_result WHERE run_id = p_run_id
  LOOP
    -- Dispatch eSocial S-1200
    PERFORM folha.dispatch_esocial_event(
      p_run_id,
      v_result.result_id,
      'S-1200',
      v_competencia,
      folha.build_esocial_s1200(v_result.result_id),
      NULL
    );
    v_esocial_count := v_esocial_count + 1;

    -- Dispatch contábil
    PERFORM folha.dispatch_accounting_event(
      p_run_id,
      v_result.result_id,
      'folha_mensal',
      folha.build_contabil_folha(v_result.result_id)
    );
    v_contabil_count := v_contabil_count + 1;
  END LOOP;

  esocial_events_dispatched := v_esocial_count;
  contabil_events_dispatched := v_contabil_count;
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION folha.dispatch_folha_completa(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION folha.dispatch_folha_completa(uuid) TO dnex_gestao_folha_worker;

COMMIT;