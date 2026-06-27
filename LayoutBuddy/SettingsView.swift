import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var dictionary: UserDictionary

    init(dictionary: UserDictionary = UserDictionary()) {
        self.dictionary = dictionary
    }

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Text("General") }
            ShortcutsSettingsView()
                .tabItem { Text("Shortcuts") }
            DictionarySettingsView(dictionary: dictionary)
                .tabItem { Text("Dictionary") }
        }
        .padding(20)
        .frame(width: 720)
    }
}

private struct DictionarySettingsView: View {
    @ObservedObject var dictionary: UserDictionary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Words added here are treated as correctly spelled, so LayoutBuddy won't auto-convert them. Add words via right-click → Services, or below.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 16) {
                DictionaryColumn(language: .english, dictionary: dictionary)
                DictionaryColumn(language: .ukrainian, dictionary: dictionary)
            }
            Spacer()
        }
    }
}

private struct DictionaryColumn: View {
    let language: UserDictionary.Language
    @ObservedObject var dictionary: UserDictionary
    @State private var newWord = ""

    private var words: [String] { dictionary.words(for: language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(language.displayName).font(.headline)
                Spacer()
                Text("\(words.count)").foregroundStyle(.secondary)
            }

            List {
                ForEach(words, id: \.self) { word in
                    HStack {
                        Text(word)
                        Spacer()
                        Button {
                            dictionary.remove(word, from: language)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 260)

            HStack {
                TextField("Add a word…", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func add() {
        dictionary.add(newWord, to: [language])
        newWord = ""
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
    @State private var toggleHotkey = LayoutPreferences().toggleHotkey
    @State private var convertHotkey = LayoutPreferences().convertHotkey
    @State private var forceCorrectHotkey = LayoutPreferences().forceCorrectHotkey
    @State private var undoCorrectionHotkey = LayoutPreferences().undoCorrectionHotkey
    private let prefs = LayoutPreferences()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Toggle conversion on/off")
                Spacer()
                HotkeyRecorder(hotkey: $toggleHotkey)
                    .frame(width: 160)
            }
            HStack {
                Text("Convert last ambiguous word")
                Spacer()
                HotkeyRecorder(hotkey: $convertHotkey)
                    .frame(width: 160)
            }
            HStack {
                Text("Force-correct last word")
                Spacer()
                HotkeyRecorder(hotkey: $forceCorrectHotkey)
                    .frame(width: 160)
            }
            HStack {
                Text("Undo last correction")
                Spacer()
                HotkeyRecorder(hotkey: $undoCorrectionHotkey)
                    .frame(width: 160)
            }
            Spacer()
        }
        .onChange(of: toggleHotkey) { _, newValue in
            prefs.toggleHotkey = newValue
        }
        .onChange(of: convertHotkey) { _, newValue in
            prefs.convertHotkey = newValue
        }
        .onChange(of: forceCorrectHotkey) { _, newValue in
            prefs.forceCorrectHotkey = newValue
        }
        .onChange(of: undoCorrectionHotkey) { _, newValue in
            prefs.undoCorrectionHotkey = newValue
        }
    }
}

#Preview {
    SettingsView()
}
