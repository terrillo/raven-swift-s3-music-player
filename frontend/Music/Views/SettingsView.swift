//
//  SettingsView.swift
//  Music
//

import SwiftUI
import SwiftData

struct SettingsView: View {
    @Binding var showingSearch: Bool
    var cacheService: CacheService
    var musicService: MusicService

    @AppStorage("streamingModeEnabled") private var streamingModeEnabled = false
    @State private var showingCacheSheet = false
    @State private var showingClearConfirmation = false
    @State private var showingDeleteAllConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                Section("Playback") {
                    Toggle(isOn: $streamingModeEnabled) {
                        Label {
                            VStack(alignment: .leading) {
                                Text("Streaming Mode")
                                Text("Play uncached tracks when online")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                        }
                    }
                }

                Section("Storage") {
                    Button {
                        showingCacheSheet = true
                    } label: {
                        HStack {
                            Label("Cache All Music", systemImage: "arrow.down.circle")
                            Spacer()
                            Text("\(musicService.songs.count) songs")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)

                    HStack {
                        Label("Cached", systemImage: "internaldrive")
                        Spacer()
                        Text("\(cacheService.cachedTrackCount()) songs")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Label("Cache Size", systemImage: "chart.pie")
                        Spacer()
                        Text(cacheService.formattedCacheSize())
                            .foregroundStyle(.secondary)
                    }

                    Button(role: .destructive) {
                        showingClearConfirmation = true
                    } label: {
                        Label("Clear Cache", systemImage: "trash")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showingDeleteAllConfirmation = true
                    } label: {
                        Label("Delete All Data", systemImage: "exclamationmark.triangle")
                    }
                } header: {
                    Text("Danger Zone")
                } footer: {
                    Text("Deletes all cached music, artwork, and listening history from this device and iCloud.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                }
            }
            .sheet(isPresented: $showingCacheSheet) {
                CacheDownloadView(
                    cacheService: cacheService,
                    tracks: musicService.songs,
                    artworkUrls: collectArtworkUrls(),
                    catalog: musicService.catalog
                )
            }
            .confirmationDialog("Clear Cache", isPresented: $showingClearConfirmation) {
                Button("Clear Cache", role: .destructive) {
                    Task {
                        await cacheService.clearCache()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will delete all cached music and artwork. You'll need to download them again for offline playback.")
            }
            .confirmationDialog("Delete All Data", isPresented: $showingDeleteAllConfirmation) {
                Button("Delete All Data", role: .destructive) {
                    Task {
                        await cacheService.clearAllData()
                        AnalyticsStore.shared.clearAllData()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete all cached music, artwork, catalog data, and listening history from this device AND iCloud. This affects all devices using this iCloud account. This action cannot be undone.")
            }
        }
    }

    private func collectArtworkUrls() -> [String] {
        var urls: Set<String> = []

        for artist in musicService.artists {
            if let url = artist.imageUrl {
                urls.insert(url)
            }
            for album in artist.albums {
                if let url = album.imageUrl {
                    urls.insert(url)
                }
            }
        }

        for track in musicService.songs {
            if let url = track.embeddedArtworkUrl {
                urls.insert(url)
            }
        }

        return Array(urls)
    }
}

#Preview {
    do {
        let container = try ModelContainer(for: CachedTrack.self, CachedArtwork.self)
        return SettingsView(
            showingSearch: .constant(false),
            cacheService: CacheService(modelContext: container.mainContext),
            musicService: MusicService()
        )
    } catch {
        return Text("Preview unavailable: \(error.localizedDescription)")
    }
}
