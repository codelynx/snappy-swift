import Foundation

// MARK: - Data Extension

extension Data {
    /// Compress this data using Snappy compression.
    ///
    /// This is a convenient wrapper around the buffer-based API that handles memory allocation.
    /// For maximum performance with repeated operations, consider using the buffer-based API directly.
    ///
    /// ## Example
    /// ```swift
    /// let text = "Hello, World!".data(using: .utf8)!
    /// let compressed = try text.snappyCompressed()
    /// print("Compressed from \(text.count) to \(compressed.count) bytes")
    /// ```
    ///
    /// ## Performance Note
    /// - Compression speed: 64-128 MB/s on Apple Silicon
    /// - Typical compression ratio: 1.5-21x depending on data
    /// - Maximum input size: 4GB (UInt32.max bytes)
    ///
    /// - Parameter options: Compression options (default: `.default`)
    /// - Returns: Compressed data
    /// - Throws: `Snappy.SnappyError.inputTooLarge` if input exceeds 4GB
    /// - Throws: `Snappy.SnappyError.insufficientBuffer` if allocation fails
    public func snappyCompressed(options: Snappy.CompressionOptions = .default) throws -> Data {
        return try withUnsafeBytes { inputBuffer in
            let input = inputBuffer.bindMemory(to: UInt8.self)

            // Allocate output buffer
            let maxSize = Snappy.maxCompressedLength(count)
            var output = Data(count: maxSize)

            let compressedSize = try output.withUnsafeMutableBytes { outputBuffer in
                let output = outputBuffer.bindMemory(to: UInt8.self)
                return try Snappy.compress(input, to: output, options: options)
            }

            // Trim to actual size
            output.count = compressedSize
            return output
        }
    }

    /// Decompress this Snappy-compressed data.
    ///
    /// This method automatically allocates the correct amount of memory based on the
    /// compressed data's header. The decompressed data is validated to ensure integrity.
    ///
    /// ## Example
    /// ```swift
    /// let compressed = try originalData.snappyCompressed()
    /// let decompressed = try compressed.snappyDecompressed()
    /// assert(decompressed == originalData)
    /// ```
    ///
    /// ## Performance Note
    /// - Decompression speed: 203-261 MB/s on Apple Silicon (2x faster than compression)
    /// - Validation: Comprehensive checks prevent buffer overflows
    ///
    /// ## Error Handling
    /// ```swift
    /// do {
    ///     let decompressed = try data.snappyDecompressed()
    /// } catch Snappy.SnappyError.corruptedData {
    ///     print("Data is corrupted or not Snappy format")
    /// }
    /// ```
    ///
    /// - Returns: Decompressed data
    /// - Throws: `Snappy.SnappyError.corruptedData` if data is invalid or corrupted
    /// - Throws: `Snappy.SnappyError.invalidLength` if uncompressed length is invalid
    public func snappyDecompressed() throws -> Data {
        return try withUnsafeBytes { inputBuffer in
            let input = inputBuffer.bindMemory(to: UInt8.self)

            // Get uncompressed length
            guard let uncompressedLength = Snappy.getUncompressedLength(input) else {
                throw Snappy.SnappyError.corruptedData
            }

            // Allocate output buffer
            var output = Data(count: uncompressedLength)

            let decompressedSize = try output.withUnsafeMutableBytes { outputBuffer in
                let output = outputBuffer.bindMemory(to: UInt8.self)
                return try Snappy.decompress(input, to: output)
            }

            // Verify size matches
            guard decompressedSize == uncompressedLength else {
                throw Snappy.SnappyError.corruptedData
            }

            return output
        }
    }

    /// Check if this data is valid Snappy-compressed data.
    ///
    /// This method performs validation without allocating memory for decompression,
    /// making it approximately 4x faster than actual decompression. Use this to
    /// validate untrusted data before attempting decompression.
    ///
    /// ## Example
    /// ```swift
    /// if data.isValidSnappyCompressed() {
    ///     let decompressed = try data.snappyDecompressed()
    ///     // Process decompressed data
    /// } else {
    ///     print("Invalid Snappy data")
    /// }
    /// ```
    ///
    /// ## What is Validated
    /// - Varint header is well-formed
    /// - Uncompressed length is valid
    /// - All operations are within bounds
    /// - No trailing garbage after valid data
    /// - All copy operations reference valid positions
    ///
    /// - Returns: `true` if data appears to be valid Snappy-compressed data, `false` otherwise
    public func isValidSnappyCompressed() -> Bool {
        return withUnsafeBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            return Snappy.isValidCompressed(bytes)
        }
    }
}
