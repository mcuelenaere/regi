import XCTest
@testable import RegiE2ECore

/// The JSON format is the interface scenarios are authored against, by hand or
/// by a generator, so it is tested as an interface: hand-written text must
/// parse, and every built-in scenario must survive a round trip.
final class ScenarioCodingTests: XCTestCase {

    private func decode(_ json: String) throws -> Scenario {
        try JSONDecoder().decode(Scenario.self, from: Data(json.utf8))
    }

    func testHandWrittenScenarioParses() throws {
        let s = try decode("""
        {
          "id": "demo", "title": "hand written", "tags": ["keyboard"],
          "steps": [
            {"do": "focusRegi"},
            {"do": "modifier", "key": "leftShift", "down": true},
            {"do": "key", "key": "a", "action": "tap", "holdMillis": 50},
            {"do": "modifier", "key": "leftShift", "down": false},
            {"do": "settle", "quietMillis": 300, "maxMillis": 2000},
            {"expect": "keySubsequence", "keys": [{"key": "a", "down": true, "characters": "A"}]},
            {"expect": "nothingHeld"}
          ]
        }
        """)
        XCTAssertEqual(s.id, "demo")
        XCTAssertEqual(s.steps.count, 7)
        XCTAssertEqual(s.steps[1], .modifier(kvk: 0x38, down: true))
        XCTAssertEqual(s.steps[2], .key(kvk: 0x00, action: .tap(holdMillis: 50)))
        XCTAssertEqual(s.steps[5],
                       .expect(.keySubsequence([KeyMatcher(kvk: 0x00, down: true, characters: "A")])))
    }

    /// Sensible defaults matter for authoring: omitting them should not be an
    /// error, and should mean the obvious thing.
    func testDefaultsAreForgiving() throws {
        let s = try decode("""
        {"id": "d", "title": "t", "steps": [
          {"do": "key", "key": "escape"},
          {"do": "modifier", "key": "leftCommand"},
          {"do": "click", "x": 10, "y": 20},
          {"do": "settle"},
          {"expect": "cursorEndsNear", "x": 1, "y": 2}
        ]}
        """)
        XCTAssertEqual(s.steps[0], .key(kvk: 0x35, action: .tap(holdMillis: 40)))
        XCTAssertEqual(s.steps[1], .modifier(kvk: 0x37, down: true))
        XCTAssertEqual(s.steps[2], .click(button: .left, x: 10, y: 20, count: 1))
        XCTAssertEqual(s.steps[3], .settle(quietMillis: 300, maxMillis: 2500))
        XCTAssertEqual(s.steps[4], .expect(.cursorEndsNear(x: 1, y: 2, tolerance: 2)))
    }

    func testEveryBuiltInScenarioRoundTrips() throws {
        let json = try ScenarioFile.json(for: Catalogue.all)
        let back = try JSONDecoder().decode([Scenario].self, from: Data(json.utf8))
        XCTAssertEqual(back, Catalogue.all,
                       "the exported catalogue is the worked example set — if it "
                       + "does not round trip, the examples are wrong")
    }

    func testFileAcceptsBareArrayAndWrapper() throws {
        let dir = FileManager.default.temporaryDirectory
        let bare = dir.appendingPathComponent("bare.json")
        let wrapped = dir.appendingPathComponent("wrapped.json")
        let body = try ScenarioFile.json(for: [Catalogue.singleKey])
        try body.write(to: bare, atomically: true, encoding: .utf8)
        try "{\"scenarios\": \(body)}".write(to: wrapped, atomically: true, encoding: .utf8)

        XCTAssertEqual(try ScenarioFile.load(contentsOf: bare).count, 1)
        XCTAssertEqual(try ScenarioFile.load(contentsOf: wrapped).count, 1,
                       "a generated file should be able to carry notes alongside")
    }

    // MARK: - Errors a generator will actually hit

    func testUnknownKeyIsNamedClearly() {
        XCTAssertThrowsError(try decode("""
        {"id":"d","title":"t","steps":[{"do":"key","key":"Wingding"}]}
        """)) { error in
            XCTAssertTrue("\(error)".contains("Wingding"), "\(error)")
            XCTAssertTrue("\(error)".contains("schema"), "should point at the vocabulary")
        }
    }

    func testUnknownStepIsNamedClearly() {
        XCTAssertThrowsError(try decode("""
        {"id":"d","title":"t","steps":[{"do":"teleport"}]}
        """)) { error in
            XCTAssertTrue("\(error)".contains("teleport"), "\(error)")
        }
    }

    func testMissingFieldSaysWhichAndWhere() {
        XCTAssertThrowsError(try decode("""
        {"id":"d","title":"t","steps":[{"do":"moveTo","x":10}]}
        """)) { error in
            XCTAssertTrue("\(error)".contains("\"y\""), "\(error)")
            XCTAssertTrue("\(error)".contains("moveTo"), "\(error)")
        }
    }

    func testKeyNamesAreUnambiguousBothWays() {
        for (name, kvk) in KeyNames.byName {
            XCTAssertEqual(try? KeyNames.keyCode(name), kvk)
        }
        // Every name a scenario could be exported with must parse back.
        for kvk in KeyNames.byKeyCode.keys {
            let name = KeyNames.name(kvk)
            XCTAssertEqual(try? KeyNames.keyCode(name), kvk,
                           "exported name \"\(name)\" does not round trip")
        }
    }
}
