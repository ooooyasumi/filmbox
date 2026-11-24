#!/usr/bin/env python3
"""Render Android vector resources from the exact macOS production identity.

The Android layer is 108 dp; its central 72 dp becomes the launcher viewport.
Map the Mac container (rather than its transparent canvas margin) to that
viewport, keeping the mark's proportions and internal whitespace unchanged.
"""
import argparse
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--check", action="store_true", help="Reject stale resources without writing")
args = parser.parse_args()
spec_path = root / "design/lighttable-v1.1/identity-spec.json"
spec = json.loads(spec_path.read_text())
icon, mark = spec["appIcon"], spec["mark"]
assert not icon["blueContainer"]
assert len(mark["rectangles"]) == 4
res = root / "Android/app/src/main/res"

def number(value):
    return format(value, ".10f").rstrip("0").rstrip(".")

def paths():
    values = []
    for index, (x, y, w, h) in enumerate(mark["rectangles"]):
        color = mark["fixedBlue"] if index == mark["fixedBlueRectangleIndex"] else mark["bodyOnLight"]
        values.append(f'        <path android:fillColor="{color}" android:pathData="M{number(x)},{number(y)}h{number(w)}v{number(h)}h-{number(w)}z" />')
    return "\n".join(values)

cx, cy, cw, ch = icon["container"]
gx, gy = icon["glyphOrigin"]
scale = icon["glyphScale"]
radius = icon["cornerRadius"]
right, bottom = cx + cw, cy + ch
container_path = (
    f"M{cx + radius},{cy}H{right - radius}A{radius},{radius} 0,0 1,{right} {cy + radius}"
    f"V{bottom - radius}A{radius},{radius} 0,0 1,{right - radius} {bottom}"
    f"H{cx + radius}A{radius},{radius} 0,0 1,{cx} {bottom - radius}"
    f"V{cy + radius}A{radius},{radius} 0,0 1,{cx + radius} {cy}Z"
)
foreground = f'''<?xml version="1.0" encoding="utf-8"?>
<!-- Generated from design/lighttable-v1.1/identity-spec.json. -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp" android:height="108dp"
    android:viewportWidth="108" android:viewportHeight="108">
    <group android:translateX="{number(18 + (gx - cx) * 72 / cw)}"
        android:translateY="{number(18 + (gy - cy) * 72 / ch)}"
        android:scaleX="{number(scale * 72 / cw)}" android:scaleY="{number(scale * 72 / ch)}">
{paths()}
    </group>
</vector>
'''
legacy = f'''<?xml version="1.0" encoding="utf-8"?>
<!-- The unchanged macOS production master, for non-adaptive uses. -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp" android:height="108dp"
    android:viewportWidth="{icon['canvas']}" android:viewportHeight="{icon['canvas']}">
    <path android:fillColor="{icon['containerOnLight']}"
        android:pathData="{container_path}" />
    <group android:translateX="{gx}" android:translateY="{gy}"
        android:scaleX="{scale}" android:scaleY="{scale}">
{paths()}
    </group>
</vector>
'''
# Keep the approved blue accent in the launcher icon. Do not replace this with
# the dark UI mark or a monochrome layer that substitutes wallpaper colors.
expected = {
    res / "drawable/filmbox_foreground.xml": foreground,
    res / "drawable/filmbox_icon.xml": legacy,
    res / "values/colors.xml": f'<resources><color name="icon_background">{icon["containerOnLight"]}</color></resources>\n',
}
obsolete = [res / "drawable/filmbox_monochrome.xml", res / "mipmap-anydpi-v33/ic_launcher.xml"]
stale = [str(path.relative_to(root)) for path, text in expected.items() if not path.exists() or path.read_text() != text]
stale.extend(str(path.relative_to(root)) for path in obsolete if path.exists())
if args.check:
    if stale:
        raise SystemExit("Android icon differs from the Mac master: " + ", ".join(stale))
    print("Android icon matches the macOS production identity.")
else:
    for path, text in expected.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    for path in obsolete:
        path.unlink(missing_ok=True)
    print("Generated Android icon from the macOS production identity.")
