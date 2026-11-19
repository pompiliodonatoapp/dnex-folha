-- DNEX Folha — Testes pgTAP da migration 0031: fila de eventos do eSocial no banco.
--
-- Cobre: catálogo e antecessores (estrutura e conteúdo), máquina de estados (caminhos válidos e
-- inválidos), antecessores não validados, idempotência e versões, folha aberta recusada, lote,
-- retornos (recibo, ocorrências, advertência, duplicado, falha de comunicação, lote incorreto),
-- retificação (exige recibo), exclusão (S-3000), reabertura e fechamento por ciclo, imutabilidade,
-- liberação de produção, isolamento entre contas, ACL exata, permissões por função, subject
-- gravado, plano de DESFAZER em ordem (cenários com vários eventos) e a visão de conferência.
-- NÃO gera XML: o conteúdo dos eventos aqui é um texto qualquer, só para exercer o armazenamento
-- e o hash. Nomes, CPFs e inscrições são fictícios. Nada é persistido (ROLLBACK no final).
--
-- Como o arquivo roda: superusuário no nível de cima. O que vale "para uma sessão de aplicação"
-- passa por pg_temp.pedido() (igual ao dos arquivos 0028, 0029 e 0030: asserção com claim da Folha
-- pelo caminho real, login de teste membro só de dnex_gestao_api e begin_request). Devolve o
-- resultado do último comando como texto, ou 'ERRO <sqlstate>: <mensagem>'.
BEGIN;

SELECT plan(429);

\set A '''a0000000-0000-0000-0000-000000000031'''
\set B '''b0000000-0000-0000-0000-000000000031'''
\set S_ADMIN '''81000000-0000-0000-0000-000000000031'''
\set S_TX    '''82000000-0000-0000-0000-000000000031'''
\set S_CLOSE '''83000000-0000-0000-0000-000000000031'''
\set S_B     '''84000000-0000-0000-0000-000000000031'''

-- ---------------------------------------------------------------------------
-- Apoio
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE escopo (conta uuid PRIMARY KEY, entidade uuid NOT NULL, filial uuid NOT NULL);
INSERT INTO escopo VALUES
  (:A, 'a1000000-0000-0000-0000-000000000031', 'a2000000-0000-0000-0000-000000000031'),
  (:B, 'b1000000-0000-0000-0000-000000000031', 'b2000000-0000-0000-0000-000000000031');
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

-- Atalhos por conta e papel: tx = transmit (S_TX); fecha = transmit + close (S_CLOSE); adm = admin (S_ADMIN);
-- lei = só leitura, sem persistir.
CREATE FUNCTION pg_temp.ca() RETURNS uuid LANGUAGE sql AS $$ SELECT 'a0000000-0000-0000-0000-000000000031'::uuid $$;
CREATE FUNCTION pg_temp.cb() RETURNS uuid LANGUAGE sql AS $$ SELECT 'b0000000-0000-0000-0000-000000000031'::uuid $$;
CREATE FUNCTION pg_temp.tx_a(p_sql text) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.faz(pg_temp.ca(), pg_temp.todas(), '82000000-0000-0000-0000-000000000031'::uuid, p_sql) $$;
CREATE FUNCTION pg_temp.fecha_a(p_sql text) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.faz(pg_temp.ca(), pg_temp.todas(), '83000000-0000-0000-0000-000000000031'::uuid, p_sql) $$;
CREATE FUNCTION pg_temp.adm_a(p_sql text) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.faz(pg_temp.ca(), pg_temp.todas(), '81000000-0000-0000-0000-000000000031'::uuid, p_sql) $$;
CREATE FUNCTION pg_temp.lei_a(p_sql text) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.le(pg_temp.ca(), pg_temp.todas(), '82000000-0000-0000-0000-000000000031'::uuid, p_sql) $$;
CREATE FUNCTION pg_temp.tx_b(p_sql text) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.faz(pg_temp.cb(), pg_temp.todas(), '84000000-0000-0000-0000-000000000031'::uuid, p_sql) $$;
CREATE FUNCTION pg_temp.lei_b(p_sql text) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.le(pg_temp.cb(), pg_temp.todas(), '84000000-0000-0000-0000-000000000031'::uuid, p_sql) $$;

-- Identificadores do cenário, por nome. Nome desconhecido é erro (não devolve nulo).
CREATE TEMP TABLE ids (k text PRIMARY KEY, id uuid NOT NULL, conta uuid NOT NULL, pai text);
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
CREATE FUNCTION pg_temp.h(p text) RETURNS text LANGUAGE sql AS $$ SELECT encode(sha256(convert_to(p, 'UTF8')), 'hex') $$;
CREATE FUNCTION pg_temp.est(p_k text) RETURNS text LANGUAGE sql AS $$
  SELECT estado FROM folha.esocial_event WHERE event_id = pg_temp.id(p_k) $$;
CREATE FUNCTION pg_temp.ok_(p_res text, p_desc text) RETURNS text LANGUAGE sql AS $$
  SELECT ok(p_res IS NOT NULL AND p_res NOT LIKE 'ERRO%', p_desc || CASE WHEN p_res LIKE 'ERRO%' THEN ' [' || left(p_res, 160) || ']' ELSE '' END) $$;

-- Empregador com estabelecimento e lotação; contrato com trabalhador novo (como nos arquivos 0028 a 0030)
CREATE TEMP SEQUENCE seq_n START 31000000001;
CREATE FUNCTION pg_temp.empregador(p_k text, p_account uuid) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  v_n bigint := nextval('seq_n');
  v_emp uuid; v_est uuid; v_lot uuid;
BEGIN
  INSERT INTO folha.employer (account_id, tipo_inscricao, inscricao, razao_social)
  VALUES (p_account, 'cnpj', left(v_n::text, 8) || right(v_n::text, 3), 'Empresa Ficticia ' || p_k)
  RETURNING employer_id INTO v_emp;
  INSERT INTO folha.employer_regime (account_id, employer_id, vigencia_inicio, regime_tributario)
  VALUES (p_account, v_emp, '2024-01-01', 'lucro_presumido');
  INSERT INTO folha.establishment (account_id, employer_id, tipo_inscricao, inscricao, cnae_preponderante)
  VALUES (p_account, v_emp, 'cnpj', v_n::text || '000', '0000000') RETURNING establishment_id INTO v_est;
  INSERT INTO folha.tax_allocation (account_id, employer_id, establishment_id, codigo_lotacao, tipo_lotacao)
  VALUES (p_account, v_emp, v_est, 'L-' || p_k, 'teste') RETURNING allocation_id INTO v_lot;
  INSERT INTO ids VALUES (p_k, v_emp, p_account, NULL), (p_k || '.est', v_est, p_account, p_k), (p_k || '.lot', v_lot, p_account, p_k);
END $$;
CREATE FUNCTION pg_temp.contrato(p_k text, p_emp_k text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  v_n bigint := nextval('seq_n');
  v_acc uuid := pg_temp.conta_de(p_emp_k);
  v_trab uuid; v_cid uuid;
BEGIN
  INSERT INTO folha.employee (account_id, cpf, nome_completo, data_nascimento)
  VALUES (v_acc, v_n::text, 'Ficticio ' || p_k, '1990-01-01') RETURNING employee_id INTO v_trab;
  INSERT INTO folha.employment_contract (account_id, employee_id, data_admissao, cargo, salario_base,
                                         regime_trabalho, employer_id, establishment_id)
  VALUES (v_acc, v_trab, '2023-01-01', 'Cargo ' || p_k, 3000.00, 'clt', pg_temp.id(p_emp_k), pg_temp.id(p_emp_k || '.est'))
  RETURNING contract_id INTO v_cid;
  INSERT INTO ids VALUES (p_k, v_cid, v_acc, p_emp_k), (p_k || '.trab', v_trab, v_acc, p_emp_k);
END $$;

-- Folha gravada direto (gatilhos desligados, como nos arquivos 0029 e 0030), com um resultado por contrato.
CREATE FUNCTION pg_temp.folha(p_k text, p_emp_k text, p_comp date, p_status text, p_contratos text[],
                              p_pgto date DEFAULT NULL, p_seq integer DEFAULT 1) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  v_run uuid;
  v_acc uuid := pg_temp.conta_de(p_emp_k);
  v_c text;
BEGIN
  PERFORM set_config('session_replication_role', 'replica', true);
  INSERT INTO folha.payroll_run (account_id, competencia, status, tipo_processo, sequencia, employer_id, data_pagamento, fechado_em)
  VALUES (v_acc, p_comp, p_status, 'mensal', p_seq, CASE WHEN p_emp_k IS NULL THEN NULL ELSE pg_temp.id(p_emp_k) END,
          COALESCE(p_pgto, (p_comp + interval '1 month' - interval '1 day')::date), CASE WHEN p_status = 'closed' THEN now() END)
  RETURNING run_id INTO v_run;
  FOREACH v_c IN ARRAY p_contratos LOOP
    INSERT INTO folha.payroll_result (run_id, account_id, employee_id, contract_id, total_proventos, total_descontos, liquido,
                                      inss_empregado, irrf, fgts, inss_patronal, rat, terceiros, calculation_hash)
    SELECT v_run, v_acc, k.employee_id, k.contract_id, 3000, 300, 2700, 270, 30, 240, 600, 60, 174, 'caso-de-teste'
      FROM folha.employment_contract k WHERE k.contract_id = pg_temp.id(v_c);
  END LOOP;
  PERFORM set_config('session_replication_role', 'origin', true);
  INSERT INTO ids VALUES (p_k, v_run, v_acc, p_emp_k);
END $$;
CREATE FUNCTION pg_temp.origem(p_run_k text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_array(jsonb_build_object('run_id', pg_temp.id(p_run_k))) $$;

-- Operações da fila (guardam o resultado em saida e o id em ids)
CREATE FUNCTION pg_temp.enf(p_k text, p_emp_k text, p_cod text, p_amb text, p_hash text,
                            p_ref jsonb DEFAULT '{}'::jsonb, p_origens jsonb DEFAULT '[]'::jsonb) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  v := pg_temp.tx_a(format('SELECT folha.esocial_evento_enfileirar_v1(%L::uuid, %L, %L, %L, %L::jsonb, %L::jsonb)::text',
         pg_temp.id(p_emp_k), p_cod, p_amb, pg_temp.h(p_hash), p_ref::text, p_origens::text));
  INSERT INTO saida VALUES (p_k, v) ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v;
  IF v NOT LIKE 'ERRO%' THEN
    INSERT INTO ids VALUES (p_k, (v::jsonb->>'event_id')::uuid, pg_temp.ca(), p_emp_k) ON CONFLICT (k) DO UPDATE SET id = EXCLUDED.id;
  END IF;
  RETURN v;
END $$;
CREATE FUNCTION pg_temp.passo(p_k text, p_para text, p_xml text DEFAULT NULL) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.tx_a(format('SELECT folha.esocial_evento_avancar_v1(%L::uuid, %L, %L)::text', pg_temp.id(p_k), p_para, p_xml)) $$;
CREATE FUNCTION pg_temp.ate_assinado(p_k text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  v := pg_temp.passo(p_k, 'pendente_interno');
  IF v LIKE 'ERRO%' THEN RETURN v; END IF;
  v := pg_temp.passo(p_k, 'gerado', format('<evt id="%s"><dado>x</dado></evt>', p_k));
  IF v LIKE 'ERRO%' THEN RETURN v; END IF;
  RETURN pg_temp.passo(p_k, 'assinado', format('<evt id="%s"><dado>x</dado><Signature/></evt>', p_k));
END $$;
-- Envia um lote com os eventos (do empregador e ambiente do primeiro)
CREATE FUNCTION pg_temp.lote(p_lote_k text, VARIADIC p_ks text[]) RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v text;
  v_emp uuid; v_amb text;
BEGIN
  SELECT e.employer_id, e.ambiente INTO v_emp, v_amb FROM folha.esocial_event e WHERE e.event_id = pg_temp.id(p_ks[1]);
  v := pg_temp.tx_a(format('SELECT folha.esocial_lote_enviar_v1(%L::uuid, %L, %L::uuid[])::text', v_emp, v_amb,
         (SELECT array_agg(pg_temp.id(k)) FROM unnest(p_ks) AS k)::text));
  IF v NOT LIKE 'ERRO%' THEN
    INSERT INTO ids VALUES (p_lote_k, (v::jsonb->>'lot_id')::uuid, pg_temp.ca(), NULL) ON CONFLICT (k) DO UPDATE SET id = EXCLUDED.id;
  END IF;
  RETURN v;
END $$;
CREATE FUNCTION pg_temp.retorno(p_lote_k text, p_tipo text, p_protocolo text DEFAULT NULL, p_codigo text DEFAULT NULL,
                                p_ocorr jsonb DEFAULT '[]'::jsonb, p_eventos jsonb DEFAULT '[]'::jsonb, p_xml text DEFAULT NULL) RETURNS text
LANGUAGE sql AS $$
  SELECT pg_temp.tx_a(format('SELECT folha.esocial_lote_retorno_v1(%L::uuid, %L, %L, %L, %L, %L::jsonb, %L::jsonb)::text',
           pg_temp.id(p_lote_k), p_tipo, p_protocolo, p_codigo, p_xml, p_ocorr::text, p_eventos::text)) $$;
CREATE FUNCTION pg_temp.res(p_k text, p_resultado text, p_recibo text DEFAULT NULL, p_ocorr jsonb DEFAULT '[]'::jsonb, p_xml text DEFAULT NULL) RETURNS jsonb
LANGUAGE sql AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object('event_id', pg_temp.id(p_k), 'resultado', p_resultado, 'recibo', p_recibo,
                                              'ocorrencias', p_ocorr, 'retorno_xml', p_xml)) $$;
-- Do rascunho ao validado com recibo, num lote só dele
CREATE FUNCTION pg_temp.validar(p_k text, p_recibo text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v text;
  v_l text := p_k || '.lote';
BEGIN
  v := pg_temp.ate_assinado(p_k);
  IF v LIKE 'ERRO%' THEN RETURN 'ERRO(ate_assinado) ' || v; END IF;
  v := pg_temp.lote(v_l, p_k);
  IF v LIKE 'ERRO%' THEN RETURN 'ERRO(lote) ' || v; END IF;
  v := pg_temp.retorno(v_l, 'recebido', 'PROT-' || v_l, '201');
  IF v LIKE 'ERRO%' THEN RETURN 'ERRO(recebido) ' || v; END IF;
  RETURN pg_temp.retorno(v_l, 'processado', NULL, NULL, '[]'::jsonb, jsonb_build_array(pg_temp.res(p_k, 'validado', p_recibo)));
END $$;
CREATE FUNCTION pg_temp.retif(p_k text, p_orig_k text, p_hash text, p_motivo text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  v := pg_temp.fecha_a(format('SELECT folha.esocial_evento_retificar_v1(%L::uuid, %L, %L)::text', pg_temp.id(p_orig_k), pg_temp.h(p_hash), p_motivo));
  INSERT INTO saida VALUES (p_k, v) ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v;
  IF v NOT LIKE 'ERRO%' THEN
    INSERT INTO ids VALUES (p_k, (v::jsonb->>'event_id')::uuid, pg_temp.ca(), NULL) ON CONFLICT (k) DO UPDATE SET id = EXCLUDED.id;
  END IF;
  RETURN v;
END $$;
CREATE FUNCTION pg_temp.excl(p_k text, p_alvo_k text, p_motivo text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  v := pg_temp.fecha_a(format('SELECT folha.esocial_evento_excluir_v1(%L::uuid, %L)::text', pg_temp.id(p_alvo_k), p_motivo));
  INSERT INTO saida VALUES (p_k, v) ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v;
  IF v NOT LIKE 'ERRO%' THEN
    INSERT INTO ids VALUES (p_k, (v::jsonb->>'event_id')::uuid, pg_temp.ca(), NULL) ON CONFLICT (k) DO UPDATE SET id = EXCLUDED.id;
  END IF;
  RETURN v;
END $$;
-- Plano de desfazer: o json em texto
CREATE FUNCTION pg_temp.plano_periodo(p_emp_k text, p_periodo date, p_amb text DEFAULT 'producao_restrita') RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.lei_a(format('SELECT folha.esocial_desfazer_plano_v1(%L::uuid, %L, %L::date, 1::smallint, NULL)::text', pg_temp.id(p_emp_k), p_amb, p_periodo)) $$;
CREATE FUNCTION pg_temp.plano_evento(p_emp_k text, p_ev_k text, p_amb text DEFAULT 'producao_restrita') RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.lei_a(format('SELECT folha.esocial_desfazer_plano_v1(%L::uuid, %L, NULL, 1::smallint, %L::uuid)::text', pg_temp.id(p_emp_k), p_amb, pg_temp.id(p_ev_k))) $$;
-- Sequência de eventos do plano (código@acao), na ordem
CREATE FUNCTION pg_temp.seq_plano(p_json text) RETURNS text LANGUAGE sql AS $$
  SELECT string_agg(p->>'evento_codigo' || '@' || (p->>'acao'), ' > ' ORDER BY (p->>'ordem')::int)
    FROM jsonb_array_elements(p_json::jsonb->'passos') p $$;

-- ===========================================================================
-- 1. Catálogo, antecessores, estados e estrutura (nada semeado por conta)
-- ===========================================================================
SELECT is((SELECT count(*) FROM folha.esocial_event_catalog), 28::bigint, 'catálogo: 28 eventos semeados (só o que o parecer sustenta)');
SELECT is(
  (SELECT string_agg(evento_codigo, ',' ORDER BY evento_codigo COLLATE "C") FROM folha.esocial_event_catalog),
  'S-1000,S-1005,S-1010,S-1020,S-1070,S-1200,S-1210,S-1298,S-1299,S-2190,S-2200,S-2205,S-2206,S-2210,S-2220,S-2230,S-2240,S-2299,S-2300,S-2306,S-2399,S-3000,S-5001,S-5002,S-5003,S-5011,S-5012,S-5013',
  'catálogo: a lista exata de códigos (sem S-1260 e S-1270, que os insumos não sustentam)');
SELECT is(
  (SELECT string_agg(grupo || '=' || n, ' ' ORDER BY grupo COLLATE "C") FROM (SELECT grupo, count(*) AS n FROM folha.esocial_event_catalog GROUP BY grupo) g),
  'exclusao=1 nao_periodicos=9 periodicos=4 sst=3 tabelas=5 totalizadores=6',
  'catálogo: os seis grupos (tabelas, não periódicos, periódicos, SST, exclusão, totalizadores)');
SELECT is(
  (SELECT string_agg(evento_codigo, ',' ORDER BY evento_codigo COLLATE "C") FROM folha.esocial_event_catalog WHERE status_validacao = 'a_validar'),
  'S-2190,S-2205,S-2210,S-2220,S-2240,S-2300,S-2306,S-2399',
  'catálogo: o que o parecer não fixa fica a_validar (chave de S-2190/S-2205/SST e TSVE)');
SELECT is(
  (SELECT string_agg(evento_codigo, ',' ORDER BY evento_codigo COLLATE "C") FROM folha.esocial_event_catalog WHERE NOT habilitado),
  'S-5001,S-5002,S-5003,S-5011,S-5012,S-5013',
  'catálogo: só os retornos do governo (totalizadores) não são enfileiráveis');
SELECT is((SELECT count(*) FROM folha.esocial_event_antecessor), 37::bigint, 'antecessores: 37 regras semeadas');
SELECT is((SELECT count(*) FROM folha.esocial_event_antecessor WHERE status_validacao = 'a_validar'), 14::bigint,
  'antecessores: 14 regras a_validar (aplicadas, mas marcadas)');
SELECT is(
  (SELECT string_agg(evento_codigo || '<-' || antecessor_codigo, ',' ORDER BY evento_codigo COLLATE "C", antecessor_codigo COLLATE "C")
     FROM folha.esocial_event_antecessor WHERE evento_codigo IN ('S-1200', 'S-1210', 'S-1299', 'S-2299')),
  'S-1200<-S-1005,S-1200<-S-1010,S-1200<-S-1020,S-1200<-S-2200,S-1200<-S-2300,S-1210<-S-1200,S-1210<-S-2299,S-1299<-S-1000,S-1299<-S-1200,S-1299<-S-1210,S-2299<-S-2200,S-2299<-S-2230',
  'antecessores: a cadeia principal S-2200/S-2300 -> S-1200 -> S-1210 -> S-1299 e S-2299');
SELECT is_empty(
  $$WITH RECURSIVE cam AS (
      SELECT a.evento_codigo AS de, a.antecessor_codigo AS para, ARRAY[a.evento_codigo] AS trilha, false AS fechou
        FROM folha.esocial_event_antecessor a
      UNION ALL
      SELECT c.de, a.antecessor_codigo, c.trilha || a.evento_codigo, a.antecessor_codigo = c.de
        FROM cam c JOIN folha.esocial_event_antecessor a ON a.evento_codigo = c.para
       WHERE NOT c.fechou AND NOT a.evento_codigo = ANY (c.trilha))
    SELECT de FROM cam WHERE fechou$$,
  'antecessores: o grafo não tem ciclo');
SELECT is((SELECT count(*) FROM folha.esocial_event_state), 13::bigint, 'estados: os 13 estados do evento');
SELECT is(
  (SELECT string_agg(de || '>' || para, ',' ORDER BY de COLLATE "C", para COLLATE "C") FROM folha.esocial_event_transition),
  'assinado>cancelado,assinado>enviado,em_processamento>duplicado,em_processamento>rejeitado,em_processamento>validado,enviado>em_processamento,enviado>falha_comunicacao,enviado>rejeitado,falha_comunicacao>assinado,gerado>assinado,gerado>cancelado,pendente_interno>cancelado,pendente_interno>gerado,pendente_interno>rascunho,rascunho>cancelado,rascunho>pendente_interno,validado>excluido,validado>retificado',
  'máquina de estados: exatamente as 18 transições válidas (todas as outras são recusadas)');
SELECT is_empty(
  $$SELECT t.de || '>' || t.para FROM folha.esocial_event_transition t JOIN folha.esocial_event_state s ON s.estado = t.de WHERE s.terminal$$,
  'máquina de estados: nenhuma transição sai de estado terminal');
SELECT is_empty(
  $$SELECT t.de || '>' || t.para FROM folha.esocial_event_transition t
     WHERE t.para IN ('gerado', 'assinado') AND t.de NOT IN ('pendente_interno', 'gerado', 'falha_comunicacao')$$,
  'máquina de estados: nada chega a gerado ou assinado sem passar pelo estado anterior (sem pulo)');
SELECT is((SELECT count(*) FROM folha.esocial_rejection_catalog), 0::bigint,
  'catálogo de rejeições: só a estrutura, nenhuma linha semeada (os códigos ficam para a fatia de validação preventiva)');
SELECT is(
  (SELECT string_agg(column_name, ',' ORDER BY ordinal_position) FROM information_schema.columns
    WHERE table_schema = 'folha' AND table_name = 'esocial_rejection_catalog' AND column_name <> 'created_at'),
  'rejeicao_codigo,classe,causa,correcao,fonte,status_validacao',
  'catálogo de rejeições: colunas código, classe, causa, correção, fonte e status de validação');
SELECT is(
  (SELECT count(*) FROM (SELECT 1 FROM folha.esocial_event UNION ALL SELECT 1 FROM folha.esocial_lot UNION ALL SELECT 1 FROM folha.esocial_event_payload
                         UNION ALL SELECT 1 FROM folha.esocial_event_occurrence UNION ALL SELECT 1 FROM folha.esocial_event_origin
                         UNION ALL SELECT 1 FROM folha.esocial_employer_setting UNION ALL SELECT 1 FROM folha.esocial_lot_event) x),
  0::bigint, 'nenhum seed ativo por conta: eventos, lotes, conteúdo, ocorrências, origens, liberações e participações nascem vazios');

-- ===========================================================================
-- 2. ACL exata, RLS e FKs
-- ===========================================================================
CREATE TEMP TABLE acl (sig text PRIMARY KEY, papeis text[] NOT NULL, definer boolean NOT NULL);
INSERT INTO acl VALUES
  ('folha.esocial_producao_definir_v1(uuid,boolean,text)',                 ARRAY['dnex_gestao_api'], true),
  ('folha.esocial_evento_enfileirar_v1(uuid,text,text,text,jsonb,jsonb)',  ARRAY['dnex_gestao_api'], true),
  ('folha.esocial_evento_avancar_v1(uuid,text,text)',                      ARRAY['dnex_gestao_api'], true),
  ('folha.esocial_evento_cancelar_v1(uuid,text)',                          ARRAY['dnex_gestao_api'], true),
  ('folha.esocial_lote_enviar_v1(uuid,text,uuid[])',                       ARRAY['dnex_gestao_api'], true),
  ('folha.esocial_lote_retorno_v1(uuid,text,text,text,text,jsonb,jsonb)',  ARRAY['dnex_gestao_api'], true),
  ('folha.esocial_evento_retificar_v1(uuid,text,text,jsonb)',              ARRAY['dnex_gestao_api'], true),
  ('folha.esocial_evento_excluir_v1(uuid,text)',                           ARRAY['dnex_gestao_api'], true),
  ('folha.esocial_desfazer_plano_v1(uuid,text,date,smallint,uuid)',        ARRAY['dnex_gestao_api'], true),
  ('folha.esocial_conferencia_v1(uuid,date,text)',                         ARRAY['dnex_gestao_api'], true),
  ('folha.esocial_bloqueio_antecessor(uuid)',                              ARRAY['dnex_gestao_data_owner', 'dnex_gestao_folha_worker'], true),
  ('folha.esocial_auditar(jsonb,text,text,uuid,jsonb)',                    ARRAY[]::text[], true),
  ('folha.esocial_chave_texto(text,text,date,uuid,uuid,date,smallint,date,integer,uuid)', ARRAY[]::text[], false),
  ('folha.esocial_escopo_casa(text,folha.esocial_event,folha.esocial_event)', ARRAY[]::text[], false),
  ('folha.esocial_periodo_fechado(uuid,uuid,text,smallint,date)',          ARRAY[]::text[], true),
  ('folha.esocial_ref_chave(folha.esocial_event)',                         ARRAY[]::text[], true),
  ('folha.esocial_antecessores_faltando(uuid,uuid)',                       ARRAY[]::text[], true),
  ('folha.esocial_depende(folha.esocial_event,folha.esocial_event)',       ARRAY[]::text[], true),
  ('folha.esocial_dependentes(uuid,boolean)',                              ARRAY[]::text[], true),
  ('folha.esocial_origem_conferir(folha.esocial_event)',                   ARRAY[]::text[], true),
  ('folha.esocial_ocorrencias_gravar(uuid,uuid,uuid,text,jsonb)',          ARRAY[]::text[], true),
  ('folha.esocial_evento_incluir(uuid,uuid,text,text,jsonb,text,jsonb,uuid,uuid,text)', ARRAY[]::text[], true),
  ('folha.esocial_imutavel()',                                             ARRAY[]::text[], false),
  ('folha.esocial_sem_truncate()',                                         ARRAY[]::text[], false),
  ('folha.esocial_setting_guarda()',                                       ARRAY[]::text[], true),
  ('folha.esocial_event_guarda()',                                         ARRAY[]::text[], true),
  ('folha.esocial_lot_guarda()',                                           ARRAY[]::text[], true),
  ('folha.esocial_lot_event_guarda()',                                     ARRAY[]::text[], true),
  ('folha.esocial_payload_guarda()',                                       ARRAY[]::text[], true),
  ('folha.esocial_occurrence_guarda()',                                    ARRAY[]::text[], true),
  ('folha.esocial_origin_guarda()',                                        ARRAY[]::text[], true);

SELECT is_empty($$SELECT acl.sig FROM acl WHERE to_regprocedure(acl.sig) IS NULL$$, 'todas as funções esperadas existem com a assinatura exata');
SELECT is(
  (SELECT count(*) FROM pg_proc p WHERE p.pronamespace = 'folha'::regnamespace AND p.proname LIKE 'esocial\_%'
      AND p.proname NOT LIKE 'esocial\_entrada\_%' AND p.proname NOT LIKE 'esocial\_dominio\_%'   -- as da 0032 são conferidas no arquivo 0032
      AND p.oid::regprocedure::text NOT IN (SELECT sig FROM acl)),
  0::bigint, 'não há função esocial_* fora da lista (nenhuma sobra sem ACL conferida)');
SELECT is_empty(
  $$SELECT acl.sig || '<-' || CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END
      FROM acl JOIN pg_proc p ON p.oid = to_regprocedure(acl.sig)::oid,
           LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
     WHERE a.grantee <> p.proowner
       AND (a.grantee = 0 OR NOT (a.grantee::regrole::text = ANY (acl.papeis)))$$,
  'ACL exata: nenhum papel além do previsto (nem PUBLIC, anon, authenticated, service_role) executa as funções da 0031');
SELECT is_empty(
  $$SELECT acl.sig || '<-' || r FROM acl, unnest(acl.papeis) AS r
     WHERE NOT has_function_privilege(r, to_regprocedure(acl.sig)::oid, 'execute')$$,
  'ACL exata: cada papel previsto executa as suas funções');
SELECT is(
  (SELECT string_agg(p.oid::regprocedure::text, ',' ORDER BY p.oid::regprocedure::text)
     FROM pg_proc p WHERE p.pronamespace = 'folha'::regnamespace AND has_function_privilege('dnex_gestao_api', p.oid, 'execute')
      AND p.proname LIKE 'esocial\_%' AND p.proname NOT LIKE 'esocial\_entrada\_%'),   -- as da 0032 são conferidas no arquivo 0032
  (SELECT string_agg(sig, ',' ORDER BY sig) FROM acl WHERE papeis = ARRAY['dnex_gestao_api']),
  'dnex_gestao_api executa, da fila do eSocial, exatamente as dez funções _v1');
SELECT is_empty(
  $$SELECT acl.sig FROM acl JOIN pg_proc p ON p.oid = to_regprocedure(acl.sig)::oid
     WHERE p.prosecdef IS DISTINCT FROM acl.definer
        OR NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) AS cfg WHERE cfg = 'search_path=pg_catalog, pg_temp')$$,
  'funções da 0031: search_path = pg_catalog, pg_temp em todas; SECURITY DEFINER nas que leem ou gravam dado');
SELECT is_empty(
  $$SELECT p.oid::regprocedure::text FROM pg_proc p
     WHERE p.pronamespace = 'folha'::regnamespace AND p.proname LIKE 'esocial\_%' AND p.prosecdef
       AND NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) AS cfg WHERE cfg LIKE 'search_path=pg_catalog%' AND cfg ~ ',\s*pg_temp$')$$,
  'toda função SECURITY DEFINER da fila fixa o search_path terminando em pg_temp');
CREATE TEMP TABLE tabelas (nome text PRIMARY KEY, por_conta boolean NOT NULL);
INSERT INTO tabelas VALUES
  ('esocial_event', true), ('esocial_lot', true), ('esocial_lot_event', true), ('esocial_event_payload', true),
  ('esocial_event_occurrence', true), ('esocial_event_origin', true), ('esocial_employer_setting', true),
  ('esocial_event_catalog', false), ('esocial_event_antecessor', false), ('esocial_event_state', false),
  ('esocial_event_transition', false), ('esocial_rejection_catalog', false);
SELECT is(
  (SELECT count(*) FROM tabelas t JOIN pg_class k ON k.oid = ('folha.' || t.nome)::regclass WHERE k.relrowsecurity AND k.relforcerowsecurity),
  12::bigint, 'as doze tabelas novas existem, com RLS e FORCE');
SELECT is_empty(
  $$SELECT p.tablename || ':' || p.policyname || '/' || p.cmd
      FROM pg_policies p JOIN tabelas t ON t.nome = p.tablename
     WHERE p.schemaname = 'folha'
       AND (p.cmd <> 'SELECT'
            OR (SELECT string_agg(r::text, '+' ORDER BY r::text) FROM unnest(p.roles) AS r) <> 'dnex_gestao_data_owner+dnex_gestao_folha_worker'
            OR (t.por_conta AND p.qual <> '(account_id = ( SELECT folha.current_account_id() AS current_account_id))'))$$,
  'policies: só leitura, só para worker e data_owner; nas tabelas por conta, pela conta da sessão');
SELECT is((SELECT count(*) FROM pg_policies p JOIN tabelas t ON t.nome = p.tablename WHERE p.schemaname = 'folha'), 12::bigint,
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
       AND (k.relname IN (SELECT nome FROM tabelas) OR k.relname = 'v_esocial_conferencia')
       AND has_table_privilege(r.papel, k.oid, p.priv)$$,
  'anon, authenticated, service_role e a sessão de aplicação não têm privilégio nas tabelas da fila nem na visão');
SELECT ok(
  NOT has_table_privilege('dnex_gestao_folha_worker', 'folha.esocial_event', 'INSERT')
  AND NOT has_table_privilege('dnex_gestao_folha_worker', 'folha.esocial_event', 'UPDATE')
  AND NOT has_table_privilege('dnex_gestao_folha_worker', 'folha.esocial_event_payload', 'INSERT')
  AND NOT has_table_privilege('dnex_gestao_folha_worker', 'folha.esocial_lot', 'UPDATE')
  AND has_table_privilege('dnex_gestao_folha_worker', 'folha.v_esocial_conferencia', 'SELECT')
  AND has_table_privilege('dnex_gestao_data_owner', 'folha.v_esocial_conferencia', 'SELECT'),
  'o worker não grava direto nas tabelas da fila e lê a visão de conferência');
SELECT is_empty(
  $$SELECT c.conrelid::regclass::text || ':' || c.conname
      FROM pg_constraint c
     WHERE c.contype = 'f'
       AND c.conrelid IN (SELECT ('folha.' || nome)::regclass FROM tabelas WHERE por_conta)
       AND c.confrelid NOT IN (SELECT ('folha.' || nome)::regclass FROM tabelas WHERE NOT por_conta)
       AND NOT EXISTS (SELECT 1 FROM unnest(c.conkey) AS k(attnum) JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
                        WHERE a.attname = 'account_id')$$,
  'toda FK das tabelas por conta (para empregador, estabelecimento, trabalhador, contrato, folha, lote e evento) é composta com account_id');
SELECT is((SELECT count(*) FROM pg_trigger t WHERE t.tgrelid = 'folha.esocial_event'::regclass AND NOT t.tgisinternal), 3::bigint,
  'o evento tem os três gatilhos (guarda, sem DELETE, sem TRUNCATE)');

-- ===========================================================================
-- 3. Cada permissão em cada função
--    Com todas as permissões menos a exigida, a função recusa com 42501 antes de qualquer
--    leitura (os identificadores são aleatórios: se a permissão passasse, o erro seria outro).
-- ===========================================================================
CREATE TEMP TABLE exige (chamada text NOT NULL, permissao text NOT NULL, PRIMARY KEY (chamada, permissao));
INSERT INTO exige VALUES
  ($$SELECT folha.esocial_producao_definir_v1(gen_random_uuid(), true, 'x')::text$$, 'folha.admin'),
  ($$SELECT folha.esocial_evento_enfileirar_v1(gen_random_uuid(), 'S-1000', 'producao_restrita', repeat('a', 64))::text$$, 'folha.transmit'),
  ($$SELECT folha.esocial_evento_avancar_v1(gen_random_uuid(), 'pendente_interno')::text$$, 'folha.transmit'),
  ($$SELECT folha.esocial_evento_cancelar_v1(gen_random_uuid(), 'x')::text$$, 'folha.transmit'),
  ($$SELECT folha.esocial_lote_enviar_v1(gen_random_uuid(), 'producao_restrita', ARRAY[gen_random_uuid()])::text$$, 'folha.transmit'),
  ($$SELECT folha.esocial_lote_retorno_v1(gen_random_uuid(), 'recebido', 'P', '201')::text$$, 'folha.transmit'),
  ($$SELECT folha.esocial_evento_retificar_v1(gen_random_uuid(), repeat('a', 64), 'x')::text$$, 'folha.transmit'),
  ($$SELECT folha.esocial_evento_retificar_v1(gen_random_uuid(), repeat('a', 64), 'x')::text$$, 'folha.close'),
  ($$SELECT folha.esocial_evento_excluir_v1(gen_random_uuid(), 'x')::text$$, 'folha.transmit'),
  ($$SELECT folha.esocial_evento_excluir_v1(gen_random_uuid(), 'x')::text$$, 'folha.close'),
  ($$SELECT folha.esocial_desfazer_plano_v1(gen_random_uuid(), 'producao_restrita', '2026-10-01'::date)::text$$, 'folha.read'),
  ($$SELECT folha.esocial_conferencia_v1(gen_random_uuid())::text$$, 'folha.read');
SELECT is_empty(
  $$SELECT e.chamada || ' sem ' || e.permissao || ' => ' || r.res
      FROM exige e
      CROSS JOIN LATERAL (SELECT pg_temp.le(pg_temp.ca(), ARRAY(SELECT p FROM unnest(pg_temp.todas()) p WHERE p <> e.permissao),
                                            '82000000-0000-0000-0000-000000000031'::uuid, e.chamada) AS res) r
     WHERE r.res NOT LIKE 'ERRO 42501:%'$$,
  'cada função _v1 recusa (42501) sem a sua permissão: admin, transmit, read e, em retificar e excluir, também close');
SELECT is_empty(
  $$SELECT e.chamada || ' => ' || pg_temp.le(pg_temp.ca(), NULL, NULL, e.chamada)
      FROM exige e WHERE pg_temp.le(pg_temp.ca(), NULL, NULL, e.chamada) NOT LIKE 'ERRO 42501:%'$$,
  'sem contexto da Folha nenhuma função _v1 funciona (42501)');

-- ===========================================================================
-- 4. Cenário: empregadores, trabalhadores e folhas
-- ===========================================================================
SELECT pg_temp.empregador('e1', :A);
SELECT pg_temp.empregador('e2', :A);
SELECT pg_temp.empregador('eb', :B);
SELECT pg_temp.contrato('c1', 'e1');
SELECT pg_temp.contrato('c2', 'e1');
SELECT pg_temp.contrato('c4', 'e1');
SELECT pg_temp.contrato('c3', 'e2');
SELECT pg_temp.contrato('cb', 'eb');
SELECT pg_temp.folha('r_out', 'e1', '2026-10-01', 'closed', ARRAY['c1', 'c2', 'c4'], '2026-10-31');
SELECT pg_temp.folha('r_draft', 'e1', '2026-09-01', 'draft', ARRAY['c1']);
SELECT pg_temp.folha('r_canc', 'e1', '2026-08-01', 'cancelled', ARRAY['c1']);
SELECT pg_temp.folha('r_pend', 'e1', '2026-07-01', 'closed', ARRAY['c1']);
SELECT pg_temp.folha('r_e2', 'e2', '2026-10-01', 'closed', ARRAY['c3']);
SELECT pg_temp.folha('r_nov', 'e1', '2026-10-01', 'closed', ARRAY['c1'], '2026-11-05', 2);
SELECT pg_temp.folha('r_nov2', 'e1', '2026-11-01', 'closed', ARRAY['c1', 'c2'], '2026-11-30');
DO $$
DECLARE
  v_livre uuid;
BEGIN
  PERFORM set_config('session_replication_role', 'replica', true);
  INSERT INTO folha.payroll_pendency (account_id, run_id, result_id, contract_id, codigo, tipo)
  SELECT r.account_id, r.run_id, pr.result_id, pr.contract_id, 'PENDENCIA_DE_TESTE', 'pendencia'
    FROM folha.payroll_run r JOIN folha.payroll_result pr ON pr.run_id = r.run_id
   WHERE r.run_id = pg_temp.id('r_pend');
  INSERT INTO folha.payroll_run (account_id, competencia, status, tipo_processo, sequencia, data_pagamento, fechado_em)
  VALUES (pg_temp.ca(), '2026-06-01', 'closed', 'mensal', 1, '2026-06-30', now())
  RETURNING run_id INTO v_livre;
  PERFORM set_config('session_replication_role', 'origin', true);
  INSERT INTO ids VALUES ('r_livre', v_livre, pg_temp.ca(), NULL);
END
$$;

-- ===========================================================================
-- 5. Tabelas do empregador: enfileirar, idempotência, versões, estados, lote, retorno
-- ===========================================================================
SELECT pg_temp.ok_(pg_temp.enf('t_s1000', 'e1', 'S-1000', 'producao_restrita', 's1000-v1', jsonb_build_object('inicio_validade', '2026-01-01')),
  'S-1000 enfileirado');
SELECT is((SELECT v::jsonb->>'situacao' FROM saida WHERE k = 't_s1000'), 'criado', 'S-1000: situação criado');
SELECT is(pg_temp.est('t_s1000'), 'rascunho', 'o evento nasce em rascunho');
SELECT is(
  (SELECT versao || '/' || ind_retif || '/' || criado_por_subject || '/' || atualizado_por_subject
     FROM folha.esocial_event WHERE event_id = pg_temp.id('t_s1000')),
  '1/1/82000000-0000-0000-0000-000000000031/82000000-0000-0000-0000-000000000031',
  'versão 1, indRetif 1 e o subject do contexto gravado na criação');
SELECT is((SELECT chave_negocio FROM folha.esocial_event WHERE event_id = pg_temp.id('t_s1000')),
  'S-1000|cod=|iv=2026-01-01|tr=|vi=|de=|ap=|pe=|ci=|ex=', 'a chave de negócio é calculada pelo banco (empregador + código + início de validade)');
-- idempotência: a mesma origem não cria nada
SELECT is((pg_temp.enf('t_s1000_dup', 'e1', 'S-1000', 'producao_restrita', 's1000-v1', jsonb_build_object('inicio_validade', '2026-01-01')))::jsonb->>'situacao',
  'existente', 'idempotência: enfileirar de novo o mesmo conteúdo devolve o existente');
SELECT is(pg_temp.id('t_s1000_dup'), pg_temp.id('t_s1000'), 'idempotência: é o mesmo evento');
SELECT is((SELECT count(*) FROM folha.esocial_event WHERE employer_id = pg_temp.id('e1') AND evento_codigo = 'S-1000'), 1::bigint,
  'idempotência: uma só linha na fila');
-- origem diferente com a versão ainda não enviada: substitui (a anterior fica no histórico, cancelada)
SELECT is((pg_temp.enf('t_s1000_v2', 'e1', 'S-1000', 'producao_restrita', 's1000-v2', jsonb_build_object('inicio_validade', '2026-01-01')))::jsonb->>'situacao',
  'substituido', 'conteúdo novo com a versão anterior ainda não enviada: substitui');
SELECT is(pg_temp.est('t_s1000') || '/' || pg_temp.est('t_s1000_v2'), 'cancelado/rascunho', 'a versão anterior fica cancelada no histórico; a nova nasce em rascunho');
SELECT is((SELECT versao FROM folha.esocial_event WHERE event_id = pg_temp.id('t_s1000_v2')), 2, 'a nova versão é a 2 (nunca descarte silencioso)');
SELECT is((SELECT count(*) FROM folha.esocial_event WHERE employer_id = pg_temp.id('e1') AND evento_codigo = 'S-1000' AND estado = 'rascunho'), 1::bigint,
  'uma só versão aberta por chave');
-- máquina de estados: nenhum pulo
SELECT matches(pg_temp.passo('t_s1000_v2', 'gerado'), '^ERRO 55000: Transição inválida do evento: de rascunho para gerado', 'rascunho -> gerado sem passar por pendente_interno: transição inválida');
SELECT matches(pg_temp.passo('t_s1000_v2', 'assinado'), '^ERRO 55000: Transição inválida do evento: de rascunho para assinado',
  'rascunho -> assinado: transição inválida');
SELECT matches(pg_temp.passo('t_s1000_v2', 'enviado'), '^ERRO 22023: ', 'enviado não se alcança por este caminho (só pelo lote)');
SELECT matches(pg_temp.passo('t_s1000_v2', 'validado'), '^ERRO 22023: ', 'validado não se alcança por este caminho (só pelo retorno do lote)');
SELECT pg_temp.ok_(pg_temp.passo('t_s1000_v2', 'pendente_interno'), 'rascunho -> pendente_interno');
SELECT matches(pg_temp.passo('t_s1000_v2', 'gerado'), '^ERRO 22023: Gerar exige o conteúdo', 'gerar sem o XML: recusado');
SELECT matches(pg_temp.passo('t_s1000_v2', 'pendente_interno', 'x'), '^ERRO 22023: ', 'avanço sem conteúdo não recebe conteúdo');
SELECT pg_temp.ok_(pg_temp.passo('t_s1000_v2', 'rascunho'), 'pendente_interno -> rascunho (volta para correção)');
SELECT is(pg_temp.est('t_s1000_v2'), 'rascunho', 'voltou ao rascunho');
SELECT pg_temp.ok_(pg_temp.ate_assinado('t_s1000_v2'), 'S-1000: rascunho -> pendente_interno -> gerado -> assinado');
SELECT is((SELECT payload_hash FROM folha.esocial_event WHERE event_id = pg_temp.id('t_s1000_v2')),
  pg_temp.h('<evt id="t_s1000_v2"><dado>x</dado></evt>'), 'o hash do XML gerado é o SHA-256 calculado pelo banco');
SELECT is((SELECT count(*) FROM folha.esocial_event_payload p JOIN folha.esocial_event e ON e.event_id = p.event_id
            WHERE e.event_id = pg_temp.id('t_s1000_v2') AND ((p.tipo = 'evento' AND p.conteudo_hash = e.payload_hash)
                                                           OR (p.tipo = 'evento_assinado' AND p.conteudo_hash = e.assinado_hash))), 2::bigint,
  'o XML gerado e o assinado ficam guardados em tabela própria, cada um com o seu hash');
SELECT ok((SELECT payload_hash <> assinado_hash AND gerado_em IS NOT NULL AND assinado_em IS NOT NULL
             FROM folha.esocial_event WHERE event_id = pg_temp.id('t_s1000_v2')), 'hash do assinado diferente do gerado; carimbos gravados');
-- lote
SELECT pg_temp.ok_(pg_temp.lote('L_t1', 't_s1000_v2'), 'lote com o S-1000 assinado enviado');
SELECT is((SELECT estado || '/' || tentativas || '/' || (lot_id = pg_temp.id('L_t1')) FROM folha.esocial_event WHERE event_id = pg_temp.id('t_s1000_v2')),
  'enviado/1/true', 'o evento passa a enviado, dentro do lote, com a tentativa 1');
SELECT is((SELECT situacao || '/' || grupo || '/' || qtd_eventos || '/' || enviado_por_subject || '/' || coalesce(protocolo, 'sem-protocolo')
             FROM folha.esocial_lot WHERE lot_id = pg_temp.id('L_t1')),
  'enviado/tabelas/1/82000000-0000-0000-0000-000000000031/sem-protocolo', 'lote: situação enviado, grupo tabelas, subject gravado, sem protocolo ainda');
SELECT matches(pg_temp.retorno('L_t1', 'recebido', 'PROT-L1', '301'), '^ERRO 22023: Resposta inválida', 'recebido com o código 301: recusado (301 é erro do servidor)');
SELECT matches(pg_temp.retorno('L_t1', 'recebido', NULL, '201'), '^ERRO 22023: Resposta inválida', 'recebido sem protocolo: recusado');
SELECT matches(pg_temp.retorno('L_t1', 'processado', NULL, NULL), '^ERRO 55000: Retorno processado não cabe no lote em situação enviado', 'processado antes de recebido: recusado');
SELECT pg_temp.ok_(pg_temp.retorno('L_t1', 'recebido', 'PROT-L1', '202', '[]'::jsonb, '[]'::jsonb, '<retornoLote cod="202"/>'), 'lote recebido (202) com o XML de retorno do lote guardado');
SELECT is((SELECT l.situacao || '/' || l.protocolo || '/' || l.codigo_resposta || '/' || e.estado
             FROM folha.esocial_lot l JOIN folha.esocial_event e ON e.lot_id = l.lot_id WHERE l.lot_id = pg_temp.id('L_t1')),
  'recebido/PROT-L1/202/em_processamento', 'protocolo guardado; o evento passa a em_processamento');
SELECT is((SELECT count(*) FROM folha.esocial_event_payload WHERE lot_id = pg_temp.id('L_t1') AND tipo = 'retorno_lote'), 1::bigint, 'o retorno do lote ficou guardado inteiro');
SELECT matches(pg_temp.retorno('L_t1', 'processado', NULL, NULL, '[]'::jsonb, jsonb_build_array(pg_temp.res('t_s1000_v2', 'rejeitado'))),
  '^ERRO 55000: Evento rejeitado exige ao menos uma ocorrência', 'rejeitado sem ocorrência de erro: recusado (o retorno original tem de ser preservado)');
SELECT matches(pg_temp.retorno('L_t1', 'processado', NULL, NULL, '[]'::jsonb, jsonb_build_array(pg_temp.res('t_s1000_v2', 'validado', 'REC-0001',
    jsonb_build_array(jsonb_build_object('codigo', 'X1', 'descricao', 'erro de teste', 'gravidade', 'erro'))))),
  '^ERRO 55000: Evento com ocorrência de erro', 'validado com ocorrência de erro: recusado');
SELECT matches(pg_temp.retorno('L_t1', 'processado', NULL, NULL, '[]'::jsonb, jsonb_build_array(pg_temp.res('t_s1000_v2', 'validado'))),
  '^ERRO 22023: O evento .* validado exige o número do recibo', 'validado sem recibo: recusado');
SELECT matches(pg_temp.retorno('L_t1', 'processado', NULL, NULL, '[]'::jsonb, '[]'::jsonb),
  '^ERRO 22023: O retorno precisa trazer o resultado de todos', 'o retorno processado precisa cobrir todos os eventos em processamento');
SELECT is(pg_temp.est('t_s1000_v2'), 'em_processamento', 'as recusas não mudaram o estado');
SELECT pg_temp.ok_(pg_temp.retorno('L_t1', 'processado', NULL, NULL, '[]'::jsonb, jsonb_build_array(pg_temp.res('t_s1000_v2', 'validado', 'REC-0001',
    jsonb_build_array(jsonb_build_object('codigo', 'W1', 'descricao', 'advertência de teste', 'gravidade', 'advertencia', 'localizacao', 'ideEmpregador')),
    '<retornoEvento ok="1"/>'))), 'processado: S-1000 validado com recibo e advertência');
SELECT is((SELECT estado || '/' || recibo_numero || '/' || com_advertencia || '/' || (processado_em IS NOT NULL) FROM folha.esocial_event WHERE event_id = pg_temp.id('t_s1000_v2')),
  'validado/REC-0001/true/true', 'validado com recibo, marcado com advertência e carimbado');
SELECT is((SELECT situacao FROM folha.esocial_lot WHERE lot_id = pg_temp.id('L_t1')), 'processado', 'o lote passa a processado');
SELECT is((SELECT gravidade || '/' || origem || '/' || codigo || '/' || criado_por_subject FROM folha.esocial_event_occurrence WHERE event_id = pg_temp.id('t_s1000_v2')),
  'advertencia/evento/W1/82000000-0000-0000-0000-000000000031', 'a ocorrência de advertência ficou registrada, com origem e subject');
SELECT is((SELECT count(*) FROM folha.esocial_event_payload WHERE event_id = pg_temp.id('t_s1000_v2') AND tipo = 'retorno_evento'), 1::bigint,
  'o XML de retorno do evento ficou guardado');
SELECT is_empty(
  $$SELECT a.auditoria_id FROM folha.auditoria a
     WHERE a.acao LIKE 'esocial\_%' AND (a.detalhe::text LIKE '%<evt%' OR a.detalhe::text LIKE '%Signature%' OR a.detalhe::text LIKE '%retornoEvento%')$$,
  'a auditoria nunca guarda o conteúdo do XML nem dos retornos');
SELECT is((SELECT string_agg(DISTINCT a.acao, ',' ORDER BY a.acao) FROM folha.auditoria a WHERE a.acao LIKE 'esocial\_%' AND a.actor_subject = '82000000-0000-0000-0000-000000000031'),
  'esocial_avancar,esocial_enfileirar,esocial_lote_enviar,esocial_lote_retorno', 'auditoria: enfileirar, avançar, enviar lote e retorno, com o subject do contexto');

-- as outras tabelas do e1, na ordem das dependências
SELECT pg_temp.ok_(pg_temp.enf('t_s1005', 'e1', 'S-1005', 'producao_restrita', 's1005', jsonb_build_object('codigo_tabela', 'EST1', 'inicio_validade', '2026-01-01')), 'S-1005 enfileirado');
SELECT pg_temp.ok_(pg_temp.validar('t_s1005', 'REC-1005'), 'S-1005 validado (S-1000 já validado)');
SELECT pg_temp.ok_(pg_temp.enf('t_s1020', 'e1', 'S-1020', 'producao_restrita', 's1020', jsonb_build_object('codigo_tabela', 'LOT1', 'inicio_validade', '2026-01-01')), 'S-1020 enfileirado');
SELECT pg_temp.ok_(pg_temp.validar('t_s1020', 'REC-1020'), 'S-1020 validado');
SELECT pg_temp.ok_(pg_temp.enf('t_s1010', 'e1', 'S-1010', 'producao_restrita', 's1010', jsonb_build_object('codigo_tabela', 'RUB1', 'inicio_validade', '2026-01-01')), 'S-1010 enfileirado');
SELECT pg_temp.ok_(pg_temp.validar('t_s1010', 'REC-1010'), 'S-1010 validado');

-- ===========================================================================
-- 6. Antecessores não validados, por empregador e por ambiente
-- ===========================================================================
SELECT pg_temp.ok_(pg_temp.enf('x_s1005', 'e2', 'S-1005', 'producao_restrita', 'e2-s1005', jsonb_build_object('codigo_tabela', 'EST2', 'inicio_validade', '2026-01-01')), 'e2: S-1005 enfileirado');
SELECT matches(pg_temp.ate_assinado('x_s1005'), '^ERRO 55000: Antecessor não validado: S-1000 \(ausente\)$',
  'S-1005 sem S-1000 validado do mesmo empregador: não passa a gerado (as validações do e1 não valem para o e2)');
SELECT is(pg_temp.est('x_s1005'), 'pendente_interno', 'o evento fica em pendente_interno, bloqueado');
SELECT pg_temp.ok_(pg_temp.enf('x_s1000', 'e2', 'S-1000', 'producao_restrita', 'e2-s1000', jsonb_build_object('inicio_validade', '2026-01-01')), 'e2: S-1000 enfileirado');
SELECT pg_temp.ok_(pg_temp.ate_assinado('x_s1000'), 'e2: S-1000 assinado');
SELECT pg_temp.ok_(pg_temp.lote('L_x1', 'x_s1000'), 'e2: lote do S-1000 enviado');
SELECT pg_temp.ok_(pg_temp.retorno('L_x1', 'recebido', 'PROT-X1', '201'), 'e2: lote recebido');
SELECT matches(pg_temp.passo('x_s1005', 'gerado', '<x/>'), '^ERRO 55000: Antecessor não validado: S-1000 \(nao_validado\)$',
  'com o S-1000 ainda em processamento, o motivo é nao_validado (protocolo não é aceitação)');
SELECT pg_temp.ok_(pg_temp.retorno('L_x1', 'processado', NULL, NULL, '[]'::jsonb, jsonb_build_array(pg_temp.res('x_s1000', 'validado', 'REC-X1000'))), 'e2: S-1000 validado');
SELECT pg_temp.ok_(pg_temp.passo('x_s1005', 'gerado', '<x/>'), 'agora o S-1005 do e2 passa a gerado');
SELECT pg_temp.ok_(pg_temp.passo('x_s1005', 'assinado', '<x sig="1"/>'), 'e2: S-1005 assinado');
SELECT pg_temp.ok_(pg_temp.lote('L_x2', 'x_s1005'), 'e2: lote do S-1005 enviado');
SELECT pg_temp.ok_(pg_temp.retorno('L_x2', 'recebido', 'PROT-X2', '201'), 'e2: lote recebido');
SELECT pg_temp.ok_(pg_temp.retorno('L_x2', 'processado', NULL, NULL, '[]'::jsonb, jsonb_build_array(pg_temp.res('x_s1005', 'validado', 'REC-X1005'))), 'e2: S-1005 validado');
SELECT pg_temp.ok_(pg_temp.enf('x_s2200', 'e2', 'S-2200', 'producao_restrita', 'e2-c3', jsonb_build_object('contract_id', pg_temp.id('c3'))), 'e2: S-2200 do c3 enfileirado');
SELECT matches(pg_temp.ate_assinado('x_s2200'), '^ERRO 55000: Antecessor não validado: S-1020 \(ausente, regra a validar\)$',
  'regra a_validar aplicada e marcada na mensagem (S-1020 ausente)');
SELECT is((SELECT employee_id = pg_temp.id('c3.trab') FROM folha.esocial_event WHERE event_id = pg_temp.id('x_s2200')), true, 'o trabalhador do evento é o do contrato (derivado)');

-- ambiente: produção só com liberação por empregador, e cada ambiente tem as suas validações
SELECT matches(pg_temp.enf('p_s1000', 'e1', 'S-1000', 'producao', 'p-s1000', jsonb_build_object('inicio_validade', '2026-02-01')),
  '^ERRO 42501: Produção não liberada para este empregador', 'produção sem liberação do empregador: recusada');
SELECT pg_temp.ok_(pg_temp.adm_a(format('SELECT folha.esocial_producao_definir_v1(%L::uuid, true, ''homologação concluída'')::text', pg_temp.id('e1'))), 'produção liberada para o e1 (folha.admin)');
SELECT is((SELECT producao_liberada || '/' || definido_por_subject FROM folha.esocial_employer_setting WHERE employer_id = pg_temp.id('e1')),
  'true/81000000-0000-0000-0000-000000000031', 'liberação gravada com o subject do administrador');
SELECT pg_temp.ok_(pg_temp.enf('p_s1000', 'e1', 'S-1000', 'producao', 'p-s1000', jsonb_build_object('inicio_validade', '2026-02-01')), 'produção liberada: S-1000 de produção enfileirado');
SELECT pg_temp.ok_(pg_temp.enf('p_s1005', 'e1', 'S-1005', 'producao', 'p-s1005', jsonb_build_object('codigo_tabela', 'EST1', 'inicio_validade', '2026-02-01')), 'S-1005 de produção enfileirado');
SELECT matches(pg_temp.ate_assinado('p_s1005'), '^ERRO 55000: Antecessor não validado: S-1000 \(nao_validado\)$',
  'a validação do S-1000 em produção restrita não vale para produção');
SELECT pg_temp.ok_(pg_temp.ate_assinado('p_s1000'), 'S-1000 de produção assinado');
SELECT pg_temp.ok_(pg_temp.adm_a(format('SELECT folha.esocial_producao_definir_v1(%L::uuid, false, ''liberação revogada'')::text', pg_temp.id('e1'))), 'liberação revogada');
SELECT matches(pg_temp.lote('L_p1', 'p_s1000'), '^ERRO 42501: Produção não liberada', 'liberação revogada antes do envio: o lote de produção é recusado');
SELECT pg_temp.ok_(pg_temp.tx_a(format('SELECT folha.esocial_evento_cancelar_v1(%L::uuid, ''limpeza do cenário'')::text', pg_temp.id('p_s1000'))), 'cancelar o S-1000 de produção assinado');
SELECT pg_temp.ok_(pg_temp.tx_a(format('SELECT folha.esocial_evento_cancelar_v1(%L::uuid, ''limpeza do cenário'')::text', pg_temp.id('p_s1005'))), 'cancelar o S-1005 de produção');

-- validações de entrada (códigos, componentes e hash)
SELECT matches(pg_temp.enf('v1', 'e1', 'S-9999', 'producao_restrita', 'v1'), '^ERRO 22023: Evento S-9999 fora do catálogo', 'código fora do catálogo: recusado');
SELECT matches(pg_temp.enf('v2', 'e1', 'S-5001', 'producao_restrita', 'v2'), '^ERRO 22023: O evento S-5001 não pode ser enfileirado', 'totalizador (retorno do governo) não se enfileira');
SELECT matches(pg_temp.enf('v3', 'e1', 'S-3000', 'producao_restrita', 'v3'), '^ERRO 22023: A exclusão \(S-3000\) nasce de', 'S-3000 só nasce da exclusão');
SELECT matches(pg_temp.enf('v4', 'e1', 'S-1200', 'producao_restrita', 'v4', jsonb_build_object('employee_id', pg_temp.id('c1.trab'), 'ind_apuracao', 1)),
  '^ERRO 22023: Evento S-1200: o componente de referência "periodo" é obrigatório', 'componente obrigatório ausente: recusado');
SELECT matches(pg_temp.enf('v5', 'e1', 'S-1200', 'producao_restrita', 'v5', jsonb_build_object('employee_id', pg_temp.id('c1.trab'), 'ind_apuracao', 1, 'periodo_apuracao', '2026-10-15')),
  '^ERRO 22023: periodo_apuracao deve ser o primeiro dia do mês', 'período que não é o primeiro dia do mês: recusado');
SELECT matches(pg_temp.enf('v6', 'e1', 'S-1200', 'producao_restrita', 'v6', jsonb_build_object('employee_id', pg_temp.id('c1.trab'), 'ind_apuracao', 2, 'periodo_apuracao', '2026-10-01')),
  '^ERRO 22023: Na folha anual', 'folha anual (indApuracao 2) é 1º de janeiro');
SELECT matches(pg_temp.enf('v7', 'e1', 'S-1210', 'producao_restrita', 'v7', jsonb_build_object('employee_id', pg_temp.id('c1.trab'), 'ind_apuracao', 1, 'periodo_apuracao', '2026-10-01')),
  '^ERRO 22023: Evento S-1210: o componente de referência "ind_apuracao" não faz parte da chave', 'componente fora da chave do evento: recusado');
SELECT matches(pg_temp.enf('v8', 'e1', 'S-2200', 'producao_restrita', 'v8', jsonb_build_object('contract_id', pg_temp.id('c3'))),
  '^ERRO 22023: Contrato .* não é deste empregador', 'contrato de outro empregador: recusado');
SELECT matches(pg_temp.enf('v9', 'e1', 'S-1000', 'producao_restrita', 'v9', jsonb_build_object('inicio_validade', '2026-01-01', 'xpto', 1)),
  '^ERRO 22023: Chave\(s\) de referência desconhecida\(s\): xpto', 'chave de referência desconhecida: recusada');
SELECT matches(pg_temp.tx_a(format('SELECT folha.esocial_evento_enfileirar_v1(%L::uuid, ''S-1000'', ''producao_restrita'', ''nao-e-hash'', ''{"inicio_validade":"2026-03-01"}'')::text', pg_temp.id('e1'))),
  '^ERRO 22023: O hash de origem deve ser um SHA-256', 'hash de origem fora do padrão: recusado');
SELECT matches(pg_temp.tx_a(format('SELECT folha.esocial_evento_enfileirar_v1(%L::uuid, ''S-1000'', ''teste'', %L, ''{}'')::text', pg_temp.id('e1'), pg_temp.h('x'))),
  '^ERRO 22023: Ambiente deve ser', 'ambiente inválido: recusado');
SELECT is((SELECT count(*) FROM folha.esocial_event WHERE employer_id = pg_temp.id('e1') AND evento_codigo IN ('S-9999', 'S-5001')), 0::bigint, 'nenhuma recusa deixou linha');

-- ===========================================================================
-- 7. Folha aberta ou com pendência: o evento periódico é recusado (trava da 0027)
-- ===========================================================================
CREATE FUNCTION pg_temp.r1200(p_trab text, p_per text DEFAULT '2026-10-01') RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('employee_id', pg_temp.id(p_trab), 'ind_apuracao', 1, 'periodo_apuracao', p_per) $$;
CREATE FUNCTION pg_temp.r1210(p_trab text, p_per text DEFAULT '2026-10-01') RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('employee_id', pg_temp.id(p_trab), 'periodo_apuracao', p_per) $$;
CREATE FUNCTION pg_temp.r1299(p_per text DEFAULT '2026-10-01') RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object('ind_apuracao', 1, 'periodo_apuracao', p_per) $$;
CREATE FUNCTION pg_temp.rvinc(p_contract text, p_data text DEFAULT NULL) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object('contract_id', pg_temp.id(p_contract), 'data_efeito', p_data)) $$;

SELECT matches(pg_temp.enf('f1', 'e1', 'S-1200', 'producao_restrita', 'f1', pg_temp.r1200('c1.trab')),
  '^ERRO 55000: O evento S-1200 exige a folha de origem \(fechada e sem pendência\); nenhuma foi informada', 'S-1200 sem folha de origem: recusado');
SELECT matches(pg_temp.enf('f2', 'e1', 'S-1200', 'producao_restrita', 'f2', pg_temp.r1200('c1.trab', '2026-09-01'), pg_temp.origem('r_draft')),
  '^ERRO 55000: A folha .* está aberta \(draft\): só folha fechada gera evento', 'folha aberta (rascunho): evento periódico recusado');
SELECT matches(pg_temp.enf('f3', 'e1', 'S-1200', 'producao_restrita', 'f3', pg_temp.r1200('c1.trab', '2026-08-01'), pg_temp.origem('r_canc')),
  '^ERRO 55000: A folha .* está cancelada', 'folha cancelada: recusado');
SELECT matches(pg_temp.enf('f4', 'e1', 'S-1200', 'producao_restrita', 'f4', pg_temp.r1200('c1.trab', '2026-07-01'), pg_temp.origem('r_pend')),
  '^ERRO 55000: A folha .* tem 1 pendência\(s\) sem liberação: não gera evento', 'folha fechada com pendência sem liberação: recusado');
SELECT matches(pg_temp.enf('f5', 'e1', 'S-1200', 'producao_restrita', 'f5', pg_temp.r1200('c1.trab', '2026-09-01'), pg_temp.origem('r_out')),
  '^ERRO 55000: A competência da folha .* não é o período de apuração do evento', 'competência da folha diferente do período do evento: recusado');
SELECT matches(pg_temp.enf('f6', 'e1', 'S-1200', 'producao_restrita', 'f6', pg_temp.r1200('c1.trab'), pg_temp.origem('r_e2')),
  '^ERRO 55000: A folha .* não é do empregador do evento', 'folha de outro empregador: recusado');
SELECT matches(pg_temp.enf('f7', 'e1', 'S-1200', 'producao_restrita', 'f7', pg_temp.r1200('c1.trab', '2026-06-01'), pg_temp.origem('r_livre')),
  '^ERRO 55000: A folha .* não é do empregador do evento \(folha sem empregador não gera evento\)', 'folha sem empregador: recusado');
SELECT matches(pg_temp.enf('f8', 'e1', 'S-1200', 'producao_restrita', 'f8', pg_temp.r1200('c2.trab'), pg_temp.origem('r_nov')),
  '^ERRO 55000: A folha .* não tem resultado do trabalhador do evento', 'folha sem resultado do trabalhador do evento: recusado');
SELECT matches(pg_temp.enf('f9', 'e1', 'S-1299', 'producao_restrita', 'f9', pg_temp.r1299('2026-09-01')),
  '^ERRO 55000: O período 2026-09 tem folha aberta: o fechamento só nasce com todas as folhas fechadas', 'S-1299 com folha aberta no período: recusado');
SELECT matches(pg_temp.enf('f10', 'e1', 'S-1299', 'producao_restrita', 'f10', pg_temp.r1299('2026-07-01')),
  '^ERRO 55000: O período 2026-07 tem folha com pendência sem liberação', 'S-1299 com folha fechada com pendência: recusado');
SELECT is((SELECT count(*) FROM folha.esocial_event WHERE evento_codigo IN ('S-1200', 'S-1299') AND employer_id = pg_temp.id('e1')), 0::bigint,
  'as recusas por folha aberta não deixaram nenhuma linha na fila');

-- admissões do e1 (c1 e c2); o c4 fica sem admissão
SELECT pg_temp.ok_(pg_temp.enf('t_s2200c1', 'e1', 'S-2200', 'producao_restrita', 's2200c1', pg_temp.rvinc('c1')), 'S-2200 do c1 enfileirado');
SELECT pg_temp.ok_(pg_temp.validar('t_s2200c1', 'REC-2200-C1'), 'S-2200 do c1 validado');
SELECT pg_temp.ok_(pg_temp.enf('t_s2200c2', 'e1', 'S-2200', 'producao_restrita', 's2200c2', pg_temp.rvinc('c2')), 'S-2200 do c2 enfileirado');
SELECT pg_temp.ok_(pg_temp.validar('t_s2200c2', 'REC-2200-C2'), 'S-2200 do c2 validado');
-- S-1200 do w1: a folha fechada serve; uma pendência criada depois bloqueia o gerado
SELECT pg_temp.ok_(pg_temp.enf('p1200w1', 'e1', 'S-1200', 'producao_restrita', 'p1200w1', pg_temp.r1200('c1.trab'), pg_temp.origem('r_out')), 'S-1200 do w1 enfileirado (folha fechada, sem pendência)');
SELECT is((SELECT count(*) FROM folha.esocial_event_origin WHERE event_id = pg_temp.id('p1200w1') AND run_id = pg_temp.id('r_out')), 1::bigint, 'a folha de origem ficou ligada ao evento');
DO $$
BEGIN
  PERFORM set_config('session_replication_role', 'replica', true);
  INSERT INTO folha.payroll_pendency (account_id, run_id, result_id, contract_id, codigo, tipo)
  SELECT r.account_id, r.run_id, pr.result_id, pr.contract_id, 'PENDENCIA_TARDIA', 'pendencia'
    FROM folha.payroll_run r JOIN folha.payroll_result pr ON pr.run_id = r.run_id AND pr.contract_id = pg_temp.id('c1')
   WHERE r.run_id = pg_temp.id('r_out');
  PERFORM set_config('session_replication_role', 'origin', true);
END
$$;
SELECT matches(pg_temp.ate_assinado('p1200w1'), '^ERRO 55000: A folha .* tem 1 pendência\(s\) sem liberação: não gera evento',
  'pendência criada depois de enfileirar: o evento não passa a gerado');
DO $$
BEGIN
  PERFORM set_config('session_replication_role', 'replica', true);
  DELETE FROM folha.payroll_pendency WHERE codigo = 'PENDENCIA_TARDIA';
  PERFORM set_config('session_replication_role', 'origin', true);
END
$$;
-- S-1210: o mês de apuração é o do pagamento
SELECT matches(pg_temp.enf('f11', 'e1', 'S-1210', 'producao_restrita', 'f11', pg_temp.r1210('c1.trab'), pg_temp.origem('r_nov')),
  '^ERRO 55000: A data de pagamento da folha .* não cai no mês de apuração do S-1210', 'S-1210 com pagamento em outro mês que o do período: recusado');
SELECT pg_temp.ok_(pg_temp.enf('p1210w1', 'e1', 'S-1210', 'producao_restrita', 'p1210w1', pg_temp.r1210('c1.trab'), pg_temp.origem('r_out')), 'S-1210 do w1 enfileirado (pagamento em outubro)');

-- ===========================================================================
-- 8. Cadeia dos periódicos: S-2200 -> S-1200 -> S-1210 -> S-1299 (fechamento por ciclo)
-- ===========================================================================
SELECT matches(pg_temp.ate_assinado('p1210w1'), '^ERRO 55000: Antecessor não validado: S-1200 ou S-2299 \(nao_validado\)$',
  'S-1210 antes do S-1200 validado: bloqueado por antecessor (alternativa S-1200 ou S-2299)');
SELECT pg_temp.ok_(pg_temp.validar('p1200w1', 'REC-1200-W1'), 'S-1200 do w1 validado');
SELECT pg_temp.ok_(pg_temp.validar('p1210w1', 'REC-1210-W1'), 'S-1210 do w1 validado (S-1200 validado)');
SELECT pg_temp.ok_(pg_temp.enf('p1200w4', 'e1', 'S-1200', 'producao_restrita', 'p1200w4', pg_temp.r1200('c4.trab'), pg_temp.origem('r_out')), 'S-1200 do w4 (sem admissão) enfileirado');
SELECT matches(pg_temp.ate_assinado('p1200w4'), '^ERRO 55000: Antecessor não validado: S-2200 ou S-2300 \(ausente\)$',
  'S-1200 de trabalhador sem S-2200 nem S-2300 validado: bloqueado');
SELECT pg_temp.ok_(pg_temp.enf('p1200w2', 'e1', 'S-1200', 'producao_restrita', 'p1200w2', pg_temp.r1200('c2.trab'), pg_temp.origem('r_out')), 'S-1200 do w2 enfileirado');
SELECT pg_temp.ok_(pg_temp.validar('p1200w2', 'REC-1200-W2'), 'S-1200 do w2 validado');
SELECT pg_temp.ok_(pg_temp.enf('p1210w2', 'e1', 'S-1210', 'producao_restrita', 'p1210w2', pg_temp.r1210('c2.trab'), pg_temp.origem('r_out')), 'S-1210 do w2 enfileirado');
SELECT pg_temp.ok_(pg_temp.enf('p1299', 'e1', 'S-1299', 'producao_restrita', 'p1299', pg_temp.r1299()), 'S-1299 do período enfileirado (nenhuma folha aberta)');
SELECT is((SELECT ciclo || '/' || ind_apuracao FROM folha.esocial_event WHERE event_id = pg_temp.id('p1299')), '1/1', 'o fechamento nasce no ciclo 1');
SELECT matches(pg_temp.ate_assinado('p1299'), '^ERRO 55000: Antecessor não validado: S-1200 \(nao_validado\); S-1210 \(nao_validado\)$',
  'S-1299 com periódicos pendentes (S-1200 do w4 e S-1210 do w2): bloqueado, com os dois antecessores na mensagem');
SELECT pg_temp.ok_(pg_temp.validar('p1210w2', 'REC-1210-W2'), 'S-1210 do w2 validado');
SELECT matches(pg_temp.passo('p1299', 'gerado', '<fech/>'), '^ERRO 55000: Antecessor não validado: S-1200 \(nao_validado\)$',
  'S-1299 com um S-1200 pendente (o do w4, bloqueado) no período: segue bloqueado');
SELECT pg_temp.ok_(pg_temp.tx_a(format('SELECT folha.esocial_evento_cancelar_v1(%L::uuid, ''trabalhador sem admissão: fora da folha'')::text', pg_temp.id('p1200w4'))), 'S-1200 do w4 cancelado');
SELECT pg_temp.ok_(pg_temp.passo('p1299', 'gerado', '<fech/>'), 'com todos os periódicos validados (e o cancelado fora da conta) o S-1299 passa a gerado');
SELECT pg_temp.ok_(pg_temp.passo('p1299', 'assinado', '<fech sig="1"/>'), 'S-1299 assinado');
-- fechamento em lote próprio (parecer 4.3)
SELECT pg_temp.ok_(pg_temp.enf('p1200w1n', 'e1', 'S-1200', 'producao_restrita', 'p1200w1n', pg_temp.r1200('c1.trab', '2026-11-01'), pg_temp.origem('r_nov2')), 'S-1200 do w1 de novembro enfileirado');
SELECT pg_temp.ok_(pg_temp.ate_assinado('p1200w1n'), 'S-1200 de novembro assinado');
SELECT matches(pg_temp.lote('L_mix', 'p1299', 'p1200w1n'), '^ERRO 55000: O fechamento \(S-1299\) vai em lote próprio',
  'S-1299 junto de outro evento no mesmo lote: recusado (fechamento em lote próprio)');
SELECT is((SELECT count(*) FROM folha.esocial_lot_event le WHERE le.event_id IN (pg_temp.id('p1299'), pg_temp.id('p1200w1n'))), 0::bigint, 'a recusa não deixou lote nem participação');
SELECT pg_temp.ok_(pg_temp.tx_a(format('SELECT folha.esocial_evento_cancelar_v1(%L::uuid, ''fora do cenário'')::text', pg_temp.id('p1200w1n'))), 'S-1200 de novembro cancelado (assinado, fora de lote)');
SELECT pg_temp.ok_(pg_temp.lote('L_1299', 'p1299'), 'o S-1299 vai sozinho em lote');
SELECT pg_temp.ok_(pg_temp.retorno('L_1299', 'recebido', 'PROT-1299', '201'), 'lote do fechamento recebido');
SELECT pg_temp.ok_(pg_temp.retorno('L_1299', 'processado', NULL, NULL, '[]'::jsonb, jsonb_build_array(pg_temp.res('p1299', 'validado', 'REC-1299-C1'))), 'fechamento validado: período 2026-10 fechado');
SELECT is(folha.esocial_periodo_fechado(pg_temp.ca(), pg_temp.id('e1'), 'producao_restrita', 1::smallint, '2026-10-01'), true, 'o período está fechado (um S-1299 validado a mais que S-1298)');
SELECT is(folha.esocial_periodo_fechado(pg_temp.ca(), pg_temp.id('e1'), 'producao_restrita', 1::smallint, '2026-11-01'), false, 'outro período segue aberto');
SELECT is(folha.esocial_periodo_fechado(pg_temp.ca(), pg_temp.id('e1'), 'producao', 1::smallint, '2026-10-01'), false, 'o fechamento de produção restrita não fecha produção');
-- ===========================================================================
-- 9. Plano de DESFAZER com o período fechado (só leitura; ordem inversa das dependências)
-- ===========================================================================
CREATE FUNCTION pg_temp.guarda(p_k text, p_v text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO saida VALUES (p_k, p_v) ON CONFLICT (k) DO UPDATE SET v = EXCLUDED.v;
  RETURN p_v;
END $$;
CREATE FUNCTION pg_temp.contagens() RETURNS text LANGUAGE sql AS $$
  SELECT (SELECT count(*) FROM folha.esocial_event) || '/' || (SELECT count(*) FROM folha.esocial_event_payload) || '/'
      || (SELECT count(*) FROM folha.esocial_lot) || '/' || (SELECT count(*) FROM folha.esocial_event_occurrence) || '/'
      || (SELECT count(*) FROM folha.auditoria) || '/' || (SELECT count(*) FROM folha.esocial_lot_event) $$;
SELECT pg_temp.guarda('cnt_antes', pg_temp.contagens());
SELECT pg_temp.ok_(pg_temp.guarda('plano_per', pg_temp.plano_periodo('e1', '2026-10-01')), 'plano de desfazer do período 2026-10 gerado');
SELECT is(pg_temp.seq_plano((SELECT v FROM saida WHERE k = 'plano_per')),
  'S-1298@reabrir_periodo > S-1210@excluir > S-1210@excluir > S-1200@excluir > S-1200@excluir',
  'plano do período fechado: reabertura S-1298, depois exclusão dos S-1210 e só então dos S-1200 (ordem inversa das dependências)');
SELECT pg_temp.ok_(pg_temp.guarda('plano_per_p', pg_temp.tx_a(format('SELECT folha.esocial_desfazer_plano_v1(%L::uuid, ''producao_restrita'', ''2026-10-01''::date, 1::smallint, NULL)::text', pg_temp.id('e1')))),
  'o mesmo plano chamado por caminho que PERSISTE (o anterior desfaz tudo ao fim, então só este prova a leitura)');
SELECT is(pg_temp.contagens(), (SELECT v FROM saida WHERE k = 'cnt_antes'), 'o plano não executa nada: nenhuma linha criada ou alterada (eventos, conteúdo, lotes, ocorrências, auditoria)');
SELECT is((SELECT v::jsonb->>'somente_leitura' || '/' || (v::jsonb->>'total_passos') FROM saida WHERE k = 'plano_per'), 'true/5', 'o plano se declara somente leitura e traz 5 passos');
SELECT ok(
  (SELECT p->>'acao' = 'reabrir_periodo' AND (p->>'exige_decisao_humana')::boolean AND (p->>'exige_aprovacao_registrada')::boolean
          AND p->'efeitos_externos' = '["DCTFWeb", "FGTS Digital"]'::jsonb
          AND p->'motivos_decisao' = '["reabertura_muda_dctfweb_e_fgts_digital"]'::jsonb
          AND p->'permissoes' = '["folha.transmit", "folha.close"]'::jsonb
          AND p->'referencia'->>'ciclo' = '1' AND p->>'evento_a_enviar' = 'S-1298'
     FROM saida, jsonb_array_elements(v::jsonb->'passos') p WHERE k = 'plano_per' AND (p->>'ordem')::int = 1),
  'a reabertura exige decisão humana (DCTFWeb e FGTS Digital), aprovação registrada e as permissões transmit + close');
SELECT is_empty(
  $$SELECT p->>'ordem' FROM saida, jsonb_array_elements(v::jsonb->'passos') p
     WHERE k = 'plano_per' AND p->>'acao' = 'excluir'
       AND NOT ((p->>'evento_a_enviar') = 'S-3000' AND (p->>'exige_aprovacao_registrada')::boolean AND NOT (p->>'exige_decisao_humana')::boolean
                AND p->'permissoes' = '["folha.transmit", "folha.close"]'::jsonb)$$,
  'as exclusões de periódicos são S-3000 com aprovação registrada; a decisão humana já está na reabertura');
SELECT is_empty(
  $$SELECT s1.p->>'ordem' FROM saida, jsonb_array_elements(v::jsonb->'passos') s1(p)
     WHERE k = 'plano_per' AND (
       (s1.p->>'evento_codigo' = 'S-1210' AND jsonb_array_length(s1.p->'depois_de_ordens') <> 0)
       OR (s1.p->>'evento_codigo' = 'S-1200' AND jsonb_array_length(s1.p->'depois_de_ordens') <> 1))$$,
  'cada S-1200 só espera o S-1210 do mesmo trabalhador; os S-1210 não esperam ninguém');
SELECT is_empty(
  $$SELECT s1.p->>'ordem'
      FROM saida, jsonb_array_elements(v::jsonb->'passos') s1(p)
      CROSS JOIN LATERAL jsonb_array_elements_text(s1.p->'depois_de_ordens') d(o)
      JOIN LATERAL (SELECT s2.p FROM jsonb_array_elements(saida.v::jsonb->'passos') s2(p) WHERE (s2.p->>'ordem') = d.o) s2 ON true
     WHERE k = 'plano_per' AND (d.o::int >= (s1.p->>'ordem')::int OR s2.p->'referencia'->>'employee_id' <> s1.p->'referencia'->>'employee_id')$$,
  'os passos de que cada passo depende têm ordem menor e são do mesmo trabalhador');
SELECT pg_temp.ok_(pg_temp.guarda('plano_s2200', pg_temp.plano_evento('e1', 't_s2200c1')), 'plano de desfazer do S-2200 do c1 gerado');
SELECT is(pg_temp.seq_plano((SELECT v FROM saida WHERE k = 'plano_s2200')),
  'S-1298@reabrir_periodo > S-1210@excluir > S-1200@excluir > S-2200@excluir',
  'plano do S-2200: reabrir o período, excluir o S-1210, o S-1200 e só então o S-2200 (sem tocar nos eventos do outro trabalhador)');
SELECT is((SELECT count(*) FROM saida, jsonb_array_elements(v::jsonb->'passos') p
            WHERE k = 'plano_s2200' AND p->'referencia'->>'employee_id' = pg_temp.id('c2.trab')::text), 0::bigint,
  'o plano do S-2200 do c1 não inclui eventos do c2');
SELECT ok(
  (SELECT (p->>'exige_decisao_humana')::boolean AND p->'motivos_decisao' = '["exclusao_de_cadastro_ou_vinculo_afeta_o_historico_e_os_dependentes"]'::jsonb
          AND p->>'recibo_numero' = 'REC-2200-C1'
     FROM saida, jsonb_array_elements(v::jsonb->'passos') p WHERE k = 'plano_s2200' AND p->>'evento_codigo' = 'S-2200'),
  'excluir a admissão exige decisão humana e leva o recibo do evento');
SELECT pg_temp.ok_(pg_temp.guarda('plano_s1005', pg_temp.plano_evento('e1', 't_s1005')), 'plano de desfazer do S-1005 (tabela) gerado');
SELECT is(pg_temp.seq_plano((SELECT v FROM saida WHERE k = 'plano_s1005')),
  'S-1298@reabrir_periodo > S-1210@excluir > S-1210@excluir > S-1200@excluir > S-1200@excluir > S-1010@excluir > S-2200@excluir > S-2200@excluir > S-1020@excluir > S-1005@excluir',
  'plano do S-1005: toda a cadeia que depende dele, dos periódicos às tabelas, e o próprio S-1005 por último');
SELECT is((SELECT jsonb_array_length(p->'depois_de_ordens') || '/' || (p->>'ordem') || '/' || (p->>'exige_decisao_humana')
             FROM saida, jsonb_array_elements(v::jsonb->'passos') p WHERE k = 'plano_s1005' AND p->>'evento_codigo' = 'S-1005'),
  '5/10/true', 'o S-1005 é o último passo, espera os 5 que dependem dele diretamente e exige decisão humana');
SELECT is_empty(
  $$SELECT s1.p->>'ordem' FROM saida, jsonb_array_elements(v::jsonb->'passos') s1(p)
      CROSS JOIN LATERAL jsonb_array_elements_text(s1.p->'depois_de_ordens') d(o)
     WHERE k = 'plano_s1005' AND d.o::int >= (s1.p->>'ordem')::int$$,
  'no plano do S-1005 todo passo vem depois dos que dependem dele');
SELECT is(pg_temp.seq_plano(pg_temp.plano_evento('e1', 'p1299')), pg_temp.seq_plano((SELECT v FROM saida WHERE k = 'plano_per')),
  'o plano do evento de fechamento (S-1299) é o plano do período');
SELECT matches(pg_temp.lei_a(format('SELECT folha.esocial_desfazer_plano_v1(%L::uuid, ''producao_restrita'', ''2026-10-01''::date, 1::smallint, %L::uuid)::text', pg_temp.id('e1'), pg_temp.id('t_s1005'))),
  '^ERRO 22023: Informe o período OU o evento', 'período e evento juntos: recusado');
SELECT matches(pg_temp.lei_a(format('SELECT folha.esocial_desfazer_plano_v1(%L::uuid, ''producao_restrita'')::text', pg_temp.id('e1'))),
  '^ERRO 22023: Informe o período OU o evento', 'nem período nem evento: recusado');
SELECT matches(pg_temp.plano_evento('e2', 't_s1000_v2'), '^ERRO P0002: Evento .* não encontrado neste empregador e ambiente', 'evento de outro empregador: não encontrado');
SELECT matches(pg_temp.plano_evento('e1', 'p1299', 'producao'), '^ERRO P0002: ', 'o ambiente também delimita o plano');

-- ===========================================================================
-- 10. Período fechado: nada periódico entra, nem retifica, nem exclui, sem o S-1298
-- ===========================================================================
SELECT matches(pg_temp.enf('p1200w4b', 'e1', 'S-1200', 'producao_restrita', 'p1200w4b', pg_temp.r1200('c4.trab'), pg_temp.origem('r_out')),
  '^ERRO 55000: O período 2026-10 está fechado: reabra com o S-1298 antes de gerar evento periódico', 'evento periódico novo em período fechado: recusado');
SELECT matches(pg_temp.retif('rx1', 'p1200w1', 'p1200w1-x', 'tentativa em período fechado'),
  '^ERRO 55000: O período 2026-10 está fechado: reabra com o S-1298', 'retificação de periódico em período fechado: recusada');
SELECT matches(pg_temp.excl('ex1', 'p1200w1', 'tentativa em período fechado'),
  '^ERRO 55000: O período 2026-10 está fechado: reabra com o S-1298 antes de excluir evento periódico', 'exclusão de periódico em período fechado: recusada');
SELECT matches(pg_temp.excl('ex2', 'p1299', 'desfazer o fechamento'),
  '^ERRO 55000: O evento S-1299 não se exclui por S-3000 \(fechamento se desfaz pela reabertura S-1298\)', 'o fechamento não se exclui: se desfaz pela reabertura');
SELECT matches(pg_temp.enf('p1298_set', 'e1', 'S-1298', 'producao_restrita', 'p1298-set', pg_temp.r1299('2026-09-01')),
  '^ERRO 55000: O período 2026-09 não está fechado', 'reabrir período que não está fechado: recusado');

-- ===========================================================================
-- 11. Reabertura (S-1298) e novo ciclo de fechamento
-- ===========================================================================
SELECT pg_temp.ok_(pg_temp.enf('p1298', 'e1', 'S-1298', 'producao_restrita', 'p1298', pg_temp.r1299()), 'S-1298 do período fechado enfileirado');
SELECT is((SELECT ciclo || '/' || (chave_negocio LIKE '%|ci=1|%') FROM folha.esocial_event WHERE event_id = pg_temp.id('p1298')), '1/true', 'a reabertura reabre o ciclo 1');
SELECT pg_temp.ok_(pg_temp.validar('p1298', 'REC-1298-C1'), 'S-1298 validado (exige o S-1299 validado do mesmo ciclo)');
SELECT is(folha.esocial_periodo_fechado(pg_temp.ca(), pg_temp.id('e1'), 'producao_restrita', 1::smallint, '2026-10-01'), false, 'depois da reabertura validada o período está aberto');
SELECT is((pg_temp.enf('p1200w4b', 'e1', 'S-1200', 'producao_restrita', 'p1200w4b', pg_temp.r1200('c4.trab'), pg_temp.origem('r_out')))::jsonb->>'situacao', 'criado',
  'período reaberto: o evento periódico volta a entrar');
SELECT is((SELECT versao FROM folha.esocial_event WHERE event_id = pg_temp.id('p1200w4b')), 2, 'a cadeia do w4 (versão 1 cancelada) segue na versão 2');
SELECT pg_temp.ok_(pg_temp.tx_a(format('SELECT folha.esocial_evento_cancelar_v1(%L::uuid, ''fora do cenário'')::text', pg_temp.id('p1200w4b'))), 'S-1200 do w4 cancelado de novo');
SELECT pg_temp.ok_(pg_temp.enf('p1299b', 'e1', 'S-1299', 'producao_restrita', 'p1299b', pg_temp.r1299()), 'novo S-1299 do período enfileirado');
SELECT is((SELECT ciclo || '/' || versao || '/' || (chave_negocio <> (SELECT chave_negocio FROM folha.esocial_event WHERE event_id = pg_temp.id('p1299')))
             FROM folha.esocial_event WHERE event_id = pg_temp.id('p1299b')), '2/1/true',
  'o novo fechamento é do ciclo 2, com chave própria (o fechamento anterior fica no histórico)');
SELECT matches(pg_temp.enf('p1298b', 'e1', 'S-1298', 'producao_restrita', 'p1298b', pg_temp.r1299()),
  '^ERRO 55000: O período 2026-10 não está fechado', 'só se reabre o que está fechado: com o ciclo 2 ainda sem fechamento validado, nova reabertura é recusada');
SELECT is(pg_temp.seq_plano(pg_temp.plano_periodo('e1', '2026-10-01')), 'S-1210@excluir > S-1210@excluir > S-1200@excluir > S-1200@excluir',
  'com o período aberto o plano não tem a reabertura');

-- ===========================================================================
-- 12. Retificação (exige o recibo do original)
-- ===========================================================================
SELECT matches(pg_temp.retif('rt1', 'x_s2200', 'x', 'motivo'), '^ERRO 55000: A retificação exige o evento validado com recibo \(estado atual: pendente_interno\)',
  'retificar evento sem recibo (não validado): recusado');
SELECT matches(pg_temp.retif('rt2', 'p1200w1', 'p1200w1', 'sem mudança'), '^ERRO 55000: O conteúdo de origem é idêntico', 'retificar com o mesmo conteúdo de origem: recusado (nada a retificar)');
SELECT matches(pg_temp.retif('rt3', 'p1200w1', 'p1200w1-v2', ''), '^ERRO 22023: esocial_evento_retificar_v1: motivo obrigatório', 'retificar sem motivo (aprovação registrada): recusado');
SELECT matches(pg_temp.enf('rt4', 'e1', 'S-1200', 'producao_restrita', 'p1200w1-v2', pg_temp.r1200('c1.trab'), pg_temp.origem('r_out')),
  '^ERRO 55000: Já existe versão validada desta chave com outra origem: a mudança é retificação', 'enfileirar conteúdo diferente sobre versão validada: só pela retificação');
SELECT is((pg_temp.enf('rt5', 'e1', 'S-1200', 'producao_restrita', 'p1200w1', pg_temp.r1200('c1.trab'), pg_temp.origem('r_out')))::jsonb->>'situacao', 'existente',
  'enfileirar o mesmo conteúdo da versão validada: existente (idempotência depois do aceite)');
SELECT pg_temp.ok_(pg_temp.retif('p1200w1_ret', 'p1200w1', 'p1200w1-v2', 'recálculo da folha de outubro'), 'retificação do S-1200 do w1 criada');
SELECT is((SELECT ind_retif || '/' || versao || '/' || estado || '/' || (retifica_event_id = pg_temp.id('p1200w1')) || '/' || criado_por_subject || '/' || motivo
             FROM folha.esocial_event WHERE event_id = pg_temp.id('p1200w1_ret')),
  '2/2/rascunho/true/83000000-0000-0000-0000-000000000031/recálculo da folha de outubro',
  'retificação: indRetif 2, versão 2, ligada ao original, com motivo e o subject de quem aprovou');
SELECT is((SELECT chave_negocio FROM folha.esocial_event WHERE event_id = pg_temp.id('p1200w1_ret')), (SELECT chave_negocio FROM folha.esocial_event WHERE event_id = pg_temp.id('p1200w1')),
  'a retificação tem a mesma chave de negócio do original');
SELECT is(pg_temp.est('p1200w1'), 'validado', 'o original segue validado até a retificação ser aceita');
SELECT is((SELECT count(*) FROM folha.esocial_event_origin WHERE event_id = pg_temp.id('p1200w1_ret') AND run_id = pg_temp.id('r_out')), 1::bigint, 'a folha de origem foi herdada pela retificação');
SELECT matches(pg_temp.retif('rt6', 'p1200w1', 'p1200w1-v3', 'segunda retificação ao mesmo tempo'), '^ERRO 55000: Já há versão deste evento em andamento',
  'duas retificações ao mesmo tempo: recusado');
SELECT pg_temp.ok_(pg_temp.ate_assinado('p1200w1_ret'), 'retificação gerada e assinada');
SELECT pg_temp.ok_(pg_temp.lote('L_ret1', 'p1200w1_ret'), 'lote da retificação enviado');
SELECT pg_temp.ok_(pg_temp.retorno('L_ret1', 'recebido', 'PROT-RET1', '201'), 'lote da retificação recebido');
SELECT pg_temp.ok_(pg_temp.retorno('L_ret1', 'processado', NULL, NULL, '[]'::jsonb, jsonb_build_array(pg_temp.res('p1200w1_ret', 'rejeitado', NULL,
    jsonb_build_array(jsonb_build_object('codigo', 'R1', 'descricao', 'rejeição de teste', 'gravidade', 'erro', 'localizacao', 'dmDev')), '<retornoRejeicao/>'))),
  'retificação rejeitada com ocorrência de erro e retorno guardado');
SELECT is(pg_temp.est('p1200w1_ret') || '/' || pg_temp.est('p1200w1'), 'rejeitado/validado', 'a retificação rejeitada não mexe no original validado');
SELECT is((SELECT count(*) FROM folha.esocial_event_occurrence WHERE event_id = pg_temp.id('p1200w1_ret') AND gravidade = 'erro' AND origem = 'evento'), 1::bigint, 'a ocorrência de erro ficou registrada');
SELECT pg_temp.ok_(pg_temp.retif('p1200w1_ret2', 'p1200w1', 'p1200w1-v3', 'segunda tentativa depois da rejeição'), 'nova retificação depois da rejeição');
SELECT is((SELECT versao FROM folha.esocial_event WHERE event_id = pg_temp.id('p1200w1_ret2')), 3, 'a nova retificação é a versão 3');
SELECT pg_temp.ok_(pg_temp.validar('p1200w1_ret2', 'REC-1200-W1B'), 'retificação validada');
SELECT is(pg_temp.est('p1200w1') || '/' || pg_temp.est('p1200w1_ret2'), 'retificado/validado', 'com a retificação aceita o original passa a retificado');
SELECT is((SELECT (SELECT recibo_numero FROM folha.esocial_event WHERE event_id = pg_temp.id('p1200w1')) || '/' || recibo_numero
             FROM folha.esocial_event WHERE event_id = pg_temp.id('p1200w1_ret2')), 'REC-1200-W1/REC-1200-W1B', 'o recibo do original fica guardado; a retificação tem o seu');
SELECT is((SELECT string_agg(versao || ':' || estado, ',' ORDER BY versao) FROM folha.esocial_event WHERE chave_negocio = (SELECT chave_negocio FROM folha.esocial_event WHERE event_id = pg_temp.id('p1200w1'))),
  '1:retificado,2:rejeitado,3:validado', 'o histórico da cadeia: original retificado, tentativa rejeitada e retificação validada');

-- ===========================================================================
-- 13. Exclusão (S-3000)
-- ===========================================================================
SELECT matches(pg_temp.excl('ex3', 'x_s2200', 'motivo'), '^ERRO 55000: A exclusão exige o evento validado com recibo \(estado atual: pendente_interno\)',
  'excluir evento sem recibo: recusado');
SELECT matches(pg_temp.excl('ex4', 't_s2200c1', 'tentativa'), '^ERRO 55000: O evento tem dependentes enviados \(S-1200\): exclua os dependentes antes',
  'excluir a admissão com S-1200 validado dependente: recusado (exclua os dependentes antes)');
SELECT matches(pg_temp.excl('ex5', 'p1210w2', ''), '^ERRO 22023: esocial_evento_excluir_v1: motivo obrigatório', 'excluir sem motivo: recusado');
SELECT pg_temp.ok_(pg_temp.excl('s3000_1210w2', 'p1210w2', 'pagamento lançado no CPF errado'), 'S-3000 do S-1210 do w2 criado');
SELECT is((SELECT evento_codigo || '/' || ind_retif || '/' || versao || '/' || estado || '/' || (exclui_event_id = pg_temp.id('p1210w2')) || '/' || criado_por_subject || '/' || motivo
             || '/' || (chave_negocio LIKE '%|ex=' || pg_temp.id('p1210w2')::text) FROM folha.esocial_event WHERE event_id = pg_temp.id('s3000_1210w2')),
  'S-3000/1/1/rascunho/true/83000000-0000-0000-0000-000000000031/pagamento lançado no CPF errado/true', 'S-3000: aponta para o evento excluído, com motivo, subject e chave própria');
SELECT is((pg_temp.excl('s3000_dup', 'p1210w2', 'pagamento lançado no CPF errado'))::jsonb->>'situacao', 'existente', 'excluir de novo enquanto o S-3000 está aberto: existente (idempotente)');
SELECT is(pg_temp.est('p1210w2'), 'validado', 'o evento excluído segue validado até o S-3000 ser aceito');
SELECT pg_temp.ok_(pg_temp.validar('s3000_1210w2', 'REC-3000-1'), 'S-3000 validado');
SELECT is(pg_temp.est('p1210w2') || '/' || (SELECT recibo_numero FROM folha.esocial_event WHERE event_id = pg_temp.id('p1210w2')), 'excluido/REC-1210-W2',
  'com o S-3000 aceito o evento passa a excluído e guarda o recibo');
SELECT matches(pg_temp.excl('ex6', 'p1210w2', 'de novo'), '^ERRO 55000: A exclusão exige o evento validado com recibo \(estado atual: excluido\)', 'não se exclui evento já excluído');
SELECT matches(pg_temp.retif('rt7', 's3000_1210w2', 'x', 'motivo'), '^ERRO 55000: O S-3000 não tem retificação', 'o S-3000 não se retifica');
SELECT is((pg_temp.enf('p1210w2b', 'e1', 'S-1210', 'producao_restrita', 'p1210w2', pg_temp.r1210('c2.trab'), pg_temp.origem('r_out')))::jsonb->>'situacao', 'criado',
  'depois da exclusão a mesma chave volta como inclusão nova (versão 2, indRetif 1)');
SELECT is((SELECT versao || '/' || ind_retif FROM folha.esocial_event WHERE event_id = pg_temp.id('p1210w2b')), '2/1', 'reinclusão depois da exclusão: versão 2 com indRetif 1');
SELECT pg_temp.ok_(pg_temp.enf('p1299b_dup', 'e1', 'S-1299', 'producao_restrita', 'p1299b', pg_temp.r1299()), 'enfileirar de novo o S-1299 do ciclo 2: idempotente');
SELECT matches(pg_temp.ate_assinado('p1299b'), '^ERRO 55000: Antecessor não validado: S-1210 \(nao_validado\)$',
  'a reinclusão pendente bloqueia o novo fechamento');
SELECT pg_temp.ok_(pg_temp.tx_a(format('SELECT folha.esocial_evento_cancelar_v1(%L::uuid, ''fora do cenário'')::text', pg_temp.id('p1210w2b'))), 'reinclusão cancelada');
SELECT pg_temp.ok_(pg_temp.passo('p1299b', 'gerado', '<fech2/>'), 'com a cadeia excluída e cancelada fora da conta, o novo fechamento passa a gerado (cadeia morta não bloqueia)');
-- ===========================================================================
-- 14. Retornos: rejeitado, duplicado, falha de comunicação, lote incorreto, reenvio, lote
-- ===========================================================================
SELECT pg_temp.ok_(pg_temp.enf('a1', 'e1', 'S-2230', 'producao_restrita', 'a1', pg_temp.rvinc('c1', '2026-05-01')), 'S-2230 a1 enfileirado');
SELECT pg_temp.ok_(pg_temp.enf('a2', 'e1', 'S-2230', 'producao_restrita', 'a2', pg_temp.rvinc('c1', '2026-05-02')), 'S-2230 a2 enfileirado');
SELECT pg_temp.ok_(pg_temp.enf('a3', 'e1', 'S-2230', 'producao_restrita', 'a3', pg_temp.rvinc('c1', '2026-05-03')), 'S-2230 a3 enfileirado');
SELECT pg_temp.ok_(pg_temp.enf('a4', 'e1', 'S-2230', 'producao_restrita', 'a4', pg_temp.rvinc('c1', '2026-05-04')), 'S-2230 a4 enfileirado');
SELECT pg_temp.ok_(pg_temp.enf('a5', 'e1', 'S-2230', 'producao_restrita', 'a5', pg_temp.rvinc('c1', '2026-05-05')), 'S-2230 a5 enfileirado');
SELECT pg_temp.ok_(pg_temp.enf('a6', 'e1', 'S-2230', 'producao_restrita', 'a6', pg_temp.rvinc('c1', '2026-05-06')), 'S-2230 a6 enfileirado');
SELECT pg_temp.ok_(pg_temp.enf('a7', 'e1', 'S-2230', 'producao_restrita', 'a7', pg_temp.rvinc('c1', '2026-05-07')), 'S-2230 a7 enfileirado (fica em rascunho)');
SELECT pg_temp.ok_(pg_temp.ate_assinado('a1'), 'a1 assinado');
SELECT pg_temp.ok_(pg_temp.ate_assinado('a2'), 'a2 assinado');
SELECT pg_temp.ok_(pg_temp.lote('L_a12', 'a1', 'a2'), 'lote com dois eventos enviado');
SELECT is((SELECT qtd_eventos || '/' || grupo FROM folha.esocial_lot WHERE lot_id = pg_temp.id('L_a12')), '2/nao_periodicos', 'o lote guarda a quantidade e o grupo');
SELECT is((SELECT count(*) FROM folha.esocial_lot_event WHERE lot_id = pg_temp.id('L_a12')), 2::bigint, 'a participação dos dois eventos no lote ficou registrada');
SELECT pg_temp.ok_(pg_temp.retorno('L_a12', 'recebido', 'PROT-A12', '201'), 'lote a12 recebido');
SELECT matches(pg_temp.retorno('L_a12', 'recebido', 'PROT-A12', '201'), '^ERRO 55000: Retorno recebido não cabe no lote em situação recebido', 'retorno repetido do mesmo tipo: recusado');
SELECT matches(pg_temp.retorno('L_a12', 'processado', NULL, NULL, '[]'::jsonb, jsonb_build_array(pg_temp.res('a1', 'rejeitado', NULL, jsonb_build_array(jsonb_build_object('codigo', 'R2', 'descricao', 'erro', 'gravidade', 'erro'))))),
  '^ERRO 22023: O retorno precisa trazer o resultado de todos os 2 eventos em processamento do lote \(vieram 1\)', 'retorno que não cobre todos os eventos do lote: recusado e desfeito');
SELECT is(pg_temp.est('a1') || '/' || pg_temp.est('a2'), 'em_processamento/em_processamento', 'a recusa desfez as mudanças parciais (a1 não ficou rejeitado)');
SELECT matches(pg_temp.retorno('L_a12', 'processado', NULL, NULL, '[]'::jsonb, jsonb_build_array(pg_temp.res('a1', 'validado', 'R'), pg_temp.res('a7', 'validado', 'R'))),
  '^ERRO 22023: Evento .* não está em processamento neste lote', 'resultado de evento que não é do lote: recusado');
SELECT matches(pg_temp.retorno('L_a12', 'processado', NULL, NULL, '[]'::jsonb, jsonb_build_array(pg_temp.res('a1', 'aceito', 'R'), pg_temp.res('a2', 'validado', 'R'))),
  '^ERRO 22023: Resultado do evento .* deve ser validado, rejeitado ou duplicado', 'resultado fora dos três previstos: recusado');
SELECT pg_temp.ok_(pg_temp.retorno('L_a12', 'processado', NULL, NULL, '[]'::jsonb, jsonb_build_array(
    pg_temp.res('a1', 'rejeitado', NULL, jsonb_build_array(jsonb_build_object('codigo', 'R3', 'descricao', 'rejeição a1', 'gravidade', 'erro', 'localizacao', 'ideVinculo')), '<ret a="1"/>'),
    pg_temp.res('a2', 'duplicado', NULL, jsonb_build_array(jsonb_build_object('codigo', 'D1', 'descricao', 'evento já existe', 'gravidade', 'erro'))))),
  'processado com um rejeitado e um duplicado');
SELECT is(pg_temp.est('a1') || '/' || pg_temp.est('a2'), 'rejeitado/duplicado', 'estados distintos: rejeitado e duplicado');
SELECT is((SELECT count(*) FROM folha.esocial_event_occurrence WHERE lot_id = pg_temp.id('L_a12') AND origem = 'evento' AND gravidade = 'erro'), 2::bigint, 'as ocorrências dos dois ficaram registradas');
SELECT is((SELECT count(*) FROM folha.esocial_event_payload WHERE event_id = pg_temp.id('a1') AND tipo = 'retorno_evento'), 1::bigint, 'o XML de retorno do rejeitado ficou guardado inteiro');
SELECT is((pg_temp.enf('a1b', 'e1', 'S-2230', 'producao_restrita', 'a1', pg_temp.rvinc('c1', '2026-05-01')))::jsonb->>'situacao', 'criado',
  'depois da rejeição o mesmo conteúdo volta como nova versão (o evento regenerado é versão nova)');
SELECT is((SELECT versao FROM folha.esocial_event WHERE event_id = pg_temp.id('a1b')), 2, 'nova versão 2 da cadeia do a1');

-- erro do servidor (301): reenviável, em outro lote, com a tentativa contada
SELECT pg_temp.ok_(pg_temp.ate_assinado('a3'), 'a3 assinado');
SELECT pg_temp.ok_(pg_temp.lote('L_a3', 'a3'), 'lote do a3 enviado');
SELECT matches(pg_temp.retorno('L_a3', 'erro_servidor', NULL, '201'), '^ERRO 22023: Resposta inválida', 'erro do servidor com o código 201: recusado');
SELECT pg_temp.ok_(pg_temp.retorno('L_a3', 'erro_servidor', NULL, '301', jsonb_build_array(jsonb_build_object('codigo', 'E301', 'descricao', 'erro do servidor', 'gravidade', 'erro'))), 'erro do servidor (301) registrado');
SELECT is(pg_temp.est('a3') || '/' || (SELECT situacao || '/' || codigo_resposta FROM folha.esocial_lot WHERE lot_id = pg_temp.id('L_a3')), 'falha_comunicacao/erro_servidor/301',
  'o evento fica em falha_comunicacao e o lote em erro_servidor (301)');
SELECT is((SELECT origem || '/' || gravidade FROM folha.esocial_event_occurrence WHERE event_id = pg_temp.id('a3')), 'lote/erro', 'a ocorrência do lote foi repetida no evento');
SELECT is((pg_temp.enf('a3x', 'e1', 'S-2230', 'producao_restrita', 'a3', pg_temp.rvinc('c1', '2026-05-03')))::jsonb->>'situacao', 'existente', 'enfileirar o mesmo conteúdo durante a falha: existente');
SELECT matches(pg_temp.enf('a3y', 'e1', 'S-2230', 'producao_restrita', 'a3-outro', pg_temp.rvinc('c1', '2026-05-03')),
  '^ERRO 55000: A versão 1 deste evento está em transmissão \(falha_comunicacao\): espere o retorno', 'conteúdo diferente durante a falha de comunicação: recusado (consultar antes de reenviar)');
SELECT pg_temp.ok_(pg_temp.passo('a3', 'assinado'), 'falha_comunicacao -> assinado (reenvio, mesmo XML assinado)');
SELECT is((SELECT lot_id IS NULL AND tentativas = 1 AND assinado_hash IS NOT NULL FROM folha.esocial_event WHERE event_id = pg_temp.id('a3')), true, 'volta sem lote, com a tentativa 1 e o mesmo hash assinado');
SELECT pg_temp.ok_(pg_temp.lote('L_a3b', 'a3'), 'reenvio do a3 em outro lote');
SELECT is((SELECT tentativas FROM folha.esocial_event WHERE event_id = pg_temp.id('a3')), 2, 'segunda tentativa contada');
SELECT is((SELECT count(*) FROM folha.esocial_lot_event WHERE event_id = pg_temp.id('a3')), 2::bigint, 'o histórico guarda os dois lotes do evento');
SELECT pg_temp.ok_(pg_temp.retorno('L_a3b', 'recebido', 'PROT-A3B', '201'), 'segundo lote recebido');
SELECT pg_temp.ok_(pg_temp.retorno('L_a3b', 'processado', NULL, NULL, '[]'::jsonb, jsonb_build_array(pg_temp.res('a3', 'validado', 'REC-A3'))), 'a3 validado depois do reenvio');
SELECT is((SELECT situacao FROM folha.esocial_lot WHERE lot_id = pg_temp.id('L_a3')), 'erro_servidor', 'o lote antigo continua como erro_servidor (histórico)');
-- sem resposta
SELECT pg_temp.ok_(pg_temp.ate_assinado('a4'), 'a4 assinado');
SELECT pg_temp.ok_(pg_temp.lote('L_a4', 'a4'), 'lote do a4 enviado');
SELECT matches(pg_temp.retorno('L_a4', 'sem_resposta', NULL, '301'), '^ERRO 22023: Resposta inválida', 'sem resposta não tem código');
SELECT pg_temp.ok_(pg_temp.retorno('L_a4', 'sem_resposta'), 'lote sem resposta registrado');
SELECT is(pg_temp.est('a4') || '/' || (SELECT situacao FROM folha.esocial_lot WHERE lot_id = pg_temp.id('L_a4')), 'falha_comunicacao/sem_resposta', 'sem resposta: o evento fica em falha_comunicacao');
-- lote incorreto (401/402): não se reenvia o mesmo lote
SELECT pg_temp.ok_(pg_temp.ate_assinado('a5'), 'a5 assinado');
SELECT pg_temp.ok_(pg_temp.lote('L_a5', 'a5'), 'lote do a5 enviado');
SELECT matches(pg_temp.retorno('L_a5', 'lote_incorreto', NULL, '301'), '^ERRO 22023: Resposta inválida', 'lote incorreto com o código 301: recusado');
SELECT matches(pg_temp.retorno('L_a5', 'lote_incorreto', NULL, '401'), '^ERRO 22023: Lote incorreto exige ao menos uma ocorrência de erro', 'lote incorreto sem ocorrência de erro: recusado');
SELECT is(pg_temp.est('a5'), 'enviado', 'a recusa deixou o evento como estava');
SELECT pg_temp.ok_(pg_temp.retorno('L_a5', 'lote_incorreto', NULL, '402', jsonb_build_array(jsonb_build_object('codigo', 'L402', 'descricao', 'lote incorreto', 'gravidade', 'erro'))), 'lote incorreto (402) registrado');
SELECT is(pg_temp.est('a5') || '/' || (SELECT situacao || '/' || codigo_resposta FROM folha.esocial_lot WHERE lot_id = pg_temp.id('L_a5')), 'rejeitado/lote_incorreto/402',
  'lote incorreto: o evento é rejeitado (não reenvia o mesmo lote) e o lote guarda o código');
SELECT is((SELECT origem FROM folha.esocial_event_occurrence WHERE event_id = pg_temp.id('a5')), 'lote', 'a ocorrência do lote ficou no evento');
-- protocolo único e limites do lote
SELECT pg_temp.ok_(pg_temp.ate_assinado('a6'), 'a6 assinado');
SELECT pg_temp.ok_(pg_temp.lote('L_a6', 'a6'), 'lote do a6 enviado');
SELECT matches(pg_temp.retorno('L_a6', 'recebido', 'PROT-A12', '201'), '^ERRO 23505: ', 'protocolo repetido na mesma conta e ambiente: recusado (único)');
SELECT pg_temp.ok_(pg_temp.retorno('L_a6', 'recebido', 'PROT-A6', '201'), 'protocolo novo aceito');
SELECT pg_temp.ok_(pg_temp.retorno('L_a6', 'processado', NULL, NULL, '[]'::jsonb, jsonb_build_array(pg_temp.res('a6', 'validado', 'REC-A6'))), 'a6 validado');
SELECT matches(pg_temp.tx_a(format('SELECT folha.esocial_lote_enviar_v1(%L::uuid, ''producao_restrita'', (SELECT array_agg(gen_random_uuid()) FROM generate_series(1, 51)))::text', pg_temp.id('e1'))),
  '^ERRO 22023: Um lote tem de 1 a 50 eventos', 'mais de 50 eventos num lote: recusado');
SELECT matches(pg_temp.tx_a(format('SELECT folha.esocial_lote_enviar_v1(%L::uuid, ''producao_restrita'', ARRAY[]::uuid[])::text', pg_temp.id('e1'))),
  '^ERRO 22023: Um lote tem de 1 a 50 eventos', 'lote vazio: recusado');
SELECT matches(pg_temp.tx_a(format('SELECT folha.esocial_lote_enviar_v1(%L::uuid, ''producao_restrita'', ARRAY[%L::uuid, %L::uuid])::text', pg_temp.id('e1'), pg_temp.id('a7'), pg_temp.id('a7'))),
  '^ERRO 22023: Evento repetido na lista do lote', 'evento repetido na lista: recusado');
SELECT matches(pg_temp.lote('L_x', 'a7'), '^ERRO 55000: Todos os eventos do lote precisam ser', 'evento ainda em rascunho (não assinado) no lote: recusado');
SELECT pg_temp.ok_(pg_temp.ate_assinado('a7'), 'a7 assinado');
SELECT matches(pg_temp.tx_a(format('SELECT folha.esocial_lote_enviar_v1(%L::uuid, ''producao_restrita'', ARRAY[%L::uuid])::text', pg_temp.id('e2'), pg_temp.id('a7'))),
  '^ERRO 55000: Todos os eventos do lote precisam ser', 'evento de outro empregador no lote: recusado');
SELECT matches(pg_temp.tx_a(format('SELECT folha.esocial_lote_enviar_v1(%L::uuid, ''producao'', ARRAY[%L::uuid])::text', pg_temp.id('e1'), pg_temp.id('a7'))),
  '^ERRO 55000: Todos os eventos do lote precisam ser', 'evento de outro ambiente no lote: recusado');
SELECT pg_temp.ok_(pg_temp.enf('rub2', 'e1', 'S-1010', 'producao_restrita', 'rub2', jsonb_build_object('codigo_tabela', 'RUB2', 'inicio_validade', '2026-06-01')), 'S-1010 RUB2 enfileirado');
SELECT pg_temp.ok_(pg_temp.ate_assinado('rub2'), 'S-1010 RUB2 assinado');
SELECT matches(pg_temp.lote('L_mix2', 'rub2', 'a7'), '^ERRO 55000: Um lote tem um só grupo de eventos', 'grupos diferentes no mesmo lote: recusado');
SELECT is((SELECT count(*) FROM folha.esocial_lot_event WHERE event_id IN (pg_temp.id('rub2'), pg_temp.id('a7'))), 0::bigint, 'as recusas de lote não deixaram participação');
SELECT matches(pg_temp.tx_a(format('SELECT folha.esocial_producao_definir_v1(%L::uuid, true, '' '')::text', pg_temp.id('e1'))), '^ERRO 22023: esocial_producao_definir_v1: informe liberada e o motivo', 'liberar produção sem motivo: recusado');
SELECT matches(pg_temp.adm_a(format('SELECT folha.esocial_producao_definir_v1(%L::uuid, true, ''x'')::text', gen_random_uuid())), '^ERRO 22023: Empregador .* não encontrado nesta conta', 'liberar produção de empregador inexistente: recusado');
SELECT matches(pg_temp.tx_a(format('SELECT folha.esocial_evento_cancelar_v1(%L::uuid, ''x'')::text', pg_temp.id('t_s1000_v2'))), '^ERRO 55000: Só se cancela evento ainda não enviado \(estado atual: validado\)', 'cancelar evento já validado: recusado');
SELECT matches(pg_temp.tx_a(format('SELECT folha.esocial_evento_cancelar_v1(%L::uuid, '' '')::text', pg_temp.id('a7'))), '^ERRO 22023: esocial_evento_cancelar_v1: motivo obrigatório', 'cancelar sem motivo: recusado');

-- ===========================================================================
-- 15. Imutabilidade e gatilhos por DML direto (o login de teste recebe, só aqui, privilégio de gravação)
-- ===========================================================================
SELECT pg_temp.ok_(pg_temp.enf('d1', 'e1', 'S-2230', 'producao_restrita', 'd1', pg_temp.rvinc('c1', '2026-05-08')), 'S-2230 d1 enfileirado (rascunho)');
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON folha.esocial_event, folha.esocial_lot, folha.esocial_lot_event, folha.esocial_event_payload,
  folha.esocial_event_occurrence, folha.esocial_event_origin, folha.esocial_employer_setting TO dnex_folha_ci_login;
-- a 0032 tem tabela que referencia esocial_event: o TRUNCATE ... CASCADE alcança a tabela e pede o privilégio nela
GRANT TRUNCATE ON folha.esocial_entrada TO dnex_folha_ci_login;
-- Com a RLS só de leitura o login de teste não escreve (nem os gatilhos disparariam): para exercer os gatilhos
-- por DML direto ele ganha, só aqui e dentro da transação do teste, uma policy de escrita em cada tabela.
DO $$
DECLARE v text;
BEGIN
  FOREACH v IN ARRAY ARRAY['esocial_event', 'esocial_lot', 'esocial_lot_event', 'esocial_event_payload', 'esocial_event_occurrence',
                           'esocial_event_origin', 'esocial_employer_setting']
  LOOP
    EXECUTE format('CREATE POLICY ci_escrita_temporaria ON folha.%I FOR ALL TO dnex_folha_ci_login USING (true) WITH CHECK (true)', v);
  END LOOP;
END
$$;
CREATE FUNCTION pg_temp.dml(p_dml text) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.faz(pg_temp.ca(), pg_temp.todas(), '82000000-0000-0000-0000-000000000031'::uuid, p_dml, 'SELECT ''ok''') $$;
SELECT matches(pg_temp.dml(format('UPDATE folha.esocial_event SET payload_hash = repeat(''a'', 64) WHERE event_id = %L', pg_temp.id('t_s1000_v2'))),
  '^ERRO 55000: .*payload e hash são imutáveis depois de gerado', 'o hash do XML gerado não muda depois de gerado');
SELECT matches(pg_temp.dml(format('UPDATE folha.esocial_event SET assinado_hash = repeat(''a'', 64) WHERE event_id = %L', pg_temp.id('t_s1000_v2'))),
  '^ERRO 55000: .*payload e hash são imutáveis depois de gerado', 'o hash do XML assinado não muda');
SELECT matches(pg_temp.dml(format('UPDATE folha.esocial_event SET recibo_numero = ''OUTRO'' WHERE event_id = %L', pg_temp.id('t_s1000_v2'))),
  '^ERRO 55000: .*só mudam numa transição de estado', 'o recibo não muda fora de uma transição');
SELECT matches(pg_temp.dml(format('UPDATE folha.esocial_event SET chave_negocio = ''outra'' WHERE event_id = %L', pg_temp.id('t_s1000_v2'))),
  '^ERRO 55000: A identidade do evento', 'a chave de negócio não muda');
SELECT matches(pg_temp.dml(format('UPDATE folha.esocial_event SET criado_por_subject = gen_random_uuid() WHERE event_id = %L', pg_temp.id('t_s1000_v2'))),
  '^ERRO 55000: A identidade do evento', 'o subject de criação não muda');
SELECT matches(pg_temp.dml(format('UPDATE folha.esocial_event SET estado = ''cancelado'' WHERE event_id = %L', pg_temp.id('t_s1000_v2'))),
  '^ERRO 55000: Transição inválida do evento: de validado para cancelado', 'validado não se cancela');
SELECT matches(pg_temp.dml(format('UPDATE folha.esocial_event SET estado = ''validado'' WHERE event_id = %L', pg_temp.id('d1'))),
  '^ERRO 55000: Transição inválida do evento: de rascunho para validado', 'rascunho -> validado: transição inválida');
SELECT matches(pg_temp.dml(format('UPDATE folha.esocial_event SET estado = ''retificado'' WHERE event_id = %L', pg_temp.id('p1210w1'))),
  '^ERRO 55000: Só passa a retificado quando a retificação foi validada', 'retificado sem retificação validada: recusado');
SELECT matches(pg_temp.dml(format('UPDATE folha.esocial_event SET estado = ''excluido'' WHERE event_id = %L', pg_temp.id('p1210w1'))),
  '^ERRO 55000: Só passa a excluído quando o S-3000 foi validado', 'excluído sem S-3000 validado: recusado');
SELECT matches(pg_temp.dml(format('UPDATE folha.esocial_event SET estado = ''gerado'', payload_hash = repeat(''b'', 64) WHERE event_id = %L', pg_temp.id('x_s2200'))),
  '^ERRO 55000: XML gerado ausente ou com hash diferente do guardado', 'gerado sem o XML guardado: recusado');
SELECT matches(pg_temp.dml(format('UPDATE folha.esocial_event SET estado = ''pendente_interno'', recibo_numero = ''REC-X'' WHERE event_id = %L', pg_temp.id('d1'))),
  '^ERRO 55000: O recibo só é gravado no retorno que valida o evento', 'recibo fora do retorno que valida: recusado');
SELECT matches(pg_temp.dml(format('UPDATE folha.esocial_event SET estado = ''pendente_interno'', lot_id = %L WHERE event_id = %L', pg_temp.id('L_a6'), pg_temp.id('d1'))),
  '^ERRO 55000: O lote do evento só muda ao enviar', 'lote do evento fora do envio: recusado');
SELECT matches(pg_temp.dml(format($i$INSERT INTO folha.esocial_event (account_id, employer_id, evento_codigo, ambiente, estado, codigo_tabela, inicio_validade, chave_negocio, versao, origem_hash, criado_por_subject, atualizado_por_subject)
    VALUES (%L, %L, 'S-1070', 'producao_restrita', 'validado', 'PROC1', '2026-01-01', 'x', 1, repeat('c', 64), gen_random_uuid(), gen_random_uuid())$i$, pg_temp.ca(), pg_temp.id('e1'))),
  '^ERRO 55000: O evento nasce em rascunho', 'inserir direto em outro estado que rascunho: recusado');
SELECT matches(pg_temp.dml(format($i$INSERT INTO folha.esocial_event (account_id, employer_id, evento_codigo, ambiente, chave_negocio, versao, origem_hash, criado_por_subject, atualizado_por_subject)
    VALUES (%L, %L, 'S-5001', 'producao_restrita', 'x', 1, repeat('c', 64), gen_random_uuid(), gen_random_uuid())$i$, pg_temp.ca(), pg_temp.id('e1'))),
  '^ERRO 22023: O evento S-5001 não pode ser enfileirado', 'inserir direto um totalizador (retorno do governo): recusado');
SELECT is(pg_temp.dml(format($i$INSERT INTO folha.esocial_event (account_id, employer_id, evento_codigo, ambiente, codigo_tabela, inicio_validade, chave_negocio, versao, origem_hash, payload_hash, recibo_numero, criado_por_subject, atualizado_por_subject)
    VALUES (%L, %L, 'S-1070', 'producao_restrita', 'PROC1', '2026-01-01', 'forjada', 7, repeat('c', 64), repeat('d', 64), 'REC-FORJADO', gen_random_uuid(), gen_random_uuid())$i$, pg_temp.ca(), pg_temp.id('e1'))),
  'ok', 'inserir direto uma linha válida funciona');
SELECT is((SELECT criado_por_subject || '/' || (payload_hash IS NULL) || '/' || (recibo_numero IS NULL) || '/' || versao || '/' || chave_negocio
             FROM folha.esocial_event WHERE employer_id = pg_temp.id('e1') AND evento_codigo = 'S-1070'),
  '82000000-0000-0000-0000-000000000031/true/true/1/S-1070|cod=PROC1|iv=2026-01-01|tr=|vi=|de=|ap=|pe=|ci=|ex=',
  'o gatilho grava o subject do contexto, zera hash e recibo informados e recalcula versão e chave (nada forjado entra)');
SELECT matches(pg_temp.dml(format($i$INSERT INTO folha.esocial_event (account_id, employer_id, evento_codigo, ambiente, codigo_tabela, inicio_validade, chave_negocio, versao, origem_hash, criado_por_subject, atualizado_por_subject)
    VALUES (%L, %L, 'S-1070', 'producao_restrita', 'PROC2', '2026-01-01', 'x', 1, repeat('c', 64), gen_random_uuid(), gen_random_uuid())$i$, pg_temp.ca(), pg_temp.id('eb'))),
  '^ERRO 23503: ', 'inserir da conta A com empregador da conta B: a chave estrangeira composta recusa');
SELECT matches(pg_temp.dml(format('DELETE FROM folha.esocial_event WHERE event_id = %L', pg_temp.id('d1'))), '^ERRO 55000: folha.esocial_event é histórico: DELETE é proibido', 'o evento não se apaga');
SELECT matches(pg_temp.dml('TRUNCATE folha.esocial_event CASCADE'), '^ERRO 55000: folha\.esocial_[a-z_]+: TRUNCATE é proibido', 'a fila não se esvazia (TRUNCATE em cascata recusado por gatilho)');
SELECT matches(pg_temp.dml('TRUNCATE folha.esocial_event_occurrence'), '^ERRO 55000: folha.esocial_event_occurrence: TRUNCATE é proibido', 'as ocorrências não se esvaziam');
SELECT matches(pg_temp.dml('TRUNCATE folha.esocial_employer_setting'), '^ERRO 55000: folha.esocial_employer_setting: TRUNCATE é proibido', 'a liberação de produção não se esvazia');
SELECT matches(pg_temp.dml(format('UPDATE folha.esocial_event_payload SET conteudo = ''x'' WHERE event_id = %L', pg_temp.id('t_s1000_v2'))), '^ERRO 55000: folha.esocial_event_payload é histórico: UPDATE é proibido', 'o conteúdo do XML não se altera');
SELECT matches(pg_temp.dml(format('DELETE FROM folha.esocial_event_payload WHERE event_id = %L', pg_temp.id('t_s1000_v2'))), '^ERRO 55000: folha.esocial_event_payload é histórico: DELETE é proibido', 'o conteúdo do XML não se apaga');
SELECT matches(pg_temp.dml('TRUNCATE folha.esocial_event_payload'), '^ERRO 55000: folha.esocial_event_payload: TRUNCATE é proibido', 'o conteúdo do XML não se esvazia');
SELECT matches(pg_temp.dml(format($i$INSERT INTO folha.esocial_event_payload (account_id, event_id, tipo, conteudo, conteudo_hash, criado_por_subject)
    VALUES (%L, %L, 'evento', '<x/>', repeat('0', 64), gen_random_uuid())$i$, pg_temp.ca(), pg_temp.id('t_s1000_v2'))),
  '^ERRO 55000: Conteúdo do tipo evento não cabe no estado validado do evento', 'XML gerado de evento que já passou de pendente_interno: recusado');
SELECT pg_temp.ok_(pg_temp.passo('d1', 'pendente_interno'), 'd1 em pendente_interno');
SELECT is(pg_temp.dml(format($i$INSERT INTO folha.esocial_event_payload (account_id, event_id, tipo, conteudo, conteudo_hash, criado_por_subject)
    VALUES (%L, %L, 'evento', '<d1 forjado="1"/>', repeat('f', 64), gen_random_uuid())$i$, pg_temp.ca(), pg_temp.id('d1'))), 'ok', 'XML do d1 gravado direto com hash e subject informados');
SELECT is((SELECT conteudo_hash = pg_temp.h('<d1 forjado="1"/>') AND criado_por_subject = '82000000-0000-0000-0000-000000000031'::uuid
             FROM folha.esocial_event_payload WHERE event_id = pg_temp.id('d1')), true, 'o banco recalcula o hash e grava o subject do contexto (o informado é ignorado)');
SELECT pg_temp.ok_(pg_temp.tx_a(format('SELECT folha.esocial_evento_cancelar_v1(%L::uuid, ''fim do teste de DML'')::text', pg_temp.id('d1'))), 'd1 cancelado');
SELECT matches(pg_temp.dml(format('UPDATE folha.esocial_event_occurrence SET descricao = ''x'' WHERE event_id = %L', pg_temp.id('a1'))), '^ERRO 55000: folha.esocial_event_occurrence é histórico: UPDATE é proibido', 'ocorrência não se altera');
SELECT matches(pg_temp.dml(format('DELETE FROM folha.esocial_event_occurrence WHERE event_id = %L', pg_temp.id('a1'))), '^ERRO 55000: folha.esocial_event_occurrence é histórico: DELETE é proibido', 'ocorrência não se apaga');
SELECT matches(pg_temp.dml(format($i$INSERT INTO folha.esocial_event_occurrence (account_id, event_id, lot_id, codigo, descricao, gravidade, origem, criado_por_subject)
    VALUES (%L, %L, %L, 'X', 'x', 'erro', 'lote', gen_random_uuid())$i$, pg_temp.ca(), pg_temp.id('x_s2200'), pg_temp.id('L_t1'))),
  '^ERRO 55000: O evento não participou do lote da ocorrência', 'ocorrência de lote em que o evento não esteve: recusada');
SELECT matches(pg_temp.dml(format('UPDATE folha.esocial_event_origin SET run_id = run_id WHERE event_id = %L', pg_temp.id('p1200w1'))), '^ERRO 55000: folha.esocial_event_origin é histórico: UPDATE é proibido', 'origem não se altera');
SELECT matches(pg_temp.dml(format('INSERT INTO folha.esocial_event_origin (account_id, event_id, run_id) VALUES (%L, %L, %L)', pg_temp.ca(), pg_temp.id('p1200w1'), pg_temp.id('r_nov'))),
  '^ERRO 55000: A origem só se registra enquanto o evento é rascunho ou pendente interno', 'origem nova em evento que já foi adiante: recusada');
SELECT matches(pg_temp.dml(format('DELETE FROM folha.esocial_lot_event WHERE lot_id = %L', pg_temp.id('L_a12'))), '^ERRO 55000: folha.esocial_lot_event é histórico: DELETE é proibido', 'participação em lote não se apaga');
SELECT matches(pg_temp.dml(format('INSERT INTO folha.esocial_lot_event (account_id, lot_id, event_id) VALUES (%L, %L, %L)', pg_temp.ca(), pg_temp.id('L_t1'), pg_temp.id('a7'))),
  '^ERRO 55000: O lote só recebe evento assinado', 'evento posto em lote já processado: recusado');
SELECT matches(pg_temp.dml(format('UPDATE folha.esocial_lot SET situacao = ''recebido'', protocolo = ''X'', codigo_resposta = ''201'' WHERE lot_id = %L', pg_temp.id('L_a5'))),
  '^ERRO 55000: Transição inválida do lote: de lote_incorreto para recebido', 'lote incorreto não volta a recebido');
SELECT matches(pg_temp.dml(format('UPDATE folha.esocial_lot SET protocolo = ''OUTRO'' WHERE lot_id = %L', pg_temp.id('L_a12'))),
  '^ERRO 55000: Protocolo e resposta do lote só mudam numa transição de situação', 'o protocolo do lote não muda fora de uma transição');
SELECT matches(pg_temp.dml(format('UPDATE folha.esocial_lot SET qtd_eventos = 3 WHERE lot_id = %L', pg_temp.id('L_a12'))), '^ERRO 55000: A identidade do lote é imutável', 'a identidade do lote não muda');
SELECT matches(pg_temp.dml(format('DELETE FROM folha.esocial_lot WHERE lot_id = %L', pg_temp.id('L_a12'))), '^ERRO 55000: folha.esocial_lot é histórico: DELETE é proibido', 'o lote não se apaga');
SELECT matches(pg_temp.faz(pg_temp.ca(), ARRAY['folha.read', 'folha.transmit'], '82000000-0000-0000-0000-000000000031'::uuid,
    'UPDATE folha.esocial_employer_setting SET producao_liberada = true', 'SELECT ''ok'''),
  '^ERRO 42501: ', 'mudar a liberação de produção por DML sem folha.admin: recusado pelo gatilho');
SELECT matches(pg_temp.faz(pg_temp.ca(), NULL, NULL, format('UPDATE folha.esocial_event SET updated_at = now() WHERE event_id = %L', pg_temp.id('t_s1000_v2')), 'SELECT ''ok'''),
  '^ERRO 42501: ', 'DML direto sem o contexto da Folha: recusado pelo gatilho (42501)');
SELECT matches(pg_temp.faz(pg_temp.ca(), ARRAY['folha.read'], '82000000-0000-0000-0000-000000000031'::uuid, format('UPDATE folha.esocial_event SET updated_at = now() WHERE event_id = %L', pg_temp.id('t_s1000_v2')), 'SELECT ''ok'''),
  '^ERRO 42501: ', 'DML direto só com folha.read: recusado (exige folha.transmit)');
DO $$
DECLARE v text;
BEGIN
  FOREACH v IN ARRAY ARRAY['esocial_event', 'esocial_lot', 'esocial_lot_event', 'esocial_event_payload', 'esocial_event_occurrence',
                           'esocial_event_origin', 'esocial_employer_setting']
  LOOP
    EXECUTE format('DROP POLICY ci_escrita_temporaria ON folha.%I', v);
  END LOOP;
END
$$;
REVOKE ALL ON folha.esocial_event, folha.esocial_lot, folha.esocial_lot_event, folha.esocial_event_payload,
  folha.esocial_event_occurrence, folha.esocial_event_origin, folha.esocial_employer_setting FROM dnex_folha_ci_login;
REVOKE ALL ON folha.esocial_entrada FROM dnex_folha_ci_login;
SELECT is_empty(
  $$SELECT k.relname FROM pg_class k WHERE k.relnamespace = 'folha'::regnamespace AND k.relname LIKE 'esocial\_%' AND k.relkind = 'r'
      AND (has_table_privilege('dnex_folha_ci_login', k.oid, 'UPDATE') OR has_table_privilege('dnex_folha_ci_login', k.oid, 'INSERT'))$$,
  'o privilégio de teste foi desfeito (o login de teste volta a não ter acesso às tabelas)');
SELECT is((SELECT count(*) FROM pg_policies p JOIN tabelas t ON t.nome = p.tablename WHERE p.schemaname = 'folha'), 12::bigint,
  'as policies temporárias de teste foram desfeitas (uma policy por tabela, como antes)');

-- ===========================================================================
-- 16. Isolamento entre contas
-- ===========================================================================
-- As policies reais são TO worker/data_owner (o login de teste não é membro de nenhum dos dois). Para ler como
-- sessão com contexto, o login ganha, só aqui, uma policy de leitura com o MESMO predicado das reais (conferido
-- na seção 2): o que se prova abaixo é o isolamento por conta do predicado.
DO $$
DECLARE v text;
BEGIN
  FOREACH v IN ARRAY ARRAY['esocial_event', 'esocial_lot', 'esocial_lot_event', 'esocial_event_payload', 'esocial_event_occurrence',
                           'esocial_event_origin', 'esocial_employer_setting']
  LOOP
    EXECUTE format('CREATE POLICY ci_leitura_temporaria ON folha.%I FOR SELECT TO dnex_folha_ci_login USING (account_id = (SELECT folha.current_account_id()))', v);
  END LOOP;
END
$$;
SELECT pg_temp.ok_(pg_temp.tx_b(format('SELECT folha.esocial_evento_enfileirar_v1(%L::uuid, ''S-1000'', ''producao_restrita'', %L, ''{"inicio_validade":"2026-01-01"}''::jsonb)::text',
    pg_temp.id('eb'), pg_temp.h('b1'))), 'a conta B enfileira para o próprio empregador');
SELECT matches(pg_temp.tx_b(format('SELECT folha.esocial_evento_enfileirar_v1(%L::uuid, ''S-1000'', ''producao_restrita'', %L, ''{"inicio_validade":"2026-01-01"}''::jsonb)::text',
    pg_temp.id('e1'), pg_temp.h('b2'))), '^ERRO 22023: Empregador .* não encontrado nesta conta', 'a conta B não enfileira para empregador da conta A');
SELECT matches(pg_temp.tx_b(format('SELECT folha.esocial_evento_enfileirar_v1(%L::uuid, ''S-2200'', ''producao_restrita'', %L, jsonb_build_object(''contract_id'', %L::uuid))::text',
    pg_temp.id('eb'), pg_temp.h('b3'), pg_temp.id('c1'))), '^ERRO 22023: Contrato .* não é deste empregador', 'a conta B não usa contrato da conta A');
SELECT matches(pg_temp.tx_b(format('SELECT folha.esocial_evento_avancar_v1(%L::uuid, ''pendente_interno'')::text', pg_temp.id('a7'))), '^ERRO P0002: Evento .* não encontrado', 'a conta B não avança evento da conta A');
SELECT matches(pg_temp.tx_b(format('SELECT folha.esocial_evento_cancelar_v1(%L::uuid, ''x'')::text', pg_temp.id('a7'))), '^ERRO P0002: Evento .* não encontrado', 'a conta B não cancela evento da conta A');
SELECT matches(pg_temp.tx_b(format('SELECT folha.esocial_evento_retificar_v1(%L::uuid, %L, ''x'')::text', pg_temp.id('t_s1000_v2'), pg_temp.h('z'))), '^ERRO P0002: Evento .* não encontrado', 'a conta B não retifica evento da conta A');
SELECT matches(pg_temp.tx_b(format('SELECT folha.esocial_evento_excluir_v1(%L::uuid, ''x'')::text', pg_temp.id('t_s1000_v2'))), '^ERRO P0002: Evento .* não encontrado', 'a conta B não exclui evento da conta A');
SELECT matches(pg_temp.tx_b(format('SELECT folha.esocial_lote_retorno_v1(%L::uuid, ''recebido'', ''P'', ''201'')::text', pg_temp.id('L_a12'))), '^ERRO P0002: Lote .* não encontrado', 'a conta B não registra retorno de lote da conta A');
SELECT matches(pg_temp.tx_b(format('SELECT folha.esocial_lote_enviar_v1(%L::uuid, ''producao_restrita'', ARRAY[%L::uuid])::text', pg_temp.id('eb'), pg_temp.id('a7'))),
  '^ERRO 55000: Todos os eventos do lote precisam ser', 'a conta B não põe evento da conta A em lote');
SELECT matches(pg_temp.lei_b(format('SELECT folha.esocial_desfazer_plano_v1(%L::uuid, ''producao_restrita'', ''2026-10-01''::date)::text', pg_temp.id('e1'))),
  '^ERRO 22023: Empregador .* não encontrado nesta conta', 'a conta B não pede o plano de desfazer do empregador da conta A');
SELECT matches(pg_temp.lei_b(format('SELECT folha.esocial_conferencia_v1(%L::uuid)::text', pg_temp.id('e1'))),
  '^ERRO 22023: Empregador .* não encontrado nesta conta', 'a conta B não pede a conferência do empregador da conta A');
SELECT is(pg_temp.com_espelho(pg_temp.cb(), pg_temp.todas(), '84000000-0000-0000-0000-000000000031'::uuid, 'SELECT count(*)::text FROM folha.esocial_event'), '1',
  'RLS: a conta B enxerga só o evento dela na fila');
SELECT is(pg_temp.com_espelho(pg_temp.ca(), pg_temp.todas(), '82000000-0000-0000-0000-000000000031'::uuid, 'SELECT count(*)::text FROM folha.esocial_event'),
  (SELECT count(*)::text FROM folha.esocial_event WHERE account_id = pg_temp.ca()), 'RLS: a conta A enxerga todos os eventos dela e nenhum da B');
SELECT is(pg_temp.com_espelho(pg_temp.cb(), pg_temp.todas(), '84000000-0000-0000-0000-000000000031'::uuid,
    'SELECT (SELECT count(*) FROM folha.esocial_event_payload) || ''/'' || (SELECT count(*) FROM folha.esocial_lot) || ''/'' || (SELECT count(*) FROM folha.esocial_event_occurrence)
       || ''/'' || (SELECT count(*) FROM folha.esocial_employer_setting) || ''/'' || (SELECT count(*) FROM folha.esocial_event_origin) || ''/'' || (SELECT count(*) FROM folha.esocial_lot_event)'),
  '0/0/0/0/0/0', 'RLS: a conta B não enxerga conteúdo, lotes, ocorrências, liberações, origens nem participações da A');
SELECT is(pg_temp.com_espelho(pg_temp.cb(), pg_temp.todas(), '84000000-0000-0000-0000-000000000031'::uuid,
    'SELECT string_agg(DISTINCT employer_id::text, '','') FROM folha.v_esocial_conferencia'), pg_temp.id('eb')::text, 'a visão de conferência da conta B só mostra o empregador dela');
SELECT is(pg_temp.com_espelho(pg_temp.ca(), pg_temp.todas(), '82000000-0000-0000-0000-000000000031'::uuid,
    'SELECT string_agg(DISTINCT employer_id::text, '','' ORDER BY employer_id::text) FROM folha.v_esocial_conferencia'),
  (SELECT string_agg(DISTINCT employer_id::text, ',' ORDER BY employer_id::text) FROM folha.esocial_event WHERE account_id = pg_temp.ca()), 'a visão da conta A mostra os empregadores dela');
SELECT is(pg_temp.com_espelho(NULL, NULL, NULL, 'SELECT count(*)::text FROM folha.esocial_event'), '0', 'sem contexto da Folha a RLS esconde todas as linhas');

-- ===========================================================================
-- 17. Conferência por empregador e período (painel de fechamento)
-- ===========================================================================
CREATE FUNCTION pg_temp.visao(p_emp_k text, p_per text) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.com_espelho(pg_temp.ca(), pg_temp.todas(), '82000000-0000-0000-0000-000000000031'::uuid,
    format('SELECT concat_ws(''/'', eventos, pendentes, em_transmissao, rejeitados, validados, com_advertencia, bloqueados_antecessor)
              FROM folha.v_esocial_conferencia WHERE employer_id = %L AND ambiente = ''producao_restrita'' AND periodo_apuracao %s',
           pg_temp.id(p_emp_k), CASE WHEN p_per IS NULL THEN 'IS NULL' ELSE '= ' || quote_literal(p_per) END)) $$;
CREATE FUNCTION pg_temp.conf(p_emp_k text, p_per text DEFAULT NULL, p_amb text DEFAULT NULL) RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.lei_a(format('SELECT folha.esocial_conferencia_v1(%L::uuid, %L::date, %L)::text', pg_temp.id(p_emp_k), p_per, p_amb)) $$;
SELECT pg_temp.ok_(pg_temp.enf('p1200w4c', 'e1', 'S-1200', 'producao_restrita', 'p1200w4c', pg_temp.r1200('c4.trab'), pg_temp.origem('r_out')), 'S-1200 do w4 (sem admissão) volta à fila');
SELECT is(pg_temp.visao('e1', '2026-10-01'), '7/2/0/0/5/0/1',
  'visão do período 2026-10: 7 eventos, 2 pendentes (S-1200 do w4 e o novo fechamento), 5 validados e 1 bloqueado por antecessor');
SELECT is((SELECT split_part(pg_temp.visao('e1', NULL), '/', 3) || '/' || split_part(pg_temp.visao('e1', NULL), '/', 4)), '1/2',
  'visão sem período (tabelas e não periódicos): 1 em transmissão (a4, sem resposta) e 2 rejeitados (a2 duplicado e a5 de lote incorreto)');
SELECT pg_temp.ok_(pg_temp.guarda('conf_per', pg_temp.conf('e1', '2026-10-01')), 'conferência do período 2026-10 gerada');
SELECT is((SELECT (v::jsonb->>'pode_fechar_periodicos')::text FROM saida WHERE k = 'conf_per'), 'false', 'o período não pode fechar: há periódico bloqueado');
SELECT ok(
  (SELECT p->>'tipo' = 'bloqueado_antecessor' AND p->'antecessores_faltando'->0->>'antecessor' = 'S-2200 ou S-2300'
          AND p->'antecessores_faltando'->0->>'motivo' = 'ausente' AND p->'antecessores_faltando'->0->>'status_validacao' = 'firme'
     FROM saida, jsonb_array_elements(v::jsonb->'problemas') p WHERE k = 'conf_per' AND p->>'event_id' = pg_temp.id('p1200w4c')::text),
  'a conferência aponta o S-1200 do w4 como bloqueado por antecessor (S-2200 ou S-2300 ausente)');
SELECT is((SELECT p->>'tipo' FROM saida, jsonb_array_elements(v::jsonb->'problemas') p WHERE k = 'conf_per' AND p->>'event_id' = pg_temp.id('p1299b')::text), 'pendente',
  'o novo fechamento aparece como pendente');
SELECT is((SELECT jsonb_array_length(v::jsonb->'problemas') FROM saida WHERE k = 'conf_per'), 2, 'só os dois problemas do período (nada de outros períodos)');
SELECT pg_temp.ok_(pg_temp.guarda('conf_nul', pg_temp.conf('e1')), 'conferência sem período gerada');
SELECT ok(
  (SELECT p->>'tipo' = 'rejeitado' AND jsonb_array_length(p->'ocorrencias') = 1 AND p->'ocorrencias'->0->>'codigo' = 'D1'
     FROM saida, jsonb_array_elements(v::jsonb->'problemas') p WHERE k = 'conf_nul' AND p->>'event_id' = pg_temp.id('a2')::text),
  'o duplicado aparece como rejeitado, com a ocorrência do retorno');
SELECT is((SELECT p->>'tipo' FROM saida, jsonb_array_elements(v::jsonb->'problemas') p WHERE k = 'conf_nul' AND p->>'event_id' = pg_temp.id('a4')::text), 'em_transmissao',
  'o evento sem resposta aparece em transmissão');
SELECT is((SELECT (v::jsonb->'pode_fechar_periodicos')::text FROM saida WHERE k = 'conf_nul'), 'null', 'sem período não há veredito de fechamento');
SELECT is((pg_temp.conf('e1', NULL, 'producao'))::jsonb->'problemas', '[]'::jsonb, 'o filtro de ambiente: produção não tem problema (os eventos de teste foram cancelados)');
SELECT matches(pg_temp.conf('e1', NULL, 'teste'), '^ERRO 22023: Ambiente deve ser', 'ambiente inválido na conferência: recusado');
SELECT pg_temp.ok_(pg_temp.tx_a(format('SELECT folha.esocial_evento_cancelar_v1(%L::uuid, ''fora do cenário'')::text', pg_temp.id('p1200w4c'))), 'S-1200 do w4 cancelado');
SELECT is((pg_temp.conf('e1', '2026-10-01'))::jsonb->>'pode_fechar_periodicos', 'true', 'sem periódico pendente, rejeitado ou bloqueado o período pode fechar (o novo S-1299 não conta)');
SELECT is(split_part(pg_temp.visao('e1', '2026-10-01'), '/', 7), '0', 'a visão deixou de contar o bloqueado');

DO $$
DECLARE v text;
BEGIN
  FOREACH v IN ARRAY ARRAY['esocial_event', 'esocial_lot', 'esocial_lot_event', 'esocial_event_payload', 'esocial_event_occurrence',
                           'esocial_event_origin', 'esocial_employer_setting']
  LOOP
    EXECUTE format('DROP POLICY ci_leitura_temporaria ON folha.%I', v);
  END LOOP;
END
$$;
SELECT is((SELECT count(*) FROM pg_policies p JOIN tabelas t ON t.nome = p.tablename WHERE p.schemaname = 'folha'), 12::bigint, 'as policies temporárias de leitura foram desfeitas');

-- ===========================================================================
-- 18. Plano de desfazer com eventos em estados diferentes (e2)
-- ===========================================================================
SELECT pg_temp.ok_(pg_temp.enf('x_s1020', 'e2', 'S-1020', 'producao_restrita', 'e2-s1020', jsonb_build_object('codigo_tabela', 'LOT2', 'inicio_validade', '2026-01-01')), 'e2: S-1020 enfileirado');
SELECT pg_temp.ok_(pg_temp.ate_assinado('x_s1020'), 'e2: S-1020 assinado');
SELECT pg_temp.ok_(pg_temp.lote('L_x3', 'x_s1020'), 'e2: lote do S-1020 enviado (sem retorno)');
SELECT pg_temp.ok_(pg_temp.guarda('plano_mix', pg_temp.plano_evento('e2', 'x_s1005')), 'plano de desfazer do S-1005 do e2 gerado');
SELECT is(pg_temp.seq_plano((SELECT v FROM saida WHERE k = 'plano_mix')), 'S-2200@cancelar > S-1020@aguardar_retorno > S-1005@excluir',
  'plano com estados diferentes: cancelar o que não saiu, aguardar o que está em transmissão e só então excluir o validado');
SELECT is((SELECT v::jsonb->>'total_passos' FROM saida WHERE k = 'plano_mix'), '3', 'sem período fechado não há passo de reabertura (3 passos)');
SELECT ok(
  (SELECT (p->>'exige_decisao_humana')::boolean AND p->'motivos_decisao' = '["evento_em_transmissao_esperar_retorno"]'::jsonb AND NOT (p->>'exige_aprovacao_registrada')::boolean
     FROM saida, jsonb_array_elements(v::jsonb->'passos') p WHERE k = 'plano_mix' AND p->>'acao' = 'aguardar_retorno'),
  'evento em transmissão: decisão humana (esperar o retorno), sem aprovação de S-3000 ainda');
SELECT ok(
  (SELECT NOT (p->>'exige_decisao_humana')::boolean AND NOT (p->>'exige_aprovacao_registrada')::boolean AND p->'permissoes' = '["folha.transmit"]'::jsonb AND (p->'evento_a_enviar') = 'null'::jsonb
     FROM saida, jsonb_array_elements(v::jsonb->'passos') p WHERE k = 'plano_mix' AND p->>'acao' = 'cancelar'),
  'evento não enviado: cancelar não exige decisão nem aprovação, só folha.transmit');
SELECT ok(
  (SELECT (p->>'exige_decisao_humana')::boolean AND (p->>'exige_aprovacao_registrada')::boolean AND p->'depois_de_ordens' = '[1, 2]'::jsonb AND p->>'recibo_numero' = 'REC-X1005'
     FROM saida, jsonb_array_elements(v::jsonb->'passos') p WHERE k = 'plano_mix' AND p->>'acao' = 'excluir'),
  'o S-1005 validado: exclusão com decisão e aprovação, depois dos dois passos anteriores, com o recibo');
SELECT ok((SELECT v::jsonb->'avisos' @> to_jsonb('Em vez de excluir, o evento validado também pode ser retificado (parecer 4.6): a escolha é humana'::text) FROM saida WHERE k = 'plano_mix'),
  'o plano avisa que retificar é a alternativa a excluir');
SELECT ok((SELECT jsonb_array_length(v::jsonb->'proximos_passos') = 4 FROM saida WHERE k = 'plano_mix'), 'o plano lista os quatro próximos passos (recalcular, reenviar, refechar, DCTFWeb e FGTS Digital)');
SELECT is(pg_temp.contagens() <> (SELECT v FROM saida WHERE k = 'cnt_antes'), true, 'sanidade: a fila mudou desde a primeira contagem (o teste de somente leitura não é vazio)');

-- ===========================================================================
-- 19. Revisão: S-3000 x retificação, reabertura com aprovação, parâmetros do retorno, dependente já gerado
-- ===========================================================================
SELECT matches(pg_temp.faz(pg_temp.ca(), ARRAY['folha.read', 'folha.transmit'], '82000000-0000-0000-0000-000000000031'::uuid,
    format('SELECT folha.esocial_evento_enfileirar_v1(%L::uuid, ''S-1298'', ''producao_restrita'', %L, ''{"ind_apuracao":1,"periodo_apuracao":"2026-10-01"}''::jsonb)::text', pg_temp.id('e1'), pg_temp.h('s1298-sem-close'))),
  '^ERRO 42501: ', 'enfileirar a reabertura (S-1298) só com folha.transmit: recusado (exige também folha.close)');
SELECT pg_temp.ok_(pg_temp.excl('s3000_a6', 'a6', 'exclusão pedida primeiro'), 'S-3000 do a6 criado');
SELECT matches(pg_temp.retif('rx_a6', 'a6', 'a6-v2', 'retificação com exclusão aberta'), '^ERRO 55000: Há S-3000 em andamento para este evento',
  'retificar evento que tem S-3000 aberto: recusado (os dois retornos aceitos travariam o lote)');
SELECT pg_temp.ok_(pg_temp.tx_a(format('SELECT folha.esocial_evento_cancelar_v1(%L::uuid, ''desistência'')::text', pg_temp.id('s3000_a6'))), 'S-3000 cancelado');
SELECT pg_temp.ok_(pg_temp.retif('rx_a6', 'a6', 'a6-v2', 'retificação sem exclusão aberta'), 'agora a retificação é aceita');
SELECT matches(pg_temp.excl('s3000_a6b', 'a6', 'exclusão com retificação aberta'), '^ERRO 55000: Há versão deste evento em andamento',
  'excluir evento com retificação aberta: recusado');
SELECT matches(pg_temp.retorno('L_x3', 'recebido', 'PROT-X3', '201', '[]'::jsonb, jsonb_build_array(pg_temp.res('x_s1020', 'validado', 'R'))), '^ERRO 22023: Resultados por evento só no retorno processado',
  'resultado de evento fora do retorno processado: recusado');
SELECT pg_temp.ok_(pg_temp.retorno('L_x3', 'recebido', 'PROT-X3', '201'), 'e2: lote do S-1020 recebido');
SELECT matches(pg_temp.retorno('L_x3', 'processado', 'PROT-QUALQUER'), '^ERRO 22023: No retorno processado, protocolo, código e ocorrências do lote não se aplicam',
  'retorno processado com protocolo do lote: recusado (nada descartado em silêncio)');
SELECT pg_temp.ok_(pg_temp.retorno('L_x3', 'processado', NULL, NULL, '[]'::jsonb, jsonb_build_array(pg_temp.res('x_s1020', 'validado', 'REC-X1020'))), 'e2: S-1020 validado');
SELECT pg_temp.ok_(pg_temp.passo('x_s2200', 'gerado', '<x2200/>'), 'e2: S-2200 do c3 gerado (agora com S-1000, S-1005 e S-1020 validados)');
SELECT pg_temp.ok_(pg_temp.passo('x_s2200', 'assinado', '<x2200 sig="1"/>'), 'e2: S-2200 do c3 assinado (ainda não enviado)');
SELECT matches(pg_temp.excl('s3000_x', 'x_s1020', 'tentativa'), '^ERRO 55000: O evento tem dependentes enviados \(S-2200\)',
  'excluir o S-1020 com dependente já gerado e assinado (não enviado): recusado');
SELECT * FROM finish();
ROLLBACK;
