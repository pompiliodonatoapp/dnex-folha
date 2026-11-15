-- DNEX Folha — Migration 0023: correção do motor de eventos de vida (13º, férias, rescisão).
-- Reescreve calc_13o, calc_ferias e calc_rescisao conforme os pareceres de DP de 15/11/2026
-- (scratch/pareceres). Os casos dourados dos pareceres (CT-01..CT-13 e G01..G12) estão em
-- tests/folha/0023_eventos_vida_dourados.pgtap.sql e foram executados em Postgres 17 + pgTAP.
--
-- O que esta migration faz:
--   1. folha.payroll_parameter: constantes normativas por vigência. O que os pareceres marcam
--      "A VALIDAR NA FONTE" entra com status_validacao = 'a_validar'.
--   2. Auxiliares: get_param, params_a_validar, avos_13o, avos_ferias, calc_irrf_separado.
--   3. calc_inss com faixas contínuas (achado V5/C3: perdia 1 centavo de base por faixa).
--   4. calc_13o, calc_ferias e calc_rescisao reescritas (assinaturas novas; as antigas são removidas).
--   5. Incidências das rubricas de férias indenizadas, abono e 1ª parcela do 13º (V2, V3, V4).
--
-- NÃO altera as migrations 0014–0022 (já aplicadas em produção).
-- Reversão: reaplicar as definições de 0016 (calc_inss) e 0019 (calc_ferias, calc_13o, calc_rescisao)
--   depois de DROP FUNCTION das assinaturas novas; DROP FUNCTION folha.calc_irrf_separado,
--   folha.avos_ferias, folha.avos_13o, folha.params_a_validar, folha.get_param;
--   DROP TABLE folha.payroll_parameter. Os UPDATEs de rubrica voltam com os booleanos de 0017.
BEGIN;

-- ===========================================================================
-- 1. Parâmetros normativos por vigência
-- ===========================================================================
CREATE TABLE IF NOT EXISTS folha.payroll_parameter (
  parameter_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  chave text NOT NULL,
  valor numeric NOT NULL,
  vigencia_inicio date NOT NULL,
  vigencia_fim date,
  fonte_normativa text NOT NULL,
  status_validacao text NOT NULL DEFAULT 'validado'
    CHECK (status_validacao IN ('validado', 'a_validar')),
  observacao text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (chave, vigencia_inicio)
);

ALTER TABLE folha.payroll_parameter ENABLE ROW LEVEL SECURITY;
ALTER TABLE folha.payroll_parameter FORCE ROW LEVEL SECURITY;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'folha' AND tablename = 'payroll_parameter' AND policyname = 'payroll_param_read') THEN
    CREATE POLICY payroll_param_read ON folha.payroll_parameter FOR SELECT USING (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'folha' AND tablename = 'payroll_parameter' AND policyname = 'payroll_param_write') THEN
    CREATE POLICY payroll_param_write ON folha.payroll_parameter
      FOR INSERT WITH CHECK (current_user = 'dnex_gestao_data_owner');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'folha' AND tablename = 'payroll_parameter' AND policyname = 'payroll_param_update') THEN
    CREATE POLICY payroll_param_update ON folha.payroll_parameter
      FOR UPDATE USING (current_user = 'dnex_gestao_data_owner')
      WITH CHECK (current_user = 'dnex_gestao_data_owner');
  END IF;
END $$;

REVOKE ALL ON folha.payroll_parameter FROM PUBLIC, anon, authenticated;
GRANT SELECT ON folha.payroll_parameter TO dnex_gestao_folha_worker;
GRANT SELECT, INSERT, UPDATE ON folha.payroll_parameter TO dnex_gestao_data_owner;

INSERT INTO folha.payroll_parameter (chave, valor, vigencia_inicio, fonte_normativa, status_validacao, observacao) VALUES
  -- 13º salário
  ('avos_13o_fracao_minima_dias',        15,       '2026-01-01', 'Lei 4.090/1962 art. 1º § 2º; Decreto 10.854/2021 art. 76 § 2º', 'validado',  'Fração igual ou superior a 15 dias no mês conta como avo'),
  ('adiantamento_13o_fracao',            0.5,      '2026-01-01', 'Lei 4.749/1965 art. 2º; Decreto 10.854/2021 art. 78',          'validado',  'Adiantamento: metade'),
  ('adiantamento_13o_mes_inicio',        2,        '2026-01-01', 'Lei 4.749/1965 art. 2º',                                       'validado',  'Janela do adiantamento: de fevereiro'),
  ('adiantamento_13o_mes_fim',           11,       '2026-01-01', 'Lei 4.749/1965 art. 2º',                                       'validado',  'Janela do adiantamento: até novembro'),
  ('quitacao_13o_data_limite',           20,       '2026-01-01', 'Lei 4.749/1965 art. 1º; Decreto 10.854/2021 art. 76',          'validado',  'Dia-limite da quitação em dezembro'),
  ('ajuste_variaveis_data_limite_mes',   1,        '2026-01-01', 'Decreto 10.854/2021 art. 77 parágrafo único',                  'validado',  'Mês do ajuste de variáveis: janeiro'),
  ('ajuste_variaveis_data_limite_dia',   10,       '2026-01-01', 'Decreto 10.854/2021 art. 77 parágrafo único',                  'validado',  'Dia-limite do ajuste de variáveis'),
  ('divisor_variaveis_quitacao',         11,       '2026-01-01', 'Decreto 10.854/2021 art. 77 caput',                            'a_validar', 'Divisor das variáveis na quitação (1/11 até novembro)'),
  ('divisor_variaveis_ajuste',           12,       '2026-01-01', 'Decreto 10.854/2021 art. 77 parágrafo único',                  'a_validar', 'Divisor das variáveis no ajuste de janeiro (1/12 do ano)'),
  -- Férias
  ('ferias_frac_avo_dias',               14,       '2026-01-01', 'CLT art. 146 parágrafo único',                                 'validado',  'Fração superior a 14 dias conta como avo'),
  ('ferias_terco_divisor',               3,        '2026-01-01', 'CF art. 7º, XVII',                                             'validado',  'Terço constitucional = valor / 3'),
  ('ferias_abono_divisor_max',           3,        '2026-01-01', 'CLT art. 143',                                                 'validado',  'Abono máximo = dias de direito / 3'),
  ('ferias_antecedencia_pagamento_dias', 2,        '2026-01-01', 'CLT art. 145',                                                 'validado',  'Pagamento até 2 dias antes do início; dia não útil: a validar'),
  ('ferias_periodo_concessivo_meses',    12,       '2026-01-01', 'CLT art. 134',                                                 'validado',  'Concessão nos 12 meses seguintes à aquisição'),
  ('ferias_fracionamento_max_periodos',  3,        '2026-01-01', 'CLT art. 134 § 1º',                                            'a_validar', 'Até 3 períodos (ainda não validado pelo motor)'),
  ('ferias_fracionamento_minimo_1',      14,       '2026-01-01', 'CLT art. 134 § 1º',                                            'a_validar', 'Um período com no mínimo 14 dias (ainda não validado pelo motor)'),
  ('ferias_fracionamento_minimo_2',      5,        '2026-01-01', 'CLT art. 134 § 1º',                                            'a_validar', 'Demais períodos com no mínimo 5 dias (ainda não validado pelo motor)'),
  ('ferias_escala_faltas_0_5',           30,       '2026-01-01', 'CLT art. 130',                                                 'validado',  'Até 5 faltas: 30 dias'),
  ('ferias_escala_faltas_6_14',          24,       '2026-01-01', 'CLT art. 130',                                                 'validado',  '6 a 14 faltas: 24 dias'),
  ('ferias_escala_faltas_15_23',         18,       '2026-01-01', 'CLT art. 130',                                                 'validado',  '15 a 23 faltas: 18 dias'),
  ('ferias_escala_faltas_24_32',         12,       '2026-01-01', 'CLT art. 130',                                                 'validado',  '24 a 32 faltas: 12 dias'),
  ('irrf_abono_pecuniario_incide',       0,        '2026-01-01', 'Parecer 13º/férias item 2.6 (ato PGFN/IN RFB não lidos)',      'a_validar', '0 = não retém IRRF sobre abono e seu terço; 1 = retém'),
  ('irrf_dobra_ferias_incide',           0,        '2026-01-01', 'Parecer 13º/férias item 2.6',                                  'a_validar', '0 = não retém IRRF sobre a dobra do art. 137; 1 = retém'),
  -- IRRF em separado (13º, férias, rescisão)
  ('irrf_redutor_referencia_bruto',      1,        '2026-01-01', 'Lei 9.250/1995 art. 3º-A (Lei 15.270/2025)',                   'a_validar', '1 = redutor aferido pelo rendimento tributável bruto; 0 = pela base após deduções (critério de calc_irrf)'),
  ('irrf_redutor_coef_a',                978.62,   '2026-01-01', 'Lei 9.250/1995 art. 3º-A (Lei 15.270/2025)',                   'a_validar', 'Redução = a - b x rendimento (mesmo valor fixo em 0016)'),
  ('irrf_redutor_coef_b',                0.133145, '2026-01-01', 'Lei 9.250/1995 art. 3º-A (Lei 15.270/2025)',                   'a_validar', 'Redução = a - b x rendimento (mesmo valor fixo em 0016)'),
  -- Rescisão
  ('aviso_previo_base_dias',             30,       '2026-01-01', 'Lei 12.506/2011 art. 1º; CLT art. 487',                        'validado',  'Aviso-base: 30 dias'),
  ('aviso_previo_dias_por_ano',          3,        '2026-01-01', 'Lei 12.506/2011 art. 1º',                                      'a_validar', '3 dias por ano completo; critério de contagem (NT 184/2012) a validar'),
  ('aviso_previo_teto_dias',             90,       '2026-01-01', 'Lei 12.506/2011 art. 1º',                                      'validado',  'Teto: 90 dias'),
  ('acordo_484a_fracao_aviso',           0.5,      '2026-01-01', 'CLT art. 484-A, I, a',                                         'validado',  'Aviso indenizado pela metade no acordo'),
  ('multa_fgts_dispensa_sem_jc',         0.40,     '2026-01-01', 'Lei 8.036/1990 art. 18 § 1º',                                  'validado',  'Multa de 40% (dispensa sem justa causa e antecipação pelo empregador)'),
  ('multa_fgts_acordo_484a',             0.20,     '2026-01-01', 'CLT art. 484-A, I, b',                                         'validado',  'Multa de 20% no acordo'),
  ('indenizacao_art479_fracao',          0.50,     '2026-01-01', 'CLT art. 479',                                                 'validado',  'Metade da remuneração devida até o termo'),
  ('limite_compensacao_trct_salarios',   1,        '2026-01-01', 'CLT art. 477 § 5º',                                            'validado',  'Compensações limitadas a 1 mês de remuneração'),
  ('prazo_pagamento_rescisao_dias',      10,       '2026-01-01', 'CLT art. 477 § 6º',                                            'a_validar', '10 dias do término; forma de contagem e dia não útil a validar'),
  ('divisor_saldo_salario',              30,       '2026-01-01', 'Convenção do produto (mensalista)',                            'a_validar', 'Divisor do mês; dia 31, fevereiro e CCT a validar'),
  ('inss_aviso_indenizado_incide',       0,        '2026-01-01', 'Parecer de rescisão item 2.1.8 (STJ Tema 478 não lido)',       'a_validar', '0 = não incide; 1 = incide'),
  ('inss_projecao_aviso_incide',         1,        '2026-01-01', 'Parecer de rescisão item 2.1.8 (STJ Tema 1.170 não lido)',     'a_validar', '1 = INSS do 13º alcança os avos da projeção do aviso; 0 = não alcança')
-- DO NOTHING: reaplicar a migration não desfaz valor nem validação registrados depois.
ON CONFLICT (chave, vigencia_inicio) DO NOTHING;

-- ===========================================================================
-- 2. Auxiliares
-- ===========================================================================
CREATE OR REPLACE FUNCTION folha.get_param(
  p_chave text,
  p_data date DEFAULT CURRENT_DATE
) RETURNS numeric
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_valor numeric;
BEGIN
  SELECT pp.valor INTO v_valor
    FROM folha.payroll_parameter pp
   WHERE pp.chave = p_chave
     AND pp.vigencia_inicio <= p_data
     AND (pp.vigencia_fim IS NULL OR pp.vigencia_fim >= p_data)
   ORDER BY pp.vigencia_inicio DESC
   LIMIT 1;

  IF v_valor IS NULL THEN
    RAISE EXCEPTION 'Parâmetro % não encontrado para a data %', p_chave, p_data;
  END IF;
  RETURN v_valor;
END;
$$;

-- Devolve 'a_validar:<chave>' para cada parâmetro usado que ainda não foi validado na fonte.
CREATE OR REPLACE FUNCTION folha.params_a_validar(
  p_chaves text[],
  p_data date
) RETURNS text[]
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
  SELECT COALESCE(array_agg('a_validar:' || x.chave ORDER BY x.chave), ARRAY[]::text[])
    FROM (
      SELECT DISTINCT ON (pp.chave) pp.chave, pp.status_validacao
        FROM folha.payroll_parameter pp
       WHERE pp.chave = ANY (p_chaves)
         AND pp.vigencia_inicio <= p_data
         AND (pp.vigencia_fim IS NULL OR pp.vigencia_fim >= p_data)
       ORDER BY pp.chave, pp.vigencia_inicio DESC
    ) x
   WHERE x.status_validacao = 'a_validar';
$$;

-- Avos do 13º no ano civil: mês conta se tiver pelo menos N dias de contrato (N = parâmetro, hoje 15).
-- Sem desligamento, o ano vai até dezembro (adiantamento e quitação de quem segue ativo).
-- Sem piso: pode devolver 0. Faltas injustificadas e afastamentos ainda não entram (pendência).
CREATE OR REPLACE FUNCTION folha.avos_13o(
  p_ano integer,
  p_admissao date,
  p_desligamento date DEFAULT NULL
) RETURNS integer
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_fracao_min integer;
  v_avos integer := 0;
  v_ini_mes date;
  v_fim_mes date;
  v_ini date;
  v_fim date;
  m integer;
BEGIN
  IF p_ano IS NULL OR p_admissao IS NULL THEN
    RAISE EXCEPTION 'avos_13o: ano e admissão são obrigatórios';
  END IF;
  v_fracao_min := folha.get_param('avos_13o_fracao_minima_dias', make_date(p_ano, 12, 31))::integer;

  FOR m IN 1..12 LOOP
    v_ini_mes := make_date(p_ano, m, 1);
    v_fim_mes := (v_ini_mes + INTERVAL '1 month' - INTERVAL '1 day')::date;
    v_ini := GREATEST(v_ini_mes, p_admissao);
    v_fim := LEAST(v_fim_mes, COALESCE(p_desligamento, v_fim_mes));
    IF v_ini <= v_fim AND (v_fim - v_ini + 1) >= v_fracao_min THEN
      v_avos := v_avos + 1;
    END IF;
  END LOOP;

  RETURN v_avos;
END;
$$;

-- Avos de férias proporcionais: meses completos desde o início do período aquisitivo até a data
-- final (inclusive), mais 1 se o resto em dias for superior ao parâmetro (hoje 14). Teto de 12.
CREATE OR REPLACE FUNCTION folha.avos_ferias(
  p_inicio_aquisitivo date,
  p_data_fim date
) RETURNS integer
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_fracao integer;
  v_limite date;      -- dia seguinte ao último dia contado
  v_meses integer;
  v_resto integer;
BEGIN
  IF p_inicio_aquisitivo IS NULL OR p_data_fim IS NULL THEN
    RAISE EXCEPTION 'avos_ferias: início do período aquisitivo e data final são obrigatórios';
  END IF;
  IF p_data_fim < p_inicio_aquisitivo THEN
    RETURN 0;
  END IF;

  v_fracao := folha.get_param('ferias_frac_avo_dias', p_data_fim)::integer;
  v_limite := p_data_fim + 1;

  v_meses := ((EXTRACT(YEAR FROM v_limite) - EXTRACT(YEAR FROM p_inicio_aquisitivo)) * 12
            + (EXTRACT(MONTH FROM v_limite) - EXTRACT(MONTH FROM p_inicio_aquisitivo)))::integer;
  IF (p_inicio_aquisitivo + make_interval(months => v_meses))::date > v_limite THEN
    v_meses := v_meses - 1;
  END IF;
  v_resto := v_limite - (p_inicio_aquisitivo + make_interval(months => v_meses))::date;

  IF v_resto > v_fracao THEN
    v_meses := v_meses + 1;
  END IF;
  RETURN LEAST(v_meses, 12);
END;
$$;

-- IRRF calculado em separado (13º, férias, verbas do mês na rescisão).
-- Tabela progressiva do seed (tax_table_version) e redutor da Lei 15.270/2025.
-- O critério de aferição do redutor (rendimento bruto ou base após deduções) é parâmetro a_validar.
-- Tabela sem dedução por dependente cadastrada: falha, não usa valor de reserva (achado V7).
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

-- ===========================================================================
-- 3. calc_inss: faixas contínuas (V5/C3)
--    O piso de cada faixa passa a ser o limite superior da faixa anterior. Antes usava o
--    limite_inferior do seed (1621.01, 2902.85, 4354.28) e perdia 1 centavo de base por faixa.
--    Método de arredondamento: soma exata das faixas, arredondada no final (método A dos pareceres;
--    a escolha entre A e B segue A VALIDAR NA FONTE).
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

-- ===========================================================================
-- 4. calc_13o
--    p_parcela: 1 = adiantamento; 2 = quitação; 3 = ajuste de variáveis (até 10 de janeiro).
--    p_competencia: data do pagamento. O ano do 13º é o da data, salvo p_ano; no ajuste pago em
--    janeiro, é o ano anterior.
--    Variáveis: no adiantamento, p_media_variaveis (média já apurada; o divisor é A VALIDAR);
--    na quitação e no ajuste, p_soma_variaveis dividida pelo parâmetro (11 e 12).
-- ===========================================================================
DROP FUNCTION IF EXISTS folha.calc_13o(uuid, date, integer);
DROP FUNCTION IF EXISTS folha.calc_13o(uuid, date, integer, numeric, numeric, integer);

CREATE OR REPLACE FUNCTION folha.calc_13o(
  p_contract_id uuid,
  p_competencia date DEFAULT CURRENT_DATE,
  p_parcela integer DEFAULT 2,
  p_adiantamento_pago numeric DEFAULT 0,
  p_media_variaveis numeric DEFAULT 0,
  p_num_dependentes integer DEFAULT 0,
  p_soma_variaveis numeric DEFAULT 0,
  p_bruto_quitado numeric DEFAULT NULL,
  p_inss_retido numeric DEFAULT 0,
  p_irrf_retido numeric DEFAULT 0,
  p_ano integer DEFAULT NULL
) RETURNS TABLE (
  valor_bruto numeric,
  inss numeric,
  irrf numeric,
  valor_liquido numeric,
  meses_proporcionais integer,
  base_calculo numeric,
  fgts numeric,
  adiantamento_compensado numeric,
  diferenca_ajuste numeric,
  pendencias_validacao text[]
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_salario numeric;
  v_admissao date;
  v_demissao date;
  v_regime text;
  v_ano integer;
  v_avos integer;
  v_rem numeric;
  v_bruto numeric;
  v_inss_total numeric;
  v_irrf_total numeric;
  v_adiant numeric := COALESCE(p_adiantamento_pago, 0);
  v_mes integer;
  v_pend text[] := ARRAY[]::text[];
  v_chaves text[] := ARRAY[]::text[];
BEGIN
  IF p_competencia IS NULL THEN
    RAISE EXCEPTION 'calc_13o: data de pagamento obrigatória';
  END IF;
  IF p_parcela IS NULL OR p_parcela NOT IN (1, 2, 3) THEN
    RAISE EXCEPTION 'calc_13o: p_parcela deve ser 1 (adiantamento), 2 (quitação) ou 3 (ajuste de variáveis); recebido %', p_parcela;
  END IF;

  SELECT c.salario_base, c.data_admissao, c.data_demissao, c.regime_trabalho
    INTO v_salario, v_admissao, v_demissao, v_regime
    FROM folha.employment_contract c
   WHERE c.contract_id = p_contract_id
     AND c.account_id = folha.current_account_id();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Contrato % não encontrado', p_contract_id;
  END IF;
  IF v_regime NOT IN ('clt', 'aprendiz') THEN
    RAISE EXCEPTION 'Regime % não tem direito a 13º salário', v_regime;
  END IF;

  v_mes := EXTRACT(MONTH FROM p_competencia)::integer;
  v_ano := COALESCE(
    p_ano,
    CASE WHEN p_parcela = 3
              AND v_mes = folha.get_param('ajuste_variaveis_data_limite_mes', p_competencia)::integer
         THEN EXTRACT(YEAR FROM p_competencia)::integer - 1
         ELSE EXTRACT(YEAR FROM p_competencia)::integer END);

  v_avos := folha.avos_13o(v_ano, v_admissao, v_demissao);

  IF p_parcela = 1 THEN
    -- Adiantamento: metade, sem INSS e sem IRRF; FGTS no mês do pagamento.
    v_rem := v_salario + COALESCE(p_media_variaveis, 0);
    v_bruto := ROUND(v_rem * v_avos / 12.0, 2);
    valor_bruto := ROUND(v_rem * v_avos / 12.0 * folha.get_param('adiantamento_13o_fracao', p_competencia), 2);
    inss := 0;
    irrf := 0;
    adiantamento_compensado := 0;
    diferenca_ajuste := 0;
    fgts := (SELECT f.fgts_deposito FROM folha.calc_fgts(valor_bruto, v_regime, p_competencia) f);
    valor_liquido := valor_bruto;
    IF v_mes < folha.get_param('adiantamento_13o_mes_inicio', p_competencia)
       OR v_mes > folha.get_param('adiantamento_13o_mes_fim', p_competencia) THEN
      v_pend := array_append(v_pend, 'pendencia:adiantamento_fora_da_janela_fev_nov');
    END IF;
    IF COALESCE(p_media_variaveis, 0) <> 0 THEN
      v_pend := array_append(v_pend, 'a_validar:divisor_media_variaveis_adiantamento');
    END IF;

  ELSIF p_parcela = 2 THEN
    -- Quitação: INSS e IRRF em separado sobre o bruto total; compensa o adiantamento.
    v_rem := v_salario + COALESCE(p_soma_variaveis, 0) / folha.get_param('divisor_variaveis_quitacao', p_competencia);
    v_bruto := ROUND(v_rem * v_avos / 12.0, 2);
    valor_bruto := v_bruto;
    inss := (SELECT i.valor_inss FROM folha.calc_inss(v_bruto, p_competencia) i);
    irrf := folha.calc_irrf_separado(v_bruto, inss, p_num_dependentes, p_competencia);
    adiantamento_compensado := v_adiant;
    diferenca_ajuste := 0;
    valor_liquido := v_bruto - v_adiant - inss - irrf;
    IF valor_liquido < 0 THEN
      RAISE EXCEPTION 'calc_13o: líquido negativo na quitação (bruto %, adiantamento %, INSS %, IRRF %); o excedente do adiantamento exige tratamento manual',
        v_bruto, v_adiant, inss, irrf;
    END IF;
    fgts := (SELECT f.fgts_deposito FROM folha.calc_fgts(GREATEST(v_bruto - v_adiant, 0), v_regime, p_competencia) f);
    v_chaves := v_chaves || ARRAY['irrf_redutor_referencia_bruto', 'irrf_redutor_coef_a', 'irrf_redutor_coef_b'];
    IF v_mes <> 12 THEN
      v_pend := array_append(v_pend, 'pendencia:quitacao_fora_de_dezembro_conferir_ano_de_referencia');
    ELSIF EXTRACT(DAY FROM p_competencia) > folha.get_param('quitacao_13o_data_limite', p_competencia) THEN
      v_pend := array_append(v_pend, 'pendencia:quitacao_depois_do_dia_limite');
    END IF;
    IF COALESCE(p_soma_variaveis, 0) <> 0 THEN
      v_chaves := v_chaves || ARRAY['divisor_variaveis_quitacao'];
    END IF;

  ELSE
    -- Ajuste de variáveis: 1/12 do total do ano; paga ou compensa a diferença.
    IF p_bruto_quitado IS NULL THEN
      RAISE EXCEPTION 'calc_13o: o ajuste de variáveis exige o bruto já quitado (p_bruto_quitado)';
    END IF;
    v_rem := v_salario + COALESCE(p_soma_variaveis, 0) / folha.get_param('divisor_variaveis_ajuste', p_competencia);
    v_bruto := ROUND(v_rem * v_avos / 12.0, 2);
    valor_bruto := v_bruto;
    diferenca_ajuste := v_bruto - p_bruto_quitado;
    v_inss_total := (SELECT i.valor_inss FROM folha.calc_inss(v_bruto, p_competencia) i);
    v_irrf_total := folha.calc_irrf_separado(v_bruto, v_inss_total, p_num_dependentes, p_competencia);
    inss := v_inss_total - COALESCE(p_inss_retido, 0);
    irrf := v_irrf_total - COALESCE(p_irrf_retido, 0);
    adiantamento_compensado := 0;
    fgts := (SELECT f.fgts_deposito FROM folha.calc_fgts(GREATEST(diferenca_ajuste, 0), v_regime, p_competencia) f);
    valor_liquido := diferenca_ajuste - inss - irrf;
    IF diferenca_ajuste < 0 THEN
      v_pend := array_append(v_pend, 'pendencia:ajuste_negativo_a_compensar');
    END IF;
    IF v_mes <> folha.get_param('ajuste_variaveis_data_limite_mes', p_competencia)
       OR EXTRACT(DAY FROM p_competencia) > folha.get_param('ajuste_variaveis_data_limite_dia', p_competencia) THEN
      v_pend := array_append(v_pend, 'pendencia:ajuste_de_variaveis_fora_do_prazo');
    END IF;
    v_chaves := v_chaves || ARRAY['divisor_variaveis_ajuste', 'irrf_redutor_referencia_bruto',
                                  'irrf_redutor_coef_a', 'irrf_redutor_coef_b'];
  END IF;

  meses_proporcionais := v_avos;
  base_calculo := v_bruto;
  pendencias_validacao := v_pend || folha.params_a_validar(v_chaves, p_competencia);
  RETURN NEXT;
END;
$$;

-- ===========================================================================
-- 5. calc_ferias (férias gozadas)
--    Exige o início do período aquisitivo: o direito não se infere do tempo de casa.
--    Recusa período aquisitivo incompleto (proporcionais só existem na rescisão).
--    INSS e FGTS só sobre férias gozadas + terço; abono e dobra ficam fora.
--    O INSS do recibo é provisório: a folha do mês de gozo reapura (pendência devolvida).
-- ===========================================================================
DROP FUNCTION IF EXISTS folha.calc_ferias(uuid, date);
DROP FUNCTION IF EXISTS folha.calc_ferias(uuid, date, integer, integer, integer, date, date, numeric);

CREATE OR REPLACE FUNCTION folha.calc_ferias(
  p_contract_id uuid,
  p_inicio_gozo date,
  p_periodo_aquisitivo_inicio date,
  p_dias_gozo integer DEFAULT NULL,
  p_dias_abono integer DEFAULT 0,
  p_faltas_injustificadas integer DEFAULT 0,
  p_periodo_concessivo_fim date DEFAULT NULL,
  p_remuneracao numeric DEFAULT NULL,
  p_num_dependentes integer DEFAULT 0
) RETURNS TABLE (
  valor_ferias numeric,
  valor_um_terco numeric,
  valor_abono numeric,
  terco_abono numeric,
  valor_dobra numeric,
  total_ferias numeric,
  dias_direito integer,
  dias_gozo integer,
  dias_abono integer,
  dias_abono_max integer,
  dias_dobra integer,
  base_calculo numeric,
  base_inss numeric,
  inss numeric,
  irrf numeric,
  fgts numeric,
  valor_liquido numeric,
  data_limite_pagamento date,
  tabela_hash text,
  pendencias_validacao text[]
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_salario numeric;
  v_admissao date;
  v_regime text;
  v_rem numeric;
  v_pa_fim date;
  v_pc_fim date;
  v_faltas integer := COALESCE(p_faltas_injustificadas, 0);
  v_direito integer;
  v_gozo integer;
  v_abono integer := COALESCE(p_dias_abono, 0);
  v_abono_max integer;
  v_dobra_dias integer;
  v_div_terco numeric;
  v_fim_gozo date;
  v_base_irrf numeric;
  v_pend text[] := ARRAY[]::text[];
BEGIN
  IF p_inicio_gozo IS NULL THEN
    RAISE EXCEPTION 'calc_ferias: data de início do gozo obrigatória';
  END IF;
  IF p_periodo_aquisitivo_inicio IS NULL THEN
    RAISE EXCEPTION 'calc_ferias: início do período aquisitivo obrigatório (o direito não se infere do tempo de casa)';
  END IF;
  IF v_faltas < 0 OR v_abono < 0 THEN
    RAISE EXCEPTION 'calc_ferias: faltas e dias de abono não podem ser negativos';
  END IF;

  SELECT c.salario_base, c.data_admissao, c.regime_trabalho
    INTO v_salario, v_admissao, v_regime
    FROM folha.employment_contract c
   WHERE c.contract_id = p_contract_id
     AND c.account_id = folha.current_account_id();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Contrato % não encontrado', p_contract_id;
  END IF;
  IF v_regime NOT IN ('clt', 'aprendiz') THEN
    RAISE EXCEPTION 'Regime % não tem direito a férias da CLT', v_regime;
  END IF;
  IF p_periodo_aquisitivo_inicio < v_admissao THEN
    RAISE EXCEPTION 'calc_ferias: período aquisitivo (%) anterior à admissão (%)', p_periodo_aquisitivo_inicio, v_admissao;
  END IF;

  v_pa_fim := (p_periodo_aquisitivo_inicio + INTERVAL '12 months' - INTERVAL '1 day')::date;
  IF p_inicio_gozo <= v_pa_fim THEN
    RAISE EXCEPTION 'calc_ferias: período aquisitivo incompleto (termina em %); férias proporcionais só na rescisão', v_pa_fim;
  END IF;
  v_pc_fim := COALESCE(
    p_periodo_concessivo_fim,
    (v_pa_fim + make_interval(months => folha.get_param('ferias_periodo_concessivo_meses', p_inicio_gozo)::integer))::date);

  v_direito := CASE
    WHEN v_faltas <= 5  THEN folha.get_param('ferias_escala_faltas_0_5', p_inicio_gozo)::integer
    WHEN v_faltas <= 14 THEN folha.get_param('ferias_escala_faltas_6_14', p_inicio_gozo)::integer
    WHEN v_faltas <= 23 THEN folha.get_param('ferias_escala_faltas_15_23', p_inicio_gozo)::integer
    WHEN v_faltas <= 32 THEN folha.get_param('ferias_escala_faltas_24_32', p_inicio_gozo)::integer
    ELSE 0
  END;
  IF v_direito = 0 THEN
    RAISE EXCEPTION 'calc_ferias: % faltas injustificadas no período aquisitivo: sem direito a férias', v_faltas;
  END IF;

  v_abono_max := FLOOR(v_direito / folha.get_param('ferias_abono_divisor_max', p_inicio_gozo))::integer;
  IF v_abono > v_abono_max THEN
    RAISE EXCEPTION 'calc_ferias: abono de % dias excede o máximo de % (1/3 do direito de % dias)', v_abono, v_abono_max, v_direito;
  END IF;

  v_gozo := COALESCE(p_dias_gozo, v_direito - v_abono);
  IF v_gozo <= 0 THEN
    RAISE EXCEPTION 'calc_ferias: dias de gozo devem ser positivos';
  END IF;
  IF v_gozo + v_abono > v_direito THEN
    RAISE EXCEPTION 'calc_ferias: gozo (%) + abono (%) excede o direito de % dias', v_gozo, v_abono, v_direito;
  END IF;

  v_rem := COALESCE(p_remuneracao, v_salario);
  v_div_terco := folha.get_param('ferias_terco_divisor', p_inicio_gozo);
  v_fim_gozo := p_inicio_gozo + v_gozo - 1;
  -- Só os dias gozados depois do fim do período concessivo são dobrados (Súmula 81 do TST).
  v_dobra_dias := GREATEST(0, LEAST(v_gozo, v_fim_gozo - v_pc_fim));

  valor_ferias := ROUND(v_rem * v_gozo / 30.0, 2);
  valor_um_terco := ROUND(valor_ferias / v_div_terco, 2);
  valor_abono := ROUND(v_rem * v_abono / 30.0, 2);
  terco_abono := ROUND(valor_abono / v_div_terco, 2);
  valor_dobra := ROUND((v_rem * v_dobra_dias / 30.0) * (1 + 1 / v_div_terco), 2);
  -- Soma das parcelas já arredondadas (achado F9).
  total_ferias := valor_ferias + valor_um_terco + valor_abono + terco_abono + valor_dobra;

  base_inss := valor_ferias + valor_um_terco;
  SELECT i.valor_inss, i.tabela_hash INTO inss, tabela_hash
    FROM folha.calc_inss(base_inss, p_inicio_gozo) i;

  v_base_irrf := base_inss
    + CASE WHEN folha.get_param('irrf_abono_pecuniario_incide', p_inicio_gozo) = 1 THEN valor_abono + terco_abono ELSE 0 END
    + CASE WHEN folha.get_param('irrf_dobra_ferias_incide', p_inicio_gozo) = 1 THEN valor_dobra ELSE 0 END;
  irrf := folha.calc_irrf_separado(v_base_irrf, inss, p_num_dependentes, p_inicio_gozo);

  fgts := (SELECT f.fgts_deposito FROM folha.calc_fgts(base_inss, v_regime, p_inicio_gozo) f);
  valor_liquido := total_ferias - inss - irrf;

  data_limite_pagamento := p_inicio_gozo - folha.get_param('ferias_antecedencia_pagamento_dias', p_inicio_gozo)::integer;
  IF EXTRACT(ISODOW FROM data_limite_pagamento) IN (6, 7) THEN
    v_pend := array_append(v_pend, 'a_validar:data_limite_pagamento_em_dia_nao_util_antecipar');
  END IF;

  dias_direito := v_direito;
  dias_gozo := v_gozo;
  dias_abono := v_abono;
  dias_abono_max := v_abono_max;
  dias_dobra := v_dobra_dias;
  base_calculo := v_rem;

  v_pend := array_append(v_pend, 'pendencia:inss_do_recibo_provisorio_reapurar_na_folha_do_mes_de_gozo');
  IF v_dobra_dias > 0 THEN
    v_pend := array_append(v_pend, 'pendencia:dobra_art_137_aplicada_sobre_' || v_dobra_dias || '_dias');
  END IF;
  IF v_gozo + v_abono < v_direito THEN
    -- O motor não conhece os outros períodos de gozo: frações mínimas e saldo ficam com o responsável.
    v_pend := array_append(v_pend, 'pendencia:gozo_fracionado_conferir_fracoes_minimas_e_saldo_de_'
                                   || (v_direito - v_gozo - v_abono) || '_dias');
  END IF;
  pendencias_validacao := v_pend || folha.params_a_validar(
    ARRAY['irrf_redutor_referencia_bruto', 'irrf_redutor_coef_a', 'irrf_redutor_coef_b']
    || CASE WHEN v_abono > 0 THEN ARRAY['irrf_abono_pecuniario_incide'] ELSE ARRAY[]::text[] END
    || CASE WHEN v_dobra_dias > 0 THEN ARRAY['irrf_dobra_ferias_incide'] ELSE ARRAY[]::text[] END,
    p_inicio_gozo);
  RETURN NEXT;
END;
$$;

-- ===========================================================================
-- 6. calc_rescisao
--    p_data_demissao = último dia trabalhado. p_motivo é obrigatório e validado.
--    Motivos: sem_justa_causa, pedido_demissao, justa_causa, acordo_484a, termino_prazo,
--             antecipacao_empregador, antecipacao_empregado, falecimento.
--    Aviso:   indenizado_empregador, trabalhado, descontado_empregado, dispensado, nao_aplicavel.
--    Férias vencidas vêm do inventário informado (períodos simples e em dobro); não se inferem
--    do tempo de casa. A multa do FGTS depende da base do extrato para fins rescisórios e é
--    devolvida em campo próprio, fora dos proventos e do líquido.
--    Contrato a prazo com cláusula assecuratória exercida (CLT art. 481): usar sem_justa_causa
--    ou pedido_demissao.
-- ===========================================================================
DROP FUNCTION IF EXISTS folha.calc_rescisao(uuid, date, text);
DROP FUNCTION IF EXISTS folha.calc_rescisao(uuid, date, text, text, integer, numeric, numeric, integer, numeric, numeric);

CREATE OR REPLACE FUNCTION folha.calc_rescisao(
  p_contract_id uuid,
  p_data_demissao date,
  p_motivo text,
  p_aviso_modo text DEFAULT 'nao_aplicavel',
  p_data_comunicacao date DEFAULT NULL,
  p_periodo_aquisitivo_inicio date DEFAULT NULL,
  p_periodos_vencidos integer DEFAULT 0,
  p_periodos_vencidos_dobro integer DEFAULT 0,
  p_fgts_base_extrato numeric DEFAULT NULL,
  p_data_termo date DEFAULT NULL,
  p_prejuizo_art480 numeric DEFAULT NULL,
  p_projecao_dias_acordo integer DEFAULT NULL,
  p_num_dependentes integer DEFAULT 0,
  p_adiantamento_13o_pago numeric DEFAULT 0,
  p_remuneracao numeric DEFAULT NULL,
  p_dias_saldo integer DEFAULT NULL
) RETURNS TABLE (
  saldo_salario numeric,
  dias_saldo integer,
  aviso_previo_indenizado numeric,
  dias_aviso integer,
  data_projetada date,
  decimo_terceiro_proporcional numeric,
  avos_13 integer,
  avos_13_projecao integer,
  ferias_vencidas numeric,
  terco_ferias_vencidas numeric,
  ferias_proporcionais numeric,
  terco_ferias_proporcionais numeric,
  avos_ferias_proporcionais integer,
  indenizacao_479 numeric,
  total_proventos numeric,
  inss_mensal numeric,
  inss_13 numeric,
  irrf_mensal numeric,
  irrf_13 numeric,
  desconto_aviso numeric,
  desconto_art480 numeric,
  desconto_adiantamento_13 numeric,
  total_descontos numeric,
  liquido_rescisao numeric,
  fgts_deposito_rescisao numeric,
  multa_fgts numeric,
  data_limite_pagamento date,
  estado text,
  pendencias_validacao text[]
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_salario numeric;
  v_admissao date;
  v_demissao_cad date;
  v_regime text;
  v_rem numeric;
  v_ult date := p_data_demissao;
  v_com date;
  v_divisor numeric;
  v_div_terco numeric;
  -- matriz motivo x verba
  v_tem_13 boolean := true;
  v_tem_fer_prop boolean := true;
  v_aviso_empregador boolean := false;
  v_aviso_empregado boolean := false;
  v_prazo boolean := false;
  v_multa_pct numeric := 0;
  v_aviso_frac numeric := 1;
  -- aviso
  v_anos integer;
  v_dias_legais integer;
  v_dias_ind integer := 0;
  v_dias_proj integer := 0;
  v_aviso_ind numeric := 0;
  v_fim date;
  -- verbas
  v_ini_mes date;
  v_fim_mes date;
  v_ini_saldo date;
  v_dias_saldo integer;
  v_saldo numeric;
  v_avos_13 integer := 0;
  v_avos_13_sem_proj integer := 0;
  v_13 numeric := 0;
  v_base_inss_13 numeric := 0;
  v_venc integer := COALESCE(p_periodos_vencidos, 0);
  v_venc_dobro integer := COALESCE(p_periodos_vencidos_dobro, 0);
  v_fer_venc numeric := 0;
  v_terco_venc numeric := 0;
  v_pa date;
  v_avos_fer integer := 0;
  v_fer_prop numeric := 0;
  v_terco_prop numeric := 0;
  v_ind_479 numeric := 0;
  v_teto_480 numeric := 0;
  -- descontos
  v_base_inss_mes numeric;
  v_adiant numeric := COALESCE(p_adiantamento_13o_pago, 0);
  v_comp_13 numeric := 0;
  v_excedente_adiant numeric := 0;
  v_desc_aviso numeric := 0;
  v_desc_480 numeric := 0;
  v_limite numeric;
  v_saldo_limite numeric;
  v_pedido numeric;
  -- FGTS
  v_fgts_dep numeric;
  v_pend text[] := ARRAY[]::text[];
  v_chaves text[] := ARRAY['divisor_saldo_salario', 'prazo_pagamento_rescisao_dias',
                           'irrf_redutor_referencia_bruto', 'irrf_redutor_coef_a', 'irrf_redutor_coef_b'];
BEGIN
  -- 1. Motivo (validado antes de qualquer leitura)
  IF p_motivo IS NULL OR btrim(p_motivo) = '' THEN
    RAISE EXCEPTION 'calc_rescisao: motivo de rescisão obrigatório';
  END IF;
  IF p_data_demissao IS NULL THEN
    RAISE EXCEPTION 'calc_rescisao: data do último dia trabalhado obrigatória';
  END IF;

  CASE p_motivo
    WHEN 'sem_justa_causa' THEN
      v_aviso_empregador := true;
      v_multa_pct := folha.get_param('multa_fgts_dispensa_sem_jc', v_ult);
    WHEN 'pedido_demissao' THEN
      v_aviso_empregado := true;
    WHEN 'justa_causa' THEN
      v_tem_13 := false;
      v_tem_fer_prop := false;
    WHEN 'acordo_484a' THEN
      v_aviso_empregador := true;
      v_aviso_frac := folha.get_param('acordo_484a_fracao_aviso', v_ult);
      v_multa_pct := folha.get_param('multa_fgts_acordo_484a', v_ult);
    WHEN 'termino_prazo' THEN
      v_prazo := true;
    WHEN 'antecipacao_empregador' THEN
      v_prazo := true;
      v_multa_pct := folha.get_param('multa_fgts_dispensa_sem_jc', v_ult);
    WHEN 'antecipacao_empregado' THEN
      v_prazo := true;
    WHEN 'falecimento' THEN
      NULL;
    ELSE
      RAISE EXCEPTION 'calc_rescisao: motivo de rescisão desconhecido: %', p_motivo;
  END CASE;

  -- 2. Contrato, sempre da conta do chamador
  SELECT c.salario_base, c.data_admissao, c.data_demissao, c.regime_trabalho
    INTO v_salario, v_admissao, v_demissao_cad, v_regime
    FROM folha.employment_contract c
   WHERE c.contract_id = p_contract_id
     AND c.account_id = folha.current_account_id();

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Contrato % não encontrado', p_contract_id;
  END IF;
  IF v_regime NOT IN ('clt', 'aprendiz') THEN
    RAISE EXCEPTION 'Regime % não tem rescisão pela CLT', v_regime;
  END IF;
  IF v_demissao_cad IS NOT NULL AND v_demissao_cad <> v_ult THEN
    RAISE EXCEPTION 'calc_rescisao: contrato já encerrado em %', v_demissao_cad;
  END IF;

  v_com := COALESCE(p_data_comunicacao, v_ult);
  IF v_ult < v_admissao THEN
    RAISE EXCEPTION 'calc_rescisao: último dia trabalhado (%) anterior à admissão (%)', v_ult, v_admissao;
  END IF;
  IF v_com < v_admissao OR v_com > v_ult THEN
    RAISE EXCEPTION 'calc_rescisao: data da comunicação (%) fora do intervalo entre a admissão (%) e o último dia (%)', v_com, v_admissao, v_ult;
  END IF;
  IF v_venc < 0 OR v_venc_dobro < 0 OR v_adiant < 0 THEN
    RAISE EXCEPTION 'calc_rescisao: períodos vencidos e adiantamento não podem ser negativos';
  END IF;

  -- 3. Modo do aviso compatível com o motivo
  IF p_aviso_modo IS NULL OR p_aviso_modo NOT IN
     ('indenizado_empregador', 'trabalhado', 'descontado_empregado', 'dispensado', 'nao_aplicavel') THEN
    RAISE EXCEPTION 'calc_rescisao: modo de aviso desconhecido: %', p_aviso_modo;
  END IF;
  IF (v_aviso_empregador AND p_aviso_modo NOT IN ('indenizado_empregador', 'trabalhado'))
     OR (v_aviso_empregado AND p_aviso_modo NOT IN ('trabalhado', 'descontado_empregado', 'dispensado'))
     OR (NOT v_aviso_empregador AND NOT v_aviso_empregado AND p_aviso_modo <> 'nao_aplicavel') THEN
    RAISE EXCEPTION 'calc_rescisao: modo de aviso % incompatível com o motivo %', p_aviso_modo, p_motivo;
  END IF;

  -- 4. Contrato a prazo: exige a data do termo
  IF v_prazo THEN
    IF p_data_termo IS NULL THEN
      RAISE EXCEPTION 'calc_rescisao: motivo % exige a data do termo do contrato', p_motivo;
    END IF;
    IF v_ult > p_data_termo THEN
      RAISE EXCEPTION 'calc_rescisao: último dia (%) posterior ao termo (%)', v_ult, p_data_termo;
    END IF;
    IF p_motivo = 'termino_prazo' AND v_ult <> p_data_termo THEN
      RAISE EXCEPTION 'calc_rescisao: no término normal o último dia (%) deve ser o termo (%)', v_ult, p_data_termo;
    END IF;
    IF p_motivo <> 'termino_prazo' AND v_ult = p_data_termo THEN
      RAISE EXCEPTION 'calc_rescisao: antecipação exige último dia anterior ao termo (%)', p_data_termo;
    END IF;
  END IF;

  v_rem := COALESCE(p_remuneracao, v_salario);
  v_divisor := folha.get_param('divisor_saldo_salario', v_ult);
  v_div_terco := folha.get_param('ferias_terco_divisor', v_ult);

  -- 5. Aviso prévio
  v_anos := EXTRACT(YEAR FROM age(v_com, v_admissao))::integer;
  v_dias_legais := LEAST(
    folha.get_param('aviso_previo_base_dias', v_ult)::integer
      + folha.get_param('aviso_previo_dias_por_ano', v_ult)::integer * v_anos,
    folha.get_param('aviso_previo_teto_dias', v_ult)::integer);

  IF v_aviso_empregador THEN
    dias_aviso := v_dias_legais;
    v_chaves := v_chaves || ARRAY['aviso_previo_dias_por_ano'];
    IF p_aviso_modo = 'indenizado_empregador' THEN
      v_dias_ind := v_dias_legais;
      v_aviso_ind := ROUND(v_rem / v_divisor * v_dias_ind * v_aviso_frac, 2);
      IF p_motivo = 'acordo_484a' THEN
        IF p_projecao_dias_acordo IS NULL THEN
          RAISE EXCEPTION 'calc_rescisao: acordo com aviso indenizado exige os dias de projeção (p_projecao_dias_acordo)';
        END IF;
        IF p_projecao_dias_acordo < 0 OR p_projecao_dias_acordo > v_dias_legais THEN
          RAISE EXCEPTION 'calc_rescisao: projeção do acordo (%) fora do intervalo de 0 a % dias', p_projecao_dias_acordo, v_dias_legais;
        END IF;
        v_dias_proj := p_projecao_dias_acordo;
        v_pend := array_append(v_pend, 'a_validar:projecao_do_aviso_no_acordo_informada_pelo_responsavel');
      ELSE
        v_dias_proj := v_dias_ind;
      END IF;
    END IF;
  ELSIF v_aviso_empregado THEN
    -- No pedido de demissão o aviso é de 30 dias (proporcionalidade só a favor do empregado: a validar).
    dias_aviso := folha.get_param('aviso_previo_base_dias', v_ult)::integer;
    IF p_aviso_modo = 'descontado_empregado' THEN
      v_desc_aviso := ROUND(v_rem / v_divisor * dias_aviso, 2);
    END IF;
  ELSE
    dias_aviso := 0;
  END IF;

  v_fim := v_ult + v_dias_proj;
  data_projetada := v_fim;

  -- 6. Saldo de salário
  v_ini_mes := date_trunc('month', v_ult)::date;
  v_fim_mes := (v_ini_mes + INTERVAL '1 month' - INTERVAL '1 day')::date;
  v_ini_saldo := GREATEST(v_ini_mes, v_admissao);
  IF p_dias_saldo IS NOT NULL THEN
    IF p_dias_saldo < 0 OR p_dias_saldo > v_divisor THEN
      RAISE EXCEPTION 'calc_rescisao: dias de saldo (%) fora do intervalo de 0 a %', p_dias_saldo, v_divisor;
    END IF;
    v_dias_saldo := p_dias_saldo;
  ELSIF v_ini_saldo = v_ini_mes AND v_ult = v_fim_mes THEN
    v_dias_saldo := v_divisor::integer;
  ELSE
    v_dias_saldo := LEAST(v_ult - v_ini_saldo + 1, v_divisor::integer);
  END IF;
  v_saldo := ROUND(v_rem / v_divisor * v_dias_saldo, 2);

  -- 7. 13º proporcional (até a data projetada)
  IF v_tem_13 THEN
    v_avos_13_sem_proj := folha.avos_13o(EXTRACT(YEAR FROM v_ult)::integer, v_admissao, v_ult);
    IF EXTRACT(YEAR FROM v_fim) = EXTRACT(YEAR FROM v_ult) THEN
      v_avos_13 := folha.avos_13o(EXTRACT(YEAR FROM v_ult)::integer, v_admissao, v_fim);
    ELSE
      -- A projeção do aviso atravessa o ano: soma os avos dos dois anos e devolve pendência.
      v_avos_13 := folha.avos_13o(EXTRACT(YEAR FROM v_ult)::integer, v_admissao,
                                   make_date(EXTRACT(YEAR FROM v_ult)::integer, 12, 31))
                 + folha.avos_13o(EXTRACT(YEAR FROM v_fim)::integer, v_admissao, v_fim);
      v_pend := array_append(v_pend, 'pendencia:projecao_do_aviso_atravessa_o_ano_separar_13o_por_ano');
    END IF;
    v_13 := ROUND(v_rem * v_avos_13 / 12.0, 2);
    IF v_avos_13 > v_avos_13_sem_proj THEN
      v_chaves := v_chaves || ARRAY['inss_projecao_aviso_incide'];
    END IF;
    v_base_inss_13 := CASE
      WHEN folha.get_param('inss_projecao_aviso_incide', v_ult) = 1 THEN v_13
      ELSE ROUND(v_rem * v_avos_13_sem_proj / 12.0, 2) END;
  END IF;

  -- 8. Férias vencidas (inventário informado; devidas em qualquer motivo)
  v_fer_venc := ROUND(v_rem * (v_venc + 2 * v_venc_dobro), 2);

  -- 9. Férias proporcionais do período aquisitivo em curso
  v_pa := p_periodo_aquisitivo_inicio;
  IF v_pa IS NULL THEN
    IF (v_admissao + INTERVAL '12 months')::date > v_fim + 1 THEN
      v_pa := v_admissao;   -- primeiro período aquisitivo: não há ambiguidade
    ELSIF v_tem_fer_prop THEN
      RAISE EXCEPTION 'calc_rescisao: contrato com 12 meses ou mais exige o início do período aquisitivo em curso';
    END IF;
  END IF;
  IF v_pa IS NOT NULL THEN
    IF v_pa < v_admissao OR v_pa > v_fim THEN
      RAISE EXCEPTION 'calc_rescisao: início do período aquisitivo (%) fora do contrato (% a %)', v_pa, v_admissao, v_fim;
    END IF;
    -- Período que se completa até a data final vira adquirido em qualquer motivo (CLT art. 146,
    -- caput) e não se repete nas proporcionais.
    WHILE (v_pa + INTERVAL '12 months')::date <= v_fim + 1 LOOP
      v_fer_venc := v_fer_venc + v_rem;
      v_pa := (v_pa + INTERVAL '12 months')::date;
      v_pend := array_append(v_pend, 'pendencia:periodo_aquisitivo_completado_ate_a_data_final_reclassificado_como_vencido');
    END LOOP;
    IF v_tem_fer_prop THEN
      v_avos_fer := folha.avos_ferias(v_pa, v_fim);
      v_fer_prop := ROUND(v_rem * v_avos_fer / 12.0, 2);
      v_terco_prop := ROUND(v_fer_prop / v_div_terco, 2);
    END IF;
  END IF;
  v_terco_venc := ROUND(v_fer_venc / v_div_terco, 2);

  -- 10. Contrato a prazo: indenização do art. 479 e desconto do art. 480
  IF v_regime = 'aprendiz' AND p_motivo IN ('antecipacao_empregador', 'antecipacao_empregado') THEN
    -- Os pareceres não tratam a extinção antecipada do contrato de aprendizagem.
    v_pend := array_append(v_pend, 'pendencia:aprendiz_aplicacao_dos_arts_479_e_480_a_validar_na_fonte');
  END IF;
  IF p_motivo IN ('antecipacao_empregador', 'antecipacao_empregado') THEN
    v_teto_480 := ROUND(v_rem / v_divisor * (p_data_termo - v_ult)
                        * folha.get_param('indenizacao_art479_fracao', v_ult), 2);
    IF p_motivo = 'antecipacao_empregador' THEN
      v_ind_479 := v_teto_480;
    ELSIF p_prejuizo_art480 IS NULL THEN
      v_pend := array_append(v_pend, 'pendencia:prejuizo_art_480_nao_informado_desconto_zero');
    ELSIF p_prejuizo_art480 < 0 THEN
      RAISE EXCEPTION 'calc_rescisao: prejuízo do art. 480 não pode ser negativo';
    ELSE
      v_desc_480 := LEAST(p_prejuizo_art480, v_teto_480);
    END IF;
  END IF;

  -- 11. INSS e IRRF (mês e 13º em separado)
  v_base_inss_mes := v_saldo
    + CASE WHEN folha.get_param('inss_aviso_indenizado_incide', v_ult) = 1 THEN v_aviso_ind ELSE 0 END;
  IF v_aviso_ind > 0 THEN
    v_chaves := v_chaves || ARRAY['inss_aviso_indenizado_incide'];
  END IF;
  inss_mensal := (SELECT i.valor_inss FROM folha.calc_inss(v_base_inss_mes, v_ult) i);
  inss_13 := (SELECT i.valor_inss FROM folha.calc_inss(v_base_inss_13, v_ult) i);
  -- Aviso indenizado é isento de IRRF (Lei 7.713/1988 art. 6º, V); férias indenizadas não são tributadas.
  irrf_mensal := folha.calc_irrf_separado(v_saldo, inss_mensal, p_num_dependentes, v_ult);
  irrf_13 := folha.calc_irrf_separado(v_13, inss_13, p_num_dependentes, v_ult);

  -- 12. Compensações. O adiantamento do 13º compensa primeiro o 13º devido (Decreto 10.854/2021
  --     art. 82, parágrafo único); o que sobrar, o aviso não cumprido e o art. 480 respeitam o
  --     limite do art. 477 § 5º. O excedente não é descontado e vira pendência.
  v_comp_13 := LEAST(v_adiant, v_13);
  v_excedente_adiant := v_adiant - v_comp_13;
  v_limite := v_rem * folha.get_param('limite_compensacao_trct_salarios', v_ult);
  v_saldo_limite := v_limite;
  v_pedido := v_desc_aviso + v_desc_480 + v_excedente_adiant;
  v_desc_aviso := LEAST(v_desc_aviso, v_saldo_limite);
  v_saldo_limite := v_saldo_limite - v_desc_aviso;
  v_desc_480 := LEAST(v_desc_480, v_saldo_limite);
  v_saldo_limite := v_saldo_limite - v_desc_480;
  v_excedente_adiant := LEAST(v_excedente_adiant, v_saldo_limite);
  IF v_pedido > v_limite THEN
    v_pend := array_append(v_pend, 'pendencia:compensacao_excede_limite_do_art_477_p5_excedente_nao_descontado');
  END IF;

  -- 13. FGTS: obrigação patronal, fora do líquido.
  --     Depósito sobre saldo, aviso indenizado e 13º (menos o adiantamento que já foi base).
  v_fgts_dep := (SELECT f.fgts_deposito
                   FROM folha.calc_fgts(v_saldo + v_aviso_ind + GREATEST(v_13 - v_comp_13, 0), v_regime, v_ult) f);
  IF v_multa_pct > 0 THEN
    IF p_fgts_base_extrato IS NULL THEN
      multa_fgts := NULL;   -- sem valor presumido
      v_pend := array_append(v_pend, 'pendencia:base_do_fgts_para_fins_rescisorios_nao_informada_multa_nao_calculada');
    ELSIF p_fgts_base_extrato < 0 THEN
      RAISE EXCEPTION 'calc_rescisao: base do FGTS não pode ser negativa';
    ELSE
      multa_fgts := ROUND(v_multa_pct * (p_fgts_base_extrato + v_fgts_dep), 2);
    END IF;
  ELSE
    multa_fgts := 0;
  END IF;

  -- 14. Totais. A multa e o depósito do FGTS não entram nos proventos nem no líquido.
  saldo_salario := v_saldo;
  dias_saldo := v_dias_saldo;
  aviso_previo_indenizado := v_aviso_ind;
  decimo_terceiro_proporcional := v_13;
  avos_13 := v_avos_13;
  avos_13_projecao := v_avos_13 - v_avos_13_sem_proj;
  ferias_vencidas := v_fer_venc;
  terco_ferias_vencidas := v_terco_venc;
  ferias_proporcionais := v_fer_prop;
  terco_ferias_proporcionais := v_terco_prop;
  avos_ferias_proporcionais := v_avos_fer;
  indenizacao_479 := v_ind_479;
  total_proventos := v_saldo + v_aviso_ind + v_13 + v_fer_venc + v_terco_venc
                   + v_fer_prop + v_terco_prop + v_ind_479;
  desconto_aviso := v_desc_aviso;
  desconto_art480 := v_desc_480;
  desconto_adiantamento_13 := v_comp_13 + v_excedente_adiant;
  total_descontos := inss_mensal + inss_13 + irrf_mensal + irrf_13
                   + desconto_aviso + desconto_art480 + desconto_adiantamento_13;
  liquido_rescisao := total_proventos - total_descontos;
  IF liquido_rescisao < 0 THEN
    v_pend := array_append(v_pend, 'pendencia:liquido_negativo_exige_decisao');
  END IF;
  fgts_deposito_rescisao := v_fgts_dep;
  data_limite_pagamento := v_ult + folha.get_param('prazo_pagamento_rescisao_dias', v_ult)::integer;

  estado := CASE WHEN EXISTS (SELECT 1 FROM unnest(v_pend) p WHERE p LIKE 'pendencia:%')
                 THEN 'pendente' ELSE 'calculado' END;
  pendencias_validacao := v_pend || folha.params_a_validar(v_chaves, v_ult);
  RETURN NEXT;
END;
$$;

-- ===========================================================================
-- 7. ACL das funções criadas ou recriadas
--    Executavam (0016 e 0019): dnex_gestao_folha_worker e dnex_gestao_data_owner. Só eles recebem.
-- ===========================================================================
DO $$
DECLARE
  v_sig text;
BEGIN
  FOREACH v_sig IN ARRAY ARRAY[
    'folha.get_param(text, date)',
    'folha.params_a_validar(text[], date)',
    'folha.avos_13o(integer, date, date)',
    'folha.avos_ferias(date, date)',
    'folha.calc_irrf_separado(numeric, numeric, integer, date)',
    'folha.calc_inss(numeric, date)',
    'folha.calc_13o(uuid, date, integer, numeric, numeric, integer, numeric, numeric, numeric, numeric, integer)',
    'folha.calc_ferias(uuid, date, date, integer, integer, integer, date, numeric, integer)',
    'folha.calc_rescisao(uuid, date, text, text, date, date, integer, integer, numeric, date, numeric, integer, integer, numeric, numeric, integer)'
  ] LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', v_sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO dnex_gestao_folha_worker, dnex_gestao_data_owner', v_sig);
  END LOOP;
END
$$;

-- ===========================================================================
-- 8. Incidências das rubricas (achados V2/C1, V3 e V4 sobre a 0017)
-- ===========================================================================
-- Férias indenizadas na rescisão: sem INSS, IRRF e FGTS.
UPDATE folha.earning_deduction_code
   SET incidencia_inss = false, incidencia_irrf = false, incidencia_fgts = false,
       descricao = 'Férias proporcionais + 1/3 na rescisão (indenizadas, sem incidência)',
       updated_at = now()
 WHERE codigo = 'RESC_FERIAS_PROP' AND is_global = true
   AND (incidencia_inss OR incidencia_irrf OR incidencia_fgts);

UPDATE folha.earning_deduction_code
   SET incidencia_inss = false, incidencia_irrf = false, incidencia_fgts = false,
       descricao = 'Férias vencidas + 1/3 na rescisão (indenizadas, sem incidência)',
       updated_at = now()
 WHERE codigo = 'RESC_FERIAS_VENCIDAS' AND is_global = true
   AND (incidencia_inss OR incidencia_irrf OR incidencia_fgts);

-- Abono pecuniário: fora da base do FGTS.
UPDATE folha.earning_deduction_code
   SET incidencia_fgts = false,
       descricao = 'Abono pecuniário de férias (CLT arts. 143 e 144; sem INSS e FGTS)',
       updated_at = now()
 WHERE codigo = 'ABONO_PECUNIARIO' AND is_global = true
   AND incidencia_fgts;

-- 1ª parcela do 13º: o INSS incide na quitação, sobre o total.
UPDATE folha.earning_deduction_code
   SET incidencia_inss = false,
       descricao = '13º salário 1ª parcela (adiantamento; INSS na quitação; FGTS no mês)',
       updated_at = now()
 WHERE codigo = 'DECIMO_TERCEIRO_1A' AND is_global = true
   AND incidencia_inss;

COMMIT;
