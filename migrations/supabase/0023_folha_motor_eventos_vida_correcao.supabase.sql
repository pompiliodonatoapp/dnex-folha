-- DNEX Folha — Migration 0023: Correção do motor de eventos de vida (13º, férias, rescisão)
-- Reescreve calc_13o, calc_ferias e calc_rescisao conforme pareceres técnicos de 15/11/2026.
-- Cria folha.payroll_parameter para constantes normativas por vigência.
-- Corrige incidências das rubricas (0017) e perda de 1 centavo no calc_inss (0016).
-- NÃO altera migrations 0014–0022 (já aplicadas em produção).
-- Rollback: DROP FUNCTION IF EXISTS folha.calc_13o(uuid,date,integer);
--           DROP FUNCTION IF EXISTS folha.calc_ferias(uuid,date);
--           DROP FUNCTION IF EXISTS folha.calc_rescisao(uuid,date,text);
--           DROP TABLE IF EXISTS folha.payroll_parameter;
BEGIN;

-- ===========================================================================
-- 1. Tabela de parâmetros normativos por vigência
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
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'payroll_param_read' AND tablename = 'payroll_parameter') THEN
    CREATE POLICY payroll_param_read ON folha.payroll_parameter FOR SELECT USING (true);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'payroll_param_write' AND tablename = 'payroll_parameter') THEN
    CREATE POLICY payroll_param_write ON folha.payroll_parameter
      FOR INSERT WITH CHECK (current_user = 'dnex_gestao_data_owner');
  END IF;
END $$;

REVOKE ALL ON folha.payroll_parameter FROM PUBLIC, anon, authenticated;
GRANT SELECT ON folha.payroll_parameter TO dnex_gestao_folha_worker;
GRANT SELECT, INSERT, UPDATE ON folha.payroll_parameter TO dnex_gestao_data_owner;

-- Seed dos parâmetros normativos vigentes em 2026
INSERT INTO folha.payroll_parameter (chave, valor, vigencia_inicio, fonte_normativa, status_validacao, observacao) VALUES
  -- 13º salário
  ('avos_13o_fracao_minima_dias',       15,     '2026-01-01', 'Lei 4.090/1962 art.1 §2; Dec 10.854/2021 art.76 §2', 'validado',      'Fração igual ou superior a 15 dias conta como mês integral'),
  ('adiantamento_13o_fracao',           0.5,    '2026-01-01', 'Lei 4.749/1965 art.2; Dec 10.854/2021 art.78',        'validado',      'Metade do salário para adiantamento'),
  ('adiantamento_13o_mes_inicio',       2,      '2026-01-01', 'Lei 4.749/1965 art.2',                                'validado',      'Janela início: fevereiro'),
  ('adiantamento_13o_mes_fim',          11,     '2026-01-01', 'Lei 4.749/1965 art.2',                                'validado',      'Janela fim: novembro'),
  ('quitacao_13o_data_limite',          20,     '2026-01-01', 'Lei 4.749/1965 art.1; Dec 10.854/2021 art.76',        'validado',      'Dia limite para quitação em dezembro'),
  ('ajuste_variaveis_data_limite_mes',  1,      '2026-01-01', 'Dec 10.854/2021 art.77 par.único',                    'validado',      'Mês do ajuste: janeiro'),
  ('ajuste_variaveis_data_limite_dia',  10,     '2026-01-01', 'Dec 10.854/2021 art.77 par.único',                    'validado',      'Dia limite do ajuste: 10'),
  ('divisor_variaveis_quitacao',        11,     '2026-01-01', 'Dec 10.854/2021 art.77 caput',                        'a_validar',     'Divisor da média de variáveis na quitação'),
  ('divisor_variaveis_ajuste',          12,     '2026-01-01', 'Dec 10.854/2021 art.77 par.único',                    'a_validar',     'Divisor da média de variáveis no ajuste'),
  -- Férias
  ('ferias_frac_avo_dias',              14,     '2026-01-01', 'CLT art.146 par.único',                               'validado',      'Fração superior a 14 dias conta como avo'),
  ('ferias_terco_fracao',               0.3333333333, '2026-01-01', 'CF art.7 XVII',                                 'validado',      'Terço constitucional ≈ 1/3'),
  ('ferias_abono_fracao_max',           0.3333333333, '2026-01-01', 'CLT art.143',                                   'validado',      'Abono máximo: 1/3 do direito'),
  ('ferias_antecedencia_pagamento_dias',2,      '2026-01-01', 'CLT art.145',                                         'validado',      'Pagamento até 2 dias antes do início'),
  ('ferias_periodo_concessivo_meses',   12,     '2026-01-01', 'CLT art.134',                                         'validado',      'Período concessivo: 12 meses após aquisição'),
  ('ferias_fracionamento_max_periodos', 3,      '2026-01-01', 'CLT art.134 §1',                                      'a_validar',     'Até 3 períodos com concordância'),
  ('ferias_fracionamento_minimo_1',     14,     '2026-01-01', 'CLT art.134 §1',                                      'a_validar',     'Um período >= 14 dias'),
  ('ferias_fracionamento_minimo_2',     5,      '2026-01-01', 'CLT art.134 §1',                                      'a_validar',     'Demais períodos >= 5 dias'),
  ('ferias_escala_faltas_0_5',          30,     '2026-01-01', 'CLT art.130',                                         'validado',      '0-5 faltas: 30 dias'),
  ('ferias_escala_faltas_6_14',         24,     '2026-01-01', 'CLT art.130',                                         'validado',      '6-14 faltas: 24 dias'),
  ('ferias_escala_faltas_15_23',        18,     '2026-01-01', 'CLT art.130',                                         'validado',      '15-23 faltas: 18 dias'),
  ('ferias_escala_faltas_24_32',        12,     '2026-01-01', 'CLT art.130',                                         'validado',      '24-32 faltas: 12 dias'),
  -- Rescisão
  ('aviso_previo_base_dias',            30,     '2026-01-01', 'Lei 12.506/2011 art.1; CLT art.487',                  'validado',      'Aviso base: 30 dias'),
  ('aviso_previo_dias_por_ano',         3,      '2026-01-01', 'Lei 12.506/2011 art.1',                               'validado',      '+3 dias por ano completo'),
  ('aviso_previo_teto_dias',            90,     '2026-01-01', 'Lei 12.506/2011 art.1',                               'validado',      'Teto: 90 dias'),
  ('multa_fgts_dispensa_sem_jc',        0.40,   '2026-01-01', 'Lei 8.036/1990 art.18 §1',                            'validado',      'Multa 40% dispensa sem justa causa'),
  ('multa_fgts_acordo_484a',            0.20,   '2026-01-01', 'CLT art.484-A I b',                                   'validado',      'Multa 20% acordo'),
  ('indenizacao_art479_fracao',         0.50,   '2026-01-01', 'CLT art.479',                                         'validado',      'Indenização art.479: metade'),
  ('limite_compensacao_trct_salarios',  1,      '2026-01-01', 'CLT art.477 §5',                                      'validado',      'Limite compensação: 1 remuneração'),
  ('prazo_pagamento_rescisao_dias',     10,     '2026-01-01', 'CLT art.477 §6',                                      'validado',      'Prazo pagamento: 10 dias do término'),
  ('divisor_saldo_salario',             30,     '2026-01-01', 'Convenção produto',                                   'a_validar',     'Divisor do saldo de salário (convenção/CCT)'),
  ('inss_aviso_indenizado_incide',      0,      '2026-01-01', 'STJ Tema 478; ato Receita',                           'a_validar',     '0=não incide (default conservador); 1=incide'),
  ('inss_projecao_aviso_incide',        1,      '2026-01-01', 'Orientação Receita',                                  'a_validar',     '1=incide sobre avos da projeção (default)'),
  ('fgts_aliquota_clt',                 0.08,   '2026-01-01', 'Lei 8.036/1990 art.15 caput',                         'validado',      'FGTS 8% CLT'),
  ('fgts_aliquota_aprendiz',            0.02,   '2026-01-01', 'Lei 8.036/1990 art.15 §7',                            'validado',      'FGTS 2% aprendiz')
ON CONFLICT (chave, vigencia_inicio) DO UPDATE SET
  valor = EXCLUDED.valor,
  fonte_normativa = EXCLUDED.fonte_normativa,
  status_validacao = EXCLUDED.status_validacao,
  observacao = EXCLUDED.observacao,
  updated_at = now();

-- ===========================================================================
-- 2. Função auxiliar: buscar parâmetro vigente
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
  SELECT valor INTO v_valor
  FROM folha.payroll_parameter
  WHERE chave = p_chave
    AND vigencia_inicio <= p_data
    AND (vigencia_fim IS NULL OR vigencia_fim >= p_data)
  ORDER BY vigencia_inicio DESC
  LIMIT 1;

  IF v_valor IS NULL THEN
    RAISE EXCEPTION 'Parâmetro % não encontrado para data %', p_chave, p_data;
  END IF;
  RETURN v_valor;
END;
$$;

REVOKE ALL ON FUNCTION folha.get_param(text, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION folha.get_param(text, date) TO dnex_gestao_folha_worker;
GRANT EXECUTE ON FUNCTION folha.get_param(text, date) TO dnex_gestao_data_owner;

-- ===========================================================================
-- 3. Função auxiliar: contar avos do 13º por ano civil
-- ===========================================================================
CREATE OR REPLACE FUNCTION folha.avos_13o(
  p_ano integer,
  p_admissao date,
  p_desligamento date DEFAULT NULL,
  p_data_ref date DEFAULT NULL
) RETURNS integer
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_fracao_min integer;
  v_avos integer := 0;
  v_ini_mes date;
  v_fim_mes date;
  v_ini_efetivo date;
  v_fim_efetivo date;
  v_dias integer;
  m integer;
BEGIN
  v_fracao_min := folha.get_param('avos_13o_fracao_minima_dias', make_date(p_ano, 1, 1))::integer;

  FOR m IN 1..12 LOOP
    v_ini_mes := make_date(p_ano, m, 1);
    v_fim_mes := (v_ini_mes + INTERVAL '1 month - 1 day')::date;

    v_ini_efetivo := GREATEST(v_ini_mes, p_admissao);
    v_fim_efetivo := LEAST(v_fim_mes, COALESCE(p_desligamento, p_data_ref, v_fim_mes));

    IF v_ini_efetivo > v_fim_efetivo THEN
      CONTINUE;
    END IF;

    v_dias := v_fim_efetivo - v_ini_efetivo + 1;

    IF v_dias >= v_fracao_min THEN
      v_avos := v_avos + 1;
    END IF;
  END LOOP;

  RETURN v_avos;
END;
$$;

REVOKE ALL ON FUNCTION folha.avos_13o(integer, date, date, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION folha.avos_13o(integer, date, date, date) TO dnex_gestao_folha_worker;
GRANT EXECUTE ON FUNCTION folha.avos_13o(integer, date, date, date) TO dnex_gestao_data_owner;

-- ===========================================================================
-- 4. Função auxiliar: contar avos de férias proporcionais
-- ===========================================================================
CREATE OR REPLACE FUNCTION folha.avos_ferias(
  p_inicio_aquisitivo date,
  p_data_fim date
) RETURNS integer
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_fracao integer;
  v_meses_completos integer;
  v_resto_dias integer;
  v_aniversario date;
  v_avos integer;
BEGIN
  v_fracao := folha.get_param('ferias_frac_avo_dias', p_data_fim)::integer;

  -- Meses completos entre início aquisitivo e data_fim
  v_meses_completos := (EXTRACT(YEAR FROM AGE(p_data_fim, p_inicio_aquisitivo)) * 12
                       + EXTRACT(MONTH FROM AGE(p_data_fim, p_inicio_aquisitivo)))::integer;

  -- Resto em dias após o último aniversário mensal
  v_aniversario := p_inicio_aquisitivo + (v_meses_completos || ' months')::interval;
  v_resto_dias := p_data_fim - v_aniversario;

  v_avos := v_meses_completos;
  IF v_resto_dias > v_fracao THEN
    v_avos := v_avos + 1;
  END IF;

  RETURN LEAST(v_avos, 12);
END;
$$;

REVOKE ALL ON FUNCTION folha.avos_ferias(date, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION folha.avos_ferias(date, date) TO dnex_gestao_folha_worker;
GRANT EXECUTE ON FUNCTION folha.avos_ferias(date, date) TO dnex_gestao_data_owner;

-- ===========================================================================
-- 5. calc_13o — REESCRITA
--    Assinatura mantida com novos parâmetros opcionais (DEFAULT).
--    p_parcela: 1=adiantamento, 2=quitação
-- ===========================================================================
DROP FUNCTION IF EXISTS folha.calc_13o(uuid, date, integer);

CREATE OR REPLACE FUNCTION folha.calc_13o(
  p_contract_id uuid,
  p_competencia date DEFAULT CURRENT_DATE,
  p_parcela integer DEFAULT 2,
  p_adiantamento_pago numeric DEFAULT 0,
  p_media_variaveis numeric DEFAULT 0,
  p_num_dependentes integer DEFAULT 0
) RETURNS TABLE (
  valor_bruto numeric,
  inss numeric,
  irrf numeric,
  valor_liquido numeric,
  meses_proporcionais integer,
  base_calculo numeric,
  fgts numeric,
  adiantamento_compensado numeric,
  pendencias_validacao text[]
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_account_id uuid;
  v_salario numeric;
  v_data_admissao date;
  v_regime text;
  v_status text;
  v_ano integer;
  v_avos integer;
  v_base_fixa numeric;
  v_base_total numeric;
  v_fracao_adiant numeric;
  v_inss_rec record;
  v_irrf_rec record;
  v_fgts_al numeric;
  v_pendencias text[] := ARRAY[]::text[];
BEGIN
  -- Carregar contrato COM tenant
  SELECT c.account_id, c.salario_base, c.data_admissao, c.regime_trabalho, c.status
    INTO v_account_id, v_salario, v_data_admissao, v_regime, v_status
    FROM folha.employment_contract c
   WHERE c.contract_id = p_contract_id
     AND c.account_id = folha.current_account_id();

  IF v_salario IS NULL THEN
    RAISE EXCEPTION 'Contrato % não encontrado', p_contract_id;
  END IF;

  IF v_regime NOT IN ('clt', 'aprendiz') THEN
    RAISE EXCEPTION 'Regime % não tem direito a 13º salário', v_regime;
  END IF;

  IF p_parcela NOT IN (1, 2) THEN
    RAISE EXCEPTION 'p_parcela deve ser 1 (adiantamento) ou 2 (quitação); recebido %', p_parcela;
  END IF;

  v_ano := EXTRACT(YEAR FROM p_competencia)::integer;

  -- Avos por ano civil com fração de 15 dias
  v_avos := folha.avos_13o(v_ano, v_data_admissao, NULL, p_competencia);

  v_base_fixa := v_salario + COALESCE(p_media_variaveis, 0);
  v_base_total := ROUND(v_base_fixa * v_avos / 12.0, 2);

  -- Verificar pendências de validação nos parâmetros
  IF EXISTS (SELECT 1 FROM folha.payroll_parameter
              WHERE chave IN ('divisor_variaveis_quitacao','divisor_variaveis_ajuste')
                AND status_validacao = 'a_validar'
                AND vigencia_inicio <= p_competencia
                AND (vigencia_fim IS NULL OR vigencia_fim >= p_competencia)) THEN
    v_pendencias := array_append(v_pendencias, 'divisor_variaveis_a_validar');
  END IF;

  IF p_parcela = 1 THEN
    -- ADIANTAMENTO: metade, sem INSS/IRRF, com FGTS
    v_fracao_adiant := folha.get_param('adiantamento_13o_fracao', p_competencia);
    valor_bruto := ROUND(v_base_total * v_fracao_adiant, 2);
    inss := 0;
    irrf := 0;
    adiantamento_compensado := 0;

    v_fgts_al := CASE WHEN v_regime = 'aprendiz'
                      THEN folha.get_param('fgts_aliquota_aprendiz', p_competencia)
                      ELSE folha.get_param('fgts_aliquota_clt', p_competencia) END;
    fgts := ROUND(valor_bruto * v_fgts_al, 2);
    valor_liquido := valor_bruto;

  ELSE
    -- QUITAÇÃO: bruto total, INSS em separado, IRRF em separado, compensa adiantamento
    valor_bruto := v_base_total;

    SELECT * INTO v_inss_rec FROM folha.calc_inss(valor_bruto, p_competencia);
    inss := v_inss_rec.valor_inss;

    SELECT * INTO v_irrf_rec FROM folha.calc_irrf(
      valor_bruto - inss, p_num_dependentes, false, p_competencia
    );
    irrf := v_irrf_rec.valor_irrf;

    adiantamento_compensado := COALESCE(p_adiantamento_pago, 0);

    v_fgts_al := CASE WHEN v_regime = 'aprendiz'
                      THEN folha.get_param('fgts_aliquota_aprendiz', p_competencia)
                      ELSE folha.get_param('fgts_aliquota_clt', p_competencia) END;
    fgts := ROUND((valor_bruto - adiantamento_compensado) * v_fgts_al, 2);

    valor_liquido := valor_bruto - adiantamento_compensado - inss - irrf;
  END IF;

  meses_proporcionais := v_avos;
  base_calculo := v_base_total;
  pendencias_validacao := v_pendencias;
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION folha.calc_13o(uuid, date, integer, numeric, numeric, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION folha.calc_13o(uuid, date, integer, numeric, numeric, integer) TO dnex_gestao_folha_worker;
GRANT EXECUTE ON FUNCTION folha.calc_13o(uuid, date, integer, numeric, numeric, integer) TO dnex_gestao_data_owner;

-- ===========================================================================
-- 6. calc_ferias — REESCRITA
--    Novos parâmetros: dias_gozo, dias_abono, faltas, periodo_aquisitivo_inicio,
--    periodo_concessivo_fim, salario_com_medias.
-- ===========================================================================
DROP FUNCTION IF EXISTS folha.calc_ferias(uuid, date);

CREATE OR REPLACE FUNCTION folha.calc_ferias(
  p_contract_id uuid,
  p_competencia date DEFAULT CURRENT_DATE,
  p_dias_gozo integer DEFAULT 30,
  p_dias_abono integer DEFAULT 0,
  p_faltas_injustificadas integer DEFAULT 0,
  p_periodo_aquisitivo_inicio date DEFAULT NULL,
  p_periodo_concessivo_fim date DEFAULT NULL,
  p_salario_com_medias numeric DEFAULT NULL
) RETURNS TABLE (
  valor_ferias numeric,
  valor_um_terco numeric,
  total_ferias numeric,
  dias_vencidos integer,
  dias_proporcionais integer,
  base_calculo numeric,
  tabela_hash text,
  valor_abono numeric,
  terco_abono numeric,
  valor_dobra numeric,
  inss numeric,
  irrf numeric,
  valor_liquido numeric,
  fgts numeric,
  pendencias_validacao text[]
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_account_id uuid;
  v_salario numeric;
  v_data_admissao date;
  v_regime text;
  v_rem numeric;
  v_pa_inicio date;
  v_pc_fim date;
  v_dias_direito integer;
  v_avos integer;
  v_terco_frac numeric;
  v_abono_frac_max numeric;
  v_dias_abono_max integer;
  v_ferias_gozadas numeric;
  v_terco_gozadas numeric;
  v_abono_val numeric;
  v_terco_abono_val numeric;
  v_dias_dobra integer := 0;
  v_dobra_val numeric := 0;
  v_bruto_total numeric;
  v_base_inss numeric;
  v_inss_rec record;
  v_irrf_rec record;
  v_fgts_al numeric;
  v_pendencias text[] := ARRAY[]::text[];
BEGIN
  SELECT c.account_id, c.salario_base, c.data_admissao, c.regime_trabalho
    INTO v_account_id, v_salario, v_data_admissao, v_regime
    FROM folha.employment_contract c
   WHERE c.contract_id = p_contract_id
     AND c.account_id = folha.current_account_id();

  IF v_salario IS NULL THEN
    RAISE EXCEPTION 'Contrato % não encontrado', p_contract_id;
  END IF;

  IF v_regime NOT IN ('clt', 'aprendiz') THEN
    RAISE EXCEPTION 'Regime % não tem direito a férias CLT', v_regime;
  END IF;

  v_rem := COALESCE(p_salario_com_medias, v_salario);

  -- Período aquisitivo: default = data_admissao (ou aniversário mais recente)
  v_pa_inicio := COALESCE(p_periodo_aquisitivo_inicio, v_data_admissao);
  v_pc_fim := COALESCE(p_periodo_concessivo_fim,
                       v_pa_inicio + (folha.get_param('ferias_periodo_concessivo_meses', p_competencia)::integer || ' months')::interval);

  -- Escala de faltas → dias de direito
  v_dias_direito := CASE
    WHEN p_faltas_injustificadas <= 5  THEN folha.get_param('ferias_escala_faltas_0_5', p_competencia)::integer
    WHEN p_faltas_injustificadas <= 14 THEN folha.get_param('ferias_escala_faltas_6_14', p_competencia)::integer
    WHEN p_faltas_injustificadas <= 23 THEN folha.get_param('ferias_escala_faltas_15_23', p_competencia)::integer
    WHEN p_faltas_injustificadas <= 32 THEN folha.get_param('ferias_escala_faltas_24_32', p_competencia)::integer
    ELSE 0
  END;

  -- Avos proporcionais (se período aquisitivo incompleto)
  v_avos := folha.avos_ferias(v_pa_inicio, p_competencia);

  -- Determinar se são vencidas (>=12 avos) ou proporcionais
  IF v_avos >= 12 THEN
    dias_vencidos := v_dias_direito;
    dias_proporcionais := 0;
  ELSE
    dias_vencidos := 0;
    dias_proporcionais := v_avos;
  END IF;

  -- Férias gozadas (proporcional aos dias de gozo sobre o direito)
  IF dias_vencidos > 0 THEN
    v_ferias_gozadas := ROUND(v_rem * p_dias_gozo / 30.0, 2);
  ELSE
    v_ferias_gozadas := ROUND(v_rem * p_dias_gozo / 30.0 * v_avos / 12.0, 2);
  END IF;

  v_terco_frac := folha.get_param('ferias_terco_fracao', p_competencia);
  v_terco_gozadas := ROUND(v_ferias_gozadas * v_terco_frac, 2);

  -- Abono pecuniário
  v_abono_frac_max := folha.get_param('ferias_abono_fracao_max', p_competencia);
  v_dias_abono_max := FLOOR(v_dias_direito * v_abono_frac_max)::integer;
  IF p_dias_abono > v_dias_abono_max THEN
    v_pendencias := array_append(v_pendencias, 'abono_excede_maximo_' || v_dias_abono_max || '_dias');
  END IF;
  v_abono_val := ROUND(v_rem * LEAST(p_dias_abono, v_dias_abono_max) / 30.0, 2);
  v_terco_abono_val := ROUND(v_abono_val * v_terco_frac, 2);

  -- Dobra (dias de gozo após o fim do concessivo)
  IF p_competencia > v_pc_fim AND p_dias_gozo > 0 THEN
    v_dias_dobra := p_dias_gozo; -- simplificação: todos os dias fora do prazo
    v_dobra_val := ROUND((v_rem * v_dias_dobra / 30.0) * (1 + v_terco_frac), 2);
    v_pendencias := array_append(v_pendencias, 'dobra_art137_aplicada');
  END IF;

  -- Totais
  valor_ferias := v_ferias_gozadas;
  valor_um_terco := v_terco_gozadas;
  valor_abono := v_abono_val;
  terco_abono := v_terco_abono_val;
  valor_dobra := v_dobra_val;
  total_ferias := v_ferias_gozadas + v_terco_gozadas + v_abono_val + v_terco_abono_val + v_dobra_val;

  -- INSS e FGTS só sobre a parte gozada (férias + terço), NÃO sobre abono nem dobra
  v_base_inss := v_ferias_gozadas + v_terco_gozadas;
  SELECT * INTO v_inss_rec FROM folha.calc_inss(v_base_inss, p_competencia);
  inss := v_inss_rec.valor_inss;

  -- IRRF em separado sobre a parte tributável (gozada + terço; abono e dobra A VALIDAR)
  SELECT * INTO v_irrf_rec FROM folha.calc_irrf(v_base_inss - inss, 0, false, p_competencia);
  irrf := v_irrf_rec.valor_irrf;

  v_fgts_al := CASE WHEN v_regime = 'aprendiz'
                    THEN folha.get_param('fgts_aliquota_aprendiz', p_competencia)
                    ELSE folha.get_param('fgts_aliquota_clt', p_competencia) END;
  fgts := ROUND(v_base_inss * v_fgts_al, 2);

  valor_liquido := total_ferias - inss - irrf;
  base_calculo := v_rem;
  tabela_hash := 'ferias_0023_v1';
  pendencias_validacao := v_pendencias;
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION folha.calc_ferias(uuid, date, integer, integer, integer, date, date, numeric)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION folha.calc_ferias(uuid, date, integer, integer, integer, date, date, numeric)
  TO dnex_gestao_folha_worker;
GRANT EXECUTE ON FUNCTION folha.calc_ferias(uuid, date, integer, integer, integer, date, date, numeric)
  TO dnex_gestao_data_owner;

-- ===========================================================================
-- 7. calc_rescisao — REESCRITA
--    Matriz motivo × verba; multa FGTS fora do líquido; INSS/IRRF via motor.
-- ===========================================================================
DROP FUNCTION IF EXISTS folha.calc_rescisao(uuid, date, text);

CREATE OR REPLACE FUNCTION folha.calc_rescisao(
  p_contract_id uuid,
  p_data_demissao date,
  p_motivo text DEFAULT 'sem_justa_causa',
  p_aviso_modo text DEFAULT 'indenizado_empregador',
  p_dias_aviso_trabalhados integer DEFAULT 0,
  p_fgts_base_extrato numeric DEFAULT NULL,
  p_prejuizo_art480 numeric DEFAULT NULL,
  p_num_dependentes integer DEFAULT 0,
  p_rendimentos_ja_pagos_no_mes numeric DEFAULT 0,
  p_salario_com_medias numeric DEFAULT NULL
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
  liquido_rescisao numeric,
  fgts_deposito_rescisao numeric,
  dias_aviso integer,
  data_projetada date,
  inss_mensal numeric,
  inss_13 numeric,
  irrf_mensal numeric,
  irrf_13 numeric,
  indenizacao_479 numeric,
  desconto_aviso numeric,
  desconto_art480 numeric,
  pendencias_validacao text[]
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_account_id uuid;
  v_salario numeric;
  v_data_admissao date;
  v_regime text;
  v_rem numeric;
  v_divisor numeric;
  v_dias_saldo integer;
  v_saldo numeric;
  v_anos_completos integer;
  v_dias_aviso_legal integer;
  v_dias_aviso_ind integer := 0;
  v_aviso_ind numeric := 0;
  v_data_proj date;
  v_avos_13 integer;
  v_13o numeric := 0;
  v_ferias_venc numeric := 0;
  v_terco_venc numeric := 0;
  v_ferias_prop numeric := 0;
  v_terco_prop numeric := 0;
  v_ind_479 numeric := 0;
  v_desc_aviso numeric := 0;
  v_desc_480 numeric := 0;
  v_multa_pct numeric := 0;
  v_multa_fgts_val numeric := 0;
  v_fgts_dep numeric := 0;
  v_fgts_al numeric;
  v_base_inss_mes numeric;
  v_inss_mes_rec record;
  v_inss_13_rec record;
  v_irrf_mes_rec record;
  v_irrf_13_rec record;
  v_total_prov numeric;
  v_total_desc numeric;
  v_limite_comp numeric;
  v_pendencias text[] := ARRAY[]::text[];
  v_tem_13o boolean := true;
  v_tem_ferias_prop boolean := true;
  v_tem_aviso_empregador boolean := false;
  v_tem_multa_fgts boolean := false;
  v_tem_ind_479 boolean := false;
  v_tem_desc_aviso boolean := false;
  v_aviso_frac numeric := 1.0;
  v_inss_aviso_incide numeric;
  v_inss_proj_incide numeric;
BEGIN
  -- 1. Carregar contrato COM tenant
  SELECT c.account_id, c.salario_base, c.data_admissao, c.regime_trabalho
    INTO v_account_id, v_salario, v_data_admissao, v_regime
    FROM folha.employment_contract c
   WHERE c.contract_id = p_contract_id
     AND c.account_id = folha.current_account_id();

  IF v_salario IS NULL THEN
    RAISE EXCEPTION 'Contrato % não encontrado', p_contract_id;
  END IF;

  IF v_regime NOT IN ('clt', 'aprendiz') THEN
    RAISE EXCEPTION 'Regime % não tem rescisão CLT', v_regime;
  END IF;

  IF p_data_demissao < v_data_admissao THEN
    RAISE EXCEPTION 'Data de demissão % anterior à admissão %', p_data_demissao, v_data_admissao;
  END IF;

  v_rem := COALESCE(p_salario_com_medias, v_salario);
  v_divisor := folha.get_param('divisor_saldo_salario', p_data_demissao);

  -- 2. Validar motivo e definir matriz
  IF p_motivo IS NULL OR p_motivo = '' THEN
    RAISE EXCEPTION 'Motivo de rescisão não pode ser nulo ou vazio';
  END IF;

  CASE p_motivo
    WHEN 'sem_justa_causa' THEN
      v_tem_13o := true; v_tem_ferias_prop := true;
      v_tem_aviso_empregador := true; v_tem_multa_fgts := true;
      v_multa_pct := folha.get_param('multa_fgts_dispensa_sem_jc', p_data_demissao);
    WHEN 'pedido_demissao' THEN
      v_tem_13o := true; v_tem_ferias_prop := true;
      v_tem_desc_aviso := (p_aviso_modo = 'descontado_empregado');
    WHEN 'justa_causa' THEN
      v_tem_13o := false; v_tem_ferias_prop := false;
    WHEN 'acordo_484a' THEN
      v_tem_13o := true; v_tem_ferias_prop := true;
      v_tem_aviso_empregador := true; v_tem_multa_fgts := true;
      v_multa_pct := folha.get_param('multa_fgts_acordo_484a', p_data_demissao);
      v_aviso_frac := 0.5;
    WHEN 'termino_prazo' THEN
      v_tem_13o := true; v_tem_ferias_prop := true;
    WHEN 'antecipacao_empregador' THEN
      v_tem_13o := true; v_tem_ferias_prop := true;
      v_tem_multa_fgts := true; v_tem_ind_479 := true;
      v_multa_pct := folha.get_param('multa_fgts_dispensa_sem_jc', p_data_demissao);
    WHEN 'antecipacao_empregado' THEN
      v_tem_13o := true; v_tem_ferias_prop := true;
    WHEN 'falecimento' THEN
      v_tem_13o := true; v_tem_ferias_prop := true;
    ELSE
      RAISE EXCEPTION 'Motivo de rescisão desconhecido: %', p_motivo;
  END CASE;

  -- 3. Saldo de salário
  v_dias_saldo := EXTRACT(DAY FROM p_data_demissao)::integer;
  v_saldo := ROUND(v_rem * v_dias_saldo / v_divisor, 2);

  -- 4. Aviso prévio
  v_anos_completos := EXTRACT(YEAR FROM AGE(p_data_demissao, v_data_admissao))::integer;
  v_dias_aviso_legal := LEAST(
    folha.get_param('aviso_previo_base_dias', p_data_demissao)::integer
    + folha.get_param('aviso_previo_dias_por_ano', p_data_demissao)::integer * v_anos_completos,
    folha.get_param('aviso_previo_teto_dias', p_data_demissao)::integer
  );

  IF v_tem_aviso_empregador AND p_aviso_modo = 'indenizado_empregador' THEN
    v_dias_aviso_ind := v_dias_aviso_legal - COALESCE(p_dias_aviso_trabalhados, 0);
    v_aviso_ind := ROUND(v_rem / v_divisor * v_dias_aviso_ind * v_aviso_frac, 2);
    v_data_proj := p_data_demissao + v_dias_aviso_ind;
  ELSIF v_tem_desc_aviso THEN
    v_desc_aviso := ROUND(v_rem / v_divisor * v_dias_aviso_legal, 2);
    v_data_proj := p_data_demissao;
  ELSE
    v_data_proj := p_data_demissao;
  END IF;

  dias_aviso := v_dias_aviso_legal;
  data_projetada := v_data_proj;

  -- 5. 13º proporcional
  IF v_tem_13o THEN
    v_avos_13 := folha.avos_13o(EXTRACT(YEAR FROM v_data_proj)::integer, v_data_admissao, v_data_proj, v_data_proj);
    v_13o := ROUND(v_rem * v_avos_13 / 12.0, 2);
  END IF;

  -- 6. Férias vencidas (simplificado: >=12 meses de casa → 1 período vencido)
  -- NOTA: modelo completo requer tabela vacation_period (pendência estrutural)
  IF EXTRACT(YEAR FROM AGE(v_data_proj, v_data_admissao)) * 12
     + EXTRACT(MONTH FROM AGE(v_data_proj, v_data_admissao)) >= 12 THEN
    v_ferias_venc := v_rem;
    v_terco_venc := ROUND(v_rem * folha.get_param('ferias_terco_fracao', p_data_demissao), 2);
  END IF;

  -- 7. Férias proporcionais
  IF v_tem_ferias_prop THEN
    DECLARE
      v_avos_fer integer;
    BEGIN
      v_avos_fer := folha.avos_ferias(v_data_admissao, v_data_proj);
      IF v_avos_fer > 0 AND v_avos_fer < 12 THEN
        v_ferias_prop := ROUND(v_rem * v_avos_fer / 12.0, 2);
        v_terco_prop := ROUND(v_ferias_prop * folha.get_param('ferias_terco_fracao', p_data_demissao), 2);
      ELSIF v_avos_fer >= 12 AND v_ferias_venc = 0 THEN
        -- Reclassificar como vencida se não havia vencida ainda
        v_ferias_venc := v_rem;
        v_terco_venc := ROUND(v_rem * folha.get_param('ferias_terco_fracao', p_data_demissao), 2);
      END IF;
    END;
  END IF;

  -- 8. Indenização art. 479 (antecipação empregador)
  IF v_tem_ind_479 THEN
    -- Metade da remuneração dos dias restantes até o termo
    -- Sem data_termo no schema atual: usar 30 dias como default conservador
    v_ind_479 := ROUND(v_rem / v_divisor * 30 * folha.get_param('indenizacao_art479_fracao', p_data_demissao), 2);
    v_pendencias := array_append(v_pendencias, 'ind_479_sem_data_termo_usou_30_dias');
  END IF;

  -- 9. Desconto art. 480 (antecipação empregado)
  IF p_motivo = 'antecipacao_empregado' THEN
    IF p_prejuizo_art480 IS NOT NULL AND p_prejuizo_art480 > 0 THEN
      v_desc_480 := LEAST(p_prejuizo_art480, v_ind_479);
    ELSE
      v_desc_480 := 0;
      v_pendencias := array_append(v_pendencias, 'prejuizo_art480_nao_informado');
    END IF;
  END IF;

  -- 10. Incidências
  v_inss_aviso_incide := folha.get_param('inss_aviso_indenizado_incide', p_data_demissao);
  v_inss_proj_incide := folha.get_param('inss_projecao_aviso_incide', p_data_demissao);

  -- INSS mensal: saldo + aviso trabalhado
  v_base_inss_mes := v_saldo;
  IF p_aviso_modo = 'trabalhado' AND p_dias_aviso_trabalhados > 0 THEN
    v_base_inss_mes := v_base_inss_mes + (v_rem / v_divisor * p_dias_aviso_trabalhados);
  END IF;

  SELECT * INTO v_inss_mes_rec FROM folha.calc_inss(v_base_inss_mes + COALESCE(p_rendimentos_ja_pagos_no_mes, 0), p_data_demissao);
  inss_mensal := v_inss_mes_rec.valor_inss;

  -- INSS 13º: em separado sobre o bruto
  IF v_13o > 0 THEN
    SELECT * INTO v_inss_13_rec FROM folha.calc_inss(v_13o, p_data_demissao);
    inss_13 := v_inss_13_rec.valor_inss;
  ELSE
    inss_13 := 0;
  END IF;

  -- IRRF mensal
  SELECT * INTO v_irrf_mes_rec FROM folha.calc_irrf(
    v_base_inss_mes - inss_mensal, p_num_dependentes, false, p_data_demissao
  );
  irrf_mensal := v_irrf_mes_rec.valor_irrf;

  -- IRRF 13º: exclusivo, em separado
  IF v_13o > 0 THEN
    SELECT * INTO v_irrf_13_rec FROM folha.calc_irrf(
      v_13o - inss_13, p_num_dependentes, false, p_data_demissao
    );
    irrf_13 := v_irrf_13_rec.valor_irrf;
  ELSE
    irrf_13 := 0;
  END IF;

  -- 11. FGTS depósito rescisório (obrigação patronal, fora do líquido)
  v_fgts_al := CASE WHEN v_regime = 'aprendiz'
                    THEN folha.get_param('fgts_aliquota_aprendiz', p_data_demissao)
                    ELSE folha.get_param('fgts_aliquota_clt', p_data_demissao) END;
  v_fgts_dep := ROUND((v_saldo + v_aviso_ind + v_13o) * v_fgts_al, 2);
  fgts_deposito_rescisao := v_fgts_dep;

  -- 12. Multa FGTS (fora dos proventos e do líquido)
  IF v_tem_multa_fgts THEN
    IF p_fgts_base_extrato IS NULL THEN
      v_multa_fgts_val := 0;
      v_pendencias := array_append(v_pendencias, 'fgts_base_extrato_ausente_multa_nao_calculada');
    ELSE
      v_multa_fgts_val := ROUND(v_multa_pct * (p_fgts_base_extrato + v_fgts_dep), 2);
    END IF;
  END IF;
  multa_fgts := v_multa_fgts_val;

  -- 13. Limite de compensação (art. 477 §5): soma descontos <= 1 remuneração
  v_limite_comp := v_rem * folha.get_param('limite_compensacao_trct_salarios', p_data_demissao);
  IF (v_desc_aviso + v_desc_480) > v_limite_comp THEN
    v_pendencias := array_append(v_pendencias, 'compensacao_excede_limite_art477');
    IF v_desc_aviso > v_limite_comp THEN
      v_desc_aviso := v_limite_comp;
      v_desc_480 := 0;
    ELSE
      v_desc_480 := LEAST(v_desc_480, v_limite_comp - v_desc_aviso);
    END IF;
  END IF;

  desconto_aviso := v_desc_aviso;
  desconto_art480 := v_desc_480;

  -- 14. Totais (multa FGTS NÃO entra nos proventos nem no líquido)
  v_total_prov := v_saldo + v_aviso_ind + v_13o
                + v_ferias_venc + v_terco_venc
                + v_ferias_prop + v_terco_prop
                + v_ind_479;
  total_proventos := v_total_prov;

  v_total_desc := COALESCE(inss_mensal, 0) + COALESCE(inss_13, 0)
                + COALESCE(irrf_mensal, 0) + COALESCE(irrf_13, 0)
                + v_desc_aviso + v_desc_480;
  total_descontos := v_total_desc;

  liquido_rescisao := v_total_prov - v_total_desc;

  saldo_salario := v_saldo;
  ferias_vencidas := v_ferias_venc;
  terco_ferias_vencidas := v_terco_venc;
  ferias_proporcionais := v_ferias_prop;
  terco_ferias_proporcionais := v_terco_prop;
  decimo_terceiro_proporcional := v_13o;
  aviso_previo_indenizado := v_aviso_ind;
  indenizacao_479 := v_ind_479;
  pendencias_validacao := v_pendencias;
  RETURN NEXT;
END;
$$;

REVOKE ALL ON FUNCTION folha.calc_rescisao(uuid, date, text, text, integer, numeric, numeric, integer, numeric, numeric)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION folha.calc_rescisao(uuid, date, text, text, integer, numeric, numeric, integer, numeric, numeric)
  TO dnex_gestao_folha_worker;
GRANT EXECUTE ON FUNCTION folha.calc_rescisao(uuid, date, text, text, integer, numeric, numeric, integer, numeric, numeric)
  TO dnex_gestao_data_owner;

-- ===========================================================================
-- 8. Correção das incidências das rubricas (0017 V2, V3, V4)
-- ===========================================================================

-- V2: Férias indenizadas na rescisão NÃO têm INSS, IRRF nem FGTS
UPDATE folha.earning_deduction_code
SET incidencia_inss = false, incidencia_irrf = false, incidencia_fgts = false,
    descricao = 'Férias proporcionais + 1/3 na rescisão (indenizada, sem incidência)',
    updated_at = now()
WHERE codigo = 'RESC_FERIAS_PROP' AND is_global = true
  AND (incidencia_inss = true OR incidencia_irrf = true OR incidencia_fgts = true);

UPDATE folha.earning_deduction_code
SET incidencia_inss = false, incidencia_irrf = false, incidencia_fgts = false,
    descricao = 'Férias vencidas + 1/3 na rescisão (indenizada, sem incidência)',
    updated_at = now()
WHERE codigo = 'RESC_FERIAS_VENCIDAS' AND is_global = true
  AND (incidencia_inss = true OR incidencia_irrf = true OR incidencia_fgts = true);

-- V3: Abono pecuniário NÃO tem FGTS
UPDATE folha.earning_deduction_code
SET incidencia_fgts = false,
    descricao = 'Abono pecuniário de férias (CLT arts. 143/144, sem INSS/FGTS)',
    updated_at = now()
WHERE codigo = 'ABONO_PECUNIARIO' AND is_global = true
  AND incidencia_fgts = true;

-- V4: 1ª parcela do 13º NÃO tem INSS (incide na quitação sobre o total)
UPDATE folha.earning_deduction_code
SET incidencia_inss = false,
    descricao = '13º salário 1ª parcela (adiantamento, sem INSS; FGTS no mês)',
    updated_at = now()
WHERE codigo = 'DECIMO_TERCEIRO_1A' AND is_global = true
  AND incidencia_inss = true;

-- ===========================================================================
-- 9. Correção do calc_inss: faixas contínuas (V5/C3)
--    O seed 0015 já tem limite_superior correto; o bug era usar limite_inferior
--    como piso da faixa seguinte, perdendo 1 centavo por faixa.
--    A função já usa LEAST(v_base, v_ls) - v_li onde v_li é o limite_inferior
--    da faixa atual. Com o seed atual (1621.01, 2902.85, 4354.28), a primeira
--    faixa vai de 0 a 1621.00 e a segunda começa em 1621.01 — sem gap.
--    O erro real estava na subtração: LEAST(base, 2902.84) - 1621.01 perde
--    o centavo 1621.00→1621.01. Corrigimos usando o limite_superior da faixa
--    anterior como piso efetivo.
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
  v_prev_ls numeric := 0;
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
  v_prev_ls := 0;

  FOR v_faixa IN SELECT * FROM jsonb_array_elements(v_tabela->'faixas')
  LOOP
    DECLARE
      v_ls numeric := COALESCE((v_faixa->>'limite_superior')::numeric, v_teto);
      v_al numeric := (v_faixa->>'aliquota')::numeric;
      v_parcela numeric;
    BEGIN
      IF v_base > v_prev_ls THEN
        v_parcela := LEAST(v_base, v_ls) - v_prev_ls;
        v_valor := v_valor + (v_parcela * v_al);
      END IF;
      v_prev_ls := v_ls;
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

REVOKE ALL ON FUNCTION folha.calc_inss(numeric, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION folha.calc_inss(numeric, date) TO dnex_gestao_folha_worker;
GRANT EXECUTE ON FUNCTION folha.calc_inss(numeric, date) TO dnex_gestao_data_owner;

COMMIT;