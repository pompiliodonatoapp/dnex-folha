-- DNEX Folha — Seed do catálogo de rubricas core (proventos, descontos, encargos).
-- Rubricas globais (is_global=true) são legíveis por todos os tenants;
-- overrides por tenant usam account_id específico.
-- Rollback: DELETE FROM folha.earning_deduction_code WHERE is_global = true;
BEGIN;

-- ---------------------------------------------------------------------------
-- PROVENTOS
-- ---------------------------------------------------------------------------
INSERT INTO folha.earning_deduction_code (codigo, descricao, natureza, incidencia_inss, incidencia_irrf, incidencia_fgts, is_global)
VALUES
  ('SALARIO_BASE', 'Salário base contratual', 'provento', true, true, true, true),
  ('HE_50', 'Hora extra 50%', 'provento', true, true, true, true),
  ('HE_100', 'Hora extra 100%', 'provento', true, true, true, true),
  ('ADIC_NOTURNO', 'Adicional noturno (CLT art. 73)', 'provento', true, true, true, true),
  ('DSR', 'Descanso semanal remunerado', 'provento', true, true, true, true),
  ('FERIAS_VENCIDAS', 'Férias vencidas + 1/3 constitucional', 'provento', true, true, true, true),
  ('FERIAS_PROPORCIONAL', 'Férias proporcionais + 1/3', 'provento', true, true, true, true),
  ('ABONO_PECUNIARIO', 'Abono pecuniário de férias (10 dias)', 'provento', false, false, true, true),
  ('DECIMO_TERCEIRO_1A', '13º salário 1ª parcela', 'provento', true, false, true, true),
  ('DECIMO_TERCEIRO_2A', '13º salário 2ª parcela', 'provento', true, true, true, true),
  ('COMISSAO', 'Comissões sobre vendas/serviços', 'provento', true, true, true, true),
  ('GRATIFICACAO_FUNCAO', 'Gratificação de função/cargo', 'provento', true, true, true, true),
  ('INSALUBRIDADE', 'Adicional de insalubridade', 'provento', true, true, true, true),
  ('PERICULOSIDADE', 'Adicional de periculosidade (30%)', 'provento', true, true, true, true),
  ('SALARIO_FAMILIA', 'Salário-família (Lei 8.213/91)', 'provento', false, false, false, true),
  ('AVISO_PREVIO_INDENIZADO', 'Aviso prévio indenizado', 'provento', false, false, true, true),
  ('MULTA_ART477', 'Multa art. 477 §8º CLT (atraso rescisão)', 'provento', false, false, false, true),
  ('RESC_SALDO_SALARIO', 'Saldo de salário na rescisão', 'provento', true, true, true, true),
  ('RESC_DECIMO_TERCEIRO_PROP', '13º proporcional na rescisão', 'provento', true, true, true, true),
  ('RESC_FERIAS_PROP', 'Férias proporcionais + 1/3 na rescisão', 'provento', true, true, true, true),
  ('RESC_FERIAS_VENCIDAS', 'Férias vencidas + 1/3 na rescisão', 'provento', true, true, true, true)
ON CONFLICT (account_id, codigo) DO NOTHING;

-- ---------------------------------------------------------------------------
-- DESCONTOS
-- ---------------------------------------------------------------------------
INSERT INTO folha.earning_deduction_code (codigo, descricao, natureza, incidencia_inss, incidencia_irrf, incidencia_fgts, is_global)
VALUES
  ('INSS_EMPREGADO', 'INSS contribuição empregado (progressivo)', 'desconto', false, false, false, true),
  ('IRRF', 'IRRF retido na fonte', 'desconto', false, false, false, true),
  ('VALE_TRANSPORTE', 'Vale-transporte desconto empregado (até 6%)', 'desconto', false, false, false, true),
  ('VALE_REFEICAO', 'Vale-refeição/alimentação desconto empregado', 'desconto', false, false, false, true),
  ('PLANO_SAUDE', 'Plano de saúde co-participação/desconto', 'desconto', false, false, false, true),
  ('PENSAO_ALIMENTICIA', 'Pensão alimentícia judicial', 'desconto', false, false, false, true),
  ('FALTAS', 'Desconto por faltas não justificadas', 'desconto', false, false, false, true),
  ('ATRASOS', 'Desconto por atrasos', 'desconto', false, false, false, true),
  ('ADIANTAMENTO_SALARIAL', 'Adiantamento salarial (vale)', 'desconto', false, false, false, true),
  ('EMPRESTIMO_CONSIGNADO', 'Empréstimo consignado', 'desconto', false, false, false, true),
  ('OUTROS_DESCONTOS', 'Outros descontos autorizados', 'desconto', false, false, false, true)
ON CONFLICT (account_id, codigo) DO NOTHING;

-- ---------------------------------------------------------------------------
-- INFORMATIVOS (não afetam líquido, apenas memória)
-- ---------------------------------------------------------------------------
INSERT INTO folha.earning_deduction_code (codigo, descricao, natureza, incidencia_inss, incidencia_irrf, incidencia_fgts, is_global)
VALUES
  ('FGTS_DEPOSITO', 'FGTS depósito mensal empregador (8%)', 'informativo', false, false, false, true),
  ('FGTS_MULTA_RESCISORIA', 'FGTS multa rescisória 40%', 'informativo', false, false, false, true),
  ('INSS_PATRONAL', 'INSS patronal empresa (20% regra geral)', 'informativo', false, false, false, true),
  ('RAT_SAT', 'RAT/SAT grau de risco (1/2/3%) × FAP', 'informativo', false, false, false, true),
  ('TERCEIROS', 'Contribuições terceiros/Sistema S', 'informativo', false, false, false, true),
  ('BASE_INSS', 'Base de cálculo INSS empregado', 'informativo', false, false, false, true),
  ('BASE_IRRF', 'Base de cálculo IRRF', 'informativo', false, false, false, true),
  ('BASE_FGTS', 'Base de cálculo FGTS', 'informativo', false, false, false, true)
ON CONFLICT (account_id, codigo) DO NOTHING;

COMMIT;