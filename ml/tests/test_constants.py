import re
from pathlib import Path

from silentml.constants import (
    BLEND_SHAPE_ORDER,
    CROP_LANDMARK_ORDER,
    MOUTH_CROP_SIZE,
    MOUTH_FILE_HEADER_DTYPE,
    MOUTH_FILE_VERSION,
    MOUTH_FPS,
    mouth_record_dtype,
    FACE_FILE_HEADER_DTYPE,
    FACE_FRAME_DTYPE,
    FEATURE_SCHEMA_VERSION,
    PROTOCOL_VERSION,
)

SWIFT_CONSTANTS = Path(__file__).parents[2] / "Packages/TacitKit/Sources/TacitKit/Constants.swift"


def swift_source() -> str:
    return SWIFT_CONSTANTS.read_text()


def test_face_frame_record_is_1052_bytes():
    assert FACE_FRAME_DTYPE.itemsize == 1052


def test_face_file_header_is_16_bytes():
    assert FACE_FILE_HEADER_DTYPE.itemsize == 16


def test_blend_shape_order_is_sorted_and_unique():
    assert len(BLEND_SHAPE_ORDER) == 52
    assert len(set(BLEND_SHAPE_ORDER)) == 52
    assert list(BLEND_SHAPE_ORDER) == sorted(BLEND_SHAPE_ORDER)


def test_blend_shape_order_matches_swift():
    block = re.search(r"blendShapeOrder: \[String\] = \[(.*?)\]", swift_source(), re.S)
    assert block, "blendShapeOrder not found in Constants.swift"
    assert tuple(re.findall(r'"(\w+)"', block.group(1))) == BLEND_SHAPE_ORDER


def test_versions_match_swift():
    source = swift_source()
    assert f"protocolVersion: UInt8 = {PROTOCOL_VERSION}" in source
    assert f"featureSchemaVersion: UInt16 = {FEATURE_SCHEMA_VERSION}" in source


def test_mouth_file_layout():
    assert MOUTH_FILE_HEADER_DTYPE.itemsize == 12
    assert mouth_record_dtype().itemsize == 104


def test_crop_landmark_order_matches_swift():
    block = re.search(r"enum CropLandmark: Int, CaseIterable, Sendable \{(.*?)\n\}", swift_source(), re.S)
    assert block, "enum CropLandmark not found in Constants.swift"
    cases = [name for line in re.findall(r"case (.*)", block.group(1)) for name in re.split(r",\s*", line.strip())]
    assert tuple(cases) == CROP_LANDMARK_ORDER


def test_mouth_constants_match_swift():
    source = swift_source()
    assert f"mouthCropSize = {MOUTH_CROP_SIZE}" in source
    assert f"mouthFps: Double = {MOUTH_FPS}" in source
    assert f"mouthFileVersion: UInt16 = {MOUTH_FILE_VERSION}" in source
