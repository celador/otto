import Foundation
import Testing
@testable import Hermes

struct SharedPhotoTextTests {
    @Test func photoMessageGetsItsTextBack() {
        let sid = "test_\(UUID().uuidString)"
        defer { PhotoStore.deleteAll(sessionID: sid) }
        PhotoStore.save([Data([0xFF, 0xD8, 0xFF])], text: "What is in this photo?", sessionID: sid)
        var t = Transcript(items: [.user(UserMessage(id: "h1", text: "", placeholderImages: 1))])
        t.attachStoredPhotos(sessionID: sid)
        guard case .user(let m) = t.items[0] else { Issue.record("not user"); return }
        #expect(m.images.count == 1)
        #expect(m.text == "What is in this photo?")
        // A reload carries images (and now the text) over from the old transcript first.
        var fresh = Transcript(items: [.user(UserMessage(id: "h2", text: "", placeholderImages: 1))])
        fresh.adoptLocalImages(from: t)
        fresh.attachStoredPhotos(sessionID: sid)
        guard case .user(let n) = fresh.items[0] else { Issue.record("not user"); return }
        #expect(n.text == "What is in this photo?")
    }
}
