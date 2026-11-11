import Foundation

/// Rules for syncing with other Macs, kept apart so the self-test can check them.
enum MacSync {
    /// Both Macs see each other, and only the one with the smaller ID connects.
    static func shouldDial(from mine: String, to theirs: String) -> Bool {
        !theirs.isEmpty && mine < theirs
    }

    /// The newest copies that fit in one message, leaving room under the 1 MiB frame limit.
    static func fitting(_ clips: [SyncedClip], budget: Int = 800_000) -> [SyncedClip] {
        var used = 0
        var result: [SyncedClip] = []
        for clip in clips.prefix(PhoneLinkProtocol.maxSyncedClips) {
            // JSON escaping can grow text, so this counts generously.
            let size = clip.text.utf8.count * 2 + 40
            if used + size > budget { continue }
            used += size
            result.append(clip)
        }
        return result
    }
}
