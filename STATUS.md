# DNEX Folha — Status do Repositório

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