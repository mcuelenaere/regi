import Foundation

/// The SPICE inputs channel: sends keyboard scancodes and mouse
/// position/motion/button events. Translation from the App layer's
/// normalized contract (virtual keycodes, 0..32767 coords, button masks)
/// happens in `SPICEBackend`; this type just frames the wire messages.
final class SpiceInputsChannel: SpiceChannel {

    func sendKeyDown(_ scancode: SpiceScancode) async {
        try? await send(type: SpiceMsg.InputsClient.keyDown.rawValue,
                        payload: SpiceByteWriter.keyCode(scancode, down: true))
    }

    func sendKeyUp(_ scancode: SpiceScancode) async {
        try? await send(type: SpiceMsg.InputsClient.keyUp.rawValue,
                        payload: SpiceByteWriter.keyCode(scancode, down: false))
    }

    /// Absolute pointer position (client mouse mode), in guest display pixels.
    func sendMousePosition(x: UInt32, y: UInt32, buttons: UInt16, displayID: UInt8 = 0) async {
        try? await send(type: SpiceMsg.InputsClient.mousePosition.rawValue,
                        payload: SpiceByteWriter.mousePosition(x: x, y: y, buttons: buttons, displayID: displayID))
    }

    /// Relative pointer motion (server mouse mode / pointer lock).
    func sendMouseMotion(dx: Int32, dy: Int32, buttons: UInt16) async {
        try? await send(type: SpiceMsg.InputsClient.mouseMotion.rawValue,
                        payload: SpiceByteWriter.mouseMotion(dx: dx, dy: dy, buttons: buttons))
    }

    func sendMousePress(_ button: SpiceMsg.MouseButton, buttons: UInt16) async {
        try? await send(type: SpiceMsg.InputsClient.mousePress.rawValue,
                        payload: SpiceByteWriter.mouseButton(button, buttons: buttons))
    }

    func sendMouseRelease(_ button: SpiceMsg.MouseButton, buttons: UInt16) async {
        try? await send(type: SpiceMsg.InputsClient.mouseRelease.rawValue,
                        payload: SpiceByteWriter.mouseButton(button, buttons: buttons))
    }
}
