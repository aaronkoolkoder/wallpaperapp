# Diorama

Live wallpapers for macOS Tahoe. Plays **Wallpaper Engine** wallpapers — video, web, and
(eventually) real Metal-rendered Scene wallpapers — plus ordinary images and GIFs. Fully offline:
no account, no server, no network.

> Working codename. Not affiliated with, or endorsed by, Wallpaper Engine or Valve.

## Status

Early. Video, web, image **and Scene** wallpapers play — scenes render natively in Metal from
their `.pkg`. Camera parallax, particle systems, post-processing chains (bloom, blur, vignette, chromatic
aberration, sharpen, pixelate) and SceneScript all work. Text layers render, with font fallback when a
wallpaper names a Windows font. Materials and effects run their own shaders, translated from
GLSL to Metal at import; anything that will not translate falls back to a built-in approximation
and is reported by name rather than silently flattened. See [PLAN.md](PLAN.md) for the full build plan,
binary format specs, milestones, and licensing constraints.

| Milestone | State |
|---|---|
| M0 — desktop surfaces, display + power management | ✅ Done |
| M1 — library import and indexing | ✅ Done |
| M2 — video / web / image backends | ✅ Done |
| M3 — `.pkg` / `.tex` format layer | ✅ Done |
| M4 — static scene rendering | ✅ Done |
| M5 — parallax + particles | ✅ Done |
| M5b — effect chains (bloom, blur, vignette…) | ✅ Done |
| M6 — SceneScript, text layers | ✅ Done |
| M7 — playlists, per-display, audio reactivity | ✅ Done |
| M7b — GLSL → Metal, real material and effect shaders | ✅ Done |
| M7c — per-wallpaper settings, live | ✅ Done |
| M8 — signing, notarization, release | ⬜ Next |

## Measured performance

M5 Pro, 3024×1964 Retina, on battery. Percent of **one** core.

| State | CPU |
|---|---|
| Covered by any window | **0%** |
| Static image / scene preview | **0%** |
| Scene, 3 layers | **0.3%** |
| Scene, 900 particles | **0.1%** |
| Scene, particles + bloom chain | **0.1–0.2%** |
| Scene, 2 scripted properties | **0.3–0.5%** |
| Video, 1080p H.264 | **3.2%** |
| Idle, no wallpaper | **0%** (45MB RSS) |

Video misses its sub-1% target; the cause is understood and written up in PLAN.md §6.1 rather
than glossed over.

## Install

Grab the `.dmg` from [Releases](https://github.com/aaronkoolkoder/wallpaperapp/releases), open
it, and drag **Diorama** into **Applications**.

> **First launch: right-click the app and choose Open.**
>
> Builds are signed ad-hoc rather than with an Apple Developer ID, so macOS reports that the
> developer cannot be verified. Right-click → Open gets past it once and it opens normally
> afterwards. Double-clicking the first time only offers to move it to the Bin — that is
> Gatekeeper, not a broken download.
>
> Removing the warning entirely needs a paid Apple Developer ID and notarisation.

Requires macOS 26 (Tahoe) on Apple Silicon.

## Using it

Diorama shows a Dock icon while a window is open and drops to the menu bar when none is, so it
stays out of the way while a wallpaper runs. The menu bar icon opens a panel with what is playing
on each display; **Wallpaper → Wallpaper Library** (⌘L) opens the full browser.

## Build from source

```bash
# Once: builds glslang and SPIRV-Cross from pinned tags.
brew install cmake ninja
Scripts/vendor-shader-tools.sh
```

```bash
swift build && swift test
```

```bash
./Scripts/install.sh release      # builds and installs into /Applications
```

Installing locally rather than from the DMG is the easier path on your own machine: a
locally-built app never picks up the quarantine attribute a browser attaches to downloads, so
Gatekeeper never appears.

Build the installer:

```bash
python3 -m venv .dmgvenv && .dmgvenv/bin/pip install ds_store mac_alias
DMG_PYTHON="$PWD/.dmgvenv/bin/python" Scripts/make-dmg.sh release
```

The DMG window layout is written straight into a `.DS_Store`. Every other recipe scripts Finder
over AppleScript, which needs Automation permission — a prompt locally and a hang in CI.

### Getting your wallpapers across

Copy this folder from your PC to your Mac by any means (AirDrop, USB, a shared folder), then
point Diorama at it:

```
C:\Program Files (x86)\Steam\steamapps\workshop\content\431960
```

Nothing is uploaded anywhere, and Diorama never talks to Steam.

### Diagnostics

| Variable | Effect |
|---|---|
| `DIORAMA_FORCE_RENDER=1` | Disable occlusion suspension, so the render path can be measured without clearing the desktop |
| `DIORAMA_LIBRARY=<path>` | Import a folder without the file panel |
| `DIORAMA_PLAY=<id>` | Start a wallpaper by Workshop ID once the scan finishes |

## wetool

A CLI for inspecting content without launching the app.

```bash
swift run wetool scan ~/Wallpapers          # index a library and summarise it
swift run wetool report ~/Wallpapers        # audit every scene; rank what is missing
swift run wetool pkg list scene.pkg         # list package entries
swift run wetool pkg extract scene.pkg out/ # unpack
swift run wetool tex info texture.tex       # describe a texture
swift run wetool manifest project.json      # parse a manifest
swift run wetool scene info <dir>          # describe a scene's layers
swift run wetool scene render <dir> out.png 1920x1080
```

`report` is the one to run against a real Workshop library. It loads every scene, collects what
could not be rendered, and ranks missing features by **how many wallpapers each affects** — so the
backlog is ordered by what actually bites rather than by guesswork. `--json` writes a
machine-readable copy so successive runs can be diffed as the renderer improves.

`scene render` draws a frame with no window and no display — the golden-image harness, and the
fastest way to debug a scene without one running on your desktop.

## Layout

| Module | Role |
|---|---|
| `WEFormat` | `.pkg` / `.tex` / scene JSON parsing. No GPU, no UI. |
| `ShaderTranspiler` | Wallpaper Engine GLSL front-end → MSL |
| `MetalRenderer` | Render graph, FBO pool, texture + pipeline caches |
| `SceneEngine` | Scene graph, properties, runtime |
| `WallpaperKit` | Desktop surfaces, display topology, power policy |
| `PlayerCore` | Backends: video, web, image, scene |
| `LibraryKit` | Import, index, thumbnails |
| `Diagnostics` | Compatibility reports, performance sampling |

## Licensing

This project deliberately does **not** derive from the GPL-3.0 Wallpaper Engine
reimplementations, which would rule out App Store distribution. See
[THIRD_PARTY.md](THIRD_PARTY.md) and PLAN.md §11.

Run `Scripts/verify-dependency.sh` on anything pulled into the project before using it.
