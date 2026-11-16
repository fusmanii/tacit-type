import importlib.util
from pathlib import Path

import numpy as np
import pytest

from silentml.constants import CROP_LANDMARK_ORDER
from silentml.preprocess import (
    IBUG_INDEX,
    MOUTH_POINTS,
    PreprocessError,
    ibug_landmarks,
    is_mirrored,
    mirror,
    mouth_rois,
    uniform_indices,
)
from synthetic import MOUTH_CENTRE, frames_with_dot, landmark_array, session

THIRD_PARTY = Path(__file__).resolve().parent.parent / "third_party"


def load_module(path: Path):
    """Imports one file from a model repo without putting the repo on sys.path."""
    if not path.exists():
        pytest.skip(f"{path} missing. Run `git submodule update --init`.")
    pytest.importorskip("cv2")
    spec = importlib.util.spec_from_file_location(f"repo_{abs(hash(path))}", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def usr2_video_process():
    return load_module(THIRD_PARTY / "usr2/preprocessing/video_preprocess.py").VideoProcess(convert_gray=False)


def auto_avsr_video_process():
    pytest.importorskip("skimage")
    return load_module(THIRD_PARTY / "auto_avsr/preparation/detectors/retinaface/video_process.py").VideoProcess(
        convert_gray=False
    )


def test_uniform_indices_without_drops_is_identity():
    ts = 50.0 + np.arange(30) / 25.0
    assert uniform_indices(ts).tolist() == list(range(30))


def test_uniform_indices_fills_a_dropped_frame():
    ts = 50.0 + np.delete(np.arange(10), 4) / 25.0  # frame 4 never arrived
    picked = uniform_indices(ts)
    assert len(picked) == 10
    assert picked.tolist()[:4] == [0, 1, 2, 3]
    assert picked[4] in (3, 4)  # a neighbour fills the gap
    assert picked.tolist()[5:] == [4, 5, 6, 7, 8]


def test_uniform_indices_tolerates_jitter():
    rng = np.random.default_rng(1)
    ts = 50.0 + np.arange(50) / 25.0 + rng.uniform(-0.008, 0.008, 50)
    assert uniform_indices(ts).tolist() == list(range(50))


def test_ibug_landmarks_places_every_slot():
    crop = landmark_array()
    points = ibug_landmarks(crop[None])[0]
    assert points.shape == (68, 2)
    for slot, name in enumerate(CROP_LANDMARK_ORDER):
        assert points[IBUG_INDEX[name]].tolist() == crop[slot].tolist()


def test_ibug_mouth_points_average_to_the_mouth_centre():
    points = ibug_landmarks(landmark_array()[None])[0]
    assert np.allclose(points[list(MOUTH_POINTS)].mean(axis=0), MOUTH_CENTRE)


def test_ibug_landmarks_leaves_bad_frames_for_interpolation():
    crop = np.repeat(landmark_array()[None], 3, axis=0)
    crop[1, 5] = np.nan
    points = ibug_landmarks(crop)
    assert points[0] is not None and points[1] is None and points[2] is not None


def test_mirror_detection():
    frames = frames_with_dot(3)
    landmarks = np.repeat(landmark_array()[None], 3, axis=0)
    assert not is_mirrored(landmarks)
    flipped_frames, flipped = mirror(frames, landmarks)
    assert is_mirrored(flipped)
    assert np.array_equal(mirror(flipped_frames, flipped)[0], frames)


def test_too_short_a_clip_is_refused():
    clip = session(count=8)
    with pytest.raises(PreprocessError):
        mouth_rois(clip.mouth, clip.mouth_ts, clip.mouth_landmarks, usr2_video_process())


@pytest.mark.parametrize("make", [usr2_video_process, auto_avsr_video_process])
def test_mouth_ends_up_in_the_centre_of_the_patch(make):
    clip = session()
    rois = mouth_rois(clip.mouth, clip.mouth_ts, clip.mouth_landmarks, make())
    assert rois.shape == (40, 96, 96) and rois.dtype == np.uint8
    y, x = np.unravel_index(np.argmax(rois[20].astype(int)), rois[20].shape)
    # The dot is 5 px across in the crop. The patch scale is close to 1, so its brightest pixel
    # lands within a couple of pixels of the patch centre.
    assert abs(x - 48) <= 3 and abs(y - 48) <= 3


def test_a_mirrored_clip_gives_the_same_patches():
    clip = session()
    frames, landmarks = mirror(clip.mouth, clip.mouth_landmarks)
    straight = mouth_rois(clip.mouth, clip.mouth_ts, clip.mouth_landmarks, usr2_video_process())
    flipped = mouth_rois(frames, clip.mouth_ts, landmarks, usr2_video_process())
    assert np.abs(straight.astype(int) - flipped.astype(int)).mean() < 1


def test_both_repos_align_the_same_way():
    clip = session()
    usr2 = mouth_rois(clip.mouth, clip.mouth_ts, clip.mouth_landmarks, usr2_video_process())
    auto = mouth_rois(clip.mouth, clip.mouth_ts, clip.mouth_landmarks, auto_avsr_video_process())
    assert np.abs(usr2.astype(int) - auto.astype(int)).mean() < 2


def test_model_input_matches_auto_avsr_test_transform():
    torch = pytest.importorskip("torch")
    pytest.importorskip("sentencepiece")
    from silentml.preprocess import model_input

    rois = np.random.default_rng(2).integers(0, 256, (12, 96, 96), dtype=np.uint8)
    transforms = load_module(THIRD_PARTY / "auto_avsr/datamodule/transforms.py")
    # The repo's pipeline takes [T, C, H, W] and returns [T, 1, H, W].
    theirs = transforms.VideoTransform("test")(torch.from_numpy(rois).float().unsqueeze(1)).squeeze(1)
    ours = model_input(rois)
    assert ours.shape == (12, 88, 88)
    assert torch.allclose(ours, theirs, atol=1e-5)


def _correction(offsets):
    from silentml.preprocess import STABLE_POINTS, AlignmentCorrection

    pytest.importorskip("cv2")
    reference = np.array([ibug_landmarks(landmark_array()[None])[0][i] for i in STABLE_POINTS])
    return AlignmentCorrection(np.asarray(offsets, dtype=np.float64), reference)


def test_a_zero_correction_changes_nothing():
    from silentml.preprocess import STABLE_POINTS

    points = ibug_landmarks(landmark_array()[None])[0]
    assert np.allclose(_correction(np.zeros((len(STABLE_POINTS), 2))).apply(points), points)


def test_a_correction_moves_the_alignment_points_and_keeps_the_mouth_centre():
    from silentml.preprocess import STABLE_POINTS

    points = ibug_landmarks(landmark_array()[None])[0]
    offsets = np.zeros((len(STABLE_POINTS), 2))
    offsets[STABLE_POINTS.index(33)] = (0.0, 6.0)  # nose base lands 6 px low
    offsets[STABLE_POINTS.index(48)] = (4.0, 0.0)  # mouth corners sit 4 px in
    offsets[STABLE_POINTS.index(54)] = (-4.0, 0.0)
    out = _correction(offsets).apply(points)
    # The reference here is our own landmarks, so the alignment is the identity.
    assert np.allclose(out[33], points[33] - (0, 6))
    assert np.allclose(out[48], points[48] - (4, 0)) and np.allclose(out[54], points[54] + (4, 0))
    assert np.allclose(out[list(MOUTH_POINTS)].mean(axis=0), MOUTH_CENTRE)


def test_a_correction_file_from_another_version_is_refused(tmp_path):
    import json

    from silentml.preprocess import STABLE_POINTS, AlignmentCorrection

    _correction(np.zeros((len(STABLE_POINTS), 2))).save(tmp_path / "c.json")
    assert AlignmentCorrection.load(tmp_path / "c.json").meta["file"] == str(tmp_path / "c.json")
    record = json.loads((tmp_path / "c.json").read_text())
    (tmp_path / "c.json").write_text(json.dumps({**record, "version": 99}))
    with pytest.raises(PreprocessError):
        AlignmentCorrection.load(tmp_path / "c.json")
