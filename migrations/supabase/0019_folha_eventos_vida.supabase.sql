-- DNEX Folha — Fase 2: Eventos de Vida (férias, 13º, rescisão)
-- Funções PL/pgSQL validadas end-to-end em produção em 2026-10-13.
-- Rollback: DROP FUNCTION folha.calc_ferias, folha.calc_13o, folha.calc_rescisao;
BEGIN;

-- ---------------------------------------------------------------------------
-- 1. calc_ferias — férias proporcionais/vencidas + 1/3 constitucional
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION folha.calc_ferias(
  p_contract_id uuid,
  p_competencia date DEFAULT CURRENT_DATE
) RETURNS TABLE (
  valor_ferias numeric,
  valor_um_terco numeric,
  total_ferias numeric,
  dias_vencidos integer,
  dias_proporcionais integer,
  base_calculo numeric,
  tabela_hash text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_salario numeric;
  v_data_admissao date;
  v_meses_trabalho integer;
  v_dias_prop integer;
  v_base numeric;
  v_ferias numeric;
  v_terco numeric;
BEGIN
  SELECT c.salario_base, c.data_admissao
  INTO v_salario, v_data_admissao
  FROM folha.employment_contract c
  WHERE c.contract_id = p_contract_id;

  IF v_salario IS NULL THEN
    RAISE EXCEPTION 'Contrato % não encontrado', p_contract_id;
  END IF;

  v_meses_trabalho := EXTRACT(YEAR FROM AGE(p_competencia, v_data_admissao)) * 12
                    + EXTRACT(MONTH FROM AGE(p_competencia, v_data_admissao));

  v_dias_prop := CASE
    WHEN v_meses_trabalho >= 12 THEN 30
    ELSE GREATEST(1, FLOOR(v_meses_trabalho / 12.0 * 30))::integer
  END;

  v_base := v_salario;
  v_ferias := v_base * (v_dias_prop / 30.0);
  v_terco := v_ferias / 3.0;

  valor_ferias := ROUND(v_ferias, 2);
  valor_um_terco := ROUND(v_terco, 2);
  total_ferias := ROUND(v_ferias + v_terco, 2);
  dias_vencidos := CASE WHEN v_meses_trabalho >= 12 THEN 30 ELSE 0 END;
  dias_proporcionais := v_dias_prop;
  base_calculo := v_base;
  tabela_hash := 'ferias_clt_art129_145';

  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION folha.calc_ferias(uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION folha.calc_ferias(uuid, date) TO dnex_gestao_folha_worker;
GRANT EXECUTE ON FUNCTION folha.calc_ferias(uuid, date) TO dnex_gestao_data_owner;

-- ---------------------------------------------------------------------------
-- 2. calc_13o — 13º salário proporcional com INSS/IRRF na 2ª parcela
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION folha.calc_13o(
  p_contract_id uuid,
  p_competencia date DEFAULT CURRENT_DATE,
  p_parcela integer DEFAULT 2
) RETURNS TABLE (
  valor_bruto numeric,
  inss numeric,
  irrf numeric,
  valor_liquido numeric,
  meses_proporcionais integer,
  base_calculo numeric
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_salario numeric;
  v_data_admissao date;
  v_meses integer;
  v_base numeric;
  v_inss_rec record;
  v_irrf_rec record;
BEGIN
  SELECT c.salario_base, c.data_admissao
  INTO v_salario, v_data_admissao
  FROM folha.employment_contract c
  WHERE c.contract_id = p_contract_id;

  IF v_salario IS NULL THEN
    RAISE EXCEPTION 'Contrato % não encontrado', p_contract_id;
  END IF;

  v_meses := EXTRACT(MONTH FROM AGE(p_competencia, v_data_admissao)) + 1;
  IF v_meses > 12 THEN v_meses := 12; END IF;

  -- Se admitido após dia 17 no mesmo ano, não conta o mês
  IF EXTRACT(DAY FROM v_data_admissao) > 17
     AND EXTRACT(YEAR FROM v_data_admissao) = EXTRACT(YEAR FROM p_competencia) THEN
    v_meses := v_meses - 1;
  END IF;
  v_meses := GREATEST(v_meses, 1);

  v_base := ROUND(v_salario * v_meses / 12.0, 2);

  IF p_parcela = 1 THEN
    -- 1ª parcela: sem descontos
    valor_bruto := v_base;
    inss := 0;
    irrf := 0;
    valor_liquido := v_base;
  ELSE
    -- 2ª parcela: com INSS e IRRF
    SELECT * INTO v_inss_rec FROM folha.calc_inss(v_base, p_competencia);
    SELECT * INTO v_irrf_rec FROM folha.calc_irrf(
      v_base - v_inss_rec.valor_inss, 0, false, p_competencia
    );
    valor_bruto := v_base;
    inss := v_inss_rec.valor_inss;
    irrf := v_irrf_rec.valor_irrf;
    valor_liquido := v_base - v_inss_rec.valor_inss - v_irrf_rec.valor_irrf;
  END IF;

  meses_proporcionais := v_meses;
  base_calculo := v_base;
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION folha.calc_13o(uuid, date, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION folha.calc_13o(uuid, date, integer) TO dnex_gestao_folha_worker;
GRANT EXECUTE ON FUNCTION folha.calc_13o(uuid, date, integer) TO dnex_gestao_data_owner;

-- ---------------------------------------------------------------------------
-- 3. calc_rescisao — TRCT completo (CLT art. 477)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION folha.calc_rescisao(
  p_contract_id uuid,
  p_data_demissao date,
  p_motivo text DEFAULT 'sem_justa_causa'
) RETURNS TABLE (
  saldo_salario numeric,
  ferias_vencidas numeric,
  terco_ferias_vencidas numeric,
  ferias_proporcionais numeric,
  terco_ferias_proporcionais numeric,
  decimo_terceiro_proporcional numeric,
  aviso_previo_indenizado numeric,
  multa_fgts numeric,
  total_proventos numeric,
  total_descontos numeric,
  liquido_rescisao numeric
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_salario numeric;
  v_data_admissao date;
  v_meses_trabalho integer;
  v_dias_mes integer;
  v_saldo_salario numeric;
  v_ferias_venc numeric := 0;
  v_terco_venc numeric := 0;
  v_ferias_prop numeric;
  v_terco_prop numeric;
  v_13o_prop numeric;
  v_aviso numeric := 0;
  v_multa_fgts numeric := 0;
  v_total_prov numeric;
  v_total_desc numeric := 0;
BEGIN
  SELECT c.salario_base, c.data_admissao
  INTO v_salario, v_data_admissao
  FROM folha.employment_contract c
  WHERE c.contract_id = p_contract_id;

  IF v_salario IS NULL THEN
    RAISE EXCEPTION 'Contrato % não encontrado', p_contract_id;
  END IF;

  -- Saldo de salário (dias trabalhados no mês da demissão)
  v_dias_mes := EXTRACT(DAY FROM p_data_demissao);
  v_saldo_salario := ROUND(v_salario * v_dias_mes / 30.0, 2);

  -- Meses trabalhados para férias e 13º
  v_meses_trabalho := EXTRACT(YEAR FROM AGE(p_data_demissao, v_data_admissao)) * 12
                    + EXTRACT(MONTH FROM AGE(p_data_demissao, v_data_admissao));

  -- Férias vencidas (se >= 12 meses)
  IF v_meses_trabalho >= 12 THEN
    v_ferias_venc := v_salario;
    v_terco_venc := ROUND(v_salario / 3.0, 2);
  END IF;

  -- Férias proporcionais
  v_ferias_prop := ROUND(v_salario * LEAST(v_meses_trabalho, 12) / 12.0, 2);
  v_terco_prop := ROUND(v_ferias_prop / 3.0, 2);

  -- 13º proporcional
  v_13o_prop := ROUND(v_salario * LEAST(EXTRACT(MONTH FROM p_data_demissao), 12) / 12.0, 2);

  -- Aviso prévio e multa FGTS (apenas sem justa causa)
  IF p_motivo = 'sem_justa_causa' THEN
    v_aviso := v_salario;
    v_multa_fgts := ROUND(v_salario * 0.40, 2);
  END IF;

  v_total_prov := v_saldo_salario + v_ferias_venc + v_terco_venc
                + v_ferias_prop + v_terco_prop + v_13o_prop
                + v_aviso + v_multa_fgts;

  saldo_salario := v_saldo_salario;
  ferias_vencidas := v_ferias_venc;
  terco_ferias_vencidas := v_terco_venc;
  ferias_proporcionais := v_ferias_prop;
  terco_ferias_proporcionais := v_terco_prop;
  decimo_terceiro_proporcional := v_13o_prop;
  aviso_previo_indenizado := v_aviso;
  multa_fgts := v_multa_fgts;
  total_proventos := v_total_prov;
  total_descontos := v_total_desc;
  liquido_rescisao := v_total_prov - v_total_desc;

  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION folha.calc_rescisao(uuid, date, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION folha.calc_rescisao(uuid, date, text) TO dnex_gestao_folha_worker;
GRANT EXECUTE ON FUNCTION folha.calc_rescisao(uuid, date, text) TO dnex_gestao_data_owner;

COMMIT;