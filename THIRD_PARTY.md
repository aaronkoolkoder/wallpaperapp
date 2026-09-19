# Third-Party Licenses

Every dependency and reference used by this project, with its license and attribution.
Maintained from the first commit. See PLAN.md §11 for the clean-room policy.

## Ported / derived code

### repkg — MIT
- Source: https://github.com/notscuffed/repkg
- Used for: understanding and reimplementing the `.pkg` and `.tex` binary formats in `WEFormat`.
- MIT permits use with attribution.

## Vendored dependencies

Fetched and built from source by `Scripts/vendor-shader-tools.sh`, pinned to release tags. Both
are permissively licensed and compatible with Mac App Store distribution. Neither is present in the
working tree; the script fetches them.

One correction for accuracy: an early commit briefly staged ~39 glslang and SPIRV-Cross headers
before they were untracked and ignored, so they remain in this repository's git *history*. Both
licences permit redistribution with the licence retained, so this is not a problem — but "never
redistributed" would be an overstatement and the history is public once this repo is.

### glslang — BSD-3-Clause / Apache-2.0
- https://github.com/KhronosGroup/glslang
- Pinned to tag `15.1.0`
- Used for: GLSL → SPIR-V

### SPIRV-Cross — Apache-2.0
- https://github.com/KhronosGroup/SPIRV-Cross
- Pinned to tag `vulkan-sdk-1.3.296.0`
- Used for: SPIR-V → Metal Shading Language

Pinned to tags rather than tracking a branch on purpose: a shader compiler changing underneath
the project would surface as wallpapers rendering differently with no commit to explain it.

## Reference only — NOT used as a code source

The following are GPL-3.0. They are consulted **only** to understand file formats, which are
facts and not copyrightable. No code, structure, or algorithm is copied from them. GPL-3.0 is
incompatible with Mac App Store distribution.

- https://github.com/Almamu/linux-wallpaperengine (GPL-3.0)
- https://github.com/Unayung/wallpaper-engine-mac (GPL-3.0)
