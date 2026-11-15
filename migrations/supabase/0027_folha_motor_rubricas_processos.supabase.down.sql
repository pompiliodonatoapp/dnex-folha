-- DNEX Folha — Reversão da migration 0027.
--
-- AVISO: esta reversão devolve o motor ao estado da 0025 (base = salário contratual do mês
-- cheio, zero silencioso para remuneração nula ou negativa, sem trava de fechamento). Use só
-- para desfazer uma aplicação que deu errado e reaplique a 0027 corrigida em seguida. Não é
-- um estado para operar. A estrutura da 0026 permanece (reverta-a depois, se for o caso).
--
-- Recusa (SQLSTATE 55000) se houver item de resultado, pendência ou folha de tipo diferente
-- de mensal: esses dados foram gravados pelo motor da 0027 e o da 0025 não os entende.
-- Os corpos restaurados são cópia literal da migration 0025.
BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL row_security = off;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM folha.payroll_result_item)
     OR EXISTS (SELECT 1 FROM folha.payroll_pendency) THEN
    RAISE EXCEPTION '0027 (reversão): há itens de resultado ou pendências gravados pelo motor por rubricas; exporte antes de reverter'
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  IF EXISTS (SELECT 1 FROM folha.payroll_run WHERE tipo_processo <> 'mensal') THEN
    RAISE EXCEPTION '0027 (reversão): há folha de tipo de processo diferente de mensal'
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
END
$$;

GRANT INSERT ON folha.payroll_result, folha.calculation_trace TO dnex_gestao_folha_worker;
DROP TRIGGER trg_payroll_result_so_em_folha_aberta ON folha.payroll_result;
DROP FUNCTION folha.payroll_result_so_em_folha_aberta();
DROP TRIGGER trg_payroll_run_trava ON folha.payroll_run;
DROP FUNCTION folha.payroll_run_trava();
DROP FUNCTION folha.payroll_run_fechar(uuid, text);
DROP FUNCTION folha.payroll_run_aprovar(uuid, text);
DROP FUNCTION folha.payroll_pendencias_liberar(uuid, text, text, text);
DROP FUNCTION folha.payroll_run_concluir_calculo(uuid);

-- run_payroll_employee: corpo da 0025 (o ACL da função é preservado pelo CREATE OR REPLACE)
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
  v_employee_id uuid;
  v_salario numeric;
  v_categoria text;
  v_competencia date;
  v_data_pagamento date;
  v_inss record;
  v_irrf record;
  v_fgts record;
  v_sf record;
  v_sf_valor numeric := 0;
  v_enc record;
  v_encs jsonb;
  v_status text;
  v_run_employer uuid;
  v_contract_employer uuid;
  v_patronal numeric;
  v_rat numeric;
  v_terceiros numeric;
  v_pend text[] := ARRAY[]::text[];
  v_result_id uuid;
  v_passo integer := 10;
BEGIN
  IF v_conta IS NULL THEN
    RAISE EXCEPTION 'run_payroll_employee: sessão sem conta (contexto não aberto)';
  END IF;
  IF COALESCE(p_num_dependentes_irrf, 0) < 0 OR COALESCE(p_num_filhos_salario_familia, 0) < 0 THEN
    RAISE EXCEPTION 'run_payroll_employee: dependentes e filhos não podem ser negativos';
  END IF;

  SELECT c.employee_id, c.salario_base, c.regime_trabalho, c.employer_id
    INTO v_employee_id, v_salario, v_categoria, v_contract_employer
    FROM folha.employment_contract c
   WHERE c.contract_id = p_contract_id AND c.account_id = v_conta;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Contrato % não encontrado', p_contract_id;
  END IF;

  -- Trava a folha: chamadas simultâneas para a mesma folha ficam em fila.
  SELECT r.competencia, r.data_pagamento, r.status, r.employer_id
    INTO v_competencia, v_data_pagamento, v_status, v_run_employer
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

  IF v_data_pagamento IS NULL THEN
    v_data_pagamento := (date_trunc('month', v_competencia) + interval '1 month' - interval '1 day')::date;
    v_pend := v_pend || ARRAY['pendencia:data_pagamento_nao_informada_usado_ultimo_dia_da_competencia'];
  END IF;

  SELECT * INTO v_inss FROM folha.calc_inss_segurado(v_salario, v_categoria, v_competencia);
  SELECT * INTO v_irrf FROM folha.calc_irrf(v_salario, v_inss.valor_inss,
                                            COALESCE(p_num_dependentes_irrf, 0), v_data_pagamento);
  SELECT * INTO v_fgts FROM folha.calc_fgts(v_salario, v_categoria, v_competencia);

  IF COALESCE(p_num_filhos_salario_familia, 0) > 0 THEN
    IF v_categoria IN ('clt', 'aprendiz') THEN
      SELECT * INTO v_sf FROM folha.calc_salario_familia(v_salario, p_num_filhos_salario_familia, v_competencia);
      v_sf_valor := v_sf.valor;
      v_pend := v_pend || v_sf.pendencias;
    ELSE
      v_pend := v_pend || ARRAY['pendencia:salario_familia_nao_calculado_para_a_categoria'];
    END IF;
  END IF;

  v_pend := v_pend || v_inss.pendencias || v_irrf.pendencias;

  -- Encargos patronais por lotação, ANTES de gravar: qualquer falta de cadastro levanta
  -- exceção e nada é gravado.
  SELECT COALESCE(jsonb_agg(to_jsonb(e)), '[]'::jsonb) INTO v_encs
    FROM folha.calc_encargos_patronais(p_contract_id, v_competencia, v_salario, 0) e;
  IF jsonb_array_length(v_encs) = 0 THEN
    RAISE EXCEPTION 'run_payroll_employee: encargos patronais do contrato % não foram apurados', p_contract_id;
  END IF;
  SELECT sum((x->>'inss_patronal')::numeric), sum((x->>'rat')::numeric), sum((x->>'terceiros')::numeric)
    INTO v_patronal, v_rat, v_terceiros
    FROM jsonb_array_elements(v_encs) x;
  IF v_patronal IS NULL OR v_rat IS NULL OR v_terceiros IS NULL THEN
    RAISE EXCEPTION 'run_payroll_employee: encargos patronais do contrato % vieram nulos', p_contract_id;
  END IF;

  INSERT INTO folha.payroll_result (
    run_id, account_id, employee_id, contract_id,
    total_proventos, total_descontos, liquido,
    inss_empregado, irrf, fgts,
    inss_patronal, rat, terceiros,
    calculation_hash
  ) VALUES (
    p_run_id, v_conta, v_employee_id, p_contract_id,
    v_salario + v_sf_valor,
    v_inss.valor_inss + v_irrf.valor_irrf,
    v_salario + v_sf_valor - v_inss.valor_inss - v_irrf.valor_irrf,
    v_inss.valor_inss, v_irrf.valor_irrf, v_fgts.fgts_deposito,
    v_patronal, v_rat, v_terceiros,
    md5(v_conta::text || p_contract_id::text || v_competencia::text || v_data_pagamento::text
        || v_salario::text || v_categoria || COALESCE(p_num_dependentes_irrf, 0)::text
        || COALESCE(p_num_filhos_salario_familia, 0)::text)
  ) RETURNING result_id INTO v_result_id;

  FOR v_enc IN SELECT x FROM jsonb_array_elements(v_encs) x
  LOOP
    v_pend := v_pend || ARRAY(SELECT jsonb_array_elements_text(v_enc.x->'pendencias'));

    INSERT INTO folha.calculation_trace (result_id, account_id, step_order, rubrica_code, descricao, base_calculo, aliquota, valor, tipo, detail_json)
    VALUES
      (v_result_id, v_conta, v_passo, 'INSS_PATRONAL', 'Contribuição patronal por lotação', (v_enc.x->>'base_rateada')::numeric, (v_enc.x->>'aliq_patronal')::numeric, (v_enc.x->>'inss_patronal')::numeric, 'encargo',
       v_enc.x - 'pendencias'),
      (v_result_id, v_conta, v_passo + 1, 'RAT_SAT', 'RAT x FAP por lotação', (v_enc.x->>'base_rateada')::numeric, (v_enc.x->>'aliq_rat')::numeric, (v_enc.x->>'rat')::numeric, 'encargo',
       v_enc.x - 'pendencias'),
      (v_result_id, v_conta, v_passo + 2, 'TERCEIROS', 'Terceiros por lotação', (v_enc.x->>'base_rateada')::numeric, (v_enc.x->>'aliq_terceiros')::numeric, (v_enc.x->>'terceiros')::numeric, 'encargo',
       v_enc.x - 'pendencias');
    v_passo := v_passo + 3;
  END LOOP;

  v_pend := ARRAY(SELECT DISTINCT p FROM unnest(v_pend) AS p ORDER BY p);

  INSERT INTO folha.calculation_trace (result_id, account_id, step_order, rubrica_code, descricao, base_calculo, aliquota, valor, tipo, detail_json)
  VALUES
    (v_result_id, v_conta, 1, 'SALARIO_BASE', 'Salário base contratual', v_salario, 1.0000, v_salario, 'provento',
     jsonb_build_object('categoria', v_categoria, 'competencia', v_competencia, 'data_pagamento', v_data_pagamento,
                        'pendencias', to_jsonb(v_pend))),
    (v_result_id, v_conta, 2, 'INSS_EMPREGADO', 'INSS do segurado', v_inss.base_contribuicao, v_inss.aliquota_efetiva, v_inss.valor_inss, 'desconto',
     jsonb_build_object('metodo', v_inss.metodo, 'tabela_vigencia', v_inss.tabela_vigencia)),
    (v_result_id, v_conta, 3, 'IRRF', 'IRRF sobre rendimento do trabalho', v_irrf.base_calculo, v_irrf.aliquota_efetiva, v_irrf.valor_irrf, 'desconto',
     jsonb_build_object('rendimento_tributavel', v_salario, 'deducao_aplicada', v_irrf.desconto_aplicado,
                        'dependentes', COALESCE(p_num_dependentes_irrf, 0), 'imposto_tabela', v_irrf.imposto_tabela,
                        'redutor_lei_15270', v_irrf.redutor_lei_15270, 'tabela_vigencia', v_irrf.tabela_vigencia,
                        'data_pagamento', v_data_pagamento)),
    (v_result_id, v_conta, 4, 'FGTS_DEPOSITO', 'FGTS depósito mensal (encargo)', v_salario, v_fgts.aliquota, v_fgts.fgts_deposito, 'informativo',
     jsonb_build_object('tabela_vigencia', v_fgts.tabela_vigencia, 'fonte_normativa', v_fgts.fonte_normativa));

  IF v_sf_valor > 0 THEN
    INSERT INTO folha.calculation_trace (result_id, account_id, step_order, rubrica_code, descricao, base_calculo, aliquota, valor, tipo, detail_json)
    VALUES (v_result_id, v_conta, 5, 'SALARIO_FAMILIA', 'Salário-família', v_salario, NULL, v_sf_valor, 'provento',
            jsonb_build_object('cota', v_sf.cota, 'remuneracao_limite', v_sf.remuneracao_limite,
                               'filhos', p_num_filhos_salario_familia));
  END IF;

  RETURN v_result_id;
END;
$$;

DROP FUNCTION folha.folha_gravar_resultado(uuid, uuid, uuid, date, jsonb);
DROP FUNCTION folha.pendencia_tipo(text);

-- dispatch_folha_completa: corpo da 0020
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

DROP FUNCTION folha.folha_rescisao_calcular(uuid, uuid, uuid, date, date, integer);
DROP FUNCTION folha.folha_ferias_calcular(uuid, uuid, uuid, date, date, integer);
DROP FUNCTION folha.folha_13o_calcular(uuid, uuid, uuid, text, date, date, integer);
DROP FUNCTION folha.processo_pendencias_gerais(uuid, uuid, date);
DROP FUNCTION folha.processo_parametros(uuid, uuid, uuid, text[], text[]);
DROP FUNCTION folha.folha_rubricas_calcular(uuid, uuid, uuid, text, date, date, integer, integer);
DROP FUNCTION folha.dias_proporcionais(uuid, date);
DROP FUNCTION folha.resolver_regra(uuid, uuid, uuid, date);
DROP FUNCTION folha.formula_avaliar(jsonb, jsonb, jsonb);
DROP FUNCTION folha.bases_somar(jsonb, uuid, numeric, date);
DROP FUNCTION folha.rubrica_conferir(uuid, date);
DROP FUNCTION folha.rubrica_por_codigo(uuid, text);
DROP FUNCTION folha.calc_inss_segurado_multiplos(numeric, text, date, numeric, numeric);
DROP FUNCTION folha.calc_irrf_separado_apurar(numeric, numeric, integer, date);

-- Corpos da 0025
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
  IF COALESCE(p_rendimento, 0) <= 0 THEN
    RETURN 0;
  END IF;
  RETURN (SELECT a.valor_irrf
            FROM folha.irrf_apurar(p_rendimento, GREATEST(COALESCE(p_deducoes, 0), 0),
                                   GREATEST(COALESCE(p_num_dependentes, 0), 0),
                                   p_competencia, 'separado') a);
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
  IF COALESCE(p_rendimento, 0) <= 0 THEN
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

  fgts_deposito := round(GREATEST(COALESCE(p_remuneracao, 0), 0) * aliquota, 2);
  RETURN NEXT;
END;
$$;

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
  v_base := LEAST(GREATEST(COALESCE(p_salario_contribuicao, 0), 0), v_teto);

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

COMMIT;
