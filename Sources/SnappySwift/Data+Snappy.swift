import Foundation

// MARK: - Data Extension

extension Data {
    /// Compress this data using Snappy compression.
    ///
    /// - Parameter options: Compression options
    /// - Returns: Compressed data
    /// - Throws: `Snappy.SnappyError` if compression fails
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
    /// - Returns: Decompressed data
    /// - Throws: `Snappy.SnappyError` if decompression fails or data is corrupted
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
    /// This is approximately 4x faster than actual decompression.
    ///
    /// - Returns: true if data appears to be valid Snappy-compressed data
    public func isValidSnappyCompressed() -> Bool {
        return withUnsafeBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            return Snappy.isValidCompressed(bytes)
        }
    }
}
