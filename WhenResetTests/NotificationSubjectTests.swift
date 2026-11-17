import XCTest
@testable import WhenReset

final class NotificationSubjectTests: XCTestCase {
    func testOneAccountUsesTheProviderName() {
        let account = make("person@example.com", provider: .chatGPT, email: "person@example.com")
        XCTAssertEqual(NotificationAccountLabel.subject(for: account, among: [account]), "ChatGPT")
        XCTAssertFalse(
            NotificationAccountLabel.subject(for: account, among: [account]).contains("@")
        )
    }

    func testSecondAccountOfTheSameProviderAddsItsLabel() {
        let home = make("person@example.com", provider: .chatGPT, email: "person@example.com")
        var work = make("other@example.com", provider: .chatGPT, email: "other@example.com")
        work.customDisplayName = "Home"
        let subject = NotificationAccountLabel.subject(for: work, among: [home, work])
        XCTAssertEqual(subject, "ChatGPT（Home）")
        XCTAssertFalse(subject.contains("other@example.com"))
    }

    func testAnotherProvidersAccountDoesNotForceALabel() {
        let chat = make("person@example.com", provider: .chatGPT, email: "person@example.com")
        let claude = make("claude@example.com", provider: .claude, email: "claude@example.com")
        XCTAssertEqual(NotificationAccountLabel.subject(for: chat, among: [chat, claude]), "ChatGPT")
        XCTAssertEqual(NotificationAccountLabel.subject(for: claude, among: [chat, claude]), "Claude")
    }

    func testLabelThatAlreadyNamesTheProviderIsNotRepeated() {
        var account = make("person@example.com", provider: .chatGPT, email: "person@example.com")
        account.customDisplayName = "ChatGPT Home"
        let other = make("other@example.com", provider: .chatGPT, email: "other@example.com")
        XCTAssertEqual(
            NotificationAccountLabel.subject(for: account, among: [account, other]),
            "ChatGPT Home"
        )
    }

    func testSecretAndWorkspaceIdentifiersAreNotLabels() {
        var account = make(
            "00000000-0000-0000-0000-000000000001",
            provider: .chatGPT,
            email: nil
        )
        account.workspaceID = "sk-live-secret-value-that-must-not-appear-in-a-notification"
        account.displayName = account.workspaceID
        let other = make("other@example.com", provider: .chatGPT, email: "other@example.com")
        let subject = NotificationAccountLabel.subject(for: account, among: [account, other])
        XCTAssertFalse(subject.contains("sk-live"))
        XCTAssertFalse(subject.contains("00000000"))
        XCTAssertTrue(subject.hasPrefix("ChatGPT（"))
    }

    func testPendingResetUsesProviderThenLabelThenProviderAgain() async throws {
        let store = try makeStore()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        var account = make("person@example.com", provider: .chatGPT, email: "person@example.com")
        account.addedAt = start
        let baseline = snapshot(account, at: start, remaining: 10, reset: start.addingTimeInterval(30 * 60))
        _ = try await store.record(snapshot: baseline, account: account, source: .background, roster: [account], now: start)

        let observed = start.addingTimeInterval(60 * 60)
        let reset = snapshot(account, at: observed, remaining: 100, reset: observed.addingTimeInterval(7 * 86_400))
        let recorded = try await store.record(
            snapshot: reset, account: account, source: .background, roster: [account], now: observed
        )
        let event = try XCTUnwrap(recorded.pendingNotifications.first { $0.kind == .quotaReset })
        XCTAssertTrue(event.body.hasPrefix("ChatGPT"))
        XCTAssertFalse(event.body.contains("person@example.com"))
        XCTAssertTrue(event.body.contains("100%"))

        var renamed = account
        renamed.customDisplayName = "Home"
        let second = make("other@example.com", provider: .chatGPT, email: "other@example.com")
        try await store.relabelPendingNotifications(accounts: [renamed, second], now: observed)
        let labeled = try await store.load(now: observed).pendingNotifications.first { $0.id == event.id }
        XCTAssertEqual(labeled?.body.contains("ChatGPT（Home）"), true)
        XCTAssertFalse(labeled?.body.contains("person@example.com") ?? true)

        try await store.relabelPendingNotifications(accounts: [renamed], now: observed)
        let single = try await store.load(now: observed).pendingNotifications.first { $0.id == event.id }
        XCTAssertTrue(single?.body.hasPrefix("ChatGPT") ?? false)
        XCTAssertFalse(single?.body.contains("Home") ?? true)
        XCTAssertFalse(single?.body.contains("（") ?? true)
    }

    func testScheduledResetUsesTheCurrentSubject() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var account = make("person@example.com", provider: .chatGPT, email: "person@example.com")
        account.addedAt = now
        let window = UsageWindow(
            title: "Weekly", usedPercent: 30,
            resetsAt: now.addingTimeInterval(3_600), windowMinutes: 10_080,
            kind: .weekly
        )
        let usage = UsageSnapshot(
            accountID: account.id, providerName: "ChatGPT", accountName: account.displayName,
            plan: nil, primary: window, secondary: nil,
            availableResetCount: 0, resetCredits: [], fetchedAt: now
        )
        let alone = ScheduledResetNotificationPlanner.targets(
            accounts: [account], snapshots: [account.id: usage],
            globalSettings: .init(notifyAtScheduledReset: true), now: now
        )
        XCTAssertEqual(alone.first?.accountName, "ChatGPT")

        var renamed = account
        renamed.customDisplayName = "Home"
        let other = make("other@example.com", provider: .chatGPT, email: "other@example.com")
        let otherWindow = UsageWindow(
            title: "Weekly", usedPercent: 10,
            resetsAt: now.addingTimeInterval(7_200), windowMinutes: 10_080,
            kind: .weekly
        )
        let otherUsage = UsageSnapshot(
            accountID: other.id, providerName: "ChatGPT", accountName: other.displayName,
            plan: nil, primary: otherWindow, secondary: nil,
            availableResetCount: 0, resetCredits: [], fetchedAt: now
        )
        let both = ScheduledResetNotificationPlanner.targets(
            accounts: [renamed, other],
            snapshots: [renamed.id: usage, other.id: otherUsage],
            globalSettings: .init(notifyAtScheduledReset: true), now: now
        )
        XCTAssertEqual(both.first { $0.accountID == renamed.id }?.accountName, "ChatGPT（Home）")

        let removed = ScheduledResetNotificationPlanner.targets(
            accounts: [other], snapshots: [other.id: otherUsage],
            globalSettings: .init(notifyAtScheduledReset: true), now: now
        )
        XCTAssertEqual(removed.map(\.accountID), [other.id])
        XCTAssertEqual(removed.first?.accountName, "ChatGPT")
    }

    private func makeStore() throws -> UsageHistoryStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notification-subject-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return UsageHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
    }

    private func make(
        _ name: String,
        provider: ProviderID,
        email: String?
    ) -> MonitoredAccount {
        var account = MonitoredAccount(
            id: UUID(), providerID: provider, displayName: name,
            workspaceID: "workspace-\(UUID().uuidString)", plan: nil, addedAt: .now
        )
        account.email = email
        return account
    }

    private func snapshot(
        _ account: MonitoredAccount,
        at date: Date,
        remaining: Double,
        reset: Date
    ) -> UsageSnapshot {
        UsageSnapshot(
            accountID: account.id,
            providerName: account.providerID.displayName,
            accountName: account.displayName,
            accountProviderID: account.providerID,
            plan: account.plan,
            primary: nil,
            secondary: UsageWindow(
                title: "Weekly limit",
                usedPercent: 100 - remaining,
                resetsAt: reset,
                windowMinutes: 10_080,
                kind: .weekly,
                identifier: "weekly"
            ),
            availableResetCount: 0,
            resetCredits: [],
            fetchedAt: date
        )
    }
}

final class AccountFailurePresentationTests: XCTestCase {
    func testNetworkFailureStaysARetryAndKeepsTheCachedFlag() {
        let failure = AccountRefreshFailure(
            error: URLError(.notConnectedToInternet),
            failedAt: Date(timeIntervalSince1970: 2_000)
        )
        let cached = AccountFailurePresentation.make(failure: failure, hasCachedUsage: true)
        let empty = AccountFailurePresentation.make(failure: failure, hasCachedUsage: false)

        XCTAssertEqual(failure.tone, .network)
        XCTAssertEqual(cached.action, .retry)
        XCTAssertEqual(empty.action, .retry)
        XCTAssertFalse(cached.showsRemoval)
        XCTAssertFalse(empty.showsRemoval)
        XCTAssertTrue(cached.hasCachedUsage)
        XCTAssertFalse(empty.hasCachedUsage)
        XCTAssertEqual(cached.summary, "Couldn't reach the provider.")
        XCTAssertFalse(cached.detail.contains("notConnectedToInternet"))
    }

    func testAuthenticationFailureAsksForSignInAndHidesTheProviderBody() {
        let failure = AccountRefreshFailure(
            error: ProviderError.server(401, "token sk-live-should-not-leak")
        )
        let presentation = AccountFailurePresentation.make(failure: failure, hasCachedUsage: true)

        XCTAssertEqual(failure.tone, .authentication)
        XCTAssertEqual(presentation.action, .signIn)
        XCTAssertFalse(presentation.showsRemoval)
        XCTAssertFalse(presentation.detail.contains("sk-live"))
        XCTAssertEqual(presentation.summary, "Sign-in expired.")
    }

    func testRateLimitIsNotAnAuthenticationFailure() {
        let failure = AccountRefreshFailure(error: ProviderError.server(429, "slow down secret"))
        let presentation = AccountFailurePresentation.make(failure: failure, hasCachedUsage: false)
        XCTAssertEqual(failure.tone, .rateLimited)
        XCTAssertEqual(presentation.action, .retry)
        XCTAssertFalse(presentation.showsRemoval)
        XCTAssertEqual(presentation.summary, "Updates are rate limited.")
        XCTAssertFalse(presentation.detail.contains("secret"))
    }

    func testRepeatTapDoesNotStartASecondRefreshAndCancelClearsIt() {
        var gate = AccountRefreshGate()
        let id = UUID()
        XCTAssertTrue(gate.begin(id))
        XCTAssertFalse(gate.begin(id))
        XCTAssertTrue(gate.inFlight.contains(id))
        gate.finish(id)
        XCTAssertFalse(gate.inFlight.contains(id))
        XCTAssertTrue(gate.begin(id))
        gate.finish(id)
        XCTAssertTrue(gate.inFlight.isEmpty)
    }
}
