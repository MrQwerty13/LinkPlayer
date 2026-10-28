"""Application bootstrap: QApplication, single instance (QLockFile), styling."""

from __future__ import annotations

import os
import sys

from PySide6.QtCore import QLockFile, Qt
from PySide6.QtGui import QIcon
from PySide6.QtWidgets import QApplication, QMessageBox

from linkplayer import APP_NAME, ORG_NAME, __version__, i18n
from linkplayer.resources_util import resource_path

_STYLE = """
_UrlLineEdit {
    padding: 6px 10px;
    border-radius: 6px;
    border: 1px solid #c8c8ce;
    background: palette(base);
    font-size: 13px;
}
_UrlLineEdit[invalid="true"] { border: 1px solid #e74c3c; }
_UrlLineEdit[highlighted="true"] { border: 2px solid #2563eb; background: #eef4ff; }
QPushButton {
    padding: 6px 14px;
    border-radius: 6px;
}
QProgressBar {
    border: 1px solid #c8c8ce;
    border-radius: 6px;
    text-align: center;
    height: 18px;
}
QProgressBar::chunk { background: #2563eb; border-radius: 5px; }
QPlainTextEdit {
    border: 1px solid #d5d5da;
    border-radius: 6px;
    background: #fbfbfd;
}
"""


def app_support_dir() -> str:
    """~/Library/Application Support/LinkPlayer on macOS (portable elsewhere)."""
    base = os.path.expanduser("~/Library/Application Support")
    if not sys.platform.startswith("darwin"):  # pragma: no cover — dev on Linux
        from PySide6.QtCore import QStandardPaths

        base = QStandardPaths.writableLocation(
            QStandardPaths.StandardLocation.AppDataLocation
        ) or os.path.expanduser("~/.local/share")
    path = os.path.join(base, APP_NAME)
    os.makedirs(path, exist_ok=True)
    return path


def acquire_single_instance(lock_path: str | None = None) -> QLockFile | None:
    """Try to become the only running instance. Returns the lock or ``None``."""
    path = lock_path or os.path.join(app_support_dir(), "linkplayer.lock")
    lock = QLockFile(path)
    lock.setStaleLockTime(0)
    if lock.tryLock(100):
        return lock
    return None


def application_icon() -> QIcon:
    icns = resource_path(os.path.join("resources", "icon.icns"))
    png = resource_path(os.path.join("resources", "icon_tray.png"))
    for candidate in (png, icns):
        if os.path.exists(candidate):
            return QIcon(candidate)
    from linkplayer.tray import tray_icon

    return tray_icon()


def create_app(argv: list[str] | None = None) -> QApplication:
    """Create (or reuse) the QApplication with names and global stylesheet."""
    argv = list(argv if argv is not None else sys.argv)
    app = QApplication.instance() or QApplication(argv)
    app.setApplicationName(APP_NAME)
    app.setOrganizationName(ORG_NAME)
    app.setApplicationDisplayName(APP_NAME)
    app.setApplicationVersion(__version__)
    app.setDesktopFileName(APP_NAME)
    app.setAttribute(Qt.ApplicationAttribute.AA_DontShowIconsInMenus, False)
    app.setQuitOnLastWindowClosed(False)  # tray keeps us alive
    app.setStyleSheet(_STYLE)
    app.setWindowIcon(application_icon())
    return app


def main(argv: list[str] | None = None) -> int:
    """Entry point used by ``python -m linkplayer`` and the frozen bundle."""
    # macOS-specific appearance tweaks must happen before the first window.
    if sys.platform == "darwin":  # pragma: no cover — only on macOS
        try:
            from PySide6.QtCore import QNativeEvent  # noqa: F401 (presence check)
        except ImportError:
            pass

    app = create_app(argv)
    i18n.set_language(None)  # system default until settings are read

    lock = acquire_single_instance()
    if lock is None:
        QMessageBox.warning(
            None,
            APP_NAME,
            i18n.t("app.title") + " — " + "Another instance is already running.",
        )
        return 0

    from linkplayer.main_window import MainWindow
    from linkplayer.settings import Settings

    settings = Settings()
    window = MainWindow(settings)
    window.show()
    code = app.exec()
    del lock  # release the single-instance lock on exit
    return code


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
