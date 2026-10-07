// Launch-usage store for the strip's smart app menu.
//
// A plain JSON object `{ "<desktop-id>": { "count": <int>, "last": <ms epoch> } }`
// is kept under ~/.local/state so the menu's ordering survives a reboot. Every
// function here is pure: it reads a store and returns a brand-new one. QML drops
// in-place writes into objects held by `var` properties now and then, so the
// caller assigns the returned value wholesale instead of poking at the old one.

var VERSION = 1

// An installed app set is a few hundred entries at most, but a long-lived
// machine accumulates stale desktop ids (uninstalled apps, renamed .desktop
// files). Anything past the cap is dropped oldest-first on every write.
var MAX_TRACKED = 400

function emptyStore() {
  return ({ version: VERSION, entries: ({}) })
}

function isPlainObject(value) {
  return !!value && typeof value === "object" && !Array.isArray(value)
}

function boundedInt(value, fallback) {
  var n = Number(value)
  if (!isFinite(n)) return fallback
  // Math.round before the clamp: a float like 3.7 would otherwise survive as a
  // fractional launch count forever.
  n = Math.round(n)
  if (n < 0) return 0
  return n > 2147483647 ? 2147483647 : n
}

// Timestamps are milliseconds since the epoch (~1.79e12 today), well past the
// 32-bit range, so they get their own clamp. Capping them like a count would
// flatten every entry to 2147483647 and destroy the recency order.
function boundedTime(value, fallback) {
  var n = Number(value)
  if (!isFinite(n)) return fallback
  n = Math.round(n)
  if (n < 0) return 0
  return n > Number.MAX_SAFE_INTEGER ? Number.MAX_SAFE_INTEGER : n
}

function normalizeRecord(raw) {
  if (!isPlainObject(raw)) return null
  var count = boundedInt(raw.count, 0)
  var last = boundedTime(raw.last, 0)
  // A record with neither a launch nor a timestamp carries no ordering
  // information at all; keeping it would only bloat the file.
  if (count === 0 && last === 0) return null
  return { count: count, last: last }
}

function normalizeId(value) {
  var id = String(value === undefined || value === null ? "" : value).trim()
  if (id.slice(-8) === ".desktop") id = id.slice(0, -8)
  return id
}

// Tolerant reader: anything unparseable, or shaped wrong, yields an empty store
// rather than taking the menu down. A corrupt state file must never be fatal.
function parse(raw) {
  var text = String(raw || "").trim()
  if (!text) return emptyStore()

  var payload
  try {
    payload = JSON.parse(text)
  } catch (e) {
    return emptyStore()
  }
  if (!isPlainObject(payload)) return emptyStore()

  // Accept both the wrapped `{version, entries}` form and a bare id->record
  // map, so a hand-edited file is not silently dropped.
  var source = isPlainObject(payload.entries) ? payload.entries : payload
  var entries = ({})

  for (var key in source) {
    var id = normalizeId(key)
    if (!id || id === "version") continue
    var record = normalizeRecord(source[key])
    if (record) entries[id] = record
  }

  return { version: VERSION, entries: prune(entries) }
}

// Oldest-first cap on the stored map, so the file cannot grow without bound.
function prune(entries) {
  var ids = []
  for (var id in entries) {
    if (Object.prototype.hasOwnProperty.call(entries, id)) ids.push(id)
  }
  if (ids.length <= MAX_TRACKED) return entries

  ids.sort(function(a, b) {
    var la = (entries[a] && entries[a].last) || 0
    var lb = (entries[b] && entries[b].last) || 0
    if (la !== lb) return la - lb
    return a < b ? -1 : (a > b ? 1 : 0)
  })

  var kept = ({})
  for (var i = ids.length - MAX_TRACKED; i < ids.length; i++) kept[ids[i]] = entries[ids[i]]
  return kept
}

function serialize(store) {
  var entries = store && isPlainObject(store.entries) ? store.entries : ({})
  return JSON.stringify({ version: VERSION, entries: prune(entries) }, null, 2) + "\n"
}

function recordOf(store, id) {
  var key = normalizeId(id)
  if (!key || !store || !isPlainObject(store.entries)) return null
  var raw = store.entries[key]
  return normalizeRecord(raw)
}

// Bumps an app's launch count and stamps it as the most recent one. Returns a
// fresh store; the caller assigns it to its `var` property.
function record(store, id, nowMs) {
  var key = normalizeId(id)
  if (!key) return store || emptyStore()

  var source = store && isPlainObject(store.entries) ? store.entries : ({})
  var previous = normalizeRecord(source[key]) || { count: 0, last: 0 }
  var now = boundedTime(nowMs, 0)

  var entries = ({})
  for (var existing in source) {
    if (!Object.prototype.hasOwnProperty.call(source, existing)) continue
    var record = normalizeRecord(source[existing])
    if (record) entries[normalizeId(existing)] = record
  }

  // A clock that jumped backwards must not make this app look older than it is;
  // `last` only ever moves forward.
  entries[key] = {
    count: Math.min(previous.count + 1, 2147483647),
    last: Math.max(previous.last, now)
  }

  return { version: VERSION, entries: prune(entries) }
}

function forget(store, id) {
  var key = normalizeId(id)
  if (!key || !store || !isPlainObject(store.entries)) return store || emptyStore()
  if (!store.entries[key]) return store

  var entries = ({})
  for (var existing in store.entries) {
    if (existing === key) continue
    if (Object.prototype.hasOwnProperty.call(store.entries, existing)) entries[existing] = store.entries[existing]
  }
  return { version: VERSION, entries: entries }
}

// Ordering for the empty-query grid: everything ever launched first, most
// recent on top, with the launch count as the tiebreak for two apps opened in
// the same millisecond. Apps never launched follow, alphabetically, so a fresh
// machine still shows a stable, scannable list.
function compareByUsage(a, b, usage) {
  var ra = recordOf(usage, a && a.id)
  var rb = recordOf(usage, b && b.id)
  var la = ra ? ra.last : 0
  var lb = rb ? rb.last : 0

  if (la !== lb) return lb - la
  var ca = ra ? ra.count : 0
  var cb = rb ? rb.count : 0
  if (ca !== cb) return cb - ca

  var na = String((a && a.name) || "").toLowerCase()
  var nb = String((b && b.name) || "").toLowerCase()
  if (na < nb) return -1
  if (na > nb) return 1
  return 0
}

// Rows are the plain `{ id, name, ... }` objects the menu builds. Returns a new
// array; the input array is never reordered in place.
function rank(rows, usage) {
  var list = Array.isArray(rows) ? rows.slice() : []
  list.sort(function(a, b) { return compareByUsage(a, b, usage) })
  return list
}

// True once the app has been launched through this menu at least once.
function isKnown(usage, id) {
  return recordOf(usage, id) !== null
}

if (typeof module !== "undefined") {
  module.exports = {
    VERSION: VERSION,
    MAX_TRACKED: MAX_TRACKED,
    emptyStore: emptyStore,
    parse: parse,
    prune: prune,
    serialize: serialize,
    recordOf: recordOf,
    record: record,
    forget: forget,
    compareByUsage: compareByUsage,
    rank: rank,
    isKnown: isKnown
  }
}