import Foundation

/// The starter catalogue. Each scenario targets a specific failure this stack
/// is known to be capable of, rather than exercising features for their own
/// sake.
public enum Catalogue {
    public static let all: [Scenario] = [
        singleKey, typingOrder, shiftedCharacter, modifiersBothSides,
        autorepeat, heldOverKeepAlive,
        commandTabRegression, focusLossReleasesModifiers,
        pointerAccuracy, pointerSingleClick, pointerDoubleClick, pointerDrag,
        pointerRightClick, pointerSideButtons,
        wheelVertical, wheelHorizontal, wheelStaysDiscrete,
        pinchProducesNothing, burstOrdering,
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

    /// The OS marks repeats, and the client may coalesce them, so the count is
    /// a range rather than a number. What must hold exactly is that there is
    /// one release and nothing is left held.
    public static let autorepeat = Scenario(
        id: "key.autorepeat", title: "a held key repeats without stranding",
        tags: [.keyboard],
        steps: [
            .focusRegi,
            .autorepeat(kvk: 0x25, count: 5, intervalMillis: 40),   // 'l'
            settle,
            .expect(.keyCount(kvk: 0x25, down: true, min: 1, max: 6)),
            .expect(.keyCount(kvk: 0x25, down: false, min: 1, max: 1)),
            .expect(.noUnmatchedReleases),
            .expect(.nothingHeld),
        ])

    /// A key held far longer than the gadget's auto-release window.
    ///
    /// The JetKVM gadget releases held keys after ~100ms of HID silence, and
    /// Regi covers that with a 50ms keep-alive. If the heartbeat ever stops,
    /// this is where it shows: a release arrives that nobody sent.
    public static let heldOverKeepAlive = Scenario(
        id: "key.heldOverKeepAlive", title: "a key held 1.2s is not auto-released",
        tags: [.keyboard, .slow],
        steps: [
            .focusRegi,
            .key(kvk: 0x00, action: .down),
            .wait(millis: 1200),
            // Asserted before the release is sent: any release seen here came
            // from the device, not from us.
            .expect(.keyCount(kvk: 0x00, down: false, min: 0, max: 0)),
            .key(kvk: 0x00, action: .up),
            settle,
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

    public static let pointerSingleClick = Scenario(
        id: "ptr.singleClick", title: "one click arrives as exactly one click",
        tags: [.pointer],
        steps: [
            .focusRegi,
            .moveTo(x: 800, y: 500),
            .wait(millis: 150),
            .click(button: .left, x: 800, y: 500, count: 1),
            settle,
            .expect(.clickCount(button: .left, min: 1, max: 1)),
            .expect(.nothingHeld),
        ])

    /// A drag is the case where a stuck button would actually show: the button
    /// must stay down across the motion and come back up at the end.
    public static let pointerDrag = Scenario(
        id: "ptr.drag", title: "a drag holds the button across the motion and releases",
        tags: [.pointer],
        steps: [
            .focusRegi,
            .drag(fromX: 500, fromY: 300, toX: 1100, toY: 700, steps: 10),
            settle,
            .expect(.clickCount(button: .left, min: 1, max: 1)),
            .expect(.cursorEndsNear(x: 1100, y: 700, tolerance: 3)),
            .expect(.noUnmatchedReleases),
            .expect(.nothingHeld),
        ])

    public static let pointerRightClick = Scenario(
        id: "ptr.rightClick", title: "right click arrives as right, not left",
        tags: [.pointer],
        steps: [
            .focusRegi,
            .moveTo(x: 900, y: 600),
            .wait(millis: 150),
            .click(button: .right, x: 900, y: 600, count: 1),
            settle,
            .expect(.clickCount(button: .right, min: 1, max: 1)),
            .expect(.clickCount(button: .left, min: 0, max: 0)),
            .expect(.nothingHeld),
        ])

    /// Back and forward ride `otherMouse*` with a button number, which is bits
    /// 3 and 4 of the mask Regi forwards.
    public static let pointerSideButtons = Scenario(
        id: "ptr.sideButtons", title: "back and forward reach the target",
        tags: [.pointer],
        steps: [
            .focusRegi,
            .moveTo(x: 960, y: 540),
            .wait(millis: 150),
            .sideButton(number: 3, x: 960, y: 540, down: true),
            .sideButton(number: 3, x: 960, y: 540, down: false),
            .sideButton(number: 4, x: 960, y: 540, down: true),
            .sideButton(number: 4, x: 960, y: 540, down: false),
            settle,
            .expect(.noUnmatchedReleases),
            .expect(.nothingHeld),
        ])

    // MARK: - Wheel

    public static let wheelVertical = Scenario(
        id: "ptr.wheel.vertical", title: "vertical wheel arrives with the right sign",
        tags: [.pointer],
        steps: [
            .focusRegi,
            .moveTo(x: 960, y: 540),
            .wait(millis: 150),
            .scroll(axis: .vertical, lines: -3),
            settle,
            // A range, not a number: the client scales and re-splits detents.
            .expect(.wheelTotal(axis: .vertical, min: -6, max: -1)),
        ])

    public static let wheelHorizontal = Scenario(
        id: "ptr.wheel.horizontal", title: "horizontal wheel arrives on the horizontal axis",
        tags: [.pointer],
        steps: [
            .focusRegi,
            .moveTo(x: 960, y: 540),
            .wait(millis: 150),
            .scroll(axis: .horizontal, lines: 3),
            settle,
            .expect(.wheelTotal(axis: .horizontal, min: 1, max: 6)),
            .expect(.wheelTotal(axis: .vertical, min: 0, max: 0)),
        ])

    /// A mouse detent must not arrive as trackpad-style continuous scroll —
    /// the target treats the two very differently.
    public static let wheelStaysDiscrete = Scenario(
        id: "ptr.wheel.discrete", title: "a wheel detent stays discrete, not continuous",
        tags: [.pointer],
        steps: [
            .focusRegi,
            .moveTo(x: 960, y: 540),
            .wait(millis: 150),
            .scroll(axis: .vertical, lines: 1),
            settle,
            .expect(.wheelTotal(axis: .vertical, min: 1, max: 3)),
        ])

    /// Targets the unordered `Task` dispatch in the backends: each event is its
    /// own unstructured Task hopping to an actor, so a fast burst is where
    /// reordering would appear.
    public static let burstOrdering = Scenario(
        id: "key.burstOrdering", title: "a fast burst keeps its order",
        tags: [.keyboard, .slow],
        steps: [
            .focusRegi,
            .type("aeaeaeaeaeaeaeae"),
            settle,
            .expect(.keySequence(Array(repeating: [KeyMatcher.down(0x00), .up(0x00),
                                                   .down(0x0E), .up(0x0E)],
                                       count: 8).flatMap { $0 })),
            .expect(.nothingHeld),
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
            .expect(.clickCount(button: .left, min: 2, max: 2)),
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
