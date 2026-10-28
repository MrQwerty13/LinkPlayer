"""JSON-dictionary based localisation (RU/EN). No QTranslator is used."""

from __future__ import annotations

import json
import os
from pathlib import Path

from PySide6.QtCore import QLocale

_LANGUAGES = ("ru", "en")
_DEFAULT_LANGUAGE = "en"

_catalogs: dict[str, dict[str, str]] = {}
_current: str = ""


def locales_dir() -> Path:
    """Directory with the JSON catalogues (works in frozen builds too)."""
    from linkplayer.resources_util import resource_path

    return Path(resource_path(os.path.join("locales")))


def _load_language(lang: str) -> dict[str, str]:
    if lang in _catalogs:
        return _catalogs[lang]
    from linkplayer.resources_util import resource_path

    path = Path(resource_path(os.path.join("locales", f"{lang}.json")))
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError):
        data = {}
    flat: dict[str, str] = {}

    def walk(prefix: str, obj: object) -> None:
        if isinstance(obj, dict):
            for k, v in obj.items():
                walk(f"{prefix}{k}.", v)
        else:
            flat[prefix.rstrip(".")] = str(obj)

    walk("", data)
    _catalogs[lang] = flat
    return flat


def system_language() -> str:
    """Map the Qt system locale onto a supported catalogue code."""
    lang = QLocale.system().name().split("_")[0].split("-")[0].lower()
    return lang if lang in _LANGUAGES else _DEFAULT_LANGUAGE


def set_language(lang: str | None) -> None:
    """Select the active language. ``None``/'' means 'follow the system'."""
    global _current
    if not lang or lang not in _LANGUAGES:
        lang = system_language()
    _load_language(lang)
    _current = lang


def current_language() -> str:
    if not _current:
        set_language(None)
    return _current


def available_languages() -> tuple[str, ...]:
    return _LANGUAGES


def t(key: str, **kwargs: object) -> str:
    """Translate ``key`` ('dot.separated.path'); fall back to the key itself."""
    lang = current_language()
    text = _load_language(lang).get(key)
    if text is None:
        # Fall back to the default language before giving up.
        text = _load_language(_DEFAULT_LANGUAGE).get(key)
    if text is None:
        return key
    if kwargs:
        try:
            return text.format(**kwargs)
        except (KeyError, IndexError, ValueError):
            return text
    return text
