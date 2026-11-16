-- DNEX Folha — Migration 0031: fila de eventos do eSocial no banco (fatia 7a).
--
-- Fonte de requisito: parecer técnico eSocial/EFD-Reinf de 15/11/2026 (seções 3, 4.3 a 4.7 e 4.9),
-- plano de construção da Folha ("Modelo de dados a adotar": fila de obrigações; "Diferenciais":
-- assistente de desfazer a cadeia na ordem certa) e o levantamento de mercado de 15/11/2026, usado
-- SÓ como referência de requisito (estados da fila, "não entra em processamento é sempre antecessor
-- não validado", reabertura e exclusão). Nomes, desenho e texto são próprios; nada foi copiado de
-- terceiros. Decisões e alternativas: docs/02-decisoes/ADR-fila-esocial-banco.md.
--
-- O QUE ESTA MIGRATION FAZ
--   1. Catálogo de eventos (folha.esocial_event_catalog) com grupo, periodicidade, componentes da
--      chave de negócio e origem de folha; antecessores em tabela própria
--      (folha.esocial_event_antecessor). Só entra o que o parecer sustenta (códigos, grupos, chaves
--      de 4.7 e dependências de 3.2); o que o parecer não fixa fica `a_validar` (e é aplicado, mas
--      aparece como a validar nas mensagens). Nada semeado por conta; sem S-1260 e S-1270 (sem fonte).
--   2. Evento (folha.esocial_event) por conta, empregador e ambiente, com chave de negócio, versão,
--      máquina de estados validada por gatilho sobre a tabela folha.esocial_event_transition, recibo,
--      hash do conteúdo de origem (idempotência) e do XML gerado (imutável depois de `gerado`),
--      vínculo com a folha de origem (folha.esocial_event_origin), retificação e exclusão (S-3000).
--      O XML e os retornos ficam em folha.esocial_event_payload (RLS; nunca no log nem na auditoria).
--   3. Lote (folha.esocial_lot, no máximo 50 eventos, um empregador, um grupo; fechamento em lote
--      próprio), ocorrências de retorno (folha.esocial_event_occurrence) e a ESTRUTURA do catálogo de
--      rejeições (folha.esocial_rejection_catalog), vazia: o catálogo de códigos fica para a fatia de
--      validação preventiva.
--   4. Operações folha.esocial_*_v1 (EXECUTE só para dnex_gestao_api): enfileirar (idempotente),
--      avançar estado, cancelar, enviar lote, registrar retorno do lote e dos eventos, retificar,
--      excluir, liberar produção por empregador, plano de desfazer e conferência.
--   5. Plano de DESFAZER (folha.esocial_desfazer_plano_v1): só leitura; devolve em JSON a cadeia
--      ordenada (dependentes antes, reabertura de período primeiro) e os passos que exigem decisão
--      humana.
--   6. Visão folha.v_esocial_conferencia: por empregador e período, pendentes, rejeitados e
--      bloqueados por antecessor não validado.
--   7. Evento que depende de folha só nasce de folha FECHADA e sem pendência aberta (trava da 0027).
--
-- PERMISSÃO POR OPERAÇÃO (protocolo da 0028)
--   folha.read      esocial_desfazer_plano_v1, esocial_conferencia_v1
--   folha.transmit  esocial_evento_enfileirar_v1, esocial_evento_avancar_v1, esocial_evento_cancelar_v1,
--                   esocial_lote_enviar_v1, esocial_lote_retorno_v1 (e todo UPDATE/INSERT nas tabelas)
--   folha.transmit + folha.close   esocial_evento_retificar_v1, esocial_evento_excluir_v1
--                   (parecer 4.9: quem aprova retificação e exclusão é papel distinto de quem prepara);
--                   o mesmo vale para enfileirar o S-1298 (reabertura)
--   folha.admin     esocial_producao_definir_v1
--
-- NÃO altera as migrations 0014 a 0030. NÃO GERA XML, NÃO TRANSMITE, NÃO USA REDE: é só a fila.
-- NÃO APLICAR EM PRODUÇÃO sem as dependências das 0024 a 0030 e sem decidir os pontos em aberto da ADR.
-- Reversão: 0031_folha_fila_esocial.supabase.down.sql.
BEGIN;

SET LOCAL lock_timeout = '5s';

-- ---------------------------------------------------------------------------
-- 0. Pré-condições
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_faltando text;
BEGIN
  SELECT string_agg(x.nome, ', ') INTO v_faltando
    FROM (VALUES
      ('papel dnex_gestao_api', NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'dnex_gestao_api')),
      ('papel dnex_gestao_folha_worker', NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'dnex_gestao_folha_worker')),
      ('papel dnex_gestao_data_owner', NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'dnex_gestao_data_owner')),
      ('folha.contexto_v1(text) (migration 0028)', to_regprocedure('folha.contexto_v1(text)') IS NULL),
      ('folha.employer (migration 0024)', to_regclass('folha.employer') IS NULL),
      ('folha.establishment (migration 0024)', to_regclass('folha.establishment') IS NULL),
      ('folha.payroll_pendency (migration 0027)', to_regclass('folha.payroll_pendency') IS NULL),
      ('índice employment_contract_account_employer_contract_key (migration 0024)',
         to_regclass('folha.employment_contract_account_employer_contract_key') IS NULL),
      ('índice employee_account_employee_key (migration 0026)', to_regclass('folha.employee_account_employee_key') IS NULL),
      ('índice payroll_run_account_run_key (migration 0026)', to_regclass('folha.payroll_run_account_run_key') IS NULL),
      ('índice payroll_result_account_result_key (migration 0026)', to_regclass('folha.payroll_result_account_result_key') IS NULL),
      ('folha.published_document (migration 0029)', to_regclass('folha.published_document') IS NULL),
      ('folha.contabil_mapa (migration 0030)', to_regclass('folha.contabil_mapa') IS NULL)
    ) AS x(nome, ausente)
   WHERE x.ausente;
  IF v_faltando IS NOT NULL THEN
    RAISE EXCEPTION '0031: faltam objetos: %', v_faltando
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  -- As funções leem e gravam com row_security = off e filtro explícito de conta.
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles
                  WHERE rolname = current_user AND (rolsuper OR rolbypassrls)) THEN
    RAISE EXCEPTION '0031: o papel % não é superusuário nem tem BYPASSRLS', current_user
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF to_regclass('folha.esocial_event') IS NOT NULL THEN
    RAISE EXCEPTION '0031: folha.esocial_event já existe' USING ERRCODE = 'duplicate_table';
  END IF;
END
$$;

-- ===========================================================================
-- 1. Catálogo de eventos e antecessores (estrutura do produto: sem dado de conta)
-- ===========================================================================

-- 1.1 Catálogo. `chave_componentes` diz de que se compõe a chave de negócio do evento (parecer 4.7):
--     codigo_tabela, inicio_validade (tabelas), trabalhador (employee_id), vinculo (contract_id),
--     data_efeito, periodo (perApur) e ind_apuracao. `origem_folha`: obrigatoria = precisa de folha de
--     origem fechada e sem pendência; periodo_inteiro = nenhuma folha do período aberta (fechamento).
--     `habilitado` falso = a fila não aceita enfileirar (retornos do governo, eventos sem fonte).
CREATE TABLE folha.esocial_event_catalog (
  evento_codigo text PRIMARY KEY CHECK (evento_codigo ~ '^S-[0-9]{4}$'),
  nome text NOT NULL CHECK (btrim(nome) <> ''),
  grupo text NOT NULL CHECK (grupo IN ('tabelas', 'nao_periodicos', 'periodicos', 'sst', 'exclusao', 'totalizadores')),
  periodicidade text NOT NULL CHECK (periodicidade IN ('eventual', 'mensal', 'mensal_ou_anual', 'retorno')),
  chave_componentes text[] NOT NULL DEFAULT '{}'
    CHECK (chave_componentes <@ ARRAY['codigo_tabela', 'inicio_validade', 'trabalhador', 'vinculo', 'data_efeito', 'periodo', 'ind_apuracao']),
  chave_ciclo boolean NOT NULL DEFAULT false,
  origem_folha text NOT NULL DEFAULT 'nenhuma' CHECK (origem_folha IN ('nenhuma', 'obrigatoria', 'periodo_inteiro')),
  lote_proprio boolean NOT NULL DEFAULT false,
  eh_retorno boolean NOT NULL DEFAULT false,
  habilitado boolean NOT NULL DEFAULT true,
  status_validacao text NOT NULL CHECK (status_validacao IN ('firme', 'a_validar')),
  fonte text NOT NULL CHECK (btrim(fonte) <> ''),
  observacao text,
  CONSTRAINT esocial_catalog_retorno_coerente
    CHECK (eh_retorno = (periodicidade = 'retorno') AND eh_retorno = (grupo = 'totalizadores') AND (NOT eh_retorno OR NOT habilitado)),
  CONSTRAINT esocial_catalog_periodo_coerente
    CHECK ((periodicidade IN ('mensal', 'mensal_ou_anual')) = ('periodo' = ANY (chave_componentes))),
  CONSTRAINT esocial_catalog_ind_apuracao_coerente
    CHECK ((periodicidade = 'mensal_ou_anual') = ('ind_apuracao' = ANY (chave_componentes))),
  CONSTRAINT esocial_catalog_ciclo_so_com_periodo
    CHECK (NOT chave_ciclo OR 'periodo' = ANY (chave_componentes))
);
COMMENT ON TABLE folha.esocial_event_catalog IS
  'Catálogo de eventos do eSocial que a fila conhece. Só o que o parecer de 15/11/2026 sustenta; o resto é a_validar ou fica de fora. Sem dado de conta.';

INSERT INTO folha.esocial_event_catalog
  (evento_codigo, nome, grupo, periodicidade, chave_componentes, chave_ciclo, origem_folha, lote_proprio, eh_retorno,
   habilitado, status_validacao, fonte, observacao)
VALUES
  ('S-1000', 'Empregador', 'tabelas', 'eventual', ARRAY['inicio_validade'], false, 'nenhuma', false, false, true, 'firme',
     'parecer eSocial/Reinf 3.1 e 3.2 item 1; chave: 4.7 (tabelas = empregador + código + início de validade)', NULL),
  ('S-1005', 'Estabelecimentos', 'tabelas', 'eventual', ARRAY['codigo_tabela', 'inicio_validade'], false, 'nenhuma', false, false, true, 'firme',
     'parecer 3.1 e 3.2 item 1; chave: 4.7', 'codigo_tabela = identificação do estabelecimento'),
  ('S-1010', 'Rubricas', 'tabelas', 'eventual', ARRAY['codigo_tabela', 'inicio_validade'], false, 'nenhuma', false, false, true, 'firme',
     'parecer 3.1 e 3.2 item 1; chave: 4.7', 'codigo_tabela = código e identificador da tabela de rubricas'),
  ('S-1020', 'Lotações tributárias', 'tabelas', 'eventual', ARRAY['codigo_tabela', 'inicio_validade'], false, 'nenhuma', false, false, true, 'firme',
     'parecer 3.1 e 3.2 item 1; chave: 4.7', 'codigo_tabela = código da lotação'),
  ('S-1070', 'Processos', 'tabelas', 'eventual', ARRAY['codigo_tabela', 'inicio_validade'], false, 'nenhuma', false, false, true, 'firme',
     'parecer 3.1 (só quando houver suspensão de tributo); chave: 4.7', 'codigo_tabela = identificação do processo'),
  ('S-2190', 'Registro preliminar de trabalhador', 'nao_periodicos', 'eventual', ARRAY['trabalhador'], false, 'nenhuma', false, false, true, 'a_validar',
     'parecer 3.1 e 3.2 item 2 (opcional, antes do S-2200)', 'A chave de negócio deste evento não é fixada no parecer'),
  ('S-2200', 'Admissão', 'nao_periodicos', 'eventual', ARRAY['trabalhador', 'vinculo'], false, 'nenhuma', false, false, true, 'firme',
     'parecer 3.1, 3.2 item 2; chave: 4.7 (empregador + CPF + matrícula)', 'vinculo = contrato; a matrícula do eSocial ainda não existe no modelo'),
  ('S-2205', 'Alteração cadastral', 'nao_periodicos', 'eventual', ARRAY['trabalhador', 'data_efeito'], false, 'nenhuma', false, false, true, 'a_validar',
     'parecer 3.1 e 3.2 item 2', 'A chave de negócio deste evento não é fixada no parecer'),
  ('S-2206', 'Alteração contratual', 'nao_periodicos', 'eventual', ARRAY['vinculo', 'data_efeito'], false, 'nenhuma', false, false, true, 'firme',
     'parecer 3.1, 3.2 item 2; chave: 4.7 (vínculo + data de efeito)', NULL),
  ('S-2230', 'Afastamento', 'nao_periodicos', 'eventual', ARRAY['vinculo', 'data_efeito'], false, 'nenhuma', false, false, true, 'firme',
     'parecer 3.1, 3.2 item 2; chave: 4.7 (vínculo + data de efeito)', NULL),
  ('S-2299', 'Desligamento', 'nao_periodicos', 'eventual', ARRAY['vinculo'], false, 'obrigatoria', false, false, true, 'firme',
     'parecer 3.1, 3.2 item 2 e 3; chave: 4.7 (vínculo)', 'As verbas rescisórias vêm de folha de rescisão fechada'),
  ('S-2300', 'Trabalhador sem vínculo (TSVE): início', 'nao_periodicos', 'eventual', ARRAY['trabalhador', 'vinculo'], false, 'nenhuma', false, false, true, 'a_validar',
     'parecer 3.1 (lista S-2300, S-2306 e S-2399)', 'O parecer não detalha chave nem dependências do TSVE'),
  ('S-2306', 'Trabalhador sem vínculo (TSVE): alteração', 'nao_periodicos', 'eventual', ARRAY['vinculo', 'data_efeito'], false, 'nenhuma', false, false, true, 'a_validar',
     'parecer 3.1', 'O parecer não detalha chave nem dependências do TSVE'),
  ('S-2399', 'Trabalhador sem vínculo (TSVE): término', 'nao_periodicos', 'eventual', ARRAY['vinculo'], false, 'nenhuma', false, false, true, 'a_validar',
     'parecer 3.1', 'O parecer não detalha chave nem dependências do TSVE'),
  ('S-1200', 'Remuneração do trabalhador', 'periodicos', 'mensal_ou_anual', ARRAY['trabalhador', 'ind_apuracao', 'periodo'], false, 'obrigatoria', false, false, true, 'firme',
     'parecer 3.1, 3.2 item 3; chave: 4.7 (empregador + indApuracao + perApur + CPF)', 'Um trabalhador com mais de um contrato gera um evento só (4.7)'),
  ('S-1210', 'Pagamentos de rendimentos', 'periodicos', 'mensal', ARRAY['trabalhador', 'periodo'], false, 'obrigatoria', false, false, true, 'firme',
     'parecer 3.1, 3.2 item 3; chave: 4.7 (empregador + perApur + CPF)', 'perApur = mês do pagamento (parecer 2.4, C2)'),
  ('S-1298', 'Reabertura dos eventos periódicos', 'periodicos', 'mensal_ou_anual', ARRAY['ind_apuracao', 'periodo'], true, 'nenhuma', false, false, true, 'firme',
     'parecer 3.1, 3.2 item 5, 4.6; chave: 4.7 (empregador + indApuracao + perApur)',
     'Cada fechamento (S-1299) e cada reabertura (S-1298) tem um ciclo, para a chave não colidir quando o período é fechado e reaberto mais de uma vez'),
  ('S-1299', 'Fechamento dos eventos periódicos', 'periodicos', 'mensal_ou_anual', ARRAY['ind_apuracao', 'periodo'], true, 'periodo_inteiro', true, false, true, 'firme',
     'parecer 3.1, 3.2 item 4, 4.3 (lote próprio); chave: 4.7', 'Só depois de todos os periódicos do período validados'),
  ('S-2210', 'Comunicação de acidente de trabalho (CAT)', 'sst', 'eventual', ARRAY['vinculo', 'data_efeito'], false, 'nenhuma', false, false, true, 'a_validar',
     'parecer 3.1, 3.3 e 3.2 item 2 (depende de S-2190, S-2200 ou S-2300)', 'A chave de negócio dos eventos de SST não é fixada no parecer'),
  ('S-2220', 'Monitoramento da saúde do trabalhador (ASO)', 'sst', 'eventual', ARRAY['vinculo', 'data_efeito'], false, 'nenhuma', false, false, true, 'a_validar',
     'parecer 3.1, 3.3 e 3.2 item 2', 'A chave de negócio dos eventos de SST não é fixada no parecer'),
  ('S-2240', 'Condições ambientais do trabalho', 'sst', 'eventual', ARRAY['vinculo', 'data_efeito'], false, 'nenhuma', false, false, true, 'a_validar',
     'parecer 3.1, 3.3 e 3.2 item 2', 'A chave de negócio dos eventos de SST não é fixada no parecer'),
  ('S-3000', 'Exclusão de evento', 'exclusao', 'eventual', '{}', false, 'nenhuma', false, false, true, 'firme',
     'parecer 3.1, 4.6 (exclusão exige o recibo do evento vigente)', 'A chave é o evento excluído (exclui_event_id)'),
  ('S-5001', 'Totalizador de contribuição previdenciária por trabalhador (retorno)', 'totalizadores', 'retorno', '{}', false, 'nenhuma', false, true, false, 'firme',
     'parecer 2.2 A2, 3.1, 4.4 (retornos S-5001, S-5002 e S-5003 por trabalhador)', 'Retorno do governo: a fila não envia'),
  ('S-5002', 'Totalizador de IRRF por trabalhador (retorno)', 'totalizadores', 'retorno', '{}', false, 'nenhuma', false, true, false, 'firme',
     'parecer 2.2 A2, 3.1, 4.4', 'Retorno do governo: a fila não envia'),
  ('S-5003', 'Totalizador de FGTS por trabalhador (retorno)', 'totalizadores', 'retorno', '{}', false, 'nenhuma', false, true, false, 'firme',
     'parecer 2.2 A2, 3.1, 4.4', 'Retorno do governo: a fila não envia'),
  ('S-5011', 'Totalizador de contribuição previdenciária do empregador (retorno)', 'totalizadores', 'retorno', '{}', false, 'nenhuma', false, true, false, 'firme',
     'parecer 2.5 D1, 3.1, 4.4, 4.8 (S-5011, S-5012 e S-5013 por empregador)', 'Retorno do governo: a fila não envia'),
  ('S-5012', 'Totalizador de IRRF do empregador (retorno)', 'totalizadores', 'retorno', '{}', false, 'nenhuma', false, true, false, 'firme',
     'parecer 3.1, 4.4, 4.8', 'Retorno do governo: a fila não envia'),
  ('S-5013', 'Totalizador de FGTS do empregador (retorno)', 'totalizadores', 'retorno', '{}', false, 'nenhuma', false, true, false, 'firme',
     'parecer 2.5 D1, 3.1, 4.4, 4.8', 'Retorno do governo: a fila não envia');

-- 1.2 Antecessores. Para o evento E (evento_codigo) e o antecessor A (antecessor_codigo), o `escopo`
--     diz como achar o A que vale para o E: mesmo empregador; mesmo trabalhador; mesmo vínculo; ou
--     mesmo período (e mesmo ciclo, quando os dois têm ciclo). `obrigatorio` = precisa haver um A
--     validado (com `grupo_alternativa`, basta um validado entre os antecessores do mesmo grupo);
--     `todos_existentes` = todo A que existir no escopo precisa estar validado, mas não precisa existir.
--     Evento "validado" = estado validado de alguma versão da cadeia (mesma chave).
CREATE TABLE folha.esocial_event_antecessor (
  evento_codigo text NOT NULL REFERENCES folha.esocial_event_catalog (evento_codigo),
  antecessor_codigo text NOT NULL REFERENCES folha.esocial_event_catalog (evento_codigo),
  escopo text NOT NULL CHECK (escopo IN ('empregador', 'trabalhador', 'vinculo', 'periodo')),
  obrigatoriedade text NOT NULL CHECK (obrigatoriedade IN ('obrigatorio', 'todos_existentes')),
  grupo_alternativa text CHECK (grupo_alternativa IS NULL OR btrim(grupo_alternativa) <> ''),
  status_validacao text NOT NULL CHECK (status_validacao IN ('firme', 'a_validar')),
  fonte text NOT NULL CHECK (btrim(fonte) <> ''),
  PRIMARY KEY (evento_codigo, antecessor_codigo),
  CONSTRAINT esocial_antecessor_distintos CHECK (evento_codigo <> antecessor_codigo),
  CONSTRAINT esocial_antecessor_alternativa_so_obrigatorio
    CHECK (grupo_alternativa IS NULL OR obrigatoriedade = 'obrigatorio')
);
COMMENT ON TABLE folha.esocial_event_antecessor IS
  'Dependência entre eventos: o evento só passa a gerado se os antecessores exigidos estiverem validados (mesmo empregador e ambiente). status_validacao a_validar = regra aplicada, mas ainda não confirmada na fonte oficial.';

INSERT INTO folha.esocial_event_antecessor
  (evento_codigo, antecessor_codigo, escopo, obrigatoriedade, grupo_alternativa, status_validacao, fonte)
VALUES
  -- Tabelas do empregador (parecer 3.2 item 1: S-1000 -> S-1005 -> S-1020 -> S-1010)
  ('S-1005', 'S-1000', 'empregador', 'obrigatorio', NULL, 'firme', 'parecer 3.2 item 1 (ordem S-1000 -> S-1005)'),
  ('S-1020', 'S-1005', 'empregador', 'obrigatorio', NULL, 'a_validar', 'parecer 3.2 item 1: a ordem está escrita; a dependência direta não é afirmada'),
  ('S-1010', 'S-1020', 'empregador', 'obrigatorio', NULL, 'a_validar', 'parecer 3.2 item 1: a ordem está escrita; a dependência direta não é afirmada'),
  -- Não periódicos
  ('S-2200', 'S-1000', 'empregador', 'obrigatorio', NULL, 'a_validar', 'levantamento de mercado de 15/11/2026 (obrigações 2.3): o S-2200 exige o cadastro inicial; o parecer não afirma'),
  ('S-2200', 'S-1005', 'empregador', 'obrigatorio', NULL, 'firme', 'parecer 3.2 item 1 (o S-1005 precede o S-2200; MOS L3488)'),
  ('S-2200', 'S-1020', 'empregador', 'obrigatorio', NULL, 'a_validar', 'levantamento de mercado (obrigações 2.3); parecer 3.2 item 1: o S-1020 precede quem o utiliza'),
  ('S-2200', 'S-2190', 'trabalhador', 'todos_existentes', NULL, 'a_validar', 'parecer 3.2 item 2 (S-2190 opcional antes do S-2200)'),
  ('S-2205', 'S-2200', 'trabalhador', 'obrigatorio', 'base_cadastro', 'firme', 'parecer 3.2 item 2 (S-2200 antes de S-2205)'),
  ('S-2205', 'S-2300', 'trabalhador', 'obrigatorio', 'base_cadastro', 'a_validar', 'parecer 3.1: o TSVE não é detalhado'),
  ('S-2206', 'S-2200', 'vinculo', 'obrigatorio', NULL, 'firme', 'parecer 3.2 item 2 (S-2200 antes de S-2206)'),
  ('S-2230', 'S-2200', 'vinculo', 'obrigatorio', NULL, 'firme', 'parecer 3.2 item 2 (S-2200 antes de S-2230)'),
  ('S-2299', 'S-2200', 'vinculo', 'obrigatorio', NULL, 'firme', 'parecer 3.2 item 2 (S-2200 antes de S-2299)'),
  ('S-2299', 'S-2230', 'vinculo', 'todos_existentes', NULL, 'a_validar', 'levantamento de mercado (obrigações 2.3): a rescisão exige os afastamentos anteriores validados; o parecer não afirma'),
  ('S-2300', 'S-1000', 'empregador', 'obrigatorio', NULL, 'a_validar', 'por analogia com o S-2200; parecer 3.1 não detalha o TSVE'),
  ('S-2300', 'S-1005', 'empregador', 'obrigatorio', NULL, 'a_validar', 'por analogia com o S-2200; parecer 3.1 não detalha o TSVE'),
  ('S-2306', 'S-2300', 'vinculo', 'obrigatorio', NULL, 'a_validar', 'parecer 3.1 não detalha o TSVE'),
  ('S-2399', 'S-2300', 'vinculo', 'obrigatorio', NULL, 'a_validar', 'parecer 3.1 não detalha o TSVE'),
  -- SST (parecer 3.2 item 2 e 3.3: depende de S-2190, S-2200 ou S-2300; MOS L9091)
  ('S-2210', 'S-2190', 'trabalhador', 'obrigatorio', 'base_trabalhador', 'firme', 'parecer 3.2 item 2 (MOS L9091)'),
  ('S-2210', 'S-2200', 'trabalhador', 'obrigatorio', 'base_trabalhador', 'firme', 'parecer 3.2 item 2 (MOS L9091)'),
  ('S-2210', 'S-2300', 'trabalhador', 'obrigatorio', 'base_trabalhador', 'firme', 'parecer 3.2 item 2 (MOS L9091)'),
  ('S-2220', 'S-2190', 'trabalhador', 'obrigatorio', 'base_trabalhador', 'firme', 'parecer 3.2 item 2 (MOS L9091)'),
  ('S-2220', 'S-2200', 'trabalhador', 'obrigatorio', 'base_trabalhador', 'firme', 'parecer 3.2 item 2 (MOS L9091)'),
  ('S-2220', 'S-2300', 'trabalhador', 'obrigatorio', 'base_trabalhador', 'firme', 'parecer 3.2 item 2 (MOS L9091)'),
  ('S-2240', 'S-2190', 'trabalhador', 'obrigatorio', 'base_trabalhador', 'firme', 'parecer 3.2 item 2 (MOS L9091)'),
  ('S-2240', 'S-2200', 'trabalhador', 'obrigatorio', 'base_trabalhador', 'firme', 'parecer 3.2 item 2 (MOS L9091)'),
  ('S-2240', 'S-2300', 'trabalhador', 'obrigatorio', 'base_trabalhador', 'firme', 'parecer 3.2 item 2 (MOS L9091)'),
  -- Periódicos
  ('S-1200', 'S-1005', 'empregador', 'obrigatorio', NULL, 'firme', 'parecer 3.2 item 1 (o S-1005 precede o S-1200; MOS L3488)'),
  ('S-1200', 'S-1010', 'empregador', 'obrigatorio', NULL, 'firme', 'parecer 3.2 item 1 (o S-1010 precede os eventos de remuneração; MOS L3618)'),
  ('S-1200', 'S-1020', 'empregador', 'obrigatorio', NULL, 'firme', 'parecer 3.2 item 1 (MOS L4237) e caso T1 (codLotacao)'),
  ('S-1200', 'S-2200', 'trabalhador', 'obrigatorio', 'base_vinculo', 'firme', 'parecer 3.2 itens 2 e 3 (não periódicos do trabalhador antes dos periódicos)'),
  ('S-1200', 'S-2300', 'trabalhador', 'obrigatorio', 'base_vinculo', 'a_validar', 'parecer 3.1: o TSVE não é detalhado'),
  ('S-1210', 'S-1200', 'trabalhador', 'obrigatorio', 'base_remuneracao', 'firme', 'parecer 3.2 item 3 (pré-requisito: S-1200 ou S-2299; MOS L6950)'),
  ('S-1210', 'S-2299', 'trabalhador', 'obrigatorio', 'base_remuneracao', 'firme', 'parecer 3.2 item 3 (pré-requisito: S-1200 ou S-2299; MOS L6950)'),
  ('S-1299', 'S-1200', 'periodo', 'todos_existentes', NULL, 'firme', 'parecer 3.2 item 4 e 4.3 (fechamento só depois de todos os periódicos aceitos)'),
  ('S-1299', 'S-1210', 'periodo', 'todos_existentes', NULL, 'firme', 'parecer 3.2 item 4 e 4.3'),
  ('S-1299', 'S-1000', 'empregador', 'obrigatorio', NULL, 'a_validar', 'levantamento de mercado (obrigações 2.3): o fechamento exige o cadastro inicial; o parecer não afirma'),
  ('S-1298', 'S-1299', 'periodo', 'obrigatorio', NULL, 'a_validar', 'parecer 3.2 item 5 e 4.6 (S-1298 antes de alterar periódico fechado); exigir o S-1299 validado do mesmo ciclo vem do levantamento de mercado');

-- Segurança do catálogo: o grafo de antecessores não pode ter ciclo (a dependência mútua travaria a fila).
DO $$
DECLARE
  v_ciclo text;
BEGIN
  WITH RECURSIVE arestas AS (
    SELECT evento_codigo AS de, antecessor_codigo AS para FROM folha.esocial_event_antecessor
  ), cam AS (
    SELECT a.de, a.para, ARRAY[a.de] AS trilha, false AS fechou FROM arestas a
    UNION ALL
    SELECT c.de, a.para, c.trilha || a.de, a.para = c.de
      FROM cam c JOIN arestas a ON a.de = c.para
     WHERE NOT c.fechou AND NOT a.de = ANY (c.trilha)
  )
  SELECT string_agg(DISTINCT c.de, ', ') INTO v_ciclo FROM cam c WHERE c.fechou;
  IF v_ciclo IS NOT NULL THEN
    RAISE EXCEPTION '0031: ciclo no grafo de antecessores envolvendo: %', v_ciclo
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
END
$$;

-- 1.3 Estados e transições do evento: a máquina é este dado; o gatilho do evento consulta esta
--     tabela. Nenhuma transição pula estado. Retificado e excluído só entram pelo retorno aceito
--     do evento que retifica ou exclui.
CREATE TABLE folha.esocial_event_state (
  estado text PRIMARY KEY,
  terminal boolean NOT NULL,
  aberto boolean NOT NULL,
  descricao text NOT NULL
);
INSERT INTO folha.esocial_event_state (estado, terminal, aberto, descricao) VALUES
  ('rascunho',         false, true,  'Intenção registrada a partir da folha ou do cadastro; ainda sem validação interna'),
  ('pendente_interno', false, true,  'Aguardando validação interna e antecessores validados'),
  ('gerado',           false, true,  'XML gerado e guardado (hash fixado); antecessores validados e folha fechada conferidos'),
  ('assinado',         false, true,  'XML assinado e guardado (hash do assinado)'),
  ('enviado',          false, true,  'Dentro de um lote enviado; aguardando o protocolo'),
  ('em_processamento', false, true,  'Lote recebido (protocolo); aguardando o resultado da consulta'),
  ('falha_comunicacao',false, true,  'Falha de comunicação ao enviar; reenviável depois de consultar'),
  ('validado',         false, false, 'Aceito pelo governo, com recibo (pode ter advertência)'),
  ('rejeitado',        true,  false, 'Rejeitado, com ocorrências; correção gera nova versão'),
  ('duplicado',        true,  false, 'O governo já tem o evento; consultar e comparar antes de qualquer reenvio'),
  ('retificado',       true,  false, 'Substituído por retificação validada'),
  ('excluido',         true,  false, 'Excluído por S-3000 validado'),
  ('cancelado',        true,  false, 'Cancelado ou substituído antes de ser enviado');

CREATE TABLE folha.esocial_event_transition (
  de text NOT NULL REFERENCES folha.esocial_event_state (estado),
  para text NOT NULL REFERENCES folha.esocial_event_state (estado),
  observacao text,
  PRIMARY KEY (de, para),
  CHECK (de <> para)
);
INSERT INTO folha.esocial_event_transition (de, para, observacao) VALUES
  ('rascunho', 'pendente_interno', NULL),
  ('rascunho', 'cancelado', NULL),
  ('pendente_interno', 'gerado', 'exige antecessores validados, folha fechada e XML guardado'),
  ('pendente_interno', 'rascunho', 'volta para correção'),
  ('pendente_interno', 'cancelado', NULL),
  ('gerado', 'assinado', NULL),
  ('gerado', 'cancelado', NULL),
  ('assinado', 'enviado', 'só dentro de um lote'),
  ('assinado', 'cancelado', 'só se ainda fora de lote'),
  ('enviado', 'em_processamento', 'lote recebido (201 ou 202)'),
  ('enviado', 'falha_comunicacao', 'erro do servidor (301) ou sem resposta'),
  ('enviado', 'rejeitado', 'lote incorreto (401 ou 402): não se reenvia o mesmo lote'),
  ('falha_comunicacao', 'assinado', 'volta para reenvio, depois de consultar'),
  ('em_processamento', 'validado', 'recibo obrigatório'),
  ('em_processamento', 'rejeitado', 'ao menos uma ocorrência de erro'),
  ('em_processamento', 'duplicado', 'ao menos uma ocorrência'),
  ('validado', 'retificado', 'só pelo retorno aceito da retificação'),
  ('validado', 'excluido', 'só pelo retorno aceito do S-3000');

-- 1.4 Catálogo de rejeições: SÓ A ESTRUTURA. Os códigos e textos entram na fatia de validação
--     preventiva, com fonte conferida; nada de terceiros é semeado aqui. As classes são as de
--     parecer 4.5 (causa -> tratamento).
CREATE TABLE folha.esocial_rejection_catalog (
  rejeicao_codigo text PRIMARY KEY CHECK (btrim(rejeicao_codigo) <> ''),
  classe text NOT NULL CHECK (classe IN ('estrutura', 'regra_negocio', 'precedencia', 'cadastro', 'duplicidade', 'certificado_procuracao', 'indisponibilidade')),
  causa text NOT NULL CHECK (btrim(causa) <> ''),
  correcao text NOT NULL CHECK (btrim(correcao) <> ''),
  fonte text NOT NULL CHECK (btrim(fonte) <> ''),
  status_validacao text NOT NULL CHECK (status_validacao IN ('firme', 'a_validar')),
  created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE folha.esocial_rejection_catalog IS
  'Estrutura do catálogo de rejeições (vazio nesta migration). O catálogo de códigos fica para a fatia de validação preventiva.';

-- ===========================================================================
-- 2. Tabelas por conta
--    Todas têm account_id, RLS com FORCE e FKs compostas com account_id. Ninguém além do dono grava
--    direto: a gravação é pelas funções (e pelos gatilhos, que exigem o contexto da Folha).
-- ===========================================================================

-- 2.1 Liberação de produção por empregador (parecer 4.2: produção exige liberação explícita)
CREATE TABLE folha.esocial_employer_setting (
  account_id uuid NOT NULL,
  employer_id uuid NOT NULL,
  producao_liberada boolean NOT NULL DEFAULT false,
  motivo text,
  definido_por_subject uuid NOT NULL,
  definido_em timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, employer_id),
  CONSTRAINT esocial_setting_employer_fk FOREIGN KEY (account_id, employer_id)
    REFERENCES folha.employer (account_id, employer_id)
);

-- 2.2 Lote. Um empregador, um grupo do catálogo, no máximo 50 eventos (parecer 4.3). A situação
--     segue os códigos de resposta do parecer 4.3: 201 e 202 recebido; 301 erro do servidor
--     (reenviável); 401 e 402 lote incorreto (não reenviável).
CREATE TABLE folha.esocial_lot (
  lot_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  employer_id uuid NOT NULL,
  ambiente text NOT NULL CHECK (ambiente IN ('producao', 'producao_restrita')),
  grupo text NOT NULL CHECK (grupo IN ('tabelas', 'nao_periodicos', 'periodicos', 'sst', 'exclusao')),
  situacao text NOT NULL DEFAULT 'enviado'
    CHECK (situacao IN ('enviado', 'recebido', 'processado', 'erro_servidor', 'lote_incorreto', 'sem_resposta')),
  protocolo text CHECK (protocolo IS NULL OR btrim(protocolo) <> ''),
  codigo_resposta text CHECK (codigo_resposta IS NULL OR codigo_resposta ~ '^[0-9]{3}$'),
  qtd_eventos integer NOT NULL CHECK (qtd_eventos BETWEEN 1 AND 50),
  enviado_em timestamptz NOT NULL DEFAULT now(),
  respondido_em timestamptz,
  processado_em timestamptz,
  enviado_por_subject uuid NOT NULL,
  atualizado_por_subject uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT esocial_lot_employer_fk FOREIGN KEY (account_id, employer_id)
    REFERENCES folha.employer (account_id, employer_id),
  UNIQUE (account_id, lot_id),
  UNIQUE (account_id, ambiente, protocolo),
  CONSTRAINT esocial_lot_protocolo_coerente
    CHECK (situacao NOT IN ('recebido', 'processado') OR protocolo IS NOT NULL)
);

-- 2.3 Evento
CREATE TABLE folha.esocial_event (
  event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  employer_id uuid NOT NULL,
  establishment_id uuid,
  evento_codigo text NOT NULL REFERENCES folha.esocial_event_catalog (evento_codigo),
  ambiente text NOT NULL CHECK (ambiente IN ('producao', 'producao_restrita')),
  -- referência: o que identifica o evento além do empregador (a chave de negócio é calculada)
  ind_apuracao smallint CHECK (ind_apuracao IN (1, 2)),      -- 1 mensal, 2 anual (13º)
  periodo_apuracao date,                                      -- 1º dia do mês; na folha anual, 1º de janeiro
  ciclo integer CHECK (ciclo >= 1),
  employee_id uuid,
  contract_id uuid,
  data_efeito date,
  inicio_validade date,
  codigo_tabela text CHECK (codigo_tabela IS NULL OR btrim(codigo_tabela) <> ''),
  chave_negocio text NOT NULL,
  versao integer NOT NULL CHECK (versao >= 1),
  ind_retif smallint NOT NULL DEFAULT 1 CHECK (ind_retif IN (1, 2)),
  estado text NOT NULL DEFAULT 'rascunho' REFERENCES folha.esocial_event_state (estado),
  origem_hash text NOT NULL CHECK (origem_hash ~ '^[0-9a-f]{64}$'),     -- conteúdo canônico de origem (idempotência)
  payload_hash text CHECK (payload_hash IS NULL OR payload_hash ~ '^[0-9a-f]{64}$'),   -- XML gerado
  assinado_hash text CHECK (assinado_hash IS NULL OR assinado_hash ~ '^[0-9a-f]{64}$'), -- XML assinado
  recibo_numero text CHECK (recibo_numero IS NULL OR recibo_numero ~ '^[0-9A-Za-z.-]{1,40}$'),
  lot_id uuid,
  tentativas integer NOT NULL DEFAULT 0 CHECK (tentativas >= 0),
  com_advertencia boolean NOT NULL DEFAULT false,
  retifica_event_id uuid,
  exclui_event_id uuid,
  motivo text,
  gerado_em timestamptz,
  assinado_em timestamptz,
  enviado_em timestamptz,
  processado_em timestamptz,
  criado_por_subject uuid NOT NULL,
  atualizado_por_subject uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT esocial_event_employer_fk FOREIGN KEY (account_id, employer_id)
    REFERENCES folha.employer (account_id, employer_id),
  CONSTRAINT esocial_event_establishment_fk FOREIGN KEY (account_id, employer_id, establishment_id)
    REFERENCES folha.establishment (account_id, employer_id, establishment_id),
  CONSTRAINT esocial_event_employee_fk FOREIGN KEY (account_id, employee_id)
    REFERENCES folha.employee (account_id, employee_id),
  CONSTRAINT esocial_event_contract_fk FOREIGN KEY (account_id, employer_id, contract_id)
    REFERENCES folha.employment_contract (account_id, employer_id, contract_id),
  CONSTRAINT esocial_event_lot_fk FOREIGN KEY (account_id, lot_id)
    REFERENCES folha.esocial_lot (account_id, lot_id),
  UNIQUE (account_id, event_id),
  UNIQUE (account_id, employer_id, evento_codigo, ambiente, chave_negocio, versao),
  CONSTRAINT esocial_event_retifica_fk FOREIGN KEY (account_id, retifica_event_id)
    REFERENCES folha.esocial_event (account_id, event_id),
  CONSTRAINT esocial_event_exclui_fk FOREIGN KEY (account_id, exclui_event_id)
    REFERENCES folha.esocial_event (account_id, event_id),
  CONSTRAINT esocial_event_retif_coerente CHECK ((ind_retif = 2) = (retifica_event_id IS NOT NULL)),
  CONSTRAINT esocial_event_exclusao_coerente CHECK ((evento_codigo = 'S-3000') = (exclui_event_id IS NOT NULL)),
  CONSTRAINT esocial_event_sem_autorreferencia
    CHECK (retifica_event_id IS DISTINCT FROM event_id AND exclui_event_id IS DISTINCT FROM event_id),
  CONSTRAINT esocial_event_motivo_obrigatorio
    CHECK ((ind_retif = 1 AND evento_codigo <> 'S-3000') OR btrim(COALESCE(motivo, '')) <> ''),
  CONSTRAINT esocial_event_hash_gerado
    CHECK (estado IN ('rascunho', 'pendente_interno', 'cancelado') OR payload_hash IS NOT NULL),
  CONSTRAINT esocial_event_hash_assinado
    CHECK (estado IN ('rascunho', 'pendente_interno', 'gerado', 'cancelado') OR assinado_hash IS NOT NULL),
  CONSTRAINT esocial_event_lote_enviado
    CHECK (estado NOT IN ('enviado', 'em_processamento', 'validado', 'retificado', 'excluido', 'duplicado') OR lot_id IS NOT NULL),
  CONSTRAINT esocial_event_recibo_coerente
    CHECK ((estado IN ('validado', 'retificado', 'excluido')) = (recibo_numero IS NOT NULL)),
  CONSTRAINT esocial_event_advertencia_so_validado
    CHECK (NOT com_advertencia OR estado IN ('validado', 'retificado', 'excluido'))
);
COMMENT ON TABLE folha.esocial_event IS
  'Fila de eventos do eSocial. Uma linha por versão de um evento; mudar o conteúdo gera nova versão (nunca descarte silencioso). O XML e os retornos ficam em esocial_event_payload.';
COMMENT ON COLUMN folha.esocial_event.origem_hash IS 'SHA-256 do conteúdo canônico de origem informado por quem enfileira; base da idempotência (mesmo hash = não gera nada)';
COMMENT ON COLUMN folha.esocial_event.payload_hash IS 'SHA-256 (hex) do XML gerado, calculado pelo banco; imutável depois de gerado';
COMMENT ON COLUMN folha.esocial_event.chave_negocio IS 'Calculada pelo gatilho a partir do catálogo (parecer 4.7); ninguém a informa';
COMMENT ON COLUMN folha.esocial_event.periodo_apuracao IS 'Primeiro dia do mês de apuração; na folha anual (ind_apuracao = 2), 1º de janeiro';

-- Uma única versão aberta por chave: serializa o enfileiramento concorrente.
CREATE UNIQUE INDEX esocial_event_aberto_key
  ON folha.esocial_event (account_id, employer_id, evento_codigo, ambiente, chave_negocio)
  WHERE estado IN ('rascunho', 'pendente_interno', 'gerado', 'assinado', 'enviado', 'em_processamento', 'falha_comunicacao');
CREATE INDEX idx_esocial_event_periodo ON folha.esocial_event (account_id, employer_id, ambiente, periodo_apuracao);
CREATE INDEX idx_esocial_event_trabalhador ON folha.esocial_event (account_id, employee_id) WHERE employee_id IS NOT NULL;
CREATE INDEX idx_esocial_event_lot ON folha.esocial_event (account_id, lot_id) WHERE lot_id IS NOT NULL;
CREATE INDEX idx_esocial_event_retifica ON folha.esocial_event (account_id, retifica_event_id) WHERE retifica_event_id IS NOT NULL;
CREATE INDEX idx_esocial_event_exclui ON folha.esocial_event (account_id, exclui_event_id) WHERE exclui_event_id IS NOT NULL;
CREATE INDEX idx_esocial_event_estado ON folha.esocial_event (account_id, employer_id, estado);

-- 2.4 Origem do evento na folha (vários resultados e várias folhas por evento: o S-1210 junta os
--     pagamentos do mês de um CPF)
CREATE TABLE folha.esocial_event_origin (
  origin_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  event_id uuid NOT NULL,
  run_id uuid NOT NULL,
  result_id uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT esocial_origin_event_fk FOREIGN KEY (account_id, event_id) REFERENCES folha.esocial_event (account_id, event_id),
  CONSTRAINT esocial_origin_run_fk FOREIGN KEY (account_id, run_id) REFERENCES folha.payroll_run (account_id, run_id),
  CONSTRAINT esocial_origin_result_fk FOREIGN KEY (account_id, result_id) REFERENCES folha.payroll_result (account_id, result_id)
);
CREATE UNIQUE INDEX esocial_event_origin_key
  ON folha.esocial_event_origin (event_id, run_id, COALESCE(result_id, '00000000-0000-0000-0000-000000000000'::uuid));
CREATE INDEX idx_esocial_origin_run ON folha.esocial_event_origin (account_id, run_id);

-- 2.5 Participação do evento em lotes (histórico: um reenvio entra em outro lote)
CREATE TABLE folha.esocial_lot_event (
  account_id uuid NOT NULL,
  lot_id uuid NOT NULL,
  event_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (lot_id, event_id),
  CONSTRAINT esocial_lot_event_lot_fk FOREIGN KEY (account_id, lot_id) REFERENCES folha.esocial_lot (account_id, lot_id),
  CONSTRAINT esocial_lot_event_event_fk FOREIGN KEY (account_id, event_id) REFERENCES folha.esocial_event (account_id, event_id)
);
CREATE INDEX idx_esocial_lot_event_event ON folha.esocial_lot_event (account_id, event_id);

-- 2.6 XML e retornos. Só anexa; ninguém atualiza nem apaga. O conteúdo NUNCA vai para log, auditoria
--     ou mensagem de erro; o limite de tamanho é apenas de sanidade (não é regra do leiaute).
CREATE TABLE folha.esocial_event_payload (
  payload_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  event_id uuid,
  lot_id uuid,
  tipo text NOT NULL CHECK (tipo IN ('evento', 'evento_assinado', 'retorno_evento', 'retorno_lote')),
  conteudo text NOT NULL CHECK (octet_length(conteudo) BETWEEN 1 AND 8388608),
  conteudo_hash text NOT NULL CHECK (conteudo_hash ~ '^[0-9a-f]{64}$'),
  criado_por_subject uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT esocial_payload_event_fk FOREIGN KEY (account_id, event_id) REFERENCES folha.esocial_event (account_id, event_id),
  CONSTRAINT esocial_payload_lot_fk FOREIGN KEY (account_id, lot_id) REFERENCES folha.esocial_lot (account_id, lot_id),
  CONSTRAINT esocial_payload_alvo_coerente CHECK ((tipo = 'retorno_lote') = (event_id IS NULL)),
  CONSTRAINT esocial_payload_lote_nos_retornos CHECK (tipo NOT IN ('retorno_lote', 'retorno_evento') OR lot_id IS NOT NULL)
);
CREATE UNIQUE INDEX esocial_payload_evento_key ON folha.esocial_event_payload (event_id) WHERE tipo = 'evento';
CREATE UNIQUE INDEX esocial_payload_assinado_key ON folha.esocial_event_payload (event_id) WHERE tipo = 'evento_assinado';
CREATE UNIQUE INDEX esocial_payload_retorno_evento_key ON folha.esocial_event_payload (lot_id, event_id) WHERE tipo = 'retorno_evento';
CREATE INDEX idx_esocial_payload_retorno_lote ON folha.esocial_event_payload (lot_id) WHERE tipo = 'retorno_lote';

-- 2.7 Ocorrências de retorno (erro ou advertência, por evento e lote)
CREATE TABLE folha.esocial_event_occurrence (
  occurrence_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  account_id uuid NOT NULL,
  event_id uuid NOT NULL,
  lot_id uuid,
  codigo text NOT NULL CHECK (btrim(codigo) <> ''),
  descricao text NOT NULL CHECK (btrim(descricao) <> ''),
  gravidade text NOT NULL CHECK (gravidade IN ('erro', 'advertencia')),
  origem text NOT NULL CHECK (origem IN ('lote', 'evento', 'validacao_interna')),
  localizacao text,
  criado_por_subject uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT esocial_occurrence_event_fk FOREIGN KEY (account_id, event_id) REFERENCES folha.esocial_event (account_id, event_id),
  CONSTRAINT esocial_occurrence_lot_fk FOREIGN KEY (account_id, lot_id) REFERENCES folha.esocial_lot (account_id, lot_id),
  CONSTRAINT esocial_occurrence_lote_nas_de_retorno CHECK (origem = 'validacao_interna' OR lot_id IS NOT NULL)
);
CREATE INDEX idx_esocial_occurrence_event ON folha.esocial_event_occurrence (account_id, event_id, lot_id);

-- ===========================================================================
-- 3. Funções internas (ninguém além do dono executa; o EXECUTE é revogado na seção 8)
-- ===========================================================================

-- 3.1 Auditoria sem conteúdo: o XML e os retornos nunca entram aqui, só ids, estados e hashes.
CREATE FUNCTION folha.esocial_auditar(p_ctx jsonb, p_acao text, p_recurso text, p_recurso_id uuid, p_detalhe jsonb)
RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
BEGIN
  INSERT INTO folha.auditoria (account_id, actor, actor_subject, acao, recurso, recurso_id, detalhe)
  VALUES ((p_ctx->>'account_id')::uuid, p_ctx->>'subject_id', (p_ctx->>'subject_id')::uuid, p_acao, p_recurso, p_recurso_id,
          COALESCE(p_detalhe, '{}'::jsonb)
          || jsonb_build_object('sessao', session_user, 'legal_entity_id', p_ctx->>'legal_entity_id', 'branch_id', p_ctx->>'branch_id'));
END
$function$;

-- 3.2 Texto da chave de negócio (parecer 4.7): formato fixo, componentes ausentes ficam vazios.
CREATE FUNCTION folha.esocial_chave_texto(
  p_codigo text, p_codigo_tabela text, p_inicio_validade date, p_employee uuid, p_contract uuid,
  p_data_efeito date, p_ind smallint, p_periodo date, p_ciclo integer, p_exclui uuid
) RETURNS text
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $function$
  SELECT concat_ws('|',
    p_codigo,
    'cod=' || COALESCE(p_codigo_tabela, ''),
    'iv=' || COALESCE(to_char(p_inicio_validade, 'YYYY-MM-DD'), ''),
    'tr=' || COALESCE(p_employee::text, ''),
    'vi=' || COALESCE(p_contract::text, ''),
    'de=' || COALESCE(to_char(p_data_efeito, 'YYYY-MM-DD'), ''),
    'ap=' || COALESCE(p_ind::text, ''),
    'pe=' || COALESCE(to_char(p_periodo, 'YYYY-MM-DD'), ''),
    'ci=' || COALESCE(p_ciclo::text, ''),
    'ex=' || COALESCE(p_exclui::text, ''));
$function$;

-- 3.3 Como o antecessor A se relaciona com o evento E (mesmo empregador e ambiente já garantidos
--     por quem chama). No período, a apuração mensal vale como indApuracao 1; ciclo só compara
--     quando os dois têm ciclo.
CREATE FUNCTION folha.esocial_escopo_casa(p_escopo text, a folha.esocial_event, b folha.esocial_event)
RETURNS boolean
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $function$
  SELECT CASE p_escopo
    WHEN 'empregador' THEN true
    WHEN 'trabalhador' THEN a.employee_id IS NOT NULL AND a.employee_id = b.employee_id
    WHEN 'vinculo' THEN a.contract_id IS NOT NULL AND a.contract_id = b.contract_id
    WHEN 'periodo' THEN a.periodo_apuracao IS NOT NULL
                        AND a.periodo_apuracao = b.periodo_apuracao
                        AND COALESCE(a.ind_apuracao, 1) = COALESCE(b.ind_apuracao, 1)
                        AND (a.ciclo IS NULL OR b.ciclo IS NULL OR a.ciclo = b.ciclo)
    ELSE false
  END;
$function$;

-- 3.4 O período está fechado? Fechado = há mais fechamentos (S-1299) validados do que reaberturas
--     (S-1298) validadas, contados por ciclo.
CREATE FUNCTION folha.esocial_periodo_fechado(p_conta uuid, p_empregador uuid, p_ambiente text, p_ind smallint, p_periodo date)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
  SELECT (SELECT count(DISTINCT x.ciclo)
            FROM folha.esocial_event x
           WHERE x.account_id = p_conta AND x.employer_id = p_empregador AND x.ambiente = p_ambiente
             AND x.evento_codigo = 'S-1299' AND x.ind_apuracao = COALESCE(p_ind, 1) AND x.periodo_apuracao = p_periodo
             AND x.estado IN ('validado', 'retificado'))
       > (SELECT count(DISTINCT x.ciclo)
            FROM folha.esocial_event x
           WHERE x.account_id = p_conta AND x.employer_id = p_empregador AND x.ambiente = p_ambiente
             AND x.evento_codigo = 'S-1298' AND x.ind_apuracao = COALESCE(p_ind, 1) AND x.periodo_apuracao = p_periodo
             AND x.estado IN ('validado', 'retificado'));
$function$;

-- 3.5 Confere a referência do evento contra o catálogo e devolve a chave de negócio e o ciclo.
CREATE FUNCTION folha.esocial_ref_chave(p folha.esocial_event)
RETURNS TABLE (o_chave text, o_ciclo integer)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  c folha.esocial_event_catalog%ROWTYPE;
  v_comp record;
  v_precisa_trabalhador boolean;
  v_ciclo integer;
  v_fech integer;
  v_reab integer;
  v_ind smallint;
BEGIN
  SELECT * INTO c FROM folha.esocial_event_catalog k WHERE k.evento_codigo = p.evento_codigo;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = format('Evento %s fora do catálogo da fila', p.evento_codigo);
  END IF;

  FOR v_comp IN
    SELECT t.nome, t.presente FROM (VALUES
      ('codigo_tabela', p.codigo_tabela IS NOT NULL),
      ('inicio_validade', p.inicio_validade IS NOT NULL),
      ('data_efeito', p.data_efeito IS NOT NULL),
      ('periodo', p.periodo_apuracao IS NOT NULL),
      ('ind_apuracao', p.ind_apuracao IS NOT NULL)) AS t(nome, presente)
  LOOP
    IF v_comp.presente IS DISTINCT FROM (v_comp.nome = ANY (c.chave_componentes)) THEN
      RAISE EXCEPTION USING ERRCODE = '22023',
        MESSAGE = format('Evento %s: o componente de referência "%s" %s', p.evento_codigo, v_comp.nome,
                         CASE WHEN v_comp.presente THEN 'não faz parte da chave deste evento' ELSE 'é obrigatório' END);
    END IF;
  END LOOP;
  v_precisa_trabalhador := 'trabalhador' = ANY (c.chave_componentes) OR 'vinculo' = ANY (c.chave_componentes);
  IF (p.employee_id IS NOT NULL) IS DISTINCT FROM v_precisa_trabalhador THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = format('Evento %s: o trabalhador %s', p.evento_codigo,
                       CASE WHEN p.employee_id IS NOT NULL THEN 'não faz parte da chave deste evento' ELSE 'é obrigatório' END);
  END IF;
  IF (p.contract_id IS NOT NULL) IS DISTINCT FROM ('vinculo' = ANY (c.chave_componentes)) THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = format('Evento %s: o vínculo (contrato) %s', p.evento_codigo,
                       CASE WHEN p.contract_id IS NOT NULL THEN 'não faz parte da chave deste evento' ELSE 'é obrigatório' END);
  END IF;
  IF (p.exclui_event_id IS NOT NULL) IS DISTINCT FROM (p.evento_codigo = 'S-3000') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Só o S-3000 aponta para o evento que exclui';
  END IF;

  IF p.periodo_apuracao IS NOT NULL THEN
    IF p.periodo_apuracao <> date_trunc('month', p.periodo_apuracao)::date THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'periodo_apuracao deve ser o primeiro dia do mês';
    END IF;
    IF p.ind_apuracao = 2 AND extract(month FROM p.periodo_apuracao) <> 1 THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Na folha anual (ind_apuracao 2) o período é 1º de janeiro';
    END IF;
  END IF;

  IF c.chave_ciclo THEN
    IF p.retifica_event_id IS NOT NULL THEN
      SELECT t.ciclo INTO v_ciclo FROM folha.esocial_event t
       WHERE t.account_id = p.account_id AND t.event_id = p.retifica_event_id;
    ELSE
      v_ind := COALESCE(p.ind_apuracao, 1);
      SELECT count(DISTINCT x.ciclo) INTO v_fech FROM folha.esocial_event x
       WHERE x.account_id = p.account_id AND x.employer_id = p.employer_id AND x.ambiente = p.ambiente
         AND x.evento_codigo = 'S-1299' AND x.ind_apuracao = v_ind AND x.periodo_apuracao = p.periodo_apuracao
         AND x.estado IN ('validado', 'retificado');
      SELECT count(DISTINCT x.ciclo) INTO v_reab FROM folha.esocial_event x
       WHERE x.account_id = p.account_id AND x.employer_id = p.employer_id AND x.ambiente = p.ambiente
         AND x.evento_codigo = 'S-1298' AND x.ind_apuracao = v_ind AND x.periodo_apuracao = p.periodo_apuracao
         AND x.estado IN ('validado', 'retificado');
      v_ciclo := v_reab + 1;
      IF p.evento_codigo = 'S-1298' AND v_fech < v_ciclo THEN
        RAISE EXCEPTION USING ERRCODE = '55000',
          MESSAGE = format('O período %s não está fechado (nenhum S-1299 validado a reabrir)', to_char(p.periodo_apuracao, 'YYYY-MM'));
      END IF;
    END IF;
  ELSE
    v_ciclo := NULL;
  END IF;

  o_ciclo := v_ciclo;
  o_chave := folha.esocial_chave_texto(p.evento_codigo, p.codigo_tabela, p.inicio_validade, p.employee_id, p.contract_id,
                                        p.data_efeito, p.ind_apuracao, p.periodo_apuracao, v_ciclo, p.exclui_event_id);
  RETURN NEXT;
END
$function$;

-- 3.6 Antecessores que faltam para o evento (vazio = pode seguir). Uma cadeia (mesma chave) está
--     "ok" se alguma versão dela está validada; "morta" se todas as versões estão canceladas ou
--     excluídas (como se não existisse); senão está "pendente". p_ignorar tira um evento da conta
--     (usado para saber quem depende dele).
CREATE FUNCTION folha.esocial_antecessores_faltando(p_event_id uuid, p_ignorar uuid DEFAULT NULL)
RETURNS TABLE (o_antecessor text, o_motivo text, o_status text)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
#variable_conflict use_column
DECLARE
  e folha.esocial_event;
  r record;
  v_ok integer;
  v_pend integer;
BEGIN
  SELECT * INTO e FROM folha.esocial_event x WHERE x.event_id = p_event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = format('Evento %s não encontrado', p_event_id);
  END IF;
  FOR r IN
    SELECT COALESCE(a.grupo_alternativa, a.antecessor_codigo) AS req,
           a.obrigatoriedade AS obrig,
           string_agg(a.antecessor_codigo, ' ou ' ORDER BY a.antecessor_codigo) AS codigos,
           CASE WHEN bool_or(a.status_validacao = 'firme') THEN 'firme' ELSE 'a_validar' END AS status
      FROM folha.esocial_event_antecessor a
     WHERE a.evento_codigo = e.evento_codigo
     GROUP BY COALESCE(a.grupo_alternativa, a.antecessor_codigo), a.obrigatoriedade
     ORDER BY 1
  LOOP
    SELECT count(*) FILTER (WHERE s.ok), count(*) FILTER (WHERE NOT s.ok AND NOT s.morta)
      INTO v_ok, v_pend
      FROM (
        SELECT p.evento_codigo, p.chave_negocio,
               bool_or(p.estado = 'validado') AS ok,
               bool_and(p.estado IN ('cancelado', 'excluido')) AS morta
          FROM folha.esocial_event p
          JOIN folha.esocial_event_antecessor a
            ON a.evento_codigo = e.evento_codigo AND a.antecessor_codigo = p.evento_codigo
           AND COALESCE(a.grupo_alternativa, a.antecessor_codigo) = r.req AND a.obrigatoriedade = r.obrig
         WHERE p.account_id = e.account_id AND p.employer_id = e.employer_id AND p.ambiente = e.ambiente
           AND p.event_id <> e.event_id
           AND (p_ignorar IS NULL OR p.event_id <> p_ignorar)
           AND folha.esocial_escopo_casa(a.escopo, e, p)
         GROUP BY p.evento_codigo, p.chave_negocio
      ) s;
    IF r.obrig = 'obrigatorio' AND v_ok = 0 THEN
      o_antecessor := r.codigos;
      o_motivo := CASE WHEN v_pend > 0 THEN 'nao_validado' ELSE 'ausente' END;
      o_status := r.status;
      RETURN NEXT;
    ELSIF r.obrig = 'todos_existentes' AND v_pend > 0 THEN
      o_antecessor := r.codigos;
      o_motivo := 'nao_validado';
      o_status := r.status;
      RETURN NEXT;
    END IF;
  END LOOP;
END
$function$;

-- 3.7 O evento B é antecessor de A por alguma regra do catálogo?
CREATE FUNCTION folha.esocial_depende(a folha.esocial_event, b folha.esocial_event) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
  SELECT a.account_id = b.account_id AND a.employer_id = b.employer_id AND a.ambiente = b.ambiente
         AND EXISTS (SELECT 1 FROM folha.esocial_event_antecessor r
                      WHERE r.evento_codigo = a.evento_codigo AND r.antecessor_codigo = b.evento_codigo
                        AND folha.esocial_escopo_casa(r.escopo, a, b));
$function$;

-- 3.8 Quem depende do evento (só os que perderiam um antecessor exigido se ele sumisse).
--     p_apenas_enviados: só os já gerados em diante (gerado, assinado, enviado, validado: os que bloqueiam uma exclusão).
CREATE FUNCTION folha.esocial_dependentes(p_event_id uuid, p_apenas_enviados boolean)
RETURNS SETOF folha.esocial_event
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  t folha.esocial_event;
BEGIN
  SELECT * INTO t FROM folha.esocial_event x WHERE x.event_id = p_event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = format('Evento %s não encontrado', p_event_id);
  END IF;
  RETURN QUERY
    SELECT c.*
      FROM folha.esocial_event c
     WHERE c.account_id = t.account_id AND c.employer_id = t.employer_id AND c.ambiente = t.ambiente
       AND c.event_id <> t.event_id
       AND c.estado = ANY (CASE WHEN p_apenas_enviados
                                THEN ARRAY['gerado', 'assinado', 'enviado', 'em_processamento', 'falha_comunicacao', 'validado']
                                ELSE ARRAY['rascunho', 'pendente_interno', 'gerado', 'assinado', 'enviado', 'em_processamento', 'falha_comunicacao', 'validado'] END)
       AND folha.esocial_depende(c, t)
       AND EXISTS (SELECT 1 FROM folha.esocial_antecessores_faltando(c.event_id, t.event_id));
END
$function$;

-- 3.9 Versão da conferência para a visão (conferida pela conta da sessão: fail-closed por conta).
CREATE FUNCTION folha.esocial_bloqueio_antecessor(p_event_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
  SELECT EXISTS (SELECT 1 FROM folha.esocial_event e
                  WHERE e.event_id = p_event_id
                    AND e.account_id = (SELECT folha.current_account_id())
                    AND EXISTS (SELECT 1 FROM folha.esocial_antecessores_faltando(e.event_id)));
$function$;

-- 3.10 Folha de origem: evento que depende de folha só nasce de folha FECHADA e sem pendência
--      aberta (trava da 0027). Conferida ao enfileirar e de novo ao gerar.
CREATE FUNCTION folha.esocial_origem_conferir(p folha.esocial_event) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  c folha.esocial_event_catalog%ROWTYPE;
  r record;
  v_n integer;
  v_anual boolean := COALESCE(p.ind_apuracao, 1) = 2;
BEGIN
  SELECT * INTO c FROM folha.esocial_event_catalog k WHERE k.evento_codigo = p.evento_codigo;
  IF c.origem_folha = 'nenhuma' THEN
    RETURN;
  END IF;

  IF c.origem_folha = 'obrigatoria' THEN
    IF NOT EXISTS (SELECT 1 FROM folha.esocial_event_origin o WHERE o.account_id = p.account_id AND o.event_id = p.event_id) THEN
      RAISE EXCEPTION USING ERRCODE = '55000',
        MESSAGE = format('O evento %s exige a folha de origem (fechada e sem pendência); nenhuma foi informada', p.evento_codigo);
    END IF;
    FOR r IN
      SELECT o.run_id, o.result_id, u.status, u.employer_id AS run_employer, u.competencia, u.data_pagamento
        FROM folha.esocial_event_origin o
        JOIN folha.payroll_run u ON u.account_id = o.account_id AND u.run_id = o.run_id
       WHERE o.account_id = p.account_id AND o.event_id = p.event_id
    LOOP
      IF r.run_employer IS DISTINCT FROM p.employer_id THEN
        RAISE EXCEPTION USING ERRCODE = '55000',
          MESSAGE = format('A folha %s não é do empregador do evento (folha sem empregador não gera evento)', r.run_id);
      END IF;
      IF r.status <> 'closed' THEN
        RAISE EXCEPTION USING ERRCODE = '55000',
          MESSAGE = format('A folha %s está %s: só folha fechada gera evento', r.run_id,
                           CASE r.status WHEN 'cancelled' THEN 'cancelada' ELSE 'aberta (' || r.status || ')' END);
      END IF;
      SELECT count(*) INTO v_n FROM folha.payroll_pendency d
       WHERE d.account_id = p.account_id AND d.run_id = r.run_id AND d.liberada_em IS NULL;
      IF v_n > 0 THEN
        RAISE EXCEPTION USING ERRCODE = '55000',
          MESSAGE = format('A folha %s tem %s pendência(s) sem liberação: não gera evento', r.run_id, v_n);
      END IF;
      IF p.evento_codigo = 'S-1200' THEN
        IF (NOT v_anual AND date_trunc('month', r.competencia)::date <> p.periodo_apuracao)
           OR (v_anual AND date_trunc('year', r.competencia)::date <> date_trunc('year', p.periodo_apuracao)::date) THEN
          RAISE EXCEPTION USING ERRCODE = '55000',
            MESSAGE = format('A competência da folha %s não é o período de apuração do evento', r.run_id);
        END IF;
      ELSIF p.evento_codigo = 'S-1210' THEN
        IF r.data_pagamento IS NULL OR date_trunc('month', r.data_pagamento)::date <> p.periodo_apuracao THEN
          RAISE EXCEPTION USING ERRCODE = '55000',
            MESSAGE = format('A data de pagamento da folha %s não cai no mês de apuração do S-1210', r.run_id);
        END IF;
      END IF;
      IF p.employee_id IS NOT NULL AND NOT EXISTS (
           SELECT 1 FROM folha.payroll_result pr
            WHERE pr.account_id = p.account_id AND pr.run_id = r.run_id AND pr.employee_id = p.employee_id
              AND (p.contract_id IS NULL OR pr.contract_id = p.contract_id)
              AND (r.result_id IS NULL OR pr.result_id = r.result_id)) THEN
        RAISE EXCEPTION USING ERRCODE = '55000',
          MESSAGE = format('A folha %s não tem resultado do trabalhador do evento', r.run_id);
      END IF;
    END LOOP;
  ELSE
    -- periodo_inteiro (fechamento): nenhuma folha do período aberta e nenhuma fechada com pendência
    IF EXISTS (SELECT 1 FROM folha.payroll_run u
                WHERE u.account_id = p.account_id AND u.employer_id = p.employer_id
                  AND u.status NOT IN ('closed', 'cancelled')
                  AND ((NOT v_anual AND date_trunc('month', u.competencia)::date = p.periodo_apuracao)
                       OR (v_anual AND date_trunc('year', u.competencia)::date = date_trunc('year', p.periodo_apuracao)::date))) THEN
      RAISE EXCEPTION USING ERRCODE = '55000',
        MESSAGE = format('O período %s tem folha aberta: o fechamento só nasce com todas as folhas fechadas', to_char(p.periodo_apuracao, 'YYYY-MM'));
    END IF;
    IF EXISTS (SELECT 1 FROM folha.payroll_run u
                JOIN folha.payroll_pendency d ON d.account_id = u.account_id AND d.run_id = u.run_id AND d.liberada_em IS NULL
               WHERE u.account_id = p.account_id AND u.employer_id = p.employer_id AND u.status = 'closed'
                 AND ((NOT v_anual AND date_trunc('month', u.competencia)::date = p.periodo_apuracao)
                      OR (v_anual AND date_trunc('year', u.competencia)::date = date_trunc('year', p.periodo_apuracao)::date))) THEN
      RAISE EXCEPTION USING ERRCODE = '55000',
        MESSAGE = format('O período %s tem folha com pendência sem liberação', to_char(p.periodo_apuracao, 'YYYY-MM'));
    END IF;
  END IF;
END
$function$;

-- ===========================================================================
-- 4. Gatilhos
-- ===========================================================================

-- 4.1 Histórico: sem DELETE (e sem UPDATE nas tabelas só de anexar) e sem TRUNCATE.
CREATE FUNCTION folha.esocial_imutavel() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  RAISE EXCEPTION USING ERRCODE = '55000',
    MESSAGE = format('folha.%s é histórico: %s é proibido', TG_TABLE_NAME, TG_OP);
END
$function$;

CREATE FUNCTION folha.esocial_sem_truncate() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = format('folha.%s: TRUNCATE é proibido', TG_TABLE_NAME);
END
$function$;

-- 4.2 Liberação de produção por empregador (folha.admin; o subject vem do contexto)
CREATE FUNCTION folha.esocial_setting_guarda() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx record;
BEGIN
  SELECT x.account_id, x.subject_id INTO v_ctx FROM folha.contexto_v1('folha.admin') AS x;
  IF v_ctx.account_id IS DISTINCT FROM NEW.account_id THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Configuração de outra conta';
  END IF;
  NEW.definido_por_subject := v_ctx.subject_id;
  NEW.definido_em := now();
  RETURN NEW;
END
$function$;

-- 4.3 Evento: identidade, máquina de estados, antecessores, folha fechada, imutabilidade
CREATE FUNCTION folha.esocial_event_guarda() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx record;
  c folha.esocial_event_catalog%ROWTYPE;
  ck folha.esocial_event_catalog%ROWTYPE;
  v_ref record;
  v_alvo folha.esocial_event;
  v_lot folha.esocial_lot;
  v_falta text;
  v_dep text;
BEGIN
  SELECT x.account_id, x.subject_id INTO v_ctx FROM folha.contexto_v1('folha.transmit') AS x;
  IF v_ctx.account_id IS DISTINCT FROM NEW.account_id THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Evento de outra conta';
  END IF;
  SELECT * INTO c FROM folha.esocial_event_catalog k WHERE k.evento_codigo = NEW.evento_codigo;

  IF TG_OP = 'INSERT' THEN
    IF NEW.estado <> 'rascunho' THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'O evento nasce em rascunho';
    END IF;
    IF NOT c.habilitado OR c.eh_retorno THEN
      RAISE EXCEPTION USING ERRCODE = '22023',
        MESSAGE = format('O evento %s não pode ser enfileirado (retorno do governo ou sem fonte nos insumos)', NEW.evento_codigo);
    END IF;
    IF NEW.evento_codigo = 'S-3000' AND NEW.ind_retif = 2 THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'O S-3000 não tem retificação';
    END IF;
    NEW.payload_hash := NULL; NEW.assinado_hash := NULL; NEW.recibo_numero := NULL; NEW.lot_id := NULL;
    NEW.tentativas := 0; NEW.com_advertencia := false;
    NEW.gerado_em := NULL; NEW.assinado_em := NULL; NEW.enviado_em := NULL; NEW.processado_em := NULL;
    NEW.criado_por_subject := v_ctx.subject_id; NEW.atualizado_por_subject := v_ctx.subject_id;
    NEW.created_at := now(); NEW.updated_at := now();

    IF NEW.ambiente = 'producao' AND NOT COALESCE(
         (SELECT s.producao_liberada FROM folha.esocial_employer_setting s
           WHERE s.account_id = NEW.account_id AND s.employer_id = NEW.employer_id), false) THEN
      RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Produção não liberada para este empregador (parecer 4.2)';
    END IF;

    SELECT r.o_chave, r.o_ciclo INTO v_ref FROM folha.esocial_ref_chave(NEW) AS r;
    NEW.chave_negocio := v_ref.o_chave;
    NEW.ciclo := v_ref.o_ciclo;
    PERFORM pg_advisory_xact_lock(hashtextextended(
      NEW.account_id::text || '|' || NEW.employer_id::text || '|' || NEW.ambiente || '|' || NEW.evento_codigo || '|' || NEW.chave_negocio, 0));
    SELECT COALESCE(max(x.versao), 0) + 1 INTO NEW.versao FROM folha.esocial_event x
     WHERE x.account_id = NEW.account_id AND x.employer_id = NEW.employer_id AND x.ambiente = NEW.ambiente
       AND x.evento_codigo = NEW.evento_codigo AND x.chave_negocio = NEW.chave_negocio;

    IF NEW.ind_retif = 2 THEN
      SELECT * INTO v_alvo FROM folha.esocial_event x WHERE x.account_id = NEW.account_id AND x.event_id = NEW.retifica_event_id;
      IF NOT FOUND OR v_alvo.estado <> 'validado' OR v_alvo.recibo_numero IS NULL
         OR v_alvo.evento_codigo <> NEW.evento_codigo OR v_alvo.employer_id <> NEW.employer_id
         OR v_alvo.ambiente <> NEW.ambiente OR v_alvo.chave_negocio <> NEW.chave_negocio THEN
        RAISE EXCEPTION USING ERRCODE = '55000',
          MESSAGE = 'A retificação exige o evento original validado, com recibo, da mesma chave';
      END IF;
      IF EXISTS (SELECT 1 FROM folha.esocial_event x
                  WHERE x.account_id = NEW.account_id AND x.exclui_event_id = NEW.retifica_event_id
                    AND x.estado IN ('rascunho', 'pendente_interno', 'gerado', 'assinado', 'enviado', 'em_processamento', 'falha_comunicacao')) THEN
        RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Há S-3000 em andamento para este evento: conclua ou cancele a exclusão antes de retificar';
      END IF;
    ELSIF EXISTS (SELECT 1 FROM folha.esocial_event x
                   WHERE x.account_id = NEW.account_id AND x.employer_id = NEW.employer_id AND x.ambiente = NEW.ambiente
                     AND x.evento_codigo = NEW.evento_codigo AND x.chave_negocio = NEW.chave_negocio AND x.estado = 'validado') THEN
      RAISE EXCEPTION USING ERRCODE = '55000',
        MESSAGE = 'Já existe versão validada desta chave: a mudança é retificação (esocial_evento_retificar_v1)';
    END IF;

    IF c.grupo = 'periodicos' AND NEW.evento_codigo NOT IN ('S-1298', 'S-1299')
       AND folha.esocial_periodo_fechado(NEW.account_id, NEW.employer_id, NEW.ambiente, NEW.ind_apuracao, NEW.periodo_apuracao) THEN
      RAISE EXCEPTION USING ERRCODE = '55000',
        MESSAGE = format('O período %s está fechado: reabra com o S-1298 antes de gerar evento periódico', to_char(NEW.periodo_apuracao, 'YYYY-MM'));
    END IF;

    IF NEW.evento_codigo = 'S-3000' THEN
      SELECT * INTO v_alvo FROM folha.esocial_event x WHERE x.account_id = NEW.account_id AND x.event_id = NEW.exclui_event_id;
      IF NOT FOUND OR v_alvo.estado <> 'validado' OR v_alvo.recibo_numero IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'A exclusão exige o evento validado, com recibo vigente';
      END IF;
      IF v_alvo.employer_id <> NEW.employer_id OR v_alvo.ambiente <> NEW.ambiente THEN
        RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'A exclusão tem de ser do mesmo empregador e ambiente do evento';
      END IF;
      SELECT * INTO ck FROM folha.esocial_event_catalog k WHERE k.evento_codigo = v_alvo.evento_codigo;
      IF v_alvo.evento_codigo IN ('S-1298', 'S-1299') OR ck.grupo IN ('exclusao', 'totalizadores') THEN
        RAISE EXCEPTION USING ERRCODE = '55000',
          MESSAGE = format('O evento %s não se exclui por S-3000 (fechamento se desfaz pela reabertura S-1298)', v_alvo.evento_codigo);
      END IF;
      IF ck.grupo = 'periodicos'
         AND folha.esocial_periodo_fechado(v_alvo.account_id, v_alvo.employer_id, v_alvo.ambiente, v_alvo.ind_apuracao, v_alvo.periodo_apuracao) THEN
        RAISE EXCEPTION USING ERRCODE = '55000',
          MESSAGE = format('O período %s está fechado: reabra com o S-1298 antes de excluir evento periódico', to_char(v_alvo.periodo_apuracao, 'YYYY-MM'));
      END IF;
      IF EXISTS (SELECT 1 FROM folha.esocial_event x
                  WHERE x.account_id = v_alvo.account_id AND x.employer_id = v_alvo.employer_id AND x.ambiente = v_alvo.ambiente
                    AND x.evento_codigo = v_alvo.evento_codigo AND x.chave_negocio = v_alvo.chave_negocio
                    AND x.estado IN ('rascunho', 'pendente_interno', 'gerado', 'assinado', 'enviado', 'em_processamento', 'falha_comunicacao')) THEN
        RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Há versão deste evento em andamento: conclua ou cancele antes de excluir';
      END IF;
      IF EXISTS (SELECT 1 FROM folha.esocial_event x
                  WHERE x.account_id = v_alvo.account_id AND x.retifica_event_id = v_alvo.event_id
                    AND x.estado IN ('rascunho', 'pendente_interno', 'gerado', 'assinado', 'enviado', 'em_processamento', 'falha_comunicacao')) THEN
        RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Há retificação em andamento deste evento: conclua ou cancele antes de excluir';
      END IF;
      SELECT string_agg(DISTINCT d.evento_codigo, ', ' ORDER BY d.evento_codigo) INTO v_dep
        FROM folha.esocial_dependentes(v_alvo.event_id, true) AS d;
      IF v_dep IS NOT NULL THEN
        RAISE EXCEPTION USING ERRCODE = '55000',
          MESSAGE = format('O evento tem dependentes enviados (%s): exclua os dependentes antes', v_dep);
      END IF;
    END IF;
    RETURN NEW;
  END IF;

  -- UPDATE ---------------------------------------------------------------
  IF ROW(NEW.account_id, NEW.employer_id, NEW.establishment_id, NEW.evento_codigo, NEW.ambiente, NEW.ind_apuracao,
         NEW.periodo_apuracao, NEW.ciclo, NEW.employee_id, NEW.contract_id, NEW.data_efeito, NEW.inicio_validade,
         NEW.codigo_tabela, NEW.chave_negocio, NEW.versao, NEW.ind_retif, NEW.origem_hash, NEW.retifica_event_id,
         NEW.exclui_event_id, NEW.motivo, NEW.criado_por_subject, NEW.created_at)
     IS DISTINCT FROM
     ROW(OLD.account_id, OLD.employer_id, OLD.establishment_id, OLD.evento_codigo, OLD.ambiente, OLD.ind_apuracao,
         OLD.periodo_apuracao, OLD.ciclo, OLD.employee_id, OLD.contract_id, OLD.data_efeito, OLD.inicio_validade,
         OLD.codigo_tabela, OLD.chave_negocio, OLD.versao, OLD.ind_retif, OLD.origem_hash, OLD.retifica_event_id,
         OLD.exclui_event_id, OLD.motivo, OLD.criado_por_subject, OLD.created_at) THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'A identidade do evento (empregador, código, referência, versão, origem, retificação, exclusão) é imutável';
  END IF;

  NEW.atualizado_por_subject := v_ctx.subject_id;
  NEW.updated_at := now();

  IF NEW.estado = OLD.estado THEN
    IF ROW(NEW.payload_hash, NEW.assinado_hash, NEW.recibo_numero, NEW.lot_id, NEW.tentativas, NEW.com_advertencia,
           NEW.gerado_em, NEW.assinado_em, NEW.enviado_em, NEW.processado_em)
       IS DISTINCT FROM
       ROW(OLD.payload_hash, OLD.assinado_hash, OLD.recibo_numero, OLD.lot_id, OLD.tentativas, OLD.com_advertencia,
           OLD.gerado_em, OLD.assinado_em, OLD.enviado_em, OLD.processado_em) THEN
      RAISE EXCEPTION USING ERRCODE = '55000',
        MESSAGE = 'Hash, recibo, lote e carimbos só mudam numa transição de estado (payload e hash são imutáveis depois de gerado)';
    END IF;
    RETURN NEW;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM folha.esocial_event_transition t WHERE t.de = OLD.estado AND t.para = NEW.estado) THEN
    RAISE EXCEPTION USING ERRCODE = '55000',
      MESSAGE = format('Transição inválida do evento: de %s para %s', OLD.estado, NEW.estado);
  END IF;

  IF NEW.payload_hash IS DISTINCT FROM OLD.payload_hash AND NOT (OLD.estado = 'pendente_interno' AND NEW.estado = 'gerado') THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'O hash do XML é imutável depois de gerado';
  END IF;
  IF NEW.assinado_hash IS DISTINCT FROM OLD.assinado_hash AND NOT (OLD.estado = 'gerado' AND NEW.estado = 'assinado') THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'O hash do XML assinado é imutável depois de assinado';
  END IF;
  IF NEW.recibo_numero IS DISTINCT FROM OLD.recibo_numero AND NOT (OLD.estado = 'em_processamento' AND NEW.estado = 'validado') THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'O recibo só é gravado no retorno que valida o evento';
  END IF;
  IF OLD.estado = 'falha_comunicacao' AND NEW.estado = 'assinado' THEN
    NEW.lot_id := NULL;
  ELSIF NEW.lot_id IS DISTINCT FROM OLD.lot_id AND NOT (OLD.estado = 'assinado' AND NEW.estado = 'enviado') THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'O lote do evento só muda ao enviar (ou ao voltar da falha de comunicação)';
  END IF;
  NEW.tentativas := CASE WHEN NEW.estado = 'enviado' THEN OLD.tentativas + 1 ELSE OLD.tentativas END;
  NEW.com_advertencia := CASE WHEN NEW.estado = 'validado'
                              THEN EXISTS (SELECT 1 FROM folha.esocial_event_occurrence o
                                            WHERE o.account_id = NEW.account_id AND o.event_id = NEW.event_id
                                              AND o.lot_id IS NOT DISTINCT FROM NEW.lot_id AND o.gravidade = 'advertencia')
                              ELSE OLD.com_advertencia END;
  NEW.gerado_em := CASE WHEN NEW.estado = 'gerado' THEN now() ELSE OLD.gerado_em END;
  NEW.assinado_em := CASE WHEN NEW.estado = 'assinado' THEN now() ELSE OLD.assinado_em END;
  NEW.enviado_em := CASE WHEN NEW.estado = 'enviado' THEN now() ELSE OLD.enviado_em END;
  NEW.processado_em := CASE WHEN NEW.estado IN ('validado', 'rejeitado', 'duplicado') THEN now() ELSE OLD.processado_em END;

  IF NEW.estado = 'gerado' THEN
    IF NEW.payload_hash IS NULL OR NOT EXISTS (
         SELECT 1 FROM folha.esocial_event_payload p
          WHERE p.account_id = NEW.account_id AND p.event_id = NEW.event_id AND p.tipo = 'evento' AND p.conteudo_hash = NEW.payload_hash) THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'XML gerado ausente ou com hash diferente do guardado';
    END IF;
    SELECT string_agg(f.o_antecessor || ' (' || f.o_motivo || CASE WHEN f.o_status = 'a_validar' THEN ', regra a validar' ELSE '' END || ')', '; ' ORDER BY f.o_antecessor)
      INTO v_falta FROM folha.esocial_antecessores_faltando(NEW.event_id) AS f;
    IF v_falta IS NOT NULL THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = format('Antecessor não validado: %s', v_falta);
    END IF;
    PERFORM folha.esocial_origem_conferir(NEW);
    IF c.grupo = 'periodicos' AND NEW.evento_codigo NOT IN ('S-1298', 'S-1299')
       AND folha.esocial_periodo_fechado(NEW.account_id, NEW.employer_id, NEW.ambiente, NEW.ind_apuracao, NEW.periodo_apuracao) THEN
      RAISE EXCEPTION USING ERRCODE = '55000',
        MESSAGE = format('O período %s está fechado: reabra com o S-1298 antes', to_char(NEW.periodo_apuracao, 'YYYY-MM'));
    END IF;
  ELSIF NEW.estado = 'assinado' THEN
    IF OLD.estado = 'gerado' AND (NEW.assinado_hash IS NULL OR NOT EXISTS (
         SELECT 1 FROM folha.esocial_event_payload p
          WHERE p.account_id = NEW.account_id AND p.event_id = NEW.event_id AND p.tipo = 'evento_assinado' AND p.conteudo_hash = NEW.assinado_hash)) THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'XML assinado ausente ou com hash diferente do guardado';
    END IF;
  ELSIF NEW.estado = 'enviado' THEN
    SELECT string_agg(f.o_antecessor || ' (' || f.o_motivo || ')', '; ' ORDER BY f.o_antecessor) INTO v_falta
      FROM folha.esocial_antecessores_faltando(NEW.event_id) AS f;
    IF v_falta IS NOT NULL THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = format('Antecessor deixou de estar validado antes do envio: %s', v_falta);
    END IF;
    IF c.grupo = 'periodicos' AND NEW.evento_codigo NOT IN ('S-1298', 'S-1299')
       AND folha.esocial_periodo_fechado(NEW.account_id, NEW.employer_id, NEW.ambiente, NEW.ind_apuracao, NEW.periodo_apuracao) THEN
      RAISE EXCEPTION USING ERRCODE = '55000',
        MESSAGE = format('O período %s está fechado: reabra com o S-1298 antes de enviar', to_char(NEW.periodo_apuracao, 'YYYY-MM'));
    END IF;
    SELECT * INTO v_lot FROM folha.esocial_lot l WHERE l.account_id = NEW.account_id AND l.lot_id = NEW.lot_id;
    IF NOT FOUND OR v_lot.situacao <> 'enviado' OR v_lot.employer_id <> NEW.employer_id OR v_lot.ambiente <> NEW.ambiente
       OR NOT EXISTS (SELECT 1 FROM folha.esocial_lot_event le WHERE le.lot_id = NEW.lot_id AND le.event_id = NEW.event_id) THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'O evento só é enviado dentro de um lote do mesmo empregador e ambiente que o inclui';
    END IF;
    IF NEW.ambiente = 'producao' AND NOT COALESCE(
         (SELECT s.producao_liberada FROM folha.esocial_employer_setting s
           WHERE s.account_id = NEW.account_id AND s.employer_id = NEW.employer_id), false) THEN
      RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Produção não liberada para este empregador (parecer 4.2)';
    END IF;
  ELSIF NEW.estado = 'em_processamento' THEN
    IF NOT EXISTS (SELECT 1 FROM folha.esocial_lot l WHERE l.account_id = NEW.account_id AND l.lot_id = NEW.lot_id AND l.situacao = 'recebido') THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'O evento só entra em processamento com o lote recebido (protocolo)';
    END IF;
  ELSIF NEW.estado = 'falha_comunicacao' THEN
    IF NOT EXISTS (SELECT 1 FROM folha.esocial_lot l WHERE l.account_id = NEW.account_id AND l.lot_id = NEW.lot_id
                    AND l.situacao IN ('erro_servidor', 'sem_resposta')) THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Falha de comunicação exige o lote com erro do servidor ou sem resposta';
    END IF;
  ELSIF NEW.estado IN ('validado', 'rejeitado', 'duplicado') THEN
    IF NOT EXISTS (SELECT 1 FROM folha.esocial_lot l WHERE l.account_id = NEW.account_id AND l.lot_id = NEW.lot_id
                    AND l.situacao = CASE WHEN OLD.estado = 'enviado' THEN 'lote_incorreto' ELSE 'recebido' END) THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'O resultado do evento tem de vir do retorno do lote dele';
    END IF;
    IF NEW.estado = 'validado' THEN
      IF NEW.recibo_numero IS NULL THEN
        RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Evento validado exige o número do recibo';
      END IF;
      IF EXISTS (SELECT 1 FROM folha.esocial_event_occurrence o
                  WHERE o.account_id = NEW.account_id AND o.event_id = NEW.event_id AND o.lot_id = NEW.lot_id AND o.gravidade = 'erro') THEN
        RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Evento com ocorrência de erro no retorno não pode ser validado';
      END IF;
    ELSIF NOT EXISTS (SELECT 1 FROM folha.esocial_event_occurrence o
                       WHERE o.account_id = NEW.account_id AND o.event_id = NEW.event_id AND o.lot_id = NEW.lot_id
                         AND (o.gravidade = 'erro' OR NEW.estado = 'duplicado')) THEN
      RAISE EXCEPTION USING ERRCODE = '55000',
        MESSAGE = format('Evento %s exige ao menos uma ocorrência registrada no retorno', NEW.estado);
    END IF;
  ELSIF NEW.estado = 'retificado' THEN
    IF NOT EXISTS (SELECT 1 FROM folha.esocial_event x WHERE x.account_id = NEW.account_id AND x.retifica_event_id = NEW.event_id AND x.estado = 'validado') THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Só passa a retificado quando a retificação foi validada';
    END IF;
  ELSIF NEW.estado = 'excluido' THEN
    IF NOT EXISTS (SELECT 1 FROM folha.esocial_event x WHERE x.account_id = NEW.account_id AND x.exclui_event_id = NEW.event_id AND x.estado = 'validado') THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Só passa a excluído quando o S-3000 foi validado';
    END IF;
  ELSIF NEW.estado = 'cancelado' THEN
    IF NEW.lot_id IS NOT NULL THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Evento em lote não se cancela';
    END IF;
  END IF;
  RETURN NEW;
END
$function$;

-- 4.4 Lote
CREATE FUNCTION folha.esocial_lot_guarda() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx record;
BEGIN
  SELECT x.account_id, x.subject_id INTO v_ctx FROM folha.contexto_v1('folha.transmit') AS x;
  IF v_ctx.account_id IS DISTINCT FROM NEW.account_id THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Lote de outra conta';
  END IF;
  IF TG_OP = 'INSERT' THEN
    NEW.situacao := 'enviado'; NEW.protocolo := NULL; NEW.codigo_resposta := NULL;
    NEW.respondido_em := NULL; NEW.processado_em := NULL;
    NEW.enviado_em := now(); NEW.created_at := now(); NEW.updated_at := now();
    NEW.enviado_por_subject := v_ctx.subject_id; NEW.atualizado_por_subject := v_ctx.subject_id;
    IF NEW.ambiente = 'producao' AND NOT COALESCE(
         (SELECT s.producao_liberada FROM folha.esocial_employer_setting s
           WHERE s.account_id = NEW.account_id AND s.employer_id = NEW.employer_id), false) THEN
      RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Produção não liberada para este empregador (parecer 4.2)';
    END IF;
    RETURN NEW;
  END IF;

  IF ROW(NEW.account_id, NEW.employer_id, NEW.ambiente, NEW.grupo, NEW.qtd_eventos, NEW.enviado_em, NEW.enviado_por_subject, NEW.created_at)
     IS DISTINCT FROM
     ROW(OLD.account_id, OLD.employer_id, OLD.ambiente, OLD.grupo, OLD.qtd_eventos, OLD.enviado_em, OLD.enviado_por_subject, OLD.created_at) THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'A identidade do lote é imutável';
  END IF;
  NEW.atualizado_por_subject := v_ctx.subject_id;
  NEW.updated_at := now();
  IF NEW.situacao = OLD.situacao THEN
    IF ROW(NEW.protocolo, NEW.codigo_resposta, NEW.respondido_em, NEW.processado_em)
       IS DISTINCT FROM ROW(OLD.protocolo, OLD.codigo_resposta, OLD.respondido_em, OLD.processado_em) THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Protocolo e resposta do lote só mudam numa transição de situação';
    END IF;
    RETURN NEW;
  END IF;
  IF NOT ((OLD.situacao = 'enviado' AND NEW.situacao IN ('recebido', 'erro_servidor', 'lote_incorreto', 'sem_resposta'))
          OR (OLD.situacao = 'recebido' AND NEW.situacao = 'processado')) THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = format('Transição inválida do lote: de %s para %s', OLD.situacao, NEW.situacao);
  END IF;
  IF NEW.protocolo IS DISTINCT FROM OLD.protocolo AND NOT (OLD.situacao = 'enviado' AND NEW.situacao = 'recebido') THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'O protocolo só é gravado quando o lote é recebido';
  END IF;
  IF NEW.situacao = 'recebido' AND NEW.protocolo IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Lote recebido exige o protocolo';
  END IF;
  IF NEW.situacao = 'processado' THEN
    NEW.codigo_resposta := OLD.codigo_resposta;
  ELSIF NOT ((NEW.situacao = 'recebido' AND NEW.codigo_resposta IN ('201', '202'))
             OR (NEW.situacao = 'erro_servidor' AND NEW.codigo_resposta = '301')
             OR (NEW.situacao = 'lote_incorreto' AND NEW.codigo_resposta IN ('401', '402'))
             OR (NEW.situacao = 'sem_resposta' AND NEW.codigo_resposta IS NULL)) THEN
    RAISE EXCEPTION USING ERRCODE = '55000',
      MESSAGE = format('Código de resposta %s incompatível com a situação %s (201/202 recebido, 301 erro do servidor, 401/402 lote incorreto)',
                       COALESCE(NEW.codigo_resposta, 'nulo'), NEW.situacao);
  END IF;
  IF NEW.situacao = 'processado' THEN
    NEW.processado_em := now();
    NEW.respondido_em := OLD.respondido_em;
  ELSE
    NEW.respondido_em := now();
  END IF;
  RETURN NEW;
END
$function$;

-- 4.5 Participação no lote: só evento assinado, do mesmo empregador, ambiente e grupo; respeita o
--     total declarado (no máximo 50) e o lote próprio do fechamento.
CREATE FUNCTION folha.esocial_lot_event_guarda() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx record;
  v_lot folha.esocial_lot;
  v_ev folha.esocial_event;
  v_k folha.esocial_event_catalog%ROWTYPE;
BEGIN
  SELECT x.account_id INTO v_ctx FROM folha.contexto_v1('folha.transmit') AS x;
  IF v_ctx.account_id IS DISTINCT FROM NEW.account_id THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Lote de outra conta';
  END IF;
  SELECT * INTO v_lot FROM folha.esocial_lot l WHERE l.account_id = NEW.account_id AND l.lot_id = NEW.lot_id;
  SELECT * INTO v_ev FROM folha.esocial_event e WHERE e.account_id = NEW.account_id AND e.event_id = NEW.event_id;
  SELECT * INTO v_k FROM folha.esocial_event_catalog k WHERE k.evento_codigo = v_ev.evento_codigo;
  IF v_lot.situacao <> 'enviado' OR v_ev.estado <> 'assinado' OR v_ev.lot_id IS NOT NULL
     OR v_ev.employer_id <> v_lot.employer_id OR v_ev.ambiente <> v_lot.ambiente OR v_k.grupo <> v_lot.grupo THEN
    RAISE EXCEPTION USING ERRCODE = '55000',
      MESSAGE = 'O lote só recebe evento assinado, fora de outro lote, do mesmo empregador, ambiente e grupo';
  END IF;
  IF (SELECT count(*) FROM folha.esocial_lot_event le WHERE le.lot_id = NEW.lot_id) >= v_lot.qtd_eventos THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'O lote já tem os eventos declarados (no máximo 50 por lote)';
  END IF;
  IF EXISTS (SELECT 1 FROM folha.esocial_lot_event le
               JOIN folha.esocial_event e ON e.event_id = le.event_id
               JOIN folha.esocial_event_catalog k ON k.evento_codigo = e.evento_codigo
              WHERE le.lot_id = NEW.lot_id
                AND (v_k.lote_proprio OR k.lote_proprio) AND e.evento_codigo <> v_ev.evento_codigo) THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'O fechamento (S-1299) vai em lote próprio (parecer 4.3)';
  END IF;
  RETURN NEW;
END
$function$;

-- 4.6 XML e retornos: o banco calcula o hash e confere o estado do evento no momento de gravar
CREATE FUNCTION folha.esocial_payload_guarda() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx record;
  v_ev folha.esocial_event;
  v_sit text;
BEGIN
  SELECT x.account_id, x.subject_id INTO v_ctx FROM folha.contexto_v1('folha.transmit') AS x;
  IF v_ctx.account_id IS DISTINCT FROM NEW.account_id THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Conteúdo de outra conta';
  END IF;
  NEW.conteudo_hash := encode(sha256(convert_to(NEW.conteudo, 'UTF8')), 'hex');
  NEW.criado_por_subject := v_ctx.subject_id;
  NEW.created_at := now();
  IF NEW.event_id IS NOT NULL THEN
    SELECT * INTO v_ev FROM folha.esocial_event e WHERE e.account_id = NEW.account_id AND e.event_id = NEW.event_id;
    IF (NEW.tipo = 'evento' AND v_ev.estado <> 'pendente_interno')
       OR (NEW.tipo = 'evento_assinado' AND v_ev.estado <> 'gerado')
       OR (NEW.tipo = 'retorno_evento' AND (v_ev.estado NOT IN ('enviado', 'em_processamento') OR v_ev.lot_id IS DISTINCT FROM NEW.lot_id)) THEN
      RAISE EXCEPTION USING ERRCODE = '55000',
        MESSAGE = format('Conteúdo do tipo %s não cabe no estado %s do evento', NEW.tipo, v_ev.estado);
    END IF;
  ELSE
    SELECT l.situacao INTO v_sit FROM folha.esocial_lot l WHERE l.account_id = NEW.account_id AND l.lot_id = NEW.lot_id;
    IF v_sit IS NULL OR v_sit NOT IN ('enviado', 'recebido') THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'O retorno do lote só é guardado enquanto o lote espera resposta';
    END IF;
  END IF;
  RETURN NEW;
END
$function$;

-- 4.7 Ocorrência de retorno
CREATE FUNCTION folha.esocial_occurrence_guarda() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx record;
BEGIN
  SELECT x.account_id, x.subject_id INTO v_ctx FROM folha.contexto_v1('folha.transmit') AS x;
  IF v_ctx.account_id IS DISTINCT FROM NEW.account_id THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Ocorrência de outra conta';
  END IF;
  NEW.criado_por_subject := v_ctx.subject_id;
  NEW.created_at := now();
  IF NEW.lot_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM folha.esocial_lot_event le WHERE le.lot_id = NEW.lot_id AND le.event_id = NEW.event_id) THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'O evento não participou do lote da ocorrência';
  END IF;
  RETURN NEW;
END
$function$;

-- 4.8 Origem do evento: só enquanto o evento ainda é rascunho ou pendente interno
CREATE FUNCTION folha.esocial_origin_guarda() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx record;
BEGIN
  SELECT x.account_id INTO v_ctx FROM folha.contexto_v1('folha.transmit') AS x;
  IF v_ctx.account_id IS DISTINCT FROM NEW.account_id THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Origem de outra conta';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM folha.esocial_event e
                  WHERE e.account_id = NEW.account_id AND e.event_id = NEW.event_id AND e.estado IN ('rascunho', 'pendente_interno')) THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'A origem só se registra enquanto o evento é rascunho ou pendente interno';
  END IF;
  NEW.created_at := now();
  RETURN NEW;
END
$function$;

CREATE TRIGGER trg_esocial_setting_guarda BEFORE INSERT OR UPDATE ON folha.esocial_employer_setting
  FOR EACH ROW EXECUTE FUNCTION folha.esocial_setting_guarda();
CREATE TRIGGER trg_esocial_lot_guarda BEFORE INSERT OR UPDATE ON folha.esocial_lot
  FOR EACH ROW EXECUTE FUNCTION folha.esocial_lot_guarda();
CREATE TRIGGER trg_esocial_event_guarda BEFORE INSERT OR UPDATE ON folha.esocial_event
  FOR EACH ROW EXECUTE FUNCTION folha.esocial_event_guarda();
CREATE TRIGGER trg_esocial_lot_event_guarda BEFORE INSERT ON folha.esocial_lot_event
  FOR EACH ROW EXECUTE FUNCTION folha.esocial_lot_event_guarda();
CREATE TRIGGER trg_esocial_payload_guarda BEFORE INSERT ON folha.esocial_event_payload
  FOR EACH ROW EXECUTE FUNCTION folha.esocial_payload_guarda();
CREATE TRIGGER trg_esocial_occurrence_guarda BEFORE INSERT ON folha.esocial_event_occurrence
  FOR EACH ROW EXECUTE FUNCTION folha.esocial_occurrence_guarda();
CREATE TRIGGER trg_esocial_origin_guarda BEFORE INSERT ON folha.esocial_event_origin
  FOR EACH ROW EXECUTE FUNCTION folha.esocial_origin_guarda();

CREATE TRIGGER trg_esocial_event_sem_delete BEFORE DELETE ON folha.esocial_event
  FOR EACH ROW EXECUTE FUNCTION folha.esocial_imutavel();
CREATE TRIGGER trg_esocial_lot_sem_delete BEFORE DELETE ON folha.esocial_lot
  FOR EACH ROW EXECUTE FUNCTION folha.esocial_imutavel();
CREATE TRIGGER trg_esocial_setting_sem_delete BEFORE DELETE ON folha.esocial_employer_setting
  FOR EACH ROW EXECUTE FUNCTION folha.esocial_imutavel();
CREATE TRIGGER trg_esocial_payload_imutavel BEFORE UPDATE OR DELETE ON folha.esocial_event_payload
  FOR EACH ROW EXECUTE FUNCTION folha.esocial_imutavel();
CREATE TRIGGER trg_esocial_occurrence_imutavel BEFORE UPDATE OR DELETE ON folha.esocial_event_occurrence
  FOR EACH ROW EXECUTE FUNCTION folha.esocial_imutavel();
CREATE TRIGGER trg_esocial_origin_imutavel BEFORE UPDATE OR DELETE ON folha.esocial_event_origin
  FOR EACH ROW EXECUTE FUNCTION folha.esocial_imutavel();
CREATE TRIGGER trg_esocial_lot_event_imutavel BEFORE UPDATE OR DELETE ON folha.esocial_lot_event
  FOR EACH ROW EXECUTE FUNCTION folha.esocial_imutavel();

CREATE TRIGGER trg_esocial_event_sem_truncate BEFORE TRUNCATE ON folha.esocial_event
  FOR EACH STATEMENT EXECUTE FUNCTION folha.esocial_sem_truncate();
CREATE TRIGGER trg_esocial_lot_sem_truncate BEFORE TRUNCATE ON folha.esocial_lot
  FOR EACH STATEMENT EXECUTE FUNCTION folha.esocial_sem_truncate();
CREATE TRIGGER trg_esocial_setting_sem_truncate BEFORE TRUNCATE ON folha.esocial_employer_setting
  FOR EACH STATEMENT EXECUTE FUNCTION folha.esocial_sem_truncate();
CREATE TRIGGER trg_esocial_payload_sem_truncate BEFORE TRUNCATE ON folha.esocial_event_payload
  FOR EACH STATEMENT EXECUTE FUNCTION folha.esocial_sem_truncate();
CREATE TRIGGER trg_esocial_occurrence_sem_truncate BEFORE TRUNCATE ON folha.esocial_event_occurrence
  FOR EACH STATEMENT EXECUTE FUNCTION folha.esocial_sem_truncate();
CREATE TRIGGER trg_esocial_origin_sem_truncate BEFORE TRUNCATE ON folha.esocial_event_origin
  FOR EACH STATEMENT EXECUTE FUNCTION folha.esocial_sem_truncate();
CREATE TRIGGER trg_esocial_lot_event_sem_truncate BEFORE TRUNCATE ON folha.esocial_lot_event
  FOR EACH STATEMENT EXECUTE FUNCTION folha.esocial_sem_truncate();

-- ===========================================================================
-- 5. Operações internas de apoio
-- ===========================================================================

-- 5.1 Ocorrências do retorno: grava e devolve quantas
CREATE FUNCTION folha.esocial_ocorrencias_gravar(
  p_conta uuid, p_event_id uuid, p_lot_id uuid, p_origem text, p_ocorrencias jsonb
) RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_oc jsonb;
  v_n integer := 0;
BEGIN
  IF p_ocorrencias IS NULL OR jsonb_typeof(p_ocorrencias) <> 'array' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'As ocorrências devem ser uma lista (json array)';
  END IF;
  FOR v_oc IN SELECT value FROM jsonb_array_elements(p_ocorrencias) LOOP
    INSERT INTO folha.esocial_event_occurrence (account_id, event_id, lot_id, codigo, descricao, gravidade, origem, localizacao, criado_por_subject)
    VALUES (p_conta, p_event_id, p_lot_id, v_oc->>'codigo', v_oc->>'descricao', v_oc->>'gravidade', p_origem, v_oc->>'localizacao',
            '00000000-0000-0000-0000-000000000000'::uuid);
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END
$function$;

-- 5.2 Inclui uma versão do evento na cadeia (idempotente). Regras:
--     sem versão anterior: cria a versão 1;
--     mesma origem (hash) e versão anterior viva ou validada: devolve a existente, sem criar nada;
--     origem diferente e versão anterior ainda não enviada: cancela a anterior e cria a nova (substitui);
--     origem diferente e anterior em transmissão: recusa (espere o retorno);
--     anterior rejeitada, duplicada, cancelada ou excluída: cria nova versão;
--     versão validada com origem diferente: só pela retificação (p_retifica).
CREATE FUNCTION folha.esocial_evento_incluir(
  p_conta uuid, p_empregador uuid, p_codigo text, p_ambiente text, p_ref jsonb, p_origem_hash text,
  p_origens jsonb, p_retifica uuid, p_exclui uuid, p_motivo text
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_row folha.esocial_event;
  v_chk record;
  v_ult folha.esocial_event;
  v_val folha.esocial_event;
  v_id uuid;
  v_versao integer;
  v_situacao text := 'criado';
  v_substitui uuid;
  v_invalidas text;
  v_org jsonb;
  v_emp_contrato uuid;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM folha.employer e WHERE e.account_id = p_conta AND e.employer_id = p_empregador) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = format('Empregador %s não encontrado nesta conta', p_empregador);
  END IF;
  IF p_ref IS NULL OR jsonb_typeof(p_ref) <> 'object' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'A referência deve ser um objeto json';
  END IF;
  IF p_origens IS NULL OR jsonb_typeof(p_origens) <> 'array' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'As origens devem ser uma lista (json array)';
  END IF;
  SELECT string_agg(k, ', ') INTO v_invalidas FROM jsonb_object_keys(p_ref) AS k
   WHERE k <> ALL (ARRAY['establishment_id', 'employee_id', 'contract_id', 'ind_apuracao', 'periodo_apuracao',
                         'data_efeito', 'inicio_validade', 'codigo_tabela']);
  IF v_invalidas IS NOT NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = format('Chave(s) de referência desconhecida(s): %s', v_invalidas);
  END IF;

  v_row.account_id := p_conta;
  v_row.employer_id := p_empregador;
  v_row.evento_codigo := p_codigo;
  v_row.ambiente := p_ambiente;
  v_row.establishment_id := (p_ref->>'establishment_id')::uuid;
  v_row.employee_id := (p_ref->>'employee_id')::uuid;
  v_row.contract_id := (p_ref->>'contract_id')::uuid;
  v_row.ind_apuracao := (p_ref->>'ind_apuracao')::smallint;
  v_row.periodo_apuracao := (p_ref->>'periodo_apuracao')::date;
  v_row.data_efeito := (p_ref->>'data_efeito')::date;
  v_row.inicio_validade := (p_ref->>'inicio_validade')::date;
  v_row.codigo_tabela := p_ref->>'codigo_tabela';
  v_row.ind_retif := CASE WHEN p_retifica IS NOT NULL THEN 2 ELSE 1 END;
  v_row.retifica_event_id := p_retifica;
  v_row.exclui_event_id := p_exclui;

  -- o vínculo define o trabalhador (e tem de ser do empregador)
  IF v_row.contract_id IS NOT NULL THEN
    SELECT k.employee_id INTO v_emp_contrato FROM folha.employment_contract k
     WHERE k.account_id = p_conta AND k.employer_id = p_empregador AND k.contract_id = v_row.contract_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = format('Contrato %s não é deste empregador', v_row.contract_id);
    END IF;
    IF v_row.employee_id IS NOT NULL AND v_row.employee_id <> v_emp_contrato THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'O trabalhador informado não é o do contrato';
    END IF;
    v_row.employee_id := v_emp_contrato;
  END IF;

  SELECT r.o_chave, r.o_ciclo INTO v_chk FROM folha.esocial_ref_chave(v_row) AS r;
  PERFORM pg_advisory_xact_lock(hashtextextended(
    p_conta::text || '|' || p_empregador::text || '|' || p_ambiente || '|' || p_codigo || '|' || v_chk.o_chave, 0));

  SELECT * INTO v_ult FROM folha.esocial_event x
   WHERE x.account_id = p_conta AND x.employer_id = p_empregador AND x.ambiente = p_ambiente
     AND x.evento_codigo = p_codigo AND x.chave_negocio = v_chk.o_chave
   ORDER BY x.versao DESC LIMIT 1;
  IF FOUND THEN
    SELECT * INTO v_val FROM folha.esocial_event x
     WHERE x.account_id = p_conta AND x.employer_id = p_empregador AND x.ambiente = p_ambiente
       AND x.evento_codigo = p_codigo AND x.chave_negocio = v_chk.o_chave AND x.estado = 'validado'
     ORDER BY x.versao DESC LIMIT 1;
  END IF;

  IF p_retifica IS NOT NULL THEN
    IF v_ult.estado IN ('rascunho', 'pendente_interno', 'gerado', 'assinado', 'enviado', 'em_processamento', 'falha_comunicacao') THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Já há versão deste evento em andamento: conclua ou cancele antes de retificar';
    END IF;
  ELSIF v_val.event_id IS NOT NULL THEN
    IF v_val.origem_hash = p_origem_hash THEN
      RETURN jsonb_build_object('event_id', v_val.event_id, 'versao', v_val.versao, 'estado', v_val.estado, 'situacao', 'existente');
    END IF;
    RAISE EXCEPTION USING ERRCODE = '55000',
      MESSAGE = 'Já existe versão validada desta chave com outra origem: a mudança é retificação (esocial_evento_retificar_v1)';
  ELSIF v_ult.event_id IS NOT NULL THEN
    IF v_ult.estado IN ('rascunho', 'pendente_interno', 'gerado', 'assinado') THEN
      IF v_ult.origem_hash = p_origem_hash THEN
        RETURN jsonb_build_object('event_id', v_ult.event_id, 'versao', v_ult.versao, 'estado', v_ult.estado, 'situacao', 'existente');
      END IF;
      UPDATE folha.esocial_event x SET estado = 'cancelado' WHERE x.account_id = p_conta AND x.event_id = v_ult.event_id;
      v_substitui := v_ult.event_id;
      v_situacao := 'substituido';
    ELSIF v_ult.estado IN ('enviado', 'em_processamento', 'falha_comunicacao') THEN
      IF v_ult.origem_hash = p_origem_hash THEN
        RETURN jsonb_build_object('event_id', v_ult.event_id, 'versao', v_ult.versao, 'estado', v_ult.estado, 'situacao', 'existente');
      END IF;
      RAISE EXCEPTION USING ERRCODE = '55000',
        MESSAGE = format('A versão %s deste evento está em transmissão (%s): espere o retorno antes de mudar o conteúdo', v_ult.versao, v_ult.estado);
    END IF;
  END IF;

  INSERT INTO folha.esocial_event (
    account_id, employer_id, establishment_id, evento_codigo, ambiente, ind_apuracao, periodo_apuracao,
    employee_id, contract_id, data_efeito, inicio_validade, codigo_tabela, chave_negocio, versao, ind_retif,
    origem_hash, retifica_event_id, exclui_event_id, motivo, criado_por_subject, atualizado_por_subject)
  VALUES (
    p_conta, p_empregador, v_row.establishment_id, p_codigo, p_ambiente, v_row.ind_apuracao, v_row.periodo_apuracao,
    v_row.employee_id, v_row.contract_id, v_row.data_efeito, v_row.inicio_validade, v_row.codigo_tabela, v_chk.o_chave, 1,
    v_row.ind_retif, p_origem_hash, p_retifica, p_exclui, p_motivo,
    '00000000-0000-0000-0000-000000000000'::uuid, '00000000-0000-0000-0000-000000000000'::uuid)
  RETURNING event_id, versao INTO v_id, v_versao;

  FOR v_org IN SELECT value FROM jsonb_array_elements(p_origens) LOOP
    INSERT INTO folha.esocial_event_origin (account_id, event_id, run_id, result_id)
    VALUES (p_conta, v_id, (v_org->>'run_id')::uuid, (v_org->>'result_id')::uuid);
  END LOOP;
  SELECT * INTO v_row FROM folha.esocial_event x WHERE x.account_id = p_conta AND x.event_id = v_id;
  PERFORM folha.esocial_origem_conferir(v_row);

  RETURN jsonb_build_object('event_id', v_id, 'versao', v_versao, 'estado', 'rascunho', 'situacao', v_situacao,
                            'substitui_event_id', v_substitui, 'ind_retif', v_row.ind_retif);
END
$function$;

-- ===========================================================================
-- 6. Funções da sessão de aplicação (EXECUTE só para dnex_gestao_api)
--    Conferem a permissão no início e de novo antes de devolver (a asserção vale até 60 s).
--    Nenhuma recebe conta, subject ou responsável: tudo vem do contexto.
-- ===========================================================================

-- 6.1 Liberar ou bloquear a produção de um empregador (folha.admin)
CREATE FUNCTION folha.esocial_producao_definir_v1(p_employer_id uuid, p_liberada boolean, p_motivo text) RETURNS boolean
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx record;
BEGIN
  SELECT c.account_id, c.legal_entity_id, c.branch_id, c.subject_id INTO v_ctx FROM folha.contexto_v1('folha.admin') AS c;
  IF p_liberada IS NULL OR btrim(COALESCE(p_motivo, '')) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'esocial_producao_definir_v1: informe liberada e o motivo';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM folha.employer e WHERE e.account_id = v_ctx.account_id AND e.employer_id = p_employer_id) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = format('Empregador %s não encontrado nesta conta', p_employer_id);
  END IF;
  INSERT INTO folha.esocial_employer_setting (account_id, employer_id, producao_liberada, motivo, definido_por_subject)
  VALUES (v_ctx.account_id, p_employer_id, p_liberada, btrim(p_motivo), v_ctx.subject_id)
  ON CONFLICT (account_id, employer_id) DO UPDATE
     SET producao_liberada = EXCLUDED.producao_liberada, motivo = EXCLUDED.motivo;
  PERFORM folha.esocial_auditar(to_jsonb(v_ctx), 'esocial_producao_definir', 'employer', p_employer_id,
                                jsonb_build_object('liberada', p_liberada, 'motivo', btrim(p_motivo)));
  PERFORM 1 FROM folha.contexto_v1('folha.admin');
  RETURN p_liberada;
END
$function$;

-- 6.2 Enfileirar (idempotente). A referência é um objeto json com as chaves que o catálogo pede
--     (ver chave_componentes): establishment_id (opcional), employee_id, contract_id, ind_apuracao,
--     periodo_apuracao (1º dia do mês), data_efeito, inicio_validade, codigo_tabela. As origens são
--     uma lista de {"run_id": ..., "result_id": ...} da folha que gerou o evento.
CREATE FUNCTION folha.esocial_evento_enfileirar_v1(
  p_employer_id uuid, p_evento_codigo text, p_ambiente text, p_origem_hash text,
  p_referencia jsonb DEFAULT '{}'::jsonb, p_origens jsonb DEFAULT '[]'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx record;
  v_r jsonb;
BEGIN
  SELECT c.account_id, c.legal_entity_id, c.branch_id, c.subject_id INTO v_ctx FROM folha.contexto_v1('folha.transmit') AS c;
  IF p_evento_codigo = 'S-3000' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'A exclusão (S-3000) nasce de esocial_evento_excluir_v1';
  END IF;
  IF p_evento_codigo = 'S-1298' THEN
    PERFORM 1 FROM folha.contexto_v1('folha.close');   -- reabertura é ação de aprovação (parecer 4.6 e 4.9)
  END IF;
  IF p_ambiente IS NULL OR p_ambiente NOT IN ('producao', 'producao_restrita') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Ambiente deve ser producao ou producao_restrita';
  END IF;
  IF p_origem_hash IS NULL OR p_origem_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'O hash de origem deve ser um SHA-256 em hexadecimal minúsculo (64 caracteres)';
  END IF;
  v_r := folha.esocial_evento_incluir(v_ctx.account_id, p_employer_id, p_evento_codigo, p_ambiente,
                                      COALESCE(p_referencia, '{}'::jsonb), p_origem_hash, COALESCE(p_origens, '[]'::jsonb),
                                      NULL, NULL, NULL);
  PERFORM folha.esocial_auditar(to_jsonb(v_ctx), 'esocial_enfileirar', 'esocial_event', (v_r->>'event_id')::uuid,
                                jsonb_build_object('evento_codigo', p_evento_codigo, 'ambiente', p_ambiente,
                                                   'situacao', v_r->>'situacao', 'versao', v_r->'versao'));
  PERFORM 1 FROM folha.contexto_v1('folha.transmit');
  IF p_evento_codigo = 'S-1298' THEN
    PERFORM 1 FROM folha.contexto_v1('folha.close');
  END IF;
  RETURN v_r;
END
$function$;

-- 6.3 Avançar o estado até assinado, só pelos caminhos válidos. rascunho <-> pendente_interno;
--     pendente_interno -> gerado (com o XML: o banco calcula e guarda o hash; exige antecessores
--     validados e folha fechada); gerado -> assinado (com o XML assinado); falha_comunicacao ->
--     assinado (reenvio, depois de consultar). Envio, retorno, cancelamento, retificação e exclusão
--     têm função própria.
CREATE FUNCTION folha.esocial_evento_avancar_v1(p_event_id uuid, p_para text, p_conteudo text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx record;
  v_e folha.esocial_event;
  v_hash text;
  v_r folha.esocial_event;
BEGIN
  SELECT c.account_id, c.legal_entity_id, c.branch_id, c.subject_id INTO v_ctx FROM folha.contexto_v1('folha.transmit') AS c;
  SELECT * INTO v_e FROM folha.esocial_event x WHERE x.account_id = v_ctx.account_id AND x.event_id = p_event_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = format('Evento %s não encontrado', p_event_id);
  END IF;
  IF p_para IS NULL OR p_para NOT IN ('rascunho', 'pendente_interno', 'gerado', 'assinado') THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = 'Este caminho avança só até assinado (rascunho, pendente_interno, gerado, assinado); envio, retorno, cancelamento, retificação e exclusão têm função própria';
  END IF;

  IF p_para = 'gerado' THEN
    IF v_e.estado <> 'pendente_interno' THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = format('Transição inválida do evento: de %s para gerado', v_e.estado);
    END IF;
    IF p_conteudo IS NULL OR btrim(p_conteudo) = '' THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Gerar exige o conteúdo (XML) do evento';
    END IF;
    INSERT INTO folha.esocial_event_payload (account_id, event_id, tipo, conteudo, conteudo_hash, criado_por_subject)
    VALUES (v_ctx.account_id, p_event_id, 'evento', p_conteudo, repeat('0', 64), v_ctx.subject_id)
    RETURNING conteudo_hash INTO v_hash;
    UPDATE folha.esocial_event x SET estado = 'gerado', payload_hash = v_hash
     WHERE x.account_id = v_ctx.account_id AND x.event_id = p_event_id;
  ELSIF p_para = 'assinado' AND v_e.estado = 'gerado' THEN
    IF p_conteudo IS NULL OR btrim(p_conteudo) = '' THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Assinar exige o XML assinado';
    END IF;
    INSERT INTO folha.esocial_event_payload (account_id, event_id, tipo, conteudo, conteudo_hash, criado_por_subject)
    VALUES (v_ctx.account_id, p_event_id, 'evento_assinado', p_conteudo, repeat('0', 64), v_ctx.subject_id)
    RETURNING conteudo_hash INTO v_hash;
    UPDATE folha.esocial_event x SET estado = 'assinado', assinado_hash = v_hash
     WHERE x.account_id = v_ctx.account_id AND x.event_id = p_event_id;
  ELSE
    IF p_conteudo IS NOT NULL THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Este avanço não recebe conteúdo';
    END IF;
    UPDATE folha.esocial_event x SET estado = p_para
     WHERE x.account_id = v_ctx.account_id AND x.event_id = p_event_id;
  END IF;

  SELECT * INTO v_r FROM folha.esocial_event x WHERE x.account_id = v_ctx.account_id AND x.event_id = p_event_id;
  PERFORM folha.esocial_auditar(to_jsonb(v_ctx), 'esocial_avancar', 'esocial_event', p_event_id,
                                jsonb_build_object('de', v_e.estado, 'para', v_r.estado, 'payload_hash', v_r.payload_hash, 'assinado_hash', v_r.assinado_hash));
  PERFORM 1 FROM folha.contexto_v1('folha.transmit');
  RETURN jsonb_build_object('event_id', p_event_id, 'estado', v_r.estado, 'payload_hash', v_r.payload_hash,
                            'assinado_hash', v_r.assinado_hash, 'tentativas', v_r.tentativas);
END
$function$;

-- 6.4 Cancelar evento ainda não enviado (rascunho, pendente interno, gerado ou assinado fora de lote)
CREATE FUNCTION folha.esocial_evento_cancelar_v1(p_event_id uuid, p_motivo text) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx record;
  v_e folha.esocial_event;
BEGIN
  SELECT c.account_id, c.legal_entity_id, c.branch_id, c.subject_id INTO v_ctx FROM folha.contexto_v1('folha.transmit') AS c;
  IF btrim(COALESCE(p_motivo, '')) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'esocial_evento_cancelar_v1: motivo obrigatório';
  END IF;
  SELECT * INTO v_e FROM folha.esocial_event x WHERE x.account_id = v_ctx.account_id AND x.event_id = p_event_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = format('Evento %s não encontrado', p_event_id);
  END IF;
  IF v_e.estado NOT IN ('rascunho', 'pendente_interno', 'gerado', 'assinado') THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = format('Só se cancela evento ainda não enviado (estado atual: %s)', v_e.estado);
  END IF;
  UPDATE folha.esocial_event x SET estado = 'cancelado' WHERE x.account_id = v_ctx.account_id AND x.event_id = p_event_id;
  PERFORM folha.esocial_auditar(to_jsonb(v_ctx), 'esocial_cancelar', 'esocial_event', p_event_id,
                                jsonb_build_object('de', v_e.estado, 'motivo', btrim(p_motivo)));
  PERFORM 1 FROM folha.contexto_v1('folha.transmit');
  RETURN jsonb_build_object('event_id', p_event_id, 'estado', 'cancelado');
END
$function$;

-- 6.5 Registrar o envio de um lote: cria o lote (até 50 eventos assinados, um empregador, um
--     grupo) e coloca os eventos em enviado. O envio em si é de outro serviço; aqui só o registro.
CREATE FUNCTION folha.esocial_lote_enviar_v1(p_employer_id uuid, p_ambiente text, p_event_ids uuid[]) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx record;
  v_n integer;
  v_grupos integer;
  v_grupo text;
  v_lot uuid;
  v_id uuid;
BEGIN
  SELECT c.account_id, c.legal_entity_id, c.branch_id, c.subject_id INTO v_ctx FROM folha.contexto_v1('folha.transmit') AS c;
  IF p_ambiente IS NULL OR p_ambiente NOT IN ('producao', 'producao_restrita') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Ambiente deve ser producao ou producao_restrita';
  END IF;
  IF p_event_ids IS NULL OR cardinality(p_event_ids) = 0 OR cardinality(p_event_ids) > 50 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Um lote tem de 1 a 50 eventos (parecer 4.3)';
  END IF;
  IF cardinality(p_event_ids) <> (SELECT count(DISTINCT i) FROM unnest(p_event_ids) AS i) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Evento repetido na lista do lote';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM folha.employer e WHERE e.account_id = v_ctx.account_id AND e.employer_id = p_employer_id) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = format('Empregador %s não encontrado nesta conta', p_employer_id);
  END IF;
  PERFORM 1 FROM folha.esocial_event x
   WHERE x.account_id = v_ctx.account_id AND x.event_id = ANY (p_event_ids) ORDER BY x.event_id FOR UPDATE;
  SELECT count(*), count(DISTINCT k.grupo), min(k.grupo) INTO v_n, v_grupos, v_grupo
    FROM folha.esocial_event x JOIN folha.esocial_event_catalog k ON k.evento_codigo = x.evento_codigo
   WHERE x.account_id = v_ctx.account_id AND x.event_id = ANY (p_event_ids)
     AND x.employer_id = p_employer_id AND x.ambiente = p_ambiente AND x.estado = 'assinado' AND x.lot_id IS NULL;
  IF v_n <> cardinality(p_event_ids) THEN
    RAISE EXCEPTION USING ERRCODE = '55000',
      MESSAGE = 'Todos os eventos do lote precisam ser do empregador e do ambiente informados, estar assinados e fora de outro lote';
  END IF;
  IF v_grupos > 1 THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Um lote tem um só grupo de eventos (parecer 4.3)';
  END IF;
  INSERT INTO folha.esocial_lot (account_id, employer_id, ambiente, grupo, qtd_eventos, enviado_por_subject, atualizado_por_subject)
  VALUES (v_ctx.account_id, p_employer_id, p_ambiente, v_grupo, cardinality(p_event_ids), v_ctx.subject_id, v_ctx.subject_id)
  RETURNING lot_id INTO v_lot;
  FOREACH v_id IN ARRAY p_event_ids LOOP
    INSERT INTO folha.esocial_lot_event (account_id, lot_id, event_id) VALUES (v_ctx.account_id, v_lot, v_id);
  END LOOP;
  UPDATE folha.esocial_event x SET estado = 'enviado', lot_id = v_lot
   WHERE x.account_id = v_ctx.account_id AND x.event_id = ANY (p_event_ids);
  PERFORM folha.esocial_auditar(to_jsonb(v_ctx), 'esocial_lote_enviar', 'esocial_lot', v_lot,
                                jsonb_build_object('employer_id', p_employer_id, 'ambiente', p_ambiente, 'grupo', v_grupo, 'eventos', cardinality(p_event_ids)));
  PERFORM 1 FROM folha.contexto_v1('folha.transmit');
  RETURN jsonb_build_object('lot_id', v_lot, 'grupo', v_grupo, 'eventos', cardinality(p_event_ids), 'situacao', 'enviado');
END
$function$;

-- 6.6 Registrar o retorno do lote e dos eventos.
--     p_tipo: recebido (protocolo; 201 ou 202) | erro_servidor (301; reenviável) | sem_resposta |
--             lote_incorreto (401 ou 402; exige ocorrência de erro) | processado (resultado por evento).
--     p_ocorrencias: ocorrências do lote (repetidas em cada evento dele).
--     p_eventos (só em processado): [{"event_id", "resultado": validado|rejeitado|duplicado,
--       "recibo", "ocorrencias": [{"codigo","descricao","gravidade": erro|advertencia,"localizacao"}],
--       "retorno_xml"}]; precisa cobrir exatamente os eventos em processamento do lote.
CREATE FUNCTION folha.esocial_lote_retorno_v1(
  p_lot_id uuid, p_tipo text, p_protocolo text DEFAULT NULL, p_codigo_resposta text DEFAULT NULL,
  p_retorno_xml text DEFAULT NULL, p_ocorrencias jsonb DEFAULT '[]'::jsonb, p_eventos jsonb DEFAULT '[]'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx record;
  v_lot folha.esocial_lot;
  v_ids uuid[];
  v_id uuid;
  v_el jsonb;
  v_res text;
  v_ev folha.esocial_event;
  v_vistos uuid[] := '{}';
  v_validados integer := 0;
  v_rejeitados integer := 0;
  v_duplicados integer := 0;
BEGIN
  SELECT c.account_id, c.legal_entity_id, c.branch_id, c.subject_id INTO v_ctx FROM folha.contexto_v1('folha.transmit') AS c;
  IF p_tipo IS NULL OR p_tipo NOT IN ('recebido', 'erro_servidor', 'sem_resposta', 'lote_incorreto', 'processado') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Tipo de retorno deve ser recebido, erro_servidor, sem_resposta, lote_incorreto ou processado';
  END IF;
  IF p_ocorrencias IS NULL OR jsonb_typeof(p_ocorrencias) <> 'array' OR p_eventos IS NULL OR jsonb_typeof(p_eventos) <> 'array' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Ocorrências e eventos devem ser listas (json array)';
  END IF;
  SELECT * INTO v_lot FROM folha.esocial_lot l WHERE l.account_id = v_ctx.account_id AND l.lot_id = p_lot_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = format('Lote %s não encontrado', p_lot_id);
  END IF;
  IF (p_tipo IN ('recebido', 'erro_servidor', 'sem_resposta', 'lote_incorreto') AND v_lot.situacao <> 'enviado')
     OR (p_tipo = 'processado' AND v_lot.situacao <> 'recebido') THEN
    RAISE EXCEPTION USING ERRCODE = '55000',
      MESSAGE = format('Retorno %s não cabe no lote em situação %s', p_tipo, v_lot.situacao);
  END IF;
  IF (p_tipo = 'recebido' AND (p_codigo_resposta IS NULL OR p_codigo_resposta NOT IN ('201', '202') OR btrim(COALESCE(p_protocolo, '')) = ''))
     OR (p_tipo = 'erro_servidor' AND p_codigo_resposta IS DISTINCT FROM '301')
     OR (p_tipo = 'lote_incorreto' AND (p_codigo_resposta IS NULL OR p_codigo_resposta NOT IN ('401', '402')))
     OR (p_tipo = 'sem_resposta' AND p_codigo_resposta IS NOT NULL) THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = 'Resposta inválida para o tipo: recebido = 201/202 com protocolo; erro_servidor = 301; lote_incorreto = 401/402; sem_resposta = sem código';
  END IF;

  IF p_tipo = 'processado' AND (p_protocolo IS NOT NULL OR p_codigo_resposta IS NOT NULL OR p_ocorrencias <> '[]'::jsonb) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'No retorno processado, protocolo, código e ocorrências do lote não se aplicam: as ocorrências vão em cada evento';
  END IF;
  IF p_tipo <> 'processado' AND p_eventos <> '[]'::jsonb THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Resultados por evento só no retorno processado';
  END IF;

  -- eventos do lote ainda esperando resposta
  SELECT COALESCE(array_agg(x.event_id ORDER BY x.event_id), '{}') INTO v_ids
    FROM folha.esocial_event x
   WHERE x.account_id = v_ctx.account_id AND x.lot_id = p_lot_id
     AND x.estado = CASE WHEN p_tipo = 'processado' THEN 'em_processamento' ELSE 'enviado' END;
  PERFORM 1 FROM folha.esocial_event x WHERE x.account_id = v_ctx.account_id AND x.event_id = ANY (v_ids) ORDER BY x.event_id FOR UPDATE;

  IF p_retorno_xml IS NOT NULL THEN
    INSERT INTO folha.esocial_event_payload (account_id, lot_id, tipo, conteudo, conteudo_hash, criado_por_subject)
    VALUES (v_ctx.account_id, p_lot_id, 'retorno_lote', p_retorno_xml, repeat('0', 64), v_ctx.subject_id);
  END IF;

  IF p_tipo = 'processado' THEN
    FOR v_el IN SELECT value FROM jsonb_array_elements(p_eventos) LOOP
      v_id := (v_el->>'event_id')::uuid;
      v_res := v_el->>'resultado';
      IF v_id IS NULL OR NOT (v_id = ANY (v_ids)) OR v_id = ANY (v_vistos) THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = format('Evento %s não está em processamento neste lote (ou veio repetido)', v_id);
      END IF;
      v_vistos := v_vistos || v_id;
      IF v_res IS NULL OR v_res NOT IN ('validado', 'rejeitado', 'duplicado') THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = format('Resultado do evento %s deve ser validado, rejeitado ou duplicado', v_id);
      END IF;
      IF v_res = 'validado' AND btrim(COALESCE(v_el->>'recibo', '')) = '' THEN
        RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = format('O evento %s validado exige o número do recibo', v_id);
      END IF;
      PERFORM folha.esocial_ocorrencias_gravar(v_ctx.account_id, v_id, p_lot_id, 'evento', COALESCE(v_el->'ocorrencias', '[]'::jsonb));
      IF v_el->>'retorno_xml' IS NOT NULL THEN
        INSERT INTO folha.esocial_event_payload (account_id, event_id, lot_id, tipo, conteudo, conteudo_hash, criado_por_subject)
        VALUES (v_ctx.account_id, v_id, p_lot_id, 'retorno_evento', v_el->>'retorno_xml', repeat('0', 64), v_ctx.subject_id);
      END IF;
      SELECT * INTO v_ev FROM folha.esocial_event x WHERE x.account_id = v_ctx.account_id AND x.event_id = v_id;
      IF v_res = 'validado' THEN
        UPDATE folha.esocial_event x SET estado = 'validado', recibo_numero = btrim(v_el->>'recibo')
         WHERE x.account_id = v_ctx.account_id AND x.event_id = v_id;
        IF v_ev.ind_retif = 2 THEN
          UPDATE folha.esocial_event x SET estado = 'retificado'
           WHERE x.account_id = v_ctx.account_id AND x.event_id = v_ev.retifica_event_id;
        END IF;
        IF v_ev.evento_codigo = 'S-3000' THEN
          UPDATE folha.esocial_event x SET estado = 'excluido'
           WHERE x.account_id = v_ctx.account_id AND x.event_id = v_ev.exclui_event_id;
        END IF;
        v_validados := v_validados + 1;
      ELSE
        UPDATE folha.esocial_event x SET estado = v_res WHERE x.account_id = v_ctx.account_id AND x.event_id = v_id;
        IF v_res = 'rejeitado' THEN v_rejeitados := v_rejeitados + 1; ELSE v_duplicados := v_duplicados + 1; END IF;
      END IF;
    END LOOP;
    IF cardinality(v_vistos) <> cardinality(v_ids) THEN
      RAISE EXCEPTION USING ERRCODE = '22023',
        MESSAGE = format('O retorno precisa trazer o resultado de todos os %s eventos em processamento do lote (vieram %s)', cardinality(v_ids), cardinality(v_vistos));
    END IF;
    UPDATE folha.esocial_lot l SET situacao = 'processado' WHERE l.account_id = v_ctx.account_id AND l.lot_id = p_lot_id;
  ELSE
    UPDATE folha.esocial_lot l
       SET situacao = p_tipo, protocolo = CASE WHEN p_tipo = 'recebido' THEN btrim(p_protocolo) END, codigo_resposta = p_codigo_resposta
     WHERE l.account_id = v_ctx.account_id AND l.lot_id = p_lot_id;
    IF p_tipo = 'lote_incorreto' AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_ocorrencias) o WHERE o.value->>'gravidade' = 'erro') THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Lote incorreto exige ao menos uma ocorrência de erro';
    END IF;
    FOREACH v_id IN ARRAY v_ids LOOP
      PERFORM folha.esocial_ocorrencias_gravar(v_ctx.account_id, v_id, p_lot_id, 'lote', p_ocorrencias);
    END LOOP;
    UPDATE folha.esocial_event x
       SET estado = CASE p_tipo WHEN 'recebido' THEN 'em_processamento' WHEN 'lote_incorreto' THEN 'rejeitado' ELSE 'falha_comunicacao' END
     WHERE x.account_id = v_ctx.account_id AND x.event_id = ANY (v_ids);
  END IF;

  PERFORM folha.esocial_auditar(to_jsonb(v_ctx), 'esocial_lote_retorno', 'esocial_lot', p_lot_id,
                                jsonb_build_object('tipo', p_tipo, 'protocolo', p_protocolo, 'codigo_resposta', p_codigo_resposta,
                                                   'eventos', cardinality(v_ids), 'validados', v_validados,
                                                   'rejeitados', v_rejeitados, 'duplicados', v_duplicados));
  PERFORM 1 FROM folha.contexto_v1('folha.transmit');
  RETURN jsonb_build_object('lot_id', p_lot_id, 'situacao', p_tipo, 'eventos', cardinality(v_ids),
                            'validados', v_validados, 'rejeitados', v_rejeitados, 'duplicados', v_duplicados);
END
$function$;

-- 6.7 Retificar (folha.transmit + folha.close): nova versão do evento VALIDADO, com o recibo
--     dele; o original só passa a retificado quando a retificação for validada.
CREATE FUNCTION folha.esocial_evento_retificar_v1(
  p_event_id uuid, p_origem_hash text, p_motivo text, p_origens jsonb DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx record;
  v_t folha.esocial_event;
  v_ref jsonb;
  v_origens jsonb;
  v_r jsonb;
BEGIN
  SELECT c.account_id, c.legal_entity_id, c.branch_id, c.subject_id INTO v_ctx FROM folha.contexto_v1('folha.transmit') AS c;
  PERFORM 1 FROM folha.contexto_v1('folha.close');
  IF btrim(COALESCE(p_motivo, '')) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'esocial_evento_retificar_v1: motivo obrigatório (aprovação registrada)';
  END IF;
  IF p_origem_hash IS NULL OR p_origem_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'O hash de origem deve ser um SHA-256 em hexadecimal minúsculo (64 caracteres)';
  END IF;
  SELECT * INTO v_t FROM folha.esocial_event x WHERE x.account_id = v_ctx.account_id AND x.event_id = p_event_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = format('Evento %s não encontrado', p_event_id);
  END IF;
  IF v_t.estado <> 'validado' OR v_t.recibo_numero IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = format('A retificação exige o evento validado com recibo (estado atual: %s)', v_t.estado);
  END IF;
  IF v_t.evento_codigo = 'S-3000' THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'O S-3000 não tem retificação';
  END IF;
  IF v_t.origem_hash = p_origem_hash THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'O conteúdo de origem é idêntico ao do evento validado: nada a retificar';
  END IF;
  v_ref := jsonb_strip_nulls(jsonb_build_object(
    'establishment_id', v_t.establishment_id, 'employee_id', v_t.employee_id, 'contract_id', v_t.contract_id,
    'ind_apuracao', v_t.ind_apuracao, 'periodo_apuracao', v_t.periodo_apuracao, 'data_efeito', v_t.data_efeito,
    'inicio_validade', v_t.inicio_validade, 'codigo_tabela', v_t.codigo_tabela));
  v_origens := COALESCE(p_origens,
    (SELECT jsonb_agg(jsonb_build_object('run_id', o.run_id, 'result_id', o.result_id) ORDER BY o.run_id, o.result_id)
       FROM folha.esocial_event_origin o WHERE o.account_id = v_ctx.account_id AND o.event_id = v_t.event_id),
    '[]'::jsonb);
  v_r := folha.esocial_evento_incluir(v_ctx.account_id, v_t.employer_id, v_t.evento_codigo, v_t.ambiente, v_ref,
                                      p_origem_hash, v_origens, v_t.event_id, NULL, btrim(p_motivo));
  PERFORM folha.esocial_auditar(to_jsonb(v_ctx), 'esocial_retificar', 'esocial_event', (v_r->>'event_id')::uuid,
                                jsonb_build_object('retifica_event_id', v_t.event_id, 'recibo_original', v_t.recibo_numero, 'motivo', btrim(p_motivo)));
  PERFORM 1 FROM folha.contexto_v1('folha.transmit');
  PERFORM 1 FROM folha.contexto_v1('folha.close');
  RETURN v_r;
END
$function$;

-- 6.8 Excluir (S-3000; folha.transmit + folha.close): cria o evento de exclusão do evento
--     validado (com o recibo dele). Recusa se houver dependentes enviados ou o período estiver
--     fechado; o evento original só passa a excluído quando o S-3000 for validado.
CREATE FUNCTION folha.esocial_evento_excluir_v1(p_event_id uuid, p_motivo text) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx record;
  v_t folha.esocial_event;
  v_r jsonb;
BEGIN
  SELECT c.account_id, c.legal_entity_id, c.branch_id, c.subject_id INTO v_ctx FROM folha.contexto_v1('folha.transmit') AS c;
  PERFORM 1 FROM folha.contexto_v1('folha.close');
  IF btrim(COALESCE(p_motivo, '')) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'esocial_evento_excluir_v1: motivo obrigatório (aprovação registrada)';
  END IF;
  SELECT * INTO v_t FROM folha.esocial_event x WHERE x.account_id = v_ctx.account_id AND x.event_id = p_event_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = format('Evento %s não encontrado', p_event_id);
  END IF;
  IF v_t.estado <> 'validado' OR v_t.recibo_numero IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = format('A exclusão exige o evento validado com recibo (estado atual: %s)', v_t.estado);
  END IF;
  v_r := folha.esocial_evento_incluir(
    v_ctx.account_id, v_t.employer_id, 'S-3000', v_t.ambiente, '{}'::jsonb,
    encode(sha256(convert_to('S-3000|' || v_t.event_id::text || '|' || v_t.recibo_numero, 'UTF8')), 'hex'),
    '[]'::jsonb, NULL, v_t.event_id, btrim(p_motivo));
  PERFORM folha.esocial_auditar(to_jsonb(v_ctx), 'esocial_excluir', 'esocial_event', (v_r->>'event_id')::uuid,
                                jsonb_build_object('exclui_event_id', v_t.event_id, 'evento_excluido', v_t.evento_codigo,
                                                   'recibo_original', v_t.recibo_numero, 'motivo', btrim(p_motivo)));
  PERFORM 1 FROM folha.contexto_v1('folha.transmit');
  PERFORM 1 FROM folha.contexto_v1('folha.close');
  RETURN v_r;
END
$function$;

-- 6.9 Plano de DESFAZER (folha.read). Só leitura: devolve em JSON a cadeia ordenada.
--     Escopo: (p_periodo, p_ind_apuracao) = todos os eventos periódicos do período; ou p_event_id =
--     o evento e tudo o que depende dele. Ordem: reabertura do período fechado (S-1298) primeiro;
--     depois, dependentes antes dos antecessores (S-1210 antes do S-1200, S-1200 antes do S-2200).
--     Evento ainda não enviado vira "cancelar"; em transmissão vira "aguardar_retorno" (decisão
--     humana); validado vira "excluir" (S-3000). O plano não executa nada.
CREATE FUNCTION folha.esocial_desfazer_plano_v1(
  p_employer_id uuid, p_ambiente text, p_periodo date DEFAULT NULL, p_ind_apuracao smallint DEFAULT 1, p_event_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx record;
  v_alvo folha.esocial_event;
  v_periodo date := p_periodo;
  v_ind smallint := COALESCE(p_ind_apuracao, 1);
  v_ativos text[] := ARRAY['rascunho', 'pendente_interno', 'gerado', 'assinado', 'enviado', 'em_processamento', 'falha_comunicacao', 'validado'];
  v_nos uuid[] := '{}';
  v_front uuid[];
  v_novos uuid[];
  v_rest uuid[];
  v_cand uuid[];
  v_ord uuid[] := '{}';
  v_per record;
  v_reabrir jsonb := '[]'::jsonb;
  v_nreab integer := 0;
  v_passos jsonb;
  v_avisos jsonb := '[]'::jsonb;
  v_modo text;
  v_ciclo integer;
BEGIN
  SELECT c.account_id, c.legal_entity_id, c.branch_id, c.subject_id INTO v_ctx FROM folha.contexto_v1('folha.read') AS c;
  IF p_ambiente IS NULL OR p_ambiente NOT IN ('producao', 'producao_restrita') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Ambiente deve ser producao ou producao_restrita';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM folha.employer e WHERE e.account_id = v_ctx.account_id AND e.employer_id = p_employer_id) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = format('Empregador %s não encontrado nesta conta', p_employer_id);
  END IF;
  IF (p_periodo IS NULL) = (p_event_id IS NULL) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Informe o período OU o evento (um dos dois)';
  END IF;

  IF p_event_id IS NOT NULL THEN
    SELECT * INTO v_alvo FROM folha.esocial_event x
     WHERE x.account_id = v_ctx.account_id AND x.employer_id = p_employer_id AND x.ambiente = p_ambiente AND x.event_id = p_event_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = format('Evento %s não encontrado neste empregador e ambiente', p_event_id);
    END IF;
    IF v_alvo.evento_codigo = 'S-1298' THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'A reabertura (S-1298) não se desfaz por este plano';
    END IF;
    IF v_alvo.evento_codigo = 'S-1299' THEN
      -- desfazer o fechamento = reabrir o período: o plano é o do período
      v_periodo := v_alvo.periodo_apuracao;
      v_ind := COALESCE(v_alvo.ind_apuracao, 1);
      v_modo := 'periodo';
    ELSIF NOT (v_alvo.estado = ANY (v_ativos)) THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = format('O evento está %s: não há o que desfazer', v_alvo.estado);
    ELSE
      v_modo := 'evento';
      v_nos := ARRAY[v_alvo.event_id];
      v_front := ARRAY[v_alvo.event_id];
      WHILE cardinality(v_front) > 0 LOOP
        SELECT COALESCE(array_agg(DISTINCT d.event_id), '{}') INTO v_novos
          FROM unnest(v_front) AS f(id), LATERAL folha.esocial_dependentes(f.id, false) AS d
         WHERE NOT (d.event_id = ANY (v_nos)) AND d.evento_codigo NOT IN ('S-1298', 'S-1299');
        v_nos := v_nos || v_novos;
        v_front := v_novos;
      END LOOP;
    END IF;
  ELSE
    v_modo := 'periodo';
  END IF;

  IF v_modo = 'periodo' THEN
    SELECT COALESCE(array_agg(e.event_id), '{}') INTO v_nos
      FROM folha.esocial_event e JOIN folha.esocial_event_catalog k ON k.evento_codigo = e.evento_codigo
     WHERE e.account_id = v_ctx.account_id AND e.employer_id = p_employer_id AND e.ambiente = p_ambiente
       AND k.grupo = 'periodicos' AND e.evento_codigo NOT IN ('S-1298', 'S-1299')
       AND e.periodo_apuracao = v_periodo AND COALESCE(e.ind_apuracao, 1) = v_ind AND e.estado = ANY (v_ativos);
    v_avisos := v_avisos || to_jsonb('O plano por período cobre os eventos periódicos do período; o S-2299 (não periódico) entra pelo plano do evento'::text);
  END IF;

  -- períodos fechados a reabrir: um passo por período (S-1298), antes de qualquer exclusão
  FOR v_per IN
    SELECT DISTINCT e.periodo_apuracao AS periodo, COALESCE(e.ind_apuracao, 1)::smallint AS ind
      FROM folha.esocial_event e JOIN folha.esocial_event_catalog k ON k.evento_codigo = e.evento_codigo
     WHERE e.account_id = v_ctx.account_id AND e.event_id = ANY (v_nos)
       AND k.grupo = 'periodicos' AND e.estado = 'validado'
    UNION
    SELECT v_periodo, v_ind WHERE v_modo = 'periodo'
    ORDER BY 1, 2
  LOOP
    IF folha.esocial_periodo_fechado(v_ctx.account_id, p_employer_id, p_ambiente, v_per.ind, v_per.periodo) THEN
      v_nreab := v_nreab + 1;
      SELECT count(DISTINCT x.ciclo) + 1 INTO v_ciclo FROM folha.esocial_event x
       WHERE x.account_id = v_ctx.account_id AND x.employer_id = p_employer_id AND x.ambiente = p_ambiente
         AND x.evento_codigo = 'S-1298' AND x.ind_apuracao = v_per.ind AND x.periodo_apuracao = v_per.periodo
         AND x.estado IN ('validado', 'retificado');
      v_reabrir := v_reabrir || jsonb_build_array(jsonb_build_object(
        'ordem', v_nreab, 'acao', 'reabrir_periodo', 'evento_codigo', 'S-1298', 'evento_a_enviar', 'S-1298',
        'event_id', NULL, 'estado', NULL,
        'referencia', jsonb_build_object('periodo_apuracao', v_per.periodo, 'ind_apuracao', v_per.ind, 'ciclo', v_ciclo),
        'depois_de_ordens', '[]'::jsonb,
        'exige_decisao_humana', true,
        'motivos_decisao', jsonb_build_array('reabertura_muda_dctfweb_e_fgts_digital'),
        'exige_aprovacao_registrada', true,
        'permissoes', jsonb_build_array('folha.transmit', 'folha.close'),
        'efeitos_externos', jsonb_build_array('DCTFWeb', 'FGTS Digital')));
    END IF;
  END LOOP;

  -- ordem de desfazer: em cada rodada, os que ninguém mais (do conjunto) usa como antecessor
  v_rest := v_nos;
  WHILE cardinality(v_rest) > 0 LOOP
    SELECT array_agg(x.event_id ORDER BY (x.estado = 'validado'), x.evento_codigo, x.employee_id NULLS FIRST, x.event_id) INTO v_cand
      FROM folha.esocial_event x
     WHERE x.event_id = ANY (v_rest)
       AND NOT EXISTS (SELECT 1 FROM folha.esocial_event y
                        WHERE y.event_id = ANY (v_rest) AND y.event_id <> x.event_id AND folha.esocial_depende(y, x));
    IF v_cand IS NULL THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Dependência circular entre os eventos do plano (não deveria ocorrer)';
    END IF;
    v_ord := v_ord || v_cand;
    SELECT COALESCE(array_agg(r), '{}') INTO v_rest FROM unnest(v_rest) AS r WHERE NOT (r = ANY (v_cand));
  END LOOP;

  SELECT COALESCE(jsonb_agg(s.passo ORDER BY s.ordem), '[]'::jsonb) INTO v_passos
    FROM (
      SELECT (v_nreab + t.ord)::integer AS ordem,
             jsonb_build_object(
               'ordem', (v_nreab + t.ord)::integer,
               'acao', CASE WHEN x.estado = 'validado' THEN 'excluir'
                            WHEN x.estado IN ('enviado', 'em_processamento', 'falha_comunicacao') THEN 'aguardar_retorno'
                            ELSE 'cancelar' END,
               'evento_codigo', x.evento_codigo,
               'evento_a_enviar', CASE WHEN x.estado = 'validado' THEN 'S-3000' END,
               'event_id', x.event_id,
               'estado', x.estado,
               'recibo_numero', x.recibo_numero,
               'referencia', jsonb_strip_nulls(jsonb_build_object(
                 'periodo_apuracao', x.periodo_apuracao, 'ind_apuracao', x.ind_apuracao, 'employee_id', x.employee_id,
                 'contract_id', x.contract_id, 'data_efeito', x.data_efeito, 'codigo_tabela', x.codigo_tabela)),
               'depois_de_ordens', (SELECT COALESCE(jsonb_agg((v_nreab + u.ord)::integer ORDER BY u.ord), '[]'::jsonb)
                                      FROM unnest(v_ord) WITH ORDINALITY AS u(id2, ord)
                                      JOIN folha.esocial_event y ON y.event_id = u.id2
                                     WHERE y.event_id <> x.event_id AND folha.esocial_depende(y, x)),
               'exige_decisao_humana', (x.estado IN ('enviado', 'em_processamento', 'falha_comunicacao'))
                                       OR (x.estado = 'validado' AND k.grupo IN ('tabelas', 'nao_periodicos', 'sst')),
               'motivos_decisao', CASE WHEN x.estado IN ('enviado', 'em_processamento', 'falha_comunicacao')
                                       THEN jsonb_build_array('evento_em_transmissao_esperar_retorno')
                                       WHEN x.estado = 'validado' AND k.grupo IN ('tabelas', 'nao_periodicos', 'sst')
                                       THEN jsonb_build_array('exclusao_de_cadastro_ou_vinculo_afeta_o_historico_e_os_dependentes')
                                       ELSE '[]'::jsonb END,
               'exige_aprovacao_registrada', (x.estado = 'validado'),
               'permissoes', CASE WHEN x.estado = 'validado' THEN jsonb_build_array('folha.transmit', 'folha.close')
                                  ELSE jsonb_build_array('folha.transmit') END,
               'efeitos_externos', '[]'::jsonb) AS passo
        FROM unnest(v_ord) WITH ORDINALITY AS t(id, ord)
        JOIN folha.esocial_event x ON x.event_id = t.id
        JOIN folha.esocial_event_catalog k ON k.evento_codigo = x.evento_codigo
    ) s;

  v_avisos := v_avisos || to_jsonb('Em vez de excluir, o evento validado também pode ser retificado (parecer 4.6): a escolha é humana'::text);
  IF v_nreab > 0 THEN
    v_avisos := v_avisos || to_jsonb('A reabertura muda a DCTFWeb e o FGTS Digital: abrir a tarefa de conferência e retificação das duas pontas (parecer 4.6)'::text);
  END IF;

  PERFORM 1 FROM folha.contexto_v1('folha.read');
  RETURN jsonb_build_object(
    'somente_leitura', true,
    'employer_id', p_employer_id,
    'ambiente', p_ambiente,
    'escopo', jsonb_strip_nulls(jsonb_build_object('tipo', v_modo, 'periodo_apuracao', v_periodo, 'ind_apuracao', v_ind,
                                                   'event_id', p_event_id)),
    'total_passos', v_nreab + cardinality(v_ord),
    'passos', v_reabrir || v_passos,
    'avisos', v_avisos,
    'proximos_passos', jsonb_build_array(
      'recalcular e fechar de novo a folha de origem, se foi ela que mudou',
      'gerar e enviar os eventos corrigidos (retificação ou evento novo)',
      'novo fechamento (S-1299) depois de todos os periódicos validados',
      'conferir a DCTFWeb (retificadora) e o FGTS Digital'));
END
$function$;

-- 6.10 Conferência por empregador e período (folha.read): resumo por período, problemas e se o
--      período pode ser fechado (nenhum periódico pendente, em transmissão, rejeitado ou bloqueado).
CREATE FUNCTION folha.esocial_conferencia_v1(p_employer_id uuid, p_periodo date DEFAULT NULL, p_ambiente text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx record;
  v_resumo jsonb;
  v_problemas jsonb;
  v_pode boolean;
BEGIN
  SELECT c.account_id, c.legal_entity_id, c.branch_id, c.subject_id INTO v_ctx FROM folha.contexto_v1('folha.read') AS c;
  IF p_ambiente IS NOT NULL AND p_ambiente NOT IN ('producao', 'producao_restrita') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Ambiente deve ser producao ou producao_restrita';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM folha.employer e WHERE e.account_id = v_ctx.account_id AND e.employer_id = p_employer_id) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = format('Empregador %s não encontrado nesta conta', p_employer_id);
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(v) - 'account_id' ORDER BY v.ambiente, v.periodo_apuracao NULLS FIRST), '[]'::jsonb) INTO v_resumo
    FROM folha.v_esocial_conferencia v
   WHERE v.account_id = v_ctx.account_id AND v.employer_id = p_employer_id
     AND (p_periodo IS NULL OR v.periodo_apuracao = p_periodo) AND (p_ambiente IS NULL OR v.ambiente = p_ambiente);

  WITH ult AS (
    SELECT e.*, k.grupo,
           (e.versao = max(e.versao) OVER (PARTITION BY e.account_id, e.employer_id, e.ambiente, e.evento_codigo, e.chave_negocio)) AS ultima
      FROM folha.esocial_event e JOIN folha.esocial_event_catalog k ON k.evento_codigo = e.evento_codigo
     WHERE e.account_id = v_ctx.account_id AND e.employer_id = p_employer_id
       AND (p_periodo IS NULL OR e.periodo_apuracao = p_periodo) AND (p_ambiente IS NULL OR e.ambiente = p_ambiente)
  ), prob AS (
    SELECT u.event_id, u.evento_codigo, u.grupo, u.ambiente, u.periodo_apuracao, u.estado, u.versao,
           CASE WHEN u.estado IN ('rejeitado', 'duplicado') THEN 'rejeitado'
                WHEN u.estado IN ('enviado', 'em_processamento', 'falha_comunicacao') THEN 'em_transmissao'
                WHEN u.estado IN ('rascunho', 'pendente_interno') AND folha.esocial_bloqueio_antecessor(u.event_id) THEN 'bloqueado_antecessor'
                ELSE 'pendente' END AS tipo
      FROM ult u
     WHERE u.ultima AND u.estado IN ('rascunho', 'pendente_interno', 'gerado', 'assinado', 'enviado', 'em_processamento', 'falha_comunicacao', 'rejeitado', 'duplicado')
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'event_id', p.event_id, 'evento_codigo', p.evento_codigo, 'ambiente', p.ambiente, 'periodo_apuracao', p.periodo_apuracao,
           'estado', p.estado, 'versao', p.versao, 'tipo', p.tipo,
           'antecessores_faltando', (SELECT COALESCE(jsonb_agg(jsonb_build_object('antecessor', f.o_antecessor, 'motivo', f.o_motivo, 'status_validacao', f.o_status) ORDER BY f.o_antecessor), '[]'::jsonb)
                                      FROM folha.esocial_antecessores_faltando(p.event_id) AS f),
           'ocorrencias', (SELECT COALESCE(jsonb_agg(jsonb_build_object('codigo', o.codigo, 'gravidade', o.gravidade, 'origem', o.origem, 'descricao', o.descricao) ORDER BY o.occurrence_id), '[]'::jsonb)
                             FROM folha.esocial_event_occurrence o
                            WHERE o.event_id = p.event_id AND o.account_id = v_ctx.account_id)
         ) ORDER BY p.periodo_apuracao NULLS FIRST, p.evento_codigo, p.event_id), '[]'::jsonb),
         NOT EXISTS (SELECT 1 FROM prob q WHERE q.grupo = 'periodicos' AND q.evento_codigo NOT IN ('S-1298', 'S-1299'))
    INTO v_problemas, v_pode
    FROM prob p;

  PERFORM 1 FROM folha.contexto_v1('folha.read');
  RETURN jsonb_build_object('employer_id', p_employer_id, 'periodo_apuracao', p_periodo, 'resumo', v_resumo, 'problemas', v_problemas,
                            'pode_fechar_periodicos', CASE WHEN p_periodo IS NULL THEN NULL ELSE v_pode END);
END
$function$;

-- ===========================================================================
-- 7. Visão de conferência por empregador e período (painel de fechamento)
--    security_invoker: quem lê passa pela RLS das tabelas; a conta ainda é conferida na função
--    de bloqueio. Só as últimas versões de cada cadeia contam como pendência.
-- ===========================================================================
CREATE VIEW folha.v_esocial_conferencia
WITH (security_invoker = true) AS
WITH ev AS (
  SELECT e.account_id, e.employer_id, e.ambiente, e.periodo_apuracao, e.event_id, e.estado, e.com_advertencia,
         (e.versao = max(e.versao) OVER (PARTITION BY e.account_id, e.employer_id, e.ambiente, e.evento_codigo, e.chave_negocio)) AS ultima
    FROM folha.esocial_event e
)
SELECT
  ev.account_id,
  ev.employer_id,
  ev.ambiente,
  ev.periodo_apuracao,
  count(*) FILTER (WHERE ev.ultima AND ev.estado NOT IN ('cancelado', 'excluido', 'retificado'))::bigint AS eventos,
  count(*) FILTER (WHERE ev.ultima AND ev.estado IN ('rascunho', 'pendente_interno', 'gerado', 'assinado'))::bigint AS pendentes,
  count(*) FILTER (WHERE ev.ultima AND ev.estado IN ('enviado', 'em_processamento', 'falha_comunicacao'))::bigint AS em_transmissao,
  count(*) FILTER (WHERE ev.ultima AND ev.estado IN ('rejeitado', 'duplicado'))::bigint AS rejeitados,
  count(*) FILTER (WHERE ev.estado = 'validado')::bigint AS validados,
  count(*) FILTER (WHERE ev.estado = 'validado' AND ev.com_advertencia)::bigint AS com_advertencia,
  count(*) FILTER (WHERE ev.ultima AND ev.estado IN ('rascunho', 'pendente_interno')
                     AND folha.esocial_bloqueio_antecessor(ev.event_id))::bigint AS bloqueados_antecessor
  FROM ev
 GROUP BY ev.account_id, ev.employer_id, ev.ambiente, ev.periodo_apuracao;
COMMENT ON VIEW folha.v_esocial_conferencia IS
  'Por empregador, ambiente e período: pendentes, em transmissão, rejeitados e bloqueados por antecessor não validado (alimenta o painel de fechamento).';

-- ===========================================================================
-- 8. RLS e ACL
--    Tabelas por conta: policy só de leitura, para worker e data_owner (a gravação é pelas funções
--    e gatilhos, no padrão da 0029 e da 0030). Catálogos: leitura para os dois papéis.
--    Funções: tira o EXECUTE de todo papel que não seja o dono e concede só o pretendido.
-- ===========================================================================
DO $$
DECLARE
  v_item text[];
  v_tabela text;
  v_papel text;
BEGIN
  FOREACH v_item SLICE 1 IN ARRAY ARRAY[
    ['esocial_employer_setting', 'conta'],
    ['esocial_lot',              'conta'],
    ['esocial_event',            'conta'],
    ['esocial_event_origin',     'conta'],
    ['esocial_lot_event',        'conta'],
    ['esocial_event_payload',    'conta'],
    ['esocial_event_occurrence', 'conta'],
    ['esocial_event_catalog',    'catalogo'],
    ['esocial_event_antecessor', 'catalogo'],
    ['esocial_event_state',      'catalogo'],
    ['esocial_event_transition', 'catalogo'],
    ['esocial_rejection_catalog', 'catalogo']
  ]
  LOOP
    v_tabela := v_item[1];
    EXECUTE format('ALTER TABLE folha.%I ENABLE ROW LEVEL SECURITY', v_tabela);
    EXECUTE format('ALTER TABLE folha.%I FORCE ROW LEVEL SECURITY', v_tabela);
    FOR v_papel IN
      SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(r.rolname) END
        FROM pg_catalog.pg_class c
        CROSS JOIN LATERAL aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) a
        LEFT JOIN pg_catalog.pg_roles r ON r.oid = a.grantee
       WHERE c.oid = format('folha.%I', v_tabela)::regclass AND a.grantee <> c.relowner
       GROUP BY 1
    LOOP
      EXECUTE format('REVOKE ALL ON folha.%I FROM %s', v_tabela, v_papel);
    END LOOP;
    EXECUTE format('REVOKE ALL ON folha.%I FROM PUBLIC, anon, authenticated, service_role', v_tabela);
    IF v_item[2] = 'conta' THEN
      EXECUTE format(
        'CREATE POLICY %I ON folha.%I FOR SELECT TO dnex_gestao_folha_worker, dnex_gestao_data_owner
           USING (account_id = (SELECT folha.current_account_id()))',
        v_tabela || '_isolamento', v_tabela);
    ELSE
      EXECUTE format(
        'CREATE POLICY %I ON folha.%I FOR SELECT TO dnex_gestao_folha_worker, dnex_gestao_data_owner USING (true)',
        v_tabela || '_leitura', v_tabela);
    END IF;
    EXECUTE format('GRANT SELECT ON folha.%I TO dnex_gestao_folha_worker, dnex_gestao_data_owner', v_tabela);
  END LOOP;

  REVOKE ALL ON folha.v_esocial_conferencia FROM PUBLIC, anon, authenticated, service_role;
  GRANT SELECT ON folha.v_esocial_conferencia TO dnex_gestao_folha_worker, dnex_gestao_data_owner;

  FOREACH v_item SLICE 1 IN ARRAY ARRAY[
    ['folha.esocial_auditar(jsonb, text, text, uuid, jsonb)',                                      ''],
    ['folha.esocial_chave_texto(text, text, date, uuid, uuid, date, smallint, date, integer, uuid)', ''],
    ['folha.esocial_escopo_casa(text, folha.esocial_event, folha.esocial_event)',                  ''],
    ['folha.esocial_periodo_fechado(uuid, uuid, text, smallint, date)',                            ''],
    ['folha.esocial_ref_chave(folha.esocial_event)',                                               ''],
    ['folha.esocial_antecessores_faltando(uuid, uuid)',                                            ''],
    ['folha.esocial_depende(folha.esocial_event, folha.esocial_event)',                            ''],
    ['folha.esocial_dependentes(uuid, boolean)',                                                   ''],
    ['folha.esocial_origem_conferir(folha.esocial_event)',                                         ''],
    ['folha.esocial_ocorrencias_gravar(uuid, uuid, uuid, text, jsonb)',                            ''],
    ['folha.esocial_evento_incluir(uuid, uuid, text, text, jsonb, text, jsonb, uuid, uuid, text)', ''],
    ['folha.esocial_imutavel()',                                                                   ''],
    ['folha.esocial_sem_truncate()',                                                               ''],
    ['folha.esocial_setting_guarda()',                                                             ''],
    ['folha.esocial_event_guarda()',                                                               ''],
    ['folha.esocial_lot_guarda()',                                                                 ''],
    ['folha.esocial_lot_event_guarda()',                                                           ''],
    ['folha.esocial_payload_guarda()',                                                             ''],
    ['folha.esocial_occurrence_guarda()',                                                          ''],
    ['folha.esocial_origin_guarda()',                                                              ''],
    ['folha.esocial_bloqueio_antecessor(uuid)',                                                    'dnex_gestao_folha_worker, dnex_gestao_data_owner'],
    ['folha.esocial_producao_definir_v1(uuid, boolean, text)',                                     'dnex_gestao_api'],
    ['folha.esocial_evento_enfileirar_v1(uuid, text, text, text, jsonb, jsonb)',                   'dnex_gestao_api'],
    ['folha.esocial_evento_avancar_v1(uuid, text, text)',                                          'dnex_gestao_api'],
    ['folha.esocial_evento_cancelar_v1(uuid, text)',                                               'dnex_gestao_api'],
    ['folha.esocial_lote_enviar_v1(uuid, text, uuid[])',                                           'dnex_gestao_api'],
    ['folha.esocial_lote_retorno_v1(uuid, text, text, text, text, jsonb, jsonb)',                  'dnex_gestao_api'],
    ['folha.esocial_evento_retificar_v1(uuid, text, text, jsonb)',                                 'dnex_gestao_api'],
    ['folha.esocial_evento_excluir_v1(uuid, text)',                                                'dnex_gestao_api'],
    ['folha.esocial_desfazer_plano_v1(uuid, text, date, smallint, uuid)',                          'dnex_gestao_api'],
    ['folha.esocial_conferencia_v1(uuid, date, text)',                                             'dnex_gestao_api']
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
END
$$;

-- ---------------------------------------------------------------------------
-- 9. Pós-voo (falha fechada)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_inesperado text;
BEGIN
  -- O que a sessão de aplicação executa de fila do eSocial é exatamente a lista desta migration.
  SELECT string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text) INTO v_inesperado
    FROM pg_catalog.pg_proc p
   WHERE p.pronamespace = 'folha'::regnamespace
     AND p.proname LIKE 'esocial\_%'
     AND has_function_privilege('dnex_gestao_api', p.oid, 'EXECUTE')
     AND p.oid::regprocedure::text NOT IN (
       'folha.esocial_producao_definir_v1(uuid,boolean,text)',
       'folha.esocial_evento_enfileirar_v1(uuid,text,text,text,jsonb,jsonb)',
       'folha.esocial_evento_avancar_v1(uuid,text,text)',
       'folha.esocial_evento_cancelar_v1(uuid,text)',
       'folha.esocial_lote_enviar_v1(uuid,text,uuid[])',
       'folha.esocial_lote_retorno_v1(uuid,text,text,text,text,jsonb,jsonb)',
       'folha.esocial_evento_retificar_v1(uuid,text,text,jsonb)',
       'folha.esocial_evento_excluir_v1(uuid,text)',
       'folha.esocial_desfazer_plano_v1(uuid,text,date,smallint,uuid)',
       'folha.esocial_conferencia_v1(uuid,date,text)');
  IF v_inesperado IS NOT NULL THEN
    RAISE EXCEPTION '0031: dnex_gestao_api executa funções da fila fora da lista: %', v_inesperado
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO v_inesperado
    FROM pg_catalog.pg_class c
   WHERE c.relnamespace = 'folha'::regnamespace AND c.relkind IN ('r', 'p', 'v', 'm')
     AND (has_table_privilege('dnex_gestao_api', c.oid, 'SELECT')
          OR has_table_privilege('dnex_gestao_api', c.oid, 'INSERT, UPDATE, DELETE, TRUNCATE'));
  IF v_inesperado IS NOT NULL THEN
    RAISE EXCEPTION '0031: dnex_gestao_api tem privilégio direto em: %', v_inesperado
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text) INTO v_inesperado
    FROM pg_catalog.pg_proc p
   WHERE p.pronamespace = 'folha'::regnamespace AND p.prosecdef
     AND NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) AS cfg
                      WHERE cfg ~ '^search_path=pg_catalog(,|$)' AND cfg ~ ',\s*pg_temp$' AND cfg !~ 'pg_temp.*pg_temp');
  IF v_inesperado IS NOT NULL THEN
    RAISE EXCEPTION '0031: função SECURITY DEFINER cujo search_path não começa por pg_catalog e termina em pg_temp: %', v_inesperado
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text) INTO v_inesperado
    FROM pg_catalog.pg_proc p
    CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
   WHERE p.pronamespace = 'folha'::regnamespace AND a.grantee = 0;
  IF v_inesperado IS NOT NULL THEN
    RAISE EXCEPTION '0031: função do schema folha executável por PUBLIC: %', v_inesperado
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF has_table_privilege('dnex_gestao_folha_worker', 'folha.esocial_event', 'INSERT, UPDATE, DELETE')
     OR has_table_privilege('dnex_gestao_folha_worker', 'folha.esocial_event_payload', 'INSERT, UPDATE, DELETE')
     OR has_table_privilege('dnex_gestao_folha_worker', 'folha.esocial_lot', 'INSERT, UPDATE, DELETE') THEN
    RAISE EXCEPTION '0031: o worker ficou com gravação direta em tabela da fila do eSocial'
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF (SELECT count(*) FROM pg_catalog.pg_class c
       WHERE c.relnamespace = 'folha'::regnamespace AND c.relname LIKE 'esocial\_%' AND c.relkind = 'r'
         AND NOT (c.relrowsecurity AND c.relforcerowsecurity)) > 0 THEN
    RAISE EXCEPTION '0031: tabela da fila do eSocial sem RLS com FORCE' USING ERRCODE = 'insufficient_privilege';
  END IF;
END
$$;

COMMIT;
