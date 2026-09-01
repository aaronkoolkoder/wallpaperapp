# Diorama

Live wallpapers for macOS Tahoe. Plays **Wallpaper Engine** wallpapers — including real Scene
wallpapers rendered natively in Metal — plus video, web, image and GIF wallpapers. Fully offline.

> Working codename. Not affiliated with, or endorsed by, Wallpaper Engine or Valve.

## Status

In development. See [PLAN.md](PLAN.md) for the full build plan, format specifications,
milestones, and licensing constraints.

## Requirements

- macOS 26 (Tahoe) or later, Apple Silicon
- Xcode 26 / Swift 6.3

## Build

```bash
swift build
swift test
```

## Layout

| Module | Role |
|---|---|
| `WEFormat` | `.pkg` / `.tex` / scene JSON parsing. No GPU, no UI. |
| `ShaderTranspiler` | Wallpaper Engine GLSL → MSL |
| `MetalRenderer` | Render graph, FBO pool, texture + pipeline caches |
| `SceneEngine` | Scene graph, properties, runtime |
| `WallpaperKit` | Desktop surfaces, display topology, power policy |
| `PlayerCore` | Backend protocol: video, web, image, scene |
| `LibraryKit` | Import, index, thumbnails |
| `Diagnostics` | Compatibility reports, performance sampling |

## License

See [THIRD_PARTY.md](THIRD_PARTY.md) for dependency licensing. Note that this project
deliberately does **not** derive from GPL-licensed Wallpaper Engine reimplementations —
see PLAN.md §11.
