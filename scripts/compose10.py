#!/usr/bin/env python3
"""Builds a still-camera clip from a lossless take (record-lossless.sh) in 10 bits, so
the app's dark gradients stay smooth.

Usage: compose10.py <take-dir> <out-base> [compose.py options]

Takes the same options as compose.py except the camera, which stays wide.

compose.py draws every frame in 8 bits, which brings the bands back. With the camera
standing still only the screen and the rings move, so this script uses compose.py once
for the still layers (background with the phone's shadow, the bezel, the screen's mask)
and for the rings, and lets ffmpeg stack them over the recording in 10 bits. Writes
<out-base>-10bit.mp4 (HEVC Main 10, smooth wherever 10 bits play) and <out-base>.mp4
(H.264, dithered down from the 10-bit picture by error diffusion).
"""
import json
import subprocess
import sys
from pathlib import Path

from PIL import Image

sys.argv, extra = sys.argv[:3], sys.argv[3:]
take, out_base = Path(sys.argv[1]), Path(sys.argv[2])
sys.argv += extra

import compose  # noqa: E402

args = compose.parse_args()
out_w, out_h = (int(v) for v in args.size.lower().split("x"))
video = take / "rec.mov"
info = json.loads((take / "rec.json").read_text())
args.scale = info["scale"]
taps, started = compose.load_timeline(take / "taps.json")
screen_size, pts = compose.probe(video)
anchor = started - info["first_frame"]
# Real touches carry their own clock; the screen answers them at varying delays.
if args.offset is not None:
    offset = args.offset
elif all(tap.get("target") == "touch" for tap in taps):
    offset = anchor
else:
    offset = compose.sync_offset(taps, compose.change_onsets(video, pts), anchor)
compose.warn_off_screen(taps, screen_size[0] / args.scale, screen_size[1] / args.scale)
start = taps[0]["time"] - args.lead
end = taps[-1]["time"] + args.tail
frames = int((end - start) * args.fps)
print(f"screen {screen_size[0]}x{screen_size[1]}, offset {offset:.3f}s (clock says {anchor:.3f}s), {frames} frames")

work = out_base.parent / (out_base.name + "-layers")
work.mkdir(parents=True, exist_ok=True)

phone = compose.Phone(screen_size, args.bezel, args.corner, args.scale, not args.no_shadow)
center = (screen_size[0] / args.scale / 2, screen_size[1] / args.scale / 2)
wide = out_h * args.share / (phone.body_height / args.scale)
s = wide / args.scale
lx, ly = phone.origin[0] + center[0] * args.scale, phone.origin[1] + center[1] * args.scale
ox, oy = out_w / 2 - lx * s, out_h / 2 - ly * s

colors = [compose.parse_color(c) for c in args.colors.split(",")]
bg = compose.background(args.background, colors, (out_w, out_h), args.grain)
half_w, half_h = out_w / 2, out_h / 2
under = bg.resize((out_w, out_h), Image.BICUBIC,
                  box=(bg.width / 2 - half_w, bg.height / 2 - half_h, bg.width / 2 + half_w, bg.height / 2 + half_h)).convert("RGBA")
compose.place(under, phone.base, s, ox, oy)
under.convert("RGB").save(work / "under.png")
cover = Image.new("RGBA", (out_w, out_h), (0, 0, 0, 0))
compose.place(cover, phone.cover, s, ox, oy)
cover.save(work / "cover.png")

# The screen lands on whole pixels; half a pixel of shift hides under the bezel.
sx, sy = round(ox + phone.origin[0] * s), round(oy + phone.origin[1] * s)
sw, sh = round(screen_size[0] * s) & ~1, round(screen_size[1] * s) & ~1
phone.mask.resize((sw, sh), Image.LANCZOS).save(work / "mask.png")

# Rings alone on a clear layer, a frame each.
rings = subprocess.Popen(
    ["ffmpeg", "-loglevel", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgba", "-s", f"{out_w}x{out_h}",
     "-r", str(args.fps), "-i", "-", "-c:v", "qtrle", str(work / "rings.mov")],
    stdin=subprocess.PIPE)
for k in range(frames):
    t = start + k / args.fps
    layer = Image.new("RGBA", (out_w, out_h), (0, 0, 0, 0))
    for tap in taps:
        if tap.get("gesture") == "swipe":
            finger = compose.swipe_finger(tap, t)
            if not finger:
                continue
            point, share, alpha = finger
        else:
            share, alpha = compose.ring_shape(t - tap["time"] + compose.RING_LEAD + tap.get("lead", 0))
            point = (tap["x"], tap["y"])
        if alpha > 0:
            x = ox + (phone.origin[0] + point[0] * args.scale) * s
            y = oy + (phone.origin[1] + point[1] * args.scale) * s
            compose.ring(layer, x, y, args.ring_radius * args.scale * s * share, alpha, args.ring)
    rings.stdin.write(layer.tobytes())
rings.stdin.close()
rings.wait()

duration = frames / args.fps
rgb_to_yuv = "scale=out_color_matrix=bt709:out_range=tv"
graph = ";".join([
    f"[1:v]{f'eq=saturation={args.saturation},' if args.saturation != 1 else ''}tpad=stop_mode=clone:stop_duration=10,fps={args.fps},trim=start={max(0, start + offset):.4f}:duration={duration + 1},"
    f"setpts=PTS-STARTPTS,scale={sw}:{sh}:flags=lanczos,format=yuva444p10le[screen]",
    "[2:v]format=gray10le[mask]",
    "[screen][mask]alphamerge[shaped]",
    f"[0:v]{rgb_to_yuv},format=yuv444p10le[under]",
    f"[under][shaped]overlay={sx}:{sy}:format=yuv444p10[a]",
    f"[3:v]{rgb_to_yuv},format=yuva444p10le[cover]",
    "[a][cover]overlay=0:0:format=yuv444p10[b]",
    f"[4:v]{rgb_to_yuv},format=yuva444p10le[rings]",
    "[b][rings]overlay=0:0:format=yuv444p10:eof_action=pass,split[ten][eight]",
    "[eight]scale=sws_dither=ed,format=yuv420p[eight8]",
])
tags = ["-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709"]
audio = ["-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000"]
subprocess.run(
    ["ffmpeg", "-loglevel", "error", "-y",
     "-loop", "1", "-framerate", str(args.fps), "-i", str(work / "under.png"),
     "-i", str(video),
     "-loop", "1", "-framerate", str(args.fps), "-i", str(work / "mask.png"),
     "-loop", "1", "-framerate", str(args.fps), "-i", str(work / "cover.png"),
     "-i", str(work / "rings.mov"),
     *audio,
     "-filter_complex", graph,
     "-map", "[ten]", "-map", "5:a", "-t", f"{duration:.3f}", "-r", str(args.fps),
     "-c:v", "libx265", "-preset", "slow", "-crf", "14", "-x265-params", "log-level=error", "-pix_fmt", "yuv420p10le", "-tag:v", "hvc1", *tags,
     "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", f"{out_base}-10bit.mp4",
     "-map", "[eight8]", "-map", "5:a", "-t", f"{duration:.3f}", "-r", str(args.fps),
     "-c:v", "libx264", "-preset", "slow", "-tune", "grain", "-crf", "14", "-pix_fmt", "yuv420p", *tags,
     "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", f"{out_base}.mp4"],
    check=True)
print(f"{out_base}.mp4 and {out_base}-10bit.mp4")
