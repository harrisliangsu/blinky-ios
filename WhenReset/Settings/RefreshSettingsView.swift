#if os(iOS)
import SwiftUI

struct RefreshSettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var refreshSettings = GlobalRefreshSettings()

    var body: some View {
        Form {
            Section {
                Picker("In app", selection: $refreshSettings.inAppInterval) {
                    ForEach(RefreshInterval.inAppOptions, id: \.self) { interval in
                        Text(interval.title).tag(interval)
                    }
                }
                Picker("Background & Live Activity",
                       selection: $refreshSettings.backgroundInterval) {
                    ForEach(RefreshInterval.backgroundOptions, id: \.self) { interval in
                        Text(interval.title).tag(interval)
                    }
                }
            } footer: {
                Text("The in-app interval runs only while Blinky is open. After you leave, Blinky asks iOS for a background refresh using the second interval. iOS chooses the time. Background App Refresh must be on for Blinky, and Low Power Mode can delay it. A widget number changes only after a provider response is saved. The time it shows is that save, not a guess.")
            }
            .blinkySettingsSection()
        }
        .blinkySettingsCanvas()
        .navigationTitle("Refresh")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refreshSettings = store.refreshSettings }
        .onChange(of: refreshSettings) { _, newValue in
            store.setRefreshSettings(newValue)
        }
    }
}
#endif
