#if os(iOS)
import SwiftUI

struct SettingsView: View {
    let onStageWorkerLink: (WorkerLinkDraft) -> Void
    @Environment(UpdateCheckController.self) private var updates
    @Environment(\.interfaceStyle) private var interfaceStyle

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    moduleLink("Appearance", systemImage: "circle.lefthalf.filled", tint: Color(red: 0.35, green: 0.34, blue: 0.84), identifier: "settings-module-appearance") {
                        AppearanceSettingsView()
                    }
                    moduleLink("Forecasts", systemImage: "chart.line.uptrend.xyaxis", tint: Color(red: 0.20, green: 0.48, blue: 0.96), identifier: "settings-module-forecasts") {
                        ForecastSettingsView()
                    }
                    moduleLink("Token activity", systemImage: "square.grid.3x3", tint: Color(red: 0.56, green: 0.36, blue: 0.96), identifier: "settings-module-token-activity") {
                        TokenActivitySettingsView()
                    }
                    moduleLink("Language", systemImage: "globe", tint: Color(red: 0.16, green: 0.62, blue: 0.68), identifier: "settings-module-language") {
                        LanguageSettingsView()
                    }
                    moduleLink("Notifications", systemImage: "bell.badge", tint: Color(red: 0.92, green: 0.28, blue: 0.28), identifier: "settings-module-notifications") {
                        NotificationSettingsView()
                    }
                    moduleLink("Refresh", systemImage: "arrow.clockwise", tint: Color(red: 0.96, green: 0.52, blue: 0.18), identifier: "settings-module-refresh") {
                        RefreshSettingsView()
                    }
                    moduleLink("Live Activity", systemImage: "iphone", tint: Color(red: 0.18, green: 0.68, blue: 0.38), identifier: "settings-module-live-activity") {
                        LiveActivitySettingsView()
                    }
                    moduleLink("Self-hosted Worker", systemImage: "server.rack", tint: Color(red: 0.38, green: 0.42, blue: 0.48), identifier: "settings-module-worker") {
                        WorkerSettingsView(onStageWorkerLink: onStageWorkerLink)
                    }
                }
                .blinkySettingsSection()
                Section {
                    moduleLink("About", systemImage: "info.circle", tint: Color(red: 0.22, green: 0.48, blue: 0.90), identifier: "settings-module-about") {
                        AboutSettingsView()
                    }
                    .badge(updates.showsAboutBadge ? 1 : 0)
                }
                .blinkySettingsSection()
            }
            .blinkySettingsCanvas()
            .navigationTitle("Settings")
        }
    }

    private func moduleLink<Destination: View>(
        _ title: LocalizedStringKey,
        systemImage: String,
        tint: Color,
        identifier: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            if interfaceStyle == .screenTime {
                HStack(spacing: 12) {
                    Image(systemName: systemImage)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text(title)
                }
            } else {
                Label(title, systemImage: systemImage)
            }
        }
        .accessibilityIdentifier(identifier)
    }
}
#endif
