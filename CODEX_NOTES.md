# Working notes — 2026-08-20

## Repository state examined

- Branch: `main`
- `HEAD`: `f59c4dd` (`Update 2 files`)
- `main` matches `origin/main`.
- The working tree was clean when this note was written; there were no staged or unstaged changes to review.

## Change set reviewed

The only changes since the prior release-preparation commit `756b2fb`
(`Bump build number to 6 for 1.1.2 App Store submission`) are the two files
in `f59c4dd`.

### `PasteList/Support/PasteAutomationController.swift`

`verifyPostEventDelivery(using:)` probes Accessibility / event-posting access
by creating no-op mouse-move and scroll-wheel events. The mouse-move event now
uses the current pointer position obtained from a `CGEvent`:

```swift
let currentCursorPosition = CGEvent(source: nil)?.location ?? .zero
```

This replaces `NSEvent.mouseLocation`. The important distinction is coordinate
space: `CGEvent` takes CoreGraphics global coordinates (top-left origin), while
the AppKit mouse location uses a bottom-left origin. Passing the AppKit value to
`CGEvent` could send the probe mouse event to a mirrored/incorrect point and
visibly warp the cursor, especially with multiple displays. The new value stays
in one coordinate system. If the cursor position cannot be read, the probe uses
`.zero`; that preserves the permission check but may still generate its harmless
mouse-move event at the global origin.

### `PasteList.xcodeproj/project.pbxproj`

- Debug and Release target configurations now use `ARCHS = $(ARCHS_STANDARD)`
  instead of forcing `arm64`. This allows the standard architectures selected by
  Xcode for the active SDK, rather than excluding Intel builds by project
  configuration.
- The Debug app product reference is renamed from `PasteList.app` to
  `PasteDebug.app`, matching the existing Debug `PRODUCT_NAME = PasteDebug`.
  Release remains `PasteList.app` / `PRODUCT_NAME = PasteList`.
- `PasteFallbackPanelController.swift` and the feature-tip file references were
  reordered within the project file. Their identifiers and source membership are
  retained; this is project-file organization, not a functional source change.

## Intended outcome

1. The Accessibility delivery probe should no longer move the real pointer to a
   coordinate derived from the wrong coordinate system.
2. Debug and installed Release builds are distinguishable by product name,
   reducing the chance of opening or granting permissions to the wrong build.
3. The project can use Xcode's standard architecture selection.

## Verification still worth doing

- Build the `PasteList` scheme for Debug and Release on the supported Macs.
- On a multi-monitor Mac, grant Accessibility, open the app, and invoke the
  automatic-paste permission flow; confirm the cursor does not jump and a paste
  reaches the previously active app.
- Confirm the Debug product is `PasteDebug.app` and the packaged Release product
  remains `PasteList.app`.

No build or runtime verification was run for this documentation-only review.

## Accessibility implementation update — 2026-08-20

The original delivery probe above was replaced with the dedicated public
PostEvent preflight and request APIs. PasteList retains an explicit,
first-launch Assistive Paste permission step:

- Debug uses `com.kam.pastelist.debug`; Release remains `com.kam.pastelist`.
- The first onboarding page explicitly requests PostEvent access and polls the
  visible permission state once per second.
- Authorization status uses `AXIsProcessTrusted`, matching the Accessibility
  toggle shown by System Settings. The mouse/scroll delivery probe remains removed.
- Missing permission returns a distinct result, keeps the clip copied, and shows
  a contextual permission panel. Focus/posting failures show the manual ⌘V
  fallback instead.
- Assistive Paste sends Command down, V down/up, and Command up at the HID tap.
- Debug tests are hosted by `PasteDebug.app`, fixing the stale `TEST_HOST` path.
- Debug reset operations use the runtime bundle identifier and cannot reset the
  installed Release/TestFlight app.

Verification performed after the change:

- Debug application and test bundle compiled successfully.
- The full test run succeeded, including the new permission, refresh-surface,
  fallback, bundle-identity, and automatic-paste tests. One existing AppPaths
  assertion was updated to validate the active configuration identifier.
- Release built as `PasteList.app` with executable `PasteList` and bundle
  identifier `com.kam.pastelist`.

The remaining required manual check is the clean-TCC onboarding flow for the new
`PasteDebug` identity: grant the listed PasteDebug row, confirm the onboarding
advances, and paste into a previously focused text field.
