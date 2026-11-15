-- DNEX Folha — casos dourados do motor mensal (migration 0025).
-- Fonte dos valores: parecer de DP "INSS, FGTS, IRRF e encargos patronais" de 15/11/2026,
-- seção 4, casos CD-01 a CD-15, em centavos. Terceiros de 5,8%, RAT e FAP são ENTRADAS dos
-- cenários do parecer, não afirmação normativa.
-- O que não vem do parecer está marcado "derivado" (conta no comentário) ou "NEG" no texto da
-- asserção. INSS e líquido de CD-01, 02, 08, 09 e 12 são provisórios: dependem do critério de
-- centavos (parâmetro inss_arredondamento_metodo, a_validar); a variante truncada do parecer
-- também é conferida.
-- Executar após as migrations 0014–0025. Nada é persistido (ROLLBACK no final).
BEGIN;

-- Conta da sessão pelo protocolo do gestao_auth, como em produção: o emissor registra a
-- asserção, o login do worker a consome com begin_request e o contexto fica preso a
-- session_user + PID + txid. O arquivo roda como o login de teste do worker; o que exige
-- superusuário (asserção, dados de outra conta, parâmetro, configuração do contexto) fica
-- entre RESET SESSION AUTHORIZATION e SET LOCAL SESSION AUTHORIZATION.
INSERT INTO gestao_finance.enterprise_scope_registry (account_id, legal_entity_id, branch_id)
VALUES ('e0000000-0000-0000-0000-000000000025', 'e1000000-0000-0000-0000-000000000025', 'e2000000-0000-0000-0000-000000000025');
INSERT INTO gestao_auth.access_assertion
  (assertion_id, subject_id, subject_type, principal_group, runtime_session_user,
   account_id, legal_entity_id, branch_id, permissions, issued_at, expires_at)
VALUES ('aa000000-0000-0000-0000-000000000025', gen_random_uuid(), 'system', 'folha_worker', 'dnex_folha_ci_login',
        'e0000000-0000-0000-0000-000000000025', 'e1000000-0000-0000-0000-000000000025', 'e2000000-0000-0000-0000-000000000025', ARRAY['folha.ci'], now(), now() + interval '4 minutes');
SET LOCAL SESSION AUTHORIZATION dnex_folha_ci_login;
DO $$ BEGIN PERFORM gestao_auth.begin_request('aa000000-0000-0000-0000-000000000025', gen_random_uuid(), gen_random_uuid()); END $$;

SELECT plan(207);

-- ---------------------------------------------------------------------------
-- Apoio
-- ---------------------------------------------------------------------------
CREATE TEMP SEQUENCE seq_n START 25000000001;

-- Monta o cenário de um contrato. p_regime NULL = contrato sem empregador.
-- Enquadramento da lotação só é gravado quando há RAT ou terceiros; FAP só quando informado.
CREATE FUNCTION pg_temp.mk(
  p_salario numeric, p_categoria text,
  p_regime text DEFAULT NULL, p_simples_cpp text DEFAULT NULL, p_cprb boolean DEFAULT false,
  p_rat numeric DEFAULT NULL, p_fap numeric DEFAULT NULL, p_terc numeric DEFAULT NULL,
  p_regime_inicio date DEFAULT '2024-01-01', p_com_rateio boolean DEFAULT true,
  p_account uuid DEFAULT 'e0000000-0000-0000-0000-000000000025'
) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
  v_n bigint := nextval('seq_n');
  v_emp uuid;
  v_est uuid;
  v_lot uuid;
  v_trab uuid;
  v_cid uuid;
BEGIN
  INSERT INTO folha.employee (account_id, cpf, nome_completo, data_nascimento)
  VALUES (p_account, v_n::text, 'Ficticio ' || v_n, '1990-01-01')
  RETURNING employee_id INTO v_trab;

  IF p_regime IS NULL THEN
    INSERT INTO folha.employment_contract (account_id, employee_id, data_admissao, cargo, salario_base, regime_trabalho)
    VALUES (p_account, v_trab, '2023-01-01', 'Caso ' || v_n, p_salario, p_categoria)
    RETURNING contract_id INTO v_cid;
    RETURN v_cid;
  END IF;

  INSERT INTO folha.employer (account_id, tipo_inscricao, inscricao, razao_social)
  VALUES (p_account, 'cnpj', left(v_n::text, 8) || right(v_n::text, 3), 'Empresa Ficticia ' || v_n)
  RETURNING employer_id INTO v_emp;
  INSERT INTO folha.employer_regime (account_id, employer_id, vigencia_inicio, regime_tributario,
                                     simples_optante, simples_cpp, cprb_optante)
  VALUES (p_account, v_emp, p_regime_inicio, p_regime,
          p_regime = 'simples_nacional', p_simples_cpp, p_cprb);
  INSERT INTO folha.establishment (account_id, employer_id, tipo_inscricao, inscricao, cnae_preponderante)
  VALUES (p_account, v_emp, 'cnpj', v_n::text || '000', '0000000')
  RETURNING establishment_id INTO v_est;
  IF p_fap IS NOT NULL THEN
    INSERT INTO folha.establishment_fap (account_id, establishment_id, vigencia_inicio, fap, fap_origem)
    VALUES (p_account, v_est, '2024-01-01', p_fap, 'entrada do cenário de teste');
  END IF;
  INSERT INTO folha.tax_allocation (account_id, employer_id, establishment_id, codigo_lotacao, tipo_lotacao)
  VALUES (p_account, v_emp, v_est, 'L' || v_n, 'teste')
  RETURNING allocation_id INTO v_lot;
  IF p_rat IS NOT NULL OR p_terc IS NOT NULL THEN
    INSERT INTO folha.tax_allocation_detail (account_id, allocation_id, vigencia_inicio, aliquota_rat, aliquota_terceiros)
    VALUES (p_account, v_lot, '2024-01-01', p_rat, p_terc);
  END IF;

  INSERT INTO folha.employment_contract (account_id, employee_id, data_admissao, cargo, salario_base,
                                         regime_trabalho, employer_id, establishment_id)
  VALUES (p_account, v_trab, '2023-01-01', 'Caso ' || v_n, p_salario, p_categoria, v_emp, v_est)
  RETURNING contract_id INTO v_cid;
  IF p_com_rateio THEN
    INSERT INTO folha.contract_tax_allocation (account_id, employer_id, contract_id, allocation_id, percentual, vigencia_inicio)
    VALUES (p_account, v_emp, v_cid, v_lot, 100, '2024-01-01');
  END IF;
  RETURN v_cid;
END;
$$;

-- Uma asserção por chave: valores monetários em centavos e demais campos por igualdade de texto.
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
    IF NOT p_linha ? k THEN RAISE EXCEPTION '%: campo % não existe no retorno', p_caso, k; END IF;
    RETURN NEXT is(round((p_linha->>k)::numeric * 100)::bigint, (p_centavos->>k)::bigint,
                   p_caso || ': ' || k || ' = ' || (p_centavos->>k) || ' centavos');
  END LOOP;
  FOR k IN SELECT jsonb_object_keys(p_exatos) ORDER BY 1 LOOP
    IF NOT p_linha ? k THEN RAISE EXCEPTION '%: campo % não existe no retorno', p_caso, k; END IF;
    RETURN NEXT is(p_linha->>k, p_exatos->>k, p_caso || ': ' || k || ' = ' || COALESCE(p_exatos->>k, 'NULL'));
  END LOOP;
END;
$$;

CREATE TEMP TABLE c (caso text PRIMARY KEY, cid uuid NOT NULL);
INSERT INTO c VALUES
  -- cenários do parecer
  ('cd01', pg_temp.mk(1621.00,  'clt',      'lucro_presumido',  NULL,          false, 0.01, 1.0000, 0.058)),
  ('cd02', pg_temp.mk(3000.00,  'clt',      'simples_nacional', 'no_das')),
  ('cd03', pg_temp.mk(5400.00,  'clt',      'lucro_real',       NULL,          false, 0.02, 1.5000, 0.058)),
  ('cd04', pg_temp.mk(10000.00, 'clt',      'lucro_real',       NULL,          false, 0.03, 0.5000, 0.058)),
  ('cd05', pg_temp.mk(1000.00,  'aprendiz', 'lucro_presumido',  NULL,          false, 0.01, 1.0000, 0.058)),
  ('cd06', pg_temp.mk(6000.00,  'contribuinte_individual', 'lucro_presumido')),
  ('cd07', pg_temp.mk(12000.00, 'contribuinte_individual', 'simples_nacional', 'no_das')),
  ('cd08', pg_temp.mk(4000.00,  'clt',      'lucro_real',       NULL,          true,  0.02, 1.0000, 0.058)),
  ('cd09', pg_temp.mk(3000.00,  'clt',      'simples_nacional', 'fora_do_das', false, 0.03, 1.0000, NULL)),
  ('cd14', pg_temp.mk(1200.00,  'estagio')),
  -- negativos e derivados
  ('pj',            pg_temp.mk(5000.00, 'pj')),
  ('sem_empregador', pg_temp.mk(3000.00, 'clt')),
  ('sem_regime',    pg_temp.mk(3000.00, 'clt', 'lucro_presumido', NULL, false, 0.01, 1.0000, 0.058, '2030-01-01')),
  ('sem_rateio',    pg_temp.mk(3000.00, 'clt', 'lucro_presumido', NULL, false, 0.01, 1.0000, 0.058, '2024-01-01', false)),
  ('sem_detalhe',   pg_temp.mk(3000.00, 'clt', 'lucro_presumido')),
  ('sem_fap',       pg_temp.mk(3000.00, 'clt', 'lucro_presumido', NULL, false, 0.01, NULL, 0.058)),
  ('sem_terceiros', pg_temp.mk(3000.00, 'clt', 'lucro_presumido', NULL, false, 0.01, 1.0000, NULL)),
  ('mei',           pg_temp.mk(3000.00, 'clt', 'mei')),
  ('concomitante',  pg_temp.mk(3000.00, 'clt', 'simples_nacional', 'concomitante')),
  ('simples_sem_cpp', pg_temp.mk(3000.00, 'clt', 'simples_nacional', NULL)),
  ('estagio_pago_jan', pg_temp.mk(5400.00, 'estagio')),
  ('dois',          pg_temp.mk(1000.01, 'clt', 'lucro_presumido', NULL, false, 0.01, 1.0000, 0.058, '2024-01-01', false)),
  ('familia',       pg_temp.mk(1900.00, 'clt', 'simples_nacional', 'no_das')),
  ('incoerente',    pg_temp.mk(3000.00, 'clt', 'lucro_presumido', NULL, false, 0.01, 1.0000, 0.058)),
  ('simples_cprb',  pg_temp.mk(3000.00, 'clt', 'simples_nacional', 'no_das', true));
-- Contrato de outra conta: o worker não o gravaria (RLS); entra como superusuário.
RESET SESSION AUTHORIZATION;
INSERT INTO c VALUES
  ('outro', pg_temp.mk(3000.00, 'clt', NULL, NULL, false, NULL, NULL, NULL, '2024-01-01', true, 'e0000000-0000-0000-0000-000000000026'));
SET LOCAL SESSION AUTHORIZATION dnex_folha_ci_login;

CREATE FUNCTION pg_temp.cid(p_caso text) RETURNS uuid LANGUAGE sql AS $$ SELECT cid FROM c WHERE caso = p_caso $$;

-- Cadastro incoerente: lucro presumido marcado como optante do Simples com CPP no DAS.
UPDATE folha.employer_regime r SET simples_optante = true, simples_cpp = 'no_das'
 WHERE r.employer_id = (SELECT k.employer_id FROM folha.employment_contract k WHERE k.contract_id = pg_temp.cid('incoerente'));

-- Segunda lotação do contrato 'dois' (rateio de 40% + 60%; derivado).
DO $$
DECLARE
  v_emp uuid; v_est uuid; v_l1 uuid; v_l2 uuid;
BEGIN
  SELECT k.employer_id, k.establishment_id INTO v_emp, v_est
    FROM folha.employment_contract k WHERE k.contract_id = pg_temp.cid('dois');
  SELECT a.allocation_id INTO v_l1 FROM folha.tax_allocation a WHERE a.establishment_id = v_est;
  INSERT INTO folha.tax_allocation (account_id, employer_id, establishment_id, codigo_lotacao, tipo_lotacao)
  VALUES ('e0000000-0000-0000-0000-000000000025', v_emp, v_est, 'SEGUNDA', 'teste')
  RETURNING allocation_id INTO v_l2;
  INSERT INTO folha.tax_allocation_detail (account_id, allocation_id, vigencia_inicio, aliquota_rat, aliquota_terceiros)
  VALUES ('e0000000-0000-0000-0000-000000000025', v_l2, '2024-01-01', 0.03, 0.058);
  INSERT INTO folha.contract_tax_allocation (account_id, employer_id, contract_id, allocation_id, percentual, vigencia_inicio)
  VALUES ('e0000000-0000-0000-0000-000000000025', v_emp, pg_temp.cid('dois'), v_l1, 40, '2024-01-01'),
         ('e0000000-0000-0000-0000-000000000025', v_emp, pg_temp.cid('dois'), v_l2, 60, '2024-01-01');
END
$$;

-- Folhas (uma por competência na conta). Pagamento no último dia do mês, como no parecer.
CREATE TEMP TABLE f (rotulo text PRIMARY KEY, run_id uuid NOT NULL);
WITH novo AS (
  INSERT INTO folha.payroll_run (account_id, competencia, data_pagamento) VALUES
    ('e0000000-0000-0000-0000-000000000025', '2026-10-01', '2026-10-31'),
    ('e0000000-0000-0000-0000-000000000025', '2023-01-01', '2023-01-31'),
    ('e0000000-0000-0000-0000-000000000025', '2025-12-01', '2026-01-05'),
    ('e0000000-0000-0000-0000-000000000025', '2026-09-01', NULL)
  RETURNING run_id, competencia)
INSERT INTO f SELECT to_char(competencia, 'YYYY-MM'), run_id FROM novo;
-- Fixture da fatia 4 (migration 0027): folha só nasce em rascunho e só fecha pelo fluxo
-- (cálculo, aprovação, fechamento). Este cenário só precisa de UMA folha já fechada para o
-- negativo "folha fechada não recebe cálculo": ela entra como superusuário, com os gatilhos
-- desligados só para este INSERT. O esperado do negativo não mudou.
RESET SESSION AUTHORIZATION;
SET LOCAL session_replication_role = replica;
WITH novo AS (
  INSERT INTO folha.payroll_run (account_id, competencia, data_pagamento, status)
  VALUES ('e0000000-0000-0000-0000-000000000025', '2026-08-01', '2026-08-31', 'closed')
  RETURNING run_id)
INSERT INTO f SELECT 'fechada', run_id FROM novo;
SET LOCAL session_replication_role = origin;
SET LOCAL SESSION AUTHORIZATION dnex_folha_ci_login;
WITH novo AS (
  INSERT INTO folha.payroll_run (account_id, competencia, data_pagamento, employer_id)
  SELECT 'e0000000-0000-0000-0000-000000000025', '2026-07-01', '2026-07-31', k.employer_id
    FROM folha.employment_contract k WHERE k.contract_id = (SELECT cid FROM c WHERE caso = 'cd01')
  RETURNING run_id)
INSERT INTO f SELECT 'do_empregador_cd01', run_id FROM novo;
RESET SESSION AUTHORIZATION;
WITH novo AS (
  INSERT INTO folha.payroll_run (account_id, competencia, data_pagamento)
  VALUES ('e0000000-0000-0000-0000-000000000026', '2026-10-01', '2026-10-31')
  RETURNING run_id)
INSERT INTO f SELECT 'outra_conta', run_id FROM novo;
SET LOCAL SESSION AUTHORIZATION dnex_folha_ci_login;

CREATE FUNCTION pg_temp.run(p_rotulo text) RETURNS uuid LANGUAGE sql AS $$ SELECT run_id FROM f WHERE rotulo = p_rotulo $$;

-- Resultado gravado de um caso, como JSON.
CREATE TEMP TABLE r (caso text PRIMARY KEY, result_id uuid NOT NULL);
CREATE FUNCTION pg_temp.res(p_caso text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT to_jsonb(pr) FROM folha.payroll_result pr JOIN r ON r.result_id = pr.result_id WHERE r.caso = p_caso
$$;
CREATE FUNCTION pg_temp.pend(p_caso text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT t.detail_json->'pendencias' FROM folha.calculation_trace t JOIN r ON r.result_id = t.result_id
   WHERE r.caso = p_caso AND t.rubrica_code = 'SALARIO_BASE'
$$;

-- ===========================================================================
-- CASOS DOURADOS DO PARECER (competência 10/2026, pagamento em 31/10/2026)
-- ===========================================================================
INSERT INTO r VALUES ('cd01', folha.run_payroll_employee(pg_temp.run('2026-10'), pg_temp.cid('cd01')));
INSERT INTO r VALUES ('cd02', folha.run_payroll_employee(pg_temp.run('2026-10'), pg_temp.cid('cd02')));
INSERT INTO r VALUES ('cd03', folha.run_payroll_employee(pg_temp.run('2026-10'), pg_temp.cid('cd03')));
INSERT INTO r VALUES ('cd04', folha.run_payroll_employee(pg_temp.run('2026-10'), pg_temp.cid('cd04'), 2));
INSERT INTO r VALUES ('cd05', folha.run_payroll_employee(pg_temp.run('2026-10'), pg_temp.cid('cd05')));
INSERT INTO r VALUES ('cd06', folha.run_payroll_employee(pg_temp.run('2026-10'), pg_temp.cid('cd06')));
INSERT INTO r VALUES ('cd07', folha.run_payroll_employee(pg_temp.run('2026-10'), pg_temp.cid('cd07')));
INSERT INTO r VALUES ('cd08', folha.run_payroll_employee(pg_temp.run('2026-10'), pg_temp.cid('cd08')));
INSERT INTO r VALUES ('cd09', folha.run_payroll_employee(pg_temp.run('2026-10'), pg_temp.cid('cd09')));
INSERT INTO r VALUES ('cd14', folha.run_payroll_employee(pg_temp.run('2026-10'), pg_temp.cid('cd14')));

-- CD-01: CLT, salário mínimo, Lucro Presumido, RAT 1%, FAP 1,0000, terceiros 5,8%
SELECT pg_temp.confere('CD-01 (INSS e líquido provisórios)', pg_temp.res('cd01'),
  '{"inss_empregado": 12158, "irrf": 0, "fgts": 12968, "inss_patronal": 32420, "rat": 1621, "terceiros": 9402, "liquido": 149942}');

-- CD-02: CLT 3.000,00, Simples Nacional com CPP no DAS
SELECT pg_temp.confere('CD-02 (INSS e líquido provisórios)', pg_temp.res('cd02'),
  '{"inss_empregado": 24860, "irrf": 0, "fgts": 24000, "inss_patronal": 0, "rat": 0, "terceiros": 0, "liquido": 275140}');

-- CD-03: CLT 5.400,00, Lucro Real, RAT 2%, FAP 1,5000, terceiros 5,8%
SELECT pg_temp.confere('CD-03', pg_temp.res('cd03'),
  '{"inss_empregado": 55751, "irrf": 14965, "fgts": 43200, "inss_patronal": 108000, "rat": 16200, "terceiros": 31320, "liquido": 469284}');

-- CD-04: CLT 10.000,00, 2 dependentes, Lucro Real, RAT 3%, FAP 0,5000, terceiros 5,8%
SELECT pg_temp.confere('CD-04', pg_temp.res('cd04'),
  '{"inss_empregado": 98809, "irrf": 146527, "fgts": 80000, "inss_patronal": 200000, "rat": 15000, "terceiros": 58000, "liquido": 754664}');

-- CD-05: aprendiz 1.000,00, Lucro Presumido, RAT 1%, FAP 1,0000, terceiros 5,8%
SELECT pg_temp.confere('CD-05', pg_temp.res('cd05'),
  '{"inss_empregado": 7500, "irrf": 0, "fgts": 2000, "inss_patronal": 20000, "rat": 1000, "terceiros": 5800, "liquido": 92500}');

-- CD-06: pró-labore 6.000,00, sócio, Lucro Presumido
SELECT pg_temp.confere('CD-06', pg_temp.res('cd06'),
  '{"inss_empregado": 66000, "irrf": 38002, "fgts": 0, "inss_patronal": 120000, "rat": 0, "terceiros": 0, "liquido": 495998}');

-- CD-07: pró-labore 12.000,00, Simples Nacional com CPP no DAS
SELECT pg_temp.confere('CD-07', pg_temp.res('cd07'),
  '{"inss_empregado": 93231, "irrf": 213488, "fgts": 0, "inss_patronal": 0, "rat": 0, "terceiros": 0, "liquido": 893281}');

-- CD-08: CLT 4.000,00, optante pela CPRB em 2026, RAT 2%, FAP 1,0000, terceiros 5,8%
SELECT pg_temp.confere('CD-08 (INSS e líquido provisórios)', pg_temp.res('cd08'),
  '{"inss_empregado": 36860, "irrf": 0, "fgts": 32000, "inss_patronal": 40000, "rat": 8000, "terceiros": 23200, "liquido": 363140}');
-- CD-08, variante do 13º: patronal sobre o 13º = 0 (parecer); RAT e terceiros incidem.
-- Os valores de RAT e terceiros da variante não estão no parecer: derivados (2% x 1,0 e 5,8% de 4.000,00).
SELECT pg_temp.confere('CD-08 variante 13º (patronal do parecer; RAT e terceiros derivados)',
  (SELECT to_jsonb(e) FROM folha.calc_encargos_patronais(pg_temp.cid('cd08'), '2026-10-01', 4000.00, 4000.00) e),
  '{"inss_patronal": 0, "rat": 8000, "terceiros": 23200}');

-- CD-09: CLT 3.000,00, Simples Nacional Anexo IV (CPP fora do DAS), RAT 3%, FAP 1,0000
SELECT pg_temp.confere('CD-09 (INSS e líquido provisórios)', pg_temp.res('cd09'),
  '{"inss_empregado": 24860, "irrf": 0, "fgts": 24000, "inss_patronal": 60000, "rat": 9000, "terceiros": 0, "liquido": 275140}');

-- CD-10: salário-família 2026
SELECT is(round((SELECT valor FROM folha.calc_salario_familia(1900.00, 2, '2026-10-01')) * 100)::bigint, 13508::bigint,
  'CD-10(a): remuneração 1.900,00, 2 filhos = 13508 centavos');
SELECT is(round((SELECT valor FROM folha.calc_salario_familia(1980.38, 1, '2026-10-01')) * 100)::bigint, 6754::bigint,
  'CD-10(b): remuneração 1.980,38, 1 filho = 6754 centavos');
SELECT is(round((SELECT valor FROM folha.calc_salario_familia(1980.39, 1, '2026-10-01')) * 100)::bigint, 0::bigint,
  'CD-10(c): remuneração 1.980,39, 1 filho = 0');
SELECT is(round(folha.get_param('salario_familia_remuneracao_ate', '2026-10-01') * 100)::bigint, 198038::bigint,
  'CD-10(d): parâmetro remuneracao_ate = 198038 centavos');
SELECT is(round(folha.get_param('salario_familia_cota', '2026-10-01') * 100)::bigint, 6754::bigint,
  'CD-10(d): parâmetro cota = 6754 centavos');
-- Conteúdo de tax_table_version: sem campo de "alta renda" e sem os limites que não estão na portaria.
CREATE FUNCTION pg_temp.sf_json_ok(p jsonb) RETURNS boolean LANGUAGE sql AS $$
  SELECT NOT EXISTS (SELECT 1 FROM jsonb_object_keys(p) k WHERE k LIKE '%alta%' OR k LIKE '%baixa%')
     AND (p->>'cota')::numeric = 67.54
     AND (p->>'remuneracao_ate')::numeric = 1980.38
$$;
SELECT ok(
  (SELECT pg_temp.sf_json_ok(t.tabela_json) FROM folha.tax_table_version t
    WHERE t.tipo = 'salario_familia' AND t.vigencia_inicio = '2026-01-01'),
  'CD-10(d): tax_table_version de salário-família de 2026 com cota e limite da portaria, sem "alta renda"');
SELECT ok(
  NOT pg_temp.sf_json_ok('{"cota_alta_renda": 67.54, "cota_baixa_renda": 67.54, "faixa_baixa_renda_ate": 1803.15, "faixa_alta_renda_ate": 2704.66}'::jsonb),
  'CD-10(d): a mesma conferência reprova o JSON da correção antiga (1.803,15 e 2.704,66)');

-- CD-11: CLT 3.000,00 na competência 03/2025 (INSS de 2025; IRRF pela tabela de fev/2024 a abr/2025)
SELECT is(round((SELECT valor_inss FROM folha.calc_inss_segurado(3000.00, 'clt', '2025-03-01')) * 100)::bigint, 25341::bigint,
  'CD-11: INSS = 25341 centavos');
SELECT is(round((SELECT valor_irrf FROM folha.calc_irrf(3000.00, 253.41, 0, '2025-03-31')) * 100)::bigint, 1320::bigint,
  'CD-11: IRRF = 1320 centavos');
SELECT is(round((SELECT fgts_deposito FROM folha.calc_fgts(3000.00, 'clt', '2025-03-01')) * 100)::bigint, 24000::bigint,
  'CD-11: FGTS = 24000 centavos');
SELECT is(
  round((3000.00
         - (SELECT valor_inss FROM folha.calc_inss_segurado(3000.00, 'clt', '2025-03-01'))
         - (SELECT valor_irrf FROM folha.calc_irrf(3000.00,
              (SELECT valor_inss FROM folha.calc_inss_segurado(3000.00, 'clt', '2025-03-01')), 0, '2025-03-31'))) * 100)::bigint,
  273339::bigint, 'CD-11: líquido = 273339 centavos');

-- CD-12: CLT 3.000,00 na competência 06/2024 (INSS de 2024)
SELECT is(round((SELECT valor_inss FROM folha.calc_inss_segurado(3000.00, 'clt', '2024-06-01')) * 100)::bigint, 25882::bigint,
  'CD-12 (provisório): INSS = 25882 centavos');
SELECT is(round((SELECT valor_irrf FROM folha.calc_irrf(3000.00, 258.82, 0, '2024-06-30')) * 100)::bigint, 1320::bigint,
  'CD-12: IRRF = 1320 centavos');
SELECT is(round((SELECT fgts_deposito FROM folha.calc_fgts(3000.00, 'clt', '2024-06-01')) * 100)::bigint, 24000::bigint,
  'CD-12: FGTS = 24000 centavos');
SELECT is(
  round((3000.00
         - (SELECT valor_inss FROM folha.calc_inss_segurado(3000.00, 'clt', '2024-06-01'))
         - (SELECT valor_irrf FROM folha.calc_irrf(3000.00,
              (SELECT valor_inss FROM folha.calc_inss_segurado(3000.00, 'clt', '2024-06-01')), 0, '2024-06-30'))) * 100)::bigint,
  272798::bigint, 'CD-12 (provisório): líquido = 272798 centavos');

-- CD-13: fronteiras do IRRF de 2026 (CLT)
SELECT is(round(i.valor_inss * 100)::bigint, x.inss, 'CD-13: rendimento ' || x.rend || ': INSS = ' || x.inss || ' centavos')
  FROM (VALUES (5000.00, 50151::bigint), (7350.00, 83051), (6000.00, 64151)) AS x(rend, inss)
  CROSS JOIN LATERAL folha.calc_inss_segurado(x.rend, 'clt', '2026-10-01') i;
SELECT is(round(q.valor_irrf * 100)::bigint, x.irrf, 'CD-13: rendimento ' || x.rend || ': IRRF = ' || x.irrf || ' centavos')
  FROM (VALUES (5000.00, 501.51, 0::bigint), (7350.00, 830.51, 88413), (6000.00, 641.51, 38510)) AS x(rend, inss, irrf)
  CROSS JOIN LATERAL folha.calc_irrf(x.rend, x.inss, 0, '2026-10-31') q;

-- CD-14: estagiário, bolsa de 1.200,00
SELECT pg_temp.confere('CD-14', pg_temp.res('cd14'),
  '{"inss_empregado": 0, "irrf": 0, "fgts": 0, "inss_patronal": 0, "rat": 0, "terceiros": 0}');

-- CD-15: competência 01/2023, sem tabela: erro e nada gravado.
SELECT throws_ok(
  $$SELECT folha.run_payroll_employee(pg_temp.run('2023-01'), pg_temp.cid('cd01'))$$,
  'P0001', 'Tabela INSS não encontrada para competência 2023-01-01',
  'CD-15: competência 01/2023 sem tabela levanta erro');
SELECT is(
  (SELECT count(*) FROM folha.payroll_result pr WHERE pr.run_id = pg_temp.run('2023-01')),
  0::bigint, 'CD-15: nenhum resultado gravado para 01/2023');
-- CD-15, segunda parte. O parecer fala em parâmetro "em rascunho"; o catálogo da 0023 não tem
-- esse estado (só validado e a_validar). O equivalente conferido aqui é o parâmetro sem
-- vigência para a data: mesmo erro, sem valor de reserva.
SELECT throws_ok(
  $$SELECT * FROM folha.calc_salario_familia(1500.00, 1, '2023-01-01')$$,
  'P0001', 'Parâmetro salario_familia_cota não encontrado para a data 2023-01-01',
  'CD-15: salário-família sem parâmetro para a data levanta erro');

-- ===========================================================================
-- Critério de centavos do INSS (a_validar): variante truncada do parecer
-- ===========================================================================
RESET SESSION AUTHORIZATION;
UPDATE folha.payroll_parameter SET valor = 2 WHERE chave = 'inss_arredondamento_metodo';
SET LOCAL SESSION AUTHORIZATION dnex_folha_ci_login;
SELECT is(round(i.valor_inss * 100)::bigint, x.inss,
          x.caso || ' truncando: INSS = ' || x.inss || ' centavos')
  FROM (VALUES ('CD-01', 1621.00, '2026-10-01'::date, 12157::bigint),
               ('CD-02', 3000.00, '2026-10-01', 24859),
               ('CD-08', 4000.00, '2026-10-01', 36859),
               ('CD-12', 3000.00, '2024-06-01', 25881)) AS x(caso, sal, comp, inss)
  CROSS JOIN LATERAL folha.calc_inss_segurado(x.sal, 'clt', x.comp) i;
RESET SESSION AUTHORIZATION;
UPDATE folha.payroll_parameter SET valor = 3 WHERE chave = 'inss_arredondamento_metodo';
SET LOCAL SESSION AUTHORIZATION dnex_folha_ci_login;
SELECT throws_ok($$SELECT * FROM folha.calc_inss(3000.00, '2026-10-01')$$,
  'P0001', 'Parâmetro inss_arredondamento_metodo com valor desconhecido: 3',
  'NEG: método de arredondamento desconhecido levanta erro');
RESET SESSION AUTHORIZATION;
UPDATE folha.payroll_parameter SET valor = 1 WHERE chave = 'inss_arredondamento_metodo';
SET LOCAL SESSION AUTHORIZATION dnex_folha_ci_login;
SELECT is((SELECT valor_inss FROM folha.calc_inss(1621.00, '2026-10-01')), 121.58::numeric,
  'método padrão restaurado: 1.621,00 = 121,58');

-- ===========================================================================
-- Encargos gravados, memória e pendências
-- ===========================================================================
SELECT is_empty(
  $$SELECT pr.result_id FROM folha.payroll_result pr
     WHERE pr.inss_patronal IS NULL OR pr.rat IS NULL OR pr.terceiros IS NULL$$,
  'nenhum resultado da conta com encargo patronal nulo');
SELECT is(
  (SELECT count(*) FROM folha.payroll_result pr),
  10::bigint, 'dez resultados gravados (a âncora do teste acima)');
SELECT is(
  (SELECT string_agg(t.rubrica_code || '=' || round(t.valor * 100), ',' ORDER BY t.step_order)
     FROM folha.calculation_trace t JOIN r ON r.result_id = t.result_id
    WHERE r.caso = 'cd03' AND t.tipo = 'encargo'),
  'INSS_PATRONAL=108000,RAT_SAT=16200,TERCEIROS=31320',
  'CD-03: memória de cálculo com os três encargos da lotação');
SELECT is(
  (SELECT t.detail_json->>'criterio' FROM folha.calculation_trace t JOIN r ON r.result_id = t.result_id
    WHERE r.caso = 'cd08' AND t.rubrica_code = 'INSS_PATRONAL'),
  'cprb_transicao', 'CD-08: a memória registra o critério da CPRB');
SELECT is(
  (SELECT t.detail_json->>'deducao_aplicada' FROM folha.calculation_trace t JOIN r ON r.result_id = t.result_id
    WHERE r.caso = 'cd03' AND t.rubrica_code = 'IRRF'),
  'simplificado', 'CD-03: a memória registra que o desconto simplificado venceu');
SELECT is(
  (SELECT t.detail_json->>'deducao_aplicada' FROM folha.calculation_trace t JOIN r ON r.result_id = t.result_id
    WHERE r.caso = 'cd04' AND t.rubrica_code = 'IRRF'),
  'legais', 'CD-04: a memória registra que as deduções legais venceram');
SELECT ok(pg_temp.pend('cd01') ? 'a_validar:inss_arredondamento_metodo',
  'CD-01: pendência do critério de centavos do INSS registrada');
SELECT ok(pg_temp.pend('cd06') ? 'a_validar:terceiros_incide_contribuinte_individual',
  'CD-06: pendência da não incidência de terceiros sobre pró-labore registrada');
SELECT ok(pg_temp.pend('cd07') ? 'a_validar:inss_ci_retencao_11_em_optante_do_simples',
  'CD-07: pendência da retenção de 11% em optante do Simples registrada');
SELECT ok(pg_temp.pend('cd08') ? 'a_validar:cprb_empresa_integralmente_desonerada',
  'CD-08: pendência do alcance da CPRB registrada');
SELECT ok(pg_temp.pend('cd09') ? 'a_validar:fap_em_optante_do_simples_anexo_iv',
  'CD-09: pendência do FAP em optante do Simples registrada');
SELECT ok(pg_temp.pend('cd14') ? 'a_validar:estagio_nao_incidencia_lei_11788',
  'CD-14: pendência do fundamento da não incidência no estágio registrada');
SELECT ok(NOT pg_temp.pend('cd03') ? 'pendencia:data_pagamento_nao_informada_usado_ultimo_dia_da_competencia',
  'CD-03: com data de pagamento informada não há pendência de data');

-- Salário-família: pendências e vigências (derivado das cotas e limites do parecer)
SELECT ok(
  (SELECT s.pendencias @> ARRAY['a_validar:salario_familia_documentos_de_elegibilidade']
          AND NOT s.pendencias @> ARRAY['a_validar:salario_familia_divisor_da_fracao_de_dias']
     FROM folha.calc_salario_familia(1900.00, 2, '2026-10-01') s),
  'salário-família: elegibilidade dos filhos devolvida como pendência; sem fração, sem pendência de divisor');
SELECT ok(
  (SELECT s.pendencias @> ARRAY['a_validar:salario_familia_divisor_da_fracao_de_dias']
     FROM folha.calc_salario_familia(1900.00, 1, '2026-10-01', 0.5) s),
  'salário-família: fração de dias devolve a pendência do divisor');
-- 62,04 x 1 (limite 1.819,26 em 2024) e 65,00 x 2 (limite 1.906,04 em 2025)
SELECT is(
  ARRAY[(SELECT valor FROM folha.calc_salario_familia(1819.26, 1, '2024-06-01')),
        (SELECT valor FROM folha.calc_salario_familia(1819.27, 1, '2024-06-01')),
        (SELECT valor FROM folha.calc_salario_familia(1906.04, 2, '2025-03-01')),
        (SELECT valor FROM folha.calc_salario_familia(1906.05, 2, '2025-03-01'))],
  ARRAY[62.04, 0, 130.00, 0]::numeric[],
  'derivado: salário-família de 2024 e 2025 pela cota e pelo limite de cada portaria');
SELECT throws_ok($$SELECT * FROM folha.calc_salario_familia(1500.00, 1, '2027-01-01')$$,
  'P0001', 'Parâmetro salario_familia_cota não encontrado para a data 2027-01-01',
  'NEG: salário-família de 2027 sem portaria cadastrada levanta erro');
SELECT throws_ok($$SELECT * FROM folha.calc_salario_familia(1500.00, -1, '2026-10-01')$$,
  'P0001', NULL, 'NEG: número de filhos negativo levanta erro');
SELECT throws_ok($$SELECT * FROM folha.calc_salario_familia(1500.00, 1, '2026-10-01', 1.5)$$,
  'P0001', NULL, 'NEG: fração de dias acima de 1 levanta erro');

-- Salário-família pela folha (derivado, provisório pelo critério de centavos: 1.621,00 x 7,5% = 121,575 + 279,00 x 9% = 25,11 -> INSS 146,685 -> 146,69;
-- 2 x 67,54 = 135,08; líquido = 1.900,00 + 135,08 - 146,69 = 1.888,39). Folha de 09/2026 sem data de pagamento.
INSERT INTO r VALUES ('familia', folha.run_payroll_employee(pg_temp.run('2026-09'), pg_temp.cid('familia'), 0, 2));
SELECT pg_temp.confere('derivado: salário-família na folha', pg_temp.res('familia'),
  '{"total_proventos": 203508, "inss_empregado": 14669, "irrf": 0, "liquido": 188839}');
SELECT is(
  (SELECT round(t.valor * 100)::bigint FROM folha.calculation_trace t JOIN r ON r.result_id = t.result_id
    WHERE r.caso = 'familia' AND t.rubrica_code = 'SALARIO_FAMILIA'),
  13508::bigint, 'derivado: salário-família na memória de cálculo = 13508 centavos');
SELECT ok(pg_temp.pend('familia') ? 'pendencia:data_pagamento_nao_informada_usado_ultimo_dia_da_competencia',
  'folha sem data de pagamento: usa o último dia da competência e registra a pendência');
SELECT throws_ok(
  $$SELECT folha.run_payroll_employee(pg_temp.run('2026-10'), pg_temp.cid('cd01'))$$,
  'P0001', NULL, 'NEG: o mesmo contrato não é calculado duas vezes na mesma folha');

-- Data de pagamento e não competência (E-16d), pela folha. Derivado: estagiário com bolsa de
-- 5.400,00, competência 12/2025 paga em 05/01/2026. Sem INSS; simplificado 607,20;
-- base 4.792,80; 27,5%: 1.318,02 - 908,73 = 409,29; redução de 2026 = 259,637 -> 149,65.
-- Pela competência (tabela de 2025, sem redução) seriam 409,29.
INSERT INTO r VALUES ('estagio_pago_jan', folha.run_payroll_employee(pg_temp.run('2025-12'), pg_temp.cid('estagio_pago_jan')));
SELECT pg_temp.confere('derivado: competência 12/2025 paga em 01/2026', pg_temp.res('estagio_pago_jan'),
  '{"inss_empregado": 0, "irrf": 14965, "fgts": 0}');

-- Rateio em duas lotações (derivado): 1.000,01 em 40% + 60% -> bases 400,00 (400,004 arredondado) e
-- 600,01 (resíduo); RAT 1% e 3% com FAP 1,0000; patronal 20%; terceiros 5,8%.
-- 400,00: 80,00 / 4,00 / 23,20.  600,01: 120,002 / 18,0003 / 34,80058.
SELECT is(
  (SELECT string_agg(round(e.base_rateada * 100) || '/' || round(e.inss_patronal * 100) || '/' || round(e.rat * 100) || '/' || round(e.terceiros * 100),
                     ' ' ORDER BY e.aliq_rat)
     FROM folha.calc_encargos_patronais(pg_temp.cid('dois'), '2026-10-01', 1000.01) e),
  '40000/8000/400/2320 60001/12000/1800/3480',
  'derivado: rateio em duas lotações, cada uma com a sua alíquota; a soma das bases é a base');
SELECT is(
  (SELECT sum(e.base_rateada) FROM folha.calc_encargos_patronais(pg_temp.cid('dois'), '2026-10-01', 1000.01) e),
  1000.01::numeric, 'derivado: bases rateadas somam a base do contrato');

-- ===========================================================================
-- NEGATIVOS
-- ===========================================================================
-- Categoria não sujeita
SELECT throws_ok(
  $$SELECT folha.run_payroll_employee(pg_temp.run('2026-10'), pg_temp.cid('pj'))$$,
  'P0001', 'run_payroll_employee: categoria pj não é processada na folha',
  'NEG: PJ não entra na folha');
SELECT is(
  (SELECT i.valor_inss::text || '/' || i.metodo FROM folha.calc_inss_segurado(5000.00, 'pj', '2026-10-01') i),
  '0/nao_sujeito', 'NEG: calc_inss_segurado não aplica INSS a PJ');
SELECT is(
  (SELECT i.valor_inss::text || '/' || i.metodo FROM folha.calc_inss_segurado(1200.00, 'estagio', '2026-10-01') i),
  '0/nao_sujeito', 'NEG: calc_inss_segurado não aplica INSS a estagiário');
SELECT is(
  (SELECT i.metodo FROM folha.calc_inss_segurado(6000.00, 'contribuinte_individual', '2026-10-01') i),
  'contribuinte_individual_retencao', 'pró-labore não usa a tabela progressiva');
SELECT throws_ok($$SELECT * FROM folha.calc_inss_segurado(3000.00, 'autonomo', '2026-10-01')$$,
  'P0001', 'calc_inss_segurado: categoria desconhecida: autonomo', 'NEG: categoria desconhecida no INSS levanta erro');
SELECT throws_ok($$SELECT * FROM folha.calc_fgts(3000.00, 'autonomo', '2026-10-01')$$,
  'P0001', 'calc_fgts: categoria desconhecida: autonomo', 'NEG: categoria desconhecida no FGTS levanta erro');
SELECT throws_ok(
  $$SELECT * FROM folha.calc_encargos_patronais(pg_temp.cid('pj'), '2026-10-01', 5000.00)$$,
  'P0001', 'calc_encargos_patronais: categoria pj não é processada na folha', 'NEG: PJ não tem encargos de folha');

-- Falta de empregador, regime, lotação, enquadramento, FAP e terceiros: erro e nada gravado
SELECT throws_like(
  $$SELECT folha.run_payroll_employee(pg_temp.run('2026-10'), pg_temp.cid('sem_empregador'))$$,
  'Contrato % sem empregador cadastrado: encargos patronais não podem ser calculados',
  'NEG: contrato sem empregador levanta erro');
SELECT throws_like(
  $$SELECT folha.run_payroll_employee(pg_temp.run('2026-10'), pg_temp.cid('sem_regime'))$$,
  'Empregador % sem regime tributário vigente em 2026-10-01',
  'NEG: empregador sem regime vigente na competência levanta erro');
SELECT throws_like(
  $$SELECT folha.run_payroll_employee(pg_temp.run('2026-10'), pg_temp.cid('sem_rateio'))$$,
  'Contrato % sem lotação tributária (rateio) vigente em 2026-10-01',
  'NEG: contrato sem lotação vigente levanta erro');
SELECT throws_like(
  $$SELECT folha.run_payroll_employee(pg_temp.run('2026-10'), pg_temp.cid('sem_detalhe'))$$,
  'Lotação % sem enquadramento tributário vigente em 2026-10-01',
  'NEG: lotação sem enquadramento vigente levanta erro');
SELECT throws_like(
  $$SELECT folha.run_payroll_employee(pg_temp.run('2026-10'), pg_temp.cid('sem_fap'))$$,
  'Estabelecimento % sem FAP vigente em 2026-10-01',
  'NEG: estabelecimento sem FAP vigente levanta erro (não presume FAP neutro)');
SELECT throws_like(
  $$SELECT folha.run_payroll_employee(pg_temp.run('2026-10'), pg_temp.cid('sem_terceiros'))$$,
  'Lotação % sem alíquota de terceiros vigente em 2026-10-01',
  'NEG: lotação sem alíquota de terceiros levanta erro');
SELECT throws_ok(
  $$SELECT folha.run_payroll_employee(pg_temp.run('2026-10'), pg_temp.cid('mei'))$$,
  'P0001', 'Regime tributário mei sem regra de encargos patronais implementada',
  'NEG: regime sem regra implementada levanta erro');
SELECT throws_like(
  $$SELECT folha.run_payroll_employee(pg_temp.run('2026-10'), pg_temp.cid('concomitante'))$$,
  'Empregador %: Simples com atividades concomitantes (rateio da folha por receita) não tem regra implementada',
  'NEG: Simples concomitante levanta erro');
SELECT throws_like(
  $$SELECT folha.run_payroll_employee(pg_temp.run('2026-10'), pg_temp.cid('simples_sem_cpp'))$$,
  'Empregador % optante do Simples sem indicação de onde recolhe a contribuição patronal (simples_cpp) em 2026-10-01',
  'NEG: Simples sem indicação da CPP levanta erro');
SELECT throws_like(
  $$SELECT folha.run_payroll_employee(pg_temp.run('2026-10'), pg_temp.cid('incoerente'))$$,
  'Empregador % com cadastro incoerente em 2026-10-01: regime lucro_presumido e simples_optante t',
  'NEG: lucro presumido marcado como optante do Simples levanta erro (não cobra nem zera em silêncio)');
SELECT throws_like(
  $$SELECT folha.run_payroll_employee(pg_temp.run('2026-10'), pg_temp.cid('simples_cprb'))$$,
  'Empregador % com cadastro incoerente em 2026-10-01: optante do Simples marcado como optante da CPRB',
  'NEG: Simples marcado como optante da CPRB levanta erro');
SELECT throws_like(
  $$SELECT folha.run_payroll_employee(pg_temp.run('fechada'), pg_temp.cid('cd02'))$$,
  'Folha % está em closed e não recebe cálculo', 'NEG: folha fechada não recebe cálculo');
SELECT throws_like(
  $$SELECT folha.run_payroll_employee(pg_temp.run('do_empregador_cd01'), pg_temp.cid('cd02'))$$,
  'Contrato % não é do empregador da folha %', 'NEG: folha de um empregador não recebe contrato de outro');
SELECT is(
  (SELECT i.indisunique::text || '/' || pg_get_indexdef(i.indexrelid) FROM pg_index i
    WHERE i.indexrelid = 'folha.payroll_result_run_contract_key'::regclass),
  'true/CREATE UNIQUE INDEX payroll_result_run_contract_key ON folha.payroll_result USING btree (run_id, contract_id)',
  'um resultado por contrato em cada folha: índice único');
SELECT is(
  (SELECT count(*) FROM folha.payroll_result pr
    WHERE pr.contract_id IN (SELECT cid FROM c WHERE caso IN ('incoerente', 'simples_cprb', 'pj', 'sem_empregador', 'sem_regime', 'sem_rateio',
            'sem_detalhe', 'sem_fap', 'sem_terceiros', 'mei', 'concomitante', 'simples_sem_cpp'))),
  0::bigint, 'NEG: nenhum dos contratos recusados ficou com resultado gravado');

-- Parâmetro sem vigência
SELECT throws_ok(
  $$SELECT * FROM folha.calc_encargos_patronais(pg_temp.cid('cd08'), '2028-01-01', 4000.00)$$,
  'P0001', 'Parâmetro cprb_fator_cpp_folha não encontrado para a data 2028-01-01',
  'NEG: CPRB em 2028, sem fator cadastrado, levanta erro');
SELECT throws_ok(
  $$SELECT * FROM folha.calc_encargos_patronais(pg_temp.cid('cd08'), '2024-06-01', 4000.00)$$,
  'P0001', 'Parâmetro cprb_fator_cpp_folha não encontrado para a data 2024-06-01',
  'NEG: CPRB em 2024, fora da transição cadastrada, levanta erro');
-- Fatores da transição (derivado da Lei 12.546/2011 art. 9º-A citada no parecer): 2025 = 5% e 2027 = 15% sobre a folha.
SELECT is(
  ARRAY[(SELECT e.inss_patronal FROM folha.calc_encargos_patronais(pg_temp.cid('cd08'), '2025-06-01', 4000.00) e),
        (SELECT e.inss_patronal FROM folha.calc_encargos_patronais(pg_temp.cid('cd08'), '2027-06-01', 4000.00) e)],
  ARRAY[200.00, 600.00]::numeric[],
  'derivado: CPRB com 5% sobre a folha em 2025 e 15% em 2027');

-- Data anterior às tabelas
SELECT throws_ok($$SELECT * FROM folha.calc_inss_segurado(3000.00, 'clt', '2023-12-01')$$,
  'P0001', 'Tabela INSS não encontrada para competência 2023-12-01', 'NEG: INSS antes de 2024 levanta erro');
SELECT throws_ok($$SELECT * FROM folha.calc_inss_segurado(6000.00, 'contribuinte_individual', '2023-12-01')$$,
  'P0001', 'Tabela INSS não encontrada para competência 2023-12-01', 'NEG: pró-labore antes de 2024 levanta erro');
SELECT throws_ok($$SELECT * FROM folha.calc_irrf(3000.00, 250.00, 0, '2024-01-31')$$,
  'P0001', 'Tabela IRRF não encontrada para competência 2024-01-31',
  'NEG: IRRF pago em 01/2024 (tabela com ato a validar, não semeada) levanta erro');
SELECT throws_ok($$SELECT * FROM folha.calc_fgts(3000.00, 'clt', '2023-12-01')$$,
  'P0001', 'Parâmetro fgts_aliquota_empregado não encontrado para a data 2023-12-01', 'NEG: FGTS antes de 2024 levanta erro');
SELECT throws_ok($$SELECT * FROM folha.calc_irrf(3000.00, 250.00, 0, NULL)$$,
  'P0001', 'IRRF: data de pagamento obrigatória', 'NEG: IRRF sem data de pagamento levanta erro');
SELECT throws_ok($$SELECT * FROM folha.calc_irrf(NULL, 0, 0, '2026-10-31')$$,
  'P0001', 'calc_irrf: rendimento tributável inválido: NULL', 'NEG: IRRF sem rendimento levanta erro (não devolve zero)');
-- Um centavo acima do limite da redução (derivado): 7.350,01; INSS 830,5158 -> 830,52;
-- base 6.519,49; 27,5%: 1.792,85975 - 908,73 = 884,12975; sem redução -> 884,13.
SELECT is((SELECT valor_irrf FROM folha.calc_irrf(7350.01, 830.52, 0, '2026-10-31')), 884.13::numeric,
  'derivado: rendimento de 7.350,01 não tem redução (884,13)');
SELECT throws_ok($$SELECT * FROM folha.calc_irrf(3000.00, -1, 0, '2026-10-31')$$,
  'P0001', NULL, 'NEG: dedução negativa no IRRF levanta erro');

-- Conta: contrato e folha de outra conta não são alcançados
SELECT throws_like(
  $$SELECT folha.run_payroll_employee(pg_temp.run('2026-10'), pg_temp.cid('outro'))$$,
  'Contrato % não encontrado', 'NEG: contrato de outra conta não é calculado');
SELECT throws_like(
  $$SELECT folha.run_payroll_employee(pg_temp.run('outra_conta'), pg_temp.cid('cd02'))$$,
  'Folha % não encontrada', 'NEG: folha de outra conta não recebe resultado');
SELECT throws_like(
  $$SELECT * FROM folha.calc_encargos_patronais(pg_temp.cid('outro'), '2026-10-01', 3000.00)$$,
  'Contrato % não encontrado', 'NEG: encargos de contrato de outra conta não são calculados');

-- Tabela incoerente: teto diferente do fim da última faixa (E-05)
RESET SESSION AUTHORIZATION;
UPDATE folha.tax_table_version SET tabela_json = jsonb_set(tabela_json, '{teto}', '9000.00')
 WHERE tipo = 'inss' AND vigencia_inicio = '2026-01-01';
SET LOCAL SESSION AUTHORIZATION dnex_folha_ci_login;
SELECT throws_like($$SELECT * FROM folha.calc_inss(3000.00, '2026-10-01')$$,
  'Tabela INSS de 2026-01-01 incoerente%', 'NEG: teto diferente do fim da última faixa levanta erro');
RESET SESSION AUTHORIZATION;
UPDATE folha.tax_table_version SET tabela_json = jsonb_set(tabela_json, '{teto}', '8475.55')
 WHERE tipo = 'inss' AND vigencia_inicio = '2026-01-01';
SET LOCAL SESSION AUTHORIZATION dnex_folha_ci_login;

-- ===========================================================================
-- IRRF em separado (0023) e mensal: um só critério
-- ===========================================================================
-- G03 do parecer de rescisão (rendimento 8.000,00, INSS 921,51): 1.037,85, sem redução.
SELECT is(folha.calc_irrf_separado(8000.00, 921.51, 0, '2026-10-13'), 1037.85::numeric,
  'calc_irrf_separado: G03 segue em 1.037,85 (redução aferida pelo rendimento bruto)');
-- Mesmo rendimento e mesmas deduções, sem simplificado em jogo (INSS acima de 607,20): os dois dão o mesmo valor.
SELECT is(
  (SELECT valor_irrf FROM folha.calc_irrf(6000.00, 641.51, 0, '2026-10-31')),
  folha.calc_irrf_separado(6000.00, 641.51, 0, '2026-10-31'),
  'mensal e separado dão o mesmo IRRF quando as deduções legais vencem o simplificado');
-- Teto da redução explícito (derivado): 13º de 5.000,00, INSS 501,51, sem simplificado:
-- base 4.498,49; 22,5%: 1.012,16025 - 675,49 = 336,67025; redução limitada a 312,89 -> 23,78.
SELECT is(folha.calc_irrf_separado(5000.00, 501.51, 0, '2026-12-18'), 23.78::numeric,
  'derivado: no IRRF em separado o teto de 312,89 limita a redução (antes zerava o imposto inteiro)');

-- ===========================================================================
-- Tabelas e parâmetros semeados: só o que o parecer traz com ato
-- ===========================================================================
SELECT is(
  (SELECT string_agg(t.tipo || ':' || t.vigencia_inicio || ':' || COALESCE(t.vigencia_fim::text, 'aberta'), ' ' ORDER BY t.tipo, t.vigencia_inicio)
     FROM folha.tax_table_version t WHERE t.vigencia_inicio < '2026-01-01'),
  'inss:2024-01-01:2024-12-31 inss:2025-01-01:2025-12-31 irrf:2024-02-01:2025-04-30 irrf:2025-05-01:2025-12-31 salario_minimo:2024-01-01:2024-12-31 salario_minimo:2025-01-01:2025-12-31',
  'tabelas anteriores a 2026: INSS e salário mínimo de 2024 e 2025; IRRF de fev/2024 em diante (a de 2023 não entra)');
SELECT is_empty(
  $$SELECT t.tipo, t.vigencia_inicio FROM folha.tax_table_version t
     WHERE t.vigencia_inicio < '2026-01-01' AND COALESCE(t.tabela_json->>'ato', '') = ''$$,
  'toda tabela de 2024 e 2025 traz o ato normativo');
SELECT is(
  (SELECT string_agg((t.tabela_json->>'valor'), '/' ORDER BY t.vigencia_inicio)
     FROM folha.tax_table_version t WHERE t.tipo = 'salario_minimo'),
  '1412.00/1518.00/1621.00', 'salário mínimo de 2024, 2025 e 2026');
SELECT is(
  (SELECT string_agg((t.tabela_json->>'teto'), '/' ORDER BY t.vigencia_inicio)
     FROM folha.tax_table_version t WHERE t.tipo = 'inss'),
  '7786.02/8157.41/8475.55', 'teto do INSS de 2024, 2025 e 2026');
SELECT is_empty(
  $$SELECT p.chave FROM folha.payroll_parameter p
     WHERE p.chave IN ('inss_arredondamento_metodo', 'inss_ci_retencao_aliquota', 'fgts_aliquota_empregado',
                       'fgts_aliquota_aprendiz', 'cpp_aliquota_empresa', 'cprb_fator_cpp_folha', 'cprb_folha_exclui_13o',
                       'terceiros_incide_contribuinte_individual', 'irrf_reducao_limite_isencao', 'irrf_reducao_teto',
                       'irrf_reducao_limite_parcial', 'salario_familia_cota', 'salario_familia_remuneracao_ate')
       AND btrim(p.fonte_normativa) = ''$$,
  'todo parâmetro da 0025 tem fonte normativa');
SELECT set_eq(
  $$SELECT p.chave FROM folha.payroll_parameter p
     WHERE p.status_validacao = 'a_validar'
       AND p.chave IN ('inss_arredondamento_metodo', 'inss_ci_retencao_aliquota', 'fgts_aliquota_empregado',
                       'fgts_aliquota_aprendiz', 'cpp_aliquota_empresa', 'cprb_fator_cpp_folha', 'cprb_folha_exclui_13o',
                       'terceiros_incide_contribuinte_individual', 'irrf_reducao_limite_isencao', 'irrf_reducao_teto',
                       'irrf_reducao_limite_parcial', 'salario_familia_cota', 'salario_familia_remuneracao_ate',
                       'irrf_redutor_coef_a', 'irrf_redutor_coef_b', 'irrf_redutor_referencia_bruto')$$,
  ARRAY['inss_arredondamento_metodo', 'terceiros_incide_contribuinte_individual', 'irrf_redutor_referencia_bruto'],
  'a_validar entre os parâmetros do motor mensal: critério de centavos, terceiros no pró-labore e referência da redução em separado');

-- ===========================================================================
-- Segurança e desempenho (pendências da revisão anterior)
-- ===========================================================================
-- (a) Policies: a conta é resolvida uma vez por comando.
SELECT is(
  (SELECT count(*) FROM pg_policies p
    WHERE p.schemaname = 'folha'
      AND position('SELECT folha.current_account_id()' IN COALESCE(p.qual, '') || COALESCE(p.with_check, '')) > 0),
  31::bigint, '31 policies do schema folha usam (SELECT folha.current_account_id()): 12 das 0014/0018, 7 da 0024 e 12 da 0026');
SELECT is_empty(
  $$SELECT p.tablename, p.policyname FROM pg_policies p
     WHERE p.schemaname = 'folha'
       AND position('current_account_id()' IN
             replace(COALESCE(p.qual, '') || ' ' || COALESCE(p.with_check, ''), 'SELECT folha.current_account_id()', '')) > 0$$,
  'nenhuma policy do schema folha chama current_account_id() por linha');
SELECT is(
  (SELECT count(*) FROM pg_policies p
    WHERE p.schemaname = 'folha'
      AND p.policyname IN ('employee_isolamento', 'contract_isolamento', 'run_isolamento', 'result_isolamento',
                           'trace_isolamento', 'rubrica_isolamento', 'rule_isolamento', 'agreement_isolamento',
                           'benefit_isolamento', 'auditoria_isolamento', 'accounting_outbox_isolamento',
                           'esocial_outbox_isolamento')
      AND p.cmd = 'ALL' AND p.qual IS NOT NULL AND p.with_check IS NOT NULL),
  12::bigint, 'as 12 policies das 0014/0018 existem, para todos os comandos, com USING e WITH CHECK');
-- O isolamento continua valendo: a conta do teste não enxerga o contrato nem a folha da outra.
SELECT is(
  (SELECT count(*) FROM folha.employment_contract k WHERE k.account_id = 'e0000000-0000-0000-0000-000000000026')
  + (SELECT count(*) FROM folha.payroll_run pr WHERE pr.account_id = 'e0000000-0000-0000-0000-000000000026'),
  0::bigint, 'policies recriadas: a conta do teste não vê contrato nem folha de outra conta');
SELECT is(
  (SELECT count(*) FROM folha.employment_contract k), 25::bigint,
  'policies recriadas: a conta do teste vê os 25 contratos próprios');
SELECT throws_ok(
  $$INSERT INTO folha.employee (account_id, cpf, nome_completo, data_nascimento)
    VALUES ('e0000000-0000-0000-0000-000000000026', '25999999999', 'Outra conta', '1990-01-01')$$,
  '42501', NULL, 'policies recriadas: gravar linha de outra conta é recusado (WITH CHECK)');

-- (b) Grupos de principal aceitos pelo contexto.
SELECT is(folha.current_account_id(), 'e0000000-0000-0000-0000-000000000025'::uuid,
  'contexto: configuração sem restrição (NULL) aceita o grupo do login');
RESET SESSION AUTHORIZATION;
UPDATE folha.request_context_config SET principal_groups_permitidos = ARRAY['outro_grupo'];
SET LOCAL SESSION AUTHORIZATION dnex_folha_ci_login;
SELECT is(folha.current_account_id(), NULL::uuid, 'contexto: grupo fora da lista permitida não dá conta');
SELECT is((SELECT count(*) FROM folha.employment_contract), 0::bigint,
  'contexto: grupo fora da lista permitida não vê linha alguma');
SELECT throws_ok(
  $$SELECT folha.run_payroll_employee(pg_temp.run('2026-10'), pg_temp.cid('cd02'))$$,
  'P0001', 'run_payroll_employee: sessão sem conta (contexto não aberto)',
  'contexto: grupo fora da lista permitida não calcula folha');
RESET SESSION AUTHORIZATION;
UPDATE folha.request_context_config SET principal_groups_permitidos = ARRAY['outro_grupo', 'folha_worker'];
SET LOCAL SESSION AUTHORIZATION dnex_folha_ci_login;
SELECT is(folha.current_account_id(), 'e0000000-0000-0000-0000-000000000025'::uuid,
  'contexto: grupo na lista permitida dá a conta');
RESET SESSION AUTHORIZATION;
UPDATE folha.request_context_config SET principal_groups_permitidos = ARRAY[]::text[];
SET LOCAL SESSION AUTHORIZATION dnex_folha_ci_login;
SELECT is(folha.current_account_id(), NULL::uuid, 'contexto: lista vazia não aceita grupo algum');
RESET SESSION AUTHORIZATION;
DELETE FROM folha.request_context_config;
SET LOCAL SESSION AUTHORIZATION dnex_folha_ci_login;
SELECT is(folha.current_account_id(), NULL::uuid, 'contexto: sem a linha de configuração, falha fechada');
RESET SESSION AUTHORIZATION;
INSERT INTO folha.request_context_config (singleton, principal_groups_permitidos) VALUES (true, NULL);
SET LOCAL SESSION AUTHORIZATION dnex_folha_ci_login;
SELECT is(folha.current_account_id(), 'e0000000-0000-0000-0000-000000000025'::uuid,
  'contexto: configuração restaurada devolve a conta');
SELECT is_empty(
  $$SELECT papel || ':' || priv
      FROM unnest(ARRAY['anon', 'authenticated', 'service_role', 'dnex_gestao_folha_worker', 'dnex_gestao_data_owner', 'dnex_folha_ci_login']) AS papel
      CROSS JOIN unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE']) AS priv
     WHERE has_table_privilege(papel, 'folha.request_context_config', priv)$$,
  'configuração do contexto: nenhum papel de aplicação lê nem altera');
SELECT is_empty(
  $$SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END
      FROM pg_class k, LATERAL aclexplode(COALESCE(k.relacl, acldefault('r', k.relowner))) a
     WHERE k.oid = 'folha.request_context_config'::regclass AND a.grantee <> k.relowner$$,
  'configuração do contexto: nenhum privilégio para nenhum papel além do dono');
SELECT is(
  (SELECT k.relrowsecurity::text || '/' || k.relforcerowsecurity::text FROM pg_class k
    WHERE k.oid = 'folha.request_context_config'::regclass),
  'true/true', 'configuração do contexto com RLS e FORCE');

-- (c) ACL das funções criadas ou recriadas pela 0025.
CREATE TEMP TABLE acl (sig text PRIMARY KEY, papeis text[] NOT NULL);
INSERT INTO acl VALUES
  ('folha.calc_inss(numeric,date)',                               ARRAY['dnex_gestao_folha_worker', 'dnex_gestao_data_owner']),
  ('folha.calc_inss_segurado(numeric,text,date)',                 ARRAY['dnex_gestao_folha_worker', 'dnex_gestao_data_owner']),
  ('folha.calc_fgts(numeric,text,date)',                          ARRAY['dnex_gestao_folha_worker', 'dnex_gestao_data_owner']),
  ('folha.calc_irrf(numeric,numeric,integer,date,numeric)',       ARRAY['dnex_gestao_folha_worker', 'dnex_gestao_data_owner']),
  ('folha.calc_irrf_separado(numeric,numeric,integer,date)',      ARRAY['dnex_gestao_folha_worker', 'dnex_gestao_data_owner']),
  ('folha.calc_salario_familia(numeric,integer,date,numeric)',    ARRAY['dnex_gestao_folha_worker', 'dnex_gestao_data_owner']),
  ('folha.calc_encargos_patronais(uuid,date,numeric,numeric)',    ARRAY['dnex_gestao_folha_worker', 'dnex_gestao_data_owner']),
  ('folha.request_context_account_id()',                          ARRAY['dnex_gestao_folha_worker', 'dnex_gestao_data_owner']),
  ('folha.run_payroll_employee(uuid,uuid,integer,integer)',       ARRAY['dnex_gestao_folha_worker']),
  ('folha.arredondar_inss(numeric,date)',                         ARRAY[]::text[]),
  ('folha.irrf_apurar(numeric,numeric,integer,date,text)',        ARRAY[]::text[]);

SELECT is_empty(
  $$SELECT sig FROM acl WHERE to_regprocedure(sig) IS NULL$$,
  'ACL: as 11 funções da 0025 existem com a assinatura esperada');
SELECT is_empty(
  $$SELECT sig || ' <- ' || papel FROM acl, unnest(ARRAY['anon', 'authenticated', 'service_role']) AS papel
     WHERE has_function_privilege(papel, to_regprocedure(sig)::oid, 'execute')$$,
  'ACL: anon, authenticated e service_role não executam as funções da 0025');
SELECT is_empty(
  $$SELECT acl.sig || ' <- ' || papel FROM acl, unnest(acl.papeis) AS papel
     WHERE NOT has_function_privilege(papel, to_regprocedure(acl.sig)::oid, 'execute')$$,
  'ACL: os papéis que já executavam continuam executando');
SELECT is(
  (SELECT count(*) FROM acl, unnest(acl.papeis) AS papel), 17::bigint,
  'ACL: 17 concessões esperadas (âncora do teste acima)');
SELECT is_empty(
  $$SELECT acl.sig || ' <- ' || CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END
      FROM acl JOIN pg_proc p ON p.oid = to_regprocedure(acl.sig)::oid,
           LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
     WHERE a.grantee <> p.proowner
       AND (a.grantee = 0 OR NOT (a.grantee::regrole::text = ANY (acl.papeis)))$$,
  'ACL: nenhum outro papel (nem PUBLIC) tem privilégio nas funções da 0025');
SELECT ok(
  NOT has_function_privilege('dnex_gestao_data_owner', 'folha.run_payroll_employee(uuid,uuid,integer,integer)', 'execute')
  AND NOT has_function_privilege('dnex_gestao_folha_worker', 'folha.irrf_apurar(numeric,numeric,integer,date,text)', 'execute')
  AND NOT has_function_privilege('dnex_gestao_folha_worker', 'folha.arredondar_inss(numeric,date)', 'execute'),
  'ACL: data_owner não grava folha; auxiliares internas não são executáveis nem pelo worker');
SELECT is_empty(
  $$SELECT acl.sig FROM acl JOIN pg_proc p ON p.oid = to_regprocedure(acl.sig)::oid
     WHERE NOT p.prosecdef
        OR NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) AS cfg WHERE cfg LIKE 'search_path=%')$$,
  'as funções da 0025 são SECURITY DEFINER com search_path fixo');
SELECT is_empty(
  $$SELECT p.oid::regprocedure::text FROM pg_proc p
     WHERE p.pronamespace = 'folha'::regnamespace
       AND p.proname IN ('calc_irrf', 'calc_fgts', 'run_payroll_employee', 'calc_inss')
       AND p.oid NOT IN (SELECT to_regprocedure(sig)::oid FROM acl)$$,
  'as assinaturas antigas de calc_irrf, calc_fgts e run_payroll_employee foram removidas');

-- Cadastro: categoria nova e colunas
SELECT throws_ok(
  $$UPDATE folha.employment_contract SET regime_trabalho = 'autonomo' WHERE contract_id = pg_temp.cid('pj')$$,
  '23514', NULL, 'NEG: categoria fora da lista é recusada pelo CHECK do contrato');
SELECT col_type_is('folha', 'payroll_run', 'data_pagamento', 'date', 'payroll_run.data_pagamento existe');
SELECT col_type_is('folha', 'tax_allocation_detail', 'aliquota_terceiros', 'numeric(6,4)', 'tax_allocation_detail.aliquota_terceiros existe');

SELECT * FROM finish();
ROLLBACK;
