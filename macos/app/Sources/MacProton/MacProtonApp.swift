import SwiftUI

@main
struct MacProtonApp: App {
    @StateObject private var library = Library()
    @StateObject private var runner = Runner()
    @StateObject private var installer = Installer()
    @StateObject private var sync = LibrarySync()
    @StateObject private var login = SteamLogin()
    @StateObject private var steamcmdSetup = SteamCMDSetup()

    var body: some Scene {
        WindowGroup("MacProton") {
            LibraryView()
                .environmentObject(library)
                .environmentObject(runner)
                .environmentObject(installer)
                .environmentObject(sync)
                .environmentObject(login)
                .environmentObject(steamcmdSetup)
                .frame(minWidth: 720, minHeight: 480)
        }
        Settings {
            SettingsView()
                .environmentObject(login)
        }
    }
}
