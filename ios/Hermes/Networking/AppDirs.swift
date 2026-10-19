import Foundation

/// Where the app keeps its files. iOS apps get their own container, so these are the plain
/// system folders. The Mac app is sandboxed too now, but builds before the sandbox kept their
/// files in a folder named after the bundle id (container-migration.plist moves them into the
/// container on first launch), so the Mac keeps that subfolder.
enum AppDirs {
    nonisolated static var caches: URL { scoped(.cachesDirectory) }
    nonisolated static var support: URL { scoped(.applicationSupportDirectory) }
    nonisolated static var documents: URL { scoped(.documentDirectory) }

    nonisolated private static func scoped(_ kind: FileManager.SearchPathDirectory) -> URL {
        let base = FileManager.default.urls(for: kind, in: .userDomainMask)[0]
        #if os(macOS)
        let d = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "ai.elier.hermes.mac", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
        #else
        return base
        #endif
    }
}
