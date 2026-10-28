# Changelog

## 0.2.1

- Safari is found again. Since macOS 13 it lives outside the Applications folder, where only a link to it remains.

## 0.2.0

- Update check: once a day Findling asks GitHub for the latest version number, and nothing about you or your files is sent. A newer version appears at the top of the menu bar menu and in Settings › General, where Download and Install verifies the disk image, opens it and quits Findling so you can drag the new version to Applications. Check for Updates… checks right away; Settings › General turns the daily check off.
- Releases are published as `Findling.dmg` with its checksum in `Findling.dmg.sha256`, so the download link stays the same for every version.

## 0.1.0

First public release.

- Launcher for files, folders, projects and apps with ⇧⌘Space, a local index kept current by file system events, and ranking that explains each match.
- Preview with Quick Look thumbnails, file details and rendered Markdown.
- Type filters, folder filters, pins, hidden results and learned choices.
- Settings for locations, exclusions, appearance, the shortcut and open at login.
