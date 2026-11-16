-- DNEX Folha — Reversão da migration 0031 (fila de eventos do eSocial no banco).
--
-- Recusa (SQLSTATE 55000) se houver linha em qualquer tabela da fila (evento, lote, XML e retornos,
-- ocorrência, origem, participação em lote, liberação de produção ou catálogo de rejeições): o
-- histórico de envio e os recibos não se perdem em silêncio; exporte e esvazie antes, como
-- superusuário e de propósito (as tabelas recusam DELETE e TRUNCATE por gatilho). A contagem roda
-- com row_security = off para não ser enganada pela RLS; se o papel não ignorar RLS, a reversão
-- falha em vez de apagar sem ver. O catálogo de eventos, os antecessores, os estados e as
-- transições são dado do produto (semeados pela própria 0031) e saem junto.
-- A auditoria (folha.auditoria) é append-only e NÃO é apagada: as linhas esocial_* ficam.
BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL row_security = off;

DO $$
DECLARE
  v_tabela text;
  v_tem boolean;
BEGIN
  FOREACH v_tabela IN ARRAY ARRAY[
    'esocial_event_occurrence', 'esocial_event_payload', 'esocial_lot_event', 'esocial_event_origin',
    'esocial_event', 'esocial_lot', 'esocial_employer_setting', 'esocial_rejection_catalog']
  LOOP
    IF to_regclass('folha.' || v_tabela) IS NULL THEN
      CONTINUE;
    END IF;
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM folha.%I)', v_tabela) INTO v_tem;
    IF v_tem THEN
      RAISE EXCEPTION '0031 (reversão): folha.% tem linhas; exporte e esvazie antes de reverter', v_tabela
        USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
  END LOOP;
END
$$;

DROP VIEW IF EXISTS folha.v_esocial_conferencia;

DROP FUNCTION IF EXISTS folha.esocial_producao_definir_v1(uuid, boolean, text);
DROP FUNCTION IF EXISTS folha.esocial_evento_enfileirar_v1(uuid, text, text, text, jsonb, jsonb);
DROP FUNCTION IF EXISTS folha.esocial_evento_avancar_v1(uuid, text, text);
DROP FUNCTION IF EXISTS folha.esocial_evento_cancelar_v1(uuid, text);
DROP FUNCTION IF EXISTS folha.esocial_lote_enviar_v1(uuid, text, uuid[]);
DROP FUNCTION IF EXISTS folha.esocial_lote_retorno_v1(uuid, text, text, text, text, jsonb, jsonb);
DROP FUNCTION IF EXISTS folha.esocial_evento_retificar_v1(uuid, text, text, jsonb);
DROP FUNCTION IF EXISTS folha.esocial_evento_excluir_v1(uuid, text);
DROP FUNCTION IF EXISTS folha.esocial_desfazer_plano_v1(uuid, text, date, smallint, uuid);
DROP FUNCTION IF EXISTS folha.esocial_conferencia_v1(uuid, date, text);
DROP FUNCTION IF EXISTS folha.esocial_evento_incluir(uuid, uuid, text, text, jsonb, text, jsonb, uuid, uuid, text);
DROP FUNCTION IF EXISTS folha.esocial_ocorrencias_gravar(uuid, uuid, uuid, text, jsonb);
DROP FUNCTION IF EXISTS folha.esocial_bloqueio_antecessor(uuid);
DROP FUNCTION IF EXISTS folha.esocial_dependentes(uuid, boolean);
DROP FUNCTION IF EXISTS folha.esocial_depende(folha.esocial_event, folha.esocial_event);
DROP FUNCTION IF EXISTS folha.esocial_antecessores_faltando(uuid, uuid);
DROP FUNCTION IF EXISTS folha.esocial_origem_conferir(folha.esocial_event);
DROP FUNCTION IF EXISTS folha.esocial_ref_chave(folha.esocial_event);
DROP FUNCTION IF EXISTS folha.esocial_periodo_fechado(uuid, uuid, text, smallint, date);
DROP FUNCTION IF EXISTS folha.esocial_escopo_casa(text, folha.esocial_event, folha.esocial_event);
DROP FUNCTION IF EXISTS folha.esocial_chave_texto(text, text, date, uuid, uuid, date, smallint, date, integer, uuid);
DROP FUNCTION IF EXISTS folha.esocial_auditar(jsonb, text, text, uuid, jsonb);

DROP TABLE IF EXISTS folha.esocial_event_occurrence;
DROP TABLE IF EXISTS folha.esocial_event_payload;
DROP TABLE IF EXISTS folha.esocial_lot_event;
DROP TABLE IF EXISTS folha.esocial_event_origin;
DROP TABLE IF EXISTS folha.esocial_event;
DROP TABLE IF EXISTS folha.esocial_lot;
DROP TABLE IF EXISTS folha.esocial_employer_setting;
DROP TABLE IF EXISTS folha.esocial_rejection_catalog;
DROP TABLE IF EXISTS folha.esocial_event_antecessor;
DROP TABLE IF EXISTS folha.esocial_event_transition;
DROP TABLE IF EXISTS folha.esocial_event_state;
DROP TABLE IF EXISTS folha.esocial_event_catalog;

DROP FUNCTION IF EXISTS folha.esocial_imutavel();
DROP FUNCTION IF EXISTS folha.esocial_sem_truncate();
DROP FUNCTION IF EXISTS folha.esocial_setting_guarda();
DROP FUNCTION IF EXISTS folha.esocial_event_guarda();
DROP FUNCTION IF EXISTS folha.esocial_lot_guarda();
DROP FUNCTION IF EXISTS folha.esocial_lot_event_guarda();
DROP FUNCTION IF EXISTS folha.esocial_payload_guarda();
DROP FUNCTION IF EXISTS folha.esocial_occurrence_guarda();
DROP FUNCTION IF EXISTS folha.esocial_origin_guarda();

COMMIT;
