import Foundation
import Testing
@testable import WEFormat

@Suite("PropertyAnimation")
struct PropertyAnimationTests {

    private func animation(_ json: String) throws -> PropertyAnimation {
        try JSONDecoder().decode(PropertyAnimation.self, from: Data(json.utf8))
    }

    /// A real intro logo: shown for three seconds, faded out over the fourth, then held.
    private let fade = """
    {"c0": [{"frame": 0, "value": 1, "back": {"enabled": true, "x": -1, "y": 0}},
            {"frame": 90, "value": 1}, {"frame": 120, "value": 0}],
     "options": {"fps": 30, "length": 120, "mode": "single", "name": "fade"}}
    """

    @Test("A single-shot timeline plays once and holds its last value")
    func single() throws {
        let fade = try animation(fade)
        #expect(fade.values(at: 0) == [1])
        #expect(fade.values(at: 2) == [1])
        #expect(abs(fade.values(at: 3.5)[0] - 0.5) < 0.0001)
        #expect(fade.values(at: 60) == [0])
    }

    @Test("A looping timeline wraps, and each channel is its own component")
    func loop() throws {
        // A real ship crossing the sky: two keys per axis over 60 frames at 2fps.
        let flight = try animation("""
        {"c0": [{"frame": 0, "value": 250}, {"frame": 60, "value": -2650}],
         "c1": [{"frame": 0, "value": -210}, {"frame": 60, "value": 1050}],
         "c2": [{"frame": 0, "value": 0}, {"frame": 60, "value": 0}],
         "options": {"fps": 2, "length": 60, "mode": "loop"}}
        """)
        let start = flight.values(at: 0), halfway = flight.values(at: 15), wrapped = flight.values(at: 30)
        #expect(start == [250, -210, 0])
        #expect(halfway == [-1200, 420, 0])
        #expect(wrapped == start)
    }

    @Test("A mirrored timeline plays back the way it came")
    func mirror() throws {
        let sway = try animation("""
        {"c0": [{"frame": 0, "value": 0}, {"frame": 10, "value": 10}],
         "options": {"fps": 10, "length": 10, "mode": "mirror"}}
        """)
        #expect(sway.values(at: 0.5) == [5])
        #expect(sway.values(at: 1.5) == [5])
        #expect(sway.values(at: 2) == [0])
    }

    @Test("A timeline written as the object form of a property is read from a scene object")
    func onSceneObject() throws {
        let object = try JSONDecoder().decode(SceneObject.self, from: Data("""
        {"id": 1, "image": "models/logo.json", "alpha": {"value": 1.0, "animation": \(fade)}}
        """.utf8))
        #expect(object.alpha == 1)
        #expect(object.animations["alpha"]?.mode == .single)
    }
}
