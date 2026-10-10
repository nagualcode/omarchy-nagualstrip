# Nagual Strip

Floating workspace switcher with workspace cards, window list, settings, and smart app launcher.

## Features

- **Workspace strip (bottom-center)** - Centered on focused screen with live workspace previews.
- **Right-click workspace card** - Opens mini menu listing all windows in that workspace. Left-click a window name to focus workspace and that window. Right-click a window name to close it.
- **Right-click strip background** - Opens configuration (only on empty background, not on icons/cards).
- **Auto-hide** - Hides by default; hovering bottom-center edge shows it. Works standalone.
- **Pinned mode** - Set `wsToggleEnabled: false` to keep it always visible.
- **Instant switches** - Click workspace card switches without animation when enabled.
- **Drag to reorder** - Drag a workspace card to reshuffle the strip. The underlying Hyprland IDs are reassigned so `Super+N` (`N` = Nth card) matches the new left-to-right order, using the smallest set of renames.
- **No empty cards** - Only workspaces that hold windows are drawn. Stale "ghost" workspaces left in Quickshell's model by a rename (`change_id`) are filtered out using Hyprland's own occupancy.
- **Smart app grid** - MRU-ranked app launcher from leftmost button.
- **Bottom reserve** - Reserves space so maximized windows clear the strip.

## Workspace reordering

Drag any workspace card left or right and the strip reshuffles live. On drop, the
new order is written back to Hyprland by renaming workspace IDs, so the keybind
(`Super+N` for the Nth card) keeps matching what you see:

- Hyprland renames a workspace's ID in place, so windows, tiling and focus ride
  along — nothing is moved or re-tiled.
- The planner keeps as many workspaces on their current ID as possible, so a
  single drag usually only touches the cards involved.
- Workspaces squatting on a target ID are parked on a temporary high ID first,
  so a rename never collides with an ID in use.
- Special (negative) workspaces are not reorderable.

While a rename settles the strip holds its layout, then reconciles against
Hyprland's real occupancy so an empty card can never be painted.

## Installation

```sh
omarchy plugin add https://github.com/nagualcode/omarchy-nagualstrip.git --enable
omarchy restart shell
```
