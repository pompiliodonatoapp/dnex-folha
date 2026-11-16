-- DNEX Folha — Reversão da migration 0030 (contabilização com partida fechada e provisões).
--
-- AVISO: esta reversão devolve build_contabil_folha, dispatch_accounting_event e
-- dispatch_folha_completa aos corpos da 0028 (um evento contábil por resultado, em reais, com
-- contas fixas no código, sem conferir a partida) e a visão de reconciliação à definição da
-- 0018 (somas multiplicadas pelo join; roda como o dono e ignora RLS). Use só para desfazer
-- uma aplicação que deu errado, e reaplique a 0030 corrigida em seguida. Não é um estado para
-- operar.
--
-- Recusa (SQLSTATE 55000) se houver lote v2 no outbox, mapeamento, configuração, pendência,
-- direito informado ou movimento no razão de provisões: os dados teriam de ser exportados
-- antes (o outbox e o razão recusam DELETE por gatilho: esvaziá-los exige desligar os
-- gatilhos, como superusuário, de propósito). A contagem roda com row_security = off para
-- não ser enganada pela RLS; se o papel não ignorar RLS, a reversão falha em vez de apagar
-- sem ver.
-- Os corpos restaurados são cópia dos da migration 0028; a visão, da 0018.
BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL row_security = off;

DO $$
DECLARE
  v_tabela text;
  v_tem boolean;
BEGIN
  IF EXISTS (SELECT 1 FROM folha.accounting_outbox WHERE formato = 'v2') THEN
    RAISE EXCEPTION '0030 (reversão): folha.accounting_outbox tem lotes v2; exporte e apague os dados antes de reverter'
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  FOREACH v_tabela IN ARRAY ARRAY[
    'provision_ledger', 'provision_entitlement', 'contabil_pendencia', 'contabil_mapa', 'contabil_config',
    'contract_cost_assignment']
  LOOP
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM folha.%I)', v_tabela) INTO v_tem;
    IF v_tem THEN
      RAISE EXCEPTION '0030 (reversão): folha.% tem linhas; exporte e apague os dados antes de reverter', v_tabela
        USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
  END LOOP;
END
$$;

-- ---------------------------------------------------------------------------
-- 1. Funções substituídas: corpos da 0028 (CREATE OR REPLACE preserva dono e ACL)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION folha.dispatch_accounting_event(
  p_run_id uuid,
  p_result_id uuid,
  p_evento_tipo text,
  p_payload jsonb
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, folha, pg_temp
AS $$
DECLARE
  v_conta uuid;
  v_account_id uuid;
  v_idem_key text;
  v_outbox_id bigint;
BEGIN
  SELECT c.account_id INTO v_conta FROM folha.contexto_v1('folha.transmit') AS c;

  SELECT account_id INTO v_account_id
    FROM folha.payroll_result
   WHERE result_id = p_result_id AND run_id = p_run_id AND account_id = v_conta;

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

CREATE OR REPLACE FUNCTION folha.build_contabil_folha(
  p_result_id uuid
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha, pg_temp
AS $$
DECLARE
  v_conta uuid;
  v_result record;
  v_lancamentos jsonb := '[]'::jsonb;
BEGIN
  SELECT c.account_id INTO v_conta FROM folha.contexto_v1('folha.transmit') AS c;

  SELECT pr.*, r.competencia INTO v_result
  FROM folha.payroll_result pr
  JOIN folha.payroll_run r ON r.run_id = pr.run_id AND r.account_id = pr.account_id
  WHERE pr.result_id = p_result_id AND pr.account_id = v_conta;

  IF v_result.result_id IS NULL THEN
    RAISE EXCEPTION 'payroll_result % não encontrado', p_result_id;
  END IF;

  -- Débito: Despesa com salários (proventos)
  v_lancamentos := v_lancamentos || jsonb_build_array(jsonb_build_object(
    'conta_debito', '3.2.1.01.001',
    'conta_credito', NULL,
    'valor', v_result.total_proventos,
    'historico', 'Folha pagamento competência ' || to_char(v_result.competencia, 'YYYY-MM-DD'),
    'tipo', 'despesa_salario'
  ));

  -- Crédito: Salários a pagar (líquido)
  v_lancamentos := v_lancamentos || jsonb_build_array(jsonb_build_object(
    'conta_debito', NULL,
    'conta_credito', '2.1.5.01.001',
    'valor', v_result.liquido,
    'historico', 'Salários a pagar competência ' || to_char(v_result.competencia, 'YYYY-MM-DD'),
    'tipo', 'passivo_salario'
  ));

  -- Crédito: INSS empregado a recolher
  IF v_result.inss_empregado > 0 THEN
    v_lancamentos := v_lancamentos || jsonb_build_array(jsonb_build_object(
      'conta_debito', NULL,
      'conta_credito', '2.1.5.02.001',
      'valor', v_result.inss_empregado,
      'historico', 'INSS empregado a recolher ' || to_char(v_result.competencia, 'YYYY-MM-DD'),
      'tipo', 'passivo_inss_empregado'
    ));
  END IF;

  -- Crédito: IRRF a recolher
  IF v_result.irrf > 0 THEN
    v_lancamentos := v_lancamentos || jsonb_build_array(jsonb_build_object(
      'conta_debito', NULL,
      'conta_credito', '2.1.5.03.001',
      'valor', v_result.irrf,
      'historico', 'IRRF a recolher ' || to_char(v_result.competencia, 'YYYY-MM-DD'),
      'tipo', 'passivo_irrf'
    ));
  END IF;

  -- Débito: FGTS encargo patronal (informativo, não desconta empregado)
  IF v_result.fgts > 0 THEN
    v_lancamentos := v_lancamentos || jsonb_build_array(jsonb_build_object(
      'conta_debito', '3.2.1.02.001',
      'conta_credito', '2.1.5.04.001',
      'valor', v_result.fgts,
      'historico', 'FGTS a depositar ' || to_char(v_result.competencia, 'YYYY-MM-DD'),
      'tipo', 'encargo_fgts'
    ));
  END IF;

  RETURN jsonb_build_object(
    'result_id', p_result_id,
    'competencia', v_result.competencia,
    'lancamentos', v_lancamentos,
    'total_debitos', v_result.total_proventos + COALESCE(v_result.fgts, 0),
    'total_creditos', v_result.liquido + v_result.inss_empregado + v_result.irrf + COALESCE(v_result.fgts, 0),
    'balanceado', (v_result.total_proventos + COALESCE(v_result.fgts, 0)) =
                   (v_result.liquido + v_result.inss_empregado + v_result.irrf + COALESCE(v_result.fgts, 0)),
    'gerado_em', now()
  );
END;
$$;

CREATE OR REPLACE FUNCTION folha.dispatch_folha_completa(
  p_run_id uuid
) RETURNS TABLE (
  esocial_events_dispatched integer,
  contabil_events_dispatched integer
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, folha, pg_temp
AS $$
DECLARE
  v_ctx record;
  v_result record;
  v_esocial_count integer := 0;
  v_contabil_count integer := 0;
  v_competencia date;
  v_status text;
  v_abertas integer;
BEGIN
  SELECT c.account_id, c.legal_entity_id, c.branch_id, c.subject_id INTO v_ctx
    FROM folha.contexto_v1('folha.transmit') AS c;

  SELECT competencia, status INTO v_competencia, v_status
  FROM folha.payroll_run
  WHERE run_id = p_run_id AND account_id = v_ctx.account_id;

  IF v_competencia IS NULL THEN
    RAISE EXCEPTION 'payroll_run % não encontrado', p_run_id;
  END IF;
  IF v_status <> 'closed' THEN
    RAISE EXCEPTION 'Folha % está em % e não pode ser despachada: só folha fechada gera eventos', p_run_id, v_status;
  END IF;
  SELECT count(*) INTO v_abertas
    FROM folha.payroll_pendency p
   WHERE p.run_id = p_run_id AND p.account_id = v_ctx.account_id AND p.liberada_em IS NULL;
  IF v_abertas > 0 THEN
    RAISE EXCEPTION 'Folha % tem % pendência(s) sem liberação e não pode ser despachada', p_run_id, v_abertas;
  END IF;

  FOR v_result IN
    SELECT result_id FROM folha.payroll_result WHERE run_id = p_run_id AND account_id = v_ctx.account_id
  LOOP
    -- Dispatch eSocial S-1200
    -- 0028: conta só o que de fato entrou na fila (repetir o despacho não insere de novo).
    IF folha.dispatch_esocial_event(
         p_run_id,
         v_result.result_id,
         'S-1200',
         v_competencia,
         folha.build_esocial_s1200(v_result.result_id),
         NULL
       ) IS NOT NULL THEN
      v_esocial_count := v_esocial_count + 1;
    END IF;

    -- Dispatch contábil
    IF folha.dispatch_accounting_event(
         p_run_id,
         v_result.result_id,
         'folha_mensal',
         folha.build_contabil_folha(v_result.result_id)
       ) IS NOT NULL THEN
      v_contabil_count := v_contabil_count + 1;
    END IF;
  END LOOP;

  INSERT INTO folha.auditoria (account_id, actor, actor_subject, acao, recurso, recurso_id, detalhe)
  VALUES (v_ctx.account_id, v_ctx.subject_id::text, v_ctx.subject_id, 'transmitir_folha', 'payroll_run', p_run_id,
          jsonb_build_object('sessao', session_user, 'esocial', v_esocial_count, 'contabil', v_contabil_count,
                             'legal_entity_id', v_ctx.legal_entity_id, 'branch_id', v_ctx.branch_id));

  esocial_events_dispatched := v_esocial_count;
  contabil_events_dispatched := v_contabil_count;
  RETURN NEXT;
END;
$$;

-- ---------------------------------------------------------------------------
-- 2. Visão de reconciliação: definição e ACL da 0018 (CREATE OR REPLACE não tira coluna)
-- ---------------------------------------------------------------------------
DROP VIEW folha.v_reconciliacao_contabil;
CREATE VIEW folha.v_reconciliacao_contabil AS
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

REVOKE ALL ON folha.v_reconciliacao_contabil FROM PUBLIC, anon, authenticated, service_role;
GRANT SELECT ON folha.v_reconciliacao_contabil TO dnex_gestao_folha_worker;
GRANT SELECT ON folha.v_reconciliacao_contabil TO dnex_gestao_data_owner;

-- ---------------------------------------------------------------------------
-- 3. Funções da sessão de aplicação e internas
-- ---------------------------------------------------------------------------
DROP FUNCTION folha.contabil_situacao_v1(uuid);
DROP FUNCTION folha.contabil_pendencia_liberar_v1(uuid, text);
DROP FUNCTION folha.contabil_pagamento_registrar_v1(uuid, text, date, text, bigint, jsonb, uuid);
DROP FUNCTION folha.contabil_provisao_constituir_v1(uuid, date);
DROP FUNCTION folha.contabil_provisao_direito_informar_v1(uuid, date, numeric, numeric, numeric);
DROP FUNCTION folha.contabil_folha_contabilizar_v1(uuid);
DROP FUNCTION folha.contabil_contrato_dimensao_definir_v1(uuid, text, text, date);
DROP FUNCTION folha.contabil_mapa_encerrar_v1(uuid, date, boolean);
DROP FUNCTION folha.contabil_mapa_definir_v1(uuid, text, text, text, text, date, boolean, date, text, uuid, uuid, text, text, text, text);
DROP FUNCTION folha.contabil_config_definir_v1(uuid, text, text, boolean);

DROP FUNCTION folha.contabil_passivo_saldos(uuid, uuid);
DROP FUNCTION folha.contabil_folha_executar(uuid, uuid, uuid);
DROP FUNCTION folha.contabil_bloqueio_registrar(uuid, uuid, jsonb);
DROP FUNCTION folha.contabil_lote_publicar(uuid, uuid, jsonb);
DROP FUNCTION folha.contabil_razao_reverter(uuid, uuid, bigint, bigint);
DROP FUNCTION folha.contabil_provisao_montar(uuid, uuid, date, text, bigint);
DROP FUNCTION folha.contabil_folha_montar(uuid, uuid, uuid, text, bigint);
DROP FUNCTION folha.contabil_folha_conferir_estado(uuid, uuid);
DROP FUNCTION folha.contabil_envelope(uuid, jsonb, integer, text, jsonb, jsonb);
DROP FUNCTION folha.contabil_lote_compor(uuid, uuid, date, text, date, text, jsonb, jsonb, text[]);
DROP FUNCTION folha.contabil_linhas_resolver(uuid, uuid, date, text, text, uuid, jsonb);
DROP FUNCTION folha.contabil_provisao_saldo(uuid, uuid, text, text, date, bigint);
DROP FUNCTION folha.contabil_chave_provisao(text, text);
DROP FUNCTION folha.contabil_evento_da_folha(text);

-- ---------------------------------------------------------------------------
-- 4. Provisões e pendências (gatilhos e policies caem com as tabelas)
-- ---------------------------------------------------------------------------
DROP TABLE folha.provision_ledger;
DROP TABLE folha.provision_entitlement;
DROP TABLE folha.provision_movement_type;
DROP TABLE folha.contabil_pendencia;
DROP FUNCTION folha.provision_ledger_trava();

-- ---------------------------------------------------------------------------
-- 5. Outbox contábil: volta à forma da 0018
-- ---------------------------------------------------------------------------
DROP TRIGGER trg_accounting_outbox_guarda ON folha.accounting_outbox;
DROP TRIGGER trg_accounting_outbox_imutavel ON folha.accounting_outbox;
DROP TRIGGER trg_accounting_outbox_sem_truncate ON folha.accounting_outbox;
DROP FUNCTION folha.contabil_sem_truncate();
DROP FUNCTION folha.accounting_outbox_guarda();
DROP FUNCTION folha.accounting_outbox_imutavel();
DROP FUNCTION folha.contabil_payload_hash(jsonb);

DROP INDEX folha.accounting_outbox_vigente_folha_key;
DROP INDEX folha.accounting_outbox_vigente_provisao_key;
DROP INDEX folha.accounting_outbox_versao_folha_key;
DROP INDEX folha.accounting_outbox_versao_provisao_key;
DROP INDEX folha.accounting_outbox_estorna_key;
DROP INDEX folha.accounting_outbox_comprovante_key;
DROP INDEX folha.idx_accounting_outbox_run;

ALTER TABLE folha.accounting_outbox
  DROP CONSTRAINT accounting_outbox_estorna_fk,
  DROP CONSTRAINT accounting_outbox_run_conta_fk,
  DROP CONSTRAINT accounting_outbox_employer_fk,
  DROP CONSTRAINT accounting_outbox_cancelamento_coerente,
  DROP CONSTRAINT accounting_outbox_provisao_sem_folha,
  DROP CONSTRAINT accounting_outbox_pagamento_com_comprovante,
  DROP CONSTRAINT accounting_outbox_estorno_coerente,
  DROP CONSTRAINT accounting_outbox_legado_inalterado,
  DROP CONSTRAINT accounting_outbox_v2_completo,
  DROP CONSTRAINT accounting_outbox_lote_balanceado,
  DROP CONSTRAINT accounting_outbox_status_check,
  DROP CONSTRAINT accounting_outbox_evento_tipo_check;
DROP INDEX folha.accounting_outbox_account_outbox_key;

ALTER TABLE folha.accounting_outbox
  DROP COLUMN cancelado_motivo,
  DROP COLUMN cancelado_em,
  DROP COLUMN contabilizado_por_subject,
  DROP COLUMN comprovante_ref,
  DROP COLUMN composicao,
  DROP COLUMN vigente,
  DROP COLUMN estorna_outbox_id,
  DROP COLUMN total_credito_minor,
  DROP COLUMN total_debito_minor,
  DROP COLUMN payload_hash,
  DROP COLUMN data_lancamento,
  DROP COLUMN versao,
  DROP COLUMN competencia,
  DROP COLUMN employer_id,
  DROP COLUMN formato;

ALTER TABLE folha.accounting_outbox
  ALTER COLUMN run_id SET NOT NULL,
  ALTER COLUMN result_id SET NOT NULL,
  ADD CONSTRAINT accounting_outbox_evento_tipo_check CHECK (evento_tipo IN (
    'provisao_ferias', 'provisao_13o', 'encargos_patronais',
    'folha_mensal', 'rescisao', 'fgts_deposito'
  )),
  ADD CONSTRAINT accounting_outbox_status_check
    CHECK (status IN ('pendente', 'despachado', 'confirmado', 'rejeitado'));

GRANT INSERT ON folha.accounting_outbox TO dnex_gestao_folha_worker;

-- ---------------------------------------------------------------------------
-- 6. Mapeamento
-- ---------------------------------------------------------------------------
DROP TABLE folha.contract_cost_assignment;
DROP TABLE folha.contabil_mapa;
DROP TABLE folha.contabil_config;
DROP TABLE folha.contabil_chave;
DROP TABLE folha.contabil_papel;
DROP FUNCTION folha.contabil_mapa_trava();

-- ---------------------------------------------------------------------------
-- 7. Parâmetros
-- ---------------------------------------------------------------------------
DELETE FROM folha.payroll_parameter
 WHERE chave IN ('contabil_provisao_encargos_incide_terco_ferias', 'contabil_rescisao_baixa_provisao_encargos');

COMMIT;
