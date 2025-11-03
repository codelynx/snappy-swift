import XCTest
@testable import SnappySwift

/// Tests for Snappy decompression
final class DecompressionTests: XCTestCase {

    // MARK: - Helper to create test data

    /// Manually create valid Snappy compressed data for testing
    private func makeCompressed(uncompressedLength: UInt32, operations: [(tag: UInt8, extra: [UInt8])]) -> [UInt8] {
        var result: [UInt8] = []

        // Encode varint length
        var buffer = [UInt8](repeating: 0, count: 10)
        buffer.withUnsafeMutableBufferPointer { buf in
            _ = Varint.encode32(uncompressedLength, to: buf, at: 0)
        }

        // Copy varint bytes
        var length = uncompressedLength
        while length >= 128 {
            result.append(UInt8(truncatingIfNeeded: (length & 0x7F) | 0x80))
            length >>= 7
        }
        result.append(UInt8(truncatingIfNeeded: length))

        // Add operations
        for op in operations {
            result.append(op.tag)
            result.append(contentsOf: op.extra)
        }

        return result
    }

    // MARK: - Basic Tests

    func testGetUncompressedLength() {
        // Test simple varints
        let tests: [(bytes: [UInt8], expected: Int?)] = [
            // Valid cases
            ([0x00], 0),          // Empty
            ([0x01], 1),          // Single byte
            ([0x7F], 127),        // Max single-byte varint
            ([0x80, 0x01], 128),  // Two-byte varint
            ([0x80, 0x02], 256),  // Another two-byte
            ([0xFE, 0xFF, 0x7F], 2097150),  // Three-byte

            // Invalid cases
            ([], nil),            // Empty buffer
        ]

        for test in tests {
            test.bytes.withUnsafeBufferPointer { buf in
                let result = Snappy.getUncompressedLength(buf)
                XCTAssertEqual(result, test.expected,
                             "Failed for \(test.bytes): got \(String(describing: result)), expected \(String(describing: test.expected))")
            }
        }
    }

    func testDecompressEmpty() throws {
        // Compressed empty string: just varint(0)
        let compressed: [UInt8] = [0x00]

        var output = [UInt8](repeating: 0, count: 10)

        let decompressedSize = try compressed.withUnsafeBufferPointer { input in
            try output.withUnsafeMutableBufferPointer { output in
                try Snappy.decompress(input, to: output)
            }
        }

        XCTAssertEqual(decompressedSize, 0)
    }

    func testDecompressSimpleLiteral() throws {
        // Compressed "A": varint(1) + literal(1) + 'A'
        // varint(1) = 0x01
        // literal tag for 1 byte = (len-1) << 2 | 0b00 = 0 << 2 | 0 = 0x00
        // data = 'A' = 0x41
        let compressed: [UInt8] = [
            0x01,  // varint: uncompressed length = 1
            0x00,  // literal tag: length 1
            0x41   // 'A'
        ]

        var output = [UInt8](repeating: 0, count: 10)

        let decompressedSize = try compressed.withUnsafeBufferPointer { input in
            try output.withUnsafeMutableBufferPointer { output in
                try Snappy.decompress(input, to: output)
            }
        }

        XCTAssertEqual(decompressedSize, 1)
        XCTAssertEqual(output[0], 0x41)  // 'A'
    }

    func testDecompressLongerLiteral() throws {
        // Compressed "Hello": varint(5) + literal(5) + "Hello"
        let hello = "Hello"
        let helloBytes = Array(hello.utf8)

        let compressed: [UInt8] = [
            0x05,  // varint: uncompressed length = 5
            0x10,  // literal tag: (5-1) << 2 = 4 << 2 = 0x10
        ] + helloBytes

        var output = [UInt8](repeating: 0, count: 10)

        let decompressedSize = try compressed.withUnsafeBufferPointer { input in
            try output.withUnsafeMutableBufferPointer { output in
                try Snappy.decompress(input, to: output)
            }
        }

        XCTAssertEqual(decompressedSize, 5)
        XCTAssertEqual(Array(output[0..<5]), helloBytes)
    }

    func testDecompressCopy() throws {
        // Test pattern: "aaaa" = "a" + copy(offset=1, length=3)
        // Expected output: "aaaa"
        //
        // Encoding:
        // varint(4) = 0x04
        // literal(1) = tag 0x00, data 'a' (0x61)
        // copy-1(offset=1, len=3) = tag computed below

        // Copy-1 tag: ((len-4) & 0x7) << 2 | ((offset >> 8) & 0x7) << 5 | 0b01
        // For len=3, this is actually len-4=-1, which won't work with copy-1
        // Copy-1 requires length 4-11
        // So let's use copy-2 instead

        // Copy-2 tag: (len-1) << 2 | 0b10
        // For len=3: (3-1) << 2 | 0b10 = 2 << 2 | 2 = 8 | 2 = 10 = 0x0A

        let compressed: [UInt8] = [
            0x04,        // varint: uncompressed length = 4
            0x00,        // literal tag: length 1
            0x61,        // 'a'
            0x0A,        // copy-2 tag: length 3
            0x01, 0x00   // offset = 1 (little-endian 16-bit)
        ]

        var output = [UInt8](repeating: 0, count: 10)

        let decompressedSize = try compressed.withUnsafeBufferPointer { input in
            try output.withUnsafeMutableBufferPointer { output in
                try Snappy.decompress(input, to: output)
            }
        }

        XCTAssertEqual(decompressedSize, 4)
        XCTAssertEqual(output[0], 0x61)  // 'a'
        XCTAssertEqual(output[1], 0x61)  // 'a' (copied)
        XCTAssertEqual(output[2], 0x61)  // 'a' (copied)
        XCTAssertEqual(output[3], 0x61)  // 'a' (copied)
    }

    func testDecompressPatternExtension() throws {
        // Test pattern: "abcabcabc" = "abc" + copy(offset=3, length=6)
        // This tests overlapping copy (pattern extension)

        // varint(9) = 0x09
        // literal(3) = tag 0x08, data "abc"
        // copy-2(offset=3, len=6) = tag (6-1) << 2 | 0b10 = 5 << 2 | 2 = 20 | 2 = 22 = 0x16

        let compressed: [UInt8] = [
            0x09,              // varint: uncompressed length = 9
            0x08,              // literal tag: length 3
            0x61, 0x62, 0x63,  // "abc"
            0x16,              // copy-2 tag: length 6
            0x03, 0x00         // offset = 3 (little-endian)
        ]

        var output = [UInt8](repeating: 0, count: 15)

        let decompressedSize = try compressed.withUnsafeBufferPointer { input in
            try output.withUnsafeMutableBufferPointer { output in
                try Snappy.decompress(input, to: output)
            }
        }

        XCTAssertEqual(decompressedSize, 9)
        let expected = Array("abcabcabc".utf8)
        XCTAssertEqual(Array(output[0..<9]), expected)
    }

    // MARK: - Error Cases

    func testDecompressInsufficientBuffer() {
        let compressed: [UInt8] = [
            0x0A,  // varint: claims 10 bytes
            0x00, 0x41  // but only provides 1 byte literal
        ]

        var output = [UInt8](repeating: 0, count: 5)  // Too small

        XCTAssertThrowsError(try compressed.withUnsafeBufferPointer { input in
            try output.withUnsafeMutableBufferPointer { output in
                try Snappy.decompress(input, to: output)
            }
        }) { error in
            XCTAssertEqual(error as? Snappy.SnappyError, .insufficientBuffer)
        }
    }

    func testDecompressCorruptedData() {
        let compressed: [UInt8] = [
            0x05,  // varint: claims 5 bytes
            0x10,  // literal tag: 5 bytes
            0x41   // but only provides 1 byte!
        ]

        var output = [UInt8](repeating: 0, count: 10)

        XCTAssertThrowsError(try compressed.withUnsafeBufferPointer { input in
            try output.withUnsafeMutableBufferPointer { output in
                try Snappy.decompress(input, to: output)
            }
        }) { error in
            XCTAssertEqual(error as? Snappy.SnappyError, .corruptedData)
        }
    }

    // MARK: - Validation Tests

    func testIsValidCompressed() {
        // Valid empty
        let validEmpty: [UInt8] = [0x00]
        XCTAssertTrue(validEmpty.withUnsafeBufferPointer { Snappy.isValidCompressed($0) })

        // Valid literal
        let validLiteral: [UInt8] = [0x01, 0x00, 0x41]
        XCTAssertTrue(validLiteral.withUnsafeBufferPointer { Snappy.isValidCompressed($0) })

        // Invalid: missing data
        let invalid: [UInt8] = [0x05, 0x10, 0x41]
        XCTAssertFalse(invalid.withUnsafeBufferPointer { Snappy.isValidCompressed($0) })

        // Invalid: empty buffer
        let invalidEmpty: [UInt8] = []
        XCTAssertFalse(invalidEmpty.withUnsafeBufferPointer { Snappy.isValidCompressed($0) })

        // Invalid: trailing garbage after valid compressed data
        let trailingGarbage: [UInt8] = [0x00, 0xFF]  // varint(0) + garbage byte
        XCTAssertFalse(trailingGarbage.withUnsafeBufferPointer { Snappy.isValidCompressed($0) },
                       "Should reject trailing garbage bytes")

        // Invalid: trailing garbage after valid literal
        let trailingGarbage2: [UInt8] = [0x01, 0x00, 0x41, 0xDE, 0xAD]
        XCTAssertFalse(trailingGarbage2.withUnsafeBufferPointer { Snappy.isValidCompressed($0) },
                       "Should reject trailing garbage after valid data")
    }

    // MARK: - Data Extension Tests

    func testDataDecompression() throws {
        // Test the Data extension
        let compressed = Data([0x05, 0x10, 0x48, 0x65, 0x6C, 0x6C, 0x6F])  // "Hello"
        let decompressed = try compressed.snappyDecompressed()

        XCTAssertEqual(String(data: decompressed, encoding: .utf8), "Hello")
    }

    func testDataValidation() {
        let valid = Data([0x01, 0x00, 0x41])
        XCTAssertTrue(valid.isValidSnappyCompressed())

        let invalid = Data([0x05, 0x10, 0x41])
        XCTAssertFalse(invalid.isValidSnappyCompressed())
    }
}
