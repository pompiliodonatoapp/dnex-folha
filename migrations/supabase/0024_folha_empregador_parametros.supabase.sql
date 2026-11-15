-- DNEX Folha — Migration 0024: empregador em quatro níveis e parâmetros por vigência.
--
-- Cria: employer, employer_regime, establishment, establishment_fap, tax_allocation,
--       tax_allocation_detail, contract_tax_allocation;
--       funções assertion_account_id() e validar_rateio_contrato().
-- Parâmetros por vigência: NÃO cria tabela nem função. O catálogo é folha.payroll_parameter
--       e a leitura é folha.get_param, ambos da migration 0023; aqui o catálogo só ganha a
--       constraint de vigências sem sobreposição.
-- Corrige: folha.current_account_id() — a reserva por parâmetro de sessão (folha.account_id)
--       só vale para o papel de teste dnex_folha_ci, que esta migration NÃO cria.
-- Adiciona: employer_id/establishment_id (anuláveis) em employee, employment_contract e payroll_run.
--
-- Vigência: vigencia_inicio e vigencia_fim são datas INCLUSIVAS (mesma leitura da 0016:
-- "vigencia_fim >= competencia"); vigencia_fim NULL = em aberto. A não sobreposição é uma
-- constraint de exclusão sobre daterange(inicio, fim, '[]'), que exige a extensão btree_gist
-- (igualdade de uuid/text em índice GiST). A extensão é nova NESTE repositório; foi preferida
-- a um trigger porque trigger de sobreposição não é seguro sob concorrência sem trava, e a
-- índice único parcial porque este não detecta intervalos que se cruzam.
--
-- Isolamento: todas as tabelas novas têm account_id, RLS com FORCE e policy pela conta da sessão.
-- As chaves estrangeiras entre as tabelas novas são compostas (account_id, id): um registro
-- não pode apontar para pai de outra conta, nem conhecendo o uuid.
--
-- Reversão (manual, nesta ordem): DROP de contract_tax_allocation, tax_allocation_detail,
-- tax_allocation, establishment_fap e employer_regime; remover as colunas
-- employer_id/establishment_id de payroll_run, employment_contract e employee; DROP de
-- establishment e employer; DROP da função validar_rateio_contrato; DROP do índice
-- employment_contract_account_contract_key; DROP das constraints payroll_parameter_vigencia_valida
-- e payroll_parameter_sem_sobreposicao.
-- NÃO restaurar o corpo antigo de current_account_id(): ele é a falha corrigida aqui.
BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Extensão para constraint de exclusão com igualdade + sobreposição de intervalo
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA extensions;

-- ---------------------------------------------------------------------------
-- 2. Correção de segurança: conta da sessão
--
--    Antes (0014): current_account_id() era SECURITY DEFINER e devolvia, como reserva,
--    o parâmetro de sessão folha.account_id, que qualquer sessão pode definir com SET.
--    O worker podia, assim, escolher a conta.
--
--    Agora são duas funções:
--    a) assertion_account_id(): SECURITY DEFINER, lê SOMENTE a asserção de
--       gestao_auth.access_assertion apontada pelo nonce dnex.context_nonce.
--       É o caminho de produção, inalterado.
--    b) current_account_id(): SECURITY INVOKER. Precisa ser INVOKER porque dentro de
--       função SECURITY DEFINER current_user é o dono da função, nunca o papel da
--       sessão, e a condição do papel de teste jamais seria verdadeira (nem falsa de
--       forma útil). Devolve a asserção; só se current_user for dnex_folha_ci (papel
--       criado no bootstrap de CI, inexistente em produção) aceita a reserva.
--       Chamada de dentro de função SECURITY DEFINER, a reserva nunca vale.
-- ---------------------------------------------------------------------------
CREATE FUNCTION folha.assertion_account_id() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, gestao_auth
AS $$
  SELECT account_id FROM gestao_auth.access_assertion
   WHERE assertion_id = NULLIF(current_setting('dnex.context_nonce', true), '')::uuid
     AND consumed_at IS NULL
     AND revoked_at IS NULL
     AND expires_at > now()
   LIMIT 1;
$$;

REVOKE ALL ON FUNCTION folha.assertion_account_id() FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION folha.current_account_id() RETURNS uuid
LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = pg_catalog
AS $$
  SELECT COALESCE(
    folha.assertion_account_id(),
    CASE WHEN current_user = 'dnex_folha_ci'
      THEN NULLIF(current_setting('folha.account_id', true), '')::uuid
    END
  );
$$;

REVOKE ALL ON FUNCTION folha.current_account_id() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION folha.current_account_id() TO dnex_gestao_folha_worker;
GRANT EXECUTE ON FUNCTION folha.current_account_id() TO dnex_gestao_data_owner;

-- Quem executa current_account_id() precisa executar assertion_account_id(), senão a
-- policy de RLS passaria a falhar com "permission denied". Além dos dois papéis do
-- repositório, replica o EXECUTE para qualquer papel que o tenha recebido fora dele
-- (concessões feitas direto no banco), exceto PUBLIC, anon e authenticated.
GRANT EXECUTE ON FUNCTION folha.assertion_account_id() TO dnex_gestao_folha_worker;
GRANT EXECUTE ON FUNCTION folha.assertion_account_id() TO dnex_gestao_data_owner;

DO $$
DECLARE
  v_papel name;
BEGIN
  FOR v_papel IN
    SELECT r.rolname
      FROM pg_proc p
      CROSS JOIN LATERAL aclexplode(p.proacl) a
      JOIN pg_roles r ON r.oid = a.grantee
     WHERE p.oid = 'folha.current_account_id()'::regprocedure
       AND a.privilege_type = 'EXECUTE'
       AND r.rolname NOT IN ('anon', 'authenticated')
  LOOP
    EXECUTE format('GRANT EXECUTE ON FUNCTION folha.assertion_account_id() TO %I', v_papel);
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
  UNIQUE (account_id, establishment_id)
);
CREATE INDEX idx_establishment_employer ON folha.establishment (account_id, employer_id);

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
CREATE TABLE folha.tax_allocation (
  allocation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  establishment_id uuid NOT NULL,
  codigo_lotacao text NOT NULL CHECK (btrim(codigo_lotacao) <> ''),
  tipo_lotacao text NOT NULL,      -- código do tipo de lotação do eSocial; domínio a validar na fonte
  descricao text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT tax_allocation_establishment_fk FOREIGN KEY (account_id, establishment_id)
    REFERENCES folha.establishment (account_id, establishment_id),
  UNIQUE (account_id, establishment_id, codigo_lotacao),
  UNIQUE (account_id, allocation_id)
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
  ADD CONSTRAINT contract_establishment_fk FOREIGN KEY (account_id, establishment_id)
    REFERENCES folha.establishment (account_id, establishment_id);
CREATE INDEX idx_contract_employer ON folha.employment_contract (account_id, employer_id)
  WHERE employer_id IS NOT NULL;
CREATE INDEX idx_contract_establishment ON folha.employment_contract (account_id, establishment_id)
  WHERE establishment_id IS NOT NULL;
-- alvo da chave composta do rateio (contract_id já é único; o par também é)
CREATE UNIQUE INDEX employment_contract_account_contract_key
  ON folha.employment_contract (account_id, contract_id);

ALTER TABLE folha.payroll_run
  ADD COLUMN employer_id uuid,
  ADD COLUMN establishment_id uuid,
  ADD CONSTRAINT run_employer_fk FOREIGN KEY (account_id, employer_id)
    REFERENCES folha.employer (account_id, employer_id),
  ADD CONSTRAINT run_establishment_fk FOREIGN KEY (account_id, establishment_id)
    REFERENCES folha.establishment (account_id, establishment_id);
CREATE INDEX idx_run_employer ON folha.payroll_run (account_id, employer_id)
  WHERE employer_id IS NOT NULL;
CREATE INDEX idx_run_establishment ON folha.payroll_run (account_id, establishment_id)
  WHERE establishment_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- 5. Rateio do contrato por lotação (percentual somando 100 em cada dia coberto)
-- ---------------------------------------------------------------------------
CREATE TABLE folha.contract_tax_allocation (
  allocation_entry_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  contract_id uuid NOT NULL,
  allocation_id uuid NOT NULL,
  percentual numeric(5,2) NOT NULL CHECK (percentual > 0 AND percentual <= 100),
  vigencia_inicio date NOT NULL,
  vigencia_fim date,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT contract_tax_allocation_contract_fk FOREIGN KEY (account_id, contract_id)
    REFERENCES folha.employment_contract (account_id, contract_id),
  CONSTRAINT contract_tax_allocation_allocation_fk FOREIGN KEY (account_id, allocation_id)
    REFERENCES folha.tax_allocation (account_id, allocation_id),
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
CREATE FUNCTION folha.validar_rateio_contrato() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
DECLARE
  v_contratos uuid[];
  v_contrato uuid;
  v_dia date;
  v_soma numeric;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_contratos := ARRAY[NEW.contract_id];
  ELSIF TG_OP = 'DELETE' THEN
    v_contratos := ARRAY[OLD.contract_id];
  ELSE
    v_contratos := ARRAY[NEW.contract_id, OLD.contract_id];
  END IF;

  FOREACH v_contrato IN ARRAY v_contratos
  LOOP
    SELECT d.dia, s.soma INTO v_dia, v_soma
      FROM (
        SELECT c.vigencia_inicio AS dia
          FROM folha.contract_tax_allocation c
         WHERE c.contract_id = v_contrato
        UNION
        SELECT c.vigencia_fim + 1
          FROM folha.contract_tax_allocation c
         WHERE c.contract_id = v_contrato AND c.vigencia_fim IS NOT NULL
      ) d
      CROSS JOIN LATERAL (
        SELECT sum(c.percentual) AS soma
          FROM folha.contract_tax_allocation c
         WHERE c.contract_id = v_contrato
           AND c.vigencia_inicio <= d.dia
           AND (c.vigencia_fim IS NULL OR c.vigencia_fim >= d.dia)
      ) s
     WHERE s.soma IS NOT NULL AND s.soma <> 100
     ORDER BY d.dia
     LIMIT 1;

    IF FOUND THEN
      RAISE EXCEPTION 'Rateio do contrato % deve somar 100 em %: soma atual %',
        v_contrato, v_dia, v_soma
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
-- 7. RLS (ENABLE + FORCE), policy por conta e ACL — REVOKE ALL antes de qualquer GRANT.
--    Mesmo critério da 0014: worker lê e grava (sem DELETE); data_owner só lê.
--    payroll_parameter não entra: RLS, policies e ACL dela são os da 0023.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_tabela text;
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
         USING (account_id = folha.current_account_id())
         WITH CHECK (account_id = folha.current_account_id())',
      v_tabela || '_isolamento', v_tabela);
    EXECUTE format(
      'REVOKE ALL ON folha.%I FROM PUBLIC, anon, authenticated, service_role', v_tabela);
    EXECUTE format(
      'GRANT SELECT, INSERT, UPDATE ON folha.%I TO dnex_gestao_folha_worker', v_tabela);
    EXECUTE format(
      'GRANT SELECT ON folha.%I TO dnex_gestao_data_owner', v_tabela);
  END LOOP;
END
$$;

COMMIT;
