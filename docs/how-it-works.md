# How Findling works

Findling is a native macOS launcher for local files, folders, projects and apps, built with SwiftUI and AppKit. It keeps its own file system index and explains why each result matches. It needs no external packages and no server.

## Launcher

Findling opens from the menu bar or with **⇧⌘Space**. The panel opens on the display containing the pointer, including when moving between displays. It follows the system's light or dark appearance and closes when you click elsewhere. Reopening brings back the last search, selected, so typing replaces it.

At Medium text size the launcher is 720 pt wide, with an 18 pt corner radius, a 56 pt search bar, 36 pt type filters, 44 pt rows and a 32 pt footer. A separate 36 pt **Search in** row holds Everywhere, the folder filters and **+**, which adds one; it shows even before the first filter, so the feature can be found. Everywhere and folder choices share outlined buttons, with a colored background and checkmark on the active filter. Right-click a folder button to rename it (only the button; the folder keeps its name), show the folder in Finder or remove the button. The launcher fades in over 0.15 s while it grows from 98 % at its top edge, and fades out over 0.1 s; with Reduce Motion it only fades. Preview splits the body into a 296 pt list and a 424 pt detail area, with a 396 pt body height. Suggested items show up to eight rows. All application UI is English.

### Shortcut

To change the shortcut, click it under **Settings › General › Keyboard** and press the new combination; Escape cancels and **Reset** goes back to ⇧⌘Space. A global shortcut takes its keys away from every app, so Findling refuses, with an orange line, combinations that apps or typing need: ⌘ or ⌃ with a single key (⌘C, ⌘V, ⌃A), and keys with only ⌥ or ⇧, which type text (⌥L is @ on a German keyboard). Space is the exception: ⌥Space, ⌃Space or ⌘Space work when macOS does not use them. A shortcut saved before these rules that breaks them falls back to ⇧⌘Space.

A shortcut that another app or macOS (System Settings › Keyboard › Keyboard Shortcuts, such as ⌘Space for Spotlight) already holds usually never reaches the recorder: pressing it opens that app or feature, and recording stops with the previous shortcut kept. Findling still checks every new shortcut against both and keeps the previous one with an orange line when one of them has it. The check matters most when Findling starts: if the saved shortcut has been taken since, a notice offers **Open Settings**, the orange line shows there, and Findling stays available from the menu bar. The menu bar menu always shows the shortcut that currently works. Apps that read the keyboard directly, with an event tap, cannot be detected.

## Settings

Settings use a native 520 pt window with four toolbar tabs, ordered by how often they are needed: **General** (open at login, appearance, keyboard, updates), **Locations** (search locations, folder filters), **Exclusions** (excluded folders, automatically skipped, hidden results) and **Index** (status, access warnings, Refresh Now). Each tab is a grouped form; descriptions sit leading-aligned under their group, with the group's action on the trailing side. Settings reopen on the last tab, and the window height follows the tab and the text size.

**General** offers Small, Medium and Large text plus Blue, Purple, Teal and Rose theme colors. Typography and row heights adapt together. Colors follow the light or dark appearance and apply to selected results, folder filters, controls, the search caret and the selected settings tab, which Findling draws itself because AppKit would use the system accent color. Preferences apply immediately and persist across restarts without rebuilding the index. **Open at login** registers Findling with `SMAppService`; it can also be switched off in System Settings › General › Login Items. **Updates** turns the daily update check on or off, shows the version and the last check, and offers a newer release (see [Updates](#updates)).

Open Settings with the gear button in the search bar, **⌘,** or **Settings…** in the menu bar menu. **Search scope** in the launcher opens the Locations tab; the warning count in its footer opens Index.

- **Locations › Search locations › Add Folder…** adds an indexed location. A location inside another one is listed under it as “Already in Home folder”, because it adds nothing; cloud folders in Library are walked separately and keep their own row. Each location shows how many items it adds; iCloud Drive names the app folders it includes.
- **Locations › Folder filters › Add Folder Filter…**, or **+** at the end of the launcher's Search in row, adds a folder such as Nextcloud or Websites to the Search in row. When no search location reaches the folder yet, as for a cloud folder in the skipped Library, it also becomes a search location; inside the home folder it would add nothing. A folder added with **+** is selected right away. Folder and type filters combine; **Everywhere** clears the folder constraint. Removing a filter (in Settings, or by right-clicking its button) removes its button; a search location added with it stays until removed under Search locations.
- **Exclusions › Excluded folders › Exclude Folder…** excludes a folder and all descendants, even under explicitly included locations. Exclusions apply to search results immediately; their records are then removed from the index. Removing an exclusion walks only that folder again.
- **Exclusions › Automatically skipped** has one switch per category with a few typical folder names; the tooltip lists everything the category covers. **Always skipped** lists the fixed rules. Explicit locations can override automatically skipped ancestor directories, while custom exclusions always take priority.
- **Exclusions › Hidden results › Show hidden results** lists individually hidden items with a Restore button. This differs from excluding an entire folder tree.
- **Index** shows the item count, indexing status, last update and size on disk, and lists folders Findling could not read. **Refresh Now** walks every location again; it is only needed after a “could not watch your folders” warning or for network volumes.

Removing a search location does not exclude it if another location still contains it (for example, the home folder). Use Excluded folders in that case.

## Search and data

- Findling searches names and paths, with diacritic-insensitive matching, Turkish dotless i, and ordered-letter matching (`ftra` → `fatura`).
- Apps and system folders are also found by their names in each of your preferred languages (`Kalender` or `Takvim` for Calendar.app, `Dokumente` or `Belgeler` for Documents); results show the name Finder shows.
- Exact names rank above prefixes, contained names, project matches and paths. Copies inside `backup` or `backups` folders follow the originals they duplicate. Folders that share a name are listed from the shallowest down; files with the same name keep the recently changed one first.
- Projects are recognized through `.git`, `Package.swift`, `package.json`, `Cargo.toml`, `pyproject.toml` and `pubspec.yaml`. The Projects filter appears only when the index holds at least one project; Tab skips it otherwise.
- Pin and hide results; restore hidden results in Settings.
- Findling learns only from successful opens in Findling. A previous choice for the same normalized query takes priority, with the latest choice winning. Related query prefixes of at least three characters also recall opened results; an exact saved query choice wins over a related one. Hidden results stay hidden until restored. Revealing a result in Finder also records the choice. Up to 64 query choices per item are stored locally.
- The preview shows the match reason, path, project, created and modified dates, the last time the item was opened (when macOS recorded one that differs from the modification date), and for files their size, with pixel dimensions for images and videos and page counts for PDFs and documents. Images, PDFs and documents get a 128 pt Quick Look thumbnail in place of the icon; supported text files show their first 6 KB instead. Markdown is laid out as headings, lists, task lists, quotes, code blocks and tables; front matter is left out, and Obsidian's `[[links]]` and callouts show as text. Links in the preview do not open. All of it is read for the selected item only while the preview is open and never stored in the index. Files still in the cloud (iCloud with optimized storage, Nextcloud and other File Provider folders) show their icon and dates only; previews never start a download.
- The default scope is the home folder, `/Applications`, `/System/Applications`, iCloud Drive when available and `~/Library/CloudStorage`. iCloud Drive includes the app folders Finder shows in it (Obsidian, Pages, Books), which macOS keeps elsewhere; Findling finds them at launch, and paths show as `iCloud Drive/…`.
- Findling skips hidden files, symlinks, dependencies (including Python environments), caches, build outputs and application package contents. In a `tags` folder of release versions (Subversion checkouts) only the newest version is indexed. Explicit cloud locations are scanned separately from the otherwise skipped Library folder.
- The index is an SQLite database with one record per item (`~/Library/Application Support/Findling/catalog-v2.sqlite`, WAL mode, small page cache). It is not loaded into memory; searches read it on a separate connection while updates are written.
- File system events (FSEvents) keep the index current: changed folders are compared with their stored children, and only new, changed or removed records are written. New folders and folders that become or stop being projects are walked completely. The last applied event is stored after each update, so changes made while Findling was closed are replayed on the next launch. Bursts of file activity (dependency installs, checkouts, test runs) can make macOS drop events and ask for a rescan of every location; Findling waits until the burst has been quiet for five seconds and then lists only folders whose modification date changed. Adding, removing or renaming items always changes that date, so nothing structural is missed; edits inside existing files keep their previous date until the next event for their folder. Events are logged under the `com.hamzabasaran.findling` subsystem (`log stream --level info --predicate 'subsystem == "com.hamzabasaran.findling"'`); paths in them are private and show as `<private>`.
- All locations are walked only for a new index, when the event history is unavailable (for example after a volume was erased), and with **Refresh Now**. Unchanged items are not rewritten. Adding a location or removing an exclusion walks just that folder; removing a location or adding an exclusion deletes its records. Walks proceed folder level by folder level, so shallow items become searchable first. Inaccessible folders keep their records until access is restored.
- Live indexing status shows the import percentage and, during walks, the number of items checked and the current folder. Updates are throttled to avoid slowing down indexing.
- Each match tier (exact name, prefix, contained name, name or project, path, letters in order) selects its candidates through an index: a trigram index of names and projects, the name and stem-length indexes, and folder subtrees for path matches. Large tiers are read in ranking order, and lower tiers are skipped once they can no longer reach the best 80. Pinned, hidden and previously opened items are ranked separately because they can outrank any tier. Better tiers are shown first; superseded searches are cancelled inside SQLite. An explicit row selection is preserved as later results arrive. File icons are cached and queries have no fixed debounce delay.

No telemetry, content search, OCR or tracking of activity in other apps; the update check is the only network request. Files are never moved or modified. Opening an iCloud result may let macOS download it. File system changes appear a few seconds after they happen.

## Updates

Findling asks GitHub for its latest release 10 seconds after launch and then whenever an hourly tick finds that 24 hours have passed since the last check. The time of the last check is stored, so restarts don't check again, and **Check for updates automatically** in Settings › General turns the check off. The request is `GET https://api.github.com/repos/mehambas/findling/releases/latest` on an ephemeral URL session without cookies, cache or credentials, with a 15-second timeout. Besides the address it sends only `User-Agent: Findling/<version>`, `Accept-Language: en` and the standard Accept headers: no identifiers, system details or usage data. Any failure (no published release, offline, timeout, rate limit) counts as no news. Automatic checks stay silent about it; **Check for Updates…** in the menu bar menu and **Check Now** in Settings › General always say what they found.

The release's tag (`v0.2.0`) is compared with `CFBundleShortVersionString` number by number, so 0.10.0 is newer than 0.9.0. A newer release puts **Update to 0.2.0…** at the top of the menu bar menu and a row with **Release Notes** and **Download and Install** in Settings › General; the offer is stored until a later check replaces it. **Download and Install** downloads the asset `Findling.dmg` to the temporary folder and compares its SHA-256 with the asset `Findling.dmg.sha256`. If the checksum is missing or does not match, the download is deleted and the release page opens in the browser instead. A verified disk image opens in Finder and Findling quits: it is not notarized, so it cannot replace itself, and Finder won't replace a running app. The user drags the new version to Applications. Progress and errors show in the menu item and the Settings row.

To try the whole flow, serve a release from a local server and start a build with the testing variables:

```sh
FINDLING_FAKE_VERSION=0.0.1 FINDLING_UPDATE_BASE=http://127.0.0.1:8000 dist/Findling.app/Contents/MacOS/Findling
```

`FINDLING_FAKE_VERSION` pretends to be another version. `FINDLING_UPDATE_BASE` replaces `https://api.github.com/repos/mehambas/findling`, so the server answers `/releases/latest` with GitHub's JSON (`tag_name`, `html_url`, and `assets` whose `browser_download_url`s point back to the server). With either variable set, Findling checks 10 seconds after launch whatever the last check was, and stores neither the check time nor the offer. Quit the installed Findling first: both would use the same index and shortcut.

## Performance

Measured on 2026-10-15 on an M1 Max: with the default skip rules, a new index of the home folder, Applications, iCloud Drive and cloud folders holds about 1.07 million items instead of 3.2 million. Building it took 141 s and 96 s CPU on an idle Mac, and 501 s while the Mac was in use, because indexing runs at utility priority; the peak footprint stayed below 150 MB and the index is about 0.6 GB. Walking an unchanged index (Refresh Now) takes about 2 minutes and writes nothing; it only runs for a new index, missing event history, changed skip rules or Refresh Now. With a warm file cache most searches take 0–50 ms; searches that fall through to letters-in-order matching across the whole index take about 70–80 ms. At rest the app uses about 0–1 % CPU and a 30–40 MB footprint. After a burst of 60,000 file operations that made macOS drop events, the folder-date check took about 47 s and 11 s CPU and changed nothing.

## Development

```sh
swift test --disable-sandbox --cache-path .build/cache -c release
bash scripts/build.sh
open dist/Findling.app
```

`scripts/build.sh` builds a universal app (Apple silicon and Intel) into `dist/Findling.app`. macOS ties folder permissions to the app's signature. An ad hoc signature changes with every build, so macOS asks for access again after each rebuild. `scripts/make-certificate.sh <backup folder>` creates a self-signed “Findling Self-Signed” certificate in the login keychain, which `build.sh` then uses; `FINDLING_SIGN_IDENTITY` picks another identity, and `-` forces ad hoc signing. Releases must always be signed with the same certificate. Keep the backup the script writes: builds signed with a new certificate lose the permissions users granted.

### Tests and visual check

Core tests cover ranking, Turkish normalization, learned choices, pin/hide, filtering, catalog persistence, project detection, scan scope and exclusions, nested search locations, per-location item counts, preview details (dates, the last open as Launch Services records it versus the stand-ins Spotlight and Nextcloud leave, sizes, pixels of rotated photos, PDF pages), Markdown blocks, update versions, GitHub release answers and checksum files, plus 190k-item (in memory) and 200k-item (catalog) release performance checks. Catalog tests compare the on-disk search with the in-memory ranking for 1,200 randomized queries and filter combinations and cover incremental updates against a fresh scan, unreadable folders, pruning, watcher event planning, cancellation and FSEvents replay since a stored event id.

```sh
# Deterministic fixture data: no personal index or preferences are touched.
dist/Findling.app/Contents/MacOS/Findling --capture-previews /tmp/findling-previews
```

The visual check exports 65 captures: all three text sizes × four themes × two appearances, previews of a generated PNG, PDF and Markdown note, every settings tab in both appearances, an update offer and its download, the shortcut recorder states, settings while indexing and with access warnings. Along the way it checks keyboard navigation, filters, exclusions, the shortcut recorder against a stand-in for `RegisterEventHotKey`, nested-location detection and the Add Folder Filter sheet.

### Demo animations

```sh
bash scripts/build.sh && scripts/make-demo.sh
```

`--capture-demo` writes sample files to a temporary folder, plays a short session in the launcher (shown as if the folder were the home folder) and saves each step as a frame; `make-demo.sh` turns the frames into `docs/images/demo-dark.gif` and `demo-light.gif` with ffmpeg.

### Icon

`Resources/Icon` holds the icon sources: the 1024 px artwork, simplified artwork for 16 and 32 px, the layers and the menu bar icon. `Resources/AppIcon.icon` is the Icon Composer version, built from the stone and highlight layers with a light and a dark fill; macOS 26 and later derive the tinted and clear styles from it. After changing either, run `scripts/make-icon.sh`: it writes `AppIcon.icns` for macOS 14 and 15 and compiles the `.icon` into `Assets.car` (this needs Xcode 26 or later). Both results are committed, so building the app needs neither Xcode nor the script. To check every style without changing System Settings:

```sh
"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" Resources/AppIcon.icon \
    --export-image --output-file dark.png --platform macOS --rendition Dark --width 512 --height 512 --scale 1
```

The renditions are `Default`, `Dark`, `TintedLight`, `TintedDark`, `ClearLight` and `ClearDark`.

### Releases

```sh
scripts/release.sh 0.2.0
```

The release script sets the version in `Resources/Info.plist`, increments the build number, builds and signs the app with the self-signed certificate, packs it into `dist/Findling.dmg` and writes its SHA-256 to `dist/Findling.dmg.sha256`. Attach both files to the GitHub release (tag `v0.2.0`) under these names: the README links `releases/latest/download/Findling.dmg`, and the update check installs only a disk image whose checksum file it finds next to it.

### Measuring

```sh
# Sample the running app and its index read-only, as CSV.
scripts/monitor-index.sh 10 first-index.csv
# Measure on copies only, never the live index.
swiftc -O -parse-as-library -module-name SearchBenchmark -I Sources/CSQLite Sources/FindlingCore/*.swift scripts/benchmark-search.swift -lsqlite3 -o .build/benchmark-search
.build/benchmark-search <copy of catalog.sqlite> <new catalog path> [--scan] [--compare] [--utility] [queries…]
```
