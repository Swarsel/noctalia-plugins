import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Services.UI

Item {
  id: root
  property var pluginApi: null
  property string compositor: ""

  Component.onCompleted: {
    if (pluginApi && !parserStarted) {
      parserStarted = true;
      logInfo("Component.onCompleted, detecting compositor");
      detectCompositor();
    }
  }

  onPluginApiChanged: {
    if (pluginApi && !parserStarted) {
      parserStarted = true;
      logInfo("pluginApi loaded, detecting compositor");
      detectCompositor();
    }
  }

  // Logger helper functions
  function logDebug(msg) {
    if (typeof Logger !== 'undefined') Logger.d("KeybindCheatsheet", msg);
    else console.log("[KeybindCheatsheet] " + msg);
  }

  function logInfo(msg) {
    if (typeof Logger !== 'undefined') Logger.i("KeybindCheatsheet", msg);
    else console.log("[KeybindCheatsheet] " + msg);
  }

  function logWarn(msg) {
    if (typeof Logger !== 'undefined') Logger.w("KeybindCheatsheet", msg);
    else console.warn("[KeybindCheatsheet] " + msg);
  }

  function logError(msg) {
    if (typeof Logger !== 'undefined') Logger.e("KeybindCheatsheet", msg);
    else console.error("[KeybindCheatsheet] " + msg);
  }

  property bool parserStarted: false

  // Watch for toggle trigger from BarWidget
  property var triggerToggle: pluginApi?.pluginSettings?.triggerToggle || 0
  onTriggerToggleChanged: {
    if (triggerToggle > 0 && pluginApi) {
      logInfo("Toggle triggered from bar widget");
      if (!compositor) {
        detectCompositor();
      } else {
        runParser();
      }
      pluginApi.withCurrentScreen(screen => pluginApi.openPanel(screen));
    }
  }

  function detectCompositor() {
    // Check environment variables to detect compositor
    var hyprlandSig = Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE");
    var niriSocket = Quickshell.env("NIRI_SOCKET");

    if (hyprlandSig && hyprlandSig.length > 0) {
      compositor = "hyprland";
      logInfo("Detected Hyprland compositor");
    } else if (niriSocket && niriSocket.length > 0) {
      compositor = "niri";
      logInfo("Detected Niri compositor");
    } else {
      // Fallback: try to detect by checking running processes
      logWarn("No compositor detected via env vars, trying process detection");
      detectByProcess();
      return;
    }

    if (pluginApi) {
      pluginApi.pluginSettings.detectedCompositor = compositor;
      pluginApi.saveSettings();
    }
    runParser();
  }

  Process {
    id: detectProcess
    command: ["sh", "-c", "pgrep -x hyprland >/dev/null && echo hyprland || (pgrep -x niri >/dev/null && echo niri || echo unknown)"]
    running: false

    stdout: SplitParser {
      onRead: data => {
        var detected = data.trim();
        if (detected === "hyprland" || detected === "niri") {
          root.compositor = detected;
          logInfo("Detected compositor via process: " + detected);
        } else {
          root.compositor = "unknown";
          logError("Could not detect compositor");
        }

        if (pluginApi) {
          pluginApi.pluginSettings.detectedCompositor = root.compositor;
          pluginApi.saveSettings();
        }

        if (root.compositor !== "unknown") {
          runParser();
        } else {
          saveToDb([{
            "title": "Error",
            "binds": [{ "keys": "ERROR", "desc": "No supported compositor detected (Hyprland/Niri)" }]
          }]);
        }
      }
    }
  }

  function detectByProcess() {
    detectProcess.running = true;
  }

  // Recursive parsing support
  property var filesToParse: []
  property var parsedFiles: ({})
  property var accumulatedLines: []
  property var currentLines: []
  property var collectedBinds: ({})  // Collect keybinds from all files
  property var collectedEditorBinds: ({})  // Extended data for editor

  // Editor support - extended data with source tracking
  property var editorData: ({
    "categories": [],
    "deletedBinds": [],
    "deletedCategories": [],
    "hasUnsavedChanges": false
  })
  property int bindIdCounter: 0
  property int categoryIdCounter: 0

  function generateBindId() {
    return "bind_" + (++bindIdCounter);
  }

  function generateCategoryId() {
    return "cat_" + (++categoryIdCounter);
  }

  function runParser() {
    logInfo("=== START PARSER for " + compositor + " ===");

    var homeDir = Quickshell.env("HOME");
    if (!homeDir) {
      logError("Cannot get $HOME");
      saveToDb([{
        "title": "ERROR",
        "binds": [{ "keys": "ERROR", "desc": "Cannot get $HOME" }]
      }]);
      return;
    }

    // Reset recursive state
    filesToParse = [];
    parsedFiles = {};
    accumulatedLines = [];
    collectedBinds = {};
    collectedEditorBinds = {};
    bindIdCounter = 0;
    categoryIdCounter = 0;

    var filePath;
    if (compositor === "hyprland") {
      filePath = pluginApi?.pluginSettings?.hyprlandConfigPath || (homeDir + "/.config/hypr/hyprland.conf");
      filePath = filePath.replace(/^~/, homeDir);
    } else if (compositor === "niri") {
      filePath = pluginApi?.pluginSettings?.niriConfigPath || (homeDir + "/.config/niri/config.kdl");
      filePath = filePath.replace(/^~/, homeDir);
    } else {
      logError("Unknown compositor: " + compositor);
      return;
    }

    logInfo("Starting with main config: " + filePath);
    filesToParse = [filePath];

    if (compositor === "hyprland") {
      parseNextHyprlandFile();
    } else {
      parseNextNiriFile();
    }
  }

  function getDirectoryFromPath(filePath) {
    var lastSlash = filePath.lastIndexOf('/');
    return lastSlash >= 0 ? filePath.substring(0, lastSlash) : ".";
  }

  function resolveRelativePath(basePath, relativePath) {
    var homeDir = Quickshell.env("HOME") || "";
    var resolved = relativePath.replace(/^~/, homeDir);
    if (resolved.startsWith('/')) return resolved;
    return getDirectoryFromPath(basePath) + "/" + resolved;
  }

  function isGlobPattern(path) {
    return path.indexOf('*') !== -1 || path.indexOf('?') !== -1;
  }

  // ========== NIRI RECURSIVE PARSING ==========
  function parseNextNiriFile() {
    if (filesToParse.length === 0) {
      logInfo("All Niri files parsed, converting " + Object.keys(collectedBinds).length + " categories");
      finalizeNiriBinds();
      return;
    }

    var nextFile = filesToParse.shift();

    // Handle glob patterns
    if (isGlobPattern(nextFile)) {
      niriGlobProcess.command = ["sh", "-c", "for f in " + nextFile + "; do [ -f \"$f\" ] && echo \"$f\"; done"];
      niriGlobProcess.running = true;
      return;
    }

    if (parsedFiles[nextFile]) {
      parseNextNiriFile();
      return;
    }

    parsedFiles[nextFile] = true;
    logInfo("Parsing Niri file: " + nextFile);

    currentLines = [];
    niriReadProcess.currentFilePath = nextFile;
    niriReadProcess.command = ["cat", nextFile];
    niriReadProcess.running = true;
  }

  Process {
    id: niriGlobProcess
    property var expandedFiles: []
    running: false

    stdout: SplitParser {
      onRead: data => {
        var trimmed = data.trim();
        if (trimmed.length > 0) niriGlobProcess.expandedFiles.push(trimmed);
      }
    }

    onExited: {
      for (var i = 0; i < expandedFiles.length; i++) {
        var path = expandedFiles[i];
        if (!root.parsedFiles[path] && root.filesToParse.indexOf(path) === -1) {
          root.filesToParse.push(path);
        }
      }
      expandedFiles = [];
      root.parseNextNiriFile();
    }
  }

  Process {
    id: niriReadProcess
    property string currentFilePath: ""
    running: false

    stdout: SplitParser {
      onRead: data => { root.currentLines.push(data); }
    }

    onExited: (exitCode, exitStatus) => {
      logInfo("niriReadProcess exited, code: " + exitCode + ", lines: " + root.currentLines.length);
      if (exitCode === 0 && root.currentLines.length > 0) {
        // First pass: find includes
        for (var i = 0; i < root.currentLines.length; i++) {
          var line = root.currentLines[i];
          var includeMatch = line.match(/(?:include|source)\s+"([^"]+)"/i);
          if (includeMatch) {
            var includePath = includeMatch[1];
            var resolvedPath = root.resolveRelativePath(currentFilePath, includePath);
            logInfo("Found include: " + includePath + " -> " + resolvedPath);
            if (!root.parsedFiles[resolvedPath] && root.filesToParse.indexOf(resolvedPath) === -1) {
              root.filesToParse.push(resolvedPath);
            }
          }
        }
        // Second pass: parse keybinds from this file with source tracking
        root.parseNiriFileContent(root.currentLines, currentFilePath);
      }
      root.currentLines = [];
      root.parseNextNiriFile();
    }
  }

  function parseNiriFileContent(lines, sourceFile) {
    logInfo("parseNiriFileContent called, lines: " + lines.length + ", file: " + sourceFile);
    var inBindsBlock = false;
    var braceDepth = 0;
    var currentCategory = null;
    var bindsFoundInFile = 0;

    var actionCategories = {
      "spawn": "Applications",
      "focus-column": "Column Navigation",
      "focus-window": "Window Focus",
      "focus-workspace": "Workspace Navigation",
      "move-column": "Move Columns",
      "move-window": "Move Windows",
      "consume-window": "Window Management",
      "expel-window": "Window Management",
      "close-window": "Window Management",
      "fullscreen-window": "Window Management",
      "maximize-column": "Column Management",
      "set-column-width": "Column Width",
      "switch-preset-column-width": "Column Width",
      "reset-window-height": "Window Size",
      "screenshot": "Screenshots",
      "power-off-monitors": "Power",
      "quit": "System",
      "toggle-animation": "Animations"
    };

    for (var i = 0; i < lines.length; i++) {
      var rawLine = lines[i];
      var line = rawLine.trim();
      var lineNumber = i + 1;

      // Find binds block
      if (line.startsWith("binds") && line.includes("{")) {
        inBindsBlock = true;
        braceDepth = 1;
        logInfo("Entered binds block");
        continue;
      }

      if (!inBindsBlock) continue;

      // Track brace depth
      for (var j = 0; j < line.length; j++) {
        if (line[j] === '{') braceDepth++;
        else if (line[j] === '}') braceDepth--;
      }

      if (braceDepth <= 0) {
        logInfo("Exiting binds block, found " + bindsFoundInFile + " binds");
        inBindsBlock = false;
        continue;
      }

      // Category markers: // #"Category Name" - only these create categories
      if (line.startsWith("//")) {
        var categoryMatch = line.match(/\/\/\s*#"([^"]+)"/);
        if (categoryMatch) {
          currentCategory = categoryMatch[1];
        }
        continue;
      }

      if (line.length === 0) continue;

      // Parse keybind
      var bindMatch = line.match(/^([A-Za-z0-9_+]+)\s*(.*?)\{\s*([^}]+)\s*\}/);
      if (bindMatch) {
        bindsFoundInFile++;
        var keyCombo = bindMatch[1];
        var attributes = bindMatch[2].trim();
        var action = bindMatch[3].trim().replace(/;$/, '');

        var hotkeyTitle = null;
        var titleMatch = attributes.match(/hotkey-overlay-title="([^"]+)"/);
        if (titleMatch) hotkeyTitle = titleMatch[1];

        var formattedKeys = formatNiriKeyCombo(keyCombo);
        var category = currentCategory || getNiriCategory(action, actionCategories);
        var description = hotkeyTitle || formatNiriAction(action);

        // Standard bind for display
        if (!collectedBinds[category]) {
          collectedBinds[category] = [];
        }
        collectedBinds[category].push({
          "keys": formattedKeys,
          "desc": description
        });

        // Extended bind for editor
        if (!collectedEditorBinds[category]) {
          collectedEditorBinds[category] = [];
        }
        collectedEditorBinds[category].push({
          "id": generateBindId(),
          "keys": formattedKeys,
          "rawKeys": keyCombo,
          "modifiers": extractNiriModifiers(keyCombo),
          "key": extractNiriKey(keyCombo),
          "action": action,
          "description": description,
          "sourceFile": sourceFile,
          "lineNumber": lineNumber,
          "rawLine": rawLine,
          "status": "unchanged"
        });
      }
    }
    logInfo("File parsing done, bindsFoundInFile: " + bindsFoundInFile);
  }

  function extractNiriModifiers(keyCombo) {
    var mods = [];
    if (keyCombo.includes("Mod+") || keyCombo.includes("Super+")) mods.push("Super");
    if (keyCombo.includes("Ctrl+") || keyCombo.includes("Control+")) mods.push("Ctrl");
    if (keyCombo.includes("Shift+")) mods.push("Shift");
    if (keyCombo.includes("Alt+")) mods.push("Alt");
    return mods;
  }

  function extractNiriKey(keyCombo) {
    var parts = keyCombo.split('+');
    return parts[parts.length - 1];
  }

  function finalizeNiriBinds() {
    var categoryOrder = [
      "Applications", "Window Management", "Column Navigation",
      "Window Focus", "Workspace Navigation", "Move Columns",
      "Move Windows", "Column Management", "Column Width",
      "Window Size", "Screenshots", "Power", "System", "Animations"
    ];

    var categories = [];
    var editorCategories = [];

    for (var k = 0; k < categoryOrder.length; k++) {
      var catName = categoryOrder[k];
      if (collectedBinds[catName] && collectedBinds[catName].length > 0) {
        categories.push({ "title": catName, "binds": collectedBinds[catName] });
        editorCategories.push({
          "id": generateCategoryId(),
          "title": catName,
          "binds": collectedEditorBinds[catName] || []
        });
      }
    }

    // Add remaining categories
    for (var cat in collectedBinds) {
      if (categoryOrder.indexOf(cat) === -1 && collectedBinds[cat].length > 0) {
        categories.push({ "title": cat, "binds": collectedBinds[cat] });
        editorCategories.push({
          "id": generateCategoryId(),
          "title": cat,
          "binds": collectedEditorBinds[cat] || []
        });
      }
    }

    logInfo("Found " + categories.length + " categories total");

    // Save editor data
    editorData = {
      "categories": editorCategories,
      "deletedBinds": [],
      "deletedCategories": [],
      "hasUnsavedChanges": false
    };

    saveToDb(categories);
  }

  // ========== HYPRLAND RECURSIVE PARSING ==========
  function parseNextHyprlandFile() {
    if (filesToParse.length === 0) {
      logInfo("All Hyprland files parsed, total lines: " + accumulatedLines.length);
      if (accumulatedLines.length > 0) {
        parseHyprlandConfig(accumulatedLines);
      } else {
        logWarn("No content found in config files");
      }
      return;
    }

    var nextFile = filesToParse.shift();

    // Handle glob patterns
    if (isGlobPattern(nextFile)) {
      hyprGlobProcess.command = ["sh", "-c", "for f in " + nextFile + "; do [ -f \"$f\" ] && echo \"$f\"; done"];
      hyprGlobProcess.running = true;
      return;
    }

    if (parsedFiles[nextFile]) {
      parseNextHyprlandFile();
      return;
    }

    parsedFiles[nextFile] = true;
    logInfo("Parsing Hyprland file: " + nextFile);

    currentLines = [];
    hyprReadProcess.currentFilePath = nextFile;
    hyprReadProcess.command = ["cat", nextFile];
    hyprReadProcess.running = true;
  }

  Process {
    id: hyprGlobProcess
    property var expandedFiles: []
    running: false

    stdout: SplitParser {
      onRead: data => {
        var trimmed = data.trim();
        if (trimmed.length > 0) hyprGlobProcess.expandedFiles.push(trimmed);
      }
    }

    onExited: {
      for (var i = 0; i < expandedFiles.length; i++) {
        var path = expandedFiles[i];
        if (!root.parsedFiles[path] && root.filesToParse.indexOf(path) === -1) {
          root.filesToParse.push(path);
        }
      }
      expandedFiles = [];
      root.parseNextHyprlandFile();
    }
  }

  Process {
    id: hyprReadProcess
    property string currentFilePath: ""
    running: false

    stdout: SplitParser {
      onRead: data => { root.currentLines.push(data); }
    }

    onExited: (exitCode, exitStatus) => {
      if (exitCode === 0 && root.currentLines.length > 0) {
        for (var i = 0; i < root.currentLines.length; i++) {
          var line = root.currentLines[i];
          // Store line with source info for editor
          root.accumulatedLines.push({
            "text": line,
            "sourceFile": currentFilePath,
            "lineNumber": i + 1
          });

          // Check for source directive
          var sourceMatch = line.trim().match(/^source\s*=\s*(.+)$/);
          if (sourceMatch) {
            var sourcePath = sourceMatch[1].trim();
            var commentIdx = sourcePath.indexOf('#');
            if (commentIdx > 0) sourcePath = sourcePath.substring(0, commentIdx).trim();
            var resolvedPath = root.resolveRelativePath(currentFilePath, sourcePath);
            logInfo("Found source: " + sourcePath + " -> " + resolvedPath);
            if (!root.parsedFiles[resolvedPath] && root.filesToParse.indexOf(resolvedPath) === -1) {
              root.filesToParse.push(resolvedPath);
            }
          }
        }
      }
      root.currentLines = [];
      root.parseNextHyprlandFile();
    }
  }

  // ========== HYPRLAND PARSER ==========
  function parseHyprlandConfig(linesWithSource) {
    logDebug("Parsing Hyprland config with source tracking");
    var categories = [];
    var editorCategories = [];
    var currentCategory = null;
    var currentEditorCategory = null;

    // Take Variable and change to UpperCase
    var modVar = pluginApi?.pluginSettings?.modKeyVariable || "$mod";
    var modVarUpper = modVar.toUpperCase();

    for (var i = 0; i < linesWithSource.length; i++) {
      var lineObj = linesWithSource[i];
      var line = lineObj.text.trim();
      var sourceFile = lineObj.sourceFile;
      var lineNumber = lineObj.lineNumber;

      // Category header: # 1. Category Name
      if (line.startsWith("#") && line.match(/#\s*\d+\./)) {
        if (currentCategory) {
          categories.push(currentCategory);
        }
        if (currentEditorCategory) {
          editorCategories.push(currentEditorCategory);
        }
        var title = line.replace(/#\s*\d+\.\s*/, "").trim();
        logDebug("New category: " + title + " from " + sourceFile);
        currentCategory = { "title": title, "binds": [] };
        currentEditorCategory = {
          "id": generateCategoryId(),
          "title": title,
          "sourceFile": sourceFile,  // Track where category header is
          "binds": []
        };
      }
      // Keybind: bind = $mod, T, exec, cmd #"description"
      else if (line.includes("bind") && line.includes('#"')) {
        if (currentCategory) {
          var descMatch = line.match(/#"(.*?)"$/);
          var description = descMatch ? descMatch[1] : "No description";

          var parts = line.split(',');
          if (parts.length >= 2) {
            var modPart = parts[0].split('=')[1].trim().toUpperCase();
            var rawKey = parts[1].trim().toUpperCase();
            var key = formatSpecialKey(rawKey);

            // Extract action (everything between key and description)
            var actionParts = parts.slice(2);
            var actionStr = actionParts.join(',').replace(/#".*"$/, '').trim();

            // Build modifiers list properly
            var mods = [];
            // We are checking what Variable is set
            if (modPart.includes(modVarUpper) || modPart.includes("SUPER")) mods.push("Super");

            if (modPart.includes("SHIFT")) mods.push("Shift");
            if (modPart.includes("CTRL") || modPart.includes("CONTROL")) mods.push("Ctrl");
            if (modPart.includes("ALT")) mods.push("Alt");

            // Build full key string
            var fullKey;
            if (mods.length > 0) {
              fullKey = mods.join(" + ") + " + " + key;
            } else {
              fullKey = key;
            }

            // Standard bind for display
            currentCategory.binds.push({
              "keys": fullKey,
              "desc": description
            });

            // Extended bind for editor
            currentEditorCategory.binds.push({
              "id": generateBindId(),
              "keys": fullKey,
              "rawKeys": parts[0].split('=')[1].trim() + ", " + parts[1].trim(),
              "modifiers": mods,
              "key": rawKey,
              "action": actionStr,
              "description": description,
              "sourceFile": sourceFile,
              "lineNumber": lineNumber,
              "rawLine": lineObj.text,
              "status": "unchanged"
            });

            logDebug("Added bind: " + fullKey);
          }
        }
      }
    }

    if (currentCategory) {
      categories.push(currentCategory);
    }
    if (currentEditorCategory) {
      editorCategories.push(currentEditorCategory);
    }

    logDebug("Found " + categories.length + " categories");

    // Save both display data and editor data
    editorData = {
      "categories": editorCategories,
      "deletedBinds": [],
      "deletedCategories": [],
      "hasUnsavedChanges": false
    };

    saveToDb(categories);
  }

  // ========== NIRI PARSER ==========
  function parseNiriConfig(text) {
    logDebug("Parsing Niri KDL config");
    var lines = text.split('\n');
    var inBindsBlock = false;
    var braceDepth = 0;
    var currentCategory = null;

    var actionCategories = {
      "spawn": "Applications",
      "focus-column": "Column Navigation",
      "focus-window": "Window Focus",
      "focus-workspace": "Workspace Navigation",
      "move-column": "Move Columns",
      "move-window": "Move Windows",
      "consume-window": "Window Management",
      "expel-window": "Window Management",
      "close-window": "Window Management",
      "fullscreen-window": "Window Management",
      "maximize-column": "Column Management",
      "set-column-width": "Column Width",
      "switch-preset-column-width": "Column Width",
      "reset-window-height": "Window Size",
      "screenshot": "Screenshots",
      "power-off-monitors": "Power",
      "quit": "System",
      "toggle-animation": "Animations"
    };

    var categorizedBinds = {};

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim();

      // Find binds block
      if (line.startsWith("binds") && line.includes("{")) {
        inBindsBlock = true;
        braceDepth = 1;
        continue;
      }

      if (!inBindsBlock) continue;

      // Track brace depth
      for (var j = 0; j < line.length; j++) {
        if (line[j] === '{') braceDepth++;
        else if (line[j] === '}') braceDepth--;
      }

      if (braceDepth <= 0) {
        inBindsBlock = false;
        break;
      }

      // Category markers: // #"Category Name" - only these create categories
      if (line.startsWith("//")) {
        var categoryMatch = line.match(/\/\/\s*#"([^"]+)"/);
        if (categoryMatch) {
          currentCategory = categoryMatch[1];
        }
        continue;
      }

      if (line.length === 0) continue;

      // Parse: Mod+Key { action; }
      var bindMatch = line.match(/^([A-Za-z0-9_+]+)\s*(?:[a-z\-]+=\S+\s*)*\{\s*([^}]+)\s*\}/);

      if (bindMatch) {
        var keyCombo = bindMatch[1];
        var action = bindMatch[2].trim().replace(/;$/, '');

        var formattedKeys = formatNiriKeyCombo(keyCombo);
        var category = currentCategory || getNiriCategory(action, actionCategories);

        if (!categorizedBinds[category]) {
          categorizedBinds[category] = [];
        }

        categorizedBinds[category].push({
          "keys": formattedKeys,
          "desc": formatNiriAction(action)
        });

        logDebug("Added bind: " + formattedKeys + " -> " + action);
      }
    }

    // Convert to array
    var categoryOrder = [
      "Applications", "Window Management", "Column Navigation",
      "Window Focus", "Workspace Navigation", "Move Columns",
      "Move Windows", "Column Management", "Column Width",
      "Window Size", "Screenshots", "Power", "System", "Animations"
    ];

    var categories = [];
    for (var k = 0; k < categoryOrder.length; k++) {
      var catName = categoryOrder[k];
      if (categorizedBinds[catName] && categorizedBinds[catName].length > 0) {
        categories.push({
          "title": catName,
          "binds": categorizedBinds[catName]
        });
      }
    }

    // Add remaining categories
    for (var cat in categorizedBinds) {
      if (categoryOrder.indexOf(cat) === -1 && categorizedBinds[cat].length > 0) {
        categories.push({
          "title": cat,
          "binds": categorizedBinds[cat]
        });
      }
    }

    logDebug("Found " + categories.length + " categories");
    saveToDb(categories);
  }

  function formatSpecialKey(key) {
    var keyMap = {
      // Audio keys (uppercase for Hyprland)
      "XF86AUDIORAISEVOLUME": "Vol Up",
      "XF86AUDIOLOWERVOLUME": "Vol Down",
      "XF86AUDIOMUTE": "Mute",
      "XF86AUDIOMICMUTE": "Mic Mute",
      "XF86AUDIOPLAY": "Play",
      "XF86AUDIOPAUSE": "Pause",
      "XF86AUDIONEXT": "Next",
      "XF86AUDIOPREV": "Prev",
      "XF86AUDIOSTOP": "Stop",
      "XF86AUDIOMEDIA": "Media",
      // Audio keys (mixed case for Niri)
      "XF86AudioRaiseVolume": "Vol Up",
      "XF86AudioLowerVolume": "Vol Down",
      "XF86AudioMute": "Mute",
      "XF86AudioMicMute": "Mic Mute",
      "XF86AudioPlay": "Play",
      "XF86AudioPause": "Pause",
      "XF86AudioNext": "Next",
      "XF86AudioPrev": "Prev",
      "XF86AudioStop": "Stop",
      "XF86AudioMedia": "Media",
      // Brightness keys
      "XF86MONBRIGHTNESSUP": "Bright Up",
      "XF86MONBRIGHTNESSDOWN": "Bright Down",
      "XF86MonBrightnessUp": "Bright Up",
      "XF86MonBrightnessDown": "Bright Down",
      // Other common keys
      "XF86CALCULATOR": "Calc",
      "XF86MAIL": "Mail",
      "XF86SEARCH": "Search",
      "XF86EXPLORER": "Files",
      "XF86WWW": "Browser",
      "XF86HOMEPAGE": "Home",
      "XF86FAVORITES": "Favorites",
      "XF86POWEROFF": "Power",
      "XF86SLEEP": "Sleep",
      "XF86EJECT": "Eject",
      // Print screen
      "PRINT": "PrtSc",
      "Print": "PrtSc",
      // Navigation
      "PRIOR": "PgUp",
      "NEXT": "PgDn",
      "Prior": "PgUp",
      "Next": "PgDn",
      // Mouse (for Hyprland)
      "MOUSE_DOWN": "Scroll Down",
      "MOUSE_UP": "Scroll Up",
      "MOUSE:272": "Left Click",
      "MOUSE:273": "Right Click",
      "MOUSE:274": "Middle Click"
    };
    return keyMap[key] || key;
  }

  function formatNiriKeyCombo(combo) {
    // First handle modifiers
    var formatted = combo
      .replace(/Mod\+/g, "Super + ")
      .replace(/Super\+/g, "Super + ")
      .replace(/Ctrl\+/g, "Ctrl + ")
      .replace(/Control\+/g, "Ctrl + ")
      .replace(/Alt\+/g, "Alt + ")
      .replace(/Shift\+/g, "Shift + ")
      .replace(/Win\+/g, "Super + ")
      .replace(/\+\s*$/, "")
      .replace(/\s+/g, " ")
      .trim();

    // Then format special keys (XF86, Print, etc.)
    var parts = formatted.split(" + ");
    var formattedParts = parts.map(function(part) {
      var trimmed = part.trim();
      if (["Super", "Ctrl", "Alt", "Shift"].indexOf(trimmed) === -1) {
        return formatSpecialKey(trimmed);
      }
      return trimmed;
    });
    return formattedParts.join(" + ");
  }

  function formatNiriAction(action) {
    if (action.startsWith("spawn")) {
      var spawnMatch = action.match(/spawn\s+"([^"]+)"/);
      if (spawnMatch) {
        return "Run: " + spawnMatch[1];
      }
      return action;
    }
    return action.replace(/-/g, ' ').replace(/\b\w/g, function(l) { return l.toUpperCase(); });
  }

  function getNiriCategory(action, actionCategories) {
    for (var prefix in actionCategories) {
      if (action.startsWith(prefix)) {
        return actionCategories[prefix];
      }
    }
    return "Other";
  }

  function saveToDb(data) {
    if (pluginApi) {
      pluginApi.pluginSettings.cheatsheetData = data;
      pluginApi.pluginSettings.editorData = editorData;
      pluginApi.saveSettings();
      logInfo("Saved " + data.length + " categories to settings (with editor data)");
    } else {
      logError("pluginApi is null!");
    }
  }

  // ========== EDITOR API ==========
  // Functions for EditorPanel to modify keybinds

  function getEditorData() {
    return editorData;
  }

  function updateKeybind(bindId, changes) {
    var newCategories = editorData.categories.map(function(cat) {
      var newBinds = cat.binds.map(function(bind) {
        if (bind.id === bindId) {
          // Create new bind object with changes and modified status
          var updatedBind = Object.assign({}, bind, changes);
          if (bind.status !== "new") {
            updatedBind.status = "modified";
          }
          return updatedBind;
        }
        return bind;
      });
      return Object.assign({}, cat, { binds: newBinds });
    });

    var found = editorData.categories.some(function(cat) {
      return cat.binds.some(function(bind) { return bind.id === bindId; });
    });

    if (found) {
      editorData = {
        categories: newCategories,
        deletedBinds: editorData.deletedBinds,
        deletedCategories: editorData.deletedCategories || [],
        hasUnsavedChanges: true
      };
    }
    return found;
  }

  function addKeybind(categoryId, bindData) {
    var newBind = {
      "id": generateBindId(),
      "keys": bindData.keys || "",
      "rawKeys": bindData.rawKeys || "",
      "modifiers": bindData.modifiers || [],
      "key": bindData.key || "",
      "action": bindData.action || "",
      "description": bindData.description || "",
      "sourceFile": bindData.sourceFile || "",
      "lineNumber": -1,
      "rawLine": "",
      "status": "new"
    };

    var newCategories = editorData.categories.map(function(cat) {
      if (cat.id === categoryId) {
        return Object.assign({}, cat, { binds: cat.binds.concat([newBind]) });
      }
      return cat;
    });

    var found = editorData.categories.some(function(cat) { return cat.id === categoryId; });

    if (found) {
      editorData = {
        categories: newCategories,
        deletedBinds: editorData.deletedBinds,
        deletedCategories: editorData.deletedCategories || [],
        hasUnsavedChanges: true
      };
      return newBind.id;
    }
    return null;
  }

  function deleteKeybind(bindId) {
    var newDeletedBinds = editorData.deletedBinds.slice();
    var found = false;

    var newCategories = editorData.categories.map(function(cat) {
      var newBinds = [];
      for (var j = 0; j < cat.binds.length; j++) {
        var bind = cat.binds[j];
        if (bind.id === bindId) {
          found = true;
          if (bind.status !== "new") {
            // Mark existing binds as deleted
            newDeletedBinds.push(Object.assign({}, bind, { status: "deleted" }));
          }
          // Don't add to newBinds (effectively deleting it)
        } else {
          newBinds.push(bind);
        }
      }
      return Object.assign({}, cat, { binds: newBinds });
    });

    if (found) {
      editorData = {
        categories: newCategories,
        deletedBinds: newDeletedBinds,
        deletedCategories: editorData.deletedCategories || [],
        hasUnsavedChanges: true
      };
    }
    return found;
  }

  function moveKeybind(bindId, targetCategoryId) {
    logInfo("moveKeybind: bindId=" + bindId + " targetCategoryId=" + targetCategoryId);
    var originalBind = null;
    var sourceCategoryId = null;

    // Find the bind and its source category
    for (var i = 0; i < editorData.categories.length; i++) {
      var cat = editorData.categories[i];
      for (var j = 0; j < cat.binds.length; j++) {
        if (cat.binds[j].id === bindId) {
          originalBind = cat.binds[j];
          sourceCategoryId = cat.id;
          logInfo("moveKeybind: found bind in category " + cat.title + " (id=" + cat.id + ")");
          break;
        }
      }
      if (originalBind) break;
    }

    if (!originalBind) {
      logWarn("moveKeybind: bind not found: " + bindId);
      return false;
    }

    if (sourceCategoryId === targetCategoryId) {
      logDebug("moveKeybind: bind already in target category");
      return false;
    }

    var newDeletedBinds = editorData.deletedBinds.slice();

    // If bind existed in file, add to deletedBinds (will be deleted from old location)
    if (originalBind.status !== "new" && originalBind.sourceFile && originalBind.rawLine) {
      newDeletedBinds.push(Object.assign({}, originalBind, { status: "deleted" }));
      logInfo("moveKeybind: added original to deletedBinds for deletion");
    }

    // Create new bind for target category (will be added as new line)
    var movedBind = Object.assign({}, originalBind, {
      id: generateBindId(),  // New ID
      status: "new",         // Will be written as new line
      sourceFile: "",        // Clear source info
      rawLine: "",
      lineNumber: -1
    });
    logInfo("moveKeybind: created new bind with id=" + movedBind.id);

    var newCategories = [];
    for (var k = 0; k < editorData.categories.length; k++) {
      var category = editorData.categories[k];
      if (category.id === sourceCategoryId) {
        // Remove from source
        var filteredBinds = [];
        for (var m = 0; m < category.binds.length; m++) {
          if (category.binds[m].id !== bindId) {
            filteredBinds.push(category.binds[m]);
          }
        }
        logInfo("moveKeybind: source category " + category.title + " binds: " + category.binds.length + " -> " + filteredBinds.length);
        newCategories.push(Object.assign({}, category, { binds: filteredBinds }));
      } else if (category.id === targetCategoryId) {
        // Add to target
        var newBinds = category.binds.concat([movedBind]);
        logInfo("moveKeybind: target category " + category.title + " binds: " + category.binds.length + " -> " + newBinds.length);
        newCategories.push(Object.assign({}, category, { binds: newBinds }));
      } else {
        newCategories.push(category);
      }
    }

    editorData = {
      categories: newCategories,
      deletedBinds: newDeletedBinds,
      deletedCategories: editorData.deletedCategories || [],
      hasUnsavedChanges: true
    };

    logInfo("moveKeybind: completed, new editorData has " + newCategories.length + " categories");
    return true;
  }

  function reorderKeybind(bindId, direction) {
    // direction: -1 = move up, 1 = move down
    logInfo("reorderKeybind: bindId=" + bindId + " direction=" + direction);

    var newCategories = [];
    var newDeletedBinds = editorData.deletedBinds.slice();
    var reordered = false;

    for (var i = 0; i < editorData.categories.length; i++) {
      var cat = editorData.categories[i];
      var bindIndex = -1;

      // Find the bind in this category
      for (var j = 0; j < cat.binds.length; j++) {
        if (cat.binds[j].id === bindId) {
          bindIndex = j;
          break;
        }
      }

      if (bindIndex === -1) {
        // Bind not in this category, keep as-is
        newCategories.push(cat);
        continue;
      }

      // Calculate new index
      var newIndex = bindIndex + direction;

      // Validate bounds
      if (newIndex < 0 || newIndex >= cat.binds.length) {
        logDebug("reorderKeybind: cannot move, already at boundary");
        newCategories.push(cat);
        continue;
      }

      // Create completely new bind objects to force QML re-render
      var newBinds = [];
      for (var k = 0; k < cat.binds.length; k++) {
        newBinds.push(Object.assign({}, cat.binds[k]));
      }

      // Add original binds to deletedBinds (to delete old lines)
      var bind1 = cat.binds[bindIndex];
      var bind2 = cat.binds[newIndex];
      if (bind1.sourceFile && bind1.rawLine) {
        newDeletedBinds.push(Object.assign({}, bind1, { status: "deleted" }));
      }
      if (bind2.sourceFile && bind2.rawLine) {
        newDeletedBinds.push(Object.assign({}, bind2, { status: "deleted" }));
      }

      // Mark swapped binds as "new" so they get written in new order
      newBinds[bindIndex] = Object.assign({}, bind2, {
        id: generateBindId(),
        status: "new",
        sourceFile: "",
        rawLine: "",
        lineNumber: -1
      });
      newBinds[newIndex] = Object.assign({}, bind1, {
        id: generateBindId(),
        status: "new",
        sourceFile: "",
        rawLine: "",
        lineNumber: -1
      });

      logInfo("reorderKeybind: swapped positions " + bindIndex + " <-> " + newIndex + " in category " + cat.title);

      newCategories.push(Object.assign({}, cat, { binds: newBinds }));
      reordered = true;
    }

    if (reordered) {
      editorData = {
        categories: newCategories,
        deletedBinds: newDeletedBinds,
        deletedCategories: editorData.deletedCategories || [],
        hasUnsavedChanges: true
      };
      logInfo("reorderKeybind: completed");
    }

    return reordered;
  }

  function addCategory(title) {
    var newCat = {
      "id": generateCategoryId(),
      "title": title,
      "binds": []
    };

    editorData = {
      categories: editorData.categories.concat([newCat]),
      deletedBinds: editorData.deletedBinds,
      deletedCategories: editorData.deletedCategories || [],
      hasUnsavedChanges: true
    };
    return newCat.id;
  }

  function renameCategory(categoryId, newTitle) {
    var newCategories = [];
    var found = false;
    for (var i = 0; i < editorData.categories.length; i++) {
      var cat = editorData.categories[i];
      if (cat.id === categoryId) {
        // Create new category object with updated title, preserving originalTitle
        var originalTitle = cat.originalTitle || cat.title;  // Keep first original
        newCategories.push(Object.assign({}, cat, {
          title: newTitle,
          originalTitle: originalTitle,
          titleChanged: true
        }));
        found = true;
        logInfo("Category renamed from '" + originalTitle + "' to '" + newTitle + "'");
      } else {
        newCategories.push(cat);
      }
    }
    if (found) {
      editorData = {
        categories: newCategories,
        deletedBinds: editorData.deletedBinds,
        deletedCategories: editorData.deletedCategories || [],
        hasUnsavedChanges: true
      };
    }
    return found;
  }

  function deleteCategory(categoryId) {
    logInfo("deleteCategory called: " + categoryId);
    var newCategories = [];
    var newDeletedBinds = editorData.deletedBinds.slice(); // Copy existing deletedBinds
    var newDeletedCategories = editorData.deletedCategories ? editorData.deletedCategories.slice() : [];
    var found = false;

    for (var i = 0; i < editorData.categories.length; i++) {
      var cat = editorData.categories[i];
      if (cat.id === categoryId) {
        found = true;
        logInfo("Found category to delete: " + cat.title + " with " + cat.binds.length + " binds");

        // Add existing binds to deletedBinds
        for (var j = 0; j < cat.binds.length; j++) {
          var bind = cat.binds[j];
          logDebug("  Bind " + j + ": status=" + bind.status + " sourceFile=" + bind.sourceFile + " rawLine=" + (bind.rawLine ? "yes" : "no"));

          if (bind.status !== "new" && bind.sourceFile && bind.rawLine) {
            // Create new bind object with deleted status
            var deletedBind = Object.assign({}, bind, { status: "deleted" });
            newDeletedBinds.push(deletedBind);
            logInfo("  Added bind to deletedBinds: " + bind.keys);
          } else {
            logDebug("  Skipping bind (new or no sourceFile): " + bind.keys);
          }
        }

        // If category exists in file, delete the header too
        // Use cat.sourceFile (set during parsing) instead of checking binds
        if (cat.sourceFile) {
          newDeletedCategories.push({
            title: cat.title,
            originalTitle: cat.originalTitle || cat.title,
            sourceFile: cat.sourceFile
          });
          logInfo("Added category header to delete: " + cat.title + " from " + cat.sourceFile);
        } else {
          logDebug("Category is new (no sourceFile), skipping header deletion");
        }
        // Don't add this category to newCategories (effectively deleting it)
      } else {
        newCategories.push(cat);
      }
    }

    if (found) {
      editorData = {
        categories: newCategories,
        deletedBinds: newDeletedBinds,
        deletedCategories: newDeletedCategories,
        hasUnsavedChanges: true
      };
    }
    return found;
  }

  function discardChanges() {
    // Re-run parser to reset data
    runParser();
  }

  // Note: editorDataChanged signal is auto-generated by QML for the editorData property
  // We need to reassign editorData to trigger the signal, e.g.: editorData = {...editorData}

  IpcHandler {
    target: "plugin:keybind-cheatsheet"
    function toggle() {
      logDebug("IPC toggle called");
      if (pluginApi) {
        if (!compositor) {
          detectCompositor();
        } else {
          runParser();
        }
        pluginApi.withCurrentScreen(screen => pluginApi.openPanel(screen));
      }
    }

    function refresh() {
      logDebug("IPC refresh called");
      if (pluginApi) {
        parserStarted = false;
        compositor = "";
        detectCompositor();
      }
    }
  }
}
