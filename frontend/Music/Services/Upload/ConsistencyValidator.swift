//
//  ConsistencyValidator.swift
//  Music
//
//  Cross-track album-level validation to catch metadata inconsistencies.
//  Groups tracks by parent directory and flags outliers.
//

import Foundation

#if os(macOS)

struct ConsistencyWarning: Identifiable {
    let id = UUID()
    let folderPath: String
    let message: String
    let affectedItems: [UUID]
    let fix: ConsistencyFix
}

enum ConsistencyFix {
    case useArtistMajority(artist: String)
    case useAlbumMajority(album: String)
    case markForReview
}

enum ConsistencyValidator {
    static func validate(_ items: [UploadPreviewItem]) -> [ConsistencyWarning] {
        var warnings: [ConsistencyWarning] = []

        // Group items by parent directory
        var byFolder: [String: [UploadPreviewItem]] = [:]
        for item in items {
            let dir = (item.localPath as NSString).deletingLastPathComponent
            byFolder[dir, default: []].append(item)
        }

        for (folder, folderItems) in byFolder {
            guard folderItems.count >= 3 else { continue }

            // Check artist consistency (normalize keys so "Hozier" and "hozier" group together)
            let artistGroups = Dictionary(grouping: folderItems, by: { $0.artist.lowercased() })
            if artistGroups.count > 1,
               let (_, majorityItems) = artistGroups.max(by: { $0.value.count < $1.value.count }) {
                let majorityArtist = majorityItems[0].artist  // Original-cased display name
                let majorityRatio = Double(majorityItems.count) / Double(folderItems.count)
                if majorityRatio >= 0.6 {
                    let outlierItems = folderItems.filter { $0.artist.lowercased() != majorityArtist.lowercased() }
                    if !outlierItems.isEmpty {
                        let outlierNames = Set(outlierItems.map { $0.artist })
                        warnings.append(ConsistencyWarning(
                            folderPath: folder,
                            message: "\(outlierItems.count) track(s) have artist \"\(outlierNames.joined(separator: ", "))\" but \(majorityItems.count) others say \"\(majorityArtist)\"",
                            affectedItems: outlierItems.map { $0.id },
                            fix: .useArtistMajority(artist: majorityArtist)
                        ))
                    }
                }
            }

            // Check album consistency (normalize keys so "Abbey Road" and "abbey road" group together)
            let albumGroups = Dictionary(grouping: folderItems, by: { $0.album.lowercased() })
            if albumGroups.count > 1,
               let (_, majorityItems) = albumGroups.max(by: { $0.value.count < $1.value.count }) {
                let majorityAlbum = majorityItems[0].album  // Original-cased display name
                let majorityRatio = Double(majorityItems.count) / Double(folderItems.count)
                if majorityRatio >= 0.6 {
                    let outlierItems = folderItems.filter { $0.album.lowercased() != majorityAlbum.lowercased() }
                    if !outlierItems.isEmpty {
                        let outlierNames = Set(outlierItems.map { $0.album })
                        warnings.append(ConsistencyWarning(
                            folderPath: folder,
                            message: "\(outlierItems.count) track(s) have album \"\(outlierNames.joined(separator: ", "))\" but \(majorityItems.count) others say \"\(majorityAlbum)\"",
                            affectedItems: outlierItems.map { $0.id },
                            fix: .useAlbumMajority(album: majorityAlbum)
                        ))
                    }
                }
            }

            // Check mixed confidence
            let confidenceCounts = Dictionary(grouping: folderItems, by: { $0.confidence })
            if confidenceCounts.count > 1 {
                let hasHigh = confidenceCounts[.high] != nil
                let lowItems = confidenceCounts[.low] ?? []
                if hasHigh && !lowItems.isEmpty {
                    warnings.append(ConsistencyWarning(
                        folderPath: folder,
                        message: "\(lowItems.count) track(s) have low confidence in a folder where other tracks matched well",
                        affectedItems: lowItems.map { $0.id },
                        fix: .markForReview
                    ))
                }
            }
        }

        return warnings
    }
}

#endif
