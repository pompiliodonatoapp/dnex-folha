-- DNEX Folha — Migration 0030: contabilização da folha com partida fechada e provisões de
-- férias e 13º (fatia 5).
--
-- Fonte: parecer técnico contábil de 15/11/2026 (14 erros em folha.build_contabil_folha e no
-- outbox, roteiro de lançamentos por natureza de conta, 15 regras de validação, casos GC-01 a
-- GC-08). Decisões e alternativas: docs/02-decisoes/ADR-contabilizacao-partida-fechada.md.
-- A especificação funcional observada em sistema de mercado serviu só de referência de
-- requisito (razão de provisão por trabalhador; separador contábil): nomes e desenho próprios.
--
-- O que esta migration faz:
--   1. Mapeamento rubrica -> natureza -> conta, configurável por empregador (e, opcionalmente,
--      por estabelecimento, lotação, centro de custo e regime de trabalho), com vigência:
--      folha.contabil_papel e folha.contabil_chave (catálogos de estrutura, sem conta),
--      folha.contabil_config, folha.contabil_mapa e folha.contract_cost_assignment.
--      Nenhuma conta contábil no código e nenhum mapeamento semeado. Sem mapeamento vigente
--      para uma rubrica usada o lote não sai: fica uma pendência de bloqueio (não liberável)
--      em folha.contabil_pendencia dizendo o que falta.
--   2. Lote contábil por folha, a partir dos ITENS por rubrica (0026/0027) e dos encargos por
--      lotação da memória de cálculo; valores em centavos inteiros; linhas agrupadas por
--      conta e dimensão; totais = soma das linhas.
--   3. Partida fechada no dado: folha.accounting_outbox ganha totais em centavos, CHECK de
--      balanceamento e gatilho que recalcula os totais a partir das linhas do evento.
--   4. Provisões de férias e 13º como razão por trabalhador (folha.provision_ledger), com tipos
--      de movimento em tabela: constituição mensal pelo método "saldo devido menos saldo
--      provisionado", baixa no pagamento (limitada ao saldo) e estorno do saldo na rescisão.
--   5. Eventos de pagamento (líquido, guias, repasses) separados da apropriação, com data
--      própria e comprovante.
--   6. Um lote vigente por folha, empregador e evento; conteúdo igual não cria nada; conteúdo diferente
--      cancela o lote ainda não despachado ou gera ESTORNO do já despachado, e depois a nova
--      versão. Nada é atualizado nem descartado em silêncio.
--   7. Só folha FECHADA e sem pendência aberta é contabilizada, pela conta do contexto, com
--      folha.transmit e o subject gravado.
--   8. Evento no contrato gestao.folha-handoff.v2 (contracts/modules).
--   9. folha.v_reconciliacao_contabil refeita: agregados separados (sem multiplicação pelo
--      join) e comparação por VALOR entre a folha e o lote vigente.
--  10. Funções da sessão de aplicação folha.contabil_*_v1 (EXECUTE só para dnex_gestao_api),
--      no padrão da 0028.
--
-- Permissão exigida por operação:
--   folha.admin      contabil_config_definir_v1, contabil_mapa_definir_v1,
--                    contabil_mapa_encerrar_v1, contabil_contrato_dimensao_definir_v1
--   folha.calculate  contabil_provisao_direito_informar_v1
--   folha.transmit   contabil_folha_contabilizar_v1, contabil_provisao_constituir_v1,
--                    contabil_pagamento_registrar_v1 (e build_contabil_folha, dispatch_*)
--   folha.close      contabil_pendencia_liberar_v1
--   folha.read       contabil_situacao_v1
-- A constituição de provisão com encargos também precisa de folha.read no contexto: os
-- encargos vêm de folha.calc_encargos_patronais, que lê a conta por folha.current_account_id().
--
-- NÃO altera as migrations 0014 a 0029. NÃO APLICAR EM PRODUÇÃO sem as dependências das
-- migrations 0024 a 0029 e sem decidir os pontos em aberto da ADR.
-- Reversão: 0030_folha_contabilizacao.supabase.down.sql.
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
      ('folha.contexto_v1(text) (migration 0028)', to_regprocedure('folha.contexto_v1(text)') IS NULL),
      ('folha.payroll_result_item (migration 0026)', to_regclass('folha.payroll_result_item') IS NULL),
      ('folha.calc_encargos_patronais(uuid, date, numeric, numeric) (migration 0025)',
         to_regprocedure('folha.calc_encargos_patronais(uuid, date, numeric, numeric)') IS NULL),
      ('folha.published_document (migration 0029)', to_regclass('folha.published_document') IS NULL)
    ) AS x(nome, ausente)
   WHERE x.ausente;
  IF v_faltando IS NOT NULL THEN
    RAISE EXCEPTION '0030: faltam objetos: %', v_faltando
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  -- As funções leem e gravam com row_security = off e filtro explícito de conta.
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles
                  WHERE rolname = current_user AND (rolsuper OR rolbypassrls)) THEN
    RAISE EXCEPTION '0030: o papel % não é superusuário nem tem BYPASSRLS', current_user
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF to_regclass('folha.contabil_mapa') IS NOT NULL THEN
    RAISE EXCEPTION '0030: folha.contabil_mapa já existe' USING ERRCODE = 'duplicate_table';
  END IF;
END
$$;

-- ===========================================================================
-- 1. Mapeamento contábil
-- ===========================================================================

-- 1.1 Papel de uma linha no lote: o lado natural e as naturezas de conta aceitas (regra V9 do
--     parecer). É ESTRUTURA do produto: não tem conta nem empresa.
CREATE TABLE folha.contabil_papel (
  papel text PRIMARY KEY CHECK (papel ~ '^[a-z][a-z_]{1,39}$'),
  lado text NOT NULL CHECK (lado IN ('D', 'C')),
  naturezas text[] NOT NULL CHECK (naturezas <@ ARRAY['despesa', 'custo', 'passivo', 'ativo', 'redutora'] AND cardinality(naturezas) > 0),
  descricao text NOT NULL
);
INSERT INTO folha.contabil_papel (papel, lado, naturezas, descricao) VALUES
  ('provento',          'D', ARRAY['despesa', 'custo', 'ativo', 'passivo', 'redutora'],
     'Provento do trabalhador, por rubrica: despesa ou custo; ativo ou redutora de passivo quando é valor a compensar ou adiantamento'),
  ('desconto',          'C', ARRAY['passivo', 'ativo', 'redutora'],
     'Desconto do trabalhador, por rubrica: passivo a recolher ou a repassar, baixa de ativo ou redutora de despesa'),
  ('liquido',           'C', ARRAY['passivo'], 'Líquido a pagar ao trabalhador'),
  ('encargo_despesa',   'D', ARRAY['despesa', 'custo'], 'Encargo patronal: lado da despesa ou do custo'),
  ('encargo_passivo',   'C', ARRAY['passivo'], 'Encargo patronal: obrigação a recolher'),
  ('provisao_despesa',  'D', ARRAY['despesa', 'custo'], 'Constituição de provisão: lado da despesa ou do custo'),
  ('provisao_passivo',  'C', ARRAY['passivo'], 'Provisão constituída (passivo); a baixa debita a mesma conta'),
  ('provisao_reversao', 'C', ARRAY['despesa', 'custo', 'redutora'],
     'Contrapartida de resultado do estorno do saldo de provisão que sobrou na rescisão'),
  ('banco',             'C', ARRAY['ativo'], 'Saída de caixa nos eventos de pagamento');

-- 1.2 Chaves que não são rubrica de provento ou desconto: o que mais precisa de conta.
CREATE TABLE folha.contabil_chave (
  chave text NOT NULL CHECK (chave ~ '^[A-Z][A-Z0-9_]{1,39}$'),
  papel text NOT NULL REFERENCES folha.contabil_papel (papel),
  descricao text NOT NULL,
  PRIMARY KEY (chave, papel)
);
INSERT INTO folha.contabil_chave (chave, papel, descricao)
SELECT k.chave, p.papel, k.descricao
  FROM (VALUES
    ('INSS_PATRONAL',         'encargo', 'Contribuição previdenciária patronal'),
    ('RAT_SAT',               'encargo', 'RAT ajustado pelo FAP'),
    ('TERCEIROS',             'encargo', 'Contribuições a terceiros'),
    ('FGTS_DEPOSITO',         'encargo', 'FGTS do mês (e o depósito rescisório)'),
    ('FGTS_MULTA_RESCISORIA', 'encargo', 'Multa rescisória do FGTS (depositada na conta vinculada; fora do líquido)'),
    ('PROV_13',               'provisao', 'Provisão de 13º salário'),
    ('PROV_13_ENCARGOS',      'provisao', 'Provisão de encargos previdenciários sobre o 13º'),
    ('PROV_13_FGTS',          'provisao', 'Provisão de FGTS sobre o 13º'),
    ('PROV_FERIAS',           'provisao', 'Provisão de férias com o terço'),
    ('PROV_FERIAS_ENCARGOS',  'provisao', 'Provisão de encargos previdenciários sobre férias'),
    ('PROV_FERIAS_FGTS',      'provisao', 'Provisão de FGTS sobre férias')
  ) AS k(chave, grupo, descricao)
  JOIN folha.contabil_papel p
    ON (k.grupo = 'encargo' AND p.papel IN ('encargo_despesa', 'encargo_passivo'))
    OR (k.grupo = 'provisao' AND p.papel IN ('provisao_despesa', 'provisao_passivo', 'provisao_reversao'));
INSERT INTO folha.contabil_chave (chave, papel, descricao) VALUES
  ('LIQUIDO', 'liquido', 'Líquido do trabalhador (soma dos proventos menos a soma dos descontos)'),
  ('BANCO',   'banco',   'Conta de saída de caixa dos eventos de pagamento');

-- 1.3 Configuração por empregador. Sem linha, nada é contabilizado (pendência de bloqueio):
--     a dimensão das linhas de resultado e a data do estorno são decisões da empresa.
CREATE TABLE folha.contabil_config (
  account_id uuid NOT NULL,
  employer_id uuid NOT NULL,
  -- separador das linhas de resultado (despesa, custo e redutora); passivo e ativo não têm
  dimensao text NOT NULL CHECK (dimensao IN ('nenhuma', 'estabelecimento', 'lotacao', 'centro_custo', 'departamento')),
  -- data do lançamento de estorno: a do lote estornado ou a do dia do estorno (ponto em
  -- aberto 3 do parecer: decisão de política contábil da empresa)
  estorno_data text NOT NULL CHECK (estorno_data IN ('data_original', 'data_do_estorno')),
  -- provisionar também os encargos (previdenciários e FGTS) sobre férias e 13º
  provisao_encargos boolean NOT NULL,
  definido_por_subject uuid NOT NULL,
  definido_em timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, employer_id),
  CONSTRAINT contabil_config_employer_fk FOREIGN KEY (account_id, employer_id)
    REFERENCES folha.employer (account_id, employer_id)
);

-- 1.4 Mapeamento. A Folha guarda o CÓDIGO da conta informado por quem configura e a natureza;
--     o plano de contas é do módulo contábil. Linha nasce inativa por padrão da tabela.
--     Escopo opcional: no máximo um entre estabelecimento, lotação e centro de custo.
CREATE TABLE folha.contabil_mapa (
  mapa_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  employer_id uuid NOT NULL,
  establishment_id uuid,
  allocation_id uuid,
  centro_custo text CHECK (centro_custo ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'),
  -- NULL = vale para todo regime; 'contribuinte_individual' separa o pró-labore
  regime_trabalho text CHECK (regime_trabalho IN ('clt', 'aprendiz', 'estagio', 'contribuinte_individual')),
  -- NULL = vale para todo evento; informado, vale só naquele (ex.: o líquido da rescisão em
  -- "rescisões a pagar" e o da folha mensal em "salários a pagar")
  evento_tipo text CHECK (evento_tipo IN (
    'folha_mensal', 'folha_complementar', 'adiantamento_salarial', 'decimo_terceiro', 'ferias', 'rescisao', 'pro_labore',
    'provisao_ferias', 'provisao_13o')),
  chave text NOT NULL CHECK (chave ~ '^[A-Z][A-Z0-9_]{1,39}$'),
  papel text NOT NULL REFERENCES folha.contabil_papel (papel),
  natureza text NOT NULL CHECK (natureza IN ('despesa', 'custo', 'passivo', 'ativo', 'redutora')),
  conta_codigo text NOT NULL CHECK (conta_codigo ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'),
  -- provento que é utilização de provisão: debita a provisão até o saldo do trabalhador e só
  -- o excedente vai para a conta deste mapeamento (regra V11)
  baixa_provisao text CHECK (baixa_provisao IN ('ferias', 'decimo_terceiro')),
  -- passivo liquidado por qual evento de pagamento (a guia de cada tributo é decisão de quem
  -- configura: o parecer deixa o agrupamento por guia a validar na fonte)
  grupo_liquidacao text CHECK (grupo_liquidacao IN (
    'pagamento_liquido', 'recolhimento_previdenciario', 'recolhimento_irrf', 'fgts_deposito', 'repasse_terceiros')),
  vigencia_inicio date NOT NULL,
  vigencia_fim date,               -- inclusiva; NULL = em aberto
  ativo boolean NOT NULL DEFAULT false,
  criado_por_subject uuid NOT NULL,
  criado_em timestamptz NOT NULL DEFAULT now(),
  atualizado_por_subject uuid,
  atualizado_em timestamptz,
  CONSTRAINT contabil_mapa_employer_fk FOREIGN KEY (account_id, employer_id)
    REFERENCES folha.employer (account_id, employer_id),
  CONSTRAINT contabil_mapa_establishment_fk FOREIGN KEY (account_id, employer_id, establishment_id)
    REFERENCES folha.establishment (account_id, employer_id, establishment_id),
  CONSTRAINT contabil_mapa_allocation_fk FOREIGN KEY (account_id, employer_id, allocation_id)
    REFERENCES folha.tax_allocation (account_id, employer_id, allocation_id),
  CONSTRAINT contabil_mapa_vigencia_valida CHECK (vigencia_fim IS NULL OR vigencia_fim >= vigencia_inicio),
  CONSTRAINT contabil_mapa_um_escopo CHECK (
    (establishment_id IS NOT NULL)::integer + (allocation_id IS NOT NULL)::integer + (centro_custo IS NOT NULL)::integer <= 1),
  CONSTRAINT contabil_mapa_baixa_so_em_provento CHECK (baixa_provisao IS NULL OR papel = 'provento'),
  CONSTRAINT contabil_mapa_liquidacao_so_em_passivo CHECK (
    grupo_liquidacao IS NULL OR (natureza = 'passivo' AND papel IN ('desconto', 'liquido', 'encargo_passivo'))),
  -- duas linhas ativas da mesma chave, papel, regime, evento e escopo não valem no mesmo dia
  CONSTRAINT contabil_mapa_sem_sobreposicao EXCLUDE USING gist (
    employer_id WITH =,
    chave WITH =,
    papel WITH =,
    (COALESCE(regime_trabalho, '*')) WITH =,
    (COALESCE(evento_tipo, '*')) WITH =,
    (COALESCE('e:' || establishment_id::text, 'l:' || allocation_id::text, 'c:' || centro_custo, '*')) WITH =,
    daterange(vigencia_inicio, vigencia_fim, '[]') WITH &&
  ) WHERE (ativo)
);
CREATE INDEX idx_contabil_mapa_busca ON folha.contabil_mapa (account_id, employer_id, chave, papel) WHERE ativo;

-- Confere a linha do mapeamento no dado (vale para qualquer caminho de gravação): natureza
-- compatível com o papel; chave existente; depois de criada, só mudam o fim da vigência e o
-- indicador de ativo (trocar a conta = encerrar a linha e criar outra, para o histórico ficar).
CREATE FUNCTION folha.contabil_mapa_trava() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_naturezas text[];
  v_tipo text;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    IF ROW(NEW.mapa_id, NEW.account_id, NEW.employer_id, NEW.establishment_id, NEW.allocation_id, NEW.centro_custo,
           NEW.regime_trabalho, NEW.evento_tipo, NEW.chave, NEW.papel, NEW.natureza, NEW.conta_codigo, NEW.baixa_provisao,
           NEW.grupo_liquidacao, NEW.vigencia_inicio, NEW.criado_por_subject, NEW.criado_em)
       IS DISTINCT FROM
       ROW(OLD.mapa_id, OLD.account_id, OLD.employer_id, OLD.establishment_id, OLD.allocation_id, OLD.centro_custo,
           OLD.regime_trabalho, OLD.evento_tipo, OLD.chave, OLD.papel, OLD.natureza, OLD.conta_codigo, OLD.baixa_provisao,
           OLD.grupo_liquidacao, OLD.vigencia_inicio, OLD.criado_por_subject, OLD.criado_em) THEN
      RAISE EXCEPTION 'contabil_mapa: a linha % só aceita mudar o fim da vigência e o indicador de ativo; para trocar a conta, encerre e crie outra', OLD.mapa_id
        USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
  END IF;

  SELECT p.naturezas INTO v_naturezas FROM folha.contabil_papel p WHERE p.papel = NEW.papel;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'contabil_mapa: papel % desconhecido', NEW.papel USING ERRCODE = 'check_violation';
  END IF;
  IF NOT (NEW.natureza = ANY (v_naturezas)) THEN
    RAISE EXCEPTION 'contabil_mapa: a natureza % não é aceita para o papel % (aceitas: %)',
      NEW.natureza, NEW.papel, array_to_string(v_naturezas, ', ')
      USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.papel IN ('provento', 'desconto') THEN
    SELECT e.tipo_rubrica INTO v_tipo
      FROM folha.earning_deduction_code e
     WHERE e.codigo = NEW.chave AND (e.account_id IS NULL OR e.account_id = NEW.account_id)
     ORDER BY (e.account_id IS NULL)
     LIMIT 1;
    IF NOT FOUND OR v_tipo IS DISTINCT FROM NEW.papel THEN
      RAISE EXCEPTION 'contabil_mapa: % não é rubrica de % disponível para esta conta', NEW.chave, NEW.papel
        USING ERRCODE = 'check_violation';
    END IF;
  ELSIF NOT EXISTS (SELECT 1 FROM folha.contabil_chave k WHERE k.chave = NEW.chave AND k.papel = NEW.papel) THEN
    RAISE EXCEPTION 'contabil_mapa: a chave % não existe para o papel %', NEW.chave, NEW.papel
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END
$function$;
CREATE TRIGGER trg_contabil_mapa_trava
  BEFORE INSERT OR UPDATE ON folha.contabil_mapa
  FOR EACH ROW EXECUTE FUNCTION folha.contabil_mapa_trava();

-- 1.5 Centro de custo e departamento do contrato, por vigência (a 0014 não tem). Só é lido
--     quando a dimensão configurada, ou o escopo de um mapeamento, é centro de custo ou
--     departamento.
CREATE TABLE folha.contract_cost_assignment (
  assignment_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  contract_id uuid NOT NULL,
  centro_custo text CHECK (centro_custo ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'),
  departamento text CHECK (departamento ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'),
  vigencia_inicio date NOT NULL,
  vigencia_fim date,
  definido_por_subject uuid NOT NULL,
  definido_em timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT contract_cost_assignment_contract_fk FOREIGN KEY (account_id, contract_id)
    REFERENCES folha.employment_contract (account_id, contract_id),
  CONSTRAINT contract_cost_assignment_com_valor CHECK (centro_custo IS NOT NULL OR departamento IS NOT NULL),
  CONSTRAINT contract_cost_assignment_vigencia_valida CHECK (vigencia_fim IS NULL OR vigencia_fim >= vigencia_inicio),
  CONSTRAINT contract_cost_assignment_sem_sobreposicao EXCLUDE USING gist (
    contract_id WITH =, daterange(vigencia_inicio, vigencia_fim, '[]') WITH &&)
);

-- ===========================================================================
-- 2. Outbox contábil: lote, versão, totais em centavos e partida fechada
-- ===========================================================================
-- As linhas anteriores a esta migration (um evento por resultado, em reais, com contas fixas)
-- ficam marcadas 'legado' e não são tocadas. Toda linha nova é 'v2'.
ALTER TABLE folha.accounting_outbox
  ALTER COLUMN run_id DROP NOT NULL,      -- provisão é por empregador e competência, sem folha
  ALTER COLUMN result_id DROP NOT NULL,   -- o lote é da folha, não de um resultado
  ADD COLUMN formato text NOT NULL DEFAULT 'legado'
    CONSTRAINT accounting_outbox_formato_check CHECK (formato IN ('legado', 'v2')),
  ADD COLUMN employer_id uuid,
  ADD COLUMN competencia date,
  ADD COLUMN versao integer,
  ADD COLUMN data_lancamento date,
  ADD COLUMN payload_hash text,
  ADD COLUMN total_debito_minor bigint,
  ADD COLUMN total_credito_minor bigint,
  ADD COLUMN estorna_outbox_id bigint,
  ADD COLUMN vigente boolean NOT NULL DEFAULT true,
  ADD COLUMN composicao jsonb,
  ADD COLUMN comprovante_ref text,
  ADD COLUMN contabilizado_por_subject uuid,
  ADD COLUMN cancelado_em timestamptz,
  ADD COLUMN cancelado_motivo text;
ALTER TABLE folha.accounting_outbox ALTER COLUMN formato SET DEFAULT 'v2';

ALTER TABLE folha.accounting_outbox
  DROP CONSTRAINT accounting_outbox_evento_tipo_check,
  DROP CONSTRAINT accounting_outbox_status_check;
ALTER TABLE folha.accounting_outbox
  ADD CONSTRAINT accounting_outbox_evento_tipo_check CHECK (evento_tipo IN (
    -- apropriação, por folha
    'folha_mensal', 'folha_complementar', 'adiantamento_salarial', 'decimo_terceiro', 'ferias', 'rescisao', 'pro_labore',
    -- provisão, por empregador e competência
    'provisao_ferias', 'provisao_13o',
    -- pagamento, por comprovante
    'pagamento_liquido', 'recolhimento_previdenciario', 'recolhimento_irrf', 'fgts_deposito', 'repasse_terceiros',
    -- estorno de lote
    'estorno',
    -- só nas linhas legadas da 0018 (os encargos saem no lote da folha)
    'encargos_patronais')),
  -- retido = lote pronto que espera a liberação de pendência a_validar; cancelado = lote
  -- substituído antes de ser despachado
  ADD CONSTRAINT accounting_outbox_status_check CHECK (status IN (
    'retido', 'pendente', 'despachado', 'confirmado', 'rejeitado', 'cancelado')),
  -- Regra V1: lote desbalanceado não existe na tabela.
  ADD CONSTRAINT accounting_outbox_lote_balanceado CHECK (
    formato = 'legado' OR (total_debito_minor = total_credito_minor AND total_debito_minor > 0)),
  ADD CONSTRAINT accounting_outbox_v2_completo CHECK (
    formato = 'legado'
    OR (employer_id IS NOT NULL AND competencia IS NOT NULL AND versao >= 1 AND data_lancamento IS NOT NULL
        AND payload_hash ~ '^[0-9a-f]{64}$' AND total_debito_minor IS NOT NULL AND total_credito_minor IS NOT NULL
        AND composicao IS NOT NULL AND contabilizado_por_subject IS NOT NULL AND result_id IS NULL
        AND EXTRACT(DAY FROM competencia) = 1)),
  ADD CONSTRAINT accounting_outbox_legado_inalterado CHECK (
    formato = 'v2' OR (run_id IS NOT NULL AND result_id IS NOT NULL)),
  ADD CONSTRAINT accounting_outbox_estorno_coerente CHECK (
    formato = 'legado' OR ((evento_tipo = 'estorno') = (estorna_outbox_id IS NOT NULL))),
  ADD CONSTRAINT accounting_outbox_pagamento_com_comprovante CHECK (
    formato = 'legado'
    OR ((evento_tipo IN ('pagamento_liquido', 'recolhimento_previdenciario', 'recolhimento_irrf', 'fgts_deposito', 'repasse_terceiros'))
        = (comprovante_ref IS NOT NULL))),
  ADD CONSTRAINT accounting_outbox_provisao_sem_folha CHECK (
    formato = 'legado' OR evento_tipo = 'estorno'
    OR ((evento_tipo IN ('provisao_ferias', 'provisao_13o')) = (run_id IS NULL))),
  ADD CONSTRAINT accounting_outbox_cancelamento_coerente CHECK (
    (status = 'cancelado') = (cancelado_em IS NOT NULL)),
  ADD CONSTRAINT accounting_outbox_employer_fk FOREIGN KEY (account_id, employer_id)
    REFERENCES folha.employer (account_id, employer_id),
  ADD CONSTRAINT accounting_outbox_run_conta_fk FOREIGN KEY (account_id, run_id)
    REFERENCES folha.payroll_run (account_id, run_id);
CREATE UNIQUE INDEX accounting_outbox_account_outbox_key ON folha.accounting_outbox (account_id, outbox_id);
ALTER TABLE folha.accounting_outbox
  ADD CONSTRAINT accounting_outbox_estorna_fk FOREIGN KEY (account_id, estorna_outbox_id)
    REFERENCES folha.accounting_outbox (account_id, outbox_id);

-- Um lote vigente por folha, empregador e evento (a folha sem empregador próprio pode reunir
-- contratos de mais de um: sai um lote para cada), e por empregador, competência e provisão.
CREATE UNIQUE INDEX accounting_outbox_vigente_folha_key
  ON folha.accounting_outbox (account_id, run_id, employer_id, evento_tipo)
  WHERE formato = 'v2' AND vigente
    AND evento_tipo IN ('folha_mensal', 'folha_complementar', 'adiantamento_salarial', 'decimo_terceiro', 'ferias', 'rescisao', 'pro_labore');
CREATE UNIQUE INDEX accounting_outbox_vigente_provisao_key
  ON folha.accounting_outbox (account_id, employer_id, competencia, evento_tipo)
  WHERE formato = 'v2' AND vigente AND evento_tipo IN ('provisao_ferias', 'provisao_13o');
-- Um estorno por lote estornado; um lote por comprovante e tipo de pagamento.
CREATE UNIQUE INDEX accounting_outbox_versao_folha_key
  ON folha.accounting_outbox (account_id, run_id, employer_id, evento_tipo, versao)
  WHERE formato = 'v2' AND evento_tipo IN ('folha_mensal', 'folha_complementar', 'adiantamento_salarial', 'decimo_terceiro', 'ferias', 'rescisao', 'pro_labore');
CREATE UNIQUE INDEX accounting_outbox_versao_provisao_key
  ON folha.accounting_outbox (account_id, employer_id, competencia, evento_tipo, versao)
  WHERE formato = 'v2' AND evento_tipo IN ('provisao_ferias', 'provisao_13o');
CREATE UNIQUE INDEX accounting_outbox_estorna_key
  ON folha.accounting_outbox (account_id, estorna_outbox_id) WHERE estorna_outbox_id IS NOT NULL;
CREATE UNIQUE INDEX accounting_outbox_comprovante_key
  ON folha.accounting_outbox (account_id, evento_tipo, comprovante_ref) WHERE comprovante_ref IS NOT NULL;
CREATE INDEX idx_accounting_outbox_run ON folha.accounting_outbox (account_id, run_id) WHERE run_id IS NOT NULL;

-- 2.1 Resumo (hash) do conteúdo contábil do evento v2. Não inclui versão, chave do envio nem
--     hora de emissão: conteúdo igual tem o mesmo resumo (regra V6).
CREATE FUNCTION folha.contabil_payload_hash(p_payload jsonb) RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $function$
  SELECT encode(sha256(convert_to(
           'v2|' || COALESCE(p_payload->>'eventType', '') || '|' || COALESCE(p_payload->>'competence', '')
           || '|' || COALESCE(p_payload->>'entryDate', '') || '|' || COALESCE(p_payload->>'employerId', '')
           || '|' || COALESCE(p_payload->>'payrollRunId', '') || '|' || COALESCE(p_payload->>'dimensionType', '')
           || '|' || COALESCE(p_payload->>'reverses', '') || '|' || COALESCE(p_payload->'evidence'->>'reference', '')
           || '|' || COALESCE((
                SELECT string_agg(
                         COALESCE(e->>'entryKey', '') || ':' || COALESCE(e->>'accountKey', '') || ':' || COALESCE(e->>'dimensionKey', '')
                         || ':' || COALESCE(e->>'debitMinor', '') || ':' || COALESCE(e->>'creditMinor', ''),
                         ';' ORDER BY (e->>'entryKey') COLLATE "C")
                  FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_payload->'entries') = 'array'
                                                 THEN p_payload->'entries' ELSE '[]'::jsonb END) AS e), ''),
           'UTF8')), 'hex');
$function$;

-- 2.2 Guarda da inserção: só nasce lote v2, sob contexto com folha.transmit, com o subject do
--     contexto, e com os totais e o resumo RECALCULADOS a partir das linhas do evento.
CREATE FUNCTION folha.accounting_outbox_guarda() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx record;
  v_debito numeric;
  v_credito numeric;
  v_ruins integer;
  v_n integer;
BEGIN
  IF NEW.formato IS DISTINCT FROM 'v2' THEN
    RAISE EXCEPTION 'accounting_outbox: só o formato v2 é aceito em linha nova' USING ERRCODE = 'check_violation';
  END IF;
  SELECT c.account_id, c.subject_id INTO v_ctx FROM folha.contexto_v1('folha.transmit') AS c;
  IF v_ctx.account_id IS DISTINCT FROM NEW.account_id THEN
    RAISE EXCEPTION USING ERRCODE = '42501', MESSAGE = 'Lote contábil de outra conta';
  END IF;
  NEW.contabilizado_por_subject := v_ctx.subject_id;

  IF jsonb_typeof(NEW.payload->'entries') IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'accounting_outbox: o evento não tem linhas' USING ERRCODE = 'check_violation';
  END IF;
  SELECT count(*),
         count(*) FILTER (WHERE COALESCE(e->>'debitMinor', '') !~ '^[0-9]+$' OR COALESCE(e->>'creditMinor', '') !~ '^[0-9]+$'),
         COALESCE(sum(CASE WHEN e->>'debitMinor' ~ '^[0-9]+$' THEN (e->>'debitMinor')::numeric END), 0),
         COALESCE(sum(CASE WHEN e->>'creditMinor' ~ '^[0-9]+$' THEN (e->>'creditMinor')::numeric END), 0)
    INTO v_n, v_ruins, v_debito, v_credito
    FROM jsonb_array_elements(NEW.payload->'entries') AS e;
  IF v_n = 0 OR v_ruins > 0 THEN
    RAISE EXCEPTION 'accounting_outbox: o evento não tem linhas ou tem linha com valor fora do formato de centavos'
      USING ERRCODE = 'check_violation';
  END IF;
  -- Regra V2: cada linha tem exatamente um lado com valor maior que zero.
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(NEW.payload->'entries') AS e
              WHERE ((e->>'debitMinor')::numeric > 0) = ((e->>'creditMinor')::numeric > 0)) THEN
    RAISE EXCEPTION 'accounting_outbox: linha com os dois lados zerados ou com os dois lados preenchidos'
      USING ERRCODE = 'check_violation';
  END IF;
  -- Regras V1 e V3 do parecer (E3): os totais são a soma das linhas, e débito = crédito.
  IF v_debito IS DISTINCT FROM NEW.total_debito_minor::numeric
     OR v_credito IS DISTINCT FROM NEW.total_credito_minor::numeric
     OR (NEW.payload->'totals'->>'debitMinor') IS DISTINCT FROM v_debito::text
     OR (NEW.payload->'totals'->>'creditMinor') IS DISTINCT FROM v_credito::text THEN
    RAISE EXCEPTION 'accounting_outbox: os totais do lote (D % / C %) não são a soma das linhas (D % / C %)',
      NEW.total_debito_minor, NEW.total_credito_minor, v_debito, v_credito
      USING ERRCODE = 'check_violation';
  END IF;
  IF v_debito <> v_credito THEN
    RAISE EXCEPTION 'accounting_outbox: lote desbalanceado (D % / C %)', v_debito, v_credito
      USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.payload_hash IS DISTINCT FROM folha.contabil_payload_hash(NEW.payload)
     OR (NEW.payload->>'payloadHash') IS DISTINCT FROM NEW.payload_hash
     OR (NEW.payload->>'contractVersion') IS DISTINCT FROM 'gestao.folha-handoff.v2'
     OR (NEW.payload->>'handoffKey') IS DISTINCT FROM NEW.idempotency_key
     OR (NEW.payload->>'accountId') IS DISTINCT FROM NEW.account_id::text
     OR (NEW.payload->>'eventType') IS DISTINCT FROM NEW.evento_tipo
     OR (NEW.payload->>'version') IS DISTINCT FROM NEW.versao::text
     OR (NEW.payload->>'entryDate') IS DISTINCT FROM to_char(NEW.data_lancamento, 'YYYY-MM-DD')
     OR (NEW.payload->>'competence') IS DISTINCT FROM to_char(NEW.competencia, 'YYYY-MM') THEN
    RAISE EXCEPTION 'accounting_outbox: o evento não confere com as colunas do lote (resumo, versão, tipo, conta, datas)'
      USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.status NOT IN ('retido', 'pendente') THEN
    RAISE EXCEPTION 'accounting_outbox: lote nasce retido ou pendente' USING ERRCODE = 'check_violation';
  END IF;
  NEW.vigente := true;
  RETURN NEW;
END
$function$;
CREATE TRIGGER trg_accounting_outbox_guarda
  BEFORE INSERT ON folha.accounting_outbox
  FOR EACH ROW EXECUTE FUNCTION folha.accounting_outbox_guarda();

-- 2.3 Lote v2 não é editado: só o estado anda. Quem consome a fila (worker) marca despachado,
--     confirmado e rejeitado; cancelar, liberar lote retido e tirar a vigência é só das
--     funções desta migration (o dono da tabela). SECURITY INVOKER de propósito: current_user
--     tem de ser quem executa o UPDATE.
CREATE FUNCTION folha.accounting_outbox_imutavel() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  v_dono boolean;
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF OLD.formato = 'v2' THEN
      RAISE EXCEPTION 'accounting_outbox: lote v2 não é apagado (cancelamento e estorno ficam registrados)'
        USING ERRCODE = 'check_violation';
    END IF;
    RETURN OLD;
  END IF;
  IF OLD.formato = 'legado' THEN
    IF NEW.formato <> 'legado' THEN
      RAISE EXCEPTION 'accounting_outbox: linha legada não vira v2' USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
  END IF;
  IF (to_jsonb(NEW) - ARRAY['status', 'despachado_em', 'confirmado_em', 'erro_json', 'vigente', 'cancelado_em', 'cancelado_motivo'])
     IS DISTINCT FROM
     (to_jsonb(OLD) - ARRAY['status', 'despachado_em', 'confirmado_em', 'erro_json', 'vigente', 'cancelado_em', 'cancelado_motivo']) THEN
    RAISE EXCEPTION 'accounting_outbox: o lote % não pode ser alterado; só o estado anda', OLD.outbox_id
      USING ERRCODE = 'check_violation';
  END IF;
  SELECT c.relowner = (SELECT r.oid FROM pg_catalog.pg_roles r WHERE r.rolname = current_user)
    INTO v_dono
    FROM pg_catalog.pg_class c WHERE c.oid = TG_RELID;
  IF NEW.status IS DISTINCT FROM OLD.status THEN
    IF NOT (   (OLD.status = 'pendente'   AND NEW.status = 'despachado')
            OR (OLD.status = 'despachado' AND NEW.status IN ('confirmado', 'rejeitado'))
            OR (v_dono AND OLD.status = 'retido' AND NEW.status IN ('pendente', 'cancelado'))
            OR (v_dono AND OLD.status = 'pendente' AND NEW.status = 'cancelado')) THEN
      RAISE EXCEPTION 'accounting_outbox: o lote % não passa de % para %', OLD.outbox_id, OLD.status, NEW.status
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  -- Lote retido só é liberado depois da última pendência a_validar dele.
  IF OLD.status = 'retido' AND NEW.status = 'pendente'
     AND EXISTS (SELECT 1 FROM folha.contabil_pendencia p
                  WHERE p.account_id = OLD.account_id AND p.outbox_id = OLD.outbox_id AND p.tipo = 'a_validar'
                    AND p.liberada_em IS NULL AND p.resolvida_em IS NULL) THEN
    RAISE EXCEPTION 'accounting_outbox: o lote % tem pendência a_validar sem liberação e continua retido', OLD.outbox_id
      USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.vigente IS DISTINCT FROM OLD.vigente AND (NEW.vigente OR NOT v_dono) THEN
    RAISE EXCEPTION 'accounting_outbox: a vigência do lote % só é retirada pelas funções de contabilização', OLD.outbox_id
      USING ERRCODE = 'check_violation';
  END IF;
  IF NOT v_dono AND ROW(NEW.cancelado_em, NEW.cancelado_motivo) IS DISTINCT FROM ROW(OLD.cancelado_em, OLD.cancelado_motivo) THEN
    RAISE EXCEPTION 'accounting_outbox: o cancelamento do lote % é só das funções de contabilização', OLD.outbox_id
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END
$function$;
CREATE TRIGGER trg_accounting_outbox_imutavel
  BEFORE UPDATE OR DELETE ON folha.accounting_outbox
  FOR EACH ROW EXECUTE FUNCTION folha.accounting_outbox_imutavel();

-- A gravação é só pelas funções desta migration (como a 0027 fez com payroll_result): o
-- INSERT direto do worker sai. O UPDATE fica, para o consumidor da fila marcar o estado.
REVOKE INSERT ON folha.accounting_outbox FROM dnex_gestao_folha_worker;

-- ===========================================================================
-- 3. Pendências da contabilização
--    bloqueio  = falta cadastro (mapeamento, configuração, dimensão, direito de provisão):
--                o lote NÃO sai e a pendência NÃO é liberável; some quando a contabilização
--                passa (resolvida_em).
--    a_validar = regra ou parâmetro não conferido na fonte: o lote nasce RETIDO e só vira
--                pendente quando todas forem liberadas, com subject e motivo.
-- ===========================================================================
CREATE TABLE folha.contabil_pendencia (
  pendencia_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  employer_id uuid,
  run_id uuid,
  competencia date,
  evento_tipo text NOT NULL,
  codigo text NOT NULL CHECK (btrim(codigo) <> ''),
  tipo text NOT NULL CHECK (tipo IN ('bloqueio', 'a_validar')),
  detalhe jsonb NOT NULL DEFAULT '{}'::jsonb,
  outbox_id bigint,
  criada_em timestamptz NOT NULL DEFAULT now(),
  criada_por_subject uuid NOT NULL,
  resolvida_em timestamptz,
  liberada_em timestamptz,
  liberada_por_subject uuid,
  liberacao_motivo text,
  CONSTRAINT contabil_pendencia_employer_fk FOREIGN KEY (account_id, employer_id)
    REFERENCES folha.employer (account_id, employer_id),
  CONSTRAINT contabil_pendencia_run_fk FOREIGN KEY (account_id, run_id)
    REFERENCES folha.payroll_run (account_id, run_id),
  CONSTRAINT contabil_pendencia_outbox_fk FOREIGN KEY (account_id, outbox_id)
    REFERENCES folha.accounting_outbox (account_id, outbox_id),
  CONSTRAINT contabil_pendencia_bloqueio_nao_liberavel CHECK (tipo = 'a_validar' OR liberada_em IS NULL),
  CONSTRAINT contabil_pendencia_a_validar_com_lote CHECK ((tipo = 'a_validar') = (outbox_id IS NOT NULL)),
  CONSTRAINT contabil_pendencia_liberacao_completa CHECK (
    (liberada_em IS NULL AND liberada_por_subject IS NULL AND liberacao_motivo IS NULL)
    OR (liberada_em IS NOT NULL AND liberada_por_subject IS NOT NULL AND btrim(COALESCE(liberacao_motivo, '')) <> ''))
);
CREATE UNIQUE INDEX contabil_pendencia_bloqueio_aberto_key
  ON folha.contabil_pendencia (account_id, (COALESCE(run_id, '00000000-0000-0000-0000-000000000000'::uuid)),
                               (COALESCE(employer_id, '00000000-0000-0000-0000-000000000000'::uuid)),
                               (COALESCE(competencia, '0001-01-01'::date)), evento_tipo, codigo)
  WHERE tipo = 'bloqueio' AND resolvida_em IS NULL;
CREATE UNIQUE INDEX contabil_pendencia_a_validar_key
  ON folha.contabil_pendencia (account_id, outbox_id, codigo) WHERE tipo = 'a_validar';
CREATE INDEX idx_contabil_pendencia_run ON folha.contabil_pendencia (account_id, run_id) WHERE run_id IS NOT NULL;

-- ===========================================================================
-- 4. Provisões: direito informado e razão por trabalhador
-- ===========================================================================

-- 4.1 Tipos de movimento do razão, como dado.
CREATE TABLE folha.provision_movement_type (
  tipo text PRIMARY KEY CHECK (tipo ~ '^[a-z][a-z_]{1,39}$'),
  efeito text NOT NULL CHECK (efeito IN ('aumenta', 'reduz', 'inverte')),
  descricao text NOT NULL
);
INSERT INTO folha.provision_movement_type (tipo, efeito, descricao) VALUES
  ('constituicao',     'aumenta', 'Constituição mensal: saldo devido na data menos saldo já provisionado'),
  ('reducao',          'reduz',   'Ajuste mensal quando o saldo devido ficou menor que o provisionado'),
  ('baixa_pagamento',  'reduz',   'Utilização no pagamento de férias, 13º ou rescisão, limitada ao saldo do trabalhador'),
  ('estorno_rescisao', 'reduz',   'Estorno do saldo que sobrou do trabalhador desligado'),
  ('reversao_de_lote', 'inverte', 'Desfaz o movimento de um lote cancelado, rejeitado ou estornado');

-- 4.2 Direito na competência, por contrato: remuneração-base e avos adquiridos. É ENTRADA: a
--     contagem de avos (período aquisitivo, faltas, afastamentos, férias vencidas) não está no
--     parecer contábil nem existe como entidade na Folha; quem informa é o escritório ou, no
--     futuro, o controle de período aquisitivo.
CREATE TABLE folha.provision_entitlement (
  account_id uuid NOT NULL,
  employer_id uuid NOT NULL,
  contract_id uuid NOT NULL,
  competencia date NOT NULL CHECK (EXTRACT(DAY FROM competencia) = 1),
  remuneracao_base numeric(14,2) NOT NULL CHECK (remuneracao_base > 0),
  avos_13 numeric(5,2) NOT NULL CHECK (avos_13 >= 0 AND avos_13 <= 12),
  -- pode passar de 12: férias vencidas ainda não gozadas somam aos avos do período em curso
  avos_ferias numeric(5,2) NOT NULL CHECK (avos_ferias >= 0 AND avos_ferias <= 36),
  informado_por_subject uuid NOT NULL,
  informado_em timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, contract_id, competencia),
  CONSTRAINT provision_entitlement_contract_fk FOREIGN KEY (account_id, employer_id, contract_id)
    REFERENCES folha.employment_contract (account_id, employer_id, contract_id)
);
CREATE INDEX idx_provision_entitlement_employer ON folha.provision_entitlement (account_id, employer_id, competencia);

-- 4.3 Razão. valor_minor tem sinal: positivo aumenta o saldo provisionado do trabalhador.
--     outbox_id é o lote que originou o movimento. Só INSERT.
CREATE TABLE folha.provision_ledger (
  movement_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  account_id uuid NOT NULL,
  employer_id uuid NOT NULL,
  contract_id uuid NOT NULL,
  competencia date NOT NULL CHECK (EXTRACT(DAY FROM competencia) = 1),
  provisao text NOT NULL CHECK (provisao IN ('ferias', 'decimo_terceiro')),
  componente text NOT NULL CHECK (componente IN ('principal', 'encargos', 'fgts')),
  tipo text NOT NULL REFERENCES folha.provision_movement_type (tipo),
  valor_minor bigint NOT NULL CHECK (valor_minor <> 0),
  outbox_id bigint NOT NULL,
  reverte_movement_id bigint,
  memoria jsonb NOT NULL DEFAULT '{}'::jsonb,
  criado_por_subject uuid NOT NULL,
  criado_em timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT provision_ledger_contract_fk FOREIGN KEY (account_id, employer_id, contract_id)
    REFERENCES folha.employment_contract (account_id, employer_id, contract_id),
  CONSTRAINT provision_ledger_outbox_fk FOREIGN KEY (account_id, outbox_id)
    REFERENCES folha.accounting_outbox (account_id, outbox_id),
  CONSTRAINT provision_ledger_reversao_coerente CHECK ((tipo = 'reversao_de_lote') = (reverte_movement_id IS NOT NULL)),
  UNIQUE (account_id, movement_id)
);
ALTER TABLE folha.provision_ledger
  ADD CONSTRAINT provision_ledger_reverte_fk FOREIGN KEY (account_id, reverte_movement_id)
    REFERENCES folha.provision_ledger (account_id, movement_id);
CREATE UNIQUE INDEX provision_ledger_reverte_key ON folha.provision_ledger (reverte_movement_id) WHERE reverte_movement_id IS NOT NULL;
CREATE INDEX idx_provision_ledger_saldo ON folha.provision_ledger (account_id, contract_id, provisao, componente, competencia);
CREATE INDEX idx_provision_ledger_outbox ON folha.provision_ledger (account_id, outbox_id);

CREATE FUNCTION folha.provision_ledger_trava() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_efeito text;
  v_original bigint;
BEGIN
  IF TG_OP <> 'INSERT' THEN
    RAISE EXCEPTION 'provision_ledger: o razão de provisões só aceita inclusão' USING ERRCODE = 'check_violation';
  END IF;
  SELECT t.efeito INTO v_efeito FROM folha.provision_movement_type t WHERE t.tipo = NEW.tipo;
  IF (v_efeito = 'aumenta' AND NEW.valor_minor < 0) OR (v_efeito = 'reduz' AND NEW.valor_minor > 0) THEN
    RAISE EXCEPTION 'provision_ledger: o movimento % não aceita valor com este sinal (%)', NEW.tipo, NEW.valor_minor
      USING ERRCODE = 'check_violation';
  END IF;
  IF v_efeito = 'inverte' THEN
    SELECT m.valor_minor INTO v_original
      FROM folha.provision_ledger m
     WHERE m.account_id = NEW.account_id AND m.movement_id = NEW.reverte_movement_id
       AND m.contract_id = NEW.contract_id AND m.provisao = NEW.provisao AND m.componente = NEW.componente;
    IF NOT FOUND OR v_original <> -NEW.valor_minor THEN
      RAISE EXCEPTION 'provision_ledger: a reversão não espelha o movimento %', NEW.reverte_movement_id
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN NEW;
END
$function$;
CREATE TRIGGER trg_provision_ledger_trava
  BEFORE INSERT OR UPDATE OR DELETE ON folha.provision_ledger
  FOR EACH ROW EXECUTE FUNCTION folha.provision_ledger_trava();
CREATE FUNCTION folha.contabil_sem_truncate() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  RAISE EXCEPTION '%: a tabela não aceita TRUNCATE', TG_TABLE_NAME USING ERRCODE = 'check_violation';
END
$function$;
CREATE TRIGGER trg_provision_ledger_sem_truncate
  BEFORE TRUNCATE ON folha.provision_ledger
  FOR EACH STATEMENT EXECUTE FUNCTION folha.contabil_sem_truncate();
CREATE TRIGGER trg_accounting_outbox_sem_truncate
  BEFORE TRUNCATE ON folha.accounting_outbox
  FOR EACH STATEMENT EXECUTE FUNCTION folha.contabil_sem_truncate();

-- ===========================================================================
-- 5. Parâmetros a validar na fonte (o parecer não fecha estas duas regras)
-- ===========================================================================
INSERT INTO folha.payroll_parameter (chave, valor, vigencia_inicio, fonte_normativa, status_validacao, observacao) VALUES
  ('contabil_provisao_encargos_incide_terco_ferias', 1, '2024-01-01',
   'Parecer técnico contábil de 15/11/2026, seção 2.5 (C5 e C6) e caso GC-03: encargos sobre férias com o terço',
   'a_validar',
   '1 = os encargos provisionados sobre férias incidem também sobre o terço constitucional. A incidência de contribuição previdenciária sobre o terço está a validar na fonte desde a migration 0026.'),
  ('contabil_rescisao_baixa_provisao_encargos', 0, '2024-01-01',
   'Parecer técnico contábil de 15/11/2026, caso GC-06: a variante com provisão de encargos (GC-06b) fica para depois de validar as incidências rescisórias',
   'a_validar',
   '0 = na rescisão os encargos efetivos vão a despesa e o saldo das provisões de encargos do trabalhador é estornado contra o resultado. O valor 1 (baixar a provisão de encargos pelos encargos efetivos) não está implementado.');

-- ===========================================================================
-- 6. Funções internas (ninguém além do dono executa)
--    Bloqueio por falta de cadastro: exceção com SQLSTATE FC001 e, no DETAIL, o JSON da
--    pendência. As funções _v1 e o despacho a capturam, desfazem o que o lote tinha gravado e
--    registram a pendência. Qualquer outro erro (estado da folha, líquido inconsistente,
--    partida que não fecha) é exceção comum e nada fica gravado.
-- ===========================================================================

-- 6.1 Evento contábil de uma folha, pelo tipo de processo.
CREATE FUNCTION folha.contabil_evento_da_folha(p_tipo_processo text) RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $function$
  SELECT CASE p_tipo_processo
           WHEN 'mensal' THEN 'folha_mensal'
           WHEN 'complementar' THEN 'folha_complementar'
           WHEN 'adiantamento' THEN 'adiantamento_salarial'
           WHEN 'decimo_terceiro_1' THEN 'decimo_terceiro'
           WHEN 'decimo_terceiro_2' THEN 'decimo_terceiro'
           WHEN 'ferias' THEN 'ferias'
           WHEN 'rescisao' THEN 'rescisao'
         END;
$function$;

-- 6.2 Chave da provisão no mapeamento.
CREATE FUNCTION folha.contabil_chave_provisao(p_provisao text, p_componente text) RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $function$
  SELECT CASE p_provisao WHEN 'decimo_terceiro' THEN 'PROV_13' WHEN 'ferias' THEN 'PROV_FERIAS' END
         || CASE p_componente WHEN 'principal' THEN '' WHEN 'encargos' THEN '_ENCARGOS' WHEN 'fgts' THEN '_FGTS' END;
$function$;

-- 6.3 Saldo provisionado do trabalhador até a competência, sem os movimentos de um lote (o que
--     está sendo substituído). Até a competência: recontabilizar uma folha antiga não muda
--     porque o trabalhador ganhou provisão depois dela.
CREATE FUNCTION folha.contabil_provisao_saldo(
  p_conta uuid, p_contract_id uuid, p_provisao text, p_componente text, p_ate date, p_ignorar_outbox bigint
) RETURNS bigint
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
  SELECT COALESCE(sum(m.valor_minor), 0)::bigint
    FROM folha.provision_ledger m
   WHERE m.account_id = p_conta AND m.contract_id = p_contract_id
     AND m.provisao = p_provisao AND m.componente = p_componente
     AND m.competencia <= p_ate
     AND m.outbox_id IS DISTINCT FROM p_ignorar_outbox;
$function$;

-- 6.4 Resolve as linhas brutas de um lote: rateia cada valor pelas lotações do contrato (a
--     última leva o resíduo, como o motor faz com os encargos), acha o mapeamento vigente
--     (escopo mais específico primeiro: centro de custo, lotação, estabelecimento, geral; dentro
--     do escopo, a linha do evento antes da genérica e, depois, a do regime de trabalho antes
--     da genérica) e a dimensão.
--     Linha bruta: n, contract_id, chave, papel, valor (centavos), lotacao_id (fixa, opcional),
--     inverte (opcional), origem_chave, origem_papel (opcionais), baixa_provisao e
--     baixa_componente (opcionais, só repassados).
CREATE FUNCTION folha.contabil_linhas_resolver(
  p_conta uuid, p_employer uuid, p_competencia date, p_dimensao text, p_evento text, p_run_id uuid, p_brutas jsonb
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_linhas jsonb;
  v_faltas jsonb;
  v_sem_dim jsonb;
  v_fora integer;
BEGIN
  IF p_brutas IS NULL OR jsonb_array_length(p_brutas) = 0 THEN
    RETURN '[]'::jsonb;
  END IF;

  SELECT count(*) INTO v_fora
    FROM jsonb_array_elements(p_brutas) AS x
   WHERE NOT EXISTS (SELECT 1 FROM folha.employment_contract c
                      WHERE c.account_id = p_conta AND c.employer_id = p_employer
                        AND c.contract_id = (x->>'contract_id')::uuid);
  IF v_fora > 0 THEN
    RAISE EXCEPTION 'Contabilização: há linha de contrato que não é do empregador %', p_employer;
  END IF;

  WITH bruta AS (
    SELECT (x->>'n')::integer AS n, (x->>'contract_id')::uuid AS contract_id,
           x->>'chave' AS chave, x->>'papel' AS papel, (x->>'valor')::bigint AS valor,
           (x->>'lotacao_id')::uuid AS lotacao_fixa,
           COALESCE((x->>'inverte')::boolean, false) AS inverte,
           COALESCE(x->>'origem_chave', x->>'chave') AS origem_chave,
           COALESCE(x->>'origem_papel', x->>'papel') AS origem_papel,
           x->>'baixa_provisao' AS bx_provisao, x->>'baixa_componente' AS bx_componente
      FROM jsonb_array_elements(p_brutas) AS x
  ),
  contrato AS (
    SELECT c.contract_id, c.regime_trabalho, c.establishment_id, d.centro_custo, d.departamento
      FROM folha.employment_contract c
      LEFT JOIN folha.contract_cost_assignment d
        ON d.account_id = c.account_id AND d.contract_id = c.contract_id
       AND d.vigencia_inicio <= p_competencia AND (d.vigencia_fim IS NULL OR d.vigencia_fim >= p_competencia)
     WHERE c.account_id = p_conta AND c.employer_id = p_employer
       AND c.contract_id IN (SELECT b.contract_id FROM bruta b)
  ),
  rateio AS (
    SELECT cta.contract_id, cta.allocation_id, cta.percentual,
           row_number() OVER (PARTITION BY cta.contract_id ORDER BY cta.percentual, cta.allocation_id) AS ord,
           count(*) OVER (PARTITION BY cta.contract_id) AS total
      FROM folha.contract_tax_allocation cta
     WHERE cta.account_id = p_conta AND cta.employer_id = p_employer
       AND cta.contract_id IN (SELECT b.contract_id FROM bruta b)
       AND cta.vigencia_inicio <= p_competencia AND (cta.vigencia_fim IS NULL OR cta.vigencia_fim >= p_competencia)
  ),
  parte AS (
    SELECT b.n, b.contract_id, b.chave, b.papel, b.inverte, b.origem_chave, b.origem_papel, b.bx_provisao, b.bx_componente,
           b.lotacao_fixa AS lotacao_id, b.valor AS valor
      FROM bruta b
     WHERE b.lotacao_fixa IS NOT NULL
        OR NOT EXISTS (SELECT 1 FROM rateio r WHERE r.contract_id = b.contract_id)
    UNION ALL
    SELECT b.n, b.contract_id, b.chave, b.papel, b.inverte, b.origem_chave, b.origem_papel, b.bx_provisao, b.bx_componente,
           r.allocation_id,
           CASE WHEN r.ord < r.total THEN round(b.valor * r.percentual / 100)::bigint
                ELSE b.valor - COALESCE((SELECT sum(round(b.valor * r2.percentual / 100)::bigint)
                                           FROM rateio r2
                                          WHERE r2.contract_id = b.contract_id AND r2.ord < r.total), 0)::bigint
           END
      FROM bruta b
      JOIN rateio r ON r.contract_id = b.contract_id
     WHERE b.lotacao_fixa IS NULL
  ),
  resolvida AS (
    SELECT p.*, k.regime_trabalho, COALESCE(la.establishment_id, k.establishment_id) AS estabelecimento_id,
           k.centro_custo, k.departamento, pp.lado AS lado_papel,
           m.conta_codigo, m.natureza, m.grupo_liquidacao, m.baixa_provisao AS mapa_baixa
      FROM parte p
      JOIN contrato k ON k.contract_id = p.contract_id
      JOIN folha.contabil_papel pp ON pp.papel = p.papel
      LEFT JOIN folha.tax_allocation la ON la.account_id = p_conta AND la.allocation_id = p.lotacao_id
      LEFT JOIN LATERAL (
        SELECT cm.conta_codigo, cm.natureza, cm.grupo_liquidacao, cm.baixa_provisao
          FROM folha.contabil_mapa cm
         WHERE cm.account_id = p_conta AND cm.employer_id = p_employer AND cm.ativo
           AND cm.chave = p.chave AND cm.papel = p.papel
           AND cm.vigencia_inicio <= p_competencia AND (cm.vigencia_fim IS NULL OR cm.vigencia_fim >= p_competencia)
           AND (cm.regime_trabalho IS NULL OR cm.regime_trabalho = k.regime_trabalho)
           AND (cm.evento_tipo IS NULL OR cm.evento_tipo = p_evento)
           AND (   (cm.establishment_id IS NULL AND cm.allocation_id IS NULL AND cm.centro_custo IS NULL)
                OR cm.establishment_id = COALESCE(la.establishment_id, k.establishment_id)
                OR cm.allocation_id = p.lotacao_id
                OR cm.centro_custo = k.centro_custo)
         ORDER BY (cm.centro_custo IS NOT NULL) DESC, (cm.allocation_id IS NOT NULL) DESC,
                  (cm.establishment_id IS NOT NULL) DESC, (cm.evento_tipo IS NOT NULL) DESC,
                  (cm.regime_trabalho IS NOT NULL) DESC
         LIMIT 1
      ) m ON true
     WHERE p.valor > 0
  ),
  final AS (
    SELECT r.*,
           CASE WHEN r.natureza IN ('despesa', 'custo', 'redutora')
                THEN CASE p_dimensao
                       WHEN 'estabelecimento' THEN r.estabelecimento_id::text
                       WHEN 'lotacao' THEN r.lotacao_id::text
                       WHEN 'centro_custo' THEN r.centro_custo
                       WHEN 'departamento' THEN r.departamento
                     END
           END AS dimensao_chave,
           (r.natureza IN ('despesa', 'custo', 'redutora') AND p_dimensao <> 'nenhuma') AS exige_dimensao
      FROM resolvida r
  )
  SELECT
    (SELECT COALESCE(jsonb_agg(jsonb_build_object(
              'n', f.n, 'contract_id', f.contract_id, 'lotacao_id', f.lotacao_id,
              'origem_chave', f.origem_chave, 'origem_papel', f.origem_papel,
              'chave', f.chave, 'papel', f.papel, 'conta', f.conta_codigo, 'natureza', f.natureza,
              'lado', CASE WHEN f.inverte THEN CASE f.lado_papel WHEN 'D' THEN 'C' ELSE 'D' END ELSE f.lado_papel END,
              'dimensao', f.dimensao_chave, 'grupo', f.grupo_liquidacao,
              'baixa_provisao', COALESCE(f.bx_provisao, f.mapa_baixa),
              'baixa_componente', CASE WHEN f.bx_provisao IS NOT NULL THEN f.bx_componente
                                       WHEN f.mapa_baixa IS NOT NULL THEN 'principal' END,
              'valor', f.valor)
              ORDER BY f.n, f.lotacao_id), '[]'::jsonb)
       FROM final f WHERE f.conta_codigo IS NOT NULL),
    (SELECT jsonb_agg(s.x ORDER BY s.x->>'chave', s.x->>'papel', s.x->>'regime_trabalho')
       FROM (SELECT DISTINCT jsonb_build_object('chave', f.chave, 'papel', f.papel, 'regime_trabalho', f.regime_trabalho) AS x
               FROM final f WHERE f.conta_codigo IS NULL) s),
    (SELECT jsonb_agg(s.contract_id ORDER BY s.contract_id)
       FROM (SELECT DISTINCT f.contract_id FROM final f
              WHERE f.conta_codigo IS NOT NULL AND f.exige_dimensao AND f.dimensao_chave IS NULL) s)
    INTO v_linhas, v_faltas, v_sem_dim;

  IF v_faltas IS NOT NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'FC001',
      MESSAGE = 'Contabilização bloqueada: sem mapeamento contábil vigente para '
                || (SELECT string_agg(s.rotulo, ', ' ORDER BY s.rotulo)
                      FROM (SELECT DISTINCT (x->>'chave') || ' (' || (x->>'papel') || ')' AS rotulo
                              FROM jsonb_array_elements(v_faltas) AS x) s),
      DETAIL = jsonb_build_object('codigo', 'mapeamento_ausente', 'evento_tipo', p_evento, 'employer_id', p_employer,
                                  'run_id', p_run_id, 'competencia', p_competencia, 'itens', v_faltas)::text;
  END IF;
  IF v_sem_dim IS NOT NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'FC001',
      MESSAGE = 'Contabilização bloqueada: ' || jsonb_array_length(v_sem_dim)::text
                || ' contrato(s) sem a dimensão configurada (' || p_dimensao || ') na competência',
      DETAIL = jsonb_build_object('codigo', 'dimensao_ausente', 'evento_tipo', p_evento, 'employer_id', p_employer,
                                  'run_id', p_run_id, 'competencia', p_competencia,
                                  'itens', jsonb_build_object('dimensao', p_dimensao, 'contratos', v_sem_dim))::text;
  END IF;
  RETURN v_linhas;
END
$function$;

-- 6.5 Compõe o lote a partir das linhas resolvidas: linhas do evento agrupadas por conta,
--     dimensão e lado; totais = soma das linhas; partida conferida (regra V1). A composição
--     (por chave e papel) fica na Folha para a conciliação e para os pagamentos; não vai no
--     evento.
CREATE FUNCTION folha.contabil_lote_compor(
  p_employer uuid, p_run_id uuid, p_competencia date, p_evento text, p_data date, p_dimensao text,
  p_linhas jsonb, p_movimentos jsonb, p_pendencias text[]
) RETURNS jsonb
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  v_entries jsonb;
  v_comp jsonb;
  v_d numeric;
  v_c numeric;
  v_rotulo text;
BEGIN
  v_rotulo := CASE p_evento
                WHEN 'folha_mensal' THEN 'Folha de pagamento'
                WHEN 'folha_complementar' THEN 'Folha complementar'
                WHEN 'adiantamento_salarial' THEN 'Adiantamento salarial'
                WHEN 'decimo_terceiro' THEN '13o salario'
                WHEN 'ferias' THEN 'Ferias'
                WHEN 'rescisao' THEN 'Rescisao'
                WHEN 'pro_labore' THEN 'Pro-labore'
                WHEN 'provisao_ferias' THEN 'Provisao de ferias'
                WHEN 'provisao_13o' THEN 'Provisao de 13o salario'
                WHEN 'pagamento_liquido' THEN 'Pagamento do liquido'
                WHEN 'recolhimento_previdenciario' THEN 'Recolhimento previdenciario'
                WHEN 'recolhimento_irrf' THEN 'Recolhimento do IRRF'
                WHEN 'fgts_deposito' THEN 'Deposito do FGTS'
                WHEN 'repasse_terceiros' THEN 'Repasse a terceiros'
                ELSE p_evento
              END || ' ' || to_char(p_competencia, 'MM/YYYY');

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'entryKey', 'e-' || left(encode(sha256(convert_to(g.lado || '|' || g.conta || '|' || COALESCE(g.dimensao, ''), 'UTF8')), 'hex'), 30),
           'accountKey', g.conta,
           'dimensionKey', g.dimensao,
           'debitMinor', CASE g.lado WHEN 'D' THEN g.valor::text ELSE '0' END,
           'creditMinor', CASE g.lado WHEN 'C' THEN g.valor::text ELSE '0' END,
           'description', v_rotulo)
           ORDER BY g.lado DESC, g.conta, g.dimensao), '[]'::jsonb),
         COALESCE(sum(g.valor) FILTER (WHERE g.lado = 'D'), 0),
         COALESCE(sum(g.valor) FILTER (WHERE g.lado = 'C'), 0)
    INTO v_entries, v_d, v_c
    FROM (SELECT l->>'lado' AS lado, l->>'conta' AS conta, l->>'dimensao' AS dimensao, sum((l->>'valor')::bigint) AS valor
            FROM jsonb_array_elements(p_linhas) AS l
           GROUP BY 1, 2, 3) g;

  IF v_d <> v_c THEN
    RAISE EXCEPTION 'Contabilização: o lote % de % não fecha (débito % / crédito %); nada foi gravado', p_evento, to_char(p_competencia, 'MM/YYYY'), v_d, v_c;
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(g) ORDER BY g.origem_papel, g.origem_chave, g.lado DESC, g.conta, g.dimensao), '[]'::jsonb)
    INTO v_comp
    FROM (SELECT l->>'origem_chave' AS origem_chave, l->>'origem_papel' AS origem_papel,
                 l->>'chave' AS chave, l->>'papel' AS papel, l->>'conta' AS conta, l->>'natureza' AS natureza,
                 l->>'lado' AS lado, l->>'dimensao' AS dimensao, l->>'grupo' AS grupo,
                 sum((l->>'valor')::bigint) AS valor
            FROM jsonb_array_elements(p_linhas) AS l
           GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9) g;

  RETURN jsonb_build_object(
    'evento_tipo', p_evento, 'employer_id', p_employer, 'run_id', p_run_id, 'competencia', p_competencia,
    'data_lancamento', p_data, 'dimensao', p_dimensao, 'entries', v_entries, 'composicao', v_comp,
    'total', v_d, 'movimentos', COALESCE(p_movimentos, '[]'::jsonb),
    'pendencias', to_jsonb(COALESCE(p_pendencias, ARRAY[]::text[])));
END
$function$;

-- 6.6 Evento no contrato gestao.folha-handoff.v2. A chave do envio é determinística.
CREATE FUNCTION folha.contabil_envelope(
  p_conta uuid, p_lote jsonb, p_versao integer, p_reverses text, p_evidence jsonb, p_entries jsonb DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  v_entries jsonb := COALESCE(p_entries, p_lote->'entries');
  v_payload jsonb;
  v_d numeric;
  v_c numeric;
BEGIN
  SELECT COALESCE(sum((e->>'debitMinor')::numeric), 0), COALESCE(sum((e->>'creditMinor')::numeric), 0)
    INTO v_d, v_c
    FROM jsonb_array_elements(v_entries) AS e;
  v_payload := jsonb_build_object(
    'contractVersion', 'gestao.folha-handoff.v2',
    'handoffKey', 'h-' || left(encode(sha256(convert_to(
        p_conta::text || '|' || (p_lote->>'employer_id') || '|' || COALESCE(p_lote->>'run_id', '') || '|' || (p_lote->>'competencia')
        || '|' || (p_lote->>'evento_tipo') || '|' || p_versao::text || '|' || COALESCE(p_reverses, '')
        || '|' || COALESCE(p_evidence->>'reference', ''), 'UTF8')), 'hex'), 40),
    'accountId', p_conta::text,
    'employerId', p_lote->>'employer_id',
    'payrollRunId', p_lote->'run_id',
    'competence', to_char((p_lote->>'competencia')::date, 'YYYY-MM'),
    'eventType', p_lote->>'evento_tipo',
    'entryDate', to_char((p_lote->>'data_lancamento')::date, 'YYYY-MM-DD'),
    'version', p_versao,
    'reverses', to_jsonb(p_reverses),
    'dimensionType', p_lote->>'dimensao',
    'totals', jsonb_build_object('debitMinor', v_d::text, 'creditMinor', v_c::text),
    'entries', v_entries,
    'evidence', COALESCE(p_evidence, 'null'::jsonb),
    'emittedAt', to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'source', jsonb_build_object('repository', 'pompiliodonatoapp/dnex-folha'));
  RETURN v_payload || jsonb_build_object('payloadHash', folha.contabil_payload_hash(v_payload));
END
$function$;

-- 6.7 Estado da folha para contabilizar. Regra V5 (aqui mais estreita que a do parecer, que
--     aceitava folha aprovada): só folha FECHADA, e sem pendência aberta.
CREATE FUNCTION folha.contabil_folha_conferir_estado(p_conta uuid, p_run_id uuid) RETURNS void
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_status text;
  v_n integer;
BEGIN
  SELECT r.status INTO v_status
    FROM folha.payroll_run r
   WHERE r.run_id = p_run_id AND r.account_id = p_conta;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Folha % não encontrada', p_run_id;
  END IF;
  IF v_status <> 'closed' THEN
    RAISE EXCEPTION 'Folha % está em % e não pode ser contabilizada: só folha fechada', p_run_id, v_status;
  END IF;
  SELECT count(*) INTO v_n
    FROM folha.payroll_pendency p
   WHERE p.account_id = p_conta AND p.run_id = p_run_id AND p.liberada_em IS NULL;
  IF v_n > 0 THEN
    RAISE EXCEPTION 'Folha % tem % pendência(s) sem liberação e não pode ser contabilizada', p_run_id, v_n;
  END IF;
END
$function$;

-- 6.8 Monta o lote de uma folha fechada, para um empregador e um evento ('pro_labore' reúne
--     os resultados de contribuinte individual; o evento do tipo de processo reúne os demais).
--     Não grava.
CREATE FUNCTION folha.contabil_folha_montar(
  p_conta uuid, p_run_id uuid, p_employer uuid, p_evento text, p_ignorar_outbox bigint
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_run record;
  v_cfg record;
  v_r record;
  v_l record;
  v_employer uuid := p_employer;
  v_n integer;
  v_data date;
  v_prov_enc text;
  v_brutas jsonb;
  v_linhas jsonb;
  v_final jsonb := '[]'::jsonb;
  v_extras jsonb := '[]'::jsonb;
  v_movs jsonb := '[]'::jsonb;
  v_saldos jsonb := '{}'::jsonb;
  v_pend text[] := ARRAY[]::text[];
  v_chave text;
  v_resto bigint;
  v_usa bigint;
  v_n_extra integer := 1000000;
  v_b record;
  v_tem_sobra_encargos boolean := false;
BEGIN
  SELECT r.run_id, r.status, r.competencia, r.tipo_processo, r.employer_id, r.data_pagamento
    INTO v_run
    FROM folha.payroll_run r
   WHERE r.run_id = p_run_id AND r.account_id = p_conta;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Folha % não encontrada', p_run_id;
  END IF;
  PERFORM folha.contabil_folha_conferir_estado(p_conta, p_run_id);
  IF p_employer IS NULL OR (v_run.employer_id IS NOT NULL AND v_run.employer_id <> p_employer) THEN
    RAISE EXCEPTION 'Folha %: empregador % não é o da folha', p_run_id, p_employer;
  END IF;

  SELECT count(*) INTO v_n
    FROM folha.payroll_result pr
    JOIN folha.employment_contract c ON c.account_id = pr.account_id AND c.contract_id = pr.contract_id
   WHERE pr.account_id = p_conta AND pr.run_id = p_run_id AND c.employer_id = p_employer
     AND (c.regime_trabalho = 'contribuinte_individual') = (p_evento = 'pro_labore');
  IF v_n = 0 THEN
    RETURN NULL;   -- o recálculo tirou do empregador todos os resultados deste evento
  END IF;

  SELECT g.dimensao, g.estorno_data, g.provisao_encargos INTO v_cfg
    FROM folha.contabil_config g
   WHERE g.account_id = p_conta AND g.employer_id = v_employer;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'FC001',
      MESSAGE = 'Contabilização bloqueada: o empregador não tem configuração contábil (dimensão e data do estorno)',
      DETAIL = jsonb_build_object('codigo', 'configuracao_ausente', 'evento_tipo', p_evento, 'employer_id', v_employer,
                                  'run_id', p_run_id, 'competencia', v_run.competencia, 'itens', '[]'::jsonb)::text;
  END IF;

  -- Conferências por resultado, antes de qualquer linha.
  FOR v_r IN
    SELECT pr.result_id, pr.contract_id, pr.total_proventos, pr.total_descontos, pr.liquido, pr.fgts,
           COALESCE(pr.inss_patronal, 0) AS inss_patronal, COALESCE(pr.rat, 0) AS rat, COALESCE(pr.terceiros, 0) AS terceiros,
           i.n_itens, i.proventos, i.descontos, i.fgts_itens, t.patronal_t, t.rat_t, t.terceiros_t
      FROM folha.payroll_result pr
      JOIN folha.employment_contract c ON c.account_id = pr.account_id AND c.contract_id = pr.contract_id
      CROSS JOIN LATERAL (
        SELECT count(*) AS n_itens,
               COALESCE(sum(x.valor) FILTER (WHERE x.tipo_rubrica = 'provento'), 0) AS proventos,
               COALESCE(sum(x.valor) FILTER (WHERE x.tipo_rubrica = 'desconto'), 0) AS descontos,
               COALESCE(sum(x.valor) FILTER (WHERE x.rubrica_codigo = 'FGTS_DEPOSITO'), 0) AS fgts_itens
          FROM folha.payroll_result_item x
         WHERE x.account_id = pr.account_id AND x.result_id = pr.result_id) i
      CROSS JOIN LATERAL (
        SELECT COALESCE(sum(y.valor) FILTER (WHERE y.rubrica_code = 'INSS_PATRONAL'), 0) AS patronal_t,
               COALESCE(sum(y.valor) FILTER (WHERE y.rubrica_code = 'RAT_SAT'), 0) AS rat_t,
               COALESCE(sum(y.valor) FILTER (WHERE y.rubrica_code = 'TERCEIROS'), 0) AS terceiros_t
          FROM folha.calculation_trace y
         WHERE y.account_id = pr.account_id AND y.result_id = pr.result_id AND y.tipo = 'encargo') t
     WHERE pr.account_id = p_conta AND pr.run_id = p_run_id AND c.employer_id = p_employer
       AND (c.regime_trabalho = 'contribuinte_individual') = (p_evento = 'pro_labore')
     ORDER BY pr.contract_id
  LOOP
    IF v_r.n_itens = 0 THEN
      -- Folha calculada antes da migration 0027: não há item por rubrica para mapear. Não é erro
      -- de quem chama nem se resolve com cadastro: fica como bloqueio, à vista.
      RAISE EXCEPTION USING ERRCODE = 'FC001',
        MESSAGE = 'Contabilização bloqueada: resultado sem itens por rubrica (cálculo anterior à migration 0027)',
        DETAIL = jsonb_build_object('codigo', 'resultado_sem_itens', 'evento_tipo', p_evento, 'employer_id', v_employer,
                                    'run_id', p_run_id, 'competencia', v_run.competencia,
                                    'itens', jsonb_build_object('resultado', v_r.result_id))::text;
    END IF;
    -- Regra V4: o líquido contabilizado vem da soma dos itens e tem de ser o gravado.
    IF v_r.proventos - v_r.descontos IS DISTINCT FROM v_r.liquido
       OR v_r.proventos IS DISTINCT FROM v_r.total_proventos
       OR v_r.descontos IS DISTINCT FROM v_r.total_descontos THEN
      RAISE EXCEPTION 'Resultado % com líquido inconsistente: proventos % menos descontos % dos itens não reproduzem o líquido gravado % (totais gravados % e %)',
        v_r.result_id, v_r.proventos, v_r.descontos, v_r.liquido, v_r.total_proventos, v_r.total_descontos;
    END IF;
    -- Regra V10: líquido negativo exige decisão de pessoa.
    IF v_r.liquido < 0 THEN
      RAISE EXCEPTION 'Resultado % com líquido negativo (%): o saldo devedor do trabalhador exige decisão e não é contabilizado', v_r.result_id, v_r.liquido;
    END IF;
    IF v_r.fgts_itens IS DISTINCT FROM v_r.fgts
       OR ROW(v_r.patronal_t, v_r.rat_t, v_r.terceiros_t) IS DISTINCT FROM ROW(v_r.inss_patronal, v_r.rat, v_r.terceiros) THEN
      RAISE EXCEPTION 'Resultado %: os encargos dos itens e da memória de cálculo (FGTS %, patronal %, RAT %, terceiros %) não reproduzem os gravados no resultado (%, %, %, %)',
        v_r.result_id, v_r.fgts_itens, v_r.patronal_t, v_r.rat_t, v_r.terceiros_t, v_r.fgts, v_r.inss_patronal, v_r.rat, v_r.terceiros;
    END IF;
  END LOOP;

  -- Linhas brutas, em centavos (regra V14: o item já está arredondado por trabalhador e rubrica).
  SELECT jsonb_agg(jsonb_build_object('n', b.n, 'contract_id', b.contract_id, 'chave', b.chave, 'papel', b.papel,
                                      'valor', b.valor, 'lotacao_id', b.lotacao_id) ORDER BY b.n)
    INTO v_brutas
    FROM (
      SELECT row_number() OVER (ORDER BY s.contract_id, s.grupo, s.ordem, s.papel) AS n, s.*
        FROM (
          -- proventos e descontos, por rubrica
          SELECT pr.contract_id, 1 AS grupo, i.ordem AS ordem, i.rubrica_codigo AS chave, i.tipo_rubrica AS papel,
                 round(i.valor * 100)::bigint AS valor, NULL::uuid AS lotacao_id
            FROM folha.payroll_result pr
            JOIN folha.employment_contract c ON c.account_id = pr.account_id AND c.contract_id = pr.contract_id
            JOIN folha.payroll_result_item i ON i.account_id = pr.account_id AND i.result_id = pr.result_id
           WHERE pr.account_id = p_conta AND pr.run_id = p_run_id AND c.employer_id = p_employer
             AND (c.regime_trabalho = 'contribuinte_individual') = (p_evento = 'pro_labore')
             AND i.tipo_rubrica IN ('provento', 'desconto')
          UNION ALL
          -- líquido
          SELECT pr.contract_id, 2, 0, 'LIQUIDO', 'liquido', round(pr.liquido * 100)::bigint, NULL::uuid
            FROM folha.payroll_result pr
            JOIN folha.employment_contract c ON c.account_id = pr.account_id AND c.contract_id = pr.contract_id
           WHERE pr.account_id = p_conta AND pr.run_id = p_run_id AND c.employer_id = p_employer
             AND (c.regime_trabalho = 'contribuinte_individual') = (p_evento = 'pro_labore')
          UNION ALL
          -- FGTS do mês e multa rescisória: itens informativos, fora do líquido (E12)
          SELECT pr.contract_id, 3, i.ordem, i.rubrica_codigo, pp.papel, round(i.valor * 100)::bigint, NULL::uuid
            FROM folha.payroll_result pr
            JOIN folha.employment_contract c ON c.account_id = pr.account_id AND c.contract_id = pr.contract_id
            JOIN folha.payroll_result_item i ON i.account_id = pr.account_id AND i.result_id = pr.result_id
            CROSS JOIN (VALUES ('encargo_despesa'), ('encargo_passivo')) AS pp(papel)
           WHERE pr.account_id = p_conta AND pr.run_id = p_run_id AND c.employer_id = p_employer
             AND (c.regime_trabalho = 'contribuinte_individual') = (p_evento = 'pro_labore')
             AND i.rubrica_codigo IN ('FGTS_DEPOSITO', 'FGTS_MULTA_RESCISORIA')
          UNION ALL
          -- encargos previdenciários patronais, por lotação (memória de cálculo)
          SELECT pr.contract_id, 4, t.step_order, t.rubrica_code, pp.papel, round(t.valor * 100)::bigint,
                 (t.detail_json->>'lotacao_id')::uuid
            FROM folha.payroll_result pr
            JOIN folha.employment_contract c ON c.account_id = pr.account_id AND c.contract_id = pr.contract_id
            JOIN folha.calculation_trace t ON t.account_id = pr.account_id AND t.result_id = pr.result_id
            CROSS JOIN (VALUES ('encargo_despesa'), ('encargo_passivo')) AS pp(papel)
           WHERE pr.account_id = p_conta AND pr.run_id = p_run_id AND c.employer_id = p_employer
             AND (c.regime_trabalho = 'contribuinte_individual') = (p_evento = 'pro_labore')
             AND t.tipo = 'encargo' AND t.rubrica_code IN ('INSS_PATRONAL', 'RAT_SAT', 'TERCEIROS')
        ) s
       WHERE s.valor > 0
    ) b;
  IF v_brutas IS NULL THEN
    RETURN NULL;   -- folha só com valores zerados: não há o que lançar
  END IF;

  v_linhas := folha.contabil_linhas_resolver(p_conta, v_employer, v_run.competencia, v_cfg.dimensao, p_evento, p_run_id, v_brutas);

  -- Encargos efetivos de folha de férias e de 13º utilizam a provisão de encargos (parecer 2.5).
  v_prov_enc := CASE v_run.tipo_processo
                  WHEN 'ferias' THEN 'ferias'
                  WHEN 'decimo_terceiro_1' THEN 'decimo_terceiro'
                  WHEN 'decimo_terceiro_2' THEN 'decimo_terceiro'
                END;

  -- Utilização de provisão, limitada ao saldo do trabalhador (regra V11): a parte coberta
  -- debita a provisão; o excedente fica na conta do mapeamento.
  FOR v_l IN
    SELECT x.linha,
           (x.linha->>'contract_id')::uuid AS contract_id,
           (x.linha->>'valor')::bigint AS valor,
           CASE WHEN (x.linha->>'baixa_provisao') IS NOT NULL THEN x.linha->>'baixa_provisao'
                WHEN (x.linha->>'papel') = 'encargo_despesa' THEN v_prov_enc END AS bx_provisao,
           CASE WHEN (x.linha->>'baixa_provisao') IS NOT NULL THEN x.linha->>'baixa_componente'
                WHEN (x.linha->>'papel') = 'encargo_despesa' AND v_prov_enc IS NOT NULL
                  THEN CASE WHEN (x.linha->>'chave') IN ('FGTS_DEPOSITO', 'FGTS_MULTA_RESCISORIA') THEN 'fgts' ELSE 'encargos' END
           END AS bx_componente
      FROM jsonb_array_elements(v_linhas) WITH ORDINALITY AS x(linha, ord)
     ORDER BY x.ord
  LOOP
    IF v_l.bx_provisao IS NULL OR (v_l.linha->>'chave') = 'FGTS_MULTA_RESCISORIA' THEN
      v_final := v_final || v_l.linha;
      CONTINUE;
    END IF;
    v_chave := v_l.contract_id::text || '|' || v_l.bx_provisao || '|' || v_l.bx_componente;
    IF NOT (v_saldos ? v_chave) THEN
      v_saldos := v_saldos || jsonb_build_object(v_chave,
        folha.contabil_provisao_saldo(p_conta, v_l.contract_id, v_l.bx_provisao, v_l.bx_componente, v_run.competencia, p_ignorar_outbox));
    END IF;
    v_resto := (v_saldos->>v_chave)::bigint;
    v_usa := LEAST(v_l.valor, GREATEST(v_resto, 0));
    IF v_usa > 0 THEN
      v_n_extra := v_n_extra + 1;
      v_extras := v_extras || jsonb_build_object(
        'n', v_n_extra, 'contract_id', v_l.contract_id, 'lotacao_id', v_l.linha->'lotacao_id',
        'chave', folha.contabil_chave_provisao(v_l.bx_provisao, v_l.bx_componente), 'papel', 'provisao_passivo',
        'inverte', true, 'valor', v_usa,
        'origem_chave', v_l.linha->>'origem_chave', 'origem_papel', v_l.linha->>'origem_papel');
      v_movs := v_movs || jsonb_build_object(
        'contract_id', v_l.contract_id, 'provisao', v_l.bx_provisao, 'componente', v_l.bx_componente,
        'tipo', 'baixa_pagamento', 'valor', -v_usa,
        'memoria', jsonb_build_object('rubrica', v_l.linha->>'origem_chave', 'valor_do_item', v_l.valor, 'saldo_antes', v_resto));
      v_saldos := v_saldos || jsonb_build_object(v_chave, v_resto - v_usa);
    END IF;
    IF v_l.valor - v_usa > 0 THEN
      v_final := v_final || (v_l.linha || jsonb_build_object('valor', v_l.valor - v_usa));
    END IF;
  END LOOP;

  -- Rescisão: o saldo de provisão que sobrou do trabalhador desligado é estornado contra o
  -- resultado (parecer 2.8). A baixa da provisão de ENCARGOS pelos encargos efetivos da
  -- rescisão está a validar (GC-06b): o saldo dessas provisões entra no mesmo estorno.
  IF v_run.tipo_processo = 'rescisao' THEN
    FOR v_b IN
      SELECT DISTINCT pr.contract_id, p.provisao, k.componente
        FROM folha.payroll_result pr
        JOIN folha.employment_contract c ON c.account_id = pr.account_id AND c.contract_id = pr.contract_id
        CROSS JOIN (VALUES ('decimo_terceiro'), ('ferias')) AS p(provisao)
        CROSS JOIN (VALUES ('principal'), ('encargos'), ('fgts')) AS k(componente)
       WHERE pr.account_id = p_conta AND pr.run_id = p_run_id AND c.employer_id = p_employer
         AND (c.regime_trabalho = 'contribuinte_individual') = (p_evento = 'pro_labore')
       ORDER BY 1, 2, 3
    LOOP
      v_chave := v_b.contract_id::text || '|' || v_b.provisao || '|' || v_b.componente;
      IF v_saldos ? v_chave THEN
        v_resto := (v_saldos->>v_chave)::bigint;
      ELSE
        v_resto := folha.contabil_provisao_saldo(p_conta, v_b.contract_id, v_b.provisao, v_b.componente, v_run.competencia, p_ignorar_outbox);
      END IF;
      IF v_resto < 0 THEN
        RAISE EXCEPTION 'Contrato %: saldo de provisão negativo (% / %: %); corrija o razão antes de contabilizar a rescisão',
          v_b.contract_id, v_b.provisao, v_b.componente, v_resto;
      END IF;
      IF v_resto > 0 THEN
        v_chave := folha.contabil_chave_provisao(v_b.provisao, v_b.componente);
        v_n_extra := v_n_extra + 2;
        v_extras := v_extras
          || jsonb_build_object('n', v_n_extra - 1, 'contract_id', v_b.contract_id, 'chave', v_chave, 'papel', 'provisao_passivo',
                                'inverte', true, 'valor', v_resto, 'origem_chave', v_chave, 'origem_papel', 'provisao_estorno')
          || jsonb_build_object('n', v_n_extra, 'contract_id', v_b.contract_id, 'chave', v_chave, 'papel', 'provisao_reversao',
                                'valor', v_resto, 'origem_chave', v_chave, 'origem_papel', 'provisao_estorno');
        v_movs := v_movs || jsonb_build_object(
          'contract_id', v_b.contract_id, 'provisao', v_b.provisao, 'componente', v_b.componente,
          'tipo', 'estorno_rescisao', 'valor', -v_resto, 'memoria', jsonb_build_object('saldo_estornado', v_resto));
        IF v_b.componente <> 'principal' THEN
          v_tem_sobra_encargos := true;
        END IF;
      END IF;
    END LOOP;
    IF v_tem_sobra_encargos THEN
      IF folha.get_param('contabil_rescisao_baixa_provisao_encargos', v_run.competencia) <> 0 THEN
        RAISE EXCEPTION 'Parâmetro contabil_rescisao_baixa_provisao_encargos diferente de 0: a baixa da provisão de encargos na rescisão não está implementada';
      END IF;
      v_pend := v_pend || folha.params_a_validar(ARRAY['contabil_rescisao_baixa_provisao_encargos'], v_run.competencia);
    END IF;
  END IF;

  IF jsonb_array_length(v_extras) > 0 THEN
    v_final := v_final || folha.contabil_linhas_resolver(p_conta, v_employer, v_run.competencia, v_cfg.dimensao, p_evento, p_run_id, v_extras);
  END IF;

  -- Data do lançamento (regra V13): último dia da competência; o adiantamento é lançado na
  -- data em que é pago (parecer 2.3).
  v_data := CASE WHEN v_run.tipo_processo = 'adiantamento' THEN v_run.data_pagamento
                 ELSE (date_trunc('month', v_run.competencia::timestamp) + interval '1 month' - interval '1 day')::date END;

  RETURN folha.contabil_lote_compor(v_employer, p_run_id, v_run.competencia, p_evento, v_data, v_cfg.dimensao, v_final, v_movs, v_pend)
         || jsonb_build_object('estorno_data', v_cfg.estorno_data);
END
$function$;

-- 6.9 Monta o lote de constituição de provisão de um empregador e competência. Método do
--     parecer (2.5): provisão do mês = saldo devido na data (avos x remuneração atual) menos
--     saldo já provisionado, por trabalhador. Não grava.
CREATE FUNCTION folha.contabil_provisao_montar(
  p_conta uuid, p_employer uuid, p_competencia date, p_provisao text, p_ignorar_outbox bigint
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_cfg record;
  v_e record;
  v_k record;
  v_evento text := CASE p_provisao WHEN 'ferias' THEN 'provisao_ferias' WHEN 'decimo_terceiro' THEN 'provisao_13o' END;
  v_faltam jsonb;
  v_rem bigint;
  v_ferias bigint;
  v_terco bigint;
  v_devido bigint;
  v_base_enc bigint;
  v_enc bigint;
  v_fgts bigint;
  v_saldo bigint;
  v_delta bigint;
  v_terco_incide boolean;
  v_usou_terco boolean := false;
  v_pend text[] := ARRAY[]::text[];
  v_pend_enc text[];
  v_enc_json jsonb;
  v_brutas jsonb := '[]'::jsonb;
  v_movs jsonb := '[]'::jsonb;
  v_n integer := 0;
  v_chave text;
  v_data date := (date_trunc('month', p_competencia::timestamp) + interval '1 month' - interval '1 day')::date;
  v_linhas jsonb;
  v_ruim text;
BEGIN
  IF v_evento IS NULL THEN
    RAISE EXCEPTION 'Provisão desconhecida: %', p_provisao;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM folha.employer e WHERE e.account_id = p_conta AND e.employer_id = p_employer) THEN
    RAISE EXCEPTION 'Empregador % não encontrado', p_employer;
  END IF;
  SELECT g.dimensao, g.estorno_data, g.provisao_encargos INTO v_cfg
    FROM folha.contabil_config g
   WHERE g.account_id = p_conta AND g.employer_id = p_employer;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'FC001',
      MESSAGE = 'Contabilização bloqueada: o empregador não tem configuração contábil (dimensão e data do estorno)',
      DETAIL = jsonb_build_object('codigo', 'configuracao_ausente', 'evento_tipo', v_evento, 'employer_id', p_employer,
                                  'run_id', NULL, 'competencia', p_competencia, 'itens', '[]'::jsonb)::text;
  END IF;

  -- Todo empregado ou aprendiz com contrato vigente na competência precisa do direito
  -- informado: provisionar só parte do quadro subavaliaria o passivo em silêncio.
  SELECT jsonb_agg(c.contract_id ORDER BY c.contract_id) INTO v_faltam
    FROM folha.employment_contract c
   WHERE c.account_id = p_conta AND c.employer_id = p_employer
     AND c.regime_trabalho IN ('clt', 'aprendiz')
     AND c.data_admissao <= v_data
     AND (c.data_demissao IS NULL OR c.data_demissao >= p_competencia)
     AND NOT EXISTS (SELECT 1 FROM folha.provision_entitlement e
                      WHERE e.account_id = p_conta AND e.contract_id = c.contract_id AND e.competencia = p_competencia);
  IF v_faltam IS NOT NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'FC001',
      MESSAGE = 'Provisão bloqueada: ' || jsonb_array_length(v_faltam)::text || ' contrato(s) vigente(s) sem o direito (remuneração e avos) informado na competência',
      DETAIL = jsonb_build_object('codigo', 'provisao_direito_ausente', 'evento_tipo', v_evento, 'employer_id', p_employer,
                                  'run_id', NULL, 'competencia', p_competencia,
                                  'itens', jsonb_build_object('contratos', v_faltam))::text;
  END IF;

  v_terco_incide := folha.get_param('contabil_provisao_encargos_incide_terco_ferias', p_competencia) = 1;

  FOR v_e IN
    SELECT e.contract_id, e.remuneracao_base, e.avos_13, e.avos_ferias, c.regime_trabalho
      FROM folha.provision_entitlement e
      JOIN folha.employment_contract c ON c.account_id = e.account_id AND c.contract_id = e.contract_id
     WHERE e.account_id = p_conta AND e.employer_id = p_employer AND e.competencia = p_competencia
     ORDER BY e.contract_id
  LOOP
    v_rem := round(v_e.remuneracao_base * 100)::bigint;
    IF p_provisao = 'decimo_terceiro' THEN
      v_devido := round(v_rem * v_e.avos_13 / 12)::bigint;
      v_base_enc := v_devido;
      v_ferias := NULL;  v_terco := NULL;
    ELSE
      v_ferias := round(v_rem * v_e.avos_ferias / 12)::bigint;
      v_terco := round(v_ferias / 3.0)::bigint;
      v_devido := v_ferias + v_terco;
      v_base_enc := CASE WHEN v_terco_incide THEN v_devido ELSE v_ferias END;
    END IF;

    v_enc := NULL;  v_fgts := NULL;
    IF v_cfg.provisao_encargos THEN
      IF v_base_enc > 0 THEN
        SELECT jsonb_agg(to_jsonb(ep)) INTO v_enc_json
          FROM folha.calc_encargos_patronais(v_e.contract_id, p_competencia, v_base_enc / 100.0,
                 CASE WHEN p_provisao = 'decimo_terceiro' THEN v_base_enc / 100.0 ELSE 0 END) ep;
        SELECT COALESCE(sum(round(((x->>'inss_patronal')::numeric + (x->>'rat')::numeric + (x->>'terceiros')::numeric) * 100)), 0)::bigint
          INTO v_enc
          FROM jsonb_array_elements(COALESCE(v_enc_json, '[]'::jsonb)) AS x;
        v_pend_enc := ARRAY(SELECT DISTINCT pd
                              FROM jsonb_array_elements(COALESCE(v_enc_json, '[]'::jsonb)) AS x
                              CROSS JOIN LATERAL jsonb_array_elements_text(x->'pendencias') AS pd);
        v_pend := v_pend || COALESCE(v_pend_enc, ARRAY[]::text[]);
        SELECT round(f.fgts_deposito * 100)::bigint INTO v_fgts
          FROM folha.calc_fgts(v_base_enc / 100.0, v_e.regime_trabalho, p_competencia) f;
        IF p_provisao = 'ferias' AND v_terco > 0 THEN
          v_usou_terco := true;
        END IF;
      ELSE
        v_enc := 0;  v_fgts := 0;
      END IF;
    END IF;

    FOR v_k IN
      SELECT * FROM (VALUES ('principal', v_devido), ('encargos', v_enc), ('fgts', v_fgts)) AS t(componente, devido)
       WHERE t.devido IS NOT NULL
    LOOP
      v_saldo := folha.contabil_provisao_saldo(p_conta, v_e.contract_id, p_provisao, v_k.componente, p_competencia, p_ignorar_outbox);
      v_delta := v_k.devido - v_saldo;
      IF v_delta = 0 THEN
        CONTINUE;
      END IF;
      v_chave := folha.contabil_chave_provisao(p_provisao, v_k.componente);
      v_n := v_n + 2;
      -- Valor negativo não existe (regra V2): quando o saldo devido cai, inverte-se o lado.
      v_brutas := v_brutas
        || jsonb_build_object('n', v_n - 1, 'contract_id', v_e.contract_id, 'chave', v_chave, 'papel', 'provisao_despesa',
                              'valor', abs(v_delta), 'inverte', v_delta < 0)
        || jsonb_build_object('n', v_n, 'contract_id', v_e.contract_id, 'chave', v_chave, 'papel', 'provisao_passivo',
                              'valor', abs(v_delta), 'inverte', v_delta < 0);
      v_movs := v_movs || jsonb_build_object(
        'contract_id', v_e.contract_id, 'provisao', p_provisao, 'componente', v_k.componente,
        'tipo', CASE WHEN v_delta > 0 THEN 'constituicao' ELSE 'reducao' END, 'valor', v_delta,
        'memoria', jsonb_build_object('remuneracao_minor', v_rem,
                                      'avos', CASE WHEN p_provisao = 'decimo_terceiro' THEN v_e.avos_13 ELSE v_e.avos_ferias END,
                                      'ferias_minor', v_ferias, 'terco_minor', v_terco, 'base_encargos_minor', v_base_enc,
                                      'saldo_devido_minor', v_k.devido, 'saldo_anterior_minor', v_saldo));
    END LOOP;
  END LOOP;

  IF v_usou_terco THEN
    v_pend := v_pend || folha.params_a_validar(ARRAY['contabil_provisao_encargos_incide_terco_ferias'], p_competencia);
  END IF;
  v_pend := ARRAY(SELECT DISTINCT p FROM unnest(v_pend) AS p ORDER BY p);
  -- Pendência de cálculo (valor sabidamente errado) vinda dos encargos não é liberável: não
  -- sai lote de provisão sobre ela.
  SELECT string_agg(p, ', ') INTO v_ruim FROM unnest(v_pend) AS p WHERE folha.pendencia_tipo(p) = 'pendencia';
  IF v_ruim IS NOT NULL THEN
    RAISE EXCEPTION 'Provisão não constituída: os encargos devolveram pendência de cálculo não liberável (%)', v_ruim;
  END IF;

  IF jsonb_array_length(v_brutas) = 0 THEN
    RETURN jsonb_build_object('evento_tipo', v_evento, 'employer_id', p_employer, 'run_id', NULL, 'competencia', p_competencia,
                              'data_lancamento', v_data, 'dimensao', v_cfg.dimensao, 'entries', '[]'::jsonb,
                              'composicao', '[]'::jsonb, 'total', 0, 'movimentos', '[]'::jsonb, 'pendencias', '[]'::jsonb,
                              'estorno_data', v_cfg.estorno_data);
  END IF;
  v_linhas := folha.contabil_linhas_resolver(p_conta, p_employer, p_competencia, v_cfg.dimensao, v_evento, NULL, v_brutas);
  RETURN folha.contabil_lote_compor(p_employer, NULL, p_competencia, v_evento, v_data, v_cfg.dimensao, v_linhas, v_movs, v_pend)
         || jsonb_build_object('estorno_data', v_cfg.estorno_data);
END
$function$;

-- 6.10 Desfaz no razão os movimentos de um lote que deixa de valer.
CREATE FUNCTION folha.contabil_razao_reverter(p_conta uuid, p_subject uuid, p_lote_antigo bigint, p_lote_origem bigint)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_n integer;
BEGIN
  INSERT INTO folha.provision_ledger (account_id, employer_id, contract_id, competencia, provisao, componente, tipo,
                                      valor_minor, outbox_id, reverte_movement_id, memoria, criado_por_subject)
  SELECT m.account_id, m.employer_id, m.contract_id, m.competencia, m.provisao, m.componente, 'reversao_de_lote',
         -m.valor_minor, p_lote_origem, m.movement_id, jsonb_build_object('lote_desfeito', p_lote_antigo), p_subject
    FROM folha.provision_ledger m
   WHERE m.account_id = p_conta AND m.outbox_id = p_lote_antigo AND m.tipo <> 'reversao_de_lote'
     AND NOT EXISTS (SELECT 1 FROM folha.provision_ledger r WHERE r.reverte_movement_id = m.movement_id)
   ORDER BY m.movement_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END
$function$;

-- 6.11 Publica um lote montado (regras V6 e V7 do parecer):
--        sem lote vigente                 -> versão 1
--        mesmo conteúdo (resumo igual)    -> nada; devolve o vigente
--        vigente retido ou pendente       -> o vigente é CANCELADO (fica na tabela) e sai a nova versão
--        vigente despachado ou confirmado -> lote de ESTORNO (linhas com os lados trocados,
--                                            referência ao estornado) e depois a nova versão
--        vigente rejeitado                -> nova versão, sem estorno (nada foi lançado)
--      Lote novo sem linhas (o recálculo zerou o evento) só retira o vigente.
CREATE FUNCTION folha.contabil_lote_publicar(p_conta uuid, p_subject uuid, p_lote jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_evento text := p_lote->>'evento_tipo';
  v_run uuid := (p_lote->>'run_id')::uuid;
  v_employer uuid := (p_lote->>'employer_id')::uuid;
  v_comp date := (p_lote->>'competencia')::date;
  v_vazio boolean := jsonb_array_length(p_lote->'entries') = 0;
  v_atual record;
  v_tem_atual boolean;
  v_versao integer;
  v_payload jsonb;
  v_estorno jsonb;
  v_estorno_id bigint;
  v_cancelado_id bigint;
  v_novo_id bigint;
  v_inseridos integer := 0;
  v_pend text[] := ARRAY(SELECT jsonb_array_elements_text(p_lote->'pendencias'));
  v_data_estorno date;
BEGIN
  SELECT o.outbox_id, o.status, o.versao, o.payload_hash, o.payload, o.composicao, o.data_lancamento, o.idempotency_key
    INTO v_atual
    FROM folha.accounting_outbox o
   WHERE o.account_id = p_conta AND o.formato = 'v2' AND o.vigente AND o.evento_tipo = v_evento
     AND o.employer_id = v_employer
     AND ((v_run IS NOT NULL AND o.run_id = v_run)
          OR (v_run IS NULL AND o.run_id IS NULL AND o.competencia = v_comp))
     FOR UPDATE;
  v_tem_atual := FOUND;

  SELECT COALESCE(max(o.versao), 0) + 1 INTO v_versao
    FROM folha.accounting_outbox o
   WHERE o.account_id = p_conta AND o.formato = 'v2' AND o.evento_tipo = v_evento
     AND o.employer_id = v_employer
     AND ((v_run IS NOT NULL AND o.run_id = v_run)
          OR (v_run IS NULL AND o.run_id IS NULL AND o.competencia = v_comp));

  IF NOT v_vazio THEN
    v_payload := folha.contabil_envelope(p_conta, p_lote, v_versao, NULL, NULL);
  END IF;

  IF v_tem_atual THEN
    IF NOT v_vazio AND v_atual.payload_hash = (v_payload->>'payloadHash') AND v_atual.status <> 'rejeitado'
       AND v_atual.composicao IS NOT DISTINCT FROM (p_lote->'composicao') THEN
      RETURN jsonb_build_object('evento_tipo', v_evento, 'situacao', 'inalterado', 'outbox_id', v_atual.outbox_id,
                                'versao', v_atual.versao, 'status', v_atual.status, 'inseridos', 0);
    END IF;
    IF v_run IS NOT NULL AND v_evento IN ('folha_mensal', 'folha_complementar', 'adiantamento_salarial', 'decimo_terceiro', 'ferias', 'rescisao', 'pro_labore')
       AND EXISTS (SELECT 1 FROM folha.accounting_outbox pg
                    WHERE pg.account_id = p_conta AND pg.run_id = v_run AND pg.employer_id = v_employer
                      AND pg.formato = 'v2' AND pg.vigente
                      AND pg.status IN ('retido', 'pendente', 'despachado', 'confirmado')
                      AND pg.evento_tipo IN ('pagamento_liquido', 'recolhimento_previdenciario', 'recolhimento_irrf', 'fgts_deposito', 'repasse_terceiros')) THEN
      RAISE EXCEPTION USING ERRCODE = 'FC001',
        MESSAGE = 'Contabilização bloqueada: a folha já tem pagamento contabilizado; o recálculo mudaria a apropriação e deixaria saldo de passivo negativo',
        DETAIL = jsonb_build_object('codigo', 'pagamento_registrado', 'evento_tipo', v_evento, 'employer_id', v_employer,
                                    'run_id', v_run, 'competencia', v_comp)::text;
    END IF;
    IF v_atual.status IN ('retido', 'pendente') THEN
      UPDATE folha.accounting_outbox o
         SET status = 'cancelado', vigente = false, cancelado_em = now(),
             cancelado_motivo = 'Substituído por recálculo antes do despacho'
       WHERE o.account_id = p_conta AND o.outbox_id = v_atual.outbox_id;
      PERFORM folha.contabil_razao_reverter(p_conta, p_subject, v_atual.outbox_id, v_atual.outbox_id);
      UPDATE folha.contabil_pendencia p
         SET resolvida_em = now()
       WHERE p.account_id = p_conta AND p.outbox_id = v_atual.outbox_id AND p.resolvida_em IS NULL AND p.liberada_em IS NULL;
      v_cancelado_id := v_atual.outbox_id;
    ELSIF v_atual.status IN ('despachado', 'confirmado') THEN
      v_data_estorno := CASE WHEN (p_lote->>'estorno_data') = 'data_do_estorno'
                             THEN (now() AT TIME ZONE 'America/Sao_Paulo')::date
                             ELSE v_atual.data_lancamento END;
      v_estorno := folha.contabil_envelope(
        p_conta,
        jsonb_build_object('evento_tipo', 'estorno', 'employer_id', v_employer, 'run_id', v_run, 'competencia', v_comp,
                           'data_lancamento', v_data_estorno, 'dimensao', v_atual.payload->>'dimensionType'),
        v_atual.versao, v_atual.idempotency_key, NULL,
        (SELECT jsonb_agg(e || jsonb_build_object('debitMinor', e->>'creditMinor', 'creditMinor', e->>'debitMinor',
                                                  'description', 'Estorno: ' || (e->>'description')))
           FROM jsonb_array_elements(v_atual.payload->'entries') AS e));
      INSERT INTO folha.accounting_outbox (
        account_id, run_id, result_id, evento_tipo, payload, status, idempotency_key, formato, employer_id, competencia,
        versao, data_lancamento, payload_hash, total_debito_minor, total_credito_minor, estorna_outbox_id, composicao,
        contabilizado_por_subject)
      VALUES (
        p_conta, v_run, NULL, 'estorno', v_estorno, 'pendente', v_estorno->>'handoffKey', 'v2', v_employer, v_comp,
        v_atual.versao, v_data_estorno, v_estorno->>'payloadHash',
        (v_estorno->'totals'->>'debitMinor')::bigint, (v_estorno->'totals'->>'creditMinor')::bigint, v_atual.outbox_id,
        (SELECT COALESCE(jsonb_agg(c || jsonb_build_object('lado', CASE c->>'lado' WHEN 'D' THEN 'C' ELSE 'D' END)), '[]'::jsonb)
           FROM jsonb_array_elements(v_atual.composicao) AS c),
        p_subject)
      RETURNING outbox_id INTO v_estorno_id;
      v_inseridos := v_inseridos + 1;
      UPDATE folha.accounting_outbox o SET vigente = false
       WHERE o.account_id = p_conta AND o.outbox_id = v_atual.outbox_id;
      PERFORM folha.contabil_razao_reverter(p_conta, p_subject, v_atual.outbox_id, v_estorno_id);
    ELSE   -- rejeitado
      UPDATE folha.accounting_outbox o SET vigente = false
       WHERE o.account_id = p_conta AND o.outbox_id = v_atual.outbox_id;
      PERFORM folha.contabil_razao_reverter(p_conta, p_subject, v_atual.outbox_id, v_atual.outbox_id);
    END IF;
  END IF;

  IF v_vazio THEN
    RETURN jsonb_build_object('evento_tipo', v_evento,
                              'situacao', CASE WHEN v_tem_atual THEN 'retirado' ELSE 'sem_movimento' END,
                              'outbox_id', NULL, 'versao', NULL, 'estorno_outbox_id', v_estorno_id,
                              'cancelou_outbox_id', v_cancelado_id, 'inseridos', v_inseridos);
  END IF;

  INSERT INTO folha.accounting_outbox (
    account_id, run_id, result_id, evento_tipo, payload, status, idempotency_key, formato, employer_id, competencia,
    versao, data_lancamento, payload_hash, total_debito_minor, total_credito_minor, composicao, contabilizado_por_subject)
  VALUES (
    p_conta, v_run, NULL, v_evento, v_payload,
    CASE WHEN cardinality(v_pend) > 0 THEN 'retido' ELSE 'pendente' END,
    v_payload->>'handoffKey', 'v2', v_employer, v_comp, v_versao, (p_lote->>'data_lancamento')::date,
    v_payload->>'payloadHash', (v_payload->'totals'->>'debitMinor')::bigint, (v_payload->'totals'->>'creditMinor')::bigint,
    p_lote->'composicao', p_subject)
  RETURNING outbox_id INTO v_novo_id;
  v_inseridos := v_inseridos + 1;

  INSERT INTO folha.provision_ledger (account_id, employer_id, contract_id, competencia, provisao, componente, tipo,
                                      valor_minor, outbox_id, memoria, criado_por_subject)
  SELECT p_conta, v_employer, (m->>'contract_id')::uuid, v_comp, m->>'provisao', m->>'componente', m->>'tipo',
         (m->>'valor')::bigint, v_novo_id, COALESCE(m->'memoria', '{}'::jsonb), p_subject
    FROM jsonb_array_elements(p_lote->'movimentos') WITH ORDINALITY AS t(m, ord)
   ORDER BY t.ord;

  INSERT INTO folha.contabil_pendencia (account_id, employer_id, run_id, competencia, evento_tipo, codigo, tipo, outbox_id, criada_por_subject)
  SELECT p_conta, v_employer, v_run, v_comp, v_evento, p, 'a_validar', v_novo_id, p_subject
    FROM unnest(v_pend) AS p;

  -- O que estava bloqueado para este lote deixou de estar.
  UPDATE folha.contabil_pendencia p
     SET resolvida_em = now()
   WHERE p.account_id = p_conta AND p.tipo = 'bloqueio' AND p.resolvida_em IS NULL AND p.evento_tipo = v_evento
     AND (p.employer_id = v_employer OR p.employer_id IS NULL)
     AND ((v_run IS NOT NULL AND p.run_id = v_run)
          OR (v_run IS NULL AND p.run_id IS NULL AND p.competencia = v_comp));

  RETURN jsonb_build_object('evento_tipo', v_evento,
                            'situacao', CASE WHEN v_tem_atual THEN 'substituido' ELSE 'contabilizado' END,
                            'outbox_id', v_novo_id, 'versao', v_versao,
                            'status', CASE WHEN cardinality(v_pend) > 0 THEN 'retido' ELSE 'pendente' END,
                            'estorno_outbox_id', v_estorno_id, 'cancelou_outbox_id', v_cancelado_id,
                            'pendencias_a_validar', to_jsonb(v_pend), 'inseridos', v_inseridos);
END
$function$;

-- 6.12 Registra (ou atualiza) a pendência de bloqueio a partir do DETAIL da exceção FC001.
CREATE FUNCTION folha.contabil_bloqueio_registrar(p_conta uuid, p_subject uuid, p_detalhe jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_id uuid;
  v_run uuid := (p_detalhe->>'run_id')::uuid;
  v_employer uuid := (p_detalhe->>'employer_id')::uuid;
  v_comp date := (p_detalhe->>'competencia')::date;
BEGIN
  SELECT p.pendencia_id INTO v_id
    FROM folha.contabil_pendencia p
   WHERE p.account_id = p_conta AND p.tipo = 'bloqueio' AND p.resolvida_em IS NULL
     AND p.run_id IS NOT DISTINCT FROM v_run AND p.employer_id IS NOT DISTINCT FROM v_employer
     AND p.competencia IS NOT DISTINCT FROM v_comp
     AND p.evento_tipo = (p_detalhe->>'evento_tipo') AND p.codigo = (p_detalhe->>'codigo')
     FOR UPDATE;
  IF FOUND THEN
    UPDATE folha.contabil_pendencia p
       SET detalhe = COALESCE(p_detalhe->'itens', '[]'::jsonb)
     WHERE p.pendencia_id = v_id AND p.account_id = p_conta;
  ELSE
    INSERT INTO folha.contabil_pendencia (account_id, employer_id, run_id, competencia, evento_tipo, codigo, tipo, detalhe, criada_por_subject)
    VALUES (p_conta, v_employer, v_run, v_comp, p_detalhe->>'evento_tipo', p_detalhe->>'codigo', 'bloqueio',
            COALESCE(p_detalhe->'itens', '[]'::jsonb), p_subject)
    RETURNING pendencia_id INTO v_id;
  END IF;
  RETURN v_id;
END
$function$;

-- 6.13 Contabiliza uma folha fechada: um lote por empregador e evento presentes na folha. Tudo
--      ou nada: o bloqueio de um lote desfaz os outros e vira pendência; devolve a situação.
CREATE FUNCTION folha.contabil_folha_executar(p_conta uuid, p_subject uuid, p_run_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_run record;
  v_par record;
  v_lote jsonb;
  v_res jsonb;
  v_lotes jsonb := '[]'::jsonb;
  v_pares jsonb := '[]'::jsonb;
  v_inseridos integer := 0;
  v_sem_emp jsonb;
  v_detalhe text;
  v_mensagem text;
  v_pend_id uuid;
BEGIN
  -- Chamadas simultâneas para a mesma folha ficam em fila.
  PERFORM pg_advisory_xact_lock(hashtextextended('folha.contabil:' || p_run_id::text, 0));
  SELECT r.run_id, r.tipo_processo, r.competencia INTO v_run
    FROM folha.payroll_run r
   WHERE r.run_id = p_run_id AND r.account_id = p_conta;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Folha % não encontrada', p_run_id;
  END IF;
  PERFORM folha.contabil_folha_conferir_estado(p_conta, p_run_id);
  IF NOT EXISTS (SELECT 1 FROM folha.payroll_result pr WHERE pr.account_id = p_conta AND pr.run_id = p_run_id) THEN
    RAISE EXCEPTION 'Folha % não tem resultado calculado', p_run_id;
  END IF;

  BEGIN
    -- O mapeamento é por empregador: contrato sem empregador cadastrado não tem como ser contabilizado.
    SELECT jsonb_agg(pr.contract_id ORDER BY pr.contract_id) INTO v_sem_emp
      FROM folha.payroll_result pr
      JOIN folha.employment_contract c ON c.account_id = pr.account_id AND c.contract_id = pr.contract_id
     WHERE pr.account_id = p_conta AND pr.run_id = p_run_id AND c.employer_id IS NULL;
    IF v_sem_emp IS NOT NULL THEN
      RAISE EXCEPTION USING ERRCODE = 'FC001',
        MESSAGE = 'Contabilização bloqueada: ' || jsonb_array_length(v_sem_emp)::text || ' contrato(s) da folha sem empregador cadastrado',
        DETAIL = jsonb_build_object('codigo', 'contrato_sem_empregador',
                                    'evento_tipo', folha.contabil_evento_da_folha(v_run.tipo_processo), 'employer_id', NULL,
                                    'run_id', p_run_id, 'competencia', v_run.competencia,
                                    'itens', jsonb_build_object('contratos', v_sem_emp))::text;
    END IF;

    -- A baixa de provisão lê o razão: a constituição de provisão do mesmo empregador fica em
    -- fila (mesma trava de contabil_provisao_constituir_v1), sempre depois da trava da folha.
    PERFORM pg_advisory_xact_lock(hashtextextended('folha.contabil.provisao:' || x.employer_id::text, 0))
       FROM (SELECT DISTINCT c.employer_id
               FROM folha.payroll_result pr
               JOIN folha.employment_contract c ON c.account_id = pr.account_id AND c.contract_id = pr.contract_id
              WHERE pr.account_id = p_conta AND pr.run_id = p_run_id
              ORDER BY 1) x;

    FOR v_par IN
      SELECT DISTINCT c.employer_id,
             CASE WHEN c.regime_trabalho = 'contribuinte_individual' THEN 'pro_labore'
                  ELSE folha.contabil_evento_da_folha(v_run.tipo_processo) END AS evento
        FROM folha.payroll_result pr
        JOIN folha.employment_contract c ON c.account_id = pr.account_id AND c.contract_id = pr.contract_id
       WHERE pr.account_id = p_conta AND pr.run_id = p_run_id
       ORDER BY 1, 2
    LOOP
      v_pares := v_pares || jsonb_build_object('e', v_par.employer_id, 'v', v_par.evento);
      v_lote := folha.contabil_folha_montar(
        p_conta, p_run_id, v_par.employer_id, v_par.evento,
        (SELECT o.outbox_id FROM folha.accounting_outbox o
          WHERE o.account_id = p_conta AND o.run_id = p_run_id AND o.employer_id = v_par.employer_id
            AND o.evento_tipo = v_par.evento AND o.formato = 'v2' AND o.vigente));
      IF v_lote IS NULL THEN
        -- folha só com valores zerados para este empregador e evento: retira o lote vigente, se houver
        v_lote := jsonb_build_object('evento_tipo', v_par.evento, 'run_id', p_run_id, 'competencia', v_run.competencia,
                                     'employer_id', v_par.employer_id, 'entries', '[]'::jsonb, 'pendencias', '[]'::jsonb,
                                     'movimentos', '[]'::jsonb,
                                     'estorno_data', (SELECT g.estorno_data FROM folha.contabil_config g
                                                       WHERE g.account_id = p_conta AND g.employer_id = v_par.employer_id));
      END IF;
      v_res := folha.contabil_lote_publicar(p_conta, p_subject, v_lote);
      v_lotes := v_lotes || v_res;
      v_inseridos := v_inseridos + (v_res->>'inseridos')::integer;
    END LOOP;
    -- Lote vigente de empregador ou evento que deixou de existir na folha (o recálculo tirou
    -- todos os resultados dele).
    FOR v_par IN
      SELECT o.evento_tipo AS evento, o.employer_id FROM folha.accounting_outbox o
       WHERE o.account_id = p_conta AND o.run_id = p_run_id AND o.formato = 'v2' AND o.vigente
         AND o.evento_tipo IN ('folha_mensal', 'folha_complementar', 'adiantamento_salarial', 'decimo_terceiro', 'ferias', 'rescisao', 'pro_labore')
         AND NOT (v_pares @> jsonb_build_array(jsonb_build_object('e', o.employer_id, 'v', o.evento_tipo)))
       ORDER BY o.employer_id, o.evento_tipo
    LOOP
      v_res := folha.contabil_lote_publicar(p_conta, p_subject,
        jsonb_build_object('evento_tipo', v_par.evento, 'run_id', p_run_id, 'competencia', v_run.competencia,
                           'employer_id', v_par.employer_id, 'entries', '[]'::jsonb, 'pendencias', '[]'::jsonb,
                           'movimentos', '[]'::jsonb, 'estorno_data',
                           (SELECT g.estorno_data FROM folha.contabil_config g
                             WHERE g.account_id = p_conta AND g.employer_id = v_par.employer_id)));
      v_lotes := v_lotes || v_res;
      v_inseridos := v_inseridos + (v_res->>'inseridos')::integer;
    END LOOP;
  EXCEPTION WHEN SQLSTATE 'FC001' THEN
    GET STACKED DIAGNOSTICS v_detalhe = PG_EXCEPTION_DETAIL, v_mensagem = MESSAGE_TEXT;
    v_pend_id := folha.contabil_bloqueio_registrar(p_conta, p_subject, v_detalhe::jsonb);
    INSERT INTO folha.auditoria (account_id, actor, actor_subject, acao, recurso, recurso_id, detalhe)
    VALUES (p_conta, p_subject::text, p_subject, 'contabilizacao_bloqueada', 'payroll_run', p_run_id,
            jsonb_build_object('sessao', session_user, 'pendencia_id', v_pend_id, 'codigo', v_detalhe::jsonb->>'codigo'));
    RETURN jsonb_build_object('situacao', 'bloqueada', 'lotes', '[]'::jsonb, 'lotes_inseridos', 0,
                              'pendencias', jsonb_build_array(v_detalhe::jsonb || jsonb_build_object('pendencia_id', v_pend_id, 'mensagem', v_mensagem)));
  END;

  INSERT INTO folha.auditoria (account_id, actor, actor_subject, acao, recurso, recurso_id, detalhe)
  VALUES (p_conta, p_subject::text, p_subject, 'contabilizar_folha', 'payroll_run', p_run_id,
          jsonb_build_object('sessao', session_user, 'lotes', v_lotes));
  RETURN jsonb_build_object(
    'situacao', CASE WHEN v_inseridos = 0 AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_lotes) l
                                                          WHERE l->>'situacao' NOT IN ('inalterado', 'sem_movimento'))
                     THEN 'inalterada' ELSE 'contabilizada' END,
    'lotes', v_lotes, 'lotes_inseridos', v_inseridos, 'pendencias', '[]'::jsonb);
END
$function$;

-- 6.14 Saldo dos passivos da folha por empregador, grupo de liquidação e conta: créditos dos
--      lotes de apropriação vigentes menos os débitos dos lotes de pagamento da mesma folha.
CREATE FUNCTION folha.contabil_passivo_saldos(p_conta uuid, p_run_id uuid)
RETURNS TABLE (employer_id uuid, grupo text, conta text, apropriado_minor bigint, pago_minor bigint, saldo_minor bigint)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
  SELECT s.employer_id, s.grupo, s.conta,
         COALESCE(sum(s.valor) FILTER (WHERE s.origem = 'apropriado'), 0)::bigint,
         COALESCE(sum(s.valor) FILTER (WHERE s.origem = 'pago'), 0)::bigint,
         (COALESCE(sum(s.valor) FILTER (WHERE s.origem = 'apropriado'), 0)
          - COALESCE(sum(s.valor) FILTER (WHERE s.origem = 'pago'), 0))::bigint
    FROM (
      SELECT o.employer_id, c->>'grupo' AS grupo, c->>'conta' AS conta, 'apropriado' AS origem, (c->>'valor')::bigint AS valor
        FROM folha.accounting_outbox o
        CROSS JOIN LATERAL jsonb_array_elements(o.composicao) AS c
       WHERE o.account_id = p_conta AND o.run_id = p_run_id AND o.formato = 'v2' AND o.vigente
         AND o.status IN ('pendente', 'despachado', 'confirmado')
         AND o.evento_tipo IN ('folha_mensal', 'folha_complementar', 'adiantamento_salarial', 'decimo_terceiro', 'ferias', 'rescisao', 'pro_labore')
         AND c->>'lado' = 'C' AND c->>'natureza' = 'passivo' AND (c->>'grupo') IS NOT NULL
      UNION ALL
      SELECT o.employer_id, o.evento_tipo, c->>'conta', 'pago', (c->>'valor')::bigint
        FROM folha.accounting_outbox o
        CROSS JOIN LATERAL jsonb_array_elements(o.composicao) AS c
       WHERE o.account_id = p_conta AND o.run_id = p_run_id AND o.formato = 'v2' AND o.vigente
         AND o.status IN ('pendente', 'despachado', 'confirmado')
         AND o.evento_tipo IN ('pagamento_liquido', 'recolhimento_previdenciario', 'recolhimento_irrf', 'fgts_deposito', 'repasse_terceiros')
         AND c->>'lado' = 'D'
    ) s
   GROUP BY s.employer_id, s.grupo, s.conta;
$function$;

-- ===========================================================================
-- 7. Funções das migrations anteriores, substituídas (mesmas assinaturas; CREATE OR REPLACE
--    preserva dono e ACL)
-- ===========================================================================

-- 7.1 build_contabil_folha: o construtor antigo (E1 a E8) dá lugar ao lote v2. Recebe um
--     resultado, como antes, e devolve a PRÉVIA do lote da folha a que ele pertence (o lote é
--     da folha e do empregador do contrato, não do resultado). Não grava. Quando falta cadastro devolve o diagnóstico do
--     bloqueio em vez do evento.
CREATE OR REPLACE FUNCTION folha.build_contabil_folha(
  p_result_id uuid
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_conta uuid;
  v_r record;
  v_evento text;
  v_atual record;
  v_lote jsonb;
  v_detalhe text;
  v_mensagem text;
BEGIN
  SELECT c.account_id INTO v_conta FROM folha.contexto_v1('folha.transmit') AS c;

  SELECT pr.result_id, pr.run_id, k.regime_trabalho, k.employer_id, r.tipo_processo
    INTO v_r
    FROM folha.payroll_result pr
    JOIN folha.payroll_run r ON r.run_id = pr.run_id AND r.account_id = pr.account_id
    JOIN folha.employment_contract k ON k.contract_id = pr.contract_id AND k.account_id = pr.account_id
   WHERE pr.result_id = p_result_id AND pr.account_id = v_conta;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'payroll_result % não encontrado', p_result_id;
  END IF;
  v_evento := CASE WHEN v_r.regime_trabalho = 'contribuinte_individual' THEN 'pro_labore'
                   ELSE folha.contabil_evento_da_folha(v_r.tipo_processo) END;

  IF v_r.employer_id IS NULL THEN
    RETURN jsonb_build_object('result_id', p_result_id, 'run_id', v_r.run_id, 'situacao', 'bloqueado',
                              'mensagem', 'Contrato sem empregador cadastrado',
                              'pendencia', jsonb_build_object('codigo', 'contrato_sem_empregador'));
  END IF;

  SELECT o.outbox_id, o.versao INTO v_atual
    FROM folha.accounting_outbox o
   WHERE o.account_id = v_conta AND o.run_id = v_r.run_id AND o.employer_id = v_r.employer_id
     AND o.evento_tipo = v_evento AND o.formato = 'v2' AND o.vigente;

  BEGIN
    v_lote := folha.contabil_folha_montar(v_conta, v_r.run_id, v_r.employer_id, v_evento, v_atual.outbox_id);
  EXCEPTION WHEN SQLSTATE 'FC001' THEN
    GET STACKED DIAGNOSTICS v_detalhe = PG_EXCEPTION_DETAIL, v_mensagem = MESSAGE_TEXT;
    RETURN jsonb_build_object('result_id', p_result_id, 'run_id', v_r.run_id, 'situacao', 'bloqueado',
                              'mensagem', v_mensagem, 'pendencia', v_detalhe::jsonb);
  END;
  IF v_lote IS NULL THEN
    RETURN jsonb_build_object('result_id', p_result_id, 'run_id', v_r.run_id, 'situacao', 'sem_movimento');
  END IF;
  RETURN jsonb_build_object(
    'result_id', p_result_id, 'run_id', v_r.run_id, 'situacao', 'previa',
    'evento', folha.contabil_envelope(v_conta, v_lote, COALESCE(v_atual.versao, 0) + 1, NULL, NULL),
    'pendencias_a_validar', v_lote->'pendencias');
END
$function$;

-- 7.2 dispatch_accounting_event: gravava no outbox qualquer JSON, por resultado, sem conferir
--     partida (E2, E10). Superada: o lote só nasce pelas funções desta migration. Mantém a
--     assinatura, a permissão e a recusa para resultado de outra conta; depois recusa sempre.
CREATE OR REPLACE FUNCTION folha.dispatch_accounting_event(
  p_run_id uuid,
  p_result_id uuid,
  p_evento_tipo text,
  p_payload jsonb
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_conta uuid;
BEGIN
  SELECT c.account_id INTO v_conta FROM folha.contexto_v1('folha.transmit') AS c;
  IF NOT EXISTS (SELECT 1 FROM folha.payroll_result pr
                  WHERE pr.result_id = p_result_id AND pr.run_id = p_run_id AND pr.account_id = v_conta) THEN
    RAISE EXCEPTION 'payroll_result % não encontrado no run %', p_result_id, p_run_id;
  END IF;
  RAISE EXCEPTION USING ERRCODE = '0A000',
    MESSAGE = 'dispatch_accounting_event foi superada pela migration 0030: o lote contábil é da folha, com partida fechada (use folha.contabil_folha_contabilizar_v1)';
END
$function$;

-- 7.3 dispatch_folha_completa: o eSocial segue como na 0028. A parte contábil deixa de ser um
--     evento por resultado: contabiliza a folha (lotes v2). Sem mapeamento ou configuração a
--     contabilização fica bloqueada, com pendência registrada, e o contador contábil devolve
--     zero; os eventos do eSocial não dependem dela. Outros erros da contabilização (líquido
--     inconsistente, partida que não fecha) abortam o despacho inteiro.
CREATE OR REPLACE FUNCTION folha.dispatch_folha_completa(
  p_run_id uuid
) RETURNS TABLE (
  esocial_events_dispatched integer,
  contabil_events_dispatched integer
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx record;
  v_result record;
  v_esocial_count integer := 0;
  v_contabil_count integer := 0;
  v_contabil jsonb;
  v_competencia date;
  v_status text;
  v_abertas integer;
BEGIN
  SELECT c.account_id, c.legal_entity_id, c.branch_id, c.subject_id INTO v_ctx
    FROM folha.contexto_v1('folha.transmit') AS c;

  SELECT r.competencia, r.status INTO v_competencia, v_status
    FROM folha.payroll_run r
   WHERE r.run_id = p_run_id AND r.account_id = v_ctx.account_id;

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
    SELECT pr.result_id FROM folha.payroll_result pr WHERE pr.run_id = p_run_id AND pr.account_id = v_ctx.account_id
  LOOP
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
  END LOOP;

  -- 0030: conta só os lotes que de fato entraram na fila (inclusive estorno).
  v_contabil := folha.contabil_folha_executar(v_ctx.account_id, v_ctx.subject_id, p_run_id);
  v_contabil_count := (v_contabil->>'lotes_inseridos')::integer;

  INSERT INTO folha.auditoria (account_id, actor, actor_subject, acao, recurso, recurso_id, detalhe)
  VALUES (v_ctx.account_id, v_ctx.subject_id::text, v_ctx.subject_id, 'transmitir_folha', 'payroll_run', p_run_id,
          jsonb_build_object('sessao', session_user, 'esocial', v_esocial_count, 'contabil', v_contabil_count,
                             'contabil_situacao', v_contabil->>'situacao',
                             'legal_entity_id', v_ctx.legal_entity_id, 'branch_id', v_ctx.branch_id));

  esocial_events_dispatched := v_esocial_count;
  contabil_events_dispatched := v_contabil_count;
  RETURN NEXT;
END
$function$;

-- ===========================================================================
-- 8. Funções da sessão de aplicação (EXECUTE só para dnex_gestao_api)
--    Como na 0028: nenhuma recebe conta nem subject; as que gravam conferem a permissão no
--    início e de novo antes de devolver.
-- ===========================================================================

-- 8.1 Configuração contábil do empregador (folha.admin).
CREATE FUNCTION folha.contabil_config_definir_v1(
  p_employer_id uuid, p_dimensao text, p_estorno_data text, p_provisao_encargos boolean
) RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx record;
BEGIN
  SELECT c.account_id, c.legal_entity_id, c.branch_id, c.subject_id INTO v_ctx
    FROM folha.contexto_v1('folha.admin') AS c;
  IF p_dimensao IS NULL OR p_estorno_data IS NULL OR p_provisao_encargos IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'contabil_config_definir_v1: dimensão, data do estorno e provisão de encargos são obrigatórias';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM folha.employer e WHERE e.account_id = v_ctx.account_id AND e.employer_id = p_employer_id) THEN
    RAISE EXCEPTION 'Empregador % não encontrado', p_employer_id;
  END IF;
  INSERT INTO folha.contabil_config AS g (account_id, employer_id, dimensao, estorno_data, provisao_encargos, definido_por_subject, definido_em)
  VALUES (v_ctx.account_id, p_employer_id, p_dimensao, p_estorno_data, p_provisao_encargos, v_ctx.subject_id, now())
  ON CONFLICT (account_id, employer_id) DO UPDATE
    SET dimensao = EXCLUDED.dimensao, estorno_data = EXCLUDED.estorno_data,
        provisao_encargos = EXCLUDED.provisao_encargos,
        definido_por_subject = EXCLUDED.definido_por_subject, definido_em = EXCLUDED.definido_em;
  INSERT INTO folha.auditoria (account_id, actor, actor_subject, acao, recurso, recurso_id, detalhe)
  VALUES (v_ctx.account_id, v_ctx.subject_id::text, v_ctx.subject_id, 'definir_config_contabil', 'employer', p_employer_id,
          jsonb_build_object('dimensao', p_dimensao, 'estorno_data', p_estorno_data, 'provisao_encargos', p_provisao_encargos,
                             'sessao', session_user, 'legal_entity_id', v_ctx.legal_entity_id, 'branch_id', v_ctx.branch_id));
  PERFORM 1 FROM folha.contexto_v1('folha.admin');
END
$function$;

-- 8.2 Linha de mapeamento (folha.admin). p_ativo é obrigatório e sem padrão: ativar é decisão
--     de quem configura.
CREATE FUNCTION folha.contabil_mapa_definir_v1(
  p_employer_id uuid,
  p_chave text,
  p_papel text,
  p_natureza text,
  p_conta_codigo text,
  p_vigencia_inicio date,
  p_ativo boolean,
  p_vigencia_fim date DEFAULT NULL,
  p_regime_trabalho text DEFAULT NULL,
  p_establishment_id uuid DEFAULT NULL,
  p_allocation_id uuid DEFAULT NULL,
  p_centro_custo text DEFAULT NULL,
  p_baixa_provisao text DEFAULT NULL,
  p_grupo_liquidacao text DEFAULT NULL,
  p_evento_tipo text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx record;
  v_id uuid;
BEGIN
  SELECT c.account_id, c.legal_entity_id, c.branch_id, c.subject_id INTO v_ctx
    FROM folha.contexto_v1('folha.admin') AS c;
  IF p_ativo IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'contabil_mapa_definir_v1: informe se a linha nasce ativa (true ou false)';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM folha.employer e WHERE e.account_id = v_ctx.account_id AND e.employer_id = p_employer_id) THEN
    RAISE EXCEPTION 'Empregador % não encontrado', p_employer_id;
  END IF;
  INSERT INTO folha.contabil_mapa (
    account_id, employer_id, establishment_id, allocation_id, centro_custo, regime_trabalho, evento_tipo, chave, papel, natureza,
    conta_codigo, baixa_provisao, grupo_liquidacao, vigencia_inicio, vigencia_fim, ativo, criado_por_subject)
  VALUES (
    v_ctx.account_id, p_employer_id, p_establishment_id, p_allocation_id, p_centro_custo, p_regime_trabalho, p_evento_tipo, p_chave, p_papel,
    p_natureza, p_conta_codigo, p_baixa_provisao, p_grupo_liquidacao, p_vigencia_inicio, p_vigencia_fim, p_ativo, v_ctx.subject_id)
  RETURNING mapa_id INTO v_id;
  INSERT INTO folha.auditoria (account_id, actor, actor_subject, acao, recurso, recurso_id, detalhe)
  VALUES (v_ctx.account_id, v_ctx.subject_id::text, v_ctx.subject_id, 'definir_mapa_contabil', 'contabil_mapa', v_id,
          jsonb_build_object('employer_id', p_employer_id, 'chave', p_chave, 'papel', p_papel, 'natureza', p_natureza,
                             'conta_codigo', p_conta_codigo, 'ativo', p_ativo, 'vigencia_inicio', p_vigencia_inicio,
                             'sessao', session_user, 'legal_entity_id', v_ctx.legal_entity_id, 'branch_id', v_ctx.branch_id));
  PERFORM 1 FROM folha.contexto_v1('folha.admin');
  RETURN v_id;
END
$function$;

-- 8.3 Encerrar a vigência ou mudar o indicador de ativo de uma linha (folha.admin).
CREATE FUNCTION folha.contabil_mapa_encerrar_v1(p_mapa_id uuid, p_vigencia_fim date, p_ativo boolean) RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx record;
BEGIN
  SELECT c.account_id, c.legal_entity_id, c.branch_id, c.subject_id INTO v_ctx
    FROM folha.contexto_v1('folha.admin') AS c;
  IF p_ativo IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'contabil_mapa_encerrar_v1: informe o indicador de ativo';
  END IF;
  UPDATE folha.contabil_mapa m
     SET vigencia_fim = p_vigencia_fim, ativo = p_ativo,
         atualizado_por_subject = v_ctx.subject_id, atualizado_em = now()
   WHERE m.mapa_id = p_mapa_id AND m.account_id = v_ctx.account_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Linha de mapeamento % não encontrada', p_mapa_id;
  END IF;
  INSERT INTO folha.auditoria (account_id, actor, actor_subject, acao, recurso, recurso_id, detalhe)
  VALUES (v_ctx.account_id, v_ctx.subject_id::text, v_ctx.subject_id, 'encerrar_mapa_contabil', 'contabil_mapa', p_mapa_id,
          jsonb_build_object('vigencia_fim', p_vigencia_fim, 'ativo', p_ativo, 'sessao', session_user,
                             'legal_entity_id', v_ctx.legal_entity_id, 'branch_id', v_ctx.branch_id));
  PERFORM 1 FROM folha.contexto_v1('folha.admin');
END
$function$;

-- 8.4 Centro de custo e departamento do contrato, a partir de uma data (folha.admin). Encerra
--     a atribuição vigente na véspera.
CREATE FUNCTION folha.contabil_contrato_dimensao_definir_v1(
  p_contract_id uuid, p_centro_custo text, p_departamento text, p_vigencia_inicio date
) RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx record;
  v_id uuid;
BEGIN
  SELECT c.account_id, c.legal_entity_id, c.branch_id, c.subject_id INTO v_ctx
    FROM folha.contexto_v1('folha.admin') AS c;
  IF p_vigencia_inicio IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'contabil_contrato_dimensao_definir_v1: início da vigência obrigatório';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM folha.employment_contract k WHERE k.account_id = v_ctx.account_id AND k.contract_id = p_contract_id) THEN
    RAISE EXCEPTION 'Contrato % não encontrado', p_contract_id;
  END IF;
  IF EXISTS (SELECT 1 FROM folha.contract_cost_assignment a
              WHERE a.account_id = v_ctx.account_id AND a.contract_id = p_contract_id AND a.vigencia_inicio >= p_vigencia_inicio) THEN
    RAISE EXCEPTION 'Contrato % já tem atribuição com início em % ou depois', p_contract_id, p_vigencia_inicio;
  END IF;
  UPDATE folha.contract_cost_assignment a
     SET vigencia_fim = p_vigencia_inicio - 1
   WHERE a.account_id = v_ctx.account_id AND a.contract_id = p_contract_id
     AND (a.vigencia_fim IS NULL OR a.vigencia_fim >= p_vigencia_inicio);
  INSERT INTO folha.contract_cost_assignment (account_id, contract_id, centro_custo, departamento, vigencia_inicio, definido_por_subject)
  VALUES (v_ctx.account_id, p_contract_id, p_centro_custo, p_departamento, p_vigencia_inicio, v_ctx.subject_id)
  RETURNING assignment_id INTO v_id;
  INSERT INTO folha.auditoria (account_id, actor, actor_subject, acao, recurso, recurso_id, detalhe)
  VALUES (v_ctx.account_id, v_ctx.subject_id::text, v_ctx.subject_id, 'definir_dimensao_contrato', 'employment_contract', p_contract_id,
          jsonb_build_object('centro_custo', p_centro_custo, 'departamento', p_departamento, 'vigencia_inicio', p_vigencia_inicio,
                             'sessao', session_user, 'legal_entity_id', v_ctx.legal_entity_id, 'branch_id', v_ctx.branch_id));
  PERFORM 1 FROM folha.contexto_v1('folha.admin');
  RETURN v_id;
END
$function$;

-- 8.5 Contabilizar a folha (folha.transmit).
CREATE FUNCTION folha.contabil_folha_contabilizar_v1(p_run_id uuid) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx record;
  v_saida jsonb;
BEGIN
  SELECT c.account_id, c.subject_id INTO v_ctx FROM folha.contexto_v1('folha.transmit') AS c;
  v_saida := folha.contabil_folha_executar(v_ctx.account_id, v_ctx.subject_id, p_run_id);
  PERFORM 1 FROM folha.contexto_v1('folha.transmit');
  RETURN v_saida;
END
$function$;

-- 8.6 Informar o direito de provisão do contrato na competência (folha.calculate). Não aceita
--     A mudança é aceita (fica na auditoria): a constituição da competência é refeita pela regra
--     V7 (lote substituído ou estornado) e o método do saldo corrige o estoque nas seguintes.
CREATE FUNCTION folha.contabil_provisao_direito_informar_v1(
  p_contract_id uuid, p_competencia date, p_remuneracao_base numeric, p_avos_13 numeric, p_avos_ferias numeric
) RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx record;
  v_employer uuid;
BEGIN
  SELECT c.account_id, c.legal_entity_id, c.branch_id, c.subject_id INTO v_ctx
    FROM folha.contexto_v1('folha.calculate') AS c;
  SELECT k.employer_id INTO v_employer
    FROM folha.employment_contract k
   WHERE k.account_id = v_ctx.account_id AND k.contract_id = p_contract_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Contrato % não encontrado', p_contract_id;
  END IF;
  IF v_employer IS NULL THEN
    RAISE EXCEPTION 'Contrato % sem empregador cadastrado: não entra em provisão', p_contract_id;
  END IF;
  IF p_competencia IS NULL OR EXTRACT(DAY FROM p_competencia) <> 1 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'contabil_provisao_direito_informar_v1: a competência é o primeiro dia do mês';
  END IF;
  INSERT INTO folha.provision_entitlement AS e (account_id, employer_id, contract_id, competencia, remuneracao_base,
                                                avos_13, avos_ferias, informado_por_subject, informado_em)
  VALUES (v_ctx.account_id, v_employer, p_contract_id, p_competencia, p_remuneracao_base, p_avos_13, p_avos_ferias, v_ctx.subject_id, now())
  ON CONFLICT (account_id, contract_id, competencia) DO UPDATE
    SET remuneracao_base = EXCLUDED.remuneracao_base, avos_13 = EXCLUDED.avos_13, avos_ferias = EXCLUDED.avos_ferias,
        informado_por_subject = EXCLUDED.informado_por_subject, informado_em = EXCLUDED.informado_em;
  INSERT INTO folha.auditoria (account_id, actor, actor_subject, acao, recurso, recurso_id, detalhe)
  VALUES (v_ctx.account_id, v_ctx.subject_id::text, v_ctx.subject_id, 'informar_direito_provisao', 'employment_contract', p_contract_id,
          jsonb_build_object('competencia', p_competencia, 'remuneracao_base', p_remuneracao_base, 'avos_13', p_avos_13,
                             'avos_ferias', p_avos_ferias, 'sessao', session_user,
                             'legal_entity_id', v_ctx.legal_entity_id, 'branch_id', v_ctx.branch_id));
  PERFORM 1 FROM folha.contexto_v1('folha.calculate');
END
$function$;

-- 8.7 Constituir as provisões de férias e de 13º do empregador na competência (folha.transmit;
--     com encargos, o contexto precisa também de folha.read). Um lote por provisão. Refazer a
--     mesma competência com conteúdo diferente segue a regra do lote (cancela ou estorna e
--     publica nova versão); não refaz competência que já tem provisão posterior.
CREATE FUNCTION folha.contabil_provisao_constituir_v1(p_employer_id uuid, p_competencia date) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx record;
  v_provisao text;
  v_evento text;
  v_lote jsonb;
  v_res jsonb;
  v_lotes jsonb := '[]'::jsonb;
  v_inseridos integer := 0;
  v_detalhe text;
  v_mensagem text;
  v_pend_id uuid;
BEGIN
  SELECT c.account_id, c.legal_entity_id, c.branch_id, c.subject_id INTO v_ctx
    FROM folha.contexto_v1('folha.transmit') AS c;
  IF p_competencia IS NULL OR EXTRACT(DAY FROM p_competencia) <> 1 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'contabil_provisao_constituir_v1: a competência é o primeiro dia do mês';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('folha.contabil.provisao:' || p_employer_id::text, 0));
  IF EXISTS (SELECT 1 FROM folha.accounting_outbox o
              WHERE o.account_id = v_ctx.account_id AND o.employer_id = p_employer_id AND o.formato = 'v2' AND o.vigente
                AND o.evento_tipo IN ('provisao_ferias', 'provisao_13o') AND o.competencia > p_competencia) THEN
    RAISE EXCEPTION 'Já existe provisão vigente em competência posterior a %: a correção entra pela competência seguinte', to_char(p_competencia, 'MM/YYYY');
  END IF;

  BEGIN
    FOREACH v_provisao IN ARRAY ARRAY['decimo_terceiro', 'ferias'] LOOP
      v_evento := CASE v_provisao WHEN 'ferias' THEN 'provisao_ferias' ELSE 'provisao_13o' END;
      v_lote := folha.contabil_provisao_montar(
        v_ctx.account_id, p_employer_id, p_competencia, v_provisao,
        (SELECT o.outbox_id FROM folha.accounting_outbox o
          WHERE o.account_id = v_ctx.account_id AND o.employer_id = p_employer_id AND o.competencia = p_competencia
            AND o.run_id IS NULL AND o.evento_tipo = v_evento AND o.formato = 'v2' AND o.vigente));
      v_res := folha.contabil_lote_publicar(v_ctx.account_id, v_ctx.subject_id, v_lote);
      v_lotes := v_lotes || v_res;
      v_inseridos := v_inseridos + (v_res->>'inseridos')::integer;
    END LOOP;
  EXCEPTION WHEN SQLSTATE 'FC001' THEN
    GET STACKED DIAGNOSTICS v_detalhe = PG_EXCEPTION_DETAIL, v_mensagem = MESSAGE_TEXT;
    v_pend_id := folha.contabil_bloqueio_registrar(v_ctx.account_id, v_ctx.subject_id, v_detalhe::jsonb);
    INSERT INTO folha.auditoria (account_id, actor, actor_subject, acao, recurso, recurso_id, detalhe)
    VALUES (v_ctx.account_id, v_ctx.subject_id::text, v_ctx.subject_id, 'provisao_bloqueada', 'employer', p_employer_id,
            jsonb_build_object('sessao', session_user, 'competencia', p_competencia, 'pendencia_id', v_pend_id,
                               'codigo', v_detalhe::jsonb->>'codigo'));
    PERFORM 1 FROM folha.contexto_v1('folha.transmit');
    RETURN jsonb_build_object('situacao', 'bloqueada', 'lotes', '[]'::jsonb, 'lotes_inseridos', 0,
                              'pendencias', jsonb_build_array(v_detalhe::jsonb || jsonb_build_object('pendencia_id', v_pend_id, 'mensagem', v_mensagem)));
  END;

  INSERT INTO folha.auditoria (account_id, actor, actor_subject, acao, recurso, recurso_id, detalhe)
  VALUES (v_ctx.account_id, v_ctx.subject_id::text, v_ctx.subject_id, 'constituir_provisao', 'employer', p_employer_id,
          jsonb_build_object('sessao', session_user, 'competencia', p_competencia, 'lotes', v_lotes,
                             'legal_entity_id', v_ctx.legal_entity_id, 'branch_id', v_ctx.branch_id));
  PERFORM 1 FROM folha.contexto_v1('folha.transmit');
  RETURN jsonb_build_object(
    'situacao', CASE WHEN v_inseridos = 0 AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_lotes) l WHERE l->>'situacao' NOT IN ('inalterado', 'sem_movimento'))
                     THEN 'inalterada' ELSE 'contabilizada' END,
    'lotes', v_lotes, 'lotes_inseridos', v_inseridos, 'pendencias', '[]'::jsonb);
END
$function$;

-- 8.8 Evento de pagamento (folha.transmit), separado da apropriação, com data própria e
--     comprovante (regra V12). Debita os passivos do grupo e credita a conta de saída de caixa.
--     O valor não excede o saldo do passivo; pagar o saldo inteiro do grupo distribui pelas
--     contas; pagamento parcial de grupo com mais de uma conta exige as parcelas por conta
--     ([{"accountKey": "...", "amountMinor": 123}]). O mesmo comprovante, de novo, não cria nada.
--     Em folha com lotes de mais de um empregador, o empregador do pagamento é obrigatório.
CREATE FUNCTION folha.contabil_pagamento_registrar_v1(
  p_run_id uuid,
  p_evento_tipo text,
  p_data_pagamento date,
  p_comprovante_ref text,
  p_valor_minor bigint,
  p_parcelas jsonb DEFAULT NULL,
  p_employer_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx record;
  v_run record;
  v_existente record;
  v_employer uuid;
  v_n_emp integer;
  v_cfg_dimensao text;
  v_banco text;
  v_saldo_total bigint;
  v_contas integer;
  v_linhas jsonb;
  v_lote jsonb;
  v_payload jsonb;
  v_id bigint;
  v_ref text := btrim(COALESCE(p_comprovante_ref, ''));
  v_detalhe jsonb;
  v_pend_id uuid;
BEGIN
  SELECT c.account_id, c.legal_entity_id, c.branch_id, c.subject_id INTO v_ctx
    FROM folha.contexto_v1('folha.transmit') AS c;
  IF p_evento_tipo IS NULL OR p_evento_tipo NOT IN ('pagamento_liquido', 'recolhimento_previdenciario', 'recolhimento_irrf', 'fgts_deposito', 'repasse_terceiros') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'contabil_pagamento_registrar_v1: tipo de pagamento desconhecido';
  END IF;
  IF v_ref !~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,99}$' OR p_data_pagamento IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'contabil_pagamento_registrar_v1: evento de pagamento exige a referência do comprovante e a data';
  END IF;
  IF p_valor_minor IS NULL OR p_valor_minor <= 0 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'contabil_pagamento_registrar_v1: valor em centavos maior que zero';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('folha.contabil:' || p_run_id::text, 0));
  SELECT r.run_id, r.competencia INTO v_run
    FROM folha.payroll_run r
   WHERE r.run_id = p_run_id AND r.account_id = v_ctx.account_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Folha % não encontrada', p_run_id;
  END IF;

  -- Regra V6: o mesmo comprovante não gera segundo lote.
  SELECT o.outbox_id, o.run_id, o.employer_id, o.total_debito_minor, o.data_lancamento, o.status INTO v_existente
    FROM folha.accounting_outbox o
   WHERE o.account_id = v_ctx.account_id AND o.evento_tipo = p_evento_tipo AND o.comprovante_ref = v_ref;
  IF FOUND THEN
    IF v_existente.run_id IS DISTINCT FROM p_run_id OR v_existente.total_debito_minor <> p_valor_minor
       OR v_existente.data_lancamento <> p_data_pagamento
       OR (p_employer_id IS NOT NULL AND v_existente.employer_id <> p_employer_id) THEN
      RAISE EXCEPTION 'O comprovante % já foi registrado neste tipo de pagamento com outra folha, empregador, valor ou data', v_ref;
    END IF;
    PERFORM 1 FROM folha.contexto_v1('folha.transmit');
    RETURN jsonb_build_object('situacao', 'inalterado', 'outbox_id', v_existente.outbox_id, 'status', v_existente.status, 'inseridos', 0);
  END IF;

  SELECT min(o.employer_id::text)::uuid, count(DISTINCT o.employer_id) INTO v_employer, v_n_emp
    FROM folha.accounting_outbox o
   WHERE o.account_id = v_ctx.account_id AND o.run_id = p_run_id AND o.formato = 'v2' AND o.vigente
     AND o.status IN ('pendente', 'despachado', 'confirmado')
     AND (p_employer_id IS NULL OR o.employer_id = p_employer_id)
     AND o.evento_tipo IN ('folha_mensal', 'folha_complementar', 'adiantamento_salarial', 'decimo_terceiro', 'ferias', 'rescisao', 'pro_labore');
  IF v_employer IS NULL THEN
    RAISE EXCEPTION 'Folha % não tem apropriação contábil vigente e liberada: não há passivo a liquidar', p_run_id;
  END IF;
  IF v_n_emp > 1 THEN
    RAISE EXCEPTION 'Folha % tem lotes de mais de um empregador: informe o empregador do pagamento', p_run_id;
  END IF;

  SELECT COALESCE(sum(s.saldo_minor), 0), count(*) FILTER (WHERE s.saldo_minor > 0)
    INTO v_saldo_total, v_contas
    FROM folha.contabil_passivo_saldos(v_ctx.account_id, p_run_id) s
   WHERE s.grupo = p_evento_tipo AND s.employer_id = v_employer;
  -- Regra V12: o pagamento não excede o saldo do passivo correspondente.
  IF p_valor_minor > v_saldo_total THEN
    RAISE EXCEPTION 'Pagamento de % centavos excede o saldo do passivo do grupo % na folha (% centavos)', p_valor_minor, p_evento_tipo, v_saldo_total;
  END IF;

  IF p_parcelas IS NOT NULL THEN
    IF jsonb_typeof(p_parcelas) <> 'array' OR jsonb_array_length(p_parcelas) = 0
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(p_parcelas) x
                   WHERE jsonb_typeof(x) <> 'object' OR COALESCE(x->>'accountKey', '') = ''
                      OR COALESCE(x->>'amountMinor', '') !~ '^[0-9]+$' OR (x->>'amountMinor')::bigint <= 0)
       OR (SELECT count(*) <> count(DISTINCT x->>'accountKey') FROM jsonb_array_elements(p_parcelas) x)
       OR (SELECT sum((x->>'amountMinor')::bigint) FROM jsonb_array_elements(p_parcelas) x) <> p_valor_minor THEN
      RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'contabil_pagamento_registrar_v1: parcelas inválidas (conta e valor em centavos, sem repetição, somando o valor do pagamento)';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_parcelas) x
                LEFT JOIN folha.contabil_passivo_saldos(v_ctx.account_id, p_run_id) s
                  ON s.grupo = p_evento_tipo AND s.employer_id = v_employer AND s.conta = x->>'accountKey'
               WHERE s.conta IS NULL OR (x->>'amountMinor')::bigint > s.saldo_minor) THEN
      RAISE EXCEPTION 'Parcela de pagamento excede o saldo do passivo da conta no grupo %', p_evento_tipo;
    END IF;
    SELECT jsonb_agg(jsonb_build_object('conta', x->>'accountKey', 'valor', (x->>'amountMinor')::bigint) ORDER BY x->>'accountKey')
      INTO v_linhas FROM jsonb_array_elements(p_parcelas) x;
  ELSIF p_valor_minor = v_saldo_total THEN
    SELECT jsonb_agg(jsonb_build_object('conta', s.conta, 'valor', s.saldo_minor) ORDER BY s.conta)
      INTO v_linhas
      FROM folha.contabil_passivo_saldos(v_ctx.account_id, p_run_id) s
     WHERE s.grupo = p_evento_tipo AND s.employer_id = v_employer AND s.saldo_minor > 0;
  ELSIF v_contas = 1 THEN
    SELECT jsonb_build_array(jsonb_build_object('conta', s.conta, 'valor', p_valor_minor))
      INTO v_linhas
      FROM folha.contabil_passivo_saldos(v_ctx.account_id, p_run_id) s
     WHERE s.grupo = p_evento_tipo AND s.employer_id = v_employer AND s.saldo_minor > 0;
  ELSE
    RAISE EXCEPTION 'Pagamento parcial de grupo com mais de uma conta de passivo: informe as parcelas por conta';
  END IF;

  -- Conta de saída de caixa: mapeamento BANCO do empregador, sem escopo, vigente na competência.
  SELECT m.conta_codigo INTO v_banco
    FROM folha.contabil_mapa m
   WHERE m.account_id = v_ctx.account_id AND m.employer_id = v_employer AND m.ativo
     AND m.chave = 'BANCO' AND m.papel = 'banco'
     AND m.establishment_id IS NULL AND m.allocation_id IS NULL AND m.centro_custo IS NULL AND m.regime_trabalho IS NULL
     AND m.evento_tipo IS NULL
     AND m.vigencia_inicio <= v_run.competencia AND (m.vigencia_fim IS NULL OR m.vigencia_fim >= v_run.competencia);
  IF NOT FOUND THEN
    v_detalhe := jsonb_build_object('codigo', 'mapeamento_ausente', 'evento_tipo', p_evento_tipo, 'employer_id', v_employer,
                                    'run_id', p_run_id, 'competencia', v_run.competencia,
                                    'itens', jsonb_build_array(jsonb_build_object('chave', 'BANCO', 'papel', 'banco', 'regime_trabalho', NULL)));
    v_pend_id := folha.contabil_bloqueio_registrar(v_ctx.account_id, v_ctx.subject_id, v_detalhe);
    PERFORM 1 FROM folha.contexto_v1('folha.transmit');
    RETURN jsonb_build_object('situacao', 'bloqueada', 'outbox_id', NULL, 'inseridos', 0,
                              'pendencias', jsonb_build_array(v_detalhe || jsonb_build_object('pendencia_id', v_pend_id)));
  END IF;

  SELECT g.dimensao INTO v_cfg_dimensao FROM folha.contabil_config g
   WHERE g.account_id = v_ctx.account_id AND g.employer_id = v_employer;

  v_lote := folha.contabil_lote_compor(
    v_employer, p_run_id, v_run.competencia, p_evento_tipo, p_data_pagamento, COALESCE(v_cfg_dimensao, 'nenhuma'),
    (SELECT jsonb_agg(z.linha)
       FROM (SELECT jsonb_build_object('origem_chave', 'PASSIVO', 'origem_papel', 'pagamento', 'chave', 'PASSIVO', 'papel', 'pagamento',
                                       'conta', x->>'conta', 'natureza', 'passivo', 'lado', 'D', 'dimensao', NULL,
                                       'grupo', p_evento_tipo, 'valor', (x->>'valor')::bigint) AS linha
               FROM jsonb_array_elements(v_linhas) x
             UNION ALL
             SELECT jsonb_build_object('origem_chave', 'BANCO', 'origem_papel', 'banco', 'chave', 'BANCO', 'papel', 'banco',
                                       'conta', v_banco, 'natureza', 'ativo', 'lado', 'C', 'dimensao', NULL,
                                       'grupo', NULL, 'valor', p_valor_minor)) z),
    '[]'::jsonb, ARRAY[]::text[]);
  v_payload := folha.contabil_envelope(
    v_ctx.account_id, v_lote, 1, NULL,
    jsonb_build_object('reference', v_ref, 'date', to_char(p_data_pagamento, 'YYYY-MM-DD')));

  INSERT INTO folha.accounting_outbox (
    account_id, run_id, result_id, evento_tipo, payload, status, idempotency_key, formato, employer_id, competencia,
    versao, data_lancamento, payload_hash, total_debito_minor, total_credito_minor, composicao, comprovante_ref,
    contabilizado_por_subject)
  VALUES (
    v_ctx.account_id, p_run_id, NULL, p_evento_tipo, v_payload, 'pendente', v_payload->>'handoffKey', 'v2', v_employer,
    v_run.competencia, 1, p_data_pagamento, v_payload->>'payloadHash',
    (v_payload->'totals'->>'debitMinor')::bigint, (v_payload->'totals'->>'creditMinor')::bigint,
    v_lote->'composicao', v_ref, v_ctx.subject_id)
  RETURNING outbox_id INTO v_id;

  UPDATE folha.contabil_pendencia p
     SET resolvida_em = now()
   WHERE p.account_id = v_ctx.account_id AND p.tipo = 'bloqueio' AND p.resolvida_em IS NULL
     AND p.run_id = p_run_id AND p.employer_id = v_employer AND p.evento_tipo = p_evento_tipo;

  INSERT INTO folha.auditoria (account_id, actor, actor_subject, acao, recurso, recurso_id, detalhe)
  VALUES (v_ctx.account_id, v_ctx.subject_id::text, v_ctx.subject_id, 'registrar_pagamento_contabil', 'payroll_run', p_run_id,
          jsonb_build_object('sessao', session_user, 'evento_tipo', p_evento_tipo, 'outbox_id', v_id, 'valor_minor', p_valor_minor,
                             'data_pagamento', p_data_pagamento, 'legal_entity_id', v_ctx.legal_entity_id, 'branch_id', v_ctx.branch_id));
  PERFORM 1 FROM folha.contexto_v1('folha.transmit');
  RETURN jsonb_build_object('situacao', 'contabilizado', 'outbox_id', v_id, 'status', 'pendente', 'inseridos', 1,
                            'total_minor', p_valor_minor);
END
$function$;

-- 8.9 Liberar pendência a_validar de um lote retido (folha.close), com motivo. Liberada a
--     última, o lote passa a pendente. Pendência de bloqueio não é liberável.
CREATE FUNCTION folha.contabil_pendencia_liberar_v1(p_pendencia_id uuid, p_motivo text) RETURNS text
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx record;
  v_p record;
  v_status text;
BEGIN
  SELECT c.account_id, c.legal_entity_id, c.branch_id, c.subject_id INTO v_ctx
    FROM folha.contexto_v1('folha.close') AS c;
  IF btrim(COALESCE(p_motivo, '')) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'contabil_pendencia_liberar_v1: motivo obrigatório';
  END IF;
  -- Ordem de locks igual à de contabil_lote_publicar: primeiro o lote, depois a pendência.
  PERFORM 1 FROM folha.accounting_outbox o
   WHERE o.account_id = v_ctx.account_id
     AND o.outbox_id = (SELECT p.outbox_id FROM folha.contabil_pendencia p
                         WHERE p.pendencia_id = p_pendencia_id AND p.account_id = v_ctx.account_id)
     FOR UPDATE;
  SELECT p.pendencia_id, p.tipo, p.codigo, p.outbox_id, p.liberada_em, p.resolvida_em INTO v_p
    FROM folha.contabil_pendencia p
   WHERE p.pendencia_id = p_pendencia_id AND p.account_id = v_ctx.account_id
     FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pendência % não encontrada', p_pendencia_id;
  END IF;
  IF v_p.tipo <> 'a_validar' THEN
    RAISE EXCEPTION 'Pendência de bloqueio (%) não é liberável: complete o cadastro e contabilize de novo', v_p.codigo;
  END IF;
  IF v_p.liberada_em IS NOT NULL OR v_p.resolvida_em IS NOT NULL THEN
    RAISE EXCEPTION 'Pendência % já foi liberada ou o lote dela foi substituído', p_pendencia_id;
  END IF;
  UPDATE folha.contabil_pendencia p
     SET liberada_em = now(), liberada_por_subject = v_ctx.subject_id, liberacao_motivo = btrim(p_motivo)
   WHERE p.pendencia_id = p_pendencia_id AND p.account_id = v_ctx.account_id;
  IF NOT EXISTS (SELECT 1 FROM folha.contabil_pendencia p
                  WHERE p.account_id = v_ctx.account_id AND p.outbox_id = v_p.outbox_id
                    AND p.liberada_em IS NULL AND p.resolvida_em IS NULL) THEN
    UPDATE folha.accounting_outbox o SET status = 'pendente'
     WHERE o.account_id = v_ctx.account_id AND o.outbox_id = v_p.outbox_id AND o.status = 'retido';
  END IF;
  SELECT o.status INTO v_status FROM folha.accounting_outbox o
   WHERE o.account_id = v_ctx.account_id AND o.outbox_id = v_p.outbox_id;
  INSERT INTO folha.auditoria (account_id, actor, actor_subject, acao, recurso, recurso_id, detalhe)
  VALUES (v_ctx.account_id, v_ctx.subject_id::text, v_ctx.subject_id, 'liberar_pendencia_contabil', 'contabil_pendencia', p_pendencia_id,
          jsonb_build_object('codigo', v_p.codigo, 'motivo', btrim(p_motivo), 'outbox_id', v_p.outbox_id, 'status_do_lote', v_status,
                             'sessao', session_user, 'legal_entity_id', v_ctx.legal_entity_id, 'branch_id', v_ctx.branch_id));
  PERFORM 1 FROM folha.contexto_v1('folha.close');
  RETURN v_status;
END
$function$;

-- 8.10 Situação contábil de uma folha (folha.read): lotes, saldos dos passivos e pendências
--      abertas. Sem dado pessoal.
CREATE FUNCTION folha.contabil_situacao_v1(p_run_id uuid) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_conta uuid;
BEGIN
  SELECT c.account_id INTO v_conta FROM folha.contexto_v1('folha.read') AS c;
  IF NOT EXISTS (SELECT 1 FROM folha.payroll_run r WHERE r.run_id = p_run_id AND r.account_id = v_conta) THEN
    RAISE EXCEPTION 'Folha % não encontrada', p_run_id;
  END IF;
  RETURN jsonb_build_object(
    'run_id', p_run_id,
    'lotes', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'outbox_id', o.outbox_id, 'employer_id', o.employer_id, 'evento_tipo', o.evento_tipo, 'versao', o.versao, 'status', o.status,
                'vigente', o.vigente, 'data_lancamento', o.data_lancamento, 'total_minor', o.total_debito_minor,
                'estorna_outbox_id', o.estorna_outbox_id, 'comprovante_ref', o.comprovante_ref,
                'handoff_key', o.idempotency_key) ORDER BY o.outbox_id), '[]'::jsonb)
                FROM folha.accounting_outbox o
               WHERE o.account_id = v_conta AND o.run_id = p_run_id AND o.formato = 'v2'),
    'passivos', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                   'employer_id', s.employer_id, 'grupo', s.grupo, 'conta', s.conta, 'apropriado_minor', s.apropriado_minor,
                   'pago_minor', s.pago_minor, 'saldo_minor', s.saldo_minor) ORDER BY s.employer_id, s.grupo, s.conta), '[]'::jsonb)
                   FROM folha.contabil_passivo_saldos(v_conta, p_run_id) s),
    'pendencias', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                     'pendencia_id', p.pendencia_id, 'tipo', p.tipo, 'codigo', p.codigo, 'evento_tipo', p.evento_tipo,
                     'outbox_id', p.outbox_id, 'detalhe', p.detalhe) ORDER BY p.criada_em, p.codigo), '[]'::jsonb)
                     FROM folha.contabil_pendencia p
                    WHERE p.account_id = v_conta AND p.run_id = p_run_id
                      AND p.resolvida_em IS NULL AND p.liberada_em IS NULL));
END
$function$;

-- ===========================================================================
-- 9. Visão de reconciliação (E13)
--    Antes: os resultados eram ligados aos dois outboxes pelo run_id, e cada soma saía
--    multiplicada pelo número de eventos; e a visão só contava eventos, sem comparar valor.
--    Agora: um agregado por fonte (resultados, lote contábil vigente, eSocial), valores da
--    folha em reais como antes e, ao lado, os valores do lote vigente em centavos, com a
--    comparação (regra V15). As treze colunas da 0018 ficam, com o mesmo nome e tipo.
--    security_invoker: a visão passa a respeitar a RLS de quem consulta (antes rodava como o
--    dono, que ignora RLS, e mostrava todas as contas a quem tinha SELECT).
-- ===========================================================================
CREATE OR REPLACE VIEW folha.v_reconciliacao_contabil
WITH (security_invoker = true) AS
SELECT
  r.run_id,
  r.competencia,
  r.account_id,
  COALESCE(f.total_empregados, 0)::bigint AS total_empregados,
  f.soma_proventos,
  f.soma_descontos,
  f.soma_liquido,
  f.soma_inss_patronal,
  f.soma_fgts,
  COALESCE(k.confirmados, 0)::bigint AS eventos_contabeis_confirmados,
  COALESCE(k.pendentes, 0)::bigint AS eventos_contabeis_pendentes,
  COALESCE(s.transmitidos, 0)::bigint AS eventos_esocial_transmitidos,
  COALESCE(s.pendentes, 0)::bigint AS eventos_esocial_pendentes,
  f.soma_rat,
  f.soma_terceiros,
  COALESCE(v.lotes_vigentes, 0)::bigint AS lotes_vigentes,
  COALESCE(v.lotes_vigentes_confirmados, 0)::bigint AS lotes_vigentes_confirmados,
  v.contabil_proventos_minor,
  v.contabil_descontos_minor,
  v.contabil_liquido_minor,
  v.contabil_encargos_previdenciarios_minor,
  v.contabil_fgts_minor,
  CASE
    WHEN COALESCE(f.total_empregados, 0) = 0 THEN 'sem_resultado'
    WHEN COALESCE(v.lotes_vigentes, 0) = 0 THEN 'sem_lote'
    WHEN ROW(round(f.soma_proventos * 100), round(f.soma_descontos * 100), round(f.soma_liquido * 100),
             round((COALESCE(f.soma_inss_patronal, 0) + COALESCE(f.soma_rat, 0) + COALESCE(f.soma_terceiros, 0)) * 100),
             round(f.soma_fgts * 100))
         IS DISTINCT FROM
         ROW(v.contabil_proventos_minor, v.contabil_descontos_minor, v.contabil_liquido_minor,
             v.contabil_encargos_previdenciarios_minor, v.contabil_fgts_minor) THEN 'divergente'
    WHEN v.lotes_vigentes_confirmados < v.lotes_vigentes THEN 'aguardando_confirmacao'
    ELSE 'conciliado'
  END AS situacao
FROM folha.payroll_run r
LEFT JOIN LATERAL (
  SELECT count(*) AS total_empregados,
         sum(pr.total_proventos) AS soma_proventos, sum(pr.total_descontos) AS soma_descontos,
         sum(pr.liquido) AS soma_liquido, sum(pr.inss_patronal) AS soma_inss_patronal, sum(pr.fgts) AS soma_fgts,
         sum(pr.rat) AS soma_rat, sum(pr.terceiros) AS soma_terceiros
    FROM folha.payroll_result pr
   WHERE pr.run_id = r.run_id AND pr.account_id = r.account_id
) f ON true
LEFT JOIN LATERAL (
  SELECT count(*) FILTER (WHERE ao.status = 'confirmado') AS confirmados,
         count(*) FILTER (WHERE ao.status = 'pendente') AS pendentes
    FROM folha.accounting_outbox ao
   WHERE ao.run_id = r.run_id AND ao.account_id = r.account_id
) k ON true
LEFT JOIN LATERAL (
  SELECT count(*) FILTER (WHERE eo.status = 'transmitido') AS transmitidos,
         count(*) FILTER (WHERE eo.status = 'pendente') AS pendentes
    FROM folha.esocial_event_outbox eo
   WHERE eo.run_id = r.run_id AND eo.account_id = r.account_id
) s ON true
LEFT JOIN LATERAL (
  SELECT count(DISTINCT ao.outbox_id) AS lotes_vigentes,
         count(DISTINCT ao.outbox_id) FILTER (WHERE ao.status = 'confirmado') AS lotes_vigentes_confirmados,
         COALESCE(sum((c->>'valor')::numeric) FILTER (WHERE c->>'origem_papel' = 'provento'), 0) AS contabil_proventos_minor,
         COALESCE(sum((c->>'valor')::numeric) FILTER (WHERE c->>'origem_papel' = 'desconto'), 0) AS contabil_descontos_minor,
         COALESCE(sum((c->>'valor')::numeric) FILTER (WHERE c->>'origem_papel' = 'liquido'), 0) AS contabil_liquido_minor,
         COALESCE(sum((c->>'valor')::numeric) FILTER (WHERE c->>'origem_papel' = 'encargo_despesa'
                                                        AND c->>'origem_chave' IN ('INSS_PATRONAL', 'RAT_SAT', 'TERCEIROS')), 0)
           AS contabil_encargos_previdenciarios_minor,
         COALESCE(sum((c->>'valor')::numeric) FILTER (WHERE c->>'origem_papel' = 'encargo_despesa'
                                                        AND c->>'origem_chave' = 'FGTS_DEPOSITO'), 0) AS contabil_fgts_minor
    FROM folha.accounting_outbox ao
    LEFT JOIN LATERAL jsonb_array_elements(ao.composicao) AS c ON true
   WHERE ao.run_id = r.run_id AND ao.account_id = r.account_id AND ao.formato = 'v2' AND ao.vigente
     AND ao.status IN ('retido', 'pendente', 'despachado', 'confirmado')
     AND ao.evento_tipo IN ('folha_mensal', 'folha_complementar', 'adiantamento_salarial', 'decimo_terceiro', 'ferias', 'rescisao', 'pro_labore')
) v ON true;

-- ===========================================================================
-- 10. RLS e ACL
--     Tabelas por conta: policy só de leitura, para worker e data_owner (a gravação é pelas
--     funções, como no Portal da 0029). Catálogos: leitura para os dois papéis.
--     Funções: tira o EXECUTE de todo papel que não seja o dono e concede só o pretendido.
-- ===========================================================================
DO $$
DECLARE
  v_item text[];
  v_tabela text;
  v_papel text;
BEGIN
  FOREACH v_item SLICE 1 IN ARRAY ARRAY[
    ['contabil_config',          'conta'],
    ['contabil_mapa',            'conta'],
    ['contract_cost_assignment', 'conta'],
    ['contabil_pendencia',       'conta'],
    ['provision_entitlement',    'conta'],
    ['provision_ledger',         'conta'],
    ['contabil_papel',           'catalogo'],
    ['contabil_chave',           'catalogo'],
    ['provision_movement_type',  'catalogo']
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

  FOREACH v_item SLICE 1 IN ARRAY ARRAY[
    ['folha.contabil_mapa_trava()',                                             ''],
    ['folha.accounting_outbox_guarda()',                                        ''],
    ['folha.accounting_outbox_imutavel()',                                      ''],
    ['folha.provision_ledger_trava()',                                          ''],
    ['folha.contabil_sem_truncate()',                                           ''],
    ['folha.contabil_payload_hash(jsonb)',                                      ''],
    ['folha.contabil_evento_da_folha(text)',                                    ''],
    ['folha.contabil_chave_provisao(text, text)',                               ''],
    ['folha.contabil_provisao_saldo(uuid, uuid, text, text, date, bigint)',     ''],
    ['folha.contabil_linhas_resolver(uuid, uuid, date, text, text, uuid, jsonb)', ''],
    ['folha.contabil_lote_compor(uuid, uuid, date, text, date, text, jsonb, jsonb, text[])', ''],
    ['folha.contabil_envelope(uuid, jsonb, integer, text, jsonb, jsonb)',       ''],
    ['folha.contabil_folha_conferir_estado(uuid, uuid)',                        ''],
    ['folha.contabil_folha_montar(uuid, uuid, uuid, text, bigint)',             ''],
    ['folha.contabil_provisao_montar(uuid, uuid, date, text, bigint)',          ''],
    ['folha.contabil_razao_reverter(uuid, uuid, bigint, bigint)',               ''],
    ['folha.contabil_lote_publicar(uuid, uuid, jsonb)',                         ''],
    ['folha.contabil_bloqueio_registrar(uuid, uuid, jsonb)',                    ''],
    ['folha.contabil_folha_executar(uuid, uuid, uuid)',                         ''],
    ['folha.contabil_passivo_saldos(uuid, uuid)',                               ''],
    ['folha.contabil_config_definir_v1(uuid, text, text, boolean)',             'dnex_gestao_api'],
    ['folha.contabil_mapa_definir_v1(uuid, text, text, text, text, date, boolean, date, text, uuid, uuid, text, text, text, text)', 'dnex_gestao_api'],
    ['folha.contabil_mapa_encerrar_v1(uuid, date, boolean)',                    'dnex_gestao_api'],
    ['folha.contabil_contrato_dimensao_definir_v1(uuid, text, text, date)',     'dnex_gestao_api'],
    ['folha.contabil_folha_contabilizar_v1(uuid)',                              'dnex_gestao_api'],
    ['folha.contabil_provisao_direito_informar_v1(uuid, date, numeric, numeric, numeric)', 'dnex_gestao_api'],
    ['folha.contabil_provisao_constituir_v1(uuid, date)',                       'dnex_gestao_api'],
    ['folha.contabil_pagamento_registrar_v1(uuid, text, date, text, bigint, jsonb, uuid)', 'dnex_gestao_api'],
    ['folha.contabil_pendencia_liberar_v1(uuid, text)',                         'dnex_gestao_api'],
    ['folha.contabil_situacao_v1(uuid)',                                        'dnex_gestao_api']
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

  -- O CHECK e o índice de exclusão do mapeamento não chamam função do schema; o gatilho de
  -- UPDATE do outbox roda com o privilégio de quem atualiza (worker) e não precisa de EXECUTE.
  -- A visão mantém a ACL da 0018 (worker e data_owner leem).
  REVOKE ALL ON folha.v_reconciliacao_contabil FROM PUBLIC, anon, authenticated, service_role;
END
$$;

-- ---------------------------------------------------------------------------
-- 11. Pós-voo (falha fechada)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_inesperado text;
BEGIN
  -- O que a sessão de aplicação executa de contabilização é exatamente a lista desta migration.
  SELECT string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text) INTO v_inesperado
    FROM pg_catalog.pg_proc p
   WHERE p.pronamespace = 'folha'::regnamespace
     AND p.proname LIKE 'contabil\_%'
     AND has_function_privilege('dnex_gestao_api', p.oid, 'EXECUTE')
     AND p.oid::regprocedure::text NOT IN (
       'folha.contabil_config_definir_v1(uuid,text,text,boolean)',
       'folha.contabil_mapa_definir_v1(uuid,text,text,text,text,date,boolean,date,text,uuid,uuid,text,text,text,text)',
       'folha.contabil_mapa_encerrar_v1(uuid,date,boolean)',
       'folha.contabil_contrato_dimensao_definir_v1(uuid,text,text,date)',
       'folha.contabil_folha_contabilizar_v1(uuid)',
       'folha.contabil_provisao_direito_informar_v1(uuid,date,numeric,numeric,numeric)',
       'folha.contabil_provisao_constituir_v1(uuid,date)',
       'folha.contabil_pagamento_registrar_v1(uuid,text,date,text,bigint,jsonb,uuid)',
       'folha.contabil_pendencia_liberar_v1(uuid,text)',
       'folha.contabil_situacao_v1(uuid)');
  IF v_inesperado IS NOT NULL THEN
    RAISE EXCEPTION '0030: dnex_gestao_api executa funções de contabilização fora da lista: %', v_inesperado
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT string_agg(c.relname, ', ' ORDER BY c.relname) INTO v_inesperado
    FROM pg_catalog.pg_class c
   WHERE c.relnamespace = 'folha'::regnamespace AND c.relkind IN ('r', 'p', 'v', 'm')
     AND (has_table_privilege('dnex_gestao_api', c.oid, 'SELECT')
          OR has_table_privilege('dnex_gestao_api', c.oid, 'INSERT, UPDATE, DELETE, TRUNCATE'));
  IF v_inesperado IS NOT NULL THEN
    RAISE EXCEPTION '0030: dnex_gestao_api tem privilégio direto em: %', v_inesperado
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text) INTO v_inesperado
    FROM pg_catalog.pg_proc p
   WHERE p.pronamespace = 'folha'::regnamespace AND p.prosecdef
     AND NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) AS cfg
                      WHERE cfg ~ '^search_path=pg_catalog(,|$)' AND cfg ~ ',\s*pg_temp$' AND cfg !~ 'pg_temp.*pg_temp');
  IF v_inesperado IS NOT NULL THEN
    RAISE EXCEPTION '0030: função SECURITY DEFINER cujo search_path não começa por pg_catalog e termina em pg_temp: %', v_inesperado
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text) INTO v_inesperado
    FROM pg_catalog.pg_proc p
    CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
   WHERE p.pronamespace = 'folha'::regnamespace AND a.grantee = 0;
  IF v_inesperado IS NOT NULL THEN
    RAISE EXCEPTION '0030: função do schema folha executável por PUBLIC: %', v_inesperado
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF has_table_privilege('dnex_gestao_folha_worker', 'folha.accounting_outbox', 'INSERT')
     OR has_table_privilege('dnex_gestao_folha_worker', 'folha.provision_ledger', 'INSERT, UPDATE, DELETE')
     OR has_table_privilege('dnex_gestao_folha_worker', 'folha.contabil_mapa', 'INSERT, UPDATE, DELETE') THEN
    RAISE EXCEPTION '0030: o worker ficou com gravação direta em tabela de contabilização'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
END
$$;

COMMIT;
