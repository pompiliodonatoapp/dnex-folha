# DNEX Folha — Status do Repositório

## Frente 15/11/2026 (fatia 2b + Portal) — Migrations 0028 (contexto do gestao) e 0029 (banco do Portal v1)

Branch `feat/folha-contexto-portal-20261115`, PR em rascunho. Nada aplicado em produção nem no Supabase.
**Não aplicar em produção**: depende do schema `gestao_folha` (dnex-gestao, PR 144, candidata) e dos bloqueios abaixo.
Decisão: `docs/02-decisoes/ADR-contexto-autorizacao-gestao.md` (proposta; aceite do proprietário pendente). Nomes finais para o Portal: `docs/CONTRATO-PORTAL.md`.

### O que entrou

- **0028:** a conta da sessão vem de `gestao_folha.require_folha_context_v1` (claim da Folha), por `folha.contexto_v1`; contexto `api` sem claim não recebe conta. Sessão de aplicação = login membro só de `dnex_gestao_api`, sem GRANT em tabela, operando por onze funções `folha.*_v1` (abrir, calcular contrato, concluir, liberar pendência, aprovar, fechar, cancelar, transmitir, segregação, dashboard, contexto), cada uma com a sua permissão. `dnex_gestao_folha_worker` deixa de ser caminho de sessão (NOLOGIN, titular dos GRANTs antigos). Subject do contexto gravado no cálculo, na liberação, na aprovação, no fechamento e na auditoria (por gatilho em folha e resultado). Segregação mínima opcional por conta, desligada por padrão. Despacho e geradores exigem `folha.transmit` e filtram pela conta. Lista de grupos `{api}`. `search_path` de todas as funções do schema que o fixam terminado em `pg_temp`.
- **0029:** quatro tabelas do Portal, schema `portal_api` com as quatro funções do empregado (papel `authenticated`, `auth.uid()`), seis funções do escritório (`folha.portal_*_v1`). Publicação só de folha fechada, sem pendência, com resultado do trabalhador e tipo de processo compatível; caminho do arquivo preso a conta e trabalhador; documento imutável (só `publicado → retirado`).
- **CI:** bootstrap reproduz o núcleo `gestao_auth` e inclui a candidata do gestao byte a byte (SHA-256 conferido); `replay.sh` executa o ciclo up, down, up das migrations 0028 em diante.

### Bloqueios de produção (novos ou mantidos)

0. **Falha de segurança no dnex-gestao (não corrigida, fora deste repositório):** as funções SECURITY DEFINER de `gestao_auth` têm `search_path` sem `pg_temp` no fim. Provado em teste local: com SQL livre no login de aplicação e uma asserção legítima de `folha.read`, troca-se de conta e ganham-se todas as permissões. A 0028 recusa aplicar enquanto isso existir (pré-condição 0.3.1); o bootstrap de CI corrige as cópias, como diferença declarada. Ver ADR.
1. **Dono das funções sem EXECUTE em `require_folha_context_v1`**: a candidata do gestao só concede a `dnex_gestao_api`. Exige mudança no dnex-gestao (ADR, "Dono das funções"). No CI o dono é superusuário e isso não é exercido.
2. **A sessão de aplicação não cadastra nem lê**: não há `_v1` para trabalhador, contrato, empregador, rubricas, lançamentos, nem leitura de folha, resultado e pendências. Fica para a fatia das telas.
2.1. **Não existem o emissor da claim no Console, as rotas do Hub nem o login dedicado** (outros repositórios). Aplicar a 0028 sem eles deixa toda sessão sem conta, inclusive o caminho atual do Hub.
3. **Entidade legal e filial do contexto não restringem** (só vão para a auditoria). Decisão do dono.
4. **Funções criadas fora do repositório** (citadas na 0022: `build_esocial_s1210/s1299/s2299`, `build_reinf_r2010/r4010`, `dispatch_folha_completa(uuid, date)`) seguem, em produção, executáveis por `service_role` e pelo worker, sem contexto e sem filtro de conta.
5. Portal: expor `portal_api` na API, bucket de armazenamento, prazo padrão de acesso e conferência de `auth.uid()` em produção são decisões e verificações pendentes (`docs/CONTRATO-PORTAL.md`, seção 6).
6. Rotinas sem usuário não têm contexto (a claim só existe para subject `user`).
7. Os bloqueios 3 a 5 da fatia 4 (abaixo) continuam. O bloqueio 1 de lá (autenticação pelo gestao) passa a ser os itens 0, 1 e 2.1 acima. O bloqueio 2 de lá (identidade em texto livre) e o 6 (despacho sem filtro de conta) foram fechados aqui para as funções deste repositório; o 7, em parte (reversão no CI).

### Verificado em execução (PostgreSQL 17 + pgTAP em Docker local, banco recriado, `tests/ci/replay.sh`)

- 1.596 asserções em 11 arquivos, todas verdes: 0014 (19), 0022 (25), 0023 (371), 0024 (165), 0025 (207), 0026 (351), **0028 (184)**, **0029 (190)**, dashboard (12), eventos de vida (47), dourados (25). Os nove anteriores somam as mesmas 1.222.
- Ciclo down 0029, down 0028, up 0028, up 0029 e os dois arquivos novos de novo: verde. `pg_dump -s` depois das duas reversões é idêntico ao de um banco só até a 0027 (fora a linha de token do próprio pg_dump; conferido antes das correções da segunda rodada, que não mexeram nas reversões).
- Lote: abrir + calcular 200 contratos + concluir num único pedido: 1,6 a 2,9 s (8 a 15 ms por contrato), contra 60 s da asserção. Cenário sintético (ver ADR).

### Arquivos de teste anteriores tocados

Nenhum valor esperado de cálculo mudou e a quantidade de asserções de cada arquivo é a mesma. Mudou:

- **Apoio (0023, 0024, 0025, 0026, eventos de vida):** a asserção passa a ser emitida com claim da Folha pelo caminho real; o login de teste (membro só de `dnex_gestao_api`) recebe, dentro da transação, o espelho dos GRANTs do worker, desfeito em volta das conferências de ACL.
- **Três esperados que não são de cálculo:** 0024, `session_user/current_user` do apoio (`…/dnex_gestao_folha_worker` → `…/dnex_folha_ci_login`: o login não assume mais o papel do worker); 0024, `search_path` de `validar_rateio_contrato` (ganhou `, pg_temp`); 0025, contagem de policies do schema (31 → 35: uma da 0028 e três da 0029).
- **Fixtures com o mesmo esperado:** 0024, asserção "de grupo que não é o do login" e adulteração de grupo passam a usar `fiscal_worker` (o login agora é do grupo `api`), e a de escopo inativo passa a ser `user/api/finance.read` gravada direto, sem claim (o caso que discrimina cada vínculo da claim está no arquivo 0028); 0025, lista de grupos do cenário usa `api` no lugar de `folha_worker`.
- Efeito colateral: a asserção dos arquivos antigos vale 55 s (o gestao recusa mais de 60), antes 4 minutos. O mais lento leva cerca de 4 s aqui.

### Revisões independentes

Duas, somente leitura (segurança/SQL; aderência aos contratos), em duas rodadas; a segunda foi sobre a versão corrigida da primeira. Primeira: crítico de `search_path` sem `pg_temp` (código do chamador rodando como dono), corrigido nas funções da Folha. Segunda: o mesmo defeito nas funções do `gestao_auth` (bloqueio 0, não corrigível daqui), o teste da isca que passava com o defeito presente (refeito, com âncora), pós-voo de `search_path` frouxo, corrida na janela de 60 s do registro de acesso, dois holerites da mesma folha (com e sem contrato), histórico contábil dependente de `DateStyle`, teste 6 do Portal que não provava o que dizia, e correções de texto nos documentos. **As correções da segunda rodada não passaram por uma terceira revisão.** O que ficou sem correção está nos bloqueios acima e nos dois documentos.

### Não verificado

- Produção e Supabase: nada foi lido nem aplicado. Não se sabe se o papel que aplica tem BYPASSRLS, se PUBLIC tem TEMP no banco, o default ACL, nem a definição real de `auth.uid()`.
- Dono não superusuário (toda a suíte roda com dono superusuário).
- PostgREST de verdade; concorrência em duas conexões para publicar, habilitar e aceitar.
- Igualdade do insumo `0015_folha_context_candidate.sql` com o PR 144 (conferido só contra o commit `b0b98b1` da worktree do gestao).
- Hub e API do Portal contra este banco.
- **Pendência documental:** o vault `DNEX-Documentacao` não foi atualizado (a branch não está mesclada e a tarefa restringia a escrita a esta worktree).

## Frente 15/11/2026 (fatia 4) — Migrations 0026 e 0027: rubricas, bases, camadas, tipos de processo e trava

Branch `feat/folha-rubricas-processos-20261115`, PR em rascunho. Nada aplicado em produção nem no Supabase.
**Não aplicar em produção** sem a dependência do dnex-gestao da 0024 e sem decidir o que está `a_validar`.
Decisão registrada em `docs/02-decisoes/ADR-rubricas-bases-camadas.md` (proposta; aceite do proprietário pendente).

### Segunda rodada de revisão (15/11, mesma PR) — fechado nas próprias 0026/0027

- **Trava:** folha só nasce em `draft`; `draft -> calculated` exige resultado e totais iguais à soma dos resultados (também por UPDATE direto); data de pagamento congelada depois do cálculo; liberação por tipo (`a_validar` e `conferencia` liberáveis com motivo; `pendencia` de cálculo NÃO é liberável: corrige, cancela e recalcula); `dispatch_folha_completa` só despacha folha fechada e sem pendência aberta.
- **Cálculo:** lançamento já pago por folha não cancelada não é pago de novo nem alterado; férias contam pelo período de gozo em qualquer competência; adiantamento já nasce com pendência `a_validar` e é recusado depois da mensal; tabela do IRRF de 2026 fechada em 31/12/2026; `rubric_incidence.status_validacao` (8 incidências globais `a_validar`, que viram pendência quando usadas); `FERIAS_VENCIDAS`/`FERIAS_PROPORCIONAL` inativas; afastamento = dias de contrato menos dias afastados, limitado a 30; mensal com base zero gera pendência.
- **Menores:** limite de tamanho da fórmula; base de conta não repete código de base global; mensagens que não revelam uuid alheio; pré-checks da 0026 listam os códigos em conflito.
- **Decisão a confirmar:** criei o tipo `conferencia` (liberável) para avisos das funções da 0023 que não indicam valor errado (ex.: INSS provisório do recibo de férias, devolvido sempre por `calc_ferias`, e base zero). Sem ele nenhuma folha de férias fecharia. Lista em `folha.pendencia_tipo`; código não classificado cai em `pendencia`.
- **Fixtures em testes anteriores (esperados inalterados):** 0023 ganha também tabela fictícia de IRRF de 2027; 0025 cria a folha "fechada" do cenário como superusuário com gatilhos desligados (folha não nasce mais fechada).

### Bloqueios de produção restantes

1. Autenticação pelo dnex-gestao (grupo e permissão da Folha) — dependência da 0024.
2. **Identidade de quem libera, aprova e fecha é texto livre** informado por quem chama; só a sessão do worker é gravada. Bloqueio até a Folha receber o subject do contexto do gestao (próxima migration).
3. Valores que o motor sabe que estão errados e marca como pendência não liberável (a folha não fecha): salário e INSS do mês de gozo, adiantamento não descontado na rescisão, pensão fora da base do IRRF, outros vínculos em 13º/férias/rescisão, contribuinte individual com outras fontes, 13º sem 1ª parcela localizada, folha sem data de pagamento.
4. Tudo que está `a_validar` (parâmetros, incidências, códigos do eSocial).
5. Produção tem 80 linhas em `folha.earning_deduction_code` contra 40 semeadas aqui: a 0026 aborta listando os códigos em conflito; a limpeza é decisão do dono, fora desta PR.
6. `dispatch_folha_completa` e os geradores da 0020 não filtram a conta e estão fora do leiaute (a refazer na fatia do eSocial).
7. Reversões (`.down.sql`) fora do CI; corrida real entre processos do mesmo contrato sem teste de concorrência.

### O que entrou

- **0026 (estrutura):** base de cálculo como entidade e ligação N:N com a rubrica; incidência por tributo como código, com vigência; rubrica com tipo, forma de cálculo e ordem; três camadas de regra (empresa, convenção, contrato) com precedência em tabela; convenção ligada ao contrato; lançamentos do período, afastamentos e remuneração de outros vínculos; folha com tipo de processo e sequência (várias por competência); itens, bases e pendências do resultado como dado; camada da regra na memória de cálculo; 40 rubricas da 0017 migradas e 12 rubricas dos processos; tabelas de INSS e salário mínimo de 2026 fechadas em 31/12/2026; RLS com FORCE e ACL em 15 tabelas.
- **0027 (motor):** `run_payroll_employee` (mesma assinatura) calcula por rubricas e despacha pelo tipo: mensal, adiantamento, complementar, 13º 1ª e 2ª parcela, férias e rescisão (os três últimos pelas funções da 0023, agora com itens por rubrica); proporcionalidade por dias; INSS com outros vínculos; fórmula restrita em JSON; `calc_irrf_separado_apurar` com pendência própria; exceção para remuneração nula ou negativa em INSS, FGTS e IRRF; trava de fechamento (pendência sem liberação impede aprovar e fechar; estados só para a frente; data de pagamento obrigatória para fechar e não anterior à competência, salvo férias); `payroll_run_concluir_calculo`, `payroll_pendencias_liberar`, `payroll_run_aprovar`, `payroll_run_fechar`.
- **Mudanças que quebram quem dependia do comportamento antigo:** unicidade de `payroll_run` (deixa de ser conta + competência); competência tem de ser dia 1; o worker perde o INSERT direto em `payroll_result` e `calculation_trace`; rubrica de conta não repete código de rubrica global; `calc_inss`, `calc_fgts` e `calc_irrf_separado` levantam erro com valor nulo ou negativo. Consumidores fora deste repositório não foram verificados.

### Verificado em execução (PostgreSQL 17 + pgTAP em Docker local, banco recriado, roteiro de `tests/ci/replay.sh`)

- 1.222 asserções aprovadas: 0014: 19; 0022: 25; 0023: 371; 0024: 165; 0025: 207; **0026: 351**; dashboard: 12; eventos_vida: 47; golden: 25; mais a corrida do rateio.
- `0026_rubricas_processos`: CD-01, CD-03 e CD-06, CT-01, CT-02, CT-08 e G01 dos pareceres pelo fluxo da folha; casos derivados com a memória no comentário (mensal completa com hora extra por fórmula, falta e desconto fixo; precedência das camadas; quantidade x valor; percentual sobre base; proporcionalidade; adiantamento, mensal e complementar; múltiplos vínculos; dezembro pago em janeiro); trava; vigência sem tabela; exceções; RLS, chaves compostas e ACL.
- `up -> down -> up` das duas migrations com a suíte inteira verde depois. O CI não executa os `.down.sql`.
- Testes falham quando a precedência é invertida, a trava é desligada, a vigência é reaberta ou a incidência de uma rubrica muda (conferido à mão, fora do CI).
- Revisão independente somente leitura (DP e SQL/segurança): sem divergência aritmética; 1 achado bloqueante e 13 importantes corrigidos e cobertos por teste. Segunda rodada dos revisores feita sobre essa versão (sem divergência aritmética); os achados dela estão na seção acima. **A versão que os corrige não foi revista de novo.**

### Arquivos de teste anteriores tocados (detalhe em `scratch/DIVERGENCIAS-FATIA4.md`, fora do git)

- `0023_eventos_vida_dourados`: fixture com tabela fictícia de INSS de 2027 (cópia da de 2026) para o CT-07, pago em 08/01/2027; valores esperados inalterados.
- `0025_motor_mensal_dourados`: contagem de policies de 19 para 31.

### `a_validar` e pendências novas devolvidas pelo motor

`divisor_saldo_salario` (proporcionalidade); `proporcionalidade_por_afastamento_criterio_de_dias`; `inss_multiplos_vinculos_criterio_de_deducao_das_outras_fontes`; `irrf_separado_reducao_lei_15270_alcance_e_teto`; `irrf_separado_desconto_simplificado_nao_aplicado`; `irrf_complementar_soma_dos_pagamentos_do_mes` e `..._pago_em_outro_mes_calculado_em_separado`; `irrf_adiantamento_pago_em_mes_diferente_do_saldo`; `irrf_ferias_apurado_pela_data_de_inicio_do_gozo_e_nao_pela_de_pagamento`; `irrf_rescisao_apurado_pela_data_do_desligamento_e_nao_pela_de_pagamento`. Pendências de cálculo: desligamento no mês, férias na competência, adiantamento não descontado na rescisão, adiantamento do 13º não localizado, outros vínculos não considerados em 13º, férias e rescisão, contribuinte individual com outras fontes, pensão não deduzida do IRRF, líquido negativo. Códigos de incidência e natureza do eSocial: não semeados.

### Pendências

- Não implementado: reapuração do salário e do INSS no mês de gozo; desconto do adiantamento na rescisão; dedução de pensão e previdência complementar; médias apuradas pelo motor (bases de médias, 13º e férias existem sem rubrica ligada); reflexo em DSR; 13º parcela de ajuste e férias em dois meses pelo fluxo; mais de um contrato do mesmo trabalhador na conta; versão das regras usadas em folha fechada; FKs compostas em `rule_id`/`entry_id` dos itens e em `payroll_result`.
- Incidências de aviso indenizado, abono e dobra ficam fixas no catálogo enquanto o motor decide por parâmetro `a_validar` (duas fontes).
- Parâmetros da redução do IRRF (`payroll_parameter`) seguem com vigência aberta; a tabela do IRRF de 2026 fecha em 31/12/2026.
- Documentação funcional (vault `DNEX-Documentacao`): não atualizada (vault inacessível neste host). Pendência documental aberta.

### Não verificado

- Produção e Supabase; aplicação sobre dados reais (rubricas de conta com código de global, folhas com competência fora do dia 1 e `is_global` incoerente abortam a 0026 por pré-condição).
- Fontes oficiais: valores conferidos contra os pareceres, não contra os atos.
- Corrida real em duas sessões entre processos do mesmo contrato (a fila por contrato não tem teste de concorrência).
- CI do GitHub para este PR (ver o resultado no PR).

---

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
