import Foundation

/// Qoder's two account sites. A session or token from one is never sent to the other.
enum QoderSite: String, CaseIterable, Identifiable, Sendable {
    case international
    case china

    var id: String { rawValue }

    var title: String {
        switch self {
        case .international: String.localized("International site · qoder.com")
        case .china: String.localized("Mainland site · qoder.com.cn")
        }
    }

    var host: String {
        switch self {
        case .international: "qoder.com"
        case .china: "qoder.com.cn"
        }
    }

    var origin: String { "https://\(host)" }

    var usageURL: URL { URL(string: "\(origin)/api/v2/me/usages/big_model_credits")! }

    var accountPage: URL { URL(string: "\(origin)/account/usage")! }

    static func preferred(locale: Locale) -> QoderSite {
        let region = locale.region?.identifier.uppercased() ?? ""
        if region == "CN" || region == "CHN" { return .china }
        return .international
    }

    static func stored(_ value: String?) -> QoderSite {
        if value == QoderSite.china.rawValue || value == QoderSite.china.host { return .china }
        return .international
    }
}

/// Qoder credits, read the way the account usage page reads them.
///
/// `GET https://{site}/api/v2/me/usages/big_model_credits` with either a personal
/// token (`pt-` / `jt-`, `Authorization: Bearer`) or the site's session cookie.
/// Blinky Mac and CodexBar use this same account-page route. The reply's
/// `totalQuota` is the account allowance and `sharedQuota` is a team pool.
/// `nextResetAt` is shown only while it is still ahead. The reply does not
/// state a window length, and a team pool is not given that reset.
struct QoderProvider {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func link(credential rawCredential: String, site: QoderSite) async throws -> LinkedIdentity {
        let credential = try Self.credential(rawCredential)
        let account = pendingAccount(providerID: .qoder, name: "Qoder")
        let snapshot = try await fetchUsage(
            account: account,
            credentials: AccountCredentials(
                accessToken: credential,
                refreshToken: "",
                idToken: "",
                serviceRegion: site.rawValue
            )
        )
        return LinkedIdentity(
            workspaceID: "qoder-\(site.rawValue)-\(AdditionalProviderParsing.fingerprint(credential))",
            displayName: "Qoder",
            plan: snapshot.plan,
            credentials: AccountCredentials(
                accessToken: credential,
                refreshToken: "",
                idToken: "",
                serviceHost: site.host,
                serviceRegion: site.rawValue
            )
        )
    }

    func fetchUsage(account: MonitoredAccount, credentials: AccountCredentials) async throws -> UsageSnapshot {
        let site = QoderSite.stored(credentials.serviceRegion ?? credentials.serviceHost)
        let credential = try Self.credential(credentials.accessToken)
        let token = Self.accessToken(in: credential)
        var request = URLRequest(url: site.usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue(try Self.normalizedCookie(credential), forHTTPHeaderField: "Cookie")
        }
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(site.origin, forHTTPHeaderField: "Origin")
        request.setValue(site.accountPage.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        // The account page sends this bot-screening header. Readers of this
        // route, including Blinky Mac, send the same value.
        request.setValue("2.5.35", forHTTPHeaderField: "Bx-V")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
                + "(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await AdditionalProviderNetworking.data(
            for: request, session: session, provider: "Qoder"
        )
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (300..<400).contains(status) || status == 401 || status == 403 {
            throw AdditionalProviderError.authorizationFailed("Qoder")
        }
        guard (200..<300).contains(status) else {
            throw AdditionalProviderError.server("Qoder", status)
        }
        guard response.url?.host == site.host else {
            throw AdditionalProviderError.authorizationFailed("Qoder")
        }
        return try Self.parseUsage(account: account, data: data, now: .now)
    }

    static func credential(_ rawValue: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if accessToken(in: value) != nil { return value }
        return try normalizedCookie(value)
    }

    /// A console personal token. Anything else is treated as a cookie header.
    static func accessToken(in raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("pt-") || trimmed.hasPrefix("jt-") { return trimmed }
        return nil
    }

    /// Keeps the host's own cookies and drops third-party analytics names.
    /// Alibaba's `cna`, `isg`, and `tfstk` stay, matching Blinky Mac: they
    /// carry the site's own screening, and dropping them refuses a working session.
    static func normalizedCookie(_ input: String) throws -> String {
        guard !input.unicodeScalars.contains(where: { $0.value < 32 || $0.value > 126 }) else {
            throw AdditionalProviderError.invalidCredential(
                "Qoder",
                String.localized("Paste a Qoder personal token or the Cookie header from the usage page.")
            )
        }
        var header = input.trimmingCharacters(in: .whitespaces)
        if header.lowercased().hasPrefix("cookie:") {
            header = String(header.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespaces)
        }
        guard !header.isEmpty, header.utf8.count <= 32_768 else {
            throw AdditionalProviderError.invalidCredential(
                "Qoder",
                String.localized("Paste a Qoder personal token or the Cookie header from the usage page.")
            )
        }
        let analytics = [
            "_ga", "_gid", "_gat", "_gcl", "_fbp", "_fbc", "_clck", "_clsk", "_hj",
            "_uet", "_tt_", "_ttp", "ajs_", "amp_", "mp_", "hm_", "hmaccount",
            "intercom-", "__stripe", "_rdt", "_pin",
        ]
        var kept: [String] = []
        var seen = Set<String>()
        for pair in header.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.isEmpty else { continue }
            let lowered = name.lowercased()
            guard !analytics.contains(where: { lowered.hasPrefix($0) }) else { continue }
            guard !value.contains(" "), !value.contains("\\"), !name.contains(" ") else { continue }
            guard seen.insert(name).inserted else { continue }
            kept.append("\(name)=\(value)")
        }
        guard !kept.isEmpty else {
            throw AdditionalProviderError.invalidCredential(
                "Qoder",
                String.localized("Paste a Qoder personal token or the Cookie header from the usage page.")
            )
        }
        return kept.joined(separator: "; ")
    }

    static func parseUsage(account: MonitoredAccount, data: Data, now: Date = .now) throws -> UsageSnapshot {
        let root = try AdditionalProviderParsing.json(data, provider: "Qoder")
        guard let personalContainer = container(root, camel: "totalQuota", snake: "total_quota"),
              let personal = pool(personalContainer) else {
            throw AdditionalProviderError.invalidResponse("Qoder")
        }
        let shared: Pool?
        if let sharedValue = root["sharedQuota"] ?? root["shared_quota"], !(sharedValue is NSNull) {
            guard let sharedContainer = AdditionalProviderParsing.dictionary(sharedValue),
                  let sharedPool = pool(sharedContainer) else {
                throw AdditionalProviderError.invalidResponse("Qoder")
            }
            shared = sharedPool.limit > 0 ? sharedPool : nil
        } else {
            shared = nil
        }

        let reportedReset = AdditionalProviderParsing.firstDate(root, keys: ["nextResetAt", "next_reset_at"])
        let reset = reportedReset.flatMap { $0 > now ? $0 : nil }
        var windows: [UsageWindow] = []
        if personal.limit > 0 {
            windows.append(window(
                personal,
                title: String.localized("Credit allowance"),
                identifier: "qoder.credits",
                reset: reset,
                now: now
            ))
        }
        if let shared {
            windows.append(window(
                shared,
                title: String.localized("Team credits"),
                identifier: "qoder.shared",
                reset: nil,
                now: now
            ))
        }
        guard !windows.isEmpty else { throw AdditionalProviderError.noAllowance("Qoder") }
        return UsageSnapshot(
            accountID: account.id,
            providerName: "Qoder",
            accountName: account.displayName,
            accountProviderID: account.providerID,
            plan: account.plan,
            primary: windows[0],
            secondary: windows.count > 1 ? windows[1] : nil,
            availableResetCount: 0,
            resetCredits: [],
            fetchedAt: now
        )
    }

    private struct Pool {
        var used: Double
        var limit: Double
    }

    private static func container(_ root: [String: Any], camel: String, snake: String) -> [String: Any]? {
        AdditionalProviderParsing.dictionary(root[camel] ?? root[snake])
    }

    private static func pool(_ container: [String: Any]) -> Pool? {
        guard let summary = self.container(container, camel: "quotaSummary", snake: "quota_summary") else {
            return nil
        }
        guard let used = AdditionalProviderParsing.firstNumber(summary, keys: ["usedValue", "used_value"]),
              let limit = AdditionalProviderParsing.firstNumber(summary, keys: ["limitValue", "limit_value"]),
              used.isFinite, limit.isFinite, used >= 0, limit >= 0 else { return nil }
        return Pool(used: used, limit: limit)
    }

    private static func window(
        _ pool: Pool,
        title: String,
        identifier: String,
        reset: Date?,
        now: Date
    ) -> UsageWindow {
        let usedPercent = pool.limit > 0 ? min(100, max(0, pool.used / pool.limit * 100)) : 0
        return UsageWindow(
            title: title,
            usedPercent: usedPercent,
            resetsAt: reset ?? now,
            windowMinutes: nil,
            kind: .additional,
            identifier: identifier,
            reportsReset: reset != nil
        )
    }
}
