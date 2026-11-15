-- DNEX Folha — Testes pgTAP da migration 0024: empregador em quatro níveis e conta da sessão.
-- Cobre: estrutura, RLS com FORCE, isolamento entre contas em cada tabela nova, a conta da
-- sessão pelo protocolo de contexto do gestao_auth, a reserva de CI, coerência da hierarquia,
-- vigências sem sobreposição (inclusive no catálogo de parâmetros da 0023), rateio somando
-- 100 e ACL.
--
-- Como os testes exercem a RLS: o arquivo roda como superusuário (que ignora RLS mesmo com
-- FORCE). Tudo o que precisa valer "para um papel" passa por pg_temp.como(), que, dentro
-- de uma subtransação sempre desfeita:
--   1. assume o login de teste (SET LOCAL SESSION AUTHORIZATION: muda o session_user, que é
--      a que o protocolo do gestao_auth vincula o contexto) e o papel efetivo;
--   2. se receber uma asserção, abre o contexto com gestao_auth.begin_request, como a
--      aplicação faria;
--   3. opcionalmente adultera o estado como superusuário (para provar cada vínculo);
--   4. executa os comandos e devolve o resultado do último como texto, ou
--      'ERRO <sqlstate>: <mensagem>'.
-- Nada do que como() grava persiste; o que precisa persistir é gravado no setup.
-- Papéis: dnex_folha_ci_login (login de teste, membro só do worker),
-- dnex_gestao_folha_worker (o de produção) e dnex_folha_ci (reserva de CI).
-- O grupo 'folha_worker' do protocolo existe só no bootstrap de CI (ver tests/ci/bootstrap.sql).
-- Os valores e a chave de parâmetro deste arquivo são fictícios; nenhum é dado normativo.
BEGIN;

SELECT plan(165);

-- ---------------------------------------------------------------------------
-- Apoio
-- ---------------------------------------------------------------------------
CREATE FUNCTION pg_temp.como(
  p_login text, p_papel text, p_assercao uuid, p_adultera text, p_gucs jsonb, p_sql text[]
) RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v_saida text;
  v_chave text;
  i integer;
BEGIN
  BEGIN
    IF p_login IS NOT NULL THEN
      EXECUTE format('SET LOCAL SESSION AUTHORIZATION %I', p_login);
    END IF;
    IF p_papel IS NOT NULL THEN
      EXECUTE format('SET LOCAL ROLE %I', p_papel);
    END IF;
    IF p_assercao IS NOT NULL THEN
      PERFORM gestao_auth.begin_request(p_assercao, gen_random_uuid(), gen_random_uuid());
    END IF;
    IF p_adultera IS NOT NULL THEN
      RESET ROLE;
      RESET SESSION AUTHORIZATION;
      EXECUTE p_adultera;
      IF p_login IS NOT NULL THEN
        EXECUTE format('SET LOCAL SESSION AUTHORIZATION %I', p_login);
      END IF;
      IF p_papel IS NOT NULL THEN
        EXECUTE format('SET LOCAL ROLE %I', p_papel);
      END IF;
    END IF;
    IF p_gucs IS NOT NULL THEN
      FOR v_chave IN SELECT jsonb_object_keys(p_gucs) LOOP
        PERFORM set_config(v_chave, p_gucs ->> v_chave, true);
      END LOOP;
    END IF;
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

-- Worker pelo protocolo real: login de teste + papel do worker + begin_request(asserção).
CREATE FUNCTION pg_temp.w(p_assercao uuid, VARIADIC p_sql text[]) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.como('dnex_folha_ci_login', 'dnex_gestao_folha_worker', p_assercao, NULL, NULL, p_sql)
$$;
-- Worker pelo protocolo real, com o estado adulterado depois de begin_request.
CREATE FUNCTION pg_temp.w_adulterado(p_assercao uuid, p_adultera text, VARIADIC p_sql text[]) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.como('dnex_folha_ci_login', 'dnex_gestao_folha_worker', p_assercao, p_adultera, NULL, p_sql)
$$;
-- Worker sem begin_request, só com parâmetros de sessão (o que um atacante consegue com SET).
CREATE FUNCTION pg_temp.w_guc(p_gucs jsonb, VARIADIC p_sql text[]) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.como('dnex_folha_ci_login', 'dnex_gestao_folha_worker', NULL, NULL, p_gucs, p_sql)
$$;
-- Papel de teste com a reserva folha.account_id.
CREATE FUNCTION pg_temp.ci(p_conta text, VARIADIC p_sql text[]) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.como(NULL, 'dnex_folha_ci', NULL, NULL, jsonb_build_object('folha.account_id', COALESCE(p_conta, '')), p_sql)
$$;

\set A '''a0000000-0000-0000-0000-000000000001'''
\set B '''b0000000-0000-0000-0000-000000000002'''
-- asserções (uma por situação)
\set AS_A '''aa000000-0000-0000-0000-000000000001'''
\set AS_B '''aa000000-0000-0000-0000-000000000002'''
\set AS_EXPIRADA '''aa000000-0000-0000-0000-000000000003'''
\set AS_CONSUMIDA '''aa000000-0000-0000-0000-000000000004'''
\set AS_REVOGADA '''aa000000-0000-0000-0000-000000000005'''
\set AS_OUTRO_LOGIN '''aa000000-0000-0000-0000-000000000006'''
\set AS_GRUPO_API '''aa000000-0000-0000-0000-000000000007'''
\set AS_ESCOPO_INATIVO '''aa000000-0000-0000-0000-000000000008'''

-- Empregadores: E1 e E3 na conta A, E2 na conta B. Estabelecimentos F1 (E1), F3 (E3), F2 (E2).
INSERT INTO folha.employer (employer_id, account_id, tipo_inscricao, inscricao, razao_social) VALUES
  ('e0000000-0000-0000-0000-000000000001', :A, 'cnpj', '11111111', 'Empresa A Ltda'),
  ('e0000000-0000-0000-0000-000000000003', :A, 'cnpj', '33333333', 'Empresa A2 Ltda'),
  ('e0000000-0000-0000-0000-000000000002', :B, 'cnpj', '22222222', 'Empresa B Ltda');

INSERT INTO folha.employer_regime (account_id, employer_id, vigencia_inicio, vigencia_fim, regime_tributario) VALUES
  (:A, 'e0000000-0000-0000-0000-000000000001', '2026-01-01', '2026-12-31', 'lucro_presumido'),
  (:B, 'e0000000-0000-0000-0000-000000000002', '2026-01-01', NULL, 'lucro_real');

INSERT INTO folha.establishment (establishment_id, account_id, employer_id, tipo_inscricao, inscricao, cnae_preponderante) VALUES
  ('f0000000-0000-0000-0000-000000000001', :A, 'e0000000-0000-0000-0000-000000000001', 'cnpj', '11111111000111', '0000000'),
  ('f0000000-0000-0000-0000-000000000003', :A, 'e0000000-0000-0000-0000-000000000003', 'cnpj', '33333333000133', '0000000'),
  ('f0000000-0000-0000-0000-000000000002', :B, 'e0000000-0000-0000-0000-000000000002', 'cnpj', '22222222000222', '0000000');

INSERT INTO folha.establishment_fap (account_id, establishment_id, vigencia_inicio, vigencia_fim, fap, fap_origem) VALUES
  (:A, 'f0000000-0000-0000-0000-000000000001', '2026-01-01', NULL, 1.2345, 'cenario de teste'),
  (:B, 'f0000000-0000-0000-0000-000000000002', '2026-01-01', NULL, 0.7500, 'cenario de teste');

-- Lotações: L1 e L3 em F1 (E1); L4 em F3 (E3); L2 em F2 (conta B).
INSERT INTO folha.tax_allocation (allocation_id, account_id, employer_id, establishment_id, codigo_lotacao, tipo_lotacao) VALUES
  ('10000000-0000-0000-0000-000000000001', :A, 'e0000000-0000-0000-0000-000000000001', 'f0000000-0000-0000-0000-000000000001', 'LOT-A1', 'teste'),
  ('10000000-0000-0000-0000-000000000003', :A, 'e0000000-0000-0000-0000-000000000001', 'f0000000-0000-0000-0000-000000000001', 'LOT-A2', 'teste'),
  ('10000000-0000-0000-0000-000000000004', :A, 'e0000000-0000-0000-0000-000000000003', 'f0000000-0000-0000-0000-000000000003', 'LOT-A3', 'teste'),
  ('10000000-0000-0000-0000-000000000002', :B, 'e0000000-0000-0000-0000-000000000002', 'f0000000-0000-0000-0000-000000000002', 'LOT-B1', 'teste');

INSERT INTO folha.tax_allocation_detail (account_id, allocation_id, vigencia_inicio, vigencia_fim, fpas, codigo_terceiros) VALUES
  (:A, '10000000-0000-0000-0000-000000000001', '2026-01-01', '2026-06-30', 'T1', 'T1'),
  (:B, '10000000-0000-0000-0000-000000000002', '2026-01-01', NULL, 'T2', 'T2');

INSERT INTO folha.employee (employee_id, account_id, cpf, nome_completo, data_nascimento) VALUES
  ('c0000000-0000-0000-0000-000000000001', :A, '33333333333', 'Trabalhador A', '1990-01-01'),
  ('c0000000-0000-0000-0000-000000000002', :B, '44444444444', 'Trabalhador B', '1990-01-01');

-- Contratos: D1 (A, E1, F1) já rateado; D3 (A, E1) sem rateio; D4 (A) sem empregador; D2 (B, E2, F2).
INSERT INTO folha.employment_contract (contract_id, account_id, employee_id, data_admissao, cargo, salario_base, regime_trabalho, employer_id, establishment_id) VALUES
  ('d0000000-0000-0000-0000-000000000001', :A, 'c0000000-0000-0000-0000-000000000001', '2026-01-01', 'Analista', 5000.00, 'clt', 'e0000000-0000-0000-0000-000000000001', 'f0000000-0000-0000-0000-000000000001'),
  ('d0000000-0000-0000-0000-000000000003', :A, 'c0000000-0000-0000-0000-000000000001', '2026-01-01', 'Analista', 5000.00, 'clt', 'e0000000-0000-0000-0000-000000000001', NULL),
  ('d0000000-0000-0000-0000-000000000004', :A, 'c0000000-0000-0000-0000-000000000001', '2026-01-01', 'Analista', 5000.00, 'clt', NULL, NULL),
  ('d0000000-0000-0000-0000-000000000002', :B, 'c0000000-0000-0000-0000-000000000002', '2026-01-01', 'Analista', 5000.00, 'clt', 'e0000000-0000-0000-0000-000000000002', 'f0000000-0000-0000-0000-000000000002');

INSERT INTO folha.contract_tax_allocation (account_id, employer_id, contract_id, allocation_id, percentual, vigencia_inicio) VALUES
  (:A, 'e0000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 100, '2026-01-01'),
  (:B, 'e0000000-0000-0000-0000-000000000002', 'd0000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 100, '2026-01-01');

-- Parâmetro fictício no catálogo global da 0023 (ver seção 10).
INSERT INTO folha.payroll_parameter (chave, valor, vigencia_inicio, vigencia_fim, fonte_normativa) VALUES
  ('parametro_teste', 1, '2026-01-01', '2026-12-31', 'fonte ficticia de teste');

-- Escopos empresariais (gestao_finance) e asserções (gestao_auth), gravados como o emissor
-- gravaria. Conta C existe só com escopo inativo.
INSERT INTO gestao_finance.enterprise_scope_registry (account_id, legal_entity_id, branch_id, status) VALUES
  (:A, 'a1000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000001', 'active'),
  (:B, 'b1000000-0000-0000-0000-000000000002', 'b2000000-0000-0000-0000-000000000002', 'active'),
  ('c9000000-0000-0000-0000-000000000003', 'c1000000-0000-0000-0000-000000000003', 'c2000000-0000-0000-0000-000000000003', 'inactive');

INSERT INTO gestao_auth.access_assertion
  (assertion_id, subject_id, subject_type, principal_group, runtime_session_user,
   account_id, legal_entity_id, branch_id, permissions, issued_at, expires_at, consumed_at, revoked_at)
VALUES
  (:AS_A, gen_random_uuid(), 'system', 'folha_worker', 'dnex_folha_ci_login',
   :A, 'a1000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000001', ARRAY['folha.ci'],
   now(), now() + interval '4 minutes', NULL, NULL),
  (:AS_B, gen_random_uuid(), 'system', 'folha_worker', 'dnex_folha_ci_login',
   :B, 'b1000000-0000-0000-0000-000000000002', 'b2000000-0000-0000-0000-000000000002', ARRAY['folha.ci'],
   now(), now() + interval '4 minutes', NULL, NULL),
  (:AS_EXPIRADA, gen_random_uuid(), 'system', 'folha_worker', 'dnex_folha_ci_login',
   :A, 'a1000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000001', ARRAY['folha.ci'],
   now() - interval '10 minutes', now() - interval '6 minutes', NULL, NULL),
  (:AS_CONSUMIDA, gen_random_uuid(), 'system', 'folha_worker', 'dnex_folha_ci_login',
   :A, 'a1000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000001', ARRAY['folha.ci'],
   now(), now() + interval '4 minutes', now(), NULL),
  (:AS_REVOGADA, gen_random_uuid(), 'system', 'folha_worker', 'dnex_folha_ci_login',
   :A, 'a1000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000001', ARRAY['folha.ci'],
   now(), now() + interval '4 minutes', NULL, now()),
  (:AS_OUTRO_LOGIN, gen_random_uuid(), 'system', 'folha_worker', 'outro_login',
   :A, 'a1000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000001', ARRAY['folha.ci'],
   now(), now() + interval '4 minutes', NULL, NULL),
  (:AS_GRUPO_API, gen_random_uuid(), 'user', 'api', 'dnex_folha_ci_login',
   :A, 'a1000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000001', ARRAY['finance.read'],
   now(), now() + interval '4 minutes', NULL, NULL),
  (:AS_ESCOPO_INATIVO, gen_random_uuid(), 'system', 'folha_worker', 'dnex_folha_ci_login',
   'c9000000-0000-0000-0000-000000000003', 'c1000000-0000-0000-0000-000000000003', 'c2000000-0000-0000-0000-000000000003', ARRAY['folha.ci'],
   now(), now() + interval '4 minutes', NULL, NULL);

SET CONSTRAINTS ALL IMMEDIATE;   -- confere agora o rateio do setup (100 em cada contrato)
SET CONSTRAINTS ALL DEFERRED;

-- ---------------------------------------------------------------------------
-- 1. Estrutura (7 tabelas, colunas novas)
-- ---------------------------------------------------------------------------
SELECT has_table('folha', t, 'tabela ' || t || ' existe')
  FROM unnest(ARRAY['employer', 'employer_regime', 'establishment', 'establishment_fap',
                    'tax_allocation', 'tax_allocation_detail', 'contract_tax_allocation']) AS t;

SELECT has_column('folha', 'employee', 'employer_id', 'employee tem employer_id');
SELECT has_column('folha', 'employment_contract', 'employer_id', 'employment_contract tem employer_id');
SELECT has_column('folha', 'employment_contract', 'establishment_id', 'employment_contract tem establishment_id');
SELECT has_column('folha', 'payroll_run', 'employer_id', 'payroll_run tem employer_id');
SELECT has_column('folha', 'payroll_run', 'establishment_id', 'payroll_run tem establishment_id');

SELECT is(
  (SELECT count(*) FROM information_schema.columns
    WHERE table_schema = 'folha' AND column_name IN ('employer_id', 'establishment_id')
      AND table_name IN ('employee', 'employment_contract', 'payroll_run') AND is_nullable = 'YES'),
  5::bigint,
  'as cinco colunas de vínculo são anuláveis nesta migration'
);

-- ---------------------------------------------------------------------------
-- 2. RLS com FORCE e policy por conta em cada tabela nova
-- ---------------------------------------------------------------------------
SELECT ok(
  (SELECT relrowsecurity AND relforcerowsecurity FROM pg_class WHERE oid = ('folha.' || t)::regclass),
  t || ' tem RLS habilitada e FORCE'
)
  FROM unnest(ARRAY['employer', 'employer_regime', 'establishment', 'establishment_fap',
                    'tax_allocation', 'tax_allocation_detail', 'contract_tax_allocation']) AS t;

SELECT is(
  (SELECT count(*) FROM pg_policies
    WHERE schemaname = 'folha'
      AND tablename IN ('employer', 'employer_regime', 'establishment', 'establishment_fap',
                        'tax_allocation', 'tax_allocation_detail', 'contract_tax_allocation')
      AND cmd = 'ALL' AND permissive = 'PERMISSIVE' AND roles = '{public}'
      AND qual ~ '^\(account_id = \( SELECT folha\.current_account_id\(\) AS current_account_id\)\)$'
      AND with_check = qual),
  7::bigint,
  'cada tabela nova tem exatamente a policy por conta (USING e WITH CHECK iguais)'
);

SELECT is(
  (SELECT count(*) FROM pg_policies
    WHERE schemaname = 'folha'
      AND tablename IN ('employer', 'employer_regime', 'establishment', 'establishment_fap',
                        'tax_allocation', 'tax_allocation_detail', 'contract_tax_allocation')),
  7::bigint,
  'nenhuma policy adicional (permissiva) nas tabelas novas'
);

-- ---------------------------------------------------------------------------
-- 3. Papéis: quem exerce a RLS nos testes não a ignora
-- ---------------------------------------------------------------------------
SELECT is(
  (SELECT count(*) FROM pg_roles
    WHERE rolname IN ('dnex_folha_ci', 'dnex_folha_ci_login', 'dnex_gestao_folha_worker', 'dnex_gestao_data_owner')
      AND NOT rolbypassrls AND NOT rolsuper),
  4::bigint,
  'papel de teste, login de teste, worker e data_owner não têm BYPASSRLS nem SUPERUSER'
);
SELECT ok(
  (SELECT NOT rolcanlogin FROM pg_roles WHERE rolname = 'dnex_folha_ci'),
  'papel de teste dnex_folha_ci não tem LOGIN'
);
SELECT ok(
  NOT pg_has_role('dnex_gestao_folha_worker', 'dnex_folha_ci', 'MEMBER')
  AND NOT pg_has_role('dnex_folha_ci_login', 'dnex_folha_ci', 'MEMBER'),
  'nem o worker nem o login de teste podem assumir o papel da reserva'
);
SELECT is(
  pg_temp.w(NULL, 'SELECT session_user || ''/'' || current_user'),
  'dnex_folha_ci_login/dnex_gestao_folha_worker',
  'o apoio dos testes troca de fato o session_user e o papel efetivo'
);

-- ---------------------------------------------------------------------------
-- 4. Isolamento entre contas em cada tabela nova, com o worker e pelo protocolo real
--    Âncora: com contexto da conta A o worker enxerga as próprias linhas (quantidade exata
--    do setup); depois, nenhuma linha da conta B, que existe (o superusuário a conta).
-- ---------------------------------------------------------------------------
SELECT is(
  pg_temp.w(:AS_A, format('SELECT count(*) FROM folha.%I', x.t)),
  x.proprias::text,
  x.t || ': worker com contexto da conta A vê as próprias linhas'
)
  FROM (VALUES ('employer', 2), ('employer_regime', 1), ('establishment', 2), ('establishment_fap', 1),
               ('tax_allocation', 3), ('tax_allocation_detail', 1), ('contract_tax_allocation', 1)) AS x(t, proprias);

SELECT is(
  pg_temp.w(:AS_A, format('SELECT count(*) FROM folha.%I WHERE account_id = %L', t, :B)),
  '0',
  t || ': worker com contexto da conta A não vê linha da conta B'
)
  FROM unnest(ARRAY['employer', 'employer_regime', 'establishment', 'establishment_fap',
                    'tax_allocation', 'tax_allocation_detail', 'contract_tax_allocation']) AS t;

SELECT is(
  (SELECT count(*) FROM (
     SELECT 1 FROM folha.employer WHERE account_id = :B
     UNION ALL SELECT 1 FROM folha.employer_regime WHERE account_id = :B
     UNION ALL SELECT 1 FROM folha.establishment WHERE account_id = :B
     UNION ALL SELECT 1 FROM folha.establishment_fap WHERE account_id = :B
     UNION ALL SELECT 1 FROM folha.tax_allocation WHERE account_id = :B
     UNION ALL SELECT 1 FROM folha.tax_allocation_detail WHERE account_id = :B
     UNION ALL SELECT 1 FROM folha.contract_tax_allocation WHERE account_id = :B) s),
  7::bigint,
  'as linhas da conta B existem (o zero acima não é tabela vazia)'
);

SELECT is(
  pg_temp.w(:AS_B, 'SELECT string_agg(razao_social, '','') FROM folha.employer'),
  'Empresa B Ltda',
  'sentido inverso: worker com contexto da conta B vê só o employer da conta B'
);
SELECT is(
  pg_temp.w(NULL, 'SELECT count(*) FROM folha.employer'),
  '0',
  'worker sem contexto não vê linha alguma'
);

-- Gravação
SELECT is(
  pg_temp.w(:AS_A,
    'WITH i AS (INSERT INTO folha.employer (account_id, tipo_inscricao, inscricao, razao_social) VALUES (''a0000000-0000-0000-0000-000000000001'', ''cpf'', ''55555555555'', ''Empregador PF'') RETURNING 1) SELECT count(*) FROM i'),
  '1',
  'worker com contexto da conta A grava employer na conta A'
);
SELECT matches(
  pg_temp.w(:AS_A, format(
    'INSERT INTO folha.employer (account_id, tipo_inscricao, inscricao, razao_social) VALUES (%L, ''cnpj'', ''44444444'', ''Invasora'')', :B)),
  '^ERRO 42501: .*row-level security',
  'worker com contexto da conta A não grava employer na conta B (WITH CHECK da policy)'
);
SELECT is(
  pg_temp.w(:AS_A, format(
    'WITH u AS (UPDATE folha.employer SET razao_social = ''Alterada'' WHERE account_id = %L RETURNING 1) SELECT count(*) FROM u', :B)),
  '0',
  'worker com contexto da conta A não altera employer da conta B'
);
SELECT matches(
  pg_temp.w(:AS_A, 'UPDATE folha.employer SET account_id = ''b0000000-0000-0000-0000-000000000002'' WHERE employer_id = ''e0000000-0000-0000-0000-000000000003'''),
  '^ERRO 42501: .*row-level security',
  'worker não transfere um employer seu para outra conta'
);
SELECT matches(
  pg_temp.w(:AS_A, 'DELETE FROM folha.contract_tax_allocation'),
  '^ERRO 42501: permission denied',
  'worker não tem DELETE (mesmo critério da 0014)'
);
SELECT matches(
  pg_temp.como('dnex_folha_ci_login', NULL, NULL, 'GRANT dnex_gestao_data_owner TO dnex_folha_ci_login; REVOKE dnex_gestao_folha_worker FROM dnex_folha_ci_login', NULL,
    ARRAY['SET LOCAL ROLE dnex_gestao_data_owner', 'UPDATE folha.employer SET razao_social = ''X''']),
  '^ERRO 42501: permission denied',
  'data_owner só lê: UPDATE em employer é negado'
);

-- ---------------------------------------------------------------------------
-- 5. Coerência da hierarquia (chaves compostas), inclusive para o superusuário
-- ---------------------------------------------------------------------------
-- 5.1 Entre contas
SELECT throws_ok(
  format('INSERT INTO folha.employer_regime (account_id, employer_id, vigencia_inicio, regime_tributario)
          VALUES (%L, ''e0000000-0000-0000-0000-000000000001'', ''2030-01-01'', ''lucro_real'')', :B),
  '23503', NULL,
  'employer_regime da conta B não referencia employer da conta A'
);
SELECT throws_ok(
  format('INSERT INTO folha.establishment (account_id, employer_id, tipo_inscricao, inscricao, cnae_preponderante)
          VALUES (%L, ''e0000000-0000-0000-0000-000000000001'', ''cno'', ''999999999999'', ''0000000'')', :B),
  '23503', NULL,
  'establishment da conta B não referencia employer da conta A'
);
SELECT throws_ok(
  'UPDATE folha.employment_contract SET employer_id = ''e0000000-0000-0000-0000-000000000001'', establishment_id = NULL
    WHERE contract_id = ''d0000000-0000-0000-0000-000000000002''',
  '23503', NULL,
  'contrato da conta B não se vincula a employer da conta A'
);
SELECT throws_ok(
  format('INSERT INTO folha.contract_tax_allocation (account_id, employer_id, contract_id, allocation_id, percentual, vigencia_inicio)
          VALUES (%L, ''e0000000-0000-0000-0000-000000000001'', ''d0000000-0000-0000-0000-000000000003'', ''10000000-0000-0000-0000-000000000002'', 100, ''2026-01-01'')', :A),
  '23503', NULL,
  'rateio de contrato da conta A não usa lotação da conta B'
);
-- 5.2 Dentro da mesma conta
SELECT throws_ok(
  'UPDATE folha.employment_contract SET establishment_id = ''f0000000-0000-0000-0000-000000000003''
    WHERE contract_id = ''d0000000-0000-0000-0000-000000000003''',
  '23503', NULL,
  'contrato do empregador E1 não aceita estabelecimento do empregador E3 (mesma conta)'
);
SELECT throws_ok(
  'UPDATE folha.employment_contract SET establishment_id = ''f0000000-0000-0000-0000-000000000001''
    WHERE contract_id = ''d0000000-0000-0000-0000-000000000004''',
  '23514', NULL,
  'contrato sem empregador não aceita estabelecimento'
);
SELECT lives_ok(
  'UPDATE folha.employment_contract SET establishment_id = ''f0000000-0000-0000-0000-000000000001''
    WHERE contract_id = ''d0000000-0000-0000-0000-000000000003''',
  'contrato do empregador E1 aceita estabelecimento do próprio E1'
);
SELECT throws_ok(
  format('INSERT INTO folha.payroll_run (account_id, competencia, employer_id, establishment_id)
          VALUES (%L, ''2031-01-01'', ''e0000000-0000-0000-0000-000000000001'', ''f0000000-0000-0000-0000-000000000003'')', :A),
  '23503', NULL,
  'folha do empregador E1 não aceita estabelecimento do empregador E3'
);
SELECT throws_ok(
  format('INSERT INTO folha.payroll_run (account_id, competencia, establishment_id)
          VALUES (%L, ''2031-02-01'', ''f0000000-0000-0000-0000-000000000001'')', :A),
  '23514', NULL,
  'folha sem empregador não aceita estabelecimento'
);
SELECT lives_ok(
  format('INSERT INTO folha.payroll_run (account_id, competencia, employer_id, establishment_id)
          VALUES (%L, ''2031-03-01'', ''e0000000-0000-0000-0000-000000000001'', ''f0000000-0000-0000-0000-000000000001'')', :A),
  'folha do empregador E1 aceita estabelecimento do próprio E1'
);
SELECT throws_ok(
  format('INSERT INTO folha.tax_allocation (account_id, employer_id, establishment_id, codigo_lotacao, tipo_lotacao)
          VALUES (%L, ''e0000000-0000-0000-0000-000000000003'', ''f0000000-0000-0000-0000-000000000001'', ''LOT-X'', ''teste'')', :A),
  '23503', NULL,
  'lotação não declara empregador diferente do dono do estabelecimento'
);
SELECT throws_ok(
  format('INSERT INTO folha.contract_tax_allocation (account_id, employer_id, contract_id, allocation_id, percentual, vigencia_inicio)
          VALUES (%L, ''e0000000-0000-0000-0000-000000000001'', ''d0000000-0000-0000-0000-000000000003'', ''10000000-0000-0000-0000-000000000004'', 100, ''2026-01-01'')', :A),
  '23503', NULL,
  'rateio de contrato do E1 não usa lotação do E3 (mesma conta)'
);
SELECT throws_ok(
  format('INSERT INTO folha.contract_tax_allocation (account_id, employer_id, contract_id, allocation_id, percentual, vigencia_inicio)
          VALUES (%L, ''e0000000-0000-0000-0000-000000000003'', ''d0000000-0000-0000-0000-000000000003'', ''10000000-0000-0000-0000-000000000004'', 100, ''2026-01-01'')', :A),
  '23503', NULL,
  'rateio não declara empregador diferente do empregador do contrato'
);
SELECT throws_ok(
  'UPDATE folha.employment_contract SET employer_id = ''e0000000-0000-0000-0000-000000000003'', establishment_id = NULL
    WHERE contract_id = ''d0000000-0000-0000-0000-000000000001''',
  '23503', NULL,
  'contrato com rateio não troca de empregador deixando o rateio para trás'
);

-- ---------------------------------------------------------------------------
-- 6. Conta da sessão pelo protocolo do gestao_auth (begin_request + request_context)
-- ---------------------------------------------------------------------------
SELECT is(
  pg_temp.w(:AS_A, 'SELECT folha.current_account_id()'),
  'a0000000-0000-0000-0000-000000000001',
  'worker que abriu contexto com asserção da conta A: a conta é A'
);
SELECT is(
  pg_temp.como('dnex_folha_ci_login', 'dnex_gestao_folha_worker', :AS_A,
    'CREATE TEMP TABLE obs AS SELECT (SELECT consumed_at IS NOT NULL FROM gestao_auth.access_assertion WHERE assertion_id = ''aa000000-0000-0000-0000-000000000001'') AS consumida, (SELECT count(*) FROM gestao_auth.request_context WHERE context_nonce::text = current_setting(''dnex.context_nonce'') AND assertion_id = ''aa000000-0000-0000-0000-000000000001'') AS contextos, current_setting(''dnex.context_nonce'') <> ''aa000000-0000-0000-0000-000000000001'' AS nonce_difere; GRANT SELECT ON obs TO PUBLIC',
    NULL, ARRAY['SELECT consumida::text || ''/'' || contextos::text || ''/'' || nonce_difere::text FROM obs']),
  'true/1/true',
  'o protocolo exercido é o real: asserção consumida, nonce é a chave de request_context e não o assertion_id'
);
SELECT is(
  pg_temp.como('dnex_folha_ci_login', 'dnex_gestao_folha_worker', :AS_A, NULL,
    jsonb_build_object('folha.account_id', 'b0000000-0000-0000-0000-000000000002'),
    ARRAY['SELECT folha.current_account_id()::text || ''/'' || (SELECT count(*) FROM folha.employer WHERE account_id = ''b0000000-0000-0000-0000-000000000002'')']),
  'a0000000-0000-0000-0000-000000000001/0',
  'worker com contexto de A e folha.account_id = B continua na conta A e não vê B'
);

-- 6.1 Parâmetro de sessão forjado, sem begin_request
SELECT is(
  pg_temp.w_guc(jsonb_build_object('dnex.context_nonce', x.valor),
    'SELECT (folha.current_account_id() IS NULL)::text || ''/'' || (SELECT count(*) FROM folha.employer)'),
  'true/0',
  'GUC forjado (' || x.caso || ') não dá conta nem linha'
)
  FROM (VALUES
    ('assertion_id válido e não consumido: o token reutilizável da 0014', 'aa000000-0000-0000-0000-000000000001'),
    ('assertion_id já consumido', 'aa000000-0000-0000-0000-000000000004'),
    ('uuid qualquer', 'ffffffff-ffff-ffff-ffff-ffffffffffff'),
    ('texto que não é uuid', 'nao-e-uuid'),
    ('vazio', '')) AS x(caso, valor);
SELECT is(
  pg_temp.w_guc(jsonb_build_object('folha.account_id', 'a0000000-0000-0000-0000-000000000001'),
    'SELECT (folha.current_account_id() IS NULL)::text || ''/'' || (SELECT count(*) FROM folha.employer)'),
  'true/0',
  'worker que define folha.account_id não ganha conta nem linha'
);
SELECT is(
  pg_temp.w_guc(jsonb_build_object('folha.account_id', 'nao-e-uuid'), 'SELECT folha.current_account_id() IS NULL'),
  'true',
  'para o worker o parâmetro folha.account_id nem chega a ser interpretado'
);
SELECT matches(
  pg_temp.w_guc(jsonb_build_object('folha.account_id', 'a0000000-0000-0000-0000-000000000001'),
    'INSERT INTO folha.employer (account_id, tipo_inscricao, inscricao, razao_social) VALUES (''a0000000-0000-0000-0000-000000000001'', ''cnpj'', ''44444444'', ''Sem contexto'')'),
  '^ERRO 42501: .*row-level security',
  'worker que define folha.account_id = A não grava na conta A'
);

-- 6.2 begin_request recusa asserção que não serve (comportamento do protocolo reproduzido)
SELECT matches(
  pg_temp.w(x.assercao::uuid, 'SELECT folha.current_account_id()'),
  '^ERRO 42501: ',
  'begin_request recusa asserção ' || x.caso
)
  FROM (VALUES
    ('expirada', 'aa000000-0000-0000-0000-000000000003'),
    ('já consumida', 'aa000000-0000-0000-0000-000000000004'),
    ('revogada', 'aa000000-0000-0000-0000-000000000005'),
    ('emitida para outro login', 'aa000000-0000-0000-0000-000000000006'),
    ('de grupo que não é o do login', 'aa000000-0000-0000-0000-000000000007'),
    ('de escopo empresarial inativo', 'aa000000-0000-0000-0000-000000000008'),
    ('inexistente', 'aa000000-0000-0000-0000-0000000000ff')) AS x(caso, assercao);

-- 6.3 Cada vínculo do contexto é revalidado na leitura: o contexto é aberto de verdade e,
--     em seguida, UM campo é adulterado como superusuário. A âncora é o primeiro teste
--     da seção 6 (sem adulteração, a conta é A).
SELECT is(
  pg_temp.w_adulterado(:AS_A, x.adultera,
    'SELECT (folha.current_account_id() IS NULL)::text || ''/'' || (SELECT count(*) FROM folha.employer)'),
  'true/0',
  'contexto com ' || x.caso || ' não dá conta nem linha'
)
  FROM (VALUES
    ('PID de outro backend',
       'UPDATE gestao_auth.request_context SET backend_pid = backend_pid + 1'),
    ('txid de outra transação',
       'UPDATE gestao_auth.request_context SET transaction_id = transaction_id + 1'),
    ('session_user de outro login',
       'UPDATE gestao_auth.request_context SET runtime_session_user = ''outro_login'''),
    ('contexto e asserção vencidos (abertos há 10 minutos)',
       'UPDATE gestao_auth.access_assertion SET issued_at = issued_at - interval ''10 minutes'', consumed_at = consumed_at - interval ''10 minutes'', expires_at = issued_at - interval ''6 minutes'' WHERE assertion_id = ''aa000000-0000-0000-0000-000000000001''; UPDATE gestao_auth.request_context SET created_at = created_at - interval ''10 minutes'', expires_at = created_at - interval ''6 minutes'''),
    ('conta trocada só no contexto',
       'UPDATE gestao_auth.request_context SET account_id = ''b0000000-0000-0000-0000-000000000002'''),
    ('conta trocada só na asserção',
       'UPDATE gestao_auth.access_assertion SET account_id = ''b0000000-0000-0000-0000-000000000002'' WHERE assertion_id = ''aa000000-0000-0000-0000-000000000001'''),
    ('asserção revogada depois de aberta',
       'UPDATE gestao_auth.access_assertion SET revoked_at = clock_timestamp() WHERE assertion_id = ''aa000000-0000-0000-0000-000000000001'''),
    ('asserção marcada como não consumida',
       'UPDATE gestao_auth.access_assertion SET consumed_at = NULL WHERE assertion_id = ''aa000000-0000-0000-0000-000000000001'''),
    ('escopo empresarial desativado',
       'UPDATE gestao_finance.enterprise_scope_registry SET status = ''inactive'' WHERE account_id = ''a0000000-0000-0000-0000-000000000001'''),
    ('login que ganhou um segundo papel',
       'GRANT dnex_gestao_data_owner TO dnex_folha_ci_login'),
    ('grupo trocado para um que não é o do login',
       'UPDATE gestao_auth.access_assertion SET principal_group = ''api'' WHERE assertion_id = ''aa000000-0000-0000-0000-000000000001''; UPDATE gestao_auth.request_context SET principal_group = ''api''')
  ) AS x(caso, adultera);

-- 6.4 O contexto não serve a outra sessão: aberto pelo login de teste, lido pelo superusuário
SELECT is(
  pg_temp.como('dnex_folha_ci_login', 'dnex_gestao_folha_worker', :AS_A, NULL, NULL,
    ARRAY['RESET ROLE', 'RESET SESSION AUTHORIZATION',
          'SELECT (folha.request_context_account_id() IS NULL)::text || ''/'' || (session_user <> ''dnex_folha_ci_login'')::text || ''/'' || (current_setting(''dnex.context_nonce'') <> '''')::text']),
  'true/true/true',
  'o mesmo nonce, na mesma transação, lido por outro session_user não dá conta'
);

-- ---------------------------------------------------------------------------
-- 7. Reserva de CI: só o papel de teste, só em banco com o marcador
-- ---------------------------------------------------------------------------
SELECT is(
  pg_temp.ci('a0000000-0000-0000-0000-000000000001', 'SELECT folha.current_account_id()'),
  'a0000000-0000-0000-0000-000000000001',
  'papel de teste em banco de CI: folha.account_id define a conta'
);
SELECT is(
  pg_temp.ci('a0000000-0000-0000-0000-000000000001', 'SELECT count(*) FROM folha.employer'),
  '2',
  'papel de teste com a reserva vê só as linhas da conta'
);
SELECT is(
  pg_temp.ci(NULL, 'SELECT count(*) FROM folha.employer'),
  '0',
  'sem conta na sessão, nem o papel de teste vê linha alguma'
);
SELECT is(
  pg_temp.como(NULL, 'dnex_folha_ci', NULL, x.adultera,
    jsonb_build_object('folha.account_id', 'a0000000-0000-0000-0000-000000000001'),
    ARRAY['SELECT (folha.current_account_id() IS NULL)::text || ''/'' || (SELECT count(*) FROM folha.employer)']),
  'true/0',
  'papel de teste ' || x.caso || ': a reserva não vale'
)
  FROM (VALUES
    ('sem o schema-marcador', 'ALTER SCHEMA dnex_folha_ci_marcador RENAME TO outro_nome'),
    ('com marcador de dono não superusuário', 'ALTER SCHEMA dnex_folha_ci_marcador OWNER TO dnex_gestao_data_owner')
  ) AS x(caso, adultera);
SELECT is(
  (SELECT r.rolsuper FROM pg_namespace n JOIN pg_roles r ON r.oid = n.nspowner WHERE n.nspname = 'dnex_folha_ci_marcador'),
  true,
  'este banco é de CI: o marcador existe e é de superusuário (criado pelo bootstrap, não pela migration)'
);
-- Dentro de função SECURITY DEFINER o papel efetivo é o dono, não o papel de teste:
-- a reserva não vale lá, nem para o papel de teste.
CREATE FUNCTION public.folha_teste_conta_em_definer() RETURNS uuid
LANGUAGE sql SECURITY DEFINER AS $$ SELECT folha.current_account_id() $$;
GRANT EXECUTE ON FUNCTION public.folha_teste_conta_em_definer() TO dnex_folha_ci, dnex_gestao_folha_worker;
SELECT is(
  pg_temp.ci('a0000000-0000-0000-0000-000000000001', 'SELECT public.folha_teste_conta_em_definer() IS NULL'),
  'true',
  'a reserva não atravessa função SECURITY DEFINER'
);
SELECT is(
  pg_temp.w(:AS_A, 'SELECT public.folha_teste_conta_em_definer()'),
  'a0000000-0000-0000-0000-000000000001',
  'o contexto do protocolo atravessa função SECURITY DEFINER (é assim que o motor da 0023 lê a conta)'
);

-- ---------------------------------------------------------------------------
-- 8. Vigências sem sobreposição (datas inclusivas; fim nulo = em aberto)
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  format('INSERT INTO folha.employer_regime (account_id, employer_id, vigencia_inicio, vigencia_fim, regime_tributario)
          VALUES (%L, ''e0000000-0000-0000-0000-000000000001'', ''2026-06-01'', ''2027-06-30'', ''lucro_real'')', :A),
  '23P01', NULL,
  'employer_regime rejeita vigência que cruza outra'
);
SELECT throws_ok(
  format('INSERT INTO folha.employer_regime (account_id, employer_id, vigencia_inicio, regime_tributario)
          VALUES (%L, ''e0000000-0000-0000-0000-000000000001'', ''2026-12-31'', ''lucro_real'')', :A),
  '23P01', NULL,
  'employer_regime rejeita início no último dia da vigência anterior (fim inclusivo)'
);
SELECT lives_ok(
  format('INSERT INTO folha.employer_regime (account_id, employer_id, vigencia_inicio, regime_tributario, simples_optante, simples_anexo, simples_cpp)
          VALUES (%L, ''e0000000-0000-0000-0000-000000000001'', ''2027-01-01'', ''simples_nacional'', true, ''III'', ''no_das'')', :A),
  'employer_regime aceita vigência que começa no dia seguinte ao fim da anterior'
);
SELECT throws_ok(
  format('INSERT INTO folha.employer_regime (account_id, employer_id, vigencia_inicio, regime_tributario)
          VALUES (%L, ''e0000000-0000-0000-0000-000000000001'', ''2031-01-01'', ''lucro_real'')', :A),
  '23P01', NULL,
  'employer_regime rejeita vigência futura quando há uma em aberto'
);
SELECT throws_ok(
  format('INSERT INTO folha.employer_regime (account_id, employer_id, vigencia_inicio, vigencia_fim, regime_tributario)
          VALUES (%L, ''e0000000-0000-0000-0000-000000000001'', ''2025-12-31'', ''2025-01-01'', ''lucro_real'')', :A),
  '23514', NULL,
  'employer_regime rejeita fim anterior ao início'
);
SELECT throws_ok(
  format('INSERT INTO folha.employer_regime (account_id, employer_id, vigencia_inicio, vigencia_fim, regime_tributario, simples_anexo)
          VALUES (%L, ''e0000000-0000-0000-0000-000000000001'', ''2025-01-01'', ''2025-12-31'', ''lucro_real'', ''III'')', :A),
  '23514', NULL,
  'employer_regime rejeita anexo do Simples sem opção pelo Simples'
);
SELECT throws_ok(
  format('INSERT INTO folha.establishment_fap (account_id, establishment_id, vigencia_inicio, vigencia_fim, fap, fap_origem)
          VALUES (%L, ''f0000000-0000-0000-0000-000000000001'', ''2027-01-01'', ''2027-12-31'', 1.0000, ''teste'')', :A),
  '23P01', NULL,
  'establishment_fap rejeita vigência sobreposta à que está em aberto'
);
SELECT lives_ok(
  format('INSERT INTO folha.establishment_fap (account_id, establishment_id, vigencia_inicio, vigencia_fim, fap, fap_origem)
          VALUES (%L, ''f0000000-0000-0000-0000-000000000001'', ''2025-01-01'', ''2025-12-31'', 0.5000, ''teste'')', :A),
  'establishment_fap aceita vigência anterior, encostada na seguinte'
);
SELECT throws_ok(
  format('INSERT INTO folha.establishment_fap (account_id, establishment_id, vigencia_inicio, vigencia_fim, fap, fap_origem)
          VALUES (%L, ''f0000000-0000-0000-0000-000000000001'', ''2024-01-01'', ''2024-12-31'', 2.0001, ''teste'')', :A),
  '23514', NULL,
  'establishment_fap rejeita FAP fora do intervalo'
);
SELECT throws_ok(
  format('INSERT INTO folha.tax_allocation_detail (account_id, allocation_id, vigencia_inicio, fpas)
          VALUES (%L, ''10000000-0000-0000-0000-000000000001'', ''2026-06-30'', ''T9'')', :A),
  '23P01', NULL,
  'tax_allocation_detail rejeita vigência sobreposta na mesma lotação'
);
SELECT lives_ok(
  format('INSERT INTO folha.tax_allocation_detail (account_id, allocation_id, vigencia_inicio, fpas)
          VALUES (%L, ''10000000-0000-0000-0000-000000000001'', ''2026-07-01'', ''T9'')', :A),
  'tax_allocation_detail aceita a vigência seguinte'
);
SELECT lives_ok(
  format('INSERT INTO folha.tax_allocation_detail (account_id, allocation_id, vigencia_inicio, fpas)
          VALUES (%L, ''10000000-0000-0000-0000-000000000003'', ''2026-01-01'', ''T9'')', :A),
  'tax_allocation_detail: a mesma vigência em outra lotação não conflita'
);
SELECT throws_ok(
  format('INSERT INTO folha.tax_allocation (account_id, employer_id, establishment_id, codigo_lotacao, tipo_lotacao)
          VALUES (%L, ''e0000000-0000-0000-0000-000000000001'', ''f0000000-0000-0000-0000-000000000001'', ''LOT-A1'', ''teste'')', :A),
  '23505', NULL,
  'tax_allocation rejeita código de lotação repetido no estabelecimento'
);

-- ---------------------------------------------------------------------------
-- 9. Rateio do contrato por lotação: soma 100 em cada dia coberto
--    O trigger é adiado; SET CONSTRAINTS ALL IMMEDIATE faz a conferência do COMMIT.
--    D1 já tem 100 em L1 (setup). D3 começa sem rateio.
-- ---------------------------------------------------------------------------
-- 9.1 Com o worker, pelo protocolo real
SELECT matches(
  pg_temp.w(:AS_A,
    'INSERT INTO folha.contract_tax_allocation (account_id, employer_id, contract_id, allocation_id, percentual, vigencia_inicio) VALUES (''a0000000-0000-0000-0000-000000000001'', ''e0000000-0000-0000-0000-000000000001'', ''d0000000-0000-0000-0000-000000000003'', ''10000000-0000-0000-0000-000000000001'', 60, ''2026-01-01'')',
    'SET CONSTRAINTS ALL IMMEDIATE',
    'SELECT ''aceito'''),
  '^ERRO 23514: Rateio do contrato d0000000-0000-0000-0000-000000000003 deve somar 100 em 2026-01-01: soma atual 60',
  'worker: rateio de 60 sozinho é rejeitado no fechamento da transação'
);
SELECT is(
  pg_temp.w(:AS_A,
    'INSERT INTO folha.contract_tax_allocation (account_id, employer_id, contract_id, allocation_id, percentual, vigencia_inicio) VALUES (''a0000000-0000-0000-0000-000000000001'', ''e0000000-0000-0000-0000-000000000001'', ''d0000000-0000-0000-0000-000000000003'', ''10000000-0000-0000-0000-000000000001'', 60, ''2026-01-01'')',
    'INSERT INTO folha.contract_tax_allocation (account_id, employer_id, contract_id, allocation_id, percentual, vigencia_inicio) VALUES (''a0000000-0000-0000-0000-000000000001'', ''e0000000-0000-0000-0000-000000000001'', ''d0000000-0000-0000-0000-000000000003'', ''10000000-0000-0000-0000-000000000003'', 40, ''2026-01-01'')',
    'SET CONSTRAINTS ALL IMMEDIATE',
    'SELECT ''aceito'''),
  'aceito',
  'worker: rateio de 60 + 40 em duas lotações, gravado linha a linha, é aceito'
);
-- 9.2 A conferência não depende do contexto: o worker grava e, antes do COMMIT, o contexto
--     some ou é trocado. Com o trigger sob RLS a soma vinha nula e o rateio passava.
SELECT matches(
  pg_temp.w(:AS_A,
    'INSERT INTO folha.contract_tax_allocation (account_id, employer_id, contract_id, allocation_id, percentual, vigencia_inicio) VALUES (''a0000000-0000-0000-0000-000000000001'', ''e0000000-0000-0000-0000-000000000001'', ''d0000000-0000-0000-0000-000000000003'', ''10000000-0000-0000-0000-000000000001'', 60, ''2026-01-01'')',
    x.antes_do_commit,
    'SET CONSTRAINTS ALL IMMEDIATE',
    'SELECT ''aceito'''),
  '^ERRO 23514: Rateio do contrato .* soma atual 60',
  'worker: rateio de 60 com ' || x.caso || ' antes do COMMIT continua rejeitado'
)
  FROM (VALUES
    ('contexto apagado', 'SELECT set_config(''dnex.context_nonce'', '''', true)'),
    ('nonce trocado por outro valor', 'SELECT set_config(''dnex.context_nonce'', ''ffffffff-ffff-ffff-ffff-ffffffffffff'', true)')
  ) AS x(caso, antes_do_commit);
SELECT is(
  pg_temp.w(:AS_A,
    'INSERT INTO folha.contract_tax_allocation (account_id, employer_id, contract_id, allocation_id, percentual, vigencia_inicio) VALUES (''a0000000-0000-0000-0000-000000000001'', ''e0000000-0000-0000-0000-000000000001'', ''d0000000-0000-0000-0000-000000000003'', ''10000000-0000-0000-0000-000000000001'', 60, ''2026-01-01'')',
    'SELECT set_config(''dnex.context_nonce'', '''', true)',
    'SELECT count(*) FROM folha.contract_tax_allocation'),
  '0',
  'âncora: depois de apagar o contexto, o worker de fato não enxerga a linha que gravou'
);
-- 9.3 Segunda gravação sobre contrato que já soma 100 (D1), em OUTRA lotação: 200.
SELECT matches(
  pg_temp.w(:AS_A,
    'INSERT INTO folha.contract_tax_allocation (account_id, employer_id, contract_id, allocation_id, percentual, vigencia_inicio) VALUES (''a0000000-0000-0000-0000-000000000001'', ''e0000000-0000-0000-0000-000000000001'', ''d0000000-0000-0000-0000-000000000001'', ''10000000-0000-0000-0000-000000000003'', 100, ''2026-01-01'')',
    x.antes_do_commit,
    'SET CONSTRAINTS ALL IMMEDIATE',
    'SELECT ''aceito'''),
  '^ERRO 23514: Rateio do contrato .* soma atual 200',
  'worker: segundo rateio de 100 em outra lotação do mesmo contrato é rejeitado (' || x.caso || ')'
)
  FROM (VALUES
    ('com contexto', 'SELECT 1'),
    ('contexto apagado antes do COMMIT', 'SELECT set_config(''dnex.context_nonce'', '''', true)')
  ) AS x(caso, antes_do_commit);
SELECT is(
  (SELECT prosecdef::text || '/' || array_to_string(proconfig, ',') FROM pg_proc WHERE oid = 'folha.validar_rateio_contrato()'::regprocedure),
  'true/search_path=pg_catalog,row_security=off',
  'a conferência do rateio é SECURITY DEFINER, com search_path fixo e sem RLS'
);
-- A corrida real entre duas conexões (a conferência serializa por contrato) está em
-- tests/ci/concorrencia_rateio.sh.

-- 9.4 Regra de datas (como superusuário: a regra é a mesma para qualquer papel)
SELECT throws_ok(
  format('INSERT INTO folha.contract_tax_allocation (account_id, employer_id, contract_id, allocation_id, percentual, vigencia_inicio) VALUES
            (%1$L, ''e0000000-0000-0000-0000-000000000001'', ''d0000000-0000-0000-0000-000000000003'', ''10000000-0000-0000-0000-000000000001'', 60, ''2026-01-01''),
            (%1$L, ''e0000000-0000-0000-0000-000000000001'', ''d0000000-0000-0000-0000-000000000003'', ''10000000-0000-0000-0000-000000000003'', 50, ''2026-01-01'');
          SET CONSTRAINTS ALL IMMEDIATE', :A),
  '23514', NULL,
  'rateio de 60 + 50 é rejeitado'
);
SELECT lives_ok(
  format('INSERT INTO folha.contract_tax_allocation (account_id, employer_id, contract_id, allocation_id, percentual, vigencia_inicio, vigencia_fim)
          VALUES (%1$L, ''e0000000-0000-0000-0000-000000000001'', ''d0000000-0000-0000-0000-000000000003'', ''10000000-0000-0000-0000-000000000001'', 60, ''2026-01-01'', ''2026-06-30'');
          INSERT INTO folha.contract_tax_allocation (account_id, employer_id, contract_id, allocation_id, percentual, vigencia_inicio, vigencia_fim)
          VALUES (%1$L, ''e0000000-0000-0000-0000-000000000001'', ''d0000000-0000-0000-0000-000000000003'', ''10000000-0000-0000-0000-000000000003'', 40, ''2026-01-01'', ''2026-06-30'');
          SET CONSTRAINTS ALL IMMEDIATE;
          SET CONSTRAINTS ALL DEFERRED', :A),
  'rateio de 60 + 40 com fim de vigência é aceito'
);
SELECT is(
  (SELECT sum(percentual) FROM folha.contract_tax_allocation WHERE contract_id = 'd0000000-0000-0000-0000-000000000003'),
  100.00,
  'o rateio aceito ficou gravado e soma 100'
);
SELECT throws_ok(
  format('INSERT INTO folha.contract_tax_allocation (account_id, employer_id, contract_id, allocation_id, percentual, vigencia_inicio)
          VALUES (%L, ''e0000000-0000-0000-0000-000000000001'', ''d0000000-0000-0000-0000-000000000003'', ''10000000-0000-0000-0000-000000000001'', 70, ''2026-07-01'');
          SET CONSTRAINTS ALL IMMEDIATE', :A),
  '23514', NULL,
  'vigência seguinte com 70 é rejeitada (o período anterior, correto, não a salva)'
);
SELECT lives_ok(
  format('INSERT INTO folha.contract_tax_allocation (account_id, employer_id, contract_id, allocation_id, percentual, vigencia_inicio)
          VALUES (%L, ''e0000000-0000-0000-0000-000000000001'', ''d0000000-0000-0000-0000-000000000003'', ''10000000-0000-0000-0000-000000000003'', 100, ''2026-07-01'');
          SET CONSTRAINTS ALL IMMEDIATE;
          SET CONSTRAINTS ALL DEFERRED', :A),
  'vigência seguinte com 100 em uma lotação é aceita'
);
SELECT throws_ok(
  'UPDATE folha.contract_tax_allocation SET vigencia_fim = ''2026-05-31''
    WHERE contract_id = ''d0000000-0000-0000-0000-000000000003'' AND percentual = 40;
   SET CONSTRAINTS ALL IMMEDIATE',
  '23514', NULL,
  'encurtar uma das linhas deixa dias com 60 e é rejeitado'
);
SELECT throws_ok(
  'DELETE FROM folha.contract_tax_allocation
    WHERE contract_id = ''d0000000-0000-0000-0000-000000000003'' AND percentual = 40;
   SET CONSTRAINTS ALL IMMEDIATE',
  '23514', NULL,
  'apagar uma linha do rateio (sobram 60) é rejeitado'
);
SELECT throws_ok(
  format('INSERT INTO folha.contract_tax_allocation (account_id, employer_id, contract_id, allocation_id, percentual, vigencia_inicio, vigencia_fim)
          VALUES (%L, ''e0000000-0000-0000-0000-000000000001'', ''d0000000-0000-0000-0000-000000000003'', ''10000000-0000-0000-0000-000000000001'', 10, ''2026-03-01'', ''2026-03-31'')', :A),
  '23P01', NULL,
  'a mesma lotação não entra duas vezes no mesmo período do contrato'
);
SELECT throws_ok(
  format('INSERT INTO folha.contract_tax_allocation (account_id, employer_id, contract_id, allocation_id, percentual, vigencia_inicio)
          VALUES (%L, ''e0000000-0000-0000-0000-000000000001'', ''d0000000-0000-0000-0000-000000000003'', ''10000000-0000-0000-0000-000000000001'', 0, ''2030-01-01'')', :A),
  '23514', NULL,
  'percentual zero é rejeitado'
);
SELECT is(
  (SELECT tgdeferrable AND tginitdeferred FROM pg_trigger
    WHERE tgrelid = 'folha.contract_tax_allocation'::regclass AND tgname = 'trg_validar_rateio_contrato'),
  true,
  'o trigger do rateio é de constraint, adiado para o fim da transação'
);

-- ---------------------------------------------------------------------------
-- 10. Parâmetros por vigência: catálogo global e leitura da 0023, sem duplicata
--     A 0024 só acrescenta a constraint de vigências sem sobreposição.
--     'parametro_teste' é chave fictícia (1 em 2026, do setup).
-- ---------------------------------------------------------------------------
SELECT hasnt_function('folha', 'get_parameter', 'não existe segunda função de leitura (só folha.get_param, da 0023)');
SELECT hasnt_column('folha', 'payroll_parameter', 'account_id', 'payroll_parameter continua global (a 0024 não a recria por conta)');
SELECT is(
  (SELECT string_agg(policyname, ',' ORDER BY policyname) FROM pg_policies
    WHERE schemaname = 'folha' AND tablename = 'payroll_parameter'),
  'payroll_param_read,payroll_param_update,payroll_param_write',
  'as policies de payroll_parameter são as três da 0023'
);
SELECT throws_ok(
  $$INSERT INTO folha.payroll_parameter (chave, valor, vigencia_inicio, fonte_normativa)
    VALUES ('parametro_teste', 9, '2026-12-31', 'fonte ficticia de teste')$$,
  '23P01', NULL,
  'payroll_parameter rejeita vigência sobreposta para a mesma chave (fim inclusivo)'
);
SELECT lives_ok(
  $$INSERT INTO folha.payroll_parameter (chave, valor, vigencia_inicio, fonte_normativa)
    VALUES ('parametro_teste', 2, '2027-01-01', 'fonte ficticia de teste')$$,
  'payroll_parameter aceita a vigência seguinte da mesma chave'
);
SELECT throws_ok(
  $$INSERT INTO folha.payroll_parameter (chave, valor, vigencia_inicio, vigencia_fim, fonte_normativa)
    VALUES ('parametro_teste', 9, '2025-12-31', '2025-01-01', 'fonte ficticia de teste')$$,
  '23514', NULL,
  'payroll_parameter rejeita fim anterior ao início'
);
SELECT is(folha.get_param('parametro_teste', '2026-12-31'), 1::numeric,
  'get_param: o último dia da vigência ainda pertence a ela');
SELECT is(folha.get_param('parametro_teste', '2027-01-01'), 2::numeric,
  'get_param: no dia seguinte vale a vigência seguinte');
SELECT throws_ok(
  $$SELECT folha.get_param('parametro_teste', '2025-12-31')$$,
  'P0001', 'Parâmetro parametro_teste não encontrado para a data 2025-12-31',
  'get_param levanta exceção antes do início da vigência (sem valor de reserva)'
);
SELECT is(
  pg_temp.w(NULL, 'SELECT folha.get_param(''parametro_teste'', ''2026-06-01'')'),
  '1',
  'worker lê o catálogo global por get_param (não depende da conta da sessão)'
);

-- ---------------------------------------------------------------------------
-- 11. ACL: nada além do pretendido, para QUALQUER papel (inclusive PUBLIC e default ACL)
-- ---------------------------------------------------------------------------
SELECT is_empty(
  $$SELECT c.relname, CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END, a.privilege_type
      FROM pg_class c
      CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) a
     WHERE c.relnamespace = 'folha'::regnamespace
       AND c.relname IN ('employer', 'employer_regime', 'establishment', 'establishment_fap',
                         'tax_allocation', 'tax_allocation_detail', 'contract_tax_allocation')
       AND a.grantee <> c.relowner
       AND NOT (a.grantee = 'dnex_gestao_folha_worker'::regrole AND a.privilege_type IN ('SELECT', 'INSERT', 'UPDATE') AND NOT a.is_grantable)
       AND NOT (a.grantee = 'dnex_gestao_data_owner'::regrole AND a.privilege_type = 'SELECT' AND NOT a.is_grantable)$$,
  'tabelas novas: nenhum privilégio de nenhum papel além de worker (SELECT/INSERT/UPDATE) e data_owner (SELECT)'
);
SELECT is_empty(
  $$SELECT c.relname, att.attname
      FROM pg_class c JOIN pg_attribute att ON att.attrelid = c.oid
     WHERE c.relnamespace = 'folha'::regnamespace
       AND c.relname IN ('employer', 'employer_regime', 'establishment', 'establishment_fap',
                         'tax_allocation', 'tax_allocation_detail', 'contract_tax_allocation')
       AND att.attacl IS NOT NULL$$,
  'tabelas novas: nenhum privilégio por coluna'
);
SELECT is_empty(
  $$SELECT r.rolname, c.relname, p.priv
      FROM pg_class c
      CROSS JOIN (VALUES ('anon'), ('authenticated'), ('service_role')) AS r(rolname)
      CROSS JOIN unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER']) AS p(priv)
     WHERE c.relnamespace = 'folha'::regnamespace
       AND c.relname IN ('employer', 'employer_regime', 'establishment', 'establishment_fap',
                         'tax_allocation', 'tax_allocation_detail', 'contract_tax_allocation')
       AND has_table_privilege(r.rolname, c.oid, p.priv)$$,
  'anon, authenticated e service_role não têm privilégio efetivo nas tabelas novas (nem herdado)'
);

SELECT table_privs_are('folha', t, 'dnex_gestao_folha_worker', ARRAY['SELECT', 'INSERT', 'UPDATE'],
                       t || ': worker lê e grava, sem DELETE')
  FROM unnest(ARRAY['employer', 'employer_regime', 'establishment', 'establishment_fap',
                    'tax_allocation', 'tax_allocation_detail', 'contract_tax_allocation']) AS t;

SELECT table_privs_are('folha', t, 'dnex_gestao_data_owner', ARRAY['SELECT'],
                       t || ': data_owner só lê')
  FROM unnest(ARRAY['employer', 'employer_regime', 'establishment', 'establishment_fap',
                    'tax_allocation', 'tax_allocation_detail', 'contract_tax_allocation']) AS t;

SELECT is_empty(
  $$SELECT p.oid::regprocedure::text, CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END
      FROM pg_proc p
      CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
     WHERE p.oid IN ('folha.current_account_id()'::regprocedure, 'folha.request_context_account_id()'::regprocedure)
       AND a.grantee <> p.proowner
       AND (a.grantee = 0 OR a.grantee::regrole::text NOT IN ('dnex_gestao_folha_worker', 'dnex_gestao_data_owner'))$$,
  'current_account_id e request_context_account_id: EXECUTE só para worker e data_owner (nem PUBLIC, nem service_role)'
);
SELECT is(
  (SELECT count(*) FROM (VALUES ('dnex_gestao_folha_worker'), ('dnex_gestao_data_owner')) AS r(rolname)
    CROSS JOIN (VALUES ('folha.current_account_id()'), ('folha.request_context_account_id()')) AS f(sig)
    WHERE has_function_privilege(r.rolname, f.sig::regprocedure, 'EXECUTE')),
  4::bigint,
  'worker e data_owner executam current_account_id e request_context_account_id'
);
SELECT is_empty(
  $$SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END
      FROM pg_proc p
      CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
     WHERE p.oid = 'folha.validar_rateio_contrato()'::regprocedure AND a.grantee <> p.proowner$$,
  'a função do trigger do rateio não é executável por ninguém além do dono'
);
SELECT is(
  (SELECT string_agg(p.proname || '=' || p.prosecdef::text, ',' ORDER BY p.proname)
     FROM pg_proc p
    WHERE p.oid IN ('folha.current_account_id()'::regprocedure, 'folha.request_context_account_id()'::regprocedure)),
  'current_account_id=false,request_context_account_id=true',
  'a leitura do contexto é SECURITY DEFINER; a condição do papel de teste roda como quem chama'
);
SELECT is_empty(
  $$SELECT p.oid::regprocedure::text FROM pg_proc p
     WHERE p.oid IN ('folha.current_account_id()'::regprocedure, 'folha.request_context_account_id()'::regprocedure,
                     'folha.validar_rateio_contrato()'::regprocedure)
       AND NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) AS c WHERE c LIKE 'search_path=%')$$,
  'as funções desta migration têm search_path fixo'
);
SELECT hasnt_function('folha', 'assertion_account_id', 'a leitura pela asserção não consumida (0014) não existe mais sob outro nome');

SELECT * FROM finish();
ROLLBACK;
