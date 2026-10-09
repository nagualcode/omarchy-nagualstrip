import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Networking
import Quickshell.Bluetooth
import Quickshell.Services.UPower
import qs.Commons
import qs.Ui
import "Workspaces.js" as WorkspaceModel
import "IconModel.js" as IconModel

// Nagual Strip — the floating workspace switcher.
//
// One always-mapped fullscreen Overlay window holds:
//   * the workspace cards strip (bottom-center, centered)
//   * the right-click configuration popup
//   * the smart app grid the launcher cell opens
//   * the optional bottom hover edge
// The window's `mask` only admits input where something interactive lives,
// so the desktop stays fully click-through everywhere else.
//
// This surface used to live inside nagualcode.speakercorners (hot corners).
// The two plugins coordinate over IPC:
//   * speakercorners' bottom-left corner runs
//       omarchy-shell -q nagualstrip setchrome on|off
//   * opening/closing its icon panel runs
//       omarchy-shell -q nagualstrip suspend|resume
//   * its bottom-center corner runs the default command
//       omarchy-shell workspace-overview toggle
//     (a legacy IPC target kept here for compatibility)
//
// Configuration lives in shell.json in the plugin's own entry:
//   "plugins": [
//     { "id": "nagualcode.nagualstrip",
//       "wsScale": 1.0, "wsOpacity": 0.97, "wsGap": 10, "wsStripGap": 21,
//       "wsAutoHide": true, "wsToggleEnabled": true, "wsInstantSwitch": true,
//       "wsShowAppMenu": true, "wsShowOmafile": true, "wsShowNewWs": true,
//       "wsStripRealIcons": true, "wsNeonEnabled": false, "appMenuRows": 1,
//       "wsEdgeEnabled": false, "animations": true }
//   ]
//
// The bottom reserved area (so maximized windows clear the strip) is written
// to ~/.config/omarchy/.nagualstrip-reserve and read by monitors.lua:
//   local strip_reserve = tonumber(read_file(".../.nagualstrip-reserve")) or 0
//
Item {
  id: root

  // Injected by the shell panel loader.
  property var shell: null
  property var manifest: null
  property var barWidgetRegistry: null
  property var pluginRegistry: null
  property string omarchyPath: ""

  // ---- Per-surface open state -------------------------------------------
  property bool workspacesOpened: false
  // The smart app menu the strip's launcher cell opens. Kept out of `opened`
  // on purpose: it is summoned by a cell inside the strip, so a generic
  // `nagualstrip toggle` must not treat it as one of the two corner surfaces
  // and close it out from under a click.
  property bool appMenuOpened: false
  // Kept alive during the closing slide so the rise is visible; cleared by the
  // slide-out timer once the play-out ends.
  property bool wsSliding: false

  readonly property bool anyOpen: root.workspacesOpened || root.appMenuOpened
  // The shell's isPluginOpen() reads `opened` off the loaded item.
  readonly property bool opened: root.anyOpen
  // Only the app grid is typed into, so it is the only surface that takes
  // the window's keyboard focus; the strip just swallows clicks via the mask.
  readonly property bool keysWanted: root.appMenuOpened

  readonly property var appLibrary: root.shell
    ? (root.shell.appLibrary || (typeof root.shell.n === "object" ? root.shell.n : null))
    : null

  // ---- Hot-panel settings (read from the plugins[] entry) ---------------
  property var pluginSettings: ({})
  property bool configLoaded: false

  // Slide animation for the inline panels (strip + configuration popup).
  // Users can disable it via the "animations" setting in shell.json; the slide
  // drops to 0ms when off so panels pop in/out instantly.
  property bool animationsEnabled: true
  property int panelAnimMs: 120
  readonly property int effectivePanelAnimMs: root.animationsEnabled ? root.panelAnimMs : 0

  // Workspaces strip look & behaviour, persisted in the plugin's shell.json
  // entry and adjustable from the right-click configuration popup.
  property real wsScale: 1.0
  property real wsOpacity: 0.97
  property bool wsAutoHide: true
  property bool wsToggleEnabled: true
  // Vertically centered spacers around the strip: this gap is kept equal
  // between the strip and the screen bottom and between the strip and the
  // windows (the bottom reserved area is stripHeight + 2*gap). Default is the
  // previous bottom margin reduced by 5% (22 -> ~21px), tuned from the
  // settings popup slider.
  readonly property int wsStripGapDefault: Math.max(2, Math.round(Style.space(22) * 0.95))
  property int wsStripGap: wsStripGapDefault
  // Workspace cards always render the real (colorful) app icon image. The
  // flat-colored Nerd Font glyph / monochrome tint is disabled and there is no
  // generic glyph fallback: only real app icons are ever shown.
  property bool wsStripRealIcons: true
  // Launcher cells of the strip: the apps-menu button, the omafile (file
  // manager) button and the new-workspace "+" button. All shown by default;
  // each can be hidden from the strip's right-click config popup.
  property bool wsShowAppMenu: true
  property bool wsShowOmafile: true
  property bool wsShowNewWs: true
  property int appMenuRows: 1
  // Clicking a workspace card lands with no transition at all: the strip
  // suppresses Hyprland's animations just long enough for the switch to warp
  // into place. Every other workspace change (touchpad gesture, keybind, the
  // "+" button) keeps the animated macOS-style transition.
  property bool wsInstantSwitch: true
  // Disabling the bottom-center toggle pins the strip on screen: it no longer
  // waits for a mouse trigger to appear and no longer auto-hides.
  readonly property bool wsAlwaysVisible: !root.wsToggleEnabled
  onWsToggleEnabledChanged: {
    if (root.wsAlwaysVisible && root.configLoaded) root.showWorkspaces()
  }

  function setting(key, fallback) {
    var value = root.pluginSettings[key]
    return value === undefined || value === null ? fallback : value
  }

  // ---- Reactive: focused monitor for the strip --------------------------
  // Reactive: focused monitor for the window.
  readonly property var activeScreen: {
    var mon = Hyprland.focusedMonitor
    var name = mon ? String(mon.name || "") : ""
    var screens = Quickshell.screens
    if (name.length > 0) {
      for (var i = 0; i < screens.length; i++) {
        if (String(screens[i].name || "") === name) return screens[i]
      }
    }
    return screens.length > 0 ? screens[0] : null
  }

  // ---- Shared look tokens (same values the icon panel card uses) -------
  readonly property int cornerRadius: Style.cornerRadius
  readonly property string fontFamily: Style.font.family

  // Same lookup speakercorners uses: own entry first, then the legacy ids,
  // so an unmigrated config still drives the strip.
  function findStripSettings(list) {
    if (!Array.isArray(list)) return null
    var ids = ["nagualcode.nagualstrip", "nagualstrip", "speakercorners"]
    for (var k = 0; k < ids.length; k++) {
      for (var i = 0; i < list.length; i++) {
        if (list[i] && String(list[i].id) === ids[k]) return list[i]
      }
    }
    return null
  }

  function readConfig() {
    var list = root.userShellConfig.plugins
    if (!Array.isArray(list) && shell && shell.shellConfig && Array.isArray(shell.shellConfig.plugins))
      list = shell.shellConfig.plugins
    var cfg = root.findStripSettings(list) || ({})
    root.pluginSettings = cfg
    root.animationsEnabled = setting("animations", true) !== false
    root.wsScale = Math.max(0.5, Math.min(2.0, Number(setting("wsScale", 1.0) || 1.0)))
    root.wsOpacity = Math.max(0.1, Math.min(1.0, Number(setting("wsOpacity", 0.97) || 0.97)))
    root.wsAutoHide = setting("wsAutoHide", true) !== false
    root.wsToggleEnabled = setting("wsToggleEnabled", true) !== false
    root.wsCardGap = Math.max(0, Math.min(Style.space(64), Number(setting("wsGap", Style.space(10)) || Style.space(10))))
    root.wsStripGap = Math.max(0, Math.min(Style.space(64), Number(setting("wsStripGap", root.wsStripGapDefault) || root.wsStripGapDefault)))
    root.wsStripRealIcons = true
    root.wsShowAppMenu = setting("wsShowAppMenu", true) !== false
    root.wsShowOmafile = setting("wsShowOmafile", true) !== false
    root.wsShowNewWs = setting("wsShowNewWs", true) !== false
    root.appMenuRows = Math.max(1, Math.min(6, Number(setting("appMenuRows", 1) || 1)))
    root.wsInstantSwitch = setting("wsInstantSwitch", true) !== false
    root.wsNeonEnabled = setting("wsNeonEnabled", false) !== false
    root.wsEdgeEnabled = setting("wsEdgeEnabled", false) !== false
    root.configLoaded = true
  }

  // Reads the plugin's own entry straight from ~/.config/omarchy/shell.json.
  // The injected shell facade has no shell.shellConfig, so without this the
  // plugin would only ever see defaults.
  readonly property string userConfigPath: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
  property var userShellConfig: ({})
  function parseUserConfig(text) {
    try {
      var parsed = JSON.parse(String(text || ""))
      return Util.isPlainObject(parsed) ? parsed : ({})
    } catch (e) { return ({}) }
  }
  FileView {
    id: userShellFile
    path: root.userConfigPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      var str = String(text() || "")
      // Ignore the echo of our own persistWorkspaceSettings write.
      if (str !== "" && str === root.lastWrittenShellText) return
      root.userShellConfig = root.parseUserConfig(str)
      if (root.configLoaded) root.readConfig()
    }
    onLoadFailed: root.userShellConfig = ({})
  }
  // Content we last pushed via persistWorkspaceSettings (see the onLoaded guard).
  property string lastWrittenShellText: ""

  // ========================================================================
  //  Hot-corner hand-off: the strip steps aside for the icon panel
  // ========================================================================
  // speakercorners owns the "chrome" gesture (strip + menu bar). It asks this
  // plugin to hide or come back; the strip keeps its own auto-hide rules and
  // its brief flash on a workspace switch while hidden.
  property bool chromeHidden: false

  function setChromeHidden(on) {
    on = !!on
    if (root.chromeHidden === on) return
    root.chromeHidden = on
    if (on) {
      chromeFlashTimer.stop()
      root.hideWorkspaces()
    } else {
      root.showWorkspaces()
    }
  }

  // Brief strip appearance on a workspace switch while everything is hidden.
  function briefWorkspaceFlash() {
    root.showWorkspaces()
    if (!root.wsAutoHide) chromeFlashTimer.start()
  }

  Timer {
    id: chromeFlashTimer
    interval: 1400
    onTriggered: { if (root.chromeHidden) root.hideWorkspaces() }
  }

  // ========================================================================
  //  Suspension while the icon panel of nagualcode.speakercorners is up
  // ========================================================================
  // Both plugins draw an always-mapped Overlay window; rather than relying on
  // layer stacking order (which Hyprland does not guarantee across surfaces),
  // the strip steps aside completely while the panel is open and comes back
  // exactly as it was when the panel closes.
  property bool suspended: false
  property bool shownBeforeSuspend: false

  function suspend() {
    if (root.suspended) return
    var was = root.workspacesOpened
    root.suspended = true
    root.closeAppMenu()
    root.hideWorkspaces()
    root.shownBeforeSuspend = was
  }

  function resume() {
    if (!root.suspended) return
    root.suspended = false
    var was = root.shownBeforeSuspend
    root.shownBeforeSuspend = false
    if (was) root.showWorkspaces()
  }

  // ---- Workspace close (strip arrow) ------------------------------------
  // The triangle marker under the active workspace card doubles as its close
  // button: hovering turns it into an "×" and clicking closes every window on
  // the active workspace, emptying it off the strip. Windows are collected via
  // hyprctl -j clients first, then each one is dispatched individually (the
  // Lua dispatchers act on one window at a time, addressed explicitly).
  property int wsCloseTarget: -1

  function closeWorkspace(wsId) {
    root.wsCloseTarget = Number(wsId)
    if (!isFinite(root.wsCloseTarget)) return
    wsCloseProc.running = true
  }

  Process {
    id: wsCloseProc
    command: ["hyprctl", "-j", "clients"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyWsClose(text)
    }
  }

  function applyWsClose(text) {
    var wsId = root.wsCloseTarget
    root.wsCloseTarget = -1
    if (!isFinite(wsId)) return
    var list = []
    try { list = JSON.parse(text || "[]") } catch (e) { return }
    if (!Array.isArray(list)) return
    var addrs = []
    for (var i = 0; i < list.length; i++) {
      var c = list[i]
      if (!c || c.mapped === false || c.hidden === true) continue
      if (!c.workspace || Number(c.workspace.id) !== wsId) continue
      var addr = String(c.address || "")
      if (/^0x[0-9a-fA-F]+$/.test(addr)) addrs.push(addr)
    }
    for (var j = 0; j < addrs.length; j++) {
      var expr = 'hl.dsp.window.close({ window = "address:' + addrs[j] + '" })'
      Quickshell.execDetached(["hyprctl", "dispatch", expr])
    }
  }

  function focusWindowByAddress(addr) {
    var expr = 'hl.dsp.focus({ window = "address:' + String(addr || "") + '" })'
    Quickshell.execDetached(["hyprctl", "dispatch", expr])
  }

  function closeWindowByAddress(addr) {
    var expr = 'hl.dsp.window.close({ window = "address:' + String(addr || "") + '" })'
    Quickshell.execDetached(["hyprctl", "dispatch", expr])
  }

  // ========================================================================
  //  NEON GLOW (workspace strip)
  // ========================================================================
  // When enabled, the strip outline and the apps-menu glyph cycle through the
  // same three colors as the Neonmarchy plugin (CSS `acid 5s linear infinite`):
  // #5BC5AA -> #B272E1 -> #72B6E1, sampled smoothly around the clock by a
  // lightweight in-QML Timer (no hyprctl, no config writes).
  property bool wsNeonEnabled: false
  property color wsNeonGlow: Color.accent
  property string neonColorA: "#5BC5AA"
  property string neonColorB: "#B272E1"
  property string neonColorC: "#72B6E1"
  property int neonCycleMs: 5000
  property int neonTickMs: 50

  // Live theme colors the strip draws with, swapped for the neon glow while
  // the effect is on.
  readonly property color wsStripAccent: root.wsNeonEnabled ? root.wsNeonGlow : Color.accent
  readonly property color wsStripBorder: root.wsNeonEnabled ? root.wsNeonGlow : Color.popups.border

  function neonHex2(v) {
    var s = Math.max(0, Math.min(255, Math.round(v))).toString(16)
    return s.length < 2 ? "0" + s : s
  }

  function neonParseHex(hex) {
    return {
      r: parseInt(hex.slice(1, 3), 16),
      g: parseInt(hex.slice(3, 5), 16),
      b: parseInt(hex.slice(5, 7), 16)
    }
  }

  function neonLerpHex(a, b, t) {
    return root.neonHex2(a.r + (b.r - a.r) * t)
      + root.neonHex2(a.g + (b.g - a.g) * t)
      + root.neonHex2(a.b + (b.b - a.b) * t)
  }

  function neonColorAt(nowMs) {
    var a = root.neonParseHex(root.neonColorA)
    var b = root.neonParseHex(root.neonColorB)
    var c = root.neonParseHex(root.neonColorC)
    var t = (nowMs % root.neonCycleMs) / root.neonCycleMs
    if (t < 1 / 3)      return root.neonLerpHex(a, b, t * 3)
    if (t < 2 / 3)      return root.neonLerpHex(b, c, (t - 1 / 3) * 3)
    return root.neonLerpHex(c, a, (t - 2 / 3) * 3)
  }

  function neonTick() {
    if (!root.wsNeonEnabled) return
    var c = root.neonColorAt(Date.now())
    root.wsNeonGlow = Qt.rgba(
      parseInt(c.substr(0, 2), 16) / 255,
      parseInt(c.substr(2, 2), 16) / 255,
      parseInt(c.substr(4, 2), 16) / 255, 1)
  }

  Timer {
    id: neonTimer
    interval: root.neonTickMs
    repeat: true
    running: root.wsNeonEnabled
    onTriggered: root.neonTick()
  }

  // ---- Workspaces mini menu for windows in workspace ---------------------
  property bool wsWindowMenuOpen: false
  property var wsWindowMenuWs: null
  property int wsWindowMenuX: 0
  property int wsWindowMenuY: 0

  function openWsWindowMenu(ws, mouse) {
    root.wsWindowMenuWs = ws
    root.wsWindowMenuOpen = true
    if (mouse) {
      var x = mouse.x - wsWindowMenuW / 2
      var y = mouse.y - 20
      root.wsWindowMenuX = Math.max(0, Math.min(panel.width - root.wsWindowMenuW, x))
      root.wsWindowMenuY = Math.max(0, Math.min(panel.height - Math.min(wsWindowMenuH, Style.space(260)) - 10, y))
    }
    wsWindowMenuPeel.restart()
  }

  function closeWsWindowMenu() {
    if (!root.wsWindowMenuOpen) return
    root.wsWindowMenuOpen = false
    root.wsWindowMenuWs = null
    wsWindowMenuPeel.stop()
    root.restartWorkspacesHideTimer()
  }

  function dismissWsWindowMenu() {
    root.closeWsWindowMenu()
  }

  Timer {
    id: wsWindowMenuPeel
    interval: 6000
    repeat: false
    onTriggered: root.closeWsWindowMenu()
  }

  readonly property int wsWindowMenuW: Style.space(280)
  readonly property int wsWindowMenuH: Style.space(200)

  // ---- Workspaces configuration popup ------------------------------------
  // Opened by right-clicking the strip background. The sliders apply live and
  // commit to shell.json on release (same write path as grid reordering).
  property bool wsConfigOpen: false

  function toggleWsConfig() { root.wsConfigOpen ? root.closeWsConfig() : root.openWsConfig() }

  function openWsConfig() {
    root.closeWsWindowMenu()
    root.wsConfigOpen = true
    wsConfigPeel.restart()
  }

  function closeWsConfig() {
    if (!root.wsConfigOpen) return
    root.wsConfigOpen = false
    wsConfigPeel.stop()
    root.persistWorkspaceSettings()
    root.restartWorkspacesHideTimer()
  }

  // A click anywhere outside the popup dismisses it: settings are already
  // live and persisted, so no shell restart is needed.
  function dismissWsConfig() {
    if (!root.wsConfigOpen) return
    root.closeWsConfig()
  }

  Timer {
    // Close the popup after a short idle so it cannot sit on screen forever.
    id: wsConfigPeel
    interval: 8000
    repeat: false
    onTriggered: root.closeWsConfig()
  }

  readonly property int wsConfigPopupW: Style.space(260)
  // Tall enough for the title, four sliders and every toggle row, including
  // "Instant switch".
  readonly property int wsConfigPopupH: Style.space(538)
  readonly property int wsConfigPopupX: Math.max(0, Math.round(root.stripX + (root.stripW - root.wsConfigPopupW) / 2))
  readonly property int wsConfigPopupY: Math.max(0, root.stripY - root.wsConfigPopupH - Style.space(12))

  function persistWorkspaceSettings() {
    var payload = JSON.stringify(root.withWorkspaceSettings(), null, 2) + "\n"
    root.lastWrittenShellText = payload
    userShellFile.setText(payload)
  }

  function withWorkspaceSettings() {
    var cfg = root.parseUserConfig(userShellFile.text())
    if (!Array.isArray(cfg.plugins)) cfg.plugins = []
    var found = false
    for (var i = 0; i < cfg.plugins.length; i++) {
      if (cfg.plugins[i] && String(cfg.plugins[i].id) === "nagualcode.nagualstrip") {
        cfg.plugins[i].wsScale = Math.round(root.wsScale * 100) / 100
        cfg.plugins[i].wsOpacity = Math.round(root.wsOpacity * 100) / 100
        cfg.plugins[i].wsAutoHide = root.wsAutoHide === true
        cfg.plugins[i].wsToggleEnabled = root.wsToggleEnabled === true
        cfg.plugins[i].wsGap = Math.round(root.wsCardGap)
        cfg.plugins[i].wsStripGap = Math.round(root.wsStripGap)
        cfg.plugins[i].wsStripRealIcons = root.wsStripRealIcons === true
        cfg.plugins[i].wsShowAppMenu = root.wsShowAppMenu === true
        cfg.plugins[i].wsShowOmafile = root.wsShowOmafile === true
        cfg.plugins[i].wsShowNewWs = root.wsShowNewWs === true
        cfg.plugins[i].wsInstantSwitch = root.wsInstantSwitch === true
        cfg.plugins[i].wsNeonEnabled = root.wsNeonEnabled === true
        cfg.plugins[i].appMenuRows = root.appMenuRows
        found = true
      }
    }
    if (!found) {
      cfg.plugins.push({
        id: "nagualcode.nagualstrip",
        wsScale: Math.round(root.wsScale * 100) / 100,
        wsOpacity: Math.round(root.wsOpacity * 100) / 100,
        wsAutoHide: root.wsAutoHide === true,
        wsToggleEnabled: root.wsToggleEnabled === true,
        wsGap: Math.round(root.wsCardGap),
        wsStripGap: Math.round(root.wsStripGap),
        wsStripRealIcons: root.wsStripRealIcons === true,
        wsShowAppMenu: root.wsShowAppMenu === true,
        wsShowOmafile: root.wsShowOmafile === true,
        wsShowNewWs: root.wsShowNewWs === true,
        wsInstantSwitch: root.wsInstantSwitch === true,
        wsNeonEnabled: root.wsNeonEnabled === true,
        appMenuRows: root.appMenuRows
      })
    }
    return cfg
  }

  // ========================================================================
  //  WORKSPACES FLOAT STRIP (bottom-right)
  // ========================================================================
  property int wsDuration: 1300
  property int wsCardWidth: Style.space(112)
  property int wsCardGap: Style.space(10)
  property int wsOuterPad: Style.space(10)
  property int wsPanelMargin: Style.space(22)
  property bool wsEdgeEnabled: false
  property int wsEdgeHeight: Style.space(6)
  property var workspaces: []
  property bool ready: false
  property bool modelDirty: true
  property bool geometryRefreshPending: false
  property bool geometryRefreshInFlight: false
  property var desktopEntries: []

  // While the Omarchy screensaver (org.omarchy.screensaver) keeps a window on
  // screen the strip must stay hidden: it would otherwise float over the
  // blackout (the screensaver parks focus on every monitor in turn, and each of
  // those focus moves re-shows the pinned strip). Showing is suspended while
  // any screensaver window exists, and the strip hides the moment one maps.
  property var screensaverWindows: ({})
  property bool screensaverUp: false
  property bool stripShownBeforeScreensaver: false

  readonly property int wsLeadingCells: (root.wsShowAppMenu ? 1 : 0) + (root.wsShowOmafile ? 1 : 0)
  // Launcher cells actually visible for the current strip content: the leading
  // apps-menu/omafile cells appear whenever the strip itself can show (always
  // visible, or there is at least one workspace card), and the trailing
  // new-workspace cell only when there are workspace cards.
  readonly property int wsExtraCards: {
    var n = root.workspaces.length
    var lead = (root.wsAlwaysVisible || n > 0) ? root.wsLeadingCells : 0
    var trail = (n > 0 && root.wsShowNewWs) ? 1 : 0
    return lead + trail
  }

  readonly property int effectiveWsCardWidth: {
    var wsCount = root.workspaces.length
    // Launcher cells + workspace cards + optional new-workspace cell.
    var n = Math.max(1, wsCount + root.wsExtraCards)
    var screen = root.activeScreen
    var avail = screen ? screen.width : 1920
    var maxW = Math.floor((avail - root.wsPanelMargin * 2 - root.wsCardGap * (n - 1) - root.wsOuterPad * 2 - 4) / n)
    var desired = Math.round(root.wsCardWidth * root.wsScale)
    return Math.max(40, Math.min(desired, maxW))
  }

  // The strip always sits centered at the bottom of the focused screen.
  readonly property int wsBorderWidth: Math.max(1, Style.space(2))
  readonly property int stripW: {
    var n = root.workspaces.length
    // Launcher cells + workspace cards + optional new-workspace cell.
    var cards = Math.max(1, n) + root.wsExtraCards
    var gaps = Math.max(0, cards - 1)
    return root.effectiveWsCardWidth * cards
      + root.wsCardGap * gaps
      + root.wsOuterPad * 2 + root.wsBorderWidth * 2
  }
  readonly property int stripH: {
    return root.wsCardPreviewH + root.wsOuterPad * 2 + root.wsBorderWidth * 2
  }
  readonly property int wsCardPreviewH: Math.round(root.effectiveWsCardWidth * 9 / 16)
  readonly property int stripX: Math.max(0, Math.floor((panel.width - root.stripW) / 2))

  // Mini triangle marker sitting in the strip's bottom padding, pointing up at
  // the active workspace card.
  readonly property int wsArrowH: Style.space(6)
  readonly property int wsArrowW: root.wsArrowH * 2
  readonly property int focusedWsIndex: {
    var id = root.focusedWorkspaceId
    if (id === null || id === undefined) return -1
    for (var i = 0; i < root.workspaces.length; i++) {
      if (Number(root.workspaces[i].id) === Number(id)) return i
    }
    return -1
  }
  // The arrow only doubles as a close button while it points at an occupied
  // workspace card: sitting over the "+" (empty / new workspace) there is
  // nothing to close, so hovering must not turn it into an "×" either.
  readonly property bool wsArrowCanClose: root.focusedWsIndex >= 0
  // Absolute x (relative to the strip) of the arrow's centre: the Row is
  // centred, and every card is effectiveWsCardWidth wide with wsCardGap
  // between them; workspace i is the (leading cells + i)th cell.
  readonly property real wsArrowCenterX: {
    var n = root.workspaces.length
    if (n <= 0) return -1
    var cards = n + root.wsLeadingCells + (root.wsShowNewWs ? 1 : 0)
    var cw = root.effectiveWsCardWidth
    var gap = root.wsCardGap
    var rowW = cards * cw + (cards - 1) * gap
    var rowX = (root.stripW - rowW) / 2
    if (root.focusedWsIndex >= 0) {
      // On a used workspace, point at its card.
      return rowX + (root.wsLeadingCells + root.focusedWsIndex) * (cw + gap) + cw / 2
    }
    // On an empty workspace there is no card for it; point at the "+"
    // new-workspace button (the last cell) so the strip still confirms where
    // the current workspace sits. With the button hidden there is nowhere to
    // point, so the arrow stays away.
    if (!root.wsShowNewWs) return -1
    return rowX + (root.wsLeadingCells + n) * (cw + gap) + cw / 2
  }
  readonly property int stripY: Math.max(0, panel.height - root.stripH - root.cardBottomMargin)

  // Bar-aware bottom margin so the strip never sits under a bottom bar.
  // The gap between the strip and the screen bottom is wsStripGap; the same
  // gap separates the strip from the windows (see stripReserve).
  readonly property real cardBottomMargin: {
    var bar = shell ? shell.bar : null
    if (bar && bar.position === "bottom" && !bar.barHidden) {
      return wsStripGap + Number(bar.barSize || 0)
    }
    return wsStripGap
  }

  // The bottom reserved area tracks the strip's on-screen region so a
  // maximized window stops one wsStripGap above the strip's top edge (equal
  // to the strip's own bottom gap): stripHeight + gap above + gap below. The
  // value is rewritten to ~/.config/omarchy/.nagualstrip-reserve and
  // applied with a Hyprland reload whenever the strip grows/shrinks (e.g. the
  // Size slider or a change in the number of workspaces). monitors.lua reads
  // that sidecar. While the strip and menu bar are hidden by the bottom-left
  // hot corner, nothing is reserved so windows reclaim the space.
  readonly property string stripReservePath: Quickshell.env("HOME") + "/.config/omarchy/.nagualstrip-reserve"
  readonly property int stripReserve: root.chromeHidden
    ? 0
    : Math.max(0, Math.round(root.stripH + root.cardBottomMargin * 2))
  property int stripReserveLast: -1
  property bool stripReservePendingReload: false
  FileView {
    id: stripReserveFile
    path: root.stripReservePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }
  // File write is cheap, so it happens on every change; the Hyprland reload
  // is deferred one extra tick so a sliding/typing the value settles and the
  // compositor reloads only once (no reload spam while dragging the Size
  // slider or typing a margin).
  function syncStripReserve() {
    var value = root.stripReserve
    if (root.stripReserveLast === value) {
      if (root.stripReservePendingReload) {
        root.stripReservePendingReload = false
        Quickshell.execDetached(["hyprctl", "reload"])
      }
      return
    }
    root.stripReserveLast = value
    stripReserveFile.setText(String(Math.round(value)))
    root.stripReservePendingReload = true
  }
  Timer {
    id: stripReserveTimer
    interval: 700
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.syncStripReserve()
  }

  Timer {
    id: readyTimer
    interval: 1500
    onTriggered: {
      root.ready = true
      // With the bottom-center toggle off the strip must be on screen from the
      // start instead of waiting for a hot-corner trigger.
      if (root.wsAlwaysVisible) root.showWorkspaces()
    }
  }

  Timer {
    // Cover the slide-out after hide: the workspace strip stays visible
    // (wsSliding) for exactly the slide duration, then hides.
    id: wsSlideOutTimer
    interval: root.effectivePanelAnimMs
    onTriggered: root.wsSliding = false
  }

  Component.onCompleted: {
    root.readyTimerStart()
    root.readConfig()
    root.refreshDesktopEntries()
  }
  function readyTimerStart() { readyTimer.start() }

  function showWorkspaces() {
    if (root.screensaverUp) return
    // The icon panel of nagualcode.speakercorners owns the screen for now; the
    // strip comes back on resume() with whatever visibility it had before.
    if (root.suspended) return
    // A fullscreen window owns the screen; keep the strip (Overlay layer, which
    // Hyprland won't fade) out of the way until it exits.
    if (root.fullscreenActive) {
      if (root.workspacesOpened) root.hideWorkspaces()
      return
    }
    var rebuilt = root.modelDirty
    root.ready = true
    if (rebuilt) root.refreshMainModel()
    // The pinned strip (toggle disabled) keeps at least the launcher cell on
    // screen even while no workspace holds a window; the transient strip has
    // nothing to display with an empty model.
    if (root.workspaces.length === 0 && !root.wsAlwaysVisible) {
      if (root.workspacesOpened) root.hideWorkspaces()
      return
    }
    root.workspacesOpened = true
    root.restartWorkspacesHideTimer()
  }

  function hideWorkspaces() {
    // Any hide while suspended (auto-hide timer, workspace switch, IPC close)
    // means there is nothing left to restore on resume().
    if (root.suspended) root.shownBeforeSuspend = false
    wsHideTimer.stop()
    wsSettleTimer.stop()
    root.workspacesOpened = false
    root.closeWsConfig()
    if (root.effectivePanelAnimMs > 0) wsSlideOutTimer.start()
    else root.wsSliding = false
  }

  function toggleWorkspaces() { root.workspacesOpened ? root.hideWorkspaces() : root.showWorkspaces() }

  function refreshDesktopEntries() {
    var next = []
    try {
      var values = DesktopEntries.applications.values || []
      for (var i = 0; i < values.length; i++) {
        if (values[i]) next.push(values[i])
      }
    } catch (error) {}
    root.desktopEntries = next
  }

  function refreshMainModel() {
    root.workspaces = WorkspaceModel.buildWorkspaces()
    root.modelDirty = false
    if (root.workspacesOpened && root.workspaces.length === 0 && !root.wsAlwaysVisible) root.hideWorkspaces()
  }

  function requestGeometryRefresh() {
    root.geometryRefreshPending = true
    if (root.geometryRefreshInFlight) return
    root.geometryRefreshInFlight = true
    Hyprland.refreshToplevels()
    wsGeometryTimer.restart()
  }

  function restartWorkspacesHideTimer() {
    if (!root.wsAutoHide || root.wsConfigOpen || root.wsAlwaysVisible || root.wsWindowMenuOpen) { wsHideTimer.stop(); return }
    if (stripHover.hovered) wsHideTimer.stop()
    else wsHideTimer.restart()
  }

  // Escape a value as a single-line Lua string literal so it can be embedded
  // in a hyprctl Lua dispatcher expression.
  function luaStringLiteral(value) {
    return String(value || "").replace(/[\\"\x00-\x1f\x7f]/g, function(ch) {
      if (ch === "\\") return "\\\\"
      if (ch === '"') return '\\"'
      var decimal = ch.charCodeAt(0).toString()
      return "\\" + ("000" + decimal).slice(-3)
    })
  }

  // Same switch as focusWorkspace, but with Hyprland's animations suppressed
  // for the one tick it takes the compositor to register the workspace
  // animation, so the click lands instantly instead of sliding.
  //
  // `hyprctl keyword animations:enabled false` is deliberately not used: since
  // Hyprland 0.55's Lua config parser it answers "keyword can't work with
  // non-legacy parsers". `hl.config` walks only the keys present in the table
  // (src/config/lua/bindings/LuaBindingsConfigRules.cpp), so `animations.enabled`
  // is the single value this touches.
  //
  // The restore is deferred by a compositor-side one-shot instead of running
  // inline because CHyprAnimationManager::tick() decides to warp an animated
  // variable (jump straight to its end state) by reading `animations:enabled` at
  // tick time, and the first tick is only scheduled ~1ms after the switch
  // registers its animated variables. Re-enabling inside the same request would
  // land before that tick and the slide would animate as usual. Both timers sit
  // on the same event loop and fire in timeout order, so the 1ms tick always
  // wins. The restored value mirrors animations.enabled in ~/.config/hypr/looknfeel.lua.
  function focusWorkspaceNoAnim(target) {
    var lua = 'hl.config({ animations = { enabled = false } })'
      + ' pcall(hl.dispatch, hl.dsp.focus({ workspace = "' + root.luaStringLiteral(target) + '" }))'
      + ' hl.timer(function() hl.config({ animations = { enabled = true } }) end, { timeout = 60, type = "oneshot" })'
    Quickshell.execDetached(["hyprctl", "eval", lua])
  }

  // Switch to the workspace behind a clicked card. Omarchy runs Hyprland in
  // Lua mode, so workspace focus goes through the Lua dispatcher expression
  // rather than the plain "workspace <id>" dispatcher (which errors under
  // hl.dispatch wrap).
  function focusWorkspace(ws) {
    root.closeWsConfig()
    root.closeWsWindowMenu()
    if (!ws) return
    var target = (ws.name && String(ws.name).length > 0) ? String(ws.name) : String(ws.id)
    if (root.wsInstantSwitch) {
      root.focusWorkspaceNoAnim(target)
      return
    }
    var expr = 'hl.dsp.focus({ workspace = "' + root.luaStringLiteral(target) + '" })'
    Quickshell.execDetached(["hyprctl", "dispatch", expr])
  }

  // Open the first empty workspace after the last used one. "Used" means a
  // workspace that has at least one window. The new workspace gets the first
  // free numeric ID above the highest occupied one.
  function openNewWorkspace() {
    // Already sitting on an empty workspace? There's nowhere to jump to, so
    // the "+" button is a no-op. Without this guard, focusing the very same
    // workspace never fires a focus-change event and the strip just disappears
    // (the hide below would never be reverted by the show).
    var focused = Hyprland.focusedWorkspace
    var tl = focused ? focused.toplevels : null
    var focusedCount = (tl && tl.values) ? tl.values.length : 0
    if (focusedCount === 0) return

    var maxUsed = 0
    for (var i = 0; i < root.workspaces.length; i++) {
      var w = root.workspaces[i]
      if (w && w.windowCount > 0) {
        var id = Number(w.id)
        if (isFinite(id) && id > maxUsed) maxUsed = id
      }
    }
    var target = maxUsed + 1
    var expr = 'hl.dsp.focus({ workspace = "' + root.luaStringLiteral(String(target)) + '" })'
    Quickshell.execDetached(["hyprctl", "dispatch", expr])
    // No explicit hideWorkspaces(): the focus change re-shows the strip via
    // onFocusedWorkspaceChanged, so hiding first would only make it flicker.
  }

  Timer {
    id: wsHideTimer
    interval: root.wsDuration
    onTriggered: root.hideWorkspaces()
  }

  Timer {
    id: wsGeometryTimer
    interval: 100
    onTriggered: {
      root.geometryRefreshInFlight = false
      if (!root.geometryRefreshPending) return
      root.geometryRefreshPending = false
      root.refreshMainModel()
      if (root.workspaces.length === 0) return
      if (root.workspacesOpened) root.restartWorkspacesHideTimer()
    }
  }

  Timer {
    id: wsSettleTimer
    interval: 40
    onTriggered: root.showWorkspaces()
  }

  // Track the Omarchy screensaver windows (class org.omarchy.screensaver) so
  // the strip can hide while the blackout is up and restore itself afterwards.
  function trackScreensaverWindows(event, name) {
    var fields = []
    try {
      if (event && event.parse) fields = event.parse(4) || []
    } catch (e) {
      fields = String(event && event.data ? event.data : "").split(",")
    }
    if (name === "openwindow" && String(fields[2] || "") === "org.omarchy.screensaver") {
      var opened = String(fields[0] || "")
      if (opened && !root.screensaverWindows[opened]) {
        var after = ({})
        for (var k in root.screensaverWindows) after[k] = true
        after[opened] = true
        root.screensaverWindows = after
        if (!root.screensaverUp) {
          root.screensaverUp = true
          root.stripShownBeforeScreensaver = root.workspacesOpened && !root.chromeHidden
          root.hideWorkspaces()
          root.closeAppMenu()
        }
      }
      return
    }
    if (name === "closewindow") {
      var closed = String(fields[0] || "")
      if (!root.screensaverWindows[closed]) return
      var rest = ({})
      var any = false
      for (var a in root.screensaverWindows) {
        if (a !== closed) {
          rest[a] = true
          any = true
        }
      }
      if (any) {
        root.screensaverWindows = rest
        return
      }
      root.screensaverWindows = ({})
      if (root.screensaverUp) {
        root.screensaverUp = false
        if (root.stripShownBeforeScreensaver) root.showWorkspaces()
        root.stripShownBeforeScreensaver = false
      }
    }
  }

  Connections {
    target: Hyprland

    function onFocusedWorkspaceChanged() {
      if (!root.ready) return
      if (root.chromeHidden) { root.briefWorkspaceFlash(); return }
      root.showWorkspaces()
    }

    function onRawEvent(event) {
      var name = String(event && event.name ? event.name : "")
      root.trackScreensaverWindows(event, name)
      if (!root.ready) return
      var geometryEvent = ["movewindow", "moveworkspace", "openwindow", "closewindow", "changefloatingmode", "fullscreen", "pin", "minimize"].indexOf(name) !== -1
      var modelEvent = geometryEvent || name === "renameworkspace" || name === "urgent"
      if (!modelEvent) return

      root.modelDirty = true
      if (geometryEvent) root.requestGeometryRefresh()
      else if (root.workspacesOpened) wsSettleTimer.restart()
    }
  }

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() { root.refreshDesktopEntries() }
  }

  readonly property var focusedWorkspaceId: {
    var ws = Hyprland.focusedWorkspace
    return ws ? ws.id : null
  }

  // Hyprland fades the bar's Top layer out while a window is fullscreen, but
  // leaves Overlay layers (where this strip lives) visible, so the strip has to
  // step aside itself. `focusedMonitor.activeWorkspace.hasFullscreen` is the
  // per-monitor signal, matching the screen the strip is shown on.
  readonly property bool fullscreenActive: {
    var monitor = Hyprland.focusedMonitor
    var ws = monitor ? monitor.activeWorkspace : null
    return !!(ws && ws.hasFullscreen)
  }
  onFullscreenActiveChanged: {
    if (root.fullscreenActive) root.hideWorkspaces()
    else if (root.wsAlwaysVisible && root.configLoaded) root.showWorkspaces()
  }

  // ---- Smart app menu -----------------------------------------------------
  // Opened by left-clicking the strip's launcher cell. It is this plugin's own
  // launcher: same installed-app list and same search as the Omarchy menu's
  // "apps" page, but ordered by use (most recently opened first) and persisted,
  // with square icon-over-name cells instead of wide rows.
  function openAppMenu() {
    if (root.screensaverUp) return
    // The two popups are modal in different ways and would fight over the same
    // full-screen mask, so opening one closes the other.
    root.closeWsConfig()
    root.closeWsWindowMenu()
    root.appMenuOpened = true
  }

  function closeAppMenu() {
    if (!root.appMenuOpened) return
    root.appMenuOpened = false
  }

  function toggleAppMenu() { root.appMenuOpened ? root.closeAppMenu() : root.openAppMenu() }

  // ========================================================================
  //  Shell panel contract + IPC targets
  // ========================================================================
  function open(payloadJson) {
    root.showWorkspaces()
    return "ok"
  }
  function close() {
    // A close must not be undone by a later resume().
    if (root.suspended) root.shownBeforeSuspend = false
    root.hideWorkspaces()
    root.closeAppMenu()
    return "ok"
  }
  function toggle() { root.anyOpen ? root.close() : root.open("") }
  function refresh() { root.readConfig(); return "ok" }
  function ping() { return "ok" }

  function stateString() {
    return (root.workspacesOpened ? "open" : "closed")
      + " apps=" + (root.appMenuOpened ? "1" : "0")
      + " chrome=" + (root.chromeHidden ? "1" : "0")
      + " suspended=" + (root.suspended ? "1" : "0")
  }

  // The canonical target of this plugin.
  IpcHandler {
    target: "nagualstrip"
    function open(): string { root.open(""); return "ok" }
    function close(): string { root.close(); return "ok" }
    function toggle(): string { root.toggle(); return "ok" }
    function state(): string { return root.stateString() }
    function suspend(): string { root.suspend(); return "ok" }
    function resume(): string { root.resume(); return "ok" }
    // omarchy-shell nagualstrip setchrome on|off
    function setchrome(on: string): string {
      root.setChromeHidden(String(on || "") === "on")
      return "ok"
    }
  }

  // Legacy target: the bottom-center hot corner of nagualcode.speakercorners
  // runs `omarchy-shell workspace-overview toggle` by default.
  IpcHandler {
    target: "workspace-overview"
    function open(): string { root.showWorkspaces(); return "ok" }
    function close(): string { root.hideWorkspaces(); return "ok" }
    function toggle(): string { root.toggleWorkspaces(); return "ok" }
    function state(): string { return root.workspacesOpened ? "open" : "closed" }
  }

  // The smart app menu, so it can be bound to a key or summoned from a script:
  //   omarchy-shell nagualstrip-apps toggle
  IpcHandler {
    target: "nagualstrip-apps"
    function open(): string { root.openAppMenu(); return "ok" }
    function close(): string { root.closeAppMenu(); return "ok" }
    function toggle(): string { root.toggleAppMenu(); return "ok" }
    function state(): string { return root.appMenuOpened ? "open" : "closed" }
  }

  // Legacy target kept so existing keybindings keep working.
  IpcHandler {
    target: "speakercorners-apps"
    function open(): string { root.openAppMenu(); return "ok" }
    function close(): string { root.closeAppMenu(); return "ok" }
    function toggle(): string { root.toggleAppMenu(); return "ok" }
    function state(): string { return root.appMenuOpened ? "open" : "closed" }
  }

  // ========================================================================
  //  The single masked window
  // ========================================================================
  PanelWindow {
    id: panel
    screen: root.activeScreen
    visible: true
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-nagualstrip"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.keysWanted ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    // Input is restricted to what is actually interactive, so everything else
    // on screen keeps receiving the pointer: the strip while it shows, the
    // app grid and the configuration popup while they are up (both bring their
    // own outside-click catchers, which the matching fullscreen block makes
    // clickable), and the opt-in bottom hover edge.
    mask: Region {
      // workspace strip clicks (and null while it is hidden)
      Region { x: root.stripX; y: root.stripY; width: root.workspacesOpened ? root.stripW : 0; height: root.workspacesOpened ? root.stripH : 0 }
      // smart app menu (the panel only; it brings its own outside-click
      // catcher, which the fullscreen block below already makes clickable)
      Region { x: appMenu.panelX; y: appMenu.panelY; width: root.appMenuOpened ? appMenu.panelW : 0; height: root.appMenuOpened ? appMenu.panelH : 0 }
      // fullscreen block while the app grid is up (it needs the keyboard, and
      // outside clicks dismiss it)
      Region { x: 0; y: 0; width: root.appMenuOpened ? panel.width : 0; height: root.appMenuOpened ? panel.height : 0 }
      // workspace configuration popup (while open)
      Region { x: root.wsConfigPopupX; y: root.wsConfigPopupY; width: root.wsConfigOpen ? root.wsConfigPopupW : 0; height: root.wsConfigOpen ? root.wsConfigPopupH : 0 }
      // fullscreen block while the config popup is open (outside clicks dismiss it)
      Region { x: 0; y: 0; width: root.wsConfigOpen ? panel.width : 0; height: root.wsConfigOpen ? panel.height : 0 }
      // workspace window menu
      Region { x: root.wsWindowMenuX; y: root.wsWindowMenuY; width: root.wsWindowMenuOpen ? root.wsWindowMenuW : 0; height: root.wsWindowMenuOpen ? root.wsWindowMenuH : 0 }
      // fullscreen block while window menu open
      Region { x: 0; y: 0; width: root.wsWindowMenuOpen ? panel.width : 0; height: root.wsWindowMenuOpen ? panel.height : 0 }
      // optional bottom edge (opt-in) or auto-hide trigger zone
      Region {
        x: root.wsEdgeEnabled ? 0 : (root.wsAutoHide && !root.wsAlwaysVisible && !root.workspacesOpened ? Math.max(0, (panel.width - Math.min(panel.width, Math.max(Style.space(160), panel.width * 0.35))) / 2) : 0)
        y: root.wsEdgeEnabled ? panel.height - root.wsEdgeHeight : (root.wsAutoHide && !root.wsAlwaysVisible && !root.workspacesOpened ? Math.max(0, panel.height - root.wsEdgeHeight * 4) : panel.height)
        width: root.wsEdgeEnabled ? panel.width : (root.wsAutoHide && !root.wsAlwaysVisible && !root.workspacesOpened ? Math.min(panel.width, Math.max(Style.space(160), panel.width * 0.35)) : 0)
        height: root.wsEdgeEnabled ? root.wsEdgeHeight : (root.wsAutoHide && !root.wsAlwaysVisible && !root.workspacesOpened ? root.wsEdgeHeight * 4 : 0)
      }
    }

    // ---- Workspaces float strip (bottom-right) ----
    BorderSurface {
      id: strip
      z: 4
      // Kept visible for the closing slide via wsSliding (see hideWorkspaces()).
      visible: root.workspacesOpened || root.wsSliding
      x: root.stripX
      // Slides up from below the screen edge; parked off-screen when closed.
      y: root.workspacesOpened ? root.stripY : panel.height
      width: root.stripW
      height: root.stripH
      radius: root.cornerRadius
      color: Util.alpha(Color.popups.background, root.wsOpacity)
      borderSpec: root.wsNeonEnabled
        ? Border.flat(root.wsNeonGlow, Math.max(1, Style.space(2)))
        : Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))

      Behavior on y {
        NumberAnimation { duration: root.effectivePanelAnimMs; easing.type: Easing.OutCubic }
      }

      // Right-click only on strip background (not on workspace icons/cards or buttons)
      // brings up its configuration (size / transparency / auto-hide).
      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.RightButton
        propagateComposedEvents: true
        onClicked: function(mouse) {
          var rowTop = strip.y + root.wsOuterPad
          var rowBottom = rowTop + root.wsCardPreviewH
          var localY = mouse.y
          var inRowVertical = (localY >= rowTop && localY <= rowBottom)
          if (inRowVertical) {
            var row = stripRow
            var localX = mouse.x
            var inRow = (localX >= row.x && localX <= row.x + row.width)
            if (inRow) {
              mouse.accepted = false
              return
            }
          }
          var arrow = wsArrow
          if (arrow.visible) {
            var inArrow = (localY >= arrow.y && localY <= arrow.y + arrow.height &&
                          localX >= arrow.x && localX <= arrow.x + arrow.width)
            if (inArrow) {
              mouse.accepted = false
              return
            }
          }
          root.toggleWsConfig()
          mouse.accepted = true
        }
      }

      // Keep the overview open while the pointer is over it, so a click can
      // land; the auto-hide countdown resumes once the pointer leaves.
      HoverHandler {
        id: stripHover
        onHoveredChanged: {
          if (hovered) wsHideTimer.stop()
          else if (root.workspacesOpened) root.restartWorkspacesHideTimer()
        }
      }

      Row {
        id: stripRow
        anchors.top: parent.top
        anchors.topMargin: root.wsOuterPad
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: root.wsCardGap

        // App launcher card: left-click opens this plugin's own smart app menu
        // (same app list and search as the Omarchy menu, ordered by use), and
        // right-click opens a terminal.
        Item {
          width: root.effectiveWsCardWidth
          height: root.wsCardPreviewH
          // The pinned strip shows the launcher cell even with no windows on
          // screen; the transient strip only appears with cards to render.
          visible: root.wsShowAppMenu && (root.wsAlwaysVisible || root.workspaces.length > 0)

          // Solid app-grid glyph (fa-th, U+F00A) from Font Awesome 7 Free --
          // the family this strip already falls back to for its icons. No
          // card background: a bare, fully-opaque accent glyph that fills the
          // whole preview cell. Left opens the app menu, right opens the
          // terminal.
          Text {
            width: root.effectiveWsCardWidth
            height: root.wsCardPreviewH
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            text: "\uF00A"
            font.family: "Font Awesome 7 Free"
            font.weight: Font.Black
            font.pixelSize: root.wsCardPreviewH
            color: appMenuArea.containsMouse
              ? Qt.lighter(root.wsStripAccent, 1.3)
              : root.wsStripAccent
            // FA7's glyph ink sits at the top of the em box (~12.5% empty
            // below), so AlignVCenter still rides high. Nudge down by half
            // that dead space to optically center the 2x2 grid in the cell.
            transform: Translate {
              y: Math.round(root.wsCardPreviewH * 0.0625)
            }
          }

          MouseArea {
            id: appMenuArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            // Left opens this plugin's own app menu (not the omarchy-menu "apps"
            // page); right opens the terminal.
            onClicked: function(mouse) {
              if (mouse.button === Qt.RightButton) {
                Quickshell.execDetached(["omarchy-launch-terminal"])
              } else {
                root.openAppMenu()
              }
            }
          }
        }

        Item {
          width: root.effectiveWsCardWidth
          height: root.wsCardPreviewH
          visible: root.wsShowOmafile && (root.wsAlwaysVisible || root.workspaces.length > 0)

          Text {
            width: root.effectiveWsCardWidth
            height: root.wsCardPreviewH
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            text: "\uF07B"
            font.family: "Font Awesome 7 Free"
            font.weight: Font.Black
            font.pixelSize: root.wsCardPreviewH
            color: omafileArea.containsMouse
              ? Qt.lighter(Color.accent, 1.3)
              : Color.accent
            transform: Translate {
              y: Math.round(root.wsCardPreviewH * 0.0625)
            }
          }

          MouseArea {
            id: omafileArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton
            onClicked: Quickshell.execDetached(["omarchy-shell", "shell", "toggle", "xyzlab.omafile", "{}"])
          }
        }

        Repeater {
          model: root.workspaces

          WorkspaceCard {
            id: wsCard
            required property var modelData

            width: root.effectiveWsCardWidth

            ws: modelData
            shell: root.shell
            desktopEntries: root.desktopEntries
            realIcons: root.wsStripRealIcons
            focused: root.focusedWorkspaceId !== null
              && Number(root.focusedWorkspaceId) === Number(modelData.id)
            onActivate: function(ws) { root.focusWorkspace(ws) }
          }
        }

        Item {
          width: root.effectiveWsCardWidth
          height: root.wsCardPreviewH
          visible: root.wsShowNewWs && root.workspaces.length > 0

          Rectangle {
            anchors.centerIn: parent
            width: root.effectiveWsCardWidth
            height: root.wsCardPreviewH
            radius: root.cornerRadius
            color: newWorkspaceArea.containsMouse
              ? Util.alpha(Color.popups.text, 0.12)
              : Util.alpha(Color.popups.text, 0.06)
            border.width: Math.max(1, Style.space(1))
            border.color: Util.alpha(Color.popups.text, 0.15)

            Text {
              anchors.centerIn: parent
              text: "+"
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              color: Util.alpha(Color.popups.text, 0.5)
            }

            MouseArea {
              id: newWorkspaceArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openNewWorkspace()
            }
          }
        }
      }

      // Mini triangle marker in the strip's bottom padding, centred under the
      // active workspace card and pointing up at it. It doubles as the close
      // button for the active workspace: hovering turns it into an "×" and a
      // click closes the workspace (and every window on it).
      Item {
        id: wsArrow
        visible: root.workspacesOpened && root.wsArrowCenterX >= 0
        width: root.wsArrowW
        height: root.wsArrowH
        x: Math.round(root.wsArrowCenterX - root.wsArrowW / 2)
        y: root.stripH - root.wsArrowH - root.wsBorderWidth - Style.space(1)

        // A square rotated 45°; clipping the lower half leaves a clean
        // upward-pointing triangle.
        Item {
          anchors.fill: parent
          clip: true
          visible: !wsArrowHover.containsMouse || !root.wsArrowCanClose

          Rectangle {
            width: root.wsArrowH * Math.SQRT2
            height: root.wsArrowH * Math.SQRT2
            color: Color.accent
            rotation: 45
            x: root.wsArrowH - width / 2
            y: root.wsArrowH - height / 2
          }
        }

        // Close-affordance "×" shown while the pointer is over the marker (and
        // only when there is an actual workspace to close).
        Text {
          anchors.centerIn: parent
          anchors.verticalCenterOffset: Math.round(-root.wsArrowH * 0.5)
          visible: wsArrowHover.containsMouse && root.wsArrowCanClose
          text: "\u2715"
          textFormat: Text.PlainText
          font.family: root.fontFamily
          font.pixelSize: Math.ceil(root.wsArrowH * 2.4)
          font.bold: true
          color: Color.urgent
        }

        MouseArea {
          id: wsArrowHover
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          enabled: root.wsArrowCanClose
          onClicked: root.closeWorkspace(root.focusedWorkspaceId)
        }
      }
    }

    // ---- Workspaces configuration popup ----
    // Right-click the strip to open. The sliders apply live and commit to
    // shell.json when the popup closes; the strip's mask admits this region
    // only while it is open.
    // Transparent catcher while the popup is open: any click outside it
    // dismisses (settings are live-applied and saved on close).
    MouseArea {
      anchors.fill: parent
      z: 10
      visible: root.wsConfigOpen
      onClicked: root.dismissWsConfig()
    }

    BorderSurface {
      id: wsConfigPopup
      z: 12
      visible: root.wsConfigOpen
      x: root.wsConfigPopupX
      y: root.wsConfigPopupY
      width: root.wsConfigPopupW
      height: root.wsConfigPopupH
      radius: root.cornerRadius
      // Same transparency as the strip itself.
      color: Util.alpha(Color.popups.background, root.wsOpacity)
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))

      // While the strip auto-hides below, the popup keeps it alive.
      HoverHandler {
        onHoveredChanged: {
          if (hovered) wsHideTimer.stop()
          else if (root.workspacesOpened) root.restartWorkspacesHideTimer()
        }
      }

      Column {
        x: Style.space(12)
        y: Style.space(12)
        width: parent.width - Style.space(24)
        spacing: Style.space(8)

        Text {
          width: parent.width
          text: "Workspace strip"
          textFormat: Text.PlainText
          font.family: Style.font.family
          font.pixelSize: Style.font.subtitle
          font.bold: true
          color: Color.popups.text
        }

        MiniSlider {
          width: parent.width
          label: "Size"
          min: 0.5
          max: 2.0
          value: root.wsScale
          format: function(v) { return Math.round(v * 100) + "%" }
          onAdjust: function(v) { root.wsScale = v; wsConfigPeel.restart() }
          onCommitted: root.persistWorkspaceSettings()
        }

        MiniSlider {
          width: parent.width
          label: "Transparency"
          min: 0.1
          max: 1.0
          value: root.wsOpacity
          format: function(v) { return Math.round((1 - v) * 100) + "%" }
          onAdjust: function(v) { root.wsOpacity = v; wsConfigPeel.restart() }
          onCommitted: root.persistWorkspaceSettings()
        }

        MiniSlider {
          width: parent.width
          label: "Spacing"
          min: 0
          max: Style.space(40)
          value: root.wsCardGap
          format: function(v) { return Math.round(v) + "px" }
          onAdjust: function(v) { root.wsCardGap = v; wsConfigPeel.restart() }
          onCommitted: root.persistWorkspaceSettings()
        }

        MiniSlider {
          width: parent.width
          label: "Gap"
          min: 0
          max: Style.space(40)
          value: root.wsStripGap
          format: function(v) { return Math.round(v) + "px" }
          onAdjust: function(v) { root.wsStripGap = v; wsConfigPeel.restart() }
          onCommitted: root.persistWorkspaceSettings()
        }

        Item {
          id: autoHideRow
          width: parent.width
          height: Style.space(26)

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Auto-hide"
            textFormat: Text.PlainText
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: Util.alpha(Color.popups.text, 0.85)
          }

          Rectangle {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(34)
            height: Style.space(18)
            radius: height / 2
            color: root.wsAutoHide ? Color.accent : Util.alpha(Color.popups.text, 0.18)
            Behavior on color { ColorAnimation { duration: 120 } }

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              x: root.wsAutoHide
                ? parent.width - width - Math.max(2, Style.space(1))
                : Math.max(2, Style.space(1))
              width: Style.space(14)
              height: Style.space(14)
              radius: width / 2
              color: "#ffffff"
              Behavior on x { NumberAnimation { duration: 120 } }
            }

            MouseArea {
              anchors.fill: parent
              onClicked: {
                root.wsAutoHide = !root.wsAutoHide
                root.persistWorkspaceSettings()
                root.restartWorkspacesHideTimer()
                wsConfigPeel.restart()
              }
            }
          }
        }

        Item {
          id: toggleRow
          width: parent.width
          height: Style.space(26)

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Bottom-center toggle"
            textFormat: Text.PlainText
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: Util.alpha(Color.popups.text, 0.85)
          }

          Rectangle {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(34)
            height: Style.space(18)
            radius: height / 2
            color: root.wsToggleEnabled ? Color.accent : Util.alpha(Color.popups.text, 0.18)
            Behavior on color { ColorAnimation { duration: 120 } }

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              x: root.wsToggleEnabled
                ? parent.width - width - Math.max(2, Style.space(1))
                : Math.max(2, Style.space(1))
              width: Style.space(14)
              height: Style.space(14)
              radius: width / 2
              color: "#ffffff"
              Behavior on x { NumberAnimation { duration: 120 } }
            }

            MouseArea {
              anchors.fill: parent
              onClicked: {
                root.wsToggleEnabled = !root.wsToggleEnabled
                root.persistWorkspaceSettings()
                root.restartWorkspacesHideTimer()
                wsConfigPeel.restart()
              }
            }
          }
        }

        MiniToggle {
          width: parent.width
          label: "Instant switch"
          checked: root.wsInstantSwitch
          onToggled: function(v) {
            root.wsInstantSwitch = v
            root.persistWorkspaceSettings()
            wsConfigPeel.restart()
          }
        }

        MiniToggle {
          width: parent.width
          label: "Neon glow"
          checked: root.wsNeonEnabled
          onToggled: function(v) {
            root.wsNeonEnabled = v
            root.persistWorkspaceSettings()
            wsConfigPeel.restart()
          }
        }

        MiniToggle {
          width: parent.width
          label: "Apps menu icon"
          checked: root.wsShowAppMenu
          onToggled: function(v) {
            root.wsShowAppMenu = v
            root.persistWorkspaceSettings()
            wsConfigPeel.restart()
          }
        }

        MiniToggle {
          width: parent.width
          label: "File manager icon"
          checked: root.wsShowOmafile
          onToggled: function(v) {
            root.wsShowOmafile = v
            root.persistWorkspaceSettings()
            wsConfigPeel.restart()
          }
        }

        MiniToggle {
          width: parent.width
          label: "New workspace icon"
          checked: root.wsShowNewWs
          onToggled: function(v) {
            root.wsShowNewWs = v
            root.persistWorkspaceSettings()
            wsConfigPeel.restart()
          }
        }

        MiniSlider {
          width: parent.width
          label: "App menu rows"
          min: 1
          max: 6
          value: root.appMenuRows
          stepSize: 1
          format: function(v) { return Math.round(v) + (Math.round(v) === 1 ? " row" : " rows") }
          onAdjust: function(v) { root.appMenuRows = Math.round(v); wsConfigPeel.restart() }
          onCommitted: root.persistWorkspaceSettings()
        }
      }
    }

      // ---- Workspace window list menu (mini) ----
      MouseArea {
        anchors.fill: parent
        z: 11
        visible: root.wsWindowMenuOpen
        onClicked: root.dismissWsWindowMenu()
      }

      BorderSurface {
        id: wsWindowMenu
        z: 13
        visible: root.wsWindowMenuOpen
        x: root.wsWindowMenuX
        y: root.wsWindowMenuY
        width: root.wsWindowMenuW
        height: Math.min(root.wsWindowMenuH, Style.space(260))
        radius: root.cornerRadius
        color: Util.alpha(Color.popups.background, root.wsOpacity)
        borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))

        Column {
          anchors.fill: parent
          anchors.margins: Style.space(8)
          spacing: Style.space(4)

          Text {
            width: parent.width
            text: "Windows"
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
            color: Color.popups.text
          }

          ListView {
            width: parent.width
            height: parent.height - Style.space(20)
            model: root.wsWindowMenuWs ? root.wsWindowMenuWs.windows : []
            clip: true
            delegate: Item {
              width: ListView.view.width
              height: Style.space(24)

              property var w: modelData
              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(4)
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Style.space(10)
                elide: Text.ElideRight
                text: w.title || w.appId || "Window"
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: Color.popups.text
                MouseArea {
                  anchors.fill: parent
                  acceptedButtons: Qt.LeftButton | Qt.RightButton
                  onClicked: function(mouse) {
                    if (mouse.button === Qt.RightButton) {
                      if (modelData && modelData.address) {
                        root.closeWindowByAddress(modelData.address)
                      }
                      root.closeWsWindowMenu()
                      mouse.accepted = true
                      return
                    }
                    if (modelData && modelData.address) {
                      root.focusWindowByAddress(modelData.address)
                    } else {
                      root.focusWorkspace(root.wsWindowMenuWs)
                    }
                    root.closeWsWindowMenu()
                    mouse.accepted = true
                  }
                }
              }

                Item {
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(16)
                  height: Style.space(16)
                }
            }
          }
        }
      }

      // ---- Smart app menu ----
      // Fills the window so its own outside-click catcher reaches every corner
      // and its geometry can be read for the mask above. Above the strip and the
      // configuration popup, both of which it dismisses on the way out.
      AppLauncherMenu {
        id: appMenu
        z: 8
        anchors.fill: parent
        appLibrary: root.appLibrary
        open: root.appMenuOpened
        // The menu shares the strip's surface: same opacity (the strip's own
        // transparency setting) and same border family, neon included.
        surfaceOpacity: root.wsOpacity
        neonEnabled: root.wsNeonEnabled
        neonGlow: root.wsNeonGlow
        accentColor: root.wsStripAccent
        rowsLimit: root.appMenuRows
        stripTop: root.stripY
        onDismissRequested: root.closeAppMenu()
      }

    // ---- Optional bottom edge / auto-hide trigger ----
      Item {
        visible: root.wsAutoHide && !root.wsAlwaysVisible
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(panel.width, Math.max(Style.space(160), panel.width * 0.35))
        height: root.wsEdgeHeight * 4
        HoverHandler {
          onHoveredChanged: if (hovered && root.ready) root.showWorkspaces()
        }
      }
      Item {
        visible: root.wsEdgeEnabled
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: root.wsEdgeHeight
        HoverHandler {
          onHoveredChanged: if (hovered && root.ready) root.showWorkspaces()
        }
      }

    // ---- Keyboard routing (app grid) ----
    Item {
      id: keyRouter
      anchors.fill: parent
      focus: root.keysWanted
      enabled: root.keysWanted
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (event.key !== Qt.Key_Escape) return
        // The app grid's own field eats Escape first when a query is typed, so
        // anything landing here is "close".
        if (root.appMenuOpened) {
          root.closeAppMenu()
          event.accepted = true
        }
      }
    }
  }

  // Drag slider used by the workspace configuration popup. No QtQuick.Controls:
  // the shell only ships hand-rolled widgets, so this matches the rest of the
  // plugin. `value` is clamped, `adjust` fires on every drag tick and
  // `committed` once, on release.
  component MiniSlider: Item {
    id: ms

    property real value: 0
    property real min: 0
    property real max: 1
    property string label: ""
    property var format: null
    property real stepSize: 0
    signal adjust(real v)
    signal committed()

    implicitHeight: Style.space(42)

    readonly property real knobW: Style.space(16)
    readonly property real trackH: Style.space(4)
    readonly property real trackX: 0
    readonly property real trackW: ms.width - Style.space(70)

    readonly property real knobX: {
      if (ms.max <= ms.min) return ms.trackX
      var t = Math.max(0, Math.min(1, (ms.value - ms.min) / (ms.max - ms.min)))
      return ms.trackX + t * ms.trackW - ms.knobW / 2
    }
    readonly property real fillW: {
      if (ms.max <= ms.min) return 0
      var t = Math.max(0, Math.min(1, (ms.value - ms.min) / (ms.max - ms.min)))
      return t * ms.trackW
    }

    function pushX(x) {
      if (ms.max <= ms.min) return
      var t = Math.max(0, Math.min(1, (x - ms.trackX) / ms.trackW))
      var v = ms.min + (ms.max - ms.min) * t
      if (ms.stepSize > 0) v = Math.round(v / ms.stepSize) * ms.stepSize
      ms.value = v
      ms.adjust(ms.value)
    }

    Text {
      anchors.left: parent.left
      anchors.top: parent.top
      text: ms.label
      textFormat: Text.PlainText
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      color: Util.alpha(Color.popups.text, 0.85)
    }

    Text {
      anchors.right: parent.right
      anchors.top: parent.top
      text: ms.format ? ms.format(ms.value) : String(Math.round(ms.value * 100))
      textFormat: Text.PlainText
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      color: Util.alpha(Color.popups.text, 0.55)
    }

    Item {
      id: msTrack
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.topMargin: Style.space(20)
      width: ms.trackW
      height: ms.trackH + ms.knobW

      Rectangle {
        id: msRail
        y: Math.round((ms.trackH + ms.knobW) / 2 - ms.trackH / 2)
        width: parent.width
        height: ms.trackH
        radius: ms.trackH / 2
        color: Util.alpha(Color.popups.text, 0.18)
      }

      Rectangle {
        y: msRail.y
        width: ms.fillW
        height: ms.trackH
        radius: ms.trackH / 2
        color: Color.accent
      }

      Rectangle {
        width: ms.knobW
        height: ms.knobW
        radius: ms.knobW / 2
        x: ms.knobX
        y: Math.round((ms.trackH + ms.knobW) / 2 - ms.knobW / 2)
        color: msDrag.pressed ? Qt.lighter(Color.accent, 1.1) : Color.accent
        border.width: Math.max(1, Style.space(1))
        border.color: Util.alpha(Color.popups.text, 0.4)
      }

      MouseArea {
        id: msDrag
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onPressed: function(mouse) { ms.pushX(mouse.x) }
        onPositionChanged: function(mouse) { if (pressed) ms.pushX(mouse.x) }
        onReleased: ms.committed()
      }
    }
  }

  component MiniToggle: Item {
    id: mt

    property string label: ""
    property bool checked: false
    signal toggled(bool value)

    implicitHeight: Style.space(26)

    Text {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: mt.label
      textFormat: Text.PlainText
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      color: Util.alpha(Color.popups.text, 0.85)
    }

    Rectangle {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(34)
      height: Style.space(18)
      radius: height / 2
      color: mt.checked ? Color.accent : Util.alpha(Color.popups.text, 0.18)
      Behavior on color { ColorAnimation { duration: 120 } }

      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        x: mt.checked
          ? parent.width - width - Math.max(2, Style.space(1))
          : Math.max(2, Style.space(1))
        width: Style.space(14)
        height: Style.space(14)
        radius: width / 2
        color: "#ffffff"
        Behavior on x { NumberAnimation { duration: 120 } }
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: {
          mt.checked = !mt.checked
          mt.toggled(mt.checked)
        }
      }
    }
  }

  component WorkspaceCard: Item {
    id: wcard

    required property var ws
    property var shell: null
    property var desktopEntries: []
    property bool realIcons: false
    property bool focused: false

    signal activate(var ws)

    readonly property real previewHeight: Math.round(wcard.width * 9 / 16)

    readonly property color focusedBorder: wcard.realIcons ? "transparent" : Color.accent
    readonly property color idleBorder: "transparent"
    readonly property color borderColor: wcard.focused ? focusedBorder : idleBorder
    readonly property int borderWidth: Math.max(2, Style.space(2))

    // With real icons the card is a bare, background-free tile (macOS-Dock
    // style); selection is shown by the strip's triangle marker instead.
    readonly property color previewBackground: wcard.realIcons
      ? "transparent"
      : (wcard.focused ? Color.foreground : Color.background)
    readonly property color previewForeground: wcard.realIcons
      ? Color.popups.text
      : (wcard.focused ? Color.background : Color.popups.text)
    readonly property color imageTint: {
      var tint = IconModel.fallbackIconTint(wcard.previewForeground, wcard.previewBackground)
      return Qt.rgba(tint.r, tint.g, tint.b, tint.a)
    }

    // Let the icons grow to fill the whole preview cell. A single app gets the
    // full height/width; multiple apps are packed as large as they fit.
    readonly property int iconGap: Math.max(1, Style.space(2))
    readonly property int iconPad: wcard.appCount <= 1 ? 0 : Math.max(1, Style.space(2))

    readonly property var appList: wcard.buildAppList(wcard.ws)
    readonly property int appCount: wcard.appList.length

    readonly property int iconColumns: {
      var n = wcard.appCount
      if (n <= 1) return 1
      var w = Math.max(1, wcardPreview.width - wcard.iconPad * 2)
      var h = Math.max(1, wcardPreview.height - wcard.iconPad * 2)
      return Math.max(1, Math.ceil(Math.sqrt(n * (w / h))))
    }

    readonly property int iconSize: {
      var n = wcard.appCount
      if (n <= 0) return 0
      if (n === 1) return Math.max(1, Math.floor(Math.min(wcardPreview.width, wcardPreview.height)))
      var w = Math.max(1, wcardPreview.width - wcard.iconPad * 2)
      var h = Math.max(1, wcardPreview.height - wcard.iconPad * 2)
      var cols = wcard.iconColumns
      var rows = Math.max(1, Math.ceil(n / cols))
      var size = Math.floor(Math.min(
        (w - (cols - 1) * wcard.iconGap) / cols,
        (h - (rows - 1) * wcard.iconGap) / rows
      ))
      return Math.max(6, size)
    }

    function buildAppList(ws) {
      var out = []
      var seen = {}
      if (!ws || !ws.windows) return out

      for (var i = 0; i < ws.windows.length; i++) {
        var w = ws.windows[i]
        if (!w) continue
        var id = (typeof w.appId === "string") ? w.appId.trim() : ""
        if (id.length === 0 && w.wayland && typeof w.wayland.appId === "string") {
          id = w.wayland.appId.trim()
        }

        var title = (typeof w.title === "string") ? w.title.trim() : ""
        var initialTitle = (typeof w.initialTitle === "string") ? w.initialTitle.trim() : ""

        // Keying on appId alone merges every shell plugin window into one card,
        // because they all report the class of the single Quickshell process.
        // Windows with no usable title still collapse onto the class key.
        var identity = initialTitle.length > 0 ? initialTitle : title
        var key = (identity.length > 0 ? id + "|" + identity : id).toLowerCase()
        if (seen[key]) continue
        seen[key] = true

        out.push({
          appId: id,
          member: {
            title: title,
            initialTitle: initialTitle,
            className: id,
            initialClass: id,
            iconCandidates: id.length > 0 ? [id] : []
          }
        })
      }
      return out
    }

    function genericIconSource() {
      return String(Quickshell.iconPath("application-x-executable", true) || "")
    }

    function desktopEntry(member) {
      var entry = IconModel.matchDesktopEntry(member, wcard.desktopEntries)
      var candidates = wcard.iconCandidates(member)
      if (entry) return entry

      for (var i = 0; i < candidates.length && !entry; i++) {
        var candidate = String(candidates[i] || "").trim()
        if (!candidate) continue

        try {
          entry = DesktopEntries.byId(candidate)
            || DesktopEntries.byId(candidate + ".desktop")
            || DesktopEntries.heuristicLookup(candidate)
        } catch (error) {}
      }

      return entry
    }

    function actualIcon(source, genericSource) {
      var value = String(source || "")
      return value.length > 0 && value !== genericSource ? source : ""
    }

    function iconCandidates(member) {
      member = member && typeof member === "object" ? member : {}

      var input = (Array.isArray(member.iconCandidates) ? member.iconCandidates.slice() : [])
      var titles = typeof IconModel.memberTitleCandidates === "function"
        ? IconModel.memberTitleCandidates(member)
        : []
      for (var t = 0; t < titles.length; t++) input.push(titles[t])

      var out = []
      for (var i = 0; i < input.length; i++) {
        var candidate = String(input[i] || "").trim()
        if (!candidate) continue
        // "org.quickshell" resolves to the Quickshell logo for every shell
        // plugin; it is a host class, never an app identity.
        if (typeof IconModel.isRuntimeClass === "function" && IconModel.isRuntimeClass(candidate)) continue
        if (out.indexOf(candidate) === -1) out.push(candidate)
      }
      return out
    }

    function iconSource(member, entry) {
      if (entry === undefined) entry = wcard.desktopEntry(member)
      var candidates = wcard.iconCandidates(member)
      var genericSource = wcard.genericIconSource()

      if (entry && entry.icon) {
        if (wcard.shell && wcard.shell.appLibrary
            && typeof wcard.shell.appLibrary.iconSource === "function") {
          var libraryIcon = wcard.actualIcon(
            wcard.shell.appLibrary.iconSource(entry.icon),
            genericSource
          )
          if (libraryIcon) return libraryIcon
        }

        var entryIcon = wcard.actualIcon(Quickshell.iconPath(String(entry.icon), true), genericSource)
        if (entryIcon) return entryIcon
      }

      for (var j = 0; j < candidates.length; j++) {
        var classIconCandidate = String(candidates[j] || "").trim()
        if (!classIconCandidate) continue
        var classIcon = wcard.actualIcon(Quickshell.iconPath(classIconCandidate, true), genericSource)
        if (classIcon) return classIcon
      }

      return ""
    }

    implicitHeight: wcard.previewHeight + wcard.borderWidth * 2
    implicitWidth: wcard.width

    BorderSurface {
      id: wcardBorder
      anchors.top: parent.top
      anchors.horizontalCenter: parent.horizontalCenter
      width: wcard.width
      height: wcard.previewHeight + wcard.borderWidth * 2
      radius: Style.cornerRadius
      color: wcard.realIcons ? "transparent" : Util.alpha(Color.background, 0.6)
      borderSpec: Border.flat(wcard.borderColor, wcard.borderWidth)
      clip: true

      Item {
        id: wcardPreview
        anchors.top: parent.top
        anchors.topMargin: wcardBorder.contentTopInset
        anchors.left: parent.left
        anchors.leftMargin: wcardBorder.contentLeftInset
        width: wcardBorder.width - wcardBorder.contentLeftInset - wcardBorder.contentRightInset
        height: wcard.previewHeight
        clip: true

        Rectangle {
          anchors.fill: parent
          color: wcard.previewBackground
        }

        GridLayout {
          anchors.centerIn: parent
          columns: wcard.iconColumns
          columnSpacing: wcard.iconGap
          rowSpacing: wcard.iconGap

          Repeater {
            model: wcard.appList

            delegate: Item {
              id: appIcon
              required property var modelData
              readonly property var member: modelData.member
              readonly property var entry: wcard.desktopEntry(member)
              // Real-icon mode skips the Nerd Font glyph mapping entirely and
              // renders the desktop-entry icon at full color; there is no
              // generic glyph fallback when no icon image can be resolved.
              readonly property bool useRealIcons: wcard.realIcons === true
              readonly property string mappedGlyph: useRealIcons
                ? ""
                : IconModel.appGlyph(member, entry)
              readonly property var imageSource: mappedGlyph.length === 0
                ? wcard.iconSource(member, entry)
                : ""
              readonly property string glyph: mappedGlyph
              readonly property int iconPixelRatio: Math.max(1, Math.round(Screen.devicePixelRatio))

              width: wcard.iconSize
              height: wcard.iconSize

              OpticalGlyph {
                anchors.centerIn: parent
                width: parent.width
                height: parent.height
                visible: appIcon.glyph.length > 0
                text: appIcon.glyph
                color: wcard.previewForeground
                fontFamily: "JetBrainsMono Nerd Font"
                fontSize: appIcon.height
              }

              Image {
                id: appImage
                anchors.fill: parent
                visible: appIcon.glyph.length === 0
                fillMode: Image.PreserveAspectFit
                sourceSize.width: Math.max(1, Math.round(width * appIcon.iconPixelRatio))
                sourceSize.height: Math.max(1, Math.round(height * appIcon.iconPixelRatio))
                asynchronous: true
                smooth: true
                source: appIcon.imageSource
                layer.enabled: visible
                layer.effect: MultiEffect {
                  colorization: appIcon.useRealIcons ? 0.0 : 1.0
                  colorizationColor: wcard.imageTint
                }
              }
            }
          }
        }
      }

      // Urgent marker: a small dot in the card's top-right corner. The old
      // per-card workspace number is gone; focus is shown by the strip arrow.
      Rectangle {
        visible: wcard.ws && wcard.ws.urgent
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: Math.max(2, Style.space(3))
        width: Math.max(4, Style.space(6))
        height: width
        radius: width / 2
        color: Color.urgent
      }

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton
        onClicked: function(mouse) {
          // Left click on workspace card: show window list mini menu
          root.openWsWindowMenu(wcard.ws, mouse)
        }
      }
    }
  }
}
