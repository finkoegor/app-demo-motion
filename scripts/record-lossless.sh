#!/bin/zsh
# Records one scripted run of an app without loss, instead of `simctl io recordVideo`,
# whose compression turns soft dark gradients into bands. By default the frames come
# straight from the simulator's framebuffer through simcapture, at the device's own pixel
# size, with no window involved. CAPTURE=window records the Device Hub window through
# capture (ScreenCaptureKit) instead, as sharp as the window is.
#
# Usage: record-lossless.sh <out-dir> <simulator-udid> <bundle-id> [launch arguments...]
#        CAPTURE=window SCREEN="x y width height" record-lossless.sh ...
#
# For CAPTURE=window, before the first take, by hand: open Device Hub on the booted
# simulator, hide the sidebar, zoom the device as large as the window allows, then find
# SCREEN, the screen's rectangle in the window in points:
#   swiftc -O capture.swift -o capture
#   ./capture --snapshot window.png "<device name>"
#   xcrun simctl io <udid> screenshot screenshot.png
#   python3 find_screen.py window.png screenshot.png
# The window must stay on screen and untouched while it records. Leaves rec.mov, rec.json
# and taps.json in <out-dir>; build the clip with compose10.py (still camera, 10 bits) or
# compose.py.
#
# Environment, as in record.sh: APPEARANCE, TIME (the simulator should already run in the
# en_US region for 9:41 without a zero, see record.sh), CLIPBOARD, STATE_DIR, MAX_SECONDS.
# WINDOW is the window's title (default: the device's name); POINTS the screen's width in
# points (default 402).
set -e
OUT=${1:?out dir}
SIM=${2:?simulator udid}
APP=${3:?bundle id}
shift 3
HERE=${0:A:h}
CAPTURE=${CAPTURE:-framebuffer}
[[ $CAPTURE == window ]] && : ${SCREEN:?set SCREEN to the screen rectangle from find_screen.py}
WINDOW=${WINDOW:-$(xcrun simctl list devices | grep "$SIM" | sed -E 's/^ *(.*) \([0-9A-F-]{36}\).*/\1/')}
POINTS=${POINTS:-402}
if [[ $CAPTURE == window ]]; then
  [[ -x $HERE/capture ]] || swiftc -O $HERE/capture.swift -o $HERE/capture
else
  [[ -x $HERE/simcapture ]] || swiftc -O $HERE/simcapture.swift -o $HERE/simcapture
fi
mkdir -p $OUT

xcrun simctl terminate $SIM $APP 2>/dev/null || true
DATA=$(xcrun simctl get_app_container $SIM $APP data)
rm -f "$DATA/tmp/demo-taps.json"
if [[ -n "$STATE_DIR" ]]; then
  rm -rf "$DATA/Library/Application Support"
  mkdir -p "$DATA/Library/Application Support"
  cp -R "$STATE_DIR" "$DATA/Library/Application Support/$(basename "$STATE_DIR")"
fi
[[ -n "$APPEARANCE" ]] && xcrun simctl ui $SIM appearance $APPEARANCE
if [[ -n "$TIME" ]]; then
  xcrun simctl status_bar $SIM override --time $TIME --batteryState discharging --batteryLevel 100 \
    --cellularMode active --cellularBars 4 --wifiMode active --wifiBars 3 --dataNetwork wifi
  trap 'xcrun simctl status_bar $SIM clear' EXIT
fi
[[ -n "$CLIPBOARD" ]] && printf "%s" "$CLIPBOARD" | xcrun simctl pbcopy $SIM
rm -f $OUT/rec.mov $OUT/rec.json $OUT/taps.json
if [[ $CAPTURE == window ]]; then
  osascript -e 'tell application id "com.apple.dt.Devices" to activate' 2>/dev/null || true
  sleep 1.5
  $HERE/capture $OUT/rec.mov "$WINDOW" ${=SCREEN} $POINTS &
else
  $HERE/simcapture $OUT/rec.mov $SIM $POINTS &
fi
CAP=$!
sleep 1.5
xcrun simctl launch $SIM $APP "$@" >/dev/null
for i in $(seq 1 $(( ${MAX_SECONDS:-60} * 10 ))); do
  [[ -f "$DATA/tmp/demo-taps.json" ]] && break
  sleep 0.1
done
sleep 0.8
kill -INT $CAP
wait $CAP 2>/dev/null || true
if [[ -f "$DATA/tmp/demo-taps.json" ]]; then
  cp "$DATA/tmp/demo-taps.json" $OUT/taps.json
else
  echo "No timeline from the app; write $OUT/taps.json by hand" >&2
fi
echo "$OUT/rec.mov"
