"""Turns a session's loose 192x192 mouth crops into the 88x88 clips the lip-reading models read.

The iPhone sends a crop 3 mouth widths across plus 12 projected face-mesh landmarks (mouth.bin).
Both models were trained on mouths aligned to `20words_mean_face.npy` with 68-point iBUG
landmarks, then cut to 96x96 around the mouth. Rather than run their face detectors on a crop
that barely holds the eyes, this module places our 12 points at their iBUG indices and hands them
to each model's own alignment code (`VideoProcess` in each repo), so the crop matches training.

Steps, in order:
1. `uniform_indices` puts the frames on an even 25 fps grid, repeating a frame where one dropped.
2. `ibug_landmarks` maps the 12 points to a 68-point array, after `is_mirrored` checks handedness.
   An `AlignmentCorrection`, when one has been fitted, then moves the 8 alignment points.
3. The model's `VideoProcess` aligns each frame to the mean face and cuts a 96x96 mouth patch.
4. `model_input` scales to 0 ... 1, takes the centre 88x88 and normalises (mean 0.421, std 0.165).
"""

from __future__ import annotations

import json
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

from .constants import CROP_LANDMARK_ORDER, MOUTH_CROP_SIZE, MOUTH_FPS

IBUG_POINT_COUNT = 68
# The 68-point indices the models use: alignment fits points 28, 33, 36, 39, 42, 45, 48 and 54 to
# the mean face, and the crop centres on the mean of points 48 to 67.
STABLE_POINTS = (28, 33, 36, 39, 42, 45, 48, 54)
MOUTH_POINTS = range(48, 68)

# iBUG index for each crop landmark, for an unmirrored image. iBUG numbers the subject's right eye
# and right mouth corner first, and in an unmirrored image they sit on the left. Our "low x" slots
# are the subject's right side, so they take those indices.
IBUG_INDEX = {
    "eyeOuterLowX": 36,
    "eyeInnerLowX": 39,
    "eyeInnerHighX": 42,
    "eyeOuterHighX": 45,
    "noseBridge": 28,
    "noseTip": 30,
    "noseBase": 33,
    "mouthCornerLowX": 48,
    "mouthCornerHighX": 54,
    "upperLipCentre": 51,
    "lowerLipCentre": 57,
    "chin": 8,
}
_SLOT = {name: i for i, name in enumerate(CROP_LANDMARK_ORDER)}
_IBUG_MOUTH = (48, 51, 54, 57)  # the mouth points that hold real landmarks
_MOUTH_SLOTS = [_SLOT[n] for n in ("mouthCornerLowX", "mouthCornerHighX", "upperLipCentre", "lowerLipCentre")]

MODEL_CROP = 88
PIXEL_MEAN = 0.421
PIXEL_STD = 0.165
# Both repos' VideoProcess skip a clip shorter than their 12-frame smoothing window.
MIN_FRAMES = 12
CORRECTION_VERSION = 1


class PreprocessError(ValueError):
    pass


def uniform_indices(timestamps: np.ndarray, fps: float = MOUTH_FPS) -> np.ndarray:
    """Indices into the frames for an even fps grid from the first to the last timestamp.

    The iPhone keeps the camera frame nearest each 40 ms tick, so with no drops this is
    0, 1, 2, ... A dropped frame is filled with its nearest neighbour, which keeps the clip's
    length in time right for the model.
    """
    timestamps = np.asarray(timestamps, dtype=np.float64)
    if len(timestamps) < 2:
        return np.zeros(len(timestamps), dtype=np.int64)
    step = 1.0 / fps
    count = int(np.floor((timestamps[-1] - timestamps[0]) / step + 0.5)) + 1
    grid = timestamps[0] + step * np.arange(count)
    after = np.clip(np.searchsorted(timestamps, grid), 1, len(timestamps) - 1)
    before = after - 1
    nearer_after = np.abs(timestamps[after] - grid) < np.abs(timestamps[before] - grid)
    return np.where(nearer_after, after, before)


def is_mirrored(landmarks: np.ndarray) -> bool:
    """True when the subject's right side sits on the right of the crop, as in a mirror.

    The iPhone crop is a rotation of the camera image, so it keeps the image's handedness.
    Judged on the median over the clip so a few bad frames can't flip it.
    """
    points = np.asarray(landmarks, dtype=np.float64)
    spread = points[:, _SLOT["eyeOuterHighX"], 0] - points[:, _SLOT["eyeOuterLowX"], 0]
    spread = spread[np.isfinite(spread)]
    if len(spread) == 0:
        raise PreprocessError("no frame has usable landmarks")
    return bool(np.median(spread) < 0)


def mirror(frames: np.ndarray, landmarks: np.ndarray, size: int = MOUTH_CROP_SIZE) -> tuple[np.ndarray, np.ndarray]:
    """Flips frames and landmarks left to right. Landmarks are in pixel-centre coordinates."""
    flipped = np.array(landmarks, dtype=np.float32, copy=True)
    flipped[..., 0] = (size - 1) - flipped[..., 0]
    return np.ascontiguousarray(frames[:, :, ::-1]), flipped


def ibug_landmarks(landmarks: np.ndarray) -> list[np.ndarray | None]:
    """Places each frame's 12 crop landmarks at their 68-point iBUG indices.

    Slots with no ARKit point are filled so the models' code sees what it needs: the mouth points
    48 to 67 average to the mouth centre (the same centre the iPhone crop uses), and the rest
    repeat the nose tip, which nothing reads. Frames with a non-finite landmark come back as None,
    and the models' VideoProcess interpolates them from their neighbours.
    """
    out: list[np.ndarray | None] = []
    for frame in np.asarray(landmarks, dtype=np.float64):
        if not np.all(np.isfinite(frame)):
            out.append(None)
            continue
        points = np.repeat(frame[_SLOT["noseTip"]][None, :], IBUG_POINT_COUNT, axis=0)
        centre = frame[_MOUTH_SLOTS].mean(axis=0)
        points[list(MOUTH_POINTS)] = centre
        for name, index in IBUG_INDEX.items():
            points[index] = frame[_SLOT[name]]
        # The four real mouth points replace four centre copies, which keeps the mean at the centre.
        out.append(points)
    return out


@dataclass(frozen=True)
class AlignmentCorrection:
    """A fixed shift of the 8 alignment points, so ARKit's points land where iBUG's would.

    ARKit's mesh points don't sit exactly where the iBUG annotators put theirs, and the iPhone
    looks at the face from below. Both show up as the same offset from the mean face on every
    frame. `cropcheck --fit` measures the mean offset of each aligned point and saves it. `apply`
    takes it back out: it maps each frame's offsets into crop pixels through that frame's own
    alignment and subtracts them, then resets the filler mouth points so the patch stays centred
    on the same mouth centre. It is fitted from landmarks only, never from labels.
    """

    offsets: np.ndarray  # [8, 2] mean offset of our aligned STABLE_POINTS from the mean face's, aligned pixels
    reference: np.ndarray  # [8, 2] the mean face's STABLE_POINTS in the aligned frame
    meta: dict | None = None  # where it was fitted from, for the record

    @classmethod
    def fit(cls, residuals: np.ndarray, reference: np.ndarray, **meta) -> "AlignmentCorrection":
        """residuals is [frames, 8, 2], as `cropcheck.residuals` returns them for uncorrected landmarks."""
        residuals = np.asarray(residuals, dtype=np.float64).reshape(-1, len(STABLE_POINTS), 2)
        return cls(residuals.mean(axis=0), np.asarray(reference, dtype=np.float64),
                   {"frames": int(len(residuals)), **meta})

    def apply(self, points: np.ndarray) -> np.ndarray:
        """A corrected copy of one frame's [68, 2] landmarks."""
        import cv2

        stable = list(STABLE_POINTS)
        # The same similarity fit the repos' VideoProcess uses to align a frame.
        transform = cv2.estimateAffinePartial2D(points[stable].astype(np.float32),
                                                self.reference.astype(np.float32), method=cv2.LMEDS)[0]
        if transform is None:
            return points
        to_crop = np.linalg.inv(transform[:, :2])
        centre = points[list(MOUTH_POINTS)].mean(axis=0)
        out = np.array(points, dtype=np.float64, copy=True)
        out[stable] = points[stable] - self.offsets @ to_crop.T
        real = list(_IBUG_MOUTH)
        filler = [i for i in MOUTH_POINTS if i not in real]
        out[filler] = (len(MOUTH_POINTS) * centre - out[real].sum(axis=0)) / len(filler)
        return out

    def save(self, path: Path | str) -> None:
        record = {
            "version": CORRECTION_VERSION,
            "createdAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "points": list(STABLE_POINTS),
            "offsets": self.offsets.round(4).tolist(),
            "reference": self.reference.round(4).tolist(),
            **(self.meta or {}),
        }
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        Path(path).write_text(json.dumps(record, indent=2) + "\n")

    @classmethod
    def load(cls, path: Path | str) -> "AlignmentCorrection":
        record = json.loads(Path(path).read_text())
        if record.get("version") != CORRECTION_VERSION or record.get("points") != list(STABLE_POINTS):
            raise PreprocessError(f"{path} is not a version {CORRECTION_VERSION} alignment correction. Refit it with cropcheck --fit.")
        meta = {"file": str(path), **{k: v for k, v in record.items() if k not in ("version", "points", "offsets", "reference")}}
        return cls(np.array(record["offsets"]), np.array(record["reference"]), meta)


def mouth_rois(
    frames: np.ndarray,
    timestamps: np.ndarray,
    landmarks: np.ndarray,
    video_process: Callable[[np.ndarray, list], np.ndarray | None],
    correction: AlignmentCorrection | None = None,
) -> np.ndarray:
    """Aligned 96x96 uint8 mouth patches, one per 25 fps tick.

    video_process is the model repo's VideoProcess(convert_gray=False), which takes the frames
    and a list of [68, 2] landmark arrays (or None) and returns the patches.
    """
    if len(frames) != len(landmarks) or len(frames) != len(timestamps):
        raise PreprocessError(f"{len(frames)} frames, {len(timestamps)} timestamps, {len(landmarks)} landmark sets")
    picked = uniform_indices(timestamps)
    frames = np.asarray(frames)[picked]
    landmarks = np.asarray(landmarks)[picked]
    if len(frames) < MIN_FRAMES:
        raise PreprocessError(f"clip has {len(frames)} frames, the models need at least {MIN_FRAMES}")
    if is_mirrored(landmarks):
        frames, landmarks = mirror(frames, landmarks)
    points = ibug_landmarks(landmarks)
    if correction is not None:
        points = [None if p is None else correction.apply(p) for p in points]
    rois = video_process(frames, points)
    if rois is None:
        raise PreprocessError("the model's VideoProcess rejected the clip")
    return np.asarray(rois, dtype=np.uint8)


def model_input(rois: np.ndarray):
    """[T, 96, 96] uint8 patches to the [T, 88, 88] float tensor both models read at test time."""
    import torch

    video = torch.from_numpy(np.asarray(rois, dtype=np.float32)) / 255.0
    top = (video.shape[1] - MODEL_CROP) // 2
    left = (video.shape[2] - MODEL_CROP) // 2
    video = video[:, top : top + MODEL_CROP, left : left + MODEL_CROP]
    return (video - PIXEL_MEAN) / PIXEL_STD
