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
- Runs in the background from the menu bar, with no Dock icon and a single window that holds
  both the library and Settings
- Puts back the wallpaper that was playing on each display when it last quit, so opening at
  login shows your wallpaper rather than a bare desktop
- Wallpaper Engine's own effects run with each placement's tuned values, chosen variants and
  painted masks, and optional effects and objects follow the wallpaper's own settings live
- Diorama's own versions of Wallpaper Engine's stock utility textures (noise, clouds, flow)

Tested against a real Workshop library of 114 wallpapers, which corrected four format
assumptions that every synthetic test had shared: package revisions run to PKGV0024 rather than
PKGV0005, scenes ship packed while their manifest names the file inside, an image object points
at a model that names the material rather than at the material, and coordinates are measured
from a corner rather than the centre.

A second pass against the same library, measuring every scene's rendered frame rather than
counting frames, found that the desktop and the test harness had been drawing through different
code. With them sharing one composition, the desktop turned out to be receiving a transparent
frame for every scene with a layer effect, and the fixes that followed — texture padding and
resolution uniforms, aspect-fill, blend factors, effect bindings, stock textures, per-texture
address modes, visibility bound to settings, and red and blue swapped on every raw texture —
brought the median frame from 2081 distinct colours to 7244, matching the bare composition.
