import QtQuick
import QtQuick.LocalStorage
import Quickshell
import Quickshell.Io
import qs.Commons

Item {
    id: root

    // Plugin API provided by PluginService
    property var pluginApi: null

    // Provider metadata
    property string name: "Calibre"
    property var launcher: null
    property bool handleSearch: false
    property string supportedLayouts: "list"
    property bool supportsAutoPaste: true

    // Constants
    property int maxResults: 50

    // Database
    property string databaseRoot: ""
    property var database: null
    property bool loaded: false
    property bool loading: false

    // TODO: Write a custom one instead
    Process {
        id: calibreDbLoader
        command: ["calibredb", "list", "--for-machine", "--fields", "title,authors,formats,cover"]
        stdout: StdioCollector {
        }
        stderr: StdioCollector {
        }
        onExited: root.parseDb(exitCode)
    }

     FileView {
        id: calibreConfigFile
        onLoaded: root.calibreConfigLoaded(text())
    }

    FileView {
        id: calibreDbFile
        watchChanges: true
        onFileChanged: root.reloadDb()
    }


    // Load database on init
    function init() {
        Logger.i("CalibreProvider", "init called, pluginDir:", pluginApi?.pluginDir);
        findCalibreLibrary()
    }

    function findCalibreLibrary() {
        const config = Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config";
        const calibreConfig = config + "/calibre/global.py";
        calibreConfigFile.path = calibreConfig;
        calibreConfigFile.reload();
    }

    function calibreConfigLoaded(text: string) {
        const search = /library_path = u'(.*)'/;
        const matches = text.match(search);
        if( !!matches && matches.length >= 2) {
            databaseRoot = matches[1]
            calibreDbFile.path = databaseRoot + '/metadata.db';
            reloadDb();
        } else {
            Logger.e("CalibreProvider", "Could not find calibre library location");
        }
    }

    function reloadDb() {
        if(calibreDbLoader.running) {
            Logger.w("CalibreProvider", "Already reloading db!");
            return;
        }
        Logger.i("CalibreProvider", "Reloading db");
        loading = true;
        calibreDbLoader.running = true;
    }

    function parseDb(exitCode: int) {
        if( exitCode != 0 ) {
            Logger.e("CalibreProvider", "Error loading Calibre db: ", calibreDbLoader.stderr.text);
        }

        try {
            const punct = /[^a-z0-9 ]/gi
            var rawdb = Array.from(JSON.parse(calibreDbLoader.stdout.text));
            database = []
            rawdb.forEach((entry) => {
                for(var i = 0; i < entry.formats.length; i++) {
                    const file = entry.formats[i];
                    const extension = file.slice(file.lastIndexOf('.')+1).toUpperCase();
                    database.push({
                        title: entry.title,
                        description: extension + " • " + entry.authors,
                        cover: entry.cover,
                        file,
                        authorSearch: entry.authors.toLowerCase().replace(punct, ""),
                        titleSearch: entry.title.toLowerCase().replace(punct, ""),
                    });
                }
            });
            loaded = true;
            Logger.i("CalibreProvider", "Finished loading db");
        } catch (e) {
            Logger.e("CalibreProvider", "Error parsing Calibre db: ", e);
        }

        loading = false;
    }

    function handleCommand(searchText) {
        return searchText.startsWith(">cb ");
    }

    // Return available commands when user types ">"
    function commands() {
        return [{
            "name": ">cb",
            "description": "Search for books in your Calibre library",
            "icon": "books",
            "isTablerIcon": true,
            "isImage": false,
            "onActivate": function() {
                launcher.setSearchText(">cb ");
            }
        }];
    }


    // Get search results
    function getResults(searchText) {
        if (!searchText.startsWith(">cb")) {
            return [];
        }

        var query = searchText.slice(4).trim().toLowerCase();
        var results = [];

        if (query === "") {
        } else {
            // Search mode
            for (var i = 0; i < database.length && results.length < maxResults; i++) {

                const entry = database[i];

                if (entry.authorSearch.includes(query) || entry.titleSearch.includes(query)) {
                    results.push(formatEntry(query, entry));
                }
            }
        }

        return results;
    }

    function formatEntry(query, entry) {
        return {
          // Display
          "name": entry.title,           // Main text
          "description": entry.description,   // Secondary text (optional)

          // Icon options (choose one)
          "icon": entry.cover,                   // Icon name
          "isTablerIcon": false,             // Use Tabler icon set
          "isImage": true,                 // Is this an image?
          "hideIcon": false,                // Hide the icon entirely

          // Layout
          "singleLine": false,              // Clip to single line height

          // Reference
          "provider": root,                 // Reference to provider (for actions)

          // Callbacks
          "onActivate": function() {        // Called when result is selected
              root.activateEntry(entry);
              launcher.close();
          },
        }
    }

    function getImageUrl(modelData) {
        return modelData.icon;
    }

    function activateEntry(entry) {
        Logger.d("CalibreProvider", "Opening file:", entry.file );
        Quickshell.execDetached(["xdg-open", entry.file]);

    }
}
