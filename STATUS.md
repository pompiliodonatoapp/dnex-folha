# DNEX Folha — Status do Repositório

## Frente 15/11/2026 (noite) — Migration 0024: empregador em quatro níveis e parâmetros por vigência

Branch `feat/folha-empregador-20261115`, PR em rascunho. Nada aplicado em produção.

### O que entrou

- **Migration 0024** (`migrations/supabase/0024_folha_empregador_parametros.supabase.sql`): oito tabelas com `account_id` (`employer`, `employer_regime`, `establishment`, `establishment_fap`, `tax_allocation`, `tax_allocation_detail`, `contract_tax_allocation`, `payroll_parameter`); vigência em duas datas inclusivas, sem sobreposição por constraint de exclusão (`btree_gist`, extensão nova neste repositório); chaves estrangeiras compostas com `account_id`; rateio do contrato por lotação somando 100 em cada dia coberto (trigger de constraint adiado); `get_parameter(chave, data)` que levanta exceção sem vigência; `employer_id`/`establishment_id` anuláveis em `employee`, `employment_contract` e `payroll_run`; RLS com FORCE, `REVOKE ALL` antes dos GRANTs (worker lê e grava, data_owner só lê). Nenhum valor normativo semeado.
- **Correção de segurança:** `folha.current_account_id()` não aceita mais o parâmetro de sessão `folha.account_id`, exceto para o papel de teste `dnex_folha_ci`, criado só em `tests/ci/bootstrap.sql`. A leitura da asserção de `gestao_auth` foi para `folha.assertion_account_id()` (SECURITY DEFINER) e `current_account_id()` passou a SECURITY INVOKER.
- **Testes:** `tests/folha/0024_empregador_parametros.pgtap.sql` (142 asserções) e `tests/folha/0014_folha_rls_isolation.pgtap.sql` (19; isolamento com o papel de teste, sem as asserções que passavam sempre).
- **ADR:** `docs/02-decisoes/ADR-empregador-quatro-niveis.md` (proposta; aceite do proprietário pendente).

### Verificado em execução (PostgreSQL 17 + pgTAP em Docker local, banco recriado, roteiro de `tests/ci/replay.sh`)

- Bootstrap, migrations 0014 a 0022 e 0024, e os seis arquivos de teste: 247 asserções, todas aprovadas, exceto o `todo` já existente do centavo do INSS em `golden_cases_calculo`.
- Os testes de isolamento falham quando a função antiga (reserva aberta) é reposta, quando a RLS de uma tabela nova é afrouxada, quando o trigger do rateio é removido e quando PUBLIC recebe SELECT.

### Não verificado

- CI do GitHub. O job "Migration sequence check" vai falhar enquanto a 0023 (outro PR) não estiver no `main`: a sequência salta de 0022 para 0024. Não renumerar.
- Produção: disponibilidade de `btree_gist`; papéis com EXECUTE em `current_account_id()` concedido fora do repositório; inexistência do papel `dnex_folha_ci`.
- Documentação funcional no vault `DNEX-Documentacao`: não atualizada (vault inacessível neste host). Pendência documental aberta.

### Próximas fatias

- Carga de parâmetros legais com ato e conferência (hoje a tabela nasce vazia) e decisão entre parâmetro por conta ou catálogo global.
- Motor lendo `get_parameter` e recusando `a_validar`; encargos por estabelecimento e lotação.
- Preencher `employer_id`/`establishment_id` nos dados existentes e torná-las obrigatórias.
- Listas oficiais de códigos (natureza jurídica, classificação tributária, tipo de lotação, FPAS, terceiros): a validar na fonte.

---

## Frente 15/11/2026 — CI de replay e pgTAP

### O que foi feito

- **Migration 0022** (`migrations/supabase/0022_folha_revogar_execucao_publica.supabase.sql`): revoga execução pública de 8 funções sensíveis (dispatch eSocial/Reinf, dashboard). Funções criadas por outro repositório (`build_esocial_s1210`, `build_esocial_s1299`, `build_esocial_s2299`, `build_reinf_r2010`, `build_reinf_r4010`, sobrecarga `dispatch_folha_completa(uuid,date)`) são tratadas com `to_regprocedure()` para idempotência no replay do zero.
- **Bootstrap CI** (`tests/ci/bootstrap.sql`): cria roles (`anon`, `authenticated`, `service_role`, `dnex_gestao_data_owner`), schema `extensions`, schema `gestao_auth` com stubs de `access_assertion` e `has_permission()`, e extensão pgTAP. Cada stub referenciado à migration:linha correspondente.
- **Script de replay** (`tests/ci/replay.sh`): aplica bootstrap → migrations em ordem → testes pgTAP via `pg_prove`, com `ON_ERROR_STOP=1` e falha alta.
- **Teste ACL 0022** (`tests/folha/0022_folha_acl.pgtap.sql`): 25 asserções verificando que `anon`/`authenticated` não executam funções sensíveis, que `dnex_gestao_folha_worker` executa, e varredura geral de SECURITY DEFINER sem exceções.
- **Workflow CI** (`.github/workflows/ci-db.yml`): job `migration-sequence` valida numeração contínua sem duplicatas; job `db-replay` instala PostgreSQL 17 + pgTAP via PGDG apt repo no runner e roda `replay.sh`.
- **Achados documentados** (`scratch/ACHADOS.md`): dependências externas mapeadas e defeitos potenciais listados.

### O que NÃO foi testado localmente

- Execução real do `replay.sh` contra PostgreSQL (ambiente local sem psql disponível).
- Instalação do pacote `postgresql-17-pgtap` no runner GitHub Actions (validado apenas pela documentação do PGDG).
- Comportamento dos testes pgTAP existentes (`golden_cases_calculo`, `eventos_vida_calculo`, `dashboard_completo_rpc`, `0014_folha_rls_isolation`) em ambiente limpo — podem revelar dependências adicionais não cobertas pelo bootstrap.
- A função `gestao_auth.has_permission()` retorna `false` no CI; o teste `mask_cpf` em `0014_folha_rls_isolation.pgtap.sql` espera máscara quando sem permissão, o que deve funcionar, mas o comportamento completo de desmascaramento não é testável sem o dnex-gestao real.

### Suposições não testadas

- O pacote `postgresql-17-pgtap` existe no repositório PGDG para Ubuntu 24.04 (noble). Se não existir, o CI falhará na instalação e será necessário build manual do pgTAP ou uso de imagem Docker customizada.
- As funções `build_esocial_s1210`, `build_esocial_s1299`, `build_esocial_s2299`, `build_reinf_r2010`, `build_reinf_r4010` e a sobrecarga `dispatch_folha_completa(uuid,date)` realmente existem em produção no repositório `dnex-gestao, migration 0027`. Não foram encontradas nas migrations 0014–0021 deste repositório.
- O `pg_prove` está disponível após instalação do pacote `postgresql-17-pgtap`; se estiver em caminho diferente, o `replay.sh` precisará de ajuste.