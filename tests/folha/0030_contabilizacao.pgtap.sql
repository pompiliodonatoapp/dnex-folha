-- DNEX Folha — Testes pgTAP da migration 0030: contabilização com partida fechada e provisões.
--
-- Casos dourados: GC-01 a GC-08 do parecer técnico contábil de 15/11/2026, em centavos. Os
-- valores esperados são os do parecer; nenhum foi ajustado. INSS do segurado, IRRF, FGTS e
-- encargos patronais são DADOS DE ENTRADA dos casos (hipotéticos), como o parecer define: o
-- teste é da contabilização, não do motor tributário. Por isso as folhas dos casos são
-- gravadas direto nas tabelas do resultado (itens por rubrica e encargos por lotação na
-- memória de cálculo), como superusuário e com os gatilhos desligados, e a contabilização é
-- sempre chamada pelo caminho real (funções folha.contabil_*_v1, com claim da Folha). A
-- exceção é o GC-03 (provisão), em que os encargos vêm de folha.calc_encargos_patronais com
-- as alíquotas hipotéticas do parecer cadastradas na lotação (20% + 2% x FAP 1,0000 + 5,8%).
-- As contas dos casos são as do mapeamento da empresa de teste (o parecer indica só a
-- natureza): DESP.* despesa, PASS.* passivo, ATV.* ativo, RED.* redutora, CUSTO.* custo.
--
-- Casos rotulados "derivado" não são do parecer: a conta está no comentário.
--
-- Como o arquivo roda: superusuário no nível de cima. O que vale "para uma sessão de
-- aplicação" passa por pg_temp.pedido() (igual ao dos arquivos 0028 e 0029: asserção com claim
-- da Folha pelo caminho real, login de teste membro só de dnex_gestao_api e begin_request;
-- ver o cabeçalho do 0028 sobre trocar de contexto dentro da transação do teste). Devolve o
-- resultado do último comando como texto, ou 'ERRO <sqlstate>: <mensagem>'.
-- Nomes, CPFs e inscrições são fictícios. Nada é persistido (ROLLBACK no final).
BEGIN;

SELECT plan(213);

\set A '''a0000000-0000-0000-0000-000000000030'''
\set B '''b0000000-0000-0000-0000-000000000030'''
\set S_ADMIN '''81000000-0000-0000-0000-000000000001'''
\set S_TX    '''82000000-0000-0000-0000-000000000002'''
\set S_CLOSE '''83000000-0000-0000-0000-000000000003'''
\set S_B     '''84000000-0000-0000-0000-000000000004'''

-- ---------------------------------------------------------------------------
-- Apoio
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE escopo (conta uuid PRIMARY KEY, entidade uuid NOT NULL, filial uuid NOT NULL);
INSERT INTO escopo VALUES
  (:A, 'a1000000-0000-0000-0000-000000000030', 'a2000000-0000-0000-0000-000000000030'),
  (:B, 'b1000000-0000-0000-0000-000000000030', 'b2000000-0000-0000-0000-000000000030');
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

-- Saída de uma chamada, guardada para ser conferida no comando seguinte (uma consulta não
-- enxerga o que uma função gravou dentro do mesmo comando).
CREATE TEMP TABLE saida (k text PRIMARY KEY, v text);
-- Identificadores do cenário, por nome. Nome desconhecido é erro (não devolve nulo).
CREATE TEMP TABLE ids (k text PRIMARY KEY, id uuid NOT NULL, conta uuid NOT NULL, pai text);
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

-- Empregador com regime, estabelecimento (FAP 1,0000) e uma lotação com as alíquotas
-- hipotéticas do parecer: patronal 20%, RAT 2%, terceiros 5,8%.
CREATE TEMP SEQUENCE seq_n START 30000000001;
CREATE FUNCTION pg_temp.empregador(p_k text, p_account uuid, p_regime text DEFAULT 'lucro_presumido') RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  v_n bigint := nextval('seq_n');
  v_emp uuid; v_est uuid; v_lot uuid;
BEGIN
  INSERT INTO folha.employer (account_id, tipo_inscricao, inscricao, razao_social)
  VALUES (p_account, 'cnpj', left(v_n::text, 8) || right(v_n::text, 3), 'Empresa Ficticia ' || p_k)
  RETURNING employer_id INTO v_emp;
  IF p_regime = 'simples' THEN
    INSERT INTO folha.employer_regime (account_id, employer_id, vigencia_inicio, regime_tributario, simples_optante, simples_cpp)
    VALUES (p_account, v_emp, '2024-01-01', 'simples_nacional', true, 'no_das');
  ELSE
    INSERT INTO folha.employer_regime (account_id, employer_id, vigencia_inicio, regime_tributario)
    VALUES (p_account, v_emp, '2024-01-01', p_regime);
  END IF;
  INSERT INTO folha.establishment (account_id, employer_id, tipo_inscricao, inscricao, cnae_preponderante)
  VALUES (p_account, v_emp, 'cnpj', v_n::text || '000', '0000000') RETURNING establishment_id INTO v_est;
  INSERT INTO folha.establishment_fap (account_id, establishment_id, vigencia_inicio, fap, fap_origem)
  VALUES (p_account, v_est, '2024-01-01', 1.0000, 'hipotetico do parecer');
  INSERT INTO ids VALUES (p_k, v_emp, p_account, NULL), (p_k || '.est', v_est, p_account, p_k);
  PERFORM pg_temp.lotacao(p_k, 'lot');
END $$;
CREATE FUNCTION pg_temp.lotacao(p_emp_k text, p_sufixo text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_lot uuid;
BEGIN
  INSERT INTO folha.tax_allocation (account_id, employer_id, establishment_id, codigo_lotacao, tipo_lotacao)
  VALUES (pg_temp.conta_de(p_emp_k), pg_temp.id(p_emp_k), pg_temp.id(p_emp_k || '.est'), 'L-' || p_emp_k || '-' || p_sufixo, 'teste')
  RETURNING allocation_id INTO v_lot;
  INSERT INTO folha.tax_allocation_detail (account_id, allocation_id, vigencia_inicio, aliquota_rat, percentual_patronal, aliquota_terceiros)
  VALUES (pg_temp.conta_de(p_emp_k), v_lot, '2024-01-01', 0.02, 0.20, 0.058);
  INSERT INTO ids VALUES (p_emp_k || '.' || p_sufixo, v_lot, pg_temp.conta_de(p_emp_k), p_emp_k);
END $$;
-- Contrato com trabalhador novo. p_lotacoes: sufixo=percentual (padrão: a lotação 'lot', 100%).
CREATE FUNCTION pg_temp.contrato(p_k text, p_emp_k text, p_regime text DEFAULT 'clt', p_lotacoes text DEFAULT 'lot=100') RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  v_n bigint := nextval('seq_n');
  v_acc uuid := pg_temp.conta_de(p_emp_k);
  v_trab uuid; v_cid uuid;
  v_par text;
BEGIN
  INSERT INTO folha.employee (account_id, cpf, nome_completo, data_nascimento)
  VALUES (v_acc, v_n::text, 'Ficticio ' || p_k, '1990-01-01') RETURNING employee_id INTO v_trab;
  INSERT INTO folha.employment_contract (account_id, employee_id, data_admissao, cargo, salario_base,
                                         regime_trabalho, employer_id, establishment_id)
  VALUES (v_acc, v_trab, '2023-01-01', 'Cargo ' || p_k, 3000.00, p_regime, pg_temp.id(p_emp_k), pg_temp.id(p_emp_k || '.est'))
  RETURNING contract_id INTO v_cid;
  FOREACH v_par IN ARRAY string_to_array(p_lotacoes, ',') LOOP
    INSERT INTO folha.contract_tax_allocation (account_id, employer_id, contract_id, allocation_id, percentual, vigencia_inicio)
    VALUES (v_acc, pg_temp.id(p_emp_k), v_cid, pg_temp.id(p_emp_k || '.' || split_part(v_par, '=', 1)),
            split_part(v_par, '=', 2)::numeric, '2024-01-01');
  END LOOP;
  INSERT INTO ids VALUES (p_k, v_cid, v_acc, p_emp_k);
END $$;

-- Folha gravada direto (gatilhos desligados): os casos do parecer partem de uma folha já
-- fechada, com os valores de entrada do caso.
CREATE FUNCTION pg_temp.folha(p_k text, p_emp_k text, p_comp date, p_tipo text DEFAULT 'mensal',
                              p_seq integer DEFAULT 1, p_status text DEFAULT 'closed') RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  v_run uuid;
BEGIN
  PERFORM set_config('session_replication_role', 'replica', true);
  INSERT INTO folha.payroll_run (account_id, competencia, status, tipo_processo, sequencia, employer_id, data_pagamento, fechado_em)
  VALUES (pg_temp.conta_de(p_emp_k), p_comp, p_status, p_tipo, p_seq, pg_temp.id(p_emp_k),
          (p_comp + interval '1 month' - interval '1 day')::date, CASE WHEN p_status = 'closed' THEN now() END)
  RETURNING run_id INTO v_run;
  PERFORM set_config('session_replication_role', 'origin', true);
  INSERT INTO ids VALUES (p_k, v_run, pg_temp.conta_de(p_emp_k), p_emp_k);
END $$;
-- Folha sem empregador próprio (forma anterior à 0024, ainda aceita pela 0026): pode reunir
-- contratos de mais de um empregador.
CREATE FUNCTION pg_temp.folha_livre(p_k text, p_account uuid, p_comp date) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_run uuid;
BEGIN
  PERFORM set_config('session_replication_role', 'replica', true);
  INSERT INTO folha.payroll_run (account_id, competencia, status, tipo_processo, sequencia, data_pagamento, fechado_em)
  VALUES (p_account, p_comp, 'closed', 'mensal', 1, (p_comp + interval '1 month' - interval '1 day')::date, now())
  RETURNING run_id INTO v_run;
  PERFORM set_config('session_replication_role', 'origin', true);
  INSERT INTO ids VALUES (p_k, v_run, p_account, NULL);
END $$;
-- Resultado de um contrato na folha. p_itens e p_encargos: 'RUBRICA=centavos,...'; no encargo,
-- '@sufixo' escolhe a lotação (padrão 'lot'). p_liquido (reais) força um líquido gravado
-- diferente da soma dos itens (caso de inconsistência do GC-08). Refaz o resultado se já existe.
CREATE FUNCTION pg_temp.resultado(p_run_k text, p_contract_k text, p_itens text, p_encargos text DEFAULT '',
                                  p_liquido numeric DEFAULT NULL) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  v_acc uuid := pg_temp.conta_de(p_run_k);
  v_run uuid := pg_temp.id(p_run_k);
  v_cid uuid := pg_temp.id(p_contract_k);
  v_emp_k text := (SELECT pai FROM ids WHERE k = p_contract_k);
  v_res uuid;
  v_prov numeric; v_desc numeric;
BEGIN
  PERFORM set_config('session_replication_role', 'replica', true);
  SELECT pr.result_id INTO v_res FROM folha.payroll_result pr WHERE pr.run_id = v_run AND pr.contract_id = v_cid;
  IF FOUND THEN
    DELETE FROM folha.calculation_trace WHERE result_id = v_res;
    DELETE FROM folha.payroll_result_item WHERE result_id = v_res;
    DELETE FROM folha.payroll_result WHERE result_id = v_res;
  END IF;
  CREATE TEMP TABLE IF NOT EXISTS tmp_itens (n integer, codigo text, valor numeric, lot text) ON COMMIT DROP;
  TRUNCATE tmp_itens;
  INSERT INTO tmp_itens
  SELECT t.n::integer, split_part(t.par, '=', 1), split_part(split_part(t.par, '=', 2), '@', 1)::numeric / 100.0, NULL
    FROM regexp_split_to_table(p_itens, ',') WITH ORDINALITY AS t(par, n);
  INSERT INTO tmp_itens
  SELECT 1000 + t.n::integer, split_part(t.par, '=', 1), split_part(split_part(t.par, '=', 2), '@', 1)::numeric / 100.0,
         COALESCE(NULLIF(split_part(t.par, '@', 2), ''), 'lot')
    FROM regexp_split_to_table(p_encargos, ',') WITH ORDINALITY AS t(par, n)
   WHERE p_encargos <> '';
  IF EXISTS (SELECT 1 FROM tmp_itens i WHERE NOT EXISTS (SELECT 1 FROM folha.earning_deduction_code e
                                                          WHERE e.account_id IS NULL AND e.codigo = i.codigo)) THEN
    RAISE EXCEPTION 'resultado(%): rubrica desconhecida', p_run_k;
  END IF;
  SELECT COALESCE(sum(i.valor) FILTER (WHERE e.tipo_rubrica = 'provento'), 0),
         COALESCE(sum(i.valor) FILTER (WHERE e.tipo_rubrica = 'desconto'), 0)
    INTO v_prov, v_desc
    FROM tmp_itens i JOIN folha.earning_deduction_code e ON e.account_id IS NULL AND e.codigo = i.codigo
   WHERE i.n < 1000;
  INSERT INTO folha.payroll_result (run_id, account_id, employee_id, contract_id, total_proventos, total_descontos, liquido,
                                    inss_empregado, irrf, fgts, inss_patronal, rat, terceiros, calculation_hash)
  SELECT v_run, v_acc, k.employee_id, v_cid, v_prov, v_desc, COALESCE(p_liquido, v_prov - v_desc),
         COALESCE((SELECT sum(valor) FROM tmp_itens WHERE codigo IN ('INSS_EMPREGADO', 'INSS_13_SALARIO') AND n < 1000), 0),
         COALESCE((SELECT sum(valor) FROM tmp_itens WHERE codigo IN ('IRRF', 'IRRF_13_SALARIO', 'IRRF_FERIAS') AND n < 1000), 0),
         COALESCE((SELECT sum(valor) FROM tmp_itens WHERE codigo = 'FGTS_DEPOSITO' AND n < 1000), 0),
         COALESCE((SELECT sum(valor) FROM tmp_itens WHERE codigo = 'INSS_PATRONAL' AND n >= 1000), 0),
         COALESCE((SELECT sum(valor) FROM tmp_itens WHERE codigo = 'RAT_SAT' AND n >= 1000), 0),
         COALESCE((SELECT sum(valor) FROM tmp_itens WHERE codigo = 'TERCEIROS' AND n >= 1000), 0),
         'caso-de-teste'
    FROM folha.employment_contract k WHERE k.contract_id = v_cid
  RETURNING result_id INTO v_res;
  INSERT INTO folha.payroll_result_item (account_id, result_id, code_id, rubrica_codigo, tipo_rubrica, ordem, valor, camada_regra)
  SELECT v_acc, v_res, e.code_id, e.codigo, e.tipo_rubrica, i.n, i.valor, 'motor'
    FROM tmp_itens i JOIN folha.earning_deduction_code e ON e.account_id IS NULL AND e.codigo = i.codigo
   WHERE i.n < 1000;
  INSERT INTO folha.calculation_trace (result_id, account_id, step_order, rubrica_code, descricao, valor, tipo, detail_json, camada_regra)
  SELECT v_res, v_acc, i.n, i.codigo, 'Encargo do caso de teste', i.valor, 'encargo',
         jsonb_build_object('lotacao_id', pg_temp.id(v_emp_k || '.' || i.lot), 'estabelecimento_id', pg_temp.id(v_emp_k || '.est')),
         'motor'
    FROM tmp_itens i WHERE i.n >= 1000;
  PERFORM set_config('session_replication_role', 'origin', true);
END $$;

-- Linha de mapeamento (texto SQL da chamada _v1).
CREATE FUNCTION pg_temp.m(p_emp_k text, p_chave text, p_papel text, p_natureza text, p_conta text,
                          p_grupo text DEFAULT NULL, p_baixa text DEFAULT NULL, p_regime text DEFAULT NULL,
                          p_evento text DEFAULT NULL, p_cc text DEFAULT NULL, p_ativo boolean DEFAULT true) RETURNS text
LANGUAGE sql AS $$
  SELECT format('SELECT folha.contabil_mapa_definir_v1(%L, %L, %L, %L, %L, ''2024-01-01'', %L, NULL, %L, NULL, NULL, %L, %L, %L, %L)::text',
                pg_temp.id(p_emp_k), p_chave, p_papel, p_natureza, p_conta, p_ativo, p_regime, p_cc, p_baixa, p_grupo, p_evento) $$;
-- Plano de contas da empresa de teste, por bloco.
CREATE FUNCTION pg_temp.plano(p_emp_k text, p_blocos text[], p_exceto text[] DEFAULT ARRAY[]::text[]) RETURNS text[]
LANGUAGE sql AS $$
  SELECT ARRAY(
    SELECT pg_temp.m(p_emp_k, x.chave, x.papel, x.natureza, x.conta, x.grupo, x.baixa, x.regime, x.evento)
      FROM (VALUES
        ('folha', 'SALARIO_BASE',          'provento',          'despesa',  'DESP.SALARIOS',            NULL, NULL, NULL, NULL),
        ('folha', 'HE_50',                 'provento',          'despesa',  'DESP.HORAS_EXTRAS',        NULL, NULL, NULL, NULL),
        ('folha', 'INSS_EMPREGADO',        'desconto',          'passivo',  'PASS.INSS_RETIDO',         'recolhimento_previdenciario', NULL, NULL, NULL),
        ('folha', 'IRRF',                  'desconto',          'passivo',  'PASS.IRRF',                'recolhimento_irrf', NULL, NULL, NULL),
        ('folha', 'VALE_TRANSPORTE',       'desconto',          'redutora', 'RED.VT',                   NULL, NULL, NULL, NULL),
        ('folha', 'PENSAO_ALIMENTICIA',    'desconto',          'passivo',  'PASS.PENSAO',              'repasse_terceiros', NULL, NULL, NULL),
        ('folha', 'ADIANTAMENTO_SALARIAL', 'desconto',          'ativo',    'ATV.ADIANTAMENTOS',        NULL, NULL, NULL, NULL),
        ('folha', 'LIQUIDO',               'liquido',           'passivo',  'PASS.SALARIOS_A_PAGAR',    'pagamento_liquido', NULL, NULL, NULL),
        ('folha', 'INSS_PATRONAL',         'encargo_despesa',   'despesa',  'DESP.INSS_PATRONAL',       NULL, NULL, NULL, NULL),
        ('folha', 'INSS_PATRONAL',         'encargo_passivo',   'passivo',  'PASS.PREVIDENCIA',         'recolhimento_previdenciario', NULL, NULL, NULL),
        ('folha', 'RAT_SAT',               'encargo_despesa',   'despesa',  'DESP.RAT',                 NULL, NULL, NULL, NULL),
        ('folha', 'RAT_SAT',               'encargo_passivo',   'passivo',  'PASS.PREVIDENCIA',         'recolhimento_previdenciario', NULL, NULL, NULL),
        ('folha', 'TERCEIROS',             'encargo_despesa',   'despesa',  'DESP.TERCEIROS',           NULL, NULL, NULL, NULL),
        ('folha', 'TERCEIROS',             'encargo_passivo',   'passivo',  'PASS.TERCEIROS',           'recolhimento_previdenciario', NULL, NULL, NULL),
        ('folha', 'FGTS_DEPOSITO',         'encargo_despesa',   'despesa',  'DESP.FGTS',                NULL, NULL, NULL, NULL),
        ('folha', 'FGTS_DEPOSITO',         'encargo_passivo',   'passivo',  'PASS.FGTS',                'fgts_deposito', NULL, NULL, NULL),
        ('folha', 'BANCO',                 'banco',             'ativo',    'ATV.BANCO',                NULL, NULL, NULL, NULL),
        -- pró-labore: contas próprias, pelo regime de trabalho do contrato
        ('prolabore', 'SALARIO_BASE',      'provento',          'despesa',  'DESP.PRO_LABORE',          NULL, NULL, 'contribuinte_individual', NULL),
        ('prolabore', 'LIQUIDO',           'liquido',           'passivo',  'PASS.PRO_LABORE_A_PAGAR',  'pagamento_liquido', NULL, 'contribuinte_individual', NULL),
        ('prolabore', 'INSS_PATRONAL',     'encargo_despesa',   'despesa',  'DESP.PATRONAL_PRO_LABORE', NULL, NULL, 'contribuinte_individual', NULL),
        -- rescisão: o líquido vai para conta própria, pelo evento
        ('rescisao', 'RESC_SALDO_SALARIO',        'provento',   'despesa',  'DESP.SALARIOS',            NULL, NULL, NULL, NULL),
        ('rescisao', 'AVISO_PREVIO_INDENIZADO',   'provento',   'despesa',  'DESP.AVISO_INDENIZADO',    NULL, NULL, NULL, NULL),
        ('rescisao', 'RESC_DECIMO_TERCEIRO_PROP', 'provento',   'despesa',  'DESP.13',                  NULL, 'decimo_terceiro', NULL, NULL),
        ('rescisao', 'RESC_FERIAS_PROP',          'provento',   'despesa',  'DESP.FERIAS',              NULL, 'ferias', NULL, NULL),
        ('rescisao', 'FGTS_MULTA_RESCISORIA',     'encargo_despesa', 'despesa', 'DESP.MULTA_FGTS',      NULL, NULL, NULL, NULL),
        ('rescisao', 'FGTS_MULTA_RESCISORIA',     'encargo_passivo', 'passivo', 'PASS.FGTS',            'fgts_deposito', NULL, NULL, NULL),
        ('rescisao', 'LIQUIDO',                   'liquido',    'passivo',  'PASS.RESCISOES_A_PAGAR',   'pagamento_liquido', NULL, NULL, 'rescisao'),
        -- férias gozadas: utilizam a provisão
        ('ferias', 'FERIAS_GOZO',          'provento',          'despesa',  'DESP.FERIAS',              NULL, 'ferias', NULL, NULL),
        ('ferias', 'FERIAS_TERCO',         'provento',          'despesa',  'DESP.FERIAS',              NULL, 'ferias', NULL, NULL),
        -- provisões
        ('provisao', 'PROV_13',              'provisao_despesa',  'despesa',  'DESP.13',                   NULL, NULL, NULL, NULL),
        ('provisao', 'PROV_13',              'provisao_passivo',  'passivo',  'PASS.PROV_13',              NULL, NULL, NULL, NULL),
        ('provisao', 'PROV_13',              'provisao_reversao', 'redutora', 'RED.REVERSAO_PROVISAO',     NULL, NULL, NULL, NULL),
        ('provisao', 'PROV_13_ENCARGOS',     'provisao_despesa',  'despesa',  'DESP.ENCARGOS_13',          NULL, NULL, NULL, NULL),
        ('provisao', 'PROV_13_ENCARGOS',     'provisao_passivo',  'passivo',  'PASS.PROV_ENCARGOS_13',     NULL, NULL, NULL, NULL),
        ('provisao', 'PROV_13_ENCARGOS',     'provisao_reversao', 'redutora', 'RED.REVERSAO_PROVISAO',     NULL, NULL, NULL, NULL),
        ('provisao', 'PROV_13_FGTS',         'provisao_despesa',  'despesa',  'DESP.FGTS_13',              NULL, NULL, NULL, NULL),
        ('provisao', 'PROV_13_FGTS',         'provisao_passivo',  'passivo',  'PASS.PROV_FGTS_13',         NULL, NULL, NULL, NULL),
        ('provisao', 'PROV_13_FGTS',         'provisao_reversao', 'redutora', 'RED.REVERSAO_PROVISAO',     NULL, NULL, NULL, NULL),
        ('provisao', 'PROV_FERIAS',          'provisao_despesa',  'despesa',  'DESP.FERIAS',               NULL, NULL, NULL, NULL),
        ('provisao', 'PROV_FERIAS',          'provisao_passivo',  'passivo',  'PASS.PROV_FERIAS',          NULL, NULL, NULL, NULL),
        ('provisao', 'PROV_FERIAS',          'provisao_reversao', 'redutora', 'RED.REVERSAO_PROVISAO',     NULL, NULL, NULL, NULL),
        ('provisao', 'PROV_FERIAS_ENCARGOS', 'provisao_despesa',  'despesa',  'DESP.ENCARGOS_FERIAS',      NULL, NULL, NULL, NULL),
        ('provisao', 'PROV_FERIAS_ENCARGOS', 'provisao_passivo',  'passivo',  'PASS.PROV_ENCARGOS_FERIAS', NULL, NULL, NULL, NULL),
        ('provisao', 'PROV_FERIAS_ENCARGOS', 'provisao_reversao', 'redutora', 'RED.REVERSAO_PROVISAO',     NULL, NULL, NULL, NULL),
        ('provisao', 'PROV_FERIAS_FGTS',     'provisao_despesa',  'despesa',  'DESP.FGTS_FERIAS',          NULL, NULL, NULL, NULL),
        ('provisao', 'PROV_FERIAS_FGTS',     'provisao_passivo',  'passivo',  'PASS.PROV_FGTS_FERIAS',     NULL, NULL, NULL, NULL),
        ('provisao', 'PROV_FERIAS_FGTS',     'provisao_reversao', 'redutora', 'RED.REVERSAO_PROVISAO',     NULL, NULL, NULL, NULL)
      ) AS x(bloco, chave, papel, natureza, conta, grupo, baixa, regime, evento)
     WHERE x.bloco = ANY (p_blocos) AND NOT (x.chave = ANY (p_exceto))) $$;
-- Configura o empregador e grava o mapeamento, pela sessão de aplicação (folha.admin).
CREATE FUNCTION pg_temp.configura(p_emp_k text, p_dimensao text, p_provisao_encargos boolean, p_mapa text[],
                                  p_estorno text DEFAULT 'data_original') RETURNS text
LANGUAGE sql AS $$
  SELECT pg_temp.faz(pg_temp.conta_de(p_emp_k), ARRAY['folha.read', 'folha.admin'], '81000000-0000-0000-0000-000000000001',
    VARIADIC ARRAY[format('SELECT folha.contabil_config_definir_v1(%L, %L, %L, %L)', pg_temp.id(p_emp_k), p_dimensao, p_estorno, p_provisao_encargos)]
             || p_mapa || ARRAY['SELECT ''ok''']) $$;

-- Contabiliza a folha pela sessão de aplicação (folha.transmit); devolve o JSON como texto.
CREATE FUNCTION pg_temp.contabiliza(p_run_k text) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.faz(pg_temp.conta_de(p_run_k), ARRAY['folha.read', 'folha.transmit'], '82000000-0000-0000-0000-000000000002',
                     format('SELECT folha.contabil_folha_contabilizar_v1(%L)::text', pg_temp.id(p_run_k))) $$;
CREATE FUNCTION pg_temp.sit(p_saida text) RETURNS text LANGUAGE sql AS $$
  SELECT CASE WHEN p_saida LIKE 'ERRO%' THEN p_saida ELSE p_saida::jsonb->>'situacao' END $$;
CREATE FUNCTION pg_temp.provisiona(p_emp_k text, p_comp date) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.faz(pg_temp.conta_de(p_emp_k), ARRAY['folha.read', 'folha.transmit'], '82000000-0000-0000-0000-000000000002',
                     format('SELECT folha.contabil_provisao_constituir_v1(%L, %L)::text', pg_temp.id(p_emp_k), p_comp)) $$;
CREATE FUNCTION pg_temp.direito(p_contract_k text, p_comp date, p_rem numeric, p_avos_13 numeric, p_avos_ferias numeric) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.faz(pg_temp.conta_de(p_contract_k), ARRAY['folha.read', 'folha.calculate'], '82000000-0000-0000-0000-000000000002',
                     format('SELECT folha.contabil_provisao_direito_informar_v1(%L, %L, %L, %L, %L)::text',
                            pg_temp.id(p_contract_k), p_comp, p_rem, p_avos_13, p_avos_ferias)) $$;
CREATE FUNCTION pg_temp.paga(p_run_k text, p_evento text, p_data date, p_ref text, p_valor bigint, p_parcelas text DEFAULT NULL,
                             p_emp_k text DEFAULT NULL) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.sit(pg_temp.faz(pg_temp.conta_de(p_run_k), ARRAY['folha.read', 'folha.transmit'], '82000000-0000-0000-0000-000000000002',
                     format('SELECT folha.contabil_pagamento_registrar_v1(%L, %L, %L, %L, %L, %L, %L)::text',
                            pg_temp.id(p_run_k), p_evento, p_data, p_ref, p_valor, p_parcelas,
                            CASE WHEN p_emp_k IS NOT NULL THEN pg_temp.id(p_emp_k) END))) $$;

-- Lote vigente de uma folha e evento (ou a versão pedida), e o de provisão.
CREATE FUNCTION pg_temp.lote(p_run_k text, p_evento text, p_versao integer DEFAULT NULL) RETURNS bigint LANGUAGE sql AS $$
  SELECT o.outbox_id FROM folha.accounting_outbox o
   WHERE o.run_id = pg_temp.id(p_run_k) AND o.evento_tipo = p_evento
     AND CASE WHEN p_versao IS NULL THEN o.vigente ELSE o.versao = p_versao END $$;
CREATE FUNCTION pg_temp.lote_prov(p_emp_k text, p_comp date, p_evento text, p_versao integer DEFAULT NULL) RETURNS bigint LANGUAGE sql AS $$
  SELECT o.outbox_id FROM folha.accounting_outbox o
   WHERE o.employer_id = pg_temp.id(p_emp_k) AND o.competencia = p_comp AND o.run_id IS NULL AND o.evento_tipo = p_evento
     AND CASE WHEN p_versao IS NULL THEN o.vigente ELSE o.versao = p_versao END $$;
-- Linhas do evento: 'conta[@dimensão] D|C valor', em ordem de conta.
CREATE FUNCTION pg_temp.linhas(p_outbox bigint) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg((e->>'accountKey') || COALESCE('@' || (e->>'dimensionKey'), '') || ' '
                    || CASE WHEN (e->>'debitMinor')::bigint > 0 THEN 'D' || (e->>'debitMinor') ELSE 'C' || (e->>'creditMinor') END,
                    ' | ' ORDER BY (e->>'accountKey') COLLATE "C", (e->>'dimensionKey') COLLATE "C", (e->>'debitMinor')::bigint DESC)
    FROM folha.accounting_outbox o, jsonb_array_elements(o.payload->'entries') e
   WHERE o.outbox_id = p_outbox $$;
CREATE FUNCTION pg_temp.total(p_outbox bigint) RETURNS text LANGUAGE sql AS $$
  SELECT o.total_debito_minor::text || '/' || o.total_credito_minor::text FROM folha.accounting_outbox o WHERE o.outbox_id = p_outbox $$;
-- Saldo provisionado do contrato.
CREATE FUNCTION pg_temp.saldo(p_contract_k text, p_provisao text, p_componente text) RETURNS bigint LANGUAGE sql AS $$
  SELECT COALESCE(sum(m.valor_minor), 0)::bigint FROM folha.provision_ledger m
   WHERE m.contract_id = pg_temp.id(p_contract_k) AND m.provisao = p_provisao AND m.componente = p_componente $$;

-- ===========================================================================
-- 0. Estado de partida: nada semeado
-- ===========================================================================
SELECT is((SELECT count(*) FROM folha.contabil_mapa) + (SELECT count(*) FROM folha.contabil_config), 0::bigint,
  'nenhum mapeamento e nenhuma configuração semeados: a tabela nasce vazia (sem conta padrão)');
SELECT is((SELECT column_default FROM information_schema.columns
            WHERE table_schema = 'folha' AND table_name = 'contabil_mapa' AND column_name = 'ativo'),
  'false', 'linha de mapeamento nasce inativa por padrão da tabela');
SELECT is_empty(
  $$SELECT a.attrelid::regclass::text FROM pg_attribute a
     WHERE a.attrelid IN ('folha.contabil_papel'::regclass, 'folha.contabil_chave'::regclass, 'folha.provision_movement_type'::regclass)
       AND a.attname IN ('account_id', 'conta_codigo') AND NOT a.attisdropped$$,
  'os catálogos (papéis, chaves e tipos de movimento) são estrutura: não têm conta contábil nem conta de cliente');

-- ---------------------------------------------------------------------------
-- Cadastro do cenário
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  PERFORM pg_temp.empregador('e1', 'a0000000-0000-0000-0000-000000000030');   -- GC-01, 02, 04, 07, 08
  PERFORM pg_temp.empregador('e8', 'a0000000-0000-0000-0000-000000000030');   -- GC-08 sem mapeamento
  PERFORM pg_temp.empregador('e5', 'a0000000-0000-0000-0000-000000000030');   -- GC-05 pró-labore
  PERFORM pg_temp.empregador('e3', 'a0000000-0000-0000-0000-000000000030');   -- GC-03 provisão
  PERFORM pg_temp.empregador('e6', 'a0000000-0000-0000-0000-000000000030');   -- GC-06 rescisão
  PERFORM pg_temp.empregador('ed', 'a0000000-0000-0000-0000-000000000030');   -- dimensão centro de custo
  PERFORM pg_temp.empregador('el', 'a0000000-0000-0000-0000-000000000030');   -- dimensão lotação
  PERFORM pg_temp.lotacao('el', 'l40');
  PERFORM pg_temp.lotacao('el', 'l60');
  PERFORM pg_temp.empregador('em', 'a0000000-0000-0000-0000-000000000030', 'simples');   -- ponta a ponta com o motor
  PERFORM pg_temp.empregador('eb', 'b0000000-0000-0000-0000-000000000030');   -- outra conta
  PERFORM pg_temp.contrato('c01', 'e1');
  PERFORM pg_temp.contrato('c02', 'e1');
  PERFORM pg_temp.contrato('c03', 'e1');
  PERFORM pg_temp.contrato('c08', 'e8');
  PERFORM pg_temp.contrato('c05', 'e5', 'contribuinte_individual');
  PERFORM pg_temp.contrato('c05b', 'e5');
  PERFORM pg_temp.contrato('c3', 'e3');
  PERFORM pg_temp.contrato('c6', 'e6');
  PERFORM pg_temp.contrato('c6b', 'e6');
  PERFORM pg_temp.contrato('cd1', 'ed');
  PERFORM pg_temp.contrato('cd2', 'ed');
  PERFORM pg_temp.contrato('cd3', 'ed');
  PERFORM pg_temp.contrato('cl', 'el', 'clt', 'l40=40,l60=60');
  PERFORM pg_temp.contrato('cm', 'em');
  PERFORM pg_temp.contrato('cb', 'eb');
END $$;
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;

-- ===========================================================================
-- 1. Estrutura, RLS e ACL
-- ===========================================================================
CREATE TEMP TABLE tabelas (nome text PRIMARY KEY, por_conta boolean NOT NULL);
INSERT INTO tabelas VALUES ('contabil_config', true), ('contabil_mapa', true), ('contract_cost_assignment', true),
  ('contabil_pendencia', true), ('provision_entitlement', true), ('provision_ledger', true),
  ('contabil_papel', false), ('contabil_chave', false), ('provision_movement_type', false);
SELECT is(
  (SELECT count(*) FROM tabelas t JOIN pg_class k ON k.oid = ('folha.' || t.nome)::regclass
    WHERE k.relrowsecurity AND k.relforcerowsecurity),
  9::bigint, 'as nove tabelas novas existem, com RLS e FORCE');
SELECT is_empty(
  $$SELECT p.tablename || ':' || p.policyname || '/' || p.cmd
      FROM pg_policies p JOIN tabelas t ON t.nome = p.tablename
     WHERE p.schemaname = 'folha'
       AND (p.cmd <> 'SELECT'
            OR (SELECT string_agg(r::text, '+' ORDER BY r::text) FROM unnest(p.roles) AS r) <> 'dnex_gestao_data_owner+dnex_gestao_folha_worker'
            OR (t.por_conta AND p.qual <> '(account_id = ( SELECT folha.current_account_id() AS current_account_id))'))$$,
  'policies: só leitura, só para worker e data_owner; nas tabelas por conta, pela conta da sessão');
SELECT is((SELECT count(*) FROM pg_policies p JOIN tabelas t ON t.nome = p.tablename WHERE p.schemaname = 'folha'), 9::bigint,
  'uma policy por tabela (âncora)');
SELECT is_empty(
  $$SELECT t.nome || '<-' || CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END || ':' || a.privilege_type
      FROM tabelas t JOIN pg_class k ON k.oid = ('folha.' || t.nome)::regclass,
           LATERAL aclexplode(COALESCE(k.relacl, acldefault('r', k.relowner))) a
     WHERE a.grantee <> k.relowner
       AND NOT (a.privilege_type = 'SELECT' AND a.grantee::regrole::text IN ('dnex_gestao_folha_worker', 'dnex_gestao_data_owner'))$$,
  'ACL exata das tabelas novas: só SELECT para worker e data_owner (a gravação é pelas funções)');
SELECT is_empty(
  $$SELECT k.relname || '<-' || r.papel || ':' || p.priv
      FROM pg_class k
      CROSS JOIN (VALUES ('anon'), ('authenticated'), ('service_role'), ('dnex_gestao_api'), ('dnex_folha_ci_login')) AS r(papel)
      CROSS JOIN unnest(ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER']) AS p(priv)
     WHERE k.relnamespace = 'folha'::regnamespace
       AND (k.relname IN (SELECT nome FROM tabelas) OR k.relname IN ('accounting_outbox', 'v_reconciliacao_contabil'))
       AND has_table_privilege(r.papel, k.oid, p.priv)$$,
  'anon, authenticated, service_role e a sessão de aplicação não têm privilégio nas tabelas de contabilização, no outbox nem na visão');
SELECT ok(
  NOT has_table_privilege('dnex_gestao_folha_worker', 'folha.accounting_outbox', 'INSERT')
  AND has_table_privilege('dnex_gestao_folha_worker', 'folha.accounting_outbox', 'SELECT')
  AND has_table_privilege('dnex_gestao_folha_worker', 'folha.accounting_outbox', 'UPDATE')
  AND NOT has_table_privilege('dnex_gestao_folha_worker', 'folha.accounting_outbox', 'DELETE'),
  'outbox: o worker perdeu o INSERT direto; lê e marca o estado (UPDATE), sem DELETE');
-- Chaves estrangeiras para tabela que tem conta levam a conta (as que apontam catálogo, não).
SELECT is_empty(
  $$SELECT con.conrelid::regclass::text || '.' || con.conname FROM pg_constraint con
     WHERE con.contype = 'f'
       AND (con.conrelid IN (SELECT ('folha.' || nome)::regclass FROM tabelas WHERE por_conta)
            OR (con.conrelid = 'folha.accounting_outbox'::regclass AND con.conname IN (
                  'accounting_outbox_employer_fk', 'accounting_outbox_run_conta_fk', 'accounting_outbox_estorna_fk')))
       AND EXISTS (SELECT 1 FROM pg_attribute x WHERE x.attrelid = con.confrelid AND x.attname = 'account_id' AND NOT x.attisdropped)
       AND NOT EXISTS (SELECT 1 FROM unnest(con.conkey) AS col
                         JOIN pg_attribute att ON att.attrelid = con.conrelid AND att.attnum = col
                        WHERE att.attname = 'account_id')$$,
  'toda chave estrangeira das tabelas novas (e as novas do outbox) para tabela com conta inclui account_id');
SELECT is(
  (SELECT count(*) FROM pg_constraint con
    WHERE con.contype = 'f'
      AND (con.conrelid IN (SELECT ('folha.' || nome)::regclass FROM tabelas WHERE por_conta)
           OR (con.conrelid = 'folha.accounting_outbox'::regclass AND con.conname LIKE 'accounting\_outbox\_%\_fk'))
      AND EXISTS (SELECT 1 FROM pg_attribute x WHERE x.attrelid = con.confrelid AND x.attname = 'account_id' AND NOT x.attisdropped)),
  15::bigint, 'quinze chaves estrangeiras compostas com a conta (âncora): configuração 1, mapeamento 3, dimensão do contrato 1, pendência 3, direito 1, razão 3, outbox 3');

CREATE TEMP TABLE acl (sig text PRIMARY KEY, papeis text[] NOT NULL, definer boolean NOT NULL);
INSERT INTO acl VALUES
  ('folha.contabil_mapa_trava()',                                              ARRAY[]::text[], true),
  ('folha.accounting_outbox_guarda()',                                         ARRAY[]::text[], true),
  ('folha.accounting_outbox_imutavel()',                                       ARRAY[]::text[], false),
  ('folha.provision_ledger_trava()',                                           ARRAY[]::text[], true),
  ('folha.contabil_sem_truncate()',                                            ARRAY[]::text[], false),
  ('folha.contabil_payload_hash(jsonb)',                                       ARRAY[]::text[], false),
  ('folha.contabil_evento_da_folha(text)',                                     ARRAY[]::text[], false),
  ('folha.contabil_chave_provisao(text,text)',                                 ARRAY[]::text[], false),
  ('folha.contabil_provisao_saldo(uuid,uuid,text,text,date,bigint)',           ARRAY[]::text[], true),
  ('folha.contabil_linhas_resolver(uuid,uuid,date,text,text,uuid,jsonb)',      ARRAY[]::text[], true),
  ('folha.contabil_lote_compor(uuid,uuid,date,text,date,text,jsonb,jsonb,text[])', ARRAY[]::text[], false),
  ('folha.contabil_envelope(uuid,jsonb,integer,text,jsonb,jsonb)',             ARRAY[]::text[], false),
  ('folha.contabil_folha_conferir_estado(uuid,uuid)',                          ARRAY[]::text[], true),
  ('folha.contabil_folha_montar(uuid,uuid,uuid,text,bigint)',                  ARRAY[]::text[], true),
  ('folha.contabil_provisao_montar(uuid,uuid,date,text,bigint)',               ARRAY[]::text[], true),
  ('folha.contabil_razao_reverter(uuid,uuid,bigint,bigint)',                   ARRAY[]::text[], true),
  ('folha.contabil_lote_publicar(uuid,uuid,jsonb)',                            ARRAY[]::text[], true),
  ('folha.contabil_bloqueio_registrar(uuid,uuid,jsonb)',                       ARRAY[]::text[], true),
  ('folha.contabil_folha_executar(uuid,uuid,uuid)',                            ARRAY[]::text[], true),
  ('folha.contabil_passivo_saldos(uuid,uuid)',                                 ARRAY[]::text[], true),
  ('folha.contabil_config_definir_v1(uuid,text,text,boolean)',                 ARRAY['dnex_gestao_api'], true),
  ('folha.contabil_mapa_definir_v1(uuid,text,text,text,text,date,boolean,date,text,uuid,uuid,text,text,text,text)', ARRAY['dnex_gestao_api'], true),
  ('folha.contabil_mapa_encerrar_v1(uuid,date,boolean)',                       ARRAY['dnex_gestao_api'], true),
  ('folha.contabil_contrato_dimensao_definir_v1(uuid,text,text,date)',         ARRAY['dnex_gestao_api'], true),
  ('folha.contabil_folha_contabilizar_v1(uuid)',                               ARRAY['dnex_gestao_api'], true),
  ('folha.contabil_provisao_direito_informar_v1(uuid,date,numeric,numeric,numeric)', ARRAY['dnex_gestao_api'], true),
  ('folha.contabil_provisao_constituir_v1(uuid,date)',                         ARRAY['dnex_gestao_api'], true),
  ('folha.contabil_pagamento_registrar_v1(uuid,text,date,text,bigint,jsonb,uuid)', ARRAY['dnex_gestao_api'], true),
  ('folha.contabil_pendencia_liberar_v1(uuid,text)',                           ARRAY['dnex_gestao_api'], true),
  ('folha.contabil_situacao_v1(uuid)',                                         ARRAY['dnex_gestao_api'], true);
SELECT is_empty($$SELECT sig FROM acl WHERE to_regprocedure(sig) IS NULL$$, 'as 30 funções da 0030 existem com a assinatura esperada');
SELECT is_empty(
  $$SELECT p.oid::regprocedure::text FROM pg_proc p
     WHERE p.pronamespace = 'folha'::regnamespace
       AND (p.proname LIKE 'contabil\_%' OR p.proname LIKE 'accounting\_outbox\_%' OR p.proname LIKE 'provision\_ledger\_%')
       AND p.oid::regprocedure::text NOT IN (SELECT sig FROM acl)$$,
  'não há função de contabilização fora da lista conferida');
SELECT is_empty(
  $$SELECT acl.sig || ' <- ' || papel FROM acl, unnest(acl.papeis) AS papel
     WHERE NOT has_function_privilege(papel, to_regprocedure(acl.sig)::oid, 'execute')$$,
  'ACL: dnex_gestao_api executa as dez funções _v1');
SELECT is_empty(
  $$SELECT acl.sig || ' <- ' || CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END
      FROM acl JOIN pg_proc p ON p.oid = to_regprocedure(acl.sig)::oid,
           LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
     WHERE a.grantee <> p.proowner
       AND (a.grantee = 0 OR NOT (a.grantee::regrole::text = ANY (acl.papeis)))$$,
  'ACL: nenhum outro papel (nem PUBLIC, anon, service_role ou o worker) executa as funções da 0030');
SELECT is_empty(
  $$SELECT acl.sig FROM acl JOIN pg_proc p ON p.oid = to_regprocedure(acl.sig)::oid
     WHERE p.prosecdef IS DISTINCT FROM acl.definer
        OR NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) AS cfg WHERE cfg = 'search_path=pg_catalog, pg_temp')$$,
  'funções da 0030: search_path = pg_catalog, pg_temp em todas; SECURITY DEFINER nas que leem ou gravam dado');
SELECT is(
  (SELECT string_agg(p.oid::regprocedure::text, ',' ORDER BY p.oid::regprocedure::text)
     FROM pg_proc p WHERE p.pronamespace = 'folha'::regnamespace AND has_function_privilege('dnex_gestao_api', p.oid, 'execute')
      AND p.proname LIKE 'contabil\_%'),
  (SELECT string_agg(sig, ',' ORDER BY sig) FROM acl WHERE papeis <> ARRAY[]::text[]),
  'dnex_gestao_api executa, de contabilização, exatamente as dez funções _v1');
SELECT is(
  (SELECT string_agg(p.oid::regprocedure::text || '=' || p.prosecdef::text || '/' || array_to_string(p.proconfig, ';')
                     || '/' || (SELECT string_agg(a.grantee::regrole::text, '+' ORDER BY a.grantee::regrole::text)
                                  FROM aclexplode(p.proacl) a WHERE a.grantee <> p.proowner),
                     ' ' ORDER BY p.oid::regprocedure::text)
     FROM pg_proc p
    WHERE p.oid IN ('folha.build_contabil_folha(uuid)'::regprocedure, 'folha.dispatch_accounting_event(uuid,uuid,text,jsonb)'::regprocedure,
                    'folha.dispatch_folha_completa(uuid)'::regprocedure)),
  'folha.build_contabil_folha(uuid)=true/search_path=pg_catalog, pg_temp;row_security=off/dnex_gestao_data_owner+dnex_gestao_folha_worker '
  || 'folha.dispatch_accounting_event(uuid,uuid,text,jsonb)=true/search_path=pg_catalog, pg_temp;row_security=off/dnex_gestao_folha_worker '
  || 'folha.dispatch_folha_completa(uuid)=true/search_path=pg_catalog, pg_temp;row_security=off/dnex_gestao_folha_worker',
  'as três funções substituídas mantêm a ACL das migrations anteriores (CREATE OR REPLACE) e ficam com search_path terminado em pg_temp');
SELECT ok(
  EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = 'folha.payroll_result'::regclass AND i.indisunique
             AND pg_get_indexdef(i.indexrelid) LIKE '%(run_id, contract_id)%'),
  'regra V8: payroll_result é único por folha e contrato (índice da 0025, conferido)');
SELECT is(
  (SELECT string_agg(pp.chave || '=' || pp.valor::text || '/' || pp.status_validacao, ' ' ORDER BY pp.chave)
     FROM folha.payroll_parameter pp WHERE pp.chave LIKE 'contabil\_%'),
  'contabil_provisao_encargos_incide_terco_ferias=1/a_validar contabil_rescisao_baixa_provisao_encargos=0/a_validar',
  'os dois pontos que o parecer não fecha entram como parâmetro a_validar');
SELECT is(
  (SELECT string_agg(t.tipo || ':' || t.efeito, ' ' ORDER BY t.tipo) FROM folha.provision_movement_type t),
  'baixa_pagamento:reduz constituicao:aumenta estorno_rescisao:reduz reducao:reduz reversao_de_lote:inverte',
  'tipos de movimento do razão de provisões em tabela');

-- ===========================================================================
-- 2. Mapeamento: configuração pela sessão de aplicação e regras no dado
-- ===========================================================================
SELECT is(pg_temp.configura('e1', 'nenhuma', false, pg_temp.plano('e1', ARRAY['folha'])), 'ok',
  'preparo: configuração e plano de contas do empregador e1 (folha.admin)');
SELECT is(
  (SELECT count(*)::text || '/' || count(*) FILTER (WHERE m.ativo AND m.criado_por_subject = :S_ADMIN)::text
     FROM folha.contabil_mapa m WHERE m.employer_id = pg_temp.id('e1')),
  '17/17', 'as dezessete linhas do plano ficam gravadas, ativas por decisão de quem configurou, com o subject');
SELECT matches(
  pg_temp.le(:A, pg_temp.todas(), :S_ADMIN, pg_temp.m('e1', 'LIQUIDO', 'liquido', 'passivo', 'PASS.OUTRA')),
  '^ERRO 23P01: ', 'NEG: segunda linha ativa da mesma chave, papel e vigência é recusada (exclusão)');
SELECT matches(
  pg_temp.le(:A, pg_temp.todas(), :S_ADMIN, pg_temp.m('e1', 'LIQUIDO', 'liquido', 'passivo', 'PASS.MODELO', NULL, NULL, NULL, NULL, NULL, false)),
  '^[0-9a-f-]{36}$', 'linha INATIVA pode coexistir (modelo a ativar depois)');
SELECT matches(
  pg_temp.le(:A, pg_temp.todas(), :S_ADMIN, pg_temp.m('e1', 'LIQUIDO', 'liquido', 'despesa', 'DESP.ERRADA', NULL, NULL, NULL, 'ferias')),
  '^ERRO 23514: contabil_mapa: a natureza despesa não é aceita para o papel liquido',
  'NEG regra V9: natureza incompatível com o papel é recusada no cadastro');
SELECT matches(
  pg_temp.le(:A, pg_temp.todas(), :S_ADMIN, pg_temp.m('e1', 'RUBRICA_QUE_NAO_EXISTE', 'provento', 'despesa', 'DESP.X')),
  '^ERRO 23514: contabil_mapa: RUBRICA_QUE_NAO_EXISTE não é rubrica de provento', 'NEG: chave que não é rubrica nem chave do catálogo');
SELECT matches(
  pg_temp.le(:A, pg_temp.todas(), :S_ADMIN, pg_temp.m('e1', 'IRRF', 'provento', 'despesa', 'DESP.X')),
  '^ERRO 23514: contabil_mapa: IRRF não é rubrica de provento', 'NEG: rubrica de desconto não entra com papel de provento');
SELECT matches(
  pg_temp.le(:A, pg_temp.todas(), :S_ADMIN, pg_temp.m('e1', 'OUTROS_DESCONTOS', 'desconto', 'passivo', 'PASS.X', NULL, 'ferias')),
  '^ERRO 23514: .*contabil_mapa_baixa_so_em_provento', 'NEG: baixa de provisão só em provento');
SELECT matches(
  pg_temp.le(:A, pg_temp.todas(), :S_ADMIN, pg_temp.m('e1', 'HE_100', 'provento', 'despesa', 'DESP.X', 'pagamento_liquido')),
  '^ERRO 23514: .*contabil_mapa_liquidacao_so_em_passivo', 'NEG: grupo de liquidação só em passivo');
SELECT throws_ok(
  format('UPDATE folha.contabil_mapa SET conta_codigo = ''DESP.TROCADA'' WHERE employer_id = %L AND chave = ''SALARIO_BASE''', pg_temp.id('e1')),
  '23514', NULL, 'NEG: a conta de uma linha gravada não é trocada (encerra-se a linha e cria-se outra)');
SELECT matches(
  pg_temp.le(:A, array_remove(pg_temp.todas(), 'folha.admin'), :S_TX, pg_temp.m('e1', 'HE_100', 'provento', 'despesa', 'DESP.X')),
  '^ERRO 42501: ', 'NEG: mapear exige folha.admin');

-- ===========================================================================
-- 3. GC-01 — Folha simples, sem patronal
--    Entrada: salário 300000; INSS 25000; IRRF 0; líquido 275000; FGTS 24000.
-- ===========================================================================
SELECT pg_temp.folha('r01', 'e1', '2026-10-01');
SELECT pg_temp.resultado('r01', 'c01', 'SALARIO_BASE=300000,INSS_EMPREGADO=25000,IRRF=0,FGTS_DEPOSITO=24000');
SELECT is(pg_temp.sit(pg_temp.contabiliza('r01')), 'contabilizada', 'GC-01: a folha fechada é contabilizada (folha.transmit)');
SELECT is(pg_temp.linhas(pg_temp.lote('r01', 'folha_mensal')),
  'DESP.FGTS D24000 | DESP.SALARIOS D300000 | PASS.FGTS C24000 | PASS.INSS_RETIDO C25000 | PASS.SALARIOS_A_PAGAR C275000',
  'GC-01: as cinco linhas do parecer, em centavos');
SELECT is(pg_temp.total(pg_temp.lote('r01', 'folha_mensal')), '324000/324000', 'GC-01: total 324000 = 324000');
SELECT is(
  (SELECT o.status || '/' || o.versao || '/' || o.data_lancamento || '/' || o.contabilizado_por_subject || '/' || o.vigente
          || '/' || (o.result_id IS NULL) || '/' || (o.employer_id = pg_temp.id('e1'))
     FROM folha.accounting_outbox o WHERE o.outbox_id = pg_temp.lote('r01', 'folha_mensal')),
  'pendente/1/2026-10-31/82000000-0000-0000-0000-000000000002/true/true/true',
  'GC-01: lote da folha (não de um resultado), versão 1, pendente, datado do último dia da competência, com o subject de quem contabilizou');
SELECT is(
  (SELECT concat_ws('/', o.payload->>'contractVersion', o.payload->>'eventType', o.payload->>'competence', o.payload->>'entryDate',
                    o.payload->>'version', o.payload->'totals'->>'debitMinor', o.payload->'totals'->>'creditMinor',
                    ((o.payload->>'payrollRunId') = pg_temp.id('r01')::text)::text, ((o.payload->>'handoffKey') = o.idempotency_key)::text,
                    ((o.payload->>'payloadHash') = o.payload_hash)::text, jsonb_typeof(o.payload->'reverses'), jsonb_typeof(o.payload->'evidence'),
                    o.payload->'source'->>'repository')
     FROM folha.accounting_outbox o WHERE o.outbox_id = pg_temp.lote('r01', 'folha_mensal')),
  'gestao.folha-handoff.v2/folha_mensal/2026-10/2026-10-31/1/324000/324000/true/true/true/null/null/pompiliodonatoapp/dnex-folha',
  'GC-01: o evento sai no contrato v2 (um formato de linha, centavos como texto, referência à folha)');
SELECT is_empty(
  format($$SELECT e FROM folha.accounting_outbox o, jsonb_array_elements(o.payload->'entries') e
            WHERE o.outbox_id = %s
              AND (((e->>'debitMinor')::bigint > 0) = ((e->>'creditMinor')::bigint > 0)
                   OR (SELECT count(*) FROM jsonb_object_keys(e)) <> 6)$$, pg_temp.lote('r01', 'folha_mensal')),
  'regra V2: cada linha tem um único lado com valor, e o mesmo formato (seis campos)');
SELECT is(
  (SELECT (o.payload::text || o.composicao::text) !~* '(cpf|nome|employee)'
          AND NOT EXISTS (SELECT 1 FROM folha.employee e
                           WHERE position(e.cpf IN o.payload::text || o.composicao::text) > 0
                              OR position(e.nome_completo IN o.payload::text || o.composicao::text) > 0
                              OR position(e.employee_id::text IN o.payload::text || o.composicao::text) > 0)
          AND position(pg_temp.id('c01')::text IN o.payload::text || o.composicao::text) = 0
     FROM folha.accounting_outbox o WHERE o.outbox_id = pg_temp.lote('r01', 'folha_mensal')),
  true, 'o evento e a composição guardada não levam dado pessoal (nem CPF, nome, trabalhador ou contrato): só o consolidado por conta');
-- Duplicidade (regra V6): mesmo conteúdo não cria nada.
SELECT is(pg_temp.sit(pg_temp.contabiliza('r01')), 'inalterada', 'regra V6: contabilizar de novo a mesma folha devolve "inalterada"');
SELECT is((SELECT count(*) FROM folha.accounting_outbox o WHERE o.run_id = pg_temp.id('r01')), 1::bigint,
  'regra V6: continua um único lote na fila');

-- Prévia pelo construtor substituído e funções superadas.
SELECT is(
  pg_temp.com_espelho(:A, ARRAY['folha.read', 'folha.transmit'], :S_TX,
    format($$SELECT (b->>'situacao') || '/' || ((b->'evento'->>'payloadHash') = %L)::text || '/' || (b->'evento'->>'version')
               FROM folha.build_contabil_folha(%L) AS b$$,
           (SELECT o.payload_hash FROM folha.accounting_outbox o WHERE o.outbox_id = pg_temp.lote('r01', 'folha_mensal')),
           (SELECT pr.result_id FROM folha.payroll_result pr WHERE pr.run_id = pg_temp.id('r01')))),
  'previa/true/2', 'build_contabil_folha (substituído) devolve a prévia do lote v2, com o mesmo resumo do lote gravado, sem gravar');
SELECT matches(
  pg_temp.com_espelho(:A, ARRAY['folha.read', 'folha.transmit'], :S_TX,
    format('SELECT folha.dispatch_accounting_event(%L, %L, ''folha_mensal'', ''{}'')', pg_temp.id('r01'),
           (SELECT pr.result_id FROM folha.payroll_result pr WHERE pr.run_id = pg_temp.id('r01')))),
  '^ERRO 0A000: dispatch_accounting_event foi superada', 'dispatch_accounting_event (evento por resultado, sem conferir partida) está superada e recusa');

-- ===========================================================================
-- 4. GC-02 — Folha com descontos diversos e encargos patronais
--    Entrada: salário 500000; horas extras 50000. Descontos: INSS 60000; IRRF 35000; VT 30000;
--    pensão 80000; adiantamento 200000. Líquido 145000. Patronal 110000, RAT 11000,
--    terceiros 31900, FGTS 44000 (base 550000: 20%, 2%, 5,8% e 8%).
-- ===========================================================================
SELECT pg_temp.folha('r02', 'e1', '2026-10-01', 'mensal', 2);
SELECT pg_temp.resultado('r02', 'c02',
  'SALARIO_BASE=500000,HE_50=50000,INSS_EMPREGADO=60000,IRRF=35000,VALE_TRANSPORTE=30000,PENSAO_ALIMENTICIA=80000,ADIANTAMENTO_SALARIAL=200000,FGTS_DEPOSITO=44000',
  'INSS_PATRONAL=110000,RAT_SAT=11000,TERCEIROS=31900');
-- A fórmula antiga (0020:209-210, repetida na 0028), reproduzida aqui sobre a MESMA entrada:
-- débitos = proventos + FGTS; créditos = líquido + INSS + IRRF + FGTS.
SELECT is(
  (SELECT round((pr.total_proventos + pr.fgts) * 100)::text || '/' || round((pr.liquido + pr.inss_empregado + pr.irrf + pr.fgts) * 100)::text
          || '/' || round(((pr.total_proventos + pr.fgts) - (pr.liquido + pr.inss_empregado + pr.irrf + pr.fgts)) * 100)::text
     FROM folha.payroll_result pr WHERE pr.run_id = pg_temp.id('r02')),
  '594000/284000/310000',
  'GC-02 (âncora): pela fórmula do construtor antigo esta entrada dá débitos 594000, créditos 284000, diferença 310000');
SELECT is(pg_temp.sit(pg_temp.contabiliza('r02')), 'contabilizada', 'GC-02: contabilizada pelo construtor novo');
SELECT is(pg_temp.linhas(pg_temp.lote('r02', 'folha_mensal')),
  'ATV.ADIANTAMENTOS C200000 | DESP.FGTS D44000 | DESP.HORAS_EXTRAS D50000 | DESP.INSS_PATRONAL D110000 | DESP.RAT D11000'
  || ' | DESP.SALARIOS D500000 | DESP.TERCEIROS D31900 | PASS.FGTS C44000 | PASS.INSS_RETIDO C60000 | PASS.IRRF C35000'
  || ' | PASS.PENSAO C80000 | PASS.PREVIDENCIA C121000 | PASS.SALARIOS_A_PAGAR C145000 | PASS.TERCEIROS C31900 | RED.VT C30000',
  'GC-02: as quinze linhas do parecer (VT, pensão e adiantamento com crédito próprio; patronal e RAT na mesma conta: 121000)');
SELECT is(pg_temp.total(pg_temp.lote('r02', 'folha_mensal')), '746900/746900', 'GC-02: a partida fecha em 746900 (no código antigo faltavam 310000)');
SELECT is(
  (SELECT v.situacao || '/' || v.contabil_proventos_minor || '/' || v.contabil_descontos_minor || '/' || v.contabil_liquido_minor
          || '/' || v.contabil_encargos_previdenciarios_minor || '/' || v.contabil_fgts_minor
     FROM folha.v_reconciliacao_contabil v WHERE v.run_id = pg_temp.id('r02')),
  'aguardando_confirmacao/550000/405000/145000/152900/44000',
  'GC-02: a reconciliação compara por valor (proventos 550000, descontos 405000, líquido 145000, encargos 152900, FGTS 44000)');

-- (derivado) Salário-família (parecer 2.3, A10): pago pela empresa e compensado na contribuição
--   previdenciária; não é despesa. O mapeamento da rubrica aponta um ativo (valor a compensar).
--   Entrada: salário 150000; salário-família 6754; INSS 12000; líquido 144754.
--   Débitos 150000 + 6754 = 156754; créditos 12000 + 144754 = 156754.
SELECT matches(
  pg_temp.faz(:A, ARRAY['folha.read', 'folha.admin'], :S_ADMIN,
    pg_temp.m('e1', 'SALARIO_FAMILIA', 'provento', 'ativo', 'ATV.SALARIO_FAMILIA_A_COMPENSAR'),
    pg_temp.m('e1', 'ADIANTAMENTO_SALARIAL_PAGO', 'provento', 'ativo', 'ATV.ADIANTAMENTOS')),
  '^[0-9a-f-]{36}$', 'preparo: salário-família e adiantamento pago mapeados como ativo no e1');
SELECT pg_temp.folha('rsf', 'e1', '2026-10-01', 'mensal', 8);
SELECT pg_temp.resultado('rsf', 'c03', 'SALARIO_BASE=150000,SALARIO_FAMILIA=6754,INSS_EMPREGADO=12000');
SELECT is(pg_temp.sit(pg_temp.contabiliza('rsf')) || ' ' || pg_temp.linhas(pg_temp.lote('rsf', 'folha_mensal')),
  'contabilizada ATV.SALARIO_FAMILIA_A_COMPENSAR D6754 | DESP.SALARIOS D150000 | PASS.INSS_RETIDO C12000 | PASS.SALARIOS_A_PAGAR C144754',
  'derivado (A10): salário-família debita o valor a compensar (ativo), não a despesa, e entra no líquido a pagar');
-- (derivado) Folha de adiantamento (parecer 2.3): D adiantamentos a empregados (ativo) e o
--   lançamento leva a data em que o adiantamento é pago, não o último dia da competência.
SELECT pg_temp.folha('rad', 'e1', '2026-10-01', 'adiantamento');
SET LOCAL session_replication_role = replica;
UPDATE folha.payroll_run SET data_pagamento = '2026-10-20' WHERE run_id = pg_temp.id('rad');
SET LOCAL session_replication_role = origin;
SELECT pg_temp.resultado('rad', 'c03', 'ADIANTAMENTO_SALARIAL_PAGO=200000');
INSERT INTO saida VALUES ('rad', pg_temp.contabiliza('rad'));
SELECT is(
  (SELECT pg_temp.sit(v) FROM saida WHERE k = 'rad') || ' ' || pg_temp.linhas(pg_temp.lote('rad', 'adiantamento_salarial'))
  || ' ' || (SELECT o.data_lancamento::text FROM folha.accounting_outbox o WHERE o.outbox_id = pg_temp.lote('rad', 'adiantamento_salarial')),
  'contabilizada ATV.ADIANTAMENTOS D200000 | PASS.SALARIOS_A_PAGAR C200000 2026-10-20',
  'derivado: adiantamento pago vai ao ativo, no evento adiantamento_salarial, datado do pagamento');

-- ===========================================================================
-- 5. GC-08 — Bloqueios (nada pode ser gravado)
-- ===========================================================================
-- 5.1 GC-02 sem mapeamento para PENSAO_ALIMENTICIA (empregador e8: mesmo plano, sem a pensão;
--     uma linha INATIVA da pensão não conta).
SELECT is(pg_temp.configura('e8', 'nenhuma', false,
            pg_temp.plano('e8', ARRAY['folha'], ARRAY['PENSAO_ALIMENTICIA'])
            || pg_temp.m('e8', 'PENSAO_ALIMENTICIA', 'desconto', 'passivo', 'PASS.PENSAO', 'repasse_terceiros', NULL, NULL, NULL, NULL, false)),
  'ok', 'preparo: empregador e8 com o plano sem a pensão ativa (só um modelo inativo)');
SELECT pg_temp.folha('r08a', 'e8', '2026-10-01');
SELECT pg_temp.resultado('r08a', 'c08',
  'SALARIO_BASE=500000,HE_50=50000,INSS_EMPREGADO=60000,IRRF=35000,VALE_TRANSPORTE=30000,PENSAO_ALIMENTICIA=80000,ADIANTAMENTO_SALARIAL=200000,FGTS_DEPOSITO=44000',
  'INSS_PATRONAL=110000,RAT_SAT=11000,TERCEIROS=31900');
INSERT INTO saida VALUES ('r08a', pg_temp.contabiliza('r08a'));
SELECT is(
  (SELECT (v::jsonb->>'situacao') || '/' || (v::jsonb->'pendencias'->0->>'codigo') || '/' || (v::jsonb->'pendencias'->0->'itens')::text
     FROM saida WHERE k = 'r08a'),
  'bloqueada/mapeamento_ausente/[{"chave": "PENSAO_ALIMENTICIA", "papel": "desconto", "regime_trabalho": "clt"}]',
  'GC-08: sem mapeamento vigente para PENSAO_ALIMENTICIA a contabilização é bloqueada e diz qual rubrica falta (regra V3)');
SELECT is((SELECT count(*) FROM folha.accounting_outbox o WHERE o.run_id = pg_temp.id('r08a')), 0::bigint,
  'GC-08: zero linhas no outbox (o lote inteiro fica de fora; não há conta padrão)');
SELECT is(
  (SELECT p.tipo || '/' || p.codigo || '/' || p.evento_tipo || '/' || (p.detalhe->0->>'chave') || '/' || (p.resolvida_em IS NULL)
          || '/' || p.criada_por_subject
     FROM folha.contabil_pendencia p WHERE p.run_id = pg_temp.id('r08a')),
  'bloqueio/mapeamento_ausente/folha_mensal/PENSAO_ALIMENTICIA/true/82000000-0000-0000-0000-000000000002',
  'GC-08: fica uma pendência de bloqueio, aberta, com a rubrica que falta e quem tentou');
SELECT matches(
  pg_temp.le(:A, pg_temp.todas(), :S_CLOSE,
    format('SELECT folha.contabil_pendencia_liberar_v1(%L, ''liberar mesmo assim'')',
           (SELECT p.pendencia_id FROM folha.contabil_pendencia p WHERE p.run_id = pg_temp.id('r08a')))),
  '^ERRO P0001: Pendência de bloqueio \(mapeamento_ausente\) não é liberável',
  'GC-08: a pendência de falta de mapeamento NÃO é liberável');
SELECT is(pg_temp.sit(pg_temp.contabiliza('r08a')), 'bloqueada', 'tentar de novo continua bloqueado');
SELECT is((SELECT count(*) FROM folha.contabil_pendencia p WHERE p.run_id = pg_temp.id('r08a')), 1::bigint,
  'a mesma pendência aberta é reaproveitada (não duplica)');
SELECT is(
  pg_temp.com_espelho(:A, ARRAY['folha.read', 'folha.transmit'], :S_TX,
    format($$SELECT (b->>'situacao') || '/' || (b->'pendencia'->>'codigo') FROM folha.build_contabil_folha(%L) AS b$$,
           (SELECT pr.result_id FROM folha.payroll_result pr WHERE pr.run_id = pg_temp.id('r08a')))),
  'bloqueado/mapeamento_ausente', 'a prévia do construtor devolve o diagnóstico do bloqueio, não um evento');
-- Completado o cadastro, a mesma folha sai e a pendência se resolve.
SELECT matches(
  pg_temp.faz(:A, ARRAY['folha.read', 'folha.admin'], :S_ADMIN,
    pg_temp.m('e8', 'PENSAO_ALIMENTICIA', 'desconto', 'passivo', 'PASS.PENSAO', 'repasse_terceiros')),
  '^[0-9a-f-]{36}$', 'preparo: a pensão passa a ter linha ativa no e8');
INSERT INTO saida VALUES ('r08a-2', pg_temp.contabiliza('r08a'));
SELECT is((SELECT pg_temp.sit(v) FROM saida WHERE k = 'r08a-2') || '/' || pg_temp.total(pg_temp.lote('r08a', 'folha_mensal'))
          || '/' || (SELECT (p.resolvida_em IS NOT NULL)::text FROM folha.contabil_pendencia p WHERE p.run_id = pg_temp.id('r08a')),
  'contabilizada/746900/746900/true', 'com o mapeamento completo a folha é contabilizada (746900) e a pendência fica resolvida');

-- 5.2 Líquido gravado diferente da soma dos itens (proventos 300000, descontos 25000, líquido gravado 270000).
SELECT pg_temp.folha('r08b', 'e1', '2026-10-01', 'mensal', 3);
SELECT pg_temp.resultado('r08b', 'c03', 'SALARIO_BASE=300000,INSS_EMPREGADO=25000', '', 2700.00);
SELECT matches(pg_temp.contabiliza('r08b'), '^ERRO P0001: Resultado .* com líquido inconsistente',
  'GC-08: líquido gravado (270000) diferente de proventos menos descontos (275000): erro de inconsistência (regra V4)');
-- 5.3 Folha em rascunho.
SELECT pg_temp.folha('r08c', 'e1', '2026-10-01', 'mensal', 4, 'draft');
SELECT pg_temp.resultado('r08c', 'c03', 'SALARIO_BASE=300000,INSS_EMPREGADO=25000');
SELECT matches(pg_temp.contabiliza('r08c'), '^ERRO P0001: Folha .* está em draft e não pode ser contabilizada: só folha fechada$',
  'GC-08: folha em draft não é contabilizada (regra V5)');
-- (derivado) A 0030 é mais estreita que a regra V5 do parecer: folha aprovada e ainda não fechada também não sai.
SELECT pg_temp.folha('r08f', 'e1', '2026-10-01', 'mensal', 7, 'approved');
SELECT pg_temp.resultado('r08f', 'c03', 'SALARIO_BASE=300000,INSS_EMPREGADO=25000');
SELECT matches(pg_temp.contabiliza('r08f'), '^ERRO P0001: Folha .* está em approved e não pode ser contabilizada',
  'derivado: folha aprovada e não fechada também não é contabilizada (só FECHADA)');
-- 5.4 Descontos maiores que os proventos.
SELECT pg_temp.folha('r08d', 'e1', '2026-10-01', 'mensal', 5);
SELECT pg_temp.resultado('r08d', 'c03', 'SALARIO_BASE=100000,INSS_EMPREGADO=25000,ADIANTAMENTO_SALARIAL=200000');
SELECT matches(pg_temp.contabiliza('r08d'), '^ERRO P0001: Resultado .* com líquido negativo',
  'GC-08: líquido negativo bloqueia e exige decisão de pessoa (regra V10)');
-- 5.5 Folha fechada com pendência aberta (injetada com os gatilhos desligados).
SELECT pg_temp.folha('r08e', 'e1', '2026-10-01', 'mensal', 6);
SELECT pg_temp.resultado('r08e', 'c03', 'SALARIO_BASE=300000,INSS_EMPREGADO=25000');
SET LOCAL session_replication_role = replica;
INSERT INTO folha.payroll_pendency (account_id, run_id, result_id, contract_id, codigo, tipo)
SELECT pr.account_id, pr.run_id, pr.result_id, pr.contract_id, 'a_validar:injetada_pelo_teste', 'a_validar'
  FROM folha.payroll_result pr WHERE pr.run_id = pg_temp.id('r08e');
SET LOCAL session_replication_role = origin;
SELECT matches(pg_temp.contabiliza('r08e'), '^ERRO P0001: Folha .* tem 1 pendência\(s\) sem liberação e não pode ser contabilizada$',
  'NEG: folha com pendência aberta não é contabilizada');
SELECT is(
  (SELECT count(*) FROM folha.accounting_outbox o
    WHERE o.run_id IN (pg_temp.id('r08b'), pg_temp.id('r08c'), pg_temp.id('r08d'), pg_temp.id('r08e'), pg_temp.id('r08f'))),
  0::bigint, 'GC-08: nenhum dos bloqueios acima gravou linha no outbox');
-- 5.6 Inserção direta de lote com débito 100 e crédito 99: recusada pela restrição da TABELA
--     (gatilhos desligados, para a recusa não vir do gatilho).
SET LOCAL session_replication_role = replica;
SELECT throws_ok(
  format($$INSERT INTO folha.accounting_outbox (account_id, run_id, evento_tipo, payload, idempotency_key, formato, employer_id,
             competencia, versao, data_lancamento, payload_hash, total_debito_minor, total_credito_minor, composicao, contabilizado_por_subject)
           VALUES ('a0000000-0000-0000-0000-000000000030', %L, 'folha_mensal', '{}', 'direto-1', 'v2', %L, '2026-10-01', 1, '2026-10-31',
                   repeat('a', 64), 100, 99, '[]', gen_random_uuid())$$, pg_temp.id('r08b'), pg_temp.id('e1')),
  '23514', 'new row for relation "accounting_outbox" violates check constraint "accounting_outbox_lote_balanceado"',
  'GC-08: lote com débito 100 e crédito 99 é rejeitado pela restrição da tabela (regra V1)');
SET LOCAL session_replication_role = origin;
-- Apoio para os negativos do gatilho do outbox: grava como o DONO das tabelas, de dentro de uma
-- sessão de aplicação com contexto aberto (é o que uma função SECURITY DEFINER do dono faz).
CREATE FUNCTION pg_temp.grava(p_sql text) RETURNS text LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  EXECUTE p_sql;
  RETURN 'gravou';
END $$;
GRANT EXECUTE ON FUNCTION pg_temp.grava(text) TO dnex_folha_ci_login;
CREATE FUNCTION pg_temp.insere_sob_contexto(p_sql text) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.le('a0000000-0000-0000-0000-000000000030', ARRAY['folha.read', 'folha.transmit'],
                    '82000000-0000-0000-0000-000000000002', format('SELECT pg_temp.grava(%L)', p_sql)) $$;

-- ===========================================================================
-- 6. GC-04 — Liquidação da folha do GC-02 (um lote por comprovante)
-- ===========================================================================
SELECT matches(pg_temp.paga('r02', 'pagamento_liquido', '2026-11-05', 'COMP-LIQ-1', 145001),
  '^ERRO P0001: Pagamento de 145001 centavos excede o saldo do passivo do grupo pagamento_liquido na folha \(145000 centavos\)$',
  'GC-04: pagamento acima do saldo do passivo é bloqueado (regra V12)');
SELECT matches(pg_temp.paga('r02', 'pagamento_liquido', '2026-11-05', '  ', 145000),
  '^ERRO 22023: .*exige a referência do comprovante e a data', 'regra V12: evento de pagamento exige a referência do comprovante');
SELECT matches(pg_temp.paga('r02', 'pagamento_liquido', NULL, 'COMP-LIQ-1', 145000),
  '^ERRO 22023: .*exige a referência do comprovante e a data', 'regra V12: evento de pagamento exige a data');
SELECT matches(pg_temp.paga('r02', 'recolhimento_previdenciario', '2026-11-20', 'GUIA-PREV-1', 100000),
  '^ERRO P0001: Pagamento parcial de grupo com mais de uma conta de passivo: informe as parcelas por conta$',
  'derivado: pagamento parcial de guia que cobre três contas exige as parcelas por conta');
SELECT is(pg_temp.paga('r02', 'pagamento_liquido', '2026-11-05', 'COMP-LIQ-1', 145000), 'contabilizado', 'GC-04: pagamento do líquido, 145000');
SELECT is(pg_temp.paga('r02', 'repasse_terceiros', '2026-11-06', 'COMP-PENSAO-1', 80000), 'contabilizado', 'GC-04: repasse da pensão, 80000');
SELECT is(pg_temp.paga('r02', 'recolhimento_previdenciario', '2026-11-20', 'GUIA-PREV-1', 212900), 'contabilizado', 'GC-04: guia previdenciária, 212900');
SELECT is(pg_temp.paga('r02', 'recolhimento_irrf', '2026-11-20', 'DARF-IRRF-1', 35000), 'contabilizado', 'GC-04: IRRF, 35000');
SELECT is(pg_temp.paga('r02', 'fgts_deposito', '2026-11-07', 'GUIA-FGTS-1', 44000), 'contabilizado', 'GC-04: FGTS, 44000');
SELECT is(
  (SELECT string_agg(o.evento_tipo || '=' || pg_temp.linhas(o.outbox_id), ' ; ' ORDER BY o.evento_tipo)
     FROM folha.accounting_outbox o WHERE o.run_id = pg_temp.id('r02') AND o.comprovante_ref IS NOT NULL),
  'fgts_deposito=ATV.BANCO C44000 | PASS.FGTS D44000'
  || ' ; pagamento_liquido=ATV.BANCO C145000 | PASS.SALARIOS_A_PAGAR D145000'
  || ' ; recolhimento_irrf=ATV.BANCO C35000 | PASS.IRRF D35000'
  || ' ; recolhimento_previdenciario=ATV.BANCO C212900 | PASS.INSS_RETIDO D60000 | PASS.PREVIDENCIA D121000 | PASS.TERCEIROS D31900'
  || ' ; repasse_terceiros=ATV.BANCO C80000 | PASS.PENSAO D80000',
  'GC-04: os cinco lotes do parecer, cada um debitando o passivo e creditando o banco (a guia: 60000 + 121000 + 31900)');
SELECT is(
  (SELECT sum(o.total_debito_minor)::text FROM folha.accounting_outbox o WHERE o.run_id = pg_temp.id('r02') AND o.comprovante_ref IS NOT NULL),
  '516900', 'GC-04: total liquidado 516900');
SELECT is(
  (SELECT string_agg(o.evento_tipo || ':' || o.data_lancamento || ':' || (o.payload->'evidence'->>'reference') || ':' || (o.payload->'evidence'->>'date'),
                     ' ' ORDER BY o.evento_tipo)
     FROM folha.accounting_outbox o WHERE o.run_id = pg_temp.id('r02') AND o.evento_tipo IN ('pagamento_liquido', 'fgts_deposito')),
  'fgts_deposito:2026-11-07:GUIA-FGTS-1:2026-11-07 pagamento_liquido:2026-11-05:COMP-LIQ-1:2026-11-05',
  'regra V13: o evento de pagamento é datado pelo comprovante (não pela competência) e leva a referência dele');
SELECT is(
  (SELECT string_agg((p->>'conta') || '=' || (p->>'saldo_minor'), ' ' ORDER BY (p->>'conta') COLLATE "C")
     FROM jsonb_array_elements(pg_temp.le(:A, ARRAY['folha.read'], :S_TX,
            format('SELECT folha.contabil_situacao_v1(%L)->''passivos''', pg_temp.id('r02')))::jsonb) p),
  'PASS.FGTS=0 PASS.INSS_RETIDO=0 PASS.IRRF=0 PASS.PENSAO=0 PASS.PREVIDENCIA=0 PASS.SALARIOS_A_PAGAR=0 PASS.TERCEIROS=0',
  'GC-04: depois da liquidação todos os passivos do GC-02 estão zerados (contabil_situacao_v1, folha.read)');
SELECT is(pg_temp.paga('r02', 'pagamento_liquido', '2026-11-05', 'COMP-LIQ-1', 145000), 'inalterado',
  'GC-04: segundo envio do mesmo comprovante não cria lote (regra V6)');
SELECT is((SELECT count(*) FROM folha.accounting_outbox o WHERE o.run_id = pg_temp.id('r02')), 6::bigint,
  'GC-04: seguem seis lotes na folha (a apropriação e os cinco pagamentos)');
SELECT matches(pg_temp.paga('r02', 'pagamento_liquido', '2026-11-05', 'COMP-LIQ-1', 100),
  '^ERRO P0001: O comprovante COMP-LIQ-1 já foi registrado', 'derivado: o mesmo comprovante com outro valor é erro, não segundo lote');
SELECT matches(pg_temp.paga('r02', 'pagamento_liquido', '2026-11-08', 'COMP-LIQ-2', 1),
  '^ERRO P0001: Pagamento de 1 centavos excede o saldo', 'derivado: passivo já zerado não aceita novo pagamento');
SELECT is(
  (SELECT v.situacao || '/' || v.soma_proventos || '/' || v.contabil_proventos_minor FROM folha.v_reconciliacao_contabil v WHERE v.run_id = pg_temp.id('r02')),
  'aguardando_confirmacao/5500.00/550000',
  'E13: com seis lotes na folha a soma da reconciliação continua 5500,00 (a visão antiga multiplicava pelo número de eventos)');
-- Derivado: recálculo de folha que já tem pagamento contabilizado é bloqueado (o saldo do passivo
-- ficaria negativo); nada é gravado e fica pendência de bloqueio.
SELECT pg_temp.resultado('r02', 'c02',
  'SALARIO_BASE=500100,HE_50=50000,INSS_EMPREGADO=60000,IRRF=35000,VALE_TRANSPORTE=30000,PENSAO_ALIMENTICIA=80000,ADIANTAMENTO_SALARIAL=200000,FGTS_DEPOSITO=44000',
  'INSS_PATRONAL=110000,RAT_SAT=11000,TERCEIROS=31900');
INSERT INTO saida VALUES ('r02pag', pg_temp.contabiliza('r02'));
SELECT is((SELECT (v::jsonb->>'situacao') || '/' || (v::jsonb->'pendencias'->0->>'codigo') FROM saida WHERE k = 'r02pag'),
  'bloqueada/pagamento_registrado', 'derivado: recálculo com pagamento já contabilizado é bloqueado (pagamento_registrado)');
SELECT is((SELECT count(*) FROM folha.accounting_outbox o WHERE o.run_id = pg_temp.id('r02')), 6::bigint,
  'derivado: o bloqueio por pagamento não gravou lote nenhum (seguem seis)');
SELECT throws_ok($$TRUNCATE folha.accounting_outbox CASCADE$$, '23514', NULL, 'derivado: o outbox contábil não aceita TRUNCATE');

-- ===========================================================================
-- 7. GC-05 — Pró-labore
--    Entrada: pró-labore 500000; INSS 55000; IRRF 30000; líquido 415000; patronal 100000.
-- ===========================================================================
SELECT is(pg_temp.configura('e5', 'nenhuma', false, pg_temp.plano('e5', ARRAY['folha', 'prolabore'])), 'ok',
  'preparo: empregador e5 com o plano da folha e as contas próprias do pró-labore (por regime de trabalho)');
SELECT pg_temp.folha('r05', 'e5', '2026-10-01');
SELECT pg_temp.resultado('r05', 'c05', 'SALARIO_BASE=500000,INSS_EMPREGADO=55000,IRRF=30000', 'INSS_PATRONAL=100000');
SELECT is(pg_temp.sit(pg_temp.contabiliza('r05')), 'contabilizada', 'GC-05: folha de pró-labore contabilizada');
SELECT is(pg_temp.linhas(pg_temp.lote('r05', 'pro_labore')),
  'DESP.PATRONAL_PRO_LABORE D100000 | DESP.PRO_LABORE D500000 | PASS.INSS_RETIDO C55000 | PASS.IRRF C30000'
  || ' | PASS.PREVIDENCIA C100000 | PASS.PRO_LABORE_A_PAGAR C415000',
  'GC-05: as seis linhas do parecer, no evento pro_labore');
SELECT is(pg_temp.total(pg_temp.lote('r05', 'pro_labore')), '600000/600000', 'GC-05: total 600000');
SELECT is_empty(
  format($$SELECT e->>'accountKey' FROM folha.accounting_outbox o, jsonb_array_elements(o.payload->'entries') e
            WHERE o.outbox_id = %s AND e->>'accountKey' IN ('DESP.FGTS', 'PASS.FGTS', 'DESP.RAT', 'DESP.TERCEIROS', 'PASS.TERCEIROS', 'DESP.SALARIOS')$$,
         pg_temp.lote('r05', 'pro_labore')),
  'GC-05: nenhuma linha de FGTS, RAT ou terceiros, e a despesa não é a conta de salários');
-- (derivado) Folha com um sócio e um empregado: dois lotes, um por evento.
--   c05 repete o GC-05 (600000); c05b: salário 100000, INSS 8000, líquido 92000 -> 100000.
SELECT pg_temp.folha('rmix', 'e5', '2026-10-01', 'mensal', 2);
SELECT pg_temp.resultado('rmix', 'c05', 'SALARIO_BASE=500000,INSS_EMPREGADO=55000,IRRF=30000', 'INSS_PATRONAL=100000');
SELECT pg_temp.resultado('rmix', 'c05b', 'SALARIO_BASE=100000,INSS_EMPREGADO=8000');
INSERT INTO saida VALUES ('rmix', pg_temp.contabiliza('rmix'));
SELECT is(
  (SELECT pg_temp.sit(v) FROM saida WHERE k = 'rmix') || ' ' ||
  (SELECT string_agg(o.evento_tipo || ':' || o.total_debito_minor, ',' ORDER BY o.evento_tipo)
     FROM folha.accounting_outbox o WHERE o.run_id = pg_temp.id('rmix')),
  'contabilizada folha_mensal:100000,pro_labore:600000',
  'derivado: folha com sócio e empregado gera um lote de pró-labore e um da folha mensal, cada um fechado');

-- (derivado) Folha sem empregador próprio com contratos de dois empregadores: um lote por
--   empregador, cada um com o mapeamento do seu. c01 (e1) repete o GC-01 (324000); c05b (e5):
--   salário 100000, INSS 8000, líquido 92000 (100000).
SELECT pg_temp.folha_livre('rmulti', :A, '2026-07-01');
SELECT pg_temp.resultado('rmulti', 'c01', 'SALARIO_BASE=300000,INSS_EMPREGADO=25000,FGTS_DEPOSITO=24000');
SELECT pg_temp.resultado('rmulti', 'c05b', 'SALARIO_BASE=100000,INSS_EMPREGADO=8000');
INSERT INTO saida VALUES ('rmulti', pg_temp.contabiliza('rmulti'));
SELECT is(
  (SELECT pg_temp.sit(v) FROM saida WHERE k = 'rmulti') || ' ' ||
  (SELECT string_agg((SELECT i.k FROM ids i WHERE i.id = o.employer_id) || ':' || o.evento_tipo || ':' || o.total_debito_minor || '/' || o.total_credito_minor,
                     ' ' ORDER BY o.total_debito_minor DESC)
     FROM folha.accounting_outbox o WHERE o.run_id = pg_temp.id('rmulti')),
  'contabilizada e1:folha_mensal:324000/324000 e5:folha_mensal:100000/100000',
  'derivado: folha com contratos de dois empregadores gera um lote fechado por empregador');
SELECT matches(pg_temp.paga('rmulti', 'pagamento_liquido', '2026-08-05', 'COMP-MULTI-1', 92000),
  '^ERRO P0001: Folha .* tem lotes de mais de um empregador: informe o empregador do pagamento$',
  'derivado: em folha com lotes de dois empregadores o pagamento exige o empregador');
INSERT INTO saida VALUES ('rmulti-pg', pg_temp.paga('rmulti', 'pagamento_liquido', '2026-08-05', 'COMP-MULTI-1', 92000, NULL, 'e5'));
SELECT is((SELECT v FROM saida WHERE k = 'rmulti-pg')
          || '/' || pg_temp.linhas((SELECT o.outbox_id FROM folha.accounting_outbox o WHERE o.comprovante_ref = 'COMP-MULTI-1')),
  'contabilizado/ATV.BANCO C92000 | PASS.SALARIOS_A_PAGAR D92000',
  'derivado: o pagamento informado para o e5 liquida só o passivo dele (92000), não o do e1');
SELECT matches(pg_temp.paga('rmulti', 'pagamento_liquido', '2026-08-05', 'COMP-MULTI-2', 275001, NULL, 'e1'),
  '^ERRO P0001: Pagamento de 275001 centavos excede o saldo do passivo do grupo pagamento_liquido na folha \(275000 centavos\)$',
  'derivado: o saldo do passivo é por empregador (275000 no e1)');
-- (derivado) Contrato sem empregador cadastrado: o mapeamento é por empregador, a folha fica bloqueada.
DO $$
DECLARE
  v_trab uuid; v_cid uuid;
BEGIN
  INSERT INTO folha.employee (account_id, cpf, nome_completo, data_nascimento)
  VALUES ('a0000000-0000-0000-0000-000000000030', nextval('seq_n')::text, 'Ficticio sem empregador', '1990-01-01')
  RETURNING employee_id INTO v_trab;
  INSERT INTO folha.employment_contract (account_id, employee_id, data_admissao, cargo, salario_base, regime_trabalho)
  VALUES ('a0000000-0000-0000-0000-000000000030', v_trab, '2023-01-01', 'Cargo sem empregador', 3000.00, 'clt')
  RETURNING contract_id INTO v_cid;
  INSERT INTO ids VALUES ('csem', v_cid, 'a0000000-0000-0000-0000-000000000030', NULL);
END $$;
SELECT pg_temp.folha_livre('rsem', :A, '2026-06-01');
SELECT pg_temp.resultado('rsem', 'csem', 'SALARIO_BASE=100000,INSS_EMPREGADO=8000');
INSERT INTO saida VALUES ('rsem', pg_temp.contabiliza('rsem'));
SELECT is(
  (SELECT (v::jsonb->>'situacao') || '/' || (v::jsonb->'pendencias'->0->>'codigo') || '/'
          || ((v::jsonb->'pendencias'->0->'itens'->'contratos'->>0) = pg_temp.id('csem')::text)::text
     FROM saida WHERE k = 'rsem')
  || '/' || (SELECT count(*)::text FROM folha.accounting_outbox o WHERE o.run_id = pg_temp.id('rsem')),
  'bloqueada/contrato_sem_empregador/true/0',
  'derivado: contrato sem empregador cadastrado bloqueia a contabilização da folha, com pendência dizendo qual contrato');

-- (derivado) Resultado sem itens por rubrica (folha calculada antes da 0027): bloqueio, não erro.
SELECT pg_temp.folha('rold', 'e1', '2026-05-01');
SELECT pg_temp.resultado('rold', 'c03', 'SALARIO_BASE=100000,INSS_EMPREGADO=8000');
SET LOCAL session_replication_role = replica;
DELETE FROM folha.payroll_result_item i USING folha.payroll_result pr WHERE pr.result_id = i.result_id AND pr.run_id = pg_temp.id('rold');
SET LOCAL session_replication_role = origin;
INSERT INTO saida VALUES ('rold', pg_temp.contabiliza('rold'));
SELECT is(
  (SELECT (v::jsonb->>'situacao') || '/' || (v::jsonb->'pendencias'->0->>'codigo') FROM saida WHERE k = 'rold')
  || '/' || (SELECT count(*)::text FROM folha.accounting_outbox o WHERE o.run_id = pg_temp.id('rold')),
  'bloqueada/resultado_sem_itens/0',
  'derivado: resultado sem itens por rubrica (cálculo anterior à 0027) não é contabilizado e fica como pendência de bloqueio');

-- ===========================================================================
-- 8. GC-03 — Provisão mensal de férias e 13º com encargos
--    Entrada: um empregado, remuneração 360000, 1 avo no mês, sem saldo anterior.
--    13º: 30000. Férias: 30000 + 1/3 (10000) = 40000. Encargos 27,8%; FGTS 8%.
-- ===========================================================================
SELECT is(pg_temp.configura('e3', 'nenhuma', true,
            pg_temp.plano('e3', ARRAY['folha', 'provisao', 'ferias'])
            || pg_temp.m('e3', 'RESC_SALDO_SALARIO', 'provento', 'despesa', 'DESP.SALARIOS')
            || pg_temp.m('e3', 'RESC_DECIMO_TERCEIRO_PROP', 'provento', 'despesa', 'DESP.13', NULL, 'decimo_terceiro')
            || pg_temp.m('e3', 'LIQUIDO', 'liquido', 'passivo', 'PASS.RESCISOES_A_PAGAR', 'pagamento_liquido', NULL, NULL, 'rescisao')),
  'ok', 'preparo: empregador e3 provisiona com encargos; plano da folha, das provisões, das férias e da rescisão');
INSERT INTO saida VALUES ('p3-sem-direito', pg_temp.provisiona('e3', '2026-10-01'));
SELECT is((SELECT pg_temp.sit(v) FROM saida WHERE k = 'p3-sem-direito') || '/'
          || (SELECT p.codigo || '/' || p.tipo || '/' || (p.detalhe->'contratos'->>0 = pg_temp.id('c3')::text)
                FROM folha.contabil_pendencia p WHERE p.employer_id = pg_temp.id('e3') AND p.run_id IS NULL),
  'bloqueada/provisao_direito_ausente/bloqueio/true',
  'NEG: sem o direito (remuneração e avos) informado para o contrato vigente a provisão é bloqueada, com pendência dizendo qual contrato');
SELECT is(pg_temp.direito('c3', '2026-10-01', 3600.00, 1, 1), '', 'GC-03: direito informado: remuneração 360000, 1 avo de 13º e 1 de férias (folha.calculate)');
SELECT is(pg_temp.sit(pg_temp.provisiona('e3', '2026-10-01')), 'contabilizada', 'GC-03: provisões da competência constituídas (folha.transmit)');
SELECT is(pg_temp.linhas(pg_temp.lote_prov('e3', '2026-10-01', 'provisao_13o')),
  'DESP.13 D30000 | DESP.ENCARGOS_13 D8340 | DESP.FGTS_13 D2400 | PASS.PROV_13 C30000 | PASS.PROV_ENCARGOS_13 C8340 | PASS.PROV_FGTS_13 C2400',
  'GC-03: 13º 30000, encargos 8340, FGTS 2400');
SELECT is(pg_temp.linhas(pg_temp.lote_prov('e3', '2026-10-01', 'provisao_ferias')),
  'DESP.ENCARGOS_FERIAS D11120 | DESP.FERIAS D40000 | DESP.FGTS_FERIAS D3200 | PASS.PROV_ENCARGOS_FERIAS C11120 | PASS.PROV_FERIAS C40000 | PASS.PROV_FGTS_FERIAS C3200',
  'GC-03: férias com o terço 40000, encargos 11120, FGTS 3200');
SELECT is(
  (SELECT sum(o.total_debito_minor)::text || '/' || sum(o.total_credito_minor)::text || '/' || count(*)::text
     FROM folha.accounting_outbox o WHERE o.employer_id = pg_temp.id('e3') AND o.competencia = '2026-10-01' AND o.run_id IS NULL),
  '95060/95060/2', 'GC-03: total 95060 = 95060 (um lote por provisão, como os eventos do contrato: 40740 + 54320)');
SELECT is(
  (SELECT string_agg(m.provisao || '.' || m.componente || '=' || m.valor_minor || ':' || m.tipo, ' ' ORDER BY m.provisao, m.componente)
     FROM folha.provision_ledger m WHERE m.contract_id = pg_temp.id('c3')),
  'decimo_terceiro.encargos=8340:constituicao decimo_terceiro.fgts=2400:constituicao decimo_terceiro.principal=30000:constituicao'
  || ' ferias.encargos=11120:constituicao ferias.fgts=3200:constituicao ferias.principal=40000:constituicao',
  'GC-03: razão por trabalhador com seis movimentos de constituição');
SELECT is(
  (SELECT (m.memoria->>'remuneracao_minor') || '/' || (m.memoria->>'avos')::numeric || '/' || (m.memoria->>'ferias_minor') || '/' || (m.memoria->>'terco_minor')
          || '/' || (m.memoria->>'saldo_devido_minor') || '/' || (m.memoria->>'saldo_anterior_minor')
     FROM folha.provision_ledger m WHERE m.contract_id = pg_temp.id('c3') AND m.provisao = 'ferias' AND m.componente = 'principal'),
  '360000/1.00/30000/10000/40000/0', 'cada movimento guarda a memória de cálculo (remuneração, avos, saldo devido e saldo anterior)');
-- a_validar: o lote de férias nasce retido por causa do parâmetro não conferido na fonte.
SELECT is(
  (SELECT string_agg(o.evento_tipo || ':' || o.status, ' ' ORDER BY o.evento_tipo)
     FROM folha.accounting_outbox o WHERE o.employer_id = pg_temp.id('e3') AND o.competencia = '2026-10-01' AND o.run_id IS NULL)
  || ' ' || (SELECT string_agg(p.codigo || '/' || p.tipo, ',') FROM folha.contabil_pendencia p
              WHERE p.outbox_id = pg_temp.lote_prov('e3', '2026-10-01', 'provisao_ferias')),
  'provisao_13o:pendente provisao_ferias:retido a_validar:contabil_provisao_encargos_incide_terco_ferias/a_validar',
  'a_validar: o lote de férias (encargos sobre o terço) nasce RETIDO, com pendência do parâmetro; o de 13º sai pendente');
SELECT matches(
  pg_temp.le(:A, array_remove(pg_temp.todas(), 'folha.close'), :S_TX,
    format('SELECT folha.contabil_pendencia_liberar_v1(%L, ''conferido'')',
           (SELECT p.pendencia_id FROM folha.contabil_pendencia p WHERE p.outbox_id = pg_temp.lote_prov('e3', '2026-10-01', 'provisao_ferias')))),
  '^ERRO 42501: ', 'NEG: liberar pendência a_validar exige folha.close');
SELECT throws_ok(
  format('UPDATE folha.accounting_outbox SET status = ''pendente'' WHERE outbox_id = %s', pg_temp.lote_prov('e3', '2026-10-01', 'provisao_ferias')),
  '23514', NULL, 'NEG: nem o dono passa o lote retido a pendente enquanto houver pendência a_validar sem liberação');
SELECT is(
  pg_temp.faz(:A, ARRAY['folha.read', 'folha.close'], :S_CLOSE,
    format('SELECT folha.contabil_pendencia_liberar_v1(%L, ''incidência conferida pelo responsável'')',
           (SELECT p.pendencia_id FROM folha.contabil_pendencia p WHERE p.outbox_id = pg_temp.lote_prov('e3', '2026-10-01', 'provisao_ferias')))),
  'pendente', 'liberada a pendência (folha.close, com motivo), o lote retido passa a pendente');
SELECT is(
  (SELECT p.liberada_por_subject::text || '/' || p.liberacao_motivo FROM folha.contabil_pendencia p
    WHERE p.outbox_id = pg_temp.lote_prov('e3', '2026-10-01', 'provisao_ferias')),
  '83000000-0000-0000-0000-000000000003/incidência conferida pelo responsável', 'a liberação guarda o subject e o motivo');
SELECT is(pg_temp.sit(pg_temp.provisiona('e3', '2026-10-01')), 'inalterada', 'regra V6: constituir de novo a mesma competência não cria nada');

-- GC-03b: no mês seguinte a remuneração sobe para 396000. Saldo devido de 13º com 2 avos =
-- 66000; já provisionado 30000; provisão do mês = 36000 (não 33000).
SELECT is(pg_temp.direito('c3', '2026-11-01', 3960.00, 2, 2), '', 'GC-03b: direito de novembro: remuneração 396000, 2 avos');
SELECT is(pg_temp.sit(pg_temp.provisiona('e3', '2026-11-01')), 'contabilizada', 'GC-03b: provisões de novembro constituídas');
SELECT is(
  (SELECT m.valor_minor::text || '/' || (m.memoria->>'saldo_devido_minor') || '/' || (m.memoria->>'saldo_anterior_minor')
     FROM folha.provision_ledger m
    WHERE m.contract_id = pg_temp.id('c3') AND m.competencia = '2026-11-01' AND m.provisao = 'decimo_terceiro' AND m.componente = 'principal'),
  '36000/66000/30000', 'GC-03b: provisão do mês = 36000 (saldo devido 66000 menos 30000 provisionados), e não 33000');
-- (derivado) Demais linhas de novembro, pelo mesmo método:
--   13º: encargos 27,8% x 66000 = 18348 - 8340 = 10008; FGTS 8% x 66000 = 5280 - 2400 = 2880.
--   Férias: 396000 x 2/12 = 66000 + terço 22000 = 88000 - 40000 = 48000;
--           encargos 27,8% x 88000 = 24464 - 11120 = 13344; FGTS 8% x 88000 = 7040 - 3200 = 3840.
SELECT is(pg_temp.linhas(pg_temp.lote_prov('e3', '2026-11-01', 'provisao_13o')) || ' ; ' || pg_temp.linhas(pg_temp.lote_prov('e3', '2026-11-01', 'provisao_ferias')),
  'DESP.13 D36000 | DESP.ENCARGOS_13 D10008 | DESP.FGTS_13 D2880 | PASS.PROV_13 C36000 | PASS.PROV_ENCARGOS_13 C10008 | PASS.PROV_FGTS_13 C2880'
  || ' ; DESP.ENCARGOS_FERIAS D13344 | DESP.FERIAS D48000 | DESP.FGTS_FERIAS D3840 | PASS.PROV_ENCARGOS_FERIAS C13344 | PASS.PROV_FERIAS C48000 | PASS.PROV_FGTS_FERIAS C3840',
  'derivado: as demais linhas de novembro seguem o método do saldo (o reajuste corrige o estoque inteiro)');
SELECT matches(pg_temp.provisiona('e3', '2026-10-01'),
  '^ERRO P0001: Já existe provisão vigente em competência posterior a 10/2026',
  'NEG: competência com provisão posterior não é refeita (a correção entra pela seguinte)');

-- (derivado) Baixa no pagamento: recibo de férias do c3 em novembro, com provisão de sobra.
--   Entrada: férias 60000 + terço 20000 = 80000; INSS 6000; líquido 74000; FGTS 6400;
--   patronal 16000, RAT 1600, terceiros 4640 (27,8% de 80000 = 22240).
--   Saldos antes: férias 88000, encargos 24464, FGTS 7040. Tudo é coberto pela provisão:
--   débito nas provisões (80000, 22240, 6400), nenhuma despesa nova. Sobram 8000, 2224 e 640.
SELECT pg_temp.folha('rf3', 'e3', '2026-11-01', 'ferias');
SELECT pg_temp.resultado('rf3', 'c3', 'FERIAS_GOZO=60000,FERIAS_TERCO=20000,INSS_EMPREGADO=6000,FGTS_DEPOSITO=6400',
                         'INSS_PATRONAL=16000,RAT_SAT=1600,TERCEIROS=4640');
SELECT is(pg_temp.sit(pg_temp.contabiliza('rf3')) || ' ' || pg_temp.linhas(pg_temp.lote('rf3', 'ferias')),
  'contabilizada PASS.FGTS C6400 | PASS.INSS_RETIDO C6000 | PASS.PREVIDENCIA C17600 | PASS.PROV_ENCARGOS_FERIAS D22240'
  || ' | PASS.PROV_FERIAS D80000 | PASS.PROV_FGTS_FERIAS D6400 | PASS.SALARIOS_A_PAGAR C74000 | PASS.TERCEIROS C4640',
  'derivado (baixa): férias pagas debitam a provisão, e os encargos efetivos debitam as provisões de encargos; nenhuma despesa em dobro');
SELECT is(pg_temp.saldo('c3', 'ferias', 'principal')::text || '/' || pg_temp.saldo('c3', 'ferias', 'encargos')::text || '/' || pg_temp.saldo('c3', 'ferias', 'fgts')::text
          || ' ' || (SELECT string_agg(x.componente || '=' || x.soma, ',' ORDER BY x.componente)
                       FROM (SELECT m.componente, sum(m.valor_minor)::text AS soma FROM folha.provision_ledger m
                              WHERE m.outbox_id = pg_temp.lote('rf3', 'ferias') AND m.tipo = 'baixa_pagamento' GROUP BY 1) x),
  '8000/2224/640 encargos=-22240,fgts=-6400,principal=-80000',
  'derivado (baixa): movimentos de baixa no razão, e saldos 8000, 2224 e 640');
SELECT is(
  (SELECT v.situacao || '/' || v.contabil_proventos_minor || '/' || v.contabil_fgts_minor FROM folha.v_reconciliacao_contabil v WHERE v.run_id = pg_temp.id('rf3')),
  'aguardando_confirmacao/80000/6400', 'derivado: a reconciliação reconhece os proventos e o FGTS mesmo quando a linha debitou a provisão');

-- (derivado) Estorno na rescisão: o c3 é desligado em dezembro com sobra de provisão.
--   Entrada: saldo de salário 100000; 13º proporcional 50000; INSS 10000; líquido 140000.
--   Saldos antes: 13º 66000 / 18348 / 5280; férias 8000 / 2224 / 640.
--   13º: baixa 50000, sobram 16000. Estorno das sobras contra o resultado:
--   16000 + 18348 + 5280 + 8000 + 2224 + 640 = 50492.
--   Débitos: 100000 + (50000 + 16000) + 18348 + 5280 + 8000 + 2224 + 640 = 200492.
--   Créditos: 10000 + 140000 + 50492 = 200492.
SELECT pg_temp.folha('rr3', 'e3', '2026-12-01', 'rescisao');
SELECT pg_temp.resultado('rr3', 'c3', 'RESC_SALDO_SALARIO=100000,RESC_DECIMO_TERCEIRO_PROP=50000,INSS_EMPREGADO=10000');
SELECT is(pg_temp.sit(pg_temp.contabiliza('rr3')) || ' ' || pg_temp.linhas(pg_temp.lote('rr3', 'rescisao')),
  'contabilizada DESP.SALARIOS D100000 | PASS.INSS_RETIDO C10000 | PASS.PROV_13 D66000 | PASS.PROV_ENCARGOS_13 D18348'
  || ' | PASS.PROV_ENCARGOS_FERIAS D2224 | PASS.PROV_FERIAS D8000 | PASS.PROV_FGTS_13 D5280 | PASS.PROV_FGTS_FERIAS D640'
  || ' | PASS.RESCISOES_A_PAGAR C140000 | RED.REVERSAO_PROVISAO C50492',
  'derivado (estorno em rescisão): baixa até o saldo, sobra estornada contra o resultado, líquido na conta da rescisão (mapeamento por evento)');
SELECT is(
  (SELECT string_agg(m.provisao || '.' || m.componente || '=' || sum_v, ' ' ORDER BY m.provisao, m.componente)
     FROM (SELECT provisao, componente, sum(valor_minor)::text AS sum_v FROM folha.provision_ledger
            WHERE contract_id = pg_temp.id('c3') GROUP BY 1, 2) m)
  || ' ' || (SELECT count(*)::text FROM folha.provision_ledger m WHERE m.outbox_id = pg_temp.lote('rr3', 'rescisao') AND m.tipo = 'estorno_rescisao'),
  'decimo_terceiro.encargos=0 decimo_terceiro.fgts=0 decimo_terceiro.principal=0 ferias.encargos=0 ferias.fgts=0 ferias.principal=0 6',
  'derivado (estorno em rescisão): seis movimentos de estorno e as provisões do trabalhador zeradas');
SELECT is(
  (SELECT o.status || ' ' || (SELECT string_agg(p.codigo, ',') FROM folha.contabil_pendencia p WHERE p.outbox_id = o.outbox_id)
     FROM folha.accounting_outbox o WHERE o.outbox_id = pg_temp.lote('rr3', 'rescisao')),
  'retido a_validar:contabil_rescisao_baixa_provisao_encargos',
  'a_validar: rescisão com sobra de provisão de encargos (variante GC-06b do parecer) nasce retida, com a pendência do parâmetro');

-- ===========================================================================
-- 9. GC-06 — Rescisão sem justa causa, com baixa de provisão e multa do FGTS
--    Premissas: patronais = 0 e a empresa não provisionava encargos.
--    Entrada: saldo de salário 100000; aviso indenizado 300000; 13º proporcional 150000
--    (provisão existente 150000); férias proporcionais + 1/3 200000 (provisão existente 180000);
--    INSS 20000; IRRF 0; líquido 730000. FGTS 44000; multa de 40% = 400000.
-- ===========================================================================
SELECT is(pg_temp.configura('e6', 'nenhuma', false, pg_temp.plano('e6', ARRAY['folha', 'rescisao', 'provisao'])), 'ok',
  'preparo: empregador e6 não provisiona encargos; plano da folha, da rescisão e das provisões');
-- Preparo (derivado) das provisões existentes, pela constituição de setembro:
--   c6: remuneração 180000; 13º 10 avos = 150000; férias 9 avos = 135000 + terço 45000 = 180000.
--   c6b (outro contrato, para os casos de redução adiante): remuneração 120000; 6 avos de 13º
--   = 60000; 6 avos de férias = 60000 + 20000 = 80000.
SELECT is(pg_temp.direito('c6', '2026-09-01', 1800.00, 10, 9) || pg_temp.direito('c6b', '2026-09-01', 1200.00, 6, 6)
          || pg_temp.sit(pg_temp.provisiona('e6', '2026-09-01')),
  'contabilizada', 'preparo (derivado): provisões de setembro do e6');
SELECT is(pg_temp.saldo('c6', 'decimo_terceiro', 'principal')::text || '/' || pg_temp.saldo('c6', 'ferias', 'principal')::text
          || '/' || (SELECT count(*)::text FROM folha.provision_ledger m WHERE m.contract_id = pg_temp.id('c6') AND m.componente <> 'principal'),
  '150000/180000/0', 'GC-06 (premissa): provisão existente de 13º 150000 e de férias 180000, sem provisão de encargos');
SELECT pg_temp.folha('r06', 'e6', '2026-10-01', 'rescisao');
SELECT pg_temp.resultado('r06', 'c6',
  'RESC_SALDO_SALARIO=100000,AVISO_PREVIO_INDENIZADO=300000,RESC_DECIMO_TERCEIRO_PROP=150000,RESC_FERIAS_PROP=200000,INSS_EMPREGADO=20000,IRRF=0,FGTS_DEPOSITO=44000,FGTS_MULTA_RESCISORIA=400000');
SELECT is(pg_temp.sit(pg_temp.contabiliza('r06')), 'contabilizada', 'GC-06: rescisão contabilizada');
SELECT is(pg_temp.linhas(pg_temp.lote('r06', 'rescisao')),
  'DESP.AVISO_INDENIZADO D300000 | DESP.FERIAS D20000 | DESP.FGTS D44000 | DESP.MULTA_FGTS D400000 | DESP.SALARIOS D100000'
  || ' | PASS.FGTS C444000 | PASS.INSS_RETIDO C20000 | PASS.PROV_13 D150000 | PASS.PROV_FERIAS D180000 | PASS.RESCISOES_A_PAGAR C730000',
  'GC-06: as dez linhas do parecer (baixa das provisões até o saldo; complemento de férias 20000 em despesa; FGTS e multa em 444000)');
SELECT is(pg_temp.total(pg_temp.lote('r06', 'rescisao')), '1194000/1194000', 'GC-06: total 1194000');
SELECT is(
  (SELECT e->>'creditMinor' FROM folha.accounting_outbox o, jsonb_array_elements(o.payload->'entries') e
    WHERE o.outbox_id = pg_temp.lote('r06', 'rescisao') AND e->>'accountKey' = 'PASS.RESCISOES_A_PAGAR'),
  '730000', 'GC-06: "rescisões a pagar" = 730000, sem a multa do FGTS (E12)');
SELECT is(
  (SELECT string_agg(m.provisao || '=' || m.valor_minor || ':' || m.tipo, ' ' ORDER BY m.provisao)
     FROM folha.provision_ledger m WHERE m.outbox_id = pg_temp.lote('r06', 'rescisao'))
  || ' ' || pg_temp.saldo('c6', 'decimo_terceiro', 'principal')::text || '/' || pg_temp.saldo('c6', 'ferias', 'principal')::text
  || ' ' || (SELECT o.status FROM folha.accounting_outbox o WHERE o.outbox_id = pg_temp.lote('r06', 'rescisao')),
  'decimo_terceiro=-150000:baixa_pagamento ferias=-180000:baixa_pagamento 0/0 pendente',
  'GC-06: baixa limitada ao saldo (regra V11) e provisões do empregado zeradas depois do lote');

-- (derivado) Redução e refazimento da provisão, com o c6b, em novembro (o c6 foi desligado).
UPDATE folha.employment_contract SET data_demissao = '2026-10-20' WHERE contract_id = pg_temp.id('c6');
SELECT is(pg_temp.sit(pg_temp.provisiona('e6', '2026-11-01')), 'bloqueada',
  'derivado: novembro sem o direito do c6b fica bloqueado (o desligado c6 não é exigido)');
--   c6b em novembro: 13º com 3 avos = 30000, contra 60000 provisionados: redução de 30000
--   (lado invertido: débito na provisão, crédito na despesa). Férias iguais: sem movimento.
SELECT is(pg_temp.direito('c6b', '2026-11-01', 1200.00, 3, 6), '', 'derivado: direito de novembro do c6b (13º cai para 3 avos)');
INSERT INTO saida VALUES ('p6nov', pg_temp.provisiona('e6', '2026-11-01'));
SELECT is(
  (SELECT (v::jsonb->>'situacao') || ' ' || (SELECT string_agg((l->>'evento_tipo') || ':' || (l->>'situacao'), ',') FROM jsonb_array_elements(v::jsonb->'lotes') l)
     FROM saida WHERE k = 'p6nov')
  || ' ' || pg_temp.linhas(pg_temp.lote_prov('e6', '2026-11-01', 'provisao_13o'))
  || ' ' || (SELECT m.tipo || '=' || m.valor_minor FROM folha.provision_ledger m WHERE m.outbox_id = pg_temp.lote_prov('e6', '2026-11-01', 'provisao_13o')),
  'contabilizada provisao_13o:contabilizado,provisao_ferias:sem_movimento DESP.13 C30000 | PASS.PROV_13 D30000 reducao=-30000',
  'derivado (regra V2): quando o saldo devido cai, a linha inverte o lado (nunca valor negativo); férias sem diferença não geram lote');
SELECT is(
  (SELECT count(*) FILTER (WHERE p.resolvida_em IS NOT NULL)::text || '/' || count(*)::text
     FROM folha.contabil_pendencia p WHERE p.employer_id = pg_temp.id('e6') AND p.tipo = 'bloqueio'),
  '1/1', 'derivado: a pendência de bloqueio da provisão foi resolvida quando a constituição passou');
--   Correção do direito na mesma competência (13º = 4 avos = 40000): o lote pendente é
--   CANCELADO, o razão é desfeito e sai a versão 2 com redução de 20000. Saldo final 40000.
SELECT is(pg_temp.direito('c6b', '2026-11-01', 1200.00, 4, 6) || pg_temp.sit(pg_temp.provisiona('e6', '2026-11-01')), 'contabilizada',
  'derivado: direito corrigido e provisão de novembro refeita');
SELECT is(
  (SELECT string_agg(o.versao || ':' || o.status || ':' || o.vigente, ' ' ORDER BY o.versao)
     FROM folha.accounting_outbox o WHERE o.employer_id = pg_temp.id('e6') AND o.competencia = '2026-11-01' AND o.evento_tipo = 'provisao_13o')
  || ' ' || pg_temp.linhas(pg_temp.lote_prov('e6', '2026-11-01', 'provisao_13o'))
  || ' ' || pg_temp.saldo('c6b', 'decimo_terceiro', 'principal')::text
  || ' ' || (SELECT string_agg(m.tipo || '=' || m.valor_minor, ',' ORDER BY m.movement_id) FROM folha.provision_ledger m
              WHERE m.contract_id = pg_temp.id('c6b') AND m.provisao = 'decimo_terceiro' AND m.competencia = '2026-11-01'),
  '1:cancelado:false 2:pendente:true DESP.13 C20000 | PASS.PROV_13 D20000 40000 reducao=-30000,reversao_de_lote=30000,reducao=-20000',
  'derivado (regra V7): lote ainda pendente é cancelado (fica na tabela), o razão é revertido e a versão 2 leva o saldo a 40000');
SELECT is(pg_temp.sit(pg_temp.provisiona('e6', '2026-11-01')), 'inalterada', 'derivado: refazer sem mudança não cria nada');

-- ===========================================================================
-- 10. GC-07 — Recálculo depois do despacho (estorno e nova versão)
--     Estado inicial: GC-01 despachado e confirmado (versão 1).
--     Recálculo: salário 310000; INSS 26000; líquido 284000; FGTS 24800.
-- ===========================================================================
CREATE TEMP TABLE v1 AS
  SELECT o.outbox_id, o.payload, o.payload_hash, o.idempotency_key
    FROM folha.accounting_outbox o WHERE o.outbox_id = pg_temp.lote('r01', 'folha_mensal');
-- O consumidor da fila (privilégios do worker) marca despachado e confirmado.
SELECT is(
  pg_temp.pedido(:A, ARRAY['folha.read'], :S_TX, true, true, ARRAY[
    format('UPDATE folha.accounting_outbox SET status = ''despachado'', despachado_em = now() WHERE outbox_id = %s', (SELECT outbox_id FROM v1)),
    format('UPDATE folha.accounting_outbox SET status = ''confirmado'', confirmado_em = now() WHERE outbox_id = %s RETURNING status', (SELECT outbox_id FROM v1))]),
  'confirmado', 'GC-07 (estado inicial): o consumidor da fila marca a versão 1 como despachada e confirmada');
-- Recálculo (a folha fechada não reabre na 0027; o teste grava o novo resultado direto).
SELECT pg_temp.resultado('r01', 'c01', 'SALARIO_BASE=310000,INSS_EMPREGADO=26000,IRRF=0,FGTS_DEPOSITO=24800');
INSERT INTO saida VALUES ('gc07', pg_temp.contabiliza('r01'));
SELECT is(
  (SELECT (v::jsonb->>'situacao') || '/' || (v::jsonb->'lotes'->0->>'situacao') || '/' || (v::jsonb->>'lotes_inseridos')
          || '/' || ((v::jsonb->'lotes'->0->>'estorno_outbox_id') IS NOT NULL)
     FROM saida WHERE k = 'gc07'),
  'contabilizada/substituido/2/true', 'GC-07: o recálculo gera dois lotes: o estorno da versão 1 e a versão 2');
SELECT is(
  (SELECT pg_temp.linhas(o.outbox_id) || ' = ' || pg_temp.total(o.outbox_id) FROM folha.accounting_outbox o
    WHERE o.run_id = pg_temp.id('r01') AND o.evento_tipo = 'estorno'),
  'DESP.FGTS C24000 | DESP.SALARIOS C300000 | PASS.FGTS D24000 | PASS.INSS_RETIDO D25000 | PASS.SALARIOS_A_PAGAR D275000 = 324000/324000',
  'GC-07: lote de estorno da versão 1, com os lados trocados, total 324000');
SELECT is(
  (SELECT (o.estorna_outbox_id = (SELECT outbox_id FROM v1))::text || '/' || ((o.payload->>'reverses') = (SELECT idempotency_key FROM v1))::text
          || '/' || o.data_lancamento || '/' || o.status || '/' || o.versao
     FROM folha.accounting_outbox o WHERE o.run_id = pg_temp.id('r01') AND o.evento_tipo = 'estorno'),
  'true/true/2026-10-31/pendente/1', 'GC-07: o estorno referencia a versão 1 (coluna e campo reverses) e leva a data do lote estornado (configuração do e1)');
SELECT is(pg_temp.linhas(pg_temp.lote('r01', 'folha_mensal')) || ' = ' || pg_temp.total(pg_temp.lote('r01', 'folha_mensal'))
          || ' v' || (SELECT o.versao FROM folha.accounting_outbox o WHERE o.outbox_id = pg_temp.lote('r01', 'folha_mensal')),
  'DESP.FGTS D24800 | DESP.SALARIOS D310000 | PASS.FGTS C24800 | PASS.INSS_RETIDO C26000 | PASS.SALARIOS_A_PAGAR C284000 = 334800/334800 v2',
  'GC-07: lote versão 2, total 334800');
SELECT is(
  (SELECT (o.payload = v1.payload)::text || '/' || (o.payload_hash = v1.payload_hash)::text || '/' || o.status || '/' || o.vigente
     FROM folha.accounting_outbox o JOIN v1 ON v1.outbox_id = o.outbox_id),
  'true/true/confirmado/false', 'GC-07: a versão 1 continua íntegra no outbox (não é editada); só deixa de ser a vigente');
SELECT is(
  (SELECT string_agg(x.conta || '=' || x.saldo, ' ' ORDER BY x.conta COLLATE "C")
     FROM (SELECT e->>'accountKey' AS conta, sum((e->>'debitMinor')::bigint - (e->>'creditMinor')::bigint)::text AS saldo
             FROM folha.accounting_outbox o, jsonb_array_elements(o.payload->'entries') e
            WHERE o.run_id = pg_temp.id('r01') GROUP BY 1) x),
  'DESP.FGTS=24800 DESP.SALARIOS=310000 PASS.FGTS=-24800 PASS.INSS_RETIDO=-26000 PASS.SALARIOS_A_PAGAR=-284000',
  'GC-07: o efeito líquido dos três lotes no razão é o da versão 2');
SELECT is(pg_temp.sit(pg_temp.contabiliza('r01')) || '/' || (SELECT count(*)::text FROM folha.accounting_outbox o WHERE o.run_id = pg_temp.id('r01')),
  'inalterada/3', 'GC-07: despachar a versão 2 outra vez não cria linha');

-- (derivado, regra V7) Lote ainda PENDENTE: o recálculo cancela e substitui, sem estorno.
--   v1: salário 200000, INSS 15000, líquido 185000, FGTS 16000 (total 216000).
--   v2: salário 210000, INSS 16000, líquido 194000, FGTS 16800 (total 226800).
SELECT pg_temp.folha('rp', 'e1', '2026-08-01');
SELECT pg_temp.resultado('rp', 'c03', 'SALARIO_BASE=200000,INSS_EMPREGADO=15000,FGTS_DEPOSITO=16000');
SELECT is(pg_temp.sit(pg_temp.contabiliza('rp')), 'contabilizada', 'derivado: versão 1 (pendente)');
SELECT pg_temp.resultado('rp', 'c03', 'SALARIO_BASE=210000,INSS_EMPREGADO=16000,FGTS_DEPOSITO=16800');
INSERT INTO saida VALUES ('rp-2', pg_temp.contabiliza('rp'));
SELECT is(
  (SELECT pg_temp.sit(v) FROM saida WHERE k = 'rp-2') || ' ' ||
  (SELECT string_agg(o.evento_tipo || ':' || o.versao || ':' || o.status || ':' || o.vigente || ':' || o.total_debito_minor
                     || ':' || (o.cancelado_em IS NOT NULL), ' ' ORDER BY o.outbox_id)
     FROM folha.accounting_outbox o WHERE o.run_id = pg_temp.id('rp')),
  'contabilizada folha_mensal:1:cancelado:false:216000:true folha_mensal:2:pendente:true:226800:false',
  'derivado (regra V7): o lote pendente é cancelado (fica registrado) e sai a versão 2; não há estorno do que não foi despachado');
-- (derivado, regra V7) Lote REJEITADO pelo contábil: nova versão, sem estorno, mesmo com o mesmo conteúdo.
UPDATE folha.accounting_outbox SET status = 'despachado' WHERE outbox_id = pg_temp.lote('rp', 'folha_mensal');
UPDATE folha.accounting_outbox SET status = 'rejeitado', erro_json = '{"motivo": "periodo fechado"}' WHERE outbox_id = pg_temp.lote('rp', 'folha_mensal');
INSERT INTO saida VALUES ('rp-3', pg_temp.contabiliza('rp'));
SELECT is(
  (SELECT pg_temp.sit(v) FROM saida WHERE k = 'rp-3') || ' ' ||
  (SELECT string_agg(o.evento_tipo || ':' || o.versao || ':' || o.status || ':' || o.vigente, ' ' ORDER BY o.outbox_id)
     FROM folha.accounting_outbox o WHERE o.run_id = pg_temp.id('rp')),
  'contabilizada folha_mensal:1:cancelado:false folha_mensal:2:rejeitado:false folha_mensal:3:pendente:true',
  'derivado (regra V7): lote rejeitado dá lugar à versão 3, sem estorno (nada tinha sido lançado) e sem reenvio em silêncio');
-- (derivado) Data do estorno pela configuração: com 'data_do_estorno', o estorno leva o dia em que é feito.
SELECT is(
  pg_temp.faz(:A, ARRAY['folha.read', 'folha.admin'], :S_ADMIN,
    format('SELECT folha.contabil_config_definir_v1(%L, ''nenhuma'', ''data_do_estorno'', false)::text', pg_temp.id('e1'))),
  '', 'preparo: o e1 passa a datar o estorno pelo dia em que é feito');
UPDATE folha.accounting_outbox SET status = 'despachado' WHERE outbox_id = pg_temp.lote('rp', 'folha_mensal');
SELECT pg_temp.resultado('rp', 'c03', 'SALARIO_BASE=220000,INSS_EMPREGADO=17000,FGTS_DEPOSITO=17600');
INSERT INTO saida VALUES ('rp-4', pg_temp.contabiliza('rp'));
SELECT is(
  (SELECT pg_temp.sit(v) FROM saida WHERE k = 'rp-4') || ' ' ||
  (SELECT (o.data_lancamento = (now() AT TIME ZONE 'America/Sao_Paulo')::date)::text || '/' || o.versao || '/' || o.total_debito_minor
     FROM folha.accounting_outbox o WHERE o.run_id = pg_temp.id('rp') AND o.evento_tipo = 'estorno'),
  'contabilizada true/3/226800', 'derivado: com a outra política, o estorno da versão 3 (226800) é datado do dia do estorno');

-- Um lote vigente por folha e evento, no dado (índice único), e o lote não é editado.
SET LOCAL session_replication_role = replica;
SELECT throws_ok(
  format($$INSERT INTO folha.accounting_outbox (account_id, run_id, evento_tipo, payload, idempotency_key, formato, employer_id,
             competencia, versao, data_lancamento, payload_hash, total_debito_minor, total_credito_minor, composicao, contabilizado_por_subject)
           VALUES ('a0000000-0000-0000-0000-000000000030', %L, 'folha_mensal', '{}', 'direto-2', 'v2', %L, '2026-10-01', 9, '2026-10-31',
                   repeat('a', 64), 100, 100, '[]', gen_random_uuid())$$, pg_temp.id('r01'), pg_temp.id('e1')),
  '23505', NULL, 'NEG (duplicidade): segundo lote vigente para a mesma folha e evento é recusado pelo índice único');
SET LOCAL session_replication_role = origin;
SELECT matches(
  pg_temp.insere_sob_contexto(format(
    $$INSERT INTO folha.accounting_outbox (account_id, run_id, evento_tipo, payload, idempotency_key, formato, employer_id,
        competencia, versao, data_lancamento, payload_hash, total_debito_minor, total_credito_minor, composicao, contabilizado_por_subject)
      SELECT o.account_id, %L, o.evento_tipo, o.payload, 'direto-3', 'v2', o.employer_id, o.competencia, o.versao, o.data_lancamento,
             o.payload_hash, o.total_debito_minor + 1, o.total_credito_minor + 1, o.composicao, gen_random_uuid()
        FROM folha.accounting_outbox o WHERE o.outbox_id = %s$$, pg_temp.id('r08b'), pg_temp.lote('r02', 'folha_mensal'))),
  '^ERRO 23514: accounting_outbox: os totais do lote \(D 746901 / C 746901\) não são a soma das linhas \(D 746900 / C 746900\)$',
  'NEG (E3): totais declarados que não são a soma das linhas do evento são recusados pelo gatilho, mesmo balanceados entre si');
SELECT matches(
  pg_temp.insere_sob_contexto(format(
    $$INSERT INTO folha.accounting_outbox (account_id, run_id, evento_tipo, payload, idempotency_key, formato, employer_id,
        competencia, versao, data_lancamento, payload_hash, total_debito_minor, total_credito_minor, composicao, contabilizado_por_subject)
      SELECT o.account_id, %L, o.evento_tipo, jsonb_set(o.payload, '{entries,0,debitMinor}', '"1"'), 'direto-4', 'v2', o.employer_id,
             o.competencia, o.versao, o.data_lancamento, o.payload_hash, o.total_debito_minor, o.total_credito_minor, o.composicao, gen_random_uuid()
        FROM folha.accounting_outbox o WHERE o.outbox_id = %s$$, pg_temp.id('r08b'), pg_temp.lote('r01', 'folha_mensal'))),
  '^ERRO 23514: accounting_outbox: ', 'NEG: evento com linha adulterada (dois lados ou soma diferente) é recusado pelo gatilho');
SELECT matches(
  pg_temp.com_espelho(:A, ARRAY['folha.read', 'folha.transmit'], :S_TX,
    format('UPDATE folha.accounting_outbox SET payload = ''{}'' WHERE outbox_id = %s RETURNING ''alterou''', pg_temp.lote('r02', 'folha_mensal'))),
  '^ERRO 23514: accounting_outbox: o lote .* não pode ser alterado; só o estado anda$',
  'NEG: com os privilégios do worker, o conteúdo do lote não é alterado');
SELECT matches(
  pg_temp.com_espelho(:A, ARRAY['folha.read', 'folha.transmit'], :S_TX,
    format('UPDATE folha.accounting_outbox SET vigente = false WHERE outbox_id = %s RETURNING ''alterou''', pg_temp.lote('r02', 'folha_mensal'))),
  '^ERRO 23514: accounting_outbox: a vigência do lote', 'NEG: o worker não tira a vigência de um lote');
SELECT matches(
  pg_temp.com_espelho(:A, ARRAY['folha.read', 'folha.transmit'], :S_TX,
    format('UPDATE folha.accounting_outbox SET status = ''cancelado'', cancelado_em = now() WHERE outbox_id = %s RETURNING ''alterou''', pg_temp.lote('r02', 'folha_mensal'))),
  '^ERRO 23514: accounting_outbox: o lote .* não passa de pendente para cancelado$', 'NEG: o worker não cancela lote');
SELECT is(
  pg_temp.com_espelho(:A, ARRAY['folha.read', 'folha.transmit'], :S_TX,
    format('UPDATE folha.accounting_outbox SET status = ''despachado'', despachado_em = now() WHERE outbox_id = %s RETURNING status', pg_temp.lote('r02', 'folha_mensal'))),
  'despachado', 'âncora: o worker marca o lote pendente como despachado');
SELECT matches(
  pg_temp.com_espelho(:A, ARRAY['folha.read', 'folha.transmit'], :S_TX,
    format($$INSERT INTO folha.accounting_outbox (account_id, run_id, evento_tipo, payload, idempotency_key)
             VALUES ('a0000000-0000-0000-0000-000000000030', %L, 'folha_mensal', '{}', 'direto-5') RETURNING 'gravou'$$, pg_temp.id('r01'))),
  '^ERRO 42501: permission denied for table accounting_outbox$', 'NEG: o worker não insere lote direto na tabela');
SELECT matches(
  pg_temp.com_espelho(:A, ARRAY['folha.read', 'folha.transmit'], :S_TX,
    format('UPDATE folha.contabil_mapa SET ativo = false WHERE employer_id = %L RETURNING ''alterou''', pg_temp.id('e1'))),
  '^ERRO 42501: permission denied for table contabil_mapa$', 'NEG: o worker não altera o mapeamento direto na tabela');
SELECT throws_ok(
  format('UPDATE folha.provision_ledger SET valor_minor = 1 WHERE contract_id = %L', pg_temp.id('c3')),
  '23514', 'provision_ledger: o razão de provisões só aceita inclusão', 'NEG: o razão de provisões não aceita UPDATE (nem do dono)');
SELECT throws_ok(
  format('DELETE FROM folha.accounting_outbox WHERE outbox_id = %s', pg_temp.lote('r02', 'folha_mensal')),
  '23514', NULL, 'NEG: lote v2 não é apagado (nem pelo dono)');

-- ===========================================================================
-- 11. Dimensão das linhas (derivados)
-- ===========================================================================
-- 11.1 Centro de custo. cd1 (ADM): salário 200000, INSS 15000, líquido 185000.
--      cd2 (PROD): salário 100000, INSS 8000, líquido 92000. O salário do centro PROD é CUSTO
--      (mapeamento com escopo de centro de custo). Passivo não leva dimensão:
--      INSS 15000 + 8000 = 23000; líquido 185000 + 92000 = 277000. Total 300000.
SELECT is(pg_temp.configura('ed', 'centro_custo', false,
            pg_temp.plano('ed', ARRAY['folha'])
            || pg_temp.m('ed', 'SALARIO_BASE', 'provento', 'custo', 'CUSTO.MAO_DE_OBRA', NULL, NULL, NULL, NULL, 'PROD')),
  'ok', 'preparo: empregador ed separa as linhas de resultado por centro de custo; salário do centro PROD mapeado como custo');
SELECT is(
  pg_temp.faz(:A, ARRAY['folha.read', 'folha.admin'], :S_ADMIN,
    format('SELECT folha.contabil_contrato_dimensao_definir_v1(%L, ''ADM'', ''DP-01'', ''2026-01-01'')', pg_temp.id('cd1')),
    format('SELECT folha.contabil_contrato_dimensao_definir_v1(%L, ''PROD'', ''DP-02'', ''2026-01-01'')', pg_temp.id('cd2')),
    'SELECT ''ok'''),
  'ok', 'preparo: centro de custo e departamento dos contratos cd1 e cd2 (folha.admin)');
SELECT pg_temp.folha('rd', 'ed', '2026-10-01');
SELECT pg_temp.resultado('rd', 'cd1', 'SALARIO_BASE=200000,INSS_EMPREGADO=15000');
SELECT pg_temp.resultado('rd', 'cd2', 'SALARIO_BASE=100000,INSS_EMPREGADO=8000');
INSERT INTO saida VALUES ('rd', pg_temp.contabiliza('rd'));
SELECT is((SELECT pg_temp.sit(v) FROM saida WHERE k = 'rd') || ' ' || pg_temp.linhas(pg_temp.lote('rd', 'folha_mensal'))
          || ' ' || (SELECT o.payload->>'dimensionType' FROM folha.accounting_outbox o WHERE o.outbox_id = pg_temp.lote('rd', 'folha_mensal')),
  'contabilizada CUSTO.MAO_DE_OBRA@PROD D100000 | DESP.SALARIOS@ADM D200000 | PASS.INSS_RETIDO C23000 | PASS.SALARIOS_A_PAGAR C277000 centro_custo',
  'derivado: linhas de resultado agrupadas pelo centro de custo configurado (custo x despesa pelo mapeamento); passivo sem dimensão');
-- 11.2 Contrato sem a dimensão configurada: bloqueio, com a lista de contratos.
SELECT pg_temp.folha('rd2', 'ed', '2026-10-01', 'mensal', 2);
SELECT pg_temp.resultado('rd2', 'cd3', 'SALARIO_BASE=100000,INSS_EMPREGADO=8000');
INSERT INTO saida VALUES ('rd2', pg_temp.contabiliza('rd2'));
SELECT is(
  (SELECT (v::jsonb->>'situacao') || '/' || (v::jsonb->'pendencias'->0->>'codigo') || '/' || (v::jsonb->'pendencias'->0->'itens'->>'dimensao')
          || '/' || ((v::jsonb->'pendencias'->0->'itens'->'contratos'->>0) = pg_temp.id('cd3')::text)
     FROM saida WHERE k = 'rd2')
  || '/' || (SELECT count(*)::text FROM folha.accounting_outbox o WHERE o.run_id = pg_temp.id('rd2')),
  'bloqueada/dimensao_ausente/centro_custo/true/0',
  'derivado: contrato sem centro de custo, com a dimensão configurada, bloqueia o lote e diz qual contrato');
-- 11.3 Lotação, com rateio 40/60 e resíduo. cl: salário 100001, INSS 8000, líquido 92001;
--      patronal por lotação (memória de cálculo): 8000 na de 40% e 12000 na de 60%.
--      Rateio do salário: 40% de 100001 = 40000,4 -> 40000; a última lotação leva o resíduo:
--      100001 - 40000 = 60001. A soma das partes é o valor (sem linha de ajuste de centavos).
SELECT is(pg_temp.configura('el', 'lotacao', false, pg_temp.plano('el', ARRAY['folha'])), 'ok',
  'preparo: empregador el separa as linhas de resultado por lotação tributária');
SELECT pg_temp.folha('rl', 'el', '2026-10-01');
SELECT pg_temp.resultado('rl', 'cl', 'SALARIO_BASE=100001,INSS_EMPREGADO=8000', 'INSS_PATRONAL=8000@l40,INSS_PATRONAL=12000@l60');
SELECT is(pg_temp.sit(pg_temp.contabiliza('rl')) || ' ' || pg_temp.linhas(pg_temp.lote('rl', 'folha_mensal')),
  (SELECT 'contabilizada ' || string_agg(x.linha, ' | ' ORDER BY x.conta COLLATE "C", x.dim COLLATE "C")
     FROM (VALUES
       ('DESP.INSS_PATRONAL', pg_temp.id('el.l40')::text, 'DESP.INSS_PATRONAL@' || pg_temp.id('el.l40')::text || ' D8000'),
       ('DESP.INSS_PATRONAL', pg_temp.id('el.l60')::text, 'DESP.INSS_PATRONAL@' || pg_temp.id('el.l60')::text || ' D12000'),
       ('DESP.SALARIOS',      pg_temp.id('el.l40')::text, 'DESP.SALARIOS@' || pg_temp.id('el.l40')::text || ' D40000'),
       ('DESP.SALARIOS',      pg_temp.id('el.l60')::text, 'DESP.SALARIOS@' || pg_temp.id('el.l60')::text || ' D60001'),
       ('PASS.INSS_RETIDO',   '',                         'PASS.INSS_RETIDO C8000'),
       ('PASS.PREVIDENCIA',   '',                         'PASS.PREVIDENCIA C20000'),
       ('PASS.SALARIOS_A_PAGAR', '',                      'PASS.SALARIOS_A_PAGAR C92001')
     ) AS x(conta, dim, linha)),
  'derivado: rateio por lotação com resíduo na última (40000 + 60001 = 100001); encargos na lotação em que foram apurados');
SELECT is(pg_temp.total(pg_temp.lote('rl', 'folha_mensal')), '120001/120001', 'derivado: o lote rateado fecha em 120001');

-- ===========================================================================
-- 12. Reconciliação (E13) — derivado
--     Três empregados: 100000 + 200000 + 300000 = 600000 de proventos; INSS 8000 + 18000 +
--     30000 = 56000; líquido 544000; FGTS 8000 + 16000 + 24000 = 48000.
--     Com 2 eventos contábeis (lote e pagamento) e 3 do eSocial, a visão antiga somava
--     3 x 2 x 3 linhas por resultado: proventos 36000,00 em vez de 6000,00.
-- ===========================================================================
SELECT pg_temp.folha('rv', 'e1', '2026-09-01');
SELECT pg_temp.resultado('rv', 'c01', 'SALARIO_BASE=100000,INSS_EMPREGADO=8000,FGTS_DEPOSITO=8000');
SELECT pg_temp.resultado('rv', 'c02', 'SALARIO_BASE=200000,INSS_EMPREGADO=18000,FGTS_DEPOSITO=16000');
SELECT pg_temp.resultado('rv', 'c03', 'SALARIO_BASE=300000,INSS_EMPREGADO=30000,FGTS_DEPOSITO=24000');
SELECT is(pg_temp.sit(pg_temp.contabiliza('rv')) || '/' || pg_temp.paga('rv', 'pagamento_liquido', '2026-10-05', 'COMP-RV-1', 544000),
  'contabilizada/contabilizado', 'preparo: folha de três empregados contabilizada e líquido pago');
SET LOCAL session_replication_role = replica;
INSERT INTO folha.esocial_event_outbox (account_id, run_id, result_id, evento_codigo, competencia, payload, idempotency_key)
SELECT pr.account_id, pr.run_id, pr.result_id, 'S-1200', '2026-09-01', '{}', 'teste-' || pr.result_id
  FROM folha.payroll_result pr WHERE pr.run_id = pg_temp.id('rv');
SET LOCAL session_replication_role = origin;
SELECT is(
  (SELECT concat_ws('/', v.total_empregados, v.soma_proventos, v.soma_descontos, v.soma_liquido, v.soma_fgts,
                    v.eventos_contabeis_pendentes, v.eventos_esocial_pendentes, v.lotes_vigentes,
                    v.contabil_proventos_minor, v.contabil_descontos_minor, v.contabil_liquido_minor, v.contabil_fgts_minor, v.situacao)
     FROM folha.v_reconciliacao_contabil v WHERE v.run_id = pg_temp.id('rv')),
  '3/6000.00/560.00/5440.00/480.00/2/3/1/600000/56000/544000/48000/aguardando_confirmacao',
  'E13: somas sem multiplicação pelo join (6000,00, não 36000,00), e os valores do lote vigente ao lado dos da folha');
UPDATE folha.accounting_outbox SET status = 'despachado' WHERE outbox_id = pg_temp.lote('rv', 'folha_mensal');
UPDATE folha.accounting_outbox SET status = 'confirmado' WHERE outbox_id = pg_temp.lote('rv', 'folha_mensal');
SELECT is((SELECT v.situacao FROM folha.v_reconciliacao_contabil v WHERE v.run_id = pg_temp.id('rv')), 'conciliado',
  'regra V15: valores iguais e lote confirmado = conciliado');
SET LOCAL session_replication_role = replica;
UPDATE folha.payroll_result SET total_proventos = total_proventos + 0.01
 WHERE run_id = pg_temp.id('rv') AND contract_id = pg_temp.id('c01');
SET LOCAL session_replication_role = origin;
SELECT is((SELECT v.situacao FROM folha.v_reconciliacao_contabil v WHERE v.run_id = pg_temp.id('rv')), 'divergente',
  'regra V15: um centavo de diferença entre a folha e o lote aparece como divergente');
SELECT is((SELECT v.situacao FROM folha.v_reconciliacao_contabil v WHERE v.run_id = pg_temp.id('r08b')), 'sem_lote',
  'folha com resultado e sem lote aparece como sem_lote');

-- ===========================================================================
-- 13. Ponta a ponta com o motor (derivado): folha calculada, fechada e transmitida pelas
--     funções _v1; os itens e os encargos são os que o motor gravou.
-- ===========================================================================
CREATE FUNCTION pg_temp.fluxo_motor() RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v text;
  v_run uuid;
  v_sql text[];
BEGIN
  v := pg_temp.faz('a0000000-0000-0000-0000-000000000030', pg_temp.todas(), gen_random_uuid(),
         format('SELECT folha.folha_abrir_v1(''2026-10-01'', ''mensal'', ''2026-10-31'', %L)::text', pg_temp.id('em')));
  IF v LIKE 'ERRO%' THEN RAISE EXCEPTION 'fluxo_motor (abrir): %', v; END IF;
  v_run := v::uuid;
  INSERT INTO ids VALUES ('rm', v_run, 'a0000000-0000-0000-0000-000000000030', 'em');
  v := pg_temp.faz('a0000000-0000-0000-0000-000000000030', pg_temp.todas(), gen_random_uuid(),
         format('SELECT folha.folha_calcular_contrato_v1(%L, %L)', v_run, pg_temp.id('cm')),
         format('SELECT folha.folha_concluir_calculo_v1(%L)::text', v_run));
  IF v LIKE 'ERRO%' THEN RAISE EXCEPTION 'fluxo_motor (calcular): %', v; END IF;
  v_sql := ARRAY(SELECT format('SELECT folha.folha_liberar_pendencia_v1(%L, %L, ''conferido no teste'')', v_run, x.codigo)
                   FROM (SELECT DISTINCT p.codigo FROM folha.payroll_pendency p WHERE p.run_id = v_run) x);
  v_sql := v_sql || format('SELECT folha.folha_aprovar_v1(%L)', v_run) || format('SELECT folha.folha_fechar_v1(%L)::text', v_run);
  v := pg_temp.pedido('a0000000-0000-0000-0000-000000000030', pg_temp.todas(), gen_random_uuid(), true, false, v_sql);
  IF v LIKE 'ERRO%' THEN RAISE EXCEPTION 'fluxo_motor (fechar): %', v; END IF;
END $$;
SELECT pg_temp.fluxo_motor();
-- Sem configuração contábil: o eSocial sai, a contabilização fica bloqueada, com pendência.
CREATE FUNCTION pg_temp.transmite(p_run_k text) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.faz(pg_temp.conta_de(p_run_k), ARRAY['folha.read', 'folha.transmit'], '82000000-0000-0000-0000-000000000002',
    format('SELECT d.esocial_events_dispatched || ''/'' || d.contabil_events_dispatched FROM folha.folha_transmitir_v1(%L) d', pg_temp.id(p_run_k))) $$;
INSERT INTO saida VALUES ('rm-1', pg_temp.transmite('rm'));
SELECT is(
  (SELECT v FROM saida WHERE k = 'rm-1')
  || ' ' || (SELECT p.tipo || ':' || p.codigo FROM folha.contabil_pendencia p WHERE p.run_id = pg_temp.id('rm'))
  || ' ' || (SELECT count(*)::text FROM folha.accounting_outbox o WHERE o.run_id = pg_temp.id('rm')),
  '1/0 bloqueio:configuracao_ausente 0',
  'transmitir sem configuração contábil: o evento do eSocial sai, nenhum lote contábil entra na fila e fica a pendência de bloqueio');
SELECT is(pg_temp.configura('em', 'estabelecimento', false, pg_temp.plano('em', ARRAY['folha'])), 'ok',
  'preparo: configuração e plano do empregador em (dimensão: estabelecimento)');
SELECT is(pg_temp.transmite('rm'),
  '0/1', 'transmitir de novo, com o cadastro completo: nada novo no eSocial e um lote contábil');
-- A conta, a partir do que o motor gravou: débitos = proventos + FGTS (Simples com CPP no DAS:
-- sem patronal); créditos = descontos + líquido + FGTS.
SELECT is(
  (SELECT o.total_debito_minor::text || '/' || o.total_credito_minor::text || '/' || o.status || '/' || (o.payload->>'dimensionType')
     FROM folha.accounting_outbox o WHERE o.outbox_id = pg_temp.lote('rm', 'folha_mensal')),
  (SELECT round((r.total_proventos + f.fgts) * 100)::text || '/' || round((r.total_descontos + r.total_liquido + f.fgts) * 100)::text || '/pendente/estabelecimento'
     FROM folha.payroll_run r, (SELECT sum(pr.fgts) AS fgts FROM folha.payroll_result pr WHERE pr.run_id = pg_temp.id('rm')) f
    WHERE r.run_id = pg_temp.id('rm')),
  'derivado: o lote da folha calculada pelo motor fecha, com débitos = proventos + FGTS e créditos = descontos + líquido + FGTS');
SELECT is(
  (SELECT string_agg(DISTINCT COALESCE(e->>'dimensionKey', '-'), ',' ORDER BY COALESCE(e->>'dimensionKey', '-'))
     FROM folha.accounting_outbox o, jsonb_array_elements(o.payload->'entries') e
    WHERE o.outbox_id = pg_temp.lote('rm', 'folha_mensal') AND e->>'accountKey' LIKE 'DESP.%'),
  pg_temp.id('em.est')::text, 'derivado: as linhas de despesa levam o estabelecimento como dimensão');
SELECT is(
  (SELECT v.situacao FROM folha.v_reconciliacao_contabil v WHERE v.run_id = pg_temp.id('rm'))
  || ' ' || (SELECT (p.resolvida_em IS NOT NULL)::text FROM folha.contabil_pendencia p WHERE p.run_id = pg_temp.id('rm')),
  'aguardando_confirmacao true', 'derivado: folha e lote conferem por valor, e a pendência de bloqueio foi resolvida');
INSERT INTO saida VALUES ('rm-3', pg_temp.transmite('rm'));
SELECT is(
  (SELECT v FROM saida WHERE k = 'rm-3')
  || ' ' || (SELECT a.detalhe->>'contabil_situacao' FROM folha.auditoria a
              WHERE a.recurso_id = pg_temp.id('rm') AND a.acao = 'transmitir_folha' ORDER BY a.auditoria_id DESC LIMIT 1),
  '0/0 inalterada', 'transmitir uma terceira vez: 0/0, e a auditoria registra que a contabilização ficou inalterada');

-- ===========================================================================
-- 14. Permissão de cada função e isolamento entre contas
-- ===========================================================================
CREATE TEMP TABLE exige (chamada text PRIMARY KEY, permissao text NOT NULL);
INSERT INTO exige VALUES
  ('SELECT folha.contabil_config_definir_v1(gen_random_uuid(), ''nenhuma'', ''data_original'', false)', 'folha.admin'),
  ('SELECT folha.contabil_mapa_definir_v1(gen_random_uuid(), ''LIQUIDO'', ''liquido'', ''passivo'', ''X'', ''2024-01-01'', true)', 'folha.admin'),
  ('SELECT folha.contabil_mapa_encerrar_v1(gen_random_uuid(), NULL, false)', 'folha.admin'),
  ('SELECT folha.contabil_contrato_dimensao_definir_v1(gen_random_uuid(), ''ADM'', NULL, ''2024-01-01'')', 'folha.admin'),
  ('SELECT folha.contabil_folha_contabilizar_v1(gen_random_uuid())', 'folha.transmit'),
  ('SELECT folha.contabil_provisao_direito_informar_v1(gen_random_uuid(), ''2026-10-01'', 1000, 1, 1)', 'folha.calculate'),
  ('SELECT folha.contabil_provisao_constituir_v1(gen_random_uuid(), ''2026-10-01'')', 'folha.transmit'),
  ('SELECT folha.contabil_pagamento_registrar_v1(gen_random_uuid(), ''pagamento_liquido'', ''2026-11-05'', ''C1'', 1)', 'folha.transmit'),
  ('SELECT folha.contabil_pendencia_liberar_v1(gen_random_uuid(), ''motivo'')', 'folha.close'),
  ('SELECT folha.contabil_situacao_v1(gen_random_uuid())', 'folha.read');
SELECT matches(
  pg_temp.le(:A, array_remove(pg_temp.todas(), x.permissao), :S_TX, x.chamada),
  '^ERRO 42501: ', 'NEG: sem ' || x.permissao || ' (com as outras quatro), recusa: ' || split_part(split_part(x.chamada, '(', 1), '.', 2))
  FROM exige x ORDER BY x.chamada;
SELECT is_empty(
  $$SELECT x.chamada FROM exige x
     WHERE pg_temp.le('a0000000-0000-0000-0000-000000000030', pg_temp.todas(), '82000000-0000-0000-0000-000000000002', x.chamada) LIKE 'ERRO 42501%'$$,
  'âncora: com as cinco permissões nenhuma das dez recusa por permissão (o erro passa a ser o do identificador inexistente)');
SELECT matches(
  pg_temp.le(:A, NULL, :S_TX, format('SELECT folha.contabil_folha_contabilizar_v1(%L)', pg_temp.id('r01'))),
  '^ERRO 42501: ', 'NEG: sem contexto aberto, a sessão de aplicação não contabiliza');

-- Conta B não alcança nada da conta A (com todas as permissões, na conta dela).
SELECT matches(pg_temp.le(:B, pg_temp.todas(), :S_B, x.sql), x.esperado, 'conta B não ' || x.caso || ' da conta A')
  FROM (VALUES
    ('contabiliza folha', format('SELECT folha.contabil_folha_contabilizar_v1(%L)', pg_temp.id('r02')), '^ERRO P0001: Folha .* não encontrada$'),
    ('consulta a situação contábil de folha', format('SELECT folha.contabil_situacao_v1(%L)', pg_temp.id('r02')), '^ERRO P0001: Folha .* não encontrada$'),
    ('registra pagamento em folha', format('SELECT folha.contabil_pagamento_registrar_v1(%L, ''pagamento_liquido'', ''2026-11-05'', ''B-1'', 1)', pg_temp.id('r02')), '^ERRO P0001: Folha .* não encontrada$'),
    ('libera pendência', format('SELECT folha.contabil_pendencia_liberar_v1(%L, ''motivo'')', (SELECT p.pendencia_id FROM folha.contabil_pendencia p WHERE p.outbox_id = pg_temp.lote('rr3', 'rescisao'))), '^ERRO P0001: Pendência .* não encontrada$'),
    ('configura empregador', format('SELECT folha.contabil_config_definir_v1(%L, ''nenhuma'', ''data_original'', false)', pg_temp.id('e1')), '^ERRO P0001: Empregador .* não encontrado$'),
    ('mapeia conta em empregador', pg_temp.m('e1', 'HE_100', 'provento', 'despesa', 'DESP.DE-B'), '^ERRO P0001: Empregador .* não encontrado$'),
    ('encerra linha de mapeamento', format('SELECT folha.contabil_mapa_encerrar_v1(%L, NULL, false)', (SELECT m.mapa_id FROM folha.contabil_mapa m WHERE m.employer_id = pg_temp.id('e1') AND m.chave = 'LIQUIDO')), '^ERRO P0001: Linha de mapeamento .* não encontrada$'),
    ('define centro de custo de contrato', format('SELECT folha.contabil_contrato_dimensao_definir_v1(%L, ''X'', NULL, ''2026-01-01'')', pg_temp.id('c01')), '^ERRO P0001: Contrato .* não encontrado$'),
    ('informa direito de provisão de contrato', format('SELECT folha.contabil_provisao_direito_informar_v1(%L, ''2026-10-01'', 1000, 1, 1)', pg_temp.id('c01')), '^ERRO P0001: Contrato .* não encontrado$'),
    ('constitui provisão de empregador', format('SELECT folha.contabil_provisao_constituir_v1(%L, ''2027-01-01'')', pg_temp.id('e3')), '^ERRO P0001: Empregador .* não encontrado$')
  ) AS x(caso, sql, esperado);
-- Com os privilégios do worker (leitura das tabelas), a RLS separa as contas.
SELECT is(pg_temp.configura('eb', 'nenhuma', false, pg_temp.plano('eb', ARRAY['folha'])), 'ok', 'preparo: a conta B configura o próprio empregador');
SELECT pg_temp.folha('rb', 'eb', '2026-10-01');
SELECT pg_temp.resultado('rb', 'cb', 'SALARIO_BASE=300000,INSS_EMPREGADO=25000,FGTS_DEPOSITO=24000');
SELECT is(pg_temp.sit(pg_temp.contabiliza('rb')) || '/' || pg_temp.total(pg_temp.lote('rb', 'folha_mensal')), 'contabilizada/324000/324000',
  'a conta B contabiliza a própria folha');
-- A policy das tabelas novas é dos papéis worker e data_owner. Exercida com o papel de reserva
-- de CI (dnex_folha_ci, membro do worker, conta por parâmetro de sessão), em subtransação.
CREATE FUNCTION pg_temp.reserva(p_conta uuid, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v_saida text;
BEGIN
  BEGIN
    PERFORM set_config('folha.account_id', COALESCE(p_conta::text, ''), true);
    SET LOCAL ROLE dnex_folha_ci;
    EXECUTE p_sql INTO v_saida;
    RAISE EXCEPTION 'desfaz' USING ERRCODE = 'ZZ001';
  EXCEPTION
    WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_saida := 'ERRO ' || SQLSTATE || ': ' || SQLERRM;
  END;
  RETURN v_saida;
END
$$;
CREATE FUNCTION pg_temp.contagens(p_outra uuid) RETURNS text LANGUAGE sql AS $$
  SELECT format($q$SELECT concat_ws('/',
        (SELECT count(*) FROM folha.contabil_mapa WHERE account_id = %1$L),
        (SELECT count(*) FROM folha.contabil_config WHERE account_id = %1$L),
        (SELECT count(*) FROM folha.accounting_outbox WHERE account_id = %1$L),
        (SELECT count(*) FROM folha.contabil_pendencia WHERE account_id = %1$L),
        (SELECT count(*) FROM folha.provision_ledger WHERE account_id = %1$L),
        (SELECT count(*) FROM folha.provision_entitlement WHERE account_id = %1$L),
        (SELECT count(*) FROM folha.contract_cost_assignment WHERE account_id = %1$L),
        (SELECT count(*) FROM folha.v_reconciliacao_contabil WHERE account_id = %1$L),
        (SELECT count(*) FROM folha.contabil_mapa),
        (SELECT count(*) FROM folha.accounting_outbox),
        (SELECT count(*) FROM folha.v_reconciliacao_contabil))$q$, p_outra) $$;
SELECT is(pg_temp.reserva(:B, pg_temp.contagens(:A)), '0/0/0/0/0/0/0/0/17/1/1',
  'isolamento (RLS, membro do worker): a conta B lê só o que é dela (17 linhas de mapeamento, 1 lote, 1 folha na reconciliação) e nada da conta A');
SELECT matches(pg_temp.reserva(:A, pg_temp.contagens(:B)), '^0/0/0/0/0/0/0/0/[1-9][0-9]*/[1-9][0-9]*/[1-9][0-9]*$',
  'isolamento (RLS, membro do worker): a conta A lê o que é dela e nada da conta B (a visão de reconciliação agora respeita a RLS)');
SELECT is(pg_temp.reserva(NULL, pg_temp.contagens(:A)), '0/0/0/0/0/0/0/0/0/0/0',
  'sem conta na sessão, o membro do worker não lê linha nenhuma');
SELECT is(
  pg_temp.com_espelho(:A, pg_temp.todas(), :S_TX,
    $$SELECT concat_ws('/', (SELECT count(*) FROM folha.contabil_mapa), (SELECT count(*) FROM folha.provision_ledger),
                       (SELECT count(*) FROM folha.contabil_pendencia))$$),
  '0/0/0', 'quem só tem os GRANTs (sem ser o papel da policy) não lê as tabelas novas, nem com contexto');

SELECT * FROM finish();
ROLLBACK;
