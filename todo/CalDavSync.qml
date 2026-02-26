import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

Item {
  id: root

  property var pluginApi: null
  property var mainInstance: null

  // CalDAV configuration (bound from pluginSettings)
  readonly property bool enabled: pluginApi?.pluginSettings?.caldavEnabled ?? false
  readonly property string serverUrl: pluginApi?.pluginSettings?.caldavUrl ?? ""
  readonly property string username: pluginApi?.pluginSettings?.caldavUsername ?? ""
  readonly property string passwordType: pluginApi?.pluginSettings?.caldavPasswordType ?? "command"
  readonly property string passwordCmd: pluginApi?.pluginSettings?.caldavPasswordCmd ?? ""
  readonly property string passwordFile: pluginApi?.pluginSettings?.caldavPasswordFile ?? ""
  readonly property int syncInterval: pluginApi?.pluginSettings?.caldavSyncInterval ?? 300

  // Sync state
  property bool isSyncing: false
  property string lastSyncTime: ""
  property string lastError: ""
  property string _cachedPassword: ""

  // Signals for Main.qml
  signal syncCompleted(var remoteTodos)
  signal syncError(string message)

  // ============================================
  // Password Retrieval
  // ============================================

  Process {
    id: passwordProcess
    command: {
      if (root.passwordType === "file") {
        return ["cat", root.passwordFile];
      } else {
        // "command" mode — split on spaces for simple commands
        return ["sh", "-c", root.passwordCmd];
      }
    }

    stdout: StdioCollector {
      onStreamFinished: {
        var pw = this.text.trim();
        if (pw.length > 0) {
          root._cachedPassword = pw;
          root._startSync();
        } else {
          root._handleError("Password command/file returned empty result");
        }
      }
    }

    stderr: StdioCollector {
      onStreamFinished: {
        if (this.text.trim().length > 0) {
          Logger.w("CalDavSync", "Password retrieval stderr: " + this.text.trim());
        }
      }
    }

    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) {
        root._handleError("Password retrieval failed (exit code " + exitCode + ")");
      }
    }
  }

  // ============================================
  // CalDAV Discovery (PROPFIND)
  // ============================================

  Process {
    id: propfindProcess
    stdout: StdioCollector {
      onStreamFinished: {
        root._handlePropfindResponse(this.text);
      }
    }
    stderr: StdioCollector {}

    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0 && !root._propfindHandled) {
        root._handleError("PROPFIND request failed (exit code " + exitCode + ")");
      }
    }
  }

  property bool _propfindHandled: false

  // ============================================
  // CalDAV GET (individual VTODO)
  // ============================================

  property var _pendingGets: []
  property var _fetchedRemoteTodos: []
  property int _completedGets: 0
  property int _totalGets: 0

  Process {
    id: getProcess
    property string currentHref: ""
    property string currentEtag: ""

    stdout: StdioCollector {
      onStreamFinished: {
        root._handleGetResponse(getProcess.currentHref, getProcess.currentEtag, this.text);
      }
    }
    stderr: StdioCollector {}
  }

  // ============================================
  // CalDAV PUT (create/update VTODO)
  // ============================================

  Process {
    id: putProcess
    property string currentUid: ""

    stdout: StdioCollector {
      onStreamFinished: {
        Logger.i("CalDavSync", "PUT completed for UID: " + putProcess.currentUid);
      }
    }
    stderr: StdioCollector {}

    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) {
        Logger.e("CalDavSync", "PUT failed for UID " + putProcess.currentUid + " (exit code " + exitCode + ")");
      }
      root._processNextPush();
    }
  }

  // ============================================
  // CalDAV DELETE
  // ============================================

  Process {
    id: deleteProcess
    property string currentUid: ""

    stdout: StdioCollector {}
    stderr: StdioCollector {}

    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0) {
        Logger.e("CalDavSync", "DELETE failed for UID " + deleteProcess.currentUid + " (exit code " + exitCode + ")");
      }
    }
  }

  // ============================================
  // Push queue
  // ============================================

  property var _pushQueue: []

  // ============================================
  // Periodic Sync Timer
  // ============================================

  Timer {
    id: syncTimer
    interval: root.syncInterval * 1000
    repeat: true
    running: root.enabled && root.serverUrl.length > 0
    onTriggered: root.syncAll()
  }

  // ============================================
  // Public API
  // ============================================

  function syncAll() {
    if (!root.enabled || root.isSyncing) return;
    if (!root.serverUrl || root.serverUrl.trim() === "") {
      _handleError("CalDAV server URL is not configured");
      return;
    }

    Logger.i("CalDavSync", "Starting sync...");
    root.isSyncing = true;
    root.lastError = "";

    // Step 1: Retrieve password, then start sync
    if (root._cachedPassword.length > 0) {
      _startSync();
    } else {
      _fetchPassword();
    }
  }

  function pushTodo(todo) {
    if (!root.enabled || !todo || !todo.uid) return;

    // Enrich todo with page name for CATEGORIES tag
    var enriched = JSON.parse(JSON.stringify(todo));
    if (root.mainInstance && root.mainInstance.rawPages) {
      var pages = root.mainInstance.rawPages;
      for (var i = 0; i < pages.length; i++) {
        if (pages[i].id === todo.pageId) {
          enriched._pageName = pages[i].name;
          break;
        }
      }
    }

    _pushQueue.push(enriched);

    if (!putProcess.running) {
      _ensurePasswordThen(function() {
        _processNextPush();
      });
    }
  }

  function deleteTodoRemote(uid) {
    if (!root.enabled || !uid) return;
    _ensurePasswordThen(function() {
      var url = _normalizeUrl(root.serverUrl) + uid + ".ics";
      deleteProcess.currentUid = uid;
      deleteProcess.command = [
        "curl", "-s", "--max-time", "15",
        "-X", "DELETE",
        "-u", root.username + ":" + root._cachedPassword,
        url
      ];
      deleteProcess.running = true;
    });
  }

  // ============================================
  // Internal Implementation
  // ============================================

  function _fetchPassword() {
    if ((root.passwordType === "command" && (!root.passwordCmd || root.passwordCmd.trim() === "")) ||
        (root.passwordType === "file" && (!root.passwordFile || root.passwordFile.trim() === ""))) {
      _handleError("No password " + root.passwordType + " configured");
      return;
    }
    passwordProcess.running = true;
  }

  function _ensurePasswordThen(callback) {
    if (root._cachedPassword.length > 0) {
      callback();
    } else {
      // Simple approach: fetch password and use a timer to wait
      root._pendingCallback = callback;
      _fetchPassword();
    }
  }

  property var _pendingCallback: null

  // Called after password is retrieved
  function _startSync() {
    // Execute any pending callback first
    if (root._pendingCallback) {
      var cb = root._pendingCallback;
      root._pendingCallback = null;
      cb();
      return;
    }

    // Perform PROPFIND to discover all VTODOs
    root._propfindHandled = false;
    root._fetchedRemoteTodos = [];
    root._pendingGets = [];
    root._completedGets = 0;
    root._totalGets = 0;

    var url = _normalizeUrl(root.serverUrl);

    var propfindBody = '<?xml version="1.0" encoding="utf-8"?>' +
      '<d:propfind xmlns:d="DAV:" xmlns:cs="urn:ietf:params:xml:ns:caldav">' +
      '<d:prop><d:getetag/><d:getcontenttype/></d:prop>' +
      '</d:propfind>';

    propfindProcess.command = [
      "curl", "-s", "--max-time", "20",
      "-X", "PROPFIND",
      "-H", "Depth: 1",
      "-H", "Content-Type: application/xml; charset=utf-8",
      "-u", root.username + ":" + root._cachedPassword,
      "-d", propfindBody,
      url
    ];
    propfindProcess.running = true;
  }

  function _handlePropfindResponse(responseText) {
    root._propfindHandled = true;

    if (!responseText || responseText.trim() === "") {
      _handleError("Empty PROPFIND response");
      return;
    }

    // Parse the multistatus XML response to extract hrefs and etags
    var entries = _parsePropfindXml(responseText);

    if (entries.length === 0) {
      Logger.i("CalDavSync", "No remote VTODOs found");
      _finishPull();
      return;
    }

    // Queue GET requests for each .ics resource
    root._pendingGets = entries;
    root._totalGets = entries.length;
    root._completedGets = 0;
    root._fetchedRemoteTodos = [];

    _processNextGet();
  }

  function _parsePropfindXml(xml) {
    var entries = [];
    // Simple regex-based parsing for DAV:response elements
    var responseRegex = /<(?:d:|D:|DAV:)?response>([\s\S]*?)<\/(?:d:|D:|DAV:)?response>/gi;
    var hrefRegex = /<(?:d:|D:|DAV:)?href>(.*?)<\/(?:d:|D:|DAV:)?href>/i;
    var etagRegex = /<(?:d:|D:|DAV:)?getetag>"?(.*?)"?<\/(?:d:|D:|DAV:)?getetag>/i;
    var contentTypeRegex = /<(?:d:|D:|DAV:)?getcontenttype>(.*?)<\/(?:d:|D:|DAV:)?getcontenttype>/i;

    var match;
    while ((match = responseRegex.exec(xml)) !== null) {
      var block = match[1];
      var hrefMatch = hrefRegex.exec(block);
      var etagMatch = etagRegex.exec(block);
      var ctMatch = contentTypeRegex.exec(block);

      if (hrefMatch) {
        var href = hrefMatch[1].trim();
        var etag = etagMatch ? etagMatch[1].trim() : "";
        var contentType = ctMatch ? ctMatch[1].trim() : "";

        // Only process .ics files (VTODOs)
        if (href.endsWith(".ics") && contentType.indexOf("text/calendar") !== -1) {
          entries.push({ href: href, etag: etag });
        } else if (href.endsWith(".ics") && contentType === "") {
          // Some servers don't return content-type in PROPFIND
          entries.push({ href: href, etag: etag });
        }
      }
    }

    Logger.i("CalDavSync", "PROPFIND found " + entries.length + " calendar resources");
    return entries;
  }

  function _processNextGet() {
    if (root._pendingGets.length === 0) {
      _finishPull();
      return;
    }

    var entry = root._pendingGets.shift();
    var url = _resolveHref(entry.href);

    getProcess.currentHref = entry.href;
    getProcess.currentEtag = entry.etag;
    getProcess.command = [
      "curl", "-s", "--max-time", "15",
      "-u", root.username + ":" + root._cachedPassword,
      url
    ];
    getProcess.running = true;
  }

  function _handleGetResponse(href, etag, icsData) {
    root._completedGets++;

    if (icsData && icsData.trim().length > 0) {
      var todo = _parseVtodo(icsData, etag, href);
      if (todo) {
        root._fetchedRemoteTodos.push(todo);
      }
    }

    // Fetch next or finish
    if (root._pendingGets.length > 0) {
      _processNextGet();
    } else {
      _finishPull();
    }
  }

  function _finishPull() {
    Logger.i("CalDavSync", "Pull complete: " + root._fetchedRemoteTodos.length + " remote todos");
    root.isSyncing = false;
    root.lastSyncTime = new Date().toLocaleString();
    root.lastError = "";

    // Push local-only todos to server after pull
    syncCompleted(root._fetchedRemoteTodos);
  }

  // ============================================
  // Push Logic
  // ============================================

  function _processNextPush() {
    if (root._pushQueue.length === 0) return;

    var todo = root._pushQueue.shift();
    var icsData = _todoToVtodo(todo);
    var url = _normalizeUrl(root.serverUrl) + todo.uid + ".ics";

    putProcess.currentUid = todo.uid;
    putProcess.command = [
      "curl", "-s", "--max-time", "15",
      "-X", "PUT",
      "-H", "Content-Type: text/calendar; charset=utf-8",
      "-u", root.username + ":" + root._cachedPassword,
      "-d", icsData,
      url
    ];
    putProcess.running = true;
  }

  // ============================================
  // iCalendar ↔ Todo Conversion
  // ============================================

  function _todoToVtodo(todo) {
    var status = todo.completed ? "COMPLETED" : "NEEDS-ACTION";
    var priority = _priorityToIcal(todo.priority);
    var now = _toIcalDate(new Date());
    var created = todo.createdAt ? _toIcalDate(new Date(todo.createdAt)) : now;

    var lines = [
      "BEGIN:VCALENDAR",
      "VERSION:2.0",
      "PRODID:-//Noctalia Todo Plugin//EN",
      "BEGIN:VTODO",
      "UID:" + todo.uid,
      "DTSTAMP:" + now,
      "CREATED:" + created,
      "LAST-MODIFIED:" + now,
      "SUMMARY:" + _escapeIcalText(todo.text || ""),
      "STATUS:" + status,
      "PRIORITY:" + priority
    ];

    if (todo.details && todo.details.trim().length > 0) {
      lines.push("DESCRIPTION:" + _escapeIcalText(todo.details));
    }

    // Add page name as CATEGORIES tag
    if (todo._pageName) {
      lines.push("CATEGORIES:" + _escapeIcalText(todo._pageName));
    }

    if (todo.completed) {
      lines.push("COMPLETED:" + now);
    }

    lines.push("END:VTODO");
    lines.push("END:VCALENDAR");

    return lines.join("\r\n");
  }

  function _parseVtodo(icsData, etag, href) {
    // Extract VTODO block
    var vtodoMatch = icsData.match(/BEGIN:VTODO([\s\S]*?)END:VTODO/i);
    if (!vtodoMatch) return null;

    var block = vtodoMatch[1];

    var uid = _extractIcalProp(block, "UID");
    if (!uid) return null;

    var summary = _unescapeIcalText(_extractIcalProp(block, "SUMMARY") || "");
    var status = _extractIcalProp(block, "STATUS") || "NEEDS-ACTION";
    var priorityVal = parseInt(_extractIcalProp(block, "PRIORITY") || "0");
    var description = _unescapeIcalText(_extractIcalProp(block, "DESCRIPTION") || "");
    var created = _extractIcalProp(block, "CREATED") || "";
    var categories = _unescapeIcalText(_extractIcalProp(block, "CATEGORIES") || "");

    return {
      uid: uid,
      text: summary,
      completed: (status.toUpperCase() === "COMPLETED"),
      priority: _icalToPriority(priorityVal),
      details: description,
      createdAt: created ? _fromIcalDate(created) : new Date().toISOString(),
      categories: categories,
      etag: etag,
      href: href,
      isRemote: true
    };
  }

  function _extractIcalProp(block, propName) {
    // Handle folded lines (lines starting with space are continuations)
    var unfolded = block.replace(/\r?\n[ \t]/g, "");
    var regex = new RegExp("^" + propName + "(?:;[^:]*)?:(.*)$", "im");
    var match = regex.exec(unfolded);
    return match ? match[1].trim() : null;
  }

  function _escapeIcalText(text) {
    return text.replace(/\\/g, "\\\\").replace(/;/g, "\\;").replace(/,/g, "\\,").replace(/\n/g, "\\n");
  }

  function _unescapeIcalText(text) {
    return text.replace(/\\n/g, "\n").replace(/\\,/g, ",").replace(/\\;/g, ";").replace(/\\\\/g, "\\");
  }

  function _priorityToIcal(priority) {
    switch (priority) {
      case "high": return "1";
      case "medium": return "5";
      case "low": return "9";
      default: return "0";
    }
  }

  function _icalToPriority(val) {
    if (val >= 1 && val <= 4) return "high";
    if (val === 5) return "medium";
    if (val >= 6 && val <= 9) return "low";
    return "medium";
  }

  function _toIcalDate(date) {
    return date.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
  }

  function _fromIcalDate(icalDate) {
    // Parse iCal date format: 20260226T085300Z
    try {
      var cleaned = icalDate.replace(/(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z?/, "$1-$2-$3T$4:$5:$6Z");
      return new Date(cleaned).toISOString();
    } catch (e) {
      return new Date().toISOString();
    }
  }

  // ============================================
  // URL Helpers
  // ============================================

  function _normalizeUrl(url) {
    if (!url) return "";
    return url.endsWith("/") ? url : url + "/";
  }

  function _resolveHref(href) {
    // If href is absolute (starts with /), construct full URL from server URL
    if (href.startsWith("http://") || href.startsWith("https://")) {
      return href;
    }

    // Extract origin from server URL
    var originMatch = root.serverUrl.match(/^(https?:\/\/[^\/]+)/);
    if (originMatch) {
      return originMatch[1] + href;
    }

    return root.serverUrl + href;
  }

  // ============================================
  // Error Handling
  // ============================================

  function _handleError(message) {
    Logger.e("CalDavSync", message);
    root.isSyncing = false;
    root.lastError = message;
    root._cachedPassword = ""; // Clear cached password on error
    syncError(message);
  }

  // ============================================
  // UUID Generation
  // ============================================

  function generateUid() {
    // Generate a UUID v4-like string
    var chars = "0123456789abcdef";
    var segments = [8, 4, 4, 4, 12];
    var parts = [];
    for (var s = 0; s < segments.length; s++) {
      var seg = "";
      for (var i = 0; i < segments[s]; i++) {
        seg += chars.charAt(Math.floor(Math.random() * 16));
      }
      parts.push(seg);
    }
    return parts.join("-");
  }
}
