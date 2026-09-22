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
- Diorama's own versions of Wallpaper Engine's stock utility textures (noise, clouds, flow) and
  soft stand-ins for its stock particle sprites
- Web wallpapers are really cut off from the network: stylesheets, fonts, images, `fetch` and
  WebSockets were getting through before, and the report now names the sites a page asks for
- Clocks and dates tell the time: text layers run their scripts, with the settings the wallpaper
  saved (24-hour, separator, seconds)
- Text is drawn at the size, font and alignment it was made with, including fonts that ship
  inside the wallpaper
- Animated textures play frame by frame instead of showing their whole sprite sheet, in layers
  and in particle flocks; video textures show their first frame
- Timeline animations play: intros fade out, ships cross the sky, logos wobble
- Rotated layers are drawn at their angle, particles spawn where their emitter says, and
  turbulence stirs them

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

A third pass looked at every scene's frame beside the preview its author published, and at what
each property in the files actually holds. Most of what it found was the format being read too
narrowly: a property written as an object once it is scripted or bound to a setting (which lost
30 colours, 19 positions and rotations and 37 text layers), angles that are radians rather than
degrees, font sizes stored as `pointsize` and set at four pixels per point, spawn distances left
out of the file because they equal the default, and combos declared in only one stage of a
shader pair, which kept godrays from compiling in five wallpapers. A layer whose texture cannot
be loaded is now hidden rather than drawn as a white rectangle.
