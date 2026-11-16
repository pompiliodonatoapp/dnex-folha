-- DNEX Folha — Migration 0029: banco do Portal do Colaborador v1 (documentos publicados).
--
-- Especificação: "Portal do Colaborador v1 — forma exata que o contrato precisa do banco"
-- (frente Portal, 15/11/2026). Nomes finais, assinaturas e divergências registradas em
-- docs/CONTRATO-PORTAL.md. Depende da migration 0028 (contexto da Folha).
--
-- O que cria:
--   1. folha.portal_employee_access      habilitação do empregado (usuário x trabalhador x empregador)
--      folha.published_document          documento publicado (só publicado -> retirado)
--      folha.published_document_access   registro de abertura e download (só INSERT)
--      folha.portal_privacy_acceptance   aceite do aviso de privacidade (por usuário e versão)
--   2. Schema portal_api, só com as quatro funções que o Portal chama com o token do próprio
--      empregado (papel authenticated): listar_meus_documentos, abrir_meu_documento,
--      meu_aviso_privacidade e aceitar_aviso_privacidade.
--   3. Funções do escritório (sessão de aplicação, EXECUTE só para dnex_gestao_api):
--      folha.portal_acesso_habilitar_v1, portal_acesso_revogar_v1, portal_acesso_definir_prazo_v1
--      (folha.admin); portal_documento_publicar_v1, portal_documento_retirar_v1 (folha.transmit);
--      portal_relatorio_visualizacao_v1 (folha.read).
--
-- Dois públicos, dois caminhos de identidade, que não se misturam:
--   * Escritório: contexto da Folha (claim de gestao_folha, migration 0028). O subject do
--     contexto é gravado em quem habilitou, revogou, publicou e retirou.
--   * Empregado: NÃO é usuário do Hub e não tem claim da Folha. Entra pelo serviço de
--     autenticação (código por e-mail), chega ao banco como o papel authenticated e é
--     identificado por auth.uid(), que lê o claim `sub` do token validado pelo PostgREST. O
--     banco não guarda nem confere segredo: o que ele confere é a habilitação gravada pelo
--     escritório para aquele identificador (portal_employee_access). As funções do schema
--     portal_api não recebem conta, trabalhador nem usuário por parâmetro.
--     auth.uid() confia em parâmetros de requisição que qualquer sessão com SQL livre pode
--     definir; por isso o EXECUTE dessas funções é só de authenticated (papel que só existe
--     atrás do PostgREST) e NÃO é dado a dnex_gestao_api, ao worker nem a service_role.
--
-- Regra de acesso (uma só, usada por listar e por abrir): existe habilitação com o user_id de
-- auth.uid(), status 'ativo', acesso_ate nulo ou não vencido (data de São Paulo), para a mesma
-- conta, trabalhador e empregador do documento; e o documento está 'publicado'. Desligamento
-- (data_demissao, status do contrato) NÃO entra na regra: o corte é acesso_ate ou revogação.
--
-- Publicação: todo documento com run_id exige folha FECHADA, sem pendência aberta, com
-- resultado daquele trabalhador. Holerite exige run_id. Publicação por parâmetro ou por rotina
-- de documento que nasce de folha (holerite, 13º, recibo de férias, rescisão) exige run_id.
-- Conferido por gatilho, no dado.
--
-- NÃO altera as migrations 0014 a 0028. NÃO APLICAR EM PRODUÇÃO antes da 0028 e sem a decisão
-- do dono sobre expor o schema portal_api na API (docs/CONTRATO-PORTAL.md, seção 6).
-- Reversão: 0029_folha_portal_colaborador.supabase.down.sql.
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
      ('papel authenticated', NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'authenticated')),
      ('papel anon',          NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'anon')),
      ('papel dnex_gestao_api', NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'dnex_gestao_api')),
      ('auth.uid()',          to_regprocedure('auth.uid()') IS NULL),
      ('folha.contexto_v1(text) (migration 0028)', to_regprocedure('folha.contexto_v1(text)') IS NULL),
      ('folha.employer (migration 0024)', to_regclass('folha.employer') IS NULL)
    ) AS x(nome, ausente)
   WHERE x.ausente;
  IF v_faltando IS NOT NULL THEN
    RAISE EXCEPTION '0029: faltam objetos: %', v_faltando
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;
  IF to_regnamespace('portal_api') IS NOT NULL THEN
    RAISE EXCEPTION '0029: o schema portal_api já existe; não é adotado'
      USING ERRCODE = 'duplicate_schema';
  END IF;
  -- As funções leem com row_security = off e filtro explícito: o dono precisa ignorar RLS, ou
  -- a leitura falharia em toda chamada.
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles
                  WHERE rolname = current_user AND (rolsuper OR rolbypassrls)) THEN
    RAISE EXCEPTION '0029: o papel % não é superusuário nem tem BYPASSRLS', current_user
      USING ERRCODE = 'insufficient_privilege';
  END IF;
END
$$;

-- ===========================================================================
-- 1. Tabelas
-- ===========================================================================

-- 1.1 Habilitação do empregado: por empregador, não por contrato (recontratação no mesmo
--     empregador mantém o acesso). Um user_id pode ter várias linhas ativas (vários
--     empregadores e contas); um trabalhador tem no máximo uma ativa por empregador.
CREATE TABLE folha.portal_employee_access (
  access_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  employee_id uuid NOT NULL,
  employer_id uuid NOT NULL,
  user_id uuid NOT NULL,           -- identificador do usuário no serviço de autenticação (auth.users); sem FK entre schemas
  status text NOT NULL DEFAULT 'ativo' CHECK (status IN ('ativo', 'revogado')),
  acesso_ate date,                 -- inclusiva, data de São Paulo; NULL = sem data de corte
  habilitado_por_subject uuid NOT NULL,
  habilitado_em timestamptz NOT NULL DEFAULT now(),
  revogado_por_subject uuid,
  revogado_em timestamptz,
  CONSTRAINT portal_employee_access_employee_fk FOREIGN KEY (account_id, employee_id)
    REFERENCES folha.employee (account_id, employee_id),
  CONSTRAINT portal_employee_access_employer_fk FOREIGN KEY (account_id, employer_id)
    REFERENCES folha.employer (account_id, employer_id),
  CONSTRAINT portal_employee_access_revogacao_completa CHECK (
    (status = 'ativo' AND revogado_por_subject IS NULL AND revogado_em IS NULL)
    OR (status = 'revogado' AND revogado_por_subject IS NOT NULL AND revogado_em IS NOT NULL))
);
CREATE UNIQUE INDEX portal_employee_access_ativo_key
  ON folha.portal_employee_access (account_id, employee_id, employer_id) WHERE status = 'ativo';
-- Um usuário é um só trabalhador em cada empregador: sem isto, um identificador digitado
-- errado na habilitação de outro trabalhador do mesmo empregador abriria o holerite alheio.
CREATE UNIQUE INDEX portal_employee_access_usuario_key
  ON folha.portal_employee_access (account_id, employer_id, user_id) WHERE status = 'ativo';
CREATE INDEX portal_employee_access_user_idx
  ON folha.portal_employee_access (user_id) WHERE status = 'ativo';

-- 1.2 Documento publicado. O arquivo fica no armazenamento; aqui ficam o caminho, o hash e o
--     tamanho. O caminho começa obrigatoriamente por <account_id>/<employee_id>/: como a API do
--     Portal assina qualquer caminho que o banco devolve, sem esse prefixo um documento poderia
--     apontar para o arquivo de outra conta ou de outro trabalhador.
CREATE TABLE folha.published_document (
  document_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  employee_id uuid NOT NULL,
  employer_id uuid NOT NULL,
  establishment_id uuid,
  contract_id uuid,
  tipo text NOT NULL CHECK (tipo IN (
    'holerite', 'ferias_recibo', 'ferias_aviso', 'decimo_terceiro', 'rescisao',
    'informe_rendimentos', 'espelho_ponto')),
  competencia date NOT NULL,
  titulo text NOT NULL CHECK (btrim(titulo) <> '' AND char_length(titulo) <= 200),
  storage_path text NOT NULL,
  sha256 text NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
  tamanho_bytes bigint NOT NULL CHECK (tamanho_bytes >= 0),
  status text NOT NULL DEFAULT 'publicado' CHECK (status IN ('publicado', 'retirado')),
  origem_publicacao text NOT NULL CHECK (origem_publicacao IN ('avulsa', 'parametro', 'rotina')),
  run_id uuid,
  published_by_subject uuid NOT NULL,
  published_at timestamptz NOT NULL DEFAULT now(),
  retired_by_subject uuid,
  retired_at timestamptz,
  retired_motivo text,
  CONSTRAINT published_document_employee_fk FOREIGN KEY (account_id, employee_id)
    REFERENCES folha.employee (account_id, employee_id),
  CONSTRAINT published_document_employer_fk FOREIGN KEY (account_id, employer_id)
    REFERENCES folha.employer (account_id, employer_id),
  CONSTRAINT published_document_establishment_fk FOREIGN KEY (account_id, employer_id, establishment_id)
    REFERENCES folha.establishment (account_id, employer_id, establishment_id),
  CONSTRAINT published_document_contract_fk FOREIGN KEY (account_id, employer_id, contract_id)
    REFERENCES folha.employment_contract (account_id, employer_id, contract_id),
  CONSTRAINT published_document_run_fk FOREIGN KEY (account_id, run_id)
    REFERENCES folha.payroll_run (account_id, run_id),
  CONSTRAINT published_document_competencia_dia_1 CHECK (EXTRACT(DAY FROM competencia) = 1),
  -- informe de rendimentos e 13º: dezembro do ano-base (o Portal mostra só o ano)
  CONSTRAINT published_document_competencia_anual CHECK (
    tipo NOT IN ('informe_rendimentos', 'decimo_terceiro') OR EXTRACT(MONTH FROM competencia) = 12),
  CONSTRAINT published_document_holerite_exige_folha CHECK (tipo <> 'holerite' OR run_id IS NOT NULL),
  CONSTRAINT published_document_origem_exige_folha CHECK (
    origem_publicacao = 'avulsa'
    OR tipo NOT IN ('holerite', 'decimo_terceiro', 'ferias_recibo', 'rescisao')
    OR run_id IS NOT NULL),
  CONSTRAINT published_document_storage_path_forma CHECK (
    storage_path ~ '^[0-9A-Za-z_.-]+(/[0-9A-Za-z_.-]+)+$'
    AND storage_path !~ '(^|/)\.\.?(/|$)'
    AND char_length(storage_path) <= 500),
  CONSTRAINT published_document_storage_path_prefixo CHECK (
    left(storage_path, 74) = account_id::text || '/' || employee_id::text || '/'),
  CONSTRAINT published_document_retirada_completa CHECK (
    (status = 'publicado' AND retired_by_subject IS NULL AND retired_at IS NULL AND retired_motivo IS NULL)
    OR (status = 'retirado' AND retired_by_subject IS NOT NULL AND retired_at IS NOT NULL
        AND btrim(COALESCE(retired_motivo, '')) <> '')),
  UNIQUE (account_id, document_id),
  UNIQUE (account_id, document_id, employee_id)   -- alvo da chave do registro de acesso
);
-- Um documento publicado por folha, trabalhador e tipo. A especificação pedia unicidade por
-- competência; a Folha admite várias folhas na mesma competência (adiantamento, mensal,
-- complementar; 13º em duas parcelas), e cada uma tem o seu documento.
CREATE UNIQUE INDEX published_document_folha_key
  ON folha.published_document (account_id, employee_id, employer_id, tipo, run_id,
                               (COALESCE(contract_id, '00000000-0000-0000-0000-000000000000'::uuid)))
  WHERE status = 'publicado' AND run_id IS NOT NULL;
-- Um arquivo, um documento (publicado ou retirado): corrigir é publicar outro arquivo.
CREATE UNIQUE INDEX published_document_storage_path_key ON folha.published_document (storage_path);
-- Sem folha: um por competência nos tipos que não admitem mais de um.
CREATE UNIQUE INDEX published_document_competencia_key
  ON folha.published_document (account_id, employee_id, employer_id, tipo, competencia)
  WHERE status = 'publicado' AND run_id IS NULL
    AND tipo IN ('decimo_terceiro', 'informe_rendimentos', 'espelho_ponto');
CREATE INDEX published_document_lista_idx
  ON folha.published_document (account_id, employee_id, employer_id, competencia DESC, published_at DESC)
  WHERE status = 'publicado';
CREATE INDEX published_document_run_idx
  ON folha.published_document (account_id, run_id) WHERE run_id IS NOT NULL;

-- 1.3 Registro de acesso: só INSERT, pela função abrir_meu_documento. Listar não grava.
CREATE TABLE folha.published_document_access (
  access_log_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id uuid NOT NULL,
  document_id uuid NOT NULL,
  employee_id uuid NOT NULL,
  user_id uuid NOT NULL,
  acao text NOT NULL CHECK (acao IN ('abriu', 'baixou')),
  at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT published_document_access_document_fk FOREIGN KEY (account_id, document_id, employee_id)
    REFERENCES folha.published_document (account_id, document_id, employee_id)
);
CREATE INDEX published_document_access_visto_idx
  ON folha.published_document_access (document_id, user_id, at);

-- 1.4 Aceite do aviso de privacidade: do usuário, não da conta.
CREATE TABLE folha.portal_privacy_acceptance (
  user_id uuid NOT NULL,
  versao text NOT NULL CHECK (versao ~ '^[0-9A-Za-z][0-9A-Za-z._-]{0,31}$'),
  accepted_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, versao)
);

-- ===========================================================================
-- 2. Gatilhos: as regras valem no dado, para qualquer caminho de gravação
-- ===========================================================================

-- 2.1 Trabalhador com vínculo no empregador (algum contrato, vigente ou encerrado, ou o
--     empregador do cadastro do trabalhador).
CREATE FUNCTION folha.portal_vinculo_existe(p_conta uuid, p_employee_id uuid, p_employer_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
  SELECT EXISTS (SELECT 1 FROM folha.employment_contract k
                  WHERE k.account_id = p_conta AND k.employee_id = p_employee_id AND k.employer_id = p_employer_id)
      OR EXISTS (SELECT 1 FROM folha.employee e
                  WHERE e.account_id = p_conta AND e.employee_id = p_employee_id AND e.employer_id = p_employer_id);
$function$;

-- 2.2 Habilitação: nasce ativa; só muda o prazo (enquanto ativa) ou passa a revogada; não é apagada.
CREATE FUNCTION folha.portal_employee_access_trava() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Habilitação do Portal não é apagada: revogue' USING ERRCODE = 'restrict_violation';
  END IF;
  IF TG_OP = 'INSERT' THEN
    IF NEW.status <> 'ativo' THEN
      RAISE EXCEPTION 'Habilitação do Portal nasce ativa' USING ERRCODE = 'check_violation';
    END IF;
    IF NOT folha.portal_vinculo_existe(NEW.account_id, NEW.employee_id, NEW.employer_id) THEN
      RAISE EXCEPTION 'Trabalhador % não tem vínculo com o empregador %', NEW.employee_id, NEW.employer_id
        USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
  END IF;
  IF OLD.status = 'revogado' THEN
    RAISE EXCEPTION 'Habilitação % está revogada e não pode ser alterada', OLD.access_id USING ERRCODE = 'restrict_violation';
  END IF;
  IF ROW(NEW.access_id, NEW.account_id, NEW.employee_id, NEW.employer_id, NEW.user_id, NEW.habilitado_por_subject, NEW.habilitado_em)
     IS DISTINCT FROM
     ROW(OLD.access_id, OLD.account_id, OLD.employee_id, OLD.employer_id, OLD.user_id, OLD.habilitado_por_subject, OLD.habilitado_em) THEN
    RAISE EXCEPTION 'Habilitação %: só o prazo e a revogação podem mudar', OLD.access_id USING ERRCODE = 'restrict_violation';
  END IF;
  RETURN NEW;
END
$function$;
CREATE TRIGGER trg_portal_employee_access_trava
  BEFORE INSERT OR UPDATE OR DELETE ON folha.portal_employee_access
  FOR EACH ROW EXECUTE FUNCTION folha.portal_employee_access_trava();

-- 2.3 Documento: confere a publicação; depois só passa de publicado a retirado, sem mexer em
--     mais nada; não é apagado. Corrigir = retirar e publicar outro.
CREATE FUNCTION folha.published_document_trava() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_run record;
  v_contrato uuid;
  v_n bigint;
BEGIN
  IF TG_OP = 'DELETE' THEN
    RAISE EXCEPTION 'Documento publicado não é apagado: retire' USING ERRCODE = 'restrict_violation';
  END IF;

  IF TG_OP = 'UPDATE' THEN
    IF OLD.status <> 'publicado' OR NEW.status <> 'retirado' THEN
      RAISE EXCEPTION 'Documento %: a única alteração possível é de publicado para retirado', OLD.document_id
        USING ERRCODE = 'restrict_violation';
    END IF;
    IF (to_jsonb(NEW) - ARRAY['status', 'retired_by_subject', 'retired_at', 'retired_motivo'])
       IS DISTINCT FROM (to_jsonb(OLD) - ARRAY['status', 'retired_by_subject', 'retired_at', 'retired_motivo']) THEN
      RAISE EXCEPTION 'Documento %: ao retirar, nenhum outro campo muda (corrigir = retirar e publicar outro)', OLD.document_id
        USING ERRCODE = 'restrict_violation';
    END IF;
    RETURN NEW;
  END IF;

  IF NEW.status <> 'publicado' THEN
    RAISE EXCEPTION 'Documento nasce publicado' USING ERRCODE = 'check_violation';
  END IF;
  IF NOT folha.portal_vinculo_existe(NEW.account_id, NEW.employee_id, NEW.employer_id) THEN
    RAISE EXCEPTION 'Trabalhador % não tem vínculo com o empregador %', NEW.employee_id, NEW.employer_id
      USING ERRCODE = 'check_violation';
  END IF;
  IF NEW.contract_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM folha.employment_contract k
        WHERE k.account_id = NEW.account_id AND k.contract_id = NEW.contract_id
          AND k.employee_id = NEW.employee_id AND k.employer_id = NEW.employer_id) THEN
    RAISE EXCEPTION 'Contrato % não é deste trabalhador neste empregador', NEW.contract_id
      USING ERRCODE = 'check_violation';
  END IF;

  IF NEW.run_id IS NOT NULL THEN
    SELECT r.status, r.employer_id, r.competencia, r.tipo_processo INTO v_run
      FROM folha.payroll_run r
     WHERE r.account_id = NEW.account_id AND r.run_id = NEW.run_id
       FOR KEY SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Folha % não encontrada', NEW.run_id USING ERRCODE = 'foreign_key_violation';
    END IF;
    IF v_run.status <> 'closed' THEN
      RAISE EXCEPTION 'Folha % está em %: só documento de folha fechada é publicado', NEW.run_id, v_run.status
        USING ERRCODE = 'check_violation';
    END IF;
    IF EXISTS (SELECT 1 FROM folha.payroll_pendency p
                WHERE p.account_id = NEW.account_id AND p.run_id = NEW.run_id AND p.liberada_em IS NULL) THEN
      RAISE EXCEPTION 'Folha % tem pendência sem liberação: documento não é publicado', NEW.run_id
        USING ERRCODE = 'check_violation';
    END IF;
    -- O documento é do tipo de processo da folha; aviso de férias, informe e espelho de ponto
    -- não nascem de folha.
    IF NOT COALESCE(
         CASE NEW.tipo
           WHEN 'holerite'        THEN v_run.tipo_processo IN ('mensal', 'adiantamento', 'complementar')
           WHEN 'decimo_terceiro' THEN v_run.tipo_processo IN ('decimo_terceiro_1', 'decimo_terceiro_2')
           WHEN 'ferias_recibo'   THEN v_run.tipo_processo = 'ferias'
           WHEN 'rescisao'        THEN v_run.tipo_processo = 'rescisao'
           ELSE false
         END, false) THEN
      RAISE EXCEPTION 'Documento do tipo % não é publicado a partir de folha do tipo %', NEW.tipo, v_run.tipo_processo
        USING ERRCODE = 'check_violation';
    END IF;
    IF v_run.employer_id IS NOT NULL AND v_run.employer_id <> NEW.employer_id THEN
      RAISE EXCEPTION 'Folha % é de outro empregador', NEW.run_id USING ERRCODE = 'check_violation';
    END IF;
    IF NOT EXISTS (
         SELECT 1
           FROM folha.payroll_result pr
           JOIN folha.employment_contract k ON k.account_id = pr.account_id AND k.contract_id = pr.contract_id
          WHERE pr.account_id = NEW.account_id AND pr.run_id = NEW.run_id
            AND pr.employee_id = NEW.employee_id AND k.employer_id = NEW.employer_id
            AND (NEW.contract_id IS NULL OR pr.contract_id = NEW.contract_id)) THEN
      RAISE EXCEPTION 'Trabalhador % não tem resultado na folha % para este empregador', NEW.employee_id, NEW.run_id
        USING ERRCODE = 'check_violation';
    END IF;
    -- Com folha, o documento é de UM contrato: sem isso dois documentos do mesmo trabalhador,
    -- um com contrato e outro sem, escapariam da unicidade. Se não veio, vale o único contrato
    -- do trabalhador com resultado nessa folha e nesse empregador; havendo mais de um, é erro.
    IF NEW.contract_id IS NULL THEN
      SELECT min(pr.contract_id::text)::uuid, count(*) INTO v_contrato, v_n
        FROM folha.payroll_result pr
        JOIN folha.employment_contract k ON k.account_id = pr.account_id AND k.contract_id = pr.contract_id
       WHERE pr.account_id = NEW.account_id AND pr.run_id = NEW.run_id
         AND pr.employee_id = NEW.employee_id AND k.employer_id = NEW.employer_id;
      IF v_n <> 1 THEN
        RAISE EXCEPTION 'Trabalhador % tem mais de um contrato na folha %: informe o contrato do documento', NEW.employee_id, NEW.run_id
          USING ERRCODE = 'check_violation';
      END IF;
      NEW.contract_id := v_contrato;
    END IF;
    IF NEW.tipo = 'holerite' AND NEW.competencia <> v_run.competencia THEN
      RAISE EXCEPTION 'Holerite: a competência do documento (%) não é a da folha (%)', NEW.competencia, v_run.competencia
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;
  RETURN NEW;
END
$function$;
CREATE TRIGGER trg_published_document_trava
  BEFORE INSERT OR UPDATE OR DELETE ON folha.published_document
  FOR EACH ROW EXECUTE FUNCTION folha.published_document_trava();

-- 2.4 Registro de acesso e aceite: só INSERT.
CREATE FUNCTION folha.portal_so_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $function$
BEGIN
  RAISE EXCEPTION 'folha.%: % recusado (o registro não é alterado nem apagado)', TG_TABLE_NAME, TG_OP
    USING ERRCODE = 'restrict_violation';
END
$function$;
CREATE TRIGGER trg_published_document_access_so_insert
  BEFORE UPDATE OR DELETE ON folha.published_document_access
  FOR EACH ROW EXECUTE FUNCTION folha.portal_so_insert();
CREATE TRIGGER trg_published_document_access_sem_truncate
  BEFORE TRUNCATE ON folha.published_document_access
  FOR EACH STATEMENT EXECUTE FUNCTION folha.portal_so_insert();
CREATE TRIGGER trg_portal_privacy_acceptance_sem_truncate
  BEFORE TRUNCATE ON folha.portal_privacy_acceptance
  FOR EACH STATEMENT EXECUTE FUNCTION folha.portal_so_insert();
CREATE TRIGGER trg_portal_employee_access_sem_truncate
  BEFORE TRUNCATE ON folha.portal_employee_access
  FOR EACH STATEMENT EXECUTE FUNCTION folha.portal_so_insert();
CREATE TRIGGER trg_published_document_sem_truncate
  BEFORE TRUNCATE ON folha.published_document
  FOR EACH STATEMENT EXECUTE FUNCTION folha.portal_so_insert();
CREATE TRIGGER trg_portal_privacy_acceptance_so_insert
  BEFORE UPDATE OR DELETE ON folha.portal_privacy_acceptance
  FOR EACH ROW EXECUTE FUNCTION folha.portal_so_insert();

-- ===========================================================================
-- 3. Funções do empregado (schema portal_api; EXECUTE só para authenticated)
--    Nenhuma recebe conta, trabalhador nem usuário. auth.uid() nulo: vazio.
--    Mensagens de erro sem dado pessoal (no máximo o nome do parâmetro).
-- ===========================================================================
CREATE SCHEMA portal_api;
COMMENT ON SCHEMA portal_api IS
  'DNEX Folha: funções que o Portal do Colaborador chama com o token do próprio empregado (papel authenticated). Só funções; nenhuma tabela.';

-- Item do contrato folha.portal-documento-publicado.v1 (dez campos, nesta ordem).
CREATE FUNCTION portal_api.listar_meus_documentos(
  p_tipo text DEFAULT NULL,
  p_de date DEFAULT NULL,
  p_ate date DEFAULT NULL,
  p_employer_id uuid DEFAULT NULL
) RETURNS TABLE (
  document_id uuid,
  employer_id uuid,
  employer_nome text,
  establishment_inscricao text,
  tipo text,
  competencia date,
  titulo text,
  published_at timestamptz,
  tamanho_bytes bigint,
  visto_em timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
  SELECT d.document_id, d.employer_id, e.razao_social, s.inscricao, d.tipo, d.competencia, d.titulo,
         d.published_at, d.tamanho_bytes,
         (SELECT min(l.at) FROM folha.published_document_access l
           WHERE l.account_id = d.account_id AND l.document_id = d.document_id AND l.user_id = u.uid)
    FROM (SELECT auth.uid() AS uid) AS u
    JOIN folha.portal_employee_access a
      ON a.user_id = u.uid
     AND a.status = 'ativo'
     AND (a.acesso_ate IS NULL OR (now() AT TIME ZONE 'America/Sao_Paulo')::date <= a.acesso_ate)
    JOIN folha.published_document d
      ON d.account_id = a.account_id AND d.employee_id = a.employee_id AND d.employer_id = a.employer_id
     AND d.status = 'publicado'
    JOIN folha.employer e
      ON e.account_id = d.account_id AND e.employer_id = d.employer_id
    LEFT JOIN folha.establishment s
      ON s.account_id = d.account_id AND s.employer_id = d.employer_id AND s.establishment_id = d.establishment_id
   WHERE u.uid IS NOT NULL
     AND (p_tipo IS NULL OR d.tipo = p_tipo)
     AND (p_de IS NULL OR d.competencia >= p_de)
     AND (p_ate IS NULL OR d.competencia <= p_ate)
     AND (p_employer_id IS NULL OR d.employer_id = p_employer_id)
   ORDER BY d.competencia DESC, d.published_at DESC, d.document_id;
$function$;

-- Devolve o caminho e o hash de UM documento do próprio usuário e grava o acesso na mesma
-- transação. Nenhuma linha para "não existe", "não é seu", "retirado", habilitação revogada ou
-- vencida; nesses casos não grava acesso. O caminho não vai ao navegador: a API do Portal
-- assina o link com a chave de serviço.
CREATE FUNCTION portal_api.abrir_meu_documento(p_document_id uuid, p_acao text)
RETURNS TABLE (storage_path text, sha256 text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
#variable_conflict use_column
DECLARE
  v_uid uuid := auth.uid();
  v_doc record;
BEGIN
  IF p_acao IS NULL OR p_acao NOT IN ('abriu', 'baixou') THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'abrir_meu_documento: p_acao deve ser abriu ou baixou';
  END IF;
  IF v_uid IS NULL OR p_document_id IS NULL THEN
    RETURN;
  END IF;

  SELECT d.account_id, d.document_id, d.employee_id, d.storage_path, d.sha256
    INTO v_doc
    FROM folha.published_document d
    JOIN folha.portal_employee_access a
      ON a.account_id = d.account_id AND a.employee_id = d.employee_id AND a.employer_id = d.employer_id
     AND a.user_id = v_uid
     AND a.status = 'ativo'
     AND (a.acesso_ate IS NULL OR (now() AT TIME ZONE 'America/Sao_Paulo')::date <= a.acesso_ate)
   WHERE d.document_id = p_document_id
     AND d.status = 'publicado'
     FOR SHARE OF d;
  IF NOT FOUND THEN
    RETURN;
  END IF;

  -- Hora real do acesso (e não a do início da transação). A tabela é só de inclusão: a mesma
  -- ação do mesmo usuário no mesmo documento em menos de 60 segundos não grava outra linha
  -- (repetição em rajada não cresce a tabela); o caminho é devolvido do mesmo jeito.
  -- Serializa por usuário, documento e ação: pedidos simultâneos gravam uma linha só.
  PERFORM pg_advisory_xact_lock(hashtextextended(
    'folha.portal_acesso_doc:' || v_uid::text || ':' || v_doc.document_id::text || ':' || p_acao, 0));
  IF NOT EXISTS (SELECT 1 FROM folha.published_document_access l
                  WHERE l.account_id = v_doc.account_id AND l.document_id = v_doc.document_id
                    AND l.user_id = v_uid AND l.acao = p_acao
                    AND l.at > clock_timestamp() - interval '60 seconds') THEN
    INSERT INTO folha.published_document_access (account_id, document_id, employee_id, user_id, acao, at)
    VALUES (v_doc.account_id, v_doc.document_id, v_doc.employee_id, v_uid, p_acao, clock_timestamp());
  END IF;

  storage_path := v_doc.storage_path;
  sha256 := v_doc.sha256;
  RETURN NEXT;
END
$function$;

-- A versão mais recente que o usuário aceitou, ou nulo.
CREATE FUNCTION portal_api.meu_aviso_privacidade() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
  SELECT p.versao
    FROM folha.portal_privacy_acceptance p
   WHERE p.user_id = auth.uid()
   ORDER BY p.accepted_at DESC, p.versao DESC
   LIMIT 1;
$function$;

-- Idempotente. Só grava para usuário que o escritório já habilitou alguma vez (ativa ou
-- revogada): usuário autenticado sem habilitação não ocupa espaço na tabela. O banco confere
-- só o formato de p_versao: saber se a versão existe e é a vigente é da API do Portal. No máximo cinco
-- versões novas por usuário a cada 24 horas (o limite passa sozinho; não trava o aceite de vez).
CREATE FUNCTION portal_api.aceitar_aviso_privacidade(p_versao text) RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF p_versao IS NULL OR p_versao !~ '^[0-9A-Za-z][0-9A-Za-z._-]{0,31}$' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'aceitar_aviso_privacidade: p_versao inválida';
  END IF;
  IF v_uid IS NULL
     OR NOT EXISTS (SELECT 1 FROM folha.portal_employee_access a WHERE a.user_id = v_uid) THEN
    RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM folha.portal_privacy_acceptance p WHERE p.user_id = v_uid AND p.versao = p_versao) THEN
    RETURN;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('folha.portal_aceite:' || v_uid::text, 0));
  IF (SELECT count(*) FROM folha.portal_privacy_acceptance p
       WHERE p.user_id = v_uid AND p.accepted_at > clock_timestamp() - interval '24 hours') >= 5 THEN
    RAISE EXCEPTION USING ERRCODE = '54000', MESSAGE = 'aceitar_aviso_privacidade: muitas versões aceitas em 24 horas; tente depois';
  END IF;
  INSERT INTO folha.portal_privacy_acceptance (user_id, versao, accepted_at)
  VALUES (v_uid, p_versao, clock_timestamp())
  ON CONFLICT (user_id, versao) DO NOTHING;
END
$function$;

-- ===========================================================================
-- 4. Funções do escritório (sessão de aplicação; contexto da Folha)
-- ===========================================================================

-- 4.1 Habilitar (folha.admin). Idempotente para o mesmo usuário; recusa se o trabalhador já
--     tem habilitação ativa de OUTRO usuário naquele empregador (revogue antes). Pode ser feita
--     depois do desligamento. p_acesso_ate nulo = sem data de corte.
CREATE FUNCTION folha.portal_acesso_habilitar_v1(
  p_employee_id uuid,
  p_employer_id uuid,
  p_user_id uuid,
  p_acesso_ate date DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx record;
  v_atual record;
  v_id uuid;
BEGIN
  SELECT c.account_id, c.legal_entity_id, c.branch_id, c.subject_id INTO v_ctx
    FROM folha.contexto_v1('folha.admin') AS c;
  IF p_employee_id IS NULL OR p_employer_id IS NULL OR p_user_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'portal_acesso_habilitar_v1: trabalhador, empregador e usuário são obrigatórios';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM folha.employee e WHERE e.account_id = v_ctx.account_id AND e.employee_id = p_employee_id) THEN
    RAISE EXCEPTION 'Trabalhador % não encontrado', p_employee_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM folha.employer e WHERE e.account_id = v_ctx.account_id AND e.employer_id = p_employer_id) THEN
    RAISE EXCEPTION 'Empregador % não encontrado', p_employer_id;
  END IF;

  -- Serializa as habilitações do mesmo trabalhador.
  PERFORM pg_advisory_xact_lock(hashtextextended('folha.portal_acesso:' || v_ctx.account_id::text || ':' || p_employee_id::text, 0));
  SELECT a.access_id, a.user_id, a.acesso_ate INTO v_atual
    FROM folha.portal_employee_access a
   WHERE a.account_id = v_ctx.account_id AND a.employee_id = p_employee_id
     AND a.employer_id = p_employer_id AND a.status = 'ativo';
  IF FOUND THEN
    IF v_atual.user_id = p_user_id THEN
      IF p_acesso_ate IS DISTINCT FROM v_atual.acesso_ate THEN
        RAISE EXCEPTION 'Trabalhador % já está habilitado para este usuário com outro prazo; use portal_acesso_definir_prazo_v1', p_employee_id;
      END IF;
      PERFORM 1 FROM folha.contexto_v1('folha.admin');
      RETURN v_atual.access_id;
    END IF;
    RAISE EXCEPTION 'Trabalhador % já tem habilitação ativa de outro usuário neste empregador; revogue antes', p_employee_id;
  END IF;

  INSERT INTO folha.portal_employee_access (account_id, employee_id, employer_id, user_id, acesso_ate, habilitado_por_subject)
  VALUES (v_ctx.account_id, p_employee_id, p_employer_id, p_user_id, p_acesso_ate, v_ctx.subject_id)
  RETURNING access_id INTO v_id;
  INSERT INTO folha.auditoria (account_id, actor, actor_subject, acao, recurso, recurso_id, detalhe)
  VALUES (v_ctx.account_id, v_ctx.subject_id::text, v_ctx.subject_id, 'portal_habilitar_acesso', 'portal_employee_access', v_id,
          jsonb_build_object('employee_id', p_employee_id, 'employer_id', p_employer_id, 'acesso_ate', p_acesso_ate,
                             'sessao', session_user, 'legal_entity_id', v_ctx.legal_entity_id, 'branch_id', v_ctx.branch_id));
  PERFORM 1 FROM folha.contexto_v1('folha.admin');
  RETURN v_id;
END
$function$;

-- 4.2 Revogar (folha.admin). Idempotente para habilitação já revogada.
CREATE FUNCTION folha.portal_acesso_revogar_v1(p_access_id uuid) RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx record;
  v_status text;
BEGIN
  SELECT c.account_id, c.legal_entity_id, c.branch_id, c.subject_id INTO v_ctx
    FROM folha.contexto_v1('folha.admin') AS c;
  SELECT a.status INTO v_status
    FROM folha.portal_employee_access a
   WHERE a.account_id = v_ctx.account_id AND a.access_id = p_access_id
     FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Habilitação % não encontrada', p_access_id;
  END IF;
  IF v_status = 'ativo' THEN
    UPDATE folha.portal_employee_access a
       SET status = 'revogado', revogado_por_subject = v_ctx.subject_id, revogado_em = now()
     WHERE a.account_id = v_ctx.account_id AND a.access_id = p_access_id;
    INSERT INTO folha.auditoria (account_id, actor, actor_subject, acao, recurso, recurso_id, detalhe)
    VALUES (v_ctx.account_id, v_ctx.subject_id::text, v_ctx.subject_id, 'portal_revogar_acesso', 'portal_employee_access', p_access_id,
            jsonb_build_object('sessao', session_user, 'legal_entity_id', v_ctx.legal_entity_id, 'branch_id', v_ctx.branch_id));
  END IF;
  PERFORM 1 FROM folha.contexto_v1('folha.admin');
END
$function$;

-- 4.3 Prazo do acesso (folha.admin): data inclusiva de corte, ou nulo para tirar o corte.
CREATE FUNCTION folha.portal_acesso_definir_prazo_v1(p_access_id uuid, p_acesso_ate date) RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx record;
BEGIN
  SELECT c.account_id, c.legal_entity_id, c.branch_id, c.subject_id INTO v_ctx
    FROM folha.contexto_v1('folha.admin') AS c;
  UPDATE folha.portal_employee_access a
     SET acesso_ate = p_acesso_ate
   WHERE a.account_id = v_ctx.account_id AND a.access_id = p_access_id AND a.status = 'ativo';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Habilitação ativa % não encontrada', p_access_id;
  END IF;
  INSERT INTO folha.auditoria (account_id, actor, actor_subject, acao, recurso, recurso_id, detalhe)
  VALUES (v_ctx.account_id, v_ctx.subject_id::text, v_ctx.subject_id, 'portal_definir_prazo_acesso', 'portal_employee_access', p_access_id,
          jsonb_build_object('acesso_ate', p_acesso_ate, 'sessao', session_user,
                             'legal_entity_id', v_ctx.legal_entity_id, 'branch_id', v_ctx.branch_id));
  PERFORM 1 FROM folha.contexto_v1('folha.admin');
END
$function$;

-- 4.4 Publicar (folha.transmit). A conta e quem publica vêm do contexto. O arquivo já deve
--     estar no armazenamento; o banco confere a forma e o prefixo do caminho, o hash, a folha
--     fechada e o vínculo (restrições e gatilho da seção 2). p_document_id pode ser informado
--     (o caminho sugerido contém o identificador) ou gerado aqui.
CREATE FUNCTION folha.portal_documento_publicar_v1(
  p_employee_id uuid,
  p_employer_id uuid,
  p_tipo text,
  p_competencia date,
  p_titulo text,
  p_storage_path text,
  p_sha256 text,
  p_tamanho_bytes bigint,
  p_origem_publicacao text,
  p_run_id uuid DEFAULT NULL,
  p_contract_id uuid DEFAULT NULL,
  p_establishment_id uuid DEFAULT NULL,
  p_document_id uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx record;
  v_id uuid;
  v_restricao text;
  v_mensagem text;
  v_estado text;
BEGIN
  SELECT c.account_id, c.legal_entity_id, c.branch_id, c.subject_id INTO v_ctx
    FROM folha.contexto_v1('folha.transmit') AS c;
  IF p_employee_id IS NULL OR p_employer_id IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'portal_documento_publicar_v1: trabalhador e empregador são obrigatórios';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM folha.employee e WHERE e.account_id = v_ctx.account_id AND e.employee_id = p_employee_id) THEN
    RAISE EXCEPTION 'Trabalhador % não encontrado', p_employee_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM folha.employer e WHERE e.account_id = v_ctx.account_id AND e.employer_id = p_employer_id) THEN
    RAISE EXCEPTION 'Empregador % não encontrado', p_employer_id;
  END IF;

  BEGIN
  INSERT INTO folha.published_document (
    document_id, account_id, employee_id, employer_id, establishment_id, contract_id, tipo, competencia,
    titulo, storage_path, sha256, tamanho_bytes, origem_publicacao, run_id, published_by_subject)
  VALUES (
    COALESCE(p_document_id, gen_random_uuid()), v_ctx.account_id, p_employee_id, p_employer_id, p_establishment_id,
    p_contract_id, p_tipo, p_competencia, btrim(p_titulo), p_storage_path, lower(p_sha256), p_tamanho_bytes,
    p_origem_publicacao, p_run_id, v_ctx.subject_id)
  RETURNING document_id INTO v_id;
  EXCEPTION WHEN integrity_constraint_violation THEN
    -- O erro padrão de restrição traz a linha recusada no DETAIL (o título pode ter nome de
    -- pessoa). Relança só com o nome da restrição, ou com a mensagem do gatilho, sem DETAIL.
    GET STACKED DIAGNOSTICS v_restricao = CONSTRAINT_NAME, v_mensagem = MESSAGE_TEXT, v_estado = RETURNED_SQLSTATE;
    RAISE EXCEPTION USING ERRCODE = v_estado,
      MESSAGE = CASE WHEN COALESCE(v_restricao, '') <> ''
                     THEN 'portal_documento_publicar_v1: documento recusado pela restrição ' || v_restricao
                     ELSE v_mensagem END;
  END;
  INSERT INTO folha.auditoria (account_id, actor, actor_subject, acao, recurso, recurso_id, detalhe)
  VALUES (v_ctx.account_id, v_ctx.subject_id::text, v_ctx.subject_id, 'portal_publicar_documento', 'published_document', v_id,
          jsonb_build_object('employee_id', p_employee_id, 'employer_id', p_employer_id, 'tipo', p_tipo,
                             'competencia', p_competencia, 'origem', p_origem_publicacao, 'run_id', p_run_id,
                             'sessao', session_user, 'legal_entity_id', v_ctx.legal_entity_id, 'branch_id', v_ctx.branch_id));
  PERFORM 1 FROM folha.contexto_v1('folha.transmit');
  RETURN v_id;
END
$function$;

-- 4.5 Retirar (folha.transmit). Sem volta. Idempotente para documento já retirado.
CREATE FUNCTION folha.portal_documento_retirar_v1(p_document_id uuid, p_motivo text) RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
DECLARE
  v_ctx record;
  v_status text;
BEGIN
  SELECT c.account_id, c.legal_entity_id, c.branch_id, c.subject_id INTO v_ctx
    FROM folha.contexto_v1('folha.transmit') AS c;
  IF btrim(COALESCE(p_motivo, '')) = '' THEN
    RAISE EXCEPTION USING ERRCODE = '22023', MESSAGE = 'portal_documento_retirar_v1: motivo obrigatório';
  END IF;
  SELECT d.status INTO v_status
    FROM folha.published_document d
   WHERE d.account_id = v_ctx.account_id AND d.document_id = p_document_id
     FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Documento % não encontrado', p_document_id;
  END IF;
  IF v_status = 'publicado' THEN
    UPDATE folha.published_document d
       SET status = 'retirado', retired_by_subject = v_ctx.subject_id, retired_at = now(), retired_motivo = btrim(p_motivo)
     WHERE d.account_id = v_ctx.account_id AND d.document_id = p_document_id;
    INSERT INTO folha.auditoria (account_id, actor, actor_subject, acao, recurso, recurso_id, detalhe)
    VALUES (v_ctx.account_id, v_ctx.subject_id::text, v_ctx.subject_id, 'portal_retirar_documento', 'published_document', p_document_id,
            jsonb_build_object('motivo', btrim(p_motivo), 'sessao', session_user,
                               'legal_entity_id', v_ctx.legal_entity_id, 'branch_id', v_ctx.branch_id));
  END IF;
  PERFORM 1 FROM folha.contexto_v1('folha.transmit');
END
$function$;

-- 4.6 Relatório de "visualizado" para o escritório (folha.read): por documento, a publicação
--     e o primeiro acesso de qualquer usuário habilitado. Fora do Portal.
CREATE FUNCTION folha.portal_relatorio_visualizacao_v1(
  p_de date DEFAULT NULL,
  p_ate date DEFAULT NULL,
  p_employer_id uuid DEFAULT NULL,
  p_tipo text DEFAULT NULL
) RETURNS TABLE (
  document_id uuid,
  employee_id uuid,
  employer_id uuid,
  tipo text,
  competencia date,
  titulo text,
  status text,
  published_at timestamptz,
  primeiro_acesso_em timestamptz,
  total_acessos bigint
)
LANGUAGE sql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET row_security = off
AS $function$
  SELECT d.document_id, d.employee_id, d.employer_id, d.tipo, d.competencia, d.titulo, d.status, d.published_at,
         v.primeiro, COALESCE(v.total, 0)
    FROM folha.contexto_v1('folha.read') AS c
    JOIN folha.published_document d ON d.account_id = c.account_id
    LEFT JOIN LATERAL (
      SELECT min(l.at) AS primeiro, count(*) AS total
        FROM folha.published_document_access l
       WHERE l.account_id = d.account_id AND l.document_id = d.document_id) v ON true
   WHERE (p_de IS NULL OR d.competencia >= p_de)
     AND (p_ate IS NULL OR d.competencia <= p_ate)
     AND (p_employer_id IS NULL OR d.employer_id = p_employer_id)
     AND (p_tipo IS NULL OR d.tipo = p_tipo)
   ORDER BY d.competencia DESC, d.published_at DESC, d.document_id;
$function$;

-- ===========================================================================
-- 5. RLS e ACL
--    RLS com FORCE nas quatro tabelas. Nenhuma policy para anon ou authenticated: a policy por
--    conta é só de leitura e só para worker e data_owner (papéis NOLOGIN da Folha); a tabela de
--    aceite, que não tem conta, não tem policy nem GRANT. Gravação só pelas funções.
--    REVOKE de todo papel que não seja o dono antes de qualquer GRANT (inclusive default ACL).
-- ===========================================================================
DO $$
DECLARE
  v_tabela text;
  v_item text[];
  v_papel text;
BEGIN
  FOREACH v_tabela IN ARRAY ARRAY[
    'portal_employee_access', 'published_document', 'published_document_access', 'portal_privacy_acceptance']
  LOOP
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
    IF v_tabela <> 'portal_privacy_acceptance' THEN
      EXECUTE format(
        'CREATE POLICY %I ON folha.%I FOR SELECT TO dnex_gestao_folha_worker, dnex_gestao_data_owner
           USING (account_id = (SELECT folha.current_account_id()))',
        v_tabela || '_isolamento', v_tabela);
      EXECUTE format('GRANT SELECT ON folha.%I TO dnex_gestao_folha_worker, dnex_gestao_data_owner', v_tabela);
    END IF;
  END LOOP;

  REVOKE ALL ON SCHEMA portal_api FROM PUBLIC, anon, authenticated, service_role;
  GRANT USAGE ON SCHEMA portal_api TO authenticated;

  FOREACH v_item SLICE 1 IN ARRAY ARRAY[
    ['folha.portal_vinculo_existe(uuid, uuid, uuid)',                 ''],
    ['folha.portal_employee_access_trava()',                          ''],
    ['folha.published_document_trava()',                              ''],
    ['folha.portal_so_insert()',                                      ''],
    ['portal_api.listar_meus_documentos(text, date, date, uuid)',     'authenticated'],
    ['portal_api.abrir_meu_documento(uuid, text)',                    'authenticated'],
    ['portal_api.meu_aviso_privacidade()',                            'authenticated'],
    ['portal_api.aceitar_aviso_privacidade(text)',                    'authenticated'],
    ['folha.portal_acesso_habilitar_v1(uuid, uuid, uuid, date)',      'dnex_gestao_api'],
    ['folha.portal_acesso_revogar_v1(uuid)',                          'dnex_gestao_api'],
    ['folha.portal_acesso_definir_prazo_v1(uuid, date)',              'dnex_gestao_api'],
    ['folha.portal_documento_publicar_v1(uuid, uuid, text, date, text, text, text, bigint, text, uuid, uuid, uuid, uuid)', 'dnex_gestao_api'],
    ['folha.portal_documento_retirar_v1(uuid, text)',                 'dnex_gestao_api'],
    ['folha.portal_relatorio_visualizacao_v1(date, date, uuid, text)', 'dnex_gestao_api']
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
-- 6. Pós-voo (falha fechada)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_inesperado text;
BEGIN
  -- portal_api: só as quatro funções, só authenticated.
  SELECT string_agg(x.linha, ', ' ORDER BY x.linha) INTO v_inesperado
    FROM (
      SELECT p.oid::regprocedure::text || ' <- ' || CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END AS linha
        FROM pg_catalog.pg_proc p
        CROSS JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
       WHERE p.pronamespace = 'portal_api'::regnamespace AND a.grantee <> p.proowner
         AND (a.grantee = 0 OR a.grantee::regrole::text <> 'authenticated')
      UNION ALL
      SELECT 'schema portal_api <- ' || CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END || ':' || a.privilege_type
        FROM pg_catalog.pg_namespace n
        CROSS JOIN LATERAL aclexplode(COALESCE(n.nspacl, acldefault('n', n.nspowner))) a
       WHERE n.nspname = 'portal_api' AND a.grantee <> n.nspowner
         AND NOT (a.grantee <> 0 AND a.grantee::regrole::text = 'authenticated' AND a.privilege_type = 'USAGE')
    ) x;
  IF v_inesperado IS NOT NULL THEN
    RAISE EXCEPTION '0029: privilégio inesperado em portal_api: %', v_inesperado USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF (SELECT count(*) FROM pg_catalog.pg_proc p WHERE p.pronamespace = 'portal_api'::regnamespace) <> 4
     OR EXISTS (SELECT 1 FROM pg_catalog.pg_class c WHERE c.relnamespace = 'portal_api'::regnamespace) THEN
    RAISE EXCEPTION '0029: o schema portal_api deve ter exatamente as quatro funções e nenhuma relação'
      USING ERRCODE = 'object_not_in_prerequisite_state';
  END IF;

  SELECT string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text) INTO v_inesperado
    FROM pg_catalog.pg_proc p
   WHERE p.pronamespace IN ('portal_api'::regnamespace, 'folha'::regnamespace) AND p.prosecdef
     AND NOT EXISTS (SELECT 1 FROM unnest(p.proconfig) AS cfg
                      WHERE cfg ~ '^search_path=pg_catalog(,|$)' AND cfg ~ ',\s*pg_temp$' AND cfg !~ 'pg_temp.*pg_temp');
  IF v_inesperado IS NOT NULL THEN
    RAISE EXCEPTION '0029: função SECURITY DEFINER cujo search_path não começa por pg_catalog e termina em pg_temp (só no fim): %', v_inesperado
      USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- anon e authenticated: nenhuma das quatro tabelas, por nenhum caminho; anon, nenhuma função.
  SELECT string_agg(t.nome || ' <- ' || r.papel, ', ') INTO v_inesperado
    FROM (VALUES ('portal_employee_access'), ('published_document'), ('published_document_access'), ('portal_privacy_acceptance')) AS t(nome)
    CROSS JOIN (VALUES ('anon'), ('authenticated'), ('service_role'), ('dnex_gestao_api')) AS r(papel)
   WHERE has_table_privilege(r.papel, format('folha.%I', t.nome), 'SELECT')
      OR has_table_privilege(r.papel, format('folha.%I', t.nome), 'INSERT')
      OR has_table_privilege(r.papel, format('folha.%I', t.nome), 'UPDATE')
      OR has_table_privilege(r.papel, format('folha.%I', t.nome), 'DELETE');
  IF v_inesperado IS NOT NULL THEN
    RAISE EXCEPTION '0029: tabela do Portal alcançável diretamente: %', v_inesperado USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_catalog.pg_proc p
              WHERE p.pronamespace IN ('portal_api'::regnamespace, 'folha'::regnamespace)
                AND p.proname IN ('listar_meus_documentos', 'abrir_meu_documento', 'meu_aviso_privacidade', 'aceitar_aviso_privacidade')
                AND (has_function_privilege('anon', p.oid, 'EXECUTE')
                     OR has_function_privilege('dnex_gestao_api', p.oid, 'EXECUTE')
                     OR has_function_privilege('service_role', p.oid, 'EXECUTE')
                     OR has_function_privilege('dnex_gestao_folha_worker', p.oid, 'EXECUTE'))) THEN
    RAISE EXCEPTION '0029: função do empregado executável por papel que não é authenticated'
      USING ERRCODE = 'insufficient_privilege';
  END IF;
END
$$;

COMMIT;
