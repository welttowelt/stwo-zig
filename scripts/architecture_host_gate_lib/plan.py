"""Strict loading and expansion of the versioned architecture command plan."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from scripts.build_architecture_receipt_lib.model import EVIDENCE_NAMES, ReceiptError


PLAN_FIELDS = {"schema", "optimize", "evidence_phases", "roles"}
ROLE_FIELDS = {"commands", "products"}
COMMAND_FIELDS = {"id", "phase", "argv", "required_inputs", "generated_outputs"}
PRODUCT_FIELDS = {
    "product_id", "phase", "identity_path", "identity_command", "artifact_path",
}
def _unique(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ReceiptError(f"architecture plan contains duplicate key {key}")
        result[key] = value
    return result


def _object(value: object, fields: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != fields:
        raise ReceiptError(f"{label} fields drifted")
    return value


def _strings(value: object, label: str, *, allow_empty: bool = False) -> list[str]:
    if not isinstance(value, list) or (not allow_empty and not value):
        raise ReceiptError(f"{label} must be a string array")
    if not all(isinstance(item, str) and item for item in value):
        raise ReceiptError(f"{label} contains an invalid string")
    return value


def load(path: Path, protocol: dict[str, Any]) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=_unique)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ReceiptError(f"cannot read architecture plan: {error}") from error
    plan = _object(value, PLAN_FIELDS, "architecture plan")
    if plan["schema"] != "build-architecture-ci-plan-v1":
        raise ReceiptError("architecture plan schema drifted")
    if plan["optimize"] != "ReleaseFast":
        raise ReceiptError("architecture plan must enforce ReleaseFast")
    evidence = _object(
        plan["evidence_phases"], set(EVIDENCE_NAMES), "architecture evidence map",
    )
    valid_phases = set(protocol["checkpoint_order"][:-1])
    for name, phases in evidence.items():
        items = _strings(phases, f"evidence_phases.{name}")
        if len(items) != len(set(items)) or not set(items).issubset(valid_phases):
            raise ReceiptError(f"evidence_phases.{name} is invalid")
    roles = _object(plan["roles"], set(protocol["host_roles"]), "architecture roles")
    for role, raw in roles.items():
        _validate_role(role, _object(raw, ROLE_FIELDS, f"roles.{role}"), protocol)
    return plan


def _validate_role(role: str, value: dict[str, Any], protocol: dict[str, Any]) -> None:
    allocated = protocol["host_roles"][role]["allocated_checkpoints"]
    order = {phase: index for index, phase in enumerate(protocol["checkpoint_order"][:-1])}
    commands = value["commands"]
    if not isinstance(commands, list) or not commands:
        raise ReceiptError(f"roles.{role}.commands must be nonempty")
    ids: list[str] = []
    phases: list[str] = []
    for index, raw in enumerate(commands):
        command = _object(raw, COMMAND_FIELDS, f"roles.{role}.commands[{index}]")
        command_id = command["id"]
        phase = command["phase"]
        if not isinstance(command_id, str) or not command_id or phase not in allocated:
            raise ReceiptError(f"roles.{role}.commands[{index}] identity is invalid")
        _strings(command["argv"], f"roles.{role}.commands[{index}].argv")
        _strings(
            command["required_inputs"],
            f"roles.{role}.commands[{index}].required_inputs",
            allow_empty=True,
        )
        _strings(
            command["generated_outputs"],
            f"roles.{role}.commands[{index}].generated_outputs",
            allow_empty=True,
        )
        ids.append(command_id)
        phases.append(phase)
    if len(ids) != len(set(ids)):
        raise ReceiptError(f"roles.{role}.commands contain duplicate IDs")
    if phases != sorted(phases, key=order.__getitem__) or set(phases) != set(allocated):
        raise ReceiptError(f"roles.{role}.commands do not cover allocated phases in order")
    products = value["products"]
    if not isinstance(products, list):
        raise ReceiptError(f"roles.{role}.products must be an array")
    product_ids = []
    for index, raw in enumerate(products):
        product = _object(raw, PRODUCT_FIELDS, f"roles.{role}.products[{index}]")
        product_id = product["product_id"]
        if product_id not in protocol["host_roles"][role]["required_products"]:
            raise ReceiptError(f"roles.{role}.products[{index}] is not allocated")
        if product["phase"] not in allocated:
            raise ReceiptError(f"roles.{role}.products[{index}] phase is not allocated")
        sources = (product["identity_path"], product["identity_command"])
        if sum(item is not None for item in sources) != 1:
            raise ReceiptError(f"roles.{role}.products[{index}] needs one identity source")
        for field in ("identity_path", "identity_command", "artifact_path"):
            if product[field] is not None and not isinstance(product[field], str):
                raise ReceiptError(f"roles.{role}.products[{index}].{field} is invalid")
        if product["identity_command"] is not None and product["identity_command"] not in ids:
            raise ReceiptError(f"roles.{role}.products[{index}] names an unknown command")
        product_ids.append(product_id)
    if product_ids != sorted(product_ids):
        raise ReceiptError(f"roles.{role}.products are not canonically ordered")
    if product_ids != sorted(protocol["host_roles"][role]["required_products"]):
        raise ReceiptError(f"roles.{role}.products do not cover required products")


def expand(value: str, replacements: dict[str, str]) -> str:
    result = value
    for name, replacement in replacements.items():
        result = result.replace("{" + name + "}", replacement)
    if "{" in result or "}" in result:
        raise ReceiptError(f"unknown architecture plan placeholder in {value}")
    return result
