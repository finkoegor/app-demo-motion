#!/bin/zsh
# Records a run that a UI test plays with real touches (templates/ui-test/PromoRun.swift),
# without loss: the device's screen from its Device Hub window through capture, while
# xcodebuild runs the one test. The app, launched by the test with `-DemoTouches`, writes
# where each finger landed. Leaves rec.mov, rec.json and taps.json in <out-dir>.
#
# Usage: PROJECT=<project folder> SCHEME=<scheme> TEST=<Target/Class/testMethod> \
#   record-uitest.sh <out-dir> <simulator-udid> <bundle-id>
#
# Before a take: the simulator booted (in the en_US region for 9:41 without a zero, see
# record.sh), `xcodebuild build-for-testing` into DERIVED, Device Hub showing the device
# with the sidebar hidden and the device zoomed as large as the window allows. The screen
# is found in the window at the start of every take: Device Hub can draw the device at
# another size after a reboot. The window must stay on screen and untouched while it
# records; ask the person for the screen if they are working.
#
# Environment: APPEARANCE (dark or light), TIME (9:41), DERIVED (the derived data folder,
# default <out-dir>/../dd), WINDOW (the window's title, default the device's name), POINTS
# (the screen's width in points, default 402), FLAG (the variable the test checks, default
# PROMO; passed to the test as TEST_RUNNER_<FLAG>=1).
set -e
OUT=${1:?out dir}
SIM=${2:?simulator udid}
APP=${3:?bundle id}
: ${PROJECT:?set PROJECT} ${SCHEME:?set SCHEME} ${TEST:?set TEST}
HERE=${0:A:h}
DERIVED=${DERIVED:-${OUT:h}/dd}
WINDOW=${WINDOW:-$(xcrun simctl list devices | grep "$SIM" | sed -E 's/^ *(.*) \([0-9A-F-]{36}\).*/\1/')}
POINTS=${POINTS:-402}
FLAG=${FLAG:-PROMO}
[[ -x $HERE/capture ]] || swiftc -O $HERE/capture.swift -o $HERE/capture
mkdir -p $OUT
rm -f $OUT/rec.mov $OUT/rec.json $OUT/taps.json

[[ -n "$APPEARANCE" ]] && xcrun simctl ui $SIM appearance $APPEARANCE
if [[ -n "$TIME" ]]; then
  xcrun simctl status_bar $SIM override --time $TIME --batteryState discharging --batteryLevel 100 \
    --cellularMode active --cellularBars 4 --wifiMode active --wifiBars 3 --dataNetwork wifi
  trap 'xcrun simctl status_bar $SIM clear' EXIT
fi
DATA=$(xcrun simctl get_app_container $SIM $APP data 2>/dev/null || true)
[[ -n "$DATA" ]] && rm -f "$DATA/tmp/demo-taps.json"

# Device Hub may sit in its own full-screen space; bringing it forward switches to it.
osascript -e 'tell application id "com.apple.dt.Devices" to activate'
sleep 3
$HERE/capture --snapshot $OUT/window.png "$WINDOW" >/dev/null
xcrun simctl io $SIM screenshot $OUT/screen.png >/dev/null 2>&1
SCREEN=($(python3 $HERE/find_screen.py $OUT/window.png $OUT/screen.png))
rm -f $OUT/window.png $OUT/screen.png
echo "screen at $SCREEN"

$HERE/capture $OUT/rec.mov "$WINDOW" $SCREEN $POINTS &
CAP=$!
sleep 3
# One device, no clones: with parallel testing on, xcodebuild runs the test on a copy of
# the simulator that the window doesn't show.
(cd $PROJECT && env TEST_RUNNER_$FLAG=1 xcodebuild test-without-building -scheme $SCHEME -destination "id=$SIM" \
  -derivedDataPath $DERIVED -parallel-testing-enabled NO -collect-test-diagnostics never \
  -only-testing:$TEST 2>&1 | grep -E "Test Case.*(passed|failed)|error:") || true
sleep 1
kill -INT $CAP
wait $CAP 2>/dev/null || true
DATA=$(xcrun simctl get_app_container $SIM $APP data)
cp "$DATA/tmp/demo-taps.json" $OUT/taps.json
echo "$OUT"
