import SwiftUI

@main
struct MacProtonApp: App {
    @StateObject private var library = Library()
    @StateObject private var runner = Runner()
    @StateObject private var installer = Installer()

    var body: some Scene {
        WindowGroup("MacProton") {
            LibraryView()
                .environmentObject(library)
                .environmentObject(runner)
                .environmentObject(installer)
                .frame(minWidth: 720, minHeight: 480)
        }
        Settings {
            SettingsView()
        }
    }
}
