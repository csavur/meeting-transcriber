@testable import MeetingTranscriber
import XCTest

/// Naming, frontmatter and write rules for the Obsidian copy of a protocol.
/// The pipeline hop that produces it is covered in `ObsidianPipelineExportTests`.
final class ObsidianNoteTests: XCTestCase {
    /// `2026-08-21 14:30` local time. Built through the same POSIX/Gregorian
    /// formatter the production code uses, so a tester in a non-Gregorian
    /// region doesn't see a different stamp than the assertion expects.
    private func date(_ value: String = "2026-08-21 14:30") throws -> Date {
        try XCTUnwrap(DateFormatter.filenameStamp("yyyy-MM-dd HH:mm").date(from: value))
    }

    // MARK: - Filename

    func testFilenameIsDateTimeThenTitle() throws {
        XCTAssertEqual(
            ObsidianNote.filename(title: "Weekly Sync", date: try date()),
            "2026-08-21 1430 Weekly Sync.md",
        )
    }

    /// The time is in the name because a daily standup and its follow-up share
    /// a date and a title; on the date alone the second note would overwrite
    /// the first.
    func testSameTitleSameDayDiffersByTime() throws {
        let morning = ObsidianNote.filename(title: "Standup", date: try date("2026-08-21 09:15"))
        let afternoon = ObsidianNote.filename(title: "Standup", date: try date("2026-08-21 16:45"))
        XCTAssertNotEqual(morning, afternoon)
    }

    // MARK: - Title sanitizing

    func testKeepsSpacesAndCase() {
        XCTAssertEqual(ObsidianNote.sanitizeTitle("Weekly Sync With Anna"), "Weekly Sync With Anna")
    }

    func testStripsCharactersIllegalInAFilename() {
        XCTAssertEqual(ObsidianNote.sanitizeTitle("Q3: Budget/Plan?"), "Q3 Budget Plan")
    }

    /// `#`, `^`, `[` and `]` are legal on APFS but break a `[[wikilink]]` to
    /// the note, which is most of the point of putting it in a vault.
    func testStripsCharactersThatBreakWikilinks() {
        XCTAssertEqual(ObsidianNote.sanitizeTitle("Retro [#3] ^final"), "Retro 3 final")
    }

    func testCollapsesWhitespaceLeftBehindByStripping() {
        XCTAssertEqual(ObsidianNote.sanitizeTitle("A  :  B"), "A B")
    }

    /// A leading dot would make the note a hidden file the vault never lists.
    func testDropsLeadingDots() {
        XCTAssertEqual(ObsidianNote.sanitizeTitle(".hidden"), "hidden")
    }

    func testEmptyTitleFallsBackToMeeting() {
        XCTAssertEqual(ObsidianNote.sanitizeTitle("///"), "Meeting")
    }

    /// Reimporting a processed recording feeds its own stem back as the title.
    /// Without the strip the note would read `2026-08-21 1430 20260503_174538_…`.
    func testStripsTimestampPrefixFromReimportedTitle() throws {
        XCTAssertEqual(
            ObsidianNote.filename(title: "20260503_174538_team_sync", date: try date()),
            "2026-08-21 1430 team_sync.md",
        )
    }

    func testCapsTitleLengthSoTheNameFitsOnDisk() throws {
        let name = ObsidianNote.filename(title: String(repeating: "x", count: 400), date: try date())
        XCTAssertLessThan(name.utf8.count, 255)
    }

    // MARK: - Frontmatter

    func testFrontmatterCarriesTheQueryableProperties() throws {
        let yaml = ObsidianNote.frontmatter(
            date: try date(), title: "Weekly Sync", app: "Zoom", participants: ["Anna", "Ben"],
        )
        XCTAssertTrue(yaml.hasPrefix("---\n"), yaml)
        XCTAssertTrue(yaml.contains("date: 2026-08-21"), yaml)
        XCTAssertTrue(yaml.contains("title: \"Weekly Sync\""), yaml)
        XCTAssertTrue(yaml.contains("app: \"Zoom\""), yaml)
        XCTAssertTrue(yaml.contains("participants: [\"Anna\", \"Ben\"]"), yaml)
        XCTAssertTrue(yaml.contains("tags: [meeting]"), yaml)
        XCTAssertTrue(yaml.hasSuffix("---\n\n"), yaml)
    }

    /// An unquoted colon makes the whole properties block unparseable, and
    /// meeting titles carry colons constantly. The `title` property is the
    /// sanitized one, so it matches the note's own name.
    func testQuotesTheTitleProperty() throws {
        let yaml = ObsidianNote.frontmatter(
            date: try date(), title: "Sync: Q3", app: "", participants: [],
        )
        XCTAssertTrue(yaml.contains("title: \"Sync Q3\""), yaml)
    }

    /// `app` and `participants` are not run through the note-name sanitizer -
    /// they never reach a filename - so a quote in them has to be escaped or
    /// it closes the scalar early.
    func testEscapesQuotesInUnsanitizedProperties() throws {
        let yaml = ObsidianNote.frontmatter(
            date: try date(), title: "Sync", app: #"He said "hi""#, participants: [],
        )
        XCTAssertTrue(yaml.contains(#"app: "He said \"hi\"""#), yaml)
    }

    /// Omitted rather than written as `[]`, so a solo recording doesn't carry
    /// an empty property in every note.
    func testOmitsEmptyParticipantsAndApp() throws {
        let yaml = ObsidianNote.frontmatter(
            date: try date(), title: "Solo", app: "", participants: [],
        )
        XCTAssertFalse(yaml.contains("participants"), yaml)
        XCTAssertFalse(yaml.contains("app:"), yaml)
    }

    func testComposePutsPropertiesBeforeTheMarkdown() throws {
        let note = ObsidianNote.compose(
            markdown: "# Protocol\n\nBody", date: try date(),
            title: "Weekly Sync", app: "Zoom", participants: [],
        )
        XCTAssertTrue(note.hasPrefix("---\n"), note)
        XCTAssertTrue(note.hasSuffix("# Protocol\n\nBody"), note)
    }

    // MARK: - Writing

    func testWriteCreatesTheFolderAndRestrictsToOwner() throws {
        let vault = try makeTempDirectory(prefix: "obsidian_vault")
            .appendingPathComponent("Meetings")

        let url = try ObsidianNote.write("hello", to: vault.appendingPathComponent("note.md"))

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "hello")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, FileManager.ownerOnlyPermissions)
    }

    // MARK: - Destination reuse

    func testReusesTheExistingNoteSoRegenerationOverwrites() throws {
        let vault = URL(fileURLWithPath: "/tmp/vault")
        let existing = vault.appendingPathComponent("2026-08-21 1430 Old Title.md")
        XCTAssertEqual(
            PipelineQueue.exportDestination(
                existing: existing, vault: vault, title: "New Title", date: try date(),
            ),
            existing,
        )
    }

    /// After the user repoints the setting, the old vault must stop receiving
    /// notes - otherwise the folder they moved away from keeps filling up.
    func testIgnoresAnExistingNoteInADifferentVault() throws {
        let old = URL(fileURLWithPath: "/tmp/old-vault/2026-08-21 1430 Sync.md")
        let vault = URL(fileURLWithPath: "/tmp/new-vault")
        XCTAssertEqual(
            PipelineQueue.exportDestination(
                existing: old, vault: vault, title: "Sync", date: try date(),
            ),
            vault.appendingPathComponent("2026-08-21 1430 Sync.md"),
        )
    }
}
