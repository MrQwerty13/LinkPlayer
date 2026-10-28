"""Tests for clipboard URL detection and the ClipboardWatcher integration."""

from __future__ import annotations

import pytest

from linkplayer.clipboard import ClipboardWatcher, extract_video_url


# --------------------------------------------------------------------------
# Pure function: extract_video_url
# --------------------------------------------------------------------------

@pytest.mark.parametrize("text", [
    "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
    "youtube.com/watch?v=dQw4w9WgXcQ",
    "https://youtu.be/dQw4w9WgXcQ",
    "youtu.be/dQw4w9WgXcQ?si=abc",
    "https://m.youtube.com/watch?v=abcdef12345",
    "https://www.youtube.com/playlist?list=PLabcdefghij",
])
def test_detects_youtube(text):
    url = extract_video_url(text)
    assert url and "youtube" in url or url and "youtu.be" in url


@pytest.mark.parametrize("text", [
    "https://vk.com/video-123456_789012",
    "https://vk.com/video/user1_12345",
    "vk.com/video-452-2",
])
def test_detects_vk(text):
    url = extract_video_url(text)
    assert url and "vk.com" in url


@pytest.mark.parametrize("text", [
    "https://rutube.ru/video/1234567890abcdef1234567890abcd/",
    "rutube.ru/video/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/",
])
def test_detects_rutube(text):
    url = extract_video_url(text)
    assert url and "rutube.ru" in url


def test_extracts_url_from_surrounding_text():
    text = "Смотри вот это видео: https://youtu.be/dQw4w9WgXcQ — огонь!"
    url = extract_video_url(text)
    assert url == "https://youtu.be/dQw4w9WgXcQ"


@pytest.mark.parametrize("text", [
    "",
    "   ",
    "привет, как дела?",
    "just some random words",
    "https://example.com/page.html",
    "https://vimeo.com/123456789",          # unsupported site
    "https://t.me/somechannel",             # not a video host
    "https://youtube.com",                  # bare domain, no video id
    "user@example.com",                     # e-mail, not a URL we accept
])
def test_ignores_non_video(text):
    assert extract_video_url(text) is None


# --------------------------------------------------------------------------
# Integration with QClipboard (pytest-qt)
# --------------------------------------------------------------------------

class FakeSettings:
    def __init__(self, watch=True):
        self.watch_clipboard = watch


@pytest.fixture()
def watcher(qapp):
    w = ClipboardWatcher(qapp.clipboard())
    yield w
    w.deleteLater()


def _set_clipboard(qapp, qtbot, text: str):
    qapp.clipboard().setText(text)
    qtbot.wait(1)  # let the dataChanged signal dispatch (no sleep-based waits)


def test_watcher_emits_on_supported_link(qapp, qtbot, watcher):
    watcher.enabled = True
    with qtbot.waitSignal(watcher.new_url, timeout=1000) as blocker:
        _set_clipboard(qapp, qtbot, "https://youtu.be/dQw4w9WgXcQ")
    assert blocker.args[0].startswith("https://youtu.be/")


def test_watcher_deduplicates_same_url(qapp, qtbot, watcher):
    watcher.enabled = True
    received = []
    watcher.new_url.connect(received.append)
    _set_clipboard(qapp, qtbot, "https://youtu.be/dQw4w9WgXcQ")
    # Copy something else, then copy the same link again → must NOT re-emit.
    _set_clipboard(qapp, qtbot, "hello world")
    _set_clipboard(qapp, qtbot, "https://youtu.be/dQw4w9WgXcQ")
    assert len(received) == 1


def test_watcher_emits_different_url_again(qapp, qtbot, watcher):
    watcher.enabled = True
    received = []
    watcher.new_url.connect(received.append)
    _set_clipboard(qapp, qtbot, "https://youtu.be/AAAAAAAAAAA")
    _set_clipboard(qapp, qtbot, "https://rutube.ru/video/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/")
    assert len(received) == 2


def test_watcher_ignores_plain_text(qapp, qtbot, watcher):
    watcher.enabled = True
    received = []
    watcher.new_url.connect(received.append)
    _set_clipboard(qapp, qtbot, "не ссылка вообще")
    assert received == []


def test_watcher_disabled_by_settings_flag(qapp, qtbot, watcher):
    """watch_clipboard=False → no notifications at all."""
    settings = FakeSettings(watch=False)
    watcher._settings = settings
    watcher.enabled = True
    received = []
    watcher.new_url.connect(received.append)
    _set_clipboard(qapp, qtbot, "https://youtu.be/dQw4w9WgXcQ")
    assert received == []


def test_watcher_reset_forgets_last(qapp, qtbot, watcher):
    watcher.enabled = True
    received = []
    watcher.new_url.connect(received.append)
    _set_clipboard(qapp, qtbot, "https://youtu.be/dQw4w9WgXcQ")
    watcher.reset()
    _set_clipboard(qapp, qtbot, "https://youtu.be/dQw4w9WgXcQ")
    assert len(received) == 2
