-- DNEX Folha — casos dourados do motor de eventos de vida (migration 0023).
-- Fonte dos valores: pareceres de DP de 15/11/2026 (scratch/pareceres), em centavos.
--   CT-01..CT-13: parecer-13o-ferias.md, seção 4.   G01..G12: parecer-rescisao.md, seção 4.2.
-- INSS pelo método A dos pareceres (soma exata das faixas, arredondada no final).
-- Valores que não vêm dos pareceres estão marcados "derivado" no texto da asserção.
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
VALUES ('e0000000-0000-0000-0000-000000000099', 'e1000000-0000-0000-0000-000000000099', 'e2000000-0000-0000-0000-000000000099');
INSERT INTO gestao_auth.access_assertion
  (assertion_id, subject_id, subject_type, principal_group, runtime_session_user,
   account_id, legal_entity_id, branch_id, permissions, issued_at, expires_at)
VALUES ('aa000000-0000-0000-0000-000000000099', gen_random_uuid(), 'system', 'folha_worker', 'dnex_folha_ci_login',
        'e0000000-0000-0000-0000-000000000099', 'e1000000-0000-0000-0000-000000000099', 'e2000000-0000-0000-0000-000000000099', ARRAY['folha.ci'], now(), now() + interval '4 minutes');
SET LOCAL SESSION AUTHORIZATION dnex_folha_ci_login;
DO $$ BEGIN PERFORM gestao_auth.begin_request('aa000000-0000-0000-0000-000000000099', gen_random_uuid(), gen_random_uuid()); END $$;

SELECT plan(371);

-- ---------------------------------------------------------------------------
-- Apoio
-- ---------------------------------------------------------------------------
CREATE TEMP SEQUENCE seq_cpf START 10000000001;

CREATE FUNCTION pg_temp.mk(
  p_admissao date, p_salario numeric, p_regime text DEFAULT 'clt',
  p_account uuid DEFAULT 'e0000000-0000-0000-0000-000000000099'
) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
  v_emp uuid;
  v_cid uuid;
  v_n bigint := nextval('seq_cpf');
BEGIN
  INSERT INTO folha.employee (account_id, cpf, nome_completo, data_nascimento)
  VALUES (p_account, v_n::text, 'Ficticio ' || v_n, '1990-01-01')
  RETURNING employee_id INTO v_emp;
  INSERT INTO folha.employment_contract (account_id, employee_id, data_admissao, cargo, salario_base, regime_trabalho)
  VALUES (p_account, v_emp, p_admissao, 'Caso ' || v_n, p_salario, p_regime)
  RETURNING contract_id INTO v_cid;
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
    RAISE EXCEPTION '%: a função não devolveu linha', p_caso;
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
  ('ct01',  pg_temp.mk('2024-01-15', 4500.00)),
  ('ct03a', pg_temp.mk('2026-03-17', 3600.00)),
  ('ct03b', pg_temp.mk('2026-03-18', 3600.00)),
  ('ct04a', pg_temp.mk('2026-02-14', 2400.00)),
  ('ct04b', pg_temp.mk('2026-02-15', 2400.00)),
  ('ct05',  pg_temp.mk('2025-11-20', 9000.00)),
  ('ct06',  pg_temp.mk('2026-12-20', 3000.00)),
  ('ct07',  pg_temp.mk('2023-01-02', 2000.00)),
  ('ct08',  pg_temp.mk('2024-08-01', 1900.00)),
  ('ct09',  pg_temp.mk('2024-08-01', 9000.00)),
  ('ct10',  pg_temp.mk('2024-08-01', 3000.00)),
  ('ct11',  pg_temp.mk('2024-03-01', 3000.00)),
  ('ct12',  pg_temp.mk('2026-04-10', 3200.00)),
  ('ct13',  pg_temp.mk('2024-08-01', 3000.00)),
  ('g01',   pg_temp.mk('2023-03-10', 2400.00)),
  ('g02',   pg_temp.mk('2026-02-02', 2100.00)),
  ('g03',   pg_temp.mk('2024-01-08', 12000.00)),
  ('g04',   pg_temp.mk('2026-03-16', 2400.00)),
  ('g05',   pg_temp.mk('2024-05-06', 2400.00)),
  ('g06',   pg_temp.mk('2021-08-02', 2400.00)),
  ('g07',   pg_temp.mk('2026-07-06', 1800.00)),
  ('g08',   pg_temp.mk('2026-08-03', 2400.00)),
  ('g10',   pg_temp.mk('2025-02-10', 2400.00)),
  ('g11',   pg_temp.mk('2004-03-01', 2400.00)),
  ('g12',   pg_temp.mk('2026-08-17', 2100.00)),
  ('pj',    pg_temp.mk('2024-01-01', 5000.00, 'pj')),
  ('est',   pg_temp.mk('2024-01-01', 1500.00, 'estagio'));
-- Contrato de outra conta: o worker não o gravaria (RLS); entra como superusuário.
RESET SESSION AUTHORIZATION;
INSERT INTO c VALUES
  ('outro', pg_temp.mk('2024-01-01', 3000.00, 'clt', 'e0000000-0000-0000-0000-000000000098'));
SET LOCAL SESSION AUTHORIZATION dnex_folha_ci_login;

CREATE FUNCTION pg_temp.cid(p_caso text) RETURNS uuid LANGUAGE sql AS $$ SELECT cid FROM c WHERE caso = p_caso $$;

-- ===========================================================================
-- 13º SALÁRIO
-- ===========================================================================

-- CT-01: adiantamento, ano inteiro (admissão 15/01/2024, salário 4.500,00, pago em 30/11/2026)
SELECT pg_temp.confere('CT-01',
  (SELECT to_jsonb(r) FROM folha.calc_13o(pg_temp.cid('ct01'), '2026-11-30', 1) r),
  '{"valor_bruto": 225000, "inss": 0, "irrf": 0, "valor_liquido": 225000, "fgts": 18000}',
  '{"meses_proporcionais": 12}');

-- CT-02: quitação em 18/12/2026 com adiantamento de 2.250,00 compensado
SELECT pg_temp.confere('CT-02',
  (SELECT to_jsonb(r) FROM folha.calc_13o(pg_temp.cid('ct01'), '2026-12-18', 2, 2250.00) r),
  '{"valor_bruto": 450000, "inss": 43151, "irrf": 0, "adiantamento_compensado": 225000, "valor_liquido": 181849, "fgts": 18000}',
  '{"meses_proporcionais": 12}');

-- CT-03: corte dos 15 dias em mês de 31 dias (salário 3.600,00)
SELECT pg_temp.confere('CT-03a (admissão 17/03)',
  (SELECT to_jsonb(r) FROM folha.calc_13o(pg_temp.cid('ct03a'), '2026-12-18', 2) r),
  '{"valor_bruto": 300000}', '{"meses_proporcionais": 10}');
SELECT pg_temp.confere('CT-03b (admissão 18/03)',
  (SELECT to_jsonb(r) FROM folha.calc_13o(pg_temp.cid('ct03b'), '2026-12-18', 2) r),
  '{"valor_bruto": 270000}', '{"meses_proporcionais": 9}');

-- CT-04: corte dos 15 dias em fevereiro de 28 dias (salário 2.400,00)
SELECT pg_temp.confere('CT-04a (admissão 14/02)',
  (SELECT to_jsonb(r) FROM folha.calc_13o(pg_temp.cid('ct04a'), '2026-12-18', 2) r),
  '{"valor_bruto": 220000}', '{"meses_proporcionais": 11}');
SELECT pg_temp.confere('CT-04b (admissão 15/02)',
  (SELECT to_jsonb(r) FROM folha.calc_13o(pg_temp.cid('ct04b'), '2026-12-18', 2) r),
  '{"valor_bruto": 200000}', '{"meses_proporcionais": 10}');

-- CT-05: admitido em 20/11/2025, salário 9.000,00, adiantamento 4.500,00, quitação em 18/12/2026
SELECT pg_temp.confere('CT-05',
  (SELECT to_jsonb(r) FROM folha.calc_13o(pg_temp.cid('ct05'), '2026-12-18', 2, 4500.00) r),
  '{"valor_bruto": 900000, "inss": 98809, "irrf": 129455, "valor_liquido": 221736, "fgts": 36000}',
  '{"meses_proporcionais": 12}');

-- CT-06: admissão em 20/12/2026, nenhum mês com 15 dias
SELECT pg_temp.confere('CT-06',
  (SELECT to_jsonb(r) FROM folha.calc_13o(pg_temp.cid('ct06'), '2026-12-31', 2) r),
  '{"valor_bruto": 0, "inss": 0, "irrf": 0, "valor_liquido": 0}', '{"meses_proporcionais": 0}');

-- CT-07: comissões e ajuste de janeiro (fixo 2.000,00)
SELECT pg_temp.confere('CT-07 adiantamento (média 1.200,00)',
  (SELECT to_jsonb(r) FROM folha.calc_13o(pg_temp.cid('ct07'), '2026-11-30', 1, p_media_variaveis => 1200.00) r),
  '{"valor_bruto": 160000, "inss": 0, "irrf": 0}', '{"meses_proporcionais": 12}');
SELECT pg_temp.confere('CT-07 quitação (13.200,00 / 11)',
  (SELECT to_jsonb(r) FROM folha.calc_13o(pg_temp.cid('ct07'), '2026-12-18', 2, 1600.00, p_soma_variaveis => 13200.00) r),
  '{"valor_bruto": 320000, "adiantamento_compensado": 160000}', '{"meses_proporcionais": 12}');
SELECT pg_temp.confere('CT-07 ajuste (15.000,00 / 12, pago em 08/01/2027)',
  (SELECT to_jsonb(r) FROM folha.calc_13o(pg_temp.cid('ct07'), '2027-01-08', 3,
          p_soma_variaveis => 15000.00, p_bruto_quitado => 3200.00) r),
  '{"valor_bruto": 325000, "diferenca_ajuste": 5000, "fgts": 400}', '{"meses_proporcionais": 12}');
SELECT ok(
  (SELECT r.pendencias_validacao @> ARRAY['a_validar:divisor_variaveis_ajuste']
     FROM folha.calc_13o(pg_temp.cid('ct07'), '2027-01-08', 3, p_soma_variaveis => 15000.00, p_bruto_quitado => 3200.00) r),
  'CT-07: o divisor das variáveis volta como pendência a_validar');

-- Avos isolados: cortes por tamanho de mês e ano bissexto (regra da seção 2.1 e 5.2 do parecer; derivado)
SELECT is(folha.avos_13o(2026, '2026-04-16'), 9, 'avos_13o: mês de 30 dias, admissão no dia 16 conta abril (derivado)');
SELECT is(folha.avos_13o(2026, '2026-04-17'), 8, 'avos_13o: mês de 30 dias, admissão no dia 17 não conta abril (derivado)');
SELECT is(folha.avos_13o(2028, '2028-02-15'), 11, 'avos_13o: fevereiro de 29 dias, admissão no dia 15 conta (derivado)');
SELECT is(folha.avos_13o(2028, '2028-02-16'), 10, 'avos_13o: fevereiro de 29 dias, admissão no dia 16 não conta (derivado)');
SELECT is(folha.avos_13o(2026, '2026-08-17', '2026-11-10'), 3, 'avos_13o: desligamento em 10/11 não conta novembro (G12 sem projeção)');
SELECT is(folha.avos_13o(2026, '2026-08-17', '2026-12-10'), 4, 'avos_13o: G12 com projeção até 10/12 = 4 avos');

-- ===========================================================================
-- FÉRIAS
-- ===========================================================================

-- CT-08: 30 dias, faixa isenta (aquisitivo 01/08/2025 a 31/07/2026; gozo de 01/09 a 30/09/2026)
SELECT pg_temp.confere('CT-08',
  (SELECT to_jsonb(r) FROM folha.calc_ferias(pg_temp.cid('ct08'), '2026-09-01', '2025-08-01', 30) r),
  '{"valor_ferias": 190000, "valor_um_terco": 63333, "total_ferias": 253333, "inss": 20368, "irrf": 0, "valor_liquido": 232965, "fgts": 20267}',
  '{"dias_direito": 30, "data_limite_pagamento": "2026-08-30", "dias_dobra": 0}');

-- CT-09: 30 dias, faixa alta
SELECT pg_temp.confere('CT-09',
  (SELECT to_jsonb(r) FROM folha.calc_ferias(pg_temp.cid('ct09'), '2026-09-01', '2025-08-01', 30) r),
  '{"valor_ferias": 900000, "valor_um_terco": 300000, "total_ferias": 1200000, "inss": 98809, "irrf": 211955, "valor_liquido": 889236, "fgts": 96000}');

-- CT-10: abono pecuniário (converte 10 dias, goza 20)
SELECT pg_temp.confere('CT-10',
  (SELECT to_jsonb(r) FROM folha.calc_ferias(pg_temp.cid('ct10'), '2026-09-01', '2025-08-01', 20, 10) r),
  '{"valor_ferias": 200000, "valor_um_terco": 66667, "valor_abono": 100000, "terco_abono": 33333, "total_ferias": 400000, "base_inss": 266667, "inss": 21569, "irrf": 0, "valor_liquido": 378431, "fgts": 21333}',
  '{"dias_gozo": 20, "dias_abono": 10, "dias_abono_max": 10}');

-- CT-11: dobra total e parcial (aquisitivo 01/03/2024 a 28/02/2025; concessivo até 28/02/2026)
SELECT pg_temp.confere('CT-11a (gozo de 01/04 a 30/04/2026)',
  (SELECT to_jsonb(r) || jsonb_build_object('simples', r.valor_ferias + r.valor_um_terco)
     FROM folha.calc_ferias(pg_temp.cid('ct11'), '2026-04-01', '2024-03-01', 30) r),
  '{"simples": 400000, "valor_dobra": 400000, "total_ferias": 800000, "inss": 36860, "fgts": 32000}',
  '{"dias_dobra": 30}');
SELECT pg_temp.confere('CT-11b (gozo de 14/02 a 15/03/2026)',
  (SELECT to_jsonb(r) || jsonb_build_object('simples', r.valor_ferias + r.valor_um_terco)
     FROM folha.calc_ferias(pg_temp.cid('ct11'), '2026-02-14', '2024-03-01', 30) r),
  '{"simples": 400000, "valor_dobra": 200000, "total_ferias": 600000, "inss": 36860, "fgts": 32000}',
  '{"dias_dobra": 15}');

-- CT-12: férias proporcionais na rescisão, fração superior a 14 dias (sem projeção de aviso)
SELECT is(folha.avos_ferias('2026-04-10', '2026-10-01'), 6, 'CT-12: avos_ferias = 6 (5 meses + 22 dias)');
SELECT pg_temp.confere('CT-12',
  (SELECT to_jsonb(r) || jsonb_build_object('total_ferias_prop', r.ferias_proporcionais + r.terco_ferias_proporcionais)
     FROM folha.calc_rescisao(pg_temp.cid('ct12'), '2026-10-01', 'sem_justa_causa', 'trabalhado',
          p_data_comunicacao => '2026-09-01', p_fgts_base_extrato => 0) r),
  '{"ferias_proporcionais": 160000, "terco_ferias_proporcionais": 53333, "total_ferias_prop": 213333}',
  '{"avos_ferias_proporcionais": 6}');
-- Verba indenizada fora das bases: INSS do mês só sobre o saldo (106,67) e FGTS só sobre saldo + 13º (derivado)
SELECT pg_temp.confere('CT-12 bases sem as férias indenizadas (derivado)',
  (SELECT to_jsonb(r) FROM folha.calc_rescisao(pg_temp.cid('ct12'), '2026-10-01', 'sem_justa_causa', 'trabalhado',
          p_data_comunicacao => '2026-09-01', p_fgts_base_extrato => 0) r),
  '{"saldo_salario": 10667, "decimo_terceiro_proporcional": 160000, "inss_mensal": 800, "irrf_mensal": 0, "fgts_deposito_rescisao": 13653}');

-- CT-13: 7 faltas injustificadas no período aquisitivo, gozo de todo o direito
SELECT pg_temp.confere('CT-13',
  (SELECT to_jsonb(r) FROM folha.calc_ferias(pg_temp.cid('ct13'), '2026-09-01', '2025-08-01',
          p_faltas_injustificadas => 7) r),
  '{"valor_ferias": 240000, "valor_um_terco": 80000, "total_ferias": 320000}',
  '{"dias_direito": 24, "dias_gozo": 24, "dias_abono_max": 8}');

-- Avos de férias isolados (memórias dos casos de rescisão)
SELECT is(folha.avos_ferias('2026-03-10', '2026-11-21'), 8, 'avos_ferias G01: 8 meses + 12 dias = 8');
SELECT is(folha.avos_ferias('2026-01-08', '2026-08-20'), 7, 'avos_ferias G03: 7 meses + 13 dias = 7');
SELECT is(folha.avos_ferias('2026-03-16', '2026-09-10'), 6, 'avos_ferias G04: 5 meses + 26 dias = 6');
SELECT is(folha.avos_ferias('2026-07-06', '2026-10-03'), 3, 'avos_ferias G07: 2 meses + 28 dias = 3');
SELECT is(folha.avos_ferias('2026-02-10', '2026-09-20'), 7, 'avos_ferias G10: 7 meses + 11 dias = 7');

-- ===========================================================================
-- RESCISÃO
-- ===========================================================================

-- G01: sem justa causa, aviso indenizado proporcional (39 dias)
SELECT pg_temp.confere('G01',
  (SELECT to_jsonb(r) FROM folha.calc_rescisao(pg_temp.cid('g01'), '2026-10-13', 'sem_justa_causa', 'indenizado_empregador',
          p_periodo_aquisitivo_inicio => '2026-03-10', p_periodos_vencidos => 1, p_fgts_base_extrato => 6500.00) r),
  '{"saldo_salario": 104000, "aviso_previo_indenizado": 312000, "decimo_terceiro_proporcional": 220000,
    "ferias_vencidas": 240000, "terco_ferias_vencidas": 80000, "ferias_proporcionais": 160000,
    "terco_ferias_proporcionais": 53333, "total_proventos": 1169333, "inss_mensal": 7800, "inss_13": 17369,
    "irrf_mensal": 0, "irrf_13": 0, "total_descontos": 25169, "liquido_rescisao": 1144164,
    "fgts_deposito_rescisao": 50880, "multa_fgts": 280352}',
  '{"dias_aviso": 39, "data_projetada": "2026-11-21", "avos_13": 11, "avos_ferias_proporcionais": 8, "estado": "calculado"}');

-- G02: sem justa causa, aviso trabalhado, menos de um ano
SELECT pg_temp.confere('G02',
  (SELECT to_jsonb(r) FROM folha.calc_rescisao(pg_temp.cid('g02'), '2026-10-01', 'sem_justa_causa', 'trabalhado',
          p_data_comunicacao => '2026-09-01', p_periodo_aquisitivo_inicio => '2026-02-02', p_fgts_base_extrato => 1327.20) r),
  '{"saldo_salario": 7000, "aviso_previo_indenizado": 0, "decimo_terceiro_proporcional": 140000,
    "ferias_proporcionais": 140000, "terco_ferias_proporcionais": 46667, "total_proventos": 333667,
    "inss_mensal": 525, "inss_13": 10500, "total_descontos": 11025, "liquido_rescisao": 322642,
    "fgts_deposito_rescisao": 11760, "multa_fgts": 57792}',
  '{"avos_13": 8, "avos_ferias_proporcionais": 8, "data_projetada": "2026-10-01"}');

-- G03: pedido de demissão, aviso cumprido, salário alto, fração de 13 dias
SELECT pg_temp.confere('G03',
  (SELECT to_jsonb(r) FROM folha.calc_rescisao(pg_temp.cid('g03'), '2026-08-20', 'pedido_demissao', 'trabalhado',
          p_data_comunicacao => '2026-07-21', p_periodo_aquisitivo_inicio => '2026-01-08', p_periodos_vencidos => 1) r),
  '{"saldo_salario": 800000, "decimo_terceiro_proporcional": 800000, "ferias_vencidas": 1200000,
    "terco_ferias_vencidas": 400000, "ferias_proporcionais": 700000, "terco_ferias_proporcionais": 233333,
    "total_proventos": 4133333, "inss_mensal": 92151, "inss_13": 92151, "irrf_mensal": 103785, "irrf_13": 103785,
    "total_descontos": 391872, "liquido_rescisao": 3741461, "fgts_deposito_rescisao": 128000, "multa_fgts": 0}',
  '{"avos_13": 8, "avos_ferias_proporcionais": 7}');

-- G04: pedido de demissão sem cumprir o aviso (desconto de 30 dias)
SELECT pg_temp.confere('G04',
  (SELECT to_jsonb(r) FROM folha.calc_rescisao(pg_temp.cid('g04'), '2026-09-10', 'pedido_demissao', 'descontado_empregado',
          p_periodo_aquisitivo_inicio => '2026-03-16') r),
  '{"saldo_salario": 80000, "decimo_terceiro_proporcional": 120000, "ferias_proporcionais": 120000,
    "terco_ferias_proporcionais": 40000, "total_proventos": 360000, "inss_mensal": 6000, "inss_13": 9000,
    "desconto_aviso": 240000, "total_descontos": 255000, "liquido_rescisao": 105000,
    "fgts_deposito_rescisao": 16000, "multa_fgts": 0}',
  '{"avos_13": 6, "avos_ferias_proporcionais": 6, "data_projetada": "2026-09-10"}');

-- G05: justa causa
SELECT pg_temp.confere('G05',
  (SELECT to_jsonb(r) FROM folha.calc_rescisao(pg_temp.cid('g05'), '2026-10-13', 'justa_causa',
          p_periodos_vencidos => 1) r),
  '{"saldo_salario": 104000, "decimo_terceiro_proporcional": 0, "ferias_vencidas": 240000,
    "terco_ferias_vencidas": 80000, "ferias_proporcionais": 0, "terco_ferias_proporcionais": 0,
    "aviso_previo_indenizado": 0, "total_proventos": 424000, "inss_mensal": 7800, "inss_13": 0,
    "total_descontos": 7800, "liquido_rescisao": 416200, "fgts_deposito_rescisao": 8320, "multa_fgts": 0}');

-- Justa causa com periodo aquisitivo completado ate a saida: vira ferias vencidas (CLT art. 146, caput; derivado)
SELECT pg_temp.confere('Justa causa com periodo completado (aquisitivo desde 06/05/2025)',
  (SELECT to_jsonb(r) FROM folha.calc_rescisao(pg_temp.cid('g05'), '2026-10-13', 'justa_causa',
          p_periodo_aquisitivo_inicio => '2025-05-06') r),
  '{"ferias_vencidas": 240000, "terco_ferias_vencidas": 80000, "ferias_proporcionais": 0}',
  '{"estado": "pendente"}');

-- G06: acordo do art. 484-A, aviso indenizado pela metade (mesmo resultado com 21 ou 42 dias de projeção)
SELECT pg_temp.confere('G06 (projeção de ' || d || ' dias)',
  (SELECT to_jsonb(r) FROM folha.calc_rescisao(pg_temp.cid('g06'), '2026-06-01', 'acordo_484a', 'indenizado_empregador',
          p_periodo_aquisitivo_inicio => '2025-08-02', p_fgts_base_extrato => 10800.00, p_projecao_dias_acordo => d) r),
  '{"saldo_salario": 8000, "aviso_previo_indenizado": 168000, "decimo_terceiro_proporcional": 120000,
    "ferias_proporcionais": 220000, "terco_ferias_proporcionais": 73333, "total_proventos": 589333,
    "inss_mensal": 600, "inss_13": 9000, "total_descontos": 9600, "liquido_rescisao": 579733,
    "fgts_deposito_rescisao": 23680, "multa_fgts": 220736}',
  '{"dias_aviso": 42, "avos_13": 6, "avos_ferias_proporcionais": 11}')
FROM (VALUES (21), (42)) AS v(d);

-- G07: término normal de contrato de experiência
SELECT pg_temp.confere('G07',
  (SELECT to_jsonb(r) FROM folha.calc_rescisao(pg_temp.cid('g07'), '2026-10-03', 'termino_prazo',
          p_data_termo => '2026-10-03') r),
  '{"saldo_salario": 18000, "decimo_terceiro_proporcional": 45000, "ferias_proporcionais": 45000,
    "terco_ferias_proporcionais": 15000, "aviso_previo_indenizado": 0, "total_proventos": 123000,
    "inss_mensal": 1350, "inss_13": 3375, "total_descontos": 4725, "liquido_rescisao": 118275,
    "fgts_deposito_rescisao": 5040, "multa_fgts": 0}',
  '{"avos_13": 3, "avos_ferias_proporcionais": 3}');

-- G08: antecipação do termo pelo empregador (art. 479)
SELECT pg_temp.confere('G08',
  (SELECT to_jsonb(r) FROM folha.calc_rescisao(pg_temp.cid('g08'), '2026-09-18', 'antecipacao_empregador',
          p_data_termo => '2026-10-31', p_fgts_base_extrato => 185.60) r),
  '{"saldo_salario": 144000, "decimo_terceiro_proporcional": 40000, "ferias_proporcionais": 40000,
    "terco_ferias_proporcionais": 13333, "indenizacao_479": 172000, "total_proventos": 409333,
    "inss_mensal": 10800, "inss_13": 3000, "total_descontos": 13800, "liquido_rescisao": 395533,
    "fgts_deposito_rescisao": 14720, "multa_fgts": 13312}',
  '{"avos_13": 2, "avos_ferias_proporcionais": 2}');

-- G09: antecipação do termo pelo empregado (art. 480), prejuízo comprovado de 2.000,00
SELECT pg_temp.confere('G09',
  (SELECT to_jsonb(r) FROM folha.calc_rescisao(pg_temp.cid('g08'), '2026-09-18', 'antecipacao_empregado',
          p_data_termo => '2026-10-31', p_prejuizo_art480 => 2000.00) r),
  '{"saldo_salario": 144000, "decimo_terceiro_proporcional": 40000, "ferias_proporcionais": 40000,
    "terco_ferias_proporcionais": 13333, "indenizacao_479": 0, "total_proventos": 237333,
    "inss_mensal": 10800, "inss_13": 3000, "desconto_art480": 172000, "total_descontos": 185800,
    "liquido_rescisao": 51533, "fgts_deposito_rescisao": 14720, "multa_fgts": 0}',
  '{"estado": "calculado"}');

-- G09b: prejuízo não informado: desconto zero e estado pendente
SELECT pg_temp.confere('G09b',
  (SELECT to_jsonb(r) FROM folha.calc_rescisao(pg_temp.cid('g08'), '2026-09-18', 'antecipacao_empregado',
          p_data_termo => '2026-10-31') r),
  '{"desconto_art480": 0, "total_descontos": 13800, "liquido_rescisao": 223533}',
  '{"estado": "pendente"}');

-- G10: falecimento
SELECT pg_temp.confere('G10',
  (SELECT to_jsonb(r) FROM folha.calc_rescisao(pg_temp.cid('g10'), '2026-09-20', 'falecimento',
          p_periodo_aquisitivo_inicio => '2026-02-10', p_periodos_vencidos => 1) r),
  '{"saldo_salario": 160000, "decimo_terceiro_proporcional": 180000, "ferias_vencidas": 240000,
    "terco_ferias_vencidas": 80000, "ferias_proporcionais": 140000, "terco_ferias_proporcionais": 46667,
    "aviso_previo_indenizado": 0, "total_proventos": 846667, "inss_mensal": 12000, "inss_13": 13769,
    "total_descontos": 25769, "liquido_rescisao": 820898, "fgts_deposito_rescisao": 27200, "multa_fgts": 0}',
  '{"avos_13": 9, "avos_ferias_proporcionais": 7}');

-- G11: sem justa causa, teto de 90 dias
SELECT pg_temp.confere('G11',
  (SELECT to_jsonb(r) FROM folha.calc_rescisao(pg_temp.cid('g11'), '2026-03-02', 'sem_justa_causa', 'indenizado_empregador',
          p_periodo_aquisitivo_inicio => '2026-03-01', p_periodos_vencidos => 1, p_fgts_base_extrato => 62000.00) r),
  '{"saldo_salario": 16000, "aviso_previo_indenizado": 720000, "decimo_terceiro_proporcional": 100000,
    "ferias_vencidas": 240000, "terco_ferias_vencidas": 80000, "ferias_proporcionais": 60000,
    "terco_ferias_proporcionais": 20000, "total_proventos": 1236000, "inss_mensal": 1200, "inss_13": 7500,
    "total_descontos": 8700, "liquido_rescisao": 1227300, "fgts_deposito_rescisao": 66880, "multa_fgts": 2506752}',
  '{"dias_aviso": 90, "data_projetada": "2026-05-31", "avos_13": 5, "avos_ferias_proporcionais": 3}');

-- G12: sem justa causa, admissão e dispensa no mesmo ano
SELECT pg_temp.confere('G12',
  (SELECT to_jsonb(r) FROM folha.calc_rescisao(pg_temp.cid('g12'), '2026-11-10', 'sem_justa_causa', 'indenizado_empregador',
          p_fgts_base_extrato => 420.00) r),
  '{"saldo_salario": 70000, "aviso_previo_indenizado": 210000, "decimo_terceiro_proporcional": 70000,
    "ferias_proporcionais": 70000, "terco_ferias_proporcionais": 23333, "total_proventos": 443333,
    "inss_mensal": 5250, "inss_13": 5250, "total_descontos": 10500, "liquido_rescisao": 432833,
    "fgts_deposito_rescisao": 28000, "multa_fgts": 28000}',
  '{"dias_aviso": 30, "data_projetada": "2026-12-10", "avos_13": 4, "avos_13_projecao": 1, "avos_ferias_proporcionais": 4}');

-- Multa do FGTS em campo próprio: fora dos proventos e do líquido (achado E3)
SELECT ok(
  (SELECT r.total_proventos = r.saldo_salario + r.aviso_previo_indenizado + r.decimo_terceiro_proporcional
            + r.ferias_vencidas + r.terco_ferias_vencidas + r.ferias_proporcionais
            + r.terco_ferias_proporcionais + r.indenizacao_479
          AND r.liquido_rescisao = r.total_proventos - r.total_descontos
          AND r.multa_fgts > 0
     FROM folha.calc_rescisao(pg_temp.cid('g01'), '2026-10-13', 'sem_justa_causa', 'indenizado_empregador',
          p_periodo_aquisitivo_inicio => '2026-03-10', p_periodos_vencidos => 1, p_fgts_base_extrato => 6500.00) r),
  'G01: proventos = soma das verbas do empregado; líquido = proventos - descontos; multa do FGTS fora dos dois');

-- Parâmetros a_validar voltam como pendência
SELECT ok(
  (SELECT r.pendencias_validacao @> ARRAY['a_validar:inss_projecao_aviso_incide', 'a_validar:inss_aviso_indenizado_incide',
                                          'a_validar:divisor_saldo_salario', 'a_validar:irrf_redutor_referencia_bruto']
     FROM folha.calc_rescisao(pg_temp.cid('g01'), '2026-10-13', 'sem_justa_causa', 'indenizado_empregador',
          p_periodo_aquisitivo_inicio => '2026-03-10', p_periodos_vencidos => 1, p_fgts_base_extrato => 6500.00) r),
  'G01: parâmetros A VALIDAR NA FONTE usados no cálculo voltam em pendencias_validacao');

-- Alternativas dos pareceres: INSS do 13º sem os avos da projeção do aviso (parâmetro a_validar = 0)
RESET SESSION AUTHORIZATION;   -- o worker só lê o catálogo
UPDATE folha.payroll_parameter SET valor = 0 WHERE chave = 'inss_projecao_aviso_incide';
SET LOCAL SESSION AUTHORIZATION dnex_folha_ci_login;
SELECT is(round((SELECT r.inss_13 FROM folha.calc_rescisao(pg_temp.cid('g01'), '2026-10-13', 'sem_justa_causa', 'indenizado_empregador',
          p_periodo_aquisitivo_inicio => '2026-03-10', p_periodos_vencidos => 1, p_fgts_base_extrato => 6500.00) r) * 100)::bigint,
  13769::bigint, 'G01 alternativa: inss_13 = 13769 sem INSS sobre os avos da projeção');
SELECT is(round((SELECT r.inss_13 FROM folha.calc_rescisao(pg_temp.cid('g06'), '2026-06-01', 'acordo_484a', 'indenizado_empregador',
          p_periodo_aquisitivo_inicio => '2025-08-02', p_fgts_base_extrato => 10800.00, p_projecao_dias_acordo => 21) r) * 100)::bigint,
  7500::bigint, 'G06 alternativa: inss_13 = 7500');
SELECT is(round((SELECT r.inss_13 FROM folha.calc_rescisao(pg_temp.cid('g11'), '2026-03-02', 'sem_justa_causa', 'indenizado_empregador',
          p_periodo_aquisitivo_inicio => '2026-03-01', p_periodos_vencidos => 1, p_fgts_base_extrato => 62000.00) r) * 100)::bigint,
  3000::bigint, 'G11 alternativa: inss_13 = 3000');
SELECT is(round((SELECT r.inss_13 FROM folha.calc_rescisao(pg_temp.cid('g12'), '2026-11-10', 'sem_justa_causa', 'indenizado_empregador',
          p_fgts_base_extrato => 420.00) r) * 100)::bigint,
  3938::bigint, 'G12 alternativa: inss_13 = 3938');
RESET SESSION AUTHORIZATION;   -- o worker só lê o catálogo
UPDATE folha.payroll_parameter SET valor = 1 WHERE chave = 'inss_projecao_aviso_incide';
SET LOCAL SESSION AUTHORIZATION dnex_folha_ci_login;

-- Limite do art. 477 § 5º: desconto do art. 480 acima de uma remuneração não é descontado (derivado)
SELECT pg_temp.confere('Limite 477 § 5º (termo em 31/12; teto do 479 = 4.160,00; prejuízo 5.000,00)',
  (SELECT to_jsonb(r) FROM folha.calc_rescisao(pg_temp.cid('g08'), '2026-09-18', 'antecipacao_empregado',
          p_data_termo => '2026-12-31', p_prejuizo_art480 => 5000.00) r),
  '{"desconto_art480": 240000}', '{"estado": "pendente"}');

-- ===========================================================================
-- NEGATIVOS (devem lançar erro, não calcular)
-- ===========================================================================
SELECT throws_ok($$SELECT * FROM folha.calc_rescisao(pg_temp.cid('g01'), '2026-10-13', 'demissao_qualquer')$$,
  'P0001', 'calc_rescisao: motivo de rescisão desconhecido: demissao_qualquer', 'NEG: motivo desconhecido levanta exceção');
SELECT throws_ok($$SELECT * FROM folha.calc_rescisao(pg_temp.cid('g01'), '2026-10-13', NULL)$$,
  'P0001', 'calc_rescisao: motivo de rescisão obrigatório', 'NEG: motivo nulo levanta exceção');
SELECT throws_ok($$SELECT * FROM folha.calc_rescisao(pg_temp.cid('g01'), '2026-10-13', '  ')$$,
  'P0001', 'calc_rescisao: motivo de rescisão obrigatório', 'NEG: motivo vazio levanta exceção');
SELECT throws_ok($$SELECT * FROM folha.calc_rescisao(pg_temp.cid('pj'), '2026-06-15', 'sem_justa_causa', 'indenizado_empregador')$$,
  'P0001', 'Regime pj não tem rescisão pela CLT', 'NEG: calc_rescisao recusa regime pj');
SELECT throws_ok($$SELECT * FROM folha.calc_rescisao(pg_temp.cid('est'), '2026-06-15', 'pedido_demissao', 'trabalhado')$$,
  'P0001', 'Regime estagio não tem rescisão pela CLT', 'NEG: calc_rescisao recusa regime estagio');
SELECT throws_ok($$SELECT * FROM folha.calc_13o(pg_temp.cid('pj'), '2026-12-18', 2)$$,
  'P0001', 'Regime pj não tem direito a 13º salário', 'NEG: calc_13o recusa regime pj');
SELECT throws_ok($$SELECT * FROM folha.calc_ferias(pg_temp.cid('pj'), '2026-09-01', '2025-01-01')$$,
  'P0001', 'Regime pj não tem direito a férias da CLT', 'NEG: calc_ferias recusa regime pj');
SELECT throws_ok($$SELECT * FROM folha.calc_rescisao(pg_temp.cid('g12'), '2026-08-01', 'justa_causa')$$,
  'P0001', NULL, 'NEG: demissão anterior à admissão levanta exceção');
SELECT throws_ok($$SELECT * FROM folha.calc_rescisao(pg_temp.cid('g07'), '2026-10-03', 'termino_prazo')$$,
  'P0001', 'calc_rescisao: motivo termino_prazo exige a data do termo do contrato', 'NEG: término de prazo sem data do termo');
SELECT throws_ok($$SELECT * FROM folha.calc_rescisao(pg_temp.cid('g08'), '2026-09-18', 'antecipacao_empregador', p_fgts_base_extrato => 185.60)$$,
  'P0001', 'calc_rescisao: motivo antecipacao_empregador exige a data do termo do contrato', 'NEG: antecipação pelo empregador sem data do termo');
SELECT throws_ok($$SELECT * FROM folha.calc_rescisao(pg_temp.cid('g08'), '2026-09-18', 'antecipacao_empregado')$$,
  'P0001', 'calc_rescisao: motivo antecipacao_empregado exige a data do termo do contrato', 'NEG: antecipação pelo empregado sem data do termo');
SELECT throws_ok($$SELECT * FROM folha.calc_rescisao(pg_temp.cid('g06'), '2026-06-01', 'acordo_484a', 'indenizado_empregador',
          p_periodo_aquisitivo_inicio => '2025-08-02', p_fgts_base_extrato => 10800.00)$$,
  'P0001', 'calc_rescisao: acordo com aviso indenizado exige os dias de projeção (p_projecao_dias_acordo)', 'NEG: acordo sem parâmetro de projeção');
SELECT throws_ok($$SELECT * FROM folha.calc_rescisao(pg_temp.cid('outro'), '2026-06-15', 'justa_causa')$$,
  'P0001', NULL, 'NEG: contrato de outra conta não é calculado (rescisão)');
SELECT throws_ok($$SELECT * FROM folha.calc_13o(pg_temp.cid('outro'), '2026-12-18', 2)$$,
  'P0001', NULL, 'NEG: contrato de outra conta não é calculado (13º)');
SELECT throws_ok($$SELECT * FROM folha.calc_ferias(pg_temp.cid('outro'), '2026-09-01', '2025-01-01')$$,
  'P0001', NULL, 'NEG: contrato de outra conta não é calculado (férias)');
SELECT throws_ok($$SELECT * FROM folha.calc_rescisao(pg_temp.cid('g01'), '2026-10-13', 'justa_causa', 'indenizado_empregador')$$,
  'P0001', 'calc_rescisao: modo de aviso indenizado_empregador incompatível com o motivo justa_causa', 'NEG: aviso incompatível com o motivo');
SELECT throws_ok($$SELECT * FROM folha.calc_rescisao(pg_temp.cid('g01'), '2026-10-13', 'pedido_demissao', 'trabalhado')$$,
  'P0001', 'calc_rescisao: contrato com 12 meses ou mais exige o início do período aquisitivo em curso', 'NEG: férias proporcionais não se inferem do tempo de casa');
SELECT throws_ok($$SELECT * FROM folha.calc_13o(pg_temp.cid('ct01'), '2026-12-18', 0)$$,
  'P0001', NULL, 'NEG: calc_13o recusa parcela 0');
SELECT throws_ok($$SELECT * FROM folha.calc_13o(pg_temp.cid('ct01'), '2026-12-18', NULL)$$,
  'P0001', NULL, 'NEG: calc_13o recusa parcela nula');
SELECT throws_ok($$SELECT * FROM folha.calc_13o(pg_temp.cid('ct01'), '2026-12-18', 2, 4400.00)$$,
  'P0001', NULL, 'NEG: calc_13o recusa líquido negativo na quitação (adiantamento maior que o líquido)');
SELECT throws_ok($$SELECT * FROM folha.calc_ferias(pg_temp.cid('ct12'), '2026-10-01', '2026-04-10')$$,
  'P0001', NULL, 'NEG: calc_ferias recusa período aquisitivo incompleto');
SELECT throws_ok($$SELECT * FROM folha.calc_ferias(pg_temp.cid('ct13'), '2026-09-01', '2025-08-01', 15, 9, 7)$$,
  'P0001', 'calc_ferias: abono de 9 dias excede o máximo de 8 (1/3 do direito de 24 dias)', 'NEG: abono acima de 1/3 do direito (CT-13: máximo de 8 dias)');
SELECT throws_ok($$SELECT * FROM folha.calc_ferias(pg_temp.cid('ct10'), '2026-09-01', '2025-08-01', 25, 10)$$,
  'P0001', NULL, 'NEG: gozo + abono acima do direito');

-- Motivo com multa sem base do FGTS: estado pendente, sem valor presumido
SELECT pg_temp.confere('NEG: multa sem base do FGTS informada',
  (SELECT to_jsonb(r) FROM folha.calc_rescisao(pg_temp.cid('g12'), '2026-11-10', 'sem_justa_causa', 'indenizado_empregador') r),
  '{"liquido_rescisao": 432833}', '{"multa_fgts": null, "estado": "pendente"}');

-- ===========================================================================
-- ACL das funções criadas ou recriadas pela 0023
-- ===========================================================================
CREATE TEMP TABLE f (sig text PRIMARY KEY);
INSERT INTO f VALUES
  ('folha.get_param(text,date)'),
  ('folha.params_a_validar(text[],date)'),
  ('folha.avos_13o(integer,date,date)'),
  ('folha.avos_ferias(date,date)'),
  ('folha.calc_irrf_separado(numeric,numeric,integer,date)'),
  ('folha.calc_inss(numeric,date)'),
  ('folha.calc_13o(uuid,date,integer,numeric,numeric,integer,numeric,numeric,numeric,numeric,integer)'),
  ('folha.calc_ferias(uuid,date,date,integer,integer,integer,date,numeric,integer)'),
  ('folha.calc_rescisao(uuid,date,text,text,date,date,integer,integer,numeric,date,numeric,integer,integer,numeric,numeric,integer)');

SELECT is_empty(
  $$SELECT sig FROM f WHERE to_regprocedure(sig) IS NULL$$,
  'ACL: as 9 funções da 0023 existem com a assinatura esperada');
SELECT is_empty(
  $$SELECT sig || ' <- ' || papel FROM f, unnest(ARRAY['anon', 'authenticated', 'service_role']) AS papel
     WHERE has_function_privilege(papel, to_regprocedure(sig)::oid, 'execute')$$,
  'ACL: anon, authenticated e service_role não executam as funções da 0023');
SELECT is_empty(
  $$SELECT sig || ' <- ' || papel FROM f, unnest(ARRAY['dnex_gestao_folha_worker', 'dnex_gestao_data_owner']) AS papel
     WHERE NOT has_function_privilege(papel, to_regprocedure(sig)::oid, 'execute')$$,
  'ACL: dnex_gestao_folha_worker e dnex_gestao_data_owner executam as funções da 0023');
SELECT is_empty(
  $$SELECT f.sig || ' <- ' || CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END
      FROM f JOIN pg_proc p ON p.oid = to_regprocedure(f.sig)::oid,
           LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
     WHERE a.privilege_type = 'EXECUTE'
       AND a.grantee <> p.proowner
       AND (a.grantee = 0 OR a.grantee::regrole::text NOT IN ('dnex_gestao_folha_worker', 'dnex_gestao_data_owner'))$$,
  'ACL: nenhum outro papel (nem PUBLIC) tem EXECUTE nas funções da 0023');
SELECT is_empty(
  $$SELECT p.oid::regprocedure::text
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'folha' AND p.proname IN ('calc_13o', 'calc_ferias', 'calc_rescisao')
       AND p.oid NOT IN (SELECT to_regprocedure(sig)::oid FROM f)$$,
  'ACL: as assinaturas antigas de calc_13o, calc_ferias e calc_rescisao foram removidas');
SELECT ok(
  NOT has_table_privilege('anon', 'folha.payroll_parameter', 'select')
  AND NOT has_table_privilege('authenticated', 'folha.payroll_parameter', 'select')
  AND has_table_privilege('dnex_gestao_folha_worker', 'folha.payroll_parameter', 'select')
  AND NOT has_table_privilege('dnex_gestao_folha_worker', 'folha.payroll_parameter', 'insert, update, delete'),
  'ACL: payroll_parameter fechada para anon e authenticated; worker só lê');

-- ===========================================================================
-- Incidências das rubricas e parâmetros
-- ===========================================================================
SELECT is_empty(
  $$SELECT codigo FROM folha.earning_deduction_code
     WHERE is_global AND codigo IN ('RESC_FERIAS_PROP', 'RESC_FERIAS_VENCIDAS')
       AND (incidencia_inss OR incidencia_irrf OR incidencia_fgts)$$,
  'Rubricas: férias indenizadas na rescisão sem INSS, IRRF e FGTS');
SELECT is(
  (SELECT incidencia_fgts FROM folha.earning_deduction_code WHERE is_global AND codigo = 'ABONO_PECUNIARIO'),
  false, 'Rubricas: abono pecuniário fora da base do FGTS');
SELECT is(
  (SELECT incidencia_inss FROM folha.earning_deduction_code WHERE is_global AND codigo = 'DECIMO_TERCEIRO_1A'),
  false, 'Rubricas: 1ª parcela do 13º sem INSS no ato');
SELECT set_eq(
  $$SELECT chave FROM folha.payroll_parameter WHERE status_validacao = 'a_validar'$$,
  ARRAY['divisor_variaveis_quitacao', 'divisor_variaveis_ajuste', 'ferias_fracionamento_max_periodos',
        'ferias_fracionamento_minimo_1', 'ferias_fracionamento_minimo_2', 'irrf_abono_pecuniario_incide',
        'irrf_dobra_ferias_incide', 'irrf_redutor_referencia_bruto', 'irrf_redutor_coef_a', 'irrf_redutor_coef_b',
        'aviso_previo_dias_por_ano', 'prazo_pagamento_rescisao_dias', 'divisor_saldo_salario',
        'inss_aviso_indenizado_incide', 'inss_projecao_aviso_incide'],
  'Parâmetros: o que os pareceres marcam A VALIDAR NA FONTE está como a_validar');
SELECT throws_ok($$SELECT folha.get_param('parametro_inexistente', '2026-01-01')$$,
  'P0001', NULL, 'get_param: parâmetro ausente levanta exceção (sem valor de reserva)');

SELECT * FROM finish();
ROLLBACK;
