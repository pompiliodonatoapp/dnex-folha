-- DNEX Folha — Testes pgTAP da migration 0032: camada que alimenta os geradores de XML do eSocial.
--
-- Cobre: tabelas oficiais como ESTRUTURA (só o que o XSD enumera, com fonte; o resto vazio), cadastro (restrições,
-- chaves compostas com conta, vigência sem sobreposição), RLS com FORCE e ACL exata (tabelas e funções), caminhos
-- felizes de S-1000, S-1005, S-1010, S-1020, S-1200, S-1210, S-2200, S-1298, S-1299 e S-3000, todos os negativos
-- (folha aberta, pendência, dado faltando, estagiário e PJ, S-3000 sem recibo, conta errada, sem permissão),
-- idempotência e hash de origem (sem o carimbo de emissão), retificação com o recibo vigente, subject gravado,
-- isolamento entre contas e imutabilidade do histórico. NÃO gera XML: a saída é o jsonb no contrato do gerador
-- (o script scripts/validar_entrada_eventos.mjs a valida contra o JSON Schema). Nomes, CPFs e inscrições são
-- SINTÉTICOS (os números dos fixtures do gerador, que têm dígito verificador calculado). Nada é persistido.
--
-- Como o arquivo roda: igual ao 0031. Superusuário no nível de cima; o que vale "para uma sessão de aplicação"
-- passa por pg_temp.pedido() (asserção com claim da Folha pelo caminho real, login de teste membro só de
-- dnex_gestao_api e begin_request). Devolve o resultado do último comando como texto, ou
-- 'ERRO <sqlstate>: <mensagem>'.
BEGIN;

SELECT plan(285);

\set A '''a0000000-0000-0000-0000-000000000032'''
\set B '''b0000000-0000-0000-0000-000000000032'''

-- ---------------------------------------------------------------------------
-- Apoio
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE escopo (conta uuid PRIMARY KEY, entidade uuid NOT NULL, filial uuid NOT NULL);
INSERT INTO escopo VALUES
  (:A, 'a1000000-0000-0000-0000-000000000032', 'a2000000-0000-0000-0000-000000000032'),
  (:B, 'b1000000-0000-0000-0000-000000000032', 'b2000000-0000-0000-0000-000000000032');
INSERT INTO gestao_finance.enterprise_scope_registry (account_id, legal_entity_id, branch_id)
SELECT conta, entidade, filial FROM escopo;

CREATE FUNCTION pg_temp.pedido(
  p_conta uuid, p_permissoes text[], p_subject uuid,
  p_persiste boolean, p_espelho boolean, p_sql text[]
) RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v_saida text;
  v_as uuid := gen_random_uuid();
  v_e record;
  i integer;
BEGIN
  BEGIN
    DELETE FROM gestao_auth.request_context WHERE backend_pid = pg_backend_pid();
    PERFORM set_config('dnex.context_nonce', '', true);
    IF p_espelho THEN
      PERFORM dnex_folha_ci_apoio.espelhar_worker();
    END IF;
    IF p_permissoes IS NOT NULL THEN
      SELECT * INTO STRICT v_e FROM escopo WHERE conta = p_conta;
      PERFORM dnex_folha_ci_apoio.emitir(v_as, p_conta, v_e.entidade, v_e.filial, p_permissoes, p_subject);
    END IF;
    SET LOCAL SESSION AUTHORIZATION dnex_folha_ci_login;
    IF p_permissoes IS NOT NULL THEN
      PERFORM gestao_auth.begin_request(v_as, gen_random_uuid(), gen_random_uuid());
    END IF;
    FOR i IN 1 .. array_length(p_sql, 1) - 1 LOOP
      EXECUTE p_sql[i];
    END LOOP;
    EXECUTE p_sql[array_length(p_sql, 1)] INTO v_saida;
    IF NOT p_persiste THEN
      RAISE EXCEPTION 'desfaz' USING ERRCODE = 'ZZ001';
    END IF;
    RESET SESSION AUTHORIZATION;
    IF p_espelho THEN
      PERFORM dnex_folha_ci_apoio.desfazer_espelho();
    END IF;
  EXCEPTION
    WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_saida := 'ERRO ' || SQLSTATE || ': ' || SQLERRM;
  END;
  RETURN v_saida;
END
$$;
CREATE FUNCTION pg_temp.le(p_conta uuid, p_permissoes text[], p_subject uuid, VARIADIC p_sql text[]) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.pedido(p_conta, p_permissoes, p_subject, false, false, p_sql) $$;
CREATE FUNCTION pg_temp.faz(p_conta uuid, p_permissoes text[], p_subject uuid, VARIADIC p_sql text[]) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.pedido(p_conta, p_permissoes, p_subject, true, false, p_sql) $$;
CREATE FUNCTION pg_temp.com_espelho(p_conta uuid, p_permissoes text[], p_subject uuid, VARIADIC p_sql text[]) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.pedido(p_conta, p_permissoes, p_subject, false, true, p_sql) $$;
CREATE FUNCTION pg_temp.todas() RETURNS text[] LANGUAGE sql AS $$
  SELECT ARRAY['folha.read', 'folha.calculate', 'folha.close', 'folha.transmit', 'folha.admin'] $$;
CREATE FUNCTION pg_temp.ca() RETURNS uuid LANGUAGE sql AS $$ SELECT 'a0000000-0000-0000-0000-000000000032'::uuid $$;
CREATE FUNCTION pg_temp.cb() RETURNS uuid LANGUAGE sql AS $$ SELECT 'b0000000-0000-0000-0000-000000000032'::uuid $$;
-- tx = todas as permissões, subject S_TX; lei_a = igual, sem persistir
CREATE FUNCTION pg_temp.tx_a(p_sql text) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.faz(pg_temp.ca(), pg_temp.todas(), '82000000-0000-0000-0000-000000000032'::uuid, p_sql) $$;
CREATE FUNCTION pg_temp.lei_a(p_sql text) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.le(pg_temp.ca(), pg_temp.todas(), '82000000-0000-0000-0000-000000000032'::uuid, p_sql) $$;
CREATE FUNCTION pg_temp.tx_b(p_sql text) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.faz(pg_temp.cb(), pg_temp.todas(), '84000000-0000-0000-0000-000000000032'::uuid, p_sql) $$;
CREATE FUNCTION pg_temp.close_a(p_sql text) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.faz(pg_temp.ca(), pg_temp.todas(), '83000000-0000-0000-0000-000000000032'::uuid, p_sql) $$;
-- só as permissões dadas (S_TX), persistindo
CREATE FUNCTION pg_temp.so(p_perm text[], p_sql text) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.faz(pg_temp.ca(), p_perm, '82000000-0000-0000-0000-000000000032'::uuid, p_sql) $$;

-- Executa um comando como superusuário numa subtransação desfeita e devolve 'OK' ou 'ERRO <sqlstate>'
CREATE FUNCTION pg_temp.tenta(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE p_sql;
    RAISE EXCEPTION 'desfaz' USING ERRCODE = 'ZZ001';
  EXCEPTION
    WHEN SQLSTATE 'ZZ001' THEN RETURN 'OK';
    WHEN OTHERS THEN RETURN 'ERRO ' || SQLSTATE;
  END;
END $$;

CREATE TEMP TABLE ids (k text PRIMARY KEY, id uuid NOT NULL, conta uuid NOT NULL);
CREATE TEMP TABLE saida (k text PRIMARY KEY, v text);
CREATE FUNCTION pg_temp.id(p_k text) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v uuid;
BEGIN
  SELECT id INTO STRICT v FROM ids WHERE k = p_k;
  RETURN v;
END $$;
CREATE FUNCTION pg_temp.conta_de(p_k text) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v uuid;
BEGIN
  SELECT conta INTO STRICT v FROM ids WHERE k = p_k;
  RETURN v;
END $$;
CREATE FUNCTION pg_temp.ger() RETURNS text LANGUAGE sql AS $$ SELECT '2026-11-18 09:00:00'::text $$;

-- Guarda o resultado (texto) e, se for jsonb com event_id, o id do evento sob a mesma chave
CREATE FUNCTION pg_temp.guarda(p_k text, p_v text, p_conta uuid DEFAULT NULL) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO saida VALUES (p_k, p_v) ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v;
  IF p_v NOT LIKE 'ERRO%' AND p_v LIKE '{%' THEN
    v_id := (p_v::jsonb ->> 'event_id')::uuid;
    IF v_id IS NOT NULL THEN
      INSERT INTO ids VALUES (p_k, v_id, COALESCE(p_conta, pg_temp.ca())) ON CONFLICT (k) DO UPDATE SET id = EXCLUDED.id;
    END IF;
  END IF;
  RETURN p_v;
END $$;
CREATE FUNCTION pg_temp.j(p_k text) RETURNS jsonb LANGUAGE sql AS $$ SELECT v::jsonb FROM saida WHERE k = p_k $$;
CREATE FUNCTION pg_temp.est(p_k text) RETURNS text LANGUAGE sql AS $$ SELECT v::jsonb ->> 'estado' FROM saida WHERE k = p_k $$;
CREATE FUNCTION pg_temp.blq(p_k text) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(b ->> 'codigo', ',' ORDER BY b ->> 'codigo') FROM saida s, jsonb_array_elements(s.v::jsonb -> 'bloqueios') b WHERE s.k = p_k $$;
CREATE FUNCTION pg_temp.falt(p_k text) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(f, ',' ORDER BY f) FROM saida s, jsonb_array_elements_text(s.v::jsonb -> 'faltando') f WHERE s.k = p_k $$;
CREATE FUNCTION pg_temp.pend(p_k text) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(p ->> 'caminho', ',' ORDER BY p ->> 'caminho') FROM saida s, jsonb_array_elements(s.v::jsonb -> 'pendencias') p WHERE s.k = p_k $$;
CREATE FUNCTION pg_temp.erro(p_k text) RETURNS text LANGUAGE sql AS $$ SELECT left(v, 11) FROM saida WHERE k = p_k $$;

-- ---------------------------------------------------------------------------
-- Cenário sintético (superusuário; gatilhos de folha desligados só onde a 0031 também desliga)
-- ---------------------------------------------------------------------------
-- Empregador completo (CNPJ do fixture do gerador), com estabelecimento, lotação, regime e cadastros do eSocial.
CREATE FUNCTION pg_temp.empregador(p_k text, p_conta uuid, p_cnpj text, p_completo boolean) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  v_emp uuid; v_est uuid; v_lot uuid;
BEGIN
  INSERT INTO folha.employer (account_id, tipo_inscricao, inscricao, razao_social, classificacao_tributaria, natureza_juridica)
  VALUES (p_conta, 'cnpj', p_cnpj, 'Empresa Sintetica ' || p_k, NULL, '206-2') RETURNING employer_id INTO v_emp;
  INSERT INTO folha.employer_regime (account_id, employer_id, vigencia_inicio, regime_tributario)
  VALUES (p_conta, v_emp, '2024-01-01', 'lucro_presumido');
  INSERT INTO folha.establishment (account_id, employer_id, tipo_inscricao, inscricao, cnae_preponderante)
  VALUES (p_conta, v_emp, 'cnpj', p_cnpj, '6201501') RETURNING establishment_id INTO v_est;
  INSERT INTO folha.tax_allocation (account_id, employer_id, establishment_id, codigo_lotacao, tipo_lotacao)
  VALUES (p_conta, v_emp, v_est, 'LOT-SINT-01', '01') RETURNING allocation_id INTO v_lot;
  INSERT INTO ids VALUES (p_k, v_emp, p_conta), (p_k || '.est', v_est, p_conta), (p_k || '.lot', v_lot, p_conta);
  IF p_completo THEN
    INSERT INTO folha.employer_esocial (account_id, employer_id, vigencia_inicio, vigencia_fim, class_trib, ind_coop, ind_constr,
                                        ind_des_folha, ind_porte, ind_opt_reg_eletron)
    VALUES (p_conta, v_emp, '2026-01-01', '2026-10-01', '99', 0, 0, 0, true, 0);
    INSERT INTO folha.establishment_fap (account_id, establishment_id, vigencia_inicio, fap, fap_origem)
    VALUES (p_conta, v_est, '2026-01-01', 1.0500, 'fixture sintetico');
    INSERT INTO folha.establishment_esocial (account_id, establishment_id, vigencia_inicio, vigencia_fim, aliq_rat)
    VALUES (p_conta, v_est, '2026-01-01', '2026-10-01', 2);
    INSERT INTO folha.tax_allocation_detail (account_id, allocation_id, vigencia_inicio, vigencia_fim, fpas, codigo_terceiros)
    VALUES (p_conta, v_lot, '2026-01-01', '2026-10-31', '507', '0000');
    INSERT INTO folha.rubric_esocial_config (account_id, employer_id, code_id, cod_rubr, ide_tab_rubr, vigencia_inicio, ind_apur_ir)
    SELECT p_conta, v_emp, c.code_id, x.cod_rubr, 'DNEX01', '2026-01-01', 0
      FROM (VALUES ('SALARIO_BASE', 'SALARIO'), ('INSS_EMPREGADO', 'INSS'), ('IRRF', 'IRRF')) AS x(codigo, cod_rubr)
      JOIN folha.earning_deduction_code c ON c.account_id IS NULL AND c.codigo = x.codigo;
  END IF;
END $$;

-- Colaborador: trabalhador + contrato (+ cadastro do eSocial e rateio 100% na lotação, se p_completo)
CREATE FUNCTION pg_temp.colab(p_k text, p_emp_k text, p_regime text, p_cpf text, p_mat text, p_completo boolean) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  v_acc uuid := pg_temp.conta_de(p_emp_k);
  v_trab uuid; v_cid uuid;
BEGIN
  INSERT INTO folha.employee (account_id, cpf, nome_completo, data_nascimento, sexo, employer_id)
  VALUES (v_acc, p_cpf, 'Trabalhador Sintetico ' || p_k, '1990-05-20', 'F', pg_temp.id(p_emp_k)) RETURNING employee_id INTO v_trab;
  INSERT INTO folha.employment_contract (account_id, employee_id, data_admissao, cargo, salario_base, regime_trabalho, jornada_semanal,
                                         employer_id, establishment_id)
  VALUES (v_acc, v_trab, '2026-01-05', 'Auxiliar administrativo', 3000.00, p_regime, 44, pg_temp.id(p_emp_k), pg_temp.id(p_emp_k || '.est'))
  RETURNING contract_id INTO v_cid;
  INSERT INTO ids VALUES (p_k, v_cid, v_acc), (p_k || '.trab', v_trab, v_acc);
  IF p_completo THEN
    INSERT INTO folha.employee_esocial (account_id, employee_id, raca_cor, grau_instr, pais_nascto, pais_nac, tp_lograd, dsc_lograd,
                                        nr_lograd, cep, cod_munic, uf)
    VALUES (v_acc, v_trab, 3, '07', '105', '105', 'R', 'Rua Sintetica', '100', '40000000', '2927408', 'BA');
    INSERT INTO folha.contract_esocial (account_id, employer_id, contract_id, matricula, cod_categ, tp_reg_prev, cad_ini, ind_admissao,
                                        tp_reg_jor, nat_atividade, cnpj_sind_categ_prof, cbo_cargo, und_sal_fixo, tp_contr,
                                        tp_jornada, tmp_parc, hor_noturno, dsc_jorn)
    VALUES (v_acc, pg_temp.id(p_emp_k), v_cid, p_mat, '101', 1, false, 1, 1, 1, '11444777000161', '411010', 5, 1,
            2, 0, false, 'Segunda a sexta, 08h as 18h, com intervalo de 2h');
    INSERT INTO folha.contract_tax_allocation (account_id, employer_id, contract_id, allocation_id, percentual, vigencia_inicio)
    VALUES (v_acc, pg_temp.id(p_emp_k), v_cid, pg_temp.id(p_emp_k || '.lot'), 100, '2026-01-01');
  END IF;
END $$;

-- Folha gravada direto (gatilhos desligados, como no 0031), um resultado por contrato, com as rubricas dos itens.
-- Itens padrão: SALARIO_BASE 3000.00 (provento), INSS_EMPREGADO 281.25 e IRRF 12.50 (descontos): líquido 2706.25.
CREATE FUNCTION pg_temp.folha(p_k text, p_emp_k text, p_comp date, p_status text, p_contratos text[],
                              p_pgto date DEFAULT NULL, p_tipo text DEFAULT 'mensal', p_seq integer DEFAULT 1,
                              p_liquido numeric DEFAULT 2706.25) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  v_run uuid;
  v_acc uuid := pg_temp.conta_de(p_emp_k);
  v_c text;
  v_res uuid;
BEGIN
  PERFORM set_config('session_replication_role', 'replica', true);
  INSERT INTO folha.payroll_run (account_id, competencia, status, tipo_processo, sequencia, employer_id, data_pagamento, fechado_em)
  VALUES (v_acc, p_comp, p_status, p_tipo, p_seq, pg_temp.id(p_emp_k),
          COALESCE(p_pgto, (p_comp + interval '1 month')::date + 4), CASE WHEN p_status = 'closed' THEN now() END)
  RETURNING run_id INTO v_run;
  FOREACH v_c IN ARRAY p_contratos LOOP
    INSERT INTO folha.payroll_result (run_id, account_id, employee_id, contract_id, total_proventos, total_descontos, liquido,
                                      inss_empregado, irrf, fgts, inss_patronal, rat, terceiros, calculation_hash)
    SELECT v_run, v_acc, k.employee_id, k.contract_id, 3000, 293.75, p_liquido, 281.25, 12.50, 240, 600, 60, 174, 'caso-de-teste'
      FROM folha.employment_contract k WHERE k.contract_id = pg_temp.id(v_c)
    RETURNING result_id INTO v_res;
    INSERT INTO folha.payroll_result_item (account_id, result_id, code_id, rubrica_codigo, tipo_rubrica, ordem, quantidade, valor, camada_regra)
    SELECT v_acc, v_res, c.code_id, c.codigo, c.tipo_rubrica, x.ordem, NULL, x.valor, 'motor'
      FROM (VALUES ('SALARIO_BASE', 1, 3000.00), ('INSS_EMPREGADO', 2, 281.25), ('IRRF', 3, 12.50)) AS x(codigo, ordem, valor)
      JOIN folha.earning_deduction_code c ON c.account_id IS NULL AND c.codigo = x.codigo;
    INSERT INTO ids VALUES (p_k || '.' || v_c, v_res, v_acc);
  END LOOP;
  PERFORM set_config('session_replication_role', 'origin', true);
  INSERT INTO ids VALUES (p_k, v_run, v_acc);
END $$;

-- Marca como validado, com recibo, um rascunho da fila (só o estado; o que os gatilhos da 0031 fariam num fluxo real
-- é tema do arquivo 0031; aqui o foco é a entrada).
CREATE FUNCTION pg_temp.valida_direto(p_k text, p_recibo text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  v_e folha.esocial_event;
  v_lot uuid;
BEGIN
  SELECT * INTO STRICT v_e FROM folha.esocial_event WHERE event_id = pg_temp.id(p_k);
  PERFORM set_config('session_replication_role', 'replica', true);
  INSERT INTO folha.esocial_lot (account_id, employer_id, ambiente, grupo, situacao, protocolo, codigo_resposta, qtd_eventos,
                                 enviado_por_subject, atualizado_por_subject)
  SELECT v_e.account_id, v_e.employer_id, v_e.ambiente, c.grupo, 'processado', 'PROT-' || p_k, '201', 1,
         '82000000-0000-0000-0000-000000000032', '82000000-0000-0000-0000-000000000032'
    FROM folha.esocial_event_catalog c WHERE c.evento_codigo = v_e.evento_codigo
  RETURNING lot_id INTO v_lot;
  UPDATE folha.esocial_event SET estado = 'validado', lot_id = v_lot, payload_hash = repeat('a', 64), assinado_hash = repeat('b', 64),
         recibo_numero = p_recibo WHERE event_id = v_e.event_id;
  PERFORM set_config('session_replication_role', 'origin', true);
END $$;

CREATE FUNCTION pg_temp.cancela_direto(p_k text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('session_replication_role', 'replica', true);
  UPDATE folha.esocial_event SET estado = 'cancelado' WHERE event_id = pg_temp.id(p_k);
  PERFORM set_config('session_replication_role', 'origin', true);
END $$;

-- Chamadas dos geradores de entrada (guardam o resultado em saida e o evento em ids)
CREATE FUNCTION pg_temp.s1000(p_k text, p_emp_k text, p_vig date, p_reg boolean DEFAULT true) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.guarda(p_k, pg_temp.tx_a(format('SELECT folha.esocial_entrada_s1000_v1(%L::uuid, %L::date, %L, %L::timestamp, %L::boolean)::text',
    pg_temp.id(p_emp_k), p_vig, 'producao_restrita', pg_temp.ger(), p_reg))) $$;
CREATE FUNCTION pg_temp.s1005(p_k text, p_est_k text, p_vig date, p_reg boolean DEFAULT true) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.guarda(p_k, pg_temp.tx_a(format('SELECT folha.esocial_entrada_s1005_v1(%L::uuid, %L::date, %L, %L::timestamp, %L::boolean)::text',
    pg_temp.id(p_est_k), p_vig, 'producao_restrita', pg_temp.ger(), p_reg))) $$;
CREATE FUNCTION pg_temp.s1010(p_k text, p_emp_k text, p_cod text, p_vig date, p_reg boolean DEFAULT true) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.guarda(p_k, pg_temp.tx_a(format('SELECT folha.esocial_entrada_s1010_v1(%L::uuid, %L::uuid, %L::date, %L, %L::timestamp, %L::boolean)::text',
    pg_temp.id(p_emp_k), (SELECT code_id FROM folha.earning_deduction_code WHERE account_id IS NULL AND codigo = p_cod), p_vig, 'producao_restrita', pg_temp.ger(), p_reg))) $$;
CREATE FUNCTION pg_temp.s1020(p_k text, p_lot_k text, p_vig date, p_reg boolean DEFAULT true) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.guarda(p_k, pg_temp.tx_a(format('SELECT folha.esocial_entrada_s1020_v1(%L::uuid, %L::date, %L, %L::timestamp, %L::boolean)::text',
    pg_temp.id(p_lot_k), p_vig, 'producao_restrita', pg_temp.ger(), p_reg))) $$;
CREATE FUNCTION pg_temp.s2200(p_k text, p_emp_k text, p_con_k text, p_reg boolean DEFAULT true, p_retif text DEFAULT NULL, p_motivo text DEFAULT NULL)
RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.guarda(p_k, pg_temp.tx_a(format('SELECT folha.esocial_entrada_s2200_v1(%L::uuid, %L::uuid, %L, %L::timestamp, %L::boolean, %L::uuid, %L)::text',
    pg_temp.id(p_emp_k), pg_temp.id(p_con_k), 'producao_restrita', pg_temp.ger(), p_reg,
    CASE WHEN p_retif IS NOT NULL THEN pg_temp.id(p_retif) END, p_motivo))) $$;
CREATE FUNCTION pg_temp.s1200(p_k text, p_emp_k text, p_trab_k text, p_comp date, p_ind smallint DEFAULT 1, p_reg boolean DEFAULT true,
                              p_retif text DEFAULT NULL, p_motivo text DEFAULT NULL) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.guarda(p_k, pg_temp.tx_a(format('SELECT folha.esocial_entrada_s1200_v1(%L::uuid, %L::uuid, %L::smallint, %L::date, %L, %L::timestamp, %L::boolean, %L::uuid, %L)::text',
    pg_temp.id(p_emp_k), pg_temp.id(p_trab_k), p_ind, p_comp, 'producao_restrita', pg_temp.ger(), p_reg,
    CASE WHEN p_retif IS NOT NULL THEN pg_temp.id(p_retif) END, p_motivo))) $$;
CREATE FUNCTION pg_temp.s1210(p_k text, p_emp_k text, p_trab_k text, p_mes date, p_reg boolean DEFAULT true,
                              p_retif text DEFAULT NULL, p_motivo text DEFAULT NULL) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.guarda(p_k, pg_temp.tx_a(format('SELECT folha.esocial_entrada_s1210_v1(%L::uuid, %L::uuid, %L::date, %L, %L::timestamp, %L::boolean, %L::uuid, %L)::text',
    pg_temp.id(p_emp_k), pg_temp.id(p_trab_k), p_mes, 'producao_restrita', pg_temp.ger(), p_reg,
    CASE WHEN p_retif IS NOT NULL THEN pg_temp.id(p_retif) END, p_motivo))) $$;
CREATE FUNCTION pg_temp.s1298(p_k text, p_emp_k text, p_per date, p_reg boolean DEFAULT true) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.guarda(p_k, pg_temp.tx_a(format('SELECT folha.esocial_entrada_s1298_v1(%L::uuid, 1::smallint, %L::date, %L, %L::timestamp, %L::boolean)::text',
    pg_temp.id(p_emp_k), p_per, 'producao_restrita', pg_temp.ger(), p_reg))) $$;
CREATE FUNCTION pg_temp.s1299(p_k text, p_emp_k text, p_per date, p_reg boolean DEFAULT true) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.guarda(p_k, pg_temp.tx_a(format('SELECT folha.esocial_entrada_s1299_v1(%L::uuid, 1::smallint, %L::date, %L, %L::timestamp, %L::boolean)::text',
    pg_temp.id(p_emp_k), p_per, 'producao_restrita', pg_temp.ger(), p_reg))) $$;
CREATE FUNCTION pg_temp.s3000(p_k text, p_alvo_k text, p_motivo text, p_reg boolean DEFAULT true) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.guarda(p_k, pg_temp.tx_a(format('SELECT folha.esocial_entrada_s3000_v1(%L::uuid, %L, %L::timestamp, %L::boolean)::text',
    pg_temp.id(p_alvo_k), p_motivo, pg_temp.ger(), p_reg))) $$;
CREATE FUNCTION pg_temp.pagar(p_k text, p_res_k text, p_dt date) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.guarda(p_k, pg_temp.close_a(format('SELECT folha.esocial_entrada_pagamento_registrar_v1(%L::uuid, %L::date, NULL, 1::smallint)::text', pg_temp.id(p_res_k), p_dt))) $$;

-- Altera a data de pagamento prevista de uma folha fechada (a trava da 0027 impede por fora; o teste a desliga)
CREATE FUNCTION pg_temp.item_extra(p_res_k text, p_cod text, p_ordem integer, p_valor numeric) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('session_replication_role', 'replica', true);
  INSERT INTO folha.payroll_result_item (account_id, result_id, code_id, rubrica_codigo, tipo_rubrica, ordem, valor, camada_regra)
  SELECT pg_temp.conta_de(p_res_k), pg_temp.id(p_res_k), c.code_id, c.codigo, c.tipo_rubrica, p_ordem, p_valor, 'motor'
    FROM folha.earning_deduction_code c WHERE c.account_id IS NULL AND c.codigo = p_cod;
  PERFORM set_config('session_replication_role', 'origin', true);
END $$;
CREATE FUNCTION pg_temp.run_pgto(p_run_k text, p_data date) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('session_replication_role', 'replica', true);
  UPDATE folha.payroll_run SET data_pagamento = p_data WHERE run_id = pg_temp.id(p_run_k);
  PERFORM set_config('session_replication_role', 'origin', true);
END $$;
-- Pendência aberta numa folha fechada (gravada direto, como a 0031 grava as folhas) e sua remoção
CREATE FUNCTION pg_temp.pendencia_abre(p_run_k text, p_res_k text, p_con_k text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('session_replication_role', 'replica', true);
  INSERT INTO folha.payroll_pendency (account_id, run_id, result_id, contract_id, codigo, tipo)
  VALUES (pg_temp.conta_de(p_run_k), pg_temp.id(p_run_k), pg_temp.id(p_res_k), pg_temp.id(p_con_k), 'a_validar:fixture', 'a_validar');
  PERFORM set_config('session_replication_role', 'origin', true);
END $$;
CREATE FUNCTION pg_temp.pendencia_fecha(p_run_k text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('session_replication_role', 'replica', true);
  DELETE FROM folha.payroll_pendency WHERE run_id = pg_temp.id(p_run_k);
  PERFORM set_config('session_replication_role', 'origin', true);
END $$;

-- Cenário da conta A: EA (completo), EC (empregador sem cadastro do eSocial) e colaboradores
SELECT pg_temp.empregador('EA', :A, '11222333000181', true);
SELECT pg_temp.empregador('EC', :A, '11222333000262', false);
SELECT pg_temp.colab('T1', 'EA', 'clt', '11144477735', '000123', true);
SELECT pg_temp.colab('T2', 'EA', 'clt', '52998224725', '000124', true);
SELECT pg_temp.colab('T3', 'EA', 'estagio', '39053344705', '000125', true);
SELECT pg_temp.colab('T4', 'EA', 'pj', '86288366757', '000126', true);
SELECT pg_temp.colab('T5', 'EA', 'clt', '12345678909', '000127', false);
-- Conta B: mesmo CNPJ e mesmo CPF sintéticos (a conta isola)
SELECT pg_temp.empregador('EB', :B, '11222333000181', true);
SELECT pg_temp.colab('TB', 'EB', 'clt', '11144477735', '000123', true);

-- ===========================================================================
-- 1. Tabelas oficiais do eSocial: só a estrutura e o que o XSD enumera
-- ===========================================================================
SELECT is((SELECT count(*) FROM folha.esocial_domain_code), 55::bigint, 'domínios: 55 códigos, todos lidos de enumerações do XSD S-1.3 local');
SELECT is(
  (SELECT string_agg(campo || '=' || n, ' ' ORDER BY campo COLLATE "C") FROM (SELECT campo, count(*) AS n FROM folha.esocial_domain_code GROUP BY campo) g),
  'codIncCP=25 codIncFGTS=8 grauInstr=12 racaCor=6 tpRubr=4',
  'domínios: só tpRubr, codIncCP, codIncFGTS, grauInstr e racaCor (as enumerações dos XSD)');
SELECT is_empty(
  $$SELECT campo || ':' || codigo FROM folha.esocial_domain_code
     WHERE status_validacao <> 'validado' OR tabela_numero <> 'XSD'
        OR fonte !~ '^dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1\.3-2026-10-26/[A-Za-z]+\.xsd:[0-9]+ \(xs:enumeration\)$'$$,
  'domínios: toda linha cita arquivo e linha do XSD, é validada na fonte e não afirma número de tabela que o XSD não cita');
SELECT is((SELECT count(*) FROM folha.esocial_domain_code WHERE campo IN ('codCateg', 'tpLotacao', 'mtvDeslig', 'codIncIRRF', 'natRubr', 'classTrib', 'tpDep')),
  0::bigint, 'domínios: Tabelas 01, 03, 07, 08, 10, 19 e 21 NÃO foram semeadas (o leiaute local não as enumera)');
SELECT is((SELECT count(*) FROM folha.esocial_rubric_nature), 0::bigint, 'natureza da rubrica (Tabela 03): estrutura própria da 0026, continua vazia');
SELECT is(folha.esocial_dominio_situacao('tpRubr', '1'), 'ok', 'situação do código: tpRubr 1 está na tabela carregada');
SELECT is(folha.esocial_dominio_situacao('tpRubr', '9'), 'invalido', 'situação do código: tpRubr 9 não está na tabela carregada');
SELECT is(folha.esocial_dominio_situacao('codCateg', '101'), 'sem_tabela', 'situação do código: Tabela 01 vazia = sem_tabela (não inventa)');
SELECT is(folha.esocial_dominio_situacao('natRubr', '1000'), 'sem_tabela', 'situação do código: Tabela 03 vazia = sem_tabela');
SELECT is(folha.esocial_dominio_situacao('tpRubr', NULL), 'sem_tabela', 'situação do código: nulo não é conferido');

CREATE TEMP TABLE tabelas (nome text PRIMARY KEY, tipo text NOT NULL);
INSERT INTO tabelas VALUES
  ('employer_esocial', 'cadastro'), ('establishment_esocial', 'cadastro'), ('rubric_esocial_config', 'cadastro'),
  ('employee_esocial', 'cadastro'), ('employee_dependent', 'cadastro'), ('contract_esocial', 'cadastro'), ('contract_termination', 'cadastro'),
  ('payroll_demonstrative', 'fato'), ('payroll_payment', 'fato'), ('esocial_entrada', 'fato'), ('esocial_domain_code', 'catalogo');
SELECT is(
  (SELECT count(*) FROM tabelas t JOIN pg_class k ON k.oid = ('folha.' || t.nome)::regclass WHERE k.relrowsecurity AND k.relforcerowsecurity),
  11::bigint, 'as onze tabelas novas existem, com RLS e FORCE');
SELECT is_empty(
  $$SELECT p.tablename || ':' || p.policyname || '/' || p.cmd
      FROM pg_policies p JOIN tabelas t ON t.nome = p.tablename
     WHERE p.schemaname = 'folha'
       AND ((t.tipo = 'cadastro' AND (p.cmd <> 'ALL' OR p.qual <> '(account_id = ( SELECT folha.current_account_id() AS current_account_id))'
                                      OR p.with_check <> '(account_id = ( SELECT folha.current_account_id() AS current_account_id))'))
         OR (t.tipo = 'fato' AND (p.cmd <> 'SELECT' OR p.qual <> '(account_id = ( SELECT folha.current_account_id() AS current_account_id))'
                                      OR (SELECT string_agg(r::text, '+' ORDER BY r::text) FROM unnest(p.roles) AS r) <> 'dnex_gestao_data_owner+dnex_gestao_folha_worker'))
         OR (t.tipo = 'catalogo' AND (p.cmd <> 'SELECT' OR p.qual <> 'true')))$$,
  'policies: cadastro e fato pela conta da sessão (fato só leitura, só worker e data_owner); catálogo só leitura');
SELECT is((SELECT count(*) FROM pg_policies p JOIN tabelas t ON t.nome = p.tablename WHERE p.schemaname = 'folha'), 11::bigint, 'uma policy por tabela nova (âncora)');
SELECT is_empty(
  $$SELECT t.nome || '<-' || CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END || ':' || a.privilege_type
      FROM tabelas t JOIN pg_class k ON k.oid = ('folha.' || t.nome)::regclass,
           LATERAL aclexplode(COALESCE(k.relacl, acldefault('r', k.relowner))) a
     WHERE a.grantee <> k.relowner
       AND NOT (a.privilege_type = 'SELECT' AND a.grantee::regrole::text IN ('dnex_gestao_folha_worker', 'dnex_gestao_data_owner'))
       AND NOT (t.tipo = 'cadastro' AND a.privilege_type IN ('INSERT', 'UPDATE') AND a.grantee::regrole::text = 'dnex_gestao_folha_worker')$$,
  'ACL exata das tabelas: SELECT para worker e data_owner; INSERT e UPDATE só do worker e só no cadastro (fato e catálogo, só pelas funções)');
SELECT is_empty(
  $$SELECT k.relname || '<-' || r.papel || ':' || p.priv
      FROM pg_class k
      CROSS JOIN (VALUES ('anon'), ('authenticated'), ('service_role'), ('dnex_gestao_api'), ('dnex_folha_ci_login')) AS r(papel)
      CROSS JOIN (VALUES ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE')) AS p(priv)
     WHERE k.oid IN (SELECT ('folha.' || nome)::regclass FROM tabelas) AND has_table_privilege(r.papel, k.oid, p.priv)$$,
  'anon, authenticated, service_role, dnex_gestao_api e o login de teste não têm privilégio nas tabelas novas');
SELECT is(
  (SELECT count(*) FROM information_schema.columns WHERE table_schema = 'folha' AND table_name = 'tax_allocation'
      AND column_name IN ('esocial_tp_insc', 'esocial_nr_insc', 'info_empr_parcial', 'dados_op_port')),
  4::bigint, 'lotação: as quatro colunas novas do S-1020 (o tipo da lotação e o FPAS já existiam)');
SELECT is(
  (SELECT count(*) FROM information_schema.columns WHERE table_schema = 'folha' AND table_name = 'tax_allocation_detail'
      AND column_name IN ('cod_terceiros_suspensos', 'info_proc_jud_terceiros')),
  2::bigint, 'enquadramento da lotação: as duas colunas novas (FPAS e Terceiros já existiam)');

-- Funções: ACL exata
CREATE TEMP TABLE acl (sig text PRIMARY KEY, papeis text[] NOT NULL, definer boolean NOT NULL);
INSERT INTO acl VALUES
  ('folha.esocial_dominio_situacao(text,text)',          ARRAY[]::text[], true),
  ('folha.esocial_dominio_guarda()',                      ARRAY[]::text[], true),
  ('folha.esocial_entrada_acc()',                         ARRAY[]::text[], false),
  ('folha.esocial_entrada_falta(jsonb,text,text)',        ARRAY[]::text[], false),
  ('folha.esocial_entrada_exige(jsonb,text,text,text)',   ARRAY[]::text[], false),
  ('folha.esocial_entrada_bloqueia(jsonb,text,text)',     ARRAY[]::text[], false),
  ('folha.esocial_entrada_pende(jsonb,text,text)',        ARRAY[]::text[], false),
  ('folha.esocial_entrada_dominio(jsonb,text,text,text,text)', ARRAY[]::text[], true),
  ('folha.esocial_entrada_dec(numeric)',                  ARRAY[]::text[], false),
  ('folha.esocial_entrada_data(date)',                    ARRAY[]::text[], false),
  ('folha.esocial_entrada_sn(boolean)',                   ARRAY[]::text[], false),
  ('folha.esocial_entrada_empregador(folha.employer)',    ARRAY[]::text[], false),
  ('folha.esocial_entrada_tpinsc_estab(text)',            ARRAY[]::text[], false),
  ('folha.esocial_entrada_contexto(boolean,boolean)',     ARRAY[]::text[], true),
  ('folha.esocial_entrada_concluir(jsonb,uuid,text,text,jsonb,jsonb,timestamp without time zone,jsonb,jsonb,jsonb,boolean,uuid,uuid,text,jsonb,text)', ARRAY[]::text[], true),
  ('folha.esocial_entrada_pagamento_registrar_v1(uuid,date,numeric,smallint)', ARRAY['dnex_gestao_api'], true),
  ('folha.esocial_entrada_s1000_v1(uuid,date,text,timestamp without time zone,boolean)', ARRAY['dnex_gestao_api'], true),
  ('folha.esocial_entrada_s1005_v1(uuid,date,text,timestamp without time zone,boolean)', ARRAY['dnex_gestao_api'], true),
  ('folha.esocial_entrada_s1010_v1(uuid,uuid,date,text,timestamp without time zone,boolean)', ARRAY['dnex_gestao_api'], true),
  ('folha.esocial_entrada_s1020_v1(uuid,date,text,timestamp without time zone,boolean)', ARRAY['dnex_gestao_api'], true),
  ('folha.esocial_entrada_s1200_v1(uuid,uuid,smallint,date,text,timestamp without time zone,boolean,uuid,text)', ARRAY['dnex_gestao_api'], true),
  ('folha.esocial_entrada_s1210_v1(uuid,uuid,date,text,timestamp without time zone,boolean,uuid,text)', ARRAY['dnex_gestao_api'], true),
  ('folha.esocial_entrada_s2200_v1(uuid,uuid,text,timestamp without time zone,boolean,uuid,text)', ARRAY['dnex_gestao_api'], true),
  ('folha.esocial_entrada_s1298_v1(uuid,smallint,date,text,timestamp without time zone,boolean)', ARRAY['dnex_gestao_api'], true),
  ('folha.esocial_entrada_s1299_v1(uuid,smallint,date,text,timestamp without time zone,boolean)', ARRAY['dnex_gestao_api'], true),
  ('folha.esocial_entrada_s3000_v1(uuid,text,timestamp without time zone,boolean)', ARRAY['dnex_gestao_api'], true);
SELECT is_empty($$SELECT acl.sig FROM acl WHERE to_regprocedure(acl.sig) IS NULL$$, 'todas as funções esperadas existem com a assinatura exata');
SELECT is(
  (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'folha'::regnamespace
      AND (p.proname LIKE 'esocial\_entrada\_%' OR p.proname LIKE 'esocial\_dominio\_%') AND p.oid::regprocedure::text NOT IN (SELECT sig FROM acl)),
  0::bigint, 'não há função esocial_entrada_* ou esocial_dominio_* fora da lista (nenhuma sobra sem ACL conferida)');
SELECT is_empty(
  $$SELECT acl.sig || '<-' || CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END
      FROM acl JOIN pg_proc p ON p.oid = to_regprocedure(acl.sig)::oid,
           LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
     WHERE a.grantee <> p.proowner
       AND (a.grantee = 0 OR NOT (a.grantee::regrole::text = ANY (acl.papeis)))$$,
  'ACL exata: nenhum papel além do previsto (nem PUBLIC, anon, authenticated, service_role) executa as funções da 0032');
SELECT is_empty(
  $$SELECT acl.sig || '<-' || r FROM acl, unnest(acl.papeis) AS r WHERE NOT has_function_privilege(r, to_regprocedure(acl.sig)::oid, 'execute')$$,
  'ACL exata: cada papel previsto executa as suas funções');
SELECT is(
  (SELECT string_agg(p.oid::regprocedure::text, ',' ORDER BY p.oid::regprocedure::text)
     FROM pg_proc p WHERE p.pronamespace = 'folha'::regnamespace AND has_function_privilege('dnex_gestao_api', p.oid, 'execute')
      AND p.proname LIKE 'esocial\_entrada\_%'),
  (SELECT string_agg(sig, ',' ORDER BY sig) FROM acl WHERE papeis = ARRAY['dnex_gestao_api']),
  'dnex_gestao_api executa, da entrada do eSocial, exatamente as onze funções _v1');
SELECT is_empty(
  $$SELECT acl.sig FROM acl JOIN pg_proc p ON p.oid = to_regprocedure(acl.sig)::oid
     WHERE p.prosecdef IS DISTINCT FROM acl.definer
        OR NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) AS cfg WHERE cfg = 'search_path=pg_catalog, pg_temp')$$,
  'funções da 0032: search_path = pg_catalog, pg_temp em todas; SECURITY DEFINER nas que leem ou gravam dado');
SELECT is_empty(
  $$SELECT p.oid::regprocedure::text FROM pg_proc p
     WHERE p.pronamespace = 'folha'::regnamespace AND p.prosecdef AND p.proname LIKE 'esocial\_%'
       AND NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) AS cfg WHERE cfg LIKE 'search_path=pg_catalog%' AND cfg ~ ',\s*pg_temp$')$$,
  'toda função SECURITY DEFINER do eSocial fixa o search_path terminando em pg_temp');

-- ===========================================================================
-- 2. Cadastro: restrições, chaves compostas com a conta e vigência sem sobreposição
-- ===========================================================================
SELECT is(pg_temp.tenta(format($q$INSERT INTO folha.employer_esocial (account_id, employer_id, vigencia_inicio, ind_des_folha, ind_opt_reg_eletron)
  VALUES (%L, %L, '2027-01-15', 0, 0)$q$, :A, pg_temp.id('EA'))), 'ERRO 23514', 'S-1000: a validade é por mês (início no dia 1)');
SELECT is(pg_temp.tenta(format($q$INSERT INTO folha.employer_esocial (account_id, employer_id, vigencia_inicio, ind_des_folha, ind_opt_reg_eletron)
  VALUES (%L, %L, '2026-05-01', 0, 0)$q$, :A, pg_temp.id('EA'))), 'ERRO 23P01', 'S-1000: vigências do mesmo empregador não se sobrepõem');
SELECT is(pg_temp.tenta(format($q$INSERT INTO folha.employer_esocial (account_id, employer_id, vigencia_inicio, ind_des_folha, ind_opt_reg_eletron, class_trib)
  VALUES (%L, %L, '2027-01-01', 0, 0, 'A1')$q$, :A, pg_temp.id('EA'))), 'ERRO 23514', 'S-1000: classificação tributária só com dois dígitos');
SELECT is(pg_temp.tenta(format($q$INSERT INTO folha.employer_esocial (account_id, employer_id, vigencia_inicio, ind_des_folha, ind_opt_reg_eletron)
  VALUES (%L, %L, '2027-01-01', 0, 0)$q$, :B, pg_temp.id('EA'))), 'ERRO 23503', 'S-1000: empregador de outra conta é recusado (chave composta com a conta)');
SELECT is(pg_temp.tenta(format($q$INSERT INTO folha.employee_esocial (account_id, employee_id) VALUES (%L, %L)$q$, :B, pg_temp.id('T5.trab'))),
  'ERRO 23503', 'trabalhador do eSocial: trabalhador de outra conta é recusado (chave composta)');
SELECT is(pg_temp.tenta(format($q$INSERT INTO folha.employee_esocial (account_id, employee_id, cep) VALUES (%L, %L, '123')$q$, :A, pg_temp.id('T5.trab'))),
  'ERRO 23514', 'trabalhador do eSocial: CEP com oito dígitos');
SELECT is(pg_temp.tenta(format($q$INSERT INTO folha.employee_esocial (account_id, employee_id, cod_munic) VALUES (%L, %L, '29274')$q$, :A, pg_temp.id('T5.trab'))),
  'ERRO 23514', 'trabalhador do eSocial: código do município é o IBGE de sete dígitos');
SELECT is(pg_temp.tenta(format($q$INSERT INTO folha.employee_esocial (account_id, employee_id, grau_instr) VALUES (%L, %L, '13')$q$, :A, pg_temp.id('T5.trab'))),
  'ERRO 23514', 'trabalhador do eSocial: grau de instrução fora de 01 a 12');
SELECT is(pg_temp.tenta(format($q$INSERT INTO folha.employee_dependent (account_id, employee_id, nm_dep, dt_nascto, dep_irrf, dep_sf, inc_trab)
  VALUES (%L, %L, 'Dependente Sintetico', '2015-01-01', true, false, false)$q$, :A, pg_temp.id('T1.trab'))),
  'ERRO 23514', 'dependente: dedução de IRRF exige o tipo do dependente');
SELECT is(pg_temp.tenta(format($q$INSERT INTO folha.employee_dependent (account_id, employee_id, nm_dep, dt_nascto, tp_dep, dep_irrf, dep_sf, inc_trab)
  VALUES (%L, %L, 'Dependente Sintetico', '2015-01-01', '03', true, false, false)$q$, :B, pg_temp.id('T1.trab'))),
  'ERRO 23503', 'dependente: trabalhador de outra conta é recusado');
SELECT is(pg_temp.tenta(format($q$INSERT INTO folha.contract_esocial (account_id, employer_id, contract_id, matricula)
  VALUES (%L, %L, %L, '000123')$q$, :A, pg_temp.id('EA'), pg_temp.id('T5'))), 'ERRO 23505',
  'vínculo: a matrícula é única por empregador');
SELECT is(pg_temp.tenta(format($q$INSERT INTO folha.contract_esocial (account_id, employer_id, contract_id, matricula)
  VALUES (%L, %L, %L, %L)$q$, :A, pg_temp.id('EA'), pg_temp.id('T5'), repeat('9', 31))), 'ERRO 23514',
  'vínculo: matrícula com mais de 30 posições é recusada');
SELECT is(pg_temp.tenta(format($q$INSERT INTO folha.contract_esocial (account_id, employer_id, contract_id, matricula)
  VALUES (%L, %L, %L, 'M-OK')$q$, :A, pg_temp.id('EC'), pg_temp.id('T5'))), 'ERRO 23503',
  'vínculo: o empregador do cadastro tem de ser o do contrato (chave composta com empregador)');
SELECT is(pg_temp.tenta(format($q$INSERT INTO folha.contract_esocial (account_id, employer_id, contract_id, matricula)
  VALUES (%L, %L, %L, 'M-OK')$q$, :A, pg_temp.id('EA'), pg_temp.id('T5'))), 'OK', 'vínculo: contrato sem o cadastro do eSocial aceita o cadastro mínimo (matrícula)');
SELECT is(pg_temp.tenta(format($q$INSERT INTO folha.contract_termination (account_id, employer_id, contract_id, mtv_deslig, dt_deslig, ind_pagto_api)
  VALUES (%L, %L, %L, '2', '2026-11-10', false)$q$, :A, pg_temp.id('EA'), pg_temp.id('T1'))), 'ERRO 23514',
  'desligamento: o motivo é CÓDIGO de dois dígitos, nunca texto');
SELECT is(pg_temp.tenta(format($q$INSERT INTO folha.contract_termination (account_id, employer_id, contract_id, mtv_deslig, dt_deslig, ind_pagto_api)
  VALUES (%L, %L, %L, '02', '2026-11-10', false)$q$, :A, pg_temp.id('EA'), pg_temp.id('T1'))), 'OK',
  'desligamento: código de dois dígitos é aceito (Tabela 19 vazia: não se confere)');
SELECT is(pg_temp.tenta(format($q$INSERT INTO folha.rubric_esocial_config (account_id, employer_id, code_id, cod_rubr, ide_tab_rubr, vigencia_inicio)
  SELECT %L, %L, code_id, 'OUTRA', 'DNEX01', '2026-03-01' FROM folha.earning_deduction_code WHERE account_id IS NULL AND codigo = 'SALARIO_BASE'$q$,
  :A, pg_temp.id('EA'))), 'ERRO 23P01', 'rubrica do S-1010: a mesma rubrica não tem duas configurações vigentes ao mesmo tempo');
SELECT is(pg_temp.tenta(format($q$INSERT INTO folha.rubric_esocial_config (account_id, employer_id, code_id, cod_rubr, ide_tab_rubr, vigencia_inicio)
  SELECT %L, %L, code_id, 'INSS', 'DNEX01', '2026-03-01' FROM folha.earning_deduction_code WHERE account_id IS NULL AND codigo = 'HE_50'$q$,
  :A, pg_temp.id('EA'))), 'ERRO 23P01', 'rubrica do S-1010: o mesmo código e identificador de tabela não vale para duas rubricas ao mesmo tempo');
SELECT is(pg_temp.tenta(format($q$INSERT INTO folha.rubric_esocial_config (account_id, employer_id, code_id, cod_rubr, ide_tab_rubr, vigencia_inicio)
  SELECT %L, %L, code_id, %L, 'DNEX01', '2026-03-01' FROM folha.earning_deduction_code WHERE account_id IS NULL AND codigo = 'HE_50'$q$,
  :A, pg_temp.id('EA'), repeat('X', 31))), 'ERRO 23514', 'rubrica do S-1010: codRubr com mais de 30 posições é recusado');
-- rubrica de outra conta: o gatilho da 0026 recusa
INSERT INTO folha.earning_deduction_code (account_id, codigo, descricao, natureza, is_global) VALUES (:B, 'RUB-DA-CONTA-B', 'Rubrica da conta B', 'provento', false);
SELECT is(pg_temp.tenta(format($q$INSERT INTO folha.rubric_esocial_config (account_id, employer_id, code_id, cod_rubr, ide_tab_rubr, vigencia_inicio)
  SELECT %L, %L, code_id, 'ALHEIA', 'DNEX01', '2026-03-01' FROM folha.earning_deduction_code WHERE codigo = 'RUB-DA-CONTA-B'$q$,
  :A, pg_temp.id('EA'))), 'ERRO 23514', 'rubrica do S-1010: rubrica de outra conta é recusada');
-- gatilho de domínio: tabela carregada recusa o código fora dela; tabela vazia não recusa
SELECT is(pg_temp.tenta($q$INSERT INTO folha.esocial_domain_code (tabela_numero, campo, codigo, descricao, fonte)
    VALUES ('01', 'codCateg', '101', 'fixture sintetico', 'fixture do teste');
  UPDATE folha.contract_esocial SET cod_categ = '999' WHERE matricula = '000123'$q$), 'ERRO 23514',
  'domínio carregado: código fora da tabela é recusado pelo gatilho');
SELECT is(pg_temp.tenta($q$INSERT INTO folha.esocial_domain_code (tabela_numero, campo, codigo, descricao, fonte)
    VALUES ('01', 'codCateg', '101', 'fixture sintetico', 'fixture do teste');
  UPDATE folha.contract_esocial SET cod_categ = '101' WHERE matricula = '000123'$q$), 'OK',
  'domínio carregado: código que está na tabela é aceito');
SELECT is(pg_temp.tenta($q$UPDATE folha.contract_esocial SET cod_categ = '999' WHERE matricula = '000123'$q$), 'OK',
  'domínio vazio (Tabela 01): o gatilho não recusa nem inventa');

-- ===========================================================================
-- 3. S-2200 (admissão)
-- ===========================================================================
SELECT pg_temp.s2200('s2200_t1_nao_reg', 'EA', 'T1', false);
SELECT is(pg_temp.est('s2200_t1_nao_reg'), 'pronto', 'S-2200: vínculo CLT completo gera a entrada');
SELECT is((SELECT count(*) FROM folha.esocial_event WHERE evento_codigo = 'S-2200' AND account_id = :A), 0::bigint,
  'S-2200: com registrar = false nada entra na fila');
SELECT is(pg_temp.j('s2200_t1_nao_reg') #>> '{entrada,evento}', 'S-2200', 'S-2200: o envelope traz o evento');
SELECT is(pg_temp.j('s2200_t1_nao_reg') #>> '{entrada,ambiente}', '2', 'S-2200: produção restrita é tpAmb 2');
SELECT is(pg_temp.j('s2200_t1_nao_reg') #>> '{entrada,emissao,geradoEm}', '2026-11-18T09:00:00', 'S-2200: o carimbo de emissão vem do relógio informado');
SELECT is(pg_temp.j('s2200_t1_nao_reg') #> '{entrada,empregador}', '{"tpInsc": 1, "nrInsc": "11222333"}'::jsonb, 'S-2200: o empregador é CNPJ pela raiz de oito posições');
SELECT is(pg_temp.j('s2200_t1_nao_reg') #>> '{entrada,dados,trabalhador,cpfTrab}', '11144477735', 'S-2200: CPF do trabalhador');
SELECT is(pg_temp.j('s2200_t1_nao_reg') #>> '{entrada,dados,vinculo,matricula}', '000123', 'S-2200: matrícula do cadastro (não é o UUID do contrato)');
SELECT is(pg_temp.j('s2200_t1_nao_reg') #>> '{entrada,dados,vinculo,infoContrato,remuneracao,vrSalFx}', '3000.00', 'S-2200: dinheiro como texto decimal');
SELECT is(pg_temp.j('s2200_t1_nao_reg') #>> '{entrada,dados,vinculo,infoContrato,localTrabalho,localTrabGeral,tpInsc}', '1', 'S-2200: local de trabalho = estabelecimento CNPJ');
SELECT is(pg_temp.j('s2200_t1_nao_reg') #>> '{entrada,dados,vinculo,infoContrato,horContratual,qtdHrsSem}', '44', 'S-2200: jornada semanal vem do contrato');
SELECT is(pg_temp.j('s2200_t1_nao_reg') #>> '{entrada,dados,vinculo,infoCeletista,dtAdm}', '2026-01-05', 'S-2200: data de admissão do contrato');
SELECT is(pg_temp.j('s2200_t1_nao_reg') #>> '{entrada,dados,vinculo,infoCeletista,tpAdmissao}', '1', 'S-2200: tpAdmissao 1');
SELECT is(pg_temp.j('s2200_t1_nao_reg') #>> '{entrada,dados,vinculo,cadIni}', 'N', 'S-2200: cadIni vem do cadastro');
SELECT ok(NOT (pg_temp.j('s2200_t1_nao_reg') #> '{entrada,dados,trabalhador}' ? 'dependente'), 'S-2200: sem dependente cadastrado, o grupo não aparece');
SELECT is(pg_temp.pend('s2200_t1_nao_reg'), 'dados.vinculo.infoContrato.codCateg',
  'S-2200: categoria (Tabela 01) vazia vira pendência, não bloqueio; raça/cor e grau de instrução foram conferidos no XSD');
SELECT pg_temp.s2200('s2200_t1', 'EA', 'T1');
SELECT is(pg_temp.est('s2200_t1'), 'pronto', 'S-2200: registrando, a entrada também fica pronta');
SELECT is((SELECT estado FROM folha.esocial_event WHERE event_id = pg_temp.id('s2200_t1')), 'rascunho', 'S-2200: o evento entra na fila como rascunho');
SELECT is((SELECT count(*) FROM folha.esocial_event_payload WHERE event_id = pg_temp.id('s2200_t1')), 0::bigint, 'S-2200: nenhum XML é gerado nem guardado');
SELECT ok((SELECT origem_hash ~ '^[0-9a-f]{64}$' AND payload_hash IS NULL AND assinado_hash IS NULL FROM folha.esocial_event WHERE event_id = pg_temp.id('s2200_t1')),
  'S-2200: o rascunho tem origem_hash SHA-256 e nenhum hash de XML');
SELECT is((SELECT criado_por_subject FROM folha.esocial_event WHERE event_id = pg_temp.id('s2200_t1')), '82000000-0000-0000-0000-000000000032'::uuid,
  'S-2200: o subject do contexto é gravado no evento');
SELECT is((SELECT e.criado_por_subject FROM folha.esocial_entrada e WHERE e.event_id = pg_temp.id('s2200_t1') AND e.estado = 'pronto'),
  '82000000-0000-0000-0000-000000000032'::uuid, 'S-2200: o subject do contexto é gravado no registro da entrada');
SELECT is((SELECT count(*) FROM folha.auditoria WHERE acao = 'esocial_entrada' AND recurso_id = pg_temp.id('s2200_t1')
             AND actor_subject = '82000000-0000-0000-0000-000000000032' AND detalhe::text NOT LIKE '%cpfTrab%' AND detalhe::text NOT LIKE '%11144477735%'),
  1::bigint, 'S-2200: a auditoria tem o subject e nenhum dado pessoal');
SELECT is((SELECT entrada_hash FROM folha.esocial_entrada WHERE event_id = pg_temp.id('s2200_t1') AND estado = 'pronto'),
  (SELECT origem_hash FROM folha.esocial_event WHERE event_id = pg_temp.id('s2200_t1')), 'S-2200: origem_hash do evento = hash da entrada');
SELECT pg_temp.s2200('s2200_t1_de_novo', 'EA', 'T1');
SELECT is((pg_temp.j('s2200_t1_de_novo') ->> 'situacao') || ':' || (pg_temp.j('s2200_t1_de_novo') ->> 'event_id'),
  'existente:' || pg_temp.id('s2200_t1'), 'S-2200: repetir a chamada é idempotente (mesmo evento, situação existente)');
SELECT is((SELECT count(*) FROM folha.esocial_entrada WHERE event_id = pg_temp.id('s2200_t1') AND estado = 'pronto'), 1::bigint,
  'S-2200: a repetição não duplica o registro da entrada');
-- o hash não depende do carimbo de emissão
SELECT is(pg_temp.tx_a(format($q$SELECT (folha.esocial_entrada_s2200_v1(%L::uuid, %L::uuid, 'producao_restrita', '2026-11-18 17:45:10'::timestamp, true, NULL, NULL) ->> 'situacao')$q$,
  pg_temp.id('EA'), pg_temp.id('T1'))), 'existente', 'S-2200: outro carimbo de emissão não muda o hash de origem');
UPDATE folha.employment_contract SET salario_base = 3100.00 WHERE contract_id = pg_temp.id('T1');
SELECT pg_temp.s2200('s2200_t1_mudou', 'EA', 'T1');
SELECT is((pg_temp.j('s2200_t1_mudou') ->> 'situacao'), 'substituido', 'S-2200: mudou o conteúdo de origem, a versão em rascunho é substituída');
SELECT is((SELECT string_agg(versao || ':' || estado, ',' ORDER BY versao) FROM folha.esocial_event WHERE employee_id = pg_temp.id('T1.trab') AND evento_codigo = 'S-2200'),
  '1:cancelado,2:rascunho', 'S-2200: a versão anterior fica cancelada, a nova nasce em rascunho');
UPDATE folha.employment_contract SET salario_base = 3000.00 WHERE contract_id = pg_temp.id('T1');
SELECT pg_temp.s2200('s2200_t1', 'EA', 'T1');
-- negativos
SELECT pg_temp.s2200('s2200_t3', 'EA', 'T3');
SELECT is(pg_temp.est('s2200_t3') || ':' || pg_temp.blq('s2200_t3'), 'bloqueado:estagiario_s2300', 'S-2200: estagiário é recusado (o evento é o S-2300)');
SELECT is(pg_temp.j('s2200_t3') -> 'entrada', 'null'::jsonb, 'S-2200: bloqueado não devolve entrada');
SELECT pg_temp.s2200('s2200_t4', 'EA', 'T4');
SELECT is(pg_temp.est('s2200_t4') || ':' || pg_temp.blq('s2200_t4'), 'bloqueado:prestador_pj', 'S-2200: prestador PJ não é trabalhador do eSocial');
SELECT pg_temp.s2200('s2200_t5', 'EA', 'T5');
SELECT is(pg_temp.est('s2200_t5'), 'incompleto', 'S-2200: cadastro incompleto não gera entrada');
SELECT is(pg_temp.falt('s2200_t5'), 'dados.trabalhador,dados.vinculo',
  'S-2200: o que falta vem por caminho (dados do eSocial do trabalhador e do vínculo); o que já está no cadastro base não é pedido de novo');
SELECT is((SELECT count(*) FROM folha.esocial_event WHERE contract_id = pg_temp.id('T5')), 0::bigint, 'S-2200: incompleto não vai para a fila');
SELECT is((SELECT count(*) FROM folha.esocial_entrada WHERE evento_codigo = 'S-2200' AND estado = 'incompleto' AND event_id IS NULL), 1::bigint,
  'S-2200: a pendência fica registrada (estado incompleto, com o que faltou)');
SELECT is(pg_temp.guarda('s2200_conta_errada', pg_temp.tx_b(format($q$SELECT folha.esocial_entrada_s2200_v1(%L::uuid, %L::uuid, 'producao_restrita', NULL, true, NULL, NULL)::text$q$,
  pg_temp.id('EA'), pg_temp.id('T1')))) LIKE 'ERRO 22023%', true, 'S-2200: empregador de outra conta é recusado (exceção, não resultado)');
SELECT is(pg_temp.guarda('s2200_contrato_de_outro', pg_temp.tx_a(format($q$SELECT folha.esocial_entrada_s2200_v1(%L::uuid, %L::uuid, 'producao_restrita', NULL, true, NULL, NULL)::text$q$,
  pg_temp.id('EC'), pg_temp.id('T1')))) LIKE 'ERRO 22023%', true, 'S-2200: contrato que não é do empregador informado é recusado');
SELECT is(pg_temp.guarda('s2200_sem_transmit', pg_temp.so(ARRAY['folha.read'], format($q$SELECT folha.esocial_entrada_s2200_v1(%L::uuid, %L::uuid, 'producao_restrita', NULL, true, NULL, NULL)::text$q$,
  pg_temp.id('EA'), pg_temp.id('T2')))) LIKE 'ERRO 42501%', true, 'S-2200: registrar sem folha.transmit é recusado (42501)');
CREATE TEMP TABLE antes AS SELECT (SELECT count(*) FROM folha.esocial_entrada) AS ent, (SELECT count(*) FROM folha.auditoria) AS aud;
SELECT is(pg_temp.guarda('s2200_so_leitura', pg_temp.so(ARRAY['folha.read'], format($q$SELECT folha.esocial_entrada_s2200_v1(%L::uuid, %L::uuid, 'producao_restrita', NULL, false, NULL, NULL) ->> 'estado'$q$,
  pg_temp.id('EA'), pg_temp.id('T2')))), 'pronto', 'S-2200: sem registrar, folha.read basta (montagem sem efeito)');
SELECT is((SELECT ((SELECT count(*) FROM folha.esocial_entrada) - ent)::text || ':' || ((SELECT count(*) FROM folha.auditoria) - aud)::text FROM antes), '0:0',
  'S-2200: a montagem só para leitura não grava nada (nem registro de entrada com dado pessoal, nem auditoria)');
SELECT is(pg_temp.guarda('s2200_sem_contexto', pg_temp.pedido(NULL, NULL, NULL, false, false, ARRAY[format($q$SELECT folha.esocial_entrada_s2200_v1(%L::uuid, %L::uuid, 'producao_restrita', NULL, false, NULL, NULL)::text$q$,
  pg_temp.id('EA'), pg_temp.id('T2'))])) LIKE 'ERRO 42501%', true, 'S-2200: sem contexto da Folha é recusado (42501)');
SELECT is(pg_temp.guarda('s2200_ambiente', pg_temp.tx_a(format($q$SELECT folha.esocial_entrada_s2200_v1(%L::uuid, %L::uuid, 'homologacao', NULL, true, NULL, NULL)::text$q$,
  pg_temp.id('EA'), pg_temp.id('T2')))) LIKE 'ERRO 22023%', true, 'S-2200: ambiente fora de producao e producao_restrita é recusado');
SELECT is((SELECT count(*) FROM folha.esocial_event WHERE contract_id = pg_temp.id('T2')), 0::bigint, 'S-2200: nenhuma das chamadas recusadas deixou evento na fila');

-- Dependentes entram no grupo, sem inventar tipo
INSERT INTO folha.employee_dependent (account_id, employee_id, nm_dep, dt_nascto, tp_dep, cpf_dep, dep_irrf, dep_sf, inc_trab)
VALUES (:A, pg_temp.id('T2.trab'), 'Dependente Sintetico Um', '2015-03-10', '03', '12312312387', true, false, false);
SELECT pg_temp.s2200('s2200_t2_dep', 'EA', 'T2', false);
SELECT is(pg_temp.j('s2200_t2_dep') #>> '{entrada,dados,trabalhador,dependente,0,depIRRF}', 'S', 'S-2200: dependente com dedução de IRRF');
SELECT is(pg_temp.j('s2200_t2_dep') #>> '{entrada,dados,trabalhador,dependente,0,tpDep}', '03', 'S-2200: tipo do dependente do cadastro');
SELECT is(pg_temp.j('s2200_t2_dep') #>> '{entrada,dados,trabalhador,dependente,0,cpfDep}', '12312312387', 'S-2200: CPF do dependente do cadastro');
UPDATE folha.employee_dependent SET cpf_dep = NULL WHERE employee_id = pg_temp.id('T2.trab');
SELECT pg_temp.s2200('s2200_t2_dep_sem_cpf', 'EA', 'T2', false);
SELECT is(pg_temp.falt('s2200_t2_dep_sem_cpf'), 'dados.trabalhador.dependente[].cpfDep', 'S-2200: dependente com dedução de IRRF sem CPF fica em "faltando" (o gerador exige)');
UPDATE folha.employee_dependent SET cpf_dep = '12312312387' WHERE employee_id = pg_temp.id('T2.trab');
UPDATE folha.contract_esocial SET tp_contr = 2 WHERE contract_id = pg_temp.id('T1');
SELECT pg_temp.s2200('s2200_t1_prazo', 'EA', 'T1', false);
SELECT is(pg_temp.falt('s2200_t1_prazo'), 'dados.vinculo.infoContrato.duracao.dtTerm', 'S-2200: contrato por prazo determinado sem a data de término fica incompleto');
UPDATE folha.contract_esocial SET tp_contr = 1, cod_categ = '901' WHERE contract_id = pg_temp.id('T1');
SELECT pg_temp.s2200('s2200_t1_901', 'EA', 'T1', false);
SELECT is(pg_temp.falt('s2200_t1_901'), 'dados.vinculo.infoContrato.codCateg', 'S-2200: categoria fora das de vínculo celetista do gerador (901 é estágio) não passa');
UPDATE folha.contract_esocial SET cod_categ = '101' WHERE contract_id = pg_temp.id('T1');
UPDATE folha.employee SET cpf = 'ABC' WHERE employee_id = pg_temp.id('T1.trab');
SELECT pg_temp.s2200('s2200_t1_cpf', 'EA', 'T1', false);
SELECT is(pg_temp.falt('s2200_t1_cpf'), 'dados.trabalhador.cpfTrab', 'S-2200: CPF fora de onze dígitos não vai para a entrada');
UPDATE folha.employee SET cpf = '11144477735' WHERE employee_id = pg_temp.id('T1.trab');
SELECT ok(pg_temp.pend('s2200_t2_dep') LIKE '%dependente[].tpDep%', 'S-2200: tipo de dependente (Tabela 07) vazia vira pendência');

-- ===========================================================================
-- 4. S-1000, S-1005, S-1020 e S-1010 (tabelas, em inclusão)
-- ===========================================================================
SELECT pg_temp.s1000('s1000_ea', 'EA', '2026-01-01');
SELECT is(pg_temp.est('s1000_ea'), 'pronto', 'S-1000: empregador com dados do eSocial gera a entrada de inclusão');
SELECT is(pg_temp.j('s1000_ea') #> '{entrada,dados,operacao}',
  '{"tipo": "inclusao", "idePeriodo": {"iniValid": "2026-01", "fimValid": "2026-10"}, "infoCadastro": {"classTrib": "99", "indCoop": 0, "indConstr": 0, "indDesFolha": 0, "indPorte": "S", "indOptRegEletron": 0}}'::jsonb,
  'S-1000: idePeriodo e infoCadastro exatamente como no cadastro (o indPorte "S" só quando verdadeiro)');
SELECT is(pg_temp.pend('s1000_ea'), 'dados.operacao.infoCadastro.classTrib', 'S-1000: classificação tributária (Tabela 08) vazia vira pendência');
SELECT is((SELECT estado || ':' || employer_id::text FROM folha.esocial_event WHERE event_id = pg_temp.id('s1000_ea')), 'rascunho:' || pg_temp.id('EA'),
  'S-1000: rascunho na fila do empregador');
SELECT pg_temp.s1000('s1000_ec', 'EC', '2026-01-01');
SELECT is(pg_temp.est('s1000_ec') || ':' || pg_temp.falt('s1000_ec'), 'incompleto:dados.operacao.infoCadastro', 'S-1000: empregador sem cadastro do eSocial na vigência fica incompleto');
SELECT pg_temp.s1000('s1000_vig_errada', 'EA', '2026-01-15');
SELECT is(pg_temp.erro('s1000_vig_errada'), 'ERRO 22023:', 'S-1000: início de validade fora do dia 1 é recusado');
UPDATE folha.employer SET classificacao_tributaria = '03' WHERE employer_id = pg_temp.id('EC');
SELECT is(pg_temp.tx_a(format($q$SELECT (folha.esocial_entrada_s1000_v1(%L::uuid, '2026-01-01', 'producao_restrita', NULL, false) -> 'faltando')::text$q$, pg_temp.id('EC'))),
  '["dados.operacao.infoCadastro"]', 'S-1000: sem cadastro do eSocial na vigência (antes do insert abaixo)');
INSERT INTO folha.employer_esocial (account_id, employer_id, vigencia_inicio, ind_des_folha, ind_opt_reg_eletron)
VALUES (:A, pg_temp.id('EC'), '2026-01-01', 1, 1);
SELECT is(pg_temp.tx_a(format($q$SELECT (folha.esocial_entrada_s1000_v1(%L::uuid, '2026-01-01', 'producao_restrita', NULL, false) -> 'faltando')::text$q$, pg_temp.id('EC'))),
  '["dados.operacao.infoCadastro.indCoop"]', 'S-1000: indCoop e indConstr são obrigatórios para pessoa jurídica');
UPDATE folha.employer_esocial SET ind_coop = 0, ind_constr = 0 WHERE employer_id = pg_temp.id('EC');
SELECT pg_temp.s1000('s1000_ec2', 'EC', '2026-01-01', false);
SELECT is(pg_temp.j('s1000_ec2') #>> '{entrada,dados,operacao,infoCadastro,classTrib}', '03', 'S-1000: a classificação tributária reusa a do empregador quando a vigência não a traz');
SELECT is(pg_temp.j('s1000_ec2') #>> '{entrada,dados,operacao,idePeriodo}', '{"iniValid": "2026-01"}', 'S-1000: vigência aberta não leva fimValid');

SELECT pg_temp.s1005('s1005_ea', 'EA.est', '2026-01-01');
SELECT is(pg_temp.est('s1005_ea'), 'pronto', 'S-1005: estabelecimento com CNAE de sete dígitos e dados do eSocial');
SELECT is(pg_temp.j('s1005_ea') #> '{entrada,dados,operacao}',
  '{"tipo": "inclusao", "ideEstab": {"tpInsc": 1, "nrInsc": "11222333000181", "iniValid": "2026-01", "fimValid": "2026-10"}, "dadosEstab": {"cnaePrep": "6201501", "aliqGilrat": {"fap": "1.0500"}}}'::jsonb,
  'S-1005: CNAE do estabelecimento e FAP vigente; o aliqRat não sai sem processo (o gerador o recusa)');
UPDATE folha.establishment_esocial SET proc_adm_jud_rat = '{"tpProc": 1, "nrProc": "12345678901234567", "codSusp": "1"}' WHERE establishment_id = pg_temp.id('EA.est');
SELECT pg_temp.s1005('s1005_rat', 'EA.est', '2026-01-01', false);
SELECT is(pg_temp.j('s1005_rat') #> '{entrada,dados,operacao,dadosEstab,aliqGilrat}', '{"fap": "1.0500", "aliqRat": 2, "procAdmJudRat": {"tpProc": 1, "nrProc": "12345678901234567", "codSusp": "1"}}'::jsonb, 'S-1005: com o processo, o aliqRat sai');
UPDATE folha.establishment_esocial SET proc_adm_jud_rat = NULL WHERE establishment_id = pg_temp.id('EA.est');
SELECT is((SELECT codigo_tabela FROM folha.esocial_event WHERE event_id = pg_temp.id('s1005_ea')), '11222333000181', 'S-1005: a identificação do estabelecimento é o código da tabela na fila');
UPDATE folha.establishment SET cnae_preponderante = '62015' WHERE establishment_id = pg_temp.id('EA.est');
SELECT pg_temp.s1005('s1005_cnae', 'EA.est', '2026-01-01', false);
SELECT is(pg_temp.falt('s1005_cnae'), 'dados.operacao.dadosEstab.cnaePrep', 'S-1005: CNAE fora de sete dígitos é "faltando", não é completado');
UPDATE folha.establishment SET cnae_preponderante = '6201501' WHERE establishment_id = pg_temp.id('EA.est');
SELECT pg_temp.s1005('s1005_ec', 'EC.est', '2026-01-01', false);
SELECT is(pg_temp.falt('s1005_ec'), 'dados.operacao.dadosEstab', 'S-1005: estabelecimento sem dados do eSocial na vigência fica incompleto');

SELECT pg_temp.s1020('s1020_ea', 'EA.lot', '2026-01-01');
SELECT is(pg_temp.est('s1020_ea'), 'pronto', 'S-1020: lotação com enquadramento de mês fechado');
SELECT is(pg_temp.j('s1020_ea') #> '{entrada,dados,operacao}',
  '{"tipo": "inclusao", "ideLotacao": {"codLotacao": "LOT-SINT-01", "iniValid": "2026-01", "fimValid": "2026-10"}, "dadosLotacao": {"tpLotacao": "01", "fpasLotacao": {"fpas": "507", "codTercs": "0000"}}}'::jsonb,
  'S-1020: tipo da lotação, FPAS e Terceiros do enquadramento (como no fixture do gerador)');
SELECT is(pg_temp.pend('s1020_ea'), 'dados.operacao.dadosLotacao.tpLotacao', 'S-1020: tipo de lotação (Tabela 10) vazia vira pendência');
INSERT INTO folha.tax_allocation_detail (account_id, allocation_id, vigencia_inicio, fpas, codigo_terceiros)
VALUES (:A, pg_temp.id('EA.lot'), '2026-11-15', '507', '00');
SELECT pg_temp.s1020('s1020_dia15', 'EA.lot', '2026-11-15', false);
SELECT is(pg_temp.falt('s1020_dia15'), 'dados.operacao.dadosLotacao.fpasLotacao.codTercs,dados.operacao.ideLotacao.iniValid',
  'S-1020: vigência que começa fora do dia 1 e Terceiros fora de quatro dígitos ficam em "faltando"');
SELECT pg_temp.s1020('s1020_sem_enq', 'EA.lot', '2026-06-01', false);
SELECT is(pg_temp.falt('s1020_sem_enq'), 'dados.operacao.dadosLotacao.fpasLotacao', 'S-1020: vigência sem enquadramento cadastrado fica incompleta');

UPDATE folha.incidence_code SET codigo_esocial = '11' WHERE (tributo, codigo) IN (('previdencia', 'BASE_MENSAL'), ('irrf', 'BASE_MENSAL'), ('fgts', 'BASE_MENSAL'));
SELECT pg_temp.s1010('s1010_sal_sem_nat', 'EA', 'SALARIO_BASE', '2026-01-01', false);
SELECT is(pg_temp.est('s1010_sal_sem_nat') || ':' || pg_temp.falt('s1010_sal_sem_nat'), 'incompleto:dados.operacao.dadosRubrica.natRubr',
  'S-1010: sem natureza (Tabela 03) cadastrada para a rubrica, falta; incidências com código do eSocial vieram de incidence_code');
INSERT INTO folha.esocial_rubric_nature (codigo, descricao, vigencia_inicio, fonte) VALUES ('1000', 'fixture sintetico', '2020-01-01', 'fixture do teste');
INSERT INTO folha.rubric_esocial_nature (account_id, code_id, natureza_codigo, vigencia_inicio)
SELECT NULL, code_id, '1000', '2026-01-01' FROM folha.earning_deduction_code WHERE account_id IS NULL AND codigo = 'SALARIO_BASE';
SELECT pg_temp.s1010('s1010_sal', 'EA', 'SALARIO_BASE', '2026-01-01');
SELECT is(pg_temp.est('s1010_sal'), 'pronto', 'S-1010: rubrica com configuração, natureza e incidências gera a entrada');
SELECT is(pg_temp.j('s1010_sal') #> '{entrada,dados,operacao}',
  '{"tipo": "inclusao", "ideRubrica": {"codRubr": "SALARIO", "ideTabRubr": "DNEX01", "iniValid": "2026-01"}, "dadosRubrica": {"dscRubr": "Salário base contratual", "natRubr": "1000", "tpRubr": 1, "codIncCP": "11", "codIncIRRF": "11", "codIncFGTS": "11"}}'::jsonb,
  'S-1010: codRubr e ideTabRubr do cadastro, natureza, tpRubr derivado do tipo da rubrica e incidências do catálogo');
SELECT is(pg_temp.pend('s1010_sal'), 'dados.operacao.dadosRubrica.codIncIRRF,dados.operacao.dadosRubrica.incidencias', 'S-1010: a Tabela 21 (IRRF) e as incidências ainda a_validar ficam pendentes; natureza e CP/FGTS foram conferidas nas tabelas carregadas');
SELECT is((SELECT codigo_tabela FROM folha.esocial_event WHERE event_id = pg_temp.id('s1010_sal')), 'SALARIO/DNEX01', 'S-1010: código e identificador da tabela são a chave na fila');
UPDATE folha.incidence_code SET codigo_esocial = '77' WHERE tributo = 'fgts' AND codigo = 'BASE_MENSAL';
SELECT pg_temp.s1010('s1010_fgts_invalido', 'EA', 'SALARIO_BASE', '2026-01-01', false);
SELECT is(pg_temp.falt('s1010_fgts_invalido'), 'dados.operacao.dadosRubrica.codIncFGTS', 'S-1010: código de incidência fora da tabela carregada (XSD) é recusado como "faltando"');
UPDATE folha.incidence_code SET codigo_esocial = '11' WHERE tributo = 'fgts' AND codigo = 'BASE_MENSAL';
SELECT pg_temp.s1010('s1010_inss', 'EA', 'INSS_EMPREGADO', '2026-01-01', false);
SELECT ok(pg_temp.falt('s1010_inss') LIKE '%natRubr%', 'S-1010: rubrica de desconto sem natureza cadastrada fica incompleta');
SELECT pg_temp.s1010('s1010_base', 'EA', 'BASE_INSS', '2026-01-01', false);
SELECT ok(pg_temp.blq('s1010_base') = 'rubrica_de_base', 'S-1010: rubrica de base de cálculo não é rubrica do eSocial');

-- ===========================================================================
-- 5. S-1200 (remuneração)
-- ===========================================================================
SELECT pg_temp.folha('R_ABERTA', 'EA', '2026-09-01', 'calculated', ARRAY['T1']);
SELECT pg_temp.s1200('s1200_aberta', 'EA', 'T1.trab', '2026-09-01', 1::smallint, false);
SELECT is(pg_temp.est('s1200_aberta') || ':' || pg_temp.blq('s1200_aberta'), 'bloqueado:folha_aberta,sem_folha_fechada', 'S-1200: folha do período ainda aberta bloqueia');
SELECT pg_temp.folha('R1', 'EA', '2026-10-01', 'closed', ARRAY['T1', 'T2']);
-- pendência aberta na folha fechada: bloqueia (e a liberação desbloqueia)
SELECT pg_temp.pendencia_abre('R1', 'R1.T1', 'T1');
SELECT pg_temp.s1200('s1200_pend', 'EA', 'T1.trab', '2026-10-01', 1::smallint, false);
SELECT is(pg_temp.est('s1200_pend') || ':' || pg_temp.blq('s1200_pend'), 'bloqueado:pendencia_aberta', 'S-1200: folha fechada com pendência aberta bloqueia');
SELECT pg_temp.pendencia_fecha('R1');
-- rubrica sem cadastro no S-1010
CREATE TEMP TABLE bak_cfg AS SELECT * FROM folha.rubric_esocial_config WHERE employer_id = pg_temp.id('EA') AND cod_rubr = 'IRRF';
DELETE FROM folha.rubric_esocial_config WHERE employer_id = pg_temp.id('EA') AND cod_rubr = 'IRRF';
SELECT pg_temp.s1200('s1200_sem_cfg', 'EA', 'T1.trab', '2026-10-01', 1::smallint, false);
SELECT is(pg_temp.est('s1200_sem_cfg') || ':' || pg_temp.falt('s1200_sem_cfg'),
  'incompleto:dados.demonstrativos[0].estabelecimentos[0].remuneracoes[0].itens[2].ideTabRubr',
  'S-1200: rubrica sem cadastro no S-1010 (codRubr/ideTabRubr) é "faltando" com o caminho do item');
SELECT is(((pg_temp.j('s1200_sem_cfg') -> 'detalhes') -> 0) ->> 'motivo',
  'rubrica IRRF sem cadastro no S-1010 (rubric_esocial_config) para 2026-10', 'S-1200: o motivo diz qual rubrica e qual mês');
INSERT INTO folha.rubric_esocial_config SELECT * FROM bak_cfg;
-- demais negativos
SELECT pg_temp.s1200('s1200_13', 'EA', 'T1.trab', '2026-01-01', 2::smallint, false);
SELECT is(pg_temp.est('s1200_13') || ':' || pg_temp.blq('s1200_13'), 'bloqueado:decimo_terceiro_nao_suportado', 'S-1200: o 13º (indApuracao 2) não é gerado nesta versão');
SELECT is(pg_temp.guarda('s1200_ind3', pg_temp.tx_a(format($q$SELECT folha.esocial_entrada_s1200_v1(%L::uuid, %L::uuid, 3::smallint, '2026-10-01', 'producao_restrita', NULL, false, NULL, NULL)::text$q$,
  pg_temp.id('EA'), pg_temp.id('T1.trab')))) LIKE 'ERRO 22023%', true, 'S-1200: indApuracao fora de 1 e 2 é recusado');
SELECT is(pg_temp.guarda('s1200_dia', pg_temp.tx_a(format($q$SELECT folha.esocial_entrada_s1200_v1(%L::uuid, %L::uuid, 1::smallint, '2026-10-15', 'producao_restrita', NULL, false, NULL, NULL)::text$q$,
  pg_temp.id('EA'), pg_temp.id('T1.trab')))) LIKE 'ERRO 22023%', true, 'S-1200: o período tem de ser o primeiro dia do mês');
SELECT is(pg_temp.guarda('s1200_trab_de_outro', pg_temp.tx_a(format($q$SELECT folha.esocial_entrada_s1200_v1(%L::uuid, %L::uuid, 1::smallint, '2026-10-01', 'producao_restrita', NULL, false, NULL, NULL)::text$q$,
  pg_temp.id('EC'), pg_temp.id('T1.trab')))) LIKE 'ERRO 22023%', true, 'S-1200: trabalhador sem contrato com o empregador é recusado');
SELECT is(pg_temp.guarda('s1200_conta_b', pg_temp.tx_b(format($q$SELECT folha.esocial_entrada_s1200_v1(%L::uuid, %L::uuid, 1::smallint, '2026-10-01', 'producao_restrita', NULL, false, NULL, NULL)::text$q$,
  pg_temp.id('EA'), pg_temp.id('T1.trab')))) LIKE 'ERRO 22023%', true, 'S-1200: a conta B não alcança o empregador da conta A');
SELECT pg_temp.s1200('s1200_sem_folha', 'EA', 'T5.trab', '2026-10-01', 1::smallint, false);
SELECT is(pg_temp.est('s1200_sem_folha') || ':' || pg_temp.blq('s1200_sem_folha'), 'bloqueado:sem_folha_fechada', 'S-1200: trabalhador sem resultado em folha fechada do mês');
SELECT pg_temp.colab('T6', 'EA', 'clt', '98765432100', '000128', true);
INSERT INTO folha.tax_allocation (account_id, employer_id, establishment_id, codigo_lotacao, tipo_lotacao)
VALUES (:A, pg_temp.id('EA'), pg_temp.id('EA.est'), 'LOT-SINT-02', '01');
DELETE FROM folha.contract_tax_allocation WHERE contract_id = pg_temp.id('T6');
INSERT INTO folha.contract_tax_allocation (account_id, employer_id, contract_id, allocation_id, percentual, vigencia_inicio)
SELECT :A, pg_temp.id('EA'), pg_temp.id('T6'), a.allocation_id, 50, '2026-01-01' FROM folha.tax_allocation a WHERE a.account_id = :A AND a.employer_id = pg_temp.id('EA') AND a.codigo_lotacao IN ('LOT-SINT-01', 'LOT-SINT-02');
SELECT pg_temp.colab('T7', 'EA', 'clt', '11122233396', '000129', true);
SELECT pg_temp.folha('R_JUL', 'EA', '2026-07-01', 'closed', ARRAY['T3', 'T4', 'T6']);
SELECT pg_temp.s1200('s1200_t3', 'EA', 'T3.trab', '2026-07-01', 1::smallint, false);
SELECT is(pg_temp.est('s1200_t3') || ':' || pg_temp.blq('s1200_t3'), 'bloqueado:estagiario_sem_gerador', 'S-1200: estagiário (categoria 901, TSVE) não é gerado como vínculo');
SELECT pg_temp.s1200('s1200_t4', 'EA', 'T4.trab', '2026-07-01', 1::smallint, false);
SELECT is(pg_temp.est('s1200_t4') || ':' || pg_temp.blq('s1200_t4'), 'bloqueado:prestador_pj', 'S-1200: prestador PJ não gera S-1200');
SELECT pg_temp.s1200('s1200_t6', 'EA', 'T6.trab', '2026-07-01', 1::smallint, false);
SELECT is(pg_temp.est('s1200_t6') || ':' || pg_temp.blq('s1200_t6'), 'bloqueado:rateio_por_lotacao', 'S-1200: contrato rateado entre lotações não é aberto por lotação nesta versão');
SELECT pg_temp.folha('R_LIQ', 'EA', '2026-08-01', 'closed', ARRAY['T2'], NULL, 'mensal', 1, 2000.00);
INSERT INTO folha.external_remuneration (account_id, employee_id, competencia, base_previdencia, origem)
VALUES (:A, pg_temp.id('T2.trab'), '2026-08-01', 1500.00, 'Outra fonte pagadora sintetica');
SELECT pg_temp.s1200('s1200_t2_ago', 'EA', 'T2.trab', '2026-08-01', 1::smallint, false);
SELECT is(pg_temp.est('s1200_t2_ago') || ':' || pg_temp.blq('s1200_t2_ago'), 'bloqueado:itens_nao_fecham_liquido,multiplos_vinculos',
  'S-1200: itens que não fecham o líquido e remuneração de outro vínculo (infoMV não é enviado sem o grupo) bloqueiam');

-- caminho feliz: T1 / 2026-10
SELECT pg_temp.s1200('s1200_t1_nao_reg', 'EA', 'T1.trab', '2026-10-01', 1::smallint, false);
SELECT is(pg_temp.est('s1200_t1_nao_reg'), 'pronto', 'S-1200: folha fechada, sem pendência e com as rubricas cadastradas gera a entrada');
SELECT is(pg_temp.j('s1200_t1_nao_reg') #>> '{entrada,dados,perApur}', '2026-10', 'S-1200: perApur é o mês da competência');
SELECT is(pg_temp.j('s1200_t1_nao_reg') #>> '{entrada,dados,indApuracao}', '1', 'S-1200: indApuracao 1 (mensal)');
SELECT is(pg_temp.j('s1200_t1_nao_reg') #>> '{entrada,dados,trabalhador,cpfTrab}', '11144477735', 'S-1200: CPF do trabalhador');
SELECT is(pg_temp.j('s1200_t1_nao_reg') #>> '{entrada,dados,demonstrativos,0,ideDmDev}', '202610-000123-M', 'S-1200: ideDmDev derivado de competência, matrícula e processo');
SELECT is(pg_temp.j('s1200_t1_nao_reg') #>> '{entrada,dados,demonstrativos,0,codCateg}', '101', 'S-1200: categoria do vínculo');
SELECT is((pg_temp.j('s1200_t1_nao_reg') #> '{entrada,dados,demonstrativos,0,estabelecimentos,0}') - 'remuneracoes',
  '{"tpInsc": 1, "nrInsc": "11222333000181", "codLotacao": "LOT-SINT-01"}'::jsonb, 'S-1200: estabelecimento e lotação (nunca o UUID)');
SELECT is(pg_temp.j('s1200_t1_nao_reg') #>> '{entrada,dados,demonstrativos,0,estabelecimentos,0,remuneracoes,0,matricula}', '000123', 'S-1200: matrícula do cadastro, não o UUID do contrato');
SELECT is(pg_temp.j('s1200_t1_nao_reg') #> '{entrada,dados,demonstrativos,0,estabelecimentos,0,remuneracoes,0,itens}',
  '[{"codRubr": "SALARIO", "ideTabRubr": "DNEX01", "vrRubr": "3000.00", "indApurIR": 0}, {"codRubr": "INSS", "ideTabRubr": "DNEX01", "vrRubr": "281.25", "indApurIR": 0}, {"codRubr": "IRRF", "ideTabRubr": "DNEX01", "vrRubr": "12.50", "indApurIR": 0}]'::jsonb,
  'S-1200: uma linha por rubrica do resultado, com valores em texto decimal');
SELECT is(pg_temp.j('s1200_t1_nao_reg') #> '{entrada,dados,demonstrativos,0,infoComplCont}', '{"codCBO": "411010"}'::jsonb, 'S-1200: CBO do cargo');
SELECT is((SELECT string_agg(k, ',' ORDER BY k) FROM jsonb_object_keys(pg_temp.j('s1200_t1_nao_reg') #> '{entrada,dados}') k), 'demonstrativos,indApuracao,perApur,trabalhador', 'S-1200: só os grupos do leiaute (sem totais da folha nem encargos no evento)');
SELECT is((SELECT count(*) FROM folha.payroll_demonstrative WHERE account_id = :A), 0::bigint, 'S-1200: sem registrar, o ideDmDev não é gravado');
SELECT pg_temp.s1200('s1200_t1', 'EA', 'T1.trab', '2026-10-01');
SELECT is(pg_temp.est('s1200_t1'), 'pronto', 'S-1200: registrando, a entrada fica pronta');
SELECT is((SELECT estado || ':' || ind_apuracao || ':' || periodo_apuracao || ':' || (employee_id = pg_temp.id('T1.trab'))::text || ':' || (contract_id IS NULL)::text
             FROM folha.esocial_event WHERE event_id = pg_temp.id('s1200_t1')),
  'rascunho:1:2026-10-01:true:true', 'S-1200: rascunho com a chave do trabalhador, indApuracao e período (sem contrato: um evento por trabalhador)');
SELECT is((SELECT count(*) FROM folha.esocial_event_origin WHERE event_id = pg_temp.id('s1200_t1') AND run_id = pg_temp.id('R1')
             AND result_id = pg_temp.id('R1.T1')), 1::bigint, 'S-1200: a origem na folha (folha e resultado) fica ligada ao evento');
SELECT is((SELECT ide_dm_dev FROM folha.payroll_demonstrative WHERE result_id = pg_temp.id('R1.T1')), '202610-000123-M', 'S-1200: o ideDmDev é gravado ao registrar');
SELECT is((SELECT criado_por_subject FROM folha.payroll_demonstrative WHERE result_id = pg_temp.id('R1.T1')), '82000000-0000-0000-0000-000000000032'::uuid,
  'S-1200: o subject do contexto é gravado no demonstrativo');
SELECT is((SELECT count(*) FROM folha.esocial_event_payload WHERE event_id = pg_temp.id('s1200_t1')), 0::bigint, 'S-1200: nenhum XML');
UPDATE folha.contract_esocial SET matricula = '000999' WHERE contract_id = pg_temp.id('T1');
SELECT pg_temp.s1200('s1200_t1_matricula', 'EA', 'T1.trab', '2026-10-01', 1::smallint, false);
SELECT is(pg_temp.j('s1200_t1_matricula') #>> '{entrada,dados,demonstrativos,0,ideDmDev}', '202610-000123-M', 'S-1200: o ideDmDev gravado não muda se a matrícula mudar depois (estável)');
UPDATE folha.contract_esocial SET matricula = '000123' WHERE contract_id = pg_temp.id('T1');
SELECT pg_temp.s1200('s1200_t1_de_novo', 'EA', 'T1.trab', '2026-10-01');
SELECT is(pg_temp.j('s1200_t1_de_novo') ->> 'situacao', 'existente', 'S-1200: repetir é idempotente');
SELECT is((SELECT count(*) FROM folha.esocial_event WHERE evento_codigo = 'S-1200' AND employee_id = pg_temp.id('T1.trab')), 1::bigint, 'S-1200: um evento só por trabalhador e período');

-- S-1210 antes e depois do pagamento
SELECT pg_temp.s1210('s1210_sem_pgto', 'EA', 'T1.trab', '2026-11-01', false);
SELECT is(pg_temp.est('s1210_sem_pgto') || ':' || pg_temp.blq('s1210_sem_pgto'), 'bloqueado:sem_pagamento', 'S-1210: sem pagamento efetivo registrado não há S-1210 (a data nunca é deduzida)');
SELECT is(pg_temp.pagar('pg_aberta', 'R_ABERTA.T1', '2026-10-05') LIKE 'ERRO 55000%', true, 'pagamento: folha que não está fechada não tem pagamento registrado');
SELECT is(pg_temp.guarda('pg_sem_data', pg_temp.close_a(format($q$SELECT folha.esocial_entrada_pagamento_registrar_v1(%L::uuid, NULL, NULL, 1::smallint)::text$q$, pg_temp.id('R1.T1')))) LIKE 'ERRO 22023%', true,
  'pagamento: a data efetiva é obrigatória');
SELECT is(pg_temp.guarda('pg_maior', pg_temp.close_a(format($q$SELECT folha.esocial_entrada_pagamento_registrar_v1(%L::uuid, '2026-11-05', 9999.00, 1::smallint)::text$q$, pg_temp.id('R1.T1')))) LIKE 'ERRO 22023%', true,
  'pagamento: o valor pago não passa do líquido do resultado');
SELECT is(pg_temp.guarda('pg_tp2', pg_temp.close_a(format($q$SELECT folha.esocial_entrada_pagamento_registrar_v1(%L::uuid, '2026-11-05', NULL, 2::smallint)::text$q$, pg_temp.id('R1.T1')))) LIKE 'ERRO 22023%', true,
  'pagamento: tpPgto 2 só para folha de rescisão');
SELECT is(pg_temp.guarda('pg_antes', pg_temp.close_a(format($q$SELECT folha.esocial_entrada_pagamento_registrar_v1(%L::uuid, '1900-01-01', NULL, 1::smallint)::text$q$, pg_temp.id('R1.T1')))) LIKE 'ERRO 22023%anterior à competência%', true,
  'pagamento: data anterior à competência da folha é recusada');
SELECT is(pg_temp.guarda('pg_sem_close', pg_temp.so(ARRAY['folha.read', 'folha.transmit'], format($q$SELECT folha.esocial_entrada_pagamento_registrar_v1(%L::uuid, '2026-11-05', NULL, 1::smallint)::text$q$, pg_temp.id('R1.T1')))) LIKE 'ERRO 42501%', true,
  'pagamento: registrar exige folha.close');
SELECT is(pg_temp.guarda('pg_outra_conta', pg_temp.faz(pg_temp.cb(), pg_temp.todas(), '84000000-0000-0000-0000-000000000032'::uuid, format($q$SELECT folha.esocial_entrada_pagamento_registrar_v1(%L::uuid, '2026-11-05', NULL, 1::smallint)::text$q$, pg_temp.id('R1.T1')))) LIKE 'ERRO P0002%', true,
  'pagamento: resultado de outra conta não existe para quem chama');
SELECT pg_temp.pagar('pg_t1', 'R1.T1', '2026-11-05');
SELECT ok((SELECT v FROM saida WHERE k = 'pg_t1') !~ '^ERRO', 'pagamento: registrado com a data efetiva');
SELECT is((SELECT dt_pgto::text || ':' || tp_pgto || ':' || vr_liq || ':' || (registrado_por_subject = '83000000-0000-0000-0000-000000000032')::text
             FROM folha.payroll_payment WHERE result_id = pg_temp.id('R1.T1')), '2026-11-05:1:2706.25:true',
  'pagamento: data, tipo e valor líquido (o líquido do resultado quando não se informa) e o subject de quem registrou');
SELECT is((SELECT v LIKE 'ERRO 22023%' FROM (SELECT pg_temp.pagar('pg_t1_dup', 'R1.T1', '2026-11-05') AS v) x), true, 'pagamento: o mesmo pagamento não é registrado duas vezes (passaria do líquido)');
SELECT is(pg_temp.tenta(format($q$INSERT INTO folha.payroll_payment (account_id, employer_id, employee_id, run_id, result_id, dt_pgto, tp_pgto, vr_liq, registrado_por_subject)
  SELECT account_id, employer_id, employee_id, run_id, result_id, dt_pgto, tp_pgto, 1.00, registrado_por_subject FROM folha.payroll_payment WHERE result_id = %L$q$, pg_temp.id('R1.T1'))),
  'ERRO 23505', 'pagamento: a chave resultado + tipo + data é única');
SELECT pg_temp.s1210('s1210_t1_nao_reg', 'EA', 'T1.trab', '2026-11-01', false);
SELECT is(pg_temp.est('s1210_t1_nao_reg'), 'pronto', 'S-1210: com o pagamento efetivo e o S-1200 registrado, gera a entrada');
SELECT is(pg_temp.j('s1210_t1_nao_reg') #>> '{entrada,dados,perApur}', '2026-11', 'S-1210: perApur é o mês do pagamento');
SELECT is(pg_temp.j('s1210_t1_nao_reg') #>> '{entrada,dados,beneficiario,cpfBenef}', '11144477735', 'S-1210: CPF do beneficiário');
SELECT is(pg_temp.j('s1210_t1_nao_reg') #> '{entrada,dados,pagamentos}',
  '[{"dtPgto": "2026-11-05", "tpPgto": 1, "perRef": "2026-10", "ideDmDev": "202610-000123-M", "vrLiq": "2706.25"}]'::jsonb,
  'S-1210: dtPgto efetiva, perRef = competência do S-1200 (outubro), ideDmDev do S-1200 e vrLiq em texto');
SELECT pg_temp.s1210('s1210_t1', 'EA', 'T1.trab', '2026-11-01');
SELECT is((SELECT estado || ':' || periodo_apuracao FROM folha.esocial_event WHERE event_id = pg_temp.id('s1210_t1')), 'rascunho:2026-11-01', 'S-1210: rascunho no mês do pagamento');
SELECT is((SELECT count(*) FROM folha.esocial_event_origin WHERE event_id = pg_temp.id('s1210_t1')), 1::bigint, 'S-1210: origem na folha ligada ao evento');
-- sem demonstrativo (S-1200 ainda não registrado), dependente de IRRF e data prevista divergente
SELECT pg_temp.pagar('pg_t2', 'R1.T2', '2026-11-06');
SELECT pg_temp.s1210('s1210_t2', 'EA', 'T2.trab', '2026-11-01', false);
SELECT is(pg_temp.est('s1210_t2') || ':' || pg_temp.falt('s1210_t2') || ':' || pg_temp.blq('s1210_t2'),
  'bloqueado:dados.pagamentos[0].ideDmDev:info_ir_complementar',
  'S-1210: sem S-1200 registrado falta o ideDmDev; trabalhador com dependente de IRRF bloqueia (o infoIRComplem não é gerado)');
SELECT pg_temp.run_pgto('R1', '2026-12-05');
SELECT pg_temp.s1210('s1210_diverge', 'EA', 'T1.trab', '2026-11-01', false);
SELECT is(pg_temp.blq('s1210_diverge'), 'data_prevista_diverge', 'S-1210: data prevista da folha em outro mês que o pagamento efetivo bloqueia (a fila exige o mesmo mês)');
SELECT pg_temp.run_pgto('R1', '2026-11-05');
SELECT pg_temp.folha('R_RESC', 'EA', '2026-11-01', 'closed', ARRAY['T7'], NULL, 'rescisao');
SELECT pg_temp.close_a(format($q$SELECT folha.esocial_entrada_pagamento_registrar_v1(%L::uuid, '2026-11-20', NULL, 2::smallint)::text$q$, pg_temp.id('R_RESC.T7')));
SELECT pg_temp.s1210('s1210_resc', 'EA', 'T7.trab', '2026-11-01', false);
SELECT is(pg_temp.blq('s1210_resc'), 'rescisao_sem_gerador', 'S-1210: pagamento de rescisão (tpPgto 2) não é montado nesta versão');
-- plano de saúde no resultado: dedução de IRRF a declarar
SELECT pg_temp.colab('T8', 'EA', 'aprendiz', '45678912381', '000130', true);
SELECT pg_temp.folha('R_DEZ', 'EA', '2026-12-01', 'closed', ARRAY['T8']);
SELECT pg_temp.item_extra('R_DEZ.T8', 'PLANO_SAUDE', 4, 50.00);
SELECT pg_temp.pagar('pg_t8', 'R_DEZ.T8', '2027-01-05');
SELECT pg_temp.s1210('s1210_t8', 'EA', 'T8.trab', '2027-01-01', false);
SELECT is(pg_temp.blq('s1210_t8'), 'info_ir_complementar', 'S-1210: plano de saúde (ou pensão alimentícia) no resultado bloqueia: o infoIRComplem não é gerado');

-- ===========================================================================
-- 6. Retificação (recibo vigente), fechamento (S-1299), reabertura (S-1298) e exclusão (S-3000)
-- ===========================================================================
SELECT pg_temp.valida_direto('s1200_t1', '1.2.0000000000000000001');
SELECT pg_temp.s1200('s1200_t1_validado', 'EA', 'T1.trab', '2026-10-01', 1::smallint, false);
SELECT is(pg_temp.est('s1200_t1_validado') || ':' || pg_temp.blq('s1200_t1_validado'), 'bloqueado:ja_validado', 'S-1200: já validado, só a retificação explícita gera nova entrada');
SELECT pg_temp.s1200('s1200_retif_sem_motivo', 'EA', 'T1.trab', '2026-10-01', 1::smallint, false, 's1200_t1', NULL);
SELECT is(pg_temp.blq('s1200_retif_sem_motivo'), 'motivo_obrigatorio', 'S-1200: retificação exige o motivo');
SELECT is(pg_temp.guarda('s1200_retif_sem_close', pg_temp.so(ARRAY['folha.read', 'folha.transmit'], format($q$SELECT folha.esocial_entrada_s1200_v1(%L::uuid, %L::uuid, 1::smallint, '2026-10-01', 'producao_restrita', NULL, true, %L::uuid, 'corrige')::text$q$,
  pg_temp.id('EA'), pg_temp.id('T1.trab'), pg_temp.id('s1200_t1')))) LIKE 'ERRO 42501%', true, 'S-1200: retificar exige folha.close além de folha.transmit');
SELECT pg_temp.s1200('s1200_retif_igual', 'EA', 'T1.trab', '2026-10-01', 1::smallint, false, 's1200_t1', 'Sem mudança');
SELECT is(pg_temp.blq('s1200_retif_igual'), 'nada_a_retificar', 'S-1200: retificar com o conteúdo idêntico ao validado é recusado (como na função da 0031)');
UPDATE folha.contract_esocial SET cbo_cargo = '411015' WHERE contract_id = pg_temp.id('T1');
SELECT pg_temp.s1200('s1200_retif', 'EA', 'T1.trab', '2026-10-01', 1::smallint, true, 's1200_t1', 'Correção de rubrica');
UPDATE folha.contract_esocial SET cbo_cargo = '411010' WHERE contract_id = pg_temp.id('T1');
SELECT is(pg_temp.est('s1200_retif'), 'pronto', 'S-1200: retificação com o recibo vigente gera a entrada');
SELECT is(pg_temp.j('s1200_retif') #> '{entrada,dados,retificacao}', '{"nrRecibo": "1.2.0000000000000000001"}'::jsonb, 'S-1200: a retificação leva o recibo do evento validado');
SELECT is((SELECT ind_retif || ':' || (retifica_event_id = pg_temp.id('s1200_t1'))::text || ':' || versao || ':' || estado FROM folha.esocial_event WHERE event_id = pg_temp.id('s1200_retif')),
  '2:true:2:rascunho', 'S-1200: a fila guarda a retificação como versão 2 em rascunho ligada ao original');
SELECT pg_temp.s1200('s1200_retif_errada', 'EA', 'T1.trab', '2026-10-01', 1::smallint, false, 's1200_retif', 'x');
SELECT is(pg_temp.blq('s1200_retif_errada'), 'retificacao_de_outra_versao', 'S-1200: só se retifica a versão validada vigente');
SELECT pg_temp.s1200('s1200_nada_retif', 'EA', 'T7.trab', '2026-10-01', 1::smallint, false, 's1200_t1', 'x');
SELECT is(pg_temp.blq('s1200_nada_retif'), 'nada_a_retificar,sem_folha_fechada', 'S-1200: sem versão validada na chave não há o que retificar');
-- S-1299 com periódico em andamento, depois com tudo validado
SELECT pg_temp.s1299('s1299_sem_t2', 'EA', '2026-10-01', false);
SELECT is(pg_temp.blq('s1299_sem_t2'), 'periodico_sem_recibo,resultado_sem_s1200', 'S-1299: remuneração em folha fechada sem S-1200 validado (T2) impede o fechamento');
SELECT pg_temp.s1200('s1200_t2', 'EA', 'T2.trab', '2026-10-01');
SELECT pg_temp.valida_direto('s1200_t2', '1.2.0000000000000000004');
SELECT pg_temp.s1299('s1299_andamento', 'EA', '2026-10-01', false);
SELECT is(pg_temp.est('s1299_andamento') || ':' || pg_temp.blq('s1299_andamento'), 'bloqueado:periodico_sem_recibo', 'S-1299: retificação do S-1200 ainda em rascunho (sem recibo) impede o fechamento');
SELECT pg_temp.s1299('s1299_aberta', 'EA', '2026-09-01', false);
SELECT is(pg_temp.est('s1299_aberta') || ':' || pg_temp.blq('s1299_aberta'), 'bloqueado:folha_aberta', 'S-1299: folha aberta no período impede o fechamento');
SELECT pg_temp.cancela_direto('s1200_retif');
SELECT pg_temp.s1299('s1299_out_nao_reg', 'EA', '2026-10-01', false);
SELECT is(pg_temp.est('s1299_out_nao_reg'), 'pronto', 'S-1299: cancelada a retificação, a última versão validada do S-1200 libera o fechamento');
SELECT is(pg_temp.j('s1299_out_nao_reg') #> '{entrada,dados}',
  '{"indApuracao": 1, "perApur": "2026-10", "infoFech": {"evtRemun": true, "evtPgtos": false, "evtComProd": false, "evtContratAvNP": false, "evtInfoComplPer": false}}'::jsonb,
  'S-1299: as marcações do infoFech vêm da fila (há S-1200 validado, não há S-1210 de outubro)');
SELECT is(pg_temp.pend('s1299_out_nao_reg'), 'dados.infoFech.evtComProd,dados.infoFech.evtContratAvNP,dados.infoFech.evtInfoComplPer,dados.infoFech.evtRemun',
  'S-1299: S-1260, S-1270, S-1280 e S-2299 sem origem de dado viram pendência explícita');
SELECT pg_temp.s1299('s1299_out', 'EA', '2026-10-01');
SELECT is((SELECT estado || ':' || ciclo FROM folha.esocial_event WHERE event_id = pg_temp.id('s1299_out')), 'rascunho:1', 'S-1299: rascunho do primeiro ciclo na fila');
SELECT is(pg_temp.s1298('s1298_antes', 'EA', '2026-10-01', false) IS NOT NULL AND pg_temp.est('s1298_antes') = 'bloqueado' AND pg_temp.blq('s1298_antes') = 'periodo_nao_fechado', true,
  'S-1298: período cujo S-1299 ainda não foi validado não se reabre');
SELECT pg_temp.valida_direto('s1299_out', '1.2.0000000000000000003');
SELECT pg_temp.s1200('s1200_fechado', 'EA', 'T2.trab', '2026-10-01', 1::smallint, false);
SELECT is(pg_temp.blq('s1200_fechado'), 'ja_validado,periodo_fechado', 'S-1200: período fechado no eSocial bloqueia evento periódico até o S-1298');
SELECT pg_temp.s1298('s1298_out', 'EA', '2026-10-01');
SELECT is(pg_temp.est('s1298_out'), 'pronto', 'S-1298: período fechado com recibo do S-1299 guardado gera a entrada');
SELECT is(pg_temp.j('s1298_out') #> '{entrada,dados}', '{"indApuracao": 1, "perApur": "2026-10"}'::jsonb, 'S-1298: só indApuracao e perApur (o leiaute não tem campo de recibo)');
SELECT is((SELECT estado || ':' || ciclo FROM folha.esocial_event WHERE event_id = pg_temp.id('s1298_out')), 'rascunho:1', 'S-1298: rascunho do ciclo na fila');
SELECT is(pg_temp.guarda('s1298_sem_close', pg_temp.so(ARRAY['folha.read', 'folha.transmit'], format($q$SELECT folha.esocial_entrada_s1298_v1(%L::uuid, 1::smallint, '2026-10-01', 'producao_restrita', NULL, true)::text$q$, pg_temp.id('EA')))) LIKE 'ERRO 42501%', true,
  'S-1298: reabrir exige folha.close além de folha.transmit');
SELECT is(pg_temp.guarda('s1298_nov', pg_temp.tx_a(format($q$SELECT folha.esocial_entrada_s1298_v1(%L::uuid, 1::smallint, '2026-11-01', 'producao_restrita', NULL, false)::text$q$, pg_temp.id('EA')))) LIKE '%periodo_nao_fechado%', true,
  'S-1298: período que nunca foi fechado não se reabre');
-- S-1299 de novembro (S-1210 em rascunho, depois validado)
SELECT pg_temp.s1299('s1299_nov_andamento', 'EA', '2026-11-01', false);
SELECT is(pg_temp.blq('s1299_nov_andamento'), 'pagamento_sem_s1210,pagamento_sem_s1210,pagamento_sem_s1210,periodico_sem_recibo,processo_sem_gerador',
  'S-1299: S-1210 de T1 em rascunho, pagamentos de T1, T2 e T7 sem S-1210 validado e folha de rescisão (sem gerador) impedem o fechamento');
SELECT pg_temp.valida_direto('s1210_t1', '1.2.0000000000000000002');
SELECT pg_temp.s1299('s1299_nov', 'EA', '2026-11-01', false);
SELECT is(pg_temp.est('s1299_nov') || ':' || pg_temp.blq('s1299_nov'), 'bloqueado:pagamento_sem_s1210,pagamento_sem_s1210,processo_sem_gerador',
  'S-1299: com o S-1210 de T1 validado, ainda bloqueia pelos pagamentos de T2 e T7 sem S-1210 e pela rescisão (o caso positivo de novembro roda no cenário do CI)');

-- S-3000: recibo do evento original guardado na fila
SELECT pg_temp.s2200('s2200_t7', 'EA', 'T7');
SELECT pg_temp.s3000('s3000_rascunho', 's2200_t7', 'Admissão lançada por engano');
SELECT is(pg_temp.est('s3000_rascunho') || ':' || pg_temp.blq('s3000_rascunho'), 'bloqueado:sem_recibo,versao_em_andamento', 'S-3000: evento original sem recibo (ainda rascunho, versão em andamento) não se exclui');
SELECT pg_temp.valida_direto('s2200_t7', '1.2.0000000000000000011');
SELECT pg_temp.s3000('s3000_sem_motivo', 's2200_t7', '  ', false);
SELECT is(pg_temp.blq('s3000_sem_motivo'), 'motivo_obrigatorio', 'S-3000: a exclusão exige o motivo');
SELECT pg_temp.s3000('s3000_t7_nao_reg', 's2200_t7', 'Admissão lançada por engano', false);
SELECT is(pg_temp.est('s3000_t7_nao_reg'), 'pronto', 'S-3000: com o recibo vigente do original, gera a entrada');
SELECT is(pg_temp.j('s3000_t7_nao_reg') #> '{entrada,dados}',
  '{"tpEvento": "S-2200", "nrRecEvt": "1.2.0000000000000000011", "trabalhador": {"cpfTrab": "11122233396"}}'::jsonb,
  'S-3000 de admissão: tpEvento, recibo guardado na fila e CPF do trabalhador (sem folhaPagto)');
SELECT pg_temp.s3000('s3000_t7', 's2200_t7', 'Admissão lançada por engano');
SELECT is((SELECT estado || ':' || (exclui_event_id = pg_temp.id('s2200_t7'))::text || ':' || ind_retif FROM folha.esocial_event WHERE event_id = pg_temp.id('s3000_t7')),
  'rascunho:true:1', 'S-3000: rascunho na fila apontando o evento excluído');
SELECT is((SELECT origem_hash FROM folha.esocial_event WHERE event_id = pg_temp.id('s3000_t7')),
  encode(sha256(convert_to('S-3000|' || pg_temp.id('s2200_t7')::text || '|1.2.0000000000000000011', 'UTF8')), 'hex'),
  'S-3000: o hash de origem é o mesmo de esocial_evento_excluir_v1');
SELECT is(pg_temp.tx_a(format($q$SELECT (folha.esocial_evento_excluir_v1(%L::uuid, 'Admissão lançada por engano') ->> 'situacao')$q$, pg_temp.id('s2200_t7'))), 'existente',
  'S-3000: a função da 0031 reconhece o mesmo rascunho (idempotente entre as duas portas)');
SELECT pg_temp.s3000('s3000_s1210', 's1210_t1', 'Pagamento ao CPF errado', false);
SELECT is(pg_temp.j('s3000_s1210') #> '{entrada,dados,folhaPagto}', '{"perApur": "2026-11"}'::jsonb, 'S-3000 de pagamento: perApur é o mês do pagamento, sem indApuracao');
SELECT pg_temp.s3000('s3000_s1200', 's1200_t1', 'Remuneração do CPF errado', false);
SELECT is(pg_temp.est('s3000_s1200') || ':' || pg_temp.blq('s3000_s1200'), 'bloqueado:dependentes_enviados,periodo_fechado',
  'S-3000: período fechado (S-1299 validado) exige reabrir antes de excluir evento periódico; o S-1299 validado depende do S-1200');
SELECT pg_temp.s3000('s3000_s1299', 's1299_out', 'Fechamento indevido', false);
SELECT is(pg_temp.blq('s3000_s1299'), 'tipo_nao_excluivel_nesta_versao', 'S-3000: o fechamento não se exclui (reabre-se com o S-1298)');
SELECT pg_temp.s2200('s2200_t2', 'EA', 'T2');
SELECT pg_temp.valida_direto('s2200_t2', '1-2-ABC');
SELECT pg_temp.s3000('s3000_recibo_ruim', 's2200_t2', 'x', false);
SELECT is(pg_temp.blq('s3000_recibo_ruim'), 'dependentes_enviados,recibo_fora_do_formato', 'S-3000: recibo fora do formato do leiaute bloqueia');
SELECT pg_temp.s2200('s2200_t2_retif_ruim', 'EA', 'T2', false, 's2200_t2', 'x');
SELECT is(pg_temp.blq('s2200_t2_retif_ruim'), 'recibo_fora_do_formato', 'S-2200: retificar com recibo fora do formato do leiaute bloqueia');
SELECT is(pg_temp.guarda('s3000_outra_conta', pg_temp.tx_b(format($q$SELECT folha.esocial_entrada_s3000_v1(%L::uuid, 'x', NULL, false)::text$q$, pg_temp.id('s2200_t7')))) LIKE 'ERRO P0002%', true,
  'S-3000: evento de outra conta não existe para quem chama');
SELECT is(pg_temp.guarda('s3000_sem_close', pg_temp.so(ARRAY['folha.read', 'folha.transmit'], format($q$SELECT folha.esocial_entrada_s3000_v1(%L::uuid, 'x', NULL, true)::text$q$, pg_temp.id('s2200_t7')))) LIKE 'ERRO 42501%', true,
  'S-3000: registrar a exclusão exige folha.close além de folha.transmit');

-- Aprendiz sem os dados de aprendizagem
SELECT pg_temp.s2200('s2200_t8', 'EA', 'T8', false);
SELECT is(pg_temp.falt('s2200_t8'), 'dados.vinculo.infoCeletista.aprend', 'S-2200: aprendiz sem os dados de aprendizagem fica incompleto');

-- ===========================================================================
-- 6.1 Permissão e conta, função por função (registrando)
-- ===========================================================================
CREATE TEMP TABLE chamadas (nome text PRIMARY KEY, sql text NOT NULL);
INSERT INTO chamadas VALUES
  ('s1000', format($q$SELECT folha.esocial_entrada_s1000_v1(%L::uuid, '2026-01-01', 'producao_restrita', NULL, true)::text$q$, pg_temp.id('EA'))),
  ('s1005', format($q$SELECT folha.esocial_entrada_s1005_v1(%L::uuid, '2026-01-01', 'producao_restrita', NULL, true)::text$q$, pg_temp.id('EA.est'))),
  ('s1010', format($q$SELECT folha.esocial_entrada_s1010_v1(%L::uuid, %L::uuid, '2026-01-01', 'producao_restrita', NULL, true)::text$q$,
                  pg_temp.id('EA'), (SELECT code_id FROM folha.earning_deduction_code WHERE account_id IS NULL AND codigo = 'SALARIO_BASE'))),
  ('s1020', format($q$SELECT folha.esocial_entrada_s1020_v1(%L::uuid, '2026-01-01', 'producao_restrita', NULL, true)::text$q$, pg_temp.id('EA.lot'))),
  ('s1200', format($q$SELECT folha.esocial_entrada_s1200_v1(%L::uuid, %L::uuid, 1::smallint, '2026-10-01', 'producao_restrita', NULL, true, NULL, NULL)::text$q$, pg_temp.id('EA'), pg_temp.id('T1.trab'))),
  ('s1210', format($q$SELECT folha.esocial_entrada_s1210_v1(%L::uuid, %L::uuid, '2026-11-01', 'producao_restrita', NULL, true, NULL, NULL)::text$q$, pg_temp.id('EA'), pg_temp.id('T1.trab'))),
  ('s2200', format($q$SELECT folha.esocial_entrada_s2200_v1(%L::uuid, %L::uuid, 'producao_restrita', NULL, true, NULL, NULL)::text$q$, pg_temp.id('EA'), pg_temp.id('T1'))),
  ('s1298', format($q$SELECT folha.esocial_entrada_s1298_v1(%L::uuid, 1::smallint, '2026-10-01', 'producao_restrita', NULL, true)::text$q$, pg_temp.id('EA'))),
  ('s1299', format($q$SELECT folha.esocial_entrada_s1299_v1(%L::uuid, 1::smallint, '2026-10-01', 'producao_restrita', NULL, true)::text$q$, pg_temp.id('EA'))),
  ('s3000', format($q$SELECT folha.esocial_entrada_s3000_v1(%L::uuid, 'motivo', NULL, true)::text$q$, pg_temp.id('s2200_t7'))),
  ('pagamento', format($q$SELECT folha.esocial_entrada_pagamento_registrar_v1(%L::uuid, '2026-11-05', NULL, 1::smallint)::text$q$, pg_temp.id('R1.T1')));
SELECT is(pg_temp.so(ARRAY['folha.read', 'folha.calculate'], c.sql) LIKE 'ERRO 42501%', true, c.nome || ': sem a permissão da operação (folha.transmit ou folha.close) é recusado com 42501')
  FROM chamadas c ORDER BY c.nome;
SELECT is(pg_temp.pedido(NULL, NULL, NULL, false, false, ARRAY[c.sql]) LIKE 'ERRO 42501%', true, c.nome || ': sem contexto da Folha é recusado com 42501')
  FROM chamadas c ORDER BY c.nome;
SELECT is(pg_temp.tx_b(c.sql) ~ '^ERRO (22023|P0002): .*(não encontrad|não é deste|não tem contrato)', true, c.nome || ': com o contexto da conta B os ids da conta A não existem (nada vaza)')
  FROM chamadas c ORDER BY c.nome;
SELECT is((SELECT count(*) FROM folha.esocial_event WHERE account_id = :B), 0::bigint, 'nenhuma chamada recusada deixou evento na conta B');

-- ===========================================================================
-- 7. Isolamento entre contas
-- ===========================================================================
SELECT pg_temp.guarda('s2200_tb', pg_temp.tx_b(format($q$SELECT folha.esocial_entrada_s2200_v1(%L::uuid, %L::uuid, 'producao_restrita', %L::timestamp, true, NULL, NULL)::text$q$,
  pg_temp.id('EB'), pg_temp.id('TB'), pg_temp.ger())), pg_temp.cb());
SELECT is(pg_temp.j('s2200_tb') ->> 'estado', 'pronto', 'conta B: o mesmo CNPJ e CPF sintéticos geram a própria entrada');
SELECT is((SELECT account_id FROM folha.esocial_event WHERE event_id = (SELECT (v::jsonb ->> 'event_id')::uuid FROM saida WHERE k = 's2200_tb')), :B::uuid,
  'conta B: o evento nasce na conta de quem chamou, não na da conta A');
SELECT is((SELECT count(*) FROM folha.esocial_event WHERE account_id = :B), 1::bigint, 'conta B: um evento só (nada da conta A vazou para ela)');
SELECT is((SELECT count(*) FROM folha.esocial_entrada WHERE account_id = :B), 1::bigint, 'conta B: um registro de entrada só');
CREATE POLICY ci_leitura_temporaria ON folha.esocial_entrada FOR SELECT TO dnex_folha_ci_login USING (account_id = (SELECT folha.current_account_id()));
SELECT is(pg_temp.com_espelho(:B, pg_temp.todas(), '84000000-0000-0000-0000-000000000032'::uuid,
  'SELECT count(*)::text FROM folha.esocial_entrada'), '1', 'RLS: a conta B enxerga só o registro de entrada dela');
SELECT is(pg_temp.com_espelho(:A, pg_temp.todas(), '82000000-0000-0000-0000-000000000032'::uuid,
  'SELECT count(*)::text FROM folha.esocial_entrada WHERE account_id = ' || quote_literal(:B)), '0', 'RLS: a conta A não enxerga registro de entrada da conta B');
SELECT is((pg_temp.com_espelho(:A, pg_temp.todas(), '82000000-0000-0000-0000-000000000032'::uuid,
  'SELECT count(*)::text FROM folha.esocial_entrada'))::int > 1, true, 'RLS: a conta A enxerga os registros dela');
DROP POLICY ci_leitura_temporaria ON folha.esocial_entrada;
SELECT is(pg_temp.com_espelho(:B, pg_temp.todas(), '84000000-0000-0000-0000-000000000032'::uuid,
  'SELECT count(*)::text FROM folha.employee_esocial'), '1', 'RLS: a conta B enxerga só o cadastro do trabalhador dela');
SELECT is((pg_temp.com_espelho(:A, pg_temp.todas(), '82000000-0000-0000-0000-000000000032'::uuid,
  'SELECT count(*)::text FROM folha.employee_esocial'))::int >= 5, true, 'RLS: a conta A enxerga os cadastros dela, e só os dela');
SELECT is(pg_temp.com_espelho(:A, pg_temp.todas(), '82000000-0000-0000-0000-000000000032'::uuid,
  'SELECT count(*)::text FROM folha.contract_esocial WHERE account_id = ' || quote_literal(:B)), '0', 'RLS: a conta A não enxerga vínculo da conta B');
SELECT is(pg_temp.com_espelho(:A, pg_temp.todas(), '82000000-0000-0000-0000-000000000032'::uuid,
  'SELECT count(*)::text FROM folha.rubric_esocial_config WHERE account_id = ' || quote_literal(:B)), '0', 'RLS: a conta A não enxerga rubrica configurada da conta B');

-- ===========================================================================
-- 8. Histórico imutável
-- ===========================================================================
SELECT is(pg_temp.tenta('UPDATE folha.esocial_entrada SET estado = estado'), 'ERRO 55000', 'esocial_entrada: UPDATE é proibido (histórico)');
SELECT is(pg_temp.tenta('DELETE FROM folha.esocial_entrada'), 'ERRO 55000', 'esocial_entrada: DELETE é proibido');
SELECT is(pg_temp.tenta('TRUNCATE folha.esocial_entrada'), 'ERRO 55000', 'esocial_entrada: TRUNCATE é proibido');
SELECT is(pg_temp.tenta('UPDATE folha.payroll_demonstrative SET ide_dm_dev = ide_dm_dev'), 'ERRO 55000', 'payroll_demonstrative: UPDATE é proibido (o ideDmDev é estável)');
SELECT is(pg_temp.tenta('DELETE FROM folha.payroll_demonstrative'), 'ERRO 55000', 'payroll_demonstrative: DELETE é proibido');
SELECT is(pg_temp.tenta('UPDATE folha.payroll_payment SET dt_pgto = dt_pgto'), 'ERRO 55000', 'payroll_payment: UPDATE é proibido (pagamento efetivo)');
SELECT is(pg_temp.tenta('DELETE FROM folha.payroll_payment'), 'ERRO 55000', 'payroll_payment: DELETE é proibido');
SELECT is(pg_temp.tenta('TRUNCATE folha.payroll_payment'), 'ERRO 55000', 'payroll_payment: TRUNCATE é proibido');
SELECT is((SELECT count(*) FROM folha.esocial_event WHERE account_id = :A AND payload_hash IS NOT NULL AND estado <> 'validado'), 0::bigint,
  'fila: nenhum evento criado pela entrada tem hash de XML (só os validados à mão no teste)');
SELECT is((SELECT count(*) FROM folha.esocial_event_payload WHERE account_id IN (:A, :B)), 0::bigint, 'fila: nenhum XML foi guardado em lugar nenhum');
SELECT is((SELECT count(*) FROM folha.esocial_entrada WHERE entrada::text ~ '(?i)<\?xml|<evt|signature'), 0::bigint, 'entrada: nenhuma entrada contém XML');
SELECT is((SELECT count(*) FROM folha.esocial_entrada e WHERE e.estado = 'pronto' AND (e.entrada ->> 'evento') <> e.evento_codigo), 0::bigint,
  'entrada: o evento do envelope é o do registro');
SELECT is((SELECT count(*) FROM folha.esocial_entrada e WHERE e.estado <> 'pronto' AND e.entrada IS NOT NULL), 0::bigint,
  'entrada: incompleta ou bloqueada nunca guarda entrada (nada de valor inventado)');
SELECT is((SELECT count(*) FROM folha.esocial_entrada e WHERE e.estado = 'pronto' AND jsonb_path_exists(e.entrada, '$.** ? (@ == "" || (@.type() == "array" && @.size() == 0) || (@.type() == "object" && @.size() == 0))')), 0::bigint,
  'entrada: nenhum campo com texto vazio, lista vazia ou objeto vazio');
SELECT is((SELECT count(DISTINCT evento_codigo) FROM folha.esocial_entrada WHERE estado = 'pronto' AND account_id = :A), 10::bigint,
  'as dez entradas (S-1000, S-1005, S-1010, S-1020, S-1200, S-1210, S-2200, S-1298, S-1299, S-3000) tiveram caminho feliz neste arquivo');

SELECT * FROM finish();
ROLLBACK;
