import Foundation
import LibraryKit
import Testing
@testable import DioramaApp

@Suite("TutorialPresentation")
@MainActor
struct TutorialPresentationTests {

    private func makePresentation() -> (TutorialPresentation, InMemoryPreferences) {
        let storage = InMemoryPreferences()
        return (TutorialPresentation(defaults: storage), storage)
    }

    @Test("Shown on a first run with nothing imported")
    func showsOnFirstRun() {
        let (tutorial, _) = makePresentation()
        #expect(tutorial.shouldShowOnLaunch(hasLibrary: false))
    }

    @Test("Not shown to someone who already has a library")
    func skippedWhenLibraryExists() {
        // They have plainly done this before. A walkthrough on top of a working app is an
        // interruption, not help.
        let (tutorial, _) = makePresentation()
        #expect(!tutorial.shouldShowOnLaunch(hasLibrary: true))
    }

    @Test("Not shown again once it has been seen")
    func shownOnlyOnce() {
        let (tutorial, _) = makePresentation()
        tutorial.hasBeenSeen = true
        #expect(!tutorial.shouldShowOnLaunch(hasLibrary: false))
    }

    @Test("Being seen survives a relaunch")
    func persists() {
        let storage = InMemoryPreferences()
        TutorialPresentation(defaults: storage).hasBeenSeen = true
        #expect(TutorialPresentation(defaults: storage).hasBeenSeen)
    }

    @Test("Every page has something to say")
    func stepsAreComplete() {
        // A blank page in a walkthrough is worse than no walkthrough.
        #expect(TutorialSheet.steps.count >= 3)
        for step in TutorialSheet.steps {
            #expect(!step.title.isEmpty)
            #expect(!step.body.isEmpty)
            #expect(!step.symbol.isEmpty)
        }
        #expect(TutorialSheet.steps.map(\.id) == Array(TutorialSheet.steps.indices))
    }

    @Test("The Windows path is the one Wallpaper Engine actually uses")
    func pathIsCorrect() {
        // 431960 is Wallpaper Engine's Steam app ID, and the folder is named after it. Getting
        // this wrong sends the user hunting through Program Files for something that is not
        // there, at the exact moment they have the least patience for it.
        let paths = TutorialSheet.steps.compactMap(\.copyable)
        #expect(paths.contains { $0.contains(#"steamapps\workshop\content\431960"#) })
    }
}
