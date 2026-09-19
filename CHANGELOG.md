# Changelog

## [0.1.0] — unreleased

First build. Plays Wallpaper Engine scene, video, web and image wallpapers natively on macOS.

- Scene rendering in Metal: layers, materials, particles, parallax, post-processing, SceneScript
- Text layers with font fallback
- Video, web and image wallpapers
- Per-display suspension when covered, on battery, in Low Power Mode or under thermal pressure
- Compatibility reporting: wallpapers say what they could not render, by name
- Per-wallpaper settings, edited live and remembered across launches
- First-run walkthrough for importing a library, reopenable from the Help button
- `wetool` for auditing a library from the command line, and `wetool library` for diagnosing
  where the imported folder went

Tested against a real Workshop library of 114 wallpapers, which corrected four format
assumptions that every synthetic test had shared: package revisions run to PKGV0024 rather than
PKGV0005, scenes ship packed while their manifest names the file inside, an image object points
at a model that names the material rather than at the material, and coordinates are measured
from a corner rather than the centre.
