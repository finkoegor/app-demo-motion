# Telegram Style Motion

Promo clips of an iOS app in the style Telegram uses for its feature announcements:
a real phone on a soft gradient or your own picture, the app running inside, the camera
leaning in on the action or holding still, a ring pulsing under every tap and following
every swipe.

The clip is one unbroken take. The app presses its own buttons on a timer, the
Simulator records the screen (or ScreenCaptureKit records it without loss), a script
puts the recording into a phone bezel, adds the background, the camera moves and the
rings, and encodes 60 fps H.264, or HEVC in 10 bits.

This repository is a skill for Claude Code. It also works by hand: the scripts are
plain zsh, Python and Swift.

## Install

```
git clone https://github.com/finkoegor/telegram-style-motion ~/.claude/skills/telegram-style-motion
```

Or for one project only, into its `.claude/skills/telegram-style-motion`. Start a new
Claude Code session in the app's folder and ask in your own words, for example "make a
promo clip: add an item from a link, show the result, dark theme, brand gradient", or
call it directly with `/telegram-style-motion`. Claude can also install it for you if
you paste the repository link and ask it to.

## What you need

- macOS with Xcode and the iOS Simulator
- ffmpeg (`brew install ffmpeg`)
- Python 3 with Pillow and numpy (`pip3 install pillow numpy`)
- a Debug build of your app on a simulator

## Quick start

1. Teach the app the flow. For SwiftUI, copy `templates/swiftui-autopilot/` into the app
   target, name the controls in `DemoTarget`, mark them with `.demoTarget(.name) { action }`
   and write the flow in `DemoAutopilot.run()`. Launched with `-Demo`, the app runs the
   flow and writes the timeline of presses. Nothing of this ships: it is all `#if DEBUG`.

2. Record a take:

   ```
   APPEARANCE=dark TIME=9:41 scripts/record.sh ~/takes/take1 <simulator udid> com.example.app -Demo
   ```

3. Build the clip:

   ```
   python3 scripts/compose.py ~/takes/take1 ~/takes/promo.mp4 --bezel bezel.png --camera auto
   ```

That is a square 1920 clip with the default gradient. Read on for the knobs.

`TIME=9:41` reboots the simulator in the en_US region for the take, so the bar reads
9:41 and not 09:41, and puts the region back after.

## Smooth gradients: the lossless take

`simctl io recordVideo` compresses hard, and soft dark gradients (glows, fades) come out
in bands that no setting fixes afterwards. If the app has them, record the simulator's
window instead:

1. Open the booted simulator in Device Hub (Xcode 27) or Simulator, hide the sidebar,
   zoom the device in as far as the window allows.
2. Find the screen in the window:

   ```
   swiftc -O scripts/capture.swift -o scripts/capture
   scripts/capture --snapshot window.png "iPhone 17 Pro"
   xcrun simctl io <udid> screenshot screenshot.png
   python3 scripts/find_screen.py window.png screenshot.png
   ```

   macOS asks once for Screen Recording permission.
3. Record, leaving the window alone while it runs:

   ```
   SCREEN="655.5 93 418 907" APPEARANCE=dark TIME=9:41 scripts/record-lossless.sh ~/takes/take1 <udid> com.example.app -Demo
   ```

4. Build it in 10 bits with a steady camera:

   ```
   python3 scripts/compose10.py ~/takes/take1 ~/takes/promo --size 1440x2160 --bezel bezel.png --background art.jpg
   ```

   `promo.mp4` is H.264 dithered from 10 bits and plays everywhere; `promo-10bit.mp4` is
   HEVC Main 10, smooth wherever 10 bits play. `compose.py` reads lossless takes too, for
   clips with camera moves.

## Your own flow

The scripts know nothing about your app; the flow is yours. Decide it first: one feature,
8 to 15 seconds, a numbered list of presses from the opening screen to the final one,
with what the viewer should read at each step. Then:

- name each pressed control in `DemoTarget` and mark it in the view with
  `.demoTarget(.name, isEnabled: ready, action: theSameAction)`; `isEnabled` makes the
  autopilot wait for loading instead of guessing delays;
- write the presses and pauses in `DemoAutopilot.run()` in the same order;
- seed inputs instead of typing them live: a link via the clipboard or a launch argument
  (`-DemoLink https://...`, read with `DemoAutopilot.argument("Link")`), photos in the
  simulator's library, typed text through the model in chunks;
- save the app state the clip should start from and restore it before every take
  (`STATE_DIR`);
- plan the camera from the same list: lean in where there is something to read, go wide
  before full-screen effects, end wide.

With Claude Code, describe the flow in words ("add an item from a link, show the cutout,
end on the board") and let the skill wire the targets and write the scenario.

## The phone

Pass `--bezel` with a PNG of a phone whose screen is transparent. The hole is found
automatically and scaled to the recording, so it only has to be the same device the
recording was made on (same aspect ratio).

- Best: Apple's Product Bezels (developer.apple.com/design/resources). Real materials,
  buttons and highlights. Pick the device and color you like and pass the portrait PNG.
- Any other mockup PNG with a transparent screen works the same way, attach it as a file.
- With Xcode installed, `swift scripts/chrome.swift "iPhone 17 Pro" bezel.png` renders
  the Simulator's own chrome: exact, but flat.
- Without `--bezel` a plain dark body is drawn.

The screen's own corners stay square in the recording; the bezel's hole shape hides them.
The Dynamic Island is in the recording already.

## The background

- `--background gradient` with `--colors "#c9b8ff,#ffc9a8,#9fd8ff,#ffb3d1"`: a soft mesh
  of up to eight colors. Put the brand palette here.
- `--background "#111112"`: a solid color.
- `--background art.jpg`: your own picture, any image, cropped to cover the frame, with a
  little grain (`--grain`) so its soft areas don't band.

The background follows the camera at a quarter of its pace, which gives the parallax.

## The camera

Zoom or no zoom is a matter of taste; both work.

- `--camera none`: a steady wide shot. With a lossless take it can be built in 10 bits.
- `--camera auto`: leans in at every press and back out after.
- `--camera moves.json`: your own moves. Each move has `at` (seconds, or `tap2-0.4` for
  0.4 s before the second press), `zoom`, `focus` in screen points and `duration`:

  ```json
  [
    { "at": "tap2-0.45", "duration": 1.0, "zoom": 1.55, "focus": [201, 380] },
    { "at": "tap3-0.95", "duration": 0.8, "zoom": 1.0 }
  ]
  ```

  Lean in on details (a form, a picture being processed), go wide before an effect that
  needs the whole screen, end wide.

## The rings

`--ring grey` (default) is a grey ring with a white rim and a soft shadow; it stays
visible over white buttons. `--ring white` is the plain white ring from Telegram's clips.
`--ring none` turns them off. `--ring-radius` is in screen points.

A swipe in the timeline (`"gesture": "swipe"` with an end point and a duration) is drawn
as a finger travelling with the control; the autopilot template has `swipe(...)` for
sliders, wheels and carousels, and `DemoSwipe` for the control's side.

## Formats

`--size 1920x1920` for a square post, `1080x1350` for a 4:5 feed, `1440x2160` for 2:3,
`1080x1920` for Reels and Stories. `--share` is how much of the frame height the phone takes (0.86).
For a logo above the phone, lower it with `--phone-y 0.565` and pass a transparent PNG the size
of the frame with `--overlay logo.png`: it shows in the wide shot and fades out as the camera zooms in.
`--lead` and `--tail` set the rest before the first press and after the last one.

## Sync

The timeline counts from the app's start, the recording from the recorder's. The script
lines them up itself: after a press the screen changes, so it finds the offset that puts
every press a frame before a change. If the flow has a spinner running before the first
press, or the timeline was written by hand, pass `--offset` in seconds yourself.

## Without touching the app

Drive the flow with `xcrun simctl` or any simulator automation, write `taps.json` by hand
with times measured from the start of the recording, and pass `--offset 0`. The autopilot
is better: external taps drift, and the first taps after a boot land late.

## Tips

- Start every take from the same app state: `STATE_DIR` restores a saved copy of the
  app's Application Support folder.
- Let the app launch once after the simulator boots and wait 10 seconds before the take.
- A paste button needs text on the simulator clipboard: `CLIPBOARD="..."`.
- For a seamless loop, end the flow on the screen it started from and trim the tail.
- Check the clip frame by frame before posting:
  `ffmpeg -i promo.mp4 -vf "fps=2,scale=240:-1,tile=6x4" -frames:v 1 sheet.png`
- A press off the screen in `taps.json` (compose warns about it) is a stale point,
  usually a control in a row that scrolled after it was measured; fix it by hand.

## License

MIT.
