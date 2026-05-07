import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Services.UI

Item {
  id: mainRoot

  property var pluginApi: null
  property var rawTodos: []
  property var rawPages: []
  property var _dirtyTodoUids: ({})

  // CalDAV sync integration
  readonly property bool caldavEnabled: pluginApi?.pluginSettings?.caldavEnabled ?? false

  CalDavSync {
    id: caldavSync
    pluginApi: mainRoot.pluginApi
    mainInstance: mainRoot

    onSyncCompleted: function(remoteTodos, syncConfig) {
      _mergeRemoteTodos(remoteTodos, syncConfig);
    }

    onSyncError: function(message) {
      Logger.e("Todo", "CalDAV sync error: " + message);
    }
  }

  // ============================================
  // Initialization
  // ============================================

  Component.onCompleted: {
    if (pluginApi) {
      // Initialize pages config
      if (!pluginApi.pluginSettings.pages) {
        pluginApi.pluginSettings.pages = [
              {
                id: 0,
                name: "General"
              }
            ];
        pluginApi.pluginSettings.current_page_id = 0;
      }

      // Initialize todo config
      if (!pluginApi.pluginSettings.todos) {
        pluginApi.pluginSettings.todos = [];
        pluginApi.pluginSettings.count = 0;
        pluginApi.pluginSettings.completedCount = 0;
      }

      // Initialize display settings
      if (pluginApi.pluginSettings.isExpanded === undefined)
        pluginApi.pluginSettings.isExpanded = false;
      if (pluginApi.pluginSettings.useCustomColors === undefined)
        pluginApi.pluginSettings.useCustomColors = false;

      // Initialize priority colors
      if (!pluginApi.pluginSettings.priorityColors) {
        pluginApi.pluginSettings.priorityColors = {
          "high": Color.mError,
          "medium": Color.mPrimary,
          "low": Color.mOnSurfaceVariant
        };
      }

      // Always create copies to avoid reference issues
      // Panel.qml may reassign pluginApi.pluginSettings.todos
      rawTodos = pluginApi.pluginSettings.todos.slice();
      rawPages = pluginApi.pluginSettings.pages.slice();

      // Data migration: add missing fields to existing todos
      for (var i = 0; i < rawTodos.length; i++) {
        if (rawTodos[i].pageId === undefined)
          rawTodos[i].pageId = 0;
        if (rawTodos[i].priority === undefined || !["high", "medium", "low"].includes(rawTodos[i].priority)) {
          rawTodos[i].priority = "medium";
        }
        if (rawTodos[i].details === undefined)
          rawTodos[i].details = "";
        if (rawTodos[i].uid === undefined)
          rawTodos[i].uid = caldavSync.generateUid();
      }

      pluginApi.saveSettings();

      // Trigger initial CalDAV sync if enabled
      if (caldavEnabled) {
        caldavSync.syncAll();
      }
    }
  }

  // ============================================
  // Persistence Functions
  // ============================================

  function saveTodos() {
    if (!pluginApi || !pluginApi.pluginSettings)
      return;
    pluginApi.pluginSettings.todos = rawTodos.slice();
    pluginApi.pluginSettings.count = rawTodos.length;
    pluginApi.pluginSettings.completedCount = rawTodos.filter(t => t.completed).length;
    pluginApi.saveSettings();
  }

  function savePages() {
    if (!pluginApi || !pluginApi.pluginSettings)
      return;
    pluginApi.pluginSettings.pages = rawPages.slice();
    pluginApi.saveSettings();
  }

  // ============================================
  // IPC Handlers - thin wrappers around core functions
  // ============================================

  IpcHandler {
    target: "plugin:todo"

    // Panel Control
    function togglePanel() {
      if (!pluginApi)
        return;
      pluginApi.withCurrentScreen(screen => {
                                    pluginApi.togglePanel(screen);
                                  });
    }

    // Todo Read Operations
    function getTodos(): string {
      return JSON.stringify(rawTodos);
    }
    function getTodo(id: string): string {
      var todo = findTodo(id);
      return todo ? JSON.stringify(todo) : "";
    }
    function getCount(): string {
      return JSON.stringify({
                              total: rawTodos.length,
                              active: rawTodos.filter(t => !t.completed).length,
                              completed: rawTodos.filter(t => t.completed).length
                            });
    }

    // Todo Create Operations
    function addTodo(text: string, priority: string, pageId: int) {
      if (!text || !text.trim()) {
        ToastService.showError(pluginApi.tr("main.error_text_empty"));
        return;
      }
      if (!["high", "medium", "low"].includes(priority)) {
        ToastService.showError(pluginApi.tr("main.error_invalid_priority"));
        return;
      }
      var targetPageId = (pageId === undefined || pageId === null) ? (pluginApi.pluginSettings.current_page_id ?? 0) : pageId;
      if (!pageExists(targetPageId)) {
        ToastService.showError(pluginApi.tr("main.error_page_not_found"));
        return;
      }

      if (createTodo(text.trim(), priority, targetPageId)) {
        ToastService.showNotice(pluginApi.tr("main.added_new_todo"));
      } else {
        ToastService.showError(pluginApi.tr("main.error_create_failed"));
      }
    }

    function addTodoDefault(text: string) {
      addTodo(text, "medium", pluginApi?.pluginSettings?.current_page_id || 0);
    }

    // Todo Update Operations
    function setTodoPriority(id: string, priority: string) {
      updateTodo(id, {
                   priority: priority
                 }) ? ToastService.showNotice(pluginApi.tr("main.updated_todo_priority")) : ToastService.showError(pluginApi.tr("main.error_update_failed"));
    }
    function setTodoCompleted(id: string, completed: bool) {
      updateTodo(id, {
                   completed: completed
                 }) ? ToastService.showNotice(pluginApi.tr("main.updated_todo")) : ToastService.showError(pluginApi.tr("main.error_update_failed"));
    }
    function setTodoDetails(id: string, details: string) {
      updateTodo(id, {
                   details: details
                 }) ? ToastService.showNotice(pluginApi.tr("main.updated_todo")) : ToastService.showError(pluginApi.tr("main.error_update_failed"));
    }
    function setTodoText(id: string, text: string) {
      updateTodo(id, {
                   text: text
                 }) ? ToastService.showNotice(pluginApi.tr("main.updated_todo")) : ToastService.showError(pluginApi.tr("main.error_update_failed"));
    }
    function toggleTodo(id: string) {
      var todo = findTodo(id);
      if (!todo) {
        ToastService.showError(pluginApi.tr("main.error_todo_not_found"));
        return;
      }
      var completed = !todo.completed;
      updateTodo(id, {
                   completed: completed
                 });
      var action = completed ? pluginApi.tr("main.todo_completed") : pluginApi.tr("main.todo_marked_incomplete");
      ToastService.showNotice(pluginApi.tr("main.todo_status_changed") + action);
    }

    // Todo Delete Operations
    function removeTodo(id: string) {
      deleteTodo(id) ? ToastService.showNotice(pluginApi.tr("main.removed_todo")) : ToastService.showError(pluginApi.tr("main.error_remove_failed"));
    }
    function clearCompleted() {
      var cleared = clearCompletedTodos();
      ToastService.showNotice(pluginApi.tr("main.cleared_completed_todos") + cleared + pluginApi.tr("main.completed_todos_suffix"));
    }
    function clearAll() {
      clearAllTodos();
      ToastService.showNotice(pluginApi.tr("main.cleared_all_todos"));
    }

    // Page Operations
    function getPages(): string {
      return JSON.stringify(rawPages);
    }
    function addPage(name: string) {
      var trimmedName = name.trim();
      if (!trimmedName) {
        ToastService.showError(pluginApi.tr("settings.pages.empty_name"));
        return;
      }
      if (pageNameExists(trimmedName)) {
        ToastService.showError(pluginApi.tr("settings.pages.name_exists"));
        return;
      }
      if (createPage(trimmedName)) {
        ToastService.showNotice(pluginApi.tr("settings.pages.added_page") + trimmedName);
      } else {
        ToastService.showError(pluginApi.tr("settings.pages.error_creating"));
      }
    }
    function renamePage(pageId: int, newName: string) {
      var trimmedName = newName.trim();
      if (!trimmedName) {
        ToastService.showError(pluginApi.tr("settings.pages.empty_name"));
        return;
      }
      if (!pageExists(pageId)) {
        ToastService.showError(pluginApi.tr("main.error_page_not_found"));
        return;
      }
      if (pageNameExistsExcluding(pageId, trimmedName)) {
        ToastService.showError(pluginApi.tr("settings.pages.name_exists"));
        return;
      }
      if (renamePageInternal(pageId, trimmedName)) {
        ToastService.showNotice(pluginApi.tr("settings.pages.renamed_page"));
      } else {
        ToastService.showError(pluginApi.tr("main.error_rename_failed"));
      }
    }
    function removePage(pageId: int) {
      if (pageId === 0) {
        ToastService.showError(pluginApi.tr("settings.pages.cannot_delete_default"));
        return;
      }
      if (isLastPage()) {
        ToastService.showError(pluginApi.tr("settings.pages.cannot_delete_last"));
        return;
      }
      if (!pageExists(pageId)) {
        ToastService.showError(pluginApi.tr("main.error_page_not_found"));
        return;
      }
      if (deletePage(pageId)) {
        ToastService.showNotice(pluginApi.tr("settings.pages.deleted_page"));
      } else {
        ToastService.showError(pluginApi.tr("main.error_delete_failed"));
      }
    }
  }

  // ============================================
  // Core Business Logic - exposed via mainInstance
  // ============================================

  // Create new todo
  function createTodo(text, priority, pageId) {
    var newTodo = {
      id: Date.now(),
      uid: caldavSync.generateUid(),
      text: text,
      completed: false,
      createdAt: new Date().toISOString(),
      pageId: pageId,
      priority: priority,
      details: ""
    };

    var insertIndex = rawTodos.length;
    for (var i = 0; i < rawTodos.length; i++) {
      if (rawTodos[i].pageId === pageId) {
        insertIndex = i;
        break;
      }
    }
    rawTodos.splice(insertIndex, 0, newTodo);
    saveTodos();

    // Push to CalDAV if enabled
    if (caldavEnabled) {
      _markTodoDirty(newTodo.uid);
      caldavSync.pushTodo(newTodo);
    }

    return true;
  }

  // Update todo (supports text/completed/priority/details)
  function updateTodo(id, updates) {
    var index = findTodoIndex(id);
    if (index === -1)
      return false;

    var todo = rawTodos[index];
    var oldCompleted = todo.completed;

    if (updates.text !== undefined)
      rawTodos[index].text = updates.text;
    if (updates.completed !== undefined)
      rawTodos[index].completed = updates.completed;
    if (updates.priority !== undefined)
      rawTodos[index].priority = updates.priority;
    if (updates.details !== undefined)
      rawTodos[index].details = updates.details;

    // If completion status changed, reorder todos
    if (updates.completed !== undefined && oldCompleted !== updates.completed) {
      moveTodoToCorrectPosition(id);
    } else {
      saveTodos();
    }

    // Push update to CalDAV if enabled.
    // Reordering may move the item, so resolve it again by ID.
    var updatedTodo = findTodo(id);
    if (caldavEnabled && updatedTodo && updatedTodo.uid) {
      _markTodoDirty(updatedTodo.uid);
      caldavSync.pushTodo(updatedTodo);
    }

    return true;
  }

  // Delete specific todo
  function deleteTodo(id) {
    var index = findTodoIndex(id);
    if (index === -1)
      return false;
    var todoUid = rawTodos[index].uid;
    rawTodos.splice(index, 1);
    saveTodos();

    // Delete from CalDAV if enabled
    if (caldavEnabled && todoUid) {
      _clearTodoDirty(todoUid);
      caldavSync.deleteTodoRemote(todoUid);
    }

    return true;
  }

  // Clear all completed todos, return count cleared
  function clearCompletedTodos() {
    var deletedUids = [];
    var active = [];

    for (var i = 0; i < rawTodos.length; i++) {
      if (rawTodos[i].completed) {
        if (rawTodos[i].uid) {
          deletedUids.push(rawTodos[i].uid);
        }
      } else {
        active.push(rawTodos[i]);
      }
    }

    var cleared = rawTodos.length - active.length;
    rawTodos.splice(0, rawTodos.length, ...active);
    saveTodos();

    if (caldavEnabled) {
      for (var d = 0; d < deletedUids.length; d++) {
        _clearTodoDirty(deletedUids[d]);
        caldavSync.deleteTodoRemote(deletedUids[d]);
      }
    }

    return cleared;
  }

  // Clear all todos
  function clearAllTodos() {
    _dirtyTodoUids = {};
    rawTodos.splice(0, rawTodos.length);
    saveTodos();
  }

  // Create new page
  function createPage(name) {
    var newId = rawPages.length > 0 ? Math.max(...rawPages.map(p => p.id)) + 1 : 0;
    rawPages.push({
                    id: newId,
                    name: name
                  });
    savePages();

    _reassignTodosForPageName(newId, name);

    return true;
  }

  // Rename page (internal)
  function renamePageInternal(pageId, newName) {
    for (var i = 0; i < rawPages.length; i++) {
      if (rawPages[i].id === pageId) {
        rawPages[i].name = newName;
        break;
      }
    }
    savePages();

    _reassignTodosForPageName(pageId, newName);

    return true;
  }

  // Delete page (moves associated todos to default page)
  function deletePage(pageId) {
    for (var i = 0; i < rawTodos.length; i++) {
      if (rawTodos[i].pageId === pageId)
        rawTodos[i].pageId = 0;
    }
    rawPages.splice(0, rawPages.length, ...rawPages.filter(p => p.id !== pageId));
    if (pluginApi.pluginSettings.current_page_id === pageId)
      pluginApi.pluginSettings.current_page_id = 0;
    saveTodos();
    savePages();
    return true;
  }

  // Move todo to correct position based on completion status
  // Called when todo completion status changes
  function moveTodoToCorrectPosition(todoId) {
    if (!rawTodos || rawTodos.length === 0)
      return;

    // Find the todo
    var todoIndex = -1;
    for (var i = 0; i < rawTodos.length; i++) {
      if (rawTodos[i].id == todoId) {
        todoIndex = i;
        break;
      }
    }
    if (todoIndex === -1)
      return;

    var movedTodo = rawTodos[todoIndex];
    var todoPageId = movedTodo.pageId;  // Use the todo's own pageId

    // Remove from current position
    rawTodos.splice(todoIndex, 1);

    // Find correct insertion position within the todo's page
    var insertIndex = -1;

    if (movedTodo.completed) {
      // Completed → Place at the END of page's todos
      insertIndex = rawTodos.length;
    } else {
      // Uncompleted → Place BEFORE the first completed todo in that page
      insertIndex = 0;
      for (var i = 0; i < rawTodos.length; i++) {
        if (rawTodos[i].pageId === todoPageId) {
          if (rawTodos[i].completed) {
            insertIndex = i;
            break;
          }
        }
      }
    }

    // Insert at the calculated position
    rawTodos.splice(insertIndex, 0, movedTodo);
    saveTodos();
  }

  // Move todo by index (for drag reorder in Panel)
  function moveTodo(todoId, fromIndex: int, toIndex: int, pageId: int) {
    if (!rawTodos || rawTodos.length === 0)
      return;

    // Find the todo in rawTodos
    var todo = null;
    var fromGlobalIndex = -1;
    for (var i = 0; i < rawTodos.length; i++) {
      if (rawTodos[i].id == todoId) {
        todo = rawTodos[i];
        fromGlobalIndex = i;
        break;
      }
    }
    if (!todo || fromGlobalIndex === -1)
      return;

    // Get todos for the target page
    var pageTodos = rawTodos.filter(function (t) {
      return t.pageId === pageId;
    });

    if (fromIndex < 0 || fromIndex >= pageTodos.length)
      return;
    if (toIndex < 0 || toIndex >= pageTodos.length)
      return false;

    // Remove from current position
    rawTodos.splice(fromGlobalIndex, 1);

    // Find target position in rawTodos
    var toGlobalIndex = -1;
    var count = 0;
    for (var i = 0; i < rawTodos.length; i++) {
      if (rawTodos[i].pageId === pageId) {
        if (count === toIndex) {
          toGlobalIndex = i;
          break;
        }
        count++;
      }
    }

    // If target is at end of page items or page is empty
    if (toGlobalIndex === -1) {
      for (var i = rawTodos.length - 1; i >= 0; i--) {
        if (rawTodos[i].pageId === pageId) {
          toGlobalIndex = i + 1;
          break;
        }
      }
      if (toGlobalIndex === -1) {
        // Insert at end of array
        toGlobalIndex = rawTodos.length;
      }
    }

    // Insert at target position
    rawTodos.splice(toGlobalIndex, 0, todo);
    saveTodos();
  }

  // Move todo by page-relative index (for drag reorder in Panel)
  // Always operates within the current page
  function moveTodoItem(fromIndex: int, toIndex: int) {
    if (!rawTodos || rawTodos.length === 0)
      return;

    var pageId = pluginApi?.pluginSettings?.current_page_id ?? 0;
    var pageTodos = rawTodos.filter(t => t.pageId === pageId);

    if (fromIndex < 0 || fromIndex >= pageTodos.length)
      return;
    if (toIndex < 0 || toIndex >= pageTodos.length)
      return;

    var todoId = pageTodos[fromIndex].id;
    moveTodo(todoId, fromIndex, toIndex, pageId);
  }

  // ============================================
  // Validation Functions
  // ============================================

  // Find todo by ID, return todo object or null
  function findTodo(id) {
    return rawTodos.find(t => t.id == id) || null;
  }
  // Find todo index by ID, return index or -1
  function findTodoIndex(id) {
    return rawTodos.findIndex(t => t.id == id);
  }

  // Check if page exists
  function pageExists(pageId) {
    return rawPages.some(p => p.id === pageId);
  }
  // Check if page name exists (case-insensitive)
  function pageNameExists(name) {
    return rawPages.some(p => p.name.toLowerCase() === name.toLowerCase());
  }
  // Check if page name exists, excluding specific page (for rename validation)
  function pageNameExistsExcluding(excludeId, name) {
    return rawPages.some(p => p.id !== excludeId && p.name.toLowerCase() === name.toLowerCase());
  }
  // Check if it's the last page (prevent deleting last page)
  function isLastPage() {
    return rawPages.length <= 1;
  }

  // Calculate completed count
  function calculateCompletedCount() {
    return rawTodos.filter(t => t.completed).length;
  }

  // ============================================
  // CalDAV Sync Merge Logic
  // ============================================

  function _mergeRemoteTodos(remoteTodos, syncConfig) {
    if (!remoteTodos || remoteTodos.length === 0) {
      // No remote todos, push all local todos to server
      _pushLocalOnlyTodos({}, syncConfig);
      return;
    }

    var localByUid = {};
    for (var i = 0; i < rawTodos.length; i++) {
      if (rawTodos[i].uid) {
        localByUid[rawTodos[i].uid] = rawTodos[i];
      }
    }

    var remoteUids = {};
    var currentPageId = pluginApi?.pluginSettings?.current_page_id ?? 0;
    var changed = false;
    var localWinsToPush = [];

    // Merge remote → local
    for (var r = 0; r < remoteTodos.length; r++) {
      var remote = remoteTodos[r];
      remoteUids[remote.uid] = true;

      if (localByUid[remote.uid]) {
        // Update existing local todo with remote data unless there is a pending local change.
        var local = localByUid[remote.uid];
        var remotePageId = _resolveTargetPageId(remote.categories, local.pageId);
        var differs = local.text !== remote.text || local.completed !== remote.completed ||
            local.priority !== remote.priority || local.details !== remote.details ||
            local.pageId !== remotePageId;

        if (_isTodoDirty(remote.uid)) {
          if (differs) {
            localWinsToPush.push(local.uid);
          } else {
            _clearTodoDirty(remote.uid);
          }
          continue;
        }

        if (differs) {
          var idx = findTodoIndex(local.id);
          if (idx !== -1) {
            rawTodos[idx].text = remote.text;
            rawTodos[idx].completed = remote.completed;
            rawTodos[idx].priority = remote.priority;
            rawTodos[idx].details = remote.details;
            rawTodos[idx].categories = remote.categories || "";
            rawTodos[idx].pageId = remotePageId;
            changed = true;
          }
        }
      } else {
        // New remote todo — add locally
        var targetPageId = _resolveTargetPageId(remote.categories, currentPageId);

        var newTodo = {
          id: Date.now() + r, // Ensure unique ID
          uid: remote.uid,
          text: remote.text,
          completed: remote.completed,
          createdAt: remote.createdAt,
          pageId: targetPageId,
          priority: remote.priority,
          details: remote.details,
          categories: remote.categories || ""
        };
        rawTodos.push(newTodo);
        changed = true;
      }
    }

    if (changed) {
      saveTodos();
    }

    // Push only local todos that were missing remotely to avoid sync churn.
    _pushLocalOnlyTodos(remoteUids, syncConfig);

    for (var l = 0; l < localWinsToPush.length; l++) {
      var localTodo = localByUid[localWinsToPush[l]];
      if (localTodo) {
        caldavSync.pushTodo(localTodo, syncConfig);
      }
    }
  }

  function _pushLocalOnlyTodos(remoteUids, syncConfig) {
    if (!caldavEnabled) return;

    for (var i = 0; i < rawTodos.length; i++) {
      var uid = rawTodos[i].uid;
      if (uid && !remoteUids[uid]) {
        caldavSync.pushTodo(rawTodos[i], syncConfig);
      }
    }
  }

  function _normalizeTagName(value) {
    return (value || "").trim().toLowerCase();
  }

  function _resolveTargetPageId(categories, fallbackPageId) {
    if (!categories || categories.trim().length === 0) {
      return fallbackPageId;
    }

    var categoryName = _normalizeTagName(categories.split(",")[0]);
    if (!categoryName) {
      return fallbackPageId;
    }

    for (var p = 0; p < rawPages.length; p++) {
      if (_normalizeTagName(rawPages[p].name) === categoryName) {
        return rawPages[p].id;
      }
    }

    return fallbackPageId;
  }

  function _reassignTodosForPageName(pageId, pageName) {
    var normalizedName = _normalizeTagName(pageName);
    if (!normalizedName) {
      return;
    }

    var changed = false;
    for (var i = 0; i < rawTodos.length; i++) {
      var categoryName = _normalizeTagName((rawTodos[i].categories || "").split(",")[0]);
      if (categoryName && categoryName === normalizedName && rawTodos[i].pageId !== pageId) {
        rawTodos[i].pageId = pageId;
        changed = true;
      }
    }

    if (changed) {
      saveTodos();
    }
  }

  function _markTodoDirty(uid) {
    if (!uid) return;
    var dirty = Object.assign({}, _dirtyTodoUids);
    dirty[uid] = true;
    _dirtyTodoUids = dirty;
  }

  function _clearTodoDirty(uid) {
    if (!uid || !_dirtyTodoUids[uid]) return;
    var dirty = Object.assign({}, _dirtyTodoUids);
    delete dirty[uid];
    _dirtyTodoUids = dirty;
  }

  function _isTodoDirty(uid) {
    return !!(uid && _dirtyTodoUids[uid]);
  }

  // Expose CalDAV sync for external use (e.g. Settings sync button)
  function triggerCaldavSync(syncConfig) {
    if (caldavEnabled) {
      caldavSync.syncAll(syncConfig || null);
    }
  }

  // Expose CalDAV sync state
  readonly property bool caldavSyncing: caldavSync.isSyncing
  readonly property string caldavLastSync: caldavSync.lastSyncTime
  readonly property string caldavLastError: caldavSync.lastError
}
