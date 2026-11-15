# ADR — Folha por rubricas: incidência por código, bases, três camadas de regra e tipos de processo

- **Data:** 15/11/2026
- **Estado:** proposta (aceite do proprietário pendente)
- **Migrations:** 0026 (estrutura e dados) e 0027 (motor e trava)
- **Fontes:** `PLANO-CONSTRUCAO-FOLHA.md` (modelo de dados e bloqueios de produção) e pareceres de DP de 15/11/2026

## Contexto

Até a 0025 a folha calculava sobre o salário contratual do mês cheio, a rubrica tinha três indicadores booleanos de incidência,
havia uma folha por conta e competência, e a pendência `a_validar` ficava só no JSON da memória de cálculo, sem impedir o
fechamento.

## Decisão

1. **Rubrica.** `earning_deduction_code` ganha tipo (provento, desconto, informativa, base), forma de cálculo e ordem. A
   incidência passa a ser um **código por tributo, com vigência** (`rubric_incidence` → `incidence_code`). O código é interno e
   descreve o efeito no motor (não incide, compõe base, é a própria retenção); o código oficial do eSocial e a natureza da
   rubrica ficam em colunas e tabela próprias, vazias e `a_validar`, até serem lidos no leiaute. Os indicadores booleanos da 0014
   ficam como legado, sem leitura pelo motor.
2. **Base de cálculo como entidade** (`calculation_base`), ligada N:N à rubrica com vigência (`rubric_base`). Provento soma,
   desconto subtrai. O código de incidência e as bases ligadas têm de concordar: o motor confere e recusa rubrica incoerente.
3. **Três camadas de regra** (`rubric_rule`): empresa, convenção coletiva (ligada ao contrato) e contrato. A precedência é dado
   (`rule_layer`): contrato > convenção > empresa. Cada item gravado e cada passo da memória de cálculo trazem a camada, a regra
   e as regras vencidas. Sem regra, vale o valor informado no lançamento (camada `lancamento`); o que o motor apura traz `motor`.
4. **Formas de cálculo:** valor fixo, percentual sobre base, quantidade x valor e fórmula. A fórmula é uma árvore JSON com
   operações e variáveis de lista fechada, validada por CHECK e avaliada sem SQL dinâmico.
5. **Tipo de processo na folha:** mensal, adiantamento, complementar, 13º 1ª e 2ª parcela, férias e rescisão, pela mesma
   `run_payroll_employee`. Várias folhas por competência (unicidade por conta, empregador, competência, tipo e sequência).
   13º, férias e rescisão continuam nas funções da 0023 e passam a gravar itens por rubrica.
6. **Resultado como dado:** itens por rubrica, bases apuradas e pendências em tabelas próprias.
7. **Trava de fechamento:** folha com pendência sem liberação registrada (quem, quando, motivo, sessão; também na auditoria) não
   é aprovada nem fechada. A folha só anda um estado por vez, congela identidade e totais depois de calculada, e fechar exige
   data de pagamento. Só o motor grava resultado.

## Alternativas descartadas

- Semear os códigos de incidência do eSocial a partir da lista observada em sistema de mercado: sem significado nem fonte oficial.
- Copiar o catálogo de rubricas por empresa: mantido o catálogo global com regras por camada.
- Fórmula em texto com SQL: risco de execução de dado.
- Trocar o retorno de `calc_irrf_separado`: quebraria as funções e os testes da 0023; a pendência sai por função irmã.

## Consequências

- Toda folha com parâmetro `a_validar` exige liberação explícita para fechar, até a validação na fonte.
- Rubrica de conta não pode repetir código de rubrica global; a conta não altera incidência nem base de rubrica global.
- As tabelas de INSS e de salário mínimo de 2026 fecham em 31/12/2026: competência de 2027 sem a tabela do ano levanta erro.
- Pendentes: natureza e códigos do eSocial; médias apuradas pelo motor (as bases de médias, 13º e férias existem sem rubrica
  ligada); reapuração no mês de gozo; deduções de pensão e previdência complementar; versão das regras usadas em folha fechada.
