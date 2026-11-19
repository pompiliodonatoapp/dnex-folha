-- DNEX Folha — Migration 0032: camada que ALIMENTA os geradores de XML do eSocial.
--
-- Contrato de saída: o do gerador já mesclado no dnex-contador (packages/esocial/contracts/
-- entrada-evento.schema.json, commit e0d3ffb): envelope {evento, ambiente, emissao, empregador,
-- dados}, dinheiro como texto decimal, schema estrito. Mapeamento e lista do que a Folha precisa
-- fornecer: packages/esocial/docs/GERACAO-EVENTOS-S13.md. Requisito de origem: parecer eSocial/Reinf
-- de 15/11/2026 (item 2: o que falta no cadastro). Decisões e limites: docs/02-decisoes/
-- ADR-entrada-eventos-esocial.md.
--
-- O QUE ESTA MIGRATION FAZ
--   1. Estrutura das tabelas oficiais do eSocial (folha.esocial_domain_code): número da tabela, campo,
--      código, descrição, vigência, fonte e situação de validação. SÓ entra o que o XSD S-1.3 local
--      enumera (tpRubr, codIncCP, codIncFGTS, grauInstr, racaCor), com arquivo e linha na fonte. As
--      Tabelas 01 (categoria), 03 (natureza, estrutura própria da 0026), 10 (lotação), 19 (desligamento)
--      e 21 (incidência do IRRF) ficam VAZIAS: o leiaute local não as enumera. Onde a tabela está
--      carregada, o código informado é conferido por gatilho; onde está vazia, a função devolve
--      pendência (não bloqueia e não inventa).
--   2. Lacunas de cadastro que os geradores exigem e a Folha não tinha: dados do empregador por
--      vigência (S-1000), do estabelecimento (S-1005: responsável, RAT, CAEPF/obra), da lotação
--      (S-1020: inscrição, Terceiros suspensos), da rubrica por empregador (S-1010: codRubr, ideTabRubr
--      e validade), do trabalhador (endereço com código IBGE, raça/cor, grau de instrução, país de
--      nascimento, deficiência), dos dependentes, do vínculo (matrícula, categoria, CBO, sindicato,
--      jornada, tipo de contrato, FGTS) e do desligamento (motivo por CÓDIGO da Tabela 19).
--      Reusa o que existia: employer, establishment, establishment_fap, tax_allocation(_detail),
--      contract_tax_allocation, rubric_incidence, incidence_code, rubric_esocial_nature, payroll_result_item.
--   3. Dois registros que não existiam: o demonstrativo (ideDmDev estável por resultado da folha) e o
--      pagamento efetivo (data, tipo e valor líquido), base do S-1210.
--   4. Funções folha.esocial_entrada_*_v1 (EXECUTE só para dnex_gestao_api; contexto pelo protocolo
--      da 0028) que devolvem jsonb: estado (pronto, incompleto, bloqueado), a entrada no contrato do
--      gerador, o que falta (caminhos), os bloqueios e as pendências. Registram o evento na fila da 0031
--      como rascunho, com origem_hash, sem gerar XML. S-1000, S-1005, S-1010 e S-1020 (inclusão),
--      S-1200, S-1210, S-2200, S-1298, S-1299 e S-3000.
--
-- NÃO GERA XML, NÃO ASSINA, NÃO TRANSMITE, NÃO USA REDE. NÃO altera as migrations 0014 a 0031.
-- NÃO APLICAR EM PRODUÇÃO sem as dependências das 0024 a 0031 e sem revisão do DP e do jurídico (ADR).
-- Reversão: 0032_folha_entrada_eventos_esocial.supabase.down.sql.
BEGIN;

SET LOCAL lock_timeout = '5s';

-- ---------------------------------------------------------------------------
-- 0. Pré-condições (falha limpa, antes de qualquer alteração)
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
      ('folha.esocial_evento_incluir (migration 0031)',
         to_regprocedure('folha.esocial_evento_incluir(uuid, uuid, text, text, jsonb, text, jsonb, uuid, uuid, text)') IS NULL),
      ('folha.esocial_imutavel() (migration 0031)', to_regprocedure('folha.esocial_imutavel()') IS NULL),
      ('folha.esocial_sem_truncate() (migration 0031)', to_regprocedure('folha.esocial_sem_truncate()') IS NULL),
      ('folha.esocial_periodo_fechado (migration 0031)',
         to_regprocedure('folha.esocial_periodo_fechado(uuid, uuid, text, smallint, date)') IS NULL),
      ('folha.exigir_rubrica_da_conta() (migration 0026)', to_regprocedure('folha.exigir_rubrica_da_conta()') IS NULL),
      ('folha.esocial_event (migration 0031)', to_regclass('folha.esocial_event') IS NULL),
      ('folha.payroll_result_item (migration 0026)', to_regclass('folha.payroll_result_item') IS NULL),
      ('folha.contract_tax_allocation (migration 0024)', to_regclass('folha.contract_tax_allocation') IS NULL),
      ('folha.esocial_rubric_nature (migration 0026)', to_regclass('folha.esocial_rubric_nature') IS NULL),
      ('índice employment_contract_account_employer_contract_key (migration 0024)',
         to_regclass('folha.employment_contract_account_employer_contract_key') IS NULL),
      ('índice employment_contract_account_contract_key (migration 0026)',
         to_regclass('folha.employment_contract_account_contract_key') IS NULL)
    ) AS x(nome, ausente)
   WHERE x.ausente;
  IF v_faltando IS NOT NULL THEN
    RAISE EXCEPTION '0032: faltam objetos: %', v_faltando
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  -- As funções leem e gravam com row_security = off e filtro explícito de conta.
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles
                  WHERE rolname = current_user AND (rolsuper OR rolbypassrls)) THEN
    RAISE EXCEPTION '0032: o papel % não é superusuário nem tem BYPASSRLS', current_user
      USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF to_regclass('folha.esocial_domain_code') IS NOT NULL THEN
    RAISE EXCEPTION '0032: folha.esocial_domain_code já existe' USING ERRCODE = 'duplicate_table';
  END IF;
END
$$;

-- ===========================================================================
-- 1. Tabelas oficiais do eSocial: SÓ A ESTRUTURA, com o que o XSD local enumera
-- ===========================================================================
-- tabela_numero: número da tabela do eSocial quando o leiaute o cita; 'XSD' quando o código vem só de
-- uma enumeração do XSD sem número de tabela no leiaute. campo: elemento do leiaute ao qual o código
-- pertence (chave de consulta). vigencia_*: o XSD não traz vigência por código (nulas = não informada
-- na fonte). Tabela de domínio sem linha para o campo = tabela NÃO carregada.
CREATE TABLE folha.esocial_domain_code (
  domain_code_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tabela_numero text NOT NULL CHECK (tabela_numero ~ '^([0-9]{2}|XSD)$'),
  campo text NOT NULL CHECK (btrim(campo) <> ''),
  codigo text NOT NULL CHECK (btrim(codigo) <> ''),
  descricao text NOT NULL CHECK (btrim(descricao) <> ''),
  vigencia_inicio date,
  vigencia_fim date,
  fonte text NOT NULL CHECK (btrim(fonte) <> ''),
  status_validacao text NOT NULL DEFAULT 'a_validar' CHECK (status_validacao IN ('validado', 'a_validar')),
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT esocial_domain_code_vigencia_valida
    CHECK (vigencia_fim IS NULL OR (vigencia_inicio IS NOT NULL AND vigencia_fim >= vigencia_inicio))
);
CREATE UNIQUE INDEX esocial_domain_code_key
  ON folha.esocial_domain_code (tabela_numero, campo, codigo, COALESCE(vigencia_inicio, '-infinity'::date));
CREATE INDEX idx_esocial_domain_code_campo ON folha.esocial_domain_code (campo, codigo);
COMMENT ON TABLE folha.esocial_domain_code IS
  'Códigos das tabelas do eSocial como ESTRUTURA. Só o que o XSD S-1.3 local enumera, com arquivo e linha; as demais (01, 03, 10, 19, 21) ficam vazias e a_validar. Sem dado de conta.';

-- Seed: enumerações lidas dos XSD (dnex-contador@e0d3ffb, packages/esocial/xsd/eventos-S-1.3-2026-10-26/).
-- A fonte de cada linha cita o arquivo e a linha do xs:enumeration.
INSERT INTO folha.esocial_domain_code (tabela_numero, campo, codigo, descricao, fonte, status_validacao)
SELECT v.t, v.c, v.k, v.d, v.f, 'validado'
  FROM (VALUES
  ('XSD', 'tpRubr', '1', 'Vencimento, provento ou pensão', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/evtTabRubrica.xsd:129 (xs:enumeration)'),
  ('XSD', 'tpRubr', '2', 'Desconto', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/evtTabRubrica.xsd:134 (xs:enumeration)'),
  ('XSD', 'tpRubr', '3', 'Informativa', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/evtTabRubrica.xsd:139 (xs:enumeration)'),
  ('XSD', 'tpRubr', '4', 'Informativa dedutora', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/evtTabRubrica.xsd:144 (xs:enumeration)'),
  ('XSD', 'codIncCP', '00', 'Não é base de cálculo', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/evtTabRubrica.xsd:159 (xs:enumeration)'),
  ('XSD', 'codIncCP', '01', 'Não é base de cálculo em função de acordos internacionais de previdência social', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/evtTabRubrica.xsd:164 (xs:enumeration)'),
  ('XSD', 'codIncCP', '11', 'Base de cálculo das contribuições sociais - Salário de contribuição:', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/evtTabRubrica.xsd:169 (xs:enumeration)'),
  ('XSD', 'codIncCP', '12', '13º salário', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/evtTabRubrica.xsd:175 (xs:enumeration)'),
  ('XSD', 'codIncCP', '13', 'Exclusiva do empregador - Mensal', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/evtTabRubrica.xsd:180 (xs:enumeration)'),
  ('XSD', 'codIncCP', '14', 'Exclusiva do empregador - 13° salário', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/evtTabRubrica.xsd:185 (xs:enumeration)'),
  ('XSD', 'codIncCP', '15', 'Exclusiva do segurado - Mensal', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/evtTabRubrica.xsd:190 (xs:enumeration)'),
  ('XSD', 'codIncCP', '16', 'Exclusiva do segurado - 13° salário', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/evtTabRubrica.xsd:195 (xs:enumeration)'),
  ('XSD', 'codIncCP', '21', 'Salário-maternidade mensal, pago pelo empregador', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/evtTabRubrica.xsd:200 (xs:enumeration)'),
  ('XSD', 'codIncCP', '22', 'Salário-maternidade 13º salário, pago pelo empregador', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/evtTabRubrica.xsd:205 (xs:enumeration)'),
  ('XSD', 'codIncCP', '25', 'Salário-maternidade mensal, pago pelo INSS', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/evtTabRubrica.xsd:210 (xs:enumeration)'),
  ('XSD', 'codIncCP', '26', 'Salário-maternidade 13° salário, pago pelo INSS', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/evtTabRubrica.xsd:215 (xs:enumeration)'),
  ('XSD', 'codIncCP', '31', 'Contribuição descontada do segurado sobre salário de contribuição:', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/evtTabRubrica.xsd:220 (xs:enumeration)'),
  ('XSD', 'codIncCP', '32', '13º salário', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/evtTabRubrica.xsd:226 (xs:enumeration)'),
  ('XSD', 'codIncCP', '34', 'SEST', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/evtTabRubrica.xsd:231 (xs:enumeration)'),
  ('XSD', 'codIncCP', '35', 'SENAT', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/evtTabRubrica.xsd:236 (xs:enumeration)'),
  ('XSD', 'codIncCP', '51', 'Outros:', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/evtTabRubrica.xsd:241 (xs:enumeration)'),
  ('XSD', 'codIncCP', '91', 'Suspensão de incidência sobre salário de contribuição em decorrência de decisão judicial:', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/evtTabRubrica.xsd:247 (xs:enumeration)'),
  ('XSD', 'codIncCP', '92', '13º salário', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/evtTabRubrica.xsd:253 (xs:enumeration)'),
  ('XSD', 'codIncCP', '93', 'Salário-maternidade', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/evtTabRubrica.xsd:258 (xs:enumeration)'),
  ('XSD', 'codIncCP', '94', 'Salário-maternidade 13º salário', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/evtTabRubrica.xsd:263 (xs:enumeration)'),
  ('XSD', 'codIncCP', '95', 'Exclusiva do empregador - Mensal', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/evtTabRubrica.xsd:268 (xs:enumeration)'),
  ('XSD', 'codIncCP', '96', 'Exclusiva do empregador - 13º salário', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/evtTabRubrica.xsd:273 (xs:enumeration)'),
  ('XSD', 'codIncCP', '97', 'Exclusiva do empregador - Salário-maternidade', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/evtTabRubrica.xsd:278 (xs:enumeration)'),
  ('XSD', 'codIncCP', '98', 'Exclusiva do empregador - Salário-maternidade 13º salário', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/evtTabRubrica.xsd:283 (xs:enumeration)'),
  ('XSD', 'codIncFGTS', '00', 'Não é base de cálculo do FGTS', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/evtTabRubrica.xsd:310 (xs:enumeration)'),
  ('XSD', 'codIncFGTS', '11', 'Base de cálculo do FGTS mensal', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/evtTabRubrica.xsd:315 (xs:enumeration)'),
  ('XSD', 'codIncFGTS', '12', 'Base de cálculo do FGTS 13° salário', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/evtTabRubrica.xsd:320 (xs:enumeration)'),
  ('XSD', 'codIncFGTS', '21', 'Base de cálculo do FGTS aviso prévio indenizado', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/evtTabRubrica.xsd:325 (xs:enumeration)'),
  ('XSD', 'codIncFGTS', '31', 'Desconto eConsignado', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/evtTabRubrica.xsd:330 (xs:enumeration)'),
  ('XSD', 'codIncFGTS', '91', 'Incidência suspensa em decorrência de decisão judicial - FGTS mensal', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/evtTabRubrica.xsd:335 (xs:enumeration)'),
  ('XSD', 'codIncFGTS', '92', 'Incidência suspensa em decorrência de decisão judicial - FGTS 13º salário', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/evtTabRubrica.xsd:340 (xs:enumeration)'),
  ('XSD', 'codIncFGTS', '93', 'Incidência suspensa em decorrência de decisão judicial - FGTS aviso prévio indenizado', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/evtTabRubrica.xsd:345 (xs:enumeration)'),
  ('XSD', 'grauInstr', '01', 'Analfabeto, inclusive o que, embora tenha recebido instrução, não se alfabetizou', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/tipos.xsd:3354 (xs:enumeration)'),
  ('XSD', 'grauInstr', '02', 'Até o 5º ano incompleto do ensino fundamental (antiga 4ª série) ou que se tenha alfabetizado sem ter frequentado escola regular', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/tipos.xsd:3359 (xs:enumeration)'),
  ('XSD', 'grauInstr', '03', '5º ano completo do ensino fundamental', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/tipos.xsd:3364 (xs:enumeration)'),
  ('XSD', 'grauInstr', '04', 'Do 6º ao 9º ano do ensino fundamental incompleto (antiga 5ª a 8ª série)', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/tipos.xsd:3369 (xs:enumeration)'),
  ('XSD', 'grauInstr', '05', 'Ensino fundamental completo', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/tipos.xsd:3374 (xs:enumeration)'),
  ('XSD', 'grauInstr', '06', 'Ensino médio incompleto', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/tipos.xsd:3379 (xs:enumeration)'),
  ('XSD', 'grauInstr', '07', 'Ensino médio completo', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/tipos.xsd:3384 (xs:enumeration)'),
  ('XSD', 'grauInstr', '08', 'Educação superior incompleta', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/tipos.xsd:3389 (xs:enumeration)'),
  ('XSD', 'grauInstr', '09', 'Educação superior completa', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/tipos.xsd:3394 (xs:enumeration)'),
  ('XSD', 'grauInstr', '10', 'Pós-graduação completa', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/tipos.xsd:3399 (xs:enumeration)'),
  ('XSD', 'grauInstr', '11', 'Mestrado completo', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/tipos.xsd:3404 (xs:enumeration)'),
  ('XSD', 'grauInstr', '12', 'Doutorado completo', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/tipos.xsd:3409 (xs:enumeration)'),
  ('XSD', 'racaCor', '1', 'Branca', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/tipos.xsd:3268 (xs:enumeration)'),
  ('XSD', 'racaCor', '2', 'Preta', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/tipos.xsd:3273 (xs:enumeration)'),
  ('XSD', 'racaCor', '3', 'Parda', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/tipos.xsd:3278 (xs:enumeration)'),
  ('XSD', 'racaCor', '4', 'Amarela', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/tipos.xsd:3283 (xs:enumeration)'),
  ('XSD', 'racaCor', '5', 'Indígena', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/tipos.xsd:3288 (xs:enumeration)'),
  ('XSD', 'racaCor', '6', 'Não informado', 'dnex-contador@e0d3ffb packages/esocial/xsd/eventos-S-1.3-2026-10-26/tipos.xsd:3293 (xs:enumeration)')
  ) AS v(t, c, k, d, f);

-- Situação de um código num campo: ok | invalido | sem_tabela (tabela não carregada: não se confere).
-- Natureza da rubrica (Tabela 03) tem estrutura própria desde a 0026 (esocial_rubric_nature).
CREATE FUNCTION folha.esocial_dominio_situacao(p_campo text, p_codigo text) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
BEGIN
  IF p_codigo IS NULL THEN
    RETURN 'sem_tabela';
  END IF;
  IF p_campo = 'natRubr' THEN
    IF NOT EXISTS (SELECT 1 FROM folha.esocial_rubric_nature) THEN
      RETURN 'sem_tabela';
    END IF;
    RETURN CASE WHEN EXISTS (SELECT 1 FROM folha.esocial_rubric_nature n WHERE n.codigo = p_codigo) THEN 'ok' ELSE 'invalido' END;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM folha.esocial_domain_code d WHERE d.campo = p_campo) THEN
    RETURN 'sem_tabela';
  END IF;
  RETURN CASE WHEN EXISTS (SELECT 1 FROM folha.esocial_domain_code d WHERE d.campo = p_campo AND d.codigo = p_codigo)
              THEN 'ok' ELSE 'invalido' END;
END
$function$;

-- Gatilho genérico: TG_ARGV = coluna1, campo1, coluna2, campo2, ... Recusa o código que não está na
-- tabela carregada do campo; tabela vazia não recusa (a função de entrada devolve pendência).
CREATE FUNCTION folha.esocial_dominio_guarda() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  i integer;
  v_valor text;
BEGIN
  FOR i IN 0 .. (TG_NARGS / 2) - 1 LOOP
    v_valor := to_jsonb(NEW) ->> TG_ARGV[2 * i];
    IF v_valor IS NOT NULL AND folha.esocial_dominio_situacao(TG_ARGV[2 * i + 1], v_valor) = 'invalido' THEN
      RAISE EXCEPTION '%: o código "%" de % não consta da tabela do eSocial carregada para o campo %',
        TG_TABLE_NAME, v_valor, TG_ARGV[2 * i], TG_ARGV[2 * i + 1] USING ERRCODE = 'check_violation';
    END IF;
  END LOOP;
  RETURN NEW;
END
$function$;

-- ===========================================================================
-- 2. Lacunas de cadastro (todas com account_id, chave estrangeira composta com account_id)
-- ===========================================================================

-- 2.1 S-1000: dados do empregador por vigência (iniValid/fimValid são meses: 1º dia do mês, fim inclusivo)
CREATE TABLE folha.employer_esocial (
  employer_esocial_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  employer_id uuid NOT NULL,
  vigencia_inicio date NOT NULL CHECK (EXTRACT(DAY FROM vigencia_inicio) = 1),
  vigencia_fim date CHECK (vigencia_fim IS NULL OR EXTRACT(DAY FROM vigencia_fim) = 1),
  class_trib text CHECK (class_trib IS NULL OR class_trib ~ '^[0-9]{2}$'),  -- vazio = usa employer.classificacao_tributaria
  ind_coop smallint CHECK (ind_coop IN (0, 1, 2, 3)),
  ind_constr smallint CHECK (ind_constr IN (0, 1)),
  ind_des_folha smallint NOT NULL CHECK (ind_des_folha IN (0, 1, 2)),
  ind_opc_cp smallint CHECK (ind_opc_cp IN (1, 2)),
  ind_porte boolean,
  ind_opt_reg_eletron smallint NOT NULL CHECK (ind_opt_reg_eletron IN (0, 1)),
  cnpj_efr text CHECK (cnpj_efr IS NULL OR cnpj_efr ~ '^[A-Z0-9]{12}[0-9]{2}$'),
  dt_trans_11096 date,
  ind_trib_folha_pis_pasep boolean,
  ind_pert_irrf boolean,
  dados_isencao jsonb CHECK (dados_isencao IS NULL OR jsonb_typeof(dados_isencao) = 'object'),
  info_org_internacional jsonb CHECK (info_org_internacional IS NULL OR jsonb_typeof(info_org_internacional) = 'object'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT employer_esocial_employer_fk FOREIGN KEY (account_id, employer_id)
    REFERENCES folha.employer (account_id, employer_id),
  CONSTRAINT employer_esocial_vigencia_valida CHECK (vigencia_fim IS NULL OR vigencia_fim >= vigencia_inicio),
  CONSTRAINT employer_esocial_sem_sobreposicao EXCLUDE USING gist (
    employer_id WITH =, daterange(vigencia_inicio, vigencia_fim, '[]') WITH &&)
);

-- 2.2 S-1005: dados do estabelecimento por vigência (CNAE em establishment, FAP em establishment_fap)
CREATE TABLE folha.establishment_esocial (
  establishment_esocial_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  establishment_id uuid NOT NULL,
  vigencia_inicio date NOT NULL CHECK (EXTRACT(DAY FROM vigencia_inicio) = 1),
  vigencia_fim date CHECK (vigencia_fim IS NULL OR EXTRACT(DAY FROM vigencia_fim) = 1),
  cnpj_resp text CHECK (cnpj_resp IS NULL OR cnpj_resp ~ '^[A-Z0-9]{12}[0-9]{2}$'),
  aliq_rat smallint CHECK (aliq_rat IN (1, 2, 3)),
  tp_caepf smallint CHECK (tp_caepf IN (1, 2, 3)),
  ind_subst_patr_obra smallint CHECK (ind_subst_patr_obra IN (1, 2)),
  proc_adm_jud_rat jsonb CHECK (proc_adm_jud_rat IS NULL OR jsonb_typeof(proc_adm_jud_rat) = 'object'),
  proc_adm_jud_fap jsonb CHECK (proc_adm_jud_fap IS NULL OR jsonb_typeof(proc_adm_jud_fap) = 'object'),
  info_trab jsonb CHECK (info_trab IS NULL OR jsonb_typeof(info_trab) = 'object'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT establishment_esocial_establishment_fk FOREIGN KEY (account_id, establishment_id)
    REFERENCES folha.establishment (account_id, establishment_id),
  CONSTRAINT establishment_esocial_vigencia_valida CHECK (vigencia_fim IS NULL OR vigencia_fim >= vigencia_inicio),
  CONSTRAINT establishment_esocial_sem_sobreposicao EXCLUDE USING gist (
    establishment_id WITH =, daterange(vigencia_inicio, vigencia_fim, '[]') WITH &&)
);

-- 2.3 S-1020: o que faltava na lotação (tipo da lotação e FPAS/Terceiros já existem em
--     tax_allocation.tipo_lotacao e tax_allocation_detail). A validade do S-1020 é a da linha de enquadramento.
ALTER TABLE folha.tax_allocation
  ADD COLUMN esocial_tp_insc smallint CHECK (esocial_tp_insc IN (1, 2, 4)),
  ADD COLUMN esocial_nr_insc text CHECK (esocial_nr_insc IS NULL OR esocial_nr_insc ~ '^([0-9]{11,12}|[A-Z0-9]{12}[0-9]{2})$'),
  ADD COLUMN info_empr_parcial jsonb CHECK (info_empr_parcial IS NULL OR jsonb_typeof(info_empr_parcial) = 'object'),
  ADD COLUMN dados_op_port jsonb CHECK (dados_op_port IS NULL OR jsonb_typeof(dados_op_port) = 'object'),
  ADD CONSTRAINT tax_allocation_insc_coerente CHECK ((esocial_tp_insc IS NULL) = (esocial_nr_insc IS NULL));
ALTER TABLE folha.tax_allocation_detail
  ADD COLUMN cod_terceiros_suspensos text CHECK (cod_terceiros_suspensos IS NULL OR cod_terceiros_suspensos ~ '^[0-9]{4}$'),
  ADD COLUMN info_proc_jud_terceiros jsonb
    CHECK (info_proc_jud_terceiros IS NULL OR jsonb_typeof(info_proc_jud_terceiros) = 'object');

-- 2.4 S-1010: a rubrica por empregador (codRubr, ideTabRubr e validade). A natureza é a de
--     rubric_esocial_nature e as incidências são as de rubric_incidence/incidence_code (não se duplica).
CREATE TABLE folha.rubric_esocial_config (
  config_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  employer_id uuid NOT NULL,
  code_id uuid NOT NULL REFERENCES folha.earning_deduction_code (code_id),
  cod_rubr text NOT NULL CHECK (char_length(cod_rubr) BETWEEN 1 AND 30 AND cod_rubr !~ '[[:cntrl:]]'),
  ide_tab_rubr text NOT NULL CHECK (char_length(ide_tab_rubr) BETWEEN 1 AND 8 AND ide_tab_rubr !~ '[[:cntrl:]]'),
  vigencia_inicio date NOT NULL CHECK (EXTRACT(DAY FROM vigencia_inicio) = 1),
  vigencia_fim date CHECK (vigencia_fim IS NULL OR EXTRACT(DAY FROM vigencia_fim) = 1),
  teto_remun boolean,
  ind_apur_ir smallint CHECK (ind_apur_ir IN (0, 1)),   -- indApurIR do item do S-1200 (0 normal, 1 RRA); sem valor = falta
  observacao text CHECK (observacao IS NULL OR char_length(observacao) BETWEEN 1 AND 255),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT rubric_esocial_config_employer_fk FOREIGN KEY (account_id, employer_id)
    REFERENCES folha.employer (account_id, employer_id),
  CONSTRAINT rubric_esocial_config_vigencia_valida CHECK (vigencia_fim IS NULL OR vigencia_fim >= vigencia_inicio),
  CONSTRAINT rubric_esocial_config_rubrica_sem_sobreposicao EXCLUDE USING gist (
    employer_id WITH =, code_id WITH =, daterange(vigencia_inicio, vigencia_fim, '[]') WITH &&),
  CONSTRAINT rubric_esocial_config_codigo_sem_sobreposicao EXCLUDE USING gist (
    employer_id WITH =, cod_rubr WITH =, ide_tab_rubr WITH =, daterange(vigencia_inicio, vigencia_fim, '[]') WITH &&)
);
CREATE TRIGGER trg_rubric_esocial_config_rubrica
  BEFORE INSERT OR UPDATE ON folha.rubric_esocial_config
  FOR EACH ROW EXECUTE FUNCTION folha.exigir_rubrica_da_conta('visivel');

-- 2.5 S-2200: dados cadastrais do trabalhador (um por trabalhador)
CREATE TABLE folha.employee_esocial (
  employee_esocial_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  employee_id uuid NOT NULL,
  raca_cor smallint CHECK (raca_cor BETWEEN 1 AND 6),
  est_civ smallint CHECK (est_civ BETWEEN 1 AND 5),
  grau_instr text CHECK (grau_instr IS NULL OR grau_instr ~ '^(0[1-9]|1[0-2])$'),
  nm_soc text CHECK (nm_soc IS NULL OR char_length(nm_soc) BETWEEN 2 AND 70),
  pais_nascto text CHECK (pais_nascto IS NULL OR pais_nascto ~ '^[0-9]{3}$'),
  pais_nac text CHECK (pais_nac IS NULL OR pais_nac ~ '^[0-9]{3}$'),
  tp_lograd text CHECK (tp_lograd IS NULL OR char_length(tp_lograd) BETWEEN 1 AND 4),
  dsc_lograd text CHECK (dsc_lograd IS NULL OR char_length(dsc_lograd) BETWEEN 1 AND 100),
  nr_lograd text CHECK (nr_lograd IS NULL OR char_length(nr_lograd) BETWEEN 1 AND 10),
  complemento text CHECK (complemento IS NULL OR char_length(complemento) BETWEEN 1 AND 30),
  bairro text CHECK (bairro IS NULL OR char_length(bairro) BETWEEN 1 AND 90),
  cep text CHECK (cep IS NULL OR cep ~ '^[0-9]{8}$'),
  cod_munic text CHECK (cod_munic IS NULL OR cod_munic ~ '^[0-9]{7}$'),   -- código IBGE do município
  uf text CHECK (uf IS NULL OR uf ~ '^(AC|AL|AP|AM|BA|CE|DF|ES|GO|MA|MT|MS|MG|PA|PB|PR|PE|PI|RJ|RN|RS|RO|RR|SC|SP|SE|TO)$'),
  info_deficiencia jsonb CHECK (info_deficiencia IS NULL OR jsonb_typeof(info_deficiencia) = 'object'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT employee_esocial_employee_fk FOREIGN KEY (account_id, employee_id)
    REFERENCES folha.employee (account_id, employee_id),
  UNIQUE (account_id, employee_id)
);
CREATE TRIGGER trg_employee_esocial_dominio
  BEFORE INSERT OR UPDATE ON folha.employee_esocial
  FOR EACH ROW EXECUTE FUNCTION folha.esocial_dominio_guarda('grau_instr', 'grauInstr', 'raca_cor', 'racaCor');

CREATE TABLE folha.employee_dependent (
  dependent_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  employee_id uuid NOT NULL,
  nm_dep text NOT NULL CHECK (char_length(nm_dep) BETWEEN 2 AND 70),
  dt_nascto date NOT NULL,
  tp_dep text CHECK (tp_dep IS NULL OR tp_dep ~ '^[0-9]{2}$'),            -- Tabela 07 (não carregada)
  cpf_dep text CHECK (cpf_dep IS NULL OR cpf_dep ~ '^[0-9]{11}$'),
  dep_irrf boolean NOT NULL,
  dep_sf boolean NOT NULL,
  inc_trab boolean NOT NULL,
  descr_dep text CHECK (descr_dep IS NULL OR char_length(descr_dep) BETWEEN 1 AND 100),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT employee_dependent_employee_fk FOREIGN KEY (account_id, employee_id)
    REFERENCES folha.employee (account_id, employee_id),
  CONSTRAINT employee_dependent_tipo_irrf CHECK (NOT dep_irrf OR tp_dep IS NOT NULL)
);
CREATE INDEX idx_employee_dependent_employee ON folha.employee_dependent (account_id, employee_id);

-- 2.6 S-2200/S-1200: dados do vínculo no eSocial (um por contrato). O estabelecimento do local de
--     trabalho vem do contrato; a jornada semanal, do contrato; o nome do cargo, do contrato.
CREATE TABLE folha.contract_esocial (
  contract_esocial_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  employer_id uuid NOT NULL,
  contract_id uuid NOT NULL,
  matricula text NOT NULL CHECK (char_length(matricula) BETWEEN 1 AND 30 AND matricula !~ '[[:cntrl:]]'),
  cod_categ text CHECK (cod_categ IS NULL OR cod_categ ~ '^[0-9]{3}$'),     -- Tabela 01 (não carregada)
  tp_reg_prev smallint CHECK (tp_reg_prev IN (1, 2, 3, 4)),                  -- 1 = RGPS
  cad_ini boolean,
  ind_admissao smallint CHECK (ind_admissao IN (1, 2, 3)),
  tp_reg_jor smallint CHECK (tp_reg_jor IN (1, 2, 3, 4)),
  nat_atividade smallint CHECK (nat_atividade IN (1, 2)),
  dt_base smallint CHECK (dt_base BETWEEN 1 AND 12),
  cnpj_sind_categ_prof text CHECK (cnpj_sind_categ_prof IS NULL OR cnpj_sind_categ_prof ~ '^[A-Z0-9]{12}[0-9]{2}$'),
  cbo_cargo text CHECK (cbo_cargo IS NULL OR cbo_cargo ~ '^[0-9]{6}$'),
  nm_funcao text CHECK (nm_funcao IS NULL OR char_length(nm_funcao) BETWEEN 1 AND 100),
  cbo_funcao text CHECK (cbo_funcao IS NULL OR cbo_funcao ~ '^[0-9]{6}$'),
  und_sal_fixo smallint CHECK (und_sal_fixo BETWEEN 1 AND 7),
  dsc_sal_var text CHECK (dsc_sal_var IS NULL OR char_length(dsc_sal_var) BETWEEN 1 AND 999),
  tp_contr smallint CHECK (tp_contr IN (1, 2, 3)),
  dt_term date,
  clau_assec boolean,
  obj_det text CHECK (obj_det IS NULL OR char_length(obj_det) BETWEEN 1 AND 255),
  tp_jornada smallint CHECK (tp_jornada IN (2, 3, 4, 5, 6, 7, 9)),
  tmp_parc smallint CHECK (tmp_parc IN (0, 1, 2, 3)),
  hor_noturno boolean,
  dsc_jorn text CHECK (dsc_jorn IS NULL OR char_length(dsc_jorn) BETWEEN 1 AND 999),
  dt_opc_fgts date,
  aprend jsonb CHECK (aprend IS NULL OR jsonb_typeof(aprend) = 'object'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT contract_esocial_contract_fk FOREIGN KEY (account_id, employer_id, contract_id)
    REFERENCES folha.employment_contract (account_id, employer_id, contract_id),
  UNIQUE (account_id, contract_id),
  UNIQUE (account_id, employer_id, matricula),
  CONSTRAINT contract_esocial_termino_coerente CHECK (COALESCE(tp_contr, 0) = 2 OR dt_term IS NULL)
);
CREATE TRIGGER trg_contract_esocial_dominio
  BEFORE INSERT OR UPDATE ON folha.contract_esocial
  FOR EACH ROW EXECUTE FUNCTION folha.esocial_dominio_guarda('cod_categ', 'codCateg');

-- 2.7 S-2299: desligamento (motivo por CÓDIGO da Tabela 19, nunca por texto). O gerador do S-2299 ainda
--     não é alimentado por esta migration (ADR); a estrutura entra aqui porque é lacuna de cadastro.
CREATE TABLE folha.contract_termination (
  termination_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  employer_id uuid NOT NULL,
  contract_id uuid NOT NULL,
  mtv_deslig text NOT NULL CHECK (mtv_deslig ~ '^[0-9]{2}$'),               -- Tabela 19 (não carregada)
  dt_deslig date NOT NULL,
  dt_av_prv date,
  ind_pagto_api boolean NOT NULL,
  dt_proj_fim_api date,
  pens_alim smallint CHECK (pens_alim IN (0, 1, 2, 3)),
  perc_aliment numeric(5, 2) CHECK (perc_aliment IS NULL OR (perc_aliment > 0 AND perc_aliment <= 100)),
  vr_alim numeric(14, 2) CHECK (vr_alim IS NULL OR vr_alim > 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT contract_termination_contract_fk FOREIGN KEY (account_id, employer_id, contract_id)
    REFERENCES folha.employment_contract (account_id, employer_id, contract_id),
  UNIQUE (account_id, contract_id),
  CONSTRAINT contract_termination_api_coerente CHECK (ind_pagto_api OR dt_proj_fim_api IS NULL)
);
CREATE TRIGGER trg_contract_termination_dominio
  BEFORE INSERT OR UPDATE ON folha.contract_termination
  FOR EACH ROW EXECUTE FUNCTION folha.esocial_dominio_guarda('mtv_deslig', 'mtvDeslig');

-- ===========================================================================
-- 3. Demonstrativo (ideDmDev estável), pagamento efetivo e registro das entradas
--    Só se grava pelas funções (e nunca se altera: histórico).
-- ===========================================================================
CREATE TABLE folha.payroll_demonstrative (
  demonstrative_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  employer_id uuid NOT NULL,
  employee_id uuid NOT NULL,
  run_id uuid NOT NULL,
  result_id uuid NOT NULL,
  ide_dm_dev text NOT NULL CHECK (char_length(ide_dm_dev) BETWEEN 1 AND 30 AND ide_dm_dev ~ '^[A-Za-z0-9][-_A-Za-z0-9./]*$'),
  criado_por_subject uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT payroll_demonstrative_employer_fk FOREIGN KEY (account_id, employer_id)
    REFERENCES folha.employer (account_id, employer_id),
  CONSTRAINT payroll_demonstrative_employee_fk FOREIGN KEY (account_id, employee_id)
    REFERENCES folha.employee (account_id, employee_id),
  CONSTRAINT payroll_demonstrative_run_fk FOREIGN KEY (account_id, run_id)
    REFERENCES folha.payroll_run (account_id, run_id),
  CONSTRAINT payroll_demonstrative_result_fk FOREIGN KEY (account_id, result_id)
    REFERENCES folha.payroll_result (account_id, result_id),
  UNIQUE (account_id, result_id),
  UNIQUE (account_id, employer_id, employee_id, ide_dm_dev)   -- ideDmDev único por trabalhador (leiaute)
);
COMMENT ON TABLE folha.payroll_demonstrative IS
  'ideDmDev do S-1200 por resultado da folha. Gravado ao registrar o S-1200 e imutável: o S-1210 referencia este identificador.';

CREATE TABLE folha.payroll_payment (
  payment_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  employer_id uuid NOT NULL,
  employee_id uuid NOT NULL,
  run_id uuid NOT NULL,
  result_id uuid NOT NULL,
  dt_pgto date NOT NULL,                                   -- data EFETIVA do pagamento (nunca deduzida)
  tp_pgto smallint NOT NULL CHECK (tp_pgto IN (1, 2)),     -- 1 folha (S-1200); 2 rescisão (S-2299)
  vr_liq numeric(14, 2) NOT NULL CHECK (vr_liq > 0),
  registrado_por_subject uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT payroll_payment_employer_fk FOREIGN KEY (account_id, employer_id)
    REFERENCES folha.employer (account_id, employer_id),
  CONSTRAINT payroll_payment_employee_fk FOREIGN KEY (account_id, employee_id)
    REFERENCES folha.employee (account_id, employee_id),
  CONSTRAINT payroll_payment_run_fk FOREIGN KEY (account_id, run_id)
    REFERENCES folha.payroll_run (account_id, run_id),
  CONSTRAINT payroll_payment_result_fk FOREIGN KEY (account_id, result_id)
    REFERENCES folha.payroll_result (account_id, result_id),
  UNIQUE (account_id, result_id, tp_pgto, dt_pgto)
);
CREATE INDEX idx_payroll_payment_trabalhador ON folha.payroll_payment (account_id, employer_id, employee_id, dt_pgto);
COMMENT ON TABLE folha.payroll_payment IS
  'Pagamento efetivo por resultado da folha (data, tipo e valor líquido): base do S-1210. Sem estorno nesta versão (ADR).';

CREATE TABLE folha.esocial_entrada (
  entrada_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  employer_id uuid NOT NULL,
  evento_codigo text NOT NULL REFERENCES folha.esocial_event_catalog (evento_codigo),
  ambiente text NOT NULL CHECK (ambiente IN ('producao', 'producao_restrita')),
  estado text NOT NULL CHECK (estado IN ('pronto', 'incompleto', 'bloqueado')),
  event_id uuid,
  entrada jsonb CHECK (entrada IS NULL OR jsonb_typeof(entrada) = 'object'),
  entrada_hash text CHECK (entrada_hash IS NULL OR entrada_hash ~ '^[0-9a-f]{64}$'),
  faltando jsonb NOT NULL CHECK (jsonb_typeof(faltando) = 'array'),
  bloqueios jsonb NOT NULL CHECK (jsonb_typeof(bloqueios) = 'array'),
  pendencias jsonb NOT NULL CHECK (jsonb_typeof(pendencias) = 'array'),
  criado_por_subject uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT esocial_entrada_employer_fk FOREIGN KEY (account_id, employer_id)
    REFERENCES folha.employer (account_id, employer_id),
  CONSTRAINT esocial_entrada_event_fk FOREIGN KEY (account_id, event_id)
    REFERENCES folha.esocial_event (account_id, event_id),
  CONSTRAINT esocial_entrada_pronto_coerente
    CHECK ((estado = 'pronto') = (entrada IS NOT NULL AND entrada_hash IS NOT NULL))
);
CREATE UNIQUE INDEX esocial_entrada_pronto_key ON folha.esocial_entrada (account_id, event_id, entrada_hash)
  WHERE estado = 'pronto' AND event_id IS NOT NULL;
CREATE INDEX idx_esocial_entrada_evento ON folha.esocial_entrada (account_id, employer_id, evento_codigo, created_at);
COMMENT ON TABLE folha.esocial_entrada IS
  'Registro de cada montagem de entrada (pronta, incompleta ou bloqueada), com o que faltou e as pendências. A entrada pronta guarda dado pessoal: RLS e leitura só por conta. Histórico: ninguém altera nem apaga.';

CREATE TRIGGER trg_payroll_demonstrative_imutavel
  BEFORE UPDATE OR DELETE ON folha.payroll_demonstrative
  FOR EACH ROW EXECUTE FUNCTION folha.esocial_imutavel();
CREATE TRIGGER trg_payroll_demonstrative_sem_truncate
  BEFORE TRUNCATE ON folha.payroll_demonstrative
  FOR EACH STATEMENT EXECUTE FUNCTION folha.esocial_sem_truncate();
CREATE TRIGGER trg_payroll_payment_imutavel
  BEFORE UPDATE OR DELETE ON folha.payroll_payment
  FOR EACH ROW EXECUTE FUNCTION folha.esocial_imutavel();
CREATE TRIGGER trg_payroll_payment_sem_truncate
  BEFORE TRUNCATE ON folha.payroll_payment
  FOR EACH STATEMENT EXECUTE FUNCTION folha.esocial_sem_truncate();
CREATE TRIGGER trg_esocial_entrada_imutavel
  BEFORE UPDATE OR DELETE ON folha.esocial_entrada
  FOR EACH ROW EXECUTE FUNCTION folha.esocial_imutavel();
CREATE TRIGGER trg_esocial_entrada_sem_truncate
  BEFORE TRUNCATE ON folha.esocial_entrada
  FOR EACH STATEMENT EXECUTE FUNCTION folha.esocial_sem_truncate();

-- ===========================================================================
-- 4. Funções internas (ninguém além do dono executa; o EXECUTE é revogado na seção 7)
-- ===========================================================================

-- Acumulador do resultado: faltando (caminhos sem dado utilizável), detalhes (motivo por caminho),
-- bloqueios (o caso não pode seguir pelo estado dos dados) e pendências (não bloqueiam).
CREATE FUNCTION folha.esocial_entrada_acc() RETURNS jsonb
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $function$
  SELECT '{"faltando": [], "detalhes": [], "bloqueios": [], "pendencias": []}'::jsonb;
$function$;

CREATE FUNCTION folha.esocial_entrada_falta(p_acc jsonb, p_caminho text, p_motivo text) RETURNS jsonb
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $function$
  SELECT jsonb_set(
           jsonb_set(p_acc, '{faltando}', (p_acc -> 'faltando') || to_jsonb(p_caminho)),
           '{detalhes}', (p_acc -> 'detalhes') || jsonb_build_array(jsonb_build_object('caminho', p_caminho, 'motivo', p_motivo)));
$function$;

CREATE FUNCTION folha.esocial_entrada_exige(p_acc jsonb, p_caminho text, p_valor text, p_motivo text DEFAULT 'dado ausente no cadastro')
RETURNS jsonb
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $function$
  SELECT CASE WHEN p_valor IS NULL OR btrim(p_valor) = ''
              THEN folha.esocial_entrada_falta(p_acc, p_caminho, p_motivo) ELSE p_acc END;
$function$;

CREATE FUNCTION folha.esocial_entrada_bloqueia(p_acc jsonb, p_codigo text, p_mensagem text) RETURNS jsonb
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $function$
  SELECT jsonb_set(p_acc, '{bloqueios}',
                   (p_acc -> 'bloqueios') || jsonb_build_array(jsonb_build_object('codigo', p_codigo, 'mensagem', p_mensagem)));
$function$;

CREATE FUNCTION folha.esocial_entrada_pende(p_acc jsonb, p_caminho text, p_motivo text) RETURNS jsonb
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $function$
  SELECT CASE WHEN (p_acc -> 'pendencias') @> jsonb_build_array(jsonb_build_object('caminho', p_caminho, 'motivo', p_motivo))
              THEN p_acc
              ELSE jsonb_set(p_acc, '{pendencias}',
                             (p_acc -> 'pendencias') || jsonb_build_array(jsonb_build_object('caminho', p_caminho, 'motivo', p_motivo)))
         END;
$function$;

-- Código num campo de tabela do eSocial: fora da tabela carregada = falta; tabela não carregada = pendência.
CREATE FUNCTION folha.esocial_entrada_dominio(p_acc jsonb, p_caminho text, p_campo text, p_valor text, p_tabela text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_sit text;
BEGIN
  IF p_valor IS NULL THEN
    RETURN p_acc;
  END IF;
  v_sit := folha.esocial_dominio_situacao(p_campo, p_valor);
  IF v_sit = 'invalido' THEN
    RETURN folha.esocial_entrada_falta(p_acc, p_caminho,
             format('o código %s não consta da tabela %s do eSocial carregada para o campo %s', p_valor, p_tabela, p_campo));
  ELSIF v_sit = 'sem_tabela' THEN
    RETURN folha.esocial_entrada_pende(p_acc, p_caminho,
             format('tabela %s do eSocial não carregada: o código do campo %s não foi conferido (a_validar)', p_tabela, p_campo));
  END IF;
  RETURN p_acc;
END
$function$;

CREATE FUNCTION folha.esocial_entrada_dec(p_valor numeric) RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $function$
  SELECT to_char(p_valor, 'FM999999999990.00');
$function$;

CREATE FUNCTION folha.esocial_entrada_data(p_data date) RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $function$
  SELECT to_char(p_data, 'YYYY-MM-DD');
$function$;

CREATE FUNCTION folha.esocial_entrada_sn(p_valor boolean) RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $function$
  SELECT CASE p_valor WHEN true THEN 'S' WHEN false THEN 'N' END;
$function$;

-- ideEmpregador: CNPJ pela raiz (8 posições; 14 para as cinco naturezas jurídicas que o gerador lista em
-- avisosInscricaoEmpregador), CPF com 11. Sem inscrição utilizável = NULL.
CREATE FUNCTION folha.esocial_entrada_empregador(p_emp folha.employer) RETURNS jsonb
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $function$
  SELECT CASE
           WHEN p_emp.tipo_inscricao = 'cnpj' AND p_emp.inscricao ~ '^[A-Z0-9]{12}[0-9]{2}$'
             THEN jsonb_build_object('tpInsc', 1, 'nrInsc',
                    CASE WHEN p_emp.natureza_juridica IN ('101-5', '104-0', '107-4', '116-3', '134-1')
                         THEN p_emp.inscricao ELSE left(p_emp.inscricao, 8) END)
           WHEN p_emp.tipo_inscricao = 'cpf' AND p_emp.inscricao ~ '^[0-9]{11}$'
             THEN jsonb_build_object('tpInsc', 2, 'nrInsc', p_emp.inscricao)
         END;
$function$;

-- tpInsc do estabelecimento: CNPJ 1, CAEPF 3, CNO 4.
CREATE FUNCTION folha.esocial_entrada_tpinsc_estab(p_tipo text) RETURNS smallint
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog, pg_temp
AS $function$
  SELECT CASE p_tipo WHEN 'cnpj' THEN 1 WHEN 'caepf' THEN 3 WHEN 'cno' THEN 4 END::smallint;
$function$;

-- Contexto da Folha pelo protocolo da 0028. Leitura (folha.read); com registro, também folha.transmit; e
-- folha.close quando a operação é de aprovação (retificação, reabertura, exclusão). Devolve o contexto em json.
CREATE FUNCTION folha.esocial_entrada_contexto(p_registrar boolean, p_aprovacao boolean) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $function$
DECLARE
  v_ctx record;
BEGIN
  SELECT c.account_id, c.legal_entity_id, c.branch_id, c.subject_id INTO v_ctx FROM folha.contexto_v1('folha.read') AS c;
  IF p_registrar THEN
    PERFORM 1 FROM folha.contexto_v1('folha.transmit');
  END IF;
  IF p_aprovacao THEN
    PERFORM 1 FROM folha.contexto_v1('folha.close');
  END IF;
  RETURN to_jsonb(v_ctx);
END
$function$;

-- Fecha a montagem: decide o estado, calcula o hash de origem (sem o carimbo de emissão, para a
-- idempotência), registra o evento na fila como rascunho (sem XML), guarda o demonstrativo, o registro da
-- entrada e a auditoria (ids, estado e hash; nunca o conteúdo).
CREATE FUNCTION folha.esocial_entrada_concluir(
  p_ctx jsonb, p_employer uuid, p_evento text, p_ambiente text, p_dados jsonb, p_empregador jsonb,
  p_gerado_em timestamp, p_acc jsonb, p_ref jsonb, p_origens jsonb, p_registrar boolean,
  p_retifica uuid, p_exclui uuid, p_motivo text, p_demonstrativos jsonb, p_hash text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_conta uuid := (p_ctx ->> 'account_id')::uuid;
  v_subject uuid := (p_ctx ->> 'subject_id')::uuid;
  v_estado text;
  v_env jsonb;
  v_hash text;
  v_r jsonb;
  v_event uuid;
  v_ger text;
  v_acc jsonb := p_acc;
  v_nat text;
  v_orig text;
  v_h0 text;
BEGIN
  SELECT e.natureza_juridica INTO v_nat FROM folha.employer e WHERE e.account_id = v_conta AND e.employer_id = p_employer;
  IF v_nat IS NULL AND p_empregador ->> 'tpInsc' = '1' THEN
    v_acc := folha.esocial_entrada_pende(v_acc, 'empregador.nrInsc',
      'natureza jurídica não informada: o CNPJ do empregador vai pela raiz de 8 posições (a_validar; 14 posições para administração pública)');
  END IF;
  -- retificação sem mudança de conteúdo: nada a retificar (a função de retificação da 0031 faz a mesma recusa)
  IF p_retifica IS NOT NULL AND jsonb_array_length(v_acc -> 'bloqueios') = 0 AND jsonb_array_length(v_acc -> 'faltando') = 0 THEN
    SELECT x.origem_hash INTO v_orig FROM folha.esocial_event x WHERE x.account_id = v_conta AND x.event_id = p_retifica;
    v_h0 := encode(sha256(convert_to(jsonb_build_object('evento', p_evento, 'ambiente', CASE p_ambiente WHEN 'producao' THEN 1 ELSE 2 END,
                'empregador', p_empregador, 'dados', p_dados - 'retificacao')::text, 'UTF8')), 'hex');
    IF v_h0 = v_orig THEN
      v_acc := folha.esocial_entrada_bloqueia(v_acc, 'nada_a_retificar', 'O conteúdo de origem é idêntico ao do evento validado: nada a retificar');
    END IF;
  END IF;
  v_estado := CASE WHEN jsonb_array_length(v_acc -> 'bloqueios') > 0 THEN 'bloqueado'
                   WHEN jsonb_array_length(v_acc -> 'faltando') > 0 THEN 'incompleto'
                   ELSE 'pronto' END;
  IF v_estado <> 'pronto' THEN
    IF p_registrar THEN
    INSERT INTO folha.esocial_entrada (account_id, employer_id, evento_codigo, ambiente, estado, faltando, bloqueios, pendencias, criado_por_subject)
    VALUES (v_conta, p_employer, p_evento, p_ambiente, v_estado, v_acc -> 'faltando', v_acc -> 'bloqueios', v_acc -> 'pendencias', v_subject);
    END IF;
    RETURN jsonb_build_object('estado', v_estado, 'evento', p_evento, 'entrada', NULL,
                              'faltando', v_acc -> 'faltando', 'detalhes', v_acc -> 'detalhes',
                              'bloqueios', v_acc -> 'bloqueios', 'pendencias', v_acc -> 'pendencias',
                              'event_id', NULL, 'situacao', NULL);
  END IF;

  v_ger := to_char(COALESCE(p_gerado_em, now() AT TIME ZONE 'America/Sao_Paulo'), 'YYYY-MM-DD"T"HH24:MI:SS');
  v_env := jsonb_build_object('evento', p_evento, 'ambiente', CASE p_ambiente WHEN 'producao' THEN 1 ELSE 2 END,
                              'empregador', p_empregador, 'dados', p_dados);
  v_hash := COALESCE(p_hash, encode(sha256(convert_to(v_env::text, 'UTF8')), 'hex'));
  v_env := v_env || jsonb_build_object('emissao', jsonb_build_object('geradoEm', v_ger));

  IF p_registrar THEN
    v_r := folha.esocial_evento_incluir(v_conta, p_employer, p_evento, p_ambiente, p_ref, v_hash,
                                        COALESCE(p_origens, '[]'::jsonb), p_retifica, p_exclui, p_motivo);
    v_event := (v_r ->> 'event_id')::uuid;
    IF p_demonstrativos IS NOT NULL AND jsonb_array_length(p_demonstrativos) > 0 THEN
      INSERT INTO folha.payroll_demonstrative (account_id, employer_id, employee_id, run_id, result_id, ide_dm_dev, criado_por_subject)
      SELECT v_conta, p_employer, (d ->> 'employee_id')::uuid, (d ->> 'run_id')::uuid, (d ->> 'result_id')::uuid,
             d ->> 'ide_dm_dev', v_subject
        FROM jsonb_array_elements(p_demonstrativos) AS d
      ON CONFLICT (account_id, result_id) DO NOTHING;
    END IF;
  END IF;

  -- Só quem registra (folha.transmit) grava: a montagem só para leitura não deixa linha nem dado pessoal.
  IF p_registrar THEN
    INSERT INTO folha.esocial_entrada (account_id, employer_id, evento_codigo, ambiente, estado, event_id, entrada, entrada_hash,
                                       faltando, bloqueios, pendencias, criado_por_subject)
    VALUES (v_conta, p_employer, p_evento, p_ambiente, 'pronto', v_event, v_env, v_hash,
            v_acc -> 'faltando', v_acc -> 'bloqueios', v_acc -> 'pendencias', v_subject)
    ON CONFLICT (account_id, event_id, entrada_hash) WHERE estado = 'pronto' AND event_id IS NOT NULL DO NOTHING;
    PERFORM folha.esocial_auditar(p_ctx, 'esocial_entrada', 'esocial_entrada', v_event,
                                  jsonb_build_object('evento_codigo', p_evento, 'ambiente', p_ambiente, 'registrado', p_registrar,
                                                     'entrada_hash', v_hash, 'situacao', v_r ->> 'situacao',
                                                     'retifica_event_id', p_retifica, 'exclui_event_id', p_exclui, 'motivo', p_motivo));
  END IF;
  RETURN jsonb_build_object('estado', 'pronto', 'evento', p_evento, 'entrada', v_env,
                            'faltando', '[]'::jsonb, 'detalhes', '[]'::jsonb, 'bloqueios', '[]'::jsonb,
                            'pendencias', v_acc -> 'pendencias',
                            'event_id', v_event, 'situacao', v_r ->> 'situacao');
END
$function$;

-- ===========================================================================
-- 5. Funções da sessão de aplicação (EXECUTE só para dnex_gestao_api)
--    Conferem o contexto no início e de novo antes de devolver (a asserção vale até 60 s). Nenhuma recebe
--    conta, subject ou responsável: tudo vem do contexto. Devolvem jsonb:
--      estado    pronto | incompleto (falta dado: caminhos em "faltando") | bloqueado (o estado dos dados
--                impede: "bloqueios"); "pendencias" não bloqueiam (tabela não carregada, a_validar);
--      entrada   o envelope do contrato do gerador, SÓ quando pronto;
--      event_id  o rascunho na fila (0031), SÓ quando pronto e p_registrar.
--    Nada é inventado: sem dado, "faltando"; nunca texto vazio ou zero silencioso.
--    Argumento inválido (ambiente, período, empregador de outra conta) é exceção, não resultado.
-- ===========================================================================

-- 5.1 Registro do pagamento efetivo (folha.close): a data nunca é deduzida; sem ele não há S-1210.
CREATE FUNCTION folha.esocial_entrada_pagamento_registrar_v1(
  p_result_id uuid, p_dt_pgto date, p_vr_liq numeric DEFAULT NULL, p_tp_pgto smallint DEFAULT 1
) RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx jsonb;
  v_conta uuid;
  v_subject uuid;
  v_res folha.payroll_result%ROWTYPE;
  v_run folha.payroll_run%ROWTYPE;
  v_vr numeric;
  v_ja numeric;
  v_id uuid;
BEGIN
  SELECT c.account_id, c.subject_id INTO v_conta, v_subject FROM folha.contexto_v1('folha.close') AS c;
  v_ctx := jsonb_build_object('account_id', v_conta, 'subject_id', v_subject);
  IF p_dt_pgto IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'esocial_entrada_pagamento_registrar_v1: a data efetiva do pagamento é obrigatória';
  END IF;
  IF p_tp_pgto IS NULL OR p_tp_pgto NOT IN (1, 2) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'esocial_entrada_pagamento_registrar_v1: tpPgto deve ser 1 (folha) ou 2 (rescisão)';
  END IF;
  SELECT * INTO v_res FROM folha.payroll_result r WHERE r.account_id = v_conta AND r.result_id = p_result_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = format('Resultado %s não encontrado nesta conta', p_result_id);
  END IF;
  SELECT * INTO v_run FROM folha.payroll_run r WHERE r.account_id = v_conta AND r.run_id = v_res.run_id;
  IF v_run.status <> 'closed' THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = format('A folha %s está %s: só folha fechada tem pagamento registrado', v_run.run_id, v_run.status);
  END IF;
  IF v_run.employer_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'Folha sem empregador não gera pagamento de eSocial';
  END IF;
  IF (v_run.tipo_processo = 'rescisao') IS DISTINCT FROM (p_tp_pgto = 2) THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = format('tpPgto %s não corresponde ao processo %s (1 = folha, 2 = rescisão)', p_tp_pgto, v_run.tipo_processo);
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('pgto|' || v_conta::text || '|' || p_result_id::text, 0));
  IF p_dt_pgto < v_run.competencia THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = format('A data de pagamento (%s) é anterior à competência da folha (%s)', p_dt_pgto, v_run.competencia);
  END IF;
  v_vr := COALESCE(p_vr_liq, v_res.liquido);
  IF v_vr IS NULL OR v_vr <= 0 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'O valor líquido pago deve ser maior que zero';
  END IF;
  SELECT COALESCE(sum(p.vr_liq), 0) INTO v_ja FROM folha.payroll_payment p
   WHERE p.account_id = v_conta AND p.result_id = p_result_id AND p.tp_pgto = p_tp_pgto;
  IF v_ja + v_vr > v_res.liquido THEN
    RAISE EXCEPTION USING ERRCODE = '22023',
      MESSAGE = format('Os pagamentos (%s já registrado + %s) passam do líquido do resultado (%s)', v_ja, v_vr, v_res.liquido);
  END IF;
  INSERT INTO folha.payroll_payment (account_id, employer_id, employee_id, run_id, result_id, dt_pgto, tp_pgto, vr_liq, registrado_por_subject)
  VALUES (v_conta, v_run.employer_id, v_res.employee_id, v_run.run_id, p_result_id, p_dt_pgto, p_tp_pgto, v_vr, v_subject)
  RETURNING payment_id INTO v_id;
  PERFORM folha.esocial_auditar(v_ctx, 'esocial_pagamento_registrar', 'payroll_payment', v_id,
                                jsonb_build_object('result_id', p_result_id, 'dt_pgto', p_dt_pgto, 'tp_pgto', p_tp_pgto, 'vr_liq', v_vr));
  PERFORM 1 FROM folha.contexto_v1('folha.close');
  RETURN v_id;
END
$function$;

-- 5.2 S-1200 (remuneração do trabalhador): um evento por empregador, trabalhador e período. Só de folha
--     FECHADA e sem pendência aberta; uma linha por rubrica do resultado (payroll_result_item), com
--     codRubr/ideTabRubr do S-1010 (rubric_esocial_config). Processos que entram: mensal, complementar e férias
--     (indApuracao 1). 13º (indApuracao 2), adiantamento e rescisão NÃO entram (ADR). p_periodo = 1º dia do mês.
CREATE FUNCTION folha.esocial_entrada_s1200_v1(
  p_employer_id uuid, p_employee_id uuid, p_ind_apuracao smallint, p_periodo date, p_ambiente text,
  p_gerado_em timestamp DEFAULT NULL, p_registrar boolean DEFAULT true, p_retificar_event_id uuid DEFAULT NULL,
  p_motivo text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx jsonb;
  v_conta uuid;
  v_emp folha.employer%ROWTYPE;
  v_ee folha.employee%ROWTYPE;
  v_acc jsonb := folha.esocial_entrada_acc();
  v_empregador jsonb;
  v_run record;
  v_row record;
  v_con folha.employment_contract%ROWTYPE;
  v_ce folha.contract_esocial%ROWTYPE;
  v_aloc record;
  v_item record;
  v_cfg folha.rubric_esocial_config%ROWTYPE;
  v_val folha.esocial_event%ROWTYPE;
  v_dms jsonb := '[]'::jsonb;
  v_dm jsonb;
  v_itens jsonb;
  v_origens jsonb := '[]'::jsonb;
  v_demos jsonb := '[]'::jsonb;
  v_ret jsonb := '{}'::jsonb;
  v_ide text;
  v_letra text;
  v_k integer;
  v_kk integer;
  v_n integer;
  v_prov numeric;
  v_desc numeric;
  v_fim_mes date := (p_periodo + interval '1 month')::date - 1;
  v_base text;
  v_qtd numeric;
BEGIN
  v_ctx := folha.esocial_entrada_contexto(p_registrar, p_retificar_event_id IS NOT NULL);
  v_conta := (v_ctx ->> 'account_id')::uuid;
  IF p_ambiente IS NULL OR p_ambiente NOT IN ('producao', 'producao_restrita') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Ambiente deve ser producao ou producao_restrita';
  END IF;
  IF p_ind_apuracao IS NULL OR p_ind_apuracao NOT IN (1, 2) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'indApuracao deve ser 1 (mensal) ou 2 (anual)';
  END IF;
  IF p_periodo IS NULL OR p_periodo <> date_trunc('month', p_periodo)::date THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'O período deve ser o primeiro dia do mês';
  END IF;
  IF p_ind_apuracao = 2 AND extract(month FROM p_periodo) <> 1 THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Na folha anual (indApuracao 2) o período é 1º de janeiro';
  END IF;
  SELECT * INTO v_emp FROM folha.employer e WHERE e.account_id = v_conta AND e.employer_id = p_employer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = format('Empregador %s não encontrado nesta conta', p_employer_id);
  END IF;
  SELECT * INTO v_ee FROM folha.employee e
   WHERE e.account_id = v_conta AND e.employee_id = p_employee_id
     AND EXISTS (SELECT 1 FROM folha.employment_contract k
                  WHERE k.account_id = v_conta AND k.employer_id = p_employer_id AND k.employee_id = p_employee_id);
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = format('Trabalhador %s não tem contrato com o empregador %s nesta conta', p_employee_id, p_employer_id);
  END IF;

  v_empregador := folha.esocial_entrada_empregador(v_emp);
  IF v_empregador IS NULL THEN
    v_acc := folha.esocial_entrada_falta(v_acc, 'empregador.nrInsc', 'empregador sem CNPJ ou CPF utilizável (tipo caepf não informa o CPF)');
  END IF;
  IF v_ee.cpf !~ '^[0-9]{11}$' THEN
    v_acc := folha.esocial_entrada_falta(v_acc, 'dados.trabalhador.cpfTrab', 'CPF fora de onze dígitos');
  END IF;
  v_acc := folha.esocial_entrada_pende(v_acc, 'dados.demonstrativos[].estabelecimentos[].remuneracoes[].infoAgNocivo',
    'exposição a agente nocivo (grauExp) não é verificada: a Folha não tem cadastro de exposição (a_validar)');

  IF p_ind_apuracao = 2 THEN
    v_acc := folha.esocial_entrada_bloqueia(v_acc, 'decimo_terceiro_nao_suportado',
      'S-1200 anual (13º): a composição das duas parcelas num único evento ainda não foi definida com o DP; o caso não é gerado');
  ELSE
    IF folha.esocial_periodo_fechado(v_conta, p_employer_id, p_ambiente, p_ind_apuracao, p_periodo) THEN
      v_acc := folha.esocial_entrada_bloqueia(v_acc, 'periodo_fechado',
        format('O período %s está fechado no eSocial: reabra com o S-1298 antes de gerar evento periódico', to_char(p_periodo, 'YYYY-MM')));
    END IF;
    -- folha do período: toda folha do empregador no mês, dos processos que o S-1200 cobre, tem de estar fechada
    FOR v_run IN
      SELECT r.run_id, r.status, r.tipo_processo, r.sequencia FROM folha.payroll_run r
       WHERE r.account_id = v_conta AND r.employer_id = p_employer_id AND r.competencia = p_periodo
         AND r.tipo_processo IN ('mensal', 'complementar', 'ferias') AND r.status <> 'cancelled'
       ORDER BY r.tipo_processo, r.sequencia
    LOOP
      IF v_run.status <> 'closed' THEN
        v_acc := folha.esocial_entrada_bloqueia(v_acc, 'folha_aberta',
          format('A folha %s (%s) do período está %s: só folha fechada gera S-1200', v_run.run_id, v_run.tipo_processo, v_run.status));
      ELSE
        SELECT count(*) INTO v_n FROM folha.payroll_pendency d
         WHERE d.account_id = v_conta AND d.run_id = v_run.run_id AND d.liberada_em IS NULL;
        IF v_n > 0 THEN
          v_acc := folha.esocial_entrada_bloqueia(v_acc, 'pendencia_aberta',
            format('A folha %s tem %s pendência(s) sem liberação: não gera S-1200', v_run.run_id, v_n));
        END IF;
      END IF;
    END LOOP;

    IF EXISTS (SELECT 1 FROM folha.external_remuneration x
                WHERE x.account_id = v_conta AND x.employee_id = p_employee_id AND x.competencia = p_periodo) THEN
      v_acc := folha.esocial_entrada_bloqueia(v_acc, 'multiplos_vinculos',
        'Há remuneração de outro vínculo no mês: o grupo infoMV exige a inscrição e a categoria da outra fonte, que o cadastro não guarda; o caso não é enviado sem o grupo');
    END IF;

    FOR v_row IN
      SELECT pr.result_id, pr.run_id, pr.contract_id, pr.liquido, r.tipo_processo, r.sequencia, r.competencia
        FROM folha.payroll_result pr
        JOIN folha.payroll_run r ON r.account_id = pr.account_id AND r.run_id = pr.run_id
       WHERE pr.account_id = v_conta AND pr.employee_id = p_employee_id AND r.employer_id = p_employer_id
         AND r.competencia = p_periodo AND r.tipo_processo IN ('mensal', 'complementar', 'ferias') AND r.status = 'closed'
       ORDER BY r.tipo_processo, r.sequencia, pr.contract_id
    LOOP
      v_k := jsonb_array_length(v_dms);
      v_origens := v_origens || jsonb_build_array(jsonb_build_object('run_id', v_row.run_id, 'result_id', v_row.result_id));
      SELECT * INTO v_con FROM folha.employment_contract k WHERE k.account_id = v_conta AND k.contract_id = v_row.contract_id;
      IF v_con.regime_trabalho = 'pj' THEN
        v_acc := folha.esocial_entrada_bloqueia(v_acc, 'prestador_pj',
          format('Contrato %s é de prestador PJ: não é trabalhador do eSocial e não gera S-1200', v_con.contract_id));
        v_dms := v_dms || jsonb_build_array('null'::jsonb);
        CONTINUE;
      ELSIF v_con.regime_trabalho = 'estagio' THEN
        v_acc := folha.esocial_entrada_bloqueia(v_acc, 'estagiario_sem_gerador',
          format('Contrato %s é de estágio (categoria 901, S-2300/S-1200 de TSVE): sem gerador nesta versão', v_con.contract_id));
        v_dms := v_dms || jsonb_build_array('null'::jsonb);
        CONTINUE;
      END IF;
      SELECT * INTO v_ce FROM folha.contract_esocial c WHERE c.account_id = v_conta AND c.contract_id = v_row.contract_id;
      v_base := format('dados.demonstrativos[%s]', v_k);
      IF NOT FOUND THEN
        v_acc := folha.esocial_entrada_falta(v_acc, v_base || '.codCateg', 'contrato sem dados do eSocial (contract_esocial)');
        v_acc := folha.esocial_entrada_falta(v_acc, v_base || '.estabelecimentos[0].remuneracoes[0].matricula', 'contrato sem dados do eSocial (contract_esocial)');
        v_dms := v_dms || jsonb_build_array('null'::jsonb);
        CONTINUE;
      END IF;
      v_acc := folha.esocial_entrada_exige(v_acc, v_base || '.codCateg', v_ce.cod_categ, 'categoria do trabalhador (Tabela 01) não informada');
      v_acc := folha.esocial_entrada_dominio(v_acc, 'dados.demonstrativos[].codCateg', 'codCateg', v_ce.cod_categ, '01');

      -- identificador estável do demonstrativo: o já gravado; senão AAAAMM-matrícula-letra[sequência]
      SELECT d.ide_dm_dev INTO v_ide FROM folha.payroll_demonstrative d WHERE d.account_id = v_conta AND d.result_id = v_row.result_id;
      IF v_ide IS NULL THEN
        v_letra := CASE v_row.tipo_processo WHEN 'mensal' THEN 'M' WHEN 'complementar' THEN 'C' WHEN 'ferias' THEN 'F' END;
        v_ide := to_char(v_row.competencia, 'YYYYMM') || '-' || v_ce.matricula || '-' || v_letra
                 || CASE WHEN v_row.sequencia > 1 THEN v_row.sequencia::text ELSE '' END;
        IF char_length(v_ide) > 30 OR v_ide !~ '^[A-Za-z0-9][-_A-Za-z0-9./]*$' THEN
          v_acc := folha.esocial_entrada_falta(v_acc, v_base || '.ideDmDev',
            format('o identificador derivado (%s) passa de 30 posições ou tem caractere fora da lista; ajuste a matrícula', v_ide));
          v_ide := NULL;
        END IF;
      END IF;

      -- lotação: exatamente uma, com 100%
      SELECT count(*) INTO v_n FROM folha.contract_tax_allocation a
       WHERE a.account_id = v_conta AND a.contract_id = v_row.contract_id
         AND a.vigencia_inicio <= v_fim_mes AND (a.vigencia_fim IS NULL OR a.vigencia_fim >= p_periodo);
      IF v_n = 0 THEN
        v_acc := folha.esocial_entrada_falta(v_acc, v_base || '.estabelecimentos[0].codLotacao', 'contrato sem rateio por lotação no mês (contract_tax_allocation)');
      ELSIF v_n > 1 THEN
        v_acc := folha.esocial_entrada_bloqueia(v_acc, 'rateio_por_lotacao',
          format('Contrato %s está rateado entre %s lotações no mês: a abertura da remuneração por lotação não é gerada nesta versão', v_con.contract_id, v_n));
      END IF;
      SELECT a.percentual, t.codigo_lotacao, s.tipo_inscricao, s.inscricao INTO v_aloc
        FROM folha.contract_tax_allocation a
        JOIN folha.tax_allocation t ON t.account_id = a.account_id AND t.allocation_id = a.allocation_id
        JOIN folha.establishment s ON s.account_id = t.account_id AND s.establishment_id = t.establishment_id
       WHERE a.account_id = v_conta AND a.contract_id = v_row.contract_id
         AND a.vigencia_inicio <= v_fim_mes AND (a.vigencia_fim IS NULL OR a.vigencia_fim >= p_periodo)
       ORDER BY a.vigencia_inicio DESC LIMIT 1;
      IF v_n = 1 AND v_aloc.percentual <> 100 THEN
        v_acc := folha.esocial_entrada_bloqueia(v_acc, 'rateio_por_lotacao',
          format('O rateio do contrato %s soma %s%% na única lotação do mês: deve ser 100%%', v_con.contract_id, v_aloc.percentual));
      END IF;
      IF v_n = 1 AND (v_aloc.inscricao IS NULL OR v_aloc.inscricao !~ '^([0-9]{12}|[A-Z0-9]{12}[0-9]{2})$') THEN
        v_acc := folha.esocial_entrada_falta(v_acc, v_base || '.estabelecimentos[0].nrInsc', 'inscrição do estabelecimento fora do formato do leiaute');
      END IF;

      -- itens: uma linha por rubrica do resultado
      v_itens := '[]'::jsonb; v_kk := 0; v_prov := 0; v_desc := 0;
      FOR v_item IN
        SELECT i.code_id, i.rubrica_codigo, i.tipo_rubrica, i.quantidade, i.valor FROM folha.payroll_result_item i
         WHERE i.account_id = v_conta AND i.result_id = v_row.result_id
           AND i.tipo_rubrica IN ('provento', 'desconto', 'informativa') AND i.valor > 0
         ORDER BY i.ordem
      LOOP
        IF v_item.tipo_rubrica = 'provento' THEN v_prov := v_prov + v_item.valor; ELSIF v_item.tipo_rubrica = 'desconto' THEN v_desc := v_desc + v_item.valor; END IF;
        SELECT * INTO v_cfg FROM folha.rubric_esocial_config c
         WHERE c.account_id = v_conta AND c.employer_id = p_employer_id AND c.code_id = v_item.code_id
           AND c.vigencia_inicio <= p_periodo AND (c.vigencia_fim IS NULL OR c.vigencia_fim >= p_periodo);
        IF NOT FOUND THEN
          v_acc := folha.esocial_entrada_falta(v_acc,
            v_base || format('.estabelecimentos[0].remuneracoes[0].itens[%s].ideTabRubr', v_kk),
            format('rubrica %s sem cadastro no S-1010 (rubric_esocial_config) para %s', v_item.rubrica_codigo, to_char(p_periodo, 'YYYY-MM')));
        ELSIF v_cfg.ind_apur_ir IS NULL THEN
          v_acc := folha.esocial_entrada_falta(v_acc,
            v_base || format('.estabelecimentos[0].remuneracoes[0].itens[%s].indApurIR', v_kk),
            format('rubrica %s sem indApurIR no cadastro do S-1010 (o gerador exige a partir de 2021-07)', v_item.rubrica_codigo));
        ELSE
          v_qtd := CASE WHEN v_item.quantidade IS NOT NULL AND round(v_item.quantidade, 2) > 0 THEN round(v_item.quantidade, 2) END;
          IF v_item.quantidade IS NOT NULL AND v_item.quantidade <> round(v_item.quantidade, 2) THEN
            v_acc := folha.esocial_entrada_pende(v_acc, 'dados.demonstrativos[].itens[].qtdRubr',
              'quantidade com mais de duas casas foi arredondada para duas (limite do leiaute)');
          END IF;
          v_itens := v_itens || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
            'codRubr', v_cfg.cod_rubr, 'ideTabRubr', v_cfg.ide_tab_rubr,
            'qtdRubr', CASE WHEN v_qtd IS NOT NULL THEN folha.esocial_entrada_dec(v_qtd) END,
            'vrRubr', folha.esocial_entrada_dec(v_item.valor), 'indApurIR', v_cfg.ind_apur_ir)));
        END IF;
        v_kk := v_kk + 1;
      END LOOP;
      IF v_kk = 0 THEN
        v_acc := folha.esocial_entrada_bloqueia(v_acc, 'sem_itens', format('O resultado %s não tem rubrica de remuneração (provento, desconto ou informativa)', v_row.result_id));
      ELSIF v_kk > 200 THEN
        v_acc := folha.esocial_entrada_bloqueia(v_acc, 'itens_demais', format('O resultado %s tem %s rubricas: o leiaute aceita até 200 por remuneração', v_row.result_id, v_kk));
      ELSIF v_prov - v_desc <> v_row.liquido THEN
        v_acc := folha.esocial_entrada_bloqueia(v_acc, 'itens_nao_fecham_liquido',
          format('No resultado %s, proventos (%s) menos descontos (%s) não fecham o líquido (%s): o cálculo precisa ser conferido antes do S-1200',
                 v_row.result_id, v_prov, v_desc, v_row.liquido));
      END IF;

      v_dm := jsonb_build_object(
        'ideDmDev', v_ide, 'codCateg', v_ce.cod_categ,
        'estabelecimentos', jsonb_build_array(jsonb_build_object(
          'tpInsc', folha.esocial_entrada_tpinsc_estab(v_aloc.tipo_inscricao), 'nrInsc', v_aloc.inscricao,
          'codLotacao', v_aloc.codigo_lotacao,
          'remuneracoes', jsonb_build_array(jsonb_build_object('matricula', v_ce.matricula, 'itens', v_itens)))));
      IF v_ce.cbo_cargo IS NOT NULL THEN
        v_dm := v_dm || jsonb_build_object('infoComplCont', jsonb_build_object('codCBO', v_ce.cbo_cargo));
      END IF;
      v_dms := v_dms || jsonb_build_array(v_dm);
      IF v_ide IS NOT NULL THEN
        v_demos := v_demos || jsonb_build_array(jsonb_build_object('employee_id', p_employee_id, 'run_id', v_row.run_id,
                                                                   'result_id', v_row.result_id, 'ide_dm_dev', v_ide));
      END IF;
    END LOOP;

    IF jsonb_array_length(v_dms) = 0 THEN
      v_acc := folha.esocial_entrada_bloqueia(v_acc, 'sem_folha_fechada',
        format('Nenhuma folha fechada do empregador em %s tem resultado deste trabalhador', to_char(p_periodo, 'YYYY-MM')));
    END IF;

    -- retificação: versão validada da mesma chave exige a retificação explícita, com o recibo vigente
    SELECT * INTO v_val FROM folha.esocial_event x
     WHERE x.account_id = v_conta AND x.employer_id = p_employer_id AND x.evento_codigo = 'S-1200' AND x.ambiente = p_ambiente
       AND x.employee_id = p_employee_id AND x.ind_apuracao = 1 AND x.periodo_apuracao = p_periodo AND x.estado = 'validado'
     ORDER BY x.versao DESC LIMIT 1;
    IF FOUND THEN
      IF p_retificar_event_id IS NULL THEN
        v_acc := folha.esocial_entrada_bloqueia(v_acc, 'ja_validado',
          format('Já existe S-1200 validado desta chave (evento %s): informe p_retificar_event_id e o motivo para gerar a retificação', v_val.event_id));
      ELSIF p_retificar_event_id <> v_val.event_id THEN
        v_acc := folha.esocial_entrada_bloqueia(v_acc, 'retificacao_de_outra_versao', 'O evento a retificar não é a versão validada vigente da chave');
      ELSIF v_val.recibo_numero !~ '^1\.[0-9]\.[0-9]{19}$' THEN
        v_acc := folha.esocial_entrada_bloqueia(v_acc, 'recibo_fora_do_formato', 'O recibo guardado do evento validado não está no formato do leiaute');
      ELSIF btrim(COALESCE(p_motivo, '')) = '' THEN
        v_acc := folha.esocial_entrada_bloqueia(v_acc, 'motivo_obrigatorio', 'A retificação exige o motivo (aprovação registrada)');
      ELSE
        v_ret := jsonb_build_object('retificacao', jsonb_build_object('nrRecibo', v_val.recibo_numero));
      END IF;
    ELSIF p_retificar_event_id IS NOT NULL THEN
      v_acc := folha.esocial_entrada_bloqueia(v_acc, 'nada_a_retificar', 'Não há S-1200 validado desta chave para retificar');
    END IF;
  END IF;

  PERFORM folha.esocial_entrada_contexto(p_registrar, p_retificar_event_id IS NOT NULL);
  RETURN folha.esocial_entrada_concluir(
    v_ctx, p_employer_id, 'S-1200', p_ambiente,
    jsonb_build_object('indApuracao', p_ind_apuracao, 'perApur', to_char(p_periodo, 'YYYY-MM'))
      || v_ret || jsonb_build_object('trabalhador', jsonb_build_object('cpfTrab', v_ee.cpf::text), 'demonstrativos', v_dms),
    v_empregador, p_gerado_em, v_acc,
    jsonb_build_object('employee_id', p_employee_id, 'ind_apuracao', p_ind_apuracao, 'periodo_apuracao', p_periodo),
    v_origens, p_registrar, p_retificar_event_id, NULL, p_motivo, v_demos);
END
$function$;

-- 5.3 S-1210 (pagamentos): um evento por empregador, trabalhador e MÊS DO PAGAMENTO (perApur). Cada pagamento
--     registrado (payroll_payment) vira um infoPgto com dtPgto efetiva, perRef (competência do S-1200) e o
--     ideDmDev gravado ao registrar o S-1200. Dedução de IRRF (dependentes, pensão alimentícia, plano de saúde)
--     exige infoIRComplem, que o gerador ainda não tem: o caso é BLOQUEADO.
CREATE FUNCTION folha.esocial_entrada_s1210_v1(
  p_employer_id uuid, p_employee_id uuid, p_periodo date, p_ambiente text,
  p_gerado_em timestamp DEFAULT NULL, p_registrar boolean DEFAULT true, p_retificar_event_id uuid DEFAULT NULL,
  p_motivo text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx jsonb;
  v_conta uuid;
  v_emp folha.employer%ROWTYPE;
  v_ee folha.employee%ROWTYPE;
  v_acc jsonb := folha.esocial_entrada_acc();
  v_empregador jsonb;
  v_pay record;
  v_val folha.esocial_event%ROWTYPE;
  v_pgs jsonb := '[]'::jsonb;
  v_origens jsonb := '[]'::jsonb;
  v_ret jsonb := '{}'::jsonb;
  v_ide text;
  v_n integer;
  v_chaves text[] := ARRAY[]::text[];
  v_chave text;
  v_ja_pendencia uuid[] := ARRAY[]::uuid[];
BEGIN
  v_ctx := folha.esocial_entrada_contexto(p_registrar, p_retificar_event_id IS NOT NULL);
  v_conta := (v_ctx ->> 'account_id')::uuid;
  IF p_ambiente IS NULL OR p_ambiente NOT IN ('producao', 'producao_restrita') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Ambiente deve ser producao ou producao_restrita';
  END IF;
  IF p_periodo IS NULL OR p_periodo <> date_trunc('month', p_periodo)::date THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'O período (mês do pagamento) deve ser o primeiro dia do mês';
  END IF;
  SELECT * INTO v_emp FROM folha.employer e WHERE e.account_id = v_conta AND e.employer_id = p_employer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = format('Empregador %s não encontrado nesta conta', p_employer_id);
  END IF;
  SELECT * INTO v_ee FROM folha.employee e
   WHERE e.account_id = v_conta AND e.employee_id = p_employee_id
     AND EXISTS (SELECT 1 FROM folha.employment_contract k
                  WHERE k.account_id = v_conta AND k.employer_id = p_employer_id AND k.employee_id = p_employee_id);
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = format('Trabalhador %s não tem contrato com o empregador %s nesta conta', p_employee_id, p_employer_id);
  END IF;

  v_empregador := folha.esocial_entrada_empregador(v_emp);
  IF v_empregador IS NULL THEN
    v_acc := folha.esocial_entrada_falta(v_acc, 'empregador.nrInsc', 'empregador sem CNPJ ou CPF utilizável (tipo caepf não informa o CPF)');
  END IF;
  IF v_ee.cpf !~ '^[0-9]{11}$' THEN
    v_acc := folha.esocial_entrada_falta(v_acc, 'dados.beneficiario.cpfBenef', 'CPF fora de onze dígitos');
  END IF;

  IF folha.esocial_periodo_fechado(v_conta, p_employer_id, p_ambiente, 1::smallint, p_periodo) THEN
    v_acc := folha.esocial_entrada_bloqueia(v_acc, 'periodo_fechado',
      format('O período %s está fechado no eSocial: reabra com o S-1298 antes de gerar evento periódico', to_char(p_periodo, 'YYYY-MM')));
  END IF;
  FOR v_pay IN
    SELECT p.payment_id, p.result_id, p.run_id, p.dt_pgto, p.tp_pgto, p.vr_liq,
           r.tipo_processo, r.competencia, r.status AS run_status, r.data_pagamento
      FROM folha.payroll_payment p
      JOIN folha.payroll_run r ON r.account_id = p.account_id AND r.run_id = p.run_id
     WHERE p.account_id = v_conta AND p.employer_id = p_employer_id AND p.employee_id = p_employee_id
       AND date_trunc('month', p.dt_pgto)::date = p_periodo
     ORDER BY p.dt_pgto, r.competencia, r.tipo_processo, p.payment_id
  LOOP
    v_n := jsonb_array_length(v_pgs);
    v_origens := v_origens || jsonb_build_array(jsonb_build_object('run_id', v_pay.run_id, 'result_id', v_pay.result_id));
    IF v_pay.tp_pgto <> 1 THEN
      v_acc := folha.esocial_entrada_bloqueia(v_acc, 'rescisao_sem_gerador',
        format('O pagamento %s é de rescisão (tpPgto 2, ligado ao S-2299): esta versão não monta o S-1210 de rescisão', v_pay.payment_id));
      v_pgs := v_pgs || jsonb_build_array('null'::jsonb);
      CONTINUE;
    END IF;
    IF v_pay.tipo_processo NOT IN ('mensal', 'complementar', 'ferias') THEN
      v_acc := folha.esocial_entrada_bloqueia(v_acc, 'processo_sem_s1200',
        format('O pagamento %s é do processo %s, que não gera S-1200 nesta versão: sem ideDmDev para referenciar', v_pay.payment_id, v_pay.tipo_processo));
      v_pgs := v_pgs || jsonb_build_array('null'::jsonb);
      CONTINUE;
    END IF;
    IF v_pay.run_status <> 'closed' THEN
      v_acc := folha.esocial_entrada_bloqueia(v_acc, 'folha_aberta', format('A folha %s está %s: só folha fechada gera S-1210', v_pay.run_id, v_pay.run_status));
    ELSIF EXISTS (SELECT 1 FROM folha.payroll_pendency d WHERE d.account_id = v_conta AND d.run_id = v_pay.run_id AND d.liberada_em IS NULL) THEN
      v_acc := folha.esocial_entrada_bloqueia(v_acc, 'pendencia_aberta', format('A folha %s tem pendência sem liberação: não gera S-1210', v_pay.run_id));
    END IF;
    IF v_pay.data_pagamento IS NULL OR date_trunc('month', v_pay.data_pagamento)::date <> p_periodo THEN
      v_acc := folha.esocial_entrada_bloqueia(v_acc, 'data_prevista_diverge',
        format('A data de pagamento prevista da folha %s (%s) não cai no mês do pagamento efetivo (%s): a fila exige o mesmo mês; corrija a folha antes',
               v_pay.run_id, COALESCE(v_pay.data_pagamento::text, 'sem data'), to_char(p_periodo, 'YYYY-MM')));
    END IF;
    SELECT d.ide_dm_dev INTO v_ide FROM folha.payroll_demonstrative d WHERE d.account_id = v_conta AND d.result_id = v_pay.result_id;
    IF v_ide IS NULL THEN
      v_acc := folha.esocial_entrada_falta(v_acc, format('dados.pagamentos[%s].ideDmDev', v_n),
        format('o resultado %s ainda não tem demonstrativo: gere e registre o S-1200 antes do S-1210', v_pay.result_id));
    END IF;
    v_chave := v_pay.tp_pgto::text || '|' || to_char(v_pay.competencia, 'YYYY-MM') || '|' || COALESCE(v_ide, '');
    IF v_chave = ANY (v_chaves) THEN
      v_acc := folha.esocial_entrada_bloqueia(v_acc, 'chave_repetida',
        'Dois pagamentos do mesmo demonstrativo no mesmo mês repetem a chave tpPgto + perRef + ideDmDev do infoPgto: o leiaute não aceita');
    END IF;
    v_chaves := v_chaves || v_chave;
    -- dedução de IRRF a declarar (infoIRComplem) não é gerada: bloqueia
    IF v_pay.result_id <> ALL (v_ja_pendencia) THEN
      v_ja_pendencia := v_ja_pendencia || v_pay.result_id;
      IF EXISTS (SELECT 1 FROM folha.payroll_result_item i
                  WHERE i.account_id = v_conta AND i.result_id = v_pay.result_id
                    AND (i.rubrica_codigo IN ('PENSAO_ALIMENTICIA', 'PLANO_SAUDE')
                         OR i.detalhe ->> 'deducao_aplicada' = 'legais'
                         OR (i.detalhe ->> 'dependentes' ~ '^[0-9]+(\.[0-9]+)?$' AND (i.detalhe ->> 'dependentes')::numeric > 0))) THEN
        v_acc := folha.esocial_entrada_bloqueia(v_acc, 'info_ir_complementar',
          format('O resultado %s tem dedução de IRRF a declarar (dependente, pensão alimentícia ou plano de saúde): o infoIRComplem não é gerado nesta versão', v_pay.result_id));
      END IF;
    END IF;
    v_pgs := v_pgs || jsonb_build_array(jsonb_build_object(
      'dtPgto', folha.esocial_entrada_data(v_pay.dt_pgto), 'tpPgto', v_pay.tp_pgto,
      'perRef', to_char(v_pay.competencia, 'YYYY-MM'), 'ideDmDev', v_ide, 'vrLiq', folha.esocial_entrada_dec(v_pay.vr_liq)));
  END LOOP;
  IF jsonb_array_length(v_pgs) = 0 THEN
    v_acc := folha.esocial_entrada_bloqueia(v_acc, 'sem_pagamento',
      format('Nenhum pagamento efetivo registrado em %s para este trabalhador (registre a data efetiva: ela nunca é deduzida)', to_char(p_periodo, 'YYYY-MM')));
  END IF;
  IF EXISTS (SELECT 1 FROM folha.employee_dependent d WHERE d.account_id = v_conta AND d.employee_id = p_employee_id AND d.dep_irrf) THEN
    v_acc := folha.esocial_entrada_bloqueia(v_acc, 'info_ir_complementar',
      'O trabalhador tem dependente para IRRF no cadastro: o infoIRComplem não é gerado nesta versão');
  END IF;

  SELECT * INTO v_val FROM folha.esocial_event x
   WHERE x.account_id = v_conta AND x.employer_id = p_employer_id AND x.evento_codigo = 'S-1210' AND x.ambiente = p_ambiente
     AND x.employee_id = p_employee_id AND x.periodo_apuracao = p_periodo AND x.estado = 'validado'
   ORDER BY x.versao DESC LIMIT 1;
  IF FOUND THEN
    IF p_retificar_event_id IS NULL THEN
      v_acc := folha.esocial_entrada_bloqueia(v_acc, 'ja_validado',
        format('Já existe S-1210 validado desta chave (evento %s): informe p_retificar_event_id e o motivo para gerar a retificação', v_val.event_id));
    ELSIF p_retificar_event_id <> v_val.event_id THEN
      v_acc := folha.esocial_entrada_bloqueia(v_acc, 'retificacao_de_outra_versao', 'O evento a retificar não é a versão validada vigente da chave');
    ELSIF v_val.recibo_numero !~ '^1\.[0-9]\.[0-9]{19}$' THEN
      v_acc := folha.esocial_entrada_bloqueia(v_acc, 'recibo_fora_do_formato', 'O recibo guardado do evento validado não está no formato do leiaute');
    ELSIF btrim(COALESCE(p_motivo, '')) = '' THEN
      v_acc := folha.esocial_entrada_bloqueia(v_acc, 'motivo_obrigatorio', 'A retificação exige o motivo (aprovação registrada)');
    ELSE
      v_ret := jsonb_build_object('retificacao', jsonb_build_object('nrRecibo', v_val.recibo_numero));
    END IF;
  ELSIF p_retificar_event_id IS NOT NULL THEN
    v_acc := folha.esocial_entrada_bloqueia(v_acc, 'nada_a_retificar', 'Não há S-1210 validado desta chave para retificar');
  END IF;

  PERFORM folha.esocial_entrada_contexto(p_registrar, p_retificar_event_id IS NOT NULL);
  RETURN folha.esocial_entrada_concluir(
    v_ctx, p_employer_id, 'S-1210', p_ambiente,
    jsonb_build_object('perApur', to_char(p_periodo, 'YYYY-MM')) || v_ret
      || jsonb_build_object('beneficiario', jsonb_build_object('cpfBenef', v_ee.cpf::text), 'pagamentos', v_pgs),
    v_empregador, p_gerado_em, v_acc,
    jsonb_build_object('employee_id', p_employee_id, 'periodo_apuracao', p_periodo),
    v_origens, p_registrar, p_retificar_event_id, NULL, p_motivo, NULL);
END
$function$;

-- 5.4 S-2200 (admissão): um evento por empregador, trabalhador e vínculo. Só vínculo CLT/RGPS: estagiário é
--     S-2300 (sem gerador) e prestador PJ não é trabalhador do eSocial. Tudo vem do cadastro; sem o dado, "faltando".
CREATE FUNCTION folha.esocial_entrada_s2200_v1(
  p_employer_id uuid, p_contract_id uuid, p_ambiente text,
  p_gerado_em timestamp DEFAULT NULL, p_registrar boolean DEFAULT true, p_retificar_event_id uuid DEFAULT NULL,
  p_motivo text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx jsonb;
  v_conta uuid;
  v_emp folha.employer%ROWTYPE;
  v_con folha.employment_contract%ROWTYPE;
  v_ee folha.employee%ROWTYPE;
  v_en folha.employee_esocial%ROWTYPE;
  v_ce folha.contract_esocial%ROWTYPE;
  v_est folha.establishment%ROWTYPE;
  v_acc jsonb := folha.esocial_entrada_acc();
  v_empregador jsonb;
  v_val folha.esocial_event%ROWTYPE;
  v_ret jsonb := '{}'::jsonb;
  v_trab jsonb;
  v_vinc jsonb;
  v_celetista jsonb;
  v_contrato jsonb;
  v_deps jsonb;
  v_fone text;
  v_tem_en boolean;
  v_tem_ce boolean;
  v_tp text;
BEGIN
  v_ctx := folha.esocial_entrada_contexto(p_registrar, p_retificar_event_id IS NOT NULL);
  v_conta := (v_ctx ->> 'account_id')::uuid;
  IF p_ambiente IS NULL OR p_ambiente NOT IN ('producao', 'producao_restrita') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Ambiente deve ser producao ou producao_restrita';
  END IF;
  SELECT * INTO v_emp FROM folha.employer e WHERE e.account_id = v_conta AND e.employer_id = p_employer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = format('Empregador %s não encontrado nesta conta', p_employer_id);
  END IF;
  SELECT * INTO v_con FROM folha.employment_contract k
   WHERE k.account_id = v_conta AND k.employer_id = p_employer_id AND k.contract_id = p_contract_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = format('Contrato %s não é deste empregador nesta conta', p_contract_id);
  END IF;
  SELECT * INTO v_ee FROM folha.employee e WHERE e.account_id = v_conta AND e.employee_id = v_con.employee_id;

  v_empregador := folha.esocial_entrada_empregador(v_emp);
  IF v_empregador IS NULL THEN
    v_acc := folha.esocial_entrada_falta(v_acc, 'empregador.nrInsc', 'empregador sem CNPJ ou CPF utilizável (tipo caepf não informa o CPF)');
  END IF;

  IF v_con.regime_trabalho = 'estagio' THEN
    v_acc := folha.esocial_entrada_bloqueia(v_acc, 'estagiario_s2300', 'Estagiário não entra por S-2200: o evento é o S-2300 (TSVE), ainda sem gerador');
  ELSIF v_con.regime_trabalho = 'pj' THEN
    v_acc := folha.esocial_entrada_bloqueia(v_acc, 'prestador_pj', 'Prestador PJ não é trabalhador do eSocial: não há S-2200');
  ELSIF v_con.regime_trabalho NOT IN ('clt', 'aprendiz') THEN
    v_acc := folha.esocial_entrada_bloqueia(v_acc, 'regime_desconhecido', format('Regime %s sem tratamento no S-2200', v_con.regime_trabalho));
  END IF;

  SELECT * INTO v_en FROM folha.employee_esocial x WHERE x.account_id = v_conta AND x.employee_id = v_con.employee_id;
  v_tem_en := FOUND;
  SELECT * INTO v_ce FROM folha.contract_esocial x WHERE x.account_id = v_conta AND x.contract_id = p_contract_id;
  v_tem_ce := FOUND;
  IF NOT v_tem_en THEN
    v_acc := folha.esocial_entrada_falta(v_acc, 'dados.trabalhador', 'trabalhador sem dados do eSocial (employee_esocial)');
  END IF;
  IF NOT v_tem_ce THEN
    v_acc := folha.esocial_entrada_falta(v_acc, 'dados.vinculo', 'contrato sem dados do eSocial (contract_esocial)');
  END IF;

  -- trabalhador
  v_acc := folha.esocial_entrada_exige(v_acc, 'dados.trabalhador.sexo', v_ee.sexo::text, 'sexo não informado');
  IF v_ee.cpf !~ '^[0-9]{11}$' THEN
    v_acc := folha.esocial_entrada_falta(v_acc, 'dados.trabalhador.cpfTrab', 'CPF fora de onze dígitos');
  END IF;
  IF EXISTS (SELECT 1 FROM folha.employee_dependent d WHERE d.account_id = v_conta AND d.employee_id = v_con.employee_id
                AND d.dep_irrf AND d.cpf_dep IS NULL) THEN
    v_acc := folha.esocial_entrada_falta(v_acc, 'dados.trabalhador.dependente[].cpfDep', 'dependente com dedução de IRRF sem CPF (o gerador exige)');
  END IF;
  IF v_ee.nome_completo IS NULL OR char_length(btrim(v_ee.nome_completo)) NOT BETWEEN 2 AND 70 THEN
    v_acc := folha.esocial_entrada_falta(v_acc, 'dados.trabalhador.nmTrab', 'nome fora de 2 a 70 posições');
  END IF;
  IF v_tem_en THEN
    v_acc := folha.esocial_entrada_exige(v_acc, 'dados.trabalhador.racaCor', v_en.raca_cor::text, 'raça/cor não informada');
    IF v_en.raca_cor = 6 AND v_con.data_admissao >= DATE '2024-04-22' THEN
      v_acc := folha.esocial_entrada_falta(v_acc, 'dados.trabalhador.racaCor', 'raça/cor 6 não é aceita para admissão a partir de 2024-04-22 (regra do gerador)');
    END IF;
    v_acc := folha.esocial_entrada_dominio(v_acc, 'dados.trabalhador.racaCor', 'racaCor', v_en.raca_cor::text, 'XSD');
    v_acc := folha.esocial_entrada_exige(v_acc, 'dados.trabalhador.grauInstr', v_en.grau_instr, 'grau de instrução não informado');
    v_acc := folha.esocial_entrada_dominio(v_acc, 'dados.trabalhador.grauInstr', 'grauInstr', v_en.grau_instr, 'XSD');
    v_acc := folha.esocial_entrada_exige(v_acc, 'dados.trabalhador.nascimento.paisNascto', v_en.pais_nascto, 'país de nascimento não informado');
    v_acc := folha.esocial_entrada_exige(v_acc, 'dados.trabalhador.nascimento.paisNac', v_en.pais_nac, 'país de nacionalidade não informado');
    v_acc := folha.esocial_entrada_exige(v_acc, 'dados.trabalhador.endereco.brasil.dscLograd', v_en.dsc_lograd, 'logradouro não informado');
    v_acc := folha.esocial_entrada_exige(v_acc, 'dados.trabalhador.endereco.brasil.nrLograd', v_en.nr_lograd, 'número do logradouro não informado');
    v_acc := folha.esocial_entrada_exige(v_acc, 'dados.trabalhador.endereco.brasil.cep', v_en.cep, 'CEP não informado');
    v_acc := folha.esocial_entrada_exige(v_acc, 'dados.trabalhador.endereco.brasil.codMunic', v_en.cod_munic, 'código IBGE do município não informado');
    v_acc := folha.esocial_entrada_exige(v_acc, 'dados.trabalhador.endereco.brasil.uf', v_en.uf, 'UF não informada');
  END IF;
  v_fone := regexp_replace(COALESCE(v_ee.telefone, ''), '[^0-9]', '', 'g');
  SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'nmDep', d.nm_dep, 'dtNascto', folha.esocial_entrada_data(d.dt_nascto), 'tpDep', d.tp_dep, 'cpfDep', d.cpf_dep,
           'depIRRF', folha.esocial_entrada_sn(d.dep_irrf), 'depSF', folha.esocial_entrada_sn(d.dep_sf),
           'incTrab', folha.esocial_entrada_sn(d.inc_trab), 'descrDep', d.descr_dep)) ORDER BY d.created_at, d.dependent_id)
    INTO v_deps
    FROM folha.employee_dependent d WHERE d.account_id = v_conta AND d.employee_id = v_con.employee_id;
  IF v_deps IS NOT NULL AND jsonb_array_length(v_deps) > 99 THEN
    v_acc := folha.esocial_entrada_bloqueia(v_acc, 'dependentes_demais', 'O leiaute aceita até 99 dependentes');
  END IF;
  FOR v_tp IN SELECT DISTINCT d.tp_dep FROM folha.employee_dependent d
               WHERE d.account_id = v_conta AND d.employee_id = v_con.employee_id AND d.tp_dep IS NOT NULL
  LOOP
    v_acc := folha.esocial_entrada_dominio(v_acc, 'dados.trabalhador.dependente[].tpDep', 'tpDep', v_tp, '07');
  END LOOP;

  -- vínculo
  IF v_tem_ce THEN
    v_acc := folha.esocial_entrada_exige(v_acc, 'dados.vinculo.cadIni', v_ce.cad_ini::text, 'indicação de cadastramento inicial (cadIni) não informada');
    IF v_ce.tp_reg_prev IS NULL THEN
      v_acc := folha.esocial_entrada_falta(v_acc, 'dados.vinculo.tpRegPrev', 'regime previdenciário não informado');
    ELSIF v_ce.tp_reg_prev <> 1 THEN
      v_acc := folha.esocial_entrada_bloqueia(v_acc, 'regime_previdenciario', 'S-2200 só para vínculo de RGPS (tpRegPrev 1): os demais regimes não são gerados');
    END IF;
    v_acc := folha.esocial_entrada_exige(v_acc, 'dados.vinculo.infoCeletista.indAdmissao', v_ce.ind_admissao::text);
    v_acc := folha.esocial_entrada_exige(v_acc, 'dados.vinculo.infoCeletista.tpRegJor', v_ce.tp_reg_jor::text);
    v_acc := folha.esocial_entrada_exige(v_acc, 'dados.vinculo.infoCeletista.natAtividade', v_ce.nat_atividade::text);
    v_acc := folha.esocial_entrada_exige(v_acc, 'dados.vinculo.infoCeletista.cnpjSindCategProf', v_ce.cnpj_sind_categ_prof, 'CNPJ do sindicato da categoria não informado');
    v_acc := folha.esocial_entrada_exige(v_acc, 'dados.vinculo.infoContrato.CBOCargo', v_ce.cbo_cargo, 'CBO do cargo não informado');
    v_acc := folha.esocial_entrada_exige(v_acc, 'dados.vinculo.infoContrato.codCateg', v_ce.cod_categ, 'categoria do trabalhador (Tabela 01) não informada');
    IF v_ce.cod_categ IS NOT NULL AND v_ce.cod_categ NOT IN ('101', '102', '103', '105', '107', '108', '111') THEN
      v_acc := folha.esocial_entrada_falta(v_acc, 'dados.vinculo.infoContrato.codCateg',
        format('a categoria %s não é de vínculo celetista no escopo do gerador (101, 102, 103, 105, 107, 108, 111)', v_ce.cod_categ));
    END IF;
    IF v_ce.ind_admissao = 3 THEN
      v_acc := folha.esocial_entrada_bloqueia(v_acc, 'ind_admissao_3', 'indAdmissao 3 exige o número do processo trabalhista (nrProcTrab), que o cadastro não guarda: o caso não é gerado');
    END IF;
    IF v_ce.tp_contr = 2 AND v_ce.dt_term IS NULL THEN
      v_acc := folha.esocial_entrada_falta(v_acc, 'dados.vinculo.infoContrato.duracao.dtTerm', 'contrato por prazo determinado sem a data de término');
    END IF;
    IF v_ce.tp_contr = 3 AND v_ce.obj_det IS NULL THEN
      v_acc := folha.esocial_entrada_falta(v_acc, 'dados.vinculo.infoContrato.duracao.objDet', 'contrato por obra certa sem o objeto determinante');
    END IF;
    IF v_ce.tmp_parc = 1 THEN
      v_acc := folha.esocial_entrada_falta(v_acc, 'dados.vinculo.infoContrato.horContratual.tmpParc', 'tmpParc 1 só vale para a categoria 104 (regra do gerador)');
    END IF;
    IF v_ce.und_sal_fixo IN (6, 7) AND v_ce.dsc_sal_var IS NULL THEN
      v_acc := folha.esocial_entrada_falta(v_acc, 'dados.vinculo.infoContrato.remuneracao.dscSalVar', 'unidade de salário 6 ou 7 exige a descrição do salário variável');
    END IF;
    IF v_ce.hor_noturno IS NULL AND v_ce.cod_categ IS DISTINCT FROM '111' THEN
      v_acc := folha.esocial_entrada_falta(v_acc, 'dados.vinculo.infoContrato.horContratual.horNoturno', 'indicação de horário noturno não informada');
    END IF;
    IF v_con.data_admissao < DATE '1988-10-05' AND v_ce.dt_opc_fgts IS NULL THEN
      v_acc := folha.esocial_entrada_falta(v_acc, 'dados.vinculo.infoCeletista.FGTS.dtOpcFGTS', 'admissão anterior a 05/10/1988 exige a data de opção pelo FGTS');
    END IF;
    v_acc := folha.esocial_entrada_dominio(v_acc, 'dados.vinculo.infoContrato.codCateg', 'codCateg', v_ce.cod_categ, '01');
    v_acc := folha.esocial_entrada_exige(v_acc, 'dados.vinculo.infoContrato.remuneracao.undSalFixo', v_ce.und_sal_fixo::text);
    v_acc := folha.esocial_entrada_exige(v_acc, 'dados.vinculo.infoContrato.duracao.tpContr', v_ce.tp_contr::text);
    v_acc := folha.esocial_entrada_exige(v_acc, 'dados.vinculo.infoContrato.horContratual.tpJornada', v_ce.tp_jornada::text, 'tipo de jornada contratual não informado');
    v_acc := folha.esocial_entrada_exige(v_acc, 'dados.vinculo.infoContrato.horContratual.tmpParc', v_ce.tmp_parc::text);
    v_acc := folha.esocial_entrada_exige(v_acc, 'dados.vinculo.infoContrato.horContratual.dscJorn', v_ce.dsc_jorn, 'descrição da jornada não informada');
    IF v_con.regime_trabalho = 'aprendiz' AND v_ce.aprend IS NULL THEN
      v_acc := folha.esocial_entrada_falta(v_acc, 'dados.vinculo.infoCeletista.aprend', 'aprendiz sem os dados de aprendizagem (contract_esocial.aprend)');
    END IF;
  END IF;
  IF v_con.cargo IS NULL OR char_length(btrim(v_con.cargo)) NOT BETWEEN 1 AND 100 THEN
    v_acc := folha.esocial_entrada_falta(v_acc, 'dados.vinculo.infoContrato.nmCargo', 'nome do cargo fora de 1 a 100 posições');
  END IF;
  IF v_con.salario_base IS NULL OR v_con.salario_base < 0 OR v_con.salario_base >= 1000000000000 THEN
    v_acc := folha.esocial_entrada_falta(v_acc, 'dados.vinculo.infoContrato.remuneracao.vrSalFx', 'salário base fora do limite do leiaute');
  END IF;
  IF v_con.establishment_id IS NULL THEN
    v_acc := folha.esocial_entrada_falta(v_acc, 'dados.vinculo.infoContrato.localTrabalho.localTrabGeral', 'contrato sem estabelecimento (local de trabalho)');
  ELSE
    SELECT * INTO v_est FROM folha.establishment s WHERE s.account_id = v_conta AND s.establishment_id = v_con.establishment_id;
    IF v_est.inscricao !~ '^([0-9]{12}|[A-Z0-9]{12}[0-9]{2})$' THEN
      v_acc := folha.esocial_entrada_falta(v_acc, 'dados.vinculo.infoContrato.localTrabalho.localTrabGeral.nrInsc', 'inscrição do estabelecimento fora do formato do leiaute');
    END IF;
  END IF;

  SELECT * INTO v_val FROM folha.esocial_event x
   WHERE x.account_id = v_conta AND x.employer_id = p_employer_id AND x.evento_codigo = 'S-2200' AND x.ambiente = p_ambiente
     AND x.contract_id = p_contract_id AND x.estado = 'validado'
   ORDER BY x.versao DESC LIMIT 1;
  IF FOUND THEN
    IF p_retificar_event_id IS NULL THEN
      v_acc := folha.esocial_entrada_bloqueia(v_acc, 'ja_validado',
        format('Já existe S-2200 validado deste vínculo (evento %s): informe p_retificar_event_id e o motivo para gerar a retificação', v_val.event_id));
    ELSIF p_retificar_event_id <> v_val.event_id THEN
      v_acc := folha.esocial_entrada_bloqueia(v_acc, 'retificacao_de_outra_versao', 'O evento a retificar não é a versão validada vigente da chave');
    ELSIF v_val.recibo_numero !~ '^1\.[0-9]\.[0-9]{19}$' THEN
      v_acc := folha.esocial_entrada_bloqueia(v_acc, 'recibo_fora_do_formato', 'O recibo guardado do evento validado não está no formato do leiaute');
    ELSIF btrim(COALESCE(p_motivo, '')) = '' THEN
      v_acc := folha.esocial_entrada_bloqueia(v_acc, 'motivo_obrigatorio', 'A retificação exige o motivo (aprovação registrada)');
    ELSE
      v_ret := jsonb_build_object('retificacao', jsonb_build_object('nrRecibo', v_val.recibo_numero));
    END IF;
  ELSIF p_retificar_event_id IS NOT NULL THEN
    v_acc := folha.esocial_entrada_bloqueia(v_acc, 'nada_a_retificar', 'Não há S-2200 validado deste vínculo para retificar');
  END IF;

  IF jsonb_array_length(v_acc -> 'faltando') = 0 AND jsonb_array_length(v_acc -> 'bloqueios') = 0 THEN
    v_trab := jsonb_strip_nulls(jsonb_build_object(
      'cpfTrab', v_ee.cpf::text, 'nmTrab', btrim(v_ee.nome_completo), 'sexo', v_ee.sexo::text, 'racaCor', v_en.raca_cor,
      'estCiv', v_en.est_civ, 'grauInstr', v_en.grau_instr, 'nmSoc', v_en.nm_soc,
      'nascimento', jsonb_build_object('dtNascto', folha.esocial_entrada_data(v_ee.data_nascimento),
                                       'paisNascto', v_en.pais_nascto, 'paisNac', v_en.pais_nac),
      'endereco', jsonb_build_object('brasil', jsonb_build_object(
        'tpLograd', v_en.tp_lograd, 'dscLograd', v_en.dsc_lograd, 'nrLograd', v_en.nr_lograd, 'complemento', v_en.complemento,
        'bairro', v_en.bairro, 'cep', v_en.cep, 'codMunic', v_en.cod_munic, 'uf', v_en.uf)),
      'infoDeficiencia', v_en.info_deficiencia,
      'dependente', v_deps,
      'contato', CASE WHEN v_fone ~ '^[0-9]{10,13}$' OR (v_ee.email IS NOT NULL AND char_length(v_ee.email) BETWEEN 6 AND 60)
                      THEN jsonb_strip_nulls(jsonb_build_object(
                             'fonePrinc', CASE WHEN v_fone ~ '^[0-9]{10,13}$' THEN v_fone END,
                             'emailPrinc', CASE WHEN char_length(v_ee.email) BETWEEN 6 AND 60 THEN v_ee.email END)) END));
    v_celetista := jsonb_strip_nulls(jsonb_build_object(
      'dtAdm', folha.esocial_entrada_data(v_con.data_admissao), 'tpAdmissao', 1, 'indAdmissao', v_ce.ind_admissao,
      'tpRegJor', v_ce.tp_reg_jor, 'natAtividade', v_ce.nat_atividade, 'dtBase', v_ce.dt_base,
      'cnpjSindCategProf', v_ce.cnpj_sind_categ_prof,
      'FGTS', CASE WHEN v_ce.dt_opc_fgts IS NOT NULL AND v_con.data_admissao < DATE '1988-10-05' THEN jsonb_build_object('dtOpcFGTS', folha.esocial_entrada_data(v_ce.dt_opc_fgts)) END,
      'aprend', CASE WHEN v_con.regime_trabalho = 'aprendiz' THEN v_ce.aprend END));
    v_contrato := jsonb_strip_nulls(jsonb_build_object(
      'nmCargo', btrim(v_con.cargo), 'CBOCargo', v_ce.cbo_cargo, 'nmFuncao', v_ce.nm_funcao, 'CBOFuncao', v_ce.cbo_funcao,
      'codCateg', v_ce.cod_categ,
      'remuneracao', jsonb_build_object('vrSalFx', folha.esocial_entrada_dec(v_con.salario_base),
                                        'undSalFixo', v_ce.und_sal_fixo, 'dscSalVar', v_ce.dsc_sal_var),
      'duracao', jsonb_build_object('tpContr', v_ce.tp_contr, 'dtTerm', folha.esocial_entrada_data(v_ce.dt_term),
                                    'clauAssec', folha.esocial_entrada_sn(v_ce.clau_assec), 'objDet', v_ce.obj_det),
      'localTrabalho', jsonb_build_object('localTrabGeral', jsonb_build_object(
        'tpInsc', folha.esocial_entrada_tpinsc_estab(v_est.tipo_inscricao), 'nrInsc', v_est.inscricao)),
      'horContratual', jsonb_build_object('qtdHrsSem', v_con.jornada_semanal::text, 'tpJornada', v_ce.tp_jornada,
                                          'tmpParc', v_ce.tmp_parc, 'horNoturno', folha.esocial_entrada_sn(v_ce.hor_noturno),
                                          'dscJorn', v_ce.dsc_jorn)));
    v_vinc := jsonb_build_object('matricula', v_ce.matricula, 'tpRegTrab', 1, 'tpRegPrev', 1,
                                 'cadIni', folha.esocial_entrada_sn(v_ce.cad_ini),
                                 'infoCeletista', v_celetista, 'infoContrato', v_contrato);
  END IF;

  PERFORM folha.esocial_entrada_contexto(p_registrar, p_retificar_event_id IS NOT NULL);
  RETURN folha.esocial_entrada_concluir(
    v_ctx, p_employer_id, 'S-2200', p_ambiente,
    v_ret || jsonb_build_object('trabalhador', v_trab, 'vinculo', v_vinc),
    v_empregador, p_gerado_em, v_acc,
    jsonb_build_object('employee_id', v_con.employee_id, 'contract_id', p_contract_id),
    '[]'::jsonb, p_registrar, p_retificar_event_id, NULL, p_motivo, NULL);
END
$function$;

-- 5.5 S-1298 (reabertura) e S-1299 (fechamento). O S-1298 só nasce de período fechado, com o recibo do S-1299
--     validado guardado na fila (folha.transmit + folha.close ao registrar: parecer 4.6 e 4.9). O S-1299 só
--     nasce com todas as folhas do período fechadas e sem pendência, e com todo S-1200/S-1210 do período já
--     validado (com recibo). As marcações do infoFech vêm da fila, não de quem chama.
CREATE FUNCTION folha.esocial_entrada_s1298_v1(
  p_employer_id uuid, p_ind_apuracao smallint, p_periodo date, p_ambiente text,
  p_gerado_em timestamp DEFAULT NULL, p_registrar boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx jsonb;
  v_conta uuid;
  v_emp folha.employer%ROWTYPE;
  v_acc jsonb := folha.esocial_entrada_acc();
  v_empregador jsonb;
  v_f1299 folha.esocial_event%ROWTYPE;
BEGIN
  v_ctx := folha.esocial_entrada_contexto(p_registrar, p_registrar);
  v_conta := (v_ctx ->> 'account_id')::uuid;
  IF p_ambiente IS NULL OR p_ambiente NOT IN ('producao', 'producao_restrita') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Ambiente deve ser producao ou producao_restrita';
  END IF;
  IF p_ind_apuracao IS NULL OR p_ind_apuracao NOT IN (1, 2) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'indApuracao deve ser 1 (mensal) ou 2 (anual)';
  END IF;
  IF p_periodo IS NULL OR p_periodo <> date_trunc('month', p_periodo)::date OR (p_ind_apuracao = 2 AND extract(month FROM p_periodo) <> 1) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'O período deve ser o primeiro dia do mês (1º de janeiro na folha anual)';
  END IF;
  SELECT * INTO v_emp FROM folha.employer e WHERE e.account_id = v_conta AND e.employer_id = p_employer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = format('Empregador %s não encontrado nesta conta', p_employer_id);
  END IF;
  v_empregador := folha.esocial_entrada_empregador(v_emp);
  IF v_empregador IS NULL THEN
    v_acc := folha.esocial_entrada_falta(v_acc, 'empregador.nrInsc', 'empregador sem CNPJ ou CPF utilizável (tipo caepf não informa o CPF)');
  END IF;

  IF NOT folha.esocial_periodo_fechado(v_conta, p_employer_id, p_ambiente, p_ind_apuracao, p_periodo) THEN
    v_acc := folha.esocial_entrada_bloqueia(v_acc, 'periodo_nao_fechado',
      format('O período %s não está fechado (nenhum S-1299 validado a reabrir)', to_char(p_periodo, 'YYYY-MM')));
  ELSE
    SELECT * INTO v_f1299 FROM folha.esocial_event x
     WHERE x.account_id = v_conta AND x.employer_id = p_employer_id AND x.ambiente = p_ambiente AND x.evento_codigo = 'S-1299'
       AND x.ind_apuracao = p_ind_apuracao AND x.periodo_apuracao = p_periodo AND x.estado = 'validado'
     ORDER BY x.ciclo DESC, x.versao DESC LIMIT 1;
    IF NOT FOUND OR v_f1299.recibo_numero IS NULL OR v_f1299.recibo_numero !~ '^1\.[0-9]\.[0-9]{19}$' THEN
      v_acc := folha.esocial_entrada_bloqueia(v_acc, 'sem_recibo_do_s1299',
        'O S-1299 do período não está guardado na fila como validado com recibo no formato do leiaute');
    END IF;
  END IF;

  PERFORM folha.esocial_entrada_contexto(p_registrar, p_registrar);
  RETURN folha.esocial_entrada_concluir(
    v_ctx, p_employer_id, 'S-1298', p_ambiente,
    jsonb_build_object('indApuracao', p_ind_apuracao,
                       'perApur', CASE WHEN p_ind_apuracao = 1 THEN to_char(p_periodo, 'YYYY-MM') ELSE to_char(p_periodo, 'YYYY') END),
    v_empregador, p_gerado_em, v_acc,
    jsonb_build_object('ind_apuracao', p_ind_apuracao, 'periodo_apuracao', p_periodo),
    '[]'::jsonb, p_registrar, NULL, NULL, NULL, NULL);
END
$function$;

CREATE FUNCTION folha.esocial_entrada_s1299_v1(
  p_employer_id uuid, p_ind_apuracao smallint, p_periodo date, p_ambiente text,
  p_gerado_em timestamp DEFAULT NULL, p_registrar boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx jsonb;
  v_conta uuid;
  v_emp folha.employer%ROWTYPE;
  v_acc jsonb := folha.esocial_entrada_acc();
  v_empregador jsonb;
  v_run record;
  v_ev record;
  v_n integer;
  v_remun boolean := false;
  v_pgtos boolean := false;
BEGIN
  v_ctx := folha.esocial_entrada_contexto(p_registrar, false);
  v_conta := (v_ctx ->> 'account_id')::uuid;
  IF p_ambiente IS NULL OR p_ambiente NOT IN ('producao', 'producao_restrita') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Ambiente deve ser producao ou producao_restrita';
  END IF;
  IF p_ind_apuracao IS NULL OR p_ind_apuracao NOT IN (1, 2) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'indApuracao deve ser 1 (mensal) ou 2 (anual)';
  END IF;
  IF p_periodo IS NULL OR p_periodo <> date_trunc('month', p_periodo)::date OR (p_ind_apuracao = 2 AND extract(month FROM p_periodo) <> 1) THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'O período deve ser o primeiro dia do mês (1º de janeiro na folha anual)';
  END IF;
  SELECT * INTO v_emp FROM folha.employer e WHERE e.account_id = v_conta AND e.employer_id = p_employer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = format('Empregador %s não encontrado nesta conta', p_employer_id);
  END IF;
  v_empregador := folha.esocial_entrada_empregador(v_emp);
  IF v_empregador IS NULL THEN
    v_acc := folha.esocial_entrada_falta(v_acc, 'empregador.nrInsc', 'empregador sem CNPJ ou CPF utilizável (tipo caepf não informa o CPF)');
  END IF;

  FOR v_run IN
    SELECT r.run_id, r.status, r.tipo_processo FROM folha.payroll_run r
     WHERE r.account_id = v_conta AND r.employer_id = p_employer_id AND r.status <> 'cancelled'
       AND ((p_ind_apuracao = 1 AND date_trunc('month', r.competencia)::date = p_periodo)
            OR (p_ind_apuracao = 2 AND date_trunc('year', r.competencia)::date = p_periodo))
  LOOP
    IF v_run.status <> 'closed' THEN
      v_acc := folha.esocial_entrada_bloqueia(v_acc, 'folha_aberta',
        format('A folha %s (%s) do período está %s: o fechamento só nasce com todas as folhas fechadas', v_run.run_id, v_run.tipo_processo, v_run.status));
    ELSE
      SELECT count(*) INTO v_n FROM folha.payroll_pendency d WHERE d.account_id = v_conta AND d.run_id = v_run.run_id AND d.liberada_em IS NULL;
      IF v_n > 0 THEN
        v_acc := folha.esocial_entrada_bloqueia(v_acc, 'pendencia_aberta',
          format('A folha %s tem %s pendência(s) sem liberação: o período não fecha', v_run.run_id, v_n));
      END IF;
    END IF;
  END LOOP;

  -- periódicos do período na fila: a última versão não cancelada de cada chave tem de estar validada (com recibo)
  FOR v_ev IN
    SELECT DISTINCT ON (x.evento_codigo, x.chave_negocio) x.evento_codigo, x.chave_negocio, x.estado, x.event_id
      FROM folha.esocial_event x
     WHERE x.account_id = v_conta AND x.employer_id = p_employer_id AND x.ambiente = p_ambiente
       AND x.evento_codigo IN ('S-1200', 'S-1210') AND x.periodo_apuracao = p_periodo AND COALESCE(x.ind_apuracao, 1) = p_ind_apuracao
       AND x.estado <> 'cancelado'
     ORDER BY x.evento_codigo, x.chave_negocio, x.versao DESC
  LOOP
    IF v_ev.estado IN ('cancelado', 'excluido') THEN
      CONTINUE;
    ELSIF v_ev.estado <> 'validado' THEN
      v_acc := folha.esocial_entrada_bloqueia(v_acc, 'periodico_sem_recibo',
        format('O %s (evento %s) do período está %s: sem recibo, o fechamento não segue', v_ev.evento_codigo, v_ev.event_id, v_ev.estado));
    ELSIF v_ev.evento_codigo = 'S-1200' THEN
      v_remun := true;
    ELSE
      v_pgtos := true;
    END IF;
  END LOOP;

  -- cobertura: todo resultado de folha fechada do período tem S-1200 validado; todo pagamento, S-1210 validado
  FOR v_run IN
    SELECT DISTINCT pr.employee_id FROM folha.payroll_result pr
      JOIN folha.payroll_run r ON r.account_id = pr.account_id AND r.run_id = pr.run_id
     WHERE pr.account_id = v_conta AND r.employer_id = p_employer_id AND r.status = 'closed'
       AND p_ind_apuracao = 1 AND r.competencia = p_periodo AND r.tipo_processo IN ('mensal', 'complementar', 'ferias')
       AND NOT EXISTS (SELECT 1 FROM folha.esocial_event x
                        WHERE x.account_id = v_conta AND x.employer_id = p_employer_id AND x.ambiente = p_ambiente
                          AND x.evento_codigo = 'S-1200' AND x.employee_id = pr.employee_id AND x.ind_apuracao = 1
                          AND x.periodo_apuracao = p_periodo AND x.estado = 'validado')
  LOOP
    v_acc := folha.esocial_entrada_bloqueia(v_acc, 'resultado_sem_s1200',
      format('O trabalhador %s tem remuneração em folha fechada do período sem S-1200 validado', v_run.employee_id));
  END LOOP;
  FOR v_run IN
    SELECT DISTINCT p.employee_id FROM folha.payroll_payment p
     WHERE p.account_id = v_conta AND p.employer_id = p_employer_id AND p_ind_apuracao = 1
       AND date_trunc('month', p.dt_pgto)::date = p_periodo
       AND NOT EXISTS (SELECT 1 FROM folha.esocial_event x
                        WHERE x.account_id = v_conta AND x.employer_id = p_employer_id AND x.ambiente = p_ambiente
                          AND x.evento_codigo = 'S-1210' AND x.employee_id = p.employee_id
                          AND x.periodo_apuracao = p_periodo AND x.estado = 'validado')
  LOOP
    v_acc := folha.esocial_entrada_bloqueia(v_acc, 'pagamento_sem_s1210',
      format('O trabalhador %s tem pagamento no mês sem S-1210 validado', v_run.employee_id));
  END LOOP;
  IF EXISTS (SELECT 1 FROM folha.payroll_run r
              WHERE r.account_id = v_conta AND r.employer_id = p_employer_id AND r.status = 'closed'
                AND r.tipo_processo IN ('rescisao', 'decimo_terceiro_1', 'decimo_terceiro_2')
                AND ((p_ind_apuracao = 1 AND r.competencia = p_periodo)
                     OR (p_ind_apuracao = 2 AND date_trunc('year', r.competencia)::date = p_periodo))) THEN
    v_acc := folha.esocial_entrada_bloqueia(v_acc, 'processo_sem_gerador',
      'Há folha fechada de rescisão ou de 13º no período: o S-2299 e o S-1200 anual ainda não são gerados, e o fechamento não pode declarar o período sem eles');
  END IF;
  v_acc := folha.esocial_entrada_pende(v_acc, 'dados.infoFech.evtComProd', 'S-1260 sem origem de dado na Folha: declarado sem movimento (a validar)');
  v_acc := folha.esocial_entrada_pende(v_acc, 'dados.infoFech.evtContratAvNP', 'S-1270 sem origem de dado na Folha: declarado sem movimento (a validar)');
  v_acc := folha.esocial_entrada_pende(v_acc, 'dados.infoFech.evtInfoComplPer', 'S-1280 sem origem de dado na Folha: declarado sem movimento (a validar)');
  v_acc := folha.esocial_entrada_pende(v_acc, 'dados.infoFech.evtRemun', 'S-2299 do período não é considerado nesta versão (o gerador do S-2299 ainda não é alimentado)');

  PERFORM folha.esocial_entrada_contexto(p_registrar, false);
  RETURN folha.esocial_entrada_concluir(
    v_ctx, p_employer_id, 'S-1299', p_ambiente,
    jsonb_build_object('indApuracao', p_ind_apuracao,
                       'perApur', CASE WHEN p_ind_apuracao = 1 THEN to_char(p_periodo, 'YYYY-MM') ELSE to_char(p_periodo, 'YYYY') END,
                       'infoFech', jsonb_build_object('evtRemun', v_remun, 'evtPgtos', v_pgtos, 'evtComProd', false,
                                                      'evtContratAvNP', false, 'evtInfoComplPer', false)),
    v_empregador, p_gerado_em, v_acc,
    jsonb_build_object('ind_apuracao', p_ind_apuracao, 'periodo_apuracao', p_periodo),
    '[]'::jsonb, p_registrar, NULL, NULL, NULL, NULL);
END
$function$;

-- 5.6 S-3000 (exclusão): recibo do evento original guardado na fila (0031), validado. Mesma operação de
--     esocial_evento_excluir_v1 (mesmo hash de origem, portanto idempotente com ela), mais a entrada do gerador.
--     Só os tipos que o gerador sabe montar: S-1200, S-1210, S-2200 e S-2299.
CREATE FUNCTION folha.esocial_entrada_s3000_v1(
  p_event_id uuid, p_motivo text, p_gerado_em timestamp DEFAULT NULL, p_registrar boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx jsonb;
  v_conta uuid;
  v_o folha.esocial_event%ROWTYPE;
  v_emp folha.employer%ROWTYPE;
  v_ee folha.employee%ROWTYPE;
  v_acc jsonb := folha.esocial_entrada_acc();
  v_empregador jsonb;
  v_dep text;
  v_dados jsonb;
  v_folha jsonb;
BEGIN
  v_ctx := folha.esocial_entrada_contexto(p_registrar, p_registrar);
  v_conta := (v_ctx ->> 'account_id')::uuid;
  SELECT * INTO v_o FROM folha.esocial_event x WHERE x.account_id = v_conta AND x.event_id = p_event_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = 'P0002', MESSAGE = format('Evento %s não encontrado nesta conta', p_event_id);
  END IF;
  SELECT * INTO v_emp FROM folha.employer e WHERE e.account_id = v_conta AND e.employer_id = v_o.employer_id;
  v_empregador := folha.esocial_entrada_empregador(v_emp);
  IF v_empregador IS NULL THEN
    v_acc := folha.esocial_entrada_falta(v_acc, 'empregador.nrInsc', 'empregador sem CNPJ ou CPF utilizável (tipo caepf não informa o CPF)');
  END IF;
  IF btrim(COALESCE(p_motivo, '')) = '' THEN
    v_acc := folha.esocial_entrada_bloqueia(v_acc, 'motivo_obrigatorio', 'A exclusão exige o motivo (aprovação registrada)');
  END IF;
  IF v_o.estado <> 'validado' OR v_o.recibo_numero IS NULL THEN
    v_acc := folha.esocial_entrada_bloqueia(v_acc, 'sem_recibo',
      format('A exclusão exige o evento original validado, com o recibo guardado na fila (estado atual: %s)', v_o.estado));
  ELSIF v_o.recibo_numero !~ '^1\.[0-9]\.[0-9]{19}$' THEN
    v_acc := folha.esocial_entrada_bloqueia(v_acc, 'recibo_fora_do_formato', 'O recibo guardado do evento original não está no formato do leiaute');
  END IF;
  IF v_o.evento_codigo NOT IN ('S-1200', 'S-1210', 'S-2200', 'S-2299') THEN
    v_acc := folha.esocial_entrada_bloqueia(v_acc, 'tipo_nao_excluivel_nesta_versao',
      format('O %s não é montado por esta versão do S-3000 (tabelas se excluem pela operação de exclusão do próprio evento; fechamento, pela reabertura)', v_o.evento_codigo));
  END IF;
  IF v_o.evento_codigo IN ('S-1200', 'S-1210')
     AND folha.esocial_periodo_fechado(v_conta, v_o.employer_id, v_o.ambiente, v_o.ind_apuracao, v_o.periodo_apuracao) THEN
    v_acc := folha.esocial_entrada_bloqueia(v_acc, 'periodo_fechado',
      format('O período %s está fechado: reabra com o S-1298 antes de excluir evento periódico', to_char(v_o.periodo_apuracao, 'YYYY-MM')));
  END IF;
  IF EXISTS (SELECT 1 FROM folha.esocial_event x
              WHERE x.account_id = v_conta AND x.employer_id = v_o.employer_id AND x.ambiente = v_o.ambiente
                AND x.evento_codigo = v_o.evento_codigo AND x.chave_negocio = v_o.chave_negocio
                AND x.estado IN ('rascunho', 'pendente_interno', 'gerado', 'assinado', 'enviado', 'em_processamento', 'falha_comunicacao')) THEN
    v_acc := folha.esocial_entrada_bloqueia(v_acc, 'versao_em_andamento', 'Há versão deste evento em andamento: conclua ou cancele antes de excluir');
  END IF;
  SELECT string_agg(DISTINCT d.evento_codigo, ', ' ORDER BY d.evento_codigo) INTO v_dep FROM folha.esocial_dependentes(p_event_id, true) AS d;
  IF v_dep IS NOT NULL THEN
    v_acc := folha.esocial_entrada_bloqueia(v_acc, 'dependentes_enviados', format('O evento tem dependentes enviados (%s): exclua os dependentes antes', v_dep));
  END IF;
  IF v_o.employee_id IS NULL THEN
    v_acc := folha.esocial_entrada_falta(v_acc, 'dados.trabalhador.cpfTrab', 'evento original sem trabalhador na fila');
  ELSE
    SELECT * INTO v_ee FROM folha.employee e WHERE e.account_id = v_conta AND e.employee_id = v_o.employee_id;
  END IF;

  v_folha := CASE v_o.evento_codigo
    WHEN 'S-1200' THEN jsonb_build_object('folhaPagto', jsonb_build_object('indApuracao', v_o.ind_apuracao,
                         'perApur', CASE WHEN v_o.ind_apuracao = 2 THEN to_char(v_o.periodo_apuracao, 'YYYY') ELSE to_char(v_o.periodo_apuracao, 'YYYY-MM') END))
    WHEN 'S-1210' THEN jsonb_build_object('folhaPagto', jsonb_build_object('perApur', to_char(v_o.periodo_apuracao, 'YYYY-MM')))
    ELSE '{}'::jsonb END;
  v_dados := jsonb_build_object('tpEvento', v_o.evento_codigo, 'nrRecEvt', v_o.recibo_numero,
                                'trabalhador', jsonb_build_object('cpfTrab', v_ee.cpf::text)) || v_folha;

  PERFORM folha.esocial_entrada_contexto(p_registrar, p_registrar);
  RETURN folha.esocial_entrada_concluir(
    v_ctx, v_o.employer_id, 'S-3000', v_o.ambiente, v_dados, v_empregador, p_gerado_em, v_acc,
    '{}'::jsonb, '[]'::jsonb, p_registrar, NULL, v_o.event_id, btrim(p_motivo), NULL,
    encode(sha256(convert_to('S-3000|' || v_o.event_id::text || '|' || COALESCE(v_o.recibo_numero, ''), 'UTF8')), 'hex'));
END
$function$;

-- 5.7 Tabelas do empregador, em INCLUSÃO (alteração e exclusão de tabela ficam pendentes, ADR): S-1000, S-1005,
--     S-1010 e S-1020. A validade é por mês (iniValid/fimValid = AAAA-MM). Se já há versão validada do cadastro, o
--     caso vira alteração e é BLOQUEADO (não se envia inclusão por cima).

-- S-1000: dados do empregador por vigência (employer_esocial). p_vigencia_inicio = 1º dia do mês de início.
CREATE FUNCTION folha.esocial_entrada_s1000_v1(
  p_employer_id uuid, p_vigencia_inicio date, p_ambiente text,
  p_gerado_em timestamp DEFAULT NULL, p_registrar boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx jsonb;
  v_conta uuid;
  v_emp folha.employer%ROWTYPE;
  v_es folha.employer_esocial%ROWTYPE;
  v_acc jsonb := folha.esocial_entrada_acc();
  v_empregador jsonb;
  v_class text;
  v_info jsonb;
BEGIN
  v_ctx := folha.esocial_entrada_contexto(p_registrar, false);
  v_conta := (v_ctx ->> 'account_id')::uuid;
  IF p_ambiente IS NULL OR p_ambiente NOT IN ('producao', 'producao_restrita') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Ambiente deve ser producao ou producao_restrita';
  END IF;
  IF p_vigencia_inicio IS NULL OR p_vigencia_inicio <> date_trunc('month', p_vigencia_inicio)::date THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'O início de validade deve ser o primeiro dia do mês';
  END IF;
  SELECT * INTO v_emp FROM folha.employer e WHERE e.account_id = v_conta AND e.employer_id = p_employer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = format('Empregador %s não encontrado nesta conta', p_employer_id);
  END IF;
  v_empregador := folha.esocial_entrada_empregador(v_emp);
  IF v_empregador IS NULL THEN
    v_acc := folha.esocial_entrada_falta(v_acc, 'empregador.nrInsc', 'empregador sem CNPJ ou CPF utilizável (tipo caepf não informa o CPF)');
  END IF;
  SELECT * INTO v_es FROM folha.employer_esocial x
   WHERE x.account_id = v_conta AND x.employer_id = p_employer_id AND x.vigencia_inicio = p_vigencia_inicio;
  IF NOT FOUND THEN
    v_acc := folha.esocial_entrada_falta(v_acc, 'dados.operacao.infoCadastro', 'empregador sem dados do eSocial nesta vigência (employer_esocial)');
  ELSE
    IF v_emp.tipo_inscricao = 'cnpj' AND (v_es.ind_coop IS NULL OR v_es.ind_constr IS NULL) THEN
      v_acc := folha.esocial_entrada_falta(v_acc, 'dados.operacao.infoCadastro.indCoop',
        'indCoop e indConstr são obrigatórios para pessoa jurídica (regra do gerador)');
    END IF;
    v_class := COALESCE(v_es.class_trib, v_emp.classificacao_tributaria);
    IF v_class IS NULL OR v_class !~ '^[0-9]{2}$' THEN
      v_acc := folha.esocial_entrada_falta(v_acc, 'dados.operacao.infoCadastro.classTrib', 'classificação tributária (Tabela 08) ausente ou fora de dois dígitos');
    ELSE
      v_acc := folha.esocial_entrada_dominio(v_acc, 'dados.operacao.infoCadastro.classTrib', 'classTrib', v_class, '08');
    END IF;
  END IF;
  IF EXISTS (SELECT 1 FROM folha.esocial_event x
              WHERE x.account_id = v_conta AND x.employer_id = p_employer_id AND x.evento_codigo = 'S-1000'
                AND x.ambiente = p_ambiente AND x.estado = 'validado') THEN
    v_acc := folha.esocial_entrada_bloqueia(v_acc, 'alteracao_nao_suportada',
      'Já existe S-1000 validado do empregador: o novo período é alteração, que esta versão não monta');
  END IF;

  IF jsonb_array_length(v_acc -> 'faltando') = 0 THEN
    v_info := jsonb_strip_nulls(jsonb_build_object(
      'classTrib', v_class, 'indCoop', v_es.ind_coop, 'indConstr', v_es.ind_constr, 'indDesFolha', v_es.ind_des_folha,
      'indOpcCP', v_es.ind_opc_cp, 'indPorte', CASE WHEN v_es.ind_porte THEN 'S' END,
      'indOptRegEletron', v_es.ind_opt_reg_eletron, 'cnpjEFR', v_es.cnpj_efr,
      'dtTrans11096', folha.esocial_entrada_data(v_es.dt_trans_11096),
      'indTribFolhaPisPasep', CASE WHEN v_es.ind_trib_folha_pis_pasep THEN 'S' END,
      'indPertIRRF', CASE WHEN v_es.ind_pert_irrf THEN 'S' END,
      'dadosIsencao', v_es.dados_isencao, 'infoOrgInternacional', v_es.info_org_internacional));
  END IF;

  PERFORM folha.esocial_entrada_contexto(p_registrar, false);
  RETURN folha.esocial_entrada_concluir(
    v_ctx, p_employer_id, 'S-1000', p_ambiente,
    jsonb_build_object('operacao', jsonb_build_object('tipo', 'inclusao',
      'idePeriodo', jsonb_strip_nulls(jsonb_build_object('iniValid', to_char(v_es.vigencia_inicio, 'YYYY-MM'),
                                                         'fimValid', to_char(v_es.vigencia_fim, 'YYYY-MM'))),
      'infoCadastro', v_info)),
    v_empregador, p_gerado_em, v_acc,
    jsonb_build_object('inicio_validade', p_vigencia_inicio), '[]'::jsonb, p_registrar, NULL, NULL, NULL, NULL);
END
$function$;

-- S-1005: estabelecimento por vigência (establishment_esocial); CNAE do establishment e FAP de establishment_fap.
CREATE FUNCTION folha.esocial_entrada_s1005_v1(
  p_establishment_id uuid, p_vigencia_inicio date, p_ambiente text,
  p_gerado_em timestamp DEFAULT NULL, p_registrar boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx jsonb;
  v_conta uuid;
  v_est folha.establishment%ROWTYPE;
  v_emp folha.employer%ROWTYPE;
  v_es folha.establishment_esocial%ROWTYPE;
  v_fap folha.establishment_fap%ROWTYPE;
  v_acc jsonb := folha.esocial_entrada_acc();
  v_empregador jsonb;
  v_ide jsonb;
  v_dados jsonb;
  v_gilrat jsonb;
BEGIN
  v_ctx := folha.esocial_entrada_contexto(p_registrar, false);
  v_conta := (v_ctx ->> 'account_id')::uuid;
  IF p_ambiente IS NULL OR p_ambiente NOT IN ('producao', 'producao_restrita') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Ambiente deve ser producao ou producao_restrita';
  END IF;
  IF p_vigencia_inicio IS NULL OR p_vigencia_inicio <> date_trunc('month', p_vigencia_inicio)::date THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'O início de validade deve ser o primeiro dia do mês';
  END IF;
  SELECT * INTO v_est FROM folha.establishment s WHERE s.account_id = v_conta AND s.establishment_id = p_establishment_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = format('Estabelecimento %s não encontrado nesta conta', p_establishment_id);
  END IF;
  SELECT * INTO v_emp FROM folha.employer e WHERE e.account_id = v_conta AND e.employer_id = v_est.employer_id;
  v_empregador := folha.esocial_entrada_empregador(v_emp);
  IF v_empregador IS NULL THEN
    v_acc := folha.esocial_entrada_falta(v_acc, 'empregador.nrInsc', 'empregador sem CNPJ ou CPF utilizável (tipo caepf não informa o CPF)');
  END IF;
  IF v_est.inscricao !~ '^([0-9]{12}|[A-Z0-9]{12}[0-9]{2})$' THEN
    v_acc := folha.esocial_entrada_falta(v_acc, 'dados.operacao.ideEstab.nrInsc', 'inscrição do estabelecimento fora do formato do leiaute');
  END IF;
  IF v_est.cnae_preponderante !~ '^[0-9]{7}$' THEN
    v_acc := folha.esocial_entrada_falta(v_acc, 'dados.operacao.dadosEstab.cnaePrep', 'CNAE preponderante fora de sete dígitos');
  END IF;
  SELECT * INTO v_es FROM folha.establishment_esocial x
   WHERE x.account_id = v_conta AND x.establishment_id = p_establishment_id AND x.vigencia_inicio = p_vigencia_inicio;
  IF NOT FOUND THEN
    v_acc := folha.esocial_entrada_falta(v_acc, 'dados.operacao.dadosEstab', 'estabelecimento sem dados do eSocial nesta vigência (establishment_esocial)');
  END IF;
  SELECT * INTO v_fap FROM folha.establishment_fap f
   WHERE f.account_id = v_conta AND f.establishment_id = p_establishment_id
     AND f.vigencia_inicio <= p_vigencia_inicio AND (f.vigencia_fim IS NULL OR f.vigencia_fim >= p_vigencia_inicio);
  IF EXISTS (SELECT 1 FROM folha.esocial_event x
              WHERE x.account_id = v_conta AND x.employer_id = v_est.employer_id AND x.evento_codigo = 'S-1005'
                AND x.ambiente = p_ambiente AND x.codigo_tabela = v_est.inscricao AND x.estado = 'validado') THEN
    v_acc := folha.esocial_entrada_bloqueia(v_acc, 'alteracao_nao_suportada',
      'Já existe S-1005 validado deste estabelecimento: o novo período é alteração, que esta versão não monta');
  END IF;

  IF jsonb_array_length(v_acc -> 'faltando') = 0 THEN
    v_gilrat := jsonb_strip_nulls(jsonb_build_object(
      'aliqRat', CASE WHEN v_es.proc_adm_jud_rat IS NOT NULL THEN v_es.aliq_rat END, 'fap', CASE WHEN v_fap.fap IS NOT NULL THEN to_char(v_fap.fap, 'FM0.0000') END,
      'procAdmJudRat', v_es.proc_adm_jud_rat, 'procAdmJudFap', v_es.proc_adm_jud_fap));
    v_dados := jsonb_strip_nulls(jsonb_build_object(
      'cnaePrep', v_est.cnae_preponderante, 'cnpjResp', v_es.cnpj_resp,
      'aliqGilrat', CASE WHEN v_gilrat <> '{}'::jsonb THEN v_gilrat END,
      'infoCaepf', CASE WHEN v_es.tp_caepf IS NOT NULL THEN jsonb_build_object('tpCaepf', v_es.tp_caepf) END,
      'infoObra', CASE WHEN v_es.ind_subst_patr_obra IS NOT NULL THEN jsonb_build_object('indSubstPatrObra', v_es.ind_subst_patr_obra) END,
      'infoTrab', v_es.info_trab));
    v_ide := jsonb_strip_nulls(jsonb_build_object(
      'tpInsc', folha.esocial_entrada_tpinsc_estab(v_est.tipo_inscricao), 'nrInsc', v_est.inscricao,
      'iniValid', to_char(v_es.vigencia_inicio, 'YYYY-MM'), 'fimValid', to_char(v_es.vigencia_fim, 'YYYY-MM')));
  END IF;

  PERFORM folha.esocial_entrada_contexto(p_registrar, false);
  RETURN folha.esocial_entrada_concluir(
    v_ctx, v_est.employer_id, 'S-1005', p_ambiente,
    jsonb_build_object('operacao', jsonb_build_object('tipo', 'inclusao', 'ideEstab', v_ide, 'dadosEstab', v_dados)),
    v_empregador, p_gerado_em, v_acc,
    jsonb_build_object('establishment_id', p_establishment_id, 'codigo_tabela', v_est.inscricao, 'inicio_validade', p_vigencia_inicio),
    '[]'::jsonb, p_registrar, NULL, NULL, NULL, NULL);
END
$function$;

-- S-1010: rubrica por empregador. codRubr/ideTabRubr/validade de rubric_esocial_config; natureza de
-- rubric_esocial_nature; incidências de rubric_incidence + incidence_code.codigo_esocial (Tabela 21: sem código
-- carregado, falta; a tabela não é inventada).
CREATE FUNCTION folha.esocial_entrada_s1010_v1(
  p_employer_id uuid, p_code_id uuid, p_vigencia_inicio date, p_ambiente text,
  p_gerado_em timestamp DEFAULT NULL, p_registrar boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx jsonb;
  v_conta uuid;
  v_emp folha.employer%ROWTYPE;
  v_rub folha.earning_deduction_code%ROWTYPE;
  v_cfg folha.rubric_esocial_config%ROWTYPE;
  v_acc jsonb := folha.esocial_entrada_acc();
  v_empregador jsonb;
  v_nat text;
  v_tp smallint;
  v_inc record;
  v_cp text; v_irrf text; v_fgts text;
  v_dados jsonb;
  v_ide jsonb;
BEGIN
  v_ctx := folha.esocial_entrada_contexto(p_registrar, false);
  v_conta := (v_ctx ->> 'account_id')::uuid;
  IF p_ambiente IS NULL OR p_ambiente NOT IN ('producao', 'producao_restrita') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Ambiente deve ser producao ou producao_restrita';
  END IF;
  IF p_vigencia_inicio IS NULL OR p_vigencia_inicio <> date_trunc('month', p_vigencia_inicio)::date THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'O início de validade deve ser o primeiro dia do mês';
  END IF;
  SELECT * INTO v_emp FROM folha.employer e WHERE e.account_id = v_conta AND e.employer_id = p_employer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = format('Empregador %s não encontrado nesta conta', p_employer_id);
  END IF;
  SELECT * INTO v_rub FROM folha.earning_deduction_code r
   WHERE r.code_id = p_code_id AND (r.account_id IS NULL OR r.account_id = v_conta);
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = format('Rubrica %s não encontrada nesta conta', p_code_id);
  END IF;
  v_empregador := folha.esocial_entrada_empregador(v_emp);
  IF v_empregador IS NULL THEN
    v_acc := folha.esocial_entrada_falta(v_acc, 'empregador.nrInsc', 'empregador sem CNPJ ou CPF utilizável (tipo caepf não informa o CPF)');
  END IF;
  SELECT * INTO v_cfg FROM folha.rubric_esocial_config c
   WHERE c.account_id = v_conta AND c.employer_id = p_employer_id AND c.code_id = p_code_id AND c.vigencia_inicio = p_vigencia_inicio;
  IF NOT FOUND THEN
    v_acc := folha.esocial_entrada_falta(v_acc, 'dados.operacao.ideRubrica', 'rubrica sem cadastro no S-1010 nesta vigência (rubric_esocial_config)');
  END IF;

  v_tp := CASE v_rub.tipo_rubrica WHEN 'provento' THEN 1 WHEN 'desconto' THEN 2 WHEN 'informativa' THEN 3 END;
  IF v_tp IS NULL THEN
    v_acc := folha.esocial_entrada_bloqueia(v_acc, 'rubrica_de_base', format('A rubrica %s é de base de cálculo: não é rubrica do eSocial', v_rub.codigo));
  END IF;
  IF char_length(v_rub.descricao) NOT BETWEEN 1 AND 100 THEN
    v_acc := folha.esocial_entrada_falta(v_acc, 'dados.operacao.dadosRubrica.dscRubr', 'descrição da rubrica fora de 1 a 100 posições');
  END IF;

  SELECT n.natureza_codigo INTO v_nat FROM folha.rubric_esocial_nature n
   WHERE n.code_id = p_code_id AND (n.account_id IS NULL OR n.account_id = v_conta) AND n.vigencia_inicio <= p_vigencia_inicio AND (n.vigencia_fim IS NULL OR n.vigencia_fim >= p_vigencia_inicio);
  IF v_nat IS NULL OR v_nat !~ '^[0-9]{4}$' THEN
    v_acc := folha.esocial_entrada_falta(v_acc, 'dados.operacao.dadosRubrica.natRubr', 'natureza da rubrica (Tabela 03) não cadastrada para a vigência');
  ELSE
    v_acc := folha.esocial_entrada_dominio(v_acc, 'dados.operacao.dadosRubrica.natRubr', 'natRubr', v_nat, '03');
  END IF;

  FOR v_inc IN
    SELECT ri.tributo, ic.codigo_esocial FROM folha.rubric_incidence ri
      JOIN folha.incidence_code ic ON ic.tributo = ri.tributo AND ic.codigo = ri.incidencia_codigo
     WHERE ri.code_id = p_code_id AND (ri.account_id IS NULL OR ri.account_id = v_conta)
       AND ri.vigencia_inicio <= p_vigencia_inicio AND (ri.vigencia_fim IS NULL OR ri.vigencia_fim >= p_vigencia_inicio)
  LOOP
    IF v_inc.tributo = 'previdencia' THEN v_cp := v_inc.codigo_esocial;
    ELSIF v_inc.tributo = 'irrf' THEN v_irrf := v_inc.codigo_esocial;
    ELSIF v_inc.tributo = 'fgts' THEN v_fgts := v_inc.codigo_esocial;
    END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM folha.rubric_incidence ri JOIN folha.incidence_code ic ON ic.tributo = ri.tributo AND ic.codigo = ri.incidencia_codigo
              WHERE ri.code_id = p_code_id AND (ri.account_id IS NULL OR ri.account_id = v_conta)
                AND ri.vigencia_inicio <= p_vigencia_inicio AND (ri.vigencia_fim IS NULL OR ri.vigencia_fim >= p_vigencia_inicio)
                AND (ri.status_validacao = 'a_validar' OR ic.esocial_status = 'a_validar')) THEN
    v_acc := folha.esocial_entrada_pende(v_acc, 'dados.operacao.dadosRubrica.incidencias',
      'incidência da rubrica ou código do eSocial ainda a_validar na fonte (rubric_incidence / incidence_code)');
  END IF;
  v_acc := folha.esocial_entrada_exige(v_acc, 'dados.operacao.dadosRubrica.codIncCP', v_cp, 'incidência para a Previdência sem código do eSocial (incidence_code.codigo_esocial)');
  v_acc := folha.esocial_entrada_dominio(v_acc, 'dados.operacao.dadosRubrica.codIncCP', 'codIncCP', v_cp, 'XSD');
  v_acc := folha.esocial_entrada_exige(v_acc, 'dados.operacao.dadosRubrica.codIncIRRF', v_irrf, 'incidência para o IRRF sem código do eSocial (Tabela 21 não carregada)');
  v_acc := folha.esocial_entrada_dominio(v_acc, 'dados.operacao.dadosRubrica.codIncIRRF', 'codIncIRRF', v_irrf, '21');
  v_acc := folha.esocial_entrada_exige(v_acc, 'dados.operacao.dadosRubrica.codIncFGTS', v_fgts, 'incidência para o FGTS sem código do eSocial (incidence_code.codigo_esocial)');
  v_acc := folha.esocial_entrada_dominio(v_acc, 'dados.operacao.dadosRubrica.codIncFGTS', 'codIncFGTS', v_fgts, 'XSD');
  IF v_irrf IS NOT NULL AND v_irrf !~ '^[0-9]{1,4}$' THEN
    v_acc := folha.esocial_entrada_falta(v_acc, 'dados.operacao.dadosRubrica.codIncIRRF', 'código de incidência do IRRF fora de um a quatro dígitos');
  END IF;
  v_acc := folha.esocial_entrada_dominio(v_acc, 'dados.operacao.dadosRubrica.tpRubr', 'tpRubr', v_tp::text, 'XSD');
  IF EXISTS (SELECT 1 FROM folha.esocial_event x
              WHERE x.account_id = v_conta AND x.employer_id = p_employer_id AND x.evento_codigo = 'S-1010'
                AND x.ambiente = p_ambiente AND x.codigo_tabela = v_cfg.cod_rubr || '/' || v_cfg.ide_tab_rubr AND x.estado = 'validado') THEN
    v_acc := folha.esocial_entrada_bloqueia(v_acc, 'alteracao_nao_suportada',
      'Já existe S-1010 validado desta rubrica: o novo período é alteração, que esta versão não monta');
  END IF;

  IF jsonb_array_length(v_acc -> 'faltando') = 0 AND jsonb_array_length(v_acc -> 'bloqueios') = 0 THEN
    v_ide := jsonb_strip_nulls(jsonb_build_object('codRubr', v_cfg.cod_rubr, 'ideTabRubr', v_cfg.ide_tab_rubr,
                                                  'iniValid', to_char(v_cfg.vigencia_inicio, 'YYYY-MM'),
                                                  'fimValid', to_char(v_cfg.vigencia_fim, 'YYYY-MM')));
    v_dados := jsonb_strip_nulls(jsonb_build_object(
      'dscRubr', btrim(v_rub.descricao), 'natRubr', v_nat, 'tpRubr', v_tp, 'codIncCP', v_cp, 'codIncIRRF', v_irrf,
      'codIncFGTS', v_fgts, 'tetoRemun', folha.esocial_entrada_sn(v_cfg.teto_remun), 'observacao', v_cfg.observacao));
  END IF;

  PERFORM folha.esocial_entrada_contexto(p_registrar, false);
  RETURN folha.esocial_entrada_concluir(
    v_ctx, p_employer_id, 'S-1010', p_ambiente,
    jsonb_build_object('operacao', jsonb_build_object('tipo', 'inclusao', 'ideRubrica', v_ide, 'dadosRubrica', v_dados)),
    v_empregador, p_gerado_em, v_acc,
    jsonb_build_object('codigo_tabela', v_cfg.cod_rubr || '/' || v_cfg.ide_tab_rubr, 'inicio_validade', p_vigencia_inicio),
    '[]'::jsonb, p_registrar, NULL, NULL, NULL, NULL);
END
$function$;

-- S-1020: lotação tributária. A validade do S-1020 é a da linha de enquadramento (tax_allocation_detail):
-- precisa começar no dia 1 e terminar no último dia de um mês; senão falta (o eSocial valida por mês).
CREATE FUNCTION folha.esocial_entrada_s1020_v1(
  p_allocation_id uuid, p_vigencia_inicio date, p_ambiente text,
  p_gerado_em timestamp DEFAULT NULL, p_registrar boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx jsonb;
  v_conta uuid;
  v_lot folha.tax_allocation%ROWTYPE;
  v_det folha.tax_allocation_detail%ROWTYPE;
  v_emp folha.employer%ROWTYPE;
  v_acc jsonb := folha.esocial_entrada_acc();
  v_empregador jsonb;
  v_dados jsonb;
  v_ide jsonb;
  v_fpas jsonb;
BEGIN
  v_ctx := folha.esocial_entrada_contexto(p_registrar, false);
  v_conta := (v_ctx ->> 'account_id')::uuid;
  IF p_ambiente IS NULL OR p_ambiente NOT IN ('producao', 'producao_restrita') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'Ambiente deve ser producao ou producao_restrita';
  END IF;
  SELECT * INTO v_lot FROM folha.tax_allocation a WHERE a.account_id = v_conta AND a.allocation_id = p_allocation_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = format('Lotação %s não encontrada nesta conta', p_allocation_id);
  END IF;
  SELECT * INTO v_emp FROM folha.employer e WHERE e.account_id = v_conta AND e.employer_id = v_lot.employer_id;
  v_empregador := folha.esocial_entrada_empregador(v_emp);
  IF v_empregador IS NULL THEN
    v_acc := folha.esocial_entrada_falta(v_acc, 'empregador.nrInsc', 'empregador sem CNPJ ou CPF utilizável (tipo caepf não informa o CPF)');
  END IF;
  SELECT * INTO v_det FROM folha.tax_allocation_detail d
   WHERE d.account_id = v_conta AND d.allocation_id = p_allocation_id AND d.vigencia_inicio = p_vigencia_inicio;
  IF NOT FOUND THEN
    v_acc := folha.esocial_entrada_falta(v_acc, 'dados.operacao.dadosLotacao.fpasLotacao', 'lotação sem enquadramento nesta vigência (tax_allocation_detail)');
  ELSE
    IF EXTRACT(DAY FROM v_det.vigencia_inicio) <> 1 THEN
      v_acc := folha.esocial_entrada_falta(v_acc, 'dados.operacao.ideLotacao.iniValid', 'a vigência do enquadramento não começa no dia 1 (o eSocial valida por mês)');
    END IF;
    IF v_det.vigencia_fim IS NOT NULL AND v_det.vigencia_fim <> (date_trunc('month', v_det.vigencia_fim) + interval '1 month')::date - 1 THEN
      v_acc := folha.esocial_entrada_falta(v_acc, 'dados.operacao.ideLotacao.fimValid', 'a vigência do enquadramento não termina no último dia do mês');
    END IF;
    IF v_det.fpas IS NULL OR v_det.fpas !~ '^[0-9]{3}$' THEN
      v_acc := folha.esocial_entrada_falta(v_acc, 'dados.operacao.dadosLotacao.fpasLotacao.fpas', 'FPAS ausente ou fora de três dígitos');
    END IF;
    IF v_det.codigo_terceiros IS NULL OR v_det.codigo_terceiros !~ '^[0-9]{4}$' THEN
      v_acc := folha.esocial_entrada_falta(v_acc, 'dados.operacao.dadosLotacao.fpasLotacao.codTercs', 'código de Terceiros (Tabela 04) ausente ou fora de quatro dígitos');
    END IF;
  END IF;
  IF v_lot.tipo_lotacao IS NULL OR v_lot.tipo_lotacao !~ '^[0-9]{2}$' THEN
    v_acc := folha.esocial_entrada_falta(v_acc, 'dados.operacao.dadosLotacao.tpLotacao', 'tipo de lotação (Tabela 10) ausente ou fora de dois dígitos');
  ELSE
    v_acc := folha.esocial_entrada_dominio(v_acc, 'dados.operacao.dadosLotacao.tpLotacao', 'tpLotacao', v_lot.tipo_lotacao, '10');
  END IF;
  IF EXISTS (SELECT 1 FROM folha.esocial_event x
              WHERE x.account_id = v_conta AND x.employer_id = v_lot.employer_id AND x.evento_codigo = 'S-1020'
                AND x.ambiente = p_ambiente AND x.codigo_tabela = v_lot.codigo_lotacao AND x.estado = 'validado') THEN
    v_acc := folha.esocial_entrada_bloqueia(v_acc, 'alteracao_nao_suportada',
      'Já existe S-1020 validado desta lotação: o novo período é alteração, que esta versão não monta');
  END IF;

  IF jsonb_array_length(v_acc -> 'faltando') = 0 THEN
    v_fpas := jsonb_strip_nulls(jsonb_build_object(
      'fpas', v_det.fpas, 'codTercs', v_det.codigo_terceiros, 'codTercsSusp', v_det.cod_terceiros_suspensos,
      'infoProcJudTerceiros', v_det.info_proc_jud_terceiros));
    v_dados := jsonb_strip_nulls(jsonb_build_object(
      'tpLotacao', v_lot.tipo_lotacao, 'tpInsc', v_lot.esocial_tp_insc, 'nrInsc', v_lot.esocial_nr_insc,
      'fpasLotacao', v_fpas, 'infoEmprParcial', v_lot.info_empr_parcial, 'dadosOpPort', v_lot.dados_op_port));
    v_ide := jsonb_strip_nulls(jsonb_build_object('codLotacao', v_lot.codigo_lotacao,
                                                  'iniValid', to_char(v_det.vigencia_inicio, 'YYYY-MM'),
                                                  'fimValid', to_char(v_det.vigencia_fim, 'YYYY-MM')));
  END IF;

  PERFORM folha.esocial_entrada_contexto(p_registrar, false);
  RETURN folha.esocial_entrada_concluir(
    v_ctx, v_lot.employer_id, 'S-1020', p_ambiente,
    jsonb_build_object('operacao', jsonb_build_object('tipo', 'inclusao', 'ideLotacao', v_ide, 'dadosLotacao', v_dados)),
    v_empregador, p_gerado_em, v_acc,
    jsonb_build_object('codigo_tabela', v_lot.codigo_lotacao, 'inicio_validade', p_vigencia_inicio),
    '[]'::jsonb, p_registrar, NULL, NULL, NULL, NULL);
END
$function$;

-- ===========================================================================
-- 6. RLS (ENABLE + FORCE) e ACL das tabelas
--    cadastro: policy por conta, worker lê e grava (sem DELETE), data_owner lê (padrão da 0024);
--    fato (demonstrativo, pagamento, registro da entrada): só leitura por conta; a gravação é pelas funções;
--    catálogo: leitura para os dois papéis.
--    Antes de conceder, tira TUDO de TODO papel que não seja o dono (default ACL do schema inclusive).
-- ===========================================================================
DO $$
DECLARE
  v_item text[];
  v_tabela text;
  v_papel text;
BEGIN
  FOREACH v_item SLICE 1 IN ARRAY ARRAY[
    ['employer_esocial',       'cadastro'],
    ['establishment_esocial',  'cadastro'],
    ['rubric_esocial_config',  'cadastro'],
    ['employee_esocial',       'cadastro'],
    ['employee_dependent',     'cadastro'],
    ['contract_esocial',       'cadastro'],
    ['contract_termination',   'cadastro'],
    ['payroll_demonstrative',  'fato'],
    ['payroll_payment',        'fato'],
    ['esocial_entrada',        'fato'],
    ['esocial_domain_code',    'catalogo']
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
    IF v_item[2] = 'cadastro' THEN
      EXECUTE format(
        'CREATE POLICY %I ON folha.%I
           USING (account_id = (SELECT folha.current_account_id()))
           WITH CHECK (account_id = (SELECT folha.current_account_id()))',
        v_tabela || '_isolamento', v_tabela);
      EXECUTE format('GRANT SELECT, INSERT, UPDATE ON folha.%I TO dnex_gestao_folha_worker', v_tabela);
      EXECUTE format('GRANT SELECT ON folha.%I TO dnex_gestao_data_owner', v_tabela);
    ELSIF v_item[2] = 'fato' THEN
      EXECUTE format(
        'CREATE POLICY %I ON folha.%I FOR SELECT TO dnex_gestao_folha_worker, dnex_gestao_data_owner
           USING (account_id = (SELECT folha.current_account_id()))',
        v_tabela || '_isolamento', v_tabela);
      EXECUTE format('GRANT SELECT ON folha.%I TO dnex_gestao_folha_worker, dnex_gestao_data_owner', v_tabela);
    ELSE
      EXECUTE format(
        'CREATE POLICY %I ON folha.%I FOR SELECT TO dnex_gestao_folha_worker, dnex_gestao_data_owner USING (true)',
        v_tabela || '_leitura', v_tabela);
      EXECUTE format('GRANT SELECT ON folha.%I TO dnex_gestao_folha_worker, dnex_gestao_data_owner', v_tabela);
    END IF;
  END LOOP;
END
$$;

-- As colunas novas de tax_allocation e tax_allocation_detail herdam a ACL e a RLS das tabelas (0024).

-- ===========================================================================
-- 7. ACL das funções: tira o EXECUTE de todo papel que não seja o dono e concede só o pretendido.
--    As internas e as de gatilho não são concedidas a ninguém.
-- ===========================================================================
DO $$
DECLARE
  v_item text[];
  v_papel text;
BEGIN
  FOREACH v_item SLICE 1 IN ARRAY ARRAY[
    ['folha.esocial_dominio_situacao(text, text)',                                   ''],
    ['folha.esocial_dominio_guarda()',                                               ''],
    ['folha.esocial_entrada_acc()',                                                  ''],
    ['folha.esocial_entrada_falta(jsonb, text, text)',                               ''],
    ['folha.esocial_entrada_exige(jsonb, text, text, text)',                         ''],
    ['folha.esocial_entrada_bloqueia(jsonb, text, text)',                            ''],
    ['folha.esocial_entrada_pende(jsonb, text, text)',                               ''],
    ['folha.esocial_entrada_dominio(jsonb, text, text, text, text)',                 ''],
    ['folha.esocial_entrada_dec(numeric)',                                           ''],
    ['folha.esocial_entrada_data(date)',                                             ''],
    ['folha.esocial_entrada_sn(boolean)',                                            ''],
    ['folha.esocial_entrada_empregador(folha.employer)',                             ''],
    ['folha.esocial_entrada_tpinsc_estab(text)',                                     ''],
    ['folha.esocial_entrada_contexto(boolean, boolean)',                             ''],
    ['folha.esocial_entrada_concluir(jsonb, uuid, text, text, jsonb, jsonb, timestamp, jsonb, jsonb, jsonb, boolean, uuid, uuid, text, jsonb, text)', ''],
    ['folha.esocial_entrada_pagamento_registrar_v1(uuid, date, numeric, smallint)',  'dnex_gestao_api'],
    ['folha.esocial_entrada_s1000_v1(uuid, date, text, timestamp, boolean)',         'dnex_gestao_api'],
    ['folha.esocial_entrada_s1005_v1(uuid, date, text, timestamp, boolean)',         'dnex_gestao_api'],
    ['folha.esocial_entrada_s1010_v1(uuid, uuid, date, text, timestamp, boolean)',   'dnex_gestao_api'],
    ['folha.esocial_entrada_s1020_v1(uuid, date, text, timestamp, boolean)',         'dnex_gestao_api'],
    ['folha.esocial_entrada_s1200_v1(uuid, uuid, smallint, date, text, timestamp, boolean, uuid, text)', 'dnex_gestao_api'],
    ['folha.esocial_entrada_s1210_v1(uuid, uuid, date, text, timestamp, boolean, uuid, text)',           'dnex_gestao_api'],
    ['folha.esocial_entrada_s2200_v1(uuid, uuid, text, timestamp, boolean, uuid, text)',                 'dnex_gestao_api'],
    ['folha.esocial_entrada_s1298_v1(uuid, smallint, date, text, timestamp, boolean)',                   'dnex_gestao_api'],
    ['folha.esocial_entrada_s1299_v1(uuid, smallint, date, text, timestamp, boolean)',                   'dnex_gestao_api'],
    ['folha.esocial_entrada_s3000_v1(uuid, text, timestamp, boolean)',                                   'dnex_gestao_api']
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
-- 8. Pós-voo (falha fechada)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_inesperado text;
BEGIN
  -- O que a sessão de aplicação executa de entrada do eSocial é exatamente a lista desta migration.
  SELECT string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text) INTO v_inesperado
    FROM pg_catalog.pg_proc p
   WHERE p.pronamespace = 'folha'::regnamespace
     AND p.proname LIKE 'esocial\_entrada\_%'
     AND has_function_privilege('dnex_gestao_api', p.oid, 'EXECUTE')
     AND p.oid::regprocedure::text NOT IN (
       'folha.esocial_entrada_pagamento_registrar_v1(uuid,date,numeric,smallint)',
       'folha.esocial_entrada_s1000_v1(uuid,date,text,timestamp without time zone,boolean)',
       'folha.esocial_entrada_s1005_v1(uuid,date,text,timestamp without time zone,boolean)',
       'folha.esocial_entrada_s1010_v1(uuid,uuid,date,text,timestamp without time zone,boolean)',
       'folha.esocial_entrada_s1020_v1(uuid,date,text,timestamp without time zone,boolean)',
       'folha.esocial_entrada_s1200_v1(uuid,uuid,smallint,date,text,timestamp without time zone,boolean,uuid,text)',
       'folha.esocial_entrada_s1210_v1(uuid,uuid,date,text,timestamp without time zone,boolean,uuid,text)',
       'folha.esocial_entrada_s2200_v1(uuid,uuid,text,timestamp without time zone,boolean,uuid,text)',
       'folha.esocial_entrada_s1298_v1(uuid,smallint,date,text,timestamp without time zone,boolean)',
       'folha.esocial_entrada_s1299_v1(uuid,smallint,date,text,timestamp without time zone,boolean)',
       'folha.esocial_entrada_s3000_v1(uuid,text,timestamp without time zone,boolean)');
  IF v_inesperado IS NOT NULL THEN
    RAISE EXCEPTION '0032: a sessão de aplicação executaria função fora da lista: %', v_inesperado;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_proc p
              WHERE p.pronamespace = 'folha'::regnamespace
                AND (p.proname LIKE 'esocial\_entrada\_%' OR p.proname LIKE 'esocial\_dominio\_%')
                AND has_function_privilege('anon', p.oid, 'EXECUTE')) THEN
    RAISE EXCEPTION '0032: função de entrada executável por anon';
  END IF;
END
$$;

COMMIT;
