"""Lambent's iPhone and iPad app icon, drawn from the same sunset mark as the Apple TV icon (tvos/scripts/make_lambent_icons.py).

    python3 ios/scripts/make_lambent_icons.py ios/Runner/Assets.xcassets/AppIcon.appiconset
"""
import json, os, sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../tvos/scripts"))
from make_lambent_icons import layout, mark, sky, supersampled  # noqa: E402

def icon(size):
    # Square and opaque: iOS masks the corners itself and rejects alpha in the App Store icon.
    def draw(W, H):
        s, oy, horizon = layout(W, H, 0.27)
        img = sky(W, H, horizon)
        img.alpha_composite(mark(W, H, s, W / 2 - 512 * s, oy))
        return img
    return supersampled(draw, size, size).convert("RGB")

if __name__ == "__main__":
    SET = sys.argv[1]
    master = icon(1024)
    for entry in json.load(open(os.path.join(SET, "Contents.json")))["images"]:
        if "filename" not in entry:
            continue
        px = round(float(entry["size"].split("x")[0]) * int(entry["scale"].rstrip("x")))
        img = master if px == 1024 else master.resize((px, px), resample=1)  # LANCZOS
        img.save(os.path.join(SET, entry["filename"]))
    print("done")
