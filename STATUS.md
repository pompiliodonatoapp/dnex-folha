# DNEX Folha — Status do Repositório

## Frente 15/11/2026 (fatia 3) — Migration 0025: motor mensal

Branch `fix/folha-motor-mensal-20261115`, PR em rascunho. Nada aplicado em produção nem no Supabase.
**Não aplicar em produção** sem a dependência do dnex-gestao da 0024 e sem decidir o que está `a_validar`.

### O que entrou

- **Migration 0025** (`migrations/supabase/0025_folha_motor_mensal.supabase.sql`, reversão em `.down.sql`):
  - `calc_inss`: arredondamento por parâmetro (`inss_arredondamento_metodo`, `a_validar`) e erro se o teto diferir do fim da última faixa. `calc_inss_segurado(base, categoria, competência)`: tabela progressiva para CLT e aprendiz; pró-labore (categoria nova `contribuinte_individual`) com 11% até o teto; estagiário e PJ sem INSS.
  - `calc_irrf(rendimento, INSS retido, dependentes, data de pagamento, outras deduções)`: redução da Lei 15.270/2025 pelo rendimento tributável bruto, com limites, teto e coeficientes em `payroll_parameter`; maior entre deduções legais e desconto simplificado; tabela escolhida pela data de pagamento. `calc_irrf_separado` (0023) usa a mesma apuração (`irrf_apurar`).
  - `calc_fgts`: 8% CLT, 2% aprendiz, zero para estagiário, PJ e contribuinte individual; sem a "multa" de 40% sobre o depósito do mês.
  - `calc_salario_familia`: cota e limite por vigência (2024, 2025, 2026), faixa única.
  - `calc_encargos_patronais`: por lotação do rateio do contrato, com o regime do empregador vigente: regra geral, CPRB (fator da transição, sem o 13º), Simples com CPP no DAS e fora do DAS, pró-labore sem RAT. Falta de empregador, regime, lotação, enquadramento, FAP ou alíquota levanta exceção; cadastro incoerente também.
  - `run_payroll_employee(folha, contrato, dependentes, filhos)`: conta da sessão, folha travada e em `draft`/`calculating`, um resultado por contrato (índice único), encargos gravados (antes nulos), pendências na memória de cálculo. PJ é recusado.
  - Cadastro: `payroll_run.data_pagamento`, `tax_allocation_detail.aliquota_terceiros`, `folha.request_context_config`.
  - Tabelas de 2024 e 2025 (INSS, salário mínimo, IRRF de fev/2024 em diante) com o ato no JSON; a tabela do IRRF de mai/2023 a jan/2024 não entrou (ato a validar).
  - Segurança: 12 policies das 0014/0018 recriadas com `(SELECT folha.current_account_id())`; `request_context_account_id()` confere o grupo do principal contra `request_context_config` (hoje NULL = sem restrição; o grupo da Folha não existe no gestao e não foi inventado); ACL das 11 funções revogada de todos e concedida só a worker e data_owner (`run_payroll_employee` só ao worker; auxiliares a ninguém).
- **Removidos:** `tests/folha/run_eventos_vida_tests.py` e o `.pyc` versionado.
- **Assinaturas removidas:** `calc_irrf(numeric, integer, boolean, date)`, a coluna `fgts_multa_rescisoria` de `calc_fgts` e `run_payroll_employee(uuid, uuid)` (a nova aceita os mesmos dois argumentos). Consumidores fora deste repositório não foram verificados.

### Verificado em execução (PostgreSQL 17 + pgTAP em Docker local, banco recriado, roteiro de `tests/ci/replay.sh`)

- 871 asserções aprovadas: 0014: 19; 0022: 25; 0023: 371; 0024: 165; **0025: 207**; dashboard: 12; eventos_vida: 47; golden: 25; mais a corrida do rateio.
- `0025_motor_mensal_dourados`: CD-01 a CD-15 do parecer em centavos, variante truncada do INSS, negativos (categoria não sujeita, falta de empregador/regime/lotação/enquadramento/FAP/terceiros, cadastro incoerente, parâmetro sem vigência, data anterior às tabelas, outra conta, folha fechada), policies, configuração do contexto e ACL.
- `up -> down -> up` da 0025 com a suíte inteira verde depois. O CI não executa o `.down.sql`.
- Revisão independente somente leitura (aritmética e SQL): sem divergência de centavo; achados corrigidos ou listados abaixo.

### `a_validar` (parâmetro ou pendência devolvida)

`inss_arredondamento_metodo`; `terceiros_incide_contribuinte_individual`; `irrf_redutor_referencia_bruto` (só IRRF em separado); pendências `estagio_nao_incidencia_lei_11788`, `inss_ci_retencao_11_em_optante_do_simples`, `fap_em_optante_do_simples_anexo_iv`, `cprb_empresa_integralmente_desonerada`, `irrf_simplificado_pela_fonte_pagadora_ato_rfb`, `salario_familia_documentos_de_elegibilidade`, `salario_familia_divisor_da_fracao_de_dias`. Passaram a `validado` (conferidos no parecer): `irrf_redutor_coef_a` e `irrf_redutor_coef_b`.

### Decisões e divergências (detalhe em `scratch/DIVERGENCIAS-PARECER-FATIA3.md`, fora do git)

1. Parâmetro `a_validar` é usado e o resultado é gravado com a pendência na memória de cálculo; o parecer propõe bloquear. Decisão do dono.
2. O teto de 312,89 da redução passou a valer também no IRRF em separado: rendimento entre cerca de 4.890,00 e 5.000,00 pode reter até R$ 23,78 (antes zero). Depende de o desconto simplificado valer em separado: a validar.
3. Encargos arredondados por contrato e lotação, não sobre a soma das bases da lotação.
4. CD-15 "parâmetro em rascunho": o catálogo não tem esse estado; conferido como parâmetro sem vigência.

### Pendências

- Base ainda é o salário contratual do mês cheio: rubricas, faltas, proporcionalidade, 13º mensal, múltiplos vínculos, pensão e previdência complementar ficam para a fatia 4. Dependentes e filhos entram por argumento.
- `build_esocial_s1200`/`s2200` (0020) tratam contribuinte individual como categoria 101 e somam o salário-família em `vr_salario`.
- Simples concomitante, MEI, imune, pessoa física e órgão público: exceção (sem regra). Tabela de terceiros por FPAS, RAT por CNAE, dispensa de retenção de valor mínimo do IRRF: não implementados.
- Vigências de regime, rateio, FAP e lotação são lidas na data da competência; FAP sem controle anual.
- JSON de FGTS e do redutor na 0015 ficou sem leitor (o motor lê `payroll_parameter`).
- Tabelas de INSS e IRRF de 2026 (0015) seguem com vigência aberta; salário-família de 2026 fecha em 31/12/2026.
- Documentação funcional (vault `DNEX-Documentacao`): não atualizada (vault inacessível neste host). Pendência documental aberta.

### Não verificado

- Produção e Supabase (estado real de `tax_table_version` e `payroll_parameter`, funções órfãs do E-17, quem chama as assinaturas removidas no Hub e em funções de borda).
- Fontes oficiais: os valores foram conferidos contra o parecer, não contra os atos.
- CI do GitHub para este PR (ver o resultado no PR).

---

## Frente 15/11/2026 (noite) — Migration 0024: empregador em quatro níveis e conta da sessão

Branch `feat/folha-empregador-20261115`, PR 3 em rascunho. Nada aplicado em produção.
**Pode ser mesclada como endurecimento; NÃO aplicar em produção** antes da dependência do dnex-gestao abaixo.

### O que entrou

- **Migration 0024** (`migrations/supabase/0024_folha_empregador_parametros.supabase.sql`, reversão em `.down.sql`): sete tabelas com `account_id` (`employer`, `employer_regime`, `establishment`, `establishment_fap`, `tax_allocation`, `tax_allocation_detail`, `contract_tax_allocation`); vigência em duas datas inclusivas, sem sobreposição por constraint de exclusão (`btree_gist`, extensão nova neste repositório); chaves estrangeiras compostas com `account_id` e hierarquia coerente na conta (estabelecimento preso ao empregador em contrato e folha; rateio com contrato e lotação do mesmo empregador); `employer_id`/`establishment_id` anuláveis em `employee`, `employment_contract` e `payroll_run`; RLS com FORCE; ACL que revoga de todo papel antes de conceder (worker lê e grava, data_owner só lê). Nenhum valor normativo semeado.
- **Rateio do contrato:** soma 100 em cada dia coberto, conferida no fim da transação por trigger SECURITY DEFINER sem RLS (não depende do contexto da sessão) e serializada por contrato (duas transações concorrentes não passam com 100 cada).
- **Parâmetros por vigência:** o catálogo é `folha.payroll_parameter` (global) e a leitura é `folha.get_param`, ambos da 0023; a 0024 só acrescenta a constraint de vigências sem sobreposição por chave.
- **Conta da sessão:** `folha.request_context_account_id()` valida o contexto pelo protocolo do `gestao_auth` (`request_context` + asserção consumida + `session_user`/PID/txid + funções de principal e de escopo do próprio gestao). `folha.current_account_id()` deixa de aceitar o parâmetro `folha.account_id`, exceto para o papel de teste `dnex_folha_ci` em banco com o marcador de CI; a migration aborta se o papel existir sem o marcador. A leitura da 0014 (asserção não consumida pelo `assertion_id`) não era o protocolo e foi removida.
- **CI:** `tests/ci/bootstrap.sql` reproduz o protocolo do gestao (tabelas, `begin_request`, validação de principal e de escopo) em vez do stub de cinco colunas; `tests/ci/concorrencia_rateio.sh` roda a corrida com duas conexões; `tests/ci/replay.sh` o chama.
- **Testes:** `0024_empregador_parametros` (165 asserções: isolamento e rateio com o worker pelo protocolo real, cada vínculo do contexto adulterado, reserva de CI, hierarquia, ACL para qualquer papel); `0014_folha_rls_isolation` (19); `0023_eventos_vida_dourados` e `eventos_vida_calculo` rodam como o login de teste do worker, com contexto aberto por `begin_request`.
- **ADR:** `docs/02-decisoes/ADR-empregador-quatro-niveis.md` (proposta; aceite do proprietário pendente).

### Dependências no dnex-gestao (nada foi criado lá)

1. Não existe grupo de principal para a Folha (`api`, `fiscal_worker`, `outbox_worker`, `context_issuer`, `producer`). Nenhum login com acesso às tabelas da Folha abre contexto; depois da 0024 a conta do worker é sempre nula em produção. O grupo `folha_worker` do bootstrap existe só para os testes.
2. Não existe permissão da Folha na lista fechada de `has_permission` (`folha.read`, pedida por `mask_cpf`, devolve falso).
3. Não existe função do gestao que devolva a conta do contexto; a Folha lê as duas tabelas do `gestao_auth` e precisa de acesso a elas para quem aplica a migration.
4. O protocolo do gestao está em preview ("NO-GO para deploy, homologação e produção" no README das migrations do gestao).

### Verificado em execução (PostgreSQL 17 + pgTAP em Docker local, banco recriado, roteiro de `tests/ci/replay.sh`)

- Bootstrap, migrations 0014 a 0024 e os sete arquivos de teste: 660 asserções, todas aprovadas (0014: 19; 0022: 25; 0023: 371; 0024: 165; dashboard: 12; eventos_vida: 47; golden: 21), mais a corrida do rateio com duas conexões em READ COMMITTED e REPEATABLE READ.
- Fora do roteiro do CI, em banco local: os testes falham quando a leitura antiga é reposta, quando o trigger do rateio volta a INVOKER, quando a serialização é retirada e quando a reserva ignora o marcador; a migration aborta com papel de teste sem marcador, sem `gestao_auth.request_context` e com vigências sobrepostas no catálogo; com default ACL hostil no schema `folha` o teste de ACL continua verde; `up → down → up` funciona e a reversão recusa com dados.

### Não verificado

- Produção: forma real do `gestao_auth`; papel que aplica com BYPASSRLS e com acesso ao `gestao_auth`; `btree_gist`; papéis com EXECUTE em `current_account_id()` concedido fora do repositório; chamadores que ainda definam `folha.account_id`.
- Custo de `current_account_id()` nas policies da 0014, que a chamam por linha.
- Documentação funcional no vault `DNEX-Documentacao`: não atualizada (vault inacessível neste host). Pendência documental aberta.

### Próximas fatias

- Grupo e permissão da Folha no gestao; depois, trocar a leitura direta por função do gestao.
- Encargos da empresa por estabelecimento e lotação, lendo estas tabelas e `get_param`.
- Preencher `employer_id`/`establishment_id` nos dados existentes e torná-las obrigatórias.
- Listas oficiais de códigos (natureza jurídica, classificação tributária, tipo de lotação, FPAS, terceiros): a validar na fonte.

---

## Frente 15/11/2026 — Correção do motor de eventos de vida (migration 0023)

Estado: migration e testes fechados contra banco real. Replay local do zero (Postgres 17 + pgTAP em Docker, roteiro
do CI): 6 arquivos, 493 asserções, todas passando (17 + 25 + 371 + 12 + 47 + 21). Nada foi aplicado em produção.
PR 2 segue em rascunho.

### O que mudou

- **Migration 0023** (`migrations/supabase/0023_folha_motor_eventos_vida_correcao.supabase.sql`):
  - `folha.payroll_parameter`: 38 parâmetros normativos por vigência (a partir de 01/01/2026), 15 deles `a_validar`.
    Reaplicar a migration não sobrescreve valor nem validação (`ON CONFLICT DO NOTHING`).
  - Auxiliares: `get_param`, `params_a_validar`, `avos_13o`, `avos_ferias`, `calc_irrf_separado`.
  - `calc_inss`: faixas contínuas (deixou de perder 1 centavo de base por faixa).
  - `calc_13o(contrato, data_pagamento, parcela, ...)`: parcela 1 = adiantamento (metade, sem INSS e IRRF, FGTS no mês);
    2 = quitação (INSS e IRRF em separado sobre o bruto total, adiantamento compensado, FGTS sobre a diferença);
    3 = ajuste de variáveis de janeiro. Avos por mês do ano civil com 15 dias ou mais, sem piso.
  - `calc_ferias(contrato, inicio_gozo, inicio_periodo_aquisitivo, ...)`: escala de faltas, dias de gozo, abono (máximo
    de 1/3), dobra só dos dias gozados depois do concessivo, INSS e FGTS sobre férias gozadas + terço, IRRF em
    separado, líquido e data-limite de pagamento. Recusa período aquisitivo incompleto.
  - `calc_rescisao(contrato, ultimo_dia, motivo, aviso_modo, ...)`: 8 motivos, aviso de 30 + 3 dias por ano (teto 90),
    projeção do aviso nos avos, férias vencidas pelo inventário informado, proporcionais pelo período aquisitivo em
    curso, arts. 479 e 480, limite do art. 477 § 5º, INSS e IRRF do mês e do 13º, depósito do FGTS. A multa do FGTS
    sai em campo próprio (`multa_fgts`), fora dos proventos e do líquido, e só é calculada com a base do extrato.
    Motivo desconhecido ou nulo e regime que não é CLT ou aprendiz levantam exceção.
  - As assinaturas antigas (`calc_ferias(uuid,date)`, `calc_13o(uuid,date,integer)`, `calc_rescisao(uuid,date,text)`)
    são removidas.
  - ACL das 9 funções: `REVOKE ALL FROM PUBLIC, anon, authenticated`; `GRANT EXECUTE` só a `dnex_gestao_folha_worker`
    e `dnex_gestao_data_owner` (os papéis que já executavam pelas 0016 e 0019).
  - Rubricas: férias indenizadas da rescisão sem INSS, IRRF e FGTS; abono sem FGTS; 1ª parcela do 13º sem INSS.
- **Testes**:
  - `tests/folha/0023_eventos_vida_dourados.pgtap.sql`: `plan(371)`. CT-01 a CT-13 e G01 a G12 dos pareceres em
    centavos, G09b, as 4 alternativas de INSS sobre a projeção, 23 negativos, ACL, rubricas e parâmetros.
  - `tests/folha/eventos_vida_calculo.pgtap.sql`: reescrito (`plan(47)`), com valor exato do comportamento correto.
  - `tests/folha/golden_cases_calculo.pgtap.sql`: o `todo` do centavo do INSS virou asserção normal.

### Decisões adotadas (revisáveis pelo dono)

| Decisão | Adotado | Alternativa | Motivo |
|---|---|---|---|
| Fração do avo do 13º | 15 dias ou mais | mais de 15 (Decreto 10.854, art. 78, § 4º) | Lei 4.090/1962; recomendação do parecer |
| Método do INSS | soma das faixas, arredondada no final (A) | truncar por faixa (B) | parecer de rescisão usa A; A VALIDAR |
| Redutor da Lei 15.270 no IRRF em separado | aferido pelo rendimento bruto (`irrf_redutor_referencia_bruto = 1`) | pela base após deduções, como `calc_irrf` | é o que o caso G03 exige; ver `scratch/DIVERGENCIAS-PARECER.md` |
| INSS sobre aviso indenizado | não incide | incide | parecer, item 2.1.8; A VALIDAR |
| INSS do 13º sobre os avos da projeção | incide | não incide (valores alternativos testados) | padrão proposto no parecer; A VALIDAR |
| IRRF sobre abono e sobre a dobra | não retém | retém | parecer, item 2.6; A VALIDAR |
| Divisor do saldo | 30; mês inteiro = 30 | dias reais do mês | convenção dos casos; A VALIDAR |
| Aviso no pedido de demissão | 30 dias | proporcional | padrão do parecer; A VALIDAR |
| Projeção do aviso no acordo | informada pelo responsável; sem ela, erro | padrão automático | parecer: o motor não decide |
| Adiantamento do 13º na rescisão | compensa primeiro o 13º; o excedente entra no limite do art. 477 § 5º | tudo dentro do limite | Decreto 10.854, art. 82, parágrafo único |
| Adiantamento do 13º fora de fevereiro a novembro | calcula e devolve pendência | recusar | não bloquear o pagamento junto com as férias |
| Médias de variáveis | recebidas prontas (`p_remuneracao`, `p_media_variaveis`, `p_soma_variaveis`) | apurar no motor | faltam tabelas de lançamentos |

### Pendências "A VALIDAR NA FONTE"

Em `folha.payroll_parameter` com `status_validacao = 'a_validar'` (as funções devolvem `a_validar:<chave>` quando usam):
`divisor_variaveis_quitacao`, `divisor_variaveis_ajuste`, `ferias_fracionamento_max_periodos`,
`ferias_fracionamento_minimo_1`, `ferias_fracionamento_minimo_2`, `irrf_abono_pecuniario_incide`,
`irrf_dobra_ferias_incide`, `irrf_redutor_referencia_bruto`, `irrf_redutor_coef_a`, `irrf_redutor_coef_b`,
`aviso_previo_dias_por_ano`, `prazo_pagamento_rescisao_dias`, `divisor_saldo_salario`,
`inss_aviso_indenizado_incide`, `inss_projecao_aviso_incide`.

Fora da tabela, ainda sem validação:
- Tabelas de INSS e IRRF de 2026 do seed 0015 (portaria e Receita) e método de arredondamento do INSS e do FGTS.
- Redutor da Lei 15.270/2025: critério (bruto ou base), alcance no 13º, aferição nas férias em separado.
- Avos do 13º e período aquisitivo em afastamentos, licença-maternidade e faltas injustificadas.
- Divisor da média de variáveis no adiantamento; critério de médias (valor ou quantidade) e CCT/ACT.
- Dia não útil no prazo do art. 145 da CLT; contagem do prazo do art. 477, § 6º; FGTS rescisório (FGTS Digital).
- Extinção antecipada do contrato de aprendizagem (arts. 479 e 480): o motor calcula e devolve pendência.

### Pendências de engenharia

- **Consumidores das assinaturas antigas não verificados** (dnex-hub, funções de borda, outros repositórios): quem
  chama `calc_ferias(uuid,date)`, `calc_13o(uuid,date,integer)` ou `calc_rescisao(uuid,date,text)` quebra ao aplicar
  a 0023. Conferir antes de aplicar em produção.
- O script Python de testes dos eventos de vida, obsoleto, foi removido na fatia 3 (migration 0025).
- `calc_irrf` (folha mensal): corrigido na fatia 3 (migration 0025); mensal e separado usam a mesma apuração.
- Parâmetros e tabelas só existem a partir de 01/01/2026: cálculo com data anterior levanta erro.
- IRRF das férias usa a data de início do gozo como competência (o pagamento ocorre antes; regime de caixa a tratar).
- Projeção do aviso que atravessa o ano: o 13º soma os avos dos dois anos, com pendência (falta separar por ano).
- Férias: sem validação do fracionamento (14 e 5 dias, até 3 períodos) nem controle de saldo entre gozos; devolve pendência.
- Rescisão: sem rendimentos já pagos no mês, médias, faltas no saldo, aviso misto, multa do art. 477, § 8º, rescisão
  indireta e culpa recíproca. Contrato a prazo com cláusula assecuratória: usar `sem_justa_causa` ou `pedido_demissao`.
- Sem tabelas de período aquisitivo, gozo, adiantamento de 13º e evento de rescisão: os dados entram por parâmetro e
  nada é persistido nem gravado em `calculation_trace`.
- Entradas monetárias negativas (`p_remuneracao`, variáveis) não são recusadas.
- Contabilização (parecer próprio, casos GC-01 a GC-08): fora desta entrega.
- **Documentação funcional** (vault `DNEX-Documentacao`): não atualizada nesta frente; a tarefa era restrita a esta
  worktree. Pendência documental aberta: módulo Folha, funções de 13º, férias e rescisão.
- Segunda conferência independente dos casos dourados por profissional de DP (os pareceres pedem) ainda não feita.

### Verificação

- Feito: replay do zero em banco local descartável; reaplicação da 0023 sobre banco já migrado; revisão de código
  independente (somente leitura), com os achados corrigidos ou listados acima.
- Não feito: execução em produção ou no Supabase; teste das telas; validação das fontes normativas.

### Migrations anteriores (0014–0022)

Inalteradas.

---

## Frente anterior — CI de replay e pgTAP (mantida)

Ver histórico em `_arquivo/limpeza-20261010/` e commits anteriores. Migration 0022, bootstrap CI, script de replay, teste ACL 0022 e workflow ci-db.yml permanecem válidos.
