#!/usr/bin/env python3
"""Enforce focused library policies through the authoritative closure engine."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from scripts.product_closure.graph import ClosureError, SourceGraph, inspect_sources
from scripts.product_closure.model import Manifest, NamedImport


NAMED_IMPORTS = (
    NamedImport("stwo_core", "src/core/mod.zig"),
    NamedImport("stwo_backend_contracts", "src/backend/mod.zig"),
    NamedImport("stwo_prover_impl", "src/prover/mod.zig"),
    NamedImport("stwo_prover", "src/products/prover/root.zig"),
)
PRODUCTS = {
    "core": {
        "entries": ("src/core/mod.zig", "src/products/core/surface.zig"),
        "allowed": ("src/core", "src/products/core"),
        "build_owner": "build_support/products/core.zig",
    },
    "backend-contracts": {
        "entries": ("src/backend/mod.zig",),
        "allowed": ("src/backend", "src/core"),
        "build_owner": None,
    },
    "prover": {
        "entries": (
            "src/products/prover/root.zig",
            "src/products/prover/surface.zig",
        ),
        "allowed": (
            "src/backend",
            "src/core",
            "src/products/prover",
            "src/prover",
        ),
        "build_owner": "build_support/products/prover.zig",
    },
}


def inspect(product: str) -> SourceGraph:
    policy = PRODUCTS[product]
    return inspect_sources(
        ROOT,
        Manifest(
            product=f"stwo-{product}",
            entry_roots=policy["entries"],
            named_imports=NAMED_IMPORTS,
            generated_imports=frozenset({"builtin", "std"}),
            allowed_files=frozenset(),
            allowed_prefixes=policy["allowed"],
        ),
    )


def check(product: str) -> tuple[list[str], SourceGraph | None]:
    try:
        graph = inspect(product)
    except ClosureError as error:
        return str(error).splitlines(), None

    failures: list[str] = []
    for source in graph.sources:
        text = source.read_text(encoding="utf-8")
        for marker in ("linkFramework", "linkSystemLibrary"):
            if marker in text:
                failures.append(
                    f"{product}: platform linkage marker {marker!r} in "
                    f"{source.relative_to(ROOT)}"
                )

    build_owner = PRODUCTS[product]["build_owner"]
    if build_owner is not None:
        owner_text = (ROOT / build_owner).read_text(encoding="utf-8")
        for marker in (
            "addInstallArtifact",
            "getInstallStep",
            "linkFramework",
            "linkSystemLibrary",
        ):
            if marker in owner_text:
                failures.append(
                    f"{product}: focused library owner contains forbidden "
                    f"install/link marker {marker!r}"
                )
    return failures, graph


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--product", choices=(*PRODUCTS, "all"), default="all")
    args = parser.parse_args()
    selected = PRODUCTS if args.product == "all" else (args.product,)
    results = {product: check(product) for product in selected}
    failures = [failure for failures, _ in results.values() for failure in failures]
    if failures:
        print("\n".join(failures))
        return 1
    for product, (_, graph) in results.items():
        assert graph is not None
        print(
            f"{product} library purity: PASS "
            f"({len(graph.sources)} Zig sources, {graph.source_digest()})"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
