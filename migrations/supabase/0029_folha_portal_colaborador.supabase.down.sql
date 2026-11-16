-- DNEX Folha — Reversão da migration 0029 (banco do Portal do Colaborador v1).
--
-- Recusa (SQLSTATE 55000) se alguma das quatro tabelas tiver linha: habilitações, documentos
-- publicados, registros de acesso e aceites teriam de ser exportados antes (os arquivos no
-- armazenamento não são tocados por esta reversão). As tabelas recusam DELETE por gatilho:
-- esvaziá-las exige desligar os gatilhos, como superusuário, de propósito.
-- A contagem roda com row_security = off para não ser enganada pela RLS; se o papel não
-- ignorar RLS, a reversão falha em vez de apagar sem ver.
BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL row_security = off;

DO $$
DECLARE
  v_tabela text;
  v_tem boolean;
BEGIN
  FOREACH v_tabela IN ARRAY ARRAY[
    'published_document_access', 'published_document', 'portal_employee_access', 'portal_privacy_acceptance']
  LOOP
    EXECUTE format('SELECT EXISTS (SELECT 1 FROM folha.%I)', v_tabela) INTO v_tem;
    IF v_tem THEN
      RAISE EXCEPTION '0029 (reversão): folha.% tem linhas; exporte e apague os dados antes de reverter', v_tabela
        USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
  END LOOP;
END
$$;

-- Funções do escritório
DROP FUNCTION folha.portal_relatorio_visualizacao_v1(date, date, uuid, text);
DROP FUNCTION folha.portal_documento_retirar_v1(uuid, text);
DROP FUNCTION folha.portal_documento_publicar_v1(uuid, uuid, text, date, text, text, text, bigint, text, uuid, uuid, uuid, uuid);
DROP FUNCTION folha.portal_acesso_definir_prazo_v1(uuid, date);
DROP FUNCTION folha.portal_acesso_revogar_v1(uuid);
DROP FUNCTION folha.portal_acesso_habilitar_v1(uuid, uuid, uuid, date);

-- Funções do empregado e o schema delas
DROP FUNCTION portal_api.aceitar_aviso_privacidade(text);
DROP FUNCTION portal_api.meu_aviso_privacidade();
DROP FUNCTION portal_api.abrir_meu_documento(uuid, text);
DROP FUNCTION portal_api.listar_meus_documentos(text, date, date, uuid);
DROP SCHEMA portal_api;

-- Tabelas (os gatilhos e as policies caem com elas) e funções de gatilho
DROP TABLE folha.portal_privacy_acceptance;
DROP TABLE folha.published_document_access;
DROP TABLE folha.published_document;
DROP TABLE folha.portal_employee_access;
DROP FUNCTION folha.portal_so_insert();
DROP FUNCTION folha.published_document_trava();
DROP FUNCTION folha.portal_employee_access_trava();
DROP FUNCTION folha.portal_vinculo_existe(uuid, uuid, uuid);

COMMIT;
