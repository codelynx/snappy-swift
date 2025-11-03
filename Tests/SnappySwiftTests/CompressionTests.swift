import XCTest
@testable import SnappySwift

/// Tests for Snappy compression
final class CompressionTests: XCTestCase {

    // MARK: - Basic Compression Tests

    func testCompressEmpty() throws {
        let input: [UInt8] = []

        let maxCompressed = Snappy.maxCompressedLength(input.count)
        var output = [UInt8](repeating: 0, count: maxCompressed)

        let compressedSize = try input.withUnsafeBufferPointer { inBuf in
            try output.withUnsafeMutableBufferPointer { outBuf in
                try Snappy.compress(inBuf, to: outBuf)
            }
        }

        XCTAssertEqual(compressedSize, 1)  // Just varint(0)
        XCTAssertEqual(output[0], 0x00)
    }

    func testCompressSingleByte() throws {
        let input: [UInt8] = [0x41]  // 'A'

        let maxCompressed = Snappy.maxCompressedLength(input.count)
        var output = [UInt8](repeating: 0, count: maxCompressed)

        let compressedSize = try input.withUnsafeBufferPointer { inBuf in
            try output.withUnsafeMutableBufferPointer { outBuf in
                try Snappy.compress(inBuf, to: outBuf)
            }
        }

        // Expected: varint(1) + literal tag + 'A' = 3 bytes
        XCTAssertEqual(compressedSize, 3)

        // Verify we can decompress it back
        guard let uncompressedLength = Array(output[0..<compressedSize]).withUnsafeBufferPointer({
            Snappy.getUncompressedLength($0)
        }) else {
            XCTFail("Failed to get uncompressed length")
            return
        }

        XCTAssertEqual(uncompressedLength, 1)

        var decompressed = [UInt8](repeating: 0, count: 10)
        let decompressedSize = try Array(output[0..<compressedSize]).withUnsafeBufferPointer { compBuf in
            try decompressed.withUnsafeMutableBufferPointer { decompBuf in
                try Snappy.decompress(compBuf, to: decompBuf)
            }
        }

        XCTAssertEqual(decompressedSize, 1)
        XCTAssertEqual(decompressed[0], 0x41)
    }

    func testCompressShortString() throws {
        let input = "Hello"
        let inputBytes = Array(input.utf8)

        let maxCompressed = Snappy.maxCompressedLength(inputBytes.count)
        var output = [UInt8](repeating: 0, count: maxCompressed)

        let compressedSize = try inputBytes.withUnsafeBufferPointer { inBuf in
            try output.withUnsafeMutableBufferPointer { outBuf in
                try Snappy.compress(inBuf, to: outBuf)
            }
        }

        // For a short unique string, expect mostly literal encoding
        XCTAssertGreaterThan(compressedSize, 0)
        XCTAssertLessThanOrEqual(compressedSize, maxCompressed)

        // Verify valid compressed format
        let isValid = Array(output[0..<compressedSize]).withUnsafeBufferPointer {
            Snappy.isValidCompressed($0)
        }
        XCTAssertTrue(isValid, "Compressed data should be valid")
    }

    func testCompressRepeatedPattern() throws {
        // String with repeated pattern: "aaaa..." (100 'a's)
        let input = [UInt8](repeating: 0x61, count: 100)  // 'a' * 100

        let maxCompressed = Snappy.maxCompressedLength(input.count)
        var output = [UInt8](repeating: 0, count: maxCompressed)

        let compressedSize = try input.withUnsafeBufferPointer { inBuf in
            try output.withUnsafeMutableBufferPointer { outBuf in
                try Snappy.compress(inBuf, to: outBuf)
            }
        }

        // Repeated pattern should compress well
        // Expected: varint + literal('a') + multiple copy operations
        XCTAssertLessThan(compressedSize, input.count,
                         "Repeated pattern should compress to less than original size")

        print("Compressed 100 'a's from \(input.count) to \(compressedSize) bytes " +
              "(ratio: \(Double(input.count)/Double(compressedSize))x)")
    }

    func testCompressLongerText() throws {
        let input = "The quick brown fox jumps over the lazy dog. " +
                   "The quick brown fox jumps over the lazy dog."
        let inputBytes = Array(input.utf8)

        let maxCompressed = Snappy.maxCompressedLength(inputBytes.count)
        var output = [UInt8](repeating: 0, count: maxCompressed)

        let compressedSize = try inputBytes.withUnsafeBufferPointer { inBuf in
            try output.withUnsafeMutableBufferPointer { outBuf in
                try Snappy.compress(inBuf, to: outBuf)
            }
        }

        // The repeated sentence should achieve some compression
        XCTAssertLessThan(compressedSize, inputBytes.count,
                         "Repeated text should compress")

        print("Compressed repeated text from \(inputBytes.count) to \(compressedSize) bytes " +
              "(ratio: \(Double(inputBytes.count)/Double(compressedSize))x)")
    }

    // MARK: - Round-Trip Tests

    func testRoundTripEmpty() throws {
        try verifyRoundTrip([])
    }

    func testRoundTripSingleByte() throws {
        try verifyRoundTrip([0x42])
    }

    func testRoundTripShortString() throws {
        try verifyRoundTrip(Array("Hello, World!".utf8))
    }

    func testRoundTripRepeatedBytes() throws {
        try verifyRoundTrip([UInt8](repeating: 0xAB, count: 1000))
    }

    func testRoundTripRepeatedPattern() throws {
        var input: [UInt8] = []
        for _ in 0..<20 {
            input.append(contentsOf: "abcdefgh".utf8)
        }
        try verifyRoundTrip(input)
    }

    func testRoundTripAllASCII() throws {
        var input: [UInt8] = []
        for i in 32..<127 {
            input.append(UInt8(i))
        }
        try verifyRoundTrip(input)
    }

    func testRoundTripIncompressible() throws {
        // Random-looking data (won't compress well)
        var input: [UInt8] = []
        for i in 0..<256 {
            input.append(UInt8((i * 31 + 17) % 256))
        }
        try verifyRoundTrip(input)
    }

    func testRoundTripLargeData() throws {
        // Test with larger data
        var input: [UInt8] = []
        let text = "The quick brown fox jumps over the lazy dog. "
        for _ in 0..<100 {
            input.append(contentsOf: text.utf8)
        }
        try verifyRoundTrip(input)
    }

    // MARK: - Data Extension Tests

    func testDataCompressionEmpty() throws {
        let input = Data()
        let compressed = try input.snappyCompressed()
        let decompressed = try compressed.snappyDecompressed()

        XCTAssertEqual(decompressed, input)
    }

    func testDataCompressionSimple() throws {
        let input = "Hello, World!".data(using: .utf8)!
        let compressed = try input.snappyCompressed()
        let decompressed = try compressed.snappyDecompressed()

        XCTAssertEqual(decompressed, input)
        XCTAssertTrue(compressed.isValidSnappyCompressed())
    }

    func testDataCompressionRepeated() throws {
        var text = ""
        for _ in 0..<50 {
            text += "Snappy compression! "
        }
        let input = text.data(using: .utf8)!

        let compressed = try input.snappyCompressed()
        let decompressed = try compressed.snappyDecompressed()

        XCTAssertEqual(decompressed, input)
        XCTAssertLessThan(compressed.count, input.count,
                         "Repeated text should compress")

        print("Data extension: compressed \(input.count) to \(compressed.count) bytes " +
              "(ratio: \(Double(input.count)/Double(compressed.count))x)")
    }

    // MARK: - Error Cases

    func testCompressInsufficientBuffer() {
        let input = "Hello, World!"
        let inputBytes = Array(input.utf8)

        var output = [UInt8](repeating: 0, count: 5)  // Too small!

        XCTAssertThrowsError(try inputBytes.withUnsafeBufferPointer { inBuf in
            try output.withUnsafeMutableBufferPointer { outBuf in
                try Snappy.compress(inBuf, to: outBuf)
            }
        }) { error in
            XCTAssertEqual(error as? Snappy.SnappyError, .insufficientBuffer)
        }
    }

    // MARK: - Helper Methods

    /// Verify that data compresses and decompresses correctly
    private func verifyRoundTrip(_ input: [UInt8], file: StaticString = #file, line: UInt = #line) throws {
        // Compress
        let maxCompressed = Snappy.maxCompressedLength(input.count)
        var compressed = [UInt8](repeating: 0, count: maxCompressed)

        let compressedSize = try input.withUnsafeBufferPointer { inBuf in
            try compressed.withUnsafeMutableBufferPointer { outBuf in
                try Snappy.compress(inBuf, to: outBuf)
            }
        }

        XCTAssertGreaterThan(compressedSize, 0, "Compressed size should be > 0", file: file, line: line)
        XCTAssertLessThanOrEqual(compressedSize, maxCompressed,
                                "Compressed size should not exceed max", file: file, line: line)

        // Validate compressed data
        let isValid = Array(compressed[0..<compressedSize]).withUnsafeBufferPointer {
            Snappy.isValidCompressed($0)
        }
        XCTAssertTrue(isValid, "Compressed data should be valid", file: file, line: line)

        // Get uncompressed length
        guard let uncompressedLength = Array(compressed[0..<compressedSize]).withUnsafeBufferPointer({
            Snappy.getUncompressedLength($0)
        }) else {
            XCTFail("Failed to get uncompressed length", file: file, line: line)
            return
        }

        XCTAssertEqual(uncompressedLength, input.count,
                      "Uncompressed length should match input", file: file, line: line)

        // Decompress
        var decompressed = [UInt8](repeating: 0, count: uncompressedLength + 10)
        let decompressedSize = try Array(compressed[0..<compressedSize]).withUnsafeBufferPointer { compBuf in
            try decompressed.withUnsafeMutableBufferPointer { decompBuf in
                try Snappy.decompress(compBuf, to: decompBuf)
            }
        }

        XCTAssertEqual(decompressedSize, input.count,
                      "Decompressed size should match input", file: file, line: line)
        XCTAssertEqual(Array(decompressed[0..<decompressedSize]), input,
                      "Decompressed data should match input", file: file, line: line)
    }
}
