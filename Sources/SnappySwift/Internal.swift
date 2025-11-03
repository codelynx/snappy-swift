/// Internal types and constants for Snappy implementation
///
/// This file contains the low-level format details and is not part of the public API.

// MARK: - Constants

enum SnappyConstants {
    /// Maximum block size: 64KB
    static let blockSize: Int = 65536

    /// Block size as power of 2
    static let blockLog: Int = 16

    /// Minimum hash table size
    static let minHashTableSize: Int = 256

    /// Maximum hash table size
    static let maxHashTableSize: Int = 32768

    /// Hash table bits range
    static let minHashTableBits: Int = 8
    static let maxHashTableBits: Int = 15

    /// Maximum varint encoding length for 32-bit value
    static let maxVarintLength: Int = 5

    /// Slop bytes for safe overwrite during copy operations
    static let slopBytes: Int = 64
}

// MARK: - Tag Types

/// Snappy tag types from the lower 2 bits of the tag byte
enum TagType: UInt8 {
    case literal = 0b00           // Literal bytes
    case copy1Byte = 0b01         // Copy with 1-byte offset (11 bits)
    case copy2Byte = 0b10         // Copy with 2-byte offset (16 bits)
    case copy4Byte = 0b11         // Copy with 4-byte offset (32 bits)

    /// Extract tag type from a tag byte
    @inline(__always)
    static func from(_ tag: UInt8) -> TagType {
        return TagType(rawValue: tag & 0b11)!
    }
}

// MARK: - Tag Encoding/Decoding

enum Tag {
    /// Encode a literal tag
    ///
    /// - Parameter length: Length of the literal (must be > 0 and <= 2^32)
    /// - Returns: Tag byte and number of extra length bytes needed
    @inline(__always)
    static func encodeLiteral(length: Int) -> (tag: UInt8, extraBytes: Int) {
        precondition(length > 0, "Literal length must be > 0")
        precondition(length <= Int(UInt32.max) + 1, "Literal length must be <= 2^32")

        let n = length - 1

        if n < 60 {
            // Length fits in tag byte
            return (UInt8(n << 2), 0)
        } else {
            // Need extra bytes for length
            // Tag byte is 60,61,62,63 based on bytes needed (1-4)
            // Use platform-independent calculation: floor(log2(n)) / 8 + 1
            let log2Floor = n.bitWidth - n.leadingZeroBitCount - 1
            let bytesNeeded = (log2Floor / 8) + 1
            assert(bytesNeeded >= 1 && bytesNeeded <= 4, "Invalid byte count")
            let tagValue = 59 + bytesNeeded
            return (UInt8(tagValue << 2), bytesNeeded)
        }
    }

    /// Decode literal length from tag
    ///
    /// - Parameter tag: The tag byte
    /// - Returns: Length if fits in tag, or nil if extra bytes needed
    @inline(__always)
    static func decodeLiteralLength(_ tag: UInt8) -> Int? {
        let n = Int(tag >> 2)
        if n < 60 {
            return n + 1
        }
        return nil  // Need extra bytes
    }

    /// Number of extra bytes needed for long literal
    ///
    /// - Parameter tag: The tag byte
    /// - Returns: Number of extra bytes (0 if short literal, 1-4 if long)
    @inline(__always)
    static func literalExtraBytes(_ tag: UInt8) -> Int {
        let n = Int(tag >> 2)
        if n < 60 {
            return 0
        }
        return n - 59  // 60->1, 61->2, 62->3, 63->4
    }

    /// Encode a copy operation with 1-byte offset
    ///
    /// - Parameters:
    ///   - offset: Copy offset (0-2047)
    ///   - length: Copy length (4-11)
    /// - Returns: Tag byte and offset byte
    @inline(__always)
    static func encodeCopy1Byte(offset: Int, length: Int) -> (tag: UInt8, offsetByte: UInt8) {
        precondition(offset >= 0 && offset < 2048, "Offset must be 0-2047")
        precondition(length >= 4 && length <= 11, "Length must be 4-11")

        let tag = UInt8(((length - 4) << 2) | 0b01 | ((offset >> 8) << 5))
        let offsetByte = UInt8(offset & 0xFF)
        return (tag, offsetByte)
    }

    /// Encode a copy operation with 2-byte offset
    ///
    /// - Parameters:
    ///   - offset: Copy offset (0-65535)
    ///   - length: Copy length (1-64)
    /// - Returns: Tag byte
    @inline(__always)
    static func encodeCopy2Byte(offset: Int, length: Int) -> UInt8 {
        precondition(offset >= 0 && offset < 65536, "Offset must be 0-65535")
        precondition(length >= 1 && length <= 64, "Length must be 1-64")

        return UInt8(((length - 1) << 2) | 0b10)
    }

    /// Encode a copy operation with 4-byte offset
    ///
    /// - Parameters:
    ///   - offset: Copy offset
    ///   - length: Copy length (1-64)
    /// - Returns: Tag byte
    @inline(__always)
    static func encodeCopy4Byte(offset: Int, length: Int) -> UInt8 {
        precondition(length >= 1 && length <= 64, "Length must be 1-64")
        return UInt8(((length - 1) << 2) | 0b11)
    }

    /// Decode copy length from tag
    ///
    /// - Parameters:
    ///   - tag: The tag byte
    ///   - tagType: The tag type
    /// - Returns: The copy length
    @inline(__always)
    static func decodeCopyLength(_ tag: UInt8, tagType: TagType) -> Int {
        switch tagType {
        case .copy1Byte:
            return Int((tag >> 2) & 0b111) + 4
        case .copy2Byte, .copy4Byte:
            return Int(tag >> 2) + 1
        case .literal:
            fatalError("Not a copy tag")
        }
    }
}

// MARK: - Varint Encoding/Decoding

enum Varint {
    /// Encode a 32-bit value as varint
    ///
    /// - Parameters:
    ///   - value: Value to encode
    ///   - buffer: Output buffer
    ///   - offset: Offset in buffer to start writing
    /// - Returns: Number of bytes written (1-5)
    @inline(__always)
    static func encode32(_ value: UInt32, to buffer: UnsafeMutableBufferPointer<UInt8>, at offset: Int) -> Int {
        var v = value
        var bytesWritten = 0

        while v >= 128 {
            buffer[offset + bytesWritten] = UInt8(truncatingIfNeeded: (v & 0x7F) | 0x80)
            v >>= 7
            bytesWritten += 1
        }

        buffer[offset + bytesWritten] = UInt8(truncatingIfNeeded: v)
        bytesWritten += 1

        return bytesWritten
    }

    /// Decode a varint
    ///
    /// - Parameters:
    ///   - buffer: Input buffer
    ///   - offset: Offset to start reading
    ///   - limit: Maximum offset to read
    /// - Returns: Decoded value and number of bytes consumed, or nil if invalid
    @inline(__always)
    static func decode32(from buffer: UnsafeBufferPointer<UInt8>, at offset: Int, limit: Int) -> (value: UInt32, bytesRead: Int)? {
        guard offset < limit else { return nil }

        var result: UInt32 = 0
        var shift: UInt32 = 0
        var bytesRead = 0

        for i in 0..<5 {  // Max 5 bytes for 32-bit
            guard offset + i < limit else { return nil }

            let byte = buffer[offset + i]
            bytesRead += 1

            result |= UInt32(byte & 0x7F) << shift

            // Check if this is the last byte
            if (byte & 0x80) == 0 {
                return (result, bytesRead)
            }

            shift += 7

            // Validate we don't overflow 32 bits
            guard shift < 32 else { return nil }
        }

        // If we get here, varint is too long
        return nil
    }
}
