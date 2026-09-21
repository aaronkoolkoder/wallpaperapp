import Foundation
import Testing
@testable import WEFormat

/// Properties written as objects once they are scripted or bound to a user setting.
///
/// Every shape here is copied from a real `scene.json`. Before these were read, each of them
/// decoded as nil and the renderer fell back to a default: the scene's corner for an origin,
/// white for a colour, and no layer at all for text.
@Suite("Properties in object form")
struct PropertyObjectFormTests {

    private func object(_ json: String) throws -> SceneObject {
        try JSONDecoder().decode(SceneObject.self, from: Data(json.utf8))
    }

    @Test("A scripted origin keeps its authored position")
    func scriptedOrigin() throws {
        let decoded = try object("""
        {"id": 1, "image": "models/a.json",
         "origin": {"script": "export function update(value) { return value; }",
                    "value": "960.00000 540.00000 0.00000"}}
        """)
        #expect(decoded.origin == WEVector3(960, 540, 0))
        #expect(decoded.scripts["origin"] != nil)
    }

    @Test("A value-only object reads like the plain value")
    func valueOnly() throws {
        let decoded = try object("""
        {"id": 1, "image": "models/a.json",
         "origin": {"value": "10 20 30"}, "angles": {"value": "0 0 1.5"},
         "scale": {"value": "2 2 1"}, "alpha": {"value": 0.25}}
        """)
        #expect(decoded.origin == WEVector3(10, 20, 30))
        #expect(decoded.angles == WEVector3(0, 0, 1.5))
        #expect(decoded.scale == WEVector3(2, 2, 1))
        #expect(decoded.alpha == 0.25)
    }

    @Test("A colour bound to a user setting keeps its saved colour")
    func boundColour() throws {
        let decoded = try object("""
        {"id": 1, "image": "models/a.json",
         "color": {"user": "textcolor", "value": "1.00000 0.50000 0.00000"}}
        """)
        #expect(decoded.color == WEVector3(1, 0.5, 0))
    }

    @Test("Scripted text keeps its text")
    func scriptedText() throws {
        let decoded = try object("""
        {"id": 7, "name": "Clock", "font": "fonts/SF-Pro-Display-Medium.otf",
         "text": {"script": "export function update(value) { return value; }",
                  "scriptproperties": {"delimiter": ":", "showSeconds": false},
                  "value": "12:34"}}
        """)
        #expect(decoded.kind == .text)
        #expect(decoded.text == "12:34")
    }

    @Test("Text bound to a user setting keeps its text")
    func boundText() throws {
        let decoded = try object("""
        {"id": 7, "name": "Label", "text": {"user": "label", "value": "Your text here"}}
        """)
        #expect(decoded.text == "Your text here")
    }

    @Test("Plain values still read as before")
    func plainValues() throws {
        let decoded = try object("""
        {"id": 1, "image": "models/a.json", "origin": "1 2 3", "alpha": "0.5", "text": "hi"}
        """)
        #expect(decoded.origin == WEVector3(1, 2, 3))
        #expect(decoded.alpha == 0.5)
        #expect(decoded.text == "hi")
    }

    @Test("An object without a value reads as absent rather than failing the object")
    func objectWithoutValue() throws {
        let decoded = try object("""
        {"id": 1, "image": "models/a.json", "origin": {"script": "x"}, "alpha": {"user": "a"}}
        """)
        #expect(decoded.origin == nil)
        #expect(decoded.alpha == nil)
        #expect(decoded.kind == .image)
    }
}
