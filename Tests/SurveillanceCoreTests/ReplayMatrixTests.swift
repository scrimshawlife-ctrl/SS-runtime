import Foundation
import Testing
@testable import SurveillanceCore

@Suite(.serialized)
struct ReplayMatrixTests {
    @Test func replayT901MatrixFixtureLoads() throws {
        let entries = try ReplayMatrix.load()
        #expect(entries.count >= 1)
        #expect(entries[0].id == "RM-001")
        #expect(entries[0].fixture == "replay-smoke-001")
    }

    @Test func replayT901SmokeTripleExecutionMatchesDigest() throws {
        let entries = try ReplayMatrix.load()
        let smoke = try #require(entries.first { $0.fixture == "replay-smoke-001" })
        let digest = try ReplayMatrix.tripleRunDigest(smoke)
        #expect(digest == smoke.expectedFinalDigest)
    }

    @Test func replayT901EachMatrixEntryProducesStableDigest() throws {
        let entries = try ReplayMatrix.load()
        for entry in entries {
            if entry.tripleRunRequired {
                let digest = try ReplayMatrix.tripleRunDigest(entry)
                #expect(digest == entry.expectedFinalDigest)
            } else {
                let result = try ReplayMatrix.execute(entry)
                #expect(result.digest == entry.expectedFinalDigest)
            }
        }
    }

    @Test func gateB016KernelAndSmokeFixturesPass() throws {
        let kernel = SpecBundle.fixture("kernel-vectors-001")
        let kernelObject = try JSONSerialization.jsonObject(with: kernel) as? [String: Any]
        let version = kernelObject?["fixtureVersion"] as? String
        #expect(version == "kernel-vectors-001")

        let entries = try ReplayMatrix.load()
        for entry in entries {
            let digest = try ReplayMatrix.tripleRunDigest(entry)
            #expect(digest.count == 64)
        }
    }

    @Test func replayT901B005UnknownVersionFailsBeforeTickOne() throws {
        let json = """
        {"schemaVersion":"runtime-kernel-001","rulesetVersion":"unknown","contentVersion":"civic-seam-content-002","arenaVersion":"civic-seam-arena-001","seed":1,"commands":[]}
        """.data(using: .utf8)!
        let result = ReplayEnvelope.load(json: json)
        guard case .failure(.incompatibleIdentity) = result else {
            Issue.record("expected incompatible identity")
            return
        }
    }
}
