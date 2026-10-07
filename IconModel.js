// App icon resolution for the Speaker Corners workspace cards.
//
// Faithful subset of Omarchy's HUD model so the workspace cards show the same
// app icons as the HUD: a Nerd Font glyph from Omarchy's default menu mapping,
// falling back to a matched desktop entry image and finally to a generic glyph.

// nf-md-application: used only after both mapped glyph and image lookup fail.
var GENERIC_APP_GLYPH = "\udb82\udcc6"

// Window classes that belong to the shell runtime rather than to an app. Every
// Omarchy shell plugin (OmaWhatsApp, Olook, the Spotify panel, omafile, the dev
// gallery, ...) is a window inside one Quickshell process, so the compositor
// reports this single class for all of them — and /usr/share/applications ships
// a matching org.quickshell.desktop whose icon is the Quickshell logo. Matching
// a class like this against a desktop entry always succeeds against the wrong
// entry, so these windows are resolved by their window title instead.
var RUNTIME_APP_CLASSES = {
  "org.quickshell": true,
  "quickshell": true
}

function isRuntimeClass(value) {
  return RUNTIME_APP_CLASSES[compactIdentity(value)] === true
}

// Normalize the table itself so a stray separator or case in a key cannot
// silently make a runtime class look like an ordinary app class.
;(function () {
  var normalized = {}
  for (var key in RUNTIME_APP_CLASSES) normalized[compactIdentity(key)] = true
  RUNTIME_APP_CLASSES = normalized
})()


// App glyphs already assigned by Omarchy's default menu and provided by its
// default JetBrainsMono Nerd Font package. Keep matching exact so a web app
// class such as "chrome-chatgpt.com__-Default" does not become Chrome.
var APP_GLYPHS = {
  "1password": "\udb82\udc81",
  "alacritty": "\ue795",
  "app.zen_browser.zen": "\udb81\udd9f",
  "bitwarden": "\udb81\udff5",
  "brave": "\udb81\udd9f",
  "brave-browser": "\udb81\udd9f",
  "brave-origin": "\udb81\udd9f",
  "chrome": "\udb80\udeaf",
  "chromium": "\uf268",
  "chromium-browser": "\uf268",
  "code": "\ue8da",
  "code-oss": "\ue8da",
  "com.1password.1password": "\udb82\udc81",
  "com.bitwarden.desktop": "\udb81\udff5",
  "com.brave.browser": "\udb81\udd9f",
  "com.google.chrome": "\udb80\udeaf",
  "com.heroicgameslauncher.hgl": "\udb85\udcdf",
  "com.microsoft.edge": "\udb80\udde9",
  "com.mitchellh.ghostty": "\ue795",
  "com.spotify.client": "\udb81\udcc7",
  "com.valvesoftware.steam": "\uf1b6",
  "com.visualstudio.code": "\ue8da",
  "com.vscodium.codium": "\ue8da",
  "dropbox": "\ue707",
  "edge": "\udb80\udde9",
  "firefox": "\udb80\ude39",
  "firefox-esr": "\udb80\ude39",
  "foot": "\ue795",
  "ghostty": "\ue795",
  "google-chrome": "\udb80\udeaf",
  "google-chrome-stable": "\udb80\udeaf",
  "heroic": "\udb85\udcdf",
  "heroic games launcher": "\udb85\udcdf",
  "io.neovim.nvim": "\ue6ae",
  "kitty": "\ue795",
  "lutris": "\uef94",
  "microsoft-edge": "\udb80\udde9",
  "microsoft-edge-stable": "\udb80\udde9",
  "minecraft": "\udb80\udf73",
  "minecraft-launcher": "\udb80\udf73",
  "net.lutris.lutris": "\uef94",
  "neovim": "\ue6ae",
  "nvim": "\ue6ae",
  "org.codeberg.dnkl.foot": "\ue795",
  "org.libretro.retroarch": "\udb82\udfc9",
  "org.mozilla.firefox": "\udb80\ude39",
  "org.omarchy.nvim": "\ue6ae",
  "org.signal.signal": "\udb82\udf79",
  "retroarch": "\udb82\udfc9",
  "signal": "\udb82\udf79",
  "signal-desktop": "\udb82\udf79",
  "spotify": "\udb81\udcc7",
  "steam": "\uf1b6",
  "vim": "\ue62b",
  "visual studio code": "\ue8da",
  "vscode": "\ue8da",
  "xbox cloud gaming": "\ued3e",
  "zen": "\udb81\udd9f",
  "zen-browser": "\udb81\udd9f"
}

var ENTRY_ONLY_APP_GLYPHS = {
  "com.docker.desktop": "\uf21f",
  "docker": "\uf21f"
}

function finiteNumber(value, fallback) {
  var parsed = Number(value)
  return isFinite(parsed) ? parsed : fallback
}

function clamp(value, minimum, maximum) {
  return Math.max(minimum, Math.min(maximum, value))
}

function nonEmptyString(value) {
  if (value === undefined || value === null) return ""
  return String(value).trim()
}

function lowerString(value) {
  return nonEmptyString(value).toLowerCase()
}

function desktopId(value) {
  var id = lowerString(value)
  return id.slice(-8) === ".desktop" ? id.slice(0, -8) : id
}

function compactIdentity(value) {
  return lowerString(value).replace(/[^a-z0-9]+/g, "")
}

function finalIdentityToken(value) {
  var tokens = lowerString(value).split(/[^a-z0-9]+/)
  for (var i = tokens.length - 1; i >= 0; i--) {
    if (tokens[i].length >= 3) return tokens[i]
  }
  return ""
}

function objectString(object, property) {
  try {
    return object ? nonEmptyString(object[property]) : ""
  } catch (error) {
    return ""
  }
}

function memberIdentityCandidates(member) {
  member = member && typeof member === "object" ? member : {}

  var input = Array.isArray(member.iconCandidates) ? member.iconCandidates.slice() : []
  input.push(member.className)
  input.push(member.initialClass)

  var output = []
  for (var i = 0; i < input.length; i++) {
    var candidate = nonEmptyString(input[i])
    if (candidate.length > 0 && output.indexOf(candidate) === -1) output.push(candidate)
  }
  return output
}

// Window titles, in the order they should be trusted. A shell plugin window
// keeps a stable title ("OmaWhatsApp", "Olook", "Omarchy Spotify"), which is
// the only thing that tells those windows apart from one another.
function memberTitleCandidates(member) {
  member = member && typeof member === "object" ? member : {}

  var input = [member.initialTitle, member.title]
  var output = []
  for (var i = 0; i < input.length; i++) {
    var candidate = nonEmptyString(input[i])
    if (candidate.length > 0 && output.indexOf(candidate) === -1) output.push(candidate)
  }
  return output
}

function stringList(value) {
  if (value === undefined || value === null) return []
  if (Array.isArray(value)) return value.map(nonEmptyString).filter(function (item) {
    return item.length > 0
  })
  return nonEmptyString(value).split(/[;,]/).map(nonEmptyString).filter(function (item) {
    return item.length > 0
  })
}

// NoDisplay entries are not launchable apps; they are helper/desktop integration
// files. They are still worth considering last, never first.
function entryHidden(entry) {
  try {
    return !!(entry && entry.noDisplay)
  } catch (error) {
    return false
  }
}

function normalizedAppIdentity(value) {
  var identity = lowerString(value)
  return identity.slice(-8) === ".desktop" ? identity.slice(0, -8) : identity
}

function iconIdentity(value) {
  var identity = lowerString(value).split("?")[0]
  var slash = Math.max(identity.lastIndexOf("/"), identity.lastIndexOf("\\"))
  if (slash >= 0) identity = identity.slice(slash + 1)
  return identity.replace(/\.(?:png|svg|xpm)$/i, "")
}

function appendIdentity(output, value) {
  var identity = normalizedAppIdentity(value)
  if (identity && output.indexOf(identity) === -1) output.push(identity)
}

function entryAppIdentities(entry) {
  var output = []
  appendIdentity(output, objectString(entry, "id"))
  appendIdentity(output, objectString(entry, "startupClass"))
  appendIdentity(output, objectString(entry, "name"))
  appendIdentity(output, executableName(objectString(entry, "execString")))
  appendIdentity(output, iconIdentity(objectString(entry, "icon")))
  return output
}

function memberAppIdentities(member) {
  var input = memberIdentityCandidates(member)
  var output = []
  for (var i = 0; i < input.length; i++) appendIdentity(output, input[i])
  return output
}

function mappedGlyph(identities, mapping) {
  for (var i = 0; i < identities.length; i++) {
    if (Object.prototype.hasOwnProperty.call(mapping, identities[i]))
      return mapping[identities[i]]
  }
  return ""
}

function appGlyph(member, entry) {
  var entryIdentities = entryAppIdentities(entry)
  var glyph = mappedGlyph(entryIdentities, APP_GLYPHS)
    || mappedGlyph(entryIdentities, ENTRY_ONLY_APP_GLYPHS)
  if (glyph) return glyph
  return mappedGlyph(memberAppIdentities(member), APP_GLYPHS)
}

function genericAppGlyph() {
  return GENERIC_APP_GLYPH
}

function colorChannelLuminance(value) {
  var channel = clamp(finiteNumber(value, 0), 0, 1)
  return channel <= 0.03928
    ? channel / 12.92
    : Math.pow((channel + 0.055) / 1.055, 2.4)
}

function colorLuminance(color) {
  color = color && typeof color === "object" ? color : {}
  return 0.2126 * colorChannelLuminance(color.r)
    + 0.7152 * colorChannelLuminance(color.g)
    + 0.0722 * colorChannelLuminance(color.b)
}

function fallbackIconTint(foreground, surface) {
  foreground = foreground && typeof foreground === "object" ? foreground : {}
  surface = surface && typeof surface === "object" ? surface : {}
  var amount = colorLuminance(foreground) < 0.08 && colorLuminance(surface) > 0.35
    ? 0.35
    : 0
  var foregroundRed = clamp(finiteNumber(foreground.r, 0), 0, 1)
  var foregroundGreen = clamp(finiteNumber(foreground.g, 0), 0, 1)
  var foregroundBlue = clamp(finiteNumber(foreground.b, 0), 0, 1)
  var surfaceRed = clamp(finiteNumber(surface.r, 0), 0, 1)
  var surfaceGreen = clamp(finiteNumber(surface.g, 0), 0, 1)
  var surfaceBlue = clamp(finiteNumber(surface.b, 0), 0, 1)

  return {
    r: foregroundRed + (surfaceRed - foregroundRed) * amount,
    g: foregroundGreen + (surfaceGreen - foregroundGreen) * amount,
    b: foregroundBlue + (surfaceBlue - foregroundBlue) * amount,
    a: 1
  }
}

function normalizeWebHost(value) {
  var host = lowerString(value)
    .replace(/^[a-z]+:\/\//, "")
    .replace(/[/:].*$/, "")
    .replace(/^www\./, "")
  return /^[a-z0-9.-]+\.[a-z0-9-]+$/.test(host) ? host : ""
}

function normalizeWebPath(value) {
  var path = lowerString(value)
  if (!path || path === "/") return ""
  path = path.replace(/^[^/]*:\/\//, "")
  var slash = path.indexOf("/")
  if (slash >= 0) path = path.slice(slash)
  if (path.charAt(0) !== "/") path = "/" + path
  return path.replace(/\/+$/, "")
}

function initialTitleWebIdentity(value) {
  var raw = lowerString(value)
  var marker = raw.indexOf("_/")
  if (marker <= 0) return null

  var host = normalizeWebHost(raw.slice(0, marker))
  if (!host) return null
  return {
    host: host,
    path: normalizeWebPath(raw.slice(marker + 1))
  }
}

function classWebIdentity(value) {
  var raw = nonEmptyString(value)
  var match = raw.match(
    /^(?:chrome|chromium|google-chrome|brave(?:-browser)?|microsoft-edge|opera|vivaldi(?:-stable)?|helium)-(.+?)-Default$/i
  )
  if (!match) return null

  var identity = match[1]
  var marker = identity.indexOf("__")
  var host = normalizeWebHost(marker >= 0 ? identity.slice(0, marker) : identity)
  if (!host) return null

  return {
    host: host,
    path: marker >= 0
      ? normalizeWebPath(identity.slice(marker + 2).replace(/_/g, "/"))
      : ""
  }
}

function memberWebIdentity(member) {
  member = member && typeof member === "object" ? member : {}

  var fromTitle = initialTitleWebIdentity(member.initialTitle)
  if (fromTitle) return fromTitle

  var candidates = memberIdentityCandidates(member)
  for (var i = 0; i < candidates.length; i++) {
    var fromClass = classWebIdentity(candidates[i])
    if (fromClass) return fromClass
  }
  return null
}

function execWebIdentity(value) {
  var match = nonEmptyString(value).match(/https?:\/\/([a-z0-9.-]+)(\/[^\s"'%]*)?/i)
  if (!match) return null

  var host = normalizeWebHost(match[1])
  if (!host) return null
  return {
    host: host,
    path: normalizeWebPath(match[2] || "")
  }
}

function executableName(value) {
  var raw = nonEmptyString(value)
  if (!raw) return ""

  var match = raw.match(/^(?:"([^"]+)"|'([^']+)'|([^\s]+))/)
  var executable = match ? (match[1] || match[2] || match[3] || "") : ""
  var slash = executable.lastIndexOf("/")
  if (slash >= 0) executable = executable.slice(slash + 1)
  return desktopId(executable)
}

function webIdentityLabel(identity) {
  if (!identity || !identity.host) return ""

  var ignored = {
    app: true,
    com: true,
    dev: true,
    io: true,
    mail: true,
    net: true,
    org: true,
    tv: true,
    web: true,
    www: true
  }
  var labels = identity.host.split(".")
  for (var i = 0; i < labels.length; i++) {
    if (labels[i].length >= 3 && !ignored[labels[i]]) return labels[i]
  }
  return ""
}

// Tokens that identify an app but appear in too many window titles to be useful
// on their own ("dev", "app", "web"). Matched tokens are dropped so they cannot
// drag an unrelated entry into a match.
var WEAK_TITLE_TOKENS = {
  "app": true,
  "apps": true,
  "dev": true,
  "default": true,
  "file": true,
  "files": true,
  "new": true,
  "old": true,
  "run": true,
  "shell": true,
  "the": true,
  "window": true
}

function meaningfulTokens(value) {
  return lowerString(value).split(/[^a-z0-9]+/).filter(function (token) {
    return token.length >= 3 && WEAK_TITLE_TOKENS[token] !== true
  })
}

// Shell plugin windows are told apart by their window title. Three passes, most
// specific first:
//   1. the title is the entry's Name or id ("Olook" -> olook.desktop)
//   2. the title is the entry's GenericName
//   3. a title token appears in the entry's keywords/categories
//      ("Omarchy Spotify" -> neon-spotify.desktop, Keywords=spotify;music)
// Hidden entries only win when nothing visible matches.
function matchTitleEntry(member, entries) {
  var values = entries && typeof entries.length === "number" ? entries : []
  var titles = memberTitleCandidates(member)
  if (values.length === 0 || titles.length === 0) return null

  var hiddenWinner = null
  var i
  var j

  function betterThan(entry) {
    if (!entryHidden(entry)) return entry
    return hiddenWinner
  }

  for (i = 0; i < titles.length; i++) {
    var titleCompact = compactIdentity(titles[i])
    if (!titleCompact) continue

    for (j = 0; j < values.length; j++) {
      var entry = values[j]
      if (!entry) continue

      if (titleCompact === compactIdentity(objectString(entry, "name"))
          || titleCompact === compactIdentity(desktopId(objectString(entry, "id")))) {
        if (entryHidden(entry)) {
          if (!hiddenWinner) hiddenWinner = entry
        } else {
          return entry
        }
      }
    }
  }

  for (i = 0; i < titles.length; i++) {
    var genericTitle = compactIdentity(titles[i])
    if (!genericTitle) continue

    for (j = 0; j < values.length; j++) {
      var genericEntry = values[j]
      if (!genericEntry || entryHidden(genericEntry)) continue
      if (genericTitle === compactIdentity(objectString(genericEntry, "genericName"))) return genericEntry
    }
  }

  var bestEntry = null
  var bestScore = 0
  for (i = 0; i < titles.length; i++) {
    var tokens = meaningfulTokens(titles[i])
    if (tokens.length === 0) continue

    for (j = 0; j < values.length; j++) {
      var tokenEntry = values[j]
      if (!tokenEntry || entryHidden(tokenEntry)) continue

      // Whole-token comparison only. Substring matching makes a title like
      // "Omarchy shell - dev gallery" match CMake ("Development" contains
      // "dev"), which is a wrong icon rather than no icon.
      var haystack = {}
      var haystackValues = [desktopId(objectString(tokenEntry, "id"))]
        .concat(stringList(tokenEntry.keywords))
        .concat(stringList(tokenEntry.categories))
        .concat(stringList(tokenEntry.name))
      for (var h = 0; h < haystackValues.length; h++) {
        var entryTokens = meaningfulTokens(haystackValues[h])
        for (var e2 = 0; e2 < entryTokens.length; e2++) haystack[entryTokens[e2]] = true
      }

      var score = 0
      for (var k = 0; k < tokens.length; k++) {
        if (haystack[tokens[k]] === true) score++
      }
      if (score > bestScore) {
        bestScore = score
        bestEntry = tokenEntry
      }
    }
  }

  return bestEntry || hiddenWinner
}

function matchDesktopEntry(member, entries) {
  var values = entries && typeof entries.length === "number" ? entries : []
  var candidates = memberIdentityCandidates(member)
  var i
  var j

  // A runtime class says which shell hosts the window, never which app it is.
  // Resolve by title first, and never let the runtime's own desktop entry win
  // on the class below.
  var runtimeClass = false
  for (i = 0; i < candidates.length; i++) {
    if (isRuntimeClass(candidates[i])) {
      runtimeClass = true
      break
    }
  }

  if (runtimeClass) {
    var titleEntry = matchTitleEntry(member, values)
    if (titleEntry) return titleEntry
  }

  for (i = 0; i < candidates.length; i++) {
    var candidateId = desktopId(candidates[i])
    var candidateLower = lowerString(candidates[i])

    for (j = 0; j < values.length; j++) {
      var exactEntry = values[j]
      if (!exactEntry) continue
      if (runtimeClass && isRuntimeClass(candidateId)) continue
      if (desktopId(objectString(exactEntry, "id")) === candidateId
          || lowerString(objectString(exactEntry, "startupClass")) === candidateLower) {
        return exactEntry
      }
    }
  }

  var webIdentity = memberWebIdentity(member)
  if (webIdentity) {
    var bestWebEntry = null
    var bestWebScore = -1

    for (i = 0; i < values.length; i++) {
      var webEntry = values[i]
      if (!webEntry) continue
      var entryIdentity = execWebIdentity(objectString(webEntry, "execString"))
      if (!entryIdentity || entryIdentity.host !== webIdentity.host) continue

      var score = 100
      if (webIdentity.path && entryIdentity.path) {
        if (webIdentity.path === entryIdentity.path) score += 30
        else if (webIdentity.path.indexOf(entryIdentity.path) === 0
            || entryIdentity.path.indexOf(webIdentity.path) === 0) score += 20
      }
      if (score > bestWebScore) {
        bestWebScore = score
        bestWebEntry = webEntry
      }
    }

    if (bestWebEntry) return bestWebEntry

    var webLabel = webIdentityLabel(webIdentity)
    if (webLabel) {
      for (i = 0; i < values.length; i++) {
        var labelEntry = values[i]
        if (!labelEntry) continue
        if (desktopId(objectString(labelEntry, "id")) === webLabel
            || compactIdentity(objectString(labelEntry, "name")) === compactIdentity(webLabel)) {
          return labelEntry
        }
      }
    }
  }

  for (i = 0; i < candidates.length; i++) {
    var candidateCompact = compactIdentity(candidates[i])
    var candidateToken = finalIdentityToken(candidates[i])
    if (!candidateCompact) continue

    for (j = 0; j < values.length; j++) {
      var entry = values[j]
      if (!entry || entryHidden(entry)) continue

      var id = desktopId(objectString(entry, "id"))
      var startup = compactIdentity(objectString(entry, "startupClass"))
      var name = compactIdentity(objectString(entry, "name"))
      var executable = executableName(objectString(entry, "execString"))

      if (candidateCompact === compactIdentity(id)
          || candidateCompact === startup
          || candidateCompact === name
          || candidateCompact === compactIdentity(executable)
          || (candidateToken && (candidateToken === id || candidateToken === executable))) {
        return entry
      }

      if (id && candidateCompact.indexOf(compactIdentity(id)) === 0) {
        var suffix = candidateCompact.slice(compactIdentity(id).length)
        if (suffix === "manager" || suffix === "machine" || suffix === "vm") return entry
      }
    }
  }

  return null
}

if (typeof module !== "undefined") {
  module.exports = {
    appGlyph: appGlyph,
    fallbackIconTint: fallbackIconTint,
    genericAppGlyph: genericAppGlyph,
    isRuntimeClass: isRuntimeClass,
    matchDesktopEntry: matchDesktopEntry,
    matchTitleEntry: matchTitleEntry,
    memberTitleCandidates: memberTitleCandidates
  }
}
