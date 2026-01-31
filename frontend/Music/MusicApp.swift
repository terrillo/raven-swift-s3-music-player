//
//  MusicApp.swift
//  Music
//
//  Created by Terrillo Walls on 1/17/26.
//

import SwiftUI
import SwiftData

@main
struct MusicApp: App {
    // Combined container with local cache and iCloud-synced upload models
    var sharedModelContainer: ModelContainer = {
        // Local-only models (device-specific cache)
        let localSchema = Schema([
            Item.self,
            CachedTrack.self,
            CachedArtwork.self,
            CachedCatalog.self
        ])
        let localConfig = ModelConfiguration(
            "LocalCache",
            schema: localSchema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )

        // iCloud-synced models (upload state shared across devices)
        let cloudSchema = Schema([
            UploadedTrack.self,
            UploadedArtist.self,
            UploadedAlbum.self
        ])
        let cloudConfig = ModelConfiguration(
            "CloudSync",
            schema: cloudSchema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .automatic
        )

        // Combined schema for the container
        let fullSchema = Schema([
            Item.self,
            CachedTrack.self,
            CachedArtwork.self,
            CachedCatalog.self,
            UploadedTrack.self,
            UploadedArtist.self,
            UploadedAlbum.self
        ])

        do {
            return try ModelContainer(for: fullSchema, configurations: [localConfig, cloudConfig])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    // Analytics uses Core Data + CloudKit (see AnalyticsStore.swift)

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .tint(.appAccent)
        }
        .modelContainer(sharedModelContainer)
    }
}
