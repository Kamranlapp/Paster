import AppKit
import Darwin
import ServiceManagement
import SwiftUI

@MainActor
final class AppServices: ObservableObject {
    @Published var globalHotKeyController: GlobalHotKeyController?
    @Published var pasteAutomationController: PasteAutomationController?
    @Published var launchAtLoginController: LaunchAtLoginController?
    @Published var onOpenOnboarding: (() -> Void)?
    @Published var isOnboardingCompleted: (() -> Bool)?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum DefaultsKey {
        static let welcomeClipSeeded = "onboarding.welcomeClipSeeded"
    }

    let services = AppServices()
    private(set) var database: AppDatabase?
    private(set) var blobStorage: BlobStorage?
    private(set) var clipRepository: ClipRepository?
    private(set) var pasteboardMonitor: PasteboardMonitor?
    private(set) var statusItemController: StatusItemController?
    private(set) var pasteAutomationController: PasteAutomationController?
    private(set) var globalHotKeyController: GlobalHotKeyController?
    private(set) var launchAtLoginController: LaunchAtLoginController?
    private(set) var preferencesWindowController: PreferencesWindowController?
    private(set) var retentionScheduler: RetentionScheduler?
    private(set) var onboardingWindowController: OnboardingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted unit tests create isolated databases explicitly.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }

        switch LaunchAtLoginResetCommand.run(
            arguments: ProcessInfo.processInfo.arguments
        ) {
        case .notRequested:
            break
        case .succeeded:
            Darwin.exit(EXIT_SUCCESS)
        case .failed(let message):
            let output = "PasteList could not unregister Launch at Login: \(message)\n"
            FileHandle.standardError.write(Data(output.utf8))
            Darwin.exit(EXIT_FAILURE)
        }

        NSApp.setActivationPolicy(.accessory)

        #if DEBUG
        let debugResetAction = DebugResetRelaunchAction(
            arguments: ProcessInfo.processInfo.arguments
        )
        if debugResetAction == .firstLaunch {
            try? SMAppService.mainApp.unregister()
            UserDefaults.standard.removePersistentDomain(forName: AppConfiguration.bundleIdentifier)
            if let paths = try? AppPaths() {
                try? FileManager.default.removeItem(at: paths.applicationSupportDirectory)
            }
        }
        #endif

        do {
            let paths = try AppPaths()
            let database = try AppDatabase(paths: paths)
            let blobStorage = try BlobStorage(paths: paths)
            let repository = ClipRepository(database: database)
            let processor = PasteboardCaptureProcessor(
                repository: repository,
                blobStorage: blobStorage
            )
            let monitor = PasteboardMonitor(processor: processor)
            let pasteAutomationController = PasteAutomationController(
                userDefaults: .standard
            )
            let launchAtLoginController = LaunchAtLoginController()
            launchAtLoginController.performInitialSetupIfNeeded()
            let retentionScheduler = RetentionScheduler(
                service: RetentionService(
                    repository: repository,
                    blobStorage: blobStorage
                )
            )

            self.database = database
            self.blobStorage = blobStorage
            clipRepository = repository
            pasteboardMonitor = monitor
            self.pasteAutomationController = pasteAutomationController
            services.pasteAutomationController = pasteAutomationController
            self.launchAtLoginController = launchAtLoginController
            services.launchAtLoginController = launchAtLoginController
            self.retentionScheduler = retentionScheduler
            let onboardingState = OnboardingState()
            let isOnboardingCompleted = { [weak onboardingState] in
                onboardingState?.hasCompleted ?? false
            }
            services.isOnboardingCompleted = isOnboardingCompleted
            let preferencesWindowController = PreferencesWindowController(services: services)
            self.preferencesWindowController = preferencesWindowController
            let featureTipsState = FeatureTipsState()
            #if DEBUG
            if debugResetAction == .accessibility {
                onboardingState.reset()
                featureTipsState.resetAll()
            }
            #endif
            let statusItemController = StatusItemController(
                repository: repository,
                blobStorage: blobStorage,
                pasteboardMonitor: monitor,
                pasteAutomationController: pasteAutomationController,
                featureTipsState: featureTipsState,
                isOnboardingCompleted: isOnboardingCompleted,
                onOpenSettings: { [weak preferencesWindowController] in
                    preferencesWindowController?.show()
                }
            )
            self.statusItemController = statusItemController
            let globalHotKeyController = GlobalHotKeyController { [weak statusItemController] in
                statusItemController?.toggleCursorPanelAtPointer()
            }
            self.globalHotKeyController = globalHotKeyController
            services.globalHotKeyController = globalHotKeyController
            let onboardingWindowController = OnboardingWindowController(
                state: onboardingState,
                pasteAutomationController: pasteAutomationController,
                globalHotKeyController: globalHotKeyController
            )
            self.onboardingWindowController = onboardingWindowController
            services.onOpenOnboarding = { [weak onboardingWindowController] in
                onboardingWindowController?.show()
            }
            #if DEBUG
            statusItemController.onResetOnboarding = { [weak onboardingState, weak featureTipsState, weak onboardingWindowController] in
                onboardingState?.reset()
                featureTipsState?.resetAll()
                onboardingWindowController?.show()
            }
            #endif
            retentionScheduler.start()
            monitor.start()
            seedWelcomeClipIfNeeded(onboardingState: onboardingState, monitor: monitor)
            onboardingWindowController.showIfNeeded()
        } catch {
            NSLog("PasteList failed to initialize its database: %@", String(describing: error))
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pasteboardMonitor?.stop()
        retentionScheduler?.stop()
    }

    private func seedWelcomeClipIfNeeded(
        onboardingState: OnboardingState,
        monitor: PasteboardMonitor
    ) {
        guard
            onboardingState.shouldPresentOnLaunch,
            !UserDefaults.standard.bool(forKey: DefaultsKey.welcomeClipSeeded)
        else {
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString("Welcome to PasteList", forType: .string) else {
            return
        }

        UserDefaults.standard.set(true, forKey: DefaultsKey.welcomeClipSeeded)
        _ = monitor.checkForChanges()
    }
}

@main
struct PasteListApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            PreferencesContainerView(services: appDelegate.services)
        }
    }
}
