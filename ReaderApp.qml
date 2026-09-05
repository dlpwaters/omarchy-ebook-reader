import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Window
import QtWebEngine

QQC.ApplicationWindow {
  id: window

  readonly property string readerUrl: {
    const prefix = "--leaf-reader-url="
    for (const argument of Qt.application.arguments) {
      if (argument.indexOf(prefix) === 0) return argument.slice(prefix.length)
    }
    return "http://127.0.0.1:4189/"
  }

  visible: true
  visibility: Window.Maximized
  minimumWidth: 720
  minimumHeight: 540
  width: 1440
  height: 900
  title: "Leaf Reader"
  color: "#171717"

  Component.onCompleted: {
    Qt.callLater(function() {
      window.raise()
      window.requestActivate()
    })
  }

  Shortcut {
    sequence: "Ctrl+Shift+Q"
    context: Qt.ApplicationShortcut
    onActivated: window.close()
  }

  Shortcut {
    sequence: "F11"
    context: Qt.ApplicationShortcut
    onActivated: window.visibility === Window.FullScreen ? window.showMaximized() : window.showFullScreen()
  }

  header: QQC.ToolBar {
    height: 42
    background: Rectangle {
      color: "#171717"
      Rectangle {
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 1
        color: "#2b2b2b"
      }
    }

    Row {
      anchors { left: parent.left; leftMargin: 15; verticalCenter: parent.verticalCenter }
      spacing: 9

      Text {
        text: "󰂺"
        color: "#d8a06a"
        font.family: "Symbols Nerd Font"
        font.pixelSize: 17
        renderType: Text.NativeRendering
      }

      Text {
        text: "Leaf Reader"
        color: "#e8e5df"
        font.family: "Noto Sans"
        font.pixelSize: 13
        font.bold: true
        renderType: Text.NativeRendering
      }
    }

    Row {
      anchors { right: parent.right; rightMargin: 7; verticalCenter: parent.verticalCenter }
      spacing: 2

      component WindowButton: Rectangle {
        property string glyph: ""
        property string tip: ""
        signal clicked()
        width: 34
        height: 30
        radius: 8
        color: hover.hovered ? "#2b2b2b" : "transparent"
        HoverHandler { id: hover }
        QQC.ToolTip.visible: hover.hovered
        QQC.ToolTip.text: tip
        Text { anchors.centerIn: parent; text: parent.glyph; color: "#d1cec8"; font.family: "Noto Sans"; font.pixelSize: 14; renderType: Text.NativeRendering }
        TapHandler { onTapped: parent.clicked() }
      }

      WindowButton { glyph: "↻"; tip: "Reload book"; onClicked: webView.reload() }
      WindowButton {
        glyph: window.visibility === Window.FullScreen ? "❐" : "□"
        tip: window.visibility === Window.FullScreen ? "Leave fullscreen · F11" : "Fullscreen · F11"
        onClicked: window.visibility = window.visibility === Window.FullScreen ? Window.Maximized : Window.FullScreen
      }
      WindowButton { glyph: "×"; tip: "Close reader · Ctrl+Shift+Q"; onClicked: window.close() }
    }
  }

  WebEngineProfile {
    id: privateProfile
    offTheRecord: true
    httpCacheType: WebEngineProfile.MemoryHttpCache
    persistentCookiesPolicy: WebEngineProfile.NoPersistentCookies
    spellCheckEnabled: false
    isPushServiceEnabled: false
  }

  WebEngineView {
    id: webView
    anchors.fill: parent
    url: window.readerUrl
    profile: privateProfile
    backgroundColor: "#fffdf8"
    focus: true

    settings.javascriptEnabled: true
    settings.localContentCanAccessRemoteUrls: false
    settings.localContentCanAccessFileUrls: false
    settings.javascriptCanOpenWindows: false
    settings.fullScreenSupportEnabled: false
    settings.pluginsEnabled: true
    settings.pdfViewerEnabled: true

    Component.onCompleted: forceActiveFocus()
  }
}
