-- DNEX Folha — Migration 0027: motor por rubricas, tipos de processo e trava de fechamento
-- (fatia 4, parte 2 de 2: funções). Depende da estrutura da 0026.
--
-- O que esta migration faz:
--   1. Exceções no lugar de zero silencioso (bloqueio de produção 5): calc_inss, calc_fgts,
--      irrf_apurar e calc_irrf_separado recusam remuneração nula ou negativa (zero continua
--      dando zero).
--   2. IRRF em separado com pendência própria (bloqueio 4): calc_irrf_separado_apurar devolve o
--      valor e as pendências do que não foi confirmado na fonte (alcance e teto da redução da
--      Lei 15.270/2025 e desconto simplificado na tributação em separado). calc_irrf_separado
--      continua devolvendo só o valor, para as funções da 0023.
--   3. INSS do segurado com remuneração de outros vínculos (calc_inss_segurado_multiplos).
--   4. Proporcionalidade por dias (dias_proporcionais), resolução das três camadas de regra
--      (resolver_regra) e avaliação da fórmula restrita (formula_avaliar).
--   5. run_payroll_employee: mesma assinatura da 0025; passa a calcular por rubricas, conforme
--      o tipo de processo da folha (mensal, adiantamento, complementar, 13º 1ª e 2ª parcela,
--      férias e rescisão — os três últimos pelas funções da 0023), gravando itens por rubrica,
--      bases, memória de cálculo com a camada da regra e pendências como dado.
--   6. Trava de fechamento (bloqueio 2): folha com pendência sem liberação registrada não é
--      aprovada nem fechada; fechar exige data de pagamento; data de pagamento anterior ao
--      início da competência é recusada (exceto férias, pagas antes do gozo).
--
-- NÃO altera as migrations 0014 a 0026. NÃO APLICAR EM PRODUÇÃO sem conferir o que está
-- a_validar e sem a dependência do dnex-gestao registrada na 0024.
-- Reversão: 0027_folha_motor_rubricas_processos.supabase.down.sql.
BEGIN;

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
  IF to_regclass('folha.payroll_pendency') IS NULL OR to_regclass('folha.rubric_rule') IS NULL THEN
    RAISE EXCEPTION '0027: faltam objetos da migration 0026'
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
END
$$;

-- ===========================================================================
-- 1. Exceção para remuneração nula ou negativa (corpos da 0025 com a conferência)
-- ===========================================================================
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
  v_piso numeric := 0;
  v_ls numeric;
BEGIN
  IF p_salario_contribuicao IS NULL OR p_salario_contribuicao < 0 THEN
    RAISE EXCEPTION 'calc_inss: salário de contribuição inválido: %', COALESCE(p_salario_contribuicao::text, 'NULL');
  END IF;

  SELECT t.tabela_json, t.vigencia_inicio, t.source_hash
    INTO v_tabela, v_vigencia, v_hash
    FROM folha.tax_table_version t
   WHERE t.tipo = 'inss'
     AND t.vigencia_inicio <= p_competencia
     AND (t.vigencia_fim IS NULL OR t.vigencia_fim >= p_competencia)
   ORDER BY t.vigencia_inicio DESC
   LIMIT 1;

  IF v_tabela IS NULL THEN
    RAISE EXCEPTION 'Tabela INSS não encontrada para competência %', p_competencia;
  END IF;

  v_teto := (v_tabela->>'teto')::numeric;
  IF v_teto IS NULL THEN
    RAISE EXCEPTION 'Tabela INSS de % sem teto', v_vigencia;
  END IF;
  v_base := LEAST(p_salario_contribuicao, v_teto);

  FOR v_faixa IN SELECT * FROM jsonb_array_elements(v_tabela->'faixas')
  LOOP
    v_ls := COALESCE((v_faixa->>'limite_superior')::numeric, v_teto);
    IF v_base > v_piso THEN
      v_valor := v_valor + (LEAST(v_base, v_ls) - v_piso) * (v_faixa->>'aliquota')::numeric;
    END IF;
    v_piso := v_ls;
  END LOOP;

  IF v_ls IS DISTINCT FROM v_teto THEN
    RAISE EXCEPTION 'Tabela INSS de % incoerente: a última faixa termina em % e o teto é %', v_vigencia, v_ls, v_teto;
  END IF;

  valor_inss := folha.arredondar_inss(v_valor, p_competencia);
  aliquota_efetiva := CASE WHEN p_salario_contribuicao > 0
                            THEN round(v_valor / p_salario_contribuicao, 4)
                            ELSE 0 END;
  tabela_vigencia := v_vigencia;
  tabela_hash := v_hash;
  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION folha.calc_fgts(
  p_remuneracao numeric,
  p_regime_trabalho text,
  p_competencia date
) RETURNS TABLE (
  fgts_deposito numeric,
  aliquota numeric,
  tabela_vigencia date,
  fonte_normativa text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_chave text;
BEGIN
  IF p_competencia IS NULL THEN
    RAISE EXCEPTION 'calc_fgts: competência obrigatória';
  END IF;
  IF p_remuneracao IS NULL OR p_remuneracao < 0 THEN
    RAISE EXCEPTION 'calc_fgts: remuneração inválida: %', COALESCE(p_remuneracao::text, 'NULL');
  END IF;

  IF p_regime_trabalho IN ('estagio', 'pj', 'contribuinte_individual') THEN
    fgts_deposito := 0;
    aliquota := 0;
    tabela_vigencia := NULL;
    fonte_normativa := NULL;
    RETURN NEXT;
    RETURN;
  END IF;

  v_chave := CASE p_regime_trabalho
               WHEN 'clt' THEN 'fgts_aliquota_empregado'
               WHEN 'aprendiz' THEN 'fgts_aliquota_aprendiz'
             END;
  IF v_chave IS NULL THEN
    RAISE EXCEPTION 'calc_fgts: categoria desconhecida: %', COALESCE(p_regime_trabalho, 'NULL');
  END IF;

  SELECT pp.valor, pp.vigencia_inicio, pp.fonte_normativa
    INTO aliquota, tabela_vigencia, fonte_normativa
    FROM folha.payroll_parameter pp
   WHERE pp.chave = v_chave
     AND pp.vigencia_inicio <= p_competencia
     AND (pp.vigencia_fim IS NULL OR pp.vigencia_fim >= p_competencia)
   ORDER BY pp.vigencia_inicio DESC
   LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Parâmetro % não encontrado para a data %', v_chave, p_competencia;
  END IF;

  fgts_deposito := round(p_remuneracao * aliquota, 2);
  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION folha.irrf_apurar(
  p_rendimento numeric,
  p_deducoes_legais numeric,
  p_num_dependentes integer,
  p_data_pagamento date,
  p_modo text
) RETURNS TABLE (
  valor_irrf numeric,
  imposto_tabela numeric,
  reducao numeric,
  base_calculo numeric,
  deducao_aplicada text,
  valor_deducao numeric,
  tabela_vigencia date,
  tabela_hash text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_tabela jsonb;
  v_faixa jsonb;
  v_ded_dep numeric;
  v_simpl numeric;
  v_legais numeric;
  v_achou boolean := false;
  v_lim_isencao numeric;
  v_ref numeric;
  v_ndep integer := COALESCE(p_num_dependentes, 0);
BEGIN
  IF p_data_pagamento IS NULL THEN
    RAISE EXCEPTION 'IRRF: data de pagamento obrigatória';
  END IF;
  IF p_modo IS NULL OR p_modo NOT IN ('mensal', 'separado') THEN
    RAISE EXCEPTION 'IRRF: modo desconhecido: %', COALESCE(p_modo, 'NULL');
  END IF;
  IF v_ndep < 0 OR COALESCE(p_deducoes_legais, 0) < 0 THEN
    RAISE EXCEPTION 'IRRF: dependentes e deduções não podem ser negativos';
  END IF;

  SELECT t.tabela_json, t.vigencia_inicio, t.source_hash
    INTO v_tabela, tabela_vigencia, tabela_hash
    FROM folha.tax_table_version t
   WHERE t.tipo = 'irrf'
     AND t.vigencia_inicio <= p_data_pagamento
     AND (t.vigencia_fim IS NULL OR t.vigencia_fim >= p_data_pagamento)
   ORDER BY t.vigencia_inicio DESC
   LIMIT 1;
  IF v_tabela IS NULL THEN
    RAISE EXCEPTION 'Tabela IRRF não encontrada para competência %', p_data_pagamento;
  END IF;

  valor_irrf := 0;
  imposto_tabela := 0;
  reducao := 0;
  base_calculo := 0;
  deducao_aplicada := 'nenhuma';
  valor_deducao := 0;
  IF p_rendimento IS NULL OR p_rendimento < 0 THEN
    RAISE EXCEPTION 'IRRF: rendimento inválido: %', COALESCE(p_rendimento::text, 'NULL');
  END IF;
  IF p_rendimento = 0 THEN
    RETURN NEXT;
    RETURN;
  END IF;

  v_ded_dep := (v_tabela->>'deducao_dependente_mensal')::numeric;
  IF v_ndep > 0 AND v_ded_dep IS NULL THEN
    RAISE EXCEPTION 'Tabela IRRF de % sem dedução por dependente cadastrada', p_data_pagamento;
  END IF;
  v_legais := COALESCE(p_deducoes_legais, 0) + v_ndep * COALESCE(v_ded_dep, 0);

  deducao_aplicada := 'legais';
  valor_deducao := v_legais;
  IF p_modo = 'mensal' THEN
    v_simpl := (v_tabela->>'desconto_simplificado_mensal')::numeric;
    IF v_simpl IS NULL THEN
      RAISE EXCEPTION 'Tabela IRRF de % sem desconto simplificado cadastrado', p_data_pagamento;
    END IF;
    IF v_simpl > v_legais THEN
      deducao_aplicada := 'simplificado';
      valor_deducao := v_simpl;
    END IF;
  END IF;

  base_calculo := GREATEST(p_rendimento - valor_deducao, 0);

  FOR v_faixa IN SELECT * FROM jsonb_array_elements(v_tabela->'faixas')
  LOOP
    IF (v_faixa->>'limite_superior') IS NULL OR base_calculo <= (v_faixa->>'limite_superior')::numeric THEN
      imposto_tabela := GREATEST(base_calculo * (v_faixa->>'aliquota')::numeric
                                 - (v_faixa->>'parcela_deduzir')::numeric, 0);
      v_achou := true;
      EXIT;
    END IF;
  END LOOP;
  IF NOT v_achou THEN
    RAISE EXCEPTION 'Tabela IRRF de % sem faixa para a base %', tabela_vigencia, base_calculo;
  END IF;

  -- Redução da Lei 15.270/2025: existe quando há parâmetro vigente na data do pagamento.
  SELECT pp.valor INTO v_lim_isencao
    FROM folha.payroll_parameter pp
   WHERE pp.chave = 'irrf_reducao_limite_isencao'
     AND pp.vigencia_inicio <= p_data_pagamento
     AND (pp.vigencia_fim IS NULL OR pp.vigencia_fim >= p_data_pagamento)
   ORDER BY pp.vigencia_inicio DESC
   LIMIT 1;
  IF FOUND THEN
    v_ref := CASE
      WHEN p_modo = 'mensal' THEN p_rendimento
      WHEN folha.get_param('irrf_redutor_referencia_bruto', p_data_pagamento) = 1 THEN p_rendimento
      ELSE p_rendimento - COALESCE(p_deducoes_legais, 0)
    END;
    IF v_ref <= v_lim_isencao THEN
      reducao := LEAST(imposto_tabela, folha.get_param('irrf_reducao_teto', p_data_pagamento));
    ELSIF v_ref <= folha.get_param('irrf_reducao_limite_parcial', p_data_pagamento) THEN
      reducao := LEAST(GREATEST(folha.get_param('irrf_redutor_coef_a', p_data_pagamento)
                                - folha.get_param('irrf_redutor_coef_b', p_data_pagamento) * v_ref, 0),
                       imposto_tabela);
    END IF;
  END IF;

  valor_irrf := GREATEST(round(imposto_tabela - reducao, 2), 0);
  RETURN NEXT;
END;
$$;

CREATE OR REPLACE FUNCTION folha.calc_irrf_separado(
  p_rendimento numeric,
  p_deducoes numeric DEFAULT 0,
  p_num_dependentes integer DEFAULT 0,
  p_competencia date DEFAULT CURRENT_DATE
) RETURNS numeric
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
BEGIN
  IF p_rendimento IS NULL OR p_rendimento < 0 THEN
    RAISE EXCEPTION 'calc_irrf_separado: rendimento inválido: %', COALESCE(p_rendimento::text, 'NULL');
  END IF;
  RETURN (SELECT a.valor_irrf
            FROM folha.irrf_apurar(p_rendimento, GREATEST(COALESCE(p_deducoes, 0), 0),
                                   GREATEST(COALESCE(p_num_dependentes, 0), 0),
                                   p_competencia, 'separado') a);
END;
$$;

-- ===========================================================================
-- 2. IRRF em separado com pendência própria
--    O valor é o de calc_irrf_separado. As pendências dizem o que, no resultado, depende de
--    ponto não confirmado na fonte:
--      a_validar:irrf_separado_reducao_lei_15270_alcance_e_teto — houve redução; o alcance na
--        tributação em separado (férias) e o teto de 312,89 no 13º não foram conferidos.
--      a_validar:irrf_separado_desconto_simplificado_nao_aplicado — o desconto simplificado
--        superaria as deduções legais e não foi aplicado (não conferido para a tributação em
--        separado; no 13º, de tributação exclusiva, retenção a maior não volta no ajuste).
-- ===========================================================================
CREATE FUNCTION folha.calc_irrf_separado_apurar(
  p_rendimento numeric,
  p_deducoes numeric,
  p_num_dependentes integer,
  p_data_pagamento date
) RETURNS TABLE (
  valor_irrf numeric,
  imposto_tabela numeric,
  reducao numeric,
  base_calculo numeric,
  pendencias text[]
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_a record;
  v_simpl numeric;
  v_ded_dep numeric;
  v_legais numeric;
BEGIN
  IF p_rendimento IS NULL OR p_rendimento < 0 THEN
    RAISE EXCEPTION 'calc_irrf_separado_apurar: rendimento inválido: %', COALESCE(p_rendimento::text, 'NULL');
  END IF;
  SELECT * INTO v_a
    FROM folha.irrf_apurar(p_rendimento, GREATEST(COALESCE(p_deducoes, 0), 0),
                           GREATEST(COALESCE(p_num_dependentes, 0), 0), p_data_pagamento, 'separado');
  valor_irrf := v_a.valor_irrf;
  imposto_tabela := v_a.imposto_tabela;
  reducao := v_a.reducao;
  base_calculo := v_a.base_calculo;
  pendencias := ARRAY[]::text[];

  IF v_a.imposto_tabela > 0 THEN
    IF v_a.reducao > 0 THEN
      pendencias := pendencias || ARRAY['a_validar:irrf_separado_reducao_lei_15270_alcance_e_teto'];
    END IF;
    SELECT (t.tabela_json->>'desconto_simplificado_mensal')::numeric,
           (t.tabela_json->>'deducao_dependente_mensal')::numeric
      INTO v_simpl, v_ded_dep
      FROM folha.tax_table_version t
     WHERE t.tipo = 'irrf'
       AND t.vigencia_inicio <= p_data_pagamento
       AND (t.vigencia_fim IS NULL OR t.vigencia_fim >= p_data_pagamento)
     ORDER BY t.vigencia_inicio DESC
     LIMIT 1;
    v_legais := GREATEST(COALESCE(p_deducoes, 0), 0)
              + GREATEST(COALESCE(p_num_dependentes, 0), 0) * COALESCE(v_ded_dep, 0);
    IF v_simpl IS NOT NULL AND v_simpl > v_legais THEN
      pendencias := pendencias || ARRAY['a_validar:irrf_separado_desconto_simplificado_nao_aplicado'];
    END IF;
  END IF;
  RETURN NEXT;
END;
$$;

-- ===========================================================================
-- 3. INSS do segurado com outras remunerações do mês
--    p_base_anterior: base já tributada NESTA fonte no mês (folha mensal anterior a uma
--      complementar). p_base_outras_fontes: salário de contribuição informado de outros
--      vínculos.
--    Empregado e aprendiz (parecer de INSS/FGTS, 5.1): valor = INSS(anteriores + esta base)
--      - INSS(anteriores), com a soma limitada ao teto; a progressão não recomeça. Com outras
--      fontes o critério segue a_validar (o parecer não traz caso conferido).
--    Contribuinte individual: a base anterior desta fonte consome o teto; para outras fontes
--      o parecer marca a regra "a validar na fonte" — o motor NÃO ajusta e devolve pendência.
-- ===========================================================================
CREATE FUNCTION folha.calc_inss_segurado_multiplos(
  p_base numeric,
  p_regime_trabalho text,
  p_competencia date,
  p_base_anterior numeric DEFAULT 0,
  p_base_outras_fontes numeric DEFAULT 0
) RETURNS TABLE (
  valor_inss numeric,
  aliquota_efetiva numeric,
  metodo text,
  base_contribuicao numeric,
  tabela_vigencia date,
  pendencias text[]
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_ant numeric := COALESCE(p_base_anterior, 0);
  v_out numeric := COALESCE(p_base_outras_fontes, 0);
  v_previo numeric;
  v_total record;
  v_parcial record;
BEGIN
  IF v_ant < 0 OR v_out < 0 THEN
    RAISE EXCEPTION 'calc_inss_segurado_multiplos: bases anteriores não podem ser negativas';
  END IF;
  IF (v_ant = 0 AND v_out = 0) OR p_regime_trabalho IN ('estagio', 'pj') THEN
    RETURN QUERY SELECT * FROM folha.calc_inss_segurado(p_base, p_regime_trabalho, p_competencia);
    RETURN;
  END IF;

  IF p_regime_trabalho = 'contribuinte_individual' THEN
    v_previo := v_ant;
  ELSE
    v_previo := v_ant + v_out;
  END IF;

  SELECT * INTO v_total FROM folha.calc_inss_segurado(v_previo + p_base, p_regime_trabalho, p_competencia);
  SELECT * INTO v_parcial FROM folha.calc_inss_segurado(v_previo, p_regime_trabalho, p_competencia);

  valor_inss := v_total.valor_inss - v_parcial.valor_inss;
  base_contribuicao := v_total.base_contribuicao - v_parcial.base_contribuicao;
  aliquota_efetiva := CASE WHEN p_base > 0 THEN round(valor_inss / p_base, 4) ELSE 0 END;
  metodo := v_total.metodo || CASE WHEN v_previo > 0 THEN '_com_base_anterior' ELSE '' END;
  tabela_vigencia := v_total.tabela_vigencia;
  pendencias := v_total.pendencias;
  IF v_out > 0 THEN
    IF p_regime_trabalho = 'contribuinte_individual' THEN
      pendencias := pendencias || ARRAY['pendencia:inss_contribuinte_individual_com_outras_fontes_sem_regra_confirmada_nao_ajustado'];
    ELSE
      pendencias := pendencias || ARRAY['a_validar:inss_multiplos_vinculos_criterio_de_deducao_das_outras_fontes'];
    END IF;
  END IF;
  RETURN NEXT;
END;
$$;

-- ===========================================================================
-- 4. Auxiliares do motor por rubricas
-- ===========================================================================

-- 4.1 Rubrica pelo código: a da conta vence a global de mesmo código.
CREATE FUNCTION folha.rubrica_por_codigo(p_conta uuid, p_codigo text) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
SET row_security = off
AS $$
  SELECT e.code_id
    FROM folha.earning_deduction_code e
   WHERE e.codigo = p_codigo AND (e.account_id = p_conta OR e.account_id IS NULL)
   ORDER BY (e.account_id IS NULL)
   LIMIT 1;
$$;

-- 4.2 Coerência entre o código de incidência e as bases ligadas, na data. Para cada tributo:
--     incidência que compõe base exige a ligação com a base do código (e só ela, entre as
--     bases daquele tributo); incidência que não compõe base não admite ligação.
CREATE FUNCTION folha.rubrica_conferir(p_code_id uuid, p_data date) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
SET row_security = off
AS $$
DECLARE
  v_codigo text;
  v_tributo text;
  v_inc record;
  v_ligadas uuid[];
BEGIN
  SELECT e.codigo INTO v_codigo FROM folha.earning_deduction_code e WHERE e.code_id = p_code_id;
  FOREACH v_tributo IN ARRAY ARRAY['previdencia', 'irrf', 'fgts'] LOOP
    SELECT ic.codigo, ic.efeito, ic.base_id INTO v_inc
      FROM folha.rubric_incidence ri
      JOIN folha.incidence_code ic ON ic.tributo = ri.tributo AND ic.codigo = ri.incidencia_codigo
     WHERE ri.code_id = p_code_id AND ri.tributo = v_tributo
       AND ri.vigencia_inicio <= p_data AND (ri.vigencia_fim IS NULL OR ri.vigencia_fim >= p_data);
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Rubrica % sem incidência de % vigente em %', v_codigo, v_tributo, p_data;
    END IF;
    SELECT COALESCE(array_agg(rb.base_id), ARRAY[]::uuid[]) INTO v_ligadas
      FROM folha.rubric_base rb
      JOIN folha.calculation_base b ON b.base_id = rb.base_id
     WHERE rb.code_id = p_code_id AND b.finalidade = v_tributo
       AND rb.vigencia_inicio <= p_data AND (rb.vigencia_fim IS NULL OR rb.vigencia_fim >= p_data);
    IF (v_inc.efeito = 'compoe_base' AND v_ligadas IS DISTINCT FROM ARRAY[v_inc.base_id])
       OR (v_inc.efeito <> 'compoe_base' AND cardinality(v_ligadas) > 0) THEN
      RAISE EXCEPTION 'Rubrica % incoerente em %: incidência de % com código % não corresponde às bases ligadas', v_codigo, p_data, v_tributo, v_inc.codigo;
    END IF;
  END LOOP;
END;
$$;

-- 4.3 Soma o valor de um item nas bases ligadas à rubrica (provento soma; desconto subtrai;
--     informativa e base não alteram). p_bases: objeto código da base -> valor.
CREATE FUNCTION folha.bases_somar(p_bases jsonb, p_code_id uuid, p_valor numeric, p_data date) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
SET row_security = off
AS $$
DECLARE
  v_tipo text;
  v_b record;
  v_out jsonb := p_bases;
BEGIN
  SELECT e.tipo_rubrica INTO v_tipo FROM folha.earning_deduction_code e WHERE e.code_id = p_code_id;
  IF v_tipo NOT IN ('provento', 'desconto') THEN
    RETURN v_out;
  END IF;
  FOR v_b IN
    SELECT b.codigo
      FROM folha.rubric_base rb
      JOIN folha.calculation_base b ON b.base_id = rb.base_id
     WHERE rb.code_id = p_code_id
       AND rb.vigencia_inicio <= p_data AND (rb.vigencia_fim IS NULL OR rb.vigencia_fim >= p_data)
  LOOP
    v_out := jsonb_set(v_out, ARRAY[v_b.codigo],
               to_jsonb(COALESCE((v_out->>v_b.codigo)::numeric, 0)
                        + CASE WHEN v_tipo = 'provento' THEN p_valor ELSE -p_valor END));
  END LOOP;
  RETURN v_out;
END;
$$;

-- 4.4 Avaliação da fórmula restrita (árvore validada por formula_valida). Sem SQL dinâmico.
CREATE FUNCTION folha.formula_avaliar(p_no jsonb, p_vars jsonb, p_bases jsonb) RETURNS numeric
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_op text;
  v_vals numeric[] := ARRAY[]::numeric[];
  v_arg jsonb;
  v_x numeric;
  v_prod numeric := 1;
BEGIN
  IF p_no ? 'num' THEN
    RETURN (p_no->>'num')::numeric;
  ELSIF p_no ? 'var' THEN
    IF (p_vars->>(p_no->>'var')) IS NULL THEN
      RAISE EXCEPTION 'Fórmula: a variável % não tem valor neste cálculo', p_no->>'var';
    END IF;
    RETURN (p_vars->>(p_no->>'var'))::numeric;
  ELSIF p_no ? 'base' THEN
    IF NOT p_bases ? (p_no->>'base') THEN
      RAISE EXCEPTION 'Fórmula: a base % não existe para esta conta', p_no->>'base';
    END IF;
    RETURN (p_bases->>(p_no->>'base'))::numeric;
  END IF;
  v_op := p_no->>'op';
  FOR v_arg IN SELECT * FROM jsonb_array_elements(p_no->'args') LOOP
    v_vals := v_vals || folha.formula_avaliar(v_arg, p_vars, p_bases);
  END LOOP;
  CASE v_op
    WHEN 'soma' THEN RETURN (SELECT sum(x) FROM unnest(v_vals) x);
    WHEN 'subtrai' THEN RETURN v_vals[1] - v_vals[2];
    WHEN 'multiplica' THEN
      FOREACH v_x IN ARRAY v_vals LOOP v_prod := v_prod * v_x; END LOOP;
      RETURN v_prod;
    WHEN 'divide' THEN
      IF v_vals[2] = 0 THEN RAISE EXCEPTION 'Fórmula: divisão por zero'; END IF;
      RETURN v_vals[1] / v_vals[2];
    WHEN 'minimo' THEN RETURN (SELECT min(x) FROM unnest(v_vals) x);
    WHEN 'maximo' THEN RETURN (SELECT max(x) FROM unnest(v_vals) x);
    WHEN 'arredonda2' THEN RETURN round(v_vals[1], 2);
    ELSE RAISE EXCEPTION 'Fórmula: operação desconhecida: %', COALESCE(v_op, 'NULL');
  END CASE;
END;
$$;

-- 4.5 Regra vigente de uma rubrica para um contrato, pelas três camadas. Vence a camada de
--     maior precedência (rule_layer); as vencidas voltam para a memória de cálculo.
--     A regra da convenção só vale se a convenção estiver vigente na data.
CREATE FUNCTION folha.resolver_regra(
  p_conta uuid,
  p_contract_id uuid,
  p_code_id uuid,
  p_data date
) RETURNS TABLE (
  rule_id uuid,
  camada text,
  forma_calculo text,
  valor numeric,
  percentual numeric,
  base_id uuid,
  valor_unitario numeric,
  formula jsonb,
  automatica boolean,
  fonte text,
  vencidas jsonb
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
SET row_security = off
AS $$
  WITH k AS (
    SELECT c.employer_id, c.agreement_id
      FROM folha.employment_contract c
     WHERE c.account_id = p_conta AND c.contract_id = p_contract_id
  ), cand AS (
    SELECT r.*, l.precedencia
      FROM folha.rubric_rule r
      JOIN folha.rule_layer l ON l.camada = r.camada
      CROSS JOIN k
     WHERE r.account_id = p_conta
       AND r.code_id = p_code_id
       AND r.vigencia_inicio <= p_data AND (r.vigencia_fim IS NULL OR r.vigencia_fim >= p_data)
       AND (   (r.camada = 'empresa' AND r.employer_id = k.employer_id)
            OR (r.camada = 'contrato' AND r.contract_id = p_contract_id)
            OR (r.camada = 'convencao' AND r.agreement_id = k.agreement_id
                AND EXISTS (SELECT 1 FROM folha.collective_agreement a
                             WHERE a.account_id = p_conta AND a.agreement_id = r.agreement_id
                               AND a.vigencia_inicio <= p_data AND a.vigencia_fim >= p_data)))
  ), ordenada AS (
    SELECT cand.*, row_number() OVER (ORDER BY cand.precedencia DESC) AS posicao FROM cand
  )
  SELECT o.rule_id, o.camada, o.forma_calculo, o.valor, o.percentual, o.base_id, o.valor_unitario,
         o.formula, o.automatica, o.fonte,
         COALESCE((SELECT jsonb_agg(jsonb_build_object('camada', v.camada, 'rule_id', v.rule_id, 'fonte', v.fonte)
                                    ORDER BY v.precedencia DESC)
                     FROM ordenada v WHERE v.posicao > 1), '[]'::jsonb)
    FROM ordenada o
   WHERE o.posicao = 1;
$$;

-- 4.6 Dias pagos no mês (admissão, desligamento e afastamento que suspende o pagamento).
--     Mês inteiro de contrato sem afastamento: proporcional = false e nada é lido de parâmetro.
--     Critério do parecer de rescisão (saldo de salário): salário / divisor x dias; dias de
--     contrato no mês limitados ao divisor; mês inteiro = divisor. O divisor é o parâmetro
--     divisor_saldo_salario (a_validar). Dias de afastamento com pagamento suspenso são
--     abatidos (critério de dias não tratado nos pareceres: pendência a_validar).
CREATE FUNCTION folha.dias_proporcionais(
  p_contract_id uuid,
  p_competencia date
) RETURNS TABLE (
  proporcional boolean,
  dias numeric,
  divisor numeric,
  dias_contrato integer,
  dias_afastamento integer,
  por_admissao_ou_desligamento boolean,
  desligamento_no_mes boolean,
  pendencias text[]
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_conta uuid := folha.current_account_id();
  v_ini date := date_trunc('month', p_competencia::timestamp)::date;
  v_fim date := (date_trunc('month', p_competencia::timestamp) + interval '1 month' - interval '1 day')::date;
  v_adm date;
  v_dem date;
  v_de date;
  v_ate date;
  v_base integer;
BEGIN
  IF p_competencia IS NULL THEN
    RAISE EXCEPTION 'dias_proporcionais: competência obrigatória';
  END IF;
  SELECT c.data_admissao, c.data_demissao INTO v_adm, v_dem
    FROM folha.employment_contract c
   WHERE c.contract_id = p_contract_id AND c.account_id = v_conta;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Contrato % não encontrado', p_contract_id;
  END IF;
  IF v_adm > v_fim OR (v_dem IS NOT NULL AND v_dem < v_ini) THEN
    RAISE EXCEPTION 'Contrato % sem dias de contrato na competência %', p_contract_id, v_ini;
  END IF;

  v_de := GREATEST(v_adm, v_ini);
  v_ate := LEAST(COALESCE(v_dem, v_fim), v_fim);
  dias_contrato := v_ate - v_de + 1;
  por_admissao_ou_desligamento := v_de > v_ini OR v_ate < v_fim;
  desligamento_no_mes := v_dem IS NOT NULL AND v_dem <= v_fim;

  SELECT count(*)::integer INTO dias_afastamento
    FROM generate_series(v_de, v_ate, interval '1 day') AS d(dia)
   WHERE EXISTS (SELECT 1 FROM folha.contract_leave l
                  WHERE l.account_id = v_conta AND l.contract_id = p_contract_id
                    AND l.suspende_pagamento
                    AND l.data_inicio <= d.dia::date
                    AND (l.data_fim IS NULL OR l.data_fim >= d.dia::date));

  pendencias := ARRAY[]::text[];
  IF NOT por_admissao_ou_desligamento AND dias_afastamento = 0 THEN
    proporcional := false;
    dias := NULL;
    divisor := NULL;
    RETURN NEXT;
    RETURN;
  END IF;

  proporcional := true;
  divisor := folha.get_param('divisor_saldo_salario', v_ini);
  v_base := CASE WHEN por_admissao_ou_desligamento
                 THEN LEAST(dias_contrato, divisor::integer)
                 ELSE divisor::integer END;
  dias := CASE WHEN dias_afastamento >= dias_contrato THEN 0
               ELSE GREATEST(v_base - dias_afastamento, 0) END;
  pendencias := folha.params_a_validar(ARRAY['divisor_saldo_salario'], v_ini);
  IF dias_afastamento > 0 THEN
    pendencias := pendencias || ARRAY['a_validar:proporcionalidade_por_afastamento_criterio_de_dias'];
  END IF;
  RETURN NEXT;
END;
$$;

-- ===========================================================================
-- 5. Cálculo por tipo de processo. Cada função devolve um JSON com:
--      itens (lista, na ordem): codigo, valor, quantidade, base_calculo, aliquota, camada,
--        rule_id, entry_id, detalhe
--      bases (código -> valor), inss, irrf, fgts, base_patronal, base_patronal_13,
--      encargos (true/false), pendencias (lista), cabecalho (dados do primeiro passo)
--    Nenhuma delas grava: quem grava é folha_gravar_resultado.
-- ===========================================================================

-- 5.1 Folha de rubricas: mensal, adiantamento e complementar.
CREATE FUNCTION folha.folha_rubricas_calcular(
  p_conta uuid,
  p_run_id uuid,
  p_contract_id uuid,
  p_tipo text,
  p_competencia date,
  p_data_pagamento date,
  p_num_dependentes integer,
  p_num_filhos integer
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
SET row_security = off
AS $$
DECLARE
  v_employee uuid;
  v_salario numeric;
  v_categoria text;
  v_itens jsonb := '[]'::jsonb;
  v_bases jsonb;
  v_pend text[] := ARRAY[]::text[];
  v_dias record;
  v_valor numeric;
  v_valor_salario numeric := 0;
  v_l record;
  v_r record;
  v_tem_regra boolean;
  v_vars jsonb;
  v_base_valor numeric;
  v_base_cod text;
  v_adiant numeric;
  v_outros numeric := 0;
  v_ant_base numeric := 0;
  v_ant_inss numeric := 0;
  v_ant_rend numeric := 0;
  v_ant_irrf numeric := 0;
  v_ant_mesmo_mes boolean := true;
  v_tem_anterior boolean := false;
  v_inss record;
  v_irrf record;
  v_irrf_valor numeric;
  v_fgts record;
  v_sf record;
  v_base_inss numeric;
  v_base_irrf numeric;
  v_base_fgts numeric;
  v_rem_sf numeric;
  v_fracao numeric := 1;
BEGIN
  SELECT c.employee_id, c.salario_base, c.regime_trabalho
    INTO v_employee, v_salario, v_categoria
    FROM folha.employment_contract c
   WHERE c.contract_id = p_contract_id AND c.account_id = p_conta;

  -- Sem tabela de INSS para a competência o cálculo para aqui, antes de qualquer rubrica.
  PERFORM 1 FROM folha.calc_inss_segurado(0, v_categoria, p_competencia);

  SELECT COALESCE(jsonb_object_agg(b.codigo, 0), '{}'::jsonb) INTO v_bases
    FROM folha.calculation_base b
   WHERE b.account_id IS NULL
      OR (b.account_id = p_conta
          AND NOT EXISTS (SELECT 1 FROM folha.calculation_base g WHERE g.account_id IS NULL AND g.codigo = b.codigo));

  -- (a) Salário contratual, só na mensal: integral ou proporcional aos dias.
  IF p_tipo = 'mensal' THEN
    IF EXISTS (SELECT 1 FROM folha.payroll_result pr
                 JOIN folha.payroll_run r ON r.run_id = pr.run_id
                WHERE pr.account_id = p_conta AND pr.contract_id = p_contract_id
                  AND r.competencia = p_competencia AND r.tipo_processo = 'rescisao'
                  AND r.status <> 'cancelled') THEN
      RAISE EXCEPTION 'Contrato % já tem rescisão calculada na competência %: o saldo de salário sai na rescisão, não na folha mensal', p_contract_id, p_competencia;
    END IF;
    IF EXISTS (SELECT 1 FROM folha.payroll_result pr
                 JOIN folha.payroll_run r ON r.run_id = pr.run_id
                WHERE pr.account_id = p_conta AND pr.contract_id = p_contract_id
                  AND r.competencia = p_competencia AND r.tipo_processo IN ('mensal', 'complementar')
                  AND r.status <> 'cancelled' AND r.run_id <> p_run_id) THEN
      RAISE EXCEPTION 'Contrato % já tem folha mensal ou complementar calculada na competência %: o salário sairia duas vezes ou o INSS recomeçaria a progressão', p_contract_id, p_competencia;
    END IF;
    -- Recibo de férias na competência: o motor ainda não abate os dias de gozo do salário nem
    -- reapura o INSS do mês sobre o total (parecer de 13º e férias, 2.7). Vira pendência.
    IF EXISTS (SELECT 1 FROM folha.payroll_result pr
                 JOIN folha.payroll_run r ON r.run_id = pr.run_id
                WHERE pr.account_id = p_conta AND pr.contract_id = p_contract_id
                  AND r.competencia = p_competencia AND r.tipo_processo = 'ferias'
                  AND r.status <> 'cancelled') THEN
      v_pend := v_pend || ARRAY['pendencia:ferias_na_competencia_salario_e_inss_do_mes_nao_reapurados'];
    END IF;
    SELECT * INTO v_dias FROM folha.dias_proporcionais(p_contract_id, p_competencia);
    v_pend := v_pend || v_dias.pendencias;
    IF v_dias.desligamento_no_mes THEN
      v_pend := v_pend || ARRAY['pendencia:desligamento_no_mes_conferir_se_o_saldo_sera_pago_na_rescisao'];
    END IF;
    IF v_dias.proporcional THEN
      v_valor_salario := round(v_salario / v_dias.divisor * v_dias.dias, 2);
    ELSE
      v_valor_salario := v_salario;
    END IF;
    v_itens := v_itens || jsonb_build_object(
      'codigo', 'SALARIO_BASE', 'valor', v_valor_salario,
      'quantidade', CASE WHEN v_dias.proporcional THEN v_dias.dias END,
      'base_calculo', v_salario,
      'aliquota', CASE WHEN v_dias.proporcional THEN round(v_dias.dias / v_dias.divisor, 4) ELSE 1.0000 END,
      'camada', 'motor',
      'detalhe', jsonb_build_object('origem', 'salário do contrato', 'proporcional', v_dias.proporcional,
                                    'dias', v_dias.dias, 'divisor', v_dias.divisor,
                                    'dias_contrato', v_dias.dias_contrato,
                                    'dias_afastamento', v_dias.dias_afastamento));
    v_bases := folha.bases_somar(v_bases, folha.rubrica_por_codigo(p_conta, 'SALARIO_BASE'), v_valor_salario, p_competencia);
  END IF;

  -- (b) Lançamentos do período e regras automáticas (estas só na mensal), na ordem de cálculo
  --     da rubrica. Rubrica com lançamento não recebe também o lançamento automático.
  FOR v_l IN
    SELECT x.entry_id, x.code_id, x.quantidade, x.valor,
           e.codigo, e.tipo_rubrica, e.forma_calculo, e.ordem_calculo
      FROM (
        SELECT pe.entry_id, pe.code_id, pe.quantidade, pe.valor, pe.created_at
          FROM folha.payroll_entry pe
         WHERE pe.account_id = p_conta AND pe.contract_id = p_contract_id
           AND pe.competencia = p_competencia AND pe.tipo_processo = p_tipo
        UNION ALL
        SELECT NULL::uuid, a.code_id, NULL::numeric, NULL::numeric, NULL::timestamptz
          FROM (SELECT DISTINCT rr.code_id
                  FROM folha.rubric_rule rr
                 WHERE rr.account_id = p_conta AND rr.automatica
                   AND rr.vigencia_inicio <= p_competencia
                   AND (rr.vigencia_fim IS NULL OR rr.vigencia_fim >= p_competencia)) a
         WHERE p_tipo = 'mensal'
           AND NOT EXISTS (SELECT 1 FROM folha.payroll_entry pe2
                            WHERE pe2.account_id = p_conta AND pe2.contract_id = p_contract_id
                              AND pe2.competencia = p_competencia AND pe2.tipo_processo = p_tipo
                              AND pe2.code_id = a.code_id)
           AND COALESCE((SELECT rg.automatica
                           FROM folha.resolver_regra(p_conta, p_contract_id, a.code_id, p_competencia) rg), false)
      ) x
      JOIN folha.earning_deduction_code e ON e.code_id = x.code_id
     ORDER BY e.ordem_calculo, e.codigo, x.created_at, x.entry_id
  LOOP
    IF v_l.forma_calculo = 'apuracao_motor' THEN
      RAISE EXCEPTION 'Rubrica % é apurada pelo motor e não aceita lançamento nem regra', v_l.codigo;
    END IF;
    IF v_l.tipo_rubrica = 'base' THEN
      RAISE EXCEPTION 'Rubrica % é do tipo base e não aceita lançamento', v_l.codigo;
    END IF;
    PERFORM folha.rubrica_conferir(v_l.code_id, p_competencia);

    SELECT * INTO v_r FROM folha.resolver_regra(p_conta, p_contract_id, v_l.code_id, p_competencia);
    v_tem_regra := FOUND;
    v_base_valor := NULL;
    v_base_cod := NULL;

    IF NOT v_tem_regra THEN
      IF v_l.valor IS NULL THEN
        RAISE EXCEPTION 'Rubrica % sem regra vigente para o contrato e sem valor informado no lançamento', v_l.codigo;
      END IF;
      v_valor := v_l.valor;
    ELSIF v_r.forma_calculo = 'formula' THEN
      v_vars := jsonb_build_object('SALARIO', v_salario, 'QUANTIDADE', v_l.quantidade, 'VALOR', v_l.valor);
      v_valor := round(folha.formula_avaliar(v_r.formula, v_vars, v_bases), 2);
    ELSE
      IF v_l.valor IS NOT NULL THEN
        RAISE EXCEPTION 'Rubrica %: o lançamento informa valor, mas a regra vigente (camada %) calcula o valor', v_l.codigo, v_r.camada;
      END IF;
      IF v_r.forma_calculo = 'valor_fixo' THEN
        v_valor := v_r.valor;
      ELSIF v_r.forma_calculo = 'percentual_base' THEN
        SELECT b.codigo INTO v_base_cod FROM folha.calculation_base b WHERE b.base_id = v_r.base_id;
        v_base_valor := (v_bases->>v_base_cod)::numeric;
        IF v_base_valor IS NULL OR v_base_valor < 0 THEN
          RAISE EXCEPTION 'Rubrica %: a base % está indisponível ou negativa (%)', v_l.codigo, v_base_cod, v_base_valor;
        END IF;
        v_valor := round(v_base_valor * v_r.percentual, 2);
      ELSE
        IF v_l.quantidade IS NULL THEN
          RAISE EXCEPTION 'Rubrica %: a regra é quantidade x valor e o lançamento não informa a quantidade', v_l.codigo;
        END IF;
        v_valor := round(v_l.quantidade * v_r.valor_unitario, 2);
      END IF;
    END IF;
    IF v_valor IS NULL OR v_valor < 0 THEN
      RAISE EXCEPTION 'Rubrica %: valor calculado inválido (%)', v_l.codigo, COALESCE(v_valor::text, 'NULL');
    END IF;

    v_itens := v_itens || jsonb_build_object(
      'codigo', v_l.codigo, 'valor', v_valor, 'quantidade', v_l.quantidade,
      'base_calculo', v_base_valor,
      'aliquota', CASE WHEN v_tem_regra THEN v_r.percentual END,
      'camada', CASE WHEN v_tem_regra THEN v_r.camada ELSE 'lancamento' END,
      'rule_id', CASE WHEN v_tem_regra THEN v_r.rule_id END,
      'entry_id', v_l.entry_id,
      'detalhe', CASE WHEN v_tem_regra
                      THEN jsonb_build_object('forma_calculo', v_r.forma_calculo, 'fonte_da_regra', v_r.fonte,
                                              'base', v_base_cod, 'valor_unitario', v_r.valor_unitario,
                                              'regras_vencidas', v_r.vencidas,
                                              'automatica', v_l.entry_id IS NULL)
                      ELSE jsonb_build_object('forma_calculo', 'valor informado no lançamento') END);
    v_bases := folha.bases_somar(v_bases, v_l.code_id, v_valor, p_competencia);
    IF v_l.codigo = 'PENSAO_ALIMENTICIA' THEN
      -- A pensão é dedução legal do IRRF (parecer de INSS/FGTS, 5.3); o motor ainda não a deduz.
      v_pend := v_pend || ARRAY['pendencia:pensao_alimenticia_nao_deduzida_da_base_do_irrf'];
    END IF;
  END LOOP;

  -- Adiantamento: só o que foi lançado ou regrado; tributos e encargos ficam na folha mensal.
  IF p_tipo = 'adiantamento' THEN
    IF jsonb_array_length(v_itens) = 0 THEN
      RAISE EXCEPTION 'Folha de adiantamento sem lançamento para o contrato %', p_contract_id;
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_itens) i WHERE i->>'codigo' <> 'ADIANTAMENTO_SALARIAL_PAGO') THEN
      RAISE EXCEPTION 'Folha de adiantamento só aceita a rubrica ADIANTAMENTO_SALARIAL_PAGO';
    END IF;
    RETURN jsonb_build_object(
      'itens', v_itens, 'bases', '{}'::jsonb, 'inss', 0, 'irrf', 0, 'fgts', 0,
      'base_patronal', 0, 'base_patronal_13', 0, 'encargos', false,
      'pendencias', to_jsonb(v_pend),
      'cabecalho', jsonb_build_object('categoria', v_categoria, 'competencia', p_competencia,
                                      'data_pagamento', p_data_pagamento, 'tipo_processo', p_tipo));
  END IF;
  IF p_tipo = 'complementar' AND jsonb_array_length(v_itens) = 0 THEN
    RAISE EXCEPTION 'Folha complementar sem lançamento para o contrato %', p_contract_id;
  END IF;

  -- (c) Mensal: desconta o adiantamento pago na competência.
  IF p_tipo = 'mensal' THEN
    SELECT COALESCE(sum(i.valor), 0),
           COALESCE(bool_and(COALESCE(date_trunc('month', r.data_pagamento::timestamp) = date_trunc('month', p_data_pagamento::timestamp), false)), true)
      INTO v_adiant, v_ant_mesmo_mes
      FROM folha.payroll_result_item i
      JOIN folha.payroll_result pr ON pr.result_id = i.result_id
      JOIN folha.payroll_run r ON r.run_id = pr.run_id
     WHERE i.account_id = p_conta AND pr.contract_id = p_contract_id
       AND r.competencia = p_competencia AND r.tipo_processo = 'adiantamento' AND r.status <> 'cancelled'
       AND i.rubrica_codigo = 'ADIANTAMENTO_SALARIAL_PAGO';
    IF v_adiant > 0 THEN
      v_itens := v_itens || jsonb_build_object(
        'codigo', 'ADIANTAMENTO_SALARIAL', 'valor', v_adiant, 'camada', 'motor',
        'detalhe', jsonb_build_object('origem', 'folhas de adiantamento da competência'));
      IF NOT v_ant_mesmo_mes THEN
        v_pend := v_pend || ARRAY['a_validar:irrf_adiantamento_pago_em_mes_diferente_do_saldo'];
      END IF;
    END IF;
    v_ant_mesmo_mes := true;
  END IF;

  -- (d) Complementar: o que esta fonte já tributou na competência (mensal e complementares).
  IF p_tipo = 'complementar' THEN
    SELECT count(*) > 0,
           COALESCE(sum((SELECT b.valor FROM folha.payroll_result_base b
                          WHERE b.result_id = pr.result_id AND b.base_codigo = 'INSS_MENSAL')), 0),
           COALESCE(sum(pr.inss_empregado), 0),
           COALESCE(sum((SELECT b.valor FROM folha.payroll_result_base b
                          WHERE b.result_id = pr.result_id AND b.base_codigo = 'IRRF_MENSAL')), 0),
           COALESCE(sum(pr.irrf), 0),
           COALESCE(bool_and(date_trunc('month', r.data_pagamento::timestamp) = date_trunc('month', p_data_pagamento::timestamp)), false)
      INTO v_tem_anterior, v_ant_base, v_ant_inss, v_ant_rend, v_ant_irrf, v_ant_mesmo_mes
      FROM folha.payroll_result pr
      JOIN folha.payroll_run r ON r.run_id = pr.run_id
     WHERE pr.account_id = p_conta AND pr.contract_id = p_contract_id
       AND r.competencia = p_competencia AND r.tipo_processo IN ('mensal', 'complementar')
       AND r.status <> 'cancelled' AND r.run_id <> p_run_id;
  END IF;

  -- (e) Tributos sobre as bases formadas pelas rubricas.
  v_base_inss := (v_bases->>'INSS_MENSAL')::numeric;
  v_base_irrf := (v_bases->>'IRRF_MENSAL')::numeric;
  v_base_fgts := (v_bases->>'FGTS_MENSAL')::numeric;
  IF v_base_inss < 0 OR v_base_irrf < 0 OR v_base_fgts < 0 THEN
    RAISE EXCEPTION 'Contrato %: base negativa (INSS %, IRRF %, FGTS %); os descontos superam os proventos', p_contract_id, v_base_inss, v_base_irrf, v_base_fgts;
  END IF;

  SELECT COALESCE(sum(x.base_previdencia), 0) INTO v_outros
    FROM folha.external_remuneration x
   WHERE x.account_id = p_conta AND x.employee_id = v_employee AND x.competencia = p_competencia;

  SELECT * INTO v_inss
    FROM folha.calc_inss_segurado_multiplos(v_base_inss, v_categoria, p_competencia, v_ant_base, v_outros);
  v_pend := v_pend || v_inss.pendencias;

  IF v_tem_anterior AND v_ant_mesmo_mes THEN
    -- Mesmo mês de pagamento: imposto sobre a soma dos rendimentos do mês, menos o já retido.
    SELECT * INTO v_irrf FROM folha.calc_irrf(v_ant_rend + v_base_irrf, v_ant_inss + v_inss.valor_inss,
                                              COALESCE(p_num_dependentes, 0), p_data_pagamento);
    v_irrf_valor := GREATEST(v_irrf.valor_irrf - v_ant_irrf, 0);
    v_pend := v_pend || ARRAY['a_validar:irrf_complementar_soma_dos_pagamentos_do_mes'];
    IF v_irrf.valor_irrf < v_ant_irrf THEN
      v_pend := v_pend || ARRAY['pendencia:irrf_ja_retido_no_mes_maior_que_o_devido_sobre_a_soma'];
    END IF;
  ELSE
    SELECT * INTO v_irrf FROM folha.calc_irrf(v_base_irrf, v_inss.valor_inss,
                                              COALESCE(p_num_dependentes, 0), p_data_pagamento);
    v_irrf_valor := v_irrf.valor_irrf;
    IF v_tem_anterior THEN
      v_pend := v_pend || ARRAY['a_validar:irrf_complementar_pago_em_outro_mes_calculado_em_separado'];
    END IF;
  END IF;
  v_pend := v_pend || v_irrf.pendencias;

  SELECT * INTO v_fgts FROM folha.calc_fgts(v_base_fgts, v_categoria, p_competencia);

  -- (f) Salário-família (só na mensal). Direito pela remuneração que seria devida no mês,
  --     somados os outros vínculos; cota proporcional só em admissão e desligamento.
  IF p_tipo = 'mensal' AND COALESCE(p_num_filhos, 0) > 0 THEN
    IF v_categoria IN ('clt', 'aprendiz') THEN
      v_rem_sf := (v_bases->>'SALARIO_FAMILIA')::numeric + (v_salario - v_valor_salario) + v_outros;
      IF v_dias.proporcional AND v_dias.por_admissao_ou_desligamento THEN
        v_fracao := LEAST(v_dias.dias_contrato, v_dias.divisor) / v_dias.divisor;
      END IF;
      SELECT * INTO v_sf FROM folha.calc_salario_familia(v_rem_sf, p_num_filhos, p_competencia, v_fracao);
      v_pend := v_pend || v_sf.pendencias;
      IF v_sf.valor > 0 THEN
        v_itens := v_itens || jsonb_build_object(
          'codigo', 'SALARIO_FAMILIA', 'valor', v_sf.valor, 'quantidade', p_num_filhos,
          'base_calculo', v_rem_sf, 'camada', 'motor',
          'detalhe', jsonb_build_object('cota', v_sf.cota, 'remuneracao_limite', v_sf.remuneracao_limite,
                                        'filhos', p_num_filhos, 'fracao_dias', v_fracao));
      END IF;
    ELSE
      v_pend := v_pend || ARRAY['pendencia:salario_familia_nao_calculado_para_a_categoria'];
    END IF;
  END IF;

  v_itens := v_itens
    || jsonb_build_object(
         'codigo', 'INSS_EMPREGADO', 'valor', v_inss.valor_inss, 'base_calculo', v_inss.base_contribuicao,
         'aliquota', v_inss.aliquota_efetiva, 'camada', 'motor',
         'detalhe', jsonb_build_object('metodo', v_inss.metodo, 'tabela_vigencia', v_inss.tabela_vigencia,
                                       'base_anterior_desta_fonte', v_ant_base, 'base_outras_fontes', v_outros))
    || jsonb_build_object(
         'codigo', 'IRRF', 'valor', v_irrf_valor, 'base_calculo', v_irrf.base_calculo,
         'aliquota', CASE WHEN v_base_irrf > 0 THEN round(v_irrf_valor / v_base_irrf, 4) ELSE 0 END, 'camada', 'motor',
         'detalhe', jsonb_build_object('rendimento_tributavel', v_base_irrf, 'deducao_aplicada', v_irrf.desconto_aplicado,
                                       'dependentes', COALESCE(p_num_dependentes, 0), 'imposto_tabela', v_irrf.imposto_tabela,
                                       'redutor_lei_15270', v_irrf.redutor_lei_15270, 'tabela_vigencia', v_irrf.tabela_vigencia,
                                       'data_pagamento', p_data_pagamento,
                                       'rendimento_anterior_no_mes', v_ant_rend, 'irrf_ja_retido', v_ant_irrf))
    || jsonb_build_object(
         'codigo', 'FGTS_DEPOSITO', 'valor', v_fgts.fgts_deposito, 'base_calculo', v_base_fgts,
         'aliquota', v_fgts.aliquota, 'camada', 'motor',
         'detalhe', jsonb_build_object('tabela_vigencia', v_fgts.tabela_vigencia, 'fonte_normativa', v_fgts.fonte_normativa));

  RETURN jsonb_build_object(
    'itens', v_itens, 'bases', v_bases,
    'inss', v_inss.valor_inss, 'irrf', v_irrf_valor, 'fgts', v_fgts.fgts_deposito,
    'base_patronal', v_base_inss, 'base_patronal_13', 0, 'encargos', true,
    'pendencias', to_jsonb(v_pend),
    'cabecalho', jsonb_build_object('categoria', v_categoria, 'competencia', p_competencia,
                                    'data_pagamento', p_data_pagamento, 'tipo_processo', p_tipo));
END;
$$;

-- Lê os parâmetros do processo (13º, férias, rescisão) e recusa chave desconhecida.
CREATE FUNCTION folha.processo_parametros(
  p_conta uuid, p_run_id uuid, p_contract_id uuid, p_permitidas text[], p_obrigatorias text[]
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
SET row_security = off
AS $$
DECLARE
  v_p jsonb;
  v_chave text;
BEGIN
  SELECT i.parametros INTO v_p
    FROM folha.payroll_process_input i
   WHERE i.account_id = p_conta AND i.run_id = p_run_id AND i.contract_id = p_contract_id;
  v_p := COALESCE(v_p, '{}'::jsonb);
  FOR v_chave IN SELECT jsonb_object_keys(v_p) LOOP
    IF NOT (v_chave = ANY (p_permitidas)) THEN
      RAISE EXCEPTION 'Parâmetro de processo desconhecido: %', v_chave;
    END IF;
  END LOOP;
  FOREACH v_chave IN ARRAY p_obrigatorias LOOP
    IF (v_p->>v_chave) IS NULL THEN
      RAISE EXCEPTION 'Parâmetro de processo obrigatório não informado: %', v_chave;
    END IF;
  END LOOP;
  RETURN v_p;
END;
$$;

-- Pendências comuns aos processos de 13º, férias e rescisão: as funções da 0023 não recebem
-- a remuneração de outros vínculos, e os pareceres não trazem a regra para esses processos.
CREATE FUNCTION folha.processo_pendencias_gerais(p_conta uuid, p_contract_id uuid, p_competencia date)
RETURNS text[]
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
SET row_security = off
AS $$
  SELECT CASE WHEN EXISTS (
           SELECT 1 FROM folha.external_remuneration x
             JOIN folha.employment_contract c ON c.account_id = x.account_id AND c.employee_id = x.employee_id
            WHERE x.account_id = p_conta AND c.contract_id = p_contract_id
              AND EXTRACT(YEAR FROM x.competencia) = EXTRACT(YEAR FROM p_competencia)
              AND x.base_previdencia > 0)
         THEN ARRAY['pendencia:outros_vinculos_informados_nao_considerados_neste_processo']
         ELSE ARRAY[]::text[] END;
$$;

-- 5.2 13º salário, 1ª e 2ª parcela, por calc_13o (0023). A data do cálculo é a data de
--     pagamento da folha. Na 2ª parcela o adiantamento compensado vem das folhas de 1ª parcela
--     do mesmo ano, salvo valor informado. A contribuição patronal acompanha o INSS do
--     segurado: incide na quitação, sobre o 13º inteiro.
CREATE FUNCTION folha.folha_13o_calcular(
  p_conta uuid,
  p_run_id uuid,
  p_contract_id uuid,
  p_tipo text,
  p_competencia date,
  p_data_pagamento date,
  p_num_dependentes integer
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
SET row_security = off
AS $$
DECLARE
  v_p jsonb;
  v_parcela integer := CASE p_tipo WHEN 'decimo_terceiro_1' THEN 1 ELSE 2 END;
  v_adiant numeric;
  v_origem_adiant text := 'nenhum';
  v_nao_localizado boolean := false;
  v_r record;
  v_ir record;
  v_itens jsonb := '[]'::jsonb;
  v_bases jsonb := '{}'::jsonb;
  v_pend text[];
BEGIN
  IF p_data_pagamento IS NULL THEN
    RAISE EXCEPTION 'Folha de 13º salário exige data de pagamento';
  END IF;
  v_p := folha.processo_parametros(p_conta, p_run_id, p_contract_id,
           ARRAY['media_variaveis', 'soma_variaveis', 'adiantamento_pago'], ARRAY[]::text[]);

  IF v_parcela = 2 THEN
    IF (v_p->>'adiantamento_pago') IS NOT NULL THEN
      v_adiant := (v_p->>'adiantamento_pago')::numeric;
      v_origem_adiant := 'informado';
    ELSE
      SELECT sum(i.valor) INTO v_adiant
        FROM folha.payroll_result_item i
        JOIN folha.payroll_result pr ON pr.result_id = i.result_id
        JOIN folha.payroll_run r ON r.run_id = pr.run_id
       WHERE i.account_id = p_conta AND pr.contract_id = p_contract_id
         AND r.tipo_processo = 'decimo_terceiro_1' AND r.status <> 'cancelled'
         AND EXTRACT(YEAR FROM r.competencia) = EXTRACT(YEAR FROM p_competencia)
         AND i.rubrica_codigo = 'DECIMO_TERCEIRO_1A';
      v_origem_adiant := 'folhas de 1ª parcela do ano';
      IF v_adiant IS NULL THEN
        -- Sem folha de 1ª parcela e sem valor informado, o motor não presume que nada foi pago.
        v_adiant := 0;
        v_origem_adiant := 'não localizado';
        v_nao_localizado := true;
      END IF;
    END IF;
  END IF;

  SELECT * INTO v_r
    FROM folha.calc_13o(p_contract_id, p_data_pagamento, v_parcela,
                        COALESCE(v_adiant, 0),
                        COALESCE((v_p->>'media_variaveis')::numeric, 0),
                        COALESCE(p_num_dependentes, 0),
                        COALESCE((v_p->>'soma_variaveis')::numeric, 0));
  v_pend := v_r.pendencias_validacao || folha.processo_pendencias_gerais(p_conta, p_contract_id, p_competencia);
  IF v_nao_localizado THEN
    v_pend := v_pend || ARRAY['pendencia:adiantamento_do_13o_nao_localizado_informar_o_valor_pago_ou_zero'];
  END IF;

  IF v_parcela = 1 THEN
    v_itens := v_itens
      || jsonb_build_object('codigo', 'DECIMO_TERCEIRO_1A', 'valor', v_r.valor_bruto, 'quantidade', v_r.meses_proporcionais,
                            'base_calculo', v_r.base_calculo, 'camada', 'motor',
                            'detalhe', jsonb_build_object('origem', 'calc_13o parcela 1', 'avos', v_r.meses_proporcionais))
      || jsonb_build_object('codigo', 'FGTS_DEPOSITO', 'valor', v_r.fgts, 'base_calculo', v_r.valor_bruto, 'camada', 'motor',
                            'detalhe', jsonb_build_object('origem', 'calc_13o parcela 1'));
    v_bases := jsonb_build_object('FGTS_13', v_r.valor_bruto);
    RETURN jsonb_build_object(
      'itens', v_itens, 'bases', v_bases, 'inss', 0, 'irrf', 0, 'fgts', v_r.fgts,
      'base_patronal', 0, 'base_patronal_13', 0, 'encargos', true,
      'pendencias', to_jsonb(v_pend),
      'cabecalho', jsonb_build_object('competencia', p_competencia, 'data_pagamento', p_data_pagamento,
                                      'tipo_processo', p_tipo));
  END IF;

  SELECT * INTO v_ir
    FROM folha.calc_irrf_separado_apurar(v_r.valor_bruto, v_r.inss, COALESCE(p_num_dependentes, 0), p_data_pagamento);
  IF v_ir.valor_irrf IS DISTINCT FROM v_r.irrf THEN
    RAISE EXCEPTION 'Folha de 13º: IRRF em separado divergente entre calc_13o (%) e a apuração com pendências (%)', v_r.irrf, v_ir.valor_irrf;
  END IF;
  v_pend := v_pend || v_ir.pendencias;

  v_itens := v_itens
    || jsonb_build_object('codigo', 'DECIMO_TERCEIRO_2A', 'valor', v_r.valor_bruto, 'quantidade', v_r.meses_proporcionais,
                          'base_calculo', v_r.base_calculo, 'camada', 'motor',
                          'detalhe', jsonb_build_object('origem', 'calc_13o parcela 2', 'avos', v_r.meses_proporcionais));
  IF v_r.adiantamento_compensado > 0 THEN
    v_itens := v_itens
      || jsonb_build_object('codigo', 'DECIMO_TERCEIRO_ADIANT_COMP', 'valor', v_r.adiantamento_compensado, 'camada', 'motor',
                            'detalhe', jsonb_build_object('origem_do_adiantamento', v_origem_adiant));
  END IF;
  v_itens := v_itens
    || jsonb_build_object('codigo', 'INSS_13_SALARIO', 'valor', v_r.inss, 'base_calculo', v_r.valor_bruto, 'camada', 'motor',
                          'detalhe', jsonb_build_object('origem', 'calc_13o parcela 2'))
    || jsonb_build_object('codigo', 'IRRF_13_SALARIO', 'valor', v_r.irrf, 'base_calculo', v_ir.base_calculo, 'camada', 'motor',
                          'detalhe', jsonb_build_object('imposto_tabela', v_ir.imposto_tabela, 'reducao', round(v_ir.reducao, 2),
                                                        'dependentes', COALESCE(p_num_dependentes, 0)))
    || jsonb_build_object('codigo', 'FGTS_DEPOSITO', 'valor', v_r.fgts,
                          'base_calculo', GREATEST(v_r.valor_bruto - v_r.adiantamento_compensado, 0), 'camada', 'motor',
                          'detalhe', jsonb_build_object('origem', 'calc_13o parcela 2'));
  v_bases := jsonb_build_object('INSS_13', v_r.valor_bruto, 'IRRF_13', v_r.valor_bruto,
                                'FGTS_13', GREATEST(v_r.valor_bruto - v_r.adiantamento_compensado, 0));
  RETURN jsonb_build_object(
    'itens', v_itens, 'bases', v_bases, 'inss', v_r.inss, 'irrf', v_r.irrf, 'fgts', v_r.fgts,
    'base_patronal', v_r.valor_bruto, 'base_patronal_13', v_r.valor_bruto, 'encargos', true,
    'liquido_esperado', v_r.valor_liquido,
    'pendencias', to_jsonb(v_pend),
    'cabecalho', jsonb_build_object('competencia', p_competencia, 'data_pagamento', p_data_pagamento,
                                    'tipo_processo', p_tipo, 'adiantamento', v_origem_adiant));
END;
$$;

-- 5.3 Férias, por calc_ferias (0023). A competência da folha é o mês de início do gozo.
CREATE FUNCTION folha.folha_ferias_calcular(
  p_conta uuid,
  p_run_id uuid,
  p_contract_id uuid,
  p_competencia date,
  p_data_pagamento date,
  p_num_dependentes integer
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
SET row_security = off
AS $$
DECLARE
  v_p jsonb;
  v_inicio date;
  v_r record;
  v_ir record;
  v_base_irrf numeric;
  v_itens jsonb := '[]'::jsonb;
  v_pend text[];
BEGIN
  v_p := folha.processo_parametros(p_conta, p_run_id, p_contract_id,
           ARRAY['inicio_gozo', 'periodo_aquisitivo_inicio', 'dias_gozo', 'dias_abono', 'faltas_injustificadas',
                 'periodo_concessivo_fim', 'remuneracao'],
           ARRAY['inicio_gozo', 'periodo_aquisitivo_inicio']);
  v_inicio := (v_p->>'inicio_gozo')::date;
  IF date_trunc('month', v_inicio::timestamp)::date <> p_competencia THEN
    RAISE EXCEPTION 'Folha de férias: o início do gozo (%) não é do mês da competência da folha (%)', v_inicio, p_competencia;
  END IF;

  SELECT * INTO v_r
    FROM folha.calc_ferias(p_contract_id, v_inicio, (v_p->>'periodo_aquisitivo_inicio')::date,
                           (v_p->>'dias_gozo')::integer,
                           COALESCE((v_p->>'dias_abono')::integer, 0),
                           COALESCE((v_p->>'faltas_injustificadas')::integer, 0),
                           (v_p->>'periodo_concessivo_fim')::date,
                           (v_p->>'remuneracao')::numeric,
                           COALESCE(p_num_dependentes, 0));
  v_pend := v_r.pendencias_validacao || folha.processo_pendencias_gerais(p_conta, p_contract_id, p_competencia);

  -- Mesma base de IRRF de calc_ferias, para devolver as pendências do IRRF em separado.
  v_base_irrf := v_r.base_inss
    + CASE WHEN folha.get_param('irrf_abono_pecuniario_incide', v_inicio) = 1 THEN v_r.valor_abono + v_r.terco_abono ELSE 0 END
    + CASE WHEN folha.get_param('irrf_dobra_ferias_incide', v_inicio) = 1 THEN v_r.valor_dobra ELSE 0 END;
  SELECT * INTO v_ir
    FROM folha.calc_irrf_separado_apurar(v_base_irrf, v_r.inss, COALESCE(p_num_dependentes, 0), v_inicio);
  IF v_ir.valor_irrf IS DISTINCT FROM v_r.irrf THEN
    RAISE EXCEPTION 'Folha de férias: IRRF em separado divergente entre calc_ferias (%) e a apuração com pendências (%)', v_r.irrf, v_ir.valor_irrf;
  END IF;
  v_pend := v_pend || v_ir.pendencias;
  IF p_data_pagamento IS NULL
     OR date_trunc('month', p_data_pagamento::timestamp) <> date_trunc('month', v_inicio::timestamp) THEN
    v_pend := v_pend || ARRAY['a_validar:irrf_ferias_apurado_pela_data_de_inicio_do_gozo_e_nao_pela_de_pagamento'];
  END IF;

  v_itens := v_itens
    || jsonb_build_object('codigo', 'FERIAS_GOZO', 'valor', v_r.valor_ferias, 'quantidade', v_r.dias_gozo,
                          'base_calculo', v_r.base_calculo, 'camada', 'motor',
                          'detalhe', jsonb_build_object('origem', 'calc_ferias', 'dias_direito', v_r.dias_direito,
                                                        'data_limite_pagamento', v_r.data_limite_pagamento))
    || jsonb_build_object('codigo', 'FERIAS_TERCO', 'valor', v_r.valor_um_terco, 'base_calculo', v_r.valor_ferias,
                          'camada', 'motor', 'detalhe', jsonb_build_object('origem', 'calc_ferias'));
  IF v_r.valor_abono > 0 THEN
    v_itens := v_itens
      || jsonb_build_object('codigo', 'ABONO_PECUNIARIO', 'valor', v_r.valor_abono, 'quantidade', v_r.dias_abono,
                            'base_calculo', v_r.base_calculo, 'camada', 'motor', 'detalhe', jsonb_build_object('origem', 'calc_ferias'))
      || jsonb_build_object('codigo', 'ABONO_PECUNIARIO_TERCO', 'valor', v_r.terco_abono, 'base_calculo', v_r.valor_abono,
                            'camada', 'motor', 'detalhe', jsonb_build_object('origem', 'calc_ferias'));
  END IF;
  IF v_r.valor_dobra > 0 THEN
    v_itens := v_itens
      || jsonb_build_object('codigo', 'FERIAS_DOBRA', 'valor', v_r.valor_dobra, 'quantidade', v_r.dias_dobra,
                            'base_calculo', v_r.base_calculo, 'camada', 'motor', 'detalhe', jsonb_build_object('origem', 'calc_ferias'));
  END IF;
  v_itens := v_itens
    || jsonb_build_object('codigo', 'INSS_EMPREGADO', 'valor', v_r.inss, 'base_calculo', v_r.base_inss, 'camada', 'motor',
                          'detalhe', jsonb_build_object('origem', 'calc_ferias (provisório: a folha do mês de gozo reapura)'))
    || jsonb_build_object('codigo', 'IRRF_FERIAS', 'valor', v_r.irrf, 'base_calculo', v_ir.base_calculo, 'camada', 'motor',
                          'detalhe', jsonb_build_object('imposto_tabela', v_ir.imposto_tabela, 'reducao', round(v_ir.reducao, 2),
                                                        'rendimento', v_base_irrf, 'dependentes', COALESCE(p_num_dependentes, 0)))
    || jsonb_build_object('codigo', 'FGTS_DEPOSITO', 'valor', v_r.fgts, 'base_calculo', v_r.base_inss, 'camada', 'motor',
                          'detalhe', jsonb_build_object('origem', 'calc_ferias'));

  RETURN jsonb_build_object(
    'itens', v_itens,
    'bases', jsonb_build_object('INSS_MENSAL', v_r.base_inss, 'FGTS_MENSAL', v_r.base_inss, 'IRRF_FERIAS', v_base_irrf),
    'inss', v_r.inss, 'irrf', v_r.irrf, 'fgts', v_r.fgts,
    'base_patronal', v_r.base_inss, 'base_patronal_13', 0, 'encargos', true,
    'liquido_esperado', v_r.valor_liquido,
    'pendencias', to_jsonb(v_pend),
    'cabecalho', jsonb_build_object('competencia', p_competencia, 'data_pagamento', p_data_pagamento,
                                    'tipo_processo', 'ferias', 'inicio_gozo', v_inicio));
END;
$$;

-- 5.4 Rescisão, por calc_rescisao (0023). A competência da folha é o mês do último dia
--     trabalhado. Férias vencidas e proporcionais saem com o terço na mesma rubrica (como a
--     descrição das rubricas da 0017).
CREATE FUNCTION folha.folha_rescisao_calcular(
  p_conta uuid,
  p_run_id uuid,
  p_contract_id uuid,
  p_competencia date,
  p_data_pagamento date,
  p_num_dependentes integer
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
SET row_security = off
AS $$
DECLARE
  v_p jsonb;
  v_ult date;
  v_r record;
  v_ir_mes record;
  v_ir_13 record;
  v_rem numeric;
  v_base_inss_mes numeric;
  v_base_inss_13 numeric;
  v_itens jsonb := '[]'::jsonb;
  v_pend text[];
  v_x record;
BEGIN
  v_p := folha.processo_parametros(p_conta, p_run_id, p_contract_id,
           ARRAY['data_demissao', 'motivo', 'aviso_modo', 'data_comunicacao', 'periodo_aquisitivo_inicio',
                 'periodos_vencidos', 'periodos_vencidos_dobro', 'fgts_base_extrato', 'data_termo',
                 'prejuizo_art480', 'projecao_dias_acordo', 'adiantamento_13o_pago', 'remuneracao', 'dias_saldo'],
           ARRAY['data_demissao', 'motivo']);
  v_ult := (v_p->>'data_demissao')::date;
  IF date_trunc('month', v_ult::timestamp)::date <> p_competencia THEN
    RAISE EXCEPTION 'Folha de rescisão: o último dia trabalhado (%) não é do mês da competência da folha (%)', v_ult, p_competencia;
  END IF;
  IF EXISTS (SELECT 1 FROM folha.payroll_result pr
               JOIN folha.payroll_run r ON r.run_id = pr.run_id
              WHERE pr.account_id = p_conta AND pr.contract_id = p_contract_id
                AND r.competencia = p_competencia AND r.tipo_processo = 'mensal' AND r.status <> 'cancelled') THEN
    RAISE EXCEPTION 'Contrato % já tem folha mensal calculada na competência %: o saldo de salário sairia duas vezes', p_contract_id, p_competencia;
  END IF;

  SELECT * INTO v_r
    FROM folha.calc_rescisao(
      p_contract_id, v_ult, v_p->>'motivo',
      COALESCE(v_p->>'aviso_modo', 'nao_aplicavel'),
      (v_p->>'data_comunicacao')::date,
      (v_p->>'periodo_aquisitivo_inicio')::date,
      COALESCE((v_p->>'periodos_vencidos')::integer, 0),
      COALESCE((v_p->>'periodos_vencidos_dobro')::integer, 0),
      (v_p->>'fgts_base_extrato')::numeric,
      (v_p->>'data_termo')::date,
      (v_p->>'prejuizo_art480')::numeric,
      (v_p->>'projecao_dias_acordo')::integer,
      COALESCE(p_num_dependentes, 0),
      COALESCE((v_p->>'adiantamento_13o_pago')::numeric, 0),
      (v_p->>'remuneracao')::numeric,
      (v_p->>'dias_saldo')::integer);
  v_pend := v_r.pendencias_validacao || folha.processo_pendencias_gerais(p_conta, p_contract_id, p_competencia);
  IF EXISTS (SELECT 1 FROM folha.payroll_result pr
               JOIN folha.payroll_run r ON r.run_id = pr.run_id
              WHERE pr.account_id = p_conta AND pr.contract_id = p_contract_id
                AND r.competencia = p_competencia AND r.tipo_processo = 'adiantamento' AND r.status <> 'cancelled') THEN
    v_pend := v_pend || ARRAY['pendencia:adiantamento_salarial_pago_na_competencia_nao_descontado_na_rescisao'];
  END IF;
  -- calc_rescisao apura o IRRF pela data do último dia; o parecer de rescisão manda usar a
  -- tabela do mês do pagamento.
  IF p_data_pagamento IS NULL
     OR date_trunc('month', p_data_pagamento::timestamp) <> date_trunc('month', v_ult::timestamp) THEN
    v_pend := v_pend || ARRAY['a_validar:irrf_rescisao_apurado_pela_data_do_desligamento_e_nao_pela_de_pagamento'];
  END IF;

  -- Bases de INSS, como calc_rescisao as forma (aviso indenizado e avos da projeção conforme
  -- os parâmetros a_validar da 0023).
  SELECT COALESCE((v_p->>'remuneracao')::numeric, c.salario_base) INTO v_rem
    FROM folha.employment_contract c WHERE c.contract_id = p_contract_id AND c.account_id = p_conta;
  v_base_inss_mes := v_r.saldo_salario
    + CASE WHEN folha.get_param('inss_aviso_indenizado_incide', v_ult) = 1 THEN v_r.aviso_previo_indenizado ELSE 0 END;
  v_base_inss_13 := CASE
    WHEN v_r.avos_13_projecao = 0 OR folha.get_param('inss_projecao_aviso_incide', v_ult) = 1
      THEN v_r.decimo_terceiro_proporcional
    ELSE round(v_rem * (v_r.avos_13 - v_r.avos_13_projecao) / 12.0, 2) END;
  IF (SELECT i.valor_inss FROM folha.calc_inss(v_base_inss_mes, v_ult) i) IS DISTINCT FROM v_r.inss_mensal
     OR (SELECT i.valor_inss FROM folha.calc_inss(v_base_inss_13, v_ult) i) IS DISTINCT FROM v_r.inss_13 THEN
    RAISE EXCEPTION 'Folha de rescisão: bases de INSS reconstituídas (% e %) não reproduzem o INSS de calc_rescisao (% e %)',
      v_base_inss_mes, v_base_inss_13, v_r.inss_mensal, v_r.inss_13;
  END IF;

  SELECT * INTO v_ir_mes
    FROM folha.calc_irrf_separado_apurar(v_r.saldo_salario, v_r.inss_mensal, COALESCE(p_num_dependentes, 0), v_ult);
  SELECT * INTO v_ir_13
    FROM folha.calc_irrf_separado_apurar(v_r.decimo_terceiro_proporcional, v_r.inss_13, COALESCE(p_num_dependentes, 0), v_ult);
  IF v_ir_mes.valor_irrf IS DISTINCT FROM v_r.irrf_mensal OR v_ir_13.valor_irrf IS DISTINCT FROM v_r.irrf_13 THEN
    RAISE EXCEPTION 'Folha de rescisão: IRRF em separado divergente entre calc_rescisao e a apuração com pendências';
  END IF;
  v_pend := v_pend || v_ir_mes.pendencias || v_ir_13.pendencias;

  FOR v_x IN
    SELECT * FROM (VALUES
      (1,  'RESC_SALDO_SALARIO',         v_r.saldo_salario,                                        v_r.dias_saldo::numeric, true),
      (2,  'AVISO_PREVIO_INDENIZADO',    v_r.aviso_previo_indenizado,                              v_r.dias_aviso::numeric, false),
      (3,  'RESC_DECIMO_TERCEIRO_PROP',  v_r.decimo_terceiro_proporcional,                         v_r.avos_13::numeric,    false),
      (4,  'RESC_FERIAS_VENCIDAS',       v_r.ferias_vencidas + v_r.terco_ferias_vencidas,          NULL::numeric,           false),
      (5,  'RESC_FERIAS_PROP',           v_r.ferias_proporcionais + v_r.terco_ferias_proporcionais, v_r.avos_ferias_proporcionais::numeric, false),
      (6,  'RESC_INDENIZACAO_ART479',    v_r.indenizacao_479,                                      NULL::numeric,           false),
      (7,  'INSS_EMPREGADO',             v_r.inss_mensal,                                          NULL::numeric,           true),
      (8,  'INSS_13_SALARIO',            v_r.inss_13,                                              NULL::numeric,           false),
      (9,  'IRRF',                       v_r.irrf_mensal,                                          NULL::numeric,           true),
      (10, 'IRRF_13_SALARIO',            v_r.irrf_13,                                              NULL::numeric,           false),
      (11, 'RESC_DESCONTO_AVISO_PREVIO', v_r.desconto_aviso,                                       NULL::numeric,           false),
      (12, 'RESC_DESCONTO_ART480',       v_r.desconto_art480,                                      NULL::numeric,           false),
      (13, 'DECIMO_TERCEIRO_ADIANT_COMP', v_r.desconto_adiantamento_13,                            NULL::numeric,           false),
      (14, 'FGTS_DEPOSITO',              v_r.fgts_deposito_rescisao,                               NULL::numeric,           true),
      (15, 'FGTS_MULTA_RESCISORIA',      v_r.multa_fgts,                                           NULL::numeric,           false)
    ) AS t(ordem, codigo, valor, quantidade, sempre)
    ORDER BY t.ordem
  LOOP
    IF v_x.valor IS NULL OR (v_x.valor = 0 AND NOT v_x.sempre) THEN
      CONTINUE;
    END IF;
    v_itens := v_itens || jsonb_build_object(
      'codigo', v_x.codigo, 'valor', v_x.valor, 'quantidade', v_x.quantidade, 'camada', 'motor',
      'base_calculo', CASE v_x.codigo WHEN 'INSS_EMPREGADO' THEN v_base_inss_mes
                                      WHEN 'INSS_13_SALARIO' THEN v_base_inss_13
                                      WHEN 'IRRF' THEN v_ir_mes.base_calculo
                                      WHEN 'IRRF_13_SALARIO' THEN v_ir_13.base_calculo END,
      'detalhe', jsonb_build_object('origem', 'calc_rescisao', 'motivo', v_p->>'motivo'));
  END LOOP;

  RETURN jsonb_build_object(
    'itens', v_itens,
    -- FGTS como calc_rescisao o apura: saldo + aviso indenizado no mês; 13º menos o adiantamento
    -- que já foi base.
    'bases', jsonb_build_object('INSS_MENSAL', v_base_inss_mes, 'INSS_13', v_base_inss_13,
                                'IRRF_MENSAL', v_r.saldo_salario, 'IRRF_13', v_r.decimo_terceiro_proporcional,
                                'FGTS_MENSAL', v_r.saldo_salario + v_r.aviso_previo_indenizado,
                                'FGTS_13', GREATEST(v_r.decimo_terceiro_proporcional
                                             - LEAST(COALESCE((v_p->>'adiantamento_13o_pago')::numeric, 0),
                                                     v_r.decimo_terceiro_proporcional), 0)),
    'inss', v_r.inss_mensal + v_r.inss_13, 'irrf', v_r.irrf_mensal + v_r.irrf_13, 'fgts', v_r.fgts_deposito_rescisao,
    'base_patronal', v_base_inss_mes + v_base_inss_13, 'base_patronal_13', v_base_inss_13, 'encargos', true,
    'liquido_esperado', v_r.liquido_rescisao,
    'pendencias', to_jsonb(v_pend),
    'cabecalho', jsonb_build_object('competencia', p_competencia, 'data_pagamento', p_data_pagamento,
                                    'tipo_processo', 'rescisao', 'ultimo_dia', v_ult, 'motivo', v_p->>'motivo',
                                    'data_limite_pagamento', v_r.data_limite_pagamento, 'estado', v_r.estado));
END;
$$;

-- ===========================================================================
-- 6. Gravação do resultado: encargos por lotação, totais, itens, bases, memória de cálculo
--    com a camada da regra e pendências como dado.
-- ===========================================================================
CREATE FUNCTION folha.folha_gravar_resultado(
  p_conta uuid,
  p_run_id uuid,
  p_contract_id uuid,
  p_competencia date,
  p_calc jsonb
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, folha
SET row_security = off
AS $$
DECLARE
  v_employee uuid;
  v_encs jsonb := '[]'::jsonb;
  v_patronal numeric := 0;
  v_rat numeric := 0;
  v_terceiros numeric := 0;
  v_prov numeric := 0;
  v_desc numeric := 0;
  v_liq numeric;
  v_pend text[];
  v_i record;
  v_rub record;
  v_enc record;
  v_b record;
  v_result_id uuid;
  v_passo integer := 1001;
BEGIN
  SELECT c.employee_id INTO v_employee
    FROM folha.employment_contract c WHERE c.contract_id = p_contract_id AND c.account_id = p_conta;

  -- Encargos patronais ANTES de gravar: falta de cadastro levanta exceção e nada é gravado.
  IF (p_calc->>'encargos')::boolean THEN
    IF (p_calc->>'base_patronal')::numeric < 0 THEN
      RAISE EXCEPTION 'Contrato %: base dos encargos patronais negativa', p_contract_id;
    END IF;
    SELECT COALESCE(jsonb_agg(to_jsonb(e)), '[]'::jsonb) INTO v_encs
      FROM folha.calc_encargos_patronais(p_contract_id, p_competencia,
             (p_calc->>'base_patronal')::numeric, (p_calc->>'base_patronal_13')::numeric) e;
    IF jsonb_array_length(v_encs) = 0 THEN
      RAISE EXCEPTION 'run_payroll_employee: encargos patronais do contrato % não foram apurados', p_contract_id;
    END IF;
    SELECT sum((x->>'inss_patronal')::numeric), sum((x->>'rat')::numeric), sum((x->>'terceiros')::numeric)
      INTO v_patronal, v_rat, v_terceiros
      FROM jsonb_array_elements(v_encs) x;
    IF v_patronal IS NULL OR v_rat IS NULL OR v_terceiros IS NULL THEN
      RAISE EXCEPTION 'run_payroll_employee: encargos patronais do contrato % vieram nulos', p_contract_id;
    END IF;
  END IF;

  SELECT COALESCE(sum((i->>'valor')::numeric) FILTER (WHERE e.tipo_rubrica = 'provento'), 0),
         COALESCE(sum((i->>'valor')::numeric) FILTER (WHERE e.tipo_rubrica = 'desconto'), 0)
    INTO v_prov, v_desc
    FROM jsonb_array_elements(p_calc->'itens') i
    JOIN folha.earning_deduction_code e ON e.code_id = folha.rubrica_por_codigo(p_conta, i->>'codigo');
  v_liq := v_prov - v_desc;
  IF p_calc ? 'liquido_esperado' AND (p_calc->>'liquido_esperado')::numeric IS DISTINCT FROM v_liq THEN
    RAISE EXCEPTION 'Contrato %: a soma dos itens por rubrica (%) não reproduz o líquido da função de origem (%)',
      p_contract_id, v_liq, p_calc->>'liquido_esperado';
  END IF;

  v_pend := ARRAY(SELECT jsonb_array_elements_text(p_calc->'pendencias'))
         || ARRAY(SELECT jsonb_array_elements_text(x->'pendencias') FROM jsonb_array_elements(v_encs) x);
  IF v_liq < 0 THEN
    v_pend := v_pend || ARRAY['pendencia:liquido_negativo_exige_decisao'];
  END IF;
  v_pend := ARRAY(SELECT DISTINCT p FROM unnest(v_pend) AS p ORDER BY p);

  INSERT INTO folha.payroll_result (
    run_id, account_id, employee_id, contract_id,
    total_proventos, total_descontos, liquido,
    inss_empregado, irrf, fgts, inss_patronal, rat, terceiros, calculation_hash
  ) VALUES (
    p_run_id, p_conta, v_employee, p_contract_id,
    v_prov, v_desc, v_liq,
    (p_calc->>'inss')::numeric, (p_calc->>'irrf')::numeric, (p_calc->>'fgts')::numeric,
    v_patronal, v_rat, v_terceiros,
    md5(p_conta::text || p_run_id::text || p_contract_id::text || (p_calc - 'pendencias')::text || v_encs::text)
  ) RETURNING result_id INTO v_result_id;

  FOR v_i IN SELECT t.item, t.n FROM jsonb_array_elements(p_calc->'itens') WITH ORDINALITY AS t(item, n) ORDER BY t.n
  LOOP
    SELECT e.code_id, e.codigo, e.descricao, e.tipo_rubrica INTO v_rub
      FROM folha.earning_deduction_code e
     WHERE e.code_id = folha.rubrica_por_codigo(p_conta, v_i.item->>'codigo');
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Rubrica % não existe no catálogo', v_i.item->>'codigo';
    END IF;

    INSERT INTO folha.payroll_result_item (
      account_id, result_id, code_id, rubrica_codigo, tipo_rubrica, ordem, quantidade, base_calculo,
      aliquota, valor, camada_regra, rule_id, entry_id, detalhe)
    VALUES (
      p_conta, v_result_id, v_rub.code_id, v_rub.codigo, v_rub.tipo_rubrica, v_i.n::integer,
      (v_i.item->>'quantidade')::numeric, (v_i.item->>'base_calculo')::numeric,
      (v_i.item->>'aliquota')::numeric, (v_i.item->>'valor')::numeric,
      v_i.item->>'camada', (v_i.item->>'rule_id')::uuid, (v_i.item->>'entry_id')::uuid, v_i.item->'detalhe');

    INSERT INTO folha.calculation_trace (
      result_id, account_id, step_order, rubrica_code, descricao, base_calculo, aliquota, valor, tipo,
      detail_json, camada_regra, rule_id)
    VALUES (
      v_result_id, p_conta, v_i.n::integer, v_rub.codigo, v_rub.descricao,
      (v_i.item->>'base_calculo')::numeric, round((v_i.item->>'aliquota')::numeric, 4), (v_i.item->>'valor')::numeric,
      CASE v_rub.tipo_rubrica WHEN 'provento' THEN 'provento' WHEN 'desconto' THEN 'desconto' ELSE 'informativo' END,
      COALESCE(v_i.item->'detalhe', '{}'::jsonb)
        || jsonb_build_object('camada_regra', v_i.item->>'camada')
        || CASE WHEN v_i.n = 1
                THEN COALESCE(p_calc->'cabecalho', '{}'::jsonb) || jsonb_build_object('pendencias', to_jsonb(v_pend))
                ELSE '{}'::jsonb END,
      v_i.item->>'camada', (v_i.item->>'rule_id')::uuid);
  END LOOP;

  FOR v_b IN
    SELECT k.key AS codigo, k.value::numeric AS valor
      FROM jsonb_each_text(p_calc->'bases') k
     WHERE k.value::numeric <> 0
  LOOP
    INSERT INTO folha.payroll_result_base (account_id, result_id, base_id, base_codigo, valor)
    SELECT p_conta, v_result_id, b.base_id, b.codigo, v_b.valor
      FROM folha.calculation_base b
     WHERE b.codigo = v_b.codigo AND (b.account_id IS NULL OR b.account_id = p_conta)
     ORDER BY (b.account_id IS NULL) DESC
     LIMIT 1;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Base % não existe no catálogo', v_b.codigo;
    END IF;
  END LOOP;

  FOR v_enc IN SELECT x FROM jsonb_array_elements(v_encs) x
  LOOP
    INSERT INTO folha.calculation_trace (result_id, account_id, step_order, rubrica_code, descricao, base_calculo, aliquota, valor, tipo, detail_json, camada_regra)
    VALUES
      (v_result_id, p_conta, v_passo, 'INSS_PATRONAL', 'Contribuição patronal por lotação', (v_enc.x->>'base_rateada')::numeric, (v_enc.x->>'aliq_patronal')::numeric, (v_enc.x->>'inss_patronal')::numeric, 'encargo',
       v_enc.x - 'pendencias', 'motor'),
      (v_result_id, p_conta, v_passo + 1, 'RAT_SAT', 'RAT x FAP por lotação', (v_enc.x->>'base_rateada')::numeric, (v_enc.x->>'aliq_rat')::numeric, (v_enc.x->>'rat')::numeric, 'encargo',
       v_enc.x - 'pendencias', 'motor'),
      (v_result_id, p_conta, v_passo + 2, 'TERCEIROS', 'Terceiros por lotação', (v_enc.x->>'base_rateada')::numeric, (v_enc.x->>'aliq_terceiros')::numeric, (v_enc.x->>'terceiros')::numeric, 'encargo',
       v_enc.x - 'pendencias', 'motor');
    v_passo := v_passo + 3;
  END LOOP;

  INSERT INTO folha.payroll_pendency (account_id, run_id, result_id, contract_id, codigo, tipo)
  SELECT p_conta, p_run_id, v_result_id, p_contract_id, p,
         CASE WHEN p LIKE 'a_validar:%' THEN 'a_validar' ELSE 'pendencia' END
    FROM unnest(v_pend) AS p;

  RETURN v_result_id;
END;
$$;

-- ===========================================================================
-- 7. run_payroll_employee: mesma assinatura da 0025; despacha pelo tipo de processo da folha.
-- ===========================================================================
CREATE OR REPLACE FUNCTION folha.run_payroll_employee(
  p_run_id uuid,
  p_contract_id uuid,
  p_num_dependentes_irrf integer DEFAULT 0,
  p_num_filhos_salario_familia integer DEFAULT 0
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_conta uuid := folha.current_account_id();
  v_categoria text;
  v_contract_employer uuid;
  v_competencia date;
  v_data_pagamento date;
  v_status text;
  v_tipo text;
  v_run_employer uuid;
  v_calc jsonb;
  v_pend_data text[] := ARRAY[]::text[];
BEGIN
  IF v_conta IS NULL THEN
    RAISE EXCEPTION 'run_payroll_employee: sessão sem conta (contexto não aberto)';
  END IF;
  IF COALESCE(p_num_dependentes_irrf, 0) < 0 OR COALESCE(p_num_filhos_salario_familia, 0) < 0 THEN
    RAISE EXCEPTION 'run_payroll_employee: dependentes e filhos não podem ser negativos';
  END IF;

  SELECT c.regime_trabalho, c.employer_id
    INTO v_categoria, v_contract_employer
    FROM folha.employment_contract c
   WHERE c.contract_id = p_contract_id AND c.account_id = v_conta;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Contrato % não encontrado', p_contract_id;
  END IF;

  -- Os processos do mesmo contrato se leem uns aos outros (adiantamento, mensal, complementar,
  -- 13º, rescisão): cálculos simultâneos do mesmo contrato ficam em fila, em qualquer folha.
  PERFORM pg_advisory_xact_lock(hashtextextended('folha.contrato:' || p_contract_id::text, 0));

  -- Trava a folha: chamadas simultâneas para a mesma folha ficam em fila.
  SELECT r.competencia, r.data_pagamento, r.status, r.employer_id, r.tipo_processo
    INTO v_competencia, v_data_pagamento, v_status, v_run_employer, v_tipo
    FROM folha.payroll_run r
   WHERE r.run_id = p_run_id AND r.account_id = v_conta
     FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Folha % não encontrada', p_run_id;
  END IF;
  IF v_status NOT IN ('draft', 'calculating') THEN
    RAISE EXCEPTION 'Folha % está em % e não recebe cálculo', p_run_id, v_status;
  END IF;
  IF v_run_employer IS NOT NULL AND v_run_employer IS DISTINCT FROM v_contract_employer THEN
    RAISE EXCEPTION 'Contrato % não é do empregador da folha %', p_contract_id, p_run_id;
  END IF;

  IF v_categoria = 'pj' THEN
    RAISE EXCEPTION 'run_payroll_employee: categoria pj não é processada na folha';
  END IF;
  IF EXISTS (SELECT 1 FROM folha.payroll_result pr
              WHERE pr.account_id = v_conta AND pr.run_id = p_run_id AND pr.contract_id = p_contract_id) THEN
    RAISE EXCEPTION 'Contrato % já tem resultado na folha %', p_contract_id, p_run_id;
  END IF;

  IF v_tipo <> 'mensal' AND COALESCE(p_num_filhos_salario_familia, 0) > 0 THEN
    RAISE EXCEPTION 'Salário-família só é calculado na folha mensal';
  END IF;

  IF v_tipo IN ('mensal', 'adiantamento', 'complementar') THEN
    IF v_data_pagamento IS NULL THEN
      -- O cálculo segue com o último dia da competência; sem a data, a folha não fecha.
      v_data_pagamento := (date_trunc('month', v_competencia::timestamp) + interval '1 month' - interval '1 day')::date;
      v_pend_data := ARRAY['pendencia:data_pagamento_nao_informada_usado_ultimo_dia_da_competencia'];
    END IF;
    v_calc := folha.folha_rubricas_calcular(v_conta, p_run_id, p_contract_id, v_tipo, v_competencia, v_data_pagamento,
                                            p_num_dependentes_irrf, p_num_filhos_salario_familia);
  ELSIF v_tipo IN ('decimo_terceiro_1', 'decimo_terceiro_2') THEN
    v_calc := folha.folha_13o_calcular(v_conta, p_run_id, p_contract_id, v_tipo, v_competencia, v_data_pagamento,
                                       p_num_dependentes_irrf);
  ELSIF v_tipo = 'ferias' THEN
    v_calc := folha.folha_ferias_calcular(v_conta, p_run_id, p_contract_id, v_competencia, v_data_pagamento,
                                          p_num_dependentes_irrf);
  ELSIF v_tipo = 'rescisao' THEN
    v_calc := folha.folha_rescisao_calcular(v_conta, p_run_id, p_contract_id, v_competencia, v_data_pagamento,
                                            p_num_dependentes_irrf);
  ELSE
    RAISE EXCEPTION 'Tipo de processo desconhecido: %', v_tipo;
  END IF;

  v_calc := jsonb_set(v_calc, '{pendencias}', (v_calc->'pendencias') || to_jsonb(v_pend_data));
  RETURN folha.folha_gravar_resultado(v_conta, p_run_id, p_contract_id, v_competencia, v_calc);
END;
$$;

-- ===========================================================================
-- 8. Estado e trava de fechamento
-- ===========================================================================

-- 8.1 Trava no dado: vale também para UPDATE direto do worker em payroll_run.
CREATE FUNCTION folha.payroll_run_trava() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, folha
SET row_security = off
AS $$
DECLARE
  v_abertas integer;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF OLD.status IN ('closed', 'cancelled') THEN
      RAISE EXCEPTION 'Folha % está % e não pode ser alterada', OLD.run_id,
        CASE OLD.status WHEN 'closed' THEN 'fechada' ELSE 'cancelada' END;
    END IF;
    -- Só anda para a frente: draft <-> calculating -> calculated -> approved -> closed;
    -- cancelar vale de qualquer estado aberto.
    IF NEW.status IS DISTINCT FROM OLD.status AND NEW.status <> 'cancelled'
       AND NOT (   (OLD.status = 'draft'       AND NEW.status IN ('calculating', 'calculated'))
                OR (OLD.status = 'calculating' AND NEW.status IN ('draft', 'calculated'))
                OR (OLD.status = 'calculated'  AND NEW.status = 'approved')
                OR (OLD.status = 'approved'    AND NEW.status = 'closed')) THEN
      RAISE EXCEPTION 'Folha %: não passa de % para %', OLD.run_id, OLD.status, NEW.status;
    END IF;
    -- Com o cálculo concluído, a identidade e os totais da folha não mudam mais.
    IF OLD.status IN ('calculated', 'approved')
       AND ROW(NEW.account_id, NEW.competencia, NEW.tipo_processo, NEW.sequencia, NEW.employer_id, NEW.establishment_id,
               NEW.total_proventos, NEW.total_descontos, NEW.total_liquido, NEW.total_encargos_patronais)
           IS DISTINCT FROM
           ROW(OLD.account_id, OLD.competencia, OLD.tipo_processo, OLD.sequencia, OLD.employer_id, OLD.establishment_id,
               OLD.total_proventos, OLD.total_descontos, OLD.total_liquido, OLD.total_encargos_patronais) THEN
      RAISE EXCEPTION 'Folha % está em %: competência, tipo de processo, empregador e totais não podem ser alterados', OLD.run_id, OLD.status;
    END IF;
  END IF;

  -- Regra de caixa do IRRF: o pagamento não antecede a competência. Férias são pagas antes
  -- do gozo (parâmetro ferias_antecedencia_pagamento_dias) e ficam fora desta regra.
  -- Conferida quando a folha nasce e quando data, competência ou tipo mudam (folha anterior à
  -- 0027 que já esteja nessa situação continua podendo ser cancelada ou corrigida).
  IF NEW.data_pagamento IS NOT NULL AND NEW.tipo_processo <> 'ferias'
     AND (TG_OP = 'INSERT'
          OR ROW(NEW.data_pagamento, NEW.competencia, NEW.tipo_processo)
             IS DISTINCT FROM ROW(OLD.data_pagamento, OLD.competencia, OLD.tipo_processo))
     AND NEW.data_pagamento < NEW.competencia THEN
    RAISE EXCEPTION 'Folha %: data de pagamento % anterior ao início da competência %', NEW.run_id, NEW.data_pagamento, NEW.competencia;
  END IF;

  IF NEW.status IN ('approved', 'closed')
     AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM NEW.status) THEN
    SELECT count(*) INTO v_abertas
      FROM folha.payroll_pendency p
     WHERE p.account_id = NEW.account_id AND p.run_id = NEW.run_id AND p.liberada_em IS NULL;
    IF v_abertas > 0 THEN
      RAISE EXCEPTION 'Folha % tem % pendência(s) sem liberação registrada e não pode passar a %', NEW.run_id, v_abertas, NEW.status;
    END IF;
    IF NEW.status = 'closed' AND NEW.data_pagamento IS NULL THEN
      RAISE EXCEPTION 'Folha % não pode ser fechada sem data de pagamento', NEW.run_id;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_payroll_run_trava
  BEFORE INSERT OR UPDATE ON folha.payroll_run
  FOR EACH ROW EXECUTE FUNCTION folha.payroll_run_trava();

-- 8.1.1 Resultado só nasce em folha aberta para cálculo, e só pelo motor. O worker tinha
--       INSERT em payroll_result e em calculation_trace desde a 0014: com isso forjaria um
--       resultado sem pendência. A gravação é feita por função SECURITY DEFINER; o INSERT
--       direto é revogado.
CREATE FUNCTION folha.payroll_result_so_em_folha_aberta() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, folha
SET row_security = off
AS $$
DECLARE
  v_status text;
BEGIN
  SELECT r.status INTO v_status FROM folha.payroll_run r
   WHERE r.run_id = NEW.run_id AND r.account_id = NEW.account_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Resultado aponta folha inexistente ou de outra conta' USING ERRCODE = 'foreign_key_violation';
  END IF;
  IF v_status NOT IN ('draft', 'calculating') THEN
    RAISE EXCEPTION 'Folha % está em % e não recebe resultado', NEW.run_id, v_status;
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_payroll_result_so_em_folha_aberta
  BEFORE INSERT ON folha.payroll_result
  FOR EACH ROW EXECUTE FUNCTION folha.payroll_result_so_em_folha_aberta();
REVOKE INSERT ON folha.payroll_result, folha.calculation_trace FROM dnex_gestao_folha_worker;

-- 8.2 Conclusão do cálculo: totaliza e leva a folha a 'calculated'.
CREATE FUNCTION folha.payroll_run_concluir_calculo(p_run_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_conta uuid := folha.current_account_id();
  v_status text;
  v_n integer;
BEGIN
  IF v_conta IS NULL THEN
    RAISE EXCEPTION 'payroll_run_concluir_calculo: sessão sem conta (contexto não aberto)';
  END IF;
  SELECT r.status INTO v_status FROM folha.payroll_run r
   WHERE r.run_id = p_run_id AND r.account_id = v_conta FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Folha % não encontrada', p_run_id;
  END IF;
  IF v_status NOT IN ('draft', 'calculating') THEN
    RAISE EXCEPTION 'Folha % está em % e não pode ter o cálculo concluído', p_run_id, v_status;
  END IF;
  SELECT count(*) INTO v_n FROM folha.payroll_result pr WHERE pr.account_id = v_conta AND pr.run_id = p_run_id;
  IF v_n = 0 THEN
    RAISE EXCEPTION 'Folha % não tem resultado calculado', p_run_id;
  END IF;
  UPDATE folha.payroll_run r
     SET status = 'calculated', calculado_em = now(), updated_at = now(),
         total_proventos = t.prov, total_descontos = t.descontos, total_liquido = t.liq,
         total_encargos_patronais = t.enc
    FROM (SELECT sum(pr.total_proventos) AS prov, sum(pr.total_descontos) AS descontos, sum(pr.liquido) AS liq,
                 sum(pr.inss_patronal + pr.rat + pr.terceiros) AS enc
            FROM folha.payroll_result pr WHERE pr.account_id = v_conta AND pr.run_id = p_run_id) t
   WHERE r.run_id = p_run_id AND r.account_id = v_conta;
END;
$$;

-- 8.3 Liberação explícita de pendência: por folha e código, com responsável e motivo. Fica na
--     própria pendência (quem, quando, motivo, sessão) e na auditoria.
CREATE FUNCTION folha.payroll_pendencias_liberar(
  p_run_id uuid,
  p_codigo text,
  p_responsavel text,
  p_motivo text
) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_conta uuid := folha.current_account_id();
  v_status text;
  v_n integer;
BEGIN
  IF v_conta IS NULL THEN
    RAISE EXCEPTION 'payroll_pendencias_liberar: sessão sem conta (contexto não aberto)';
  END IF;
  IF btrim(COALESCE(p_responsavel, '')) = '' OR btrim(COALESCE(p_motivo, '')) = '' THEN
    RAISE EXCEPTION 'payroll_pendencias_liberar: responsável e motivo são obrigatórios';
  END IF;
  SELECT r.status INTO v_status FROM folha.payroll_run r
   WHERE r.run_id = p_run_id AND r.account_id = v_conta FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Folha % não encontrada', p_run_id;
  END IF;
  IF v_status <> 'calculated' THEN
    RAISE EXCEPTION 'Folha % está em %: pendência só é liberada com o cálculo concluído', p_run_id, v_status;
  END IF;
  UPDATE folha.payroll_pendency p
     SET liberada_em = now(), liberada_por = btrim(p_responsavel),
         liberada_sessao = session_user, liberacao_motivo = btrim(p_motivo)
   WHERE p.account_id = v_conta AND p.run_id = p_run_id AND p.codigo = p_codigo AND p.liberada_em IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN
    RAISE EXCEPTION 'Folha % não tem pendência aberta com o código %', p_run_id, p_codigo;
  END IF;
  INSERT INTO folha.auditoria (account_id, actor, acao, recurso, recurso_id, detalhe)
  VALUES (v_conta, btrim(p_responsavel), 'liberar_pendencia', 'payroll_run', p_run_id,
          jsonb_build_object('codigo', p_codigo, 'motivo', btrim(p_motivo), 'pendencias', v_n, 'sessao', session_user));
  RETURN v_n;
END;
$$;

-- 8.4 Aprovação e fechamento. A trava (8.1) recusa se houver pendência sem liberação e, no
--     fechamento, se faltar a data de pagamento.
CREATE FUNCTION folha.payroll_run_aprovar(p_run_id uuid, p_responsavel text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_conta uuid := folha.current_account_id();
  v_status text;
BEGIN
  IF v_conta IS NULL THEN
    RAISE EXCEPTION 'payroll_run_aprovar: sessão sem conta (contexto não aberto)';
  END IF;
  IF btrim(COALESCE(p_responsavel, '')) = '' THEN
    RAISE EXCEPTION 'payroll_run_aprovar: responsável obrigatório';
  END IF;
  SELECT r.status INTO v_status FROM folha.payroll_run r
   WHERE r.run_id = p_run_id AND r.account_id = v_conta FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Folha % não encontrada', p_run_id;
  END IF;
  IF v_status <> 'calculated' THEN
    RAISE EXCEPTION 'Folha % está em % e não pode ser aprovada', p_run_id, v_status;
  END IF;
  UPDATE folha.payroll_run r
     SET status = 'approved', aprovado_em = now(), approved_by = btrim(p_responsavel), updated_at = now()
   WHERE r.run_id = p_run_id AND r.account_id = v_conta;
  INSERT INTO folha.auditoria (account_id, actor, acao, recurso, recurso_id, detalhe)
  VALUES (v_conta, btrim(p_responsavel), 'aprovar_folha', 'payroll_run', p_run_id, jsonb_build_object('sessao', session_user));
END;
$$;

CREATE FUNCTION folha.payroll_run_fechar(p_run_id uuid, p_responsavel text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_conta uuid := folha.current_account_id();
  v_status text;
BEGIN
  IF v_conta IS NULL THEN
    RAISE EXCEPTION 'payroll_run_fechar: sessão sem conta (contexto não aberto)';
  END IF;
  IF btrim(COALESCE(p_responsavel, '')) = '' THEN
    RAISE EXCEPTION 'payroll_run_fechar: responsável obrigatório';
  END IF;
  SELECT r.status INTO v_status FROM folha.payroll_run r
   WHERE r.run_id = p_run_id AND r.account_id = v_conta FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Folha % não encontrada', p_run_id;
  END IF;
  IF v_status <> 'approved' THEN
    RAISE EXCEPTION 'Folha % está em % e não pode ser fechada', p_run_id, v_status;
  END IF;
  UPDATE folha.payroll_run r
     SET status = 'closed', fechado_em = now(), updated_at = now()
   WHERE r.run_id = p_run_id AND r.account_id = v_conta;
  INSERT INTO folha.auditoria (account_id, actor, acao, recurso, recurso_id, detalhe)
  VALUES (v_conta, btrim(p_responsavel), 'fechar_folha', 'payroll_run', p_run_id, jsonb_build_object('sessao', session_user));
END;
$$;

-- ===========================================================================
-- 9. ACL das funções: tira o EXECUTE de todo papel que não seja o dono e concede só o
--    necessário. As auxiliares internas não são concedidas a ninguém.
-- ===========================================================================
DO $$
DECLARE
  v_item text[];
  v_papel text;
BEGIN
  FOREACH v_item SLICE 1 IN ARRAY ARRAY[
    ['folha.calc_inss(numeric, date)',                                              'dnex_gestao_folha_worker, dnex_gestao_data_owner'],
    ['folha.calc_fgts(numeric, text, date)',                                        'dnex_gestao_folha_worker, dnex_gestao_data_owner'],
    ['folha.calc_irrf_separado(numeric, numeric, integer, date)',                   'dnex_gestao_folha_worker, dnex_gestao_data_owner'],
    ['folha.calc_irrf_separado_apurar(numeric, numeric, integer, date)',            'dnex_gestao_folha_worker, dnex_gestao_data_owner'],
    ['folha.calc_inss_segurado_multiplos(numeric, text, date, numeric, numeric)',   'dnex_gestao_folha_worker, dnex_gestao_data_owner'],
    ['folha.dias_proporcionais(uuid, date)',                                        'dnex_gestao_folha_worker, dnex_gestao_data_owner'],
    ['folha.run_payroll_employee(uuid, uuid, integer, integer)',                    'dnex_gestao_folha_worker'],
    ['folha.payroll_run_concluir_calculo(uuid)',                                    'dnex_gestao_folha_worker'],
    ['folha.payroll_pendencias_liberar(uuid, text, text, text)',                    'dnex_gestao_folha_worker'],
    ['folha.payroll_run_aprovar(uuid, text)',                                       'dnex_gestao_folha_worker'],
    ['folha.payroll_run_fechar(uuid, text)',                                        'dnex_gestao_folha_worker'],
    ['folha.irrf_apurar(numeric, numeric, integer, date, text)',                    ''],
    ['folha.rubrica_por_codigo(uuid, text)',                                        ''],
    ['folha.rubrica_conferir(uuid, date)',                                          ''],
    ['folha.bases_somar(jsonb, uuid, numeric, date)',                               ''],
    ['folha.formula_avaliar(jsonb, jsonb, jsonb)',                                  ''],
    ['folha.resolver_regra(uuid, uuid, uuid, date)',                                ''],
    ['folha.processo_parametros(uuid, uuid, uuid, text[], text[])',                 ''],
    ['folha.folha_rubricas_calcular(uuid, uuid, uuid, text, date, date, integer, integer)', ''],
    ['folha.folha_13o_calcular(uuid, uuid, uuid, text, date, date, integer)',       ''],
    ['folha.folha_ferias_calcular(uuid, uuid, uuid, date, date, integer)',          ''],
    ['folha.folha_rescisao_calcular(uuid, uuid, uuid, date, date, integer)',        ''],
    ['folha.folha_gravar_resultado(uuid, uuid, uuid, date, jsonb)',                 ''],
    ['folha.payroll_run_trava()',                                                   ''],
    ['folha.payroll_result_so_em_folha_aberta()',                                   ''],
    ['folha.processo_pendencias_gerais(uuid, uuid, date)',                          '']
  ]
  LOOP
    FOR v_papel IN
      SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(r.rolname) END
        FROM pg_catalog.pg_proc p
        CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
        LEFT JOIN pg_catalog.pg_roles r ON r.oid = a.grantee
       WHERE p.oid = v_item[1]::regprocedure AND a.grantee <> p.proowner
       GROUP BY 1
    LOOP
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM %s', v_item[1], v_papel);
    END LOOP;
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated, service_role', v_item[1]);
    IF v_item[2] <> '' THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %s', v_item[1], v_item[2]);
    END IF;
  END LOOP;
END
$$;

COMMIT;
