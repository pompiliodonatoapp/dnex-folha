-- DNEX Folha — Revogação de execução pública de funções sensíveis (aplicada em prod 2026-11-15).
-- Motivo: funções de despacho eSocial/Reinf e dashboard estavam executáveis por PUBLIC/anon/authenticated
-- após criação ou recriação sem REVOKE explícito. Esta migration garante least-privilege idempotente.
-- Funções criadas fora deste repositório (dnex-gestao, migration 0027) são protegidas com to_regprocedure().
--
-- Rollback (reverter grants para estado anterior — NÃO recomendado em produção):
--   GRANT EXECUTE ON FUNCTION folha.build_esocial_s1210(uuid) TO PUBLIC;
--   GRANT EXECUTE ON FUNCTION folha.build_esocial_s1299(uuid,date) TO PUBLIC;
--   GRANT EXECUTE ON FUNCTION folha.build_esocial_s2299(uuid,date) TO PUBLIC;
--   GRANT EXECUTE ON FUNCTION folha.build_reinf_r2010(uuid,date) TO PUBLIC;
--   GRANT EXECUTE ON FUNCTION folha.build_reinf_r4010(uuid,date) TO PUBLIC;
--   GRANT EXECUTE ON FUNCTION folha.dispatch_folha_completa(uuid) TO PUBLIC;
--   GRANT EXECUTE ON FUNCTION folha.dispatch_folha_completa(uuid,date) TO PUBLIC;
--   GRANT EXECUTE ON FUNCTION folha.dashboard_completo(uuid) TO authenticated;
BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Funções definidas NESTE repositório (migrations 0020 e 0021)
-- ---------------------------------------------------------------------------

-- dispatch_folha_completa(uuid) — migration 0020 linha 225
REVOKE ALL ON FUNCTION folha.dispatch_folha_completa(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION folha.dispatch_folha_completa(uuid) TO dnex_gestao_folha_worker, service_role;

-- dashboard_completo(uuid) — migration 0021 linha 7
REVOKE ALL ON FUNCTION folha.dashboard_completo(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION folha.dashboard_completo(uuid) TO dnex_gestao_folha_worker;

-- ---------------------------------------------------------------------------
-- 2. Funções criadas por dnex-gestao, migration 0027 (outro repositório)
--    Usamos to_regprocedure() para replay do zero não falhar quando a função
--    ainda não existe neste banco. Em produção essas funções já existem.
-- ---------------------------------------------------------------------------

DO $$
BEGIN
  -- build_esocial_s1210(uuid)
  IF to_regprocedure('folha.build_esocial_s1210(uuid)') IS NOT NULL THEN
    EXECUTE 'REVOKE ALL ON FUNCTION folha.build_esocial_s1210(uuid) FROM PUBLIC, anon, authenticated';
    EXECUTE 'GRANT EXECUTE ON FUNCTION folha.build_esocial_s1210(uuid) TO dnex_gestao_folha_worker, service_role';
  END IF;

  -- build_esocial_s1299(uuid, date)
  IF to_regprocedure('folha.build_esocial_s1299(uuid,date)') IS NOT NULL THEN
    EXECUTE 'REVOKE ALL ON FUNCTION folha.build_esocial_s1299(uuid,date) FROM PUBLIC, anon, authenticated';
    EXECUTE 'GRANT EXECUTE ON FUNCTION folha.build_esocial_s1299(uuid,date) TO dnex_gestao_folha_worker, service_role';
  END IF;

  -- build_esocial_s2299(uuid, date)
  IF to_regprocedure('folha.build_esocial_s2299(uuid,date)') IS NOT NULL THEN
    EXECUTE 'REVOKE ALL ON FUNCTION folha.build_esocial_s2299(uuid,date) FROM PUBLIC, anon, authenticated';
    EXECUTE 'GRANT EXECUTE ON FUNCTION folha.build_esocial_s2299(uuid,date) TO dnex_gestao_folha_worker, service_role';
  END IF;

  -- build_reinf_r2010(uuid, date)
  IF to_regprocedure('folha.build_reinf_r2010(uuid,date)') IS NOT NULL THEN
    EXECUTE 'REVOKE ALL ON FUNCTION folha.build_reinf_r2010(uuid,date) FROM PUBLIC, anon, authenticated';
    EXECUTE 'GRANT EXECUTE ON FUNCTION folha.build_reinf_r2010(uuid,date) TO dnex_gestao_folha_worker, service_role';
  END IF;

  -- build_reinf_r4010(uuid, date)
  IF to_regprocedure('folha.build_reinf_r4010(uuid,date)') IS NOT NULL THEN
    EXECUTE 'REVOKE ALL ON FUNCTION folha.build_reinf_r4010(uuid,date) FROM PUBLIC, anon, authenticated';
    EXECUTE 'GRANT EXECUTE ON FUNCTION folha.build_reinf_r4010(uuid,date) TO dnex_gestao_folha_worker, service_role';
  END IF;

  -- dispatch_folha_completa(uuid, date) — sobrecarga com data
  IF to_regprocedure('folha.dispatch_folha_completa(uuid,date)') IS NOT NULL THEN
    EXECUTE 'REVOKE ALL ON FUNCTION folha.dispatch_folha_completa(uuid,date) FROM PUBLIC, anon, authenticated';
    EXECUTE 'GRANT EXECUTE ON FUNCTION folha.dispatch_folha_completa(uuid,date) TO dnex_gestao_folha_worker, service_role';
  END IF;
END
$$;

COMMIT;