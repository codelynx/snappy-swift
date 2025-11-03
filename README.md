# SnappySwift

A pure Swift implementation of Google's Snappy compression algorithm, providing fast compression and decompression with reasonable compression ratios.

## Status

🚧 **Under Development** - Phase 1 in progress

- ✅ Package structure
- ✅ Basic types (Tags, Varint)
- ✅ API design
- 🚧 Compression implementation
- 🚧 Decompression implementation
- 🚧 Test suite
- 🚧 Performance optimization

## Overview

Snappy is a compression library optimized for speed rather than maximum compression. It's designed for scenarios where compression/decompression speed is critical.

### Key Features

- **Fast**: Compression at ~250 MB/s, decompression at ~500 MB/s
- **Reasonable compression**: 1.5-1.7x for text, 2-4x for HTML
- **Stable format**: Compatible with Google's C++ implementation
- **Zero dependencies**: Pure Swift, no external libraries
- **Cross-platform**: macOS, iOS, watchOS, tvOS, Linux (coming soon)

### Use Cases

- Database storage (LevelDB, Cassandra, MongoDB)
- Network protocols (Protocol Buffers, Hadoop)
- In-memory compression
- Real-time data pipelines

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/yourusername/snappy-swift.git", from: "1.0.0")
]
```

Then add the dependency to your target:

```swift
.target(
    name: "YourTarget",
    dependencies: ["SnappySwift"]
)
```

## Usage

### Basic Compression/Decompression

```swift
import SnappySwift
import Foundation

// Compress data
let original = "Hello, World! This is a test of Snappy compression.".data(using: .utf8)!
let compressed = try original.snappyCompressed()

print("Original: \(original.count) bytes")
print("Compressed: \(compressed.count) bytes")
print("Ratio: \(Double(original.count) / Double(compressed.count))x")

// Decompress data
let decompressed = try compressed.snappyDecompressed()
assert(decompressed == original)
```

### Low-Level API

```swift
import SnappySwift

// Using buffer-based API
let input: [UInt8] = [/* your data */]
let maxCompressedSize = Snappy.maxCompressedLength(input.count)
var output = [UInt8](repeating: 0, count: maxCompressedSize)

let compressedSize = try input.withUnsafeBufferPointer { inputBuf in
    try output.withUnsafeMutableBufferPointer { outputBuf in
        try Snappy.compress(inputBuf, to: outputBuf)
    }
}

print("Compressed \(input.count) bytes to \(compressedSize) bytes")
```

### Validation

```swift
// Check if data is valid Snappy-compressed
if compressed.isValidSnappyCompressed() {
    print("Data is valid")
}

// Get uncompressed length without decompressing
compressed.withUnsafeBytes { buffer in
    let bytes = buffer.bindMemory(to: UInt8.self)
    if let length = Snappy.getUncompressedLength(bytes) {
        print("Will decompress to \(length) bytes")
    }
}
```

## Performance

Target performance (compared to C++ implementation):

- Compression: Within 10-20% of C++ speed
- Decompression: Within 10-20% of C++ speed
- Compression ratio: Identical to C++

## Architecture

```
SnappySwift/
├── SnappySwift.swift      # Public API
├── Data+Snappy.swift      # Foundation extensions
├── Internal.swift         # Format types (Tags, Varint)
├── Compression.swift      # Compression implementation (TODO)
├── Decompression.swift    # Decompression implementation (TODO)
└── Utilities.swift        # Helper functions (TODO)
```

## Development

### Building

```bash
swift build
```

### Testing

```bash
swift test
```

### Running Tests with Coverage

```bash
swift test --enable-code-coverage
```

## Compatibility

This implementation is designed to be **100% compatible** with Google's C++ Snappy implementation:

- Produces identical compressed output
- Can decompress C++ Snappy output
- Follows the same format specification
- Validates against reference test data

## Roadmap

### Phase 1: Core Implementation (Current)
- [x] Package structure
- [x] Basic types and format handling
- [ ] Single-hash compression (level 1)
- [ ] Branchless decompression
- [ ] Basic test suite

### Phase 2: Optimization
- [ ] SIMD acceleration
- [ ] Double-hash compression (level 2)
- [ ] Performance benchmarks
- [ ] Platform-specific optimizations

### Phase 3: Polish
- [ ] Comprehensive test suite
- [ ] Compatibility tests with C++
- [ ] Documentation
- [ ] Examples
- [ ] CI/CD

## References

- [Google Snappy](https://github.com/google/snappy)
- [Format Specification](./docs/snappy-cpp-analysis.md)
- [C++ Analysis](./docs/snappy-cpp-analysis.md)

## License

BSD 3-Clause License (same as Google Snappy)

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Acknowledgments

This implementation is based on Google's Snappy C++ library. Special thanks to the Snappy team for creating such an elegant and fast compression algorithm.
