// Generate test data for Snappy Swift implementation
// Compile: g++ -std=c++11 generate_test_data.cpp snappy-cpp/snappy.cc snappy-cpp/snappy-sinksource.cc snappy-cpp/snappy-stubs-internal.cc -o generate_test_data
// Run: ./generate_test_data

#include "snappy-cpp/snappy.h"
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

void writeTestCase(const std::string& name, const std::string& input) {
    std::string compressed;
    snappy::Compress(input.data(), input.size(), &compressed);

    std::string filename = "Tests/SnappySwiftTests/TestData/" + name + ".snappy";
    std::ofstream file(filename, std::ios::binary);
    file.write(compressed.data(), compressed.size());
    file.close();

    std::cout << name << ":" << std::endl;
    std::cout << "  Input size: " << input.size() << " bytes" << std::endl;
    std::cout << "  Compressed size: " << compressed.size() << " bytes" << std::endl;
    std::cout << "  Ratio: " << (double)input.size() / compressed.size() << "x" << std::endl;
    std::cout << "  Saved to: " << filename << std::endl;
    std::cout << std::endl;
}

int main() {
    std::cout << "Generating Snappy test data..." << std::endl;
    std::cout << std::endl;

    // Test 1: Empty string
    writeTestCase("empty", "");

    // Test 2: Single byte
    writeTestCase("single_byte", "A");

    // Test 3: Short string (no compression expected)
    writeTestCase("hello", "Hello, World!");

    // Test 4: Repeated pattern (good compression)
    writeTestCase("repeated", std::string(100, 'a'));

    // Test 5: Pattern with repetition
    std::string pattern;
    for (int i = 0; i < 20; i++) {
        pattern += "abcdefgh";
    }
    writeTestCase("pattern", pattern);

    // Test 6: Longer text
    std::string longer =
        "The quick brown fox jumps over the lazy dog. "
        "The quick brown fox jumps over the lazy dog. "
        "The quick brown fox jumps over the lazy dog. "
        "The quick brown fox jumps over the lazy dog.";
    writeTestCase("longer_text", longer);

    // Test 7: All ASCII characters
    std::string ascii;
    for (int i = 32; i < 127; i++) {
        ascii += char(i);
    }
    writeTestCase("ascii", ascii);

    // Test 8: Large block (test block handling)
    std::string large(10000, 'x');
    writeTestCase("large", large);

    // Test 9: Mixed content
    std::string mixed = "AAAAAAAbbbbbCCCCCdddEEFF1234567890";
    writeTestCase("mixed", mixed);

    // Test 10: Numbers
    std::string numbers;
    for (int i = 0; i < 100; i++) {
        numbers += std::to_string(i) + " ";
    }
    writeTestCase("numbers", numbers);

    // Test 11: Large - 100KB (repeated pattern)
    std::string large100k;
    std::string chunk = "The quick brown fox jumps over the lazy dog. ";
    while (large100k.size() < 100000) {
        large100k += chunk;
    }
    large100k.resize(100000);  // Exactly 100KB
    writeTestCase("large_100kb", large100k);

    // Test 12: Large - 1MB (mixed content)
    std::string large1mb;
    for (int i = 0; i < 10000; i++) {
        large1mb += "Line " + std::to_string(i) + ": Lorem ipsum dolor sit amet, consectetur adipiscing elit. ";
        if (i % 10 == 0) {
            large1mb += std::string(50, 'A' + (i % 26));  // Add some repeated patterns
        }
    }
    large1mb.resize(1048576);  // Exactly 1MB
    writeTestCase("large_1mb", large1mb);

    // Test 13: Large - 10MB (highly compressible)
    std::cout << "Generating 10MB file (this may take a moment)..." << std::endl;
    std::string large10mb;
    large10mb.reserve(10485760);
    for (int i = 0; i < 10485760 / 100; i++) {
        // Highly compressible pattern
        large10mb += std::string(100, 'X');
    }
    writeTestCase("large_10mb", large10mb);

    std::cout << "Test data generation complete!" << std::endl;
    return 0;
}
