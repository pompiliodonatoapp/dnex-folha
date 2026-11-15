-- DNEX Folha — Reversão da migration 0025.
--
-- AVISO: esta reversão devolve o motor mensal ao estado das migrations 0016, 0023 e 0024, que
-- é o estado com os erros apontados no parecer de INSS/FGTS (IRRF com a redução aferida pela
-- base, FGTS para estagiário e PJ, "multa" de 40% sobre o depósito do mês, encargos patronais
-- nulos, policies avaliando a conta por linha). Use só para desfazer uma aplicação que deu
-- errado e reaplique a 0025 corrigida em seguida. Não é um estado para operar.
--
-- Recusa (SQLSTATE 55000) se houver contrato de contribuinte individual, folha com data de
-- pagamento ou lotação com alíquota de terceiros: esses dados teriam de ser exportados antes.
-- A conferência roda com row_security = off; se o papel não ignorar RLS, falha em vez de
-- apagar sem ver. Resultados de folha já gravados pela função nova permanecem.
-- Os corpos das funções restauradas são cópia literal das migrations de origem (linhas
-- indicadas em cada bloco).
BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL row_security = off;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM folha.employment_contract WHERE regime_trabalho = 'contribuinte_individual') THEN
    RAISE EXCEPTION '0025 (reversão): há contrato de contribuinte individual; o CHECK da 0014 não o aceita'
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  IF EXISTS (SELECT 1 FROM folha.payroll_run WHERE data_pagamento IS NOT NULL) THEN
    RAISE EXCEPTION '0025 (reversão): há folha com data de pagamento; exporte antes de reverter'
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  IF EXISTS (SELECT 1 FROM folha.tax_allocation_detail WHERE aliquota_terceiros IS NOT NULL) THEN
    RAISE EXCEPTION '0025 (reversão): há lotação com alíquota de terceiros; exporte antes de reverter'
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
END
$$;

-- Conta da sessão: corpo da 0024 (0024:155-217), sem a leitura da configuração
CREATE OR REPLACE FUNCTION folha.request_context_account_id() RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, gestao_auth
SET row_security = on
AS $function$
DECLARE
  v_nonce_text text;
  v_txid bigint;
  v_contexto record;
BEGIN
  v_nonce_text := NULLIF(pg_catalog.current_setting('dnex.context_nonce', true), '');
  IF v_nonce_text IS NULL
     OR v_nonce_text !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN
    RETURN NULL;
  END IF;

  -- begin_request usa txid_current(): transação sem xid atribuído não tem contexto.
  v_txid := pg_catalog.txid_current_if_assigned();
  IF v_txid IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT context.account_id, context.legal_entity_id, context.branch_id, context.principal_group
    INTO v_contexto
    FROM gestao_auth.request_context AS context
    JOIN gestao_auth.access_assertion AS assertion
      ON assertion.assertion_id = context.assertion_id
   WHERE context.context_nonce = v_nonce_text::uuid
     AND context.runtime_session_user = session_user
     AND context.backend_pid = pg_catalog.pg_backend_pid()
     AND context.transaction_id = v_txid
     AND context.created_at <= pg_catalog.statement_timestamp()
     AND context.expires_at > pg_catalog.statement_timestamp()
     AND assertion.runtime_session_user = context.runtime_session_user
     AND assertion.subject_id = context.subject_id
     AND assertion.subject_type = context.subject_type
     AND assertion.principal_group = context.principal_group
     AND assertion.account_id = context.account_id
     AND assertion.legal_entity_id = context.legal_entity_id
     AND assertion.branch_id = context.branch_id
     AND assertion.permissions = context.permissions
     AND assertion.consumed_at = context.created_at
     AND assertion.revoked_at IS NULL
     AND assertion.expires_at > pg_catalog.statement_timestamp();

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  BEGIN
    PERFORM gestao_auth.assert_authorization_principal_v1(session_user, v_contexto.principal_group);
  EXCEPTION WHEN insufficient_privilege THEN
    RETURN NULL;
  END;

  IF NOT COALESCE(gestao_auth.is_active_scope_v1(
       v_contexto.account_id, v_contexto.legal_entity_id, v_contexto.branch_id), false) THEN
    RETURN NULL;
  END IF;

  RETURN v_contexto.account_id;
END
$function$;

-- Folha mensal: corpo e GRANTs da 0016 (0016:251-333)
DROP FUNCTION folha.run_payroll_employee(uuid, uuid, integer, integer);
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

DROP FUNCTION folha.calc_encargos_patronais(uuid, date, numeric, numeric);
DROP FUNCTION folha.calc_salario_familia(numeric, integer, date, numeric);
DROP FUNCTION folha.calc_inss_segurado(numeric, text, date);

-- IRRF em separado: corpo da 0023 (0023:237-305)
CREATE OR REPLACE FUNCTION folha.calc_irrf_separado(
  p_rendimento numeric,
  p_deducoes numeric DEFAULT 0,
  p_num_dependentes integer DEFAULT 0,
  p_competencia date DEFAULT CURRENT_DATE
) RETURNS numeric
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_tabela jsonb;
  v_faixa jsonb;
  v_ded_dep numeric;
  v_base numeric;
  v_imposto numeric := 0;
  v_cfg jsonb;
  v_ref numeric;
  v_redutor numeric := 0;
BEGIN
  IF COALESCE(p_rendimento, 0) <= 0 THEN
    RETURN 0;
  END IF;

  SELECT t.tabela_json INTO v_tabela
    FROM folha.tax_table_version t
   WHERE t.tipo = 'irrf'
     AND t.vigencia_inicio <= p_competencia
     AND (t.vigencia_fim IS NULL OR t.vigencia_fim >= p_competencia)
   ORDER BY t.vigencia_inicio DESC
   LIMIT 1;

  IF v_tabela IS NULL THEN
    RAISE EXCEPTION 'Tabela IRRF não encontrada para competência %', p_competencia;
  END IF;

  v_ded_dep := (v_tabela->>'deducao_dependente_mensal')::numeric;
  IF COALESCE(p_num_dependentes, 0) > 0 AND v_ded_dep IS NULL THEN
    RAISE EXCEPTION 'Tabela IRRF de % sem dedução por dependente cadastrada', p_competencia;
  END IF;

  v_base := GREATEST(p_rendimento - COALESCE(p_deducoes, 0)
                     - COALESCE(p_num_dependentes, 0) * COALESCE(v_ded_dep, 0), 0);

  FOR v_faixa IN SELECT * FROM jsonb_array_elements(v_tabela->'faixas')
  LOOP
    IF (v_faixa->>'limite_superior') IS NULL OR v_base <= (v_faixa->>'limite_superior')::numeric THEN
      v_imposto := GREATEST(v_base * (v_faixa->>'aliquota')::numeric
                            - (v_faixa->>'parcela_deduzir')::numeric, 0);
      EXIT;
    END IF;
  END LOOP;

  v_cfg := v_tabela->'redutor_lei_15270_2025';
  IF v_cfg IS NOT NULL AND jsonb_typeof(v_cfg) = 'object' THEN
    v_ref := CASE WHEN folha.get_param('irrf_redutor_referencia_bruto', p_competencia) = 1
                  THEN p_rendimento
                  ELSE p_rendimento - COALESCE(p_deducoes, 0) END;
    IF v_ref <= (v_cfg->>'isencao_efetiva_ate')::numeric THEN
      v_redutor := v_imposto;
    ELSIF v_ref <= (v_cfg->>'reducao_decrescente_ate')::numeric THEN
      v_redutor := LEAST(GREATEST(folha.get_param('irrf_redutor_coef_a', p_competencia)
                                  - folha.get_param('irrf_redutor_coef_b', p_competencia) * v_ref, 0),
                         v_imposto);
    END IF;
  END IF;

  RETURN GREATEST(ROUND(v_imposto - v_redutor, 2), 0);
END;
$$;

-- IRRF mensal: corpo e GRANTs da 0016 (0016:79-188)
DROP FUNCTION folha.calc_irrf(numeric, numeric, integer, date, numeric);
DROP FUNCTION folha.irrf_apurar(numeric, numeric, integer, date, text);
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

-- FGTS: corpo e GRANTs da 0016 (0016:193-245)
DROP FUNCTION folha.calc_fgts(numeric, text, date);
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

-- INSS: corpo da 0023 (0023:314-370)
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
  v_base := LEAST(GREATEST(COALESCE(p_salario_contribuicao, 0), 0), v_teto);

  FOR v_faixa IN SELECT * FROM jsonb_array_elements(v_tabela->'faixas')
  LOOP
    v_ls := COALESCE((v_faixa->>'limite_superior')::numeric, v_teto);
    IF v_base > v_piso THEN
      v_valor := v_valor + (LEAST(v_base, v_ls) - v_piso) * (v_faixa->>'aliquota')::numeric;
    END IF;
    v_piso := v_ls;
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
DROP FUNCTION folha.arredondar_inss(numeric, date);

-- As funções recriadas acima voltam com os GRANTs das migrations de origem; aqui só se
-- garante que anon, authenticated e service_role não herdem EXECUTE de PUBLIC ou de default ACL.
REVOKE ALL ON FUNCTION folha.run_payroll_employee(uuid, uuid) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION folha.calc_irrf(numeric, integer, boolean, date) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION folha.calc_fgts(numeric, text, date) FROM PUBLIC, anon, authenticated, service_role;

-- Policies da 0014 e da 0018: de volta à chamada direta de current_account_id()
DO $$
DECLARE
  v_par text[];
BEGIN
  FOREACH v_par SLICE 1 IN ARRAY ARRAY[
    ['employee_isolamento',          'employee'],
    ['contract_isolamento',          'employment_contract'],
    ['run_isolamento',               'payroll_run'],
    ['result_isolamento',            'payroll_result'],
    ['trace_isolamento',             'calculation_trace'],
    ['rule_isolamento',              'payroll_rule_version'],
    ['agreement_isolamento',         'collective_agreement'],
    ['benefit_isolamento',           'benefit'],
    ['auditoria_isolamento',         'auditoria'],
    ['accounting_outbox_isolamento', 'accounting_outbox'],
    ['esocial_outbox_isolamento',    'esocial_event_outbox']
  ]
  LOOP
    EXECUTE format('DROP POLICY %I ON folha.%I', v_par[1], v_par[2]);
    EXECUTE format(
      'CREATE POLICY %I ON folha.%I
         USING (account_id = folha.current_account_id())
         WITH CHECK (account_id = folha.current_account_id())',
      v_par[1], v_par[2]);
  END LOOP;
END
$$;

DROP POLICY rubrica_isolamento ON folha.earning_deduction_code;
CREATE POLICY rubrica_isolamento ON folha.earning_deduction_code
  USING (account_id = folha.current_account_id() OR is_global = true)
  WITH CHECK (account_id = folha.current_account_id());

-- Parâmetros e tabelas semeados pela 0025
-- Só as linhas que a 0025 semeou (marcadas na observação); linha que já existia fica.
DELETE FROM folha.payroll_parameter
 WHERE observacao LIKE '%[semeado pela 0025]';

-- Estado e observação da 0023 (0023:88-90), só onde a 0025 mexeu
UPDATE folha.payroll_parameter
   SET status_validacao = 'a_validar',
       observacao = 'Redução = a - b x rendimento (mesmo valor fixo em 0016)',
       updated_at = now()
 WHERE chave IN ('irrf_redutor_coef_a', 'irrf_redutor_coef_b') AND vigencia_inicio = '2026-01-01'
   AND observacao LIKE '%[validado pela 0025]';
UPDATE folha.payroll_parameter
   SET observacao = '1 = redutor aferido pelo rendimento tributável bruto; 0 = pela base após deduções (critério de calc_irrf)',
       updated_at = now()
 WHERE chave = 'irrf_redutor_referencia_bruto' AND vigencia_inicio = '2026-01-01';

DELETE FROM folha.tax_table_version
 WHERE vigencia_inicio < '2026-01-01'
   AND source_hash LIKE 'rotulo:parecer-inss-fgts-encargos-20261115:%';

-- Salário-família de 2026: volta ao conteúdo da 0015 (0015:118-132), não ao da correção
-- posterior feita fora deste repositório.
UPDATE folha.tax_table_version
   SET tabela_json = '{
    "cota_baixa_renda": null,
    "cota_alta_renda": null,
    "faixa_baixa_renda_ate": null,
    "observacao": "VALORES PLACEHOLDER — REVALIDAR NA PORTARIA MPS/MF VIGENTE ANTES DE USAR EM PRODUÇÃO",
    "status_confirmacao": "a_confirmar",
    "base_legal": "Lei 8.213/1991"
  }'::jsonb,
       source_url = 'https://www.gov.br/previdencia/pt-br/assuntos/salario-familia',
       source_hash = 'sha256:salario_familia_2026_placeholder_a_confirmar'
 WHERE tipo = 'salario_familia' AND vigencia_inicio = '2026-01-01';

-- Cadastro
DROP INDEX folha.payroll_result_run_contract_key;
DROP TABLE folha.request_context_config;
ALTER TABLE folha.tax_allocation_detail DROP COLUMN aliquota_terceiros;
ALTER TABLE folha.payroll_run DROP COLUMN data_pagamento;
ALTER TABLE folha.employment_contract
  DROP CONSTRAINT employment_contract_regime_trabalho_check,
  ADD CONSTRAINT employment_contract_regime_trabalho_check
    CHECK (regime_trabalho IN ('clt', 'pj', 'estagio', 'aprendiz'));

COMMIT;
