# 🔲 Nagual Strip

> The floating workspace switcher, its settings and its app grid — finally on
> their own.

**Nagual Strip** is the workspace half that was split out of
[Speaker Corners](https://github.com/nagualcode/omarchy-speakercorners): one
masked, click-through overlay holding the workspace cards (bottom-center), the
right-click configuration popup, the smart MRU-ranked app grid and an opt-in
bottom hover edge. Hot corners, the icon panel and the embedded workspace
overview stayed behind in Speaker Corners.

![izi](https://img.shields.io/badge/omarchy-ready-blueviolet)
![hyprland](https://img.shields.io/badge/hyprland-native-2ea44f)

![preview](preview.jpg)
---

## 🎯 What it does

- **🌆 Floating workspace strip (bottom-center)** — always centred on the
  focused screen. Each card is a live preview whose app icons fill the cell (a
  single app gets the whole tile, macOS-Dock style), plus an urgent dot in the
  corner and a `+` to mint a new workspace. A small triangle at the strip's base
  points up at the active workspace; hovering turns it into an **×** that closes
  the workspace (every window on it), and while it points at the empty/new
  workspace there is nothing to close, so it stays a plain triangle.
  - **Instant switches** — clicking a card suppresses Hyprland's animations just
    long enough for the compositor to warp the switch into place
    (`wsInstantSwitch`, on by default). Every other workspace change — touchpad
    gesture, keybind, the `+` button — keeps the animated macOS-style
    transition from `~/.config/hypr/looknfeel.lua`.
  - **It steps aside** while a window on the focused monitor is fullscreen, and
    while the Omarchy screensaver blackout is up; a pinned strip comes back
    when either goes away.
  - **Real icons only** — workspace cards always render the actual, full-color
    app icon; there is no generic glyph fallback
    (`wsStripRealIcons` is always on).
  - **Auto-hide or pinned** — `wsAutoHide` shows it for a dwell after a
    workspace change; switching the bottom-center toggle off
    (`wsToggleEnabled: false`) pins it on screen from the start.
  - **Optional neon glow** — `wsNeonEnabled` cycles the strip outline and the
    apps glyph through the Neonmarchy palette (`#5BC5AA → #B272E1 → #72B6E1`).
- **🎛️ Right-click configuration** — the strip background opens a popup with
  live sliders for **Size**, **Opacity**, **Gap** (cards) and **Bottom gap**,
  plus toggles for auto-hide, instant switch, neon, the launcher cells and the
  app-grid rows. Everything is written to `shell.json` on release; a short idle
  closes the popup by itself.
- **🧲 Smart app grid** — the apps cell at the left of the strip opens a
  launcher of its own, built from the same app library the Omarchy menu uses,
  so it lists every app the menu lists. Six square cells per row with big icons
  and the name underneath, parked just above the strip.
  **The apps you actually use float to the front**: most recently opened first,
  ties broken by how often you have opened it, never-opened apps alphabetically.
  Typing filters with the same fuzzy search the Omarchy menu uses (ranking is
  left alone while you type). Arrows move (and wrap), `Enter` launches, `Esc`
  clears the search and then closes, `PageUp`/`PageDown`/`Home`/`End` scroll,
  the wheel scrolls, and clicking outside dismisses it. Raise `appMenuRows`
  (1–6) for a taller grid, which grows upward so it never covers the strip.
- **⬇️ Opt-in bottom hover edge** (`wsEdgeEnabled`) — a thin strip along the
  bottom edge that re-summons the strip on hover.

---

## 🤝 Works with Speaker Corners

The two plugins draw two separate always-mapped Overlay windows, so they
coordinate over IPC instead of relying on layer stacking order (which Hyprland
does not guarantee between surfaces):

| Speaker Corners does…                                   | Nagual Strip reacts |
| ------------------------------------------------------- | ------------------- |
| bottom-left corner / `toggle-hide-chrome`               | `nagualstrip setchrome on\|off` — hides, then flashes back on a workspace switch |
| opening the icon panel                                  | `nagualstrip suspend` — closes the app grid, hides, remembers visibility |
| closing the icon panel                                  | `nagualstrip resume` — restores exactly what was on screen |
| bottom-center corner (default command)                  | `omarchy-shell workspace-overview toggle` (a legacy target kept here) |

Install **both** to keep the pre-split behaviour: with only Speaker Corners the
bottom-center corner still runs its command, it simply has no strip to talk to.

---

## 📦 Installation

```sh
omarchy plugin add https://github.com/nagualcode/omarchy-nagualstrip.git --enable
omarchy restart shell
```

### Upgrading from the merged Speaker Corners

```sh
omarchy plugin add https://github.com/nagualcode/omarchy-nagualstrip.git --enable
# keep your app-grid ranking
mkdir -p "${XDG_STATE_HOME:-~/.local/state}" \
  && mv "${XDG_STATE_HOME:-~/.local/state}/speakercorners" \
        "${XDG_STATE_HOME:-~/.local/state}/nagualstrip" 2>/dev/null
omarchy restart shell
```

## Removal

```sh
omarchy plugin remove nagualcode.nagualstrip
```

---

## ⚙️ Configuration

Settings live in a `plugins` entry in `~/.config/omarchy/shell.json`. Reads
accept the entry with id `nagualcode.nagualstrip`, then `nagualstrip`, then the
legacy `speakercorners` entry (so an unmigrated config keeps working); writes
always go to `nagualcode.nagualstrip`. Every key is optional and falls back to
a default, so the minimum entry is just `{ "id": "nagualcode.nagualstrip" }`.

```jsonc
{
  "id": "nagualcode.nagualstrip",
  "enabled": true,
  "animations": true,      // false to drop the slide to 0ms (pop in/out)
  "wsScale": 1.0,          // card size multiplier (0.5–2.0)
  "wsOpacity": 0.97,       // strip surface opacity (0.1–1.0)
  "wsStripGap": 21,        // gap between the strip and the screen bottom
  "wsGap": 10,             // gap between cards
  "wsAutoHide": true,      // show on a workspace change, hide after a dwell
  "wsToggleEnabled": true, // bottom-center hot corner arms the strip
  "wsInstantSwitch": true, // card clicks switch with no animation
  "wsShowAppMenu": true,   // apps launcher cell
  "wsShowOmafile": true,   // file manager cell
  "wsShowNewWs": true,     // "+" cell
  "wsStripRealIcons": true,// always real, full-color app icons
  "wsNeonEnabled": false,  // cycling neon outline
  "appMenuRows": 1,        // rows of icons in the smart app grid (1–6)
  "wsEdgeEnabled": false   // thin hover edge along the screen bottom
}
```

> **Pinned strip.** `wsToggleEnabled: false` disables the bottom-center hot
> corner and pins the strip on screen: it no longer waits for a pointer trigger
> and no longer auto-hides. Speaker Corners reads the same key, so its
> bottom-center corner stays inert while the strip is pinned.

### Bottom reserved area

Maximized ("▲") windows must stop above the strip. The plugin writes the needed
space to `~/.config/omarchy/.nagualstrip-reserve` (and reloads Hyprland) on
every size change; `~/.config/hypr/monitors.lua` reads it:

```lua
-- Bottom reserved area keeps maximized ("▲") windows above the workspace strip.
local stripReservePath = os.getenv("HOME") .. "/.config/omarchy/.nagualstrip-reserve"
local stripReserveFile = io.open(stripReservePath, "r")
local stripBottom = stripReserveFile and tonumber(stripReserveFile:read("*a")) or 0
if stripReserveFile then stripReserveFile:close() end
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale,
             reserved_area = { top = 0, right = 0, bottom = stripBottom > 0 and stripBottom or 0, left = 0 } })
```

The file holds `0` while the strip is hidden by `setchrome on`, so windows
reclaim the space instead of leaving a dead band.

---

## 📡 IPC

```sh
omarchy-shell nagualstrip toggle
omarchy-shell nagualstrip state
omarchy-shell nagualstrip-apps toggle
```

| Target                    | Methods                                                   |
| ------------------------- | --------------------------------------------------------- |
| `nagualstrip`             | `open` `close` `toggle` `state` `suspend` `resume` `setchrome <on\|off>` |
| `workspace-overview`      | `open` `close` `toggle` `state` (legacy — Speaker Corners' bottom-center default) |
| `nagualstrip-apps`        | `open` `close` `toggle` `state`                           |
| `speakercorners-apps`     | `open` `close` `toggle` `state` (legacy keybindings)      |

`suspend`/`resume` and `setchrome` are called by Speaker Corners; you rarely
need them by hand.

---

## 🦾 Requirements

- **Omarchy** (shell + `omarchy-shell` IPC)
- **Hyprland** (native `WlrLayershell` + Hyprland IPC)
- A **Nerd Font** on the system (default: `JetBrainsMono Nerd Font`) for the
  cell glyphs
- **Font Awesome 7 Free** (shipped with Omarchy) for the app-grid launcher icon

## 🧱 Roof tiles

- `NagualStrip.qml` — model, geometry, reserve sidecar, IPC and the single
  masked window
- `AppLauncherMenu.qml` — the smart app grid (search, square cells, keynav)
- `AppUsage.js` — app ranking model (most recent first) + JSON persistence
- `AppSearchShim.js` — fuzzy search shared with the Omarchy menu
- `IconModel.js` — app icon resolution for the workspace cards (a faithful
  subset of Omarchy's HUD model)
- `Workspaces.js` — Hyprland → plain-JS workspace model builder

State lives in `${XDG_STATE_HOME:-~/.local/state}/nagualstrip/app-usage.json`
(max 400 apps).

## 🚗 License

MIT — take the strip. 🛹
