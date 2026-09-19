# Legal posture

**Not legal advice.** This is research and a set of working rules, written so the project does
not drift into a position that needs a lawyer. If Diorama is ever sold, funded, or receives a
letter, get one.

Last reviewed: 2026-09-19.

## 1. What the app does, stated precisely

Diorama reads files the user already has, from a folder the user picks, and renders them on the
user's own Mac.

It does **not**:

- bundle, host, mirror, or transmit any Wallpaper Engine file or any Workshop wallpaper;
- download from Steam, log into Steam, or automate a Steam client;
- circumvent any encryption, licence check, DRM, or access control;
- contain any code copied from Wallpaper Engine or from another implementation of it;
- claim to be Wallpaper Engine, or to be endorsed by or affiliated with its developer.

Everything below follows from those five facts, so they are load-bearing rather than decorative.
Breaking one changes the analysis.

## 2. The four questions that actually matter

### 2.1 Is reading the `.pkg` / `.tex` format infringement?

No. A file format is a method of operation, not an expressive work — the same reasoning that
lets any program open a `.zip`. The container here carries no encryption and no access control:
`scene.pkg` is a length-prefixed table of paths and offsets followed by a blob, readable with
twenty lines of Python.

This matters for the DMCA specifically. §1201 prohibits *circumventing a technological measure
that effectively controls access*. There is no such measure to circumvent, so §1201 is not
engaged at all. The interoperability exception at [§1201(f)][1201f] would cover this work even
if there were one, but the project never needs to reach it.

### 2.2 Can a third party display Workshop wallpapers?

The Workshop EULA for app 431960 contemplates exactly this. Creators grant that
*"subscribers of your Steam Workshop content may export and transfer your content to compatible
mobile devices"* and use it *"for the purpose of displaying wallpapers"*, and that submissions
*"may be modified and optimized on the system of individual end-users for the purpose of
enabling technical compatibility"*.

That language is written around the developer's own Android client, so it is context rather than
a licence granted to Diorama. What it does establish is that export to another device, and
adaptation for compatibility on that device, is within what creators agreed to — which is the
activity a user performs with this app. The user is the one who obtained the content and the one
displaying it, privately, on hardware they own.

### 2.3 Has the developer acted against anyone doing this?

No evidence of it, and there are two live examples.

[**linux-wallpaperengine**][linux] has been public on GitHub since 2017, plays Workshop content
on Linux, and reads Wallpaper Engine's own installed assets to do it. No takedown, no notice.

[**Vivid Walls**][vivid] is on the Mac App Store *today*, sells for $9.99, advertises running
*"your Wallpaper Engine library natively on your Mac"* with scenes, shaders and particles, and
ships a Windows companion that copies the library across. Apple approved it; [AppleInsider
covered it][ai]. That is the closest possible precedent — same content, same platform, same
store, commercial — and it is unchallenged.

The developer's own [position on other platforms][help] is that porting is not economically
worthwhile, not that others may not interoperate.

### 2.4 Where is the real exposure?

Trademark, and one specific technical decision.

**Naming.** "Wallpaper Engine" is their mark. Describing compatibility factually is nominative
fair use; implying endorsement is not. This is the most likely source of a letter and the
cheapest to get right — see the rules below.

**Stock shaders.** Materials name built-in shaders (`genericimage2`, and includes like
`common.h`) that ship with Wallpaper Engine, not inside wallpapers. Sixty-one of the shader
references in the first real library tested were to these. There are two ways to supply them and
only one is safe:

- ❌ Bundling Wallpaper Engine's shader source. That is redistributing their copyrighted code.
- ✅ Writing our own implementations against the observed *interface* — the uniform names, combo
  names and blend behaviour a material declares. Names and interfaces are not protected
  expression; the implementation must be ours.

linux-wallpaperengine takes a third route: requiring the user to own Wallpaper Engine and
reading the shaders out of their Steam install. That is also clean, but it is unavailable here —
Wallpaper Engine does not run on macOS, so a Mac user has no install to read.

## 3. Working rules

These are the rules. They are not aspirations.

1. **Never redistribute.** No wallpaper, texture, shader or asset from Wallpaper Engine or the
   Workshop ships with Diorama, appears in this repository, or is uploaded anywhere. The test
   corpus stays out of git (`Tests/Corpus/**` is ignored; real libraries are read in place from
   wherever the user keeps them).
2. **Never copy code.** Not from Wallpaper Engine, and not from GPL-licensed implementations —
   see [THIRD_PARTY.md](THIRD_PARTY.md). Formats are learned from the published spec, from
   MIT-licensed `repkg`, and from observing bytes.
3. **Write stock shaders ourselves**, from the interface only, and say so in the source.
4. **Name it carefully.** The app is "Diorama". Compatibility is stated as a fact —
   *"plays wallpapers made for Wallpaper Engine"* — never as a name, never as a badge, never
   with their logo, and never "Wallpaper Engine for Mac". No metadata, keyword, or screenshot
   that implies affiliation. Carry a disclaimer: *not affiliated with or endorsed by the
   Wallpaper Engine developer.*
5. **Don't touch Steam.** No downloading, no scraping, no automating the client, no credentials.
   The user points the app at a folder they already have.
6. **Keep it local.** No telemetry, no uploads, no accounts. This is also the privacy promise —
   see [PRIVACY.md](PRIVACY.md) — and it removes the question of whether the app ever *handles*
   anyone's content off-device. It does not.
7. **Application wallpapers stay unsupported.** They are Windows executables; the Workshop
   [removed them in 2026][apps] over malware. Diorama reports them as unsupported by design.

## 4. What is still open

- The Workshop EULA's export language is written for the developer's own mobile client. It is
  persuasive context, not a licence to us. The user's position is solid; Diorama's is
  "we are a tool the user runs on their own files", which is the same position as a media player.
- Creators own their wallpapers, and many contain third-party IP (anime frames, game art,
  music). Diorama never redistributes any of it, so the exposure stays with whoever uploaded it.
- Trademark tolerance can change without the law changing. If a letter arrives, the answer is
  almost certainly a naming change, not a shutdown — which is why rule 4 keeps the name
  separable from the product.

[1201f]: https://www.law.cornell.edu/uscode/text/17/1201
[linux]: https://github.com/Almamu/linux-wallpaperengine
[vivid]: https://apps.apple.com/us/app/vivid-walls-live-wallpapers/id6761993729
[ai]: https://appleinsider.com/inside/macos-27/tips/there-is-a-way-to-run-wallpaper-engine-files-on-mac-with-caveats
[help]: https://help.wallpaperengine.io/en/functionality/linuxmacos.html
[apps]: https://www.gamespot.com/articles/popular-steam-wallpaper-program-removes-app-over-malware-concerns/
