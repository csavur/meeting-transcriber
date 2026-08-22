import Foundation

/// Everything derived from `obsidianDirBookmark`. Mirrors
/// `AppSettings+OutputDirectory.swift` - same bookmark helpers, same
/// read-only/repair split - because a vault folder is the same kind of
/// user-picked, security-scoped location as the output folder.
extension AppSettings {
    /// Resolved vault folder, or nil when the user hasn't picked one (the
    /// default) or the bookmark no longer resolves. Unlike `effectiveOutputDir`
    /// there is no fallback location: an Obsidian export nobody asked for would
    /// scatter meeting notes into a folder that isn't a vault.
    ///
    /// Read-only: security-scoped *access* is the caller's job, and a stale
    /// bookmark is deliberately not repaired here - see `customOutputDir`.
    var obsidianDir: URL? {
        var isStale = false
        return resolveBookmark(obsidianDirBookmark, isStale: &isStale)
    }

    /// True when protocols are being copied into a vault. Cheap enough for the
    /// Settings UI, since it doesn't resolve the bookmark.
    var obsidianExportEnabled: Bool {
        obsidianDirBookmark != nil
    }

    /// Store a user-selected vault folder as a security-scoped bookmark.
    func setObsidianDir(_ url: URL) {
        guard let data = makeBookmark(for: url) else { return }
        obsidianDirBookmark = data
    }

    /// Turn the vault export off again.
    func clearObsidianDir() {
        obsidianDirBookmark = nil
    }

    /// Re-create the bookmark when macOS reports it stale (the vault moved or
    /// was renamed). Call once at launch, off the view-update path.
    func repairStaleObsidianDirBookmark() {
        var isStale = false
        guard let url = resolveBookmark(obsidianDirBookmark, isStale: &isStale), isStale,
              let refreshed = makeBookmark(for: url)
        else { return }
        obsidianDirBookmark = refreshed
    }
}
