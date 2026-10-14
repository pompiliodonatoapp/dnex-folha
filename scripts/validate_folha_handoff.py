#!/usr/bin/env python3
"""Validate the DNEX Folha handoff contract (gestao.folha-handoff.v1).
Static, fail-closed. Does not emit real handoff events.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REQUIRED_FILES = [
    "contracts/modules/gestao.folha-handoff.v1.schema.json",
    "contracts/modules/examples/gestao.folha-handoff.v1.example.json",
    "scripts/validate_folha_handoff.py",
]
KEY_PATTERN = re.compile(r"^[a-z0-9-]{1,64}$")
COMPETENCE_PATTERN = re.compile(r"^[0-9]{4}-[0-9]{2}$")
AMOUNT_PATTERN = re.compile(r"^[0-9]+$")


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


def main() -> None:
    for path in REQUIRED_FILES:
        read(path)

    schema = read_json("contracts/modules/gestao.folha-handoff.v1.schema.json")
    example = read_json("contracts/modules/examples/gestao.folha-handoff.v1.example.json")

    if not schema.get("$id", "").endswith("gestao.folha-handoff.v1.schema.json"):
        fail("schema do folha handoff: $id incorreto")
    if example.get("contractVersion") != "gestao.folha-handoff.v1":
        fail("exemplo do folha handoff: contractVersion incorreto")

    required = set(schema.get("required", []))
    properties = set(schema.get("properties", {}).keys())
    missing = required - properties
    if missing:
        fail(f"schema do folha handoff: required sem propriedade correspondente: {missing}")

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

    print("OK: contrato de folha handoff valido (partida dobrada, vinculos e versao coerentes), 0 aplicacao real")


if __name__ == "__main__":
    main()