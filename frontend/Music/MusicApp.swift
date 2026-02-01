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
    // Single local container for all SwiftData models
    // Note: CloudKit sync for catalog can be enabled later via separate container
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            // Cache models (device-specific, for offline playback)
            Item.self,
            CachedTrack.self,
            CachedArtwork.self,
            // Catalog models (populated by macOS upload feature)
            CatalogArtist.self,
            CatalogAlbum.self,
            CatalogTrack.self,
            CatalogMetadata.self
        ])

        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none  // Local-only for reliability
        )

        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Log error and attempt recovery with in-memory fallback
            print("❌ Failed to create persistent ModelContainer: \(error)")
            print("⚠️ Falling back to in-memory storage")

            let fallbackConfig = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: true,
                cloudKitDatabase: .none
            )

            do {
                return try ModelContainer(for: schema, configurations: [fallbackConfig])
            } catch {
                fatalError("Could not create ModelContainer: \(error)")
            }
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
