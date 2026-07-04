import Foundation

/// Decoder for the Zlib encoding (6): a rect is a u32 length followed by that
/// many bytes of zlib-compressed raw pixels, inflated through one persistent
/// stream per connection. With our negotiated 32-bit little-endian BGRA pixel
/// format the inflated bytes are already framebuffer-order BGRA, so it's a
/// straight blit. Less efficient than Tight — a fallback for servers that don't
/// offer Tight.
final class ZlibDecoder {
    private let stream = ZlibInflateStream()

    func reset() { stream.reset() }

    func decodeRect(
        _ rect: RFBProtocol.RectHeader,
        channel: any VNCByteChannel,
        framebuffer fb: VNCFramebuffer
    ) async throws {
        var header = VNCByteReader(try await channel.readExactly(4))
        let length = Int(try header.readU32())
        guard length >= 0, length <= 64 * 1024 * 1024 else {
            throw VNCConnectionError.protocolError("Zlib: implausible length \(length)")
        }
        let expected = rect.width * rect.height * VNCFramebuffer.bytesPerPixel
        guard expected > 0 else { return }
        let compressed = length > 0 ? try await channel.readExactly(length) : Data()
        let pixels = try stream.inflate(compressed, expectedCount: expected)
        try pixels.withUnsafeBytes {
            try fb.blitBGRA(x: rect.x, y: rect.y, w: rect.width, h: rect.height, src: $0)
        }
    }
}
