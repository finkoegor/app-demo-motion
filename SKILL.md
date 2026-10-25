---
name: telegram-style-motion
description: Makes Telegram-style promo clips of an iOS app. The app plays a scripted flow on the iOS Simulator, the recording goes into a phone bezel on a gradient or any background, a camera moves in on the action and a ring pulses at every tap. Use when asked for an app promo video, a feature screencast with tap highlights, a motion clip of a flow, a "video like Telegram makes", or a clip for Threads, Reels, Product Hunt or the App Store page.
---

# Telegram Style Motion

The look: a real phone body on a soft colorful background, the app running inside at
full frame rate, the camera leaning in on what matters, a ring pulsing where the finger
lands. The clip is cut from one unbroken take, so every animation is the app's own.

Everything runs on a Mac with Xcode, ffmpeg and Python 3 (Pillow, numpy). The scripts
live next to this file in `scripts/`; copy them into the project or run them from here.

## How it works

1. The app presses its own buttons. A debug build launched with `-Demo` runs a scripted
   scenario through the same actions a finger triggers, with exact pauses, and writes a
   timeline of presses (time, point on screen) to its temporary folder.
2. `scripts/record.sh` prepares the simulator (appearance, status bar, clipboard, saved
   app state), records the screen with `simctl io recordVideo` and stops when the
   timeline appears.
3. `scripts/compose.py` builds the clip: finds the exact offset between the timeline and
   the recording by watching when the screen starts changing after each press, draws the
   phone, background, camera and rings, and encodes 60 fps H.264.

## Step 0: the scenario, with the person

Every app and every clip has its own flow; nothing here assumes one. Before touching
code, settle the scenario together:

- What the clip proves: one feature, one message, 8 to 15 seconds. A clip that shows
  two features is two clips.
- The path: the screen it starts on, every press in order, the screen it ends on. Write
  it as a numbered list of presses and waits. If it should loop, it ends where it began.
- What the viewer must read at each step, and what is only a transition. That decides
  the pauses (a result is held 1.5 to 2.5 s, a transition is not held) and the camera
  (lean in on what is read, go wide for full-screen effects).
- Inputs: links, text, photos, accounts. Each one is seeded, not typed live: a link goes
  through the clipboard or a launch argument, a photo sits in the simulator's library,
  typed text is driven through the model in chunks so the keyboard shows and the text
  appears at a human pace.
- Preconditions: what the app must already contain so the screens look full (a few
  items, a profile name, dark or light appearance). Save that state once and restore it
  before every take.
- Format and style: square, 4:5 or 9:16; the phone (Apple bezel, own PNG, Simulator
  chrome, drawn); the background (brand gradient colors, a color, an image); ring style.

Then turn the list into code: read the app to find each pressed control and the action
it runs, mark it with `.demoTarget`, gate it on the state that means "ready" (loaded,
cut out, saved) instead of guessing delays, and write `run()` as the list reads. Keep
the person's wording for the camera plan: "lean in on the photo while it is processed,
out before the confirmation" becomes two moves in `camera.json`.

## Step 1: the scenario inside the app

Prefer this over tapping the simulator from outside: external taps drift, drop
characters and start before the simulator is ready; the app itself is exact.

For SwiftUI, copy `templates/swiftui-autopilot/*.swift` into the app target (they are
wrapped in `#if DEBUG`, nothing ships), then:

- List the controls the flow presses in `DemoTarget`.
- Mark each control: `.demoTarget(.save, isEnabled: model.isReady, action: save)` next to
  the button, passing the same action the button runs. The `isEnabled` condition makes
  the autopilot wait for loading, cut-outs, network and the like, so there is no guessing
  of delays.
- Write the flow in `DemoAutopilot.run()`: `press` waits for the control, `after:` holds
  a beat first, `pause` is time for the viewer. Start with 2 to 3 seconds of rest and end
  with 2 seconds on the final screen. A flow that opens a sheet, pastes a link, waits for
  the page and saves reads as: `press(.add)`, `pause(1.2)`, `press(.paste)`,
  `press(.save, after: 2.0)` with `.save` enabled only once the page is loaded,
  `pause(2.4)`, `press(.done)`, `pause(2.0)`.
- A slider is pressed where its value would be: `anchor: UnitPoint(x: 0.96, y: 0.5)` puts
  the ring at the top end, and the action can walk the value up step by step so the
  number counts as under a finger.
- One item of a list (a tag, a row) is picked with an optional target:
  `.demoTarget(tag == "Outside" ? .location : nil) { toggle(tag) }`.
- A button whose meaning changes in place (Continue, then Save) passes the target for
  the current step: `.demoTarget(step == 1 ? .next : .complete, action: footerAction)`.
- Controls the system draws (tab bar items) have no SwiftUI frame. Mark any view that
  is always there with a locator and the same action the tap does:
  `.demoTarget(.analyze, locate: { DemoLocator.frameOfTab(at: 1) }) { selectedTab = .analyze }`.
  Tab buttons carry no accessibility labels on iOS 27 and are drawn twice (plain and
  selected), so `DemoLocator` finds them by position. A back button or a bar button:
  `DemoLocator.frameOfLeadingBarButton()`, the leftmost one a tap would reach.
- A SwiftUI `Menu` has no action to call. `DemoLocator.presentMenuOfTrailingBarButton()`
  opens a toolbar menu with its real animation; a row is found with
  `frameOfMenuItem(titled:)` and pressed by `dismissMenu()` plus the row's own action:
  `.demoTarget(.listView, locate: { DemoLocator.frameOfMenuItem(titled: "List view") }) { DemoLocator.dismissMenu(); layout = .list }`.
- Seed the data the clip shows: every day of the weeks or months the viewer will see,
  with varied values, so charts and lists are never empty or flat.
- Start it from the root view: `.task { await DemoAutopilot.shared?.run() }`. If the app
  has a launch screen or loader, the first pause has to outlast it, or the clip opens on
  the loader.
- Values the flow needs (a link to paste, a name to type) come through launch arguments
  such as `-DemoLink https://...` and `DemoAutopilot.argument("Link")`.

Typed text: trigger the same model change the keyboard would make, or type it through
the field's binding in chunks with short pauses, so the keyboard shows and the text
appears as a person would see it.

For UIKit or another framework do the same with whatever the app offers: a flag, a
timer, the controls' own actions, and a JSON timeline of `{"target","time","x","y"}`
written to `NSTemporaryDirectory()/demo-taps.json` in screen points from the run's start.
A press can carry `"gesture": "pinch"`: `compose.py` then draws two fingers landing apart
around the point and closing in through the press time, the app answering halfway. For a
pinch the autopilot runs what the gesture does at a stop (a grid gaining a column, say)
and reports the middle of the pinched view.

Without changing the app (not recommended): drive the flow with `xcrun simctl` or the
simulator tool, write `taps.json` by hand with times measured from the start of the
recording, and pass `--offset 0` to `compose.py`.

## Step 2: the take

```
STATE_DIR=~/takes/state/MyApp APPEARANCE=dark TIME=9:41 CLIPBOARD="https://example.com/product" \
  scripts/record.sh ~/takes/take1 <simulator udid> com.example.app -Demo -DemoLink https://example.com/product
```

- Install a Debug build on the simulator first (`xcodebuild ... build` then
  `xcrun simctl install <udid> <app>`), on a simulator of the device whose bezel will be
  used. Current iPhones record at 3 px per point.
- `STATE_DIR` restores a saved copy of the app's Application Support folder so every
  take starts from the same content. Make it once by hand: fill the app, then copy the
  folder out of `xcrun simctl get_app_container <udid> <bundle> data`.
- Right after a simulator boots, the first launch is slow and taps land late; let the
  app start once and wait 10 seconds before the real take.
- A paste button needs the text on the simulator's clipboard (`CLIPBOARD`). After a paste
  iOS may show a "pasted from" banner; cover it in the edit or paste through the model.
- Do a dry run without recording: check that the flow completes and the timeline shows up.
- Something from outside the app (a message with a link, a push): a Messages banner
  drops over the app with `xcrun simctl push <udid> com.apple.MobileSMS message.json`
  (`{"Simulator Target Bundle": "com.apple.MobileSMS", "aps": {"alert": {"title": "Name",
  "body": "text"}}}`), and `xcrun simctl openurl <udid> <link>` opens the link where a
  tap on the banner would; the banner leaves as the link opens. Launch the app with the
  autopilot first, let `press` wait for what the link opens, and add the banner tap to
  `taps.json` by hand, timed from the timeline's `started`, a quarter second before the
  link opens.

## Step 3: the clip

```
python3 scripts/compose.py ~/takes/take1 ~/takes/promo.mp4 \
  --bezel bezel.png --camera camera.json --colors "#c9b8ff,#ffc9a8,#9fd8ff,#ffb3d1"
```

Options that matter:

- `--size`: 1920x1920 by default; 1080x1350 for a feed, 1080x1920 for Reels and Stories.
  The phone takes `--share` of the frame height (0.86).
- `--bezel`: a PNG of a phone with a transparent screen. The hole is found automatically
  and scaled to the recording, so any device works if the recording matches it. Best
  source: Apple's Product Bezels from developer.apple.com/design/resources, which have
  real materials and buttons. Without `--bezel` a plain dark body is drawn. With Xcode
  installed, `swift scripts/chrome.swift "iPhone 17 Pro" bezel.png` renders the
  Simulator's own chrome, flat but exact.
- `--background`: `gradient` (default) with `--colors` as a comma list of hex values,
  the brand palette goes here; a solid `#hex`; or an image file, cropped to cover.
- `--camera`: `none`, `auto` (leans in at every press and back out) or a JSON file of
  moves: `at` as seconds or `tap<N>±seconds`, `zoom`, `focus` in screen points,
  `duration`. Move in on details (a form, a picture being processed), move out before
  a big effect that needs the whole screen, and end wide. See `examples/camera.json`.
- `--ring`: `grey` (grey with a white rim and shadow, readable over white buttons),
  `white` (the Telegram look) or `none`; `--ring-radius` in points (40).
- `--lead` and `--tail`: rest before the first press and after the last one.
- `--offset`: overrides the automatic sync when the first screen change is not caused
  by the press (a spinner was running) or the timeline is hand made.

Rendering is a few seconds of clip per minute of work at 1920 square; check the first
result, then adjust camera and pacing.

## Check the result before handing it over

Pull frames and look: `ffmpeg -i promo.mp4 -vf "fps=2,scale=240:-1,tile=6x4" -frames:v 1 sheet.png`.
Look for: the ring lands exactly before the screen reacts; the phone's corners are hidden
by the bezel; the first and last frames rest on calm screens; the camera never cuts off
what the viewer should read. For a seamless loop, script the flow to return to the
starting screen and trim the tail to match.

## Things that bite

- The simulator recording is variable frame rate. Pull frames with
  `-fps_mode passthrough` or by time (`fps=60` filter); plain rawvideo output silently
  drops to 25 fps.
- `simctl io recordVideo` is stopped with SIGINT, not killed; otherwise the file is empty.
- Status bar overrides persist on the simulator; clear them after the take.
- A sheet opening or a keyboard rising starts about 0.2 s after the press; the sync
  looks for the first change, so pure UI delays are fine, network delays are not. Keep
  loading out of the frame or gate presses on `isEnabled`.
- The autopilot reads control frames in global coordinates; on iPad or in a window the
  points differ from the screen, record on an iPhone simulator.
