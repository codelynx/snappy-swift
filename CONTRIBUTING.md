# Contributing to SnappySwift

Thank you for your interest in contributing to SnappySwift! This guide will help you get started.

## Getting Started

### Basic Setup

```bash
# Clone the repository
git clone https://github.com/codelynx/snappy-swift.git
cd snappy-swift

# Build the project
swift build

# Run tests
swift test
```

That's all you need for most contributions!

## Working with C++ Reference Implementation

The C++ reference implementation is **not included** as a git submodule to ensure clean SPM installation for end users. If you need to work with C++ compatibility testing, follow this setup:

### When You Need C++ Setup

You only need the C++ reference for:
- Regenerating test data (rare - maybe once per release)
- Validating Swift output against C++ (compatibility testing)
- Updating to newer C++ Snappy versions
- Debugging compression format differences

### Manual C++ Setup

#### 1. Clone C++ Reference (One-Time Setup)

```bash
# From the snappy-swift directory
cd ..
git clone https://github.com/google/snappy.git snappy-cpp
cd snappy-swift
```

Now you have:
```
Projects/
├── snappy-swift/          # This repository
└── snappy-cpp/            # C++ reference (separate)
```

#### 2. Compile C++ Tools

The repository includes two C++ tools:

```bash
# Compile test data generator (requires g++ or clang++)
g++ -std=c++11 generate_test_data.cpp \
    ../snappy-cpp/snappy.cc \
    ../snappy-cpp/snappy-sinksource.cc \
    ../snappy-cpp/snappy-stubs-internal.cc \
    -o generate_test_data

# Compile validation tool
g++ -std=c++11 validate_snappy.cpp \
    ../snappy-cpp/snappy.cc \
    ../snappy-cpp/snappy-sinksource.cc \
    ../snappy-cpp/snappy-stubs-internal.cc \
    -o validate_snappy
```

**Note:** The compiled binaries (`generate_test_data`, `validate_snappy`) are gitignored and should not be committed.

#### 3. Using C++ Tools

**Generate Test Data:**
```bash
./generate_test_data
# Creates test files in Tests/SnappySwiftTests/TestData/
```

**Validate Swift Compression:**
```bash
# First, generate a .snappy file with Swift
swift test --filter testLargePayloadCompatibility

# Then validate with C++
./validate_snappy Tests/SnappySwiftTests/TestData/large_10mb.snappy 10485760
```

### Keeping C++ Reference Updated

```bash
# Update to latest C++ Snappy
cd ../snappy-cpp
git pull origin main

# Return to snappy-swift and recompile tools
cd ../snappy-swift
g++ -std=c++11 generate_test_data.cpp ../snappy-cpp/snappy*.cc -o generate_test_data
g++ -std=c++11 validate_snappy.cpp ../snappy-cpp/snappy*.cc -o validate_snappy

# Regenerate test data if needed
./generate_test_data

# Run compatibility tests
swift test --filter CompatibilityTests
```

## Development Workflow

### Making Changes

1. **Create a branch:**
   ```bash
   git checkout -b feature/my-feature
   ```

2. **Make your changes:**
   - Edit source files in `Sources/SnappySwift/`
   - Add tests in `Tests/SnappySwiftTests/`

3. **Run tests:**
   ```bash
   swift test
   ```

4. **Run benchmarks (optional):**
   ```bash
   swift test --filter BenchmarkTests
   ```

5. **Verify C++ compatibility (if format changes):**
   ```bash
   # Only needed if you changed compression/decompression logic
   swift test --filter CompatibilityTests
   ```

### Testing Guidelines

- Add tests for all new features
- Maintain 100% C++ compatibility for format changes
- Run full test suite before submitting PR
- Add benchmark tests for performance-critical changes

### Code Style

- Follow Swift API Design Guidelines
- Use meaningful variable names
- Add documentation comments for public APIs
- Keep functions focused and concise

## Compatibility Requirements

SnappySwift maintains **100% compatibility** with Google's C++ Snappy:

- Must decompress all C++ Snappy output correctly
- Swift-compressed data must decompress correctly with C++
- Follow the Snappy format specification exactly
- Test against reference test data

## Submitting Changes

1. **Commit your changes:**
   ```bash
   git add .
   git commit -m "Add feature: brief description"
   ```

2. **Push to your fork:**
   ```bash
   git push origin feature/my-feature
   ```

3. **Create a Pull Request:**
   - Describe your changes
   - Reference any related issues
   - Include test results
   - Note any performance impacts

## Common Development Tasks

### Adding a New Test Case

```swift
// In Tests/SnappySwiftTests/CompressionTests.swift
func testMyNewFeature() throws {
    let input = Data("test data".utf8)
    let compressed = try input.snappyCompressed()
    let decompressed = try compressed.snappyDecompressed()
    XCTAssertEqual(input, decompressed)
}
```

### Debugging Compression Issues

```bash
# Enable verbose test output
swift test --filter testName -v

# Compare with C++ output
./generate_test_data  # Generate C++ reference
swift test --filter CompatibilityTests
```

### Performance Testing

```bash
# Run all benchmarks
swift test --filter BenchmarkTests

# Run specific benchmark
swift test --filter testCompressionThroughput
```

## Project Structure

```
SnappySwift/
├── Sources/SnappySwift/
│   ├── SnappySwift.swift      # Public API
│   ├── Data+Snappy.swift      # Foundation extensions
│   ├── Internal.swift         # Format types
│   ├── Compression.swift      # Compression implementation
│   └── Decompression.swift    # Decompression implementation
├── Tests/SnappySwiftTests/
│   ├── CompressionTests.swift
│   ├── DecompressionTests.swift
│   ├── CompatibilityTests.swift
│   ├── BenchmarkTests.swift
│   └── TestData/              # Pre-generated test files
├── generate_test_data.cpp     # C++ tool (source)
├── validate_snappy.cpp        # C++ tool (source)
└── Package.swift
```

## Getting Help

- **Issues:** Open an issue on GitHub
- **Discussions:** Use GitHub Discussions for questions
- **Pull Requests:** Draft PRs are welcome for early feedback

## License

By contributing, you agree that your contributions will be licensed under the BSD 3-Clause License.

---

Thank you for contributing to SnappySwift!
