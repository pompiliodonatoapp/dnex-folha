-- DNEX Folha — Reversão da migration 0024.
--
-- AVISO: esta reversão devolve folha.current_account_id() ao corpo da migration 0014, que
-- é a versão com os dois defeitos corrigidos pela 0024 (aceita o parâmetro de sessão
-- folha.account_id de qualquer sessão e lê a asserção pelo assertion_id não consumido).
-- Use só para desfazer uma aplicação que deu errado, e reaplique a 0024 corrigida em
-- seguida. Não é um estado para operar.
--
-- Recusa (SQLSTATE 55000) se alguma tabela do empregador tiver linha: os dados teriam de
-- ser exportados antes. A contagem roda com row_security = off para não ser enganada pela
-- RLS; se o papel não ignorar RLS, a reversão falha em vez de apagar sem ver.
-- A extensão btree_gist é mantida (outros objetos do banco podem usá-la).
BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL row_security = off;

DO $$
DECLARE
  v_tabela text;
  v_tem boolean;
BEGIN
  FOREACH v_tabela IN ARRAY ARRAY[
    'contract_tax_allocation', 'tax_allocation_detail', 'tax_allocation',
    'establishment_fap', 'establishment', 'employer_regime', 'employer'
  ]
  LOOP
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM folha.%I)', v_tabela) INTO v_tem;
    IF v_tem THEN
      RAISE EXCEPTION '0024 (reversão): folha.% tem linhas; exporte e apague os dados antes de reverter', v_tabela
        USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
  END LOOP;

  IF EXISTS (SELECT 1 FROM folha.employee WHERE employer_id IS NOT NULL)
     OR EXISTS (SELECT 1 FROM folha.employment_contract WHERE employer_id IS NOT NULL OR establishment_id IS NOT NULL)
     OR EXISTS (SELECT 1 FROM folha.payroll_run WHERE employer_id IS NOT NULL OR establishment_id IS NOT NULL)
  THEN
    RAISE EXCEPTION '0024 (reversão): há trabalhador, contrato ou folha vinculado a empregador'
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
END
$$;

-- Tabelas do empregador (o trigger e as policies vão junto)
DROP TABLE folha.contract_tax_allocation;
DROP FUNCTION folha.validar_rateio_contrato();
DROP TABLE folha.tax_allocation_detail;
DROP TABLE folha.tax_allocation;
DROP TABLE folha.establishment_fap;
DROP TABLE folha.employer_regime;

-- Colunas de vínculo (chaves estrangeiras, CHECKs e índices das colunas vão junto)
ALTER TABLE folha.payroll_run
  DROP COLUMN establishment_id,
  DROP COLUMN employer_id;
ALTER TABLE folha.employment_contract
  DROP COLUMN establishment_id,
  DROP COLUMN employer_id;
ALTER TABLE folha.employee
  DROP COLUMN employer_id;

DROP TABLE folha.establishment;
DROP TABLE folha.employer;

-- Catálogo de parâmetros da 0023: volta a ter só UNIQUE (chave, vigencia_inicio)
ALTER TABLE folha.payroll_parameter
  DROP CONSTRAINT payroll_parameter_sem_sobreposicao,
  DROP CONSTRAINT payroll_parameter_vigencia_valida;

-- Conta da sessão: corpo e GRANTs da 0014 (0014:32-49)
CREATE OR REPLACE FUNCTION folha.current_account_id() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, gestao_auth
AS $$
  SELECT COALESCE(
    (SELECT account_id FROM gestao_auth.access_assertion
      WHERE assertion_id = NULLIF(current_setting('dnex.context_nonce', true), '')::uuid
        AND consumed_at IS NULL
        AND revoked_at IS NULL
        AND expires_at > now()
      LIMIT 1),
    NULLIF(current_setting('folha.account_id', true), '')::uuid
  );
$$;

REVOKE ALL ON FUNCTION folha.current_account_id() FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION folha.current_account_id() TO dnex_gestao_folha_worker;
GRANT EXECUTE ON FUNCTION folha.current_account_id() TO dnex_gestao_data_owner;

DROP FUNCTION folha.request_context_account_id();

COMMIT;
