import SwiftUI

/// The user's launch options for a game, with a choice of Direct3D version.
struct LaunchOptionsView: View {
    let game: Game
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var graphics: Graphics
    @State private var extra: String
    @State private var driver: VulkanDriver?
    @State private var zink: Bool

    enum Graphics: String, CaseIterable {
        case game = "", dx11 = "-dx11", dx12 = "-dx12"

        var title: String {
            switch self {
            case .game: return "Wie vom Spiel vorgesehen"
            case .dx11: return "Direct3D 11 (-dx11)"
            case .dx12: return "Direct3D 12 (-dx12)"
            }
        }

        /// Also Unreal's other spellings
        static func of(_ option: String) -> Graphics? {
            switch option.lowercased() {
            case "-dx11", "-d3d11": return .dx11
            case "-dx12", "-d3d12": return .dx12
            default: return nil
            }
        }
    }

    init(game: Game) {
        self.game = game
        let options = InstallScripts.split(game.launchOptions ?? "")
        _graphics = State(initialValue: options.compactMap(Graphics.of).last ?? .game)
        _extra = State(initialValue: options.filter { Graphics.of($0) == nil }.joined(separator: " "))
        _driver = State(initialValue: game.vulkanDriver)
        _zink = State(initialValue: game.openGLZink ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Startoptionen", systemImage: "slider.horizontal.3")
                .font(.title2.weight(.semibold))
            Text(game.name).font(.callout).foregroundStyle(.secondary)

            Picker("Grafik", selection: $graphics) {
                ForEach(Graphics.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Text("Diese Schalter verstehen vor allem Spiele mit Unreal Engine. Direct3D 11 läuft auf dem Mac am zuverlässigsten, Direct3D 12 ist noch in Arbeit.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Grafiktreiber", selection: $driver) {
                Text("Standard (\(VulkanDriver.standard.title))").tag(VulkanDriver?.none)
                ForEach(VulkanDriver.allCases, id: \.self) { Text($0.title).tag(VulkanDriver?.some($0)) }
            }
            .disabled(!VulkanDriver.kosmicKrispAvailable)

            Toggle("OpenGL über Vulkan (Zink)", isOn: $zink)
                .disabled(!VulkanDriver.kosmicKrispAvailable)
            Text("Für OpenGL-Spiele: Mesas Zink bietet OpenGL 4.6 auf KosmicKrisp, macOS selbst nur 4.1.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Weitere Startoptionen", text: $extra, prompt: Text("z. B. -windowed"))
            if !game.arguments.isEmpty {
                Text("Steam übergibt außerdem: \(game.arguments)")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
            }

            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Sichern") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func save() {
        var updated = library.games.first { $0.appID == game.appID } ?? game
        let options = ([graphics.rawValue] + InstallScripts.split(extra)).filter { !$0.isEmpty }
        updated.launchOptions = options.isEmpty ? nil : options.joined(separator: " ")
        updated.vulkanDriver = driver
        updated.openGLZink = zink ? true : nil
        library.upsert(updated)
    }
}
