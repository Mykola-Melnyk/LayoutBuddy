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
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading) {
            Toggle("Launch LayoutBuddy at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .onChange(of: launchAtLogin) { enabled in
                    if enabled {
                        try? SMAppService.mainApp.register()
                    } else {
                        SMAppService.mainApp.unregister()
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
