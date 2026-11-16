-- DNEX Folha — Testes pgTAP da migration 0029: banco do Portal do Colaborador v1.
-- Cobre os oito testes pedidos pela frente Portal (BANCO-V1, seção 5) e mais: ACL exata,
-- permissão de cada função do escritório, identidade gravada, publicação só de folha fechada
-- e sem pendência, forma e prefixo do caminho do arquivo, imutabilidade do documento,
-- isolamento entre contas e entre empregados, acesso após o desligamento, aceite do aviso de
-- privacidade e relatório de visualização.
--
-- Dois apoios, um para cada público:
--   pg_temp.pedido()  sessão de aplicação do escritório: asserção com claim da Folha emitida
--                     pelo caminho real, login de teste (membro só de dnex_gestao_api) e
--                     begin_request. Igual ao do arquivo 0028 (ver o cabeçalho de lá, inclusive
--                     sobre o artifício de trocar de contexto dentro da transação do teste).
--   pg_temp.portal()  empregado: papel authenticated com o claim `sub` nos parâmetros de
--                     requisição, como o PostgREST deixa depois de validar o token. p_uid nulo =
--                     requisição sem claim.
-- Os dois devolvem o resultado do último comando como texto, ou 'ERRO <sqlstate>: <mensagem>'.
-- Nomes, CPFs, caminhos e hashes são fictícios. Nada é persistido (ROLLBACK no final).
BEGIN;

SELECT plan(190);

\set A '''a0000000-0000-0000-0000-000000000029'''
\set B '''b0000000-0000-0000-0000-000000000029'''
\set S_ADMIN '''61000000-0000-0000-0000-000000000001'''
\set S_TX    '''62000000-0000-0000-0000-000000000002'''
\set S_READ  '''63000000-0000-0000-0000-000000000003'''
\set S_B     '''64000000-0000-0000-0000-000000000004'''
\set U_ANA   '''71000000-0000-0000-0000-000000000001'''
\set U_BIA   '''72000000-0000-0000-0000-000000000002'''
\set U_CAIO  '''73000000-0000-0000-0000-000000000003'''
\set U_SEM   '''74000000-0000-0000-0000-000000000004'''
\set U_ANA2  '''75000000-0000-0000-0000-000000000005'''
\set HASH '''0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'''

-- ---------------------------------------------------------------------------
-- Apoio
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE escopo (conta uuid PRIMARY KEY, entidade uuid NOT NULL, filial uuid NOT NULL);
INSERT INTO escopo VALUES
  (:A, 'a1000000-0000-0000-0000-000000000029', 'a2000000-0000-0000-0000-000000000029'),
  (:B, 'b1000000-0000-0000-0000-000000000029', 'b2000000-0000-0000-0000-000000000029');
INSERT INTO gestao_finance.enterprise_scope_registry (account_id, legal_entity_id, branch_id)
SELECT conta, entidade, filial FROM escopo;

CREATE FUNCTION pg_temp.pedido(
  p_conta uuid, p_permissoes text[], p_subject uuid,
  p_persiste boolean, p_espelho boolean, p_sql text[]
) RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v_saida text;
  v_as uuid := gen_random_uuid();
  v_e record;
  i integer;
BEGIN
  BEGIN
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
CREATE FUNCTION pg_temp.le(p_conta uuid, p_permissoes text[], p_subject uuid, VARIADIC p_sql text[]) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.pedido(p_conta, p_permissoes, p_subject, false, false, p_sql) $$;
CREATE FUNCTION pg_temp.faz(p_conta uuid, p_permissoes text[], p_subject uuid, VARIADIC p_sql text[]) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.pedido(p_conta, p_permissoes, p_subject, true, false, p_sql) $$;
CREATE FUNCTION pg_temp.com_espelho(p_conta uuid, p_permissoes text[], p_subject uuid, VARIADIC p_sql text[]) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.pedido(p_conta, p_permissoes, p_subject, false, true, p_sql) $$;
CREATE FUNCTION pg_temp.todas() RETURNS text[] LANGUAGE sql AS $$
  SELECT ARRAY['folha.read', 'folha.calculate', 'folha.close', 'folha.transmit', 'folha.admin'] $$;

-- Empregado (ou anon) atrás do PostgREST.
CREATE FUNCTION pg_temp.portal_como(p_papel text, p_uid uuid, p_persiste boolean, p_sql text[]) RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v_saida text;
  i integer;
BEGIN
  BEGIN
    PERFORM set_config('request.jwt.claims',
      CASE WHEN p_uid IS NULL THEN '' ELSE json_build_object('sub', p_uid, 'role', p_papel)::text END, true);
    EXECUTE format('SET LOCAL ROLE %I', p_papel);
    FOR i IN 1 .. array_length(p_sql, 1) - 1 LOOP
      EXECUTE p_sql[i];
    END LOOP;
    EXECUTE p_sql[array_length(p_sql, 1)] INTO v_saida;
    IF NOT p_persiste THEN
      RAISE EXCEPTION 'desfaz' USING ERRCODE = 'ZZ001';
    END IF;
    RESET ROLE;
    PERFORM set_config('request.jwt.claims', '', true);
  EXCEPTION
    WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_saida := 'ERRO ' || SQLSTATE || ': ' || SQLERRM;
  END;
  RETURN v_saida;
END
$$;
-- Leitura do empregado (nada persiste) e ação do empregado (persiste).
CREATE FUNCTION pg_temp.portal(p_uid uuid, VARIADIC p_sql text[]) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.portal_como('authenticated', p_uid, false, p_sql) $$;
CREATE FUNCTION pg_temp.portal_faz(p_uid uuid, VARIADIC p_sql text[]) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.portal_como('authenticated', p_uid, true, p_sql) $$;
-- O que o empregado enxerga: títulos em ordem alfabética.
CREATE FUNCTION pg_temp.titulos(p_uid uuid) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.portal(p_uid, 'SELECT COALESCE(string_agg(d.titulo, '','' ORDER BY d.titulo), '''') FROM portal_api.listar_meus_documentos() d') $$;

-- Cadastro. pg_temp.mk cria um contrato; com p_employer nulo cria empregador novo (com
-- estabelecimento e lotação); com p_employee nulo cria trabalhador novo.
CREATE TEMP SEQUENCE seq_n START 29000000001;
CREATE FUNCTION pg_temp.mk(p_account uuid, p_nome text, p_employee uuid DEFAULT NULL, p_employer uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE
  v_n bigint := nextval('seq_n');
  v_emp uuid := p_employer; v_est uuid; v_lot uuid; v_trab uuid := p_employee; v_cid uuid;
BEGIN
  IF v_trab IS NULL THEN
    INSERT INTO folha.employee (account_id, cpf, nome_completo, data_nascimento)
    VALUES (p_account, v_n::text, p_nome, '1990-01-01') RETURNING employee_id INTO v_trab;
  END IF;
  IF v_emp IS NULL THEN
    INSERT INTO folha.employer (account_id, tipo_inscricao, inscricao, razao_social)
    VALUES (p_account, 'cnpj', left(v_n::text, 8) || right(v_n::text, 3), 'Empresa de ' || p_nome)
    RETURNING employer_id INTO v_emp;
    INSERT INTO folha.employer_regime (account_id, employer_id, vigencia_inicio, regime_tributario, simples_optante, simples_cpp)
    VALUES (p_account, v_emp, '2024-01-01', 'simples_nacional', true, 'no_das');
    INSERT INTO folha.establishment (account_id, employer_id, tipo_inscricao, inscricao, cnae_preponderante)
    VALUES (p_account, v_emp, 'cnpj', v_n::text || '000', '0000000') RETURNING establishment_id INTO v_est;
    INSERT INTO folha.tax_allocation (account_id, employer_id, establishment_id, codigo_lotacao, tipo_lotacao)
    VALUES (p_account, v_emp, v_est, 'L' || v_n, 'teste') RETURNING allocation_id INTO v_lot;
  ELSE
    SELECT s.establishment_id INTO STRICT v_est FROM folha.establishment s WHERE s.employer_id = v_emp;
    SELECT l.allocation_id INTO STRICT v_lot FROM folha.tax_allocation l WHERE l.employer_id = v_emp;
  END IF;
  INSERT INTO folha.employment_contract (account_id, employee_id, data_admissao, cargo, salario_base,
                                         regime_trabalho, employer_id, establishment_id)
  VALUES (p_account, v_trab, '2023-01-01', 'Cargo ' || v_n, 3000.00, 'clt', v_emp, v_est)
  RETURNING contract_id INTO v_cid;
  INSERT INTO folha.contract_tax_allocation (account_id, employer_id, contract_id, allocation_id, percentual, vigencia_inicio)
  VALUES (p_account, v_emp, v_cid, v_lot, 100, '2024-01-01');
  RETURN v_cid;
END;
$$;

-- Contratos: Ana e Bia no empregador E1; Ana também no empregador E2 (mesma conta); Dora em E1,
-- sem resultado em folha; Caio na conta B.
CREATE TEMP TABLE c (k text PRIMARY KEY, cid uuid NOT NULL);
GRANT SELECT ON c TO dnex_folha_ci_login;
INSERT INTO c VALUES ('ana_e1', pg_temp.mk(:A, 'Ana Ficticia'));
CREATE FUNCTION pg_temp.trab(p_k text) RETURNS uuid LANGUAGE sql AS $$
  SELECT k.employee_id FROM folha.employment_contract k JOIN c ON c.cid = k.contract_id WHERE c.k = p_k $$;
CREATE FUNCTION pg_temp.emp(p_k text) RETURNS uuid LANGUAGE sql AS $$
  SELECT k.employer_id FROM folha.employment_contract k JOIN c ON c.cid = k.contract_id WHERE c.k = p_k $$;
CREATE FUNCTION pg_temp.est(p_k text) RETURNS uuid LANGUAGE sql AS $$
  SELECT k.establishment_id FROM folha.employment_contract k JOIN c ON c.cid = k.contract_id WHERE c.k = p_k $$;
CREATE FUNCTION pg_temp.cid(p_k text) RETURNS uuid LANGUAGE sql AS $$ SELECT cid FROM c WHERE k = p_k $$;
INSERT INTO c VALUES ('bia', pg_temp.mk(:A, 'Bia Ficticia', NULL, pg_temp.emp('ana_e1')));
INSERT INTO c VALUES ('ana_e2', pg_temp.mk(:A, 'Ana Ficticia', pg_temp.trab('ana_e1'), NULL));
INSERT INTO c VALUES ('dora', pg_temp.mk(:A, 'Dora Ficticia', NULL, pg_temp.emp('ana_e1')));
INSERT INTO c VALUES ('caio', pg_temp.mk(:B, 'Caio Ficticio'));
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;

-- Folhas, pelo fluxo real (funções _v1): 'fechada' (10/2026, Ana em E1 e E2 e Bia),
-- 'aberta' (11/2026, calculada e não fechada) e 'com_pendencia' (08/2026, fechada, na qual o
-- teste injeta depois uma pendência aberta, com os gatilhos desligados).
CREATE TEMP TABLE f (k text PRIMARY KEY, run_id uuid NOT NULL);
GRANT SELECT, INSERT ON f TO dnex_folha_ci_login;
CREATE FUNCTION pg_temp.run(p_k text) RETURNS uuid LANGUAGE sql AS $$ SELECT run_id FROM f WHERE k = p_k $$;
CREATE FUNCTION pg_temp.monta_folha(p_k text, p_comp date, p_pag date, p_contratos text[], p_fechar boolean) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  v text;
  v_sql text[];
BEGIN
  v_sql := ARRAY[format('INSERT INTO f SELECT %L, folha.folha_abrir_v1(%L, ''mensal'', %L)', p_k, p_comp, p_pag)];
  v_sql := v_sql || ARRAY(SELECT format('SELECT folha.folha_calcular_contrato_v1((SELECT run_id FROM f WHERE k = %L), (SELECT cid FROM c WHERE k = %L))', p_k, x) FROM unnest(p_contratos) AS x);
  v_sql := v_sql || format('SELECT folha.folha_concluir_calculo_v1((SELECT run_id FROM f WHERE k = %L))::text', p_k);
  v := pg_temp.pedido('a0000000-0000-0000-0000-000000000029', pg_temp.todas(), gen_random_uuid(), true, false, v_sql);
  IF v LIKE 'ERRO%' THEN RAISE EXCEPTION 'monta_folha(%): %', p_k, v; END IF;
  IF NOT p_fechar THEN RETURN; END IF;
  v_sql := ARRAY(SELECT format('SELECT folha.folha_liberar_pendencia_v1(%L, %L, ''conferido no teste'')', pg_temp.run(p_k), x.codigo)
                   FROM (SELECT DISTINCT p.codigo FROM folha.payroll_pendency p WHERE p.run_id = pg_temp.run(p_k)) x);
  v_sql := v_sql || format('SELECT folha.folha_aprovar_v1(%L)', pg_temp.run(p_k));
  v_sql := v_sql || format('SELECT folha.folha_fechar_v1(%L)::text', pg_temp.run(p_k));
  v := pg_temp.pedido('a0000000-0000-0000-0000-000000000029', pg_temp.todas(), gen_random_uuid(), true, false, v_sql);
  IF v LIKE 'ERRO%' THEN RAISE EXCEPTION 'monta_folha(%) ao fechar: %', p_k, v; END IF;
END
$$;
DO $$ BEGIN
  PERFORM pg_temp.monta_folha('fechada', '2026-10-01', '2026-10-31', ARRAY['ana_e1', 'ana_e2', 'bia'], true);
  PERFORM pg_temp.monta_folha('aberta', '2026-11-01', '2026-11-30', ARRAY['ana_e1'], false);
  PERFORM pg_temp.monta_folha('com_pendencia', '2026-08-01', '2026-08-31', ARRAY['ana_e1'], true);
END $$;
SET LOCAL session_replication_role = replica;   -- gatilhos desligados só para este INSERT
INSERT INTO folha.payroll_pendency (account_id, run_id, result_id, contract_id, codigo, tipo)
SELECT pr.account_id, pr.run_id, pr.result_id, pr.contract_id, 'a_validar:injetada_pelo_teste', 'a_validar'
  FROM folha.payroll_result pr WHERE pr.run_id = pg_temp.run('com_pendencia');
SET LOCAL session_replication_role = origin;

-- Caminho do arquivo no formato sugerido pelo Portal: <conta>/<trabalhador>/<tipo>/<AAAA-MM>/<documento>.pdf
CREATE FUNCTION pg_temp.caminho(p_conta uuid, p_k text, p_tipo text, p_mes text, p_doc uuid) RETURNS text LANGUAGE sql AS $$
  SELECT p_conta::text || '/' || pg_temp.trab(p_k)::text || '/' || p_tipo || '/' || p_mes || '/' || p_doc::text || '.pdf' $$;
-- Chamada de publicação (texto SQL), com o documento identificado por p_doc.
CREATE FUNCTION pg_temp.publica(
  p_k text, p_tipo text, p_comp date, p_titulo text, p_origem text, p_run text DEFAULT NULL, p_doc uuid DEFAULT gen_random_uuid(),
  p_caminho text DEFAULT NULL, p_hash text DEFAULT '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
  p_tamanho bigint DEFAULT 12345, p_conta uuid DEFAULT 'a0000000-0000-0000-0000-000000000029', p_com_estabelecimento boolean DEFAULT false
) RETURNS text LANGUAGE sql AS $$
  SELECT format('SELECT folha.portal_documento_publicar_v1(%L, %L, %L, %L, %L, %L, %L, %L, %L, %L, NULL, %L, %L)::text',
    pg_temp.trab(p_k), pg_temp.emp(p_k), p_tipo, p_comp, p_titulo,
    COALESCE(p_caminho, pg_temp.caminho(p_conta, p_k, p_tipo, to_char(p_comp, 'YYYY-MM'), p_doc)),
    p_hash, p_tamanho, p_origem, pg_temp.run(p_run),
    CASE WHEN p_com_estabelecimento THEN pg_temp.est(p_k) END, p_doc) $$;
CREATE TEMP TABLE d (k text PRIMARY KEY, id uuid NOT NULL);
CREATE FUNCTION pg_temp.doc(p_k text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM d WHERE k = p_k $$;
CREATE TEMP TABLE h (k text PRIMARY KEY, id uuid NOT NULL);
CREATE FUNCTION pg_temp.hab(p_k text) RETURNS uuid LANGUAGE sql AS $$ SELECT id FROM h WHERE k = p_k $$;

-- ===========================================================================
-- 1. Estrutura, RLS e ACL
-- ===========================================================================
CREATE TEMP TABLE tabelas (nome text PRIMARY KEY, com_conta boolean NOT NULL);
INSERT INTO tabelas VALUES ('portal_employee_access', true), ('published_document', true),
  ('published_document_access', true), ('portal_privacy_acceptance', false);
SELECT is(
  (SELECT count(*) FROM tabelas t JOIN pg_class k ON k.oid = ('folha.' || t.nome)::regclass
    WHERE k.relrowsecurity AND k.relforcerowsecurity),
  4::bigint, 'as quatro tabelas existem, com RLS e FORCE');
SELECT is(
  (SELECT string_agg(p.tablename || ':' || p.policyname || '/' || p.cmd || '/'
                     || (SELECT string_agg(r::text, '+' ORDER BY r::text) FROM unnest(p.roles) AS r) || '/'
                     || (p.qual = '(account_id = ( SELECT folha.current_account_id() AS current_account_id))')::text,
                     ' ' ORDER BY p.tablename)
     FROM pg_policies p WHERE p.schemaname = 'folha' AND p.tablename IN (SELECT nome FROM tabelas)),
  'portal_employee_access:portal_employee_access_isolamento/SELECT/dnex_gestao_data_owner+dnex_gestao_folha_worker/true '
  || 'published_document:published_document_isolamento/SELECT/dnex_gestao_data_owner+dnex_gestao_folha_worker/true '
  || 'published_document_access:published_document_access_isolamento/SELECT/dnex_gestao_data_owner+dnex_gestao_folha_worker/true',
  'policies: só leitura por conta, só para worker e data_owner; nenhuma para anon ou authenticated; a de aceite não tem policy');
SELECT is(
  (SELECT string_agg(x.linha, ' ' ORDER BY x.linha COLLATE "C")
     FROM (SELECT t.nome || '<-' || CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END || ':' || a.privilege_type AS linha
             FROM tabelas t JOIN pg_class k ON k.oid = ('folha.' || t.nome)::regclass,
                  LATERAL aclexplode(COALESCE(k.relacl, acldefault('r', k.relowner))) a
            WHERE a.grantee <> k.relowner) x),
  'portal_employee_access<-dnex_gestao_data_owner:SELECT portal_employee_access<-dnex_gestao_folha_worker:SELECT '
  || 'published_document<-dnex_gestao_data_owner:SELECT published_document<-dnex_gestao_folha_worker:SELECT '
  || 'published_document_access<-dnex_gestao_data_owner:SELECT published_document_access<-dnex_gestao_folha_worker:SELECT',
  'ACL exata das tabelas: só SELECT para worker e data_owner; a de aceite, ninguém');
SELECT is_empty(
  $$SELECT t.nome || '<-' || r.papel || ':' || p.priv
      FROM tabelas t
      CROSS JOIN (VALUES ('anon'), ('authenticated'), ('service_role'), ('dnex_gestao_api'), ('dnex_folha_ci_login')) AS r(papel)
      CROSS JOIN unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER']) AS p(priv)
     WHERE has_table_privilege(r.papel, ('folha.' || t.nome)::regclass, p.priv)$$,
  'anon, authenticated, service_role e a sessão de aplicação não têm privilégio efetivo em nenhuma das quatro tabelas');
SELECT is_empty(
  $$SELECT t.nome || '.' || att.attname FROM tabelas t JOIN pg_attribute att ON att.attrelid = ('folha.' || t.nome)::regclass
     WHERE att.attacl IS NOT NULL$$,
  'nenhum privilégio por coluna');
-- Chaves estrangeiras compostas com a conta.
SELECT is_empty(
  $$SELECT con.conname FROM pg_constraint con
     WHERE con.contype = 'f' AND con.conrelid IN (SELECT ('folha.' || nome)::regclass FROM tabelas)
       AND NOT EXISTS (SELECT 1 FROM unnest(con.conkey) AS col
                         JOIN pg_attribute att ON att.attrelid = con.conrelid AND att.attnum = col
                        WHERE att.attname = 'account_id')$$,
  'toda chave estrangeira das tabelas do Portal inclui account_id');
SELECT is(
  (SELECT count(*) FROM pg_constraint con
    WHERE con.contype = 'f' AND con.conrelid IN (SELECT ('folha.' || nome)::regclass FROM tabelas)),
  8::bigint, 'oito chaves estrangeiras (âncora): 2 na habilitação, 5 no documento, 1 no registro de acesso');

CREATE TEMP TABLE acl (sig text PRIMARY KEY, papeis text[] NOT NULL);
INSERT INTO acl VALUES
  ('folha.portal_vinculo_existe(uuid,uuid,uuid)',                 ARRAY[]::text[]),
  ('folha.portal_employee_access_trava()',                        ARRAY[]::text[]),
  ('folha.published_document_trava()',                            ARRAY[]::text[]),
  ('folha.portal_so_insert()',                                    ARRAY[]::text[]),
  ('portal_api.listar_meus_documentos(text,date,date,uuid)',      ARRAY['authenticated']),
  ('portal_api.abrir_meu_documento(uuid,text)',                   ARRAY['authenticated']),
  ('portal_api.meu_aviso_privacidade()',                          ARRAY['authenticated']),
  ('portal_api.aceitar_aviso_privacidade(text)',                  ARRAY['authenticated']),
  ('folha.portal_acesso_habilitar_v1(uuid,uuid,uuid,date)',       ARRAY['dnex_gestao_api']),
  ('folha.portal_acesso_revogar_v1(uuid)',                        ARRAY['dnex_gestao_api']),
  ('folha.portal_acesso_definir_prazo_v1(uuid,date)',             ARRAY['dnex_gestao_api']),
  ('folha.portal_documento_publicar_v1(uuid,uuid,text,date,text,text,text,bigint,text,uuid,uuid,uuid,uuid)', ARRAY['dnex_gestao_api']),
  ('folha.portal_documento_retirar_v1(uuid,text)',                ARRAY['dnex_gestao_api']),
  ('folha.portal_relatorio_visualizacao_v1(date,date,uuid,text)', ARRAY['dnex_gestao_api']);
SELECT is_empty($$SELECT sig FROM acl WHERE to_regprocedure(sig) IS NULL$$, 'as 14 funções da 0029 existem com a assinatura esperada');
SELECT is_empty(
  $$SELECT acl.sig || ' <- ' || papel FROM acl, unnest(acl.papeis) AS papel
     WHERE NOT has_function_privilege(papel, to_regprocedure(acl.sig)::oid, 'execute')$$,
  'ACL: authenticated executa as quatro do empregado; dnex_gestao_api, as seis do escritório');
SELECT is_empty(
  $$SELECT acl.sig || ' <- ' || CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END
      FROM acl JOIN pg_proc p ON p.oid = to_regprocedure(acl.sig)::oid,
           LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
     WHERE a.grantee <> p.proowner
       AND (a.grantee = 0 OR NOT (a.grantee::regrole::text = ANY (acl.papeis)))$$,
  'ACL: nenhum outro papel (nem PUBLIC, anon, service_role ou o worker) executa as funções da 0029');
SELECT is_empty(
  $$SELECT acl.sig FROM acl JOIN pg_proc p ON p.oid = to_regprocedure(acl.sig)::oid
     WHERE acl.sig <> 'folha.portal_so_insert()'
       AND (NOT p.prosecdef OR NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) AS cfg WHERE cfg = 'search_path=pg_catalog, pg_temp'))$$,
  'funções da 0029: SECURITY DEFINER com search_path = pg_catalog, pg_temp');
SELECT is(
  (SELECT string_agg(p.oid::regprocedure::text, ',' ORDER BY p.oid::regprocedure::text) FROM pg_proc p WHERE p.pronamespace = 'portal_api'::regnamespace),
  'portal_api.abrir_meu_documento(uuid,text),portal_api.aceitar_aviso_privacidade(text),portal_api.listar_meus_documentos(text,date,date,uuid),portal_api.meu_aviso_privacidade()',
  'o schema portal_api tem exatamente as quatro funções');
SELECT is(
  (SELECT count(*) FROM pg_class k WHERE k.relnamespace = 'portal_api'::regnamespace), 0::bigint,
  'o schema portal_api não tem tabela, visão nem sequência');
SELECT is(
  (SELECT string_agg(x.linha, ',' ORDER BY x.linha)
     FROM (SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END || ':' || a.privilege_type AS linha
             FROM pg_namespace n, LATERAL aclexplode(COALESCE(n.nspacl, acldefault('n', n.nspowner))) a
            WHERE n.nspname = 'portal_api' AND a.grantee <> n.nspowner) x),
  'authenticated:USAGE', 'schema portal_api: USAGE só para authenticated');
SELECT is(
  (SELECT string_agg(p.oid::regprocedure::text, ',' ORDER BY p.oid::regprocedure::text)
     FROM pg_proc p WHERE p.pronamespace = 'folha'::regnamespace AND has_function_privilege('dnex_gestao_api', p.oid, 'execute')
      AND p.proname LIKE 'portal\_%'),
  (SELECT string_agg(sig, ',' ORDER BY sig) FROM acl WHERE papeis = ARRAY['dnex_gestao_api']),
  'dnex_gestao_api executa, das funções do Portal, exatamente as seis do escritório');
SELECT is(
  pg_get_function_result('portal_api.listar_meus_documentos(text,date,date,uuid)'::regprocedure),
  'TABLE(document_id uuid, employer_id uuid, employer_nome text, establishment_inscricao text, tipo text, competencia date, titulo text, published_at timestamp with time zone, tamanho_bytes bigint, visto_em timestamp with time zone)',
  'listar_meus_documentos devolve exatamente os dez campos do contrato folha.portal-documento-publicado.v1');
SELECT is(
  pg_get_function_result('portal_api.abrir_meu_documento(uuid,text)'::regprocedure) || ' | '
  || pg_get_function_result('portal_api.meu_aviso_privacidade()'::regprocedure) || ' | '
  || pg_get_function_result('portal_api.aceitar_aviso_privacidade(text)'::regprocedure),
  'TABLE(storage_path text, sha256 text) | text | void', 'retornos das outras três funções do empregado');

-- ===========================================================================
-- 2. Habilitação (folha.admin)
-- ===========================================================================
INSERT INTO h SELECT 'ana', pg_temp.faz(:A, ARRAY['folha.read', 'folha.admin'], :S_ADMIN,
  format('SELECT folha.portal_acesso_habilitar_v1(%L, %L, %L)::text', pg_temp.trab('ana_e1'), pg_temp.emp('ana_e1'), :U_ANA))::uuid;
SELECT is(
  (SELECT a.account_id::text || '/' || a.status || '/' || (a.acesso_ate IS NULL)::text || '/' || a.user_id::text || '/' || a.habilitado_por_subject::text
     FROM folha.portal_employee_access a WHERE a.access_id = pg_temp.hab('ana')),
  'a0000000-0000-0000-0000-000000000029/ativo/true/71000000-0000-0000-0000-000000000001/61000000-0000-0000-0000-000000000001',
  'habilitar: linha ativa na conta do contexto, sem data de corte, com o subject de quem habilitou');
SELECT is(
  (SELECT a.actor_subject::text || '/' || (a.detalhe ? 'employee_id')::text || '/' || (a.detalhe::text ~* 'ficticia|2900000')::text
     FROM folha.auditoria a WHERE a.acao = 'portal_habilitar_acesso' AND a.recurso_id = pg_temp.hab('ana')),
  '61000000-0000-0000-0000-000000000001/true/false', 'auditoria da habilitação: subject e identificadores, sem nome nem CPF');
SELECT is(
  pg_temp.le(:A, ARRAY['folha.read', 'folha.admin'], :S_ADMIN,
    format('SELECT folha.portal_acesso_habilitar_v1(%L, %L, %L)::text', pg_temp.trab('ana_e1'), pg_temp.emp('ana_e1'), :U_ANA)),
  pg_temp.hab('ana')::text, 'habilitar de novo o mesmo usuário é idempotente (devolve a mesma habilitação)');
SELECT matches(
  pg_temp.le(:A, ARRAY['folha.read', 'folha.admin'], :S_ADMIN,
    format('SELECT folha.portal_acesso_habilitar_v1(%L, %L, %L)', pg_temp.trab('ana_e1'), pg_temp.emp('ana_e1'), :U_SEM)),
  '^ERRO P0001: Trabalhador .* já tem habilitação ativa de outro usuário neste empregador; revogue antes$',
  'NEG: segundo usuário para o mesmo trabalhador e empregador é recusado');
SELECT matches(
  pg_temp.le(:A, array_remove(pg_temp.todas(), 'folha.admin'), :S_TX, x.sql),
  '^ERRO 42501: Folha assertion missing, expired or revoked$',
  'NEG: sem folha.admin (com as outras quatro), ' || x.caso || ' recusa')
  FROM (VALUES
    ('habilitar', format('SELECT folha.portal_acesso_habilitar_v1(%L, %L, %L)', pg_temp.trab('bia'), pg_temp.emp('bia'), :U_BIA)),
    ('revogar', format('SELECT folha.portal_acesso_revogar_v1(%L)', pg_temp.hab('ana'))),
    ('definir prazo', format('SELECT folha.portal_acesso_definir_prazo_v1(%L, ''2030-01-01'')', pg_temp.hab('ana')))
  ) AS x(caso, sql);
SELECT matches(
  pg_temp.le(x.conta, ARRAY['folha.read', 'folha.admin'], :S_ADMIN, x.sql), x.esperado, 'NEG habilitar: ' || x.caso)
  FROM (VALUES
    ('trabalhador sem vínculo com o empregador (Caio, da conta B, não existe na conta A)', :A::uuid,
       format('SELECT folha.portal_acesso_habilitar_v1(%L, %L, %L)', pg_temp.trab('caio'), pg_temp.emp('ana_e1'), :U_CAIO),
       '^ERRO P0001: Trabalhador .* não encontrado$'),
    ('conta B não habilita trabalhador da conta A', :B::uuid,
       format('SELECT folha.portal_acesso_habilitar_v1(%L, %L, %L)', pg_temp.trab('ana_e1'), pg_temp.emp('ana_e1'), :U_CAIO),
       '^ERRO P0001: Trabalhador .* não encontrado$'),
    ('empregador de outra conta', :A::uuid,
       format('SELECT folha.portal_acesso_habilitar_v1(%L, %L, %L)', pg_temp.trab('ana_e1'), pg_temp.emp('caio'), :U_ANA),
       '^ERRO P0001: Empregador .* não encontrado$'),
    ('Bia nunca trabalhou no empregador E2', :A::uuid,
       format('SELECT folha.portal_acesso_habilitar_v1(%L, %L, %L)', pg_temp.trab('bia'), pg_temp.emp('ana_e2'), :U_BIA),
       '^ERRO 23514: Trabalhador .* não tem vínculo com o empregador '),
    ('o mesmo usuário para outro trabalhador do mesmo empregador (Dora, com o usuário da Ana)', :A::uuid,
       format('SELECT folha.portal_acesso_habilitar_v1(%L, %L, %L)', pg_temp.trab('dora'), pg_temp.emp('dora'), :U_ANA),
       '^ERRO 23505: .*portal_employee_access_usuario_key'),
    ('habilitar de novo o mesmo usuário com outro prazo (não altera em silêncio)', :A::uuid,
       format('SELECT folha.portal_acesso_habilitar_v1(%L, %L, %L, %L)', pg_temp.trab('ana_e1'), pg_temp.emp('ana_e1'), :U_ANA, '2020-01-01'),
       '^ERRO P0001: Trabalhador .* já está habilitado para este usuário com outro prazo; use portal_acesso_definir_prazo_v1$'),
    ('usuário nulo', :A::uuid,
       format('SELECT folha.portal_acesso_habilitar_v1(%L, %L, NULL)', pg_temp.trab('bia'), pg_temp.emp('bia')),
       '^ERRO 22023: ')
  ) AS x(caso, conta, sql, esperado);
INSERT INTO h SELECT 'bia', pg_temp.faz(:A, ARRAY['folha.read', 'folha.admin'], :S_ADMIN,
  format('SELECT folha.portal_acesso_habilitar_v1(%L, %L, %L)::text', pg_temp.trab('bia'), pg_temp.emp('bia'), :U_BIA))::uuid;
INSERT INTO h SELECT 'caio', pg_temp.faz(:B, ARRAY['folha.read', 'folha.admin'], :S_B,
  format('SELECT folha.portal_acesso_habilitar_v1(%L, %L, %L)::text', pg_temp.trab('caio'), pg_temp.emp('caio'), :U_CAIO))::uuid;
SELECT is((SELECT count(*) FROM folha.portal_employee_access WHERE status = 'ativo'), 3::bigint,
  'três habilitações ativas: Ana em E1, Bia em E1 e Caio na conta B (Ana em E2 fica sem)');
-- No dado: nem o dono altera o que não pode mudar, nem apaga.
SELECT throws_ok(format('UPDATE folha.portal_employee_access SET user_id = %L WHERE access_id = %L', :U_SEM, pg_temp.hab('ana')),
  '23001', NULL, 'NEG dado: o usuário da habilitação não é trocado');
SELECT throws_ok(format('DELETE FROM folha.portal_employee_access WHERE access_id = %L', pg_temp.hab('ana')),
  '23001', NULL, 'NEG dado: habilitação não é apagada');
SELECT matches(
  pg_temp.com_espelho(:A, pg_temp.todas(), :S_ADMIN,
    format('INSERT INTO folha.portal_employee_access (account_id, employee_id, employer_id, user_id, habilitado_por_subject) VALUES (%L, %L, %L, %L, %L)',
           :A, pg_temp.trab('dora'), pg_temp.emp('dora'), :U_SEM, :S_ADMIN), 'SELECT 1'),
  '^ERRO 42501: permission denied for table', 'NEG: nem com os privilégios do worker se grava habilitação fora da função');

-- ===========================================================================
-- 3. Publicação (folha.transmit): folha fechada, sem pendência, com resultado do trabalhador
-- ===========================================================================
INSERT INTO d VALUES ('ana_hol', gen_random_uuid()), ('ana_inf', gen_random_uuid()), ('bia_hol', gen_random_uuid()),
  ('ana_e2_hol', gen_random_uuid()), ('caio_inf', gen_random_uuid()), ('ana_fer', gen_random_uuid()), ('ana_inf2', gen_random_uuid()),
  ('bia_res', gen_random_uuid());
SELECT is(
  pg_temp.faz(:A, ARRAY['folha.read', 'folha.transmit'], :S_TX,
    pg_temp.publica('ana_e1', 'holerite', '2026-10-01', 'Holerite 10/2026 Ana E1', 'rotina', 'fechada', pg_temp.doc('ana_hol'),
                    p_hash => '0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF', p_com_estabelecimento => true)),
  pg_temp.doc('ana_hol')::text, 'publicar holerite de folha fechada (folha.transmit), por rotina');
SELECT is(
  (SELECT x.account_id::text || '/' || x.status || '/' || x.origem_publicacao || '/' || x.published_by_subject::text || '/' || x.sha256 || '/' || (x.run_id = pg_temp.run('fechada'))::text
     FROM folha.published_document x WHERE x.document_id = pg_temp.doc('ana_hol')),
  'a0000000-0000-0000-0000-000000000029/publicado/rotina/62000000-0000-0000-0000-000000000002/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef/true',
  'documento na conta do contexto, com o subject de quem publicou; hash gravado em minúsculas');
SELECT is(
  (SELECT a.actor_subject::text || '/' || (a.detalhe->>'tipo') || '/' || (a.detalhe::text ~* 'ficticia|holerite 10')::text
     FROM folha.auditoria a WHERE a.acao = 'portal_publicar_documento' AND a.recurso_id = pg_temp.doc('ana_hol')),
  '62000000-0000-0000-0000-000000000002/holerite/false', 'auditoria da publicação: subject e tipo, sem título nem nome');
SELECT matches(
  pg_temp.le(:A, array_remove(pg_temp.todas(), 'folha.transmit'), :S_ADMIN, x.sql),
  '^ERRO 42501: Folha assertion missing, expired or revoked$',
  'NEG: sem folha.transmit (com as outras quatro), ' || x.caso || ' recusa')
  FROM (VALUES
    ('publicar', pg_temp.publica('bia', 'holerite', '2026-10-01', 'x', 'rotina', 'fechada')),
    ('retirar', format('SELECT folha.portal_documento_retirar_v1(%L, ''motivo'')', pg_temp.doc('ana_hol')))
  ) AS x(caso, sql);
SELECT matches(
  pg_temp.le(x.conta, ARRAY['folha.read', 'folha.transmit'], :S_TX, x.sql), x.esperado, 'NEG publicar: ' || x.caso)
  FROM (VALUES
    ('holerite de folha calculada e não fechada', :A::uuid,
       pg_temp.publica('ana_e1', 'holerite', '2026-11-01', 'x', 'rotina', 'aberta'),
       '^ERRO 23514: Folha .* está em calculated: só documento de folha fechada é publicado$'),
    ('holerite de folha fechada com pendência aberta', :A::uuid,
       pg_temp.publica('ana_e1', 'holerite', '2026-08-01', 'x', 'rotina', 'com_pendencia'),
       '^ERRO 23514: Folha .* tem pendência sem liberação: documento não é publicado$'),
    ('holerite sem folha', :A::uuid,
       pg_temp.publica('ana_e1', 'holerite', '2026-10-01', 'x', 'avulsa'),
       '^ERRO 23514: .*published_document_holerite_exige_folha'),
    ('holerite de trabalhador sem resultado na folha (Dora)', :A::uuid,
       pg_temp.publica('dora', 'holerite', '2026-10-01', 'x', 'rotina', 'fechada'),
       '^ERRO 23514: Trabalhador .* não tem resultado na folha .* para este empregador$'),
    ('holerite com competência diferente da folha', :A::uuid,
       pg_temp.publica('bia', 'holerite', '2026-09-01', 'x', 'rotina', 'fechada'),
       '^ERRO 23514: Holerite: a competência do documento '),
    ('13º a partir de folha mensal', :A::uuid,
       pg_temp.publica('bia', 'decimo_terceiro', '2026-12-01', 'x', 'rotina', 'fechada'),
       '^ERRO 23514: Documento do tipo decimo_terceiro não é publicado a partir de folha do tipo mensal$'),
    ('rescisão a partir de folha mensal', :A::uuid,
       pg_temp.publica('bia', 'rescisao', '2026-10-01', 'x', 'rotina', 'fechada'),
       '^ERRO 23514: Documento do tipo rescisao não é publicado a partir de folha do tipo mensal$'),
    ('aviso de férias apontando para folha', :A::uuid,
       pg_temp.publica('bia', 'ferias_aviso', '2026-10-01', 'x', 'avulsa', 'fechada'),
       '^ERRO 23514: Documento do tipo ferias_aviso não é publicado a partir de folha do tipo mensal$'),
    ('arquivo que já é de outro documento', :A::uuid,
       pg_temp.publica('ana_e1', 'ferias_aviso', '2026-05-01', 'x', 'avulsa', NULL, gen_random_uuid(),
                       (SELECT x.storage_path FROM folha.published_document x WHERE x.document_id = pg_temp.doc('ana_hol'))),
       '^ERRO 23505: .*published_document_storage_path_key'),
    ('rescisão por rotina sem folha', :A::uuid,
       pg_temp.publica('bia', 'rescisao', '2026-10-01', 'x', 'rotina'),
       '^ERRO 23514: .*published_document_origem_exige_folha'),
    ('recibo de férias por parâmetro sem folha', :A::uuid,
       pg_temp.publica('bia', 'ferias_recibo', '2026-10-01', 'x', 'parametro'),
       '^ERRO 23514: .*published_document_origem_exige_folha'),
    ('caminho com prefixo de outro trabalhador', :A::uuid,
       pg_temp.publica('bia', 'holerite', '2026-10-01', 'x', 'rotina', 'fechada',
                       p_caminho => pg_temp.caminho('a0000000-0000-0000-0000-000000000029', 'ana_e1', 'holerite', '2026-10', gen_random_uuid())),
       '^ERRO 23514: .*published_document_storage_path_prefixo'),
    ('caminho com prefixo de outra conta', :A::uuid,
       pg_temp.publica('bia', 'holerite', '2026-10-01', 'x', 'rotina', 'fechada',
                       p_caminho => 'b0000000-0000-0000-0000-000000000029/' || pg_temp.trab('bia')::text || '/holerite/2026-10/x.pdf'),
       '^ERRO 23514: .*published_document_storage_path_prefixo'),
    ('caminho com ..', :A::uuid,
       pg_temp.publica('bia', 'holerite', '2026-10-01', 'x', 'rotina', 'fechada',
                       p_caminho => 'a0000000-0000-0000-0000-000000000029/' || pg_temp.trab('bia')::text || '/../x.pdf'),
       '^ERRO 23514: .*published_document_storage_path_forma'),
    ('caminho com barra inicial', :A::uuid,
       pg_temp.publica('bia', 'holerite', '2026-10-01', 'x', 'rotina', 'fechada',
                       p_caminho => '/a0000000-0000-0000-0000-000000000029/' || pg_temp.trab('bia')::text || '/x.pdf'),
       '^ERRO 23514: .*published_document_storage_path_forma'),
    ('hash que não tem 64 hexadecimais', :A::uuid,
       pg_temp.publica('bia', 'holerite', '2026-10-01', 'x', 'rotina', 'fechada', p_hash => 'abc'),
       '^ERRO 23514: .*published_document_sha256_check'),
    ('tamanho negativo', :A::uuid,
       pg_temp.publica('bia', 'holerite', '2026-10-01', 'x', 'rotina', 'fechada', p_tamanho => -1),
       '^ERRO 23514: .*published_document_tamanho_bytes_check'),
    ('tipo fora da lista', :A::uuid,
       pg_temp.publica('bia', 'contracheque', '2026-10-01', 'x', 'avulsa'),
       '^ERRO 23514: .*published_document_tipo_check'),
    ('origem fora da lista', :A::uuid,
       pg_temp.publica('bia', 'ferias_aviso', '2026-10-01', 'x', 'manual'),
       '^ERRO 23514: .*published_document_origem_publicacao_check'),
    ('competência que não é dia 01', :A::uuid,
       pg_temp.publica('bia', 'ferias_aviso', '2026-10-15', 'x', 'avulsa'),
       '^ERRO 23514: .*published_document_competencia_dia_1'),
    ('informe de rendimentos fora de dezembro', :A::uuid,
       pg_temp.publica('bia', 'informe_rendimentos', '2025-11-01', 'x', 'avulsa'),
       '^ERRO 23514: .*published_document_competencia_anual'),
    ('título vazio', :A::uuid,
       pg_temp.publica('bia', 'ferias_aviso', '2026-10-01', '   ', 'avulsa'),
       '^ERRO 23514: .*published_document_titulo_check'),
    ('segundo holerite publicado da mesma folha para o mesmo trabalhador', :A::uuid,
       pg_temp.publica('ana_e1', 'holerite', '2026-10-01', 'x', 'rotina', 'fechada'),
       '^ERRO 23505: .*published_document_folha_key'),
    ('conta B não publica para trabalhador da conta A', :B::uuid,
       pg_temp.publica('ana_e1', 'ferias_aviso', '2026-10-01', 'x', 'avulsa'),
       '^ERRO P0001: Trabalhador .* não encontrado$'),
    ('folha de outra conta', :B::uuid,
       pg_temp.publica('caio', 'holerite', '2026-10-01', 'x', 'rotina', 'fechada', p_conta => 'b0000000-0000-0000-0000-000000000029'),
       '^ERRO 23503: ')
  ) AS x(caso, conta, sql, esperado);
-- Demais documentos do cenário.
SELECT is(
  pg_temp.faz(:A, ARRAY['folha.read', 'folha.transmit'], :S_TX,
    pg_temp.publica('ana_e1', 'informe_rendimentos', '2025-12-01', 'Informe 2025 Ana E1', 'avulsa', NULL, pg_temp.doc('ana_inf')),
    pg_temp.publica('bia', 'holerite', '2026-10-01', 'Holerite 10/2026 Bia', 'parametro', 'fechada', pg_temp.doc('bia_hol')),
    pg_temp.publica('ana_e2', 'holerite', '2026-10-01', 'Holerite 10/2026 Ana E2', 'rotina', 'fechada', pg_temp.doc('ana_e2_hol')),
    pg_temp.publica('ana_e1', 'ferias_aviso', '2026-07-01', 'Aviso de férias Ana E1', 'avulsa', NULL, pg_temp.doc('ana_fer'))),
  pg_temp.doc('ana_fer')::text,
  'publicar: informe avulso (sem folha), holerite por parâmetro, holerite do segundo empregador e aviso de férias avulso');
SELECT is(
  pg_temp.faz(:B, ARRAY['folha.read', 'folha.transmit'], :S_B,
    pg_temp.publica('caio', 'informe_rendimentos', '2025-12-01', 'Informe 2025 Caio', 'avulsa', NULL, pg_temp.doc('caio_inf'),
                    p_conta => 'b0000000-0000-0000-0000-000000000029')),
  pg_temp.doc('caio_inf')::text, 'conta B publica o informe do Caio');
SELECT matches(
  pg_temp.le(:A, ARRAY['folha.read', 'folha.transmit'], :S_TX,
    pg_temp.publica('ana_e1', 'informe_rendimentos', '2025-12-01', 'x', 'avulsa')),
  '^ERRO 23505: .*published_document_competencia_key', 'NEG: segundo informe publicado do mesmo ano para o mesmo trabalhador e empregador');
SELECT is((SELECT count(*) FROM folha.published_document WHERE status = 'publicado'), 6::bigint, 'seis documentos publicados (âncora)');
SELECT is(
  (SELECT x.contract_id FROM folha.published_document x WHERE x.document_id = pg_temp.doc('ana_hol')), pg_temp.cid('ana_e1'),
  'documento de folha publicado sem contrato recebe o contrato do resultado');
SELECT matches(
  pg_temp.le(:A, ARRAY['folha.read', 'folha.transmit'], :S_TX,
    format('SELECT folha.portal_documento_publicar_v1(%L, %L, ''holerite'', ''2026-10-01'', ''x'', %L, %L, 1, ''rotina'', %L, %L)',
           pg_temp.trab('ana_e1'), pg_temp.emp('ana_e1'), pg_temp.caminho(:A, 'ana_e1', 'holerite', '2026-10', gen_random_uuid()), :HASH,
           pg_temp.run('fechada'), pg_temp.cid('ana_e1'))),
  '^ERRO 23505: .*published_document_folha_key',
  'NEG: segundo holerite da mesma folha informando o contrato (o primeiro foi publicado sem) também é recusado');
-- Erro de restrição sem a linha recusada: o título (que pode trazer nome de pessoa) não volta.
SELECT is(
  pg_temp.le(:A, ARRAY['folha.read', 'folha.transmit'], :S_TX,
    format($q$DO $d$ DECLARE v_m text; v_d text; BEGIN PERFORM folha.portal_documento_publicar_v1(%L, %L, 'ferias_aviso', '2026-10-15', 'Fulano de Tal 12345678901', %L, %L, 1, 'avulsa'); EXCEPTION WHEN check_violation THEN GET STACKED DIAGNOSTICS v_m = MESSAGE_TEXT, v_d = PG_EXCEPTION_DETAIL; PERFORM set_config('teste.erro', v_m || '|' || COALESCE(v_d, ''), true); END $d$ $q$,
           pg_temp.trab('bia'), pg_temp.emp('bia'), pg_temp.caminho(:A, 'bia', 'ferias_aviso', '2026-10', gen_random_uuid()), :HASH),
    'SELECT current_setting(''teste.erro'')'),
  'portal_documento_publicar_v1: documento recusado pela restrição published_document_competencia_dia_1|',
  'erro de restrição na publicação: só o nome da restrição, sem DETAIL com a linha (título, caminho)');
-- No dado: o documento não muda (nem pelo dono), só é retirado.
SELECT throws_ok(format('UPDATE folha.published_document SET %s WHERE document_id = %L', x.set, pg_temp.doc('ana_hol')),
  '23001', NULL, 'NEG dado: documento publicado não aceita ' || x.caso)
  FROM (VALUES
    ('troca de caminho', 'storage_path = storage_path || ''x'''),
    ('troca de hash', 'sha256 = repeat(''f'', 64)'),
    ('troca de tipo', 'tipo = ''ferias_aviso'''),
    ('troca de competência', 'competencia = ''2026-09-01'''),
    ('retirada com troca de título junto', 'status = ''retirado'', retired_by_subject = gen_random_uuid(), retired_at = now(), retired_motivo = ''m'', titulo = ''outro''')
  ) AS x(caso, set);
SELECT throws_ok(format('DELETE FROM folha.published_document WHERE document_id = %L', pg_temp.doc('ana_hol')),
  '23001', NULL, 'NEG dado: documento publicado não é apagado');
SELECT matches(
  pg_temp.com_espelho(:A, pg_temp.todas(), :S_TX,
    format('UPDATE folha.published_document SET titulo = ''x'' WHERE document_id = %L', pg_temp.doc('ana_hol')), 'SELECT 1'),
  '^ERRO 42501: permission denied for table', 'NEG: nem com os privilégios do worker se altera documento fora da função');
-- RLS: a policy é dos papéis worker e data_owner. Exercida com o papel de reserva de CI
-- (dnex_folha_ci, membro do worker, conta por parâmetro de sessão), dentro de subtransação.
CREATE FUNCTION pg_temp.reserva(p_conta uuid, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v_saida text;
BEGIN
  BEGIN
    PERFORM set_config('folha.account_id', p_conta::text, true);
    SET LOCAL ROLE dnex_folha_ci;
    EXECUTE p_sql INTO v_saida;
    RAISE EXCEPTION 'desfaz' USING ERRCODE = 'ZZ001';
  EXCEPTION
    WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_saida := 'ERRO ' || SQLSTATE || ': ' || SQLERRM;
  END;
  RETURN v_saida;
END
$$;
SELECT is(
  pg_temp.reserva(:A,
    'SELECT (SELECT count(*) FROM folha.published_document)::text || ''/'' || (SELECT count(*) FROM folha.published_document WHERE account_id = ''b0000000-0000-0000-0000-000000000029'')::text || ''/'' || (SELECT count(*) FROM folha.portal_employee_access)::text'),
  '5/0/2', 'RLS (membro do worker): a conta A lê os seus 5 documentos e 2 habilitações, nenhum da conta B');
SELECT is(
  pg_temp.com_espelho(:A, ARRAY['folha.read'], :S_READ,
    'SELECT (SELECT count(*) FROM folha.published_document)::text || ''/'' || (SELECT count(*) FROM folha.portal_employee_access)::text'),
  '0/0', 'RLS: quem tem o GRANT mas não é worker nem data_owner não lê linha alguma (a policy é desses dois papéis)');

-- ===========================================================================
-- 4. Empregado: lista (testes 1 e 2 da frente Portal)
-- ===========================================================================
SELECT is(pg_temp.titulos(:U_ANA), 'Aviso de férias Ana E1,Holerite 10/2026 Ana E1,Informe 2025 Ana E1',
  'Ana vê os seus três documentos do empregador E1: não vê os da Bia (mesma conta e empregador), nem os do Caio (outra conta), nem o próprio do empregador E2 (sem habilitação lá)');
SELECT is(pg_temp.titulos(:U_BIA), 'Holerite 10/2026 Bia', 'Bia vê só o seu');
SELECT is(pg_temp.titulos(:U_CAIO), 'Informe 2025 Caio', 'Caio (conta B) vê só o seu');
SELECT is(pg_temp.titulos(:U_SEM), '', 'usuário autenticado sem habilitação não vê nada');
SELECT is(pg_temp.titulos(NULL), '', 'requisição sem claim (auth.uid() nulo): vazio');
SELECT is(
  pg_temp.portal(:U_ANA, 'SELECT string_agg(d.titulo, '' > '') FROM portal_api.listar_meus_documentos() d'),
  'Holerite 10/2026 Ana E1 > Aviso de férias Ana E1 > Informe 2025 Ana E1',
  'ordem da lista: competência decrescente');
SELECT is(
  pg_temp.portal(:U_ANA, format('SELECT (SELECT string_agg(k, '','' ORDER BY k) FROM jsonb_object_keys(to_jsonb(d)) AS k) FROM portal_api.listar_meus_documentos() d WHERE d.document_id = %L', pg_temp.doc('ana_hol'))),
  'competencia,document_id,employer_id,employer_nome,establishment_inscricao,published_at,tamanho_bytes,tipo,titulo,visto_em',
  'item da lista: exatamente os dez campos do contrato (nenhum a mais: nada de conta, caminho ou hash)');
SELECT is(
  pg_temp.portal(:U_ANA, format('SELECT concat_ws(''|'', d.employer_id, d.employer_nome, d.establishment_inscricao, d.tipo, to_jsonb(d)->>''competencia'', d.tamanho_bytes, (d.visto_em IS NULL)) FROM portal_api.listar_meus_documentos() d WHERE d.document_id = %L', pg_temp.doc('ana_hol'))),
  (SELECT concat_ws('|', e.employer_id, e.razao_social, s.inscricao, 'holerite', '2026-10-01', 12345, true)
     FROM folha.employer e JOIN folha.establishment s ON s.employer_id = e.employer_id WHERE e.employer_id = pg_temp.emp('ana_e1')),
  'item: razão social do empregador, inscrição do estabelecimento sem máscara, competência AAAA-MM-DD, tamanho e visto_em nulo antes de abrir');
SELECT is(
  pg_temp.portal(:U_ANA, format('SELECT (d.establishment_inscricao IS NULL)::text FROM portal_api.listar_meus_documentos() d WHERE d.document_id = %L', pg_temp.doc('ana_inf'))),
  'true', 'item sem estabelecimento: establishment_inscricao nulo');
SELECT is(
  pg_temp.portal(:U_ANA, x.sql), x.esperado, 'filtro: ' || x.caso)
  FROM (VALUES
    ('por tipo', 'SELECT string_agg(d.titulo, '','') FROM portal_api.listar_meus_documentos(p_tipo => ''holerite'') d', 'Holerite 10/2026 Ana E1'),
    ('por período', 'SELECT string_agg(d.titulo, '','') FROM portal_api.listar_meus_documentos(p_de => ''2026-01-01'', p_ate => ''2026-09-01'') d', 'Aviso de férias Ana E1'),
    ('pelo empregador habilitado', format('SELECT count(*)::text FROM portal_api.listar_meus_documentos(p_employer_id => %L) d', pg_temp.emp('ana_e1')), '3'),
    ('pelo empregador E2, onde ela trabalha mas não foi habilitada (só restringe)', format('SELECT count(*)::text FROM portal_api.listar_meus_documentos(p_employer_id => %L) d', pg_temp.emp('ana_e2')), '0'),
    ('por empregador de outra conta', format('SELECT count(*)::text FROM portal_api.listar_meus_documentos(p_employer_id => %L) d', pg_temp.emp('caio')), '0'),
    ('por tipo desconhecido', 'SELECT count(*)::text FROM portal_api.listar_meus_documentos(p_tipo => ''qualquer'') d', '0')
  ) AS x(caso, sql, esperado);
SELECT is((SELECT count(*) FROM folha.published_document_access), 0::bigint, 'listar não grava registro de acesso');

-- ===========================================================================
-- 5. Empregado: abrir (testes 1, 2, 5 e 6)
-- ===========================================================================
SELECT is(
  pg_temp.portal_faz(:U_ANA, format('SELECT a.storage_path || ''|'' || a.sha256 FROM portal_api.abrir_meu_documento(%L, ''abriu'') a', pg_temp.doc('ana_hol'))),
  (SELECT x.storage_path || '|' || x.sha256 FROM folha.published_document x WHERE x.document_id = pg_temp.doc('ana_hol')),
  'Ana abre o próprio holerite: recebe o caminho e o hash');
SELECT is(
  (SELECT string_agg(l.account_id::text || '/' || l.user_id::text || '/' || l.acao || '/' || (l.employee_id = pg_temp.trab('ana_e1'))::text, ';')
     FROM folha.published_document_access l WHERE l.document_id = pg_temp.doc('ana_hol')),
  'a0000000-0000-0000-0000-000000000029/71000000-0000-0000-0000-000000000001/abriu/true',
  'o acesso foi gravado na mesma transação: conta, usuário, ação e trabalhador');
SELECT is(
  pg_temp.portal(:U_ANA, format('SELECT (d.visto_em IS NOT NULL)::text FROM portal_api.listar_meus_documentos() d WHERE d.document_id = %L', pg_temp.doc('ana_hol'))),
  'true', 'visto_em preenchido depois de abrir');
SELECT is(
  pg_temp.portal_faz(:U_ANA, format('SELECT count(*)::text FROM portal_api.abrir_meu_documento(%L, ''baixou'') a', pg_temp.doc('ana_hol'))),
  '1', 'baixar também devolve uma linha e grava');
SELECT is(
  (SELECT count(*)::text || '/' || (min(l.at) = (SELECT l2.at FROM folha.published_document_access l2 WHERE l2.document_id = pg_temp.doc('ana_hol') AND l2.acao = 'abriu'))::text
     FROM folha.published_document_access l WHERE l.document_id = pg_temp.doc('ana_hol')),
  '2/true', 'dois registros; visto_em é o primeiro');
SELECT is(
  pg_temp.portal_faz(x.uid, format('SELECT count(*)::text FROM portal_api.abrir_meu_documento(%L, ''abriu'') a', x.doc)),
  '0', 'NEG abrir: ' || x.caso || ' devolve nenhuma linha')
  FROM (VALUES
    ('Bia tentando o holerite da Ana (mesma conta, mesmo empregador)', :U_BIA::uuid, pg_temp.doc('ana_hol')),
    ('Caio tentando o holerite da Ana (outra conta)', :U_CAIO::uuid, pg_temp.doc('ana_hol')),
    ('Ana tentando o informe do Caio (outra conta)', :U_ANA::uuid, pg_temp.doc('caio_inf')),
    ('Ana tentando o próprio holerite do empregador E2 (sem habilitação lá)', :U_ANA::uuid, pg_temp.doc('ana_e2_hol')),
    ('usuário sem habilitação', :U_SEM::uuid, pg_temp.doc('ana_hol')),
    ('requisição sem claim', NULL::uuid, pg_temp.doc('ana_hol')),
    ('documento que não existe', :U_ANA::uuid, gen_random_uuid()),
    ('documento nulo', :U_ANA::uuid, NULL::uuid)
  ) AS x(caso, uid, doc);
SELECT is((SELECT count(*) FROM folha.published_document_access), 2::bigint, 'nenhuma das oito tentativas recusadas gravou acesso');
SELECT is(
  pg_temp.portal_faz(:U_ANA, format('SELECT count(*)::text FROM generate_series(1, 50) AS g, LATERAL portal_api.abrir_meu_documento(%L, ''abriu'') a', pg_temp.doc('ana_hol')))
  || '/' || (SELECT count(*) FROM folha.published_document_access)::text,
  '50/2', 'abrir 50 vezes em seguida devolve o caminho 50 vezes e não grava linha nova (mesma ação em menos de 60 s)');
SELECT matches(
  pg_temp.portal(:U_ANA, format('SELECT count(*) FROM portal_api.abrir_meu_documento(%L, ''imprimiu'')', pg_temp.doc('ana_hol'))),
  '^ERRO 22023: abrir_meu_documento: p_acao deve ser abriu ou baixou$', 'NEG abrir: ação fora da lista é erro, sem dado pessoal na mensagem');
SELECT is(
  pg_temp.portal(:U_BIA, format('SELECT (d.visto_em IS NULL)::text FROM portal_api.listar_meus_documentos() d WHERE d.document_id = %L', pg_temp.doc('bia_hol'))),
  'true', 'o acesso de um usuário não preenche o visto_em de documento de outro');

-- ===========================================================================
-- 6. Revogação, data de corte e desligamento (testes 3 e 4)
-- ===========================================================================
\set HOJE_SP '(now() AT TIME ZONE ''America/Sao_Paulo'')::date'
SELECT is(
  pg_temp.faz(:A, ARRAY['folha.read', 'folha.admin'], :S_ADMIN,
    format('SELECT folha.portal_acesso_definir_prazo_v1(%L, %L)::text', pg_temp.hab('ana'), :HOJE_SP - 1)),
  '', 'definir prazo: acesso da Ana até ontem');
SELECT is(pg_temp.titulos(:U_ANA), '', 'acesso_ate ontem: vazio');
SELECT is(
  pg_temp.portal_faz(:U_ANA, format('SELECT count(*)::text FROM portal_api.abrir_meu_documento(%L, ''abriu'') a', pg_temp.doc('ana_hol'))),
  '0', 'acesso_ate ontem: não abre');
SELECT is(
  pg_temp.faz(:A, ARRAY['folha.read', 'folha.admin'], :S_ADMIN,
    format('SELECT folha.portal_acesso_definir_prazo_v1(%L, %L)::text', pg_temp.hab('ana'), :HOJE_SP)),
  '', 'definir prazo: acesso da Ana até hoje');
SELECT is(pg_temp.titulos(:U_ANA), 'Aviso de férias Ana E1,Holerite 10/2026 Ana E1,Informe 2025 Ana E1', 'acesso_ate hoje (data de São Paulo): enxerga');
SELECT is(
  pg_temp.faz(:A, ARRAY['folha.read', 'folha.admin'], :S_ADMIN,
    format('SELECT folha.portal_acesso_definir_prazo_v1(%L, NULL)::text', pg_temp.hab('ana'))),
  '', 'definir prazo: sem data de corte');
SELECT is(pg_temp.titulos(:U_ANA), 'Aviso de férias Ana E1,Holerite 10/2026 Ana E1,Informe 2025 Ana E1', 'acesso_ate nulo: enxerga');
SELECT is(
  (SELECT count(*) FROM folha.auditoria a WHERE a.acao = 'portal_definir_prazo_acesso' AND a.recurso_id = pg_temp.hab('ana') AND a.actor_subject = :S_ADMIN),
  3::bigint, 'cada mudança de prazo fica na auditoria, com o subject');
-- Desligamento: não corta o acesso. A Bia é desligada (contrato encerrado e inativo).
UPDATE folha.employment_contract SET data_demissao = '2026-10-31', status = 'inativo' WHERE contract_id = pg_temp.cid('bia');
SELECT is(pg_temp.titulos(:U_BIA), 'Holerite 10/2026 Bia', 'contrato com data_demissao e habilitação ativa: continua enxergando');
SELECT is(
  pg_temp.faz(:A, ARRAY['folha.read', 'folha.transmit'], :S_TX,
    pg_temp.publica('bia', 'rescisao', '2026-10-01', 'Rescisão Bia', 'avulsa', NULL, pg_temp.doc('bia_res'))),
  pg_temp.doc('bia_res')::text, 'rescisão publicada depois do desligamento');
SELECT is(pg_temp.titulos(:U_BIA), 'Holerite 10/2026 Bia,Rescisão Bia', 'documento publicado depois do desligamento fica visível');
-- A Bia abre o holerite dela antes de perder o acesso (o registro fica).
SELECT is(
  pg_temp.portal_faz(:U_BIA, format('SELECT count(*)::text FROM portal_api.abrir_meu_documento(%L, ''abriu'') a', pg_temp.doc('bia_hol')),
    format('SELECT (d.visto_em IS NOT NULL)::text FROM portal_api.listar_meus_documentos() d WHERE d.document_id = %L', pg_temp.doc('bia_hol'))),
  'true', 'a Bia abre o próprio holerite e passa a ver visto_em');
-- Revogação.
SELECT is(
  pg_temp.faz(:A, ARRAY['folha.read', 'folha.admin'], :S_ADMIN, format('SELECT folha.portal_acesso_revogar_v1(%L)::text', pg_temp.hab('bia'))),
  '', 'revogar a habilitação da Bia (folha.admin)');
SELECT is(
  (SELECT a.status || '/' || a.revogado_por_subject::text || '/' || (a.revogado_em IS NOT NULL)::text FROM folha.portal_employee_access a WHERE a.access_id = pg_temp.hab('bia')),
  'revogado/61000000-0000-0000-0000-000000000001/true', 'revogação com o subject de quem revogou');
SELECT is(pg_temp.titulos(:U_BIA), '', 'status revogado: vazio');
SELECT is(
  pg_temp.portal_faz(:U_BIA, format('SELECT count(*)::text FROM portal_api.abrir_meu_documento(%L, ''abriu'') a', pg_temp.doc('bia_hol'))),
  '0', 'status revogado: não abre');
SELECT is(
  pg_temp.faz(:A, ARRAY['folha.read', 'folha.admin'], :S_ADMIN, format('SELECT folha.portal_acesso_revogar_v1(%L)::text', pg_temp.hab('bia'))),
  '', 'revogar de novo é idempotente');
SELECT matches(
  pg_temp.le(x.conta, ARRAY['folha.read', 'folha.admin'], :S_ADMIN, x.sql), x.esperado, 'NEG habilitação: ' || x.caso)
  FROM (VALUES
    ('prazo em habilitação revogada', :A::uuid, format('SELECT folha.portal_acesso_definir_prazo_v1(%L, NULL)', pg_temp.hab('bia')), '^ERRO P0001: Habilitação ativa .* não encontrada$'),
    ('conta B não revoga habilitação da conta A', :B::uuid, format('SELECT folha.portal_acesso_revogar_v1(%L)', pg_temp.hab('ana')), '^ERRO P0001: Habilitação .* não encontrada$'),
    ('conta B não muda prazo de habilitação da conta A', :B::uuid, format('SELECT folha.portal_acesso_definir_prazo_v1(%L, ''2020-01-01'')', pg_temp.hab('ana')), '^ERRO P0001: Habilitação ativa .* não encontrada$')
  ) AS x(caso, conta, sql, esperado);
SELECT throws_ok(format('UPDATE folha.portal_employee_access SET status = ''ativo'', revogado_por_subject = NULL, revogado_em = NULL WHERE access_id = %L', pg_temp.hab('bia')),
  '23001', NULL, 'NEG dado: habilitação revogada não volta a ativa');
-- Habilitar depois do desligamento (contrato já encerrado), para outro usuário: linha nova.
INSERT INTO h SELECT 'bia2', pg_temp.faz(:A, ARRAY['folha.read', 'folha.admin'], :S_ADMIN,
  format('SELECT folha.portal_acesso_habilitar_v1(%L, %L, %L)::text', pg_temp.trab('bia'), pg_temp.emp('bia'), :U_ANA2))::uuid;
SELECT is(
  pg_temp.titulos(:U_ANA2) || ' / ' || pg_temp.titulos(:U_BIA),
  'Holerite 10/2026 Bia,Rescisão Bia / ',
  'habilitação feita depois do desligamento vale; a revogada continua sem acesso');
SELECT is(
  pg_temp.portal(:U_ANA2, format('SELECT (d.visto_em IS NULL)::text FROM portal_api.listar_meus_documentos() d WHERE d.document_id = %L', pg_temp.doc('bia_hol'))),
  'true', 'visto_em é por usuário: o acesso do usuário anterior (Bia) ao mesmo documento não preenche o do novo');
SELECT is(
  (SELECT count(*) FROM folha.published_document_access l WHERE l.document_id = pg_temp.doc('bia_hol') AND l.user_id = :U_BIA), 1::bigint,
  'âncora: o acesso da Bia a esse documento existe');

-- ===========================================================================
-- 7. Retirada (teste 5)
-- ===========================================================================
SELECT matches(
  pg_temp.le(:A, ARRAY['folha.read', 'folha.transmit'], :S_TX, format('SELECT folha.portal_documento_retirar_v1(%L, ''  '')', pg_temp.doc('ana_inf'))),
  '^ERRO 22023: ', 'NEG retirar: motivo obrigatório');
SELECT matches(
  pg_temp.le(:B, ARRAY['folha.read', 'folha.transmit'], :S_B, format('SELECT folha.portal_documento_retirar_v1(%L, ''motivo'')', pg_temp.doc('ana_inf'))),
  '^ERRO P0001: Documento .* não encontrado$', 'NEG retirar: conta B não retira documento da conta A');
SELECT is(
  pg_temp.faz(:A, ARRAY['folha.read', 'folha.transmit'], :S_TX, format('SELECT folha.portal_documento_retirar_v1(%L, ''valor corrigido'')::text', pg_temp.doc('ana_inf'))),
  '', 'retirar o informe da Ana (folha.transmit)');
SELECT is(
  (SELECT x.status || '/' || x.retired_by_subject::text || '/' || x.retired_motivo || '/' || (x.retired_at IS NOT NULL)::text FROM folha.published_document x WHERE x.document_id = pg_temp.doc('ana_inf')),
  'retirado/62000000-0000-0000-0000-000000000002/valor corrigido/true', 'retirada com subject, motivo e data');
SELECT is(pg_temp.titulos(:U_ANA), 'Aviso de férias Ana E1,Holerite 10/2026 Ana E1', 'documento retirado some da lista');
SELECT is(
  pg_temp.portal_faz(:U_ANA, format('SELECT count(*)::text FROM portal_api.abrir_meu_documento(%L, ''abriu'') a', pg_temp.doc('ana_inf')))
  || '/' || (SELECT count(*) FROM folha.published_document_access l WHERE l.document_id = pg_temp.doc('ana_inf'))::text,
  '0/0', 'documento retirado não abre e não grava acesso');
SELECT is(
  pg_temp.faz(:A, ARRAY['folha.read', 'folha.transmit'], :S_TX, format('SELECT folha.portal_documento_retirar_v1(%L, ''de novo'')::text', pg_temp.doc('ana_inf'))),
  '', 'retirar de novo é idempotente');
SELECT is(
  (SELECT x.retired_motivo FROM folha.published_document x WHERE x.document_id = pg_temp.doc('ana_inf')), 'valor corrigido',
  'a segunda retirada não altera a primeira');
SELECT throws_ok(format('UPDATE folha.published_document SET status = ''publicado'', retired_by_subject = NULL, retired_at = NULL, retired_motivo = NULL WHERE document_id = %L', pg_temp.doc('ana_inf')),
  '23001', NULL, 'NEG dado: documento retirado não volta a publicado');
SELECT is(
  pg_temp.faz(:A, ARRAY['folha.read', 'folha.transmit'], :S_TX,
    pg_temp.publica('ana_e1', 'informe_rendimentos', '2025-12-01', 'Informe 2025 Ana E1 (corrigido)', 'avulsa', NULL, pg_temp.doc('ana_inf2'))),
  pg_temp.doc('ana_inf2')::text, 'corrigir = retirar e publicar outro: o novo informe do mesmo ano é aceito');
SELECT is(pg_temp.titulos(:U_ANA), 'Aviso de férias Ana E1,Holerite 10/2026 Ana E1,Informe 2025 Ana E1 (corrigido)', 'a Ana vê o informe novo e não o retirado');

-- ===========================================================================
-- 8. Quem não chega (teste 7) e identidade forjada
-- ===========================================================================
SELECT matches(
  pg_temp.portal_como('anon', x.uid, false, ARRAY[x.sql]),
  '^ERRO 42501: permission denied for schema portal_api$', 'anon não executa ' || x.caso)
  FROM (VALUES
    ('listar_meus_documentos', NULL::uuid, 'SELECT count(*) FROM portal_api.listar_meus_documentos()'),
    ('listar_meus_documentos, mesmo com claim de usuário habilitado', :U_ANA::uuid, 'SELECT count(*) FROM portal_api.listar_meus_documentos()'),
    ('abrir_meu_documento', :U_ANA::uuid, 'SELECT count(*) FROM portal_api.abrir_meu_documento(gen_random_uuid(), ''abriu'')'),
    ('meu_aviso_privacidade', :U_ANA::uuid, 'SELECT portal_api.meu_aviso_privacidade()'),
    ('aceitar_aviso_privacidade', :U_ANA::uuid, 'SELECT portal_api.aceitar_aviso_privacidade(''v1'')')
  ) AS x(caso, uid, sql);
SELECT matches(
  pg_temp.portal(:U_ANA, x.sql),
  '^ERRO 42501: permission denied for schema folha$', 'authenticated não ' || x.caso)
  FROM (VALUES
    ('lê folha.published_document', 'SELECT count(*) FROM folha.published_document'),
    ('lê folha.portal_employee_access', 'SELECT count(*) FROM folha.portal_employee_access'),
    ('lê folha.published_document_access', 'SELECT count(*) FROM folha.published_document_access'),
    ('lê folha.portal_privacy_acceptance', 'SELECT count(*) FROM folha.portal_privacy_acceptance'),
    ('grava registro de acesso', 'INSERT INTO folha.published_document_access (account_id, document_id, employee_id, user_id, acao) VALUES (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), ''abriu'')'),
    ('chama função do escritório', 'SELECT folha.portal_acesso_habilitar_v1(gen_random_uuid(), gen_random_uuid(), gen_random_uuid())'),
    ('chama o relatório do escritório', 'SELECT count(*) FROM folha.portal_relatorio_visualizacao_v1()')
  ) AS x(caso, sql);
-- A sessão de aplicação do escritório (qualquer sessão do Gestão) poderia definir os parâmetros
-- de requisição e se passar por um empregado; por isso não executa as funções do empregado.
SELECT matches(
  pg_temp.pedido(:A, pg_temp.todas(), :S_ADMIN, false, x.espelho,
    ARRAY[format('SELECT set_config(''request.jwt.claims'', %L, true)', json_build_object('sub', :U_ANA::uuid)::text),
          'SELECT count(*) FROM portal_api.listar_meus_documentos()']),
  '^ERRO 42501: permission denied for schema portal_api$',
  'sessão do escritório' || x.caso || ' com claim forjado não executa função do empregado')
  FROM (VALUES ('', false), (' (com os privilégios do worker)', true)) AS x(caso, espelho);

-- ===========================================================================
-- 9. Aviso de privacidade
-- ===========================================================================
SELECT is(pg_temp.portal(:U_ANA, 'SELECT COALESCE(portal_api.meu_aviso_privacidade(), ''(nulo)'')'), '(nulo)', 'sem aceite: nulo');
SELECT is(
  pg_temp.portal_faz(:U_ANA, 'SELECT portal_api.aceitar_aviso_privacidade(''2026-11'')', 'SELECT portal_api.meu_aviso_privacidade()'),
  '2026-11', 'aceitar e ler a versão aceita');
SELECT is(
  pg_temp.portal_faz(:U_ANA, 'SELECT pg_sleep(0.01)', 'SELECT portal_api.aceitar_aviso_privacidade(''2027-01'')', 'SELECT portal_api.meu_aviso_privacidade()'),
  '2027-01', 'a versão devolvida é a aceita mais recentemente');
SELECT is(
  pg_temp.portal_faz(:U_ANA, 'SELECT pg_sleep(0.01)', 'SELECT portal_api.aceitar_aviso_privacidade(''2026-11'')', 'SELECT portal_api.meu_aviso_privacidade()'),
  '2027-01', 'aceitar de novo uma versão já aceita é idempotente (não vira a mais recente)');
SELECT is((SELECT count(*) FROM folha.portal_privacy_acceptance WHERE user_id = :U_ANA), 2::bigint, 'dois aceites da Ana');
SELECT is(pg_temp.portal(:U_CAIO, 'SELECT COALESCE(portal_api.meu_aviso_privacidade(), ''(nulo)'')'), '(nulo)', 'o aceite é do usuário: o Caio não tem');
SELECT matches(
  pg_temp.portal(:U_ANA, format('SELECT portal_api.aceitar_aviso_privacidade(%L)', x.v)),
  '^ERRO 22023: aceitar_aviso_privacidade: p_versao inválida$', 'NEG aceite: versão ' || x.caso)
  FROM (VALUES ('nula', NULL), ('vazia', ''), ('com espaço', 'v 1'), ('com mais de 32 caracteres', repeat('a', 33)), ('com aspas', 'v''1')) AS x(caso, v);
SELECT is(
  pg_temp.portal_faz(:U_SEM, 'SELECT portal_api.aceitar_aviso_privacidade(''2026-11'')', 'SELECT COALESCE(portal_api.meu_aviso_privacidade(), ''(nulo)'')')
  || '/' || pg_temp.portal_faz(NULL, 'SELECT portal_api.aceitar_aviso_privacidade(''2026-11'')', 'SELECT COALESCE(portal_api.meu_aviso_privacidade(), ''(nulo)'')')
  || '/' || (SELECT count(*) FROM folha.portal_privacy_acceptance WHERE user_id <> :U_ANA)::text,
  '(nulo)/(nulo)/0', 'usuário sem habilitação e requisição sem claim não gravam aceite');
SELECT is(
  pg_temp.portal_faz(:U_BIA, 'SELECT portal_api.aceitar_aviso_privacidade(''2026-11'')', 'SELECT portal_api.meu_aviso_privacidade()'),
  '2026-11', 'usuário com habilitação revogada ainda registra o aceite (já foi habilitado)');
SELECT matches(
  pg_temp.portal(:U_CAIO, 'SELECT portal_api.aceitar_aviso_privacidade(''v'' || g) FROM generate_series(1, 6) AS g', 'SELECT 1'),
  '^ERRO 54000: aceitar_aviso_privacidade: muitas versões aceitas em 24 horas; tente depois$',
  'NEG aceite: a sexta versão nova em 24 horas é recusada (o limite passa com o tempo; não trava de vez)');
SELECT is(
  pg_temp.portal(:U_CAIO, 'SELECT portal_api.aceitar_aviso_privacidade(''v'' || g) FROM generate_series(1, 5) AS g', 'SELECT portal_api.aceitar_aviso_privacidade(''v3'')', 'SELECT portal_api.meu_aviso_privacidade()'),
  'v5', 'aceite: cinco versões novas cabem, e repetir uma já aceita não conta');
SELECT throws_ok($$UPDATE folha.portal_privacy_acceptance SET accepted_at = now()$$, '23001', NULL, 'NEG dado: aceite não é alterado');
SELECT throws_ok($$DELETE FROM folha.portal_privacy_acceptance$$, '23001', NULL, 'NEG dado: aceite não é apagado');

-- ===========================================================================
-- 10. Registro de acesso (só INSERT) e relatório de visualização (folha.read)
-- ===========================================================================
SELECT throws_ok($$UPDATE folha.published_document_access SET acao = 'baixou'$$, '23001', NULL, 'NEG dado: registro de acesso não é alterado');
SELECT throws_ok($$DELETE FROM folha.published_document_access$$, '23001', NULL, 'NEG dado: registro de acesso não é apagado');
SELECT throws_ok($$TRUNCATE folha.published_document_access$$, '23001', NULL, 'NEG dado: registro de acesso não é truncado');
SELECT throws_ok(format('TRUNCATE folha.%I CASCADE', t), '23001', NULL, 'NEG dado: ' || t || ' não é truncada')
  FROM unnest(ARRAY['portal_privacy_acceptance', 'portal_employee_access', 'published_document']) AS t;
SELECT is(
  pg_temp.le(:A, ARRAY['folha.read'], :S_READ,
    'SELECT string_agg(r.titulo || ''='' || r.status || ''/'' || (r.primeiro_acesso_em IS NOT NULL)::text || ''/'' || r.total_acessos, '' ; '' ORDER BY r.titulo) FROM folha.portal_relatorio_visualizacao_v1() r'),
  'Aviso de férias Ana E1=publicado/false/0 ; Holerite 10/2026 Ana E1=publicado/true/2 ; Holerite 10/2026 Ana E2=publicado/false/0 ; '
  || 'Holerite 10/2026 Bia=publicado/true/1 ; Informe 2025 Ana E1=retirado/false/0 ; Informe 2025 Ana E1 (corrigido)=publicado/false/0 ; Rescisão Bia=publicado/false/0',
  'relatório (folha.read): todos os documentos da conta, com o primeiro acesso e o total; os retirados aparecem como retirados');
SELECT is(
  pg_temp.le(:A, ARRAY['folha.read'], :S_READ,
    format('SELECT (r.primeiro_acesso_em = %L)::text || ''/'' || (r.employee_id = %L)::text FROM folha.portal_relatorio_visualizacao_v1(p_tipo => ''holerite'', p_employer_id => %L) r WHERE r.document_id = %L',
           (SELECT min(l.at) FROM folha.published_document_access l WHERE l.document_id = pg_temp.doc('ana_hol')),
           pg_temp.trab('ana_e1'), pg_temp.emp('ana_e1'), pg_temp.doc('ana_hol'))),
  'true/true', 'relatório: primeiro acesso exato e trabalhador do documento; filtros por tipo e empregador');
SELECT is(
  pg_temp.le(:B, ARRAY['folha.read'], :S_B, 'SELECT string_agg(r.titulo, '','') FROM folha.portal_relatorio_visualizacao_v1() r'),
  'Informe 2025 Caio', 'relatório: a conta B vê só os seus');
SELECT matches(
  pg_temp.le(:A, NULL, NULL, 'SELECT count(*) FROM folha.portal_relatorio_visualizacao_v1()'),
  '^ERRO 42501: ', 'relatório sem contexto da Folha: recusa');

SELECT * FROM finish();
ROLLBACK;
