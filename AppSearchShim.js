var AppSearch = Qt.include("/usr/share/omarchy/shell/services/AppSearch.js")

function entryName(entry) { return AppSearch.entryName(entry) }
function entrySubtext(entry) { return AppSearch.entrySubtext(entry) }

function sortedEntries(values, query) {
  var q = String(query || "").trim()
  var rows = []
  for (var i = 0; i < values.length; i++) {
    var entry = values[i]
    if (!entry || entry.noDisplay) continue
    var name = entryName(entry)
    if (!name) continue
    var score = AppSearch.fuzzyScore(entry, q)
    if (score < 0) continue
    rows.push({ entry: entry, score: score, key: AppSearch.entrySortKey(entry), name: name.toLowerCase() })
  }
  rows.sort(function(a,b){
    if (q && a.score !== b.score) return b.score - a.score
    if (a.key < b.key) return -1
    if (a.key > b.key) return 1
    if (a.name < b.name) return -1
    if (a.name > b.name) return 1
    return 0
  })
  return rows
}
