import Foundation

/// The same account the usage card shows, with that account's hidden metrics removed.
enum PresentedUsageSnapshot {
    static func make(
        _ snapshot: UsageSnapshot,
        account: MonitoredAccount,
        settings: AccountMonitorSettings
    ) -> UsageSnapshot {
        var result = snapshot
        result.accountName = account.usageCardTitle
        result.accountProviderID = account.providerID
        result.accountSymbolName = account.customSymbolName
        return result.filtered(using: settings)
    }
}

/// Accounts the device itself should ask. Worker-polled accounts stay out of this list.
///
/// This matches `AccountRefreshRoute.provider`. The unit test keeps the two in step.
enum WidgetRefreshPlan {
    static let defaultMinimumInterval: TimeInterval = 15 * 60

    static func pollsOnDevice(
        isDemo: Bool,
        remoteOnly: Bool,
        workerIsCredentialAuthority: Bool,
        serverMonitoringEnabled: Bool,
        hasLocalCredentials: Bool
    ) -> Bool {
        if isDemo || remoteOnly { return false }
        if serverMonitoringEnabled && (!hasLocalCredentials || workerIsCredentialAuthority) {
            return false
        }
        return true
    }

    static func pollsOnDevice(
        _ account: MonitoredAccount,
        serverMonitoringEnabled: Bool,
        hasLocalCredentials: Bool
    ) -> Bool {
        pollsOnDevice(
            isDemo: account.isDemo,
            remoteOnly: account.isRemoteOnly,
            workerIsCredentialAuthority: account.usesWorkerAsCredentialAuthority,
            serverMonitoringEnabled: serverMonitoringEnabled,
            hasLocalCredentials: hasLocalCredentials
        )
    }

    /// Accounts whose saved `fetchedAt` is older than the interval, or missing.
    static func staleAccountIDs(
        accounts: [MonitoredAccount],
        snapshots: [UsageSnapshot],
        now: Date,
        minimumInterval: TimeInterval
    ) -> Set<UUID> {
        let interval = max(minimumInterval, 60)
        let fetchedAt = Dictionary(
            snapshots.map { ($0.accountID, $0.fetchedAt) },
            uniquingKeysWith: { max($0, $1) }
        )
        return Set(accounts.compactMap { account in
            guard let fetched = fetchedAt[account.id] else { return account.id }
            return now.timeIntervalSince(fetched) >= interval ? account.id : nil
        })
    }
}

/// Replaces fetched accounts in place and keeps every account that was not fetched.
enum WidgetSnapshotMerge {
    static func merging(existing: [UsageSnapshot], updates: [UUID: UsageSnapshot]) -> [UsageSnapshot] {
        var seen = Set<UUID>()
        var result: [UsageSnapshot] = []
        result.reserveCapacity(existing.count + updates.count)
        for snapshot in existing {
            result.append(updates[snapshot.accountID] ?? snapshot)
            seen.insert(snapshot.accountID)
        }
        let extras = updates
            .filter { !seen.contains($0.key) }
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .map(\.value)
        result.append(contentsOf: extras)
        return result
    }

    /// A widget refresh that does not yet know the account's hidden-metric settings
    /// keeps the metrics the last saved snapshot already showed.
    static func preservingOmittedMetrics(
        updated: UsageSnapshot,
        previous: UsageSnapshot?
    ) -> UsageSnapshot {
        guard let previous else { return updated }
        let allowed = Set(previous.usageWindows.map(\.metricID))
        guard !allowed.isEmpty else { return updated }
        var result = updated
        if let primary = result.primary, !allowed.contains(primary.metricID) {
            result.primary = nil
        }
        if let secondary = result.secondary, !allowed.contains(secondary.metricID) {
            result.secondary = nil
        }
        result.extraWindows = result.extraWindows?.filter { allowed.contains($0.metricID) }
        return result
    }
}

struct WidgetRefreshManifest: Codable, Equatable, Sendable {
    /// Keyed by `UUID.uuidString`. JSON object keys have to be strings.
    var accounts: [MonitoredAccount]
    var settingsByAccountID: [String: AccountMonitorSettings]
    var minimumInterval: TimeInterval

    func settings(for accountID: UUID) -> AccountMonitorSettings {
        settingsByAccountID[accountID.uuidString] ?? .init()
    }
}

enum WidgetRefreshManifestStore {
    private static let fileName = "widget-refresh-manifest-v1.json"

    static func load(fileManager: FileManager = .default) -> WidgetRefreshManifest? {
        guard let url = fileURL(fileManager: fileManager),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(WidgetRefreshManifest.self, from: data) else {
            return nil
        }
        return manifest
    }

    static func save(_ manifest: WidgetRefreshManifest, fileManager: FileManager = .default) {
        guard let url = fileURL(fileManager: fileManager),
              let data = try? JSONEncoder().encode(manifest) else { return }
        let directory = url.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    static func fileURL(fileManager: FileManager = .default) -> URL? {
        SharedSnapshotStore.appGroupSupportDirectory(fileManager: fileManager)?
            .appendingPathComponent(fileName, isDirectory: false)
    }
}
