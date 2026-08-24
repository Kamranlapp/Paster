import AppKit
import ApplicationServices
import Carbon
import Combine
import CoreGraphics
import Foundation

enum AuthorizationRefreshSurface: Hashable {
    case settings
    case onboarding
    case permissionPrompt
}

enum PostEventPermissionState: Equatable {
    case granted
    case notGranted

    init(isGranted: Bool) {
        self = isGranted ? .granted : .notGranted
    }
}

enum PostEventPermissionRequestState: Equatable {
    case idle
    case requesting
    case awaitingSystemApproval
}

@MainActor
struct PostEventPermissionClient {
    let preflight: () -> Bool
    let request: () -> Bool

    static let live = PostEventPermissionClient(
        // System Settings exposes the approval as an Accessibility toggle.
        // AX trust reflects that toggle reliably, including after the user
        // grants access while the app is already running. In contrast,
        // CGPreflightPostEventAccess can remain false for a sandboxed app even
        // though the visible Accessibility entry is enabled.
        preflight: { AXIsProcessTrusted() },
        request: { CGRequestPostEventAccess() }
    )
}

private func postCommandVPasteEvent() -> Bool {
    guard
        let source = CGEventSource(stateID: .hidSystemState),
        let commandDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(kVK_Command),
            keyDown: true
        ),
        let pasteDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(kVK_ANSI_V),
            keyDown: true
        ),
        let pasteUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(kVK_ANSI_V),
            keyDown: false
        ),
        let commandUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(kVK_Command),
            keyDown: false
        )
    else {
        return false
    }

    commandDown.flags = .maskCommand
    pasteDown.flags = .maskCommand
    pasteUp.flags = .maskCommand
    commandUp.flags = []
    commandDown.post(tap: .cghidEventTap)
    pasteDown.post(tap: .cghidEventTap)
    pasteUp.post(tap: .cghidEventTap)
    commandUp.post(tap: .cghidEventTap)
    return true
}

enum PasteAutomationResult: Equatable {
    case pastedAutomatically
    case permissionRequired
    case copiedForManualPaste
}

@MainActor
final class PasteAutomationController: ObservableObject {
    private enum DefaultsKey {
        static let assistivePasteEnabled = "accessibility.assistivePasteEnabled"
    }

    struct TargetApplication {
        let processIdentifier: pid_t
        let bundleIdentifier: String?
        let isTerminated: () -> Bool
        let activate: () -> Bool
    }

    @Published private(set) var permissionState: PostEventPermissionState
    @Published private(set) var permissionRequestState: PostEventPermissionRequestState = .idle
    @Published private(set) var isAssistivePasteEnabled: Bool

    var isPostEventAuthorized: Bool {
        permissionState == .granted
    }

    private let permissionClient: PostEventPermissionClient
    private let userDefaults: UserDefaults?
    private let frontmostApplication: () -> TargetApplication?
    private let isApplicationFrontmost: (pid_t) -> Bool
    private let postCommandV: () -> Bool
    private let waitBeforePosting: () async -> Void
    private let openSystemSettings: () -> Void
    private let backgroundRefreshInterval: TimeInterval
    private let settingsRefreshInterval: TimeInterval
    private var previousApplication: TargetApplication?
    private var authorizationRefreshTask: Task<Void, Never>?
    private var applicationDidBecomeActiveCancellable: AnyCancellable?
    private var visibleAuthorizationSurfaces: Set<AuthorizationRefreshSurface> = []
    private(set) var authorizationRefreshInterval: TimeInterval
    private(set) var authorizationMonitorGeneration = 0

    init(
        permissionClient: PostEventPermissionClient = .live,
        userDefaults: UserDefaults? = nil,
        frontmostApplication: @escaping () -> TargetApplication? = {
            guard let application = NSWorkspace.shared.frontmostApplication else {
                return nil
            }
            return TargetApplication(
                processIdentifier: application.processIdentifier,
                bundleIdentifier: application.bundleIdentifier,
                isTerminated: { application.isTerminated },
                activate: {
                    application.activate(options: [.activateIgnoringOtherApps])
                }
            )
        },
        isApplicationFrontmost: @escaping (pid_t) -> Bool = { processIdentifier in
            NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier
        },
        postCommandV: @escaping () -> Bool = postCommandVPasteEvent,
        waitBeforePosting: @escaping () async -> Void = {
            try? await Task.sleep(nanoseconds: 150_000_000)
        },
        openSystemSettings: @escaping () -> Void = {
            guard let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            ) else {
                return
            }
            NSWorkspace.shared.open(url)
        },
        backgroundRefreshInterval: TimeInterval = 60,
        settingsRefreshInterval: TimeInterval = 1
    ) {
        self.permissionClient = permissionClient
        self.userDefaults = userDefaults
        if let userDefaults,
           userDefaults.object(forKey: DefaultsKey.assistivePasteEnabled) != nil {
            isAssistivePasteEnabled = userDefaults.bool(
                forKey: DefaultsKey.assistivePasteEnabled
            )
        } else {
            isAssistivePasteEnabled = true
        }
        self.frontmostApplication = frontmostApplication
        self.isApplicationFrontmost = isApplicationFrontmost
        self.postCommandV = postCommandV
        self.waitBeforePosting = waitBeforePosting
        self.openSystemSettings = openSystemSettings
        self.backgroundRefreshInterval = backgroundRefreshInterval
        self.settingsRefreshInterval = settingsRefreshInterval
        authorizationRefreshInterval = backgroundRefreshInterval
        permissionState = PostEventPermissionState(isGranted: permissionClient.preflight())
        applicationDidBecomeActiveCancellable = NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.refreshAuthorizationNow()
                }
            }
        scheduleAuthorizationRefresh(every: authorizationRefreshInterval)
    }

    func rememberFrontmostApplication() {
        guard
            let application = frontmostApplication(),
            application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
            application.bundleIdentifier != AppConfiguration.bundleIdentifier
        else {
            return
        }
        previousApplication = application
    }

    func refreshAuthorization() {
        applyAuthorization(isGranted: permissionClient.preflight())
    }

    @discardableResult
    func refreshAuthorizationNow() async -> Bool {
        let isGranted = permissionClient.preflight()
        applyAuthorization(isGranted: isGranted)
        return isGranted
    }

    private func applyAuthorization(isGranted: Bool) {
        permissionState = PostEventPermissionState(isGranted: isGranted)
        if isGranted {
            permissionRequestState = .idle
        }
    }

    func setAssistivePasteEnabled(_ isEnabled: Bool) {
        isAssistivePasteEnabled = isEnabled
        userDefaults?.set(isEnabled, forKey: DefaultsKey.assistivePasteEnabled)
    }

    func setSettingsVisible(_ isVisible: Bool) {
        setAuthorizationSurface(.settings, visible: isVisible)
    }

    func setAuthorizationSurface(
        _ surface: AuthorizationRefreshSurface,
        visible isVisible: Bool
    ) {
        if isVisible {
            visibleAuthorizationSurfaces.insert(surface)
            refreshAuthorization()
        } else {
            visibleAuthorizationSurfaces.remove(surface)
        }
        let interval = visibleAuthorizationSurfaces.isEmpty
            ? backgroundRefreshInterval
            : settingsRefreshInterval
        guard interval != authorizationRefreshInterval else { return }
        authorizationRefreshInterval = interval
        scheduleAuthorizationRefresh(every: interval)
    }

    private func scheduleAuthorizationRefresh(every interval: TimeInterval) {
        authorizationRefreshTask?.cancel()
        authorizationMonitorGeneration += 1
        let nanoseconds = UInt64(interval * 1_000_000_000)
        authorizationRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                await self.refreshAuthorizationNow()
            }
        }
    }

    /// This is the only method that may trigger the system PostEvent prompt.
    /// Call it exclusively from an explicit user action.
    @discardableResult
    func requestAuthorization() async -> Bool {
        guard permissionRequestState != .requesting else {
            return isPostEventAuthorized
        }

        if await refreshAuthorizationNow() {
            return true
        }

        permissionRequestState = .requesting
        _ = permissionClient.request()
        // PostEvent preflight is authoritative and is polled while the
        // permission UI is visible; the request's return value is not treated
        // as the final TCC state.
        let isGranted = await refreshAuthorizationNow()
        if !isGranted {
            permissionRequestState = .awaitingSystemApproval
        }
        return isGranted
    }

    func openPostEventSettings() {
        openSystemSettings()
    }

    func pasteIntoPreviousApplication() async -> PasteAutomationResult {
        guard isAssistivePasteEnabled else {
            return .copiedForManualPaste
        }
        guard
            let application = previousApplication,
            !application.isTerminated(),
            application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
            application.bundleIdentifier != AppConfiguration.bundleIdentifier
        else {
            return .copiedForManualPaste
        }

        guard await refreshAuthorizationNow() else {
            return .permissionRequired
        }
        guard application.activate() else {
            return .copiedForManualPaste
        }

        await waitBeforePosting()
        guard isApplicationFrontmost(application.processIdentifier) else {
            return .copiedForManualPaste
        }
        return postCommandV()
            ? .pastedAutomatically
            : .copiedForManualPaste
    }
}
