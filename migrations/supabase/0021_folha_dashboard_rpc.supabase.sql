-- DNEX Folha — Fase 4: RPC dashboard_completo para UI do contador
-- Função agregadora que alimenta a PaginaFolha no dnex-hub com KPIs,
-- distribuição por regime e evolução de custo/headcount dos últimos 6 meses.
-- Rollback: DROP FUNCTION folha.dashboard_completo(uuid);
BEGIN;

CREATE OR REPLACE FUNCTION folha.dashboard_completo(
  p_account_id uuid
) RETURNS TABLE (
  total_empregados_ativos integer,
  custo_folha_mes_centavos bigint,
  encargos_patronais_mes_centavos bigint,
  competencias_abertas integer,
  competencias_fechadas_mes integer,
  distribuicao_regime jsonb,
  evolucao_custo_6m jsonb
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_total_ativos integer;
  v_custo_mes bigint;
  v_encargos_mes bigint;
  v_comp_abertas integer;
  v_comp_fechadas integer;
  v_dist_regime jsonb;
  v_evolucao jsonb;
  v_competencia_atual date;
BEGIN
  v_competencia_atual := date_trunc('month', CURRENT_DATE);

  -- Total de empregados ativos
  SELECT count(*) INTO v_total_ativos
  FROM folha.employment_contract
  WHERE account_id = p_account_id
    AND status = 'ativo'
    AND (data_demissao IS NULL OR data_demissao > v_competencia_atual);

  -- Custo folha do mês corrente (proventos em centavos)
  SELECT COALESCE(SUM(pr.total_proventos * 100)::bigint, 0) INTO v_custo_mes
  FROM folha.payroll_result pr
  JOIN folha.payroll_run r ON r.run_id = pr.run_id
  WHERE r.account_id = p_account_id
    AND r.competencia = v_competencia_atual
    AND r.status IN ('approved', 'closed');

  -- Encargos patronais do mês corrente
  SELECT COALESCE(SUM(COALESCE(pr.inss_patronal, 0) + COALESCE(pr.rat, 0) + COALESCE(pr.terceiros, 0)) * 100::bigint, 0) INTO v_encargos_mes
  FROM folha.payroll_result pr
  JOIN folha.payroll_run r ON r.run_id = pr.run_id
  WHERE r.account_id = p_account_id
    AND r.competencia = v_competencia_atual
    AND r.status IN ('approved', 'closed');

  -- Competências abertas (draft/calculating/calculated)
  SELECT count(*) INTO v_comp_abertas
  FROM folha.payroll_run
  WHERE account_id = p_account_id
    AND status IN ('draft', 'calculating', 'calculated');

  -- Competências fechadas no mês corrente
  SELECT count(*) INTO v_comp_fechadas
  FROM folha.payroll_run
  WHERE account_id = p_account_id
    AND status = 'closed'
    AND competencia >= date_trunc('month', CURRENT_DATE);

  -- Distribuição por regime de trabalho
  SELECT jsonb_agg(jsonb_build_object('regime', c.regime_trabalho, 'count', cnt)) INTO v_dist_regime
  FROM (
    SELECT regime_trabalho, count(*) as cnt
    FROM folha.employment_contract
    WHERE account_id = p_account_id
      AND status = 'ativo'
      AND (data_demissao IS NULL OR data_demissao > v_competencia_atual)
    GROUP BY regime_trabalho
  ) c;

  -- Evolução custo × headcount últimos 6 meses
  SELECT jsonb_agg(jsonb_build_object('competencia', comp, 'custo_centavos', custo, 'headcount', hc)) INTO v_evolucao
  FROM (
    SELECT r.competencia as comp,
           COALESCE(SUM(pr.total_proventos * 100)::bigint, 0) as custo,
           COUNT(DISTINCT pr.employee_id) as hc
    FROM folha.payroll_run r
    LEFT JOIN folha.payroll_result pr ON pr.run_id = r.run_id
    WHERE r.account_id = p_account_id
      AND r.status IN ('approved', 'closed')
      AND r.competencia >= (v_competencia_atual - interval '5 months')
    GROUP BY r.competencia
    ORDER BY r.competencia
  ) sub;

  total_empregados_ativos := v_total_ativos;
  custo_folha_mes_centavos := v_custo_mes;
  encargos_patronais_mes_centavos := v_encargos_mes;
  competencias_abertas := v_comp_abertas;
  competencias_fechadas_mes := v_comp_fechadas;
  distribuicao_regime := COALESCE(v_dist_regime, '[]'::jsonb);
  evolucao_custo_6m := COALESCE(v_evolucao, '[]'::jsonb);
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION folha.dashboard_completo(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION folha.dashboard_completo(uuid) TO dnex_gestao_folha_worker;
GRANT EXECUTE ON FUNCTION folha.dashboard_completo(uuid) TO authenticated;

COMMIT;