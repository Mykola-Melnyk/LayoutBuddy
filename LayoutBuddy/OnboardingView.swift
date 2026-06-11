import SwiftUI

/// First-run / permissions window. Lists the two required permissions with live
/// status and buttons that prompt + deep-link into System Settings.
struct OnboardingView: View {
    @ObservedObject var permissions: PermissionsManager
    var onContinue: () -> Void

    // The user grants permissions in System Settings, out of our process, so
    // poll to reflect changes live without needing a relaunch.
    private let pollTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            permissionRow(
                title: "Accessibility",
                systemImage: "accessibility",
                granted: permissions.accessibilityGranted,
                why: "Lets LayoutBuddy read the word you just typed and replace it.",
                grant: {
                    permissions.requestAccessibility()
                    permissions.openAccessibilitySettings()
                })

            permissionRow(
                title: "Input Monitoring",
                systemImage: "keyboard",
                granted: permissions.inputMonitoringGranted,
                why: "Lets LayoutBuddy notice what you type, to know when to convert.",
                grant: {
                    permissions.requestInputMonitoring()
                    permissions.openInputMonitoringSettings()
                })

            Divider()
            footer
        }
        .padding(24)
        .frame(width: 470)
        .onReceive(pollTimer) { _ in permissions.refresh() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "infinity")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("Welcome to LayoutBuddy")
                    .font(.title2).bold()
                Text("Two quick permissions and you're set.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            if permissions.allGranted {
                Label("All permissions granted", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                Text("If a switch stays off after granting, quit and reopen LayoutBuddy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(permissions.allGranted ? "Done" : "Continue", action: onContinue)
                .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private func permissionRow(title: String,
                               systemImage: String,
                               granted: Bool,
                               why: String,
                               grant: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 26)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(why).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
                    .font(.subheadline)
            } else {
                Button("Grant…", action: grant)
            }
        }
        .padding(.vertical, 6)
    }
}
