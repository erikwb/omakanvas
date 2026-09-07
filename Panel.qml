import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.erikwb.omakanvas"
  ipcTarget: "io.github.erikwb.omakanvas"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string pluginDir: decodeURIComponent(
    String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, ""))
  readonly property string helperPath: pluginDir + "/omakanvas"
  readonly property string baseUrl: String(setting("baseUrl", "")).trim()
  readonly property string configurationMessage: "Set your Canvas URL with omarchy bar set, then run the helper's login command or save an API token."
  readonly property int days: boundedSetting("days", 14, 1, 60)
  readonly property int refreshSec: boundedSetting("refreshIntervalSec", 21600, 300, 86400)

  readonly property var paneNames: ["Overview", "Assignments", "Courses"]
  property int selectedPane: 0
  property string selectedRole: "student"
  property bool cursorActive: false
  property string selectedCourseId: ""
  property var payload: ({
    schema_version: 5,
    fetched_at: "",
    days: 14,
    roles: {
      student: { available: false, error: "", courses: [], hidden_courses: [] },
      teacher: { available: false, error: "", courses: [], hidden_courses: [] }
    }
  })
  property string errorText: ""
  property string visibilityError: ""
  property bool loading: false
  property bool loggingIn: false
  property bool authError: false
  property string pendingToken: ""
  property bool showSetup: false
  readonly property bool setupVisible: root.showSetup || root.baseUrl === ""
    || (root.authError && root.errorText !== "")
  property bool refreshAfterStatus: false
  property var pendingVisibilityCourse: null
  property bool pendingHiddenState: false
  property bool hiddenCoursesExpanded: false
  property bool submittedAssignmentsExpanded: false

  readonly property var studentData: payload.roles && payload.roles.student
    ? payload.roles.student : ({ available: false, error: "", courses: [], hidden_courses: [] })
  readonly property var teacherData: payload.roles && payload.roles.teacher
    ? payload.roles.teacher : ({ available: false, error: "", courses: [], hidden_courses: [] })
  readonly property var activeRoleData: selectedRole === "teacher" ? teacherData : studentData
  readonly property bool teaching: selectedRole === "teacher"
  readonly property bool studentRolePresent: !!studentData.available || String(studentData.error || "") !== ""
  readonly property bool teacherRolePresent: !!teacherData.available || String(teacherData.error || "") !== ""
  readonly property bool showRoleSwitch: studentRolePresent && teacherRolePresent
  readonly property string roleError: String(activeRoleData.error || "")
  readonly property var courses: activeRoleData.courses || []
  readonly property var hiddenCourses: activeRoleData.hidden_courses || []
  readonly property var assignments: flattenAssignments(courses)
  readonly property var openAssignments: filterAssignments(assignments, false)
  readonly property var submittedAssignments: filterAssignments(assignments, true)
  readonly property var selectedCourse: findSelectedCourse()
  readonly property int selectedCourseIndex: findSelectedCourseIndex()
  readonly property var selectedCourseAssignments: selectedCourse
    ? (selectedCourse.assignments || []) : []
  readonly property var selectedCourseOpenAssignments:
    filterAssignments(selectedCourseAssignments, false)
  readonly property var selectedCourseSubmittedAssignments:
    filterAssignments(selectedCourseAssignments, true)
  readonly property var selectedCourseAnnouncements: selectedCourse
    ? (selectedCourse.announcements || []) : []
  // The payload keeps every announcement and conversation for external
  // tools; the panel shows only a recent subset (RECENT_ITEM_LIMIT in sync).
  readonly property var selectedCourseRecentAnnouncements:
    selectedCourseAnnouncements.slice(0, 3)
  readonly property var selectedCourseConversations: selectedCourse
    ? (selectedCourse.conversations || []) : []
  readonly property var selectedCourseUnreadConversations:
    selectedCourseConversations.filter(function(item) { return !!item.unread })
  readonly property var selectedCourseRecentUnreadConversations:
    selectedCourseUnreadConversations.slice(0, 3)
  readonly property var selectedCourseDiscussions: selectedCourse
    ? (selectedCourse.discussions || []) : []
  readonly property var selectedCourseRecentDiscussions:
    selectedCourseDiscussions.slice(0, 3)
  readonly property var nextAssignment: teaching
    ? (assignments.length > 0 ? assignments[0] : null)
    : (openAssignments.length > 0 ? openAssignments[0] : null)
  readonly property int pendingCount: countAssignments(false)
  readonly property int submittedCount: assignments.length - pendingCount
  readonly property int draftCount: countDraftAssignments()
  readonly property int needsGradingCount: {
    var total = 0
    for (var i = 0; i < courses.length; i++)
      total += Math.max(0, Number(courses[i].needs_grading_count || 0))
    return total
  }
  readonly property int urgentCount: {
    var total = 0
    var cutoff = Date.now() + 2 * 24 * 60 * 60 * 1000
    for (var i = 0; i < assignments.length; i++) {
      var due = new Date(assignments[i].due_at).getTime()
      if (!assignments[i].submitted && isFinite(due) && due <= cutoff) total++
    }
    return total
  }

  onHiddenCoursesChanged: if (hiddenCourses.length === 0) hiddenCoursesExpanded = false
  onSubmittedCountChanged: if (submittedCount === 0) submittedAssignmentsExpanded = false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function alpha(color, amount) { return Qt.rgba(color.r, color.g, color.b, amount) }

  function boundedSetting(key, fallback, minimum, maximum) {
    var value = Number(setting(key, fallback))
    if (!isFinite(value)) value = fallback
    return Math.max(minimum, Math.min(maximum, Math.round(value)))
  }

  function flattenAssignments(courseList) {
    var rows = []
    for (var i = 0; i < courseList.length; i++) {
      var course = courseList[i]
      var courseAssignments = course.assignments || []
      for (var j = 0; j < courseAssignments.length; j++) {
        var source = courseAssignments[j]
        rows.push({
          id: source.id,
          name: source.name,
          due_at: source.due_at,
          due_dates: source.due_dates || [],
          availability_schedules: source.availability_schedules || [],
          submitted: source.submitted,
          published: source.published,
          locked_for_user: source.locked_for_user,
          unlock_at: source.unlock_at,
          lock_at: source.lock_at,
          html_url: source.html_url,
          course_id: course.id,
          course_name: course.name,
          course_code: course.code
        })
      }
    }
    rows.sort(function(a, b) {
      return new Date(a.due_at).getTime() - new Date(b.due_at).getTime()
    })
    return rows
  }

  function countAssignments(submitted) {
    var total = 0
    for (var i = 0; i < assignments.length; i++)
      if (!!assignments[i].submitted === submitted) total++
    return total
  }

  function filterAssignments(assignmentList, submitted) {
    var rows = []
    for (var i = 0; i < assignmentList.length; i++)
      if (!!assignmentList[i].submitted === submitted) rows.push(assignmentList[i])
    return rows
  }

  function countDraftAssignments() {
    var total = 0
    for (var i = 0; i < assignments.length; i++)
      if (assignments[i].published === false) total++
    return total
  }

  function ensureSelectedRole() {
    if (selectedRole === "teacher" && teacherRolePresent) return
    if (selectedRole === "student" && studentRolePresent) return
    if (studentRolePresent) selectedRole = "student"
    else if (teacherRolePresent) selectedRole = "teacher"
    else selectedRole = "student"
  }

  function selectRole(role) {
    if (role !== "student" && role !== "teacher") return
    if (role === "student" && !studentRolePresent) return
    if (role === "teacher" && !teacherRolePresent) return
    selectedRole = role
    selectedCourseId = ""
    hiddenCoursesExpanded = false
    submittedAssignmentsExpanded = false
    ensureSelectedCourse()
    if (panelFlick) panelFlick.contentY = 0
  }

  function findSelectedCourse() {
    for (var i = 0; i < courses.length; i++)
      if (String(courses[i].id) === selectedCourseId) return courses[i]
    return courses.length > 0 ? courses[0] : null
  }

  function findSelectedCourseIndex() {
    for (var i = 0; i < courses.length; i++)
      if (String(courses[i].id) === selectedCourseId) return i
    return courses.length > 0 ? 0 : -1
  }

  function ensureSelectedCourse() {
    if (courses.length === 0) {
      selectedCourseId = ""
      return
    }
    for (var i = 0; i < courses.length; i++)
      if (String(courses[i].id) === selectedCourseId) return
    selectedCourseId = String(courses[0].id)
  }

  function selectPane(index) {
    selectedPane = ((index % paneNames.length) + paneNames.length) % paneNames.length
    cursorActive = true
    if (panelFlick) panelFlick.contentY = 0
  }

  function selectCourseOffset(offset) {
    if (courses.length === 0) return
    var index = ((selectedCourseIndex + offset) % courses.length + courses.length) % courses.length
    selectedCourseId = String(courses[index].id)
    if (panelFlick) panelFlick.contentY = 0
  }

  function refreshNow() {
    if (statusProc.running) return
    if (baseUrl === "") {
      errorText = configurationMessage
      return
    }
    loading = true
    errorText = ""
    authError = false
    statusProc.running = true
  }

  function startLogin() {
    if (loginProc.running || loggingIn) return
    if (baseUrl === "") {
      errorText = configurationMessage
      return
    }
    loggingIn = true
    errorText = ""
    authError = false
    loginProc.running = true
  }

  function cancelLogin() {
    if (loginProc.running) loginProc.running = false
    loggingIn = false
  }

  function displayError() {
    if (!authError) return errorText
    if (/no canvas credential|canvas_api_key is empty/i.test(errorText))
      return "You're not signed in. Sign in with Canvas to load your courses."
    if (/rejected the browser session/i.test(errorText))
      return "Your Canvas session expired. Sign in again to continue."
    if (/rejected the api token/i.test(errorText))
      return "Canvas rejected the saved API token. Sign in or save a new token."
    return errorText
  }

  function saveBaseUrl() {
    if (urlProc.running) return
    var url = String(urlField.text || "").trim()
    if (url === "") {
      errorText = "Enter your institution's Canvas URL, such as https://canvas.example.edu."
      return
    }
    errorText = ""
    urlProc.command = [
      "/usr/share/omarchy/bin/omarchy", "bar", "set",
      "io.github.erikwb.omakanvas", "baseUrl", url
    ]
    urlProc.running = true
  }

  function saveToken() {
    if (tokenProc.running || baseUrl === "") return
    if (String(tokenField.text || "").trim() === "") {
      errorText = "Paste your Canvas API token first."
      return
    }
    pendingToken = String(tokenField.text)
    tokenField.text = ""
    errorText = ""
    authError = false
    tokenProc.command = [root.helperPath, "set-token", "--token-stdin"]
    tokenProc.running = true
  }

  function grade(course) {
    if (!course) return "No grade"
    if (course.current_grade !== null && course.current_grade !== undefined && course.current_grade !== "")
      return String(course.current_grade)
    if (course.current_score !== null && course.current_score !== undefined)
      return Number(course.current_score).toFixed(1) + "%"
    return "No grade"
  }

  function dueLabel(value) {
    var date = new Date(value)
    if (!isFinite(date.getTime())) return "No due date"
    return date.toLocaleString(Qt.locale(), "ddd MMM d, h:mm AP")
  }

  function assignmentSubtitle(assignment, includeCourse) {
    var parts = []
    if (includeCourse)
      parts.push(String(assignment.course_code || assignment.course_name || ""))
    var availability = assignmentAvailabilityLabel(assignment)
    if (availability !== "") parts.push(availability)
    parts.push("Due " + dueLabel(assignment.due_at))
    if (teaching && assignment.published !== null && assignment.published !== undefined)
      parts.push(assignment.published ? "Published" : "Draft")
    return parts.filter(function(part) { return part !== "" }).join(" · ")
  }

  function announcementSubtitle(announcement) {
    if (!announcement) return ""
    var parts = []
    var posted = new Date(announcement.posted_at || "").getTime()
    parts.push(isFinite(posted)
      ? "Posted " + dueLabel(announcement.posted_at)
      : "No posted date")
    var author = String(announcement.author || "").trim()
    if (author !== "") parts.push(author)
    return parts.join(" · ")
  }

  function conversationSubtitle(conversation) {
    if (!conversation) return ""
    var parts = []
    var names = []
    var participants = conversation.participants || []
    for (var i = 0; i < participants.length && i < 3; i++) {
      var name = String(participants[i].name || "").trim()
      if (name !== "") names.push(name)
    }
    if (names.length > 0) parts.push(names.join(", "))
    var sent = new Date(conversation.last_message_at || "").getTime()
    parts.push(isFinite(sent) ? dueLabel(conversation.last_message_at) : "No date")
    if (Number(conversation.message_count) > 1)
      parts.push(Number(conversation.message_count) + " messages")
    if (conversation.starred) parts.push("Starred")
    return parts.join(" · ")
  }

  function discussionSubtitle(discussion) {
    if (!discussion) return ""
    var parts = []
    var active = new Date(discussion.last_activity_at || "").getTime()
    parts.push(isFinite(active)
      ? "Active " + dueLabel(discussion.last_activity_at)
      : "No activity date")
    var author = String(discussion.author || "").trim()
    if (author !== "") parts.push(author)
    var replies = Number(discussion.reply_count) || 0
    parts.push(replies + (replies === 1 ? " reply" : " replies"))
    if (discussion.pinned) parts.push("Pinned")
    return parts.join(" · ")
  }

  function assignmentLocked(assignment) {
    if (!assignment) return false
    if (!teaching) return !!assignment.locked_for_user
    var schedules = assignment.availability_schedules || []
    for (var i = 0; i < schedules.length; i++) {
      var unlock = new Date(schedules[i].unlock_at || "").getTime()
      if (isFinite(unlock) && unlock > Date.now()) return true
    }
    return false
  }

  function assignmentAvailabilityLabel(assignment) {
    if (!assignment) return ""
    if (!teaching) {
      if (!assignment.locked_for_user) return ""
      var studentUnlock = new Date(assignment.unlock_at || "").getTime()
      return isFinite(studentUnlock) && studentUnlock > Date.now()
        ? "Unlocks " + dueLabel(assignment.unlock_at)
        : "Locked · No scheduled unlock date"
    }

    var schedules = assignment.availability_schedules || []
    var futureUnlocks = []
    for (var i = 0; i < schedules.length; i++) {
      var unlock = new Date(schedules[i].unlock_at || "").getTime()
      if (isFinite(unlock) && unlock > Date.now()) futureUnlocks.push(unlock)
    }
    futureUnlocks.sort(function(a, b) { return a - b })
    if (schedules.length > 1) {
      var summary = schedules.length + " availability schedules"
      return futureUnlocks.length > 0
        ? summary + " · Earliest unlock " + dueLabel(new Date(futureUnlocks[0]).toISOString())
        : summary
    }
    return futureUnlocks.length > 0
      ? "Scheduled to unlock " + dueLabel(new Date(futureUnlocks[0]).toISOString())
      : ""
  }

  function courseStatus(course) {
    if (!course) return ""
    if (!teaching) return "Current grade  ·  " + grade(course)
    var state = String(course.workflow_state || "").toLowerCase()
    var stateLabel = state === "available" ? "Published"
      : (state === "unpublished" ? "Unpublished" : "")
    var count = Math.max(0, Number(course.needs_grading_count || 0))
    var label = count + " submission" + (count === 1 ? "" : "s") + " need grading"
    return stateLabel === "" ? label : label + "  ·  " + stateLabel
  }

  function fetchedLabel() {
    var date = new Date(payload.fetched_at || "")
    if (!isFinite(date.getTime())) return loading ? "REFRESHING" : "NOT YET UPDATED"
    return "UPDATED " + date.toLocaleString(Qt.locale(), "h:mm AP")
  }

  function elidedLabel(value, maximumLength) {
    var label = String(value || "").trim()
    if (label.length <= maximumLength) return label
    return label.substring(0, maximumLength - 1) + "…"
  }

  function courseLabel(course, index) {
    var code = String(course.code || "").trim()
    if (code !== "") return elidedLabel(code, 20)
    return elidedLabel(course.name || ("Course " + (index + 1)), 20)
  }

  function canvasItemUrl(item) {
    if (!item) return ""
    var candidate = String(item.html_url || "").trim()
    var origin = String(baseUrl || "").trim().replace(/\/+$/, "").toLowerCase()
    if (candidate === "" || origin === "") return ""
    return candidate.toLowerCase().indexOf(origin + "/") === 0 ? candidate : ""
  }

  function openAssignment(assignment) {
    var url = canvasItemUrl(assignment)
    if (url !== "") Qt.openUrlExternally(url)
  }

  function openCourse(course) {
    var url = canvasItemUrl(course)
    if (url !== "") Qt.openUrlExternally(url)
  }

  function setCourseVisibility(course, hidden) {
    if (!course || visibilityProc.running || baseUrl === "") return
    pendingVisibilityCourse = course
    pendingHiddenState = hidden
    visibilityError = ""
    var command = [
      helperPath, hidden ? "hide-course" : "unhide-course",
      String(course.id)
    ]
    if (hidden) {
      command.push("--course-name", String(course.name || ""))
      command.push("--course-code", String(course.code || ""))
    }
    visibilityProc.command = command
    visibilityProc.running = true
  }

  Process {
    id: statusProc
    command: [root.helperPath, "fetch", "--json", "--days", String(root.days)]
    environment: ({ "CANVAS_BASE_URL": root.baseUrl })
    stdout: StdioCollector { id: statusOutput; waitForEnd: true }
    stderr: StdioCollector { id: statusError; waitForEnd: true }
    onExited: function(exitCode) {
      root.loading = false
      if (exitCode !== 0) {
        var message = String(statusError.text || "").trim()
        root.errorText = message !== "" ? message.replace(/^omakanvas:\s*/, "")
                                            : "Canvas could not be refreshed."
        root.authError = /credential|log ?in|session|api token|canvas_api_key|rejected|expired/i.test(message)
        return
      }
      try {
        var nextPayload = JSON.parse(String(statusOutput.text || ""))
        if (Number(nextPayload.schema_version) !== 5 || !nextPayload.roles)
          throw new Error("Unsupported Omakanvas data format")
        root.payload = nextPayload
        root.ensureSelectedRole()
        root.ensureSelectedCourse()
        root.errorText = ""
        root.authError = false
      } catch (error) {
        root.errorText = "Canvas returned data the bar could not read."
      }
      if (root.refreshAfterStatus) {
        root.refreshAfterStatus = false
        Qt.callLater(function() { root.refreshNow() })
      }
    }
  }

  Process {
    id: visibilityProc
    environment: ({ "CANVAS_BASE_URL": root.baseUrl })
    stderr: StdioCollector { id: visibilityErrorOutput; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        var message = String(visibilityErrorOutput.text || "").trim()
        root.visibilityError = message !== "" ? message.replace(/^omakanvas:\s*/, "")
                                                  : "Could not update the hidden course list."
      } else {
        if (root.pendingHiddenState) root.selectedCourseId = ""
        if (statusProc.running) root.refreshAfterStatus = true
        else root.refreshNow()
      }
      root.pendingVisibilityCourse = null
    }
  }

  Process {
    id: loginProc
    command: [root.helperPath, "login"]
    environment: ({ "CANVAS_BASE_URL": root.baseUrl })
    stderr: StdioCollector { id: loginErrorOutput; waitForEnd: true }
    onExited: function(exitCode) {
      root.loggingIn = false
      if (exitCode !== 0) {
        var message = String(loginErrorOutput.text || "").trim()
        if (/cancel/i.test(message)) return
        root.errorText = message !== "" ? message.replace(/^omakanvas:\s*/, "")
                                        : "Canvas sign-in did not complete."
        root.authError = true
        return
      }
      root.errorText = ""
      root.authError = false
      if (!statusProc.running) root.refreshNow()
      else root.refreshAfterStatus = true
    }
  }

  Process {
    id: urlProc
    stderr: StdioCollector { id: urlErrorOutput; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        var message = String(urlErrorOutput.text || "").trim()
        root.errorText = message !== "" ? message : "Could not save the Canvas URL."
        return
      }
      root.errorText = ""
      if (!statusProc.running) root.refreshNow()
      else root.refreshAfterStatus = true
    }
  }

  Process {
    id: tokenProc
    stdinEnabled: true
    environment: ({ "CANVAS_BASE_URL": root.baseUrl })
    stderr: StdioCollector { id: tokenErrorOutput; waitForEnd: true }
    onStarted: function() {
      if (root.pendingToken !== "") tokenProc.write(root.pendingToken + "\n")
    }
    onExited: function(exitCode) {
      root.pendingToken = ""
      if (exitCode !== 0) {
        var message = String(tokenErrorOutput.text || "").trim()
        root.errorText = message !== "" ? message.replace(/^omakanvas:\s*/, "")
                                        : "Could not save the API token."
        root.authError = true
        return
      }
      root.errorText = ""
      root.authError = false
      if (!statusProc.running) root.refreshNow()
      else root.refreshAfterStatus = true
    }
  }

  Timer {
    interval: root.refreshSec * 1000
    running: root.baseUrl !== ""
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshNow()
  }

  onBaseUrlChanged: {
    if (baseUrl !== "" && errorText === configurationMessage) errorText = ""
    else if (baseUrl === "" && !loading) errorText = configurationMessage
  }

  Component.onCompleted: if (baseUrl === "") errorText = configurationMessage

  onOpenedChanged: if (opened) {
    cursorActive = false
    submittedAssignmentsExpanded = false
    showSetup = false
    if (panelFlick) panelFlick.contentY = 0
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  IpcHandler {
    target: "io.github.erikwb.omakanvas"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
    function nextPane(): string { root.selectPane(root.selectedPane + 1); return root.paneNames[root.selectedPane] }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf0ae"
    active: root.errorText !== "" || root.roleError !== "" || root.urgentCount > 0
    tooltipText: root.errorText !== ""
      ? "Omakanvas — " + root.displayError()
      : (root.roleError !== "" ? "Omakanvas — " + root.roleError
      : "Omakanvas — " + (root.teaching ? "Teaching · " : "Student · ")
        + root.pendingCount + " assignment" + (root.pendingCount === 1 ? "" : "s")
        + " due · right-click to refresh")
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.refreshNow()
      else if (root.authError && !root.loggingIn && root.baseUrl !== "") {
        root.open()
        root.startLogin()
      }
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(680))

      PanelKeyCatcher {
        id: keyCatcher
        anchors.fill: parent
        blocked: urlField.activeFocus || tokenField.activeFocus
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.selectPane(root.selectedPane + dx)
        if (dy !== 0)
          panelFlick.contentY = Math.max(0, Math.min(
            panelFlick.contentY + dy * Style.space(56),
            Math.max(0, panelFlick.contentHeight - panelFlick.height)))
      }
      onActivateRequested: root.refreshNow()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r" || text === "R") root.refreshNow()
        else if (text === "l" || text === "L") root.startLogin()
        else if (text === "s" || text === "S") root.selectRole("student")
        else if (text === "t" || text === "T") root.selectRole("teacher")
        else if (text === "1") root.selectPane(0)
        else if (text === "2") root.selectPane(1)
        else if (text === "3") root.selectPane(2)
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar {
          id: panelScrollBar
          policy: ScrollBar.AsNeeded
        }

        Column {
          id: content
          width: panelFlick.width - panelScrollBar.implicitWidth - Style.space(4)
          spacing: Style.space(12)

          Item {
            id: hero
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

            Text {
              id: heroIcon
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "\uf0ae"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Item {
                width: parent.width
                implicitHeight: Math.max(heroTitle.implicitHeight, roleChooser.implicitHeight)

                Text {
                  id: heroTitle
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Omakanvas"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                }

                Item {
                  id: roleChooser
                  visible: root.showRoleSwitch
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  implicitWidth: roleChooserText.implicitWidth
                  implicitHeight: roleChooserText.implicitHeight

                  Text {
                    id: roleChooserText
                    text: root.teaching ? "TEACHING" : "STUDENT"
                    color: roleChooserMouse.containsMouse ? root.urgent : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.letterSpacing: 1.0
                  }

                  MouseArea {
                    id: roleChooserMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.selectRole(root.teaching ? "student" : "teacher")
                  }
                }
              }

              Text {
                width: parent.width
                text: root.fetchedLabel()
                  + (root.loading ? " · REFRESHING" : (root.teaching
                    ? " · " + root.assignments.length + " DUE · "
                      + root.needsGradingCount + " TO GRADE"
                    : " · " + root.pendingCount + " DUE"))
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
              }
            }
          }

          Row {
            id: paneSwitch
            width: parent.width
            spacing: Style.spacing.md
            readonly property real cellWidth: (width - spacing * (root.paneNames.length - 1)) / root.paneNames.length

            Repeater {
              model: root.paneNames
              Button {
                required property string modelData
                required property int index
                width: paneSwitch.cellWidth
                text: modelData
                selected: index === root.selectedPane
                hasCursor: root.cursorActive && index === root.selectedPane
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.selectPane(index)
                onHovered: function(isHovered) { if (isHovered) root.cursorActive = true }
              }
            }
          }

          Text {
            visible: root.errorText !== ""
            width: parent.width
            text: root.displayError()
            textFormat: Text.PlainText
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          Button {
            visible: root.setupVisible && root.baseUrl !== "" && !root.loggingIn
            width: parent.width
            text: "Sign in with Canvas"
            iconText: "\uf090"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.body
            onClicked: root.startLogin()
          }

          Row {
            visible: root.setupVisible && !root.loggingIn
            width: parent.width
            spacing: Style.space(8)

            TextField {
              id: urlField
              width: parent.width - saveUrlButton.width - parent.spacing
              placeholderText: "https://canvas.example.edu"
              inputMethodHints: Qt.ImhUrlCharactersOnly
              foreground: root.foreground
              onAccepted: root.saveBaseUrl()
            }

            Button {
              id: saveUrlButton
              text: "Save"
              bordered: true
              enabled: !urlProc.running
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.saveBaseUrl()
            }
          }

          Row {
            visible: root.setupVisible && root.baseUrl !== "" && !root.loggingIn
            width: parent.width
            spacing: Style.space(8)

            TextField {
              id: tokenField
              width: parent.width - saveTokenButton.width - parent.spacing
              placeholderText: "Canvas API token"
              password: true
              foreground: root.foreground
              onAccepted: root.saveToken()
            }

            Button {
              id: saveTokenButton
              text: "Save"
              bordered: true
              enabled: !tokenProc.running
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onClicked: root.saveToken()
            }
          }

          Text {
            visible: root.loggingIn
            width: parent.width
            text: "A browser window has been opened for Canvas sign-in. "
              + "Complete the login there; this will continue automatically."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          Button {
            visible: root.loggingIn
            width: parent.width
            text: "Cancel sign-in"
            bordered: false
            leftAlign: true
            foreground: root.dim
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            onClicked: root.cancelLogin()
          }

          Text {
            visible: root.errorText === "" && !root.loading
              && root.roleError === ""
              && root.courses.length === 0 && root.hiddenCourses.length === 0
            width: parent.width
            text: root.teaching
              ? "No active courses being taught were found."
              : "No active student courses were found."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.errorText === "" && root.roleError !== ""
            width: parent.width
            text: root.roleError
            textFormat: Text.PlainText
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          Text {
            visible: root.visibilityError !== ""
            width: parent.width
            text: root.visibilityError
            textFormat: Text.PlainText
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          Column {
            id: overviewPane
            visible: root.errorText === "" && root.roleError === "" && root.selectedPane === 0
            width: parent.width
            spacing: Style.space(12)

            Row {
              id: overviewSummary
              width: parent.width
              spacing: Style.space(8)

              Repeater {
                model: root.teaching ? [
                  { value: root.assignments.length, label: "DUE", alarming: false },
                  { value: root.urgentCount, label: "48 HOURS", alarming: root.urgentCount > 0 },
                  { value: root.needsGradingCount, label: "TO GRADE", alarming: root.needsGradingCount > 0 },
                  { value: root.courses.length, label: "COURSES", alarming: false }
                ] : [
                  { value: root.pendingCount, label: "DUE", alarming: false },
                  { value: root.urgentCount, label: "48 HOURS", alarming: root.urgentCount > 0 },
                  { value: root.courses.length, label: "COURSES", alarming: false }
                ]
                Row {
                  required property var modelData
                  required property int index
                  spacing: Style.space(4)

                  Text {
                    visible: index > 0
                    text: "·"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    text: modelData.value + " " + modelData.label
                    color: modelData.alarming ? root.urgent : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }
              }
            }

            PanelSectionHeader {
              text: root.teaching ? "TEACHING COURSES" : "COURSE GRADES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.courses
              Column {
                required property var modelData
                required property int index
                width: overviewPane.width
                spacing: Style.space(7)

                Item {
                  width: parent.width
                  implicitHeight: Math.max(overviewName.implicitHeight, overviewGrade.implicitHeight)
                  Text {
                    id: overviewName
                    anchors.left: parent.left
                    anchors.right: overviewGrade.left
                    anchors.rightMargin: Style.space(12)
                    text: modelData.name
                    textFormat: Text.PlainText
                    color: overviewCourseLink.containsMouse ? root.urgent : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight

                    MouseArea {
                      id: overviewCourseLink
                      anchors.fill: parent
                      enabled: root.canvasItemUrl(modelData) !== ""
                      hoverEnabled: enabled
                      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                      onClicked: root.openCourse(modelData)
                    }
                  }
                  Text {
                    id: overviewGrade
                    anchors.right: parent.right
                    text: root.teaching
                      ? String(modelData.needs_grading_count || 0) + " TO GRADE"
                      : root.grade(modelData)
                    textFormat: Text.PlainText
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }
                }

                PanelSeparator {
                  visible: index < root.courses.length - 1
                  width: parent.width
                  foreground: root.foreground
                  opacity: 0.18
                }
              }
            }

            Text {
              visible: !!root.nextAssignment
              width: parent.width
              text: root.nextAssignment
                ? "Next: " + root.dueLabel(root.nextAssignment.due_at) + " — " + root.nextAssignment.name
                : ""
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Column {
            id: assignmentsPane
            visible: root.errorText === "" && root.roleError === "" && root.selectedPane === 1
            width: parent.width
            spacing: Style.space(9)

            PanelSectionHeader {
              text: root.teaching
                ? "NEXT " + root.days + " DAYS · " + root.assignments.length
                  + " ASSIGNMENTS" + (root.draftCount > 0 ? " · " + root.draftCount + " DRAFT" + (root.draftCount === 1 ? "" : "S") : "")
                : "NEXT " + root.days + " DAYS · " + root.pendingCount + " OPEN"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              visible: root.teaching
                ? root.assignments.length === 0
                : root.openAssignments.length === 0
              width: parent.width
              text: !root.teaching && root.submittedCount > 0
                ? "All upcoming assignments are submitted."
                : "No assignments are due in this window."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: root.teaching ? root.assignments : root.openAssignments
              Column {
                required property var modelData
                required property int index
                width: assignmentsPane.width
                spacing: Style.space(4)

                AssignmentLinkRow {
                  width: parent.width
                  title: String(modelData.name || "Untitled")
                  subtitle: root.assignmentSubtitle(modelData, true)
                  submitted: !!modelData.submitted
                  showSubmissionStatus: !root.teaching
                  locked: root.assignmentLocked(modelData)
                  linkAvailable: root.canvasItemUrl(modelData) !== ""
                  foreground: root.foreground
                  muted: root.dim
                  accent: root.urgent
                  fontFamily: root.fontFamily
                  onActivated: root.openAssignment(modelData)
                }
                PanelSeparator {
                  visible: index < (root.teaching
                    ? root.assignments.length : root.openAssignments.length) - 1
                  width: parent.width
                  foreground: root.foreground
                  opacity: 0.18
                }
              }
            }

            Button {
              visible: !root.teaching && root.submittedCount > 0
              width: parent.width
              text: root.submittedCount + " submitted assignment"
                + (root.submittedCount === 1 ? "" : "s")
              iconText: root.submittedAssignmentsExpanded ? "\uf078" : "\uf054"
              bordered: false
              leftAlign: true
              foreground: root.dim
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              iconSize: Style.font.caption
              horizontalPadding: 0
              onClicked: root.submittedAssignmentsExpanded = !root.submittedAssignmentsExpanded
            }

            Repeater {
              model: !root.teaching && root.submittedAssignmentsExpanded
                ? root.submittedAssignments : []
              Column {
                required property var modelData
                required property int index
                width: assignmentsPane.width
                spacing: Style.space(4)

                AssignmentLinkRow {
                  width: parent.width
                  title: String(modelData.name || "Untitled")
                  subtitle: root.assignmentSubtitle(modelData, true)
                  submitted: true
                  showSubmissionStatus: true
                  locked: root.assignmentLocked(modelData)
                  linkAvailable: root.canvasItemUrl(modelData) !== ""
                  foreground: root.foreground
                  muted: root.dim
                  accent: root.urgent
                  fontFamily: root.fontFamily
                  onActivated: root.openAssignment(modelData)
                }
                PanelSeparator {
                  visible: index < root.submittedAssignments.length - 1
                  width: parent.width
                  foreground: root.foreground
                  opacity: 0.18
                }
              }
            }
          }

          Column {
            id: coursesPane
            visible: root.errorText === "" && root.roleError === "" && root.selectedPane === 2
            width: parent.width
            spacing: Style.space(10)

            Item {
              visible: !!root.selectedCourse
              width: parent.width
              implicitHeight: Math.max(coursePosition.implicitHeight, hideCourseAction.implicitHeight)

              PanelSectionHeader {
                id: coursePosition
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "COURSE " + (root.selectedCourseIndex + 1) + " OF " + root.courses.length
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              PanelActionButton {
                id: hideCourseAction
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                iconText: "\uf070"
                tooltipText: visibilityProc.running && root.pendingHiddenState
                  ? "Hiding course…" : "Hide course"
                enabled: !visibilityProc.running
                foreground: root.foreground
                hoverColor: root.urgent
                fontFamily: root.fontFamily
                onClicked: root.setCourseVisibility(root.selectedCourse, true)
              }
            }

            Item {
              visible: !!root.selectedCourse
              width: parent.width
              implicitHeight: Math.max(previousCourse.implicitHeight, courseCode.implicitHeight, nextCourse.implicitHeight)

              PanelActionButton {
                id: previousCourse
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                iconText: "\uf053"
                tooltipText: "Previous course"
                enabled: root.courses.length > 1
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.selectCourseOffset(-1)
              }

              Text {
                id: courseCode
                anchors.left: previousCourse.right
                anchors.right: nextCourse.left
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: root.selectedCourse
                  ? root.courseLabel(root.selectedCourse, root.selectedCourseIndex) : ""
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
              }

              PanelActionButton {
                id: nextCourse
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                iconText: "\uf054"
                tooltipText: "Next course"
                enabled: root.courses.length > 1
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.selectCourseOffset(1)
              }
            }

            Text {
              id: selectedCourseName
              visible: !!root.selectedCourse
              width: parent.width
              text: root.selectedCourse ? root.selectedCourse.name : ""
              textFormat: Text.PlainText
              color: selectedCourseLink.containsMouse ? root.urgent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap

              MouseArea {
                id: selectedCourseLink
                anchors.fill: parent
                enabled: root.canvasItemUrl(root.selectedCourse) !== ""
                hoverEnabled: enabled
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.openCourse(root.selectedCourse)
              }
            }

            Text {
              visible: !!root.selectedCourse
              width: parent.width
              text: root.courseStatus(root.selectedCourse)
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              horizontalAlignment: Text.AlignHCenter
            }

            PanelSectionHeader {
              visible: !!root.selectedCourse
              text: root.teaching
                ? "UPCOMING ASSIGNMENTS"
                : "UPCOMING ASSIGNMENTS · "
                  + root.selectedCourseOpenAssignments.length + " OPEN"
              foreground: root.foreground
              fontFamily: root.fontFamily
              topPadding: Math.ceil(fontSize * 0.15) + Style.space(4)
            }

            Text {
              visible: root.selectedCourse && (root.teaching
                ? root.selectedCourseAssignments.length === 0
                : root.selectedCourseOpenAssignments.length === 0)
              width: parent.width
              text: !root.teaching && root.selectedCourseSubmittedAssignments.length > 0
                ? "All upcoming assignments are submitted."
                : "No assignments due in the next " + root.days + " days."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: root.teaching
                ? root.selectedCourseAssignments : root.selectedCourseOpenAssignments
              Column {
                required property var modelData
                required property int index
                width: coursesPane.width
                spacing: Style.space(4)

                AssignmentLinkRow {
                  width: parent.width
                  title: String(modelData.name || "Untitled")
                  subtitle: root.assignmentSubtitle(modelData, false)
                  submitted: !!modelData.submitted
                  showSubmissionStatus: !root.teaching
                  locked: root.assignmentLocked(modelData)
                  linkAvailable: root.canvasItemUrl(modelData) !== ""
                  foreground: root.foreground
                  muted: root.dim
                  accent: root.urgent
                  fontFamily: root.fontFamily
                  onActivated: root.openAssignment(modelData)
                }
                PanelSeparator {
                  visible: index < (root.teaching
                    ? root.selectedCourseAssignments.length
                    : root.selectedCourseOpenAssignments.length) - 1
                  width: parent.width
                  foreground: root.foreground
                  opacity: 0.18
                }
              }
            }

            Button {
              visible: !root.teaching
                && root.selectedCourseSubmittedAssignments.length > 0
              width: parent.width
              text: root.selectedCourseSubmittedAssignments.length
                + " submitted assignment"
                + (root.selectedCourseSubmittedAssignments.length === 1 ? "" : "s")
              iconText: root.submittedAssignmentsExpanded ? "\uf078" : "\uf054"
              bordered: false
              leftAlign: true
              foreground: root.dim
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              iconSize: Style.font.caption
              horizontalPadding: 0
              onClicked: root.submittedAssignmentsExpanded = !root.submittedAssignmentsExpanded
            }

            Repeater {
              model: !root.teaching && root.submittedAssignmentsExpanded
                ? root.selectedCourseSubmittedAssignments : []
              Column {
                required property var modelData
                required property int index
                width: coursesPane.width
                spacing: Style.space(4)

                AssignmentLinkRow {
                  width: parent.width
                  title: String(modelData.name || "Untitled")
                  subtitle: root.assignmentSubtitle(modelData, false)
                  submitted: true
                  showSubmissionStatus: true
                  locked: root.assignmentLocked(modelData)
                  linkAvailable: root.canvasItemUrl(modelData) !== ""
                  foreground: root.foreground
                  muted: root.dim
                  accent: root.urgent
                  fontFamily: root.fontFamily
                  onActivated: root.openAssignment(modelData)
                }
                PanelSeparator {
                  visible: index < root.selectedCourseSubmittedAssignments.length - 1
                  width: parent.width
                  foreground: root.foreground
                  opacity: 0.18
                }
              }
            }

            PanelSectionHeader {
              visible: !!root.selectedCourse
              text: "RECENT ANNOUNCEMENTS"
              foreground: root.foreground
              fontFamily: root.fontFamily
              topPadding: Math.ceil(fontSize * 0.15) + Style.space(4)
            }

            Text {
              visible: !!root.selectedCourse && root.selectedCourseRecentAnnouncements.length === 0
              width: parent.width
              text: "No recent announcements."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: root.selectedCourseRecentAnnouncements
              Column {
                required property var modelData
                required property int index
                width: coursesPane.width
                spacing: Style.space(4)

                AssignmentLinkRow {
                  width: parent.width
                  title: String(modelData.title || "Untitled announcement")
                  subtitle: root.announcementSubtitle(modelData)
                  submitted: false
                  showSubmissionStatus: false
                  locked: false
                  linkAvailable: root.canvasItemUrl(modelData) !== ""
                  foreground: root.foreground
                  muted: root.dim
                  accent: root.urgent
                  fontFamily: root.fontFamily
                  onActivated: root.openAssignment(modelData)
                }
                Text {
                  visible: String(modelData.excerpt || "") !== ""
                  width: parent.width
                  text: String(modelData.excerpt || "")
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                  maximumLineCount: 3
                  elide: Text.ElideRight
                }
                PanelSeparator {
                  visible: index < root.selectedCourseRecentAnnouncements.length - 1
                  width: parent.width
                  foreground: root.foreground
                  opacity: 0.18
                }
              }
            }

            PanelSectionHeader {
              visible: !!root.selectedCourse
                && root.selectedCourseUnreadConversations.length > 0
              text: "MESSAGES · " + root.selectedCourseUnreadConversations.length + " UNREAD"
              foreground: root.foreground
              fontFamily: root.fontFamily
              topPadding: Math.ceil(fontSize * 0.15) + Style.space(4)
            }

            Repeater {
              model: root.selectedCourseRecentUnreadConversations
              Column {
                required property var modelData
                required property int index
                width: coursesPane.width
                spacing: Style.space(4)

                AssignmentLinkRow {
                  width: parent.width
                  title: String(modelData.subject || "No subject")
                  subtitle: root.conversationSubtitle(modelData)
                  submitted: false
                  showSubmissionStatus: false
                  locked: false
                  linkAvailable: root.canvasItemUrl(modelData) !== ""
                  foreground: root.foreground
                  muted: root.dim
                  accent: root.urgent
                  fontFamily: root.fontFamily
                  onActivated: root.openAssignment(modelData)
                }
                Text {
                  visible: String(modelData.last_message || "") !== ""
                  width: parent.width
                  text: String(modelData.last_message || "")
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                  maximumLineCount: 3
                  elide: Text.ElideRight
                }
                PanelSeparator {
                  visible: index < root.selectedCourseRecentUnreadConversations.length - 1
                  width: parent.width
                  foreground: root.foreground
                  opacity: 0.18
                }
              }
            }

            PanelSectionHeader {
              visible: !!root.selectedCourse
              text: "DISCUSSIONS"
              foreground: root.foreground
              fontFamily: root.fontFamily
              topPadding: Math.ceil(fontSize * 0.15) + Style.space(4)
            }

            Text {
              visible: !!root.selectedCourse && root.selectedCourseRecentDiscussions.length === 0
              width: parent.width
              text: "No recent discussions."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: root.selectedCourseRecentDiscussions
              Column {
                required property var modelData
                required property int index
                width: coursesPane.width
                spacing: Style.space(4)

                AssignmentLinkRow {
                  width: parent.width
                  title: String(modelData.title || "Untitled discussion")
                  subtitle: root.discussionSubtitle(modelData)
                  submitted: false
                  showSubmissionStatus: false
                  locked: !!modelData.locked
                  linkAvailable: root.canvasItemUrl(modelData) !== ""
                  foreground: root.foreground
                  muted: root.dim
                  accent: root.urgent
                  fontFamily: root.fontFamily
                  onActivated: root.openAssignment(modelData)
                }
                Text {
                  visible: String(modelData.excerpt || "") !== ""
                  width: parent.width
                  text: String(modelData.excerpt || "")
                  textFormat: Text.PlainText
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                  maximumLineCount: 3
                  elide: Text.ElideRight
                }
                PanelSeparator {
                  visible: index < root.selectedCourseRecentDiscussions.length - 1
                  width: parent.width
                  foreground: root.foreground
                  opacity: 0.18
                }
              }
            }

            Button {
              visible: root.hiddenCourses.length > 0
              width: parent.width
              text: root.hiddenCourses.length + " hidden course"
                + (root.hiddenCourses.length === 1 ? "" : "s")
              iconText: root.hiddenCoursesExpanded ? "\uf078" : "\uf054"
              bordered: false
              leftAlign: true
              foreground: root.dim
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              iconSize: Style.font.caption
              horizontalPadding: 0
              onClicked: root.hiddenCoursesExpanded = !root.hiddenCoursesExpanded
            }

            Text {
              visible: root.hiddenCoursesExpanded && root.hiddenCourses.length > 0
              width: parent.width
              text: "Hidden courses are excluded from assignments, announcements, discussions, messages, counts, alerts, and assignment API requests."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: root.hiddenCoursesExpanded ? root.hiddenCourses : []
              Column {
                required property var modelData
                required property int index
                width: coursesPane.width
                spacing: Style.space(7)

                Item {
                  width: parent.width
                  implicitHeight: Math.max(hiddenCourseText.implicitHeight, unhideCourseAction.implicitHeight)

                  Column {
                    id: hiddenCourseText
                    anchors.left: parent.left
                    anchors.right: unhideCourseAction.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(1)
                    Text {
                      width: parent.width
                      text: modelData.name
                      textFormat: Text.PlainText
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      elide: Text.ElideRight
                    }
                    Text {
                      visible: String(modelData.code || "") !== ""
                      width: parent.width
                      text: String(modelData.code || "")
                      textFormat: Text.PlainText
                      color: Qt.darker(root.dim, 1.25)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }

                  PanelActionButton {
                    id: unhideCourseAction
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    iconText: "\uf06e"
                    tooltipText: visibilityProc.running && !root.pendingHiddenState
                      && root.pendingVisibilityCourse
                      && String(root.pendingVisibilityCourse.id) === String(modelData.id)
                      ? "Unhiding course…" : "Unhide course"
                    enabled: !visibilityProc.running
                    foreground: root.dim
                    fontFamily: root.fontFamily
                    onClicked: root.setCourseVisibility(modelData, false)
                  }
                }

                PanelSeparator {
                  visible: index < root.hiddenCourses.length - 1
                  width: parent.width
                  foreground: root.foreground
                  opacity: 0.12
                }
              }
            }
          }

          PanelSeparator { width: parent.width; foreground: root.foreground; opacity: 0.45 }

          Text {
            width: parent.width
            text: "Right-click or press R to refresh · L to sign in · ←/→ changes views"
              + (root.showRoleSwitch ? " · S/T changes role" : "")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          Button {
            width: parent.width
            text: root.showSetup ? "Hide setup" : "Setup"
            iconText: root.showSetup ? "\uf078" : "\uf054"
            bordered: false
            leftAlign: true
            foreground: root.dim
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            iconSize: Style.font.caption
            horizontalPadding: 0
            onClicked: root.showSetup = !root.showSetup
          }
        }
      }
    }
  }
}
