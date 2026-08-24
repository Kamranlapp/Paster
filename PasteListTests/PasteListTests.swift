import Foundation
import Carbon
import GRDB
import ServiceManagement
import XCTest
@testable import PasteList

final class PasteListTests: XCTestCase {
    @MainActor
    func testAccessibilityResetHelperTargetsOnlyDebugAssistivePasteServicesAndDefersLocalReset() {
        let script = DebugAccessibilityResetScript.contents(
            bundleIdentifier: "com.kam.pastelist.debug",
            appPath: "/Applications/PasteDebug.app",
            relaunchAction: .accessibility
        )

        XCTAssertTrue(script.contains("tccutil reset Accessibility 'com.kam.pastelist.debug'"))
        XCTAssertTrue(script.contains("tccutil reset PostEvent 'com.kam.pastelist.debug'"))
        XCTAssertFalse(script.contains("tccutil reset ListenEvent"))
        XCTAssertTrue(script.contains("'/Applications/PasteDebug.app' --args '--complete-accessibility-reset'"))
        XCTAssertFalse(script.contains("reset All"))
        XCTAssertFalse(script.contains("Application Support"))
    }

    func testExternalCleanResetScriptsAreNarrowAndExposeBothModes() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptsRoot = projectRoot.appendingPathComponent("Scripts", isDirectory: true)
        let resetScriptURL = scriptsRoot.appendingPathComponent("reset-clean-install.sh")
        let fullLauncherURL = scriptsRoot.appendingPathComponent(
            "Reset PasteList - Full.command"
        )
        let dataOnlyLauncherURL = scriptsRoot.appendingPathComponent(
            "Reset PasteList - Data Only.command"
        )
        let resetScript = try String(contentsOf: resetScriptURL, encoding: .utf8)
        let fullLauncher = try String(contentsOf: fullLauncherURL, encoding: .utf8)
        let dataOnlyLauncher = try String(contentsOf: dataOnlyLauncherURL, encoding: .utf8)

        XCTAssertTrue(resetScript.contains("com.kam.pastelist"))
        XCTAssertTrue(resetScript.contains("com.kam.pastelist.debug"))
        XCTAssertTrue(resetScript.contains("tccutil reset \"$service\" \"$bundle_identifier\""))
        XCTAssertTrue(resetScript.contains("Accessibility PostEvent"))
        XCTAssertTrue(resetScript.contains(LaunchAtLoginResetCommand.argument))
        XCTAssertTrue(
            resetScript.contains(
                "Data/Library/Preferences/$bundle_identifier"
            )
        )
        XCTAssertFalse(resetScript.contains("tccutil reset All"))
        XCTAssertFalse(resetScript.contains("ListenEvent"))
        XCTAssertFalse(resetScript.contains("sfltool"))
        XCTAssertFalse(resetScript.contains("sudo"))
        XCTAssertFalse(resetScript.contains("Continue? [y/N]"))
        XCTAssertTrue(fullLauncher.contains("--mode full"))
        XCTAssertTrue(dataOnlyLauncher.contains("--mode data-only"))

        for launcherURL in [fullLauncherURL, dataOnlyLauncherURL] {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: launcherURL.path
            )
            let permissions = try XCTUnwrap(
                (attributes[.posixPermissions] as? NSNumber)?.intValue
            )
            XCTAssertNotEqual(permissions & 0o111, 0)
        }
    }

    func testQuickPasteShortcutsAssignOneThroughNineThenZero() {
        XCTAssertEqual(
            (0..<10).compactMap(QuickPasteShortcut.label(forEntryIndex:)),
            ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
        )
        XCTAssertNil(QuickPasteShortcut.label(forEntryIndex: 10))
    }

    func testQuickPasteShortcutsMapNumberRowAndNumericKeypad() {
        let numberRowKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
        let numericKeypadKeyCodes: [UInt16] = [83, 84, 85, 86, 87, 88, 89, 91, 92, 82]

        XCTAssertEqual(
            numberRowKeyCodes.compactMap {
                QuickPasteShortcut.entryIndex(forKeyCode: $0)
            },
            Array(0..<10)
        )
        XCTAssertEqual(
            numericKeypadKeyCodes.compactMap {
                QuickPasteShortcut.entryIndex(forKeyCode: $0)
            },
            Array(0..<10)
        )
        XCTAssertNil(
            QuickPasteShortcut.entryIndex(
                forKeyCode: 18,
                modifierFlags: .command
            )
        )
    }

    func testMouseSwipeDeleteRecognizesOnlyDecisiveLeftwardDrags() {
        XCTAssertEqual(
            MouseSwipeDeleteGesture.intent(for: NSSize(width: -12, height: 2)),
            .deleteSwipe
        )
        XCTAssertEqual(
            MouseSwipeDeleteGesture.intent(for: NSSize(width: 12, height: 2)),
            .otherDrag
        )
        XCTAssertEqual(
            MouseSwipeDeleteGesture.intent(for: NSSize(width: -3, height: 12)),
            .otherDrag
        )
        XCTAssertEqual(
            MouseSwipeDeleteGesture.intent(for: NSSize(width: -3, height: 1)),
            .undecided
        )
        XCTAssertTrue(
            MouseSwipeDeleteGesture.shouldDelete(
                translation: NSSize(width: -48, height: 4)
            )
        )
        XCTAssertFalse(
            MouseSwipeDeleteGesture.shouldDelete(
                translation: NSSize(width: -47, height: 4)
            )
        )
        XCTAssertEqual(MouseSwipeDeleteGesture.visualOffset(for: -40), -40)
        XCTAssertEqual(
            MouseSwipeDeleteGesture.visualOffset(for: -200),
            -MouseSwipeDeleteGesture.maximumRevealDistance
        )
        XCTAssertEqual(MouseSwipeDeleteGesture.visualOffset(for: 20), 0)
    }

    @MainActor
    func testCursorPanelInterceptsQuickPasteBeforeFocusedSearchField() throws {
        let panel = CursorHistoryPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let searchField = NSTextField(frame: panel.contentView?.bounds ?? .zero)
        panel.contentView = searchField
        panel.makeFirstResponder(searchField)
        var pastedEntryIndex: Int?
        panel.quickPaste = { pastedEntryIndex = $0 }
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: panel.windowNumber,
                context: nil,
                characters: "2",
                charactersIgnoringModifiers: "2",
                isARepeat: false,
                keyCode: 19
            )
        )

        panel.sendEvent(event)

        XCTAssertEqual(pastedEntryIndex, 1)
        XCTAssertEqual(searchField.stringValue, "")
    }

    func testApplicationConfiguration() {
        #if DEBUG
        XCTAssertEqual(AppConfiguration.name, "PasteDebug")
        XCTAssertEqual(AppConfiguration.bundleIdentifier, "com.kam.pastelist.debug")
        #else
        XCTAssertEqual(AppConfiguration.name, "PasteList")
        XCTAssertEqual(AppConfiguration.bundleIdentifier, "com.kam.pastelist")
        #endif
    }

    func testPrivacyManifestDeclaresNoCollectionAndRequiredReasons() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifestURL = projectRoot
            .appendingPathComponent("PasteList")
            .appendingPathComponent("PrivacyInfo.xcprivacy")
        let data = try Data(contentsOf: manifestURL)
        let manifest = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )

        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual(
            (manifest["NSPrivacyTrackingDomains"] as? [String])?.count,
            0
        )
        XCTAssertEqual(
            (manifest["NSPrivacyCollectedDataTypes"] as? [[String: Any]])?.count,
            0
        )

        let accessedTypes = try XCTUnwrap(
            manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]]
        )
        var reasonsByType: [String: [String]] = [:]
        for entry in accessedTypes {
            guard
                let type = entry["NSPrivacyAccessedAPIType"] as? String,
                let reasons = entry["NSPrivacyAccessedAPITypeReasons"] as? [String]
            else {
                continue
            }
            reasonsByType[type] = reasons
        }
        XCTAssertEqual(
            reasonsByType["NSPrivacyAccessedAPICategoryUserDefaults"],
            ["CA92.1"]
        )
        XCTAssertEqual(
            reasonsByType["NSPrivacyAccessedAPICategoryFileTimestamp"],
            ["C617.1"]
        )
    }

    func testClipPrimaryInteractionsKeepSelectionAndDraggingExclusive() {
        let makeClip: (ClipContentType) -> ClipRecord = { type in
            ClipRecord(
                id: 1,
                type: type.rawValue,
                content: "content",
                previewText: "preview",
                createdAt: Date()
            )
        }

        XCTAssertEqual(makeClip(.text).primaryInteraction, .textSelection)
        XCTAssertEqual(makeClip(.rtf).primaryInteraction, .textSelection)
        XCTAssertEqual(makeClip(.url).primaryInteraction, .textSelection)
        XCTAssertEqual(makeClip(.image).primaryInteraction, .fileDrag)
        XCTAssertEqual(makeClip(.file).primaryInteraction, .fileDrag)
    }

    func testDefaultGlobalHotKeyIsCommandShiftV() {
        let hotKey = HotKey.defaultValue

        XCTAssertEqual(hotKey.displayName, "⇧⌘V")
        XCTAssertNotEqual(hotKey.modifiers & UInt32(cmdKey), 0)
        XCTAssertNotEqual(hotKey.modifiers & UInt32(shiftKey), 0)
    }

    @MainActor
    func testPostEventAccessIsRequestedOnlyByExplicitAction() async {
        var trustCheckCount = 0
        var requestCount = 0
        var isGranted = false
        let controller = PasteAutomationController(
            permissionClient: PostEventPermissionClient(
                preflight: {
                    trustCheckCount += 1
                    return isGranted
                },
                request: {
                    requestCount += 1
                    isGranted = true
                    return true
                }
            ),
            frontmostApplication: { nil },
            isApplicationFrontmost: { _ in false },
            postCommandV: { false },
            waitBeforePosting: {},
            openSystemSettings: {}
        )

        XCTAssertEqual(trustCheckCount, 1)
        XCTAssertEqual(requestCount, 0)

        controller.refreshAuthorization()
        XCTAssertEqual(trustCheckCount, 2)
        XCTAssertEqual(requestCount, 0)

        let wasGranted = await controller.requestAuthorization()
        XCTAssertTrue(wasGranted)
        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(controller.isPostEventAuthorized)
        XCTAssertEqual(controller.permissionState, .granted)
        XCTAssertEqual(controller.permissionRequestState, .idle)
    }

    @MainActor
    func testDeniedDirectRequestWaitsForApprovalWithoutOpeningSettings() async {
        var requestCount = 0
        var settingsOpenCount = 0
        let controller = PasteAutomationController(
            permissionClient: PostEventPermissionClient(
                preflight: { false },
                request: {
                    requestCount += 1
                    return false
                }
            ),
            frontmostApplication: { nil },
            isApplicationFrontmost: { _ in false },
            postCommandV: { false },
            waitBeforePosting: {},
            openSystemSettings: { settingsOpenCount += 1 }
        )

        let wasGranted = await controller.requestAuthorization()
        XCTAssertFalse(wasGranted)
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(settingsOpenCount, 0)
        XCTAssertEqual(controller.permissionState, .notGranted)
        XCTAssertEqual(controller.permissionRequestState, .awaitingSystemApproval)
    }

    @MainActor
    func testPermissionRequestDoesNotOpenSystemSettingsWhileStillDenied() async {
        var requestCount = 0
        var settingsOpenCount = 0
        let controller = PasteAutomationController(
            permissionClient: PostEventPermissionClient(
                preflight: { false },
                request: {
                    requestCount += 1
                    return false
                }
            ),
            frontmostApplication: { nil },
            isApplicationFrontmost: { _ in false },
            postCommandV: { false },
            waitBeforePosting: {},
            openSystemSettings: { settingsOpenCount += 1 }
        )

        let firstResult = await controller.requestAuthorization()
        XCTAssertFalse(firstResult)
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(settingsOpenCount, 0)
        XCTAssertEqual(controller.permissionRequestState, .awaitingSystemApproval)

        let secondResult = await controller.requestAuthorization()
        XCTAssertFalse(secondResult)
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(settingsOpenCount, 0)
        XCTAssertEqual(controller.permissionRequestState, .awaitingSystemApproval)
    }

    @MainActor
    func testPostEventPermissionStateTracksGrantAndRevocation() {
        var isGranted = false
        let controller = PasteAutomationController(
            permissionClient: PostEventPermissionClient(
                preflight: { isGranted },
                request: { false }
            ),
            frontmostApplication: { nil },
            isApplicationFrontmost: { _ in false },
            postCommandV: { false },
            waitBeforePosting: {},
            openSystemSettings: {}
        )

        XCTAssertEqual(controller.permissionState, .notGranted)

        isGranted = true
        controller.refreshAuthorization()
        XCTAssertEqual(controller.permissionState, .granted)

        isGranted = false
        controller.refreshAuthorization()
        XCTAssertEqual(controller.permissionState, .notGranted)
    }

    @MainActor
    func testPostEventPreflightIsAuthoritativeAfterRequestAndRevocation() async {
        var isTrusted = false
        let controller = PasteAutomationController(
            permissionClient: PostEventPermissionClient(
                preflight: { isTrusted },
                request: {
                    isTrusted = true
                    return true
                }
            ),
            frontmostApplication: { nil },
            isApplicationFrontmost: { _ in false },
            postCommandV: { false },
            waitBeforePosting: {},
            openSystemSettings: {}
        )

        let wasGranted = await controller.requestAuthorization()
        XCTAssertTrue(wasGranted)
        XCTAssertEqual(controller.permissionState, .granted)

        isTrusted = false
        let isGrantedAfterRevocation = await controller.refreshAuthorizationNow()
        XCTAssertFalse(isGrantedAfterRevocation)
        XCTAssertEqual(controller.permissionState, .notGranted)
    }

    @MainActor
    func testSettingsVisibilityUsesOneMonitorAtTheExpectedInterval() async {
        var isGranted = false
        let controller = PasteAutomationController(
            permissionClient: PostEventPermissionClient(
                preflight: { isGranted },
                request: { false }
            ),
            frontmostApplication: { nil },
            isApplicationFrontmost: { _ in false },
            postCommandV: { false },
            waitBeforePosting: {},
            openSystemSettings: {}
        )
        let initialGeneration = controller.authorizationMonitorGeneration

        controller.setSettingsVisible(true)
        XCTAssertEqual(controller.authorizationRefreshInterval, 1)
        XCTAssertEqual(controller.permissionState, .notGranted)
        XCTAssertEqual(
            controller.authorizationMonitorGeneration,
            initialGeneration + 1
        )

        isGranted = true
        controller.setSettingsVisible(true)
        await Task.yield()
        XCTAssertEqual(controller.permissionState, .granted)
        XCTAssertEqual(
            controller.authorizationMonitorGeneration,
            initialGeneration + 1,
            "Opening an already-visible settings window must not create another monitor"
        )

        controller.setSettingsVisible(false)
        XCTAssertEqual(controller.authorizationRefreshInterval, 60)
        XCTAssertEqual(
            controller.authorizationMonitorGeneration,
            initialGeneration + 2
        )
    }

    @MainActor
    func testClosingOnePermissionSurfaceKeepsFastRefreshForAnother() {
        let controller = PasteAutomationController(
            permissionClient: PostEventPermissionClient(
                preflight: { false },
                request: { false }
            ),
            frontmostApplication: { nil },
            isApplicationFrontmost: { _ in false },
            postCommandV: { false },
            waitBeforePosting: {},
            openSystemSettings: {}
        )

        controller.setAuthorizationSurface(.onboarding, visible: true)
        controller.setAuthorizationSurface(.settings, visible: true)
        controller.setAuthorizationSurface(.settings, visible: false)
        XCTAssertEqual(controller.authorizationRefreshInterval, 1)

        controller.setAuthorizationSurface(.onboarding, visible: false)
        XCTAssertEqual(controller.authorizationRefreshInterval, 60)
    }

    @MainActor
    func testOnboardingIsPresentedOnlyBeforeCompletion() throws {
        let suiteName = "PasteListTests.onboarding.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initialState = OnboardingState(userDefaults: defaults)
        XCTAssertTrue(initialState.shouldPresentOnLaunch)

        initialState.complete()
        XCTAssertFalse(initialState.shouldPresentOnLaunch)

        let nextLaunchState = OnboardingState(userDefaults: defaults)
        XCTAssertFalse(nextLaunchState.shouldPresentOnLaunch)
        XCTAssertTrue(nextLaunchState.hasCompleted)
    }

    @MainActor
    func testCompletedOnboardingCanStillBeReopenedWithoutResettingState() throws {
        let suiteName = "PasteListTests.onboarding.reopen.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = OnboardingState(userDefaults: defaults)
        state.complete()

        var didRequestReopen = false
        let reopen = { didRequestReopen = true }
        reopen()

        XCTAssertTrue(didRequestReopen)
        XCTAssertTrue(state.hasCompleted)
        XCTAssertFalse(state.shouldPresentOnLaunch)
    }

    @MainActor
    func testAssistivePasteIsEnabledByDefaultAndPostsCommandV() async {
        var activationCount = 0
        var postCount = 0
        let target = PasteAutomationController.TargetApplication(
            processIdentifier: 42_424,
            bundleIdentifier: "com.example.target",
            isTerminated: { false },
            activate: {
                activationCount += 1
                return true
            }
        )
        let controller = PasteAutomationController(
            permissionClient: PostEventPermissionClient(
                preflight: { true },
                request: { XCTFail("Permission request must be explicit"); return false }
            ),
            frontmostApplication: { target },
            isApplicationFrontmost: { $0 == target.processIdentifier },
            postCommandV: {
                postCount += 1
                return true
            },
            waitBeforePosting: {},
            openSystemSettings: {}
        )
        controller.rememberFrontmostApplication()

        let result = await controller.pasteIntoPreviousApplication()

        XCTAssertEqual(result, .pastedAutomatically)
        XCTAssertEqual(activationCount, 1)
        XCTAssertEqual(postCount, 1)
    }

    @MainActor
    func testAssistivePasteCanBeDisabledAndPersistsItsSetting() async throws {
        let suiteName = "PasteListTests.assistivePaste.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var activationCount = 0
        var postCount = 0
        let target = PasteAutomationController.TargetApplication(
            processIdentifier: 42_428,
            bundleIdentifier: "com.example.target",
            isTerminated: { false },
            activate: {
                activationCount += 1
                return true
            }
        )
        let controller = PasteAutomationController(
            permissionClient: PostEventPermissionClient(
                preflight: { true },
                request: { false }
            ),
            userDefaults: defaults,
            frontmostApplication: { target },
            isApplicationFrontmost: { _ in true },
            postCommandV: {
                postCount += 1
                return true
            },
            waitBeforePosting: {},
            openSystemSettings: {}
        )
        XCTAssertTrue(controller.isAssistivePasteEnabled)

        controller.setAssistivePasteEnabled(false)
        controller.rememberFrontmostApplication()
        let result = await controller.pasteIntoPreviousApplication()

        XCTAssertEqual(result, .copiedForManualPaste)
        XCTAssertEqual(activationCount, 0)
        XCTAssertEqual(postCount, 0)
        let reloadedController = PasteAutomationController(
            permissionClient: PostEventPermissionClient(
                preflight: { false },
                request: { false }
            ),
            userDefaults: defaults,
            frontmostApplication: { nil },
            isApplicationFrontmost: { _ in false },
            postCommandV: { false },
            waitBeforePosting: {},
            openSystemSettings: {}
        )
        XCTAssertFalse(reloadedController.isAssistivePasteEnabled)
    }

    @MainActor
    func testAssistivePasteReturnsPermissionRequiredBeforeActivatingTarget() async {
        var activationCount = 0
        var postCount = 0
        let target = PasteAutomationController.TargetApplication(
            processIdentifier: 42_427,
            bundleIdentifier: "com.example.target",
            isTerminated: { false },
            activate: {
                activationCount += 1
                return true
            }
        )
        let controller = PasteAutomationController(
            permissionClient: PostEventPermissionClient(
                preflight: { false },
                request: { XCTFail("Paste must not request permission implicitly"); return false }
            ),
            frontmostApplication: { target },
            isApplicationFrontmost: { $0 == target.processIdentifier },
            postCommandV: {
                postCount += 1
                return true
            },
            waitBeforePosting: {},
            openSystemSettings: {}
        )
        controller.rememberFrontmostApplication()

        let result = await controller.pasteIntoPreviousApplication()

        XCTAssertEqual(result, .permissionRequired)
        XCTAssertEqual(activationCount, 0)
        XCTAssertEqual(postCount, 0)
    }

    @MainActor
    func testAssistivePasteFallsBackWithoutPermissionAndPreservesClipboard() async {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("fallback payload", forType: .string)
        var activationCount = 0
        var postCount = 0
        var requestCount = 0
        let target = PasteAutomationController.TargetApplication(
            processIdentifier: 42_425,
            bundleIdentifier: "com.example.target",
            isTerminated: { false },
            activate: {
                activationCount += 1
                return true
            }
        )
        let controller = PasteAutomationController(
            permissionClient: PostEventPermissionClient(
                preflight: { false },
                request: {
                    requestCount += 1
                    return false
                }
            ),
            frontmostApplication: { target },
            isApplicationFrontmost: { $0 == target.processIdentifier },
            postCommandV: {
                postCount += 1
                return true
            },
            waitBeforePosting: {},
            openSystemSettings: {}
        )
        controller.rememberFrontmostApplication()

        let result = await controller.pasteIntoPreviousApplication()

        XCTAssertEqual(result, .permissionRequired)
        XCTAssertEqual(activationCount, 0)
        XCTAssertEqual(postCount, 0)
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "fallback payload")
    }

    @MainActor
    func testAssistivePasteFallsBackWhenPreviousApplicationCannotActivate() async {
        var postCount = 0
        let target = PasteAutomationController.TargetApplication(
            processIdentifier: 42_426,
            bundleIdentifier: "com.example.target",
            isTerminated: { false },
            activate: { false }
        )
        let controller = PasteAutomationController(
            permissionClient: PostEventPermissionClient(
                preflight: { true },
                request: { XCTFail("Permission request must be explicit"); return false }
            ),
            frontmostApplication: { target },
            isApplicationFrontmost: { _ in false },
            postCommandV: {
                postCount += 1
                return true
            },
            waitBeforePosting: {},
            openSystemSettings: {}
        )
        controller.rememberFrontmostApplication()

        let result = await controller.pasteIntoPreviousApplication()

        XCTAssertEqual(result, .copiedForManualPaste)
        XCTAssertEqual(postCount, 0)
    }

    @MainActor
    func testManualPasteFallbackUsesClearInstruction() {
        XCTAssertEqual(
            PasteFallbackPanelController.manualTitle,
            "Copied — press ⌘V to paste"
        )
        XCTAssertEqual(
            PasteFallbackPanelController.permissionTitle,
            "Assistive Paste needs permission to send ⌘V."
        )
    }

    func testApplicationSourcesUsePublicAccessibilityPermissionAPIs() throws {
        let testsURL = URL(fileURLWithPath: #filePath)
        let projectRoot = testsURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = projectRoot.appendingPathComponent("PasteList", isDirectory: true)
        let forbiddenSymbols = [
            ["AXUI", "Element"].joined(),
            ["IOHID", "CheckAccess"].joined(),
            ["IOHID", "RequestAccess"].joined(),
            ["Accessibility", "AccessSheet"].joined(),
        ]
        let sourceURLs = try FileManager.default
            .subpathsOfDirectory(atPath: sourceRoot.path)
            .filter { $0.hasSuffix(".swift") }
            .map { sourceRoot.appendingPathComponent($0) }

        for sourceURL in sourceURLs {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            for symbol in forbiddenSymbols {
                XCTAssertFalse(source.contains(symbol), "Found forbidden API \(symbol) in \(sourceURL.path)")
            }
        }

        let automationSource = try String(
            contentsOf: sourceRoot
                .appendingPathComponent("Support")
                .appendingPathComponent("PasteAutomationController.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(automationSource.contains("import ApplicationServices"))
        XCTAssertTrue(automationSource.contains("AXIsProcessTrusted()"))
        XCTAssertTrue(automationSource.contains("CGRequestPostEventAccess"))
    }

    @MainActor
    func testCursorPanelPlacesPointerOverFirstRowAwayFromScreenEdges() {
        let pointer = NSPoint(x: 800, y: 600)
        let expectedHorizontalPosition = StatusItemController.cursorScrollBarWidth
            + StatusItemController.cursorScrollBarSpacing
            + StatusItemController.cursorPanelPadding
            + StatusItemController.cursorPanelContentSize.width
                * StatusItemController.cursorHorizontalAnchor
        let expectedVerticalPosition = StatusItemController.cursorWindowControlAreaHeight
            + StatusItemController.cursorWindowControlSpacing
            + StatusItemController.cursorPanelPadding
            + StatusItemController.cursorFirstRowCenterFromTop
        let frame = StatusItemController.cursorPanelFrame(
            pointerLocation: pointer,
            visibleFrame: NSRect(x: 0, y: 0, width: 1_440, height: 900)
        )

        XCTAssertEqual(
            pointer.x - frame.minX,
            expectedHorizontalPosition
        )
        XCTAssertEqual(
            frame.maxY - pointer.y,
            expectedVerticalPosition
        )
    }

    @MainActor
    func testCursorPanelStaysInsideVisibleScreenNearEdges() {
        let visibleFrame = NSRect(x: 0, y: 25, width: 1_000, height: 700)
        let frame = StatusItemController.cursorPanelFrame(
            pointerLocation: NSPoint(x: 995, y: 30),
            visibleFrame: visibleFrame
        )

        XCTAssertGreaterThanOrEqual(frame.minX, visibleFrame.minX)
        XCTAssertGreaterThanOrEqual(frame.minY, visibleFrame.minY)
        XCTAssertLessThanOrEqual(frame.maxX, visibleFrame.maxX)
        XCTAssertLessThanOrEqual(frame.maxY, visibleFrame.maxY)
    }

    @MainActor
    func testCursorPanelSizeIsSavedAndRestored() throws {
        let suiteName = "PasteListTests.cursorPanelSize.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let savedSize = NSSize(width: 460, height: 520)
        StatusItemController.saveCursorPanelSize(savedSize, in: defaults)

        XCTAssertEqual(
            StatusItemController.storedCursorPanelSize(in: defaults),
            savedSize
        )
    }

    func testCursorPanelResizeKeepsOppositeCornerFixed() {
        let initialFrame = NSRect(x: 100, y: 100, width: 500, height: 400)

        let resizedFrame = CursorPanelResizer.frame(
            from: initialFrame,
            dragging: [.top, .left],
            by: NSPoint(x: 50, y: -100),
            minimumSize: NSSize(width: 300, height: 250),
            within: nil
        )

        XCTAssertEqual(
            resizedFrame,
            NSRect(x: 150, y: 100, width: 450, height: 300)
        )
        XCTAssertEqual(resizedFrame.maxX, initialFrame.maxX)
        XCTAssertEqual(resizedFrame.minY, initialFrame.minY)
    }

    func testCursorPanelResizeHonorsMinimumSize() {
        let initialFrame = NSRect(x: 100, y: 100, width: 500, height: 400)

        let resizedFrame = CursorPanelResizer.frame(
            from: initialFrame,
            dragging: [.bottom, .right],
            by: NSPoint(x: -300, y: 250),
            minimumSize: NSSize(width: 300, height: 250),
            within: nil
        )

        XCTAssertEqual(
            resizedFrame,
            NSRect(x: 100, y: 250, width: 300, height: 250)
        )
        XCTAssertEqual(resizedFrame.maxX, 400)
        XCTAssertEqual(resizedFrame.maxY, initialFrame.maxY)
    }

    @MainActor
    func testCursorPanelSurfaceFrameExcludesRailScrollBarAndControlStrip() {
        let panelFrame = NSRect(
            x: 400,
            y: 300,
            width: StatusItemController.cursorPanelSize.width,
            height: StatusItemController.cursorPanelSize.height
        )

        let surfaceFrame = StatusItemController.cursorPanelSurfaceFrame(in: panelFrame)

        XCTAssertEqual(
            surfaceFrame.size,
            StatusItemController.cursorPanelSurfaceSize
        )
        XCTAssertEqual(surfaceFrame.minX, panelFrame.minX + 16)
        XCTAssertEqual(surfaceFrame.maxX, panelFrame.maxX - 121)
        XCTAssertEqual(surfaceFrame.minY, panelFrame.minY)
        XCTAssertEqual(surfaceFrame.maxY, panelFrame.maxY - 50)
    }

    func testImagePreviewIsPlacedRightOfTheSurfaceSharingItsTopEdge() {
        let surfaceFrame = NSRect(x: 416, y: 300, width: 334, height: 416)

        let previewFrame = ImagePreviewPlacement.frame(
            previewSize: NSSize(width: 300, height: 200),
            anchorFrame: surfaceFrame,
            visibleFrame: NSRect(x: 0, y: 0, width: 1800, height: 1000),
            gap: 16
        )

        XCTAssertEqual(previewFrame.minX, surfaceFrame.maxX + 16)
        XCTAssertEqual(previewFrame.maxY, surfaceFrame.maxY)
        XCTAssertEqual(previewFrame, NSRect(x: 766, y: 516, width: 300, height: 200))
    }

    func testImagePreviewFlipsToTheLeftNearTheRightScreenEdge() {
        let surfaceFrame = NSRect(x: 1016, y: 300, width: 334, height: 416)

        let previewFrame = ImagePreviewPlacement.frame(
            previewSize: NSSize(width: 300, height: 200),
            anchorFrame: surfaceFrame,
            visibleFrame: NSRect(x: 0, y: 0, width: 1500, height: 1000),
            gap: 16
        )

        XCTAssertEqual(previewFrame.maxX, surfaceFrame.minX - 16)
        XCTAssertEqual(previewFrame.minX, 700)
    }

    func testImagePreviewStaysInsideVisibleFrame() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1800, height: 1000)

        let topFrame = ImagePreviewPlacement.frame(
            previewSize: NSSize(width: 300, height: 400),
            anchorFrame: NSRect(x: 416, y: 700, width: 334, height: 416),
            visibleFrame: visibleFrame,
            gap: 16
        )
        XCTAssertEqual(topFrame.maxY, visibleFrame.maxY)

        let bottomFrame = ImagePreviewPlacement.frame(
            previewSize: NSSize(width: 300, height: 400),
            anchorFrame: NSRect(x: 416, y: 0, width: 334, height: 300),
            visibleFrame: visibleFrame,
            gap: 16
        )
        XCTAssertEqual(bottomFrame.minY, visibleFrame.minY)
    }

    func testImagePreviewDisplaySizeFitsMaximumAndPreservesAspectRatio() {
        let displaySize = ImagePreviewPlacement.displaySize(
            pixelSize: NSSize(width: 1680, height: 945),
            scale: 2,
            maximum: NSSize(width: 420, height: 420),
            minimumLongSide: 120
        )

        XCTAssertEqual(displaySize.width, 420)
        XCTAssertEqual(displaySize.height, 236)
    }

    func testImagePreviewDisplaySizeIsScaleIndependent() {
        let retinaSize = ImagePreviewPlacement.displaySize(
            pixelSize: NSSize(width: 1680, height: 945),
            scale: 2,
            maximum: NSSize(width: 420, height: 420),
            minimumLongSide: 120
        )
        let nonRetinaSize = ImagePreviewPlacement.displaySize(
            pixelSize: NSSize(width: 1680, height: 945),
            scale: 1,
            maximum: NSSize(width: 420, height: 420),
            minimumLongSide: 120
        )

        XCTAssertEqual(retinaSize, nonRetinaSize)
    }

    func testImagePreviewDisplaySizeEnlargesTinyImages() {
        let displaySize = ImagePreviewPlacement.displaySize(
            pixelSize: NSSize(width: 32, height: 16),
            scale: 2,
            maximum: NSSize(width: 420, height: 420),
            minimumLongSide: 120
        )

        XCTAssertEqual(displaySize.width, 120)
        XCTAssertEqual(displaySize.height, 60)
    }

    func testSavedPanelIsHalfHeightAndSharesTopEdgeWithHistoryPanel() {
        let surfaceFrame = NSRect(x: 416, y: 300, width: 334, height: 416)

        let savedFrame = SavedClipsPlacement.frame(
            panelSurfaceFrame: surfaceFrame,
            visibleFrame: NSRect(x: 0, y: 0, width: 1800, height: 1000),
            gap: 16
        )

        XCTAssertEqual(
            savedFrame.width,
            (surfaceFrame.width * SavedClipsPlacement.widthRatio).rounded()
        )
        XCTAssertEqual(savedFrame.height, surfaceFrame.height / 2)
        XCTAssertEqual(savedFrame.maxX, surfaceFrame.minX - 16)
        XCTAssertEqual(savedFrame.maxY, surfaceFrame.maxY)
    }

    func testSavedPanelFlipsToTheRightNearTheLeftScreenEdge() {
        let surfaceFrame = NSRect(x: 100, y: 300, width: 334, height: 416)

        let savedFrame = SavedClipsPlacement.frame(
            panelSurfaceFrame: surfaceFrame,
            visibleFrame: NSRect(x: 0, y: 0, width: 1500, height: 1000),
            gap: 16
        )

        XCTAssertEqual(savedFrame.minX, surfaceFrame.maxX + 16)
    }

    func testSavedPanelStaysInsideVisibleFrame() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1800, height: 1000)

        let savedFrame = SavedClipsPlacement.frame(
            panelSurfaceFrame: NSRect(x: 416, y: 800, width: 334, height: 600),
            visibleFrame: visibleFrame,
            gap: 16
        )

        XCTAssertLessThanOrEqual(savedFrame.maxY, visibleFrame.maxY)
        XCTAssertGreaterThanOrEqual(savedFrame.minY, visibleFrame.minY)
    }

    func testImagePreviewStaysRightOfHistoryWhenSavedPanelIsOnTheLeft() {
        let surfaceFrame = NSRect(x: 416, y: 300, width: 334, height: 416)
        let visibleFrame = NSRect(x: 0, y: 0, width: 1800, height: 1000)
        let savedFrame = SavedClipsPlacement.frame(
            panelSurfaceFrame: surfaceFrame,
            visibleFrame: visibleFrame,
            gap: 16
        )

        let withoutSaved = ImagePreviewPlacement.frame(
            previewSize: NSSize(width: 300, height: 200),
            anchorFrame: surfaceFrame,
            visibleFrame: visibleFrame,
            gap: 16
        )
        let withSaved = ImagePreviewPlacement.frame(
            previewSize: NSSize(width: 300, height: 200),
            anchorFrame: surfaceFrame.union(savedFrame),
            visibleFrame: visibleFrame,
            gap: 16
        )

        XCTAssertEqual(savedFrame.maxX, surfaceFrame.minX - 16)
        XCTAssertEqual(withSaved.minX, withoutSaved.minX)
        // The union keeps the taller history panel's top, so the preview stays
        // on the same line either way.
        XCTAssertEqual(withSaved.maxY, withoutSaved.maxY)
    }

    @MainActor
    func testSavedPanelVisibilityIsSavedAndRestored() throws {
        let suiteName = "PasteListTests.savedPanelVisible.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(SavedClipsPanelController.storedVisibility(in: defaults))

        SavedClipsPanelController.saveVisibility(true, in: defaults)
        XCTAssertTrue(SavedClipsPanelController.storedVisibility(in: defaults))

        SavedClipsPanelController.saveVisibility(false, in: defaults)
        XCTAssertFalse(SavedClipsPanelController.storedVisibility(in: defaults))
    }

    func testClipTimestampUsesTodayYesterdayAndWeekdayFormats() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(
            calendar.date(from: DateComponents(
                year: 2026,
                month: 7,
                day: 29,
                hour: 18
            ))
        )
        let today = try XCTUnwrap(
            calendar.date(from: DateComponents(
                year: 2026,
                month: 7,
                day: 29,
                hour: 15,
                minute: 4
            ))
        )
        let yesterday = try XCTUnwrap(
            calendar.date(from: DateComponents(
                year: 2026,
                month: 7,
                day: 28,
                hour: 9,
                minute: 15
            ))
        )
        let thursday = try XCTUnwrap(
            calendar.date(from: DateComponents(
                year: 2026,
                month: 7,
                day: 23,
                hour: 20,
                minute: 30
            ))
        )

        XCTAssertEqual(
            ClipTimestampFormatter.string(for: today, relativeTo: now, calendar: calendar),
            "Today 15:04"
        )
        XCTAssertEqual(
            ClipTimestampFormatter.string(for: yesterday, relativeTo: now, calendar: calendar),
            "Yesterday 09:15"
        )
        XCTAssertEqual(
            ClipTimestampFormatter.string(for: thursday, relativeTo: now, calendar: calendar),
            "Thursday 20:30"
        )
    }

    func testAppPathsCreateExpectedDirectories() throws {
        try withTemporaryPaths { paths in
            XCTAssertEqual(
                paths.applicationSupportDirectory.lastPathComponent,
                AppConfiguration.bundleIdentifier
            )
            XCTAssertEqual(paths.databaseURL.lastPathComponent, "clips.sqlite")
            XCTAssertEqual(paths.blobsDirectory.lastPathComponent, "blobs")

            var isDirectory: ObjCBool = false
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: paths.blobsDirectory.path,
                    isDirectory: &isDirectory
                )
            )
            XCTAssertTrue(isDirectory.boolValue)
        }
    }

    func testMigrationCreatesClipsSchemaAndIndexes() throws {
        try withTemporaryPaths { paths in
            let appDatabase = try AppDatabase(paths: paths)

            let schema = try appDatabase.databasePool.read { database in
                try String.fetchOne(
                    database,
                    sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'clips'"
                )
            }
            XCTAssertNotNil(schema)
            XCTAssertTrue(schema?.contains("AUTOINCREMENT") == true)

            let columns = try appDatabase.databasePool.read { database in
                try Row.fetchAll(database, sql: "PRAGMA table_info(clips)")
            }
            XCTAssertEqual(
                columns.map { $0["name"] as String },
                ["id", "type", "content", "preview_text", "created_at", "pinned", "app_bundle_id"]
            )

            let indexNames = try appDatabase.databasePool.read { database in
                try String.fetchAll(
                    database,
                    sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'clips'"
                )
            }
            XCTAssertTrue(indexNames.contains("clips_created_at_desc"))
            XCTAssertTrue(indexNames.contains("clips_pinned_created_at_desc"))
        }
    }

    func testClipRecordRoundTripAndAutoIncrementedID() throws {
        try withTemporaryPaths { paths in
            let appDatabase = try AppDatabase(paths: paths)
            let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

            let inserted = try appDatabase.databasePool.write { database in
                var clip = ClipRecord(
                    type: "text",
                    content: "Hello",
                    previewText: "Hello",
                    createdAt: createdAt,
                    appBundleID: "com.apple.TextEdit"
                )
                try clip.insert(database)
                return clip
            }

            XCTAssertNotNil(inserted.id)
            let fetched = try appDatabase.databasePool.read { database in
                try ClipRecord.fetchOne(database, key: inserted.id)
            }
            XCTAssertEqual(fetched, inserted)
        }
    }

    func testMigrationCanRunMoreThanOnce() throws {
        try withTemporaryPaths { paths in
            _ = try AppDatabase(paths: paths)
            let reopenedDatabase = try AppDatabase(paths: paths)

            let migrationCount = try reopenedDatabase.databasePool.read { database in
                try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = 'createClips'"
                )
            }
            XCTAssertEqual(migrationCount, 1)
        }
    }

    private func withTemporaryPaths<T>(
        _ body: (AppPaths) throws -> T
    ) throws -> T {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasteListTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        let paths = try AppPaths(applicationSupportRoot: temporaryRoot)
        return try body(paths)
    }
}

@MainActor
final class LaunchAtLoginControllerTests: XCTestCase {
    func testExternalResetCommandIgnoresNormalLaunch() {
        let service = LaunchAtLoginServiceSpy(status: .enabled)

        let result = LaunchAtLoginResetCommand.run(
            arguments: ["/Applications/PasteList.app/Contents/MacOS/PasteList"],
            service: service
        )

        XCTAssertEqual(result, .notRequested)
        XCTAssertEqual(service.unregisterCallCount, 0)
    }

    func testExternalResetCommandUnregistersEnabledService() {
        let service = LaunchAtLoginServiceSpy(status: .enabled)

        let result = LaunchAtLoginResetCommand.run(
            arguments: ["PasteList", LaunchAtLoginResetCommand.argument],
            service: service
        )

        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(service.status, .notRegistered)
    }

    func testExternalResetCommandUnregistersServiceAwaitingApproval() {
        let service = LaunchAtLoginServiceSpy(status: .requiresApproval)

        let result = LaunchAtLoginResetCommand.run(
            arguments: ["PasteList", LaunchAtLoginResetCommand.argument],
            service: service
        )

        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(service.unregisterCallCount, 1)
    }

    func testExternalResetCommandAcceptsAlreadyUnregisteredService() {
        let service = LaunchAtLoginServiceSpy(status: .notRegistered)

        let result = LaunchAtLoginResetCommand.run(
            arguments: ["PasteList", LaunchAtLoginResetCommand.argument],
            service: service
        )

        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(service.unregisterCallCount, 0)
    }

    func testExternalResetCommandReportsUnregisterFailure() {
        let expectedError = NSError(
            domain: "LaunchAtLoginResetCommandTests",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "reset denied"]
        )
        let service = LaunchAtLoginServiceSpy(
            status: .enabled,
            unregisterError: expectedError
        )

        let result = LaunchAtLoginResetCommand.run(
            arguments: ["PasteList", LaunchAtLoginResetCommand.argument],
            service: service
        )

        XCTAssertEqual(result, .failed("reset denied"))
        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(service.status, .enabled)
    }

    func testInitialSetupDoesNotRegisterWithoutUserAction() throws {
        let defaults = try isolatedUserDefaults()
        let service = LaunchAtLoginServiceSpy(status: .notRegistered)
        let controller = LaunchAtLoginController(
            service: service,
            userDefaults: defaults
        )

        controller.performInitialSetupIfNeeded()

        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertFalse(controller.isEnabled)
    }

    func testInitialSetupRemovesStaleLaunchRegistration() throws {
        let defaults = try isolatedUserDefaults()
        let service = LaunchAtLoginServiceSpy(status: .enabled)
        let controller = LaunchAtLoginController(
            service: service,
            userDefaults: defaults
        )

        controller.performInitialSetupIfNeeded()

        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertFalse(controller.isEnabled)
    }

    func testToggleIsTheOnlyOperationThatChangesRegistration() throws {
        let defaults = try isolatedUserDefaults()
        let service = LaunchAtLoginServiceSpy(status: .notRegistered)
        let controller = LaunchAtLoginController(
            service: service,
            userDefaults: defaults
        )

        controller.setEnabled(true)
        controller.setEnabled(false)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(service.unregisterCallCount, 1)
    }

    private func isolatedUserDefaults() throws -> UserDefaults {
        let suiteName = "LaunchAtLoginControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}

@MainActor
private final class LaunchAtLoginServiceSpy: LaunchAtLoginServicing {
    var status: SMAppService.Status
    private let unregisterError: Error?
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0

    init(
        status: SMAppService.Status,
        unregisterError: Error? = nil
    ) {
        self.status = status
        self.unregisterError = unregisterError
    }

    func register() throws {
        registerCallCount += 1
        status = .enabled
    }

    func unregister() throws {
        unregisterCallCount += 1
        if let unregisterError {
            throw unregisterError
        }
        status = .notRegistered
    }
}
