# Nagual Strip

Floating workspace switcher with workspace cards, window list, settings, and smart app launcher.

## Features

- **Workspace strip (bottom-center)** - Centered on focused screen with live workspace previews.
- **Right-click workspace card** - Opens mini menu listing all windows in that workspace. Left-click a window name to focus workspace and that window. Right-click a window name to close it.
- **Right-click strip background** - Opens configuration (only on empty background, not on icons/cards).
- **Auto-hide** - Hides by default; hovering bottom-center edge shows it. Works standalone.
- **Pinned mode** - Set `wsToggleEnabled: false` to keep it always visible.
- **Instant switches** - Click workspace card switches without animation when enabled.
- **Smart app grid** - MRU-ranked app launcher from leftmost button.
- **Bottom reserve** - Reserves space so maximized windows clear the strip.

## Installation

```sh
omarchy plugin add https://github.com/nagualcode/omarchy-nagualstrip.git --enable
omarchy restart shell
```
