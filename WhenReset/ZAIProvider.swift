import CryptoKit
import Foundation

enum ZAIRegion: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case global
    case mainland

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic · 自动"
        case .global: "Global · Z.AI"
        case .mainland: "中国大陆 · 智谱 BigModel"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            "Try api.z.ai, then open.bigmodel.cn, and remember the host that accepts this key."
        case .global:
            "International Z.AI only (api.z.ai). A mainland 智谱 key is not sent to the other host."
        case .mainland:
            "中国大陆智谱 BigModel only (open.bigmodel.cn). An international key is not sent to the other host."
        }
    }
}

enum ZAIProviderError: LocalizedError {
    case invalidAPIKey
    case invalidResponse
    case noResettableQuota
    case authorizationFailed(String)
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            "Enter a valid 智谱 GLM / Z.AI Coding Plan API key."
        case .invalidResponse:
            "智谱 GLM returned unreadable Coding Plan quota data."
        case .noResettableQuota:
            "智谱 GLM did not report any resettable Coding Plan limits for this key."
        case let .authorizationFailed(host):
            Self.authorizationMessage(host: host)
        case let .server(code, message):
            "智谱 GLM request failed (HTTP \(code)): \(message)"
        }
    }

    private static func authorizationMessage(host: String) -> String {
        switch host {
        case ZAIProvider.mainlandHost:
            "智谱 BigModel (open.bigmodel.cn) rejected this key. If it is a Z.AI international key, choose Global or Automatic."
        case ZAIProvider.globalHost:
            "Z.AI (api.z.ai) rejected this key. If it is a 智谱 mainland key, choose 中国大陆 · BigModel or Automatic."
        default:
            "Neither api.z.ai nor open.bigmodel.cn accepted this Coding Plan key. Check that it belongs to an active 智谱 GLM / Z.AI Coding Plan."
        }
    }
}

struct ZAIUsageResult: Sendable {
    var snapshot: UsageSnapshot
    var credentials: AccountCredentials
}

struct ZAIProvider {
    static let providerTitle = "智谱 GLM"
    static let globalHost = "api.z.ai"
    static let mainlandHost = "open.bigmodel.cn"
    static let quotaPath = "/api/monitor/usage/quota/limit"
    static let globalQuotaURL = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!
    static let mainlandQuotaURL = URL(string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit")!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func link(apiKey rawAPIKey: String, region: ZAIRegion = .automatic) async throws -> LinkedIdentity {
        let apiKey = try Self.normalizedKey(rawAPIKey)
        let account = MonitoredAccount(
            id: UUID(),
            providerID: .zai,
            displayName: Self.providerTitle,
            workspaceID: "pending",
            plan: nil,
            addedAt: .now
        )
        let result = try await load(
            account: account,
            credentials: AccountCredentials(
                accessToken: apiKey,
                refreshToken: "",
                idToken: "",
                serviceRegion: region.rawValue
            )
        )
        let digest = SHA256.hash(data: Data(apiKey.utf8))
        let fingerprint = digest.prefix(8).map { String(format: "%02x", $0) }.joined()

        return LinkedIdentity(
            workspaceID: "zai-\(fingerprint)",
            displayName: Self.providerTitle,
            plan: result.snapshot.plan ?? "Coding Plan",
            credentials: result.credentials
        )
    }

    func fetchUsage(account: MonitoredAccount, credentials: AccountCredentials) async throws -> ZAIUsageResult {
        try await load(account: account, credentials: credentials)
    }

    static func candidateURLs(region: ZAIRegion, pinnedHost: String?) -> [URL] {
        if let pinned = quotaURL(forHost: pinnedHost) {
            return [pinned]
        }
        switch region {
        case .global: return [globalQuotaURL]
        case .mainland: return [mainlandQuotaURL]
        case .automatic: return [globalQuotaURL, mainlandQuotaURL]
        }
    }

    static func quotaURL(forHost host: String?) -> URL? {
        switch host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case globalHost, globalQuotaURL.absoluteString: globalQuotaURL
        case mainlandHost, mainlandQuotaURL.absoluteString: mainlandQuotaURL
        default: nil
        }
    }

    static func region(from credentials: AccountCredentials) -> ZAIRegion {
        ZAIRegion(rawValue: credentials.serviceRegion ?? "") ?? .automatic
    }

    static func parseUsage(account: MonitoredAccount, data: Data, now: Date = .now) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = integer(root["code"]),
              code == 200,
              (root["success"] as? Bool) != false,
              let payload = root["data"] as? [String: Any],
              let rawLimits = payload["limits"] as? [[String: Any]] else {
            throw ZAIProviderError.invalidResponse
        }

        var fiveHour: UsageWindow?
        var weekly: UsageWindow?
        var additional: [UsageWindow] = []

        for rawLimit in rawLimits {
            guard let window = usageWindow(rawLimit, now: now) else { continue }
            switch window.windowMinutes {
            case 300 where fiveHour == nil:
                fiveHour = window
            case 10_080 where weekly == nil:
                weekly = window
            default:
                additional.append(window)
            }
        }

        guard fiveHour != nil || weekly != nil || !additional.isEmpty else {
            throw ZAIProviderError.noResettableQuota
        }

        let plan = string(payload["planName"])
            ?? string(payload["plan"])
            ?? string(payload["plan_type"])
            ?? string(payload["packageName"])
            ?? account.plan

        return UsageSnapshot(
            accountID: account.id,
            providerName: providerTitle,
            accountName: account.displayName,
            accountProviderID: account.providerID,
            accountSymbolName: account.customSymbolName,
            plan: plan,
            primary: fiveHour,
            secondary: weekly,
            availableResetCount: 0,
            resetCredits: [],
            fetchedAt: now,
            extraWindows: additional.isEmpty ? nil : additional
        )
    }

    private func load(account: MonitoredAccount, credentials: AccountCredentials) async throws -> ZAIUsageResult {
        let apiKey = try Self.normalizedKey(credentials.accessToken)
        let region = Self.region(from: credentials)
        let urls = Self.candidateURLs(region: region, pinnedHost: credentials.serviceHost)
        var mostRecentRetryableError: Error?

        for url in urls {
            do {
                let data = try await quotaData(apiKey: apiKey, url: url)
                let snapshot = try Self.parseUsage(account: account, data: data)
                var pinned = credentials
                pinned.accessToken = apiKey
                pinned.serviceRegion = region.rawValue
                pinned.serviceHost = url.absoluteString
                return ZAIUsageResult(snapshot: snapshot, credentials: pinned)
            } catch let error as ZAIProviderError {
                switch error {
                case .authorizationFailed, .invalidResponse:
                    mostRecentRetryableError = error
                    if urls.count == 1 { throw error }
                case .invalidAPIKey, .noResettableQuota, .server:
                    throw error
                }
            }
        }

        throw mostRecentRetryableError ?? ZAIProviderError.authorizationFailed("both")
    }

    private func quotaData(apiKey: String, url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("WhenReset/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let host = url.host ?? "both"
        switch status {
        case 200..<300:
            if Self.envelopeAccepted(data) { return data }
            throw ZAIProviderError.authorizationFailed(host)
        case 401, 403:
            throw ZAIProviderError.authorizationFailed(host)
        case 404, 405:
            throw ZAIProviderError.authorizationFailed(host)
        default:
            throw ZAIProviderError.server(status, Self.safeServerMessage(data))
        }
    }

    private static func normalizedKey(_ rawAPIKey: String) throws -> String {
        let apiKey = rawAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard apiKey.count >= 12, !apiKey.contains(where: { $0.isWhitespace }) else {
            throw ZAIProviderError.invalidAPIKey
        }
        return apiKey
    }

    /// Zhipu and Z.AI answer with a `code` / `success` envelope even when HTTP is 200.
    /// A non-success envelope is a wrong-region or wrong-key reply, not quota data.
    static func envelopeAccepted(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        if (root["success"] as? Bool) == false { return false }
        if let code = integer(root["code"]), code != 200 { return false }
        return root["data"] is [String: Any]
    }

    private static func usageWindow(_ raw: [String: Any], now: Date) -> UsageWindow? {
        guard let type = string(raw["type"])?.uppercased(),
              type == "TOKENS_LIMIT" || type == "TIME_LIMIT",
              let reset = resetDate(raw["nextResetTime"] ?? raw["next_reset_time"]),
              reset > now else { return nil }

        let unit = integer(raw["unit"])
        let number = integer(raw["number"]) ?? 0
        let minutes = windowMinutes(unit: unit, number: number)
        let usedPercent = percentage(raw)

        if type == "TOKENS_LIMIT" {
            switch minutes {
            case 300:
                return UsageWindow(title: "5h limit", usedPercent: usedPercent, resetsAt: reset,
                                   windowMinutes: minutes, kind: .fiveHour, identifier: "zai:five_hour")
            case 10_080:
                return UsageWindow(title: "Weekly limit", usedPercent: usedPercent, resetsAt: reset,
                                   windowMinutes: minutes, kind: .weekly, identifier: "zai:weekly")
            default:
                let title = windowTitle(unit: unit, number: number) ?? "Coding limit"
                return UsageWindow(title: title, usedPercent: usedPercent, resetsAt: reset,
                                   windowMinutes: minutes, kind: .additional,
                                   identifier: "zai:coding:\(unit ?? -1):\(number)")
            }
        }

        return UsageWindow(
            title: "Monthly MCP limit",
            usedPercent: usedPercent,
            resetsAt: reset,
            windowMinutes: minutes,
            kind: .additional,
            identifier: "zai:mcp:\(unit ?? -1):\(number)"
        )
    }

    private static func percentage(_ raw: [String: Any]) -> Double {
        if let allowance = number(raw["usage"]), allowance > 0 {
            let fromRemaining = number(raw["remaining"]).map { allowance - $0 }
            let current = number(raw["currentValue"] ?? raw["current_value"])
            let used = [fromRemaining, current].compactMap { $0 }.max()
            if let used {
                return min(100, max(0, used / allowance * 100))
            }
        }
        return min(100, max(0, number(raw["percentage"]) ?? 0))
    }

    private static func windowMinutes(unit: Int?, number: Int) -> Int? {
        guard number > 0 else { return nil }
        return switch unit {
        case 1: number * 24 * 60
        case 3: number * 60
        case 5: number
        case 6: number * 7 * 24 * 60
        default: nil
        }
    }

    private static func windowTitle(unit: Int?, number: Int) -> String? {
        guard number > 0 else { return nil }
        return switch unit {
        case 1: "\(number)-day limit"
        case 3: "\(number)h limit"
        case 5: "\(number)-minute limit"
        case 6: number == 1 ? "Weekly limit" : "\(number)-week limit"
        default: nil
        }
    }

    private static func resetDate(_ value: Any?) -> Date? {
        guard let timestamp = number(value), timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp > 10_000_000_000 ? timestamp / 1_000 : timestamp)
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func safeServerMessage(_ data: Data) -> String {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = string(root["msg"] ?? root["message"]) {
            return String(message.prefix(180))
        }
        return "The quota service is unavailable."
    }
}
