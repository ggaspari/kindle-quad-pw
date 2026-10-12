"""Kindle Paperwhite (1st gen, jailbroken) as a second kind of screen.

The PW1 is a 6" 758x1024 panel at 212 ppi with 16 grey levels. We lay the
board out landscape on a logical 800 x 592 canvas (same width as the E1001,
so every panel keeps its proportions, just with taller cells), anti-aliased,
then scale it to 1024 x 758, snap to 16 greys and rotate it into the panel's
native portrait framebuffer. The Kindle just fetches the PNG and hands it to
eips/FBInk; taps come back as raw panel coordinates and are mapped here.

Render under board.cond: this swaps render.py's layout globals for the
duration, and every other render path also runs under that lock.
"""
from __future__ import annotations

from PIL import Image, ImageFilter

import render as R

NATIVE = (758, 1024)                 # PW1 framebuffer, portrait
LAND = (NATIVE[1], NATIVE[0])        # 1024 x 758 once turned sideways
LOGICAL_W = 800
LOGICAL_H = round(LOGICAL_W * LAND[1] / LAND[0])    # 592

NAV_HINT = "tap  left: back  ·  right: next  ·  middle: home"
NAV_HINT_PT = "toque  esquerda: voltar  ·  direita: próxima  ·  meio: início"


def _layout(w, h):
    R.W, R.H = w, h
    R.CELL_W, R.CELL_H = w // 2, (h - R.GRID_Y) // 2
    R.BODY = (w, h - R.GRID_Y)


def landscape(ctx: R.Ctx) -> Image.Image:
    """The board as a 1024 x 758 L image, 16 grey levels, not yet rotated."""
    saved = (R.W, R.H, R.CELL_W, R.CELL_H, R.BODY, R.AA, R.NAV_HINT, R.NAV_HINT_PT)
    try:
        _layout(LOGICAL_W, LOGICAL_H)
        R.AA = True
        R.NAV_HINT, R.NAV_HINT_PT = NAV_HINT, NAV_HINT_PT
        img = R._compose_l(ctx)
    finally:
        R.W, R.H, R.CELL_W, R.CELL_H, R.BODY, R.AA, R.NAV_HINT, R.NAV_HINT_PT = saved
    img = img.resize(LAND, Image.LANCZOS)
    # the 1.28x upscale softens edges a touch; e-paper also reads greys
    # lighter than a monitor, so sharpen and pull the mid-tones darker
    img = img.filter(ImageFilter.UnsharpMask(radius=1.2, percent=70, threshold=1))
    lut = [round(255 * (v / 255) ** 1.35) for v in range(256)]
    img = img.point(lut)
    img = img.point(lambda v: (v * 15 + 127) // 255 * 17)     # 16 levels: 0, 17 .. 255
    if ctx.cfg.get("dark", False):
        img = img.point(lambda v: 255 - v)
    return img


def frame(ctx: R.Ctx, rotate: int = 90) -> Image.Image:
    """Native 758 x 1024 frame ready for eips -g / fbink -g. rotate is 90 or
    270: which way round the Kindle lies on its side."""
    return landscape(ctx).rotate(270 if rotate % 360 == 270 else 90, expand=True)


def tap_zone(x: int, y: int, rotate: int = 90, flip: str = "") -> tuple[str, int, int]:
    """Raw touch (native portrait px) -> ("left"|"middle"|"right", lx, ly) in
    the landscape picture. flip: "x", "y" or "xy" if the digitizer's axes run
    opposite to the framebuffer's (check with `quad.sh touchtest`)."""
    nw, nh = NATIVE
    if "x" in flip:
        x = nw - 1 - x
    if "y" in flip:
        y = nh - 1 - y
    lw, lh = LAND
    # inverse of PIL's counter-clockwise Image.rotate(rotate, expand=True)
    if rotate % 360 == 270:
        lx, ly = y, lh - 1 - x
    else:
        lx, ly = lw - 1 - y, x
    zone = "left" if lx < lw / 3 else "right" if lx >= lw * 2 / 3 else "middle"
    return zone, int(lx), int(ly)


def battery_pct(v):
    """The Kindle reports its own percentage (lipc battLevel); just sanitise it."""
    try:
        return max(0, min(100, int(float(v))))
    except (TypeError, ValueError):
        return None
