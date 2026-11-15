"""A synthetic mouth clip laid out the way the iPhone crop is: mouth centred, 64 px wide, eyes level."""

from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from silentml.constants import CROP_LANDMARK_ORDER, MOUTH_CROP_SIZE

# Crop pixels for an unmirrored face. The mouth spans 3 widths' worth of crop (192 / 3 = 64 px)
# and the eyes sit about 1.4 mouth widths above its centre, as on the real iPhone crop.
LANDMARKS = {
    "eyeOuterLowX": (30, 8),
    "eyeInnerLowX": (72, 10),
    "eyeInnerHighX": (120, 10),
    "eyeOuterHighX": (162, 8),
    "noseBridge": (96, 16),
    "noseTip": (96, 52),
    "noseBase": (96, 68),
    "mouthCornerLowX": (64, 96),
    "mouthCornerHighX": (128, 96),
    "upperLipCentre": (96, 88),
    "lowerLipCentre": (96, 104),
    "chin": (96, 160),
}
MOUTH_CENTRE = (96.0, 96.0)


def landmark_array() -> np.ndarray:
    return np.array([LANDMARKS[name] for name in CROP_LANDMARK_ORDER], dtype=np.float32)


def frames_with_dot(count: int, centre=MOUTH_CENTRE) -> np.ndarray:
    """Dim frames with a bright 5x5 dot at the mouth centre, so alignment can be checked."""
    frames = np.full((count, MOUTH_CROP_SIZE, MOUTH_CROP_SIZE), 40, dtype=np.uint8)
    x, y = int(round(centre[0])), int(round(centre[1]))
    frames[:, y - 2 : y + 3, x - 2 : x + 3] = 250
    return frames


@dataclass
class FakeSession:
    """The fields of silentml.data.Session that preprocessing reads."""

    mouth: np.ndarray
    mouth_ts: np.ndarray
    mouth_landmarks: np.ndarray
    path: Path = Path("synthetic")
    manifest: dict = field(default_factory=dict)


def session(count: int = 40, t0: float = 1000.0) -> FakeSession:
    landmarks = np.repeat(landmark_array()[None], count, axis=0)
    return FakeSession(frames_with_dot(count), t0 + np.arange(count) / 25.0, landmarks)
