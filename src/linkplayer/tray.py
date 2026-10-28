"""System tray icon with Open/Quit menu and native-style notifications."""

from __future__ import annotations

import os

from PySide6.QtCore import QObject, Signal, Slot
from PySide6.QtGui import QIcon, QPixmap
from PySide6.QtWidgets import QMenu, QSystemTrayIcon

from linkplayer import i18n
from linkplayer.resources_util import resource_path


def tray_icon() -> QIcon:
    """22x22 tray pixmap (``icon_tray.png``) with a graceful fallback."""
    path = resource_path(os.path.join("resources", "icon_tray.png"))
    if os.path.exists(path):
        pm = QPixmap(path)
        if not pm.isNull():
            return QIcon(pm)
    # Fallback: solid 22x22 pixmaps so the tray still works in dev.
    from PySide6.QtCore import Qt
    from PySide6.QtGui import QColor, QPainter

    pm = QPixmap(22, 22)
    pm.fill(QColor(0, 0, 0, 0))
    painter = QPainter(pm)
    painter.setRenderHint(QPainter.RenderHint.Antialiasing)
    painter.setBrush(QColor(37, 99, 235))
    painter.setPen(Qt.PenStyle.NoPen)
    painter.drawEllipse(1, 1, 20, 20)
    painter.end()
    return QIcon(pm)


class TrayManager(QObject):
    """Owns the QSystemTrayIcon; emits activate()/quit_requested()."""

    quit_requested = Signal()
    open_requested = Signal()
    notification_clicked = Signal(str)  # file/dir path attached to a message

    def __init__(self, parent=None) -> None:
        super().__init__(parent)
        self._tray: QSystemTrayIcon | None = None
        self._last_payload = ""
        if QSystemTrayIcon.isSystemTrayAvailable():
            self._tray = QSystemTrayIcon(tray_icon(), parent)
            menu = QMenu()
            act_open = menu.addAction(i18n.t("tray.open"))
            act_open.triggered.connect(self.open_requested.emit)
            menu.addSeparator()
            act_quit = menu.addAction(i18n.t("tray.quit"))
            act_quit.triggered.connect(self.quit_requested.emit)
            self._menu = menu
            self._tray.setContextMenu(menu)
            self._tray.setToolTip(i18n.t("tray.tooltip"))
            self._tray.activated.connect(self._on_activated)
            self._tray.messageClicked.connect(self._on_message_clicked)

    @property
    def available(self) -> bool:
        return self._tray is not None

    def retranslate(self) -> None:
        """Refresh menu/tooltip texts after a language switch."""
        if self._tray is None:
            return
        actions = self._menu.actions()
        if len(actions) >= 3:
            actions[0].setText(i18n.t("tray.open"))
            actions[2].setText(i18n.t("tray.quit"))
        self._tray.setToolTip(i18n.t("tray.tooltip"))

    def show(self) -> None:
        if self._tray is not None:
            self._tray.show()

    def notify(self, title: str, body: str, payload: str = "", msecs: int = 6000) -> None:
        """Show a tray notification; clicking it opens ``payload`` (a path)."""
        self._last_payload = payload
        if self._tray is not None:
            self._tray.showMessage(title, body, self._tray.icon(), msecs)

    def _on_activated(self, reason) -> None:
        from PySide6.QtWidgets import QSystemTrayIcon as STI

        if reason in (STI.ActivationReason.Trigger, STI.ActivationReason.DoubleClick):
            self.open_requested.emit()

    def _on_message_clicked(self) -> None:
        if self._last_payload:
            self.notification_clicked.emit(self._last_payload)


def open_in_file_manager(path: str) -> None:
    """Reveal *path* (file or folder) in Finder / Explorer / xdg-open."""
    import subprocess
    import sys

    if not path or not os.path.exists(path):
        return
    if sys.platform == "darwin":
        if os.path.isdir(path):
            args = ["open", path]
        else:
            args = ["open", "-R", path]
    elif sys.platform.startswith("win"):  # pragma: no cover
        args = ["explorer", "/select,", path]
    else:  # pragma: no cover
        target = path if os.path.isdir(path) else os.path.dirname(path)
        args = ["xdg-open", target]
    try:
        subprocess.Popen(args)
    except OSError:
        pass
