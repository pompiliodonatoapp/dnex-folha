-- DNEX Folha — Migration 0025: motor mensal (INSS, IRRF, FGTS, salário-família, pró-labore e
-- encargos patronais por lotação tributária).
--
-- Fonte: parecer de DP "INSS, FGTS, IRRF e encargos patronais" de 15/11/2026 (achados E-01 a
-- E-19, tabelas 2024-2026 e casos dourados CD-01 a CD-15). Os casos estão em
-- tests/folha/0025_motor_mensal_dourados.pgtap.sql e foram executados em Postgres 17 + pgTAP.
-- O que o parecer marca "A VALIDAR NA FONTE" entra como parâmetro a_validar ou como pendência
-- devolvida pela função; nada disso é tratado como norma conferida.
--
-- O que esta migration faz:
--   1. Cadastro: categoria 'contribuinte_individual' (pró-labore) em employment_contract;
--      payroll_run.data_pagamento; tax_allocation_detail.aliquota_terceiros;
--      folha.request_context_config (grupos de principal aceitos pelo contexto).
--   2. Parâmetros por vigência (payroll_parameter) e tabelas de 2024 e 2025
--      (tax_table_version): só valores que o parecer traz com ato normativo citado.
--   3. calc_inss (arredondamento por parâmetro, coerência teto x última faixa);
--      calc_inss_segurado (por categoria); calc_fgts (por categoria, sem a "multa" de 40%
--      sobre o depósito do mês); calc_irrf (rendimento bruto, dependentes, desconto
--      simplificado, data de pagamento, redução da Lei 15.270/2025 por parâmetro);
--      calc_irrf_separado passa a usar a mesma apuração; calc_salario_familia;
--      calc_encargos_patronais; run_payroll_employee.
--   4. Policies da 0014 e da 0018 recriadas com (SELECT folha.current_account_id()).
--   5. request_context_account_id() confere o grupo do principal contra a configuração.
--   6. ACL das funções e da tabela nova.
--
-- NÃO altera as migrations 0014 a 0024. Assinaturas removidas: calc_irrf(numeric, integer,
-- boolean, date), calc_fgts com a coluna fgts_multa_rescisoria e run_payroll_employee(uuid, uuid)
-- (a nova aceita os mesmos dois argumentos). Quem chama calc_irrf pela assinatura antiga quebra.
--
-- NÃO APLICAR EM PRODUÇÃO sem conferir o que está a_validar e sem a dependência do
-- dnex-gestao registrada na 0024 (grupo de principal da Folha).
-- Reversão: 0025_folha_motor_mensal.supabase.down.sql.
BEGIN;

SET LOCAL lock_timeout = '5s';

-- ---------------------------------------------------------------------------
-- 0. Pré-condições
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  -- payroll_parameter e tax_table_version têm RLS com FORCE: sem ignorar RLS, o UPDATE
  -- abaixo afetaria zero linhas em silêncio e o INSERT falharia na policy.
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles
                  WHERE rolname = current_user AND (rolsuper OR rolbypassrls)) THEN
    RAISE EXCEPTION '0025: o papel % não é superusuário nem tem BYPASSRLS; os parâmetros e as tabelas por vigência não seriam gravados', current_user
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NOT has_table_privilege(current_user, 'folha.tax_table_version', 'UPDATE')
     OR NOT has_table_privilege(current_user, 'folha.payroll_parameter', 'UPDATE') THEN
    RAISE EXCEPTION '0025: o papel % não pode alterar folha.tax_table_version ou folha.payroll_parameter (precisa ser o dono ou superusuário)', current_user
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF EXISTS (SELECT 1 FROM folha.payroll_result GROUP BY run_id, contract_id HAVING count(*) > 1) THEN
    RAISE EXCEPTION '0025: há contrato com mais de um resultado na mesma folha; resolva antes de criar o índice único'
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  IF to_regprocedure('folha.get_param(text, date)') IS NULL
     OR to_regclass('folha.tax_allocation_detail') IS NULL THEN
    RAISE EXCEPTION '0025: faltam objetos das migrations 0023 e 0024'
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
END
$$;

-- ===========================================================================
-- 1. Cadastro
-- ===========================================================================

-- 1.1 Categoria de contribuinte individual (sócio ou administrador com pró-labore).
--     O CHECK da 0014 só aceitava clt, pj, estagio e aprendiz (achado E-13). Os códigos de
--     categoria do eSocial continuam fora: a validar na fonte.
DO $$
DECLARE
  v_nome text;
BEGIN
  FOR v_nome IN
    SELECT con.conname
      FROM pg_catalog.pg_constraint con
     WHERE con.conrelid = 'folha.employment_contract'::regclass
       AND con.contype = 'c'
       AND pg_catalog.pg_get_constraintdef(con.oid) LIKE '%regime_trabalho%'
  LOOP
    EXECUTE format('ALTER TABLE folha.employment_contract DROP CONSTRAINT %I', v_nome);
  END LOOP;
END
$$;
ALTER TABLE folha.employment_contract
  ADD CONSTRAINT employment_contract_regime_trabalho_check
    CHECK (regime_trabalho IN ('clt', 'pj', 'estagio', 'aprendiz', 'contribuinte_individual'));

-- 1.2 Data de pagamento da folha: o IRRF segue a data do pagamento, não a competência (E-16d).
ALTER TABLE folha.payroll_run
  ADD COLUMN data_pagamento date;

-- 1.3 Alíquota de terceiros da lotação (fração; 0,058 = 5,8%). Entra pelo cadastro, com
--     vigência; a tabela por FPAS e código de terceiros está a validar na fonte e não é semeada.
ALTER TABLE folha.tax_allocation_detail
  ADD COLUMN aliquota_terceiros numeric(6,4)
    CONSTRAINT tax_allocation_detail_aliquota_terceiros_check
      CHECK (aliquota_terceiros >= 0 AND aliquota_terceiros <= 1);

-- 1.3.1 Um resultado por contrato em cada folha (a checagem da função sozinha não segura duas
--       chamadas simultâneas).
CREATE UNIQUE INDEX payroll_result_run_contract_key ON folha.payroll_result (run_id, contract_id);

-- 1.4 Grupos de principal aceitos pelo contexto da Folha (seção 5).
--     principal_groups_permitidos NULL = sem restrição de grupo (estado atual: o dnex-gestao
--     ainda não tem grupo da Folha); lista = só esses grupos; lista vazia = nenhum.
--     Sem a linha, request_context_account_id() devolve NULL (falha fechada).
CREATE TABLE folha.request_context_config (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  principal_groups_permitidos text[],
  observacao text,
  updated_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO folha.request_context_config (singleton, principal_groups_permitidos, observacao)
VALUES (true, NULL, 'Sem restrição de grupo até o dnex-gestao criar o grupo de principal da Folha; então gravar aqui o nome do grupo.');
ALTER TABLE folha.request_context_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE folha.request_context_config FORCE ROW LEVEL SECURITY;
CREATE POLICY request_context_config_leitura ON folha.request_context_config FOR SELECT USING (true);

-- ===========================================================================
-- 2. Parâmetros e tabelas por vigência
--    Só entra o que o parecer traz com ato citado. Datas inclusivas.
-- ===========================================================================
INSERT INTO folha.payroll_parameter (chave, valor, vigencia_inicio, vigencia_fim, fonte_normativa, status_validacao, observacao) VALUES
  -- INSS do segurado
  ('inss_arredondamento_metodo',               1,        '2024-01-01', NULL,         'Parecer INSS/FGTS E-02: critério de centavos do eSocial (S-5001) não lido',         'a_validar', '1 = soma exata das faixas, arredondada meio para cima uma vez no total; 2 = truncada na segunda casa [semeado pela 0025]'),
  ('inss_ci_retencao_aliquota',                0.11,     '2024-01-01', NULL,         'Lei 10.666/2003 art. 4º; Lei 8.212/1991 arts. 21 e 30 § 4º',                        'validado',  'Retenção do contribuinte individual a serviço de empresa, até o teto. Optante do Simples, entidade isenta, salário de contribuição mínimo e múltiplas fontes: a validar [semeado pela 0025]'),
  -- FGTS
  ('fgts_aliquota_empregado',                  0.08,     '2024-01-01', NULL,         'Lei 8.036/1990 art. 15, caput',                                                     'validado',  'Depósito mensal do empregado. Início de vigência = início da cobertura do motor, não da lei [semeado pela 0025]'),
  ('fgts_aliquota_aprendiz',                   0.02,     '2024-01-01', NULL,         'Lei 8.036/1990 art. 15 § 7º',                                                       'validado',  'Depósito mensal do aprendiz. Início de vigência = início da cobertura do motor, não da lei [semeado pela 0025]'),
  -- Contribuição patronal
  ('cpp_aliquota_empresa',                     0.20,     '2024-01-01', NULL,         'Lei 8.212/1991 art. 22, I e III',                                                   'validado',  'Regra geral; a lotação pode informar percentual próprio (tax_allocation_detail.percentual_patronal) [semeado pela 0025]'),
  ('cprb_fator_cpp_folha',                     0.25,     '2025-01-01', '2025-12-31', 'Lei 12.546/2011 art. 9º-A, I (Lei 14.973/2024)',                                    'validado',  'Fração das alíquotas do art. 22, I e III, da Lei 8.212 devida sobre a folha pelo optante da CPRB [semeado pela 0025]'),
  ('cprb_fator_cpp_folha',                     0.50,     '2026-01-01', '2026-12-31', 'Lei 12.546/2011 art. 9º-A, II (Lei 14.973/2024)',                                   'validado',  'Fração das alíquotas do art. 22, I e III, da Lei 8.212 devida sobre a folha pelo optante da CPRB [semeado pela 0025]'),
  ('cprb_fator_cpp_folha',                     0.75,     '2027-01-01', '2027-12-31', 'Lei 12.546/2011 art. 9º-A, III (Lei 14.973/2024)',                                  'validado',  'Fração das alíquotas do art. 22, I e III, da Lei 8.212 devida sobre a folha pelo optante da CPRB [semeado pela 0025]'),
  ('cprb_folha_exclui_13o',                    1,        '2025-01-01', '2027-12-31', 'Lei 12.546/2011 art. 9º-A § 1º (Lei 14.973/2024)',                                  'validado',  '1 = a parcela sobre a folha não incide sobre o 13º [semeado pela 0025]'),
  ('terceiros_incide_contribuinte_individual', 0,        '2024-01-01', NULL,         'Parecer INSS/FGTS CD-06 (IN RFB 2.110/2022 e anexos não lidos)',                    'a_validar', '0 = terceiros não incidem sobre pró-labore; 1 = incidem [semeado pela 0025]'),
  -- IRRF: redução da Lei 15.270/2025
  ('irrf_reducao_limite_isencao',              5000.00,  '2026-01-01', NULL,         'Lei 9.250/1995 art. 3º-A (Lei 15.270/2025)',                                        'validado',  'Rendimento tributável mensal até este valor: redução até zerar o imposto, limitada ao teto [semeado pela 0025]'),
  ('irrf_reducao_teto',                        312.89,   '2026-01-01', NULL,         'Lei 9.250/1995 art. 3º-A (Lei 15.270/2025)',                                        'validado',  'Teto da redução na faixa até o limite de isenção [semeado pela 0025]'),
  ('irrf_reducao_limite_parcial',              7350.00,  '2026-01-01', NULL,         'Lei 9.250/1995 art. 3º-A (Lei 15.270/2025)',                                        'validado',  'Acima deste rendimento tributável mensal não há redução [semeado pela 0025]'),
  -- Salário-família (faixa única; vigência fechada no ano: a portaria do ano seguinte traz o novo valor)
  ('salario_familia_cota',                     62.04,    '2024-01-01', '2024-12-31', 'Portaria Interministerial MPS/MF nº 2, de 11/01/2024 (DOU 12/01/2024), art. 4º',    'validado',  'Cota por filho ou equiparado [semeado pela 0025]'),
  ('salario_familia_remuneracao_ate',          1819.26,  '2024-01-01', '2024-12-31', 'Portaria Interministerial MPS/MF nº 2, de 11/01/2024 (DOU 12/01/2024), art. 4º',    'validado',  'Remuneração mensal máxima para ter direito [semeado pela 0025]'),
  ('salario_familia_cota',                     65.00,    '2025-01-01', '2025-12-31', 'Portaria Interministerial MPS/MF nº 6, de 10/01/2025 (DOU 13/01/2025), art. 4º',    'validado',  'Cota por filho ou equiparado [semeado pela 0025]'),
  ('salario_familia_remuneracao_ate',          1906.04,  '2025-01-01', '2025-12-31', 'Portaria Interministerial MPS/MF nº 6, de 10/01/2025 (DOU 13/01/2025), art. 4º',    'validado',  'Remuneração mensal máxima para ter direito [semeado pela 0025]'),
  ('salario_familia_cota',                     67.54,    '2026-01-01', '2026-12-31', 'Portaria Interministerial MPS/MF nº 13, de 09/01/2026 (DOU 12/01/2026), art. 4º',   'validado',  'Cota por filho ou equiparado [semeado pela 0025]'),
  ('salario_familia_remuneracao_ate',          1980.38,  '2026-01-01', '2026-12-31', 'Portaria Interministerial MPS/MF nº 13, de 09/01/2026 (DOU 12/01/2026), art. 4º',   'validado',  'Remuneração mensal máxima para ter direito [semeado pela 0025]')
-- DO NOTHING: reaplicar não desfaz valor nem validação registrados depois.
ON CONFLICT (chave, vigencia_inicio) DO NOTHING;

-- Coeficientes da redução: semeados pela 0023 como a_validar; o parecer de INSS/FGTS os
-- conferiu no texto da lei. O critério de aferição no IRRF em separado segue a_validar
-- (alcance nas férias em separado não conferido).
UPDATE folha.payroll_parameter
   SET status_validacao = 'validado',
       observacao = 'Redução = a - b x rendimento tributável mensal; conferido no parecer de INSS/FGTS de 15/11/2026 [validado pela 0025]',
       updated_at = now()
 WHERE chave IN ('irrf_redutor_coef_a', 'irrf_redutor_coef_b')
   AND vigencia_inicio = '2026-01-01'
   AND status_validacao = 'a_validar';

UPDATE folha.payroll_parameter
   SET observacao = '1 = redução aferida pelo rendimento tributável bruto; 0 = pela base após deduções. Vale só para o IRRF em separado (13º, férias, rescisão); na folha mensal o critério é o rendimento bruto (Lei 9.250/1995 art. 3º-A). Férias em separado: a validar',
       updated_at = now()
 WHERE chave = 'irrf_redutor_referencia_bruto'
   AND vigencia_inicio = '2026-01-01';

-- Tabelas de 2024 e 2025. source_hash é rótulo, não hash do documento (o parecer não traz o
-- hash dos PDFs); o ato fica dentro do JSON.
INSERT INTO folha.tax_table_version (tipo, vigencia_inicio, vigencia_fim, tabela_json, source_url, source_hash, captured_at) VALUES
  ('salario_minimo', '2024-01-01', '2024-12-31',
   '{"valor": 1412.00, "moeda": "BRL",
     "ato": "Portaria Interministerial MPS/MF nº 2, de 11/01/2024 (DOU 12/01/2024), art. 2º (salário de contribuição mínimo); Decreto nº 11.864/2023 citado no preâmbulo, texto não lido"}'::jsonb,
   'https://www.gov.br/previdencia/pt-br/assuntos/rpps/legislacao-dos-rpps/2025/PortariaInterministerialMPSMFn2de11jan2024Revogada.pdf',
   'rotulo:parecer-inss-fgts-encargos-20261115:salario_minimo_2024', '2026-11-15T00:00:00Z'),
  ('salario_minimo', '2025-01-01', '2025-12-31',
   '{"valor": 1518.00, "moeda": "BRL",
     "ato": "Portaria Interministerial MPS/MF nº 6, de 10/01/2025 (DOU 13/01/2025), art. 2º (salário de contribuição mínimo); Decreto nº 12.342/2024 citado no preâmbulo, texto não lido"}'::jsonb,
   'https://www.gov.br/previdencia/pt-br/assuntos/rpps/legislacao-dos-rpps/2025/PortariaInterministerialMPSMFn6de10jan2025.pdf',
   'rotulo:parecer-inss-fgts-encargos-20261115:salario_minimo_2025', '2026-11-15T00:00:00Z'),
  ('inss', '2024-01-01', '2024-12-31',
   '{"teto": 7786.02,
     "faixas": [
       {"limite_inferior": 0, "limite_superior": 1412.00, "aliquota": 0.075},
       {"limite_inferior": 1412.01, "limite_superior": 2666.68, "aliquota": 0.09},
       {"limite_inferior": 2666.69, "limite_superior": 4000.03, "aliquota": 0.12},
       {"limite_inferior": 4000.04, "limite_superior": 7786.02, "aliquota": 0.14}
     ],
     "tipo_calculo": "progressivo_por_faixa",
     "ato": "Portaria Interministerial MPS/MF nº 2, de 11/01/2024 (DOU 12/01/2024), arts. 2º e 7º e Anexo II"}'::jsonb,
   'https://www.gov.br/previdencia/pt-br/assuntos/rpps/legislacao-dos-rpps/2025/PortariaInterministerialMPSMFn2de11jan2024Revogada.pdf',
   'rotulo:parecer-inss-fgts-encargos-20261115:inss_2024', '2026-11-15T00:00:00Z'),
  ('inss', '2025-01-01', '2025-12-31',
   '{"teto": 8157.41,
     "faixas": [
       {"limite_inferior": 0, "limite_superior": 1518.00, "aliquota": 0.075},
       {"limite_inferior": 1518.01, "limite_superior": 2793.88, "aliquota": 0.09},
       {"limite_inferior": 2793.89, "limite_superior": 4190.83, "aliquota": 0.12},
       {"limite_inferior": 4190.84, "limite_superior": 8157.41, "aliquota": 0.14}
     ],
     "tipo_calculo": "progressivo_por_faixa",
     "ato": "Portaria Interministerial MPS/MF nº 6, de 10/01/2025 (DOU 13/01/2025), arts. 2º e 7º e Anexo II"}'::jsonb,
   'https://www.gov.br/previdencia/pt-br/assuntos/rpps/legislacao-dos-rpps/2025/PortariaInterministerialMPSMFn6de10jan2025.pdf',
   'rotulo:parecer-inss-fgts-encargos-20261115:inss_2025', '2026-11-15T00:00:00Z'),
  -- IRRF: a tabela de maio/2023 a janeiro/2024 NÃO entra (ato originário a validar na fonte).
  ('irrf', '2024-02-01', '2025-04-30',
   '{"faixas": [
       {"limite_inferior": 0, "limite_superior": 2259.20, "aliquota": 0, "parcela_deduzir": 0},
       {"limite_inferior": 2259.21, "limite_superior": 2826.65, "aliquota": 0.075, "parcela_deduzir": 169.44},
       {"limite_inferior": 2826.66, "limite_superior": 3751.05, "aliquota": 0.15, "parcela_deduzir": 381.44},
       {"limite_inferior": 3751.06, "limite_superior": 4664.68, "aliquota": 0.225, "parcela_deduzir": 662.77},
       {"limite_inferior": 4664.69, "limite_superior": null, "aliquota": 0.275, "parcela_deduzir": 896.00}
     ],
     "deducao_dependente_mensal": 189.59,
     "desconto_simplificado_mensal": 564.80,
     "ato": "Lei nº 14.848, de 01/05/2024; dedução por dependente: Lei 9.250/1995, art. 4º, III"}'::jsonb,
   'https://www.gov.br/receitafederal/pt-br/assuntos/meu-imposto-de-renda/tabelas/copy_of_2024',
   'rotulo:parecer-inss-fgts-encargos-20261115:irrf_fev2024_abr2025', '2026-11-15T00:00:00Z'),
  ('irrf', '2025-05-01', '2025-12-31',
   '{"faixas": [
       {"limite_inferior": 0, "limite_superior": 2428.80, "aliquota": 0, "parcela_deduzir": 0},
       {"limite_inferior": 2428.81, "limite_superior": 2826.65, "aliquota": 0.075, "parcela_deduzir": 182.16},
       {"limite_inferior": 2826.66, "limite_superior": 3751.05, "aliquota": 0.15, "parcela_deduzir": 394.16},
       {"limite_inferior": 3751.06, "limite_superior": 4664.68, "aliquota": 0.225, "parcela_deduzir": 675.49},
       {"limite_inferior": 4664.69, "limite_superior": null, "aliquota": 0.275, "parcela_deduzir": 908.73}
     ],
     "deducao_dependente_mensal": 189.59,
     "desconto_simplificado_mensal": 607.20,
     "ato": "Lei nº 15.191, de 11/08/2025; dedução por dependente: Lei 9.250/1995, art. 4º, III"}'::jsonb,
   'https://www.gov.br/receitafederal/pt-br/assuntos/meu-imposto-de-renda/tabelas/2025',
   'rotulo:parecer-inss-fgts-encargos-20261115:irrf_mai2025_dez2025', '2026-11-15T00:00:00Z')
ON CONFLICT (tipo, vigencia_inicio) DO NOTHING;

-- Salário-família de 2026 em tax_table_version: a 0015 gravou nulos e uma correção posterior
-- (fora deste repositório) gravou limites que não existem na portaria (E-14). O motor lê
-- payroll_parameter; esta linha é corrigida para não sobrar uma segunda fonte errada.
DO $$
DECLARE
  v_linhas integer;
BEGIN
  UPDATE folha.tax_table_version
     SET tabela_json = '{"cota": 67.54, "remuneracao_ate": 1980.38, "faixa_unica": true,
                         "ato": "Portaria Interministerial MPS/MF nº 13, de 09/01/2026 (DOU 12/01/2026), art. 4º",
                         "fonte_do_motor": "folha.payroll_parameter (salario_familia_cota, salario_familia_remuneracao_ate)"}'::jsonb,
         source_url = 'https://www.gov.br/previdencia/pt-br/assuntos/rpps/documentos/PortariaInterministerialMPSMF13de9dejaneirode2026.pdf',
         source_hash = 'rotulo:parecer-inss-fgts-encargos-20261115:salario_familia_2026'
   WHERE tipo = 'salario_familia' AND vigencia_inicio = '2026-01-01';
  GET DIAGNOSTICS v_linhas = ROW_COUNT;
  IF v_linhas <> 1 THEN
    RAISE EXCEPTION '0025: esperava corrigir 1 linha de salário-família de 2026 em tax_table_version; corrigiu %', v_linhas
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
END
$$;

-- ===========================================================================
-- 3. Funções do motor
-- ===========================================================================

-- 3.1 Arredondamento do INSS do segurado (E-02). O critério oficial está a validar; o método
--     padrão é o do parecer (meio para cima, uma vez no total).
CREATE FUNCTION folha.arredondar_inss(p_valor numeric, p_data date) RETURNS numeric
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_metodo numeric;
BEGIN
  v_metodo := folha.get_param('inss_arredondamento_metodo', p_data);
  IF v_metodo = 1 THEN
    RETURN round(p_valor, 2);
  ELSIF v_metodo = 2 THEN
    RETURN trunc(p_valor, 2);
  END IF;
  RAISE EXCEPTION 'Parâmetro inss_arredondamento_metodo com valor desconhecido: %', v_metodo;
END;
$$;

-- 3.2 calc_inss: progressivo por faixa contínua (0023), teto, arredondamento por parâmetro e
--     conferência de coerência entre o teto e a última faixa (E-05).
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

-- 3.3 INSS do segurado por categoria (E-03, E-13).
--     clt e aprendiz: tabela progressiva. contribuinte_individual (pró-labore): alíquota de
--     retenção sobre a remuneração limitada ao teto, sem tabela progressiva. estagio e pj:
--     não há desconto de INSS de segurado na folha.
CREATE FUNCTION folha.calc_inss_segurado(
  p_base numeric,
  p_regime_trabalho text,
  p_competencia date
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
  v_inss record;
  v_teto numeric;
  v_vig date;
  v_aliq numeric;
  v_bruto numeric;
BEGIN
  IF p_competencia IS NULL THEN
    RAISE EXCEPTION 'calc_inss_segurado: competência obrigatória';
  END IF;
  IF p_base IS NULL OR p_base < 0 THEN
    RAISE EXCEPTION 'calc_inss_segurado: base de contribuição inválida: %', p_base;
  END IF;

  IF p_regime_trabalho IN ('estagio', 'pj') THEN
    valor_inss := 0;
    aliquota_efetiva := 0;
    metodo := 'nao_sujeito';
    base_contribuicao := 0;
    tabela_vigencia := NULL;
    pendencias := CASE WHEN p_regime_trabalho = 'estagio'
                       THEN ARRAY['a_validar:estagio_nao_incidencia_lei_11788']
                       ELSE ARRAY[]::text[] END;
    RETURN NEXT;
    RETURN;
  END IF;

  IF p_regime_trabalho IS NULL
     OR p_regime_trabalho NOT IN ('clt', 'aprendiz', 'contribuinte_individual') THEN
    RAISE EXCEPTION 'calc_inss_segurado: categoria desconhecida: %', COALESCE(p_regime_trabalho, 'NULL');
  END IF;

  SELECT (t.tabela_json->>'teto')::numeric, t.vigencia_inicio
    INTO v_teto, v_vig
    FROM folha.tax_table_version t
   WHERE t.tipo = 'inss'
     AND t.vigencia_inicio <= p_competencia
     AND (t.vigencia_fim IS NULL OR t.vigencia_fim >= p_competencia)
   ORDER BY t.vigencia_inicio DESC
   LIMIT 1;
  IF v_teto IS NULL THEN
    RAISE EXCEPTION 'Tabela INSS não encontrada para competência %', p_competencia;
  END IF;

  base_contribuicao := LEAST(p_base, v_teto);
  tabela_vigencia := v_vig;

  IF p_regime_trabalho = 'contribuinte_individual' THEN
    v_aliq := folha.get_param('inss_ci_retencao_aliquota', p_competencia);
    v_bruto := base_contribuicao * v_aliq;
    valor_inss := folha.arredondar_inss(v_bruto, p_competencia);
    metodo := 'contribuinte_individual_retencao';
    aliquota_efetiva := CASE WHEN p_base > 0 THEN round(v_bruto / p_base, 4) ELSE 0 END;
    pendencias := folha.params_a_validar(ARRAY['inss_arredondamento_metodo', 'inss_ci_retencao_aliquota'], p_competencia);
  ELSE
    SELECT * INTO v_inss FROM folha.calc_inss(p_base, p_competencia);
    valor_inss := v_inss.valor_inss;
    aliquota_efetiva := v_inss.aliquota_efetiva;
    metodo := 'progressivo_por_faixa';
    pendencias := folha.params_a_validar(ARRAY['inss_arredondamento_metodo'], p_competencia);
  END IF;
  RETURN NEXT;
END;
$$;

-- 3.4 calc_fgts: alíquota por categoria (E-08) e sem a "multa" de 40% sobre o depósito do
--     mês (E-09: não é grandeza legal; a multa rescisória é de calc_rescisao, sobre o extrato).
--     estagio, pj e contribuinte_individual: sem depósito (diretor não empregado só por
--     deliberação da empresa, não modelada).
DROP FUNCTION folha.calc_fgts(numeric, text, date);
CREATE FUNCTION folha.calc_fgts(
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

-- 3.5 Apuração única do IRRF (E-16, E-16a, E-16b, E-16d).
--     p_modo = 'mensal': dedução = a maior entre as deduções legais e o desconto
--       simplificado; a redução da Lei 15.270/2025 é aferida pelo rendimento tributável bruto.
--     p_modo = 'separado' (13º, férias, rescisão): sem desconto simplificado (não conferido
--       para a tributação em separado); a grandeza da redução segue o parâmetro
--       irrf_redutor_referencia_bruto (a_validar).
--     Tabela, dedução por dependente e desconto simplificado vêm de tax_table_version pela
--     DATA DE PAGAMENTO; os limites e coeficientes da redução vêm de payroll_parameter.
--     O teto da redução é explícito nos dois modos.
CREATE FUNCTION folha.irrf_apurar(
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

-- 3.6 calc_irrf (folha mensal). A assinatura antiga recebia a base já líquida de INSS e a
--     competência; a nova recebe o rendimento tributável bruto, as deduções em separado e a
--     data de pagamento, sem valor padrão para a data.
DROP FUNCTION folha.calc_irrf(numeric, integer, boolean, date);
CREATE FUNCTION folha.calc_irrf(
  p_rendimento_tributavel numeric,
  p_inss_retido numeric,
  p_num_dependentes integer,
  p_data_pagamento date,
  p_outras_deducoes numeric DEFAULT 0
) RETURNS TABLE (
  valor_irrf numeric,
  aliquota_efetiva numeric,
  desconto_aplicado text,
  redutor_lei_15270 numeric,
  tabela_vigencia date,
  tabela_hash text,
  base_calculo numeric,
  imposto_tabela numeric,
  pendencias text[]
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_a record;
BEGIN
  IF p_rendimento_tributavel IS NULL OR p_rendimento_tributavel < 0 THEN
    RAISE EXCEPTION 'calc_irrf: rendimento tributável inválido: %', COALESCE(p_rendimento_tributavel::text, 'NULL');
  END IF;
  IF COALESCE(p_inss_retido, 0) < 0 OR COALESCE(p_outras_deducoes, 0) < 0 THEN
    RAISE EXCEPTION 'calc_irrf: deduções não podem ser negativas';
  END IF;

  SELECT * INTO v_a
    FROM folha.irrf_apurar(p_rendimento_tributavel,
                           COALESCE(p_inss_retido, 0) + COALESCE(p_outras_deducoes, 0),
                           p_num_dependentes, p_data_pagamento, 'mensal');

  valor_irrf := v_a.valor_irrf;
  aliquota_efetiva := CASE WHEN COALESCE(p_rendimento_tributavel, 0) > 0
                           THEN round(v_a.valor_irrf / p_rendimento_tributavel, 4)
                           ELSE 0 END;
  desconto_aplicado := v_a.deducao_aplicada;
  redutor_lei_15270 := round(v_a.reducao, 2);
  tabela_vigencia := v_a.tabela_vigencia;
  tabela_hash := v_a.tabela_hash;
  base_calculo := v_a.base_calculo;
  imposto_tabela := v_a.imposto_tabela;
  pendencias := CASE WHEN v_a.deducao_aplicada = 'simplificado'
                     THEN ARRAY['a_validar:irrf_simplificado_pela_fonte_pagadora_ato_rfb']
                     ELSE ARRAY[]::text[] END;
  RETURN NEXT;
END;
$$;

-- 3.7 calc_irrf_separado (0023): mesma assinatura e mesmo retorno; passa a usar a apuração
--     única. Muda em relação à 0023: o teto da redução (312,89) fica explícito; antes, até o
--     limite de isenção a redução era o imposto inteiro.
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

-- 3.8 Salário-família (E-14, E-15). Faixa única: remuneração até o limite dá direito a uma
--     cota por filho elegível. A fração de dias (admissão e demissão) é informada por quem
--     chama: o divisor está a validar na fonte e não é presumido aqui.
CREATE FUNCTION folha.calc_salario_familia(
  p_remuneracao numeric,
  p_num_filhos integer,
  p_competencia date,
  p_fracao_dias numeric DEFAULT 1
) RETURNS TABLE (
  valor numeric,
  cota numeric,
  remuneracao_limite numeric,
  tem_direito boolean,
  pendencias text[]
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
BEGIN
  IF p_competencia IS NULL THEN
    RAISE EXCEPTION 'calc_salario_familia: competência obrigatória';
  END IF;
  IF p_remuneracao IS NULL OR p_remuneracao < 0 THEN
    RAISE EXCEPTION 'calc_salario_familia: remuneração inválida: %', p_remuneracao;
  END IF;
  IF p_num_filhos IS NULL OR p_num_filhos < 0 THEN
    RAISE EXCEPTION 'calc_salario_familia: número de filhos inválido: %', p_num_filhos;
  END IF;
  IF p_fracao_dias IS NULL OR p_fracao_dias <= 0 OR p_fracao_dias > 1 THEN
    RAISE EXCEPTION 'calc_salario_familia: fração de dias deve estar entre 0 (exclusive) e 1: %', p_fracao_dias;
  END IF;

  cota := folha.get_param('salario_familia_cota', p_competencia);
  remuneracao_limite := folha.get_param('salario_familia_remuneracao_ate', p_competencia);
  tem_direito := p_remuneracao <= remuneracao_limite;
  valor := CASE WHEN tem_direito THEN round(cota * p_num_filhos * p_fracao_dias, 2) ELSE 0 END;

  pendencias := folha.params_a_validar(
    ARRAY['salario_familia_cota', 'salario_familia_remuneracao_ate'], p_competencia);
  IF valor > 0 THEN
    pendencias := pendencias || ARRAY['a_validar:salario_familia_documentos_de_elegibilidade'];
  END IF;
  IF p_fracao_dias <> 1 THEN
    pendencias := pendencias || ARRAY['a_validar:salario_familia_divisor_da_fracao_de_dias'];
  END IF;
  RETURN NEXT;
END;
$$;

-- 3.9 Encargos patronais do contrato por lotação tributária (E-11, E-12).
--     Lê o cadastro da 0024: regime do empregador vigente (employer_regime), rateio do
--     contrato (contract_tax_allocation), enquadramento da lotação (tax_allocation_detail) e
--     FAP do estabelecimento (establishment_fap). Data de referência das vigências: a
--     competência informada. Falta de cadastro levanta exceção; nunca devolve nulo nem zero
--     por omissão.
--       Simples com CPP no DAS: patronal, RAT e terceiros zero (LC 123/2006 art. 13, VI e § 3º).
--       Simples com CPP fora do DAS (Anexo IV): patronal e RAT; terceiros zero.
--       Lucro real ou presumido: patronal, RAT x FAP e terceiros.
--       Optante da CPRB: patronal x fator da transição, sem a parcela do 13º; RAT e terceiros
--         integrais. Só vale para empresa integralmente desonerada (pendência devolvida).
--       Contribuinte individual: só a patronal; sem RAT; terceiros conforme parâmetro a_validar.
--       Estagiário: sem encargos (fundamento a validar). PJ: não é da folha.
--       Simples concomitante e demais regimes: exceção (regra não implementada).
--     Arredondamento por contrato e lotação. A totalização oficial é por estabelecimento e
--     lotação sobre a soma das bases: com mais de um trabalhador na lotação a soma dos valores
--     por contrato pode diferir em centavos do total apurado sobre a soma.
CREATE FUNCTION folha.calc_encargos_patronais(
  p_contract_id uuid,
  p_competencia date,
  p_base numeric,
  p_base_13 numeric DEFAULT 0
) RETURNS TABLE (
  lotacao_id uuid,
  estabelecimento_id uuid,
  percentual_rateio numeric,
  base_rateada numeric,
  regime text,
  criterio text,
  aliq_patronal numeric,
  inss_patronal numeric,
  aliq_rat numeric,
  fap_aplicado numeric,
  rat numeric,
  aliq_terceiros numeric,
  terceiros numeric,
  pendencias text[]
)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_conta uuid;
  v_employer uuid;
  v_categoria text;
  v_reg record;
  v_lot record;
  v_det record;
  v_tem_det boolean;
  v_ci boolean;
  v_fator_cpp numeric;
  v_exclui_13 boolean := false;
  v_usa_rat boolean;
  v_usa_terc boolean;
  v_pend text[] := ARRAY[]::text[];
  v_chaves text[] := ARRAY[]::text[];
  v_total integer;
  v_i integer := 0;
  v_acum numeric := 0;
  v_acum_13 numeric := 0;
  v_base_13 numeric := COALESCE(p_base_13, 0);
  v_b numeric;
  v_b13 numeric;
  v_aliq_base numeric;
BEGIN
  IF p_competencia IS NULL THEN
    RAISE EXCEPTION 'calc_encargos_patronais: competência obrigatória';
  END IF;
  IF p_base IS NULL OR p_base < 0 THEN
    RAISE EXCEPTION 'calc_encargos_patronais: base inválida: %', p_base;
  END IF;
  IF v_base_13 < 0 OR v_base_13 > p_base THEN
    RAISE EXCEPTION 'calc_encargos_patronais: a parcela de 13º (%) deve estar entre zero e a base (%)', v_base_13, p_base;
  END IF;

  SELECT c.account_id, c.employer_id, c.regime_trabalho
    INTO v_conta, v_employer, v_categoria
    FROM folha.employment_contract c
   WHERE c.contract_id = p_contract_id
     AND c.account_id = folha.current_account_id();
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Contrato % não encontrado', p_contract_id;
  END IF;

  IF v_categoria = 'pj' THEN
    RAISE EXCEPTION 'calc_encargos_patronais: categoria pj não é processada na folha';
  END IF;
  IF v_categoria = 'estagio' THEN
    lotacao_id := NULL;
    estabelecimento_id := NULL;
    percentual_rateio := 100;
    base_rateada := p_base;
    regime := NULL;
    criterio := 'estagio_sem_encargos';
    aliq_patronal := 0;  inss_patronal := 0;
    aliq_rat := 0;       fap_aplicado := NULL;  rat := 0;
    aliq_terceiros := 0; terceiros := 0;
    pendencias := ARRAY['a_validar:estagio_nao_incidencia_lei_11788'];
    RETURN NEXT;
    RETURN;
  END IF;
  IF v_categoria NOT IN ('clt', 'aprendiz', 'contribuinte_individual') THEN
    RAISE EXCEPTION 'calc_encargos_patronais: categoria desconhecida: %', v_categoria;
  END IF;
  v_ci := v_categoria = 'contribuinte_individual';

  IF v_employer IS NULL THEN
    RAISE EXCEPTION 'Contrato % sem empregador cadastrado: encargos patronais não podem ser calculados', p_contract_id;
  END IF;

  SELECT r.regime_tributario, r.simples_optante, r.simples_cpp, r.cprb_optante, r.cprb_percentual_reducao
    INTO v_reg
    FROM folha.employer_regime r
   WHERE r.account_id = v_conta
     AND r.employer_id = v_employer
     AND r.vigencia_inicio <= p_competencia
     AND (r.vigencia_fim IS NULL OR r.vigencia_fim >= p_competencia);
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Empregador % sem regime tributário vigente em %', v_employer, p_competencia;
  END IF;

  IF v_reg.simples_optante IS DISTINCT FROM (v_reg.regime_tributario = 'simples_nacional') THEN
    RAISE EXCEPTION 'Empregador % com cadastro incoerente em %: regime % e simples_optante %', v_employer, p_competencia, v_reg.regime_tributario, v_reg.simples_optante;
  END IF;
  IF v_reg.regime_tributario = 'simples_nacional' AND v_reg.cprb_optante THEN
    RAISE EXCEPTION 'Empregador % com cadastro incoerente em %: optante do Simples marcado como optante da CPRB', v_employer, p_competencia;
  END IF;

  IF v_reg.regime_tributario = 'simples_nacional' THEN
    IF v_reg.simples_cpp IS NULL THEN
      RAISE EXCEPTION 'Empregador % optante do Simples sem indicação de onde recolhe a contribuição patronal (simples_cpp) em %', v_employer, p_competencia;
    ELSIF v_reg.simples_cpp = 'no_das' THEN
      criterio := 'simples_cpp_no_das';
      v_fator_cpp := 0;  v_usa_rat := false;  v_usa_terc := false;
    ELSIF v_reg.simples_cpp = 'fora_do_das' THEN
      criterio := 'simples_cpp_fora_do_das';
      v_fator_cpp := 1;  v_usa_rat := true;   v_usa_terc := false;
      v_pend := v_pend || ARRAY['a_validar:fap_em_optante_do_simples_anexo_iv'];
    ELSE
      RAISE EXCEPTION 'Empregador %: Simples com atividades concomitantes (rateio da folha por receita) não tem regra implementada', v_employer;
    END IF;
    IF v_ci THEN
      v_pend := v_pend || ARRAY['a_validar:inss_ci_retencao_11_em_optante_do_simples'];
    END IF;
  ELSIF v_reg.regime_tributario IN ('lucro_real', 'lucro_presumido') THEN
    v_usa_rat := true;  v_usa_terc := true;
    IF v_reg.cprb_optante THEN
      criterio := 'cprb_transicao';
      v_fator_cpp := folha.get_param('cprb_fator_cpp_folha', p_competencia);
      v_exclui_13 := folha.get_param('cprb_folha_exclui_13o', p_competencia) = 1;
      v_chaves := v_chaves || ARRAY['cprb_fator_cpp_folha', 'cprb_folha_exclui_13o'];
      v_pend := v_pend || ARRAY['a_validar:cprb_empresa_integralmente_desonerada'];
      IF v_reg.cprb_percentual_reducao IS NOT NULL THEN
        v_pend := v_pend || ARRAY['pendencia:cprb_percentual_reducao_do_cadastro_nao_utilizado'];
      END IF;
    ELSE
      criterio := 'regra_geral';
      v_fator_cpp := 1;
    END IF;
  ELSE
    RAISE EXCEPTION 'Regime tributário % sem regra de encargos patronais implementada', v_reg.regime_tributario;
  END IF;

  IF v_ci THEN
    -- Contribuinte individual: sem RAT (Lei 8.212/1991 art. 22, II, alcança empregados e avulsos).
    v_usa_rat := false;
    IF v_usa_terc THEN
      v_usa_terc := folha.get_param('terceiros_incide_contribuinte_individual', p_competencia) = 1;
      v_chaves := v_chaves || ARRAY['terceiros_incide_contribuinte_individual'];
    END IF;
  END IF;

  SELECT count(*) INTO v_total
    FROM folha.contract_tax_allocation cta
   WHERE cta.account_id = v_conta
     AND cta.contract_id = p_contract_id
     AND cta.vigencia_inicio <= p_competencia
     AND (cta.vigencia_fim IS NULL OR cta.vigencia_fim >= p_competencia);
  IF v_total = 0 THEN
    RAISE EXCEPTION 'Contrato % sem lotação tributária (rateio) vigente em %', p_contract_id, p_competencia;
  END IF;

  regime := v_reg.regime_tributario;
  pendencias := v_pend || folha.params_a_validar(v_chaves, p_competencia);

  FOR v_lot IN
    SELECT cta.allocation_id AS a_id, cta.percentual AS pct, ta.establishment_id AS e_id
      FROM folha.contract_tax_allocation cta
      JOIN folha.tax_allocation ta
        ON ta.account_id = cta.account_id AND ta.allocation_id = cta.allocation_id
     WHERE cta.account_id = v_conta
       AND cta.contract_id = p_contract_id
       AND cta.vigencia_inicio <= p_competencia
       AND (cta.vigencia_fim IS NULL OR cta.vigencia_fim >= p_competencia)
     ORDER BY cta.percentual, cta.allocation_id
  LOOP
    v_i := v_i + 1;
    -- A última lotação leva o resíduo: a soma das bases rateadas é a base.
    IF v_i < v_total THEN
      v_b := round(p_base * v_lot.pct / 100, 2);
      v_b13 := round(v_base_13 * v_lot.pct / 100, 2);
    ELSE
      v_b := p_base - v_acum;
      v_b13 := v_base_13 - v_acum_13;
    END IF;
    v_acum := v_acum + v_b;
    v_acum_13 := v_acum_13 + v_b13;

    SELECT d.aliquota_rat AS d_rat, d.percentual_patronal AS d_patronal, d.aliquota_terceiros AS d_terc
      INTO v_det
      FROM folha.tax_allocation_detail d
     WHERE d.account_id = v_conta
       AND d.allocation_id = v_lot.a_id
       AND d.vigencia_inicio <= p_competencia
       AND (d.vigencia_fim IS NULL OR d.vigencia_fim >= p_competencia);
    v_tem_det := FOUND;
    IF NOT v_tem_det AND (v_usa_rat OR v_usa_terc) THEN
      RAISE EXCEPTION 'Lotação % sem enquadramento tributário vigente em %', v_lot.a_id, p_competencia;
    END IF;

    lotacao_id := v_lot.a_id;
    estabelecimento_id := v_lot.e_id;
    percentual_rateio := v_lot.pct;
    base_rateada := v_b;

    IF v_fator_cpp = 0 THEN
      aliq_patronal := 0;
    ELSE
      v_aliq_base := CASE WHEN v_tem_det THEN v_det.d_patronal END;
      IF v_aliq_base IS NULL THEN
        v_aliq_base := folha.get_param('cpp_aliquota_empresa', p_competencia);
      END IF;
      aliq_patronal := v_aliq_base * v_fator_cpp;
    END IF;
    inss_patronal := round((v_b - CASE WHEN v_exclui_13 THEN v_b13 ELSE 0 END) * aliq_patronal, 2);

    IF v_usa_rat THEN
      IF v_det.d_rat IS NULL THEN
        RAISE EXCEPTION 'Lotação % sem alíquota RAT vigente em %', v_lot.a_id, p_competencia;
      END IF;
      SELECT f.fap INTO fap_aplicado
        FROM folha.establishment_fap f
       WHERE f.account_id = v_conta
         AND f.establishment_id = v_lot.e_id
         AND f.vigencia_inicio <= p_competencia
         AND (f.vigencia_fim IS NULL OR f.vigencia_fim >= p_competencia);
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Estabelecimento % sem FAP vigente em %', v_lot.e_id, p_competencia;
      END IF;
      aliq_rat := v_det.d_rat;
      -- Produto exato de RAT x FAP; arredonda só o valor.
      rat := round(v_b * aliq_rat * fap_aplicado, 2);
    ELSE
      aliq_rat := 0;
      fap_aplicado := NULL;
      rat := 0;
    END IF;

    IF v_usa_terc THEN
      IF v_det.d_terc IS NULL THEN
        RAISE EXCEPTION 'Lotação % sem alíquota de terceiros vigente em %', v_lot.a_id, p_competencia;
      END IF;
      aliq_terceiros := v_det.d_terc;
      terceiros := round(v_b * aliq_terceiros, 2);
    ELSE
      aliq_terceiros := 0;
      terceiros := 0;
    END IF;

    RETURN NEXT;
  END LOOP;
END;
$$;

-- 3.10 run_payroll_employee: folha mensal de um contrato.
--      Mudanças em relação à 0016: contrato e folha da conta da sessão (antes não filtrava a
--      conta); categoria define INSS e FGTS; IRRF sobre o rendimento bruto, com dependentes,
--      desconto simplificado e data de pagamento; salário-família; encargos patronais
--      gravados (antes NULL). Base = salário contratual do mês cheio (rubricas, faltas,
--      proporcionalidade e múltiplos vínculos ficam para a fatia das rubricas).
--      Dependentes e filhos entram por argumento: não há cadastro de dependentes ainda.
DROP FUNCTION folha.run_payroll_employee(uuid, uuid);
CREATE FUNCTION folha.run_payroll_employee(
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

-- ===========================================================================
-- 4. Policies da 0014 e da 0018: conta resolvida uma vez por comando
--    (SELECT folha.current_account_id()) vira InitPlan; sem o SELECT a função era avaliada
--    a cada linha. Mesmo critério de isolamento; recriadas na mesma transação.
-- ===========================================================================
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
         USING (account_id = (SELECT folha.current_account_id()))
         WITH CHECK (account_id = (SELECT folha.current_account_id()))',
      v_par[1], v_par[2]);
  END LOOP;
END
$$;

DROP POLICY rubrica_isolamento ON folha.earning_deduction_code;
CREATE POLICY rubrica_isolamento ON folha.earning_deduction_code
  USING (account_id = (SELECT folha.current_account_id()) OR is_global = true)
  WITH CHECK (account_id = (SELECT folha.current_account_id()));

-- ===========================================================================
-- 5. Conta da sessão: grupo do principal conferido contra a configuração
--    Mesma validação da 0024; acrescenta a leitura de folha.request_context_config.
--    Hoje a configuração não restringe (NULL): o grupo da Folha ainda não existe no
--    dnex-gestao e não é inventado aqui.
-- ===========================================================================
CREATE OR REPLACE FUNCTION folha.request_context_account_id() RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, gestao_auth
SET row_security = on
AS $function$
DECLARE
  v_nonce_text text;
  v_txid bigint;
  v_contexto record;
  v_grupos text[];
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

  -- Grupos aceitos: sem a linha de configuração, ninguém; NULL, qualquer grupo que passe
  -- nas validações do gestao; lista, só os grupos listados.
  SELECT cfg.principal_groups_permitidos INTO v_grupos
    FROM folha.request_context_config AS cfg
   WHERE cfg.singleton;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  IF v_grupos IS NOT NULL
     AND (v_contexto.principal_group = ANY (v_grupos)) IS NOT TRUE THEN
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

-- ===========================================================================
-- 6. ACL
--    Tira o EXECUTE de todo papel que não seja o dono (inclusive default ACL e concessão
--    feita direto no banco) e concede só a quem já executava pelas 0016 e 0023:
--    worker e data_owner nas funções de cálculo; só o worker em run_payroll_employee.
--    As auxiliares internas (arredondar_inss, irrf_apurar) não são concedidas a ninguém.
-- ===========================================================================
DO $$
DECLARE
  v_item text[];
  v_papel text;
BEGIN
  FOREACH v_item SLICE 1 IN ARRAY ARRAY[
    ['folha.calc_inss(numeric, date)',                                   'dnex_gestao_folha_worker, dnex_gestao_data_owner'],
    ['folha.calc_inss_segurado(numeric, text, date)',                    'dnex_gestao_folha_worker, dnex_gestao_data_owner'],
    ['folha.calc_fgts(numeric, text, date)',                             'dnex_gestao_folha_worker, dnex_gestao_data_owner'],
    ['folha.calc_irrf(numeric, numeric, integer, date, numeric)',        'dnex_gestao_folha_worker, dnex_gestao_data_owner'],
    ['folha.calc_irrf_separado(numeric, numeric, integer, date)',        'dnex_gestao_folha_worker, dnex_gestao_data_owner'],
    ['folha.calc_salario_familia(numeric, integer, date, numeric)',      'dnex_gestao_folha_worker, dnex_gestao_data_owner'],
    ['folha.calc_encargos_patronais(uuid, date, numeric, numeric)',      'dnex_gestao_folha_worker, dnex_gestao_data_owner'],
    ['folha.request_context_account_id()',                               'dnex_gestao_folha_worker, dnex_gestao_data_owner'],
    ['folha.run_payroll_employee(uuid, uuid, integer, integer)',         'dnex_gestao_folha_worker'],
    ['folha.arredondar_inss(numeric, date)',                             ''],
    ['folha.irrf_apurar(numeric, numeric, integer, date, text)',         '']
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

  -- Configuração do contexto: só o dono lê e altera (a função que a lê é SECURITY DEFINER).
  FOR v_papel IN
    SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(r.rolname) END
      FROM pg_catalog.pg_class c
      CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) a
      LEFT JOIN pg_catalog.pg_roles r ON r.oid = a.grantee
     WHERE c.oid = 'folha.request_context_config'::regclass AND a.grantee <> c.relowner
     GROUP BY 1
  LOOP
    EXECUTE format('REVOKE ALL ON folha.request_context_config FROM %s', v_papel);
  END LOOP;
  REVOKE ALL ON folha.request_context_config FROM PUBLIC, anon, authenticated, service_role;
END
$$;

COMMIT;
