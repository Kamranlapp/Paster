import Foundation

enum AppConfiguration {
    #if DEBUG
    static let name = "PasteDebug"
    static let fallbackBundleIdentifier = "com.kam.pastelist.debug"
    #else
    static let name = "PasteList"
    static let fallbackBundleIdentifier = "com.kam.pastelist"
    #endif
    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? fallbackBundleIdentifier
    static let isOnboardingEnabled = true
}

#if DEBUG
enum DebugResetRelaunchAction: String, CaseIterable {
    case accessibility = "--complete-accessibility-reset"
    case firstLaunch = "--complete-first-launch-reset"

    init?(arguments: [String]) {
        guard let match = Self.allCases.first(where: { arguments.contains($0.rawValue) }) else {
            return nil
        }
        self = match
    }
}

enum DebugAccessibilityResetScript {
    static let services = ["Accessibility", "PostEvent"]

    static func contents(
        bundleIdentifier: String,
        appPath: String,
        relaunchAction: DebugResetRelaunchAction
    ) -> String {
        let quotedBundleIdentifier = shellQuote(bundleIdentifier)
        let quotedAppPath = shellQuote(appPath)
        let quotedRelaunchArgument = shellQuote(relaunchAction.rawValue)

        return """
        #!/bin/bash
        set -u

        script_path="$0"
        cleanup() {
            /bin/rm -f "$script_path"
        }
        trap cleanup EXIT

        echo "Resetting automatic-paste authorization for \(bundleIdentifier)…"
        reset_failed=0
        \(services.map { "/usr/bin/tccutil reset \($0) \(quotedBundleIdentifier) || reset_failed=$?" }.joined(separator: "\n"))
        if ((reset_failed == 0)); then
            echo "Authorization reset succeeded. Relaunching PasteDebug…"
            /bin/sleep 1
            /usr/bin/open \(quotedAppPath) --args \(quotedRelaunchArgument)
            exit 0
        fi

        echo "Authorization reset failed with status $reset_failed. No app data was removed."
        /usr/bin/open \(quotedAppPath)
        echo "Press Return to close."
        read -r _
        exit "$reset_failed"
        """
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
#endif
