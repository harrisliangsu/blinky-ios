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

    func testPastedTokenIsNotANewSession() throws {
        XCTAssertThrowsError(try QoderProvider.sessionCredential("pt-live"))
        XCTAssertThrowsError(try QoderProvider.sessionCredential(" jt-job "))
        XCTAssertThrowsError(try QoderProvider.sessionCredential("pt-example-token"))
        XCTAssertNil(QoderProvider.accessToken(in: "session=abc"))

        let stored = try QoderProvider.usageRequest(credential: "pt-stored", site: .international)
        XCTAssertEqual(stored.value(forHTTPHeaderField: "Authorization"), "Bearer pt-stored")
        XCTAssertNil(stored.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(stored.url?.host, "qoder.com")

        let session = try QoderProvider.usageRequest(credential: "session=abc; cna=keep", site: .china)
        XCTAssertEqual(session.value(forHTTPHeaderField: "Cookie"), "session=abc; cna=keep")
        XCTAssertNil(session.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(session.url?.host, "qoder.com.cn")
        XCTAssertEqual(session.value(forHTTPHeaderField: "Origin"), "https://qoder.com.cn")
        XCTAssertEqual(session.value(forHTTPHeaderField: "Referer"), "https://qoder.com.cn/account/usage")
        XCTAssertEqual(session.value(forHTTPHeaderField: "Bx-V"), "2.5.35")
    }

    func testCookieNormalizationDropsAnalyticsAndKeepsAlibaba() throws {
        let cookie = try QoderProvider.normalizedCookie(
            "Cookie: session=abc; _ga=1; _gcl_au=drop; Hm_lvt=drop; cna=keep; isg=keep; tfstk=keep; session=second; bad"
        )
        XCTAssertEqual(cookie, "session=abc; cna=keep; isg=keep; tfstk=keep")
        XCTAssertThrowsError(try QoderProvider.normalizedCookie("Cookie: _ga=1"))
        XCTAssertThrowsError(try QoderProvider.normalizedCookie("session=ab\nc"))
        XCTAssertThrowsError(try QoderProvider.sessionCredential(""))
        XCTAssertEqual(try QoderProvider.sessionCredential("Cookie: session=abc; _fbp=1"), "session=abc")
    }

    func testBrowserCookiesStayOnTheChosenSite() throws {
        let cookies = [
            try cookie("session", "intl", domain: "qoder.com"),
            try cookie("qoder_csrf_token", "csrf", domain: "qoder.com"),
            try cookie("_ga", "analytics", domain: "qoder.com"),
            try cookie("cna", "alibaba", domain: "qoder.com"),
            try cookie("edge", "sub", domain: "api.qoder.com"),
            try cookie("session", "cn", domain: "qoder.com.cn"),
            try cookie("acw_tc", "waf", domain: "qoder.com.cn"),
        ]
        let international = try QoderBrowserSession.header(from: cookies, site: .international)
        XCTAssertEqual(international, "session=intl; qoder_csrf_token=csrf; cna=alibaba; edge=sub")
        XCTAssertFalse(international.contains("=cn"))
        XCTAssertFalse(international.contains("acw_tc"))

        let china = try QoderBrowserSession.header(from: cookies, site: .china)
        XCTAssertEqual(china, "session=cn; acw_tc=waf")
        XCTAssertFalse(china.contains("intl"))
        XCTAssertFalse(china.contains("csrf"))

        XCTAssertThrowsError(try QoderBrowserSession.header(from: [
            try cookie("_ga", "1", domain: "qoder.com"),
            try cookie("session", "cn", domain: "qoder.com.cn"),
        ], site: .international))
        XCTAssertThrowsError(try QoderBrowserSession.header(from: [
            try cookie("qoder_csrf_token", "csrf", domain: "qoder.com"),
            try cookie("acw_tc", "waf", domain: "qoder.com"),
        ], site: .international))
    }

    func testSignedInPageIsTheAccountUsagePageForThatSite() {
        XCTAssertEqual(QoderSite.international.signInURL.absoluteString, "https://qoder.com/account/usage")
        XCTAssertEqual(QoderSite.china.signInURL.absoluteString, "https://qoder.com.cn/account/usage")
        XCTAssertTrue(QoderBrowserSession.isSignedInAccountPage(
            URL(string: "https://qoder.com/account/usage")!, site: .international
        ))
        XCTAssertTrue(QoderBrowserSession.isSignedInAccountPage(
            URL(string: "https://qoder.com/account/usage/?from=sign-in")!, site: .international
        ))
        XCTAssertTrue(QoderBrowserSession.isSignedInAccountPage(
            URL(string: "https://www.qoder.com/account/usage")!, site: .international
        ))
        XCTAssertFalse(QoderBrowserSession.isSignedInAccountPage(
            URL(string: "https://qoder.com/users/sign-in?oauth_callback=https%3A%2F%2Fqoder.com%2Faccount%2Fusage")!,
            site: .international
        ))
        XCTAssertFalse(QoderBrowserSession.isSignedInAccountPage(
            URL(string: "https://qoder.com.cn/account/usage")!, site: .international
        ))
        XCTAssertTrue(QoderBrowserSession.isSignedInAccountPage(
            URL(string: "https://qoder.com.cn/account/usage")!, site: .china
        ))
        XCTAssertFalse(QoderBrowserSession.isSignedInAccountPage(
            URL(string: "https://qoder.com/account/usage")!, site: .china
        ))
        XCTAssertFalse(QoderBrowserSession.isSignedInAccountPage(
            URL(string: "https://notqoder.com/account/usage")!, site: .international
        ))
        XCTAssertFalse(QoderBrowserSession.isSignedInAccountPage(
            URL(string: "https://evil.qoder.com.example/account/usage")!, site: .international
        ))
        XCTAssertFalse(QoderBrowserSession.isSignedInAccountPage(
            URL(string: "http://qoder.com/account/usage")!, site: .international
        ))
        XCTAssertFalse(QoderSite.owns(host: "qoder.com.cn", site: .international))
        XCTAssertFalse(QoderSite.owns(host: ".qoder.com", site: .china))
        XCTAssertTrue(QoderSite.owns(host: "api.qoder.com", site: .international))
        XCTAssertTrue(QoderSite.owns(host: ".qoder.com.cn", site: .china))
        XCTAssertNil(QoderSite.retainedSession("session=abc", from: .international, to: .china))
        XCTAssertEqual(QoderSite.retainedSession("session=abc", from: .china, to: .china), "session=abc")
        XCTAssertEqual(ProviderID.qoder.logoAssetName, "QoderLogo")
    }

    private func cookie(_ name: String, _ value: String, domain: String) throws -> HTTPCookie {
        let properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: "/",
        ]
        return try XCTUnwrap(HTTPCookie(properties: properties))
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
