"""Mirrors Packages/TacitKit/Sources/TacitKit/Constants.swift. tests/test_constants.py checks parity."""

import numpy as np

PROTOCOL_VERSION = 1
FEATURE_SCHEMA_VERSION = 1
AUDIO_SAMPLE_RATE = 16_000
LIP_VERTEX_COUNT = 64

BLEND_SHAPE_ORDER: tuple[str, ...] = (
    "browDown_L", "browDown_R", "browInnerUp", "browOuterUp_L", "browOuterUp_R",
    "cheekPuff", "cheekSquint_L", "cheekSquint_R",
    "eyeBlink_L", "eyeBlink_R", "eyeLookDown_L", "eyeLookDown_R", "eyeLookIn_L", "eyeLookIn_R",
    "eyeLookOut_L", "eyeLookOut_R", "eyeLookUp_L", "eyeLookUp_R", "eyeSquint_L", "eyeSquint_R",
    "eyeWide_L", "eyeWide_R",
    "jawForward", "jawLeft", "jawOpen", "jawRight",
    "mouthClose", "mouthDimple_L", "mouthDimple_R", "mouthFrown_L", "mouthFrown_R", "mouthFunnel",
    "mouthLeft", "mouthLowerDown_L", "mouthLowerDown_R", "mouthPress_L", "mouthPress_R", "mouthPucker",
    "mouthRight", "mouthRollLower", "mouthRollUpper", "mouthShrugLower", "mouthShrugUpper",
    "mouthSmile_L", "mouthSmile_R", "mouthStretch_L", "mouthStretch_R", "mouthUpperUp_L", "mouthUpperUp_R",
    "noseSneer_L", "noseSneer_R",
    "tongueOut",
)

# One FaceFrame record, identical on the wire and in face.bin.
FACE_FRAME_DTYPE = np.dtype([
    ("timestamp", "<f8"),
    ("tracking_flags", "<u4"),
    ("blend_shapes", "<f4", (len(BLEND_SHAPE_ORDER),)),
    ("head_transform", "<f4", (16,)),
    ("lip_vertices", "<f4", (LIP_VERTEX_COUNT, 3)),
])

# face.bin header: magic "SFCE", schema version, lip vertex count, frame count, reserved.
FACE_FILE_HEADER_DTYPE = np.dtype([
    ("magic", "S4"),
    ("feature_schema_version", "<u2"),
    ("lip_vertex_count", "<u2"),
    ("frame_count", "<u4"),
    ("reserved", "<u4"),
])
FACE_FILE_MAGIC = b"SFCE"
