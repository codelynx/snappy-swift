# Snappy C++ Implementation Analysis

**Date:** 2025-11-02
**Updated:** 2025-11-02 (Corrected literal encoding, DecompressBranchless, IncrementalCopy)
**Purpose:** Comprehensive analysis of Google's Snappy C++ implementation for porting to Swift
**Source:** https://github.com/google/snappy

> **Corrections Applied:**
> - Fixed literal encoding: extra bytes always encode `(len - 1)`, not `(len - 61)`
> - Fixed DecompressBranchless: uses single deferred copy, not operation batching array
> - Fixed IncrementalCopy: correct signature with 4 parameters, conditional stores, bounds checking

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Algorithm Overview](#algorithm-overview)
3. [Format Specification](#format-specification)
4. [Core Implementation Details](#core-implementation-details)
5. [Code Organization](#code-organization)
6. [API Surface](#api-surface)
7. [Performance Optimizations](#performance-optimizations)
8. [Testing Strategy](#testing-strategy)
9. [Swift Porting Roadmap](#swift-porting-roadmap)

---

## Executive Summary

### What is Snappy?

Snappy is a **fast compression/decompression library** developed by Google that prioritizes speed over compression ratio. It's designed for scenarios where compression/decompression speed is more important than achieving maximum compression.

### Key Characteristics

- **Speed-focused:** 250-500 MB/s decompression, 250 MB/s compression per core
- **Reasonable compression:** 1.5-1.7x for text, 2-4x for HTML
- **Simple algorithm:** LZ77-type with fixed byte-oriented encoding
- **No dependencies:** Self-contained, no external libraries required
- **Stable format:** Backward and forward compatible
- **Battle-tested:** Handles petabytes of data in Google's production

### Code Statistics

| Component | LOC | Purpose |
|-----------|-----|---------|
| snappy.cc | ~2400 | Main compression/decompression logic |
| snappy.h | ~260 | Public API |
| snappy-internal.h | ~445 | Internal utilities and SIMD |
| snappy-stubs-internal.h/cc | ~500 | Platform abstraction |
| snappy-sinksource.h/cc | ~200 | I/O abstractions |
| **Total Core** | **~3800** | Clean, manageable codebase |

### Use Cases

- Database storage (LevelDB, Cassandra, MongoDB)
- Network protocols (Protocol Buffers, Hadoop)
- In-memory compression
- Real-time data pipelines

---

## Algorithm Overview

### Compression Algorithm (LZ77-based)

Snappy uses a **dictionary-based compression** approach similar to LZ77:

1. **Scan input** looking for repeated byte sequences
2. **Build hash table** to track previously seen 4-byte patterns
3. **Emit operations:**
   - **Literals:** Unmatched bytes copied directly
   - **Copies:** Backreferences to previous data (offset + length)

#### High-Level Compression Flow

```
Input: "The quick brown fox jumps over the lazy dog"
       ↓
[Hash table lookup for patterns]
       ↓
Output: [varint: length] [tag: literal] "The quick brown fox jumps over"
        [tag: copy offset=12 len=4] " lazy dog"
```

#### Two Compression Levels

**Level 1 (Default):** Single hash table
- Uses 4-byte hash lookups
- Fast, lower CPU usage
- Good for most use cases

**Level 2 (Experimental):** Double hash table
- Uses both 4-byte and 8-byte hash lookups
- Better compression ratio (similar to zstd:-3)
- Slightly slower but still very fast

### Decompression Algorithm

Decompression is **simpler and faster** than compression:

1. **Read varint** to get uncompressed length
2. **Parse tags** sequentially:
   - **Tag bits 0-1:** Operation type (literal/copy-1/copy-2/copy-4)
   - **Tag bits 2-7:** Length encoding
3. **Execute operations:**
   - Literals: Copy bytes from input to output
   - Copies: Copy bytes from earlier in output buffer

#### Key Optimization: Branchless Decoding

Uses **lookup tables** to minimize branching:
- Pre-computed tag interpretation table
- Deferred memcpy operations
- Loop unrolling (2x)
- SIMD prefetching

---

## Format Specification

### Stream Structure

```
[Compressed Stream]
├─ Varint: Uncompressed Length (1-5 bytes)
└─ Operations*
   ├─ Literal (tag + length [+ extra] + data)
   └─ Copy (tag + length [+ extra] + offset)
```

### Tag Encoding

Tags are **1 byte** encoding operation type and length information:

```
Bits 0-1: Operation Type
  00 = Literal
  01 = Copy with 1-byte offset (offset: 0-2047)
  10 = Copy with 2-byte offset (offset: 0-65535)
  11 = Copy with 4-byte offset (offset: 0-4294967295)

Bits 2-7: Length/Data (varies by type)
```

#### Literal Encoding

```
Length 1-60:
  Tag: [(len-1) << 2 | 0b00]
  Data: [literal bytes]

Length 61-256:
  Tag: [60 << 2 | 0b00]
  Extra: [1 byte: len-1]
  Data: [literal bytes]

Length 257-65536:
  Tag: [61 << 2 | 0b00]
  Extra: [2 bytes LE: len-1]
  Data: [literal bytes]

And so on for 62 (3 bytes), 63 (4 bytes)
```

#### Copy Encoding

**Copy-1 (1-byte offset, tag 0b01):**
```
Tag: [offset[10:8] << 5 | (len-4)[2:0] << 2 | 0b01]
Offset: [offset[7:0]]

Length: 4-11 bytes
Offset: 0-2047 bytes
Total: 2 bytes
```

**Copy-2 (2-byte offset, tag 0b10):**
```
Tag: [(len-1) << 2 | 0b10]
Offset: [2 bytes, little-endian]

Length: 1-64 bytes
Offset: 0-65535 bytes
Total: 3 bytes
```

**Copy-4 (4-byte offset, tag 0b11):**
```
Tag: [(len-1) << 2 | 0b11]
Offset: [4 bytes, little-endian]

Length: 1-64 bytes
Offset: 0-4294967295 bytes
Total: 5 bytes
```

### Varint Encoding

Used for uncompressed length at stream start:

```
Algorithm:
  while (value >= 128):
    output byte: (value & 0x7F) | 0x80
    value >>= 7
  output byte: value

Examples:
  64        → 0x40
  127       → 0x7F
  128       → 0x80 0x01
  2097150   → 0xFE 0xFF 0x7F
```

Maximum: 5 bytes for 32-bit length

---

## Core Implementation Details

### Block Size and Hashing

#### Constants (snappy.h:247-254)

```cpp
kBlockSize = 65536          // 64KB max block size
kBlockLog = 16

kMinHashTableSize = 256     // 2^8 entries
kMaxHashTableSize = 32768   // 2^15 entries
kMinHashTableBits = 8
kMaxHashTableBits = 15
```

#### Hash Table Sizing

Hash table size adapts to input:

```cpp
// Compute table size
table_size = min(input_size, kMaxHashTableSize)
table_size = max(table_size, kMinHashTableSize)
table_size = next_power_of_2(table_size)

// Compute mask for modulo operation
mask = 2 * (table_size - 1)
```

**Hash Table Entry:** `uint16_t` (2 bytes)
- Stores offset within current block (0-65535)
- `0` indicates unused slot

#### Hash Functions

**Hardware CRC32 (preferred, snappy.cc:163-171):**
```cpp
#if SNAPPY_HAVE_NEON_CRC32
  hash = __crc32cw(bytes, mask);      // ARM
#elif SNAPPY_HAVE_X86_CRC32
  hash = _mm_crc32_u32(bytes, mask);  // x86
#endif
```

**Software Fallback (snappy.cc:172-174):**
```cpp
constexpr uint32_t kMagic = 0x1e35a7bd;
hash = (kMagic * bytes) >> (31 - kMaxHashTableBits);
```

CRC32 provides better distribution and is 1-cycle on modern CPUs.

### Compression Implementation

#### Main Function: CompressFragment (snappy.cc:788-956)

**Algorithm pseudocode:**
```
Input: data[0..n], hash_table
Output: compressed bytes

1. Initialize:
   ip = input pointer
   base_ip = start of current block
   next_emit = next byte to emit as literal

2. While ip < end - 15:
   a. Load 4 bytes at ip
   b. Compute hash
   c. Look up candidate = hash_table[hash]
   d. Store current ip in hash_table[hash]

   e. If candidate matches:
      - Emit literal [next_emit, ip)
      - Extend match backward and forward
      - Emit copy operation
      - Skip matched bytes
      - Update next_emit

   f. Else:
      - Advance ip (with heuristic skip)

3. Emit final literal [next_emit, end)
```

**Key optimization - Match skipping heuristic (snappy.cc:870-885):**
```cpp
// If no match found in 32 bytes, start skipping
if (ip - last_match_pos > 32) {
  skip = (ip - last_match_pos) >> 5;  // Divide by 32
  ip += skip;  // Skip ahead
}
```

This prevents wasting cycles on incompressible data.

#### Helper: FindMatchLength (snappy-internal.h:198-326)

Finds length of matching bytes between two pointers:

**Optimized for little-endian 64-bit:**
```cpp
1. Compare 8 bytes at a time using unaligned loads
2. If match: advance by 8, repeat
3. If mismatch:
   - XOR the two values
   - Find first differing bit using count-trailing-zeros
   - Return matched byte count
```

**Special x86 optimization:**
- Uses inline assembly for conditional move
- Preloads next comparison data
- Cuts data dependency chain
- Critical for compression throughput

#### Helper: EmitLiteral (snappy.cc:611-692)

Outputs literal bytes:

```cpp
void EmitLiteral(char* op, const char* literal, size_t len) {
  // Encode length in tag
  int n = len - 1;
  if (n < 60) {
    op[0] = n << 2;
    op += 1;
  } else {
    // For len >= 61, tag byte is 60,61,62,63 based on bytes needed
    // Extra bytes always encode (len - 1)
    int count = (log2(n) >> 3) + 1;  // 1-4 bytes
    op[0] = (59 + count) << 2;
    Store32LittleEndian(op + 1, n);  // Store len-1 in extra bytes
    op += 1 + count;
  }
  // ... rest of function

  // Fast path: copy 16 bytes at a time
  while (len >= 16) {
    UnalignedCopy128(literal, op);
    literal += 16;
    op += 16;
    len -= 16;
  }

  // Copy remaining bytes
  memcpy(op, literal, len);
}
```

#### Helper: EmitCopy (snappy.cc:693-787)

Outputs copy operation:

```cpp
void EmitCopy(char* op, size_t offset, size_t len) {
  // Emit 2-byte encoding if offset < 2048
  while (len >= 4 && len <= 11 && offset < 2048) {
    op[0] = ((len - 4) << 2) | 0b01 | ((offset >> 8) << 5);
    op[1] = offset & 0xFF;
    op += 2;
    len = 0;  // Done
  }

  // Emit longer copies in 64-byte chunks
  while (len >= 64) {
    op[0] = (63 << 2) | 0b10;
    *(uint16_t*)(op + 1) = offset;  // Little-endian
    op += 3;
    len -= 64;
  }

  // Emit remaining
  if (len > 0) {
    if (offset < 65536) {
      op[0] = ((len - 1) << 2) | 0b10;
      *(uint16_t*)(op + 1) = offset;
      op += 3;
    } else {
      op[0] = ((len - 1) << 2) | 0b11;
      *(uint32_t*)(op + 1) = offset;
      op += 5;
    }
  }
}
```

### Decompression Implementation

#### Main Function: DecompressAllTags (snappy.cc:1581-1808)

**Algorithm pseudocode:**
```
Input: compressed[0..n]
Output: decompressed bytes

1. Read varint uncompressed_length
2. Allocate output buffer
3. ip = input pointer, op = output pointer

4. While ip < end:
   a. Read tag byte
   b. Extract operation type (tag & 0b11)
   c. Extract length/data (tag >> 2)

   d. If literal:
      - Read length (from tag or extra bytes)
      - Copy bytes from input to output
      - Advance both pointers

   e. If copy:
      - Read offset (1, 2, or 4 bytes)
      - Read length (from tag)
      - Copy bytes from (op - offset) to op
      - Advance output pointer

5. Verify op - base == uncompressed_length
```

#### Optimization: DecompressBranchless (snappy.cc:1398-1580)

Fast inner loop using **lookup tables and deferred copy**:

```cpp
// Deferred copy state - defers ONE copy operation
const void* deferred_src;
size_t deferred_length;
uint8_t safe_source[64];
ClearDeferred(&deferred_src, &deferred_length, safe_source);

// Pre-computed table: kLengthMinusOffset[256]
// For each tag byte, stores (length - offset) to enable
// single-comparison bounds checking

while (ip < ip_limit_min_slop) {
  tag = *ip++;
  ptrdiff_t len_minus_offset = kLengthMinusOffset[tag];

  // Decode offset and length based on tag type
  size_t tag_type = tag & 0x3;
  ptrdiff_t len = len_minus_offset & 0xFF;
  ptrdiff_t extracted = ExtractOffset(next_bytes, tag_type);

  // Check if this is a valid copy (offset >= length)
  if (len_minus_offset > extracted) {
    // Pattern extension case or exceptional case
    // Execute deferred copy first
    MemCopy64(op_base + op, deferred_src, deferred_length);
    op += deferred_length;
    ClearDeferred(&deferred_src, &deferred_length, safe_source);
    // ... handle pattern extension
  } else {
    // Normal case: execute previous deferred copy, defer this one
    MemCopy64(op_base + op, deferred_src, deferred_length);
    op += deferred_length;

    // Defer the current copy
    const void* from = tag_type ? (op_base + op + len_minus_offset - len) : ip;
    DeferMemCopy(&deferred_src, &deferred_length, from, len);
  }
}

// Execute final deferred copy
if (deferred_length) {
  MemCopy64(op_base + op, deferred_src, deferred_length);
  op += deferred_length;
}
```

**Benefits:**
- Reduces memcpy overhead by deferring one copy operation
- Eliminates branch mispredictions via lookup table
- Enables better instruction pipelining
- Single-comparison bounds checking (len_minus_offset vs extracted)

#### Helper: IncrementalCopy (snappy.cc:423-538)

Handles overlapping copies (pattern extension):

**Example:**
```
Output buffer: "abc??????"
Copy: offset=3, length=10
Result: "abcabcabcabc"  (pattern "abc" repeated)
```

**Implementation:**
```cpp
// Copy [src, src+(op_limit-op)) to [op, op_limit)
// buf_limit is past the end of writable region
inline char* IncrementalCopy(const char* src, char* op,
                              char* const op_limit,
                              char* const buf_limit) {
  size_t pattern_size = op - src;  // The offset (distance back)

  // Bounds checks
  assert(src < op);
  assert(op < op_limit);
  assert(op_limit <= buf_limit);
  assert(op_limit - op <= 64);  // Max copy length

  if (pattern_size < 16) {
    // Small pattern: use SIMD to extend
    if (SNAPPY_PREDICT_TRUE(op_limit <= buf_limit - 15)) {
      // Fast path: enough slop for conditional stores
      auto [pattern, reshuffle_mask] =
          LoadPatternAndReshuffleMask(src, pattern_size);

      // Conditionally write 1-4 16-byte chunks (not always 4!)
      V128_StoreU(reinterpret_cast<V128*>(op), pattern);
      if (op + 16 < op_limit) {
        pattern = V128_Shuffle(pattern, reshuffle_mask);
        V128_StoreU(reinterpret_cast<V128*>(op + 16), pattern);
      }
      if (op + 32 < op_limit) {
        pattern = V128_Shuffle(pattern, reshuffle_mask);
        V128_StoreU(reinterpret_cast<V128*>(op + 32), pattern);
      }
      if (op + 48 < op_limit) {
        pattern = V128_Shuffle(pattern, reshuffle_mask);
        V128_StoreU(reinterpret_cast<V128*>(op + 48), pattern);
      }
      return op_limit;
    }
    // Slow path: insufficient slop, use scalar fallback
    return IncrementalCopySlow(src, op, op_limit);
  }

  // Large pattern (>= 16 bytes): use memcpy in chunks
  for (char* op_end = buf_limit - 16; op < op_end; op += 16, src += 16) {
    UnalignedCopy128(src, op);
  }
  if (op >= op_limit) return op_limit;

  // Handle remaining bytes
  return IncrementalCopySlow(src, op, op_limit);
}
```

**Key differences from simplified version:**
- Takes 4 parameters: `src, op, op_limit, buf_limit`
- Returns new `op` position
- Has extensive bounds checking for safety
- **Conditionally** writes 1-4 chunks (not always 4)
- Falls back to scalar copy when insufficient slop
- Critical for performance as overlapping copies are common

### Working Memory Management

#### WorkingMemory Class (snappy-internal.h:137-159)

Manages scratch space for compression:

```cpp
class WorkingMemory {
public:
  explicit WorkingMemory(size_t input_size) {
    // Compute required sizes
    size_t hash_table_size = ComputeTableSize(input_size);
    size_t scratch_input_size = kBlockSize;
    size_t scratch_output_size = MaxCompressedLength(kBlockSize);

    // Single allocation for all scratch space
    size_ = hash_table_size * 2 + scratch_input_size + scratch_output_size;
    mem_ = new char[size_];

    // Initialize pointers
    table_ = (uint16_t*)mem_;
    input_ = mem_ + hash_table_size * 2;
    output_ = input_ + scratch_input_size;
  }

  uint16_t* GetHashTable(size_t fragment_size, int* table_size) {
    *table_size = ComputeTableSize(fragment_size);
    std::memset(table_, 0, *table_size * 2);  // Clear hash table
    return table_;
  }

private:
  char* mem_;       // Single allocation
  uint16_t* table_; // Hash table
  char* input_;     // Input scratch buffer
  char* output_;    // Output scratch buffer
};
```

**Key benefit:** Single allocation reduces malloc overhead and improves cache locality.

---

## Code Organization

### File Structure

```
snappy-cpp/
├── snappy.h                    # Public API (260 lines)
├── snappy.cc                   # Main implementation (2400 lines)
├── snappy-internal.h           # Internal utilities (445 lines)
├── snappy-stubs-internal.h     # Platform abstraction (header)
├── snappy-stubs-internal.cc    # Platform abstraction (impl)
├── snappy-sinksource.h         # I/O interfaces
├── snappy-sinksource.cc        # I/O implementations
├── snappy-c.h                  # C language bindings
├── snappy-c.cc                 # C language bindings impl
├── snappy_unittest.cc          # Comprehensive tests
├── format_description.txt      # Format spec
├── framing_format.txt          # Framing spec (optional)
└── testdata/                   # Test data files
```

### Key Components

#### 1. Public API (snappy.h)

**Namespace:** `snappy::`

**Classes:**
- `CompressionOptions` - Compression level configuration
- `Source` - Abstract input interface
- `Sink` - Abstract output interface

**Functions:** All compression/decompression variants

#### 2. Main Implementation (snappy.cc)

**Key functions by line number:**

| Lines | Function | Purpose |
|-------|----------|---------|
| 197-219 | `MaxCompressedLength` | Calculate worst-case output size |
| 611-692 | `EmitLiteral` | Encode literal bytes |
| 693-787 | `EmitCopy` | Encode copy operations |
| 788-956 | `CompressFragment` | Single-hash compression (level 1) |
| 957-1123 | `CompressFragmentDoubleHash` | Double-hash compression (level 2) |
| 1298-1397 | `InternalUncompress` | Decompression wrapper |
| 1398-1580 | `DecompressBranchless` | Optimized inner loop |
| 1581-1808 | `DecompressAllTags` | Main decompression |
| 1815-2245 | Source/Sink implementations | I/O abstractions |
| 2245-2398 | Public API wrappers | String/array interfaces |

#### 3. Internal Utilities (snappy-internal.h)

**V128 SIMD abstraction (lines 76-133):**
```cpp
#if SNAPPY_HAVE_SSSE3
  using V128 = __m128i;
  V128 V128_Load(const V128* src);
  V128 V128_Shuffle(V128 input, V128 mask);
#elif SNAPPY_HAVE_NEON
  using V128 = uint8x16_t;
  V128 V128_Load(const V128* src);
  V128 V128_Shuffle(V128 input, V128 mask);
#endif
```

**WorkingMemory class (lines 137-159):** Scratch space management

**FindMatchLength (lines 198-355):** Core pattern matching

**Decompression table (lines 404-439):** Lookup table for tag decoding

#### 4. Platform Abstraction (snappy-stubs-internal.h)

**Unaligned access (lines 131-165):**
```cpp
inline uint32_t UNALIGNED_LOAD32(const void* p) {
  uint32_t t;
  memcpy(&t, p, sizeof t);  // Compiles to single instruction
  return t;
}
```

**Endianness (lines 176-283):**
```cpp
class LittleEndian {
public:
  static uint32_t Load32(const void* ptr) {
#if SNAPPY_IS_BIG_ENDIAN
    const uint8_t* buf = (const uint8_t*)ptr;
    return buf[0] | (buf[1]<<8) | (buf[2]<<16) | (buf[3]<<24);
#else
    uint32_t val;
    memcpy(&val, ptr, 4);
    return val;
#endif
  }
};
```

**Bit operations (lines 286-430):**
```cpp
class Bits {
public:
  static int FindLSBSetNonZero64(uint64_t n) {
    return __builtin_ctzll(n);  // Count trailing zeros
  }
};
```

**Varint encoding (lines 433-503):**
```cpp
class Varint {
public:
  static char* Encode32(char* dst, uint32_t v);
  static const char* Parse32WithLimit(...);
};
```

#### 5. I/O Abstraction (snappy-sinksource.h)

**Source interface (lines 111-143):**
```cpp
class Source {
public:
  virtual ~Source();
  virtual size_t Available() const = 0;
  virtual const char* Peek(size_t* len) = 0;
  virtual void Skip(size_t n) = 0;
};
```

**Sink interface (lines 37-108):**
```cpp
class Sink {
public:
  virtual ~Sink();
  virtual void Append(const char* bytes, size_t n) = 0;
  virtual char* GetAppendBuffer(size_t length, char* scratch);
  virtual void AppendAndTakeOwnership(char* bytes, size_t n,
                                      void (*deleter)(void*, const char*, size_t),
                                      void* deleter_arg);
};
```

**Concrete implementations:**
- `ByteArraySource` - Input from byte array
- `UncheckedByteArraySink` - Output to byte array (no bounds checking)
- Adapters for `std::string`

---

## API Surface

### Compression Options

```cpp
struct CompressionOptions {
  int level = 1;  // 1 = fast, 2 = better (experimental)

  static constexpr int MinCompressionLevel() { return 1; }
  static constexpr int MaxCompressionLevel() { return 2; }
  static constexpr int DefaultCompressionLevel() { return 1; }
};
```

### High-Level String API

**Compression:**
```cpp
// Compress std::string
size_t Compress(const char* input, size_t input_length,
                std::string* compressed,
                CompressionOptions options = {});

// Returns: compressed size
// Requires: input != compressed
```

**Decompression:**
```cpp
// Decompress to std::string
bool Uncompress(const char* compressed, size_t compressed_length,
                std::string* uncompressed);

// Returns: true if successful, false if corrupted
// Requires: compressed != uncompressed
```

### Low-Level Array API

**Compression:**
```cpp
// Compress to pre-allocated buffer
void RawCompress(const char* input, size_t input_length,
                 char* compressed, size_t* compressed_length,
                 CompressionOptions options = {});

// Requires: compressed buffer >= MaxCompressedLength(input_length)
```

**Decompression:**
```cpp
// Decompress to pre-allocated buffer
bool RawUncompress(const char* compressed, size_t compressed_length,
                   char* uncompressed);

// Requires: uncompressed buffer >= GetUncompressedLength(compressed)
// Returns: true if successful
```

### Scatter/Gather (IOVec) API

**Compression from multiple buffers:**
```cpp
// Compress from iovec array
size_t CompressFromIOVec(const struct iovec* iov, size_t iov_cnt,
                         std::string* compressed,
                         CompressionOptions options = {});

// Or with pre-allocated buffer:
void RawCompressFromIOVec(const struct iovec* iov,
                          size_t uncompressed_length,
                          char* compressed, size_t* compressed_length,
                          CompressionOptions options = {});
```

**Decompression to multiple buffers:**
```cpp
// Decompress to iovec array
bool RawUncompressToIOVec(const char* compressed, size_t compressed_length,
                          const struct iovec* iov, size_t iov_cnt);

// Requires: sum(iov[i].iov_len) >= GetUncompressedLength(compressed)
```

### Streaming API

**With Source/Sink interfaces:**
```cpp
// Compress from Source to Sink
size_t Compress(Source* reader, Sink* writer,
                CompressionOptions options = {});

// Decompress from Source to Sink
bool Uncompress(Source* compressed, Sink* uncompressed);

// Also with partial decompression:
size_t UncompressAsMuchAsPossible(Source* compressed, Sink* uncompressed);
```

### Utility Functions

**Calculate max compressed size:**
```cpp
size_t MaxCompressedLength(size_t source_bytes);
// Returns: 32 + source_bytes + source_bytes / 6
```

**Get uncompressed length from compressed data:**
```cpp
// From buffer:
bool GetUncompressedLength(const char* compressed,
                          size_t compressed_length,
                          size_t* result);

// From Source:
bool GetUncompressedLength(Source* source, uint32_t* result);

// Returns: true if valid, false if corrupted
// Note: O(1) operation, just reads varint
```

**Validate compressed data:**
```cpp
// From buffer:
bool IsValidCompressedBuffer(const char* compressed,
                             size_t compressed_length);

// From Source:
bool IsValidCompressed(Source* compressed);

// Returns: true if data can be decompressed
// Note: ~4x faster than actual decompression
```

### Constants

```cpp
namespace snappy {
  static constexpr int kBlockLog = 16;
  static constexpr size_t kBlockSize = 1 << kBlockLog;  // 65536

  static constexpr int kMinHashTableBits = 8;
  static constexpr size_t kMinHashTableSize = 1 << kMinHashTableBits;  // 256

  static constexpr int kMaxHashTableBits = 15;
  static constexpr size_t kMaxHashTableSize = 1 << kMaxHashTableBits;  // 32768
}
```

---

## Performance Optimizations

### SIMD Optimizations

#### SSSE3 (x86/x64)

**Operations (snappy-internal.h:76-110):**
```cpp
using V128 = __m128i;

// Load 16 bytes (aligned)
V128 V128_Load(const V128* src) {
  return _mm_load_si128(src);
}

// Load 16 bytes (unaligned)
V128 V128_LoadU(const V128* src) {
  return _mm_loadu_si128(src);
}

// Store 16 bytes (unaligned)
void V128_StoreU(V128* dst, V128 val) {
  _mm_storeu_si128(dst, val);
}

// Shuffle bytes (PSHUFB instruction)
V128 V128_Shuffle(V128 input, V128 shuffle_mask) {
  return _mm_shuffle_epi8(input, shuffle_mask);
}

// Duplicate byte
V128 V128_DupChar(char c) {
  return _mm_set1_epi8(c);
}
```

**Use cases:**
- Pattern extension in IncrementalCopy
- Bulk copying in decompression
- Literal emission

#### NEON (ARM)

**Operations (snappy-internal.h:111-132):**
```cpp
using V128 = uint8x16_t;

V128 V128_Load(const V128* src) {
  return vld1q_u8(reinterpret_cast<const uint8_t*>(src));
}

V128 V128_LoadU(const V128* src) {
  return vld1q_u8(reinterpret_cast<const uint8_t*>(src));
}

void V128_StoreU(V128* dst, V128 val) {
  vst1q_u8(reinterpret_cast<uint8_t*>(dst), val);
}

V128 V128_Shuffle(V128 input, V128 shuffle_mask) {
  return vqtbl1q_u8(input, shuffle_mask);
}

V128 V128_DupChar(char c) {
  return vdupq_n_u8(c);
}
```

Same functionality, different intrinsics.

#### Pattern Generation (snappy.cc:303-321)

Pre-computed shuffle masks for pattern replication:

```cpp
// For pattern size N (1-16), creates mask to replicate pattern
// Example: pattern_size=3 ("abc")
// Mask: [0,1,2,0,1,2,0,1,2,0,1,2,0,1,2,0]
// Result: "abcabcabcabcabca" (16 bytes)

alignas(16) constexpr std::array<std::array<char, 16>, 16>
  pattern_generation_masks = ...;

// After first 16 bytes, need to "rotate" pattern
alignas(16) constexpr std::array<std::array<char, 16>, 16>
  pattern_reshuffle_masks = ...;
```

This enables **very fast pattern extension** for short overlapping copies.

### BMI2 Instructions (x86)

**Bit manipulation (snappy.cc:1191-1197):**
```cpp
// Extract low N bytes from value
inline uint32_t ExtractLowBytes(uint32_t v, int n) {
#if SNAPPY_HAVE_BMI2
  return _bzhi_u32(v, 8 * n);  // Zero high bits (1 cycle)
#else
  uint32_t mask = 0xFFFFFFFF >> (32 - 8 * n);
  return v & mask;
#endif
}
```

**BMI2 availability:** Intel Haswell+ (2013), AMD Excavator+ (2015)

### Hardware CRC32

**Hash function (snappy.cc:163-177):**
```cpp
#if SNAPPY_HAVE_NEON_CRC32
  const uint32_t hash = __crc32cw(bytes, mask);
#elif SNAPPY_HAVE_X86_CRC32
  const uint32_t hash = _mm_crc32_u32(bytes, mask);
#else
  constexpr uint32_t kMagic = 0x1e35a7bd;
  const uint32_t hash = (kMagic * bytes) >> (31 - kMaxHashTableBits);
#endif
```

**Benefits:**
- Better hash distribution
- 1-3 cycle latency
- Reduces hash collisions → better compression

**Availability:** Intel SSE4.2+ (2008), ARM CRC32+ (ARMv8)

### Unaligned Memory Access

**Load/Store macros (snappy-stubs-internal.h:131-165):**
```cpp
inline uint64_t UNALIGNED_LOAD64(const void* p) {
  uint64_t t;
  memcpy(&t, p, sizeof t);  // Optimizes to single mov on x86/ARM64
  return t;
}

inline void UNALIGNED_STORE64(void* p, uint64_t v) {
  memcpy(p, &v, sizeof v);  // Optimizes to single mov
}
```

**Why memcpy?**
- Avoids undefined behavior in C++
- Modern compilers recognize pattern and optimize
- Works on all architectures (compiler handles alignment)

### Branch Prediction Hints

**Macros (snappy-stubs-internal.h:82-89):**
```cpp
#define SNAPPY_PREDICT_TRUE(x) __builtin_expect(!!(x), 1)
#define SNAPPY_PREDICT_FALSE(x) __builtin_expect(x, 0)
```

**Usage:**
```cpp
// In compression hot path (snappy.cc:870)
if (SNAPPY_PREDICT_TRUE(ip < ip_limit)) {
  // Common case: more input available
}

// In decompression (snappy.cc:1449)
if (SNAPPY_PREDICT_FALSE(tag >= kLongLiteralTag)) {
  // Rare case: long literal
}
```

Helps CPU's branch predictor make better decisions.

### Prefetching

**In decompression (snappy.cc:1429):**
```cpp
SNAPPY_PREFETCH(op + pattern_size);
```

**Macro (snappy-stubs-internal.h:95-99):**
```cpp
#define SNAPPY_PREFETCH(ptr) __builtin_prefetch(ptr, 0, 3)
```

Hints CPU to load data into cache before it's needed.

### Lookup Tables

**Decompression table (snappy-internal.h:404-439):**
```cpp
// Pre-computed for all 256 possible tag bytes
static constexpr uint16_t char_table[256] = {
  // Bits 0-7:   Literal/copy length
  // Bits 8-10:  Copy offset/256
  // Bits 11-13: Extra bytes after tag
  0x0001, 0x0804, 0x1001, 0x2001, ...
};
```

**Length-minus-offset table (snappy.cc:142-147):**
```cpp
// For copy operations, stores (length - offset)
// Used to check if offset >= length in single comparison
alignas(64) const std::array<int16_t, 256> kLengthMinusOffset = ...;
```

These eliminate branches in hot paths.

### Loop Unrolling

**Decompression (snappy.cc:1450-1500):**
```cpp
// Manual 2x unrolling
for (; ip < ip_limit_min_slop; ) {
  // Process tag 1
  tag = *ip++;
  // ... decode and execute

  // Process tag 2
  tag = *ip++;
  // ... decode and execute
}
```

Reduces loop overhead and enables better instruction scheduling.

### Fast Path Specialization

**Different code paths based on data characteristics:**

```cpp
// Compression
if (input_size <= kBlockSize) {
  // Fast path: single block, no need for blocking
  CompressFragment(input, size, output, table, table_size);
} else {
  // Slow path: multiple blocks
  while (remaining > 0) {
    size_t fragment = min(remaining, kBlockSize);
    CompressFragment(...);
    remaining -= fragment;
  }
}

// Decompression
if (sufficient_buffer_space) {
  // Fast path: branchless decoder
  DecompressBranchless(...);
} else {
  // Slow path: careful bounds checking
  DecompressWithChecks(...);
}
```

### Data Dependency Optimization

**Critical in FindMatchLength (snappy-internal.h:243-275):**

```cpp
// BAD: Load depends on matched_bytes calculation
matched_bytes = count_trailing_zeros(xor_value) / 8;
next_data = LOAD(s2 + matched_bytes);  // STALL!

// GOOD: Preload data speculatively
data_low = LOAD(s2);
data_high = LOAD(s2 + 4);
matched_bytes = count_trailing_zeros(xor_value) / 8;
next_data = (matched_bytes < 4) ? data_low : data_high;
```

The second approach allows loads to happen in parallel with comparison.

---

## Testing Strategy

### Test Files

**snappy_unittest.cc** - Comprehensive unit tests:
- Basic compression/decompression
- Round-trip testing
- Edge cases (empty, single byte, max size)
- Corrupted data handling
- IOVec interface testing
- Performance regression tests

**snappy_test_data.h/cc** - Test data definitions:
- Alice in Wonderland (text)
- HTML documents
- URLs list
- Protocol buffers
- Compressed formats (JPEG, PNG)
- Random data

**testdata/** directory:
- Real-world test files
- Pre-compressed reference data
- Corrupted data for validation testing

### Test Patterns

#### Basic Round-Trip (snappy_unittest.cc:107-121)

```cpp
int VerifyString(const std::string& input) {
  std::string compressed;
  size_t written = snappy::Compress(input.data(), input.size(), &compressed);
  CHECK_EQ(written, compressed.size());
  CHECK_LE(compressed.size(), snappy::MaxCompressedLength(input.size()));
  CHECK(snappy::IsValidCompressedBuffer(compressed.data(), compressed.size()));

  std::string uncompressed;
  CHECK(snappy::Uncompress(compressed.data(), compressed.size(), &uncompressed));
  CHECK_EQ(uncompressed, input);
  return uncompressed.size();
}
```

#### IOVec Testing (snappy_unittest.cc:141-200)

Tests scatter/gather interfaces:
- Random split of data into 1-10 buffers
- Some buffers have 0 length
- Validates same output as single-buffer

#### Corrupted Data Testing

Tests various corruption scenarios:
- Invalid varint length
- Offset pointing before buffer start
- Length exceeding declared size
- Invalid tag bytes
- Truncated data

#### Memory Safety (snappy_unittest.cc:62-105)

Uses `DataEndingAtUnreadablePage`:
- Allocates buffer at page boundary
- Protects next page with mprotect()
- Tests don't read beyond input
- Catches off-by-one errors

### Test Categories

**Correctness:**
- Empty input
- Single byte input
- Maximum block size (64KB)
- Data with no matches (incompressible)
- Highly compressible data (repeated patterns)
- All literal encoding sizes
- All copy encoding sizes
- Pattern extension cases

**Compatibility:**
- Compress with C++, decompress with C++ ✓
- Compress level 1, decompress ✓
- Compress level 2, decompress ✓
- Old compressed data, new decompressor ✓

**Performance:**
- Benchmark on various data types
- Compare against LZO, LZF, zlib
- Measure compression ratio
- Measure speed (MB/s)

**Robustness:**
- Malformed compressed data
- Out-of-bounds offsets
- Integer overflow attempts
- Buffer overruns

---

## Swift Porting Roadmap

### Phase 1: Core Algorithm (Weeks 1-2)

**Goal:** Port basic compression/decompression without optimizations

**Tasks:**
1. Create Swift package structure
2. Port format types (tags, varint)
3. Port basic compression (single hash)
4. Port basic decompression
5. Create initial test suite
6. Validate against C++ implementation

**Deliverables:**
- `SnappySwift` module
- Basic `compress()` and `decompress()` functions
- Test suite with 100% round-trip success

### Phase 2: Platform Abstraction (Week 3)

**Goal:** Swift equivalents for C++ platform code

**Tasks:**
1. Unaligned memory access using `withUnsafeBytes`
2. Endianness handling with `littleEndian` conversions
3. Bit manipulation (count trailing zeros)
4. Varint encoding/decoding
5. Buffer management

**Deliverables:**
- `SnappyInternal` module with platform utilities
- Unit tests for each utility
- Performance benchmarks

### Phase 3: API Design (Week 3)

**Goal:** Swift-native API that feels natural

**API Design:**
```swift
// Foundation extension
extension Data {
  func snappyCompressed(options: SnappyCompressionOptions = .default) throws -> Data
  func snappyDecompressed() throws -> Data
  func isValidSnappyCompressed() -> Bool
}

// Low-level API
struct Snappy {
  static func compress(_ input: UnsafeBufferPointer<UInt8>,
                      to output: UnsafeMutableBufferPointer<UInt8>,
                      options: SnappyCompressionOptions = .default) throws -> Int

  static func decompress(_ input: UnsafeBufferPointer<UInt8>,
                        to output: UnsafeMutableBufferPointer<UInt8>) throws -> Int

  static func maxCompressedLength(_ sourceLength: Int) -> Int
  static func getUncompressedLength(_ compressed: UnsafeBufferPointer<UInt8>) -> Int?
}

// Streaming API
protocol SnappySource {
  func peek() throws -> UnsafeBufferPointer<UInt8>?
  func skip(_ n: Int) throws
}

protocol SnappySink {
  func append(_ data: UnsafeBufferPointer<UInt8>) throws
}

struct SnappyCompressionOptions {
  var level: CompressionLevel = .fast

  enum CompressionLevel {
    case fast      // Level 1
    case better    // Level 2
  }
}

// Errors
enum SnappyError: Error {
  case corruptedData
  case insufficientBuffer
  case invalidLength
}
```

**Tasks:**
1. Design protocol-based Source/Sink
2. Implement Data extensions
3. Create buffer-based API
4. Add convenience methods
5. Document API thoroughly

### Phase 4: Optimizations (Weeks 4-5)

**Goal:** Match C++ performance

**4.1 SIMD Support**
```swift
import simd

// Use SIMD16<UInt8> for V128
func duplicateByte(_ byte: UInt8) -> SIMD16<UInt8> {
  return SIMD16<UInt8>(repeating: byte)
}

// Pattern extension using SIMD
func extendPattern(_ pattern: UnsafePointer<UInt8>,
                   size: Int,
                   to dst: UnsafeMutablePointer<UInt8>) {
  let simdPattern = loadPatternSIMD(pattern, size: size)
  // ... store 4x
}
```

**4.2 Accelerate Framework**
```swift
import Accelerate

// CRC32 using Accelerate (if available)
#if canImport(Accelerate)
  func hashCRC32(_ bytes: UInt32) -> UInt32 {
    // Use vCRC32 if available
  }
#endif
```

**4.3 Performance Critical Paths**
```swift
@inline(__always)
func emitLiteral(_ literal: UnsafeBufferPointer<UInt8>,
                 to output: UnsafeMutablePointer<UInt8>) {
  // ... hot path code
}

@_specialize(where T == UInt8)
func copy<T>(_ src: UnsafePointer<T>,
            to dst: UnsafeMutablePointer<T>,
            count: Int) {
  // ... specialized for UInt8
}
```

**Tasks:**
1. Implement SIMD pattern extension
2. Add hash function optimizations
3. Optimize hot paths with inline
4. Profile and benchmark
5. Compare with C++ performance

### Phase 5: Testing & Validation (Week 6)

**Goal:** Comprehensive test coverage and compatibility

**5.1 Unit Tests**
```swift
import XCTest
@testable import SnappySwift

class SnappyTests: XCTestCase {
  func testRoundTripEmpty() { }
  func testRoundTripSingleByte() { }
  func testRoundTripLargeData() { }
  func testMaxBlockSize() { }
  func testCorruptedData() { }
  func testAllLiteralSizes() { }
  func testAllCopySizes() { }
  func testPatternExtension() { }
}
```

**5.2 Compatibility Tests**
```swift
class SnappyCompatibilityTests: XCTestCase {
  // Compress with Swift, decompress with C++
  func testCompressedBySwiftDecompressedByCpp() { }

  // Compress with C++, decompress with Swift
  func testCompressedByCppDecompressedBySwift() { }

  // Test against reference test data
  func testReferenceTestData() { }
}
```

**5.3 Fuzz Testing**
```swift
import OSLog

func fuzzTest(iterations: Int) {
  for _ in 0..<iterations {
    let input = generateRandomData()

    do {
      let compressed = try input.snappyCompressed()
      let decompressed = try compressed.snappyDecompressed()
      assert(decompressed == input)
    } catch {
      // Log failure case
    }
  }
}
```

**Tasks:**
1. Port C++ unit tests to Swift
2. Add Swift-specific tests
3. Create compatibility test suite
4. Implement fuzz testing
5. Test on multiple platforms (macOS, iOS, Linux)

### Phase 6: Performance Benchmarking (Week 7)

**Goal:** Validate performance characteristics

**Benchmarks:**
```swift
import Foundation

struct SnappyBenchmark {
  func benchmarkCompression(data: Data, iterations: Int = 1000) {
    let start = Date()
    for _ in 0..<iterations {
      _ = try! data.snappyCompressed()
    }
    let elapsed = Date().timeIntervalSince(start)
    let throughput = Double(data.count * iterations) / elapsed / 1_000_000
    print("Compression: \(throughput) MB/s")
  }

  func benchmarkDecompression(compressed: Data, iterations: Int = 1000) {
    let start = Date()
    for _ in 0..<iterations {
      _ = try! compressed.snappyDecompressed()
    }
    let elapsed = Date().timeIntervalSince(start)
    // ... calculate throughput
  }
}

// Test data types
enum TestDataType {
  case text        // Alice in Wonderland
  case html        // HTML documents
  case urls        // URL list
  case protobuf    // Protocol buffers
  case random      // Random bytes
}
```

**Metrics:**
- Compression speed (MB/s)
- Decompression speed (MB/s)
- Compression ratio
- Memory usage
- Compare against C++ implementation

**Tasks:**
1. Create benchmark harness
2. Test with various data types
3. Compare Swift vs C++ performance
4. Profile to find bottlenecks
5. Optimize critical paths
6. Document performance characteristics

### Phase 7: Documentation & Examples (Week 8)

**Goal:** Comprehensive documentation for users

**Tasks:**
1. API documentation with DocC
2. Usage examples
3. Performance guide
4. Migration guide from C++
5. Architecture documentation
6. Tutorial

**Example Documentation:**
```swift
/// Compresses data using the Snappy algorithm.
///
/// Snappy is a fast compression algorithm optimized for speed rather than
/// compression ratio. It's ideal for scenarios where compression/decompression
/// speed is critical.
///
/// - Parameter options: Compression options (level, etc.)
/// - Returns: Compressed data
/// - Throws: `SnappyError.insufficientBuffer` if output buffer is too small
///
/// Example:
/// ```swift
/// let originalData = "Hello, World!".data(using: .utf8)!
/// let compressed = try originalData.snappyCompressed()
/// let decompressed = try compressed.snappyDecompressed()
/// assert(decompressed == originalData)
/// ```
public func snappyCompressed(options: SnappyCompressionOptions = .default) throws -> Data {
  // ...
}
```

### Phase 8: Platform-Specific Optimizations (Week 9)

**Goal:** Optimize for each platform

**8.1 Apple Silicon (ARM64)**
- Use NEON intrinsics via Swift SIMD
- Optimize for unified memory
- Leverage hardware CRC32

**8.2 Intel/AMD (x86-64)**
- Use SSE/AVX via Swift SIMD
- Leverage BMI2 if available
- Hardware CRC32 (SSE4.2)

**8.3 Linux**
- Ensure compatibility
- Optimize for server workloads
- Large data handling

**Tasks:**
1. Platform-specific SIMD code
2. Runtime CPU feature detection
3. Platform benchmarks
4. Conditional compilation
5. CI/CD for all platforms

### Phase 9: Release Preparation (Week 10)

**Goal:** Production-ready library

**Tasks:**
1. Final performance tuning
2. Security audit
3. Memory safety verification
4. Documentation review
5. Example projects
6. CI/CD setup (GitHub Actions)
7. Package.swift finalization
8. Versioning (1.0.0)
9. Release notes
10. Public announcement

**CI/CD Pipeline:**
```yaml
name: Tests
on: [push, pull_request]
jobs:
  test:
    strategy:
      matrix:
        os: [macos-latest, ubuntu-latest]
        swift: ["5.9", "5.10"]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v3
      - uses: swift-actions/setup-swift@v1
        with:
          swift-version: ${{ matrix.swift }}
      - run: swift test
      - run: swift test --enable-code-coverage
      - run: swift run benchmark
```

### Delivery Timeline

| Week | Phase | Deliverable |
|------|-------|-------------|
| 1-2 | Core Algorithm | Basic compress/decompress working |
| 3 | Platform + API | Swift-native API complete |
| 4-5 | Optimizations | Performance matches C++ |
| 6 | Testing | 100% test coverage |
| 7 | Benchmarking | Performance validated |
| 8 | Documentation | Full docs and examples |
| 9 | Platform Optimization | Platform-specific tuning |
| 10 | Release | Production-ready v1.0.0 |

### Success Criteria

**Correctness:**
- ✓ 100% round-trip success rate
- ✓ Compatible with C++ implementation
- ✓ Passes all reference tests

**Performance:**
- ✓ Within 20% of C++ speed (target: within 10%)
- ✓ Same compression ratio as C++
- ✓ Memory usage ≤ C++ implementation

**Quality:**
- ✓ 100% test coverage
- ✓ No memory leaks
- ✓ Thread-safe
- ✓ Comprehensive documentation

---

## Appendix A: Key Algorithms Pseudocode

### Compression (Level 1)

```
function compress(input):
  output = empty buffer
  hash_table = array[table_size] of uint16

  write_varint(output, input.length)

  ip = 0  # input position
  next_emit = 0  # next byte to emit as literal

  while ip < input.length - 15:
    # Hash current 4 bytes
    bytes = read_uint32(input, ip)
    hash = hash_function(bytes)

    # Look up candidate match
    candidate_pos = hash_table[hash]
    hash_table[hash] = ip

    # Check if candidate matches
    if candidate_pos > 0 and bytes == read_uint32(input, candidate_pos):
      # Emit literal for unmatched region
      if next_emit < ip:
        emit_literal(output, input[next_emit:ip])

      # Find full match length
      match_len = 4
      while ip + match_len < input.length and
            input[ip + match_len] == input[candidate_pos + match_len]:
        match_len++

      # Emit copy operation
      offset = ip - candidate_pos
      emit_copy(output, offset, match_len)

      # Skip matched bytes
      ip += match_len
      next_emit = ip
    else:
      ip++

      # Heuristic: skip ahead in incompressible data
      if ip - next_emit > 32:
        skip = (ip - next_emit) / 32
        ip += skip

  # Emit final literal
  if next_emit < input.length:
    emit_literal(output, input[next_emit:])

  return output
```

### Decompression

```
function decompress(input):
  # Read uncompressed length
  (uncompressed_len, ip) = read_varint(input)

  output = allocate(uncompressed_len)
  op = 0  # output position

  while ip < input.length:
    tag = input[ip++]
    tag_type = tag & 0b11

    if tag_type == LITERAL:
      # Decode literal length
      # All extra bytes encode (len - 1)
      if (tag >> 2) < 60:
        len = (tag >> 2) + 1
      elif (tag >> 2) == 60:
        # Read 1 extra byte encoding (len - 1)
        len = input[ip++] + 1
      elif (tag >> 2) == 61:
        # Read 2 extra bytes encoding (len - 1)
        len = read_uint16_le(input, ip) + 1
        ip += 2
      elif (tag >> 2) == 62:
        # Read 3 extra bytes encoding (len - 1)
        len = read_uint24_le(input, ip) + 1
        ip += 3
      elif (tag >> 2) == 63:
        # Read 4 extra bytes encoding (len - 1)
        len = read_uint32_le(input, ip) + 1
        ip += 4

      # Copy literal bytes
      copy(input[ip:ip+len], output[op:op+len])
      ip += len
      op += len

    elif tag_type == COPY_1_BYTE_OFFSET:
      len = ((tag >> 2) & 0b111) + 4
      offset = ((tag >> 5) << 8) | input[ip++]

      # Copy from output history
      incremental_copy(output[op - offset:], output[op:], len)
      op += len

    elif tag_type == COPY_2_BYTE_OFFSET:
      len = (tag >> 2) + 1
      offset = read_uint16_le(input, ip)
      ip += 2

      incremental_copy(output[op - offset:], output[op:], len)
      op += len

    elif tag_type == COPY_4_BYTE_OFFSET:
      len = (tag >> 2) + 1
      offset = read_uint32_le(input, ip)
      ip += 4

      incremental_copy(output[op - offset:], output[op:], len)
      op += len

  return output[0:op]
```

### Incremental Copy (Pattern Extension)

```
function incremental_copy(src, dst, len):
  pattern_size = dst - src  # offset

  if pattern_size < 16:
    # Use SIMD to extend pattern
    if pattern_size == 1:
      # Duplicate byte
      pattern = duplicate_byte(src[0])
      for i in 0..3:
        store_simd(dst + i*16, pattern)
    elif pattern_size in {2, 4, 8, 16}:
      # Load and replicate power-of-2 pattern
      pattern = load_pattern(src, pattern_size)
      for i in 0..3:
        store_simd(dst + i*16, pattern)
    else:
      # General case: shuffle to extend
      pattern = load_pattern(src, pattern_size)
      shuffle_mask = get_reshuffle_mask(pattern_size)
      for i in 0..3:
        store_simd(dst + i*16, pattern)
        pattern = shuffle(pattern, shuffle_mask)
  else:
    # Large pattern: use memcpy
    for i in 0..3:
      memcpy(dst + i*16, dst + i*16 - pattern_size, 16)
```

---

## Appendix B: Reference Materials

### Official Documentation

- **Format Specification:** `snappy-cpp/format_description.txt`
- **Framing Format:** `snappy-cpp/framing_format.txt` (optional)
- **README:** `snappy-cpp/README.md`
- **GitHub:** https://github.com/google/snappy

### Key Papers

- "LZ77: A Universal Algorithm for Sequential Data Compression" - Ziv & Lempel (1977)
- "The Snappy Compression Format" - Google (2011)

### Related Projects

- **Snappy-Java:** Java port
- **python-snappy:** Python bindings
- **snappy-c:** C bindings (included in repo)
- **rusty-snappy:** Rust port

### Performance Comparisons

From README.md benchmarks:

| Algorithm | Compression | Decompression | Ratio |
|-----------|-------------|---------------|-------|
| Snappy | 250 MB/s | 500 MB/s | 1.5-1.7x |
| zlib (fast) | 27 MB/s | 260 MB/s | 2.6-2.8x |
| LZO | 135 MB/s | 410 MB/s | 2.0-2.2x |
| LZF | 195 MB/s | 375 MB/s | 2.0-2.1x |

Snappy trades compression ratio for speed.

### Swift Resources

- **Swift SIMD:** https://developer.apple.com/documentation/swift/simd
- **Swift Performance:** WWDC talks on optimization
- **Swift Package Manager:** https://swift.org/package-manager/
- **DocC:** https://developer.apple.com/documentation/docc

---

## Conclusion

This analysis provides a comprehensive foundation for porting Google's Snappy compression library to Swift. The C++ implementation is well-structured, extensively optimized, and thoroughly tested - providing an excellent reference for the Swift port.

### Key Takeaways

1. **Simple Core Algorithm:** LZ77 with hash table matching
2. **Fixed Format:** Byte-oriented encoding with simple tag system
3. **Speed-Focused:** Multiple SIMD optimizations, lookup tables, branch hints
4. **Production-Ready:** Extensive testing, validation, error handling
5. **Clean Codebase:** ~3800 LOC of well-organized, documented C++

### Next Steps

1. Review this analysis
2. Set up Swift package structure
3. Begin Phase 1: Core Algorithm implementation
4. Follow the 10-week roadmap
5. Maintain compatibility with C++ implementation
6. Achieve production-ready status

---

**Analysis Date:** 2025-11-02
**Analyzed By:** Claude (Anthropic)
**Source Version:** Snappy C++ (latest from GitHub)
