import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root
  property var pluginApi: null

  property bool steamRunning: false
  property bool overlayActive: false
  property var steamWindows: []

  // Auto-detect screen resolution
  property int screenWidth: 3440  // Default, will be updated
  property int screenHeight: 1440  // Default, will be updated

  // Shortcut to settings and defaults
  readonly property var cfg: pluginApi?.pluginSettings || ({})
  readonly property var defaults: pluginApi?.manifest?.metadata?.defaultSettings || ({})

  // User-configurable settings with fallback chain
  readonly property int gapSize: cfg.gapSize ?? defaults.gapSize ?? 10
  readonly property real topMarginPercent: cfg.topMarginPercent ?? defaults.topMarginPercent ?? 2.5
  readonly property real windowHeightPercent: cfg.windowHeightPercent ?? defaults.windowHeightPercent ?? 95
  readonly property real friendsWidthPercent: cfg.friendsWidthPercent ?? defaults.friendsWidthPercent ?? 10
  readonly property real mainWidthPercent: cfg.mainWidthPercent ?? defaults.mainWidthPercent ?? 60
  readonly property real chatWidthPercent: cfg.chatWidthPercent ?? defaults.chatWidthPercent ?? 25

  // Calculate pixel values from percentages (updates automatically when screen size changes)
  readonly property int topMargin: Math.round(screenHeight * (topMarginPercent / 100))
  readonly property int windowHeight: Math.round(screenHeight * (windowHeightPercent / 100))
  readonly property int friendsWidth: Math.round((screenWidth * (friendsWidthPercent / 100)) - gapSize)
  readonly property int mainWidth: Math.round((screenWidth * (mainWidthPercent / 100)) - (gapSize * 2))
  readonly property int chatWidth: Math.round((screenWidth * (chatWidthPercent / 100)) - gapSize)

  // Calculate center offset for horizontal centering
  readonly property int totalWidth: friendsWidth + gapSize + mainWidth + gapSize + chatWidth
  readonly property int centerOffset: Math.round((screenWidth - totalWidth) / 2)

  // Logger helper functions (fallback to console if Logger not available)
  function logDebug(msg) {
    if (typeof Logger !== 'undefined') Logger.d(msg);
    else console.log(msg);
  }

  function logInfo(msg) {
    if (typeof Logger !== 'undefined') Logger.i(msg);
    else console.log(msg);
  }

  function logWarn(msg) {
    if (typeof Logger !== 'undefined') Logger.w(msg);
    else console.warn(msg);
  }

  function logError(msg) {
    if (typeof Logger !== 'undefined') Logger.e(msg);
    else console.error(msg);
  }

  onPluginApiChanged: {
    if (pluginApi) {
      logInfo("SteamOverlay: " + (pluginApi?.tr("main.plugin_loaded") || "Plugin loaded"));
      checkSteam.running = true;
    }
  }

  Component.onCompleted: {
    if (pluginApi) {
      checkSteam.running = true;
    }
    detectResolution.running = true;
    monitorTimer.start();
  }

  // Check if Steam is running
  Process {
    id: checkSteam
    command: ["pidof", "steam"]
    running: false

    onExited: (exitCode, exitStatus) => {
      steamRunning = (exitCode === 0);
    }
  }

  // Launch Steam
  Process {
    id: launchSteam
    command: ["steam", "steam://open/main"]
    running: false

    onExited: (exitCode, exitStatus) => {
      logInfo("SteamOverlay: " + (pluginApi?.tr("main.steam_launched") || "Steam launched"));
    }
  }

  // Detect screen resolution
  Process {
    id: detectResolution
    command: ["bash", "-c", "hyprctl monitors -j | jq -r '.[0] | \"\\(.width) \\(.height)\"'"]
    running: false

    stdout: SplitParser {
      onRead: data => {
        var parts = data.trim().split(" ");
        if (parts.length === 2) {
          screenWidth = parseInt(parts[0]);
          screenHeight = parseInt(parts[1]);
          var msg = pluginApi?.tr("main.resolution_detected")
            .replace("{width}", screenWidth)
            .replace("{height}", screenHeight);
          logDebug("SteamOverlay: " + msg);
        }
      }
    }
  }

  // Detect Steam windows (only Friends List, Main, and small Chat windows)
  Process {
    id: detectWindows
    command: ["bash", "-c", "hyprctl clients -j | jq -c '.[] | select(.class == \"steam\" and .fullscreen == 0) | {address: .address, title: .title, x: .at[0], y: .at[1], w: .size[0], h: .size[1]}'"]
    running: false

    property var lines: []

    stdout: SplitParser {
      onRead: data => {
        detectWindows.lines.push(data.trim());
      }
    }

    onExited: (exitCode, exitStatus) => {
      if (exitCode === 0 && lines.length > 0) {
        var allWindows = lines.map(line => JSON.parse(line));

        // Filter only main Steam UI windows (Friends List, Main Window, Chat)
        steamWindows = allWindows.filter(win => {
          var title = win.title || "";
          var width = win.w || 0;
          var height = win.h || 0;

          // Accept Friends List
          if (title.includes("Friends List")) return true;

          // Accept main Steam window
          if (title === "Steam") return true;

          // Accept chat windows (< 30% screen width and < 100% screen height)
          var maxChatWidth = screenWidth * 0.30;
          var maxChatHeight = screenHeight * 1.0;
          if (width < maxChatWidth && height < maxChatHeight) return true;

          // Reject everything else (games, large auxiliary windows, etc.)
          return false;
        });

        var msg = pluginApi?.tr("main.windows_found").replace("{count}", steamWindows.length);
        logDebug("SteamOverlay: " + msg);
        lines = [];
      }
    }
  }

  // Move and position windows
  Process {
    id: moveWindows
    command: ["bash", "-c", ""]
    running: false

    onExited: (exitCode, exitStatus) => {
      var msg = pluginApi?.tr("main.windows_moved").replace("{code}", exitCode);
      logDebug("SteamOverlay: " + msg);
      if (exitCode === 0) {
        // Show the special workspace, then focus additional windows
        showWorkspace.running = true;
      }
    }
  }

  // Show special workspace
  Process {
    id: showWorkspace
    command: ["hyprctl", "dispatch", "togglespecialworkspace", "steam"]
    running: false

    onExited: (exitCode, exitStatus) => {
      logDebug("SteamOverlay: " + (pluginApi?.tr("main.workspace_toggled") || "Workspace toggled"));
      if (exitCode === 0 && overlayActive) {
        // After showing workspace, focus additional windows to bring them to front
        Qt.callLater(() => {
          focusAdditionalWindows.running = true;
        });
      }
    }
  }

  // Focus additional (non-main) windows to bring them to front
  Process {
    id: focusAdditionalWindows
    command: ["bash", "-c", "hyprctl clients -j | jq -r '.[] | select(.class == \"steam\" and .workspace.name == \"special:steam\" and .fullscreen == 0) | .address'"]
    running: false

    property var addresses: []

    stdout: SplitParser {
      onRead: data => {
        var addr = data.trim();
        if (addr && addr.startsWith("0x")) {
          focusAdditionalWindows.addresses.push(addr);
        }
      }
    }

    onExited: (exitCode, exitStatus) => {
      if (exitCode === 0 && addresses.length > 0) {
        var focusCommands = [];

        // Focus only non-main windows
        for (var i = 0; i < addresses.length; i++) {
          var addr = addresses[i];
          var isMain = false;

          // Check if this is one of the 3 main windows
          for (var j = 0; j < steamWindows.length; j++) {
            if (steamWindows[j].address === addr) {
              isMain = true;
              break;
            }
          }

          // Bring additional windows to top (without focusing/moving cursor)
          if (!isMain) {
            focusCommands.push("hyprctl dispatch alterzorder top,address:" + addr);
          }
        }

        if (focusCommands.length > 0) {
          executeFocus.command = ["bash", "-c", focusCommands.join(" && ")];
          executeFocus.running = true;
          logDebug("SteamOverlay: Bringing " + focusCommands.length + " additional window(s) to top");
        }
      }
      addresses = [];
    }
  }

  // Execute focus commands
  Process {
    id: executeFocus
    command: ["bash", "-c", ""]
    running: false

    onExited: (exitCode, exitStatus) => {
      if (exitCode === 0) {
        logDebug("SteamOverlay: Additional windows focused");
      }
    }
  }

  // Timer to monitor Steam
  Timer {
    id: monitorTimer
    interval: 3000
    repeat: true
    running: false

    onTriggered: {
      checkSteam.running = true;
    }
  }

  // Detect ALL Steam windows (including additional ones)
  Process {
    id: detectAllWindows
    command: ["bash", "-c", "hyprctl clients -j | jq -c '.[] | select(.class == \"steam\" and .fullscreen == 0) | {address: .address, title: .title}'"]
    running: false

    property var allSteamWindows: []

    stdout: SplitParser {
      onRead: data => {
        var line = data.trim();
        if (line) {
          try {
            detectAllWindows.allSteamWindows.push(JSON.parse(line));
          } catch (e) {}
        }
      }
    }

    onExited: (exitCode, exitStatus) => {
      if (exitCode === 0 && allSteamWindows.length > 0) {
        var commands = [];

        for (var i = 0; i < allSteamWindows.length; i++) {
          var win = allSteamWindows[i];
          var addr = win.address;
          var title = win.title || "";

          // Skip notification toasts
          if (title.includes("notificationtoasts")) {
            continue;
          }

          // Move all Steam windows to overlay and set as floating
          commands.push("hyprctl dispatch movetoworkspacesilent special:steam,address:" + addr);
          commands.push("hyprctl dispatch setfloating address:" + addr);
        }

        if (commands.length > 0) {
          moveAllWindows.command = ["bash", "-c", commands.join(" && ")];
          moveAllWindows.running = true;
        }
      }
      allSteamWindows = [];
    }
  }

  // Execute move all windows commands
  Process {
    id: moveAllWindows
    command: ["bash", "-c", ""]
    running: false

    onExited: (exitCode, exitStatus) => {
      if (exitCode === 0) {
        logDebug("SteamOverlay: All Steam windows moved to overlay and set as floating");
        // After moving all windows, position the main 3 and show workspace
        Qt.callLater(() => {
          if (steamWindows.length > 0) {
            moveWindowsToOverlay();
          }
        });
      }
    }
  }


  function toggleOverlay() {
    logDebug("SteamOverlay: " + (pluginApi?.tr("main.toggle_called") || "Toggle called"));

    if (!steamRunning) {
      logInfo("SteamOverlay: " + (pluginApi?.tr("main.launching_steam") || "Launching Steam"));
      launchSteam.running = true;
      return;
    }

    if (overlayActive) {
      // Hide overlay
      showWorkspace.running = true;
      overlayActive = false;
    } else {
      // Show overlay - detect main windows first, then all windows
      detectWindows.running = true;

      // Wait for main windows detection, then detect all windows
      Qt.callLater(() => {
        if (steamWindows.length > 0) {
          // Now detect and move ALL Steam windows
          detectAllWindows.running = true;
        } else {
          logWarn("SteamOverlay: " + (pluginApi?.tr("main.no_windows_found") || "No Steam windows found"));
        }
      });

      overlayActive = true;
    }
  }

  function moveWindowsToOverlay() {
    var commands = [];

    for (var i = 0; i < steamWindows.length; i++) {
      var win = steamWindows[i];
      var addr = win.address;
      var title = win.title;

      // Position based on title with percentage layout + center offset
      var x = 0, y = topMargin, w = 800, h = windowHeight;

      if (title === "Steam") {
        // Main window: center + friends + gap
        x = centerOffset + friendsWidth + gapSize;
        w = mainWidth;
      } else if (title === "Friends List") {
        // Friends: center offset (left side)
        x = centerOffset;
        w = friendsWidth;
      } else {
        // Chat: center + friends + gap + main + gap
        x = centerOffset + friendsWidth + gapSize + mainWidth + gapSize;
        w = chatWidth;
      }

      // Position and size the 3 main windows (they are already floating and in overlay)
      commands.push("hyprctl dispatch resizewindowpixel exact " + w + " " + h + ",address:" + addr);
      commands.push("hyprctl dispatch movewindowpixel exact " + x + " " + y + ",address:" + addr);
    }

    if (commands.length > 0) {
      moveWindows.command = ["bash", "-c", commands.join(" && ")];
      moveWindows.running = true;
    }
  }

  // IPC Handler
  IpcHandler {
    target: "plugin:hyprland-steam-overlay"

    function toggle() {
      logDebug("SteamOverlay: " + (pluginApi?.tr("main.ipc_received") || "IPC toggle received"));
      root.toggleOverlay();
    }
  }
}
