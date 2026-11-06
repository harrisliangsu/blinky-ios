import XCTest
@testable import WhenReset

final class ZAIProviderTests: XCTestCase {
    func testQuotaResponseBuildsFiveHourWeeklyAndMonthlyWindows() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let data = Data(#"""
        {
          "code": 200,
          "success": true,
          "data": {
            "planName": "Pro",
            "limits": [
              {
                "type": "TOKENS_LIMIT",
                "unit": 3,
                "number": 5,
                "usage": 400,
                "currentValue": 100,
                "remaining": 300,
                "percentage": 1,
                "nextResetTime": 1800000000000
              },
              {
                "type": "TOKENS_LIMIT",
                "unit": 6,
                "number": 1,
                "usage": "2000",
                "currentValue": "500",
                "remaining": "1500",
                "percentage": 1,
                "nextResetTime": "1800604800000"
              },
              {
                "type": "TIME_LIMIT",
                "unit": 5,
                "number": 1,
                "percentage": 40,
                "nextResetTime": 1802592000000
              }
            ]
          }
        }
        """#.utf8)
        let account = MonitoredAccount(id: UUID(), providerID: .zai, displayName: "Z.AI account",
                                       workspaceID: "zai-test", plan: nil, addedAt: now)

        let snapshot = try ZAIProvider.parseUsage(account: account, data: data, now: now)

        XCTAssertEqual(snapshot.providerName, "z.ai")
        XCTAssertEqual(snapshot.accountProviderID, .zai)
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(snapshot.primary?.metricID, "zai:five_hour")
        XCTAssertEqual(snapshot.primary?.windowMinutes, 300)
        XCTAssertEqual(snapshot.primary?.usedPercent, 25)
        XCTAssertEqual(snapshot.secondary?.metricID, "zai:weekly")
        XCTAssertEqual(snapshot.secondary?.windowMinutes, 10_080)
        XCTAssertEqual(snapshot.secondary?.usedPercent, 25)
        XCTAssertEqual(snapshot.extraWindows?.first?.displayTitle, "Monthly MCP limit")
        XCTAssertEqual(snapshot.extraWindows?.first?.metricID, "zai:mcp:5:1")
        XCTAssertEqual(snapshot.extraWindows?.first?.usedPercent, 40)
        XCTAssertEqual(snapshot.availableResetCount, 0)
        XCTAssertTrue(snapshot.resetCredits.isEmpty)
    }

    func testQuotaDocumentDoesNotInventResetCards() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let data = Data(#"""
        {
          "code": 200,
          "success": true,
          "data": {
            "level": "max",
            "limits": [{
              "type": "TOKENS_LIMIT",
              "unit": 3,
              "number": 5,
              "percentage": 11,
              "nextResetTime": 1800000000000
            }]
          }
        }
        """#.utf8)
        let account = MonitoredAccount(id: UUID(), providerID: .zhipu, displayName: "智谱",
                                       workspaceID: "zhipu-test", plan: nil, addedAt: now)
        let snapshot = try ZAIProvider.parseUsage(account: account, data: data, now: now)
        XCTAssertEqual(snapshot.availableResetCount, 0)
        XCTAssertNil(ZAIProvider.parseResetInventory(data: data, now: now))
    }

    func testResetInventoryParsesAvailableCardsAndDropsSpentOrExpiredOnes() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let data = Data(#"""
        {
          "code": 200,
          "success": true,
          "data": {
            "customerId": 41,
            "targetType": "PERSONAL",
            "fiveHourResets": [
              { "recordId": 1, "expireTime": "2023-10-18 23:59:59", "available": false },
              { "recordId": 2, "expireTime": "2023-11-07 23:59:59", "available": true },
              { "recordId": 3, "expireTime": "2026-11-07 15:59:59", "available": true }
            ],
            "weekResets": [
              { "recordId": 9, "expireTime": "2026-12-01 08:00:00", "available": true, "grantType": "GLOBAL" }
            ]
          }
        }
        """#.utf8)
        let credits = try XCTUnwrap(ZAIProvider.parseResetInventory(data: data, now: now))
        XCTAssertEqual(credits.map(\.id), [
            "zai-reset-fiveHourResets-3",
            "zai-reset-weekResets-9",
        ])
        XCTAssertEqual(credits.map(\.resetWindow), ["FIVE_HOUR", "WEEK"])
        XCTAssertEqual(credits.map(\.providerRecordID), ["3", "9"])
        XCTAssertEqual(credits.map(\.grantType), ["GLOBAL", "GLOBAL"])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let soonest = try XCTUnwrap(credits[0].expiresAt)
        XCTAssertEqual(calendar.component(.year, from: soonest), 2026)
        XCTAssertEqual(calendar.component(.month, from: soonest), 11)
        XCTAssertEqual(calendar.component(.day, from: soonest), 7)
        XCTAssertEqual(calendar.component(.hour, from: soonest), 15)
        XCTAssertEqual(calendar.component(.minute, from: soonest), 59)

        let resetURL = try XCTUnwrap(ZAIProvider.resetListURL(quotaURL: ZAIProvider.mainlandQuotaURL))
        let parts = try XCTUnwrap(URLComponents(url: resetURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(resetURL.host, "open.bigmodel.cn")
        XCTAssertEqual(resetURL.path, "/api/biz/customer-package-reset/list")
        XCTAssertEqual(parts.queryItems, [URLQueryItem(name: "targetType", value: "PERSONAL")])
        XCTAssertEqual(
            ZAIProvider.resetListURL(quotaURL: ZAIProvider.globalQuotaURL)?.host,
            "api.z.ai"
        )
        XCTAssertNil(ZAIProvider.resetListURL(quotaURL: URL(string: "https://evil.example/quota")!))
        XCTAssertTrue(ProviderID.zhipu.supportsBankedResets)
        XCTAssertTrue(ProviderID.zai.supportsBankedResets)
        XCTAssertFalse(ProviderID.kimi.supportsBankedResets)
    }

    func testCreditLimitRowsBecomeFiveHourAndWeeklyWindows() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let data = Data(#"""
        {
          "code": 200,
          "success": true,
          "data": {
            "level": "max",
            "limits": [
              {
                "type": "CREDIT_LIMIT",
                "unit": 3,
                "number": 5,
                "usage": 28000,
                "currentValue": 2585,
                "percentage": 9,
                "nextResetTime": 1800000000000
              },
              {
                "type": "CREDIT_LIMIT",
                "unit": 6,
                "number": 1,
                "percentage": 41
              }
            ]
          }
        }
        """#.utf8)
        let account = MonitoredAccount(id: UUID(), providerID: .zhipu, displayName: "智谱",
                                       workspaceID: "zhipu-test", plan: nil, addedAt: now)
        let snapshot = try ZAIProvider.parseUsage(account: account, data: data, now: now)
        XCTAssertEqual(snapshot.providerName, "智谱")
        XCTAssertEqual(snapshot.plan, "Max")
        XCTAssertEqual(snapshot.primary?.metricID, "zai:five_hour")
        XCTAssertTrue(snapshot.primary?.reportsReset == true)
        XCTAssertEqual(snapshot.secondary?.metricID, "zai:weekly")
        XCTAssertEqual(snapshot.secondary?.reportsReset, false)
        XCTAssertEqual(snapshot.secondary?.usedPercent, 41)
    }

    func testWebAuthorizeURLStaysOnTheStorefront() throws {
        let mainland = Data(#"""
        {"code":0,"data":{"flow_id":"abc","authorize_url":"https://bigmodel.cn/login?appId=zcode","poll_interval_sec":2,"expires_at":1793596569}}
        """#.utf8)
        let link = try ZAIProvider.webLink(from: mainland, pollToken: "token", storefront: .mainland)
        XCTAssertEqual(link.verificationURL.host, "bigmodel.cn")
        let evil = Data(#"""
        {"code":0,"data":{"flow_id":"abc","authorize_url":"https://evil.example/login","expires_at":1793596569}}
        """#.utf8)
        XCTAssertThrowsError(try ZAIProvider.webLink(from: evil, pollToken: "token", storefront: .mainland))
    }

    func testQuotaWithoutFutureResetIsRejected() throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let data = Data(#"""
        {
          "code": 200,
          "success": true,
          "data": {
            "limits": [{
              "type": "TOKENS_LIMIT",
              "unit": 3,
              "number": 5,
              "percentage": 10,
              "nextResetTime": 1000
            }]
          }
        }
        """#.utf8)
        let account = MonitoredAccount(id: UUID(), providerID: .zai, displayName: "Z.AI account",
                                       workspaceID: "zai-test", plan: nil, addedAt: now)

        XCTAssertThrowsError(try ZAIProvider.parseUsage(account: account, data: data, now: now)) { error in
            guard case ZAIProviderError.noResettableQuota = error else {
                return XCTFail("Expected noResettableQuota, got \(error)")
            }
        }
    }

    func testInvalidEnvelopeIsRejected() {
        let data = Data(#"{"code":401,"success":false,"data":null}"#.utf8)
        let account = MonitoredAccount(id: UUID(), providerID: .zai, displayName: "Z.AI account",
                                       workspaceID: "zai-test", plan: nil, addedAt: .now)

        XCTAssertThrowsError(try ZAIProvider.parseUsage(account: account, data: data))
    }

    func testHTTPSuccessEnvelopeWithoutQuotaIsNotAccepted() {
        XCTAssertFalse(ZAIProvider.envelopeAccepted(Data(#"{"code":401,"success":false,"msg":"invalid api key"}"#.utf8)))
        XCTAssertFalse(ZAIProvider.envelopeAccepted(Data(#"{"code":200,"success":true}"#.utf8)))
        XCTAssertTrue(ZAIProvider.envelopeAccepted(Data(#"{"code":200,"success":true,"data":{"limits":[]}}"#.utf8)))
    }

    func testRegionSelectionPinsOneHostAndAutomaticTriesBothUntilPinned() {
        XCTAssertEqual(
            ZAIProvider.candidateURLs(provider: .zai, region: .global, pinnedHost: nil).map(\.host),
            ["api.z.ai"]
        )
        XCTAssertEqual(
            ZAIProvider.candidateURLs(provider: .zhipu, region: .mainland, pinnedHost: nil).map(\.host),
            ["open.bigmodel.cn"]
        )
        XCTAssertEqual(
            ZAIProvider.candidateURLs(region: .mainland, pinnedHost: nil).map(\.absoluteString),
            ["https://open.bigmodel.cn/api/monitor/usage/quota/limit"]
        )
        XCTAssertEqual(
            ZAIProvider.candidateURLs(region: .global, pinnedHost: nil).map(\.host),
            ["api.z.ai"]
        )
        XCTAssertEqual(
            ZAIProvider.candidateURLs(
                provider: .zhipu,
                region: .mainland,
                pinnedHost: "https://open.bigmodel.cn/api/monitor/usage/quota/limit"
            ).map(\.host),
            ["open.bigmodel.cn"]
        )
        XCTAssertEqual(
            ZAIProvider.candidateURLs(region: .automatic, pinnedHost: "https://evil.example/quota"),
            [ZAIProvider.globalQuotaURL]
        )
        XCTAssertEqual(ProviderID.zai.displayName, "z.ai")
        XCTAssertEqual(ProviderID.zhipu.displayName, "智谱")
        XCTAssertEqual(ProviderID.zai.logoAssetName, "ZAILogo")
    }

    func testRedeemPostsTheSoonestCardAndKeepsTheKeyOnTheQuotaHost() async throws {
        let sooner = Date(timeIntervalSince1970: 1_700_000_000)
        let later = Date(timeIntervalSince1970: 1_800_000_000)
        let credits = [
            ResetCredit(id: "later", expiresAt: later, status: "available",
                        providerRecordID: "11", resetWindow: "FIVE_HOUR", grantType: "GLOBAL"),
            ResetCredit(id: "sooner", expiresAt: sooner, status: "available",
                        providerRecordID: "3", resetWindow: "FIVE_HOUR", grantType: nil),
            ResetCredit(id: "week", expiresAt: sooner, status: "available",
                        providerRecordID: "9", resetWindow: "WEEK", grantType: "GLOBAL"),
        ]
        let now = Date(timeIntervalSince1970: 1_600_000_000)
        let use = try XCTUnwrap(ZAIProvider.soonestUse(in: credits, resetType: "FIVE_HOUR", now: now))
        XCTAssertEqual(use, ZAIResetUse(resetType: "FIVE_HOUR", recordID: "3", grantType: "GLOBAL"))
        XCTAssertNil(ZAIProvider.soonestUse(in: credits, resetType: "WEEK", now: later.addingTimeInterval(1)))
        let body = ZAIProvider.useBody(use)
        XCTAssertEqual(body["targetType"] as? String, "PERSONAL")
        XCTAssertEqual(body["resetType"] as? String, "FIVE_HOUR")
        XCTAssertEqual(body["recordId"] as? Int, 3)
        XCTAssertEqual(body["grantType"] as? String, "GLOBAL")
        XCTAssertEqual(body["requestId"] as? String, "")
        XCTAssertEqual(
            ZAIProvider.resetUseURL(quotaURL: ZAIProvider.mainlandQuotaURL)?.path,
            "/api/biz/customer-package-reset/use"
        )
        XCTAssertNil(ZAIProvider.resetUseURL(quotaURL: URL(string: "https://evil.example/quota")!))
        XCTAssertEqual(
            ResetCardUseButton.confirmation(for: use, credits: credits),
            String(format: String(localized: "This resets the %@. %d reset cards of this kind will remain."),
                   String(localized: "5-hour quota"), 1)
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ZAIResetUseStub.self]
        ZAIResetUseStub.responseStatus = 200
        ZAIResetUseStub.responseBody = Data(#"{"code":200,"success":true,"msg":"ok"}"#.utf8)
        ZAIResetUseStub.captured = nil
        ZAIResetUseStub.capturedBody = nil
        let provider = ZAIProvider(session: URLSession(configuration: configuration))
        let apiKey = "test-key-not-real-1234"
        try await provider.redeem(use, apiKey: apiKey, quotaURL: ZAIProvider.mainlandQuotaURL)
        let request = try XCTUnwrap(ZAIResetUseStub.captured)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.host, "open.bigmodel.cn")
        XCTAssertEqual(request.url?.path, "/api/biz/customer-package-reset/use")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(apiKey)")
        let posted = try XCTUnwrap(ZAIResetUseStub.capturedBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: posted) as? [String: Any])
        XCTAssertEqual(json["resetType"] as? String, "FIVE_HOUR")
        XCTAssertEqual(json["recordId"] as? Int, 3)
        XCTAssertNotEqual(request.url?.host, "bigmodel.cn")

        ZAIResetUseStub.responseBody = Data(#"{"code":400,"success":false,"msg":"card already used"}"#.utf8)
        do {
            try await provider.redeem(
                ZAIResetUse(resetType: "WEEK", recordID: "9", grantType: "GLOBAL"),
                apiKey: apiKey,
                quotaURL: ZAIProvider.globalQuotaURL
            )
            XCTFail("A rejected reset card should surface the provider message.")
        } catch let error as ZAIProviderError {
            guard case let .resetRejected(message) = error else {
                return XCTFail("Unexpected error \(error)")
            }
            XCTAssertTrue(message.contains("card already used"))
        }
        XCTAssertEqual(ZAIResetUseStub.captured?.url?.host, "api.z.ai")
    }
}

private final class ZAIResetUseStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseStatus = 200
    nonisolated(unsafe) static var responseBody = Data()
    nonisolated(unsafe) static var captured: URLRequest?
    nonisolated(unsafe) static var capturedBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.captured = request
        Self.capturedBody = Self.body(of: request)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://open.bigmodel.cn/api/biz/customer-package-reset/use")!,
            statusCode: Self.responseStatus,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession often moves `httpBody` onto the stream before a protocol sees it.
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1024)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 1024)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
