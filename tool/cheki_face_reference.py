#!/usr/bin/env python3
"""YuNet rows for the face windows dumped by test/cheki_pipeline_parity_test.dart.

Usage: python3 tool/cheki_face_reference.py <window_dir> <out.json>

Runs OpenCV's FaceDetectorYN with the model the app ships
(assets/models/yunet.onnx) using the app's detector settings (score 0.6,
NMS 0.3, faces under 4 % of the short side dropped). The app's own engine
reproduces OpenCV's numbers on device (integration_test/face_engine_parity_test).
Output: {"<source>__<card>": {"<turn>": [[x, y, w, h, 10 landmarks, score]]}}.
"""
import json
import sys
from pathlib import Path

import cv2

MODEL = Path(__file__).resolve().parent.parent / "assets/models/yunet.onnx"


def main():
    windows, out = Path(sys.argv[1]), Path(sys.argv[2])
    detector = cv2.FaceDetectorYN.create(str(MODEL), "", (320, 320), 0.6, 0.3, 5000)
    result = {}
    for path in sorted(windows.glob("*.png")):
        card, turn = path.stem.rsplit("__", 1)
        image = cv2.imread(str(path))
        height, width = image.shape[:2]
        detector.setInputSize((width, height))
        _, faces = detector.detect(image)
        rows = []
        for face in [] if faces is None else faces:
            if min(face[2], face[3]) >= 0.04 * min(width, height):
                rows.append([round(float(v), 4) for v in face[:15]])
        result.setdefault(card, {})[turn] = rows
    out.write_text(json.dumps(result, ensure_ascii=False, indent=1))
    print(f"{len(result)} cards -> {out}")


if __name__ == "__main__":
    main()
