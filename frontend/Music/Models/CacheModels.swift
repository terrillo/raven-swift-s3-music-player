//
//  CacheModels.swift
//  Music
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

@Model
class CachedCatalog {
    @Attribute(.unique) var id: String
    var catalogData: Data
    var cachedAt: Date
    var totalTracks: Int
    var generatedAt: String

    init(id: String = "main", catalogData: Data, totalTracks: Int, generatedAt: String, cachedAt: Date = Date()) {
        self.id = id
        self.catalogData = catalogData
        self.totalTracks = totalTracks
        self.generatedAt = generatedAt
        self.cachedAt = cachedAt
    }
}

// Note: PlayEvent and SkipEvent analytics are now in Core Data + CloudKit
// See AnalyticsStore.swift and MusicDB.xcdatamodeld
