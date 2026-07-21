"""Mechanical autoresearch board-activation policy."""

from .contract import ActivationError, activation_errors, validate_settings_receipt
from .github import build_settings_receipt, settings_payload

__all__ = (
    "ActivationError",
    "activation_errors",
    "build_settings_receipt",
    "settings_payload",
    "validate_settings_receipt",
)
