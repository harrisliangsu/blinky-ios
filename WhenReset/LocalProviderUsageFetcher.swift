import Foundation

/// One provider fetch for a widget timeline or any other caller that is not `AppStore`.
///
/// Credential refresh is saved back to the Keychain. A provider that rotates its refresh
/// token has to keep that token, or the next fetch from the app fails.
enum LocalProviderUsageFetcher {
    static func fetch(_ account: MonitoredAccount) async throws -> UsageSnapshot {
        var credentials = try KeychainStore.load(for: account.id)
        var effective = account
        switch account.providerID {
        case .chatGPT:
            let provider = ChatGPTProvider()
            credentials = try storeIfChanged(try await provider.refreshedIfNeeded(credentials), accountID: account.id)
            if let identity = try? provider.linkedIdentity(
                accessToken: credentials.accessToken,
                refreshToken: credentials.refreshToken,
                idToken: credentials.idToken
            ) {
                effective = applying(identity.accountDetails, to: effective)
            }
            return try await provider.fetchUsage(account: effective, credentials: credentials)
        case .claude:
            let provider = ClaudeProvider()
            let refreshed = try await provider.refreshedAccountIfNeeded(credentials)
            credentials = try storeIfChanged(refreshed.credentials, accountID: account.id)
            effective = applying(refreshed.accountDetails, to: effective)
            return try await provider.fetchUsage(account: effective, credentials: credentials)
        case .grok:
            let provider = GrokProvider()
            credentials = try storeIfChanged(try await provider.refreshedIfNeeded(credentials), accountID: account.id)
            if let identity = try? GrokProvider.linkedIdentity(credentials: credentials) {
                effective = applying(identity.accountDetails, to: effective)
            }
            return try await provider.fetchUsage(account: effective, credentials: credentials)
        case .kimi:
            let provider = KimiProvider()
            credentials = try storeIfChanged(try await provider.refreshedIfNeeded(credentials), accountID: account.id)
            effective = applying(KimiProvider.linkedIdentity(credentials: credentials).accountDetails, to: effective)
            return try await provider.fetchUsage(account: effective, credentials: credentials)
        case .githubCopilot:
            let provider = CopilotProvider()
            credentials = try storeIfChanged(try await provider.refreshedIfNeeded(credentials), accountID: account.id)
            if let details = try? await provider.fetchAccountDetails(credentials: credentials) {
                effective = applying(details, to: effective)
            }
            return try await provider.fetchUsage(account: effective, credentials: credentials)
        case .zai, .zhipu:
            let fetched = try await ZAIProvider().fetchUsage(account: effective, credentials: credentials)
            _ = try storeIfChanged(fetched.credentials, accountID: account.id)
            return fetched.snapshot
        case .miniMax:
            return try await MiniMaxProvider().fetchUsage(account: effective, credentials: credentials)
        case .synthetic:
            return try await SyntheticProvider().fetchUsage(account: effective, credentials: credentials)
        case .ollamaCloud:
            return try await OllamaCloudProvider().fetchUsage(account: effective, credentials: credentials)
        case .warp:
            return try await WarpProvider().fetchUsage(account: effective, credentials: credentials)
        case .antigravity:
            let provider = AntigravityProvider()
            credentials = try storeIfChanged(try await provider.refreshedIfNeeded(credentials), accountID: account.id)
            return try await provider.fetchUsage(account: effective, credentials: credentials)
        case .compatibleAPI:
            return try await CompatibleAPIProvider().fetchUsage(account: effective, credentials: credentials)
        case .openAIAPI:
            return try await OpenAIAPIProvider().fetchUsage(account: effective, credentials: credentials)
        case .anthropicAPI:
            return try await AnthropicAPIProvider().fetchUsage(account: effective, credentials: credentials)
        case .newAPI:
            return try await NewAPIProvider().fetchUsage(account: effective, credentials: credentials)
        case .openRouter:
            return try await OpenRouterProvider().fetchUsage(account: effective, credentials: credentials)
        case .fireworksAI:
            return try await FireworksAIProvider().fetchUsage(account: effective, credentials: credentials)
        case .deepSeek:
            return try await DeepSeekProvider().fetchUsage(account: effective, credentials: credentials)
        case .poe:
            return try await PoeProvider().fetchUsage(account: effective, credentials: credentials)
        case .qoder:
            return try await QoderProvider().fetchUsage(account: effective, credentials: credentials)
        }
    }

    private static func storeIfChanged(
        _ updated: AccountCredentials,
        accountID: UUID
    ) throws -> AccountCredentials {
        let current = try KeychainStore.load(for: accountID)
        guard updated != current else { return current }
        try KeychainStore.save(updated, for: accountID)
        return updated
    }

    private static func applying(_ details: ProviderAccountDetails?, to account: MonitoredAccount) -> MonitoredAccount {
        guard let details else { return account }
        var copy = account
        copy.mergeProviderDetails(details)
        return copy
    }
}
