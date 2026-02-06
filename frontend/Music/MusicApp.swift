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
    // Local SwiftData container for all models
    // Catalog syncs via catalog.json on CDN (not CloudKit)
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            CachedTrack.self,
            CachedArtwork.self,
            CatalogArtist.self,
            CatalogAlbum.self,
            CatalogTrack.self,
            CatalogMetadata.self
        ])

        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none  // Local only - catalog syncs via CDN
        )

        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            print("Failed to create persistent ModelContainer: \(error)")

            // Try deleting the corrupt store and retrying
            if let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                let storeURL = appSupportURL.appendingPathComponent("default.store")
                try? FileManager.default.removeItem(at: storeURL)
                // Also remove WAL/SHM files
                try? FileManager.default.removeItem(at: storeURL.appendingPathExtension("wal"))
                try? FileManager.default.removeItem(at: storeURL.appendingPathExtension("shm"))

                if let retryContainer = try? ModelContainer(for: schema, configurations: [config]) {
                    print("Successfully recreated ModelContainer after deleting corrupt store")
                    return retryContainer
                }
            }

            print("Falling back to in-memory storage")

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
                #if os(macOS)
                .accentColor(Color.appAccent)
                #endif
        }
        .modelContainer(sharedModelContainer)
    }
}
