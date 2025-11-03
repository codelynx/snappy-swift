import XCTest
@testable import SnappySwift
import Foundation

/// Tests for C++ roundtrip - verify C++ can decompress Swift-compressed data
final class CppRoundtripTests: XCTestCase {

    // MARK: - Helper Methods

    /// Write data to temporary file
    private func writeTempFile(_ data: Data, name: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("\(name).snappy")
        try data.write(to: fileURL)
        return fileURL
    }

    /// Run C++ validator on a file
    private func validateWithCpp(_ fileURL: URL, expectedSize: Int) throws {
        let validatorPath = FileManager.default.currentDirectoryPath + "/validate_snappy"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: validatorPath)
        process.arguments = [fileURL.path, "\(expectedSize)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        print(output)

        XCTAssertEqual(process.terminationStatus, 0,
                      "C++ validator failed:\n\(output)")
    }

    // MARK: - Basic Tests

    func testCppDecompressSwiftEmpty() throws {
        let original = Data()
        let compressed = try original.snappyCompressed()

        let fileURL = try writeTempFile(compressed, name: "swift_empty")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try validateWithCpp(fileURL, expectedSize: 0)
    }

    func testCppDecompressSwiftSingleByte() throws {
        let original = Data([0x42])  // 'B'
        let compressed = try original.snappyCompressed()

        let fileURL = try writeTempFile(compressed, name: "swift_single")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try validateWithCpp(fileURL, expectedSize: 1)
    }

    func testCppDecompressSwiftHello() throws {
        let original = "Hello, World!".data(using: .utf8)!
        let compressed = try original.snappyCompressed()

        let fileURL = try writeTempFile(compressed, name: "swift_hello")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try validateWithCpp(fileURL, expectedSize: 13)
    }

    func testCppDecompressSwiftRepeated() throws {
        let original = Data(repeating: 0x61, count: 100)  // 100 'a's
        let compressed = try original.snappyCompressed()

        let fileURL = try writeTempFile(compressed, name: "swift_repeated")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try validateWithCpp(fileURL, expectedSize: 100)

        print("Swift compressed 100 'a's to \(compressed.count) bytes")
    }

    func testCppDecompressSwiftPattern() throws {
        var original = Data()
        for _ in 0..<20 {
            original.append(contentsOf: "abcdefgh".utf8)
        }

        let compressed = try original.snappyCompressed()

        let fileURL = try writeTempFile(compressed, name: "swift_pattern")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try validateWithCpp(fileURL, expectedSize: 160)

        print("Swift compressed pattern to \(compressed.count) bytes")
    }

    func testCppDecompressSwiftLargeText() throws {
        var text = ""
        for _ in 0..<50 {
            text += "The quick brown fox jumps over the lazy dog. "
        }
        let original = text.data(using: .utf8)!

        let compressed = try original.snappyCompressed()

        let fileURL = try writeTempFile(compressed, name: "swift_large_text")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try validateWithCpp(fileURL, expectedSize: original.count)

        print("Swift compressed large text (\(original.count)B) to \(compressed.count) bytes (ratio: \(Double(original.count)/Double(compressed.count))x)")
    }

    // MARK: - Large Payload Tests

    func testCppDecompressSwiftLarge10KB() throws {
        let original = Data(repeating: 0x58, count: 10000)  // 10KB of 'X'
        let compressed = try original.snappyCompressed()

        let fileURL = try writeTempFile(compressed, name: "swift_large_10kb")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try validateWithCpp(fileURL, expectedSize: 10000)

        print("Swift compressed 10KB to \(compressed.count) bytes (ratio: \(Double(10000)/Double(compressed.count))x)")
    }

    func testCppDecompressSwiftLarge100KB() throws {
        // Use repeated text pattern
        var text = ""
        let chunk = "The quick brown fox jumps over the lazy dog. "
        while text.count < 100000 {
            text += chunk
        }
        let original = text.prefix(100000).data(using: .utf8)!

        let compressed = try original.snappyCompressed()

        let fileURL = try writeTempFile(compressed, name: "swift_large_100kb")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try validateWithCpp(fileURL, expectedSize: 100000)

        print("Swift compressed 100KB to \(compressed.count) bytes (ratio: \(Double(100000)/Double(compressed.count))x)")
    }

    func testCppDecompressSwiftLarge1MB() throws {
        // Use varied content
        var data = Data()
        for i in 0..<10000 {
            let line = "Line \(i): Lorem ipsum dolor sit amet, consectetur adipiscing elit. "
            data.append(contentsOf: line.utf8)

            if i % 10 == 0 {
                // Add some repeated patterns
                let repeated = String(repeating: Character(UnicodeScalar(65 + (i % 26))!), count: 50)
                data.append(contentsOf: repeated.utf8)
            }
        }

        // Ensure exactly 1MB by padding or trimming
        let targetSize = 1048576
        if data.count < targetSize {
            // Pad with repeated content
            while data.count < targetSize {
                let remaining = targetSize - data.count
                let padding = min(remaining, 1000)
                data.append(Data(repeating: 0x20, count: padding))  // Spaces
            }
        } else {
            // Trim to exact size
            data = data.prefix(targetSize)
        }

        XCTAssertEqual(data.count, targetSize, "Test data should be exactly 1MB")

        let compressed = try data.snappyCompressed()

        let fileURL = try writeTempFile(compressed, name: "swift_large_1mb")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try validateWithCpp(fileURL, expectedSize: targetSize)

        print("Swift compressed 1MB to \(compressed.count) bytes (ratio: \(Double(targetSize)/Double(compressed.count))x)")
    }

    // MARK: - Stress Test

    func testCppDecompressSwiftMixedPatterns() throws {
        // Create data with various patterns to stress test
        var original = Data()

        // Literal section
        original.append(contentsOf: "This is unique text that won't compress well: @#$%^&*()".utf8)

        // Repeated section
        original.append(Data(repeating: 0x41, count: 1000))  // 'A' * 1000

        // Pattern section
        for _ in 0..<100 {
            original.append(contentsOf: "pattern".utf8)
        }

        // Mixed section
        for i in 0..<100 {
            original.append(contentsOf: "Line \(i)\n".utf8)
        }

        let compressed = try original.snappyCompressed()

        let fileURL = try writeTempFile(compressed, name: "swift_mixed")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try validateWithCpp(fileURL, expectedSize: original.count)

        print("Swift compressed mixed patterns (\(original.count)B) to \(compressed.count) bytes (ratio: \(Double(original.count)/Double(compressed.count))x)")
    }
}
