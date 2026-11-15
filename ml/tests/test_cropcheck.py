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
