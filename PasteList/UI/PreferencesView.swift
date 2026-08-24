import AppKit
import Carbon
import SwiftUI

struct PreferencesView: View {
    @ObservedObject var hotKeyController: GlobalHotKeyController
    @ObservedObject var pasteAutomationController: PasteAutomationController
    @ObservedObject var launchAtLoginController: LaunchAtLoginController
    let onOpenOnboarding: () -> Void

    var body: some View {
        preferencesSurface
            .frame(width: 560, height: 720)
        .onAppear {
            pasteAutomationController.refreshAuthorization()
            launchAtLoginController.refresh()
        }
    }

    private var preferencesSurface: some View {
        VStack(spacing: 0) {
            Form {
                preferenceSection(.globalShortcut) {
                Section("Global Shortcut") {
                    HStack {
                        Text("Open \(AppConfiguration.name)")
                        Spacer()
                        HotKeyRecorderField(
                            hotKey: hotKeyController.currentHotKey,
                            onRecord: { hotKeyController.updateHotKey($0) }
                        )
                        .frame(width: 150, height: 28)
                    }

                    if let error = hotKeyController.registrationError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            preferenceSection(.accessibility) {
                Section("Accessibility") {
                    Toggle(
                        "Assistive Paste",
                        isOn: Binding(
                            get: { pasteAutomationController.isAssistivePasteEnabled },
                            set: { pasteAutomationController.setAssistivePasteEnabled($0) }
                        )
                    )

                    Text("Enables a complete mouse-only paste workflow for people who have difficulty using a physical keyboard.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Label(
                            pasteAutomationController.isPostEventAuthorized
                                ? "Assistive Paste permission granted"
                                : "Assistive Paste permission not granted",
                            systemImage: pasteAutomationController.isPostEventAuthorized
                                ? "checkmark.circle.fill"
                                : "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(
                            pasteAutomationController.isPostEventAuthorized ? .green : .red
                        )
                        Spacer()
                    }

                    if pasteAutomationController.isAssistivePasteEnabled,
                       !pasteAutomationController.isPostEventAuthorized {
                        Button("Enable Assistive Paste…") {
                            Task {
                                await pasteAutomationController.requestAuthorization()
                            }
                        }
                        .disabled(pasteAutomationController.permissionRequestState == .requesting)

                        Text("Make sure \(AppConfiguration.name) is listed and turned on in Privacy & Security › Accessibility.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("PasteList never reads or monitors keyboard input or another app’s interface. After you select a clip, Assistive Paste sends only ⌘V. Without permission, the item stays copied for manual paste.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            preferenceSection(.historyRetention) {
                Section("History Retention") {
                    LabeledContent("Maximum age", value: "7 days")
                    LabeledContent("Maximum unpinned clips", value: "200")
                    Text("Pinned clips are not removed automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            preferenceSection(.startup) {
                Section("Startup") {
                    Toggle(
                        "Launch \(AppConfiguration.name) at login",
                        isOn: Binding(
                            get: { launchAtLoginController.isEnabled },
                            set: { launchAtLoginController.setEnabled($0) }
                        )
                    )
                    Text(launchAtLoginController.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let error = launchAtLoginController.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

                if AppConfiguration.isOnboardingEnabled {
                    preferenceSection(.help) {
                        Section("Help") {
                            Button("Show Welcome to \(AppConfiguration.name)") {
                                onOpenOnboarding()
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollIndicators(.hidden)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 8)
            .padding(.top, 8)

            Divider()
                .padding(.horizontal, 20)

            HStack {
                Spacer()
                Button("Close") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 560, height: 720)
        .background {
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .blur(radius: 15)
                Color.black.opacity(0.2)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
    }

    private func preferenceSection<Content: View>(
        _ section: PreferencesSection,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .id(section)
    }
}

private enum PreferencesSection: Int, CaseIterable, Hashable {
    case globalShortcut
    case accessibility
    case historyRetention
    case startup
    case help
}

struct PreferencesContainerView: View {
    @ObservedObject var services: AppServices

    var body: some View {
        if
            let hotKeyController = services.globalHotKeyController,
            let pasteAutomationController = services.pasteAutomationController,
            let launchAtLoginController = services.launchAtLoginController
        {
            PreferencesView(
                hotKeyController: hotKeyController,
                pasteAutomationController: pasteAutomationController,
                launchAtLoginController: launchAtLoginController,
                onOpenOnboarding: services.onOpenOnboarding ?? {}
            )
        } else {
            ProgressView()
                .frame(width: 560, height: 720)
        }
    }
}

struct HotKeyRecorderField: NSViewRepresentable {
    let hotKey: HotKey
    let onRecord: (HotKey) -> Bool

    func makeNSView(context: Context) -> HotKeyRecorderNSView {
        HotKeyRecorderNSView(hotKey: hotKey, onRecord: onRecord)
    }

    func updateNSView(_ nsView: HotKeyRecorderNSView, context: Context) {
        nsView.hotKey = hotKey
        nsView.onRecord = onRecord
        nsView.updateLabel()
    }
}

final class HotKeyRecorderNSView: NSView {
    var hotKey: HotKey
    var onRecord: (HotKey) -> Bool

    private let label = NSTextField(labelWithString: "")
    private var isRecording = false

    init(hotKey: HotKey, onRecord: @escaping (HotKey) -> Bool) {
        self.hotKey = hotKey
        self.onRecord = onRecord
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateLabel()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
        updateLabel()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        if event.keyCode == UInt16(kVK_Escape) {
            isRecording = false
            window?.makeFirstResponder(nil)
            updateLabel()
            return
        }

        let modifiers = Self.carbonModifiers(from: event.modifierFlags)
        guard modifiers != 0 else {
            NSSound.beep()
            return
        }

        let candidate = HotKey(
            keyCode: UInt32(event.keyCode),
            modifiers: modifiers
        )
        if onRecord(candidate) {
            hotKey = candidate
        } else {
            NSSound.beep()
        }
        isRecording = false
        window?.makeFirstResponder(nil)
        updateLabel()
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        updateLabel()
        return super.resignFirstResponder()
    }

    func updateLabel() {
        label.stringValue = isRecording ? "Press shortcut…" : hotKey.displayName
        layer?.backgroundColor = (
            isRecording
                ? NSColor.controlAccentColor.withAlphaComponent(0.12)
                : NSColor.controlBackgroundColor
        ).cgColor
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        return modifiers
    }
}
