import XCTest
import KVMWebRTC
@testable import JetKVMKit

final class ReliableHIDQueueTests: XCTestCase {
    actor Recorder {
        private(set) var messages: [HIDRPCMessage] = []

        func append(_ message: HIDRPCMessage) {
            messages.append(message)
        }

        func snapshot() -> [HIDRPCMessage] {
            messages
        }
    }

    @MainActor
    func testControlTabTransitionsRemainInFIFOOrder() async {
        let recorder = Recorder()
        let queue = ReliableHIDQueue { message in
            // Yield deliberately.  The old one-Task-per-transition path
            // had no ordering contract across these suspension points.
            await Task.yield()
            await recorder.append(message)
        }

        let expected: [HIDRPCMessage] = [
            .keypressReport(key: 0xE0, pressed: true),  // Control down
            .keypressReport(key: 0x2B, pressed: true),  // Tab down
            .keypressReport(key: 0x2B, pressed: false), // Tab up
            .keypressReport(key: 0xE0, pressed: false), // Control up
        ]
        for message in expected {
            queue.enqueue(message)
        }

        await queue.finishAndWait()
        let recorded = await recorder.snapshot()
        XCTAssertEqual(recorded, expected)
    }

    @MainActor
    func testSyntheticTapBatchCannotInterleaveWithModifierRelease() async {
        let recorder = Recorder()
        let queue = ReliableHIDQueue { message in
            await Task.yield()
            await recorder.append(message)
        }

        let controlDown = HIDRPCMessage.keypressReport(key: 0xE0, pressed: true)
        let tabDown = HIDRPCMessage.keypressReport(key: 0x2B, pressed: true)
        let tabUp = HIDRPCMessage.keypressReport(key: 0x2B, pressed: false)
        let controlUp = HIDRPCMessage.keypressReport(key: 0xE0, pressed: false)

        queue.enqueue(controlDown)
        queue.enqueueBatch([tabDown, tabUp])
        queue.enqueue(controlUp)

        await queue.finishAndWait()
        let recorded = await recorder.snapshot()
        XCTAssertEqual(
            recorded,
            [controlDown, tabDown, tabUp, controlUp]
        )
    }
}
