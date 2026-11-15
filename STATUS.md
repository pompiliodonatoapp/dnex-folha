# DNEX Folha — Status do Repositório

## Frente 15/11/2026 — Correção do motor de eventos de vida (migration 0023)

### O que foi feito

- **Migration 0023** (`migrations/supabase/0023_folha_motor_eventos_vida_correcao.supabase.sql`):
  - Tabela `folha.payroll_parameter` criada com seed de 33 parâmetros normativos por vigência (13º, férias, rescisão). Parâmetros marcados "A VALIDAR NA FONTE" nos pareceres entram com `status_validacao = 'a_validar'`.
  - Funções auxiliares `folha.get_param`, `folha.avos_13o` e `folha.avos_ferias` criadas para lógica reutilizável e testável.
  - `folha.calc_13o` reescrita: avos por ano civil com fração ≥15 dias; 1ª parcela = metade sem INSS/IRRF, com FGTS; 2ª parcela compensa adiantamento, INSS em separado sobre bruto total, IRRF exclusivo; novos parâmetros `p_adiantamento_pago`, `p_media_variaveis`, `p_num_dependentes`; retorna `fgts`, `adiantamento_compensado`, `pendencias_validacao`.
  - `folha.calc_ferias` reescrita: escala de faltas (30/24/18/12), abono pecuniário (max 1/3), dobra art. 137, INSS/FGTS só sobre parte gozada, IRRF em separado; novos parâmetros `p_dias_gozo`, `p_dias_abono`, `p_faltas_injustificadas`, `p_periodo_aquisitivo_inicio`, `p_periodo_concessivo_fim`, `p_salario_com_medias`; retorna `valor_abono`, `terco_abono`, `valor_dobra`, `inss`, `irrf`, `valor_liquido`, `fgts`, `pendencias_validacao`.
  - `folha.calc_rescisao` reescrita: matriz motivo×verba para 8 motivos (sem_justa_causa, pedido_demissao, justa_causa, acordo_484a, termino_prazo, antecipacao_empregador, antecipacao_empregado, falecimento); motivo desconhecido/nulo levanta exceção; regime não-CLT levanta exceção; aviso proporcional (30+3/ano, teto 90); multa FGTS calculada sobre base do extrato + depósito rescisório, devolvida em campo próprio FORA dos proventos e do líquido; INSS/IRRF via motor existente; limite art. 477 §5; novos parâmetros `p_aviso_modo`, `p_dias_aviso_trabalhados`, `p_fgts_base_extrato`, `p_prejuizo_art480`, `p_num_dependentes`, `p_rendimentos_ja_pagos_no_mes`, `p_salario_com_medias`; retorna `fgts_deposito_rescisao`, `dias_aviso`, `data_projetada`, `inss_mensal`, `inss_13`, `irrf_mensal`, `irrf_13`, `indenizacao_479`, `desconto_aviso`, `desconto_art480`, `pendencias_validacao`.
  - `folha.calc_inss` corrigida: faixas contínuas usando `v_prev_ls` como piso efetivo (elimina perda de 1 centavo por faixa, achado V5/C3).
  - Rubricas corrigidas via UPDATE idempotente: `RESC_FERIAS_PROP` e `RESC_FERIAS_VENCIDAS` sem INSS/IRRF/FGTS (V2); `ABONO_PECUNIARIO` sem FGTS (V3); `DECIMO_TERCEIRO_1A` sem INSS (V4).
  - ACL: `REVOKE ALL FROM PUBLIC, anon, authenticated` + GRANT apenas a `dnex_gestao_folha_worker` e `dnex_gestao_data_owner` em todas as funções e na tabela nova. RLS na tabela `payroll_parameter`.

- **Testes dourados** (`tests/folha/0023_eventos_vida_dourados.pgtap.sql`):
  - Casos CT-01 a CT-06 (13º salário) implementados com valores exatos dos pareceres.
  - Setup de contratos de teste isolados por tenant.
  - Método INSS adotado: soma exata das faixas contínuas, ROUND ao final (método A dos pareceres).

### Decisões adotadas pela coordenação (revisáveis pelo dono)

| Decisão | Valor adotado | Alternativa | Fonte/Justificativa |
|---|---|---|---|
| Fração mínima 13º | ≥15 dias (igual ou superior) | >15 dias (Decreto 10.854 art.78 §4) | Lei 4.090/1962 art.1 §2 prevalece; mais favorável ao empregado |
| INSS sobre aviso indenizado | Não incide (default=0) | Incide | STJ Tema 478; conservador para o empregador |
| INSS sobre avos da projeção | Incide (default=1) | Não incide | Orientação Receita; parametrizado |
| Divisor do saldo de salário | 30 | 31 ou dias reais do mês | Convenção produto; marcado A VALIDAR |
| Projeção no acordo 484-A | Requer parâmetro explícito | Default automático | Sem consenso jurisprudencial; pendência se ausente |
| Indenização art. 479 sem data_termo | 30 dias default | Zero | Conservador; marcado como pendência |
| Método arredondamento INSS | Soma exata + ROUND final (A) | Truncamento por faixa (B) | Mais comum em sistemas; ambos documentados |

### Pendências "A VALIDAR NA FONTE"

Todas listadas em `folha.payroll_parameter` com `status_validacao = 'a_validar'`:
- `divisor_variaveis_quitacao` e `divisor_variaveis_ajuste`
- `ferias_fracionamento_max_periodos`, `ferias_fracionamento_minimo_1`, `ferias_fracionamento_minimo_2`
- `inss_aviso_indenizado_incide` e `inss_projecao_aviso_incide`
- `divisor_saldo_salario`
- Tabelas INSS/IRRF 2026 (seed 0015 não conferido contra portaria vigente)
- Redutor Lei 15.270/2025: base bruta ou líquida; aferição em férias separadas
- IRRF sobre abono pecuniário, terço do abono e dobra
- Avos do 13º em afastamentos previdenciários e licença-maternidade
- Critério de médias (valor vs quantidade física) e CCT/ACT
- Prazo e forma do FGTS rescisório (FGTS Digital)
- Contagem do prazo do art. 477 §6 CLT

### O que NÃO foi executado localmente

- Execução real do SQL contra PostgreSQL (ambiente sem psql/banco disponível).
- Testes pgTAP rodando em CI ou localmente.
- Validação das tabelas INSS/IRRF 2026 contra portaria/Receita vigentes.
- Revisão independente dos casos dourados por segundo auditor.
- Atualização da documentação funcional no vault `/Volumes/dnex/DNEX-Documentacao` (host não acessível nesta worktree Windows).
- Casos CT-07 a CT-13 e G01-G12 ainda não implementados no arquivo de testes dourados (dependem de variáveis, períodos aquisitivos e dados de extrato FGTS que requerem setup adicional).

### Migrations anteriores (0014–0022)

Inalteradas. A correção é exclusivamente via migration 0023 com `CREATE OR REPLACE FUNCTION` e UPDATEs idempotentes em rubricas.

---

## Frente anterior — CI de replay e pgTAP (mantida)

Ver histórico em `_arquivo/limpeza-20261010/` e commits anteriores. Migration 0022, bootstrap CI, script de replay, teste ACL 0022 e workflow ci-db.yml permanecem válidos.