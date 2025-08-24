import SwiftUI
import ServiceManagement

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Text("General") }
            ShortcutsSettingsView()
                .tabItem { Text("Shortcuts") }
        }
        .padding(20)
        .frame(width: 360)
    }
}

private struct GeneralSettingsView: View {
    @AppStorage("PlaySoundAtLayoutConversion") private var playSoundAtConversion = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading) {
            Toggle("Play sound at layout conversion", isOn: $playSoundAtConversion)
                .toggleStyle(.checkbox)
            Toggle("Launch LayoutBuddy at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .onChange(of: launchAtLogin) { _, enabled in
                    if enabled {
                        try? SMAppService.mainApp.register()
                    } else {
                        try? SMAppService.mainApp.unregister()
                    }
                }
            Spacer()
        }
    }
}

private struct ShortcutsSettingsView: View {
    var body: some View {
        Text("Shortcut settings will appear here.")
    }
}

#Preview {
    SettingsView()
}
