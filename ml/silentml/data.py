"""Session loader for the on-disk format written by Tacit Type's SessionStore.

A session folder holds manifest.json, face.bin and audio.wav. The Swift side is
Packages/TacitKit/Sources/TacitKit/Model/SessionStore.swift. tests/test_data.py reads a fixture
that the Swift tests keep current, so the two sides can't drift.
"""

from __future__ import annotations

import json
import wave
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from .constants import (
    AUDIO_SAMPLE_RATE,
    FACE_FILE_HEADER_DTYPE,
    FACE_FILE_MAGIC,
    FACE_FRAME_DTYPE,
    FEATURE_SCHEMA_VERSION,
    LIP_VERTEX_COUNT,
)

# Columns of Session.face: 52 blendshapes, 16 head transform values, 64 x 3 lip vertices.
BLEND_SHAPE_COLUMNS = slice(0, 52)
HEAD_TRANSFORM_COLUMNS = slice(52, 68)
LIP_VERTEX_COLUMNS = slice(68, 68 + LIP_VERTEX_COUNT * 3)
FACE_FEATURE_COUNT = LIP_VERTEX_COLUMNS.stop

TRACKED_FLAG = 1 << 0


class SessionFormatError(ValueError):
    pass


@dataclass
class Session:
    face: np.ndarray  # [T, 260] float32, columns as above
    face_ts: np.ndarray  # [T] float64, iPhone host-clock seconds
    audio: np.ndarray  # [S] int16, 16 kHz mono
    audio_t0: float  # host-clock time of audio[0], same clock as face_ts
    manifest: dict
    tracked: np.ndarray  # [T] bool, False where ARKit had no face and the row is zeros
    path: Path


def read_face_file(path: Path) -> np.ndarray:
    """Returns the frames of a face.bin as a structured array of FACE_FRAME_DTYPE."""
    with open(path, "rb") as file:
        header = np.fromfile(file, dtype=FACE_FILE_HEADER_DTYPE, count=1)
        if len(header) != 1 or header["magic"][0] != FACE_FILE_MAGIC:
            raise SessionFormatError(f"{path}: not a face.bin file")
        schema = int(header["feature_schema_version"][0])
        if schema != FEATURE_SCHEMA_VERSION:
            raise SessionFormatError(f"{path}: feature schema {schema}, expected {FEATURE_SCHEMA_VERSION}")
        if int(header["lip_vertex_count"][0]) != LIP_VERTEX_COUNT:
            raise SessionFormatError(f"{path}: {header['lip_vertex_count'][0]} lip vertices, expected {LIP_VERTEX_COUNT}")
        frames = np.fromfile(file, dtype=FACE_FRAME_DTYPE)
    if len(frames) != int(header["frame_count"][0]):
        raise SessionFormatError(f"{path}: header says {header['frame_count'][0]} frames, file has {len(frames)}")
    return frames


def read_audio_file(path: Path) -> np.ndarray:
    with wave.open(str(path), "rb") as file:
        if (file.getnchannels(), file.getsampwidth(), file.getframerate()) != (1, 2, AUDIO_SAMPLE_RATE):
            raise SessionFormatError(f"{path}: expected 16 kHz mono 16-bit PCM")
        return np.frombuffer(file.readframes(file.getnframes()), dtype="<i2")


def load_session(path: Path | str) -> Session:
    path = Path(path)
    manifest = json.loads((path / "manifest.json").read_text())
    if manifest["featureSchemaVersion"] != FEATURE_SCHEMA_VERSION:
        raise SessionFormatError(
            f"{path}: feature schema {manifest['featureSchemaVersion']}, expected {FEATURE_SCHEMA_VERSION}"
        )
    frames = read_face_file(path / "face.bin")
    face = np.concatenate(
        [frames["blend_shapes"], frames["head_transform"], frames["lip_vertices"].reshape(len(frames), -1)],
        axis=1,
    )
    audio = read_audio_file(path / "audio.wav")
    audio_t0 = manifest.get("firstAudioTs")
    return Session(
        face=face,
        face_ts=frames["timestamp"].copy(),
        audio=audio,
        audio_t0=float("nan") if audio_t0 is None else float(audio_t0),
        manifest=manifest,
        tracked=(frames["tracking_flags"] & TRACKED_FLAG) != 0,
        path=path,
    )


def iter_sessions(root: Path | str, style: str | None = None, ok_only: bool = True) -> Iterator[Session]:
    """Yields the sessions under root (<root>/<day>/<sessionId>/), in path order.

    style keeps one speechStyle (aloud, whisper, silent or negative).
    ok_only skips takes the Recorder flagged (quality.ok is false).
    """
    for manifest_path in sorted(Path(root).glob("*/*/manifest.json")):
        manifest = json.loads(manifest_path.read_text())
        if style is not None and manifest["speechStyle"] != style:
            continue
        if ok_only and not manifest["quality"]["ok"]:
            continue
        yield load_session(manifest_path.parent)
