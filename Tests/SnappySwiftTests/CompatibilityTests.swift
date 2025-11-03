import XCTest
@testable import SnappySwift
import Foundation

/// Tests for C++ compatibility - verify Swift can decompress C++ compressed data
final class CompatibilityTests: XCTestCase {

    // MARK: - Test Data

    /// Expected uncompressed data for each test file
    private let testCases: [(file: String, expected: [UInt8])] = [
        ("empty", []),
        ("single_byte", [0x41]),  // 'A'
        ("hello", Array("Hello, World!".utf8)),
        ("repeated", [UInt8](repeating: 0x61, count: 100)),  // 100 'a's
        ("pattern", {
            var bytes: [UInt8] = []
            for _ in 0..<20 {
                bytes.append(contentsOf: "abcdefgh".utf8)
            }
            return bytes
        }()),
        ("longer_text", Array((
            "The quick brown fox jumps over the lazy dog. " +
            "The quick brown fox jumps over the lazy dog. " +
            "The quick brown fox jumps over the lazy dog. " +
            "The quick brown fox jumps over the lazy dog."
        ).utf8)),
        ("ascii", {
            var bytes: [UInt8] = []
            for i in 32..<127 {
                bytes.append(UInt8(i))
            }
            return bytes
        }()),
        ("large", [UInt8](repeating: 0x78, count: 10000)),  // 10000 'x's
        ("mixed", Array("AAAAAAAbbbbbCCCCCdddEEFF1234567890".utf8)),
        ("numbers", {
            var bytes: [UInt8] = []
            for i in 0..<100 {
                bytes.append(contentsOf: "\(i) ".utf8)
            }
            return bytes
        }()),
    ]

    // MARK: - Helper Methods

    /// Load compressed test data from file
    private func loadTestData(_ filename: String) throws -> Data {
        let testBundle = Bundle.module

        guard let url = testBundle.url(forResource: filename, withExtension: "snappy", subdirectory: "TestData") else {
            XCTFail("Test file not found: \(filename).snappy in bundle: \(testBundle.bundlePath)")
            throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "File not found"])
        }

        return try Data(contentsOf: url)
    }

    // MARK: - Individual Test Cases

    func testDecompressCppEmpty() throws {
        let compressed = try loadTestData("empty")
        let decompressed = try compressed.snappyDecompressed()

        XCTAssertEqual(decompressed.count, 0)
        XCTAssertEqual(Array(decompressed), [])
    }

    func testDecompressCppSingleByte() throws {
        let compressed = try loadTestData("single_byte")
        let decompressed = try compressed.snappyDecompressed()

        XCTAssertEqual(decompressed.count, 1)
        XCTAssertEqual(decompressed[0], 0x41)  // 'A'
    }

    func testDecompressCppHello() throws {
        let compressed = try loadTestData("hello")
        let decompressed = try compressed.snappyDecompressed()

        let text = String(data: decompressed, encoding: .utf8)
        XCTAssertEqual(text, "Hello, World!")
    }

    func testDecompressCppRepeated() throws {
        let compressed = try loadTestData("repeated")
        let decompressed = try compressed.snappyDecompressed()

        XCTAssertEqual(decompressed.count, 100)
        XCTAssertTrue(decompressed.allSatisfy { $0 == 0x61 })  // All 'a's

        print("C++ repeated: compressed 100 bytes to \(compressed.count) bytes (ratio: \(Double(100)/Double(compressed.count))x)")
    }

    func testDecompressCppPattern() throws {
        let compressed = try loadTestData("pattern")
        let decompressed = try compressed.snappyDecompressed()

        XCTAssertEqual(decompressed.count, 160)

        // Verify pattern repeats 20 times
        let pattern = "abcdefgh".data(using: .utf8)!
        for i in 0..<20 {
            let slice = decompressed[i*8..<(i+1)*8]
            XCTAssertEqual(Array(slice), Array(pattern))
        }

        print("C++ pattern: compressed 160 bytes to \(compressed.count) bytes (ratio: \(Double(160)/Double(compressed.count))x)")
    }

    func testDecompressCppLongerText() throws {
        let compressed = try loadTestData("longer_text")
        let decompressed = try compressed.snappyDecompressed()

        let expected = "The quick brown fox jumps over the lazy dog. " +
                      "The quick brown fox jumps over the lazy dog. " +
                      "The quick brown fox jumps over the lazy dog. " +
                      "The quick brown fox jumps over the lazy dog."

        let text = String(data: decompressed, encoding: .utf8)
        XCTAssertEqual(text, expected)

        print("C++ longer_text: compressed \(decompressed.count) bytes to \(compressed.count) bytes (ratio: \(Double(decompressed.count)/Double(compressed.count))x)")
    }

    func testDecompressCppAscii() throws {
        let compressed = try loadTestData("ascii")
        let decompressed = try compressed.snappyDecompressed()

        XCTAssertEqual(decompressed.count, 95)

        // Verify ASCII characters 32-126
        for (i, byte) in decompressed.enumerated() {
            XCTAssertEqual(byte, UInt8(32 + i))
        }
    }

    func testDecompressCppLarge() throws {
        let compressed = try loadTestData("large")
        let decompressed = try compressed.snappyDecompressed()

        XCTAssertEqual(decompressed.count, 10000)
        XCTAssertTrue(decompressed.allSatisfy { $0 == 0x78 })  // All 'x's

        print("C++ large: compressed 10000 bytes to \(compressed.count) bytes (ratio: \(Double(10000)/Double(compressed.count))x)")
    }

    func testDecompressCppMixed() throws {
        let compressed = try loadTestData("mixed")
        let decompressed = try compressed.snappyDecompressed()

        let text = String(data: decompressed, encoding: .utf8)
        XCTAssertEqual(text, "AAAAAAAbbbbbCCCCCdddEEFF1234567890")
    }

    func testDecompressCppNumbers() throws {
        let compressed = try loadTestData("numbers")
        let decompressed = try compressed.snappyDecompressed()

        let text = String(data: decompressed, encoding: .utf8)!

        // Verify contains numbers 0-99
        for i in 0..<100 {
            XCTAssertTrue(text.contains("\(i) "), "Should contain '\(i) '")
        }
    }

    // MARK: - Large Payload Tests

    func testDecompressCppLarge100KB() throws {
        let compressed = try loadTestData("large_100kb")
        let decompressed = try compressed.snappyDecompressed()

        // Verify size
        XCTAssertEqual(decompressed.count, 100000, "Should decompress to exactly 100KB")

        // Verify it's repeated text pattern
        let text = String(data: decompressed, encoding: .utf8)!
        XCTAssertTrue(text.hasPrefix("The quick brown fox"), "Should start with expected text")

        print("C++ large_100kb: compressed 100KB to \(compressed.count) bytes (ratio: \(Double(100000)/Double(compressed.count))x)")
    }

    func testDecompressCppLarge1MB() throws {
        let compressed = try loadTestData("large_1mb")
        let decompressed = try compressed.snappyDecompressed()

        // Verify size
        XCTAssertEqual(decompressed.count, 1048576, "Should decompress to exactly 1MB")

        // Verify content structure
        let text = String(data: decompressed, encoding: .utf8)!
        XCTAssertTrue(text.contains("Line 0:"), "Should contain line markers")
        XCTAssertTrue(text.contains("Lorem ipsum"), "Should contain Lorem ipsum text")

        print("C++ large_1mb: compressed 1MB to \(compressed.count) bytes (ratio: \(Double(1048576)/Double(compressed.count))x)")
    }

    func testDecompressCppLarge10MB() throws {
        let compressed = try loadTestData("large_10mb")
        let decompressed = try compressed.snappyDecompressed()

        // Verify size
        XCTAssertEqual(decompressed.count, 10485700, "Should decompress to ~10MB")

        // Verify it's all X's (highly compressible)
        XCTAssertTrue(decompressed.allSatisfy { $0 == 0x58 }, "Should be all 'X' characters")

        print("C++ large_10mb: compressed ~10MB to \(compressed.count) bytes (ratio: \(Double(10485700)/Double(compressed.count))x)")
    }

    func testRoundTripLarge100KB() throws {
        // Test Swift compress → Swift decompress for 100KB
        let cppCompressed = try loadTestData("large_100kb")
        let decompressed1 = try cppCompressed.snappyDecompressed()

        XCTAssertEqual(decompressed1.count, 100000)

        // Compress with Swift
        let swiftCompressed = try decompressed1.snappyCompressed()

        // Decompress Swift compressed data
        let decompressed2 = try swiftCompressed.snappyDecompressed()

        XCTAssertEqual(decompressed2, decompressed1, "Round-trip should preserve data")

        print("Round-trip [large_100kb]: C++:\(cppCompressed.count)B → Swift:\(swiftCompressed.count)B (diff: \(swiftCompressed.count - cppCompressed.count)B)")
    }

    func testRoundTripLarge1MB() throws {
        // Test Swift compress → Swift decompress for 1MB
        let cppCompressed = try loadTestData("large_1mb")
        let decompressed1 = try cppCompressed.snappyDecompressed()

        XCTAssertEqual(decompressed1.count, 1048576)

        // Compress with Swift
        let swiftCompressed = try decompressed1.snappyCompressed()

        // Decompress Swift compressed data
        let decompressed2 = try swiftCompressed.snappyDecompressed()

        XCTAssertEqual(decompressed2, decompressed1, "Round-trip should preserve data")

        print("Round-trip [large_1mb]: C++:\(cppCompressed.count)B → Swift:\(swiftCompressed.count)B (diff: \(swiftCompressed.count - cppCompressed.count)B)")
    }

    func testRoundTripLarge10MB() throws {
        // Test Swift compress → Swift decompress for 10MB
        let cppCompressed = try loadTestData("large_10mb")
        let decompressed1 = try cppCompressed.snappyDecompressed()

        XCTAssertEqual(decompressed1.count, 10485700)

        // Compress with Swift
        let swiftCompressed = try decompressed1.snappyCompressed()

        // Decompress Swift compressed data
        let decompressed2 = try swiftCompressed.snappyDecompressed()

        XCTAssertEqual(decompressed2, decompressed1, "Round-trip should preserve data")

        print("Round-trip [large_10mb]: C++:\(cppCompressed.count)B → Swift:\(swiftCompressed.count)B (diff: \(swiftCompressed.count - cppCompressed.count)B)")
    }

    // MARK: - Batch Tests

    func testDecompressAllCppTestData() throws {
        // Decompress all test files and verify against expected data
        for testCase in testCases {
            let compressed = try loadTestData(testCase.file)
            let decompressed = try compressed.snappyDecompressed()

            XCTAssertEqual(Array(decompressed), testCase.expected,
                          "Failed for test case: \(testCase.file)")

            // Verify validation passes
            XCTAssertTrue(compressed.isValidSnappyCompressed(),
                         "Validation failed for: \(testCase.file)")
        }
    }

    func testGetUncompressedLengthFromCppData() throws {
        // Verify we can read uncompressed length from C++ compressed data
        for testCase in testCases {
            let compressed = try loadTestData(testCase.file)

            let length = compressed.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                bytes.bindMemory(to: UInt8.self).withMemoryRebound(to: UInt8.self) { buf in
                    Snappy.getUncompressedLength(buf)
                }
            }

            XCTAssertNotNil(length, "Failed to get length for: \(testCase.file)")
            XCTAssertEqual(length, testCase.expected.count,
                          "Wrong length for: \(testCase.file)")
        }
    }

    func testValidateAllCppTestData() throws {
        // Verify all C++ compressed data passes validation
        for testCase in testCases {
            let compressed = try loadTestData(testCase.file)

            let isValid = compressed.isValidSnappyCompressed()
            XCTAssertTrue(isValid, "Validation failed for: \(testCase.file)")
        }
    }

    // MARK: - Round-Trip with C++ Data

    func testRoundTripWithCppReference() throws {
        // For each C++ test file:
        // 1. Decompress with Swift
        // 2. Compress with Swift
        // 3. Decompress again with Swift
        // 4. Verify matches original

        for testCase in testCases {
            let cppCompressed = try loadTestData(testCase.file)

            // Step 1: Decompress C++ data
            let decompressed1 = try cppCompressed.snappyDecompressed()
            XCTAssertEqual(Array(decompressed1), testCase.expected,
                          "C++ decompression failed for: \(testCase.file)")

            // Step 2: Compress with Swift
            let swiftCompressed = try decompressed1.snappyCompressed()

            // Step 3: Decompress Swift compressed data
            let decompressed2 = try swiftCompressed.snappyDecompressed()

            // Step 4: Verify round-trip
            XCTAssertEqual(Array(decompressed2), testCase.expected,
                          "Round-trip failed for: \(testCase.file)")

            print("Round-trip [\(testCase.file)]: " +
                  "C++:\(cppCompressed.count)B → " +
                  "decomp:\(decompressed1.count)B → " +
                  "Swift:\(swiftCompressed.count)B → " +
                  "decomp:\(decompressed2.count)B ✓")
        }
    }

    // MARK: - Performance Comparison

    func testCompressionRatioComparison() throws {
        // Compare Swift vs C++ compression ratios
        print("\n=== Compression Ratio Comparison ===")
        print("File           | Original | C++ Size | Swift Size | C++ Ratio | Swift Ratio")
        print("---------------|----------|----------|------------|-----------|------------")

        for testCase in testCases {
            let cppCompressed = try loadTestData(testCase.file)
            let original = Data(testCase.expected)
            let swiftCompressed = try original.snappyCompressed()

            let originalSize = original.count
            let cppSize = cppCompressed.count
            let swiftSize = swiftCompressed.count

            let cppRatio = originalSize > 0 ? Double(originalSize) / Double(cppSize) : 0
            let swiftRatio = originalSize > 0 ? Double(originalSize) / Double(swiftSize) : 0

            let fileName = testCase.file.padding(toLength: 14, withPad: " ", startingAt: 0)
            print("\(fileName) | \(String(format: "%8d", originalSize)) | \(String(format: "%8d", cppSize)) | \(String(format: "%10d", swiftSize)) | \(String(format: "%9.2f", cppRatio))x | \(String(format: "%11.2f", swiftRatio))x")

            // Swift compression should be reasonably close to C++
            // Allow up to 25% difference for different implementations
            if originalSize > 10 {  // Only for non-trivial data
                let difference = abs(Double(swiftSize - cppSize)) / Double(cppSize)
                XCTAssertLessThan(difference, 0.25,
                                 "\(testCase.file): Swift compression differs too much from C++ (>25%)")
            }
        }

        print("================================\n")
    }
}
