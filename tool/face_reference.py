#!/usr/bin/env python3
"""Build the OpenCV face reference JSON the real-photo probes expect.

Mirrors the Dart engine's pipeline so host runs match on-device numbers:
YuNet 640x640 (score 0.6, nms 0.3) and the L2-normalised 128-d SFace-int8
embedding of the aligned 112x112 BGR crop.

Usage:
  python3 tool/face_reference.py <photos-dir> <out.json>
"""
import json
import os
import sys

import cv2
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
YUNET = os.path.join(ROOT, "assets/models/yunet.onnx")
SFACE = os.path.join(ROOT, "assets/models/sface_int8.onnx")

if len(sys.argv) != 3:
    sys.exit(f"usage: {sys.argv[0]} <photos-dir> <out.json>")

PHOTOS, OUT = sys.argv[1], sys.argv[2]

# Small inputs (a cheki cut from a desk photo is ~150x240 px) are upscaled (bilinear)
# so the long side is MIN_SIDE before detection, matching
# FaceDetectorOptions.minDetectSide in the app.
MIN_SIDE = int(os.environ.get("OTA_FACE_MIN_SIDE", "480"))

detector = cv2.FaceDetectorYN_create(YUNET, "", (640, 640), 0.6, 0.3, 5000)
recognizer = cv2.FaceRecognizerSF_create(SFACE, "")

images = []
total_faces = 0
for name in sorted(os.listdir(PHOTOS)):
    if not name.lower().endswith((".jpg", ".jpeg", ".png")):
        continue
    image = cv2.imread(os.path.join(PHOTOS, name))
    if image is None:
        print(f"SKIP unreadable {name}", file=sys.stderr)
        continue
    long_side = max(image.shape[:2])
    scale = MIN_SIDE / long_side if 0 < long_side < MIN_SIDE else 1.0
    if scale != 1.0:
        image = cv2.resize(
            image,
            (round(image.shape[1] * scale), round(image.shape[0] * scale)),
            interpolation=cv2.INTER_LINEAR,
        )
    detector.setInputSize((image.shape[1], image.shape[0]))
    ok, faces = detector.detect(image)
    faces_out = []
    for row in ([] if (not ok or faces is None) else faces):
        row = row.astype(np.float32)
        aligned = recognizer.alignCrop(image, row)
        feature = recognizer.feature(aligned, cv2.FaceRecognizerSF_FR_NORM_L2)
        faces_out.append({
            # Report boxes/landmarks in original-image coordinates.
            "row": [float(v) / scale if i < 14 else float(v)
                    for i, v in enumerate(row.reshape(-1))],
            "feature": [float(v) for v in feature.reshape(-1)],
        })
    total_faces += len(faces_out)
    images.append({"name": name, "faces": faces_out})
    print(f"{name}: {len(faces_out)} face(s)", file=sys.stderr)

os.makedirs(os.path.dirname(os.path.abspath(OUT)), exist_ok=True)
with open(OUT, "w") as handle:
    json.dump({"images": images}, handle)
print(f"wrote {OUT}: {len(images)} photos, {total_faces} faces", file=sys.stderr)
