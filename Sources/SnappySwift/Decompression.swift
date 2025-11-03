/// Snappy decompression implementation
///
/// This file implements the core decompression algorithm based on Google's C++ implementation.

import Foundation

// MARK: - Decompression

extension Snappy {

    /// Get the uncompressed length from compressed data.
    ///
    /// This reads only the varint header and is very fast (O(1)).
    ///
    /// - Parameter compressed: Buffer containing compressed data
    /// - Returns: The uncompressed length in bytes, or nil if data is corrupted
    static func getUncompressedLengthImpl(_ compressed: UnsafeBufferPointer<UInt8>) -> Int? {
        guard !compressed.isEmpty else { return nil }

        let result = Varint.decode32(from: compressed, at: 0, limit: compressed.count)
        guard let (length, _) = result else { return nil }

        return Int(length)
    }

    /// Decompress data that was compressed with Snappy.
    ///
    /// - Parameters:
    ///   - input: Buffer containing compressed data
    ///   - output: Buffer to write decompressed data to
    /// - Returns: Number of bytes written to output buffer
    /// - Throws: `SnappyError` if decompression fails or data is corrupted
    static func decompressImpl(
        _ input: UnsafeBufferPointer<UInt8>,
        to output: UnsafeMutableBufferPointer<UInt8>
    ) throws -> Int {
        // Read uncompressed length from varint
        guard let (uncompressedLength, varintBytes) = Varint.decode32(
            from: input,
            at: 0,
            limit: input.count
        ) else {
            throw SnappyError.corruptedData
        }

        let expectedLength = Int(uncompressedLength)

        // Verify output buffer is large enough
        guard output.count >= expectedLength else {
            throw SnappyError.insufficientBuffer
        }

        // Decompress
        var ip = varintBytes  // Input position (past varint)
        var op = 0            // Output position

        while ip < input.count {
            // Read tag byte
            let tag = input[ip]
            ip += 1

            let tagType = TagType.from(tag)

            switch tagType {
            case .literal:
                // Decode literal length
                let length: Int
                if let shortLength = Tag.decodeLiteralLength(tag) {
                    // Length fits in tag byte
                    length = shortLength
                } else {
                    // Need to read extra bytes
                    let extraBytes = Tag.literalExtraBytes(tag)
                    guard ip + extraBytes <= input.count else {
                        throw SnappyError.corruptedData
                    }

                    // Read little-endian length
                    var lengthValue: UInt32 = 0
                    for i in 0..<extraBytes {
                        lengthValue |= UInt32(input[ip + i]) << (i * 8)
                    }
                    ip += extraBytes

                    // Length is encoded as (len - 1)
                    length = Int(lengthValue) + 1
                }

                // Validate literal doesn't exceed buffer
                guard ip + length <= input.count else {
                    throw SnappyError.corruptedData
                }
                guard op + length <= output.count else {
                    throw SnappyError.corruptedData
                }

                // Copy literal bytes
                output.baseAddress!.advanced(by: op).initialize(
                    from: input.baseAddress!.advanced(by: ip),
                    count: length
                )

                ip += length
                op += length

            case .copy1Byte:
                // 1-byte offset copy
                let length = Tag.decodeCopyLength(tag, tagType: .copy1Byte)

                guard ip < input.count else {
                    throw SnappyError.corruptedData
                }

                let offsetLow = Int(input[ip])
                let offsetHigh = Int((tag >> 5) & 0b111) << 8
                let offset = offsetHigh | offsetLow
                ip += 1

                // Validate offset
                guard offset > 0 && offset <= op else {
                    throw SnappyError.corruptedData
                }
                guard op + length <= output.count else {
                    throw SnappyError.corruptedData
                }

                // Perform copy (may overlap)
                try incrementalCopy(
                    from: output.baseAddress!.advanced(by: op - offset),
                    to: output.baseAddress!.advanced(by: op),
                    length: length
                )

                op += length

            case .copy2Byte:
                // 2-byte offset copy
                let length = Tag.decodeCopyLength(tag, tagType: .copy2Byte)

                guard ip + 2 <= input.count else {
                    throw SnappyError.corruptedData
                }

                // Read little-endian 16-bit offset
                let offset = Int(input[ip]) | (Int(input[ip + 1]) << 8)
                ip += 2

                // Validate offset
                guard offset > 0 && offset <= op else {
                    throw SnappyError.corruptedData
                }
                guard op + length <= output.count else {
                    throw SnappyError.corruptedData
                }

                // Perform copy (may overlap)
                try incrementalCopy(
                    from: output.baseAddress!.advanced(by: op - offset),
                    to: output.baseAddress!.advanced(by: op),
                    length: length
                )

                op += length

            case .copy4Byte:
                // 4-byte offset copy
                let length = Tag.decodeCopyLength(tag, tagType: .copy4Byte)

                guard ip + 4 <= input.count else {
                    throw SnappyError.corruptedData
                }

                // Read little-endian 32-bit offset
                let offset = Int(input[ip])
                    | (Int(input[ip + 1]) << 8)
                    | (Int(input[ip + 2]) << 16)
                    | (Int(input[ip + 3]) << 24)
                ip += 4

                // Validate offset
                guard offset > 0 && offset <= op else {
                    throw SnappyError.corruptedData
                }
                guard op + length <= output.count else {
                    throw SnappyError.corruptedData
                }

                // Perform copy (may overlap)
                try incrementalCopy(
                    from: output.baseAddress!.advanced(by: op - offset),
                    to: output.baseAddress!.advanced(by: op),
                    length: length
                )

                op += length
            }
        }

        // Verify we wrote exactly the expected amount
        guard op == expectedLength else {
            throw SnappyError.corruptedData
        }

        return op
    }

    /// Copy data incrementally, handling overlapping regions (pattern extension).
    ///
    /// This handles the case where offset < length, which creates a repeating pattern.
    /// For example, copying 10 bytes from offset 3 creates: "abcabcabcabc"
    ///
    /// - Parameters:
    ///   - src: Source pointer
    ///   - dst: Destination pointer
    ///   - length: Number of bytes to copy
    /// - Throws: `SnappyError.corruptedData` if offset is zero
    @inline(__always)
    private static func incrementalCopy(
        from src: UnsafePointer<UInt8>,
        to dst: UnsafeMutablePointer<UInt8>,
        length: Int
    ) throws {
        // Calculate offset between pointers (dst - src)
        let srcAddr = Int(bitPattern: src)
        let dstAddr = Int(bitPattern: dst)
        let offset = dstAddr - srcAddr

        guard offset > 0 else {
            throw SnappyError.corruptedData
        }

        if offset >= length {
            // No overlap - can use fast copy
            dst.initialize(from: src, count: length)
        } else {
            // Overlapping copy - must copy byte by byte to extend pattern
            // Example: offset=3, length=10
            // "abc" -> "abcabcabca"
            var copied = 0
            while copied < length {
                dst[copied] = src[copied]
                copied += 1
            }
        }
    }

    /// Validate that compressed data is well-formed.
    ///
    /// This is approximately 4x faster than actual decompression.
    ///
    /// - Parameter compressed: Buffer containing compressed data
    /// - Returns: true if data appears valid, false otherwise
    static func isValidCompressedImpl(_ compressed: UnsafeBufferPointer<UInt8>) -> Bool {
        // Get uncompressed length
        guard let result = Varint.decode32(
            from: compressed,
            at: 0,
            limit: compressed.count
        ) else {
            return false
        }

        let uncompressedLength = result.value
        var ip = result.bytesRead
        var expectedOutput = Int(uncompressedLength)

        // Simulate decompression without actually copying data
        while ip < compressed.count && expectedOutput > 0 {
            let tag = compressed[ip]
            ip += 1

            let tagType = TagType.from(tag)

            switch tagType {
            case .literal:
                let length: Int
                if let shortLength = Tag.decodeLiteralLength(tag) {
                    length = shortLength
                } else {
                    let extraBytes = Tag.literalExtraBytes(tag)
                    guard ip + extraBytes <= compressed.count else { return false }

                    var lengthValue: UInt32 = 0
                    for i in 0..<extraBytes {
                        lengthValue |= UInt32(compressed[ip + i]) << (i * 8)
                    }
                    ip += extraBytes
                    length = Int(lengthValue) + 1
                }

                guard ip + length <= compressed.count else { return false }
                guard length <= expectedOutput else { return false }

                ip += length
                expectedOutput -= length

            case .copy1Byte:
                let length = Tag.decodeCopyLength(tag, tagType: .copy1Byte)
                guard ip < compressed.count else { return false }
                guard length <= expectedOutput else { return false }

                ip += 1
                expectedOutput -= length

            case .copy2Byte:
                let length = Tag.decodeCopyLength(tag, tagType: .copy2Byte)
                guard ip + 2 <= compressed.count else { return false }
                guard length <= expectedOutput else { return false }

                ip += 2
                expectedOutput -= length

            case .copy4Byte:
                let length = Tag.decodeCopyLength(tag, tagType: .copy4Byte)
                guard ip + 4 <= compressed.count else { return false }
                guard length <= expectedOutput else { return false }

                ip += 4
                expectedOutput -= length
            }
        }

        // Should have consumed all input and all expected output
        return expectedOutput == 0 && ip == compressed.count
    }
}
