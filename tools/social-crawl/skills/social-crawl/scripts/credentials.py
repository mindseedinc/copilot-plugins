"""Resolve the SocialCrawl API key without ever printing it.

Sources, first usable one wins:
  1. $SOCIALCRAWL_API_KEY
  2. <plugin root>/.env
  3. ~/.config/socialcrawl/api_key
"""
from __future__ import annotations

import os
import re
from pathlib import Path
from typing import Dict, List, Mapping, Optional

KEY_NAME = "SOCIALCRAWL_API_KEY"
PLUGIN_ROOT = Path(__file__).resolve().parents[3]

_PLACEHOLDER = re.compile(
    r"^(|sc_?|your_?api_?key|sc_your_key(_here)?|sc_\.\.\.|<.*>|\$\{?\w+\}?)$", re.IGNORECASE
)
_ENV_LINE = re.compile(r"^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$")


def is_usable_key(value: Optional[str]) -> bool:
    if not isinstance(value, str):
        return False
    value = value.strip()
    return not _PLACEHOLDER.match(value) and not re.search(r"\s", value)


def parse_env(text: str) -> Dict[str, str]:
    values: Dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = _ENV_LINE.match(line)
        if not match:
            continue
        value = match.group(2).strip()
        if len(value) >= 2 and value[0] in "\"'" and value.endswith(value[0]):
            value = value[1:-1]
        else:
            value = re.sub(r"\s+#.*$", "", value)
        values[match.group(1)] = value
    return values


def _read_optional(path: Path) -> Optional[str]:
    try:
        return path.read_text(encoding="utf-8")
    except (FileNotFoundError, NotADirectoryError):
        return None
    except OSError as error:
        raise RuntimeError(f"Cannot read credential file {path}: {error.strerror or error}") from None


def credential_sources(plugin_root: Optional[Path] = None, home: Optional[Path] = None) -> List[Dict[str, object]]:
    plugin_root = Path(plugin_root) if plugin_root else PLUGIN_ROOT
    home = Path(home) if home else Path.home()
    key_file = home / ".config" / "socialcrawl" / "api_key"
    return [
        {"kind": "env", "label": f"${KEY_NAME}"},
        {"kind": "env-file", "label": str(plugin_root / ".env"), "path": plugin_root / ".env"},
        {"kind": "key-file", "label": str(key_file), "path": key_file},
    ]


def resolve_api_key(
    env: Optional[Mapping[str, str]] = None,
    plugin_root: Optional[Path] = None,
    home: Optional[Path] = None,
) -> Dict[str, object]:
    """Return {"key", "source"} for the first usable key, or {"key": None, "checked": [...]}."""
    env = os.environ if env is None else env
    sources = credential_sources(plugin_root, home)
    for source in sources:
        if source["kind"] == "env":
            value = env.get(KEY_NAME)
        else:
            text = _read_optional(source["path"])  # type: ignore[arg-type]
            if text is None:
                continue
            value = parse_env(text).get(KEY_NAME) if source["kind"] == "env-file" else text.strip()
        if is_usable_key(value):
            return {"key": value.strip(), "source": source["label"]}  # type: ignore[union-attr]
    return {"key": None, "source": None, "checked": [s["label"] for s in sources]}
