import Foundation
import Testing
@testable import WEFormat

/// The shapes a `visible` key takes in real `scene.json` files, and what each one means.
@Suite("SceneVisibility")
struct SceneVisibilityTests {

    private func decode(_ json: String) throws -> SceneVisibility {
        // Wrapped in an array: a bare `false` is not a JSON document the decoder accepts.
        try JSONDecoder().decode([SceneVisibility].self, from: Data("[\(json)]".utf8))[0]
    }

    @Test("Plain values are constants")
    func constants() throws {
        #expect(try decode("true") == .constant(true))
        #expect(try decode("false") == .constant(false))
        #expect(try decode("0") == .constant(false))
        #expect(try decode(#""1""#) == .constant(true))
    }

    @Test("A checkbox binding keeps its property and the value it was saved with")
    func checkboxBinding() throws {
        // Real content: film grain shipped switched off behind a "deep film grain" checkbox.
        // This shape used to decode as "not given" — visible — so the grain always ran.
        let visibility = try decode(#"{"user":"deep_film_grain","value":false}"#)
        #expect(visibility == .userProperty(name: "deep_film_grain", condition: nil, value: false))
        #expect(visibility.staticValue == false)
        #expect(visibility.isUserBound)
    }

    @Test("A checkbox binding follows the user's setting, and its saved value until then")
    func checkboxFollowsTheProperty() {
        let visibility = SceneVisibility.userProperty(name: "grain", condition: nil, value: false)
        #expect(!visibility.isVisible(with: [:]))
        #expect(visibility.isVisible(with: ["grain": .bool(true)]))
        #expect(!visibility.isVisible(with: ["grain": .bool(false)]))
        #expect(visibility.isVisible(with: ["grain": .number(1)]))
    }

    @Test("A list binding shows while its option is the one chosen")
    func listBinding() throws {
        // An author offering "style 1 / style 2" keeps both variants in the scene and shows
        // one, keyed by the list's value.
        let visibility = try decode(#"{"user":{"condition":"2","name":"style"},"value":false}"#)
        #expect(visibility == .userProperty(name: "style", condition: "2", value: false))

        #expect(!visibility.isVisible(with: [:]))
        #expect(visibility.isVisible(with: ["style": .string("2")]))
        #expect(visibility.isVisible(with: ["style": .number(2)]), "2.0 must match the option 2")
        #expect(!visibility.isVisible(with: ["style": .string("1")]))
    }

    @Test("A script-driven value falls back to what the editor saved")
    func scriptFallsBackToSaved() throws {
        let visibility = try decode(#"{"script":"export function update() {}","value":false}"#)
        #expect(visibility == .constant(false))
    }

    @Test("Bindings survive a round trip")
    func roundTrips() throws {
        for original in [
            SceneVisibility.userProperty(name: "grain", condition: nil, value: false),
            .userProperty(name: "style", condition: "2", value: true),
            .constant(false),
            .expression("time > 3"),
        ] {
            let data = try JSONEncoder().encode([original])
            #expect(try JSONDecoder().decode([SceneVisibility].self, from: data)[0] == original)
        }
    }
}
