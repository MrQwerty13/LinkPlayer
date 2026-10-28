"""QSettings wrapper for LinkPlayer preferences.

Settings survive restarts (stored by Qt in
``~/Library/Preferences/com.linkplayer.app.plist`` on macOS).  In tests the
storage location is isolated via ``QSettings.setPath`` + ``tmp_path``.
"""

from __future__ import annotations

import os
from pathlib import Path

from PySide6.QtCore import QSettings, QStandardPaths

from linkplayer import APP_NAME, ORG_NAME
from linkplayer.i18n import system_language

# Allowed values for the cookies-browser selector.
COOKIES_BROWSERS = (None, "safari", "chrome", "edge", "firefox")

_KEY_SAVE_DIR = "save_dir"
_KEY_LANGUAGE = "language"
_KEY_COOKIES_BROWSER = "cookies_browser"
_KEY_WATCH_CLIPBOARD = "watch_clipboard"
_KEY_CLOSE_TO_TRAY = "close_to_tray"


def default_download_dir() -> str:
    """The platform Downloads folder (or home as a last resort)."""
    downloads = QStandardPaths.writableLocation(QStandardPaths.StandardLocation.DownloadLocation)
    if downloads and os.path.isdir(downloads):
        return downloads
    return str(Path.home())


def is_writable_dir(path: str | None) -> bool:
    """True when *path* is an existing directory we can actually write into."""
    if not path:
        return False
    p = Path(path)
    if not p.is_dir():
        return False
    if not os.access(str(p), os.W_OK):
        return False
    # Effective check (root ignores the W_OK bit): try creating a temp file.
    import tempfile

    probe = None
    try:
        fd, probe = tempfile.mkstemp(dir=str(p), prefix=".lp-probe-")
        os.close(fd)
        return True
    except OSError:
        return False
    finally:
        if probe and os.path.exists(probe):
            try:
                os.unlink(probe)
            except OSError:  # pragma: no cover
                pass


# Backwards-compatible alias used by the settings dialog.
is_valid_dir = is_writable_dir


class Settings:
    """Typed facade over QSettings with validation and sane defaults."""

    def __init__(self) -> None:
        self._q = QSettings(ORG_NAME, APP_NAME)

    # ---- raw helpers -----------------------------------------------------
    def _get(self, key: str, default=None):
        return self._q.value(key, default)

    def _set(self, key: str, value) -> None:
        self._q.setValue(key, value)
        self._q.sync()

    # ---- save_dir --------------------------------------------------------
    @property
    def save_dir(self) -> str:
        raw = self._get(_KEY_SAVE_DIR)
        value = str(raw) if raw else ""
        if is_valid_dir(value):
            return value
        # Invalid / unset → fall back to the default and persist it.
        fallback = default_download_dir()
        self._set(_KEY_SAVE_DIR, fallback)
        return fallback

    @save_dir.setter
    def save_dir(self, path: str) -> None:
        if is_valid_dir(path):
            self._set(_KEY_SAVE_DIR, str(path))
        else:
            # Reject invalid folders; keep the current/default value.
            self._set(_KEY_SAVE_DIR, default_download_dir())

    # ---- language --------------------------------------------------------
    @property
    def language(self) -> str:
        raw = self._get(_KEY_LANGUAGE)
        value = str(raw) if raw else ""
        if value in ("ru", "en"):
            return value
        return system_language()

    @language.setter
    def language(self, lang: str) -> None:
        if lang in ("ru", "en", "", None):
            self._set(_KEY_LANGUAGE, lang or "")
        else:
            self._set(_KEY_LANGUAGE, "")

    # ---- cookies browser -------------------------------------------------
    @property
    def cookies_browser(self) -> str | None:
        raw = self._get(_KEY_COOKIES_BROWSER)
        value = str(raw) if raw not in (None, "") else None
        return value if value in COOKIES_BROWSERS else None

    @cookies_browser.setter
    def cookies_browser(self, browser: str | None) -> None:
        if browser in COOKIES_BROWSERS:
            self._set(_KEY_COOKIES_BROWSER, browser if browser else "")
        else:
            self._set(_KEY_COOKIES_BROWSER, "")

    # ---- booleans --------------------------------------------------------
    @staticmethod
    def _to_bool(value, default: bool) -> bool:
        if value is None:
            return default
        if isinstance(value, bool):
            return value
        s = str(value).strip().lower()
        if s in ("true", "1", "yes", "on"):
            return True
        if s in ("false", "0", "no", "off", ""):
            return False
        return default

    @property
    def watch_clipboard(self) -> bool:
        return self._to_bool(self._get(_KEY_WATCH_CLIPBOARD, None), False)

    @watch_clipboard.setter
    def watch_clipboard(self, value: bool) -> None:
        self._set(_KEY_WATCH_CLIPBOARD, bool(value))

    @property
    def close_to_tray(self) -> bool:
        return self._to_bool(self._get(_KEY_CLOSE_TO_TRAY, None), True)

    @close_to_tray.setter
    def close_to_tray(self, value: bool) -> None:
        self._set(_KEY_CLOSE_TO_TRAY, bool(value))

    # ---- misc ------------------------------------------------------------
    def sync(self) -> None:
        self._q.sync()

    def clear(self) -> None:
        self._q.clear()
        self._q.sync()
