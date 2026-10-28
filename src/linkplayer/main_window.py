"""Main window of LinkPlayer: URL input, download button, progress, log, tray."""

from __future__ import annotations

import os
from datetime import datetime

from PySide6.QtCore import Qt, QThreadPool, Signal
from PySide6.QtGui import QFont
from PySide6.QtWidgets import (
    QCheckBox,
    QDialog,
    QFileDialog,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMainWindow,
    QProgressBar,
    QPushButton,
    QPlainTextEdit,
    QVBoxLayout,
    QWidget,
)

from linkplayer import APP_NAME, __version__, i18n
from linkplayer.clipboard import ClipboardWatcher, extract_video_url
from linkplayer.downloader import DownloadTask, detect_playlist
from linkplayer.resources_util import ffmpeg_path, resource_path
from linkplayer.settings import Settings
from linkplayer.tray import TrayManager, open_in_file_manager


class MainWindow(QMainWindow):
    """The single application window. All downloads run on the global pool."""

    settings_changed = Signal()

    def __init__(self, settings: Settings | None = None, parent=None) -> None:
        super().__init__(parent)
        self.settings = settings or Settings()
        i18n.set_language(self.settings.language)

        self._pool = QThreadPool.globalInstance()
        self._current_task: DownloadTask | None = None
        self._last_notified_url: str | None = None

        self.setWindowTitle(f"{APP_NAME} {__version__}")
        self.setWindowIcon(self._window_icon())
        self.setMinimumSize(560, 420)
        self.resize(640, 480)

        self._build_ui()
        self.retranslate()

        # --- tray -----------------------------------------------------------
        self.tray = TrayManager(self)
        self.tray.open_requested.connect(self.show_and_raise)
        self.tray.quit_requested.connect(self._quit_app)
        self.tray.notification_clicked.connect(self._on_notification_clicked)
        self.tray.show()

        # --- clipboard watcher ---------------------------------------------
        from PySide6.QtGui import QGuiApplication

        self.clipboard_watcher = ClipboardWatcher(
            QGuiApplication.clipboard(), settings=self.settings, parent=self
        )
        self.clipboard_watcher.enabled = self.settings.watch_clipboard
        self.clipboard_watcher.new_url.connect(self._on_clipboard_url)

        self._force_close = False

    # ------------------------------------------------------------------ UI
    def _window_icon(self):
        from PySide6.QtGui import QIcon

        png = resource_path(os.path.join("resources", "icon_tray.png"))
        if os.path.exists(png):
            return QIcon(png)
        from linkplayer.tray import tray_icon

        return tray_icon()

    def _build_ui(self) -> None:
        central = QWidget(self)
        root = QVBoxLayout(central)
        root.setContentsMargins(16, 16, 16, 16)
        root.setSpacing(10)

        # Row 1: URL + Download
        row = QHBoxLayout()
        self.url_edit = _UrlLineEdit(central)
        self.url_edit.setObjectName("urlEdit")
        self.url_edit.returnPressed.connect(self.on_download_clicked)
        self.download_btn = QPushButton(central)
        self.download_btn.setObjectName("downloadButton")
        self.download_btn.setDefault(True)
        self.download_btn.clicked.connect(self.on_download_clicked)
        row.addWidget(self.url_edit, 1)
        row.addWidget(self.download_btn)
        root.addLayout(row)

        # Validation hint
        self.error_label = QLabel(central)
        self.error_label.setObjectName("errorLabel")
        self.error_label.setStyleSheet("color: #c0392b;")
        self.error_label.setVisible(False)
        self.error_label.setWordWrap(True)
        root.addWidget(self.error_label)

        # Row 2: progress + cancel
        row2 = QHBoxLayout()
        self.progress_bar = QProgressBar(central)
        self.progress_bar.setObjectName("progressBar")
        self.progress_bar.setRange(0, 1000)
        self.progress_bar.setValue(0)
        self.cancel_btn = QPushButton(central)
        self.cancel_btn.setObjectName("cancelButton")
        self.cancel_btn.setEnabled(False)
        self.cancel_btn.clicked.connect(self.on_cancel_clicked)
        row2.addWidget(self.progress_bar, 1)
        row2.addWidget(self.cancel_btn)
        root.addLayout(row2)

        self.status_label = QLabel("", central)
        self.status_label.setObjectName("statusLabel")
        root.addWidget(self.status_label)

        # Row 3: folder / settings / open folder
        row3 = QHBoxLayout()
        self.open_folder_btn = QPushButton(central)
        self.open_folder_btn.setObjectName("openFolderButton")
        self.open_folder_btn.clicked.connect(self.on_open_folder_clicked)
        self.settings_btn = QPushButton(central)
        self.settings_btn.setObjectName("settingsButton")
        self.settings_btn.clicked.connect(self.open_settings)
        self.folder_label = QLabel(self.settings.save_dir, central)
        self.folder_label.setObjectName("folderLabel")
        self.folder_label.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        row3.addWidget(self.open_folder_btn)
        row3.addWidget(self.settings_btn)
        row3.addStretch(1)
        root.addLayout(row3)
        root.addWidget(self.folder_label)

        # Log
        log_title = QLabel(central)
        log_title.setObjectName("logTitle")
        root.addWidget(log_title)
        self.log_view = QPlainTextEdit(central)
        self.log_view.setObjectName("logView")
        self.log_view.setReadOnly(True)
        mono = QFont("Menlo")
        mono.setStyleHint(QFont.StyleHint.Monospace)
        mono.setPointSize(11)
        self.log_view.setFont(mono)
        root.addWidget(self.log_view, 1)

        self.setCentralWidget(central)

    # --------------------------------------------------------- localisation
    def retranslate(self) -> None:
        """Apply all texts from the active locale (called at startup/switch)."""
        t = i18n.t
        self.setWindowTitle(f"{APP_NAME} {__version__}")
        self.url_edit.setPlaceholderText(t("download.url_placeholder"))
        self.download_btn.setText(t("download.button"))
        self.cancel_btn.setText(t("download.cancel"))
        self.open_folder_btn.setText(t("download.open_folder"))
        self.settings_btn.setText(t("settings.title"))
        log_title = self.findChild(QLabel, "logTitle")
        if log_title:
            log_title.setText(t("log.title"))

    # ------------------------------------------------------------ logging
    def append_log(self, message: str) -> None:
        ts = datetime.now().strftime("%H:%M:%S")
        self.log_view.appendPlainText(f"[{ts}] {message}")

    # ------------------------------------------------------------ actions
    def validate_url(self, text: str) -> str | None:
        """Return a normalised supported URL or ``None`` (and show the error)."""
        url = extract_video_url(text)
        if not url:
            self.show_validation_error(i18n.t("download.invalid_url"))
            return None
        self.error_label.setVisible(False)
        return url

    def show_validation_error(self, message: str) -> None:
        self.error_label.setText(message)
        self.error_label.setVisible(True)
        self.url_edit.setProperty("invalid", True)
        self.url_edit.style().unpolish(self.url_edit)
        self.url_edit.style().polish(self.url_edit)

    def on_download_clicked(self) -> None:
        if self._current_task is not None:
            self.append_log(i18n.t("download.already_running"))
            return
        url = self.validate_url(self.url_edit.text())
        if not url:
            return
        self.start_download(url)

    def start_download(self, url: str, playlist: bool = True) -> DownloadTask:
        """Detect playlists, ask the user if needed, then queue a task."""
        count = detect_playlist(url)
        if count > 1:
            choice = self.ask_playlist(url, count)
            if choice == "cancel":
                self.append_log(i18n.t("playlist.cancel"))
                return None  # type: ignore[return-value]
            playlist = choice == "all"
        task = DownloadTask(
            url=url,
            save_dir=self.settings.save_dir,
            cookies_browser=self.settings.cookies_browser,
            ffmpeg_location=ffmpeg_path(),
            playlist=playlist,
            parent=self,
        )
        sig = task.signals
        sig.progress.connect(self._on_progress)
        sig.log.connect(self.append_log)
        sig.finished.connect(self._on_finished)
        sig.error.connect(self._on_error)
        self._current_task = task
        self.download_btn.setEnabled(False)
        self.cancel_btn.setEnabled(True)
        self.progress_bar.setValue(0)
        self.append_log(i18n.t("download.started"))
        self._pool.start(task)
        return task

    def ask_playlist(self, url: str, count: int) -> str:
        """Dialog for multi-entry URLs: all / first only / cancel."""
        from PySide6.QtWidgets import QMessageBox

        box = QMessageBox(self)
        box.setWindowTitle(i18n.t("playlist.question_title"))
        box.setText(i18n.t("playlist.question", count=count))
        all_btn = box.addButton(i18n.t("playlist.all"), QMessageBox.ButtonRole.AcceptRole)
        first_btn = box.addButton(i18n.t("playlist.first"), QMessageBox.ButtonRole.DestructiveRole)
        cancel_btn = box.addButton(i18n.t("playlist.cancel"), QMessageBox.ButtonRole.RejectRole)
        box.exec()
        clicked = box.clickedButton()
        if clicked is all_btn:
            return "all"
        if clicked is first_btn:
            return "first"
        return "cancel"

    def on_cancel_clicked(self) -> None:
        if self._current_task is not None:
            self._current_task.cancel()
            self.append_log(i18n.t("download.cancel"))
            self.cancel_btn.setEnabled(False)

    def on_open_folder_clicked(self) -> None:
        open_in_file_manager(self.settings.save_dir)

    # ---------------------------------------------------------- task events
    def _on_progress(self, percent: float, text: str) -> None:
        self.progress_bar.setValue(int(percent * 10))
        if text:
            self.status_label.setText(text)

    def _on_finished(self, filename: str) -> None:
        self.progress_bar.setValue(self.progress_bar.maximum())
        name = os.path.basename(filename) if os.path.isfile(filename) else filename
        self.status_label.setText(i18n.t("download.finished", name=name))
        self.append_log(i18n.t("download.finished", name=name))
        self.tray.notify(
            i18n.t("notifications.download_finished"),
            name,
            payload=filename if os.path.isfile(filename) else self.settings.save_dir,
        )
        self._task_done()

    def _on_error(self, message: str) -> None:
        self.status_label.setText("")
        self.append_log(i18n.t("download.error", message=message))
        self.show_validation_error(message)
        self.tray.notify(i18n.t("notifications.download_error"), message)
        self._task_done(reset_progress=True)

    def _task_done(self, reset_progress: bool = False) -> None:
        self._current_task = None
        self.download_btn.setEnabled(True)
        self.cancel_btn.setEnabled(False)
        if reset_progress:
            self.progress_bar.setValue(0)

    # ------------------------------------------------------------ clipboard
    def _on_clipboard_url(self, url: str) -> None:
        """Highlight the input and offer (never auto-) downloading."""
        self.url_edit.setText(url)
        self.url_edit.setProperty("highlighted", True)
        self.url_edit.style().unpolish(self.url_edit)
        self.url_edit.style().polish(self.url_edit)
        self.url_edit.setFocus()
        if url != self._last_notified_url:
            self._last_notified_url = url
            self.tray.notify(
                i18n.t("notifications.clipboard_title"),
                i18n.t("notifications.clipboard_body"),
                payload="",
            )

    def clear_highlight(self) -> None:
        self.url_edit.setProperty("highlighted", False)
        self.url_edit.style().unpolish(self.url_edit)
        self.url_edit.style().polish(self.url_edit)

    # ------------------------------------------------------------- settings
    def open_settings(self) -> None:
        dlg = SettingsDialog(self.settings, self)
        if dlg.exec() == QDialog.DialogCode.Accepted:
            self.apply_settings()

    def apply_settings(self) -> None:
        """Re-read persisted settings and update live behaviour."""
        old_lang = i18n.current_language()
        i18n.set_language(self.settings.language)
        self.folder_label.setText(self.settings.save_dir)
        self.clipboard_watcher.enabled = self.settings.watch_clipboard
        if i18n.current_language() != old_lang:
            self.retranslate()
            self.tray.retranslate()
        self.settings_changed.emit()

    # ----------------------------------------------------------------- tray
    def show_and_raise(self) -> None:
        self.showNormal()
        self.raise_()
        self.activateWindow()

    def closeEvent(self, event) -> None:  # noqa: N802 — Qt naming
        if self.settings.close_to_tray and self.tray.available and not self._force_close:
            event.ignore()
            self.hide()
            self.tray.notify(
                APP_NAME,
                i18n.t("tray.tooltip"),
                payload="",
                msecs=3000,
            )
        else:
            event.accept()

    def _quit_app(self) -> None:
        from PySide6.QtWidgets import QApplication

        self._force_close = True
        if self._current_task is not None:
            self._current_task.cancel()
        self.tray._tray.hide() if self.tray.available else None
        QApplication.instance().quit()

    # ------------------------------------------------------ notifications
    def _on_notification_clicked(self, path: str) -> None:
        target = path if os.path.isdir(path) else os.path.dirname(path)
        open_in_file_manager(target)
        self.show_and_raise()


class _UrlLineEdit(QLineEdit):
    """URL input with stylesheet-driven validation/clipboard highlight states."""

    pass
