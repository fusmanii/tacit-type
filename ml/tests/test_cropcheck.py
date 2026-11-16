import numpy as np
import pytest

from silentml.constants import CROP_LANDMARK_ORDER
from silentml.preprocess import IBUG_INDEX, STABLE_POINTS
from synthetic import frames_with_dot
from test_preprocess import auto_avsr_video_process, usr2_video_process


def mean_face_session(vp, count=30, shift_corners=0.0):
    """A clip whose landmarks are the mean face itself, scaled into the iPhone crop."""
    from synthetic import FakeSession

    reference = np.asarray(vp.reference, dtype=np.float64)
    width = np.linalg.norm(reference[54] - reference[48])
    scale = 64 / width  # the iPhone crop is 64 px across the mouth
    centre = reference[48:68].mean(axis=0)
    crop = np.array([(reference[IBUG_INDEX[name]] - centre) * scale + 96 for name in CROP_LANDMARK_ORDER])
    crop[CROP_LANDMARK_ORDER.index("mouthCornerLowX"), 0] += shift_corners
    crop[CROP_LANDMARK_ORDER.index("mouthCornerHighX"), 0] += shift_corners
    landmarks = np.repeat(crop[None].astype(np.float32), count, axis=0)
    return FakeSession(frames_with_dot(count), 10.0 + np.arange(count) / 25.0, landmarks,
                       manifest={"speechStyle": "silent", "promptId": "harvard-01-01"})


@pytest.mark.parametrize("make", [usr2_video_process, auto_avsr_video_process])
def test_the_mean_face_aligns_onto_itself(make):
    from silentml.cropcheck import _prepared, residuals, summary

    vp = make()
    offsets = residuals(vp, *_prepared(mean_face_session(vp)))
    assert offsets.shape == (30, len(STABLE_POINTS), 2)
    assert np.abs(offsets).max() < 0.5
    assert not summary(offsets)["systematic_shift"]


def test_a_consistent_offset_is_called_systematic():
    from silentml.cropcheck import _prepared, residuals, summary

    vp = usr2_video_process()
    result = summary(residuals(vp, *_prepared(mean_face_session(vp, shift_corners=12.0))))
    assert result["systematic_shift"]
    assert result["mouth_corner_mean_offset"]["dx"] > 3


def test_row_draws_three_tiles():
    from silentml.cropcheck import row

    vp = usr2_video_process()
    tiles = row(vp, mean_face_session(vp))
    assert tiles.shape == (256, 3 * 256, 3) and tiles.dtype == np.uint8


def test_a_fitted_correction_removes_a_consistent_offset(tmp_path):
    from silentml.cropcheck import _prepared, _stable_reference, residuals, summary
    from silentml.preprocess import AlignmentCorrection

    vp = usr2_video_process()
    shifted = _prepared(mean_face_session(vp, shift_corners=12.0))
    correction = AlignmentCorrection.fit(residuals(vp, *shifted), _stable_reference(vp), takes=1)
    correction.save(tmp_path / "correction.json")
    loaded = AlignmentCorrection.load(tmp_path / "correction.json")
    after = summary(residuals(vp, *shifted, loaded))
    assert after["max_mean_offset_px"] < 0.5
    assert not after["systematic_shift"]


def test_main_fits_saves_and_reports_the_correction(tmp_path, monkeypatch):
    import json

    from silentml import cropcheck, evaluate, models

    vp = usr2_video_process()
    session = mean_face_session(vp, shift_corners=12.0)
    session.manifest.update({"sittingId": "S1", "promptText": "the birch canoe"})
    monkeypatch.setattr(models, "video_process", lambda name: vp)
    monkeypatch.setattr(evaluate, "sentence_takes", lambda root, sittings=None: iter([session]))
    monkeypatch.setenv("TACIT_MODEL_DIR", str(tmp_path / "models"))

    cropcheck.main(["--data", str(tmp_path), "--model", "usr2-large", "--out", str(tmp_path / "out"), "--fit"])
    saved = json.loads(models.correction_path().read_text())
    assert saved["sittings"] == ["S1"] and saved["takes"] == 1
    result = json.loads((tmp_path / "out" / "usr2-large.json").read_text())
    assert result["raw"]["systematic_shift"]
    assert result["corrected"]["max_mean_offset_px"] < 0.5
    assert result["correction"] == str(models.correction_path())
