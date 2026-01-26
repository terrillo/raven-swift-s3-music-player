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
    // Local-only container for cache tracking (device-specific, SwiftData)
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([Item.self, CachedTrack.self, CachedArtwork.self, CachedCatalog.self])
        let config = ModelConfiguration(
            "LocalCache",
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    // Analytics uses Core Data + CloudKit (see AnalyticsStore.swift)

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .tint(.yellow)
        }
        .modelContainer(sharedModelContainer)
    }
}
