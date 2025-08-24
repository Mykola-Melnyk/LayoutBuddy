import SwiftUI

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
    var body: some View {
        Text("General settings will appear here.")
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
