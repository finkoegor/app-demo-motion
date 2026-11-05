#!/usr/bin/env python3
"""Turns a simulator take into a promo clip.

Usage: compose.py <take-dir> <out.mp4> [options]

The take dir holds the recording, rec.mp4 from record.sh or rec.mov and rec.json from
record-lossless.sh, and taps.json (when and where each press landed, in screen points,
timed from the app's run). A press with "gesture":
"pinch" is drawn as two fingers closing in on its point instead of a tap; one with
"gesture": "swipe" lands at (x, y) and travels to (x2, y2) over "duration" seconds on an
ease in and out, as the app moves its control. The clip puts the recording
inside a phone bezel on a background, moves a camera over it and draws a ring at every
press. Run with --help for the options.

The taps are timed from the start of the app's run, the recording from the start of
recording. They are lined up by the frames: a press is followed at once by a change on
screen, so the offset is the one that puts each press about a frame before a change.
"""
import argparse
import json
import math
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

FPS = 60
RING_LEAD = 0.12
# A pinch: half the distance between the fingers as they land and as they lift, in
# screen points, and the slant of the line through them.
PINCH_SPREAD = (110, 46)
PINCH_ANGLE = math.radians(-38)

# For simctl takes: the steps its compression leaves in dark gradients are about 40
# pixels apart, so the filter looks that far around each pixel.
DEBAND = "deband=1thr=0.02:2thr=0.02:3thr=0.02:range=48:direction=-3.14159:blur=1"

# Apple's iPhone 18 Pro Max bezels, by color, looked for in bezels/ next to scripts/.
BEZELS = Path(__file__).resolve().parent.parent / "bezels"
BEZEL_COLORS = ["black", "silver", "glacier", "burgundy"]
DEFAULT_COLORS = ["#c9b8ff", "#ffc9a8", "#9fd8ff", "#ffb3d1", "#c4e2ff"]
# Where the gradient's colors sit, as shares of the canvas, for up to eight colors.
COLOR_SPOTS = [(0.08, 0.12), (0.92, 0.08), (0.10, 0.92), (0.90, 0.90), (0.50, 0.55), (0.50, 0.05), (0.05, 0.50), (0.95, 0.50)]


def ease_in_out(t):
    t = min(max(t, 0.0), 1.0)
    return 4 * t * t * t if t < 0.5 else 1 - (-2 * t + 2) ** 3 / 2


def ease_out(t):
    t = min(max(t, 0.0), 1.0)
    return 1 - (1 - t) ** 3


def parse_color(text):
    text = text.strip().lstrip("#")
    return tuple(int(text[i:i + 2], 16) for i in (0, 2, 4))


# Recording ------------------------------------------------------------------------

def probe(video):
    """Size in pixels and every frame's time, as the recording is variable frame rate."""
    out = subprocess.run(
        ["ffprobe", "-loglevel", "error", "-select_streams", "v", "-show_entries", "stream=width,height:frame=pts_time",
         "-of", "csv=p=0", str(video)],
        capture_output=True, text=True, check=True).stdout.replace(",", " ").split("\n")
    size = None
    pts = []
    for line in out:
        parts = line.split()
        if len(parts) == 2 and size is None:
            size = (int(parts[0]), int(parts[1]))
        elif len(parts) == 1:
            pts.append(float(parts[0]))
    return size, pts


def change_onsets(video, pts):
    """Times when the screen starts changing after a quarter second of rest."""
    w, h = 100, 217
    raw = subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-i", str(video), "-vf", f"scale={w}:{h}", "-fps_mode", "passthrough",
         "-f", "rawvideo", "-pix_fmt", "gray", "-"],
        capture_output=True, check=True).stdout
    frames = np.frombuffer(raw, np.uint8).reshape(-1, h, w).astype(np.int16)
    onsets, last_change = [], -1.0
    for i in range(1, min(len(frames), len(pts))):
        if np.abs(frames[i] - frames[i - 1]).mean() > 0.6:
            if pts[i] - last_change > 0.25:
                onsets.append(pts[i])
            last_change = pts[i]
    return np.array(onsets)


def load_timeline(path):
    """The presses and, when the app wrote it, the wall clock time the run began."""
    if not path.exists():
        return [], None
    data = json.loads(path.read_text())
    if isinstance(data, list):
        return data, None
    return data.get("taps", []), data.get("started")


def first_frame_wall_time(video, duration):
    """When the recording's first frame was taken: the recorder creates the file as it
    captures it. Without a birth time, the last write less the duration, which runs
    late by however long the screen stood still at the end."""
    stat = video.stat()
    return getattr(stat, "st_birthtime", None) or (stat.st_mtime - duration)


def sync_offset(taps, onsets, anchor=None):
    """The video time of the run's start that puts each press about a frame before a
    change. With an anchor from the wall clock, only offsets near it count: an app
    that keeps redrawing while it loads can otherwise match the presses to the wrong
    changes."""
    if not len(onsets) or not taps:
        return anchor or 0.0
    times = np.array([tap["time"] for tap in taps])
    # The run may begin before the recording, when the app is launched first and waits
    # for something from outside: the offset is then below zero.
    low, high = (anchor - 0.25, anchor + 0.25) if anchor is not None else (0, onsets.max())
    best, best_cost = low, math.inf
    for offset in np.arange(low, high, 1 / 240):
        # The presses sit as close before their changes as they can without passing one.
        cost = 0.0
        for t in times + offset:
            after = onsets[onsets >= t - 0.02]
            lag = after[0] - t if len(after) else 10
            cost += lag if lag < 0.6 else 10
        if cost < best_cost:
            best, best_cost = offset, cost
    return best


# Phone ----------------------------------------------------------------------------

class Phone:
    """The bezel around the recording: a PNG with a transparent screen hole, scaled so the
    hole matches the recording, or a plain drawn one. Holds the layer under the screen
    (its shadow), the layer over it (the bezel) and where the screen goes."""

    def __init__(self, screen_size, bezel_path, corner_points, scale, shadow):
        self.screen_w, self.screen_h = screen_size
        pad = int(80 * scale)
        if bezel_path:
            bezel, hole = self.load_bezel(bezel_path)
        else:
            bezel, hole = self.draw_bezel(scale, corner_points * scale)
        self.width, self.height = bezel.width + pad * 2, bezel.height + pad * 2
        self.origin = (pad + hole[0], pad + hole[1])
        self.mask = hole[2]
        self.body_height = bezel.height

        self.base = Image.new("RGBA", (self.width, self.height), (0, 0, 0, 0))
        if shadow:
            body = Image.new("L", (self.width, self.height), 0)
            body.paste(bezel.split()[3], (pad, pad + int(14 * scale)))
            body.paste(255, (self.origin[0], self.origin[1] + int(14 * scale),
                             self.origin[0] + self.screen_w, self.origin[1] + int(14 * scale) + self.screen_h))
            blur = body.filter(ImageFilter.GaussianBlur(28 * scale)).point(lambda a: int(a * 0.32))
            self.base = Image.new("RGBA", (self.width, self.height), (30, 16, 60, 255))
            self.base.putalpha(blur)
        self.cover = Image.new("RGBA", (self.width, self.height), (0, 0, 0, 0))
        self.cover.paste(bezel, (pad, pad))

    def load_bezel(self, path):
        source = Image.open(path).convert("RGBA")
        alpha = np.asarray(source.split()[3])
        cy, cx = source.height // 2, source.width // 2
        if alpha[cy, cx] > 127:
            sys.exit("The bezel's screen must be transparent in the middle of the image")
        hole = Image.fromarray(np.where(alpha < 250, 255, 0).astype(np.uint8), "L").copy()
        ImageDraw.floodfill(hole, (cx, cy), 128)
        hole = np.asarray(hole) == 128
        ys, xs = np.where(hole)
        left, top, right, bottom = xs.min(), ys.min(), xs.max() + 1, ys.max() + 1
        # Bring the bezel to the recording's scale, so the hole is the screen's size.
        factor = self.screen_w / (right - left)
        size = (round(source.width * factor), round(source.height * factor))
        bezel = source.resize(size, Image.LANCZOS)
        hole_mask = Image.fromarray(hole.astype(np.uint8) * 255, "L").resize(size, Image.LANCZOS)
        hole_mask = hole_mask.filter(ImageFilter.MaxFilter(5))
        left, top = round(left * factor), round(top * factor)
        mask = hole_mask.crop((left, top, left + self.screen_w, top + self.screen_h))
        return bezel, (left, top, mask)

    def draw_bezel(self, scale, corner):
        """A plain dark body with a soft edge, for when no bezel image is given."""
        border = int(18 * scale)
        w, h = self.screen_w + border * 2, self.screen_h + border * 2
        s = 4
        big = Image.new("RGBA", (w * s, h * s), (0, 0, 0, 0))
        draw = ImageDraw.Draw(big)
        radius = (corner + border) * s
        draw.rounded_rectangle((0, 0, w * s - 1, h * s - 1), radius=radius, fill=(28, 28, 30, 255))
        draw.rounded_rectangle((0, 0, w * s - 1, h * s - 1), radius=radius, outline=(70, 70, 74, 255), width=int(2 * scale * s))
        draw.rounded_rectangle((border * s, border * s, (w - border) * s - 1, (h - border) * s - 1), radius=corner * s, fill=(0, 0, 0, 0))
        bezel = big.resize((w, h), Image.LANCZOS)
        mask = Image.new("L", (self.screen_w * s, self.screen_h * s), 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, self.screen_w * s - 1, self.screen_h * s - 1), radius=corner * s, fill=255)
        mask = mask.resize((self.screen_w, self.screen_h), Image.LANCZOS)
        return bezel, (border, border, mask)

    def frame(self, screen):
        """The phone with this screen frame on it."""
        layer = self.base.copy()
        layer.paste(screen, self.origin, self.mask)
        layer.alpha_composite(self.cover)
        return layer


# Background -----------------------------------------------------------------------

def gradient(size, colors):
    """A mesh of soft colors: each point's color weighs in by a Gaussian of its distance."""
    ys, xs = np.mgrid[0:size, 0:size].astype(np.float32) / size
    total = np.zeros((size, size, 3), np.float32)
    weights = np.zeros((size, size), np.float32)
    for (px, py), color in zip(COLOR_SPOTS, colors):
        w = np.exp(-((xs - px) ** 2 + (ys - py) ** 2) / (2 * 0.32 ** 2))
        total += w[..., None] * np.array(color, np.float32)
        weights += w
    image = total / weights[..., None]
    # Grain keeps the encoder from banding the gradient.
    image += np.random.default_rng(7).normal(0, 1.2, image.shape)
    return Image.fromarray(np.clip(image, 0, 255).astype(np.uint8), "RGB")


def background(kind, colors, size, grain):
    """Larger than the frame, for the camera to pan over."""
    big = int(max(size) * 1.25)
    if kind == "gradient":
        return gradient(big, colors)
    if kind.startswith("#"):
        return Image.new("RGB", (big, big), parse_color(kind))
    image = Image.open(kind).convert("RGB")
    # Cover the square, centered.
    factor = max(big / image.width, big / image.height)
    image = image.resize((round(image.width * factor), round(image.height * factor)), Image.LANCZOS)
    left, top = (image.width - big) // 2, (image.height - big) // 2
    image = image.crop((left, top, left + big, top + big))
    # A soft picture in 8 bits shows steps once encoded; grain breaks them up.
    pixels = np.asarray(image, np.float32) + np.random.default_rng(7).normal(0, grain, (big, big, 1))
    return Image.fromarray(np.clip(pixels, 0, 255).astype(np.uint8), "RGB")


# Camera ---------------------------------------------------------------------------

class Camera:
    """Zoom and focus point (in screen points) over time, eased between moves."""

    def __init__(self, moves, center):
        self.moves = sorted(moves, key=lambda m: m[0])
        self.center = center

    def at(self, t):
        state = (1.0, self.center)
        for start, duration, zoom, target in self.moves:
            target = target or self.center
            if t <= start:
                break
            p = ease_in_out((t - start) / max(duration, 0.01))
            state = (
                state[0] + (zoom - state[0]) * p,
                (state[1][0] + (target[0] - state[1][0]) * p, state[1][1] + (target[1] - state[1][1]) * p),
            )
        return state


def tap_time(text, taps):
    """A time in seconds, or "tap<N>" with an optional shift, like "tap2-0.4"."""
    if isinstance(text, (int, float)):
        return float(text)
    text = text.strip()
    if not text.startswith("tap"):
        return float(text)
    rest = text[3:]
    for i, c in enumerate(rest):
        if c in "+-":
            return taps[int(rest[:i]) - 1]["time"] + float(rest[i:])
    return taps[int(rest) - 1]["time"] if rest else taps[0]["time"]


def camera_moves(spec, taps, center):
    """Moves from a JSON file, "auto" (in on every press, out after it) or "none"."""
    if spec == "none":
        return []
    if spec == "auto":
        moves = []
        for tap in taps:
            moves.append((tap["time"] - 0.45, 0.9, 1.35, (tap["x"], tap["y"])))
            moves.append((tap["time"] + 1.1, 0.8, 1.0, None))
        return moves
    plan = json.loads(Path(spec).read_text())
    moves = []
    for move in plan:
        focus = move.get("focus")
        moves.append((tap_time(move["at"], taps), float(move.get("duration", 0.9)), float(move.get("zoom", 1.0)),
                      (float(focus[0]), float(focus[1])) if focus else None))
    return moves


# Drawing --------------------------------------------------------------------------

def place(frame, layer, scale, ox, oy):
    """Draws `layer` onto `frame` with its pixel (x, y) at (ox + x * scale, oy + y * scale),
    resampling only what is in view."""
    fw, fh = frame.size
    x0, y0 = max(0.0, ox), max(0.0, oy)
    x1, y1 = min(fw, ox + layer.width * scale), min(fh, oy + layer.height * scale)
    if x1 <= x0 or y1 <= y0:
        return
    ix0, iy0, ix1, iy1 = math.floor(x0), math.floor(y0), math.ceil(x1), math.ceil(y1)
    box = (
        max(0.0, (ix0 - ox) / scale), max(0.0, (iy0 - oy) / scale),
        min(layer.width, (ix1 - ox) / scale), min(layer.height, (iy1 - oy) / scale),
    )
    piece = layer.resize((ix1 - ix0, iy1 - iy0), Image.LANCZOS, box=box)
    frame.alpha_composite(piece, (ix0, iy0))


def ring(frame, cx, cy, radius, alpha, style):
    """A thick ring: grey with a white rim and a soft shadow, which stays visible over
    white buttons, or plain white as in the reference clips."""
    if alpha <= 0.01 or radius < 1:
        return
    # Room for the shadow: its blur reaches about three times its radius past the ring,
    # and it sits a little lower.
    blur = radius * 0.12 + 2
    r = int(radius + 3 * blur + radius * 0.05 + 4)
    x0, y0 = int(cx) - r, int(cy) - r
    ys, xs = np.mgrid[y0:y0 + 2 * r, x0:x0 + 2 * r].astype(np.float32)
    d = np.hypot(xs + 0.5 - cx, ys + 0.5 - cy)
    inner = radius * 0.6
    body = np.clip(radius - d + 0.75, 0, 1) * np.clip(d - inner + 0.75, 0, 1)
    spot = np.zeros((2 * r, 2 * r, 4), np.float32)
    if style == "white":
        spot[..., :3] = 255
        spot[..., 3] = body * 0.55 * 255 * alpha
        frame.alpha_composite(Image.fromarray(spot.astype(np.uint8), "RGBA"), (x0, y0))
        return
    rim = np.clip(np.exp(-((d - radius + 1) / 1.1) ** 2) + np.exp(-((d - inner - 1) / 1.1) ** 2), 0, 1) * body
    shadow = Image.fromarray((body * 255).astype(np.uint8), "L").filter(ImageFilter.GaussianBlur(blur))
    shade = np.zeros((2 * r, 2 * r, 4), np.uint8)
    shade[..., 3] = (np.asarray(shadow, np.float32) * 0.35 * alpha).astype(np.uint8)
    frame.alpha_composite(Image.fromarray(shade, "RGBA"), (x0, y0 + max(1, int(radius * 0.05))))
    grey, white = 0.62 * (1 - rim), rim
    total = np.maximum(grey + white, 1e-3)[..., None]
    spot[..., :3] = (155 * grey[..., None] + 255 * white[..., None]) / total
    spot[..., 3] = np.clip(body * 0.62 + rim * 0.3, 0, 1) * 255 * alpha
    frame.alpha_composite(Image.fromarray(spot.astype(np.uint8), "RGBA"), (x0, y0))


def ring_shape(age):
    """Radius share and opacity of a ring `age` seconds after it appears: it opens out,
    then draws in a little as it fades."""
    if age < 0 or age > 0.55:
        return 0, 0
    if age < 0.2:
        return 0.45 + 0.55 * ease_out(age / 0.2), min(1, age / 0.06)
    q = (age - 0.2) / 0.35
    return 1 - 0.2 * ease_in_out(q), (1 - q) ** 1.5


def pinch_shape(age):
    """The fingers of a pinch `age` seconds after its press: how far they have closed in,
    as a share of the way, and each ring's radius share and opacity. They land apart a
    beat before the press, close in through it, the app answering halfway, and lift."""
    if age < -0.42 or age > 0.6:
        return 0, 0, 0
    landed = age + 0.42
    if landed < 0.15:
        share, alpha = 0.45 + 0.55 * ease_out(landed / 0.15), min(1, landed / 0.06)
    else:
        share, alpha = 1, 1
    if age > 0.3:
        q = (age - 0.3) / 0.3
        share, alpha = 1 - 0.2 * ease_in_out(q), (1 - q) ** 1.5
    return ease_in_out((age + 0.3) / 0.6), share, alpha


def swipe_finger(tap, t):
    """Where the finger of a swipe is at `t`, its ring's radius share and opacity: it
    lands just before the press, travels with the control, and lifts at the end."""
    age = t - tap["time"]
    duration = float(tap.get("duration", 0.6))
    if age < -0.15 or age > duration + 0.32:
        return None
    start, end = (tap["x"], tap["y"]), (tap.get("x2", tap["x"]), tap.get("y2", tap["y"]))
    p = ease_in_out(age / duration) if age > 0 else 0
    point = (start[0] + (end[0] - start[0]) * p, start[1] + (end[1] - start[1]) * p)
    if age < 0:
        landed = age + 0.15
        return point, 0.45 + 0.55 * ease_out(landed / 0.15), min(1, landed / 0.06)
    if age <= duration:
        return point, 1, 1
    q = (age - duration) / 0.32
    return point, 1 - 0.2 * ease_in_out(q), (1 - q) ** 1.5


def pinch_fingers(cx, cy, closed):
    """Where the two fingers of a pinch around (cx, cy) are, in screen points."""
    half = PINCH_SPREAD[0] + (PINCH_SPREAD[1] - PINCH_SPREAD[0]) * closed
    dx, dy = half * math.cos(PINCH_ANGLE), half * math.sin(PINCH_ANGLE)
    return [(cx - dx, cy - dy), (cx + dx, cy + dy)]


def warn_off_screen(taps, width, height):
    """A press outside the screen means a stale frame: a control in a row that scrolled
    after it was measured, for one. Its ring would be drawn off the phone."""
    for index, tap in enumerate(taps, 1):
        if not (0 <= tap["x"] <= width and 0 <= tap["y"] <= height):
            print(f"press {index} ({tap.get('target', '?')}) is off the screen at {tap['x']:.0f}, {tap['y']:.0f}: "
                  "fix its point in taps.json", file=sys.stderr)


# Main -----------------------------------------------------------------------------

def parse_args():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("take", type=Path, help="folder with rec.mp4 and taps.json")
    parser.add_argument("out", type=Path, help="the clip to write")
    parser.add_argument("--size", default="1920x1920", help="output size, like 1920x1920, 1080x1350 or 1080x1920")
    parser.add_argument("--fps", type=int, default=FPS)
    parser.add_argument("--bezel", default="black", help="black, silver, glacier or burgundy for the iPhone 18 Pro Max bezels in bezels/, a PNG of a phone with a transparent screen, or plain for a drawn body")
    parser.add_argument("--corner", type=float, default=55, help="screen corner radius in points for the drawn bezel")
    parser.add_argument("--scale", type=float, default=3, help="recording pixels per screen point")
    parser.add_argument("--share", type=float, default=0.86, help="share of the frame's height the phone takes in the wide shot")
    parser.add_argument("--phone-y", type=float, default=0.5, help="where the phone's middle sits in the wide shot, as a share of the frame's height; zooming in brings it back to the middle, leaving room above or below for an overlay")
    parser.add_argument("--no-shadow", action="store_true")
    parser.add_argument("--background", default="gradient", help="gradient, a #hex color, or an image file")
    parser.add_argument("--colors", default=",".join(DEFAULT_COLORS), help="gradient colors, comma separated hex")
    parser.add_argument("--overlay", type=Path, help="PNG the size of the frame drawn over everything in the wide shot, like a logo above the phone; it fades out as the camera zooms in")
    parser.add_argument("--overlay-fade", type=float, default=0.12, help="zoom past 1 at which the overlay is gone")
    parser.add_argument("--camera", default="none", help="none, auto, or a JSON file of moves")
    parser.add_argument("--ring", default="grey", choices=["grey", "white", "none"])
    parser.add_argument("--ring-radius", type=float, default=40, help="in screen points")
    parser.add_argument("--lead", type=float, default=1.3, help="seconds before the first press")
    parser.add_argument("--tail", type=float, default=2.2, help="seconds after the last press")
    parser.add_argument("--deband", nargs="?", const=DEBAND, default="",
                        help="smooth the steps simctl's compression leaves in dark gradients (an ffmpeg filter; the flag alone uses a tested one)")
    parser.add_argument("--saturation", type=float, default=1.0, help="the screen's colors, 1 as the app draws them; 1.1 is a touch richer")
    parser.add_argument("--noise", type=float, default=1.5, help="film grain over the whole clip, so the encoder keeps gradients smooth; 0 for none")
    parser.add_argument("--grain", type=float, default=1.6, help="noise over a background picture, against banding")
    parser.add_argument("--offset", type=float, help="recording time of the run's start; found from the frames when omitted")
    args = parser.parse_args()
    args.bezel = bezel_path(args.bezel)
    return args


def bezel_path(choice):
    """The bezel file for a color name or a path; None draws a plain body."""
    if choice == "plain":
        return None
    if choice.lower() in BEZEL_COLORS:
        path = BEZELS / f"iPhone 18 Pro Max - {choice.capitalize()} - Portrait.png"
        if path.exists():
            return path
        print(f"No {path.name} in {BEZELS}, drawing a plain body (see README, The phone)", file=sys.stderr)
        return None
    return Path(choice)


def main():
    args = parse_args()
    out_w, out_h = (int(v) for v in args.size.lower().split("x"))
    # A lossless take from capture (rec.mov) says itself when its first frame was taken
    # and how many pixels a screen point is; a simctl one (rec.mp4) is timed by its file.
    lossless = args.take / "rec.mov"
    video = lossless if lossless.exists() else args.take / "rec.mp4"
    info = json.loads((args.take / "rec.json").read_text()) if lossless.exists() else {}
    if info.get("scale"):
        args.scale = info["scale"]
    taps, started = load_timeline(args.take / "taps.json")
    screen_size, pts = probe(video)
    first_frame = info.get("first_frame") or first_frame_wall_time(video, pts[-1])
    anchor = started - first_frame if started else None
    # Real touches carry their own clock (the touch's timestamp), and the screen's answer to
    # them comes at varying delays; matching presses to changes would move each ring by that
    # delay. Their clock alone lines them up.
    if args.offset is not None:
        offset = args.offset
    elif info and all(tap.get("target") == "touch" for tap in taps):
        offset = anchor
    else:
        offset = sync_offset(taps, change_onsets(video, pts), anchor)

    start = (taps[0]["time"] if taps else 0) - args.lead
    end = (taps[-1]["time"] if taps else pts[-1] - offset) + args.tail
    frames = int((end - start) * args.fps)
    print(f"screen {screen_size[0]}x{screen_size[1]}, offset {offset:.3f}s" + (f" (clock says {anchor:.3f}s)" if anchor is not None else "") + f", {frames} frames")

    phone = Phone(screen_size, args.bezel, args.corner, args.scale, not args.no_shadow)
    points_w, points_h = screen_size[0] / args.scale, screen_size[1] / args.scale
    warn_off_screen(taps, points_w, points_h)
    center = (points_w / 2, points_h / 2)
    camera = Camera(camera_moves(args.camera, taps, center), center)
    # Output pixels per screen point in the wide shot.
    wide = out_h * args.share / (phone.body_height / args.scale)

    colors = [parse_color(c) for c in args.colors.split(",")]
    bg = background(args.background, colors, (out_w, out_h), args.grain)
    bg_size = bg.width
    overlay = Image.open(args.overlay).convert("RGBA").resize((out_w, out_h), Image.LANCZOS) if args.overlay else None

    decode = subprocess.Popen(
        ["ffmpeg", "-loglevel", "error", "-i", str(video), "-vf",
         f"{args.deband + ',' if args.deband else ''}{f'eq=saturation={args.saturation},' if args.saturation != 1 else ''}tpad=stop_mode=clone:stop_duration=10,fps={args.fps},trim=start={max(0, start + offset):.4f}:duration={frames / args.fps + 1},setpts=PTS-STARTPTS",
         "-fps_mode", "passthrough", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
        stdout=subprocess.PIPE)
    # A silent stereo track goes along: LinkedIn will not take a video without sound.
    encode = subprocess.Popen(
        ["ffmpeg", "-loglevel", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{out_w}x{out_h}",
         "-r", str(args.fps), "-i", "-", "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000",
         "-shortest", *(["-vf", f"noise=alls={args.noise}:allf=t"] if args.noise > 0 else []), "-c:v", "libx264", "-preset", "slow", "-tune", "grain", "-crf", "18",
         "-pix_fmt", "yuv420p",
         "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", str(args.out)],
        stdin=subprocess.PIPE)

    frame_bytes = screen_size[0] * screen_size[1] * 3
    for k in range(frames):
        raw = decode.stdout.read(frame_bytes)
        if len(raw) < frame_bytes:
            break
        t = start + k / args.fps
        zoom, (fx, fy) = camera.at(t)
        scale = wide * zoom / args.scale
        # Layer pixel of the focus point lands in the middle of the frame.
        lx, ly = phone.origin[0] + fx * args.scale, phone.origin[1] + fy * args.scale
        rest_y = 0.5 + (args.phone_y - 0.5) / zoom
        ox, oy = out_w / 2 - lx * scale, out_h * rest_y - ly * scale

        # The background follows the camera at a quarter of its pace.
        bz = 1 + (zoom - 1) * 0.25
        shift_x, shift_y = (fx - center[0]) * wide * 0.25, (fy - center[1]) * wide * 0.25
        half_w, half_h = out_w / 2 / bz, out_h / 2 / bz
        frame = bg.resize((out_w, out_h), Image.BICUBIC,
                          box=(bg_size / 2 + shift_x - half_w, bg_size / 2 + shift_y - half_h,
                               bg_size / 2 + shift_x + half_w, bg_size / 2 + shift_y + half_h)).convert("RGBA")

        screen = Image.frombuffer("RGB", screen_size, raw, "raw", "RGB", 0, 1)
        place(frame, phone.frame(screen), scale, ox, oy)

        if args.ring != "none":
            for tap in taps:
                if tap.get("gesture") == "pinch":
                    closed, share, alpha = pinch_shape(t - tap["time"])
                    points = pinch_fingers(tap["x"], tap["y"], closed)
                elif tap.get("gesture") == "swipe":
                    finger = swipe_finger(tap, t)
                    if not finger:
                        continue
                    point, share, alpha = finger
                    points = [point]
                else:
                    share, alpha = ring_shape(t - tap["time"] + RING_LEAD + tap.get("lead", 0))
                    points = [(tap["x"], tap["y"])]
                if alpha > 0:
                    for px, py in points:
                        x = ox + (phone.origin[0] + px * args.scale) * scale
                        y = oy + (phone.origin[1] + py * args.scale) * scale
                        ring(frame, x, y, args.ring_radius * args.scale * scale * share, alpha, args.ring)

        if overlay is not None:
            shown = min(1.0, max(0.0, 1 - (zoom - 1) / args.overlay_fade))
            if shown > 0:
                layer = overlay if shown == 1 else Image.fromarray(
                    (np.asarray(overlay, np.float32) * [1, 1, 1, ease_in_out(shown)]).astype(np.uint8), "RGBA")
                frame.alpha_composite(layer)

        encode.stdin.write(frame.convert("RGB").tobytes())
        if k % args.fps == 0:
            print(f"{k}/{frames}", flush=True)

    encode.stdin.close()
    encode.wait()
    decode.kill()
    print(args.out)


if __name__ == "__main__":
    main()
