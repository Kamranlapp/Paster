import AppKit
import SwiftUI

@MainActor
final class PasteFallbackPanelController {
    enum Presentation: Equatable {
        case permissionRequired
        case manualPaste
    }

    static var permissionTitle: String {
        "Assistive Paste needs permission to send ⌘V."
    }
    static var permissionMessage: String {
        "Enable \(AppConfiguration.name) in Privacy & Security → Accessibility."
    }
    static let manualTitle = "Copied — press ⌘V to paste"
    static let manualMessage = "Assistive Paste could not reach the previous app."

    private static let permissionPanelSize = NSSize(width: 520, height: 170)
    private static let manualPanelSize = NSSize(width: 500, height: 96)

    private let panel: NSPanel
    private let pasteAutomationController: PasteAutomationController
    private var dismissalTask: Task<Void, Never>?
    private var presentation: Presentation?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?

    init(pasteAutomationController: PasteAutomationController) {
        self.pasteAutomationController = pasteAutomationController
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.permissionPanelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = true
    }

    func showPermissionRequired() {
        show(.permissionRequired)
    }

    func showManualPaste() {
        show(.manualPaste)
    }

    private func show(_ presentation: Presentation) {
        dismissalTask?.cancel()
        if self.presentation == .permissionRequired, presentation != .permissionRequired {
            pasteAutomationController.setAuthorizationSurface(
                .permissionPrompt,
                visible: false
            )
        }
        self.presentation = presentation
        let panelSize = presentation == .permissionRequired
            ? Self.permissionPanelSize
            : Self.manualPanelSize
        panel.setContentSize(panelSize)
        panel.contentViewController = NSHostingController(
            rootView: PasteFallbackView(
                presentation: presentation,
                pasteAutomationController: pasteAutomationController,
                dismiss: { [weak self] in self?.hide() }
            )
        )
        if presentation == .permissionRequired {
            pasteAutomationController.setAuthorizationSurface(
                .permissionPrompt,
                visible: true
            )
        }
        let pointer = NSEvent.mouseLocation
        let visibleFrame = NSScreen.screens.first { $0.frame.contains(pointer) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? .zero
        let origin = NSPoint(
            x: min(
                max(pointer.x - panelSize.width / 2, visibleFrame.minX + 8),
                visibleFrame.maxX - panelSize.width - 8
            ),
            y: min(
                max(pointer.y + 20, visibleFrame.minY + 8),
                visibleFrame.maxY - panelSize.height - 8
            )
        )
        panel.setFrameOrigin(origin)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        if presentation == .permissionRequired {
            startOutsideClickMonitoring()
        } else {
            dismissalTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard !Task.isCancelled else {
                    return
                }
                self?.hide()
            }
        }
    }

    private func startOutsideClickMonitoring() {
        stopOutsideClickMonitoring()
        let mouseDownEvents: NSEvent.EventTypeMask = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
        ]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseDownEvents) {
            [weak self] event in
            self?.hideIfClickIsOutsidePanel(at: NSEvent.mouseLocation)
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDownEvents) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.hideIfClickIsOutsidePanel(at: NSEvent.mouseLocation)
            }
        }
    }

    private func hideIfClickIsOutsidePanel(at location: NSPoint) {
        guard presentation == .permissionRequired,
              !panel.frame.contains(location) else {
            return
        }
        hide()
    }

    private func stopOutsideClickMonitoring() {
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
    }

    private func hide() {
        dismissalTask?.cancel()
        stopOutsideClickMonitoring()
        if presentation == .permissionRequired {
            pasteAutomationController.setAuthorizationSurface(
                .permissionPrompt,
                visible: false
            )
        }
        presentation = nil
        panel.orderOut(nil)
    }
}

private struct PasteFallbackView: View {
    let presentation: PasteFallbackPanelController.Presentation
    @ObservedObject var pasteAutomationController: PasteAutomationController
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: iconName)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(iconColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if presentation == .permissionRequired {
                    HStack(spacing: 12) {
                        if pasteAutomationController.isPostEventAuthorized {
                            Button("Done", action: dismiss)
                        } else {
                            Button("Open System Settings") {
                                Task {
                                    await pasteAutomationController.requestAuthorization()
                                }
                            }
                            .disabled(
                                pasteAutomationController.permissionRequestState == .requesting
                            )
                            Button("Close", action: dismiss)
                        }
                    }
                    .controlSize(.small)
                    .padding(.top, 6)
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(
            width: presentation == .permissionRequired ? 520 : 500,
            height: presentation == .permissionRequired ? 170 : 96
        )
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.separator.opacity(0.65), lineWidth: 1)
        }
    }

    private var iconName: String {
        if presentation == .manualPaste {
            return "doc.on.clipboard.fill"
        }
        return pasteAutomationController.isPostEventAuthorized
            ? "checkmark.circle.fill"
            : "accessibility"
    }

    private var iconColor: Color {
        pasteAutomationController.isPostEventAuthorized ? .green : .primary
    }

    private var title: String {
        switch presentation {
        case .permissionRequired:
            return pasteAutomationController.isPostEventAuthorized
                ? "Assistive Paste permission granted"
                : PasteFallbackPanelController.permissionTitle
        case .manualPaste:
            return PasteFallbackPanelController.manualTitle
        }
    }

    private var message: String {
        switch presentation {
        case .permissionRequired:
            return pasteAutomationController.isPostEventAuthorized
                ? "The next selected clip can be pasted using only your pointing device."
                : PasteFallbackPanelController.permissionMessage
        case .manualPaste:
            return PasteFallbackPanelController.manualMessage
        }
    }
}
