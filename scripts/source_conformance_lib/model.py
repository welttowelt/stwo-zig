"""Shared finding representation for source-conformance scanners."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True, order=True)
class Finding:
    key: str
    message: str
    line_count: int | None = None
