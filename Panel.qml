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

  // An open book rather than fa-book: at bar sizes the closed-book glyph
  // collapses into an indistinct block, while this one still reads as a book.
  readonly property string glyph: "\uf405"  // nf-oct-book

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

  // No separator at all. The bar font is monospaced, so the glyph already sits
  // in a full cell with its own slack; adding a space on top of that reads as a
  // stray number parked next to an unrelated icon rather than as one pill.
  readonly property string pillText: glyph + (barCount >= 0 ? String(barCount) : "")
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
    loadShelf(fresh === true)
  }

  function loadShelf(fresh) {
    var args = ["shelf", "--user", root.userId, "--shelf", root.shelfName,
                "--per-page", String(root.perPage), "--page", String(root.shelfPage),
                "--sort", root.shelfName === "read" ? "date_read" : "date_added"]
    if (root.rssKey !== "") args = args.concat(["--key", root.rssKey])
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
    root.query = q
    root.view = "search"
    root.backView = "shelves"
    root.results = []
    searchProc.running = false
    searchProc.command = root.cli(["search", "--query", q, "--limit", "20"], fresh === true)
    searchProc.running = true
    root.statusText = "searching…"
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
    case "shelf": loadShelf(true); break
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
    function search(text: string): string { root.open(); root.runSearch(text); return text }
    function book(id: string): string {
      root.open()
      // No row to carry over here, so the view fills in entirely from the fetch.
      root.openBook({ bookId: String(id), title: "", author: "", cover: "", url: "" }, false)
      return id
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
              width: parent.width
              text: "Connect your Goodreads account to read your shelves here."
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Text {
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
              width: parent.width
              visible: root.connecting
              text: root.connectMessage
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Text {
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
            placeholderText: "Search Goodreads — Enter"
            foreground: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.runSearch(searchField.text)
                event.accepted = true
              } else if (event.key === Qt.Key_Escape) {
                root.close()
                event.accepted = true
              }
            }
          }

          Text {
            visible: root.configured && root.connectedName !== ""
            width: parent.width
            text: "Connected as " + root.connectedName
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          // ---- status / error ----
          Text {
            visible: root.errorText !== ""
            width: parent.width
            text: root.errorText
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
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
              model: root.shelves
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
              visible: root.shelves.length === 0 && !root.busy && root.errorText === ""
              width: parent.width
              topPadding: Style.space(12)
              text: "No shelves found for user " + root.userId + "."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              horizontalAlignment: Text.AlignHCenter
            }
          }

          // ============================== shelf + search book lists =========
          Column {
            visible: (root.view === "shelf" || root.view === "search") && root.configured
            width: parent.width
            spacing: Style.spacing.xs

            Repeater {
              model: root.view === "shelf" ? root.books : root.results
              delegate: Item {
                id: bookRow
                required property var modelData
                width: column.width
                height: Math.max(root.showCovers ? Style.space(56) : 0,
                                 rowText.implicitHeight + Style.spacing.sm * 2)

                Rectangle {
                  anchors.fill: parent
                  radius: Style.space(6)
                  color: bookHover.hovered ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.07)
                                           : "transparent"
                  TapHandler { onTapped: root.openBook(bookRow.modelData, false) }
                }
                HoverHandler { id: bookHover; cursorShape: Qt.PointingHandCursor }

                // Covers come off Goodreads' CDN; a failed or slow load leaves
                // the slot empty rather than stalling or shifting the row.
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
                    width: parent.width
                    text: bookRow.modelData.title
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }
                  Text {
                    width: parent.width
                    visible: bookRow.modelData.author !== ""
                    text: bookRow.modelData.author
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                  Text {
                    width: parent.width
                    // Your own rating leads when you have one — that is the
                    // interesting number on your own shelf — with the crowd's
                    // average following it.
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
            }

            // Shelf paging. The RSS feed hands out one page at a time, so
            // "next" is only offered while the current page came back full.
            Item {
              visible: root.view === "shelf" && (root.shelfPage > 1 || root.books.length >= root.perPage)
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
              visible: !root.busy && root.errorText === ""
                       && (root.view === "shelf" ? root.books.length === 0 : root.results.length === 0)
              width: parent.width
              topPadding: Style.space(12)
              text: root.view === "shelf"
                    ? "Nothing on this shelf" + (root.shelfPage > 1 ? " page." : ".")
                    : (root.query === "" ? "Type a title or author above." : "No results for “" + root.query + "”.")
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
                    id: who
                    anchors.left: parent.left
                    text: Model.oneLine(reviewRow.modelData.reviewer, 28)
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                  Text {
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
