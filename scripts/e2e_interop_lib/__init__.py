"""Schema-aware helpers for the Native Rust/Zig interchange gate."""

from .evidence import (
    ARCHIVE_PROTOCOL,
    archive_receipt,
    collect_provenance,
    file_sha256,
    register_artifact,
)
from .mutations import (
    ACTIVE_MUTATIONS,
    NOT_APPLICABLE_COVERAGE,
    MutationSpec,
    coverage_manifest,
    mutate_artifact,
)

__all__ = [
    "ACTIVE_MUTATIONS",
    "ARCHIVE_PROTOCOL",
    "NOT_APPLICABLE_COVERAGE",
    "MutationSpec",
    "archive_receipt",
    "collect_provenance",
    "coverage_manifest",
    "file_sha256",
    "mutate_artifact",
    "register_artifact",
]
