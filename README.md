# Let It Snow

A native macOS desktop snow app powered by **Swift + Metal + Apple Vision**, featuring real aerodynamic physics, granular snow accumulation on desktop icons, folders, the Dock, open windows, and wallpaper people/objects, plus an optional Snowcraft snowball fight mini-game.

## Features

- **Real Snow Physics & Accumulation:** Gravity, air drag, curl turbulence, crystal flutter, angle-of-repose heightfields, edge spillover clumps, melting, and cursor snow brushing.
- **Mac-Aware Surfaces:** Accumulates on **Desktop Icons**, **Desktop Folders** (with tab profiles), the **Dock & Dock Icons**, **Open Windows** (snow cascades off when windows are minimized/closed), and **Screen Bottom**.
- **Wallpaper Depth Map:** Uses `ScreenCaptureKit` + Apple `Vision` (`VNGenerateForegroundInstanceMaskRequest` + `VNGeneratePersonSegmentationRequest`) and scene ridge detection so flakes land on people, shoulders, heads, and objects in your wallpaper.
- **Customizable Settings & Presets:**
  - Curved low-end snow intensity slider (`5–3,500` flakes)
  - Custom preset saving & Menu Bar quick switching
  - **Mac Efficiency Mode** (**Eco**, **Balanced**, **Ultra**) with automatic idle/sleep/lock pausing
  - **Variable Weather Patterns**, **Pomodoro Blizzard Timer**, and **Snowstorm Alarm**
- **Optional Snowcraft Mini-Game:** Click & drag to roll snowballs, click & hold anywhere to pack & charge a throw against Red Snowcraft dudes (opt-in from Settings or Menu Bar).

## Download

Grab the latest Universal build (`arm64` + `x86_64`, macOS 14.0+) from the [Releases](../../releases) page.

> **First Launch Note:** Because the app is ad-hoc signed, if macOS shows *"Apple could not verify LetItSnow"*, click **Done**, open **System Settings → Privacy & Security**, and click **Open Anyway** next to **LetItSnow**.

## Build from Source

Requires macOS 14.0+ and Xcode / Swift 6 toolchain:

```bash
# Run unit tests
swift test

# Build Universal .app bundle into build/LetItSnow.app
./build.sh

# Package Universal .dmg and .zip into dist/
./package.sh
```
