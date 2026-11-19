-- DNEX Folha — cenário SINTÉTICO da verificação do contrato de entrada dos geradores do eSocial.
--
-- Usado por scripts/validar_entrada_eventos.mjs (e roda no CI, sem segredo): monta um empregador sintético,
-- chama as funções folha.esocial_entrada_*_v1 pela sessão de aplicação (contexto real, login de teste membro só
-- de dnex_gestao_api) e imprime uma linha "@@RESULT@@<chave>@@<json>" por chamada. O script Node valida a
-- "entrada" de cada resultado pronto contra o JSON Schema do gerador (contracts/esocial/entrada-evento.schema.json).
-- Tudo roda numa transação e é desfeito no fim. Nomes, CPFs e inscrições são SINTÉTICOS (os números dos
-- fixtures do gerador). Pré-requisito: o banco com bootstrap e as migrations 0014 a 0032 (tests/ci/replay.sh).
\set ON_ERROR_STOP on
BEGIN;
\set A '''a0000000-0000-0000-0000-0000000000c1'''

-- ---------------------------------------------------------------------------
-- Apoio (o mesmo do tests/folha/0032_entrada_eventos.pgtap.sql)
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE escopo (conta uuid PRIMARY KEY, entidade uuid NOT NULL, filial uuid NOT NULL);
INSERT INTO escopo VALUES
  (:A, 'a1000000-0000-0000-0000-0000000000c1', 'a2000000-0000-0000-0000-0000000000c1');
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
CREATE FUNCTION pg_temp.ca() RETURNS uuid LANGUAGE sql AS $$ SELECT 'a0000000-0000-0000-0000-0000000000c1'::uuid $$;
CREATE FUNCTION pg_temp.cb() RETURNS uuid LANGUAGE sql AS $$ SELECT 'b0000000-0000-0000-0000-0000000000c1'::uuid $$;
-- tx = todas as permissões, subject S_TX; lei_a = igual, sem persistir
CREATE FUNCTION pg_temp.tx_a(p_sql text) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.faz(pg_temp.ca(), pg_temp.todas(), '82000000-0000-0000-0000-0000000000c1'::uuid, p_sql) $$;
CREATE FUNCTION pg_temp.lei_a(p_sql text) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.le(pg_temp.ca(), pg_temp.todas(), '82000000-0000-0000-0000-0000000000c1'::uuid, p_sql) $$;
CREATE FUNCTION pg_temp.tx_b(p_sql text) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.faz(pg_temp.cb(), pg_temp.todas(), '84000000-0000-0000-0000-0000000000c1'::uuid, p_sql) $$;
CREATE FUNCTION pg_temp.close_a(p_sql text) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.faz(pg_temp.ca(), pg_temp.todas(), '83000000-0000-0000-0000-0000000000c1'::uuid, p_sql) $$;
-- só as permissões dadas (S_TX), persistindo
CREATE FUNCTION pg_temp.so(p_perm text[], p_sql text) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.faz(pg_temp.ca(), p_perm, '82000000-0000-0000-0000-0000000000c1'::uuid, p_sql) $$;

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
-- Cenário sintético (superusuário; gatilhos de folha desligados só onde a 0031 também desliga)
-- ---------------------------------------------------------------------------
-- Empregador completo (CNPJ do fixture do gerador), com estabelecimento, lotação, regime e cadastros do eSocial.
CREATE FUNCTION pg_temp.empregador(p_k text, p_conta uuid, p_cnpj text, p_completo boolean) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  v_emp uuid; v_est uuid; v_lot uuid;
BEGIN
  INSERT INTO folha.employer (account_id, tipo_inscricao, inscricao, razao_social, classificacao_tributaria)
  VALUES (p_conta, 'cnpj', p_cnpj, 'Empresa Sintetica ' || p_k, NULL) RETURNING employer_id INTO v_emp;
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
    INSERT INTO folha.rubric_esocial_config (account_id, employer_id, code_id, cod_rubr, ide_tab_rubr, vigencia_inicio)
    SELECT p_conta, v_emp, c.code_id, x.cod_rubr, 'DNEX01', '2026-01-01'
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
         '82000000-0000-0000-0000-0000000000c1', '82000000-0000-0000-0000-0000000000c1'
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

-- Imprime o resultado de uma chamada pela sessão de aplicação (jsonb em uma linha)
CREATE FUNCTION pg_temp.emite(p_k text, p_v text) RETURNS text LANGUAGE sql AS $$
  SELECT '@@RESULT@@' || p_k || '@@' || regexp_replace(p_v, E'[\n\r]+', ' ', 'g') $$;
CREATE FUNCTION pg_temp.ev(p_k text, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v text; v_id uuid;
BEGIN
  v := pg_temp.tx_a(p_sql);
  IF v LIKE '{%' THEN
    v_id := (v::jsonb ->> 'event_id')::uuid;
    IF v_id IS NOT NULL THEN
      INSERT INTO ids VALUES (p_k, v_id, pg_temp.ca()) ON CONFLICT (k) DO UPDATE SET id = EXCLUDED.id;
    END IF;
  END IF;
  RETURN pg_temp.emite(p_k, v);
END $$;
CREATE FUNCTION pg_temp.amb() RETURNS text LANGUAGE sql AS $$ SELECT 'producao_restrita' $$;
CREATE FUNCTION pg_temp.ger() RETURNS text LANGUAGE sql AS $$ SELECT '2026-11-18 09:00:00' $$;
CREATE FUNCTION pg_temp.valida(p_k text, p_recibo text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_e folha.esocial_event;
  v_lot uuid;
BEGIN
  SELECT * INTO STRICT v_e FROM folha.esocial_event WHERE event_id = pg_temp.id(p_k);
  PERFORM set_config('session_replication_role', 'replica', true);
  INSERT INTO folha.esocial_lot (account_id, employer_id, ambiente, grupo, situacao, protocolo, codigo_resposta, qtd_eventos,
                                 enviado_por_subject, atualizado_por_subject)
  SELECT v_e.account_id, v_e.employer_id, v_e.ambiente, c.grupo, 'processado', 'PROT-' || p_k, '201', 1,
         '82000000-0000-0000-0000-0000000000c1', '82000000-0000-0000-0000-0000000000c1'
    FROM folha.esocial_event_catalog c WHERE c.evento_codigo = v_e.evento_codigo
  RETURNING lot_id INTO v_lot;
  UPDATE folha.esocial_event SET estado = 'validado', lot_id = v_lot, payload_hash = repeat('a', 64), assinado_hash = repeat('b', 64),
         recibo_numero = p_recibo WHERE event_id = v_e.event_id;
  PERFORM set_config('session_replication_role', 'origin', true);
END $$;

-- Cenário: empregador sintético e colaboradores (T1 completo; T3 estagiário; T5 sem cadastro do eSocial; T7 para o S-3000)
SELECT pg_temp.empregador('EA', :A, '11222333000181', true);
SELECT pg_temp.colab('T1', 'EA', 'clt', '11144477735', '000123', true);
SELECT pg_temp.colab('T3', 'EA', 'estagio', '39053344705', '000125', true);
SELECT pg_temp.colab('T5', 'EA', 'clt', '12345678909', '000127', false);
SELECT pg_temp.colab('T7', 'EA', 'clt', '11122233396', '000129', true);
SELECT pg_temp.folha('R_ABERTA', 'EA', '2026-09-01', 'calculated', ARRAY['T1']);
SELECT pg_temp.folha('R1', 'EA', '2026-10-01', 'closed', ARRAY['T1']);
-- tabelas de apoio do S-1010 (códigos de FIXTURE, a_validar: o leiaute local não os enumera)
UPDATE folha.incidence_code SET codigo_esocial = '11' WHERE (tributo, codigo) IN (('previdencia', 'BASE_MENSAL'), ('irrf', 'BASE_MENSAL'), ('fgts', 'BASE_MENSAL'));
INSERT INTO folha.esocial_rubric_nature (codigo, descricao, vigencia_inicio, fonte) VALUES ('1000', 'fixture sintetico', '2020-01-01', 'fixture do cenario sintetico');
INSERT INTO folha.rubric_esocial_nature (account_id, code_id, natureza_codigo, vigencia_inicio)
SELECT NULL, code_id, '1000', '2026-01-01' FROM folha.earning_deduction_code WHERE account_id IS NULL AND codigo = 'SALARIO_BASE';

-- Tabelas
SELECT pg_temp.ev('s1000', format($q$SELECT folha.esocial_entrada_s1000_v1(%L::uuid, '2026-01-01', %L, %L::timestamp, true)::text$q$, pg_temp.id('EA'), pg_temp.amb(), pg_temp.ger()));
SELECT pg_temp.ev('s1005', format($q$SELECT folha.esocial_entrada_s1005_v1(%L::uuid, '2026-01-01', %L, %L::timestamp, true)::text$q$, pg_temp.id('EA.est'), pg_temp.amb(), pg_temp.ger()));
SELECT pg_temp.ev('s1020', format($q$SELECT folha.esocial_entrada_s1020_v1(%L::uuid, '2026-01-01', %L, %L::timestamp, true)::text$q$, pg_temp.id('EA.lot'), pg_temp.amb(), pg_temp.ger()));
SELECT pg_temp.ev('s1010', format($q$SELECT folha.esocial_entrada_s1010_v1(%L::uuid, %L::uuid, '2026-01-01', %L, %L::timestamp, true)::text$q$,
  pg_temp.id('EA'), (SELECT code_id FROM folha.earning_deduction_code WHERE account_id IS NULL AND codigo = 'SALARIO_BASE'), pg_temp.amb(), pg_temp.ger()));
SELECT pg_temp.ev('s1010_inss_sem_natureza', format($q$SELECT folha.esocial_entrada_s1010_v1(%L::uuid, %L::uuid, '2026-01-01', %L, %L::timestamp, false)::text$q$,
  pg_temp.id('EA'), (SELECT code_id FROM folha.earning_deduction_code WHERE account_id IS NULL AND codigo = 'INSS_EMPREGADO'), pg_temp.amb(), pg_temp.ger()));
-- Vínculos
SELECT pg_temp.ev('s2200_t1', format($q$SELECT folha.esocial_entrada_s2200_v1(%L::uuid, %L::uuid, %L, %L::timestamp, true, NULL, NULL)::text$q$, pg_temp.id('EA'), pg_temp.id('T1'), pg_temp.amb(), pg_temp.ger()));
SELECT pg_temp.ev('s2200_t3_estagio', format($q$SELECT folha.esocial_entrada_s2200_v1(%L::uuid, %L::uuid, %L, %L::timestamp, true, NULL, NULL)::text$q$, pg_temp.id('EA'), pg_temp.id('T3'), pg_temp.amb(), pg_temp.ger()));
SELECT pg_temp.ev('s2200_t5_incompleto', format($q$SELECT folha.esocial_entrada_s2200_v1(%L::uuid, %L::uuid, %L, %L::timestamp, true, NULL, NULL)::text$q$, pg_temp.id('EA'), pg_temp.id('T5'), pg_temp.amb(), pg_temp.ger()));
SELECT pg_temp.ev('s2200_t7', format($q$SELECT folha.esocial_entrada_s2200_v1(%L::uuid, %L::uuid, %L, %L::timestamp, true, NULL, NULL)::text$q$, pg_temp.id('EA'), pg_temp.id('T7'), pg_temp.amb(), pg_temp.ger()));
-- Remuneração: folha aberta (bloqueado) e folha fechada (pronto)
SELECT pg_temp.ev('s1200_aberta', format($q$SELECT folha.esocial_entrada_s1200_v1(%L::uuid, %L::uuid, 1::smallint, '2026-09-01', %L, %L::timestamp, true, NULL, NULL)::text$q$, pg_temp.id('EA'), pg_temp.id('T1.trab'), pg_temp.amb(), pg_temp.ger()));
SELECT pg_temp.ev('s1200_t1', format($q$SELECT folha.esocial_entrada_s1200_v1(%L::uuid, %L::uuid, 1::smallint, '2026-10-01', %L, %L::timestamp, true, NULL, NULL)::text$q$, pg_temp.id('EA'), pg_temp.id('T1.trab'), pg_temp.amb(), pg_temp.ger()));
-- Pagamento efetivo e S-1210
SELECT pg_temp.close_a(format($q$SELECT folha.esocial_entrada_pagamento_registrar_v1(%L::uuid, '2026-11-05', NULL, 1::smallint)::text$q$, pg_temp.id('R1.T1'))) IS NOT NULL AS pagamento_registrado \gset
SELECT pg_temp.ev('s1210_t1', format($q$SELECT folha.esocial_entrada_s1210_v1(%L::uuid, %L::uuid, '2026-11-01', %L, %L::timestamp, true, NULL, NULL)::text$q$, pg_temp.id('EA'), pg_temp.id('T1.trab'), pg_temp.amb(), pg_temp.ger()));
-- Fechamento do mês 10 (S-1200 validado pelo governo, simulado), reabertura e fechamento do mês 11
SELECT pg_temp.valida('s1200_t1', '1.2.0000000000000000001') \gset
SELECT pg_temp.ev('s1299_out', format($q$SELECT folha.esocial_entrada_s1299_v1(%L::uuid, 1::smallint, '2026-10-01', %L, %L::timestamp, true)::text$q$, pg_temp.id('EA'), pg_temp.amb(), pg_temp.ger()));
SELECT pg_temp.valida('s1299_out', '1.2.0000000000000000003') \gset
SELECT pg_temp.ev('s1298_out', format($q$SELECT folha.esocial_entrada_s1298_v1(%L::uuid, 1::smallint, '2026-10-01', %L, %L::timestamp, true)::text$q$, pg_temp.id('EA'), pg_temp.amb(), pg_temp.ger()));
SELECT pg_temp.valida('s1210_t1', '1.2.0000000000000000002') \gset
SELECT pg_temp.ev('s1299_nov', format($q$SELECT folha.esocial_entrada_s1299_v1(%L::uuid, 1::smallint, '2026-11-01', %L, %L::timestamp, false)::text$q$, pg_temp.id('EA'), pg_temp.amb(), pg_temp.ger()));
-- Exclusão de uma admissão validada
SELECT pg_temp.valida('s2200_t7', '1.2.0000000000000000011') \gset
SELECT pg_temp.ev('s3000_t7', format($q$SELECT folha.esocial_entrada_s3000_v1(%L::uuid, 'Admissao lancada por engano', %L::timestamp, true)::text$q$, pg_temp.id('s2200_t7'), pg_temp.ger()));

ROLLBACK;
