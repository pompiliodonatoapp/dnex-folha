-- DNEX Folha — Rollback da fundação do schema folha.
-- Remove schema, role, extensão e todos os objetos criados na migration 0014.
BEGIN;

DROP SCHEMA IF EXISTS folha CASCADE;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dnex_gestao_folha_worker') THEN
    DROP ROLE dnex_gestao_folha_worker;
  END IF;
END
$$;

-- pgcrypto é compartilhada; não remover automaticamente.
-- Se foi instalada exclusivamente por esta migration, descomente:
-- DROP EXTENSION IF EXISTS pgcrypto;

COMMIT;