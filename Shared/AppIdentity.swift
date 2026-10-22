import Foundation

/// Bundle identifier, App Group, and background-refresh id for this fork.
///
/// Defaults are Harris-owned (`com.harrisliangsu.whenreset`). A signed build
/// substitutes the same values from Info.plist, so a local or CI override of
/// `APP_BUNDLE_IDENTIFIER` / `APP_GROUP_IDENTIFIER` stays in one place.
enum AppIdentity {
    static let defaultBundleIdentifier = "com.harrisliangsu.whenreset"
    static let defaultAppGroupIdentifier = "group.com.harrisliangsu.whenreset"
    static let defaultWidgetBundleIdentifier = "com.harrisliangsu.whenreset.widgets"

    static var bundleIdentifier: String {
        if let configured = resolvedInfoString("WhenResetBundleIdentifier") {
            return configured
        }
        if let identifier = Bundle.main.bundleIdentifier, isResolved(identifier),
           !identifier.hasSuffix(".widgets"), !identifier.contains("Tests") {
            return identifier
        }
        return defaultBundleIdentifier
    }

    static var appGroupIdentifier: String {
        resolvedInfoString("AppGroupIdentifier") ?? defaultAppGroupIdentifier
    }

    static var refreshTaskIdentifier: String {
        if let identifiers = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String],
           let first = identifiers.first, isResolved(first) {
            return first
        }
        return "\(bundleIdentifier).refresh"
    }

    private static func resolvedInfoString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, isResolved(value) else {
            return nil
        }
        return value
    }

    private static func isResolved(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.contains("$(")
    }
}
