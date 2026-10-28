"""yt-dlp based download engine.

``build_ydl_opts`` is a pure function so it can be unit-tested without any
network access; ``DownloadTask`` wraps yt-dlp in a cancellable worker that
lives on its own Python thread (Qt's QThreadPool) while signals are delivered
to the GUI thread.
"""

from __future__ import annotations

import os
import re
import threading
from pathlib import Path

from PySide6.QtCore import QObject, QRunnable, Signal

# ---------------------------------------------------------------------------
# Pure helpers
# ---------------------------------------------------------------------------

#: Best-quality MP4 container selection (video+audio merged into mp4).
MP4_FORMAT = "bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/bv*+ba/b"
OUTTMPL = "%(title)s [%(id)s].%(ext)s"
SUBTITLE_LANGS = ["ru", "en"]

VALID_COOKIES_BROWSERS = {"safari", "chrome", "chromium", "edge", "firefox", "brave", "opera"}


def build_ydl_opts(
    save_dir: str,
    cookies_browser: str | None = None,
    ffmpeg_location: str | None = None,
    playlist: bool = True,
) -> dict:
    """Assemble the ``yt_dlp.YoutubeDL`` options dictionary.

    * best mp4 format + mp4 merge;
    * subtitles (manual + auto, ru/en) and thumbnail writing;
    * postprocessors: remux→mp4, thumbnail→jpg, embed thumbnail, embed subs;
    * optional browser cookie extraction (private/age-restricted videos).
    """
    opts: dict = {
        "format": MP4_FORMAT,
        "merge_output_format": "mp4",
        "outtmpl": os.path.join(save_dir, OUTTMPL),
        "noplaylist": not playlist,
        "ignoreerrors": "only_download" if playlist else False,
        "quiet": True,
        "no_warnings": True,
        "writesubtitles": True,
        "writeautomaticsub": True,
        "subtitleslangs": list(SUBTITLE_LANGS),
        "subtitlesformat": "best",
        "writethumbnail": True,
        "postprocessors": [
            {"key": "FFmpegVideoRemuxer", "preferedformat": "mp4"},
            {"key": "FFmpegThumbnailsConvertor", "format": "jpg"},
            {"key": "EmbedThumbnail", "already_have_thumbnail": False},
            {"key": "FFmpegEmbedSubtitle"},
        ],
        # Concurrency knobs — safe defaults for home connections.
        "concurrent_fragment_downloads": 4,
        "retries": 3,
        "fragment_retries": 3,
        "windowsfilenames": True,
    }

    if ffmpeg_location:
        opts["ffmpeg_location"] = ffmpeg_location

    browser = (cookies_browser or "").lower() or None
    if browser and browser in VALID_COOKIES_BROWSERS:
        opts["cookiesfrombrowser"] = (browser,)

    return opts


_PERCENT_RE = re.compile(r"([0-9]+(?:[.,][0-9]+)?)\s*%")


def parse_percent(value) -> float | None:
    """Extract a 0..100 percentage from ``_percent_str``-like values."""
    if value is None:
        return None
    try:
        return float(str(value).replace("%", "").replace(",", ".").strip())
    except ValueError:
        m = _PERCENT_RE.search(str(value))
        if m:
            return float(m.group(1))
    return None


def human_size(num: float | None) -> str:
    if not num:
        return ""
    size = float(num)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if size < 1024 or unit == "TB":
            return f"{size:.1f} {unit}" if unit != "B" else f"{int(size)} B"
        size /= 1024
    return ""


def make_progress_hook(emit) -> callable:
    """Return a yt-dlp ``progress_hooks`` callback that calls ``emit(pct, text)``.

    ``pct`` is a float 0..100; ``text`` is a short human status line such as
    ``"12.3 MB of 50 MB · 4.1 MiB/s"``.
    """

    def hook(d: dict) -> None:
        status = d.get("status", "")
        if status == "downloading":
            pct = parse_percent(d.get("_percent_str"))
            if pct is None:
                done = d.get("downloaded_bytes") or 0
                total = d.get("total_bytes") or d.get("total_bytes_estimate") or 0
                pct = (done / total * 100.0) if total else 0.0
            speed = d.get("_speed_str") or (
                f"{human_size(d['speed'])}/s" if d.get("speed") else ""
            )
            eta = d.get("_eta_str") or ""
            text_bits = [str(speed).strip(), str(eta).strip()]
            text = " · ".join(b for b in text_bits if b)
            emit(round(min(max(pct, 0.0), 100.0), 1), text)
        elif status == "finished":
            emit(100.0, "")

    return hook


def make_error_translator(language_hint: str | None = None) -> callable:
    """Translate raw yt-dlp error strings into localised messages."""
    from linkplayer import i18n

    def translate(raw: str) -> str:
        low = (raw or "").lower()
        if "keychain" in low or ("cookies" in low and "browser" in low):
            m = re.search(r"(safari|chrome|chromium|edge|firefox|brave|opera)", low)
            browser = m.group(1).capitalize() if m else ""
            return i18n.t("cookies.keychain_error", browser=browser)
        if "requested format is not available" in low or "age" in low and "confirm" in low:
            return i18n.t("errors.private")
        if "unable to download" in low or "connection" in low or "timed out" in low:
            return i18n.t("errors.network")
        if "unsupported url" in low:
            return i18n.t("errors.unsupported")
        return raw or i18n.t("errors.generic")

    return translate


# ---------------------------------------------------------------------------
# Playlist detection
# ---------------------------------------------------------------------------

def detect_playlist(url: str, ydl_opts: dict | None = None) -> int:
    """Return the number of entries for *url* using ``extract_flat``.

    1 → single video; N>1 → playlist.  Any failure is treated as a single
    item (the real download will surface proper errors later).
    """
    import yt_dlp

    opts = dict(ydl_opts or {})
    opts.update({"extract_flat": "in_playlist", "quiet": True, "no_warnings": True, "skip_download": True})
    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(url, download=False)
    except Exception:
        return 1
    if not info:
        return 1
    if info.get("_type") in ("playlist", "multi_video"):
        n = info.get("n_entries")
        if n is None:
            entries = info.get("entries") or []
            n = len([e for e in entries if e])
        try:
            return max(int(n), 1)
        except (TypeError, ValueError):
            return 1
    return 1


# ---------------------------------------------------------------------------
# Worker
# ---------------------------------------------------------------------------

class DownloadSignals(QObject):
    """Signals owned by a :class:`DownloadTask` (kept alive by it)."""

    progress = Signal(float, str)      # percent 0..100, status text
    log = Signal(str)                  # one line for the GUI log
    finished = Signal(str)             # path of the produced file
    error = Signal(str)                # localised error message


class DownloadTask(QRunnable):
    """Cancellable yt-dlp download executed off the GUI thread."""

    def __init__(
        self,
        url: str,
        save_dir: str,
        cookies_browser: str | None = None,
        ffmpeg_location: str | None = None,
        playlist: bool = True,
        parent: QObject | None = None,
    ) -> None:
        super().__init__()
        self.url = url.strip()
        self.save_dir = save_dir
        self.cookies_browser = cookies_browser
        self.ffmpeg_location = ffmpeg_location
        self.playlist = playlist
        self.signals = DownloadSignals(parent)
        self.setAutoDelete(True)
        self._cancel = threading.Event()
        self._ydl_lock = threading.Lock()
        self._ydl = None

    # -- cancellation ------------------------------------------------------
    def cancel(self) -> None:
        """Request cancellation; yt-dlp aborts on the next progress tick."""
        self._cancel.set()

    @property
    def cancelled(self) -> bool:
        return self._cancel.is_set()

    # -- helpers -----------------------------------------------------------
    def build_opts(self) -> dict:
        return build_ydl_opts(
            save_dir=self.save_dir,
            cookies_browser=self.cookies_browser,
            ffmpeg_location=self.ffmpeg_location,
            playlist=self.playlist,
        )

    def _latest_file(self) -> str:
        """Best-effort path of the most recently modified media file."""
        try:
            candidates = [
                p for p in Path(self.save_dir).iterdir()
                if p.suffix.lower() in (".mp4", ".mkv", ".webm", ".mov")
            ]
            if candidates:
                return str(max(candidates, key=lambda p: p.stat().st_mtime))
        except OSError:
            pass
        return self.save_dir

    # -- run ---------------------------------------------------------------
    def run(self) -> None:  # called on the QThreadPool worker thread
        import yt_dlp

        translate_error = make_error_translator()

        if self._cancel.is_set():
            self.signals.error.emit(self.tr_cancelled())
            return

        self.signals.log.emit(f"yt-dlp: starting {self.url}")
        hook = make_progress_hook(
            lambda pct, text: self._on_progress(pct, text)
        )
        opts = self.build_opts()
        opts["progress_hooks"] = [hook]

        try:
            with yt_dlp.YoutubeDL(opts) as ydl:
                with self._ydl_lock:
                    self._ydl = ydl
                try:
                    info = ydl.extract_info(self.url, download=True)
                finally:
                    with self._ydl_lock:
                        self._ydl = None
            if self._cancel.is_set():
                self.signals.error.emit(self.tr_cancelled())
                return
            filename = self._result_path(info)
            self.signals.finished.emit(filename)
        except yt_dlp.utils.DownloadError as exc:
            if self._cancel.is_set():
                self.signals.error.emit(self.tr_cancelled())
                return
            self.signals.error.emit(translate_error(str(exc)))
        except Exception as exc:  # noqa: BLE001 — surface anything to the UI
            if self._cancel.is_set():
                self.signals.error.emit(self.tr_cancelled())
                return
            self.signals.error.emit(translate_error(str(exc)))

    def tr_cancelled(self) -> str:
        from linkplayer import i18n

        return i18n.t("download.cancelled")

    def _result_path(self, info) -> str:
        try:
            if isinstance(info, dict):
                reqs = info.get("requested_downloads")
                if reqs:
                    fp = reqs[0].get("filepath")
                    if fp:
                        return str(fp)
                fp = info.get("filepath") or info.get("_filename")
                if fp:
                    return str(fp)
        except Exception:  # pragma: no cover — defensive
            pass
        return self._latest_file()

    def _on_progress(self, pct: float, text: str) -> None:
        # Checked here so cancellation interrupts the download loop.
        if self._cancel.is_set():
            import yt_dlp

            raise yt_dlp.utils.DownloadError("cancelled")
        self.signals.progress.emit(pct, text)
