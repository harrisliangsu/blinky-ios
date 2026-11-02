import XCTest
@testable import WhenReset

final class TokenActivityTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var today: Date {
        calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func testNoRecordsDrawNothing() {
        let activity = TokenActivity.of(days: [:], now: today, calendar: calendar)
        XCTAssertTrue(activity.isEmpty)
        XCTAssertEqual(activity.total, 0)
        XCTAssertNil(TokenPerformanceTable.make([]))
    }

    func testFutureWorkIsNotDrawn() {
        let future = calendar.date(byAdding: .day, value: 2, to: today)!
        let activity = TokenActivity.of(days: [future: 40], now: today, calendar: calendar)
        XCTAssertTrue(activity.isEmpty)
    }

    func testYearWindowDropsDaysOlderThanTwelveMonths() {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let ancient = calendar.date(byAdding: .year, value: -2, to: today)!
        let activity = TokenActivity.of(
            days: [yesterday: 10, ancient: 999],
            hasPartialCounts: true,
            now: today,
            calendar: calendar
        )
        XCTAssertEqual(activity.total, 10)
        XCTAssertEqual(activity.activeDays, 1)
        XCTAssertTrue(activity.hasPartialCounts)
        XCTAssertFalse(activity.weeks.isEmpty)
        XCTAssertLessThanOrEqual(activity.columnCount, 53)
    }

    func testQuietDayAfterTheFirstRecordIsZero() {
        let earlier = calendar.date(byAdding: .day, value: -2, to: today)!
        let activity = TokenActivity.of(
            days: [earlier: 4, today: 8],
            now: today,
            calendar: calendar
        )
        let drawn = activity.weeks.flatMap(\.drawn)
        let middle = drawn.first { $0.date == calendar.date(byAdding: .day, value: -1, to: today) }
        XCTAssertEqual(middle?.tokens, 0)
        XCTAssertEqual(activity.step(for: 0), 0)
        XCTAssertEqual(activity.total, 12)
    }

    func testPerformanceOmitsEmptyColumnsAndSitsOnlyWhenAFigureExists() {
        XCTAssertNil(TokenPerformanceTable.make([
            TokenPerformanceRow(name: "quiet", cache: nil, input: nil, output: nil, tokensPerSecond: nil)
        ]))
        let table = TokenPerformanceTable.make([
            TokenPerformanceRow(name: "gpt", cache: 20, input: 80, output: 30, tokensPerSecond: 42),
            TokenPerformanceRow(name: "other", cache: nil, input: 5, output: nil, tokensPerSecond: nil),
        ])
        XCTAssertEqual(table?.columns, [.cache, .input, .output, .speed])
        XCTAssertEqual(table?.rows.map(\.name), ["gpt", "other"])
    }

    func testScreenshotSampleCoversAYearAndTheTokenSplit() {
        let sample = ScreenshotLaunch.tokenActivitySample(now: today, calendar: calendar)
        let activity = TokenActivity.of(days: sample.days, now: today, calendar: calendar)
        XCTAssertGreaterThan(activity.total, 1_000_000)
        XCTAssertGreaterThan(activity.activeDays, 200)
        XCTAssertLessThanOrEqual(activity.columnCount, 53)
        let table = TokenPerformanceTable.make(sample.rows)
        XCTAssertEqual(table?.columns, [.cache, .input, .output, .speed])
        XCTAssertEqual(table?.rows.map(\.name), ["Overall", "gpt-5.4", "claude-sonnet", "grok-4"])
        XCTAssertNil(sample.rows.last?.cache)
        XCTAssertNotNil(sample.rows.last?.input)
    }
}
