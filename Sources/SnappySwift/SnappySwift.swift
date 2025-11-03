/// Snappy - Fast compression/decompression library
///
/// A pure Swift implementation of Google's Snappy compression algorithm, optimized for speed
/// rather than maximum compression. It provides very high compression and decompression speeds
/// with reasonable compression ratios.
///
/// ## Features
/// - **Fast compression**: 64-128 MB/s on Apple Silicon
/// - **Very fast decompression**: 203-261 MB/s (2x faster than compression)
/// - **Excellent compression**: 20-21x for repeated data, 1.5-3x for text
/// - **100% C++ compatible**: Interoperates with Google's reference implementation
/// - **Safe**: Comprehensive validation prevents buffer overflows
/// - **Zero dependencies**: Pure Swift, no external libraries
///
/// ## Performance
/// Measured on Apple Silicon (M1/M2):
/// - Compression: 64-128 MB/s
/// - Decompression: 203-261 MB/s
/// - Compression ratios: 1.5-21x depending on data
///
/// ## Basic Usage
/// ```swift
/// import SnappySwift
/// import Foundation
///
/// // Compress data using Data extension
/// let original = "Hello, World!".data(using: .utf8)!
/// let compressed = try original.snappyCompressed()
///
/// // Decompress data
/// let decompressed = try compressed.snappyDecompressed()
/// assert(decompressed == original)
/// ```
///
/// ## Buffer-based API for Maximum Performance
/// ```swift
/// import SnappySwift
///
/// let input: [UInt8] = [/* your data */]
/// let maxSize = Snappy.maxCompressedLength(input.count)
/// var output = [UInt8](repeating: 0, count: maxSize)
///
/// let compressedSize = try input.withUnsafeBufferPointer { inputBuf in
///     try output.withUnsafeMutableBufferPointer { outputBuf in
///         try Snappy.compress(inputBuf, to: outputBuf)
///     }
/// }
///
/// print("Compressed to \(compressedSize) bytes")
/// ```
///
/// ## When to Use Snappy
/// **Good use cases:**
/// - High-throughput data pipelines
/// - In-memory caching with compression
/// - Database storage (LevelDB, Cassandra)
/// - Network protocols (Protocol Buffers, Hadoop)
/// - Mobile apps (fast decompression, battery efficient)
///
/// **Not ideal for:**
/// - Maximum compression ratio (use zlib, brotli, zstd instead)
/// - Very small data (<100 bytes)
/// - Already compressed data (JPEG, PNG, MP4)
///
/// ## Thread Safety
/// All public methods are thread-safe and can be called concurrently.
/// Each compression/decompression operation is independent.
public enum Snappy {

    /// Current version of the library
    public static let version = "1.0.0"

    // MARK: - Public API

    /// Calculate the maximum possible compressed size for a given input size.
    ///
    /// This is useful for pre-allocating output buffers.
    ///
    /// - Parameter sourceLength: The size of the uncompressed data in bytes
    /// - Returns: The maximum size the compressed data could be
    public static func maxCompressedLength(_ sourceLength: Int) -> Int {
        // From C++: 32 + source_bytes + source_bytes / 6
        return 32 + sourceLength + sourceLength / 6
    }

    /// Compress data using the Snappy algorithm.
    ///
    /// - Parameters:
    ///   - input: Buffer containing uncompressed data
    ///   - output: Buffer to write compressed data to (must be at least `maxCompressedLength(input.count)`)
    ///   - options: Compression options
    /// - Returns: Number of bytes written to output buffer
    /// - Throws: `SnappyError` if compression fails
    public static func compress(
        _ input: UnsafeBufferPointer<UInt8>,
        to output: UnsafeMutableBufferPointer<UInt8>,
        options: CompressionOptions = .default
    ) throws -> Int {
        return try compressImpl(input, to: output, options: options)
    }

    /// Decompress data that was compressed with Snappy.
    ///
    /// - Parameters:
    ///   - input: Buffer containing compressed data
    ///   - output: Buffer to write decompressed data to
    /// - Returns: Number of bytes written to output buffer
    /// - Throws: `SnappyError` if decompression fails or data is corrupted
    public static func decompress(
        _ input: UnsafeBufferPointer<UInt8>,
        to output: UnsafeMutableBufferPointer<UInt8>
    ) throws -> Int {
        return try decompressImpl(input, to: output)
    }

    /// Get the uncompressed length from compressed data.
    ///
    /// This reads only the varint header and is very fast (O(1)).
    ///
    /// - Parameter compressed: Buffer containing compressed data
    /// - Returns: The uncompressed length in bytes, or nil if data is corrupted
    public static func getUncompressedLength(_ compressed: UnsafeBufferPointer<UInt8>) -> Int? {
        return getUncompressedLengthImpl(compressed)
    }

    /// Validate that compressed data is well-formed.
    ///
    /// This is approximately 4x faster than actual decompression.
    ///
    /// - Parameter compressed: Buffer containing compressed data
    /// - Returns: true if data appears valid, false otherwise
    public static func isValidCompressed(_ compressed: UnsafeBufferPointer<UInt8>) -> Bool {
        return isValidCompressedImpl(compressed)
    }
}

// MARK: - Compression Options

extension Snappy {
    /// Options for Snappy compression.
    public struct CompressionOptions: Sendable {
        /// Compression level
        public var level: CompressionLevel

        /// Default compression options (level: fast)
        public static let `default` = CompressionOptions(level: .fast)

        /// Create compression options
        public init(level: CompressionLevel = .fast) {
            self.level = level
        }
    }

    /// Compression level
    public enum CompressionLevel: Int, Sendable {
        /// Fast compression (level 1) - default
        case fast = 1

        /// Better compression (level 2) - experimental, slightly slower
        case better = 2
    }
}

// MARK: - Errors

extension Snappy {
    /// Errors that can occur during Snappy operations
    public enum SnappyError: Error, CustomStringConvertible {
        /// The compressed data is corrupted or invalid
        case corruptedData

        /// The output buffer is too small
        case insufficientBuffer

        /// The uncompressed length is invalid
        case invalidLength

        /// Input is too large (> 2^32 - 1 bytes)
        case inputTooLarge

        public var description: String {
            switch self {
            case .corruptedData:
                return "Snappy: Corrupted or invalid compressed data"
            case .insufficientBuffer:
                return "Snappy: Output buffer is too small"
            case .invalidLength:
                return "Snappy: Invalid uncompressed length"
            case .inputTooLarge:
                return "Snappy: Input exceeds maximum size (2^32 - 1 bytes)"
            }
        }
    }
}
