# Contrato do banco para o Portal do Colaborador v1 — nomes finais

De: frente Folha. Para: frente Portal. Data: 15/11/2026.
Resposta a "Portal do Colaborador v1 — forma exata que o contrato precisa do banco" (BANCO-V1). Implementado na migration `0029_folha_portal_colaborador` (depende da `0028`). **Nada aplicado em nenhum ambiente**; provado só em PostgreSQL 17 local (`tests/folha/0029_portal_colaborador.pgtap.sql`, 190 asserções, incluindo os oito testes pedidos). O adaptador nunca rodou contra este banco.

## 1. O que o Portal chama

Schema **`portal_api`** (só estas quatro funções, nenhuma tabela). `POST /rest/v1/rpc/<nome>` com o token do próprio empregado e `Content-Profile: portal_api`. EXECUTE só para `authenticated`. Nenhuma recebe conta, trabalhador ou usuário; o usuário é `auth.uid()`.

| Função | Parâmetros | Retorno |
|---|---|---|
| `listar_meus_documentos` | `p_tipo text default null`, `p_de date default null`, `p_ate date default null`, `p_employer_id uuid default null` | conjunto de linhas com os dez campos do contrato `folha.portal-documento-publicado.v1`, nesta ordem: `document_id`, `employer_id`, `employer_nome`, `establishment_inscricao`, `tipo`, `competencia`, `titulo`, `published_at`, `tamanho_bytes`, `visto_em`. Ordem: `competencia desc, published_at desc` (desempate por `document_id`) |
| `abrir_meu_documento` | `p_document_id uuid`, `p_acao text` | uma linha `storage_path text, sha256 text`, ou nenhuma |
| `meu_aviso_privacidade` | — | **escalar** `text` (a resposta do PostgREST é `"2026-11"` ou `null`, sem chave) |
| `aceitar_aviso_privacidade` | `p_versao text` | void |

Comportamento que o adaptador precisa conhecer:

- `auth.uid()` nulo: `listar` e `abrir` devolvem vazio; `meu_aviso` devolve nulo; `aceitar` não faz nada. Argumento inválido (`p_acao`, `p_versao`) é `22023` mesmo sem usuário. `sub` que não seja uuid dá `22P02`.
- `anon` recebe `42501` (sem acesso ao schema). **`service_role` também**: as quatro funções são só de `authenticated`; chamadas com a chave de serviço são recusadas.
- `listar` não tem limite nem paginação; `p_tipo` desconhecido ou `p_de > p_ate` devolvem vazio, sem erro. `abrir` e `aceitar` gravam: só por POST.
- `abrir_meu_documento` devolve nenhuma linha para "não existe", "não é seu", "retirado", habilitação revogada ou vencida e `p_document_id` nulo, sem gravar acesso. **`p_acao` fora de `abriu`/`baixou` (ou nulo) é erro `22023`**, não linha vazia.
- O acesso é gravado na mesma transação, com a hora real. A mesma ação do mesmo usuário no mesmo documento em menos de 60 segundos não grava outra linha (o caminho é devolvido do mesmo jeito); pedidos simultâneos são postos em fila por usuário, documento e ação.
- `visto_em` é o primeiro acesso **daquele usuário** àquele documento.
- `meu_aviso_privacidade` devolve a versão aceita por último (pela hora do aceite), não a "maior".
- `aceitar_aviso_privacidade`: `p_versao` precisa casar com `^[0-9A-Za-z][0-9A-Za-z._-]{0,31}$` (senão `22023`); é idempotente; **não grava, em silêncio, para usuário que o escritório nunca habilitou** (ele continuará lendo nulo: releia `meu_aviso_privacidade` depois de aceitar); no máximo cinco versões novas por usuário a cada 24 horas (`54000`). O banco confere só o formato: saber se a versão existe e é a vigente é da API do Portal.
- `competencia` sai como `AAAA-MM-DD`; `published_at` e `visto_em` em ISO 8601 com fuso; `tamanho_bytes` como número.
- Pode haver **mais de um `holerite` na mesma competência** (adiantamento, mensal, complementar) e **dois `decimo_terceiro` no mesmo ano** (duas parcelas, ambas com competência em dezembro); distinguem-se pelo título.

## 2. Regra de acesso

A do BANCO-V1, sem alteração: habilitação com `user_id = auth.uid()`, `status = 'ativo'`, `acesso_ate` nulo ou `data de hoje em São Paulo <= acesso_ate`, mesma conta, trabalhador e empregador do documento; e documento `publicado`. `data_demissao` e `status` do contrato não entram. O escritório pode habilitar depois do desligamento. `acesso_ate` é gravado nulo enquanto o proprietário não decidir o prazo padrão.

## 3. Tabelas (schema `folha`; o Portal não as lê)

| Tabela | Observação |
|---|---|
| `folha.portal_employee_access` | como pedido, com as diferenças da seção 5 |
| `folha.published_document` | idem |
| `folha.published_document_access` | só INSERT (UPDATE, DELETE e TRUNCATE recusados por gatilho) |
| `folha.portal_privacy_acceptance` | PK `(user_id, versao)`; só INSERT (UPDATE, DELETE e TRUNCATE recusados por gatilho) |

RLS com FORCE nas quatro. Nenhuma policy nem GRANT para `anon`, `authenticated`, `service_role` ou `dnex_gestao_api`. Leitura por conta só para os papéis NOLOGIN da Folha (worker e data_owner); a de aceite não tem policy nem GRANT. Gravação só pelas funções. Chaves estrangeiras compostas com `account_id`.

## 4. Funções do escritório (Hub, com contexto da Folha; fora do Portal)

EXECUTE só para `dnex_gestao_api`. A conta e quem executa vêm do contexto (o subject fica gravado).

| Função | Permissão | Observação |
|---|---|---|
| `folha.portal_acesso_habilitar_v1(p_employee_id, p_employer_id, p_user_id, p_acesso_ate date default null) → uuid` | `folha.admin` | idempotente para o mesmo usuário e prazo; com outro prazo é erro (use a função de prazo); recusa segundo usuário para o mesmo trabalhador e empregador, e o mesmo usuário para outro trabalhador do mesmo empregador; exige que trabalhador e empregador existam na conta e tenham vínculo (algum contrato, ou o empregador do cadastro do trabalhador). `p_user_id` não é conferido contra o serviço de autenticação |
| `folha.portal_acesso_revogar_v1(p_access_id) → void` | `folha.admin` | idempotente |
| `folha.portal_acesso_definir_prazo_v1(p_access_id, p_acesso_ate date) → void` | `folha.admin` | nulo tira o corte |
| `folha.portal_documento_publicar_v1(p_employee_id, p_employer_id, p_tipo, p_competencia, p_titulo, p_storage_path, p_sha256, p_tamanho_bytes, p_origem_publicacao, p_run_id default null, p_contract_id default null, p_establishment_id default null, p_document_id default null) → uuid` | `folha.transmit` | o arquivo já deve estar no armazenamento; mesmo vínculo exigido na habilitação; com `p_run_id` e sem `p_contract_id`, o contrato é o do resultado (erro se houver mais de um). Erro de restrição volta só com o nome da restrição, sem a linha |
| `folha.portal_documento_retirar_v1(p_document_id, p_motivo) → void` | `folha.transmit` | sem volta; idempotente |
| `folha.portal_relatorio_visualizacao_v1(p_de, p_ate, p_employer_id, p_tipo) → linhas` | `folha.read` | por documento: publicação, primeiro acesso e total |

A lista fechada do gestao não tem permissão própria do Portal; o mapeamento acima (habilitar = administrar; publicar = entregar) é proposta da Folha.

## 5. Divergências em relação ao BANCO-V1

| # | Pedido | Entregue | Motivo |
|---|---|---|---|
| 1 | `habilitado_por`, `revogado_por`, `published_by`, `retired_by` como `text` | `*_subject uuid` (subject do contexto) | identidade real, não texto digitado. O Portal não lê tabela |
| 2 | FKs simples para `employee`, `employment_contract`, `payroll_run` | compostas com `account_id`; contrato e estabelecimento presos ao empregador | isolamento entre contas no dado |
| 3 | único parcial por `(conta, trabalhador, empregador, tipo, competência)` para holerite, 13º, informe e espelho | com `run_id`: único por `(…, tipo, run_id, contrato)` (inclusive férias e rescisão); sem `run_id`: único por competência só para 13º, informe e espelho | a Folha tem várias folhas por competência (adiantamento, mensal, complementar; 13º em duas parcelas). Ver o último item da seção 1 |
| 4 | holerite só de folha `closed` | **todo** documento com `run_id` exige folha fechada, sem pendência aberta, do mesmo empregador (quando a folha tem empregador), com resultado daquele trabalhador em contrato daquele empregador e de tipo de processo compatível (holerite: mensal, adiantamento ou complementar; 13º: as duas parcelas; recibo de férias: férias; rescisão: rescisão). Aviso de férias, informe e espelho não aceitam `run_id`. Holerite exige competência igual à da folha | pedido do proprietário: publicação só de folha fechada e sem pendência |
| 5 | origem `parametro` e `rotina` sem regra | para holerite, 13º, recibo de férias e rescisão, exigem `run_id`. `avulsa` desses tipos (menos holerite) é aceita sem folha | documento automático nasce de folha; o avulso cobre documento feito fora do DNEX (por exemplo, de quem veio de outro sistema). **Lacuna assumida:** rescisão, recibo de férias e 13º avulsos não passam pela conferência de folha fechada |
| 6 | `storage_path` "sem `..`, sem barra inicial"; caminho sugerido | caminho **obrigatoriamente** iniciado por `<account_id>/<employee_id>/`, só com `[0-9A-Za-z_.-]` e `/`, até 500 caracteres, único | a API do Portal assina qualquer caminho que o banco devolve; sem o prefixo, um documento poderia apontar para arquivo de outra conta ou de outro trabalhador. O caminho sugerido atende |
| 7 | `sha256` "64 hex" | gravado em minúsculas (a função converte) | comparação estável |
| 8 | `competencia` de informe e 13º "use dezembro" | CHECK: mês 12 | o que o Portal pediu, no dado |
| 9 | `titulo` livre | não vazio, até 200 caracteres | — |
| 10 | um `user_id` pode ter várias linhas ativas | pode, em empregadores e contas diferentes; **não** em dois trabalhadores do mesmo empregador | identificador digitado errado abriria o holerite de outro colega |
| 11 | `versao` livre; aceite de qualquer usuário | formato restrito; só para quem já foi habilitado; limite por dia | usuário autenticado qualquer não ocupa a tabela |
| 12 | `published_document_access` | recusa repetição da mesma ação em menos de 60 s | tabela só de inclusão não pode crescer por rajada |
| 13 | publicação "por rotina" | exige usuário no pedido (`folha.transmit`) | o contexto do gestao não atende rotina sem usuário |
| 14 | bucket `folha-documentos-publicados` | **não criado** aqui | armazenamento fica fora desta migration; o banco não confere que o arquivo existe nem que hash e tamanho batem |
| 15 | `meu_aviso_privacidade` devolve `versao_aceita text` | escalar `text`, sem chave | se o adaptador preferir linha com a chave, é troca simples: avisem |
| 16 | `abrir_meu_documento`: sempre linha ou nenhuma | `p_acao` inválida é erro `22023` | erro de programação do chamador não deve parecer "documento inexistente" |
| 17 | `at default now()` | hora real (`clock_timestamp()`) | `now()` é a hora do início da transação |
| 18 | (não pedido) | o prefixo do caminho usa os uuid em minúsculas, como o banco os escreve | comparação exata |

Alterar documento publicado: nenhum campo muda; a única transição é `publicado → retirado` (com quem, quando e motivo). Corrigir é retirar e publicar outro arquivo.

## 6. Decisões do proprietário em aberto

1. **Expor o schema `portal_api` na API** do projeto (configuração do PostgREST). A migration 0022 fechou a Folha para `anon` e `authenticated`; esta reabre exatamente quatro funções para `authenticated`, que é todo usuário autenticado do projeto, não só empregados. O que protege é a habilitação gravada pelo escritório.
2. Prazo padrão de `acesso_ate`.
3. Quem cria o bucket e as policies de armazenamento.
4. Quem cria a conta do empregado no serviço de autenticação e de onde o Hub tira o `user_id` que informa na habilitação (o banco não confere esse identificador; a defesa é a unicidade da divergência 10).
5. A identidade do empregado depende de `auth.uid()` do projeto. No CI ela é uma reprodução da definição pública do Supabase; **não foi conferida contra a produção**.

## 7. Não verificado

Chamada pelo PostgREST de verdade (os testes simulam o papel `authenticated` e os parâmetros de requisição por SQL), inclusive status HTTP dos erros e formato do escalar; publicação de 13º, recibo de férias e rescisão a partir de folhas reais desses tipos (a regra de tipo foi exercida só com folha mensal); concorrência real em duas conexões pela suíte (um revisor exerceu o aceite com 30 conexões); desempenho com volume; o adaptador do Portal contra este banco.
