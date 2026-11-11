#!/usr/bin/env python3
"""Build a small PingFang SC subset for deterministic UI preview goldens.

The generated font is a local development artifact and is intentionally not
committed (Apple system fonts are not redistributable). Run this before
`flutter test tool/ui_preview/ui_preview_test.dart --update-goldens`.
"""
from pathlib import Path
from fontTools.ttLib import TTCollection
from fontTools.subset import Options, Subsetter

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "tool/ui_preview/PingFangSC-Preview.ttf"
CANDIDATES = [
    "/System/Library/AssetsV2/com_apple_MobileAsset_Font8/"
    "86ba2c91f017a3749571a82f2c6d890ac7ffb2fb.asset/AssetData/PingFang.ttc",
    "/System/Library/Fonts/Supplemental/PingFang.ttc",
]


def main() -> None:
    source = next((Path(p) for p in CANDIDATES if Path(p).exists()), None)
    if source is None:
        raise SystemExit("PingFang SC not found; edit CANDIDATES in this script")

    collection = TTCollection(str(source))
    font = next(
        (f for f in collection.fonts if f["name"].getDebugName(1) == "PingFang SC Regular"),
        collection.fonts[0],
    )

    options = Options()
    options.layout_features = ["*"]
    options.name_IDs = ["*"]
    options.name_legacy = True
    options.notdef_outline = True
    options.recommended_glyphs = True
    subsetter = Subsetter(options=options)
    # Keep the whole BMP plus the punctuation and symbols used by the UI. This
    # is a few MB and only lives on the developer machine, but avoids mystery
    # tofu boxes whenever a new label is added.
    subsetter.populate(unicodes=[*range(0x20, 0x100), *range(0x2000, 0x2070), *range(0x3000, 0x3040), *range(0x4E00, 0xA000), *range(0xFF00, 0xFF70)])
    subsetter.subset(font)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    font.save(str(OUT))
    print(f"wrote {OUT} ({OUT.stat().st_size / 1024:.0f} KiB)")


if __name__ == "__main__":
    main()
