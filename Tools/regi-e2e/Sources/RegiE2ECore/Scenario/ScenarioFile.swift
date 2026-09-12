import Foundation

/// Loads scenarios from JSON so they need not be compiled in.
///
/// This is what lets scenarios be written by hand or generated rather than
/// edited into `Catalogue.swift` and rebuilt.
public enum ScenarioFile {
    public static func load(contentsOf url: URL) throws -> [Scenario] {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        // Accept either a bare array or an object with a "scenarios" key, so a
        // generated file can carry notes alongside.
        if let wrapper = try? decoder.decode(Wrapper.self, from: data) {
            return wrapper.scenarios
        }
        return try decoder.decode([Scenario].self, from: data)
    }

    public static func json(for scenarios: [Scenario]) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return String(data: try enc.encode(scenarios), encoding: .utf8) ?? ""
    }

    private struct Wrapper: Decodable { let scenarios: [Scenario] }
}

/// The authoring vocabulary, printed by `regi-e2e schema`.
///
/// Written for whoever (or whatever) is composing scenarios: it lists the steps
/// and expectations with their fields, and names the traps that are not
/// guessable from the grammar.
public enum ScenarioSchema {
    public static var text: String {
        """
        SCENARIO FORMAT

        A file is either an array of scenarios or {"scenarios": [...]}.

        {
          "id": "key.single",
          "title": "a single key arrives once, and is released",
          "tags": ["keyboard"],
          "quarantined": false,
          "steps": [ ... ]
        }

        Tags: keyboard, pointer, modifiers, capture, lifecycle, slow
        `quarantined: true` runs and reports but never affects the exit code —
        for a known-failing case kept as documentation of the gap.

        STEPS

          {"do": "focusRegi"}                      make Regi frontmost; do this first
          {"do": "focusElsewhere"}                 focus another app (tests focus loss)
          {"do": "key", "key": "a", "action": "tap", "holdMillis": 40}
                                                   action: tap | down | up
          {"do": "modifier", "key": "leftShift", "down": true}
          {"do": "type", "text": "has"}
          {"do": "moveTo", "x": 960, "y": 540}
          {"do": "click", "button": "left", "x": 700, "y": 400, "count": 2}
          {"do": "drag", "fromX": 100, "fromY": 100, "toX": 400, "toY": 300, "steps": 8}
          {"do": "wait", "millis": 200}
          {"do": "settle", "quietMillis": 300, "maxMillis": 2500}

        EXPECTATIONS  (steps too; they run in order against what arrived so far)

          {"expect": "keySequence", "keys": [{"key": "a", "down": true}, …]}
              exactly these key events in order, nothing else of that kind
          {"expect": "keySubsequence", "keys": [...]}
              these in order, tolerating others between
          {"expect": "keyCount", "key": "l", "down": true, "min": 1, "max": 5}
          {"expect": "absent", "kind": "gesture"}      kind: key|pointer|wheel|gesture|any
          {"expect": "cursorEndsNear", "x": 960, "y": 540, "tolerance": 2}
          {"expect": "nothingHeld"}
          {"expect": "noUnmatchedReleases"}
          {"expect": "modifierEndsUp", "key": "leftCommand"}

        A key matcher may also assert the character the target produced:
          {"key": "a", "down": true, "characters": "A"}
        That is the only assertion proving modifier state actually reached the
        target rather than just a keycode.

        THINGS THAT ARE NOT GUESSABLE

        - Coordinates are framebuffer pixels on the TARGET, not screen points.
        - Modifiers must be their own `modifier` steps. Setting a flag on a
          keypress does nothing: Regi learns modifier state only from
          flagsChanged events.
        - `absent` is meaningless without a preceding `settle`; without one it
          only says "nothing had arrived yet".
        - Motion is throttled in the backends, so never assert a count of
          pointer events. Assert where the cursor ended up.
        - Do not write an expectation by running the scenario and copying what
          happened. Expectations come from what the input MEANS. A stuck
          modifier reported faithfully is still a bug, and recording it as
          expected is how it would get baked in.

        KEY NAMES

        \(KeyNames.byName.keys.sorted().joined(separator: ", "))
        """
    }
}
