//
//  ArtworkExtractor.swift
//  Music
//
//  Extracts embedded artwork from audio files using AVAsset.
//

import Foundation
import AVFoundation

#if os(macOS)
import AppKit

/// Extracted artwork data
struct ExtractedArtwork {
    let data: Data
    let mimeType: String
}

struct ArtworkExtractor {

    /// Extract embedded artwork from an audio file.
    /// Returns ExtractedArtwork on success, nil if no artwork found.
    func extract(from fileURL: URL) async -> ExtractedArtwork? {
        let asset = AVURLAsset(url: fileURL)

        do {
            let metadata = try await asset.load(.metadata)

            // Try common artwork identifier
            if let artwork = await extractArtwork(from: metadata, identifier: .commonIdentifierArtwork) {
                return artwork
            }

            // Try iTunes artwork
            if let artwork = await extractArtwork(from: metadata, identifier: .iTunesMetadataCoverArt) {
                return artwork
            }

            // Try ID3 attached picture (APIC)
            if let artwork = await extractArtwork(from: metadata, key: "APIC", keySpace: .id3) {
                return artwork
            }

            // Try generic search across all metadata
            for item in metadata {
                if let identifier = item.identifier?.rawValue,
                   identifier.lowercased().contains("artwork") || identifier.lowercased().contains("picture") || identifier.lowercased().contains("covr") {
                    if let artwork = await extractFromItem(item) {
                        return artwork
                    }
                }
            }

        } catch {
            // Metadata not available
        }

        return nil
    }

    // MARK: - Helper Methods

    private func extractArtwork(from metadata: [AVMetadataItem], identifier: AVMetadataIdentifier) async -> ExtractedArtwork? {
        let items = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier)
        guard let item = items.first else { return nil }
        return await extractFromItem(item)
    }

    private func extractArtwork(from metadata: [AVMetadataItem], key: String, keySpace: AVMetadataKeySpace) async -> ExtractedArtwork? {
        let items = AVMetadataItem.metadataItems(from: metadata, withKey: key, keySpace: keySpace)
        guard let item = items.first else { return nil }
        return await extractFromItem(item)
    }

    private func extractFromItem(_ item: AVMetadataItem) async -> ExtractedArtwork? {
        // Try to load data value
        do {
            if let dataValue = try await item.load(.dataValue) {
                let mimeType = determineMimeType(from: dataValue)
                return ExtractedArtwork(data: dataValue, mimeType: mimeType)
            }
        } catch {
            // Fall through to try value
        }

        // Try legacy value property
        if let data = item.dataValue {
            let mimeType = determineMimeType(from: data)
            return ExtractedArtwork(data: data, mimeType: mimeType)
        }

        // Try converting from value
        if let value = item.value {
            if let data = value as? Data {
                let mimeType = determineMimeType(from: data)
                return ExtractedArtwork(data: data, mimeType: mimeType)
            }

            // Handle NSImage for some formats
            #if os(macOS)
            if let image = value as? NSImage, let tiffData = image.tiffRepresentation {
                if let bitmap = NSBitmapImageRep(data: tiffData),
                   let pngData = bitmap.representation(using: .png, properties: [:]) {
                    return ExtractedArtwork(data: pngData, mimeType: "image/png")
                }
            }
            #endif
        }

        return nil
    }

    /// Determine MIME type from image data by checking magic bytes
    private func determineMimeType(from data: Data) -> String {
        guard data.count >= 4 else { return "image/jpeg" }

        let bytes = [UInt8](data.prefix(4))

        // JPEG: FF D8 FF
        if bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF {
            return "image/jpeg"
        }

        // PNG: 89 50 4E 47
        if bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47 {
            return "image/png"
        }

        // GIF: 47 49 46
        if bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 {
            return "image/gif"
        }

        // WEBP: 52 49 46 46 ... 57 45 42 50
        if data.count >= 12 && bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 {
            let webpBytes = [UInt8](data[8..<12])
            if webpBytes == [0x57, 0x45, 0x42, 0x50] {
                return "image/webp"
            }
        }

        // Default to JPEG
        return "image/jpeg"
    }
}

#endif
