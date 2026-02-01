//
//  AudioConverter.swift
//  Music
//
//  Converts audio files to M4A format.
//  Uses AVAssetExportSession for mp3/m4a and AudioToolbox for FLAC.
//

import Foundation
import AVFoundation
import AudioToolbox

#if os(macOS)

struct AudioConverter {
    private static let supportedInputFormats = Set(["mp3", "m4a", "flac", "wav", "aac", "aiff"])

    /// Check if a file needs conversion (not already m4a)
    static func needsConversion(_ fileURL: URL) -> Bool {
        let ext = fileURL.pathExtension.lowercased()
        return ext != "m4a" && supportedInputFormats.contains(ext)
    }

    /// Convert audio file to M4A format.
    /// Returns the URL of the converted file in a temporary directory.
    func convert(_ inputURL: URL) async throws -> URL {
        let inputFormat = inputURL.pathExtension.lowercased()

        // If already M4A, return as-is
        guard inputFormat != "m4a" else {
            return inputURL
        }

        // Create temporary output file
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        // FLAC requires special handling with AudioToolbox
        if inputFormat == "flac" {
            try await convertFLAC(inputURL, to: outputURL)
        } else {
            try await convertWithAVAsset(inputURL, to: outputURL)
        }

        return outputURL
    }

    // MARK: - AVAssetExportSession Conversion

    private func convertWithAVAsset(_ inputURL: URL, to outputURL: URL) async throws {
        let asset = AVURLAsset(url: inputURL)

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ConversionError.exportSessionCreationFailed
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a

        await exportSession.export()

        switch exportSession.status {
        case .completed:
            return
        case .failed:
            throw exportSession.error ?? ConversionError.exportFailed
        case .cancelled:
            throw ConversionError.cancelled
        default:
            throw ConversionError.unknownStatus
        }
    }

    // MARK: - FLAC Conversion via AudioToolbox

    private func convertFLAC(_ inputURL: URL, to outputURL: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.performFLACConversion(inputURL, to: outputURL)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func performFLACConversion(_ inputURL: URL, to outputURL: URL) throws {
        // Open input file
        var inputFile: ExtAudioFileRef?
        var status = ExtAudioFileOpenURL(inputURL as CFURL, &inputFile)
        guard status == noErr, let inputFile = inputFile else {
            throw ConversionError.cannotOpenInput(status)
        }
        defer { ExtAudioFileDispose(inputFile) }

        // Get input format
        var inputFormat = AudioStreamBasicDescription()
        var propertySize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = ExtAudioFileGetProperty(inputFile, kExtAudioFileProperty_FileDataFormat, &propertySize, &inputFormat)
        guard status == noErr else {
            throw ConversionError.cannotGetInputFormat(status)
        }

        // Set up client format (PCM for reading)
        var clientFormat = AudioStreamBasicDescription()
        clientFormat.mSampleRate = inputFormat.mSampleRate
        clientFormat.mFormatID = kAudioFormatLinearPCM
        clientFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        clientFormat.mBitsPerChannel = 16
        clientFormat.mChannelsPerFrame = inputFormat.mChannelsPerFrame
        clientFormat.mBytesPerFrame = clientFormat.mChannelsPerFrame * 2
        clientFormat.mFramesPerPacket = 1
        clientFormat.mBytesPerPacket = clientFormat.mBytesPerFrame

        status = ExtAudioFileSetProperty(inputFile, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFormat)
        guard status == noErr else {
            throw ConversionError.cannotSetClientFormat(status)
        }

        // Set up output format (AAC)
        var outputFormat = AudioStreamBasicDescription()
        outputFormat.mSampleRate = inputFormat.mSampleRate
        outputFormat.mFormatID = kAudioFormatMPEG4AAC
        outputFormat.mFormatFlags = 0
        outputFormat.mBytesPerPacket = 0
        outputFormat.mFramesPerPacket = 1024
        outputFormat.mBytesPerFrame = 0
        outputFormat.mChannelsPerFrame = inputFormat.mChannelsPerFrame
        outputFormat.mBitsPerChannel = 0

        // Create output file
        var outputFile: ExtAudioFileRef?
        status = ExtAudioFileCreateWithURL(
            outputURL as CFURL,
            kAudioFileM4AType,
            &outputFormat,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &outputFile
        )
        guard status == noErr, let outputFile = outputFile else {
            throw ConversionError.cannotCreateOutput(status)
        }
        defer { ExtAudioFileDispose(outputFile) }

        // Set client format on output
        status = ExtAudioFileSetProperty(outputFile, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFormat)
        guard status == noErr else {
            throw ConversionError.cannotSetOutputClientFormat(status)
        }

        // Read/write in chunks
        let bufferFrames: UInt32 = 4096
        let bufferSize = Int(bufferFrames * clientFormat.mBytesPerFrame)
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        while true {
            var frameCount = bufferFrames

            let audioBuffer = AudioBuffer(
                mNumberChannels: clientFormat.mChannelsPerFrame,
                mDataByteSize: UInt32(bufferSize),
                mData: &buffer
            )
            var bufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: audioBuffer)

            status = ExtAudioFileRead(inputFile, &frameCount, &bufferList)
            guard status == noErr else {
                throw ConversionError.readError(status)
            }

            if frameCount == 0 {
                break  // End of file
            }

            // Update actual data size
            bufferList.mBuffers.mDataByteSize = frameCount * clientFormat.mBytesPerFrame

            status = ExtAudioFileWrite(outputFile, frameCount, &bufferList)
            guard status == noErr else {
                throw ConversionError.writeError(status)
            }
        }
    }
}

// MARK: - Conversion Errors

enum ConversionError: LocalizedError {
    case exportSessionCreationFailed
    case exportFailed
    case cancelled
    case unknownStatus
    case cannotOpenInput(OSStatus)
    case cannotGetInputFormat(OSStatus)
    case cannotSetClientFormat(OSStatus)
    case cannotCreateOutput(OSStatus)
    case cannotSetOutputClientFormat(OSStatus)
    case readError(OSStatus)
    case writeError(OSStatus)

    var errorDescription: String? {
        switch self {
        case .exportSessionCreationFailed:
            return "Failed to create export session"
        case .exportFailed:
            return "Export failed"
        case .cancelled:
            return "Conversion was cancelled"
        case .unknownStatus:
            return "Unknown export status"
        case .cannotOpenInput(let status):
            return "Cannot open input file (status: \(status))"
        case .cannotGetInputFormat(let status):
            return "Cannot get input format (status: \(status))"
        case .cannotSetClientFormat(let status):
            return "Cannot set client format (status: \(status))"
        case .cannotCreateOutput(let status):
            return "Cannot create output file (status: \(status))"
        case .cannotSetOutputClientFormat(let status):
            return "Cannot set output client format (status: \(status))"
        case .readError(let status):
            return "Read error (status: \(status))"
        case .writeError(let status):
            return "Write error (status: \(status))"
        }
    }
}

#endif
