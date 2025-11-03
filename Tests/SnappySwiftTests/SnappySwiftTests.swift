import XCTest
@testable import SnappySwift

/// Basic tests for Snappy Swift implementation
final class SnappySwiftTests: XCTestCase {

    // MARK: - Basic Tests

    func testVersion() {
        XCTAssertEqual(Snappy.version, "1.0.0")
    }

    func testMaxCompressedLength() {
        // Test the formula: 32 + source_bytes + source_bytes / 6

        XCTAssertEqual(Snappy.maxCompressedLength(0), 32)
        XCTAssertEqual(Snappy.maxCompressedLength(100), 32 + 100 + 100 / 6)
        XCTAssertEqual(Snappy.maxCompressedLength(1000), 32 + 1000 + 1000 / 6)
        XCTAssertEqual(Snappy.maxCompressedLength(65536), 32 + 65536 + 65536 / 6)
    }

    // MARK: - Varint Tests

    func testVarintEncode() {
        var buffer = [UInt8](repeating: 0, count: 10)

        buffer.withUnsafeMutableBufferPointer { buf in
            // Test small values
            XCTAssertEqual(Varint.encode32(0, to: buf, at: 0), 1)
            XCTAssertEqual(buf[0], 0)

            XCTAssertEqual(Varint.encode32(64, to: buf, at: 0), 1)
            XCTAssertEqual(buf[0], 64)

            XCTAssertEqual(Varint.encode32(127, to: buf, at: 0), 1)
            XCTAssertEqual(buf[0], 127)

            // Test values requiring 2 bytes
            XCTAssertEqual(Varint.encode32(128, to: buf, at: 0), 2)
            XCTAssertEqual(buf[0], 0x80)
            XCTAssertEqual(buf[1], 0x01)

            // Test larger value
            XCTAssertEqual(Varint.encode32(2097150, to: buf, at: 0), 3)
            XCTAssertEqual(buf[0], 0xFE)
            XCTAssertEqual(buf[1], 0xFF)
            XCTAssertEqual(buf[2], 0x7F)
        }
    }

    func testVarintDecode() {
        let tests: [(bytes: [UInt8], expected: UInt32)] = [
            ([0x00], 0),
            ([0x40], 64),
            ([0x7F], 127),
            ([0x80, 0x01], 128),
            ([0xFE, 0xFF, 0x7F], 2097150),
        ]

        for test in tests {
            test.bytes.withUnsafeBufferPointer { buf in
                let result = Varint.decode32(from: buf, at: 0, limit: buf.count)
                XCTAssertNotNil(result, "Failed to decode: \(test.bytes)")
                if let result = result {
                    XCTAssertEqual(result.value, test.expected, "Decoded wrong value")
                    XCTAssertEqual(result.bytesRead, test.bytes.count, "Wrong bytes read")
                }
            }
        }
    }

    func testVarintRoundTrip() {
        let values: [UInt32] = [0, 1, 64, 127, 128, 255, 256, 16384, 2097150, UInt32.max]

        for value in values {
            var buffer = [UInt8](repeating: 0, count: 10)

            // Encode
            let bytesWritten = buffer.withUnsafeMutableBufferPointer { writeBuf in
                Varint.encode32(value, to: writeBuf, at: 0)
            }

            // Decode
            let result = buffer.withUnsafeBufferPointer { readBuf in
                Varint.decode32(from: readBuf, at: 0, limit: bytesWritten)
            }

            XCTAssertNotNil(result, "Failed round-trip for \(value)")
            if let result = result {
                XCTAssertEqual(result.value, value, "Round-trip mismatch for \(value)")
                XCTAssertEqual(result.bytesRead, bytesWritten, "Bytes read mismatch")
            }
        }
    }

    // MARK: - Tag Tests

    func testLiteralTagEncoding() {
        // Short literals (1-60 bytes)
        for length in 1...60 {
            let (tag, extraBytes) = Tag.encodeLiteral(length: length)
            XCTAssertEqual(extraBytes, 0, "Short literal \(length) should need no extra bytes")
            XCTAssertEqual(Int(tag >> 2), length - 1, "Tag should encode length-1")
            XCTAssertEqual(tag & 0b11, 0b00, "Tag type should be literal")
        }

        // Long literals - test boundary cases for each byte count
        // 1 byte: 61-256 (tag = 60)
        let (tag61, extra61) = Tag.encodeLiteral(length: 61)
        XCTAssertEqual(tag61 >> 2, 60, "Length 61 should use tag 60")
        XCTAssertEqual(extra61, 1, "Length 61 should need 1 extra byte")

        let (tag256, extra256) = Tag.encodeLiteral(length: 256)
        XCTAssertEqual(tag256 >> 2, 60, "Length 256 should use tag 60")
        XCTAssertEqual(extra256, 1, "Length 256 should need 1 extra byte")

        // 2 bytes: 257-65536 (tag = 61)
        let (tag257, extra257) = Tag.encodeLiteral(length: 257)
        XCTAssertEqual(tag257 >> 2, 61, "Length 257 should use tag 61")
        XCTAssertEqual(extra257, 2, "Length 257 should need 2 extra bytes")

        let (tag65536, extra65536) = Tag.encodeLiteral(length: 65536)
        XCTAssertEqual(tag65536 >> 2, 61, "Length 65536 should use tag 61")
        XCTAssertEqual(extra65536, 2, "Length 65536 should need 2 extra bytes")

        // 3 bytes: 65537-16777216 (tag = 62)
        let (tag65537, extra65537) = Tag.encodeLiteral(length: 65537)
        XCTAssertEqual(tag65537 >> 2, 62, "Length 65537 should use tag 62")
        XCTAssertEqual(extra65537, 3, "Length 65537 should need 3 extra bytes")

        let (tag16M, extra16M) = Tag.encodeLiteral(length: 16777216)
        XCTAssertEqual(tag16M >> 2, 62, "Length 16M should use tag 62")
        XCTAssertEqual(extra16M, 3, "Length 16M should need 3 extra bytes")

        // 4 bytes: 16777217-4294967296 (tag = 63)
        let (tag16Mp1, extra16Mp1) = Tag.encodeLiteral(length: 16777217)
        XCTAssertEqual(tag16Mp1 >> 2, 63, "Length 16M+1 should use tag 63")
        XCTAssertEqual(extra16Mp1, 4, "Length 16M+1 should need 4 extra bytes")

        // Maximum allowed length
        let maxLength = Int(UInt32.max) + 1  // 2^32
        let (tagMax, extraMax) = Tag.encodeLiteral(length: maxLength)
        XCTAssertEqual(tagMax >> 2, 63, "Max length should use tag 63")
        XCTAssertEqual(extraMax, 4, "Max length should need 4 extra bytes")
    }

    func testLiteralTagDecoding() {
        // Short literals
        for length in 1...60 {
            let tag = UInt8((length - 1) << 2)
            let decoded = Tag.decodeLiteralLength(tag)
            XCTAssertEqual(decoded, length, "Should decode to original length")
        }

        // Long literal
        let longTag = UInt8(60 << 2)
        XCTAssertNil(Tag.decodeLiteralLength(longTag), "Long literal should return nil")
        XCTAssertEqual(Tag.literalExtraBytes(longTag), 1, "Should need 1 extra byte")
    }

    func testCopy1ByteTagEncoding() {
        let (tag, offsetByte) = Tag.encodeCopy1Byte(offset: 100, length: 5)

        // Verify tag type
        XCTAssertEqual(tag & 0b11, 0b01, "Should be copy-1 type")

        // Verify length encoding
        let decodedLength = Tag.decodeCopyLength(tag, tagType: .copy1Byte)
        XCTAssertEqual(decodedLength, 5, "Should decode to original length")

        // Verify offset encoding
        let offsetHigh = Int((tag >> 5) & 0b111) << 8
        let offsetLow = Int(offsetByte)
        let reconstructedOffset = offsetHigh | offsetLow
        XCTAssertEqual(reconstructedOffset, 100, "Should reconstruct original offset")
    }

    func testCopy2ByteTagEncoding() {
        let tag = Tag.encodeCopy2Byte(offset: 1000, length: 20)

        // Verify tag type
        XCTAssertEqual(tag & 0b11, 0b10, "Should be copy-2 type")

        // Verify length encoding
        let decodedLength = Tag.decodeCopyLength(tag, tagType: .copy2Byte)
        XCTAssertEqual(decodedLength, 20, "Should decode to original length")
    }

    // MARK: - Bounds Validation Tests

    func testLiteralTagEncodingBoundsValidation() {
        // Test that zero length is rejected
        // Note: This will trigger a precondition failure in debug builds
        // In release builds, the behavior is undefined
        #if DEBUG
        // We can't easily test precondition failures in XCTest
        // This is documented behavior that length must be > 0
        #endif

        // Test that overly large lengths are rejected
        // Maximum is UInt32.max + 1 = 2^32 = 4,294,967,296
        #if DEBUG
        // Similarly, testing precondition failure for length > UInt32.max + 1
        #endif
    }

    // MARK: - Platform Independence Tests

    func testLiteralEncodingPlatformIndependent() {
        // This test ensures the literal encoding works correctly
        // regardless of platform (32-bit vs 64-bit)
        //
        // The bug would manifest as incorrect bytesNeeded calculation
        // on 32-bit platforms for the expression: (n.leadingZeroBitCount ^ 63)
        //
        // The fixed version uses: (n.bitWidth - n.leadingZeroBitCount - 1)
        // which works correctly on all platforms

        // Test critical boundary values
        let testCases: [(length: Int, expectedTag: UInt8, expectedExtra: Int)] = [
            (60, 59 << 2, 0),      // Largest short literal
            (61, 60 << 2, 1),      // Smallest 1-byte extra
            (256, 60 << 2, 1),     // Largest 1-byte extra
            (257, 61 << 2, 2),     // Smallest 2-byte extra
            (65536, 61 << 2, 2),   // Largest 2-byte extra
            (65537, 62 << 2, 3),   // Smallest 3-byte extra
            (16777216, 62 << 2, 3), // Largest 3-byte extra
            (16777217, 63 << 2, 4), // Smallest 4-byte extra
        ]

        for test in testCases {
            let (tag, extra) = Tag.encodeLiteral(length: test.length)
            XCTAssertEqual(tag, test.expectedTag,
                          "Length \(test.length): tag mismatch")
            XCTAssertEqual(extra, test.expectedExtra,
                          "Length \(test.length): extra bytes mismatch")
        }
    }

    // MARK: - Future Compression Tests

    // TODO: Add compression tests once implemented
    // func testBasicCompression() { ... }
    // func testBasicDecompression() { ... }
    // func testRoundTrip() { ... }
}
