-- DNEX Folha — Bootstrap mínimo para replay das migrations 0014..0024 em CI.
-- Cria SOMENTE objetos externos ao repositório que as migrations referenciam.
-- Cada stub tem comentário com migration:linha que o exige.
-- NÃO usar em produção; apenas para testes de replay do zero.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Roles exigidas pelas migrations
-- ---------------------------------------------------------------------------

-- anon, authenticated, service_role: roles padrão do Supabase/PostgREST
-- Exigidas por: 0014:20 (REVOKE ... FROM PUBLIC, authenticated, service_role)
--               0014:344 (REVOKE ALL ON ALL TABLES ... FROM PUBLIC, authenticated, service_role)
--               0018:37,74 (REVOKE ... FROM PUBLIC, authenticated, service_role)
--               0022 (REVOKE ... FROM PUBLIC, anon, authenticated)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN;
  END IF;
END
$$;

-- dnex_gestao_data_owner: role de leitura/escrita administrativa
-- Exigida por: 0014:22 (GRANT USAGE ON SCHEMA folha TO dnex_gestao_data_owner)
--              0014:49,256,257,347-381 (grants diversos)
--              0016:74,188,245 (grants em funções de cálculo)
--              0019:68,143,242 (grants em eventos de vida)
--              0020:74,129,220 (grants em integração)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dnex_gestao_data_owner') THEN
    CREATE ROLE dnex_gestao_data_owner NOLOGIN;
  END IF;
  -- 0022: GRANT EXECUTE ... TO dnex_gestao_folha_worker
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dnex_gestao_folha_worker') THEN
    CREATE ROLE dnex_gestao_folha_worker NOLOGIN;
  END IF;
END
$$;

-- dnex_gestao_folha_worker: criada pela própria migration 0014:12-18,
-- mas listamos aqui para garantir existência antes de qualquer GRANT antecipado.
-- A migration 0014 faz IF NOT EXISTS, então é idempotente.

-- dnex_folha_ci: papel de teste dedicado para CI. ÚNICO papel para o qual
-- folha.current_account_id() aceita a reserva por parâmetro de sessão
-- (folha.account_id), a partir da migration 0024.
-- NÃO existe em produção e NENHUMA migration o cria: só este bootstrap.
-- Sem LOGIN, sem SUPERUSER e sem BYPASSRLS (as policies valem para ele).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dnex_folha_ci') THEN
    CREATE ROLE dnex_folha_ci NOLOGIN NOSUPERUSER NOBYPASSRLS INHERIT;
  END IF;
END
$$;

-- Mesmas permissões de tabela e função do worker, sem repetir a lista de GRANTs
-- (que só poderia rodar depois das migrations): o papel de teste é membro do
-- worker e herda o que as migrations concedem a ele, hoje e no futuro.
-- A herança não torna o worker um papel de teste: current_user continua sendo
-- o papel efetivo da sessão.
GRANT dnex_gestao_folha_worker TO dnex_folha_ci;

-- ---------------------------------------------------------------------------
-- 2. Schema extensions (para pgcrypto)
-- ---------------------------------------------------------------------------

-- Exigido por: 0014:27 (CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions)
CREATE SCHEMA IF NOT EXISTS extensions;

-- ---------------------------------------------------------------------------
-- 3. Schema gestao_auth + tabela access_assertion (stub)
-- ---------------------------------------------------------------------------

-- Exigido por: 0014:34 (SET search_path = pg_catalog, gestao_auth)
--              0014:37 (SELECT account_id FROM gestao_auth.access_assertion ...)
--              0014:244 (SET search_path = pg_catalog, folha, gestao_auth em mask_cpf)
--              0014:247 (gestao_auth.has_permission(...) em mask_cpf)
CREATE SCHEMA IF NOT EXISTS gestao_auth;

-- Stub da tabela access_assertion — somente colunas usadas em 0014:37-41
CREATE TABLE IF NOT EXISTS gestao_auth.access_assertion (
  assertion_id uuid PRIMARY KEY,
  account_id uuid NOT NULL,
  consumed_at timestamptz,
  revoked_at timestamptz,
  expires_at timestamptz NOT NULL
);

-- Stub da função has_permission — usada em 0014:247 (mask_cpf)
-- Retorna false por padrão no CI; em produção é implementada pelo dnex-gestao.
CREATE OR REPLACE FUNCTION gestao_auth.has_permission(
  p_permission text,
  p_account_id uuid,
  p_resource_type text,
  p_resource_id uuid
) RETURNS boolean
LANGUAGE sql STABLE
AS $$
  SELECT false;
$$;

-- ---------------------------------------------------------------------------
-- 4. Extensão pgTAP (para testes)
-- ---------------------------------------------------------------------------

-- Exigido por: todos os tests/folha/*.pgtap.sql (SELECT plan(), ok(), is(), etc.)
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

COMMIT;
