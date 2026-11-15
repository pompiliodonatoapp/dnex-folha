# ADR: empregador em quatro níveis e parâmetros por vigência

- **Status:** proposta (aceite do proprietário pendente; entra com o merge do PR)
- **Data:** 2026-11-15
- **Migration:** `migrations/supabase/0024_folha_empregador_parametros.supabase.sql`
- **Testes:** `tests/folha/0024_empregador_parametros.pgtap.sql`

## Contexto

O DNEX Folha só conhecia a conta do Hub (`account_id`). Não havia onde gravar inscrição do empregador, estabelecimento, lotação tributária, regime, FAP, FPAS ou terceiros; sem isso não existem os eventos de tabela do eSocial (S-1000, S-1005, S-1020) nem encargos da empresa por lotação. Parâmetros legais estavam em constantes e JSON sem fonte. E `folha.current_account_id()` aceitava, como reserva, o parâmetro de sessão `folha.account_id`, que qualquer sessão define com `SET`: o próprio worker podia escolher a conta.

Insumos: plano de construção de 15/11/2026 (seção "Modelo de dados a adotar"), parecer de INSS/FGTS/encargos (seção 3) e parecer de eSocial/Reinf (seção 3.1).

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

- `folha.contract_tax_allocation`: rateio do contrato por lotação. Em todo dia em que o contrato tem rateio, a soma dos percentuais vigentes é 100. A conferência é um trigger de constraint adiado para o fim da transação (as linhas podem ser gravadas uma a uma).
- Parâmetros por vigência: o catálogo é `folha.payroll_parameter` da migration 0023 (global, sem `account_id`: parâmetro legal é igual para todas as contas) e a leitura única é `folha.get_param(chave, data)`, também da 0023, que levanta exceção quando não há parâmetro vigente. A 0024 não cria outra tabela nem outra função; só acrescenta ao catálogo a constraint de vigências sem sobreposição por chave. A primeira versão desta migration criava uma `payroll_parameter` por conta e `get_parameter`; foram retiradas por colidirem com a 0023.
- `employer_id` e `establishment_id`, anuláveis, em `folha.employee` (só `employer_id`), `folha.employment_contract` e `folha.payroll_run`.

Nenhum valor normativo é semeado nesta migration. Domínios oficiais (natureza jurídica, classificação tributária, tipo de lotação, FPAS, terceiros) entram como texto, sem lista: a lista oficial não está nos insumos e fica a validar na fonte.

### Vigência

`vigencia_inicio` e `vigencia_fim` são datas inclusivas (mesma leitura da migration 0016); `vigencia_fim` nula significa em aberto. A não sobreposição é constraint de exclusão sobre `daterange(inicio, fim, '[]')`, o que exige a extensão `btree_gist`, nova neste repositório.

### Isolamento

RLS com FORCE e policy `account_id = folha.current_account_id()` (USING e WITH CHECK) nas sete tabelas novas (`payroll_parameter` mantém a RLS e a ACL da 0023); `REVOKE ALL` de PUBLIC, anon, authenticated e service_role antes dos GRANTs; worker com SELECT/INSERT/UPDATE e data_owner com SELECT, como na 0014. As chaves estrangeiras entre as tabelas novas, e das colunas novas nas tabelas existentes, são compostas com `account_id`: um registro não aponta para pai de outra conta.

### Conta da sessão (correção de segurança)

- `folha.assertion_account_id()` (SECURITY DEFINER): lê só a asserção de `gestao_auth.access_assertion` indicada por `dnex.context_nonce`, válida, não consumida e não revogada. É o caminho de produção, sem mudança de regra.
- `folha.current_account_id()` passa a SECURITY INVOKER e devolve a asserção; a reserva por `folha.account_id` só vale quando `current_user` é `dnex_folha_ci`. Esse papel é criado apenas em `tests/ci/bootstrap.sql` (membro do worker, sem LOGIN, sem BYPASSRLS); nenhuma migration o cria e ele não deve existir em produção.

A função precisou deixar de ser SECURITY DEFINER: dentro de função desse tipo `current_user` é o dono da função, e a condição do papel de teste nunca seria satisfeita. Consequência: dentro de qualquer função SECURITY DEFINER a reserva não vale, nem para o papel de teste. As funções do motor (`calc_13o`, `calc_ferias`, `calc_rescisao`) são SECURITY DEFINER e leem a conta por `current_account_id()`: em produção seguem pela asserção, e os testes delas passaram a criar uma asserção e definir o nonce, em vez de `folha.account_id`.

## Alternativas consideradas

| Alternativa | Por que não |
|---|---|
| Empregador em uma tabela com JSON | sem vigência verificável, sem constraint de sobreposição, não mapeia para os eventos de tabela |
| Coluna `daterange` | o pedido é vigência explícita em duas datas; o intervalo é montado só na constraint |
| Trigger para impedir sobreposição | não é seguro sob concorrência sem trava explícita; a constraint de exclusão é |
| Índice único parcial | não detecta intervalos que se cruzam |
| Manter `current_account_id()` SECURITY DEFINER com teste de `current_user` | a condição nunca é verdadeira (ver acima); os testes de isolamento deixariam de exercer a RLS |
| Testar `session_user` | os testes trocam de papel com `SET ROLE`, que não altera `session_user`; exigiria `SET SESSION AUTHORIZATION` em todos os testes |
| Rateio com uma linha-cabeçalho por período | uma tabela a mais; a regra "soma 100 em cada dia" na própria tabela resolve |
| Segunda tabela de parâmetros por conta e `get_parameter` | colide com o catálogo global e o `get_param` da 0023; sobreposição por conta ou empregador não tem consumidor hoje e pertence à fatia das três camadas de regra |

## Consequências

- **eSocial:** S-1000, S-1005 e S-1020 passam a ter de onde ler inscrição, classificação tributária, CNAE, FAP, código de lotação, FPAS e terceiros. O `ideEstabLot` de S-1200 usa a inscrição do estabelecimento e o `codigo_lotacao`. Os geradores atuais não foram alterados aqui.
- **Encargos e contabilização:** a apuração da empresa pode ser feita por estabelecimento e lotação, com o regime vigente e parâmetros com fonte; o rateio do contrato dá a divisão do custo. O motor ainda não lê estas tabelas.
- **Ponto:** vincula marcações ao `establishment_id`; relatórios por empresa usam `employer_id`.
- **Portal do Colaborador:** documentos publicados identificam o empregador por `employer_id` e exibem razão social e inscrição do estabelecimento.

### Contrato da chave de empresa empregadora (para Ponto, Portal, Gestão e Contábil)

- Empregador: `(account_id, employer_id)`. Chave de negócio para integração: `(account_id, tipo_inscricao, inscricao)`, com a inscrição sem máscara.
- Estabelecimento: `(account_id, establishment_id)`; chave de negócio `(account_id, tipo_inscricao, inscricao)`.
- Lotação: `(account_id, allocation_id)`; chave de negócio `(account_id, establishment_id, codigo_lotacao)`.
- Sempre com `account_id` na chave estrangeira; nunca usar o uuid da conta como inscrição em documento ou evento.

## Em aberto

- Aceite desta ADR pelo proprietário.
- `btree_gist` precisa estar disponível no banco de produção; não foi conferido.
- Papéis que tenham recebido EXECUTE em `current_account_id()` fora do repositório: a migration replica o EXECUTE para `assertion_account_id()`, mas a lista de produção não foi conferida.
- Sobreposição de parâmetro por conta ou empregador (convenção, regra da empresa): não criada; se vier, entra como tabela própria e sobrecarga de `get_param`, com trilha de onde veio o valor.
- Chamadores de produção que ainda definam `folha.account_id` em vez do nonce deixam de ter conta depois da 0024: conferir antes de aplicar.
- Preenchimento de `employer_id`/`establishment_id` nos dados existentes e passagem das colunas a obrigatórias.
- Listas oficiais dos códigos (natureza jurídica, classificação tributária, tipo de lotação, FPAS, terceiros) e regras de formato das inscrições: a validar na fonte.
