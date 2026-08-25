import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.dlpwaters.ebook-reader"

  readonly property string helperPath: String(Qt.resolvedUrl("ebook-tool")).replace(/^file:\/\//, "")
  property string lastTitle: ""
  property bool launching: false
  property string launchOutput: ""
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function inject() {
    var panel = panelLoader.item
    if (panel) {
      if ("bar" in panel) panel.bar = root.bar
      if ("settings" in panel) panel.settings = root.settings
      if ("anchorItem" in panel) panel.anchorItem = button
      if ("hostWidget" in panel) panel.hostWidget = root
      if ("helperPath" in panel) panel.helperPath = root.helperPath
    }
  }

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function setLastTitle(value) { lastTitle = String(value || "") }
  function openReader(bookId, title) {
    if (launchProc.running) return
    launchOutput = ""
    launching = true
    launchProc.command = String(bookId || "") !== ""
      ? [helperPath, "open", String(bookId)] : [helperPath, "open"]
    launchProc.running = true
  }
  function resume() { openReader("", lastTitle) }
  function refreshSummary() {
    if (summaryProc.running) return
    summaryOutput = ""
    summaryProc.running = true
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: inject()
  onSettingsChanged: inject()
  Component.onCompleted: summaryDelay.start()
  Component.onDestruction: {
    if (root.helperPath !== "") Quickshell.execDetached([root.helperPath, "stop"])
  }

  property string summaryOutput: ""

  Timer {
    id: summaryDelay
    interval: 120
    onTriggered: root.refreshSummary()
  }

  Process {
    id: summaryProc
    command: [root.helperPath, "library", "--limit", "1", "--deadline", "8"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.summaryOutput = text }
    onExited: {
      try {
        var payload = JSON.parse(root.summaryOutput)
        if (payload && payload.books && payload.books.length > 0)
          root.setLastTitle(payload.books[0].title)
      } catch (error) {}
    }
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: { root.inject(); Qt.callLater(root.inject) }
  }

  Process {
    id: launchProc
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.launchOutput = text }
    stderr: StdioCollector { waitForEnd: true }
    onExited: {
      root.launching = false
      root.refreshSummary()
    }
  }

  IpcHandler {
    target: "leaf-reader"
    function open() { root.open() }
    function close() { root.close() }
    function toggle() { root.toggle() }
    function resume() { root.resume() }
    function read(bookId: string) { root.openReader(bookId, "") }
    function status(): string {
      return JSON.stringify({ panelOpen: panelLoader.item ? panelLoader.item.opened : false,
        launching: root.launching, lastTitle: root.lastTitle })
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.launching ? "󰔟" : "󰂺"
    active: root.launching || (panelLoader.item ? panelLoader.item.opened : false)
    useActiveColor: true
    tooltipText: root.lastTitle !== "" ? "Leaf Reader · Continue reading" : "Leaf Reader"
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) root.resume()
      else root.toggle()
    }
  }
}
