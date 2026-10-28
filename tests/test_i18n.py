"""Tests for the JSON-based localisation module."""

from __future__ import annotations

import json

import pytest


def test_catalog_files_exist_and_are_valid_json():
    from linkplayer.i18n import locales_dir

    d = locales_dir()
    assert (d / "ru.json").exists() and (d / "en.json").exists()
    for name in ("ru.json", "en.json"):
        data = json.loads((d / name).read_text(encoding="utf-8"))
        assert isinstance(data, dict) and data


@pytest.mark.parametrize("lang", ["ru", "en"])
def test_load_language_no_errors(lang):
    from linkplayer import i18n

    catalog = i18n._load_language(lang)
    assert catalog  # non-empty
    assert "download.button" in catalog


def test_t_returns_different_strings_per_language():
    from linkplayer import i18n

    i18n.set_language("ru")
    ru = i18n.t("download.button")
    i18n.set_language("en")
    en = i18n.t("download.button")
    assert ru == "Скачать"
    assert en == "Download"
    assert ru != en


def test_missing_key_returns_key_itself():
    from linkplayer import i18n

    i18n.set_language("en")
    key = "no.such.key.at.all"
    assert i18n.t(key) == key  # fallback, no exception


def test_switching_language_changes_strings_at_runtime():
    from linkplayer import i18n

    i18n.set_language("en")
    assert i18n.t("settings.title") == "Settings"
    i18n.set_language("ru")
    assert i18n.t("settings.title") == "Настройки"
    # …and back again without restart.
    i18n.set_language("en")
    assert i18n.t("settings.title") == "Settings"


def test_format_arguments_are_substituted():
    from linkplayer import i18n

    i18n.set_language("en")
    assert i18n.t("playlist.question", count=7) == \
        "Playlist of 7 videos. What should be downloaded?"


def test_system_default_when_language_unset(qapp):
    from linkplayer import i18n

    lang = i18n.system_language()
    assert lang in i18n.available_languages()
    i18n.set_language(None)
    assert i18n.current_language() == lang
