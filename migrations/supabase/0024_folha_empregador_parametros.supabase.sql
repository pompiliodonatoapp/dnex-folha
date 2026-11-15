-- DNEX Folha — Migration 0024: empregador em quatro níveis e conta da sessão.
--
-- Cria: employer, employer_regime, establishment, establishment_fap, tax_allocation,
--       tax_allocation_detail, contract_tax_allocation;
--       funções request_context_account_id() e validar_rateio_contrato().
-- Parâmetros por vigência: NÃO cria tabela nem função. O catálogo é folha.payroll_parameter
--       e a leitura é folha.get_param, ambos da migration 0023; aqui o catálogo só ganha a
--       constraint de vigências sem sobreposição.
-- Corrige: folha.current_account_id() (ver seção 2).
-- Adiciona: employer_id/establishment_id (anuláveis) em employee, employment_contract e payroll_run.
--
-- NÃO APLICAR EM PRODUÇÃO enquanto o dnex-gestao não tiver um grupo de principal para a
-- Folha: hoje nenhum login com acesso às tabelas da Folha consegue abrir contexto pelo
-- protocolo do gestao_auth (seção 2), e depois desta migration nenhuma sessão de
-- aplicação tem conta. Isso é intencional (falha fechada), mas torna a Folha inoperante
-- para o worker até a dependência ser resolvida.
--
-- Vigência: vigencia_inicio e vigencia_fim são datas INCLUSIVAS (mesma leitura da 0016:
-- "vigencia_fim >= competencia"); vigencia_fim NULL = em aberto. A não sobreposição é uma
-- constraint de exclusão sobre daterange(inicio, fim, '[]'), que exige a extensão btree_gist
-- (igualdade de uuid/text em índice GiST). A extensão é nova NESTE repositório; foi preferida
-- a um trigger porque trigger de sobreposição não é seguro sob concorrência sem trava, e a
-- índice único parcial porque este não detecta intervalos que se cruzam.
--
-- Isolamento: todas as tabelas novas têm account_id, RLS com FORCE e policy pela conta da
-- sessão. As chaves estrangeiras são compostas com account_id, e a hierarquia é coerente
-- dentro da conta: estabelecimento preso ao seu empregador em contrato e folha; lotação e
-- contrato do rateio presos ao mesmo empregador.
--
-- Aplicação: uma transação; lock_timeout de 5 s (os ALTER TABLE em employee,
-- employment_contract, payroll_run e payroll_parameter pedem ACCESS EXCLUSIVE: se houver
-- sessão longa, a migration falha inteira em vez de enfileirar atrás dela); as
-- pré-condições são conferidas antes de qualquer DDL e abortam com mensagem própria.
-- Reversão: 0024_folha_empregador_parametros.supabase.down.sql (restaura corpo e GRANTs
-- de current_account_id() da 0014; leia o aviso no topo daquele arquivo).
BEGIN;

SET LOCAL lock_timeout = '5s';

-- ---------------------------------------------------------------------------
-- 0. Pré-condições (falha limpa, antes de qualquer alteração)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_faltando text;
BEGIN
  -- 0.1 O papel de teste só pode existir em banco de CI. O critério de "banco de CI" é o
  --     schema-marcador que tests/ci/bootstrap.sql cria, como superusuário, antes das migrations.
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'dnex_folha_ci')
     AND NOT EXISTS (
       SELECT 1
         FROM pg_catalog.pg_namespace n
         JOIN pg_catalog.pg_roles r ON r.oid = n.nspowner
        WHERE n.nspname = 'dnex_folha_ci_marcador' AND r.rolsuper)
  THEN
    RAISE EXCEPTION '0024: o papel de teste dnex_folha_ci existe neste cluster, mas este banco não é de CI (falta o schema-marcador dnex_folha_ci_marcador de dono superusuário). Remova o papel antes de aplicar.'
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;

  -- 0.2 Objetos do protocolo de contexto do gestao_auth que esta migration lê.
  SELECT string_agg(x.nome, ', ') INTO v_faltando
    FROM (VALUES
      ('gestao_auth.request_context',
         to_regclass('gestao_auth.request_context') IS NULL),
      ('gestao_auth.access_assertion',
         to_regclass('gestao_auth.access_assertion') IS NULL),
      ('gestao_auth.assert_authorization_principal_v1(name, text)',
         to_regprocedure('gestao_auth.assert_authorization_principal_v1(name, text)') IS NULL),
      ('gestao_auth.is_active_scope_v1(uuid, uuid, uuid)',
         to_regprocedure('gestao_auth.is_active_scope_v1(uuid, uuid, uuid)') IS NULL)
    ) AS x(nome, ausente)
   WHERE x.ausente;
  IF v_faltando IS NOT NULL THEN
    RAISE EXCEPTION '0024: faltam objetos do protocolo de contexto do dnex-gestao: %', v_faltando
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;

  -- 0.3 Quem aplica vira dono das funções SECURITY DEFINER desta migration e precisa poder
  --     ler e executar os objetos acima.
  IF NOT (has_table_privilege(current_user, 'gestao_auth.request_context', 'SELECT')
          AND has_table_privilege(current_user, 'gestao_auth.access_assertion', 'SELECT')
          AND has_function_privilege(current_user, 'gestao_auth.assert_authorization_principal_v1(name, text)', 'EXECUTE')
          AND has_function_privilege(current_user, 'gestao_auth.is_active_scope_v1(uuid, uuid, uuid)', 'EXECUTE'))
  THEN
    RAISE EXCEPTION '0024: o papel % não lê gestao_auth.request_context/access_assertion ou não executa as funções de validação do gestao_auth; a conta da sessão ficaria sempre nula', current_user
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- 0.4 A conferência do rateio (seção 5) roda com row_security = off para nunca ser
  --     enganada pela RLS; isso exige dono que ignore RLS.
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles
                  WHERE rolname = current_user AND (rolsuper OR rolbypassrls)) THEN
    RAISE EXCEPTION '0024: o papel % não é superusuário nem tem BYPASSRLS; a conferência do rateio do contrato falharia em toda gravação', current_user
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- 0.5 Extensão da constraint de exclusão.
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_available_extensions WHERE name = 'btree_gist') THEN
    RAISE EXCEPTION '0024: a extensão btree_gist não está disponível neste servidor'
      USING ERRCODE = 'feature_not_supported';
  END IF;

  -- 0.6 O catálogo de parâmetros (0023) não pode ter vigências sobrepostas já gravadas.
  SELECT string_agg(DISTINCT a.chave, ', ') INTO v_faltando
    FROM folha.payroll_parameter a
    JOIN folha.payroll_parameter b
      ON b.chave = a.chave AND b.parameter_id <> a.parameter_id
     AND daterange(a.vigencia_inicio, a.vigencia_fim, '[]') && daterange(b.vigencia_inicio, b.vigencia_fim, '[]');
  IF v_faltando IS NOT NULL THEN
    RAISE EXCEPTION '0024: folha.payroll_parameter tem vigências sobrepostas nas chaves: %', v_faltando
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- 1. Extensão para constraint de exclusão com igualdade + sobreposição de intervalo
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA extensions;

-- ---------------------------------------------------------------------------
-- 2. Conta da sessão
--
--    Antes (0014): current_account_id() era SECURITY DEFINER e tinha dois defeitos.
--    (a) Procurava em gestao_auth.access_assertion uma asserção NÃO consumida cujo
--        assertion_id fosse o valor do GUC dnex.context_nonce. No protocolo do gestao_auth,
--        begin_request CONSOME a asserção e grava no GUC a chave de
--        gestao_auth.request_context, não o assertion_id. Em fluxo real a conta vinha
--        nula; e quem conhecesse um assertion_id ainda não consumido podia usá-lo em
--        SET dnex.context_nonce como credencial reutilizável, sem vínculo com login,
--        processo ou transação.
--    (b) Aceitava, como reserva, o parâmetro de sessão folha.account_id, que qualquer
--        sessão define com SET.
--
--    Agora:
--    request_context_account_id() (SECURITY DEFINER): devolve a conta do contexto da
--    transação, validado como gestao_auth.has_permission valida (dnex-gestao,
--    0007_producer_principal:666-740): linha de request_context do nonce, presa a
--    session_user + PID + txid e dentro da validade; asserção de origem idêntica, consumida
--    naquele instante e não revogada; principal do login conferido por
--    gestao_auth.assert_authorization_principal_v1; escopo ativo por
--    gestao_auth.is_active_scope_v1. As duas últimas são as funções do próprio gestao,
--    reutilizadas. Qualquer falha devolve NULL (nenhuma linha visível, nenhuma gravação).
--    O gestao não tem função que devolva a conta do contexto; a leitura das duas tabelas
--    fica aqui até existir (dependência registrada na ADR).
--    Não confere permissão: a lista fechada de has_permission não tem permissão da Folha.
--    O que esta função estabelece é a CONTA; o que cada papel pode fazer é o GRANT.
--
--    current_account_id() (SECURITY INVOKER): contexto acima; a reserva por
--    folha.account_id só vale quando current_user é dnex_folha_ci E o banco tem o
--    schema-marcador de CI com dono superusuário. Precisa ser INVOKER: dentro de função
--    SECURITY DEFINER current_user é o dono da função. Por isso a reserva também nunca
--    vale quando a chamada vem de dentro de função SECURITY DEFINER.
-- ---------------------------------------------------------------------------
CREATE FUNCTION folha.request_context_account_id() RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, gestao_auth
SET row_security = on
AS $function$
DECLARE
  v_nonce_text text;
  v_txid bigint;
  v_contexto record;
BEGIN
  v_nonce_text := NULLIF(pg_catalog.current_setting('dnex.context_nonce', true), '');
  IF v_nonce_text IS NULL
     OR v_nonce_text !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN
    RETURN NULL;
  END IF;

  -- begin_request usa txid_current(): transação sem xid atribuído não tem contexto.
  v_txid := pg_catalog.txid_current_if_assigned();
  IF v_txid IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT context.account_id, context.legal_entity_id, context.branch_id, context.principal_group
    INTO v_contexto
    FROM gestao_auth.request_context AS context
    JOIN gestao_auth.access_assertion AS assertion
      ON assertion.assertion_id = context.assertion_id
   WHERE context.context_nonce = v_nonce_text::uuid
     AND context.runtime_session_user = session_user
     AND context.backend_pid = pg_catalog.pg_backend_pid()
     AND context.transaction_id = v_txid
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
    RETURN NULL;
  END IF;

  BEGIN
    PERFORM gestao_auth.assert_authorization_principal_v1(session_user, v_contexto.principal_group);
  EXCEPTION WHEN insufficient_privilege THEN
    RETURN NULL;
  END;

  IF NOT COALESCE(gestao_auth.is_active_scope_v1(
       v_contexto.account_id, v_contexto.legal_entity_id, v_contexto.branch_id), false) THEN
    RETURN NULL;
  END IF;

  RETURN v_contexto.account_id;
END
$function$;

CREATE OR REPLACE FUNCTION folha.current_account_id() RETURNS uuid
LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = pg_catalog
AS $$
  SELECT COALESCE(
    folha.request_context_account_id(),
    CASE WHEN current_user = 'dnex_folha_ci'
              AND EXISTS (SELECT 1
                            FROM pg_catalog.pg_namespace n
                            JOIN pg_catalog.pg_roles r ON r.oid = n.nspowner
                           WHERE n.nspname = 'dnex_folha_ci_marcador' AND r.rolsuper)
      THEN NULLIF(current_setting('folha.account_id', true), '')::uuid
    END
  );
$$;

-- ACL das duas funções: tira de todo mundo que não seja o dono (inclusive concessões
-- feitas direto no banco e por default ACL) e concede só aos dois papéis do repositório.
-- Quem tinha EXECUTE em current_account_id() fora do repositório é avisado, não replicado.
DO $$
DECLARE
  v_sig text;
  v_papel text;
BEGIN
  FOREACH v_sig IN ARRAY ARRAY['folha.current_account_id()', 'folha.request_context_account_id()']
  LOOP
    FOR v_papel IN
      SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(r.rolname) END
        FROM pg_catalog.pg_proc p
        CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
        LEFT JOIN pg_catalog.pg_roles r ON r.oid = a.grantee
       WHERE p.oid = v_sig::regprocedure AND a.grantee <> p.proowner
       GROUP BY 1
    LOOP
      IF v_papel NOT IN ('PUBLIC', 'dnex_gestao_folha_worker', 'dnex_gestao_data_owner') THEN
        RAISE WARNING '0024: % perdeu EXECUTE em % (concessão de fora do repositório)', v_papel, v_sig;
      END IF;
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM %s', v_sig, v_papel);
    END LOOP;
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated, service_role', v_sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO dnex_gestao_folha_worker, dnex_gestao_data_owner', v_sig);
  END LOOP;
END
$$;

-- ---------------------------------------------------------------------------
-- 3. Empregador em quatro níveis
-- ---------------------------------------------------------------------------

-- 3.1 Nível 1 — empresa empregadora (raiz)
CREATE TABLE folha.employer (
  employer_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  tipo_inscricao text NOT NULL CHECK (tipo_inscricao IN ('cnpj', 'cpf', 'caepf')),
  inscricao text NOT NULL CHECK (inscricao ~ '^[0-9A-Z]+$'),  -- sem máscara
  razao_social text NOT NULL CHECK (btrim(razao_social) <> ''),
  natureza_juridica text,          -- código oficial; domínio não semeado aqui (a validar na fonte)
  classificacao_tributaria text,   -- código da classificação tributária do eSocial (S-1000); idem
  situacao text NOT NULL DEFAULT 'ativa' CHECK (situacao IN ('ativa', 'inativa', 'baixada')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (account_id, tipo_inscricao, inscricao),
  UNIQUE (account_id, employer_id)   -- alvo das chaves estrangeiras compostas
);

-- 3.2 Nível 2 — regime tributário do empregador por vigência
CREATE TABLE folha.employer_regime (
  regime_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  employer_id uuid NOT NULL,
  vigencia_inicio date NOT NULL,
  vigencia_fim date,               -- inclusiva; NULL = em aberto
  regime_tributario text NOT NULL CHECK (regime_tributario IN (
    'lucro_real', 'lucro_presumido', 'simples_nacional', 'mei',
    'imune_isenta', 'pessoa_fisica', 'orgao_publico'
  )),
  simples_optante boolean NOT NULL DEFAULT false,
  simples_anexo text CHECK (simples_anexo IN ('I', 'II', 'III', 'IV', 'V')),
  -- onde a contribuição patronal do optante é recolhida (LC 123/2006, art. 13, VI, e art. 18, §5º-C)
  simples_cpp text CHECK (simples_cpp IN ('no_das', 'fora_do_das', 'concomitante')),
  cprb_optante boolean NOT NULL DEFAULT false,   -- opção pela CPRB (Lei 12.546/2011)
  -- fração (0 a 1) de redução informada para a vigência, se houver; os fatores legais da
  -- transição NÃO ficam aqui: vêm de folha.payroll_parameter, com fonte normativa
  cprb_percentual_reducao numeric(5,4)
    CHECK (cprb_percentual_reducao >= 0 AND cprb_percentual_reducao <= 1),
  documento_prova text,            -- termo de opção, consulta ou ato que comprova o enquadramento
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT employer_regime_employer_fk FOREIGN KEY (account_id, employer_id)
    REFERENCES folha.employer (account_id, employer_id),
  CONSTRAINT employer_regime_vigencia_valida
    CHECK (vigencia_fim IS NULL OR vigencia_fim >= vigencia_inicio),
  CONSTRAINT employer_regime_simples_coerente
    CHECK (simples_optante OR (simples_anexo IS NULL AND simples_cpp IS NULL)),
  CONSTRAINT employer_regime_cprb_coerente
    CHECK (cprb_optante OR cprb_percentual_reducao IS NULL),
  CONSTRAINT employer_regime_sem_sobreposicao EXCLUDE USING gist (
    employer_id WITH =,
    daterange(vigencia_inicio, vigencia_fim, '[]') WITH &&
  )
);

-- 3.3 Nível 3 — estabelecimento (CNPJ completo, CAEPF ou CNO)
CREATE TABLE folha.establishment (
  establishment_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  employer_id uuid NOT NULL,
  tipo_inscricao text NOT NULL CHECK (tipo_inscricao IN ('cnpj', 'caepf', 'cno')),
  inscricao text NOT NULL CHECK (inscricao ~ '^[0-9A-Z]+$'),  -- sem máscara
  cnae_preponderante text NOT NULL CHECK (cnae_preponderante ~ '^[0-9]+$'),
  nome_fantasia text,
  endereco_json jsonb,
  situacao text NOT NULL DEFAULT 'ativa' CHECK (situacao IN ('ativa', 'inativa', 'baixada')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT establishment_employer_fk FOREIGN KEY (account_id, employer_id)
    REFERENCES folha.employer (account_id, employer_id),
  UNIQUE (account_id, tipo_inscricao, inscricao),
  UNIQUE (account_id, establishment_id),
  -- alvo de quem precisa provar "este estabelecimento é deste empregador"
  UNIQUE (account_id, employer_id, establishment_id)
);

-- 3.3.1 FAP do estabelecimento por vigência (tabela filha)
CREATE TABLE folha.establishment_fap (
  fap_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  establishment_id uuid NOT NULL,
  vigencia_inicio date NOT NULL,
  vigencia_fim date,
  -- multiplicador de 0,5000 a 2,0000 (Decreto 3.048/1999, art. 202-A); sem padrão: o
  -- valor "neutro" para quem ainda não tem FAP está a validar na fonte e não é presumido
  fap numeric(5,4) NOT NULL CHECK (fap >= 0.5000 AND fap <= 2.0000),
  fap_origem text NOT NULL CHECK (btrim(fap_origem) <> ''),  -- de onde veio o número (consulta, decisão)
  processo_judicial_ref text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT establishment_fap_establishment_fk FOREIGN KEY (account_id, establishment_id)
    REFERENCES folha.establishment (account_id, establishment_id),
  CONSTRAINT establishment_fap_vigencia_valida
    CHECK (vigencia_fim IS NULL OR vigencia_fim >= vigencia_inicio),
  CONSTRAINT establishment_fap_sem_sobreposicao EXCLUDE USING gist (
    establishment_id WITH =,
    daterange(vigencia_inicio, vigencia_fim, '[]') WITH &&
  )
);

-- 3.4 Nível 4 — lotação tributária (identidade)
--     employer_id é repetido aqui (e conferido contra o estabelecimento) para que o
--     rateio do contrato possa exigir "lotação do mesmo empregador do contrato".
CREATE TABLE folha.tax_allocation (
  allocation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  employer_id uuid NOT NULL,
  establishment_id uuid NOT NULL,
  codigo_lotacao text NOT NULL CHECK (btrim(codigo_lotacao) <> ''),
  tipo_lotacao text NOT NULL,      -- código do tipo de lotação do eSocial; domínio a validar na fonte
  descricao text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT tax_allocation_establishment_fk FOREIGN KEY (account_id, employer_id, establishment_id)
    REFERENCES folha.establishment (account_id, employer_id, establishment_id),
  UNIQUE (account_id, establishment_id, codigo_lotacao),
  UNIQUE (account_id, allocation_id),
  UNIQUE (account_id, employer_id, allocation_id)
);

-- 3.4.1 Enquadramento da lotação por vigência (tabela filha)
--       Alíquotas como fração (0,01 = 1%). Nenhum valor é semeado nem presumido:
--       FPAS, terceiros, RAT e patronal entram pelo cadastro, com vigência.
CREATE TABLE folha.tax_allocation_detail (
  detail_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  allocation_id uuid NOT NULL,
  vigencia_inicio date NOT NULL,
  vigencia_fim date,
  fpas text,
  codigo_terceiros text,
  aliquota_rat numeric(5,4) CHECK (aliquota_rat >= 0 AND aliquota_rat <= 1),
  percentual_patronal numeric(5,4) CHECK (percentual_patronal >= 0 AND percentual_patronal <= 1),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT tax_allocation_detail_allocation_fk FOREIGN KEY (account_id, allocation_id)
    REFERENCES folha.tax_allocation (account_id, allocation_id),
  CONSTRAINT tax_allocation_detail_vigencia_valida
    CHECK (vigencia_fim IS NULL OR vigencia_fim >= vigencia_inicio),
  CONSTRAINT tax_allocation_detail_sem_sobreposicao EXCLUDE USING gist (
    allocation_id WITH =,
    daterange(vigencia_inicio, vigencia_fim, '[]') WITH &&
  )
);

-- ---------------------------------------------------------------------------
-- 4. Vínculo das tabelas existentes com o empregador (colunas anuláveis nesta migration)
--    Estabelecimento só com empregador, e sempre do mesmo empregador (chave composta de
--    três colunas; o CHECK fecha a brecha do MATCH SIMPLE quando employer_id é nulo).
-- ---------------------------------------------------------------------------
ALTER TABLE folha.employee
  ADD COLUMN employer_id uuid,
  ADD CONSTRAINT employee_employer_fk FOREIGN KEY (account_id, employer_id)
    REFERENCES folha.employer (account_id, employer_id);
CREATE INDEX idx_employee_employer ON folha.employee (account_id, employer_id)
  WHERE employer_id IS NOT NULL;

ALTER TABLE folha.employment_contract
  ADD COLUMN employer_id uuid,
  ADD COLUMN establishment_id uuid,
  ADD CONSTRAINT contract_employer_fk FOREIGN KEY (account_id, employer_id)
    REFERENCES folha.employer (account_id, employer_id),
  ADD CONSTRAINT contract_establishment_fk FOREIGN KEY (account_id, employer_id, establishment_id)
    REFERENCES folha.establishment (account_id, employer_id, establishment_id),
  ADD CONSTRAINT contract_establishment_exige_employer
    CHECK (establishment_id IS NULL OR employer_id IS NOT NULL);
CREATE INDEX idx_contract_employer ON folha.employment_contract (account_id, employer_id)
  WHERE employer_id IS NOT NULL;
CREATE INDEX idx_contract_establishment ON folha.employment_contract (account_id, establishment_id)
  WHERE establishment_id IS NOT NULL;
-- alvo da chave composta do rateio: prova que o contrato é daquele empregador
CREATE UNIQUE INDEX employment_contract_account_employer_contract_key
  ON folha.employment_contract (account_id, employer_id, contract_id);

ALTER TABLE folha.payroll_run
  ADD COLUMN employer_id uuid,
  ADD COLUMN establishment_id uuid,
  ADD CONSTRAINT run_employer_fk FOREIGN KEY (account_id, employer_id)
    REFERENCES folha.employer (account_id, employer_id),
  ADD CONSTRAINT run_establishment_fk FOREIGN KEY (account_id, employer_id, establishment_id)
    REFERENCES folha.establishment (account_id, employer_id, establishment_id),
  ADD CONSTRAINT run_establishment_exige_employer
    CHECK (establishment_id IS NULL OR employer_id IS NOT NULL);
CREATE INDEX idx_run_employer ON folha.payroll_run (account_id, employer_id)
  WHERE employer_id IS NOT NULL;
CREATE INDEX idx_run_establishment ON folha.payroll_run (account_id, establishment_id)
  WHERE establishment_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 5. Rateio do contrato por lotação (percentual somando 100 em cada dia coberto)
--    Contrato e lotação precisam ser do MESMO empregador (employer_id entra nas duas
--    chaves estrangeiras). Estabelecimentos diferentes do mesmo empregador são aceitos:
--    o S-1200 informa a remuneração por estabelecimento e lotação (ideEstabLot), e um
--    contrato pode ser rateado entre lotações de mais de um estabelecimento.
--    Consequência: só há rateio para contrato com empregador preenchido.
-- ---------------------------------------------------------------------------
CREATE TABLE folha.contract_tax_allocation (
  allocation_entry_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  employer_id uuid NOT NULL,
  contract_id uuid NOT NULL,
  allocation_id uuid NOT NULL,
  percentual numeric(5,2) NOT NULL CHECK (percentual > 0 AND percentual <= 100),
  vigencia_inicio date NOT NULL,
  vigencia_fim date,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT contract_tax_allocation_contract_fk FOREIGN KEY (account_id, employer_id, contract_id)
    REFERENCES folha.employment_contract (account_id, employer_id, contract_id),
  CONSTRAINT contract_tax_allocation_allocation_fk FOREIGN KEY (account_id, employer_id, allocation_id)
    REFERENCES folha.tax_allocation (account_id, employer_id, allocation_id),
  CONSTRAINT contract_tax_allocation_vigencia_valida
    CHECK (vigencia_fim IS NULL OR vigencia_fim >= vigencia_inicio),
  -- a mesma lotação não aparece duas vezes no mesmo dia para o mesmo contrato;
  -- lotações diferentes podem (e devem) coexistir: é isso que é o rateio
  CONSTRAINT contract_tax_allocation_sem_sobreposicao EXCLUDE USING gist (
    contract_id WITH =,
    allocation_id WITH =,
    daterange(vigencia_inicio, vigencia_fim, '[]') WITH &&
  )
);
CREATE INDEX idx_contract_tax_allocation_allocation
  ON folha.contract_tax_allocation (account_id, allocation_id);

-- A soma é conferida no fim da transação (trigger de constraint adiado), para que as
-- linhas de um rateio possam ser gravadas uma a uma. Regra: em todo dia em que o contrato
-- tem alguma linha de rateio vigente, a soma dos percentuais vigentes é exatamente 100.
-- A soma só muda nos inícios de vigência e no dia seguinte a cada fim; basta conferir
-- esses dias. Dia sem nenhuma linha vigente é permitido (contrato ainda sem rateio).
--
-- A conferência não depende de quem grava nem do contexto da sessão:
--   * SECURITY DEFINER com row_security = off: lê todas as linhas do contrato mesmo que a
--     sessão tenha perdido ou trocado o contexto antes do COMMIT (com RLS, a soma viria
--     nula e passaria). Se o dono não ignorar RLS, a leitura falha em vez de vir vazia.
--   * Filtro explícito por account_id e contract_id.
--   * Serialização por contrato: antes de somar, grava a linha do contrato (updated_at).
--     Duas transações que rateiam o mesmo contrato ficam em fila; a segunda, ao somar, já
--     enxerga as linhas confirmadas da primeira (READ COMMITTED) ou falha com erro de
--     serialização (REPEATABLE READ e SERIALIZABLE). Sem isso, cada uma veria só as
--     próprias linhas e as duas passariam com 100.
CREATE FUNCTION folha.validar_rateio_contrato() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog
SET row_security = off
AS $$
DECLARE
  v_contas uuid[];
  v_contratos uuid[];
  i integer;
  v_dia date;
  v_soma numeric;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_contas := ARRAY[NEW.account_id];
    v_contratos := ARRAY[NEW.contract_id];
  ELSIF TG_OP = 'DELETE' THEN
    v_contas := ARRAY[OLD.account_id];
    v_contratos := ARRAY[OLD.contract_id];
  ELSE
    v_contas := ARRAY[NEW.account_id, OLD.account_id];
    v_contratos := ARRAY[NEW.contract_id, OLD.contract_id];
  END IF;

  FOR i IN 1 .. array_length(v_contratos, 1)
  LOOP
    UPDATE folha.employment_contract c
       SET updated_at = now()
     WHERE c.account_id = v_contas[i] AND c.contract_id = v_contratos[i];

    SELECT d.dia, s.soma INTO v_dia, v_soma
      FROM (
        SELECT c.vigencia_inicio AS dia
          FROM folha.contract_tax_allocation c
         WHERE c.account_id = v_contas[i] AND c.contract_id = v_contratos[i]
        UNION
        SELECT c.vigencia_fim + 1
          FROM folha.contract_tax_allocation c
         WHERE c.account_id = v_contas[i] AND c.contract_id = v_contratos[i]
           AND c.vigencia_fim IS NOT NULL
      ) d
      CROSS JOIN LATERAL (
        SELECT sum(c.percentual) AS soma
          FROM folha.contract_tax_allocation c
         WHERE c.account_id = v_contas[i] AND c.contract_id = v_contratos[i]
           AND c.vigencia_inicio <= d.dia
           AND (c.vigencia_fim IS NULL OR c.vigencia_fim >= d.dia)
      ) s
     WHERE s.soma IS NOT NULL AND s.soma <> 100
     ORDER BY d.dia
     LIMIT 1;

    IF FOUND THEN
      RAISE EXCEPTION 'Rateio do contrato % deve somar 100 em %: soma atual %',
        v_contratos[i], v_dia, v_soma
        USING ERRCODE = 'check_violation';
    END IF;
  END LOOP;

  RETURN NULL;
END
$$;

REVOKE ALL ON FUNCTION folha.validar_rateio_contrato() FROM PUBLIC, anon, authenticated, service_role;

CREATE CONSTRAINT TRIGGER trg_validar_rateio_contrato
  AFTER INSERT OR UPDATE OR DELETE ON folha.contract_tax_allocation
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW EXECUTE FUNCTION folha.validar_rateio_contrato();

-- ---------------------------------------------------------------------------
-- 6. Parâmetros por vigência: o catálogo é o da migration 0023
--    folha.payroll_parameter (global, sem account_id: parâmetro legal é igual para todas as
--    contas) e folha.get_param(chave, data), que levanta exceção quando não há parâmetro
--    vigente, já existem desde a 0023 e continuam sendo a única tabela e a única leitura.
--    Esta migration NÃO cria outra tabela nem outra função de leitura. Sobreposição por
--    conta ou por empregador (convenção, regra da empresa) não tem consumidor hoje e fica
--    para a fatia das três camadas de regra.
--
--    O que entra aqui é só a garantia que faltava no catálogo: vigências da mesma chave não
--    se sobrepõem (a 0023 tem apenas UNIQUE (chave, vigencia_inicio) e get_param escolhe a
--    vigência mais recente). Datas inclusivas, como get_param já lê.
-- ---------------------------------------------------------------------------
ALTER TABLE folha.payroll_parameter
  ADD CONSTRAINT payroll_parameter_vigencia_valida
    CHECK (vigencia_fim IS NULL OR vigencia_fim >= vigencia_inicio),
  ADD CONSTRAINT payroll_parameter_sem_sobreposicao EXCLUDE USING gist (
    chave WITH =,
    daterange(vigencia_inicio, vigencia_fim, '[]') WITH &&
  );

-- ---------------------------------------------------------------------------
-- 7. RLS (ENABLE + FORCE), policy por conta e ACL.
--    Mesmo critério da 0014: worker lê e grava (sem DELETE); data_owner só lê.
--    payroll_parameter não entra: RLS, policies e ACL dela são os da 0023.
--    A policy usa (SELECT folha.current_account_id()) para a conta ser resolvida uma vez
--    por comando, e não a cada linha.
--    ACL: antes de conceder, tira TUDO de TODO papel que não seja o dono — não só de uma
--    lista fixa. Um default ACL do schema (ALTER DEFAULT PRIVILEGES) pode ter dado
--    privilégio a qualquer papel no momento do CREATE TABLE.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_tabela text;
  v_papel text;
BEGIN
  FOREACH v_tabela IN ARRAY ARRAY[
    'employer', 'employer_regime', 'establishment', 'establishment_fap',
    'tax_allocation', 'tax_allocation_detail', 'contract_tax_allocation'
  ]
  LOOP
    EXECUTE format('ALTER TABLE folha.%I ENABLE ROW LEVEL SECURITY', v_tabela);
    EXECUTE format('ALTER TABLE folha.%I FORCE ROW LEVEL SECURITY', v_tabela);
    EXECUTE format(
      'CREATE POLICY %I ON folha.%I
         USING (account_id = (SELECT folha.current_account_id()))
         WITH CHECK (account_id = (SELECT folha.current_account_id()))',
      v_tabela || '_isolamento', v_tabela);

    FOR v_papel IN
      SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(r.rolname) END
        FROM pg_catalog.pg_class c
        CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) a
        LEFT JOIN pg_catalog.pg_roles r ON r.oid = a.grantee
       WHERE c.oid = format('folha.%I', v_tabela)::regclass AND a.grantee <> c.relowner
       GROUP BY 1
    LOOP
      EXECUTE format('REVOKE ALL ON folha.%I FROM %s', v_tabela, v_papel);
    END LOOP;
    EXECUTE format(
      'REVOKE ALL ON folha.%I FROM PUBLIC, anon, authenticated, service_role', v_tabela);
    EXECUTE format(
      'GRANT SELECT, INSERT, UPDATE ON folha.%I TO dnex_gestao_folha_worker', v_tabela);
    EXECUTE format(
      'GRANT SELECT ON folha.%I TO dnex_gestao_data_owner', v_tabela);
  END LOOP;

  -- A função do trigger não é chamada por ninguém diretamente: nenhum EXECUTE além do dono.
  FOR v_papel IN
    SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(r.rolname) END
      FROM pg_catalog.pg_proc p
      CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
      LEFT JOIN pg_catalog.pg_roles r ON r.oid = a.grantee
     WHERE p.oid = 'folha.validar_rateio_contrato()'::regprocedure AND a.grantee <> p.proowner
     GROUP BY 1
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION folha.validar_rateio_contrato() FROM %s', v_papel);
  END LOOP;
END
$$;

COMMIT;
