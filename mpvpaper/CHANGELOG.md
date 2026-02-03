# Changelog

Here I'll try to document all changes for the mpvpaper plugin.

## 1.4.0 - 2026-02-03

- feat: Added the ability to manipulate both audio and play/pause.
- feat: Added so that a user can use both the video and the picture default wallpaper.
- fix: Fixed a bug where the thumbnail folder wasn't created correctly on startup.
- fix: Fixed other minor bugs.

## 1.3.0 - 2026-02-02

- feat: Added color generation by utilizing the thumbnails.
- feat: Added a context menu for the bar widget, for easier toggling of the wallpaper.
- fix: Fixed some bugs that gave a lot of warnings to the debug logs.

## 1.2.0 - 2026-02-01

- feat: Added thumbnail generation for all the videos inside of the wallpaper folder, scaled down to save space.
- feat: Added a panel for selecting a wallpaper with some buttons to choose the wallpaper folder, refresh the thumbnails, choose a random wallpaper and clear the current wallpaper.
- feat: Added a bar widget for opening the panel.
- fix: Fixed a bug where if the active setting was turned off and you restarted the computer mpvpaper would start automatically.
- fix: Fixed a bug so that it doesn't try to run the process while current wallpaper is empty.

## 1.1.0 - 2026-01-31

- feat: Added IPC handlers for toggling, setting and getting active state.
- feat: Added IPC handler for getting the current wallpaper.
- fix: Fixed some debug logs for better error debugging.

## [1.0.0] - Initial Release

- feat: Added mpvpaper process creation and destruction
- feat: Added socket for handling changing the wallpaper
- feat: Added settings menu to be able to change current wallpaper, wallpapers folder, mpvpaper socket location and a random and clear button.
