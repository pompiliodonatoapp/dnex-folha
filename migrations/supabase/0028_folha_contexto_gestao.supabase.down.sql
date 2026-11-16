-- DNEX Folha — Reversão da migration 0028.
--
-- AVISO: esta reversão devolve a conta da sessão à leitura da 0025, que aceita QUALQUER
-- contexto do grupo api (um contexto financeiro comum, sem direito à Folha, recebe a conta),
-- devolve os geradores e o despacho ao estado sem filtro de conta e sem permissão, e apaga a
-- identidade (subject) gravada em folha, resultado, pendência e auditoria. Use só para
-- desfazer uma aplicação que deu errado, e reaplique a 0028 corrigida em seguida. Não é um
-- estado para operar.
--
-- Recusa (SQLSTATE 55000) se já houver identidade gravada ou segregação configurada: os dados
-- teriam de ser exportados antes (a auditoria não aceita DELETE: limpar exige desligar o
-- gatilho dela, como superusuário, de propósito). A contagem roda com row_security = off para não ser
-- enganada pela RLS; se o papel não ignorar RLS, a reversão falha em vez de apagar sem ver.
-- Os corpos restaurados são cópia dos das migrations 0018, 0020, 0025 e 0027.
BEGIN;

SET LOCAL lock_timeout = '5s';
SET LOCAL row_security = off;

DO $$
BEGIN
  IF to_regclass('folha.portal_employee_access') IS NOT NULL OR to_regnamespace('portal_api') IS NOT NULL THEN
    RAISE EXCEPTION '0028 (reversão): a migration 0029 (Portal) está aplicada e depende desta; reverta a 0029 antes'
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  IF EXISTS (SELECT 1 FROM folha.payroll_run
              WHERE calculado_por_subject IS NOT NULL OR aprovado_por_subject IS NOT NULL OR fechado_por_subject IS NOT NULL)
     OR EXISTS (SELECT 1 FROM folha.payroll_result WHERE calculado_por_subject IS NOT NULL)
     OR EXISTS (SELECT 1 FROM folha.payroll_pendency WHERE liberada_por_subject IS NOT NULL)
     OR EXISTS (SELECT 1 FROM folha.auditoria WHERE actor_subject IS NOT NULL)
     OR EXISTS (SELECT 1 FROM folha.segregation_config)
  THEN
    RAISE EXCEPTION '0028 (reversão): há identidade (subject) gravada ou segregação configurada; exporte antes de reverter'
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
END
$$;

-- 0. search_path: tira o ", pg_temp" que a 0028 acrescentou às funções do schema folha.
DO $$
DECLARE
  v record;
BEGIN
  FOR v IN
    SELECT p.oid::regprocedure::text AS sig, regexp_replace(substr(cfg, 13), ',\s*pg_temp$', '') AS caminho
      FROM pg_catalog.pg_proc p
      CROSS JOIN LATERAL unnest(p.proconfig) AS cfg
     WHERE p.pronamespace = 'folha'::regnamespace
       AND cfg LIKE 'search_path=%'
       AND cfg ~ ',\s*pg_temp$'
  LOOP
    EXECUTE format('ALTER FUNCTION %s SET search_path = %s', v.sig, v.caminho);
  END LOOP;
END
$$;

-- 1. Funções da sessão de aplicação
DROP FUNCTION folha.segregacao_definir_v1(boolean);
DROP FUNCTION folha.folha_transmitir_v1(uuid);
DROP FUNCTION folha.folha_cancelar_v1(uuid, text);
DROP FUNCTION folha.folha_fechar_v1(uuid);
DROP FUNCTION folha.folha_aprovar_v1(uuid);
DROP FUNCTION folha.folha_liberar_pendencia_v1(uuid, text, text);
DROP FUNCTION folha.folha_concluir_calculo_v1(uuid);
DROP FUNCTION folha.folha_calcular_contrato_v1(uuid, uuid, integer, integer);
DROP FUNCTION folha.folha_abrir_v1(date, text, date, uuid, uuid, integer);
DROP FUNCTION folha.dashboard_v1();
DROP FUNCTION folha.contexto_atual_v1();
REVOKE USAGE ON SCHEMA folha FROM dnex_gestao_api;
GRANT EXECUTE ON FUNCTION folha.bloquear_mutacao_auditoria() TO PUBLIC;   -- como a 0014 deixou

-- 2. Gatilhos de identidade
DROP TRIGGER trg_payroll_result_z_identidade ON folha.payroll_result;
DROP FUNCTION folha.payroll_result_identidade();
DROP TRIGGER trg_payroll_run_z_identidade ON folha.payroll_run;
DROP FUNCTION folha.payroll_run_identidade();

-- 3. Corpos anteriores (CREATE OR REPLACE preserva dono e ACL)
-- 3.1 da 0027
CREATE OR REPLACE FUNCTION folha.run_payroll_employee(
  p_run_id uuid,
  p_contract_id uuid,
  p_num_dependentes_irrf integer DEFAULT 0,
  p_num_filhos_salario_familia integer DEFAULT 0
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, folha
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
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_conta uuid := folha.current_account_id();
  v_status text;
  v_n integer;
BEGIN
  IF v_conta IS NULL THEN
    RAISE EXCEPTION 'payroll_run_concluir_calculo: sessão sem conta (contexto não aberto)';
  END IF;
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

CREATE OR REPLACE FUNCTION folha.payroll_pendencias_liberar(
  p_run_id uuid,
  p_codigo text,
  p_responsavel text,
  p_motivo text
) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_conta uuid := folha.current_account_id();
  v_status text;
  v_n integer;
BEGIN
  IF v_conta IS NULL THEN
    RAISE EXCEPTION 'payroll_pendencias_liberar: sessão sem conta (contexto não aberto)';
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
  UPDATE folha.payroll_pendency p
     SET liberada_em = now(), liberada_por = btrim(p_responsavel),
         liberada_sessao = session_user, liberacao_motivo = btrim(p_motivo)
   WHERE p.account_id = v_conta AND p.run_id = p_run_id AND p.codigo = p_codigo AND p.liberada_em IS NULL;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN
    RAISE EXCEPTION 'Folha % não tem pendência aberta com o código %', p_run_id, p_codigo;
  END IF;
  INSERT INTO folha.auditoria (account_id, actor, acao, recurso, recurso_id, detalhe)
  VALUES (v_conta, btrim(p_responsavel), 'liberar_pendencia', 'payroll_run', p_run_id,
          jsonb_build_object('codigo', p_codigo, 'motivo', btrim(p_motivo), 'pendencias', v_n, 'sessao', session_user));
  RETURN v_n;
END;
$$;

CREATE OR REPLACE FUNCTION folha.payroll_run_aprovar(p_run_id uuid, p_responsavel text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_conta uuid := folha.current_account_id();
  v_status text;
BEGIN
  IF v_conta IS NULL THEN
    RAISE EXCEPTION 'payroll_run_aprovar: sessão sem conta (contexto não aberto)';
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
  UPDATE folha.payroll_run r
     SET status = 'approved', aprovado_em = now(), approved_by = btrim(p_responsavel), updated_at = now()
   WHERE r.run_id = p_run_id AND r.account_id = v_conta;
  INSERT INTO folha.auditoria (account_id, actor, acao, recurso, recurso_id, detalhe)
  VALUES (v_conta, btrim(p_responsavel), 'aprovar_folha', 'payroll_run', p_run_id, jsonb_build_object('sessao', session_user));
END;
$$;

CREATE OR REPLACE FUNCTION folha.payroll_run_fechar(p_run_id uuid, p_responsavel text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_conta uuid := folha.current_account_id();
  v_status text;
BEGIN
  IF v_conta IS NULL THEN
    RAISE EXCEPTION 'payroll_run_fechar: sessão sem conta (contexto não aberto)';
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
  UPDATE folha.payroll_run r
     SET status = 'closed', fechado_em = now(), updated_at = now()
   WHERE r.run_id = p_run_id AND r.account_id = v_conta;
  INSERT INTO folha.auditoria (account_id, actor, acao, recurso, recurso_id, detalhe)
  VALUES (v_conta, btrim(p_responsavel), 'fechar_folha', 'payroll_run', p_run_id, jsonb_build_object('sessao', session_user));
END;
$$;

CREATE OR REPLACE FUNCTION folha.dispatch_folha_completa(
  p_run_id uuid
) RETURNS TABLE (
  esocial_events_dispatched integer,
  contabil_events_dispatched integer
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_result record;
  v_esocial_count integer := 0;
  v_contabil_count integer := 0;
  v_competencia date;
  v_status text;
  v_abertas integer;
BEGIN
  SELECT competencia, status INTO v_competencia, v_status
  FROM folha.payroll_run
  WHERE run_id = p_run_id;

  IF v_competencia IS NULL THEN
    RAISE EXCEPTION 'payroll_run % não encontrado', p_run_id;
  END IF;
  IF v_status <> 'closed' THEN
    RAISE EXCEPTION 'Folha % está em % e não pode ser despachada: só folha fechada gera eventos', p_run_id, v_status;
  END IF;
  SELECT count(*) INTO v_abertas
    FROM folha.payroll_pendency p WHERE p.run_id = p_run_id AND p.liberada_em IS NULL;
  IF v_abertas > 0 THEN
    RAISE EXCEPTION 'Folha % tem % pendência(s) sem liberação e não pode ser despachada', p_run_id, v_abertas;
  END IF;

  FOR v_result IN
    SELECT result_id FROM folha.payroll_result WHERE run_id = p_run_id
  LOOP
    -- Dispatch eSocial S-1200
    PERFORM folha.dispatch_esocial_event(
      p_run_id,
      v_result.result_id,
      'S-1200',
      v_competencia,
      folha.build_esocial_s1200(v_result.result_id),
      NULL
    );
    v_esocial_count := v_esocial_count + 1;

    -- Dispatch contábil
    PERFORM folha.dispatch_accounting_event(
      p_run_id,
      v_result.result_id,
      'folha_mensal',
      folha.build_contabil_folha(v_result.result_id)
    );
    v_contabil_count := v_contabil_count + 1;
  END LOOP;

  esocial_events_dispatched := v_esocial_count;
  contabil_events_dispatched := v_contabil_count;
  RETURN NEXT;
END;
$$;

-- 3.2 da 0020
CREATE OR REPLACE FUNCTION folha.build_esocial_s1200(
  p_result_id uuid
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_result record;
  v_employee record;
  v_contract record;
  v_payload jsonb;
BEGIN
  SELECT pr.*, pr.run_id INTO v_result
  FROM folha.payroll_result pr
  WHERE pr.result_id = p_result_id;

  IF v_result.result_id IS NULL THEN
    RAISE EXCEPTION 'payroll_result % não encontrado', p_result_id;
  END IF;

  SELECT e.* INTO v_employee
  FROM folha.employee e
  WHERE e.employee_id = v_result.employee_id;

  SELECT c.* INTO v_contract
  FROM folha.employment_contract c
  WHERE c.contract_id = v_result.contract_id;

  v_payload := jsonb_build_object(
    'evento', 'S-1200',
    'versao_leiaute', 'S-1.3',
    'competencia', (SELECT competencia FROM folha.payroll_run WHERE run_id = v_result.run_id),
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
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_employee record;
  v_contract record;
  v_payload jsonb;
BEGIN
  SELECT c.* INTO v_contract
  FROM folha.employment_contract c
  WHERE c.contract_id = p_contract_id;

  IF v_contract.contract_id IS NULL THEN
    RAISE EXCEPTION 'employment_contract % não encontrado', p_contract_id;
  END IF;

  SELECT e.* INTO v_employee
  FROM folha.employee e
  WHERE e.employee_id = v_contract.employee_id;

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
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_result record;
  v_lancamentos jsonb := '[]'::jsonb;
BEGIN
  SELECT pr.*, r.competencia INTO v_result
  FROM folha.payroll_result pr
  JOIN folha.payroll_run r ON r.run_id = pr.run_id
  WHERE pr.result_id = p_result_id;

  IF v_result.result_id IS NULL THEN
    RAISE EXCEPTION 'payroll_result % não encontrado', p_result_id;
  END IF;

  -- Débito: Despesa com salários (proventos)
  v_lancamentos := v_lancamentos || jsonb_build_array(jsonb_build_object(
    'conta_debito', '3.2.1.01.001',
    'conta_credito', NULL,
    'valor', v_result.total_proventos,
    'historico', 'Folha pagamento competência ' || v_result.competencia::text,
    'tipo', 'despesa_salario'
  ));

  -- Crédito: Salários a pagar (líquido)
  v_lancamentos := v_lancamentos || jsonb_build_array(jsonb_build_object(
    'conta_debito', NULL,
    'conta_credito', '2.1.5.01.001',
    'valor', v_result.liquido,
    'historico', 'Salários a pagar competência ' || v_result.competencia::text,
    'tipo', 'passivo_salario'
  ));

  -- Crédito: INSS empregado a recolher
  IF v_result.inss_empregado > 0 THEN
    v_lancamentos := v_lancamentos || jsonb_build_array(jsonb_build_object(
      'conta_debito', NULL,
      'conta_credito', '2.1.5.02.001',
      'valor', v_result.inss_empregado,
      'historico', 'INSS empregado a recolher ' || v_result.competencia::text,
      'tipo', 'passivo_inss_empregado'
    ));
  END IF;

  -- Crédito: IRRF a recolher
  IF v_result.irrf > 0 THEN
    v_lancamentos := v_lancamentos || jsonb_build_array(jsonb_build_object(
      'conta_debito', NULL,
      'conta_credito', '2.1.5.03.001',
      'valor', v_result.irrf,
      'historico', 'IRRF a recolher ' || v_result.competencia::text,
      'tipo', 'passivo_irrf'
    ));
  END IF;

  -- Débito: FGTS encargo patronal (informativo, não desconta empregado)
  IF v_result.fgts > 0 THEN
    v_lancamentos := v_lancamentos || jsonb_build_array(jsonb_build_object(
      'conta_debito', '3.2.1.02.001',
      'conta_credito', '2.1.5.04.001',
      'valor', v_result.fgts,
      'historico', 'FGTS a depositar ' || v_result.competencia::text,
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

-- 3.3 da 0018
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

-- 3.4 da 0025
CREATE OR REPLACE FUNCTION folha.request_context_account_id() RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, gestao_auth
SET row_security = on
AS $function$
DECLARE
  v_nonce_text text;
  v_txid bigint;
  v_contexto record;
  v_grupos text[];
BEGIN
  v_nonce_text := NULLIF(pg_catalog.current_setting('dnex.context_nonce', true), '');
  IF v_nonce_text IS NULL
     OR v_nonce_text !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN
    RETURN NULL;
  END IF;

  -- begin_request usa txid_current(): transação sem xid atribuído não tem contexto.
  v_txid := pg_catalog.txid_current_if_assigned();
  IF v_txid IS NULL THEN
    RETURN NULL;
  END IF;

  SELECT context.account_id, context.legal_entity_id, context.branch_id, context.principal_group
    INTO v_contexto
    FROM gestao_auth.request_context AS context
    JOIN gestao_auth.access_assertion AS assertion
      ON assertion.assertion_id = context.assertion_id
   WHERE context.context_nonce = v_nonce_text::uuid
     AND context.runtime_session_user = session_user
     AND context.backend_pid = pg_catalog.pg_backend_pid()
     AND context.transaction_id = v_txid
     AND context.created_at <= pg_catalog.statement_timestamp()
     AND context.expires_at > pg_catalog.statement_timestamp()
     AND assertion.runtime_session_user = context.runtime_session_user
     AND assertion.subject_id = context.subject_id
     AND assertion.subject_type = context.subject_type
     AND assertion.principal_group = context.principal_group
     AND assertion.account_id = context.account_id
     AND assertion.legal_entity_id = context.legal_entity_id
     AND assertion.branch_id = context.branch_id
     AND assertion.permissions = context.permissions
     AND assertion.consumed_at = context.created_at
     AND assertion.revoked_at IS NULL
     AND assertion.expires_at > pg_catalog.statement_timestamp();

  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  -- Grupos aceitos: sem a linha de configuração, ninguém; NULL, qualquer grupo que passe
  -- nas validações do gestao; lista, só os grupos listados.
  SELECT cfg.principal_groups_permitidos INTO v_grupos
    FROM folha.request_context_config AS cfg
   WHERE cfg.singleton;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;
  IF v_grupos IS NOT NULL
     AND (v_contexto.principal_group = ANY (v_grupos)) IS NOT TRUE THEN
    RETURN NULL;
  END IF;

  BEGIN
    PERFORM gestao_auth.assert_authorization_principal_v1(session_user, v_contexto.principal_group);
  EXCEPTION WHEN insufficient_privilege THEN
    RETURN NULL;
  END;

  IF NOT COALESCE(gestao_auth.is_active_scope_v1(
       v_contexto.account_id, v_contexto.legal_entity_id, v_contexto.branch_id), false) THEN
    RETURN NULL;
  END IF;

  RETURN v_contexto.account_id;
END
$function$;

-- O EXECUTE de service_role em dispatch_folha_completa(uuid) vinha da 0022.
GRANT EXECUTE ON FUNCTION folha.dispatch_folha_completa(uuid) TO service_role;

-- 4. Segregação, identidade e contexto
DROP FUNCTION folha.segregacao_conferir(uuid, uuid, uuid);
DROP TABLE folha.segregation_config;
ALTER TABLE folha.auditoria DROP COLUMN actor_subject;
ALTER TABLE folha.payroll_pendency
  DROP CONSTRAINT payroll_pendency_subject_so_com_liberacao,
  DROP CONSTRAINT payroll_pendency_liberacao_identificada,
  DROP COLUMN liberada_por_subject;
ALTER TABLE folha.payroll_result DROP COLUMN calculado_por_subject;
ALTER TABLE folha.payroll_run
  DROP COLUMN fechado_por_subject,
  DROP COLUMN aprovado_por_subject,
  DROP COLUMN calculado_por_subject;
COMMENT ON COLUMN folha.payroll_run.approved_by IS NULL;
COMMENT ON COLUMN folha.payroll_pendency.liberada_por IS NULL;
DROP FUNCTION folha.contexto_v1(text);

-- 5. Configuração de grupos: volta ao NULL da 0025 (só a linha que a 0028 alterou).
UPDATE folha.request_context_config
   SET principal_groups_permitidos = NULL,
       observacao = 'Sem restrição de grupo até o dnex-gestao criar o grupo de principal da Folha; então gravar aqui o nome do grupo.',
       updated_at = now()
 WHERE singleton AND principal_groups_permitidos = ARRAY['api'];

COMMIT;
