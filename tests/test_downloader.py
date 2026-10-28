"""Tests for the download engine — yt_dlp.YoutubeDL is ALWAYS mocked."""

from __future__ import annotations

import pytest

import linkplayer.downloader as dl


# --------------------------------------------------------------------------
# build_ydl_opts (pure)
# --------------------------------------------------------------------------

def test_build_ydl_opts_core_fields():
    opts = dl.build_ydl_opts("/tmp/downloads")
    assert opts["format"] == "bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/bv*+ba/b"
    assert opts["merge_output_format"] == "mp4"
    assert opts["outtmpl"].endswith("%(title)s [%(id)s].%(ext)s")
    assert "/tmp/downloads" in opts["outtmpl"]


def test_build_ydl_opts_subtitles_thumbnail():
    opts = dl.build_ydl_opts("/tmp/downloads")
    assert opts["writesubtitles"] is True
    assert opts["writeautomaticsub"] is True
    assert opts["subtitleslangs"] == ["ru", "en"]
    assert opts["writethumbnail"] is True


def test_build_ydl_opts_postprocessors():
    opts = dl.build_ydl_opts("/tmp/downloads")
    keys = {p["key"] for p in opts["postprocessors"]}
    assert {"FFmpegVideoRemuxer", "FFmpegThumbnailsConvertor",
            "EmbedThumbnail", "FFmpegEmbedSubtitle"} <= keys
    remux = next(p for p in opts["postprocessors"] if p["key"] == "FFmpegVideoRemuxer")
    assert remux["preferedformat"] == "mp4"
    conv = next(p for p in opts["postprocessors"] if p["key"] == "FFmpegThumbnailsConvertor")
    assert conv["format"] == "jpg"


@pytest.mark.parametrize("browser", ["safari", "chrome", "firefox", "edge"])
def test_build_ydl_opts_cookies_browser(browser):
    opts = dl.build_ydl_opts("/tmp/dl", cookies_browser=browser)
    assert opts["cookiesfrombrowser"] == (browser,)


def test_build_ydl_opts_no_cookies_by_default():
    opts = dl.build_ydl_opts("/tmp/dl")
    assert "cookiesfrombrowser" not in opts


def test_build_ydl_opts_unknown_browser_ignored():
    opts = dl.build_ydl_opts("/tmp/dl", cookies_browser="netscape")
    assert "cookiesfrombrowser" not in opts


def test_build_ydl_opts_ffmpeg_location():
    opts = dl.build_ydl_opts("/tmp/dl", ffmpeg_location="/app/ffmpeg")
    assert opts["ffmpeg_location"] == "/app/ffmpeg"


def test_build_ydl_opts_single_video_mode():
    opts = dl.build_ydl_opts("/tmp/dl", playlist=False)
    assert opts["noplaylist"] is True


# --------------------------------------------------------------------------
# progress hook
# --------------------------------------------------------------------------

def test_progress_hook_percent_str():
    events = []
    hook = dl.make_progress_hook(lambda pct, text: events.append((pct, text)))
    hook({
        "status": "downloading",
        "_percent_str": " 45.5%",
        "_speed_str": " 3.2MiB/s",
        "_eta_str": " 00:12",
        "downloaded_bytes": 455,
        "total_bytes": 1000,
    })
    assert len(events) == 1
    pct, text = events[0]
    assert pct == pytest.approx(45.5)
    assert "3.2MiB/s" in text


def test_progress_hook_from_byte_counters():
    events = []
    hook = dl.make_progress_hook(lambda pct, text: events.append((pct, text)))
    hook({
        "status": "downloading",
        "downloaded_bytes": 250,
        "total_bytes": 1000,
        "speed": 1024 * 1024,
    })
    assert events[0][0] == pytest.approx(25.0)


def test_progress_hook_finished_emits_100():
    events = []
    hook = dl.make_progress_hook(lambda pct, text: events.append((pct, text)))
    hook({"status": "finished"})
    assert events[-1][0] == 100.0


def test_progress_hook_ignores_other_statuses():
    events = []
    hook = dl.make_progress_hook(lambda pct, text: events.append((pct, text)))
    hook({"status": "extracting"})
    hook({"status": "error"})
    assert events == []


# --------------------------------------------------------------------------
# detect_playlist (YoutubeDL mocked)
# --------------------------------------------------------------------------

class FakeYDL:
    """Stand-in for ``yt_dlp.YoutubeDL`` — no network access whatsoever."""

    info = {}
    raises = None

    def __init__(self, opts=None):
        type(self).last_opts = opts

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def extract_info(self, url, download=False):
        if type(self).raises:
            raise type(self).raises(type(self).raises_msg or "boom")
        return type(self).info


@pytest.fixture()
def fake_ydl(monkeypatch):
    import yt_dlp

    FakeYDL.raises = None
    FakeYDL.raises_msg = None
    FakeYDL.info = {}
    monkeypatch.setattr(yt_dlp, "YoutubeDL", FakeYDL)
    yield FakeYDL
    monkeypatch.undo()


def test_detect_playlist_many(fake_ydl):
    fake_ydl.info = {"_type": "playlist", "n_entries": 5}
    assert dl.detect_playlist("https://example/playlist") == 5


def test_detect_playlist_one(fake_ydl):
    fake_ydl.info = {"_type": "playlist", "n_entries": 1}
    assert dl.detect_playlist("https://example/x") == 1


def test_detect_playlist_missing_key_counts_entries(fake_ydl):
    fake_ydl.info = {"_type": "playlist", "entries": [{"url": "a"}, {"url": "b"}, {"url": "c"}]}
    assert dl.detect_playlist("https://example/x") == 3


def test_detect_playlist_single_video(fake_ydl):
    fake_ydl.info = {"_type": "video", "id": "abc"}
    assert dl.detect_playlist("https://example/x") == 1


def test_detect_playlist_none_info(fake_ydl):
    fake_ydl.info = None
    assert dl.detect_playlist("https://example/x") == 1


def test_detect_playlist_error_returns_one(fake_ydl):
    import yt_dlp

    fake_ydl.raises = yt_dlp.utils.DownloadError
    fake_ydl.raises_msg = "network down"
    assert dl.detect_playlist("https://example/x") == 1


def test_detect_playlist_uses_extract_flat(fake_ydl):
    fake_ydl.info = {"_type": "video"}
    dl.detect_playlist("https://example/x")
    assert fake_ydl.last_opts.get("extract_flat") == "in_playlist"
    assert fake_ydl.last_opts.get("skip_download") is True


# --------------------------------------------------------------------------
# DownloadTask with mocked YoutubeDL
# --------------------------------------------------------------------------

def make_task(qtbot, monkeypatch, fake_ydl, **kw):
    from PySide6.QtCore import QCoreApplication

    task = dl.DownloadTask(
        url=kw.pop("url", "https://youtu.be/dQw4w9WgXcQ"),
        save_dir=kw.pop("save_dir", "/tmp/lp-test"),
        **kw,
    )
    return task


def test_task_run_success_emits_finished(qtbot, monkeypatch, fake_ydl, tmp_path):
    fake_ydl.info = {
        "_type": "video",
        "requested_downloads": [{"filepath": str(tmp_path / "video.mp4")}],
    }
    task = dl.DownloadTask(url="https://youtu.be/x", save_dir=str(tmp_path))
    with qtbot.waitSignal(task.signals.finished, timeout=5000) as blocker:
        task.run()
    assert blocker.args[0].endswith("video.mp4")


def test_task_download_error_emits_error_not_crash(qtbot, monkeypatch, fake_ydl, tmp_path):
    import yt_dlp

    fake_ydl.raises = yt_dlp.utils.DownloadError
    fake_ydl.raises_msg = "ERROR: Unsupported URL"
    task = dl.DownloadTask(url="https://example/x", save_dir=str(tmp_path))
    with qtbot.waitSignal(task.signals.error, timeout=5000) as blocker:
        task.run()
    assert isinstance(blocker.args[0], str) and blocker.args[0]


def test_task_unsupported_url_localised(qtbot, fake_ydl, tmp_path):
    import yt_dlp

    from linkplayer import i18n

    i18n.set_language("en")
    fake_ydl.raises = yt_dlp.utils.DownloadError
    fake_ydl.raises_msg = "ERROR: Unsupported URL: https://x"
    task = dl.DownloadTask(url="https://x", save_dir=str(tmp_path))
    with qtbot.waitSignal(task.signals.error, timeout=5000) as blocker:
        task.run()
    assert blocker.args[0] == i18n.t("errors.unsupported")


def test_task_cancelled_before_start(qtbot, fake_ydl, tmp_path):
    task = dl.DownloadTask(url="https://youtu.be/x", save_dir=str(tmp_path))
    task.cancel()
    with qtbot.waitSignal(task.signals.error, timeout=5000):
        task.run()
    assert task.cancelled


def test_task_progress_signal_forwarded(qtbot, fake_ydl, tmp_path, monkeypatch):
    """The hook installed into ydl_opts drives the Qt ``progress`` signal."""

    def extract_info(self, url, download=False):
        # Simulate yt-dlp calling our progress hooks.
        for h in type(self).last_opts.get("progress_hooks", []):
            h({"status": "downloading", "_percent_str": "50.0%",
               "_speed_str": "1MiB/s", "downloaded_bytes": 1, "total_bytes": 2})
            h({"status": "finished"})
        return {"_type": "video", "requested_downloads": [{"filepath": "v.mp4"}]}

    monkeypatch.setattr(FakeYDL, "extract_info", extract_info)
    task = dl.DownloadTask(url="https://youtu.be/x", save_dir=str(tmp_path))
    progresses = []
    task.signals.progress.connect(lambda p, t: progresses.append((p, t)))
    with qtbot.waitSignal(task.signals.finished, timeout=5000):
        task.run()
    assert (50.0, "1MiB/s") in progresses
    assert progresses[-1][0] == 100.0


def test_task_cancel_during_download_emits_error(qtbot, fake_ydl, tmp_path, monkeypatch):
    def extract_info(self, url, download=False):
        hook = type(self).last_opts["progress_hooks"][0]
        hook({"status": "downloading", "_percent_str": "10%", "downloaded_bytes": 1,
              "total_bytes": 10})
        task.cancel()
        # The second tick must raise DownloadError from inside the hook —
        # exactly what real yt-dlp interprets as user cancellation.
        try:
            hook({"status": "downloading", "_percent_str": "20%", "downloaded_bytes": 2,
                  "total_bytes": 10})
        except Exception as exc:
            import yt_dlp

            assert isinstance(exc, yt_dlp.utils.DownloadError)
            raise
        return {"_type": "video"}

    monkeypatch.setattr(FakeYDL, "extract_info", extract_info)
    task = dl.DownloadTask(url="https://youtu.be/x", save_dir=str(tmp_path))
    with qtbot.waitSignal(task.signals.error, timeout=5000):
        task.run()


def test_task_build_opts_inherits_module_settings(fake_ydl, tmp_path):
    task = dl.DownloadTask(
        url="https://vk.com/video-1_2",
        save_dir=str(tmp_path),
        cookies_browser="safari",
        ffmpeg_location="/opt/ffmpeg",
    )
    opts = task.build_opts()
    assert opts["cookiesfrombrowser"] == ("safari",)
    assert opts["ffmpeg_location"] == "/opt/ffmpeg"
    assert opts["merge_output_format"] == "mp4"


# --------------------------------------------------------------------------
# error translator
# --------------------------------------------------------------------------

def test_error_translator_keychain_message(qtbot):
    from linkplayer import i18n

    i18n.set_language("ru")
    tr = dl.make_error_translator()
    msg = tr("ERROR: could not read cookies from safari keychain")
    assert msg == i18n.t("cookies.keychain_error", browser="safari")
    i18n.set_language("en")
