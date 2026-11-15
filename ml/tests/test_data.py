"""Reads the fixture sessions that TacitKit's SessionStoreTests writes and checks every field.

The expected values repeat the formulas in SessionFixture (SessionStoreTests.swift).
If the Swift test `fixtureForPythonIsCurrent` fails, regenerate with
`TACIT_WRITE_FIXTURE=1 make test-swift` and update this file to match.
"""

from pathlib import Path

import numpy as np
import pytest

from silentml.constants import CROP_LANDMARK_COUNT, FACE_FILE_HEADER_DTYPE, MOUTH_FILE_HEADER_DTYPE
from silentml.data import (
    BLEND_SHAPE_COLUMNS,
    FACE_FEATURE_COUNT,
    HEAD_TRANSFORM_COLUMNS,
    LIP_VERTEX_COLUMNS,
    SessionFormatError,
    iter_sessions,
    load_session,
)

ROOT = Path(__file__).parent / "fixtures" / "sessions"
ALOUD = ROOT / "2026-11-05" / "0A1B2C3D-0000-4000-8000-000000000001"
SILENT = ROOT / "2026-11-05" / "0A1B2C3D-0000-4000-8000-000000000002"

FACE_T0 = 81234.512
AUDIO_T0 = 81234.498
MOUTH_T0 = 81234.52
f32 = np.float32


def expected_frame(i: int) -> np.ndarray:
    blend = np.array([f32(i * 100 + j) / f32(1000) for j in range(52)], dtype=f32)
    head = np.array([f32(k - i) / f32(8) for k in range(16)], dtype=f32)
    lips = np.array(
        [[f32(v) / f32(1000), f32(i) / f32(1000), f32(v * i) / f32(-1000)] for v in range(64)], dtype=f32
    )
    return np.concatenate([blend, head, lips.reshape(-1)])


def expected_audio(count: int) -> np.ndarray:
    return np.array([(n * 37) % 2001 - 1000 for n in range(count)], dtype=np.int16)


def expected_mouth_pixels(k: int) -> np.ndarray:
    y, x = np.mgrid[0:192, 0:192]
    return np.clip(30 + x // 2 + y // 4 + 10 * k, 0, 255).astype(np.uint8)


def expected_mouth_landmarks(k: int) -> np.ndarray:
    return np.array([[slot * 10 + k, slot * 5 - 20.5] for slot in range(CROP_LANDMARK_COUNT)], dtype=f32)


def test_aloud_session_every_field():
    session = load_session(ALOUD)

    assert session.face.shape == (12, FACE_FEATURE_COUNT) == (12, 260)
    assert session.face.dtype == np.float32
    assert session.face_ts.dtype == np.float64
    np.testing.assert_array_equal(session.face_ts, [FACE_T0 + i / 60 for i in range(12)])
    np.testing.assert_array_equal(session.tracked, [i != 5 for i in range(12)])
    for i in range(12):
        expected = np.zeros(260, dtype=f32) if i == 5 else expected_frame(i)
        np.testing.assert_array_equal(session.face[i], expected)
    assert session.face[3, BLEND_SHAPE_COLUMNS].shape == (52,)
    assert session.face[3, HEAD_TRANSFORM_COLUMNS].shape == (16,)
    assert session.face[3, LIP_VERTEX_COLUMNS].reshape(64, 3)[10, 0] == f32(10) / f32(1000)

    assert session.audio.dtype == np.int16
    np.testing.assert_array_equal(session.audio, expected_audio(3200))
    assert session.audio_t0 == AUDIO_T0
    assert session.path == ALOUD

    assert session.mouth.shape == (5, 192, 192)
    assert session.mouth.dtype == np.uint8
    np.testing.assert_array_equal(session.mouth_ts, [MOUTH_T0 + k * 0.04 for k in range(5)])
    assert session.mouth_landmarks.dtype == np.float32
    for k in range(5):
        np.testing.assert_array_equal(session.mouth_landmarks[k], expected_mouth_landmarks(k))
        # H.264 is lossy, so pixels match the pattern closely rather than exactly.
        error = np.abs(session.mouth[k].astype(int) - expected_mouth_pixels(k))
        assert error.max() <= 4 and error.mean() < 1.5

    assert session.manifest == {
        "sessionId": "0A1B2C3D-0000-4000-8000-000000000001",
        "createdAt": "2026-11-05T00:00:00Z",
        "mode": "record",
        "speechStyle": "aloud",
        "promptId": "harvard-03-07",
        "promptText": "The birch canoe slid on the smooth planks.",
        "sittingId": "0A1B2C3D-0000-4000-8000-0000000000AA",
        "device": {"model": "iPhone16,1", "osVersion": "18.2"},
        "appVersions": {"mac": "0.1.0", "iphone": "0.1.0"},
        "protocolVersion": 1,
        "featureSchemaVersion": 1,
        "firstFaceTs": FACE_T0,
        "firstAudioTs": AUDIO_T0,
        "frameCount": 12,
        "measuredFps": 60,
        "trackedRatio": 11 / 12,
        "droppedFrames": 0,
        "audioGapsFilled": 1,
        "measuredAvOffsetMs": -4.5,
        "mouthFrameCount": 5,
        "mouthFps": 25,
        "meanLuma": 111.5,
        "quality": {"ok": True, "flags": []},
    }

    assert session.transcript == {
        "text": "The birch canoe slid on the smooth planks.",
        "words": [
            {"w": "The", "start": 0.32, "end": 0.41, "p": 0.98},
            {"w": " birch", "start": 0.41, "end": 0.7, "p": 0.875},
        ],
        "model": "openai_whisper-small.en",
        "createdAt": "2026-11-05T00:01:40Z",
        "wer": 0.125,
    }


def test_flagged_silent_session_leaves_optionals_out():
    session = load_session(SILENT)
    assert session.face.shape == (3, 260)
    assert session.tracked.all()
    assert session.mouth is session.mouth_ts is session.mouth_landmarks is session.transcript is None
    np.testing.assert_array_equal(session.face[2], expected_frame(2))
    np.testing.assert_array_equal(session.audio, expected_audio(160))
    assert np.isnan(session.audio_t0)
    assert session.manifest == {
        "sessionId": "0A1B2C3D-0000-4000-8000-000000000002",
        "createdAt": "2026-11-05T00:01:00Z",
        "mode": "silent",
        "speechStyle": "silent",
        "device": {"model": "iPhone16,1", "osVersion": "18.2"},
        "appVersions": {"mac": "0.1.0", "iphone": "0.1.0"},
        "protocolVersion": 1,
        "featureSchemaVersion": 1,
        "frameCount": 3,
        "measuredFps": 60,
        "trackedRatio": 1,
        "droppedFrames": 0,
        "audioGapsFilled": 0,
        "quality": {"ok": False, "flags": ["audible_in_silent", "too_short"]},
    }


def test_face_file_header():
    header = np.fromfile(ALOUD / "face.bin", dtype=FACE_FILE_HEADER_DTYPE, count=1)[0]
    assert header["magic"] == b"SFCE"
    assert (header["feature_schema_version"], header["lip_vertex_count"]) == (1, 64)
    assert (header["frame_count"], header["reserved"]) == (12, 0)


def test_mouth_file_header():
    header = np.fromfile(ALOUD / "mouth.bin", dtype=MOUTH_FILE_HEADER_DTYPE, count=1)[0]
    assert header["magic"] == b"SMTH"
    assert (header["version"], header["landmark_count"], header["frame_count"]) == (1, 12, 5)
    assert (ALOUD / "mouth.bin").stat().st_size == 12 + 5 * (8 + 12 * 8)


def test_iter_sessions_filters():
    def ids(**kwargs):
        return [s.manifest["sessionId"][-1] for s in iter_sessions(ROOT, **kwargs)]

    assert ids() == ["1"]
    assert ids(ok_only=False) == ["1", "2"]
    assert ids(style="silent") == []
    assert ids(style="silent", ok_only=False) == ["2"]
    assert ids(style="aloud") == ["1"]


def test_other_schema_versions_are_rejected(tmp_path):
    for name in ("manifest.json", "audio.wav"):
        (tmp_path / name).write_bytes((ALOUD / name).read_bytes())
    face = bytearray((ALOUD / "face.bin").read_bytes())
    face[4] = 2
    (tmp_path / "face.bin").write_bytes(face)
    with pytest.raises(SessionFormatError, match="feature schema 2"):
        load_session(tmp_path)

    face[4] = 1
    (tmp_path / "face.bin").write_bytes(face[:-4])
    with pytest.raises(SessionFormatError, match="frames"):
        load_session(tmp_path)


def test_mouth_mismatches_are_rejected(tmp_path):
    for name in ("manifest.json", "audio.wav", "face.bin", "mouth.mp4"):
        (tmp_path / name).write_bytes((ALOUD / name).read_bytes())
    mouth = bytearray((ALOUD / "mouth.bin").read_bytes())
    mouth[4] = 2
    (tmp_path / "mouth.bin").write_bytes(mouth)
    with pytest.raises(SessionFormatError, match="mouth file version 2"):
        load_session(tmp_path)

    mouth[4] = 1
    (tmp_path / "mouth.bin").write_bytes(mouth[:-104])
    with pytest.raises(SessionFormatError, match="frames"):
        load_session(tmp_path)

    mouth[8] = 4  # header says 4 frames and the file holds 4, but mouth.mp4 has 5
    (tmp_path / "mouth.bin").write_bytes(mouth[:-104])
    with pytest.raises(SessionFormatError, match="mouth.mp4 has 5 frames"):
        load_session(tmp_path)
