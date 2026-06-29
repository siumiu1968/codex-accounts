#!/usr/bin/env python3
from pathlib import Path

from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parents[1]

SHOTS = [
    (
        Path("/Users/auchunngai/Desktop/螢幕截圖 2026-05-09 12.54.09.png"),
        ROOT / "docs/assets/codex-accounts-v2.2-real-zh-HK.png",
    ),
    (
        Path("/Users/auchunngai/Desktop/螢幕截圖 2026-05-09 12.54.14.png"),
        ROOT / "docs/assets/codex-accounts-v2.2-real-zh-CN.png",
    ),
    (
        Path("/Users/auchunngai/Desktop/螢幕截圖 2026-05-09 12.54.21.png"),
        ROOT / "docs/assets/codex-accounts-v2.2-real-en.png",
    ),
]

# The screenshots are real app captures at 3420x2214. These boxes cover only the
# username segment in `/Users/auchunngai/...`, leaving the UI and profile names
# unchanged.
USERNAME_X = 970
USERNAME_WIDTH = 178
USERNAME_HEIGHT = 34
USERNAME_TOPS = [598, 770, 944, 1116, 1290, 1464, 1636, 1810, 2096]


def obscure_username(image: Image.Image, box: tuple[int, int, int, int]) -> None:
    crop = image.crop(box)
    small_w = max(1, crop.width // 12)
    small_h = max(1, crop.height // 8)
    pixelated = crop.resize((small_w, small_h), Image.Resampling.BILINEAR)
    pixelated = pixelated.resize(crop.size, Image.Resampling.NEAREST)
    softened = pixelated.filter(ImageFilter.GaussianBlur(radius=2.2))
    image.paste(softened, box)


def sanitize(src: Path, dst: Path) -> None:
    image = Image.open(src).convert("RGB")
    for y in USERNAME_TOPS:
        box = (
            USERNAME_X,
            y,
            min(USERNAME_X + USERNAME_WIDTH, image.width),
            min(y + USERNAME_HEIGHT, image.height),
        )
        obscure_username(image, box)

    dst.parent.mkdir(parents=True, exist_ok=True)
    image.save(dst, "PNG", optimize=True)
    print(dst)


def main() -> None:
    for src, dst in SHOTS:
        sanitize(src, dst)


if __name__ == "__main__":
    main()
