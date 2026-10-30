import AppKit
import SwiftUI

/// How the images of Windows games reach the pixels of a Retina display.
/// MetalFX Temporal would need depth and motion vectors from the game, so
/// only the spatial scaler is offered.
enum Upscaling: String, CaseIterable {
    case system, metalFX = "metalfx", nearest

    var title: String {
        switch self {
        case .system: return "macOS (weich)"
        case .metalFX: return "MetalFX Spatial (schärfer)"
        case .nearest: return "Pixelgenau"
        }
    }

    /// Read by MoltenVK
    var environment: [String: String] {
        switch self {
        case .system: return [:]
        case .metalFX: return ["MVK_CONFIG_UPSCALING": "metalfx"]
        case .nearest: return ["MVK_CONFIG_SWAPCHAIN_MIN_MAG_FILTER_USE_NEAREST": "1"]
        }
    }

    static var current: Upscaling {
        UserDefaults.standard.string(forKey: "upscaling").flatMap(Upscaling.init) ?? .system
    }
}

struct SettingsView: View {
    @EnvironmentObject private var login: SteamLogin
    @EnvironmentObject private var cloud: SteamCloudAccount
    @AppStorage("cloudSync") private var cloudSync = true
    @State private var showCloudSignIn = false
    @AppStorage("steamAccount") private var steamAccount = ""
    @AppStorage("runtimePath") private var runtimePath = ""
    @AppStorage("syncSaves") private var syncSaves = true
    @AppStorage("metalHUD") private var metalHUD = false
    @AppStorage("steamOverlay") private var steamOverlay = true
    @AppStorage("vulkanDriver") private var vulkanDriver = VulkanDriver.standard
    @AppStorage("upscaling") private var upscaling = Upscaling.system
    @AppStorage("autoUpdate") private var autoUpdate = false
    @AppStorage("defaultGameLocation") private var gameLocation = ""

    var body: some View {
        Form {
            Section("Steam") {
                TextField("Konto", text: $steamAccount, prompt: Text(detectSteamAccount() ?? "Steam-Kontoname"))
                Text("Leer lassen, um das zuletzt in Steam angemeldete Konto zu verwenden.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Bei Steam anmelden …") {
                    login.present(account: steamAccount.isEmpty ? (detectSteamAccount() ?? "") : steamAccount)
                }
                Text("steamcmd, mit dem MacProton Spiele lädt, braucht einmalig deine Steam-Anmeldung.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Steam Cloud") {
                if let name = cloud.accountName {
                    LabeledContent("Angemeldet als", value: name.isEmpty ? "Steam-Konto" : name)
                    Toggle("Spielstände von Windows-Spielen abgleichen", isOn: $cloudSync)
                    Button("Abmelden") { cloud.signOut() }
                } else {
                    Button("Mit der Steam-App anmelden …") {
                        showCloudSignIn = true
                        cloud.startSignIn()
                    }
                }
                Text("Steam für macOS gleicht Spielstände nicht ab, die Windows-Spiele in Windows-Ordnern speichern. Mit dieser Anmeldung lädt MacProton sie vor jedem Start aus der Steam Cloud und nach dem Spielen wieder hoch. Was MacProton ersetzt, sichert es vorher. Du bestätigst die Anmeldung in der Steam-App auf dem Handy, MacProton sieht dein Passwort nicht.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Spielstände") {
                Toggle("Spielstände über Steam Cloud synchronisieren", isOn: $syncSaves)
                Text("Für Spiele, deren Windows- und Mac-Version dieselben Spielstände nutzen: Der Speicherordner im Prefix wird mit dem Mac-Ordner verknüpft, den Steam synchronisiert. Vorher werden beide gesichert.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Speicherort für Spiele") {
                HStack {
                    TextField("Ordner", text: $gameLocation, prompt: Text(Paths.gamesDir.path))
                    Button("Wählen …") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        panel.prompt = "Wählen"
                        panel.directoryURL = Paths.gameLocation
                        if panel.runModal() == .OK, let url = panel.url { gameLocation = url.path }
                    }
                    if !gameLocation.isEmpty {
                        Button("Zurücksetzen") { gameLocation = "" }
                    }
                }
                Text("Neue Spiele werden hier installiert, zum Beispiel auf einer externen Festplatte. Leer lassen für den Ordner von MacProton. Installierte Spiele bleiben, wo sie sind: Verschieben geht per Rechtsklick auf das Spiel, ein anderer Ort für ein einzelnes Spiel mit „Installieren in …“.")
                    .font(.caption).foregroundStyle(.secondary)
                if !gameLocation.isEmpty && !FileManager.default.fileExists(atPath: Paths.gameLocation.path) {
                    Label("Ordner nicht gefunden. Ist das Laufwerk angeschlossen?", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
            Section("Updates") {
                Toggle("Spiel-Updates automatisch laden", isOn: $autoUpdate)
                Text("MacProton sucht beim Start und alle vier Stunden nach Updates der installierten Windows-Spiele. Ist das aus, zeigt die Spielkarte „Update verfügbar“. Ist es an, lädt MacProton Updates selbst, wenn kein Spiel läuft. Steam verbindet sich danach kurz neu.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Anzeige") {
                Toggle("Metal-HUD mit FPS einblenden", isOn: $metalHUD)
                Text("Zeigt Apples Metal-Leistungsanzeige mit Bildrate und GPU-Zeit in Windows-Spielen. Gilt ab dem nächsten Spielstart.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Grafiktreiber", selection: $vulkanDriver) {
                    ForEach(VulkanDriver.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(!VulkanDriver.kosmicKrispAvailable)
                Text(VulkanDriver.kosmicKrispAvailable
                     ? "Der Vulkan-Treiber unter Direct3D: KosmicKrisp aus Mesa oder MoltenVK, beide auf Metal. KosmicKrisp ist der Nachfolger und kann mehr (Stream Output, Feature Level 11_1, OpenGL 4.6 über Zink). Läuft ein Spiel damit nicht, wähle in seinen Startoptionen MoltenVK."
                     : "KosmicKrisp braucht macOS 26 oder neuer, MacProton nutzt MoltenVK.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Steam-Overlay in Windows-Spielen", isOn: $steamOverlay)
                Text("Umschalt+Tab öffnet im Spiel Steams Overlay mit Freunden, Chat und Shop. Gilt ab dem nächsten Spielstart.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Hochskalierung", selection: $upscaling) {
                    ForEach(Upscaling.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text("Windows-Spiele rendern in der Fenstergröße in Punkten, auf einem Retina-Display rechnet macOS jedes Bild auf die doppelte Auflösung hoch. MetalFX Spatial macht das schärfer und kostet etwas GPU-Zeit, „Pixelgenau“ passt zu Pixel-Art. Gilt für Direct3D- und Vulkan-Spiele ab dem nächsten Spielstart.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Proton-Laufzeit") {
                HStack {
                    TextField("Ordner", text: $runtimePath, prompt: Text(Paths.runtime.path))
                    Button("Wählen …") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        if panel.runModal() == .OK, let url = panel.url { runtimePath = url.path }
                    }
                }
                Text("Der dist-Ordner aus macos/build.sh mit run.sh und files/.")
                    .font(.caption).foregroundStyle(.secondary)
                Label(Paths.runtimeAvailable ? "Laufzeit gefunden" : "Keine Laufzeit gefunden",
                      systemImage: Paths.runtimeAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(Paths.runtimeAvailable ? .green : .red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
        .sheet(isPresented: $showCloudSignIn) { CloudSignInView() }
    }
}

/// The QR code for MacProton's Steam sign-in, renewed while it waits.
private struct CloudSignInView: View {
    @EnvironmentObject private var cloud: SteamCloudAccount
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 14) {
            Label("Bei Steam anmelden", systemImage: "qrcode")
                .font(.title2.weight(.semibold))
            Text("Öffne die Steam-App auf deinem Handy, tippe auf Steam Guard und dann auf „QR-Code scannen“. Bestätige danach die Anmeldung für „MacProton“.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if let image = cloud.qrCode {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 240, height: 240)
                } else if cloud.signingIn {
                    ProgressView().frame(width: 240, height: 240)
                } else {
                    Color.clear.frame(width: 240, height: 240)
                }
            }
            .background(Color.white)
            if let error = cloud.error {
                Label(error, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Erneut versuchen") { cloud.startSignIn() }
            }
            HStack {
                Spacer()
                Button("Abbrechen") {
                    cloud.cancelSignIn()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onChange(of: cloud.accountName) { _, name in
            if name != nil { dismiss() }
        }
    }
}
