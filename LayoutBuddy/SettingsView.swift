import SwiftUI

struct SettingsView: View {
    @StateObject private var model: ViewModel

    init(preferences: LayoutPreferences) {
        _model = StateObject(wrappedValue: ViewModel(preferences: preferences))
    }

    var body: some View {
        Form {
            Picker("Primary Layout", selection: $model.primaryID) {
                ForEach(model.layouts, id: \.id) { info in
                    Text(info.name).tag(info.id)
                }
            }
            Picker("Secondary Layout", selection: $model.secondaryID) {
                ForEach(model.layouts, id: \.id) { info in
                    Text(info.name).tag(info.id)
                }
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

extension SettingsView {
    final class ViewModel: ObservableObject {
        private let preferences: LayoutPreferences
        private let manager: KeyboardLayoutManager
        let layouts: [KeyboardLayoutManager.InputSourceInfo]

        @Published var primaryID: String {
            didSet { preferences.primaryID = primaryID }
        }
        @Published var secondaryID: String {
            didSet { preferences.secondaryID = secondaryID }
        }

        init(preferences: LayoutPreferences) {
            self.preferences = preferences
            self.manager = KeyboardLayoutManager(preferences: preferences)
            self.layouts = manager.listSelectableKeyboardLayouts()
            self.primaryID = preferences.primaryID
            self.secondaryID = preferences.secondaryID
        }
    }
}

#Preview {
    SettingsView(preferences: LayoutPreferences())
}
