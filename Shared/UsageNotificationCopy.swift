import Foundation

enum UsageNotificationCopy {
    static func format(_ key: String.LocalizationValue, _ args: CVarArg...) -> String {
        format(key, arguments: args)
    }

    static func format(_ key: String.LocalizationValue, arguments: [CVarArg]) -> String {
        String(format: String.localized(key), locale: AppLanguage.current.locale, arguments: arguments)
    }
}

enum UsageNotificationArgument: Codable, Hashable, Sendable {
    case subject
    case text(String)
    case integer(Int64)
}

/// Enough of a notification to draw it again after an account is added,
/// renamed, or removed. The subject is not stored: it is the provider name,
/// or the provider plus a label, for the roster at render time.
struct UsageNotificationRecipe: Codable, Hashable, Sendable {
    var titleKey: String
    var titleArguments: [UsageNotificationArgument]
    var bodyKey: String
    var bodyArguments: [UsageNotificationArgument]

    func title(subject: String) -> String {
        UsageNotificationCopy.format(
            String.LocalizationValue(stringLiteral: titleKey),
            arguments: Self.values(titleArguments, subject: subject)
        )
    }

    func body(subject: String) -> String {
        UsageNotificationCopy.format(
            String.LocalizationValue(stringLiteral: bodyKey),
            arguments: Self.values(bodyArguments, subject: subject)
        )
    }

    private static func values(
        _ arguments: [UsageNotificationArgument],
        subject: String
    ) -> [CVarArg] {
        var result: [CVarArg] = []
        for argument in arguments {
            switch argument {
            case .subject: result.append(subject)
            case let .text(value): result.append(value)
            case let .integer(value): result.append(value)
            }
        }
        return result
    }
}

/// Who a reset notification names.
///
/// One account of a provider is named by that provider. A second account of
/// the same provider adds a friendly label. An account of a different
/// provider does not count, and the label is never a workspace id or a token.
enum NotificationAccountLabel {
    static func subject(for account: MonitoredAccount, among accounts: [MonitoredAccount]) -> String {
        let provider = account.providerDisplayName
        let peers = accounts.filter { !$0.isDemo && $0.providerID == account.providerID }
        guard peers.count > 1 else { return provider }

        let chosen = peers.map { (account: $0, label: label(for: $0)) }
        guard let own = chosen.first(where: { $0.account.id == account.id }) else { return provider }
        var text = own.label
        let duplicates = chosen.filter { $0.label.caseInsensitiveCompare(text) == .orderedSame }
        if duplicates.count > 1 {
            let ordered = duplicates.map(\.account).sorted { lhs, rhs in
                if lhs.addedAt != rhs.addedAt { return lhs.addedAt < rhs.addedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            let number = (ordered.firstIndex(where: { $0.id == account.id }) ?? 0) + 1
            text = "\(text) \(number)"
        }
        if incorporates(provider, text) { return text }
        return "\(provider)（\(text)）"
    }

    private static func label(for account: MonitoredAccount) -> String {
        let provider = account.providerDisplayName
        let blocked = Set(
            [account.workspaceID, account.remoteWorkerAccountID]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        let candidates = [
            account.customDisplayName,
            account.profileName,
            account.email,
            account.displayName,
        ]
        for candidate in candidates {
            guard let value = readable(candidate), !blocked.contains(value.lowercased()) else { continue }
            if value.caseInsensitiveCompare(provider) == .orderedSame { continue }
            return value
        }
        return String.localized("Account")
    }

    /// A name a person can recognize. Tokens, workspace ids, and control
    /// characters are not labels.
    private static func readable(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 80 else { return nil }
        guard value.unicodeScalars.allSatisfy({ scalar in
            scalar.value >= 32 && !CharacterSet.newlines.contains(scalar)
        }) else { return nil }
        if UUID(uuidString: value) != nil { return nil }
        let lowered = value.lowercased()
        if lowered.hasPrefix("sk-") || lowered.hasPrefix("pt-") || lowered.hasPrefix("jt-")
            || lowered.hasPrefix("bearer ") {
            return nil
        }
        if !value.contains(" "), !value.contains("@"), value.count >= 40 { return nil }
        return value
    }

    private static func incorporates(_ provider: String, _ label: String) -> Bool {
        guard let range = label.range(of: provider, options: [.caseInsensitive, .anchored]) else {
            return false
        }
        let rest = label[range.upperBound...]
        if rest.isEmpty { return true }
        guard let first = rest.first else { return true }
        return first == " " || first == "·" || first == "（" || first == "("
    }
}
