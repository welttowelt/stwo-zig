"""Proof-admission policy for the pinned Stark-V trace corpus."""

from __future__ import annotations

SUPPORTED = "supported"
FAIL_CLOSED = "fail_closed_known_limitation"
DIAGNOSTIC_FAIL_CLOSED = "diagnostic_balanced_family_fail_closed"
SIGNED_MULH_LIMITATION = "stark-v-signed-mulh"

_REQUIRED_LIMITATIONS = {
    "mul_div": {
        "status": FAIL_CLOSED,
        "known_limitation": SIGNED_MULH_LIMITATION,
    },
    "mulhu_only": {
        "status": DIAGNOSTIC_FAIL_CLOSED,
        "known_limitation": SIGNED_MULH_LIMITATION,
    },
}


def for_programs(program_names: object) -> dict[str, dict[str, str]]:
    """Return the complete policy, refusing a corpus without both probes."""
    names = set(program_names)
    missing = set(_REQUIRED_LIMITATIONS) - names
    if missing:
        raise ValueError(f"trace corpus lacks required limitation probes: {sorted(missing)}")
    result = {name: {"status": SUPPORTED} for name in names}
    result.update({name: dict(value) for name, value in _REQUIRED_LIMITATIONS.items()})
    return result


def errors(
    vectors: object,
    expected: dict[str, dict[str, str]],
) -> list[str]:
    """Validate every vector against the complete, closed admission policy."""
    if not isinstance(vectors, list):
        return ["trace-vector manifest vectors must be an array"]
    result: list[str] = []
    observed: dict[str, dict[str, str]] = {}
    allowed = {SUPPORTED, FAIL_CLOSED, DIAGNOSTIC_FAIL_CLOSED}
    for vector in vectors:
        if not isinstance(vector, dict):
            result.append("trace-vector manifest contains a non-object vector")
            continue
        name = vector.get("name")
        admission = vector.get("proof_admission")
        if not isinstance(name, str) or not isinstance(admission, dict):
            result.append(f"{name}: proof admission must be an object")
            continue
        status = admission.get("status")
        if status not in allowed:
            result.append(f"{name}: unknown proof-admission status {status!r}")
        observed[name] = admission
        if admission != expected.get(name):
            result.append(
                f"{name}: proof admission {admission!r} != expected {expected.get(name)!r}"
            )
    if observed != expected:
        result.append("trace-vector proof-admission manifest is incomplete or non-canonical")
    return result
