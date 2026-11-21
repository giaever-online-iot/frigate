"""Snap paths (spec D7). Each raises KeyError if its variable is unset."""
import os
from pathlib import Path


def camera_dir() -> Path:
    return Path(os.environ["SNAP_DATA"]) / "ezviz" / "cameras"


def state_dir() -> Path:
    return Path(os.environ["SNAP_COMMON"]) / "ezviz" / "state"


def ffmpeg() -> str:
    return os.environ["SNAP"] + "/usr/lib/ffmpeg/8.0/bin/ffmpeg"
