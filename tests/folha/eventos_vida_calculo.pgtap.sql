-- DNEX Folha — comportamento de calc_ferias, calc_13o e calc_rescisao depois da migration 0023.
-- Este arquivo consagrava os erros do motor da 0019 (9 avos para quem trabalhou o ano inteiro,
-- aviso fixo de um salário, multa do FGTS de 40% do salário dentro dos proventos). Agora confere
-- o comportamento correto com valor exato. Os valores abaixo são derivados das regras dos
-- pareceres de 15/11/2026 (não são os casos dourados, que ficam em 0023_eventos_vida_dourados).
-- Executar após as migrations 0014–0023. Nada é persistido (ROLLBACK no final).
BEGIN;

-- Conta da sessão pelo protocolo do gestao_auth, como em produção: o emissor registra a
-- asserção, o login do worker a consome com begin_request e o contexto fica preso a
-- session_user + PID + txid. Por isso o arquivo roda como o login de teste do worker
-- (SET LOCAL SESSION AUTHORIZATION), não como superusuário: desde a migration 0024 não há
-- outro jeito de as funções do motor (SECURITY DEFINER) enxergarem a conta. O que exige
-- superusuário (gravar a asserção, dados de outra conta, alterar parâmetro) fica entre
-- RESET SESSION AUTHORIZATION e SET LOCAL SESSION AUTHORIZATION.
INSERT INTO gestao_finance.enterprise_scope_registry (account_id, legal_entity_id, branch_id)
VALUES ('e0000000-0000-0000-0000-000000000005', 'e1000000-0000-0000-0000-000000000005', 'e2000000-0000-0000-0000-000000000005');
INSERT INTO gestao_auth.access_assertion
  (assertion_id, subject_id, subject_type, principal_group, runtime_session_user,
   account_id, legal_entity_id, branch_id, permissions, issued_at, expires_at)
VALUES ('aa000000-0000-0000-0000-000000000005', gen_random_uuid(), 'system', 'folha_worker', 'dnex_folha_ci_login',
        'e0000000-0000-0000-0000-000000000005', 'e1000000-0000-0000-0000-000000000005', 'e2000000-0000-0000-0000-000000000005', ARRAY['folha.ci'], now(), now() + interval '4 minutes');
SET LOCAL SESSION AUTHORIZATION dnex_folha_ci_login;
DO $$ BEGIN PERFORM gestao_auth.begin_request('aa000000-0000-0000-0000-000000000005', gen_random_uuid(), gen_random_uuid()); END $$;

SELECT plan(47);

-- ---------------------------------------------------------------------------
-- Dados fictícios: Sênior (admissão 15/01/2024, 4.500,00) e Júnior (admissão 01/04/2026, 2.500,00)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_conta constant uuid := 'e0000000-0000-0000-0000-000000000005';
  v_emp uuid;
  v_cid uuid;
BEGIN
  INSERT INTO folha.employee (account_id, cpf, nome_completo, data_nascimento)
  VALUES (v_conta, '55555555555', 'Teste Eventos Vida Senior', '1985-06-15')
  RETURNING employee_id INTO v_emp;
  INSERT INTO folha.employment_contract (account_id, employee_id, data_admissao, cargo, salario_base, regime_trabalho)
  VALUES (v_conta, v_emp, '2024-01-15', 'Senior Tester', 4500.00, 'clt')
  RETURNING contract_id INTO v_cid;
  PERFORM set_config('test.senior_cid', v_cid::text, true);

  INSERT INTO folha.employee (account_id, cpf, nome_completo, data_nascimento)
  VALUES (v_conta, '66666666666', 'Teste Eventos Vida Junior', '1995-03-20')
  RETURNING employee_id INTO v_emp;
  INSERT INTO folha.employment_contract (account_id, employee_id, data_admissao, cargo, salario_base, regime_trabalho)
  VALUES (v_conta, v_emp, '2026-04-01', 'Junior Tester', 2500.00, 'clt')
  RETURNING contract_id INTO v_cid;
  PERFORM set_config('test.junior_cid', v_cid::text, true);
END
$$;

CREATE FUNCTION pg_temp.senior() RETURNS uuid LANGUAGE sql AS $$ SELECT current_setting('test.senior_cid')::uuid $$;
CREATE FUNCTION pg_temp.junior() RETURNS uuid LANGUAGE sql AS $$ SELECT current_setting('test.junior_cid')::uuid $$;

-- ===========================================================================
-- CALC_13O
-- ===========================================================================
CREATE TEMP TABLE t13_adiant AS SELECT * FROM folha.calc_13o(pg_temp.senior(), '2026-10-01', 1);
CREATE TEMP TABLE t13_quit   AS SELECT * FROM folha.calc_13o(pg_temp.senior(), '2026-12-18', 2, 2250.00);
CREATE TEMP TABLE t13_junior AS SELECT * FROM folha.calc_13o(pg_temp.junior(), '2026-12-18', 2);

-- Antes: 9 avos (EXTRACT(MONTH FROM AGE) + 1). Admitido em 2024, tem o ano civil inteiro.
SELECT is((SELECT meses_proporcionais FROM t13_adiant), 12, 'calc_13o: Sênior admitido em 2024 tem 12 avos em 2026');
-- Antes: a 1ª parcela saía como o 13º inteiro.
SELECT is((SELECT valor_bruto FROM t13_adiant), 2250.00::numeric, 'calc_13o: adiantamento = metade (2.250,00)');
SELECT is((SELECT inss FROM t13_adiant), 0::numeric, 'calc_13o: adiantamento sem INSS');
SELECT is((SELECT irrf FROM t13_adiant), 0::numeric, 'calc_13o: adiantamento sem IRRF');
SELECT is((SELECT valor_liquido FROM t13_adiant), 2250.00::numeric, 'calc_13o: adiantamento líquido = 2.250,00');
SELECT is((SELECT fgts FROM t13_adiant), 180.00::numeric, 'calc_13o: FGTS do adiantamento = 180,00');

-- Antes: a quitação não compensava o adiantamento.
SELECT is((SELECT valor_bruto FROM t13_quit), 4500.00::numeric, 'calc_13o: quitação com bruto integral de 4.500,00');
SELECT is((SELECT inss FROM t13_quit), 431.51::numeric, 'calc_13o: INSS em separado sobre o bruto total = 431,51');
SELECT is((SELECT adiantamento_compensado FROM t13_quit), 2250.00::numeric, 'calc_13o: adiantamento compensado = 2.250,00');
SELECT is((SELECT valor_liquido FROM t13_quit), 1818.49::numeric, 'calc_13o: líquido da quitação = 4.500,00 - 2.250,00 - 431,51 - IRRF 0');

SELECT is((SELECT meses_proporcionais FROM t13_junior), 9, 'calc_13o: Júnior admitido em 01/04/2026 tem 9 avos');
SELECT is((SELECT valor_bruto FROM t13_junior), 1875.00::numeric, 'calc_13o: Júnior 2.500,00 x 9/12 = 1.875,00');
SELECT is((SELECT inss FROM t13_junior), 144.44::numeric, 'calc_13o: Júnior INSS sobre 1.875,00 = 144,44');

SELECT throws_ok(
  $$SELECT * FROM folha.calc_13o('00000000-0000-0000-0000-000000000000'::uuid, '2026-10-01', 2)$$,
  'P0001', 'Contrato 00000000-0000-0000-0000-000000000000 não encontrado',
  'calc_13o: contrato inexistente levanta exceção');
SELECT throws_ok(
  $$SELECT * FROM folha.calc_13o(pg_temp.senior(), '2026-10-01', 4)$$,
  'P0001', NULL, 'calc_13o: parcela desconhecida levanta exceção (antes caía na 2ª parcela)');

-- ===========================================================================
-- CALC_FERIAS (período aquisitivo de 15/01/2025 a 14/01/2026; gozo de 30 dias em 01/10/2026)
-- ===========================================================================
CREATE TEMP TABLE tfer AS SELECT * FROM folha.calc_ferias(pg_temp.senior(), '2026-10-01', '2025-01-15');

SELECT is((SELECT dias_direito FROM tfer), 30, 'calc_ferias: 30 dias de direito sem faltas');
SELECT is((SELECT valor_ferias FROM tfer), 4500.00::numeric, 'calc_ferias: férias de 30 dias = 4.500,00');
SELECT is((SELECT valor_um_terco FROM tfer), 1500.00::numeric, 'calc_ferias: terço = 1.500,00');
SELECT is((SELECT total_ferias FROM tfer), 6000.00::numeric, 'calc_ferias: total = soma das parcelas = 6.000,00');
SELECT is((SELECT inss FROM tfer), 641.51::numeric, 'calc_ferias: INSS sobre férias + terço (6.000,00) = 641,51');
SELECT is((SELECT fgts FROM tfer), 480.00::numeric, 'calc_ferias: FGTS sobre férias + terço = 480,00');
SELECT is((SELECT valor_liquido FROM tfer), (SELECT total_ferias - inss - irrf FROM tfer), 'calc_ferias: líquido = total - INSS - IRRF');
SELECT is((SELECT dias_dobra FROM tfer), 0, 'calc_ferias: gozo dentro do período concessivo não gera dobra');
SELECT is((SELECT data_limite_pagamento FROM tfer), '2026-09-29'::date, 'calc_ferias: pagamento até 2 dias antes do início');

-- Antes: tempo de casa virava direito a férias (Júnior com 6 meses recebia "proporcionais" em gozo).
SELECT throws_ok(
  $$SELECT * FROM folha.calc_ferias(pg_temp.junior(), '2026-10-01', '2026-04-01')$$,
  'P0001', NULL, 'calc_ferias: período aquisitivo incompleto levanta exceção');
SELECT throws_ok(
  $$SELECT * FROM folha.calc_ferias(pg_temp.senior(), '2026-10-01', NULL)$$,
  'P0001', NULL, 'calc_ferias: sem início do período aquisitivo levanta exceção');
SELECT throws_ok(
  $$SELECT * FROM folha.calc_ferias('00000000-0000-0000-0000-000000000000'::uuid, '2026-10-01', '2025-01-15')$$,
  'P0001', 'Contrato 00000000-0000-0000-0000-000000000000 não encontrado',
  'calc_ferias: contrato inexistente levanta exceção');

-- ===========================================================================
-- CALC_RESCISAO (Sênior, último dia 13/10/2026, período aquisitivo em curso desde 15/01/2026)
-- ===========================================================================
CREATE TEMP TABLE tsjc AS SELECT * FROM folha.calc_rescisao(pg_temp.senior(), '2026-10-13', 'sem_justa_causa',
  'indenizado_empregador', p_periodo_aquisitivo_inicio => '2026-01-15', p_fgts_base_extrato => 10000.00);
CREATE TEMP TABLE tped AS SELECT * FROM folha.calc_rescisao(pg_temp.senior(), '2026-10-13', 'pedido_demissao',
  'dispensado', p_periodo_aquisitivo_inicio => '2026-01-15');
CREATE TEMP TABLE tjc AS SELECT * FROM folha.calc_rescisao(pg_temp.senior(), '2026-10-13', 'justa_causa',
  p_periodos_vencidos => 1);

SELECT is((SELECT saldo_salario FROM tsjc), 1950.00::numeric, 'calc_rescisao: saldo de 13 dias = 1.950,00');
-- Antes: aviso fixo de um salário (4.500,00).
SELECT is((SELECT dias_aviso FROM tsjc), 36, 'calc_rescisao: aviso de 30 + 3 x 2 anos = 36 dias');
SELECT is((SELECT aviso_previo_indenizado FROM tsjc), 5400.00::numeric, 'calc_rescisao: aviso indenizado de 36 dias = 5.400,00');
SELECT is((SELECT data_projetada FROM tsjc), '2026-11-18'::date, 'calc_rescisao: projeção do aviso até 18/11/2026');
-- Antes: avos = número do mês da demissão, sem projeção.
SELECT is((SELECT decimo_terceiro_proporcional FROM tsjc), 4125.00::numeric, 'calc_rescisao: 13º de 11/12 (com a projeção) = 4.125,00');
-- Antes: 12/12 de proporcionais para todo contrato com mais de um ano, além de "vencidas" presumidas.
SELECT is((SELECT ferias_proporcionais FROM tsjc), 3750.00::numeric, 'calc_rescisao: férias proporcionais de 10/12 = 3.750,00');
SELECT is((SELECT terco_ferias_proporcionais FROM tsjc), 1250.00::numeric, 'calc_rescisao: terço das proporcionais = 1.250,00');
SELECT is((SELECT ferias_vencidas FROM tsjc), 0::numeric, 'calc_rescisao: sem período vencido informado, não presume férias vencidas');
-- Antes: multa = 40% do salário (1.800,00) somada aos proventos e ao líquido.
SELECT is((SELECT total_proventos FROM tsjc), 16475.00::numeric, 'calc_rescisao: proventos = 1.950 + 5.400 + 4.125 + 3.750 + 1.250, sem a multa do FGTS');
SELECT is((SELECT inss_mensal FROM tsjc), 151.19::numeric, 'calc_rescisao: INSS do mês sobre o saldo = 151,19');
SELECT is((SELECT inss_13 FROM tsjc), 383.60::numeric, 'calc_rescisao: INSS do 13º em separado = 383,60');
SELECT is((SELECT liquido_rescisao FROM tsjc), 15940.21::numeric, 'calc_rescisao: líquido = 16.475,00 - 534,79');
SELECT is((SELECT fgts_deposito_rescisao FROM tsjc), 918.00::numeric, 'calc_rescisao: depósito do FGTS = 8% de saldo + aviso + 13º = 918,00');
SELECT is((SELECT multa_fgts FROM tsjc), 4367.20::numeric, 'calc_rescisao: multa = 40% de (10.000,00 + 918,00), em campo próprio');

SELECT is((SELECT aviso_previo_indenizado FROM tped), 0::numeric, 'calc_rescisao: pedido de demissão sem aviso indenizado');
SELECT is((SELECT multa_fgts FROM tped), 0::numeric, 'calc_rescisao: pedido de demissão sem multa do FGTS');
SELECT is((SELECT decimo_terceiro_proporcional FROM tped), 3375.00::numeric, 'calc_rescisao: pedido de demissão com 13º de 9/12 (sem projeção) = 3.375,00');

-- Antes: justa causa recebia 13º e férias proporcionais.
SELECT is(
  (SELECT ARRAY[decimo_terceiro_proporcional, ferias_proporcionais, aviso_previo_indenizado, multa_fgts, ferias_vencidas, terco_ferias_vencidas] FROM tjc),
  ARRAY[0, 0, 0, 0, 4500.00, 1500.00]::numeric[],
  'calc_rescisao: justa causa sem 13º, proporcionais, aviso e multa; com as férias vencidas informadas');

SELECT throws_ok(
  $$SELECT * FROM folha.calc_rescisao('00000000-0000-0000-0000-000000000000'::uuid, '2026-10-13', 'justa_causa')$$,
  'P0001', 'Contrato 00000000-0000-0000-0000-000000000000 não encontrado',
  'calc_rescisao: contrato inexistente levanta exceção');
-- Antes: qualquer texto caía em silêncio no ramo "sem aviso e sem multa".
SELECT throws_ok(
  $$SELECT * FROM folha.calc_rescisao(pg_temp.senior(), '2026-10-13', 'acordo')$$,
  'P0001', 'calc_rescisao: motivo de rescisão desconhecido: acordo',
  'calc_rescisao: motivo desconhecido levanta exceção');

SELECT * FROM finish();
ROLLBACK;
