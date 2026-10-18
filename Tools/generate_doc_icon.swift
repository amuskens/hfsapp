#!/usr/bin/env swift
import Foundation

// Compatibility entry point. The shared renderer owns the artwork and iconset sizes.
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: generate_doc_icon.swift <output-directory>\n", stderr)
    exit(1)
}
let renderer = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("generate_artwork.swift")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
process.arguments = ["swift", renderer.path, "floppy", CommandLine.arguments[1]]
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
