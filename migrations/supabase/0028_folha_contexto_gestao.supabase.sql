-- DNEX Folha — Migration 0028: contexto de autorização do dnex-gestao (claim da Folha).
--
-- Contrato: dnex-gestao, docs/01-arquitetura/FOLHA-CONTEXTO-AUTORIZACAO.md e
-- migrations/0015_folha_context_candidate.sql (PR 144; schema gestao_folha). Decisão e
-- alternativas: docs/02-decisoes/ADR-contexto-autorizacao-gestao.md.
--
-- O que muda:
--   1. A conta da sessão deixa de vir de "qualquer contexto do grupo api" e passa a vir de
--      gestao_folha.require_folha_context_v1: só existe conta quando a asserção consumida
--      pela transação tem claim da Folha. A Folha deixa de ler gestao_auth.request_context e
--      gestao_auth.access_assertion.
--      - folha.contexto_v1(permissão): função interna (SECURITY DEFINER, sem EXECUTE para
--        ninguém além do dono) que devolve conta, entidade legal, filial e subject, exigindo a
--        permissão pedida. Levanta 42501 quando o contexto não serve.
--      - folha.request_context_account_id(): contexto_v1('folha.read'), NULL em 42501. É o que
--        as policies de RLS chamam, por folha.current_account_id().
--   2. Quem executa: a sessão de aplicação é um LOGIN membro só de dnex_gestao_api, que não tem
--      GRANT em tabela da Folha. Ela opera pelas funções folha.*_v1 desta migration (EXECUTE só
--      para dnex_gestao_api), cada uma exigindo a sua permissão no início e antes de devolver.
--      dnex_gestao_folha_worker deixa de ser caminho de sessão: continua NOLOGIN, titular dos
--      GRANTs de tabela e de função das migrations 0014 a 0027 (nenhum é revogado aqui), mas
--      nenhum login que seja membro dele abre contexto.
--   3. Identidade: cálculo, conclusão, liberação de pendência, aprovação e fechamento gravam o
--      subject do contexto. Em payroll_run e payroll_result isso é feito por gatilho, então
--      vale também para UPDATE direto. O texto "responsável" das funções da 0027 deixa de ser
--      identidade (as funções _v1 nem o recebem).
--   4. Segregação mínima opcional (folha.segregation_config, por conta, desligada por padrão):
--      quem calculou a folha não libera pendência, não aprova e não fecha.
--   5. Despacho e geradores (dispatch_folha_completa, dispatch_*_event, build_*): exigem
--      folha.transmit e filtram pela conta do contexto. service_role perde o EXECUTE de
--      dispatch_folha_completa(uuid).
--   6. folha.request_context_config: a lista de grupos deixa de ser NULL e passa a {api}. A
--      barreira é a claim; a lista fica como chave geral (lista vazia ou linha ausente = Folha
--      sem contexto).
--   7. search_path: toda função do schema folha que fixa search_path passa a terminar em
--      pg_temp. Sem isso o Postgres procura tipos e tabelas PRIMEIRO no schema temporário da
--      sessão: quem tem SQL livre com o login de aplicação criava pg_temp.uuid (domínio com
--      CHECK) e fazia código seu rodar como o dono de qualquer função SECURITY DEFINER com
--      variável uuid, antes de qualquer conferência de contexto (achado da revisão de 15/11).
--
-- Permissão exigida por operação:
--   folha.read      conta da sessão (RLS), contexto_atual_v1, dashboard_v1
--   folha.calculate folha_abrir_v1, folha_calcular_contrato_v1, folha_concluir_calculo_v1
--   folha.close     folha_liberar_pendencia_v1, folha_aprovar_v1, folha_fechar_v1, folha_cancelar_v1
--   folha.transmit  folha_transmitir_v1, geradores e despachos
--   folha.admin     segregacao_definir_v1
--
-- NÃO altera as migrations 0014 a 0027. NÃO APLICAR EM PRODUÇÃO antes de o schema gestao_folha
-- existir lá (a pré-condição 0.2 aborta) e de o dono desta migration ter EXECUTE em
-- gestao_folha.require_folha_context_v1 (0.3; ver a ADR, seção "Dono das funções").
-- Reversão: 0028_folha_contexto_gestao.supabase.down.sql.
BEGIN;

SET LOCAL lock_timeout = '5s';

-- ---------------------------------------------------------------------------
-- 0. Pré-condições (falha limpa, antes de qualquer alteração)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_faltando text;
BEGIN
  -- 0.1 Papel de teste só em banco de CI (mesmo critério da 0024).
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'dnex_folha_ci')
     AND NOT EXISTS (
       SELECT 1
         FROM pg_catalog.pg_namespace n
         JOIN pg_catalog.pg_roles r ON r.oid = n.nspowner
        WHERE n.nspname = 'dnex_folha_ci_marcador' AND r.rolsuper)
  THEN
    RAISE EXCEPTION '0028: o papel de teste dnex_folha_ci existe neste cluster, mas este banco não é de CI'
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;

  -- 0.2 Contrato do dnex-gestao e objetos da 0027.
  SELECT string_agg(x.nome, ', ') INTO v_faltando
    FROM (VALUES
      ('papel dnex_gestao_api',
         NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'dnex_gestao_api')),
      ('gestao_folha.require_folha_context_v1(text)',
         to_regprocedure('gestao_folha.require_folha_context_v1(text)') IS NULL),
      ('folha.payroll_run_fechar(uuid, text) (migration 0027)',
         to_regprocedure('folha.payroll_run_fechar(uuid, text)') IS NULL),
      ('folha.request_context_config (migration 0025)',
         to_regclass('folha.request_context_config') IS NULL)
    ) AS x(nome, ausente)
   WHERE x.ausente;
  IF v_faltando IS NOT NULL THEN
    RAISE EXCEPTION '0028: faltam objetos: %', v_faltando
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;

  -- 0.3 Quem aplica vira dono das funções SECURITY DEFINER desta migration. Sem EXECUTE em
  --     require_folha_context_v1 a conta da sessão viria sempre nula, em silêncio.
  IF NOT has_schema_privilege(current_user, 'gestao_folha', 'USAGE')
     OR NOT has_function_privilege(current_user, 'gestao_folha.require_folha_context_v1(text)', 'EXECUTE') THEN
    RAISE EXCEPTION '0028: o papel % não executa gestao_folha.require_folha_context_v1 (no dnex-gestao o EXECUTE é só de dnex_gestao_api); a conta da sessão ficaria sempre nula', current_user
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- 0.3.1 O contexto é tão seguro quanto as funções do gestao que a sessão de aplicação
  --       executa. Função SECURITY DEFINER de gestao_auth ou gestao_folha, executável por
  --       dnex_gestao_api, com search_path que não termina em pg_temp deixa quem tem SQL livre
  --       com o login de aplicação rodar código como o dono dela (domínio pg_temp.text, por
  --       exemplo) e reescrever a própria asserção e a claim: outra conta, todas as permissões.
  --       Provado na revisão de 15/11 contra has_permission e begin_request. Não se corrige
  --       daqui (é do dnex-gestao): a migration não aplica enquanto existir.
  SELECT string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text) INTO v_faltando
    FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname IN ('gestao_auth', 'gestao_folha') AND p.prosecdef
     AND has_function_privilege('dnex_gestao_api', p.oid, 'EXECUTE')
     AND NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) AS cfg
                      WHERE cfg ~ '^search_path=pg_catalog(,|$)' AND cfg ~ ',\s*pg_temp$' AND cfg !~ 'pg_temp.*pg_temp');
  IF v_faltando IS NOT NULL THEN
    RAISE EXCEPTION '0028: funções do dnex-gestao executáveis por dnex_gestao_api com search_path que não termina em pg_temp (corrija no dnex-gestao antes): %', v_faltando
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;

  -- 0.4 As funções desta migration leem e gravam com filtro explícito de conta e precisam de
  --     dono que ignore RLS (mesma exigência da 0024 e da 0025).
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles
                  WHERE rolname = current_user AND (rolsuper OR rolbypassrls)) THEN
    RAISE EXCEPTION '0028: o papel % não é superusuário nem tem BYPASSRLS', current_user
      USING ERRCODE = 'insufficient_privilege';
  END IF;
END
$$;

-- ===========================================================================
-- 1. Contexto
-- ===========================================================================

-- 1.1 Leitura do contexto com permissão. Interna: ninguém além do dono executa. Não recebe
--     conta, subject nem login: tudo vem de require_folha_context_v1, que confere o vínculo
--     do contexto com session_user, PID e transação, a claim, a validade (até 60 s), a
--     revogação, o login estrito do grupo api e o escopo ativo. Qualquer divergência: 42501.
CREATE FUNCTION folha.contexto_v1(p_permissao text)
RETURNS TABLE (account_id uuid, legal_entity_id uuid, branch_id uuid, subject_id uuid)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = on
AS $function$
#variable_conflict use_column
DECLARE
  v_ctx record;
  v_grupos text[];
BEGIN
  SELECT c.account_id, c.legal_entity_id, c.branch_id, c.subject_id
    INTO v_ctx
    FROM gestao_folha.require_folha_context_v1(p_permissao) AS c;
  IF NOT FOUND OR v_ctx.account_id IS NULL OR v_ctx.subject_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Contexto da Folha ausente';
  END IF;

  -- Chave geral (0025): sem a linha, ninguém; lista, só se contiver o grupo do contexto da
  -- Folha, que é sempre api (a claim só existe para esse grupo); NULL, sem restrição.
  SELECT cfg.principal_groups_permitidos INTO v_grupos
    FROM folha.request_context_config AS cfg
   WHERE cfg.singleton;
  IF NOT FOUND OR (v_grupos IS NOT NULL AND ('api' = ANY (v_grupos)) IS NOT TRUE) THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Contexto da Folha recusado pela configuração';
  END IF;

  account_id := v_ctx.account_id;
  legal_entity_id := v_ctx.legal_entity_id;
  branch_id := v_ctx.branch_id;
  subject_id := v_ctx.subject_id;
  RETURN NEXT;
END
$function$;

-- 1.2 Conta da sessão: a do contexto da Folha com folha.read; NULL quando não há (nenhuma
--     linha visível, nenhuma gravação). Mesma assinatura, dono e ACL da 0024/0025.
CREATE OR REPLACE FUNCTION folha.request_context_account_id() RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = on
AS $function$
BEGIN
  RETURN (SELECT c.account_id FROM folha.contexto_v1('folha.read') AS c);
EXCEPTION WHEN insufficient_privilege THEN
  RETURN NULL;
END
$function$;

-- 1.3 Grupos aceitos: a restrição deixa de ser NULL. Só altera a linha que ainda está como a
--     0025 a deixou.
UPDATE folha.request_context_config
   SET principal_groups_permitidos = ARRAY['api'],
       observacao = 'Contexto da Folha = claim de gestao_folha no grupo api (migration 0028). Lista vazia ou linha ausente desliga o contexto da Folha.',
       updated_at = now()
 WHERE singleton AND principal_groups_permitidos IS NULL;

-- ===========================================================================
-- 2. Identidade e segregação
-- ===========================================================================
ALTER TABLE folha.payroll_run
  ADD COLUMN calculado_por_subject uuid,
  ADD COLUMN aprovado_por_subject uuid,
  ADD COLUMN fechado_por_subject uuid;
ALTER TABLE folha.payroll_result
  ADD COLUMN calculado_por_subject uuid;
ALTER TABLE folha.payroll_pendency
  ADD COLUMN liberada_por_subject uuid,
  -- NOT VALID: vale para toda liberação nova; as anteriores à 0028 não têm subject.
  ADD CONSTRAINT payroll_pendency_liberacao_identificada
    CHECK (liberada_em IS NULL OR liberada_por_subject IS NOT NULL) NOT VALID,
  ADD CONSTRAINT payroll_pendency_subject_so_com_liberacao
    CHECK (liberada_por_subject IS NULL OR liberada_em IS NOT NULL);
ALTER TABLE folha.auditoria
  ADD COLUMN actor_subject uuid;

COMMENT ON COLUMN folha.payroll_run.calculado_por_subject IS 'Subject do contexto que concluiu o cálculo (gravado por gatilho; folha.calculate)';
COMMENT ON COLUMN folha.payroll_run.aprovado_por_subject IS 'Subject do contexto que aprovou (gravado por gatilho; folha.close)';
COMMENT ON COLUMN folha.payroll_run.fechado_por_subject IS 'Subject do contexto que fechou (gravado por gatilho; folha.close)';
COMMENT ON COLUMN folha.payroll_run.approved_by IS 'Rótulo informado por quem chama a função da 0027; NÃO é identidade (ver aprovado_por_subject)';
COMMENT ON COLUMN folha.payroll_result.calculado_por_subject IS 'Subject do contexto que calculou o resultado (gravado por gatilho; folha.calculate)';
COMMENT ON COLUMN folha.payroll_pendency.liberada_por_subject IS 'Subject do contexto que liberou a pendência (folha.close)';
COMMENT ON COLUMN folha.payroll_pendency.liberada_por IS 'Rótulo informado por quem chama a função da 0027; NÃO é identidade (ver liberada_por_subject)';
COMMENT ON COLUMN folha.auditoria.actor_subject IS 'Subject do contexto que executou a ação (a partir da migration 0028)';

-- 2.1 Segregação mínima, por conta. Sem linha ou com false: desligada (padrão).
CREATE TABLE folha.segregation_config (
  account_id uuid PRIMARY KEY,
  calculo_x_fechamento boolean NOT NULL DEFAULT false,
  definido_por_subject uuid NOT NULL,
  definido_em timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE folha.segregation_config IS
  'Segregação mínima de funções por conta: com calculo_x_fechamento = true, o subject que calculou a folha não libera pendência, não aprova e não fecha. Desligada por padrão.';
ALTER TABLE folha.segregation_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE folha.segregation_config FORCE ROW LEVEL SECURITY;
CREATE POLICY segregation_config_isolamento ON folha.segregation_config
  FOR SELECT TO dnex_gestao_folha_worker, dnex_gestao_data_owner
  USING (account_id = (SELECT folha.current_account_id()));

-- Recusa quando a segregação está ligada e o subject participou do cálculo. Folha calculada
-- sem subject (antes desta migration) não permite provar a segregação: também recusa.
CREATE FUNCTION folha.segregacao_conferir(p_conta uuid, p_run_id uuid, p_subject uuid) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
BEGIN
  IF NOT COALESCE((SELECT s.calculo_x_fechamento FROM folha.segregation_config s WHERE s.account_id = p_conta), false) THEN
    RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM folha.payroll_run r
              WHERE r.account_id = p_conta AND r.run_id = p_run_id AND r.calculado_por_subject IS NULL)
     OR EXISTS (SELECT 1 FROM folha.payroll_result pr
                 WHERE pr.account_id = p_conta AND pr.run_id = p_run_id AND pr.calculado_por_subject IS NULL) THEN
    RAISE EXCEPTION USING ERRCODE = '42501',
      MESSAGE = 'Segregação de funções: a folha ' || p_run_id::text || ' foi calculada sem identificação de quem calculou; cancele e recalcule';
  END IF;
  IF EXISTS (SELECT 1 FROM folha.payroll_run r
              WHERE r.account_id = p_conta AND r.run_id = p_run_id AND r.calculado_por_subject = p_subject)
     OR EXISTS (SELECT 1 FROM folha.payroll_result pr
                 WHERE pr.account_id = p_conta AND pr.run_id = p_run_id AND pr.calculado_por_subject = p_subject) THEN
    RAISE EXCEPTION USING ERRCODE = '42501',
      MESSAGE = 'Segregação de funções: quem calculou a folha ' || p_run_id::text || ' não libera pendência, não aprova e não fecha';
  END IF;
END
$function$;

-- 2.2 Folha: o subject de quem conclui o cálculo, aprova e fecha é gravado pelo gatilho, a
--     partir do contexto, e não pode ser informado nem alterado por quem grava. O nome do
--     gatilho o coloca DEPOIS de trg_payroll_run_trava (ordem alfabética): as recusas da trava
--     continuam vindo primeiro.
CREATE FUNCTION folha.payroll_run_identidade() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx record;
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.calculado_por_subject := NULL;
    NEW.aprovado_por_subject := NULL;
    NEW.fechado_por_subject := NULL;
    RETURN NEW;
  END IF;

  NEW.calculado_por_subject := OLD.calculado_por_subject;
  NEW.aprovado_por_subject := OLD.aprovado_por_subject;
  NEW.fechado_por_subject := OLD.fechado_por_subject;
  IF NEW.status IS NOT DISTINCT FROM OLD.status
     OR NEW.status NOT IN ('calculated', 'approved', 'closed') THEN
    RETURN NEW;
  END IF;

  SELECT c.account_id, c.subject_id INTO v_ctx
    FROM folha.contexto_v1(CASE WHEN NEW.status = 'calculated' THEN 'folha.calculate' ELSE 'folha.close' END) AS c;
  IF v_ctx.account_id IS DISTINCT FROM NEW.account_id THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Folha de outra conta';
  END IF;

  IF NEW.status = 'calculated' THEN
    NEW.calculado_por_subject := v_ctx.subject_id;
  ELSE
    PERFORM folha.segregacao_conferir(NEW.account_id, NEW.run_id, v_ctx.subject_id);
    IF NEW.status = 'approved' THEN
      NEW.aprovado_por_subject := v_ctx.subject_id;
    ELSE
      NEW.fechado_por_subject := v_ctx.subject_id;
    END IF;
  END IF;
  RETURN NEW;
END
$function$;
CREATE TRIGGER trg_payroll_run_z_identidade
  BEFORE INSERT OR UPDATE ON folha.payroll_run
  FOR EACH ROW EXECUTE FUNCTION folha.payroll_run_identidade();

-- 2.3 Resultado: só nasce sob contexto com folha.calculate, e leva o subject.
CREATE FUNCTION folha.payroll_result_identidade() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx record;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    NEW.calculado_por_subject := OLD.calculado_por_subject;
    RETURN NEW;
  END IF;
  SELECT c.account_id, c.subject_id INTO v_ctx FROM folha.contexto_v1('folha.calculate') AS c;
  IF v_ctx.account_id IS DISTINCT FROM NEW.account_id THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Resultado de outra conta';
  END IF;
  NEW.calculado_por_subject := v_ctx.subject_id;
  RETURN NEW;
END
$function$;
CREATE TRIGGER trg_payroll_result_z_identidade
  BEFORE INSERT OR UPDATE ON folha.payroll_result
  FOR EACH ROW EXECUTE FUNCTION folha.payroll_result_identidade();

-- ===========================================================================
-- 3. Funções da 0027 com permissão e identidade (mesmas assinaturas; CREATE OR REPLACE
--    preserva dono e ACL). O corpo é o da 0027 com as linhas marcadas "0028".
-- ===========================================================================
CREATE OR REPLACE FUNCTION folha.run_payroll_employee(
  p_run_id uuid,
  p_contract_id uuid,
  p_num_dependentes_irrf integer DEFAULT 0,
  p_num_filhos_salario_familia integer DEFAULT 0
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, folha, pg_temp
AS $$
DECLARE
  v_conta uuid := folha.current_account_id();
  v_categoria text;
  v_contract_employer uuid;
  v_competencia date;
  v_data_pagamento date;
  v_status text;
  v_tipo text;
  v_run_employer uuid;
  v_calc jsonb;
  v_pend_data text[] := ARRAY[]::text[];
BEGIN
  IF v_conta IS NULL THEN
    RAISE EXCEPTION 'run_payroll_employee: sessão sem conta (contexto não aberto)';
  END IF;
  PERFORM 1 FROM folha.contexto_v1('folha.calculate');   -- 0028
  IF COALESCE(p_num_dependentes_irrf, 0) < 0 OR COALESCE(p_num_filhos_salario_familia, 0) < 0 THEN
    RAISE EXCEPTION 'run_payroll_employee: dependentes e filhos não podem ser negativos';
  END IF;

  SELECT c.regime_trabalho, c.employer_id
    INTO v_categoria, v_contract_employer
    FROM folha.employment_contract c
   WHERE c.contract_id = p_contract_id AND c.account_id = v_conta;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Contrato % não encontrado', p_contract_id;
  END IF;

  -- Os processos do mesmo contrato se leem uns aos outros (adiantamento, mensal, complementar,
  -- 13º, rescisão): cálculos simultâneos do mesmo contrato ficam em fila, em qualquer folha.
  PERFORM pg_advisory_xact_lock(hashtextextended('folha.contrato:' || p_contract_id::text, 0));

  -- Trava a folha: chamadas simultâneas para a mesma folha ficam em fila.
  SELECT r.competencia, r.data_pagamento, r.status, r.employer_id, r.tipo_processo
    INTO v_competencia, v_data_pagamento, v_status, v_run_employer, v_tipo
    FROM folha.payroll_run r
   WHERE r.run_id = p_run_id AND r.account_id = v_conta
     FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Folha % não encontrada', p_run_id;
  END IF;
  IF v_status NOT IN ('draft', 'calculating') THEN
    RAISE EXCEPTION 'Folha % está em % e não recebe cálculo', p_run_id, v_status;
  END IF;
  IF v_run_employer IS NOT NULL AND v_run_employer IS DISTINCT FROM v_contract_employer THEN
    RAISE EXCEPTION 'Contrato % não é do empregador da folha %', p_contract_id, p_run_id;
  END IF;

  IF v_categoria = 'pj' THEN
    RAISE EXCEPTION 'run_payroll_employee: categoria pj não é processada na folha';
  END IF;
  IF EXISTS (SELECT 1 FROM folha.payroll_result pr
              WHERE pr.account_id = v_conta AND pr.run_id = p_run_id AND pr.contract_id = p_contract_id) THEN
    RAISE EXCEPTION 'Contrato % já tem resultado na folha %', p_contract_id, p_run_id;
  END IF;

  IF v_tipo <> 'mensal' AND COALESCE(p_num_filhos_salario_familia, 0) > 0 THEN
    RAISE EXCEPTION 'Salário-família só é calculado na folha mensal';
  END IF;

  IF v_tipo IN ('mensal', 'adiantamento', 'complementar') THEN
    IF v_data_pagamento IS NULL THEN
      -- O cálculo segue com o último dia da competência; sem a data, a folha não fecha.
      v_data_pagamento := (date_trunc('month', v_competencia::timestamp) + interval '1 month' - interval '1 day')::date;
      v_pend_data := ARRAY['pendencia:data_pagamento_nao_informada_usado_ultimo_dia_da_competencia'];
    END IF;
    v_calc := folha.folha_rubricas_calcular(v_conta, p_run_id, p_contract_id, v_tipo, v_competencia, v_data_pagamento,
                                            p_num_dependentes_irrf, p_num_filhos_salario_familia);
  ELSIF v_tipo IN ('decimo_terceiro_1', 'decimo_terceiro_2') THEN
    v_calc := folha.folha_13o_calcular(v_conta, p_run_id, p_contract_id, v_tipo, v_competencia, v_data_pagamento,
                                       p_num_dependentes_irrf);
  ELSIF v_tipo = 'ferias' THEN
    v_calc := folha.folha_ferias_calcular(v_conta, p_run_id, p_contract_id, v_competencia, v_data_pagamento,
                                          p_num_dependentes_irrf);
  ELSIF v_tipo = 'rescisao' THEN
    v_calc := folha.folha_rescisao_calcular(v_conta, p_run_id, p_contract_id, v_competencia, v_data_pagamento,
                                            p_num_dependentes_irrf);
  ELSE
    RAISE EXCEPTION 'Tipo de processo desconhecido: %', v_tipo;
  END IF;

  v_calc := jsonb_set(v_calc, '{pendencias}', (v_calc->'pendencias') || to_jsonb(v_pend_data));
  RETURN folha.folha_gravar_resultado(v_conta, p_run_id, p_contract_id, v_competencia, v_calc);
END;
$$;

CREATE OR REPLACE FUNCTION folha.payroll_run_concluir_calculo(p_run_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, folha, pg_temp
AS $$
DECLARE
  v_conta uuid := folha.current_account_id();
  v_status text;
  v_n integer;
BEGIN
  IF v_conta IS NULL THEN
    RAISE EXCEPTION 'payroll_run_concluir_calculo: sessão sem conta (contexto não aberto)';
  END IF;
  PERFORM 1 FROM folha.contexto_v1('folha.calculate');   -- 0028
  SELECT r.status INTO v_status FROM folha.payroll_run r
   WHERE r.run_id = p_run_id AND r.account_id = v_conta FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Folha % não encontrada', p_run_id;
  END IF;
  IF v_status NOT IN ('draft', 'calculating') THEN
    RAISE EXCEPTION 'Folha % está em % e não pode ter o cálculo concluído', p_run_id, v_status;
  END IF;
  SELECT count(*) INTO v_n FROM folha.payroll_result pr WHERE pr.account_id = v_conta AND pr.run_id = p_run_id;
  IF v_n = 0 THEN
    RAISE EXCEPTION 'Folha % não tem resultado calculado', p_run_id;
  END IF;
  UPDATE folha.payroll_run r
     SET status = 'calculated', calculado_em = now(), updated_at = now(),
         total_proventos = t.prov, total_descontos = t.descontos, total_liquido = t.liq,
         total_encargos_patronais = t.enc
    FROM (SELECT sum(pr.total_proventos) AS prov, sum(pr.total_descontos) AS descontos, sum(pr.liquido) AS liq,
                 sum(pr.inss_patronal + pr.rat + pr.terceiros) AS enc
            FROM folha.payroll_result pr WHERE pr.account_id = v_conta AND pr.run_id = p_run_id) t
   WHERE r.run_id = p_run_id AND r.account_id = v_conta;
END;
$$;

-- Liberação de pendência: exige folha.close; grava o subject do contexto na pendência e na
-- auditoria; respeita a segregação. p_responsavel continua obrigatório nesta assinatura (a da
-- 0027), mas é só rótulo: a identidade é liberada_por_subject.
CREATE OR REPLACE FUNCTION folha.payroll_pendencias_liberar(
  p_run_id uuid,
  p_codigo text,
  p_responsavel text,
  p_motivo text
) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, folha, pg_temp
AS $$
DECLARE
  v_conta uuid := folha.current_account_id();
  v_status text;
  v_n integer;
  v_ctx record;   -- 0028
BEGIN
  IF v_conta IS NULL THEN
    RAISE EXCEPTION 'payroll_pendencias_liberar: sessão sem conta (contexto não aberto)';
  END IF;
  SELECT c.account_id, c.legal_entity_id, c.branch_id, c.subject_id INTO v_ctx
    FROM folha.contexto_v1('folha.close') AS c;   -- 0028
  IF v_ctx.account_id IS DISTINCT FROM v_conta THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Contexto da Folha divergente';
  END IF;
  IF btrim(COALESCE(p_responsavel, '')) = '' OR btrim(COALESCE(p_motivo, '')) = '' THEN
    RAISE EXCEPTION 'payroll_pendencias_liberar: responsável e motivo são obrigatórios';
  END IF;
  SELECT r.status INTO v_status FROM folha.payroll_run r
   WHERE r.run_id = p_run_id AND r.account_id = v_conta FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Folha % não encontrada', p_run_id;
  END IF;
  IF v_status <> 'calculated' THEN
    RAISE EXCEPTION 'Folha % está em %: pendência só é liberada com o cálculo concluído', p_run_id, v_status;
  END IF;
  IF EXISTS (SELECT 1 FROM folha.payroll_pendency p
              WHERE p.account_id = v_conta AND p.run_id = p_run_id AND p.codigo = p_codigo
                AND p.liberada_em IS NULL AND p.tipo = 'pendencia') THEN
    RAISE EXCEPTION 'Pendência de cálculo % não é liberável: o valor está errado ou incompleto; corrija a origem, cancele a folha e recalcule', p_codigo;
  END IF;
  PERFORM folha.segregacao_conferir(v_conta, p_run_id, v_ctx.subject_id);   -- 0028
  UPDATE folha.payroll_pendency p
     SET liberada_em = now(), liberada_por = btrim(p_responsavel),
         liberada_sessao = session_user, liberacao_motivo = btrim(p_motivo),
         liberada_por_subject = v_ctx.subject_id   -- 0028
   WHERE p.account_id = v_conta AND p.run_id = p_run_id AND p.codigo = p_codigo AND p.liberada_em IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN
    RAISE EXCEPTION 'Folha % não tem pendência aberta com o código %', p_run_id, p_codigo;
  END IF;
  INSERT INTO folha.auditoria (account_id, actor, actor_subject, acao, recurso, recurso_id, detalhe)
  VALUES (v_conta, v_ctx.subject_id::text, v_ctx.subject_id, 'liberar_pendencia', 'payroll_run', p_run_id,
          jsonb_build_object('codigo', p_codigo, 'motivo', btrim(p_motivo), 'pendencias', v_n, 'sessao', session_user,
                             'rotulo_informado', btrim(p_responsavel),
                             'legal_entity_id', v_ctx.legal_entity_id, 'branch_id', v_ctx.branch_id));
  RETURN v_n;
END;
$$;

CREATE OR REPLACE FUNCTION folha.payroll_run_aprovar(p_run_id uuid, p_responsavel text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, folha, pg_temp
AS $$
DECLARE
  v_conta uuid := folha.current_account_id();
  v_status text;
  v_ctx record;   -- 0028
BEGIN
  IF v_conta IS NULL THEN
    RAISE EXCEPTION 'payroll_run_aprovar: sessão sem conta (contexto não aberto)';
  END IF;
  SELECT c.account_id, c.legal_entity_id, c.branch_id, c.subject_id INTO v_ctx
    FROM folha.contexto_v1('folha.close') AS c;   -- 0028
  IF v_ctx.account_id IS DISTINCT FROM v_conta THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Contexto da Folha divergente';
  END IF;
  IF btrim(COALESCE(p_responsavel, '')) = '' THEN
    RAISE EXCEPTION 'payroll_run_aprovar: responsável obrigatório';
  END IF;
  SELECT r.status INTO v_status FROM folha.payroll_run r
   WHERE r.run_id = p_run_id AND r.account_id = v_conta FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Folha % não encontrada', p_run_id;
  END IF;
  IF v_status <> 'calculated' THEN
    RAISE EXCEPTION 'Folha % está em % e não pode ser aprovada', p_run_id, v_status;
  END IF;
  -- aprovado_por_subject é gravado pelo gatilho trg_payroll_run_z_identidade.
  UPDATE folha.payroll_run r
     SET status = 'approved', aprovado_em = now(), approved_by = btrim(p_responsavel), updated_at = now()
   WHERE r.run_id = p_run_id AND r.account_id = v_conta;
  INSERT INTO folha.auditoria (account_id, actor, actor_subject, acao, recurso, recurso_id, detalhe)
  VALUES (v_conta, v_ctx.subject_id::text, v_ctx.subject_id, 'aprovar_folha', 'payroll_run', p_run_id,
          jsonb_build_object('sessao', session_user, 'rotulo_informado', btrim(p_responsavel),
                             'legal_entity_id', v_ctx.legal_entity_id, 'branch_id', v_ctx.branch_id));
END;
$$;

CREATE OR REPLACE FUNCTION folha.payroll_run_fechar(p_run_id uuid, p_responsavel text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, folha, pg_temp
AS $$
DECLARE
  v_conta uuid := folha.current_account_id();
  v_status text;
  v_ctx record;   -- 0028
BEGIN
  IF v_conta IS NULL THEN
    RAISE EXCEPTION 'payroll_run_fechar: sessão sem conta (contexto não aberto)';
  END IF;
  SELECT c.account_id, c.legal_entity_id, c.branch_id, c.subject_id INTO v_ctx
    FROM folha.contexto_v1('folha.close') AS c;   -- 0028
  IF v_ctx.account_id IS DISTINCT FROM v_conta THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Contexto da Folha divergente';
  END IF;
  IF btrim(COALESCE(p_responsavel, '')) = '' THEN
    RAISE EXCEPTION 'payroll_run_fechar: responsável obrigatório';
  END IF;
  SELECT r.status INTO v_status FROM folha.payroll_run r
   WHERE r.run_id = p_run_id AND r.account_id = v_conta FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Folha % não encontrada', p_run_id;
  END IF;
  IF v_status <> 'approved' THEN
    RAISE EXCEPTION 'Folha % está em % e não pode ser fechada', p_run_id, v_status;
  END IF;
  -- fechado_por_subject é gravado pelo gatilho trg_payroll_run_z_identidade.
  UPDATE folha.payroll_run r
     SET status = 'closed', fechado_em = now(), updated_at = now()
   WHERE r.run_id = p_run_id AND r.account_id = v_conta;
  INSERT INTO folha.auditoria (account_id, actor, actor_subject, acao, recurso, recurso_id, detalhe)
  VALUES (v_conta, v_ctx.subject_id::text, v_ctx.subject_id, 'fechar_folha', 'payroll_run', p_run_id,
          jsonb_build_object('sessao', session_user, 'rotulo_informado', btrim(p_responsavel),
                             'legal_entity_id', v_ctx.legal_entity_id, 'branch_id', v_ctx.branch_id));
END;
$$;

-- ===========================================================================
-- 4. Despacho e geradores: folha.transmit e conta do contexto
--    Antes: SECURITY DEFINER sem filtro de conta. Quem tivesse EXECUTE lia, pelo
--    identificador, resultado, contrato e trabalhador de qualquer conta, e despachava folha
--    de qualquer conta. Agora todo SELECT filtra pela conta do contexto.
--    (Os geradores continuam os da 0020, sem leiaute oficial: a refazer na fatia do eSocial.)
-- ===========================================================================
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

CREATE OR REPLACE FUNCTION folha.dispatch_esocial_event(
  p_run_id uuid,
  p_result_id uuid,
  p_evento_codigo text,
  p_competencia date,
  p_payload jsonb,
  p_cofre_cert_ref uuid DEFAULT NULL
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
    FROM folha.payroll_run
   WHERE run_id = p_run_id AND account_id = v_conta;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'payroll_run % não encontrado', p_run_id;
  END IF;
  IF p_result_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM folha.payroll_result pr
        WHERE pr.result_id = p_result_id AND pr.run_id = p_run_id AND pr.account_id = v_conta) THEN
    RAISE EXCEPTION 'payroll_result % não encontrado no run %', p_result_id, p_run_id;
  END IF;

  v_idem_key := p_run_id::text || '|' || COALESCE(p_result_id::text, 'run') || '|' || p_evento_codigo || '|' || to_char(p_competencia, 'YYYY-MM-DD');   -- 0028: não depende de DateStyle

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

CREATE OR REPLACE FUNCTION folha.build_esocial_s1200(
  p_result_id uuid
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha, pg_temp
AS $$
DECLARE
  v_conta uuid;
  v_result record;
  v_employee record;
  v_contract record;
  v_payload jsonb;
BEGIN
  SELECT c.account_id INTO v_conta FROM folha.contexto_v1('folha.transmit') AS c;

  SELECT pr.*, pr.run_id INTO v_result
  FROM folha.payroll_result pr
  WHERE pr.result_id = p_result_id AND pr.account_id = v_conta;

  IF v_result.result_id IS NULL THEN
    RAISE EXCEPTION 'payroll_result % não encontrado', p_result_id;
  END IF;

  SELECT e.* INTO v_employee
  FROM folha.employee e
  WHERE e.employee_id = v_result.employee_id AND e.account_id = v_conta;

  SELECT c.* INTO v_contract
  FROM folha.employment_contract c
  WHERE c.contract_id = v_result.contract_id AND c.account_id = v_conta;

  v_payload := jsonb_build_object(
    'evento', 'S-1200',
    'versao_leiaute', 'S-1.3',
    'competencia', (SELECT competencia FROM folha.payroll_run WHERE run_id = v_result.run_id AND account_id = v_conta),
    'cpf_trabalhador', v_employee.cpf,
    'nome_trabalhador', v_employee.nome_completo,
    'matricula', v_contract.contract_id::text,
    'cod_categoria', CASE v_contract.regime_trabalho
      WHEN 'clt' THEN '101'
      WHEN 'aprendiz' THEN '103'
      WHEN 'estagio' THEN '401'
      ELSE '101'
    END,
    'remuneracao', jsonb_build_object(
      'vr_salario', v_result.total_proventos,
      'vr_inss_empregado', v_result.inss_empregado,
      'vr_irrf', v_result.irrf,
      'vr_fgts', v_result.fgts,
      'vr_liquido', v_result.liquido
    ),
    'encargos_patronais', jsonb_build_object(
      'vr_inss_patronal', COALESCE(v_result.inss_patronal, 0),
      'vr_rat', COALESCE(v_result.rat, 0),
      'vr_terceiros', COALESCE(v_result.terceiros, 0)
    ),
    'gerado_em', now(),
    'calculation_hash', v_result.calculation_hash
  );

  RETURN v_payload;
END;
$$;

CREATE OR REPLACE FUNCTION folha.build_esocial_s2200(
  p_contract_id uuid
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha, pg_temp
AS $$
DECLARE
  v_conta uuid;
  v_employee record;
  v_contract record;
  v_payload jsonb;
BEGIN
  SELECT c.account_id INTO v_conta FROM folha.contexto_v1('folha.transmit') AS c;

  SELECT c.* INTO v_contract
  FROM folha.employment_contract c
  WHERE c.contract_id = p_contract_id AND c.account_id = v_conta;

  IF v_contract.contract_id IS NULL THEN
    RAISE EXCEPTION 'employment_contract % não encontrado', p_contract_id;
  END IF;

  SELECT e.* INTO v_employee
  FROM folha.employee e
  WHERE e.employee_id = v_contract.employee_id AND e.account_id = v_conta;

  v_payload := jsonb_build_object(
    'evento', 'S-2200',
    'versao_leiaute', 'S-1.3',
    'cpf_trabalhador', v_employee.cpf,
    'nome_trabalhador', v_employee.nome_completo,
    'data_nascimento', v_employee.data_nascimento,
    'sexo', v_employee.sexo,
    'data_admissao', v_contract.data_admissao,
    'cargo', v_contract.cargo,
    'salario_base', v_contract.salario_base,
    'regime_trabalho', v_contract.regime_trabalho,
    'jornada_semanal', v_contract.jornada_semanal,
    'cod_categoria', CASE v_contract.regime_trabalho
      WHEN 'clt' THEN '101'
      WHEN 'aprendiz' THEN '103'
      WHEN 'estagio' THEN '401'
      ELSE '101'
    END,
    'gerado_em', now()
  );

  RETURN v_payload;
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

-- Sem contexto não há despacho: o EXECUTE que a 0022 preservou para service_role não tem mais
-- caminho de uso (service_role não é login do grupo api) e sai.
REVOKE ALL ON FUNCTION folha.dispatch_folha_completa(uuid) FROM service_role;

-- ===========================================================================
-- 5. Funções da sessão de aplicação (EXECUTE só para dnex_gestao_api)
--    As que gravam conferem a permissão no início e de novo antes de devolver: se a asserção
--    vencer no meio (validade de até 60 s), a função falha e a transação é desfeita. As de
--    leitura (contexto_atual_v1, dashboard_v1) conferem uma vez.
--    Nenhuma recebe conta, subject ou responsável: tudo vem do contexto.
-- ===========================================================================
CREATE FUNCTION folha.contexto_atual_v1()
RETURNS TABLE (account_id uuid, legal_entity_id uuid, branch_id uuid, subject_id uuid)
LANGUAGE sql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
  SELECT c.account_id, c.legal_entity_id, c.branch_id, c.subject_id FROM folha.contexto_v1('folha.read') AS c;
$function$;

CREATE FUNCTION folha.dashboard_v1()
RETURNS TABLE (
  total_empregados_ativos integer,
  custo_folha_mes_centavos bigint,
  encargos_patronais_mes_centavos bigint,
  competencias_abertas integer,
  competencias_fechadas_mes integer,
  distribuicao_regime jsonb,
  evolucao_custo_6m jsonb
)
LANGUAGE sql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
  SELECT d.total_empregados_ativos, d.custo_folha_mes_centavos, d.encargos_patronais_mes_centavos,
         d.competencias_abertas, d.competencias_fechadas_mes, d.distribuicao_regime, d.evolucao_custo_6m
    FROM folha.contexto_v1('folha.read') AS c
    CROSS JOIN LATERAL folha.dashboard_completo(c.account_id) AS d;
$function$;

CREATE FUNCTION folha.folha_abrir_v1(
  p_competencia date,
  p_tipo_processo text DEFAULT 'mensal',
  p_data_pagamento date DEFAULT NULL,
  p_employer_id uuid DEFAULT NULL,
  p_establishment_id uuid DEFAULT NULL,
  p_sequencia integer DEFAULT 1
) RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  v_ctx record;
  v_run_id uuid;
BEGIN
  SELECT c.account_id, c.legal_entity_id, c.branch_id, c.subject_id INTO v_ctx
    FROM folha.contexto_v1('folha.calculate') AS c;
  INSERT INTO folha.payroll_run (account_id, competencia, tipo_processo, data_pagamento,
                                 employer_id, establishment_id, sequencia, created_by)
  VALUES (v_ctx.account_id, p_competencia, COALESCE(p_tipo_processo, 'mensal'), p_data_pagamento,
          p_employer_id, p_establishment_id, COALESCE(p_sequencia, 1), v_ctx.subject_id::text)
  RETURNING run_id INTO v_run_id;
  INSERT INTO folha.auditoria (account_id, actor, actor_subject, acao, recurso, recurso_id, detalhe)
  VALUES (v_ctx.account_id, v_ctx.subject_id::text, v_ctx.subject_id, 'abrir_folha', 'payroll_run', v_run_id,
          jsonb_build_object('sessao', session_user, 'legal_entity_id', v_ctx.legal_entity_id, 'branch_id', v_ctx.branch_id));
  PERFORM 1 FROM folha.contexto_v1('folha.calculate');
  RETURN v_run_id;
END
$function$;

CREATE FUNCTION folha.folha_calcular_contrato_v1(
  p_run_id uuid,
  p_contract_id uuid,
  p_num_dependentes_irrf integer DEFAULT 0,
  p_num_filhos_salario_familia integer DEFAULT 0
) RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  v_result_id uuid;
BEGIN
  PERFORM 1 FROM folha.contexto_v1('folha.calculate');
  v_result_id := folha.run_payroll_employee(p_run_id, p_contract_id, p_num_dependentes_irrf, p_num_filhos_salario_familia);
  PERFORM 1 FROM folha.contexto_v1('folha.calculate');
  RETURN v_result_id;
END
$function$;

CREATE FUNCTION folha.folha_concluir_calculo_v1(p_run_id uuid) RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  PERFORM 1 FROM folha.contexto_v1('folha.calculate');
  PERFORM folha.payroll_run_concluir_calculo(p_run_id);
  PERFORM 1 FROM folha.contexto_v1('folha.calculate');
END
$function$;

CREATE FUNCTION folha.folha_liberar_pendencia_v1(p_run_id uuid, p_codigo text, p_motivo text) RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  v_subject uuid;
  v_n integer;
BEGIN
  SELECT c.subject_id INTO v_subject FROM folha.contexto_v1('folha.close') AS c;
  v_n := folha.payroll_pendencias_liberar(p_run_id, p_codigo, v_subject::text, p_motivo);
  PERFORM 1 FROM folha.contexto_v1('folha.close');
  RETURN v_n;
END
$function$;

CREATE FUNCTION folha.folha_aprovar_v1(p_run_id uuid) RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  v_subject uuid;
BEGIN
  SELECT c.subject_id INTO v_subject FROM folha.contexto_v1('folha.close') AS c;
  PERFORM folha.payroll_run_aprovar(p_run_id, v_subject::text);
  PERFORM 1 FROM folha.contexto_v1('folha.close');
END
$function$;

CREATE FUNCTION folha.folha_fechar_v1(p_run_id uuid) RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  v_subject uuid;
BEGIN
  SELECT c.subject_id INTO v_subject FROM folha.contexto_v1('folha.close') AS c;
  PERFORM folha.payroll_run_fechar(p_run_id, v_subject::text);
  PERFORM 1 FROM folha.contexto_v1('folha.close');
END
$function$;

-- Cancelar folha ainda não fechada (folha.close). É a saída das mensagens "cancele e recalcule".
CREATE FUNCTION folha.folha_cancelar_v1(p_run_id uuid, p_motivo text) RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx record;
  v_status text;
BEGIN
  SELECT c.account_id, c.legal_entity_id, c.branch_id, c.subject_id INTO v_ctx
    FROM folha.contexto_v1('folha.close') AS c;
  IF btrim(COALESCE(p_motivo, '')) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'folha_cancelar_v1: motivo obrigatório';
  END IF;
  SELECT r.status INTO v_status FROM folha.payroll_run r
   WHERE r.run_id = p_run_id AND r.account_id = v_ctx.account_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Folha % não encontrada', p_run_id;
  END IF;
  -- A trava da 0027 recusa cancelar folha fechada ou já cancelada.
  UPDATE folha.payroll_run r SET status = 'cancelled', updated_at = now()
   WHERE r.run_id = p_run_id AND r.account_id = v_ctx.account_id;
  INSERT INTO folha.auditoria (account_id, actor, actor_subject, acao, recurso, recurso_id, detalhe)
  VALUES (v_ctx.account_id, v_ctx.subject_id::text, v_ctx.subject_id, 'cancelar_folha', 'payroll_run', p_run_id,
          jsonb_build_object('estado_anterior', v_status, 'motivo', btrim(p_motivo), 'sessao', session_user,
                             'legal_entity_id', v_ctx.legal_entity_id, 'branch_id', v_ctx.branch_id));
  PERFORM 1 FROM folha.contexto_v1('folha.close');
END
$function$;

CREATE FUNCTION folha.folha_transmitir_v1(p_run_id uuid)
RETURNS TABLE (esocial_events_dispatched integer, contabil_events_dispatched integer)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
#variable_conflict use_column
DECLARE
  v_d record;
BEGIN
  PERFORM 1 FROM folha.contexto_v1('folha.transmit');
  SELECT d.esocial_events_dispatched, d.contabil_events_dispatched INTO v_d
    FROM folha.dispatch_folha_completa(p_run_id) AS d;
  PERFORM 1 FROM folha.contexto_v1('folha.transmit');
  esocial_events_dispatched := v_d.esocial_events_dispatched;
  contabil_events_dispatched := v_d.contabil_events_dispatched;
  RETURN NEXT;
END
$function$;

CREATE FUNCTION folha.segregacao_definir_v1(p_calculo_x_fechamento boolean) RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx record;
BEGIN
  IF p_calculo_x_fechamento IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'segregacao_definir_v1: informe true ou false';
  END IF;
  SELECT c.account_id, c.legal_entity_id, c.branch_id, c.subject_id INTO v_ctx
    FROM folha.contexto_v1('folha.admin') AS c;
  INSERT INTO folha.segregation_config AS s (account_id, calculo_x_fechamento, definido_por_subject, definido_em)
  VALUES (v_ctx.account_id, p_calculo_x_fechamento, v_ctx.subject_id, now())
  ON CONFLICT (account_id) DO UPDATE
    SET calculo_x_fechamento = EXCLUDED.calculo_x_fechamento,
        definido_por_subject = EXCLUDED.definido_por_subject,
        definido_em = EXCLUDED.definido_em;
  INSERT INTO folha.auditoria (account_id, actor, actor_subject, acao, recurso, recurso_id, detalhe)
  VALUES (v_ctx.account_id, v_ctx.subject_id::text, v_ctx.subject_id, 'definir_segregacao', 'segregation_config', NULL,
          jsonb_build_object('calculo_x_fechamento', p_calculo_x_fechamento, 'sessao', session_user,
                             'legal_entity_id', v_ctx.legal_entity_id, 'branch_id', v_ctx.branch_id));
  PERFORM 1 FROM folha.contexto_v1('folha.admin');
END
$function$;

-- ===========================================================================
-- 6. ACL
--    Funções: tira o EXECUTE de todo papel que não seja o dono (inclusive default ACL e
--    concessão feita direto no banco) e concede só o pretendido. As internas e as de gatilho
--    não são concedidas a ninguém.
--    Tabela nova: só leitura para worker e data_owner (a gravação é pela função).
-- ===========================================================================
-- dnex_gestao_api passa a ter USAGE no schema: tudo o que PUBLIC executa nele ficaria ao alcance
-- da sessao de aplicacao. A unica funcao nessa situacao e a do gatilho da auditoria (0014), que
-- nao e chamavel diretamente; o EXECUTE de PUBLIC sai mesmo assim (o gatilho nao depende dele).
REVOKE ALL ON FUNCTION folha.bloquear_mutacao_auditoria() FROM PUBLIC, anon, authenticated, service_role;
GRANT USAGE ON SCHEMA folha TO dnex_gestao_api;

DO $$
DECLARE
  v_item text[];
  v_papel text;
BEGIN
  FOREACH v_item SLICE 1 IN ARRAY ARRAY[
    ['folha.contexto_v1(text)',                                         ''],
    ['folha.segregacao_conferir(uuid, uuid, uuid)',                     ''],
    ['folha.payroll_run_identidade()',                                  ''],
    ['folha.payroll_result_identidade()',                               ''],
    ['folha.contexto_atual_v1()',                                       'dnex_gestao_api'],
    ['folha.dashboard_v1()',                                            'dnex_gestao_api'],
    ['folha.folha_abrir_v1(date, text, date, uuid, uuid, integer)',     'dnex_gestao_api'],
    ['folha.folha_calcular_contrato_v1(uuid, uuid, integer, integer)',  'dnex_gestao_api'],
    ['folha.folha_concluir_calculo_v1(uuid)',                           'dnex_gestao_api'],
    ['folha.folha_liberar_pendencia_v1(uuid, text, text)',              'dnex_gestao_api'],
    ['folha.folha_aprovar_v1(uuid)',                                    'dnex_gestao_api'],
    ['folha.folha_fechar_v1(uuid)',                                     'dnex_gestao_api'],
    ['folha.folha_cancelar_v1(uuid, text)',                             'dnex_gestao_api'],
    ['folha.folha_transmitir_v1(uuid)',                                 'dnex_gestao_api'],
    ['folha.segregacao_definir_v1(boolean)',                            'dnex_gestao_api']
  ]
  LOOP
    FOR v_papel IN
      SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(r.rolname) END
        FROM pg_catalog.pg_proc p
        CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
        LEFT JOIN pg_catalog.pg_roles r ON r.oid = a.grantee
       WHERE p.oid = v_item[1]::regprocedure AND a.grantee <> p.proowner
       GROUP BY 1
    LOOP
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM %s', v_item[1], v_papel);
    END LOOP;
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated, service_role', v_item[1]);
    IF v_item[2] <> '' THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %s', v_item[1], v_item[2]);
    END IF;
  END LOOP;

  FOR v_papel IN
    SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(r.rolname) END
      FROM pg_catalog.pg_class c
      CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) a
      LEFT JOIN pg_catalog.pg_roles r ON r.oid = a.grantee
     WHERE c.oid = 'folha.segregation_config'::regclass AND a.grantee <> c.relowner
     GROUP BY 1
  LOOP
    EXECUTE format('REVOKE ALL ON folha.segregation_config FROM %s', v_papel);
  END LOOP;
  REVOKE ALL ON folha.segregation_config FROM PUBLIC, anon, authenticated, service_role;
  GRANT SELECT ON folha.segregation_config TO dnex_gestao_folha_worker, dnex_gestao_data_owner;
END
$$;

-- ---------------------------------------------------------------------------
-- 6.1 search_path terminado em pg_temp em toda função do schema folha que fixa search_path
--     (inclusive as das migrations 0014 a 0027, que ficam ao alcance por dentro das _v1, e as
--     SECURITY INVOKER chamadas de dentro de função SECURITY DEFINER, como current_account_id).
--     O valor gravado é o mesmo de antes, com ", pg_temp" no fim.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v record;
BEGIN
  FOR v IN
    SELECT p.oid::regprocedure::text AS sig, substr(cfg, 13) AS caminho
      FROM pg_catalog.pg_proc p
      CROSS JOIN LATERAL unnest(p.proconfig) AS cfg
     WHERE p.pronamespace = 'folha'::regnamespace
       AND cfg LIKE 'search_path=%'
       AND cfg !~ ',\s*pg_temp$'
  LOOP
    -- Só sabe tratar caminho que começa por pg_catalog e ainda não cita pg_temp (é o caso de
    -- todas as funções deste repositório). Função criada fora dele com outro caminho: aborta.
    IF v.caminho !~ '^pg_catalog(,|$)' OR v.caminho ~ 'pg_temp' THEN
      RAISE EXCEPTION '0028: % tem search_path "%": corrija à mão (pg_catalog primeiro, pg_temp só no fim)', v.sig, v.caminho
        USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;
    EXECUTE format('ALTER FUNCTION %s SET search_path = %s, pg_temp', v.sig, v.caminho);
  END LOOP;
END
$$;

-- ---------------------------------------------------------------------------
-- 7. Pós-voo (falha fechada): o que dnex_gestao_api alcança no schema folha é exatamente o
--    pretendido, e nenhuma tabela.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_inesperado text;
BEGIN
  SELECT string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text) INTO v_inesperado
    FROM pg_catalog.pg_proc p
   WHERE p.pronamespace = 'folha'::regnamespace
     AND has_function_privilege('dnex_gestao_api', p.oid, 'EXECUTE')
     AND p.oid::regprocedure::text NOT IN (
       'folha.contexto_atual_v1()', 'folha.dashboard_v1()',
       'folha.folha_abrir_v1(date,text,date,uuid,uuid,integer)',
       'folha.folha_calcular_contrato_v1(uuid,uuid,integer,integer)',
       'folha.folha_concluir_calculo_v1(uuid)', 'folha.folha_liberar_pendencia_v1(uuid,text,text)',
       'folha.folha_aprovar_v1(uuid)', 'folha.folha_fechar_v1(uuid)', 'folha.folha_cancelar_v1(uuid,text)',
       'folha.folha_transmitir_v1(uuid)',
       'folha.segregacao_definir_v1(boolean)');
  IF v_inesperado IS NOT NULL THEN
    RAISE EXCEPTION '0028: dnex_gestao_api executa funções fora da lista: %', v_inesperado
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO v_inesperado
    FROM pg_catalog.pg_class c
   WHERE c.relnamespace = 'folha'::regnamespace AND c.relkind IN ('r', 'p', 'v', 'm', 'S')
     AND (has_table_privilege('dnex_gestao_api', c.oid, 'SELECT')
          OR (c.relkind <> 'S' AND has_table_privilege('dnex_gestao_api', c.oid, 'INSERT, UPDATE, DELETE, TRUNCATE')));
  IF v_inesperado IS NOT NULL THEN
    RAISE EXCEPTION '0028: dnex_gestao_api tem privilégio direto em: %', v_inesperado
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text) INTO v_inesperado
    FROM pg_catalog.pg_proc p
   WHERE p.pronamespace = 'folha'::regnamespace AND p.prosecdef
     AND NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) AS cfg
                      WHERE cfg ~ '^search_path=pg_catalog(,|$)' AND cfg ~ ',\s*pg_temp$' AND cfg !~ 'pg_temp.*pg_temp');
  IF v_inesperado IS NOT NULL THEN
    RAISE EXCEPTION '0028: função SECURITY DEFINER cujo search_path não começa por pg_catalog e termina em pg_temp (só no fim): %', v_inesperado
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF has_function_privilege('dnex_gestao_folha_worker', 'folha.contexto_v1(text)', 'EXECUTE')
     OR has_function_privilege('dnex_gestao_api', 'folha.contexto_v1(text)', 'EXECUTE') THEN
    RAISE EXCEPTION '0028: folha.contexto_v1 é interna e ficou executável por papel de aplicação'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
END
$$;

COMMIT;
