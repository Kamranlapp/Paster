# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

PasteList is a native macOS menu-bar clipboard manager (SwiftUI + AppKit, Swift 6). It runs as an accessory app (`NSApp.setActivationPolicy(.accessory)`), stores clipboard history locally in SQLite via GRDB, and has no accounts, cloud sync, analytics, or network access.

## Commands

Build and run: open `PasteList.xcodeproj` in Xcode, select the **PasteList** scheme, and run. Dependencies (GRDB) resolve automatically via Swift Package Manager — there is no `Package.swift`; SPM packages are referenced directly from the Xcode project.

Run the full test suite:

```sh
xcodebuild test -project PasteList.xcodeproj -scheme PasteList -destination 'platform=macOS'
```

Run a single test class or method (add `-only-testing` to the same invocation):

```sh
xcodebuild test -project PasteList.xcodeproj -scheme PasteList -destination 'platform=macOS' \
  -only-testing:PasteListTests/ClipRepositoryTests
xcodebuild test -project PasteList.xcodeproj -scheme PasteList -destination 'platform=macOS' \
  -only-testing:PasteListTests/ClipRepositoryTests/testExample
```

Package a signed Release build into a DMG:

```sh
Scripts/package-dmg.sh /path/to/Release/PasteList.app
```

### Accessibility / Apple Events permissions during development

Debug builds use the app name `PasteDebug` and bundle identifier `com.kam.pastelist.debug`, keeping their TCC record, app data, and reset commands isolated from the Release/TestFlight identifier `com.kam.pastelist`. macOS retains permission decisions after uninstall, so after switching from an older Debug build reset both stale automatic-paste records with `tccutil reset Accessibility com.kam.pastelist.debug` and `tccutil reset PostEvent com.kam.pastelist.debug`, then grant PasteDebug access from the first onboarding page.

`SMAppService.mainApp` (Launch at Login) only registers reliably when the app runs from a stable path such as `/Applications/PasteList.app` — registration from Xcode's DerivedData is unreliable.

## Architecture

### Composition root

There is no dependency-injection framework. `AppDelegate.applicationDidFinishLaunching` (`PasteList/PasteListApp.swift`) is the single composition root: it constructs `AppDatabase` → `BlobStorage` → `ClipRepository` → `PasteboardCaptureProcessor` → `PasteboardMonitor`, then the various controllers, and wires their closures together by hand. When adding a new subsystem, wire it here rather than reaching for a service locator or singleton. Hosted unit tests short-circuit this method (`XCTestConfigurationFilePath` env check) and construct their own isolated databases instead.

The only SwiftUI `Scene` is a hidden `Settings {}` scene used to host preferences; almost all UI is AppKit windows/panels hosting SwiftUI views via `NSHostingController`, driven by `StatusItemController`.

### Clipboard capture pipeline

`PasteboardMonitor` polls `NSPasteboard.general.changeCount` on a 0.4s timer (macOS has no clipboard-change notification API) and hands new content to `ClipboardParser`, which classifies it into a `ParsedClipboardItem`. That item flows into `PasteboardCaptureProcessor` (an `actor`), which:

1. Normalizes the payload into a `PreparedPayload` (text, RTF, image PNG, files, or URL).
2. Checks `isConsecutiveDuplicate` against the most recent DB row so re-copying the same thing doesn't spam history — text/URL compares content directly, RTF/image compares decoded blob bytes, files compare via `FileContentComparator` (recursive, byte-for-byte for directories).
3. Inserts a `ClipRecord` through `ClipRepository`. Blob-backed types (RTF, image, files) are staged into `BlobStorage` first, then committed and linked to the row's `content` column (a relative path) only after the DB insert succeeds — `insertBlobBacked` rolls back the staged blob if the second write fails, so a partial insert never leaves an orphaned file.

`PasteboardMonitor.performSelfWrite`/`suppressCurrentChange` let the app write to the pasteboard (restoring a clip, bulk paste, quick paste) without the monitor re-capturing its own write as new history.

### Storage layer

`AppDatabase` owns a single GRDB `DatabasePool` and a `DatabaseMigrator` (schema changes go here as new `registerMigration` steps — never edit an existing migration). `ClipRepository` is the only place that touches SQL/GRDB query-builder code; it exposes fetch/insert/pin/delete operations plus `historyObservation`/`observeHistory`, a `ValueObservation` that both the cursor panel and the Saved panel subscribe to through one shared `HistoryViewModel` instance, keeping both windows in sync from a single DB observation. Ordering is always `createdAt DESC, id DESC` (`historyOrdering`); pinning/bumping/marking-used all work by rewriting `createdAt` rather than a separate sort key.

`BlobStorage` manages on-disk blob files (RTF/image/file drops) referenced by relative path from `ClipRecord.content`. `RetentionService`/`RetentionScheduler` periodically purge old unpinned clips (and their blobs) based on age and a max-unpinned-count cap (`fetchRetentionCandidates`).

### UI shell

`StatusItemController` owns the menu-bar item and two borderless `NSPanel`s: the "cursor panel" (`CursorHistoryPanel`, appears at the pointer, hosts `HistoryView`) and the Saved-clips panel (`SavedClipsPanelController`, hosts `SavedClipsView`), plus an image-preview panel. All three read from the same `HistoryViewModel`. Panel geometry (size, anchoring relative to pointer/screen edges, the scroll-bar/bulk-paste-rail insets) is computed with static geometry helpers on `StatusItemController` (`cursorPanelFrame`, `cursorPanelSurfaceFrame`) rather than SwiftUI layout, and persisted across launches via `UserDefaults` with a layout-version migration guard (`cursorPanelLayoutVersion`).

`CursorHistoryPanel` overrides `sendEvent` to intercept number-key quick-paste shortcuts (`QuickPasteShortcut`) at the window dispatch level, because SwiftUI's search field can otherwise swallow key events before they reach normal responder-chain handling.

### Paste-back automation

Restoring a clip copies it to the pasteboard, then the optional, default-enabled Assistive Paste feature lets people complete the workflow using only a pointing device by pasting into the app that was frontmost before the panel opened. Permission state comes from `AXIsProcessTrusted`, matching the toggle shown in System Settings; only an explicit onboarding, Settings, or contextual permission action calls `CGRequestPostEventAccess`, and System Settings opens only when the user chooses that action in the macOS permission dialog. The app does not use Accessibility elements, inspect another app's UI, or read keyboard input. Authorized paste posts an explicit Command-down, V-down/up, Command-up sequence at the HID event tap. If Assistive Paste is disabled or permission is missing, the clip remains copied for manual paste. Permission UI polls once per second and normal background polling remains infrequent.

### Global hotkey

`GlobalHotKeyController` uses the Carbon `RegisterEventHotKey` API directly (no third-party hotkey library); default shortcut is Shift-Command-V.

## Testing conventions

Tests live in `PasteListTests/` and are largely organized one file per major component (`ClipRepositoryTests`, `PasteboardMonitorTests`, `BulkPasteTests`, `ClipRestorerTests`, `RetentionServiceTests`, `BlobStorageTests`, `ClipboardParserTests`, `HistoryViewModelTests`, `AppReviewRequestControllerTests`). Components that touch the pasteboard, filesystem, or system permissions take their dependencies as injectable closures/protocols (e.g. `PasteAutomationController`'s `frontmostApplication`, `postCommandV`, `permissionClient`; `PasteboardMonitor`'s `pasteboard`/`sourceBundleIDProvider`) specifically so tests can fake them — follow this pattern for new system-facing code rather than reaching for real `NSPasteboard`/`NSWorkspace` state in tests.
