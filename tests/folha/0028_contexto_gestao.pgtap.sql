-- DNEX Folha — Testes pgTAP da migration 0028: contexto de autorização do dnex-gestao.
-- Cobre: ACL exata das funções da sessão de aplicação; contexto feliz e negativos (sem claim,
-- claim adulterada, vencida, revogada, login fora do grupo api, login membro do worker, escopo
-- inativo, chave geral); cada permissão em cada função; identidade (subject) gravada no cálculo,
-- na liberação, na aprovação, no fechamento e na auditoria, inclusive por UPDATE direto;
-- segregação opcional; despacho e geradores filtrados pela conta; isolamento entre contas; e a
-- medição do cálculo em lote frente ao limite de 60 s da asserção.
--
-- Como o arquivo roda: sempre como superusuário no nível de cima. Tudo o que vale "para uma
-- sessão de aplicação" passa por pg_temp.pedido(), que emite uma asserção com claim da Folha
-- pelo caminho real (login emissor), assume o login de teste (membro só de dnex_gestao_api),
-- abre o contexto com gestao_auth.begin_request, executa os comandos e devolve o resultado do
-- último como texto, ou 'ERRO <sqlstate>: <mensagem>'.
--   * p_persiste = false: tudo é desfeito (subtransação); serve para negativos e leituras.
--   * p_persiste = true: o que foi gravado fica, para o passo seguinte do fluxo.
--   * p_espelho = true: o login recebe o espelho dos GRANTs do worker (bootstrap, seção 6),
--     para provar que as barreiras valem também para quem alcança as tabelas e as funções
--     internas. Com false (o normal aqui) a sessão é a de produção: só as funções folha.*_v1.
-- O protocolo do gestao admite um contexto por transação. Como o arquivo inteiro é uma
-- transação, cada pedido novo apaga, como superusuário, o contexto do pedido anterior
-- (linha de request_context e parâmetro dnex.context_nonce). É artifício do teste para
-- encadear pedidos de usuários diferentes; em produção cada pedido é uma transação.
-- Valores de cálculo: nenhum é conferido aqui (os dourados estão nos arquivos 0023 a 0026).
BEGIN;

SELECT plan(184);

\set A '''a0000000-0000-0000-0000-000000000028'''
\set B '''b0000000-0000-0000-0000-000000000028'''
\set S_CALC  '''51000000-0000-0000-0000-000000000001'''
\set S_CLOSE '''52000000-0000-0000-0000-000000000002'''
\set S_TX    '''53000000-0000-0000-0000-000000000003'''
\set S_ADMIN '''54000000-0000-0000-0000-000000000004'''
\set S_TUDO  '''55000000-0000-0000-0000-000000000005'''
\set S_B     '''56000000-0000-0000-0000-000000000006'''

-- ---------------------------------------------------------------------------
-- Apoio
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE escopo (conta uuid PRIMARY KEY, entidade uuid NOT NULL, filial uuid NOT NULL);
INSERT INTO escopo VALUES
  (:A, 'a1000000-0000-0000-0000-000000000028', 'a2000000-0000-0000-0000-000000000028'),
  (:B, 'b1000000-0000-0000-0000-000000000028', 'b2000000-0000-0000-0000-000000000028');
INSERT INTO gestao_finance.enterprise_scope_registry (account_id, legal_entity_id, branch_id)
SELECT conta, entidade, filial FROM escopo;

CREATE FUNCTION pg_temp.pedido(
  p_conta uuid, p_permissoes text[], p_subject uuid,
  p_persiste boolean, p_espelho boolean, p_adultera text, p_sql text[]
) RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v_saida text;
  v_as uuid := gen_random_uuid();
  v_e record;
  i integer;
BEGIN
  BEGIN
    -- contexto do pedido anterior (artifício do teste, ver o cabeçalho)
    DELETE FROM gestao_auth.request_context WHERE backend_pid = pg_backend_pid();
    PERFORM set_config('dnex.context_nonce', '', true);
    IF p_espelho THEN
      PERFORM dnex_folha_ci_apoio.espelhar_worker();
    END IF;
    IF p_permissoes IS NOT NULL THEN
      SELECT * INTO STRICT v_e FROM escopo WHERE conta = p_conta;
      PERFORM dnex_folha_ci_apoio.emitir(v_as, p_conta, v_e.entidade, v_e.filial, p_permissoes, p_subject);
    END IF;
    SET LOCAL SESSION AUTHORIZATION dnex_folha_ci_login;
    IF p_permissoes IS NOT NULL THEN
      PERFORM gestao_auth.begin_request(v_as, gen_random_uuid(), gen_random_uuid());
    END IF;
    IF p_adultera IS NOT NULL THEN
      RESET SESSION AUTHORIZATION;
      EXECUTE replace(p_adultera, '@AS@', v_as::text);
      SET LOCAL SESSION AUTHORIZATION dnex_folha_ci_login;
    END IF;
    FOR i IN 1 .. array_length(p_sql, 1) - 1 LOOP
      EXECUTE p_sql[i];
    END LOOP;
    EXECUTE p_sql[array_length(p_sql, 1)] INTO v_saida;
    IF NOT p_persiste THEN
      RAISE EXCEPTION 'desfaz' USING ERRCODE = 'ZZ001';
    END IF;
    RESET SESSION AUTHORIZATION;
    IF p_espelho THEN
      PERFORM dnex_folha_ci_apoio.desfazer_espelho();
    END IF;
  EXCEPTION
    WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_saida := 'ERRO ' || SQLSTATE || ': ' || SQLERRM;
  END;
  RETURN v_saida;
END
$$;
-- Negativo ou leitura: sessão de produção, nada persiste.
CREATE FUNCTION pg_temp.le(p_conta uuid, p_permissoes text[], p_subject uuid, VARIADIC p_sql text[]) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.pedido(p_conta, p_permissoes, p_subject, false, false, NULL, p_sql) $$;
-- Passo do fluxo: sessão de produção, persiste.
CREATE FUNCTION pg_temp.faz(p_conta uuid, p_permissoes text[], p_subject uuid, VARIADIC p_sql text[]) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.pedido(p_conta, p_permissoes, p_subject, true, false, NULL, p_sql) $$;
-- Contexto aberto e depois adulterado como superusuário ('@AS@' = a asserção do pedido).
CREATE FUNCTION pg_temp.adulterado(p_adultera text, VARIADIC p_sql text[]) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.pedido('a0000000-0000-0000-0000-000000000028',
                        ARRAY['folha.read', 'folha.calculate', 'folha.close', 'folha.transmit', 'folha.admin'],
                        '55000000-0000-0000-0000-000000000005', false, false, p_adultera, p_sql) $$;
-- Sessão com os privilégios do worker (espelho), nada persiste.
CREATE FUNCTION pg_temp.com_espelho(p_conta uuid, p_permissoes text[], p_subject uuid, VARIADIC p_sql text[]) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.pedido(p_conta, p_permissoes, p_subject, false, true, NULL, p_sql) $$;

CREATE FUNCTION pg_temp.todas() RETURNS text[] LANGUAGE sql AS $$
  SELECT ARRAY['folha.read', 'folha.calculate', 'folha.close', 'folha.transmit', 'folha.admin'] $$;

-- Um contrato com empregador próprio, optante do Simples com CPP no DAS (mesmo cenário mínimo
-- dos testes da 0026). Devolve o contrato.
CREATE TEMP SEQUENCE seq_n START 28000000001;
CREATE FUNCTION pg_temp.mk(p_account uuid, p_salario numeric DEFAULT 3000.00) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
  v_n bigint := nextval('seq_n');
  v_emp uuid; v_est uuid; v_lot uuid; v_trab uuid; v_cid uuid;
BEGIN
  INSERT INTO folha.employee (account_id, cpf, nome_completo, data_nascimento)
  VALUES (p_account, v_n::text, 'Ficticio ' || v_n, '1990-01-01') RETURNING employee_id INTO v_trab;
  INSERT INTO folha.employer (account_id, tipo_inscricao, inscricao, razao_social)
  VALUES (p_account, 'cnpj', left(v_n::text, 8) || right(v_n::text, 3), 'Empresa Ficticia ' || v_n)
  RETURNING employer_id INTO v_emp;
  INSERT INTO folha.employer_regime (account_id, employer_id, vigencia_inicio, regime_tributario, simples_optante, simples_cpp)
  VALUES (p_account, v_emp, '2024-01-01', 'simples_nacional', true, 'no_das');
  INSERT INTO folha.establishment (account_id, employer_id, tipo_inscricao, inscricao, cnae_preponderante)
  VALUES (p_account, v_emp, 'cnpj', v_n::text || '000', '0000000') RETURNING establishment_id INTO v_est;
  INSERT INTO folha.tax_allocation (account_id, employer_id, establishment_id, codigo_lotacao, tipo_lotacao)
  VALUES (p_account, v_emp, v_est, 'L' || v_n, 'teste') RETURNING allocation_id INTO v_lot;
  INSERT INTO folha.employment_contract (account_id, employee_id, data_admissao, cargo, salario_base,
                                         regime_trabalho, employer_id, establishment_id)
  VALUES (p_account, v_trab, '2023-01-01', 'Caso ' || v_n, p_salario, 'clt', v_emp, v_est)
  RETURNING contract_id INTO v_cid;
  INSERT INTO folha.contract_tax_allocation (account_id, employer_id, contract_id, allocation_id, percentual, vigencia_inicio)
  VALUES (p_account, v_emp, v_cid, v_lot, 100, '2024-01-01');
  RETURN v_cid;
END;
$$;

-- Identificadores que a sessão de aplicação precisa citar (ela não lê tabela da Folha).
CREATE TEMP TABLE ids (k text PRIMARY KEY, id uuid NOT NULL);
GRANT SELECT, INSERT ON ids TO dnex_folha_ci_login;
INSERT INTO ids VALUES
  ('a1', pg_temp.mk(:A)), ('a2', pg_temp.mk(:A)), ('a3', pg_temp.mk(:A)), ('a4', pg_temp.mk(:A)),
  ('b1', pg_temp.mk(:B));
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;
CREATE FUNCTION pg_temp.id(p_k text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM ids WHERE k = p_k $$;
-- Códigos de pendência abertos de uma folha, para a sessão de aplicação liberar.
CREATE TEMP TABLE pend (k text NOT NULL, codigo text NOT NULL, PRIMARY KEY (k, codigo));
GRANT SELECT ON pend TO dnex_folha_ci_login;
CREATE FUNCTION pg_temp.anota_pendencias(p_k text) RETURNS void LANGUAGE sql AS $$
  INSERT INTO pend SELECT DISTINCT p_k, p.codigo FROM folha.payroll_pendency p
   WHERE p.run_id = pg_temp.id(p_k) AND p.liberada_em IS NULL
  ON CONFLICT DO NOTHING $$;

-- ===========================================================================
-- 1. Estrutura e ACL
-- ===========================================================================
CREATE TEMP TABLE acl (sig text PRIMARY KEY, papeis text[] NOT NULL);
INSERT INTO acl VALUES
  ('folha.contexto_v1(text)',                                        ARRAY[]::text[]),
  ('folha.segregacao_conferir(uuid,uuid,uuid)',                      ARRAY[]::text[]),
  ('folha.payroll_run_identidade()',                                 ARRAY[]::text[]),
  ('folha.payroll_result_identidade()',                              ARRAY[]::text[]),
  ('folha.contexto_atual_v1()',                                      ARRAY['dnex_gestao_api']),
  ('folha.dashboard_v1()',                                           ARRAY['dnex_gestao_api']),
  ('folha.folha_abrir_v1(date,text,date,uuid,uuid,integer)',         ARRAY['dnex_gestao_api']),
  ('folha.folha_calcular_contrato_v1(uuid,uuid,integer,integer)',    ARRAY['dnex_gestao_api']),
  ('folha.folha_concluir_calculo_v1(uuid)',                          ARRAY['dnex_gestao_api']),
  ('folha.folha_liberar_pendencia_v1(uuid,text,text)',               ARRAY['dnex_gestao_api']),
  ('folha.folha_aprovar_v1(uuid)',                                   ARRAY['dnex_gestao_api']),
  ('folha.folha_fechar_v1(uuid)',                                    ARRAY['dnex_gestao_api']),
  ('folha.folha_cancelar_v1(uuid,text)',                             ARRAY['dnex_gestao_api']),
  ('folha.folha_transmitir_v1(uuid)',                                ARRAY['dnex_gestao_api']),
  ('folha.segregacao_definir_v1(boolean)',                           ARRAY['dnex_gestao_api']);

SELECT is_empty($$SELECT sig FROM acl WHERE to_regprocedure(sig) IS NULL$$,
  'as 15 funções da 0028 existem com a assinatura esperada');
SELECT is((SELECT count(*) FROM acl), 15::bigint, 'ACL: 15 funções conferidas (âncora)');
SELECT is_empty(
  $$SELECT acl.sig || ' <- ' || papel FROM acl, unnest(acl.papeis) AS papel
     WHERE NOT has_function_privilege(papel, to_regprocedure(acl.sig)::oid, 'execute')$$,
  'ACL: dnex_gestao_api executa as onze funções _v1');
SELECT is_empty(
  $$SELECT acl.sig || ' <- ' || CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END
      FROM acl JOIN pg_proc p ON p.oid = to_regprocedure(acl.sig)::oid,
           LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
     WHERE a.grantee <> p.proowner
       AND (a.grantee = 0 OR NOT (a.grantee::regrole::text = ANY (acl.papeis)))$$,
  'ACL: nenhum outro papel (nem PUBLIC, nem o worker) executa as funções da 0028; as internas, ninguém');
SELECT is_empty(
  $$SELECT acl.sig FROM acl JOIN pg_proc p ON p.oid = to_regprocedure(acl.sig)::oid
     WHERE NOT p.prosecdef
        OR NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) AS cfg WHERE cfg = 'search_path=pg_catalog, pg_temp')$$,
  'toda função da 0028 é SECURITY DEFINER com search_path = pg_catalog, pg_temp');
SELECT is_empty(
  $$SELECT p.oid::regprocedure::text FROM pg_proc p
     WHERE p.pronamespace = 'folha'::regnamespace
       AND (p.prosecdef OR EXISTS (SELECT 1 FROM unnest(p.proconfig) AS cfg WHERE cfg LIKE 'search_path=%'))
       AND NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) AS cfg WHERE cfg LIKE 'search_path=%' AND cfg ~ ',\s*pg_temp$')$$,
  'toda função do schema folha que é SECURITY DEFINER ou fixa search_path termina o search_path em pg_temp (inclusive as das 0014 a 0027)');
SELECT is(
  (SELECT string_agg(p.oid::regprocedure::text, ',' ORDER BY p.oid::regprocedure::text)
     FROM pg_proc p WHERE p.pronamespace = 'folha'::regnamespace AND has_function_privilege('dnex_gestao_api', p.oid, 'execute')
      AND p.proname NOT LIKE 'portal\_%'     -- as do Portal (0029) são conferidas no arquivo 0029
      AND p.proname NOT LIKE 'contabil\_%'), -- as da contabilização (0030) são conferidas no arquivo 0030
  (SELECT string_agg(sig, ',' ORDER BY sig) FROM acl WHERE papeis <> ARRAY[]::text[]),
  'dnex_gestao_api executa, no schema folha, exatamente as onze funções _v1 da 0028 (nenhuma das 0014 a 0027)');
SELECT is_empty(
  $$SELECT c.relname || ':' || priv
      FROM pg_class c CROSS JOIN unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER']) AS priv
     WHERE c.relnamespace = 'folha'::regnamespace AND c.relkind IN ('r', 'p', 'v', 'm')
       AND has_table_privilege('dnex_gestao_api', c.oid, priv)$$,
  'dnex_gestao_api não tem privilégio em nenhuma tabela ou visão da Folha');
SELECT is_empty(
  $$SELECT c.relname FROM pg_class c
     WHERE c.relnamespace = 'folha'::regnamespace
       AND CASE WHEN c.relkind = 'S' THEN has_sequence_privilege('dnex_gestao_api', c.oid, 'USAGE, SELECT, UPDATE') ELSE false END$$,
  'dnex_gestao_api não tem privilégio em nenhuma sequência da Folha');
SELECT ok(
  has_schema_privilege('dnex_gestao_api', 'folha', 'USAGE') AND NOT has_schema_privilege('dnex_gestao_api', 'folha', 'CREATE'),
  'dnex_gestao_api tem USAGE no schema folha, sem CREATE');
SELECT is_empty(
  $$SELECT p.oid::regprocedure::text FROM pg_proc p
      CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
     WHERE p.pronamespace = 'folha'::regnamespace AND a.grantee = 0$$,
  'nenhuma função do schema folha é executável por PUBLIC');
SELECT ok(
  NOT has_function_privilege('service_role', 'folha.dispatch_folha_completa(uuid)', 'execute')
  AND has_function_privilege('dnex_gestao_folha_worker', 'folha.dispatch_folha_completa(uuid)', 'execute'),
  'service_role perdeu o EXECUTE de dispatch_folha_completa; o worker (titular) mantém');

-- Papéis: o que o contrato exige do login e o que resta ao worker.
SELECT is(
  (WITH RECURSIVE f(oid) AS (
     SELECT m.roleid FROM pg_auth_members m WHERE m.member = 'dnex_folha_ci_login'::regrole
     UNION SELECT m.roleid FROM f JOIN pg_auth_members m ON m.member = f.oid)
   SELECT string_agg(oid::regrole::text, ',' ORDER BY oid::regrole::text) FROM f),
  'dnex_gestao_api',
  'o login de teste é membro só de dnex_gestao_api (closure exata)');
SELECT ok(
  (SELECT NOT rolcanlogin AND NOT rolsuper AND NOT rolbypassrls FROM pg_roles WHERE rolname = 'dnex_gestao_folha_worker'),
  'dnex_gestao_folha_worker continua NOLOGIN, sem SUPERUSER e sem BYPASSRLS');
SELECT ok(
  has_table_privilege('dnex_gestao_folha_worker', 'folha.employee', 'SELECT, INSERT, UPDATE')
  AND has_function_privilege('dnex_gestao_folha_worker', 'folha.run_payroll_employee(uuid,uuid,integer,integer)', 'execute')
  AND NOT has_function_privilege('dnex_gestao_folha_worker', 'gestao_folha.require_folha_context_v1(text)', 'execute'),
  'o worker continua titular dos GRANTs das 0014 a 0027 e não executa require_folha_context_v1');
SELECT ok(
  has_function_privilege('dnex_gestao_api', 'gestao_folha.require_folha_context_v1(text)', 'execute')
  AND NOT has_function_privilege('dnex_gestao_api', 'gestao_folha.register_folha_assertion_v1(uuid,uuid,name,uuid,uuid,uuid,text[],timestamptz)', 'execute')
  AND has_function_privilege('dnex_gestao_context_issuer', 'gestao_folha.register_folha_assertion_v1(uuid,uuid,name,uuid,uuid,uuid,text[],timestamptz)', 'execute'),
  'gestao_folha como no contrato: api consome, só o emissor registra');
SELECT is(
  (SELECT principal_groups_permitidos FROM folha.request_context_config WHERE singleton),
  ARRAY['api'], 'a lista de grupos deixou de ser NULL: {api}');

-- Colunas, gatilhos e tabela nova.
SELECT is(
  (SELECT string_agg(table_name || '.' || column_name || ':' || data_type, ',' ORDER BY table_name, column_name)
     FROM information_schema.columns
    WHERE table_schema = 'folha' AND column_name LIKE '%\_subject'
      AND table_name IN ('auditoria', 'payroll_pendency', 'payroll_result', 'payroll_run', 'segregation_config')),
  'auditoria.actor_subject:uuid,payroll_pendency.liberada_por_subject:uuid,payroll_result.calculado_por_subject:uuid,'
  || 'payroll_run.aprovado_por_subject:uuid,payroll_run.calculado_por_subject:uuid,payroll_run.fechado_por_subject:uuid,'
  || 'segregation_config.definido_por_subject:uuid',
  'colunas de identidade (subject) criadas');
SELECT is(
  (SELECT string_agg(t.tgname, ',' ORDER BY t.tgname) FROM pg_trigger t
    WHERE t.tgrelid = 'folha.payroll_run'::regclass AND NOT t.tgisinternal AND t.tgtype & 2 = 2),
  'trg_payroll_run_trava,trg_payroll_run_z_identidade',
  'payroll_run: o gatilho de identidade vem depois da trava (ordem alfabética dos BEFORE)');
SELECT is(
  (SELECT string_agg(t.tgname, ',' ORDER BY t.tgname) FROM pg_trigger t
    WHERE t.tgrelid = 'folha.payroll_result'::regclass AND NOT t.tgisinternal AND t.tgtype & 2 = 2),
  'trg_payroll_result_so_em_folha_aberta,trg_payroll_result_z_identidade',
  'payroll_result: gatilho de identidade presente');
SELECT is(
  (SELECT k.relrowsecurity::text || '/' || k.relforcerowsecurity::text FROM pg_class k WHERE k.oid = 'folha.segregation_config'::regclass),
  'true/true', 'segregation_config com RLS e FORCE');
SELECT is(
  (SELECT string_agg(x.linha, ',' ORDER BY x.linha)
     FROM (SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END || ':' || a.privilege_type AS linha
             FROM pg_class k, LATERAL aclexplode(COALESCE(k.relacl, acldefault('r', k.relowner))) a
            WHERE k.oid = 'folha.segregation_config'::regclass AND a.grantee <> k.relowner) x),
  'dnex_gestao_data_owner:SELECT,dnex_gestao_folha_worker:SELECT',
  'segregation_config: só leitura para worker e data_owner; gravação só pela função');
SELECT is(
  (SELECT p.policyname || '/' || p.cmd || '/' || (SELECT string_agg(r::text, ',' ORDER BY r::text) FROM unnest(p.roles) AS r)
     FROM pg_policies p
    WHERE p.schemaname = 'folha' AND p.tablename = 'segregation_config'),
  'segregation_config_isolamento/SELECT/dnex_gestao_data_owner,dnex_gestao_folha_worker',
  'segregation_config: uma policy, de leitura, por conta');

-- ===========================================================================
-- 2. Contexto feliz
-- ===========================================================================
SELECT is(
  pg_temp.le(:A, ARRAY['folha.read'], :S_CALC, 'SELECT c.account_id || ''/'' || c.legal_entity_id || ''/'' || c.branch_id || ''/'' || c.subject_id FROM folha.contexto_atual_v1() c'),
  'a0000000-0000-0000-0000-000000000028/a1000000-0000-0000-0000-000000000028/a2000000-0000-0000-0000-000000000028/51000000-0000-0000-0000-000000000001',
  'contexto com claim da Folha: conta, entidade legal, filial e subject vêm da claim');
SELECT is(
  pg_temp.le(:B, ARRAY['folha.read'], :S_B, 'SELECT c.account_id || ''/'' || c.subject_id FROM folha.contexto_atual_v1() c'),
  'b0000000-0000-0000-0000-000000000028/56000000-0000-0000-0000-000000000006',
  'outra conta, outro subject: cada contexto devolve o seu');
SELECT is(
  pg_temp.le(:A, ARRAY['folha.read'], :S_CALC, 'SELECT (d.total_empregados_ativos = 4)::text FROM folha.dashboard_v1() d'),
  'true', 'dashboard_v1: lê a conta do contexto (4 contratos ativos na conta A), só com folha.read');
SELECT is(
  pg_temp.le(:B, ARRAY['folha.read'], :S_B, 'SELECT d.total_empregados_ativos::text FROM folha.dashboard_v1() d'),
  '1', 'dashboard_v1: a conta B vê só o seu (1)');
SELECT is(
  pg_temp.com_espelho(:A, ARRAY['folha.read'], :S_CALC, 'SELECT folha.current_account_id()::text || ''/'' || (SELECT count(*) FROM folha.employment_contract)'),
  'a0000000-0000-0000-0000-000000000028/4',
  'RLS: com claim da Folha (folha.read), a conta da sessão é a da claim e as linhas são as da conta');
SELECT is(
  pg_temp.com_espelho(:A, ARRAY['folha.read'], :S_CALC,
    'SELECT (SELECT count(*) FROM folha.employment_contract WHERE account_id = ''b0000000-0000-0000-0000-000000000028'')::text'),
  '0', 'RLS: a conta A não vê contrato da conta B');
-- Risco registrado (decisão do dono em 15/11/2026: aceito por enquanto): a asserção do núcleo
-- carrega finance.read, então o contexto da Folha passa em has_permission('finance.read').
SELECT is(
  pg_temp.le(:A, ARRAY['folha.read'], :S_CALC,
    'SELECT gestao_auth.has_permission(''finance.read'', ''a0000000-0000-0000-0000-000000000028'', ''a1000000-0000-0000-0000-000000000028'', ''a2000000-0000-0000-0000-000000000028'')::text'),
  'true', 'risco registrado (aceito "por enquanto", segundo a instrução desta frente): contexto da Folha também passa em finance.read do mesmo escopo');

-- ===========================================================================
-- 3. Contexto que não serve
-- ===========================================================================
-- 3.1 Contexto api SEM claim da Folha: asserção financeira comum, registrada pelo emissor.
CREATE FUNCTION pg_temp.financeiro(VARIADIC p_sql text[]) RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v_saida text;
  v_as uuid := gen_random_uuid();
  i integer;
BEGIN
  BEGIN
    DELETE FROM gestao_auth.request_context WHERE backend_pid = pg_backend_pid();
    PERFORM set_config('dnex.context_nonce', '', true);
    PERFORM dnex_folha_ci_apoio.espelhar_worker();
    SET LOCAL SESSION AUTHORIZATION dnex_folha_ci_emissor;
    PERFORM gestao_auth.register_assertion(v_as, gen_random_uuid(), 'user', 'api', 'dnex_folha_ci_login',
      'a0000000-0000-0000-0000-000000000028', 'a1000000-0000-0000-0000-000000000028', 'a2000000-0000-0000-0000-000000000028',
      ARRAY['finance.read'], clock_timestamp() + interval '55 seconds');
    SET LOCAL SESSION AUTHORIZATION dnex_folha_ci_login;
    PERFORM gestao_auth.begin_request(v_as, gen_random_uuid(), gen_random_uuid());
    FOR i IN 1 .. array_length(p_sql, 1) - 1 LOOP
      EXECUTE p_sql[i];
    END LOOP;
    EXECUTE p_sql[array_length(p_sql, 1)] INTO v_saida;
    RAISE EXCEPTION 'desfaz' USING ERRCODE = 'ZZ001';
  EXCEPTION
    WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_saida := 'ERRO ' || SQLSTATE || ': ' || SQLERRM;
  END;
  RETURN v_saida;
END
$$;
SELECT is(
  pg_temp.financeiro('SELECT gestao_auth.has_permission(''finance.read'', ''a0000000-0000-0000-0000-000000000028'', ''a1000000-0000-0000-0000-000000000028'', ''a2000000-0000-0000-0000-000000000028'')::text'),
  'true', 'âncora: o contexto financeiro sem claim é um contexto api válido (passa em finance.read)');
SELECT is(
  pg_temp.financeiro('SELECT (folha.current_account_id() IS NULL)::text || ''/'' || (folha.request_context_account_id() IS NULL)::text || ''/'' || (SELECT count(*) FROM folha.employment_contract)'),
  'true/true/0',
  'contexto api SEM claim da Folha não recebe conta nem linha (era aceito até a 0027)');
SELECT matches(
  pg_temp.financeiro('SELECT folha.contexto_atual_v1()'),
  '^ERRO 42501: ', 'contexto api sem claim: contexto_atual_v1 recusa');
SELECT matches(
  pg_temp.financeiro(format('SELECT folha.folha_abrir_v1(%L)', '2026-10-01')),
  '^ERRO 42501: ', 'contexto api sem claim: não abre folha');
SELECT matches(
  pg_temp.financeiro('SELECT folha.run_payroll_employee(gen_random_uuid(), gen_random_uuid())'),
  '^ERRO P0001: run_payroll_employee: sessão sem conta',
  'contexto api sem claim, mesmo com os privilégios do worker: o motor não tem conta');

-- 3.2 Sem contexto algum, ou só com parâmetro de sessão.
SELECT matches(
  pg_temp.le(:A, NULL, NULL, 'SELECT folha.contexto_atual_v1()'),
  '^ERRO 42501: ', 'sem begin_request: recusa');
SELECT matches(
  pg_temp.le(:A, NULL, NULL, 'SELECT set_config(''dnex.context_nonce'', gen_random_uuid()::text, true)', 'SELECT folha.contexto_atual_v1()'),
  '^ERRO 42501: ', 'nonce forjado por SET: recusa');
SELECT matches(
  pg_temp.le(:A, NULL, NULL, 'SELECT set_config(''dnex.context_nonce'', ''nao-e-uuid'', true)', 'SELECT folha.dashboard_v1()'),
  '^ERRO 42501: ', 'nonce que não é uuid: recusa (sem erro de conversão)');
SELECT is(
  pg_temp.com_espelho(:A, NULL, NULL, 'SELECT set_config(''folha.account_id'', ''a0000000-0000-0000-0000-000000000028'', true)',
    'SELECT (folha.current_account_id() IS NULL)::text || ''/'' || (SELECT count(*) FROM folha.employment_contract)'),
  'true/0', 'parâmetro folha.account_id não dá conta à sessão de aplicação');

-- 3.3 Contexto aberto de verdade e, em seguida, UM vínculo adulterado como superusuário.
--     Âncora: sem adulteração a mesma chamada devolve a conta (seção 2).
SELECT matches(
  pg_temp.adulterado(x.adultera, 'SELECT c.account_id::text FROM folha.contexto_atual_v1() c'),
  '^ERRO 42501: ',
  'contexto com ' || x.caso || ': recusa'
)
  FROM (VALUES
    ('a claim apagada',
       'DELETE FROM gestao_folha.folha_assertion_claim WHERE assertion_id = ''@AS@'''),
    ('a conta trocada só na claim',
       'UPDATE gestao_folha.folha_assertion_claim SET account_id = ''b0000000-0000-0000-0000-000000000028'' WHERE assertion_id = ''@AS@'''),
    ('o subject trocado só na claim',
       'UPDATE gestao_folha.folha_assertion_claim SET subject_id = gen_random_uuid() WHERE assertion_id = ''@AS@'''),
    ('a claim emitida para outro login',
       'UPDATE gestao_folha.folha_assertion_claim SET runtime_session_user = ''outro_login'' WHERE assertion_id = ''@AS@'''),
    ('a validade da claim diferente da asserção',
       'UPDATE gestao_folha.folha_assertion_claim SET expires_at = expires_at - interval ''1 second'' WHERE assertion_id = ''@AS@'''),
    ('a asserção revogada depois de aberta',
       'UPDATE gestao_auth.access_assertion SET revoked_at = clock_timestamp() WHERE assertion_id = ''@AS@'''),
    ('asserção, contexto e claim vencidos (abertos há 2 minutos)',
       'UPDATE gestao_auth.access_assertion SET issued_at = issued_at - interval ''2 minutes'', consumed_at = consumed_at - interval ''2 minutes'', expires_at = expires_at - interval ''2 minutes'' WHERE assertion_id = ''@AS@''; '
       || 'UPDATE gestao_auth.request_context SET created_at = created_at - interval ''2 minutes'', expires_at = expires_at - interval ''2 minutes'' WHERE assertion_id = ''@AS@''; '
       || 'UPDATE gestao_folha.folha_assertion_claim SET registered_at = registered_at - interval ''2 minutes'', expires_at = expires_at - interval ''2 minutes'' WHERE assertion_id = ''@AS@'''),
    ('o PID de outro backend',
       'UPDATE gestao_auth.request_context SET backend_pid = backend_pid + 1 WHERE assertion_id = ''@AS@'''),
    ('o txid de outra transação',
       'UPDATE gestao_auth.request_context SET transaction_id = transaction_id + 1 WHERE assertion_id = ''@AS@'''),
    ('o escopo empresarial desativado',
       'UPDATE gestao_finance.enterprise_scope_registry SET status = ''inactive'' WHERE account_id = ''a0000000-0000-0000-0000-000000000028'''),
    ('o login que ganhou um segundo papel',
       'GRANT dnex_gestao_data_owner TO dnex_folha_ci_login'),
    ('o login que virou membro do worker (o worker não é mais caminho de sessão)',
       'GRANT dnex_gestao_folha_worker TO dnex_folha_ci_login'),
    ('a lista de grupos da Folha vazia (chave geral)',
       'UPDATE folha.request_context_config SET principal_groups_permitidos = ARRAY[]::text[]'),
    ('a lista de grupos da Folha sem o grupo api',
       'UPDATE folha.request_context_config SET principal_groups_permitidos = ARRAY[''folha_worker'']'),
    ('a linha de configuração ausente',
       'DELETE FROM folha.request_context_config')
  ) AS x(caso, adultera);
SELECT is(
  pg_temp.adulterado('UPDATE folha.request_context_config SET principal_groups_permitidos = NULL',
    'SELECT c.account_id::text FROM folha.contexto_atual_v1() c'),
  'a0000000-0000-0000-0000-000000000028',
  'lista de grupos NULL continua significando "sem restrição de grupo": a barreira é a claim');
-- A permissão vem da claim, não do pedido: tirar folha.calculate da claim tira a operação.
SELECT matches(
  pg_temp.adulterado('UPDATE gestao_folha.folha_assertion_claim SET folha_permissions = ARRAY[''folha.read''] WHERE assertion_id = ''@AS@''',
    format('SELECT folha.folha_abrir_v1(%L)', '2026-10-01')),
  '^ERRO 42501: ', 'claim reduzida a folha.read depois de aberta: não abre folha');
-- O mesmo contexto, na mesma transação, lido por outro session_user.
SELECT is(
  pg_temp.pedido(:A, pg_temp.todas(), :S_TUDO, false, false, NULL,
    ARRAY['RESET SESSION AUTHORIZATION',
          'SELECT (folha.request_context_account_id() IS NULL)::text || ''/'' || (current_setting(''dnex.context_nonce'') <> '''')::text']),
  'true/true', 'o mesmo nonce, lido por outro session_user (superusuário), não dá conta');
-- Validade real: asserção de 1 segundo, usada depois de vencer, dentro da mesma transação.
CREATE FUNCTION pg_temp.vencida() RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v_saida text;
  v_as uuid := gen_random_uuid();
BEGIN
  BEGIN
    DELETE FROM gestao_auth.request_context WHERE backend_pid = pg_backend_pid();
    PERFORM set_config('dnex.context_nonce', '', true);
    PERFORM dnex_folha_ci_apoio.emitir(v_as, 'a0000000-0000-0000-0000-000000000028', 'a1000000-0000-0000-0000-000000000028',
      'a2000000-0000-0000-0000-000000000028', pg_temp.todas(), gen_random_uuid(), 'dnex_folha_ci_login', interval '1 second');
    SET LOCAL SESSION AUTHORIZATION dnex_folha_ci_login;
    PERFORM gestao_auth.begin_request(v_as, gen_random_uuid(), gen_random_uuid());
    v_saida := (SELECT c.account_id::text FROM folha.contexto_atual_v1() c);
    PERFORM pg_sleep(1.3);
    v_saida := v_saida || ' depois ' || (SELECT c.account_id::text FROM folha.contexto_atual_v1() c);
    RAISE EXCEPTION 'desfaz' USING ERRCODE = 'ZZ001';
  EXCEPTION
    WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_saida := v_saida || ' depois ERRO ' || SQLSTATE;
  END;
  RETURN v_saida;
END
$$;
SELECT is(pg_temp.vencida(), 'a0000000-0000-0000-0000-000000000028 depois ERRO 42501',
  'a asserção vale enquanto não vence; vencida no meio da transação, a chamada seguinte falha');

-- 3.4 Objeto temporário com nome de tipo do sistema. A sessão de aplicação pode criar objetos
--     temporários; com search_path sem pg_temp no fim, um domínio pg_temp.uuid faria a função
--     de conferência do domínio rodar como o dono das funções SECURITY DEFINER (antes de
--     qualquer conferência de contexto). A isca, se rodar como outro papel que não o da
--     sessão, levanta um erro próprio (ZZ999) que nenhum dos blocos abaixo captura: gravar numa
--     tabela não serviria, porque a recusa da função desfaz a gravação.
SELECT is(
  pg_temp.pedido(:A, x.permissoes, :S_TUDO, false, x.espelho, NULL, ARRAY[
    'CREATE FUNCTION pg_temp.isca(anyelement) RETURNS boolean LANGUAGE plpgsql AS $f$ BEGIN IF current_user <> session_user THEN RAISE EXCEPTION ''isca executada como %'', current_user USING ERRCODE = ''ZZ999''; END IF; RETURN true; END $f$',
    'CREATE DOMAIN pg_temp.uuid AS pg_catalog.uuid CHECK (pg_temp.isca(VALUE))',
    'CREATE DOMAIN pg_temp.text AS pg_catalog.text CHECK (pg_temp.isca(VALUE))',
    'CREATE DOMAIN pg_temp.date AS pg_catalog.date CHECK (pg_temp.isca(VALUE))',
    'CREATE DOMAIN pg_temp.timestamptz AS pg_catalog.timestamptz CHECK (pg_temp.isca(VALUE))',
    'CREATE DOMAIN pg_temp.bool AS pg_catalog.bool CHECK (pg_temp.isca(VALUE))',
    'CREATE DOMAIN pg_temp.int4 AS pg_catalog.int4 CHECK (pg_temp.isca(VALUE))',
    'CREATE DOMAIN pg_temp.numeric AS pg_catalog.numeric CHECK (pg_temp.isca(VALUE))',
    x.chamada,
    'SELECT ''ninguem''']),
  'ninguem',
  'domínios temporários com nome de tipo do sistema não fazem código do chamador rodar como o dono: ' || x.caso)
  FROM (VALUES
    ('sem contexto, folha_abrir_v1', NULL::text[], false,
       'DO $d$ BEGIN PERFORM folha.folha_abrir_v1(DATE ''2026-10-01''); EXCEPTION WHEN insufficient_privilege THEN NULL; END $d$'),
    ('com contexto, contexto_atual_v1 e dashboard_v1', ARRAY['folha.read'], false,
       'DO $d$ BEGIN PERFORM 1 FROM folha.contexto_atual_v1(); PERFORM 1 FROM folha.dashboard_v1(); END $d$'),
    ('com contexto e privilégios do worker, funções das 0014 a 0027 e a conta da sessão',
       ARRAY['folha.read', 'folha.calculate', 'folha.close', 'folha.transmit', 'folha.admin'], true,
       'DO $d$ BEGIN PERFORM folha.current_account_id(); PERFORM gestao_auth.has_permission(''finance.read'', pg_catalog.gen_random_uuid(), pg_catalog.gen_random_uuid(), pg_catalog.gen_random_uuid()); PERFORM folha.calc_inss(3000, DATE ''2026-10-01''); BEGIN PERFORM folha.run_payroll_employee(pg_catalog.gen_random_uuid(), pg_catalog.gen_random_uuid()); EXCEPTION WHEN raise_exception THEN NULL; END; BEGIN PERFORM folha.payroll_run_fechar(pg_catalog.gen_random_uuid(), ''x''); EXCEPTION WHEN raise_exception THEN NULL; END; END $d$')
  ) AS x(caso, permissoes, espelho, chamada);

-- Âncora da isca: numa função SECURITY DEFINER com search_path SEM pg_temp no fim, ela dispara.
CREATE FUNCTION public.folha_teste_definer_vulneravel() RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE v uuid := gen_random_uuid(); BEGIN RETURN 'sem isca'; END $$;
GRANT EXECUTE ON FUNCTION public.folha_teste_definer_vulneravel() TO dnex_folha_ci_login;
SELECT matches(
  pg_temp.pedido(:A, NULL, NULL, false, false, NULL, ARRAY[
    'CREATE FUNCTION pg_temp.isca(anyelement) RETURNS boolean LANGUAGE plpgsql AS $f$ BEGIN IF current_user <> session_user THEN RAISE EXCEPTION ''isca executada como %'', current_user USING ERRCODE = ''ZZ999''; END IF; RETURN true; END $f$',
    'CREATE DOMAIN pg_temp.uuid AS pg_catalog.uuid CHECK (pg_temp.isca(VALUE))',
    'SELECT public.folha_teste_definer_vulneravel()']),
  '^ERRO ZZ999: isca executada como ',
  'âncora: a mesma isca dispara numa função SECURITY DEFINER com search_path sem pg_temp (o teste acima não passa por acaso)');
-- As funções do gestao que a sessão de aplicação executa precisam da mesma proteção (a 0028
-- recusa aplicar sem ela; no gestao real, hoje, falta: ver bootstrap, diferença i).
SELECT is_empty(
  $$SELECT p.oid::regprocedure::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname IN ('gestao_auth', 'gestao_folha') AND p.prosecdef
       AND has_function_privilege('dnex_gestao_api', p.oid, 'execute')
       AND NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) AS cfg WHERE cfg ~ '^search_path=pg_catalog(,|$)' AND cfg ~ ',\s*pg_temp$')$$,
  'funções do gestao executáveis pela sessão de aplicação têm search_path terminado em pg_temp (pré-condição da 0028)');

-- ===========================================================================
-- 4. Cada permissão em cada função
--    Com todas as permissões menos a exigida, a função recusa com 42501 antes de qualquer
--    leitura (os identificadores são aleatórios: se a permissão passasse, o erro seria outro).
-- ===========================================================================
CREATE TEMP TABLE exige (chamada text PRIMARY KEY, permissao text NOT NULL);
INSERT INTO exige VALUES
  ('SELECT folha.folha_abrir_v1(''2026-10-01'')',                                            'folha.calculate'),
  ('SELECT folha.folha_calcular_contrato_v1(gen_random_uuid(), gen_random_uuid())',          'folha.calculate'),
  ('SELECT folha.folha_concluir_calculo_v1(gen_random_uuid())',                              'folha.calculate'),
  ('SELECT folha.folha_liberar_pendencia_v1(gen_random_uuid(), ''a_validar:x'', ''motivo'')', 'folha.close'),
  ('SELECT folha.folha_aprovar_v1(gen_random_uuid())',                                       'folha.close'),
  ('SELECT folha.folha_fechar_v1(gen_random_uuid())',                                        'folha.close'),
  ('SELECT folha.folha_cancelar_v1(gen_random_uuid(), ''motivo'')',                            'folha.close'),
  ('SELECT folha.folha_transmitir_v1(gen_random_uuid())',                                    'folha.transmit'),
  ('SELECT folha.segregacao_definir_v1(true)',                                               'folha.admin');
SELECT matches(
  pg_temp.le(:A, array_remove(pg_temp.todas(), e.permissao), :S_TUDO, e.chamada),
  '^ERRO 42501: Folha assertion missing, expired or revoked$',
  'sem ' || e.permissao || ' (com as outras quatro): ' || split_part(split_part(e.chamada, '(', 1), ' ', 2) || ' recusa')
  FROM exige e ORDER BY e.chamada;
SELECT matches(
  pg_temp.le(:A, ARRAY['folha.read', e.permissao], :S_TUDO, e.chamada),
  CASE WHEN e.chamada LIKE '%folha_abrir_v1%' OR e.chamada LIKE '%segregacao_definir_v1%' THEN '^[0-9a-f-]{36}$|^$'
       ELSE '^ERRO P0001: ' END,
  'com folha.read + ' || e.permissao || ': ' || split_part(split_part(e.chamada, '(', 1), ' ', 2) || ' passa da permissão'
)
  FROM exige e ORDER BY e.chamada;
-- As funções das 0018 a 0027 (inalcançáveis pela sessão de produção) também conferem a permissão:
-- quem as alcança com os privilégios do worker precisa da mesma permissão.
CREATE TEMP TABLE exige_interna (chamada text PRIMARY KEY, permissao text NOT NULL);
INSERT INTO exige_interna VALUES
  ('SELECT folha.run_payroll_employee(gen_random_uuid(), gen_random_uuid())',                            'folha.calculate'),
  ('SELECT folha.payroll_run_concluir_calculo(gen_random_uuid())',                                       'folha.calculate'),
  ('SELECT folha.payroll_pendencias_liberar(gen_random_uuid(), ''a_validar:x'', ''Rotulo'', ''motivo'')',  'folha.close'),
  ('SELECT folha.payroll_run_aprovar(gen_random_uuid(), ''Rotulo'')',                                    'folha.close'),
  ('SELECT folha.payroll_run_fechar(gen_random_uuid(), ''Rotulo'')',                                     'folha.close'),
  ('SELECT * FROM folha.dispatch_folha_completa(gen_random_uuid())',                                     'folha.transmit'),
  ('SELECT folha.dispatch_esocial_event(gen_random_uuid(), NULL, ''S-1200'', ''2026-10-01'', ''{}'')',     'folha.transmit'),
  ('SELECT folha.dispatch_accounting_event(gen_random_uuid(), gen_random_uuid(), ''folha_mensal'', ''{}'')', 'folha.transmit'),
  ('SELECT folha.build_esocial_s1200(gen_random_uuid())',                                                'folha.transmit'),
  ('SELECT folha.build_esocial_s2200(gen_random_uuid())',                                                'folha.transmit'),
  ('SELECT folha.build_contabil_folha(gen_random_uuid())',                                               'folha.transmit');
SELECT matches(
  pg_temp.com_espelho(:A, array_remove(pg_temp.todas(), e.permissao), :S_TUDO, e.chamada),
  '^ERRO 42501: Folha assertion missing, expired or revoked$',
  'privilégios do worker sem ' || e.permissao || ': ' || split_part(split_part(e.chamada, '(', 1), 'folha.', 2) || ' recusa')
  FROM exige_interna e ORDER BY e.chamada;
SELECT matches(
  pg_temp.le(:A, pg_temp.todas(), :S_TUDO, e.chamada),
  '^ERRO 42501: permission denied for function',
  'sessão de produção (sem espelho) não executa ' || split_part(split_part(e.chamada, '(', 1), 'folha.', 2))
  FROM exige_interna e ORDER BY e.chamada;
SELECT matches(
  pg_temp.le(:A, pg_temp.todas(), :S_TUDO, x.sql),
  '^ERRO 42501: permission denied for (table|function)',
  'sessão de produção não ' || x.caso)
  FROM (VALUES
    ('lê tabela da Folha', 'SELECT count(*) FROM folha.employee'),
    ('grava folha direto', 'INSERT INTO folha.payroll_run (account_id, competencia) VALUES (''a0000000-0000-0000-0000-000000000028'', ''2026-10-01'')'),
    ('lê a configuração de segregação', 'SELECT count(*) FROM folha.segregation_config'),
    ('chama a leitura interna do contexto', 'SELECT folha.contexto_v1(''folha.admin'')'),
    ('chama a conta da sessão diretamente', 'SELECT folha.current_account_id()')
  ) AS x(caso, sql);

-- ===========================================================================
-- 5. Fluxo com identidade: quem calcula, quem libera, quem aprova, quem fecha, quem transmite
-- ===========================================================================
SELECT matches(
  pg_temp.faz(:A, ARRAY['folha.read', 'folha.calculate'], :S_CALC,
    'INSERT INTO ids SELECT ''r1'', folha.folha_abrir_v1(''2026-10-01'', ''mensal'', ''2026-10-31'') RETURNING id::text'),
  '^[0-9a-f-]{36}$', 'abrir folha (folha.calculate)');
SELECT is(
  (SELECT r.account_id::text || '/' || r.status || '/' || r.created_by || '/' || (r.calculado_por_subject IS NULL)::text
     FROM folha.payroll_run r WHERE r.run_id = pg_temp.id('r1')),
  'a0000000-0000-0000-0000-000000000028/draft/51000000-0000-0000-0000-000000000001/true',
  'a folha nasce na conta do contexto, em rascunho, com o subject em created_by');
SELECT matches(
  pg_temp.faz(:A, ARRAY['folha.read', 'folha.calculate'], :S_CALC,
    'SELECT folha.folha_calcular_contrato_v1((SELECT id FROM ids WHERE k = ''r1''), (SELECT id FROM ids WHERE k = ''a1''))::text'),
  '^[0-9a-f-]{36}$', 'calcular um contrato (folha.calculate)');
SELECT is(
  (SELECT string_agg(pr.calculado_por_subject::text, ',') FROM folha.payroll_result pr WHERE pr.run_id = pg_temp.id('r1')),
  '51000000-0000-0000-0000-000000000001', 'o resultado leva o subject de quem calculou');
SELECT is(
  pg_temp.faz(:A, ARRAY['folha.read', 'folha.calculate'], :S_TUDO,
    'SELECT folha.folha_calcular_contrato_v1((SELECT id FROM ids WHERE k = ''r1''), (SELECT id FROM ids WHERE k = ''a2'')) IS NOT NULL'),
  'true', 'um segundo usuário calcula outro contrato da mesma folha');
SELECT is(
  pg_temp.faz(:A, ARRAY['folha.read', 'folha.calculate'], :S_CALC,
    'SELECT folha.folha_concluir_calculo_v1((SELECT id FROM ids WHERE k = ''r1''))::text'),
  '', 'concluir o cálculo (folha.calculate)');
SELECT is(
  (SELECT r.status || '/' || r.calculado_por_subject::text || '/' || (r.aprovado_por_subject IS NULL)::text
     FROM folha.payroll_run r WHERE r.run_id = pg_temp.id('r1')),
  'calculated/51000000-0000-0000-0000-000000000001/true', 'a folha leva o subject de quem concluiu o cálculo');
SELECT pg_temp.anota_pendencias('r1');
SELECT cmp_ok((SELECT count(*) FROM pend WHERE k = 'r1'), '>=', 1::bigint, 'âncora: a folha tem pendência a liberar');

SELECT is(
  pg_temp.faz(:A, ARRAY['folha.read', 'folha.close'], :S_CLOSE,
    'SELECT (sum(folha.folha_liberar_pendencia_v1((SELECT id FROM ids WHERE k = ''r1''), p.codigo, ''conferido no teste'')) > 0)::text FROM pend p WHERE p.k = ''r1'''),
  'true', 'liberar as pendências (folha.close)');
SELECT is(
  (SELECT string_agg(DISTINCT p.liberada_por_subject::text || '/' || p.liberada_por || '/' || p.liberada_sessao || '/' || p.liberacao_motivo, ';')
     FROM folha.payroll_pendency p WHERE p.run_id = pg_temp.id('r1')),
  '52000000-0000-0000-0000-000000000002/52000000-0000-0000-0000-000000000002/dnex_folha_ci_login/conferido no teste',
  'a liberação grava o subject do contexto (e não texto livre), a sessão e o motivo');
SELECT is(
  (SELECT string_agg(DISTINCT a.actor || '/' || a.actor_subject::text || '/' || (a.detalhe->>'legal_entity_id') || '/' || (a.detalhe->>'branch_id'), ';')
     FROM folha.auditoria a WHERE a.recurso_id = pg_temp.id('r1') AND a.acao = 'liberar_pendencia'),
  '52000000-0000-0000-0000-000000000002/52000000-0000-0000-0000-000000000002/a1000000-0000-0000-0000-000000000028/a2000000-0000-0000-0000-000000000028',
  'auditoria da liberação: ator = subject, com entidade legal e filial do contexto');
SELECT is(
  pg_temp.faz(:A, ARRAY['folha.read', 'folha.close'], :S_CLOSE,
    'SELECT folha.folha_aprovar_v1((SELECT id FROM ids WHERE k = ''r1''))::text'),
  '', 'aprovar (folha.close)');
SELECT is(
  pg_temp.faz(:A, ARRAY['folha.read', 'folha.close'], :S_TUDO,
    'SELECT folha.folha_fechar_v1((SELECT id FROM ids WHERE k = ''r1''))::text'),
  '', 'fechar (folha.close), por outro usuário');
SELECT is(
  (SELECT r.status || '/' || r.calculado_por_subject::text || '/' || r.aprovado_por_subject::text || '/' || r.fechado_por_subject::text || '/' || r.approved_by
     FROM folha.payroll_run r WHERE r.run_id = pg_temp.id('r1')),
  'closed/51000000-0000-0000-0000-000000000001/52000000-0000-0000-0000-000000000002/55000000-0000-0000-0000-000000000005/52000000-0000-0000-0000-000000000002',
  'a folha fechada guarda quem calculou, quem aprovou e quem fechou; approved_by é o subject, não um nome digitado');
SELECT is(
  (SELECT string_agg(a.acao || '=' || a.actor_subject::text, ',' ORDER BY a.auditoria_id)
     FROM folha.auditoria a WHERE a.recurso_id = pg_temp.id('r1') AND a.acao IN ('abrir_folha', 'aprovar_folha', 'fechar_folha')),
  'abrir_folha=51000000-0000-0000-0000-000000000001,aprovar_folha=52000000-0000-0000-0000-000000000002,fechar_folha=55000000-0000-0000-0000-000000000005',
  'auditoria: abertura, aprovação e fechamento com o subject de cada um');

-- Transmissão
-- Mudou com a migration 0030: o evento contábil deixou de ser um por resultado, com contas fixas
-- no código. Os empregadores deste arquivo não têm configuração nem mapeamento contábil: a
-- contabilização fica bloqueada (pendência) e o contador contábil devolve 0; os eventos do
-- eSocial não dependem dela. A contabilização com mapeamento está no arquivo 0030.
SELECT is(
  pg_temp.faz(:A, ARRAY['folha.read', 'folha.transmit'], :S_TX,
    'SELECT d.esocial_events_dispatched || ''/'' || d.contabil_events_dispatched FROM folha.folha_transmitir_v1((SELECT id FROM ids WHERE k = ''r1'')) d'),
  '2/0', 'transmitir a folha fechada (folha.transmit): dois resultados, dois eventos do eSocial; sem mapeamento contábil, nenhum lote contábil');
SELECT is(
  (SELECT (SELECT count(*) FROM folha.esocial_event_outbox o WHERE o.run_id = pg_temp.id('r1') AND o.account_id = :A)::text
          || '/' || (SELECT count(*) FROM folha.accounting_outbox o WHERE o.run_id = pg_temp.id('r1') AND o.account_id = :A)::text
          || '/' || (SELECT count(*) FROM folha.esocial_event_outbox o WHERE o.account_id <> :A)::text),
  '2/0/0', 'os eventos entram nas outboxes da conta do contexto, e em nenhuma outra (a contábil fica vazia: contabilização bloqueada)');
SELECT is(
  (SELECT a.actor_subject::text || '/' || (a.detalhe->>'esocial') FROM folha.auditoria a
    WHERE a.recurso_id = pg_temp.id('r1') AND a.acao = 'transmitir_folha'),
  '53000000-0000-0000-0000-000000000003/2', 'auditoria da transmissão com o subject');

-- Repetir a transmissão não põe nada de novo na fila, nem com outro formato de data na sessão,
-- e o retorno diz isso (zero), em vez de repetir a contagem da primeira vez.
SELECT is(
  pg_temp.faz(:A, ARRAY['folha.read', 'folha.transmit'], :S_TX,
    'SET LOCAL DateStyle = ''SQL, DMY''',
    'SELECT d.esocial_events_dispatched || ''/'' || d.contabil_events_dispatched FROM folha.folha_transmitir_v1((SELECT id FROM ids WHERE k = ''r1'')) d'),
  '0/0', 'transmitir de novo (com DateStyle diferente): nada novo, e o retorno é 0/0');
RESET DateStyle;
SELECT is(
  (SELECT (SELECT count(*) FROM folha.esocial_event_outbox o WHERE o.run_id = pg_temp.id('r1'))::text
          || '/' || (SELECT count(*) FROM folha.accounting_outbox o WHERE o.run_id = pg_temp.id('r1'))::text),
  '2/0', 'a fila do eSocial continua com um evento por resultado, e a contábil vazia');

-- Cancelar (folha.close): a saída de "cancele e recalcule".
SELECT matches(
  pg_temp.faz(:A, ARRAY['folha.read', 'folha.calculate'], :S_CALC,
    'INSERT INTO ids SELECT ''rc'', folha.folha_abrir_v1(''2026-10-01'', ''mensal'', ''2026-10-31'', NULL, NULL, 5) RETURNING id::text'),
  '^[0-9a-f-]{36}$', 'preparo: folha a cancelar');
SELECT matches(
  pg_temp.le(:A, ARRAY['folha.read', 'folha.close'], :S_CLOSE, 'SELECT folha.folha_cancelar_v1((SELECT id FROM ids WHERE k = ''rc''), ''  '')'),
  '^ERRO 22023: ', 'NEG cancelar: motivo obrigatório');
SELECT matches(
  pg_temp.le(:B, pg_temp.todas(), :S_B, 'SELECT folha.folha_cancelar_v1((SELECT id FROM ids WHERE k = ''rc''), ''motivo'')'),
  '^ERRO P0001: Folha .* não encontrada$', 'NEG cancelar: conta B não cancela folha da conta A');
SELECT is(
  pg_temp.faz(:A, ARRAY['folha.read', 'folha.close'], :S_CLOSE, 'SELECT folha.folha_cancelar_v1((SELECT id FROM ids WHERE k = ''rc''), ''aberta por engano'')::text'),
  '', 'cancelar folha em rascunho (folha.close)');
SELECT is(
  (SELECT r.status || '/' || (SELECT a.actor_subject::text || '/' || (a.detalhe->>'estado_anterior') || '/' || (a.detalhe->>'motivo')
                               FROM folha.auditoria a WHERE a.recurso_id = r.run_id AND a.acao = 'cancelar_folha')
     FROM folha.payroll_run r WHERE r.run_id = pg_temp.id('rc')),
  'cancelled/52000000-0000-0000-0000-000000000002/draft/aberta por engano', 'folha cancelada, com subject, estado anterior e motivo na auditoria');
SELECT matches(
  pg_temp.le(:A, ARRAY['folha.read', 'folha.close'], :S_CLOSE, 'SELECT folha.folha_cancelar_v1((SELECT id FROM ids WHERE k = ''r1''), ''motivo'')'),
  '^ERRO P0001: Folha .* está fechada e não pode ser alterada$', 'NEG cancelar: folha fechada não é cancelada (trava da 0027)');

-- ===========================================================================
-- 6. Identidade no dado: UPDATE e INSERT diretos (privilégios do worker) não a forjam
-- ===========================================================================
-- Folha r2: calculada por S_CALC, com as pendências liberadas por S_CLOSE.
SELECT matches(
  pg_temp.faz(:A, ARRAY['folha.read', 'folha.calculate'], :S_CALC,
    'INSERT INTO ids SELECT ''r2'', folha.folha_abrir_v1(''2026-10-01'', ''mensal'', ''2026-10-31'', NULL, NULL, 2)',
    'SELECT folha.folha_calcular_contrato_v1((SELECT id FROM ids WHERE k = ''r2''), (SELECT id FROM ids WHERE k = ''a3''))',
    'SELECT folha.folha_concluir_calculo_v1((SELECT id FROM ids WHERE k = ''r2''))::text'),
  '^$', 'preparo: segunda folha da competência aberta, calculada e concluída num só pedido');
SELECT pg_temp.anota_pendencias('r2');
SELECT is(
  pg_temp.faz(:A, ARRAY['folha.read', 'folha.close'], :S_CLOSE,
    'SELECT (sum(folha.folha_liberar_pendencia_v1((SELECT id FROM ids WHERE k = ''r2''), p.codigo, ''conferido'')) > 0)::text FROM pend p WHERE p.k = ''r2'''),
  'true', 'preparo: pendências da segunda folha liberadas');
SELECT is(
  pg_temp.com_espelho(:A, ARRAY['folha.read', 'folha.close'], :S_CLOSE,
    format('UPDATE folha.payroll_run SET status = ''approved'', aprovado_por_subject = %L, calculado_por_subject = %L WHERE run_id = %L', :S_ADMIN, :S_ADMIN, pg_temp.id('r2')),
    format('SELECT aprovado_por_subject::text || ''/'' || calculado_por_subject::text FROM folha.payroll_run WHERE run_id = %L', pg_temp.id('r2'))),
  '52000000-0000-0000-0000-000000000002/51000000-0000-0000-0000-000000000001',
  'UPDATE direto do status: o gatilho grava o subject do contexto e ignora o que foi informado');
SELECT matches(
  pg_temp.com_espelho(:A, ARRAY['folha.read', 'folha.calculate', 'folha.transmit', 'folha.admin'], :S_CLOSE,
    format('UPDATE folha.payroll_run SET status = ''approved'' WHERE run_id = %L', pg_temp.id('r2')), 'SELECT 1'),
  '^ERRO 42501: ', 'UPDATE direto para aprovada sem folha.close: recusado pelo gatilho');
SELECT matches(
  pg_temp.com_espelho(:B, pg_temp.todas(), :S_B,
    format('UPDATE folha.payroll_run SET status = ''approved'' WHERE run_id = %L RETURNING 1', pg_temp.id('r2')), 'SELECT ''nenhuma linha'''),
  '^nenhuma linha$', 'UPDATE direto por outra conta: a RLS não deixa alcançar a folha');
SELECT throws_ok(
  format('UPDATE folha.payroll_run SET status = ''approved'' WHERE run_id = %L', pg_temp.id('r2')),
  '42501', NULL, 'superusuário sem contexto também não aprova: sem subject não há aprovação');
SELECT is(
  pg_temp.com_espelho(:A, pg_temp.todas(), :S_TUDO,
    format('UPDATE folha.payroll_run SET fechado_por_subject = %L, calculado_por_subject = %L, updated_at = now() WHERE run_id = %L', :S_ADMIN, :S_ADMIN, pg_temp.id('r2')),
    format('SELECT (fechado_por_subject IS NULL)::text || ''/'' || calculado_por_subject::text FROM folha.payroll_run WHERE run_id = %L', pg_temp.id('r2'))),
  'true/51000000-0000-0000-0000-000000000001',
  'UPDATE que só tenta alterar as colunas de identidade não as altera');
SELECT is(
  pg_temp.com_espelho(:A, pg_temp.todas(), :S_TUDO,
    format('INSERT INTO folha.payroll_run (account_id, competencia, sequencia, calculado_por_subject, aprovado_por_subject, fechado_por_subject) VALUES (%L, ''2026-10-01'', 9, %L, %L, %L)', :A, :S_ADMIN, :S_ADMIN, :S_ADMIN),
    'SELECT (calculado_por_subject IS NULL AND aprovado_por_subject IS NULL AND fechado_por_subject IS NULL)::text FROM folha.payroll_run WHERE sequencia = 9'),
  'true', 'INSERT direto com identidade informada: as três colunas nascem nulas');
SELECT matches(
  pg_temp.com_espelho(:A, pg_temp.todas(), :S_TUDO,
    format('UPDATE folha.payroll_pendency SET liberada_por_subject = %L', :S_ADMIN), 'SELECT 1'),
  '^ERRO 42501: permission denied', 'a pendência (e o subject dela) só muda pela função');
-- Liberação pelas funções da 0027 (rótulo informado): a identidade continua sendo o subject.
SELECT is(
  pg_temp.com_espelho(:A, ARRAY['folha.read', 'folha.close'], :S_CLOSE,
    format('SELECT folha.payroll_run_aprovar(%L, ''Nome Digitado'')', pg_temp.id('r2')),
    format('SELECT r.approved_by || ''/'' || r.aprovado_por_subject::text || ''/'' || (SELECT a.actor || ''/'' || (a.detalhe->>''rotulo_informado'') FROM folha.auditoria a WHERE a.recurso_id = r.run_id AND a.acao = ''aprovar_folha'') FROM folha.payroll_run r WHERE r.run_id = %L', pg_temp.id('r2'))),
  'Nome Digitado/52000000-0000-0000-0000-000000000002/52000000-0000-0000-0000-000000000002/Nome Digitado',
  'função da 0027 com rótulo digitado: o rótulo fica como rótulo; identidade e ator da auditoria são o subject');
-- Resultado: só nasce sob folha.calculate, com o subject; a coluna não é alterável.
WITH nova AS (
  INSERT INTO folha.payroll_run (account_id, competencia, data_pagamento, sequencia)
  VALUES (:A, '2026-10-01', '2026-10-31', 8) RETURNING run_id)
INSERT INTO ids SELECT 'rascunho', run_id FROM nova;
SELECT throws_ok(
  format($q$INSERT INTO folha.payroll_result (run_id, account_id, employee_id, contract_id, total_proventos, total_descontos, liquido, inss_empregado, irrf, fgts, calculation_hash)
            SELECT %L, k.account_id, k.employee_id, k.contract_id, 1, 0, 1, 0, 0, 0, 'x' FROM folha.employment_contract k WHERE k.contract_id = %L$q$,
         pg_temp.id('rascunho'), pg_temp.id('a4')),
  '42501', NULL, 'resultado gravado sem contexto (superusuário) é recusado: sem folha.calculate não há resultado');

-- ===========================================================================
-- 7. Isolamento entre contas nas funções (contexto da conta B, todas as permissões)
-- ===========================================================================
SELECT matches(
  pg_temp.le(:B, pg_temp.todas(), :S_B, x.sql),
  x.esperado,
  'conta B não ' || x.caso)
  FROM (VALUES
    ('calcula em folha da conta A',
       'SELECT folha.folha_calcular_contrato_v1((SELECT id FROM ids WHERE k = ''r2''), (SELECT id FROM ids WHERE k = ''b1''))',
       '^ERRO P0001: Folha .* não encontrada$'),
    ('calcula contrato da conta A',
       'SELECT folha.folha_calcular_contrato_v1((SELECT id FROM ids WHERE k = ''r2''), (SELECT id FROM ids WHERE k = ''a4''))',
       '^ERRO P0001: Contrato .* não encontrado$'),
    ('conclui folha da conta A',
       'SELECT folha.folha_concluir_calculo_v1((SELECT id FROM ids WHERE k = ''r2''))',
       '^ERRO P0001: Folha .* não encontrada$'),
    ('libera pendência de folha da conta A',
       'SELECT folha.folha_liberar_pendencia_v1((SELECT id FROM ids WHERE k = ''r2''), ''a_validar:x'', ''motivo'')',
       '^ERRO P0001: Folha .* não encontrada$'),
    ('aprova folha da conta A',
       'SELECT folha.folha_aprovar_v1((SELECT id FROM ids WHERE k = ''r2''))',
       '^ERRO P0001: Folha .* não encontrada$'),
    ('fecha folha da conta A',
       'SELECT folha.folha_fechar_v1((SELECT id FROM ids WHERE k = ''r1''))',
       '^ERRO P0001: Folha .* não encontrada$'),
    ('transmite folha (fechada) da conta A',
       'SELECT folha.folha_transmitir_v1((SELECT id FROM ids WHERE k = ''r1''))',
       '^ERRO P0001: payroll_run .* não encontrado$')
  ) AS x(caso, sql, esperado);
-- Geradores e despachos (alcançáveis só com os privilégios do worker): antes da 0028 devolviam
-- o resultado, o contrato e o CPF de qualquer conta pelo identificador.
CREATE TEMP TABLE alvo AS
  SELECT pr.result_id, pr.run_id, pr.contract_id FROM folha.payroll_result pr
   WHERE pr.run_id = pg_temp.id('r1') ORDER BY pr.result_id LIMIT 1;
SELECT matches(
  pg_temp.com_espelho(:B, pg_temp.todas(), :S_B, x.sql),
  '^ERRO P0001: .* não encontrado',
  'conta B, com os privilégios do worker, não ' || x.caso || ' da conta A')
  FROM (VALUES
    ('gera S-1200 de resultado', format('SELECT folha.build_esocial_s1200(%L)', (SELECT result_id FROM alvo))),
    ('gera lançamento contábil de resultado', format('SELECT folha.build_contabil_folha(%L)', (SELECT result_id FROM alvo))),
    ('gera S-2200 de contrato', format('SELECT folha.build_esocial_s2200(%L)', (SELECT contract_id FROM alvo))),
    ('despacha evento contábil de resultado', format('SELECT folha.dispatch_accounting_event(%L, %L, ''folha_mensal'', ''{}'')', (SELECT run_id FROM alvo), (SELECT result_id FROM alvo))),
    ('despacha evento do eSocial de folha', format('SELECT folha.dispatch_esocial_event(%L, NULL, ''S-1299'', ''2026-10-01'', ''{}'')', (SELECT run_id FROM alvo))),
    ('despacha a folha', format('SELECT * FROM folha.dispatch_folha_completa(%L)', (SELECT run_id FROM alvo)))
  ) AS x(caso, sql);
SELECT is(
  pg_temp.com_espelho(:A, ARRAY['folha.read', 'folha.transmit'], :S_TX,
    format('SELECT (folha.build_esocial_s1200(%L)->>''evento'') || ''/'' || (folha.build_contabil_folha(%L)->>''result_id'')', (SELECT result_id FROM alvo), (SELECT result_id FROM alvo))),
  'S-1200/' || (SELECT result_id::text FROM alvo),
  'âncora: a própria conta, com folha.transmit, gera os dois');
SELECT matches(
  pg_temp.com_espelho(:A, ARRAY['folha.read', 'folha.transmit'], :S_TX,
    format('SELECT folha.dispatch_esocial_event(%L, %L, ''S-1200'', ''2026-10-01'', ''{}'')', pg_temp.id('r2'), (SELECT result_id FROM alvo))),
  '^ERRO P0001: payroll_result .* não encontrado no run',
  'evento do eSocial não aceita resultado que não é da folha informada');

-- ===========================================================================
-- 8. Segregação mínima (opcional, por conta, desligada por padrão)
-- ===========================================================================
SELECT is((SELECT count(*) FROM folha.segregation_config), 0::bigint, 'segregação desligada por padrão: nenhuma conta configurada');
-- Desligada: quem calculou pode liberar, aprovar e fechar (folha r3, tudo com S_TUDO).
SELECT matches(
  pg_temp.faz(:A, pg_temp.todas(), :S_TUDO,
    'INSERT INTO ids SELECT ''r3'', folha.folha_abrir_v1(''2026-10-01'', ''mensal'', ''2026-10-31'', NULL, NULL, 3)',
    'SELECT folha.folha_calcular_contrato_v1((SELECT id FROM ids WHERE k = ''r3''), (SELECT id FROM ids WHERE k = ''a4''))',
    'SELECT folha.folha_concluir_calculo_v1((SELECT id FROM ids WHERE k = ''r3''))::text'),
  '^$', 'preparo: terceira folha calculada e concluída por S_TUDO');
SELECT pg_temp.anota_pendencias('r3');
SELECT is(
  pg_temp.le(:A, pg_temp.todas(), :S_TUDO,
    'SELECT sum(folha.folha_liberar_pendencia_v1((SELECT id FROM ids WHERE k = ''r3''), p.codigo, ''m'')) FROM pend p WHERE p.k = ''r3''',
    'SELECT folha.folha_aprovar_v1((SELECT id FROM ids WHERE k = ''r3''))',
    'SELECT folha.folha_fechar_v1((SELECT id FROM ids WHERE k = ''r3''))::text'),
  '', 'segregação desligada: o mesmo usuário calcula, libera, aprova e fecha');
-- Ligar exige folha.admin e fica registrado.
SELECT is(
  pg_temp.faz(:A, ARRAY['folha.read', 'folha.admin'], :S_ADMIN, 'SELECT folha.segregacao_definir_v1(true)::text'),
  '', 'ligar a segregação (folha.admin)');
SELECT is(
  (SELECT s.account_id::text || '/' || s.calculo_x_fechamento::text || '/' || s.definido_por_subject::text FROM folha.segregation_config s),
  'a0000000-0000-0000-0000-000000000028/true/54000000-0000-0000-0000-000000000004',
  'configuração gravada na conta do contexto, com quem definiu');
SELECT is(
  (SELECT a.actor_subject::text || '/' || (a.detalhe->>'calculo_x_fechamento') FROM folha.auditoria a WHERE a.acao = 'definir_segregacao'),
  '54000000-0000-0000-0000-000000000004/true', 'auditoria da configuração');
SELECT matches(
  pg_temp.le(:A, pg_temp.todas(), :S_TUDO,
    'SELECT folha.folha_liberar_pendencia_v1((SELECT id FROM ids WHERE k = ''r3''), (SELECT min(p.codigo) FROM pend p WHERE p.k = ''r3''), ''m'')'),
  '^ERRO 42501: Segregação de funções: quem calculou a folha .* não libera pendência, não aprova e não fecha$',
  'segregação ligada: quem calculou não libera pendência');
SELECT is(
  pg_temp.faz(:A, ARRAY['folha.read', 'folha.close'], :S_CLOSE,
    'SELECT (sum(folha.folha_liberar_pendencia_v1((SELECT id FROM ids WHERE k = ''r3''), p.codigo, ''m'')) > 0)::text FROM pend p WHERE p.k = ''r3'''),
  'true', 'segregação ligada: outro usuário libera');
SELECT matches(
  pg_temp.le(:A, pg_temp.todas(), :S_TUDO, 'SELECT folha.folha_aprovar_v1((SELECT id FROM ids WHERE k = ''r3''))'),
  '^ERRO 42501: Segregação de funções: ', 'segregação ligada: quem calculou não aprova');
SELECT matches(
  pg_temp.com_espelho(:A, pg_temp.todas(), :S_TUDO,
    format('UPDATE folha.payroll_run SET status = ''approved'' WHERE run_id = %L', pg_temp.id('r3')), 'SELECT 1'),
  '^ERRO 42501: Segregação de funções: ', 'segregação ligada: nem por UPDATE direto');
SELECT is(
  pg_temp.faz(:A, ARRAY['folha.read', 'folha.close'], :S_CLOSE, 'SELECT folha.folha_aprovar_v1((SELECT id FROM ids WHERE k = ''r3''))::text'),
  '', 'segregação ligada: outro usuário aprova');
SELECT matches(
  pg_temp.le(:A, pg_temp.todas(), :S_TUDO, 'SELECT folha.folha_fechar_v1((SELECT id FROM ids WHERE k = ''r3''))'),
  '^ERRO 42501: Segregação de funções: ', 'segregação ligada: quem calculou não fecha');
-- Quem calculou um dos resultados (sem ter concluído) também é "quem calculou": r1 foi fechada
-- antes de ligar; usa-se r2 (resultado de S_CALC, conclusão de S_CALC) com um terceiro usuário
-- e depois com S_CALC.
SELECT matches(
  pg_temp.le(:A, ARRAY['folha.read', 'folha.close', 'folha.calculate'], :S_CALC, 'SELECT folha.folha_aprovar_v1((SELECT id FROM ids WHERE k = ''r2''))'),
  '^ERRO 42501: Segregação de funções: ', 'segregação ligada: S_CALC calculou r2 e não a aprova');
SELECT is(
  pg_temp.le(:A, ARRAY['folha.read', 'folha.close'], :S_ADMIN, 'SELECT folha.folha_aprovar_v1((SELECT id FROM ids WHERE k = ''r2''))::text'),
  '', 'segregação ligada: quem não calculou r2 a aprova');
-- Folha calculada sem identificação (como as anteriores à 0028): não dá para provar a segregação.
SET LOCAL session_replication_role = replica;   -- gatilhos desligados só para este INSERT
WITH nova AS (
  INSERT INTO folha.payroll_run (account_id, competencia, data_pagamento, status, sequencia)
  VALUES (:A, '2026-10-01', '2026-10-31', 'calculated', 7) RETURNING run_id)
INSERT INTO ids SELECT 'legada', run_id FROM nova;
SET LOCAL session_replication_role = origin;
SELECT matches(
  pg_temp.le(:A, ARRAY['folha.read', 'folha.close'], :S_CLOSE, 'SELECT folha.folha_aprovar_v1((SELECT id FROM ids WHERE k = ''legada''))'),
  '^ERRO 42501: Segregação de funções: a folha .* foi calculada sem identificação de quem calculou; cancele e recalcule$',
  'segregação ligada: folha calculada sem subject não é aprovada (não há como provar)');
-- A configuração é da conta: a conta B segue sem segregação.
SELECT is(
  pg_temp.le(:B, pg_temp.todas(), :S_B,
    'INSERT INTO ids SELECT ''rb'', folha.folha_abrir_v1(''2026-10-01'', ''mensal'', ''2026-10-31'')',
    'SELECT folha.folha_calcular_contrato_v1((SELECT id FROM ids WHERE k = ''rb''), (SELECT id FROM ids WHERE k = ''b1''))',
    'SELECT folha.folha_concluir_calculo_v1((SELECT id FROM ids WHERE k = ''rb''))',
    'SELECT folha.folha_liberar_pendencia_v1((SELECT id FROM ids WHERE k = ''rb''), ''a_validar:inss_arredondamento_metodo'', ''m'') >= 1'),
  'true', 'a segregação da conta A não vale para a conta B (o mesmo usuário calcula e libera)');
SELECT matches(
  pg_temp.le(:A, ARRAY['folha.read', 'folha.close'], :S_CLOSE, 'SELECT folha.segregacao_definir_v1(false)'),
  '^ERRO 42501: ', 'quem fecha não desliga a segregação (exige folha.admin)');
SELECT matches(
  pg_temp.le(:A, ARRAY['folha.read', 'folha.admin'], :S_ADMIN, 'SELECT folha.segregacao_definir_v1(NULL)'),
  '^ERRO 22023: ', 'segregacao_definir_v1 recusa nulo');
SELECT is(
  pg_temp.faz(:A, ARRAY['folha.read', 'folha.admin'], :S_TUDO, 'SELECT folha.segregacao_definir_v1(false)::text'),
  '', 'desligar a segregação (folha.admin)');
SELECT is(
  pg_temp.faz(:A, pg_temp.todas(), :S_TUDO, 'SELECT folha.folha_fechar_v1((SELECT id FROM ids WHERE k = ''r3''))::text'),
  '', 'segregação desligada de novo: quem calculou fecha');
SELECT is(
  (SELECT r.calculado_por_subject::text || '/' || r.aprovado_por_subject::text || '/' || r.fechado_por_subject::text
     FROM folha.payroll_run r WHERE r.run_id = pg_temp.id('r3')),
  '55000000-0000-0000-0000-000000000005/52000000-0000-0000-0000-000000000002/55000000-0000-0000-0000-000000000005',
  'r3: cada passo com o subject de quem o fez');

-- ===========================================================================
-- 9. Limite de 60 s da asserção frente ao cálculo em lote
--    Uma folha, 200 contratos sintéticos, um pedido (uma transação, uma asserção): abrir,
--    calcular os 200 e concluir. O tempo é medido dentro do pedido e impresso (diag).
--    A margem do teste é o próprio limite do contrato: acima de 60 s o pedido falharia.
-- ===========================================================================
CREATE TEMP TABLE lote (n integer PRIMARY KEY, cid uuid NOT NULL);
INSERT INTO lote SELECT g, pg_temp.mk(:A, 2500.00 + g) FROM generate_series(1, 200) AS g;
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;
GRANT SELECT ON lote TO dnex_folha_ci_login;
CREATE TEMP TABLE medida (rotulo text PRIMARY KEY, inicio timestamptz, fim timestamptz, n integer);
GRANT SELECT, INSERT, UPDATE ON medida TO dnex_folha_ci_login;
SELECT is(
  pg_temp.faz(:A, ARRAY['folha.read', 'folha.calculate'], :S_CALC,
    'INSERT INTO medida VALUES (''lote'', clock_timestamp(), NULL, NULL)',
    'INSERT INTO ids SELECT ''rl'', folha.folha_abrir_v1(''2026-09-01'', ''mensal'', ''2026-09-30'')',
    'UPDATE medida SET n = (SELECT count(folha.folha_calcular_contrato_v1((SELECT id FROM ids WHERE k = ''rl''), l.cid)) FROM lote l)',
    'SELECT folha.folha_concluir_calculo_v1((SELECT id FROM ids WHERE k = ''rl''))',
    'UPDATE medida SET fim = clock_timestamp() RETURNING n::text'),
  '200', 'lote: 200 contratos calculados e a folha concluída em um único pedido (uma asserção)');
SELECT is(
  (SELECT r.status || '/' || (SELECT count(*) FROM folha.payroll_result pr WHERE pr.run_id = r.run_id AND pr.calculado_por_subject = :S_CALC)
     FROM folha.payroll_run r WHERE r.run_id = pg_temp.id('rl')),
  'calculated/200', 'lote: 200 resultados gravados, todos com o subject');
SELECT diag('LOTE 0028: 200 contratos (abrir + calcular + concluir) em '
            || round(extract(epoch FROM (fim - inicio))::numeric, 3) || ' s; '
            || round(extract(epoch FROM (fim - inicio))::numeric * 1000 / 200, 2) || ' ms por contrato; limite da asserção: 60 s')
  FROM medida WHERE rotulo = 'lote';
SELECT cmp_ok((SELECT extract(epoch FROM (fim - inicio)) FROM medida WHERE rotulo = 'lote'), '<', 60::numeric,
  'lote: o pedido coube na validade máxima da asserção (60 s)');

SELECT * FROM finish();
ROLLBACK;
