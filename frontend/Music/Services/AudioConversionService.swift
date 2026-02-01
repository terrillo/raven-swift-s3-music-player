//
//  AudioConversionService.swift
//  Music
//
//  Converts audio files to M4A format for streaming compatibility.
//

import Foundation
import AVFoundation

#if os(macOS)

// MARK: - AudioConversionService

/// Service for converting audio files to M4A format using AVAssetExportSession.
actor AudioConversionService {
    private let outputDirectory: URL

    init(outputDirectory: URL) {
        self.outputDirectory = outputDirectory
    }

    // MARK: - Conversion

    /// Convert an audio file to M4A format.
    /// Returns the URL of the converted file, or the original URL if no conversion needed.
    func convertToM4A(fileURL: URL, progress: ((Double) -> Void)? = nil) async throws -> URL {
        let ext = fileURL.pathExtension.lowercased()

        // Already M4A or MP3 - no conversion needed
        if ext == "m4a" || ext == "mp3" {
            return fileURL
        }

        // Create output directory if needed
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        // Generate output filename
        let outputFilename = fileURL.deletingPathExtension().lastPathComponent + ".m4a"
        let outputURL = outputDirectory.appendingPathComponent(outputFilename)

        // Remove existing file if present
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        // Create asset
        let asset = AVURLAsset(url: fileURL)

        // Check if format is compatible with AVAssetExportSession
        guard await isExportCompatible(asset) else {
            // Fall back to pass-through for unsupported formats
            throw ConversionError.unsupportedFormat(ext)
        }

        // Create export session
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw ConversionError.exportSessionCreationFailed
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a

        // Start export with progress monitoring
        return try await withCheckedThrowingContinuation { continuation in
            // Monitor progress
            let progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
                let currentProgress = Double(exportSession.progress)
                progress?(currentProgress)

                if exportSession.status != .exporting {
                    timer.invalidate()
                }
            }

            exportSession.exportAsynchronously {
                progressTimer.invalidate()

                switch exportSession.status {
                case .completed:
                    progress?(1.0)
                    continuation.resume(returning: outputURL)

                case .failed:
                    let error = exportSession.error ?? ConversionError.exportFailed
                    continuation.resume(throwing: error)

                case .cancelled:
                    continuation.resume(throwing: ConversionError.cancelled)

                default:
                    continuation.resume(throwing: ConversionError.unexpectedStatus(exportSession.status))
                }
            }
        }
    }

    /// Check if the asset can be exported using AVAssetExportSession.
    private func isExportCompatible(_ asset: AVURLAsset) async -> Bool {
        // Get compatible presets
        let compatiblePresets = AVAssetExportSession.exportPresets(compatibleWith: asset)
        return compatiblePresets.contains(AVAssetExportPresetAppleM4A)
    }

    /// Convert a file using ffmpeg command-line tool (fallback for FLAC).
    /// Requires ffmpeg to be installed.
    func convertWithFFmpeg(fileURL: URL, progress: ((Double) -> Void)? = nil) async throws -> URL {
        // Create output directory if needed
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        // Generate output filename
        let outputFilename = fileURL.deletingPathExtension().lastPathComponent + ".m4a"
        let outputURL = outputDirectory.appendingPathComponent(outputFilename)

        // Remove existing file if present
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        // Find ffmpeg
        let ffmpegPath = try findFFmpeg()

        // Build ffmpeg command
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = [
            "-i", fileURL.path,
            "-c:a", "aac",
            "-b:a", "256k",
            "-vn",  // No video
            "-y",   // Overwrite output
            outputURL.path
        ]

        // Capture stderr for progress parsing
        let pipe = Pipe()
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ConversionError.ffmpegFailed(Int(process.terminationStatus))
        }

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw ConversionError.outputFileNotCreated
        }

        progress?(1.0)
        return outputURL
    }

    /// Find ffmpeg binary in common locations.
    private func findFFmpeg() throws -> String {
        let paths = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]

        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        // Try which command
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["ffmpeg"]

        let pipe = Pipe()
        process.standardOutput = pipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return path
            }
        }

        throw ConversionError.ffmpegNotFound
    }

    // MARK: - Cleanup

    /// Remove a converted file.
    func cleanup(_ fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Remove all converted files.
    func cleanupAll() {
        try? FileManager.default.removeItem(at: outputDirectory)
    }
}

// MARK: - Errors

enum ConversionError: LocalizedError {
    case unsupportedFormat(String)
    case exportSessionCreationFailed
    case exportFailed
    case cancelled
    case unexpectedStatus(AVAssetExportSession.Status)
    case ffmpegNotFound
    case ffmpegFailed(Int)
    case outputFileNotCreated

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format):
            return "Unsupported format for conversion: \(format)"
        case .exportSessionCreationFailed:
            return "Failed to create export session"
        case .exportFailed:
            return "Export failed"
        case .cancelled:
            return "Conversion cancelled"
        case .unexpectedStatus(let status):
            return "Unexpected export status: \(status.rawValue)"
        case .ffmpegNotFound:
            return "ffmpeg not found. Install with: brew install ffmpeg"
        case .ffmpegFailed(let code):
            return "ffmpeg failed with exit code: \(code)"
        case .outputFileNotCreated:
            return "Output file was not created"
        }
    }
}

#else

// iOS stub - conversion is macOS only
actor AudioConversionService {
    init(outputDirectory: URL) {}

    func convertToM4A(fileURL: URL, progress: ((Double) -> Void)?) async throws -> URL {
        return fileURL
    }

    func convertWithFFmpeg(fileURL: URL, progress: ((Double) -> Void)?) async throws -> URL {
        return fileURL
    }

    func cleanup(_ fileURL: URL) {}
    func cleanupAll() {}
}

#endif
