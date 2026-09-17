import Foundation

/// How a playlist picks the next wallpaper.
public enum PlaylistOrder: String, Sendable, Codable, CaseIterable {
    case inOrder
    case shuffle

    public var label: String {
        switch self {
        case .inOrder: "In order"
        case .shuffle: "Shuffle"
        }
    }
}

/// When a playlist advances.
public enum PlaylistTrigger: Sendable, Codable, Hashable {
    /// Every N seconds.
    case interval(seconds: TimeInterval)
    /// When the system switches between light and dark.
    case appearanceChange
    /// At fixed times of day, as minutes past midnight.
    case timesOfDay([Int])
    /// Only when the user asks.
    case manual

    public var label: String {
        switch self {
        case .interval(let seconds): "Every \(Self.describe(seconds))"
        case .appearanceChange: "When appearance changes"
        case .timesOfDay(let minutes): "\(minutes.count) time\(minutes.count == 1 ? "" : "s") a day"
        case .manual: "Manually"
        }
    }

    static func describe(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total % 3600 == 0, total >= 3600 {
            let hours = total / 3600
            return "\(hours) hour\(hours == 1 ? "" : "s")"
        }
        if total % 60 == 0, total >= 60 {
            let minutes = total / 60
            return "\(minutes) minute\(minutes == 1 ? "" : "s")"
        }
        return "\(total) second\(total == 1 ? "" : "s")"
    }
}

/// An ordered set of wallpapers that rotates.
public struct Playlist: Sendable, Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    /// Workshop IDs, in the order the user arranged them.
    public var wallpaperIDs: [String]
    public var order: PlaylistOrder
    public var trigger: PlaylistTrigger
    /// Skip a wallpaper that reports problems, so a rotation does not park on a broken one.
    public var skipsUnsupported: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        wallpaperIDs: [String] = [],
        order: PlaylistOrder = .inOrder,
        trigger: PlaylistTrigger = .interval(seconds: 1800),
        skipsUnsupported: Bool = true
    ) {
        self.id = id
        self.name = name
        self.wallpaperIDs = wallpaperIDs
        self.order = order
        self.trigger = trigger
        self.skipsUnsupported = skipsUnsupported
    }

    public var isEmpty: Bool { wallpaperIDs.isEmpty }
}

/// Decides which wallpaper a playlist should be showing.
///
/// Pure and deterministic: every decision is a function of the playlist, the current position,
/// and a supplied date. Scheduling bugs are otherwise miserable to reproduce — "it advanced
/// twice at midnight" is not something you can sit and wait for — so the whole thing is written
/// to be testable without a clock.
public struct PlaylistScheduler: Sendable {

    /// Rotation state, persisted so a playlist resumes where it left off rather than restarting
    /// from the top every launch.
    public struct State: Sendable, Codable, Hashable {
        public var index: Int
        public var lastAdvance: Date
        /// Shuffle order, regenerated each pass so a shuffle does not repeat the same sequence.
        public var shuffledIDs: [String]

        public init(index: Int = 0, lastAdvance: Date = .distantPast, shuffledIDs: [String] = []) {
            self.index = index
            self.lastAdvance = lastAdvance
            self.shuffledIDs = shuffledIDs
        }
    }

    public init() {}

    /// Whether the playlist is due to advance.
    public func shouldAdvance(
        _ playlist: Playlist,
        state: State,
        now: Date,
        appearanceChanged: Bool = false
    ) -> Bool {
        guard !playlist.isEmpty else { return false }

        switch playlist.trigger {
        case .manual:
            return false

        case .appearanceChange:
            return appearanceChanged

        case .interval(let seconds):
            guard seconds > 0 else { return false }
            return now.timeIntervalSince(state.lastAdvance) >= seconds

        case .timesOfDay(let minutes):
            guard !minutes.isEmpty else { return false }
            // Fire when a scheduled minute falls in the window since the last advance. Comparing
            // against "the current minute" instead would miss the trigger entirely whenever the
            // machine was asleep or the app was not checking at that exact moment.
            return Self.scheduledTimePassed(
                minutes: minutes, since: state.lastAdvance, now: now
            )
        }
    }

    static func scheduledTimePassed(minutes: [Int], since: Date, now: Date) -> Bool {
        guard since < now else { return false }
        // A first run has no meaningful previous advance; do not fire retroactively for every
        // scheduled time since the beginning of the epoch.
        guard since > .distantPast else { return false }

        let calendar = Calendar.current
        for minute in minutes.sorted() {
            var components = calendar.dateComponents([.year, .month, .day], from: since)
            components.hour = minute / 60
            components.minute = minute % 60
            components.second = 0
            guard var candidate = calendar.date(from: components) else { continue }

            // Walk forward day by day from the last advance, so a gap spanning several days
            // still fires exactly once rather than once per missed day.
            while candidate <= now {
                if candidate > since { return true }
                guard let next = calendar.date(byAdding: .day, value: 1, to: candidate) else {
                    break
                }
                candidate = next
            }
        }
        return false
    }

    /// The next wallpaper, and the state to persist alongside it.
    ///
    /// - Parameter isPlayable: lets the caller exclude wallpapers that would not render, without
    ///   this type needing to know anything about the library.
    public func advance(
        _ playlist: Playlist,
        state: State,
        now: Date,
        isPlayable: (String) -> Bool
    ) -> (wallpaperID: String, state: State)? {
        guard !playlist.isEmpty else { return nil }

        let candidates = playlist.skipsUnsupported
            ? playlist.wallpaperIDs.filter(isPlayable)
            : playlist.wallpaperIDs
        // Every entry unplayable: fall back to the raw list rather than silently doing nothing,
        // so the user sees the wallpaper fail rather than the playlist appearing to be stuck.
        let pool = candidates.isEmpty ? playlist.wallpaperIDs : candidates

        var next = state
        next.lastAdvance = now

        switch playlist.order {
        case .inOrder:
            next.index = (state.index + 1) % pool.count
            return (pool[next.index], next)

        case .shuffle:
            var sequence = state.shuffledIDs.filter(pool.contains)
            if sequence.isEmpty || next.index + 1 >= sequence.count {
                sequence = Self.reshuffle(pool, avoidingFirst: pool.count > 1 ? currentID(playlist, state) : nil)
                next.index = 0
            } else {
                next.index += 1
            }
            next.shuffledIDs = sequence
            return (sequence[min(next.index, sequence.count - 1)], next)
        }
    }

    private func currentID(_ playlist: Playlist, _ state: State) -> String? {
        let pool = state.shuffledIDs.isEmpty ? playlist.wallpaperIDs : state.shuffledIDs
        guard state.index >= 0, state.index < pool.count else { return nil }
        return pool[state.index]
    }

    /// Shuffle, avoiding an immediate repeat across the seam between passes.
    ///
    /// Without this the last wallpaper of one pass can be the first of the next, which reads as
    /// the rotation being broken even though it is technically random.
    static func reshuffle(_ ids: [String], avoidingFirst avoid: String?) -> [String] {
        guard ids.count > 1 else { return ids }
        var shuffled = ids.shuffled()
        if let avoid, shuffled.first == avoid {
            shuffled.swapAt(0, Int.random(in: 1 ..< shuffled.count))
        }
        return shuffled
    }
}
