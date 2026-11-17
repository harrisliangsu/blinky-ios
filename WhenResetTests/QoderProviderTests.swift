import XCTest
@testable import WhenReset

final class QoderProviderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testMixedSpellingBuildsAllowanceAndFutureReset() throws {
        let data = Data(#"""
        {
          "quotaKey": "big_model_credits",
          "nextResetAt": "2030-01-01T00:00:00Z",
          "total_quota": {
            "quota_summary": { "used_value": 125, "limit_value": 500, "remaining_value": 375 }
          },
          "sharedQuota": {
            "quotaSummary": { "usedValue": 200, "limitValue": 1000, "remainingValue": 800 }
          }
        }
        """#.utf8)
        let snapshot = try QoderProvider.parseUsage(
            account: makeQoderAccount(),
            data: data,
            now: now
        )

        XCTAssertEqual(snapshot.primary?.metricID, "qoder.credits")
        XCTAssertEqual(snapshot.primary?.usedPercent, 25)
        XCTAssertEqual(snapshot.primary?.reportsReset, true)
        XCTAssertEqual(snapshot.primary?.resetsAt, Date(timeIntervalSince1970: 1_893_456_000))
        XCTAssertNil(snapshot.primary?.windowMinutes)
        XCTAssertEqual(snapshot.secondary?.metricID, "qoder.shared")
        XCTAssertEqual(snapshot.secondary?.usedPercent, 20)
        XCTAssertEqual(snapshot.secondary?.reportsReset, false)
        XCTAssertEqual(ScheduledResetCadence.classify(snapshot.primary!), .other)
        XCTAssertNil(ScheduledResetCadence.classify(snapshot.secondary!))
    }

    func testStaleResetIsDroppedAndZeroPoolIsOmitted() throws {
        let data = Data(#"""
        {
          "next_reset_at": 1700000000000,
          "totalQuota": {
            "quotaSummary": { "usedValue": 10, "limitValue": 100, "remainingValue": 90 }
          },
          "shared_quota": {
            "quota_summary": { "used_value": 0, "limit_value": 0, "remaining_value": 0 }
          }
        }
        """#.utf8)
        let snapshot = try QoderProvider.parseUsage(account: makeQoderAccount(), data: data, now: now)
        XCTAssertEqual(snapshot.primary?.reportsReset, false)
        XCTAssertEqual(snapshot.primary?.usedPercent, 10)
        XCTAssertNil(snapshot.secondary)

        let zeroPersonal = Data(#"""
        {
          "totalQuota": { "quotaSummary": { "usedValue": 0, "limitValue": 0, "remainingValue": 0 } },
          "sharedQuota": { "quotaSummary": { "usedValue": 5, "limitValue": 20, "remainingValue": 15 } }
        }
        """#.utf8)
        let sharedOnly = try QoderProvider.parseUsage(
            account: makeQoderAccount(), data: zeroPersonal, now: now
        )
        XCTAssertEqual(sharedOnly.primary?.metricID, "qoder.shared")
        XCTAssertNil(sharedOnly.secondary)

        XCTAssertThrowsError(try QoderProvider.parseUsage(
            account: makeQoderAccount(),
            data: Data(#"{"totalQuota":{"quotaSummary":{"usedValue":0,"limitValue":0,"remainingValue":0}}}"#.utf8),
            now: now
        ))
    }

    func testMalformedSharedQuotaIsNotTreatedAsNoTeamPool() {
        let data = Data(#"""
        { "totalQuota": { "quotaSummary": { "usedValue": 1, "limitValue": 2, "remainingValue": 1 } },
          "sharedQuota": { "quotaSummary": { "usedValue": "nope" } } }
        """#.utf8)
        XCTAssertThrowsError(try QoderProvider.parseUsage(account: makeQoderAccount(), data: data, now: now))
    }

    func testPersonalTokenAndCookieNormalization() throws {
        XCTAssertEqual(QoderProvider.accessToken(in: " pt-example-token "), "pt-example-token")
        XCTAssertEqual(QoderProvider.accessToken(in: "jt-job"), "jt-job")
        XCTAssertNil(QoderProvider.accessToken(in: "session=abc"))

        let cookie = try QoderProvider.normalizedCookie(
            "Cookie: session=abc; _ga=1; cna=keep; session=second; bad"
        )
        XCTAssertEqual(cookie, "session=abc; cna=keep")
        XCTAssertThrowsError(try QoderProvider.normalizedCookie("Cookie: _ga=1"))
        XCTAssertEqual(try QoderProvider.credential("pt-live"), "pt-live")
    }

    func testProviderSearchMatchesChineseAndEnglish() {
        XCTAssertTrue(ProviderSearch.matches(.chatGPT, query: "  chatgpt "))
        XCTAssertTrue(ProviderSearch.matches(.zhipu, query: "智谱"))
        XCTAssertTrue(ProviderSearch.matches(.chatGPT, query: "用量额度"))
        XCTAssertTrue(ProviderSearch.matches(.qoder, query: "QODER"))
        XCTAssertTrue(ProviderSearch.matches(.qoder, query: "积分"))
        XCTAssertFalse(ProviderSearch.matches(.claude, query: "qoder"))
        XCTAssertTrue(ProviderSearch.matches(.kimi, query: ""))
    }

    private func makeQoderAccount() -> MonitoredAccount {
        MonitoredAccount(
            id: UUID(),
            providerID: .qoder,
            displayName: "Qoder",
            workspaceID: "qoder-test",
            plan: nil,
            addedAt: now
        )
    }
}

final class ScheduledResetCadenceTests: XCTestCase {
    func testLegacyScheduledSwitchEnablesEveryCadence() throws {
        let decoded = try JSONDecoder().decode(
            GlobalNotificationSettings.self,
            from: Data(#"{"notifyAtScheduledReset":true}"#.utf8)
        )
        XCTAssertTrue(decoded.notifyAtHourlyReset)
        XCTAssertTrue(decoded.notifyAtDailyReset)
        XCTAssertTrue(decoded.notifyAtWeeklyReset)
        XCTAssertTrue(decoded.notifyAtMonthlyReset)
        XCTAssertTrue(decoded.notifyAtOtherScheduledReset)

        let off = try JSONDecoder().decode(
            GlobalNotificationSettings.self,
            from: Data("{}".utf8)
        )
        XCTAssertFalse(off.notifyAtScheduledReset)
    }

    func testExplicitCadenceOverridesLegacySwitch() throws {
        let decoded = try JSONDecoder().decode(
            GlobalNotificationSettings.self,
            from: Data(#"""
            {"notifyAtScheduledReset":true,"notifyAtHourlyReset":false,"notifyAtWeeklyReset":true,"notifyAtDailyReset":false,"notifyAtMonthlyReset":false,"notifyAtOtherScheduledReset":false}
            """#.utf8)
        )
        XCTAssertFalse(decoded.notifyAtHourlyReset)
        XCTAssertTrue(decoded.notifyAtWeeklyReset)
        XCTAssertTrue(decoded.notifyAtScheduledReset)
    }

    func testPlannerKeepsOnlyTheEnabledCadence() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let account = MonitoredAccount(
            id: UUID(), providerID: .claude, displayName: "Claude",
            workspaceID: "workspace", plan: "Max", addedAt: now
        )
        let weekly = UsageWindow(
            title: "Weekly", usedPercent: 10,
            resetsAt: now.addingTimeInterval(7_200), windowMinutes: 10_080, kind: .weekly
        )
        let hourly = UsageWindow(
            title: "5-hour", usedPercent: 20,
            resetsAt: now.addingTimeInterval(1_800), windowMinutes: 300, kind: .fiveHour
        )
        let monthly = UsageWindow(
            title: "Monthly credits", usedPercent: 5,
            resetsAt: now.addingTimeInterval(9_000), windowMinutes: nil,
            kind: .additional, identifier: "warp:monthly_credits"
        )
        let snapshot = UsageSnapshot(
            accountID: account.id, providerName: "Claude", accountName: account.displayName,
            plan: account.plan, primary: weekly, secondary: hourly,
            availableResetCount: 0, resetCredits: [], fetchedAt: now,
            extraWindows: [monthly]
        )
        var settings = GlobalNotificationSettings()
        settings.notifyAtHourlyReset = true
        let targets = ScheduledResetNotificationPlanner.targets(
            accounts: [account], snapshots: [account.id: snapshot],
            globalSettings: settings, now: now
        )
        XCTAssertEqual(targets.map(\.cadence), [.hourly])
        XCTAssertEqual(targets.map(\.metricID), [hourly.metricID])
        XCTAssertEqual(
            ScheduledResetCadence.classify(monthly),
            .monthly
        )
        XCTAssertEqual(ScheduledResetCadence.classify(UsageWindow(
            title: "Daily cap", usedPercent: 1,
            resetsAt: now.addingTimeInterval(100), windowMinutes: 1_440, kind: .additional
        )), .daily)
    }
}
