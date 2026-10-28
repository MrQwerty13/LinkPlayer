"""GUI tests for MainWindow (pytest-qt). DownloadTask is mocked — no network."""

from __future__ import annotations

import pytest

from linkplayer.main_window import MainWindow


@pytest.fixture()
def window(isolated_settings, download_dir, monkeypatch, qtbot):
    """MainWindow with Settings isolated and playlist detection stubbed out."""
    isolated_settings.save_dir = download_dir
    monkeypatch.setattr("linkplayer.main_window.detect_playlist", lambda url, opts=None: 1)
    w = MainWindow(isolated_settings)
    qtbot.addWidget(w)
    yield w
    # Do not let a queued pool task run after teardown.
    if w._current_task is not None:
        w._current_task.cancel()


def test_window_created_with_url_field_and_button(window):
    assert window.url_edit is not None
    assert window.download_btn is not None
    assert window.download_btn.text()  # localised label present
    assert window.progress_bar is not None
    assert window.log_view is not None
    assert window.open_folder_btn is not None


def test_empty_url_click_shows_validation_error_no_task(window, mocker):
    create_spy = mocker.spy(__import__("linkplayer.downloader", fromlist=["DownloadTask"]), "DownloadTask")
    window.url_edit.setText("")
    mocker.patch.object(window, "_pool")  # safety: nothing should be started
    window.download_btn.click()
    assert window.error_label.isVisible() or window.error_label.text()
    assert window.error_label.text() == pytest.importorskip(
        "linkplayer.i18n").t("download.invalid_url")
    create_spy.assert_not_called()
    assert window._current_task is None


def test_invalid_url_does_not_create_task(window, mocker):
    window.url_edit.setText("https://example.com/not-a-video")
    mock_cls = mocker.patch("linkplayer.main_window.DownloadTask")
    window.download_btn.click()
    mock_cls.assert_not_called()
    assert window._current_task is None


def test_valid_url_creates_download_task(window, mocker):
    fake_task = mocker.MagicMock()
    fake_task.signals = __import__(
        "linkplayer.downloader", fromlist=["DownloadSignals"]
    ).DownloadSignals()
    mock_cls = mocker.patch("linkplayer.main_window.DownloadTask", return_value=fake_task)
    mocker.patch.object(window._pool, "start")
    window.url_edit.setText("https://youtu.be/dQw4w9WgXcQ")
    window.download_btn.click()
    mock_cls.assert_called_once()
    kwargs = mock_cls.call_args.kwargs
    assert kwargs["url"] == "https://youtu.be/dQw4w9WgXcQ"
    assert window._current_task is fake_task
    assert window.cancel_btn.isEnabled()
    assert not window.download_btn.isEnabled()


def test_progress_signal_updates_progressbar(window, mocker):
    fake_task = mocker.MagicMock()
    fake_task.signals = __import__(
        "linkplayer.downloader", fromlist=["DownloadSignals"]
    ).DownloadSignals()
    mocker.patch("linkplayer.main_window.DownloadTask", return_value=fake_task)
    mocker.patch.object(window._pool, "start")
    window.url_edit.setText("https://youtu.be/dQw4w9WgXcQ")
    window.download_btn.click()
    # Simulate the worker emitting progress (direct connection in-process).
    fake_task.signals.progress.emit(42.5, "1 MiB/s")
    assert window.progress_bar.value() == 425
    assert "1 MiB/s" in window.status_label.text()


def test_finished_signal_restores_buttons_and_logs(window, mocker, tmp_path):
    fake_task = mocker.MagicMock()
    fake_task.signals = __import__(
        "linkplayer.downloader", fromlist=["DownloadSignals"]
    ).DownloadSignals()
    mocker.patch("linkplayer.main_window.DownloadTask", return_value=fake_task)
    mocker.patch.object(window._pool, "start")
    window.url_edit.setText("https://youtu.be/dQw4w9WgXcQ")
    window.download_btn.click()
    f = tmp_path / "video.mp4"
    f.write_bytes(b"x")
    fake_task.signals.finished.emit(str(f))
    assert window._current_task is None
    assert window.download_btn.isEnabled()
    assert not window.cancel_btn.isEnabled()
    assert "video.mp4" in window.log_view.toPlainText()


def test_error_signal_shows_message(window, mocker):
    fake_task = mocker.MagicMock()
    fake_task.signals = __import__(
        "linkplayer.downloader", fromlist=["DownloadSignals"]
    ).DownloadSignals()
    mocker.patch("linkplayer.main_window.DownloadTask", return_value=fake_task)
    mocker.patch.object(window._pool, "start")
    window.url_edit.setText("https://youtu.be/dQw4w9WgXcQ")
    window.download_btn.click()
    fake_task.signals.error.emit("boom")
    assert "boom" in window.log_view.toPlainText()
    assert window._current_task is None


def test_cancel_button_cancels_task(window, mocker):
    real_task = mocker.MagicMock()
    real_task.signals = __import__(
        "linkplayer.downloader", fromlist=["DownloadSignals"]
    ).DownloadSignals()
    mocker.patch("linkplayer.main_window.DownloadTask", return_value=real_task)
    mocker.patch.object(window._pool, "start")
    window.url_edit.setText("https://youtu.be/dQw4w9WgXcQ")
    window.download_btn.click()
    window.cancel_btn.click()
    real_task.cancel.assert_called_once()


def test_second_download_while_running_is_refused(window, mocker):
    real_task = mocker.MagicMock()
    real_task.signals = __import__(
        "linkplayer.downloader", fromlist=["DownloadSignals"]
    ).DownloadSignals()
    mock_cls = mocker.patch("linkplayer.main_window.DownloadTask", return_value=real_task)
    mocker.patch.object(window._pool, "start")
    window.url_edit.setText("https://youtu.be/dQw4w9WgXcQ")
    window.download_btn.click()
    assert mock_cls.call_count == 1
    window.download_btn.setEnabled(True)  # simulate rapid second click
    window.on_download_clicked()
    assert mock_cls.call_count == 1  # no second task created


def test_playlist_dialog_all_choice(window, mocker):
    """n_entries>1 → dialog; 'all' keeps playlist=True, 'first' sets False."""
    mocker.patch("linkplayer.main_window.detect_playlist", lambda url, opts=None: 3)
    captured = {}
    real_cls = __import__("linkplayer.downloader", fromlist=["DownloadTask"]).DownloadTask

    def spy(*a, **kw):
        captured.update(kw)
        t = real_cls(*a, **kw)
        t.run = lambda: None  # never actually hit yt-dlp
        return t

    mocker.patch("linkplayer.main_window.DownloadTask", side_effect=spy)
    mocker.patch.object(window, "ask_playlist", return_value="all")
    mocker.patch.object(window._pool, "start")
    window.url_edit.setText("https://www.youtube.com/playlist?list=PLabc123456789")
    window.download_btn.click()
    assert captured.get("playlist") is True

    window._current_task = None
    window.download_btn.setEnabled(True)
    captured.clear()
    mocker.patch.object(window, "ask_playlist", return_value="first")
    window.download_btn.click()
    assert captured.get("playlist") is False


def test_playlist_dialog_cancel_aborts(window, mocker):
    mocker.patch("linkplayer.main_window.detect_playlist", lambda url, opts=None: 3)
    mock_cls = mocker.patch("linkplayer.main_window.DownloadTask")
    mocker.patch.object(window, "ask_playlist", return_value="cancel")
    window.url_edit.setText("https://www.youtube.com/playlist?list=PLabc123456789")
    window.download_btn.click()
    mock_cls.assert_not_called()
    assert window._current_task is None


def test_clipboard_notification_highlights_input(window, mocker):
    notify = mocker.patch.object(window.tray, "notify")
    url = "https://youtu.be/dQw4w9WgXcQ"
    window.clipboard_watcher.new_url.emit(url)
    assert window.url_edit.text() == url
    notify.assert_called_once()
    # duplicate → no second notification
    window.clipboard_watcher.new_url.emit(url)
    assert notify.call_count == 1


def test_retranslate_switches_language_at_runtime(window, mocker):
    from linkplayer import i18n

    i18n.set_language("ru")
    window.retranslate()
    assert window.download_btn.text() == "Скачать"
    i18n.set_language("en")
    window.retranslate()
    assert window.download_btn.text() == "Download"
    i18n.set_language("en")
