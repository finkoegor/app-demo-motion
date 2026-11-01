#!/usr/bin/env python3
"""Finds where a simulator's screen sits in a snapshot of its window, for capture.

Usage: find_screen.py <window.png> <screenshot.png> [--pixels-per-point 2]

window.png comes from `capture --snapshot`, screenshot.png from
`xcrun simctl io <udid> screenshot` taken at the same moment, on a still screen (the home
screen is good). Prints the screen's rectangle in window points, as capture takes it:
x y width height.
"""
import argparse

import numpy as np
from PIL import Image


def gray(image, size=None):
    image = image.convert("L")
    if size:
        image = image.resize(size, Image.LANCZOS)
    return np.asarray(image, np.float64)


def ssd_map(window, template):
    """Sum of squared differences of the template at every offset in the window, by FFT."""
    wh, ww = window.shape
    th, tw = template.shape
    shape = (wh + th, ww + tw)
    f_window = np.fft.rfft2(window, shape)
    corr = np.fft.irfft2(f_window * np.conj(np.fft.rfft2(template, shape)), shape)[:wh - th + 1, :ww - tw + 1]
    ones = np.fft.irfft2(np.fft.rfft2(window ** 2, shape) * np.conj(np.fft.rfft2(np.ones_like(template), shape)), shape)[:wh - th + 1, :ww - tw + 1]
    return ones - 2 * corr + (template ** 2).sum()


def central(template, margin=0.15):
    """The middle of the screen: the corners are rounded and the clock moves."""
    h, w = template.shape
    y0, x0 = int(h * margin), int(w * margin)
    return template[y0:h - y0, x0:w - x0], x0, y0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("window")
    parser.add_argument("screenshot")
    parser.add_argument("--pixels-per-point", type=float, default=2)
    args = parser.parse_args()

    window_image = Image.open(args.window)
    shot = Image.open(args.screenshot)
    ww, wh = window_image.size
    sw, sh = shot.size

    # Coarse: a quarter of the window, every scale from a third of the screenshot to all of it.
    q = 4
    window_small = gray(window_image, (ww // q, wh // q))
    best = None
    for scale in np.arange(0.3, 1.01, 0.01):
        tw, th = round(sw * scale / q), round(sh * scale / q)
        if tw >= ww // q or th >= wh // q:
            continue
        patch, x0, y0 = central(gray(shot, (tw, th)))
        ssd = ssd_map(window_small, patch) / patch.size
        y, x = np.unravel_index(np.argmin(ssd), ssd.shape)
        if best is None or ssd[y, x] < best[0]:
            best = (ssd[y, x], scale, (x - x0) * q, (y - y0) * q)
    _, scale, ox, oy = best

    # Fine: full size, around the coarse answer.
    window_full = gray(window_image)
    fine = None
    for s in np.arange(scale - 0.012, scale + 0.012, 0.001):
        tw, th = round(sw * s), round(sh * s)
        patch, x0, y0 = central(gray(shot, (tw, th)))
        x_lo, y_lo = max(0, ox - 10 + x0), max(0, oy - 10 + y0)
        region = window_full[y_lo:y_lo + patch.shape[0] + 20, x_lo:x_lo + patch.shape[1] + 20]
        if region.shape[0] < patch.shape[0] or region.shape[1] < patch.shape[1]:
            continue
        ssd = ssd_map(region, patch) / patch.size
        y, x = np.unravel_index(np.argmin(ssd), ssd.shape)
        if fine is None or ssd[y, x] < fine[0]:
            fine = (ssd[y, x], tw, th, x_lo + x - x0, y_lo + y - y0)
    _, tw, th, x, y = fine
    ppp = args.pixels_per_point
    print(f"{x / ppp:g} {y / ppp:g} {tw / ppp:g} {th / ppp:g}")


if __name__ == "__main__":
    main()
