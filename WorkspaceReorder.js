// Workspace reorder planner for the workspace strip.
//
// Given the workspace IDs in their new visual (left-to-right) order, work out
// the smallest set of ID renames that makes the strip's ID-sorted model match
// that order. Hyprland's `workspace.change_id` swaps a workspace's numeric ID
// in place (windows, tiling, monitor, focus all ride along), but the strip
// always renders workspaces sorted by ascending ID. So "reordering the bar"
// really means reassigning IDs.
//
// Heuristic: keep as many workspaces on their current ID as possible (the
// longest chain of already-increasing IDs whose integer gaps can hold the
// items between them), then fill the remaining slots with the smallest free
// IDs >= 1. Ties between equally long chains go to the one that renames the
// fewest/lowest IDs (smallest sum of new IDs), which is what keeps a single
// drag from touching more than the two cards involved.
//
// Pure: no Hyprland calls, no QML types. computePlan() is unit-testable.
//
// computePlan(ids) -> { newIds: number[], plan: [{from, to}] }
//   ids     IDs currently on the strip, in the order the user dragged them to.
//   newIds  the ID each slot should end up with (aligned with `ids`).
//   plan    only the slots that actually change, as {from, to} pairs.

// Feasibility for a kept anchor: slot i holding id ids[i] needs room for the
// i items before it (IDs 1..i) and for the items between anchors.
function feasibleGap(fromId, toId, slotDistance) {
  return toId > fromId && (toId - fromId) >= slotDistance
}

function triangular(m) {
  return m * (m + 1) / 2
}

function computePlan(ids) {
  var k = (ids || []).length
  if (k <= 1) return { newIds: ids ? ids.slice() : [], plan: [] }

  // dp over anchor slots: keep[i] = most anchors in a chain ending at slot i;
  // cost[i] = sum of newly-assigned IDs for that chain's regions so far.
  var keep = new Array(k)
  var cost = new Array(k)
  var prev = new Array(k)
  for (var i = 0; i < k; i++) {
    keep[i] = -1
    cost[i] = Infinity
    prev[i] = -2
    // Start a fresh chain: slots 0..i-1 become IDs 1..i before the anchor.
    if (ids[i] >= i + 1) {
      keep[i] = 1
      cost[i] = triangular(i)
      prev[i] = -1
    }
    for (var j = 0; j < i; j++) {
      if (keep[j] < 1) continue
      if (!feasibleGap(ids[j], ids[i], i - j)) continue
      var gapCount = i - j - 1
      var regionCost = gapCount * ids[j] + triangular(gapCount)
      var c = keep[j] + 1
      var s = cost[j] + regionCost
      if (c > keep[i] || (c === keep[i] && s < cost[i])) {
        keep[i] = c
        cost[i] = s
        prev[i] = j
      }
    }
  }

  var best = -1
  var bestKeep = -1
  var bestCost = Infinity
  for (var b = 0; b < k; b++) {
    if (keep[b] < 1) continue
    var tail = k - 1 - b
    var total = cost[b] + tail * ids[b] + triangular(tail)
    if (keep[b] > bestKeep || (keep[b] === bestKeep && total < bestCost)) {
      best = b
      bestKeep = keep[b]
      bestCost = total
    }
  }
  if (best < 0) best = k - 1

  var anchors = []
  for (var p = best; p !== -1 && p !== -2; p = prev[p]) anchors.unshift(p)
  if (anchors.length === 0) anchors.push(k - 1)

  var newIds = new Array(k)
  var first = anchors[0]
  for (var a = 0; a < first; a++) newIds[a] = a + 1
  for (var ai = 0; ai < anchors.length; ai++) {
    var idx = anchors[ai]
    newIds[idx] = ids[idx]
    if (ai + 1 < anchors.length) {
      var next = anchors[ai + 1]
      for (var m = idx + 1; m < next; m++) newIds[m] = ids[idx] + (m - idx)
    }
  }
  var last = anchors[anchors.length - 1]
  for (var t = last + 1; t < k; t++) newIds[t] = ids[last] + (t - last)

  var plan = []
  for (var z = 0; z < k; z++) {
    if (newIds[z] !== ids[z]) plan.push({ from: ids[z], to: newIds[z] })
  }
  return { newIds: newIds, plan: plan }
}
