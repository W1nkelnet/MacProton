import SwiftUI

/// The language of MacProton: that of macOS, German or English. macOS picks
/// an app's localization when it starts, so a change restarts the app.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, de, en

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system: return "Wie macOS"
        case .de: return "Deutsch"
        case .en: return "English"
        }
    }

    /// Set by apply(), as the app's own AppleLanguages preference
    static var current: AppLanguage {
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")
        switch (domain?["AppleLanguages"] as? [String])?.first {
        case "de": return .de
        case "en": return .en
        default: return .system
        }
    }

    /// Stores the choice and restarts MacProton in it
    func apply() {
        guard self != AppLanguage.current else { return }
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.environment = ProcessInfo.processInfo.environment
        // The new instance waits for this one to quit, see MacProtonApp
        configuration.arguments = ["-waitForPID", String(ProcessInfo.processInfo.processIdentifier)]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// Picks the language, asking before the restart that applies it
struct LanguagePicker: View {
    @State private var selection = AppLanguage.current
    @State private var pending: AppLanguage?

    var body: some View {
        Picker("Sprache", selection: $selection) {
            ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
        }
        .onChange(of: selection) { _, language in
            if language != AppLanguage.current { pending = language }
        }
        .confirmationDialog("MacProton startet neu, um die Sprache zu wechseln.",
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Neu starten") { pending?.apply() }
            Button("Abbrechen", role: .cancel) { selection = AppLanguage.current }
        } message: {
            Text("Laufende Downloads setzt MacProton danach fort.")
        }
    }
}
