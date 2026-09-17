"""Write the installer window's layout straight into a .DS_Store.

Finder stores window geometry, background and icon positions in .DS_Store. Every common DMG
recipe gets those there by driving Finder over AppleScript, which needs Automation permission —
a prompt on a developer machine, and a hang in CI where there is nobody to approve it. Writing
the file directly avoids the permission entirely and works headlessly.
"""

import os
import struct
import sys

import mac_alias.alias
from ds_store import DSStore
from mac_alias import Alias


def _patch_mac_alias() -> None:
    """Allow CNIDs that do not fit in 32 bits.

    `mac_alias` packs the CNID path as unsigned 32-bit integers, which APFS outgrew — on any
    modern volume `Alias.for_file` raises `struct.error` before it can produce anything. Finder
    resolves the background by path anyway when the CNID chain does not match, so clamping the
    oversized entries yields an alias it still accepts rather than no alias at all.
    """
    original = mac_alias.alias.Alias._to_fd

    def patched(self, fd):
        if getattr(self.target, "cnid_path", None):
            self.target.cnid_path = tuple(
                min(int(cnid), 0xFFFFFFFF) for cnid in self.target.cnid_path
            )
        return original(self, fd)

    mac_alias.alias.Alias._to_fd = patched


_patch_mac_alias()

# Must agree with the arrow drawn in make-dmg-background.swift. Finder's origin is top-left.
WINDOW = (140, 120, 800, 540)          # left, top, right, bottom
ICON_POSITIONS = {
    "Diorama.app": (172, 188),
    "Applications": (488, 188),
}
ICON_SIZE = 128


def main(staging: str) -> None:
    background = os.path.join(staging, ".background", "background.png")
    if not os.path.exists(background):
        raise SystemExit(f"missing background: {background}")

    try:
        background_alias = Alias.for_file(background).to_bytes()
        background_type = 2                      # picture
    except Exception as error:                   # noqa: BLE001 - any alias failure is survivable
        # A solid fill still gives a proper installer window with the icons where they belong;
        # only the arrow art is lost. Far better than failing the build over decoration.
        print(f"  background image unavailable ({error}); falling back to a solid fill")
        background_alias = None
        background_type = 1                      # colour

    store_path = os.path.join(staging, ".DS_Store")
    with DSStore.open(store_path, "w+") as store:
        store["."]["vSrn"] = ("long", 1)
        store["."]["bwsp"] = {
            "WindowBounds": f"{{{{{WINDOW[0]}, {WINDOW[1]}}}, "
                            f"{{{WINDOW[2] - WINDOW[0]}, {WINDOW[3] - WINDOW[1]}}}}}",
            "ShowStatusBar": False,
            "ShowTabView": False,
            "ShowPathbar": False,
            "ShowSidebar": False,
            "ShowToolbar": False,
        }
        view_options = {
            "viewOptionsVersion": 1,
            "backgroundType": background_type,
            "iconSize": float(ICON_SIZE),
            "gridSpacing": 100.0,
            "gridOffsetX": 0.0,
            "gridOffsetY": 0.0,
            "textSize": 13.0,
            "labelOnBottom": True,
            "showItemInfo": False,
            "showIconPreview": True,
            "arrangeBy": "none",
        }
        if background_alias is not None:
            view_options["backgroundImageAlias"] = background_alias
        else:
            # Matches the top of the gradient the artwork would have used.
            view_options["backgroundColorRed"] = 0.071
            view_options["backgroundColorGreen"] = 0.071
            view_options["backgroundColorBlue"] = 0.078
        store["."]["icvp"] = view_options

        for name, (x, y) in ICON_POSITIONS.items():
            store[name]["Iloc"] = (x, y)

    print(f"  wrote layout: {ICON_SIZE}pt icons, window {WINDOW[2] - WINDOW[0]}"
          f"x{WINDOW[3] - WINDOW[1]}")


if __name__ == "__main__":
    main(sys.argv[1])
