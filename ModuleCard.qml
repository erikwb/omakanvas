pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui

Column {
  id: card

  required property var moduleData
  property color foreground
  property color muted
  property color accent
  property string fontFamily
  property bool expanded: false
  signal openItem(var item)

  spacing: Style.space(8)

  AssignmentLinkRow {
    width: parent.width
    title: (card.expanded ? "▾ " : "▸ ") + String(card.moduleData.name || "Untitled module")
    subtitle: (card.moduleData.items || []).length + " items"
      + (card.moduleData.state ? " · " + card.moduleData.state : "")
      + (card.moduleData.published === false ? " · Unpublished" : "")
    submitted: false
    showSubmissionStatus: false
    locked: card.moduleData.state === "locked"
    linkAvailable: true
    foreground: card.foreground
    muted: card.muted
    accent: card.accent
    fontFamily: card.fontFamily
    onActivated: card.expanded = !card.expanded
  }

  Text {
    visible: String(card.moduleData.fetch_error || "") !== ""
    width: parent.width
    text: String(card.moduleData.fetch_error || "")
    textFormat: Text.PlainText
    color: card.accent
    font.family: card.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.Wrap
  }

  Repeater {
    model: card.expanded ? (card.moduleData.items || []) : []

    Column {
      id: itemColumn
      required property var modelData
      required property int index
      width: card.width
      spacing: Style.space(5)

      AssignmentLinkRow {
        width: parent.width
        title: String(itemColumn.modelData.title || "Untitled module item")
        subtitle: String(itemColumn.modelData.type || "")
        submitted: false
        showSubmissionStatus: false
        locked: !!(itemColumn.modelData.content_details || {}).locked_for_user
        linkAvailable: !!itemColumn.modelData.html_url
        foreground: card.foreground
        muted: card.muted
        accent: card.accent
        fontFamily: card.fontFamily
        onActivated: card.openItem(itemColumn.modelData)
      }

      Text {
        visible: text !== ""
        width: parent.width
        text: String(itemColumn.modelData.fetch_error || "")
        textFormat: Text.PlainText
        color: card.accent
        font.family: card.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
      }

      Text {
        visible: text !== ""
        width: parent.width
        text: String(itemColumn.modelData.body || "")
        textFormat: Text.PlainText
        color: card.muted
        font.family: card.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.Wrap
      }

      Repeater {
        model: itemColumn.modelData.documents || []

        AssignmentLinkRow {
          required property var modelData
          width: itemColumn.width
          title: String(modelData.display_name || modelData.filename || "Document")
          subtitle: modelData.download_status === "downloaded"
            ? "Saved locally · " + Number(modelData.downloaded_size || 0).toLocaleString(Qt.locale(), 'f', 0) + " bytes"
            : String(modelData.fetch_error || "Document unavailable")
          submitted: false
          showSubmissionStatus: false
          locked: modelData.download_status === "locked"
          linkAvailable: !!modelData.local_url || !!modelData.html_url
          foreground: card.foreground
          muted: card.muted
          accent: card.accent
          fontFamily: card.fontFamily
          onActivated: {
            if (modelData.local_url) Qt.openUrlExternally(modelData.local_url)
            else card.openItem(modelData)
          }
        }
      }

      PanelSeparator {
        visible: itemColumn.index < (card.moduleData.items || []).length - 1
        width: parent.width
        foreground: card.foreground
        opacity: 0.18
      }
    }
  }
}
