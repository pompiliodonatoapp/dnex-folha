-- DNEX Folha — Integração com accounting-kernel e esocial-reinf-orchestrator.
-- Cria tabelas de outbox para eventos contábeis e fiscais, funções de despacho
-- idempotente e views de reconciliação. Não implementa a transmissão ou o
-- lançamento contábil em si (responsabilidade das skills irmãs).
-- Rollback: DROP TABLE folha.accounting_outbox, folha.esocial_event_outbox;
BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Outbox contábil (post_to_ledger via accounting-kernel)
-- ---------------------------------------------------------------------------
CREATE TABLE folha.accounting_outbox (
  outbox_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  account_id uuid NOT NULL,
  run_id uuid NOT NULL REFERENCES folha.payroll_run(run_id),
  result_id uuid NOT NULL REFERENCES folha.payroll_result(result_id),
  evento_tipo text NOT NULL CHECK (evento_tipo IN (
    'provisao_ferias', 'provisao_13o', 'encargos_patronais',
    'folha_mensal', 'rescisao', 'fgts_deposito'
  )),
  payload jsonb NOT NULL,
  status text NOT NULL DEFAULT 'pendente' CHECK (status IN ('pendente', 'despachado', 'confirmado', 'rejeitado')),
  idempotency_key text NOT NULL,
  correlation_id uuid NOT NULL DEFAULT gen_random_uuid(),
  criado_em timestamptz NOT NULL DEFAULT now(),
  despachado_em timestamptz,
  confirmado_em timestamptz,
  erro_json jsonb,
  UNIQUE (account_id, evento_tipo, idempotency_key)
);

ALTER TABLE folha.accounting_outbox ENABLE ROW LEVEL SECURITY;
ALTER TABLE folha.accounting_outbox FORCE ROW LEVEL SECURITY;
CREATE POLICY accounting_outbox_isolamento ON folha.accounting_outbox
  USING (account_id = folha.current_account_id())
  WITH CHECK (account_id = folha.current_account_id());

REVOKE ALL ON folha.accounting_outbox FROM PUBLIC, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE ON folha.accounting_outbox TO dnex_gestao_folha_worker;
GRANT SELECT ON folha.accounting_outbox TO dnex_gestao_data_owner;

-- ---------------------------------------------------------------------------
-- 2. Outbox eSocial/Reinf (build_compliance_events via esocial-reinf-orchestrator)
-- ---------------------------------------------------------------------------
CREATE TABLE folha.esocial_event_outbox (
  outbox_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  account_id uuid NOT NULL,
  run_id uuid NOT NULL REFERENCES folha.payroll_run(run_id),
  result_id uuid REFERENCES folha.payroll_result(result_id),
  evento_codigo text NOT NULL CHECK (evento_codigo IN (
    'S-1200', 'S-1210', 'S-1299', 'S-2200', 'S-2299',
    'R-2010', 'R-2099', 'R-4010', 'R-4099'
  )),
  competencia date NOT NULL,
  payload jsonb NOT NULL,
  status text NOT NULL DEFAULT 'pendente' CHECK (status IN ('pendente', 'despachado', 'transmitido', 'rejeitado', 'retificado')),
  recibo_numero text,
  protocolo text,
  idempotency_key text NOT NULL,
  correlation_id uuid NOT NULL DEFAULT gen_random_uuid(),
  cofre_certificate_ref uuid,
  criado_em timestamptz NOT NULL DEFAULT now(),
  despachado_em timestamptz,
  transmitido_em timestamptz,
  erro_json jsonb,
  UNIQUE (account_id, evento_codigo, competencia, idempotency_key)
);

ALTER TABLE folha.esocial_event_outbox ENABLE ROW LEVEL SECURITY;
ALTER TABLE folha.esocial_event_outbox FORCE ROW LEVEL SECURITY;
CREATE POLICY esocial_outbox_isolamento ON folha.esocial_event_outbox
  USING (account_id = folha.current_account_id())
  WITH CHECK (account_id = folha.current_account_id());

REVOKE ALL ON folha.esocial_event_outbox FROM PUBLIC, authenticated, service_role;
GRANT SELECT, INSERT, UPDATE ON folha.esocial_event_outbox TO dnex_gestao_folha_worker;
GRANT SELECT ON folha.esocial_event_outbox TO dnex_gestao_data_owner;

-- ---------------------------------------------------------------------------
-- 3. Função de despacho contábil idempotente
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION folha.dispatch_accounting_event(
  p_run_id uuid,
  p_result_id uuid,
  p_evento_tipo text,
  p_payload jsonb
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_account_id uuid;
  v_idem_key text;
  v_outbox_id bigint;
BEGIN
  SELECT account_id INTO v_account_id
    FROM folha.payroll_result
   WHERE result_id = p_result_id AND run_id = p_run_id;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'payroll_result % não encontrado no run %', p_result_id, p_run_id;
  END IF;

  v_idem_key := p_run_id::text || '|' || p_result_id::text || '|' || p_evento_tipo;

  INSERT INTO folha.accounting_outbox (
    account_id, run_id, result_id, evento_tipo, payload, idempotency_key
  ) VALUES (
    v_account_id, p_run_id, p_result_id, p_evento_tipo, p_payload, v_idem_key
  )
  ON CONFLICT (account_id, evento_tipo, idempotency_key) DO NOTHING
  RETURNING outbox_id INTO v_outbox_id;

  RETURN v_outbox_id;
END;
$$;

REVOKE ALL ON FUNCTION folha.dispatch_accounting_event(uuid, uuid, text, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION folha.dispatch_accounting_event(uuid, uuid, text, jsonb) TO dnex_gestao_folha_worker;

-- ---------------------------------------------------------------------------
-- 4. Função de despacho eSocial idempotente
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION folha.dispatch_esocial_event(
  p_run_id uuid,
  p_result_id uuid,
  p_evento_codigo text,
  p_competencia date,
  p_payload jsonb,
  p_cofre_cert_ref uuid DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_account_id uuid;
  v_idem_key text;
  v_outbox_id bigint;
BEGIN
  SELECT account_id INTO v_account_id
    FROM folha.payroll_run
   WHERE run_id = p_run_id;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'payroll_run % não encontrado', p_run_id;
  END IF;

  v_idem_key := p_run_id::text || '|' || COALESCE(p_result_id::text, 'run') || '|' || p_evento_codigo || '|' || p_competencia::text;

  INSERT INTO folha.esocial_event_outbox (
    account_id, run_id, result_id, evento_codigo, competencia,
    payload, idempotency_key, cofre_certificate_ref
  ) VALUES (
    v_account_id, p_run_id, p_result_id, p_evento_codigo, p_competencia,
    p_payload, v_idem_key, p_cofre_cert_ref
  )
  ON CONFLICT (account_id, evento_codigo, competencia, idempotency_key) DO NOTHING
  RETURNING outbox_id INTO v_outbox_id;

  RETURN v_outbox_id;
END;
$$;

REVOKE ALL ON FUNCTION folha.dispatch_esocial_event(uuid, uuid, text, date, jsonb, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION folha.dispatch_esocial_event(uuid, uuid, text, date, jsonb, uuid) TO dnex_gestao_folha_worker;

-- ---------------------------------------------------------------------------
-- 5. View de reconciliação folha × contábil
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW folha.v_reconciliacao_contabil AS
SELECT
  r.run_id,
  r.competencia,
  r.account_id,
  COUNT(DISTINCT pr.result_id) AS total_empregados,
  SUM(pr.total_proventos) AS soma_proventos,
  SUM(pr.total_descontos) AS soma_descontos,
  SUM(pr.liquido) AS soma_liquido,
  SUM(pr.inss_patronal) AS soma_inss_patronal,
  SUM(pr.fgts) AS soma_fgts,
  COUNT(DISTINCT ao.outbox_id) FILTER (WHERE ao.status = 'confirmado') AS eventos_contabeis_confirmados,
  COUNT(DISTINCT ao.outbox_id) FILTER (WHERE ao.status = 'pendente') AS eventos_contabeis_pendentes,
  COUNT(DISTINCT eo.outbox_id) FILTER (WHERE eo.status = 'transmitido') AS eventos_esocial_transmitidos,
  COUNT(DISTINCT eo.outbox_id) FILTER (WHERE eo.status = 'pendente') AS eventos_esocial_pendentes
FROM folha.payroll_run r
LEFT JOIN folha.payroll_result pr ON pr.run_id = r.run_id
LEFT JOIN folha.accounting_outbox ao ON ao.run_id = r.run_id
LEFT JOIN folha.esocial_event_outbox eo ON eo.run_id = r.run_id
GROUP BY r.run_id, r.competencia, r.account_id;

REVOKE ALL ON folha.v_reconciliacao_contabil FROM PUBLIC;
GRANT SELECT ON folha.v_reconciliacao_contabil TO dnex_gestao_folha_worker;
GRANT SELECT ON folha.v_reconciliacao_contabil TO dnex_gestao_data_owner;

COMMIT;