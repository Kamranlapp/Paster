import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController {
    private let state: OnboardingState
    private let pasteAutomationController: PasteAutomationController
    private let globalHotKeyController: GlobalHotKeyController

    init(
        state: OnboardingState,
        pasteAutomationController: PasteAutomationController,
        globalHotKeyController: GlobalHotKeyController
    ) {
        self.state = state
        self.pasteAutomationController = pasteAutomationController
        self.globalHotKeyController = globalHotKeyController
        let window = NSWindow()
        window.title = "Welcome to \(AppConfiguration.name)"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 640, height: 480))
        window.minSize = NSSize(width: 640, height: 480)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func showIfNeeded() {
        guard AppConfiguration.isOnboardingEnabled, state.shouldPresentOnLaunch else {
            return
        }
        show()
    }

    func show() {
        guard AppConfiguration.isOnboardingEnabled else {
            return
        }
        window?.contentViewController = NSHostingController(
            rootView: OnboardingView(
                state: state,
                pasteAutomationController: pasteAutomationController,
                globalHotKeyController: globalHotKeyController,
                onFinish: { [weak self] in
                    self?.close()
                }
            )
        )
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct OnboardingView: View {
    @ObservedObject var state: OnboardingState
    @ObservedObject var pasteAutomationController: PasteAutomationController
    @ObservedObject var globalHotKeyController: GlobalHotKeyController
    let onFinish: () -> Void

    @State private var page = 0
    private let pageCount = 2

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0:
                    assistivePastePage
                default:
                    shortcutPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 12) {
                pageIndicator
                Spacer()
                if page > 0 {
                    Button("Back") {
                        page -= 1
                    }
                    .fixedSize()
                }
                Button {
                    if page == pageCount - 1 {
                        state.complete()
                        onFinish()
                    } else {
                        page += 1
                    }
                } label: {
                    Text(page == pageCount - 1 ? "Start Using \(AppConfiguration.name)" : "Continue")
                        .fixedSize()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .fixedSize(horizontal: true, vertical: true)
                .focusable(false)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 640, height: 480)
        .onAppear {
            pasteAutomationController.setAuthorizationSurface(
                .onboarding,
                visible: true
            )
        }
        .onDisappear {
            pasteAutomationController.setAuthorizationSurface(
                .onboarding,
                visible: false
            )
        }
        .onChange(of: pasteAutomationController.isPostEventAuthorized) { isAuthorized in
            guard isAuthorized, page == 0 else { return }
            Task {
                try? await Task.sleep(nanoseconds: 650_000_000)
                withAnimation {
                    page = 1
                }
            }
        }
    }

    private var assistivePastePage: some View {
        VStack(spacing: 22) {
            Image(systemName: pasteAutomationController.isPostEventAuthorized
                ? "checkmark.circle.fill"
                : "accessibility")
                .font(.system(size: 64, weight: .medium))
                .foregroundStyle(pasteAutomationController.isPostEventAuthorized ? Color.green : Color.accentColor)
            Text("Assistive Paste")
                .font(.system(size: 30, weight: .semibold))

            Text("Paste with only a mouse, trackpad, head pointer, or another pointing device — no physical keyboard action required.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)

            if pasteAutomationController.isPostEventAuthorized {
                Label("Assistive Paste permission granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Enable Assistive Paste…") {
                    Task {
                        await pasteAutomationController.requestAuthorization()
                    }
                }
                .disabled(pasteAutomationController.permissionRequestState == .requesting)

                Text("Make sure \(AppConfiguration.name) is listed and turned on in Privacy & Security › Accessibility.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Text("Optional and enabled by default. You can skip permission access and paste manually with ⌘V.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(44)
    }

    private var shortcutPage: some View {
        VStack(spacing: 24) {
            Image(systemName: "keyboard")
                .font(.system(size: 64, weight: .medium))
                .foregroundStyle(Color.accentColor)
            Text("Open it from anywhere")
                .font(.system(size: 30, weight: .semibold))
                .multilineTextAlignment(.center)

            HotKeyRecorderField(
                hotKey: globalHotKeyController.currentHotKey,
                onRecord: { globalHotKeyController.updateHotKey($0) }
            )
            .frame(width: 150, height: 32)

            if let error = globalHotKeyController.registrationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text("Press this shortcut to open \(AppConfiguration.name) at the pointer. Click the field above to record a different one — you can also change it later in Settings.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 470)
        }
        .padding(44)
    }

    private var pageIndicator: some View {
        HStack(spacing: 7) {
            ForEach(0..<pageCount, id: \.self) { index in
                Circle()
                    .fill(index == page ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityLabel("Step \(page + 1) of \(pageCount)")
    }
}
