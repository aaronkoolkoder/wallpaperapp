# Privacy Policy

**Diorama does not collect, transmit, or store any personal information.**

Last updated: 21 September 2026.

This is not a summary of a longer policy. It is the whole policy, and it is short because the
app genuinely does nothing that would need explaining.

## Nothing leaves your Mac

Diorama contains no networking code. There is no `URLSession`, no analytics SDK, no crash
reporter, no account system, no licence server, and no "anonymous usage statistics". There is
nothing to opt out of, because there is nothing to opt into.

If you disconnect your Mac from the internet, every feature of Diorama continues to work
exactly as before. That is the test, and it is the reason the app was built to run entirely
offline in the first place.

**There are no advertisements.** Diorama does not include an advertising SDK, and therefore
carries none of the tracking that comes with one.

## What is stored, and where

All of it stays on your Mac, in your own user account.

| What | Where | Why |
|---|---|---|
| Which folder holds your wallpapers | A bookmark in app preferences | So your library reopens next launch |
| Which wallpaper is on which display | App preferences | So your desktop survives a restart |
| Your playlists and schedules | App preferences | Because you made them |
| Per-wallpaper settings you changed | App preferences | So a slider you moved stays moved |
| A still image of the current wallpaper | `~/Library/Application Support/Diorama` | So the menu bar and Mission Control tint correctly. Capped and pruned |
| Translated shaders | `~/Library/Application Support/Diorama` | So a wallpaper opens fast the second time |
| The compiled network block for web wallpapers | `~/Library/Application Support/Diorama` | So a web wallpaper is never opened without it |

Deleting the app and `~/Library/Application Support/Diorama` removes all of it.

## Your wallpapers

Diorama reads the wallpaper folder you choose. It reads it **in place** — nothing is copied,
uploaded, indexed remotely, or sent anywhere. It reads nothing else on your disk, and it never
asks to.

Diorama does not connect to Steam, does not sign in to anything, and does not download
wallpapers on your behalf. You bring your own folder.

## Permissions

Diorama asks for two things, both only when you need them, and both refusable.

**Your wallpaper folder.** macOS shows a standard open panel the first time you import. Diorama
reads that folder and nothing else.

**Audio, only if you turn on audio reactivity.** Some wallpapers react to sound. To let them,
Diorama has to read what your Mac is playing, which macOS gates behind a screen-recording
permission — that is the only mechanism the system provides for capturing audio output, and it
is why the prompt mentions recording. The audio is analysed into a handful of loudness numbers
in memory, passed to the wallpaper's shader, and discarded on the next frame. It is never
written to disk and never leaves the machine.

Audio reactivity is **off by default**. If you never turn it on, Diorama never asks.

## Web wallpapers

Some Wallpaper Engine wallpapers are small web pages. Diorama runs them in a web view with
**all network access blocked**: every request over `http`, `https`, `ws`, `wss` or `ftp` is
refused — pages, stylesheets, fonts, images, scripts, `fetch` and WebSockets alike — and a page
can only read files from its own folder. A web wallpaper cannot phone home, load a tracker, or
fetch a remote image, even if its author wrote it to. A wallpaper that expects the internet (a
music player, a web font) shows without that part, and its compatibility report names the sites
it asked for.

## Children

Diorama does not knowingly collect information from anyone, of any age, because it does not
collect information.

## Changes

If a future version ever sends anything anywhere, this document will say so plainly and before
the fact, and the behaviour will be opt-in. A version that quietly started collecting data while
this file still said otherwise would be a bug worth reporting as one.

## Contact

Open an issue at <https://github.com/aaronkoolkoder/wallpaperapp/issues>.
