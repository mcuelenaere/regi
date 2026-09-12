import Foundation

/// Hand-written JSON coding, because the synthesized form is not writable by
/// hand or by a generator.
///
/// Swift's synthesized `Codable` for enums with associated values emits
/// `{"expect":{"_0":{"keySequence":{"_0":[…]}}}}` and `{"focusRegi":{}}`. The
/// shape below is flat and self-describing instead:
///
///     {"do": "key", "key": "a", "action": "tap", "holdMillis": 40}
///     {"expect": "keySequence", "keys": [{"key": "a", "down": true}]}
///
/// Keys are named, never numeric: `"leftShift"` rather than `0x38`.
/// `regi-e2e schema` prints the whole vocabulary.
private struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

private extension KeyedDecodingContainer where Key == AnyKey {
    func str(_ name: String, _ ctx: String) throws -> String {
        guard let v = try decodeIfPresent(String.self, forKey: AnyKey(name)) else {
            throw ScenarioFormatError.missingField(name, in: ctx)
        }
        return v
    }
    func int(_ name: String, _ ctx: String) throws -> Int {
        guard let v = try decodeIfPresent(Int.self, forKey: AnyKey(name)) else {
            throw ScenarioFormatError.missingField(name, in: ctx)
        }
        return v
    }
    func intOr(_ name: String, _ fallback: Int) throws -> Int {
        try decodeIfPresent(Int.self, forKey: AnyKey(name)) ?? fallback
    }
    func boolOr(_ name: String, _ fallback: Bool) throws -> Bool {
        try decodeIfPresent(Bool.self, forKey: AnyKey(name)) ?? fallback
    }
}

// MARK: - Scenario

extension Scenario: Codable {
    /// `tags` and `quarantined` are optional. A hand-written scenario should
    /// need only an id, a title and steps, and a missing optional field must
    /// not produce an error that masks the real mistake further down.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        let rawTags = try c.decodeIfPresent([String].self, forKey: AnyKey("tags")) ?? []
        self.init(id: try c.str("id", "scenario"),
                  title: try c.str("title", "scenario"),
                  tags: Set(rawTags.compactMap(Tag.init(rawValue:))),
                  quarantined: try c.boolOr("quarantined", false),
                  steps: try c.decode([Step].self, forKey: AnyKey("steps")))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(id, forKey: AnyKey("id"))
        try c.encode(title, forKey: AnyKey("title"))
        try c.encode(tags.map(\.rawValue).sorted(), forKey: AnyKey("tags"))
        try c.encode(quarantined, forKey: AnyKey("quarantined"))
        try c.encode(steps, forKey: AnyKey("steps"))
    }
}

// MARK: - KeyMatcher

extension KeyMatcher: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        self.init(kvk: try KeyNames.keyCode(try c.str("key", "key matcher")),
                  down: try c.boolOr("down", true),
                  characters: try c.decodeIfPresent(String.self, forKey: AnyKey("characters")))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(KeyNames.name(kvk), forKey: AnyKey("key"))
        try c.encode(down, forKey: AnyKey("down"))
        try c.encodeIfPresent(characters, forKey: AnyKey("characters"))
    }
}

// MARK: - Expectation

extension Expectation: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        let kind = try c.str("expect", "expectation")
        switch kind {
        case "keySequence":
            self = .keySequence(try c.decode([KeyMatcher].self, forKey: AnyKey("keys")))
        case "keySubsequence":
            self = .keySubsequence(try c.decode([KeyMatcher].self, forKey: AnyKey("keys")))
        case "keyCount":
            self = .keyCount(kvk: try KeyNames.keyCode(try c.str("key", kind)),
                             down: try c.boolOr("down", true),
                             min: try c.int("min", kind), max: try c.int("max", kind))
        case "absent":
            let raw = try c.str("kind", kind)
            guard let f = KindFilter(rawValue: raw) else {
                throw ScenarioFormatError.unknownExpectation("absent kind \"\(raw)\"")
            }
            self = .absent(f)
        case "cursorEndsNear":
            self = .cursorEndsNear(x: try c.int("x", kind), y: try c.int("y", kind),
                                   tolerance: try c.intOr("tolerance", 2))
        case "nothingHeld":         self = .nothingHeld
        case "noUnmatchedReleases": self = .noUnmatchedReleases
        case "wheelTotal":
            let axis = try c.decodeIfPresent(String.self, forKey: AnyKey("axis")) ?? "vertical"
            self = .wheelTotal(axis: axis == "horizontal" ? .horizontal : .vertical,
                               min: try c.int("min", kind), max: try c.int("max", kind))
        case "clickCount":
            let b = try c.decodeIfPresent(String.self, forKey: AnyKey("button")) ?? "left"
            self = .clickCount(button: b == "right" ? .right : .left,
                               min: try c.int("min", kind), max: try c.int("max", kind))
        case "modifierEndsUp":
            self = .modifierEndsUp(kvk: try KeyNames.keyCode(try c.str("key", kind)))
        default:
            throw ScenarioFormatError.unknownExpectation(kind)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        switch self {
        case .keySequence(let m):
            try c.encode("keySequence", forKey: AnyKey("expect"))
            try c.encode(m, forKey: AnyKey("keys"))
        case .keySubsequence(let m):
            try c.encode("keySubsequence", forKey: AnyKey("expect"))
            try c.encode(m, forKey: AnyKey("keys"))
        case .keyCount(let kvk, let down, let min, let max):
            try c.encode("keyCount", forKey: AnyKey("expect"))
            try c.encode(KeyNames.name(kvk), forKey: AnyKey("key"))
            try c.encode(down, forKey: AnyKey("down"))
            try c.encode(min, forKey: AnyKey("min"))
            try c.encode(max, forKey: AnyKey("max"))
        case .absent(let f):
            try c.encode("absent", forKey: AnyKey("expect"))
            try c.encode(f.rawValue, forKey: AnyKey("kind"))
        case .cursorEndsNear(let x, let y, let tol):
            try c.encode("cursorEndsNear", forKey: AnyKey("expect"))
            try c.encode(x, forKey: AnyKey("x"))
            try c.encode(y, forKey: AnyKey("y"))
            try c.encode(tol, forKey: AnyKey("tolerance"))
        case .nothingHeld:         try c.encode("nothingHeld", forKey: AnyKey("expect"))
        case .noUnmatchedReleases: try c.encode("noUnmatchedReleases", forKey: AnyKey("expect"))
        case .wheelTotal(let axis, let min, let max):
            try c.encode("wheelTotal", forKey: AnyKey("expect"))
            try c.encode(axis.rawValue, forKey: AnyKey("axis"))
            try c.encode(min, forKey: AnyKey("min")); try c.encode(max, forKey: AnyKey("max"))
        case .clickCount(let b, let min, let max):
            try c.encode("clickCount", forKey: AnyKey("expect"))
            try c.encode(b.rawValue, forKey: AnyKey("button"))
            try c.encode(min, forKey: AnyKey("min")); try c.encode(max, forKey: AnyKey("max"))
        case .modifierEndsUp(let kvk):
            try c.encode("modifierEndsUp", forKey: AnyKey("expect"))
            try c.encode(KeyNames.name(kvk), forKey: AnyKey("key"))
        }
    }
}

// MARK: - Step

extension Step: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        if c.contains(AnyKey("expect")) {
            self = .expect(try Expectation(from: decoder))
            return
        }
        let kind = try c.str("do", "step")
        switch kind {
        case "key":
            let action: KeyAction
            switch try c.decodeIfPresent(String.self, forKey: AnyKey("action")) ?? "tap" {
            case "down": action = .down
            case "up":   action = .up
            default:     action = .tap(holdMillis: try c.intOr("holdMillis", 40))
            }
            self = .key(kvk: try KeyNames.keyCode(try c.str("key", kind)), action: action)
        case "modifier":
            self = .modifier(kvk: try KeyNames.keyCode(try c.str("key", kind)),
                             down: try c.boolOr("down", true))
        case "type":
            self = .type(try c.str("text", kind))
        case "moveTo":
            self = .moveTo(x: try c.int("x", kind), y: try c.int("y", kind))
        case "click":
            let b = try c.decodeIfPresent(String.self, forKey: AnyKey("button")) ?? "left"
            self = .click(button: b == "right" ? .right : .left,
                          x: try c.int("x", kind), y: try c.int("y", kind),
                          count: try c.intOr("count", 1))
        case "drag":
            self = .drag(fromX: try c.int("fromX", kind), fromY: try c.int("fromY", kind),
                         toX: try c.int("toX", kind), toY: try c.int("toY", kind),
                         steps: try c.intOr("steps", 8))
        case "buttonDown", "buttonUp":
            let b = try c.decodeIfPresent(String.self, forKey: AnyKey("button")) ?? "left"
            let button: Button = b == "right" ? .right : .left
            let x = try c.int("x", kind), y = try c.int("y", kind)
            self = kind == "buttonDown" ? .buttonDown(button: button, x: x, y: y)
                                        : .buttonUp(button: button, x: x, y: y)
        case "sideButton":
            self = .sideButton(number: try c.int("number", kind),
                               x: try c.int("x", kind), y: try c.int("y", kind),
                               down: try c.boolOr("down", true))
        case "scroll":
            let axis = try c.decodeIfPresent(String.self, forKey: AnyKey("axis")) ?? "vertical"
            self = .scroll(axis: axis == "horizontal" ? .horizontal : .vertical,
                           lines: try c.int("lines", kind))
        case "autorepeat":
            self = .autorepeat(kvk: try KeyNames.keyCode(try c.str("key", kind)),
                               count: try c.intOr("count", 5),
                               intervalMillis: try c.intOr("intervalMillis", 40))
        case "focusRegi":      self = .focusRegi
        case "focusElsewhere": self = .focusElsewhere
        case "wait":           self = .wait(millis: try c.int("millis", kind))
        case "settle":
            self = .settle(quietMillis: try c.intOr("quietMillis", 300),
                           maxMillis: try c.intOr("maxMillis", 2500))
        default:
            throw ScenarioFormatError.unknownStep(kind)
        }
    }

    public func encode(to encoder: Encoder) throws {
        if case .expect(let e) = self { try e.encode(to: encoder); return }
        var c = encoder.container(keyedBy: AnyKey.self)
        switch self {
        case .key(let kvk, let action):
            try c.encode("key", forKey: AnyKey("do"))
            try c.encode(KeyNames.name(kvk), forKey: AnyKey("key"))
            switch action {
            case .down: try c.encode("down", forKey: AnyKey("action"))
            case .up:   try c.encode("up", forKey: AnyKey("action"))
            case .tap(let hold):
                try c.encode("tap", forKey: AnyKey("action"))
                try c.encode(hold, forKey: AnyKey("holdMillis"))
            }
        case .modifier(let kvk, let down):
            try c.encode("modifier", forKey: AnyKey("do"))
            try c.encode(KeyNames.name(kvk), forKey: AnyKey("key"))
            try c.encode(down, forKey: AnyKey("down"))
        case .type(let text):
            try c.encode("type", forKey: AnyKey("do"))
            try c.encode(text, forKey: AnyKey("text"))
        case .moveTo(let x, let y):
            try c.encode("moveTo", forKey: AnyKey("do"))
            try c.encode(x, forKey: AnyKey("x")); try c.encode(y, forKey: AnyKey("y"))
        case .click(let b, let x, let y, let count):
            try c.encode("click", forKey: AnyKey("do"))
            try c.encode(b.rawValue, forKey: AnyKey("button"))
            try c.encode(x, forKey: AnyKey("x")); try c.encode(y, forKey: AnyKey("y"))
            try c.encode(count, forKey: AnyKey("count"))
        case .drag(let fx, let fy, let tx, let ty, let steps):
            try c.encode("drag", forKey: AnyKey("do"))
            try c.encode(fx, forKey: AnyKey("fromX")); try c.encode(fy, forKey: AnyKey("fromY"))
            try c.encode(tx, forKey: AnyKey("toX")); try c.encode(ty, forKey: AnyKey("toY"))
            try c.encode(steps, forKey: AnyKey("steps"))
        case .buttonDown(let b, let x, let y), .buttonUp(let b, let x, let y):
            if case .buttonDown = self { try c.encode("buttonDown", forKey: AnyKey("do")) }
            else { try c.encode("buttonUp", forKey: AnyKey("do")) }
            try c.encode(b.rawValue, forKey: AnyKey("button"))
            try c.encode(x, forKey: AnyKey("x")); try c.encode(y, forKey: AnyKey("y"))
        case .sideButton(let number, let x, let y, let down):
            try c.encode("sideButton", forKey: AnyKey("do"))
            try c.encode(number, forKey: AnyKey("number"))
            try c.encode(x, forKey: AnyKey("x")); try c.encode(y, forKey: AnyKey("y"))
            try c.encode(down, forKey: AnyKey("down"))
        case .scroll(let axis, let lines):
            try c.encode("scroll", forKey: AnyKey("do"))
            try c.encode(axis.rawValue, forKey: AnyKey("axis"))
            try c.encode(lines, forKey: AnyKey("lines"))
        case .autorepeat(let kvk, let count, let interval):
            try c.encode("autorepeat", forKey: AnyKey("do"))
            try c.encode(KeyNames.name(kvk), forKey: AnyKey("key"))
            try c.encode(count, forKey: AnyKey("count"))
            try c.encode(interval, forKey: AnyKey("intervalMillis"))
        case .focusRegi:       try c.encode("focusRegi", forKey: AnyKey("do"))
        case .focusElsewhere:  try c.encode("focusElsewhere", forKey: AnyKey("do"))
        case .wait(let ms):
            try c.encode("wait", forKey: AnyKey("do"))
            try c.encode(ms, forKey: AnyKey("millis"))
        case .settle(let quiet, let max):
            try c.encode("settle", forKey: AnyKey("do"))
            try c.encode(quiet, forKey: AnyKey("quietMillis"))
            try c.encode(max, forKey: AnyKey("maxMillis"))
        case .expect:
            break   // handled above
        }
    }
}
