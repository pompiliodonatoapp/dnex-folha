-- DNEX Folha — Migration 0026: modelo de rubricas, bases de cálculo, camadas de regra,
-- lançamentos, tipo de processo e pendências (fatia 4, parte 1 de 2: estrutura e dados).
-- As funções do motor ficam na 0027.
--
-- Fontes: scratch/insumos/PLANO-CONSTRUCAO-FOLHA.md (seções "Modelo de dados a adotar" e
-- "Bloqueios de produção em aberto") e os pareceres de DP de 15/11/2026. A especificação
-- funcional observada em sistema de mercado serviu só de referência de requisito: nomes,
-- desenho e textos são próprios.
--
-- O que esta migration faz:
--   1. Catálogos globais: base de cálculo (calculation_base), código de incidência por
--      tributo (incidence_code), natureza de rubrica do eSocial (esocial_rubric_nature,
--      vazia) e camadas de regra com a precedência (rule_layer).
--   2. Rubrica (earning_deduction_code): tipo, forma de cálculo e ordem; incidência por
--      tributo COMO CÓDIGO e com vigência (rubric_incidence); natureza do eSocial por
--      vigência (rubric_esocial_nature); ligação N:N com as bases (rubric_base).
--   3. Três camadas de regra (rubric_rule): empresa, convenção coletiva e contrato.
--   4. Lançamentos do período (payroll_entry), afastamentos (contract_leave) e remuneração
--      informada de outros vínculos (external_remuneration).
--   5. Folha com tipo de processo e várias folhas por competência (payroll_run), entradas
--      dos processos de 13º, férias e rescisão (payroll_process_input), itens e bases do
--      resultado como dado (payroll_result_item, payroll_result_base), origem da regra na
--      memória de cálculo (calculation_trace) e pendências consultáveis (payroll_pendency).
--   6. Fecha em 31/12/2026 a vigência das tabelas de INSS, salário mínimo e IRRF de 2026 (0015),
--      que estavam abertas e serviriam 2027 sem erro.
--   7. Migra as rubricas da 0017 para o modelo novo e cria as rubricas dos processos.
--   8. RLS com FORCE, policies com (SELECT folha.current_account_id()) e ACL com REVOKE
--      antes do GRANT, no padrão das 0024 e 0025.
--
-- Códigos de incidência: o catálogo é ESTRUTURA. Os códigos são internos (efeito no motor);
-- a coluna codigo_esocial fica nula e a_validar, porque os insumos trazem só a lista de
-- números em uso num sistema de mercado, sem significado nem leiaute oficial lido. O mesmo
-- vale para a natureza de rubrica (tabela vazia). PIS não entra: o parecer de eSocial cita
-- só CP, IRRF e FGTS.
--
-- NÃO altera as migrations 0014 a 0025. NÃO APLICAR EM PRODUÇÃO sem as dependências já
-- registradas (autenticação pelo dnex-gestao) e sem a 0027.
-- Reversão: 0026_folha_rubricas_bases_camadas.supabase.down.sql.
BEGIN;

SET LOCAL lock_timeout = '5s';

-- ---------------------------------------------------------------------------
-- 0. Pré-condições
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_lista text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles
                  WHERE rolname = current_user AND (rolsuper OR rolbypassrls)) THEN
    RAISE EXCEPTION '0026: o papel % não é superusuário nem tem BYPASSRLS; a migração das rubricas e das tabelas por vigência não enxergaria as linhas', current_user
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF to_regprocedure('folha.irrf_apurar(numeric, numeric, integer, date, text)') IS NULL
     OR to_regclass('folha.request_context_config') IS NULL THEN
    RAISE EXCEPTION '0026: faltam objetos da migration 0025'
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  -- As três conferências abaixo dizem QUAIS códigos conflitam: nada é limpo por esta migration.
  SELECT string_agg(x.codigo || ' (' || x.n || ' linhas)', ', ' ORDER BY x.codigo) INTO v_lista
    FROM (SELECT codigo, count(*) AS n FROM folha.earning_deduction_code
           WHERE account_id IS NULL GROUP BY codigo HAVING count(*) > 1) x;
  IF v_lista IS NOT NULL THEN
    RAISE EXCEPTION '0026: rubrica global com código repetido; resolva antes de criar o índice único. Códigos: %', v_lista
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  SELECT string_agg(e.codigo || ' (conta ' || COALESCE(e.account_id::text, 'nula') || ', is_global ' || e.is_global || ')', ', ' ORDER BY e.codigo)
    INTO v_lista
    FROM folha.earning_deduction_code e WHERE e.is_global IS DISTINCT FROM (e.account_id IS NULL);
  IF v_lista IS NOT NULL THEN
    RAISE EXCEPTION '0026: rubrica com is_global incoerente com a conta (global = conta nula); corrija antes. Rubricas: %', v_lista
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  SELECT string_agg(DISTINCT c.codigo, ', ' ORDER BY c.codigo) INTO v_lista
    FROM folha.earning_deduction_code c
    JOIN folha.earning_deduction_code g ON g.account_id IS NULL AND g.codigo = c.codigo
   WHERE c.account_id IS NOT NULL;
  IF v_lista IS NOT NULL THEN
    RAISE EXCEPTION '0026: rubrica de conta com o mesmo código de rubrica global; renomeie antes (o motor resolve a rubrica pelo código). Códigos: %', v_lista
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  IF EXISTS (SELECT 1 FROM folha.payroll_run WHERE EXTRACT(DAY FROM competencia) <> 1) THEN
    RAISE EXCEPTION '0026: há folha com competência que não é o primeiro dia do mês'
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
END
$$;

-- ===========================================================================
-- 1. Catálogos globais
-- ===========================================================================

-- 1.1 Base de cálculo como entidade. account_id NULL = base padrão (global).
CREATE TABLE folha.calculation_base (
  base_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid,
  codigo text NOT NULL CHECK (codigo ~ '^[A-Z][A-Z0-9_]{1,39}$'),
  descricao text NOT NULL,
  finalidade text NOT NULL CHECK (finalidade IN (
    'previdencia', 'irrf', 'fgts', 'medias', 'decimo_terceiro', 'ferias', 'salario_familia', 'outra')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX calculation_base_global_codigo_key
  ON folha.calculation_base (codigo) WHERE account_id IS NULL;
CREATE UNIQUE INDEX calculation_base_conta_codigo_key
  ON folha.calculation_base (account_id, codigo) WHERE account_id IS NOT NULL;

-- A policy das tabelas com linha global deixa a conta LER a linha global; sem esta trava, um
-- UPDATE que trocasse account_id para a própria conta passaria no WITH CHECK e tiraria a linha
-- de todas as outras contas. Com a conta imutável, o UPDATE de linha global cai no WITH CHECK.
CREATE FUNCTION folha.conta_imutavel() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, folha
AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.account_id IS DISTINCT FROM OLD.account_id THEN
    RAISE EXCEPTION '%: a conta da linha não pode ser alterada', TG_TABLE_NAME USING ERRCODE = 'check_violation';
  END IF;
  -- Base de conta não repete código de base global (o motor lê a base pelo código).
  IF NEW.account_id IS NOT NULL
     AND EXISTS (SELECT 1 FROM folha.calculation_base g WHERE g.account_id IS NULL AND g.codigo = NEW.codigo) THEN
    RAISE EXCEPTION 'calculation_base: o código % é de base global e não pode ser repetido por conta', NEW.codigo
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_calculation_base_conta_imutavel
  BEFORE INSERT OR UPDATE ON folha.calculation_base
  FOR EACH ROW EXECUTE FUNCTION folha.conta_imutavel();

INSERT INTO folha.calculation_base (codigo, descricao, finalidade) VALUES
  ('INSS_MENSAL',     'Salário de contribuição do mês (INSS do segurado e encargos patronais)',  'previdencia'),
  ('INSS_13',         'Salário de contribuição do 13º salário (apuração em separado)',            'previdencia'),
  ('IRRF_MENSAL',     'Rendimento tributável de incidência mensal',                               'irrf'),
  ('IRRF_13',         'Rendimento do 13º salário (tributação em separado)',                       'irrf'),
  ('IRRF_FERIAS',     'Rendimento de férias (tributação em separado)',                            'irrf'),
  ('FGTS_MENSAL',     'Remuneração do mês para o depósito do FGTS',                               'fgts'),
  ('FGTS_13',         'Remuneração de 13º salário para o depósito do FGTS',                       'fgts'),
  ('SALARIO_FAMILIA', 'Remuneração do mês para aferir o direito ao salário-família (sem 13º e sem terço de férias)', 'salario_familia'),
  ('MEDIAS',          'Rubricas variáveis que entram em médias (sem rubrica ligada por padrão)',  'medias'),
  ('DECIMO_TERCEIRO', 'Rubricas que compõem a remuneração-base do 13º (sem rubrica ligada por padrão)', 'decimo_terceiro'),
  ('FERIAS',          'Rubricas que compõem a remuneração-base das férias (sem rubrica ligada por padrão)', 'ferias');

-- 1.2 Código de incidência por tributo. O código é interno e diz o EFEITO no motor; o
--     código oficial do eSocial entra em codigo_esocial quando for lido no leiaute.
CREATE TABLE folha.incidence_code (
  tributo text NOT NULL CHECK (tributo IN ('previdencia', 'irrf', 'fgts')),
  codigo text NOT NULL CHECK (codigo ~ '^[A-Z][A-Z0-9_]{1,39}$'),
  descricao text NOT NULL,
  efeito text NOT NULL CHECK (efeito IN ('nao_incide', 'compoe_base', 'retencao')),
  base_id uuid REFERENCES folha.calculation_base (base_id),
  codigo_esocial text,
  esocial_status text NOT NULL DEFAULT 'a_validar' CHECK (esocial_status IN ('validado', 'a_validar')),
  esocial_fonte text,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tributo, codigo),
  CONSTRAINT incidence_code_base_coerente CHECK ((efeito = 'compoe_base') = (base_id IS NOT NULL)),
  CONSTRAINT incidence_code_esocial_com_fonte
    CHECK (esocial_status = 'a_validar' OR (codigo_esocial IS NOT NULL AND btrim(COALESCE(esocial_fonte, '')) <> ''))
);

INSERT INTO folha.incidence_code (tributo, codigo, descricao, efeito, base_id)
SELECT x.tributo, x.codigo, x.descricao, x.efeito,
       (SELECT b.base_id FROM folha.calculation_base b WHERE b.account_id IS NULL AND b.codigo = x.base)
  FROM (VALUES
    ('previdencia', 'NAO_INCIDE',        'Não compõe salário de contribuição',                       'nao_incide',  NULL),
    ('previdencia', 'BASE_MENSAL',       'Compõe o salário de contribuição do mês',                  'compoe_base', 'INSS_MENSAL'),
    ('previdencia', 'BASE_13',           'Compõe o salário de contribuição do 13º salário',          'compoe_base', 'INSS_13'),
    ('previdencia', 'RETENCAO_SEGURADO', 'É a própria contribuição descontada do segurado',          'retencao',    NULL),
    ('irrf',        'NAO_INCIDE',        'Não é rendimento tributável na fonte',                     'nao_incide',  NULL),
    ('irrf',        'BASE_MENSAL',       'Rendimento tributável de incidência mensal',               'compoe_base', 'IRRF_MENSAL'),
    ('irrf',        'BASE_13',           'Rendimento do 13º salário, tributado em separado',         'compoe_base', 'IRRF_13'),
    ('irrf',        'BASE_FERIAS',       'Rendimento de férias, tributado em separado',              'compoe_base', 'IRRF_FERIAS'),
    ('irrf',        'RETENCAO',          'É o próprio imposto retido na fonte',                      'retencao',    NULL),
    ('fgts',        'NAO_INCIDE',        'Não compõe a remuneração para o FGTS',                     'nao_incide',  NULL),
    ('fgts',        'BASE_MENSAL',       'Compõe a remuneração do mês para o FGTS',                  'compoe_base', 'FGTS_MENSAL'),
    ('fgts',        'BASE_13',           'Compõe a remuneração de 13º salário para o FGTS',          'compoe_base', 'FGTS_13')
  ) AS x(tributo, codigo, descricao, efeito, base);

-- 1.3 Natureza de rubrica do eSocial: só a estrutura. A tabela oficial não está nos insumos.
CREATE TABLE folha.esocial_rubric_nature (
  codigo text PRIMARY KEY,
  descricao text NOT NULL,
  vigencia_inicio date NOT NULL,
  vigencia_fim date,
  fonte text NOT NULL CHECK (btrim(fonte) <> ''),
  status_validacao text NOT NULL DEFAULT 'a_validar' CHECK (status_validacao IN ('validado', 'a_validar')),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT esocial_rubric_nature_vigencia_valida CHECK (vigencia_fim IS NULL OR vigencia_fim >= vigencia_inicio)
);

-- 1.4 Camadas de regra e precedência (maior número vence). Decisão de produto registrada no
--     ADR-rubricas-bases-camadas; a regra mais específica prevalece.
CREATE TABLE folha.rule_layer (
  camada text PRIMARY KEY CHECK (camada IN ('empresa', 'convencao', 'contrato')),
  precedencia integer NOT NULL UNIQUE CHECK (precedencia > 0),
  descricao text NOT NULL
);
INSERT INTO folha.rule_layer (camada, precedencia, descricao) VALUES
  ('empresa',   1, 'Regra do empregador, para todos os contratos dele'),
  ('convencao', 2, 'Regra da convenção ou do acordo coletivo ligado ao contrato'),
  ('contrato',  3, 'Regra do trabalhador ou contrato (aditivo, condição individual)');

-- ===========================================================================
-- 2. Rubrica
-- ===========================================================================
ALTER TABLE folha.earning_deduction_code
  ADD COLUMN tipo_rubrica text
    CONSTRAINT earning_deduction_code_tipo_rubrica_check
      CHECK (tipo_rubrica IN ('provento', 'desconto', 'informativa', 'base')),
  ADD COLUMN forma_calculo text NOT NULL DEFAULT 'valor_fixo'
    CONSTRAINT earning_deduction_code_forma_calculo_check
      CHECK (forma_calculo IN ('valor_fixo', 'percentual_base', 'quantidade_valor', 'formula', 'apuracao_motor')),
  ADD COLUMN ordem_calculo integer NOT NULL DEFAULT 500
    CONSTRAINT earning_deduction_code_ordem_check CHECK (ordem_calculo BETWEEN 1 AND 9999),
  ADD COLUMN ativa boolean NOT NULL DEFAULT true;   -- rubrica inativa não entra em cálculo

COMMENT ON COLUMN folha.earning_deduction_code.incidencia_inss IS
  'Legado da 0014. O motor não lê: a incidência vale por código e vigência em folha.rubric_incidence.';
COMMENT ON COLUMN folha.earning_deduction_code.incidencia_irrf IS
  'Legado da 0014. O motor não lê: a incidência vale por código e vigência em folha.rubric_incidence.';
COMMENT ON COLUMN folha.earning_deduction_code.incidencia_fgts IS
  'Legado da 0014. O motor não lê: a incidência vale por código e vigência em folha.rubric_incidence.';
COMMENT ON COLUMN folha.earning_deduction_code.forma_calculo IS
  'apuracao_motor = valor apurado pelo motor (não aceita lançamento nem regra); as demais dizem como o lançamento vira valor quando não há regra de camada.';

-- Quem grava rubrica sem tipo (código anterior à 0026) recebe o tipo derivado da natureza.
-- A mesma função guarda três invariantes de que o motor depende:
--   a conta da rubrica não muda (ver folha.conta_imutavel); global = conta nula; e rubrica de
--   conta não repete código de rubrica global (o motor resolve a rubrica pelo código: uma
--   rubrica de conta chamada INSS_EMPREGADO ou SALARIO_BASE tomaria o lugar da do motor).
CREATE FUNCTION folha.rubrica_derivar_tipo() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, folha
SET row_security = off
AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.account_id IS DISTINCT FROM OLD.account_id THEN
    RAISE EXCEPTION 'earning_deduction_code: a conta da rubrica não pode ser alterada' USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.is_global IS DISTINCT FROM (NEW.account_id IS NULL) THEN
    RAISE EXCEPTION 'earning_deduction_code: rubrica global tem conta nula, e só ela (is_global %, conta %)', NEW.is_global, NEW.account_id
      USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.account_id IS NOT NULL
     AND EXISTS (SELECT 1 FROM folha.earning_deduction_code g WHERE g.account_id IS NULL AND g.codigo = NEW.codigo) THEN
    RAISE EXCEPTION 'earning_deduction_code: o código % é de rubrica global e não pode ser repetido por conta', NEW.codigo
      USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.account_id IS NULL
     AND EXISTS (SELECT 1 FROM folha.earning_deduction_code c WHERE c.account_id IS NOT NULL AND c.codigo = NEW.codigo) THEN
    RAISE EXCEPTION 'earning_deduction_code: o código % já existe como rubrica de conta', NEW.codigo
      USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.tipo_rubrica IS NULL THEN
    NEW.tipo_rubrica := CASE NEW.natureza
                          WHEN 'provento' THEN 'provento'
                          WHEN 'desconto' THEN 'desconto'
                          ELSE 'informativa' END;
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_rubrica_derivar_tipo
  BEFORE INSERT OR UPDATE ON folha.earning_deduction_code
  FOR EACH ROW EXECUTE FUNCTION folha.rubrica_derivar_tipo();

CREATE UNIQUE INDEX earning_deduction_code_global_codigo_key
  ON folha.earning_deduction_code (codigo) WHERE account_id IS NULL;

-- 2.1 A linha filha de uma rubrica tem a mesma conta da rubrica (NULL = global) e, nas
--     tabelas por conta, só aponta rubrica global ou da própria conta; a base de cálculo
--     apontada é global ou da mesma conta; a conta da linha não muda. SECURITY DEFINER:
--     a conferência não pode depender da RLS de quem grava.
CREATE FUNCTION folha.exigir_rubrica_da_conta() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, folha
SET row_security = off
AS $$
DECLARE
  v_conta_rubrica uuid;
  v_conta_base uuid;
  v_base uuid := (to_jsonb(NEW)->>'base_id')::uuid;
  v_modo text := TG_ARGV[0];
BEGIN
  IF TG_OP = 'UPDATE' AND NEW.account_id IS DISTINCT FROM OLD.account_id THEN
    RAISE EXCEPTION '%: a conta da linha não pode ser alterada', TG_TABLE_NAME USING ERRCODE = 'check_violation';
  END IF;
  -- Base de cálculo apontada pela linha: global ou da mesma conta (a FK é simples).
  -- As mensagens não distinguem "não existe" de "é de outra conta": quem grava não descobre
  -- por aqui se um identificador alheio existe.
  IF v_base IS NOT NULL THEN
    SELECT b.account_id INTO v_conta_base FROM folha.calculation_base b WHERE b.base_id = v_base;
    IF NOT FOUND OR (v_conta_base IS NOT NULL AND v_conta_base IS DISTINCT FROM NEW.account_id) THEN
      RAISE EXCEPTION '%: base de cálculo inexistente ou indisponível para esta conta', TG_TABLE_NAME USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  SELECT e.account_id INTO v_conta_rubrica
    FROM folha.earning_deduction_code e WHERE e.code_id = NEW.code_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '%: rubrica inexistente ou indisponível para esta conta', TG_TABLE_NAME USING ERRCODE = 'check_violation';
  END IF;
  IF v_modo = 'mesma_conta' THEN
    IF v_conta_rubrica IS DISTINCT FROM NEW.account_id THEN
      RAISE EXCEPTION '%: a linha deve ter a mesma conta da rubrica (global só com conta nula)', TG_TABLE_NAME
        USING ERRCODE = 'check_violation';
    END IF;
  ELSIF v_conta_rubrica IS NOT NULL AND v_conta_rubrica IS DISTINCT FROM NEW.account_id THEN
    RAISE EXCEPTION '%: rubrica inexistente ou indisponível para esta conta', TG_TABLE_NAME USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

-- 2.2 Incidência por tributo, como código e com vigência (datas inclusivas).
CREATE TABLE folha.rubric_incidence (
  rubric_incidence_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid,
  code_id uuid NOT NULL REFERENCES folha.earning_deduction_code (code_id),
  tributo text NOT NULL,
  incidencia_codigo text NOT NULL,
  vigencia_inicio date NOT NULL,
  vigencia_fim date,
  fonte text,
  -- a_validar = incidência não conferida na fonte: usada no cálculo, vira pendência na folha.
  status_validacao text NOT NULL DEFAULT 'a_validar' CHECK (status_validacao IN ('validado', 'a_validar')),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT rubric_incidence_codigo_fk FOREIGN KEY (tributo, incidencia_codigo)
    REFERENCES folha.incidence_code (tributo, codigo),
  CONSTRAINT rubric_incidence_vigencia_valida CHECK (vigencia_fim IS NULL OR vigencia_fim >= vigencia_inicio),
  CONSTRAINT rubric_incidence_sem_sobreposicao EXCLUDE USING gist (
    code_id WITH =, tributo WITH =,
    daterange(vigencia_inicio, vigencia_fim, '[]') WITH &&)
);
CREATE TRIGGER trg_rubric_incidence_conta
  BEFORE INSERT OR UPDATE ON folha.rubric_incidence
  FOR EACH ROW EXECUTE FUNCTION folha.exigir_rubrica_da_conta('mesma_conta');

-- 2.3 Natureza do eSocial da rubrica, por vigência (sem linha = natureza a definir).
CREATE TABLE folha.rubric_esocial_nature (
  rubric_nature_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid,
  code_id uuid NOT NULL REFERENCES folha.earning_deduction_code (code_id),
  natureza_codigo text NOT NULL REFERENCES folha.esocial_rubric_nature (codigo),
  vigencia_inicio date NOT NULL,
  vigencia_fim date,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT rubric_esocial_nature_vigencia_valida CHECK (vigencia_fim IS NULL OR vigencia_fim >= vigencia_inicio),
  CONSTRAINT rubric_esocial_nature_sem_sobreposicao EXCLUDE USING gist (
    code_id WITH =, daterange(vigencia_inicio, vigencia_fim, '[]') WITH &&)
);
CREATE TRIGGER trg_rubric_esocial_nature_conta
  BEFORE INSERT OR UPDATE ON folha.rubric_esocial_nature
  FOR EACH ROW EXECUTE FUNCTION folha.exigir_rubrica_da_conta('mesma_conta');

-- 2.4 Rubrica x base (N:N), por vigência. Provento soma na base; desconto subtrai.
CREATE TABLE folha.rubric_base (
  rubric_base_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid,
  code_id uuid NOT NULL REFERENCES folha.earning_deduction_code (code_id),
  base_id uuid NOT NULL REFERENCES folha.calculation_base (base_id),
  vigencia_inicio date NOT NULL,
  vigencia_fim date,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT rubric_base_vigencia_valida CHECK (vigencia_fim IS NULL OR vigencia_fim >= vigencia_inicio),
  CONSTRAINT rubric_base_sem_sobreposicao EXCLUDE USING gist (
    code_id WITH =, base_id WITH =,
    daterange(vigencia_inicio, vigencia_fim, '[]') WITH &&)
);
CREATE INDEX idx_rubric_base_base ON folha.rubric_base (base_id);
CREATE TRIGGER trg_rubric_base_conta
  BEFORE INSERT OR UPDATE ON folha.rubric_base
  FOR EACH ROW EXECUTE FUNCTION folha.exigir_rubrica_da_conta('mesma_conta');

-- ===========================================================================
-- 3. Camadas de regra
-- ===========================================================================
-- Alvos das chaves estrangeiras compostas com a conta.
CREATE UNIQUE INDEX employee_account_employee_key ON folha.employee (account_id, employee_id);
CREATE UNIQUE INDEX employment_contract_account_contract_key ON folha.employment_contract (account_id, contract_id);
CREATE UNIQUE INDEX collective_agreement_account_agreement_key ON folha.collective_agreement (account_id, agreement_id);
CREATE UNIQUE INDEX payroll_run_account_run_key ON folha.payroll_run (account_id, run_id);
CREATE UNIQUE INDEX payroll_result_account_result_key ON folha.payroll_result (account_id, result_id);

-- Convenção ligada ao contrato (a 0014 criou a convenção sem vínculo com o contrato).
ALTER TABLE folha.employment_contract
  ADD COLUMN agreement_id uuid,
  ADD CONSTRAINT contract_agreement_fk FOREIGN KEY (account_id, agreement_id)
    REFERENCES folha.collective_agreement (account_id, agreement_id);
CREATE INDEX idx_contract_agreement ON folha.employment_contract (account_id, agreement_id)
  WHERE agreement_id IS NOT NULL;

-- Fórmula restrita: árvore JSON com operações aritméticas, números, variáveis de uma lista
-- fechada e leitura de base. Não há SQL montado a partir de dado. Profundidade limitada.
CREATE FUNCTION folha.formula_valida(p_no jsonb, p_nivel integer DEFAULT 0) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE
SET search_path = pg_catalog, folha
AS $$
DECLARE
  v_arg jsonb;
  v_n integer;
BEGIN
  IF p_no IS NULL OR jsonb_typeof(p_no) <> 'object' OR p_nivel > 12 THEN
    RETURN false;
  END IF;
  IF p_no ? 'num' THEN
    RETURN (SELECT count(*) FROM jsonb_object_keys(p_no)) = 1 AND jsonb_typeof(p_no->'num') = 'number';
  ELSIF p_no ? 'var' THEN
    RETURN (SELECT count(*) FROM jsonb_object_keys(p_no)) = 1
       AND jsonb_typeof(p_no->'var') = 'string'
       AND (p_no->>'var') IN ('SALARIO', 'QUANTIDADE', 'VALOR');
  ELSIF p_no ? 'base' THEN
    RETURN (SELECT count(*) FROM jsonb_object_keys(p_no)) = 1
       AND jsonb_typeof(p_no->'base') = 'string'
       AND (p_no->>'base') ~ '^[A-Z][A-Z0-9_]{1,39}$';
  ELSIF p_no ? 'op' THEN
    IF (SELECT count(*) FROM jsonb_object_keys(p_no)) <> 2
       OR jsonb_typeof(p_no->'op') <> 'string'
       OR (p_no->>'op') NOT IN ('soma', 'subtrai', 'multiplica', 'divide', 'minimo', 'maximo', 'arredonda2')
       OR jsonb_typeof(p_no->'args') IS DISTINCT FROM 'array' THEN
      RETURN false;
    END IF;
    v_n := jsonb_array_length(p_no->'args');
    IF (p_no->>'op') = 'arredonda2' AND v_n <> 1 THEN RETURN false; END IF;
    IF (p_no->>'op') IN ('subtrai', 'divide') AND v_n <> 2 THEN RETURN false; END IF;
    IF (p_no->>'op') IN ('soma', 'multiplica', 'minimo', 'maximo') AND (v_n < 2 OR v_n > 8) THEN RETURN false; END IF;
    FOR v_arg IN SELECT * FROM jsonb_array_elements(p_no->'args') LOOP
      IF NOT folha.formula_valida(v_arg, p_nivel + 1) THEN RETURN false; END IF;
    END LOOP;
    RETURN true;
  END IF;
  RETURN false;
END;
$$;

CREATE TABLE folha.rubric_rule (
  rule_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  camada text NOT NULL REFERENCES folha.rule_layer (camada),
  employer_id uuid,
  agreement_id uuid,
  contract_id uuid,
  code_id uuid NOT NULL REFERENCES folha.earning_deduction_code (code_id),
  forma_calculo text NOT NULL CHECK (forma_calculo IN ('valor_fixo', 'percentual_base', 'quantidade_valor', 'formula')),
  valor numeric(14,2) CHECK (valor >= 0),
  percentual numeric(9,6) CHECK (percentual >= 0),            -- fração: 0,30 = 30%
  base_id uuid REFERENCES folha.calculation_base (base_id),
  valor_unitario numeric(14,4) CHECK (valor_unitario >= 0),
  formula jsonb,
  automatica boolean NOT NULL DEFAULT false,   -- true = entra em toda folha mensal do alcance, sem lançamento
  vigencia_inicio date NOT NULL,
  vigencia_fim date,
  fonte text NOT NULL CHECK (btrim(fonte) <> ''),              -- cláusula, política interna ou aditivo
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT rubric_rule_employer_fk FOREIGN KEY (account_id, employer_id)
    REFERENCES folha.employer (account_id, employer_id),
  CONSTRAINT rubric_rule_agreement_fk FOREIGN KEY (account_id, agreement_id)
    REFERENCES folha.collective_agreement (account_id, agreement_id),
  CONSTRAINT rubric_rule_contract_fk FOREIGN KEY (account_id, contract_id)
    REFERENCES folha.employment_contract (account_id, contract_id),
  CONSTRAINT rubric_rule_vigencia_valida CHECK (vigencia_fim IS NULL OR vigencia_fim >= vigencia_inicio),
  CONSTRAINT rubric_rule_alcance_da_camada CHECK (
       (camada = 'empresa'   AND employer_id IS NOT NULL AND agreement_id IS NULL AND contract_id IS NULL)
    OR (camada = 'convencao' AND agreement_id IS NOT NULL AND employer_id IS NULL AND contract_id IS NULL)
    OR (camada = 'contrato'  AND contract_id IS NOT NULL AND employer_id IS NULL AND agreement_id IS NULL)),
  CONSTRAINT rubric_rule_forma_coerente CHECK (
       (forma_calculo = 'valor_fixo'       AND valor IS NOT NULL AND percentual IS NULL AND base_id IS NULL AND valor_unitario IS NULL AND formula IS NULL)
    OR (forma_calculo = 'percentual_base'  AND percentual IS NOT NULL AND base_id IS NOT NULL AND valor IS NULL AND valor_unitario IS NULL AND formula IS NULL)
    OR (forma_calculo = 'quantidade_valor' AND valor_unitario IS NOT NULL AND valor IS NULL AND percentual IS NULL AND base_id IS NULL AND formula IS NULL)
    OR (forma_calculo = 'formula'          AND formula IS NOT NULL AND valor IS NULL AND percentual IS NULL AND base_id IS NULL AND valor_unitario IS NULL)),
  CONSTRAINT rubric_rule_formula_valida CHECK (formula IS NULL OR folha.formula_valida(formula)),
  CONSTRAINT rubric_rule_formula_tamanho CHECK (formula IS NULL OR pg_column_size(formula) <= 4000),
  -- Lançamento automático precisa de valor que não dependa de quantidade informada.
  CONSTRAINT rubric_rule_automatica_sem_quantidade CHECK (NOT automatica OR forma_calculo <> 'quantidade_valor'),
  CONSTRAINT rubric_rule_automatica_sem_variavel_de_lancamento
    CHECK (NOT automatica OR formula IS NULL OR formula::text !~ '"var": "(QUANTIDADE|VALOR)"'),
  CONSTRAINT rubric_rule_sem_sobreposicao EXCLUDE USING gist (
    code_id WITH =,
    (COALESCE(employer_id, agreement_id, contract_id)) WITH =,
    daterange(vigencia_inicio, vigencia_fim, '[]') WITH &&)
);
CREATE INDEX idx_rubric_rule_employer ON folha.rubric_rule (account_id, employer_id) WHERE employer_id IS NOT NULL;
CREATE INDEX idx_rubric_rule_agreement ON folha.rubric_rule (account_id, agreement_id) WHERE agreement_id IS NOT NULL;
CREATE INDEX idx_rubric_rule_contract ON folha.rubric_rule (account_id, contract_id) WHERE contract_id IS NOT NULL;
CREATE TRIGGER trg_rubric_rule_conta
  BEFORE INSERT OR UPDATE ON folha.rubric_rule
  FOR EACH ROW EXECUTE FUNCTION folha.exigir_rubrica_da_conta('visivel');

-- ===========================================================================
-- 4. Lançamentos, afastamentos e outros vínculos
-- ===========================================================================
CREATE TABLE folha.payroll_entry (
  entry_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  contract_id uuid NOT NULL,
  code_id uuid NOT NULL REFERENCES folha.earning_deduction_code (code_id),
  competencia date NOT NULL CHECK (EXTRACT(DAY FROM competencia) = 1),
  tipo_processo text NOT NULL DEFAULT 'mensal' CHECK (tipo_processo IN ('mensal', 'adiantamento', 'complementar')),
  quantidade numeric(12,4) CHECK (quantidade >= 0),
  valor numeric(14,2) CHECK (valor >= 0),
  origem text NOT NULL DEFAULT 'digitacao' CHECK (origem IN ('digitacao', 'importacao', 'ponto', 'api')),
  observacao text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT payroll_entry_contract_fk FOREIGN KEY (account_id, contract_id)
    REFERENCES folha.employment_contract (account_id, contract_id),
  CONSTRAINT payroll_entry_com_valor_ou_quantidade CHECK (quantidade IS NOT NULL OR valor IS NOT NULL)
);
CREATE INDEX idx_payroll_entry_contrato ON folha.payroll_entry (account_id, contract_id, competencia, tipo_processo);
CREATE TRIGGER trg_payroll_entry_conta
  BEFORE INSERT OR UPDATE ON folha.payroll_entry
  FOR EACH ROW EXECUTE FUNCTION folha.exigir_rubrica_da_conta('visivel');

-- Afastamento: quem cadastra diz se os dias suspendem o pagamento pelo empregador; o motor
-- não decide a regra de cada motivo (não está nos pareceres).
CREATE TABLE folha.contract_leave (
  leave_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  contract_id uuid NOT NULL,
  data_inicio date NOT NULL,
  data_fim date,
  motivo text NOT NULL CHECK (btrim(motivo) <> ''),
  suspende_pagamento boolean NOT NULL,
  observacao text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT contract_leave_contract_fk FOREIGN KEY (account_id, contract_id)
    REFERENCES folha.employment_contract (account_id, contract_id),
  CONSTRAINT contract_leave_periodo_valido CHECK (data_fim IS NULL OR data_fim >= data_inicio),
  CONSTRAINT contract_leave_sem_sobreposicao EXCLUDE USING gist (
    contract_id WITH =, daterange(data_inicio, data_fim, '[]') WITH &&)
);

-- Remuneração de outros vínculos no mês, informada pelo trabalhador (base de INSS já usada
-- em outra fonte).
CREATE TABLE folha.external_remuneration (
  external_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  employee_id uuid NOT NULL,
  competencia date NOT NULL CHECK (EXTRACT(DAY FROM competencia) = 1),
  base_previdencia numeric(14,2) NOT NULL CHECK (base_previdencia >= 0),
  origem text NOT NULL CHECK (btrim(origem) <> ''),            -- identificação da outra fonte pagadora
  documento_prova text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT external_remuneration_employee_fk FOREIGN KEY (account_id, employee_id)
    REFERENCES folha.employee (account_id, employee_id),
  UNIQUE (account_id, employee_id, competencia, origem)
);

-- ===========================================================================
-- 5. Folha: tipo de processo, várias por competência, itens, bases e pendências
-- ===========================================================================
ALTER TABLE folha.payroll_run
  ADD COLUMN tipo_processo text NOT NULL DEFAULT 'mensal'
    CONSTRAINT payroll_run_tipo_processo_check CHECK (tipo_processo IN (
      'mensal', 'adiantamento', 'complementar', 'decimo_terceiro_1', 'decimo_terceiro_2', 'ferias', 'rescisao')),
  ADD COLUMN sequencia integer NOT NULL DEFAULT 1
    CONSTRAINT payroll_run_sequencia_check CHECK (sequencia > 0),
  ADD CONSTRAINT payroll_run_competencia_dia_1 CHECK (EXTRACT(DAY FROM competencia) = 1);

-- A unicidade da 0014 (uma folha por conta e competência) dá lugar a uma folha por conta,
-- empregador, competência, tipo de processo e sequência.
DO $$
DECLARE
  v_nome text;
BEGIN
  FOR v_nome IN
    SELECT con.conname FROM pg_catalog.pg_constraint con
     WHERE con.conrelid = 'folha.payroll_run'::regclass AND con.contype = 'u'
       AND pg_catalog.pg_get_constraintdef(con.oid) = 'UNIQUE (account_id, competencia)'
  LOOP
    EXECUTE format('ALTER TABLE folha.payroll_run DROP CONSTRAINT %I', v_nome);
  END LOOP;
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_constraint con
              WHERE con.conrelid = 'folha.payroll_run'::regclass AND con.contype = 'u'
                AND pg_catalog.pg_get_constraintdef(con.oid) = 'UNIQUE (account_id, competencia)') THEN
    RAISE EXCEPTION '0026: a unicidade antiga de payroll_run não foi removida';
  END IF;
END
$$;
CREATE UNIQUE INDEX payroll_run_processo_key ON folha.payroll_run (
  account_id, (COALESCE(employer_id, '00000000-0000-0000-0000-000000000000'::uuid)),
  competencia, tipo_processo, sequencia);

-- Entradas dos processos que não são a folha de rubricas do mês (13º, férias, rescisão):
-- os argumentos das funções da 0023, por folha e contrato.
CREATE TABLE folha.payroll_process_input (
  input_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  run_id uuid NOT NULL,
  contract_id uuid NOT NULL,
  parametros jsonb NOT NULL CHECK (jsonb_typeof(parametros) = 'object'),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT payroll_process_input_run_fk FOREIGN KEY (account_id, run_id)
    REFERENCES folha.payroll_run (account_id, run_id),
  CONSTRAINT payroll_process_input_contract_fk FOREIGN KEY (account_id, contract_id)
    REFERENCES folha.employment_contract (account_id, contract_id),
  UNIQUE (run_id, contract_id)
);

-- Linhas do resultado por rubrica, com a origem da regra.
CREATE TABLE folha.payroll_result_item (
  item_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  account_id uuid NOT NULL,
  result_id uuid NOT NULL,
  code_id uuid NOT NULL REFERENCES folha.earning_deduction_code (code_id),
  rubrica_codigo text NOT NULL,
  tipo_rubrica text NOT NULL CHECK (tipo_rubrica IN ('provento', 'desconto', 'informativa', 'base')),
  ordem integer NOT NULL,
  quantidade numeric(12,4),
  base_calculo numeric(14,2),
  aliquota numeric(12,6),
  valor numeric(14,2) NOT NULL CHECK (valor >= 0),
  camada_regra text NOT NULL CHECK (camada_regra IN ('motor', 'lancamento', 'empresa', 'convencao', 'contrato')),
  rule_id uuid REFERENCES folha.rubric_rule (rule_id),
  entry_id uuid REFERENCES folha.payroll_entry (entry_id),
  detalhe jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT payroll_result_item_result_fk FOREIGN KEY (account_id, result_id)
    REFERENCES folha.payroll_result (account_id, result_id),
  CONSTRAINT payroll_result_item_regra_da_camada
    CHECK ((camada_regra IN ('empresa', 'convencao', 'contrato')) = (rule_id IS NOT NULL)),
  UNIQUE (result_id, ordem)
);

-- O item aponta o lançamento que o gerou (entry_id). Lançamento já pago por folha não
-- cancelada não é alterado nem apagado, e o motor não o paga de novo em outra folha.
CREATE FUNCTION folha.payroll_entry_consumido() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, folha
SET row_security = off
AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM folha.payroll_result_item i
               JOIN folha.payroll_result pr ON pr.result_id = i.result_id
               JOIN folha.payroll_run r ON r.run_id = pr.run_id
              WHERE i.entry_id = OLD.entry_id AND r.status <> 'cancelled') THEN
    RAISE EXCEPTION 'Lançamento % já foi calculado em folha não cancelada e não pode ser alterado nem apagado', OLD.entry_id;
  END IF;
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER trg_payroll_entry_consumido
  BEFORE UPDATE OR DELETE ON folha.payroll_entry
  FOR EACH ROW EXECUTE FUNCTION folha.payroll_entry_consumido();
CREATE INDEX idx_payroll_result_item_entry ON folha.payroll_result_item (entry_id) WHERE entry_id IS NOT NULL;

-- Bases apuradas no resultado.
CREATE TABLE folha.payroll_result_base (
  account_id uuid NOT NULL,
  result_id uuid NOT NULL,
  base_id uuid NOT NULL REFERENCES folha.calculation_base (base_id),
  base_codigo text NOT NULL,
  valor numeric(14,2) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (result_id, base_id),
  CONSTRAINT payroll_result_base_result_fk FOREIGN KEY (account_id, result_id)
    REFERENCES folha.payroll_result (account_id, result_id)
);

-- Memória de cálculo: de qual camada veio a regra de cada passo.
ALTER TABLE folha.calculation_trace
  ADD COLUMN camada_regra text
    CONSTRAINT calculation_trace_camada_regra_check
      CHECK (camada_regra IN ('motor', 'lancamento', 'empresa', 'convencao', 'contrato')),
  ADD COLUMN rule_id uuid REFERENCES folha.rubric_rule (rule_id);

-- Pendências como dado. tipo:
--   a_validar   = regra ou parâmetro não conferido na fonte: liberável, com responsável e motivo;
--   conferencia = aviso das funções de cálculo que pede conferência humana (ex.: INSS provisório
--                 do recibo de férias): liberável, com responsável e motivo;
--   pendencia   = o valor calculado está sabidamente errado ou incompleto (ex.: salário sem
--                 abater o gozo de férias): NÃO é liberável; some corrigindo e recalculando.
-- Com pendência aberta, a folha não é aprovada nem fechada (trava na 0027).
CREATE TABLE folha.payroll_pendency (
  pendency_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  run_id uuid NOT NULL,
  result_id uuid NOT NULL,
  contract_id uuid NOT NULL,
  codigo text NOT NULL CHECK (btrim(codigo) <> ''),
  tipo text NOT NULL CHECK (tipo IN ('a_validar', 'conferencia', 'pendencia')),
  created_at timestamptz NOT NULL DEFAULT now(),
  liberada_em timestamptz,
  liberada_por text,
  liberada_sessao text,
  liberacao_motivo text,
  CONSTRAINT payroll_pendency_run_fk FOREIGN KEY (account_id, run_id)
    REFERENCES folha.payroll_run (account_id, run_id),
  CONSTRAINT payroll_pendency_result_fk FOREIGN KEY (account_id, result_id)
    REFERENCES folha.payroll_result (account_id, result_id),
  CONSTRAINT payroll_pendency_contract_fk FOREIGN KEY (account_id, contract_id)
    REFERENCES folha.employment_contract (account_id, contract_id),
  CONSTRAINT payroll_pendency_liberacao_completa CHECK (
    (liberada_em IS NULL AND liberada_por IS NULL AND liberada_sessao IS NULL AND liberacao_motivo IS NULL)
    OR (liberada_em IS NOT NULL AND btrim(COALESCE(liberada_por, '')) <> ''
        AND liberada_sessao IS NOT NULL AND btrim(COALESCE(liberacao_motivo, '')) <> '')),
  UNIQUE (result_id, codigo)
);
CREATE INDEX idx_payroll_pendency_aberta ON folha.payroll_pendency (account_id, run_id) WHERE liberada_em IS NULL;

-- ===========================================================================
-- 6. Vigências abertas (bloqueio de produção 3)
--    As tabelas de INSS, de salário mínimo e do IRRF de 2026 da 0015 não tinham fim de
--    vigência: competência ou pagamento de 2027 seria calculado com os valores de 2026 sem
--    erro. Fecham em 31/12/2026; sem a tabela do ano, o motor levanta "Tabela INSS não
--    encontrada" / "Tabela IRRF não encontrada". A tabela do IRRF não muda todo ano por regra,
--    mas quem diz que a de 2026 vale em 2027 é quem cadastra a de 2027, com o ato.
-- ===========================================================================
DO $$
DECLARE
  v_linhas integer;
BEGIN
  UPDATE folha.tax_table_version
     SET vigencia_fim = '2026-12-31'
   WHERE tipo IN ('inss', 'salario_minimo', 'irrf')
     AND vigencia_inicio = '2026-01-01'
     AND vigencia_fim IS NULL;
  GET DIAGNOSTICS v_linhas = ROW_COUNT;
  IF EXISTS (SELECT 1 FROM folha.tax_table_version
              WHERE tipo IN ('inss', 'salario_minimo', 'irrf') AND vigencia_fim IS NULL) THEN
    RAISE EXCEPTION '0026: ainda há tabela de INSS, de salário mínimo ou de IRRF com vigência aberta (linhas fechadas: %)', v_linhas
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
END
$$;

-- ===========================================================================
-- 7. Rubricas: migração das da 0017 e rubricas dos processos
-- ===========================================================================
-- 7.1 Rubricas novas dos processos (globais). As incidências entram em 7.3.
INSERT INTO folha.earning_deduction_code
  (codigo, descricao, natureza, incidencia_inss, incidencia_irrf, incidencia_fgts, is_global) VALUES
  ('ADIANTAMENTO_SALARIAL_PAGO',  'Adiantamento salarial pago (folha de adiantamento)',           'provento', false, false, false, true),
  ('FERIAS_GOZO',                 'Férias gozadas',                                               'provento', true,  true,  true,  true),
  ('FERIAS_TERCO',                'Terço constitucional das férias gozadas',                      'provento', true,  true,  true,  true),
  ('ABONO_PECUNIARIO_TERCO',      'Terço do abono pecuniário de férias',                          'provento', false, false, false, true),
  ('FERIAS_DOBRA',                'Dobra de férias gozadas fora do período concessivo',           'provento', false, false, false, true),
  ('RESC_INDENIZACAO_ART479',     'Indenização do art. 479 da CLT (rescisão antecipada)',         'provento', false, false, false, true),
  ('INSS_13_SALARIO',             'INSS do segurado sobre o 13º salário',                         'desconto', false, false, false, true),
  ('IRRF_13_SALARIO',             'IRRF sobre o 13º salário (em separado)',                       'desconto', false, false, false, true),
  ('IRRF_FERIAS',                 'IRRF sobre férias (em separado)',                              'desconto', false, false, false, true),
  ('DECIMO_TERCEIRO_ADIANT_COMP', 'Adiantamento do 13º salário compensado',                       'desconto', false, false, false, true),
  ('RESC_DESCONTO_AVISO_PREVIO',  'Aviso prévio não cumprido pelo empregado',                     'desconto', false, false, false, true),
  ('RESC_DESCONTO_ART480',        'Indenização do art. 480 da CLT (rescisão antecipada pelo empregado)', 'desconto', false, false, false, true);

-- 7.2 Tipo, forma de cálculo e ordem.
UPDATE folha.earning_deduction_code e
   SET tipo_rubrica = CASE
         WHEN e.codigo IN ('BASE_INSS', 'BASE_IRRF', 'BASE_FGTS') THEN 'base'
         WHEN e.natureza = 'provento' THEN 'provento'
         WHEN e.natureza = 'desconto' THEN 'desconto'
         ELSE 'informativa' END,
       updated_at = now()
 WHERE e.tipo_rubrica IS NULL;

ALTER TABLE folha.earning_deduction_code
  ALTER COLUMN tipo_rubrica SET NOT NULL;

UPDATE folha.earning_deduction_code e
   SET forma_calculo = 'apuracao_motor', updated_at = now()
 WHERE e.account_id IS NULL
   AND e.codigo IN (
     'SALARIO_BASE', 'SALARIO_FAMILIA', 'INSS_EMPREGADO', 'IRRF', 'ADIANTAMENTO_SALARIAL',
     'FGTS_DEPOSITO', 'FGTS_MULTA_RESCISORIA', 'INSS_PATRONAL', 'RAT_SAT', 'TERCEIROS',
     'BASE_INSS', 'BASE_IRRF', 'BASE_FGTS',
     'DECIMO_TERCEIRO_1A', 'DECIMO_TERCEIRO_2A', 'INSS_13_SALARIO', 'IRRF_13_SALARIO', 'DECIMO_TERCEIRO_ADIANT_COMP',
     'FERIAS_GOZO', 'FERIAS_TERCO', 'ABONO_PECUNIARIO', 'ABONO_PECUNIARIO_TERCO', 'FERIAS_DOBRA', 'IRRF_FERIAS',
     'FERIAS_VENCIDAS', 'FERIAS_PROPORCIONAL',
     'AVISO_PREVIO_INDENIZADO', 'RESC_SALDO_SALARIO', 'RESC_DECIMO_TERCEIRO_PROP', 'RESC_FERIAS_PROP',
     'RESC_FERIAS_VENCIDAS', 'RESC_INDENIZACAO_ART479', 'RESC_DESCONTO_AVISO_PREVIO', 'RESC_DESCONTO_ART480');

UPDATE folha.earning_deduction_code e
   SET ordem_calculo = CASE
         WHEN e.codigo = 'SALARIO_BASE' THEN 10
         WHEN e.codigo = 'SALARIO_FAMILIA' THEN 700
         WHEN e.codigo IN ('INSS_EMPREGADO', 'INSS_13_SALARIO') THEN 800
         WHEN e.codigo IN ('IRRF', 'IRRF_13_SALARIO', 'IRRF_FERIAS') THEN 810
         WHEN e.tipo_rubrica = 'provento' THEN 100
         WHEN e.tipo_rubrica = 'desconto' THEN 300
         ELSE 900 END,
       updated_at = now()
 WHERE e.account_id IS NULL;

-- 7.3 Incidência por código. Deriva dos booleanos da 0014/0017 (já corrigidos pela 0023),
--     com a base própria para 13º e férias. Início em 01/01/2024 = início da cobertura do
--     motor (primeiras tabelas), não da norma.
INSERT INTO folha.rubric_incidence (account_id, code_id, tributo, incidencia_codigo, vigencia_inicio, fonte)
SELECT e.account_id, e.code_id, t.tributo,
       CASE
         WHEN t.tributo = 'previdencia' AND e.codigo IN ('INSS_EMPREGADO', 'INSS_13_SALARIO') THEN 'RETENCAO_SEGURADO'
         WHEN t.tributo = 'irrf' AND e.codigo IN ('IRRF', 'IRRF_13_SALARIO', 'IRRF_FERIAS') THEN 'RETENCAO'
         WHEN NOT t.incide THEN 'NAO_INCIDE'
         WHEN e.codigo IN ('DECIMO_TERCEIRO_1A', 'DECIMO_TERCEIRO_2A', 'RESC_DECIMO_TERCEIRO_PROP') THEN 'BASE_13'
         WHEN t.tributo = 'irrf' AND e.codigo IN ('FERIAS_GOZO', 'FERIAS_TERCO', 'FERIAS_VENCIDAS', 'FERIAS_PROPORCIONAL') THEN 'BASE_FERIAS'
         ELSE 'BASE_MENSAL'
       END,
       '2024-01-01',
       'Derivado dos indicadores das migrations 0017 e 0023 [0026]'
  FROM folha.earning_deduction_code e
  CROSS JOIN LATERAL (VALUES
    ('previdencia', e.incidencia_inss), ('irrf', e.incidencia_irrf), ('fgts', e.incidencia_fgts)
  ) AS t(tributo, incide);

-- 7.3.1 Estado de validação. As incidências derivadas dos indicadores das 0017/0023 entram
--       como validadas (conferidas nos pareceres, não nos atos). Ficam a_validar, sem que esta
--       migration decida a regra: IRRF da multa do art. 477; o terço do abono pecuniário; a
--       previdência sobre o terço de férias gozadas (base da contribuição patronal); e as três
--       incidências que o motor da 0023 decide por parâmetro a_validar (previdência do aviso
--       indenizado, IRRF do abono e IRRF da dobra).
UPDATE folha.rubric_incidence SET status_validacao = 'validado';
DO $$
DECLARE
  v_linhas integer;
BEGIN
  UPDATE folha.rubric_incidence ri
     SET status_validacao = 'a_validar'
    FROM folha.earning_deduction_code e
   WHERE e.code_id = ri.code_id AND e.account_id IS NULL
     AND (   (e.codigo = 'MULTA_ART477' AND ri.tributo = 'irrf')
          OR (e.codigo = 'ABONO_PECUNIARIO_TERCO')
          OR (e.codigo = 'FERIAS_TERCO' AND ri.tributo = 'previdencia')
          OR (e.codigo = 'AVISO_PREVIO_INDENIZADO' AND ri.tributo = 'previdencia')
          OR (e.codigo IN ('ABONO_PECUNIARIO', 'FERIAS_DOBRA') AND ri.tributo = 'irrf'));
  GET DIAGNOSTICS v_linhas = ROW_COUNT;
  IF v_linhas <> 8 THEN
    RAISE EXCEPTION '0026: esperava marcar 8 incidências como a_validar; marcou %', v_linhas;
  END IF;

  -- Rubricas legadas da 0017 que juntam férias e terço e não distinguem gozadas de
  -- indenizadas: nenhum processo as emite. Ficam inativas (não são apagadas).
  UPDATE folha.earning_deduction_code
     SET ativa = false, updated_at = now()
   WHERE account_id IS NULL AND codigo IN ('FERIAS_VENCIDAS', 'FERIAS_PROPORCIONAL');
  GET DIAGNOSTICS v_linhas = ROW_COUNT;
  IF v_linhas <> 2 THEN
    RAISE EXCEPTION '0026: esperava desativar 2 rubricas legadas; desativou %', v_linhas;
  END IF;
END
$$;

-- 7.4 Rubrica x base: cada incidência que compõe base liga a rubrica à base do código; o
--     salário de contribuição do mês também afere o salário-família, exceto o terço de férias.
INSERT INTO folha.rubric_base (account_id, code_id, base_id, vigencia_inicio)
SELECT ri.account_id, ri.code_id, ic.base_id, ri.vigencia_inicio
  FROM folha.rubric_incidence ri
  JOIN folha.incidence_code ic ON ic.tributo = ri.tributo AND ic.codigo = ri.incidencia_codigo
 WHERE ic.efeito = 'compoe_base';

INSERT INTO folha.rubric_base (account_id, code_id, base_id, vigencia_inicio)
SELECT ri.account_id, ri.code_id,
       (SELECT b.base_id FROM folha.calculation_base b WHERE b.account_id IS NULL AND b.codigo = 'SALARIO_FAMILIA'),
       ri.vigencia_inicio
  FROM folha.rubric_incidence ri
  JOIN folha.earning_deduction_code e ON e.code_id = ri.code_id
 WHERE ri.tributo = 'previdencia' AND ri.incidencia_codigo = 'BASE_MENSAL'
   AND e.codigo <> 'FERIAS_TERCO';

-- Faltas e atrasos são descontos que reduzem a remuneração: passam a reduzir as bases do mês
-- (o parecer de INSS/FGTS, E-04, aponta que as faltas não entravam no salário de contribuição).
-- Não reduzem a base do salário-família: o direito é aferido pela remuneração que seria devida
-- no mês, independentemente dos dias trabalhados (portarias, art. 4º, § 2º, no parecer).
DO $$
DECLARE
  v_linhas integer;
BEGIN
  UPDATE folha.rubric_incidence ri
     SET incidencia_codigo = 'BASE_MENSAL',
         fonte = 'Parecer INSS/FGTS E-04: faltas e atrasos reduzem as bases do mês [0026]'
    FROM folha.earning_deduction_code e
   WHERE e.code_id = ri.code_id AND e.account_id IS NULL AND e.codigo IN ('FALTAS', 'ATRASOS');
  GET DIAGNOSTICS v_linhas = ROW_COUNT;
  IF v_linhas <> 6 THEN
    RAISE EXCEPTION '0026: esperava ajustar 6 incidências de FALTAS e ATRASOS; ajustou %', v_linhas;
  END IF;
  INSERT INTO folha.rubric_base (account_id, code_id, base_id, vigencia_inicio)
  SELECT NULL, e.code_id, b.base_id, '2024-01-01'
    FROM folha.earning_deduction_code e
    CROSS JOIN folha.calculation_base b
   WHERE e.account_id IS NULL AND e.codigo IN ('FALTAS', 'ATRASOS')
     AND b.account_id IS NULL AND b.codigo IN ('INSS_MENSAL', 'IRRF_MENSAL', 'FGTS_MENSAL');
END
$$;

-- ===========================================================================
-- 8. RLS (ENABLE + FORCE), policies e ACL
--    Tabelas por conta: mesma policy da 0024. Tabelas com linha global (conta nula): leitura
--    da própria conta e do global, escrita só da própria conta (como a rubrica, 0014/0025).
--    Catálogos globais: só leitura; quem grava é o dono, por migration.
--    ACL: tira tudo de todo papel que não seja o dono antes de conceder.
-- ===========================================================================
DO $$
DECLARE
  v_item text[];
  v_tabela text;
  v_papel text;
BEGIN
  FOREACH v_item SLICE 1 IN ARRAY ARRAY[
    -- tabela,                  modelo,   privilégios do worker
    ['calculation_base',        'global_ou_conta', 'SELECT, INSERT, UPDATE'],
    ['rubric_incidence',        'global_ou_conta', 'SELECT, INSERT, UPDATE'],
    ['rubric_esocial_nature',   'global_ou_conta', 'SELECT, INSERT, UPDATE'],
    ['rubric_base',             'global_ou_conta', 'SELECT, INSERT, UPDATE'],
    ['rubric_rule',             'conta',           'SELECT, INSERT, UPDATE'],
    ['payroll_entry',           'conta',           'SELECT, INSERT, UPDATE, DELETE'],
    ['contract_leave',          'conta',           'SELECT, INSERT, UPDATE'],
    ['external_remuneration',   'conta',           'SELECT, INSERT, UPDATE'],
    ['payroll_process_input',   'conta',           'SELECT, INSERT, UPDATE'],
    ['payroll_result_item',     'conta',           'SELECT'],
    ['payroll_result_base',     'conta',           'SELECT'],
    ['payroll_pendency',        'conta',           'SELECT'],
    ['incidence_code',          'catalogo',        'SELECT'],
    ['esocial_rubric_nature',   'catalogo',        'SELECT'],
    ['rule_layer',              'catalogo',        'SELECT']
  ]
  LOOP
    v_tabela := v_item[1];
    EXECUTE format('ALTER TABLE folha.%I ENABLE ROW LEVEL SECURITY', v_tabela);
    EXECUTE format('ALTER TABLE folha.%I FORCE ROW LEVEL SECURITY', v_tabela);
    IF v_item[2] = 'conta' THEN
      EXECUTE format(
        'CREATE POLICY %I ON folha.%I
           USING (account_id = (SELECT folha.current_account_id()))
           WITH CHECK (account_id = (SELECT folha.current_account_id()))',
        v_tabela || '_isolamento', v_tabela);
    ELSIF v_item[2] = 'global_ou_conta' THEN
      EXECUTE format(
        'CREATE POLICY %I ON folha.%I
           USING (account_id = (SELECT folha.current_account_id()) OR account_id IS NULL)
           WITH CHECK (account_id = (SELECT folha.current_account_id()))',
        v_tabela || '_isolamento', v_tabela);
    ELSE
      EXECUTE format('CREATE POLICY %I ON folha.%I FOR SELECT USING (true)', v_tabela || '_leitura', v_tabela);
    END IF;

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
    EXECUTE format('GRANT %s ON folha.%I TO dnex_gestao_folha_worker', v_item[3], v_tabela);
    EXECUTE format('GRANT SELECT ON folha.%I TO dnex_gestao_data_owner', v_tabela);
  END LOOP;

  -- Funções de trigger: ninguém além do dono as executa diretamente. O validador de
  -- fórmula roda dentro do CHECK de rubric_rule com o privilégio de quem grava: o worker
  -- precisa do EXECUTE.
  FOREACH v_tabela IN ARRAY ARRAY[
    'folha.rubrica_derivar_tipo()', 'folha.exigir_rubrica_da_conta()', 'folha.conta_imutavel()',
    'folha.payroll_entry_consumido()',
    'folha.formula_valida(jsonb, integer)'
  ]
  LOOP
    FOR v_papel IN
      SELECT CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(r.rolname) END
        FROM pg_catalog.pg_proc p
        CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
        LEFT JOIN pg_catalog.pg_roles r ON r.oid = a.grantee
       WHERE p.oid = v_tabela::regprocedure AND a.grantee <> p.proowner
       GROUP BY 1
    LOOP
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM %s', v_tabela, v_papel);
    END LOOP;
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated, service_role', v_tabela);
  END LOOP;
  GRANT EXECUTE ON FUNCTION folha.formula_valida(jsonb, integer) TO dnex_gestao_folha_worker;
END
$$;

COMMIT;
