#!/usr/bin/env python3
"""Stampd app icon: dark-green field, cream postage stamp, orthographic globe
drawn from the app's own countries.geojson, dashed flight path, plane.

Output is the full-bleed 1024x1024 PNG (iOS rounds the corners itself).
Run from the repo root:  python3 scripts/make-appicon.py
"""
import json
import math
import os
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GEOJSON = os.path.join(ROOT, "CulinaryPassport", "Resources", "countries.geojson")
OUT = os.path.join(ROOT, "CulinaryPassport", "Resources", "Assets.xcassets",
                   "AppIcon.appiconset", "AppIcon1024.png")

S = 2  # supersample
W = 1024 * S

GREEN = (50, 78, 61)
CREAM = (244, 239, 228)

img = Image.new("RGB", (W, W), GREEN)
d = ImageDraw.Draw(img)

# ── Stamp with scalloped (bump) edges ────────────────────────────────────────
sx0, sy0, sx1, sy1 = 196 * S, 148 * S, 828 * S, 876 * S
r = 26 * S  # bump radius

d.rectangle([sx0, sy0, sx1, sy1], fill=CREAM)


def bumps(a, b, fixed, horizontal):
    """Circles centred on the stamp edge -> half sticks out as a scallop."""
    n = max(2, round((b - a) / (2.55 * r)))
    for i in range(n + 1):
        t = a + (b - a) * i / n
        cx, cy = (t, fixed) if horizontal else (fixed, t)
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=CREAM)


bumps(sx0, sx1, sy0, True)   # top
bumps(sx0, sx1, sy1, True)   # bottom
bumps(sy0, sy1, sx0, False)  # left
bumps(sy0, sy1, sx1, False)  # right

# ── Globe: orthographic projection of the real country polygons ─────────────
GCX, GCY, GR = 476 * S, 590 * S, 258 * S
LAT0, LON0 = math.radians(8), math.radians(12)  # Africa centre, Europe up top

d.ellipse([GCX - GR, GCY - GR, GCX + GR, GCY + GR],
          fill=CREAM, outline=GREEN, width=10 * S)


def project(lon, lat):
    lam, phi = math.radians(lon), math.radians(lat)
    cosc = (math.sin(LAT0) * math.sin(phi)
            + math.cos(LAT0) * math.cos(phi) * math.cos(lam - LON0))
    if cosc <= 0.02:
        return None
    x = math.cos(phi) * math.sin(lam - LON0)
    y = (math.cos(LAT0) * math.sin(phi)
         - math.sin(LAT0) * math.cos(phi) * math.cos(lam - LON0))
    return GCX + GR * 0.985 * x, GCY - GR * 0.985 * y


with open(GEOJSON) as f:
    geo = json.load(f)

globe_layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
gd = ImageDraw.Draw(globe_layer)

for feat in geo["features"]:
    g = feat["geometry"]
    polys = g["coordinates"] if g["type"] == "MultiPolygon" else [g["coordinates"]]
    for poly in polys:
        ring = poly[0]  # outer ring only; icon-scale has no visible holes
        pts = [p for p in (project(lon, lat) for lon, lat in ring) if p]
        if len(pts) < 3:
            continue
        # skip specks the perforation dwarfs anyway
        xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
        if (max(xs) - min(xs)) * (max(ys) - min(ys)) < (10 * S) ** 2:
            continue
        gd.polygon(pts, fill=GREEN)
        # fatten a touch so coastlines survive home-screen sizes
        gd.line(pts + [pts[0]], fill=GREEN, width=3 * S, joint="curve")

# clip continents to the globe disc, slightly inset so the rim stays clean
mask = Image.new("L", (W, W), 0)
ImageDraw.Draw(mask).ellipse(
    [GCX - GR + 7 * S, GCY - GR + 7 * S, GCX + GR - 7 * S, GCY + GR - 7 * S],
    fill=255)
img.paste(globe_layer, (0, 0), Image.composite(
    globe_layer.split()[3], Image.new("L", (W, W), 0), mask))

# left-limb crescent for a little depth, like the reference
d.arc([GCX - GR + 6 * S, GCY - GR + 6 * S, GCX + GR - 6 * S, GCY + GR - 6 * S],
      start=110, end=240, fill=GREEN, width=16 * S)

# ── Dashed flight path over the globe to a plane, top-right ─────────────────
P0 = (258 * S, 352 * S)
P1 = (430 * S, 118 * S)
P2 = (676 * S, 262 * S)


def bez(t):
    x = (1 - t) ** 2 * P0[0] + 2 * (1 - t) * t * P1[0] + t ** 2 * P2[0]
    y = (1 - t) ** 2 * P0[1] + 2 * (1 - t) * t * P1[1] + t ** 2 * P2[1]
    return x, y


steps = 260
pts = [bez(i / steps) for i in range(steps + 1)]
lens = [0.0]
for i in range(1, len(pts)):
    lens.append(lens[-1] + math.dist(pts[i - 1], pts[i]))
total, dash, gap = lens[-1], 25 * S, 19 * S
pos = 0.0
while pos < total - dash * 0.4:
    seg = [p for p, ln in zip(pts, lens) if pos <= ln <= pos + dash]
    if len(seg) >= 2:
        d.line(seg, fill=GREEN, width=9 * S, joint="curve")
    pos += dash + gap

# ── Plane silhouette, nose up-right ──────────────────────────────────────────
half = [
    (1.00, 0.000), (0.62, 0.035), (0.50, 0.045),   # nose -> wing root
    (0.16, 0.44), (0.06, 0.44), (0.26, 0.045),      # swept main wing
    (-0.12, 0.035),                                 # rear fuselage
    (-0.26, 0.20), (-0.34, 0.20), (-0.26, 0.028),   # tailplane
    (-0.30, 0.000),
]
outline = half + [(x, -y) for x, y in reversed(half[:-1])]
angle = math.radians(-38)  # up-right (screen y grows down)
LEN, PCX, PCY = 130 * S, 686 * S, 246 * S
plane = []
for x, y in outline:
    rx = x * math.cos(angle) - y * math.sin(angle)
    ry = x * math.sin(angle) + y * math.cos(angle)
    plane.append((PCX + rx * LEN, PCY + ry * LEN))
d.polygon(plane, fill=GREEN)

img = img.resize((1024, 1024), Image.LANCZOS)
img.save(OUT)
print("wrote", OUT)
