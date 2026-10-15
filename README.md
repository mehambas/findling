# FindIt

A native macOS launcher for local files, folders, projects and apps. Built with SwiftUI and AppKit, with an independent filesystem index and explainable search ranking. Requires macOS 14+ and Xcode / Swift tools; no external packages or server.

## Run

```sh
bash scripts/build.sh
open dist/FindIt.app
```

The app is built for Apple silicon and Intel. It is signed with the first Developer ID or Apple Development certificate in the keychain, which keeps macOS folder permissions across rebuilds; without one it is signed ad hoc (`FINDIT_SIGN_IDENTITY` overrides the choice, `-` forces ad hoc). Other Macs show Gatekeeper's warning unless the app is signed with Developer ID and notarized. An Apple Development certificate's name, including the Apple ID email, is readable in the signature; build copies for others with `FINDIT_SIGN_IDENTITY=-`.

Open FindIt from the menu bar or with **⇧⌘Space**, which you can change in **Settings → General**. The panel opens on the display containing the pointer, including when moving between displays. It follows the system’s light/dark appearance and closes when you click elsewhere.

| Shortcut | Action |
| --- | --- |
| ↑ / ↓ | Select a result |
| Return | Open |
| ⌘Return | Show in Finder |
| Tab / Shift-Tab | Next / previous type filter |
| Shift-Delete / ⌘Delete | Clear the entire search query |
| → / ← at the end of the query | Open / close preview |
| ⌘Y | Toggle preview |
| ⌘K | Actions menu |
| ⌘P | Pin / unpin |
| ⌘, | Settings |
| Escape | Close preview, then close launcher |

Click selects a row; double-click opens it. Right-click opens its actions.

To change the shortcut, click it under **Settings → General → Keyboard** and press the new combination; Escape cancels and **Reset** goes back to ⇧⌘Space. A global shortcut takes its keys away from every app, so FindIt refuses, with an orange line, combinations that apps or typing need: ⌘ or ⌃ with a single key (⌘C, ⌘V, ⌃A), and keys with only ⌥ or ⇧, which type text (⌥L is @ on a German keyboard). Space is the exception: ⌥Space, ⌃Space or ⌘Space work when macOS does not use them. A shortcut saved before these rules that breaks them falls back to ⇧⌘Space.

A shortcut that another app or macOS (System Settings › Keyboard › Keyboard Shortcuts, such as ⌘Space for Spotlight) already holds usually never reaches the recorder: pressing it opens that app or feature, and recording stops with the previous shortcut kept. FindIt still checks every new shortcut against both and keeps the previous one with an orange line when one of them has it. The check matters most when FindIt starts: if the saved shortcut has been taken since, a notice offers **Open Settings**, the orange line shows there, and FindIt stays available from the menu bar. The menu bar menu always shows the shortcut that currently works. Apps that read the keyboard directly, with an event tap, cannot be detected.

## Design

Implemented from **“Macos Launcher-style Search App Called Findit”** in OpenDesign (project `2dd7610b-130a-4683-bfb7-5e72fbb19f4b`). The source board is preserved in `design/reference/findit.html`; its illustrative assets are included alongside it. The app uses actual macOS file icons and native visual-effect materials.

At Medium text size, the launcher is 720 pt wide, with an 18 pt corner radius, a 56 pt search bar, 36 pt type filters, 44 pt rows and a 32 pt footer. A separate 36 pt **Search in** row holds Everywhere, the folder filters and **+**, which adds one; it shows even before the first filter, so the feature can be found. Everywhere and folder choices share outlined buttons, with a colored background and checkmark on the active filter. Right-click a folder button to rename it (only the button; the folder keeps its name), show the folder in Finder or remove the button. The launcher fades in over 0.15 s while it grows from 98 % at its top edge, and fades out over 0.1 s; with Reduce Motion it only fades. Reopening brings back the last search, selected, so typing replaces it. Preview splits the body into a 296 pt list and a 424 pt detail area, with a 396 pt body height. Suggested items show up to eight rows. Settings use a native 520 pt window with toolbar tabs (see below). All application UI is English.

Settings follow **“FindIt Settings Redesign”** in OpenDesign (project `0c4b1cd0-e755-4536-830b-08df0803abc4`). Four toolbar tabs are ordered by how often they are needed: **General** (appearance, keyboard), **Locations** (search locations, folder filters), **Exclusions** (excluded folders, automatically skipped, hidden results) and **Index** (status, access warnings, Refresh Now). Each tab is a grouped form; descriptions sit leading-aligned under their group, with the group's action on the trailing side. Settings reopen on the last tab, and the window height follows the tab and the text size.

**Settings → General** offers Small, Medium and Large text plus Blue, Purple, Teal and Rose theme colors. Typography and row heights adapt together. Colors follow macOS light/dark appearance and apply to selected results, folder filters, controls, the search caret and the selected settings tab, which FindIt draws itself because AppKit would use the system accent color. Preferences apply immediately and persist across restarts without rebuilding the index.

## Locations and exclusions

Open Settings using the gear button in the search bar, **⌘,**, or **Settings…** in the menu bar menu. **Search scope** in the launcher opens the Locations tab; the warning count in its footer opens Index.

- **Locations → Search locations → Add Folder…** adds an indexed location. A location inside another one is listed under it as “Already in Home folder”, because it adds nothing; cloud folders in Library are walked separately and keep their own row. Each location shows how many items it adds; iCloud Drive names the app folders it includes.
- **Locations → Folder filters → Add Folder Filter…**, or **+** at the end of the launcher's Search in row, adds a folder such as Nextcloud or Websites to the Search in row. When no search location reaches the folder yet, as for a cloud folder in the skipped Library, it also becomes a search location; inside the home folder it would add nothing. A folder added with **+** is selected right away. Folder and type filters combine; **Everywhere** clears the folder constraint. Removing a filter (in Settings, or by right-clicking its button) removes its button; a search location added with it stays until removed under Search locations.
- **Exclusions → Excluded folders → Exclude Folder…** excludes a folder and all descendants, even under explicitly included locations. Exclusions apply to search results immediately; their records are then removed from the index. Removing an exclusion walks only that folder again.
- **Exclusions → Automatically skipped** has one switch per category with a few typical folder names; the tooltip lists everything the category covers. **Always skipped** lists the fixed rules. Explicit roots can override automatically skipped ancestor directories, while custom exclusions always take priority.
- **Exclusions → Hidden results → Show hidden results** lists individually hidden items with a Restore button. This differs from excluding an entire folder tree.
- **Index** shows the item count, indexing status, last update and size on disk, and lists folders FindIt could not read. **Refresh Now** walks every location again; it is only needed after a “could not watch your folders” warning or for network volumes.

Removing a search location does not exclude it if another location still contains it (for example, the home folder). Use Excluded folders in that case.

## Search and data

- Search names and paths, with Turkish character normalization and ordered-letter matching (`ftra` → `fatura`).
- Apps and system folders are also found by their names in each of your preferred languages (`Kalender` or `Takvim` for Calendar.app, `Dokumente` or `Belgeler` for Documents); results show the name Finder shows.
- Exact names rank above prefixes, contained names, project matches and paths. Copies inside `backup` or `backups` folders follow the originals they duplicate. Folders that share a name are listed from the shallowest down; files with the same name keep the recently changed one first.
- Recognizes projects through `.git`, `Package.swift`, `package.json`, `Cargo.toml`, `pyproject.toml` and `pubspec.yaml`. The Projects filter appears only when the index holds at least one project; Tab skips it otherwise.
- Pin and hide results; restore hidden results in Settings.
- Learns only from successful opens in FindIt. A previous choice for the same normalized query takes priority, with the latest choice winning. Related query prefixes of at least three characters also recall opened results; an exact saved query choice wins over a related one. Hidden results stay hidden until restored. Revealing a result in Finder also records the choice. Stores up to 64 query choices per item locally.
- Shows the match reason, path, project, created and modified dates, the last time the item was opened (when macOS recorded one that differs from the modification date), and for files their size, with pixel dimensions for images and videos and page counts for PDFs and documents. Images, PDFs and documents get a 128 pt Quick Look thumbnail in place of the icon; supported text files show their first 6 KB instead. Markdown is laid out as headings, lists, task lists, quotes, code blocks and tables; front matter is left out, and Obsidian's `[[links]]` and callouts show as text. Links in the preview do not open. All of it is read for the selected item only while the preview is open and never stored in the index. Files still in the cloud (iCloud with optimized storage, Nextcloud and other File Provider folders) show their icon and dates only; previews never start a download.
- Default scope includes the home folder, `/Applications`, `/System/Applications`, available iCloud Drive and `~/Library/CloudStorage`. Add or remove locations in Settings. iCloud Drive includes the app folders Finder shows in it (Obsidian, Pages, Books), which macOS keeps elsewhere; FindIt finds them at launch, and paths show as `iCloud Drive/…`.
- Skips hidden files, symlinks, dependencies (including Python environments), caches, build outputs and application package contents. In a `tags` folder of release versions (Subversion checkouts) only the newest version is indexed. Explicit cloud roots are scanned separately from the otherwise excluded Library directory.
- The index is an SQLite database with one record per item (`~/Library/Application Support/Bul/catalog-v2.sqlite`, WAL mode, small page cache). It is not loaded into memory; searches read it on a separate connection while updates are written.
- File system events (FSEvents) keep the index current: changed folders are compared with their stored children, and only new, changed or removed records are written. New folders and folders that become or stop being projects are walked completely. The last applied event is stored after each update, so changes made while FindIt was closed are replayed on the next launch. Bursts of file activity (dependency installs, checkouts, test runs) can make macOS drop events and ask for a rescan of every location; FindIt waits until the burst has been quiet for five seconds and then lists only folders whose modification date changed. Adding, removing or renaming items always changes that date, so nothing structural is missed; edits inside existing files keep their previous date until the next event for their folder. Events are logged under the `com.hamzabasaran.bul` subsystem (`log stream --level info --predicate 'subsystem == "com.hamzabasaran.bul"'`).
- All locations are walked only for a new index, when the event history is unavailable (for example after a volume was erased), and with **Refresh Now**. Unchanged items are not rewritten. Adding a location or removing an exclusion walks just that folder; removing a location or adding an exclusion deletes its records. Walks proceed folder level by folder level, so shallow items become searchable first. Inaccessible folders retain their records until access is restored.
- Live indexing status shows the import percentage and, during walks, the number of items checked and the current folder. Updates are throttled to avoid slowing down indexing.
- Each match tier (exact name, prefix, contained name, name or project, path, letters in order) selects its candidates through an index: a trigram index of names and projects, the name and stem-length indexes, and folder subtrees for path matches. Large tiers are read in ranking order, and lower tiers are skipped once they can no longer reach the best 80. Pinned, hidden and previously opened items are ranked separately because they can outrank any tier. Better tiers are shown first; superseded searches are cancelled inside SQLite. An explicit row selection is preserved as later results arrive. File icons are cached and queries have no fixed debounce delay.

The rename deliberately retains `com.hamzabasaran.bul`, preserving existing scope, pins, hidden results and learned choices in its user defaults. The previous single-file catalog (`catalog.sqlite`) is imported once into `catalog-v2.sqlite` in bounded chunks and resumes if interrupted; FindIt never modifies or deletes the previous file. Internal kind identifiers remain compatible; their UI labels are English.

No network requests, telemetry, content search, OCR or tracking of activity in other apps. Files are never moved or modified. Opening an iCloud result may let macOS download it. File system changes appear a few seconds after they happen.

## Verify

```sh
swift test --disable-sandbox --cache-path .build/cache -c release
# Deterministic fixture data: no personal index or preferences are touched.
dist/FindIt.app/Contents/MacOS/FindIt --capture-previews "$PWD/design/previews"
```

Core tests cover ranking, Turkish normalization, learned choices, pin/hide, filtering, catalog persistence, project detection, scan scope and exclusions, nested search locations, per-location item counts, preview details (dates, the last open as Launch Services records it versus the stand-ins Spotlight and Nextcloud leave, sizes, pixels of rotated photos, PDF pages), Markdown blocks (front matter, task lists, Obsidian links and callouts, tables, text cut off mid-block), plus 190k-item (in memory) and 200k-item (catalog) release performance checks. Catalog tests compare the on-disk search with the in-memory ranking for 1,200 randomized queries and filter combinations — including forced score-ordered reads and their fallback — and cover importing the previous catalog with an interrupted and resumed import, incremental updates against a fresh scan (deletions, renames, new folders, a folder becoming a project), unreadable folders, pruning, watcher event planning, cancellation and FSEvents replay since a stored event id. The visual check exports 63 captures, including all three text sizes × four themes × two appearances, large-text previews, previews of a generated PNG, PDF and Markdown note with fixed dates in both appearances (the note also scrolled to its end) and at Large, every settings tab in both appearances, the shortcut recorder while recording, with a refused and with a taken shortcut, settings while indexing, with access warnings and with all lists expanded, and General at Large. It checks settings tab switching, the shortcut recorder (pausing the shortcut while recording, refusing ⌘ or ⌃ with a single key and keys that type text while allowing ⌥Space, Escape, Reset, keeping the old shortcut when macOS or another app has the new one, the launch notice and the menu bar shortcut) against a stand-in for RegisterEventHotKey, nested-location detection, the launcher’s Add Folder Filter sheet, filter names and removal, the selected search after reopening, the Projects filter without projects, selection contrast, search input font sizing, preservation of combined filters during appearance changes, indexing progress, Shift/Command-Delete, immediate cached exclusions, arrow navigation, caret editing, preview, Escape and filter cycling.

Real-catalog measurement (2026-10-15, M1 Max): with the default skip rules, a new index of the home folder, Applications, iCloud Drive and cloud folders holds about 1.07 million items instead of 3.2 million. Building it took 141 s and 96 s CPU on an idle Mac, and 501 s while the Mac was in use, because indexing runs at utility priority; the peak footprint stayed below 150 MB and the catalog is about 0.6 GB. Walking an unchanged catalog (Refresh Now) takes about 2 minutes and writes nothing; it only runs for a new index, missing event history, changed skip rules or Refresh Now. With a warm file cache most searches take 0–50 ms; searches that fall through to letters-in-order matching across the whole catalog take about 70–80 ms. At rest the app uses about 0–1% CPU and a 30–40 MB footprint. After a burst of 60,000 file operations that made macOS drop events, the folder-date check took about 47 s and 11 s CPU and changed nothing; checking folders on four threads brought the check down to about 10 s in a benchmark. Importing the previous single-file catalog took 63 s (59 s CPU). Before: 17 GiB RAM, about 93% CPU, a full scan every five minutes, 51 s search preparation and 1.4 s per complete search.

```sh
# Sample the running app and its catalog read-only, as CSV (see docs/test-plan-fresh-install.md).
scripts/monitor-index.sh 10 first-index.csv
# Measure on copies only, never the live catalog.
swiftc -O -parse-as-library -module-name SearchBenchmark -I Sources/CSQLite Sources/BulCore/*.swift scripts/benchmark-search.swift -lsqlite3 -o .build/benchmark-search
.build/benchmark-search <copy of catalog.sqlite> <new catalog path> [--scan] [--compare] [--utility] [queries…]
```
