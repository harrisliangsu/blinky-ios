import XCTest
@testable import WhenReset

final class BackgroundWidgetRefreshTests: XCTestCase {
    func testAProviderMissDoesNotMarkTheBackgroundTaskFailed() {
        XCTAssertTrue(BackgroundRefreshReporting.reportsSuccess(
            persistedSnapshots: true,
            expiredBeforePersist: false
        ))
    }

    func testExpirationBeforeTheSnapshotWriteFailsTheTask() {
        XCTAssertFalse(BackgroundRefreshReporting.reportsSuccess(
            persistedSnapshots: false,
            expiredBeforePersist: true
        ))
        XCTAssertFalse(BackgroundRefreshReporting.reportsSuccess(
            persistedSnapshots: true,
            expiredBeforePersist: true
        ))
        XCTAssertFalse(BackgroundRefreshReporting.reportsSuccess(
            persistedSnapshots: false,
            expiredBeforePersist: false
        ))
    }

    func testWidgetReloadReadsTheSavedSnapshotAndDoesNotChangeItsPercent() throws {
        let previous = SharedSnapshotStore.load()
        defer { SharedSnapshotStore.save(previous) }

        let savedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let accountID = UUID()
        let window = UsageWindow(
            title: "Weekly limit",
            usedPercent: 74,
            resetsAt: savedAt.addingTimeInterval(86_400),
            windowMinutes: 10_080,
            kind: .weekly
        )
        let snapshot = UsageSnapshot(
            accountID: accountID,
            providerName: "ChatGPT",
            accountName: "ChatGPT",
            accountProviderID: .chatGPT,
            plan: "Plus",
            primary: window,
            secondary: nil,
            availableResetCount: 0,
            resetCredits: [],
            fetchedAt: savedAt
        )
        SharedSnapshotStore.save([snapshot])

        let readBack = try XCTUnwrap(SharedSnapshotStore.load().first { $0.accountID == accountID })
        XCTAssertEqual(readBack.fetchedAt, savedAt)
        XCTAssertEqual(readBack.primary?.usedPercent, 74)

        let reload = ResetCardSurface.reloadDate(
            targetExpiresAt: window.resetsAt,
            snapshots: [readBack],
            now: savedAt
        )
        XCTAssertEqual(reload, savedAt.addingTimeInterval(15 * 60))
        XCTAssertEqual(readBack.primary?.usedPercent, 74)
        XCTAssertEqual(SharedSnapshotStore.load().first { $0.accountID == accountID }?.fetchedAt, savedAt)
    }

    func testSnapshotFileSurvivesClearingTheDefaultsCache() throws {
        try XCTSkipIf(SharedSnapshotStore.snapshotFileURL() == nil)
        let previous = SharedSnapshotStore.load()
        defer { SharedSnapshotStore.save(previous) }

        let savedAt = Date(timeIntervalSince1970: 1_800_000_100)
        let accountID = UUID()
        let snapshot = sampleSnapshot(accountID: accountID, usedPercent: 41, fetchedAt: savedAt)
        SharedSnapshotStore.save([snapshot])
        UserDefaults(suiteName: SharedSnapshotStore.suiteName)?
            .removeObject(forKey: SharedSnapshotStore.snapshotsKey)

        let readBack = try XCTUnwrap(SharedSnapshotStore.load().first { $0.accountID == accountID })
        XCTAssertEqual(readBack.primary?.usedPercent, 41)
        XCTAssertEqual(readBack.fetchedAt, savedAt)
    }

    func testDevicePollMatchesTheAccountRefreshRoute() {
        let samples: [(Bool, Bool, Bool, Bool, Bool)] = [
            (true, false, false, false, true),
            (false, true, false, false, true),
            (false, false, true, true, true),
            (false, false, false, true, false),
            (false, false, false, true, true),
            (false, false, false, false, false),
            (false, false, true, false, true)
        ]
        for sample in samples {
            let route = AccountRefreshRoute(
                isDemo: sample.0,
                serverMonitoringEnabled: sample.3,
                remoteOnly: sample.1,
                hasLocalCredentials: sample.4,
                workerIsCredentialAuthority: sample.2
            )
            XCTAssertEqual(
                WidgetRefreshPlan.pollsOnDevice(
                    isDemo: sample.0,
                    remoteOnly: sample.1,
                    workerIsCredentialAuthority: sample.2,
                    serverMonitoringEnabled: sample.3,
                    hasLocalCredentials: sample.4
                ),
                route == .provider,
                "demo=\(sample.0) remote=\(sample.1) workerAuthority=\(sample.2) server=\(sample.3) credentials=\(sample.4)"
            )
        }
    }

    func testStaleAccountsAreRefetchedAndFreshOnesAreLeftAlone() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let staleID = UUID()
        let freshID = UUID()
        let missingID = UUID()
        let accounts = [staleID, freshID, missingID].map { sampleAccount(id: $0) }
        let snapshots = [
            sampleSnapshot(accountID: staleID, usedPercent: 10, fetchedAt: now.addingTimeInterval(-16 * 60)),
            sampleSnapshot(accountID: freshID, usedPercent: 20, fetchedAt: now.addingTimeInterval(-5 * 60))
        ]
        let stale = WidgetRefreshPlan.staleAccountIDs(
            accounts: accounts,
            snapshots: snapshots,
            now: now,
            minimumInterval: WidgetRefreshPlan.defaultMinimumInterval
        )
        XCTAssertEqual(stale, [staleID, missingID])
    }

    func testMergeReplacesFetchedUsageAndKeepsTheRest() {
        let keptID = UUID()
        let updatedID = UUID()
        let existing = [
            sampleSnapshot(accountID: keptID, usedPercent: 11, fetchedAt: .distantPast),
            sampleSnapshot(accountID: updatedID, usedPercent: 22, fetchedAt: .distantPast)
        ]
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let updated = sampleSnapshot(accountID: updatedID, usedPercent: 64, fetchedAt: fetchedAt)
        let merged = WidgetSnapshotMerge.merging(existing: existing, updates: [updatedID: updated])
        XCTAssertEqual(merged.map(\.accountID), [keptID, updatedID])
        XCTAssertEqual(merged[0].primary?.usedPercent, 11)
        XCTAssertEqual(merged[1].primary?.usedPercent, 64)
        XCTAssertEqual(merged[1].fetchedAt, fetchedAt)
    }

    func testUnknownSettingsDoNotRestoreAHiddenMetric() {
        let accountID = UUID()
        let previous = sampleSnapshot(accountID: accountID, usedPercent: 10, fetchedAt: .distantPast)
        var updated = sampleSnapshot(accountID: accountID, usedPercent: 40, fetchedAt: .now)
        updated.secondary = UsageWindow(
            title: "Weekly limit",
            usedPercent: 80,
            resetsAt: Date(timeIntervalSince1970: 1_800_086_400),
            windowMinutes: 10_080,
            kind: .weekly
        )
        let preserved = WidgetSnapshotMerge.preservingOmittedMetrics(updated: updated, previous: previous)
        XCTAssertEqual(preserved.primary?.usedPercent, 40)
        XCTAssertNil(preserved.secondary)
    }

    func testManifestRoundTripKeepsFiltersAndInterval() throws {
        let id = UUID()
        var settings = AccountMonitorSettings()
        settings.hiddenMetricIDs = ["weekly"]
        settings.monitorOnSelfHostedServer = true
        let manifest = WidgetRefreshManifest(
            accounts: [sampleAccount(id: id)],
            settingsByAccountID: [id.uuidString: settings],
            minimumInterval: 1_800
        )
        let decoded = try JSONDecoder().decode(
            WidgetRefreshManifest.self,
            from: JSONEncoder().encode(manifest)
        )
        XCTAssertEqual(decoded, manifest)
    }

    func testBackgroundGenerationReportsAWriteAfterItIsArmed() {
        let counter = SnapshotPublishCounter()
        let generation = BackgroundRefreshGeneration()
        generation.arm(counter)
        XCTAssertFalse(generation.didPersist())
        counter.increment()
        XCTAssertTrue(generation.didPersist())
    }

    private func sampleAccount(id: UUID) -> MonitoredAccount {
        MonitoredAccount(
            id: id,
            providerID: .chatGPT,
            displayName: "ChatGPT",
            workspaceID: "workspace",
            plan: "Plus",
            addedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func sampleSnapshot(accountID: UUID, usedPercent: Double, fetchedAt: Date) -> UsageSnapshot {
        UsageSnapshot(
            accountID: accountID,
            providerName: "ChatGPT",
            accountName: "ChatGPT",
            accountProviderID: .chatGPT,
            plan: "Plus",
            primary: UsageWindow(
                title: "5h limit",
                usedPercent: usedPercent,
                resetsAt: fetchedAt.addingTimeInterval(18_000),
                windowMinutes: 300,
                kind: .fiveHour
            ),
            secondary: nil,
            availableResetCount: 0,
            resetCredits: [],
            fetchedAt: fetchedAt
        )
    }
}
