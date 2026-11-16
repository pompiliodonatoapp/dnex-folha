# ADR — Contabilização da folha com partida fechada e provisões de férias e 13º

Data: 15/11/2026. Estado: **implementada na migration 0030, não aplicada em nenhum ambiente**; aceite do proprietário pendente. Fonte: parecer técnico contábil de 15/11/2026 (14 erros em `folha.build_contabil_folha` e no outbox, 15 regras de validação, casos GC-01 a GC-08).

## Problema

O construtor antigo gravava contas fixas no código, lia só o total do resultado (não os itens por rubrica), fechava a partida apenas porque o motor gravava `total_descontos = INSS + IRRF` e gerava um evento por resultado. No caso GC-02 (VT, pensão e adiantamento) faltavam R$ 3.100,00 de crédito. Não havia provisão, pagamento separado da apropriação, estorno em recálculo nem reconciliação por valor.

## Decisão

1. **Mapeamento configurável.** `contabil_config` (por empregador) e `contabil_mapa` (rubrica/papel -> natureza -> conta, com vigência e escopo opcional por estabelecimento, lotação e centro de custo). Nenhuma conta no código, nenhum plano de contas embutido, nenhum seed ativo. Sem mapeamento vigente para rubrica usada, o lote não sai: pendência de bloqueio, NÃO liberável, listando as rubricas que faltam (FC001).
2. **Construtor por itens.** `contabil_folha_montar` parte dos itens por rubrica (0026/0027), por competência, em centavos inteiros; encargos patronais por lotação a partir do `calculation_trace`; pró-labore em evento próprio; multa do FGTS rescisório fora do líquido.
3. **Partida fechada no dado.** CHECK `lote_balanceado` e gatilho que recalcula totais a partir das linhas; lote desbalanceado não entra no outbox. Totais = soma das linhas.
4. **Provisões** em razão por trabalhador (`provision_ledger`, só INSERT): constituição com encargos, baixa no pagamento, estorno na rescisão. Os dois pontos que o parecer não fecha viram parâmetros `a_validar` com pendência: `contabil_provisao_encargos_incide_terco_ferias` e `contabil_rescisao_baixa_provisao_encargos`. O lote que depende deles nasce `retido`; sai com liberação (`folha.close`) com motivo.
5. **Pagamento separado.** Lote por comprovante (`comprovante_ref` único), limitado ao saldo do passivo por grupo.
6. **Recálculo.** Uma contabilização por folha e versão; hash igual não cria lote; pendente é cancelado e substituído; despachado/confirmado gera ESTORNO e nova versão. Folha com pagamento já contabilizado não é recalculada (bloqueio `pagamento_registrado`).
7. **Quem pode.** Só folha FECHADA e sem pendência aberta, pela conta do contexto da 0028. Permissões: `folha.admin` (config, mapa, dimensão), `folha.calculate` (direito de provisão), `folha.transmit` (contabilizar, provisão, pagamento), `folha.close` (liberar `a_validar`), `folha.read` (situação). Subject gravado.
8. **Contrato** `gestao.folha-handoff.v2` (v1 marcado superado), validado por `scripts/validate_folha_handoff.py`.
9. **ACL/RLS** no padrão da 0028: funções `_v1` com EXECUTE só para `dnex_gestao_api`, REVOKE antes de GRANT, `search_path` terminando em `pg_temp`, FKs compostas com `account_id`, RLS forçada nas tabelas novas.
10. `v_reconciliacao_contabil` compara por valor (agregados por LATERAL, sem multiplicação pelo join). Os contadores de eventos passam a contar todos os lotes da folha (pagamento, estorno), não um por resultado.

## Divergências com o parecer

- **GC-08, sem mapeamento:** o parecer pede "erro listando a rubrica"; o código devolve `situacao = bloqueada`, grava pendência de bloqueio e nenhuma linha no outbox. `dispatch_folha_completa` devolve contagem contábil 0 sem erro; consumidores devem ler a situação/pendência (ponto em aberto para a UI).
- **V7 (recálculo):** com pagamento já contabilizado (não rejeitado/cancelado) o recálculo é BLOQUEADO (`pagamento_registrado`), em vez de estorno e nova versão. O bloqueio é por folha e empregador, não por grupo, e não há função de estornar pagamento: a saída operacional ainda não existe (ponto em aberto 11).
- **Chave de versão:** os índices de versão incluem `run_id` (folha) ou a competência (provisão); a chave do parecer não tinha `run_id`, e sem ele duas folhas da mesma competência colidiriam.
- **Direito de provisão:** `contabil_provisao_direito_informar_v1` aceita mudança (fica na auditoria; a constituição é refeita pela V7).
- **V5:** só folha `closed` (o parecer admite aprovada ou fechada); mais restritivo, documentado e testado.
- `dispatch_accounting_event` agora sempre levanta 0A000 (o despacho é por folha); `build_contabil_folha` devolve prévia no formato v2.
- Unicidade de versão: índices parciais por folha/empregador/evento/versão e por provisão (o parecer pedia UNIQUE completo; o filtro exclui pagamento e estorno, que repetem versão).

## Pontos em aberto (decisão do proprietário ou validação na fonte)

1. Os dois parâmetros `a_validar` acima (valor atual 1 e 0, status `a_validar`).
2. Pagamento de comprovante único que consolida várias folhas (guia previdenciária mensal, FGTS): hoje um comprovante atende uma folha e um empregador; usar referência por folha ou criar rateio do comprovante.
3. Baixa do ativo "salário-família a compensar" no recolhimento previdenciário: não há movimento D passivo / C ativo.
4. Baixa de provisão para rubricas rescisórias sem mapeamento de baixa (férias vencidas, art. 479): a despesa pode duplicar e a sobra é estornada; avaliar alerta.
5. FGTS para contribuinte individual: hoje o mapeamento é genérico; parecer diz que só ocorre por opção da empresa.
6. Lote `retido` já grava movimentos no razão de provisão; baixa seguinte pode consumi-los.
7. Casos GC-06b (rescisão com provisão de encargos), 13º parcelas e estorno de lote de provisão já despachado sem teste dedicado.
8. Vigência dos parâmetros `a_validar` a partir de 2024-01-01 (`get_param` levanta erro antes disso).
9. Auditoria de contabilizar/bloqueio sem `legal_entity_id`/`branch_id`; guarda do outbox não confere `employerId`/`payrollRunId`; ordem dos advisory locks por empregador na provisão sem ORDER garantido; sem trava de dado para saldo de provisão negativo.
11. Estorno/cancelamento de pagamento contabilizado errado (hoje bloqueia recálculo da folha) e bloqueio mais fino por grupo.
12. Sem teste de concorrência (liberações simultâneas, pagamento versus recálculo, dois recálculos).

## Consequências

Nada vai a produção sem aceite, aplicação da 0030 e configuração do mapeamento contábil de cada empregador pelo contador. O `down.sql` recusa reversão com dado.
