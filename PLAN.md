# Diorama — Live Wallpapers for macOS Tahoe

> **Working codename.** `Diorama` is a placeholder — see [Naming](#naming) before you register anything.
> **Status:** planning. Nothing implemented yet.
> **Target:** macOS 26 Tahoe, Apple Silicon. Swift 6.3, Xcode 26.
> **Author:** Aaron Merchant

---

## 1. What this is

A native macOS app that plays **Wallpaper Engine** wallpapers — including real **Scene** wallpapers, rendered
natively in Metal — plus ordinary video, web, image and GIF wallpapers, entirely offline.

Two stages:

| | Stage 1 | Stage 2 |
|---|---|---|
| **Goal** | Working app, public GitHub repo | Mac App Store release |
| **Distribution** | Notarized DMG + GitHub Releases | Mac App Store |
| **Sandbox** | On (by choice, from day one) | On (required) |
| **Price** | Free, fully unlocked | Free tier + $4.99 IAP unlock |
| **Updates** | Sparkle | App Store |

The two stages are **one codebase, two build configurations**, gated by an `APPSTORE` compile flag. Stage 2 is a
configuration change and a StoreKit module, not a rewrite. Every architectural decision below is made with Stage 2's
constraints already applied, so nothing has to be unwound later.

### 1.1 Positioning against the reference app

The Reddit post that seeded this project describes *Vivid Walls* ($9.99, Mac App Store). It's the closest competitor
and it's a genuinely impressive piece of work. Here's the honest ledger:

**What it gets right — and we must match:**

- Renders the real Scene format, not video recordings of scenes. This is the entire value proposition. Video
  conversion throws away per-scene settings, audio reactivity, parallax, and runtime behavior.
- Fully local. No account, no cloud, no server.
- One-time price, no subscription.

**What we improve on:**

| Their weakness | Our answer |
|---|---|
| Requires a Windows companion app + both machines on the same Wi-Fi | **Manual folder import.** Copy your `431960` folder over by any means — AirDrop, USB, SMB, Syncthing. Zero network code, zero second app, works offline forever. LAN sync becomes an *optional* convenience later, never a requirement. |
| $9.99 up front, no trial | **Free tier that's genuinely useful**, $4.99 to unlock power features. Cheaper, and you try before you buy. |
| "Handles most scenes but not 100%" — silent breakage, report bugs to the dev | **Per-wallpaper compatibility report.** The app tells you exactly which feature it couldn't render and why, in-app. Failures are legible, not mysterious. Backed by a golden-image regression suite. |
| MoltenVK → Vulkan → Metal translation layer at runtime | **Native Metal, no translation layer.** Shaders are transpiled to MSL and compiled to a cached `.metallib` **at import time**, not at runtime. No first-frame hitch, no Vulkan shim overhead, smaller binary. |
| Wallpaper Engine content only | Also plays plain video files, GIFs, image folders, local web bundles, and Shadertoy-style GLSL. |
| No playlists, scheduling, or per-display control mentioned | Playlists, shuffle, time-of-day and Dark Mode triggers, independent wallpaper per display and per Space. |
| Power behavior unstated | **Power management as a visible, first-class feature** with a live energy readout. See §6. |

---

## 2. Locked decisions

These are settled; the rest of the plan assumes them.

1. **Ingest: manual folder import.** The user points the app at a copy of
   `Steam/steamapps/workshop/content/431960`. No companion app in Stage 1. No Steam API calls, no SteamCMD, no
   downloading on the user's behalf — see §11 for why that matters legally.
2. **Render scope: Scenes are in Stage 1.** Scenes are the entire premise; shipping without them makes this a Plash
   clone. But they are *sequenced last*, behind an app shell that video and web wallpapers already prove out. That
   way there's a usable, shippable build from week 3 onward and the risky work happens on a foundation that's
   already known-good rather than on speculation.
3. **Monetization: feature-gated free tier + $4.99 non-consumable IAP.** No ads. No major ad SDK supports macOS
   (AdMob, AppLovin, Unity Ads are iOS/Android only), and the workarounds all require a server and network access,
   which would break the offline design and add tracking-disclosure burden for revenue that rounds to nothing.
4. **Rendering: native Metal.** No MoltenVK, no Vulkan.
5. **Test assets: real.** You own Wallpaper Engine and have a Windows PC, so the compatibility corpus (§12) is built
   from a real Workshop library, not synthetic fixtures.

---

## 3. Architecture

### 3.1 Module graph

Local Swift packages, composed by a thin app target. Each module is independently testable and has no UI dependency
except where stated.

```
                       ┌─────────────────┐
                       │   DioramaApp    │  SwiftUI + AppKit. Menu bar, library,
                       │   (app target)  │  settings, onboarding, paywall.
                       └────────┬────────┘
              ┌─────────────────┼─────────────────┐
              │                 │                 │
      ┌───────▼──────┐  ┌───────▼──────┐  ┌──────▼───────┐
      │ WallpaperKit │  │   Library    │  │ Diagnostics  │
      │              │  │              │  │              │
      │ Desktop      │  │ Import, scan │  │ Compat report│
      │ surfaces,    │  │ index, thumbs│  │ perf HUD,    │
      │ display mgmt │  │ bookmarks    │  │ energy meter │
      │ power mgmt   │  └──────┬───────┘  └──────────────┘
      └───────┬──────┘         │
              │                │
      ┌───────▼────────────────▼───────┐
      │          PlayerCore            │  One protocol, four backends:
      │  Backend protocol + lifecycle  │  VideoBackend  (AVFoundation)
      └───────┬────────────────────────┘  WebBackend    (WKWebView)
              │                            ImageBackend  (Core Image)
      ┌───────▼──────┐                     SceneBackend  ↓
      │  SceneEngine │  Scene graph, objects, effects, particles,
      │              │  properties, SceneScript runtime
      └───┬──────┬───┘
          │      │
  ┌───────▼──┐ ┌─▼──────────────┐
  │ WEFormat │ │  MetalRenderer │  Render graph, FBO pool, texture
  │          │ │                │  cache, pipeline state cache
  │ pkg, tex │ └─┬──────────────┘
  │ json     │   │
  └──────────┘ ┌─▼─────────────────┐
               │ ShaderTranspiler  │  WE GLSL → SPIR-V → MSL → metallib
               └───────────────────┘  (import-time, cached)
```

**Dependency rule:** arrows point down only. `WEFormat` knows nothing about Metal. `MetalRenderer` knows nothing
about Wallpaper Engine. `SceneEngine` is the only module that knows both. This keeps the format layer trivially
unit-testable with no GPU, and lets the renderer be exercised by synthetic scenes.

### 3.2 Process model

**One process.** Not one-per-display, not an XPC helper per wallpaper.

- A single `MTLDevice`, one command queue, one shared texture cache.
- Two displays showing the same wallpaper share every texture and pipeline state, and render from one scene
  simulation into two drawables. This is a large memory and CPU win over the naive approach and it's the reason to
  resist the "isolate each wallpaper in its own process" instinct.
- Rendering happens on a dedicated serial queue, not the main thread. The main thread only ever handles UI.
- Swift 6 strict concurrency is on. The render loop is an `actor`-isolated or explicitly `@unchecked Sendable`
  boundary with documented invariants — decide per-type, don't blanket-suppress.

Cost: a crash in a malformed scene takes down the whole app. Mitigation is defensive parsing (§4.4), not process
isolation — the perf tax of isolation is not worth it for a thing that runs 24/7 in the background.

---

## 4. The Wallpaper Engine format layer (`WEFormat`)

Pure Swift, zero dependencies, no GPU, no UI. This module is a **port of `notscuffed/repkg` (MIT)** — legally clean,
attribution required. See §11.

### 4.1 On-disk layout

A Workshop item is a directory named by its numeric ID:

```
431960/
  2837291840/
    project.json          ← manifest: title, type, preview, file, properties
    preview.jpg|gif
    scene.pkg             ← Scene type: packed archive of everything below
    <video>.mp4           ← Video type
    index.html            ← Web type
```

`project.json` `type` field is one of `scene` | `video` | `web` | `application`. **`application` is a Windows `.exe`
and is out of scope permanently** — the library UI marks these unsupported with a clear explanation rather than
hiding them, so the user isn't left wondering where a wallpaper went.

### 4.2 `.pkg` container

A flat archive, not compressed at the container level.

```
int32   headerVersionLength
char[]  headerVersion        // "PKGV0001" … "PKGV0005"
int32   entryCount
entry × entryCount {
  int32  pathLength
  char[] path                // e.g. "materials/wave.json"
  int32  offset              // relative to end of header block
  int32  size
}
byte[]  blob
```

Support **PKGV0001 through PKGV0005**. Later versions add fields to the entry record; version-dispatch the entry
reader rather than assuming a fixed stride.

### 4.3 `.tex` textures

```
"TEXV0005"\0                 // file magic
"TEXI0001"\0                 // extra magic
int32  format                // 0=ARGB8888 4=DXT5 6=DXT3 7=DXT1 8=RG88 9=R8
int32  flags                 // 1=Interpolation 2=ClampUVs 4=IsGif
int32  textureWidth, textureHeight
int32  imageWidth,  imageHeight
int32  _unknown
"TEXB000{1,2,3}"\0           // mipmap container version
  [TEXB0003 only] int32 _unknown
  [TEXB0003 only] int32 freeImageFormat
int32  mipmapCount
mip × mipmapCount {
  int32  width, height
  int32  isCompressed
  int32  uncompressedSize
  int32  compressedSize
  byte[] data                // LZ4 block when isCompressed
}
[optional] "TEXS000{1,2,3}"  // animated sprite frame table
```

Two decisions that matter:

- **BC textures upload directly to Metal — no transcoding.** Apple Silicon (Apple7 / M1 and later) supports BC
  compression natively; verify with `MTLDevice.supportsBCTextureCompression` at launch and keep a CPU decode path
  as a fallback for the property returning false. This avoids an expensive import-time transcode step and keeps
  textures compressed in VRAM, which is a real memory win on a 24/7 background process.
- **LZ4 block decompression** uses Apple's `compression_decode_buffer` with `COMPRESSION_LZ4_RAW` from the
  `Compression` framework. No third-party LZ4 dependency.

`TEXS` frame tables drive animated sprite sheets — needed for a meaningful fraction of scenes, so it's in scope for
M3, not deferred.

### 4.4 Parsing posture

Every parser is **hostile-input hardened**. This content is arbitrary third-party data from the Steam Workshop, and
the app runs continuously in the background:

- All reads bounds-checked against the buffer; no force-unwraps, no `assumingMemoryBound` on unvalidated offsets.
- Every length and count validated against remaining bytes before allocation — a corrupt `entryCount` must not
  cause a multi-gigabyte allocation.
- Errors are typed and recoverable: a bad wallpaper is skipped and surfaced in the compatibility report, never
  fatal.
- Fuzz the PKG and TEX readers with `swift-testing` + a corpus of mutated real files. This is cheap and catches the
  class of bug that would otherwise be a Stage 2 security review problem.

---

## 5. The scene renderer

The hard part. Roughly two-thirds of total effort.

### 5.1 Scope calibration

For grounding: `Almamu/linux-wallpaperengine` is a mature open-source scene renderer with ~4.6k stars and
**255 source files** — 88 in rendering, 54 in data/parsing, 28 in scripting, 16 in audio. That is the honest size of
this problem. It is **GPL-3.0 and therefore unusable as a code source for us** (§11), but it's an excellent map of
the territory and a reference for *what the format does*.

### 5.2 Scene model

`scene.json` has three roots: `camera`, `general`, `objects`.

- **Objects** are `image`, `sound`, `particle`, or `text`. Each carries transform, visibility, parallax depth, and
  either a material or a particle system.
- **Materials** reference shaders and textures and declare **passes**; **effects** are ordered chains of passes
  applied to an object's rendered output through ping-ponged framebuffers.
- **Properties** (`general.properties` in `project.json`) are the per-wallpaper user-configurable settings —
  sliders, colors, booleans, combos — bound to shader uniforms. Surfacing these properly in a native settings UI is
  a differentiator; the reference app's users lose them entirely when scenes get recorded to video.

### 5.3 Render graph

Layered 2D compositing with an orthographic camera, driven by a small retained render graph:

1. Resolve the object list into draw order (depth, then declaration order).
2. Each object renders to an FBO from a **pooled, size-bucketed allocator** — allocating framebuffers per frame is
   the single easiest way to destroy the performance target.
3. Effect chains ping-pong between two same-size FBOs from the pool.
4. Final composite into the `CAMetalLayer` drawable.

Metal specifics:
- `MTLStorageModePrivate` for all GPU-only textures and FBOs.
- Pipeline states built once at import and stored in an `MTLBinaryArchive`, so PSO creation is a cache hit at
  runtime rather than a compile.
- Argument buffers for material bindings to cut per-draw encoder overhead.
- Explicit `MTLHeap` for the FBO pool to avoid allocator churn.

### 5.4 Shader pipeline — the key optimization

Wallpaper Engine ships GLSL-flavored `.vert`/`.frag` with a custom preprocessor: `#include`, `COMBO` variant
defines, and JSON metadata in trailing comments that bind uniforms to user properties.

**Pipeline, run once at import time:**

```
WE shader source
  → preprocess (resolve #include, expand COMBO variants, strip/parse metadata)
  → glslang        (GLSL → SPIR-V)
  → SPIRV-Cross    (SPIR-V → MSL)
  → MTLDevice.makeLibrary(source:)  → cached .metallib on disk
  → MTLBinaryArchive of pipeline states
```

Both `glslang` (BSD-3/Apache-2) and `SPIRV-Cross` (Apache-2.0) are permissively licensed and App Store compatible.

Why import-time rather than runtime: shader compilation is the dominant cost of first-play, and `COMBO` variants
mean a single shader can expand into dozens of permutations. Paying it once behind a visible "Preparing wallpaper…"
progress bar — with the result cached in Application Support keyed by content hash — means **switching wallpapers is
instant and stutter-free forever after**. The reference app compiles through MoltenVK at runtime; this is where we
beat it on feel, not just on numbers.

`MTLDevice.makeLibrary(source:options:)` is a supported runtime API and is permitted under App Store rules. Do not
attempt to invoke `xcrun metal` — that binary does not exist inside a sandbox.

### 5.5 SceneScript

Wallpaper Engine's scripting layer is JavaScript-like. Use **JavaScriptCore**, which ships with macOS.

Review-risk note: App Store guideline 2.5.2 restricts executing downloaded code. The defensible framing — and the
one the precedent app operates under — is that these scripts are inert data inside user-supplied content files,
executed in a sandboxed interpreter with no filesystem or network bridge, exactly as a Web wallpaper's JavaScript
runs inside `WKWebView`. Expose **no native bridge whatsoever** to the JS context beyond scene uniforms. Document
this in the review notes (§10.4).

### 5.6 Staged capability

Not everything lands at once, and the app should be honest about it. The compatibility report distinguishes:

- ✅ **Supported** — renders correctly.
- ⚠️ **Degraded** — renders, with a named feature missing (e.g. "audio reactivity unavailable").
- ❌ **Unsupported** — with the specific reason.

This is the direct answer to the reference app's "handles most scenes but not 100%." Same underlying reality;
radically better experience, because the user knows.

---

## 6. Performance: the 1–2% budget

The stated requirement is 1–2% CPU. Here's the honest version, and how we hit it.

### 6.1 Targets and measured results

Measured on an M5 Pro (5 P-cores, 10 E-cores), 3024x1964 Retina, on battery. CPU figures are
percent of **one** core, as `ps` reports them.

| State | Target | **Measured** | Notes |
|---|---|---|---|
| Occluded by any window | 0% | **0%** ✅ | Display link stopped, process idle. The common case. |
| No wallpaper set | 0% | **0%** ✅ | |
| Static image / scene preview | < 1% | **0%** ✅ | Handed to the compositor once; no display link, no per-frame work. |
| Scene, 3 layers @ 30fps | 1–2% | **0.3%** ✅ | Native Metal. Beats target. |
| Video, 1080p H.264 | < 1% | **3.2%** ⚠️ | Misses target. See below. |
| Video, 4K HEVC 240fps | — | **3.6%** | Apple's own wallpaper format; an outlier, not typical Workshop content. |
| Idle app, no content | — | **0%**, 45MB RSS | |

**The video number misses its target and the reason is now understood.** Cost is roughly constant
across 1080p H.264 and 4K HEVC — halving the resolution and changing codec moved it by 0.4 points
— so it is not decode. Since the static-image path on the same surface measures a true 0%, the
window, the desktop level and the compositing of a full-screen layer are all free. What remains is
the `AVPlayerLayer` presentation path itself.

Two things were tried and did not help: stopping the redundant display link (correct in principle,
and kept, but it was not the cost), and `preferredMaximumResolution` (documented mainly for HLS;
local file assets appear to ignore it).

The escape hatch named in §5.4 is the next thing to try: feed `AVSampleBufferDisplayLayer` directly
from an `AVAssetReader` and present at the video's own rate rather than the display's. That was
deliberately not taken first because it means owning the read loop, the timebase and the loop
wrap, and the saving had to be demonstrated before paying for that complexity. It now has a
measurement to justify it.

**In absolute terms:** 3.2% of one core is ~0.21% of this machine's total CPU, and it only applies
while the wallpaper is genuinely visible. That is a defensible place to ship from, but it is not
the number the plan promised, and the marketing copy must quote the measured figure rather than
the target.

### 6.2 The mechanisms

**Suspension — this is where the wins actually are.** A wallpaper is invisible most of the time. Rendering it anyway
is the mistake every competitor makes.

1. `NSWindow.occlusionState` — no `.visible` flag means stop the display link entirely. Not "render slower." Stop.
2. Fullscreen app detection via `CGWindowListCopyWindowInfo` + frontmost-app bounds → suspend that display only.
3. Display sleep and screen lock — `NSWorkspace.willSleepNotification`, `com.apple.screenIsLocked` → suspend all.
4. Inactive Space → suspend the surfaces not on the active Space.
5. Displays that are off or disconnected → tear down surfaces, release textures.

**Throttling, when actually visible:**

6. `CADisplayLink` with `preferredFrameRateRange` — default cap 30fps; Pro tier can raise to 60/120 on ProMotion.
   Never render faster than the wallpaper's own declared FPS.
7. `ProcessInfo.isLowPowerModeEnabled` → suspend (default) or hard-cap at 15fps.
8. `ProcessInfo.thermalStateDidChangeNotification` → step down at `.serious`, suspend at `.critical`.
9. On battery vs. AC (`IOPSCopyPowerSourcesInfo`) → independent frame rate caps.

**Rendering efficiency:**

10. **MetalFX spatial upscaling** — render at 0.5–0.75× and upscale. On a 5K display this is a very large GPU
    saving for a background element nobody scrutinizes at 1:1. Exposed as a Quality setting; default **Balanced**.
11. `CAMetalLayer.maximumDrawableCount = 2` — a wallpaper does not need triple buffering; double buffering cuts a
    full framebuffer of memory per display.
12. `wantsExtendedDynamicRangeContent = false` unless the content genuinely needs it.
13. Shared texture cache and shared scene simulation across displays showing the same wallpaper.
14. Video uses `AVSampleBufferDisplayLayer` fed directly, **not** `AVPlayer` — bypasses the full playback graph and
    keeps decode in the fixed-function block.
15. Zero per-frame allocation in the render loop. Enforced by a debug assertion that trips on allocation during
    frame encode.

### 6.3 Making it verifiable

Performance claims rot silently. So:

- A **perf HUD** (debug + optional in release) showing frame time, CPU%, GPU%, memory, and `powermetrics`-derived
  energy impact.
- A **CI performance gate**: a headless harness renders the test corpus offscreen for N frames and fails the build
  if frame time regresses beyond a threshold. Without this, §6.2 decays into aspiration within two months.

---

## 7. macOS integration

### 7.1 The desktop surface

One borderless `NSWindow` per `NSScreen`:

```swift
window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
window.ignoresMouseEvents = true
window.isOpaque = true
window.hasShadow = false
window.styleMask = .borderless
window.canHide = false
window.displaysWhenScreenProfileChanges = true
```

Sitting one level below `.desktopIconWindow` places us **above the system desktop picture but below desktop icons**,
which is correct — icons must stay on top and stay clickable. `ignoresMouseEvents` keeps right-click-on-desktop and
drag-select working normally. No private APIs, no accessibility permissions, no injection.

Rebuild surfaces on `NSApplication.didChangeScreenParametersNotification` (resolution change, display connect,
arrangement change). Handle it as a full teardown/rebuild rather than trying to diff — it's rare, and diffing
display topology is a bug farm.

### 7.2 App shape

- **Menu bar app** (`LSUIElement`), no Dock icon by default, user-toggleable.
- Menu bar popover: current wallpaper per display, quick switcher, pause/resume, energy readout.
- `SMAppService.mainApp.register()` for launch at login — the modern, sandbox-safe API.

### 7.3 Permissions

The app requests **as close to nothing as possible**, and this is a marketing point, not just hygiene:

| Capability | Requirement | When |
|---|---|---|
| Read the wallpaper library | `files.user-selected.read-only` + security-scoped bookmarks | At import |
| Audio reactivity | Screen Recording TCC (ScreenCaptureKit system audio) | **Only** if the user enables it |
| IAP | `network.client` | Stage 2 only, StoreKit only |

Everything else — no microphone, no camera, no location, no contacts, no analytics, no network in Stage 1 at all.
`PrivacyInfo.xcprivacy` declares zero data collection and zero tracking, truthfully.

Audio reactivity uses `SCStream` with audio capture rather than an audio loopback driver (Soundflower/BlackHole
style), because a kernel/audio driver install is a non-starter for App Store and a support nightmare regardless.

### 7.4 Automation

- **Shortcuts.app** actions: set wallpaper, next in playlist, pause, resume, set per display.
- AppleScript / URL scheme (`diorama://`) for scripting.
- These are cheap to add and are the kind of thing that earns power-user goodwill the competitor doesn't have.

---

## 8. Design — a distinct Tahoe app

Native-feeling, not a themed cross-platform shell. The point is that it looks like something Apple would ship.

**Foundation:** SwiftUI on macOS 26, adopting **Liquid Glass** via `.glassEffect()` and `GlassEffectContainer`
(`NSGlassEffectView` where AppKit interop is needed). Recompiling on Xcode 26 adopts it for standard chrome
automatically; the custom surfaces need explicit work.

**Screens:**

1. **Library** — the main window. A dense, fluid grid of animated previews over a glass sidebar (All / Scenes /
   Video / Web / Playlists / Unsupported). Previews animate on hover only, and only a bounded number at once — an
   auto-playing grid of 300 wallpapers is exactly the kind of thing that makes an app feel cheap and hot.
2. **Detail / Inspector** — live preview, the wallpaper's own properties (sliders, colors, combos) rendered as
   native controls, per-display assignment, and the **compatibility report**.
3. **Playlists** — ordered sets with shuffle, interval, and triggers (time of day, Dark Mode change, Focus mode).
4. **Settings** — Displays, Performance (with the live energy meter), Library, General, About.
5. **Onboarding** — a genuinely good first-run flow that walks through getting the `431960` folder off a PC. This is
   the app's single biggest friction point and deserves real design attention, including a copy-paste PowerShell
   one-liner and an AirDrop/SMB/USB walkthrough with screenshots.

**Principles:** respect Reduce Motion and Increase Contrast; full keyboard navigation; VoiceOver labels on the grid;
light and dark both designed, not one derived from the other. Ship an app icon that survives being 16pt in the menu
bar.

---

## 9. Stage 1 milestones

Sequenced so there is a **runnable, useful app from M2 onward** and the risky work lands on proven foundations.
Week estimates assume focused solo work; M4–M6 are the ones that realistically slip.

### M0 — Skeleton and desktop surface · ~1 week
XcodeGen project, local SwiftPM packages, CI on a macOS runner. Menu bar app. A desktop surface on every display
rendering an animated Metal gradient. Display link + full power manager from §6.2. Perf HUD.

> **Exit:** a gradient animates behind desktop icons on all displays at <1% CPU, and drops to literally 0% when any
> window covers it. *Proving the power model before building anything on top of it is the whole point of M0.*

### M1 — Library and import · ~1 week
Folder picker with security-scoped bookmarks. Recursive scan of `431960/<id>/project.json`. Metadata index in a
local store. Thumbnail cache. Library grid UI.

> **Exit:** import a real Workshop library, browse 300+ items with thumbnails, 120fps scrolling, cold launch <1s.

### M2 — Video and Web backends · ~1 week
`PlayerCore` protocol. `AVSampleBufferDisplayLayer` video backend with seamless looping. `WKWebView` backend, local
content only, remote loads blocked. Image and GIF backends.

> **Exit:** **the app is shippable.** Video wallpaper at <1% CPU. This is already competitive with most of the Mac
> live-wallpaper market.

### M3 — Format layer · ~2 weeks
`WEFormat`: `BinaryReader`, PKG v1–v5, TEX with all formats + TEXB1–3 + LZ4 + TEXS frames. A dev CLI (`wetool`) to
extract and inspect — invaluable for debugging every later milestone. Fuzz corpus.

> **Exit:** extract any `scene.pkg`; decoded textures match `repkg` output byte-for-byte; fuzzer runs clean.

### M4 — Static scene rendering · ~3 weeks
`scene.json` model. Image objects, materials, single-pass. Metal render graph, FBO pool, ortho camera, blend modes.
`ShaderTranspiler` end to end with on-disk caching.

> **Exit:** simple layered scenes render pixel-comparable to reference screenshots from Wallpaper Engine on the PC.

### M5 — Scene dynamics · ~3 weeks
Multi-pass effect chains. Particle systems. Text objects. Parallax and camera motion. Time/mouse/audio uniforms.

> **Exit:** ≥70% of the 100-wallpaper corpus renders correctly or acceptably-degraded.

### M6 — SceneScript · ~2 weeks
JavaScriptCore runtime, scene bindings, no native bridge.

> **Exit:** scripted wallpapers animate correctly; corpus pass rate ≥85%.

### M7 — Properties, audio, polish · ~2 weeks
Per-wallpaper property UI. ScreenCaptureKit audio reactivity. Playlists, scheduling, per-display and per-Space
assignment. Compatibility report UI. Shortcuts actions. Full accessibility pass.

> **Exit:** feature-complete for Stage 1.

### M8 — Release engineering · ~1 week
Developer ID signing, notarization, stapling, DMG. Sparkle. README, docs, screenshots. GitHub Actions release
workflow.

> **Exit:** `v1.0.0` tagged, notarized DMG on GitHub Releases.

**Total: ~16 weeks.** Treat M4–M6 (8 weeks) as the estimate that could double. If it does, M2's build is still a
real product you can ship in the meantime — which is exactly why the sequence is arranged this way.

---

## 10. Stage 2 — Mac App Store

~4–6 weeks after Stage 1. One codebase; `#if APPSTORE` gates the differences.

### 10.1 What changes

| | Stage 1 | Stage 2 |
|---|---|---|
| Sandbox | On (already) | On — no change needed, by design |
| Updates | Sparkle | Removed; App Store |
| Screensaver `.saver` | Supported | **Removed** — a sandboxed app cannot install a screensaver plugin |
| IAP | None | StoreKit 2 |
| Entitlements | No network | + `network.client` (StoreKit only) |

Building Stage 1 sandboxed from day one is the single decision that makes Stage 2 cheap. Retrofitting a sandbox onto
a finished Mac app is weeks of misery.

### 10.2 Free vs. Pro

Free must be genuinely good — a free tier that feels like nagware earns 1-star reviews and no conversions.

**Free**
- Unlimited library import and browsing
- Video, web, image, GIF wallpapers — unrestricted
- Scene wallpapers on **one** display
- 30fps cap, Balanced quality
- Manual switching

**Pro — $4.99, non-consumable**
- Scenes on all displays
- Per-display and per-Space assignment
- Unlocked frame rate (60/120 ProMotion) and quality modes
- Playlists, scheduling, shuffle, triggers
- Audio reactivity
- Per-wallpaper property editing
- Shortcuts and AppleScript automation

Implementation: StoreKit 2 with `Transaction.currentEntitlements`, offline-tolerant (a cached entitlement must keep
working with no network — this app's whole promise is that it works offline). One paywall surface, no repeated
interruption, no countdown timers.

### 10.3 Store assets
Localized description, 5–6 screenshots, a preview video (screen recording of real scenes, which sells this far
better than stills), privacy manifest, support URL, marketing page.

### 10.4 Review strategy
Anticipate these and write review notes up front:

- **2.5.2 (downloaded code)** — SceneScript. Framing: inert data in user-supplied files, sandboxed interpreter,
  zero native bridge, directly analogous to JS in a `WKWebView` wallpaper.
- **4.1 (copycat) / 5.2 (IP)** — state plainly that the app is a *player* for content the user already owns; it
  bundles no Wallpaper Engine content, code, or branding, and performs no downloads on the user's behalf.
- **2.4.5 / power** — have the energy measurements from §6.3 ready.
- **3.1.1 (IAP)** — unlock is a non-consumable, correctly configured.

The precedent app cleared review with a similar architecture, so this is navigable — but go in with the notes
written rather than improvising in a rejection thread.

---

## 11. Legal, licensing, and clean-room discipline

**Read this before writing any code.** Getting it wrong invalidates Stage 2 entirely.

### 11.1 The licensing split

| Project | License | Can we use the code? |
|---|---|---|
| `notscuffed/repkg` | **MIT** | ✅ **Yes.** Port freely with attribution. Basis for `WEFormat`. |
| `Almamu/linux-wallpaperengine` | **GPL-3.0** | ❌ **No.** Reference for *format understanding* only. |
| `Unayung/wallpaper-engine-mac` | **GPL-3.0** | ❌ **No.** Closest prior art, still off-limits as a source. |

**Why GPL-3.0 is fatal here:** copying GPL code would force the entire app to be GPL-3.0, which (a) conflicts with a
paid closed-source product and (b) is fundamentally incompatible with App Store distribution — GPL-3.0's
anti-tivoization and redistribution terms cannot be satisfied under the App Store's terms of service. Apps have been
pulled from the store for exactly this.

**The rule:** file formats and protocols are facts, and facts are not copyrightable. Reading GPL source to
*understand what a byte at offset 12 means* is fine. Copying its structure, algorithms, or code is not. When in
doubt on the renderer, work from the format description in this document and from observed behavior of the real
Wallpaper Engine on your PC — not from someone else's implementation.

Third-party code that **is** safe: `glslang` (BSD-3/Apache-2), `SPIRV-Cross` (Apache-2.0), `repkg` (MIT). Maintain a
`THIRD_PARTY.md` with every dependency, its license, and its attribution text, from M0.

### 11.2 Content and trademark

1. **Never bundle, host, or transfer Workshop content.** The app is a player. The user supplies content they
   already subscribed to on their own account. No sample wallpapers in the binary, ever.
2. **Never download from Steam on the user's behalf.** This is precisely why manual import (§2.1) is the right
   Stage 1 choice — it isn't just simpler, it's the defensible one. Automating Workshop downloads would put the app
   against the Steam Subscriber Agreement.
3. **"Wallpaper Engine" is someone else's trademark.** Do not use it as branding, in the app name, in the icon, or
   in the App Store title/subtitle. Describe compatibility factually in body copy: *"Plays wallpapers from your
   Wallpaper Engine library."* Nominative use to describe interoperability is fine; suggesting affiliation is not.
4. **Residual risk, stated plainly:** the Wallpaper Engine developers could object to an interoperating player.
   Precedent (the reference app is live on the App Store) suggests this is tolerated, but it is a real,
   non-zero business risk that should factor into how much you invest. This is a judgment call, not a blocker —
   just make it with open eyes.

---

## 12. Testing

- **Unit** — `swift-testing` across `WEFormat` (parsers, all PKG/TEX versions), `SceneEngine` (model, properties),
  `ShaderTranspiler` (golden MSL output).
- **Fuzz** — mutated PKG/TEX corpus against the parsers. Non-negotiable given untrusted input.
- **Golden-image regression** — headless offscreen render of the corpus at fixed timesteps, compared against
  approved PNGs with a perceptual diff threshold. **This is what turns "handles most scenes" into a number you can
  watch go up**, and it's the single highest-leverage piece of infrastructure in the project. Build it during M4,
  not later.
- **Compatibility corpus** — 100 real Workshop wallpapers you own, chosen to span scene/video/web, simple to heavy,
  scripted and not, audio-reactive and not. Track a pass/degraded/fail rate per commit.
- **Performance gate** — CI fails on frame-time regression (§6.3).
- **Manual matrix** — multi-display, mixed DPI, display hot-plug, Spaces, Stage Manager, fullscreen apps, sleep/wake,
  Low Power Mode, thermal throttling, Reduce Motion, VoiceOver.

---

## 13. Repo layout

```
wallpaper/
├─ PLAN.md
├─ README.md
├─ THIRD_PARTY.md
├─ project.yml                  # XcodeGen — diffable project definition
├─ Packages/
│  ├─ WEFormat/                 # pkg, tex, json  (no GPU, no UI)
│  ├─ SceneEngine/              # scene graph, properties, SceneScript
│  ├─ MetalRenderer/            # render graph, FBO pool, caches
│  ├─ ShaderTranspiler/         # WE GLSL → MSL
│  ├─ WallpaperKit/             # desktop surfaces, displays, power
│  ├─ PlayerCore/               # backend protocol + video/web/image
│  ├─ Library/                  # import, index, thumbnails, bookmarks
│  └─ Diagnostics/              # compat report, perf HUD
├─ App/                         # SwiftUI app target
├─ Tools/wetool/                # dev CLI: extract, inspect, render-offscreen
├─ Tests/
│  ├─ Corpus/                   # .gitignored — your own Workshop content
│  └─ Golden/                   # approved reference PNGs
└─ .github/workflows/           # build, test, perf gate, release
```

**XcodeGen** over a checked-in `.xcodeproj`: the project file becomes reviewable YAML instead of an unmergeable
XML blob. Worth it from day one on a repo meant to be public.

`Tests/Corpus/` is **gitignored and must stay that way** — it contains Workshop content you don't have the right to
redistribute (§11.2). Add the ignore rule in M0, before the first import, not after.

---

## 14. Risks

| Risk | Severity | Response |
|---|---|---|
| Scene renderer takes far longer than estimated | **High** | Sequence guarantees a shippable app at M2. Scenes land incrementally with a visible pass-rate metric. |
| Accidental GPL contamination | **High** | §11 clean-room rule; no GPL source in the repo or on the working machine while writing the renderer. |
| Shader transpilation fails on exotic WE constructs | Medium | Per-wallpaper compat report degrades gracefully; corpus surfaces the real frequency early. |
| App Store rejection on 2.5.2 (SceneScript) | Medium | Review notes prepared in advance; precedent exists; worst case ship Stage 2 with scripting disabled and scripted wallpapers marked degraded. |
| Wallpaper Engine devs object | Low–Medium | Business risk, accepted knowingly. Never use their branding. |
| Power target missed on heavy scenes | Medium | Honest published numbers, aggressive defaults, user-facing energy meter, MetalFX upscaling. |
| Manual import friction hurts adoption | Medium | Invest real design effort in onboarding (§8.5); Windows companion becomes the obvious Stage 1.5 if metrics say so. |

---

## 15. Open items

1. <a name="naming"></a>**Name.** `Diorama` is a working codename. Before registering: check the Mac App Store, the
   USPTO/EUIPO trademark databases, and domain availability. Alternatives worth testing: *Vespera*, *Motif*,
   *Prism*, *Lumen*, *Halcyon*.
2. **Apple Developer Program** — $99/yr, required for notarization in Stage 1 (not just Stage 2). Enroll early;
   it can take days.
3. **Windows companion (Stage 1.5)** — deferred, not cancelled. Revisit once onboarding drop-off is measurable.
4. **Bundle ID** — reserve `app.<yourdomain>.diorama` style once the name settles.

---

## Appendix — References

Format documentation and prior art. **See §11 before reading any GPL source.**

- [notscuffed/repkg](https://github.com/notscuffed/repkg) — MIT. PKG/TEX reference implementation. **Portable.**
- [linux-wallpaperengine texture format docs](https://github.com/Almamu/linux-wallpaperengine/blob/main/docs/textures/TEXTURE_FORMAT.md) — format documentation.
- [Almamu/linux-wallpaperengine](https://github.com/Almamu/linux-wallpaperengine) — GPL-3.0. **Reference only, do not copy.**
- [Unayung/wallpaper-engine-mac](https://github.com/Unayung/wallpaper-engine-mac) — GPL-3.0. **Reference only, do not copy.**
- [Metal Feature Set Tables](https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf)
- [supportsBCTextureCompression](https://developer.apple.com/documentation/metal/mtldevice/supportsbctexturecompression)
- [Vivid Walls](https://apps.apple.com/us/app/vivid-walls-live-wallpapers/id6761993729?mt=12) — the competitor.
