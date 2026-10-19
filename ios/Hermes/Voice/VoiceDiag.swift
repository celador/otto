import Foundation

/// Voice-mode trace written to a file in the app container, so a failing session on a real device can be
/// read from the Mac (`devicectl device copy from --domain-type appDataContainer`). Small and rotating.
enum VoiceDiag {
    nonisolated static let url: URL = {
        let dir = AppDirs.documents
        return dir.appendingPathComponent("voice-diag.log")
    }()
    private nonisolated static let queue = DispatchQueue(label: "ai.elier.hermes.voicediag")
    private nonisolated static let start = Date()

    nonisolated static func log(_ message: @autoclosure () -> String) {
        let line = String(format: "%@ +%.2f %@\n", ISO8601DateFormatter().string(from: Date()),
                          Date().timeIntervalSince(start), message())
        queue.async {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               (attrs[.size] as? Int ?? 0) > 400_000 {
                try? FileManager.default.removeItem(at: url)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// Sends the trace to the relay (`POST /hermes/voice-diag`) so it can be read on the Mac wherever the
    /// phone is. Best effort; the relay keeps the last few.
    @MainActor
    static func upload(_ companion: CompanionClient?) {
        guard let companion else { return }
        queue.async {
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
            let text = String(decoding: data.suffix(300_000), as: UTF8.self)
            let device = "\(ProcessInfo.processInfo.hostName)"
            Task { try? await companion.uploadVoiceDiag(text, device: device) }
        }
    }
}
