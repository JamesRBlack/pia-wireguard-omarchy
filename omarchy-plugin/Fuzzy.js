.pragma library

// Fuzzy matching for the server list, in the spirit of fzf/fzy: the query's
// characters must appear in order, and a match scores higher when they start
// words or run together, and lower for gaps and long names. Space-separated
// words in the query must all match ("uk lon").
//
// prepare() lower-cases each entry once. filter() rejects non-matches with a
// linear subsequence scan and runs the O(query x name) scoring only on the
// rest, reusing its buffers.

var BONUS_START = 10      // first character of the name
var BONUS_WORD = 8        // first character after a separator
var BONUS_RUN = 5         // directly follows the previous matched character
var PENALTY_GAP = 1       // per character skipped between matches
var PENALTY_LEAD = 0.5    // per character before the first match
var SEPARATORS = " _-()/."

// Cheap pre-check: is `q` a subsequence of `t` at all? Most entries fail
// here, so the scoring below runs only for real candidates.
function isSubsequence(q, t) {
  var j = 0
  for (var i = 0; i < q.length; i++) {
    j = t.indexOf(q.charAt(i), j)
    if (j < 0) return false
    j++
  }
  return true
}

// Scratch rows reused across calls instead of allocated per entry.
var bufLen = 0, prevD, prevM, curD, curM
function ensureBuffers(m) {
  if (m <= bufLen) return
  bufLen = Math.max(m, 64)
  prevD = new Float64Array(bufLen); prevM = new Float64Array(bufLen)
  curD = new Float64Array(bufLen); curM = new Float64Array(bufLen)
}

// Best score for matching `q` as a subsequence of `t` (both lower case), or
// -Infinity when it does not match. D[j]: best score with q[i] matched at t[j].
// M[j]: best score with q[0..i] matched at or before t[j], gaps charged.
function score(q, t) {
  var n = q.length, m = t.length
  if (n === 0) return 0
  if (n > m || !isSubsequence(q, t)) return -Infinity
  ensureBuffers(m)
  var pD = prevD, pM = prevM, cD = curD, cM = curM, tmp
  for (var i = 0; i < n; i++) {
    var qc = q.charCodeAt(i)
    var best = -Infinity
    for (var j = 0; j < m; j++) {
      var d = -Infinity
      if (qc === t.charCodeAt(j)) {
        var bonus = j === 0 ? BONUS_START : (SEPARATORS.indexOf(t.charAt(j - 1)) >= 0 ? BONUS_WORD : 0)
        if (i === 0) d = bonus - j * PENALTY_LEAD
        else if (j > 0) d = Math.max(pM[j - 1] + bonus, pD[j - 1] + BONUS_RUN + bonus)
      }
      cD[j] = d
      best = Math.max(best - PENALTY_GAP, d)
      cM[j] = best
    }
    tmp = pD; pD = cD; cD = tmp
    tmp = pM; pM = cM; cM = tmp
  }
  return pM[m - 1]
}

// [{id, name}] -> entries carrying their lower-cased search text.
function prepare(regions) {
  var out = []
  for (var i = 0; i < regions.length; i++) {
    var r = regions[i]
    out.push({ id: r.id, name: r.name, country: r.country || "", key: (r.name + " " + r.id).toLowerCase() })
  }
  return out
}

// Entries matching every word of `query`, best first. An empty query keeps
// the original order.
function filter(entries, query) {
  var words = String(query).toLowerCase().split(/\s+/).filter(function(w) { return w.length > 0 })
  if (words.length === 0) return entries.slice()
  var hits = []
  for (var i = 0; i < entries.length; i++) {
    var total = 0
    for (var w = 0; w < words.length; w++) {
      var s = score(words[w], entries[i].key)
      if (s === -Infinity) { total = -Infinity; break }
      total += s
    }
    if (total !== -Infinity) hits.push({ entry: entries[i], score: total })
  }
  hits.sort(function(a, b) {
    return b.score - a.score || a.entry.key.length - b.entry.key.length || (a.entry.key < b.entry.key ? -1 : 1)
  })
  return hits.map(function(h) { return h.entry })
}
