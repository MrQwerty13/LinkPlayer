"""Tests for the QSettings wrapper — fully isolated via tmp_path."""

from __future__ import annotations

import os
import stat

import pytest


def test_defaults(isolated_settings):
    s = isolated_settings
    # language defaults to the system locale
    from linkplayer.i18n import system_language

    assert s.language == system_language()
    assert s.cookies_browser is None
    assert s.watch_clipboard is False
    assert s.close_to_tray is True


def test_save_dir_default_is_valid_dir(isolated_settings):
    s = isolated_settings
    assert os.path.isdir(s.save_dir) and os.access(s.save_dir, os.W_OK)


def test_write_read_save_dir(isolated_settings, download_dir):
    s = isolated_settings
    s.save_dir = download_dir
    assert s.save_dir == download_dir


def test_invalid_nonexistent_dir_resets_to_default(isolated_settings, tmp_path, download_dir):
    s = isolated_settings
    s.save_dir = download_dir  # valid first
    bogus = str(tmp_path / "does-not-exist")
    s.save_dir = bogus         # rejected → falls back to default
    assert s.save_dir != bogus
    assert os.path.isdir(s.save_dir)


def test_nonwritable_dir_is_rejected(isolated_settings, tmp_path):
    s = isolated_settings
    ro = tmp_path / "readonly"
    ro.mkdir()
    os.chmod(ro, stat.S_IRUSR | stat.S_IXUSR)  # r-x, no w
    try:
        s.save_dir = str(ro)
        assert s.save_dir != str(ro)
    finally:
        os.chmod(ro, stat.S_IRWXU)


@pytest.mark.parametrize("browser", [None, "safari", "chrome", "firefox", "edge"])
def test_cookies_browser_roundtrip(isolated_settings, browser):
    s = isolated_settings
    s.cookies_browser = browser
    assert s.cookies_browser == browser


def test_invalid_browser_value_is_dropped(isolated_settings):
    s = isolated_settings
    s.cookies_browser = "opera-mini"  # not in the selector list
    assert s.cookies_browser is None


def test_watch_clipboard_toggle(isolated_settings):
    s = isolated_settings
    s.watch_clipboard = True
    assert s.watch_clipboard is True
    s.watch_clipboard = False
    assert s.watch_clipboard is False


def test_settings_survive_restart(isolated_settings, download_dir):
    """A brand-new Settings() over the same file sees the stored values."""
    s = isolated_settings
    s.save_dir = download_dir
    s.cookies_browser = "chrome"
    s.watch_clipboard = True
    s.close_to_tray = False
    s.sync()

    from linkplayer.settings import Settings

    s2 = Settings()
    assert s2.save_dir == download_dir
    assert s2.cookies_browser == "chrome"
    assert s2.watch_clipboard is True
    assert s2.close_to_tray is False


def test_language_persisted_and_applied(isolated_settings):
    s = isolated_settings
    s.language = "ru"
    assert s.language == "ru"
    from linkplayer import i18n

    i18n.set_language(s.language)
    assert i18n.t("download.button") == "Скачать"
    i18n.set_language("en")  # restore for other tests
