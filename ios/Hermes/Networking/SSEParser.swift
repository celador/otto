import Foundation

/// One dispatched Server-Sent Event.
struct SSEMessage: Equatable, Sendable {
    var id: String?
    var event: String?
    var data: String
}

/// Incremental SSE parser, fed one byte at a time.
///
/// `URLSession.AsyncBytes.lines` drops empty lines, and empty lines are what
/// dispatch an SSE event, so the stream is parsed byte-wise here instead.
/// Comment lines (`: keepalive`, `: open`) are ignored per the SSE spec.
struct SSEParser: Sendable {
    private var line: [UInt8] = []
    private var lastID: String?
    private var event: String?
    private var dataLines: [String] = []

    init() {}

    /// Feed one byte; returns a message when a blank line completes one.
    mutating func feed(byte: UInt8) -> SSEMessage? {
        guard byte == 0x0A else {
            line.append(byte)
            return nil
        }
        if line.last == 0x0D { line.removeLast() }
        let text = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)
        return process(text)
    }

    /// Convenience for tests and chunked input.
    mutating func feed(_ bytes: some Sequence<UInt8>) -> [SSEMessage] {
        bytes.compactMap { feed(byte: $0) }
    }

    private mutating func process(_ text: String) -> SSEMessage? {
        if text.isEmpty {
            defer { event = nil; dataLines = [] }
            guard !dataLines.isEmpty else { return nil }
            return SSEMessage(id: lastID, event: event, data: dataLines.joined(separator: "\n"))
        }
        if text.hasPrefix(":") { return nil }

        let field: Substring
        var value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(text)
            value = ""
        }
        switch field {
        case "id": lastID = String(value)
        case "event": event = String(value)
        case "data": dataLines.append(String(value))
        default: break
        }
        return nil
    }
}
