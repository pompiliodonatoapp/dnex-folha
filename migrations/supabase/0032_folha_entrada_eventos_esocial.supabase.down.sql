-- DNEX Folha — Reversão da migration 0032 (camada de entrada dos geradores do eSocial).
--
-- Recusa (SQLSTATE 55000) se houver linha em qualquer tabela criada pela 0032 (cadastro do eSocial,
-- demonstrativo, pagamento efetivo, registro das entradas): são dado de conta e histórico (o ideDmDev e a
-- data de pagamento efetiva não se refazem), então a reversão não os apaga em silêncio; exporte e
-- esvazie antes, como superusuário e de propósito (as tabelas de histórico recusam DELETE e TRUNCATE por
-- gatilho). A contagem roda com row_security = off para não ser enganada pela RLS; se o papel não ignorar
-- RLS, a reversão falha em vez de apagar sem ver. O catálogo de domínios (esocial_domain_code) é dado do
-- produto, semeado pela própria 0032 a partir do XSD, e sai junto: só vale a recusa se tiver linha que
-- NÃO seja a semeada (por exemplo, uma tabela carregada depois).
-- As colunas novas de tax_allocation e tax_allocation_detail são apagadas; se houver valor nelas, a
-- reversão também recusa. A auditoria (folha.auditoria) é append-only e NÃO é apagada: as linhas
-- esocial_entrada e esocial_pagamento_registrar ficam.
BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL row_security = off;

DO $$
DECLARE
  v_tabela text;
  v_tem boolean;
  v_n bigint;
BEGIN
  FOREACH v_tabela IN ARRAY ARRAY[
    'esocial_entrada', 'payroll_payment', 'payroll_demonstrative', 'contract_termination', 'contract_esocial',
    'employee_dependent', 'employee_esocial', 'rubric_esocial_config', 'establishment_esocial', 'employer_esocial']
  LOOP
    IF to_regclass('folha.' || v_tabela) IS NULL THEN
      CONTINUE;
    END IF;
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM folha.%I)', v_tabela) INTO v_tem;
    IF v_tem THEN
      RAISE EXCEPTION '0032 (reversão): folha.% tem linhas; exporte e esvazie antes de reverter', v_tabela
        USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
  END LOOP;
  IF to_regclass('folha.esocial_domain_code') IS NOT NULL THEN
    SELECT count(*) INTO v_n FROM folha.esocial_domain_code d WHERE d.tabela_numero <> 'XSD' OR d.fonte !~ '^dnex-contador@e0d3ffb ';
    IF v_n > 0 THEN
      RAISE EXCEPTION '0032 (reversão): folha.esocial_domain_code tem % linha(s) além da semeada; exporte e esvazie antes de reverter', v_n
        USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
  END IF;
  IF EXISTS (SELECT 1 FROM folha.tax_allocation
              WHERE esocial_tp_insc IS NOT NULL OR esocial_nr_insc IS NOT NULL OR info_empr_parcial IS NOT NULL OR dados_op_port IS NOT NULL)
     OR EXISTS (SELECT 1 FROM folha.tax_allocation_detail
                 WHERE cod_terceiros_suspensos IS NOT NULL OR info_proc_jud_terceiros IS NOT NULL) THEN
    RAISE EXCEPTION '0032 (reversão): há valor nas colunas novas de tax_allocation ou tax_allocation_detail; exporte e limpe antes de reverter'
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
END
$$;

DROP FUNCTION IF EXISTS folha.esocial_entrada_pagamento_registrar_v1(uuid, date, numeric, smallint);
DROP FUNCTION IF EXISTS folha.esocial_entrada_s1000_v1(uuid, date, text, timestamp, boolean);
DROP FUNCTION IF EXISTS folha.esocial_entrada_s1005_v1(uuid, date, text, timestamp, boolean);
DROP FUNCTION IF EXISTS folha.esocial_entrada_s1010_v1(uuid, uuid, date, text, timestamp, boolean);
DROP FUNCTION IF EXISTS folha.esocial_entrada_s1020_v1(uuid, date, text, timestamp, boolean);
DROP FUNCTION IF EXISTS folha.esocial_entrada_s1200_v1(uuid, uuid, smallint, date, text, timestamp, boolean, uuid, text);
DROP FUNCTION IF EXISTS folha.esocial_entrada_s1210_v1(uuid, uuid, date, text, timestamp, boolean, uuid, text);
DROP FUNCTION IF EXISTS folha.esocial_entrada_s2200_v1(uuid, uuid, text, timestamp, boolean, uuid, text);
DROP FUNCTION IF EXISTS folha.esocial_entrada_s1298_v1(uuid, smallint, date, text, timestamp, boolean);
DROP FUNCTION IF EXISTS folha.esocial_entrada_s1299_v1(uuid, smallint, date, text, timestamp, boolean);
DROP FUNCTION IF EXISTS folha.esocial_entrada_s3000_v1(uuid, text, timestamp, boolean);
DROP FUNCTION IF EXISTS folha.esocial_entrada_concluir(jsonb, uuid, text, text, jsonb, jsonb, timestamp, jsonb, jsonb, jsonb, boolean, uuid, uuid, text, jsonb, text);
DROP FUNCTION IF EXISTS folha.esocial_entrada_contexto(boolean, boolean);
DROP FUNCTION IF EXISTS folha.esocial_entrada_dominio(jsonb, text, text, text, text);
DROP FUNCTION IF EXISTS folha.esocial_entrada_pende(jsonb, text, text);
DROP FUNCTION IF EXISTS folha.esocial_entrada_bloqueia(jsonb, text, text);
DROP FUNCTION IF EXISTS folha.esocial_entrada_exige(jsonb, text, text, text);
DROP FUNCTION IF EXISTS folha.esocial_entrada_falta(jsonb, text, text);
DROP FUNCTION IF EXISTS folha.esocial_entrada_acc();
DROP FUNCTION IF EXISTS folha.esocial_entrada_dec(numeric);
DROP FUNCTION IF EXISTS folha.esocial_entrada_data(date);
DROP FUNCTION IF EXISTS folha.esocial_entrada_sn(boolean);
DROP FUNCTION IF EXISTS folha.esocial_entrada_empregador(folha.employer);
DROP FUNCTION IF EXISTS folha.esocial_entrada_tpinsc_estab(text);

DROP TABLE IF EXISTS folha.esocial_entrada;
DROP TABLE IF EXISTS folha.payroll_payment;
DROP TABLE IF EXISTS folha.payroll_demonstrative;
DROP TABLE IF EXISTS folha.contract_termination;
DROP TABLE IF EXISTS folha.contract_esocial;
DROP TABLE IF EXISTS folha.employee_dependent;
DROP TABLE IF EXISTS folha.employee_esocial;
DROP TABLE IF EXISTS folha.rubric_esocial_config;
DROP TABLE IF EXISTS folha.establishment_esocial;
DROP TABLE IF EXISTS folha.employer_esocial;

DROP FUNCTION IF EXISTS folha.esocial_dominio_guarda();
DROP TABLE IF EXISTS folha.esocial_domain_code;
DROP FUNCTION IF EXISTS folha.esocial_dominio_situacao(text, text);

ALTER TABLE folha.tax_allocation_detail
  DROP COLUMN IF EXISTS cod_terceiros_suspensos,
  DROP COLUMN IF EXISTS info_proc_jud_terceiros;
ALTER TABLE folha.tax_allocation
  DROP CONSTRAINT IF EXISTS tax_allocation_insc_coerente,
  DROP COLUMN IF EXISTS esocial_tp_insc,
  DROP COLUMN IF EXISTS esocial_nr_insc,
  DROP COLUMN IF EXISTS info_empr_parcial,
  DROP COLUMN IF EXISTS dados_op_port;

COMMIT;
