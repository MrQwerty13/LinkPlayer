"""Smoke test for the built bundle — skipped unless dist/LinkPlayer.app exists."""

from __future__ import annotations

import os
import stat

import pytest

APP_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "dist", "LinkPlayer.app",
)

pytestmark = pytest.mark.slow


@pytest.mark.skipif(not os.path.isdir(APP_PATH), reason="dist/LinkPlayer.app not built")
def test_bundle_binary_exists_and_executable():
    macos_dir = os.path.join(APP_PATH, "Contents", "MacOS")
    binaries = [
        os.path.join(macos_dir, f)
        for f in os.listdir(macos_dir)
        if os.path.isfile(os.path.join(macos_dir, f))
    ] if os.path.isdir(macos_dir) else []
    assert binaries, "no executable inside Contents/MacOS"
    for b in binaries:
        assert os.stat(b).st_mode & stat.S_IXUSR, f"{b} is not executable"


@pytest.mark.skipif(not os.path.isdir(APP_PATH), reason="dist/LinkPlayer.app not built")
def test_bundle_info_plist_keys():
    plist = os.path.join(APP_PATH, "Contents", "Info.plist")
    assert os.path.exists(plist)
    data = open(plist, "rb").read()
    for needle in (b"com.linkplayer.app", b"NSHighResolutionCapable", b"LSMinimumSystemVersion"):
        assert needle in data
