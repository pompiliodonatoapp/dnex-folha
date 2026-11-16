# ADR — Contexto de autorização da Folha pela claim do dnex-gestao

Data: 15/11/2026. Estado: **proposta implementada em migration (0028), não aplicada em nenhum ambiente**; aceite do proprietário pendente. Contrato de origem: dnex-gestao, `docs/01-arquitetura/FOLHA-CONTEXTO-AUTORIZACAO.md` e `migrations/0015_folha_context_candidate.sql` (PR 144; candidata).

## Problema

Até a 0027, `folha.request_context_account_id()` devolvia a conta de **qualquer** contexto válido do grupo `api`: um contexto financeiro comum, sem direito à Folha, recebia a conta. A identidade de quem liberava pendência, aprovava e fechava era texto digitado. Os geradores e o despacho (0018, 0020) eram SECURITY DEFINER sem filtro de conta.

O contrato do gestao oferece `gestao_folha.require_folha_context_v1(permissão)`, que devolve conta, entidade legal, filial e subject só quando a asserção consumida pela transação tem claim da Folha com a permissão pedida. Duas restrições moldam o desenho:

1. o EXECUTE dessa função é só de `dnex_gestao_api`, e a sessão precisa ser um LOGIN cuja closure de memberships é exatamente `{dnex_gestao_api}`;
2. as policies de RLS da Folha chamam `folha.current_account_id()` em todo comando, com qualquer papel.

## Decisão

**Leitura do contexto.** `folha.contexto_v1(permissão)` é a única função da Folha que chama `require_folha_context_v1`. É SECURITY DEFINER, interna (ninguém além do dono executa), devolve conta, entidade legal, filial e subject, e levanta 42501 quando o contexto não serve. `folha.request_context_account_id()` passa a ser `contexto_v1('folha.read')`, com NULL em 42501; as policies continuam chamando `current_account_id()` sem saber de permissão. A Folha deixa de ler `gestao_auth.request_context` e `gestao_auth.access_assertion`.

**Quem executa o quê.**

| Papel | Antes (0027) | Depois (0028) |
|---|---|---|
| Login da aplicação | membro de `dnex_gestao_folha_worker`; lia e gravava as tabelas sob RLS | membro só de `dnex_gestao_api`; **não** tem GRANT em tabela da Folha; executa só `folha.*_v1` |
| `dnex_gestao_folha_worker` | papel da sessão | NOLOGIN, titular dos GRANTs de tabela e função das 0014 a 0027 (nenhum revogado). Login que seja membro dele não abre contexto: deixou de ser caminho de sessão |
| `dnex_gestao_data_owner` | leitura | inalterado |
| `service_role` | executava `dispatch_folha_completa(uuid)` | perdeu esse EXECUTE (sem contexto não há despacho) |
| `authenticated` | nada na Folha (fora `mask_cpf`) | quatro funções do schema `portal_api` (0029) |

Funções da sessão de aplicação (EXECUTE só para `dnex_gestao_api`; as que gravam conferem a permissão no início e antes de devolver; as de leitura, uma vez):

| Permissão | Funções |
|---|---|
| `folha.read` | `contexto_atual_v1`, `dashboard_v1`, `portal_relatorio_visualizacao_v1`; a conta da sessão (RLS) |
| `folha.calculate` | `folha_abrir_v1`, `folha_calcular_contrato_v1`, `folha_concluir_calculo_v1` |
| `folha.close` | `folha_liberar_pendencia_v1`, `folha_aprovar_v1`, `folha_fechar_v1`, `folha_cancelar_v1` |
| `folha.transmit` | `folha_transmitir_v1`, `portal_documento_publicar_v1`, `portal_documento_retirar_v1` |
| `folha.admin` | `segregacao_definir_v1`, `portal_acesso_habilitar_v1`, `portal_acesso_revogar_v1`, `portal_acesso_definir_prazo_v1` |

As funções das 0018 a 0027 (`run_payroll_employee`, `payroll_run_*`, `payroll_pendencias_liberar`, `dispatch_*`, `build_*`) mantêm assinatura, dono e ACL, e passam a conferir a mesma permissão por dentro: quem as alcançasse com os privilégios do worker precisaria da permissão do mesmo jeito.

**Identidade.** O subject do contexto é gravado em `payroll_result.calculado_por_subject`, `payroll_run.calculado_por_subject`, `aprovado_por_subject`, `fechado_por_subject`, `payroll_pendency.liberada_por_subject` e `auditoria.actor_subject` (com entidade legal e filial no detalhe). Em `payroll_run` e `payroll_result` quem grava é um gatilho, então vale também para UPDATE e INSERT diretos, e o valor informado por quem grava é ignorado. `approved_by` e `liberada_por` (texto) ficam como rótulo; as funções `_v1` gravam neles o próprio subject.

**Segregação mínima.** `folha.segregation_config`, por conta, desligada por padrão (sem linha). Ligada por `segregacao_definir_v1(true)` (`folha.admin`): o subject que calculou algum resultado da folha, ou que concluiu o cálculo, não libera pendência, não aprova e não fecha. Folha calculada sem subject (antes da 0028) é recusada enquanto a segregação estiver ligada: cancele e recalcule. Limite conhecido: quem acumula `folha.admin`, `folha.calculate` e `folha.close` pode desligar, fechar e religar; fica na auditoria, não é impedido.

**Grupos do principal.** `folha.request_context_config.principal_groups_permitidos` deixa de ser NULL e passa a `{api}`. A barreira é a claim; a lista vira chave geral: vazia ou sem a linha, a Folha fica sem contexto.

**search_path.** Toda função do schema `folha` que fixa `search_path` passa a terminar em `pg_temp` (ver "Achado da revisão").

## Dono das funções (pendência que trava a produção)

`contexto_v1` roda como o dono, que precisa de EXECUTE em `require_folha_context_v1`. A candidata 0015 concede esse EXECUTE **só** a `dnex_gestao_api`, e o pós-voo dela aborta se houver outro grantee. No CI o dono é superusuário e a ACL não é exercida. A pré-condição 0.3 da 0028 aborta limpo se o dono não tiver o EXECUTE. Saídas:

1. **(recomendada) mudar a candidata do gestao:** conceder `require_folha_context_v1` a um papel NOLOGIN dono das funções da Folha e incluí-lo no pós-voo, como a 0012 fez com as ordens de serviço; na Folha, transferir a propriedade das funções para esse papel e testar com dono não superusuário.
2. tornar o papel que aplica a 0028 membro de `dnex_gestao_api`: funciona tecnicamente, mas esse papel é LOGIN e os preflights do gestao recusam login sensível com closure diferente da estrita.

Não foi resolvido aqui porque exige alterar o dnex-gestao.

## Limite de 60 segundos

A asserção vale no máximo 60 s, e isso limita a transação. Medido no teste (`tests/folha/0028_contexto_gestao.pgtap.sql`, seção 9; PostgreSQL 17 em Docker local): abrir uma folha, calcular 200 contratos e concluir, num único pedido, levou de 1,6 a 2,9 s nas execuções desta frente e das revisões (8 a 15 ms por contrato). O cenário é sintético: um contrato por empregador, Simples, folha mensal, sem lançamentos nem histórico. Vale como ordem de grandeza, não como garantia para 13º, férias ou rescisão com histórico, nem para o hardware de produção.

Desenho para quando não couber (não implementado; não altera o gestao): o Hub divide o lote em pedidos, cada um com a sua asserção e a sua transação (`folha_calcular_contrato_v1` para N contratos), e conclui a folha num pedido final. O motor já admite isso: a folha fica em `draft` entre os pedidos, cada resultado é independente e há um resultado por contrato e folha. Se a asserção vencer no meio de um pedido, a conferência final da função falha e só aquele lote é desfeito.

## Achado da revisão: search_path sem pg_temp (fechado na Folha, ABERTO no dnex-gestao)

A revisão de segurança provou que, com `SET search_path = pg_catalog` (sem `pg_temp` no fim), quem tivesse SQL livre com o login de aplicação criava `pg_temp.uuid` como domínio com CHECK e fazia código seu rodar como o dono de qualquer função SECURITY DEFINER com variável `uuid`, sem contexto algum, lendo dados de outra conta. O mesmo padrão existia nas migrations 0014 a 0027. A 0028 corrige as funções novas e altera o `search_path` de todas as anteriores do schema; o pós-voo falha se alguma SECURITY DEFINER não começar por `pg_catalog` e terminar em `pg_temp`; o teste reproduz a tentativa (com âncora numa função propositalmente vulnerável).

**O mesmo defeito existe no dnex-gestao e não se corrige daqui.** As funções SECURITY DEFINER de `gestao_auth` (`has_permission`, `begin_request` e as demais; previews 0006 e 0007 e `main` local `de87a55`) têm `search_path = pg_catalog, gestao_auth`, sem `pg_temp`. A segunda rodada de revisão provou, no banco de teste: com uma asserção legítima só de `folha.read` na conta A, o login de aplicação criou `pg_temp.text` como domínio, chamou `has_permission`, executou código como `dnex_gestao_auth_owner`, reescreveu a própria asserção e a claim (conta B, as cinco permissões) e abriu folha na conta B. Exige SQL livre com o login de aplicação e privilégio TEMP no banco; atinge também o financeiro do Gestão, não só a Folha.

Consequências nesta entrega: a 0028 **recusa aplicar** enquanto alguma função SECURITY DEFINER de `gestao_auth` ou `gestao_folha` executável por `dnex_gestao_api` não terminar o `search_path` em `pg_temp` (pré-condição 0.3.1); o bootstrap de CI acrescenta `pg_temp` às cópias dessas funções, como diferença declarada (i), para a suíte poder rodar. A correção de verdade é no dnex-gestao e não foi feita nem pedida lá por esta frente.

## Divergências e lacunas em relação ao contrato do gestao

| Ponto | Situação |
|---|---|
| EXECUTE de `require_folha_context_v1` para o dono das funções | não previsto na candidata; ver acima |
| Cobertura das `_v1` | não há função para cadastrar (trabalhador, contrato, empregador, regime, estabelecimento, lotação, rubricas, lançamentos, data de pagamento) nem para ler folha, resultado e pendências. A sessão de aplicação ainda não opera a Folha de ponta a ponta. Fica para a fatia das telas |
| Entidade legal e filial | devolvidas pelo contexto e gravadas só na auditoria. Não restringem: um contexto emitido para uma filial opera todos os empregadores da conta. Mapear para empregador e estabelecimento é decisão do dono, em aberto |
| Rotinas sem usuário | não atendidas (a claim só existe para subject `user`). Publicação "por rotina" e "por parâmetro" no Portal exige usuário no pedido |
| Reabrir competência (`folha.close` no contrato) | não existe: a 0027 torna `closed` terminal |
| Permissões além do texto do contrato | proposta da Folha: liberar pendência, aprovar e cancelar sob `folha.close`; habilitação do Portal sob `folha.admin`; publicar e retirar documento sob `folha.transmit` |
| Emissor no Console, rotas do Hub e login dedicado | **não existem** (são de outros repositórios: função de autoridade no Console com entitlement `folha`, rotas do Hub em `begin_request` + `folha.*_v1`, LOGIN dedicado membro só de `dnex_gestao_api`). Aplicar a 0028 sem eles deixa toda sessão sem conta, inclusive o caminho atual do Hub |
| Cancelar e recalcular | `folha_cancelar_v1` cancela; a folha cancelada continua ocupando a chave (conta, empregador, competência, tipo, sequência): a nova folha precisa de outra sequência |
| `finance.read` | o contexto da Folha passa em `has_permission('finance.read')` do mesmo escopo. Aceito "por enquanto" pelo dono em 15/11/2026, segundo a instrução desta frente; não há outro registro escrito da decisão neste repositório. O teste registra o fato |
| Funções criadas fora deste repositório (0022: `build_esocial_s1210/s1299/s2299`, `build_reinf_r2010/r4010`, `dispatch_folha_completa(uuid, date)`) | não são tocadas. Em produção seguem executáveis por `service_role` e pelo worker, sem contexto e sem filtro de conta. Medir e reescrever ou revogar antes de aplicar. Se alguma for SECURITY DEFINER com `search_path` que a 0028 não sabe tratar, a 0028 aborta (falha fechada) |
| `folha.dashboard_completo(uuid)` | recebe a conta por parâmetro e segue executável pelo worker (o teste da 0022 exige). Nenhuma sessão é worker; `dashboard_v1` é o caminho |
| `folha.mask_cpf` | continua consultando `gestao_auth.has_permission('folha.read')`, que não conhece permissão da Folha: mascara sempre |

## CI

`tests/ci/bootstrap.sql` reproduz o núcleo `gestao_auth` e inclui, byte a byte, a candidata 0015 (`tests/ci/gestao_folha_0015_candidate.sql`, SHA-256 conferido por `replay.sh`). O grupo `folha_worker` e a permissão `folha.ci`, que só existiam no bootstrap, foram removidos. O login de teste é membro só de `dnex_gestao_api`; para os testes anteriores continuarem a ler e gravar as tabelas, ele recebe, dentro da transação do teste, o espelho dos GRANTs do worker, desfeito antes das conferências de ACL. Os testes da 0028 e da 0029 rodam sem o espelho, como a sessão de produção. `replay.sh` passou a executar o ciclo up, down, up das migrations 0028 em diante.

## Alternativas descartadas

- **Conceder as tabelas a `dnex_gestao_api`:** a RLS viraria a única barreira para toda sessão do Gestão (o contrato desaconselha).
- **Grupo próprio no núcleo do gestao (opção A do plano):** exige novo corte do catálogo e quiescência; fica para quando houver decisão de segregação de funções.
- **Permissão conferida só nas funções:** UPDATE direto forjaria a identidade; por isso o gatilho.
