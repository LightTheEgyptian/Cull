# Cull

**A fast, private photo culling app for Mac.** Drop in a folder from a shoot and keep or reject each photo with one key, while your Mac checks focus and eyes for you.

Made by **Nur Elmasri**. Free and open source under the [MIT License](LICENSE): anyone can use it, change it and share it.

## What it does

- **Keep, reject, rate.** P keeps, X rejects, 1–5 gives stars. Cull jumps to the next photo so you can move quickly.
- **Spots problems for you.** Every photo is checked on your Mac with Apple's Vision framework:
  - **Out of focus**: judged on faces, or on the sharpest part of the frame, and compared with the rest of the shoot, so a shallow depth of field isn't counted as blur.
  - **Eyes may be closed**
  - **Strong shot**: Apple's aesthetic score picks out your best frames.
- **Handles bursts.** Shots taken within 2 seconds are grouped. Cull marks the best in each burst, **B** keeps it and rejects the rest, and **C** compares them side by side.
- **Check details fast.** **F** zooms to faces, **Z** zooms to 100%, **I** shows camera settings.
- **Works with Lightroom.** RAW + JPEG pairs stay together, and ratings are written to XMP sidecars.
- **Export for clients.** JPEGs at full size, 3000 px or 2048 px, with an optional watermark and location data removed.
- **Nothing is deleted.** **Move** puts keepers in a `Keepers` folder and rejects in a `Rejected` folder, and **Undo** puts everything back.
- **Private.** Everything runs on your Mac. Cull never uploads your photos.

## Keyboard shortcuts

| Key | Action |
| --- | --- |
| ← → | Previous / next (or drag the photo) |
| P / X / U | Keep / reject / clear |
| 1 – 5 | Star rating |
| B | Keep the best of the burst |
| C | Compare the burst |
| F / Z | Zoom to faces / zoom to 100% |
| I | Camera info |
| ⌘Z | Undo |
| ⌘1 – ⌘6 | Filters |
| ⇧⌘E | Export for clients |
| ⇧⌘M | Move keepers and rejects |

## Install

Needs macOS 15 or later and Apple's Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/LightTheEgyptian/Cull.git
cd Cull
./build.sh
```

Or double-click **Build Cull.command**. The app is built on your Mac and installed in Applications.

## Credits

Designed and built by Nur Elmasri, 2026. See the [changelog](CHANGELOG.md) for what's new.
