-- DNEX Folha — conferência direta de calc_inss, calc_irrf e calc_fgts (tabelas de 2026).
-- Reescrito com a migration 0025: calc_irrf recebe o rendimento tributável bruto, o INSS
-- retido, os dependentes e a DATA DE PAGAMENTO (a assinatura antiga recebia a base já líquida
-- de INSS e consagrava o erro E-16 do parecer); calc_fgts perdeu a coluna da "multa" de 40%
-- sobre o depósito do mês (E-09).
-- Os valores abaixo são DERIVADOS das tabelas e regras do parecer de INSS/FGTS de 15/11/2026,
-- com a conta no comentário; os casos dourados do parecer (CD-01 a CD-15) ficam em
-- 0025_motor_mensal_dourados.pgtap.sql.
-- Executar após as migrations 0014–0025. Nada é persistido (ROLLBACK no final).
BEGIN;
SELECT plan(25);

SELECT is(
  (SELECT count(*) FROM folha.tax_table_version WHERE tipo = 'inss'),
  3::bigint,
  'Tabelas do INSS: 2024, 2025 e 2026 carregadas'
);

-- ---------------------------------------------------------------------------
-- INSS progressivo (tabela de 2026; soma exata das faixas, arredondada no total)
-- Provisório: o critério de centavos é o parâmetro inss_arredondamento_metodo (a_validar).
-- ---------------------------------------------------------------------------
-- 1.621,00 x 7,5% = 121,575
SELECT is((SELECT valor_inss FROM folha.calc_inss(1621.00, '2026-10-01')), 121.58::numeric,
  'INSS salário mínimo 1.621,00 = 121,58');
-- 121,575 + 879,00 x 9% (79,11) = 200,685
SELECT is((SELECT valor_inss FROM folha.calc_inss(2500.00, '2026-10-01')), 200.69::numeric,
  'INSS 2.500,00 = 200,69');
-- 121,575 + 115,3656 + 597,16 x 12% (71,6592) = 308,5998
SELECT is((SELECT valor_inss FROM folha.calc_inss(3500.00, '2026-10-01')), 308.60::numeric,
  'INSS 3.500,00 = 308,60');
-- 121,575 + 115,3656 + 174,1716 + 4.121,28 x 14% (576,9792) = 988,0914
SELECT is((SELECT valor_inss FROM folha.calc_inss(8475.55, '2026-10-01')), 988.09::numeric,
  'INSS no teto 8.475,55 = 988,09');
SELECT is((SELECT valor_inss FROM folha.calc_inss(10000.00, '2026-10-01')), 988.09::numeric,
  'INSS acima do teto (10.000,00) = 988,09');

-- ---------------------------------------------------------------------------
-- IRRF mensal: calc_irrf(rendimento, INSS retido, dependentes, data de pagamento)
-- ---------------------------------------------------------------------------
-- 3.000,00: INSS 248,60 < 607,20 -> simplificado; base 2.392,80 -> isento
SELECT is((SELECT valor_irrf FROM folha.calc_irrf(3000.00, 248.60, 0, '2026-10-31')), 0.00::numeric,
  'IRRF 3.000,00 = 0,00');
SELECT is((SELECT desconto_aplicado FROM folha.calc_irrf(3000.00, 248.60, 0, '2026-10-31')), 'simplificado',
  'IRRF 3.000,00: desconto simplificado é mais favorável que o INSS');
-- 6.000,00: INSS 641,51 > 607,20; base 5.358,49; 27,5%: 1.473,58475 - 908,73 = 564,85475;
-- redução 978,62 - 0,133145 x 6.000,00 = 179,75; imposto 385,10475
SELECT is((SELECT valor_irrf FROM folha.calc_irrf(6000.00, 641.51, 0, '2026-10-31')), 385.10::numeric,
  'IRRF 6.000,00 = 385,10 (redução aferida pelo rendimento bruto)');
-- 7.500,00: INSS 851,51; base 6.648,49; 27,5%: 1.828,33475 - 908,73 = 919,60475; acima de 7.350,00, sem redução
SELECT is((SELECT valor_irrf FROM folha.calc_irrf(7500.00, 851.51, 0, '2026-10-31')), 919.60::numeric,
  'IRRF 7.500,00 = 919,60 (sem redução acima de 7.350,00)');
-- 4.500,00: INSS 431,51 < 607,20 -> simplificado; base 3.892,80; 22,5%: 875,88 - 675,49 = 200,39;
-- rendimento até 5.000,00: redução 200,39 (limitada a 312,89) -> zero
SELECT is((SELECT valor_irrf FROM folha.calc_irrf(4500.00, 431.51, 0, '2026-10-31')), 0.00::numeric,
  'IRRF 4.500,00 = 0,00');
SELECT is((SELECT redutor_lei_15270 FROM folha.calc_irrf(4500.00, 431.51, 0, '2026-10-31')), 200.39::numeric,
  'IRRF 4.500,00: redução da Lei 15.270/2025 = 200,39 (o imposto da tabela)');
-- 3.500,00 com 2 dependentes: legais 308,60 + 2 x 189,59 = 687,78 > 607,20; base 2.812,22;
-- 7,5%: 210,9165 - 182,16 = 28,7565; rendimento até 5.000,00 -> zero
SELECT is((SELECT valor_irrf FROM folha.calc_irrf(3500.00, 308.60, 2, '2026-10-31')), 0.00::numeric,
  'IRRF 3.500,00 com 2 dependentes = 0,00');
SELECT is((SELECT desconto_aplicado FROM folha.calc_irrf(3500.00, 308.60, 2, '2026-10-31')), 'legais',
  'IRRF 3.500,00 com 2 dependentes: deduções legais vencem o simplificado');
-- Data de pagamento, não competência (E-16d): 5.400,00 com INSS 557,51; simplificado;
-- base 4.792,80; 27,5%: 1.318,02 - 908,73 = 409,29. Pago em 31/12/2025 não há redução;
-- pago em 01/01/2026 a redução é 978,62 - 0,133145 x 5.400,00 = 259,637 -> 149,653
SELECT is((SELECT valor_irrf FROM folha.calc_irrf(5400.00, 557.51, 0, '2025-12-31')), 409.29::numeric,
  'IRRF 5.400,00 pago em 31/12/2025 = 409,29 (tabela de 2025, sem redução)');
SELECT is((SELECT valor_irrf FROM folha.calc_irrf(5400.00, 557.51, 0, '2026-01-01')), 149.65::numeric,
  'IRRF 5.400,00 pago em 01/01/2026 = 149,65 (redução da Lei 15.270/2025)');

-- ---------------------------------------------------------------------------
-- FGTS por categoria
-- ---------------------------------------------------------------------------
SELECT is((SELECT fgts_deposito FROM folha.calc_fgts(3000.00, 'clt', '2026-10-01')), 240.00::numeric,
  'FGTS CLT 3.000,00 = 240,00 (8%)');
SELECT is((SELECT fgts_deposito FROM folha.calc_fgts(1200.00, 'aprendiz', '2026-10-01')), 24.00::numeric,
  'FGTS aprendiz 1.200,00 = 24,00 (2%)');
SELECT is(
  ARRAY[(SELECT fgts_deposito FROM folha.calc_fgts(1200.00, 'estagio', '2026-10-01')),
        (SELECT fgts_deposito FROM folha.calc_fgts(5000.00, 'pj', '2026-10-01')),
        (SELECT fgts_deposito FROM folha.calc_fgts(6000.00, 'contribuinte_individual', '2026-10-01'))],
  ARRAY[0, 0, 0]::numeric[],
  'FGTS: estagiário, PJ e contribuinte individual sem depósito');
SELECT is_empty(
  $$SELECT p.oid::regprocedure::text FROM pg_proc p
     WHERE p.pronamespace = 'folha'::regnamespace AND p.proname = 'calc_fgts'
       AND 'fgts_multa_rescisoria' = ANY (p.proargnames)$$,
  'calc_fgts não devolve mais a "multa" de 40% sobre o depósito do mês');

-- ---------------------------------------------------------------------------
-- Metadados e falhas
-- ---------------------------------------------------------------------------
SELECT is((SELECT tabela_vigencia FROM folha.calc_inss(3000.00, '2026-10-01')), '2026-01-01'::date,
  'calc_inss devolve a vigência da tabela usada');
SELECT is((SELECT tabela_vigencia FROM folha.calc_irrf(3000.00, 248.60, 0, '2025-03-31')), '2024-02-01'::date,
  'calc_irrf devolve a vigência da tabela escolhida pela data de pagamento');
SELECT is((SELECT aliquota FROM folha.calc_fgts(3000.00, 'clt', '2026-10-01')), 0.08::numeric,
  'calc_fgts devolve a alíquota de 8% para CLT');
SELECT throws_ok(
  $$SELECT * FROM folha.calc_inss(3000.00, '2020-01-01')$$,
  'Tabela INSS não encontrada para competência 2020-01-01',
  'calc_inss falha quando não há tabela para a competência');
SELECT hasnt_function('folha', 'calc_irrf', ARRAY['numeric', 'integer', 'boolean', 'date'],
  'a assinatura antiga de calc_irrf (base líquida de INSS e competência) foi removida');

SELECT * FROM finish();
ROLLBACK;
