import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.dlpwaters.ebook-reader"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property string helperPath: ""
  property var books: []
  property var visibleBooks: []
  property var readerSettings: ({})
  property string lastBookId: ""
  property bool converterAvailable: false
  property bool loading: false
  property bool settingsMode: false
  property string libraryOutput: ""
  property string actionOutput: ""
  property string statusText: ""
  property bool statusError: false

  readonly property var barIdentity: hostWidget || root
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color muted: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.58)
  readonly property color subtle: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.075)
  readonly property color accent: Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property int desiredWidth: Style.space(760)
  readonly property int maximumHeight: Style.space(820)

  function fileUrl(path) {
    if (!path) return ""
    return "file://" + encodeURI(String(path))
  }

  function open() {
    root.controller.show()
    settingsMode = false
    refresh(false)
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }
  function close() { root.controller.hide() }
  function toggle() { root.opened ? close() : open() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function refresh(force) {
    if (libraryProc.running || helperPath === "") return
    loading = true
    libraryOutput = ""
    libraryProc.command = force
      ? [helperPath, "library", "--refresh", "--limit", "1000", "--deadline", "8"]
      : [helperPath, "library", "--limit", "1000", "--deadline", "8"]
    libraryProc.running = true
  }

  function parseLibrary(exitCode) {
    loading = false
    var payload = null
    try { payload = JSON.parse(libraryOutput) } catch (error) {}
    if (exitCode !== 0 || !payload || !payload.ok) {
      showStatus(payload && payload.error ? payload.error : "Your library could not be scanned.", true)
      return
    }
    books = payload.books || []
    readerSettings = payload.settings || ({})
    lastBookId = String(payload.lastBookId || "")
    converterAvailable = payload.converterAvailable === true
    rebuildVisibleBooks()
    if (payload.truncated === true)
      showStatus("Showing the first 1,000 books. Narrow the selected library folder for a smaller shelf.", false)
    var recent = lastBook()
    if (hostWidget && recent && typeof hostWidget.setLastTitle === "function")
      hostWidget.setLastTitle(recent.title)
  }

  function rebuildVisibleBooks() {
    var query = searchField.text.trim().toLowerCase()
    var result = []
    for (var i = 0; i < books.length; i++) {
      var book = books[i]
      var haystack = (String(book.title || "") + " " + String(book.author || "") + " "
        + String((book.formats || []).join(" "))).toLowerCase()
      if (query === "" || haystack.indexOf(query) !== -1) result.push(book)
    }
    visibleBooks = result
  }

  function lastBook() {
    for (var i = 0; i < books.length; i++) if (String(books[i].id) === lastBookId) return books[i]
    return books.length > 0 ? books[0] : null
  }

  function read(book) {
    if (!book || !hostWidget) return
    root.close()
    hostWidget.openReader(String(book.id), String(book.title || ""))
  }

  function showStatus(message, error) {
    statusText = String(message || "")
    statusError = error === true
    statusTimer.restart()
  }

  function chooseFolder() {
    if (actionProc.running) return
    actionOutput = ""
    actionProc.command = [helperPath, "choose-folder"]
    actionProc.running = true
  }

  function saveSetting(args) {
    if (actionProc.running) return
    actionOutput = ""
    actionProc.command = [helperPath, "settings"].concat(args)
    actionProc.running = true
  }

  function parseAction(exitCode) {
    var payload = null
    try { payload = JSON.parse(actionOutput) } catch (error) {}
    if (payload && payload.cancelled) return
    if (exitCode !== 0 || !payload || !payload.ok) {
      showStatus(payload && payload.error ? payload.error : "That change could not be saved.", true)
      return
    }
    readerSettings = payload.settings || readerSettings
    showStatus("Saved", false)
    refresh(true)
  }

  onBooksChanged: rebuildVisibleBooks()

  Process {
    id: libraryProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.libraryOutput = text }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) { root.parseLibrary(exitCode) }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.actionOutput = text }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) { root.parseAction(exitCode) }
  }

  Timer {
    id: statusTimer
    interval: 3200
    onTriggered: root.statusText = ""
  }

  KeyboardPanel {
    id: libraryPanel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: libraryPanel.fittedContentWidth(root.desiredWidth)
    contentHeight: libraryPanel.fittedContentHeight(contentColumn.implicitHeight, root.maximumHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchField.activeFocus || folderField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: contentColumn
        width: parent.width
        spacing: Style.space(12)

        Row {
          width: parent.width
          height: Style.space(54)
          spacing: Style.space(12)

          BorderSurface {
            width: Style.space(48); height: width
            anchors.verticalCenter: parent.verticalCenter
            radius: Style.cornerRadius
            color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.13)
            borderSpec: Border.flat(root.accent, 1)
            Text { anchors.centerIn: parent; text: "󰂺"; color: root.accent; font.family: root.fontFamily; font.pixelSize: Style.font.display }
          }

          Column {
            width: parent.width - Style.space(48) - settingsButton.width - refreshButton.width - parent.spacing * 3
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)
            Text { text: "Leaf Reader"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.title; font.bold: true }
            Text {
              width: parent.width
              text: root.settingsMode ? "A CALMER WAY TO READ" : root.loading ? "SCANNING YOUR LIBRARY…"
                : String(root.books.length) + " BOOK" + (root.books.length === 1 ? "" : "S") + " · LOCAL & PRIVATE"
              color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true; font.letterSpacing: 0.9
              elide: Text.ElideRight
            }
          }

          PanelActionButton {
            id: refreshButton
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰑐"; tooltipText: "Rescan library"; foreground: root.foreground; hoverColor: root.accent; bordered: true
            enabled: !root.loading
            onClicked: root.refresh(true)
          }
          PanelActionButton {
            id: settingsButton
            anchors.verticalCenter: parent.verticalCenter
            iconText: root.settingsMode ? "󰅖" : "󰒓"; tooltipText: root.settingsMode ? "Back to library" : "Reader settings"
            foreground: root.foreground; hoverColor: root.accent; bordered: true
            onClicked: root.settingsMode = !root.settingsMode
          }
        }

        Rectangle { width: parent.width; height: 1; color: root.subtle }

        Item {
          visible: !root.settingsMode
          width: parent.width
          height: visible ? libraryContent.implicitHeight : 0

          Column {
            id: libraryContent
            width: parent.width
            spacing: Style.space(12)

            BorderSurface {
              visible: root.lastBook() !== null
              width: parent.width
              height: visible ? Style.space(134) : 0
              radius: Style.cornerRadius
              color: root.subtle
              borderSpec: Border.flat(root.subtle, 1)

              Row {
                anchors.fill: parent
                anchors.margins: Style.space(12)
                spacing: Style.space(14)

                Rectangle {
                  width: Style.space(70); height: Style.space(106); radius: Style.space(5); clip: true
                  color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.16)
                  Image {
                    anchors.fill: parent
                    source: root.lastBook() ? root.fileUrl(root.lastBook().cover) : ""
                    sourceSize: Qt.size(Style.space(140), Style.space(212))
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    visible: status === Image.Ready
                  }
                  Text {
                    anchors.centerIn: parent; width: parent.width - Style.space(10)
                    visible: parent.children[0].status !== Image.Ready
                    text: root.lastBook() ? String(root.lastBook().title || "") : ""
                    textFormat: Text.PlainText
                    color: root.foreground; font.family: "Noto Serif"; font.pixelSize: Style.font.caption; font.bold: true
                    horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; maximumLineCount: 4; elide: Text.ElideRight
                  }
                }

                Column {
                  width: parent.width - Style.space(70) - continueButton.width - parent.spacing * 2
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(5)
                  Text { text: "CONTINUE READING"; color: root.accent; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true; font.letterSpacing: 1 }
                  Text {
                    width: parent.width; text: root.lastBook() ? String(root.lastBook().title || "") : ""
                    textFormat: Text.PlainText
                    color: root.foreground; font.family: "Noto Serif"; font.pixelSize: Style.font.title; font.bold: true; elide: Text.ElideRight
                  }
                  Text {
                    width: parent.width; text: root.lastBook() ? String(root.lastBook().author || "") : ""
                    textFormat: Text.PlainText
                    color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.body; elide: Text.ElideRight
                  }
                  Row {
                    spacing: Style.space(8)
                    Rectangle {
                      width: Style.space(170); height: Style.space(4); radius: height / 2; color: root.subtle
                      Rectangle { width: parent.width * (root.lastBook() ? Number(root.lastBook().progress || 0) : 0); height: parent.height; radius: parent.radius; color: root.accent }
                    }
                    Text {
                      text: root.lastBook() && Number(root.lastBook().progress || 0) > 0
                        ? Math.round(Number(root.lastBook().progress) * 100) + "%" : "READY"
                      color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption
                    }
                  }
                }

                PanelActionButton {
                  id: continueButton
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: "󰐊"; tooltipText: "Continue reading"; foreground: root.foreground; hoverColor: root.accent; bordered: true
                  onClicked: root.read(root.lastBook())
                }
              }
            }

            QQC.TextField {
              id: searchField
              width: parent.width
              height: Style.space(42)
              placeholderText: "Search title, author, or format"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              leftPadding: Style.space(14); rightPadding: Style.space(14)
              background: Rectangle { radius: Style.cornerRadius; color: root.subtle; border.width: searchField.activeFocus ? 1 : 0; border.color: root.accent }
              onTextChanged: root.rebuildVisibleBooks()
            }

            Text {
              visible: !root.loading && root.books.length === 0
              width: parent.width
              topPadding: Style.space(34); bottomPadding: Style.space(34)
              text: "No ebooks found yet. Open Reader settings and choose the folder that holds your books."
              color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
            }

            Text {
              visible: root.books.length > 0
              text: searchField.text.trim() === "" ? "LIBRARY" : String(root.visibleBooks.length) + " MATCHES"
              color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true; font.letterSpacing: 1
            }

            GridView {
              id: bookGrid
              visible: root.books.length > 0
              width: parent.width
              height: visible ? Math.min(contentHeight, Style.space(410)) : 0
              cellWidth: width / 4
              cellHeight: Style.space(190)
              clip: true
              model: root.visibleBooks
              boundsBehavior: Flickable.StopAtBounds
              QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

              delegate: Item {
                required property var modelData
                width: bookGrid.cellWidth
                height: bookGrid.cellHeight

                Rectangle {
                  id: coverCard
                  anchors { top: parent.top; horizontalCenter: parent.horizontalCenter }
                  width: Math.min(parent.width - Style.space(18), Style.space(106))
                  height: Style.space(145)
                  radius: Style.space(6)
                  clip: true
                  color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, coverHover.hovered ? 0.23 : 0.13)
                  border.width: coverHover.hovered ? 1 : 0
                  border.color: root.accent

                  Image {
                    id: bookImage
                    anchors.fill: parent
                    source: root.fileUrl(modelData.cover)
                    sourceSize: Qt.size(Style.space(212), Style.space(290))
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    visible: status === Image.Ready
                  }
                  Text {
                    anchors.centerIn: parent; width: parent.width - Style.space(14)
                    visible: bookImage.status !== Image.Ready
                    text: String(modelData.title || "")
                    textFormat: Text.PlainText
                    color: root.foreground; font.family: "Noto Serif"; font.pixelSize: Style.font.caption; font.bold: true
                    horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; maximumLineCount: 5; elide: Text.ElideRight
                  }
                  Rectangle {
                    visible: Number(modelData.progress || 0) > 0
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                    height: Style.space(4); color: Qt.rgba(0, 0, 0, 0.28)
                    Rectangle { width: parent.width * Number(modelData.progress || 0); height: parent.height; color: root.accent }
                  }
                  HoverHandler { id: coverHover }
                  TapHandler { onTapped: root.read(modelData) }
                }

                Text {
                  anchors { top: coverCard.bottom; topMargin: Style.space(7); left: parent.left; right: parent.right }
                  text: String(modelData.title || "")
                  textFormat: Text.PlainText
                  color: root.foreground; font.family: "Noto Serif"; font.pixelSize: Style.font.caption; font.bold: true
                  horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
                }
                Text {
                  anchors { top: coverCard.bottom; topMargin: Style.space(23); left: parent.left; right: parent.right }
                  text: String(modelData.author || "")
                  textFormat: Text.PlainText
                  color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption - 1
                  horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
                }
              }
            }
          }
        }

        Item {
          visible: root.settingsMode
          width: parent.width
          height: visible ? settingsContent.implicitHeight : 0

          Column {
            id: settingsContent
            width: parent.width
            spacing: Style.space(16)

            Column {
              width: parent.width; spacing: Style.space(7)
              Text { text: "LIBRARY FOLDER"; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true; font.letterSpacing: 1 }
              Row {
                width: parent.width; spacing: Style.space(8)
                QQC.TextField {
                  id: folderField
                  width: parent.width - browseButton.width - parent.spacing
                  height: Style.space(42)
                  text: String(root.readerSettings.libraryFolder || "")
                  color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body
                  leftPadding: Style.space(12); rightPadding: Style.space(12)
                  background: Rectangle { radius: Style.cornerRadius; color: root.subtle; border.width: folderField.activeFocus ? 1 : 0; border.color: root.accent }
                  onAccepted: root.saveSetting(["--library-folder", text.trim()])
                }
                PanelActionButton {
                  id: browseButton
                  iconText: "󰉋"; tooltipText: "Choose folder"; foreground: root.foreground; hoverColor: root.accent; bordered: true
                  onClicked: root.chooseFolder()
                }
              }
              Text { text: "Scans subfolders automatically. Your files never leave this computer."; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
            }

            Rectangle { width: parent.width; height: 1; color: root.subtle }

            Row {
              width: parent.width; spacing: Style.space(18)

              Column {
                width: (parent.width - parent.spacing) / 2; spacing: Style.space(8)
                Text { text: "TEXT SIZE"; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true; font.letterSpacing: 1 }
                Row {
                  spacing: Style.space(7)
                  PanelActionButton {
                    iconText: "A−"; tooltipText: "Smaller text"; foreground: root.foreground; hoverColor: root.accent; bordered: true
                    onClicked: root.saveSetting(["--font-size", String(Number(root.readerSettings.fontSize || 20) - 1)])
                  }
                  BorderSurface {
                    width: Style.space(76); height: Style.space(38); radius: Style.cornerRadius; color: root.subtle; borderSpec: Border.flat(root.subtle, 1)
                    Text { anchors.centerIn: parent; text: String(root.readerSettings.fontSize || 20) + " px"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body }
                  }
                  PanelActionButton {
                    iconText: "A+"; tooltipText: "Larger text"; foreground: root.foreground; hoverColor: root.accent; bordered: true
                    onClicked: root.saveSetting(["--font-size", String(Number(root.readerSettings.fontSize || 20) + 1)])
                  }
                }
              }

              Column {
                width: (parent.width - parent.spacing) / 2; spacing: Style.space(8)
                Text { text: "PAGE WIDTH"; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true; font.letterSpacing: 1 }
                QQC.Slider {
                  width: parent.width
                  from: 520; to: 1100; stepSize: 20
                  value: Number(root.readerSettings.pageWidth || 760)
                  onMoved: root.saveSetting(["--page-width", String(Math.round(value))])
                }
              }
            }

            Column {
              width: parent.width; spacing: Style.space(8)
              Text { text: "PAGE COLOR"; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true; font.letterSpacing: 1 }
              Row {
                spacing: Style.space(8)
                Repeater {
                  model: [
                    { name: "Paper", value: "paper", color: "#fffdf8" },
                    { name: "Sepia", value: "sepia", color: "#f4ead6" },
                    { name: "Slate", value: "slate", color: "#313c43" },
                    { name: "Night", value: "night", color: "#1d1d1d" }
                  ]
                  delegate: Rectangle {
                    required property var modelData
                    width: Style.space(120); height: Style.space(48); radius: Style.cornerRadius
                    color: root.readerSettings.theme === modelData.value ? root.subtle : "transparent"
                    border.width: root.readerSettings.theme === modelData.value ? 1 : 0
                    border.color: root.accent
                    Row {
                      anchors.centerIn: parent; spacing: Style.space(8)
                      Rectangle { width: Style.space(22); height: width; radius: width / 2; color: modelData.color; border.width: 1; border.color: "#777777" }
                      Text { text: modelData.name; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body }
                    }
                    TapHandler { onTapped: root.saveSetting(["--theme", modelData.value]) }
                  }
                }
              }
            }

            Column {
              width: parent.width; spacing: Style.space(8)
              Text { text: "PAGE TURN EFFECT"; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true; font.letterSpacing: 1 }
              Row {
                spacing: Style.space(8)
                Repeater {
                  model: [
                    { name: "On", value: true },
                    { name: "Off", value: false }
                  ]
                  delegate: Rectangle {
                    required property var modelData
                    width: Style.space(120); height: Style.space(40); radius: Style.cornerRadius
                    color: (root.readerSettings.pageTurn !== false) === modelData.value ? root.subtle : "transparent"
                    border.width: (root.readerSettings.pageTurn !== false) === modelData.value ? 1 : 0
                    border.color: root.accent
                    Text { anchors.centerIn: parent; text: modelData.name; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body }
                    TapHandler { onTapped: root.saveSetting(["--page-turn", modelData.value ? "true" : "false"]) }
                  }
                }
              }
              Text { text: "Turn it off for an instant, motion-free page change."; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
            }

            Row {
              width: parent.width; spacing: Style.space(18)
              Column {
                width: (parent.width - parent.spacing) / 2; spacing: Style.space(7)
                Text { text: "TYPEFACE"; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true; font.letterSpacing: 1 }
                QQC.ComboBox {
                  width: parent.width
                  model: ["Serif", "Sans", "Publisher"]
                  currentIndex: root.readerSettings.fontFamily === "sans" ? 1 : root.readerSettings.fontFamily === "publisher" ? 2 : 0
                  onActivated: root.saveSetting(["--font-family", ["serif", "sans", "publisher"][currentIndex]])
                }
              }
              Column {
                width: (parent.width - parent.spacing) / 2; spacing: Style.space(7)
                Text { text: "SORT LIBRARY"; color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true; font.letterSpacing: 1 }
                QQC.ComboBox {
                  width: parent.width
                  model: ["Recently read", "Title", "Author", "Recently added"]
                  currentIndex: ["recent", "title", "author", "added"].indexOf(String(root.readerSettings.sort || "recent"))
                  onActivated: root.saveSetting(["--sort", ["recent", "title", "author", "added"][currentIndex]])
                }
              }
            }

            BorderSurface {
              width: parent.width; height: Style.space(68); radius: Style.cornerRadius
              color: root.subtle; borderSpec: Border.flat(root.subtle, 1)
              Row {
                anchors.fill: parent; anchors.margins: Style.space(12); spacing: Style.space(12)
                Text { anchors.verticalCenter: parent.verticalCenter; text: root.converterAvailable ? "󰄬" : "󰅙"; color: root.converterAvailable ? "#86b97c" : root.muted; font.pixelSize: Style.font.title }
                Column {
                  anchors.verticalCenter: parent.verticalCenter; width: parent.width - Style.space(40); spacing: Style.space(2)
                  Text { text: root.converterAvailable ? "Kindle formats are ready" : "EPUB and PDF are ready"; color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.body; font.bold: true }
                  Text {
                    width: parent.width
                    text: root.converterAvailable ? "AZW3, MOBI, FB2, RTF, and text books convert locally when first opened."
                      : "Install ebook-convert only if you want AZW3, MOBI, and other conversion-only formats."
                    color: root.muted; font.family: root.fontFamily; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap
                  }
                }
              }
            }
          }
        }

        Text {
          visible: root.statusText !== ""
          width: parent.width
          text: root.statusText
          textFormat: Text.PlainText
          color: root.statusError ? "#e06c75" : root.accent
          font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true
          horizontalAlignment: Text.AlignHCenter
        }
      }
    }
  }
}
