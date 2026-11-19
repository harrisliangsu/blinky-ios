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
}
