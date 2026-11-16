-- Folha context claim: all new objects isolated in gestao_folha; the gestao_auth
-- and gestao_finance catalogs (B1) and the services catalog stay exact.
-- Candidate only: no production execution is authorized by this file.
--
-- Model: lateral claim on the `api` principal group, as in 0012 (service orders).
-- The core assertion is registered by gestao_auth.register_assertion with group
-- `api`, subject `user` and exactly {finance.read}; the Folha permissions live
-- only in gestao_folha.folha_assertion_claim. No CHECK constraint, closed list or
-- function of gestao_auth is altered.
--
-- SEGREGATION OF DUTIES, OPEN DECISION: because the core assertion carries
-- finance.read, a Folha context also passes gestao_auth.has_permission for
-- finance.read on the same scope. Do not install before the owner decides
-- (docs/01-arquitetura/FOLHA-CONTEXTO-AUTORIZACAO.md, section 5).
--
-- Closed list of Folha permissions (every grant set must contain folha.read):
--   folha.read      read payroll data of the scope
--   folha.calculate create/recalculate payroll runs and life events
--   folha.close     close or reopen a payroll period
--   folha.transmit  hand eSocial/Reinf/accounting payloads to the outboxes
--   folha.admin     employer, establishment, rubric and parameter administration
BEGIN;
SET LOCAL lock_timeout='5s';

-- Preconditions: fail clean, before any DDL.
DO $precondition$
DECLARE v_missing text;
BEGIN
 SELECT pg_catalog.string_agg(x.name,', ') INTO v_missing FROM (VALUES
  ('role dnex_gestao_auth_owner',NOT EXISTS(SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='dnex_gestao_auth_owner')),
  ('role dnex_gestao_context_issuer',NOT EXISTS(SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='dnex_gestao_context_issuer')),
  ('role dnex_gestao_api',NOT EXISTS(SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='dnex_gestao_api')),
  ('gestao_auth.access_assertion',pg_catalog.to_regclass('gestao_auth.access_assertion') IS NULL),
  ('gestao_auth.request_context',pg_catalog.to_regclass('gestao_auth.request_context') IS NULL),
  ('gestao_auth.register_assertion',pg_catalog.to_regprocedure('gestao_auth.register_assertion(uuid,uuid,text,text,name,uuid,uuid,uuid,text[],timestamptz)') IS NULL),
  ('gestao_auth.assert_authorization_principal_v1',pg_catalog.to_regprocedure('gestao_auth.assert_authorization_principal_v1(name,text)') IS NULL),
  ('gestao_auth.is_active_scope_v1',pg_catalog.to_regprocedure('gestao_auth.is_active_scope_v1(uuid,uuid,uuid)') IS NULL)
 ) AS x(name,absent) WHERE x.absent;
 IF v_missing IS NOT NULL THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='0015: missing authorization foundation: '||v_missing;END IF;
 IF pg_catalog.to_regnamespace('gestao_folha') IS NOT NULL THEN RAISE EXCEPTION USING ERRCODE='42P06',MESSAGE='0015: schema gestao_folha already exists; refusing adoption';END IF;
END $precondition$;

CREATE SCHEMA gestao_folha;
-- Same installer ownership as gestao_services. Assertion owner, issuer and
-- runtime receive USAGE only, never schema CREATE.
ALTER SCHEMA gestao_folha OWNER TO postgres;
REVOKE ALL ON SCHEMA gestao_folha FROM PUBLIC;
GRANT USAGE ON SCHEMA gestao_folha TO dnex_gestao_auth_owner,dnex_gestao_context_issuer,dnex_gestao_api;

CREATE TABLE gestao_folha.folha_assertion_claim (
 assertion_id uuid PRIMARY KEY,subject_id uuid NOT NULL,runtime_session_user name NOT NULL,
 account_id uuid NOT NULL,legal_entity_id uuid NOT NULL,branch_id uuid NOT NULL,
 core_permissions text[] NOT NULL,folha_permissions text[] NOT NULL,expires_at timestamptz NOT NULL,
 registered_by name NOT NULL,registered_at timestamptz NOT NULL,
 CONSTRAINT folha_assertion_claim_core_check CHECK(core_permissions=ARRAY['finance.read']::text[]),
 CONSTRAINT folha_assertion_claim_permissions_check CHECK(
  pg_catalog.array_ndims(folha_permissions)=1 AND pg_catalog.cardinality(folha_permissions) BETWEEN 1 AND 5
  AND pg_catalog.array_position(folha_permissions,NULL) IS NULL
  AND folha_permissions<@ARRAY['folha.admin','folha.calculate','folha.close','folha.read','folha.transmit']::text[]
  AND 'folha.read'=ANY(folha_permissions)),
 CONSTRAINT folha_assertion_claim_expiry_check CHECK(expires_at>registered_at AND expires_at<=registered_at+interval '60 seconds')
);
REVOKE ALL ON TABLE gestao_folha.folha_assertion_claim FROM PUBLIC;
ALTER TABLE gestao_folha.folha_assertion_claim OWNER TO dnex_gestao_auth_owner;
ALTER TABLE gestao_folha.folha_assertion_claim ENABLE ROW LEVEL SECURITY;
ALTER TABLE gestao_folha.folha_assertion_claim FORCE ROW LEVEL SECURITY;
CREATE POLICY assertion_owner ON gestao_folha.folha_assertion_claim TO dnex_gestao_auth_owner USING(true) WITH CHECK(true);

-- Issue: only a strict context-issuer login. The runtime login, the scope and the
-- subject are validated by the core register_assertion; this function adds the
-- Folha grant set and binds it to the exact core assertion row.
CREATE FUNCTION gestao_folha.register_folha_assertion_v1(p_assertion_id uuid,p_subject_id uuid,p_runtime_login name,p_account_id uuid,p_legal_entity_id uuid,p_branch_id uuid,p_folha_permissions text[],p_expires_at timestamptz) RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET row_security=on AS $fn$
DECLARE
 v_core CONSTANT pg_catalog.text[]:=ARRAY['finance.read']::pg_catalog.text[];
 v_allowed CONSTANT pg_catalog.text[]:=ARRAY['folha.admin','folha.calculate','folha.close','folha.read','folha.transmit']::pg_catalog.text[];
 v_permissions pg_catalog.text[];
 v_now pg_catalog.timestamptz:=pg_catalog.clock_timestamp();
BEGIN
 PERFORM gestao_auth.assert_authorization_principal_v1(session_user,'context_issuer');
 IF p_assertion_id IS NULL OR p_subject_id IS NULL OR p_runtime_login IS NULL OR p_account_id IS NULL OR p_legal_entity_id IS NULL OR p_branch_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Folha assertion incomplete';END IF;
 IF p_expires_at IS NULL OR p_expires_at<=v_now OR p_expires_at>v_now+interval '60 seconds' THEN RAISE EXCEPTION USING ERRCODE='22023',MESSAGE='Folha assertion expiry out of range';END IF;
 IF p_folha_permissions IS NULL OR pg_catalog.array_ndims(p_folha_permissions) IS DISTINCT FROM 1 OR pg_catalog.array_position(p_folha_permissions,NULL) IS NOT NULL THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Invalid Folha grant set';END IF;
 SELECT pg_catalog.array_agg(DISTINCT x.v ORDER BY x.v) INTO v_permissions FROM pg_catalog.unnest(p_folha_permissions) AS x(v);
 IF pg_catalog.cardinality(v_permissions)<>pg_catalog.cardinality(p_folha_permissions) OR NOT(v_permissions<@v_allowed) OR NOT('folha.read'=ANY(v_permissions)) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Invalid Folha grant set';END IF;
 PERFORM gestao_auth.register_assertion(p_assertion_id,p_subject_id,'user','api',p_runtime_login,p_account_id,p_legal_entity_id,p_branch_id,v_core,p_expires_at);
 IF NOT EXISTS(SELECT 1 FROM gestao_auth.access_assertion a WHERE a.assertion_id=p_assertion_id AND a.subject_id=p_subject_id AND a.subject_type='user' AND a.principal_group='api' AND a.runtime_session_user=p_runtime_login AND (a.account_id,a.legal_entity_id,a.branch_id)=(p_account_id,p_legal_entity_id,p_branch_id) AND a.permissions=v_core AND a.expires_at=p_expires_at AND a.issued_at<=pg_catalog.clock_timestamp() AND a.expires_at>pg_catalog.clock_timestamp() AND a.revoked_at IS NULL AND a.consumed_at IS NULL AND a.registered_by=session_user) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Assertion binding failed';END IF;
 INSERT INTO gestao_folha.folha_assertion_claim(assertion_id,subject_id,runtime_session_user,account_id,legal_entity_id,branch_id,core_permissions,folha_permissions,expires_at,registered_by,registered_at)
 VALUES(p_assertion_id,p_subject_id,p_runtime_login,p_account_id,p_legal_entity_id,p_branch_id,v_core,v_permissions,p_expires_at,session_user,v_now);
END $fn$;
REVOKE ALL ON FUNCTION gestao_folha.register_folha_assertion_v1(uuid,uuid,name,uuid,uuid,uuid,text[],timestamptz) FROM PUBLIC;
ALTER FUNCTION gestao_folha.register_folha_assertion_v1(uuid,uuid,name,uuid,uuid,uuid,text[],timestamptz) OWNER TO dnex_gestao_auth_owner;

-- Consume: returns the scope of the transaction context only when the request
-- context of this login/PID/transaction comes from an assertion that carries a
-- Folha claim with the requested permission. Any mismatch raises 42501.
CREATE FUNCTION gestao_folha.require_folha_context_v1(p_permission text) RETURNS TABLE(account_id uuid,legal_entity_id uuid,branch_id uuid,subject_id uuid) LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,pg_temp SET row_security=on AS $fn$
DECLARE
 v_nonce pg_catalog.uuid;
 v_txid pg_catalog.int8;
 v_claim gestao_folha.folha_assertion_claim%ROWTYPE;
BEGIN
 IF p_permission IS NULL OR p_permission NOT IN ('folha.read','folha.calculate','folha.close','folha.transmit','folha.admin') THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Invalid Folha permission';END IF;
 BEGIN v_nonce:=NULLIF(pg_catalog.current_setting('dnex.context_nonce',true),'')::pg_catalog.uuid;EXCEPTION WHEN invalid_text_representation THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Invalid Folha context';END;
 -- begin_request assigns the transaction id; a transaction without one has no context.
 v_txid:=pg_catalog.txid_current_if_assigned();
 IF v_nonce IS NULL OR v_txid IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Folha assertion missing, expired or revoked';END IF;
 SELECT s.* INTO v_claim FROM gestao_folha.folha_assertion_claim s JOIN gestao_auth.request_context x ON x.assertion_id=s.assertion_id JOIN gestao_auth.access_assertion a ON a.assertion_id=x.assertion_id
 WHERE x.context_nonce=v_nonce AND x.runtime_session_user=session_user AND x.backend_pid=pg_catalog.pg_backend_pid() AND x.transaction_id=v_txid
 AND x.subject_type='user' AND x.principal_group='api' AND x.created_at<=pg_catalog.clock_timestamp() AND x.expires_at>pg_catalog.clock_timestamp()
 AND a.runtime_session_user=x.runtime_session_user AND a.subject_id=x.subject_id AND a.subject_type=x.subject_type AND a.principal_group=x.principal_group
 AND (a.account_id,a.legal_entity_id,a.branch_id)=(x.account_id,x.legal_entity_id,x.branch_id) AND a.permissions=x.permissions
 AND a.consumed_at=x.created_at AND a.revoked_at IS NULL AND a.expires_at>pg_catalog.clock_timestamp() AND a.expires_at=x.expires_at
 AND s.subject_id=a.subject_id AND s.runtime_session_user=a.runtime_session_user AND (s.account_id,s.legal_entity_id,s.branch_id)=(a.account_id,a.legal_entity_id,a.branch_id)
 AND s.core_permissions=a.permissions AND s.expires_at=a.expires_at AND s.expires_at>pg_catalog.clock_timestamp() AND s.registered_by=a.registered_by
 AND p_permission=ANY(s.folha_permissions) AND 'folha.read'=ANY(s.folha_permissions) AND 'finance.read'=ANY(x.permissions);
 IF v_claim.assertion_id IS NULL THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Folha assertion missing, expired or revoked';END IF;
 PERFORM gestao_auth.assert_authorization_principal_v1(session_user,'api');
 IF NOT gestao_auth.is_active_scope_v1(v_claim.account_id,v_claim.legal_entity_id,v_claim.branch_id) THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='Inactive Folha scope';END IF;
 account_id:=v_claim.account_id;legal_entity_id:=v_claim.legal_entity_id;branch_id:=v_claim.branch_id;subject_id:=v_claim.subject_id;
 RETURN NEXT;
END $fn$;
REVOKE ALL ON FUNCTION gestao_folha.require_folha_context_v1(text) FROM PUBLIC;
ALTER FUNCTION gestao_folha.require_folha_context_v1(text) OWNER TO dnex_gestao_auth_owner;

REVOKE ALL ON ALL TABLES IN SCHEMA gestao_folha FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA gestao_folha FROM PUBLIC;
GRANT EXECUTE ON FUNCTION gestao_folha.register_folha_assertion_v1(uuid,uuid,name,uuid,uuid,uuid,text[],timestamptz) TO dnex_gestao_context_issuer;
GRANT EXECUTE ON FUNCTION gestao_folha.require_folha_context_v1(text) TO dnex_gestao_api;

-- Postflight, fail closed: the ACL must be exactly the intended one. Nothing is
-- revoked here beyond PUBLIC; if default privileges of the cluster add a grantee,
-- a grant option or a column privilege, the whole installation aborts.
DO $postflight$
DECLARE v_unexpected text;
BEGIN
 SELECT pg_catalog.string_agg(x.object||' -> '||x.grantee||':'||x.privilege,', ' ORDER BY x.object,x.grantee,x.privilege) INTO v_unexpected FROM (
  SELECT 'schema gestao_folha' AS object,CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE a.grantee::pg_catalog.regrole::text END AS grantee,a.privilege_type||CASE WHEN a.is_grantable THEN ' WITH GRANT OPTION' ELSE '' END AS privilege
  FROM pg_catalog.pg_namespace n CROSS JOIN LATERAL pg_catalog.aclexplode(COALESCE(n.nspacl,pg_catalog.acldefault('n',n.nspowner))) a
  WHERE n.nspname='gestao_folha' AND a.grantee<>n.nspowner
  UNION ALL
  SELECT 'table '||c.relname,CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE a.grantee::pg_catalog.regrole::text END,a.privilege_type||CASE WHEN a.is_grantable THEN ' WITH GRANT OPTION' ELSE '' END
  FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace CROSS JOIN LATERAL pg_catalog.aclexplode(COALESCE(c.relacl,pg_catalog.acldefault('r',c.relowner))) a
  WHERE n.nspname='gestao_folha' AND a.grantee<>c.relowner
  UNION ALL
  SELECT 'column '||c.relname||'.'||t.attname,CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE a.grantee::pg_catalog.regrole::text END,a.privilege_type
  FROM pg_catalog.pg_attribute t JOIN pg_catalog.pg_class c ON c.oid=t.attrelid JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace CROSS JOIN LATERAL pg_catalog.aclexplode(t.attacl) a
  WHERE n.nspname='gestao_folha' AND t.attacl IS NOT NULL
  UNION ALL
  SELECT 'function '||p.proname,CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE a.grantee::pg_catalog.regrole::text END,a.privilege_type||CASE WHEN a.is_grantable THEN ' WITH GRANT OPTION' ELSE '' END
  FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace CROSS JOIN LATERAL pg_catalog.aclexplode(COALESCE(p.proacl,pg_catalog.acldefault('f',p.proowner))) a
  WHERE n.nspname='gestao_folha' AND a.grantee<>p.proowner
 ) AS x
 WHERE (x.object,x.grantee,x.privilege) NOT IN (
  ('schema gestao_folha','dnex_gestao_auth_owner','USAGE'),('schema gestao_folha','dnex_gestao_context_issuer','USAGE'),('schema gestao_folha','dnex_gestao_api','USAGE'),
  ('function register_folha_assertion_v1','dnex_gestao_context_issuer','EXECUTE'),('function require_folha_context_v1','dnex_gestao_api','EXECUTE'));
 IF v_unexpected IS NOT NULL THEN RAISE EXCEPTION USING ERRCODE='42501',MESSAGE='0015: unexpected privileges in gestao_folha: '||v_unexpected;END IF;
 IF (SELECT pg_catalog.count(*) FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace JOIN pg_catalog.pg_roles r ON r.oid=p.proowner WHERE n.nspname='gestao_folha' AND p.prosecdef AND r.rolname='dnex_gestao_auth_owner' AND p.proconfig @> ARRAY['search_path=pg_catalog, pg_temp','row_security=on'])<>2
 OR (SELECT pg_catalog.count(*) FROM pg_catalog.pg_proc p JOIN pg_catalog.pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='gestao_folha')<>2
 OR NOT EXISTS(SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace JOIN pg_catalog.pg_roles r ON r.oid=c.relowner WHERE n.nspname='gestao_folha' AND c.relname='folha_assertion_claim' AND c.relrowsecurity AND c.relforcerowsecurity AND r.rolname='dnex_gestao_auth_owner')
 OR (SELECT pg_catalog.count(*) FROM pg_catalog.pg_constraint k WHERE k.conrelid='gestao_folha.folha_assertion_claim'::pg_catalog.regclass AND k.contype='c' AND k.convalidated)<>3
 OR NOT pg_catalog.has_function_privilege('dnex_gestao_context_issuer','gestao_folha.register_folha_assertion_v1(uuid,uuid,name,uuid,uuid,uuid,text[],timestamptz)','EXECUTE')
 OR NOT pg_catalog.has_function_privilege('dnex_gestao_api','gestao_folha.require_folha_context_v1(text)','EXECUTE')
 THEN RAISE EXCEPTION USING ERRCODE='55000',MESSAGE='0015: gestao_folha objects are not in the reviewed shape';END IF;
END $postflight$;
COMMIT;
