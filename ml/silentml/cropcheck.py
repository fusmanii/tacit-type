"""Phase A crop check: our aligned mouth crops beside the geometry each model was trained on.

    python -m silentml.cropcheck --data <sessions dir> --model auto-avsr --out runs/baseline/crops
    python -m silentml.cropcheck --data <sessions dir> --model auto-avsr --out runs/baseline/crops --fit

Writes <out>/<model>.png with one row per sampled take (20 by default), and <out>/<model>.json
with how far our alignment points land from the mean face, averaged over every frame. Both are
reported before ("raw") and after the alignment correction, when there is one.

--fit measures the raw offsets on these takes and saves them as the alignment correction, next to
the checkpoints, where `models.load` picks it up. Fit on a whole sitting or more, since it should
hold for every take.

Each row has three tiles, all scaled to 256 px tall:
1. The iPhone crop with its 12 landmarks (green).
2. The frame after the model's alignment to the mean face. Red dots are the mean face's 8
   alignment points and green dots are ours. On a good fit they overlap.
3. The 96x96 patch the model reads, with the mean face's lip outline in red and the 88x88 test
   crop as a box. The real lips should sit on the outline.

ARKit's mesh points don't sit exactly where the iBUG annotators put theirs, so a consistent offset
in the JSON (rather than scatter) means a fixed correction should be fitted (see the spec).
No weights are loaded, so this runs before any checkpoint is downloaded.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

from .preprocess import (
    MIN_FRAMES,
    STABLE_POINTS,
    AlignmentCorrection,
    ibug_landmarks,
    is_mirrored,
    mirror,
    uniform_indices,
)

ALIGNED = 256  # both repos align into a 256x256 frame
PATCH = 96
MODEL_CROP = 88
TILE = 256
RED, GREEN, WHITE = (60, 60, 230), (80, 220, 80), (255, 255, 255)
# Mean offset, in aligned pixels, above which the check calls a shift systematic.
SHIFT_WARNING_PX = 3.0


def _prepared(session):
    frames = np.asarray(session.mouth)
    landmarks = np.asarray(session.mouth_landmarks)
    picked = uniform_indices(session.mouth_ts)
    frames, landmarks = frames[picked], landmarks[picked]
    if is_mirrored(landmarks):
        frames, landmarks = mirror(frames, landmarks)
    return frames, landmarks


def _stable_reference(vp) -> np.ndarray:
    return np.asarray(vp.get_stable_reference(vp.reference, STABLE_POINTS, (ALIGNED, ALIGNED), (ALIGNED, ALIGNED)))


def _points(landmarks: np.ndarray, correction: AlignmentCorrection | None) -> list:
    points = ibug_landmarks(landmarks)
    if correction is None:
        return points
    return [None if p is None else correction.apply(p) for p in points]


def residuals(vp, frames: np.ndarray, landmarks: np.ndarray, correction: AlignmentCorrection | None = None) -> np.ndarray:
    """[frames, 8, 2] offset of each aligned stable point from the mean face's, in aligned pixels."""
    reference = _stable_reference(vp)
    out = []
    for frame, points in zip(frames, _points(landmarks, correction)):
        if points is None:
            continue
        _, aligned = vp.affine_transform(frame, points, vp.reference, grayscale=False)
        out.append(np.asarray(aligned)[list(STABLE_POINTS)] - reference)
    return np.array(out).reshape(-1, len(STABLE_POINTS), 2)


def _bgr(gray: np.ndarray):
    import cv2

    return cv2.cvtColor(np.ascontiguousarray(gray, dtype=np.uint8), cv2.COLOR_GRAY2BGR)


def _dots(image, points, colour, scale: float, radius: int = 3):
    import cv2

    for x, y in np.asarray(points, dtype=np.float64):
        if np.isfinite(x) and np.isfinite(y):
            cv2.circle(image, (int(round(x * scale)), int(round(y * scale))), radius, colour, -1, cv2.LINE_AA)


def row(vp, session, correction: AlignmentCorrection | None = None) -> np.ndarray:
    """One row of the sheet for a session's middle frame."""
    import cv2

    frames, landmarks = _prepared(session)
    middle = len(frames) // 2
    all_points = _points(landmarks, correction)
    points = all_points[middle]

    crop = cv2.resize(_bgr(frames[middle]), (TILE, TILE), interpolation=cv2.INTER_LINEAR)
    _dots(crop, landmarks[middle], GREEN, TILE / frames.shape[1])

    aligned_frame, aligned = vp.affine_transform(frames[middle], points, vp.reference, grayscale=False)
    aligned_tile = _bgr(aligned_frame)
    _dots(aligned_tile, _stable_reference(vp), RED, 1.0, radius=4)
    _dots(aligned_tile, np.asarray(aligned)[list(STABLE_POINTS)], GREEN, 1.0)

    patches = vp(frames, all_points)
    patch = cv2.resize(_bgr(patches[middle]), (TILE, TILE), interpolation=cv2.INTER_NEAREST)
    scale = TILE / PATCH
    # The patch is centred on the mouth, so the mean face's lips belong around the patch centre.
    lips = np.asarray(vp.reference)[48:68]
    lips = lips - lips.mean(axis=0) + PATCH / 2
    outer = np.round(lips[:12] * scale).astype(np.int32)
    inner = np.round(lips[12:] * scale).astype(np.int32)
    cv2.polylines(patch, [outer, inner], True, RED, 1, cv2.LINE_AA)
    margin = int(round((PATCH - MODEL_CROP) / 2 * scale))
    cv2.rectangle(patch, (margin, margin), (TILE - margin, TILE - margin), WHITE, 1)

    tiles = np.concatenate([crop, aligned_tile, patch], axis=1)
    label = f"{session.manifest.get('speechStyle', '')}  {session.manifest.get('promptId', '')}"
    cv2.putText(tiles, label, (6, TILE - 8), cv2.FONT_HERSHEY_SIMPLEX, 0.45, WHITE, 1, cv2.LINE_AA)
    return tiles


def summary(offsets: np.ndarray) -> dict:
    """Mean and spread of the offsets per alignment point. A large mean with a small spread is a fixed shift."""
    mean = offsets.mean(axis=0)
    spread = offsets.std(axis=0)
    per_point = {
        str(index): {"dx": float(m[0]), "dy": float(m[1]), "sd_x": float(s[0]), "sd_y": float(s[1])}
        for index, m, s in zip(STABLE_POINTS, mean, spread)
    }
    mouth = mean[[STABLE_POINTS.index(48), STABLE_POINTS.index(54)]].mean(axis=0)
    shift = float(np.abs(mean).max())
    return {
        "frames": int(len(offsets)),
        "points": per_point,
        "mouth_corner_mean_offset": {"dx": float(mouth[0]), "dy": float(mouth[1])},
        "max_mean_offset_px": shift,
        "systematic_shift": shift > SHIFT_WARNING_PX,
    }


def _print(raw: dict, corrected: dict | None) -> None:
    print(f"{'point':>5} {'dx':>6} {'dy':>6} {'sd':>5}" + ("   corrected dx    dy" if corrected else "")
          + f"   (aligned pixels, {raw['frames']} frames)")
    for index, p in raw["points"].items():
        line = f"{index:>5} {p['dx']:6.1f} {p['dy']:6.1f} {max(p['sd_x'], p['sd_y']):5.1f}"
        if corrected:
            c = corrected["points"][index]
            line += f"   {c['dx']:12.1f} {c['dy']:5.1f}"
        print(line)


def main(argv: list[str] | None = None) -> None:
    import cv2

    from . import models
    from .evaluate import sentence_takes

    parser = argparse.ArgumentParser(prog="python -m silentml.cropcheck")
    parser.add_argument("--data", type=Path, required=True)
    parser.add_argument("--model", required=True, choices=list(models.CHECKPOINTS))
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--count", type=int, default=20, help="takes on the sheet")
    parser.add_argument("--sitting", action="append")
    parser.add_argument("--fit", action="store_true", help="save these takes' mean offsets as the alignment correction")
    parser.add_argument("--correction", type=Path, help="correction file to use or write (default: next to the checkpoints)")
    parser.add_argument("--no-correction", action="store_true", help="check the alignment without any correction")
    args = parser.parse_args(argv)

    vp = models.video_process(args.model)
    sessions = [s for s in sentence_takes(args.data, sittings=args.sitting) if len(s.mouth) >= MIN_FRAMES]
    if not sessions:
        raise SystemExit("no sentence takes with mouth video")
    prepared = [_prepared(s) for s in sessions]
    raw = np.concatenate([residuals(vp, *p) for p in prepared])

    if args.fit:
        path = args.correction or models.correction_path()
        sittings = sorted({s.manifest.get("sittingId") for s in sessions if s.manifest.get("sittingId")})
        AlignmentCorrection.fit(raw, _stable_reference(vp), takes=len(sessions), sittings=sittings).save(path)
        print(f"wrote the alignment correction to {path}")
    correction = None if args.no_correction else models.load_correction(args.correction or "default")
    corrected = np.concatenate([residuals(vp, *p, correction) for p in prepared]) if correction else None

    picks = np.unique(np.linspace(0, len(sessions) - 1, min(args.count, len(sessions))).round().astype(int))
    sheet = np.concatenate([row(vp, sessions[i], correction) for i in picks], axis=0)
    args.out.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(args.out / f"{args.model}.png"), sheet)
    result = {
        "model": args.model,
        "takes": len(sessions),
        "correction": correction.meta["file"] if correction else None,
        "raw": summary(raw),
        "corrected": summary(corrected) if correction else None,
    }
    (args.out / f"{args.model}.json").write_text(json.dumps(result, indent=2) + "\n")

    _print(result["raw"], result["corrected"])
    final = result["corrected"] or result["raw"]
    label = "after the correction" if correction else "with no correction"
    verdict = "looks systematic, so fit a correction (--fit)" if final["systematic_shift"] else "is within tolerance"
    print(f"largest mean offset {label} {final['max_mean_offset_px']:.1f} px {verdict}")
    print(f"wrote {args.out / (args.model + '.png')} (drawn {label})")


if __name__ == "__main__":
    main()
