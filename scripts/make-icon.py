"""Builds Resources/AppIcon.icon (Icon Composer) from the owner's three logos in design/logo/.

light.png is the default icon, dark.png the dark appearance, mono.png the tinted (and clear) appearance.
Each logo is cropped square around its body so the system's own icon mask cuts the edge, and the
icon fill behind it is the logo's face colour, so no corner can show through.

Run: uv run --with numpy --with pillow python scripts/make-icon.py
"""

import json
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "design" / "logo"
TARGET = ROOT / "Resources" / "AppIcon.icon"
SIZE = 1024
INSET = 0.015  # crop a little inside the body edge, the mask rounds the rest


def body_box(alpha: np.ndarray) -> tuple[int, int, int, int]:
    """Bounds of the opaque body; stray specks in the transparent margin are ignored."""
    rows = np.where((alpha > 200).sum(1) > 200)[0]
    cols = np.where((alpha > 200).sum(0) > 200)[0]
    return int(cols[0]), int(rows[0]), int(cols[-1]), int(rows[-1])


def face_colour(
    rgba: np.ndarray, box: tuple[int, int, int, int]
) -> tuple[float, float, float]:
    """Median colour of a patch on the face between the top edge and the ring."""
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0
    patch = rgba[
        y0 + int(h * 0.08) : y0 + int(h * 0.12),
        x0 + int(w * 0.45) : x0 + int(w * 0.55),
        :3,
    ]
    return tuple(float(v) / 255 for v in np.median(patch.reshape(-1, 3), axis=0))


def artwork(name: str) -> tuple[Image.Image, tuple[float, float, float]]:
    image = Image.open(SOURCE / f"{name}.png").convert("RGBA")
    rgba = np.asarray(image)
    box = body_box(rgba[:, :, 3])
    x0, y0, x1, y1 = box
    side = min(x1 - x0, y1 - y0) * (1 - 2 * INSET)
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    crop = image.crop(
        (
            round(cx - side / 2),
            round(cy - side / 2),
            round(cx + side / 2),
            round(cy + side / 2),
        )
    )
    return crop.resize((SIZE, SIZE), Image.Resampling.LANCZOS), face_colour(rgba, box)


def srgb(colour: tuple[float, float, float]) -> str:
    return "srgb:" + ",".join(f"{c:.5f}" for c in colour) + ",1.00000"


def main() -> None:
    (TARGET / "Assets").mkdir(parents=True, exist_ok=True)
    fills = {}
    for name in ("light", "dark", "mono"):
        image, fills[name] = artwork(name)
        image.save(TARGET / "Assets" / f"{name}.png")
        print(f"{name}: face {tuple(round(c * 255) for c in fills[name])}")

    def layer(name: str, shown_in: str | None) -> dict:
        """One full-bleed layer, visible only in its own appearance (None = the default)."""
        hidden = [{"value": shown_in is not None}]
        for appearance in ("dark", "tinted"):
            hidden.append({"appearance": appearance, "value": appearance != shown_in})
        return {
            "image-name": f"{name}.png",
            "name": name,
            "glass": False,
            "hidden-specializations": hidden,
        }

    icon = {
        "fill-specializations": [
            {"value": {"solid": srgb(fills["light"])}},
            {"appearance": "dark", "value": {"solid": srgb(fills["dark"])}},
            {"appearance": "tinted", "value": {"solid": srgb(fills["mono"])}},
        ],
        "groups": [
            {
                "layers": [
                    layer("light", None),
                    layer("dark", "dark"),
                    layer("mono", "tinted"),
                ],
                # The logos carry their own light and depth: no extra glass, shadow or blur on top.
                "shadow": {"kind": "none", "opacity": 0},
                "specular": False,
                "translucency": {"enabled": False, "value": 0},
            }
        ],
        "supported-platforms": {"squares": ["macOS"]},
    }
    (TARGET / "icon.json").write_text(json.dumps(icon, indent=2) + "\n")
    print(f"wrote {TARGET}")


if __name__ == "__main__":
    main()
