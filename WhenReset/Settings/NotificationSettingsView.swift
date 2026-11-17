#if os(iOS)
import SwiftUI
import UIKit
import UserNotifications

enum NotificationPermissionPresentation: Equatable {
    case needsRequest
    case provisional
    case allowed
    case denied
    case ephemeral

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .needsRequest
        case .provisional: self = .provisional
        case .authorized: self = .allowed
        case .denied: self = .denied
        case .ephemeral: self = .ephemeral
        @unknown default: self = .allowed
        }
    }
}

struct NotificationSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var notificationSettings = GlobalNotificationSettings()
    @State private var authorization: UNAuthorizationStatus = .notDetermined
    @State private var testNote: String?

    private var permission: NotificationPermissionPresentation {
        NotificationPermissionPresentation(authorization)
    }

    var body: some View {
        Form {
            Section {
                switch permission {
                case .needsRequest:
                    Button("Allow Notifications") { Task { await allowNotifications() } }
                case .provisional:
                    LabeledContent("Status", value: String.localized("Quiet alerts"))
                    Button("Allow Alerts and Sounds") { Task { await allowNotifications() } }
                case .allowed:
                    LabeledContent("Status", value: String.localized("Allowed"))
                case .denied:
                    LabeledContent("Status", value: String.localized("Off"))
                    Button("Open Settings") { openSystemSettings() }
                case .ephemeral:
                    LabeledContent("Status", value: String.localized("Allowed for this session"))
                }
            } header: {
                Text("Permission")
            } footer: {
                Text(permissionFooter)
            }
            .blinkySettingsSection()

            Section {
                Toggle("Quota resets",
                       isOn: $notificationSettings.notifyAboutQuotaResets)
                Toggle("Unexpected or early resets",
                       isOn: $notificationSettings.notifyAboutUnexpectedResets)
                Toggle("New reset card notices",
                       isOn: $notificationSettings.notifyAboutNewBankedResets)
            } header: {
                Text("Limit reminders")
            } footer: {
                Text("The same switches cover every account. Quota reset alerts say a window started a new period, like a refilled 5-hour quota, and they are off by default. Unexpected or early resets cover an early quota change and an early weekly reset.")
            }
            .blinkySettingsSection()

            Section {
                scheduledResetToggle(\.notifyAtHourlyReset, cadence: .hourly)
                scheduledResetToggle(\.notifyAtDailyReset, cadence: .daily)
                scheduledResetToggle(\.notifyAtWeeklyReset, cadence: .weekly)
                scheduledResetToggle(\.notifyAtMonthlyReset, cadence: .monthly)
                scheduledResetToggle(\.notifyAtOtherScheduledReset, cadence: .other)
            } header: {
                Text("Reset reminders")
            } footer: {
                Text("These fire when the provider’s reset time arrives, and the notification names the kind of window. A 5-hour or shorter window is an hourly reset, then a day, a week, and a month. Anything else with a real reset time is the other switch. A predicted Codex reset stays in Forecasts and can fire 12, 24, or 48 hours before an announced time.")
            }
            .blinkySettingsSection()

            Section {
                Button("Send") {
                    Task { testNote = await UsageNotificationService.sendTestNote() }
                }
                .accessibilityIdentifier("notification-test-send")
                if let testNote {
                    Text(testNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Test notification")
            } footer: {
                Text("Sends one now, so you can see that notifications reach you.")
            }
            .blinkySettingsSection()
        }
        .blinkySettingsCanvas()
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { notificationSettings = store.notificationSettings }
        .onChange(of: notificationSettings) { _, newValue in
            store.setNotificationSettings(newValue)
        }
        .task { await refreshAuthorization() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshAuthorization() }
        }
    }

    private var permissionFooter: String {
        switch permission {
        case .needsRequest:
            String.localized("Allow notifications to deliver reset alerts.")
        case .provisional:
            String.localized("Quiet alerts are on. Allow alerts and sounds to show reset notifications on the Lock Screen and in Notification Center.")
        case .allowed:
            String.localized("Notifications are allowed.")
        case .denied:
            String.localized("Notifications are off for Blinky. Turn them on in Settings to deliver reset alerts.")
        case .ephemeral:
            String.localized("Notifications are allowed for this session.")
        }
    }

    private func allowNotifications() async {
        await UsageNotificationService.requestProminentAuthorization()
        await refreshAuthorization()
    }

    private func refreshAuthorization() async {
        authorization = await UsageNotificationService.authorizationStatus()
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func scheduledResetToggle(
        _ keyPath: WritableKeyPath<GlobalNotificationSettings, Bool>,
        cadence: ScheduledResetCadence
    ) -> some View {
        Toggle(isOn: Binding(
            get: { notificationSettings[keyPath: keyPath] },
            set: { isOn in
                var copy = notificationSettings
                copy[keyPath: keyPath] = isOn
                notificationSettings = copy
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text(cadence.notificationTitle)
                Text(cadence.settingsSubtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("scheduled-reset-\(cadence.rawValue)")
    }

    private func accountSetting(
        _ account: MonitoredAccount,
        _ keyPath: WritableKeyPath<AccountMonitorSettings, Bool>
    ) -> Binding<Bool> {
        Binding {
            store.settings(for: account)[keyPath: keyPath]
        } set: { isOn in
            var settings = store.settings(for: account)
            guard settings[keyPath: keyPath] != isOn else { return }
            settings[keyPath: keyPath] = isOn
            store.setSettings(settings, for: account)
        }
    }
}
#endif
