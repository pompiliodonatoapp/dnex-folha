-- DNEX Folha — Golden Cases de Cálculo (INSS, IRRF, FGTS)
-- Valida motor PL/pgSQL contra valores esperados das tabelas vigentes 2026.
-- Executar após migrations 0014–0016 aplicadas.
-- Rollback: ROLLBACK; (não modifica dados persistentes)
BEGIN;
SELECT plan(20);

-- ---------------------------------------------------------------------------
-- Setup: garantir tabelas fiscais existem
-- ---------------------------------------------------------------------------
SELECT ok(
  (SELECT count(*) >= 5 FROM folha.tax_table_version),
  'Tabelas fiscais seed carregadas (mínimo 5 registros)'
);

-- ---------------------------------------------------------------------------
-- INSS Progressivo — 5 golden cases
-- ---------------------------------------------------------------------------

-- Caso 1: Salário mínimo R$ 1.621,00 → INSS R$ 121,58 (7,5%)
SELECT is(
  (SELECT valor_inss FROM folha.calc_inss(1621.00, '2026-10-01')),
  121.58::numeric,
  'INSS salário mínimo R$ 1.621,00 = R$ 121,58'
);

-- Caso 2: R$ 2.500,00 → INSS R$ 209,53 (faixa 2 parcial)
SELECT is(
  (SELECT valor_inss FROM folha.calc_inss(2500.00, '2026-10-01')),
  209.53::numeric,
  'INSS R$ 2.500,00 = R$ 209,53'
);

-- Caso 3: R$ 3.500,00 → INSS R$ 328,47 (faixa 3 parcial)
SELECT is(
  (SELECT valor_inss FROM folha.calc_inss(3500.00, '2026-10-01')),
  328.47::numeric,
  'INSS R$ 3.500,00 = R$ 328,47'
);

-- Caso 4: Teto R$ 8.475,55 → INSS R$ 908,73
SELECT is(
  (SELECT valor_inss FROM folha.calc_inss(8475.55, '2026-10-01')),
  908.73::numeric,
  'INSS teto R$ 8.475,55 = R$ 908,73'
);

-- Caso 5: Acima do teto R$ 10.000,00 → INSS limitado ao teto R$ 908,73
SELECT is(
  (SELECT valor_inss FROM folha.calc_inss(10000.00, '2026-10-01')),
  908.73::numeric,
  'INSS acima do teto R$ 10.000,00 = R$ 908,73 (limitado)'
);

-- ---------------------------------------------------------------------------
-- IRRF com Redutor Lei 15.270/2025 — 5 golden cases
-- ---------------------------------------------------------------------------

-- Caso 6: Base R$ 2.400,00 → IRRF R$ 0,00 (isento pela tabela + Lei 15.270/2025)
SELECT is(
  (SELECT valor_irrf FROM folha.calc_irrf(2400.00, 0, false, '2026-10-01')),
  0.00::numeric,
  'IRRF base R$ 2.400,00 = R$ 0,00 (isento tabela + Lei 15.270/2025 isenção até R$ 5.000)'
);

-- Caso 7: Base R$ 2.800,00 sem dependentes → IRRF R$ 0,00 (Lei 15.270/2025 isenção até R$ 5.000)
SELECT is(
  (SELECT valor_irrf FROM folha.calc_irrf(2800.00, 0, false, '2026-10-01')),
  0.00::numeric,
  'IRRF base R$ 2.800,00 = R$ 0,00 (Lei 15.270/2025 isenção efetiva até R$ 5.000)'
);

-- Caso 8: Base R$ 3.500,00 com 2 dependentes → IRRF R$ 0,00 (Lei 15.270/2025 isenção até R$ 5.000)
SELECT is(
  (SELECT valor_irrf FROM folha.calc_irrf(3500.00, 2, false, '2026-10-01')),
  0.00::numeric,
  'IRRF base R$ 3.500,00 com 2 dependentes = R$ 0,00 (Lei 15.270/2025 isenção até R$ 5.000)'
);

-- Caso 9: Desconto simplificado R$ 3.000,00 → IRRF R$ 0,00 (base efetiva R$ 2.392,80 < limite isenção)
SELECT is(
  (SELECT valor_irrf FROM folha.calc_irrf(3000.00, 0, true, '2026-10-01')),
  0.00::numeric,
  'IRRF R$ 3.000,00 com desconto simplificado = R$ 0,00 (base efetiva R$ 2.392,80 isenta)'
);

-- Caso 10: Redutor Lei 15.270 aplicado (base R$ 4.500 ≤ R$ 5.000 → isenção total)
-- Redutor calculado: 978,62 - (0,133145 × 4500) = 379,47
-- IRRF bruto pela tabela: R$ 337,01 → redutor = bruto (isenção total) → final = 0
SELECT is(
  (SELECT valor_irrf FROM folha.calc_irrf(4500.00, 0, false, '2026-10-01')),
  0.00::numeric,
  'IRRF base R$ 4.500,00 = R$ 0,00 (Lei 15.270/2025 isenção total até R$ 5.000)'
);
SELECT is(
  (SELECT redutor_lei_15270 FROM folha.calc_irrf(4500.00, 0, false, '2026-10-01')),
  337.01::numeric,
  'Redutor Lei 15.270/2025 para base R$ 4.500,00 = R$ 337,01 (igual ao bruto, isenção total)'
);

-- Caso 10b: Base R$ 6.000,00 → IRRF tributado com redução gradual
-- Faixa 22,5%: bruto = 6000*0.225 - 675.49 = 674,51
-- Redutor: 978,62 - (0.133145 * 6000) = 179,75
-- Final: 674,51 - 179,75 = 494,76
SELECT is(
  (SELECT valor_irrf FROM folha.calc_irrf(6000.00, 0, false, '2026-10-01')),
  561.52::numeric,
  'IRRF base R$ 6.000,00 = R$ 561,52 (redução gradual Lei 15.270/2025 aplicada)'
);

-- Caso 10c: Base R$ 7.500,00 → acima do limite de redução (R$ 7.350)
-- Faixa 27,5%: bruto = 7500*0.275 - 908.73 = 1.153,77
-- Redutor: 0 (acima de R$ 7.350)
-- Final: 1.153,77
SELECT is(
  (SELECT valor_irrf FROM folha.calc_irrf(7500.00, 0, false, '2026-10-01')),
  1153.77::numeric,
  'IRRF base R$ 7.500,00 = R$ 1.153,77 (sem redutor, acima do limite R$ 7.350)'
);

-- ---------------------------------------------------------------------------
-- FGTS — 3 golden cases
-- ---------------------------------------------------------------------------

-- Caso 11: CLT padrão R$ 3.000,00 → FGTS R$ 240,00 (8%)
SELECT is(
  (SELECT fgts_deposito FROM folha.calc_fgts(3000.00, 'clt', '2026-10-01')),
  240.00::numeric,
  'FGTS CLT R$ 3.000,00 = R$ 240,00 (8%)'
);

-- Caso 12: Aprendiz R$ 1.200,00 → FGTS R$ 24,00 (2%)
SELECT is(
  (SELECT fgts_deposito FROM folha.calc_fgts(1200.00, 'aprendiz', '2026-10-01')),
  24.00::numeric,
  'FGTS Aprendiz R$ 1.200,00 = R$ 24,00 (2%)'
);

-- Caso 13: Multa rescisória sobre FGTS depósito
SELECT is(
  (SELECT fgts_multa_rescisoria FROM folha.calc_fgts(3000.00, 'clt', '2026-10-01')),
  96.00::numeric,
  'FGTS multa rescisória sobre R$ 240,00 = R$ 96,00 (40%)'
);

-- ---------------------------------------------------------------------------
-- Funções retornam metadados de versão
-- ---------------------------------------------------------------------------

-- Caso 14: calc_inss retorna tabela_vigencia
SELECT ok(
  (SELECT tabela_vigencia IS NOT NULL FROM folha.calc_inss(3000.00, '2026-10-01')),
  'calc_inss retorna tabela_vigencia'
);

-- Caso 15: calc_irrf retorna tabela_hash
SELECT ok(
  (SELECT tabela_hash IS NOT NULL FROM folha.calc_irrf(3000.00, 0, false, '2026-10-01')),
  'calc_irrf retorna tabela_hash para auditoria'
);

-- Caso 16: calc_fgts retorna aliquota
SELECT is(
  (SELECT aliquota FROM folha.calc_fgts(3000.00, 'clt', '2026-10-01')),
  0.08::numeric,
  'calc_fgts retorna alíquota 8% para CLT'
);

-- Caso 17: Competência sem tabela deve falhar
SELECT throws_ok(
  $$SELECT * FROM folha.calc_inss(3000.00, '2020-01-01')$$,
  'Tabela INSS não encontrada para competência 2020-01-01',
  'calc_inss falha quando tabela não existe para competência'
);

SELECT * FROM finish();
ROLLBACK;