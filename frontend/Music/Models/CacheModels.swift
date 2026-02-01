//
//  CacheModels.swift
//  Music
//
//  SwiftData models for caching downloaded tracks and artwork locally.
//

import Foundation
import SwiftData

@Model
class CachedTrack {
    @Attribute(.unique) var s3Key: String
    var localFileName: String
    var fileSize: Int64
    var cachedAt: Date

    init(s3Key: String, localFileName: String, fileSize: Int64, cachedAt: Date = Date()) {
        self.s3Key = s3Key
        self.localFileName = localFileName
        self.fileSize = fileSize
        self.cachedAt = cachedAt
    }
}

@Model
class CachedArtwork {
    @Attribute(.unique) var remoteUrl: String
    var localFileName: String
    var cachedAt: Date

    init(remoteUrl: String, localFileName: String, cachedAt: Date = Date()) {
        self.remoteUrl = remoteUrl
        self.localFileName = localFileName
        self.cachedAt = cachedAt
    }
}

// Note: CachedCatalog removed - catalog now comes exclusively from SwiftData
// (populated by macOS upload feature, synced via CloudKit)

// Note: PlayEvent and SkipEvent analytics are in Core Data + CloudKit
// See AnalyticsStore.swift and MusicDB.xcdatamodeld
