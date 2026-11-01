"""Lambent's Apple TV icon layers and Top Shelf banners, drawn from the sunset mark (assets/icons/moonfin_logo.svg).

    python3 tvos/scripts/make_lambent_icons.py tvos/Runner/Assets.xcassets <InstrumentSans-SemiBold.ttf>
"""
import os, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont

CAT, FONT = sys.argv[1], sys.argv[2]
SKY = [(0.0, (4, 6, 17)), (0.5, (14, 19, 42)), (1.0, (55, 48, 69))]   # top to horizon
SEA = [(0.0, (55, 48, 69)), (0.35, (19, 23, 44)), (1.0, (10, 16, 35))]  # horizon to bottom

def ramp(stops, t):
    t = np.clip(t, 0, 1)
    out = np.zeros(t.shape + (len(stops[0][1]),))
    for (a, ca), (b, cb) in zip(stops, stops[1:]):
        m = (t >= a) & (t <= b)
        f = ((t - a) / (b - a))[m][:, None]
        out[m] = np.array(ca) * (1 - f) + np.array(cb) * f
    return out

def sky(w, h, horizon):
    y = np.arange(h)[:, None].repeat(w, 1).astype(float)
    top = ramp(SKY, y / horizon)
    bottom = ramp(SEA, (y - horizon) / max(1, h - horizon))
    rgb = np.where((y < horizon)[..., None], top, bottom)
    return Image.fromarray(rgb.astype(np.uint8), "RGB").convert("RGBA")

def over(dst, rgb, alpha):
    # Straight-alpha "over" onto an RGBA float canvas (0-1).
    a = np.clip(alpha, 0, 1)[..., None]
    src = np.concatenate([np.broadcast_to(np.array(rgb, float) / 255, a.shape[:2] + (3,)), a], -1)
    out_a = src[..., 3:] + dst[..., 3:] * (1 - src[..., 3:])
    out_rgb = (src[..., :3] * src[..., 3:] + dst[..., :3] * dst[..., 3:] * (1 - src[..., 3:])) / np.maximum(out_a, 1e-6)
    dst[..., :3], dst[..., 3:] = out_rgb, out_a

def mark(w, h, s, ox, oy):
    """The mark drawn at scale s (px per SVG unit) with the SVG origin at (ox, oy), on transparency."""
    c = np.zeros((h, w, 4))
    Y, X = np.mgrid[0:h, 0:w].astype(float)
    u, v = (X - ox) / s, (Y - oy) / s  # SVG coordinates
    d = np.hypot(u - 512, v - 560) / 440
    glow = np.interp(d, [0, 0.55, 0.80, 1.0], [0.35, 0.35, 0.12, 0.0])
    over(c, (255, 150, 74), glow)
    refl = ((u >= 220) & (u <= 804) & (v >= 630) & (v <= 760)) * np.interp(v, [630, 760], [0.5, 0.0])
    over(c, (255, 162, 82), refl)
    r = np.hypot(u - 512, v - 630)
    sun = (r <= 292) & (v <= 630)
    t = (v - 338) / (630 - 338)
    sun_rgb = ramp([(0, (248, 107, 68)), (0.35, (255, 153, 84)), (0.65, (255, 192, 106)), (1, (255, 255, 207))], t)
    a = sun.astype(float)
    c[..., :3] = c[..., :3] * (1 - a[..., None]) + sun_rgb / 255 * a[..., None]
    c[..., 3] = c[..., 3] * (1 - a) + a
    halo = (np.abs(r - 324) <= 5) & (v <= 630)
    over(c, (255, 246, 228), halo.astype(float))
    horizon = ((v >= 627) & (v <= 632) & (u >= 120) & (u <= 904)) * np.interp(u, [120, 512, 904], [0, 0.9, 0])
    over(c, (255, 246, 228), horizon)
    return Image.fromarray((np.clip(c, 0, 1) * 255).astype(np.uint8), "RGBA")

def layout(w, h, mark_frac):
    # The sun's top (SVG y 338) to the horizon (y 630) takes mark_frac of the height; the horizon sits at 62%.
    s = mark_frac * h / (630 - 338)
    horizon = 0.62 * h
    return s, horizon - 630 * s, horizon

def supersampled(fn, w, h):
    return fn(w * 2, h * 2).resize((w, h), Image.LANCZOS)

def icon_layers(w, h):
    def back(W, H):
        return sky(W, H, layout(W, H, 0.42)[2])
    def front(W, H):
        s, oy, _ = layout(W, H, 0.42)
        return mark(W, H, s, W / 2 - 512 * s, oy)
    return supersampled(back, w, h), supersampled(front, w, h)

def shelf(w, h):
    def draw(W, H):
        s, oy, horizon = layout(W, H, 0.34)
        img = sky(W, H, horizon)
        font = ImageFont.truetype(FONT, int(H * 0.2))
        text = "Lambent"
        tw = ImageDraw.Draw(img).textlength(text, font=font)
        gap, mark_w = 0.04 * W, 2 * 324 * s
        x0 = (W - (mark_w + gap + tw)) / 2
        img.alpha_composite(mark(W, H, s, x0 + mark_w / 2 - 512 * s, oy))
        d = ImageDraw.Draw(img)
        asc, desc = font.getmetrics()
        d.text((x0 + mark_w + gap, horizon - asc * 0.98), text, font=font, fill=(255, 250, 240, 255))
        return img
    return supersampled(draw, w, h).convert("RGB")

B = os.path.join(CAT, "AppIcon.brandassets")
for stack, name, sizes in [("App Icon.imagestack", "App-Icon-Small", [(400, 240), (800, 480)]),
                           ("App Icon - App Store.imagestack", "App-Icon-Large", [(1280, 768), (2560, 1536)])]:
    for scale, (w, h) in zip((1, 2), sizes):
        back, front = icon_layers(w, h)
        back.convert("RGB").save(os.path.join(B, stack, "Back.imagestacklayer/Content.imageset", f"{name}-{scale}x.png"))
        front.save(os.path.join(B, stack, "Front.imagestacklayer/Content.imageset", f"{name}-{scale}x.png"))
for folder, name, sizes in [("Top Shelf Image.imageset", "Top-Shelf", [(1920, 720), (3840, 1440)]),
                            ("Top Shelf Image Wide.imageset", "Top-Shelf-Wide", [(2320, 720), (4640, 1440)])]:
    for scale, (w, h) in zip((1, 2), sizes):
        shelf(w, h).save(os.path.join(B, folder, f"{name}-{scale}x.png"))
print("done")
