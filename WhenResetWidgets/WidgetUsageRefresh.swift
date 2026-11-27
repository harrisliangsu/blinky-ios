import Foundation

/// Refreshes usage while WidgetKit is building a timeline.
///
/// Home and Lock Screen widgets do not run the app. `reloadAllTimelines()` from a
/// background launch is often deferred until the app is opened, so the timeline
/// itself asks the providers and returns the saved numbers.
actor WidgetUsageRefresh {
    static let shared = WidgetUsageRefresh()

    private var inFlight: Task<Void, Never>?

    func refreshIfNeeded(preview: Bool) async {
        guard !preview else { return }
        if let inFlight {
            await inFlight.value
            return
        }
        let task = Task { await self.perform() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func perform() async {
        let existing = SharedSnapshotStore.load()
        let context = Self.context()
        let staleIDs = WidgetRefreshPlan.staleAccountIDs(
            accounts: context.accounts,
            snapshots: existing,
            now: .now,
            minimumInterval: context.minimumInterval
        )
        let stale = context.accounts.filter { staleIDs.contains($0.id) }
        guard !stale.isEmpty else { return }

        let previousByID = Dictionary(existing.map { ($0.accountID, $0) }, uniquingKeysWith: { _, latest in latest })
        var updates: [UUID: UsageSnapshot] = [:]
        await withTaskGroup(of: (UUID, UsageSnapshot)?.self) { group in
            for account in stale {
                group.addTask {
                    guard let fetched = await Self.fetchOne(account) else { return nil }
                    return (account.id, Self.present(
                        fetched,
                        account: account,
                        previous: previousByID[account.id],
                        settings: context.settingsByAccountID[account.id.uuidString] ?? .init(),
                        settingsAreAuthoritative: context.settingsAreAuthoritative
                    ))
                }
            }
            for await update in group {
                if let update { updates[update.0] = update.1 }
            }
        }
        guard !updates.isEmpty else { return }
        SharedSnapshotStore.save(WidgetSnapshotMerge.merging(existing: existing, updates: updates))
    }

    private static func fetchOne(_ account: MonitoredAccount) async -> UsageSnapshot? {
        await withTaskGroup(of: UsageSnapshot?.self) { group in
            group.addTask { try? await LocalProviderUsageFetcher.fetch(account) }
            group.addTask {
                try? await Task.sleep(for: .seconds(20))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func present(
        _ snapshot: UsageSnapshot,
        account: MonitoredAccount,
        previous: UsageSnapshot?,
        settings: AccountMonitorSettings,
        settingsAreAuthoritative: Bool
    ) -> UsageSnapshot {
        let presented = PresentedUsageSnapshot.make(snapshot, account: account, settings: settings)
        guard settingsAreAuthoritative else {
            return WidgetSnapshotMerge.preservingOmittedMetrics(updated: presented, previous: previous)
        }
        return presented
    }

    private static func context() -> RefreshContext {
        if let manifest = WidgetRefreshManifestStore.load() {
            let accounts = manifest.accounts.filter {
                WidgetRefreshPlan.pollsOnDevice(
                    $0,
                    serverMonitoringEnabled: manifest.settings(for: $0.id).monitorOnSelfHostedServer,
                    hasLocalCredentials: hasCredentials($0.id)
                )
            }
            return RefreshContext(
                accounts: accounts,
                settingsByAccountID: manifest.settingsByAccountID,
                minimumInterval: manifest.minimumInterval,
                settingsAreAuthoritative: true
            )
        }
        let accounts = ((try? KeychainStore.loadAccounts()) ?? []).filter {
            !$0.usesWorkerAsCredentialAuthority && WidgetRefreshPlan.pollsOnDevice(
                $0,
                serverMonitoringEnabled: false,
                hasLocalCredentials: hasCredentials($0.id)
            )
        }
        return RefreshContext(
            accounts: accounts,
            settingsByAccountID: [:],
            minimumInterval: WidgetRefreshPlan.defaultMinimumInterval,
            settingsAreAuthoritative: false
        )
    }

    private static func hasCredentials(_ id: UUID) -> Bool {
        (try? KeychainStore.load(for: id)) != nil
    }

    private struct RefreshContext: Sendable {
        var accounts: [MonitoredAccount]
        var settingsByAccountID: [String: AccountMonitorSettings]
        var minimumInterval: TimeInterval
        var settingsAreAuthoritative: Bool
    }
}
