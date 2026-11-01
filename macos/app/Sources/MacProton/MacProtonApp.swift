import SwiftUI

@main
struct MacProtonApp: App {
    @StateObject private var library = Library()
    @StateObject private var runner = Runner()
    @StateObject private var installer = Installer()
    @StateObject private var sync = LibrarySync()
    @StateObject private var login = SteamLogin()
    @StateObject private var steamcmdSetup = SteamCMDSetup()
    @StateObject private var updates = UpdateChecker()
    @StateObject private var appUpdates = AppUpdateChecker()
    @StateObject private var cloudAccount = SteamCloudAccount()

    var body: some Scene {
        WindowGroup("MacProton") {
            RootView()
                .environmentObject(library)
                .environmentObject(runner)
                .environmentObject(installer)
                .environmentObject(sync)
                .environmentObject(login)
                .environmentObject(steamcmdSetup)
                .environmentObject(updates)
                .environmentObject(appUpdates)
                .frame(minWidth: 720, minHeight: 480)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                // The licenses of the software MacProton ships, bundled by build-app.sh
                Button("Lizenzen …") {
                    if let url = Bundle.main.url(forResource: "Licenses", withExtension: nil) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .disabled(Bundle.main.url(forResource: "Licenses", withExtension: nil) == nil)
            }
        }
        Settings {
            SettingsView()
                .environmentObject(login)
                .environmentObject(cloudAccount)
        }
    }
}

/// Shows the welcome screen until the first setup is done, then the library.
private struct RootView: View {
    @EnvironmentObject private var login: SteamLogin
    @EnvironmentObject private var steamcmdSetup: SteamCMDSetup
    @AppStorage("onboardingDone") private var onboardingDone = false

    var body: some View {
        Group {
            if onboardingDone { LibraryView() } else { WelcomeView() }
        }
        .sheet(isPresented: $login.isPresented) { LoginView() }
        .onAppear { steamcmdSetup.setUpIfNeeded() }
    }
}
