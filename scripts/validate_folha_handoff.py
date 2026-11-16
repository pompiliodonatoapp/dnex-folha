#!/usr/bin/env python3
"""Valida os contratos de handoff contábil da DNEX Folha.

- gestao.folha-handoff.v2 (vigente): esquema, todos os exemplos v2 e as regras que o esquema
  não expressa (totais = soma das linhas, débito = crédito, um lado por linha, entryKey único,
  resumo do conteúdo, estorno com referência, pagamento com comprovante).
- gestao.folha-handoff.v1 (superado pela migration 0030; mantido para referência): esquema e
  exemplo, como antes.

Estático e falha fechada. Não emite evento real. Só biblioteca padrão: o esquema é conferido
por um interpretador mínimo de JSON Schema (o subconjunto usado pelos dois arquivos); palavra
de esquema desconhecida é erro, para o esquema não ganhar regra que o validador ignora.
"""
from __future__ import annotations

import copy
import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTRATOS = ROOT / "contracts" / "modules"
EXEMPLOS = CONTRATOS / "examples"

V1_SCHEMA = "contracts/modules/gestao.folha-handoff.v1.schema.json"
V1_EXEMPLO = "contracts/modules/examples/gestao.folha-handoff.v1.example.json"
V2_SCHEMA = "contracts/modules/gestao.folha-handoff.v2.schema.json"
V2_EXEMPLOS_GLOB = "gestao.folha-handoff.v2.*.example.json"
# Eventos que os exemplos v2 precisam cobrir (um de cada família do contrato).
V2_EVENTOS_OBRIGATORIOS = {"folha_mensal", "provisao_13o", "recolhimento_previdenciario", "estorno"}

KEY_PATTERN = re.compile(r"^[a-z0-9-]{1,64}$")
COMPETENCE_PATTERN = re.compile(r"^[0-9]{4}-[0-9]{2}$")
AMOUNT_PATTERN = re.compile(r"^[0-9]+$")

PAGAMENTOS = {"pagamento_liquido", "recolhimento_previdenciario", "recolhimento_irrf", "fgts_deposito", "repasse_terceiros"}
PROVISOES = {"provisao_ferias", "provisao_13o"}


class Invalido(Exception):
    """O documento não atende ao contrato."""


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def read(path: str) -> str:
    full = ROOT / path
    if not full.is_file():
        fail(f"arquivo obrigatorio ausente: {path}")
    return full.read_text(encoding="utf-8")


def read_json(path: str) -> dict:
    try:
        return json.loads(read(path))
    except json.JSONDecodeError as exc:
        fail(f"JSON invalido em {path}: {exc}")
    raise AssertionError("inalcancavel")


# ---------------------------------------------------------------------------
# Interpretador mínimo de JSON Schema (subconjunto usado pelos contratos da Folha)
# ---------------------------------------------------------------------------
PALAVRAS_SEM_EFEITO = {"$schema", "$id", "title", "description", "format", "deprecated", "x-superseded-by"}
PALAVRAS_CONHECIDAS = PALAVRAS_SEM_EFEITO | {
    "type", "const", "enum", "pattern", "required", "additionalProperties", "properties", "items",
    "minItems", "minimum", "maxLength", "oneOf", "allOf", "if", "then", "else",
}


def _tipo_ok(valor, tipo: str) -> bool:
    if tipo == "object":
        return isinstance(valor, dict)
    if tipo == "array":
        return isinstance(valor, list)
    if tipo == "string":
        return isinstance(valor, str)
    if tipo == "integer":
        return isinstance(valor, int) and not isinstance(valor, bool)
    if tipo == "null":
        return valor is None
    if tipo == "boolean":
        return isinstance(valor, bool)
    raise Invalido(f"tipo de esquema nao suportado pelo validador: {tipo}")


def conferir_esquema(valor, esquema: dict, caminho: str = "$") -> None:
    desconhecidas = set(esquema) - PALAVRAS_CONHECIDAS
    if desconhecidas:
        raise Invalido(f"{caminho}: palavra de esquema que o validador nao interpreta: {sorted(desconhecidas)}")

    if "type" in esquema:
        tipos = esquema["type"] if isinstance(esquema["type"], list) else [esquema["type"]]
        if not any(_tipo_ok(valor, t) for t in tipos):
            raise Invalido(f"{caminho}: tipo invalido (esperado {tipos})")
    if "const" in esquema and valor != esquema["const"]:
        raise Invalido(f"{caminho}: valor diferente de {esquema['const']!r}")
    if "enum" in esquema and valor not in esquema["enum"]:
        raise Invalido(f"{caminho}: valor fora da lista permitida: {valor!r}")
    if isinstance(valor, str):
        if "pattern" in esquema and not re.search(esquema["pattern"], valor):
            raise Invalido(f"{caminho}: fora do padrao {esquema['pattern']}")
        if "maxLength" in esquema and len(valor) > esquema["maxLength"]:
            raise Invalido(f"{caminho}: excede {esquema['maxLength']} caracteres")
    if isinstance(valor, int) and not isinstance(valor, bool):
        if "minimum" in esquema and valor < esquema["minimum"]:
            raise Invalido(f"{caminho}: menor que {esquema['minimum']}")
    if isinstance(valor, dict):
        for campo in esquema.get("required", []):
            if campo not in valor:
                raise Invalido(f"{caminho}: campo obrigatorio ausente: {campo}")
        propriedades = esquema.get("properties", {})
        if esquema.get("additionalProperties") is False:
            extras = set(valor) - set(propriedades)
            if extras:
                raise Invalido(f"{caminho}: campo nao previsto: {sorted(extras)}")
        for campo, sub in propriedades.items():
            if campo in valor:
                conferir_esquema(valor[campo], sub, f"{caminho}.{campo}")
    if isinstance(valor, list):
        if "minItems" in esquema and len(valor) < esquema["minItems"]:
            raise Invalido(f"{caminho}: menos de {esquema['minItems']} itens")
        if "items" in esquema:
            for i, item in enumerate(valor):
                conferir_esquema(item, esquema["items"], f"{caminho}[{i}]")
    if "oneOf" in esquema:
        acertos = 0
        for sub in esquema["oneOf"]:
            try:
                conferir_esquema(valor, sub, caminho)
                acertos += 1
            except Invalido:
                pass
        if acertos != 1:
            raise Invalido(f"{caminho}: deveria atender a exatamente uma alternativa (atende a {acertos})")
    for sub in esquema.get("allOf", []):
        conferir_esquema(valor, sub, caminho)
    if "if" in esquema:
        try:
            conferir_esquema(valor, esquema["if"], caminho)
            condicao = True
        except Invalido:
            condicao = False
        ramo = esquema.get("then") if condicao else esquema.get("else")
        if ramo is not None:
            conferir_esquema(valor, ramo, caminho)


# ---------------------------------------------------------------------------
# v2
# ---------------------------------------------------------------------------
def resumo_v2(doc: dict) -> str:
    """Resumo do conteúdo contábil, como folha.contabil_payload_hash (migration 0030)."""
    linhas = sorted(doc["entries"], key=lambda e: e["entryKey"].encode("utf-8"))
    texto = "|".join([
        "v2",
        doc["eventType"],
        doc["competence"],
        doc["entryDate"],
        doc["employerId"],
        doc["payrollRunId"] or "",
        doc["dimensionType"] or "",
        doc["reverses"] or "",
        (doc["evidence"] or {}).get("reference") or "",
        ";".join(
            ":".join([e["entryKey"], e["accountKey"], e["dimensionKey"] or "", e["debitMinor"], e["creditMinor"]])
            for e in linhas
        ),
    ])
    return hashlib.sha256(texto.encode("utf-8")).hexdigest()


def conferir_v2(doc: dict, esquema: dict) -> None:
    """Levanta Invalido se o documento não atender ao contrato v2."""
    conferir_esquema(doc, esquema)

    debito = credito = 0
    chaves = set()
    for i, linha in enumerate(doc["entries"]):
        d, c = int(linha["debitMinor"]), int(linha["creditMinor"])
        if (d > 0) == (c > 0):
            raise Invalido(f"entries[{i}]: a linha deve ter exatamente um lado com valor")
        if linha["entryKey"] in chaves:
            raise Invalido(f"entries[{i}]: entryKey repetido no lote")
        chaves.add(linha["entryKey"])
        debito += d
        credito += c
    if str(debito) != doc["totals"]["debitMinor"] or str(credito) != doc["totals"]["creditMinor"]:
        raise Invalido(f"totals nao e a soma das linhas (linhas: D {debito} / C {credito})")
    if debito != credito:
        raise Invalido(f"lote desbalanceado (D {debito} / C {credito})")
    if doc["payloadHash"] != resumo_v2(doc):
        raise Invalido("payloadHash nao confere com o conteudo")

    evento = doc["eventType"]
    if (evento == "estorno") != (doc["reverses"] is not None):
        raise Invalido("reverses e obrigatorio no estorno e nulo nos demais eventos")
    if (evento in PAGAMENTOS) != (doc["evidence"] is not None):
        raise Invalido("evidence e obrigatorio nos eventos de pagamento e nulo nos demais")
    if evento in PAGAMENTOS and doc["entryDate"] != doc["evidence"]["date"]:
        raise Invalido("no pagamento, entryDate e a data do comprovante")
    if evento in PROVISOES and doc["payrollRunId"] is not None:
        raise Invalido("lote de provisao nao tem folha")
    if evento not in PROVISOES and evento != "estorno" and doc["payrollRunId"] is None:
        raise Invalido("lote de folha ou de pagamento exige a folha")
    if doc["dimensionType"] == "nenhuma" and any(l["dimensionKey"] is not None for l in doc["entries"]):
        raise Invalido("linha com dimensao em lote sem dimensao configurada")
    if not doc["entryDate"].startswith(doc["competence"]) and evento not in PAGAMENTOS | {"estorno", "adiantamento_salarial"}:
        raise Invalido("na apropriacao e na provisao, entryDate e do mes da competencia")


def _mutacoes_v2(base: dict):
    """Adulterações de um exemplo válido: cada uma tem de ser recusada."""
    def muta(nome, fn):
        doc = copy.deepcopy(base)
        fn(doc)
        return nome, doc

    def desbalancear(d):
        d["entries"][0]["debitMinor" if int(d["entries"][0]["debitMinor"]) > 0 else "creditMinor"] = "1"

    def dois_lados(d):
        d["entries"][0]["debitMinor"] = "5"
        d["entries"][0]["creditMinor"] = "5"

    def total_paralelo(d):
        d["totals"]["debitMinor"] = str(int(d["totals"]["debitMinor"]) + 1)
        d["totals"]["creditMinor"] = str(int(d["totals"]["creditMinor"]) + 1)

    def valor_em_reais(d):
        d["entries"][0]["debitMinor"] = "10.50"

    def campo_extra(d):
        d["cpf"] = "00000000000"

    def conta_trocada(d):
        d["entries"][0]["accountKey"] = d["entries"][0]["accountKey"] + "X"

    def estorno_sem_referencia(d):
        d["eventType"] = "estorno"

    def pagamento_sem_comprovante(d):
        d["eventType"] = "pagamento_liquido"

    def versao_zero(d):
        d["version"] = 0

    def linha_zerada(d):
        d["entries"][0]["debitMinor"] = "0"
        d["entries"][0]["creditMinor"] = "0"

    return [
        muta("lote desbalanceado", desbalancear),
        muta("linha com os dois lados", dois_lados),
        muta("totais que nao sao a soma das linhas", total_paralelo),
        muta("valor fora do formato de centavos", valor_em_reais),
        muta("campo nao previsto (dado pessoal)", campo_extra),
        muta("conteudo alterado sem refazer o resumo", conta_trocada),
        muta("estorno sem referencia ao lote estornado", estorno_sem_referencia),
        muta("pagamento sem comprovante", pagamento_sem_comprovante),
        muta("versao zero", versao_zero),
        muta("linha zerada", linha_zerada),
    ]


def validar_v2() -> int:
    esquema = read_json(V2_SCHEMA)
    if not esquema.get("$id", "").endswith("gestao.folha-handoff.v2.schema.json"):
        fail("schema v2 do folha handoff: $id incorreto")
    faltando = set(esquema.get("required", [])) - set(esquema.get("properties", {}))
    if faltando:
        fail(f"schema v2 do folha handoff: required sem propriedade correspondente: {sorted(faltando)}")

    arquivos = sorted(EXEMPLOS.glob(V2_EXEMPLOS_GLOB))
    if not arquivos:
        fail("nenhum exemplo v2 do folha handoff encontrado")
    eventos = set()
    base = None
    for arquivo in arquivos:
        rel = arquivo.relative_to(ROOT).as_posix()
        doc = read_json(rel)
        try:
            conferir_v2(doc, esquema)
        except Invalido as exc:
            fail(f"exemplo v2 {rel}: {exc}")
        eventos.add(doc["eventType"])
        if doc["eventType"] == "folha_mensal" and base is None:
            base = doc
    ausentes = V2_EVENTOS_OBRIGATORIOS - eventos
    if ausentes:
        fail(f"exemplos v2 do folha handoff: faltam exemplos dos eventos {sorted(ausentes)}")

    # O validador não pode ser vazio: cada adulteração de um exemplo válido tem de ser recusada.
    for nome, adulterado in _mutacoes_v2(base):
        try:
            conferir_v2(adulterado, esquema)
        except Invalido:
            continue
        fail(f"validador v2 aceitou documento adulterado: {nome}")
    return len(arquivos)


# ---------------------------------------------------------------------------
# v1 (superado)
# ---------------------------------------------------------------------------
def validar_v1() -> None:
    schema = read_json(V1_SCHEMA)
    example = read_json(V1_EXEMPLO)

    if not schema.get("$id", "").endswith("gestao.folha-handoff.v1.schema.json"):
        fail("schema do folha handoff: $id incorreto")
    if schema.get("deprecated") is not True or schema.get("x-superseded-by") != "gestao.folha-handoff.v2":
        fail("schema v1 do folha handoff: deve estar marcado como superado pelo v2 (deprecated e x-superseded-by)")
    if example.get("contractVersion") != "gestao.folha-handoff.v1":
        fail("exemplo do folha handoff: contractVersion incorreto")

    required = set(schema.get("required", []))
    properties = set(schema.get("properties", {}).keys())
    missing = required - properties
    if missing:
        fail(f"schema do folha handoff: required sem propriedade correspondente: {missing}")
    try:
        conferir_esquema(example, schema)
    except Invalido as exc:
        fail(f"exemplo v1 do folha handoff nao atende ao esquema: {exc}")

    for field in ("handoffKey", "accountId", "payrollRunId", "competence", "emittedAt", "entries"):
        if field not in example:
            fail(f"exemplo do folha handoff: campo obrigatorio ausente {field}")

    if not KEY_PATTERN.match(example.get("handoffKey", "")):
        fail("exemplo do folha handoff: handoffKey fora do padrao")
    if not KEY_PATTERN.match(example.get("accountId", "")):
        fail("exemplo do folha handoff: accountId fora do padrao")
    if not KEY_PATTERN.match(example.get("payrollRunId", "")):
        fail("exemplo do folha handoff: payrollRunId fora do padrao")
    if not COMPETENCE_PATTERN.match(example.get("competence", "")):
        fail("exemplo do folha handoff: competence fora do padrao (YYYY-MM)")

    entries = example.get("entries", [])
    if not entries:
        fail("exemplo do folha handoff: entries vazio")

    total_debit = 0
    total_credit = 0
    for i, entry in enumerate(entries):
        if not KEY_PATTERN.match(entry.get("entryKey", "")):
            fail(f"exemplo do folha handoff: entries[{i}].entryKey fora do padrao")
        if not KEY_PATTERN.match(entry.get("accountKey", "")):
            fail(f"exemplo do folha handoff: entries[{i}].accountKey fora do padrao")
        debit = entry.get("debitMinor", "")
        credit = entry.get("creditMinor", "")
        if not AMOUNT_PATTERN.match(debit):
            fail(f"exemplo do folha handoff: entries[{i}].debitMinor invalido")
        if not AMOUNT_PATTERN.match(credit):
            fail(f"exemplo do folha handoff: entries[{i}].creditMinor invalido")
        total_debit += int(debit)
        total_credit += int(credit)
        desc = entry.get("description", "")
        if len(desc) > 500:
            fail(f"exemplo do folha handoff: entries[{i}].description excede 500 caracteres")

    if total_debit != total_credit:
        fail(f"exemplo do folha handoff: partida dobrada desbalanceada (debit={total_debit}, credit={total_credit})")

    source = example.get("source", {})
    if source.get("repository") != "pompiliodonatoapp/dnex-folha":
        fail("exemplo do folha handoff: source.repository incorreto")


def main() -> None:
    for path in (V1_SCHEMA, V1_EXEMPLO, V2_SCHEMA, "scripts/validate_folha_handoff.py"):
        read(path)
    exemplos_v2 = validar_v2()
    validar_v1()
    print(
        "OK: contratos de folha handoff validos: v2 (vigente; esquema, "
        f"{exemplos_v2} exemplos, partida fechada, resumo do conteudo e adulteracoes recusadas) "
        "e v1 (superado; esquema e exemplo), 0 aplicacao real"
    )


if __name__ == "__main__":
    main()
