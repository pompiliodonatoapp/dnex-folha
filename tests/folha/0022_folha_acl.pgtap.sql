-- DNEX Folha: ACL apos a migration 0022 (revogacao de execucao publica).
-- anon e authenticated NAO executam as funcoes; dnex_gestao_folha_worker executa.
-- Funcoes criadas pela migration 0027 do dnex-gestao nao existem no replay deste
-- repositorio: os testes delas sao pulados (skip), nunca dados como aprovados.
BEGIN;

SELECT plan(25);

SELECT CASE
  WHEN to_regprocedure(sig) IS NULL THEN skip(sig || ' ausente neste repositorio', 3)
  ELSE collect_tap(
    ok(NOT has_function_privilege('anon', to_regprocedure(sig)::oid, 'execute'), sig || ': anon nao executa'),
    ok(NOT has_function_privilege('authenticated', to_regprocedure(sig)::oid, 'execute'), sig || ': authenticated nao executa'),
    ok(has_function_privilege('dnex_gestao_folha_worker', to_regprocedure(sig)::oid, 'execute'), sig || ': worker executa')
  )
END
FROM unnest(ARRAY[
  'folha.build_esocial_s1210(uuid)',
  'folha.build_esocial_s1299(uuid,date)',
  'folha.build_esocial_s2299(uuid,date)',
  'folha.build_reinf_r2010(uuid,date)',
  'folha.build_reinf_r4010(uuid,date)',
  'folha.dispatch_folha_completa(uuid)',
  'folha.dispatch_folha_completa(uuid,date)',
  'folha.dashboard_completo(uuid)'
]) AS sig;

SELECT is_empty(
  $$SELECT p.oid::regprocedure::text
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'folha' AND p.prosecdef
       AND has_function_privilege('anon', p.oid, 'execute')$$,
  'nenhuma funcao SECURITY DEFINER do schema folha e executavel por anon'
);

SELECT * FROM finish();
ROLLBACK;
