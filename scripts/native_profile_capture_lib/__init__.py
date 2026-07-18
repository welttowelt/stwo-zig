"""Public contract for the bounded Native CPU/Metal profiler capture."""

from .controller import run_capture
from .model import (
    COUNTER_WORKLOADS,
    PROFILE_WORKLOADS,
    CaptureError,
    CaptureSettings,
)

__all__ = [
    "COUNTER_WORKLOADS",
    "PROFILE_WORKLOADS",
    "CaptureError",
    "CaptureSettings",
    "run_capture",
]
