import SwiftUI

/// First start: sets up steamcmd with visible progress, then asks for the
/// Steam login, then opens the library.
struct WelcomeView: View {
    @EnvironmentObject private var setup: SteamCMDSetup
    @EnvironmentObject private var login: SteamLogin
    @EnvironmentObject private var installer: Installer
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var sync: LibrarySync
    @AppStorage("onboardingDone") private var onboardingDone = false
    @AppStorage("steamAccount") private var steamAccount = ""

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 96, height: 96)
                (Text("Willkommen bei MacProton") + Text(".").foregroundStyle(Theme.gradient))
                    .font(.largeTitle.weight(.bold))
                Text("Spiel deine Windows-Spiele aus Steam auf dem Mac. Spiele mit Mac-Version startet MacProton direkt über Steam.")
                    .font(.title3).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            VStack(alignment: .leading, spacing: 18) {
                step(number: 1, title: "steamcmd einrichten", done: setup.isComplete) {
                    if setup.isComplete {
                        Text("Valves steamcmd ist bereit.").foregroundStyle(.secondary)
                    } else if let error = setup.error {
                        Text(error).foregroundStyle(.red)
                        Button("Erneut versuchen") { setup.setUpIfNeeded() }
                    } else {
                        ProgressView(value: setup.progress) {
                            Text(setup.status.isEmpty ? "Bereite vor …" : setup.status).font(.callout)
                        } currentValueLabel: {
                            Text("\(Int(setup.progress * 100)) %").font(.caption).monospacedDigit()
                        }
                        .tint(Theme.blue)
                    }
                }

                step(number: 2, title: "Bei Steam anmelden", done: loggedIn) {
                    if loggedIn {
                        Text("Angemeldet als \(steamAccount).").foregroundStyle(.secondary)
                    } else {
                        Text("steamcmd braucht einmalig deine Steam-Anmeldung, um Spiele zu laden. Dein Passwort geht nur an steamcmd.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            login.present(account: steamAccount.isEmpty ? (detectSteamAccount() ?? "") : steamAccount)
                        } label: {
                            Label("Bei Steam anmelden", systemImage: "person.badge.key")
                        }
                        .disabled(!setup.isComplete)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 560)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))

            HStack(spacing: 16) {
                Button("Später") { onboardingDone = true }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Button {
                    onboardingDone = true
                    sync.sync(library: library, account: installer.account)
                } label: {
                    Text("Los geht's").font(.headline).padding(.horizontal, 28).padding(.vertical, 10)
                        .foregroundStyle(.white)
                        .background(Theme.gradient, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!setup.isComplete || !loggedIn)
                .opacity(setup.isComplete && loggedIn ? 1 : 0.4)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A login in this window, or one cached from earlier
    private var loggedIn: Bool { login.step == .done || (!steamAccount.isEmpty && !login.isPresented && login.step == .idle) }

    private func step<Content: View>(number: Int, title: String, done: Bool,
                                     @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(done ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(.quaternary))
                if done {
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.callout.weight(.semibold))
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content()
            }
            Spacer(minLength: 0)
        }
    }
}
