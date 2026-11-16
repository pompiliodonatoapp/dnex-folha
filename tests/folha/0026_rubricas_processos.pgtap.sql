-- DNEX Folha — fatia 4: rubricas, bases, camadas de regra, tipos de processo e trava de
-- fechamento (migrations 0026 e 0027).
--
-- Rótulos das asserções:
--   "CD-xx", "CT-xx", "Gxx" = caso dourado de parecer de DP de 15/11/2026 (INSS/FGTS/encargos,
--     13º e férias, rescisão), agora calculado pelo fluxo da folha e gravado por rubrica. Os
--     valores são os do parecer. Encargos patronais desses casos, quando o parecer não os traz,
--     estão marcados "derivado".
--   "derivado" = caso novo; a memória de cálculo está no comentário. RAT, FAP, terceiros,
--     divisor de horas, percentuais de regra e valores lançados são ENTRADAS do cenário, não
--     afirmação normativa.
--   "NEG" = caminho de recusa.
-- Executar após as migrations 0014–0027. Nada é persistido (ROLLBACK no final).
BEGIN;

-- Conta da sessão pelo protocolo do gestao_auth, como nos arquivos 0023 a 0025.
INSERT INTO gestao_finance.enterprise_scope_registry (account_id, legal_entity_id, branch_id)
VALUES ('e0000000-0000-0000-0000-000000000027', 'e1000000-0000-0000-0000-000000000027', 'e2000000-0000-0000-0000-000000000027');
-- Desde a migration 0028 a conta vem da claim da Folha (gestao_folha): o emissor registra a
-- asserção com as cinco permissões e o login de teste, membro só de dnex_gestao_api, a consome.
-- Esse login não tem GRANT nas tabelas da Folha; para o arquivo continuar a ler e gravar como
-- o worker, recebe, só nesta transação, o espelho dos GRANTs do worker (tests/ci/bootstrap.sql,
-- seção 6). Nenhum valor esperado mudou.
DO $$ BEGIN
  PERFORM dnex_folha_ci_apoio.emitir('aa000000-0000-0000-0000-000000000027', 'e0000000-0000-0000-0000-000000000027', 'e1000000-0000-0000-0000-000000000027', 'e2000000-0000-0000-0000-000000000027');
  PERFORM dnex_folha_ci_apoio.espelhar_worker();
END $$;
-- Os indicadores booleanos da 0014 são legado: o motor lê o código de incidência. Desligados
-- aqui (só nesta transação) para provar que o resultado de M1 não depende deles.
UPDATE folha.earning_deduction_code
   SET incidencia_inss = false, incidencia_irrf = false, incidencia_fgts = false
 WHERE account_id IS NULL AND codigo = 'HE_50';
SET LOCAL SESSION AUTHORIZATION dnex_folha_ci_login;
DO $$ BEGIN PERFORM gestao_auth.begin_request('aa000000-0000-0000-0000-000000000027', gen_random_uuid(), gen_random_uuid()); END $$;

SELECT plan(351);

-- ---------------------------------------------------------------------------
-- Apoio
-- ---------------------------------------------------------------------------
CREATE TEMP SEQUENCE seq_n START 27000000001;

-- Um contrato com empregador próprio. Simples = CPP no DAS (sem encargos patronais).
CREATE FUNCTION pg_temp.mk(
  p_salario numeric, p_categoria text DEFAULT 'clt', p_regime text DEFAULT 'simples_nacional',
  p_admissao date DEFAULT '2023-01-01', p_demissao date DEFAULT NULL,
  p_rat numeric DEFAULT NULL, p_fap numeric DEFAULT NULL, p_terc numeric DEFAULT NULL,
  p_account uuid DEFAULT 'e0000000-0000-0000-0000-000000000027'
) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
  v_n bigint := nextval('seq_n');
  v_emp uuid; v_est uuid; v_lot uuid; v_trab uuid; v_cid uuid;
BEGIN
  INSERT INTO folha.employee (account_id, cpf, nome_completo, data_nascimento)
  VALUES (p_account, v_n::text, 'Ficticio ' || v_n, '1990-01-01') RETURNING employee_id INTO v_trab;
  INSERT INTO folha.employer (account_id, tipo_inscricao, inscricao, razao_social)
  VALUES (p_account, 'cnpj', left(v_n::text, 8) || right(v_n::text, 3), 'Empresa Ficticia ' || v_n)
  RETURNING employer_id INTO v_emp;
  INSERT INTO folha.employer_regime (account_id, employer_id, vigencia_inicio, regime_tributario, simples_optante, simples_cpp)
  VALUES (p_account, v_emp, '2024-01-01', p_regime, p_regime = 'simples_nacional',
          CASE WHEN p_regime = 'simples_nacional' THEN 'no_das' END);
  INSERT INTO folha.establishment (account_id, employer_id, tipo_inscricao, inscricao, cnae_preponderante)
  VALUES (p_account, v_emp, 'cnpj', v_n::text || '000', '0000000') RETURNING establishment_id INTO v_est;
  IF p_fap IS NOT NULL THEN
    INSERT INTO folha.establishment_fap (account_id, establishment_id, vigencia_inicio, fap, fap_origem)
    VALUES (p_account, v_est, '2024-01-01', p_fap, 'entrada do cenário de teste');
  END IF;
  INSERT INTO folha.tax_allocation (account_id, employer_id, establishment_id, codigo_lotacao, tipo_lotacao)
  VALUES (p_account, v_emp, v_est, 'L' || v_n, 'teste') RETURNING allocation_id INTO v_lot;
  IF p_rat IS NOT NULL OR p_terc IS NOT NULL THEN
    INSERT INTO folha.tax_allocation_detail (account_id, allocation_id, vigencia_inicio, aliquota_rat, aliquota_terceiros)
    VALUES (p_account, v_lot, '2024-01-01', p_rat, p_terc);
  END IF;
  INSERT INTO folha.employment_contract (account_id, employee_id, data_admissao, data_demissao, cargo, salario_base,
                                         regime_trabalho, employer_id, establishment_id)
  VALUES (p_account, v_trab, p_admissao, p_demissao, 'Caso ' || v_n, p_salario, p_categoria, v_emp, v_est)
  RETURNING contract_id INTO v_cid;
  INSERT INTO folha.contract_tax_allocation (account_id, employer_id, contract_id, allocation_id, percentual, vigencia_inicio)
  VALUES (p_account, v_emp, v_cid, v_lot, 100, '2024-01-01');
  RETURN v_cid;
END;
$$;

CREATE FUNCTION pg_temp.confere(
  p_caso text, p_linha jsonb, p_centavos jsonb, p_exatos jsonb DEFAULT '{}'::jsonb
) RETURNS SETOF text LANGUAGE plpgsql AS $$
DECLARE
  k text;
BEGIN
  IF p_linha IS NULL THEN
    RAISE EXCEPTION '%: sem linha para conferir', p_caso;
  END IF;
  FOR k IN SELECT jsonb_object_keys(p_centavos) ORDER BY 1 LOOP
    IF NOT p_linha ? k THEN RAISE EXCEPTION '%: campo % não existe', p_caso, k; END IF;
    RETURN NEXT is(round((p_linha->>k)::numeric * 100)::bigint, (p_centavos->>k)::bigint,
                   p_caso || ': ' || k || ' = ' || (p_centavos->>k) || ' centavos');
  END LOOP;
  FOR k IN SELECT jsonb_object_keys(p_exatos) ORDER BY 1 LOOP
    IF NOT p_linha ? k THEN RAISE EXCEPTION '%: campo % não existe', p_caso, k; END IF;
    RETURN NEXT is(p_linha->>k, p_exatos->>k, p_caso || ': ' || k || ' = ' || COALESCE(p_exatos->>k, 'NULL'));
  END LOOP;
END;
$$;

CREATE FUNCTION pg_temp.rub(p_codigo text) RETURNS uuid LANGUAGE sql AS $$
  SELECT e.code_id FROM folha.earning_deduction_code e
   WHERE e.codigo = p_codigo ORDER BY (e.account_id IS NULL) LIMIT 1
$$;

CREATE TEMP TABLE c (caso text PRIMARY KEY, cid uuid NOT NULL);
CREATE FUNCTION pg_temp.cid(p_caso text) RETURNS uuid LANGUAGE sql AS $$ SELECT cid FROM c WHERE caso = p_caso $$;
CREATE FUNCTION pg_temp.emp(p_caso text) RETURNS uuid LANGUAGE sql AS $$
  SELECT k.employer_id FROM folha.employment_contract k WHERE k.contract_id = pg_temp.cid(p_caso) $$;
CREATE FUNCTION pg_temp.trab(p_caso text) RETURNS uuid LANGUAGE sql AS $$
  SELECT k.employee_id FROM folha.employment_contract k WHERE k.contract_id = pg_temp.cid(p_caso) $$;

CREATE TEMP TABLE f (rotulo text PRIMARY KEY, run_id uuid NOT NULL);
CREATE FUNCTION pg_temp.folha(p_rotulo text, p_tipo text, p_comp date, p_pag date, p_seq integer DEFAULT 1)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v uuid;
BEGIN
  INSERT INTO folha.payroll_run (account_id, competencia, data_pagamento, tipo_processo, sequencia)
  VALUES ('e0000000-0000-0000-0000-000000000027', p_comp, p_pag, p_tipo, p_seq) RETURNING run_id INTO v;
  INSERT INTO f VALUES (p_rotulo, v);
END;
$$;
CREATE FUNCTION pg_temp.run(p_rotulo text) RETURNS uuid LANGUAGE sql AS $$ SELECT run_id FROM f WHERE rotulo = p_rotulo $$;

CREATE TEMP TABLE r (caso text PRIMARY KEY, result_id uuid NOT NULL);
CREATE FUNCTION pg_temp.res(p_caso text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT to_jsonb(pr) FROM folha.payroll_result pr JOIN r ON r.result_id = pr.result_id WHERE r.caso = p_caso $$;
-- Itens do resultado: "CODIGO=centavos/camada" na ordem gravada.
CREATE FUNCTION pg_temp.itens(p_caso text) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(i.rubrica_codigo || '=' || round(i.valor * 100) || '/' || i.camada_regra, ' ' ORDER BY i.ordem)
    FROM folha.payroll_result_item i JOIN r ON r.result_id = i.result_id WHERE r.caso = p_caso $$;
CREATE FUNCTION pg_temp.bases(p_caso text) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(b.base_codigo || '=' || round(b.valor * 100), ' ' ORDER BY b.base_codigo)
    FROM folha.payroll_result_base b JOIN r ON r.result_id = b.result_id WHERE r.caso = p_caso $$;
CREATE FUNCTION pg_temp.pend(p_caso text) RETURNS text[] LANGUAGE sql AS $$
  SELECT COALESCE(array_agg(p.codigo ORDER BY p.codigo), ARRAY[]::text[])
    FROM folha.payroll_pendency p JOIN r ON r.result_id = p.result_id WHERE r.caso = p_caso $$;
CREATE FUNCTION pg_temp.item(p_caso text, p_codigo text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT to_jsonb(i) FROM folha.payroll_result_item i JOIN r ON r.result_id = i.result_id
   WHERE r.caso = p_caso AND i.rubrica_codigo = p_codigo $$;

-- Folhas
SELECT pg_temp.folha('m10',   'mensal',            '2026-10-01', '2026-10-31');
SELECT pg_temp.folha('m10b',  'mensal',            '2026-10-01', '2026-10-31', 2);
SELECT pg_temp.folha('m10c',  'mensal',            '2026-10-01', NULL,         3);
SELECT pg_temp.folha('m02',   'mensal',            '2026-02-01', '2026-02-28');
SELECT pg_temp.folha('m12',   'mensal',            '2026-12-01', '2027-01-05');
SELECT pg_temp.folha('m2701', 'mensal',            '2027-01-01', '2027-01-29');
SELECT pg_temp.folha('ad10',  'adiantamento',      '2026-10-01', '2026-10-15');
SELECT pg_temp.folha('co10',  'complementar',      '2026-10-01', '2026-10-31');
SELECT pg_temp.folha('d1',    'decimo_terceiro_1', '2026-11-01', '2026-11-30');
SELECT pg_temp.folha('d2',    'decimo_terceiro_2', '2026-12-01', '2026-12-18');
SELECT pg_temp.folha('fe09',  'ferias',            '2026-09-01', '2026-08-28');
SELECT pg_temp.folha('re10',  'rescisao',          '2026-10-01', '2026-10-23');

-- ===========================================================================
-- 1. Estrutura migrada (A e B)
-- ===========================================================================
SELECT is(
  (SELECT count(*) FROM folha.rubric_incidence ri JOIN folha.earning_deduction_code e ON e.code_id = ri.code_id
    WHERE e.account_id IS NULL AND ri.vigencia_inicio <= '2026-10-01' AND ri.vigencia_fim IS NULL),
  3 * (SELECT count(*) FROM folha.earning_deduction_code e WHERE e.account_id IS NULL),
  'toda rubrica global tem incidência vigente de previdência, IRRF e FGTS');
SELECT is(
  (SELECT count(*) FROM folha.earning_deduction_code e WHERE e.account_id IS NULL), 52::bigint,
  '52 rubricas globais: 40 da 0017 e 12 dos processos (âncora da asserção acima)');
SELECT is_empty(
  $$SELECT e.codigo, ri.tributo FROM folha.earning_deduction_code e
      JOIN folha.rubric_incidence ri ON ri.code_id = e.code_id
      JOIN folha.incidence_code ic ON ic.tributo = ri.tributo AND ic.codigo = ri.incidencia_codigo
     WHERE e.account_id IS NULL AND e.codigo NOT IN ('FALTAS', 'ATRASOS', 'HE_50')
       AND (ic.efeito = 'compoe_base') IS DISTINCT FROM
           (CASE ri.tributo WHEN 'previdencia' THEN e.incidencia_inss WHEN 'irrf' THEN e.incidencia_irrf ELSE e.incidencia_fgts END)$$,
  'migração: o código de incidência compõe base exatamente onde o indicador da 0017/0023 era verdadeiro');
SELECT is(
  (SELECT string_agg(ri.tributo || ':' || ri.incidencia_codigo, ' ' ORDER BY ri.tributo)
     FROM folha.rubric_incidence ri WHERE ri.code_id = pg_temp.rub('DECIMO_TERCEIRO_2A')),
  'fgts:BASE_13 irrf:BASE_13 previdencia:BASE_13', '13º 2ª parcela: incidências nas bases de 13º');
SELECT is(
  (SELECT string_agg(ri.tributo || ':' || ri.incidencia_codigo, ' ' ORDER BY ri.tributo)
     FROM folha.rubric_incidence ri WHERE ri.code_id = pg_temp.rub('ABONO_PECUNIARIO')),
  'fgts:NAO_INCIDE irrf:NAO_INCIDE previdencia:NAO_INCIDE', 'abono pecuniário: sem incidência (como corrigido na 0023)');
SELECT is(
  (SELECT string_agg(ri.tributo || ':' || ri.incidencia_codigo, ' ' ORDER BY ri.tributo)
     FROM folha.rubric_incidence ri WHERE ri.code_id = pg_temp.rub('INSS_EMPREGADO')),
  'fgts:NAO_INCIDE irrf:NAO_INCIDE previdencia:RETENCAO_SEGURADO', 'INSS do segurado: código de retenção, não de base');
SELECT is(
  (SELECT string_agg(b.codigo, ' ' ORDER BY b.codigo) FROM folha.rubric_base rb
     JOIN folha.calculation_base b ON b.base_id = rb.base_id WHERE rb.code_id = pg_temp.rub('SALARIO_BASE')),
  'FGTS_MENSAL INSS_MENSAL IRRF_MENSAL SALARIO_FAMILIA', 'salário: ligado N:N às quatro bases do mês');
SELECT is(
  (SELECT string_agg(b.codigo, ' ' ORDER BY b.codigo) FROM folha.rubric_base rb
     JOIN folha.calculation_base b ON b.base_id = rb.base_id WHERE rb.code_id = pg_temp.rub('FALTAS')),
  'FGTS_MENSAL INSS_MENSAL IRRF_MENSAL', 'faltas: reduzem INSS, IRRF e FGTS do mês; não a base do salário-família');
SELECT is(
  (SELECT string_agg(b.codigo, ' ' ORDER BY b.codigo) FROM folha.calculation_base b WHERE b.account_id IS NULL),
  'DECIMO_TERCEIRO FERIAS FGTS_13 FGTS_MENSAL INSS_13 INSS_MENSAL IRRF_13 IRRF_FERIAS IRRF_MENSAL MEDIAS SALARIO_FAMILIA',
  'bases padrão: INSS, IRRF e FGTS (mês, 13º, férias), salário-família, médias, 13º e férias');
SELECT is(
  (SELECT count(*) FROM folha.incidence_code), 12::bigint, 'catálogo de incidência: 12 códigos internos (4 + 5 + 3)');
SELECT is_empty(
  $$SELECT tributo, codigo FROM folha.incidence_code WHERE codigo_esocial IS NOT NULL OR esocial_status <> 'a_validar'$$,
  'nenhum código do eSocial foi semeado: todos nulos e a_validar');
SELECT is((SELECT count(*) FROM folha.esocial_rubric_nature), 0::bigint, 'natureza de rubrica do eSocial: só a estrutura, vazia');
SELECT throws_ok(
  $$INSERT INTO folha.incidence_code (tributo, codigo, descricao, efeito) VALUES ('pis', 'X1', 'teste', 'nao_incide')$$,
  '42501', NULL, 'NEG: o worker não grava no catálogo de incidência');
SELECT is(
  (SELECT string_agg(l.camada || '=' || l.precedencia, ' ' ORDER BY l.precedencia) FROM folha.rule_layer l),
  'empresa=1 convencao=2 contrato=3', 'precedência das camadas é dado: empresa < convenção < contrato');
SELECT is(
  (SELECT string_agg(e.codigo, ' ' ORDER BY e.codigo) FROM folha.earning_deduction_code e
    WHERE e.account_id IS NULL AND e.tipo_rubrica = 'base'),
  'BASE_FGTS BASE_INSS BASE_IRRF', 'tipo de rubrica "base" nas três rubricas de base da 0017');
SELECT is(
  (SELECT e.forma_calculo || '/' || e.tipo_rubrica FROM folha.earning_deduction_code e WHERE e.code_id = pg_temp.rub('HE_50')),
  'valor_fixo/provento', 'hora extra: provento lançável');
SELECT is(
  (SELECT e.forma_calculo FROM folha.earning_deduction_code e WHERE e.code_id = pg_temp.rub('IRRF')),
  'apuracao_motor', 'IRRF: apurado pelo motor');

-- ===========================================================================
-- 2. Folha mensal de ponta a ponta por rubricas
-- ===========================================================================
INSERT INTO c VALUES
  ('cd01', pg_temp.mk(1621.00, 'clt', 'lucro_presumido', '2023-01-01', NULL, 0.01, 1.0000, 0.058)),
  ('cd03', pg_temp.mk(5400.00, 'clt', 'lucro_real',      '2023-01-01', NULL, 0.02, 1.5000, 0.058)),
  ('cd06', pg_temp.mk(6000.00, 'contribuinte_individual', 'lucro_presumido')),
  ('m1',   pg_temp.mk(5000.00, 'clt', 'lucro_real',      '2023-01-01', NULL, 0.02, 1.5000, 0.058));

-- CD-01, CD-03 e CD-06 do parecer de INSS/FGTS, pela folha de rubricas.
INSERT INTO r VALUES ('cd01', folha.run_payroll_employee(pg_temp.run('m10'), pg_temp.cid('cd01')));
INSERT INTO r VALUES ('cd03', folha.run_payroll_employee(pg_temp.run('m10'), pg_temp.cid('cd03')));
INSERT INTO r VALUES ('cd06', folha.run_payroll_employee(pg_temp.run('m10'), pg_temp.cid('cd06')));
SELECT pg_temp.confere('CD-01 por rubricas (INSS e líquido provisórios)', pg_temp.res('cd01'),
  '{"total_proventos": 162100, "inss_empregado": 12158, "irrf": 0, "fgts": 12968, "inss_patronal": 32420, "rat": 1621, "terceiros": 9402, "liquido": 149942}');
SELECT pg_temp.confere('CD-03 por rubricas', pg_temp.res('cd03'),
  '{"total_proventos": 540000, "total_descontos": 70716, "inss_empregado": 55751, "irrf": 14965, "fgts": 43200, "inss_patronal": 108000, "rat": 16200, "terceiros": 31320, "liquido": 469284}');
SELECT pg_temp.confere('CD-06 por rubricas', pg_temp.res('cd06'),
  '{"inss_empregado": 66000, "irrf": 38002, "fgts": 0, "inss_patronal": 120000, "rat": 0, "terceiros": 0, "liquido": 495998}');
SELECT is(pg_temp.itens('cd03'),
  'SALARIO_BASE=540000/motor INSS_EMPREGADO=55751/motor IRRF=14965/motor FGTS_DEPOSITO=43200/motor',
  'CD-03 (estrutura, derivado): itens gravados por rubrica');
SELECT is(pg_temp.bases('cd03'),
  'FGTS_MENSAL=540000 INSS_MENSAL=540000 IRRF_MENSAL=540000 SALARIO_FAMILIA=540000',
  'CD-03 (estrutura, derivado): bases gravadas como dado');
SELECT is(pg_temp.bases('cd06'),
  'FGTS_MENSAL=600000 INSS_MENSAL=600000 IRRF_MENSAL=600000 SALARIO_FAMILIA=600000',
  'CD-06 (estrutura, derivado): a base é da rubrica; a categoria (pró-labore) decide a alíquota e a ausência de FGTS');

-- M1 (derivado). CLT, salário 5.000,00; Lucro Real, RAT 2%, FAP 1,5000, terceiros 5,8%.
--   HE_50: regra da EMPRESA por fórmula SALARIO / 220 x 1,5 x QUANTIDADE; 10 horas:
--          5.000 / 220 = 22,727272...; x 1,5 = 34,090909...; x 10 = 340,9090... -> 340,91
--   FALTAS: 166,67 informados no lançamento (sem regra)
--   PLANO_SAUDE: regra do CONTRATO, valor fixo 150,00, automática (sem lançamento)
--   Bases (INSS, IRRF, FGTS) = 5.000,00 + 340,91 - 166,67 = 5.174,24
--   INSS: 121,575 + 115,3656 + 174,1716 + (5.174,24 - 4.354,27) x 14% (114,7958) = 525,908 -> 525,91
--   IRRF: 525,91 < 607,20 -> simplificado; base 4.567,04; 22,5%: 1.027,584 - 675,49 = 352,094;
--         redução 978,62 - 0,133145 x 5.174,24 (688,9241848) = 289,6958152; imposto 62,3981848 -> 62,40
--   FGTS 8% = 413,9392 -> 413,94
--   Proventos 5.340,91; descontos 166,67 + 150,00 + 525,91 + 62,40 = 904,98; líquido 4.435,93
--   Encargos sobre 5.174,24: patronal 20% = 1.034,848 -> 1.034,85; RAT 2% x 1,5 = 155,2272 -> 155,23;
--   terceiros 5,8% = 300,10592 -> 300,11
INSERT INTO folha.rubric_rule (account_id, camada, employer_id, code_id, forma_calculo, formula, vigencia_inicio, fonte)
VALUES ('e0000000-0000-0000-0000-000000000027', 'empresa', pg_temp.emp('m1'), pg_temp.rub('HE_50'), 'formula',
        '{"op":"multiplica","args":[{"op":"divide","args":[{"var":"SALARIO"},{"num":220}]},{"num":1.5},{"var":"QUANTIDADE"}]}',
        '2026-01-01', 'política interna fictícia: hora extra a 50% com divisor 220');
INSERT INTO folha.rubric_rule (account_id, camada, contract_id, code_id, forma_calculo, valor, automatica, vigencia_inicio, fonte)
VALUES ('e0000000-0000-0000-0000-000000000027', 'contrato', pg_temp.cid('m1'), pg_temp.rub('PLANO_SAUDE'), 'valor_fixo',
        150.00, true, '2026-01-01', 'termo de adesão fictício ao plano de saúde');
INSERT INTO folha.payroll_entry (account_id, contract_id, code_id, competencia, quantidade)
VALUES ('e0000000-0000-0000-0000-000000000027', pg_temp.cid('m1'), pg_temp.rub('HE_50'), '2026-10-01', 10);
INSERT INTO folha.payroll_entry (account_id, contract_id, code_id, competencia, valor)
VALUES ('e0000000-0000-0000-0000-000000000027', pg_temp.cid('m1'), pg_temp.rub('FALTAS'), '2026-10-01', 166.67);
INSERT INTO r VALUES ('m1', folha.run_payroll_employee(pg_temp.run('m10'), pg_temp.cid('m1')));

SELECT pg_temp.confere('M1 derivado: folha mensal por rubricas', pg_temp.res('m1'),
  '{"total_proventos": 534091, "total_descontos": 90498, "liquido": 443593, "inss_empregado": 52591, "irrf": 6240, "fgts": 41394, "inss_patronal": 103485, "rat": 15523, "terceiros": 30011}');
SELECT is(pg_temp.itens('m1'),
  'SALARIO_BASE=500000/motor HE_50=34091/empresa FALTAS=16667/lancamento PLANO_SAUDE=15000/contrato INSS_EMPREGADO=52591/motor IRRF=6240/motor FGTS_DEPOSITO=41394/motor',
  'M1: um item por rubrica, com a camada de onde veio a regra');
SELECT is(pg_temp.bases('m1'),
  'FGTS_MENSAL=517424 INSS_MENSAL=517424 IRRF_MENSAL=517424 SALARIO_FAMILIA=534091',
  'M1: hora extra soma e falta subtrai nas bases; a base do salário-família não desconta a falta');
SELECT is(
  (SELECT string_agg(t.rubrica_code || ':' || t.camada_regra, ' ' ORDER BY t.step_order)
     FROM folha.calculation_trace t JOIN r ON r.result_id = t.result_id WHERE r.caso = 'm1' AND t.tipo <> 'encargo'),
  'SALARIO_BASE:motor HE_50:empresa FALTAS:lancamento PLANO_SAUDE:contrato INSS_EMPREGADO:motor IRRF:motor FGTS_DEPOSITO:motor',
  'M1: a memória de cálculo guarda a camada de cada passo');
SELECT is(
  (SELECT (t.rule_id = (SELECT rr.rule_id FROM folha.rubric_rule rr WHERE rr.code_id = pg_temp.rub('HE_50') AND rr.employer_id = pg_temp.emp('m1')))::text
          || '/' || (t.detail_json->>'fonte_da_regra')
     FROM folha.calculation_trace t JOIN r ON r.result_id = t.result_id WHERE r.caso = 'm1' AND t.rubrica_code = 'HE_50'),
  'true/política interna fictícia: hora extra a 50% com divisor 220',
  'M1: a memória aponta a regra aplicada e a fonte dela');
SELECT is((pg_temp.item('m1', 'PLANO_SAUDE')->'detalhe'->>'automatica'), 'true', 'M1: plano de saúde entrou pela regra automática, sem lançamento');
SELECT is((pg_temp.item('m1', 'HE_50')->>'quantidade')::numeric, 10::numeric, 'M1: o item guarda a quantidade lançada');
SELECT ok((pg_temp.item('m1', 'HE_50')->>'entry_id') IS NOT NULL AND (pg_temp.item('m1', 'PLANO_SAUDE')->>'entry_id') IS NULL,
  'M1: o item aponta o lançamento de origem quando há');
SELECT is(
  (SELECT string_agg(t.rubrica_code || '=' || round(t.valor * 100), ',' ORDER BY t.step_order)
     FROM folha.calculation_trace t JOIN r ON r.result_id = t.result_id WHERE r.caso = 'm1' AND t.tipo = 'encargo'),
  'INSS_PATRONAL=103485,RAT_SAT=15523,TERCEIROS=30011', 'M1: encargos por lotação sobre a base formada pelas rubricas');
SELECT ok(pg_temp.pend('m1') @> ARRAY['a_validar:inss_arredondamento_metodo', 'a_validar:irrf_simplificado_pela_fonte_pagadora_ato_rfb'],
  'M1: pendências do cálculo gravadas como dado');
SELECT is(
  (SELECT string_agg(DISTINCT p.tipo, ',') FROM folha.payroll_pendency p JOIN r ON r.result_id = p.result_id WHERE r.caso = 'm1'),
  'a_validar', 'M1: tipo da pendência derivado do prefixo');
SELECT is(
  (SELECT t.detail_json->'pendencias' FROM folha.calculation_trace t JOIN r ON r.result_id = t.result_id
    WHERE r.caso = 'm1' AND t.step_order = 1),
  to_jsonb(pg_temp.pend('m1')), 'M1: as mesmas pendências seguem no primeiro passo da memória de cálculo');

-- ===========================================================================
-- 3. Três camadas de regra (derivado)
--    Gratificação por valor fixo automático: empresa 100,00; convenção 200,00; contrato 300,00.
--    Salário 3.000,00, Simples (sem encargos). INSS: 121,575 + 115,3656 + (base - 2.902,84) x 12%.
--      k1 (só empresa): base 3.100,00 -> 197,16 x 12% = 23,6592 -> 260,5998 -> 260,60
--      k2 (empresa + convenção): base 3.200,00 -> 35,6592 -> 272,5998 -> 272,60
--      k3 (as três): base 3.300,00 -> 47,6592 -> 284,5998 -> 284,60
--      k4 (convenção vencida em 30/09/2026): volta para a empresa -> 260,60
-- ===========================================================================
INSERT INTO c VALUES
  ('k1', pg_temp.mk(3000.00)), ('k2', pg_temp.mk(3000.00)), ('k3', pg_temp.mk(3000.00)), ('k4', pg_temp.mk(3000.00));
INSERT INTO folha.collective_agreement (agreement_id, account_id, sindicato, categoria, vigencia_inicio, vigencia_fim, clausulas_json)
VALUES ('ca000000-0000-0000-0000-000000000001', 'e0000000-0000-0000-0000-000000000027', 'Sindicato Ficticio A', 'teste', '2026-01-01', '2026-12-31', '{}'),
       ('ca000000-0000-0000-0000-000000000002', 'e0000000-0000-0000-0000-000000000027', 'Sindicato Ficticio B', 'teste', '2025-10-01', '2026-09-30', '{}');
UPDATE folha.employment_contract SET agreement_id = 'ca000000-0000-0000-0000-000000000001'
 WHERE contract_id IN (pg_temp.cid('k2'), pg_temp.cid('k3'));
UPDATE folha.employment_contract SET agreement_id = 'ca000000-0000-0000-0000-000000000002'
 WHERE contract_id = pg_temp.cid('k4');
INSERT INTO folha.rubric_rule (account_id, camada, employer_id, code_id, forma_calculo, valor, automatica, vigencia_inicio, fonte)
SELECT 'e0000000-0000-0000-0000-000000000027', 'empresa', pg_temp.emp(x), pg_temp.rub('GRATIFICACAO_FUNCAO'), 'valor_fixo', 100.00, true, '2026-01-01', 'política fictícia da empresa'
  FROM unnest(ARRAY['k1', 'k2', 'k3', 'k4']) AS x;
INSERT INTO folha.rubric_rule (account_id, camada, agreement_id, code_id, forma_calculo, valor, automatica, vigencia_inicio, fonte)
VALUES ('e0000000-0000-0000-0000-000000000027', 'convencao', 'ca000000-0000-0000-0000-000000000001', pg_temp.rub('GRATIFICACAO_FUNCAO'), 'valor_fixo', 200.00, true, '2026-01-01', 'cláusula fictícia 12 da convenção A'),
       ('e0000000-0000-0000-0000-000000000027', 'convencao', 'ca000000-0000-0000-0000-000000000002', pg_temp.rub('GRATIFICACAO_FUNCAO'), 'valor_fixo', 250.00, true, '2025-10-01', 'cláusula fictícia 7 da convenção B');
INSERT INTO folha.rubric_rule (account_id, camada, contract_id, code_id, forma_calculo, valor, automatica, vigencia_inicio, fonte)
VALUES ('e0000000-0000-0000-0000-000000000027', 'contrato', pg_temp.cid('k3'), pg_temp.rub('GRATIFICACAO_FUNCAO'), 'valor_fixo', 300.00, true, '2026-01-01', 'aditivo contratual fictício');
INSERT INTO r SELECT x, folha.run_payroll_employee(pg_temp.run('m10'), pg_temp.cid(x)) FROM unnest(ARRAY['k1', 'k2', 'k3', 'k4']) AS x;

SELECT is(
  (pg_temp.item(x.caso, 'GRATIFICACAO_FUNCAO')->>'camada_regra') || '=' || round((pg_temp.item(x.caso, 'GRATIFICACAO_FUNCAO')->>'valor')::numeric * 100),
  x.esperado, 'camadas derivado: ' || x.caso || ' -> ' || x.esperado)
  FROM (VALUES ('k1', 'empresa=10000'), ('k2', 'convencao=20000'), ('k3', 'contrato=30000'), ('k4', 'empresa=10000')) AS x(caso, esperado);
SELECT is(round((pg_temp.res(x.caso)->>'inss_empregado')::numeric * 100)::bigint, x.inss,
          'camadas derivado: ' || x.caso || ' INSS sobre a base com a gratificação = ' || x.inss)
  FROM (VALUES ('k1', 26060::bigint), ('k2', 27260), ('k3', 28460), ('k4', 26060)) AS x(caso, inss);
SELECT is(
  (SELECT string_agg(v->>'camada', ',' ORDER BY ord)
     FROM jsonb_array_elements(pg_temp.item('k3', 'GRATIFICACAO_FUNCAO')->'detalhe'->'regras_vencidas') WITH ORDINALITY AS t(v, ord)),
  'convencao,empresa', 'camadas: o item do contrato registra as regras vencidas, na ordem de precedência');
SELECT is(jsonb_array_length(pg_temp.item('k1', 'GRATIFICACAO_FUNCAO')->'detalhe'->'regras_vencidas'), 0,
  'camadas: sem regra concorrente, nenhuma vencida');
SELECT is(
  (SELECT t.camada_regra || '/' || (t.detail_json->>'fonte_da_regra') FROM folha.calculation_trace t JOIN r ON r.result_id = t.result_id
    WHERE r.caso = 'k2' AND t.rubrica_code = 'GRATIFICACAO_FUNCAO'),
  'convencao/cláusula fictícia 12 da convenção A', 'camadas: a memória de cálculo traz a camada e a cláusula');
SELECT is(
  (SELECT rg.camada FROM folha.payroll_result_item i JOIN r ON r.result_id = i.result_id AND r.caso = 'k4'
     JOIN folha.rubric_rule rg ON rg.rule_id = i.rule_id WHERE i.rubrica_codigo = 'GRATIFICACAO_FUNCAO'),
  'empresa', 'camadas: convenção fora da vigência não vence a regra da empresa');
SELECT throws_ok(
  $$INSERT INTO folha.rubric_rule (account_id, camada, employer_id, code_id, forma_calculo, valor, vigencia_inicio, fonte)
    VALUES ('e0000000-0000-0000-0000-000000000027', 'empresa', pg_temp.emp('k1'), pg_temp.rub('GRATIFICACAO_FUNCAO'), 'valor_fixo', 1, '2026-06-01', 'x')$$,
  '23P01', NULL, 'NEG: duas regras vigentes da mesma rubrica no mesmo alcance são recusadas');
SELECT throws_ok(
  $$INSERT INTO folha.rubric_rule (account_id, camada, contract_id, employer_id, code_id, forma_calculo, valor, vigencia_inicio, fonte)
    VALUES ('e0000000-0000-0000-0000-000000000027', 'contrato', pg_temp.cid('k1'), pg_temp.emp('k1'), pg_temp.rub('COMISSAO'), 'valor_fixo', 1, '2026-01-01', 'x')$$,
  '23514', NULL, 'NEG: regra com alcance de duas camadas é recusada');

-- Quantidade x valor (convenção) e percentual sobre base da conta (empresa). Derivado.
--   Contrato q1, salário 3.000,00, Simples, convenção C (só dele).
--   HE_100: regra da convenção, 40,00 por hora; 2,5 horas -> 100,00
--   PREMIO_PROD (rubrica da conta, incide nos três tributos e soma na base VARIAVEIS_CONTA): 600,00 lançados
--   REFLEXO_VAR (rubrica da conta): regra da empresa, 20% da base VARIAVEIS_CONTA -> 120,00
--   Base INSS = 3.000 + 100 + 600 + 120 = 3.820,00 -> 121,575 + 115,3656 + 917,16 x 12% (110,0592) = 346,9998 -> 347,00
--   IRRF: simplificado; base 3.212,80; 15%: 481,92 - 394,16 = 87,76; redução zera. FGTS 8% = 305,60
--   Proventos 3.000 + 80 + 100 + 600 + 120 = 3.900,00; líquido 3.900,00 - 347,00 = 3.553,00
INSERT INTO c VALUES ('q1', pg_temp.mk(3000.00));
INSERT INTO folha.collective_agreement (agreement_id, account_id, sindicato, categoria, vigencia_inicio, vigencia_fim, clausulas_json)
VALUES ('ca000000-0000-0000-0000-000000000003', 'e0000000-0000-0000-0000-000000000027', 'Sindicato Ficticio C', 'teste', '2026-01-01', '2026-12-31', '{}');
UPDATE folha.employment_contract SET agreement_id = 'ca000000-0000-0000-0000-000000000003' WHERE contract_id = pg_temp.cid('q1');
INSERT INTO folha.calculation_base (account_id, codigo, descricao, finalidade)
VALUES ('e0000000-0000-0000-0000-000000000027', 'VARIAVEIS_CONTA', 'Variáveis da conta de teste', 'outra');
INSERT INTO folha.earning_deduction_code (account_id, codigo, descricao, natureza, ordem_calculo)
VALUES ('e0000000-0000-0000-0000-000000000027', 'PREMIO_PROD', 'Prêmio fictício', 'provento', 100),
       ('e0000000-0000-0000-0000-000000000027', 'REFLEXO_VAR', 'Reflexo fictício', 'provento', 200),
       ('e0000000-0000-0000-0000-000000000027', 'AJUDA_X', 'Ajuda fictícia sem incidência', 'provento', 100),
       ('e0000000-0000-0000-0000-000000000027', 'SEM_INCID', 'Rubrica sem incidência cadastrada', 'provento', 100),
       ('e0000000-0000-0000-0000-000000000027', 'INCOERENTE', 'Rubrica com incidência sem base', 'provento', 100);
INSERT INTO folha.rubric_incidence (account_id, code_id, tributo, incidencia_codigo, vigencia_inicio)
SELECT 'e0000000-0000-0000-0000-000000000027', pg_temp.rub(x.rubrica), t.tributo, x.codigo, '2026-01-01'
  FROM (VALUES ('PREMIO_PROD', 'BASE_MENSAL'), ('REFLEXO_VAR', 'BASE_MENSAL'), ('AJUDA_X', 'NAO_INCIDE'), ('INCOERENTE', 'BASE_MENSAL')) AS x(rubrica, codigo)
  CROSS JOIN (VALUES ('previdencia'), ('irrf'), ('fgts')) AS t(tributo);
INSERT INTO folha.rubric_base (account_id, code_id, base_id, vigencia_inicio)
SELECT 'e0000000-0000-0000-0000-000000000027', pg_temp.rub(x.rubrica), b.base_id, '2026-01-01'
  FROM (VALUES ('PREMIO_PROD'), ('REFLEXO_VAR')) AS x(rubrica)
  CROSS JOIN folha.calculation_base b
 WHERE b.codigo IN ('INSS_MENSAL', 'IRRF_MENSAL', 'FGTS_MENSAL')
    OR (b.codigo = 'VARIAVEIS_CONTA' AND x.rubrica = 'PREMIO_PROD');
INSERT INTO folha.rubric_rule (account_id, camada, agreement_id, code_id, forma_calculo, valor_unitario, vigencia_inicio, fonte)
VALUES ('e0000000-0000-0000-0000-000000000027', 'convencao', 'ca000000-0000-0000-0000-000000000003', pg_temp.rub('HE_100'), 'quantidade_valor', 40.00, '2026-01-01', 'cláusula fictícia 20 da convenção C');
INSERT INTO folha.rubric_rule (account_id, camada, employer_id, code_id, forma_calculo, percentual, base_id, vigencia_inicio, fonte)
VALUES ('e0000000-0000-0000-0000-000000000027', 'empresa', pg_temp.emp('q1'), pg_temp.rub('REFLEXO_VAR'), 'percentual_base', 0.20,
        (SELECT b.base_id FROM folha.calculation_base b WHERE b.codigo = 'VARIAVEIS_CONTA'), '2026-01-01', 'política fictícia de reflexo');
INSERT INTO folha.payroll_entry (account_id, contract_id, code_id, competencia, quantidade, valor) VALUES
  ('e0000000-0000-0000-0000-000000000027', pg_temp.cid('q1'), pg_temp.rub('HE_100'), '2026-10-01', 2.5, NULL),
  ('e0000000-0000-0000-0000-000000000027', pg_temp.cid('q1'), pg_temp.rub('PREMIO_PROD'), '2026-10-01', NULL, 600.00),
  ('e0000000-0000-0000-0000-000000000027', pg_temp.cid('q1'), pg_temp.rub('REFLEXO_VAR'), '2026-10-01', 1, NULL),
  ('e0000000-0000-0000-0000-000000000027', pg_temp.cid('q1'), pg_temp.rub('AJUDA_X'), '2026-10-01', NULL, 80.00);
INSERT INTO r VALUES ('q1', folha.run_payroll_employee(pg_temp.run('m10'), pg_temp.cid('q1')));
SELECT is(pg_temp.itens('q1'),
  'SALARIO_BASE=300000/motor AJUDA_X=8000/lancamento HE_100=10000/convencao PREMIO_PROD=60000/lancamento REFLEXO_VAR=12000/empresa INSS_EMPREGADO=34700/motor IRRF=0/motor FGTS_DEPOSITO=30560/motor',
  'formas derivado: quantidade x valor (convenção), valor lançado e percentual sobre base da conta (empresa)');
SELECT is(pg_temp.bases('q1'),
  'FGTS_MENSAL=382000 INSS_MENSAL=382000 IRRF_MENSAL=382000 SALARIO_FAMILIA=310000 VARIAVEIS_CONTA=60000',
  'formas derivado: rubrica com código NAO_INCIDE fica fora das bases; a base da conta é gravada');
SELECT pg_temp.confere('formas derivado', pg_temp.res('q1'), '{"total_proventos": 390000, "liquido": 355300}');

-- A incidência por código tem efeito: rubrica sem incidência ou incoerente com as bases é recusada.
INSERT INTO c VALUES ('neg1', pg_temp.mk(3000.00)), ('neg2', pg_temp.mk(3000.00)), ('neg3', pg_temp.mk(3000.00)),
                     ('neg4', pg_temp.mk(3000.00)), ('neg5', pg_temp.mk(3000.00));
INSERT INTO folha.payroll_entry (account_id, contract_id, code_id, competencia, valor) VALUES
  ('e0000000-0000-0000-0000-000000000027', pg_temp.cid('neg1'), pg_temp.rub('SEM_INCID'), '2026-10-01', 10.00),
  ('e0000000-0000-0000-0000-000000000027', pg_temp.cid('neg2'), pg_temp.rub('INCOERENTE'), '2026-10-01', 10.00),
  ('e0000000-0000-0000-0000-000000000027', pg_temp.cid('neg3'), pg_temp.rub('INSS_EMPREGADO'), '2026-10-01', 10.00),
  ('e0000000-0000-0000-0000-000000000027', pg_temp.cid('neg5'), pg_temp.rub('FALTAS'), '2026-10-01', 3500.00);
INSERT INTO folha.payroll_entry (account_id, contract_id, code_id, competencia, quantidade)
VALUES ('e0000000-0000-0000-0000-000000000027', pg_temp.cid('neg4'), pg_temp.rub('COMISSAO'), '2026-10-01', 3);
SELECT throws_ok($$SELECT folha.run_payroll_employee(pg_temp.run('m10'), pg_temp.cid('neg1'))$$,
  'P0001', 'Rubrica SEM_INCID sem incidência de previdencia vigente em 2026-10-01', 'NEG: rubrica sem código de incidência vigente');
SELECT throws_like($$SELECT folha.run_payroll_employee(pg_temp.run('m10'), pg_temp.cid('neg2'))$$,
  'Rubrica INCOERENTE incoerente em 2026-10-01: incidência de previdencia com código BASE_MENSAL%',
  'NEG: código de incidência que compõe base sem a ligação com a base');
SELECT throws_ok($$SELECT folha.run_payroll_employee(pg_temp.run('m10'), pg_temp.cid('neg3'))$$,
  'P0001', 'Rubrica INSS_EMPREGADO é apurada pelo motor e não aceita lançamento nem regra', 'NEG: rubrica do motor não aceita lançamento');
SELECT throws_ok($$SELECT folha.run_payroll_employee(pg_temp.run('m10'), pg_temp.cid('neg4'))$$,
  'P0001', 'Rubrica COMISSAO sem regra vigente para o contrato e sem valor informado no lançamento', 'NEG: lançamento só com quantidade e sem regra');
SELECT throws_like($$SELECT folha.run_payroll_employee(pg_temp.run('m10'), pg_temp.cid('neg5'))$$,
  'Contrato % base negativa (INSS -500.00, IRRF -500.00, FGTS -500.00); os descontos superam os proventos',
  'NEG: base negativa não vira zero em silêncio');
SELECT is(
  (SELECT count(*) FROM folha.payroll_result pr WHERE pr.contract_id IN (SELECT cid FROM c WHERE caso LIKE 'neg%')),
  0::bigint, 'NEG: nenhum dos contratos recusados ficou com resultado gravado');

-- Fórmula restrita
SELECT ok(folha.formula_valida('{"op":"arredonda2","args":[{"op":"multiplica","args":[{"var":"SALARIO"},{"num":0.3}]}]}'),
  'fórmula: árvore de operações com variável da lista e número é aceita');
SELECT is(
  ARRAY[folha.formula_valida('{"sql":"select 1"}'), folha.formula_valida('{"op":"executa","args":[{"num":1},{"num":2}]}'),
        folha.formula_valida('{"var":"current_user"}'), folha.formula_valida('{"op":"divide","args":[{"num":1}]}'),
        folha.formula_valida('"SALARIO * 2"'), folha.formula_valida('{"base":"x; drop table"}'),
        folha.formula_valida('{"num":1,"var":"SALARIO"}')],
  ARRAY[false, false, false, false, false, false, false],
  'NEG fórmula: chave, operação e variável fora da lista, aridade errada, texto livre e nome de base inválido são recusados');
SELECT throws_ok(
  $$INSERT INTO folha.rubric_rule (account_id, camada, contract_id, code_id, forma_calculo, formula, vigencia_inicio, fonte)
    VALUES ('e0000000-0000-0000-0000-000000000027', 'contrato', pg_temp.cid('k1'), pg_temp.rub('COMISSAO'), 'formula',
            '{"op":"soma","args":[{"var":"SALARIO"},{"sql":"select 1"}]}', '2026-01-01', 'x')$$,
  '23514', NULL, 'NEG fórmula: a regra não é gravada com fórmula fora da gramática');

-- ===========================================================================
-- 4. Proporcionalidade por dias (derivado; critério do saldo de salário do parecer de rescisão:
--    salário / divisor x dias, dias de contrato no mês limitados ao divisor, mês inteiro = divisor;
--    divisor = parâmetro divisor_saldo_salario = 30, a_validar)
--      p1: admissão em 16/10/2026, salário 3.000,00 -> 16 dias -> 1.600,00; INSS 7,5% = 120,00; FGTS 128,00
--      p2: outubro inteiro (31 dias) com 10 dias de afastamento que suspende o pagamento -> 31 - 10 = 21 dias
--          (limite 30) -> 3.000,00 / 30 x 21 = 2.100,00
--      p3: desligamento em 10/10/2026 -> 10 dias -> 1.000,00
--      p5: afastamento que NÃO suspende o pagamento -> salário inteiro
--      p6: admissão em 01/10 (mês de 31 dias) -> salário inteiro, não 31/30
--      p7: fevereiro inteiro (28 dias) -> salário inteiro
--      pf: salário 1.800,00, admissão em 16/10, 1 filho: remuneração do mês para o direito = 1.800,00
--          (<= 1.980,38); cota 67,54 x 16/30 = 36,0213... -> 36,02; salário 960,00; INSS 72,00
-- ===========================================================================
INSERT INTO c VALUES
  ('p1', pg_temp.mk(3000.00, 'clt', 'simples_nacional', '2026-10-16')),
  ('p2', pg_temp.mk(3000.00)),
  ('p3', pg_temp.mk(3000.00, 'clt', 'simples_nacional', '2023-01-01', '2026-10-10')),
  ('p4', pg_temp.mk(3000.00, 'clt', 'simples_nacional', '2026-11-03')),
  ('p5', pg_temp.mk(3000.00)),
  ('p6', pg_temp.mk(3000.00, 'clt', 'simples_nacional', '2026-10-01')),
  ('p7', pg_temp.mk(3000.00)),
  ('pf', pg_temp.mk(1800.00, 'clt', 'simples_nacional', '2026-10-16'));
INSERT INTO folha.contract_leave (account_id, contract_id, data_inicio, data_fim, motivo, suspende_pagamento) VALUES
  ('e0000000-0000-0000-0000-000000000027', pg_temp.cid('p2'), '2026-10-05', '2026-10-14', 'afastamento fictício', true),
  ('e0000000-0000-0000-0000-000000000027', pg_temp.cid('p5'), '2026-10-05', '2026-10-14', 'licença fictícia paga pela empresa', false);
INSERT INTO r SELECT x, folha.run_payroll_employee(pg_temp.run('m10'), pg_temp.cid(x)) FROM unnest(ARRAY['p1', 'p2', 'p3', 'p5', 'p6']) AS x;
INSERT INTO r VALUES ('p7', folha.run_payroll_employee(pg_temp.run('m02'), pg_temp.cid('p7')));
INSERT INTO r VALUES ('pf', folha.run_payroll_employee(pg_temp.run('m10'), pg_temp.cid('pf'), 0, 1));

SELECT pg_temp.confere('proporcional derivado p1 (admissão em 16/10)', pg_temp.res('p1'),
  '{"total_proventos": 160000, "inss_empregado": 12000, "irrf": 0, "fgts": 12800, "liquido": 148000}');
SELECT is((pg_temp.item('p1', 'SALARIO_BASE')->>'quantidade')::numeric, 16::numeric, 'p1: 16 dias pagos');
SELECT ok(pg_temp.pend('p1') @> ARRAY['a_validar:divisor_saldo_salario'], 'p1: o divisor a_validar vira pendência');
SELECT is(round((pg_temp.res('p2')->>'total_proventos')::numeric * 100)::bigint, 210000::bigint,
  'proporcional derivado p2: 10 dias de afastamento sem pagamento em mês de 31 dias -> 21/30 do salário');
SELECT ok(pg_temp.pend('p2') @> ARRAY['a_validar:proporcionalidade_por_afastamento_criterio_de_dias'],
  'p2: o critério de dias do afastamento vira pendência');
SELECT is(round((pg_temp.res('p3')->>'total_proventos')::numeric * 100)::bigint, 100000::bigint,
  'proporcional derivado p3: desligamento em 10/10 -> 10/30 do salário');
SELECT ok(pg_temp.pend('p3') @> ARRAY['pendencia:desligamento_no_mes_conferir_se_o_saldo_sera_pago_na_rescisao'],
  'p3: desligamento no mês pela folha mensal vira pendência de cálculo');
SELECT is(
  ARRAY[(pg_temp.res('p5')->>'total_proventos')::numeric, (pg_temp.res('p6')->>'total_proventos')::numeric,
        (pg_temp.res('p7')->>'total_proventos')::numeric],
  ARRAY[3000.00, 3000.00, 3000.00]::numeric[],
  'proporcional derivado: afastamento pago, admissão no dia 1º de mês de 31 dias e fevereiro inteiro = salário inteiro');
SELECT ok(NOT pg_temp.pend('p6') @> ARRAY['a_validar:divisor_saldo_salario'], 'mês inteiro não lê o divisor nem gera a pendência');
SELECT throws_like($$SELECT folha.run_payroll_employee(pg_temp.run('m10'), pg_temp.cid('p4'))$$,
  'Contrato % sem dias de contrato na competência 2026-10-01', 'NEG: contrato admitido depois do mês não entra na folha');
SELECT pg_temp.confere('proporcional derivado pf (salário-família com cota proporcional)', pg_temp.res('pf'),
  '{"total_proventos": 99602, "inss_empregado": 7200, "liquido": 92402}');
SELECT is(round((pg_temp.item('pf', 'SALARIO_FAMILIA')->>'valor')::numeric * 100)::bigint, 3602::bigint,
  'pf: cota de 67,54 x 16/30 = 36,02');
SELECT is((pg_temp.item('pf', 'SALARIO_FAMILIA')->>'base_calculo')::numeric, 1800.00::numeric,
  'pf: o direito é aferido pela remuneração que seria devida no mês inteiro (1.800,00), não pelos dias pagos');
SELECT ok(pg_temp.pend('pf') @> ARRAY['a_validar:salario_familia_divisor_da_fracao_de_dias'],
  'pf: o divisor da fração do salário-família segue como pendência');
SELECT is(
  (SELECT d.proporcional::text || '/' || d.dias || '/' || d.dias_contrato || '/' || d.dias_afastamento
     FROM folha.dias_proporcionais(pg_temp.cid('p2'), '2026-10-01') d),
  'true/21/31/10', 'dias_proporcionais: 31 dias de contrato, 10 de afastamento, 21 pagos');

-- ===========================================================================
-- 5. Tipos de processo e várias folhas por competência
-- ===========================================================================
-- Adiantamento e mensal (derivado sobre o CD-02 do parecer: CLT 3.000,00 no Simples, INSS 248,60, IRRF 0).
--   Adiantamento de 1.200,00 pago em 15/10; na mensal: 3.000,00 - 1.200,00 - 248,60 = 1.551,40
INSERT INTO c VALUES ('a1', pg_temp.mk(3000.00));
INSERT INTO folha.payroll_entry (account_id, contract_id, code_id, competencia, tipo_processo, valor)
VALUES ('e0000000-0000-0000-0000-000000000027', pg_temp.cid('a1'), pg_temp.rub('ADIANTAMENTO_SALARIAL_PAGO'), '2026-10-01', 'adiantamento', 1200.00);
INSERT INTO r VALUES ('a1_ad', folha.run_payroll_employee(pg_temp.run('ad10'), pg_temp.cid('a1')));
INSERT INTO r VALUES ('a1_m',  folha.run_payroll_employee(pg_temp.run('m10'),  pg_temp.cid('a1')));
SELECT pg_temp.confere('adiantamento derivado', pg_temp.res('a1_ad'),
  '{"total_proventos": 120000, "total_descontos": 0, "liquido": 120000, "inss_empregado": 0, "irrf": 0, "fgts": 0, "inss_patronal": 0}');
SELECT is(pg_temp.itens('a1_ad'), 'ADIANTAMENTO_SALARIAL_PAGO=120000/lancamento', 'adiantamento: só a rubrica do adiantamento');
SELECT pg_temp.confere('mensal com adiantamento (derivado sobre o CD-02)', pg_temp.res('a1_m'),
  '{"total_proventos": 300000, "total_descontos": 144860, "inss_empregado": 24860, "irrf": 0, "fgts": 24000, "liquido": 155140}');
SELECT is(pg_temp.itens('a1_m'),
  'SALARIO_BASE=300000/motor ADIANTAMENTO_SALARIAL=120000/motor INSS_EMPREGADO=24860/motor IRRF=0/motor FGTS_DEPOSITO=24000/motor',
  'mensal: o adiantamento pago na competência é descontado e não reduz as bases');

-- Complementar (derivado sobre CD-02 e CD-08 do parecer). Comissão de 1.000,00 paga em 31/10, mesmo mês.
--   INSS: INSS(4.000,00) - INSS(3.000,00) = 368,60 - 248,60 = 120,00 (a progressão não recomeça)
--   IRRF: rendimento do mês 4.000,00, INSS 368,60 -> simplificado; base 3.392,80; 114,76; redução zera; menos 0 já retido = 0
--   FGTS 80,00; líquido 880,00
INSERT INTO folha.payroll_entry (account_id, contract_id, code_id, competencia, tipo_processo, valor)
VALUES ('e0000000-0000-0000-0000-000000000027', pg_temp.cid('a1'), pg_temp.rub('COMISSAO'), '2026-10-01', 'complementar', 1000.00);
INSERT INTO r VALUES ('a1_co', folha.run_payroll_employee(pg_temp.run('co10'), pg_temp.cid('a1')));
SELECT pg_temp.confere('complementar derivado', pg_temp.res('a1_co'),
  '{"total_proventos": 100000, "inss_empregado": 12000, "irrf": 0, "fgts": 8000, "liquido": 88000}');
SELECT is(pg_temp.itens('a1_co'), 'COMISSAO=100000/lancamento INSS_EMPREGADO=12000/motor IRRF=0/motor FGTS_DEPOSITO=8000/motor',
  'complementar: sem salário; só o lançado e os tributos da diferença');
SELECT ok(pg_temp.pend('a1_co') @> ARRAY['a_validar:irrf_complementar_soma_dos_pagamentos_do_mes'],
  'complementar: o critério do IRRF (soma dos pagamentos do mês) vira pendência');
SELECT is(
  (SELECT string_agg(r.tipo_processo, ',' ORDER BY r.tipo_processo) FROM folha.payroll_run r
     JOIN folha.payroll_result pr ON pr.run_id = r.run_id WHERE pr.contract_id = pg_temp.cid('a1') AND r.competencia = '2026-10-01'),
  'adiantamento,complementar,mensal', 'três folhas de tipos diferentes para o mesmo contrato na mesma competência');
SELECT throws_ok(
  $$INSERT INTO folha.payroll_run (account_id, competencia, tipo_processo) VALUES ('e0000000-0000-0000-0000-000000000027', '2026-10-01', 'mensal')$$,
  '23505', NULL, 'NEG: mesma conta, competência, tipo e sequência não se repete');
SELECT throws_ok(
  $$INSERT INTO folha.payroll_run (account_id, competencia, tipo_processo) VALUES ('e0000000-0000-0000-0000-000000000027', '2026-10-01', 'plr')$$,
  '23514', NULL, 'NEG: tipo de processo fora da lista');
SELECT throws_ok(
  $$INSERT INTO folha.payroll_run (account_id, competencia, sequencia) VALUES ('e0000000-0000-0000-0000-000000000027', '2026-10-15', 9)$$,
  '23514', NULL, 'NEG: competência é o primeiro dia do mês');
INSERT INTO c VALUES ('a2', pg_temp.mk(3000.00));
SELECT throws_like($$SELECT folha.run_payroll_employee(pg_temp.run('ad10'), pg_temp.cid('a2'))$$,
  'Folha de adiantamento sem lançamento para o contrato %', 'NEG: adiantamento sem lançamento');
SELECT throws_like($$SELECT folha.run_payroll_employee(pg_temp.run('co10'), pg_temp.cid('a2'))$$,
  'Folha complementar sem lançamento para o contrato %', 'NEG: complementar sem lançamento');

-- 13º: CT-01 (1ª parcela) e CT-02 (quitação com o adiantamento compensado) do parecer de 13º e férias.
--   Admissão em 15/01/2024, salário 4.500,00. A 2ª parcela busca o adiantamento na folha da 1ª.
--   Encargos (derivado; Lucro Presumido, RAT 1%, FAP 1,0000, terceiros 5,8%): na quitação, sobre 4.500,00:
--   900,00 / 45,00 / 261,00; na 1ª parcela, zero (o INSS do 13º incide na quitação).
INSERT INTO c VALUES ('ct01', pg_temp.mk(4500.00, 'clt', 'lucro_presumido', '2024-01-15', NULL, 0.01, 1.0000, 0.058));
INSERT INTO r VALUES ('ct01', folha.run_payroll_employee(pg_temp.run('d1'), pg_temp.cid('ct01')));
INSERT INTO r VALUES ('ct02', folha.run_payroll_employee(pg_temp.run('d2'), pg_temp.cid('ct01')));
SELECT pg_temp.confere('CT-01 pela folha de 13º (1ª parcela)', pg_temp.res('ct01'),
  '{"total_proventos": 225000, "total_descontos": 0, "liquido": 225000, "inss_empregado": 0, "irrf": 0, "fgts": 18000}');
SELECT pg_temp.confere('CT-01 encargos (derivado)', pg_temp.res('ct01'), '{"inss_patronal": 0, "rat": 0, "terceiros": 0}');
SELECT is(pg_temp.itens('ct01'), 'DECIMO_TERCEIRO_1A=225000/motor FGTS_DEPOSITO=18000/motor', 'CT-01 (estrutura, derivado): itens por rubrica');
SELECT pg_temp.confere('CT-02 pela folha de 13º (2ª parcela)', pg_temp.res('ct02'),
  '{"total_proventos": 450000, "inss_empregado": 43151, "irrf": 0, "liquido": 181849, "fgts": 18000}');
SELECT pg_temp.confere('CT-02 encargos (derivado)', pg_temp.res('ct02'), '{"inss_patronal": 90000, "rat": 4500, "terceiros": 26100}');
SELECT is(pg_temp.itens('ct02'),
  'DECIMO_TERCEIRO_2A=450000/motor DECIMO_TERCEIRO_ADIANT_COMP=225000/motor INSS_13_SALARIO=43151/motor IRRF_13_SALARIO=0/motor FGTS_DEPOSITO=18000/motor',
  'CT-02 (estrutura, derivado): itens por rubrica; o adiantamento compensado veio da folha da 1ª parcela');
SELECT is(pg_temp.bases('ct02'), 'FGTS_13=225000 INSS_13=450000 IRRF_13=450000', 'CT-02 (estrutura, derivado): bases de 13º separadas das do mês');
SELECT ok(pg_temp.pend('ct02') @> ARRAY['a_validar:irrf_separado_reducao_lei_15270_alcance_e_teto',
                                        'a_validar:irrf_separado_desconto_simplificado_nao_aplicado'],
  'CT-02: o IRRF do 13º zerado pela redução leva as pendências próprias do IRRF em separado');
INSERT INTO c VALUES ('d_sem', pg_temp.mk(3000.00, 'clt', 'lucro_presumido', '2023-01-01', NULL, 0.01, 1.0000, 0.058));
INSERT INTO folha.payroll_process_input (account_id, run_id, contract_id, parametros)
VALUES ('e0000000-0000-0000-0000-000000000027', pg_temp.run('d2'), pg_temp.cid('d_sem'), '{"parcela": 3}');
SELECT throws_ok($$SELECT folha.run_payroll_employee(pg_temp.run('d2'), pg_temp.cid('d_sem'))$$,
  'P0001', 'Parâmetro de processo desconhecido: parcela', 'NEG: parâmetro de processo fora da lista é recusado');

-- Férias: CT-08 do parecer (30 dias, faixa isenta; admissão 01/08/2024, salário 1.900,00, gozo em 01/09/2026).
--   Encargos (derivado; Lucro Presumido, RAT 1%, FAP 1,0000, terceiros 5,8%) sobre 2.533,33:
--   506,666 -> 506,67; 25,3333 -> 25,33; 146,93314 -> 146,93. Folha paga em 28/08, antes da competência.
INSERT INTO c VALUES ('ct08', pg_temp.mk(1900.00, 'clt', 'lucro_presumido', '2024-08-01', NULL, 0.01, 1.0000, 0.058));
INSERT INTO folha.payroll_process_input (account_id, run_id, contract_id, parametros)
VALUES ('e0000000-0000-0000-0000-000000000027', pg_temp.run('fe09'), pg_temp.cid('ct08'),
        '{"inicio_gozo": "2026-09-01", "periodo_aquisitivo_inicio": "2025-08-01", "dias_gozo": 30}');
INSERT INTO r VALUES ('ct08', folha.run_payroll_employee(pg_temp.run('fe09'), pg_temp.cid('ct08')));
SELECT pg_temp.confere('CT-08 pela folha de férias', pg_temp.res('ct08'),
  '{"total_proventos": 253333, "inss_empregado": 20368, "irrf": 0, "liquido": 232965, "fgts": 20267}');
SELECT pg_temp.confere('CT-08 encargos (derivado)', pg_temp.res('ct08'), '{"inss_patronal": 50667, "rat": 2533, "terceiros": 14693}');
SELECT is(pg_temp.itens('ct08'),
  'FERIAS_GOZO=190000/motor FERIAS_TERCO=63333/motor INSS_EMPREGADO=20368/motor IRRF_FERIAS=0/motor FGTS_DEPOSITO=20267/motor',
  'CT-08 (estrutura, derivado): itens por rubrica');
SELECT ok(pg_temp.pend('ct08') @> ARRAY['pendencia:inss_do_recibo_provisorio_reapurar_na_folha_do_mes_de_gozo',
                                        'a_validar:irrf_ferias_apurado_pela_data_de_inicio_do_gozo_e_nao_pela_de_pagamento'],
  'CT-08: pendências do recibo de férias gravadas como dado');
SELECT ok(NOT pg_temp.pend('ct08') @> ARRAY['a_validar:irrf_separado_reducao_lei_15270_alcance_e_teto'],
  'CT-08: base isenta na tabela, sem pendência de redução');
INSERT INTO c VALUES ('fe_x', pg_temp.mk(1900.00, 'clt', 'lucro_presumido', '2024-08-01', NULL, 0.01, 1.0000, 0.058));
SELECT throws_ok($$SELECT folha.run_payroll_employee(pg_temp.run('fe09'), pg_temp.cid('fe_x'))$$,
  'P0001', 'Parâmetro de processo obrigatório não informado: inicio_gozo', 'NEG: férias sem as entradas do processo');

-- Rescisão: G01 do parecer de rescisão (sem justa causa, aviso indenizado de 39 dias; admissão 10/03/2023, 2.400,00).
--   Encargos (derivado; Lucro Presumido, RAT 1%, FAP 1,0000, terceiros 5,8%) sobre saldo 1.040,00 + 13º 2.200,00
--   = 3.240,00 (o aviso indenizado não compõe a base, parâmetro a_validar da 0023): 648,00 / 32,40 / 187,92.
INSERT INTO c VALUES ('g01', pg_temp.mk(2400.00, 'clt', 'lucro_presumido', '2023-03-10', NULL, 0.01, 1.0000, 0.058));
INSERT INTO folha.payroll_process_input (account_id, run_id, contract_id, parametros)
VALUES ('e0000000-0000-0000-0000-000000000027', pg_temp.run('re10'), pg_temp.cid('g01'),
        '{"data_demissao": "2026-10-13", "motivo": "sem_justa_causa", "aviso_modo": "indenizado_empregador",
          "periodo_aquisitivo_inicio": "2026-03-10", "periodos_vencidos": 1, "fgts_base_extrato": 6500.00}');
INSERT INTO r VALUES ('g01', folha.run_payroll_employee(pg_temp.run('re10'), pg_temp.cid('g01')));
SELECT pg_temp.confere('G01 pela folha de rescisão', pg_temp.res('g01'),
  '{"total_proventos": 1169333, "total_descontos": 25169, "liquido": 1144164, "inss_empregado": 25169, "irrf": 0, "fgts": 50880}');
SELECT pg_temp.confere('G01 encargos (derivado)', pg_temp.res('g01'), '{"inss_patronal": 64800, "rat": 3240, "terceiros": 18792}');
SELECT is(pg_temp.itens('g01'),
  'RESC_SALDO_SALARIO=104000/motor AVISO_PREVIO_INDENIZADO=312000/motor RESC_DECIMO_TERCEIRO_PROP=220000/motor RESC_FERIAS_VENCIDAS=320000/motor RESC_FERIAS_PROP=213333/motor INSS_EMPREGADO=7800/motor INSS_13_SALARIO=17369/motor IRRF=0/motor FGTS_DEPOSITO=50880/motor FGTS_MULTA_RESCISORIA=280352/motor',
  'G01 (estrutura, derivado): verbas, descontos e FGTS por rubrica (férias com o terço na mesma rubrica)');
-- Bases do G01 (estrutura, derivado): FGTS do mês = saldo 1.040,00 + aviso 3.120,00; 8% x (4.160,00 + 2.200,00) = 508,80.
SELECT is(pg_temp.bases('g01'),
  'FGTS_13=220000 FGTS_MENSAL=416000 INSS_13=220000 INSS_MENSAL=104000 IRRF_13=220000 IRRF_MENSAL=104000',
  'G01 (estrutura, derivado): bases da rescisão');
SELECT throws_like($$SELECT folha.run_payroll_employee(pg_temp.run('m10'), pg_temp.cid('g01'))$$,
  'Contrato % já tem rescisão calculada na competência 2026-10-01%', 'NEG: contrato com rescisão não recebe também o salário na folha mensal');
SELECT throws_like($$SELECT folha.run_payroll_employee(pg_temp.run('re10'), pg_temp.cid('a1'))$$,
  'Parâmetro de processo obrigatório não informado: data_demissao', 'NEG: rescisão sem as entradas do processo');

-- ===========================================================================
-- 6. Múltiplos vínculos (derivado; parecer de INSS/FGTS, 5.1: INSS(outros + aqui) - INSS(outros),
--    soma limitada ao teto, a progressão não recomeça)
--      INSS(2.000,00) = 121,575 + 379,00 x 9% (34,11) = 155,685 -> 155,69
--      INSS(5.000,00) = 501,5144 -> 501,51 (CD-13 do parecer); teto: 988,09 (CD-04 do parecer)
--      aqui 3.000,00 com 2.000,00 em outra fonte: 501,51 - 155,69 = 345,82 (diferença de valores já
--        arredondados, como na fórmula do parecer; a diferença exata, 345,8294, daria 345,83: a_validar)
--      aqui 6.000,00 com 5.000,00 em outra fonte: 988,09 - 501,51 = 486,58
--      aqui 3.000,00 com 9.000,00 em outra fonte (acima do teto): 0,00
-- ===========================================================================
SELECT is(
  ARRAY[(SELECT valor_inss FROM folha.calc_inss_segurado_multiplos(3000.00, 'clt', '2026-10-01', 0, 2000.00)),
        (SELECT valor_inss FROM folha.calc_inss_segurado_multiplos(6000.00, 'clt', '2026-10-01', 0, 5000.00)),
        (SELECT valor_inss FROM folha.calc_inss_segurado_multiplos(3000.00, 'clt', '2026-10-01', 0, 9000.00)),
        (SELECT valor_inss FROM folha.calc_inss_segurado_multiplos(3000.00, 'clt', '2026-10-01', 0, 0))],
  ARRAY[345.82, 486.58, 0.00, 248.60]::numeric[],
  'múltiplos vínculos derivado: 345,82; 486,58; zero acima do teto; sem outra fonte = 248,60 (CD-02)');
SELECT is(
  (SELECT m.base_contribuicao::text || '/' || m.metodo FROM folha.calc_inss_segurado_multiplos(6000.00, 'clt', '2026-10-01', 0, 5000.00) m),
  '3475.55/progressivo_por_faixa_com_base_anterior', 'múltiplos vínculos: base de contribuição limitada ao que resta até o teto');
SELECT ok(
  (SELECT m.pendencias @> ARRAY['a_validar:inss_multiplos_vinculos_criterio_de_deducao_das_outras_fontes']
     FROM folha.calc_inss_segurado_multiplos(3000.00, 'clt', '2026-10-01', 0, 2000.00) m),
  'múltiplos vínculos: o critério segue a_validar e volta como pendência');
SELECT is(
  (SELECT m.valor_inss::text || '/' || (m.pendencias @> ARRAY['pendencia:inss_contribuinte_individual_com_outras_fontes_sem_regra_confirmada_nao_ajustado'])::text
     FROM folha.calc_inss_segurado_multiplos(6000.00, 'contribuinte_individual', '2026-10-01', 0, 5000.00) m),
  '660.00/true', 'contribuinte individual com outras fontes: sem regra confirmada, não ajusta e devolve pendência de cálculo');
SELECT throws_ok($$SELECT * FROM folha.calc_inss_segurado_multiplos(3000.00, 'clt', '2026-10-01', 0, -1)$$,
  'P0001', NULL, 'NEG: base de outra fonte negativa');
INSERT INTO c VALUES ('mv', pg_temp.mk(3000.00));
INSERT INTO folha.external_remuneration (account_id, employee_id, competencia, base_previdencia, origem)
VALUES ('e0000000-0000-0000-0000-000000000027', pg_temp.trab('mv'), '2026-10-01', 2000.00, 'outra fonte fictícia');
INSERT INTO r VALUES ('mv', folha.run_payroll_employee(pg_temp.run('m10'), pg_temp.cid('mv')));
SELECT pg_temp.confere('múltiplos vínculos pela folha (derivado)', pg_temp.res('mv'), '{"inss_empregado": 34582, "fgts": 24000, "liquido": 265418}');
SELECT ok(pg_temp.pend('mv') @> ARRAY['a_validar:inss_multiplos_vinculos_criterio_de_deducao_das_outras_fontes'],
  'múltiplos vínculos pela folha: pendência gravada');

-- ===========================================================================
-- 7. Trava de fechamento (bloqueio 2) e data de pagamento (bloqueio 5)
-- ===========================================================================
-- Folha m10b: CD-03 de novo, numa segunda folha mensal da competência.
INSERT INTO c VALUES ('t1', pg_temp.mk(5400.00, 'clt', 'lucro_real', '2023-01-01', NULL, 0.02, 1.5000, 0.058));
INSERT INTO r VALUES ('t1', folha.run_payroll_employee(pg_temp.run('m10b'), pg_temp.cid('t1')));
SELECT is(pg_temp.pend('t1'),
  ARRAY['a_validar:inss_arredondamento_metodo', 'a_validar:irrf_simplificado_pela_fonte_pagadora_ato_rfb'],
  'trava: o resultado tem duas pendências a_validar consultáveis');
SELECT throws_like($$SELECT folha.payroll_run_aprovar(pg_temp.run('m10b'), 'Responsável Fictício')$$,
  'Folha % está em draft e não pode ser aprovada', 'NEG trava: folha sem cálculo concluído não é aprovada');
SELECT throws_like($$SELECT folha.payroll_pendencias_liberar(pg_temp.run('m10b'), 'a_validar:inss_arredondamento_metodo', 'Responsável Fictício', 'motivo')$$,
  'Folha % está em draft: pendência só é liberada com o cálculo concluído', 'NEG trava: liberação antes de concluir o cálculo');
SELECT lives_ok($$SELECT folha.payroll_run_concluir_calculo(pg_temp.run('m10b'))$$, 'cálculo concluído');
SELECT is(
  (SELECT x.status || '/' || round(x.total_liquido * 100) || '/' || round(x.total_encargos_patronais * 100)
     FROM folha.payroll_run x WHERE x.run_id = pg_temp.run('m10b')),
  'calculated/469284/155520', 'folha calculada com os totais dos resultados (CD-03: líquido e encargos do parecer)');
SELECT throws_like($$SELECT folha.payroll_run_aprovar(pg_temp.run('m10b'), 'Responsável Fictício')$$,
  'Folha % tem 2 pendência(s) sem liberação registrada e não pode passar a approved',
  'NEG trava: pendência a_validar impede aprovar');
SELECT throws_like($$UPDATE folha.payroll_run SET status = 'approved' WHERE run_id = pg_temp.run('m10b')$$,
  'Folha % tem 2 pendência(s) sem liberação registrada e não pode passar a approved',
  'NEG trava: UPDATE direto do status também é barrado');
SELECT throws_like($$UPDATE folha.payroll_run SET status = 'closed' WHERE run_id = pg_temp.run('m10b')$$,
  'Folha %: não passa de calculated para closed',
  'NEG trava: UPDATE direto para fechada também é barrado (a folha só anda um passo por vez)');
SELECT throws_ok($$UPDATE folha.payroll_pendency SET liberada_em = now(), liberada_por = 'x', liberada_sessao = 'x', liberacao_motivo = 'x'$$,
  '42501', NULL, 'NEG trava: o worker não altera a pendência diretamente');
SELECT throws_ok($$SELECT folha.payroll_pendencias_liberar(pg_temp.run('m10b'), 'a_validar:inss_arredondamento_metodo', 'Responsável Fictício', '  ')$$,
  'P0001', 'payroll_pendencias_liberar: responsável e motivo são obrigatórios', 'NEG trava: liberação sem motivo');
SELECT throws_like($$SELECT folha.payroll_pendencias_liberar(pg_temp.run('m10b'), 'a_validar:inexistente', 'Responsável Fictício', 'motivo')$$,
  'Folha % não tem pendência aberta com o código a_validar:inexistente', 'NEG trava: liberação de código que não está pendente');
SELECT is(folha.payroll_pendencias_liberar(pg_temp.run('m10b'), 'a_validar:inss_arredondamento_metodo', 'Responsável Fictício', 'critério de centavos aceito para esta folha'),
  1, 'liberação explícita de uma pendência');
SELECT throws_like($$SELECT folha.payroll_run_aprovar(pg_temp.run('m10b'), 'Responsável Fictício')$$,
  'Folha % tem 1 pendência(s) sem liberação registrada e não pode passar a approved',
  'NEG trava: liberar uma pendência não libera a outra');
SELECT is(folha.payroll_pendencias_liberar(pg_temp.run('m10b'), 'a_validar:irrf_simplificado_pela_fonte_pagadora_ato_rfb', 'Responsável Fictício', 'simplificado aceito para esta folha'),
  1, 'liberação explícita da segunda pendência');
SELECT is(
  (SELECT p.liberada_por || '/' || p.liberacao_motivo || '/' || p.liberada_sessao || '/' || (p.liberada_em IS NOT NULL)::text
     FROM folha.payroll_pendency p WHERE p.run_id = pg_temp.run('m10b') AND p.codigo = 'a_validar:inss_arredondamento_metodo'),
  'Responsável Fictício/critério de centavos aceito para esta folha/dnex_folha_ci_login/true',
  'a liberação registra quem, quando, motivo e sessão');
SELECT is(
  (SELECT count(*) FROM folha.auditoria a WHERE a.recurso_id = pg_temp.run('m10b') AND a.acao = 'liberar_pendencia'),
  2::bigint, 'cada liberação fica na auditoria');
SELECT lives_ok($$SELECT folha.payroll_run_aprovar(pg_temp.run('m10b'), 'Responsável Fictício')$$, 'com as pendências liberadas, a folha é aprovada');
SELECT throws_like($$SELECT folha.run_payroll_employee(pg_temp.run('m10b'), pg_temp.cid('a2'))$$,
  'Folha % está em approved e não recebe cálculo', 'NEG: folha aprovada não recebe cálculo');
SELECT lives_ok($$SELECT folha.payroll_run_fechar(pg_temp.run('m10b'), 'Responsável Fictício')$$, 'folha aprovada com data de pagamento é fechada');
SELECT is(
  (SELECT x.status || '/' || x.approved_by || '/' || (x.fechado_em IS NOT NULL)::text FROM folha.payroll_run x WHERE x.run_id = pg_temp.run('m10b')),
  'closed/Responsável Fictício/true', 'folha fechada');
SELECT throws_like($$UPDATE folha.payroll_run SET data_pagamento = '2026-11-05' WHERE run_id = pg_temp.run('m10b')$$,
  'Folha % está fechada e não pode ser alterada', 'NEG: folha fechada não é alterada');

-- Sem data de pagamento: calcula com pendência de CÁLCULO, que não é liberável; a folha não aprova.
INSERT INTO c VALUES ('t2', pg_temp.mk(1200.00, 'estagio'));
INSERT INTO r VALUES ('t2', folha.run_payroll_employee(pg_temp.run('m10c'), pg_temp.cid('t2')));
SELECT is(pg_temp.pend('t2'),
  ARRAY['a_validar:estagio_nao_incidencia_lei_11788', 'a_validar:irrf_simplificado_pela_fonte_pagadora_ato_rfb',
        'pendencia:data_pagamento_nao_informada_usado_ultimo_dia_da_competencia'],
  'sem data de pagamento: a pendência de cálculo é gravada');
SELECT is(
  (SELECT string_agg(p.tipo, ',' ORDER BY p.codigo) FROM folha.payroll_pendency p JOIN r ON r.result_id = p.result_id WHERE r.caso = 't2'),
  'a_validar,a_validar,pendencia', 'tipo da pendência: duas a_validar (liberáveis) e uma de cálculo (não liberável)');
SELECT lives_ok($$SELECT folha.payroll_run_concluir_calculo(pg_temp.run('m10c'))$$, 'cálculo concluído (folha sem data de pagamento)');
SELECT is(folha.payroll_pendencias_liberar(pg_temp.run('m10c'), 'a_validar:estagio_nao_incidencia_lei_11788', 'Responsável Fictício', 'teste'), 1, 'a_validar liberada (1)');
SELECT is(folha.payroll_pendencias_liberar(pg_temp.run('m10c'), 'a_validar:irrf_simplificado_pela_fonte_pagadora_ato_rfb', 'Responsável Fictício', 'teste'), 1, 'a_validar liberada (2)');
SELECT throws_like(
  $$SELECT folha.payroll_pendencias_liberar(pg_temp.run('m10c'), 'pendencia:data_pagamento_nao_informada_usado_ultimo_dia_da_competencia', 'Responsável Fictício', 'teste')$$,
  'Pendência de cálculo % não é liberável%', 'NEG: pendência de cálculo não é liberável');
SELECT throws_like($$SELECT folha.payroll_run_aprovar(pg_temp.run('m10c'), 'Responsável Fictício')$$,
  'Folha % tem 1 pendência(s) sem liberação registrada e não pode passar a approved',
  'NEG: com pendência de cálculo aberta a folha não é aprovada (sem data de pagamento não há como fechar)');
SELECT throws_like($$UPDATE folha.payroll_run SET data_pagamento = '2026-10-31' WHERE run_id = pg_temp.run('m10c')$$,
  'Folha % está em calculated: competência, tipo de processo, empregador, totais e data de pagamento não podem ser alterados',
  'NEG: a data de pagamento não muda depois do cálculo (exige cancelar e recalcular)');
SELECT pg_temp.folha('m10e', 'mensal', '2026-10-01', NULL, 6);
SELECT throws_like($$UPDATE folha.payroll_run SET data_pagamento = '2026-09-30' WHERE run_id = pg_temp.run('m10e')$$,
  'Folha %: data de pagamento 2026-09-30 anterior ao início da competência 2026-10-01',
  'NEG: data de pagamento anterior ao início da competência é recusada');
SELECT lives_ok($$UPDATE folha.payroll_run SET data_pagamento = '2026-10-01' WHERE run_id = pg_temp.run('m10e')$$,
  'data de pagamento no primeiro dia da competência é aceita (folha em rascunho)');
SELECT throws_like(
  $$INSERT INTO folha.payroll_run (account_id, competencia, data_pagamento, sequencia) VALUES ('e0000000-0000-0000-0000-000000000027', '2026-12-01', '2026-11-30', 5)$$,
  'Folha %: data de pagamento 2026-11-30 anterior ao início da competência 2026-12-01',
  'NEG: folha mensal não nasce com pagamento anterior à competência');
SELECT is((SELECT x.data_pagamento FROM folha.payroll_run x WHERE x.run_id = pg_temp.run('fe09')), '2026-08-28'::date,
  'férias: a folha é paga antes do gozo (única exceção à regra)');
SELECT throws_ok(
  format($$INSERT INTO folha.payroll_run (account_id, competencia, data_pagamento, status, sequencia)
           VALUES ('e0000000-0000-0000-0000-000000000027', '2026-07-01', '2026-07-31', %L, 5)$$, x.st),
  'P0001', 'Folha só pode ser criada em draft (recebido: ' || x.st || ')', 'NEG: folha não nasce em ' || x.st)
  FROM unnest(ARRAY['calculating', 'calculated', 'approved', 'closed', 'cancelled']) AS x(st);

-- Dezembro pago em janeiro (derivado sobre o CD-03): competência 12/2026 paga em 05/01/2027.
--   INSS pela tabela da competência (2026): 557,51. IRRF pela data do pagamento (05/01/2027).
--   A tabela do IRRF de 2026 agora fecha em 31/12/2026: sem tabela de 2027 o cálculo levanta erro.
--   Com uma tabela FICTÍCIA de 2027 (cópia da de 2026, só nesta transação) o IRRF é 149,65.
INSERT INTO c VALUES ('dez', pg_temp.mk(5400.00, 'clt', 'lucro_real', '2023-01-01', NULL, 0.02, 1.5000, 0.058));
SELECT throws_ok($$SELECT folha.run_payroll_employee(pg_temp.run('m12'), pg_temp.cid('dez'))$$,
  'P0001', 'Tabela IRRF não encontrada para competência 2027-01-05',
  'NEG: pagamento datado em 2027 sem tabela de IRRF do ano levanta erro (não usa a de 2026)');
SELECT is((SELECT count(*) FROM folha.payroll_result pr WHERE pr.run_id = pg_temp.run('m12')), 0::bigint,
  'NEG: nada gravado para o pagamento sem tabela');
RESET SESSION AUTHORIZATION;
INSERT INTO folha.tax_table_version (tipo, vigencia_inicio, vigencia_fim, tabela_json, source_url, source_hash, captured_at)
SELECT t.tipo, '2027-01-01', '2027-12-31', t.tabela_json, t.source_url, 'rotulo:ficticia-de-teste-copia-de-2026', t.captured_at
  FROM folha.tax_table_version t WHERE t.tipo = 'irrf' AND t.vigencia_inicio = '2026-01-01';
SET LOCAL SESSION AUTHORIZATION dnex_folha_ci_login;
INSERT INTO r VALUES ('dez', folha.run_payroll_employee(pg_temp.run('m12'), pg_temp.cid('dez')));
SELECT pg_temp.confere('dezembro pago em janeiro (derivado sobre o CD-03)', pg_temp.res('dez'),
  '{"inss_empregado": 55751, "irrf": 14965, "fgts": 43200, "liquido": 469284}');
SELECT is((pg_temp.item('dez', 'IRRF')->'detalhe'->>'data_pagamento'), '2027-01-05', 'dezembro pago em janeiro: o IRRF registra a data de pagamento usada');
SELECT lives_ok($$SELECT folha.payroll_run_concluir_calculo(pg_temp.run('m12'))$$, 'dezembro: cálculo concluído');
SELECT is(
  (SELECT sum(folha.payroll_pendencias_liberar(pg_temp.run('m12'), x, 'Responsável Fictício', 'teste'))
     FROM unnest(pg_temp.pend('dez')) AS x),
  2::bigint, 'dezembro: pendências liberadas');
SELECT lives_ok($$SELECT folha.payroll_run_aprovar(pg_temp.run('m12'), 'Responsável Fictício')$$, 'dezembro: aprovada');
SELECT lives_ok($$SELECT folha.payroll_run_fechar(pg_temp.run('m12'), 'Responsável Fictício')$$, 'dezembro pago em janeiro: fecha');

-- ===========================================================================
-- 8. Vigência sem tabela (bloqueio 3)
-- ===========================================================================
SELECT is(
  (SELECT string_agg(t.tipo || ':' || t.vigencia_fim, ' ' ORDER BY t.tipo) FROM folha.tax_table_version t
    WHERE t.tipo IN ('inss', 'salario_minimo') AND t.vigencia_inicio = '2026-01-01'),
  'inss:2026-12-31 salario_minimo:2026-12-31', 'as tabelas de INSS e de salário mínimo de 2026 fecham em 31/12/2026');
SELECT is_empty(
  $$SELECT t.tipo, t.vigencia_inicio FROM folha.tax_table_version t WHERE t.tipo IN ('inss', 'salario_minimo') AND t.vigencia_fim IS NULL$$,
  'nenhuma tabela de INSS ou de salário mínimo com vigência aberta');
INSERT INTO c VALUES ('v27', pg_temp.mk(3000.00));
SELECT throws_ok($$SELECT folha.run_payroll_employee(pg_temp.run('m2701'), pg_temp.cid('v27'))$$,
  'P0001', 'Tabela INSS não encontrada para competência 2027-01-01', 'NEG: competência de 2027 sem tabela do ano levanta erro');
SELECT is((SELECT count(*) FROM folha.payroll_result pr WHERE pr.run_id = pg_temp.run('m2701')), 0::bigint,
  'NEG: nada gravado para a competência sem tabela');
SELECT throws_ok($$SELECT * FROM folha.calc_inss(3000.00, '2027-01-01')$$,
  'P0001', 'Tabela INSS não encontrada para competência 2027-01-01', 'NEG: calc_inss em 2027 não usa a tabela de 2026');
SELECT is((SELECT valor_inss FROM folha.calc_inss(3000.00, '2026-12-31')), 248.60::numeric, 'último dia de 2026 ainda usa a tabela de 2026');

-- ===========================================================================
-- 9. Exceções para remuneração nula ou negativa (bloqueio 5) e IRRF em separado (bloqueio 4)
-- ===========================================================================
SELECT throws_ok($$SELECT * FROM folha.calc_inss(NULL, '2026-10-01')$$, 'P0001', 'calc_inss: salário de contribuição inválido: NULL', 'NEG: INSS com remuneração nula');
SELECT throws_ok($$SELECT * FROM folha.calc_inss(-0.01, '2026-10-01')$$, 'P0001', 'calc_inss: salário de contribuição inválido: -0.01', 'NEG: INSS com remuneração negativa');
SELECT throws_ok($$SELECT * FROM folha.calc_fgts(NULL, 'clt', '2026-10-01')$$, 'P0001', 'calc_fgts: remuneração inválida: NULL', 'NEG: FGTS com remuneração nula');
SELECT throws_ok($$SELECT * FROM folha.calc_fgts(-1, 'clt', '2026-10-01')$$, 'P0001', 'calc_fgts: remuneração inválida: -1', 'NEG: FGTS com remuneração negativa');
SELECT throws_ok($$SELECT * FROM folha.calc_fgts(-1, 'estagio', '2026-10-01')$$, 'P0001', 'calc_fgts: remuneração inválida: -1', 'NEG: FGTS negativo é recusado também na categoria sem depósito');
SELECT throws_ok($$SELECT folha.calc_irrf_separado(NULL, 0, 0, '2026-10-31')$$, 'P0001', 'calc_irrf_separado: rendimento inválido: NULL', 'NEG: IRRF em separado com rendimento nulo');
SELECT throws_ok($$SELECT folha.calc_irrf_separado(-5, 0, 0, '2026-10-31')$$, 'P0001', 'calc_irrf_separado: rendimento inválido: -5', 'NEG: IRRF em separado com rendimento negativo');
SELECT throws_ok($$SELECT * FROM folha.calc_irrf(-1, 0, 0, '2026-10-31')$$, 'P0001', 'calc_irrf: rendimento tributável inválido: -1', 'NEG: IRRF mensal com rendimento negativo');
SELECT throws_ok($$SELECT * FROM folha.calc_irrf_separado_apurar(NULL, 0, 0, '2026-10-31')$$, 'P0001', NULL, 'NEG: apuração em separado com rendimento nulo');
SELECT is(
  ARRAY[(SELECT valor_inss FROM folha.calc_inss(0, '2026-10-01')), (SELECT fgts_deposito FROM folha.calc_fgts(0, 'clt', '2026-10-01')),
        folha.calc_irrf_separado(0, 0, 0, '2026-10-31'), (SELECT valor_irrf FROM folha.calc_irrf(0, 0, 0, '2026-10-31'))],
  ARRAY[0, 0, 0, 0]::numeric[], 'remuneração zero continua dando zero (só nula ou negativa é erro)');

-- IRRF em separado com pendência própria. Valores: derivados já conferidos na 0025 (13º de 5.000,00 com
-- INSS 501,51 -> 23,78, redução limitada a 312,89) e G03 do parecer de rescisão (8.000,00 -> 1.037,85).
SELECT is(
  (SELECT a.valor_irrf::text || '/' || round(a.reducao, 2) || '/' || array_to_string(a.pendencias, ',')
     FROM folha.calc_irrf_separado_apurar(5000.00, 501.51, 0, '2026-12-18') a),
  '23.78/312.89/a_validar:irrf_separado_reducao_lei_15270_alcance_e_teto,a_validar:irrf_separado_desconto_simplificado_nao_aplicado',
  '13º de 5.000,00: 23,78, com as duas pendências (teto da redução e simplificado não aplicado)');
SELECT is(
  (SELECT a.valor_irrf::text || '/' || cardinality(a.pendencias) FROM folha.calc_irrf_separado_apurar(8000.00, 921.51, 0, '2026-10-13') a),
  '1037.85/0', 'G03: 1.037,85 sem pendência (sem redução e com deduções legais acima do simplificado)');
SELECT is(
  (SELECT a.valor_irrf::text || '/' || cardinality(a.pendencias) FROM folha.calc_irrf_separado_apurar(2000.00, 150.00, 0, '2026-10-13') a),
  '0.00/0', 'rendimento isento na tabela: sem pendência');
SELECT is(
  (SELECT a.valor_irrf FROM folha.calc_irrf_separado_apurar(5000.00, 501.51, 0, '2026-12-18') a),
  folha.calc_irrf_separado(5000.00, 501.51, 0, '2026-12-18'), 'a apuração com pendências devolve o mesmo valor de calc_irrf_separado');

-- ===========================================================================
-- 10. RLS, chaves compostas e ACL
-- ===========================================================================
CREATE TEMP TABLE novas (tabela text PRIMARY KEY, modelo text NOT NULL, worker text NOT NULL);
INSERT INTO novas VALUES
  ('calculation_base', 'global_ou_conta', 'INSERT,SELECT,UPDATE'), ('rubric_incidence', 'global_ou_conta', 'INSERT,SELECT,UPDATE'),
  ('rubric_esocial_nature', 'global_ou_conta', 'INSERT,SELECT,UPDATE'), ('rubric_base', 'global_ou_conta', 'INSERT,SELECT,UPDATE'),
  ('rubric_rule', 'conta', 'INSERT,SELECT,UPDATE'), ('payroll_entry', 'conta', 'DELETE,INSERT,SELECT,UPDATE'),
  ('contract_leave', 'conta', 'INSERT,SELECT,UPDATE'), ('external_remuneration', 'conta', 'INSERT,SELECT,UPDATE'),
  ('payroll_process_input', 'conta', 'INSERT,SELECT,UPDATE'), ('payroll_result_item', 'conta', 'SELECT'),
  ('payroll_result_base', 'conta', 'SELECT'), ('payroll_pendency', 'conta', 'SELECT'),
  ('incidence_code', 'catalogo', 'SELECT'), ('esocial_rubric_nature', 'catalogo', 'SELECT'), ('rule_layer', 'catalogo', 'SELECT');
SELECT is_empty(
  $$SELECT n.tabela FROM novas n JOIN pg_class k ON k.oid = ('folha.' || n.tabela)::regclass
     WHERE NOT k.relrowsecurity OR NOT k.relforcerowsecurity$$,
  'as 15 tabelas novas têm RLS com FORCE');
SELECT is((SELECT count(*) FROM novas), 15::bigint, '15 tabelas novas (âncora)');
SELECT is_empty(
  $$SELECT n.tabela FROM novas n
     WHERE n.modelo = 'conta'
       AND NOT EXISTS (SELECT 1 FROM pg_policies p WHERE p.schemaname = 'folha' AND p.tablename = n.tabela AND p.cmd = 'ALL'
                          AND p.qual = '(account_id = ( SELECT folha.current_account_id() AS current_account_id))'
                          AND p.with_check = p.qual)$$,
  'tabelas por conta: policy única com a conta resolvida uma vez por comando');
SELECT is_empty(
  $$SELECT n.tabela FROM novas n
     WHERE n.modelo = 'global_ou_conta'
       AND NOT EXISTS (SELECT 1 FROM pg_policies p WHERE p.schemaname = 'folha' AND p.tablename = n.tabela AND p.cmd = 'ALL'
                          AND p.qual = '((account_id = ( SELECT folha.current_account_id() AS current_account_id)) OR (account_id IS NULL))'
                          AND p.with_check = '(account_id = ( SELECT folha.current_account_id() AS current_account_id))')$$,
  'tabelas com linha global: lê a própria conta e o global; grava só a própria conta');
SELECT is(
  (SELECT count(*) FROM pg_policies p WHERE p.schemaname = 'folha' AND p.tablename IN (SELECT tabela FROM novas)),
  15::bigint, 'uma policy por tabela nova, nenhuma adicional');
SELECT is_empty(
  $$SELECT n.tabela || ': ' || COALESCE((SELECT string_agg(priv, ',' ORDER BY priv)
                                          FROM unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE']) AS priv
                                         WHERE has_table_privilege('dnex_gestao_folha_worker', 'folha.' || n.tabela, priv)), '')
      FROM novas n
     WHERE COALESCE((SELECT string_agg(priv, ',' ORDER BY priv)
                       FROM unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE']) AS priv
                      WHERE has_table_privilege('dnex_gestao_folha_worker', 'folha.' || n.tabela, priv)), '') <> n.worker$$,
  'ACL: o worker tem exatamente os privilégios previstos em cada tabela nova');
-- ACL conferida sem o espelho de CI (o login de teste não entra na ACL das migrations).
RESET SESSION AUTHORIZATION;
DO $$ BEGIN PERFORM dnex_folha_ci_apoio.desfazer_espelho(); END $$;
SET LOCAL SESSION AUTHORIZATION dnex_folha_ci_login;
SELECT is_empty(
  $$SELECT n.tabela || ' <- ' || CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END || ':' || a.privilege_type
      FROM novas n JOIN pg_class k ON k.oid = ('folha.' || n.tabela)::regclass,
           LATERAL aclexplode(COALESCE(k.relacl, acldefault('r', k.relowner))) a
     WHERE a.grantee <> k.relowner
       AND NOT (a.grantee = 'dnex_gestao_folha_worker'::regrole)
       AND NOT (a.grantee = 'dnex_gestao_data_owner'::regrole AND a.privilege_type = 'SELECT')$$,
  'ACL: fora o worker, só o data_owner, e só para leitura; nada para PUBLIC, anon, authenticated ou service_role');
RESET SESSION AUTHORIZATION;
DO $$ BEGIN PERFORM dnex_folha_ci_apoio.espelhar_worker(); END $$;
SET LOCAL SESSION AUTHORIZATION dnex_folha_ci_login;

-- Isolamento: dados de outra conta entram como superusuário e não são vistos nem alcançados.
RESET SESSION AUTHORIZATION;
INSERT INTO c VALUES ('outro', pg_temp.mk(3000.00, 'clt', 'simples_nacional', '2023-01-01', NULL, NULL, NULL, NULL, 'e0000000-0000-0000-0000-000000000028'));
INSERT INTO folha.payroll_entry (account_id, contract_id, code_id, competencia, valor)
VALUES ('e0000000-0000-0000-0000-000000000028', pg_temp.cid('outro'), pg_temp.rub('COMISSAO'), '2026-10-01', 999.00);
INSERT INTO folha.earning_deduction_code (account_id, codigo, descricao, natureza)
VALUES ('e0000000-0000-0000-0000-000000000028', 'RUBRICA_DA_OUTRA', 'Rubrica de outra conta', 'provento');
CREATE TEMP TABLE alheio AS
  SELECT e.code_id FROM folha.earning_deduction_code e WHERE e.codigo = 'RUBRICA_DA_OUTRA';
GRANT SELECT ON alheio TO dnex_folha_ci_login;
INSERT INTO folha.calculation_base (account_id, codigo, descricao, finalidade)
VALUES ('e0000000-0000-0000-0000-000000000028', 'BASE_DA_OUTRA', 'Base de outra conta', 'outra');
CREATE TEMP TABLE base_alheia AS
  SELECT b.base_id FROM folha.calculation_base b WHERE b.codigo = 'BASE_DA_OUTRA';
GRANT SELECT ON base_alheia TO dnex_folha_ci_login;
SET LOCAL SESSION AUTHORIZATION dnex_folha_ci_login;
SELECT is((SELECT count(*) FROM folha.payroll_entry pe WHERE pe.account_id = 'e0000000-0000-0000-0000-000000000028'), 0::bigint,
  'RLS: lançamento de outra conta não é visto');
SELECT throws_ok(
  $$INSERT INTO folha.payroll_entry (account_id, contract_id, code_id, competencia, valor)
    VALUES ('e0000000-0000-0000-0000-000000000028', pg_temp.cid('outro'), pg_temp.rub('COMISSAO'), '2026-10-01', 1)$$,
  '42501', NULL, 'RLS: gravar lançamento em outra conta é recusado (WITH CHECK)');
SELECT throws_ok(
  $$INSERT INTO folha.payroll_entry (account_id, contract_id, code_id, competencia, valor)
    VALUES ('e0000000-0000-0000-0000-000000000027', pg_temp.cid('outro'), pg_temp.rub('COMISSAO'), '2026-10-01', 1)$$,
  '23503', NULL, 'chave composta: lançamento da conta não aponta contrato de outra conta');
SELECT throws_ok(
  $$INSERT INTO folha.rubric_rule (account_id, camada, contract_id, code_id, forma_calculo, valor, vigencia_inicio, fonte)
    VALUES ('e0000000-0000-0000-0000-000000000027', 'contrato', pg_temp.cid('outro'), pg_temp.rub('COMISSAO'), 'valor_fixo', 1, '2026-01-01', 'x')$$,
  '23503', NULL, 'chave composta: regra da conta não aponta contrato de outra conta');
SELECT throws_ok(
  $$INSERT INTO folha.payroll_entry (account_id, contract_id, code_id, competencia, valor)
    VALUES ('e0000000-0000-0000-0000-000000000027', pg_temp.cid('k1'), (SELECT code_id FROM alheio), '2026-10-01', 1)$$,
  '23514', 'payroll_entry: rubrica inexistente ou indisponível para esta conta', 'rubrica de outra conta não entra em lançamento desta conta');
SELECT throws_ok(
  $$INSERT INTO folha.rubric_base (account_id, code_id, base_id, vigencia_inicio)
    VALUES ('e0000000-0000-0000-0000-000000000027', pg_temp.rub('COMISSAO'),
            (SELECT b.base_id FROM folha.calculation_base b WHERE b.codigo = 'VARIAVEIS_CONTA'), '2026-01-01')$$,
  '23514', NULL, 'a conta não altera as bases de uma rubrica global (a ligação tem a conta da rubrica)');
SELECT throws_ok(
  $$INSERT INTO folha.rubric_incidence (account_id, code_id, tributo, incidencia_codigo, vigencia_inicio)
    VALUES (NULL, pg_temp.rub('COMISSAO'), 'irrf', 'NAO_INCIDE', '2030-01-01')$$,
  '42501', NULL, 'a conta não grava incidência global');
SELECT throws_like($$SELECT folha.run_payroll_employee(pg_temp.run('m10'), pg_temp.cid('outro'))$$,
  'Contrato % não encontrado', 'contrato de outra conta não é calculado');
SELECT throws_like($$SELECT * FROM folha.dias_proporcionais(pg_temp.cid('outro'), '2026-10-01')$$,
  'Contrato % não encontrado', 'dias_proporcionais não alcança contrato de outra conta');

-- ACL das funções das 0026 e 0027
CREATE TEMP TABLE acl (sig text PRIMARY KEY, papeis text[] NOT NULL);
INSERT INTO acl VALUES
  ('folha.calc_inss(numeric,date)',                                             ARRAY['dnex_gestao_folha_worker', 'dnex_gestao_data_owner']),
  ('folha.calc_fgts(numeric,text,date)',                                        ARRAY['dnex_gestao_folha_worker', 'dnex_gestao_data_owner']),
  ('folha.calc_irrf_separado(numeric,numeric,integer,date)',                    ARRAY['dnex_gestao_folha_worker', 'dnex_gestao_data_owner']),
  ('folha.calc_irrf_separado_apurar(numeric,numeric,integer,date)',             ARRAY['dnex_gestao_folha_worker', 'dnex_gestao_data_owner']),
  ('folha.calc_inss_segurado_multiplos(numeric,text,date,numeric,numeric)',     ARRAY['dnex_gestao_folha_worker', 'dnex_gestao_data_owner']),
  ('folha.dias_proporcionais(uuid,date)',                                       ARRAY['dnex_gestao_folha_worker', 'dnex_gestao_data_owner']),
  ('folha.run_payroll_employee(uuid,uuid,integer,integer)',                     ARRAY['dnex_gestao_folha_worker']),
  ('folha.payroll_run_concluir_calculo(uuid)',                                  ARRAY['dnex_gestao_folha_worker']),
  ('folha.payroll_pendencias_liberar(uuid,text,text,text)',                     ARRAY['dnex_gestao_folha_worker']),
  ('folha.payroll_run_aprovar(uuid,text)',                                      ARRAY['dnex_gestao_folha_worker']),
  ('folha.payroll_run_fechar(uuid,text)',                                       ARRAY['dnex_gestao_folha_worker']),
  ('folha.formula_valida(jsonb,integer)',                                       ARRAY['dnex_gestao_folha_worker']),
  ('folha.irrf_apurar(numeric,numeric,integer,date,text)',                      ARRAY[]::text[]),
  ('folha.rubrica_por_codigo(uuid,text)',                                       ARRAY[]::text[]),
  ('folha.rubrica_conferir(uuid,date)',                                         ARRAY[]::text[]),
  ('folha.bases_somar(jsonb,uuid,numeric,date)',                                ARRAY[]::text[]),
  ('folha.formula_avaliar(jsonb,jsonb,jsonb)',                                  ARRAY[]::text[]),
  ('folha.resolver_regra(uuid,uuid,uuid,date)',                                 ARRAY[]::text[]),
  ('folha.processo_parametros(uuid,uuid,uuid,text[],text[])',                   ARRAY[]::text[]),
  ('folha.folha_rubricas_calcular(uuid,uuid,uuid,text,date,date,integer,integer)', ARRAY[]::text[]),
  ('folha.folha_13o_calcular(uuid,uuid,uuid,text,date,date,integer)',           ARRAY[]::text[]),
  ('folha.folha_ferias_calcular(uuid,uuid,uuid,date,date,integer)',             ARRAY[]::text[]),
  ('folha.folha_rescisao_calcular(uuid,uuid,uuid,date,date,integer)',           ARRAY[]::text[]),
  ('folha.folha_gravar_resultado(uuid,uuid,uuid,date,jsonb)',                   ARRAY[]::text[]),
  ('folha.payroll_run_trava()',                                                 ARRAY[]::text[]),
  ('folha.exigir_rubrica_da_conta()',                                           ARRAY[]::text[]),
  ('folha.rubrica_derivar_tipo()',                                              ARRAY[]::text[]),
  ('folha.conta_imutavel()',                                                    ARRAY[]::text[]),
  ('folha.payroll_result_so_em_folha_aberta()',                                 ARRAY[]::text[]),
  ('folha.processo_pendencias_gerais(uuid,uuid,date)',                          ARRAY[]::text[]),
  ('folha.payroll_entry_consumido()',                                           ARRAY[]::text[]),
  ('folha.pendencia_tipo(text)',                                                ARRAY['dnex_gestao_folha_worker', 'dnex_gestao_data_owner']);
SELECT is_empty($$SELECT sig FROM acl WHERE to_regprocedure(sig) IS NULL$$, 'ACL: as 32 funções existem com a assinatura esperada');
SELECT is((SELECT count(*) FROM acl), 32::bigint, 'ACL: 32 funções conferidas (âncora)');
SELECT is_empty(
  $$SELECT acl.sig || ' <- ' || papel FROM acl, unnest(acl.papeis) AS papel
     WHERE NOT has_function_privilege(papel, to_regprocedure(acl.sig)::oid, 'execute')$$,
  'ACL: os papéis previstos executam');
-- ACL conferida sem o espelho de CI (o login de teste não entra na ACL das migrations).
RESET SESSION AUTHORIZATION;
DO $$ BEGIN PERFORM dnex_folha_ci_apoio.desfazer_espelho(); END $$;
SET LOCAL SESSION AUTHORIZATION dnex_folha_ci_login;
SELECT is_empty(
  $$SELECT acl.sig || ' <- ' || CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END
      FROM acl JOIN pg_proc p ON p.oid = to_regprocedure(acl.sig)::oid,
           LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
     WHERE a.grantee <> p.proowner
       AND (a.grantee = 0 OR NOT (a.grantee::regrole::text = ANY (acl.papeis)))$$,
  'ACL: nenhum outro papel (nem PUBLIC) executa as funções das 0026 e 0027');
RESET SESSION AUTHORIZATION;
DO $$ BEGIN PERFORM dnex_folha_ci_apoio.espelhar_worker(); END $$;
SET LOCAL SESSION AUTHORIZATION dnex_folha_ci_login;
SELECT is_empty(
  $$SELECT acl.sig FROM acl JOIN pg_proc p ON p.oid = to_regprocedure(acl.sig)::oid
     WHERE p.prosecdef AND NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) AS cfg WHERE cfg LIKE 'search_path=%')$$,
  'toda função SECURITY DEFINER das 0026 e 0027 tem search_path fixo');
SELECT throws_ok($$SELECT folha.folha_gravar_resultado('e0000000-0000-0000-0000-000000000027', pg_temp.run('m10'), pg_temp.cid('k1'), '2026-10-01', '{}'::jsonb)$$,
  '42501', NULL, 'o worker não chama a gravação do resultado diretamente');
SELECT throws_ok($$SELECT * FROM folha.resolver_regra('e0000000-0000-0000-0000-000000000028', pg_temp.cid('outro'), pg_temp.rub('COMISSAO'), '2026-10-01')$$,
  '42501', NULL, 'o worker não chama a resolução de regra (que recebe a conta por argumento) diretamente');
SELECT throws_ok(
  $$INSERT INTO folha.payroll_result_item (account_id, result_id, code_id, rubrica_codigo, tipo_rubrica, ordem, valor, camada_regra)
    SELECT 'e0000000-0000-0000-0000-000000000027', result_id, pg_temp.rub('COMISSAO'), 'COMISSAO', 'provento', 99, 1, 'motor' FROM r WHERE caso = 'k1'$$,
  '42501', NULL, 'o worker não grava item de resultado fora do motor');

-- ===========================================================================
-- 11. Achados das revisões independentes (SQL/segurança e DP)
-- ===========================================================================
-- Linhas globais não podem ser tomadas por uma conta (a policy deixa LER o global).
SELECT throws_ok(
  $$UPDATE folha.calculation_base SET account_id = 'e0000000-0000-0000-0000-000000000027' WHERE account_id IS NULL AND codigo = 'MEDIAS'$$,
  '23514', NULL, 'NEG: a conta não toma para si uma base global');
SELECT throws_ok(
  $$UPDATE folha.calculation_base SET descricao = 'alterada' WHERE account_id IS NULL AND codigo = 'MEDIAS'$$,
  '42501', NULL, 'NEG: a conta não altera uma base global');
SELECT throws_ok(
  $$UPDATE folha.rubric_base SET account_id = 'e0000000-0000-0000-0000-000000000027', code_id = pg_temp.rub('PREMIO_PROD')
     WHERE account_id IS NULL AND code_id = pg_temp.rub('SALARIO_BASE')$$,
  '23514', NULL, 'NEG: a conta não toma para si as bases do salário global');
SELECT throws_ok(
  $$UPDATE folha.rubric_incidence SET account_id = 'e0000000-0000-0000-0000-000000000027', code_id = pg_temp.rub('PREMIO_PROD')
     WHERE account_id IS NULL AND code_id = pg_temp.rub('SALARIO_BASE')$$,
  '23514', NULL, 'NEG: a conta não toma para si as incidências do salário global');
SELECT throws_ok(
  $$UPDATE folha.earning_deduction_code SET account_id = 'e0000000-0000-0000-0000-000000000027', is_global = false
     WHERE account_id IS NULL AND codigo = 'HE_100'$$,
  '23514', NULL, 'NEG: a conta não toma para si uma rubrica global');
SELECT is((SELECT count(*) FROM folha.rubric_base rb WHERE rb.account_id IS NULL AND rb.code_id = pg_temp.rub('SALARIO_BASE')), 4::bigint,
  'as quatro bases do salário global continuam globais');
SELECT throws_ok(
  $$INSERT INTO folha.earning_deduction_code (account_id, codigo, descricao, natureza)
    VALUES ('e0000000-0000-0000-0000-000000000027', 'INSS_EMPREGADO', 'sombra', 'provento')$$,
  '23514', NULL, 'NEG: rubrica de conta não repete código de rubrica global (não toma o lugar da rubrica do motor)');
SELECT throws_ok(
  $$INSERT INTO folha.earning_deduction_code (account_id, codigo, descricao, natureza, is_global)
    VALUES ('e0000000-0000-0000-0000-000000000027', 'FALSA_GLOBAL', 'x', 'provento', true)$$,
  '23514', NULL, 'NEG: rubrica de conta não se declara global');
SELECT throws_ok(
  $$INSERT INTO folha.rubric_rule (account_id, camada, contract_id, code_id, forma_calculo, percentual, base_id, vigencia_inicio, fonte)
    VALUES ('e0000000-0000-0000-0000-000000000027', 'contrato', pg_temp.cid('k1'), pg_temp.rub('COMISSAO'), 'percentual_base', 0.1,
            (SELECT base_id FROM base_alheia), '2026-01-01', 'x')$$,
  '23514', NULL, 'NEG: regra da conta não aponta base de cálculo de outra conta');
SELECT throws_ok(
  $$INSERT INTO folha.rubric_rule (account_id, camada, contract_id, code_id, forma_calculo, formula, automatica, vigencia_inicio, fonte)
    VALUES ('e0000000-0000-0000-0000-000000000027', 'contrato', pg_temp.cid('k1'), pg_temp.rub('COMISSAO'), 'formula',
            '{"op":"multiplica","args":[{"var":"QUANTIDADE"},{"num":2}]}', true, '2026-01-01', 'x')$$,
  '23514', NULL, 'NEG: regra automática não usa variável que só existe no lançamento');
SELECT throws_ok(
  $$INSERT INTO folha.payroll_result (run_id, account_id, employee_id, contract_id, total_proventos, total_descontos, liquido,
                                      inss_empregado, irrf, fgts, calculation_hash)
    VALUES (pg_temp.run('m10'), 'e0000000-0000-0000-0000-000000000027', pg_temp.trab('a2'), pg_temp.cid('a2'), 9, 0, 9, 0, 0, 0, 'forjado')$$,
  '42501', NULL, 'NEG: o worker não grava resultado de folha fora do motor');

-- Folha m10d: máquina de estados e campos congelados. Contratos a2 (sem mensal ainda) e pa.
SELECT pg_temp.folha('m10d', 'mensal', '2026-10-01', '2026-10-31', 4);
SELECT pg_temp.folha('m09',  'mensal', '2026-09-01', '2026-09-30');
SELECT throws_like($$SELECT folha.run_payroll_employee(pg_temp.run('m10d'), pg_temp.cid('k1'))$$,
  'Contrato % já tem folha mensal ou complementar calculada na competência 2026-10-01%',
  'NEG: o mesmo contrato não entra em duas folhas mensais da competência');
SELECT throws_like($$UPDATE folha.payroll_run SET status = 'closed' WHERE run_id = pg_temp.run('m10d')$$,
  'Folha %: não passa de draft para closed', 'NEG: folha não salta de rascunho para fechada');
-- Pensão lançada (derivado): 200,00 de desconto; o IRRF ainda não a deduz e isso vira pendência.
INSERT INTO c VALUES ('pa', pg_temp.mk(3000.00));
INSERT INTO folha.payroll_entry (account_id, contract_id, code_id, competencia, valor)
VALUES ('e0000000-0000-0000-0000-000000000027', pg_temp.cid('pa'), pg_temp.rub('PENSAO_ALIMENTICIA'), '2026-10-01', 200.00),
       ('e0000000-0000-0000-0000-000000000027', pg_temp.cid('pa'), pg_temp.rub('MULTA_ART477'), '2026-10-01', 100.00);
INSERT INTO r VALUES ('pa', folha.run_payroll_employee(pg_temp.run('m10d'), pg_temp.cid('pa')));
SELECT ok(pg_temp.pend('pa') @> ARRAY['pendencia:pensao_alimenticia_nao_deduzida_da_base_do_irrf'],
  'pensão alimentícia lançada: a falta da dedução no IRRF vira pendência de cálculo');
SELECT lives_ok($$SELECT folha.payroll_run_concluir_calculo(pg_temp.run('m10d'))$$, 'm10d: cálculo concluído');
SELECT throws_like($$UPDATE folha.payroll_run SET status = 'draft' WHERE run_id = pg_temp.run('m10d')$$,
  'Folha %: não passa de calculated para draft', 'NEG: folha calculada não volta a rascunho');
SELECT throws_like($$UPDATE folha.payroll_run SET total_liquido = 1 WHERE run_id = pg_temp.run('m10d')$$,
  'Folha % está em calculated: competência, tipo de processo, empregador, totais e data de pagamento não podem ser alterados',
  'NEG: totais da folha calculada não são alterados');
SELECT throws_like($$UPDATE folha.payroll_run SET tipo_processo = 'adiantamento' WHERE run_id = pg_temp.run('m10d')$$,
  'Folha % está em calculated: competência, tipo de processo, empregador, totais e data de pagamento não podem ser alterados',
  'NEG: tipo de processo da folha calculada não é alterado');
SELECT lives_ok($$UPDATE folha.payroll_run SET status = 'cancelled' WHERE run_id = pg_temp.run('m10d')$$, 'folha calculada pode ser cancelada');
SELECT throws_like($$UPDATE folha.payroll_run SET status = 'draft' WHERE run_id = pg_temp.run('m10d')$$,
  'Folha % está cancelada e não pode ser alterada', 'NEG: folha cancelada não é reaberta');

-- Mensal no mês em que há recibo de férias (CT-08, gozo em 09/2026): pendência de cálculo.
INSERT INTO r VALUES ('ct08_m', folha.run_payroll_employee(pg_temp.run('m09'), pg_temp.cid('ct08')));
SELECT ok(pg_temp.pend('ct08_m') @> ARRAY['pendencia:ferias_na_competencia_salario_e_inss_do_mes_nao_reapurados'],
  'mensal com férias na competência: salário e INSS não reapurados viram pendência de cálculo');

-- 2ª parcela do 13º sem 1ª parcela no sistema e com outro vínculo informado no ano.
INSERT INTO c VALUES ('d_nf', pg_temp.mk(3000.00, 'clt', 'lucro_presumido', '2023-01-01', NULL, 0.01, 1.0000, 0.058));
INSERT INTO folha.external_remuneration (account_id, employee_id, competencia, base_previdencia, origem)
VALUES ('e0000000-0000-0000-0000-000000000027', pg_temp.trab('d_nf'), '2026-12-01', 1000.00, 'outra fonte fictícia');
INSERT INTO r VALUES ('d_nf', folha.run_payroll_employee(pg_temp.run('d2'), pg_temp.cid('d_nf')));
SELECT ok(pg_temp.pend('d_nf') @> ARRAY['pendencia:adiantamento_do_13o_nao_localizado_informar_o_valor_pago_ou_zero',
                                        'pendencia:outros_vinculos_informados_nao_considerados_neste_processo'],
  '13º 2ª parcela: adiantamento não localizado e outro vínculo não considerado viram pendências (não zero em silêncio)');
SELECT ok(NOT pg_temp.pend('ct02') @> ARRAY['pendencia:adiantamento_do_13o_nao_localizado_informar_o_valor_pago_ou_zero'],
  'CT-02: com a 1ª parcela na folha, não há pendência de adiantamento');

-- Rescisão com adiantamento salarial pago na competência e paga no mês seguinte (derivado sobre o G01:
-- mesmas entradas; só as pendências são conferidas).
SELECT pg_temp.folha('re10b', 'rescisao', '2026-10-01', '2026-11-03', 2);
INSERT INTO c VALUES ('ra', pg_temp.mk(2400.00, 'clt', 'lucro_presumido', '2023-03-10', NULL, 0.01, 1.0000, 0.058));
INSERT INTO folha.payroll_entry (account_id, contract_id, code_id, competencia, tipo_processo, valor)
VALUES ('e0000000-0000-0000-0000-000000000027', pg_temp.cid('ra'), pg_temp.rub('ADIANTAMENTO_SALARIAL_PAGO'), '2026-10-01', 'adiantamento', 500.00);
INSERT INTO r VALUES ('ra_ad', folha.run_payroll_employee(pg_temp.run('ad10'), pg_temp.cid('ra')));
INSERT INTO folha.payroll_process_input (account_id, run_id, contract_id, parametros)
VALUES ('e0000000-0000-0000-0000-000000000027', pg_temp.run('re10b'), pg_temp.cid('ra'),
        '{"data_demissao": "2026-10-13", "motivo": "sem_justa_causa", "aviso_modo": "indenizado_empregador",
          "periodo_aquisitivo_inicio": "2026-03-10", "periodos_vencidos": 1, "fgts_base_extrato": 6500.00}');
INSERT INTO r VALUES ('ra', folha.run_payroll_employee(pg_temp.run('re10b'), pg_temp.cid('ra')));
SELECT ok(pg_temp.pend('ra') @> ARRAY['pendencia:adiantamento_salarial_pago_na_competencia_nao_descontado_na_rescisao',
                                      'a_validar:irrf_rescisao_apurado_pela_data_do_desligamento_e_nao_pela_de_pagamento'],
  'rescisão: adiantamento não descontado e IRRF pela data do desligamento viram pendências');
SELECT ok(NOT pg_temp.pend('g01') && ARRAY['pendencia:adiantamento_salarial_pago_na_competencia_nao_descontado_na_rescisao',
                                           'a_validar:irrf_rescisao_apurado_pela_data_do_desligamento_e_nao_pela_de_pagamento'],
  'G01: sem adiantamento e paga no mês do desligamento, sem essas pendências');
SELECT throws_ok($$SELECT folha.run_payroll_employee(pg_temp.run('co10'), pg_temp.cid('k1'), 0, 1)$$,
  'P0001', 'Salário-família só é calculado na folha mensal', 'NEG: filhos informados fora da folha mensal');

-- ===========================================================================
-- 12. Segunda rodada de revisão
-- ===========================================================================
-- (2) draft -> calculated por UPDATE direto: só com resultado e com os totais iguais à soma.
SELECT throws_like($$UPDATE folha.payroll_run SET status = 'calculated' WHERE run_id = pg_temp.run('m10e')$$,
  'Folha % não tem resultado calculado', 'NEG: folha sem resultado não passa a calculada por UPDATE direto');
SELECT throws_like($$UPDATE folha.payroll_run SET status = 'calculated', total_liquido = 1 WHERE run_id = pg_temp.run('m10')$$,
  'Folha %: os totais não são a soma dos resultados%', 'NEG: UPDATE direto para calculada com totais livres é barrado');

-- (5) Despacho só de folha fechada.
SELECT throws_like($$SELECT * FROM folha.dispatch_folha_completa(pg_temp.run('m10'))$$,
  'Folha % está em draft e não pode ser despachada: só folha fechada gera eventos', 'NEG: folha em rascunho não é despachada');
SELECT throws_like($$SELECT * FROM folha.dispatch_folha_completa(pg_temp.run('m10c'))$$,
  'Folha % está em calculated e não pode ser despachada: só folha fechada gera eventos', 'NEG: folha calculada com pendência não é despachada');
-- Mudou com a migration 0030: o evento contábil deixou de ser um por resultado, com contas fixas
-- no código. Sem configuração e mapeamento contábil do empregador (este arquivo não cadastra)
-- o lote não sai e fica pendência de bloqueio: o contador contábil devolve 0. O despacho com
-- mapeamento está no arquivo 0030.
SELECT is(
  (SELECT d.esocial_events_dispatched::text || '/' || d.contabil_events_dispatched FROM folha.dispatch_folha_completa(pg_temp.run('m10b')) d),
  '1/0', 'folha fechada e sem pendência aberta é despachada (um resultado; sem mapeamento contábil, nenhum lote contábil)');
SELECT ok(
  has_function_privilege('dnex_gestao_folha_worker', 'folha.dispatch_folha_completa(uuid)', 'execute')
  AND NOT has_function_privilege('anon', 'folha.dispatch_folha_completa(uuid)', 'execute')
  AND NOT has_function_privilege('authenticated', 'folha.dispatch_folha_completa(uuid)', 'execute'),
  'dispatch_folha_completa mantém a ACL da 0022');

-- (4) Pendência de cálculo não liberável (pensão fora do IRRF, na folha m10d já calculada e cancelada acima:
--     a consulta abaixo confere o tipo; a recusa da liberação foi conferida na folha m10c).
SELECT is(
  (SELECT string_agg(p.codigo || '=' || p.tipo, ' ' ORDER BY p.codigo) FROM folha.payroll_pendency p JOIN r ON r.result_id = p.result_id
    WHERE r.caso = 'pa' AND p.codigo LIKE 'pendencia:%'),
  'pendencia:pensao_alimenticia_nao_deduzida_da_base_do_irrf=pendencia', 'pensão fora do IRRF: pendência de cálculo, não liberável');
SELECT is(
  ARRAY[folha.pendencia_tipo('a_validar:qualquer'), folha.pendencia_tipo('pendencia:inss_do_recibo_provisorio_reapurar_na_folha_do_mes_de_gozo'),
        folha.pendencia_tipo('pendencia:ferias_na_competencia_salario_e_inss_do_mes_nao_reapurados'),
        folha.pendencia_tipo('pendencia:adiantamento_salarial_pago_na_competencia_nao_descontado_na_rescisao'),
        folha.pendencia_tipo('pendencia:codigo_novo_nao_classificado')],
  ARRAY['a_validar', 'conferencia', 'pendencia', 'pendencia', 'pendencia'],
  'classificação: a_validar e conferência são liberáveis; valor errado e código não classificado, não');

-- (6) Lançamento ligado à folha que o pagou: a segunda folha da competência não paga de novo.
INSERT INTO c VALUES ('dup', pg_temp.mk(3000.00));
INSERT INTO folha.payroll_entry (account_id, contract_id, code_id, competencia, tipo_processo, valor)
VALUES ('e0000000-0000-0000-0000-000000000027', pg_temp.cid('dup'), pg_temp.rub('ADIANTAMENTO_SALARIAL_PAGO'), '2026-10-01', 'adiantamento', 300.00);
INSERT INTO r VALUES ('dup_ad1', folha.run_payroll_employee(pg_temp.run('ad10'), pg_temp.cid('dup')));
SELECT pg_temp.folha('ad10b', 'adiantamento', '2026-10-01', '2026-10-20', 2);
SELECT throws_like($$SELECT folha.run_payroll_employee(pg_temp.run('ad10b'), pg_temp.cid('dup'))$$,
  'Folha de adiantamento sem lançamento para o contrato %', 'NEG: o segundo adiantamento não paga de novo o lançamento já pago');
SELECT throws_like(
  $$UPDATE folha.payroll_entry SET valor = 999 WHERE contract_id = pg_temp.cid('dup')$$,
  'Lançamento % já foi calculado em folha não cancelada e não pode ser alterado nem apagado', 'NEG: lançamento já pago não é alterado');
SELECT throws_like(
  $$DELETE FROM folha.payroll_entry WHERE contract_id = pg_temp.cid('dup')$$,
  'Lançamento % já foi calculado em folha não cancelada e não pode ser alterado nem apagado', 'NEG: lançamento já pago não é apagado');
INSERT INTO folha.payroll_entry (account_id, contract_id, code_id, competencia, tipo_processo, valor)
VALUES ('e0000000-0000-0000-0000-000000000027', pg_temp.cid('dup'), pg_temp.rub('ADIANTAMENTO_SALARIAL_PAGO'), '2026-10-01', 'adiantamento', 200.00);
INSERT INTO r VALUES ('dup_ad2', folha.run_payroll_employee(pg_temp.run('ad10b'), pg_temp.cid('dup')));
SELECT is(pg_temp.itens('dup_ad2'), 'ADIANTAMENTO_SALARIAL_PAGO=20000/lancamento', 'segundo adiantamento: só o lançamento novo (200,00)');
-- Complementar em duas folhas (derivado): comissões de 400,00 e depois 100,00, sem mensal. INSS incremental:
--   1ª: 400,00 x 7,5% = 30,00; 2ª: INSS(500,00) - INSS(400,00) = 37,50 - 30,00 = 7,50.
INSERT INTO folha.payroll_entry (account_id, contract_id, code_id, competencia, tipo_processo, valor)
VALUES ('e0000000-0000-0000-0000-000000000027', pg_temp.cid('dup'), pg_temp.rub('COMISSAO'), '2026-10-01', 'complementar', 400.00);
INSERT INTO r VALUES ('dup_co1', folha.run_payroll_employee(pg_temp.run('co10'), pg_temp.cid('dup')));
SELECT pg_temp.folha('co10b', 'complementar', '2026-10-01', '2026-10-31', 2);
SELECT throws_like($$SELECT folha.run_payroll_employee(pg_temp.run('co10b'), pg_temp.cid('dup'))$$,
  'Folha complementar sem lançamento para o contrato %', 'NEG: a segunda complementar não paga de novo o lançamento já pago');
INSERT INTO folha.payroll_entry (account_id, contract_id, code_id, competencia, tipo_processo, valor)
VALUES ('e0000000-0000-0000-0000-000000000027', pg_temp.cid('dup'), pg_temp.rub('COMISSAO'), '2026-10-01', 'complementar', 100.00);
INSERT INTO r VALUES ('dup_co2', folha.run_payroll_employee(pg_temp.run('co10b'), pg_temp.cid('dup')));
SELECT is(pg_temp.itens('dup_co2'), 'COMISSAO=10000/lancamento INSS_EMPREGADO=750/motor IRRF=0/motor FGTS_DEPOSITO=800/motor',
  'segunda complementar derivado: só a comissão nova, com o INSS incremental (7,50)');
SELECT is(round((pg_temp.res('dup_co1')->>'inss_empregado')::numeric * 100)::bigint, 3000::bigint, 'primeira complementar derivado: INSS 30,00');

-- (8) Adiantamento: pendência a_validar já na folha de adiantamento; recusado depois da mensal.
SELECT ok(pg_temp.pend('a1_ad') @> ARRAY['a_validar:irrf_adiantamento_sem_retencao_regra_quando_o_saldo_e_pago_em_outro_mes'],
  'adiantamento: a regra de retenção não conferida já sai como pendência a_validar na própria folha');
INSERT INTO folha.payroll_entry (account_id, contract_id, code_id, competencia, tipo_processo, valor)
VALUES ('e0000000-0000-0000-0000-000000000027', pg_temp.cid('k1'), pg_temp.rub('ADIANTAMENTO_SALARIAL_PAGO'), '2026-10-01', 'adiantamento', 100.00);
SELECT throws_like($$SELECT folha.run_payroll_employee(pg_temp.run('ad10b'), pg_temp.cid('k1'))$$,
  'Contrato % já tem folha mensal ou rescisão calculada na competência 2026-10-01: o adiantamento não seria descontado',
  'NEG: adiantamento depois da mensal da competência é recusado');

-- (7) Férias que atravessam o mês: gozo de 20/09 a 19/10/2026 (30 dias), folha de férias de 09/2026.
--     A mensal de OUTUBRO enxerga o período de gozo e recebe a pendência de cálculo.
INSERT INTO c VALUES ('fx', pg_temp.mk(1900.00, 'clt', 'lucro_presumido', '2024-08-01', NULL, 0.01, 1.0000, 0.058));
INSERT INTO folha.payroll_process_input (account_id, run_id, contract_id, parametros)
VALUES ('e0000000-0000-0000-0000-000000000027', pg_temp.run('fe09'), pg_temp.cid('fx'),
        '{"inicio_gozo": "2026-09-20", "periodo_aquisitivo_inicio": "2025-08-01", "dias_gozo": 30}');
INSERT INTO r VALUES ('fx_fe', folha.run_payroll_employee(pg_temp.run('fe09'), pg_temp.cid('fx')));
INSERT INTO r VALUES ('fx_out', folha.run_payroll_employee(pg_temp.run('m10'), pg_temp.cid('fx')));
SELECT ok(pg_temp.pend('fx_out') @> ARRAY['pendencia:ferias_na_competencia_salario_e_inss_do_mes_nao_reapurados'],
  'férias de 20/09 a 19/10: a mensal de outubro recebe a pendência (vale o período de gozo, não a competência da folha de férias)');
SELECT pg_temp.folha('m11', 'mensal', '2026-11-01', '2026-11-30');
INSERT INTO r VALUES ('fx_nov', folha.run_payroll_employee(pg_temp.run('m11'), pg_temp.cid('fx')));
SELECT ok(NOT pg_temp.pend('fx_nov') @> ARRAY['pendencia:ferias_na_competencia_salario_e_inss_do_mes_nao_reapurados'],
  'mês seguinte ao fim do gozo: sem a pendência');

-- (10) Incidência com estado de validação; rubricas legadas inativas.
SELECT is(
  (SELECT string_agg(e.codigo || ':' || ri.tributo, ' ' ORDER BY e.codigo, ri.tributo)
     FROM folha.rubric_incidence ri JOIN folha.earning_deduction_code e ON e.code_id = ri.code_id
    WHERE e.account_id IS NULL AND ri.status_validacao = 'a_validar'),
  'ABONO_PECUNIARIO:irrf ABONO_PECUNIARIO_TERCO:fgts ABONO_PECUNIARIO_TERCO:irrf ABONO_PECUNIARIO_TERCO:previdencia AVISO_PREVIO_INDENIZADO:previdencia FERIAS_DOBRA:irrf FERIAS_TERCO:previdencia MULTA_ART477:irrf',
  'oito incidências globais a_validar (as demais, validadas nos pareceres)');
SELECT ok(pg_temp.pend('ct08') @> ARRAY['a_validar:incidencia_FERIAS_TERCO_previdencia'],
  'incidência a_validar usada no cálculo vira pendência (terço de férias na base previdenciária)');
SELECT ok(pg_temp.pend('pa') @> ARRAY['a_validar:incidencia_MULTA_ART477_irrf'],
  'multa do art. 477 lançada: a incidência de IRRF a_validar vira pendência');
SELECT ok(pg_temp.pend('g01') @> ARRAY['a_validar:incidencia_AVISO_PREVIO_INDENIZADO_previdencia'],
  'G01: a previdência do aviso indenizado (decidida por parâmetro a_validar) vira pendência de incidência');
SELECT ok(NOT EXISTS (SELECT 1 FROM unnest(pg_temp.pend('cd03')) x WHERE x LIKE 'a_validar:incidencia_%'),
  'CD-03: rubricas com incidência validada não geram pendência de incidência');
SELECT ok(pg_temp.pend('q1') @> ARRAY['a_validar:incidencia_PREMIO_PROD_previdencia'],
  'rubrica de conta nasce com incidência a_validar até ser conferida');
SELECT is(
  (SELECT string_agg(e.codigo, ' ' ORDER BY e.codigo) FROM folha.earning_deduction_code e WHERE NOT e.ativa),
  'FERIAS_PROPORCIONAL FERIAS_VENCIDAS', 'rubricas legadas de férias inativas (não apagadas)');
INSERT INTO c VALUES ('leg', pg_temp.mk(3000.00));
INSERT INTO folha.payroll_entry (account_id, contract_id, code_id, competencia, valor)
VALUES ('e0000000-0000-0000-0000-000000000027', pg_temp.cid('leg'), pg_temp.rub('FERIAS_VENCIDAS'), '2026-10-01', 10.00);
SELECT throws_ok($$SELECT folha.run_payroll_employee(pg_temp.run('m10'), pg_temp.cid('leg'))$$,
  'P0001', 'Rubrica FERIAS_VENCIDAS está inativa e não entra em cálculo', 'NEG: rubrica inativa não entra em cálculo');

-- (11) Afastamento em mês cheio: dias de contrato menos dias afastados, limitados a 30.
--      Outubro (31 dias) com afastamento de 01 a 30: 1 dia pago. Fevereiro (28) com afastamento de 01 a 27: 1 dia.
INSERT INTO c VALUES ('b30', pg_temp.mk(3000.00)), ('bfev', pg_temp.mk(3000.00)), ('bz', pg_temp.mk(3000.00));
INSERT INTO folha.contract_leave (account_id, contract_id, data_inicio, data_fim, motivo, suspende_pagamento) VALUES
  ('e0000000-0000-0000-0000-000000000027', pg_temp.cid('b30'),  '2026-10-01', '2026-10-30', 'afastamento fictício', true),
  ('e0000000-0000-0000-0000-000000000027', pg_temp.cid('bfev'), '2026-02-01', '2026-02-27', 'afastamento fictício', true),
  ('e0000000-0000-0000-0000-000000000027', pg_temp.cid('bz'),   '2026-10-01', '2026-10-31', 'afastamento fictício', true);
SELECT is(
  ARRAY[(SELECT d.dias FROM folha.dias_proporcionais(pg_temp.cid('b30'), '2026-10-01') d),
        (SELECT d.dias FROM folha.dias_proporcionais(pg_temp.cid('bfev'), '2026-02-01') d),
        (SELECT d.dias FROM folha.dias_proporcionais(pg_temp.cid('bz'), '2026-10-01') d)],
  ARRAY[1, 1, 0]::numeric[],
  'afastamento derivado: 1 dia trabalhado paga 1/30 (em mês de 31 e de 28 dias); mês inteiro afastado paga zero');
INSERT INTO r VALUES ('b30', folha.run_payroll_employee(pg_temp.run('m10'), pg_temp.cid('b30')));
SELECT is(round((pg_temp.res('b30')->>'total_proventos')::numeric * 100)::bigint, 10000::bigint,
  'afastamento derivado: 3.000,00 / 30 x 1 = 100,00');

-- (12) Folha mensal com base zero (mês inteiro afastado): pendência de conferência.
INSERT INTO r VALUES ('bz', folha.run_payroll_employee(pg_temp.run('m10'), pg_temp.cid('bz')));
SELECT ok(pg_temp.pend('bz') @> ARRAY['pendencia:folha_mensal_com_base_zero_conferir'],
  'folha mensal com base zero gera pendência');
SELECT ok(NOT pg_temp.pend('b30') @> ARRAY['pendencia:folha_mensal_com_base_zero_conferir'], 'base maior que zero: sem a pendência');

-- (13) Tamanho da fórmula e código de base global.
SELECT throws_ok(
  $$INSERT INTO folha.rubric_rule (account_id, camada, contract_id, code_id, forma_calculo, formula, vigencia_inicio, fonte)
    VALUES ('e0000000-0000-0000-0000-000000000027', 'contrato', pg_temp.cid('leg'), pg_temp.rub('COMISSAO'), 'formula',
            ('{"op":"soma","args":[{"num":1},{"num":1.' || repeat('1234567890', 1500) || '}]}')::jsonb, '2026-01-01', 'x')$$,
  '23514', NULL, 'NEG: fórmula acima do tamanho máximo é recusada');
SELECT throws_ok(
  $$INSERT INTO folha.calculation_base (account_id, codigo, descricao, finalidade)
    VALUES ('e0000000-0000-0000-0000-000000000027', 'INSS_MENSAL', 'sombra', 'outra')$$,
  '23514', NULL, 'NEG: base de conta não repete código de base global');

-- (14) A recusa não diz se o identificador alheio existe: mesma mensagem para rubrica de outra conta e inexistente.
SELECT throws_ok(
  $$INSERT INTO folha.payroll_entry (account_id, contract_id, code_id, competencia, valor)
    VALUES ('e0000000-0000-0000-0000-000000000027', pg_temp.cid('k1'), (SELECT code_id FROM alheio), '2026-11-01', 1)$$,
  '23514', 'payroll_entry: rubrica inexistente ou indisponível para esta conta', 'rubrica de outra conta: mensagem neutra');
SELECT throws_ok(
  $$INSERT INTO folha.payroll_entry (account_id, contract_id, code_id, competencia, valor)
    VALUES ('e0000000-0000-0000-0000-000000000027', pg_temp.cid('k1'), '00000000-0000-0000-0000-00000000dead', '2026-11-01', 1)$$,
  '23514', 'payroll_entry: rubrica inexistente ou indisponível para esta conta', 'rubrica inexistente: a mesma mensagem');

-- (9) Vigência do IRRF de 2026 fechada.
SELECT is(
  (SELECT t.vigencia_fim FROM folha.tax_table_version t WHERE t.tipo = 'irrf' AND t.vigencia_inicio = '2026-01-01'),
  '2026-12-31'::date, 'a tabela do IRRF de 2026 fecha em 31/12/2026');

SELECT * FROM finish();
ROLLBACK;
