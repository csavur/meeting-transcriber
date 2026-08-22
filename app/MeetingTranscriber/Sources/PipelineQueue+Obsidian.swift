import Foundation
import OSLog

private let logger = Logger(subsystem: AppPaths.logSubsystem, category: "PipelineQueue")

extension PipelineQueue {
    /// Copy a generated protocol into the user's Obsidian vault, if one is
    /// configured.
    ///
    /// Called from `generateProtocol`, which is the single choke point every
    /// protocol passes through - the initial pipeline run *and* every
    /// regeneration after speaker naming (confirm, skip, stale cleanup, late
    /// re-diarization). Exporting anywhere else would either miss the renamed
    /// version or write the note twice.
    ///
    /// Never throws: a vault on an unmounted drive must not fail a job whose
    /// protocol is already safely on disk, so a failure becomes a job warning
    /// the same way a failed protocol generation does.
    func exportToObsidian(jobID: UUID, markdown: String, title: String) {
        guard let obsidianDir, let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        let job = jobs[idx]
        let shortID = PipelineJob.shortID(for: jobID)
        // Same anchor the output-folder stem uses, so the note's date is when
        // the meeting happened rather than when the pipeline got to it.
        let date = job.meetingStartTime ?? job.enqueuedAt
        let destination = Self.exportDestination(
            existing: job.obsidianPath, vault: obsidianDir, title: title, date: date,
        )
        let note = ObsidianNote.compose(
            markdown: markdown, date: date, title: title,
            app: job.appName, participants: job.participants,
        )
        do {
            let url = try ObsidianNote.write(note, to: destination)
            // Re-find the job: the array can have been mutated while the
            // protocol was being generated.
            if let current = jobs.firstIndex(where: { $0.id == jobID }) {
                jobs[current].obsidianPath = url
            }
            logger.info("[\(shortID, privacy: .public)] obsidian_note_saved file=\(url.lastPathComponent, privacy: .private)")
        } catch {
            logger.warning("[\(shortID, privacy: .public)] obsidian_export_failed error=\(error.localizedDescription, privacy: .public)")
            addWarning(id: jobID, "Obsidian export failed - protocol saved")
        }
    }

    /// Reuse the note this job already wrote, so a regenerated protocol
    /// overwrites it instead of leaving a stale first draft behind under a
    /// different name (speaker naming changes the transcript, and the title can
    /// change with it).
    ///
    /// Only when that note is still inside the *current* vault: if the user has
    /// since pointed the setting at another folder, writing back to the old one
    /// would silently keep filling a vault they've moved away from.
    static func exportDestination(
        existing: URL?, vault: URL, title: String, date: Date,
    ) -> URL {
        if let existing,
           existing.deletingLastPathComponent().standardizedFileURL == vault.standardizedFileURL {
            return existing
        }
        return vault.appendingPathComponent(ObsidianNote.filename(title: title, date: date))
    }
}
