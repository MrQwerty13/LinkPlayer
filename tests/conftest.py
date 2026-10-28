"""Shared pytest fixtures.

* Forces the offscreen Qt platform so GUI tests run headless (CI/Linux/macOS).
* Isolates QSettings into a per-test temp file via ``QSettings.setPath`` —
  no real user preferences are ever touched.
* yt-dlp is always mocked; tests never hit the network.
"""

from __future__ import annotations

import os
import sys

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

# Make ``src/`` importable without installing the package.
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")
if SRC not in sys.path:
    sys.path.insert(0, SRC)

import pytest  # noqa: E402


@pytest.fixture(scope="session")
def qapp_cls():
    """Use QApplication (not QGuiApplication) for widget tests."""
    from PySide6.QtWidgets import QApplication

    return QApplication


@pytest.fixture()
def isolated_settings(tmp_path, qapp):
    """Redirect QSettings storage to *tmp_path* and yield a fresh Settings().

    Call this fixture *before* constructing any Settings object.
    """
    from PySide6.QtCore import QSettings

    from linkplayer import APP_NAME, ORG_NAME

    conf_dir = tmp_path / "conf"
    data_dir = tmp_path / "data"
    conf_dir.mkdir()
    data_dir.mkdir()
    QSettings.setPath(QSettings.Format.NativeFormat,
                      QSettings.Scope.UserScope, str(conf_dir))
    QSettings.setPath(QSettings.Format.IniFormat,
                      QSettings.Scope.UserScope, str(conf_dir))
    QSettings.setPath(QSettings.Format.NativeFormat,
                      QSettings.Scope.SystemScope, str(data_dir))
    QSettings.setPath(QSettings.Format.IniFormat,
                      QSettings.Scope.SystemScope, str(data_dir))
    QSettings.setDefaultFormat(QSettings.Format.IniFormat)
    s = None
    from linkplayer.settings import Settings

    s = Settings()
    s.clear()
    yield s
    if s is not None:
        s.clear()


@pytest.fixture()
def download_dir(tmp_path):
    d = tmp_path / "downloads"
    d.mkdir()
    return str(d)
