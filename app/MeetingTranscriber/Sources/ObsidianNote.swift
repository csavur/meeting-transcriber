import Foundation
import OSLog

/// Builds and writes the Obsidian copy of a generated meeting protocol.
///
/// The protocols folder keeps the pipeline's own artefacts (transcript, audio,
/// protocol) under one machine-sortable stem - `20260821_1430_weekly_sync`.
/// A vault wants the opposite: a human-readable note name that reads well in
/// the file list and in a `[[wikilink]]`, plus YAML properties so the note is
/// queryable from Dataview/Bases. So this is a *second* rendering of the same
/// markdown, not a move - nothing about the existing output folder changes.
///
/// Everything here is pure except `write`, so the naming and frontmatter rules
/// are unit-testable without touching a vault.
enum ObsidianNote {
    private static let logger = Logger(subsystem: "com.meetingtranscriber", category: "obsidian")

    /// `2026-08-21 1430` - ISO date first so the vault sorts chronologically,
    /// the time appended because two meetings a day with the same title are
    /// routine and the date alone would let the second silently overwrite the
    /// first.
    static let stampFormat = "yyyy-MM-dd HHmm"

    /// `2026-08-21` for the `date` property. Kept separate from `stampFormat`
    /// so the property stays a plain date Obsidian can parse as one.
    static let datePropertyFormat = "yyyy-MM-dd"

    /// Characters that must not reach a note name. The union of what the
    /// filesystem rejects (`/`, NUL), what Windows rejects (`\ : * ? " < > |`
    /// - vaults are commonly synced), and what Obsidian's own link syntax
    /// claims (`# ^ [ ]` break a `[[wikilink]]` to the note).
    private static let illegalInNoteName = CharacterSet(charactersIn: #"/\:*?"<>|#^[]"#)
        .union(.controlCharacters)

    /// Filenames are bytes on disk; a 200-character meeting title would push a
    /// UTF-8 name past the 255-byte limit on APFS once the stamp is prepended.
    private static let maxTitleLength = 120

    // MARK: - Naming

    /// Turn a meeting title into something usable as a note name: spaces and
    /// case preserved (unlike `ProtocolGenerator.sanitizeSlug`, which is built
    /// for a filesystem stem), illegal characters dropped.
    ///
    /// The title is run through `stripExistingTimestampPrefix` first because a
    /// reimported recording feeds its old stem back as a title, which would
    /// otherwise read `2026-08-21 1430 20260503_174538`.
    static func sanitizeTitle(_ title: String) -> String {
        let stripped = ProtocolGenerator.stripExistingTimestampPrefix(title)
        // Replaced with a space rather than removed: "Budget/Plan" is two words
        // and has to stay two words.
        let cleaned = String(String.UnicodeScalarView(
            stripped.unicodeScalars.map { illegalInNoteName.contains($0) ? " " : $0 },
        ))
        // Collapse the runs that leaves behind
        // ("Sync: Q3" → "Sync  Q3") and drop leading dots, which would make the
        // note a hidden file the vault never lists.
        let collapsed = cleaned
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .trimmingCharacters(in: .whitespaces)
        guard !collapsed.isEmpty else { return "Meeting" }
        return String(collapsed.prefix(maxTitleLength))
            .trimmingCharacters(in: .whitespaces)
    }

    /// `2026-08-21 1430 Weekly Sync.md`.
    static func filename(title: String, date: Date) -> String {
        let stamp = DateFormatter.filenameStamp(stampFormat).string(from: date)
        return "\(stamp) \(sanitizeTitle(title)).md"
    }

    // MARK: - Frontmatter

    /// YAML properties block, terminated by a blank line so the markdown that
    /// follows starts cleanly.
    ///
    /// `participants` is omitted when empty rather than written as `[]`, so a
    /// solo recording doesn't show an empty property in every note.
    static func frontmatter(
        date: Date, title: String, app: String, participants: [String],
    ) -> String {
        var lines = ["---"]
        lines.append("date: \(DateFormatter.filenameStamp(datePropertyFormat).string(from: date))")
        lines.append("title: \(yamlQuoted(sanitizeTitle(title)))")
        if !app.isEmpty { lines.append("app: \(yamlQuoted(app))") }
        if !participants.isEmpty {
            lines.append("participants: [\(participants.map(yamlQuoted).joined(separator: ", "))]")
        }
        lines.append("tags: [meeting]")
        lines.append("---")
        return lines.joined(separator: "\n") + "\n\n"
    }

    /// Always double-quote scalars. Meeting titles carry colons ("Sync: Q3"),
    /// leading `#`, and quotes often enough that quoting unconditionally is the
    /// only rule that can't produce invalid YAML.
    private static func yamlQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// The complete note: properties, then the markdown exactly as it was
    /// written to the protocols folder.
    static func compose(
        markdown: String, date: Date, title: String, app: String, participants: [String],
    ) -> String {
        frontmatter(date: date, title: title, app: app, participants: participants) + markdown
    }

    // MARK: - Writing

    /// Write `note` into the vault folder. Mirrors `ProtocolGenerator.saveProtocol`:
    /// paired security-scoped access (the folder arrives as a user-picked
    /// bookmark) and owner-only permissions, since the note carries the same
    /// meeting speech the protocol does.
    ///
    /// - Parameter url: the exact destination. Callers that already exported
    ///   this job pass back the stored path so a protocol regenerated after
    ///   speaker naming overwrites its note instead of forking a second one.
    static func write(_ note: String, to url: URL) throws -> URL {
        let dir = url.deletingLastPathComponent()
        let accessing = dir.startAccessingSecurityScopedResource()
        defer { if accessing { dir.stopAccessingSecurityScopedResource() } }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try note.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.restrictToOwner(url)
        logger.info("Obsidian note saved: \(url.lastPathComponent, privacy: .private)")
        return url
    }
}
