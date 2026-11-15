-- DNEX Folha — Bootstrap mínimo para replay das migrations 0014..0025 em CI.
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
-- (folha.account_id), a partir da migration 0024, e só enquanto existir o
-- marcador de CI abaixo.
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

-- Marcador de banco de CI: um schema vazio, criado por superusuário, ANTES das
-- migrations. É por banco (papéis são do cluster), não é parâmetro de sessão e
-- não pode ser criado por papel de aplicação. A migration 0024 aborta se o
-- papel dnex_folha_ci existir sem este marcador, e a reserva de
-- current_account_id() só vale enquanto ele existir com dono superusuário.
CREATE SCHEMA IF NOT EXISTS dnex_folha_ci_marcador;
REVOKE ALL ON SCHEMA dnex_folha_ci_marcador FROM PUBLIC;
COMMENT ON SCHEMA dnex_folha_ci_marcador IS
  'Marcador de banco de CI do dnex-folha. Não deve existir em produção.';

-- Login de teste do worker: o protocolo de contexto do gestao_auth vincula o
-- contexto ao session_user, que precisa ser um login sem atributos e membro de
-- exatamente um papel de grupo. Os testes assumem este login com
-- SET LOCAL SESSION AUTHORIZATION (sem senha: ninguém conecta com ele).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dnex_folha_ci_login') THEN
    CREATE ROLE dnex_folha_ci_login LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS INHERIT;
  END IF;
END
$$;
GRANT dnex_gestao_folha_worker TO dnex_folha_ci_login;

-- ---------------------------------------------------------------------------
-- 2. Schema extensions (para pgcrypto)
-- ---------------------------------------------------------------------------

-- Exigido por: 0014:27 (CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions)
CREATE SCHEMA IF NOT EXISTS extensions;

-- ---------------------------------------------------------------------------
-- 3. Protocolo de contexto do gestao_auth (reprodução para CI)
--
-- Fonte: dnex-gestao, migrations 0001_auth_context, 0006_authorization_hardening
-- e 0007_producer_principal (previews; no README do gestao, "NO-GO para deploy,
-- homologação e produção"). O que está aqui reproduz o protocolo, não o
-- substitui:
--   1. o emissor registra uma asserção (access_assertion), curta e de uso único,
--      vinculada ao login que vai usá-la;
--   2. o login chama begin_request(assertion_id, context_nonce, correlation_id):
--      a asserção é CONSUMIDA e nasce uma linha em request_context, presa a
--      session_user + PID do backend + txid; o GUC dnex.context_nonce recebe a
--      chave dessa linha (não o assertion_id);
--   3. a leitura revalida tudo isso a cada uso (como has_permission).
--
-- Diferenças declaradas em relação ao gestao:
--   a) GRUPO 'folha_worker' (papel dnex_gestao_folha_worker) e permissão
--      'folha.ci' NÃO EXISTEM no gestao. O gestao só conhece api, fiscal_worker,
--      outbox_worker, context_issuer e producer. Sem um grupo da Folha lá,
--      nenhum login com acesso às tabelas da Folha abre contexto em produção.
--      Aqui o grupo existe só para os testes exercerem o protocolo; é a
--      dependência registrada no STATUS e na ADR, não uma decisão tomada.
--   b) register_assertion (emissor) não é reproduzida: os testes gravam a
--      asserção direto, como superusuário.
--   c) listas fechadas de permissão por grupo ficam de fora (a Folha não tem
--      permissão registrada no gestao).
--   d) donos e GRANTs do gestao (dnex_gestao_auth_owner etc.) não são
--      reproduzidos: aqui tudo é do superusuário do CI.
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS gestao_auth;
CREATE SCHEMA IF NOT EXISTS gestao_finance;

-- gestao 0006: registro de escopos empresariais ativos (só as colunas lidas).
CREATE TABLE IF NOT EXISTS gestao_finance.enterprise_scope_registry (
  account_id uuid NOT NULL,
  legal_entity_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  status text NOT NULL DEFAULT 'active',
  deprovisioned_at timestamptz,
  PRIMARY KEY (account_id, legal_entity_id, branch_id)
);

-- gestao 0001:94-153
CREATE TABLE IF NOT EXISTS gestao_auth.access_assertion (
  assertion_id uuid PRIMARY KEY,
  subject_id uuid NOT NULL,
  subject_type text NOT NULL,
  principal_group text NOT NULL,
  runtime_session_user name NOT NULL,
  account_id uuid NOT NULL,
  legal_entity_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  permissions text[] NOT NULL,
  issued_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  consumed_at timestamptz,
  revoked_at timestamptz,
  registered_by name NOT NULL DEFAULT current_user,
  CONSTRAINT access_assertion_subject_type_check
    CHECK (subject_type IN ('user', 'system', 'integration')),
  CONSTRAINT access_assertion_group_check
    CHECK (principal_group IN ('api', 'fiscal_worker', 'outbox_worker', 'producer', 'folha_worker')),
  CONSTRAINT access_assertion_expiry_check
    CHECK (expires_at > issued_at AND expires_at <= issued_at + interval '5 minutes'),
  CONSTRAINT access_assertion_consumed_check
    CHECK (consumed_at IS NULL OR (consumed_at >= issued_at AND consumed_at < expires_at)),
  CONSTRAINT access_assertion_revoked_check
    CHECK (revoked_at IS NULL OR revoked_at >= issued_at)
);

-- gestao 0001:167-225
CREATE TABLE IF NOT EXISTS gestao_auth.request_context (
  context_nonce uuid PRIMARY KEY,
  assertion_id uuid NOT NULL UNIQUE
    REFERENCES gestao_auth.access_assertion (assertion_id) ON DELETE RESTRICT,
  runtime_session_user name NOT NULL,
  backend_pid integer NOT NULL,
  transaction_id bigint NOT NULL,
  subject_id uuid NOT NULL,
  subject_type text NOT NULL,
  principal_group text NOT NULL,
  account_id uuid NOT NULL,
  legal_entity_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  permissions text[] NOT NULL,
  correlation_id uuid NOT NULL,
  created_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  CONSTRAINT request_context_transaction_unique
    UNIQUE (runtime_session_user, backend_pid, transaction_id),
  CONSTRAINT request_context_backend_check CHECK (backend_pid > 0),
  CONSTRAINT request_context_transaction_check CHECK (transaction_id > 0),
  CONSTRAINT request_context_expiry_check
    CHECK (expires_at > created_at AND expires_at <= created_at + interval '5 minutes')
);

-- gestao 0007:448-530, com o grupo 'folha_worker' acrescentado (diferença a).
CREATE OR REPLACE FUNCTION gestao_auth.assert_authorization_principal_v1(
  p_login name,
  p_expected_principal_group text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
VOLATILE
SET search_path = pg_catalog, gestao_auth
SET row_security = on
AS $function$
DECLARE
  v_expected_role name;
  v_reachable_memberships integer;
  v_expected_memberships integer;
BEGIN
  IF p_login IS NULL
     OR p_expected_principal_group IS NULL
     OR p_expected_principal_group NOT IN (
       'api', 'fiscal_worker', 'outbox_worker', 'context_issuer', 'producer', 'folha_worker'
     ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'principal de autorização inválido';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_catalog.pg_roles
    WHERE rolname = p_login::text
      AND rolcanlogin
      AND NOT rolsuper
      AND NOT rolcreatedb
      AND NOT rolcreaterole
      AND NOT rolreplication
      AND NOT rolbypassrls
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'login de autorização não elegível';
  END IF;

  v_expected_role := CASE p_expected_principal_group
    WHEN 'api' THEN 'dnex_gestao_api'::name
    WHEN 'fiscal_worker' THEN 'dnex_gestao_fiscal_worker'::name
    WHEN 'outbox_worker' THEN 'dnex_gestao_outbox_worker'::name
    WHEN 'context_issuer' THEN 'dnex_gestao_context_issuer'::name
    WHEN 'producer' THEN 'dnex_gestao_producer'::name
    WHEN 'folha_worker' THEN 'dnex_gestao_folha_worker'::name
  END;

  WITH RECURSIVE membership_closure(role_oid) AS (
    SELECT membership.roleid
    FROM pg_catalog.pg_auth_members AS membership
    JOIN pg_catalog.pg_roles AS login ON login.oid = membership.member
    WHERE login.rolname = p_login::text
    UNION
    SELECT membership.roleid
    FROM membership_closure AS closure
    JOIN pg_catalog.pg_auth_members AS membership
      ON membership.member = closure.role_oid
  )
  SELECT
    pg_catalog.count(*),
    pg_catalog.count(*) FILTER (
      WHERE granted_role.rolname = v_expected_role::text
    )
  INTO v_reachable_memberships, v_expected_memberships
  FROM membership_closure AS closure
  JOIN pg_catalog.pg_roles AS granted_role
    ON granted_role.oid = closure.role_oid;

  IF v_reachable_memberships <> 1
     OR v_expected_memberships <> 1 THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'principal fora da allowlist estrita de membership';
  END IF;
END
$function$;

-- gestao 0006:331-356
CREATE OR REPLACE FUNCTION gestao_auth.is_active_scope_v1(
  p_account_id uuid,
  p_legal_entity_id uuid,
  p_branch_id uuid
)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
VOLATILE
SET search_path = pg_catalog, gestao_finance
SET row_security = on
AS $function$
  SELECT
    p_account_id IS NOT NULL
    AND p_legal_entity_id IS NOT NULL
    AND p_branch_id IS NOT NULL
    AND EXISTS (
      SELECT 1
      FROM gestao_finance.enterprise_scope_registry AS scope
      WHERE scope.account_id = p_account_id
        AND scope.legal_entity_id = p_legal_entity_id
        AND scope.branch_id = p_branch_id
        AND scope.status = 'active'
        AND scope.deprovisioned_at IS NULL
    );
$function$;

-- gestao 0006:477-558
CREATE OR REPLACE FUNCTION gestao_auth.begin_request(
  p_assertion_id uuid,
  p_context_nonce uuid,
  p_correlation_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
VOLATILE
SET search_path = pg_catalog, gestao_auth
SET row_security = on
AS $function$
DECLARE
  v_now timestamptz := pg_catalog.statement_timestamp();
  v_assertion gestao_auth.access_assertion%ROWTYPE;
BEGIN
  IF p_assertion_id IS NULL OR p_context_nonce IS NULL OR p_correlation_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'contexto incompleto';
  END IF;

  IF NULLIF(pg_catalog.current_setting('dnex.context_nonce', true), '') IS NOT NULL THEN
    RAISE EXCEPTION USING ERRCODE = '25000', MESSAGE = 'a transação já possui contexto';
  END IF;

  SELECT assertion.*
  INTO v_assertion
  FROM gestao_auth.access_assertion AS assertion
  WHERE assertion.assertion_id = p_assertion_id
    AND assertion.runtime_session_user = session_user
    AND assertion.consumed_at IS NULL
    AND assertion.revoked_at IS NULL
    AND assertion.issued_at <= v_now
    AND assertion.expires_at > v_now
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'asserção ausente, expirada, consumida ou incompatível';
  END IF;

  PERFORM gestao_auth.assert_authorization_principal_v1(
    session_user, v_assertion.principal_group
  );

  IF NOT gestao_auth.is_active_scope_v1(
    v_assertion.account_id,
    v_assertion.legal_entity_id,
    v_assertion.branch_id
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'escopo empresarial ausente ou inativo';
  END IF;

  UPDATE gestao_auth.access_assertion AS assertion
  SET consumed_at = v_now
  WHERE assertion.assertion_id = v_assertion.assertion_id
    AND assertion.consumed_at IS NULL
  RETURNING assertion.* INTO v_assertion;

  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'asserção já consumida';
  END IF;

  INSERT INTO gestao_auth.request_context (
    context_nonce, assertion_id, runtime_session_user, backend_pid,
    transaction_id, subject_id, subject_type, principal_group, account_id,
    legal_entity_id, branch_id, permissions, correlation_id, created_at,
    expires_at
  ) VALUES (
    p_context_nonce, v_assertion.assertion_id, session_user,
    pg_catalog.pg_backend_pid(), pg_catalog.txid_current(),
    v_assertion.subject_id, v_assertion.subject_type,
    v_assertion.principal_group, v_assertion.account_id,
    v_assertion.legal_entity_id, v_assertion.branch_id,
    v_assertion.permissions, p_correlation_id, v_now, v_assertion.expires_at
  );

  PERFORM pg_catalog.set_config('dnex.context_nonce', p_context_nonce::text, true);
END
$function$;

-- has_permission — usada em 0014:247 (mask_cpf). A lista fechada de permissões
-- do gestao (0007:666-690) não tem nenhuma permissão da Folha: 'folha.read'
-- devolve false lá, e aqui também.
CREATE OR REPLACE FUNCTION gestao_auth.has_permission(
  p_permission text,
  p_account_id uuid,
  p_legal_entity_id uuid,
  p_branch_id uuid
) RETURNS boolean
LANGUAGE sql STABLE
AS $$
  SELECT false;
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA gestao_auth FROM PUBLIC;
-- No gestao (0001:763-766) begin_request é concedida aos papéis de grupo.
GRANT USAGE ON SCHEMA gestao_auth TO dnex_gestao_folha_worker;
GRANT EXECUTE ON FUNCTION gestao_auth.begin_request(uuid, uuid, uuid) TO dnex_gestao_folha_worker;

-- ---------------------------------------------------------------------------
-- 4. Extensão pgTAP (para testes)
-- ---------------------------------------------------------------------------

-- Exigido por: todos os tests/folha/*.pgtap.sql (SELECT plan(), ok(), is(), etc.)
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- O login de teste executa asserções do pgTAP nos arquivos que rodam inteiros sob o
-- protocolo de contexto (testes do motor).
GRANT USAGE ON SCHEMA extensions TO dnex_folha_ci_login;

COMMIT;
