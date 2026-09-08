// Pure helpers for the Goodreads bar widget. No QML imports, so the parsing and
// formatting stay testable on their own and Panel.qml keeps only wiring.
//
// Everything here consumes the JSON that bin/goodreads-cli prints:
//   shelves -> { user, name, profileUrl, shelves: [{name, label, count}] }
//   shelf   -> { shelf, title, url, books: [{bookId, title, author, ...}] }
//   search  -> { query, results: [{bookId, title, author, ...}] }
//   book    -> { partial, book: {...}, reviews: [{reviewer, rating, text, ...}] }

// Parse a CLI response. Returns { ok, data, error } rather than throwing, so a
// caller can render the message instead of an empty panel. A body that carries
// an "error" key is a failure even when the JSON itself parsed.
function parseResponse(raw) {
  var text = String(raw || "").trim()
  if (text === "") return { ok: false, data: null, error: "no answer from goodreads-cli" }
  try {
    var data = JSON.parse(text)
    if (data && data.error) return { ok: false, data: null, error: String(data.error) }
    return { ok: true, data: data, error: "" }
  } catch (e) {
    return { ok: false, data: null, error: "unreadable answer from goodreads-cli" }
  }
}

function shelvesOf(data) {
  if (!data || !Array.isArray(data.shelves)) return []
  var out = []
  for (var i = 0; i < data.shelves.length; i++) {
    var s = data.shelves[i] || {}
    if (!s.name) continue
    out.push({
      name: String(s.name),
      label: prettyShelf(s.label || s.name),
      count: typeof s.count === "number" ? s.count : -1,
      icon: shelfIcon(String(s.name))
    })
  }
  return out
}

function booksOf(data) {
  if (!data || !Array.isArray(data.books)) return []
  var out = []
  for (var i = 0; i < data.books.length; i++) out.push(normalizeBook(data.books[i]))
  return out
}

function resultsOf(data) {
  if (!data || !Array.isArray(data.results)) return []
  var out = []
  for (var i = 0; i < data.results.length; i++) out.push(normalizeBook(data.results[i]))
  return out
}

// One row shape for shelf entries and search hits alike, so the list delegate
// does not have to care which fetch produced it. userRating is 0 for a search
// hit (you have not rated it here) and 1-5 for a rated shelf book.
function normalizeBook(raw) {
  var b = raw || {}
  return {
    bookId: String(b.bookId || ""),
    title: String(b.title || "(untitled)"),
    author: String(b.author || ""),
    cover: String(b.cover || ""),
    url: String(b.url || ""),
    userRating: numberOr(b.userRating, 0),
    averageRating: numberOr(b.averageRating, 0),
    ratingsCount: numberOr(b.ratingsCount, 0),
    numPages: numberOr(b.numPages, 0),
    published: String(b.published || ""),
    readAt: shortDate(b.readAt),
    addedAt: shortDate(b.addedAt),
    review: String(b.review || ""),
    description: String(b.description || "")
  }
}

function bookOf(data) {
  var b = (data && data.book) || {}
  return {
    bookId: String(b.bookId || ""),
    title: String(b.title || ""),
    author: String(b.author || ""),
    authorUrl: String(b.authorUrl || ""),
    series: String(b.series || ""),
    cover: String(b.cover || ""),
    url: String(b.url || ""),
    description: String(b.description || ""),
    genres: Array.isArray(b.genres) ? b.genres.filter(function(g) { return !!g }) : [],
    format: String(b.format || ""),
    numPages: numberOr(b.numPages, 0),
    publisher: String(b.publisher || ""),
    language: String(b.language || ""),
    publicationYear: String(b.publicationYear || ""),
    averageRating: numberOr(b.averageRating, 0),
    ratingsCount: numberOr(b.ratingsCount, 0),
    reviewsCount: numberOr(b.reviewsCount, 0)
  }
}

function reviewsOf(data) {
  if (!data || !Array.isArray(data.reviews)) return []
  var out = []
  for (var i = 0; i < data.reviews.length; i++) {
    var r = data.reviews[i] || {}
    out.push({
      reviewer: String(r.reviewer || "A Goodreads member"),
      reviewerUrl: String(r.reviewerUrl || ""),
      rating: numberOr(r.rating, 0),
      likes: numberOr(r.likes, 0),
      when: String(r.when || ""),
      spoiler: !!r.spoiler,
      text: String(r.text || "")
    })
  }
  return out
}

// A book detail fetch that fell back to the reviews widget carries reviews but
// no metadata. The panel merges the row it navigated from over the top, so the
// header still shows a title and cover instead of blanks.
function mergeKnown(detail, known) {
  if (!known) return detail
  var out = detail
  var fields = ["title", "author", "cover", "url", "description"]
  for (var i = 0; i < fields.length; i++) {
    var f = fields[i]
    if (!out[f] && known[f]) out[f] = known[f]
  }
  if (!out.averageRating && known.averageRating) out.averageRating = known.averageRating
  if (!out.ratingsCount && known.ratingsCount) out.ratingsCount = known.ratingsCount
  if (!out.numPages && known.numPages) out.numPages = known.numPages
  return out
}

// The numeric user id inside a Goodreads profile, shelf, or RSS URL, or "" when
// there is none. Mirrors USER_ID_PATTERNS in bin/goodreads-cli so the clipboard
// watcher can reject the other 99% of copied text without spending a fetch on
// it; the CLI still re-checks and confirms the id against the live profile.
function userIdIn(text) {
  var s = String(text || "")
  var patterns = [
    /goodreads\.com\/user\/show\/(\d+)/,
    /goodreads\.com\/review\/list\/(\d+)/,
    /goodreads\.com\/review\/list_rss\/(\d+)/
  ]
  for (var i = 0; i < patterns.length; i++) {
    var m = s.match(patterns[i])
    if (m) return m[1]
  }
  if (/^\d{2,12}$/.test(s.trim())) return s.trim()
  return ""
}

// ------------------------------------------------------------------- filter

// Fold a string down to something worth comparing: lowercase, accents removed
// where the engine can do it, punctuation and runs of space flattened. Without
// this, searching "dune" misses "Dune:" and searching "les mis" misses
// "Les Misérables".
function matchNorm(text) {
  var s = String(text || "").toLowerCase()
  try {
    // Decompose, then drop the combining marks é -> e.
    s = s.normalize("NFD").replace(/[\u0300-\u036f]/g, "")
  } catch (e) {
    // An engine without String.normalize just compares the accented form.
  }
  return s.replace(/[^a-z0-9]+/g, " ").replace(/^\s+|\s+$/g, "")
}

// Every whitespace-separated term must appear somewhere in the haystack, so
// "herbert dune" finds Dune the same way "dune herbert" does.
function matchesTerms(haystack, query) {
  var hay = matchNorm(haystack)
  var terms = matchNorm(query).split(" ")
  for (var i = 0; i < terms.length; i++) {
    if (terms[i] === "") continue
    if (hay.indexOf(terms[i]) === -1) return false
  }
  return true
}

// Books on a shelf, narrowed by title and author. An empty query returns the
// list untouched so callers can bind to this unconditionally.
function filterBooks(books, query) {
  var list = Array.isArray(books) ? books : []
  if (matchNorm(query) === "") return list
  var out = []
  for (var i = 0; i < list.length; i++) {
    var b = list[i] || {}
    if (matchesTerms(String(b.title || "") + " " + String(b.author || ""), query)) out.push(b)
  }
  return out
}

// The same, for the shelf list itself.
function filterShelves(shelves, query) {
  var list = Array.isArray(shelves) ? shelves : []
  if (matchNorm(query) === "") return list
  var out = []
  for (var i = 0; i < list.length; i++) {
    var s = list[i] || {}
    if (matchesTerms(String(s.label || "") + " " + String(s.name || ""), query)) out.push(s)
  }
  return out
}

// ------------------------------------------------------------------ display

// "currently-reading" -> "Currently reading". Custom shelves keep whatever
// casing their owner gave them beyond the first word.
function prettyShelf(name) {
  var s = String(name || "").replace(/[-_]+/g, " ").trim()
  if (s === "") return ""
  return s.charAt(0).toUpperCase() + s.slice(1)
}

// Nerd Font glyphs for the three shelves every Goodreads account has; anything
// custom gets a generic bookmark.
function shelfIcon(name) {
  switch (String(name)) {
  case "read": return "\uf00c"              // nf-fa-check
  case "currently-reading": return "\uf02d" // nf-fa-book
  case "to-read": return "\uf097"           // nf-fa-bookmark_o
  case "did-not-finish": return "\uf05e"    // nf-fa-ban
  default: return "\uf02e"                  // nf-fa-bookmark
  }
}

// Five glyphs, filled up to `rating`. Half stars are rounded down so a 4.4
// average never looks like a 5.
function stars(rating) {
  var n = Math.max(0, Math.min(5, Math.floor(numberOr(rating, 0))))
  var out = ""
  for (var i = 0; i < 5; i++) out += (i < n) ? "★" : "☆"
  return out
}

// "4.29 ★ · 1.7M ratings" — the one-line stats under a title.
function ratingLine(book) {
  var parts = []
  if (book.averageRating > 0) parts.push(book.averageRating.toFixed(2) + " ★")
  if (book.ratingsCount > 0) parts.push(compactCount(book.ratingsCount) + " ratings")
  if (book.numPages > 0) parts.push(book.numPages + "p")
  if (book.published) parts.push(book.published)
  return parts.join("  ·  ")
}

function compactCount(n) {
  var v = numberOr(n, 0)
  if (v >= 1000000) return (v / 1000000).toFixed(1).replace(/\.0$/, "") + "M"
  if (v >= 1000) return (v / 1000).toFixed(1).replace(/\.0$/, "") + "k"
  return String(v)
}

// RFC-822-ish dates ("Mon, 07 Sep 2026 23:05:05 -0700") come out of the RSS
// feed; show them as "Sep 2026". An unparseable or empty value yields "" so
// callers can just test for truthiness.
function shortDate(value) {
  var s = String(value || "").trim()
  if (s === "") return ""
  var d = new Date(s)
  if (isNaN(d.getTime())) return s.slice(0, 16)
  var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  return months[d.getMonth()] + " " + d.getFullYear()
}

function oneLine(text, max) {
  var s = String(text || "").replace(/\s+/g, " ").trim()
  if (s.length <= max) return s
  return s.slice(0, max - 1) + "…"
}

function numberOr(value, fallback) {
  var n = Number(value)
  return isFinite(n) ? n : fallback
}
