#!/usr/bin/env python3
"""Pixel-level verification for a3b-buddy UI checks.

Usage:
  python3 verify_visual.py center   <image> <expected_x_frac> <expected_y_frac> <tol_px>
  python3 verify_visual.py color    <image> <x> <y> <expected_hex> <tolerance>
  python3 verify_visual.py present  <image> <template_image> <min_confidence>

Exit code 0 = PASS, 1 = FAIL. Prints measured values either way.
"""
import sys
from PIL import Image

def find_content_bbox(img, bg_tolerance=12):
    """Bounding box of non-background pixels (background = corner color)."""
    rgb = img.convert("RGB")
    corner = rgb.getpixel((0, 0))
    w, h = rgb.size
    xs, ys = [], []
    px = rgb.load()
    for y in range(0, h, 2):
        for x in range(0, w, 2):
            p = px[x, y]
            if any(abs(p[i] - corner[i]) > bg_tolerance for i in range(3)):
                xs.append(x); ys.append(y)
    if not xs:
        return None
    return (min(xs), min(ys), max(xs), max(ys))

def cmd_center(image_path, ex_frac, ey_frac, tol_px):
    img = Image.open(image_path)
    bbox = find_content_bbox(img)
    if bbox is None:
        print("FAIL: no content found in image"); return 1
    cx = (bbox[0] + bbox[2]) / 2
    cy = (bbox[1] + bbox[3]) / 2
    tx = img.width * float(ex_frac)
    ty = img.height * float(ey_frac)
    dx, dy = abs(cx - tx), abs(cy - ty)
    ok = dx <= float(tol_px) and dy <= float(tol_px)
    print(f"content center=({cx:.0f},{cy:.0f}) target=({tx:.0f},{ty:.0f}) "
          f"offset=({dx:.0f},{dy:.0f}) tol={tol_px} -> {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1

def cmd_color(image_path, x, y, expected_hex, tolerance):
    img = Image.open(image_path).convert("RGB")
    p = img.getpixel((int(x), int(y)))
    e = expected_hex.lstrip("#")
    exp = tuple(int(e[i:i+2], 16) for i in (0, 2, 4))
    diff = max(abs(p[i] - exp[i]) for i in range(3))
    ok = diff <= int(tolerance)
    print(f"pixel({x},{y})=#{p[0]:02x}{p[1]:02x}{p[2]:02x} expected=#{e} "
          f"maxdiff={diff} tol={tolerance} -> {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1

def cmd_present(image_path, template_path, min_conf):
    # Simple presence check: template's average color appears in image region scan.
    # For robust matching install opencv-python and use cv2.matchTemplate.
    try:
        import cv2, numpy as np
        img = cv2.imread(image_path); tpl = cv2.imread(template_path)
        res = cv2.matchTemplate(img, tpl, cv2.TM_CCOEFF_NORMED)
        conf = float(res.max())
        ok = conf >= float(min_conf)
        print(f"template match confidence={conf:.3f} min={min_conf} -> {'PASS' if ok else 'FAIL'}")
        return 0 if ok else 1
    except ImportError:
        print("FAIL: install opencv-python for template matching "
              "(pip3 install opencv-python --break-system-packages)")
        return 1

if __name__ == "__main__":
    cmd = sys.argv[1]
    fn = {"center": cmd_center, "color": cmd_color, "present": cmd_present}[cmd]
    sys.exit(fn(*sys.argv[2:]))
