"""Resource path resolution that works both from sources and a PyInstaller bundle.

In a frozen (PyInstaller) app, data files are extracted to ``sys._MEIPASS``;
when running from sources they live next to this module.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path


def resource_path(relative: str) -> str:
    """Return an absolute path to a bundled resource.

    ``relative`` is POSIX-style relative to the package root, e.g.
    ``"locales/ru.json"`` or ``"resources/ffmpeg"``.
    """
    base = getattr(sys, "_MEIPASS", None)
    if base:
        candidate = Path(base) / "linkplayer" / relative
        if candidate.exists():
            return str(candidate)
        # Some specs place resources at the MEIPASS root.
        candidate = Path(base) / relative
        if candidate.exists():
            return str(candidate)
    pkg_dir = Path(__file__).resolve().parent
    return str(pkg_dir / relative)


def ffmpeg_path() -> str:
    """Absolute path to the bundled (or system, in dev) ffmpeg binary."""
    name = "ffmpeg"
    bundled = resource_path(os.path.join("resources", name))
    if os.path.exists(bundled):
        return bundled
    # Development fallback: rely on PATH so source runs work without a fetch.
    from shutil import which

    found = which(name)
    if found:
        return found
    return bundled


def ffprobe_path() -> str:
    """Absolute path to the bundled (or system, in dev) ffprobe binary."""
    name = "ffprobe"
    bundled = resource_path(os.path.join("resources", name))
    if os.path.exists(bundled):
        return bundled
    from shutil import which

    found = which(name)
    if found:
        return found
    return bundled
