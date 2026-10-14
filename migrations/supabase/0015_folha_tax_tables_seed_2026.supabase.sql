-- DNEX Folha — Seed inicial das tabelas fiscais federais vigentes em 2026.
-- Dados extraídos de references/tabelas-encargos-esocial-fontes.md (skill dnex-brazilian-payroll-domain v2.0.1).
-- Última conferência geral: 2026-07-18. Guardas [verificar em AAAA-MM] mantidas nos comentários.
-- Rollback: DELETE FROM folha.tax_table_version WHERE vigencia_inicio >= '2026-01-01' AND vigencia_inicio < '2027-01-01';
BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Salário mínimo nacional 2026
-- Fonte: Decreto do salário mínimo 2026 (DOU) · gov.br
-- Guarda: [verificar em 2026-07] — validar no Decreto/DOU
-- ---------------------------------------------------------------------------
INSERT INTO folha.tax_table_version (tipo, vigencia_inicio, tabela_json, source_url, source_hash, captured_at)
VALUES (
  'salario_minimo',
  '2026-01-01',
  '{"valor": 1621.00, "moeda": "BRL"}'::jsonb,
  'https://www.gov.br/trabalho-e-emprego/pt-br/assuntos/salario-minimo',
  'sha256:salario_minimo_2026_decreto_dou',
  '2026-07-18T00:00:00Z'
) ON CONFLICT (tipo, vigencia_inicio) DO UPDATE SET
  tabela_json = EXCLUDED.tabela_json,
  source_url = EXCLUDED.source_url,
  captured_at = EXCLUDED.captured_at;

-- ---------------------------------------------------------------------------
-- 2. Teto de contribuição INSS 2026
-- Fonte: Portaria Interministerial MPS/MF nº 13/2026 (DOU)
-- Guarda: [verificar em 2026-07] — validar na Portaria/DOU
-- ---------------------------------------------------------------------------
INSERT INTO folha.tax_table_version (tipo, vigencia_inicio, tabela_json, source_url, source_hash, captured_at)
VALUES (
  'inss',
  '2026-01-01',
  '{
    "teto": 8475.55,
    "faixas": [
      {"limite_inferior": 0, "limite_superior": 1621.00, "aliquota": 0.075},
      {"limite_inferior": 1621.01, "limite_superior": 2902.84, "aliquota": 0.09},
      {"limite_inferior": 2902.85, "limite_superior": 4354.27, "aliquota": 0.12},
      {"limite_inferior": 4354.28, "limite_superior": 8475.55, "aliquota": 0.14}
    ],
    "tipo_calculo": "progressivo_por_faixa",
    "desconto_maximo_aproximado_teto": null
  }'::jsonb,
  'https://www.gov.br/previdencia/pt-br/assuntos/portarias-interministeriais',
  'sha256:inss_teto_2026_portaria_13_mps_mf',
  '2026-07-18T00:00:00Z'
) ON CONFLICT (tipo, vigencia_inicio) DO UPDATE SET
  tabela_json = EXCLUDED.tabela_json,
  source_url = EXCLUDED.source_url,
  captured_at = EXCLUDED.captured_at;

-- ---------------------------------------------------------------------------
-- 3. IRRF mensal 2026 (rendimento do trabalho) + Redutor Lei 15.270/2025
-- Fonte: Receita Federal — Tributação de 2026; Lei 15.191/2025 e Lei 15.270/2025
-- Guarda: [verificar em 2026-07] — confirmar fórmula e limites na IN/ADE vigente
-- ---------------------------------------------------------------------------
INSERT INTO folha.tax_table_version (tipo, vigencia_inicio, tabela_json, source_url, source_hash, captured_at)
VALUES (
  'irrf',
  '2026-01-01',
  '{
    "faixas": [
      {"limite_inferior": 0, "limite_superior": 2428.80, "aliquota": 0, "parcela_deduzir": 0},
      {"limite_inferior": 2428.81, "limite_superior": 2826.65, "aliquota": 0.075, "parcela_deduzir": 182.16},
      {"limite_inferior": 2826.66, "limite_superior": 3751.05, "aliquota": 0.15, "parcela_deduzir": 394.16},
      {"limite_inferior": 3751.06, "limite_superior": 4664.68, "aliquota": 0.225, "parcela_deduzir": 675.49},
      {"limite_inferior": 4664.69, "limite_superior": null, "aliquota": 0.275, "parcela_deduzir": 908.73}
    ],
    "deducao_dependente_mensal": 189.59,
    "desconto_simplificado_mensal": 607.20,
    "redutor_lei_15270_2025": {
      "isencao_efetiva_ate": 5000.00,
      "reducao_decrescente_ate": 7350.00,
      "formula": "978.62 - (0.133145 * rendimento_tributavel)",
      "aplicacao": "apos_calculo_tabela"
    },
    "base_legal": ["Lei 15.191/2025", "Lei 15.270/2025", "Decreto 9.580/2018 (RIR/2018)"]
  }'::jsonb,
  'https://www.gov.br/receitafederal/pt-br/assuntos/meu-imposto-de-renda/tabelas/2026',
  'sha256:irrf_2026_rfb_lei_15270_redutor',
  '2026-07-18T00:00:00Z'
) ON CONFLICT (tipo, vigencia_inicio) DO UPDATE SET
  tabela_json = EXCLUDED.tabela_json,
  source_url = EXCLUDED.source_url,
  captured_at = EXCLUDED.captured_at;

-- ---------------------------------------------------------------------------
-- 4. FGTS — alíquotas vigentes
-- Fonte: Lei 8.036/1990, art. 15 e §7º; art. 18, §1º (multa 40%)
-- Guarda: [verificar em 2026-07]
-- ---------------------------------------------------------------------------
INSERT INTO folha.tax_table_version (tipo, vigencia_inicio, tabela_json, source_url, source_hash, captured_at)
VALUES (
  'fgts',
  '2026-01-01',
  '{
    "deposito_mensal_empregado": 0.08,
    "aprendiz": 0.02,
    "multa_rescisorias_dispensa_sem_justa_causa": 0.40,
    "multa_adicional_lc_110_2001": {"extinta_desde": "2020-01-01", "lei_extincao": "Lei 13.932/2019"},
    "base_legal": "Lei 8.036/1990"
  }'::jsonb,
  'https://www.planalto.gov.br/ccivil_03/leis/L8036consol.htm',
  'sha256:fgts_lei_8036_1990_art15_art18',
  '2026-07-18T00:00:00Z'
) ON CONFLICT (tipo, vigencia_inicio) DO UPDATE SET
  tabela_json = EXCLUDED.tabela_json,
  source_url = EXCLUDED.source_url,
  captured_at = EXCLUDED.captured_at;

-- ---------------------------------------------------------------------------
-- 5. Salário-família 2026 (valores e faixas)
-- Fonte: Lei 8.213/1991; Portaria anual MPS/MF
-- Guarda: valor/faixa [a confirmar] na Portaria vigente
-- NOTA: Valores placeholder — REVALIDAR NA PORTARIA VIGENTE ANTES DE USAR EM PRODUÇÃO
-- ---------------------------------------------------------------------------
INSERT INTO folha.tax_table_version (tipo, vigencia_inicio, tabela_json, source_url, source_hash, captured_at)
VALUES (
  'salario_familia',
  '2026-01-01',
  '{
    "cota_baixa_renda": null,
    "cota_alta_renda": null,
    "faixa_baixa_renda_ate": null,
    "observacao": "VALORES PLACEHOLDER — REVALIDAR NA PORTARIA MPS/MF VIGENTE ANTES DE USAR EM PRODUÇÃO",
    "status_confirmacao": "a_confirmar",
    "base_legal": "Lei 8.213/1991"
  }'::jsonb,
  'https://www.gov.br/previdencia/pt-br/assuntos/salario-familia',
  'sha256:salario_familia_2026_placeholder_a_confirmar',
  '2026-07-18T00:00:00Z'
) ON CONFLICT (tipo, vigencia_inicio) DO UPDATE SET
  tabela_json = EXCLUDED.tabela_json,
  source_url = EXCLUDED.source_url,
  captured_at = EXCLUDED.captured_at;

COMMIT;