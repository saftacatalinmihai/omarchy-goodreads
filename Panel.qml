import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Goodreads in the bar. The pill shows how many books sit on your chosen shelf
// (currently-reading by default); the panel is a small four-view browser:
//
//   shelves -> every shelf on your profile, with counts
//   shelf   -> the books on one shelf, with your rating and the average
//   search  -> Goodreads book search
//   book    -> one book's details plus community reviews
//
// All network work happens in bin/goodreads-cli (see its docstring for why
// Goodreads is read the way it is). This file only launches it, parses the
// JSON it prints, and draws the result.
//
// Every Text here sets `textFormat: Text.PlainText`, without exception. Titles,
// authors, blurbs, reviews, reviewer names and shelf labels are all strings
// Goodreads controls, and Qt's default AutoText promotes anything that looks
// like markup to rich text — which renders tags and fetches embedded resources
// such as <img src>. Static labels carry it too, so that the rule is "every
// Text", with no judgement call left for the next edit to get wrong.
Panel {
  id: root
  // The bar overwrites this with the entry id from shell.json, so it is always
  // the real plugin id at runtime — which is what `omarchy bar set` needs.
  moduleName: "safta.goodreads"
  ipcTarget: "goodreads"
  manageIpc: false

  // ---- theme ----
  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.5)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property int pad: Style.spacing.popupPadding

  readonly property string glyph: "\uf02d"  // nf-fa-book

  // ---- config ----
  // Connect writes the id into shell.json through `omarchy bar set`, but the
  // config round-trip takes a moment; the override makes the panel usable the
  // instant the id is known and is simply shadowed once the setting catches up.
  property string userIdOverride: ""
  readonly property string userId: userIdOverride !== ""
                                   ? userIdOverride
                                   : String(setting("userId", "")).trim()
  readonly property string rssKey: String(setting("rssKey", "")).trim()
  readonly property string defaultShelf: String(setting("defaultShelf", "currently-reading")).trim()
                                         || "currently-reading"
  readonly property int perPage: Math.max(5, Math.min(100, parseInt(setting("perPage", 30), 10) || 30))
  readonly property int reviewCount: Math.max(3, Math.min(30, parseInt(setting("reviewCount", 10), 10) || 10))
  readonly property int refreshSec: Math.max(120, parseInt(setting("refreshSec", 900), 10) || 900)
  readonly property bool showCovers: String(setting("showCovers", "On")).toLowerCase() !== "off"
  readonly property bool configured: userId !== ""

  // Absolute path to the fetcher that ships next to this file. Process wants a
  // path, not a URL, and argv means nothing here is shell-quoted.
  readonly property string cliPath: String(Qt.resolvedUrl("bin/goodreads-cli")).replace(/^file:\/\//, "")

  // ---- state ----
  // One of "shelves", "shelf", "search", "book". backView is where the ← key
  // and button return to; there is only ever one level to go back to, so a
  // single slot beats a stack here.
  property string view: "shelves"
  property string backView: ""

  property var shelves: []
  property string shelfName: ""
  property string shelfTitle: ""
  property string shelfUrl: ""
  property var books: []
  property int shelfPage: 1

  property string query: ""
  property var results: []

  // Live search. Typing searches on its own once there is enough of a query to
  // be worth a request; Enter just skips the wait. The minimum keeps one- and
  // two-letter prefixes — which match half of Goodreads — from costing a fetch,
  // and the debounce collapses a burst of keystrokes into a single one.
  readonly property int searchMinChars: 3
  readonly property int searchDebounceMs: 350
  property string pendingQuery: ""
  property string lastSearched: ""

  // What is in the box right now. Filtering the list you are looking at is
  // local and free, so it runs on every keystroke from the first letter; the
  // Goodreads request behind it is what waits for the debounce and the
  // three-letter minimum.
  property string filterText: ""
  readonly property bool filtering: filterText !== ""

  // The shelf view shows one page at a time, but a filter that only searched
  // the visible page would answer "you don't own that" about books sitting on
  // page 2. So the first keystroke pulls the whole shelf once, 100 at a time,
  // and the filter runs against that. The CLI caches it, so leaving and
  // returning to a shelf costs nothing.
  property var shelfAll: []
  property string shelfAllShelf: ""
  property bool shelfAllLoading: false
  property int shelfAllPage: 1
  readonly property int shelfAllPageSize: 100
  readonly property int shelfAllMaxPages: 12

  // Filter against the whole shelf once it is here, and against the page that
  // is already on screen until then, so typing is never blocked on a fetch.
  readonly property var shelfSource: shelfAll.length > 0 ? shelfAll : books
  readonly property var filteredBooks: Model.filterBooks(shelfSource, filterText)
  readonly property var filteredShelves: Model.filterShelves(shelves, filterText)

  // The row the book view was opened from, so a details fetch that only
  // returned reviews still has a title and cover to show.
  property var pendingBook: null
  property var detail: ({})
  property var reviews: []
  property bool detailPartial: false
  property bool descriptionExpanded: false

  property int barCount: -1
  property string errorText: ""
  property string statusText: ""

  // ---- connect flow ----
  // Goodreads retired its API (and with it OAuth) in 2020, so there is no
  // sign-in to perform. What the panel actually needs is the numeric user id,
  // and the browser is the only thing that knows it: Connect opens the profile
  // page and watches the clipboard for the address the user copies back.
  property bool connecting: false
  property string connectMessage: ""
  property string connectedName: ""
  property string lastClipboard: ""
  property int connectTicksLeft: 0
  // The browser is only summoned when the clipboard cannot already answer the
  // question, and only once per Connect.
  property bool connectOpenPending: false
  property bool connectBrowserOpened: false
  readonly property int connectPollMs: 700
  readonly property int connectTimeoutSec: 300

  // Just the book. The shelf count is still fetched and kept — it heads the
  // tooltip and the panel — but in the bar itself a bare number next to an icon
  // reads as noise, so the pill stays a single glyph.
  readonly property string pillText: glyph
  readonly property bool busy: shelvesProc.running || shelfProc.running
                               || searchProc.running || bookProc.running

  readonly property string viewTitle: {
    switch (view) {
    case "shelf": return Model.prettyShelf(shelfName).toUpperCase()
    case "search": return "SEARCH"
    case "book": return "BOOK"
    default: return "BOOKSHELVES"
    }
  }

  // The Goodreads page behind whatever is on screen, for the ↗ button.
  readonly property string externalUrl: {
    switch (view) {
    case "shelf": return shelfUrl
    case "book": return detail.url || (pendingBook ? pendingBook.url : "")
    case "search": return "https://www.goodreads.com/search?q=" + encodeURIComponent(query)
    default: return "https://www.goodreads.com/user/show/" + userId
    }
  }

  // ---- fetching ----
  // Every call goes through the same argv builder so the CLI path, the cache
  // flag, and the user id are in one place.
  function cli(args, fresh) {
    var argv = [root.cliPath]
    if (fresh) argv.push("--no-cache")
    return argv.concat(args)
  }

  function loadShelves(fresh) {
    if (!root.configured) return
    shelvesProc.running = false
    shelvesProc.command = root.cli(["shelves", "--user", root.userId], fresh === true)
    shelvesProc.running = true
  }

  function openShelf(name, fresh) {
    if (!root.configured) return
    root.view = "shelf"
    root.backView = "shelves"
    root.shelfName = name
    root.shelfPage = 1
    root.books = []
    if (root.shelfAllShelf !== name) root.forgetWholeShelf()
    loadShelf(fresh === true)
  }

  // Books you have finished are most interesting by when you read them;
  // everything else by when you added it.
  function shelfSort() {
    return root.shelfName === "read" ? "date_read" : "date_added"
  }

  function shelfArgs(shelf, page, perPage) {
    var args = ["shelf", "--user", root.userId, "--shelf", shelf,
                "--per-page", String(perPage), "--page", String(page),
                "--sort", root.shelfSort()]
    if (root.rssKey !== "") args = args.concat(["--key", root.rssKey])
    return args
  }

  // Pull the whole of the shelf on screen, one 100-book page at a time, so the
  // filter can speak for the entire shelf rather than the page. Idempotent:
  // asking again for a shelf already loaded (or loading) does nothing.
  function ensureWholeShelf() {
    if (root.view !== "shelf" || root.shelfName === "" || !root.configured) return
    if (root.shelfAllShelf === root.shelfName) return
    root.shelfAllShelf = root.shelfName
    root.shelfAll = []
    root.shelfAllPage = 1
    root.shelfAllLoading = true
    root.fetchShelfAllPage()
  }

  function fetchShelfAllPage() {
    shelfAllProc.running = false
    shelfAllProc.command = root.cli(
      root.shelfArgs(root.shelfAllShelf, root.shelfAllPage, root.shelfAllPageSize), false)
    shelfAllProc.running = true
  }

  function forgetWholeShelf() {
    shelfAllProc.running = false
    root.shelfAll = []
    root.shelfAllShelf = ""
    root.shelfAllLoading = false
  }

  function loadShelf(fresh) {
    var args = root.shelfArgs(root.shelfName, root.shelfPage, root.perPage)
    shelfProc.running = false
    shelfProc.command = root.cli(args, fresh === true)
    shelfProc.running = true
    root.statusText = "loading " + root.shelfName + "…"
  }

  function stepShelfPage(delta) {
    var next = root.shelfPage + delta
    if (next < 1) return
    // The RSS feed answers a page past the end with an empty list; refusing to
    // step forward off a short page keeps you from walking into that.
    if (delta > 0 && root.books.length < root.perPage) return
    root.shelfPage = next
    loadShelf(false)
  }

  function runSearch(text, fresh) {
    var q = String(text || "").trim()
    if (q === "") return
    searchDebounce.stop()
    root.query = q
    root.lastSearched = q
    // A view that already lists things keeps its own list and gains a second,
    // clearly labelled section of Goodreads hits underneath. Only the book
    // view, which has no list to narrow, hands over to the results view.
    if (root.view === "book") {
      root.backView = root.view
      root.view = "search"
    }
    root.results = []
    searchProc.running = false
    searchProc.command = root.cli(["search", "--query", q, "--limit", "20"], fresh === true)
    searchProc.running = true
    root.statusText = "searching…"
  }

  // Called on every keystroke. Nothing here talks to the network directly; it
  // only decides whether a search is worth scheduling.
  function scheduleSearch(text) {
    var q = String(text || "").trim()
    root.pendingQuery = q
    root.filterText = q
    searchDebounce.stop()
    if (q === "") {
      // Emptying the field drops the filter. On the dedicated results view
      // there is nothing left to look at, so it also takes you back.
      root.lastSearched = ""
      root.results = []
      if (root.view === "search") root.goBack()
      return
    }
    // Filtering a shelf has to speak for the whole shelf, not the page.
    if (root.view === "shelf") root.ensureWholeShelf()
    if (q.length < root.searchMinChars) return
    if (q === root.lastSearched) return
    searchDebounce.restart()
  }

  // Enter: same search, without waiting out the debounce.
  function searchNow(text) {
    var q = String(text || "").trim()
    if (q.length < root.searchMinChars) return
    root.runSearch(q, false)
  }

  function openBook(book, fresh) {
    if (!book || !book.bookId) return
    root.backView = root.view === "book" ? root.backView : root.view
    root.view = "book"
    root.pendingBook = book
    root.detail = Model.mergeKnown({}, book)
    root.reviews = []
    root.detailPartial = false
    root.descriptionExpanded = false
    bookProc.running = false
    bookProc.command = root.cli(["book", "--id", String(book.bookId),
                                 "--reviews", String(root.reviewCount)], fresh === true)
    bookProc.running = true
    root.statusText = "loading reviews…"
  }

  function goBack() {
    if (root.backView === "" || root.view === "shelves") { root.view = "shelves"; return }
    root.view = root.backView
    root.backView = root.view === "shelves" ? "" : "shelves"
  }

  // Reload whatever is on screen, bypassing the on-disk cache.
  function refresh() {
    root.errorText = ""
    switch (root.view) {
    case "shelf": root.forgetWholeShelf(); loadShelf(true); if (root.filtering) root.ensureWholeShelf(); break
    case "search": runSearch(root.query, true); break
    case "book": if (root.pendingBook) openBook(root.pendingBook, true); break
    default: loadShelves(true)
    }
  }

  // Start watching for the profile link. The clipboard is checked once up
  // front: someone who already copied their profile URL is connected without
  // touching the browser at all.
  function startConnect() {
    root.connecting = true
    root.connectedName = ""
    root.errorText = ""
    root.lastClipboard = ""
    root.connectBrowserOpened = false
    root.connectTicksLeft = Math.ceil(root.connectTimeoutSec * 1000 / root.connectPollMs)
    root.connectMessage = "Checking the clipboard…"
    // Look before summoning anything: a profile link already sitting in the
    // clipboard connects on this one click, with no browser window at all.
    root.connectOpenPending = true
    root.pollClipboard()
  }

  // /review/list is the "My Books" page: signed in, Goodreads redirects it to
  // /review/list/<id>-<slug>, so the address bar ends up holding exactly the id
  // this panel needs. Signed out it lands on the sign-in page and continues
  // there afterwards. (/user/show without an id just 404s — it is not a
  // "my profile" shortcut.)
  function openGoodreadsProfile() {
    if (root.connectBrowserOpened) return
    root.connectBrowserOpened = true
    root.connectMessage = "Opened your Goodreads books page — copy its address (Ctrl+L, then Ctrl+C) and it lands here."
    root.openExternally("https://www.goodreads.com/review/list")
  }

  function cancelConnect() {
    root.connecting = false
    root.connectMessage = ""
  }

  function pollClipboard() {
    if (clipProc.running) return
    clipProc.command = ["wl-paste", "--no-newline", "--type", "text/plain"]
    clipProc.running = true
  }

  // Called with whatever the clipboard holds. Only a string that looks like a
  // Goodreads user URL costs a network round trip; everything else is ignored
  // silently, because the clipboard belongs to the user, not to this panel.
  function considerClipboard(text) {
    var value = String(text || "")
    if (value === root.lastClipboard) return
    root.lastClipboard = value
    if (Model.userIdIn(value) === "") return
    if (whoamiProc.running) return
    root.connectMessage = "Checking that profile…"
    whoamiProc.command = root.cli(["whoami", "--url", value], true)
    whoamiProc.running = true
  }

  // Persist the id the same way the settings UI would, so it survives a
  // restart and shows up as this widget's setting rather than private state.
  function adoptUser(id, name) {
    root.userIdOverride = String(id)
    root.connecting = false
    root.connectedName = String(name || "")
    root.connectMessage = root.connectedName !== ""
                          ? "Connected as " + root.connectedName
                          : "Connected"
    saveProc.command = ["omarchy-bar", "set", root.moduleName, "userId", String(id)]
    saveProc.running = true
    root.loadShelves(true)
    root.openShelf(root.defaultShelf, true)
  }

  function openExternally(url) {
    if (!url) return
    Quickshell.execDetached(["omarchy-launch-browser", String(url)])
  }

  // Shared failure handling: a non-zero exit means the CLI printed
  // {"error": ...} (or died); either way the panel says so rather than
  // silently showing an empty list.
  function handleFailure(raw, code, what) {
    var parsed = Model.parseResponse(raw)
    root.errorText = parsed.error !== "" ? parsed.error
                                         : (what + " failed (exit " + code + ")")
    root.statusText = ""
  }

  // ---- processes ----
  Process {
    id: shelvesProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      var raw = shelvesProc.stdout.text
      var parsed = Model.parseResponse(raw)
      if (code !== 0 || !parsed.ok) { root.handleFailure(raw, code, "shelf list"); return }
      root.errorText = ""
      root.shelves = Model.shelvesOf(parsed.data)
      // The pill counts the configured shelf; -1 keeps it blank when that
      // shelf is missing or the profile hides counts.
      var count = -1
      for (var i = 0; i < root.shelves.length; i++) {
        if (root.shelves[i].name === root.defaultShelf) count = root.shelves[i].count
      }
      root.barCount = count
    }
  }

  Process {
    id: shelfProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      var raw = shelfProc.stdout.text
      var parsed = Model.parseResponse(raw)
      root.statusText = ""
      if (code !== 0 || !parsed.ok) { root.handleFailure(raw, code, "shelf"); return }
      root.errorText = ""
      root.books = Model.booksOf(parsed.data)
      root.shelfTitle = String(parsed.data.title || "")
      root.shelfUrl = String(parsed.data.url || "")
    }
  }

  Process {
    id: searchProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      var raw = searchProc.stdout.text
      var parsed = Model.parseResponse(raw)
      root.statusText = ""
      if (code !== 0 || !parsed.ok) { root.handleFailure(raw, code, "search"); return }
      root.errorText = ""
      root.results = Model.resultsOf(parsed.data)
    }
  }

  Process {
    id: bookProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      var raw = bookProc.stdout.text
      var parsed = Model.parseResponse(raw)
      root.statusText = ""
      if (code !== 0 || !parsed.ok) { root.handleFailure(raw, code, "book"); return }
      root.errorText = ""
      root.detailPartial = !!parsed.data.partial
      root.detail = Model.mergeKnown(Model.bookOf(parsed.data), root.pendingBook)
      root.reviews = Model.reviewsOf(parsed.data)
    }
  }

  Process {
    id: clipProc
    stdout: StdioCollector { waitForEnd: true }
    // A clipboard holding an image (or nothing) makes wl-paste exit non-zero;
    // that is a normal state to poll through, not an error to report.
    onExited: function(code) {
      var text = code === 0 ? clipProc.stdout.text : ""
      var candidate = Model.userIdIn(text)
      if (code === 0) root.considerClipboard(text)
      if (root.connectOpenPending) {
        root.connectOpenPending = false
        // A candidate is being confirmed; leave the browser out of it unless
        // that confirmation comes back empty-handed.
        if (candidate === "") root.openGoodreadsProfile()
      }
    }
  }

  Process {
    id: whoamiProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      var parsed = Model.parseResponse(whoamiProc.stdout.text)
      if (code !== 0 || !parsed.ok) {
        root.connectMessage = "Couldn't reach Goodreads to confirm that profile — copy the link again."
        root.openGoodreadsProfile()
        return
      }
      if (!parsed.data.connected) {
        // Not a profile link; keep waiting rather than nagging.
        root.connectMessage = "That link has no user id in it. Open your profile page and copy its address."
        root.openGoodreadsProfile()
        return
      }
      root.adoptUser(parsed.data.userId, parsed.data.name)
    }
  }

  Process {
    id: saveProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      if (code !== 0) root.errorText = "Connected, but saving the id to the bar config failed."
    }
  }

  Process {
    id: shelfAllProc
    stdout: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      var parsed = Model.parseResponse(shelfAllProc.stdout.text)
      if (code !== 0 || !parsed.ok) {
        // The page filter still works; it just cannot promise it saw the whole
        // shelf, which the section header says for itself.
        root.shelfAllLoading = false
        return
      }
      var page = Model.booksOf(parsed.data)
      root.shelfAll = root.shelfAll.concat(page)
      // A short page is the last page. The cap is a backstop against a shelf
      // (or a bug) that would otherwise page forever.
      if (page.length >= root.shelfAllPageSize && root.shelfAllPage < root.shelfAllMaxPages) {
        root.shelfAllPage += 1
        root.fetchShelfAllPage()
      } else {
        root.shelfAllLoading = false
      }
    }
  }

  Timer {
    id: searchDebounce
    interval: root.searchDebounceMs
    onTriggered: root.runSearch(root.pendingQuery, false)
  }

  Timer {
    id: connectTimer
    interval: root.connectPollMs
    running: root.connecting
    repeat: true
    onTriggered: {
      if (root.connectTicksLeft <= 0) {
        root.connecting = false
        root.connectMessage = "Gave up waiting. Copy your profile address from the browser and press Connect again."
        return
      }
      root.connectTicksLeft -= 1
      root.pollClipboard()
    }
  }

  // Keep the pill honest while the panel is closed. Goodreads rate-limits
  // scrapers hard, so this leans on the CLI's on-disk cache (no --no-cache)
  // and defaults to a quarter of an hour.
  Timer {
    interval: root.refreshSec * 1000
    running: root.configured
    repeat: true
    triggeredOnStart: true
    onTriggered: root.loadShelves(false)
  }

  onOpenedChanged: if (opened) {
    if (root.shelves.length === 0) root.loadShelves(false)
    if (root.view === "shelves" && root.books.length === 0 && root.configured)
      root.openShelf(root.defaultShelf, false)
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    function connect(): string { root.open(); root.startConnect(); return "ok" }
    function shelf(name: string): string { root.open(); root.openShelf(name, false); return name }
    // Fills the box rather than firing a bare query, so a scripted search
    // behaves exactly like a typed one — the shelf on screen narrows too, and
    // the text is there to refine.
    function search(text: string): string {
      root.open()
      searchField.text = String(text)
      return text
    }
    function book(id: string): string {
      root.open()
      // No row to carry over here, so the view fills in entirely from the fetch.
      root.openBook({ bookId: String(id), title: "", author: "", cover: "", url: "" }, false)
      return id
    }
  }

  // One book row, shared by the shelf list and the Goodreads list so the two
  // sections of a filtered view are visibly the same kind of thing.
  component BookRow: Item {
    id: bookRow

    required property var modelData

    width: parent ? parent.width : 0
    height: Math.max(root.showCovers ? Style.space(56) : 0,
                     rowText.implicitHeight + Style.spacing.sm * 2)

    Rectangle {
      anchors.fill: parent
      radius: Style.space(6)
      color: bookHover.hovered ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.07) : "transparent"
      TapHandler { onTapped: root.openBook(bookRow.modelData, false) }
    }
    HoverHandler { id: bookHover; cursorShape: Qt.PointingHandCursor }

    // Covers come off Goodreads' CDN; a failed or slow load leaves the slot
    // empty rather than stalling or shifting the row.
    Image {
      id: cover
      visible: root.showCovers && bookRow.modelData.cover !== ""
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
      height: Style.space(48)
      width: Style.space(32)
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      cache: true
      source: root.showCovers ? bookRow.modelData.cover : ""
    }

    Column {
      id: rowText
      anchors.left: cover.visible ? cover.right : parent.left
      anchors.leftMargin: Style.spacing.md
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.xxs

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: bookRow.modelData.title
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }
      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: bookRow.modelData.author !== ""
        text: bookRow.modelData.author
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
      Text {
        textFormat: Text.PlainText
        width: parent.width
        // Your own rating leads when you have one — that is the interesting
        // number on your own shelf — with the crowd's average following it.
        text: (bookRow.modelData.userRating > 0
               ? Model.stars(bookRow.modelData.userRating) + "   "
               : "") + Model.ratingLine(bookRow.modelData)
        color: bookRow.modelData.userRating > 0 ? root.accent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }

  // ---- bar pill ----
  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.pillText
    active: root.opened
    tooltipText: !root.configured
                 ? "Goodreads — click to connect your account"
                 : (root.barCount >= 0
                    ? root.barCount + " on " + Model.prettyShelf(root.defaultShelf).toLowerCase()
                    : "Goodreads")
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton || buttonCode === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  // ---- popup ----
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight + root.pad * 2, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The search field owns the keyboard whenever it has focus; typing a
      // query is the common case, so it starts focused and only hands keys
      // back when you click away from it.
      blocked: searchField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onActivateRequested: root.refresh()
      onReturnRequested: root.goBack()

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight + root.pad * 2
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          x: root.pad
          y: root.pad
          width: flick.width - root.pad * 2
          spacing: Style.spacing.md

          // ---- header ----
          Item {
            width: parent.width
            height: Style.spacing.controlHeight

            Text {
              textFormat: Text.PlainText
              id: backBtn
              visible: root.view !== "shelves"
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "\uf060"  // nf-fa-arrow_left
              color: backHover.hovered ? root.fg : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              TapHandler { onTapped: root.goBack() }
              HoverHandler { id: backHover; cursorShape: Qt.PointingHandCursor }
            }

            Text {
              textFormat: Text.PlainText
              anchors.left: backBtn.visible ? backBtn.right : parent.left
              anchors.leftMargin: backBtn.visible ? Style.spacing.md : 0
              anchors.verticalCenter: parent.verticalCenter
              text: root.viewTitle
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.letterSpacing: 1.5
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              id: openBtn
              anchors.right: refreshBtn.left
              anchors.rightMargin: Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              visible: root.externalUrl !== ""
              text: "\uf08e"  // nf-fa-external_link
              color: openHover.hovered ? root.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              TapHandler { onTapped: root.openExternally(root.externalUrl) }
              HoverHandler { id: openHover; cursorShape: Qt.PointingHandCursor }
            }

            Text {
              textFormat: Text.PlainText
              id: refreshBtn
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: "\uf021"  // nf-fa-refresh
              color: root.busy ? root.accent : (refreshHover.hovered ? root.fg : root.dim)
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              TapHandler { onTapped: root.refresh() }
              HoverHandler { id: refreshHover; cursorShape: Qt.PointingHandCursor }
            }
          }

          // ---- connect card (shown until an account is attached) ----
          Column {
            visible: !root.configured
            width: parent.width
            spacing: Style.spacing.md

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Connect your Goodreads account to read your shelves here."
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: !root.connecting
              text: "Goodreads shut its API down in 2020, so there is no sign-in to do — "
                    + "the panel just needs the address of your profile page."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Button {
              visible: !root.connecting
              text: "Connect Goodreads"
              bordered: true
              foreground: root.fg
              accent: root.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.startConnect()
            }

            // ---- waiting for the copied link ----
            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: root.connecting
              text: root.connectMessage
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: root.connecting
              text: "Watching the clipboard… " + Math.ceil(root.connectTicksLeft * root.connectPollMs / 1000) + "s"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Row {
              visible: root.connecting
              spacing: Style.spacing.md

              Button {
                text: "Check clipboard now"
                bordered: true
                foreground: root.fg
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                // A fresh look bypasses the "unchanged since last poll" guard,
                // so pressing this after re-copying always re-checks.
                onClicked: { root.lastClipboard = ""; root.pollClipboard() }
              }
              Button {
                text: "Cancel"
                bordered: true
                foreground: root.fg
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onClicked: root.cancelConnect()
              }
            }

            // The last thing Connect said, kept visible after it stops so a
            // timeout or a rejected link explains itself.
            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: !root.connecting && root.connectMessage !== ""
              text: root.connectMessage
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---- search box ----
          TextField {
            id: searchField
            visible: root.configured
            width: parent.width
            placeholderText: "Search Goodreads"
            foreground: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            onTextChanged: root.scheduleSearch(searchField.text)
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.searchNow(searchField.text)
                event.accepted = true
              } else if (event.key === Qt.Key_Escape) {
                root.close()
                event.accepted = true
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.configured && root.connectedName !== ""
            width: parent.width
            text: "Connected as " + root.connectedName
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          // ---- status / error ----
          Text {
            textFormat: Text.PlainText
            visible: root.errorText !== ""
            width: parent.width
            text: root.errorText
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            visible: root.statusText !== "" && root.errorText === ""
            width: parent.width
            text: root.statusText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          // ================================================ shelves view ====
          Column {
            visible: root.view === "shelves" && root.configured
            width: parent.width
            spacing: 0

            Repeater {
              model: root.filteredShelves
              delegate: Item {
                id: shelfRow
                required property var modelData
                width: column.width
                height: Style.spacing.controlHeight + Style.spacing.xs

                Rectangle {
                  anchors.fill: parent
                  radius: Style.space(6)
                  color: shelfHover.hovered ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.07)
                                            : "transparent"
                  TapHandler { onTapped: root.openShelf(shelfRow.modelData.name, false) }
                }
                HoverHandler { id: shelfHover; cursorShape: Qt.PointingHandCursor }

                Text {
                  textFormat: Text.PlainText
                  id: shelfGlyph
                  anchors.left: parent.left
                  anchors.leftMargin: Style.spacing.sm
                  anchors.verticalCenter: parent.verticalCenter
                  text: shelfRow.modelData.icon
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
                Text {
                  textFormat: Text.PlainText
                  anchors.left: shelfGlyph.right
                  anchors.leftMargin: Style.spacing.md
                  anchors.right: shelfCount.left
                  anchors.rightMargin: Style.spacing.md
                  anchors.verticalCenter: parent.verticalCenter
                  text: shelfRow.modelData.label
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }
                Text {
                  textFormat: Text.PlainText
                  id: shelfCount
                  anchors.right: parent.right
                  anchors.rightMargin: Style.spacing.sm
                  anchors.verticalCenter: parent.verticalCenter
                  text: shelfRow.modelData.count >= 0 ? String(shelfRow.modelData.count) : ""
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.filteredShelves.length === 0 && !root.busy && root.errorText === ""
              width: parent.width
              topPadding: Style.space(12)
              text: root.filtering
                    ? "No shelf matches “" + root.filterText + "”."
                    : "No shelves found for user " + root.userId + "."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              horizontalAlignment: Text.AlignHCenter
            }
          }

          // ================================ shelf list, filtered or paged ===
          Column {
            visible: root.view === "shelf" && root.configured
            width: parent.width
            spacing: Style.spacing.xs

            // While filtering, say which shelf is being narrowed and how far
            // the search actually reaches — a filter that quietly covered only
            // the visible page would be worse than no filter at all.
            PanelSectionHeader {
              visible: root.filtering
              text: Model.prettyShelf(root.shelfName).toUpperCase() + "  ·  "
                    + (root.shelfAllLoading
                       ? "checking the whole shelf…"
                       : root.filteredBooks.length + (root.filteredBooks.length === 1 ? " match" : " matches"))
              foreground: root.fg
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.filtering ? root.filteredBooks : root.books
              delegate: BookRow {}
            }

            Text {
              textFormat: Text.PlainText
              visible: root.filtering && !root.shelfAllLoading && root.filteredBooks.length === 0
              width: parent.width
              topPadding: Style.space(6)
              text: "Nothing on this shelf matches “" + root.filterText + "”."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
            }

            // Shelf paging. The RSS feed hands out one page at a time, so
            // "next" is only offered while the current page came back full.
            // A filter spans the whole shelf, so pages stop meaning anything.
            Item {
              visible: !root.filtering
                       && (root.shelfPage > 1 || root.books.length >= root.perPage)
              width: parent.width
              height: Style.spacing.controlHeight

              Button {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "◀ prev"
                bordered: true
                enabled: root.shelfPage > 1
                foreground: root.fg
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onClicked: root.stepShelfPage(-1)
              }
              Text {
                textFormat: Text.PlainText
                anchors.centerIn: parent
                text: "page " + root.shelfPage
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              Button {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "next ▶"
                bordered: true
                enabled: root.books.length >= root.perPage
                foreground: root.fg
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onClicked: root.stepShelfPage(1)
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: !root.busy && !root.filtering && root.errorText === ""
                       && root.books.length === 0
              width: parent.width
              topPadding: Style.space(12)
              text: "Nothing on this shelf" + (root.shelfPage > 1 ? " page." : ".")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              horizontalAlignment: Text.AlignHCenter
            }
          }

          // ==================================== all of Goodreads (search) ===
          // On a list view this is the second section, under its own heading,
          // so it is never mistaken for part of your shelf. On the results
          // view it is the only thing there and needs no heading.
          Column {
            visible: root.configured
                     && (root.view === "search"
                         || (root.filtering && root.results.length > 0
                             && (root.view === "shelf" || root.view === "shelves")))
            width: parent.width
            spacing: Style.spacing.xs

            PanelSeparator {
              width: parent.width
              visible: root.view !== "search"
              foreground: root.fg
            }

            PanelSectionHeader {
              visible: root.view !== "search"
              text: "ALL OF GOODREADS"
              foreground: root.fg
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.results
              delegate: BookRow {}
            }

            Text {
              textFormat: Text.PlainText
              visible: root.view === "search" && !root.busy && root.errorText === ""
                       && root.results.length === 0
              width: parent.width
              topPadding: Style.space(12)
              text: root.query === ""
                    ? "Type at least " + root.searchMinChars + " letters above."
                    : "No results for “" + root.query + "”."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              horizontalAlignment: Text.AlignHCenter
            }
          }

          // =================================================== book view ====
          Column {
            visible: root.view === "book"
            width: parent.width
            spacing: Style.spacing.md

            // ---- hero: cover beside the title block ----
            Item {
              width: parent.width
              height: Math.max(bigCover.visible ? bigCover.height : 0, titleBlock.implicitHeight)

              Image {
                id: bigCover
                visible: root.showCovers && String(root.detail.cover || "") !== ""
                anchors.left: parent.left
                anchors.top: parent.top
                height: Style.space(108)
                width: Style.space(72)
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                cache: true
                source: root.showCovers ? String(root.detail.cover || "") : ""
              }

              Column {
                id: titleBlock
                anchors.left: bigCover.visible ? bigCover.right : parent.left
                anchors.leftMargin: bigCover.visible ? Style.spacing.lg : 0
                anchors.right: parent.right
                anchors.top: parent.top
                spacing: Style.spacing.xs

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: String(root.detail.title || "")
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                  wrapMode: Text.WordWrap
                  maximumLineCount: 3
                  elide: Text.ElideRight
                }
                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  visible: String(root.detail.author || "") !== ""
                  text: String(root.detail.author || "")
                        + (root.detail.series ? "  ·  " + root.detail.series : "")
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }
                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  visible: root.detail.averageRating > 0
                  text: Model.stars(Math.round(root.detail.averageRating)) + "   "
                        + Model.ratingLine(root.detail)
                  color: root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  visible: (root.detail.genres || []).length > 0
                  text: (root.detail.genres || []).join(" · ")
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                  maximumLineCount: 2
                  elide: Text.ElideRight
                }
                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  visible: String(root.detail.publisher || "") !== ""
                           || String(root.detail.format || "") !== ""
                  text: [root.detail.format, root.detail.publisher,
                         root.detail.publicationYear].filter(function(v) { return !!v }).join("  ·  ")
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }
            }

            // ---- description, folded to four lines until clicked ----
            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: String(root.detail.description || "") !== ""
              text: String(root.detail.description || "")
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              maximumLineCount: root.descriptionExpanded ? 999 : 4
              elide: Text.ElideRight
              TapHandler { onTapped: root.descriptionExpanded = !root.descriptionExpanded }
              HoverHandler { cursorShape: Qt.PointingHandCursor }
            }

            // The fallback path can only reach the reviews widget, so say why
            // the metadata above is thinner than usual instead of looking broken.
            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: root.detailPartial
              text: "Goodreads is throttling the full book page; showing the reviews widget instead."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            PanelSeparator {
              width: parent.width
              visible: root.reviews.length > 0
            }

            PanelSectionHeader {
              visible: root.reviews.length > 0
              text: "COMMUNITY REVIEWS"
              foreground: root.fg
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.reviews
              delegate: Column {
                id: reviewRow
                required property var modelData
                width: column.width
                spacing: Style.spacing.xxs
                bottomPadding: Style.spacing.md

                Item {
                  width: parent.width
                  height: who.implicitHeight

                  Text {
                    textFormat: Text.PlainText
                    id: who
                    anchors.left: parent.left
                    text: Model.oneLine(reviewRow.modelData.reviewer, 28)
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                  Text {
                    textFormat: Text.PlainText
                    anchors.left: who.right
                    anchors.leftMargin: Style.spacing.md
                    anchors.right: parent.right
                    text: (reviewRow.modelData.rating > 0
                           ? Model.stars(reviewRow.modelData.rating) + "  " : "")
                          + reviewRow.modelData.when
                          + (reviewRow.modelData.likes > 0
                             ? "  ·  " + Model.compactCount(reviewRow.modelData.likes) + " likes" : "")
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                // Reviews run long; six lines is enough to judge one, and the
                // row opens the full review on Goodreads when tapped.
                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: reviewRow.modelData.spoiler
                        ? "(marked as a spoiler — open on Goodreads to read it)"
                        : reviewRow.modelData.text
                  color: reviewRow.modelData.spoiler ? root.dim : root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                  maximumLineCount: 6
                  elide: Text.ElideRight
                  TapHandler {
                    onTapped: root.openExternally(reviewRow.modelData.reviewerUrl
                                                  || root.detail.url)
                  }
                  HoverHandler { cursorShape: Qt.PointingHandCursor }
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: !root.busy && root.reviews.length === 0 && root.errorText === ""
              width: parent.width
              topPadding: Style.space(12)
              text: "No reviews came back for this book."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              horizontalAlignment: Text.AlignHCenter
            }
          }
        }
      }
    }
  }
}
