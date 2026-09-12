import Foundation

/// The starter catalogue. Each scenario targets a specific failure this stack
/// is known to be capable of, rather than exercising features for their own
/// sake.
public enum Catalogue {
    public static let all: [Scenario] = [
        singleKey, typingOrder, shiftedCharacter, modifiersBothSides,
        commandTabRegression, focusLossReleasesModifiers,
        pointerAccuracy, pointerDoubleClick, pinchProducesNothing,
    ]

    public static func scenario(id: String) -> Scenario? { all.first { $0.id == id } }

    static let settle = Step.settle(quietMillis: 300, maxMillis: 2500)

    // MARK: - Keyboard

    public static let singleKey = Scenario(
        id: "key.single", title: "a single key arrives once, and is released",
        tags: [.keyboard],
        steps: [
            .focusRegi,
            .key(kvk: 0x00, action: .tap(holdMillis: 40)),
            settle,
            .expect(.keySequence([.down(0x00), .up(0x00)])),
            .expect(.nothingHeld),
        ])

    public static let typingOrder = Scenario(
        id: "key.typingOrder", title: "keys arrive in the order they were sent",
        tags: [.keyboard],
        steps: [
            .focusRegi,
            .type("has"),
            settle,
            .expect(.keySequence([.down(0x04), .up(0x04),   // h
                                  .down(0x00), .up(0x00),   // a
                                  .down(0x01), .up(0x01)])), // s
            .expect(.nothingHeld),
        ])

    /// Proves modifier state actually reached the target, not merely that a
    /// keycode did: with shift genuinely held the target produces "A".
    ///
    /// Measured on the rig: flags set on the key event alone produced "a",
    /// because ModifierTracker only learns modifier state from flagsChanged.
    public static let shiftedCharacter = Scenario(
        id: "key.shiftedCharacter", title: "shift+a produces an uppercase A on the target",
        tags: [.keyboard, .modifiers],
        steps: [
            .focusRegi,
            .modifier(kvk: 0x38, down: true),
            .key(kvk: 0x00, action: .tap(holdMillis: 40)),
            .modifier(kvk: 0x38, down: false),
            settle,
            .expect(.keySubsequence([.down(0x00, "A"), .up(0x00, "A")])),
            .expect(.modifierEndsUp(kvk: 0x38)),
            .expect(.nothingHeld),
        ])

    /// Left and right are distinct keycodes and must not collapse. Only the
    /// device-side flag bits carry the distinction.
    public static let modifiersBothSides = Scenario(
        id: "key.modifiers.bothSides", title: "left and right modifiers stay distinct",
        tags: [.keyboard, .modifiers],
        steps: [
            .focusRegi,
            .modifier(kvk: 0x38, down: true),
            .modifier(kvk: 0x3C, down: true),
            .modifier(kvk: 0x38, down: false),
            .modifier(kvk: 0x3C, down: false),
            settle,
            .expect(.keySubsequence([.down(0x38), .down(0x3C), .up(0x38), .up(0x3C)])),
            .expect(.nothingHeld),
        ])

    // MARK: - The bugs this harness has already found

    /// Regression for the reported ⌘Tab bug: ⌘ goes down in Regi, focus leaves,
    /// and the release is delivered to the app that took focus instead. The
    /// host was left with ⌘ stuck, and every subsequent ⌘ was inverted because
    /// ModifierTracker inferred state by toggling.
    public static let commandTabRegression = Scenario(
        id: "lifecycle.commandTabLeavesNothingStuck",
        title: "⌘ held while focus leaves does not strand on the target",
        tags: [.modifiers, .lifecycle],
        steps: [
            .focusRegi,
            .modifier(kvk: 0x37, down: true),
            .wait(millis: 200),
            .focusElsewhere,              // the ⌘-up never reaches Regi
            settle,
            .expect(.modifierEndsUp(kvk: 0x37)),
            .expect(.nothingHeld),
        ])

    /// The same gap for an ordinary modifier, with keyboard capture off — which
    /// is the default, and the configuration in which nothing used to release.
    public static let focusLossReleasesModifiers = Scenario(
        id: "focus.lossReleasesModifiers",
        title: "modifiers release when Regi loses focus, capture off",
        tags: [.modifiers, .lifecycle],
        steps: [
            .focusRegi,
            .modifier(kvk: 0x38, down: true),
            .wait(millis: 200),
            .focusElsewhere,
            settle,
            .expect(.modifierEndsUp(kvk: 0x38)),
            .expect(.nothingHeld),
        ])

    // MARK: - Pointer

    public static let pointerAccuracy = Scenario(
        id: "ptr.accuracy", title: "the cursor lands on the pixel it was sent to",
        tags: [.pointer],
        steps: [
            .focusRegi,
            .moveTo(x: 960, y: 540),
            settle,
            // Tolerance follows from the geometry: one screen point covers
            // more than one framebuffer pixel whenever the window is smaller
            // than the source.
            .expect(.cursorEndsNear(x: 960, y: 540, tolerance: 2)),
        ])

    public static let pointerDoubleClick = Scenario(
        id: "ptr.doubleClick", title: "a double click arrives as exactly two clicks",
        tags: [.pointer],
        steps: [
            .focusRegi,
            .moveTo(x: 700, y: 400),
            .wait(millis: 200),
            .click(button: .left, x: 700, y: 400, count: 2),
            settle,
            .expect(.cursorEndsNear(x: 700, y: 400, tolerance: 2)),
            .expect(.nothingHeld),
        ])

    /// Regi emits no gestures, so a pinch must produce nothing at all. This is
    /// the assertion that caught generic trackpad events being mislabelled as
    /// magnify.
    public static let pinchProducesNothing = Scenario(
        id: "gesture.pinchProducesNothing", title: "a pinch on the driver reaches the target as nothing",
        tags: [.pointer],
        steps: [
            .focusRegi,
            .moveTo(x: 960, y: 540),
            settle,
            .expect(.absent(.gesture)),
        ])
}
