-- DNEX Folha — Testes pgTAP da migration 0024: empregador em quatro níveis e parâmetros.
-- Cobre: estrutura, RLS com FORCE, isolamento entre contas em cada tabela nova, a conta da
-- sessão (reserva só para o papel de teste; asserção de gestao_auth como caminho real),
-- vigências sem sobreposição, rateio somando 100, get_parameter e ACL.
--
-- Como os testes exercem a RLS: o arquivo roda como superusuário (que ignora RLS mesmo com
-- FORCE). Cada leitura ou gravação "como um papel" passa por pg_temp.como(), que troca o
-- papel com SET LOCAL ROLE, executa o comando e devolve o resultado como texto (ou
-- 'ERRO <sqlstate>: <mensagem>'), voltando ao papel original antes da asserção.
-- Papéis usados: dnex_folha_ci (teste; membro do worker, sem BYPASSRLS),
-- dnex_gestao_folha_worker e dnex_gestao_data_owner (os de produção).
-- Os valores e chaves de parâmetro deste arquivo são fictícios; nenhum é dado normativo.
BEGIN;

SELECT plan(142);

-- ---------------------------------------------------------------------------
-- Apoio
-- ---------------------------------------------------------------------------
CREATE FUNCTION pg_temp.como(p_papel text, p_conta text, p_nonce text, p_sql text)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v_saida text;
BEGIN
  PERFORM set_config('folha.account_id', COALESCE(p_conta, ''), true);
  PERFORM set_config('dnex.context_nonce', COALESCE(p_nonce, ''), true);
  EXECUTE format('SET LOCAL ROLE %I', p_papel);
  BEGIN
    EXECUTE p_sql INTO v_saida;
  EXCEPTION WHEN OTHERS THEN
    v_saida := 'ERRO ' || SQLSTATE || ': ' || SQLERRM;
  END;
  RESET ROLE;
  PERFORM set_config('folha.account_id', '', true);
  PERFORM set_config('dnex.context_nonce', '', true);
  RETURN v_saida;
END
$$;

\set A '''a0000000-0000-0000-0000-000000000001'''
\set B '''b0000000-0000-0000-0000-000000000002'''

-- Uma linha por conta em cada tabela nova (ids fixos: 1 = conta A, 2 = conta B).
INSERT INTO folha.employer (employer_id, account_id, tipo_inscricao, inscricao, razao_social) VALUES
  ('e0000000-0000-0000-0000-000000000001', :A, 'cnpj', '11111111', 'Empresa A Ltda'),
  ('e0000000-0000-0000-0000-000000000002', :B, 'cnpj', '22222222', 'Empresa B Ltda');

INSERT INTO folha.employer_regime (account_id, employer_id, vigencia_inicio, vigencia_fim, regime_tributario) VALUES
  (:A, 'e0000000-0000-0000-0000-000000000001', '2026-01-01', '2026-12-31', 'lucro_presumido'),
  (:B, 'e0000000-0000-0000-0000-000000000002', '2026-01-01', NULL, 'lucro_real');

INSERT INTO folha.establishment (establishment_id, account_id, employer_id, tipo_inscricao, inscricao, cnae_preponderante) VALUES
  ('f0000000-0000-0000-0000-000000000001', :A, 'e0000000-0000-0000-0000-000000000001', 'cnpj', '11111111000111', '0000000'),
  ('f0000000-0000-0000-0000-000000000002', :B, 'e0000000-0000-0000-0000-000000000002', 'cnpj', '22222222000222', '0000000');

INSERT INTO folha.establishment_fap (account_id, establishment_id, vigencia_inicio, vigencia_fim, fap, fap_origem) VALUES
  (:A, 'f0000000-0000-0000-0000-000000000001', '2026-01-01', NULL, 1.2345, 'cenario de teste'),
  (:B, 'f0000000-0000-0000-0000-000000000002', '2026-01-01', NULL, 0.7500, 'cenario de teste');

INSERT INTO folha.tax_allocation (allocation_id, account_id, establishment_id, codigo_lotacao, tipo_lotacao) VALUES
  ('10000000-0000-0000-0000-000000000001', :A, 'f0000000-0000-0000-0000-000000000001', 'LOT-A1', 'teste'),
  ('10000000-0000-0000-0000-000000000003', :A, 'f0000000-0000-0000-0000-000000000001', 'LOT-A2', 'teste'),
  ('10000000-0000-0000-0000-000000000002', :B, 'f0000000-0000-0000-0000-000000000002', 'LOT-B1', 'teste');

INSERT INTO folha.tax_allocation_detail (account_id, allocation_id, vigencia_inicio, vigencia_fim, fpas, codigo_terceiros) VALUES
  (:A, '10000000-0000-0000-0000-000000000001', '2026-01-01', '2026-06-30', 'T1', 'T1'),
  (:B, '10000000-0000-0000-0000-000000000002', '2026-01-01', NULL, 'T2', 'T2');

INSERT INTO folha.employee (employee_id, account_id, cpf, nome_completo, data_nascimento) VALUES
  ('c0000000-0000-0000-0000-000000000001', :A, '33333333333', 'Trabalhador A', '1990-01-01'),
  ('c0000000-0000-0000-0000-000000000002', :B, '44444444444', 'Trabalhador B', '1990-01-01');

INSERT INTO folha.employment_contract (contract_id, account_id, employee_id, data_admissao, cargo, salario_base, regime_trabalho) VALUES
  ('d0000000-0000-0000-0000-000000000001', :A, 'c0000000-0000-0000-0000-000000000001', '2026-01-01', 'Analista', 5000.00, 'clt'),
  ('d0000000-0000-0000-0000-000000000003', :A, 'c0000000-0000-0000-0000-000000000001', '2026-01-01', 'Analista', 5000.00, 'clt'),
  ('d0000000-0000-0000-0000-000000000002', :B, 'c0000000-0000-0000-0000-000000000002', '2026-01-01', 'Analista', 5000.00, 'clt');

INSERT INTO folha.contract_tax_allocation (account_id, contract_id, allocation_id, percentual, vigencia_inicio) VALUES
  (:A, 'd0000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 100, '2026-01-01'),
  (:B, 'd0000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 100, '2026-01-01');

INSERT INTO folha.payroll_parameter (account_id, chave, valor_numerico, vigencia_inicio, vigencia_fim, fonte_normativa, status_validacao, conferido_por, conferido_em) VALUES
  (:A, 'parametro_teste', 123.45, '2026-01-01', '2026-12-31', 'fonte ficticia de teste', 'validado', 'teste', now()),
  (:B, 'parametro_teste', 999.00, '2026-01-01', NULL, NULL, 'a_validar', NULL, NULL),
  (:B, 'so_da_conta_b', 1, '2026-01-01', NULL, NULL, 'a_validar', NULL, NULL);

-- Asserções de gestao_auth para o caminho real (nonce dnex.context_nonce).
INSERT INTO gestao_auth.access_assertion (assertion_id, account_id, consumed_at, revoked_at, expires_at) VALUES
  ('aa000000-0000-0000-0000-000000000001', :A, NULL, NULL, now() + interval '1 hour'),   -- válida, conta A
  ('aa000000-0000-0000-0000-000000000002', :B, NULL, NULL, now() + interval '1 hour'),   -- válida, conta B
  ('aa000000-0000-0000-0000-000000000003', :A, NULL, NULL, now() - interval '1 second'), -- expirada
  ('aa000000-0000-0000-0000-000000000004', :A, now(), NULL, now() + interval '1 hour'),  -- consumida
  ('aa000000-0000-0000-0000-000000000005', :A, NULL, now(), now() + interval '1 hour');  -- revogada

SET CONSTRAINTS ALL IMMEDIATE;   -- confere agora o rateio do setup (100 em cada contrato)
SET CONSTRAINTS ALL DEFERRED;

-- ---------------------------------------------------------------------------
-- 1. Estrutura (8 tabelas, colunas novas, extensão)
-- ---------------------------------------------------------------------------
SELECT has_table('folha', t, 'tabela ' || t || ' existe')
  FROM unnest(ARRAY['employer', 'employer_regime', 'establishment', 'establishment_fap',
                    'tax_allocation', 'tax_allocation_detail', 'contract_tax_allocation',
                    'payroll_parameter']) AS t;

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

SELECT is(
  (SELECT count(*) FROM pg_constraint
    WHERE contype = 'f' AND confrelid IN ('folha.employer'::regclass, 'folha.establishment'::regclass)
      AND conrelid IN ('folha.employee'::regclass, 'folha.employment_contract'::regclass, 'folha.payroll_run'::regclass)
      AND cardinality(conkey) = 2),
  5::bigint,
  'as cinco colunas de vínculo têm chave estrangeira composta com account_id'
);

-- ---------------------------------------------------------------------------
-- 2. RLS com FORCE e policy por conta em cada tabela nova
-- ---------------------------------------------------------------------------
SELECT ok(
  (SELECT relrowsecurity AND relforcerowsecurity FROM pg_class WHERE oid = ('folha.' || t)::regclass),
  t || ' tem RLS habilitada e FORCE'
)
  FROM unnest(ARRAY['employer', 'employer_regime', 'establishment', 'establishment_fap',
                    'tax_allocation', 'tax_allocation_detail', 'contract_tax_allocation',
                    'payroll_parameter']) AS t;

SELECT is(
  (SELECT count(*) FROM pg_policies
    WHERE schemaname = 'folha'
      AND tablename IN ('employer', 'employer_regime', 'establishment', 'establishment_fap',
                        'tax_allocation', 'tax_allocation_detail', 'contract_tax_allocation',
                        'payroll_parameter')
      AND cmd = 'ALL' AND permissive = 'PERMISSIVE'
      AND qual = '(account_id = folha.current_account_id())'
      AND with_check = '(account_id = folha.current_account_id())'),
  8::bigint,
  'cada tabela nova tem exatamente a policy por conta (USING e WITH CHECK)'
);

SELECT is(
  (SELECT count(*) FROM pg_policies
    WHERE schemaname = 'folha'
      AND tablename IN ('employer', 'employer_regime', 'establishment', 'establishment_fap',
                        'tax_allocation', 'tax_allocation_detail', 'contract_tax_allocation',
                        'payroll_parameter')),
  8::bigint,
  'nenhuma policy adicional (permissiva) nas tabelas novas'
);

-- ---------------------------------------------------------------------------
-- 3. Papéis: quem exerce a RLS nos testes não a ignora
-- ---------------------------------------------------------------------------
SELECT is(
  (SELECT count(*) FROM pg_roles
    WHERE rolname IN ('dnex_folha_ci', 'dnex_gestao_folha_worker', 'dnex_gestao_data_owner')
      AND NOT rolbypassrls AND NOT rolsuper),
  3::bigint,
  'papel de teste, worker e data_owner não têm BYPASSRLS nem SUPERUSER'
);
SELECT ok(
  (SELECT NOT rolcanlogin FROM pg_roles WHERE rolname = 'dnex_folha_ci'),
  'papel de teste dnex_folha_ci não tem LOGIN'
);
SELECT ok(
  NOT pg_has_role('dnex_gestao_folha_worker', 'dnex_folha_ci', 'MEMBER'),
  'o worker não é membro do papel de teste (não pode assumir dnex_folha_ci)'
);

-- ---------------------------------------------------------------------------
-- 4. Isolamento entre contas em cada tabela nova (papel de teste, sem BYPASSRLS)
--    Âncora: a conta A enxerga as próprias linhas (quantidade exata do setup);
--    depois, nenhuma linha da conta B, que existe (o superusuário a conta).
-- ---------------------------------------------------------------------------
SELECT is(
  pg_temp.como('dnex_folha_ci', :A, NULL, format('SELECT count(*) FROM folha.%I', x.t)),
  x.proprias::text,
  x.t || ': conta A vê as próprias linhas'
)
  FROM (VALUES ('employer', 1), ('employer_regime', 1), ('establishment', 1), ('establishment_fap', 1),
               ('tax_allocation', 2), ('tax_allocation_detail', 1), ('contract_tax_allocation', 1),
               ('payroll_parameter', 1)) AS x(t, proprias);

SELECT is(
  pg_temp.como('dnex_folha_ci', :A, NULL,
    format('SELECT count(*) FROM folha.%I WHERE account_id = %L', t, :B)),
  '0',
  t || ': conta A não vê linha da conta B'
)
  FROM unnest(ARRAY['employer', 'employer_regime', 'establishment', 'establishment_fap',
                    'tax_allocation', 'tax_allocation_detail', 'contract_tax_allocation',
                    'payroll_parameter']) AS t;

SELECT is(
  (SELECT count(*) FROM (
     SELECT 1 FROM folha.employer WHERE account_id = :B
     UNION ALL SELECT 1 FROM folha.employer_regime WHERE account_id = :B
     UNION ALL SELECT 1 FROM folha.establishment WHERE account_id = :B
     UNION ALL SELECT 1 FROM folha.establishment_fap WHERE account_id = :B
     UNION ALL SELECT 1 FROM folha.tax_allocation WHERE account_id = :B
     UNION ALL SELECT 1 FROM folha.tax_allocation_detail WHERE account_id = :B
     UNION ALL SELECT 1 FROM folha.contract_tax_allocation WHERE account_id = :B
     UNION ALL SELECT 1 FROM folha.payroll_parameter WHERE account_id = :B) s),
  9::bigint,
  'as linhas da conta B existem (o zero acima não é tabela vazia)'
);

SELECT is(
  pg_temp.como('dnex_folha_ci', :B, NULL, 'SELECT string_agg(razao_social, '','') FROM folha.employer'),
  'Empresa B Ltda',
  'sentido inverso: conta B vê só o próprio employer'
);

SELECT is(
  pg_temp.como('dnex_folha_ci', NULL, NULL, 'SELECT count(*) FROM folha.employer'),
  '0',
  'sem conta na sessão, nem o papel de teste vê linha alguma'
);

-- Gravação cruzada
SELECT matches(
  pg_temp.como('dnex_folha_ci', :A, NULL, format(
    'INSERT INTO folha.employer (account_id, tipo_inscricao, inscricao, razao_social) VALUES (%L, ''cnpj'', ''33333333'', ''Invasora'')', :B)),
  '^ERRO 42501: .*row-level security',
  'conta A não grava employer na conta B (WITH CHECK da policy)'
);
SELECT is(
  pg_temp.como('dnex_folha_ci', :A, NULL, format(
    'WITH u AS (UPDATE folha.employer SET razao_social = ''Alterada'' WHERE account_id = %L RETURNING 1) SELECT count(*) FROM u', :B)),
  '0',
  'conta A não altera employer da conta B'
);
SELECT is(
  (SELECT razao_social FROM folha.employer WHERE employer_id = 'e0000000-0000-0000-0000-000000000002'),
  'Empresa B Ltda',
  'o employer da conta B continua intacto'
);
SELECT is(
  pg_temp.como('dnex_folha_ci', :A, NULL,
    'WITH i AS (INSERT INTO folha.employer (account_id, tipo_inscricao, inscricao, razao_social) VALUES (''a0000000-0000-0000-0000-000000000001'', ''cpf'', ''55555555555'', ''Empregador PF'') RETURNING 1) SELECT count(*) FROM i'),
  '1',
  'conta A grava employer na própria conta (a recusa acima não é falta de permissão)'
);

-- Chave composta: registro de uma conta não aponta para pai de outra, nem como superusuário
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
  format('UPDATE folha.employment_contract SET employer_id = ''e0000000-0000-0000-0000-000000000001''
           WHERE contract_id = ''d0000000-0000-0000-0000-000000000002'''),
  '23503', NULL,
  'contrato da conta B não se vincula a employer da conta A'
);
SELECT throws_ok(
  format('INSERT INTO folha.contract_tax_allocation (account_id, contract_id, allocation_id, percentual, vigencia_inicio)
          VALUES (%L, ''d0000000-0000-0000-0000-000000000003'', ''10000000-0000-0000-0000-000000000002'', 100, ''2026-01-01'')', :A),
  '23503', NULL,
  'rateio de contrato da conta A não usa lotação da conta B'
);

-- ---------------------------------------------------------------------------
-- 5. Conta da sessão: a reserva por parâmetro só vale para o papel de teste
-- ---------------------------------------------------------------------------
SELECT is(
  pg_temp.como('dnex_folha_ci', :A, NULL, 'SELECT folha.current_account_id()'),
  'a0000000-0000-0000-0000-000000000001',
  'papel de teste: folha.account_id define a conta (reserva de CI)'
);
SELECT is(
  pg_temp.como('dnex_gestao_folha_worker', :A, NULL, 'SELECT folha.current_account_id() IS NULL'),
  'true',
  'worker: definir folha.account_id NÃO define a conta'
);
SELECT is(
  pg_temp.como('dnex_gestao_folha_worker', :A, NULL, 'SELECT count(*) FROM folha.employer'),
  '0',
  'worker com folha.account_id = A não lê employer algum (o papel de teste leu 1 acima)'
);
SELECT is(
  pg_temp.como('dnex_gestao_folha_worker', :B, NULL, 'SELECT count(*) FROM folha.payroll_parameter'),
  '0',
  'worker com folha.account_id = B não lê parâmetro algum'
);
SELECT matches(
  pg_temp.como('dnex_gestao_folha_worker', :A, NULL,
    'INSERT INTO folha.employer (account_id, tipo_inscricao, inscricao, razao_social) VALUES (''a0000000-0000-0000-0000-000000000001'', ''cnpj'', ''44444444'', ''Sem contexto'')'),
  '^ERRO 42501: .*row-level security',
  'worker com folha.account_id = A não grava na conta A'
);
SELECT is(
  pg_temp.como('dnex_gestao_data_owner', :A, NULL, 'SELECT count(*) FROM folha.employer'),
  '0',
  'data_owner com folha.account_id = A não lê employer algum'
);
SELECT is(
  pg_temp.como('dnex_gestao_folha_worker', 'nao-e-uuid', NULL, 'SELECT folha.current_account_id() IS NULL'),
  'true',
  'worker: o parâmetro de sessão nem chega a ser interpretado'
);
-- Dentro de função SECURITY DEFINER o papel efetivo é o dono, não o papel de teste:
-- a reserva não vale lá, nem para o papel de teste.
CREATE FUNCTION public.folha_teste_conta_em_definer() RETURNS uuid
LANGUAGE sql SECURITY DEFINER AS $$ SELECT folha.current_account_id() $$;
GRANT EXECUTE ON FUNCTION public.folha_teste_conta_em_definer() TO dnex_folha_ci;
SELECT is(
  pg_temp.como('dnex_folha_ci', :A, NULL, 'SELECT public.folha_teste_conta_em_definer() IS NULL'),
  'true',
  'a reserva não atravessa função SECURITY DEFINER'
);

-- ---------------------------------------------------------------------------
-- 6. Caminho de produção: asserção de gestao_auth pelo nonce dnex.context_nonce
-- ---------------------------------------------------------------------------
SELECT is(
  pg_temp.como('dnex_gestao_folha_worker', NULL, 'aa000000-0000-0000-0000-000000000001', 'SELECT folha.current_account_id()'),
  'a0000000-0000-0000-0000-000000000001',
  'worker com asserção válida da conta A: a conta é A'
);
SELECT is(
  pg_temp.como('dnex_gestao_folha_worker', NULL, 'aa000000-0000-0000-0000-000000000001',
    'SELECT string_agg(razao_social, '','' ORDER BY razao_social) FROM folha.employer'),
  'Empregador PF,Empresa A Ltda',
  'worker com asserção da conta A lê só os employers da conta A (o do setup e o gravado acima)'
);
SELECT is(
  pg_temp.como('dnex_gestao_folha_worker', NULL, 'aa000000-0000-0000-0000-000000000002',
    'SELECT string_agg(razao_social, '','' ORDER BY razao_social) FROM folha.employer'),
  'Empresa B Ltda',
  'worker com asserção da conta B lê só o employer da conta B'
);
SELECT is(
  pg_temp.como('dnex_gestao_folha_worker', :B, 'aa000000-0000-0000-0000-000000000001', 'SELECT folha.current_account_id()'),
  'a0000000-0000-0000-0000-000000000001',
  'worker com asserção de A e folha.account_id = B: continua na conta A'
);
SELECT is(
  pg_temp.como('dnex_gestao_folha_worker', :B, 'aa000000-0000-0000-0000-000000000001',
    format('SELECT count(*) FROM folha.employer WHERE account_id = %L', :B)),
  '0',
  'worker com asserção de A não troca para B definindo folha.account_id'
);
SELECT is(
  pg_temp.como('dnex_folha_ci', :B, 'aa000000-0000-0000-0000-000000000001', 'SELECT folha.current_account_id()'),
  'a0000000-0000-0000-0000-000000000001',
  'a asserção prevalece sobre a reserva, mesmo para o papel de teste'
);
SELECT is(
  pg_temp.como('dnex_gestao_folha_worker', NULL, n.nonce, 'SELECT folha.current_account_id() IS NULL'),
  'true',
  'asserção ' || n.estado || ' não define a conta'
)
  FROM (VALUES ('aa000000-0000-0000-0000-000000000003', 'expirada'),
               ('aa000000-0000-0000-0000-000000000004', 'consumida'),
               ('aa000000-0000-0000-0000-000000000005', 'revogada'),
               ('aa000000-0000-0000-0000-0000000000ff', 'inexistente')) AS n(nonce, estado);
SELECT is(
  pg_temp.como('dnex_gestao_folha_worker', NULL, 'aa000000-0000-0000-0000-000000000003', 'SELECT count(*) FROM folha.employer'),
  '0',
  'worker com asserção expirada não lê employer algum'
);
SELECT is(
  pg_temp.como('dnex_gestao_folha_worker', NULL, 'aa000000-0000-0000-0000-000000000001',
    'WITH i AS (INSERT INTO folha.establishment (account_id, employer_id, tipo_inscricao, inscricao, cnae_preponderante) VALUES (''a0000000-0000-0000-0000-000000000001'', ''e0000000-0000-0000-0000-000000000001'', ''cno'', ''123456789012'', ''0000000'') RETURNING 1) SELECT count(*) FROM i'),
  '1',
  'worker com asserção da conta A grava na conta A'
);
SELECT matches(
  pg_temp.como('dnex_gestao_folha_worker', NULL, 'aa000000-0000-0000-0000-000000000001', format(
    'INSERT INTO folha.employer (account_id, tipo_inscricao, inscricao, razao_social) VALUES (%L, ''cnpj'', ''66666666'', ''Invasora'')', :B)),
  '^ERRO 42501: .*row-level security',
  'worker com asserção da conta A não grava na conta B'
);
SELECT is(
  pg_temp.como('dnex_gestao_data_owner', NULL, 'aa000000-0000-0000-0000-000000000001', 'SELECT count(*) FROM folha.employer_regime'),
  '1',
  'data_owner com asserção da conta A lê o regime da conta A'
);
SELECT matches(
  pg_temp.como('dnex_gestao_data_owner', NULL, 'aa000000-0000-0000-0000-000000000001',
    'UPDATE folha.employer SET razao_social = ''X'''),
  '^ERRO 42501: permission denied',
  'data_owner só lê: UPDATE em employer é negado'
);
SELECT matches(
  pg_temp.como('dnex_gestao_folha_worker', NULL, 'aa000000-0000-0000-0000-000000000001',
    'DELETE FROM folha.contract_tax_allocation'),
  '^ERRO 42501: permission denied',
  'worker não tem DELETE (mesmo critério da 0014)'
);

-- ---------------------------------------------------------------------------
-- 7. Vigências sem sobreposição (datas inclusivas; fim nulo = em aberto)
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
  format('INSERT INTO folha.tax_allocation (account_id, establishment_id, codigo_lotacao, tipo_lotacao)
          VALUES (%L, ''f0000000-0000-0000-0000-000000000001'', ''LOT-A1'', ''teste'')', :A),
  '23505', NULL,
  'tax_allocation rejeita código de lotação repetido no estabelecimento'
);
SELECT throws_ok(
  format('INSERT INTO folha.payroll_parameter (account_id, chave, valor_texto, vigencia_inicio)
          VALUES (%L, ''parametro_teste'', ''x'', ''2026-12-31'')', :A),
  '23P01', NULL,
  'payroll_parameter rejeita vigência sobreposta para a mesma chave e conta'
);
SELECT lives_ok(
  format('INSERT INTO folha.payroll_parameter (account_id, chave, valor_texto, vigencia_inicio)
          VALUES (%L, ''parametro_teste'', ''seguinte'', ''2027-01-01'')', :A),
  'payroll_parameter aceita a vigência seguinte da mesma chave'
);
SELECT throws_ok(
  format('INSERT INTO folha.payroll_parameter (account_id, chave, valor_numerico, valor_texto, vigencia_inicio)
          VALUES (%L, ''dois_valores'', 1, ''x'', ''2026-01-01'')', :A),
  '23514', NULL,
  'payroll_parameter rejeita mais de um valor na mesma linha'
);
SELECT throws_ok(
  format('INSERT INTO folha.payroll_parameter (account_id, chave, vigencia_inicio)
          VALUES (%L, ''sem_valor'', ''2026-01-01'')', :A),
  '23514', NULL,
  'payroll_parameter rejeita linha sem valor'
);
SELECT throws_ok(
  format('INSERT INTO folha.payroll_parameter (account_id, chave, valor_numerico, vigencia_inicio, status_validacao)
          VALUES (%L, ''validado_sem_prova'', 1, ''2026-01-01'', ''validado'')', :A),
  '23514', NULL,
  'payroll_parameter rejeita "validado" sem fonte, conferente e data'
);
SELECT throws_ok(
  format('INSERT INTO folha.payroll_parameter (account_id, chave, valor_numerico, vigencia_inicio, status_validacao)
          VALUES (%L, ''estado_invalido'', 1, ''2026-01-01'', ''ok'')', :A),
  '23514', NULL,
  'payroll_parameter só aceita status validado ou a_validar'
);
SELECT is(
  (SELECT column_default FROM information_schema.columns
    WHERE table_schema = 'folha' AND table_name = 'payroll_parameter' AND column_name = 'status_validacao'),
  '''a_validar''::text',
  'payroll_parameter nasce a_validar'
);

-- ---------------------------------------------------------------------------
-- 8. Rateio do contrato por lotação: soma 100 em cada dia coberto
--    O trigger é adiado; SET CONSTRAINTS ALL IMMEDIATE faz a conferência do commit.
--    Contrato d...03 (conta A) começa sem rateio.
-- ---------------------------------------------------------------------------
SELECT throws_ok(
  format('INSERT INTO folha.contract_tax_allocation (account_id, contract_id, allocation_id, percentual, vigencia_inicio)
          VALUES (%L, ''d0000000-0000-0000-0000-000000000003'', ''10000000-0000-0000-0000-000000000001'', 60, ''2026-01-01'');
          SET CONSTRAINTS ALL IMMEDIATE', :A),
  '23514', NULL,
  'rateio de 60 sozinho é rejeitado no fechamento da transação'
);
SELECT throws_ok(
  format('INSERT INTO folha.contract_tax_allocation (account_id, contract_id, allocation_id, percentual, vigencia_inicio) VALUES
            (%1$L, ''d0000000-0000-0000-0000-000000000003'', ''10000000-0000-0000-0000-000000000001'', 60, ''2026-01-01''),
            (%1$L, ''d0000000-0000-0000-0000-000000000003'', ''10000000-0000-0000-0000-000000000003'', 50, ''2026-01-01'');
          SET CONSTRAINTS ALL IMMEDIATE', :A),
  '23514', NULL,
  'rateio de 60 + 50 é rejeitado'
);
SELECT lives_ok(
  format('INSERT INTO folha.contract_tax_allocation (account_id, contract_id, allocation_id, percentual, vigencia_inicio, vigencia_fim)
          VALUES (%1$L, ''d0000000-0000-0000-0000-000000000003'', ''10000000-0000-0000-0000-000000000001'', 60, ''2026-01-01'', ''2026-06-30'');
          INSERT INTO folha.contract_tax_allocation (account_id, contract_id, allocation_id, percentual, vigencia_inicio, vigencia_fim)
          VALUES (%1$L, ''d0000000-0000-0000-0000-000000000003'', ''10000000-0000-0000-0000-000000000003'', 40, ''2026-01-01'', ''2026-06-30'');
          SET CONSTRAINTS ALL IMMEDIATE;
          SET CONSTRAINTS ALL DEFERRED', :A),
  'rateio de 60 + 40 em duas lotações, gravado linha a linha, é aceito'
);
SELECT is(
  (SELECT sum(percentual) FROM folha.contract_tax_allocation WHERE contract_id = 'd0000000-0000-0000-0000-000000000003'),
  100.00,
  'o rateio aceito ficou gravado e soma 100'
);
SELECT throws_ok(
  format('INSERT INTO folha.contract_tax_allocation (account_id, contract_id, allocation_id, percentual, vigencia_inicio)
          VALUES (%L, ''d0000000-0000-0000-0000-000000000003'', ''10000000-0000-0000-0000-000000000001'', 70, ''2026-07-01'');
          SET CONSTRAINTS ALL IMMEDIATE', :A),
  '23514', NULL,
  'vigência seguinte com 70 é rejeitada (o período anterior, correto, não a salva)'
);
SELECT lives_ok(
  format('INSERT INTO folha.contract_tax_allocation (account_id, contract_id, allocation_id, percentual, vigencia_inicio)
          VALUES (%L, ''d0000000-0000-0000-0000-000000000003'', ''10000000-0000-0000-0000-000000000003'', 100, ''2026-07-01'');
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
  format('INSERT INTO folha.contract_tax_allocation (account_id, contract_id, allocation_id, percentual, vigencia_inicio, vigencia_fim)
          VALUES (%L, ''d0000000-0000-0000-0000-000000000003'', ''10000000-0000-0000-0000-000000000001'', 10, ''2026-03-01'', ''2026-03-31'')', :A),
  '23P01', NULL,
  'a mesma lotação não entra duas vezes no mesmo período do contrato'
);
SELECT throws_ok(
  format('INSERT INTO folha.contract_tax_allocation (account_id, contract_id, allocation_id, percentual, vigencia_inicio)
          VALUES (%L, ''d0000000-0000-0000-0000-000000000003'', ''10000000-0000-0000-0000-000000000001'', 0, ''2030-01-01'')', :A),
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
-- 9. get_parameter: devolve o vigente da conta; sem vigência, exceção
-- ---------------------------------------------------------------------------
SELECT is(
  pg_temp.como('dnex_folha_ci', :A, NULL, 'SELECT folha.get_parameter(''parametro_teste'', ''2026-06-01'') ->> ''valor_numerico'''),
  '123.450000',
  'get_parameter devolve o valor vigente da conta A'
);
SELECT is(
  pg_temp.como('dnex_folha_ci', :B, NULL, 'SELECT folha.get_parameter(''parametro_teste'', ''2026-06-01'') ->> ''valor_numerico'''),
  '999.000000',
  'a mesma chave na conta B devolve o valor da conta B'
);
SELECT is(
  pg_temp.como('dnex_folha_ci', :B, NULL, 'SELECT folha.get_parameter(''parametro_teste'', ''2026-06-01'') ->> ''status_validacao'''),
  'a_validar',
  'get_parameter informa o status de validação (a_validar não se passa por validado)'
);
SELECT is(
  pg_temp.como('dnex_folha_ci', :A, NULL, 'SELECT folha.get_parameter(''parametro_teste'', ''2026-12-31'') ->> ''valor_numerico'''),
  '123.450000',
  'o último dia da vigência ainda pertence a ela'
);
SELECT is(
  pg_temp.como('dnex_folha_ci', :A, NULL, 'SELECT folha.get_parameter(''parametro_teste'', ''2027-01-01'') ->> ''valor_texto'''),
  'seguinte',
  'no dia seguinte vale a vigência seguinte'
);
SELECT is(
  pg_temp.como('dnex_folha_ci', :A, NULL, 'SELECT folha.get_parameter(''parametro_teste'', ''2025-12-31'')'),
  'ERRO P0002: Parâmetro "parametro_teste" sem vigência em 2025-12-31',
  'get_parameter levanta exceção antes do início da vigência'
);
SELECT is(
  pg_temp.como('dnex_folha_ci', :A, NULL, 'SELECT folha.get_parameter(''chave_inexistente'', ''2026-06-01'')'),
  'ERRO P0002: Parâmetro "chave_inexistente" sem vigência em 2026-06-01',
  'get_parameter levanta exceção para chave inexistente'
);
SELECT is(
  pg_temp.como('dnex_folha_ci', :A, NULL, 'SELECT folha.get_parameter(''so_da_conta_b'', ''2026-06-01'')'),
  'ERRO P0002: Parâmetro "so_da_conta_b" sem vigência em 2026-06-01',
  'get_parameter não devolve parâmetro de outra conta'
);
SELECT matches(
  pg_temp.como('dnex_gestao_folha_worker', :A, NULL, 'SELECT folha.get_parameter(''parametro_teste'', ''2026-06-01'')'),
  '^ERRO 42501: get_parameter: conta não identificada',
  'worker com folha.account_id (sem asserção) não obtém parâmetro'
);
SELECT is(
  pg_temp.como('dnex_gestao_folha_worker', NULL, 'aa000000-0000-0000-0000-000000000001', 'SELECT folha.get_parameter(''parametro_teste'', ''2026-06-01'') ->> ''fonte_normativa'''),
  'fonte ficticia de teste',
  'worker com asserção da conta A obtém o parâmetro da conta A, com a fonte'
);
SELECT matches(
  pg_temp.como('dnex_folha_ci', :A, NULL, 'SELECT folha.get_parameter(NULL, ''2026-06-01'')'),
  '^ERRO 22004: ',
  'get_parameter recusa chave nula'
);

-- ---------------------------------------------------------------------------
-- 10. ACL
-- ---------------------------------------------------------------------------
SELECT is_empty(
  $$SELECT r.rolname, c.relname, p.priv
      FROM pg_class c
      CROSS JOIN (VALUES ('anon'), ('authenticated'), ('service_role')) AS r(rolname)
      CROSS JOIN unnest(ARRAY['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER']) AS p(priv)
     WHERE c.relnamespace = 'folha'::regnamespace
       AND c.relname IN ('employer', 'employer_regime', 'establishment', 'establishment_fap',
                         'tax_allocation', 'tax_allocation_detail', 'contract_tax_allocation',
                         'payroll_parameter')
       AND has_table_privilege(r.rolname, c.oid, p.priv)$$,
  'anon, authenticated e service_role não têm privilégio algum nas tabelas novas (nem por PUBLIC)'
);

SELECT table_privs_are('folha', t, 'dnex_gestao_folha_worker', ARRAY['SELECT', 'INSERT', 'UPDATE'],
                       t || ': worker lê e grava, sem DELETE')
  FROM unnest(ARRAY['employer', 'employer_regime', 'establishment', 'establishment_fap',
                    'tax_allocation', 'tax_allocation_detail', 'contract_tax_allocation',
                    'payroll_parameter']) AS t;

SELECT table_privs_are('folha', t, 'dnex_gestao_data_owner', ARRAY['SELECT'],
                       t || ': data_owner só lê')
  FROM unnest(ARRAY['employer', 'employer_regime', 'establishment', 'establishment_fap',
                    'tax_allocation', 'tax_allocation_detail', 'contract_tax_allocation',
                    'payroll_parameter']) AS t;

SELECT is_empty(
  $$SELECT r.rolname, p.oid::regprocedure::text
      FROM pg_proc p
      CROSS JOIN (VALUES ('anon'), ('authenticated')) AS r(rolname)
     WHERE p.oid IN ('folha.current_account_id()'::regprocedure,
                     'folha.assertion_account_id()'::regprocedure,
                     'folha.get_parameter(text,date)'::regprocedure,
                     'folha.validar_rateio_contrato()'::regprocedure)
       AND has_function_privilege(r.rolname, p.oid, 'EXECUTE')$$,
  'anon e authenticated não executam as funções desta migration (nem por PUBLIC)'
);
SELECT is(
  (SELECT count(*) FROM (VALUES ('dnex_gestao_folha_worker'), ('dnex_gestao_data_owner')) AS r(rolname)
    CROSS JOIN (VALUES ('folha.current_account_id()'), ('folha.assertion_account_id()'),
                       ('folha.get_parameter(text,date)')) AS f(sig)
    WHERE has_function_privilege(r.rolname, f.sig::regprocedure, 'EXECUTE')),
  6::bigint,
  'worker e data_owner executam current_account_id, assertion_account_id e get_parameter'
);
SELECT is(
  (SELECT string_agg(p.proname || '=' || p.prosecdef::text, ',' ORDER BY p.proname)
     FROM pg_proc p
    WHERE p.oid IN ('folha.current_account_id()'::regprocedure, 'folha.assertion_account_id()'::regprocedure,
                    'folha.get_parameter(text,date)'::regprocedure)),
  'assertion_account_id=true,current_account_id=false,get_parameter=false',
  'só assertion_account_id é SECURITY DEFINER; a condição do papel de teste roda como quem chama'
);
SELECT is_empty(
  $$SELECT p.oid::regprocedure::text FROM pg_proc p
     WHERE p.oid IN ('folha.current_account_id()'::regprocedure, 'folha.assertion_account_id()'::regprocedure,
                     'folha.get_parameter(text,date)'::regprocedure, 'folha.validar_rateio_contrato()'::regprocedure)
       AND NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) AS c WHERE c LIKE 'search_path=%')$$,
  'as funções desta migration têm search_path fixo'
);

SELECT * FROM finish();
ROLLBACK;
