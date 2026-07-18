"""User configuration: tokens and API keys under XDG config, chmod 600."""

from __future__ import annotations

import json
import os
from pathlib import Path


def config_dir() -> Path:
    base = os.environ.get("XDG_CONFIG_HOME")
    root = Path(base) if base else Path.home() / ".config"
    return root / "stwo-perf"


def config_path() -> Path:
    return config_dir() / "config.json"


def load() -> dict:
    path = config_path()
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError:
        return {}


def save(data: dict) -> None:
    config_dir().mkdir(parents=True, exist_ok=True)
    path = config_path()
    path.write_text(json.dumps(data, indent=2) + "\n")
    os.chmod(path, 0o600)


def get(key: str, default=None):
    return load().get(key, default)


def set_value(key: str, value) -> None:
    data = load()
    data[key] = value
    save(data)


def github_token() -> str | None:
    return os.environ.get("STWO_PERF_GITHUB_TOKEN") or get("github_token")


def api_key() -> str | None:
    return os.environ.get("STWO_PERF_API_KEY") or get("api_key")


def api_url() -> str:
    return os.environ.get("STWO_PERF_API_URL") or get("api_url", "http://localhost:8787")
