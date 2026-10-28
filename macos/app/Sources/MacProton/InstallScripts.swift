import Foundation

/// Steam runs a game's install scripts (installscript.vdf) once before its
/// first start, e.g. to install the Visual C++ runtime the game ships in
/// _CommonRedist; Proton does that in the game's prefix. MacProton runs them
/// the same way and records the steps done in the prefix.
enum InstallScripts {
    struct Step {
        /// Script path relative to the install dir and entry name
        let id: String
        /// Windows path of the program
        let program: String
        let arguments: [String]
    }

    static func pending(for game: Game, prefix: URL) -> [Step] {
        let done = Set(((try? String(contentsOf: doneFile(prefix), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init))
        return steps(in: game.installDir).filter { !done.contains($0.id) }
    }

    static func markDone(_ step: Step, prefix: URL) {
        let file = doneFile(prefix)
        let text = ((try? String(contentsOf: file, encoding: .utf8)) ?? "") + step.id + "\n"
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }

    private static func doneFile(_ prefix: URL) -> URL {
        prefix.appendingPathComponent("macproton-installscripts.txt")
    }

    static func steps(in installDir: String) -> [Step] {
        let root = URL(fileURLWithPath: installDir)
        let windowsDir = "Z:" + root.path.replacingOccurrences(of: "/", with: "\\")
        var steps: [Step] = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            let relative = String(file.path.dropFirst(root.path.count + 1))
            if relative.split(separator: "/").count > 4 || relative.hasPrefix("steamapps") {
                files?.skipDescendants()
                continue
            }
            guard file.lastPathComponent.lowercased() == "installscript.vdf",
                  let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            // Wine and DXVK provide DirectX; its old installer would only put
            // Microsoft's DLLs in their place
            if relative.lowercased().contains("directx/") { continue }

            for (name, entry) in VDF.parse(text)["installscript", "Run Process"]?.entries ?? [] {
                // Only for 32-bit Windows, i.e. not for this 64-bit prefix
                if entry["Requirement_OS", "Is64BitWindows"]?.string == "0" { continue }
                var index = 1
                while let process = entry["process \(index)"]?.string {
                    let program = process.replacingOccurrences(of: "%INSTALLDIR%", with: windowsDir,
                                                               options: .caseInsensitive)
                    // Other placeholders are Steam's own, e.g. its install path
                    if !program.contains("%") {
                        steps.append(Step(id: "\(relative)/\(name)/\(index)", program: program,
                                          arguments: split(entry["command \(index)"]?.string ?? "")))
                    }
                    index += 1
                }
            }
        }
        return steps
    }

    /// Splits a command line at spaces outside double quotes.
    static func split(_ line: String) -> [String] {
        var parts: [String] = [], current = "", quoted = false
        for c in line {
            if c == "\"" { quoted.toggle() }
            else if c == " " && !quoted { if !current.isEmpty { parts.append(current); current = "" } }
            else { current.append(c) }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}
