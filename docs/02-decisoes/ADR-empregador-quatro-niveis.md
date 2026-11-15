# ADR: empregador em quatro níveis e conta da sessão

- **Status:** proposta (aceite do proprietário pendente). Pode ser mesclada como endurecimento; **não aplicar em produção** antes de resolver a dependência do dnex-gestao descrita em "Dependências".
- **Data:** 2026-11-15
- **Migration:** `migrations/supabase/0024_folha_empregador_parametros.supabase.sql` (reversão em `.down.sql`)
- **Testes:** `tests/folha/0024_empregador_parametros.pgtap.sql`, `tests/ci/concorrencia_rateio.sh`

## Contexto

O DNEX Folha só conhecia a conta do Hub (`account_id`). Não havia onde gravar inscrição do empregador, estabelecimento, lotação tributária, regime, FAP, FPAS ou terceiros; sem isso não existem os eventos de tabela do eSocial (S-1000, S-1005, S-1020) nem encargos da empresa por lotação.

`folha.current_account_id()` (migration 0014) tinha dois defeitos:

1. Lia `gestao_auth.access_assertion` procurando uma asserção **não consumida** cujo `assertion_id` fosse o valor do parâmetro `dnex.context_nonce`. No protocolo do gestao (`dnex-gestao`, `migrations/0001_auth_context.preview.sql` e `0006_authorization_hardening.preview.sql`), `begin_request` **consome** a asserção e grava no parâmetro a chave de `gestao_auth.request_context`, não o `assertion_id`. Em fluxo real a conta vinha nula; e um `assertion_id` ainda não consumido servia de credencial reutilizável em `SET dnex.context_nonce`, sem vínculo com login, processo ou transação.
2. Aceitava, como reserva, o parâmetro de sessão `folha.account_id`, que qualquer sessão define com `SET`.

Insumos: plano de construção de 15/11/2026, parecer de INSS/FGTS/encargos (seção 3), parecer de eSocial/Reinf (seção 3.1) e a revisão independente do PR 3.

## Decisão

### Quatro níveis, todos com `account_id`

| Nível | Tabela | Conteúdo | Vigência |
|---|---|---|---|
| 1 | `folha.employer` | tipo e número de inscrição, razão social, natureza jurídica e classificação tributária do eSocial (códigos), situação | não (cadastro) |
| 2 | `folha.employer_regime` | regime tributário, opção pelo Simples, anexo e onde a CPP é recolhida, opção pela CPRB e percentual de redução, documento de prova | sim |
| 3 | `folha.establishment` | CNPJ/CAEPF/CNO, CNAE preponderante | não (cadastro) |
| 3 | `folha.establishment_fap` (filha) | FAP, origem do número, processo judicial | sim |
| 4 | `folha.tax_allocation` | código e tipo da lotação | não (cadastro) |
| 4 | `folha.tax_allocation_detail` (filha) | FPAS, código de terceiros, alíquota RAT, percentual patronal | sim |

Complementos:

- `folha.contract_tax_allocation`: rateio do contrato por lotação. Em todo dia em que o contrato tem rateio, a soma dos percentuais vigentes é 100.
- `employer_id` e `establishment_id`, anuláveis, em `folha.employee` (só `employer_id`), `folha.employment_contract` e `folha.payroll_run`.
- Parâmetros por vigência: o catálogo é `folha.payroll_parameter` da migration 0023 (global) e a leitura única é `folha.get_param`. A 0024 não cria tabela nem função de parâmetro; só acrescenta ao catálogo a constraint de vigências sem sobreposição por chave.

Nenhum valor normativo é semeado. Domínios oficiais (natureza jurídica, classificação tributária, tipo de lotação, FPAS, terceiros) entram como texto, sem lista: a validar na fonte.

### Vigência

`vigencia_inicio` e `vigencia_fim` são datas inclusivas (mesma leitura da 0016); `vigencia_fim` nula = em aberto. A não sobreposição é constraint de exclusão sobre `daterange(inicio, fim, '[]')`, que exige a extensão `btree_gist`, nova neste repositório.

### Isolamento e coerência da hierarquia

- RLS com FORCE e policy `account_id = (SELECT folha.current_account_id())` (USING e WITH CHECK) nas sete tabelas novas.
- Chaves estrangeiras compostas com `account_id`: nada aponta para pai de outra conta.
- Dentro da conta: o estabelecimento de um contrato ou de uma folha é do empregador daquele contrato ou folha (chave de três colunas; sem empregador não há estabelecimento); a lotação declara o empregador do seu estabelecimento; o rateio exige contrato e lotação do **mesmo empregador**.
- O rateio aceita lotações de estabelecimentos diferentes do mesmo empregador. A revisão sugeria "mesmo estabelecimento/empregador"; ficou empregador porque o S-1200 informa a remuneração por estabelecimento e lotação (`ideEstabLot`, parecer de eSocial, item A1) e um trabalhador pode ser rateado entre estabelecimentos. Se a regra de negócio for "só o estabelecimento do contrato", é uma chave a mais.

### ACL

Antes de conceder, a migration revoga tudo de todo papel que não seja o dono (lido do ACL do objeto, não de uma lista fixa), para não herdar default ACL do schema. Tabelas: worker com SELECT/INSERT/UPDATE, data_owner com SELECT. Funções de conta: EXECUTE só para worker e data_owner. Quem tinha EXECUTE em `current_account_id()` por concessão de fora do repositório perde e é listado em WARNING; nada é replicado.

### Conta da sessão

- `folha.request_context_account_id()` (SECURITY DEFINER): devolve a conta do contexto da transação, validado como `gestao_auth.has_permission` valida (`dnex-gestao`, `0007_producer_principal.preview.sql:666-740`): linha de `request_context` do nonce, presa a `session_user` + PID + txid e dentro da validade; asserção de origem idêntica, consumida naquele instante e não revogada; principal do login por `gestao_auth.assert_authorization_principal_v1` e escopo ativo por `gestao_auth.is_active_scope_v1`, que são as funções do próprio gestao. Qualquer falha devolve NULL.
- Não confere permissão: a lista fechada de `has_permission` não tem permissão da Folha. A função estabelece a conta; o que cada papel pode fazer é o GRANT.
- `folha.current_account_id()` (SECURITY INVOKER): contexto acima; a reserva por `folha.account_id` só vale quando `current_user` é `dnex_folha_ci` **e** o banco tem o schema-marcador `dnex_folha_ci_marcador` com dono superusuário. Papel e marcador são criados só por `tests/ci/bootstrap.sql`. A migration aborta se o papel existir sem o marcador.
- A função é INVOKER porque dentro de função SECURITY DEFINER `current_user` é o dono. Consequência: a reserva nunca vale dentro de função SECURITY DEFINER (as do motor da 0023 são). O contexto do protocolo vale, porque é preso a `session_user`.

### Rateio: conferência independente de quem grava

O trigger de constraint é adiado para o fim da transação e roda como SECURITY DEFINER, com `search_path` fixo, `row_security = off` e filtro explícito por conta e contrato: se a sessão perder ou trocar o contexto antes do COMMIT, a soma continua sendo feita sobre todas as linhas (sob RLS vinha nula e passava). Antes de somar, grava a linha do contrato, o que põe em fila duas transações que rateiam o mesmo contrato: a segunda enxerga as linhas da primeira (READ COMMITTED) ou falha com erro de serialização (REPEATABLE READ).

### Aplicação

Uma transação, `lock_timeout` de 5 s, pré-condições conferidas antes de qualquer DDL com mensagem própria: papel de teste sem marcador de CI; objetos do protocolo do gestao ausentes ou sem acesso para quem aplica; papel que aplica sem BYPASSRLS (exigido pela conferência do rateio); `btree_gist` indisponível; vigências já sobrepostas no catálogo de parâmetros. A reversão restaura corpo e GRANTs de `current_account_id()` da 0014 e recusa se houver dados.

## Dependências no dnex-gestao (nada foi criado lá)

1. **Não existe grupo de principal para a Folha.** Os grupos são `api`, `fiscal_worker`, `outbox_worker`, `context_issuer` e `producer` (`0007_producer_principal.preview.sql:320-323, 466-468`), e `assert_authorization_principal_v1` exige que o login pertença a exatamente um papel de grupo. Um login membro de `dnex_gestao_folha_worker` não passa em nenhum. Hoje nenhum login com acesso às tabelas da Folha abre contexto; depois da 0024 a conta dele é sempre nula. O grupo `folha_worker` que aparece no bootstrap de CI existe só para os testes exercerem o protocolo.
2. **Não existe permissão da Folha** na lista fechada de `has_permission`; `folha.mask_cpf` (0014) pede `folha.read`, que lá devolve falso.
3. **Não existe função do gestao que devolva a conta do contexto.** Por isso `request_context_account_id()` lê `request_context` e `access_assertion` diretamente e precisa de SELECT nelas e EXECUTE nas duas funções de validação para o papel que aplica a migration. O desejável é o gestao expor essa leitura e a Folha só chamá-la.
4. **O protocolo do gestao está em preview**: o README de `dnex-gestao/migrations` diz "NO-GO para deploy, homologação e produção". Se o que está em produção for diferente dos previews, a pré-condição da 0024 falha ou a leitura precisa ser revista.

## Alternativas consideradas

| Alternativa | Por que não |
|---|---|
| Manter a leitura pela asserção não consumida | não é o protocolo; conta nula em fluxo real e credencial reutilizável |
| Reimplementar a validação de principal e de escopo na Folha | duplicaria regra do gestao; as duas funções dele são reutilizadas |
| Reserva de CI condicionada só ao nome do papel | um papel com esse nome em produção reabriria a brecha; exige também o marcador, e a migration aborta sem ele |
| Testar `session_user` para a reserva | os testes da reserva trocam de papel com `SET ROLE` |
| Trigger do rateio como INVOKER | sob RLS a soma some com o contexto |
| Trava consultiva (`pg_advisory_xact_lock`) no rateio | não resolve REPEATABLE READ; a gravação da linha do contrato resolve os dois níveis |
| Trigger para impedir sobreposição de vigência | não é seguro sob concorrência sem trava; a constraint de exclusão é |
| Segunda tabela de parâmetros por conta e `get_parameter` | colide com o catálogo global e o `get_param` da 0023; sem consumidor hoje |

## Consequências

- **eSocial:** S-1000, S-1005 e S-1020 passam a ter de onde ler inscrição, classificação tributária, CNAE, FAP, código de lotação, FPAS e terceiros. Os geradores atuais não foram alterados.
- **Encargos e contabilização:** a apuração da empresa pode ser feita por estabelecimento e lotação. O motor ainda não lê estas tabelas.
- **Ponto e Portal:** usam `employer_id` e `establishment_id` como chave de empresa.
- **Testes do motor (0023):** rodam como o login de teste do worker, com contexto aberto por `begin_request`; a reserva não alcança funções SECURITY DEFINER.
- **Desempenho:** as policies das tabelas novas resolvem a conta uma vez por comando. As policies da 0014 chamam `current_account_id()` por linha, e a função agora faz mais trabalho; medir antes de produção.

### Contrato da chave de empresa empregadora (para Ponto, Portal, Gestão e Contábil)

- Empregador: `(account_id, employer_id)`. Chave de negócio: `(account_id, tipo_inscricao, inscricao)`, inscrição sem máscara.
- Estabelecimento: `(account_id, employer_id, establishment_id)`; chave de negócio `(account_id, tipo_inscricao, inscricao)`.
- Lotação: `(account_id, employer_id, allocation_id)`; chave de negócio `(account_id, establishment_id, codigo_lotacao)`.
- Sempre com `account_id` na chave estrangeira; nunca usar o uuid da conta como inscrição em documento ou evento.

## Em aberto

- Aceite desta ADR pelo proprietário, incluindo `btree_gist` e o rateio por empregador.
- As quatro dependências do gestao acima.
- Em produção: papel que aplica com BYPASSRLS; `btree_gist`; papéis com EXECUTE em `current_account_id()` concedido fora do repositório; chamadores que ainda definam `folha.account_id`.
- Preenchimento de `employer_id`/`establishment_id` nos dados existentes e passagem das colunas a obrigatórias.
- Sobreposição de parâmetro por conta ou empregador, se houver caso real.
- Listas oficiais dos códigos e regras de formato das inscrições: a validar na fonte.
