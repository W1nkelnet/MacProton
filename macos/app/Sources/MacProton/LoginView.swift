import SwiftUI

/// Steam login for steamcmd: account name, then password and Steam Guard
/// code as steamcmd asks for them.
struct LoginView: View {
    @EnvironmentObject private var login: SteamLogin
    @State private var account = ""
    @State private var secret = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Bei Steam anmelden", systemImage: "person.badge.key")
                .font(.title2.weight(.semibold))
            Text("MacProton lädt Windows-Spiele mit Valves steamcmd. steamcmd braucht dafür einmalig deine Anmeldung und merkt sich danach ein Anmelde-Token. Dein Passwort geht nur an steamcmd und wird nicht gespeichert.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                TextField("Steam-Benutzername", text: $account)
                    .textContentType(.username)
                    .disabled(login.step != .idle && !isFailed)
                if !account.isEmpty && account == detectSteamAccount() {
                    Text("Aus deinem Steam-Client übernommen")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            switch login.step {
            case .password:
                SecureField("Passwort", text: $secret)
                    .textContentType(.password)
                    .onSubmit(submit)
            case .emailCode:
                prompt("Steam hat dir einen Code per E-Mail geschickt.")
                TextField("Steam-Guard-Code", text: $secret).onSubmit(submit)
            case .mobileCode:
                prompt("Gib den Code aus der Steam-App auf deinem Handy ein.")
                TextField("Steam-Guard-Code", text: $secret).onSubmit(submit)
            case .mobileConfirmation:
                prompt("Bestätige die Anmeldung in der Steam-App auf deinem Handy.")
                ProgressView().controlSize(.small)
            case .connecting:
                HStack { ProgressView().controlSize(.small); Text("Verbinde mit Steam …").font(.callout) }
            case .done:
                Label("Angemeldet als \(login.account).", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            case .idle:
                EmptyView()
            }

            HStack {
                Spacer()
                if login.step == .done {
                    Button("Fertig") { login.cancel() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Abbrechen", role: .cancel) { login.cancel() }.keyboardShortcut(.cancelAction)
                    Button(primaryTitle, action: submit)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSubmit)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { account = login.account }
        .onChange(of: login.step) { _, _ in secret = "" }
        .onDisappear { secret = "" }
    }

    private var isFailed: Bool {
        if case .failed = login.step { return true }
        return false
    }

    private var awaitsAnswer: Bool { [.password, .emailCode, .mobileCode].contains(login.step) }

    private var primaryTitle: String { awaitsAnswer ? "Weiter" : "Anmelden" }

    private var canSubmit: Bool {
        awaitsAnswer ? !secret.isEmpty : (login.step == .idle || isFailed) && !account.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func prompt(_ text: String) -> some View {
        Text(text).font(.callout)
    }

    private func submit() {
        guard canSubmit else { return }
        if awaitsAnswer {
            login.submit(secret)
            secret = ""
        } else {
            login.start(account: account.trimmingCharacters(in: .whitespaces))
        }
    }
}
