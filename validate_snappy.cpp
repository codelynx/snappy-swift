// Validate Snappy compressed files using C++ decompressor
// This validates that Swift-compressed data can be decompressed by C++
// Compile: g++ -std=c++11 validate_snappy.cpp snappy-cpp/snappy.cc snappy-cpp/snappy-sinksource.cc snappy-cpp/snappy-stubs-internal.cc -o validate_snappy
// Usage: ./validate_snappy <compressed_file> <expected_uncompressed_size>

#include "snappy-cpp/snappy.h"
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

int main(int argc, char* argv[]) {
    if (argc != 3) {
        std::cerr << "Usage: " << argv[0] << " <compressed_file> <expected_size>" << std::endl;
        std::cerr << "Example: " << argv[0] << " test.snappy 100" << std::endl;
        return 1;
    }

    std::string filename = argv[1];
    size_t expectedSize = std::stoull(argv[2]);

    // Read compressed file
    std::ifstream file(filename, std::ios::binary);
    if (!file) {
        std::cerr << "ERROR: Cannot open file: " << filename << std::endl;
        return 1;
    }

    std::string compressed(
        (std::istreambuf_iterator<char>(file)),
        std::istreambuf_iterator<char>()
    );
    file.close();

    std::cout << "File: " << filename << std::endl;
    std::cout << "Compressed size: " << compressed.size() << " bytes" << std::endl;

    // Validate compressed data
    if (!snappy::IsValidCompressedBuffer(compressed.data(), compressed.size())) {
        std::cerr << "ERROR: Invalid compressed data format" << std::endl;
        return 1;
    }
    std::cout << "✓ Format validation passed" << std::endl;

    // Get uncompressed length
    size_t uncompressedLength;
    if (!snappy::GetUncompressedLength(compressed.data(), compressed.size(), &uncompressedLength)) {
        std::cerr << "ERROR: Cannot get uncompressed length" << std::endl;
        return 1;
    }
    std::cout << "✓ Uncompressed length: " << uncompressedLength << " bytes" << std::endl;

    // Check against expected size
    if (uncompressedLength != expectedSize) {
        std::cerr << "ERROR: Size mismatch! Expected " << expectedSize
                  << " but got " << uncompressedLength << std::endl;
        return 1;
    }
    std::cout << "✓ Size matches expected: " << expectedSize << " bytes" << std::endl;

    // Decompress
    std::string decompressed;
    if (!snappy::Uncompress(compressed.data(), compressed.size(), &decompressed)) {
        std::cerr << "ERROR: Decompression failed" << std::endl;
        return 1;
    }
    std::cout << "✓ Decompression successful" << std::endl;

    // Verify final size
    if (decompressed.size() != expectedSize) {
        std::cerr << "ERROR: Decompressed size mismatch! Expected " << expectedSize
                  << " but got " << decompressed.size() << std::endl;
        return 1;
    }

    // Calculate compression ratio
    double ratio = (double)decompressed.size() / (double)compressed.size();
    std::cout << "✓ Compression ratio: " << ratio << "x" << std::endl;

    std::cout << "\n✅ ALL CHECKS PASSED - Swift-compressed data is valid!" << std::endl;
    return 0;
}
