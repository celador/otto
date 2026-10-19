import AVFoundation
import Foundation

/// Otto local voice on the Mac (relay → Parakeet speech-to-text, Kokoro voices).
enum LocalVoice {
    nonisolated static let useKey = "hermes.localSTT"
    /// On unless turned off in Settings; only used when the relay says it's available.
    nonisolated static var enabled: Bool { UserDefaults.standard.object(forKey: useKey) as? Bool ?? true }
}

struct LocalVoiceStatus: Decodable, Sendable {
    let available: Bool
    let starting: Bool?
    let reason: String?
    let sttModel: String?
    let ttsModel: String?
    let defaultVoice: String?
}

private struct LocalTranscript: Decodable { let text: String; let ms: Int? }

extension CompanionClient {
    func localVoiceStatus() async throws -> LocalVoiceStatus {
        try HermesClient.decoder.decode(LocalVoiceStatus.self, from: try await rawRequest("GET", "/hermes/local-voice"))
    }

    /// 16 kHz mono PCM16 → text with Parakeet on the Mac.
    func localTranscribe(pcm16k: Data) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["audio": pcm16k.base64EncodedString(),
                                                               "mime_type": "audio/L16;rate=16000"])
        let data = try await rawRequest("POST", "/hermes/local-voice/stt", body: body)
        return try HermesClient.decoder.decode(LocalTranscript.self, from: data).text
    }
}

/// The last ~90 s of mic audio as 16 kHz PCM16, timestamped, so a finished turn can be cut out and
/// sent to Parakeet. Appended from the audio thread.
final class TurnAudio: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [(at: Date, data: Data)] = []
    private let keep: TimeInterval

    init(keep: TimeInterval = 90) { self.keep = keep }

    func append(_ data: Data, at: Date = Date()) {
        lock.withLock {
            chunks.append((at, data))
            let cutoff = at.addingTimeInterval(-keep)
            if let first = chunks.first, first.at < cutoff { chunks.removeAll { $0.at < cutoff } }
        }
    }

    /// Audio from chunks that ended at or after `since` (each chunk is ~100 ms).
    func slice(since: Date) -> Data {
        lock.withLock {
            chunks.filter { $0.at >= since }.reduce(into: Data()) { $0.append($1.data) }
        }
    }

    func reset() { lock.withLock { chunks = [] } }
}
