"""Session loader for the on-disk format written by Tacit Type's SessionStore (M3)."""

from __future__ import annotations

from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path

import numpy as np


@dataclass
class Session:
    face: np.ndarray  # [T, F]
    face_ts: np.ndarray  # [T]
    audio: np.ndarray  # [S]
    audio_t0: float
    manifest: dict


def load_session(path: Path) -> Session:
    raise NotImplementedError("M3")


def iter_sessions(root: Path, style: str | None = None, ok_only: bool = True) -> Iterator[Session]:
    raise NotImplementedError("M3")
