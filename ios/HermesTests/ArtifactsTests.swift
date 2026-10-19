import Foundation
import Testing
@testable import Hermes

struct ArtifactsTests {
    let json = """
    {"artifacts":[
     {"id":"s1:/Users/sam/x/Report.pdf","kind":"file","value":"/Users/sam/x/Report.pdf","label":"Report.pdf","session_id":"s1","profile":"default","session_title":"Acme proposal","timestamp":1791161129.3,"exists":true,"size":99566},
     {"id":"s1:/tmp/a.png","kind":"image","value":"/tmp/a.png","label":"a.png","session_id":"s1","profile":"default","session_title":"Acme proposal","timestamp":1791161000,"exists":false},
     {"id":"s2:https://example.com/a","kind":"link","value":"https://example.com/a","label":"a","session_id":"s2","profile":"webmaster","session_title":"Health check","timestamp":1791000000}
    ],"sessions_failed":0}
    """

    @Test func decodesAndFilters() throws {
        let r = try HermesClient.decoder.decode(ArtifactsResponse.self, from: Data(json.utf8))
        #expect(r.artifacts.count == 3)
        let pdf = r.artifacts[0]
        #expect(pdf.location == "~/x")
        #expect(!pdf.isMissing)
        #expect(r.artifacts[1].isMissing)
        #expect(r.artifacts[2].location == "example.com/a")
        #expect(!r.artifacts[2].isDefaultProfile)
        #expect(ArtifactFilter.visible(r.artifacts, filter: .image, query: "").map(\.label) == ["a.png"])
        #expect(ArtifactFilter.visible(r.artifacts, filter: .all, query: "acme").count == 2)
        #expect(ArtifactFilter.visible(r.artifacts, filter: .link, query: "example").count == 1)
    }
}
