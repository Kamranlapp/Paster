import AppKit
import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    static let cursorPanelContentSize = NSSize(width: 294, height: 392)
    static let cursorPanelPadding: CGFloat = 24
    static let cursorPanelSurfaceSize = NSSize(
        width: cursorPanelContentSize.width + cursorPanelPadding * 2,
        height: cursorPanelContentSize.height + cursorPanelPadding * 2
    )
    static let cursorScrollBarWidth: CGFloat = 8
    static let cursorScrollBarSpacing: CGFloat = 8
    static let cursorBulkPasteRailWidth: CGFloat = 113
    static let cursorBulkPasteRailSpacing: CGFloat = 8
    static let cursorWindowControlDiameter: CGFloat = 24
    static let cursorWindowControlSpacing: CGFloat = 8
    static let cursorWindowTooltipHeight: CGFloat = 18
    static let cursorPanelFadeDuration: TimeInterval = 0.3
    static let cursorWindowControlAreaHeight = cursorWindowTooltipHeight
        + cursorWindowControlDiameter
    static let cursorPanelSize = NSSize(
        width: cursorScrollBarWidth
            + cursorScrollBarSpacing
            + cursorPanelSurfaceSize.width
            + cursorBulkPasteRailSpacing
            + cursorBulkPasteRailWidth,
        height: cursorWindowControlAreaHeight
            + cursorWindowControlSpacing
            + cursorPanelSurfaceSize.height
    )
    static let cursorPanelMinimumSize = NSSize(
        width: 276 + cursorBulkPasteRailSpacing + cursorBulkPasteRailWidth,
        height: 332
    )
    static let cursorHorizontalAnchor = 0.75
    static let cursorFirstRowCenterFromTop: CGFloat = 56
    private static let screenEdgePadding: CGFloat = 8
    private static let cursorPanelWidthDefaultsKey = "cursorPanelWidth"
    private static let cursorPanelHeightDefaultsKey = "cursorPanelHeight"
    private static let cursorPanelLayoutVersionDefaultsKey = "cursorPanelLayoutVersion"
    private static let cursorPanelLayoutVersion = 2

    private let statusItem: NSStatusItem
    private let actionsPopover: NSPopover
    private let cursorPanel: CursorHistoryPanel
    private let imagePreviewPanel: ImagePreviewPanelController
    private let savedClipsPanel: SavedClipsPanelController
    private let historyViewModel: HistoryViewModel
    private let thumbnailCache: ImageThumbnailCache
    private let selectionResetController: HistorySelectionResetController
    private let featureTipsState: FeatureTipsState
    private let isOnboardingCompleted: () -> Bool
    private let pasteAutomationController: PasteAutomationController
    private let pasteFallbackPanel: PasteFallbackPanelController
    private let appReviewRequestController: AppReviewRequestController
    private let onOpenSettings: () -> Void
    #if DEBUG
    var onResetOnboarding: (() -> Void)?
    #endif
    private var isCursorPanelPinned = false
    private var isCursorPanelResizeModeEnabled = false
    private var isCursorPanelFilterMenuPresented = false
    private var isCursorPanelClearConfirmationPresented = false
    private var localResizeExitMonitor: Any?
    private var globalResizeExitMonitor: Any?
    private var globalDismissMonitor: Any?
    private var cursorPanelFadeGeneration = 0
    private var isCursorPanelFadingOut = false

    init(
        repository: ClipRepository,
        blobStorage: BlobStorage,
        pasteboardMonitor: PasteboardMonitor,
        pasteAutomationController: PasteAutomationController,
        appReviewRequestController: AppReviewRequestController = AppReviewRequestController(),
        featureTipsState: FeatureTipsState = FeatureTipsState(),
        isOnboardingCompleted: @escaping () -> Bool = { true },
        onOpenSettings: @escaping () -> Void
    ) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        actionsPopover = NSPopover()
        selectionResetController = HistorySelectionResetController()
        self.featureTipsState = featureTipsState
        self.isOnboardingCompleted = isOnboardingCompleted
        let initialCursorPanelSize = Self.storedCursorPanelSize()
        cursorPanel = CursorHistoryPanel(
            contentRect: NSRect(origin: .zero, size: initialCursorPanelSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        imagePreviewPanel = ImagePreviewPanelController(blobStorage: blobStorage)
        savedClipsPanel = SavedClipsPanelController()
        thumbnailCache = ImageThumbnailCache(blobStorage: blobStorage)
        // One view model backs both the history panel and the Saved panel, so a
        // single database observation keeps the two windows in step.
        let historyViewModel = HistoryViewModel(
            repository: repository,
            blobStorage: blobStorage,
            restorer: ClipRestorer(
                repository: repository,
                blobStorage: blobStorage,
                monitor: pasteboardMonitor
            ),
            bulkPasteController: BulkPasteController(
                repository: repository,
                blobStorage: blobStorage,
                monitor: pasteboardMonitor
            ),
            onRestored: {}
        )
        self.historyViewModel = historyViewModel
        self.pasteAutomationController = pasteAutomationController
        self.appReviewRequestController = appReviewRequestController
        self.onOpenSettings = onOpenSettings
        pasteFallbackPanel = PasteFallbackPanelController(
            pasteAutomationController: pasteAutomationController
        )
        super.init()

        historyViewModel.onRestored = { [weak self] in
            self?.didRestoreClip()
        }
        configureStatusItem()
        configureCursorPanel(blobStorage: blobStorage)
        configureSavedClipsPanel(blobStorage: blobStorage)
        configureActionsPopover()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else {
            return
        }

        let image = NSImage(named: "BarIcon")
            ?? NSImage(
                systemSymbolName: "doc.on.clipboard",
                accessibilityDescription: AppConfiguration.name
            )
        image?.size = NSSize(width: 22, height: 22)
        image?.isTemplate = true
        button.image = image
        button.toolTip = AppConfiguration.name
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func configureActionsPopover() {
        actionsPopover.behavior = .transient
        actionsPopover.animates = true
        #if DEBUG
        actionsPopover.contentSize = NSSize(width: 240, height: 242)
        #else
        actionsPopover.contentSize = NSSize(width: 220, height: 92)
        #endif
        #if DEBUG
        actionsPopover.contentViewController = NSHostingController(
            rootView: StatusActionsView(
                openSettings: { [weak self] in
                    self?.actionsPopover.performClose(nil)
                    self?.onOpenSettings()
                },
                quit: {
                    NSApp.terminate(nil)
                },
                restart: { [weak self] in
                    self?.restartApplication()
                },
                resetAccessibility: { [weak self] in
                    self?.resetAccessibilityPermission()
                },
                resetToFirstLaunch: { [weak self] in
                    self?.resetToFirstLaunch()
                },
                resetOnboarding: { [weak self] in
                    self?.actionsPopover.performClose(nil)
                    self?.onResetOnboarding?()
                }
            )
        )
        #else
        actionsPopover.contentViewController = NSHostingController(
            rootView: StatusActionsView(
                openSettings: { [weak self] in
                    self?.actionsPopover.performClose(nil)
                    self?.onOpenSettings()
                },
                quit: {
                    NSApp.terminate(nil)
                }
            )
        )
        #endif
    }

    #if DEBUG
    private func restartApplication() {
        actionsPopover.performClose(nil)
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = [
            "-c",
            "sleep 1; /usr/bin/open \"$1\"",
            "PasteList restart",
            Bundle.main.bundlePath,
        ]

        do {
            try relauncher.run()
            NSApp.terminate(nil)
        } catch {
            NSLog("PasteList could not restart: %@", String(describing: error))
        }
    }

    private func resetAccessibilityPermission() {
        actionsPopover.performClose(nil)
        launchAccessibilityResetHelper(relaunchAction: .accessibility)
    }

    private func resetToFirstLaunch() {
        actionsPopover.performClose(nil)
        launchAccessibilityResetHelper(relaunchAction: .firstLaunch)
    }

    private func launchAccessibilityResetHelper(
        relaunchAction: DebugResetRelaunchAction
    ) {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasteDebug-reset-\(UUID().uuidString).command")
        let script = DebugAccessibilityResetScript.contents(
            bundleIdentifier: AppConfiguration.bundleIdentifier,
            appPath: Bundle.main.bundlePath,
            relaunchAction: relaunchAction
        )

        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: scriptURL.path
            )
        } catch {
            showAccessibilityResetFailure(error: error)
            return
        }

        let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [scriptURL],
            withApplicationAt: terminalURL,
            configuration: configuration
        ) { [weak self] application, error in
            Task { @MainActor in
                guard error == nil, application != nil else {
                    try? FileManager.default.removeItem(at: scriptURL)
                    self?.showAccessibilityResetFailure(error: error)
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }

    private func showAccessibilityResetFailure(error: Error?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not start the Accessibility reset"
        alert.informativeText = "\(error?.localizedDescription ?? "Terminal could not be opened.") No app data was removed."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    #endif

    private func configureCursorPanel(blobStorage: BlobStorage) {
        cursorPanel.isReleasedWhenClosed = false
        cursorPanel.isFloatingPanel = true
        cursorPanel.level = .popUpMenu
        cursorPanel.hidesOnDeactivate = false
        cursorPanel.backgroundColor = .clear
        cursorPanel.isOpaque = false
        cursorPanel.hasShadow = true
        cursorPanel.minSize = Self.cursorPanelMinimumSize
        cursorPanel.collectionBehavior = [
            .transient,
            .moveToActiveSpace,
            .fullScreenAuxiliary,
        ]
        cursorPanel.delegate = self
        cursorPanel.cancelResizeMode = { [weak self] in
            self?.finishCursorPanelResizeMode()
        }
        cursorPanel.quickPaste = { [weak self] entryIndex in
            self?.quickPasteHistoryEntry(at: entryIndex)
        }
        let hostingController = NSHostingController(
            rootView: HistoryView(
                viewModel: historyViewModel,
                blobStorage: blobStorage,
                thumbnailCache: thumbnailCache,
                usesTransparentBackground: true,
                isSavedPanelVisible: savedClipsPanel.isEnabled,
                onActivateClip: { [weak self] clip in
                    self?.activateClip(clip)
                },
                onCursorPanelPinChanged: { [weak self] isPinned in
                    self?.setCursorPanelPinned(isPinned)
                },
                onCursorPanelResizeModeChanged: { [weak self] isEnabled in
                    self?.setCursorPanelResizeMode(isEnabled)
                },
                onCursorPanelFilterMenuPresentationChanged: { [weak self] isPresented in
                    self?.isCursorPanelFilterMenuPresented = isPresented
                },
                onCursorPanelClearConfirmationChanged: { [weak self] isPresented in
                    self?.isCursorPanelClearConfirmationPresented = isPresented
                },
                onSavedPanelVisibilityChanged: { [weak self] isVisible in
                    self?.setSavedPanelVisible(isVisible)
                },
                onImagePreviewChanged: { [weak self] clipID in
                    self?.setImagePreview(clipID: clipID)
                },
                selectionResetController: selectionResetController,
                featureTipsState: featureTipsState,
                isOnboardingCompleted: isOnboardingCompleted
            )
        )
        // The hosting controller would otherwise push its own fitting size onto
        // the panel and discard the size restored from user defaults.
        hostingController.sizingOptions = []
        cursorPanel.contentViewController = hostingController
        cursorPanel.setContentSize(Self.storedCursorPanelSize())
    }

    private func configureSavedClipsPanel(blobStorage: BlobStorage) {
        savedClipsPanel.configure(
            rootView: SavedClipsView(
                viewModel: historyViewModel,
                blobStorage: blobStorage,
                thumbnailCache: thumbnailCache,
                onActivateClip: { [weak self] clip in
                    self?.activateClip(clip)
                },
                onImagePreviewChanged: { [weak self] clipID in
                    self?.setImagePreview(clipID: clipID)
                }
            )
        )
    }

    private func setSavedPanelVisible(_ isVisible: Bool) {
        savedClipsPanel.setEnabled(isVisible, relativeTo: cursorPanel)
    }

    func toggleCursorPanelAtPointer() {
        if cursorPanel.isVisible && !isCursorPanelFadingOut {
            closeCursorPanel(force: true)
            return
        }

        actionsPopover.performClose(nil)
        selectionResetController.reset()
        pasteAutomationController.rememberFrontmostApplication()

        let pointerLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointerLocation) }
            ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            return
        }

        cursorPanel.setFrame(
            Self.cursorPanelFrame(
                pointerLocation: pointerLocation,
                visibleFrame: visibleFrame,
                size: cursorPanel.frame.size
            ),
            display: true
        )
        cursorPanelFadeGeneration += 1
        isCursorPanelFadingOut = false
        cursorPanel.alphaValue = 0
        cursorPanel.makeKeyAndOrderFront(nil)
        installGlobalDismissMonitor()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.cursorPanelFadeDuration
            context.timingFunction = CAMediaTimingFunction(
                name: .easeInEaseOut
            )
            cursorPanel.animator().alphaValue = 1
        }
        savedClipsPanel.show(relativeTo: cursorPanel)
    }

    static func cursorPanelFrame(
        pointerLocation: NSPoint,
        visibleFrame: NSRect,
        size requestedSize: NSSize = cursorPanelSize
    ) -> NSRect {
        let availableFrame = visibleFrame.insetBy(
            dx: screenEdgePadding,
            dy: screenEdgePadding
        )
        let size = NSSize(
            width: min(max(requestedSize.width, cursorPanelMinimumSize.width), availableFrame.width),
            height: min(max(requestedSize.height, cursorPanelMinimumSize.height), availableFrame.height)
        )
        let desiredOrigin = NSPoint(
            x: pointerLocation.x
                - cursorScrollBarWidth
                - cursorScrollBarSpacing
                - cursorPanelPadding
                - (size.width
                    - cursorScrollBarWidth
                    - cursorScrollBarSpacing
                    - cursorBulkPasteRailSpacing
                    - cursorBulkPasteRailWidth
                    - cursorPanelPadding * 2)
                    * cursorHorizontalAnchor,
            y: pointerLocation.y
                - (
                    size.height
                        - cursorWindowControlAreaHeight
                        - cursorWindowControlSpacing
                        - cursorPanelPadding
                        - cursorFirstRowCenterFromTop
                )
        )
        let maximumX = max(availableFrame.minX, availableFrame.maxX - size.width)
        let maximumY = max(availableFrame.minY, availableFrame.maxY - size.height)
        let origin = NSPoint(
            x: min(max(desiredOrigin.x, availableFrame.minX), maximumX),
            y: min(max(desiredOrigin.y, availableFrame.minY), maximumY)
        )
        return NSRect(origin: origin, size: size)
    }

    /// The rounded surface the user actually sees, inset from the panel frame by
    /// the tick scroll bar on the left, the hidden bulk-paste rail on the right
    /// and the transparent window-control strip on top.
    static func cursorPanelSurfaceFrame(in panelFrame: NSRect) -> NSRect {
        let leadingInset = cursorScrollBarWidth + cursorScrollBarSpacing
        let trailingInset = cursorBulkPasteRailSpacing + cursorBulkPasteRailWidth
        let topInset = cursorWindowControlAreaHeight + cursorWindowControlSpacing
        return NSRect(
            x: panelFrame.minX + leadingInset,
            y: panelFrame.minY,
            width: max(panelFrame.width - leadingInset - trailingInset, 0),
            height: max(panelFrame.height - topInset, 0)
        )
    }

    static func storedCursorPanelSize(
        in userDefaults: UserDefaults = .standard
    ) -> NSSize {
        let width = userDefaults.double(forKey: cursorPanelWidthDefaultsKey)
        let height = userDefaults.double(forKey: cursorPanelHeightDefaultsKey)
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            return cursorPanelSize
        }
        let storedLayoutVersion = userDefaults.integer(
            forKey: cursorPanelLayoutVersionDefaultsKey
        )
        let migratedWidth = storedLayoutVersion < cursorPanelLayoutVersion
            ? CGFloat(width) + cursorBulkPasteRailSpacing + cursorBulkPasteRailWidth
            : CGFloat(width)
        if storedLayoutVersion < cursorPanelLayoutVersion {
            userDefaults.set(
                cursorPanelLayoutVersion,
                forKey: cursorPanelLayoutVersionDefaultsKey
            )
        }
        return NSSize(
            width: max(migratedWidth, cursorPanelMinimumSize.width),
            height: max(CGFloat(height), cursorPanelMinimumSize.height)
        )
    }

    static func saveCursorPanelSize(
        _ size: NSSize,
        in userDefaults: UserDefaults = .standard
    ) {
        userDefaults.set(size.width, forKey: cursorPanelWidthDefaultsKey)
        userDefaults.set(size.height, forKey: cursorPanelHeightDefaultsKey)
        userDefaults.set(
            cursorPanelLayoutVersion,
            forKey: cursorPanelLayoutVersionDefaultsKey
        )
    }

    private func saveCursorPanelSize() {
        Self.saveCursorPanelSize(cursorPanel.frame.size)
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            toggleActionsPopover()
        } else {
            toggleCursorPanelAtPointer()
        }
    }

    private func didRestoreClip() {
        let shouldRequestReview = appReviewRequestController.recordSuccessfulPaste()
        dismissCursorPanelForPaste()
        Task { [weak self] in
            guard let self else {
                return
            }
            let result = await pasteAutomationController.pasteIntoPreviousApplication()
            switch result {
            case .pastedAutomatically:
                break
            case .permissionRequired:
                pasteFallbackPanel.showPermissionRequired()
            case .copiedForManualPaste:
                pasteFallbackPanel.showManualPaste()
            }
            if shouldRequestReview, let viewController = cursorPanel.contentViewController {
                await appReviewRequestController.performPendingRequest(
                    in: viewController
                )
            }
        }
    }

    /// Automatic paste must not race the panel's fade-out animation. Keeping a
    /// PasteList window visible (especially while pinned) can leave it as the key
    /// window while the synthetic Command-V is posted.
    private func dismissCursorPanelForPaste() {
        removeGlobalDismissMonitor()
        imagePreviewPanel.hide()
        savedClipsPanel.hide()
        setCursorPanelResizeMode(false)
        cursorPanelFadeGeneration += 1
        cursorPanel.orderOut(nil)
        cursorPanel.alphaValue = 1
        isCursorPanelFadingOut = false
        selectionResetController.reset()
    }

    private func quickPasteHistoryEntry(at index: Int) {
        guard historyViewModel.history.indices.contains(index) else {
            return
        }
        activateClip(historyViewModel.history[index])
    }

    private func activateClip(_ clip: ClipRecord) {
        historyViewModel.restore(clip)
    }

    private func toggleActionsPopover() {
        if actionsPopover.isShown {
            actionsPopover.performClose(nil)
            return
        }

        closeCursorPanel(force: true)
        guard let button = statusItem.button else {
            return
        }
        actionsPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        actionsPopover.contentViewController?.view.window?.makeKey()
    }

    private func setCursorPanelPinned(_ isPinned: Bool) {
        isCursorPanelPinned = isPinned
        cursorPanel.level = .popUpMenu
        cursorPanel.hidesOnDeactivate = false
        cursorPanel.collectionBehavior = isPinned
            ? [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            : [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
    }

    private func setImagePreview(clipID: Int64?) {
        guard let clipID, cursorPanel.isVisible, !isCursorPanelFadingOut else {
            imagePreviewPanel.hide()
            return
        }
        imagePreviewPanel.show(
            clipID: clipID,
            relativeTo: cursorPanel,
            anchorFrame: savedClipsPanel.anchorFrame(
                surfaceFrame: Self.cursorPanelSurfaceFrame(in: cursorPanel.frame)
            )
        )
    }

    private func setCursorPanelResizeMode(_ isEnabled: Bool) {
        guard isCursorPanelResizeModeEnabled != isEnabled else {
            return
        }
        isCursorPanelResizeModeEnabled = isEnabled
        if isEnabled {
            imagePreviewPanel.hide()
            installResizeExitMonitors()
        } else {
            removeResizeExitMonitors()
            saveCursorPanelSize()
        }
    }

    private func finishCursorPanelResizeMode() {
        guard isCursorPanelResizeModeEnabled else {
            return
        }
        setCursorPanelResizeMode(false)
        selectionResetController.reset()
    }

    private func installResizeExitMonitors() {
        removeResizeExitMonitors()
        localResizeExitMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .leftMouseDown
        ) { [weak self] event in
            self?.finishResizeModeIfClickIsFarFromEdge()
            return event
        }
        globalResizeExitMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .leftMouseDown
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.finishResizeModeIfClickIsFarFromEdge()
            }
        }
    }

    private func removeResizeExitMonitors() {
        if let localResizeExitMonitor {
            NSEvent.removeMonitor(localResizeExitMonitor)
            self.localResizeExitMonitor = nil
        }
        if let globalResizeExitMonitor {
            NSEvent.removeMonitor(globalResizeExitMonitor)
            self.globalResizeExitMonitor = nil
        }
    }

    private func installGlobalDismissMonitor() {
        guard globalDismissMonitor == nil else {
            return
        }
        globalDismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.closeCursorPanel()
            }
        }
    }

    private func removeGlobalDismissMonitor() {
        guard let globalDismissMonitor else {
            return
        }
        NSEvent.removeMonitor(globalDismissMonitor)
        self.globalDismissMonitor = nil
    }

    private func finishResizeModeIfClickIsFarFromEdge() {
        guard isCursorPanelResizeModeEnabled else {
            return
        }
        let point = NSEvent.mouseLocation
        let frame = cursorPanel.frame
        let distance: CGFloat
        if frame.contains(point) {
            distance = min(
                point.x - frame.minX,
                frame.maxX - point.x,
                point.y - frame.minY,
                frame.maxY - point.y
            )
        } else {
            let horizontalDistance = max(
                frame.minX - point.x,
                0,
                point.x - frame.maxX
            )
            let verticalDistance = max(
                frame.minY - point.y,
                0,
                point.y - frame.maxY
            )
            distance = hypot(horizontalDistance, verticalDistance)
        }
        if distance > 100 {
            finishCursorPanelResizeMode()
        }
    }

    private func closeCursorPanel(force: Bool = false) {
        guard force || !isCursorPanelPinned else {
            return
        }
        removeGlobalDismissMonitor()
        imagePreviewPanel.hide()
        savedClipsPanel.hide()
        setCursorPanelResizeMode(false)
        guard cursorPanel.isVisible else {
            return
        }
        guard !isCursorPanelFadingOut else {
            return
        }
        cursorPanelFadeGeneration += 1
        let fadeGeneration = cursorPanelFadeGeneration
        isCursorPanelFadingOut = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.cursorPanelFadeDuration
            context.timingFunction = CAMediaTimingFunction(
                name: .easeInEaseOut
            )
            cursorPanel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard
                    let self,
                    cursorPanelFadeGeneration == fadeGeneration
                else {
                    return
                }
                cursorPanel.orderOut(nil)
                cursorPanel.alphaValue = 1
                isCursorPanelFadingOut = false
                selectionResetController.reset()
            }
        }
    }
}

extension StatusItemController: NSWindowDelegate {
    func windowDidResize(_ notification: Notification) {
        guard notification.object as? NSWindow === cursorPanel else {
            return
        }
        // Child windows follow a move on their own, but not a resize.
        savedClipsPanel.layout(relativeTo: cursorPanel)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === cursorPanel else {
            return
        }
        guard
            !isCursorPanelFilterMenuPresented,
            !isCursorPanelClearConfirmationPresented
        else {
            return
        }
        closeCursorPanel()
    }
}

@MainActor
final class HistorySelectionResetController: ObservableObject {
    @Published private(set) var token = 0

    func reset() {
        token &+= 1
    }
}

final class CursorHistoryPanel: NSPanel {
    var cancelResizeMode: (() -> Void)?
    var quickPaste: ((Int) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        cancelResizeMode?()
    }

    override func sendEvent(_ event: NSEvent) {
        // SwiftUI's search field can own the field editor and receive keyDown
        // directly, bypassing NSWindow.keyDown. Intercept quick-paste keys at
        // the window dispatch boundary so they work regardless of first responder.
        if
            event.type == .keyDown,
            let entryIndex = QuickPasteShortcut.entryIndex(
                forKeyCode: event.keyCode,
                modifierFlags: event.modifierFlags
            )
        {
            quickPaste?(entryIndex)
            return
        }
        super.sendEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            cancelResizeMode?()
        } else {
            super.keyDown(with: event)
        }
    }

}

private struct StatusActionsView: View {
    let openSettings: () -> Void
    let quit: () -> Void
    #if DEBUG
    let restart: () -> Void
    let resetAccessibility: () -> Void
    let resetToFirstLaunch: () -> Void
    let resetOnboarding: () -> Void
    #endif

    var body: some View {
        VStack(spacing: 4) {
            actionButton("Settings…", systemImage: "gearshape", action: openSettings)
            #if DEBUG
            Divider()
            actionButton("Restart \(AppConfiguration.name)", systemImage: "arrow.clockwise", action: restart)
            actionButton("Reset Accessibility", systemImage: "hand.raised", action: resetAccessibility)
            actionButton("Reset to First Launch", systemImage: "trash", action: resetToFirstLaunch)
            actionButton("Reset Onboarding", systemImage: "arrow.counterclockwise", action: resetOnboarding)
            #endif
            Divider()
            actionButton("Quit \(AppConfiguration.name)", systemImage: "power", action: quit)
        }
        .padding(8)
        .frame(width: 220)
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .frame(height: 30)
    }
}
