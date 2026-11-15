"""Session loader for the on-disk format written by Tacit Type's SessionStore.

A session folder holds manifest.json, face.bin and audio.wav, plus mouth.mp4 and mouth.bin when
the iPhone sent mouth video, and transcript.json once the label job or live dictation wrote one. The Swift side is
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
    MOUTH_CROP_SIZE,
    MOUTH_FILE_HEADER_DTYPE,
    MOUTH_FILE_MAGIC,
    MOUTH_FILE_VERSION,
    mouth_record_dtype,
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
    mouth: np.ndarray | None = None  # [N, 192, 192] uint8 grayscale crops, 0 ... 255
    mouth_ts: np.ndarray | None = None  # [N] float64, same clock as face_ts
    mouth_landmarks: np.ndarray | None = None  # [N, 12, 2] float32, crop pixels, CROP_LANDMARK_ORDER
    # transcript.json: {text, words: [{w, start, end, p}], model, createdAt, wer?}. Word times are
    # seconds from audio_t0. words is empty for live dictation. wer is against promptText.
    transcript: dict | None = None


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


def read_mouth_file(path: Path) -> np.ndarray:
    """Returns the records of a mouth.bin as a structured array of mouth_record_dtype()."""
    with open(path, "rb") as file:
        header = np.fromfile(file, dtype=MOUTH_FILE_HEADER_DTYPE, count=1)
        if len(header) != 1 or header["magic"][0] != MOUTH_FILE_MAGIC:
            raise SessionFormatError(f"{path}: not a mouth.bin file")
        version = int(header["version"][0])
        if version != MOUTH_FILE_VERSION:
            raise SessionFormatError(f"{path}: mouth file version {version}, expected {MOUTH_FILE_VERSION}")
        records = np.fromfile(file, dtype=mouth_record_dtype(int(header["landmark_count"][0])))
    if len(records) != int(header["frame_count"][0]):
        raise SessionFormatError(f"{path}: header says {header['frame_count'][0]} frames, file has {len(records)}")
    return records


def read_mouth_video(path: Path) -> np.ndarray:
    """Decodes mouth.mp4 to [N, 192, 192] uint8.

    The Mac writes video range (luma 16 ... 235), so this expands it back to 0 ... 255 the same way
    `MouthVideo.toFullRange` does in Swift.
    """
    import av  # imported here so face-only work doesn't need PyAV

    frames = []
    with av.open(str(path)) as container:
        for frame in container.decode(video=0):
            if frame.format.name not in ("yuv420p", "nv12"):
                raise SessionFormatError(f"{path}: unexpected pixel format {frame.format.name}")
            plane = frame.planes[0]  # Y, untouched by any range conversion
            luma = np.frombuffer(plane, dtype=np.uint8).reshape(plane.height, plane.line_size)
            frames.append(luma[:, : frame.width])
    if not frames:
        return np.zeros((0, MOUTH_CROP_SIZE, MOUTH_CROP_SIZE), dtype=np.uint8)
    video = np.stack(frames).astype(np.int32)
    if video.shape[1:] != (MOUTH_CROP_SIZE, MOUTH_CROP_SIZE):
        raise SessionFormatError(f"{path}: frames are {video.shape[2]}x{video.shape[1]}, expected {MOUTH_CROP_SIZE}")
    return np.clip(((video - 16) * 255 + 109) // 219, 0, 255).astype(np.uint8)


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
    mouth = mouth_ts = mouth_landmarks = None
    if (path / "mouth.bin").exists():
        records = read_mouth_file(path / "mouth.bin")
        mouth = read_mouth_video(path / "mouth.mp4")
        if len(mouth) != len(records):
            raise SessionFormatError(f"{path}: mouth.mp4 has {len(mouth)} frames, mouth.bin has {len(records)}")
        mouth_ts = records["timestamp"].copy()
        mouth_landmarks = records["landmarks"].copy()
    transcript_path = path / "transcript.json"
    transcript = json.loads(transcript_path.read_text()) if transcript_path.exists() else None
    return Session(
        face=face,
        face_ts=frames["timestamp"].copy(),
        audio=audio,
        audio_t0=float("nan") if audio_t0 is None else float(audio_t0),
        manifest=manifest,
        tracked=(frames["tracking_flags"] & TRACKED_FLAG) != 0,
        path=path,
        mouth=mouth,
        mouth_ts=mouth_ts,
        mouth_landmarks=mouth_landmarks,
        transcript=transcript,
    )


def iter_sessions(root: Path | str, style: str | None = None, ok_only: bool = True) -> Iterator[Session]:
    """Yields the sessions under root (<root>/<day>/<sessionId>/), in path order.

    style keeps one speechStyle (aloud, whisper, silent or negative).
    ok_only skips takes the Recorder or the label job flagged (quality.ok is false).
    """
    for manifest_path in sorted(Path(root).glob("*/*/manifest.json")):
        manifest = json.loads(manifest_path.read_text())
        if style is not None and manifest["speechStyle"] != style:
            continue
        if ok_only and not manifest["quality"]["ok"]:
            continue
        yield load_session(manifest_path.parent)
