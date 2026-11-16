-- DNEX Folha — Bootstrap mínimo para replay das migrations 0014..0029 em CI.
-- Cria SOMENTE objetos externos ao repositório que as migrations referenciam.
-- Cada stub tem comentário com a origem que o exige.
-- NÃO usar em produção; apenas para testes de replay do zero.
--
-- Este arquivo é aplicado com psql -f (ver replay.sh): no fim ele inclui, com \ir, a cópia
-- byte a byte da migration candidata do dnex-gestao que cria o schema gestao_folha.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Roles exigidas pelas migrations
-- ---------------------------------------------------------------------------

-- anon, authenticated, service_role: roles padrão do Supabase/PostgREST
-- Exigidas por: 0014:20 (REVOKE ... FROM PUBLIC, authenticated, service_role)
--               0014:344 (REVOKE ALL ON ALL TABLES ... FROM PUBLIC, authenticated, service_role)
--               0018:37,74 (REVOKE ... FROM PUBLIC, authenticated, service_role)
--               0022 (REVOKE ... FROM PUBLIC, anon, authenticated)
--               0029 (GRANT EXECUTE das funções do Portal só a authenticated)
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

-- Papéis do núcleo de autorização do dnex-gestao (0000_reserved_roles_preflight e 0001):
--   dnex_gestao_auth_owner      dono NOLOGIN das funções de gestao_auth e de gestao_folha
--   dnex_gestao_context_issuer  grupo NOLOGIN do emissor de asserções
--   dnex_gestao_api             grupo NOLOGIN do runtime da API
-- Exigidos por: tests/ci/gestao_folha_0015_candidate.sql (pré-condição) e pela migration 0028
-- (EXECUTE das funções folha.*_v1 para dnex_gestao_api).
DO $$
DECLARE
  v_papel text;
BEGIN
  FOREACH v_papel IN ARRAY ARRAY['dnex_gestao_auth_owner', 'dnex_gestao_context_issuer', 'dnex_gestao_api']
  LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_papel) THEN
      EXECUTE format('CREATE ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS', v_papel);
    END IF;
  END LOOP;
END
$$;

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

-- Logins de teste. O protocolo do gestao_auth vincula o contexto ao session_user, que precisa
-- ser um LOGIN sem atributos cuja closure de memberships é EXATAMENTE o papel do grupo:
--   dnex_folha_ci_login    runtime: membro só de dnex_gestao_api (contrato do contexto da Folha,
--                          seção 3). Até a migration 0027 este login era membro do worker; pelo
--                          contrato, login que seja membro de dnex_gestao_folha_worker não abre
--                          contexto da Folha, então ele deixou de ser.
--   dnex_folha_ci_emissor  emissor: membro só de dnex_gestao_context_issuer.
-- Os testes assumem estes logins com SET LOCAL SESSION AUTHORIZATION (sem senha: ninguém
-- conecta com eles).
DO $$
DECLARE
  v_login text;
BEGIN
  FOREACH v_login IN ARRAY ARRAY['dnex_folha_ci_login', 'dnex_folha_ci_emissor']
  LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_login) THEN
      EXECUTE format('CREATE ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS INHERIT', v_login);
    END IF;
  END LOOP;
END
$$;
-- Banco reaproveitado de um replay anterior à 0028 (papéis são do cluster): tira a membership antiga.
REVOKE dnex_gestao_folha_worker FROM dnex_folha_ci_login;
GRANT dnex_gestao_api TO dnex_folha_ci_login;
GRANT dnex_gestao_context_issuer TO dnex_folha_ci_emissor;

-- ---------------------------------------------------------------------------
-- 2. Schema extensions (para pgcrypto)
-- ---------------------------------------------------------------------------

-- Exigido por: 0014:27 (CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions)
CREATE SCHEMA IF NOT EXISTS extensions;

-- ---------------------------------------------------------------------------
-- 3. Núcleo de autorização do gestao_auth (reprodução para CI)
--
-- Fonte: dnex-gestao, migrations 0001_auth_context, 0006_authorization_hardening
-- e 0007_producer_principal (previews). O que está aqui reproduz o protocolo, não o
-- substitui:
--   1. o emissor (login estrito de dnex_gestao_context_issuer) registra uma asserção
--      (access_assertion), curta e de uso único, vinculada ao login que vai usá-la;
--   2. o login chama begin_request(assertion_id, context_nonce, correlation_id):
--      a asserção é CONSUMIDA e nasce uma linha em request_context, presa a
--      session_user + PID do backend + txid; o GUC dnex.context_nonce recebe a
--      chave dessa linha (não o assertion_id);
--   3. a leitura revalida tudo isso a cada uso (has_permission e require_folha_context_v1).
--
-- Reproduzido como no gestao: donos (tabelas do data_owner, funções do auth_owner), RLS com
-- FORCE e policies das duas tabelas, CHECKs de grupo e de whitelist de permissões (0007:315-349),
-- register_assertion (0007:534-662), has_permission (0007:666-745), begin_request
-- (0006:477-558), assert_authorization_principal_v1 (0007:448-530), is_active_scope_v1
-- (0006:331-356) e os GRANTs de 0001:746-770.
--
-- Diferenças declaradas em relação ao gestao:
--   a) só existem aqui os papéis de grupo api e context_issuer; fiscal_worker, outbox_worker e
--      producer não são criados (as funções os citam, e recusam quem os pedir);
--   b) gestao_auth.producer_registry existe vazia e só com as colunas que register_assertion
--      lê (o PL/pgSQL planeja a expressão inteira, mesmo sem entrar no ramo 'producer');
--   c) gestao_finance tem só enterprise_scope_registry, com as colunas lidas;
--   d) access_assertion.registered_by tem DEFAULT current_user para os testes que gravam
--      asserção direto como superusuário (cenários negativos);
--   e) os pós-voos de ACL e de default privileges das previews não são reproduzidos;
--   f) CHECKs não reproduzidos: access_assertion_permissions_shape_check e, em request_context,
--      subject_type, permissions_shape e permission_whitelist (as funções copiadas validam o
--      mesmo antes de gravar); índices de expiração não criados;
--   g) os papéis do gestao são NOINHERIT lá; aqui ficam com o padrão (as funções conferem a
--      closure de memberships, não a herança);
--   h) não existem as policies e GRANTs de leitura de dnex_gestao_finance_function_owner nem a
--      policy de leitura da API em enterprise_scope_registry (a Folha não lê gestao_finance).
--   i) ATENÇÃO, diferença de SEGURANÇA: no dnex-gestao (main de87a55 e previews 0006/0007) as
--      funções SECURITY DEFINER de gestao_auth têm search_path "pg_catalog, gestao_auth", SEM
--      pg_temp no fim. A revisão de 15/11 provou que, assim, quem tem SQL livre com o login
--      de aplicação roda código como dnex_gestao_auth_owner (domínio pg_temp.text) e reescreve
--      a própria asserção e a claim da Folha. A migration 0028 recusa aplicar nesse estado
--      (pré-condição 0.3.1). Para o CI poder aplicar e testar a 0028, AQUI as cópias recebem
--      ", pg_temp" logo depois de criadas. Isto NÃO descreve o gestao real: é a correção
--      que falta lá.
-- O schema gestao_folha (seção 7) NÃO é reprodução: é a migration do gestao, byte a byte.
-- O grupo 'folha_worker' e a permissão 'folha.ci', que existiam só neste bootstrap até a
-- migration 0027, foram REMOVIDOS: o contexto da Folha passou a ser a claim de gestao_folha.
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS gestao_auth;
CREATE SCHEMA IF NOT EXISTS gestao_finance;
REVOKE ALL ON SCHEMA gestao_auth FROM PUBLIC;
REVOKE ALL ON SCHEMA gestao_finance FROM PUBLIC;
-- gestao 0001:79 e 239: o data owner (dono das tabelas) fica com USAGE; as checagens de chave
-- estrangeira rodam como ele.
GRANT USAGE ON SCHEMA gestao_auth TO dnex_gestao_data_owner;

-- gestao 0006: registro de escopos empresariais ativos (só as colunas lidas).
CREATE TABLE IF NOT EXISTS gestao_finance.enterprise_scope_registry (
  account_id uuid NOT NULL,
  legal_entity_id uuid NOT NULL,
  branch_id uuid NOT NULL,
  status text NOT NULL DEFAULT 'active',
  deprovisioned_at timestamptz,
  PRIMARY KEY (account_id, legal_entity_id, branch_id)
);
ALTER TABLE gestao_finance.enterprise_scope_registry OWNER TO dnex_gestao_data_owner;
ALTER TABLE gestao_finance.enterprise_scope_registry ENABLE ROW LEVEL SECURITY;
ALTER TABLE gestao_finance.enterprise_scope_registry FORCE ROW LEVEL SECURITY;
REVOKE ALL ON gestao_finance.enterprise_scope_registry FROM PUBLIC;
-- gestao 0006:231-241
CREATE POLICY enterprise_scope_registry_auth_owner_select_policy
  ON gestao_finance.enterprise_scope_registry
  FOR SELECT TO dnex_gestao_auth_owner
  USING (true);
GRANT USAGE ON SCHEMA gestao_finance TO dnex_gestao_auth_owner;
GRANT SELECT ON gestao_finance.enterprise_scope_registry TO dnex_gestao_auth_owner;

-- gestao 0001:94-153, com os CHECKs de grupo e whitelist da 0007:315-349
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
    CHECK (principal_group IN ('api', 'fiscal_worker', 'outbox_worker', 'producer')),
  CONSTRAINT access_assertion_permission_whitelist_check
    CHECK (
      (
        principal_group = 'api'
        AND subject_type = 'user'
        AND permissions <@ ARRAY[
          'finance.read',
          'finance.settle',
          'finance.reconcile',
          'finance.category.manage'
        ]::text[]
      )
      OR (
        principal_group = 'fiscal_worker'
        AND subject_type IN ('system', 'integration')
        AND permissions <@ ARRAY['integration.fiscal.ingest']::text[]
      )
      OR (
        principal_group = 'outbox_worker'
        AND subject_type IN ('system', 'integration')
        AND permissions <@ ARRAY['integration.outbox.dispatch']::text[]
      )
      OR (
        principal_group = 'producer'
        AND subject_type = 'integration'
        AND permissions <@ ARRAY['finance.receivable.originate']::text[]
      )
    ),
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
  CONSTRAINT request_context_group_check
    CHECK (principal_group IN ('api', 'fiscal_worker', 'outbox_worker', 'producer')),
  CONSTRAINT request_context_expiry_check
    CHECK (expires_at > created_at AND expires_at <= created_at + interval '5 minutes')
);

-- gestao 0007: registro de produtores (diferença b: vazia, só as colunas lidas).
CREATE TABLE IF NOT EXISTS gestao_auth.producer_registry (
  runtime_login name PRIMARY KEY,
  subject_id uuid NOT NULL,
  status text NOT NULL
);
ALTER TABLE gestao_auth.producer_registry OWNER TO dnex_gestao_data_owner;
REVOKE ALL ON gestao_auth.producer_registry FROM PUBLIC;
GRANT SELECT ON gestao_auth.producer_registry TO dnex_gestao_auth_owner;

-- gestao 0001:235-293: o data owner possui as tabelas; o auth owner possui só as funções e
-- recebe o DML mínimo, sob RLS com FORCE.
ALTER TABLE gestao_auth.access_assertion OWNER TO dnex_gestao_data_owner;
ALTER TABLE gestao_auth.request_context OWNER TO dnex_gestao_data_owner;
ALTER TABLE gestao_auth.access_assertion ENABLE ROW LEVEL SECURITY;
ALTER TABLE gestao_auth.access_assertion FORCE ROW LEVEL SECURITY;
ALTER TABLE gestao_auth.request_context ENABLE ROW LEVEL SECURITY;
ALTER TABLE gestao_auth.request_context FORCE ROW LEVEL SECURITY;

CREATE POLICY access_assertion_register_policy
  ON gestao_auth.access_assertion
  FOR INSERT
  TO dnex_gestao_auth_owner
  WITH CHECK (
    registered_by = session_user
    AND pg_catalog.pg_has_role(
      session_user,
      'dnex_gestao_context_issuer'::name,
      'MEMBER'
    )
  );

CREATE POLICY access_assertion_auth_select_policy
  ON gestao_auth.access_assertion
  FOR SELECT
  TO dnex_gestao_auth_owner
  USING (true);

CREATE POLICY access_assertion_auth_update_policy
  ON gestao_auth.access_assertion
  FOR UPDATE
  TO dnex_gestao_auth_owner
  USING (true)
  WITH CHECK (true);

CREATE POLICY request_context_auth_insert_policy
  ON gestao_auth.request_context
  FOR INSERT
  TO dnex_gestao_auth_owner
  WITH CHECK (true);

CREATE POLICY request_context_auth_select_policy
  ON gestao_auth.request_context
  FOR SELECT
  TO dnex_gestao_auth_owner
  USING (true);

REVOKE ALL ON gestao_auth.access_assertion FROM PUBLIC;
REVOKE ALL ON gestao_auth.request_context FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE ON gestao_auth.access_assertion
  TO dnex_gestao_auth_owner;
GRANT SELECT, INSERT ON gestao_auth.request_context
  TO dnex_gestao_auth_owner;

-- gestao 0007:448-530 (cópia; os papéis fiscal_worker, outbox_worker e producer não existem
-- neste banco, então quem os pedir cai em "principal fora da allowlist").
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
       'api', 'fiscal_worker', 'outbox_worker', 'context_issuer', 'producer'
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
  END;

  -- Não basta rejeitar atributos rol*. A closure completa precisa ser a
  -- singleton {papel principal esperado}; qualquer role comum ou predefinida
  -- (inclusive pg_execute_server_program), direta ou por pontes NOINHERIT,
  -- torna o principal inelegível.
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
      MESSAGE = 'principal fora da allowlist estrita de membership; pg_execute_server_program é proibido';
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

-- gestao 0007:534-662 (cópia)
CREATE OR REPLACE FUNCTION gestao_auth.register_assertion(
  p_assertion_id uuid,
  p_subject_id uuid,
  p_subject_type text,
  p_principal_group text,
  p_runtime_session_user name,
  p_account_id uuid,
  p_legal_entity_id uuid,
  p_branch_id uuid,
  p_permissions text[],
  p_expires_at timestamptz
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
  v_allowed_permissions text[];
  v_permissions text[];
BEGIN
  PERFORM gestao_auth.assert_authorization_principal_v1(
    session_user, 'context_issuer'
  );

  IF p_assertion_id IS NULL
     OR p_subject_id IS NULL
     OR p_runtime_session_user IS NULL
     OR p_account_id IS NULL
     OR p_legal_entity_id IS NULL
     OR p_branch_id IS NULL
     OR p_expires_at IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'asserção incompleta';
  END IF;

  CASE p_principal_group
    WHEN 'api' THEN
      IF p_subject_type <> 'user' THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'subject incompatível com grupo';
      END IF;
      v_allowed_permissions := ARRAY[
        'finance.read', 'finance.settle', 'finance.reconcile',
        'finance.category.manage'
      ]::text[];
    WHEN 'fiscal_worker' THEN
      IF p_subject_type NOT IN ('system', 'integration') THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'subject incompatível com grupo';
      END IF;
      v_allowed_permissions := ARRAY['integration.fiscal.ingest']::text[];
    WHEN 'outbox_worker' THEN
      IF p_subject_type NOT IN ('system', 'integration') THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'subject incompatível com grupo';
      END IF;
      v_allowed_permissions := ARRAY['integration.outbox.dispatch']::text[];
    WHEN 'producer' THEN
      IF p_subject_type IS DISTINCT FROM 'integration' THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'subject incompatível com grupo';
      END IF;
      v_allowed_permissions := ARRAY['finance.receivable.originate']::text[];
    ELSE
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'grupo de principal não permitido';
  END CASE;

  PERFORM gestao_auth.assert_authorization_principal_v1(
    p_runtime_session_user, p_principal_group
  );

  -- Produtor: o subject precisa ser exatamente o registrado para o login
  -- runtime ativo (fonte única, ADR-0014 §1). O product_key nunca vem da
  -- asserção; o comando o deriva do login por current_producer_v1().
  IF p_principal_group = 'producer' AND NOT EXISTS (
    SELECT 1
    FROM gestao_auth.producer_registry AS registry
    WHERE registry.runtime_login = p_runtime_session_user
      AND registry.status = 'active'
      AND registry.subject_id = p_subject_id
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'produtor não registrado, inativo ou com subject divergente';
  END IF;

  IF NOT gestao_auth.is_active_scope_v1(
    p_account_id, p_legal_entity_id, p_branch_id
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = '42501',
      MESSAGE = 'escopo empresarial ausente ou inativo';
  END IF;

  IF p_permissions IS NULL
     OR pg_catalog.cardinality(p_permissions) = 0
     OR pg_catalog.array_ndims(p_permissions) <> 1
     OR pg_catalog.array_position(p_permissions, NULL) IS NOT NULL
     OR EXISTS (
       SELECT 1
       FROM pg_catalog.unnest(p_permissions) AS permission(value)
       WHERE value = ''
     ) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'lista de permissões inválida';
  END IF;

  SELECT pg_catalog.array_agg(DISTINCT value ORDER BY value)
  INTO v_permissions
  FROM pg_catalog.unnest(p_permissions) AS permission(value);

  IF pg_catalog.cardinality(v_permissions) <> pg_catalog.cardinality(p_permissions)
     OR NOT (v_permissions <@ v_allowed_permissions) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'permissão fora da whitelist do grupo';
  END IF;

  IF p_expires_at <= v_now OR p_expires_at > v_now + interval '5 minutes' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'expiração da asserção fora do limite';
  END IF;

  INSERT INTO gestao_auth.access_assertion (
    assertion_id, subject_id, subject_type, principal_group,
    runtime_session_user, account_id, legal_entity_id, branch_id,
    permissions, issued_at, expires_at, consumed_at, revoked_at, registered_by
  ) VALUES (
    p_assertion_id, p_subject_id, p_subject_type, p_principal_group,
    p_runtime_session_user, p_account_id, p_legal_entity_id, p_branch_id,
    v_permissions, v_now, p_expires_at, NULL, NULL, session_user
  );
END
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

-- gestao 0007:666-745 (cópia). A lista fechada não tem permissão da Folha: 'folha.read'
-- devolve false aqui, como lá (folha.mask_cpf, 0014:247, continua mascarando).
CREATE OR REPLACE FUNCTION gestao_auth.has_permission(
  p_permission text,
  p_account_id uuid,
  p_legal_entity_id uuid,
  p_branch_id uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
VOLATILE
SET search_path = pg_catalog, gestao_auth
SET row_security = on
AS $function$
DECLARE
  v_nonce_text text;
  v_context_nonce uuid;
  v_principal_group text;
BEGIN
  IF p_permission IS NULL
     OR p_account_id IS NULL
     OR p_legal_entity_id IS NULL
     OR p_branch_id IS NULL
     OR p_permission NOT IN (
       'finance.read', 'finance.settle', 'finance.reconcile',
       'finance.category.manage', 'finance.receivable.originate',
       'integration.fiscal.ingest', 'integration.outbox.dispatch'
     ) THEN
    RETURN false;
  END IF;

  v_nonce_text := NULLIF(pg_catalog.current_setting('dnex.context_nonce', true), '');
  IF v_nonce_text IS NULL THEN
    RETURN false;
  END IF;
  BEGIN
    v_context_nonce := v_nonce_text::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    RETURN false;
  END;

  SELECT context.principal_group
  INTO v_principal_group
  FROM gestao_auth.request_context AS context
  JOIN gestao_auth.access_assertion AS assertion
    ON assertion.assertion_id = context.assertion_id
  WHERE context.context_nonce = v_context_nonce
    AND context.runtime_session_user = session_user
    AND context.backend_pid = pg_catalog.pg_backend_pid()
    AND context.transaction_id = pg_catalog.txid_current()
    AND context.account_id = p_account_id
    AND context.legal_entity_id = p_legal_entity_id
    AND context.branch_id = p_branch_id
    AND p_permission = ANY (context.permissions)
    AND context.created_at <= pg_catalog.statement_timestamp()
    AND context.expires_at > pg_catalog.statement_timestamp()
    AND assertion.runtime_session_user = context.runtime_session_user
    AND assertion.subject_id = context.subject_id
    AND assertion.subject_type = context.subject_type
    AND assertion.principal_group = context.principal_group
    AND assertion.account_id = context.account_id
    AND assertion.legal_entity_id = context.legal_entity_id
    AND assertion.branch_id = context.branch_id
    AND assertion.permissions = context.permissions
    AND assertion.consumed_at = context.created_at
    AND assertion.revoked_at IS NULL
    AND assertion.expires_at > pg_catalog.statement_timestamp();

  IF NOT FOUND THEN
    RETURN false;
  END IF;

  PERFORM gestao_auth.assert_authorization_principal_v1(
    session_user, v_principal_group
  );

  RETURN gestao_auth.is_active_scope_v1(
    p_account_id, p_legal_entity_id, p_branch_id
  );
END
$function$;

-- Diferença (i): pg_temp no fim do search_path das cinco cópias (o gestao real não tem).
ALTER FUNCTION gestao_auth.assert_authorization_principal_v1(name, text) SET search_path = pg_catalog, gestao_auth, pg_temp;
ALTER FUNCTION gestao_auth.is_active_scope_v1(uuid, uuid, uuid) SET search_path = pg_catalog, gestao_finance, pg_temp;
ALTER FUNCTION gestao_auth.register_assertion(uuid, uuid, text, text, name, uuid, uuid, uuid, text[], timestamptz) SET search_path = pg_catalog, gestao_auth, pg_temp;
ALTER FUNCTION gestao_auth.begin_request(uuid, uuid, uuid) SET search_path = pg_catalog, gestao_auth, pg_temp;
ALTER FUNCTION gestao_auth.has_permission(text, uuid, uuid, uuid) SET search_path = pg_catalog, gestao_auth, pg_temp;

-- Donos e GRANTs como no gestao (0001:482-488, 626-628, 738-770; 0006:326-360; 0007:1253-1264).
ALTER FUNCTION gestao_auth.assert_authorization_principal_v1(name, text) OWNER TO dnex_gestao_auth_owner;
ALTER FUNCTION gestao_auth.is_active_scope_v1(uuid, uuid, uuid) OWNER TO dnex_gestao_auth_owner;
ALTER FUNCTION gestao_auth.register_assertion(uuid, uuid, text, text, name, uuid, uuid, uuid, text[], timestamptz) OWNER TO dnex_gestao_auth_owner;
ALTER FUNCTION gestao_auth.begin_request(uuid, uuid, uuid) OWNER TO dnex_gestao_auth_owner;
ALTER FUNCTION gestao_auth.has_permission(text, uuid, uuid, uuid) OWNER TO dnex_gestao_auth_owner;
ALTER SCHEMA gestao_auth OWNER TO dnex_gestao_auth_owner;
ALTER SCHEMA gestao_finance OWNER TO dnex_gestao_data_owner;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA gestao_auth FROM PUBLIC;
GRANT USAGE ON SCHEMA gestao_auth TO dnex_gestao_api, dnex_gestao_context_issuer;
GRANT USAGE ON SCHEMA gestao_finance TO dnex_gestao_api;
GRANT EXECUTE ON FUNCTION gestao_auth.register_assertion(
  uuid, uuid, text, text, name, uuid, uuid, uuid, text[], timestamptz
) TO dnex_gestao_context_issuer;
GRANT EXECUTE ON FUNCTION gestao_auth.begin_request(uuid, uuid, uuid) TO dnex_gestao_api;
GRANT EXECUTE ON FUNCTION gestao_auth.has_permission(text, uuid, uuid, uuid) TO dnex_gestao_api;

-- ---------------------------------------------------------------------------
-- 4. Identidade do usuário do Portal do Colaborador (reprodução para CI)
--
-- O empregado não é usuário do Hub: entra pelo serviço de autenticação do Supabase e chega
-- ao banco como o papel authenticated, com o identificador no claim `sub` do token, que o
-- PostgREST valida e grava nos parâmetros de requisição. auth.uid() abaixo é a definição
-- pública do Supabase para essa leitura, reproduzida de memória do projeto público
-- supabase/postgres; NÃO foi conferida contra o banco de produção do DNEX.
-- Exigido por: 0029 (funções do schema portal_api resolvem o empregado por auth.uid()).
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS auth;
GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid
LANGUAGE sql STABLE
AS $$
  select
    coalesce(
      nullif(current_setting('request.jwt.claim.sub', true), ''),
      (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
    )::uuid
$$;

-- ---------------------------------------------------------------------------
-- 5. Extensão pgTAP (para testes)
-- ---------------------------------------------------------------------------

-- Exigido por: todos os tests/folha/*.pgtap.sql (SELECT plan(), ok(), is(), etc.)
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;

-- Os logins e papéis de teste executam asserções do pgTAP nos arquivos que rodam sob o
-- protocolo de contexto (testes do motor) e sob o papel authenticated (testes do Portal).
GRANT USAGE ON SCHEMA extensions TO dnex_folha_ci_login, authenticated, anon;

-- ---------------------------------------------------------------------------
-- 6. Apoio dos testes (só CI): emissão de claim da Folha e espelho dos GRANTs do worker
--
-- dnex_folha_ci_apoio.emitir: registra uma asserção com claim da Folha pelo caminho REAL
--   (gestao_folha.register_folha_assertion_v1, com o login emissor). Validade padrão de 55 s:
--   o gestao recusa mais de 60 s.
-- dnex_folha_ci_apoio.espelhar_worker / desfazer_espelho: pelo contrato, a sessão de
--   aplicação é um login membro só de dnex_gestao_api, que NÃO tem GRANT nas tabelas da Folha
--   (em produção ela só executa as funções folha.*_v1). Os testes anteriores à 0028 gravam e
--   leem as tabelas diretamente com o login de teste, para exercer a RLS e os GRANTs do
--   worker. Para continuarem a fazê-lo, o login de teste recebe, DENTRO da transação do
--   teste (desfeita no fim), exatamente os privilégios que o worker tem naquele instante.
--   Nenhuma migration concede nada a dnex_folha_ci_login; os testes de ACL desfazem o espelho
--   antes de conferir.
-- Só superusuário chama estas funções (sem EXECUTE para PUBLIC).
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS dnex_folha_ci_apoio;
REVOKE ALL ON SCHEMA dnex_folha_ci_apoio FROM PUBLIC;

CREATE OR REPLACE FUNCTION dnex_folha_ci_apoio.emitir(
  p_assercao uuid,
  p_conta uuid,
  p_entidade uuid,
  p_filial uuid,
  p_permissoes text[] DEFAULT ARRAY['folha.read', 'folha.calculate', 'folha.close', 'folha.transmit', 'folha.admin'],
  p_subject uuid DEFAULT gen_random_uuid(),
  p_login name DEFAULT 'dnex_folha_ci_login',
  p_validade interval DEFAULT interval '55 seconds'
) RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  SET LOCAL SESSION AUTHORIZATION dnex_folha_ci_emissor;
  PERFORM gestao_folha.register_folha_assertion_v1(
    p_assercao, p_subject, p_login, p_conta, p_entidade, p_filial, p_permissoes,
    clock_timestamp() + p_validade);
  RESET SESSION AUTHORIZATION;
END
$$;

CREATE OR REPLACE FUNCTION dnex_folha_ci_apoio.desfazer_espelho() RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  IF to_regnamespace('folha') IS NULL THEN
    RETURN;
  END IF;
  REVOKE ALL ON ALL TABLES IN SCHEMA folha FROM dnex_folha_ci_login;
  REVOKE ALL ON ALL SEQUENCES IN SCHEMA folha FROM dnex_folha_ci_login;
  REVOKE ALL ON ALL FUNCTIONS IN SCHEMA folha FROM dnex_folha_ci_login;
  REVOKE ALL ON SCHEMA folha FROM dnex_folha_ci_login;
END
$$;

CREATE OR REPLACE FUNCTION dnex_folha_ci_apoio.espelhar_worker() RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  v record;
BEGIN
  PERFORM dnex_folha_ci_apoio.desfazer_espelho();
  IF has_schema_privilege('dnex_gestao_folha_worker', 'folha', 'USAGE') THEN
    GRANT USAGE ON SCHEMA folha TO dnex_folha_ci_login;
  END IF;
  FOR v IN
    SELECT c.oid::regclass::text AS objeto, string_agg(a.privilege_type, ', ') AS privilegios,
           CASE WHEN c.relkind = 'S' THEN 'SEQUENCE' ELSE 'TABLE' END AS especie
      FROM pg_class c
      CROSS JOIN LATERAL aclexplode(c.relacl) a
     WHERE c.relnamespace = 'folha'::regnamespace
       AND a.grantee = 'dnex_gestao_folha_worker'::regrole
     GROUP BY c.oid, c.relkind
  LOOP
    EXECUTE format('GRANT %s ON %s %s TO dnex_folha_ci_login', v.privilegios, v.especie, v.objeto);
  END LOOP;
  FOR v IN
    SELECT c.oid::regclass::text AS objeto, quote_ident(t.attname) AS coluna, a.privilege_type AS privilegio
      FROM pg_class c
      JOIN pg_attribute t ON t.attrelid = c.oid AND t.attacl IS NOT NULL
      CROSS JOIN LATERAL aclexplode(t.attacl) a
     WHERE c.relnamespace = 'folha'::regnamespace
       AND a.grantee = 'dnex_gestao_folha_worker'::regrole
  LOOP
    EXECUTE format('GRANT %s (%s) ON %s TO dnex_folha_ci_login', v.privilegio, v.coluna, v.objeto);
  END LOOP;
  FOR v IN
    SELECT p.oid::regprocedure::text AS objeto
      FROM pg_proc p
      CROSS JOIN LATERAL aclexplode(p.proacl) a
     WHERE p.pronamespace = 'folha'::regnamespace
       AND a.grantee = 'dnex_gestao_folha_worker'::regrole
       AND a.privilege_type = 'EXECUTE'
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO dnex_folha_ci_login', v.objeto);
  END LOOP;
END
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA dnex_folha_ci_apoio FROM PUBLIC;

COMMIT;

-- ---------------------------------------------------------------------------
-- 7. Schema gestao_folha: contexto de autorização do DNEX Folha
--
-- Cópia BYTE A BYTE de dnex-gestao, migrations/0015_folha_context_candidate.sql
-- (PR 144 do dnex-gestao, commit b0b98b1 da branch da frente; candidata, não aplicada em
-- nenhum ambiente). SHA-256 do arquivo:
--   212dd4b60bb5125dc0b85028a0a08d3c98dce0f96f3af93207e5f3eafbebbd24
-- gravado em tests/ci/gestao_folha_0015_candidate.sha256 e conferido por replay.sh antes de
-- aplicar. O arquivo tem BEGIN/COMMIT, pré-condições e pós-voo de ACL próprios, que rodam
-- aqui como rodariam lá. Se o dnex-gestao mudar a candidata, troque o arquivo e o hash juntos.
-- ---------------------------------------------------------------------------
\ir gestao_folha_0015_candidate.sql
