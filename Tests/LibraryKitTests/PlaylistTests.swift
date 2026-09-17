import Foundation
import Testing
@testable import LibraryKit

@Suite("PlaylistScheduler")
struct PlaylistSchedulerTests {

    private let scheduler = PlaylistScheduler()
    private let allPlayable: (String) -> Bool = { _ in true }

    private func playlist(
        _ ids: [String] = ["a", "b", "c"],
        order: PlaylistOrder = .inOrder,
        trigger: PlaylistTrigger = .interval(seconds: 60),
        skipsUnsupported: Bool = true
    ) -> Playlist {
        Playlist(
            name: "Test", wallpaperIDs: ids, order: order,
            trigger: trigger, skipsUnsupported: skipsUnsupported
        )
    }

    // MARK: - Advancing in order

    @Test("Advances through the list and wraps")
    func advancesInOrder() {
        var state = PlaylistScheduler.State()
        var seen: [String] = []
        for _ in 0 ..< 4 {
            let result = scheduler.advance(
                playlist(), state: state, now: .now, isPlayable: allPlayable
            )
            seen.append(result!.wallpaperID)
            state = result!.state
        }
        #expect(seen == ["b", "c", "a", "b"])
    }

    @Test("An empty playlist yields nothing rather than crashing")
    func emptyPlaylist() {
        #expect(
            scheduler.advance(
                playlist([]), state: .init(), now: .now, isPlayable: allPlayable
            ) == nil
        )
    }

    @Test("A single-entry playlist keeps returning that entry")
    func singleEntry() {
        let result = scheduler.advance(
            playlist(["only"]), state: .init(), now: .now, isPlayable: allPlayable
        )
        #expect(result?.wallpaperID == "only")
    }

    // MARK: - Skipping unsupported

    @Test("Skips wallpapers that would not render")
    func skipsUnsupported() {
        var state = PlaylistScheduler.State()
        var seen: Set<String> = []
        for _ in 0 ..< 6 {
            let result = scheduler.advance(
                playlist(["a", "broken", "c"]), state: state, now: .now,
                isPlayable: { $0 != "broken" }
            )
            seen.insert(result!.wallpaperID)
            state = result!.state
        }
        #expect(!seen.contains("broken"))
        #expect(seen == ["a", "c"])
    }

    @Test("When every entry is unplayable it still returns one")
    func allUnsupportedStillAdvances() {
        // Otherwise the playlist appears stuck with no explanation; better to let the wallpaper
        // fail visibly than to silently do nothing.
        let result = scheduler.advance(
            playlist(["a", "b"]), state: .init(), now: .now, isPlayable: { _ in false }
        )
        #expect(result != nil)
    }

    @Test("Skipping can be turned off")
    func skippingIsOptional() {
        var state = PlaylistScheduler.State()
        var seen: Set<String> = []
        for _ in 0 ..< 6 {
            let result = scheduler.advance(
                playlist(["a", "broken", "c"], skipsUnsupported: false),
                state: state, now: .now, isPlayable: { $0 != "broken" }
            )
            seen.insert(result!.wallpaperID)
            state = result!.state
        }
        #expect(seen.contains("broken"))
    }

    // MARK: - Shuffle

    @Test("Shuffle visits every wallpaper before repeating")
    func shuffleCoversAll() {
        var state = PlaylistScheduler.State()
        var seen: [String] = []
        let list = playlist(["a", "b", "c", "d"], order: .shuffle)
        for _ in 0 ..< 4 {
            let result = scheduler.advance(
                list, state: state, now: .now, isPlayable: allPlayable
            )
            seen.append(result!.wallpaperID)
            state = result!.state
        }
        #expect(Set(seen).count == 4)
    }

    @Test("Shuffle avoids repeating across the seam between passes")
    func shuffleAvoidsSeamRepeat() {
        // Technically random, but the same wallpaper twice in a row reads as the rotation being
        // broken. Run it repeatedly since the failure would be intermittent.
        for _ in 0 ..< 60 {
            let ids = ["a", "b", "c"]
            let shuffled = PlaylistScheduler.reshuffle(ids, avoidingFirst: "a")
            #expect(shuffled.first != "a")
            #expect(Set(shuffled) == Set(ids))
        }
    }

    @Test("Reshuffling a single entry is a no-op rather than an error")
    func reshuffleSingle() {
        #expect(PlaylistScheduler.reshuffle(["only"], avoidingFirst: "only") == ["only"])
        #expect(PlaylistScheduler.reshuffle([], avoidingFirst: nil).isEmpty)
    }

    // MARK: - Triggers

    @Test("Interval fires only once the interval has elapsed")
    func intervalTiming() {
        let now = Date()
        let state = PlaylistScheduler.State(index: 0, lastAdvance: now.addingTimeInterval(-30))
        let list = playlist(trigger: .interval(seconds: 60))

        #expect(scheduler.shouldAdvance(list, state: state, now: now) == false)
        #expect(
            scheduler.shouldAdvance(list, state: state, now: now.addingTimeInterval(31)) == true
        )
    }

    @Test("A zero or negative interval never fires")
    func zeroIntervalNeverFires() {
        // Content or a bad edit could set this; spinning on a zero interval would rotate the
        // wallpaper every tick.
        let list = playlist(trigger: .interval(seconds: 0))
        #expect(scheduler.shouldAdvance(list, state: .init(), now: .now) == false)
    }

    @Test("Manual never fires on its own")
    func manualNeverFires() {
        #expect(
            scheduler.shouldAdvance(
                playlist(trigger: .manual), state: .init(), now: .now
            ) == false
        )
    }

    @Test("Appearance trigger fires only on an actual change")
    func appearanceTrigger() {
        let list = playlist(trigger: .appearanceChange)
        #expect(scheduler.shouldAdvance(list, state: .init(), now: .now) == false)
        #expect(
            scheduler.shouldAdvance(
                list, state: .init(), now: .now, appearanceChanged: true
            ) == true
        )
    }

    @Test("Time of day fires once when its time passes")
    func timeOfDayFires() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let nineAM = calendar.date(byAdding: .minute, value: 9 * 60, to: today)!

        #expect(
            PlaylistScheduler.scheduledTimePassed(
                minutes: [9 * 60],
                since: nineAM.addingTimeInterval(-600),
                now: nineAM.addingTimeInterval(60)
            )
        )
        // Not yet reached.
        #expect(
            PlaylistScheduler.scheduledTimePassed(
                minutes: [9 * 60],
                since: nineAM.addingTimeInterval(-600),
                now: nineAM.addingTimeInterval(-60)
            ) == false
        )
    }

    @Test("A multi-day gap fires once, not once per missed day")
    func multiDayGapFiresOnce() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let longAgo = calendar.date(byAdding: .day, value: -5, to: today)!
        // Waking after the machine slept for days must not trigger a burst of advances.
        #expect(
            PlaylistScheduler.scheduledTimePassed(
                minutes: [8 * 60], since: longAgo, now: today.addingTimeInterval(9 * 3600)
            )
        )
    }

    @Test("A first run does not fire retroactively")
    func firstRunDoesNotFire() {
        // `lastAdvance` defaults to distantPast; walking forward from there would otherwise
        // fire immediately on launch for every configured time.
        #expect(
            PlaylistScheduler.scheduledTimePassed(
                minutes: [0, 720], since: .distantPast, now: .now
            ) == false
        )
    }

    @Test("No configured times never fires")
    func emptyTimesNeverFire() {
        #expect(
            scheduler.shouldAdvance(
                playlist(trigger: .timesOfDay([])), state: .init(), now: .now
            ) == false
        )
    }

    @Test("An empty playlist never reports as due")
    func emptyNeverDue() {
        let state = PlaylistScheduler.State(lastAdvance: .distantPast)
        #expect(
            scheduler.shouldAdvance(
                playlist([], trigger: .interval(seconds: 1)), state: state, now: .now
            ) == false
        )
    }

    // MARK: - Persistence

    @Test("Playlists round-trip through Codable")
    func codableRoundTrip() throws {
        let original = playlist(["a", "b"], order: .shuffle, trigger: .timesOfDay([480, 1080]))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Playlist.self, from: data)
        #expect(decoded == original)
    }

    @Test("Trigger labels read as plain English")
    func triggerLabels() {
        #expect(PlaylistTrigger.interval(seconds: 3600).label == "Every 1 hour")
        #expect(PlaylistTrigger.interval(seconds: 1800).label == "Every 30 minutes")
        #expect(PlaylistTrigger.interval(seconds: 45).label == "Every 45 seconds")
        #expect(PlaylistTrigger.manual.label == "Manually")
    }
}
