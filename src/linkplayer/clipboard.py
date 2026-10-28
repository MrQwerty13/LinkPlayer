"""Clipboard monitoring: pure URL detection + a Qt signal-based watcher."""

from __future__ import annotations

import re

from PySide6.QtCore import QObject, Signal

#: Hosts we recognise as downloadable video links.
VIDEO_HOSTS = (
    "youtube.com",
    "youtu.be",
    "music.youtube.com",
    "vk.com",
    "vkvideo.ru",
    "rutube.ru",
)

_URL_RE = re.compile(
    r"""(?:https?://)?((?:[a-zA-Z0-9-]+\.)+(?:com|ru|be|net|org)(?:/[^\s<>"']*)?)""",
    re.IGNORECASE,
)


def _host_of(url: str) -> str:
    m = re.match(r"^(?:https?://)?([^/]+)", url, re.IGNORECASE)
    return (m.group(1) if m else "").lower()


def _is_video_url(candidate: str) -> bool:
    host = _host_of(candidate)
    if not host:
        return False
    if host in ("youtu.be", "www.youtu.be") or host.endswith(".youtu.be"):
        return True
    if host in ("youtube.com", "www.youtube.com", "m.youtube.com",
                "music.youtube.com") or host.endswith(".youtube.com"):
        path = "/" + candidate.split(host, 1)[-1] if host in candidate else "/"
        # Require an explicit video/playlist marker; bare domains don't count.
        return bool(re.search(r"/watch\b|[?&]v=|/shorts/|/live\b|/playlist\b|[?&]list=", path))
    if host in ("vk.com", "www.vk.com", "m.vk.com", "vkvideo.ru", "www.vkvideo.ru"):
        path = candidate.lower()
        return "/video" in path or "vkvideo.ru/" in path.replace("https://", "").replace("http://", "")
    if host in ("rutube.ru", "www.rutube.ru"):
        return "/video/" in candidate.lower() or "/shorts/" in candidate.lower() or "/play/embed/" in candidate.lower()
    return False


def extract_video_url(text: str | None) -> str | None:
    """Return the first supported video URL found in *text*, else ``None``.

    Pure function — no Qt, no network. Recognises YouTube
    (``youtube.com/watch?v=…``, ``youtu.be/…``), VK Video
    (``vk.com/video…``) and Rutube (``rutube.ru/video/…``).
    """
    if not text or not text.strip():
        return None
    for m in _URL_RE.finditer(text):
        candidate = m.group(0).strip().rstrip(".,;:)")
        host = _host_of(candidate)
        if any(host == h or host.endswith("." + h) for h in VIDEO_HOSTS):
            if _is_video_url(candidate):
                if not candidate.lower().startswith(("http://", "https://")):
                    candidate = "https://" + candidate
                return candidate
    return None


class ClipboardWatcher(QObject):
    """Watches ``QGuiApplication.clipboard().dataChanged`` and de-duplicates.

    Emits :attr:`new_url` only when a *different* supported link appears and
    only while enabled.  Never auto-downloads — the GUI decides.
    """

    new_url = Signal(str)

    def __init__(self, clipboard, settings=None, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self._clipboard = clipboard
        self._settings = settings
        self._last_url: str | None = None
        self._enabled = True
        self._clipboard.dataChanged.connect(self._on_changed)

    # -- enable/disable ----------------------------------------------------
    @property
    def enabled(self) -> bool:
        return self._enabled

    @enabled.setter
    def enabled(self, value: bool) -> None:
        self._enabled = bool(value)

    # -- slots -------------------------------------------------------------
    def _on_changed(self) -> None:
        if not self._enabled:
            return
        if self._settings is not None and not self._settings.watch_clipboard:
            return
        try:
            mime = self._clipboard.mimeData()
            text = mime.text() if mime.hasText() else ""
        except Exception:  # pragma: no cover — defensive
            text = ""
        url = extract_video_url(text)
        if not url:
            return
        if url == self._last_url:
            return  # duplicate — do not notify twice
        self._last_url = url
        self.new_url.emit(url)

    def reset(self) -> None:
        """Forget the last notified URL (e.g. after the user dismisses it)."""
        self._last_url = None
