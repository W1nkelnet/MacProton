import SwiftUI

/// The download queue: progress, pausing and continuing.
struct DownloadsView: View {
    @EnvironmentObject private var installer: Installer

    var body: some View {
        if installer.downloads.isEmpty {
            ContentUnavailableView {
                Label("Keine Downloads", systemImage: "arrow.down.circle")
            } description: {
                Text("Installierst oder aktualisierst du ein Spiel, erscheint es hier.")
            }
        } else {
            List {
                Section {
                    ForEach(installer.downloads) { DownloadRow(download: $0) }
                } footer: {
                    Text("Downloads laufen nacheinander. Beim Fortsetzen, auch nach einem Neustart von MacProton, gleicht steamcmd die vorhandenen Dateien ab und lädt nur, was fehlt. Entfernen behält das bereits Geladene.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct DownloadRow: View {
    let download: Download
    @EnvironmentObject private var installer: Installer

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(download.appID)/header.jpg")) { image in
                image.resizable().aspectRatio(460.0 / 215.0, contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.quaternary)
            }
            .frame(width: 120, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(download.name).font(.headline).lineLimit(1)
                ProgressView(value: download.progress)
                    .tint(download.state == .running ? .accentColor : .secondary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(download.state == .failed ? .red : download.error != nil ? .orange : .secondary)
                    .lineLimit(2)
            }

            buttons
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 6) {
            switch download.state {
            case .running, .queued:
                Button { installer.pause(download.appID) } label: { Image(systemName: "pause.fill") }
                    .help("Pausieren")
            case .paused, .failed:
                Button { installer.resume(download.appID) } label: { Image(systemName: "play.fill") }
                    .help(download.state == .failed ? "Erneut versuchen" : "Fortsetzen")
            }
            if download.state == .queued, installer.downloads.first(where: { $0.state == .queued })?.appID != download.appID {
                Button { installer.moveToFront(download.appID) } label: { Image(systemName: "arrow.up.to.line") }
                    .help("Als Nächstes laden")
            }
            Button { installer.remove(download.appID) } label: { Image(systemName: "xmark") }
                .help("Aus der Liste entfernen. Bereits Geladenes bleibt erhalten.")
        }
        .buttonStyle(.borderless)
        .font(.title3)
    }

    private var detail: String {
        var parts: [String] = []
        switch download.state {
        case .running: parts.append(download.phase)
        case .queued: parts.append("Wartet")
        case .paused: parts.append(download.phase == "Unterbrochen" ? "Unterbrochen" : "Pausiert")
        case .failed: parts.append("Fehlgeschlagen")
        }
        if download.progress > 0 { parts.append("\(Int(download.progress * 100)) %") }
        if download.bytesTotal > 0 {
            let done = ByteCountFormatter.string(fromByteCount: download.bytesDone, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: download.bytesTotal, countStyle: .file)
            parts.append("\(done) von \(total)" + (download.verifying ? " geprüft" : ""))
        }
        if download.state == .running, let speed = installer.speeds[download.appID], speed > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s")
            let left = Double(download.bytesTotal - download.bytesDone) / speed
            if left > 0, left < 30 * 86400 {
                parts.append("noch " + Duration.seconds(left).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
            }
        }
        if let error = download.error { parts.append(error) }
        return parts.joined(separator: " · ")
    }
}
