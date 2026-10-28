"""Settings dialog: download folder, language, cookies browser, toggles."""

from __future__ import annotations

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QCheckBox,
    QComboBox,
    QDialog,
    QDialogButtonBox,
    QFileDialog,
    QFormLayout,
    QHBoxLayout,
    QLineEdit,
    QMessageBox,
    QPushButton,
    QVBoxLayout,
    QWidget,
)

from linkplayer import i18n
from linkplayer.settings import Settings, is_valid_dir

_BROWSER_KEYS = {
    "": "settings.browser_none",
    "safari": "settings.browser_safari",
    "chrome": "settings.browser_chrome",
    "firefox": "settings.browser_firefox",
    "edge": "settings.browser_edge",
}


class SettingsDialog(QDialog):
    """Modal editor for all persisted preferences. Writes on Accept."""

    def __init__(self, settings: Settings, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._settings = settings
        self.setWindowTitle(i18n.t("settings.title"))
        self.setModal(True)
        self.setMinimumWidth(440)

        form = QFormLayout()
        form.setLabelAlignment(
            Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter
        )

        # --- save_dir -------------------------------------------------------
        dir_row = QHBoxLayout()
        self.dir_edit = QLineEdit(settings.save_dir)
        self.dir_edit.setObjectName("dirEdit")
        self.browse_btn = QPushButton(i18n.t("settings.browse"))
        self.browse_btn.setObjectName("browseButton")
        self.browse_btn.clicked.connect(self._browse)
        dir_row.addWidget(self.dir_edit, 1)
        dir_row.addWidget(self.browse_btn)
        dir_widget = QWidget()
        dir_widget.setLayout(dir_row)
        form.addRow(i18n.t("settings.save_dir"), dir_widget)

        # --- language -------------------------------------------------------
        self.lang_combo = QComboBox()
        self.lang_combo.setObjectName("languageCombo")
        self.lang_combo.addItem(i18n.t("settings.language_ru"), "ru")
        self.lang_combo.addItem(i18n.t("settings.language_en"), "en")
        idx = self.lang_combo.findData(settings.language)
        self.lang_combo.setCurrentIndex(idx if idx >= 0 else 1)
        form.addRow(i18n.t("settings.language"), self.lang_combo)

        # --- cookies browser -------------------------------------------------
        self.browser_combo = QComboBox()
        self.browser_combo.setObjectName("browserCombo")
        for value, key in _BROWSER_KEYS.items():
            self.browser_combo.addItem(i18n.t(key), value)
        cur = settings.cookies_browser or ""
        bidx = self.browser_combo.findData(cur)
        self.browser_combo.setCurrentIndex(bidx if bidx >= 0 else 0)
        form.addRow(i18n.t("settings.cookies_browser"), self.browser_combo)

        # --- checkboxes -------------------------------------------------------
        self.clipboard_check = QCheckBox(i18n.t("settings.watch_clipboard"))
        self.clipboard_check.setObjectName("clipboardCheck")
        self.clipboard_check.setChecked(settings.watch_clipboard)
        self.tray_check = QCheckBox(i18n.t("settings.close_to_tray"))
        self.tray_check.setObjectName("trayCheck")
        self.tray_check.setChecked(settings.close_to_tray)

        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Save | QDialogButtonBox.StandardButton.Cancel
        )
        save_btn = buttons.button(QDialogButtonBox.StandardButton.Save)
        save_btn.setText(i18n.t("settings.ok"))
        cancel_btn = buttons.button(QDialogButtonBox.StandardButton.Cancel)
        cancel_btn.setText(i18n.t("settings.cancel"))
        buttons.accepted.connect(self._on_accept)
        buttons.rejected.connect(self.reject)

        root = QVBoxLayout(self)
        root.addLayout(form)
        root.addWidget(self.clipboard_check)
        root.addWidget(self.tray_check)
        root.addStretch(1)
        root.addWidget(buttons)

    # ------------------------------------------------------------------ slots
    def _browse(self) -> None:
        start = self.dir_edit.text() or self._settings.save_dir
        chosen = QFileDialog.getExistingDirectory(self, i18n.t("settings.save_dir"), start)
        if chosen:
            self.dir_edit.setText(chosen)

    def _on_accept(self) -> None:
        path = self.dir_edit.text().strip()
        if not is_valid_dir(path):
            QMessageBox.warning(self, i18n.t("settings.title"), i18n.t("settings.invalid_dir"))
            path = self._settings.save_dir  # resets to default inside setter logic
            self.dir_edit.setText(path)
        self._settings.save_dir = path
        self._settings.language = self.lang_combo.currentData()
        self._settings.cookies_browser = self.browser_combo.currentData() or None
        self._settings.watch_clipboard = self.clipboard_check.isChecked()
        self._settings.close_to_tray = self.tray_check.isChecked()
        self._settings.sync()
        self.accept()
