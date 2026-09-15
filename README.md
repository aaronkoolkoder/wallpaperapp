# Diorama

Live wallpapers for macOS Tahoe. Plays **Wallpaper Engine** wallpapers — video, web, and
(eventually) real Metal-rendered Scene wallpapers — plus ordinary images and GIFs. Fully offline:
no account, no server, no network.

> Working codename. Not affiliated with, or endorsed by, Wallpaper Engine or Valve.

## Status

Early. Video, web, image **and Scene** wallpapers play — scenes render natively in Metal from
their `.pkg`. Camera parallax and particle systems work. Text layers and post-processing effect chains are
not drawn yet; wallpapers using them render what we can and report the rest by name. See [PLAN.md](PLAN.md) for the full build plan,
binary format specs, milestones, and licensing constraints.

| Milestone | State |
|---|---|
| M0 — desktop surfaces, display + power management | ✅ Done |
| M1 — library import and indexing | ✅ Done |
| M2 — video / web / image backends | ✅ Done |
| M3 — `.pkg` / `.tex` format layer | ✅ Done |
| M4 — static scene rendering | ✅ Done |
| M5 — parallax + particles | ✅ Done |
| M5b — effect chains, text | ⬜ Next |
| M6 — SceneScript | ⬜ |
| M7 — properties, audio, playlists | ⬜ |
| M8 — signing, notarization, release | ⬜ |

## Measured performance

M5 Pro, 3024×1964 Retina, on battery. Percent of **one** core.

| State | CPU |
|---|---|
| Covered by any window | **0%** |
| Static image / scene preview | **0%** |
| Scene, 3 layers | **0.3%** |
| Scene, 900 particles | **0.1%** |
| Video, 1080p H.264 | **3.2%** |
| Idle, no wallpaper | **0%** (45MB RSS) |

Video misses its sub-1% target; the cause is understood and written up in PLAN.md §6.1 rather
than glossed over.

## Requirements

macOS 26 (Tahoe), Apple Silicon, Xcode 26 / Swift 6.3.

## Build and run

```bash
swift build && swift test
```

```bash
./Scripts/bundle.sh debug && open dist/Diorama.app
```

Diorama is a menu bar app — look for the icon in the menu bar, not the Dock.

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
swift run wetool pkg list scene.pkg         # list package entries
swift run wetool pkg extract scene.pkg out/ # unpack
swift run wetool tex info texture.tex       # describe a texture
swift run wetool manifest project.json      # parse a manifest
swift run wetool scene info <dir>          # describe a scene's layers
swift run wetool scene render <dir> out.png 1920x1080
```

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
