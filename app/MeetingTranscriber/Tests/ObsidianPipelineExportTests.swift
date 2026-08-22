@testable import MeetingTranscriber
import XCTest

/// `generateProtocol` is the single choke point every protocol passes through -
/// the initial run and every regeneration after speaker naming - so the vault
/// export has to happen there and nowhere else.
@MainActor
// swiftlint:disable:next attributes balanced_xctest_lifecycle
final class ObsidianPipelineExportTests: XCTestCase {
    // swiftlint:disable implicitly_unwrapped_optional
    private var root: URL!
    private var vault: URL!
    // swiftlint:enable implicitly_unwrapped_optional

    override func setUp() async throws {
        try await super.setUp()
        root = try makeTempDirectory(prefix: "obsidian_export_test")
        vault = root.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
    }

    private func makeQueue(obsidianDir: URL?) -> PipelineQueue {
        PipelineQueue(
            engine: WhisperKitEngine(),
            diarizationFactory: { MockDiarization() },
            protocolGeneratorFactory: { MockProtocolGen() },
            outputDir: root,
            obsidianDir: obsidianDir,
            logDir: root,
        )
    }

    private var protocolsDir: URL {
        root.appendingPathComponent("protocols")
    }

    private func makeJob() throws -> PipelineJob {
        PipelineJob(
            meetingTitle: "Weekly Sync",
            appName: "Microsoft Teams",
            mixPath: URL(fileURLWithPath: "/tmp/mix.wav"),
            appPath: nil,
            micPath: nil,
            micDelay: 0,
            participants: ["Anna"],
            meetingStartTime: try XCTUnwrap(
                DateFormatter.filenameStamp("yyyy-MM-dd HH:mm").date(from: "2026-08-21 14:30"),
            ),
        )
    }

    func testProtocolIsCopiedIntoTheVault() async throws {
        let queue = makeQueue(obsidianDir: vault)
        let job = try makeJob()
        queue.enqueue(job)

        await queue.generateProtocol(
            jobID: job.id, transcript: "hello", title: job.meetingTitle, protocolsDir: protocolsDir,
        )

        let expected = vault.appendingPathComponent("2026-08-21 1430 Weekly Sync.md")
        XCTAssertEqual(queue.jobs.first?.obsidianPath, expected)
        let note = try String(contentsOf: expected, encoding: .utf8)
        XCTAssertTrue(note.contains("title: \"Weekly Sync\""), note)
        XCTAssertTrue(note.contains("app: \"Microsoft Teams\""), note)
        XCTAssertTrue(note.contains("participants: [\"Anna\"]"), note)
        // The transcript rides along, same as the protocols-folder .md.
        XCTAssertTrue(note.contains("## Full Transcript"), note)
    }

    /// The protocol is regenerated once speaker names are confirmed. The vault
    /// must end up with one note per meeting, not one per generation.
    func testRegenerationOverwritesTheSameNote() async throws {
        let queue = makeQueue(obsidianDir: vault)
        let job = try makeJob()
        queue.enqueue(job)

        await queue.generateProtocol(
            jobID: job.id, transcript: "first", title: job.meetingTitle, protocolsDir: protocolsDir,
        )
        await queue.generateProtocol(
            jobID: job.id, transcript: "[Anna] second", title: job.meetingTitle,
            protocolsDir: protocolsDir,
        )

        let notes = try FileManager.default.contentsOfDirectory(atPath: vault.path)
        XCTAssertEqual(notes, ["2026-08-21 1430 Weekly Sync.md"])
        let note = try String(contentsOf: vault.appendingPathComponent(notes[0]), encoding: .utf8)
        XCTAssertTrue(note.contains("second"), note)
        XCTAssertFalse(note.contains("first"), note)
    }

    func testNoVaultConfiguredWritesNothing() async throws {
        let queue = makeQueue(obsidianDir: nil)
        let job = try makeJob()
        queue.enqueue(job)

        await queue.generateProtocol(
            jobID: job.id, transcript: "hello", title: job.meetingTitle, protocolsDir: protocolsDir,
        )

        XCTAssertNil(queue.jobs.first?.obsidianPath)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vault.path), [])
    }

    /// A vault on an unmounted drive must cost the user a warning, not the job:
    /// the protocol itself is already on disk by the time the export runs.
    func testUnwritableVaultWarnsInsteadOfFailingTheJob() async throws {
        // A file where the folder should be, so createDirectory and write both fail.
        let blocked = root.appendingPathComponent("not-a-folder")
        try Data().write(to: blocked)
        let queue = makeQueue(obsidianDir: blocked)
        let job = try makeJob()
        queue.enqueue(job)

        await queue.generateProtocol(
            jobID: job.id, transcript: "hello", title: job.meetingTitle, protocolsDir: protocolsDir,
        )

        XCTAssertNotNil(queue.jobs.first?.protocolPath)
        XCTAssertNil(queue.jobs.first?.obsidianPath)
        let warnings = try XCTUnwrap(queue.jobs.first?.warnings)
        let mentionsObsidian = warnings.contains { $0.contains("Obsidian") }
        XCTAssertTrue(mentionsObsidian, "\(warnings)")
    }
}
